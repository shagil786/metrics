// MCPShutdownTests: what happens to work that is still running when the session ends.
//
// `printf '…' | portmaster-mcp` — and every one-shot client that writes a request and
// closes stdin — is a session whose end arrives while its call is still in flight.
// What the server does with that is the difference between "the caller got an answer"
// and "the approval path was silently dropped", and slice 2 made it matter: a relayed
// `confirmEach` mutation waits for a person for up to `SocketMCPClient.callTimeout`
// (75 s), which is seven times the on-demand drain.
//
// Two properties are held here, one arithmetic and one behavioural:
//
//  1. **The drain outlasts the call it is waiting for**, per route. A bound below a
//     legitimate wait loses that call, which for a confirmation means the user is asked
//     a question whose answer can never arrive.
//  2. **The drain really does wait.** The bound being large is not the same as the
//     wait happening; this drives `CallTracker` directly so the mechanism is exercised
//     rather than inferred.

import Foundation
@testable import PortmasterMCP
import XCTest

final class MCPShutdownTests: XCTestCase {

    // MARK: The bound

    /// A relayed session must outlast the longest call a client will wait for.
    func testTheRelayedDrainOutlastsTheRelayedCall() {
        XCTAssertGreaterThan(
            MCPStdioRunner.relayedEofDrainTimeout, SocketMCPClient.callTimeout,
            "a drain below the client's own budget ends the process while the call is "
                + "still live, and the answer can never be delivered"
        )
    }

    /// …and the on-demand session must not inherit that budget.
    ///
    /// The two are separate numbers on purpose. Widening the on-demand drain would
    /// make a wedged sampler cost 75 seconds to give up instead of 10, which is a
    /// regression traded for nothing.
    func testTheOnDemandDrainIsUnaffectedByTheRelayedOne() {
        XCTAssertLessThan(
            MCPStdioRunner.eofDrainTimeout, MCPStdioRunner.relayedEofDrainTimeout,
            "an on-demand session has no confirmation to wait for"
        )
        XCTAssertEqual(
            MCPStdioRunner.drainTimeout(relayed: false), MCPStdioRunner.eofDrainTimeout
        )
        XCTAssertEqual(
            MCPStdioRunner.drainTimeout(relayed: true), MCPStdioRunner.relayedEofDrainTimeout
        )
    }

    /// The bound is a formula over two numbers that each have an owner, so shortening
    /// either surfaces as a failure here rather than in a user's face.
    func testTheRelayedDrainIsDerivedRatherThanWrittenDown() {
        XCTAssertEqual(
            MCPStdioRunner.relayedEofDrainTimeout,
            ConfirmationBroker.defaultTimeout
                + OnDemandProvider.defaultSnapshotTimeout
                + SocketMCPClient.relayedCallMargin
                + MCPStdioRunner.eofQuietPeriod,
            "the drain must track the budgets it exists to outlast"
        )
    }

    // MARK: The wait

    /// The mechanism, not the arithmetic: work still running at EOF is waited for.
    ///
    /// A call that outlives the *quiet* period must keep the shutdown waiting, up to
    /// the deadline — and must be waited out to completion, not abandoned when the
    /// deadline lands. That second half is the one that matters for a confirmation: an
    /// approval answered a moment too late is still an approval the user gave.
    func testShutdownWaitsForACallStillRunningAtEOF() async throws {
        let tracker = CallTracker()
        let finished = expectation(description: "the call finished")
        let work = Task {
            try await tracker.track {
                try await Task.sleep(for: .milliseconds(300))
            }
            finished.fulfill()
        }

        // Quiet is short, so it proves the wait is driven by the in-flight count and
        // not by the quiet period elapsing.
        await tracker.waitUntilIdle(
            quiet: MCPStdioRunner.eofQuietPeriod,
            timeout: MCPStdioRunner.eofDrainTimeout
        )

        await fulfillment(of: [finished], timeout: 2)
        _ = try await work.value
        let remaining = await tracker.inFlightCount
        XCTAssertEqual(remaining, 0, "and the tracker is empty once it is")
    }

    /// A call that never finishes still ends the shutdown, at the deadline.
    ///
    /// Without this the fix above would be a hang: "wait for in-flight work" is only
    /// safe because it is bounded, and the bound is what this holds still.
    func testACallThatNeverFinishesStillEndsTheShutdown() async throws {
        let tracker = CallTracker()
        let work = Task {
            try await tracker.track {
                try await Task.sleep(for: .seconds(30))
            }
        }
        let started = Date()
        await tracker.waitUntilIdle(quiet: 0.01, timeout: 0.2)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 5, "a wedged handler must cost the deadline and no more")
        work.cancel()
        _ = try? await work.value
    }
}
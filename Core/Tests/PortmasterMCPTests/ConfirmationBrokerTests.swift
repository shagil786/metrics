// ConfirmationBrokerTests: the human-in-the-loop gate between an AI client and a
// change to the machine.
//
// The broker is the piece of slice 2 that must never be wrong in the quiet way. A
// request that is never resumed is a tool call that hangs forever; a continuation
// resumed twice traps; two dialogs stacked at once is how a user approves the
// wrong thing. So these tests are about the paths rather than the happy case
// alone: every outcome terminates, nothing is left pending, an answer for an id
// nobody asked about is inert, and a denial does not strand the request behind it.
//
// Nothing here touches a socket or a window. The broker only answers; who shows
// the prompt is a later task's business.
//
// Waiting is done by polling bounded boxes rather than by sleeping for the answer:
// a test that slept long enough to pass would also pass when the broker is broken
// in the other direction, and a test that slept forever would hang the suite
// instead of failing it.

import Foundation
import PortmasterMCP
import XCTest

final class ConfirmationBrokerTests: XCTestCase {

    // MARK: - Approve and deny

    func testApproveReturnsApproved() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let (box, _) = start(broker, makeRequest())

        let presented = await waitForPending(broker, 1)
        let id = try XCTUnwrap(presented.first?.id, "the request must be presented for a decision")
        await broker.decide(id: id, outcome: .approved)

        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .approved)
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [], "a decided request must leave the queue")
    }

    func testDenyReturnsDeniedWithTheGivenReason() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let (box, _) = start(broker, makeRequest())

        let presented = await waitForPending(broker, 1)
        let id = try XCTUnwrap(presented.first?.id)
        await broker.decide(id: id, outcome: .denied(reason: "Portmaster is quitting."))

        // The reason has to survive verbatim: the tool layer shows it to the AI
        // client, and a generic "denied" tells the model nothing about retrying.
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .denied(reason: "Portmaster is quitting."))
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    // MARK: - Silence

    func testSilenceTimesOutAtTheConfiguredBudget() async throws {
        let broker = ConfirmationBroker(timeout: 0.05)
        let started = Date()
        let (box, _) = start(broker, makeRequest())
        await waitForPending(broker, 1)

        // Nobody ever decides. The caller must still come back.
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .timedOut)
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [], "a timed-out request must leave the queue")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 5,
            "a 50 ms budget must not be waited out in real minutes"
        )
    }

    // MARK: - Order

    func testSecondRequestWaitsBehindTheFirst() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")

        let (firstBox, _) = start(broker, first)
        let presented = await waitForPending(broker, 1)
        XCTAssertEqual(presented.map(\.id), [first.id])

        let (secondBox, _) = start(broker, second)
        await waitWhileSuspended(secondBox)
        XCTAssertNil(secondBox.result, "a queued request must stay suspended")
        let whileQueued = await pendingIDs(broker)
        XCTAssertEqual(
            whileQueued, [first.id],
            "only the request being decided is presented, or a burst stacks dialogs"
        )

        await broker.decide(id: first.id, outcome: .approved)
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .approved)

        let nowPresented = await waitForPending(broker, 1)
        XCTAssertEqual(
            nowPresented.map(\.id), [second.id],
            "the queued request is presented once the first one is decided"
        )
        await broker.decide(id: second.id, outcome: .approved)
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .approved)
    }

    func testDecideIgnoresAnUnknownID() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let (box, _) = start(broker, makeRequest())
        let presented = await waitForPending(broker, 1)
        let id = try XCTUnwrap(presented.first?.id)

        // A stale window answering a request that was never asked about, twice.
        await broker.decide(id: UUID(), outcome: .approved)
        await broker.decide(id: UUID(), outcome: .denied(reason: "wrong request"))
        await waitWhileSuspended(box)
        XCTAssertNil(box.result, "an unknown id must not resume anything")
        let unchanged = await pendingIDs(broker)
        XCTAssertEqual(unchanged, [id], "an unknown id must leave the queue alone")

        // And the real request is still decidable afterwards, which is what proves
        // the queue was not corrupted rather than merely unchanged.
        await broker.decide(id: id, outcome: .approved)
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .approved)
    }

    // MARK: - Termination

    func testPendingIsEmptyAfterEveryDecisionPath() async throws {
        // Each path gets its own broker: the point is that the queue drains, not
        // that a sequence of outcomes works out.
        let approved = ConfirmationBroker(timeout: 5)
        let approvedRequest = makeRequest(kind: .quitApp)
        let (approvedBox, _) = start(approved, approvedRequest)
        await waitForPending(approved, 1)
        await approved.decide(id: approvedRequest.id, outcome: .approved)
        let approvedOutcome = try await waitForOutcome(approvedBox)
        XCTAssertEqual(approvedOutcome, .approved)
        let afterApprove = await pendingIDs(approved)
        XCTAssertEqual(afterApprove, [], "approved leaves nothing pending")

        let denied = ConfirmationBroker(timeout: 5)
        let deniedRequest = makeRequest(kind: .stopProject)
        let (deniedBox, _) = start(denied, deniedRequest)
        await waitForPending(denied, 1)
        await denied.decide(id: deniedRequest.id, outcome: .denied(reason: "Not now."))
        let deniedOutcome = try await waitForOutcome(deniedBox)
        XCTAssertEqual(deniedOutcome, .denied(reason: "Not now."))
        let afterDeny = await pendingIDs(denied)
        XCTAssertEqual(afterDeny, [], "denied leaves nothing pending")

        let silent = ConfirmationBroker(timeout: 0.05)
        let (silentBox, _) = start(silent, makeRequest(kind: .setPreference))
        await waitForPending(silent, 1)
        let silentOutcome = try await waitForOutcome(silentBox)
        XCTAssertEqual(silentOutcome, .timedOut)
        let afterTimeout = await pendingIDs(silent)
        XCTAssertEqual(afterTimeout, [], "timed out leaves nothing pending")
    }

    func testCancelAllDeniesEverythingPending() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopProject, summary: "Stop project web")

        let (firstBox, _) = start(broker, first)
        let presented = await waitForPending(broker, 1)
        XCTAssertEqual(presented.map(\.id), [first.id])
        let (secondBox, _) = start(broker, second)
        // The queued request has to have reached the actor before the shutdown
        // happens, or `cancelAll` would legitimately miss it and this test would
        // be measuring scheduling luck rather than the broker.
        await waitWhileSuspended(secondBox, duration: 0.2)

        await broker.cancelAll(reason: "Portmaster is quitting.")

        // Denied, not left hanging: a caller must never wait out the budget when
        // the answer is already known.
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .denied(reason: "Portmaster is quitting."))
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .denied(reason: "Portmaster is quitting."))
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    func testAFailedDecisionDoesNotLeakTheContinuation() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let first = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let second = makeRequest(kind: .stopContainer, summary: "Stop container web")

        let (firstBox, _) = start(broker, first)
        await waitForPending(broker, 1)
        let (secondBox, _) = start(broker, second)
        await waitWhileSuspended(secondBox, duration: 0.2)

        // The interesting half of "no leak": a caller that says no must not
        // consume or strand the request waiting behind it.
        await broker.decide(id: first.id, outcome: .denied(reason: "Not this time."))
        let firstOutcome = try await waitForOutcome(firstBox)
        XCTAssertEqual(firstOutcome, .denied(reason: "Not this time."))

        let nowPresented = await waitForPending(broker, 1)
        XCTAssertEqual(nowPresented.map(\.id), [second.id])
        await broker.decide(id: second.id, outcome: .approved)
        let secondOutcome = try await waitForOutcome(secondBox)
        XCTAssertEqual(secondOutcome, .approved)
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    // MARK: - A caller that gives up

    /// A caller whose own task is cancelled mid-wait must not disappear from the
    /// queue and must not take the next request with it. The broker owes it an
    /// outcome either way: dropping the entry would leak the continuation, and
    /// resuming it later is legal even though the awaiting task no longer cares.
    func testACancelledCallerDoesNotStrandTheQueue() async throws {
        let broker = ConfirmationBroker(timeout: 5)
        let abandoned = makeRequest(kind: .quitApp, summary: "Quit Mail?")
        let abandonedTask = Task { try await broker.request(abandoned) }
        await waitForPending(broker, 1)

        abandonedTask.cancel()

        let next = makeRequest(kind: .stopContainer, summary: "Stop container web")
        let (nextBox, _) = start(broker, next)
        await waitWhileSuspended(nextBox, duration: 0.2)
        let afterCancel = await pendingIDs(broker)
        XCTAssertEqual(
            afterCancel, [abandoned.id],
            "the abandoned request is still owed a decision, and still heads the queue"
        )

        await broker.decide(id: abandoned.id, outcome: .denied(reason: "Caller went away."))
        let abandonedResult = await abandonedTask.result
        let abandonedOutcome = try abandonedResult.get()
        XCTAssertEqual(
            abandonedOutcome, .denied(reason: "Caller went away."),
            "a cancelled caller must still be resumed rather than left suspended"
        )

        let nowPresented = await waitForPending(broker, 1)
        XCTAssertEqual(nowPresented.map(\.id), [next.id])
        await broker.decide(id: next.id, outcome: .approved)
        let nextOutcome = try await waitForOutcome(nextBox)
        XCTAssertEqual(nextOutcome, .approved, "the next request is unaffected")
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    // MARK: - The clock is real, not decorative

    /// The budget is measured against the injected clock, not against wall time.
    /// Without this, a 60-second budget could only be tested by not deciding for
    /// 60 seconds, and the default would be the only budget worth trusting.
    func testAnInjectedClockExpiresTheBudgetWithoutWaitingForIt() async throws {
        let clock = FakeClock()
        let broker = ConfirmationBroker(timeout: ConfirmationBroker.defaultTimeout, clock: { clock.now })
        let (box, _) = start(broker, makeRequest())
        await waitForPending(broker, 1)

        await waitWhileSuspended(box)
        XCTAssertNil(box.result, "a budget that has not elapsed must not expire")

        clock.advance(by: ConfirmationBroker.defaultTimeout + 1)
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .timedOut, "advancing the clock must expire the default budget")
        let remaining = await pendingIDs(broker)
        XCTAssertEqual(remaining, [])
    }

    /// A presenter that answers after the budget ran out must be inert. This is
    /// the double-resume hazard in its purest form: resuming an already-resumed
    /// `CheckedContinuation` traps, so the outcome has to stay the timeout and
    /// the broker has to keep serving.
    func testALateDecisionAfterATimeoutIsIgnored() async throws {
        let broker = ConfirmationBroker(timeout: 0.05)
        let request = makeRequest()
        let (box, _) = start(broker, request)
        let outcome = try await waitForOutcome(box)
        XCTAssertEqual(outcome, .timedOut)

        await broker.decide(id: request.id, outcome: .approved)
        let afterLateDecision = await pendingIDs(broker)
        XCTAssertEqual(afterLateDecision, [], "a late answer has nothing to answer")
        XCTAssertEqual(box.outcome, .timedOut, "the first outcome stands")

        let next = makeRequest(kind: .stopProject, summary: "Stop project web")
        let (nextBox, _) = start(broker, next)
        let presented = await waitForPending(broker, 1)
        XCTAssertEqual(presented.map(\.id), [next.id])
        await broker.decide(id: next.id, outcome: .approved)
        let nextOutcome = try await waitForOutcome(nextBox)
        XCTAssertEqual(
            nextOutcome, .approved,
            "the broker must still serve requests after a late answer"
        )
    }

    // MARK: - Helpers

    private func makeRequest(
        kind: MCPApprovalRequest.Kind = .quitApp,
        summary: String = "Quit Mail?",
        detail: String = "Portmaster will ask Mail to quit."
    ) -> MCPApprovalRequest {
        MCPApprovalRequest(kind: kind, summary: summary, detail: detail)
    }

    /// Runs a request in its own task and records what came back.
    ///
    /// A `Task` cannot be asked whether it is finished, and awaiting one that is
    /// *meant* to be suspended would hang the test instead of failing it. So the
    /// answer lands in a box the test polls, which turns "did it come back?" into
    /// a question with a deadline.
    private func start(
        _ broker: ConfirmationBroker,
        _ request: MCPApprovalRequest
    ) -> (OutcomeBox, Task<Void, Never>) {
        let box = OutcomeBox()
        let task = Task {
            do {
                box.store(.success(try await broker.request(request)))
            } catch {
                box.store(.failure(error))
            }
        }
        return (box, task)
    }

    /// The ids currently presented, hoisted out of the actor because `XCTAssert*`
    /// takes autoclosures, and an autoclosure cannot await.
    private func pendingIDs(_ broker: ConfirmationBroker) async -> [UUID] {
        await broker.pending.map(\.id)
    }

    /// Polls until exactly `count` requests are presented, or fails the test.
    /// Bounded on purpose: a broker that never publishes is a failure to report,
    /// not a suite to hang.
    @discardableResult
    private func waitForPending(
        _ broker: ConfirmationBroker,
        _ count: Int,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> [MCPApprovalRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [MCPApprovalRequest] = []
        while Date() < deadline {
            latest = await broker.pending
            if latest.count == count { return latest }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail(
            "expected \(count) pending request(s), saw \(latest.map(\.id))",
            file: file, line: line
        )
        return latest
    }

    /// Waits for a request to come back, within a bound that keeps a broken broker
    /// from wedging the suite.
    private func waitForOutcome(
        _ box: OutcomeBox,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ApprovalOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = box.result {
                // A thrown `windowUnavailable` fails the test here, with the
                // broker's own reason, rather than as a confusing nil outcome.
                return try result.get()
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the request never came back", file: file, line: line)
        throw CancellationError()
    }

    /// Gives a request that must *not* resolve a bounded chance to resolve
    /// wrongly. Only useful as the negative half of an assertion.
    private func waitWhileSuspended(_ box: OutcomeBox, duration: TimeInterval = 0.05) async {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            if box.result != nil { return }
            try? await Task.sleep(for: .milliseconds(2))
        } while Date() < deadline
    }

    /// A recorded outcome. `@unchecked Sendable` because the request task writes
    /// it and the test task reads it; the lock is what makes that safe.
    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<ApprovalOutcome, Error>?

        var result: Result<ApprovalOutcome, Error>? { lock.withLock { stored } }

        var outcome: ApprovalOutcome? {
            guard case .success(let outcome) = result else { return nil }
            return outcome
        }

        func store(_ result: Result<ApprovalOutcome, Error>) {
            lock.withLock { stored = result }
        }
    }

    /// A clock a test moves by hand, so a timeout budget can expire without the
    /// test spending real seconds on it.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
            current = now
        }

        var now: Date { lock.withLock { current } }

        func advance(by seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }
}

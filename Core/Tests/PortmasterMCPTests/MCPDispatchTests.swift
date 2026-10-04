// MCPDispatchTests: the seam between the MCP wire and `ToolExecutor`.
//
// These are the tests that cannot be written against the executable, because
// what they check is a decision made *between* two calls in one process: that the
// permission gate is rebuilt per call, so a mode change or a quit Portmaster
// takes effect without restarting the server.

import Foundation
import PortmasterCore
@testable import PortmasterMCP
import XCTest

final class MCPDispatchTests: XCTestCase {

    /// A context that answers by handing out a fresh executor every time, and counts
    /// them. `@unchecked Sendable` because the count is guarded by a lock.
    private final class CountingContext: MCPToolCalling, @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        private let executor: @Sendable () -> ToolExecutor

        init(_ executor: @escaping @Sendable () -> ToolExecutor) { self.executor = executor }

        var executorsMade: Int { lock.withLock { made } }

        func call(name: String, arguments: [String: String]) async -> ToolOutcome {
            let tool = lock.withLock { () -> ToolExecutor in
                made += 1
                return executor()
            }
            return await tool.execute(name: name, arguments: arguments)
        }
    }

    func testEachToolCallBuildsItsOwnExecutor() async throws {
        let directory = try makeTemporaryDirectory(prefix: name)
        let provider = StubProvider()
        let context = CountingContext {
            ToolExecutor(
                provider: provider,
                gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
                audit: AuditLog(directory: directory)
            )
        }

        let first = await MCPDispatch.call(
            name: "get_settings", arguments: [:], context: context
        )
        let second = await MCPDispatch.call(
            name: "get_settings", arguments: [:], context: context
        )

        XCTAssertFalse(first.isError, first.text)
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(
            context.executorsMade, 2,
            "an executor cached across calls would freeze the settings a call sees"
        )
        // Both calls answered with the stub's settings rather than one coming back
        // empty-handed. The count above is the real assertion here; this only
        // confirms neither call was swallowed.
        XCTAssertEqual(first.text, second.text)
    }

    /// The provider is the other half of the seam, and it must *not* be per call.
    ///
    /// A provider owns the sampler, and the sampler is expensive: a cold engine
    /// pays a process sweep, an `lsof` port scan and a `nettop` pass before it has
    /// anything to say. Building one per call would also make the documented 5 s
    /// snapshot cache unreachable — a cache with no owner is not a cache — so two
    /// reads in one agent turn would each pay a full sweep, and N concurrent reads
    /// would run N engines over the same machine.
    ///
    /// The context is *given* the provider rather than a factory that makes one, so
    /// the second read here is answered by the same cache the first one filled.
    func testTwoReadsThroughTheLiveContextShareOneProvider() async throws {
        let source = StubSnapshotSource([OnDemandProviderTests.makeSnapshot(cpuPercent: 42)])
        let provider = OnDemandProvider(
            snapshotSource: source,
            appRunning: { false },
            cacheTTL: 5
        )
        let context = LocalMCPCallContext(
            provider: provider,
            loadSettings: { MCPSettings(mode: .off) },
            appRunning: { false },
            auditDirectory: try makeTemporaryDirectory(prefix: name)
        )

        let first = await MCPDispatch.call(
            name: "get_system_overview", arguments: [:], context: context
        )
        let second = await MCPDispatch.call(
            name: "get_system_overview", arguments: [:], context: context
        )

        XCTAssertFalse(first.isError, first.text)
        XCTAssertFalse(second.isError, second.text)
        XCTAssertEqual(
            source.callCount, 1,
            "the second read must be answered by the snapshot the first one collected"
        )
        XCTAssertEqual(first.text, second.text)
    }

    /// The reason this seam exists at all.
    ///
    /// `PermissionGate` takes `appRunning` as a construction-time snapshot, so a
    /// server that built one gate at startup would keep permitting
    /// `allowSession` mutations after the user quit Portmaster — contradicting
    /// the very reason string it returns in the other direction.
    func testSessionGrantStopsApplyingOnceTheAppQuits() async throws {
        let auditDirectory = try makeTemporaryDirectory(prefix: name)
        let provider = StubProvider()
        let running = LivenessStub(startsRunning: true)
        let context = LocalMCPCallContext(
            provider: provider,
            loadSettings: { MCPSettings(mode: .allowSession) },
            appRunning: { running.isRunning },
            auditDirectory: auditDirectory
        )
        let arguments = ["id": "app:Somewhere"]

        // First call: Portmaster is running, so the session grant holds.
        let allowed = await MCPDispatch.call(
            name: "quit_app", arguments: arguments, context: context
        )
        XCTAssertFalse(allowed.isError, allowed.text)
        XCTAssertEqual(provider.quitAppCallCount, 1)

        // The user quits Portmaster. Nothing restarts the server.
        running.isRunning = false

        let denied = await MCPDispatch.call(
            name: "quit_app", arguments: arguments, context: context
        )
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(
            denied.text, "Session grants apply only while Portmaster is running."
        )
        XCTAssertEqual(
            provider.quitAppCallCount, 1,
            "a denied mutation must return before the provider is touched"
        )
        let entries = try auditEntries(in: auditDirectory)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { $0["outcome"] as? String }, ["allowed", "denied"])
    }

    /// A mode change written to disk takes effect on the next call too.
    func testModeChangeOnDiskAppliesToTheNextCall() async throws {
        let auditDirectory = try makeTemporaryDirectory(prefix: name)
        let settingsDirectory = try makeTemporaryDirectory(prefix: name)
        let settings = SettingsStub(MCPSettings(mode: .off))
        let provider = StubProvider()
        let context = LocalMCPCallContext(
            provider: provider,
            loadSettings: { settings.current },
            appRunning: { false },
            auditDirectory: auditDirectory,
            settingsDirectory: settingsDirectory
        )

        let denied = await MCPDispatch.call(
            name: "quit_app", arguments: ["id": "app:Somewhere"], context: context
        )
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(denied.text, "MCP mutations are disabled in Portmaster settings.")

        settings.current.mode = .allowSession
        let stillDenied = await MCPDispatch.call(
            name: "quit_app", arguments: ["id": "app:Somewhere"], context: context
        )
        XCTAssertTrue(
            stillDenied.isError,
            "the app is not running, so allowSession must still deny"
        )
        XCTAssertEqual(stillDenied.text, "Session grants apply only while Portmaster is running.")
    }

    /// The mode on disk, changeable between two calls in one server's life.
    private final class SettingsStub: @unchecked Sendable {
        private let lock = NSLock()
        private var settings: MCPSettings
        init(_ settings: MCPSettings) { self.settings = settings }
        var current: MCPSettings {
            get { lock.withLock { settings } }
            set { lock.withLock { settings = newValue } }
        }
    }

    /// A flag a test can flip mid-run, standing in for the app being quit.
    private final class LivenessStub: @unchecked Sendable {
        private let lock = NSLock()
        private var running: Bool
        init(startsRunning: Bool) { running = startsRunning }
        var isRunning: Bool {
            get { lock.withLock { running } }
            set { lock.withLock { running = newValue } }
        }
    }

    // MARK: The EOF drain

    /// The drain gives work that is already running time to finish.
    func testDrainWaitsForACallThatIsStillRunning() async throws {
        let tracker = CallTracker()
        let started = expectation(description: "the tracked call began")
        Task {
            await tracker.track {
                started.fulfill()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await fulfillment(of: [started], timeout: 5)
        // Well past the quiet period, so only the in-flight count can hold the
        // drain open.
        await tracker.waitUntilIdle(quiet: 0.02, timeout: 5)
        let finished = await tracker.inFlightCount
        XCTAssertEqual(finished, 0, "the drain must return after the call completed")
    }

    /// The other half of the ruling: a call that never returns must not keep the
    /// server alive. Bounded means the wait ends at the timeout, whatever the
    /// handler is doing.
    func testDrainIsBoundedWhenACallNeverReturns() async throws {
        let tracker = CallTracker()
        let started = expectation(description: "the tracked call began")
        Task {
            // Never completes within this test run.
            await tracker.track {
                started.fulfill()
                try? await Task.sleep(for: .seconds(600))
            }
        }
        await fulfillment(of: [started], timeout: 5)

        let began = Date()
        await tracker.waitUntilIdle(quiet: 0.02, timeout: 0.3)
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertGreaterThan(elapsed, 0.02, "the quiet period is still respected")
        XCTAssertLessThan(elapsed, 2, "a stuck call must cost the timeout and no more")
        let outstanding = await tracker.inFlightCount
        XCTAssertEqual(outstanding, 1, "the stuck call is still outstanding, and that is fine")
    }

    /// The quiet period is not zero: a request the SDK has read but not yet
    /// started is invisible to the count, so returning the instant the count hits
    /// zero would race it.
    func testDrainWaitsOutTheQuietPeriod() async throws {
        let tracker = CallTracker()
        let began = Date()
        await tracker.waitUntilIdle(quiet: 0.15, timeout: 5)
        XCTAssertGreaterThan(
            Date().timeIntervalSince(began), 0.1,
            "an idle drain must still wait out the quiet period"
        )
    }

    /// The cap is derived from the read budget so the two cannot drift apart.
    /// This names the invariant behind that derivation: a cap shorter than the
    /// budget silently loses the slowest legitimate tool, and the symptom — a
    /// piped read answering with nothing — looks like a broken server rather than
    /// a number that was picked too small.
    func testDrainCapIsNotShorterThanASlowReadCanTake() {
        XCTAssertGreaterThanOrEqual(
            MCPStdioRunner.eofDrainTimeout,
            OnDemandProvider.defaultSnapshotTimeout,
            "the EOF drain must outlast a tool that is legitimately waiting for a reading"
        )
        XCTAssertGreaterThanOrEqual(
            MCPStdioRunner.eofDrainTimeout,
            MCPStdioRunner.eofQuietPeriod,
            "the cap is a ceiling on a stuck handler, not a reason to skip the quiet period"
        )
    }
}

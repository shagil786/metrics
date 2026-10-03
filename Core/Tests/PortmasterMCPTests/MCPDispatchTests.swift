// MCPDispatchTests: the seam between the MCP wire and `ToolExecutor`.
//
// These are the tests that cannot be written against the executable, because
// what they check is a decision made *between* two calls in one process: that the
// permission gate is rebuilt per call, so a mode change or a quit Portmaster
// takes effect without restarting the server.

import Foundation
import PortmasterCore
import PortmasterMCP
import XCTest

final class MCPDispatchTests: XCTestCase {

    /// A context that hands out a fresh executor every time and counts them.
    private final class CountingContext: MCPCallContext {
        private let lock = NSLock()
        private var made = 0
        private let executor: @Sendable () -> ToolExecutor

        init(_ executor: @escaping @Sendable () -> ToolExecutor) { self.executor = executor }

        var executorsMade: Int { lock.withLock { made } }

        func makeExecutor() -> ToolExecutor {
            lock.withLock { made += 1 }
            return executor()
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
        // Two reads of the same settings are allowed to differ only because the
        // snapshot is taken twice — proof the calls really went through.
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
        let context = LiveMCPCallContext(
            provider: { provider },
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
        var settings = MCPSettings(mode: .off)
        let provider = StubProvider()
        let context = LiveMCPCallContext(
            provider: { provider },
            loadSettings: { settings },
            appRunning: { false },
            auditDirectory: auditDirectory,
            settingsDirectory: settingsDirectory
        )

        let denied = await MCPDispatch.call(
            name: "quit_app", arguments: ["id": "app:Somewhere"], context: context
        )
        XCTAssertTrue(denied.isError)
        XCTAssertEqual(denied.text, "MCP mutations are disabled in Portmaster settings.")

        settings.mode = .allowSession
        let stillDenied = await MCPDispatch.call(
            name: "quit_app", arguments: ["id": "app:Somewhere"], context: context
        )
        XCTAssertTrue(
            stillDenied.isError,
            "the app is not running, so allowSession must still deny"
        )
        XCTAssertEqual(stillDenied.text, "Session grants apply only while Portmaster is running.")
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
}
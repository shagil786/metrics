// TestMCPHost: a real MCP host in the test process, for tests that speak to one.
//
// Shared rather than declared twice, because the two suites that need it are asserting
// opposite halves of the same contract: `CLIRoutingTests` drives the relay in-process,
// and `CLIIntegrationTests` drives the executable relaying to one. Two copies of the
// stub between them would be two definitions of "the app's call surface", which is the
// thing both suites are trying to hold still.

import Foundation
import PortmasterMCP
import XCTest

/// Stands in for the app's own call surface: records what arrived, answers with a canned
/// outcome, and touches nothing on this machine.
///
/// A recording context rather than a real executor is what makes a relay observable. The
/// app's gate, broker and audit live behind *this* seam — replacing it is what makes
/// "the call arrived with these arguments" mean something, and what makes the canned
/// answer identifiable as the app's rather than the CLI's.
final class RecordingHostContext: MCPToolCalling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(name: String, arguments: [String: String])] = []
    private let text: String

    init(text: String = "done by the app") { self.text = text }

    var calls: [(name: String, arguments: [String: String])] {
        lock.withLock { recorded }
    }

    func call(name: String, arguments: [String: String]) async -> ToolOutcome {
        lock.withLock { recorded.append((name, arguments)) }
        return ToolOutcome(text: text, isError: false)
    }
}

/// A host whose calls take longer than the on-demand drain and then answer.
///
/// The shape a confirmation has from the client's side: the request is relayed, the app
/// is busy with a person, and the answer comes back eventually. `testARelayedCallOutliving
/// TheOnDemandDrainIsStillAnswered` points this at a delay just past
/// `MCPStdioRunner.eofDrainTimeout`, which is the bound the old code used for every
/// route — so a client that closed stdin while this was running used to exit without
/// ever hearing back.
final class SlowHostContext: MCPToolCalling, @unchecked Sendable {
    private let delay: TimeInterval
    private let lock = NSLock()
    private var recordedCalls = 0

    init(delay: TimeInterval) { self.delay = delay }

    var calls: Int { lock.withLock { recordedCalls } }

    func call(name: String, arguments: [String: String]) async -> ToolOutcome {
        lock.withLock { recordedCalls += 1 }
        try? await Task.sleep(for: .seconds(delay))
        return ToolOutcome(text: #"{"mutationMode":"confirmEach"}"#, isError: false)
    }
}

/// A host whose calls never answer.
///
/// This is the *wedged app* shape from the other side: the handshake works, `initialize`
/// works, the catalog is served, and then a tool call simply never comes back — which is
/// what a confirmation window waiting on a person looks like from the outside. It is what
/// makes a bounded relayed call observable: without a stall there is no way to see a
/// client give up, because a call that succeeds never stops being connected.
final class StallingHostContext: MCPToolCalling, @unchecked Sendable {
    private let began: CheckedContinuation<Void, Never>?

    init(onCallBegan: CheckedContinuation<Void, Never>? = nil) {
        began = onCallBegan
    }

    func call(name: String, arguments: [String: String]) async -> ToolOutcome {
        began?.resume()
        // A session-length wait, so the call is still outstanding when the client has
        // stopped waiting for it. `Task.sleep` rather than a loop so the task stays
        // cancellable and does not spin.
        try? await Task.sleep(for: .seconds(600))
        return ToolOutcome(text: "this should never be read", isError: false)
    }
}

/// A host bound to a socket in its own directory.
final class TestMCPHost {
    let host: MCPHostServer
    /// The recording surface, when this host was built with one. `nil` for a host whose
    /// context is only interesting for what it *does not* do, like the stalling one.
    ///
    /// Kept as the surface the host was actually built with, rather than a property
    /// typed as `any MCPToolCalling`: an existential cannot be read back as a
    /// `RecordingHostContext`, and a second initialiser that quietly installed a
    /// throwaway recorder is exactly the sort of thing that makes a relay test pass
    /// vacuously.
    let recorder: RecordingHostContext?
    let directory: URL
    let socketURL: URL

    init(directory: URL, context: RecordingHostContext) {
        self.recorder = context
        self.directory = directory
        socketURL = directory.appendingPathComponent("mcp.sock")
        host = MCPHostServer(
            socketURL: socketURL,
            endpointDirectory: directory,
            context: context
        )
    }

    /// A host over any other context, for the cases where the context is the point.
    init(directory: URL, surface: any MCPToolCalling) {
        recorder = nil
        self.directory = directory
        socketURL = directory.appendingPathComponent("mcp.sock")
        host = MCPHostServer(
            socketURL: socketURL,
            endpointDirectory: directory,
            context: surface
        )
    }

    /// The calls the recording surface received, oldest first. Empty for a host with no
    /// recorder — which is only ever read by a test that has one.
    var recordedCalls: [(name: String, arguments: [String: String])] {
        recorder?.calls ?? []
    }

    func start() throws { try host.start() }

    /// The clients the host is currently serving, oldest first.
    func connectedClients() -> [MCPConnectedClient] { host.connectedClients() }

    /// Waits for every client to have gone, or fails naming the ones that stayed.
    ///
    /// Polling rather than sleeping a fixed amount because what is being waited for — a
    /// child process closing its socket — happens on another process's schedule and has
    /// no deadline of its own. This is how "the CLI disconnected on the way out" is
    /// observed: the descriptor is closed by the process that opened it, so the host's
    /// count returning to zero *is* the evidence.
    func waitForNoClients(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let live = connectedClients()
            if live.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pids = connectedClients().map { $0.pid }
        XCTFail("clients \(pids) were still connected \(timeout)s later")
    }
}

extension XCTestCase {
    /// A host on a socket inside its own directory, started, and stopped when the test
    /// ends.
    ///
    /// The directory is prefixed `pm` and not named after the test method, because
    /// `sockaddr_un.sun_path` holds 103 bytes on Darwin and a long test name does not
    /// fit — the same reason `MCPHostHarness` uses a short one.
    func startRecordingHost(text: String = "done by the app") throws -> TestMCPHost {
        // Built directly rather than through `startHost`, which installs the *other*
        // initialiser: a host over a recording surface and a host that merely wraps some
        // surface are different fixtures, and going through the generic one here would
        // leave the recording behind on a host nobody reads.
        try start(
            TestMCPHost(
                directory: try makeTemporaryDirectory(prefix: "pm"),
                context: RecordingHostContext(text: text)
            )
        )
    }

    /// A host over any context, for the cases where the context is the point.
    func startHost(
        context: any MCPToolCalling,
        directory: URL? = nil
    ) throws -> TestMCPHost {
        try start(
            TestMCPHost(
                directory: try directory ?? makeTemporaryDirectory(prefix: "pm"),
                surface: context
            )
        )
    }

    /// Starts `fixture` and schedules its shutdown, which is the same for every host and
    /// is only here once so neither constructor path can forget it.
    private func start(_ fixture: TestMCPHost) throws -> TestMCPHost {
        try fixture.start()
        addTeardownBlock {
            // Started off the main thread: a teardown block blocks the thread it runs
            // on, and `stop` is async.
            let stopped = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                Task {
                    await fixture.host.stop()
                    stopped.signal()
                }
            }
            _ = stopped.wait(timeout: .now() + 30)
        }
        return fixture
    }
}

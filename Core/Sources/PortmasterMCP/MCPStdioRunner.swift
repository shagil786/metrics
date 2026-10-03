// MCPStdioRunner: running one stdio session.
//
// The shape here is not incidental. `SamplingEngine` publishes `latest` on the
// **main dispatch queue**, so a server process that never services its main run
// loop answers every live read with "No reading available yet; the sampler is
// still starting" — however long the caller waits. The session is therefore
// served off the main thread while the main thread pumps the run loop for the
// life of the session, and the integration test
// `testGetSystemOverviewAnswersFromLiveSampler` is what keeps that honest.
import Foundation
import MCP

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Serves MCP over stdin/stdout.
public enum MCPStdioRunner {

    /// Reported to clients in the `initialize` handshake.
    public static let serverName = "portmaster-mcp"
    public static let serverVersion = "1.0.0"

    /// Tells a client what this server is before it calls anything. The mutation
    /// policy is worth stating up front: an agent that has not been told every
    /// mutation is default-deny will discover it one refusal at a time.
    public static let instructions = """
        Read-only tools answer immediately. Every mutation — quitting an app, \
        stopping a container or project, changing a preference — is refused unless \
        the user has chosen a mutation mode in Portmaster's MCP settings, and in \
        the modes that grant it, Portmaster itself has to be running. Call \
        get_settings to read the current mode. Refusals arrive as the tool's own \
        text with isError set; they are not transport failures.
        """

    /// How long the main thread services its run loop between checks that the
    /// session has ended. Short enough that quitting on EOF is immediate to a
    /// client, long enough to cost nothing while idle.
    static let pumpInterval: TimeInterval = 0.02

    /// How long the drain waits with no call in flight before it believes the
    /// outstanding work is finished.
    ///
    /// Not zero, because a count of zero is not proof of nothing left to do: the
    /// SDK spawns a task per request from inside its receive loop and exposes no
    /// hook for "this request has been read but its handler has not started yet",
    /// so for a moment after EOF a queued call is invisible here. Requiring the
    /// count to stay at zero for this long is what tells "still nothing running"
    /// apart from "nothing started yet". Bounded on both ends — a quiet period
    /// cannot be satisfied by a handler that never finishes, and the timeout ends
    /// the wait regardless.
    static let eofQuietPeriod: TimeInterval = 0.25

    /// Longest the server stays alive after stdin reaches EOF.
    ///
    /// A stuck-handler allowance, **not** a shutdown-latency budget. In the normal
    /// case the drain returns `eofQuietPeriod` after the last reply however large
    /// this is; it is a ceiling on what a wedged handler can cost, not a wait
    /// anyone normally sits through.
    ///
    /// Derived from the read budget rather than picked, because a cap below it
    /// silently loses the slowest legitimate tool: a piped `get_system_overview`
    /// on a cold sampler can spend the whole budget waiting for its first
    /// reading, and a cap under that answers nothing at all. Expressed in terms
    /// of the provider's own number so the two cannot drift apart.
    public static let eofDrainTimeout: TimeInterval =
        OnDemandProvider.defaultSnapshotTimeout + eofQuietPeriod

    /// Serves one session over `transport` and returns when the client is done —
    /// that is, when the transport's input reaches EOF.
    ///
    /// This is the whole server, with no assumption about which thread or run
    /// loop the caller has: everything below belongs to whoever called it. Call
    /// `runMain` for the stdio process.
    ///
    /// The session itself lives in `MCPServerSurface.serveSession`, which the socket
    /// host also calls — the two transports must serve the same `initialize` and
    /// drain the same way, so there is one implementation of both rather than two
    /// that agree today.
    public static func serve(context: any MCPCallContext, transport: any Transport) async throws {
        try await MCPServerSurface.serveSession(context: context, transport: transport)
    }

    /// Serves MCP on stdin/stdout until the client closes stdin. Does not return:
    /// the caller exits the process.
    ///
    /// Only diagnostics go to stderr, and only if the session could not be
    /// served at all. stdout carries JSON-RPC and nothing else.
    public static func runMain(context: any MCPCallContext = LiveMCPCallContext()) {
        let session = SessionOutcome()

        // Detached so the session is served by the concurrency pool and the main
        // thread stays free to run its run loop. Nothing in `serve` or in
        // `ToolExecutor` is main-actor isolated, so this costs nothing.
        Task.detached(priority: .userInitiated) {
            do {
                try await serve(context: context, transport: StdioTransport())
                session.finish(error: nil)
            } catch {
                session.finish(error: error)
            }
        }

        // Main thread: service the main run loop for as long as the session
        // lasts. This is what lets `SamplingEngine` publish its readings, and it
        // is why the sampler is not left to time out on every live read. Polling
        // `run(until:)` rather than `run()` is deliberate — `run()` returns
        // immediately when the run loop has no sources, which at startup it does
        // not, and would end the process before the first request arrived.
        while !session.isFinished {
            RunLoop.main.run(until: Date().addingTimeInterval(pumpInterval))
        }

        if let error = session.error {
            writeToStandardError("portmaster-mcp: \(error)")
            exit(1)
        }
    }

    /// Diagnostics go to stderr precisely so they cannot corrupt the protocol.
    private static func writeToStandardError(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// How a finished session ended, readable from the main thread that is only
/// running a run loop and cannot `await`.
private final class SessionOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: (any Error)?

    var isFinished: Bool { lock.withLock { finished } }
    var error: (any Error)? { lock.withLock { failure } }

    func finish(error: (any Error)?) {
        lock.withLock {
            failure = error
            finished = true
        }
    }
}

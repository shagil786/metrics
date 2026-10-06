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

    /// The same drain, for a session whose calls are answered by a running app.
    ///
    /// **The on-demand bound above is wrong for the relayed route, and using it there
    /// silently dropped a confirmation.** A relayed mutation under `confirmEach` waits
    /// for a person, up to `SocketMCPClient.callTimeout` — 75 s by construction. The
    /// on-demand drain is ~10 s, so a client that wrote its request and closed stdin
    /// (`printf '…' | portmaster-mcp`, and any one-shot client) had its process exit
    /// while the confirmation was still open: the socket closed, the answer could not
    /// be delivered, and nothing said so. `eofDrainTimeout`'s own comment claims a cap
    /// below the slowest legitimate tool "silently loses the slowest legitimate tool";
    /// slice 2's confirmation *is* that tool, and the cap had not been told.
    ///
    /// Derived from the client's own budget rather than restated, so the two cannot
    /// drift: the drain must outlast the call it is waiting for, plus the same quiet
    /// period the on-demand path uses to be sure nothing started late.
    public static let relayedEofDrainTimeout: TimeInterval =
        SocketMCPClient.callTimeout + eofQuietPeriod

    /// How long shutdown waits for in-flight work, for the route this session chose.
    ///
    /// One function so the choice is a value a test can hold rather than a line
    /// somewhere in `runMain`.
    public static func drainTimeout(relayed: Bool) -> TimeInterval {
        relayed ? relayedEofDrainTimeout : eofDrainTimeout
    }

    /// Serves one session over `transport` and returns when the client is done —
    /// that is, when the transport's input reaches EOF.
    ///
    /// This is the whole server, with no assumption about which thread or run
    /// loop the caller has: everything below belongs to whoever called it. Call
    /// `runMain` for the stdio process.
    ///
    /// `context` is a call surface, not an executor factory, so the same `serve`
    /// serves the on-demand path and the relayed one without knowing which it has.
    ///
    /// `drainTimeout` is threaded through rather than read from the runner because the
    /// socket host also calls `serveSession`, and the two callers have different
    /// budgets — see `relayedEofDrainTimeout`.
    public static func serve(
        context: any MCPToolCalling,
        transport: any Transport,
        drainTimeout: TimeInterval = eofDrainTimeout
    ) async throws {
        try await MCPServerSurface.serveSession(
            context: context, transport: transport, drainTimeout: drainTimeout
        )
    }

    /// Serves MCP on stdin/stdout until the client closes stdin. Does not return:
    /// the caller exits the process.
    ///
    /// With no `context`, the route is chosen **once**, here, before anything is
    /// served: relay to a running Portmaster if there is one, otherwise do the work
    /// this process does exactly as slice 1 did. It is a single decision rather than a
    /// per-call one on purpose — a call must have exactly one authority, and deciding
    /// per call is how a mutation ends up gated twice or answered from two different
    /// snapshots.
    ///
    /// Only diagnostics go to stderr: the route's one line when there is no app to relay
    /// to, and this function's own line if the session could not be served at all. The
    /// first of those is the *normal* path whenever Portmaster is not running, which is
    /// why it is worded as a statement rather than as a failure. stdout carries
    /// JSON-RPC and nothing else.
    ///
    /// - Parameter context: serves this surface instead of routing. For a test that
    ///   wants one specific authority; the executable passes none.
    /// - Parameter drainTimeout: how long shutdown waits for in-flight calls. Passed
    ///   in rather than derived here because only the caller knows the route, and the
    ///   two routes have genuinely different budgets — see `relayedEofDrainTimeout`.
    public static func runMain(context: (any MCPToolCalling)? = nil) {
        let session = SessionOutcome()

        // Detached so the session is served by the concurrency pool and the main
        // thread stays free to run its run loop. Nothing in `serve` or in
        // `ToolExecutor` is main-actor isolated, so this costs nothing.
        Task.detached(priority: .userInitiated) {
            var relayed: SocketMCPClient?
            do {
                let surface: any MCPToolCalling
                let drain: TimeInterval
                if let context {
                    surface = context
                    drain = drainTimeout(relayed: false)
                } else {
                    let route = await MCPRouteSelector.select()
                    if case .proxy(let client) = route { relayed = client }
                    surface = route.context
                    drain = drainTimeout(relayed: relayed != nil)
                }
                try await serve(
                    context: surface, transport: StdioTransport(), drainTimeout: drain
                )
                await relayed?.disconnect()
                session.finish(error: nil)
            } catch {
                // The session is over either way, so a relayed socket is closed either
                // way: a CLI that exits leaving a descriptor and a reader thread behind
                // is a CLI whose exit path is not the one that was tested.
                await relayed?.disconnect()
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

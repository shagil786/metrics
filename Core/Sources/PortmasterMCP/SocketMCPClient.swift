// SocketMCPClient: the CLI's half of slice 2.
//
// Slice 1 made the CLI a server and slice 2 gave the running app one of its own. This is
// the client half of the pair: it presents the token, speaks MCP to whatever is on the
// socket, and forwards a call's name and arguments without ever interpreting them. Where
// the session's authority comes from — and the decision itself — is `MCPRoute`.
//
// Four things here are load-bearing and are stated once each, at the code that does them:
//
//  1. **Nothing is interpreted locally.** No gate, no audit line, no retry, no local
//     re-run on failure. A relayed call has one authority or it has none: re-running it
//     here would apply a second gate to a mutation whose first outcome nobody can see
//     any more, and would answer a caller from a different machine state than the one
//     the app just acted on.
//  2. **Every wait is bounded.** The failure this exists for is the app *disappearing*:
//     the SDK's message loop ends when its input does and leaves a request it already
//     read outstanding, so a call made at that moment waits for a reply that can never
//     arrive. A bound is what turns a wedged app into an error an agent can read.
//  3. **Failures are tool results, never throws.** The host renders tool results and
//     refuses to render transport errors, so a client whose app quit must still receive
//     something readable — and something that invents no outcome.
//  4. **The token goes out once, in the handshake line, and nowhere else.** Read from
//     the endpoint file, written straight to the descriptor, never formed into a
//     diagnostic, an error string, a log line or a payload.
//
// The handshake itself is not reimplemented: `UnixSocketBinding` addresses the socket
// and `UnixSocketTransport` frames MCP over the connected descriptor — the same code the
// host uses, so the two ends cannot drift apart.

import Foundation
import MCP

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Relays tool calls to a running Portmaster over its Unix socket.
///
/// One MCP session per CLI process, opened once in `open()` and used for every call.
/// Not because a session is cheap to rebuild — it is not, there is an `initialize` per
/// one — but because a per-call session would make the app's `ClientRegistry` churn, and
/// a client whose connections come and go is one Settings cannot present sensibly.
public final class SocketMCPClient: MCPToolCalling, @unchecked Sendable {

    /// What a client is told when the app cannot answer. Plain language, no errno, no
    /// socket path, and no suggestion that anything was retried: the honest description
    /// is that the app is not answering, and inventing a cause would send whoever reads
    /// it looking in the wrong place.
    public static let unavailableText =
        "Portmaster isn't running; showing on-demand readings instead."

    /// How long the handshake may take to be *refused*.
    ///
    /// A rejection is silence followed by a close, so "was I admitted?" can only be
    /// answered by watching for the one thing a refusal produces — end of file. There is
    /// no acknowledgement to wait for, which is also why the CLI has no reason to wait
    /// between sending the handshake and sending `initialize`.
    ///
    /// Short, because it is paid on every CLI start with an app running and there is
    /// nothing to wait for: a refusal closes the descriptor as soon as the host has read
    /// the line, which on a local socket is far below this.
    ///
    /// **It is a cooperative-pool cost, and raising it is not a tuning decision.**
    /// `init?` judges the handshake with a blocking read on whatever thread called it,
    /// and its callers are async, so every millisecond here is a millisecond a
    /// cooperative-pool thread spends blocked in `recv`. At 250 ms that is invisible. At
    /// the host's own ten-second handshake timeout it would be a real stall in a pool
    /// sized to the machine's cores — and it would be silent, because nothing about the
    /// code would have changed. A future raise must come with the probe moved off the
    /// pool (see `wasAdmitted`), not on its own.
    static let handshakeSilenceTimeout: TimeInterval = 0.25

    /// How long `initialize` may take before the app is written off.
    ///
    /// ~10× the cost of a probe that works (a local socket, ~250 ms including the
    /// handshake wait), which leaves room for a loaded machine and a cold app without
    /// making a wedged app cost a startup stall anyone would report. The host is
    /// answering MCP on a Unix socket; a healthy one answers in microseconds, so there is
    /// no legitimate case this needs to be large.
    static let probeTimeout: TimeInterval = 2.5

    /// How long one relayed call may take.
    ///
    /// Derived from the read budget a legitimately slow live read is allowed to spend,
    /// so a cold snapshot is never mistaken for a dead app — the same derivation
    /// `MCPStdioRunner.eofDrainTimeout` makes, for the same reason: a cap under the
    /// budget silently loses the slowest call anyone actually makes.
    static let callTimeout: TimeInterval = MCPStdioRunner.eofDrainTimeout

    /// The connected descriptor. Kept rather than reconnected per call, and closed by
    /// `disconnect()`.
    private let socket: UnixSocket

    /// Guards the two pieces of state below. The lock is not about the socket — it is
    /// about a caller on one task and a shutdown on another, which is the whole of what
    /// `disconnect()` races with.
    private let lock = NSLock()
    private var client: Client?
    private var connected = false

    /// A connected, authenticated client, or `nil` — never a throw the caller has to
    /// translate.
    ///
    /// `nil` when the endpoint file is absent or stale, the socket refuses, or the
    /// handshake is refused. Those are the failures a CLI can see synchronously, and
    /// they are one answer: *there is no app here*. The handshake's own outcome is
    /// decided inside `init?` — by watching for the close a refusal produces — and
    /// whether MCP itself came up is `open()`'s, because that part is asynchronous and
    /// `MCPRouteSelector` is what asks.
    ///
    /// This blocks for up to `handshakeSilenceTimeout` doing that judgement, on the
    /// caller's thread. That is a bounded cost accepted on purpose, and the reasoning is
    /// the same as for not using a semaphore: the alternative — blocking on the SDK's
    /// async `connect` from here — would park a cooperative-pool thread for a whole
    /// round trip *and* nest a wait inside the call that has to make progress. A
    /// semaphore does not deadlock this, it would just cost more and prove less; the real
    /// reason to stay synchronous is that `open()` then has a single job (MCP), rather
    /// than also having to re-derive whether it may talk on this descriptor at all.
    /// See the note on `handshakeSilenceTimeout` for the constraint that puts on raising
    /// either number.
    ///
    /// Not throwing is the design, not a convenience: a CLI's startup path has exactly
    /// one fallback, and an `NSError` about a socket would tempt a caller into
    /// surfacing it to an agent as though the agent had done something wrong.
    public init?(endpointDirectory: URL? = nil) {
        // Absent, undecodable, wrong-shaped or stale: `read` does not tell those apart,
        // and a caller could not act differently on each.
        guard let endpoint = EndpointFileStore.read(directory: endpointDirectory),
            let socket = UnixSocketBinding.connect(path: endpoint.socket.path)
        else {
            return nil
        }
        // The one place the token is written. Straight from the file to the descriptor,
        // with no intermediate string that could be logged, described or thrown.
        guard let frame = Self.handshakeFrame(token: endpoint.token) else {
            socket.close()
            return nil
        }
        do {
            try socket.writeAll(frame)
        } catch {
            // The host has gone between the endpoint file being written and this write.
            socket.close()
            return nil
        }
        guard Self.wasAdmitted(socket) else {
            socket.close()
            return nil
        }
        self.socket = socket
    }

    /// Whether MCP is up with the app. False until `open()` has succeeded, and false
    /// again after a disconnect — so it answers "is this client usable", not "did the
    /// descriptor open", which is a question no caller has.
    public var isConnected: Bool { lock.withLock { connected } }

    /// The underlying SDK client, once there is one.
    ///
    /// Internal, and it exists so a test can ask the app a question of its own —
    /// `tools/list` in particular, which cannot be compared against the CLI's own idea
    /// of what the app would say. Every production path goes through `call`, which is
    /// the one that bounds, translates and reports.
    var mcpClient: Client? { lock.withLock { connected ? client : nil } }

    /// Runs one call in the app and reports what it said.
    ///
    /// Never throws and never falls back to a local executor. See the note at the top of
    /// this file: a relayed call has one authority or it has none.
    public func call(name: String, arguments: [String: String]) async -> ToolOutcome {
        guard let client = mcpClient else { return Self.unavailable }
        do {
            let answer: (text: String, isError: Bool)? = try await Self.withDeadline(
                Self.callTimeout
            ) {
                let replied = try await client.callTool(
                    name: name, arguments: Self.payload(arguments)
                )
                return (text: Self.text(of: replied.content), isError: replied.isError ?? false)
            }
            guard let answer else {
                // Presumed wedged rather than gone: stop pretending the session is
                // usable, and say so once.
                MCPDiagnostics.hostFailure(
                    "a relayed MCP call did not answer in time",
                    detail: "pid \(ProcessInfo.processInfo.processIdentifier) asked the app for \(name)"
                )
                await disconnect()
                return Self.unavailable
            }
            return ToolOutcome(text: answer.text, isError: answer.isError)
        } catch {
            // A throw here is a failed write or a JSON-RPC error, never a tool refusal:
            // a refusal arrives as `isError` data, which is the branch above. The
            // session is left alone — a call that failed is not evidence the connection
            // is finished, and every later call is bounded anyway.
            MCPDiagnostics.hostFailure(
                "a relayed MCP call failed on the wire",
                detail: "pid \(ProcessInfo.processInfo.processIdentifier) asked the app for \(name)"
            )
            return Self.unavailable
        }
    }

    /// Completes MCP's `initialize`, or reports that there is no app to talk to.
    ///
    /// Separate from `init?` because this part is asynchronous and `init?` cannot be:
    /// the handshake's *admission* is observable from a descriptor, but whether the app
    /// speaks MCP is a round trip. `MCPRouteSelector` calls this before choosing
    /// `.proxy`, so a socket that opens but does not answer is a fallback rather than a
    /// broken client.
    ///
    /// Returns `false` for every reason there is no app, including the deadline: a host
    /// that accepts the connection and then says nothing is not available, whatever the
    /// endpoint file claims.
    ///
    /// Idempotent, because the alternative is a second `initialize` on a connection the
    /// app is already serving MCP on — which its `Server` answers with "Server is
    /// already initialized", and which would leave a second session in the app's
    /// `ClientRegistry` behind a client that only wanted to ask whether it was up.
    @discardableResult
    public func open() async -> Bool {
        if isConnected { return true }

        let client = Client(name: "portmaster-mcp-cli", version: MCPStdioRunner.serverVersion)
        // The host's own transport, over the descriptor the handshake already left
        // authenticated. There is no pending bytes to seed: the handshake read the
        // connection up to the newline and the SDK's `initialize` goes out afterwards,
        // on a connection the host is already serving MCP on.
        let transport = UnixSocketTransport(socket: socket)
        do {
            let finished = try await Self.withDeadline(Self.probeTimeout) {
                try await client.connect(transport: transport)
                return true
            }
            guard finished == true else {
                await discard(client)
                return false
            }
            lock.withLock {
                self.client = client
                connected = true
            }
            return true
        } catch {
            await discard(client)
            return false
        }
    }

    /// Ends the session: the SDK client first, so any request still outstanding is
    /// released, and the descriptor after.
    public func disconnect() async {
        let client = lock.withLock { () -> Client? in
            connected = false
            defer { self.client = nil }
            return self.client
        }
        await client?.disconnect()
        socket.close()
    }

    // MARK: - Private

    private static var unavailable: ToolOutcome {
        ToolOutcome(text: unavailableText, isError: true)
    }

    /// The handshake line: one `token` key, one newline, nothing else.
    ///
    /// Encoded rather than interpolated, so the shape the host demands — a single-key
    /// object — is guaranteed by construction rather than by care, and so no path through
    /// this file builds a JSON string containing the secret by hand. A nil answer means
    /// the encoder failed, which cannot happen for a string, and is treated as a
    /// handshake that cannot be sent.
    private static func handshakeFrame(token: String) -> Data? {
        let frame = Handshake(token: token)
        guard let data = try? JSONEncoder().encode(frame), !data.isEmpty else { return nil }
        return data + Data([0x0A])
    }

    /// Whether the host kept the connection.
    ///
    /// Silence is the only success signal the handshake has: the host writes nothing to
    /// an admitted client and closes the descriptor to a refused one. So the wait is for
    /// the close, and a deadline that expires means admitted — the honest reading of
    /// "nothing happened", and the only one that does not need the host to change.
    ///
    /// Any byte at all is a refusal of a different kind: the host this connects to
    /// answers a handshake, and nothing on this connection could be framed correctly
    /// after that.
    ///
    /// **This blocks the calling thread**, which is why `handshakeSilenceTimeout` is
    /// 250 ms and carries the warning it does. Moving the wait off the cooperative pool
    /// means reading the descriptor on a thread of its own and handing the answer back —
    /// which is also what a handshake-scale timeout would require.
    private static func wasAdmitted(_ socket: UnixSocket) -> Bool {
        let deadline = Date().addingTimeInterval(handshakeSilenceTimeout)
        var chunk = [UInt8](repeating: 0, count: 512)
        while Date() < deadline {
            switch socket.read(into: &chunk, timeout: deadline.timeIntervalSinceNow) {
            case .bytes, .endOfFile, .failed:
                return false
            case .interrupted:
                // A signal, not an answer. Asking again is the only correct response.
                continue
            case .timedOut:
                return true
            }
        }
        return true
    }

    /// One relayed call, bounded.
    ///
    /// A deadline rather than a `Task.sleep` race written at each call site: the SDK
    /// resumes a pending request when its client disconnects and not when a task is
    /// cancelled, so every caller of this needs the same answer to the same question —
    /// what now — or it leaks a continuation per timeout.
    private static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T? {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            // Whichever finishes first decides; `cancelAll` in the defer stops the other
            // from outliving this, so a slow call cannot keep the CLI's session alive
            // after it has already answered.
            return try await group.next() ?? nil
        }
    }

    /// Closes a session that never opened, releasing anything the SDK left pending.
    private func discard(_ client: Client) async {
        await client.disconnect()
        socket.close()
    }

    /// Arguments as the SDK's own JSON values.
    ///
    /// `nil` rather than an empty object for no arguments, because `ToolExecutor`'s own
    /// readers treat "absent" and "empty" identically and the SDK encodes them
    /// differently on the wire.
    private static func payload(_ arguments: [String: String]) -> [String: Value]? {
        guard !arguments.isEmpty else { return nil }
        return arguments.mapValues { Value.string($0) }
    }

    /// The tool's text out of an MCP result.
    ///
    /// Only the text parts, joined by newlines: this server answers with exactly one
    /// text part per call, and a part it did not send must not appear in the answer a
    /// client reads.
    private static func text(of content: [Tool.Content]) -> String {
        content.compactMap { part in
            guard case .text(let text, _, _) = part else { return nil }
            return text
        }
        .joined(separator: "\n")
    }

    /// The handshake line's own shape. A private type so the only way to build one is the
    /// one key the host accepts.
    private struct Handshake: Encodable {
        let token: String
    }
}

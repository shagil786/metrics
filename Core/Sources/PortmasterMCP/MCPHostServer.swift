// MCPHostServer: the running app as an MCP server.
//
// Slice 1 put the tools on a wire and slice 2 has to make them reachable by something
// other than this process's own stdout. This file is that reach: one `AF_UNIX` socket
// at `~/.portmaster/mcp.sock`, owner-only, serving the same tool surface to any local
// client that can present the token from the endpoint file.
//
// Five decisions are worth stating before the code, because each is a place where the
// obvious thing is the wrong thing:
//
//  1. **The handshake is transport-level, not MCP.** The first line on a connection is
//     `{"token":"…"}` and nothing else; the host reads it itself, before the SDK sees a
//     byte. It is not an MCP method because there is nowhere in the protocol to keep
//     it — no SDK call carries the token, so it cannot leak through a result, a log,
//     or a `tools/list`.
//  2. **A rejected connection gets silence on the wire.** No error, no reply, no MCP
//     frame: the connection is closed and nothing is written. A rejection that answers
//     is a rejection that confirms something is listening. The unified log gets a line;
//     the client does not.
//  3. **The listener is POSIX, not Network.framework.** `NWListener` has no Unix
//     initializer on macOS at all — only `init(using:on: NWEndpoint.Port)` and the
//     launchd/service forms — so a socket here is `socket`/`bind`/`listen`/`accept`.
//     See `UnixSocketBinding`, and the spike in the task report.
//  4. **One `Server` per connection, one shared `context`.** The permission gate has to
//     be rebuilt per call and the sampler must not be: a per-connection context would
//     mean a per-connection engine and a permanently cold snapshot cache. So the
//     context is shared and wrapped, per connection, by a decorator that records when a
//     call was made — which is also how `lastCallAt` is known without touching slice
//     1's wiring.
//  5. **The session itself is not written here.** `MCPServerSurface.serveSession` owns
//     building the `Server`, configuring it, and draining at EOF, and the stdio runner
//     calls the same thing. Two copies of that would be two surfaces that agree today
//     and disagree the day someone edits one.
//
// The rest of the socket machinery is in three neighbours: `UnixSocketBinding` (the
// file at the path and who owns it), `UnixSocket` (the descriptor), and
// `UnixSocketTransport` (the `Transport` the SDK sees).

import Foundation
import MCP

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Serves MCP on a local socket, for as long as the app is running.
public final class MCPHostServer: @unchecked Sendable {

    /// How long a connection has to present its token before it is given up on.
    ///
    /// Bounded because the alternative is unbounded: every socket that connects and
    /// says nothing holds a descriptor and a task until the client goes away, and a
    /// local socket is reachable by anything running as this user.
    static let handshakeTimeout: TimeInterval = 10

    /// Ceiling on `stop()`'s wait for the accept loop. A shutdown that waits forever is
    /// a shutdown the user cannot quit the app through.
    static let shutdownTimeout: TimeInterval = 10

    private let boundSocketURL: URL
    private let endpointDirectory: URL?
    private let context: any MCPToolCalling

    private let lock = NSLock()
    /// The token this launch minted. Read by the handshake check and nowhere else:
    /// never logged, never in an error, never in a payload.
    private var token: String?
    private var listenerDescriptor: Int32 = -1
    /// Which socket *file* this host created, so `stop` can tell its own from one a
    /// later launch has since bound over the path.
    private var socketIdentity: (dev: dev_t, ino: ino_t)?
    private var wakePipe: (read: Int32, write: Int32)?
    private var acceptSemaphore: DispatchSemaphore?
    private var running = false

    private let registry = ClientRegistry()
    /// Reader threads still alive. Observable so a test can prove they are gone: a
    /// reader that never exits is a thread spinning at full speed for the life of the
    /// process, one per connection, and nothing else in the system would show it.
    private var liveReaders = 0

    /// Where blocking handshake reads go, so a read waiting on a client to speak does
    /// not park a cooperative-pool thread.
    private let blockingQueue = DispatchQueue(
        label: "app.portmaster.mcp-host.io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// - Parameters:
    ///   - socketURL: the socket to bind. `~/.portmaster/mcp.sock` in production.
    ///   - endpointDirectory: where the endpoint file goes. `nil` is the per-user
    ///     `~/.portmaster`; a test must never pass `nil`, because that is the one place
    ///     the token would be real.
    ///   - context: the shared call context. Built once and shared by every connection —
    ///     see the note at the top of this file.
    public init(socketURL: URL, endpointDirectory: URL?, context: any MCPToolCalling) {
        self.boundSocketURL = socketURL
        self.endpointDirectory = endpointDirectory
        self.context = context
    }

    public var socketURL: URL { boundSocketURL }

    // MARK: - Lifecycle

    /// Binds, publishes, and starts serving. Returns as soon as the socket is bound;
    /// connections are handled concurrently from then on.
    ///
    /// Throws rather than returning a host that is not serving. This runs on the app's
    /// launch path, where the difference between "the MCP host is not available" and
    /// "the app silently has no MCP host" is the difference between a diagnosable
    /// problem and a mystery.
    public func start() throws {
        // Checked before anything is created. Checked inside the lock below it would be
        // too late: the bind would already have replaced this host's own socket file,
        // and the `running` guard would then return having stored nothing — a bound,
        // untracked descriptor and an endpoint file naming a listener nobody polls.
        guard !lock.withLock({ running }) else {
            throw UnixSocketBinding.failure("this MCP host is already running", code: 0)
        }

        let token = try EndpointFileStore.newToken()
        let listener = try UnixSocketBinding.listen(path: boundSocketURL.path)
        do {
            try EndpointFileStore.write(
                EndpointFile(
                    socket: boundSocketURL,
                    token: token,
                    pid: ProcessInfo.processInfo.processIdentifier
                ),
                directory: endpointDirectory
            )
            try startAcceptLoop(listener)
        } catch {
            // Never leave a bound socket, or an endpoint file, describing a host that
            // is not serving: a later launch would find them, find nothing listening,
            // and be right to replace the socket — while the endpoint file kept
            // advertising this pid.
            close(listener)
            UnixSocketBinding.unlink(path: boundSocketURL.path)
            EndpointFileStore.remove(directory: endpointDirectory)
            MCPDiagnostics.hostFailure("could not start the MCP host", detail: "\(error)")
            throw error
        }

        let identity = UnixSocketBinding.identity(of: boundSocketURL)
        lock.withLock {
            running = true
            self.token = token
            listenerDescriptor = listener
            socketIdentity = identity
        }
    }

    /// Closes the listener, closes every live connection, and takes down the files this
    /// host created.
    ///
    /// The endpoint file is removed **only if it is still ours** — same socket path and
    /// same pid. A second app launch overwrites the endpoint file (last writer wins) and
    /// orphans the first instance's socket; without this check, the instance that lost
    /// would delete the endpoint file of the one that won, and every CLI would fall back
    /// to spawning its own server.
    ///
    /// **It must never block.** This runs on the app's quit path, and the one thing an
    /// app-hosted caller does from another actor while this is in flight is write a
    /// preference through `LiveDataProvider`'s `applyPreference` — which suspends onto
    /// the main actor. If `stop()` were made synchronous (blocking its caller while the
    /// accept thread is joined), a main actor waiting for that write and a main actor
    /// this call is waiting on would be the same thread, and the app would deadlock at
    /// quit. Every wait below therefore suspends (`withCheckedContinuation`), and the
    /// wait on the accept thread is itself handed to a global queue rather than
    /// performed on the caller's actor.
    public func stop() async {
        let shutdown = lock.withLock { () -> (
            Int32, Int32, Int32, DispatchSemaphore, (dev: dev_t, ino: ino_t)?
        )? in
            guard running else { return nil }
            running = false
            token = nil
            let descriptor = listenerDescriptor
            listenerDescriptor = -1
            let pipe = wakePipe
            wakePipe = nil
            let semaphore = acceptSemaphore
            acceptSemaphore = nil
            let identity = socketIdentity
            guard let semaphore else { return nil }
            return (descriptor, pipe?.read ?? -1, pipe?.write ?? -1, semaphore, identity)
        }
        guard let (listener, wakeRead, wakeWrite, threadDone, identity) = shutdown else {
            return
        }

        // Stops accepting and takes every admitted session, atomically. Done before the
        // accept-thread join rather than after, so no session starts during the wait —
        // and it is the *atomicity* that matters, not the ordering: a connection
        // accepted moments before `running` went false can still be inside its ten-second
        // handshake read, and will call `add` after this line. That call returns
        // `.hostClosed` and the connection closes its own socket. Checking `running` in
        // the host and then adding under a second lock would leave a window for exactly
        // that connection to start a session nothing would ever close.
        let live = registry.closeAndTakeAll()

        // Closing each descriptor is what ends the connections: the blocking read
        // returns, the transport finishes its stream, and the SDK's message loop ends
        // with it.
        for connection in live { connection.socket.close() }

        // Wake the accept loop: it is parked in `poll`, and closing the listener out
        // from under it is not something to rely on.
        UnixSocketBinding.signal(wakeWrite)
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = threadDone.wait(timeout: .now() + Self.shutdownTimeout)
                // Safe now that the loop has stopped touching them.
                close(listener)
                if wakeRead >= 0 { close(wakeRead) }
                if wakeWrite >= 0 { close(wakeWrite) }
                continuation.resume()
            }
        }

        if UnixSocketBinding.isOurs(path: boundSocketURL.path, identity: identity) {
            UnixSocketBinding.unlink(path: boundSocketURL.path)
        }
        if claimsEndpointFile() {
            EndpointFileStore.remove(directory: endpointDirectory)
        }
    }

    /// The clients currently authenticated, oldest first.
    public func connectedClients() -> [MCPConnectedClient] { registry.clients() }

    /// Reader threads still running. Internal, and read by tests only: it exists
    /// because a leaked reader is invisible from outside — no crash, no log, just a
    /// process quietly using a core.
    var liveReaderCount: Int { lock.withLock { liveReaders } }

    /// Called with every accepted socket, synchronously, before it is served.
    ///
    /// **Test-only.** It exists for the one property of an
    /// accepted descriptor that nothing outside the process can observe: whether its
    /// writes are prevented from raising `SIGPIPE`. A missing `SO_NOSIGPIPE` has no
    /// crash report and no log line — it terminates the app — so the only way to keep
    /// that honest is to read the option off the descriptor the host actually
    /// accepted. Set at any time — the accept loop reads it per connection, so a test
    /// may install it after `start()` — and `nil` in production, so the accept path
    /// costs one optional read per connection and nothing per sample.
    var onSocketAccepted: (@Sendable (UnixSocket) -> Void)? {
        get { lock.withLock { socketAcceptedObserver } }
        set { lock.withLock { socketAcceptedObserver = newValue } }
    }
    private var socketAcceptedObserver: (@Sendable (UnixSocket) -> Void)?

    // MARK: - Accepting

    private func startAcceptLoop(_ listener: Int32) throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw UnixSocketBinding.failure("cannot create the host's wake pipe", code: errno)
        }
        let semaphore = DispatchSemaphore(value: 0)
        lock.withLock {
            wakePipe = (read: descriptors[0], write: descriptors[1])
            acceptSemaphore = semaphore
        }
        let thread = Thread { [weak self] in
            self?.acceptLoop(listener: listener, wakeDescriptor: descriptors[0])
            semaphore.signal()
        }
        // A dedicated thread that only ever blocks in `poll` and `accept`.
        thread.qualityOfService = .userInitiated
        thread.name = "app.portmaster.mcp-host.accept"
        thread.start()
    }

    /// Parks in `poll` on the listener and the wake pipe, and hands every accepted
    /// descriptor to its own task.
    ///
    /// `poll` on both rather than a bare blocking `accept` because stopping has to be
    /// able to interrupt the wait: closing a descriptor another thread is blocked in
    /// `accept` on is not something to rely on, and a self-pipe is.
    private func acceptLoop(listener: Int32, wakeDescriptor: Int32) {
        while true {
            var descriptors = [
                pollfd(fd: listener, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeDescriptor, events: Int16(POLLIN), revents: 0),
            ]
            let ready = Darwin.poll(&descriptors, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if descriptors[1].revents != 0 { return }
            guard descriptors[0].revents & Int16(POLLIN) != 0 else { continue }

            let accepted = accept(listener, nil, nil)
            if accepted < 0 {
                // A client that vanishes between the connection being made and the
                // accept is an ordinary event, not a reason to stop serving.
                if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
                return
            }
            let socket = UnixSocket(accepted)
            // Outside the lock: the observer is a test's, and a test that blocks
            // here would block `stop()` behind it.
            lock.withLock { socketAcceptedObserver }?(socket)
            guard lock.withLock({ running }) else {
                socket.close()
                return
            }
            // Strong capture, deliberately. A weak one means a deallocated host
            // silently drops the descriptor on the floor: nobody closes it, and it
            // stays open until the process exits. The task's lifetime is already bounded
            // by the socket — it ends at EOF or when `stop()` closes the descriptor — so
            // holding the host for it costs nothing.
            Task { await self.serve(socket) }
        }
    }

    // MARK: - One connection

    /// Reads the handshake, then serves MCP on the same connection until it ends.
    private func serve(_ socket: UnixSocket) async {
        let pid = pid_t(UnixSocketBinding.peerProcessIdentifier(of: socket))

        guard let token = lock.withLock({ self.token }), lock.withLock({ running }) else {
            socket.close()
            MCPDiagnostics.clientRefused(.notRunning, pid: pid)
            return
        }

        // Read here, on the blocking queue, and never handed to the SDK — so an
        // unauthenticated connection never reaches a message loop that could answer it.
        let handshake = await withCheckedContinuation { continuation in
            blockingQueue.async {
                continuation.resume(
                    returning: Self.readHandshake(
                        from: socket, timeout: Self.handshakeTimeout, pid: pid
                    )
                )
            }
        }

        // Silence on the wire, whichever way this goes. See the note at the top of
        // this file.
        guard case .accepted(let frame, let remainder) = handshake else {
            socket.close()
            if case .refused(let reason) = handshake {
                MCPDiagnostics.clientRefused(reason, pid: pid)
            }
            return
        }
        if let refusal = Self.refusal(for: frame, expected: token) {
            socket.close()
            MCPDiagnostics.clientRefused(refusal, pid: pid)
            return
        }

        let identifier = UUID()
        let connection = ClientConnection(id: identifier, pid: pid, socket: socket)

        // Re-checked here, under the host lock, because the check at the top of this
        // function can be ten seconds stale: it happened before the handshake read, and
        // `stop()` may have run since. This narrows the window; `registry.add` is what
        // actually closes it, because that decision and shutdown's are made under one
        // lock.
        guard lock.withLock({ running }) else {
            socket.close()
            MCPDiagnostics.clientRefused(.notRunning, pid: pid)
            return
        }
        switch registry.add(connection, ifUnder: SessionLimit.maximum) {
        case .admitted:
            break
        case .hostClosed:
            socket.close()
            MCPDiagnostics.clientRefused(.notRunning, pid: pid)
            return
        case .atCapacity:
            socket.close()
            MCPDiagnostics.clientRefused(.tooManySessions, pid: pid)
            return
        }

        let transport = UnixSocketTransport(
            socket: socket,
            // Whatever arrived past the handshake newline in the same read. A client
            // that wrote its handshake and its `initialize` together has every reason
            // to — the host sends no acknowledgement, so there is nothing to wait for —
            // and dropping those bytes would hang a correct client until its own
            // timeout.
            pendingBytes: remainder,
            onReaderStart: { [weak self] in self?.readerDidStart() },
            onReaderExit: { [weak self] in self?.readerDidExit() }
        )
        // Wrapped, not replaced: the executor still comes from the caller's context, so
        // the shared provider and the shared sampler survive, while the decorator gets
        // to see that a call happened at all.
        let recording = RecordingContext(base: context) { connection.recordCall() }

        do {
            // The relayed drain, named explicitly. This is one end of a relay whose other
            // end is the CLI, and the two used to disagree about the same logical event:
            // the CLI waited `relayedEofDrainTimeout` for this session's calls to finish
            // while this side took the on-demand default. Nothing observable went wrong —
            // the *client* gives up first either way — but two sides of one relay
            // reasoning about the same deadline differently is the kind of thing that
            // becomes a bug the moment either of them is measured rather than assumed.
            try await MCPServerSurface.serveSession(
                context: recording,
                transport: transport,
                drainTimeout: MCPStdioRunner.relayedEofDrainTimeout
            )
        } catch {
            // Keeping the host up is right — one bad connection is not worth taking the
            // socket down for. Silence is not: this feature's whole failure surface is
            // "the CLI said no such host", and a log line is the difference between that
            // and a `sample` of the app.
            MCPDiagnostics.hostFailure(
                "an MCP connection ended early",
                detail: "pid \(pid): \(error)"
            )
        }

        socket.close()
        registry.remove(id: identifier)
    }

    private func readerDidStart() {
        lock.withLock { liveReaders += 1 }
    }

    private func readerDidExit() {
        lock.withLock { liveReaders -= 1 }
    }

    // MARK: - The handshake

    /// What came of the first line, and everything behind it.
    enum HandshakeOutcome {
        /// The frame, plus the bytes already read past its newline.
        case accepted(Data, remainder: Data)
        case refused(MCPDiagnostics.RefusalReason)
    }

    /// Reads up to the first newline.
    ///
    /// Returns the remainder rather than dropping it: one `read` routinely returns the
    /// handshake *and* the first MCP frame, because they were written together.
    static func readHandshake(
        from socket: UnixSocket,
        timeout: TimeInterval,
        pid: pid_t
    ) -> HandshakeOutcome {
        /// A handshake is one short line. Anything longer is not one, and reading it
        /// would let a client that never sends a newline choose how much memory this
        /// host holds.
        let frameLimit = 4_096

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)

        readLoop: while Date() < deadline {
            if let index = buffer.firstIndex(of: 0x0A) {
                return Self.split(buffer, at: index)
            }
            if buffer.count >= frameLimit {
                return .refused(.handshakeTooLarge)
            }
            switch socket.read(into: &chunk, timeout: deadline.timeIntervalSinceNow) {
            case .bytes(let count):
                buffer.append(contentsOf: chunk[0..<count])
            case .endOfFile:
                return .refused(.noHandshake)
            case .interrupted:
                // A signal, not a refusal. Treating it as one would silently drop a
                // legitimate client that happened to be interrupted while typing.
                continue readLoop
            case .timedOut:
                return .refused(.handshakeTimedOut)
            case .failed(let code):
                // Distinct from a timeout, and it has to be: a descriptor error during a
                // handshake is a fault to look at, while a timeout is a client that went
                // quiet, and reporting one as the other sends whoever reads the log
                // looking in the wrong place.
                MCPDiagnostics.hostFailure(
                    "a handshake read failed",
                    detail: "pid \(pid): \(String(cString: strerror(code)))"
                )
                return .refused(.handshakeFailed)
            }
        }
        // Reachable, and the reason the loop cannot simply give up here: the last read
        // before the deadline can be the one that carries the newline, and by then the
        // loop condition has already failed.
        if let index = buffer.firstIndex(of: 0x0A) { return split(buffer, at: index) }
        return .refused(.handshakeTimedOut)
    }

    private static func split(_ buffer: Data, at index: Data.Index) -> HandshakeOutcome {
        .accepted(
            Data(buffer[buffer.startIndex..<index]),
            remainder: Data(buffer[buffer.index(after: index)...])
        )
    }

    /// Why `frame` is not this launch's token, or `nil` when it is.
    ///
    /// Returns the reason rather than a bare `false` so the log line can say which kind
    /// of wrong it was, from a fixed vocabulary: a message built from what the client
    /// actually sent is a message that can put a token in the unified log, where it
    /// outlives the connection.
    ///
    /// The shape is checked as well as the value — a line carrying anything other than
    /// a single `token` key is not a handshake, whatever else it says — and the
    /// comparison itself is `EndpointFileStore.tokenMatches`, which is not
    /// short-circuiting. `expected` is never empty because it came from `newToken()`.
    private static func refusal(
        for frame: Data,
        expected: String
    ) -> MCPDiagnostics.RefusalReason? {
        guard !expected.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: frame),
            let fields = object as? [String: Any],
            fields.count == 1,
            let candidate = fields["token"] as? String
        else {
            return .malformedHandshake
        }
        return EndpointFileStore.tokenMatches(candidate, expected: expected) ? nil : .wrongToken
    }

    // MARK: - Taking down what this host made

    /// Whether the endpoint file on disk still names this process and this socket.
    ///
    /// Read rather than remembered for the same reason the socket's inode is checked:
    /// another launch may have overwritten it while this one was shutting down, and a
    /// stale host must not take the new host's advertisement with it.
    private func claimsEndpointFile() -> Bool {
        let url = EndpointFileStore.defaultURL(directory: endpointDirectory)
        guard let data = try? Data(contentsOf: url),
            let recorded = try? JSONDecoder().decode(EndpointFile.self, from: data)
        else {
            return false
        }
        return recorded.socket.path == boundSocketURL.path
            && recorded.pid == ProcessInfo.processInfo.processIdentifier
    }
}

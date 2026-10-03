// MCPHostServer: the running app as an MCP server.
//
// Slice 1 put the tools on a wire and slice 2 has to make them reachable by
// something other than this process's own stdout. This file is that reach: one
// `AF_UNIX` socket at `~/.portmaster/mcp.sock`, owner-only, serving the same tool
// surface to any local client that can present the token from the endpoint file.
//
// Four decisions are worth stating before the code, because each of them is a
// place where the obvious thing is the wrong thing:
//
//  1. **The handshake is transport-level, not MCP.** The first line on a connection
//     is `{"token":"…"}` and nothing else; the host reads it itself, before the SDK
//     sees a byte. It is not an MCP method because there is nowhere in the protocol
//     to keep it — no SDK call carries the token, so it cannot leak through a
//     result, a log, or a `tools/list`.
//  2. **A rejected connection gets silence.** No error, no reply, no MCP frame:
//     the connection is closed and nothing is written. A rejection that answers is
//     a rejection that confirms something is listening.
//  3. **The listener is POSIX, not Network.framework.** `NWListener` has no Unix
//     initializer on macOS at all — only `init(using:on: NWEndpoint.Port)` and the
//     launchd/service forms — so a socket here is `socket`/`bind`/`listen`/`accept`.
//     See the spike in the task report.
//  4. **One `Server` per connection, one shared `context`.** The permission gate has
//     to be rebuilt per call (`MCPServerSurface`), and the sampler must not be — a
//     per-connection context would mean a per-connection engine and a permanently
//     cold snapshot cache. So the context is shared and wrapped, per connection, by a
//     decorator that records when a call was made — which is also how `lastCallAt`
//     is known without touching slice 1's wiring.

import Foundation
import Logging
import MCP

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

// MARK: - Connected clients

/// One authenticated client, as Settings shows it.
///
/// Deliberately three fields. The token is what makes this connection legitimate,
/// and Settings must never be one more place it can be read from — so a client is
/// identified by who it is and when it acted, and nothing else.
public struct MCPConnectedClient: Identifiable, Sendable {
    /// The peer process, or 0 when the OS will not say. Two connections from one
    /// peer share an `id`; that is the trade for an id the user can recognise.
    public let id: pid_t
    public let connectedAt: Date
    /// When this client last *called a tool*. `initialize` and `tools/list` do not
    /// count: a client that connected and asked nothing has not called anything.
    public var lastCallAt: Date?

    public init(id: pid_t, connectedAt: Date, lastCallAt: Date? = nil) {
        self.id = id
        self.connectedAt = connectedAt
        self.lastCallAt = lastCallAt
    }
}

// MARK: - The host

/// Serves MCP on a local socket, for as long as the app is running.
public final class MCPHostServer: @unchecked Sendable {

    /// How long a connection has to present its token before it is given up on.
    ///
    /// Bounded because the alternative is unbounded: every socket that connects and
    /// says nothing holds a descriptor and a task until the client goes away, and a
    /// local socket is reachable by anything running as this user.
    static let handshakeTimeout: TimeInterval = 10

    /// Largest single newline-delimited frame accepted from a client. Generous
    /// against the largest `tools/call` result this server can produce and small
    /// enough that a client which never sends a newline cannot grow the host without
    /// limit.
    static let maximumFrameBytes = 4 * 1024 * 1024

    /// Ceiling on `stop()`'s wait for the accept loop and the live connections.
    /// A shutdown that waits forever is a shutdown the user cannot quit the app
    /// through, so every wait here is bounded.
    static let shutdownTimeout: TimeInterval = 10

    private let boundSocketURL: URL
    private let endpointDirectory: URL?
    private let context: any MCPCallContext

    private let lock = NSLock()
    /// The token this launch minted. Read by the handshake check and nowhere else:
    /// never logged, never in an error, never in a payload.
    private var token: String?
    private var listenerDescriptor: Int32 = -1
    /// `(device, inode)` of the socket file this host created, so `stop` can tell
    /// its own socket from one a later launch has since bound over the path.
    private var socketIdentity: (dev: dev_t, ino: ino_t)?
    private var clients: [UUID: ClientConnection] = [:]
    private var running = false

    /// Where blocking handshake reads and frame writes go, so neither parks a
    /// cooperative-pool thread on a descriptor that may never answer.
    private let blockingQueue = DispatchQueue(
        label: "app.portmaster.mcp-host.io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// - Parameters:
    ///   - socketURL: the socket to bind. `~/.portmaster/mcp.sock` in production.
    ///   - endpointDirectory: where the endpoint file goes. `nil` is the per-user
    ///     `~/.portmaster`; a test must never pass `nil`, because that is the one
    ///     place the token would be real.
    ///   - context: the shared call context. Built once and shared by every
    ///     connection — see the note at the top of this file.
    public init(socketURL: URL, endpointDirectory: URL?, context: any MCPCallContext) {
        self.boundSocketURL = socketURL
        self.endpointDirectory = endpointDirectory
        self.context = context
    }

    public var socketURL: URL { boundSocketURL }

    // MARK: Lifecycle

    /// Binds, publishes, and starts serving. Returns as soon as the socket is bound;
    /// connections are handled concurrently from then on.
    ///
    /// Throws rather than returning a host that is not serving. This runs on the
    /// app's launch path, where the difference between "the MCP host is not
    /// available" and "the app silently has no MCP host" is the difference between a
    /// diagnosable problem and a mystery.
    public func start() throws {
        let token = try EndpointFileStore.newToken()
        let listener = try Self.bind(path: boundSocketURL.path)
        do {
            try EndpointFileStore.write(
                EndpointFile(
                    socket: boundSocketURL,
                    token: token,
                    pid: ProcessInfo.processInfo.processIdentifier
                ),
                directory: endpointDirectory
            )
        } catch {
            // Never leave a bound socket with nothing describing it: a later launch
            // would find it, find nothing listening, and be right to replace it —
            // but this launch would be advertising an endpoint it cannot serve.
            close(listener)
            Self.unlink(path: boundSocketURL.path)
            throw error
        }

        let identity = Self.identity(of: boundSocketURL)
        lock.withLock {
            guard !running else { return }
            running = true
            self.token = token
            listenerDescriptor = listener
            socketIdentity = identity
        }
        do {
            try startAcceptLoop(listener)
        } catch {
            close(listener)
            Self.unlink(path: boundSocketURL.path)
            EndpointFileStore.remove(directory: endpointDirectory)
            lock.withLock {
                running = false
                self.token = nil
                listenerDescriptor = -1
                socketIdentity = nil
            }
            throw error
        }
    }

    /// Closes the listener, closes every live connection, and takes down the files
    /// this host created.
    ///
    /// The endpoint file is removed **only if it is still ours** — same socket path
    /// and same pid. A second app launch overwrites the endpoint file (last writer
    /// wins) and orphans the first instance's socket; without this check, the
    /// instance that lost would delete the endpoint file of the one that won, and
    /// every CLI would fall back to spawning its own server.
    public func stop() async {
        let shutdown = lock.withLock { () -> (
            Int32, Int32, Int32, DispatchSemaphore, [ClientConnection], (dev: dev_t, ino: ino_t)?
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
            let live = Array(clients.values)
            clients.removeAll()
            guard let semaphore else { return nil }
            return (
                descriptor, pipe?.read ?? -1, pipe?.write ?? -1, semaphore, live, identity
            )
        }
        guard let (listener, wakeRead, wakeWrite, threadDone, connections, identity) = shutdown
        else {
            return
        }

        // Wake the accept loop first: it is parked in `poll`, and closing the
        // listener out from under it is not something to rely on.
        Self.signal(wakeWrite)
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

        // Closing each descriptor is what ends the connections: a blocking read
        // returns, the transport finishes its stream, and the SDK's message loop
        // ends with it.
        for connection in connections { connection.socket.close() }

        if Self.isOurs(path: boundSocketURL.path, identity: identity) {
            Self.unlink(path: boundSocketURL.path)
        }
        if claimsEndpointFile() {
            EndpointFileStore.remove(directory: endpointDirectory)
        }
    }

    /// The clients currently authenticated, oldest first.
    public func connectedClients() -> [MCPConnectedClient] {
        lock.withLock {
            clients.values
                .map(\.client)
                .sorted { $0.connectedAt < $1.connectedAt }
        }
    }

    // MARK: - Accepting

    /// The self-pipe `stop` pokes to interrupt the accept loop, and the semaphore the
    /// accept thread signals on its way out. Created once in `start`, because both
    /// are needed on the path `stop` takes and neither can be allowed to fail there.
    private var wakePipe: (read: Int32, write: Int32)?
    private var acceptSemaphore: DispatchSemaphore?

    private func startAcceptLoop(_ listener: Int32) throws {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw Self.failure("cannot create the host's wake pipe", code: errno)
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
    /// `poll` on both rather than a bare blocking `accept` because stopping has to
    /// be able to interrupt the wait: closing a descriptor another thread is blocked
    /// in `accept` on is not something to rely on, and a self-pipe is.
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
                // A client that vanishes between the handshake completing and the
                // accept is an ordinary event, not a reason to stop serving.
                if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
                return
            }
            let descriptor = UnixSocket(accepted)
            lock.withLock {
                guard running else {
                    descriptor.close()
                    return
                }
            }
            Task { [weak self] in await self?.serve(descriptor) }
        }
    }

    // MARK: - One connection

    /// Reads the handshake, then serves MCP on the same connection until it ends.
    private func serve(_ socket: UnixSocket) async {
        let token = lock.withLock { self.token }
        guard let token else {
            socket.close()
            return
        }

        // The handshake is read here, on the blocking queue, and never handed to the
        // SDK — so an unauthenticated connection never reaches a message loop that
        // could answer it.
        let line = await withCheckedContinuation { continuation in
            blockingQueue.async {
                continuation.resume(
                    returning: Self.readFrame(from: socket, timeout: Self.handshakeTimeout)
                )
            }
        }

        guard let line, Self.isAuthenticated(line, expected: token) else {
            // Silence. No bytes out, no log line, no error — see the note at the top
            // of this file.
            socket.close()
            return
        }

        let identifier = UUID()
        let connection = ClientConnection(
            id: pid_t(Self.peerProcessIdentifier(of: socket)),
            socket: socket
        )
        lock.withLock {
            guard running else {
                socket.close()
                return
            }
            clients[identifier] = connection
        }

        let transport = UnixSocketTransport(socket: socket)
        let server = Self.makeServer()
        // Wrapped, not replaced: the executor still comes from the caller's context,
        // so the shared provider and the shared sampler survive, while the decorator
        // gets to see that a call happened at all.
        let recording = RecordingContext(base: context) { connection.recordCall() }
        do {
            let tracker = await MCPServerSurface.configure(server, context: recording)
            try await server.start(transport: transport)
            await server.waitUntilCompleted()
            // Same drain as the stdio surface: the SDK's loop ends at EOF without
            // waiting for the handler tasks it spawned on the way there.
            await tracker.waitUntilIdle(
                quiet: MCPStdioRunner.eofQuietPeriod,
                timeout: MCPStdioRunner.eofDrainTimeout
            )
            await server.stop()
        } catch {
            // A connection that cannot be served is that connection's problem. The
            // host stays up: nothing here is worth taking the socket down for.
            await server.stop()
        }

        socket.close()
        lock.withLock { _ = clients.removeValue(forKey: identifier) }
    }

    /// The same `Server` the stdio surface serves, built from the same constants so
    /// a client cannot tell the two transports apart from `initialize`. Kept here
    /// rather than factored into `MCPServerSurface` so slice 1 is untouched; the two
    /// shapes have to stay in step, and this is the place to look if they drift.
    private static func makeServer() -> Server {
        Server(
            name: MCPStdioRunner.serverName,
            version: MCPStdioRunner.serverVersion,
            instructions: MCPStdioRunner.instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    // MARK: - The handshake

    /// Whether the first line is this launch's token and nothing else.
    ///
    /// The shape is checked as well as the value: a line carrying anything other
    /// than a single `token` key is not a handshake, whatever else it says. The
    /// comparison itself is `EndpointFileStore.tokenMatches`, which is not
    /// short-circuiting, and `expected` is never empty because it came from
    /// `newToken()`.
    private static func isAuthenticated(_ frame: Data, expected: String) -> Bool {
        guard !expected.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: frame),
            let fields = object as? [String: Any],
            fields.count == 1,
            let candidate = fields["token"] as? String
        else {
            return false
        }
        return EndpointFileStore.tokenMatches(candidate, expected: expected)
    }

    /// Reads up to the first newline, or returns nil on EOF, timeout, or a frame too
    /// large to be a handshake.
    static func readFrame(from socket: UnixSocket, timeout: TimeInterval) -> Data? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)

        while Date() < deadline {
            if let index = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[buffer.startIndex..<index])
            }
            guard buffer.count < Self.handshakeFrameLimit else { return nil }

            let read = socket.read(into: &chunk, timeout: deadline.timeIntervalSinceNow)
            switch read {
            case .bytes(let count):
                buffer.append(contentsOf: chunk[0..<count])
            case .endOfFile:
                return nil  // EOF: the client closed without authenticating.
            case .failed, .timedOut:
                return nil  // Timed out, or the descriptor is gone.
            }
        }
        // Reachable, and the reason the loop cannot simply give up here: the last
        // read before the deadline can be the one that carries the newline, and by
        // then the loop condition has already failed.
        return buffer.firstIndex(of: 0x0A).map { Data(buffer[buffer.startIndex..<$0]) }
    }

    /// A handshake is one short line. Anything longer is not one, and reading it
    /// would let a client that never sends a newline choose how much memory this
    /// host holds.
    private static let handshakeFrameLimit = 4_096

    // MARK: - Binding

    /// Creates, binds, tightens and listens on a Unix socket.
    ///
    /// The `0600` is set explicitly rather than left to the umask: `bind` creates
    /// the file at `0777 & ~umask`, which under the usual `022` is `0755` and lets
    /// any other local process connect and be handed a socket. The containing
    /// directory is created `0700` first, for the same reason.
    static func bind(path: String) throws -> Int32 {
        let containing = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: containing,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.removeStaleSocket(at: path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw failure("cannot create a socket for \(path)", code: errno)
        }
        // Deliberately no SO_REUSEADDR. It buys nothing for an `AF_UNIX` socket —
        // there is no TIME_WAIT to outlive — and on Darwin it permits binding over a
        // path another process is already listening on, which is exactly the case
        // `removeStaleSocket` exists to refuse.
        var address = try Self.socketAddress(path: path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw failure("cannot bind \(path)", code: code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(descriptor)
            Self.unlink(path: path)
            throw failure("cannot restrict \(path) to its owner", code: code)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            Self.unlink(path: path)
            throw failure("cannot listen on \(path)", code: code)
        }
        return descriptor
    }

    /// Removes whatever is at the socket path, unless something is listening on it.
    ///
    /// A socket file outlives the process that made it — every crash, every force
    /// quit leaves one — and binding over it fails with `EADDRINUSE`. Connecting
    /// first is what tells a leftover from a live host: refused means there is
    /// nothing there, and a successful connect means there is, and that is not this
    /// host's socket to delete.
    static func removeStaleSocket(at path: String) throws {
        // Checked before anything is removed, so an unbindable path is reported as
        // itself rather than quietly treated as absent.
        _ = try Self.socketAddress(path: path)
        var status = stat()
        guard lstat(path, &status) == 0 else { return }  // Nothing there at all.
        if (status.st_mode & S_IFMT) == S_IFSOCK, Self.isListening(at: path) {
            throw failure("another process is already listening on \(path)", code: EADDRINUSE)
        }
        Self.unlink(path: path)
    }

    /// Whether a connection to `path` is accepted. A connect to a socket file with
    /// no listener behind it fails with `ECONNREFUSED` — that answer is the only
    /// difference between a leftover and a live host.
    private static func isListening(at path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        guard var address = try? Self.socketAddress(path: path) else { return false }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    /// `sockaddr_un` for `path`.
    ///
    /// Throws rather than truncating: a truncated path would bind a socket at a
    /// *different* place from the one published in the endpoint file, and the
    /// symptom of that would be a CLI that reads a perfectly good endpoint and
    /// cannot reach anything. And it throws rather than trapping, because this is
    /// reached from the app's launch path.
    static func socketAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw failure(
                """
                the socket path is \(bytes.count) bytes and sockaddr_un holds \
                \(capacity - 1); it cannot be bound
                """,
                code: ENAMETOOLONG
            )
        }
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            destination.withMemoryRebound(to: CChar.self, capacity: capacity) { chars in
                _ = bytes.withUnsafeBytes { source in
                    memcpy(chars, source.baseAddress!, bytes.count)
                }
                chars[bytes.count] = 0
            }
        }
        return address
    }

    // MARK: - Taking down what this host made

    /// Whether the socket file at `path` is still the inode this host created.
    ///
    /// A second launch binds the same path and gets a new inode; unlinking on the
    /// strength of "the path matches" would delete a live host's socket.
    private static func isOurs(path: String, identity: (dev: dev_t, ino: ino_t)?) -> Bool {
        guard let identity else { return false }
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return status.st_dev == identity.dev && status.st_ino == identity.ino
    }

    /// Whether the endpoint file on disk still names this process and this socket.
    ///
    /// Read rather than remembered for the same reason: another launch may have
    /// overwritten it while this one was shutting down, and a stale host must not
    /// take the new host's advertisement with it.
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

    private static func identity(of url: URL) -> (dev: dev_t, ino: ino_t)? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return (status.st_dev, status.st_ino)
    }

    private static func unlink(path: String) {
        _ = Darwin.unlink(path)
    }

    private static func signal(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        var byte: UInt8 = 1
        _ = withUnsafeBytes(of: &byte) { Darwin.write(descriptor, $0.baseAddress, 1) }
    }

    /// The peer pid behind a Unix socket, or 0 when the kernel will not say.
    ///
    /// `LOCAL_PEERPID` is the only way to get it — `getpeereid` gives effective
    /// *uids*, not processes — and it is a `getsockopt` that can simply fail, on a
    /// socket type that does not carry the answer. A client that cannot be named is
    /// still a client; it is shown as pid 0 rather than not shown at all.
    private static func peerProcessIdentifier(of socket: UnixSocket) -> pid_t {
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        let result = withUnsafeMutablePointer(to: &peer) { pointer in
            getsockopt(
                socket.descriptor, SOL_LOCAL, LOCAL_PEERPID,
                pointer, &size
            )
        }
        guard result == 0, peer > 0 else { return 0 }
        return peer
    }

    private static func failure(_ message: String, code: Int32) -> NSError {
        let description = code == 0 ? message : "\(message): \(String(cString: strerror(code)))"
        return NSError(
            domain: "PortmasterMCP.MCPHostServer",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

// MARK: - Connection bookkeeping

/// One live connection: who it is, its descriptor (so `stop` can reach it), and
/// when it last called.
///
/// Self-contained on purpose — it owns its own lock and stamps itself, so recording
/// a call never has to reach back into the host. A callback from here into the host
/// that then asked this to record again is a cycle, and cycles on a tool-call path
/// are not something to debug under load.
private final class ClientConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: MCPConnectedClient
    let socket: UnixSocket

    init(id: pid_t, socket: UnixSocket) {
        self.socket = socket
        self.stored = MCPConnectedClient(id: id, connectedAt: Date())
    }

    var client: MCPConnectedClient { lock.withLock { stored } }

    func recordCall() { lock.withLock { stored.lastCallAt = Date() } }
}

/// Stamps the connection's `lastCallAt` every time an executor is asked for.
///
/// The stamp is the point, and it is exact: `MCPCallContext.makeExecutor` is called
/// once per `tools/call` and never once per process, so this fires for tool calls
/// and for nothing else. No slice-1 wiring is changed to arrange it.
private struct RecordingContext: MCPCallContext {
    let base: any MCPCallContext
    let onCall: @Sendable () -> Void

    func makeExecutor() -> ToolExecutor {
        onCall()
        return base.makeExecutor()
    }
}

// MARK: - The descriptor

/// One connected `AF_UNIX` descriptor, closeable exactly once.
///
/// The reference count of owners is the reason this exists rather than a bare
/// `Int32`: `stop()` closes a live connection from another thread while that
/// connection's own task is reading or writing it, and a double close would close a
/// descriptor the kernel has since handed to something else.
final class UnixSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32

    init(_ descriptor: Int32) {
        stored = descriptor
    }

    /// The raw descriptor, for the calls that need one (`getsockopt`). Only valid
    /// while the socket is open.
    var descriptor: Int32 { lock.withLock { stored } }
    func close() {
        let descriptor = lock.withLock { () -> Int32 in
            defer { stored = -1 }
            return stored
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    enum ReadResult {
        case bytes(Int)
        case timedOut
        case endOfFile
        case failed(Int32)
    }

    /// One `read`, bounded by `timeout`.
    ///
    /// The deadline is written on **every** call rather than left as whatever the
    /// previous reader set. `SO_RCVTIMEO` is per-descriptor and this descriptor has
    /// two readers with different deadlines: the handshake, which has ten seconds,
    /// and the MCP session, which has none. A session that inherited the handshake's
    /// window would end the first time a client thought for ten seconds — and then
    /// spin, because the reader treats `EAGAIN` as "try again" and would do so for
    /// as long as the descriptor lived.
    ///
    /// `EAGAIN` is reported as `timedOut` so a caller looping until a newline can
    /// tell "nothing yet" from "no longer possible".
    func read(into buffer: inout [UInt8], timeout: TimeInterval) -> ReadResult {
        let descriptor = lock.withLock { stored }
        guard descriptor >= 0 else { return .endOfFile }
        var window: timeval
        if timeout.isFinite {
            let whole = max(0, timeout)
            window = timeval(
                tv_sec: Int(whole.rounded(.down)),
                tv_usec: Int32(((whole - floor(whole)) * 1_000_000).rounded(.down))
            )
        } else {
            // `{0, 0}` is POSIX for "no deadline": block until a byte arrives. It has
            // to be written explicitly, because "leave it alone" would mean leaving
            // behind whichever window the last reader installed.
            window = timeval(tv_sec: 0, tv_usec: 0)
        }
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &window,
            socklen_t(MemoryLayout.size(ofValue: window))
        )

        let count = buffer.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }
        if count > 0 { return .bytes(count) }
        if count == 0 { return .endOfFile }
        switch errno {
        case EINTR, EAGAIN: return .timedOut
        default: return .failed(errno)
        }
    }

    /// Writes all of `data`, looping over partial writes.
    func writeAll(_ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let descriptor = lock.withLock { stored }
            guard descriptor >= 0 else {
                throw NSError(
                    domain: "PortmasterMCP.MCPHostServer", code: Int(EPIPE),
                    userInfo: [NSLocalizedDescriptionKey: "the client closed the connection"]
                )
            }
            let written = remaining.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw NSError(
                    domain: "PortmasterMCP.MCPHostServer", code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
            guard written > 0 else {
                throw NSError(
                    domain: "PortmasterMCP.MCPHostServer", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "zero-byte write to the client"]
                )
            }
            remaining = remaining.dropFirst(written)
        }
    }
}

// MARK: - The transport

/// An MCP `Transport` over an accepted Unix descriptor, framed with
/// newline-delimited JSON.
///
/// Written rather than reused, for one reason: the SDK's `NetworkTransport` takes
/// an `NWConnection` and *starts* it, so there is nowhere to put a handshake that
/// has to precede every MCP message — and its host side could not be used anyway,
/// since `NWListener` cannot bind a Unix path on macOS. The framing is the same as
/// the SDK's stdio transport, so the server sees the bytes it already knows.
///
/// Reads run on their own thread: the descriptor is blocking, and a read that waits
/// for a client to think must not park a cooperative-pool thread while it does.
actor UnixSocketTransport: Transport {

    /// No-op, like the SDK's own transports: this host has no logging facility, and
    /// the one thing that must never reach a log — the token — never passes through
    /// here anyway.
    nonisolated public let logger = Logger(
        label: "mcp.transport.unix-socket",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private nonisolated let socket: UnixSocket
    private nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private nonisolated let stream: AsyncThrowingStream<Data, Error>
    /// Writes are serialised through one queue so two replies cannot interleave
    /// halves of a frame.
    private nonisolated let writeQueue = DispatchQueue(label: "app.portmaster.mcp-host.write")
    private var started = false

    init(socket: UnixSocket) {
        self.socket = socket
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    /// The descriptor is already connected — it came from `accept` — so this only
    /// starts the reader.
    public func connect() async throws {
        guard !started else { return }
        started = true
        let socket = self.socket
        let continuation = self.continuation
        let maximum = MCPHostServer.maximumFrameBytes
        let thread = Thread { [weak self] in
            Self.readLoop(
                socket: socket,
                continuation: continuation,
                maximumFrameBytes: maximum,
                onEnd: { [weak self] in Task { await self?.disconnect() } }
            )
        }
        thread.name = "app.portmaster.mcp-host.read"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func disconnect() async {
        socket.close()
        continuation.finish()
    }

    /// Frames with a newline, the same delimiter the SDK's stdio and network
    /// transports use.
    public func send(_ message: Data) async throws {
        let socket = self.socket
        var framed = message
        framed.append(0x0A)
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                do {
                    try socket.writeAll(framed)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> { stream }

    /// Splits the byte stream into frames on newlines, the inverse of `send`.
    ///
    /// Ends the stream on EOF, which is what tells the SDK's message loop the client
    /// is gone — the same signal stdin closing gives the stdio surface.
    private static func readLoop(
        socket: UnixSocket,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        maximumFrameBytes: Int,
        onEnd: @escaping @Sendable () -> Void
    ) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        // No deadline: once a client is authenticated, an MCP session is idle more
        // often than not, and a read timeout here would end a quiet session.
        while true {
            switch socket.read(into: &chunk, timeout: .infinity) {
            case .bytes(let count):
                buffer.append(contentsOf: chunk[0..<count])
                while let index = buffer.firstIndex(of: 0x0A) {
                    let frame = Data(buffer[buffer.startIndex..<index])
                    buffer.removeSubrange(buffer.startIndex...index)
                    // An empty line is framing, not a message; MCP has nothing to
                    // say about one and the SDK would only answer it with an error.
                    if !frame.isEmpty { continuation.yield(frame) }
                }
                if buffer.count > maximumFrameBytes {
                    continuation.finish(throwing: NSError(
                        domain: "PortmasterMCP.MCPHostServer", code: Int(EMSGSIZE),
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "a client sent a frame larger than \(maximumFrameBytes) bytes"
                        ]
                    ))
                    break
                }
            case .endOfFile:
                continuation.finish()
                break
            case .timedOut:
                continue
            case .failed:
                // The descriptor was closed out from under this read — which is how
                // `stop()` ends a session — so an unfinished frame is not an error
                // to report to anyone.
                continuation.finish()
                break
            }
        }
        onEnd()
    }
}

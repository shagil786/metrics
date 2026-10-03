// UnixSocketTransport: an MCP `Transport` over an accepted Unix descriptor.
//
// Written rather than reused, for one reason: the SDK's `NetworkTransport` takes an
// `NWConnection` and *starts* it, so there is nowhere to put a handshake that has to
// precede every MCP message — and its host side could not be used anyway, since
// `NWListener` cannot bind a Unix path on macOS. The framing is the same as the SDK's
// stdio transport, so the server sees the bytes it already knows.

import Foundation
import Logging
import MCP

/// Frames MCP messages with newlines over a Unix socket.
///
/// Reads run on their own thread: the descriptor is blocking, and a read that waits
/// for a client to think must not park a cooperative-pool thread while it does.
actor UnixSocketTransport: Transport {

    /// Largest single frame accepted from a client. Generous against the largest
    /// `tools/call` result this server can produce, and small enough that a client
    /// which never sends a newline cannot grow the host without limit.
    static let maximumFrameBytes = 4 * 1024 * 1024

    /// No-op, like the SDK's own transports. Diagnostics about *this host's* failures
    /// go through `MCPDiagnostics` to the unified log; what the SDK would log here is
    /// per-frame noise about a client that is behaving, and the default swift-log
    /// handler writes to stdout — which on this project's stdio transport is the
    /// JSON-RPC channel.
    nonisolated public let logger = Logger(
        label: "mcp.transport.unix-socket",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private nonisolated let socket: UnixSocket
    private nonisolated let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private nonisolated let stream: AsyncThrowingStream<Data, Error>
    /// Writes are serialised through one queue so two replies cannot interleave halves
    /// of a frame.
    private nonisolated let writeQueue = DispatchQueue(label: "app.portmaster.mcp-host.write")
    private var started = false

    /// - Parameters:
    ///   - socket: the accepted descriptor.
    ///   - pendingBytes: frames already read from `socket` before this transport
    ///     existed. The handshake read usually pulls more than the handshake line off
    ///     the descriptor in one go, and a client that wrote its handshake and its
    ///     `initialize` together — which it has every reason to, since the host sends
    ///     no acknowledgement — must not lose the second one. Dropping them would hang
    ///     a correct client until its own timeout.
    ///   - onReaderStart: called as the reader thread starts, and `onReaderExit` as it
    ///     finishes, for any reason. Paired, and both driven from inside `connect`, so
    ///     the count a test watches tracks *threads* exactly. Counting from the caller's
    ///     side instead would drift whenever the session failed before `connect` ran.
    ///     This is what a test watches to prove a reader is gone: a reader that never
    ///     exits is a thread spinning at full speed for the life of the process, and
    ///     nothing else in the system would show it.
    init(
        socket: UnixSocket,
        pendingBytes: Data = Data(),
        onReaderStart: @escaping @Sendable () -> Void = {},
        onReaderExit: @escaping @Sendable () -> Void = {}
    ) {
        self.socket = socket
        self.pendingBytes = pendingBytes
        self.onReaderStart = onReaderStart
        self.onReaderExit = onReaderExit
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { captured = $0 }
        continuation = captured
    }

    private nonisolated let pendingBytes: Data
    private nonisolated let onReaderStart: @Sendable () -> Void
    private nonisolated let onReaderExit: @Sendable () -> Void

    /// The descriptor is already connected — it came from `accept` — so this only
    /// starts the reader.
    public func connect() async throws {
        guard !started else { return }
        started = true
        let socket = self.socket
        let continuation = self.continuation
        let seeded = pendingBytes
        let didStart = onReaderStart
        let didEnd = onReaderExit
        // Bound once, here, rather than capturing `self` weakly in both the thread's
        // closure and the one nested inside it: the inner capture would then be a
        // reference to a captured `var`, which is not safe to read off another thread.
        weak let weakSelf = self
        let thread = Thread {
            Self.readLoop(
                socket: socket,
                seeded: seeded,
                continuation: continuation,
                onEnd: {
                    didEnd()
                    Task { await weakSelf?.disconnect() }
                }
            )
        }
        thread.name = "app.portmaster.mcp-host.read"
        thread.qualityOfService = .userInitiated
        // Counted before `start`, not after: the thread exists from this line on, and a
        // test that reads the count first must never see a thread it cannot account for.
        didStart()
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
    /// Ends the stream on EOF, which is what tells the SDK's message loop the client is
    /// gone — the same signal stdin closing gives the stdio surface.
    ///
    /// The loop is **labelled** and every exit breaks the label, not the `switch`.
    /// Unlabelled `break` inside a `switch` case leaves the switch and returns to the
    /// top of this loop, which on EOF means reading a closed descriptor forever: a
    /// thread at full CPU for the life of the process, one per connection, and a
    /// continuation that is never finished so the server's drain never returns either.
    private static func readLoop(
        socket: UnixSocket,
        seeded: Data,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        onEnd: @Sendable () -> Void
    ) {
        var buffer = seeded
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)

        func drainFrames() {
            while let index = buffer.firstIndex(of: 0x0A) {
                let frame = Data(buffer[buffer.startIndex..<index])
                buffer.removeSubrange(buffer.startIndex...index)
                // An empty line is framing, not a message; MCP has nothing to say
                // about one and the SDK would only answer it with an error.
                if !frame.isEmpty { continuation.yield(frame) }
            }
        }

        // `seeded` was read before this thread existed, so it is already framed.
        drainFrames()

        readLoop: while true {
            // No deadline: once a client is authenticated, an MCP session is idle more
            // often than not, and a read timeout here would end a quiet session.
            switch socket.read(into: &chunk, timeout: .infinity) {
            case .bytes(let count):
                buffer.append(contentsOf: chunk[0..<count])
                drainFrames()
                if buffer.count > maximumFrameBytes {
                    continuation.finish(throwing: UnixSocketTransport.frameTooLarge(
                        maximumFrameBytes
                    ))
                    break readLoop
                }
            case .endOfFile:
                continuation.finish()
                break readLoop
            case .interrupted:
                // A signal, not an ending. Falling through to the top of the loop and
                // reading again is the whole correct response.
                continue readLoop
            case .timedOut:
                // Unreachable while the window is `{0, 0}`, but "no deadline" should not
                // depend on that staying true: treat it as nothing to do, never as an
                // end, and never as a reason to stop reading.
                continue readLoop
            case .failed:
                // The descriptor was closed out from under this read — which is how
                // `stop()` ends a session — so an unfinished frame is not an error to
                // report to anyone.
                continuation.finish()
                break readLoop
            }
        }
        onEnd()
    }

    static func frameTooLarge(_ limit: Int) -> NSError {
        NSError(
            domain: "PortmasterMCP.MCPHostServer", code: Int(EMSGSIZE),
            userInfo: [
                NSLocalizedDescriptionKey: "a client sent a frame larger than \(limit) bytes"
            ]
        )
    }
}

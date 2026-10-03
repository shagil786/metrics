// UnixSocket: one connected AF_UNIX descriptor.
//
// Everything that touches a raw descriptor goes through here so there is exactly one
// place that knows how a descriptor is closed, and closing is the part that has to be
// right: `stop()` closes a live connection from one thread while that connection's
// own reader and writer are using it from others.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A connected descriptor, closeable exactly once.
///
/// The idempotent close is the whole reason this is a type and not an `Int32`: the
/// host's shutdown, the transport's `disconnect` and the reader's own teardown all
/// reach the same descriptor, and a double close would close a number the kernel has
/// since handed to something else.
final class UnixSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32

    init(_ descriptor: Int32) {
        stored = descriptor
    }

    /// The raw descriptor, for the calls that need one (`getsockopt`). Only meaningful
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
        /// `EAGAIN`: the descriptor's deadline expired with nothing to read.
        case timedOut
        /// `EINTR`: a signal arrived. Nothing was read, and nothing is wrong.
        case interrupted
        /// The peer closed, or this descriptor is already closed.
        case endOfFile
        case failed(Int32)
    }

    /// One `read`, bounded by `timeout`.
    ///
    /// The deadline is written on **every** call rather than left as whatever the
    /// previous reader set. `SO_RCVTIMEO` is per-descriptor state and this descriptor
    /// has two readers with different deadlines: the handshake, which has seconds, and
    /// the MCP session, which has none. A session that inherited the handshake's
    /// window would end the first time a client thought for that long — and then
    /// spin, because a reader that treats `EAGAIN` as "try again" would do so for as
    /// long as the descriptor lived.
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
        case EINTR: return .interrupted
        case EAGAIN: return .timedOut
        default: return .failed(errno)
        }
    }

    /// Writes all of `data`, looping over partial writes.
    func writeAll(_ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let descriptor = lock.withLock { stored }
            guard descriptor >= 0 else {
                throw UnixSocketError.closed
            }
            let written = remaining.withUnsafeBytes {
                Darwin.write(descriptor, $0.baseAddress, $0.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.writeFailed(errno)
            }
            guard written > 0 else {
                throw UnixSocketError.writeFailed(0)
            }
            remaining = remaining.dropFirst(written)
        }
    }
}

/// What can go wrong on a descriptor.
///
/// `CustomNSError` so the code, and not the wording, is what a caller branches on —
/// and so the wording can change without anything noticing.
enum UnixSocketError: Error, CustomNSError {
    case closed
    case writeFailed(Int32)

    static var errorDomain: String { "PortmasterMCP.UnixSocket" }

    var errorCode: Int {
        switch self {
        case .closed: Int(EPIPE)
        case .writeFailed(let code): Int(code)
        }
    }

    var errorUserInfo: [String: Any] {
        switch self {
        case .closed:
            [NSLocalizedDescriptionKey: "the client closed the connection"]
        case .writeFailed(let code) where code != 0:
            [NSLocalizedDescriptionKey: String(cString: strerror(code))]
        case .writeFailed:
            [NSLocalizedDescriptionKey: "zero-byte write to the client"]
        }
    }
}

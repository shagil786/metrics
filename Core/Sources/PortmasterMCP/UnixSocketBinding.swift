// UnixSocketBinding: putting a socket at a path, and proving it is still ours.
//
// Split out from the host because binding is a different kind of problem from serving.
// Binding is about the filesystem — a path that may be too long, may hold a leftover,
// may have been taken over by a later launch — and none of those questions are about
// MCP. It is also the only part of the host that touches the socket *file* rather than
// a connection, so keeping it together is what makes "who owns this path" answerable
// in one place.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// The socket file, and who put it there.
enum UnixSocketBinding {

    /// Creates, binds, tightens and listens on a Unix socket.
    ///
    /// The `0600` is set explicitly rather than left to the umask: `bind` creates the
    /// file at `0777 & ~umask`, which under the usual `022` is `0755` and lets any
    /// other local process connect and reach the handshake. The `0700` on the
    /// containing directory is applied only when this call creates it — an existing
    /// directory keeps whatever mode it had, which is why the socket's own mode is
    /// what actually carries the protection and is asserted in the tests.
    static func listen(path: String) throws -> Int32 {
        let containing = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: containing,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try removeStaleSocket(at: path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw failure("cannot create a socket for \(path)", code: errno)
        }
        // Deliberately no SO_REUSEADDR. It buys nothing for an `AF_UNIX` socket —
        // there is no TIME_WAIT to outlive — and on Darwin it permits binding over a
        // path another process is already listening on, which is exactly the case
        // `removeStaleSocket` exists to refuse.
        var address = try socketAddress(path: path)
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
            unlink(path: path)
            throw failure("cannot restrict \(path) to its owner", code: code)
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path: path)
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
        _ = try socketAddress(path: path)
        var status = stat()
        guard lstat(path, &status) == 0 else { return }  // Nothing there at all.
        if (status.st_mode & S_IFMT) == S_IFSOCK, isListening(at: path) {
            throw failure("another process is already listening on \(path)", code: EADDRINUSE)
        }
        unlink(path: path)
    }

    /// Whether a connection to `path` is accepted. A connect to a socket file with
    /// no listener behind it fails with `ECONNREFUSED` — that answer is the only
    /// difference between a leftover and a live host.
    private static func isListening(at path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        guard var address = try? socketAddress(path: path) else { return false }
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

    // MARK: - Ownership

    /// Which file is at `url` right now.
    ///
    /// `(device, inode)` rather than the path, because a path can be rebound: a
    /// second launch binds the same path and gets a new inode, and the instance that
    /// lost a last-writer-wins race must not unlink the winner's socket on its way
    /// out. Recorded after `listen`, compared before `unlink`.
    static func identity(of url: URL) -> (dev: dev_t, ino: ino_t)? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return (status.st_dev, status.st_ino)
    }

    /// Whether the file at `path` is still the one `identity` named.
    static func isOurs(path: String, identity: (dev: dev_t, ino: ino_t)?) -> Bool {
        guard let identity else { return false }
        var status = stat()
        guard lstat(path, &status) == 0 else { return false }
        return status.st_dev == identity.dev && status.st_ino == identity.ino
    }

    // MARK: - Primitives

    static func unlink(path: String) {
        _ = Darwin.unlink(path)
    }

    /// Writes one byte to a self-pipe, to wake a thread parked in `poll`.
    static func signal(_ descriptor: Int32) {
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
    static func peerProcessIdentifier(of socket: UnixSocket) -> pid_t {
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        let result = withUnsafeMutablePointer(to: &peer) { pointer in
            getsockopt(socket.descriptor, SOL_LOCAL, LOCAL_PEERPID, pointer, &size)
        }
        guard result == 0, peer > 0 else { return 0 }
        return peer
    }

    /// A thrown error carrying the reason in words, since the callers that matter are a
    /// CLI and an app that both have to be able to say what went wrong.
    ///
    /// `code` is an `errno` except where the failure did not come from a syscall, in
    /// which case it is 0 and there is no `strerror` to add.
    static func failure(_ message: String, code: Int32) -> NSError {
        let description = code == 0 ? message : "\(message): \(String(cString: strerror(code)))"
        return NSError(
            domain: "PortmasterMCP.UnixSocketBinding",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

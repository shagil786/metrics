import Darwin
import Foundation
import Security

/// How a CLI finds a running Portmaster: the socket it is listening on, the
/// token that proves the caller may talk to it, and the pid that says whether the
/// app is still there at all.
///
/// On disk this is exactly `{socket, token, pid}` at
/// `~/.portmaster/mcp-endpoint.json`, written and read through `EndpointFileStore`.
public struct EndpointFile: Equatable, Sendable, Codable {
    /// Absolute path of the Unix socket the host is serving MCP on.
    public let socket: URL
    /// Per-launch secret the host requires in the handshake. See
    /// `EndpointFileStore.newToken()`.
    public let token: String
    /// The host process that wrote this file, so a file left behind by a crash or
    /// a kill is recognisable as stale.
    public let pid: pid_t

    public init(socket: URL, token: String, pid: pid_t) {
        self.socket = socket
        self.token = token
        self.pid = pid
    }

    private enum CodingKeys: String, CodingKey {
        case socket, token, pid
    }

    /// Decoded from a plain path string rather than `URL`'s own conformance, which
    /// nests the value as `{"relative": ...}`. The file is read by a CLI that has
    /// to be able to read it with nothing but a JSON parser, so the shape is kept
    /// to three flat keys.
    ///
    /// An empty `socket` is rejected here rather than turned into a URL, because
    /// `URL(fileURLWithPath: "")` does not fail — it resolves to the current working
    /// directory, which would hand a caller a socket path that names a real place
    /// and a host that was never there.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let socketPath = try container.decode(String.self, forKey: .socket)
        guard !socketPath.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .socket,
                in: container,
                debugDescription: "socket path is empty"
            )
        }
        socket = URL(fileURLWithPath: socketPath)
        token = try container.decode(String.self, forKey: .token)
        pid = try container.decode(pid_t.self, forKey: .pid)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(socket.path, forKey: .socket)
        try container.encode(token, forKey: .token)
        try container.encode(pid, forKey: .pid)
    }
}

/// Reads and writes the endpoint file.
///
/// The `directory` parameter on every entry point exists for test injection;
/// passing `nil` uses the per-user `~/.portmaster`. No test may pass `nil` — that
/// is the one location the token would be real.
public enum EndpointFileStore {
    /// Bytes of entropy behind a token; hex-encoded, so 64 characters.
    private static let tokenByteCount = 32

    /// `<dir>/mcp-endpoint.json`.
    public static func defaultURL(directory: URL? = nil) -> URL {
        (directory ?? MCPSettings.defaultDirectory)
            .appendingPathComponent("mcp-endpoint.json")
    }

    /// Writes the endpoint file, replacing whatever was there, owner-only.
    ///
    /// The directory is created *and tightened* to `0700` and the file to `0600`
    /// even when they already exist: this file holds the token, so a directory
    /// someone made by hand at `0755`, or a file left behind by an older version,
    /// is repaired rather than adopted.
    public static func write(_ endpoint: EndpointFile, directory: URL? = nil) throws {
        let url = defaultURL(directory: directory)
        let fileManager = FileManager.default
        let containingDirectory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: containingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: containingDirectory.path
        )

        let encoder = JSONEncoder()
        // The bytes are identical either way; unescaped slashes only keep the
        // socket path readable to whoever ends up opening this file by hand.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(endpoint)
        // `.atomic` installs the new file with a rename, so a CLI reading this
        // while the app starts never sees a half-written endpoint, and never sees
        // the old token advertised against the new socket.
        try data.write(to: url, options: .atomic)
        // The mode is set explicitly rather than requested at write time
        // (`Data.WritingOptions` has no `posixPermissions` to ask with) and set
        // rather than assumed, for two reasons: it repairs a file an older
        // version left wider, and the file this just created is at the umask's
        // mode (0644), not 0600, until this call. That window is closed by the
        // directory: it is `0700`, so nothing but this user can reach the file
        // while it is briefly wider — and it is why the directory is tightened
        // above, before a single byte of token exists.
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The endpoint of a live app, or `nil` for "no app available".
    ///
    /// Absent, unreadable, undecodable, wrong-shaped and stale all mean the same
    /// thing to a caller — there is nothing to connect to, fall back — so this
    /// never throws and never tells them apart. Staleness is the case that carries
    /// the weight: the app is gone, the socket it named is a leftover file, and
    /// the pid is the only thing in the file that says so.
    public static func read(directory: URL? = nil) -> EndpointFile? {
        guard let data = try? Data(contentsOf: defaultURL(directory: directory)),
              let endpoint = try? JSONDecoder().decode(EndpointFile.self, from: data),
              isWellFormedToken(endpoint.token),
              isProcessAlive(endpoint.pid)
        else {
            return nil
        }
        return endpoint
    }

    /// Deletes the endpoint file if it is there. Safe on a directory that was
    /// never written to, so shutdown does not need to know whether it started.
    public static func remove(directory: URL? = nil) {
        try? FileManager.default.removeItem(at: defaultURL(directory: directory))
    }

    /// A fresh token: `tokenByteCount` random bytes, hex-encoded.
    ///
    /// Rotated per launch, and never written anywhere but this file — a token only
    /// has to outlive the processes sharing this user account, so replacing it is
    /// cheaper than protecting it. Two sources are tried in order, and if both
    /// fail there is no safe answer left, so this traps rather than returning
    /// something predictable: a guessable token is the one failure that would
    /// quietly turn the handshake into decoration.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        if !fillFromSecRandomCopyBytes(&bytes), !fillFromDeviceRandom(&bytes) {
            fatalError("no source of random bytes for the MCP endpoint token")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `candidate` is `expected`, in constant time.
    ///
    /// A `==` stops at the first differing byte, which makes how long a rejection
    /// took a running oracle for how much of the guess was right; this accumulates
    /// every difference and decides once, at the end. The length check up front does
    /// leak length, deliberately: the length is fixed and already public, and the
    /// only way to compare variable-length inputs without leaking it is to hash
    /// both first.
    public static func tokenMatches(_ candidate: String, expected: String) -> Bool {
        let candidateBytes = candidate.utf8
        let expectedBytes = expected.utf8
        guard candidateBytes.count == expectedBytes.count else { return false }

        var difference: UInt8 = 0
        for (candidateByte, expectedByte) in zip(candidateBytes, expectedBytes) {
            difference |= candidateByte ^ expectedByte
        }
        return difference == 0
    }

    // MARK: - Private

    /// Whether `pid` still names a live process.
    ///
    /// `kill(pid, 0)` answers `EPERM` for a process that exists but is not ours to
    /// signal — root-owned, or another user's — and `ESRCH` only for one that is
    /// gone. Reading `EPERM` as dead would hide a running app and send every
    /// caller to the on-demand fallback, so it is read as alive. `pid <= 0` is
    /// rejected before the call: `kill` treats those as "my process group" and
    /// "every process", which would report this very process alive for any file
    /// naming 0 or -1.
    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Whether the token is the shape `newToken()` produces. A file whose token is
    /// anything else did not come from a live host, and a caller that trusted one
    /// would be presenting a guess to a socket.
    private static func isWellFormedToken(_ token: String) -> Bool {
        let bytes = token.utf8
        guard bytes.count == tokenByteCount * 2 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    private static func fillFromSecRandomCopyBytes(_ bytes: inout [UInt8]) -> Bool {
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    }

    /// `/dev/urandom` as a second source, so a machine where the Security
    /// framework's generator is unavailable still gets real entropy instead of a
    /// weaker substitute.
    private static func fillFromDeviceRandom(_ bytes: inout [UInt8]) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: "/dev/urandom") else { return false }
        defer { try? handle.close() }
        do {
            let read = try handle.read(upToCount: bytes.count) ?? Data()
            guard read.count == bytes.count else { return false }
            read.copyBytes(to: &bytes, count: bytes.count)
            return true
        } catch {
            return false
        }
    }
}

import Darwin
import Foundation
import Security

/// How a CLI finds a running Portmaster: the socket it is listening on, the
/// token that proves the caller may talk to it, and the pid that says whether the
/// app is still there at all.
///
/// On disk this is exactly `{socket, token, pid}` at
/// `~/.portmaster/mcp-endpoint.json`, written and read through `EndpointFileStore`.
///
/// The token is a secret this type holds, so the type describes itself without it:
/// `description` and `debugDescription` redact it, because a reflected value reaches
/// logs, assertion messages and error text, none of which should ever carry it.
public struct EndpointFile: Equatable, Sendable, Codable {
    /// Absolute path of the Unix socket the host is serving MCP on.
    public let socket: URL
    /// Per-launch secret the host requires in the handshake. See
    /// `EndpointFileStore.newToken()`. Never print this.
    public let token: String
    /// The host process that wrote this file, so a file left behind by a crash or
    /// a kill is recognisable as stale.
    public let pid: pid_t

    public init(socket: URL, token: String, pid: pid_t) {
        self.socket = socket
        self.token = token
        self.pid = pid
    }

    public var description: String {
        "EndpointFile(socket: \(socket.path), token: <redacted>, pid: \(pid))"
    }

    public var debugDescription: String { description }

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

extension EndpointFile: CustomStringConvertible, CustomDebugStringConvertible {}

/// Reads and writes the endpoint file.
///
/// The `directory` parameter on every entry point exists for test injection;
/// passing `nil` uses the per-user `~/.portmaster`. No test may pass `nil` — that
/// is the one location the token would be real.
public enum EndpointFileStore {
    /// Bytes of entropy behind a token; hex-encoded, so 64 characters.
    private static let tokenByteCount = 32

    /// Largest endpoint file that will be read. The real one is a few hundred bytes
    /// — a socket path, a 64-character token, a pid — so this is slack, not a budget
    /// that anything real can reach.
    static let maxEndpointFileBytes = 4_096

    /// `<dir>/mcp-endpoint.json`.
    public static func defaultURL(directory: URL? = nil) -> URL {
        (directory ?? MCPSettings.defaultDirectory)
            .appendingPathComponent("mcp-endpoint.json")
    }

    /// Writes the endpoint file, replacing whatever was there, owner-only.
    ///
    /// The directory is created *and tightened* to `0700` even when it already
    /// exists — a hand-made `~/.portmaster` at `0755` is repaired rather than
    /// adopted — and it is tightened before a single byte of token exists, so
    /// nothing but this user can reach the file at any point in the write below.
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
        try replaceAtomically(try encoder.encode(endpoint), at: url)
    }

    /// The endpoint of a live app, or `nil` for "no app available".
    ///
    /// Absent, unreadable, undecodable, wrong-shaped and stale all mean the same
    /// thing to a caller — there is nothing to connect to, fall back — so this
    /// never throws and never tells them apart. Staleness is the case that carries
    /// the weight: the app is gone, the socket it named is a leftover file, and
    /// the pid is the only thing in the file that says so.
    public static func read(directory: URL? = nil) -> EndpointFile? {
        let url = defaultURL(directory: directory)
        guard isBoundedRegularFile(at: url),
              let data = try? Data(contentsOf: url),
              data.count <= maxEndpointFileBytes,
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
    /// cheaper than protecting it.
    ///
    /// Throws rather than substituting something predictable when no entropy source
    /// answers: a guessable token is the one failure that would quietly turn the
    /// handshake into decoration. Failing to mint a token is also not worth killing a
    /// process over — the caller is on the app's launch path, and the right outcome
    /// there is an MCP host that declines to start and says why, not a GUI app that
    /// disappears.
    public static func newToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: tokenByteCount)
        if !fillFromSecRandomCopyBytes(&bytes), !fillFromDeviceRandom(&bytes) {
            throw failure("no source of random bytes for the MCP endpoint token", code: 0)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `candidate` is `expected`.
    ///
    /// Deliberately without an early return on a differing byte: `==` stops at the
    /// first difference, which makes how long a rejection took an oracle for how much
    /// of the guess was right. This walks both strings once, accumulates every
    /// difference and decides once at the end, so the work does not depend on *where*
    /// the strings differ. That is a guarantee about this code's control flow, not a
    /// measured one — only a timing test against the shipped binary could show the
    /// optimiser kept it.
    ///
    /// The comparison is over UTF-8 **bytes**, so "64 characters" from a caller and
    /// "64 characters" here can be different lengths; that is deliberate, and a token
    /// is hex either way.
    ///
    /// The length check up front does leak length, deliberately: the length is fixed
    /// and already public, and comparing variable-length inputs without leaking it
    /// means hashing both first.
    ///
    /// Callers must never pass an empty `expected`. `tokenMatches("", "")` is `true`
    /// by the definition above — two empty strings are equal, whatever their length —
    /// and the only thing standing between a caller and an empty-token handshake is
    /// `read`'s check that the file's token is well formed.
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

    // MARK: - Writing

    /// Installs `data` at `url` in one step a reader cannot observe halfway, and
    /// owner-only from the moment it exists.
    ///
    /// The bytes go into a sibling temp file created `0600` with `O_EXCL`, and the
    /// `rename` swaps it in. Foundation's `.atomic` write would have created its temp
    /// file at the umask's mode — `0644` under the usual `022` — and installed that at
    /// the destination, leaving the token readable by anyone who could reach the file
    /// until a following `chmod`; the `0700` directory made that unreachable in
    /// practice, but a window that is only closed by a second line of defence is
    /// better removed than argued about. The rename is kept because it is what stops
    /// a CLI reading this mid-launch from seeing a half-written endpoint, or the old
    /// token advertised against the new socket.
    private static func replaceAtomically(_ data: Data, at url: URL) throws {
        // The pid keeps two writers in one process from colliding; `O_EXCL` means a
        // name someone else already holds is an error rather than something to adopt.
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw failure("cannot create \(temporaryURL.path)", code: errno)
        }

        var installed = false
        defer {
            close(descriptor)
            // A failed write must not leave a half-file beside the real endpoint for
            // the next `read` to trip over.
            if !installed {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw failure("cannot write \(temporaryURL.path)", code: errno)
            }
            guard written > 0 else {
                throw failure("zero-byte write to \(temporaryURL.path)", code: 0)
            }
            remaining = remaining.dropFirst(written)
        }

        guard rename(temporaryURL.path, url.path) == 0 else {
            throw failure("cannot install \(url.path)", code: errno)
        }
        installed = true
    }

    // MARK: - Reading

    /// Whether `url` is a regular file of a size an endpoint file could plausibly be.
    ///
    /// Checked before reading, because `Data(contentsOf:)` blocks forever on a FIFO
    /// and reads all of a huge file: a path this code did not write — a mistyped
    /// location, or something another process left in a directory it can write — would
    /// then hang or pull in unbounded memory instead of reading as "no app". `lstat`
    /// rather than `stat`, so a symlink is rejected outright rather than followed to
    /// whatever it aims at.
    private static func isBoundedRegularFile(at url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFREG
            && status.st_size > 0
            && status.st_size <= Int64(maxEndpointFileBytes)
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

    /// A thrown error carrying the reason in words, since the callers that matter
    /// are a CLI and an app that both have to be able to say what went wrong.
    ///
    /// `code` is an `errno` except where the failure did not come from a syscall, in
    /// which case it is 0 and there is no `strerror` to add.
    private static func failure(_ message: String, code: Int32) -> NSError {
        let description = code == 0
            ? message
            : "\(message): \(String(cString: strerror(code)))"
        return NSError(
            domain: "PortmasterMCP.EndpointFile",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

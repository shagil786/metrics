import Darwin
import Foundation

/// Appends one JSON line per MCP **mutation attempt** to
/// `~/.portmaster/mcp-audit.log`. Reads are deliberately not logged: they change
/// nothing, and logging them would bury the entries that matter.
///
/// Lines have the shape `{ts, tool, arguments, outcome, reason, pid}` with every
/// key always present (a nil `reason` is written as JSON `null`). `outcome` is
/// one of `denied` (the gate refused; nothing happened), `allowed` (the action
/// succeeded), or `failed` (it was permitted but did not work). `arguments` is an
/// echo of what the client sent, bounded by `maxRecordedArgumentKeys` /
/// `maxRecordedArgumentValueCharacters` / `maxRecordedArgumentsCharacters` and
/// marked with `argumentsTruncationMarker` when anything was dropped — a client
/// is not obliged to send only declared arguments, and one line has to stay a
/// line. The log file is created owner-only (`0600`) inside a `0700` directory.
public struct AuditLog: Sendable {
    private static let fileName = "mcp-audit.log"

    /// Most argument keys one line records. Clients are not obliged to send only
    /// declared arguments, so this — not the tool's own schema — is what stops a
    /// buggy client from inventing thousands of them.
    public static let maxRecordedArgumentKeys = 24
    /// Longest single argument value recorded, in characters. A longer value is
    /// clipped and marked, never silently shortened: the log's job is to say what
    /// was acted on, and a clipped value must not read as the whole one.
    public static let maxRecordedArgumentValueCharacters = 512
    /// Largest total of key and value characters one line records, so many short
    /// keys cannot add up to a document either.
    public static let maxRecordedArgumentsCharacters = 4_096
    /// The key that records *that* arguments were dropped. Without it a bounded
    /// line would be indistinguishable from a call that passed only what it lists.
    public static let argumentsTruncationMarker = "[truncated]"
    /// Room held back from every record for the truncation note, so a line that
    /// runs out of budget can still say that it did — a bounded record that reads
    /// as complete is worse than no record at all.
    private static let truncationNoteCharacters = 32

    /// Absolute path of the audit log this instance appends to.
    public let fileURL: URL

    public init(directory: URL? = nil) {
        let directory = directory ?? MCPSettings.defaultDirectory
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// Records one audit line. Best-effort by design: the non-throwing
    /// signature means a failed write must never break tool execution, so
    /// failures are reported on stderr instead of thrown.
    public func record(tool: String, arguments: [String: String], outcome: String, reason: String?) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            // Not fatal on its own: the append below is the authority on writability.
            Self.warn("cannot create audit directory \(directory.path)")
        }

        let entry = AuditEntry(
            ts: Date(),
            tool: tool,
            arguments: Self.bounded(arguments),
            outcome: outcome,
            reason: reason,
            pid: ProcessInfo.processInfo.processIdentifier
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            var line = try encoder.encode(entry)
            line.append(0x0A)
            Self.append(line, to: fileURL.path)
        } catch {
            Self.warn("cannot encode audit entry for tool \(tool)")
        }
    }

    /// The argument map as it will be recorded: bounded in key count, in value
    /// length and in total, and marked when anything was dropped.
    ///
    /// This log is one line per mutation attempt, so an unbounded echo lets a
    /// client that sends megabytes of invented arguments write megabytes per call
    /// to the user's disk. Keys are walked in sorted order so two identical calls
    /// produce byte-identical lines — which is what makes a diff of the log
    /// readable — and the budget is spent in that order.
    static func bounded(_ arguments: [String: String]) -> [String: String] {
        var recorded: [String: String] = [:]
        var characters = truncationNoteCharacters
        var dropped = 0
        for key in arguments.keys.sorted() {
            let value = arguments[key] ?? ""
            let clipped = value.count > maxRecordedArgumentValueCharacters
                ? String(value.prefix(maxRecordedArgumentValueCharacters)) + "\u{2026}"
                : value
            let cost = key.count + clipped.count
            if recorded.count >= maxRecordedArgumentKeys
                || characters + cost > maxRecordedArgumentsCharacters {
                dropped += 1
                continue
            }
            recorded[key] = clipped
            characters += cost
        }
        if dropped > 0 {
            // The count is itself capped, so the note cannot grow past the room
            // reserved for it no matter how many arguments were dropped.
            recorded[argumentsTruncationMarker] = dropped <= 999
                ? "\(dropped) argument(s) not recorded"
                : "many arguments not recorded"
        }
        return recorded
    }

    /// Appends one line through a single `O_APPEND` write, so concurrent
    /// records land at the file end instead of overwriting each other. The log
    /// is created with owner-only permissions, never briefly world-readable.
    private static func append(_ line: Data, to path: String) {
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard descriptor >= 0 else {
            warn("cannot open \(path): \(lastErrorDescription)")
            return
        }
        defer { close(descriptor) }

        // Repairs the mode of a pre-existing log file. A failure here must not
        // cost the record, so it is reported and the write still proceeds.
        if fchmod(descriptor, 0o600) != 0 {
            warn("cannot tighten permissions on \(path): \(lastErrorDescription)")
        }

        var remaining = line
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                warn("cannot append to \(path): \(lastErrorDescription)")
                return
            }
            guard written > 0 else {
                warn("zero-byte write to \(path); append stopped")
                return
            }
            remaining = remaining.dropFirst(written)
        }
    }

    private static var lastErrorDescription: String {
        String(cString: strerror(errno))
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("Portmaster MCP audit: \(message)\n".utf8))
    }
}

/// One audit line. `reason` is encoded unconditionally — as `null` when absent —
/// so readers can rely on a fixed key set.
private struct AuditEntry: Encodable {
    let ts: Date
    let tool: String
    let arguments: [String: String]
    let outcome: String
    let reason: String?
    let pid: Int32

    private enum CodingKeys: String, CodingKey {
        case ts, tool, arguments, outcome, reason, pid
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ts, forKey: .ts)
        try container.encode(tool, forKey: .tool)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(reason, forKey: .reason)
        try container.encode(pid, forKey: .pid)
    }
}

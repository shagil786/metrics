import Darwin
import Foundation

/// Appends one JSON line per MCP **mutation attempt** to
/// `~/.portmaster/mcp-audit.log`. Reads are deliberately not logged: they change
/// nothing, and logging them would bury the entries that matter.
///
/// Lines have the shape `{ts, tool, arguments, outcome, reason, pid}` with every
/// key always present (a nil `reason` is written as JSON `null`). `outcome` is
/// one of `denied` (the gate refused; nothing happened), `allowed` (the action
/// succeeded), or `failed` (it was permitted but did not work). The log file is
/// created owner-only (`0600`) inside a `0700` directory.
public struct AuditLog: Sendable {
    private static let fileName = "mcp-audit.log"

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
            arguments: arguments,
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
import Darwin
import Foundation

/// Appends one JSON line per MCP tool call to `~/.portmaster/mcp-audit.log`.
///
/// Lines have the shape `{ts, tool, arguments, outcome, reason, pid}`.
/// The log file is owner-only (`0600`) inside a `0700` directory.
public struct AuditLog: Sendable {
    private static let fileName = "mcp-audit.log"

    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? MCPSettings.defaultDirectory
    }

    /// Records one audit line. Best-effort by design: the non-throwing
    /// signature means a failed write must never break tool execution.
    public func record(tool: String, arguments: [String: String], outcome: String, reason: String?) {
        let fileURL = directory.appendingPathComponent(Self.fileName)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }
            guard chmod(fileURL.path, 0o600) == 0 else { return }

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
            var line = try encoder.encode(entry)
            line.append(0x0A)

            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            return
        }
    }
}

private struct AuditEntry: Codable {
    let ts: Date
    let tool: String
    let arguments: [String: String]
    let outcome: String
    let reason: String?
    let pid: Int32
}

import Foundation

/// User-selectable mutation policy for MCP tool calls.
public enum MCPMutationMode: String, CaseIterable, Codable, Sendable {
    case off, confirmEach, allowSession
}

/// Persistent MCP settings, stored as JSON at `~/.portmaster/mcp-settings.json`.
///
/// The `directory` parameter on `load`/`save`/`fileURL` exists for test injection;
/// passing `nil` uses the per-user default directory.
public struct MCPSettings: Codable, Sendable {
    public var mode: MCPMutationMode

    public static let defaultMode: MCPMutationMode = .off

    /// Canonical per-user directory for Portmaster MCP state (`~/.portmaster`).
    static let defaultDirectory: URL =
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".portmaster", isDirectory: true)

    public init(mode: MCPMutationMode = MCPSettings.defaultMode) {
        self.mode = mode
    }

    public static func fileURL(directory: URL?) -> URL {
        (directory ?? defaultDirectory).appendingPathComponent("mcp-settings.json")
    }

    /// Loads settings; a missing or corrupt file yields the defaults.
    public static func load(directory: URL? = nil) -> MCPSettings {
        guard let data = try? Data(contentsOf: fileURL(directory: directory)),
              let settings = try? JSONDecoder().decode(MCPSettings.self, from: data)
        else {
            return MCPSettings()
        }
        return settings
    }

    public func save(directory: URL? = nil) throws {
        let url = MCPSettings.fileURL(directory: directory)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

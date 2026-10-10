// Core/Sources/PortmasterMCP/HandoffTargets.swift
import Foundation

/// How to start one receiving agent. Configuration, not code: the spec's §6
/// promise is that adding an agent is a config entry, and the exact shapes are
/// **assumed rather than confirmed** against installed CLIs (spec, "Not
/// verified") — so they belong somewhere an edit fixes, not a rebuild.
public struct HandoffTarget: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum HandoffTargets {
    /// Key → target. The key is what `handoff_context`'s `target` argument and
    /// the affordance's picker say, and it is what the chain line shows for the
    /// spawned side (ruling 2).
    public static let defaults: [String: HandoffTarget] = [
        "claude": HandoffTarget(executable: "claude"),
        "codex": HandoffTarget(executable: "codex"),
    ]

    public static let fileName = "handoff-targets.json"

    /// The file's map when it exists, decodes, and is non-empty; the defaults
    /// otherwise. Read per handoff, the same way this repo reads settings per
    /// call, so a corrected file takes effect without restarting anything.
    public static func load(directory: URL? = nil) -> [String: HandoffTarget] {
        let dir = directory ?? MCPSettings.defaultDirectory
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: HandoffTarget].self, from: data),
              !map.isEmpty
        else { return defaults }
        return map
    }
}

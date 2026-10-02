// DataProvider: the seam between the MCP tool layer and Portmaster's data.
// Slice 1 implements it over an on-demand snapshot (Task 6); tests use a stub.
// Nothing here talks to the network or spawns a process — a provider only
// answers questions about the machine, or performs an already-gated stop.
import Foundation
import PortmasterCore

/// Metric a `get_top_apps` ranking is ordered by.
public enum AppMetric: String, CaseIterable, Sendable {
    case cpu, memory, network, disk
}

/// Lookback window for `get_history_rankings`. Raw values are the strings the
/// tool accepts, so the catalog's help text and the parser agree by construction.
public enum HistoryWindow: String, CaseIterable, Sendable {
    case h1 = "1h"
    case h12 = "12h"
    case h24 = "24h"
    case d7 = "7d"
    case d30 = "30d"

    /// Window length in seconds.
    public var seconds: TimeInterval {
        switch self {
        case .h1: return 3600
        case .h12: return 12 * 3600
        case .h24: return 24 * 3600
        case .d7: return 7 * 86400
        case .d30: return 30 * 86400
        }
    }

    /// Start of the window, inclusive, relative to now.
    public var since: Date { Date().addingTimeInterval(-seconds) }
}

/// A detected repository, as MCP callers see it: identity plus the process and
/// port footprint. Distinct from `PortmasterCore.ProjectSummary`, which also
/// carries memory and is a display model for the app's Projects screen.
public struct ProjectSummary: Codable, Sendable {
    /// Project identifier (the attributed repository path).
    public let id: String
    /// Last path component of `id`, for display.
    public let name: String
    public let processCount: Int
    /// Listening ports bound by the project's processes, ascending.
    public let ports: [Int]

    public init(id: String, name: String, processCount: Int, ports: [Int]) {
        self.id = id
        self.name = name
        self.processCount = processCount
        self.ports = ports
    }
}

/// User preferences, flattened to plain strings so the MCP payload never has to
/// mirror the app's `AppPreferences` layout (which is free to evolve).
public struct SettingsSnapshot: Codable, Sendable {
    public let temperatureUnit: String
    public let networkUnit: String
    public let cpuScale: String
    public let temperatureSource: String
    public let compactMenuBar: Bool
    /// Current MCP mutation mode (`off` / `confirmEach` / `allowSession`).
    public let mutationMode: String
    public let alertsEnabled: Bool
    public let retention: String

    public init(
        temperatureUnit: String, networkUnit: String, cpuScale: String,
        temperatureSource: String, compactMenuBar: Bool, mutationMode: String,
        alertsEnabled: Bool, retention: String
    ) {
        self.temperatureUnit = temperatureUnit
        self.networkUnit = networkUnit
        self.cpuScale = cpuScale
        self.temperatureSource = temperatureSource
        self.compactMenuBar = compactMenuBar
        self.mutationMode = mutationMode
        self.alertsEnabled = alertsEnabled
        self.retention = retention
    }
}

/// Result of a stop action, keyed by pid: `"stopped"`, `"failed: <msg>"`, or
/// `"unsupported"`. Mirrors `StopCoordinator.Outcome.Status`.
public struct StopReport: Codable, Sendable {
    public let results: [String: String]

    public init(results: [String: String]) {
        self.results = results
    }

    /// Maps a coordinator outcome onto the wire value for one pid.
    public static func value(for status: StopCoordinator.Outcome.Status) -> String {
        switch status {
        case .stopped: return "stopped"
        case .stillRunning: return "failed: still running after the stop signal"
        case .failed(let message): return "failed: \(message)"
        }
    }
}

/// A failure whose message is safe to show the caller verbatim.
public struct MCPToolError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Everything the tool layer can ask the machine for.
///
/// Reads are snapshot observations; mutations already carry an explicit stop or
/// preference intent and must be called only after `PermissionGate` allows them.
public protocol DataProvider: Sendable {
    func systemOverview() async throws -> SystemSample
    func topApps(metric: AppMetric, limit: Int) async throws -> [AppRollup]
    func appDetail(id: String) async throws -> AppRollup
    func containers() async throws -> DockerSample
    func projects() async throws -> [ProjectSummary]
    func historyRankings(
        window: HistoryWindow, resource: HistoryResource?
    ) async throws -> [AppHistoryTrend]
    func temperaturesFans() async throws -> ThermalSample?
    func activeAlerts() async throws -> [ActingUpAlert]
    func settingsSnapshot() -> SettingsSnapshot
    func quitApp(id: String, force: Bool) async throws -> StopReport
    func stopContainer(id: String) async throws -> StopReport
    func stopProject(id: String) async throws -> StopReport
    func setPreference(key: String, value: String) throws
}

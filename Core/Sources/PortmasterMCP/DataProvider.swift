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
public struct ProjectSummary: Codable, Equatable, Sendable {
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

/// Where a set of alerts came from. Provenance belongs to whoever evaluated
/// them: a caller must not read an alert reconstructed from recorded samples as
/// one the live engine has just raised.
public enum AlertSource: String, Sendable {
    /// Raised by the live `AlertEngine` from the current sampling.
    case live
    /// Reconstructed from recorded history — the observation is real, its
    /// freshness is not.
    case historyApproximate = "history-approximate"
}

/// Alerts plus how they were produced. The two travel together so that an
/// *empty* result still says which evaluation produced it; an array on its own
/// cannot carry that, and "no alerts" is exactly when a caller wonders whether
/// the alert path is working at all.
public struct AlertsSnapshot: Sendable {
    public let source: AlertSource
    public let alerts: [ActingUpAlert]

    public init(source: AlertSource, alerts: [ActingUpAlert]) {
        self.source = source
        self.alerts = alerts
    }
}

/// Result of a stop action, keyed by pid: `"stopped"` or `"failed: <reason>"`.
/// Mirrors `StopCoordinator.Outcome.Status`, which has no separate unsupported
/// case — an unsupported host arrives as `.failed(reason:)`.
public struct StopReport: Codable, Equatable, Sendable {
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

    /// What an app-hosted provider throws when its sampler has published nothing.
    ///
    /// `LiveDataProvider` passes whatever its `snapshot` closure throws straight
    /// through, so the app's own closure owns the wording of the one refusal every
    /// caller eventually meets — and a second copy of that sentence is how a client
    /// reads two different explanations for the same fact, one per provider it can
    /// reach. It is a constant here so the app cannot write it out: the value *is*
    /// the on-demand path's `notReadyMessage`, by construction rather than by
    /// agreement, and `MCPHostWiringTests` pins it against both.
    public static let samplerNotReady = MCPToolError(message: OnDemandProvider.notReadyMessage)

    /// A failure whose message is safe to show the caller verbatim, naming the
    /// subsystem it came from.
    ///
    /// Providers throw errors from collectors, databases and subprocesses; left
    /// alone those render as `localizedDescription`'s "The operation couldn't be
    /// completed. (Module.Error error 1.)", which tells a caller — and the audit
    /// log — nothing about what actually failed. An `MCPToolError` is passed
    /// through unchanged, so a provider's own careful wording survives.
    static func wrapping(_ error: Error, subsystem: String) -> MCPToolError {
        if let error = error as? MCPToolError { return error }
        return MCPToolError(
            message: "Could not read \(subsystem) data: \(error.localizedDescription)"
        )
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
    /// Agent sessions, newest first, with each one's usage and cost.
    ///
    /// `storeAvailable` is separate from an empty list on purpose. An empty
    /// `sessions` array means "the store opened and holds no sessions"; a store
    /// that would not open must say so, because "no agent history" and "could not
    /// read the history" are different claims and a caller told the first would
    /// report a user as never having used an agent.
    ///
    /// `openSessionIDs` is the host's live set. It exists because nothing observes
    /// a socket closing, so there is no stored end time to read — liveness is the
    /// only honest signal available. A provider with no live set (the CLI) passes
    /// an empty set, which means "nothing is open *that this process knows of*".
    func agentSessions(
        limit: Int, openSessionIDs: Set<UUID>
    ) async throws -> (sessions: [AgentSessionSnapshot], storeAvailable: Bool, note: String?)
    /// App CPU/memory totals over the window. The executor never fills `resource`
    /// here — it always passes nil and sends resource reads to
    /// `historyResources` — so do not write a non-nil branch for it.
    func historyRankings(
        window: HistoryWindow, resource: HistoryResource?
    ) async throws -> [AppHistoryTrend]
    /// Recorded readings of a single resource over the window. A separate method
    /// rather than an overload of `historyRankings`: a resource reading belongs
    /// to no app, so folding it into `AppHistoryTrend` would invent the app it
    /// was never attributed to.
    func historyResources(
        window: HistoryWindow, resource: HistoryResource
    ) async throws -> [ResourceHistoryPoint]
    /// Sensor temperatures and fan RPMs.
    ///
    /// Non-optional on purpose, and the provider must throw rather than answer
    /// when it has no reading. The sensor pass runs on the sampler's slow lane, so
    /// a snapshot taken before that pass lands has no thermal sample in it, and a
    /// later pass that cannot read the SMC reports `notSampledYet` — and neither
    /// is the same claim as "this machine has no temperature sensors". Returning
    /// nil would let the payload turn the first into the second.
    /// `ThermalSample.availability` separates them: the provider throws for
    /// `.notSampledYet` and returns the sample for `.noSensors` and `.available`.
    func temperaturesFans() async throws -> ThermalSample
    func activeAlerts() async throws -> AlertsSnapshot
    /// `async` because a host answers this from state it publishes — the app's own
    /// preferences, read on its actor — and a synchronous seam would force it to
    /// block that actor or answer from a copy that can be stale. `onDemand` reads a
    /// blob off disk and is `async` only because the requirement is.
    func settingsSnapshot() async -> SettingsSnapshot
    func quitApp(id: String, force: Bool) async throws -> StopReport
    func stopContainer(id: String) async throws -> StopReport
    func stopProject(id: String) async throws -> StopReport
    /// `async` so a host whose preferences live on another actor can hand on to it by
    /// suspending. It was synchronous, and the only implementations either did the
    /// work inline or bridged to a main actor with a blocking hop — a hop that is
    /// correct until something on that actor waits for a tool call, and then a
    /// deadlock. Reads that must not block are declared `throws`; this one is declared
    /// for the opposite reason.
    func setPreference(key: String, value: String) async throws
}

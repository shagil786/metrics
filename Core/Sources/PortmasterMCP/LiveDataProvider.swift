// LiveDataProvider: the `DataProvider` the Portmaster app itself serves.
//
// Where `OnDemandProvider` is the fallback — an MCP server alone on the machine,
// collecting what it needs per call — this one is a view onto a sampler that is
// already running. The app sweeps on its own cadence and publishes what it found;
// this provider reads that published reading and hands it to the tool layer. So
// there is no acquisition, no cache and no collection here at all, and a tool call
// costs what the app's last sweep cost rather than a fresh process sweep.
//
// The honesty rules are inherited rather than restated, which is why so little of
// this file is logic: absence refuses (`SnapshotAcquisition.notReadyMessage`),
// the three thermal answers stay apart (`OnDemandProvider.thermalSample`), project
// grouping is one function (`OnDemandProvider.projectSummaries`), and the ranking
// and limit range are the executor's (`ToolExecutor.rank`, `ToolExecutor.validatedLimit`).
// Two providers answer the same tool for a client that can reach either, so where
// both answer, they answer with the same code.
import Foundation
import PortmasterCore

/// `DataProvider` over the running app's published snapshot.
public struct LiveDataProvider: DataProvider {
    private let snapshotSource: @Sendable () async throws -> ObservationSnapshot
    private let alertsSource: @Sendable () -> AlertsSnapshot
    private let history: LazyHistory
    private let settingsSource: @Sendable () -> SettingsSnapshot
    private let applyPreference: @Sendable (String, String) throws -> Void
    private let stopApp: @Sendable (String, Bool) async throws -> StopReport
    private let stopContainerNamed: @Sendable (String) async throws -> StopReport
    private let stopProject: @Sendable (String) async throws -> StopReport

    /// - Parameters:
    ///   - snapshot: returns the app's latest snapshot on demand (the app passes a
    ///     closure hopping to the main actor). Reads must not fabricate: if no
    ///     snapshot has arrived yet, throw
    ///     `MCPToolError(SnapshotAcquisition.notReadyMessage)`.
    ///   - alerts: returns recent alerts for `get_active_alerts`, tagged `.live`.
    ///   - history: opened lazily, only for history questions.
    ///   - settings: the app's current preferences, read on demand.
    ///   - stopping: how mutations reach the app's `StopCoordinator` and settings
    ///     writes.
    public init(
        snapshot: @escaping @Sendable () async throws -> ObservationSnapshot,
        alerts: @escaping @Sendable () -> AlertsSnapshot,
        history: @escaping @Sendable () -> any HistoryReading,
        settings: @escaping @Sendable () -> SettingsSnapshot,
        applyPreference: @escaping @Sendable (String, String) throws -> Void,
        stopApp: @escaping @Sendable (String, Bool) async throws -> StopReport,
        stopContainerNamed: @escaping @Sendable (String) async throws -> StopReport,
        stopProject: @escaping @Sendable (String) async throws -> StopReport
    ) {
        self.snapshotSource = snapshot
        self.alertsSource = alerts
        // Opened on the first history question and kept, as in the on-demand path:
        // most tool calls never ask one, and opening a database to answer a
        // process question would be a write the caller never asked for.
        self.history = LazyHistory(history)
        self.settingsSource = settings
        self.applyPreference = applyPreference
        self.stopApp = stopApp
        self.stopContainerNamed = stopContainerNamed
        self.stopProject = stopProject
    }

    // MARK: Snapshot reads

    /// The app's latest published reading.
    ///
    /// The app is the sampler, so nothing is collected here — this only asks for
    /// what has already been published, and refuses when there is nothing. A
    /// provider that answered "not yet" with an empty snapshot would be reporting
    /// a reading nobody took, which is the one failure this whole contract exists
    /// to prevent; so absence arrives as a throw and reaches the caller in the
    /// words the on-demand path uses, because "the sampler is still starting" is
    /// the same fact whoever observed it.
    private func snapshot() async throws -> ObservationSnapshot {
        do {
            return try await snapshotSource()
        } catch {
            // `MCPToolError` passes through untouched, so the app's careful
            // wording survives; anything else would render as "The operation
            // couldn't be completed…" in the audit log, naming no subsystem.
            throw MCPToolError.wrapping(error, subsystem: "sampling")
        }
    }

    public func systemOverview() async throws -> SystemSample {
        try await snapshot().system
    }

    public func topApps(metric: AppMetric, limit: Int) async throws -> [AppRollup] {
        // The executor owns ranking and truncation for the payload, and does both
        // again after this returns. Applying the same two steps here is applying
        // them once — the comparator is a total order on the metric, so re-ranking
        // a ranked prefix reproduces it — and it means the limit range is enforced
        // on whichever provider a client happens to be talking to.
        let allowed = try ToolExecutor.validatedLimit(limit)
        return Array(ToolExecutor.rank(try await snapshot().rollups, by: metric).prefix(allowed))
    }

    public func appDetail(id: String) async throws -> AppRollup {
        let rollups = try await snapshot().rollups
        guard let rollup = rollups.first(where: { $0.id == id }) else {
            throw OnDemandProvider.appNotFound(id)
        }
        return rollup
    }

    public func containers() async throws -> DockerSample {
        // nil means the first `docker` pass has not landed — not "Docker is not
        // installed". Reporting an availability nothing observed would be a claim
        // about the machine that no pass made.
        guard let docker = try await snapshot().docker else {
            throw MCPToolError(message: OnDemandProvider.dockerNotKnownMessage)
        }
        return docker
    }

    public func temperaturesFans() async throws -> ThermalSample {
        try OnDemandProvider.thermalSample(from: await snapshot())
    }

    public func projects() async throws -> [ProjectSummary] {
        OnDemandProvider.projectSummaries(from: try await snapshot())
    }

    // MARK: History reads

    public func historyRankings(
        window: HistoryWindow, resource: HistoryResource?
    ) async throws -> [AppHistoryTrend] {
        // `resource` is documented as always nil; see `DataProvider`.
        _ = resource
        do {
            return try await history.get().appTrends(since: window.since)
        } catch {
            throw MCPToolError.wrapping(error, subsystem: OnDemandProvider.historySubsystem())
        }
    }

    public func historyResources(
        window: HistoryWindow, resource: HistoryResource
    ) async throws -> [ResourceHistoryPoint] {
        do {
            return try await history.get().resourceSamples(resource, since: window.since)
        } catch {
            throw MCPToolError.wrapping(
                error, subsystem: OnDemandProvider.historySubsystem(for: resource)
            )
        }
    }

    // MARK: Alerts

    /// The live engine's alerts, handed over whole.
    ///
    /// This is where `.live` becomes real: the alerts were raised by the running
    /// `AlertEngine` from the sampling the app is already doing, so they are not
    /// reconstructed from recorded history and must not be tagged as an
    /// approximation. They are also not ranked, filtered or re-dated here — the
    /// app owns which of its alerts are current, and a provider that reordered them
    /// would be reporting a different set of alerts than the one the user sees.
    public func activeAlerts() async throws -> AlertsSnapshot {
        alertsSource()
    }

    // MARK: Settings

    /// The app's current preferences.
    ///
    /// Answered from the app rather than from a preferences blob decoded here: the
    /// app holds the decoded preferences in memory, so it is the only reader that
    /// sees an unsaved change and the only writer that will not lose one.
    public func settingsSnapshot() -> SettingsSnapshot {
        settingsSource()
    }

    /// Changes one allowlisted preference, through the app.
    ///
    /// The key and the value are checked here first, with the on-demand path's own
    /// validation code, so a client that can reach both providers cannot have a
    /// key or value refused by one and applied by the other. Applying it is the
    /// app's: it owns the blob, and it is what the Settings screen writes through.
    ///
    /// **Known asymmetry, deliberate.** `OnDemandProvider` additionally refuses
    /// while the app is running, because there it would be writing a blob the app
    /// holds in memory and would overwrite on its next change. Here the app is the
    /// writer, so there is nothing to race: the write is the same one the Settings
    /// screen makes. `mcpMode` still never reaches this method — the executor owns
    /// that key end to end, and `apply` refuses it on both paths.
    public func setPreference(key: String, value: String) throws {
        // `apply` raises the two refusals the on-demand path uses — a key outside
        // the executor's allowlist, and a value no enum case matches — with the
        // same wording, built from the same allowlist. The preferences it writes
        // into are discarded: this is a check, not a write.
        var scratch = AppPreferences()
        try PreferencesStore.apply(key: key, value: value, to: &scratch)
        try applyPreference(key, value)
    }

    // MARK: Stops

    /// Stops an app's processes, as the app's coordinator sees them.
    ///
    /// No id is resolved here. The app's own snapshot is the membership list, its
    /// coordinator re-verifies each pid's identity immediately before signalling
    /// it, and a list read here would be a second, staler answer to the same
    /// question — so a caller either gets the app's report or its refusal.
    public func quitApp(id: String, force: Bool) async throws -> StopReport {
        try await stopApp(id, force)
    }

    /// Stops a container, as the app's docker integration stops one.
    public func stopContainer(id: String) async throws -> StopReport {
        try await stopContainerNamed(id)
    }

    /// Stops a project's processes, as the app's coordinator sees them.
    public func stopProject(id: String) async throws -> StopReport {
        try await stopProject(id)
    }
}

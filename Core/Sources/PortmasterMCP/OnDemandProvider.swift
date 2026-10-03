// OnDemandProvider: the real `DataProvider`, answering tool calls straight from
// the machine's telemetry with no Portmaster app running.
//
// The provider itself is the mapping from PortmasterCore's models to the MCP
// `DataProvider` contract. Everything it needs from the outside world arrives as
// a parameter — the snapshot source, the history store, the preferences domain,
// the clock, the process controller, the subprocess runner and the app-liveness
// probe — so a test never signals a real process, writes real preferences, or
// opens the real history database, and so the mappings below can be read without
// a sampler running underneath them.
//
// The seams themselves live next door: `SnapshotAcquisition.swift` (a missing
// reading is reported, never filled in), `HistoryReading.swift` (the store is
// opened only when a history question is actually asked),
// `PreferencesStore.swift`, and `SubprocessRunner.swift`.
import AppKit
import Foundation
import PortmasterCore

// MARK: - App liveness

/// Whether the Portmaster app is running right now.
public enum AppLiveness {
    /// The app's bundle identifier, which is also the `UserDefaults` suite the
    /// app's preferences live in.
    public static let bundleIdentifier = "dev.portmaster.app"

    /// Probed per call rather than captured at construction: the app can be
    /// launched or quit while the MCP server stays up, and both answers matter
    /// (a running app owns its preferences; a running app means liveness-based
    /// mutation policy should follow).
    public static func isPortmasterRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}

// MARK: - Provider

/// `DataProvider` over the machine itself, for an MCP server running without
/// the Portmaster app.
public struct OnDemandProvider: DataProvider {
    /// Said when the sampler has not produced a reading yet. One string for every
    /// path that can report it, so a caller sees the same explanation whichever
    /// tool asked.
    public static var notReadyMessage: String { SnapshotAcquisition.notReadyMessage }

    /// Said when a preference write is refused because the app is running.
    public static let appRunningMessage =
        "Portmaster is running; close it before changing preferences via MCP "
        + "(live writes arrive with the MCP host)."

    /// How long to keep a collected snapshot before collecting again.
    public static let defaultCacheTTL: TimeInterval = 5
    /// Budget for the first reading of a call. Generous because a cold sampler
    /// pays for a process sweep, a port scan and a `nettop` pass before it has
    /// anything to say.
    public static let defaultSnapshotTimeout: TimeInterval = 10
    /// `docker stop` waits for the container's own grace period, so this is
    /// generous; it exists to stop a call hanging forever, not to hurry docker.
    static let dockerStopTimeout: TimeInterval = 20

    private let acquisition: SnapshotAcquisition
    private let history: LazyHistory
    private let preferences: PreferencesStore
    private let now: @Sendable () -> Date
    private let appRunning: @Sendable () -> Bool
    private let settingsDirectory: URL?
    private let stopController: any ProcessControlling
    private let stopIdentity: @Sendable (pid_t) -> StopCoordinator.IdentityState
    private let stopVerifyDelay: TimeInterval
    private let processRunner: any ProcessRunning
    private let dockerExecutable: @Sendable () -> String?

    /// - Parameters:
    ///   - snapshotSource: where readings come from. Defaults to a live
    ///     `SamplingEngine`; tests pass a stub.
    ///   - historyReader: history reads. Defaults to the store at the canonical
    ///     location; tests pass a seeded or failing seam.
    ///   - preferencesDefaults: the app's preferences domain. Defaults to the
    ///     app's own suite.
    ///   - preferencesDomain: suite to open when `preferencesDefaults` is nil.
    ///   - appRunning: whether the app holds the preferences right now.
    ///   - cacheTTL: how long one collected snapshot serves every read.
    ///   - snapshotTimeout: budget for a first reading; after it, reads say the
    ///     sampler is still starting.
    ///   - stopController: what actually signals a process.
    ///   - stopIdentity: how a pid's identity is verified immediately before
    ///     signalling it.
    ///   - stopVerifyDelay: grace period after a signal before a pid is
    ///     reported as still running.
    ///   - processRunner: how `stop_container` runs the docker CLI.
    ///   - dockerExecutable: where the docker CLI is, resolved through the
    ///     collector's own candidate list unless a caller supplies it.
    ///   - now: the clock that decides cache freshness.
    ///   - settingsDirectory: where `mcpMode` and `get_settings` read the MCP
    ///     server's own settings.
    public init(
        snapshotSource: any SnapshotSource = LiveSnapshotSource(),
        historyReader: (any HistoryReading)? = nil,
        preferencesDefaults: UserDefaults? = nil,
        preferencesDomain: String = AppLiveness.bundleIdentifier,
        appRunning: @escaping @Sendable () -> Bool = { AppLiveness.isPortmasterRunning() },
        cacheTTL: TimeInterval = OnDemandProvider.defaultCacheTTL,
        snapshotTimeout: TimeInterval = OnDemandProvider.defaultSnapshotTimeout,
        stopController: any ProcessControlling = KillProcessController(),
        stopIdentity: @escaping @Sendable (pid_t) -> StopCoordinator.IdentityState = {
            StopCoordinator.liveIdentity($0)
        },
        stopVerifyDelay: TimeInterval = 3.0,
        processRunner: any ProcessRunning = SystemProcessRunner(),
        dockerExecutable: @escaping @Sendable () -> String? = { DockerCollector.locate() },
        now: @escaping @Sendable () -> Date = { Date() },
        settingsDirectory: URL? = nil
    ) {
        self.acquisition = SnapshotAcquisition(
            source: snapshotSource, cacheTTL: cacheTTL, snapshotTimeout: snapshotTimeout, now: now
        )
        self.history = LazyHistory {
            if let historyReader { return historyReader }
            return Self.defaultHistory()
        }
        self.preferences = PreferencesStore(
            defaults: preferencesDefaults ?? UserDefaults(suiteName: preferencesDomain) ?? .standard
        )
        self.now = now
        self.appRunning = appRunning
        self.settingsDirectory = settingsDirectory
        self.stopController = stopController
        self.stopIdentity = stopIdentity
        self.stopVerifyDelay = stopVerifyDelay
        self.processRunner = processRunner
        self.dockerExecutable = dockerExecutable
    }

    private static func defaultHistory() -> any HistoryReading {
        StoreHistoryReading.defaultStore()
            ?? UnavailableHistoryReading(
                message: "Could not open the local history database at "
                    + HistoryStore.defaultStoreURL().path + "."
            )
    }

    // MARK: Snapshot reads

    /// A snapshot for a read, from the cache when it is fresh enough. See
    /// `SnapshotAcquisition` for why a stop passes `forceRefresh`.
    private func snapshot(forceRefresh: Bool = false) async throws -> ObservationSnapshot {
        try await acquisition.snapshot(forceRefresh: forceRefresh)
    }

    public func systemOverview() async throws -> SystemSample {
        try await snapshot().system
    }

    public func topApps(metric: AppMetric, limit: Int) async throws -> [AppRollup] {
        // Ranking and truncation are the executor's, which owns the payload and
        // the nil-sorts-last rule; a second ranking here could only disagree
        // with it. `metric` and `limit` are therefore not read here.
        try await snapshot().rollups
    }

    public func appDetail(id: String) async throws -> AppRollup {
        let rollups = try await snapshot().rollups
        guard let rollup = rollups.first(where: { $0.id == id }) else {
            throw MCPToolError(message: "App not found: \(id)")
        }
        return rollup
    }

    public func containers() async throws -> DockerSample {
        // nil means the first `docker` pass has not landed — not "Docker is not
        // installed". Reporting an availability the collector never reported
        // would be a claim about the machine that nothing observed.
        guard let docker = try await snapshot().docker else {
            throw MCPToolError(
                message: "Docker status is not known yet; the first container scan has not finished."
            )
        }
        return docker
    }

    public func temperaturesFans() async throws -> ThermalSample? {
        // nil here is real information: the payload reports `available: false`
        // with null readings, which is exactly what "no SMC sensors" means.
        try await snapshot().system.thermal
    }

    public func projects() async throws -> [ProjectSummary] {
        Self.projectSummaries(from: try await snapshot())
    }

    /// One summary per attributed project, ports joined by pid membership.
    ///
    /// Sorted by process count then id so two calls over the same snapshot
    /// produce the same order — the payload is meant to be byte-stable.
    static func projectSummaries(from snapshot: ObservationSnapshot) -> [ProjectSummary] {
        let attributed = snapshot.processes.compactMap { row in
            row.projectID.map { (id: $0, row: row) }
        }
        let grouped = Dictionary(grouping: attributed, by: \.id)
        var summaries: [ProjectSummary] = []
        summaries.reserveCapacity(grouped.count)
        for (id, rows) in grouped {
            let pids = Set(rows.map(\.row.pid))
            let ports = Array(Set(
                snapshot.ports.filter { pids.contains($0.pid) }.map { Int($0.port) }
            )).sorted()
            summaries.append(ProjectSummary(
                id: id,
                name: (id as NSString).lastPathComponent,
                processCount: rows.count,
                ports: ports
            ))
        }
        return summaries.sorted {
            $0.processCount == $1.processCount ? $0.id < $1.id : $0.processCount > $1.processCount
        }
    }

    // MARK: History reads

    public func historyRankings(
        window: HistoryWindow, resource: HistoryResource?
    ) async throws -> [AppHistoryTrend] {
        // `resource` is documented as always nil: a resource reading belongs to
        // no app, and `historyResources` is where one comes from. Ignoring it
        // here is deliberate — there is no trend-shaped answer to give.
        _ = resource
        do {
            return try await history.get().appTrends(since: window.since)
        } catch {
            throw MCPToolError.wrapping(error, subsystem: "recorded app history")
        }
    }

    public func historyResources(
        window: HistoryWindow, resource: HistoryResource
    ) async throws -> [ResourceHistoryPoint] {
        do {
            return try await history.get().resourceSamples(resource, since: window.since)
        } catch {
            throw MCPToolError.wrapping(error, subsystem: "recorded \(resource.rawValue) history")
        }
    }

    // MARK: Alerts

    /// Alerts reconstructed from recorded history — always tagged
    /// `historyApproximate`, including when there are none.
    ///
    /// Two of the live engine's four signals can be evaluated from history,
    /// because history recorded the observations they need: sustained CPU over
    /// the same window and threshold, and memory growth between two recorded
    /// readings. Per-app disk and network hammering cannot: history stores those
    /// rates per app but not as a sustained per-app average over a window, and a
    /// single sample is a spike, not hammering. Those stay live-only rather than
    /// being approximated into an alert nobody observed.
    public func activeAlerts() async throws -> AlertsSnapshot {
        let now = self.now()
        let trends: [AppHistoryTrend]
        do {
            trends = try await history.get().appTrends(since: now.addingTimeInterval(-AlertEngine.cpuWindow))
        } catch {
            throw MCPToolError.wrapping(error, subsystem: "recorded app history")
        }
        let spans: [AppMemorySpan]
        do {
            spans = try await history.get().appMemorySpans(since: now.addingTimeInterval(-AlertEngine.memGrowthWindow))
        } catch {
            throw MCPToolError.wrapping(error, subsystem: "recorded app history")
        }

        var alerts: [ActingUpAlert] = []
        alerts.reserveCapacity(trends.count + spans.count)
        for trend in trends {
            guard let average = trend.averageCPU, average >= AlertEngine.cpuThreshold else { continue }
            alerts.append(ActingUpAlert(
                id: "history:\(trend.id):sustainedCPU",
                kind: .sustainedCPU,
                appName: trend.displayName,
                headline: "\(trend.displayName) is keeping the CPU busy",
                detail: "\(Int(average))% average over the last 10 minutes, from recorded history.",
                at: trend.lastSeen
            ))
        }
        for span in spans {
            guard span.growthBytes >= AlertEngine.memGrowthBytes else { continue }
            alerts.append(ActingUpAlert(
                id: "history:\(span.appID):memoryGrowth",
                kind: .memoryGrowth,
                appName: span.displayName,
                headline: "\(span.displayName) keeps using more memory",
                detail: "Up \(Fmt.bytes(span.growthBytes)) in the last hour, now "
                    + "\(Fmt.bytes(span.lastBytes)), from recorded history.",
                at: span.lastAt
            ))
        }
        return AlertsSnapshot(
            source: .historyApproximate,
            alerts: alerts.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
        )
    }

    // MARK: Settings

    public func settingsSnapshot() -> SettingsSnapshot {
        let preferences = self.preferences.load()
        return SettingsSnapshot(
            temperatureUnit: preferences.presentation.temperatureUnit.rawValue,
            networkUnit: preferences.presentation.networkUnit.rawValue,
            cpuScale: preferences.presentation.cpuScale.rawValue,
            temperatureSource: preferences.presentation.temperatureSource.rawValue,
            compactMenuBar: preferences.presentation.compact,
            mutationMode: MCPSettings.load(directory: settingsDirectory).mode.rawValue,
            alertsEnabled: preferences.alertsEnabled,
            retention: preferences.retention.rawValue
        )
    }

    /// Changes one allowlisted preference.
    ///
    /// Refused while the app is running: the app holds the decoded preferences
    /// in memory and writes the whole blob on its next change, which would erase
    /// whatever MCP just wrote. The app's Settings screen is the owner then.
    public func setPreference(key: String, value: String) throws {
        guard !appRunning() else {
            throw MCPToolError(message: Self.appRunningMessage)
        }
        if key == "mcpMode" {
            try setMutationMode(value)
            return
        }
        try preferences.setAllowlisted(key: key, value: value)
    }

    /// `mcpMode` is the MCP server's own mutation policy, kept in `MCPSettings`
    /// rather than the app's preferences blob, because the server must be able to
    /// read and write it whether or not the UI is running.
    private func setMutationMode(_ value: String) throws {
        guard let mode = MCPMutationMode(rawValue: value) else {
            throw MCPToolError(message: "Invalid value '\(value)' for 'mcpMode'.")
        }
        var settings = MCPSettings.load(directory: settingsDirectory)
        settings.mode = mode
        do {
            try settings.save(directory: settingsDirectory)
        } catch {
            throw MCPToolError(
                message: "Could not save MCP settings: \(error.localizedDescription)"
            )
        }
    }

    // MARK: Stops

    public func quitApp(id: String, force: Bool) async throws -> StopReport {
        let snapshot = try await snapshot(forceRefresh: true)
        guard let rollup = snapshot.rollups.first(where: { $0.id == id }) else {
            throw MCPToolError(message: "App not found: \(id)")
        }
        // Membership is frozen from this sweep: a process that starts now was not
        // on the list the permission gate approved.
        let targets = ConfirmedStopPlan.ordered(rollup.processes)
        guard !targets.isEmpty else {
            throw MCPToolError(message: "No running processes found for \(rollup.displayName).")
        }
        return await stop(targets, force: force)
    }

    public func stopProject(id: String) async throws -> StopReport {
        let snapshot = try await snapshot(forceRefresh: true)
        let targets = ConfirmedStopPlan.project(id, rows: snapshot.processes)
        guard !targets.isEmpty else {
            throw MCPToolError(message: "No running processes found for project '\(id)'.")
        }
        return await stop(targets, force: false)
    }

    /// Stops a container through the docker CLI.
    ///
    /// Not through the process list: a snapshot has no container-to-pid
    /// attribution, and matching a container to a same-named process would be a
    /// guess about something the caller then acts on. So this runs the one
    /// command that stops a container — `docker stop -- <id>`, fixed argv, the id
    /// as exactly one element and after `--` so an id that starts with `-` cannot
    /// be read as a flag. No shell is involved, so shell metacharacters in an id
    /// are characters, not commands.
    ///
    /// The outcome is docker's own: exit 0 is a stop, a non-zero exit is reported
    /// with what docker said. An id that is not in the snapshot is reported as not
    /// found rather than passed on as a stop that was never attempted.
    public func stopContainer(id: String) async throws -> StopReport {
        let snapshot = try await snapshot(forceRefresh: true)
        guard let docker = snapshot.docker else {
            throw MCPToolError(
                message: "Docker status is not known yet; the first container scan has not finished."
            )
        }
        // Availability first: with the daemon down or docker absent there is no
        // container list to match against, and no stop to attempt.
        switch docker.availability {
        case .notInstalled:
            throw MCPToolError(
                message: "Docker is not installed, so container '\(id)' was not stopped."
            )
        case .daemonDown:
            throw MCPToolError(
                message: "The Docker daemon is not running, so container '\(id)' was not stopped."
            )
        case .running:
            break
        }
        guard docker.containers.contains(where: { $0.id == id || $0.name == id }) else {
            throw MCPToolError(message: "Container not found: \(id)")
        }
        guard let executable = dockerExecutable() else {
            // The sample said docker was there; it is not now.
            throw MCPToolError(
                message: "The docker command is not available, so container '\(id)' was not stopped."
            )
        }

        let outcome: CommandOutcome
        do {
            outcome = try await processRunner.run(
                executable: executable,
                arguments: ["stop", "--", id],
                timeout: Self.dockerStopTimeout
            )
        } catch {
            throw MCPToolError.wrapping(error, subsystem: "docker")
        }
        // Formatted through `StopReport` so a container stop and a pid stop read
        // the same way in the payload.
        let status: StopCoordinator.Outcome.Status = outcome.exitCode == 0
            ? .stopped
            : .failed(message: Self.dockerFailureMessage(outcome))
        return StopReport(results: [id: StopReport.value(for: status)])
    }

    /// Docker's own explanation, first line, or the exit status when docker said
    /// nothing. Never replaced with a guess about what went wrong.
    private static func dockerFailureMessage(_ outcome: CommandOutcome) -> String {
        let firstLine = outcome.standardError
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let firstLine, !firstLine.isEmpty else {
            return "docker exited with status \(outcome.exitCode) and said nothing."
        }
        return firstLine
    }

    /// Signals the confirmed targets and reports each pid's outcome.
    ///
    /// The coordinator re-verifies every pid's identity immediately before its
    /// own signal, and reports `stillRunning` when a pid survives the grace
    /// period, so the report says what happened rather than what was requested.
    private func stop(_ targets: [ConfirmedProcess], force: Bool) async -> StopReport {
        let coordinator = StopCoordinator(
            controller: stopController,
            verifyDelay: stopVerifyDelay,
            identityLookup: stopIdentity
        )
        let outcomes = await coordinator.stopConfirmed(targets, force: force)
        var results: [String: String] = [:]
        for (pid, outcome) in outcomes {
            results[String(pid)] = StopReport.value(for: outcome.status)
        }
        return StopReport(results: results)
    }
}

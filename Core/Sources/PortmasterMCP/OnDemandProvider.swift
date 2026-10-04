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

    /// Said when no sensor reading has been observed yet. One string for the
    /// refusal, so the payload can never be reached with nothing behind it.
    ///
    /// Wording covers both reasons nothing has been observed — the first sensor
    /// pass is still pending, and a pass that could not read the SMC — because
    /// both leave the caller with nothing observed, and neither may be reported
    /// as a machine with no sensors.
    public static let thermalNotSampledMessage =
        "Temperature and fan readings are not known yet; no sensor reading has been observed."

    /// Said when the container scan has not reported yet. One string for every
    /// path that can report it — the on-demand read and its stop, and the app's
    /// proxied read — so a caller sees the same explanation whichever provider
    /// and whichever tool asked.
    public static let dockerNotKnownMessage =
        "Docker status is not known yet; the first container scan has not finished."

    /// Said when no app in the reading answers to an id.
    ///
    /// `static` and shared: a client can reach this provider or `LiveDataProvider`
    /// for the same tool, and the two refusals must be the same sentence.
    static func appNotFound(_ id: String) -> MCPToolError {
        MCPToolError(message: "App not found: \(id)")
    }

    /// Names the recorded history a read asked for, for `MCPToolError.wrapping`.
    ///
    /// A resource reading belongs to no app, so it is named after the resource;
    /// everything else is app history. Built here rather than written at each
    /// throw site because both providers wrap history failures and a wrapper that
    /// named a different subsystem on one path than the other would send a caller
    /// looking in two places for one fault.
    static func historySubsystem(for resource: HistoryResource? = nil) -> String {
        resource.map { "recorded \($0.rawValue) history" } ?? "recorded app history"
    }

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
    ///   - historyFactory: opens the store the first time a history question is
    ///     asked. Defaults to the canonical location; a test passes a seam here so
    ///     it can count the opens and prove the non-history tools make none.
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
    ///   - settingsDirectory: where `get_settings` reads the MCP server's own
    ///     settings from. `set_preference` does not write `mcpMode` here — the
    ///     executor owns that key — so this directory decides what
    ///     `settingsSnapshot()` reports as `mutationMode`, and a test points it at
    ///     a disposable one.
    public init(
        snapshotSource: any SnapshotSource = LiveSnapshotSource(),
        historyFactory: @escaping @Sendable () -> any HistoryReading = {
            OnDemandProvider.openDefaultHistory()
        },
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
        self.history = LazyHistory(historyFactory)
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

    /// Opens the canonical store, or a reading that refuses with the reason.
    ///
    /// Called on the first history question, not at construction: most tool calls
    /// never ask one, and opening a database — which also creates the directory
    /// it lives in — to answer a process question would be a write to the user's
    /// Application Support directory they did not ask for.
    public static func openDefaultHistory() -> any HistoryReading {
        StoreHistoryReading.defaultStore()
            ?? UnavailableHistoryReading(
                message: "Could not open the local history database in "
                    + historyLocationDescription() + "."
            )
    }

    /// Where history lives, written `~`-relative.
    ///
    /// `MCPToolError` is documented as safe to show a caller verbatim, and these
    /// messages reach the audit log on disk. An absolute path would put the
    /// account name in both.
    static func historyLocationDescription() -> String {
        let directory = HistoryStore.defaultStoreURL().deletingLastPathComponent()
        let path = directory.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
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
        //
        // **Known asymmetry, deliberate.** `LiveDataProvider.topApps` *does* read
        // them, through the executor's own `rank` and `validatedLimit`, because a
        // client reaching the proxied path must get the same refused limit the
        // fallback refuses. No payload can tell the two apart: the ranking is a
        // total order and the executor truncates again after either returns.
        try await snapshot().rollups
    }

    public func appDetail(id: String) async throws -> AppRollup {
        let rollups = try await snapshot().rollups
        guard let rollup = rollups.first(where: { $0.id == id }) else {
            throw Self.appNotFound(id)
        }
        return rollup
    }

    public func containers() async throws -> DockerSample {
        // nil means the first `docker` pass has not landed — not "Docker is not
        // installed". Reporting an availability the collector never reported
        // would be a claim about the machine that nothing observed.
        guard let docker = try await snapshot().docker else {
            throw MCPToolError(message: Self.dockerNotKnownMessage)
        }
        return docker
    }

    public func temperaturesFans() async throws -> ThermalSample {
        try Self.thermalSample(from: await snapshot())
    }

    /// The thermal answer for one reading, in three states kept apart.
    ///
    /// nil and `.notSampledYet` are the same fact — nothing has been observed
    /// yet — so both refuse the way `containers()` does: answering
    /// `available: false` for them would be a claim about the user's hardware that
    /// no pass made. `.noSensors` is a different fact, and a narrower one than its
    /// name suggests: the last pass read a working SMC and no *recognized* sensor
    /// produced a plausible reading from it. That is what the caller is told — a
    /// sensor type this collector cannot decode reports the same way a Mac with no
    /// sensors does.
    ///
    /// Shared with `LiveDataProvider` so the two cannot answer `get_temperatures_fans`
    /// differently for the same snapshot.
    static func thermalSample(
        from snapshot: ObservationSnapshot
    ) throws -> ThermalSample {
        guard let thermal = snapshot.system.thermal,
              thermal.availability != .notSampledYet
        else {
            throw MCPToolError(message: thermalNotSampledMessage)
        }
        return thermal
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
            throw MCPToolError.wrapping(error, subsystem: Self.historySubsystem())
        }
    }

    public func historyResources(
        window: HistoryWindow, resource: HistoryResource
    ) async throws -> [ResourceHistoryPoint] {
        do {
            return try await history.get().resourceSamples(resource, since: window.since)
        } catch {
            throw MCPToolError.wrapping(error, subsystem: Self.historySubsystem(for: resource))
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
            throw MCPToolError.wrapping(error, subsystem: Self.historySubsystem())
        }
        let spans: [AppMemorySpan]
        do {
            spans = try await history.get().appMemorySpans(since: now.addingTimeInterval(-AlertEngine.memGrowthWindow))
        } catch {
            throw MCPToolError.wrapping(error, subsystem: Self.historySubsystem())
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
                // The window comes from the same constant the threshold did, so
                // changing one can never leave the sentence describing the other.
                detail: "\(Int(average))% average over the last "
                    + "\(Self.spanDescription(AlertEngine.cpuWindow)), from recorded history.",
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
                detail: "Up \(Fmt.bytes(span.growthBytes)) in the last "
                    + "\(Self.spanDescription(AlertEngine.memGrowthWindow)), now "
                    + "\(Fmt.bytes(span.lastBytes)), from recorded history.",
                at: span.lastAt
            ))
        }
        return AlertsSnapshot(
            source: .historyApproximate,
            alerts: alerts.sorted { $0.at == $1.at ? $0.id < $1.id : $0.at > $1.at }
        )
    }

    /// How long a window reads as in a sentence: "10 minutes", "1 hour".
    /// Derived from the interval rather than written next to it, so a threshold
    /// change cannot leave a message describing a window that is no longer used.
    static func spanDescription(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        func plural(_ count: Int, _ unit: String) -> String {
            "\(count) \(unit)\(count == 1 ? "" : "s")"
        }
        if seconds % 3600 == 0 { return plural(seconds / 3600, "hour") }
        if seconds % 60 == 0 { return plural(seconds / 60, "minute") }
        return plural(seconds, "second")
    }

    // MARK: Settings

    /// Current preferences.
    ///
    /// **Known asymmetry, deliberate.** `PreferencesStore.load()` falls back to
    /// the defaults when the blob is missing *or undecodable*, while
    /// `setPreference` refuses to write over an unreadable blob. That difference
    /// is forced by the protocol: `settingsSnapshot()` cannot throw, so it must
    /// answer something, and a default-valued snapshot is the least-wrong answer
    /// available. The consequence is that `get_settings` can report defaults for a
    /// preferences file this build cannot read — a caller who just wrote a
    /// preference and reads back defaults is looking at this, not at a lost
    /// write. Task 8's README limitations should say so.
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
    /// The app's own preferences are refused while it is running: it holds the
    /// decoded preferences in memory and writes the whole blob on its next
    /// change, which would erase whatever MCP just wrote. The app's Settings
    /// screen is the owner then.
    ///
    /// `mcpMode` is deliberately *not* handled here. It is not an app preference at
    /// all — it is this server's own mutation policy, kept in `MCPSettings` beside
    /// the audit log — so it must not be refused while the app runs, and it must
    /// not be written into a blob the app owns. The executor owns that key
    /// end to end, intercepting it before the provider is touched, and it is the
    /// only place that writes it. A second implementation here would be reachable
    /// only by a caller that bypassed the tool surface, and its two copies of the
    /// invalid-value message had already begun to disagree.
    public func setPreference(key: String, value: String) throws {
        guard !appRunning() else {
            throw MCPToolError(message: Self.appRunningMessage)
        }
        try preferences.setAllowlisted(key: key, value: value)
    }

    // MARK: Stops

    public func quitApp(id: String, force: Bool) async throws -> StopReport {
        let snapshot = try await snapshot(forceRefresh: true)
        guard let rollup = snapshot.rollups.first(where: { $0.id == id }) else {
            throw Self.appNotFound(id)
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
            throw MCPToolError(message: Self.dockerNotKnownMessage)
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

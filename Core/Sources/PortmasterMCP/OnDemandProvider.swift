// OnDemandProvider: the real `DataProvider`, answering tool calls straight from
// the machine's telemetry with no Portmaster app running.
//
// Two ideas carry the file:
//
//  1. **A missing reading is reported, never filled in.** The sampler's
//     "nothing collected yet" value is `ObservationSnapshot.empty`, and passing
//     that on as if it were a measurement is the one failure mode that would
//     make every other number in a payload a lie. Reads wait for a real reading
//     within a budget and then say plainly that there isn't one yet.
//  2. **Every seam is injected.** The snapshot source, the history store, the
//     preferences domain, the clock, the process controller and the app-liveness
//     probe are all parameters, so a test never signals a real process, writes
//     real preferences, or opens the real history database.
import AppKit
import Darwin
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

// MARK: - Snapshot source

/// One reading of the machine's telemetry.
public protocol SnapshotSource: Sendable {
    /// A snapshot collected after this call started.
    ///
    /// - Throws: `MCPToolError` when no reading arrives within `maxWait`. A
    ///   source must never return `ObservationSnapshot.empty` as an answer: that
    ///   value means "the sampler has not produced anything", which is a fact
    ///   the caller deserves to hear.
    func currentSnapshot(maxWait: TimeInterval) async throws -> ObservationSnapshot
}

/// The live source: one long-lived `SamplingEngine`, started on first use.
///
/// Sampling continues between calls on purpose. Several readings Portmaster
/// reports are differences between sweeps — CPU and disk rates need two sweeps,
/// per-process network needs a `nettop` pass — so a sampler started and polled
/// once per tool call would report "unknown" forever. Keeping one engine alive
/// costs a background cadence and makes every call after the first honest.
public final class LiveSnapshotSource: SnapshotSource, @unchecked Sendable {
    /// The engine a live source collects from. Injected so a caller (or a test)
    /// can supply fixture collectors without this file knowing about them.
    public typealias EngineFactory = @Sendable () -> SamplingEngine

    private let engineFactory: EngineFactory
    private let lock = NSLock()
    private var engine: SamplingEngine?

    /// The production engine: real collectors, standard cadence. `surfaceVisible`
    /// is set by `currentSnapshot` rather than here, since it is a policy about
    /// being asked, not about existing.
    public static func defaultEngine() -> SamplingEngine {
        SamplingEngine(
            systemCollector: MachSystemCollector(),
            processCollector: LibprocProcessCollector(),
            portCollector: LsofPortScanner()
        )
    }

    public init(
        engineFactory: @escaping EngineFactory = { LiveSnapshotSource.defaultEngine() }
    ) {
        self.engineFactory = engineFactory
    }

    /// A reading older than this is stale enough to be worth asking for: the
    /// engine's live cadence is 2-5s, so anything under a second old is already
    /// the answer.
    static let refreshThreshold: TimeInterval = 1

    public func currentSnapshot(maxWait: TimeInterval) async throws -> ObservationSnapshot {
        let engine = self.engineOrStart()
        let requestedAt = Date()
        // Ask for a sweep only when the newest reading is already stale. Refreshing
        // on every attempt would stack a full process sweep per poll while a
        // caller waits, which is the opposite of the conservative cadence the
        // engine is built around.
        if Date().timeIntervalSince(engine.latest.at) > Self.refreshThreshold {
            engine.refreshNow()
        }

        let deadline = requestedAt.addingTimeInterval(max(0, maxWait))
        while Date() < deadline {
            let latest = engine.latest
            // The snapshot's own timestamp is the test: a sweep that *started*
            // after we asked carries `at > requestedAt`, so it cannot be a
            // leftover from before the call.
            if latest.at > requestedAt { return latest }
            try await Task.sleep(nanoseconds: OnDemandProvider.pollIntervalNanos)
        }
        let latest = engine.latest
        if latest.at > requestedAt { return latest }
        throw MCPToolError(message: OnDemandProvider.notReadyMessage)
    }

    /// The engine, created and started exactly once. `start()` runs its first
    /// tick on the sampling queue, so this call does not block on a port scan.
    private func engineOrStart() -> SamplingEngine {
        lock.lock()
        defer { lock.unlock() }
        if let engine { return engine }
        let fresh = engineFactory()
        // A tool call is a visible surface: read the live cadence, and never let
        // the engine's idle pause strand it between calls.
        fresh.setSurfaceVisible(true)
        fresh.start()
        engine = fresh
        return fresh
    }

    deinit {
        // The timer chain outlives this object otherwise, and keeps sweeping the
        // machine with nothing left to serve.
        engine?.stop()
    }
}

// MARK: - History

/// The history questions an on-demand alert evaluation and the history tools
/// ask. An injectable seam so a test can read from a seeded store — or refuse —
/// without touching the real database.
public protocol HistoryReading: Sendable {
    func appTrends(since: Date) async throws -> [AppHistoryTrend]
    func resourceSamples(_ resource: HistoryResource, since: Date) async throws -> [ResourceHistoryPoint]
    /// Only apps with at least two readings in the window; see `AppMemorySpan`.
    func appMemorySpans(since: Date) async throws -> [AppMemorySpan]
}

/// History reads over a `HistoryStore`: trends and memory endpoints through the
/// store's reader actor (which keeps the stored models inside it), resource
/// points through the store's own query.
public struct StoreHistoryReading: HistoryReading {
    private let store: HistoryStore

    public init(storeURL: URL? = nil) throws {
        self.store = try HistoryStore(storeURL: storeURL)
    }

    /// The adapter over an already-open store, for a caller that keeps one
    /// around (the app does, for writing).
    public init(store: HistoryStore) {
        self.store = store
    }

    /// The store at the canonical Application Support location, or `nil` when it
    /// cannot be opened — so the provider can report that instead of answering
    /// every history tool with "no data".
    public static func defaultStore() -> StoreHistoryReading? {
        try? StoreHistoryReading(storeURL: nil)
    }

    public func appTrends(since: Date) async throws -> [AppHistoryTrend] {
        try await store.makeReader().appTrends(since: since)
    }

    public func resourceSamples(
        _ resource: HistoryResource, since: Date
    ) async throws -> [ResourceHistoryPoint] {
        store.resourceSamples(resource, since: since)
    }

    public func appMemorySpans(since: Date) async throws -> [AppMemorySpan] {
        try await store.makeReader().appMemorySpans(since: since)
    }
}

/// Stands in when history cannot be opened at all. Every read fails with the
/// reason, so an unreachable database reads as a failure rather than as a
/// machine with no history.
struct UnavailableHistoryReading: HistoryReading {
    let message: String

    func appTrends(since: Date) async throws -> [AppHistoryTrend] { throw MCPToolError(message: message) }
    func resourceSamples(
        _ resource: HistoryResource, since: Date
    ) async throws -> [ResourceHistoryPoint] { throw MCPToolError(message: message) }
    func appMemorySpans(since: Date) async throws -> [AppMemorySpan] { throw MCPToolError(message: message) }
}

// MARK: - Preferences

/// Reads and writes the app's preferences blob.
///
/// `UserDefaults` is not `Sendable`, so this box owns the one instance and the
/// lock serializes the read-modify-write. That lock is not incidental: two MCP
/// calls setting two different preferences concurrently would otherwise each
/// read the same blob and the second write would erase the first one's field.
final class PreferencesStore: @unchecked Sendable {
    /// The preference keys MCP may change, and what each one accepts. Enum
    /// fields take their raw values only; `compact` is the one boolean.
    static let allowedKeys = ["compact", "cpuScale", "networkUnit", "temperatureSource", "temperatureUnit"]

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> AppPreferences {
        AppPreferences.load(from: defaults)
    }

    /// Changes exactly one allowlisted field and writes the whole blob back.
    /// Sibling fields are preserved by construction: the blob is decoded, one
    /// field is mutated, and the rest is re-encoded untouched.
    func setAllowlisted(key: String, value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var preferences = try read()
        try Self.apply(key: key, value: value, to: &preferences)
        try write(preferences)
    }

    private func read() throws -> AppPreferences {
        guard let data = defaults.data(forKey: AppPreferences.defaultsKey) else {
            // No blob yet: the app has never saved preferences, so the defaults
            // are the current state and there is nothing to preserve.
            return AppPreferences()
        }
        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            // Refuse rather than overwrite: a blob this build cannot read may
            // still be one it can preserve field by field, and replacing it with
            // defaults would silently discard the user's preferences.
            throw MCPToolError(
                message: "Could not read Portmaster preferences: \(error.localizedDescription)"
            )
        }
    }

    private func write(_ preferences: AppPreferences) throws {
        do {
            defaults.set(try JSONEncoder().encode(preferences), forKey: AppPreferences.defaultsKey)
        } catch {
            throw MCPToolError(
                message: "Could not save Portmaster preferences: \(error.localizedDescription)"
            )
        }
    }

    static func apply(key: String, value: String, to preferences: inout AppPreferences) throws {
        func invalid() -> MCPToolError {
            MCPToolError(message: "Invalid value '\(value)' for '\(key)'.")
        }
        switch key {
        case "compact":
            // Only the two literals the catalog documents. "yes" or "1" would be
            // a guess about the caller's intent.
            switch value.lowercased() {
            case "true": preferences.presentation.compact = true
            case "false": preferences.presentation.compact = false
            default: throw invalid()
            }
        case "cpuScale":
            guard let scale = CPUScale(rawValue: value) else { throw invalid() }
            preferences.presentation.cpuScale = scale
        case "networkUnit":
            guard let unit = NetworkUnit(rawValue: value) else { throw invalid() }
            preferences.presentation.networkUnit = unit
        case "temperatureSource":
            guard let source = TemperatureSource(rawValue: value) else { throw invalid() }
            preferences.presentation.temperatureSource = source
        case "temperatureUnit":
            guard let unit = TemperatureUnit(rawValue: value) else { throw invalid() }
            preferences.presentation.temperatureUnit = unit
        default:
            throw MCPToolError(
                message: "Preference '\(key)' cannot be changed via MCP. Allowed: "
                    + allowedKeys.joined(separator: ", ") + "."
            )
        }
    }
}

// MARK: - Snapshot cache

/// One cached snapshot and the wall time it was taken.
///
/// A class behind a lock because the provider is a value type handed to
/// concurrent tool calls: without shared storage, "cache the snapshot for five
/// seconds" would mean nothing.
final class SnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (snapshot: ObservationSnapshot, at: Date)?

    /// The cached snapshot if it is younger than `ttl`. A non-positive `ttl`
    /// never hits, which is how a caller asks for an un-cached read.
    func snapshot(ttl: TimeInterval, now: Date) -> ObservationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, now.timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.snapshot
    }

    func store(_ snapshot: ObservationSnapshot, at: Date) {
        lock.lock()
        entry = (snapshot, at)
        lock.unlock()
    }
}

// MARK: - Subprocess seam

/// What one command left behind: the status it exited with, and what it said on
/// stderr.
public struct CommandOutcome: Sendable {
    /// Exit status, or -1 when the process was terminated instead of exiting on
    /// its own. `-1` never comes from a program; it means the timeout stopped it,
    /// and `standardError` then explains that rather than quoting docker.
    public let exitCode: Int32
    public let standardError: String

    public init(exitCode: Int32, standardError: String) {
        self.exitCode = exitCode
        self.standardError = standardError
    }
}

/// Runs one command with an argument list, never a command string.
///
/// The argument type is the whole safety property: a container id goes in as
/// one element, so nothing in it can be read as a flag, a path, or a command.
/// There is no shell anywhere in this path, so shell metacharacters in an id are
/// just characters.
public protocol ProcessRunning: Sendable {
    /// - Throws: `MCPToolError` when the process could not be started at all.
    ///   A non-zero exit is an outcome, not an error: the caller reports what the
    ///   command said.
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> CommandOutcome
}

/// The real runner: `Process` with `executableURL` and `arguments` set
/// separately, exactly as `DockerCollector` runs its sampling passes.
public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(
        executable: String, arguments: [String], timeout: TimeInterval
    ) async throws -> CommandOutcome {
        // `Process` blocks, so it runs off the cooperative pool: a blocked tool
        // call must not take a thread a sibling tool call needs.
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // stdout is docker echoing the id back, which we already know.
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.standardInput = FileHandle.nullDevice
            process.qualityOfService = .utility

            do {
                try process.run()
            } catch {
                throw MCPToolError(
                    message: "Could not start \(executable): \(error.localizedDescription)"
                )
            }

            // A stopped-but-unresponsive daemon makes `docker stop` hang, and a
            // tool call must not hang with it.
            let terminate = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            let kill = DispatchWorkItem {
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout, execute: terminate
            )
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + timeout + 2, execute: kill
            )
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            terminate.cancel()
            kill.cancel()

            guard process.terminationReason != .uncaughtSignal else {
                return CommandOutcome(
                    exitCode: -1,
                    standardError: "\(URL(fileURLWithPath: executable).lastPathComponent) was "
                        + "terminated after \(Int(timeout))s without answering."
                )
            }
            return CommandOutcome(
                exitCode: process.terminationStatus,
                standardError: String(data: data, encoding: .utf8) ?? ""
            )
        }.value
    }
}

// MARK: - Provider

/// `DataProvider` over the machine itself, for an MCP server running without
/// the Portmaster app.
public struct OnDemandProvider: DataProvider {
    /// Said when the sampler has not produced a reading yet. Every path that
    /// could report this uses this one string, so a caller sees the same
    /// explanation whichever tool asked.
    public static let notReadyMessage = "No reading available yet; the sampler is still starting."

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
    /// How often to ask the source again while waiting.
    static let pollIntervalNanos: UInt64 = 50_000_000
    /// `docker stop` waits for the container's own grace period, so this is
    /// generous; it exists to stop a call hanging forever, not to hurry docker.
    static let dockerStopTimeout: TimeInterval = 20

    private let source: any SnapshotSource
    private let history: any HistoryReading
    private let preferences: PreferencesStore
    private let cache: SnapshotCache
    private let cacheTTL: TimeInterval
    private let snapshotTimeout: TimeInterval
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
        self.source = snapshotSource
        self.history = historyReader ?? Self.defaultHistory()
        self.preferences = PreferencesStore(
            defaults: preferencesDefaults ?? UserDefaults(suiteName: preferencesDomain) ?? .standard
        )
        self.cache = SnapshotCache()
        self.cacheTTL = cacheTTL
        self.snapshotTimeout = snapshotTimeout
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

    // MARK: Snapshot acquisition

    /// A snapshot for a read, from the cache when it is fresh enough.
    ///
    /// `forceRefresh` skips the cache for actions that act on live pids: a stop
    /// built from a five-second-old list may target a pid that has since exited
    /// and been reused.
    private func snapshot(forceRefresh: Bool = false) async throws -> ObservationSnapshot {
        if !forceRefresh, let cached = cache.snapshot(ttl: cacheTTL, now: now()) {
            return cached
        }
        let reading = try await firstReading()
        cache.store(reading, at: now())
        return reading
    }

    /// Asks the source for a real reading, retrying until the budget runs out.
    ///
    /// `.empty` is treated as "not yet" rather than as data, and the wait is
    /// measured on the real clock: a caller that injects a fixed clock is
    /// testing cache freshness, and a fake wait would either hang or skip the
    /// very wait this exists to guarantee.
    private func firstReading() async throws -> ObservationSnapshot {
        let deadline = Date().addingTimeInterval(max(0, snapshotTimeout))
        var lastFailure: Error?
        while true {
            // Outside the attempt below, so a cancelled caller stops here instead
            // of being caught and retried until the budget runs out.
            try Task.checkCancellation()
            let attempt: Result<ObservationSnapshot, Error>
            do {
                attempt = .success(
                    try await source.currentSnapshot(maxWait: Self.boundedWait(until: deadline))
                )
            } catch {
                attempt = .failure(error)
            }
            switch attempt {
            case .success(let reading) where reading.at != .distantPast:
                return reading
            case .success:
                // The source answered, but with nothing collected yet.
                lastFailure = nil
            case .failure(let failure):
                lastFailure = failure
            }
            if Date() >= deadline { break }
            try await Task.sleep(nanoseconds: Self.pollIntervalNanos)
        }
        if let lastFailure { throw Self.wrap(lastFailure) }
        throw MCPToolError(message: Self.notReadyMessage)
    }

    /// Per-attempt wait: what is left of the budget, capped so one slow attempt
    /// cannot spend the whole budget on the source's own timeout.
    private static func boundedWait(until deadline: Date) -> TimeInterval {
        min(max(deadline.timeIntervalSinceNow, 0.05), 0.5)
    }

    /// Collector's and database failures arrive as `MCPToolError` so the audit
    /// log records which subsystem failed instead of a Foundation message.
    private static func wrap(_ error: Error, subsystem: String = "sampling") -> MCPToolError {
        if let error = error as? MCPToolError { return error }
        return MCPToolError(
            message: "Could not read \(subsystem) data: \(error.localizedDescription)"
        )
    }

    // MARK: Snapshot reads

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
            return try await history.appTrends(since: window.since)
        } catch {
            throw Self.wrap(error, subsystem: "recorded app history")
        }
    }

    public func historyResources(
        window: HistoryWindow, resource: HistoryResource
    ) async throws -> [ResourceHistoryPoint] {
        do {
            return try await history.resourceSamples(resource, since: window.since)
        } catch {
            throw Self.wrap(error, subsystem: "recorded \(resource.rawValue) history")
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
            trends = try await history.appTrends(since: now.addingTimeInterval(-AlertEngine.cpuWindow))
        } catch {
            throw Self.wrap(error, subsystem: "recorded app history")
        }
        let spans: [AppMemorySpan]
        do {
            spans = try await history.appMemorySpans(since: now.addingTimeInterval(-AlertEngine.memGrowthWindow))
        } catch {
            throw Self.wrap(error, subsystem: "recorded app history")
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
            throw Self.wrap(error, subsystem: "docker")
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
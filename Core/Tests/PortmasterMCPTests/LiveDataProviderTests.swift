// LiveDataProvider: the provider the Portmaster app itself serves.
//
// Every seam is injected, so no test here builds a `SamplingEngine`, reads a real
// SMC, opens the real history database, writes real preferences or signals a
// real process. The snapshot is assembled from PortmasterCore's model
// initializers, history is a stub that fails on demand, and the mutations are
// recorded rather than performed — the app supplies the real closures in Task 5.
//
// The other half of these tests is drift: where this provider and
// `OnDemandProvider` answer the same question, the assertion is that they reach
// for the same code and the same wording, so a client that can reach either one
// cannot be told two different things.
import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

// MARK: - Stubs

/// What the app has published. Either one reading, or one reason there is none —
/// which is how a snapshot source says "the sampler has not produced anything
/// yet" without a sweep being run.
final class PublishedSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ObservationSnapshot?
    private let failure: Error?
    private var reads = 0

    init(_ snapshot: ObservationSnapshot) {
        self.snapshot = snapshot
        self.failure = nil
    }

    init(failingWith failure: Error) {
        self.snapshot = nil
        self.failure = failure
    }

    var readCount: Int { lock.withLock { reads } }

    func current() async throws -> ObservationSnapshot {
        let (snapshot, failure) = lock.withLock { () -> (ObservationSnapshot?, Error?) in
            reads += 1
            return (self.snapshot, self.failure)
        }
        if let failure { throw failure }
        guard let snapshot else {
            throw StubError(message: "this stub was built without a reading")
        }
        return snapshot
    }
}

/// Counts how many times the provider asked for history, so a test can prove the
/// non-history reads never do.
final class HistoryOpener: @unchecked Sendable {
    private let lock = NSLock()
    private let reading: any HistoryReading
    private var opens = 0

    init(_ reading: any HistoryReading = FailingHistoryReading(message: "database is locked")) {
        self.reading = reading
    }

    var openCount: Int { lock.withLock { opens } }

    var open: @Sendable () -> any HistoryReading {
        { [self] in
            lock.withLock { opens += 1 }
            return reading
        }
    }
}

/// Records the mutations that reached the app, instead of performing them, so a
/// test can assert the arguments each closure was handed.
final class RecordedMutations: @unchecked Sendable {
    struct PreferenceWrite: Equatable, Sendable {
        let key: String
        let value: String
    }

    struct AppStop: Equatable, Sendable {
        let id: String
        let force: Bool
    }

    private let lock = NSLock()
    private var preferenceWrites: [PreferenceWrite] = []
    private var appStops: [AppStop] = []
    private var containerStops: [String] = []
    private var projectStops: [String] = []

    var preferences: [PreferenceWrite] { lock.withLock { preferenceWrites } }
    var apps: [AppStop] { lock.withLock { appStops } }
    var containers: [String] { lock.withLock { containerStops } }
    var projects: [String] { lock.withLock { projectStops } }

    func applyPreference(key: String, value: String) {
        lock.withLock { preferenceWrites.append(PreferenceWrite(key: key, value: value)) }
    }

    func stopApp(id: String, force: Bool) async throws -> StopReport {
        lock.withLock { appStops.append(AppStop(id: id, force: force)) }
        return StopReport(results: ["4242": "stopped"])
    }

    func stopContainer(id: String) async throws -> StopReport {
        lock.withLock { containerStops.append(id) }
        return StopReport(results: [id: "stopped"])
    }

    func stopProject(id: String) async throws -> StopReport {
        lock.withLock { projectStops.append(id) }
        return StopReport(results: ["5150": "stopped"])
    }
}

// MARK: - Tests

final class LiveDataProviderTests: XCTestCase {

    // MARK: Reads

    /// The app is the sampler. A read answers from what the app has already
    /// published — it never collects a sweep of its own, and it never opens the
    /// history store to answer a non-history question.
    func testOverviewReadsTheInjectedSnapshot() async throws {
        let published = PublishedSnapshot(Self.snapshot(cpuPercent: 41))
        let history = HistoryOpener()
        let provider = makeProvider(published, history: history)

        let overview = try await provider.systemOverview()

        XCTAssertEqual(overview.at, OnDemandProviderTests.sampleTime)
        XCTAssertEqual(overview.cpu.totalPercent, 41, accuracy: 0.001)
        XCTAssertEqual(published.readCount, 1, "a read asks the app for what it already has")
        XCTAssertEqual(history.openCount, 0, "a snapshot read must not open the history store")

        // Every other snapshot read asks the same source, so no read can answer
        // from a sweep only it ran.
        let detail = try await provider.appDetail(id: "app:Chrome")
        XCTAssertEqual(detail.displayName, "Chrome")
        XCTAssertEqual(published.readCount, 2)
    }

    /// Same ranking and the same refused range as the on-demand path, through the
    /// executor's own code — including a limit that is out of range being an
    /// error rather than a silently clamped one.
    func testTopAppsRanksAndRefusesAnOutOfRangeLimit() async throws {
        let published = PublishedSnapshot(Self.snapshot(rollups: [
            Self.rollup(name: "Slow", netIn: 10),
            Self.rollup(name: "Fast", netIn: 900),
            Self.rollup(name: "Unmeasured", netIn: nil),
        ]))
        let provider = makeProvider(published)

        let ranked = try await provider.topApps(metric: .network, limit: 3)
        XCTAssertEqual(
            ranked.map(\.displayName), ["Fast", "Slow", "Unmeasured"],
            "an unmeasured rate sorts last: reading it as zero would rank an app nothing was "
                + "measured for above a slow one"
        )
        let truncated = try await provider.topApps(metric: .network, limit: 1)
        XCTAssertEqual(
            truncated.map(\.displayName), ["Fast"],
            "the limit truncates the ranking rather than being ignored"
        )

        let readsBefore = published.readCount
        for limit in [0, -1, 101] {
            do {
                _ = try await provider.topApps(metric: .network, limit: limit)
                XCTFail("A limit of \(limit) is outside 1...100 and must be refused, not clamped")
            } catch let error as MCPToolError {
                XCTAssertEqual(error.message, "Invalid limit: \(limit) (must be 1...100)")
            }
        }
        XCTAssertEqual(
            published.readCount, readsBefore,
            "a refused limit is refused before the app is asked for anything"
        )
    }

    /// Grouping is the on-demand provider's function, called with the app's
    /// snapshot — not a second implementation of it that could order the same
    /// processes differently.
    func testProjectsGroupsByProjectIDAndJoinsPorts() async throws {
        let snapshot = Self.snapshot(
            processes: [
                Self.process(pid: 100, name: "node", project: "/Users/dev/code/api"),
                Self.process(pid: 101, name: "esbuild", project: "/Users/dev/code/api"),
                Self.process(pid: 200, name: "redis", project: "/Users/dev/code/redis"),
                // Unattributed: must never appear as a project of its own.
                Self.process(pid: 300, name: "launchd", project: nil),
            ],
            ports: [
                ListeningPort(port: 4000, pid: 100, processName: "node"),
                ListeningPort(port: 8080, pid: 101, processName: "esbuild"),
                ListeningPort(port: 6379, pid: 200, processName: "redis"),
                ListeningPort(port: 22, pid: 300, processName: "launchd"),
            ]
        )
        let provider = makeProvider(PublishedSnapshot(snapshot))

        let projects = try await provider.projects()

        XCTAssertEqual(
            projects.map(\.id), ["/Users/dev/code/api", "/Users/dev/code/redis"],
            "processes without a project id are skipped, and the order is stable"
        )
        XCTAssertEqual(projects[0].name, "api", "the display name is the last path component")
        XCTAssertEqual(projects[0].processCount, 2)
        XCTAssertEqual(projects[0].ports, [4000, 8080], "ports join by pid and sort ascending")
        XCTAssertEqual(projects[1].ports, [6379])
        XCTAssertEqual(projects, OnDemandProvider.projectSummaries(from: snapshot))
    }

    /// The container sample is the app's, whole — including the answer that docker
    /// is there and not answering, which is a fact about the machine and not a
    /// failure of this read. Only "the scan has not reported yet" refuses.
    ///
    /// The cold-snapshot test cannot cover this: it fails before the guard runs.
    func testContainersReturnsTheAppsSampleAndRefusesOnlyAnAbsentOne() async throws {
        let down = DockerSample(
            availability: .daemonDown,
            containers: [OnDemandProviderTests.makeContainer(id: "abc123", name: "api")],
            at: OnDemandProviderTests.sampleTime
        )
        let answered = try await makeProvider(
            PublishedSnapshot(Self.snapshot(docker: down))
        ).containers()
        XCTAssertEqual(
            answered, down,
            "a daemon that is down is reported, not turned into an error or an empty list"
        )

        let refusal = await refusal("a reading with no docker sample") {
            _ = try await makeProvider(
                PublishedSnapshot(Self.snapshot(docker: nil))
            ).containers()
        }
        XCTAssertEqual(
            refusal.message, OnDemandProvider.dockerNotKnownMessage,
            "absent means not scanned yet, which is not 'Docker is not installed'"
        )
    }

    /// The live `AlertEngine`'s answer, handed over whole. The source travels with
    /// it because an empty list cannot say which evaluation produced it — and
    /// with the app in the loop, "no alerts" really can mean the live engine ran
    /// and found nothing, which is a fact worth being able to state.
    func testAlertsCarryLiveSourceEvenWhenEmpty() async throws {
        let none = try await makeProvider(
            PublishedSnapshot(Self.snapshot()),
            alerts: { AlertsSnapshot(source: .live, alerts: []) }
        ).activeAlerts()
        XCTAssertEqual(none.source, .live)
        XCTAssertEqual(none.alerts, [])

        let raised = ActingUpAlert(
            id: "diskHammering:build:4242", kind: .diskHammering, appName: "build",
            headline: AlertCopy.headline(.diskHammering, appName: "build"),
            detail: AlertCopy.diskHammering("80 MB/s", source: .live),
            at: OnDemandProviderTests.sampleTime
        )
        let some = try await makeProvider(
            PublishedSnapshot(Self.snapshot()),
            alerts: { AlertsSnapshot(source: .live, alerts: [raised]) }
        ).activeAlerts()
        XCTAssertEqual(some.source, .live)
        XCTAssertEqual(
            some.alerts, [raised],
            "the app's alerts are the answer; a provider may not rank or filter them"
        )
    }

    /// The refusal a cold sampler gets, in the words the on-demand path uses. A
    /// provider that has nothing published says so rather than answering from
    /// an empty snapshot, which would be a reading nobody took.
    func testNoSnapshotYetThrowsTheHonestNotStartedError() async throws {
        let provider = makeProvider(
            PublishedSnapshot(
                failingWith: MCPToolError(message: OnDemandProvider.notReadyMessage)
            )
        )

        // Every snapshot-backed read refuses identically.
        let reads: [() async throws -> Void] = [
            { _ = try await provider.systemOverview() },
            { _ = try await provider.topApps(metric: .cpu, limit: 10) },
            { _ = try await provider.appDetail(id: "app:Chrome") },
            { _ = try await provider.projects() },
            { _ = try await provider.containers() },
            { _ = try await provider.temperaturesFans() },
        ]
        for read in reads {
            do {
                _ = try await read()
                XCTFail("A sampler that has published nothing must not answer with a reading")
            } catch let error as MCPToolError {
                XCTAssertEqual(
                    error.message, OnDemandProvider.notReadyMessage,
                    "both providers must refuse a cold sampler in the same words"
                )
            }
        }

        // A fault that is not "not yet" is wrapped rather than dropped, so the
        // audit log names the subsystem that failed.
        let broken = makeProvider(PublishedSnapshot(failingWith: StubError(message: "collector died")))
        do {
            _ = try await broken.systemOverview()
            XCTFail("A collector fault must not be reported as a missing reading")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("sampling"), error.message)
            XCTAssertTrue(error.message.contains("collector died"), error.message)
        }
    }

    /// The three thermal answers, kept apart: nothing observed refuses, a
    /// completed pass with no readable sensor answers, a pass with readings
    /// answers with them. The messages and the states are the on-demand
    /// provider's, because `get_temperatures_fans` is one tool.
    func testTemperaturesFansKeepsTheThreeAnswersApart() async throws {
        for thermal in [ThermalSample?.none, .some(ThermalSample.notSampledYet)] {
            let provider = makeProvider(PublishedSnapshot(Self.snapshot(thermal: thermal)))
            do {
                let answered = try await provider.temperaturesFans()
                XCTFail("an unfinished sensor pass must refuse, not answer \(answered.availability)")
            } catch let error as MCPToolError {
                XCTAssertEqual(error.message, OnDemandProvider.thermalNotSampledMessage)
            }
        }

        let noSensors = try await makeProvider(
            PublishedSnapshot(Self.snapshot(thermal: .noSensors))
        ).temperaturesFans()
        XCTAssertEqual(noSensors.availability, .noSensors)
        XCTAssertNil(noSensors.cpuTempC, "an unreadable sensor is absent, never a fabricated zero")

        let readings = ThermalSample.readings(
            cpuTempC: 71.5, gpuTempC: nil, hottestTempC: 71.5,
            fans: [FanSample(name: "Fan 1", currentRPM: 1_800)]
        )
        let available = try await makeProvider(
            PublishedSnapshot(Self.snapshot(thermal: readings))
        ).temperaturesFans()
        XCTAssertEqual(available, readings, "the app's own sensor pass is the answer")
    }

    // MARK: History

    /// A history failure reaches the caller as an `MCPToolError` naming what
    /// failed — a bare Foundation error renders as "The operation couldn't be
    /// completed…" — and the store is only opened by a history question.
    ///
    /// The message is pinned exactly, against the same failing seam driven through
    /// `OnDemandProvider`. `contains("history")` would pass just as happily for a
    /// bare `"history"` subsystem as for the two this names, so it would protect
    /// nothing: the whole point of both providers wrapping a history failure the
    /// same way is that the two sentences are the same sentence.
    func testHistoryFailureIsWrappedNamingTheSubsystem() async throws {
        let history = HistoryOpener(FailingHistoryReading(message: "database is locked"))
        let provider = makeProvider(PublishedSnapshot(Self.snapshot()), history: history)

        _ = try await provider.projects()
        XCTAssertEqual(history.openCount, 0, "only a history question opens the store")

        // The fallback, over the same failing seam: what the proxied path must say.
        let onDemand = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            historyFactory: { FailingHistoryReading(message: "database is locked") },
            appRunning: { false },
            snapshotTimeout: 0.1
        )
        let locked = StubError(message: "database is locked")

        let rankings = await refusal("the proxied rankings read") {
            _ = try await provider.historyRankings(window: .h1, resource: nil)
        }
        let onDemandRankings = await refusal("the on-demand rankings read") {
            _ = try await onDemand.historyRankings(window: .h1, resource: nil)
        }
        XCTAssertEqual(rankings, onDemandRankings)
        XCTAssertEqual(
            rankings,
            MCPToolError.wrapping(locked, subsystem: OnDemandProvider.historySubsystem()),
            "and it is the subsystem name the on-demand path builds, not a similar one"
        )

        let resources = await refusal("the proxied resources read") {
            _ = try await provider.historyResources(window: .h1, resource: .gpu)
        }
        XCTAssertEqual(
            resources,
            MCPToolError.wrapping(locked, subsystem: OnDemandProvider.historySubsystem(for: .gpu)),
            "a resource read names the resource, exactly as the fallback does"
        )
        XCTAssertEqual(history.openCount, 1, "the store is opened once and kept")
    }

    // MARK: Settings

    /// A key outside the allowlist is refused with the words the on-demand path
    /// uses, built from the executor's own list — and it never reaches the app.
    func testSetPreferenceRejectsAKeyOutsideTheAllowlist() async throws {
        let mutations = RecordedMutations()
        let provider = makeProvider(PublishedSnapshot(Self.snapshot()), mutations: mutations)

        // `do`/`catch` rather than `XCTAssertThrowsError`: that takes a synchronous
        // autoclosure, and `setPreference` is `async` so a host can hand a write to
        // another actor by suspending rather than by blocking one.
        do {
            try await provider.setPreference(key: "alertsEnabled", value: "false")
            XCTFail("a key outside the allowlist must be refused")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error,
                MCPToolError(
                    message: "Preference 'alertsEnabled' cannot be changed via MCP. Allowed: "
                        + ToolExecutor.allowedPreferenceKeysDescription() + "."
                ),
                "the proxied path must refuse a key exactly as the fallback does"
            )
        }
        XCTAssertEqual(
            mutations.preferences, [],
            "a refused key must not be handed to the app to refuse there"
        )
    }

    /// An unusable value is refused in the same words too: one client can reach
    /// either provider, so a value this path rejects cannot be applied by the app
    /// while the other path rejects it.
    func testSetPreferenceRejectsAnInvalidValueWithSliceOneWording() async throws {
        let mutations = RecordedMutations()
        let provider = makeProvider(PublishedSnapshot(Self.snapshot()), mutations: mutations)

        do {
            try await provider.setPreference(key: "temperatureUnit", value: "kelvin")
            XCTFail("a value no case matches must be refused")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error,
                MCPToolError(message: "Invalid value 'kelvin' for 'temperatureUnit'.")
            )
        }
        XCTAssertEqual(mutations.preferences, [], "a refused value must not reach the app")
    }

    // MARK: Mutations

    /// Every mutation is the app's to perform: the provider hands on the
    /// arguments and returns the app's report unchanged. No id is checked,
    /// resolved or signalled here — the app's own snapshot and its stop
    /// coordinator own that.
    func testMutationsDelegateToTheInjectedClosures() async throws {
        let mutations = RecordedMutations()
        let provider = makeProvider(PublishedSnapshot(Self.snapshot()), mutations: mutations)

        let quit = try await provider.quitApp(id: "app:Chrome", force: true)
        XCTAssertEqual(quit, StopReport(results: ["4242": "stopped"]))
        let container = try await provider.stopContainer(id: "abc123")
        XCTAssertEqual(container, StopReport(results: ["abc123": "stopped"]))
        let project = try await provider.stopProject(id: "/Users/dev/code/api")
        XCTAssertEqual(project, StopReport(results: ["5150": "stopped"]))
        try await provider.setPreference(key: "temperatureUnit", value: "fahrenheit")

        XCTAssertEqual(mutations.apps, [RecordedMutations.AppStop(id: "app:Chrome", force: true)])
        XCTAssertEqual(mutations.containers, ["abc123"])
        XCTAssertEqual(mutations.projects, ["/Users/dev/code/api"])
        XCTAssertEqual(
            mutations.preferences,
            [RecordedMutations.PreferenceWrite(key: "temperatureUnit", value: "fahrenheit")],
            "the value is handed on as the caller wrote it, not normalized on the way"
        )
    }

    /// `get_settings` answers from the app rather than from a preferences blob of
    /// its own, so what it reports is what the app currently holds.
    func testSettingsSnapshotReturnsTheAppsValue() async throws {
        let provider = makeProvider(PublishedSnapshot(Self.snapshot()))

        let settings = await provider.settingsSnapshot()

        XCTAssertEqual(settings.temperatureUnit, "fahrenheit")
        XCTAssertEqual(settings.networkUnit, "bits")
        XCTAssertEqual(settings.cpuScale, "perMac")
        XCTAssertEqual(settings.temperatureSource, "gpu")
        XCTAssertTrue(settings.compactMenuBar)
        XCTAssertEqual(settings.mutationMode, "allowSession")
        XCTAssertFalse(settings.alertsEnabled)
        XCTAssertEqual(settings.retention, "days7")
    }

    // MARK: Helpers

    /// The `MCPToolError` a read threw. Fails the test if it answered instead,
    /// or threw something that is not an `MCPToolError` — both of which would
    /// otherwise be compared away as a placeholder.
    private func refusal(
        _ what: String, _ read: () async throws -> Void
    ) async -> MCPToolError {
        do {
            try await read()
        } catch let error as MCPToolError {
            return error
        } catch {
            XCTFail("\(what) threw \(error), which names no subsystem")
            return MCPToolError(message: "unreachable")
        }
        XCTFail("\(what) answered instead of refusing")
        return MCPToolError(message: "unreachable")
    }

    /// A provider over the stubs, so a test only spells out the seam it is about.
    private func makeProvider(
        _ published: PublishedSnapshot,
        alerts: @escaping @Sendable () -> AlertsSnapshot = {
            AlertsSnapshot(source: .live, alerts: [])
        },
        history: HistoryOpener = HistoryOpener(),
        mutations: RecordedMutations = RecordedMutations()
    ) -> LiveDataProvider {
        LiveDataProvider(
            snapshot: { try await published.current() },
            alerts: alerts,
            history: history.open,
            settings: { Self.settings },
            // Wrapped rather than passed as method references: a reference to a
            // class method is not `@Sendable`, and these seams cross actors.
            applyPreference: { key, value in mutations.applyPreference(key: key, value: value) },
            stopApp: { id, force in try await mutations.stopApp(id: id, force: force) },
            stopContainerNamed: { id in try await mutations.stopContainer(id: id) },
            stopProject: { id in try await mutations.stopProject(id: id) }
        )
    }

    /// The preferences the app is holding, handed over verbatim. Never a real
    /// preferences blob: this provider reads the app's, it does not decode one.
    static let settings = SettingsSnapshot(
        temperatureUnit: "fahrenheit", networkUnit: "bits", cpuScale: "perMac",
        temperatureSource: "gpu", compactMenuBar: true, mutationMode: "allowSession",
        alertsEnabled: false, retention: "days7"
    )

    // MARK: Fixtures

    static func snapshot(
        cpuPercent: Double = 10,
        processes: [ProcessRow] = [],
        ports: [ListeningPort] = [],
        rollups: [AppRollup]? = nil,
        docker: DockerSample? = nil,
        thermal: ThermalSample? = nil
    ) -> ObservationSnapshot {
        OnDemandProviderTests.makeSnapshot(
            cpuPercent: cpuPercent,
            processes: processes,
            ports: ports,
            rollups: rollups ?? [Self.rollup(name: "Chrome", netIn: 1_000)],
            docker: docker,
            thermal: thermal
        )
    }

    static func process(pid: Int32, name: String, project: String?) -> ProcessRow {
        OnDemandProviderTests.makeProcess(pid: pid, name: name, project: project)
    }

    /// One rollup with a single process, whose download rate is `netIn` — or
    /// unmeasured when it is nil, which is what the sampler's own nil rate looks
    /// like before nettop's first pass.
    static func rollup(name: String, netIn: Double?) -> AppRollup {
        var rollup = AppRollup(id: "app:\(name)", displayName: name, isAppBundle: true)
        var row = OnDemandProviderTests.makeProcess(pid: 4_242, name: name)
        row.netInBytesPerSec = netIn
        rollup.processes = [row]
        return rollup
    }
}

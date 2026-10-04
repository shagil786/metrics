import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

// MARK: - Stubs
//
// Every seam the provider takes is injected here, so no test signals a real
// process, writes real preferences, or reads the real history database.

/// A snapshot source that answers with canned snapshots and counts its calls,
/// so a test can prove a read was served from the provider's cache rather than
/// collected again.
final class StubSnapshotSource: SnapshotSource, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [ObservationSnapshot]
    private var calls = 0

    init(_ snapshots: [ObservationSnapshot]) { self.snapshots = snapshots }

    var callCount: Int { lock.withLock { calls } }

    func currentSnapshot(maxWait: TimeInterval) async throws -> ObservationSnapshot {
        let index = lock.withLock { () -> Int in
            let index = calls
            calls += 1
            return index
        }
        // A stub that runs out of snapshots keeps answering with the last one,
        // which is what a sampler that has stopped advancing looks like.
        return snapshots[min(index, snapshots.count - 1)]
    }
}

/// A source that never produces a reading at all.
func stubSnapshotSourceWithoutReading() -> StubSnapshotSource {
    StubSnapshotSource([.empty])
}

/// Injectable wall clock, so cache freshness is testable without sleeping.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) { self.date = date }

    var now: Date { lock.withLock { date } }

    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}

/// Records which pids were signalled instead of signalling them, and flips the
/// stub identity to "gone" so the coordinator's verification sees a stop.
final class RecordingProcessController: ProcessControlling, @unchecked Sendable {
    let isSupported = true
    let unsupportedReason: String? = nil

    private let lock = NSLock()
    private var graceful: [pid_t] = []
    private var forced: [pid_t] = []
    private let identity: StubIdentity

    init(identity: StubIdentity) { self.identity = identity }

    var gracefullySignalled: [pid_t] { lock.withLock { graceful } }
    var forceSignalled: [pid_t] { lock.withLock { forced } }

    func gracefulStop(pid: pid_t) throws {
        lock.withLock { graceful.append(pid) }
        identity.markSignalled(pid)
    }

    func forceQuit(pid: pid_t) throws {
        lock.withLock { forced.append(pid) }
        identity.markSignalled(pid)
    }
}

/// Identity answers for pids that do not exist: "running" with the fixture's
/// start date until something signals them, then gone. Lets the real
/// `StopCoordinator` run end to end without a real process.
final class StubIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var signalled: Set<pid_t> = []

    init(start: Date) { self.start = start }

    func state(_ pid: pid_t) -> StopCoordinator.IdentityState {
        lock.withLock { signalled.contains(pid) ? .gone : .running(startedAt: start) }
    }

    func markSignalled(_ pid: pid_t) { lock.withLock { _ = signalled.insert(pid) } }
}

/// Records how a command would have been run and returns a canned outcome,
/// so a test can assert the argv — and prove a hostile id is one element —
/// without a docker binary existing on the machine.
final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private let outcome: CommandOutcome
    private let failure: Error?

    init(outcome: CommandOutcome, failure: Error? = nil) {
        self.outcome = outcome
        self.failure = failure
    }

    var invocations: [Invocation] { lock.withLock { recorded } }

    func run(
        executable: String, arguments: [String], timeout: TimeInterval
    ) async throws -> CommandOutcome {
        lock.withLock {
            recorded.append(Invocation(
                executable: executable, arguments: arguments, timeout: timeout
            ))
        }
        if let failure { throw failure }
        return outcome
    }
}

/// Counts how many times a provider opened history, so a test can prove the
/// non-history tools never touch the database.
final class CountingHistoryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var opens = 0
    private let reading: @Sendable () -> any HistoryReading

    init(reading: @escaping @Sendable () -> any HistoryReading = {
        FailingHistoryReading(message: "database is locked")
    }) {
        self.reading = reading
    }

    var openCount: Int { lock.withLock { opens } }
    var factory: @Sendable () -> any HistoryReading {
        { [self] in
            lock.withLock { opens += 1 }
            return reading()
        }
    }
}

/// A source that fails outright, to tell a real collector fault apart from
/// "not ready yet".
final class FailingSnapshotSource: SnapshotSource, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let error: Error

    init(error: Error) { self.error = error }

    var callCount: Int { lock.withLock { calls } }

    func currentSnapshot(maxWait: TimeInterval) async throws -> ObservationSnapshot {
        lock.withLock { calls += 1 }
        throw error
    }
}

/// A source that reports "not ready" the way a live sampler does.
final class NotReadySnapshotSource: SnapshotSource, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func currentSnapshot(maxWait: TimeInterval) async throws -> ObservationSnapshot {
        lock.withLock { calls += 1 }
        throw MCPToolError(message: SnapshotAcquisition.notReadyMessage)
    }
}

/// A history seam that always fails, so the provider's error wrapping is
/// observable without breaking a real database.
struct FailingHistoryReading: HistoryReading {
    let message: String
    func appTrends(since: Date) async throws -> [AppHistoryTrend] { throw StubError(message: message) }
    func resourceSamples(_ resource: HistoryResource, since: Date) async throws -> [ResourceHistoryPoint] {
        throw StubError(message: message)
    }
    func appMemorySpans(since: Date) async throws -> [AppMemorySpan] { throw StubError(message: message) }
}

struct StubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Tests

final class OnDemandProviderTests: XCTestCase {

    // MARK: Snapshot acquisition

    /// The first tick may not have landed. The honest answer is "not yet",
    /// never `.empty` handed back as if it were a reading.
    func testSnapshotTimeoutThrowsHonestError() async throws {
        let source = stubSnapshotSourceWithoutReading()
        let provider = OnDemandProvider(
            snapshotSource: source,
            appRunning: { false },
            snapshotTimeout: 0.2,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        do {
            _ = try await provider.systemOverview()
            XCTFail("A sampler that has produced no reading must not answer with one")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error.message, "No reading available yet; the sampler is still starting."
            )
        }
        XCTAssertGreaterThan(
            source.callCount, 1,
            "the provider must keep asking within its wait budget rather than give up after one try"
        )
    }

    /// Opening the history database is a write to the user's Application Support
    /// directory, and most tool calls never ask a history question. So the store
    /// must stay shut for snapshot, stop and container calls — which also means a
    /// unit-test run cannot touch the developer's real database.
    func testOnlyHistoryQuestionsOpenTheHistoryStore() async throws {
        let history = CountingHistoryFactory()
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let identity = StubIdentity(start: startedAt)
        let snapshot = Self.makeSnapshot(
            cpuPercent: 10,
            processes: [Self.makeProcess(pid: 4242, name: "app", startedAt: startedAt)],
            rollups: [Self.makeRollup(name: "app", pids: [4242], startedAt: startedAt)],
            docker: DockerSample(
                availability: .running,
                containers: [Self.makeContainer(id: "abc123", name: "api")],
                at: Self.sampleTime
            )
        )
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([snapshot]),
            historyFactory: history.factory,
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            stopController: RecordingProcessController(identity: identity),
            stopIdentity: { identity.state($0) },
            stopVerifyDelay: 0,
            processRunner: RecordingProcessRunner(
                outcome: CommandOutcome(exitCode: 0, standardError: "")
            ),
            dockerExecutable: { "/test/docker" }
        )

        _ = try await provider.systemOverview()
        _ = try await provider.projects()
        _ = try await provider.containers()
        _ = try await provider.quitApp(id: "app:app", force: false)
        _ = try await provider.stopContainer(id: "abc123")
        XCTAssertEqual(
            history.openCount, 0,
            "no snapshot, stop or container call may open the history database"
        )

        // A history question opens it — once, and then it is reused.
        _ = try? await provider.activeAlerts()
        XCTAssertEqual(history.openCount, 1)
        _ = try? await provider.historyRankings(window: .h1, resource: nil)
        XCTAssertEqual(
            history.openCount, 1,
            "the store is opened once and kept, not reopened per question"
        )
    }

    /// A refusing reading is what an unreachable database looks like, and the
    /// location it names must not carry the account name into the audit log.
    func testUnavailableHistorySaysWhyItCannotAnswer() async throws {
        let location = OnDemandProvider.historyLocationDescription()
        XCTAssertTrue(location.hasPrefix("~"), "the path must be home-relative: \(location)")
        XCTAssertFalse(
            location.contains(FileManager.default.homeDirectoryForCurrentUser.lastPathComponent),
            "an MCPToolError message is shown verbatim and logged; it must not name the account"
        )
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            historyFactory: {
                UnavailableHistoryReading(
                    message: "Could not open the local history database in \(location)."
                )
            },
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            snapshotTimeout: 0.1
        )

        do {
            _ = try await provider.historyRankings(window: .h1, resource: nil)
            XCTFail("An unreachable database must not read as a machine with no history")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error.message, "Could not open the local history database in \(location)."
            )
        }
    }

    /// A genuine collector failure is reported at once. Waiting out the whole
    /// budget for an error that will not fix itself would only make a clear fault
    /// slow and vague about its cause.
    func testSourceFailureIsReportedWithoutRetrying() async throws {
        let source = FailingSnapshotSource(
            error: MCPToolError(message: "Could not read sampling data: libproc denied")
        )
        let provider = OnDemandProvider(
            snapshotSource: source,
            historyFactory: { FailingHistoryReading(message: "unused") },
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            snapshotTimeout: 5
        )

        do {
            _ = try await provider.systemOverview()
            XCTFail("A broken collector must fail the call")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error.message, "Could not read sampling data: libproc denied",
                "the provider's own wording must survive the wrap"
            )
        }
        XCTAssertEqual(
            source.callCount, 1,
            "a real fault must not be retried for the rest of the budget"
        )
    }

    /// "Not yet" is the one failure worth waiting out, so it is the one the
    /// budget applies to.
    func testNotReadySourceIsWaitedOutUntilTheBudgetEnds() async throws {
        let source = NotReadySnapshotSource()
        let provider = OnDemandProvider(
            snapshotSource: source,
            historyFactory: { FailingHistoryReading(message: "unused") },
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            snapshotTimeout: 0.3
        )

        do {
            _ = try await provider.systemOverview()
            XCTFail("A sampler that never produces a reading must not answer")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, SnapshotAcquisition.notReadyMessage)
        }
        XCTAssertGreaterThan(source.callCount, 1, "not-ready must be polled, not failed")
    }

    /// Two reads inside the TTL cost one collection; a read after the TTL
    /// collects again.
    func testSnapshotCachedWithinTTL() async throws {
        let clock = TestClock()
        let source = StubSnapshotSource([Self.makeSnapshot(cpuPercent: 42)])
        let provider = OnDemandProvider(
            snapshotSource: source,
            appRunning: { false },
            cacheTTL: 5,
            now: { clock.now }
        )

        _ = try await provider.systemOverview()
        _ = try await provider.projects()
        XCTAssertEqual(
            source.callCount, 1,
            "the second read inside the TTL must be served from the cached snapshot"
        )

        clock.advance(5.001)
        _ = try await provider.projects()
        XCTAssertEqual(source.callCount, 2, "a read past the TTL must collect again")
    }

    func testSystemOverviewReturnsTheSnapshotSystemSample() async throws {
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([Self.makeSnapshot(cpuPercent: 17.5)]),
            appRunning: { false }
        )

        let sample = try await provider.systemOverview()

        XCTAssertEqual(sample.cpu.totalPercent, 17.5, accuracy: 0.001)
        XCTAssertEqual(sample.at, Self.sampleTime)
    }

    func testTopAppsReturnsSnapshotRollups() async throws {
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([
                Self.makeSnapshot(cpuPercent: 10, processes: [Self.makeProcess(pid: 700, name: "worker")])
            ]),
            appRunning: { false }
        )

        let rollups = try await provider.topApps(metric: .cpu, limit: 5)

        XCTAssertEqual(rollups.map(\.displayName), ["worker"])
        XCTAssertEqual(rollups.first?.totalCPU ?? 0, 10, accuracy: 0.001)
    }

    /// A limit outside `1...100` is refused here, not clamped, and refused before
    /// the machine is swept. `LiveDataProvider` refuses the same range in the same
    /// words for the same reason: a client can reach either provider, so neither
    /// may be the one that quietly turns 101 into 100.
    func testTopAppsRefusesAnOutOfRangeLimitBeforeCollectingAnything() async throws {
        let source = StubSnapshotSource([Self.makeSnapshot(cpuPercent: 10)])
        let provider = OnDemandProvider(snapshotSource: source, appRunning: { false })

        for limit in [0, -1, 101] {
            do {
                _ = try await provider.topApps(metric: .cpu, limit: limit)
                XCTFail("A limit of \(limit) is outside 1...100 and must be refused, not clamped")
            } catch let error as MCPToolError {
                XCTAssertEqual(error.message, "Invalid limit: \(limit) (must be 1...100)")
            }
        }
        XCTAssertEqual(
            source.callCount, 0,
            "an unusable limit is refused before a process sweep is paid for"
        )
    }

    func testAppDetailUnknownIDIsAnHonestError() async throws {
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([Self.makeSnapshot(cpuPercent: 10)]),
            appRunning: { false }
        )

        do {
            _ = try await provider.appDetail(id: "bin:nope")
            XCTFail("An id that is not in the snapshot must not produce a rollup")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, "App not found: bin:nope")
        }
    }

    // MARK: Containers

    /// Docker being down is a fact about the machine, so it must survive the
    /// provider intact rather than becoming an error or a fabricated list.
    func testContainersMapsAvailabilityThrough() async throws {
        let docker = DockerSample(
            availability: .daemonDown,
            containers: [Self.makeContainer(id: "abc123", name: "api")],
            at: Self.sampleTime
        )
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([
                Self.makeSnapshot(cpuPercent: 10, docker: docker)
            ]),
            appRunning: { false }
        )

        let sample = try await provider.containers()

        XCTAssertEqual(sample.availability, .daemonDown)
        XCTAssertEqual(sample.containers.map(\.id), ["abc123"])
        XCTAssertEqual(sample.containers.first?.name, "api")
    }

    func testContainersWithoutAScannedSampleIsAnHonestError() async throws {
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([Self.makeSnapshot(cpuPercent: 10, docker: nil)]),
            appRunning: { false }
        )

        do {
            _ = try await provider.containers()
            XCTFail("An unscanned Docker pass must not be reported as 'not installed'")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains("not known yet"), error.message
            )
        }
    }

    /// The sensor pass runs on the engine's slow lane, so the very first snapshot
    /// after a cold start carries no thermal reading at all — and a nil reading in
    /// that snapshot means "not sampled yet", not "this machine has no sensors".
    /// The two must not look alike to a caller, so the unsampled snapshot refuses
    /// and the sampled one answers.
    func testTemperaturesDistinguishUnsampledFromSampled() async throws {
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([
                Self.makeSnapshot(cpuPercent: 10, thermal: nil),
                Self.makeSnapshot(
                    cpuPercent: 10,
                    thermal: ThermalSample.readings(
                        cpuTempC: 71.5, gpuTempC: nil, hottestTempC: 71.5, fans: []
                    )
                )
            ]),
            appRunning: { false },
            cacheTTL: 0
        )

        do {
            _ = try await provider.temperaturesFans()
            XCTFail("An unsampled sensor pass must not be reported as a machine with no sensors")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, OnDemandProvider.thermalNotSampledMessage)
        }

        // The next snapshot does carry a sample, so the same tool now answers.
        let sampled = try await provider.temperaturesFans()
        XCTAssertEqual(sampled.cpuTempC ?? 0, 71.5, accuracy: 0.001)
        XCTAssertEqual(sampled.hottestTempC ?? 0, 71.5, accuracy: 0.001)
    }

    // MARK: Projects

    func testProjectsGroupsProcessesAndJoinsPorts() async throws {
        let snapshot = Self.makeSnapshot(
            cpuPercent: 10,
            processes: [
                Self.makeProcess(pid: 100, name: "node", project: "/Users/dev/code/api"),
                Self.makeProcess(pid: 101, name: "esbuild", project: "/Users/dev/code/api"),
                Self.makeProcess(pid: 200, name: "redis", project: "/Users/dev/code/redis"),
                // Unattributed: must never appear as a project of its own.
                Self.makeProcess(pid: 300, name: "launchd", project: nil),
            ],
            ports: [
                ListeningPort(port: 4000, pid: 100, processName: "node"),
                ListeningPort(port: 8080, pid: 101, processName: "esbuild"),
                ListeningPort(port: 6379, pid: 200, processName: "redis"),
                ListeningPort(port: 22, pid: 300, processName: "launchd"),
            ]
        )
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([snapshot]),
            appRunning: { false }
        )

        let projects = try await provider.projects()

        XCTAssertEqual(projects.count, 2, "processes without a project id are skipped")
        XCTAssertEqual(projects.map(\.id), ["/Users/dev/code/api", "/Users/dev/code/redis"])
        XCTAssertEqual(projects[0].name, "api", "the display name is the last path component")
        XCTAssertEqual(projects[0].processCount, 2)
        XCTAssertEqual(projects[0].ports, [4000, 8080], "ports join by pid and sort ascending")
        XCTAssertEqual(projects[1].ports, [6379])
    }

    // MARK: History

    func testHistoryRankingsReadsTrendsForTheWindow() async throws {
        // `HistoryWindow.since` is computed from the real clock, so the recorded
        // points must sit inside the real last hour for the window to see them.
        let now = Date()
        let reading = try makeHistoryStore { store in
            store.recordExtended(
                system: Self.systemSample(at: now),
                apps: [Self.makeRollup(name: "Chrome", pid: 900, cpu: 60, memory: 100_000_000)],
                interval: 60
            )
        }
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            historyFactory: { reading },
            appRunning: { false },
            snapshotTimeout: 0.1
        )

        let trends = try await provider.historyRankings(window: .h1, resource: nil)

        XCTAssertEqual(trends.map(\.id), ["app:Chrome"])
        XCTAssertEqual(try XCTUnwrap(trends.first).averageCPU ?? 0, 60, accuracy: 0.001)
    }

    func testHistoryResourcesReturnsRecordedPoints() async throws {
        let now = Date()
        let reading = try makeHistoryStore { store in
            store.recordExtended(
                system: Self.systemSample(at: now),
                apps: [],
                interval: 60
            )
        }
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            historyFactory: { reading },
            appRunning: { false },
            now: { now }
        )

        let points = try await provider.historyResources(window: .h1, resource: .download)

        XCTAssertEqual(points.map(\.metric), ["download"])
        XCTAssertNil(points.first?.value, "no network was recorded, so no rate may be invented")
    }

    /// A history failure must reach the caller as an `MCPToolError` naming the
    /// subsystem. A bare Foundation error renders as "The operation couldn't be
    /// completed…" in the audit log.
    func testHistoryFailureIsWrappedAsMCPToolError() async throws {
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            historyFactory: { FailingHistoryReading(message: "database is locked") },
            appRunning: { false },
            snapshotTimeout: 0.1
        )

        do {
            _ = try await provider.historyRankings(window: .h1, resource: nil)
            XCTFail("A history failure must not answer with an empty ranking")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("history"), error.message)
            XCTAssertTrue(error.message.contains("database is locked"), error.message)
        }
        do {
            _ = try await provider.historyResources(window: .h1, resource: .gpu)
            XCTFail("A history failure must not answer with an empty point list")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("gpu"), error.message)
        }
    }

    // MARK: Alerts

    /// Stale history means "no alert", and an empty answer must still say which
    /// evaluation produced it.
    func testActiveAlertsWithStaleHistoryReturnsEmptyWithSource() async throws {
        let now = Self.sampleTime
        let clock = TestClock(now)
        let reading = try makeHistoryStore { store in
            // Two hours old: outside both the CPU and memory windows.
            let stale = now.addingTimeInterval(-7200)
            store.recordExtended(
                system: Self.systemSample(at: stale),
                apps: [Self.makeRollup(name: "Chrome", pid: 900, cpu: 99, memory: 4_000_000_000)],
                interval: 60
            )
        }
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            historyFactory: { reading },
            appRunning: { false },
            now: { clock.now }
        )

        let alerts = try await provider.activeAlerts()

        XCTAssertEqual(alerts.source, .historyApproximate)
        XCTAssertEqual(
            alerts.alerts, [],
            "history older than the alert windows cannot show a sustained problem"
        )
    }

    func testActiveAlertsFromHistoryApproximation() async throws {
        let now = Self.sampleTime
        let clock = TestClock(now)
        let reading = try makeHistoryStore { store in
            for offset in [-60.0, 0.0] {
                store.recordExtended(
                    system: Self.systemSample(at: now.addingTimeInterval(offset)),
                    apps: [Self.makeRollup(name: "Chrome", pid: 900, cpu: 60, memory: 100_000_000)],
                    interval: 60
                )
            }
        }
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            historyFactory: { reading },
            appRunning: { false },
            now: { clock.now }
        )

        let alerts = try await provider.activeAlerts()

        XCTAssertEqual(alerts.source, .historyApproximate)
        let sustained = alerts.alerts.filter { $0.kind == .sustainedCPU }
        XCTAssertEqual(sustained.count, 1)
        let alert = try XCTUnwrap(sustained.first)
        XCTAssertTrue(
            alert.id.hasPrefix("history:"),
            "an alert reconstructed from history must be identifiable as such: \(alert.id)"
        )
        XCTAssertEqual(alert.appName, "Chrome")
        XCTAssertTrue(
            alert.detail.contains("recorded"), alert.detail
        )
        XCTAssertTrue(
            alert.detail.contains(
                OnDemandProvider.spanDescription(AlertEngine.cpuWindow)
            ),
            "the window in the sentence must come from the constant that produced "
                + "the threshold: \(alert.detail)"
        )
    }

    /// Memory growth is measured between two real observations. A peak alone is
    /// not growth, so one recorded reading cannot produce this alert.
    func testActiveAlertsReportsMemoryGrowthFromRecordedEndpoints() async throws {
        let now = Self.sampleTime
        let clock = TestClock(now)
        let reading = try makeHistoryStore { store in
            store.recordExtended(
                system: Self.systemSample(at: now.addingTimeInterval(-1800)),
                apps: [Self.makeRollup(name: "Editor", pid: 901, cpu: 1, memory: 200_000_000)],
                interval: 60
            )
            store.recordExtended(
                system: Self.systemSample(at: now),
                apps: [Self.makeRollup(name: "Editor", pid: 901, cpu: 1, memory: 2_000_000_000)],
                interval: 60
            )
        }
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            historyFactory: { reading },
            appRunning: { false },
            now: { clock.now }
        )

        let alerts = try await provider.activeAlerts()

        let growth = alerts.alerts.filter { $0.kind == .memoryGrowth }
        XCTAssertEqual(growth.count, 1)
        let alert = try XCTUnwrap(growth.first)
        XCTAssertTrue(alert.id.hasPrefix("history:"))
        XCTAssertTrue(
            alert.detail.contains(OnDemandProvider.spanDescription(AlertEngine.memGrowthWindow)),
            alert.detail
        )
    }

    // MARK: Settings

    func testSettingsSnapshotMapsPreferencesAndMutationMode() async throws {
        let defaults = try makePreferencesDefaults()
        var prefs = AppPreferences()
        prefs.presentation.temperatureUnit = .fahrenheit
        prefs.presentation.networkUnit = .bits
        prefs.presentation.cpuScale = .perMac
        prefs.presentation.temperatureSource = .gpu
        prefs.presentation.compact = true
        prefs.retention = .days7
        prefs.alertsEnabled = false
        prefs.save(to: defaults)
        let directory = try makeTemporaryDirectory(prefix: name)
        let settings = MCPSettings(mode: .confirmEach)
        try settings.save(directory: directory)

        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            preferencesDefaults: defaults,
            appRunning: { false },
            settingsDirectory: directory
        )

        let snapshot = provider.settingsSnapshot()

        XCTAssertEqual(snapshot.temperatureUnit, "fahrenheit")
        XCTAssertEqual(snapshot.networkUnit, "bits")
        XCTAssertEqual(snapshot.cpuScale, "perMac")
        XCTAssertEqual(snapshot.temperatureSource, "gpu")
        XCTAssertTrue(snapshot.compactMenuBar)
        XCTAssertEqual(snapshot.retention, "days7")
        XCTAssertFalse(snapshot.alertsEnabled)
        XCTAssertEqual(snapshot.mutationMode, "confirmEach")
    }

    // MARK: Preferences

    func testSetPreferenceAppOpenDenies() throws {
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { true }
        )

        do {
            try provider.setPreference(key: "temperatureUnit", value: "fahrenheit")
            XCTFail("A running app holds preferences in memory and would clobber an external write")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error.message,
                "Portmaster is running; close it before changing preferences via MCP "
                    + "(live writes arrive with the MCP host)."
            )
        }
    }

    /// A read-modify-write of the app's blob must leave every sibling field alone.
    func testSetPreferenceWritesAllowlistedFieldOnly() throws {
        let defaults = try makePreferencesDefaults()
        var seeded = AppPreferences(menuBarMetric: .networkDown)
        seeded.presentation.networkUnit = .bits
        seeded.presentation.temperatureUnit = .celsius
        seeded.retention = .days3
        seeded.save(to: defaults)
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            preferencesDefaults: defaults,
            appRunning: { false }
        )

        try provider.setPreference(key: "temperatureUnit", value: "fahrenheit")

        let reloaded = AppPreferences.load(from: defaults)
        XCTAssertEqual(reloaded.presentation.temperatureUnit, .fahrenheit, "the requested field changed")
        XCTAssertEqual(
            reloaded.menuBarMetric, .networkDown,
            "a sibling field outside the allowlist must survive the write"
        )
        XCTAssertEqual(
            reloaded.presentation.networkUnit, .bits,
            "a sibling field inside the same sub-struct must survive the write"
        )
        XCTAssertEqual(reloaded.retention, .days3, "unrelated preferences survive the write")
    }

    func testSetPreferenceInvalidValueThrows() throws {
        let defaults = try makePreferencesDefaults()
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            preferencesDefaults: defaults,
            appRunning: { false }
        )

        for (key, value) in [("temperatureUnit", "kelvin"), ("compact", "yes"), ("cpuScale", "total")] {
            do {
                try provider.setPreference(key: key, value: value)
                XCTFail("\(key)=\(value) must be rejected rather than stored")
            } catch let error as MCPToolError {
                XCTAssertEqual(error.message, "Invalid value '\(value)' for '\(key)'.")
            }
        }
        XCTAssertEqual(
            AppPreferences.load(from: defaults).presentation.temperatureUnit, .celsius,
            "a rejected write must leave the blob untouched"
        )
    }

    func testSetPreferenceRejectsKeyOutsideTheAllowlist() throws {
        let defaults = try makePreferencesDefaults()
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            preferencesDefaults: defaults,
            appRunning: { false }
        )

        do {
            try provider.setPreference(key: "retention", value: "days30")
            XCTFail("Only allowlisted preferences may be changed")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("retention"), error.message)
            // The rejection quotes what *is* allowed, and the catalog lists
            // `mcpMode`, so leaving it out would send a client looking for a key
            // it was just told does not exist.
            for key in ["compact", "cpuScale", "mcpMode", "networkUnit", "temperatureSource", "temperatureUnit"] {
                XCTAssertTrue(error.message.contains(key), "\(key) missing from: \(error.message)")
            }
        }
    }

    /// One rule for every key: trimmed, then matched without regard to case.
    /// A client echoing a label back must not fail for a reason a user can see,
    /// and a value that is not on the list must still be refused.
    func testSetPreferenceValuesAreCaseInsensitiveAndTrimmed() throws {
        let defaults = try makePreferencesDefaults()
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            preferencesDefaults: defaults,
            appRunning: { false }
        )

        try provider.setPreference(key: "temperatureUnit", value: "  Fahrenheit ")
        try provider.setPreference(key: "networkUnit", value: "BITS")
        try provider.setPreference(key: "cpuScale", value: "PerMac")
        try provider.setPreference(key: "temperatureSource", value: "GPU")
        try provider.setPreference(key: "compact", value: " TRUE ")

        let reloaded = AppPreferences.load(from: defaults)
        XCTAssertEqual(reloaded.presentation.temperatureUnit, .fahrenheit)
        XCTAssertEqual(reloaded.presentation.networkUnit, .bits)
        XCTAssertEqual(reloaded.presentation.cpuScale, .perMac)
        XCTAssertEqual(reloaded.presentation.temperatureSource, .gpu)
        XCTAssertTrue(reloaded.presentation.compact)
    }

    /// `mcpMode` is the MCP server's own policy, not an app preference, so it does
    /// not go through the provider's preferences blob at all — the executor
    /// intercepts it before the provider is touched, and it stays writable with the
    /// app open because the app never holds it.
    ///
    /// The provider therefore has no `mcpMode` branch to reach, and reaching it
    /// directly gets the ordinary not-a-preference refusal. The write itself is
    /// pinned where it happens, in `ToolExecutorMutationTests`.
    func testSetPreferenceMcpModeIsNotTheProvidersToWrite() throws {
        let defaults = try makePreferencesDefaults()
        let provider = OnDemandProvider(
            snapshotSource: stubSnapshotSourceWithoutReading(),
            preferencesDefaults: defaults,
            appRunning: { false }
        )

        do {
            try provider.setPreference(key: "mcpMode", value: "allowSession")
            XCTFail("The provider must not write the MCP server's own mutation policy")
        } catch let error as MCPToolError {
            // One message, not two: the refusal is the executor's own sentence,
            // because the store quotes the executor's allowlist.
            XCTAssertEqual(
                error.message,
                "Preference 'mcpMode' cannot be changed via MCP. Allowed: "
                    + ToolExecutor.allowedPreferenceKeysDescription() + "."
            )
        }
        XCTAssertNil(
            defaults.data(forKey: AppPreferences.defaultsKey),
            "the MCP server's own mode must not be written into the app's preferences blob"
        )
    }

    // MARK: Stops

    func testQuitAppStopsStubbedPids() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let identity = StubIdentity(start: startedAt)
        let controller = RecordingProcessController(identity: identity)
        let snapshot = Self.makeSnapshot(
            cpuPercent: 10,
            processes: [
                Self.makeProcess(pid: 4242, name: "app", parent: 1, startedAt: startedAt),
                Self.makeProcess(pid: 4243, name: "helper", parent: 4242, startedAt: startedAt),
            ],
            rollups: [
                Self.makeRollup(name: "app", pids: [4242, 4243], startedAt: startedAt)
            ]
        )
        let source = StubSnapshotSource([snapshot])
        let provider = OnDemandProvider(
            snapshotSource: source,
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            stopController: controller,
            stopIdentity: { identity.state($0) },
            stopVerifyDelay: 0
        )

        let report = try await provider.quitApp(id: "app:app", force: false)

        XCTAssertEqual(
            report.results, ["4242": "stopped", "4243": "stopped"],
            "every process of the app is reported individually"
        )
        XCTAssertEqual(Set(controller.gracefullySignalled), [4242, 4243])
        XCTAssertEqual(controller.forceSignalled, [], "a graceful quit must not force-kill")

        _ = try await provider.quitApp(id: "app:app", force: false)
        XCTAssertEqual(
            source.callCount, 2,
            "a stop targets live pids, so it must not be served from the read cache"
        )
    }

    func testQuitAppUnknownIDIsAnHonestError() async throws {
        let identity = StubIdentity(start: Date())
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([Self.makeSnapshot(cpuPercent: 10)]),
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            stopController: RecordingProcessController(identity: identity),
            stopIdentity: { identity.state($0) },
            stopVerifyDelay: 0
        )

        do {
            _ = try await provider.quitApp(id: "app:gone", force: true)
            XCTFail("Quitting an app that is not in the snapshot must not signal anything")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, "App not found: app:gone")
        }
    }

    func testStopProjectStopsOnlyThatProjectsPids() async throws {
        let startedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let identity = StubIdentity(start: startedAt)
        let controller = RecordingProcessController(identity: identity)
        let snapshot = Self.makeSnapshot(
            cpuPercent: 10,
            processes: [
                Self.makeProcess(pid: 500, name: "node", parent: 1, project: "/src/api", startedAt: startedAt),
                Self.makeProcess(pid: 600, name: "redis", parent: 1, project: "/src/redis", startedAt: startedAt),
            ]
        )
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([snapshot]),
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            stopController: controller,
            stopIdentity: { identity.state($0) },
            stopVerifyDelay: 0
        )

        let report = try await provider.stopProject(id: "/src/api")

        XCTAssertEqual(report.results, ["500": "stopped"])
        XCTAssertEqual(controller.gracefullySignalled, [500], "another project's pid must be untouched")
    }

    func testStopProjectWithoutRunningProcessesIsAnHonestError() async throws {
        let identity = StubIdentity(start: Date())
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([Self.makeSnapshot(cpuPercent: 10)]),
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            stopController: RecordingProcessController(identity: identity),
            stopIdentity: { identity.state($0) },
            stopVerifyDelay: 0
        )

        do {
            _ = try await provider.stopProject(id: "/src/absent")
            XCTFail("A project with no live processes must say so rather than report an empty success")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, "No running processes found for project '/src/absent'.")
        }
    }

    // MARK: Container stops
    //
    // `stop_container` runs the docker CLI through an injected runner, so these
    // tests assert the argv and the reported outcome without a container, a
    // daemon, or a docker binary ever being involved.

    func testStopContainerReportsStoppedWhenDockerExitsZero() async throws {
        let runner = RecordingProcessRunner(
            outcome: CommandOutcome(exitCode: 0, standardError: "")
        )
        let provider = try makeContainerProvider(runner: runner)

        let report = try await provider.stopContainer(id: "abc123")

        XCTAssertEqual(report.results, ["abc123": "stopped"])
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(
            runner.invocations.first?.arguments, ["stop", "--", "abc123"],
            "one fixed command, the id after `--` so it cannot be read as a flag"
        )
        XCTAssertEqual(runner.invocations.first?.executable, "/test/docker")
    }

    /// A non-zero exit is reported with docker's own words, not a paraphrase of
    /// them: the caller needs the reason the daemon gave.
    func testStopContainerReportsFailedWithDockersOwnMessage() async throws {
        let runner = RecordingProcessRunner(
            outcome: CommandOutcome(
                exitCode: 1,
                standardError: "Error response from daemon: No such container: abc123\n"
            )
        )
        let provider = try makeContainerProvider(runner: runner)

        let report = try await provider.stopContainer(id: "abc123")

        XCTAssertEqual(
            report.results,
            ["abc123": "failed: Error response from daemon: No such container: abc123"]
        )
    }

    func testStopContainerThrowsWhenDockerIsUnavailable() async throws {
        for (availability, expected) in [
            (DockerAvailability.notInstalled, "Docker is not installed"),
            (DockerAvailability.daemonDown, "Docker daemon is not running"),
        ] {
            let runner = RecordingProcessRunner(
                outcome: CommandOutcome(exitCode: 0, standardError: "")
            )
            let provider = try makeContainerProvider(
                runner: runner, availability: availability
            )

            do {
                _ = try await provider.stopContainer(id: "abc123")
                XCTFail("Docker being unavailable must not be reported as a stop")
            } catch let error as MCPToolError {
                XCTAssertTrue(error.message.contains(expected), error.message)
            }
            XCTAssertEqual(
                runner.invocations, [],
                "nothing is run when docker cannot answer"
            )
        }
    }

    /// The safety property, stated as a test: an id full of shell metacharacters
    /// reaches docker as one argument and nothing is interpreted. Docker would
    /// never mint such an id, which is exactly why the provider must not be the
    /// thing that trusts the string.
    func testStopContainerPassesTheIDAsOneArgvElement() async throws {
        let hostile = "; rm -rf ~"
        let runner = RecordingProcessRunner(
            outcome: CommandOutcome(exitCode: 0, standardError: "")
        )
        let docker = DockerSample(
            availability: .running,
            containers: [Self.makeContainer(id: hostile, name: hostile)],
            at: Self.sampleTime
        )
        let provider = try makeContainerProvider(runner: runner, docker: docker)

        let report = try await provider.stopContainer(id: hostile)

        XCTAssertEqual(report.results, [hostile: "stopped"])
        let invocation = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(
            invocation.arguments, ["stop", "--", hostile],
            "the id must be one argument, never split on whitespace or punctuation"
        )
        XCTAssertEqual(
            invocation.arguments.filter { $0 == "--" }.count, 1,
            "exactly one `--`, so the id cannot be read as an option"
        )
        XCTAssertFalse(
            invocation.arguments.contains { $0 == "-rf" },
            "no argument may be derived from the id's contents"
        )
    }

    /// An id that is not in the snapshot is not stopped, and nothing is run on
    /// docker's behalf for it.
    func testStopContainerUnknownIDIsNotReportedAsAStop() async throws {
        let runner = RecordingProcessRunner(
            outcome: CommandOutcome(exitCode: 0, standardError: "")
        )
        let provider = try makeContainerProvider(runner: runner)

        do {
            _ = try await provider.stopContainer(id: "not-here")
            XCTFail("An unknown id must not be reported as stopped")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, "Container not found: not-here")
        }
        XCTAssertEqual(runner.invocations, [])
    }

    func testStopContainerWrapsARunnerFailure() async throws {
        let runner = RecordingProcessRunner(
            outcome: CommandOutcome(exitCode: 0, standardError: ""),
            failure: StubError(message: "no such file")
        )
        let provider = try makeContainerProvider(runner: runner)

        do {
            _ = try await provider.stopContainer(id: "abc123")
            XCTFail("A docker that could not be started must not be reported as a stop")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("docker"), error.message)
            XCTAssertTrue(error.message.contains("no such file"), error.message)
        }
    }

    /// The production runner, exercised with something that is definitely not
    /// docker. The seam tests prove what the provider *asks* for; this proves the
    /// thing that actually executes does what it claims — a non-zero exit arrives
    /// as an exit status rather than a thrown error, and a missing executable
    /// arrives as an error rather than silence.
    func testSystemProcessRunnerReportsExitStatusAndStartFailure() async throws {
        let runner = SystemProcessRunner()
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/false") else {
            throw XCTSkip("no /usr/bin/false on this machine")
        }

        let failed = try await runner.run(
            executable: "/usr/bin/false", arguments: ["stop", "--", "abc"], timeout: 5
        )
        XCTAssertEqual(failed.exitCode, 1, "a failing command is an outcome, not a thrown error")

        do {
            _ = try await runner.run(
                executable: "/nonexistent/docker", arguments: ["stop"], timeout: 5
            )
            XCTFail("A missing executable must not read as a successful stop")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("Could not start"), error.message)
        }
    }

    // MARK: Helpers

    /// A provider whose snapshot reports `docker` as the caller asks, with the
    /// subprocess runner injected so no test reaches a real docker.
    private func makeContainerProvider(
        runner: RecordingProcessRunner,
        availability: DockerAvailability = .running,
        docker: DockerSample? = nil
    ) throws -> OnDemandProvider {
        let sample = docker ?? DockerSample(
            availability: availability,
            containers: [Self.makeContainer(id: "abc123", name: "api")],
            at: Self.sampleTime
        )
        return OnDemandProvider(
            snapshotSource: StubSnapshotSource([
                Self.makeSnapshot(cpuPercent: 10, docker: sample)
            ]),
            preferencesDefaults: try makePreferencesDefaults(),
            appRunning: { false },
            processRunner: runner,
            dockerExecutable: { "/test/docker" }
        )
    }

    /// A seeded history store in a temporary directory, plus the reading seam
    /// over it. The directory is removed by the shared teardown.
    private func makeHistoryStore(_ seed: (HistoryStore) -> Void) throws -> any HistoryReading {
        let directory = try makeTemporaryDirectory(prefix: name)
        let store = try HistoryStore(storeURL: directory.appendingPathComponent("history.sqlite"))
        seed(store)
        return StoreHistoryReading(store: store)
    }

    /// A `UserDefaults` suite of this test's own, removed afterwards so no run
    /// can see another run's writes or touch the real app domain.
    private func makePreferencesDefaults() throws -> UserDefaults {
        let suite = "dev.portmaster.mcp.tests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: Fixtures

    static let sampleTime = Date(timeIntervalSince1970: 1_700_000_000)

    static func systemSample(
        at: Date, cpuPercent: Double = 12, thermal: ThermalSample? = nil
    ) -> SystemSample {
        SystemSample(
            at: at,
            cpu: SystemCPU(
                totalPercent: cpuPercent, userPercent: cpuPercent * 0.7,
                systemPercent: cpuPercent * 0.3,
                idlePercent: 100 - cpuPercent, corePercents: [8, 4], coreCount: 2
            ),
            memory: SystemMemory(
                totalBytes: 16_000_000_000, usedBytes: 8_000_000_000,
                pressureLevel: .normal, pressureRatio: 0.5,
                swapBytes: nil, freeBytes: 8_000_000_000,
                appBytes: nil, wiredBytes: nil, compressedBytes: nil
            ),
            thermal: thermal
        )
    }

    static func makeSnapshot(
        cpuPercent: Double,
        processes: [ProcessRow] = [],
        ports: [ListeningPort] = [],
        rollups: [AppRollup]? = nil,
        docker: DockerSample? = nil,
        thermal: ThermalSample? = nil
    ) -> ObservationSnapshot {
        ObservationSnapshot(
            at: sampleTime,
            system: systemSample(at: sampleTime, cpuPercent: cpuPercent, thermal: thermal),
            processes: processes,
            ports: ports,
            services: [],
            rollups: rollups ?? AppRollupBuilder.build(from: processes),
            docker: docker
        )
    }

    static func makeProcess(
        pid: Int32,
        name: String,
        parent: Int32? = 1,
        cpu: Double = 10,
        memory: UInt64 = 1_000_000,
        project: String? = nil,
        startedAt: Date? = nil
    ) -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, parentPid: parent,
            cpuPercent: cpu, memoryBytes: memory,
            startedAt: startedAt, projectID: project
        )
    }

    /// One rollup whose totals are exactly the given processes' values.
    static func makeRollup(
        name: String,
        pids: [Int32],
        startedAt: Date? = nil
    ) -> AppRollup {
        var rollup = AppRollup(id: "app:\(name)", displayName: name, isAppBundle: true)
        rollup.processes = pids.map {
            makeProcess(pid: $0, name: name, startedAt: startedAt)
        }
        return rollup
    }

    static func makeRollup(name: String, pid: Int32, cpu: Double, memory: UInt64) -> AppRollup {
        var rollup = AppRollup(id: "app:\(name)", displayName: name, isAppBundle: true)
        rollup.processes = [makeProcess(pid: pid, name: name, cpu: cpu, memory: memory)]
        return rollup
    }

    static func makeContainer(id: String, name: String) -> DockerContainer {
        DockerContainer(
            id: id, name: name, image: "ghcr.io/portmaster/\(name):1.2.3",
            statusText: "Up 8 minutes", ports: [8080],
            cpuPercent: 3, memoryBytes: 64_000_000
        )
    }
}

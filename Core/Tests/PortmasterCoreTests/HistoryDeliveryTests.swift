import XCTest
import Foundation
import Darwin
@testable import PortmasterCore

final class HistoryDeliveryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private func row(_ pid: pid_t, parent: pid_t? = nil, project: String? = nil, cpu: Double? = 100, start: Date? = Date(timeIntervalSince1970: 100)) -> ProcessRow {
        ProcessRow(pid: pid, name: "worker", parentPid: parent, cpuPercent: cpu, memoryBytes: 100_000_000, startedAt: start, projectID: project)
    }
    private func app(id: String = "/Applications/Example.app", pids: [pid_t] = [700], cpu: Double? = 100) -> AppRollup {
        var result = AppRollup(id: id, displayName: "Example", isAppBundle: true)
        result.processes = pids.map { row($0, cpu: cpu) }; return result
    }
    private func system(at: Date, network: NetworkSample? = nil) -> SystemSample {
        SystemSample(at: at, cpu: .unknown, memory: .unknown, network: network)
    }
    func testMarkerProbeDoesNotOpenNonDirectoryFIFO() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        XCTAssertEqual(mkfifo(path, 0o600), 0)
        defer { unlink(path) }
        XCTAssertFalse(ProjectAttributor.containsMarker(at: path, markers: ["package.json", ".git"]))
    }
    func testMarkerProbeFindsDotDirectoryAndIgnoresUnrelatedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(ProjectAttributor.containsMarker(at: dir.path, markers: [".git"]))
        XCTAssertFalse(ProjectAttributor.containsMarker(at: dir.path, markers: ["Cargo.toml"]))
    }
    func testMachTickConversionHandlesAppleSiliconIntelAndOverflow() {
        XCTAssertEqual(LibprocProcessCollector.machTicksToNanos(user: 24_000_000, system: 0, numer: 125, denom: 3), 1_000_000_000)
        XCTAssertEqual(LibprocProcessCollector.machTicksToNanos(user: 800_000_000, system: 200_000_000, numer: 1, denom: 1), 1_000_000_000)
        XCTAssertEqual(LibprocProcessCollector.machTicksToNanos(user: .max, system: .max, numer: 125, denom: 3), .max)
        XCTAssertNil(LibprocProcessCollector.machTicksToNanos(user: 1, system: 0, numer: 125, denom: 0))
    }
    func testCanonicalCPUHandlesMultipleCoresAndNormalizesOnlyOnce() {
        let percent = SamplingEngine.coreCPUPercent(tickDeltaNanos: 2_000_000_000, intervalSeconds: 1)
        XCTAssertEqual(percent, 200)
        XCTAssertEqual(DisplayUnits.processCPU(percent, scale: .perCore, cores: 10), 200)
        XCTAssertEqual(DisplayUnits.processCPU(percent, scale: .perMac, cores: 10), 20)
    }
    func testNewReusedAndResetCPUReadingOnlySetsBaseline() {
        XCTAssertNil(SamplingEngine.processCPUPercent(currentNanos: 100, previousNanos: nil, currentStart: epoch, previousStart: epoch, intervalSeconds: 1))
        XCTAssertNil(SamplingEngine.processCPUPercent(currentNanos: 100, previousNanos: 50, currentStart: epoch, previousStart: epoch.addingTimeInterval(-1), intervalSeconds: 1))
        XCTAssertNil(SamplingEngine.processCPUPercent(currentNanos: 40, previousNanos: 50, currentStart: epoch, previousStart: epoch, intervalSeconds: 1))
        XCTAssertEqual(SamplingEngine.processCPUPercent(currentNanos: 1_000_000_050, previousNanos: 50, currentStart: epoch, previousStart: epoch, intervalSeconds: 1), 100)
    }
    func testLiveBusyWorkerCPUCounterUsesRealNanoseconds() async throws {
        let worker = Process(); worker.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        worker.standardOutput = FileHandle.nullDevice; worker.standardError = FileHandle.nullDevice
        try worker.run(); defer { if worker.isRunning { worker.terminate() }; worker.waitUntilExit() }
        let collector = LibprocProcessCollector()
        let before = try XCTUnwrap(collector.snapshot())
        let a = try XCTUnwrap(before.records.first { $0.pid == worker.processIdentifier })
        try await Task.sleep(nanoseconds: 800_000_000)
        let after = try XCTUnwrap(collector.snapshot())
        let b = try XCTUnwrap(after.records.first { $0.pid == worker.processIdentifier })
        let cpu = SamplingEngine.coreCPUPercent(tickDeltaNanos: Double(b.cpuTicks - a.cpuTicks), intervalSeconds: after.at.timeIntervalSince(before.at))
        XCTAssertGreaterThan(cpu, 25); XCTAssertLessThan(cpu, 150)
    }
    func testViewingRangesDoNotChangeRetentionOptions() {
        XCTAssertEqual(HistoryRange.hour1.seconds, 3600)
        XCTAssertEqual(HistoryRange.hours12.seconds, 43200)
        XCTAssertEqual(HistoryRetention.allCases.count, 4)
    }
    func testAppIdentitySurvivesPIDChangesAndCombinesHelpers() {
        let a = AppHistoryPoint(at: epoch, app: app(pids: [700, 701]), interval: 3)
        let b = AppHistoryPoint(at: epoch.addingTimeInterval(30), app: app(pids: [800]), interval: 30)
        let trends = AppHistoryTrend.aggregate([a, b], since: epoch.addingTimeInterval(-60))
        XCTAssertEqual(trends.count, 1); XCTAssertEqual(trends[0].cpuSeconds, 36)
        XCTAssertEqual(trends[0].peakMemory, 200_000_000)
        XCTAssertEqual(trends[0].averageCPU!, 36 / 33 * 100, accuracy: 0.001)
    }
    func testCPUTimeWeightsCadenceRatherThanCountingSamples() {
        let a = AppHistoryPoint(at: epoch, app: app(id: "a", cpu: 100), interval: 2)
        let b = AppHistoryPoint(at: epoch, app: app(id: "b", cpu: 50), interval: 30)
        let trends = AppHistoryTrend.aggregate([a, b], since: epoch.addingTimeInterval(-60))
        XCTAssertEqual(trends.map(\.id), ["b", "a"])
        XCTAssertEqual(trends[0].cpuSeconds, 15)
    }
    func testWindowBoundaryClipsFirstInterval() {
        let p = AppHistoryPoint(at: epoch, app: app(), interval: 30)
        let trend = AppHistoryTrend.aggregate([p], since: epoch.addingTimeInterval(-5))[0]
        XCTAssertEqual(trend.cpuSeconds, 5); XCTAssertEqual(trend.observedSeconds, 5)
        XCTAssertTrue(AppHistoryTrend.aggregate([p], since: epoch.addingTimeInterval(1)).isEmpty)
    }
    func testUnknownCPUAndSleepGapsContributeNoCPUTime() {
        for interval in [0.0, -1, 121, Double.infinity] {
            XCTAssertEqual(AppHistoryPoint(at: epoch, app: app(), interval: interval).cpuSeconds, 0)
        }
        let p = AppHistoryPoint(at: epoch, app: app(cpu: nil), interval: 3)
        XCTAssertEqual(p.cpuSeconds, 0); XCTAssertEqual(p.observedSeconds, 0)
    }
    func testPartialAppNetworkIsUnknown() {
        var value = app(pids: [700, 701]); value.processes[0].netInBytesPerSec = 100
        XCTAssertNil(AppHistoryPoint(at: epoch, app: value, interval: 3).download)
        value.processes[1].netInBytesPerSec = 0
        XCTAssertEqual(AppHistoryPoint(at: epoch, app: value, interval: 3).download, 100)
    }
    func testUnavailableResourceIsNilAndNonfiniteIsRejected() {
        XCTAssertNil(HistoryResource.gpu.reading(in: system(at: epoch)))
        XCTAssertNil(HistoryResource.download.reading(in: system(at: epoch, network: .init(downBytesPerSec: .nan, upBytesPerSec: 0))))
        XCTAssertEqual(HistoryResource.upload.reading(in: system(at: epoch, network: .init(downBytesPerSec: 1, upBytesPerSec: 0))), 0)
    }
    func testMissingReadingsAndLongPausesBreakPlotLines() {
        let input: [HistoryPlot.Reading] = [
            .init(at: epoch, value: 10), .init(at: epoch.addingTimeInterval(3), value: nil),
            .init(at: epoch.addingTimeInterval(6), value: 20), .init(at: epoch.addingTimeInterval(900), value: 30),
            .init(at: epoch.addingTimeInterval(903), value: 40)
        ]
        let points = HistoryPlot.downsample(input)
        XCTAssertEqual(points.map(\.value), [10, 20, 40])
        XCTAssertEqual(Set(points.map(\.segment)).count, 3)
    }
    func testPlotsStayBoundedAcrossLongWindows() {
        let input = (0..<20_000).map { HistoryPlot.Reading(at: epoch.addingTimeInterval(Double($0) * 3), value: Double($0 % 100)) }
        XCTAssertLessThanOrEqual(HistoryPlot.downsample(input).count, 200)
        XCTAssertTrue(HistoryPlot.downsample(input, maxPoints: 0).isEmpty)
    }
    func testPersistencePruningAndClearIncludeExtendedTables() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite")
        do {
            let store = try HistoryStore(storeURL: url)
            store.recordExtended(system: system(at: epoch), apps: [app()], interval: 3)
            store.recordExtended(system: system(at: epoch.addingTimeInterval(30)), apps: [app()], interval: 30)
            XCTAssertEqual(store.extendedRowCounts().apps, 2)
            XCTAssertEqual(store.resourceSamples(.gpu, since: epoch).count, 2)
            XCTAssertNil(store.resourceSamples(.gpu, since: epoch)[0].value)
        }
        let reopened = try HistoryStore(storeURL: url)
        XCTAssertEqual(reopened.appTrends(since: epoch.addingTimeInterval(-60))[0].cpuSeconds, 33)
        reopened.prune(olderThan: epoch.addingTimeInterval(1))
        XCTAssertEqual(reopened.extendedRowCounts().apps, 1)
        XCTAssertEqual(reopened.extendedRowCounts().resources, HistoryResource.allCases.count)
        try reopened.clearAll()
        XCTAssertEqual(reopened.extendedRowCounts().apps, 0); XCTAssertEqual(reopened.extendedRowCounts().resources, 0)
    }
    func testActualLegacyStoreMigrationWhenFixtureProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["PORTMASTER_LEGACY_HISTORY"] else { throw XCTSkip("Set PORTMASTER_LEGACY_HISTORY to an isolated copy of a pre-upgrade database.") }
        let store = try HistoryStore(storeURL: URL(fileURLWithPath: path))
        let counts = store.rowCounts()
        XCTAssertEqual(counts.cpu, 1278); XCTAssertEqual(counts.mem, 1278)
        XCTAssertEqual(counts.process, 48145); XCTAssertEqual(counts.port, 364)
        XCTAssertEqual(store.extendedRowCounts().apps, 0)
        XCTAssertFalse(store.processTrends(since: .distantPast).isEmpty)
    }
    func testProjectPlanIncludesNonlistenersButExcludesOtherProjectsAndSelf() {
        let rows = [row(700, project: "a"), row(701, parent: 700, project: "a"), row(702, parent: 700, project: "b"), row(703, project: "a"), row(1, project: "a")]
        XCTAssertEqual(ConfirmedStopPlan.project("a", rows: rows, ownPID: 703).map(\.pid), [701, 700])
    }
    func testProcessPlanCapturesDescendantsWithoutCyclesOrDuplicates() {
        let rows = [row(700, parent: 702), row(701, parent: 700), row(702, parent: 701), row(703)]
        let plan = ConfirmedStopPlan.process(700, rows: rows, ownPID: 900)
        XCTAssertEqual(Set(plan.map(\.pid)), [700, 701, 702]); XCTAssertEqual(plan.count, 3)
    }
    func testReusedAndUnknownIdentitiesAreNeverSignaled() async {
        let mock = StopMock()
        mock.states[700] = .running(startedAt: epoch)
        mock.states[701] = .unavailable
        let coordinator = StopCoordinator(controller: mock, verifyDelay: 0, identityLookup: { mock.state($0) })
        let results = await coordinator.stopConfirmed([.init(pid: 700, name: "old", startedAt: epoch.addingTimeInterval(-1)), .init(pid: 701, name: "unknown", startedAt: epoch)], force: false)
        XCTAssertTrue(mock.signals.isEmpty); XCTAssertEqual(results.count, 2)
        for result in results.values { if case .failed = result.status {} else { XCTFail("Expected a refusal") } }
    }
    func testConfirmedStopDeduplicatesAndVerifiesWholeSet() async {
        let mock = StopMock(); mock.states[700] = .running(startedAt: epoch); mock.states[701] = .running(startedAt: epoch)
        let coordinator = StopCoordinator(controller: mock, verifyDelay: 0, identityLookup: { mock.state($0) })
        let members = [700, 701, 700].map { ConfirmedProcess(pid: pid_t($0), name: "worker", startedAt: epoch) }
        let results = await coordinator.stopConfirmed(members, force: false)
        XCTAssertEqual(mock.signals, [700, 701]); XCTAssertEqual(results.count, 2)
        for result in results.values { if case .stopped = result.status {} else { XCTFail("Expected verified exit") } }
    }
    func testSignalFailureStillRunningAndForceRecoveryAreReported() async {
        let mock = StopMock(); mock.states[700] = .running(startedAt: epoch); mock.keepAlive = true
        let coordinator = StopCoordinator(controller: mock, verifyDelay: 0, identityLookup: { mock.state($0) })
        let members = [ConfirmedProcess(pid: 700, name: "worker", startedAt: epoch)]
        let graceful = await coordinator.stopConfirmed(members, force: false)
        if case .stillRunning? = graceful[700]?.status {} else { XCTFail("Expected still running") }
        mock.fail = true
        let failure = await coordinator.stopConfirmed(members, force: true)
        if case .failed? = failure[700]?.status {} else { XCTFail("Expected signal failure") }
        mock.fail = false; mock.keepAlive = false
        let force = await coordinator.stopConfirmed(members, force: true)
        if case .stopped? = force[700]?.status {} else { XCTFail("Expected force exit") }
    }
    func testOnboardingRunsForNewInstallsButPreservesLegacyPreferences() throws {
        XCTAssertFalse(AppPreferences().hasCompletedOnboarding)
        let old = try JSONDecoder().decode(AppPreferences.self, from: Data("{\"showInDock\":true}".utf8))
        XCTAssertTrue(old.hasCompletedOnboarding); XCTAssertTrue(old.showInDock)
        var new = AppPreferences(); new.hasCompletedOnboarding = true
        XCTAssertTrue(try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(new)).hasCompletedOnboarding)
    }
    func testUpdaterRejectsMissingInsecureOrMalformedConfiguration() {
        let key = Data(repeating: 3, count: 32).base64EncodedString()
        XCTAssertTrue(UpdateConfiguration.isValid(feed: "https://updates.example.org/appcast.xml", publicKey: key))
        for feed in ["", "http://updates.example.org/feed", "file:///feed.xml", "https://user:pass@example.org/feed", "$(PORTMASTER_UPDATE_FEED_URL)"] {
            XCTAssertFalse(UpdateConfiguration.isValid(feed: feed, publicKey: key))
        }
        XCTAssertFalse(UpdateConfiguration.isValid(feed: "https://example.org/feed", publicKey: "junk"))
    }
}

private final class StopMock: ProcessControlling, @unchecked Sendable {
    let isSupported = true
    let unsupportedReason: String? = nil
    var states: [pid_t: StopCoordinator.IdentityState] = [:]
    var signals: [pid_t] = []
    var keepAlive = false
    var fail = false
    func state(_ pid: pid_t) -> StopCoordinator.IdentityState { states[pid] ?? .gone }
    func gracefulStop(pid: pid_t) throws {
        if fail { throw StopError.permissionDenied(pid: pid) }
        signals.append(pid); if !keepAlive { states[pid] = .gone }
    }
    func forceQuit(pid: pid_t) throws { try gracefulStop(pid: pid) }
}

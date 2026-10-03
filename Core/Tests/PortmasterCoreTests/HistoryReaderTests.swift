import XCTest
import Foundation
@testable import PortmasterCore

final class HistoryReaderTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor private func fixture() throws -> (HistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try HistoryStore(storeURL: directory.appendingPathComponent("history.sqlite")), directory)
    }
    private func app(cpu: Double = 100) -> AppRollup {
        var app = AppRollup(id: "app", displayName: "Example", isAppBundle: true)
        app.processes = [ProcessRow(pid: 700, name: "worker", parentPid: nil, cpuPercent: cpu, memoryBytes: 100_000_000)]
        return app
    }
    @MainActor func testReaderMatchesWeightedRankingsAndSelectedAppChart() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        store.recordExtended(system: .init(at: at, cpu: .unknown, memory: .unknown), apps: [app()], interval: 30)
        let reader = store.makeReader()
        let since = at.addingTimeInterval(-5)
        let trends = try await reader.appTrends(since: since)
        XCTAssertEqual(trends.count, 1); XCTAssertEqual(trends[0].cpuSeconds, 5)
        XCTAssertEqual(trends[0].peakMemory, 100_000_000)
        let chart = try await reader.chart(since: since, metric: "cpu", appID: "app")
        XCTAssertEqual(chart.map(\.value), [100])
        let missing = try await reader.chart(since: since, metric: "cpu", appID: "missing")
        XCTAssertTrue(missing.isEmpty)
    }
    @MainActor func testFreshReadSeesSavedWritesAndClear() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = store.makeReader()
        let initial = try await reader.chart(since: .distantPast, metric: "cpu", appID: "")
        XCTAssertTrue(initial.isEmpty)
        store.recordSystem(cpu: .unknown, memory: .unknown, at: at)
        let saved = try await reader.chart(since: .distantPast, metric: "cpu", appID: "")
        XCTAssertEqual(saved.count, 1)
        try store.clearAll()
        let cleared = try await reader.chart(since: .distantPast, metric: "cpu", appID: "")
        XCTAssertTrue(cleared.isEmpty)
    }
    @MainActor func testUnavailableResourceDoesNotProduceZeroOrJoinGaps() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        for (offset, rate) in [(0.0, 10.0), (3, nil), (6, 20)] as [(Double, Double?)] {
            store.recordExtended(system: .init(at: at.addingTimeInterval(offset), cpu: .unknown, memory: .unknown,
                network: rate.map { .init(downBytesPerSec: $0, upBytesPerSec: 0) }), apps: [], interval: 3)
        }
        let chart = try await store.makeReader().chart(since: at, metric: "download", appID: "")
        XCTAssertEqual(chart.map(\.value), [10, 20]); XCTAssertNotEqual(chart[0].segment, chart[1].segment)
    }
    @MainActor func testLegacyQueryAggregatesSeparatelyAndHonorsWindow() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        store.recordProcessPoints(app().processes, at: at, servicePids: [])
        let reader = store.makeReader()
        let legacy = try await reader.legacyTrends(since: at)
        XCTAssertEqual(legacy.count, 1); XCTAssertEqual(legacy[0].key, "worker")
        XCTAssertEqual(legacy[0].peakMemory, 100_000_000)
        let outside = try await reader.legacyTrends(since: at.addingTimeInterval(1))
        XCTAssertTrue(outside.isEmpty)
        let appRankings = try await reader.appTrends(since: at)
        XCTAssertTrue(appRankings.isEmpty)
    }
    @MainActor func testCancelledQueryIsRejectedAndNextQueryStillWorks() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = store.makeReader()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await reader.chart(since: .distantPast, metric: "cpu", appID: "")
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled queries must not return stale results") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let next = try await reader.appTrends(since: at)
        XCTAssertTrue(next.isEmpty)
    }

    @MainActor func testDailyStatsExcludeFutureReadingsAndNeedTwoSamples() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let reader = store.makeReader()
        store.recordSystem(cpu: .unknown, memory: .unknown, at: at)
        store.recordSystem(cpu: .unknown, memory: .unknown, at: at.addingTimeInterval(60))
        let first = try await reader.dayStats(metric: "cpu", now: at.addingTimeInterval(30))
        XCTAssertEqual(first.sampleCount, 1); XCTAssertNil(first.averageTodayPercent)
        let next = try await reader.dayStats(metric: "cpu", now: at.addingTimeInterval(90))
        XCTAssertEqual(next.sampleCount, 2); XCTAssertEqual(next.averageTodayPercent, 0)
        let memory = try await reader.dayStats(metric: "memory", now: at.addingTimeInterval(90))
        XCTAssertEqual(memory.sampleCount, 2); XCTAssertEqual(memory.averageTodayPercent, 0)
    }

    /// A span is a difference between two observations, so an app seen once has
    /// none: its peak is not growth, and emitting a zero-growth span would put a
    /// made-up measurement behind an API that promises a real one.
    @MainActor func testMemorySpansNeedTwoReadingsAndCarryTheRealDelta() async throws {
        let (store, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        func app(id: String, name: String, pid: Int32, memory: UInt64) -> AppRollup {
            var rollup = AppRollup(id: id, displayName: name, isAppBundle: true)
            rollup.processes = [ProcessRow(pid: pid, name: name, parentPid: nil, cpuPercent: 1, memoryBytes: memory)]
            return rollup
        }
        let reader = store.makeReader()

        store.recordExtended(
            system: .init(at: at, cpu: .unknown, memory: .unknown),
            apps: [app(id: "once", name: "Once", pid: 710, memory: 200_000_000)], interval: 30
        )
        let single = try await reader.appMemorySpans(since: at.addingTimeInterval(-5))
        XCTAssertEqual(
            single.map(\.appID), [],
            "one recorded reading is a peak, not a growth measurement"
        )

        for (offset, memory) in [(30.0, UInt64(200_000_000)), (60.0, UInt64(1_500_000_000))] {
            store.recordExtended(
                system: .init(at: at.addingTimeInterval(offset), cpu: .unknown, memory: .unknown),
                apps: [app(id: "twice", name: "Twice", pid: 720, memory: memory)], interval: 30
            )
        }
        let spans = try await reader.appMemorySpans(since: at.addingTimeInterval(-5))
        XCTAssertEqual(spans.map(\.appID), ["twice"], "the single-reading app still has no span")
        let span = try XCTUnwrap(spans.first)
        XCTAssertEqual(span.displayName, "Twice")
        XCTAssertEqual(span.firstBytes, 200_000_000)
        XCTAssertEqual(span.lastBytes, 1_500_000_000)
        XCTAssertEqual(span.growthBytes, 1_300_000_000)
        XCTAssertEqual(span.firstAt, at.addingTimeInterval(30))
        XCTAssertEqual(span.lastAt, at.addingTimeInterval(60))

        // A release is not growth.
        store.recordExtended(
            system: .init(at: at.addingTimeInterval(90), cpu: .unknown, memory: .unknown),
            apps: [app(id: "shrink", name: "Shrink", pid: 730, memory: 900_000_000)], interval: 30
        )
        for (offset, memory) in [(120.0, UInt64(2_000_000_000)), (150.0, UInt64(500_000_000))] {
            store.recordExtended(
                system: .init(at: at.addingTimeInterval(offset), cpu: .unknown, memory: .unknown),
                apps: [app(id: "shrink", name: "Shrink", pid: 730, memory: memory)], interval: 30
            )
        }
        let shrinking = try await reader.appMemorySpans(since: at.addingTimeInterval(-5))
        XCTAssertEqual(shrinking.first { $0.appID == "shrink" }?.growthBytes, 0)

        // Outside the window there is nothing to compare.
        let outside = try await reader.appMemorySpans(since: at.addingTimeInterval(200))
        XCTAssertTrue(outside.isEmpty)
    }
}

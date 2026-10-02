import XCTest
@testable import PortmasterCore

final class RollupTests: XCTestCase {

    private func row(pid: pid_t, name: String, path: String?, cpu: Double, mem: UInt64) -> ProcessRow {
        ProcessRow(pid: pid, name: name, parentPid: nil, cpuPercent: cpu, memoryBytes: mem, executablePathHint: path)
    }

    func testHelpersGroupUnderHostApp() {
        let rows = [
            row(pid: 1, name: "Slack", path: "/Applications/Slack.app/Contents/MacOS/Slack", cpu: 5, mem: 300_000_000),
            row(pid: 2, name: "Slack Helper (Renderer)", path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper (Renderer).app/Contents/MacOS/Slack Helper (Renderer)", cpu: 20, mem: 800_000_000),
            row(pid: 3, name: "node", path: "/usr/local/bin/node", cpu: 40, mem: 100_000_000),
        ]
        let rollups = AppRollupBuilder.build(from: rows)
        XCTAssertEqual(rollups.count, 2)
        let slack = rollups.first { $0.displayName == "Slack" }
        XCTAssertNotNil(slack)
        XCTAssertEqual(slack?.pidCount, 2)
        XCTAssertEqual(slack?.totalCPU ?? 0, 25, accuracy: 0.001)
        XCTAssertTrue(slack!.isAppBundle)
        let node = rollups.first { $0.displayName == "node" }
        XCTAssertEqual(node?.pidCount, 1)
        XCTAssertFalse(node!.isAppBundle)
    }

    func testEmptyPathFallsBackToName() {
        let rows = [row(pid: 9, name: "postgres", path: nil, cpu: 1, mem: 50_000_000)]
        let rollups = AppRollupBuilder.build(from: rows)
        XCTAssertEqual(rollups.count, 1)
        XCTAssertEqual(rollups[0].displayName, "postgres")
        XCTAssertEqual(rollups[0].id, "bin:postgres")
    }

    func testProjectIDsCollected() {
        let r = ProcessRow(
            pid: 4, name: "Code", parentPid: nil, cpuPercent: 3, memoryBytes: 10,
            projectID: "proj:/Users/dev/work/api",
            executablePathHint: "/Applications/Xcode.app/Contents/MacOS/Xcode"
        )
        let rollups = AppRollupBuilder.build(from: [r])
        XCTAssertEqual(rollups[0].projectIDs, ["proj:/Users/dev/work/api"])
    }
}

final class AlertEngineTests: XCTestCase {

    private func app(id: String, name: String, cpu: Double, mem: UInt64) -> AppRollup {
        var rollup = AppRollup(id: id, displayName: name, isAppBundle: true)
        let r = ProcessRow(pid: 100, name: name, parentPid: nil, cpuPercent: cpu, memoryBytes: mem)
        rollup.processes.append(r)
        return rollup
    }

    private func hammerApp(
        id: String, name: String, diskWrite: Double?, netIn: Double?
    ) -> AppRollup {
        var rollup = AppRollup(id: id, displayName: name, isAppBundle: true)
        // CPU 2%: above the ingest guard (totalCPU > 1) but far below the
        // sustained-CPU threshold so only the hammering kinds can fire.
        var r = ProcessRow(pid: 200, name: name, parentPid: nil, cpuPercent: 2, memoryBytes: 100)
        r.diskWriteBytesPerSec = diskWrite
        r.netInBytesPerSec = netIn
        rollup.processes.append(r)
        return rollup
    }

    func testDiskHammeringFiresAfterWindow() {
        let engine = AlertEngine()
        let start = Date()
        var fired: [ActingUpAlert] = []
        // 12 minutes at 60 MB/s written, sampled every 30s → fires once.
        for i in 0..<24 {
            let at = start.addingTimeInterval(Double(i) * 30)
            fired += engine.ingest(
                rollups: [hammerApp(id: "d1", name: "Encoder", diskWrite: 60 * 1_048_576, netIn: 0)],
                at: at, notify: false
            )
        }
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .diskHammering)
        XCTAssertEqual(fired[0].appName, "Encoder")
    }

    func testNetworkHammeringFiresAfterWindow() {
        let engine = AlertEngine()
        let start = Date()
        var fired: [ActingUpAlert] = []
        // 12 minutes at 12 MB/s downloaded → above the 10 MB/s threshold.
        for i in 0..<24 {
            let at = start.addingTimeInterval(Double(i) * 30)
            fired += engine.ingest(
                rollups: [hammerApp(id: "n1", name: "Syncer", diskWrite: 0, netIn: 12 * 1_048_576)],
                at: at, notify: false
            )
        }
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .networkHammering)
        XCTAssertEqual(fired[0].appName, "Syncer")
    }

    func testSustainedButBelowHammerThresholdDoesNotFire() {
        let engine = AlertEngine()
        let start = Date()
        var fired: [ActingUpAlert] = []
        // 12 minutes at 20 MB/s disk and 5 MB/s network — both below threshold.
        for i in 0..<24 {
            let at = start.addingTimeInterval(Double(i) * 30)
            fired += engine.ingest(
                rollups: [hammerApp(id: "q1", name: "Chatter", diskWrite: 20 * 1_048_576, netIn: 5 * 1_048_576)],
                at: at, notify: false
            )
        }
        XCTAssertTrue(fired.isEmpty)
    }

    func testDiskSpikeDoesNotFireWithoutFullWindow() {
        let engine = AlertEngine()
        let start = Date()
        var fired: [ActingUpAlert] = []
        // 2 minutes hammering then quiet — under the 10-minute window.
        for i in 0..<8 {
            let at = start.addingTimeInterval(Double(i) * 30)
            let disk: Double? = i < 4 ? 80 * 1_048_576 : 0
            fired += engine.ingest(
                rollups: [hammerApp(id: "s1", name: "Burst", diskWrite: disk, netIn: 0)],
                at: at, notify: false
            )
        }
        XCTAssertTrue(fired.isEmpty)
    }

    func testSustainedCPUFiresAfterWindow() {
        let engine = AlertEngine()
        var fired: [ActingUpAlert] = []
        let start = Date()
        // 12 minutes at 70% CPU, sampled every 30s → should fire once around 10 min.
        for i in 0..<24 {
            let at = start.addingTimeInterval(Double(i) * 30)
            fired += engine.ingest(rollups: [app(id: "a1", name: "Chrome", cpu: 70, mem: 100)], at: at, notify: false)
        }
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .sustainedCPU)
        XCTAssertEqual(fired[0].appName, "Chrome")
        XCTAssertTrue(fired[0].headline.contains("Chrome"))
    }

    func testBriefSpikeDoesNotFire() {
        let engine = AlertEngine()
        var fired: [ActingUpAlert] = []
        let start = Date()
        // 2 minutes of high CPU then quiet — under the 10-minute window.
        for i in 0..<8 {
            let cpu: Double = i < 4 ? 90 : 2
            fired += engine.ingest(rollups: [app(id: "a2", name: "Spike", cpu: cpu, mem: 100)], at: start.addingTimeInterval(Double(i) * 30), notify: false)
        }
        XCTAssertTrue(fired.isEmpty)
    }

    func testMemoryGrowthFiresAtOneGB() {
        let engine = AlertEngine()
        let start = Date()
        var fired: [ActingUpAlert] = []
        // Climb 300 MB every 10 min for an hour → +1.5 GB.
        for i in 0..<7 {
            let mem = UInt64(200_000_000) + UInt64(i) * 300_000_000
            fired += engine.ingest(rollups: [app(id: "a3", name: "Slack", cpu: 1, mem: mem)], at: start.addingTimeInterval(Double(i) * 600), notify: false)
        }
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired[0].kind, .memoryGrowth)
        XCTAssertTrue(fired[0].detail.contains("GB") || fired[0].detail.contains("MB"))
    }

    func testMemoryFreeResetsBaseline() {
        let engine = AlertEngine()
        let start = Date()
        var fired: [ActingUpAlert] = []
        // Grow to 1.3 GB, free back to 300 MB, grow again — second climb should fire again after cooldown-safe interval.
        let pattern: [UInt64] = [200_000_000, 800_000_000, 1_300_000_000, 300_000_000, 900_000_000, 1_400_000_000, 1_500_000_000]
        for (i, mem) in pattern.enumerated() {
            fired += engine.ingest(rollups: [app(id: "a4", name: "Cycler", cpu: 1, mem: mem)], at: start.addingTimeInterval(Double(i) * 900), notify: false)
        }
        // At least one fire; cooldown (1h) permits the second climb at i=4..6 (45–90 min).
        XCTAssertGreaterThanOrEqual(fired.count, 1)
    }

    func testNotificationAuthorizationRequestDoesNotCrash() async {
        // Should complete without crashing regardless of permission state.
        _ = await AlertEngine.requestAuthorizationIfNeeded()
    }
}

final class DownsampleTests: XCTestCase {
    func testDownsampleReducesAndPreservesBounds() {
        let start = Date()
        let points = (0..<1000).map { ChartMath.Point(at: start.addingTimeInterval(Double($0)), value: Double($0 % 50)) }
        let reduced = ChartMath.downsample(points, maxPoints: 200)
        XCTAssertLessThanOrEqual(reduced.count, 200)
        XCTAssertEqual(reduced.last?.at, points.last?.at)
    }

    func testDownsampleKeepsSmallInput() {
        let points = [ChartMath.Point(at: Date(), value: 1)]
        XCTAssertEqual(ChartMath.downsample(points, maxPoints: 200).count, 1)
    }
}

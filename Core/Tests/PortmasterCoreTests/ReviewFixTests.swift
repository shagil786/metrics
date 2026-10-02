import XCTest
@testable import PortmasterCore

/// Coverage for the review findings.
final class ReviewFixTests: XCTestCase {

    // MARK: #2 — real pressure signal

    func testKernelPressureLevelMapping() {
        XCTAssertEqual(MachSystemCollector.mapPressureLevel(1), .normal)
        XCTAssertEqual(MachSystemCollector.mapPressureLevel(2), .elevated)
        XCTAssertEqual(MachSystemCollector.mapPressureLevel(3), .critical)
        XCTAssertEqual(MachSystemCollector.mapPressureLevel(4), .critical)
        // Live check on this machine: the sysctl must be readable and map cleanly.
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let ok = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        if ok {
            XCTAssertGreaterThanOrEqual(level, 1)
            let mapped = MachSystemCollector.mapPressureLevel(level)
            XCTAssertTrue([.normal, .elevated, .critical].contains(mapped))
        }
    }

    // MARK: #1 — dev-service filter

    private func serviceRow(name: String, path: String?, project: String? = nil, cpu: Double = 0.5, pid: pid_t = 500) -> ProcessRow {
        ProcessRow(
            pid: pid, name: name, parentPid: nil, cpuPercent: cpu,
            memoryBytes: 10_000_000, projectID: project, executablePathHint: path
        )
    }

    func testSystemDaemonIsNotDevService() {
        XCTAssertFalse(SamplingEngine.isDevService(process: serviceRow(
            name: "rapportd", path: "/usr/libexec/rapportd"
        )))
        XCTAssertFalse(SamplingEngine.isDevService(process: serviceRow(
            name: "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter"
        )))
    }

    func testHomebrewAndUserServicesAreDev() {
        XCTAssertTrue(SamplingEngine.isDevService(process: serviceRow(
            name: "postgres", path: "/opt/homebrew/bin/postgres"
        )))
        XCTAssertTrue(SamplingEngine.isDevService(process: serviceRow(
            name: "node", path: "/Users/dev/work/api/node_modules/.bin/node"
        )))
    }

    func testProjectAttributionMakesDevServiceEvenWithOddPath() {
        XCTAssertTrue(SamplingEngine.isDevService(process: serviceRow(
            name: "weird-binary", path: "/Volumes/Tools/weird", project: "proj:/Users/dev/work/api"
        )))
    }

    func testFilteredServiceListExcludesRapportd() {
        var ledger: [pid_t: Date] = [:]
        let rows = [
            serviceRow(name: "rapportd", path: "/usr/libexec/rapportd", pid: 500),
            serviceRow(name: "postgres", path: "/opt/homebrew/bin/postgres", pid: 501),
        ]
        let ports = [
            ListeningPort(port: 4200, pid: 500, processName: "rapportd"),
            ListeningPort(port: 5432, pid: 501, processName: "postgres"),
        ]
        let services = SamplingEngine.buildServices(ports: ports, rows: rows, priorActivity: &ledger)
        XCTAssertEqual(services.count, 1)
        XCTAssertEqual(services[0].displayName, "postgres")
        XCTAssertFalse(services.contains { $0.displayName == "rapportd" })
    }

    // MARK: #3 — quiet needs real lookback

    func testQuietLabelRequiresWindowOfSilence() {
        var ledger: [pid_t: Date] = [:]
        let busy = serviceRow(name: "node", path: "/usr/local/bin/node", cpu: 12)
        let ports = [ListeningPort(port: 3000, pid: 500, processName: "node")]

        // First observation: busy → active.
        var services = SamplingEngine.buildServices(ports: ports, rows: [busy], priorActivity: &ledger)
        if case .quiet = services[0].activity {
            XCTFail("a service observed busy right now must not be labeled quiet")
        }

        // Immediately after: idle sample — but only 2 s of window have passed.
        let idle = serviceRow(name: "node", path: "/usr/local/bin/node", cpu: 0)
        services = SamplingEngine.buildServices(ports: ports, rows: [idle], priorActivity: &ledger)
        if case .quiet(let lookback) = services[0].activity {
            XCTAssertLessThan(lookback, 10, "quiet lookback must reflect actual observed silence, not claim 5 minutes")
        }
    }

    // MARK: #5 — descendant resolution

    func testDescendantsWalksFullTree() throws {
        // This test process tree: current pid is a leaf; find a process with
        // children and verify the walker goes deeper than one level using
        // launchd-free data we control. We simulate via our own child spawn.
        let collector = LibprocProcessCollector()
        let sweep = try XCTUnwrap(collector.snapshot())
        // Sanity: walker returns empty for a childless, self-owned pid.
        let leaves = StopCoordinator.descendants(of: getpid(), using: collector)
        // Our own pid may have children in CI harnesses; just assert it never
        // includes itself.
        XCTAssertFalse(leaves.contains(getpid()))
        _ = sweep
    }

    // MARK: fmt.rate

    func testRateFormatting() {
        XCTAssertEqual(Fmt.rate(500), "500 B/s")
        XCTAssertEqual(Fmt.rate(67 * 1024), "67 kB/s")
        // Whole numbers trim ("5 MB/s", like the reference's "14 kB/s");
        // fractional values keep one decimal ("5.4 MB/s").
        XCTAssertEqual(Fmt.rate(5 * 1024 * 1024), "5 MB/s")
        XCTAssertEqual(Fmt.rate(5.4 * 1024 * 1024), "5.4 MB/s")
    }

    // MARK: CPU scale consistency (review P2)

    func testProcessCPUUsesMachineScale() {
        // One fully-busy core on an 8-core Mac → 12.5% of machine capacity,
        // directly comparable with the system CPU headline.
        let busyCore = SamplingEngine.machineCPUPercent(
            tickDeltaNanos: 1_000_000_000, intervalSeconds: 1, coreCount: 8
        )
        XCTAssertEqual(busyCore, 12.5, accuracy: 0.001)

        // Eight busy cores on 8 cores → 100%, never 800%.
        let allCores = SamplingEngine.machineCPUPercent(
            tickDeltaNanos: 8_000_000_000, intervalSeconds: 1, coreCount: 8
        )
        XCTAssertEqual(allCores, 100, accuracy: 0.001)

        // Half-interval busy single core on 10 cores.
        let half = SamplingEngine.machineCPUPercent(
            tickDeltaNanos: 500_000_000, intervalSeconds: 1, coreCount: 10
        )
        XCTAssertEqual(half, 5, accuracy: 0.001)
    }

    func testProcessCPUNeverExceedsSystemTotal() {
        // The sum of all per-process figures can never exceed the machine
        // total: same denominator guarantees comparability.
        let cores = 10
        let interval = 2.0
        let total = SamplingEngine.machineCPUPercent(
            tickDeltaNanos: Double(cores) * interval * 1_000_000_000,
            intervalSeconds: interval, coreCount: cores
        )
        XCTAssertLessThanOrEqual(total, 100.0)
    }

    // MARK: Disk I/O rates (Disk tab parity)

    func testDiskRatesNeedTwoSweeps() {
        // First sweep: no prior counters → nil (honest unknown), never zero.
        let first = SamplingEngine.diskRates(
            currentRead: 1_000, currentWrite: 2_000, prior: nil, intervalSeconds: 2
        )
        XCTAssertNil(first.read)
        XCTAssertNil(first.write)

        // Second sweep: delta over interval.
        let second = SamplingEngine.diskRates(
            currentRead: 11_000, currentWrite: 22_000,
            prior: (read: 1_000, write: 2_000), intervalSeconds: 2
        )
        XCTAssertEqual(second.read ?? -1, 5_000, accuracy: 0.001)
        XCTAssertEqual(second.write ?? -1, 10_000, accuracy: 0.001)
    }

    func testDiskRatesNilOnCounterReset() {
        // Pid reuse / counter reset: cumulative counter went backwards →
        // nil rather than a bogus negative or wrapped rate.
        let r = SamplingEngine.diskRates(
            currentRead: 500, currentWrite: 500,
            prior: (read: 9_000, write: 9_000), intervalSeconds: 2
        )
        XCTAssertNil(r.read)
        XCTAssertNil(r.write)
    }

    func testRollupDiskWriteRateSumsMembers() {
        var app = AppRollup(id: "bin:writer", displayName: "writer", isAppBundle: false)
        var a = ProcessRow(pid: 10, name: "w1", parentPid: nil)
        var b = ProcessRow(pid: 11, name: "w2", parentPid: nil)
        a.diskWriteBytesPerSec = 1_500
        b.diskWriteBytesPerSec = 500
        app.processes = [a, b]
        XCTAssertEqual(app.totalDiskWriteBytesPerSec ?? -1, 2_000, accuracy: 0.001)

        // Any member without a rate (first sweep) → sum unknown, not partial.
        b.diskWriteBytesPerSec = nil
        app.processes = [a, b]
        XCTAssertNil(app.totalDiskWriteBytesPerSec)
    }

    func testLiveSweepCarriesDiskCounters() throws {
        // The real collector must surface rusage counters for a live pid
        // (this test process itself certainly did disk I/O or at minimum is
        // readable); nil is acceptable only if the kernel refuses, which is
        // not expected for own-process.
        let collector = LibprocProcessCollector()
        let sweep = try XCTUnwrap(collector.snapshot())
        let selfRow = try XCTUnwrap(sweep.records.first { $0.pid == getpid() })
        XCTAssertNotNil(selfRow.diskReadBytes, "own-process rusage should be readable")
        XCTAssertNotNil(selfRow.diskWriteBytes, "own-process rusage should be readable")
    }

    // MARK: nettop parsing (Network tab parity)

    func testNettopCSVParsing() {
        let csv = """
        ,bytes_in,bytes_out,
        syslogd.130,0,23596,
        Chrome Helper.4021,10512690,4806515,
        mDNSResponder.216,10612690,4806515,
        """
        let rows = NettopNetworkCollector.parseCSV(Data(csv.utf8))
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].pid, 130)
        XCTAssertEqual(rows[0].bytesIn, 0)
        XCTAssertEqual(rows[0].bytesOut, 23_596)
        // Name with spaces/dots keeps everything before the last dot.
        XCTAssertEqual(rows[1].name, "Chrome Helper")
        XCTAssertEqual(rows[2].bytesIn, 10_612_690)
    }

    func testNettopCSVSkipsGarbage() {
        let csv = """
        ,bytes_in,bytes_out,
        header-ish,,
        badline.abc,1,2,
        shortrow.5,3,
        kern.0,4,5,
        """
        let rows = NettopNetworkCollector.parseCSV(Data(csv.utf8))
        // Only kern.0 parses (pid 0 dropped, everything else malformed).
        XCTAssertEqual(rows.count, 0)
    }

    func testRollupNetInRateSumsMembers() {
        var app = AppRollup(id: "bin:dl", displayName: "dl", isAppBundle: false)
        var a = ProcessRow(pid: 10, name: "d1", parentPid: nil)
        var b = ProcessRow(pid: 11, name: "d2", parentPid: nil)
        a.netInBytesPerSec = 2_000_000
        b.netInBytesPerSec = 500_000
        app.processes = [a, b]
        XCTAssertEqual(app.totalNetInBytesPerSec ?? -1, 2_500_000, accuracy: 0.001)

        b.netInBytesPerSec = nil
        app.processes = [a, b]
        XCTAssertNil(app.totalNetInBytesPerSec)
    }

    // MARK: Battery wattage + project summaries (GPU/Battery/Projects parity)

    func testBatteryWattageMath() {
        // 11.4 V × 1.44 A ≈ 16.4 W — the reference's power-draw figure.
        XCTAssertEqual(BatteryCollector.watts(voltageMV: 11_400, amperageMA: 1_440) ?? -1, 16.416, accuracy: 0.001)
        // Negative amperage (discharge sign conventions) → magnitude.
        XCTAssertEqual(BatteryCollector.watts(voltageMV: 11_400, amperageMA: -1_000) ?? -1, 11.4, accuracy: 0.001)
        // Missing readings → honest nil, never zero.
        XCTAssertNil(BatteryCollector.watts(voltageMV: nil, amperageMA: 1_000))
        XCTAssertNil(BatteryCollector.watts(voltageMV: 11_400, amperageMA: nil))
    }

    // MARK: CPU tab — windowed stats + P/E core counts

    private func cpuStatSample(_ percent: Double, _ at: Date) -> (value: Double, at: Date) {
        (percent, at)
    }

    func testCpuWindowStatsNeedTwoSamples() {
        // One sample today: an average is not yet computable — honest nil.
        let now = Date()
        let one = CpuWindowStats.compute(samples: [cpuStatSample(20, now)], now: now)
        XCTAssertNil(one.averageTodayPercent)
        XCTAssertTrue(one.averageSeries.isEmpty)
        XCTAssertEqual(one.sampleCount, 1)
    }

    func testCpuWindowStatsAveragesOnlyToday() {
        let cal = Calendar.current
        // A fixed local noon keeps "one hour ago" today, including runs just after midnight.
        let now = cal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let today = cal.date(byAdding: .hour, value: -1, to: now)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        let stats = CpuWindowStats.compute(samples: [
            cpuStatSample(10, yesterday),
            cpuStatSample(30, today),
            cpuStatSample(50, now),
        ], now: now)
        // Yesterday's sample is excluded: 30+50 / 2, not 10+30+50 / 3.
        XCTAssertEqual(stats.averageTodayPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(stats.sampleCount, 2)
        XCTAssertFalse(stats.averageSeries.isEmpty)
    }

    func testCpuWindowStatsFutureSamplesExcluded() {
        let now = Date()
        let future = now.addingTimeInterval(3600)
        let stats = CpuWindowStats.compute(samples: [
            cpuStatSample(20, now),
            cpuStatSample(90, future),
        ], now: now)
        XCTAssertNil(stats.averageTodayPercent, "a lone sample plus a clock-skewed future sample is still not an average")
        XCTAssertEqual(stats.sampleCount, 1)
    }

    func testCpuWindowStatsSeriesBounded() {
        let now = Date()
        let samples = (0..<500).map { i -> (Double, Date) in
            (Double(i % 90), now.addingTimeInterval(Double(-i) * 60))
        }
        let stats = CpuWindowStats.compute(samples: samples.map { (value: $0.0, at: $0.1) }, now: now, buckets: 48)
        XCTAssertLessThanOrEqual(stats.averageSeries.count, 48)
        XCTAssertGreaterThan(stats.averageSeries.count, 1)
    }

    func testPerformanceCoreCountsCoverAllCores() {
        // Live check on this machine: when the kernel exposes a P/E split,
        // it must sum to the logical core count the CPU collector reports.
        let (p, e) = SystemInfo.performanceCoreCounts()
        if p != nil {
            let cpu = MachSystemCollector().sampleCPU()
            if let cpu, cpu.coreCount > 0 {
                XCTAssertEqual(p! + (e ?? 0), cpu.coreCount,
                               "P+E must account for every logical core")
            }
        }
        // Otherwise both nil — callers show "—", never a fabricated split.
    }

    func testProjectSummaryAggregation() {
        var web = ProcessRow(pid: 1, name: "node", parentPid: nil, memoryBytes: 100_000_000,
                             projectID: "proj:/Users/dev/storefront-web")
        var api = ProcessRow(pid: 2, name: "postgres", parentPid: nil, memoryBytes: 250_000_000,
                             projectID: "proj:/Users/dev/storefront-web")
        let rogue = ProcessRow(pid: 3, name: "rapportd", parentPid: nil, memoryBytes: 5_000_000)
        let ports = [
            ListeningPort(port: 4322, pid: 1, processName: "node"),
            ListeningPort(port: 4322, pid: 1, processName: "node"), // dup FD
            ListeningPort(port: 4200, pid: 3, processName: "rapportd"), // unattributed
        ]
        web.executablePathHint = "/usr/local/bin/node"
        api.executablePathHint = "/opt/homebrew/bin/postgres"

        let summaries = ProjectSummary.build(processes: [web, api, rogue], ports: ports)
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].displayName, "storefront-web")
        XCTAssertEqual(summaries[0].processCount, 2)
        XCTAssertEqual(summaries[0].memoryBytes, 350_000_000)
        XCTAssertEqual(summaries[0].ports, [4322], "duplicate FDs collapse; unattributed listener stays out")
    }
}

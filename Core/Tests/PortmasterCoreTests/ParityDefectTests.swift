import XCTest
@testable import PortmasterCore

/// Regression coverage for the 2026-09-30 parity-audit defects 1, 2 and 4.
final class ParityDefectTests: XCTestCase {

    private func usage(_ pid: pid_t, _ bytesIn: UInt64, _ bytesOut: UInt64 = 0) -> ProcessNetUsage {
        ProcessNetUsage(pid: pid, name: "p\(pid)", bytesIn: bytesIn, bytesOut: bytesOut)
    }

    // MARK: Defect 1 — counter overflow must saturate, never trap

    func testDuplicatePidCountersSaturateInParser() {
        let csv = """
        ,bytes_in,bytes_out,
        huge.42,\(UInt64.max),\(UInt64.max - 1),
        huge.42,10,10,
        """
        let rows = NettopNetworkCollector.parseCSV(Data(csv.utf8))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bytesIn, .max)
        XCTAssertEqual(rows[0].bytesOut, .max)
    }

    func testDiffSaturatesExtremeTotals() {
        let first = SamplingEngine.diffNettop(
            prior: nil, rows: [usage(1, 0), usage(2, 0)], intervalSeconds: 0)
        let second = SamplingEngine.diffNettop(
            prior: first.current,
            rows: [usage(1, .max), usage(2, .max)], intervalSeconds: 20)
        XCTAssertEqual(second.newIn, .max, "sum of two max deltas must clamp")
        XCTAssertEqual(UInt64.max.saturatingAdd(1), .max)
    }

    func testNegativeAndGarbageCountersRejected() {
        let csv = """
        ,bytes_in,bytes_out,
        neg.7,-5,3,
        nan.8,abc,3,
        big.9,99999999999999999999999,3,
        """
        XCTAssertTrue(NettopNetworkCollector.parseCSV(Data(csv.utf8)).isEmpty)
    }

    // MARK: Defect 2 — baselines and session totals

    func testFirstPassIsBaselineNotTraffic() {
        let first = SamplingEngine.diffNettop(prior: nil, rows: [usage(1, 1_000)], intervalSeconds: 0)
        XCTAssertEqual(first.newIn, 0)
        XCTAssertTrue(first.rates.isEmpty)

        let second = SamplingEngine.diffNettop(
            prior: first.current, rows: [usage(1, 1_200)], intervalSeconds: 20)
        XCTAssertEqual(second.newIn, 200, "delta is 1,200 − 1,000, not the lifetime 1,200")
        XCTAssertEqual(second.rates[1]?.in ?? -1, 10, accuracy: 0.0001)
    }

    func testDepartedProcessDoesNotEraseSurvivorTraffic() {
        // A: 100→150; B: 100 then gone. Old aggregate diff gave 150−200 → 0.
        let prior = SamplingEngine.diffNettop(
            prior: nil, rows: [usage(1, 100), usage(2, 100)], intervalSeconds: 0).current
        let diff = SamplingEngine.diffNettop(prior: prior, rows: [usage(1, 150)], intervalSeconds: 20)
        XCTAssertEqual(diff.newIn, 50)
        XCTAssertNil(diff.current[2])
    }

    func testNewProcessLifetimeTrafficIsBaseline() {
        let prior = SamplingEngine.diffNettop(prior: nil, rows: [usage(1, 100)], intervalSeconds: 0).current
        let diff = SamplingEngine.diffNettop(
            prior: prior, rows: [usage(1, 110), usage(3, 9_000_000)], intervalSeconds: 20)
        XCTAssertEqual(diff.newIn, 10, "pid 3's pre-observation bytes are not session traffic")
        XCTAssertNil(diff.rates[3])

        let next = SamplingEngine.diffNettop(
            prior: diff.current, rows: [usage(1, 110), usage(3, 9_000_500)], intervalSeconds: 20)
        XCTAssertEqual(next.newIn, 500, "once baselined, pid 3 contributes its real delta")
    }

    func testCounterResetYieldsZero() {
        let prior = SamplingEngine.diffNettop(prior: nil, rows: [usage(1, 5_000)], intervalSeconds: 0).current
        let diff = SamplingEngine.diffNettop(prior: prior, rows: [usage(1, 10)], intervalSeconds: 20)
        XCTAssertEqual(diff.newIn, 0)
        XCTAssertNil(diff.rates[1])
    }

    // MARK: Defect 4 — quiet label states only observed silence

    private func svcRow(cpu: Double, pid: pid_t = 700) -> ProcessRow {
        ProcessRow(pid: pid, name: "node", parentPid: nil, cpuPercent: cpu,
                   memoryBytes: 1, executablePathHint: "/usr/local/bin/node")
    }

    func testNewIdleListenerDoesNotClaimFiveMinutes() {
        var ledger: [pid_t: Date] = [:]
        let ports = [ListeningPort(port: 3000, pid: 700, processName: "node")]
        let services = SamplingEngine.buildServices(ports: ports, rows: [svcRow(cpu: 0)], priorActivity: &ledger)
        guard case .quiet(let lookback) = services[0].activity else {
            return XCTFail("idle listener should be quiet")
        }
        XCTAssertLessThan(lookback, 1, "first sighting has observed ~0 s, not \(SamplingEngine.quietLookback)")
    }

    func testQuietIntervalGrowsFromFirstSighting() {
        let ports = [ListeningPort(port: 3000, pid: 700, processName: "node")]
        var ledger: [pid_t: Date] = [700: Date().addingTimeInterval(-120)]
        let services = SamplingEngine.buildServices(ports: ports, rows: [svcRow(cpu: 0)], priorActivity: &ledger)
        guard case .quiet(let lookback) = services[0].activity else { return XCTFail() }
        XCTAssertEqual(lookback, 120, accuracy: 2)
    }

    func testLedgerForgetsPidsThatStopListening() {
        var ledger: [pid_t: Date] = [999: Date().addingTimeInterval(-3600)]
        _ = SamplingEngine.buildServices(ports: [], rows: [], priorActivity: &ledger)
        XCTAssertNil(ledger[999], "a reused pid must not inherit an old observation window")
    }
}

import XCTest
@testable import PortmasterCore

/// Temporary diagnostic: does the engine tick with real collectors?
final class EngineProbeTests: XCTestCase {
    func testEngineProducesSnapshot() {
        let engine = SamplingEngine(
            systemCollector: MachSystemCollector(),
            processCollector: LibprocProcessCollector(),
            portCollector: LsofPortScanner(),
            cadence: .brisk
        )
        engine.start()
        let exp = expectation(description: "ticks")
        // 20s, not 8s: the first lsof invocation after a reboot/restart pays
        // a one-time cold-start cost that once exceeded the old 8s window
        // (warm stages measured: cpu 0.1ms, sweep 7ms, lsof 0.12s).
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exp.fulfill() }
        wait(for: [exp], timeout: 30)
        print("PROBE: processes=\(engine.latest.processes.count) cpu=\(engine.latest.system.cpu.totalPercent) at=\(engine.latest.at)")
        XCTAssertFalse(engine.latest.processes.isEmpty, "engine produced no process rows after 20s")
        XCTAssertNotEqual(engine.latest.at, .distantPast)
        engine.stop()
    }
}

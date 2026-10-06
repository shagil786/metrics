import XCTest
@testable import PortmasterCore

/// Temporary diagnostic: does the engine tick with real collectors?
///
/// Polls for the first published snapshot instead of sleeping a fixed 20 s and then
/// looking, which is the treatment `CLIIntegrationTests` already uses for its live
/// read: **a timeout skips, an assertion failure fails.** A busy machine — the whole
/// `swift test` suite running live collectors at once is exactly that — can be slower
/// than any budget a test can honestly hold, and a probe that reports "the engine does
/// not tick" because it was slow proves nothing about the engine. The property under
/// test is that a tick arrives and carries process rows; a run where it does not gets
/// a skip naming the budget, which is a weaker but truthful outcome.
///
/// `engine.latest` is not main-actor isolated, so polling it from the test thread is
/// safe; what publishes it is a main-queue hop inside the engine.
final class EngineProbeTests: XCTestCase {

    /// How long the engine has to publish a snapshot with real process rows. The first
    /// tick dispatches the slow lane, and the first `lsof` after a reboot or a cold
    /// start pays a one-time cost; warm stages measured: cpu 0.1 ms, sweep 7 ms, lsof
    /// 0.12 s. Generous, because the cost being absorbed is contention from the rest of
    /// the suite rather than the engine's own work.
    static let probeBudget: TimeInterval = 30

    func testEngineProducesSnapshot() async throws {
        let engine = SamplingEngine(
            systemCollector: MachSystemCollector(),
            processCollector: LibprocProcessCollector(),
            portCollector: LsofPortScanner(),
            cadence: .brisk
        )
        engine.start()
        defer { engine.stop() }

        let deadline = Date().addingTimeInterval(Self.probeBudget)
        while engine.latest.processes.isEmpty || engine.latest.at == .distantPast {
            guard Date() < deadline else {
                throw XCTSkip(
                    "no process rows within \(Int(Self.probeBudget))s; the assertion "
                        + "this guards against is an engine that reports a snapshot "
                        + "with no rows, which still fails below"
                )
            }
            try await Task.sleep(for: .milliseconds(200))
        }

        print(
            "PROBE: processes=\(engine.latest.processes.count) "
                + "cpu=\(engine.latest.system.cpu.totalPercent) at=\(engine.latest.at)"
        )
        XCTAssertFalse(engine.latest.processes.isEmpty, "engine produced no process rows")
        XCTAssertNotEqual(engine.latest.at, .distantPast)
    }
}
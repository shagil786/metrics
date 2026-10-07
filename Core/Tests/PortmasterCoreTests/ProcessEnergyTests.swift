// Per-process energy accounting. The kernel bills energy per process only on
// some Macs; where it does not, every process reads zero. The whole point of
// ProcessEnergy's three states is that "nobody is counting" and "counted, and
// the answer was zero" stay distinguishable, because rendering both as 0 W is
// how a monitor asserts something it does not know.
//
// Fixture-driven: counter values are injected, so every branch is exercised
// without hardware that bills energy.
import XCTest
import PMShim
@testable import PortmasterCore

final class ProcessEnergyTests: XCTestCase {

    // MARK: - Rate derivation

    /// A rising counter on a machine that meters energy yields that rate.
    func testRisingCounterProducesRate() {
        let state = SamplingEngine.energyState(
            current: 2_000, prior: 1_000, intervalSeconds: 2, metersEnergy: true)
        guard case .available(let rate) = state else { return XCTFail("expected available, got \(state)") }
        XCTAssertEqual(rate, 500, accuracy: 0.0001)
    }

    /// THE REGRESSION THIS DESIGN EXISTS FOR.
    ///
    /// The kernel can advertise per-process energy accounting
    /// (`ri_energy_nj != 0`) and never advance the counter — measured on an M4
    /// Mac mini, where it stayed bit-identical through a sustained CPU burn.
    /// Every process then reads exactly 0, forever. Publishing that as `.available(0)`
    /// would render the whole machine as having measured no energy, which is a
    /// claim no one can support. A delta of zero before any rate has ever been
    /// observed must be `.notReported`, not a measured zero.
    func testFrozenCounterIsNotReportedRatherThanMeasuredZero() {
        let state = SamplingEngine.energyState(
            current: 28737, prior: 28737, intervalSeconds: 1, metersEnergy: false)
        XCTAssertEqual(state, .notReported,
                       "a counter that never moves must not read as a measured zero")
        XCTAssertFalse(state.isAvailable)
    }

    /// Once a machine has produced a rate, a later flat stretch is a process
    /// that was idle — a real measured zero, not a lost capability.
    func testFlatCounterAfterARateIsAMeasuredZero() {
        let state = SamplingEngine.energyState(
            current: 5_000, prior: 5_000, intervalSeconds: 1, metersEnergy: true)
        guard case .available(let rate) = state else { return XCTFail("expected available, got \(state)") }
        XCTAssertEqual(rate, 0)
    }

    /// The kernel publishing no energy field at all.
    func testUnmeteredMachineIsNotReported() {
        XCTAssertEqual(SamplingEngine.energyState(
            current: 1_000, prior: 1_000, intervalSeconds: 1, metersEnergy: false), .notReported)
        XCTAssertEqual(SamplingEngine.energyState(
            current: nil, prior: nil, intervalSeconds: 1, metersEnergy: true), .notReported)
    }

    /// A counter with no earlier sample to difference against, or a pid that
    /// exited mid-sweep, produces no rate.
    func testMissingCounterOrPriorIsNotSampledYet() {
        XCTAssertEqual(SamplingEngine.energyState(
            current: 1_000, prior: nil, intervalSeconds: 1, metersEnergy: true), .notSampledYet)
        XCTAssertEqual(SamplingEngine.energyState(
            current: 1_000, prior: 500, intervalSeconds: 0, metersEnergy: true), .notSampledYet)
    }

    /// A counter that went backwards means the pid restarted. Dropping the
    /// sample beats emitting a negative rate, which would read as a process
    /// generating energy.
    func testCounterGoingBackwardsIsNotSampledYet() {
        let state = SamplingEngine.energyState(
            current: 10, prior: 9_999, intervalSeconds: 1, metersEnergy: true)
        XCTAssertEqual(state, .notSampledYet)
        XCTAssertNil(state.nanounitsPerSecond)
    }

    /// A sub-millisecond interval must not divide by zero into infinity.
    func testTinyIntervalClampsRatherThanDividingByZero() {
        let state = SamplingEngine.energyState(
            current: 1_000, prior: 0, intervalSeconds: 0.000_001, metersEnergy: true)
        guard case .available(let rate) = state else { return XCTFail("expected available, got \(state)") }
        XCTAssertTrue(rate.isFinite)
    }

    // MARK: - The property that matters most

    /// The three states must not collapse into each other. Specifically: a
    /// machine that cannot measure must never be indistinguishable from a
    /// process that measured zero.
    func testNotReportedIsNeverConfusedWithMeasuredZero() {
        let unknown = SamplingEngine.energyState(
            current: nil, prior: nil, intervalSeconds: 1, metersEnergy: true)
        let measuredZero = SamplingEngine.energyState(
            current: 7, prior: 7, intervalSeconds: 1, metersEnergy: true)

        XCTAssertNotEqual(unknown, measuredZero)
        XCTAssertNil(unknown.nanounitsPerSecond)
        XCTAssertNotNil(measuredZero.nanounitsPerSecond)
        XCTAssertFalse(unknown.isAvailable)
        XCTAssertTrue(measuredZero.isAvailable)
    }

    // MARK: - Resting default

    /// A row with no energy assigned yet must read as not-reported, the honest
    /// resting answer — not as a measured zero.
    func testRowDefaultsToNotReported() {
        XCTAssertEqual(ProcessRow(pid: 1, name: "x", parentPid: nil).energy, .notReported)
    }

    // MARK: - Live kernel

    /// On this machine, `ri_energy_nj` says whether energy accounting exists at
    /// all. Both outcomes are valid; what must hold is that the collector's
    /// cached flag agrees with a direct read, so the machine-level claim cannot
    /// drift from the kernel's.
    func testCachedBillingFlagMatchesADirectRead() {
        var read: UInt64 = 0, written: UInt64 = 0
        var billed: UInt64 = 0, serviced: UInt64 = 0, nj: UInt64 = 0
        let ok = pm_rusage_counters(getpid(), &read, &written, &billed, &serviced, &nj) == 0

        guard ok else { return }  // no libproc here; nothing to assert
        XCTAssertEqual(LibprocProcessCollector.kernelAdvertisesEnergyAccounting, nj > 0)
    }

    /// The shim must report a live failure rather than silent zeros: a pid that
    /// cannot exist is the cheapest way to confirm the error path is real.
    func testShimFailsForAnImpossiblePid() {
        var read: UInt64 = 0, written: UInt64 = 0
        var billed: UInt64 = 0, serviced: UInt64 = 0, nj: UInt64 = 0
        let rc = pm_rusage_counters(pid_t(0x7FFF_FFFE), &read, &written, &billed, &serviced, &nj)
        XCTAssertNotEqual(rc, 0, "a nonexistent pid must not read as a successful sample")
    }

    /// Reading our own pid must succeed — the same call the collector relies on.
    func testShimReadsTheCallingProcess() {
        var read: UInt64 = 0, written: UInt64 = 0
        var billed: UInt64 = 0, serviced: UInt64 = 0, nj: UInt64 = 0
        XCTAssertEqual(pm_rusage_counters(getpid(), &read, &written, &billed, &serviced, &nj), 0)
    }
}

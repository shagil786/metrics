// Thermal availability: "this Mac has no sensors" and "the first sensor pass
// has not finished yet" are different facts, and the sampler must be able to
// tell them apart. These tests pin the three answers the engine publishes, all
// driven through fixture collectors — no real SMC, no subprocesses.
import XCTest
import Combine
@testable import PortmasterCore

final class ThermalAvailabilityTests: XCTestCase {

    // MARK: - What a pass publishes

    /// A pass that returned readings is an observation of working sensors.
    func testPassThatProducesReadingsPublishesAvailable() {
        let engine = Self.makeEngine(thermal: FixtureThermalProvider())
        let published = expectation(description: "a sample with readings")
        let subscription = engine.$latest.first { $0.system.thermal != nil }.sink { snapshot in
            guard let thermal = snapshot.system.thermal else { return XCTFail("no thermal sample") }
            XCTAssertEqual(thermal.availability, .available)
            XCTAssertEqual(thermal.cpuTempC ?? 0, 54, accuracy: 0.001)
            XCTAssertEqual(thermal.fans.count, 1)
            published.fulfill()
        }
        engine.start()
        // The first tick dispatches the slow lane; a subsequent tick publishes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { engine.refreshNow() }
        wait(for: [published], timeout: 4)
        engine.stop()
        subscription.cancel()
    }

    /// A pass that completed and produced nothing is not an unfinished pass: the
    /// sensors were asked and answered with nothing, so the sample says so
    /// instead of leaving the pre-pass state in place forever.
    func testPassThatProducesNothingPublishesNoSensors() {
        let engine = Self.makeEngine(thermal: SilentThermalProvider())
        let published = expectation(description: "an empty sample")
        let subscription = engine.$latest.first { $0.system.thermal != nil }.sink { snapshot in
            guard let thermal = snapshot.system.thermal else { return XCTFail("no thermal sample") }
            XCTAssertEqual(thermal.availability, .noSensors)
            XCTAssertNil(thermal.cpuTempC, "a pass that read nothing reports no number")
            XCTAssertNil(thermal.gpuTempC)
            XCTAssertNil(thermal.hottestTempC)
            XCTAssertTrue(thermal.fans.isEmpty)
            published.fulfill()
        }
        engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { engine.refreshNow() }
        wait(for: [published], timeout: 4)
        engine.stop()
        subscription.cancel()
    }

    /// Before any pass has completed the sampler has observed nothing at all, so
    /// it publishes no sample rather than one that claims the sensors answered
    /// empty. A nil here is the engine's encoding of "not sampled yet"; it must
    /// never be indistinguishable from the empty pass above.
    func testSnapshotBeforeAnyPassCarriesNoThermalSample() {
        let engine = Self.makeEngine(thermal: FixtureThermalProvider())
        let first = expectation(description: "the first snapshot")
        let subscription = engine.$latest.first().sink { snapshot in
            XCTAssertNil(
                snapshot.system.thermal,
                "a snapshot built before the slow lane answers must claim no sensor state"
            )
            first.fulfill()
        }
        engine.start()
        wait(for: [first], timeout: 4)
        engine.stop()
        subscription.cancel()
    }

    // MARK: - The model

    /// The three states are distinct values and each named sample carries only
    /// its own availability, so a caller cannot read one as another.
    func testTheThreeStatesAreDistinctSamples() {
        XCTAssertNotEqual(ThermalSample.noSensors.availability, ThermalSample.notSampledYet.availability)
        XCTAssertEqual(ThermalSample.noSensors.availability, .noSensors)
        XCTAssertEqual(ThermalSample.notSampledYet.availability, .notSampledYet)
        XCTAssertEqual(
            ThermalSample.readings(
                cpuTempC: 40, gpuTempC: nil, hottestTempC: 40,
                fans: [FanSample(name: "Fan 1", currentRPM: 900)]
            ).availability,
            .available
        )
        // Neither empty sample carries a reading, so nothing here can be mistaken
        // for a sensor that answered.
        for sample in [ThermalSample.noSensors, ThermalSample.notSampledYet] {
            XCTAssertNil(sample.cpuTempC)
            XCTAssertNil(sample.gpuTempC)
            XCTAssertNil(sample.hottestTempC)
            XCTAssertTrue(sample.fans.isEmpty)
        }
    }

    // MARK: - Fixtures

    /// An engine whose only real work is the thermal seam: everything else is a
    /// fixture, so these tests read the slow lane and never the machine.
    private static func makeEngine(thermal: ThermalProviding) -> SamplingEngine {
        SamplingEngine(
            systemCollector: FixtureSystemCollector(), processCollector: FixtureProcessCollector(),
            portCollector: FixturePortCollector(), nettopCollector: FixtureNettopProvider(),
            assertionCollector: FixtureAssertionProvider(), dockerCollector: FixtureDockerProvider(),
            thermalCollector: thermal,
            audioCollector: FixtureAudioProvider(), bluetoothCollector: FixtureBluetoothProvider()
        )
    }

    /// A sensor seam that never answers — the shape of a machine whose key space
    /// yields nothing plausible, or an SMC the collector cannot open.
    private final class SilentThermalProvider: ThermalProviding, @unchecked Sendable {
        func sample() -> ThermalSample? { nil }
    }
}
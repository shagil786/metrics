// Thermal availability: "this Mac has no sensors", "no sensor produced a
// plausible reading", and "nothing could be read at all yet" are three
// different facts, and the sampler must be able to tell them apart. These tests
// pin what a pass publishes, all driven through fixture collectors — no real
// SMC, no subprocesses.
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

    /// A readable key space with nothing plausible in it is a statement about
    /// the machine, so it is published — as an empty sample, never as one
    /// carrying a number for a sensor that said none.
    func testPassThatReadsNothingPublishesNoSensors() {
        let engine = Self.makeEngine(thermal: NoRecognizedSensorProvider())
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

    /// A pass that never reached the machine observed nothing, so it publishes
    /// `notSampledYet`. Publishing `noSensors` here would be a hardware claim
    /// the pass never made.
    func testPassThatCouldNotReadAnythingPublishesNotSampledYet() {
        let engine = Self.makeEngine(thermal: UnreadableSMCProvider())
        let published = expectation(description: "an unsampled state")
        let subscription = engine.$latest.first { $0.system.thermal != nil }.sink { snapshot in
            guard let thermal = snapshot.system.thermal else { return XCTFail("no thermal sample") }
            XCTAssertEqual(thermal.availability, .notSampledYet)
            published.fulfill()
        }
        engine.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { engine.refreshNow() }
        wait(for: [published], timeout: 4)
        engine.stop()
        subscription.cancel()
    }

    /// An unreadable pass replaces the reading published before it. Leaving the
    /// older reading standing would report a number this tick knows nothing
    /// about; reporting the empty pass as `noSensors` would claim a fact about
    /// the hardware the pass never established.
    func testNotSampledYetReplacesAnEarlierReading() {
        let engine = Self.makeEngine(thermal: ReadingsThenUnreadableProvider())
        let replaced = expectation(description: "the stale reading is replaced")
        var sawReading = false
        let subscription = engine.$latest.sink { snapshot in
            if snapshot.system.thermal?.availability == .available {
                sawReading = true
            } else if snapshot.system.thermal?.availability == .notSampledYet {
                XCTAssertTrue(sawReading, "the unreadable pass must follow a reading")
                XCTAssertNil(
                    snapshot.system.thermal?.cpuTempC,
                    "an earlier reading must not survive a pass that read nothing"
                )
                replaced.fulfill()
            }
        }
        engine.start()
        // Publish the first slow result, poll again after its five-second
        // cadence, then publish the unreadable pass. No real SMC/subprocess work.
        for delay in [0.5, 5.2, 5.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { engine.refreshNow() }
        }
        wait(for: [replaced], timeout: 8)
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

    /// An SMC that opened and enumerated but whose recognized sensors answered
    /// with nothing plausible — the shape of a Mac with no usable sensors.
    private struct NoRecognizedSensorProvider: ThermalProviding {
        func sample() -> ThermalSample { .noSensors }
    }

    /// An SMC that could not be read at all: nothing was observed, so nothing
    /// may be claimed about the machine.
    private struct UnreadableSMCProvider: ThermalProviding {
        func sample() -> ThermalSample { .notSampledYet }
    }

    /// Readings first, then an SMC that stopped answering — the mid-session
    /// failure that must not read as "no sensors" nor leave the old value up.
    private final class ReadingsThenUnreadableProvider: ThermalProviding, @unchecked Sendable {
        // Accessed only on the engine's serial slow lane.
        private var calls = 0
        func sample() -> ThermalSample {
            calls += 1
            guard calls == 1 else { return .notSampledYet }
            return FixtureThermalProvider().sample()
        }
    }
}

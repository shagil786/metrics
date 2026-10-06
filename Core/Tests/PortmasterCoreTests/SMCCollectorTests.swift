import XCTest
import Combine
@testable import PortmasterCore

final class SMCCollectorTests: XCTestCase {
    func testRawKeyAndTypeCanonicalization() {
        XCTAssertEqual(SMCCollector.canonicalString(Array("YEK#".utf8)), "#KEY")
        XCTAssertEqual(SMCCollector.canonicalString(Array(" tlf".utf8)), "flt ")
        XCTAssertEqual(SMCCollector.canonicalString(Array("cA0F".utf8)), "F0Ac")
        XCTAssertNil(SMCCollector.canonicalString([0, 0, 0, 0]))
        XCTAssertNil(SMCCollector.canonicalString([65, 66]))
    }

    func testM4FloatPayloadIsLittleEndian() {
        // Real M4 F0Ac bytes: exactly 1000 RPM, not a near-zero BE float.
        XCTAssertEqual(SMCCollector.decode(type: "flt ", bytes: [0, 0, 0x7a, 0x44]), 1000)
        XCTAssertEqual(SMCCollector.decode(type: "flt ", bytes: [0, 0, 0x48, 0x42]), 50)
        XCTAssertEqual(SMCCollector.decode(type: "flt ", bytes: [0, 0, 0, 0]), 0) // stopped fan
    }

    func testLegacyFixedPointDecoding() {
        XCTAssertEqual(SMCCollector.decode(type: "sp78", bytes: [0x32, 0x80]), 50.5)
        XCTAssertEqual(SMCCollector.decode(type: "sp78", bytes: [0xff, 0x80]), -0.5)
        XCTAssertEqual(SMCCollector.decode(type: "fpe2", bytes: [0x0f, 0xa0]), 1000)
    }

    func testIntegerDecoding() {
        XCTAssertEqual(SMCCollector.decode(type: "ui8 ", bytes: [2]), 2)
        XCTAssertEqual(SMCCollector.decode(type: "ui32", bytes: [0, 0, 1, 0]), 256)
        XCTAssertEqual(SMCCollector.decode(type: "si32", bytes: [0xff, 0xff, 0xff, 0xfe]), -2)
    }

    func testMalformedAndNonFinitePayloadsStayUnknown() {
        for type in ["flt ", "sp78", "fpe2", "ui8 ", "ui32", "si32", "hex_"] {
            XCTAssertNil(SMCCollector.decode(type: type, bytes: []))
        }
        XCTAssertNil(SMCCollector.decode(type: "flt ", bytes: [0, 0, 0xc0, 0x7f]))
        XCTAssertNil(SMCCollector.decode(type: "flt ", bytes: [0, 0, 0x80, 0x7f]))
        XCTAssertNil(SMCCollector.decode(type: "flt ", bytes: [0, 0, 0x80]))
    }

    func testSensorClassificationAndPlausibility() {
        XCTAssertTrue(SMCCollector.isCpuTempKey("Tp01"))
        XCTAssertTrue(SMCCollector.isCpuTempKey("TPD0"))
        XCTAssertTrue(SMCCollector.isCpuTempKey("TC0P"))
        XCTAssertFalse(SMCCollector.isCpuTempKey("TCMb"))
        XCTAssertFalse(SMCCollector.isCpuTempKey("TCMz"))
        XCTAssertTrue(SMCCollector.isGpuTempKey("Tg0D"))
        XCTAssertFalse(SMCCollector.isGpuTempKey("TH0a"))
        XCTAssertTrue(SMCCollector.isFanRpmKey("F0Ac"))
        XCTAssertFalse(SMCCollector.isFanRpmKey("F0Mn"))
        XCTAssertTrue(SMCCollector.isFanNameKey("F1Nm"))
        for bad in [0.0, -20, 151, Double.nan, Double.infinity] {
            XCTAssertFalse(SMCCollector.isPlausibleTemp(bad))
        }
        XCTAssertTrue(SMCCollector.isPlausibleTemp(5))
        XCTAssertTrue(SMCCollector.isPlausibleTemp(150))
    }

    func testTemperaturePreferenceRoundTrip() throws {
        let prefs = AppPreferences(menuBarMetric: .temperature)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded.menuBarMetric, .temperature)
    }

    func testBatteryHealthUsesRawCapacityNotNormalizedCharge() {
        let result = BatteryCollector.health(from: ["AppleRawMaxCapacity": 4500, "DesignCapacity": 5000, "MaxCapacity": 100, "CycleCount": 12])
        XCTAssertEqual(result.percent, 90)
        XCTAssertEqual(result.cycles, 12)
        XCTAssertNil(BatteryCollector.health(from: ["MaxCapacity": 100, "DesignCapacity": 5000]).percent)
    }

    func testBatteryHealthMissingAndInvalidMetadata() {
        XCTAssertNil(BatteryCollector.health(from: [:]).percent)
        XCTAssertNil(BatteryCollector.health(from: ["CycleCount": -1]).cycles)
        XCTAssertNil(BatteryCollector.health(from: ["AppleRawMaxCapacity": 0, "DesignCapacity": 0]).percent)
        XCTAssertEqual(BatteryCollector.health(from: ["MaxCapacity": 5100, "DesignCapacity": 5000]).percent, 102)
    }

    func testSlowLanePublishesInjectedThermalReading() {
        let expected = FixtureThermalProvider().sample()
        let engine = SamplingEngine(
            systemCollector: FixtureSystemCollector(), processCollector: FixtureProcessCollector(),
            portCollector: FixturePortCollector(), nettopCollector: FixtureNettopProvider(),
            assertionCollector: FixtureAssertionProvider(), dockerCollector: FixtureDockerProvider(),
            thermalCollector: FixtureThermalProvider(),
            audioCollector: FixtureAudioProvider(), bluetoothCollector: FixtureBluetoothProvider())
        let received = expectation(description: "thermal result in next snapshot")
        let subscription = engine.$latest.first { $0.system.thermal != nil }.sink { snapshot in
            XCTAssertEqual(snapshot.system.thermal, expected)
            XCTAssertEqual(snapshot.audio?.clients?.count, 0)
            XCTAssertEqual(snapshot.bluetooth?.devices.count, 0)
            received.fulfill()
        }
        engine.start()
        // The first tick dispatches the slow lane; a subsequent tick publishes it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { engine.refreshNow() }
        wait(for: [received], timeout: 4)
        engine.stop()
        subscription.cancel()
    }

    private final class FailingThermalProvider: ThermalProviding, @unchecked Sendable {
        // Accessed only on the engine's serial slow lane.
        private var calls = 0
        func sample() -> ThermalSample {
            calls += 1
            return calls == 1 ? FixtureThermalProvider().sample() : .notSampledYet
        }
    }

    /// A pass that cannot read the SMC must not leave the readings it published
    /// earlier standing, and must not be reported as a machine with no sensors
    /// either: it established nothing, so it publishes `notSampledYet` in place
    /// of the stale reading.
    func testUnreadablePassReplacesPublishedReadingsWithNotSampledYet() {
        let engine = SamplingEngine(
            systemCollector: FixtureSystemCollector(), processCollector: FixtureProcessCollector(),
            portCollector: FixturePortCollector(), nettopCollector: FixtureNettopProvider(),
            assertionCollector: FixtureAssertionProvider(), dockerCollector: FixtureDockerProvider(),
            thermalCollector: FailingThermalProvider(),
            audioCollector: FixtureAudioProvider(), bluetoothCollector: FixtureBluetoothProvider())
        let cleared = expectation(description: "an unreadable pass clears old data")
        var sawReading = false
        let subscription = engine.$latest.sink { snapshot in
            if snapshot.system.thermal?.availability == .available { sawReading = true }
            else if snapshot.system.thermal?.availability == .notSampledYet {
                XCTAssertTrue(sawReading, "the unreadable pass must follow a reading")
                XCTAssertNil(
                    snapshot.system.thermal?.cpuTempC,
                    "the earlier reading must not survive a pass that read nothing"
                )
                XCTAssertNotEqual(
                    snapshot.system.thermal?.availability, .noSensors,
                    "a pass that read nothing observed no evidence that the Mac has no sensors"
                )
                cleared.fulfill()
            }
        }
        engine.start()
        // Publish the first slow result, poll again after its five-second
        // cadence, then publish the failure. No real SMC/subprocess work.
        //
        // The 15s bound is not slack for this test's own work — there is none, and it
        // lands in about 5.9s — it is slack for a machine that is busy running the rest
        // of the suite's live collectors. 8s was 1.35x the measured time and starved
        // once in a 903s run, which is a flaky test rather than a signal. The floor is
        // the engine's own five-second slow-lane cadence, so no smaller bound can be
        // honest here: the assertion needs a second slow pass to exist at all.
        for delay in [0.5, 5.2, 5.7] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { engine.refreshNow() }
        }
        wait(for: [cleared], timeout: 15)
        engine.stop()
        subscription.cancel()
    }

    func testLiveSMCReadingsArePlausibleWhenAvailable() {
        // Portable smoke test: an SMC that cannot be read is an honest
        // `notSampledYet`, and an unreadable sensor key space is `noSensors`.
        // Neither is a claim about plausibility, so only readings are checked.
        let reading = SMCCollector().sample()
        guard reading.availability == .available else {
            print("SMC LIVE: unavailable (\(reading.availability))")
            return
        }
        for value in [reading.cpuTempC, reading.gpuTempC, reading.hottestTempC].compactMap({ $0 }) {
            XCTAssertTrue(SMCCollector.isPlausibleTemp(value))
        }
        for fan in reading.fans {
            XCTAssertTrue((fan.currentRPM ?? -1) >= 0)
            XCTAssertTrue((fan.currentRPM ?? 30000) < 30000)
        }
        print("SMC LIVE: \(reading)")
    }
}

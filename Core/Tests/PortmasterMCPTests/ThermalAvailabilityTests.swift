// The three thermal answers, end to end. A sensor pass that has not finished is
// not a machine with no sensors, so the first refuses and only the second is
// allowed to say `available: false`. Every seam is a stub: no real SMC, no
// sampler, no preferences, no subprocesses.
import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

final class ThermalAvailabilityTests: XCTestCase {

    // MARK: - The provider's three answers

    /// The refusal covers both reasons a pass can leave nothing observed — the
    /// first pass still pending, and an SMC that stopped answering mid-session —
    /// so its wording cannot be narrowed back to one of them.
    func testTheRefusalIsTrueForEveryUnobservedState() {
        let message = OnDemandProvider.thermalNotSampledMessage.lowercased()
        XCTAssertTrue(
            message.contains("no sensor reading has been observed"),
            "the refusal must read as 'nothing observed yet', not as a first-pass excuse: "
                + OnDemandProvider.thermalNotSampledMessage
        )
    }

    /// An unfinished pass has produced nothing to report, so the tool refuses.
    /// The snapshot encodes that state as no sample at all; a sample that names
    /// it explicitly must refuse identically rather than fall through to an
    /// `available: false` payload.
    func testNotSampledYetRefusesInsteadOfReportingNoSensors() async throws {
        let withoutSample = OnDemandProvider(
            snapshotSource: StubSnapshotSource([
                OnDemandProviderTests.makeSnapshot(cpuPercent: 10, thermal: nil)
            ]),
            appRunning: { false },
            cacheTTL: 0
        )
        let named = OnDemandProvider(
            snapshotSource: StubSnapshotSource([
                OnDemandProviderTests.makeSnapshot(
                    cpuPercent: 10, thermal: ThermalSample.notSampledYet
                )
            ]),
            appRunning: { false },
            cacheTTL: 0
        )

        for provider in [withoutSample, named] {
            do {
                let answered = try await provider.temperaturesFans()
                XCTFail(
                    "an unfinished sensor pass must refuse, not answer \(answered.availability)"
                )
            } catch let error as MCPToolError {
                XCTAssertEqual(error.message, OnDemandProvider.thermalNotSampledMessage)
            }
        }
    }

    /// A pass that completed and read nothing is a fact about the machine, so it
    /// is answered — with no numbers invented for the sensors that said nothing.
    func testNoSensorsAnswersWithTheEmptySample() async throws {
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([
                OnDemandProviderTests.makeSnapshot(
                    cpuPercent: 10, thermal: ThermalSample.noSensors
                )
            ]),
            appRunning: { false },
            cacheTTL: 0
        )

        let thermal = try await provider.temperaturesFans()

        XCTAssertEqual(thermal.availability, .noSensors)
        XCTAssertNil(thermal.cpuTempC)
        XCTAssertNil(thermal.gpuTempC)
        XCTAssertNil(thermal.hottestTempC)
        XCTAssertTrue(thermal.fans.isEmpty)
    }

    /// A pass with readings answers with them.
    func testAvailableAnswersWithTheReadings() async throws {
        let readings = ThermalSample.readings(
            cpuTempC: 71.5, gpuTempC: 66, hottestTempC: 71.5,
            fans: [FanSample(name: "Fan 1", currentRPM: 1_800)]
        )
        let provider = OnDemandProvider(
            snapshotSource: StubSnapshotSource([
                OnDemandProviderTests.makeSnapshot(cpuPercent: 10, thermal: readings)
            ]),
            appRunning: { false },
            cacheTTL: 0
        )

        let thermal = try await provider.temperaturesFans()

        XCTAssertEqual(thermal.availability, .available)
        XCTAssertEqual(try XCTUnwrap(thermal.cpuTempC), 71.5, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(thermal.gpuTempC), 66, accuracy: 0.001)
        XCTAssertEqual(thermal.fans.count, 1)
    }

    // MARK: - The wire answers

    /// The payload names the state beside the readings, and the readings that do
    /// not exist are absent rather than zero — the synthesized `Encodable`
    /// omits nil keys, it does not emit `null`, so a caller that wants a number
    /// has to have been given one.
    func testNoSensorsPayloadNamesTheStateAndInventsNoReading() async throws {
        let stub = StubProvider()
        stub.thermal = ThermalSample.noSensors
        let tool = try makeExecutor(provider: stub)
        let outcome = await tool.execute(name: "get_temperatures_fans", arguments: [:])

        XCTAssertFalse(outcome.isError, "a completed pass with no sensors is data: \(outcome.text)")
        let json = try jsonObject(outcome.text)
        XCTAssertEqual(json["availability"] as? String, "noSensors")
        XCTAssertEqual(json["available"] as? Bool, false)
        XCTAssertFalse(
            json.keys.contains("cpuTempC"),
            "an unreadable sensor is absent, never a fabricated zero or a null"
        )
        XCTAssertEqual((json["fans"] as? [Any])?.count, 0)
    }

    /// `available` stays for callers that only ever read the flag, and it is
    /// derived from the same state the payload names — so the two can never
    /// disagree about whether the sensors answered.
    func testAvailablePayloadKeepsTheDerivedFlagBesideTheReadings() async throws {
        let stub = StubProvider()
        stub.thermal = ThermalSample.readings(
            cpuTempC: 72.3125, gpuTempC: nil, hottestTempC: 88.125,
            fans: [FanSample(name: "Fan 1", currentRPM: 1_800)]
        )
        let tool = try makeExecutor(provider: stub)
        let outcome = await tool.execute(name: "get_temperatures_fans", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)
        XCTAssertEqual(json["availability"] as? String, "available")
        XCTAssertEqual(json["available"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(json["cpuTempC"] as? Double), 72.3125, accuracy: 0.0001)
        XCTAssertFalse(json.keys.contains("gpuTempC"), "a sensor that did not answer is omitted")
        XCTAssertEqual(try XCTUnwrap(json["hottestTempC"] as? Double), 88.125, accuracy: 0.0001)
        let fans = try XCTUnwrap(json["fans"] as? [[String: Any]])
        XCTAssertEqual(try XCTUnwrap(fans[0]["currentRPM"] as? Double), 1_800, accuracy: 0.001)
    }

    /// The refusal is still a refusal all the way out: a provider that cannot
    /// answer produces an error, never a payload dressed up as one.
    func testRefusalReachesTheCallerAsAnErrorWithNoPayload() async throws {
        let stub = StubProvider()
        stub.fail("temperaturesFans", with: OnDemandProvider.thermalNotSampledMessage)
        let tool = try makeExecutor(provider: stub)
        let outcome = await tool.execute(name: "get_temperatures_fans", arguments: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, OnDemandProvider.thermalNotSampledMessage)
        XCTAssertFalse(outcome.text.contains("availability"))
    }

    // MARK: - The overview's slice of the same sample

    /// The overview's thermal section is independently optional, so before the
    /// first pass its key is absent. Once a pass has answered, the section is
    /// present — and presence must not read as "the sensors answered": it names
    /// the state, exactly as `get_temperatures_fans` does.
    func testOverviewThermalSectionNamesTheStateWhenItIsPresent() async throws {
        for (sample, expected) in [
            (ThermalSample.noSensors, "noSensors"),
            (ThermalSample.notSampledYet, "notSampledYet"),
            (
                ThermalSample.readings(cpuTempC: 40, gpuTempC: nil, hottestTempC: 40, fans: []),
                "available"
            ),
        ] {
            let stub = StubProvider()
            var system = StubProvider.makeSample()
            system.thermal = sample
            stub.sample = system
            let tool = try makeExecutor(provider: stub)
            let outcome = await tool.execute(name: "get_system_overview", arguments: [:])

            XCTAssertFalse(outcome.isError, outcome.text)
            let thermal = try XCTUnwrap(
                jsonObject(outcome.text)["thermal"] as? [String: Any],
                "a sample in the snapshot must produce a thermal section: \(outcome.text)"
            )
            XCTAssertEqual(thermal["availability"] as? String, expected)
            XCTAssertEqual(thermal["available"] as? Bool, expected == "available")
        }
    }

    /// With no sample at all the overview omits the section entirely, which is
    /// the one case where absence is the honest answer.
    func testOverviewOmitsThermalBeforeAnySample() async throws {
        let stub = StubProvider()
        stub.sample = StubProvider.makeSample()
        stub.sample.thermal = nil
        let tool = try makeExecutor(provider: stub)
        let outcome = await tool.execute(name: "get_system_overview", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)
        XCTAssertFalse(
            json.keys.contains("thermal"),
            "an unsampled snapshot has nothing to say about sensors: \(outcome.text)"
        )
    }
}

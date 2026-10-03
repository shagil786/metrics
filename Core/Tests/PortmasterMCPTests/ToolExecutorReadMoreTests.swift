import XCTest
import PortmasterCore
import PortmasterMCP

/// The remaining read tools: containers, projects, history rankings,
/// temperatures/fans, active alerts, and settings.
///
/// Most of these are about one distinction the payload has to keep honest: an
/// *unavailable subsystem* (Docker daemon down, Docker absent, sensors that
/// answered with nothing) is a state of the machine the caller asked about, so it
/// comes back as data with `isError` false. A subsystem that has not been observed
/// yet is a different thing, and is an error. Only genuinely bad input — an
/// unknown range, an unknown resource — is an error. Collapsing the first case
/// into the second would tell a caller "the call failed" when the machine simply
/// answered; collapsing the second into the first would assert a machine state
/// nobody observed.
final class ToolExecutorReadMoreTests: XCTestCase {

    // MARK: get_containers

    func testContainersDaemonDownIsDataNotError() async throws {
        let stub = StubProvider()
        stub.dockerSample = DockerSample(availability: .daemonDown, containers: [])
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(name: "get_containers", arguments: [:])

        XCTAssertFalse(
            outcome.isError,
            "a stopped Docker daemon is an answer about the machine, "
                + "not a failed call: \(outcome.text)"
        )
        let json = try jsonObject(outcome.text)
        XCTAssertEqual(
            json["availability"] as? String, "daemonDown",
            "the caller must be able to tell the availability states apart"
        )
        XCTAssertEqual((json["containers"] as? [Any])?.count, 0)
        XCTAssertTrue(outcome.text.contains("daemonDown"), outcome.text)
        XCTAssertEqual(stub.count(of: "containers"), 1)
    }

    /// Every container field is named after a different measurement, so a
    /// transposition here (in for out, cpu from the wrong container) would ship
    /// wrong numbers to clients while every other test still passed. Each value
    /// below is deliberately distinct.
    func testContainersMapsEveryFieldFromItsOwnSource() async throws {
        let stub = StubProvider()
        stub.dockerSample = DockerSample(
            availability: .running,
            containers: [
                DockerContainer(
                    id: "abc123", name: "api", image: "ghcr.io/portmaster/api:1.2.3",
                    statusText: "Up 8 minutes", ports: [5432, 8080],
                    cpuPercent: 12.5, memoryBytes: 268_435_456,
                    networkInBytesPerSec: 1_000, networkOutBytesPerSec: 2_000,
                    diskReadBytesPerSec: 3_000, diskWriteBytesPerSec: 4_000
                )
            ]
        )
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(name: "get_containers", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)
        XCTAssertEqual(json["availability"] as? String, "running")
        XCTAssertNotNil(json["at"], "the sample's timestamp travels with the list")
        let containers = try XCTUnwrap(json["containers"] as? [[String: Any]])
        XCTAssertEqual(containers.count, 1)
        let container = try XCTUnwrap(containers.first)
        XCTAssertEqual(container["id"] as? String, "abc123")
        XCTAssertEqual(container["name"] as? String, "api")
        XCTAssertEqual(container["image"] as? String, "ghcr.io/portmaster/api:1.2.3")
        XCTAssertEqual(container["statusText"] as? String, "Up 8 minutes")
        XCTAssertEqual(
            container["isRunning"] as? Bool, true,
            "isRunning is derived from the status text, not sent by the caller"
        )
        XCTAssertEqual(
            container["ports"] as? [Int], [5432, 8080],
            "the collector sorts ports; the payload passes them through as given"
        )
        XCTAssertEqual(try XCTUnwrap(container["cpuPercent"] as? Double), 12.5, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(container["memoryBytes"] as? UInt64), 268_435_456,
            "memory must not be folded into another rate"
        )
        XCTAssertEqual(
            try XCTUnwrap(container["networkInBytesPerSec"] as? Double), 1_000, accuracy: 0.001,
            "in and out must not be transposed"
        )
        XCTAssertEqual(
            try XCTUnwrap(container["networkOutBytesPerSec"] as? Double), 2_000, accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(container["diskReadBytesPerSec"] as? Double), 3_000, accuracy: 0.001,
            "read and write must not be transposed"
        )
        XCTAssertEqual(
            try XCTUnwrap(container["diskWriteBytesPerSec"] as? Double), 4_000, accuracy: 0.001
        )
    }

    // MARK: get_projects

    func testProjectsDerivesSummaryFields() async throws {
        let stub = StubProvider()
        stub.projectSummaries = [
            PortmasterMCP.ProjectSummary(
                id: "/Users/dev/code/portmaster", name: "portmaster",
                processCount: 3, ports: [3000, 8080]
            )
        ]
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(name: "get_projects", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let projects = try jsonArray(outcome.text)
        XCTAssertEqual(projects.count, 1)
        let project = try XCTUnwrap(projects.first)
        XCTAssertEqual(project["id"] as? String, "/Users/dev/code/portmaster")
        XCTAssertEqual(project["name"] as? String, "portmaster")
        XCTAssertEqual(project["processCount"] as? Int, 3)
        XCTAssertEqual(project["ports"] as? [Int], [3000, 8080])
    }

    // MARK: get_history_rankings

    func testHistoryRankingsInvalidRangeIsError() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(
            name: "get_history_rankings", arguments: ["range": "3h"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Invalid range: 3h")
        XCTAssertEqual(
            stub.count(of: "historyRankings"), 0,
            "an unknown range must be rejected before the history is read"
        )
        XCTAssertNil(stub.lastHistoryWindow)
    }

    func testHistoryRankingsValidRangeMapsSinceDate() async throws {
        let stub = StubProvider()
        // Built through the real aggregation so the payload is exercised with a
        // trend the provider could actually produce (the model has no public
        // initializer of its own).
        let point = AppHistoryPoint(
            at: Date(), app: StubProvider.makeRollup(
                name: "Chrome", pid: 4242, cpu: 70, memory: 500_000_000
            ), interval: 60
        )
        stub.trends = AppHistoryTrend.aggregate([point], since: Date().addingTimeInterval(-3600))
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(
            name: "get_history_rankings", arguments: ["range": "12h"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        let window = try XCTUnwrap(stub.lastHistoryWindow)
        XCTAssertEqual(window, .h12, "\"12h\" must reach the provider as .h12")
        XCTAssertEqual(
            window.since.timeIntervalSinceNow, -12 * 3600, accuracy: 5,
            "the window the provider receives must already be the lookback start"
        )
        XCTAssertNil(stub.lastHistoryResource, "an absent resource means app trends")
        XCTAssertEqual(
            stub.count(of: "historyResources"), 0,
            "without a resource there is nothing for the resource path to read"
        )
        let trends = try jsonArray(outcome.text)
        XCTAssertEqual(trends.count, 1)
        let trend = try XCTUnwrap(trends.first)
        XCTAssertEqual(trend["displayName"] as? String, "Chrome")
        XCTAssertEqual(
            try XCTUnwrap(trend["averageCPU"] as? Double), 70, accuracy: 0.001,
            "a missing or wrongly-typed averageCPU must fail here, not read as 0"
        )
        XCTAssertEqual(try XCTUnwrap(trend["cpuSeconds"] as? Double), 42, accuracy: 0.001)
    }

    /// A resource reading belongs to no app, so resource mode must return the
    /// recorded points themselves. Decoding them as `AppHistoryTrend` would
    /// invent an app to hang a GPU temperature on.
    func testHistoryRankingsWithResourceReadsResourcePoints() async throws {
        let stub = StubProvider()
        stub.resourcePoints = [
            ResourceHistoryPoint(at: Date(), metric: "gpuTemperature", value: 61.5),
            // An unavailable reading stays null; it is not a zero.
            ResourceHistoryPoint(at: Date(), metric: "gpuTemperature", value: nil)
        ]
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(
            name: "get_history_rankings",
            arguments: ["range": "24h", "resource": "gpuTemperature"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(
            stub.count(of: "historyResources"), 1,
            "a resource request must reach the resource reader"
        )
        XCTAssertEqual(
            stub.count(of: "historyRankings"), 0,
            "app trends are a different question and must not be read as a stand-in"
        )
        XCTAssertEqual(stub.lastResourceWindow, .h24)
        XCTAssertEqual(stub.lastRequestedResource, .gpuTemperature)

        let points = try jsonArray(outcome.text)
        XCTAssertEqual(points.count, 2)
        let reading = try XCTUnwrap(points.first)
        XCTAssertEqual(reading["metric"] as? String, "gpuTemperature")
        XCTAssertEqual(try XCTUnwrap(reading["value"] as? Double), 61.5, accuracy: 0.001)
        XCTAssertNotNil(reading["at"], "a reading carries when it was taken")
        XCTAssertNil(
            points.last?["value"],
            "a missing reading must not be reported as a number"
        )
    }

    func testHistoryRankingsInvalidResourceIsError() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(
            name: "get_history_rankings",
            arguments: ["range": "24h", "resource": "temperatures"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Invalid resource: temperatures")
        XCTAssertEqual(stub.count(of: "historyRankings"), 0)
        XCTAssertEqual(
            stub.count(of: "historyResources"), 0,
            "an unknown resource must be rejected before any history is read"
        )
    }

    /// A blank `resource` is a value the caller sent, not an absent one. Treating
    /// it as absent would answer with app trends while the caller asked about a
    /// resource, which reads as if the resource had been honoured.
    func testHistoryRankingsBlankResourceIsRejectedNotAbsent() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(
            name: "get_history_rankings",
            arguments: ["range": "24h", "resource": "   "]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Invalid resource: ")
        XCTAssertEqual(
            stub.count(of: "historyRankings"), 0,
            "a blank resource must not fall through to app trends"
        )
        XCTAssertEqual(stub.count(of: "historyResources"), 0)
    }

    // MARK: get_temperatures_fans

    /// A provider that cannot answer refuses, and the refusal is the answer. The
    /// payload's `available` flag describes sensors the machine reported, so a
    /// sensor pass that has not reported anything must never be encoded as one.
    func testTemperaturesRefusalIsAnErrorNotAnUnavailablePayload() async throws {
        let stub = StubProvider()
        stub.fail("temperaturesFans", with: OnDemandProvider.thermalNotSampledMessage)
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(name: "get_temperatures_fans", arguments: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, OnDemandProvider.thermalNotSampledMessage)
        XCTAssertFalse(
            outcome.text.contains("available"),
            "an unsampled sensor pass must not be dressed up as a payload: \(outcome.text)"
        )
    }

    /// A sample that carries no reading is still a sample — it is what sensors
    /// that answer with nothing look like — so it stays data, and the payload
    /// says the readings are unavailable without sending a zero for any of them.
    func testTemperaturesWithNoReadingsReportsUnavailable() async throws {
        let stub = StubProvider()
        stub.thermal = ThermalSample.unknown
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(name: "get_temperatures_fans", arguments: [:])

        XCTAssertFalse(
            outcome.isError,
            "a sampled-but-empty reading is data, not a refusal: \(outcome.text)"
        )
        let json = try jsonObject(outcome.text)
        XCTAssertEqual(json["available"] as? Bool, false)
        XCTAssertNil(
            json["cpuTempC"],
            "an unreadable sensor must not be reported as a number"
        )
        XCTAssertNil(json["hottestTempC"])
        XCTAssertEqual((json["fans"] as? [Any])?.count, 0)
    }

    /// The nil branch above cannot tell a correct mapping from a transposed one,
    /// so the populated path names each field's own sensor. CPU, GPU and hottest
    /// are three distinct numbers precisely so a swap is visible.
    func testTemperaturesMapsEachSensorAndFanToItsOwnField() async throws {
        let stub = StubProvider()
        stub.thermal = ThermalSample(
            cpuTempC: 72.3125, gpuTempC: 60.5, hottestTempC: 88.125,
            fans: [
                FanSample(name: "Fan 1", currentRPM: 1_800),
                // An unreadable fan keeps a null RPM rather than reporting 0.
                FanSample(name: nil, currentRPM: nil)
            ]
        )
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(name: "get_temperatures_fans", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)
        XCTAssertEqual(
            json["available"] as? Bool, true,
            "a sample was reported, so the sensors are available"
        )
        XCTAssertEqual(try XCTUnwrap(json["cpuTempC"] as? Double), 72.3125, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(json["gpuTempC"] as? Double), 60.5, accuracy: 0.0001,
            "the GPU sensor must not be reported as the CPU one"
        )
        XCTAssertEqual(try XCTUnwrap(json["hottestTempC"] as? Double), 88.125, accuracy: 0.0001)
        let fans = try XCTUnwrap(json["fans"] as? [[String: Any]])
        XCTAssertEqual(fans.count, 2)
        XCTAssertEqual(fans[0]["name"] as? String, "Fan 1")
        XCTAssertEqual(try XCTUnwrap(fans[0]["currentRPM"] as? Double), 1_800, accuracy: 0.001)
        XCTAssertNil(fans[1]["name"], "an unnamed fan stays null")
        XCTAssertNil(
            fans[1]["currentRPM"],
            "an unreadable fan must not be reported as 0 RPM"
        )
    }

    // MARK: get_active_alerts

    func testGetActiveAlertsReturnsAlertJSON() async throws {
        let stub = StubProvider()
        stub.alertSource = .historyApproximate
        stub.alerts = [
            ActingUpAlert(
                id: "history:app:Chrome:sustainedCPU",
                kind: .sustainedCPU,
                appName: "Chrome",
                headline: "Chrome is keeping the CPU busy",
                detail: "70% average over 10 minutes.",
                at: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            ActingUpAlert(
                id: "history:app:Slack:diskHammering",
                kind: .diskHammering,
                appName: "Slack",
                headline: "Slack is hammering the disk",
                detail: "60 MB/s average over 10 minutes.",
                at: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ]
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(name: "get_active_alerts", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)
        XCTAssertEqual(
            json["source"] as? String, "history-approximate",
            "a caller must be able to tell a history approximation from a live observation"
        )
        let alerts = try XCTUnwrap(json["alerts"] as? [[String: Any]])
        XCTAssertEqual(alerts.count, 2)
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alert["id"] as? String, "history:app:Chrome:sustainedCPU")
        XCTAssertEqual(alert["kind"] as? String, "sustainedCPU")
        XCTAssertEqual(alert["appName"] as? String, "Chrome")
        XCTAssertEqual(alert["headline"] as? String, "Chrome is keeping the CPU busy")
        XCTAssertEqual(alert["detail"] as? String, "70% average over 10 minutes.")
        XCTAssertNotNil(alert["at"], "an alert carries when it was observed")
    }

    /// Provenance is exactly what a caller cannot infer from an empty array, so
    /// it has to survive the empty case — "no alerts" and "the alert path never
    /// ran" must not look the same.
    func testGetActiveAlertsEmptyStillReportsSource() async throws {
        for source in [AlertSource.historyApproximate, .live] {
            let stub = StubProvider()
            stub.alertSource = source
            stub.alerts = []
            let tool = try makeExecutor(provider: stub)

            let outcome = await tool.execute(name: "get_active_alerts", arguments: [:])

            XCTAssertFalse(outcome.isError, outcome.text)
            let json = try jsonObject(outcome.text)
            XCTAssertEqual(
                json["source"] as? String, source.rawValue,
                "an empty result must still name the evaluation that produced it"
            )
            XCTAssertEqual((json["alerts"] as? [Any])?.count, 0)
        }
    }

    // MARK: get_settings

    func testGetSettingsReturnsSnapshotJSON() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub)

        let outcome = await tool.execute(name: "get_settings", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)
        XCTAssertEqual(
            json["mutationMode"] as? String, "off",
            "a caller must be able to read back the current MCP mutation mode"
        )
        XCTAssertNotNil(json["temperatureUnit"])
        XCTAssertNotNil(json["alertsEnabled"])
    }
}

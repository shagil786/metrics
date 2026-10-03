import XCTest
import PortmasterCore
import PortmasterMCP

/// The remaining read tools: containers, projects, history rankings,
/// temperatures/fans, active alerts, and settings.
///
/// Most of these are about one distinction the payload has to keep honest: an
/// *unavailable subsystem* (Docker daemon down, Docker absent, SMC sensors
/// missing) is a state of the machine the caller asked about, so it comes back
/// as data with `isError` false. Only genuinely bad input — an unknown range, an
/// unknown resource — is an error. Collapsing the first case into the second
/// would tell a caller "the call failed" when the machine simply answered.
final class ToolExecutorReadMoreTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolExecutorReadMoreTests-\(UUID().uuidString)")
    }

    private func executor(_ provider: DataProvider, directory: URL) -> ToolExecutor {
        ToolExecutor(
            provider: provider,
            gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
            audit: AuditLog(directory: directory)
        )
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "payload must be a JSON object: \(text)"
        )
    }

    private func jsonArray(_ text: String) throws -> [[String: Any]] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]],
            "payload must be a JSON array: \(text)"
        )
    }

    // MARK: get_containers

    func testContainersDaemonDownIsDataNotError() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        stub.dockerSample = DockerSample(availability: .daemonDown, containers: [])
        let tool = executor(stub, directory: dir)

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

    // MARK: get_projects

    func testProjectsDerivesSummaryFields() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        stub.projectSummaries = [
            PortmasterMCP.ProjectSummary(
                id: "/Users/dev/code/portmaster", name: "portmaster",
                processCount: 3, ports: [3000, 8080]
            )
        ]
        let tool = executor(stub, directory: dir)

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
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        let tool = executor(stub, directory: dir)

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
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
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
        let tool = executor(stub, directory: dir)

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
        let trends = try jsonArray(outcome.text)
        XCTAssertEqual(trends.count, 1)
        XCTAssertEqual(trends[0]["displayName"] as? String, "Chrome")
        XCTAssertEqual(trends[0]["averageCPU"] as? Double ?? 0, 70, accuracy: 0.001)
        XCTAssertEqual(trends[0]["cpuSeconds"] as? Double ?? 0, 42, accuracy: 0.001)
    }

    func testHistoryRankingsInvalidResourceIsError() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        let tool = executor(stub, directory: dir)

        let outcome = await tool.execute(
            name: "get_history_rankings",
            arguments: ["range": "24h", "resource": "temperatures"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Invalid resource: temperatures")
        XCTAssertEqual(stub.count(of: "historyRankings"), 0)
    }

    // MARK: get_temperatures_fans

    func testTemperaturesUnavailableIsDataNotError() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        stub.thermal = nil
        let tool = executor(stub, directory: dir)

        let outcome = await tool.execute(name: "get_temperatures_fans", arguments: [:])

        XCTAssertFalse(
            outcome.isError,
            "absent SMC sensors are reported, not thrown: \(outcome.text)"
        )
        XCTAssertTrue(
            outcome.text.contains("\"available\":false"),
            "the payload must say so explicitly rather than send zeros: \(outcome.text)"
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

    // MARK: get_active_alerts

    func testGetActiveAlertsReturnsAlertJSON() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
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
                id: "app:Slack:diskHammering",
                kind: .diskHammering,
                appName: "Slack",
                headline: "Slack is hammering the disk",
                detail: "60 MB/s average over 10 minutes.",
                at: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ]
        let tool = executor(stub, directory: dir)

        let outcome = await tool.execute(name: "get_active_alerts", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let alerts = try jsonArray(outcome.text)
        XCTAssertEqual(alerts.count, 2)
        let alert = try XCTUnwrap(alerts.first)
        XCTAssertEqual(alert["id"] as? String, "history:app:Chrome:sustainedCPU")
        XCTAssertEqual(alert["kind"] as? String, "sustainedCPU")
        XCTAssertEqual(alert["appName"] as? String, "Chrome")
        XCTAssertEqual(alert["headline"] as? String, "Chrome is keeping the CPU busy")
        XCTAssertEqual(alert["detail"] as? String, "70% average over 10 minutes.")
        XCTAssertNotNil(alert["at"], "an alert carries when it was observed")

        // Provenance, so a caller can tell an alert the live engine just raised
        // from one reconstructed out of recorded samples. The provider marks the
        // second kind with a `"history:"` id prefix; the executor only reads it.
        XCTAssertEqual(
            alert["source"] as? String, "history-approximate",
            "a history-derived alert must not read as a live observation"
        )
        XCTAssertEqual(
            alerts[1]["source"] as? String, "live",
            "an unprefixed id means the live engine raised it"
        )
    }

    // MARK: get_settings

    func testGetSettingsReturnsSnapshotJSON() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        let tool = executor(stub, directory: dir)

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

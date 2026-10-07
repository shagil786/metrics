import XCTest
import PortmasterCore
import PortmasterMCP

// MARK: - Stub

/// Canned `DataProvider` with per-method call counters and per-method thrown
/// errors, so a test can assert both "what was asked" and "what was answered".
/// `@unchecked Sendable` because the counters are guarded by a lock.
final class StubProvider: DataProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var failures: [String: MCPToolError] = [:]

    // Canned results. Tests overwrite whichever one they exercise.
    var sample = StubProvider.makeSample()
    var rollups: [AppRollup] = []
    var details: [String: AppRollup] = [:]
    var stopReport = StopReport(results: ["4321": "stopped"])
    var dockerSample = DockerSample(availability: .running, containers: [])
    var projectSummaries: [PortmasterMCP.ProjectSummary] = []
    var trends: [AppHistoryTrend] = []
    var resourcePoints: [ResourceHistoryPoint] = []
    var thermal: ThermalSample = .noSensors
    var alerts: [ActingUpAlert] = []
    var alertSource: AlertSource = .historyApproximate

    static func makeSample() -> SystemSample {
        SystemSample(
            at: Date(timeIntervalSince1970: 1_700_000_000),
            cpu: SystemCPU(
                totalPercent: 12, userPercent: 8, systemPercent: 4,
                idlePercent: 88, corePercents: [8, 4], coreCount: 2
            ),
            memory: SystemMemory(
                totalBytes: 16_000_000_000, usedBytes: 8_000_000_000,
                pressureLevel: .normal, pressureRatio: 0.5,
                swapBytes: nil, freeBytes: 8_000_000_000,
                appBytes: nil, wiredBytes: nil, compressedBytes: nil
            )
        )
    }

    /// One single-process rollup, so the rollup totals equal that process's values.
    static func makeRollup(
        name: String,
        pid: Int32,
        cpu: Double,
        memory: UInt64,
        netIn: Double? = nil,
        diskWrite: Double? = nil
    ) -> AppRollup {
        var rollup = AppRollup(id: "app:\(name)", displayName: name, isAppBundle: true)
        rollup.processes = [
            ProcessRow(
                pid: pid, name: name, parentPid: 1,
                cpuPercent: cpu, memoryBytes: memory,
                diskWriteBytesPerSec: diskWrite, netInBytesPerSec: netIn
            )
        ]
        return rollup
    }

    /// Arms a provider failure, modelled the way `DataProvider` documents it:
    /// wrapped in `MCPToolError` so the message is caller- and log-safe.
    func fail(_ call: String, with message: String) {
        lock.withLock { failures[call] = MCPToolError(message: message) }
    }

    func count(of call: String) -> Int {
        lock.withLock { counters[call] ?? 0 }
    }

    var quitAppCallCount: Int { count(of: "quitApp") }
    var stopContainerCallCount: Int { count(of: "stopContainer") }
    var stopProjectCallCount: Int { count(of: "stopProject") }
    var topAppsCallCount: Int { count(of: "topApps") }
    var appDetailCallCount: Int { count(of: "appDetail") }

    /// What `quitApp` was actually asked for, so a test can pin that the value
    /// the executor validated is the value the provider receives.
    private(set) var lastQuitAppID: String?
    private(set) var lastQuitAppForce: Bool?

    /// What `setPreference` was actually asked for, so a test can pin that the
    /// key that passed the allowlist is the key the provider receives.
    private(set) var lastPreferenceKey: String?
    private(set) var lastPreferenceValue: String?

    /// What `historyRankings` was asked for, so a test can pin the range string
    /// a caller sent against the window the provider received.
    private(set) var lastHistoryWindow: HistoryWindow?
    private(set) var lastHistoryResource: HistoryResource?
    /// What `historyResources` was asked for, so a test can tell the resource
    /// path apart from the app-trend path.
    private(set) var lastResourceWindow: HistoryWindow?
    private(set) var lastRequestedResource: HistoryResource?

    /// Counts the call, then throws the armed `MCPToolError` when there is one.
    private func enter(_ call: String) throws {
        let failure: MCPToolError? = lock.withLock {
            counters[call, default: 0] += 1
            return failures[call]
        }
        if let failure { throw failure }
    }

    func systemOverview() async throws -> SystemSample {
        try enter("systemOverview")
        return sample
    }

    func topApps(metric: AppMetric, limit: Int) async throws -> [AppRollup] {
        try enter("topApps")
        return rollups
    }

    func appDetail(id: String) async throws -> AppRollup {
        try enter("appDetail")
        guard let rollup = details[id] else {
            throw MCPToolError(message: "App not found: \(id)")
        }
        return rollup
    }

    func containers() async throws -> DockerSample {
        try enter("containers")
        return dockerSample
    }

    func projects() async throws -> [PortmasterMCP.ProjectSummary] {
        try enter("projects")
        return projectSummaries
    }

    func historyRankings(
        window: HistoryWindow, resource: HistoryResource?
    ) async throws -> [AppHistoryTrend] {
        try enter("historyRankings")
        lastHistoryWindow = window
        lastHistoryResource = resource
        return trends
    }

    func historyResources(
        window: HistoryWindow, resource: HistoryResource
    ) async throws -> [ResourceHistoryPoint] {
        try enter("historyResources")
        lastResourceWindow = window
        lastRequestedResource = resource
        return resourcePoints
    }

    func temperaturesFans() async throws -> ThermalSample {
        try enter("temperaturesFans")
        return thermal
    }

    func activeAlerts() async throws -> AlertsSnapshot {
        try enter("activeAlerts")
        return AlertsSnapshot(source: alertSource, alerts: alerts)
    }

    /// `async`, like the requirement. The same note as `setPreference` below: a
    /// synchronous function witnesses an async requirement without complaint, so the
    /// only way this miss is visible is by reading for it.
    func settingsSnapshot() async -> SettingsSnapshot {
        SettingsSnapshot(
            temperatureUnit: "celsius", networkUnit: "bytes", cpuScale: "total",
            temperatureSource: "hottest", compactMenuBar: false,
            mutationMode: "off", alertsEnabled: true, retention: "hours24"
        )
    }

    func quitApp(id: String, force: Bool) async throws -> StopReport {
        try enter("quitApp")
        lastQuitAppID = id
        lastQuitAppForce = force
        return stopReport
    }

    func stopContainer(id: String) async throws -> StopReport {
        try enter("stopContainer")
        return stopReport
    }

    func stopProject(id: String) async throws -> StopReport {
        try enter("stopProject")
        return stopReport
    }

    /// `async`, like the protocol requirement. A synchronous function is a legal
    /// witness for it, so leaving this one out compiles and reads as though the
    /// provider's seam were still synchronous — which it is not.
    func setPreference(key: String, value: String) async throws {
        try enter("setPreference")
        lastPreferenceKey = key
        lastPreferenceValue = value
    }
}

// MARK: - Tests

/// Covers the executor's read dispatch, its error contract, and the one thing
/// the gate must never be fooled on: a denied mutation never reaches the provider.
final class ToolExecutorReadTests: XCTestCase {

    // MARK: Catalog

    func testCatalogDeclaresFourteenToolsAndClassifiesEffects() {
        let catalog = ToolExecutor.catalog
        XCTAssertEqual(catalog.count, 14, "catalog must declare all 14 tools")

        let names = catalog.map(\.name)
        XCTAssertEqual(Set(names).count, 14, "tool names must be unique")

        let expected: Set<String> = [
            "get_system_overview", "get_top_apps", "get_app_detail", "get_containers",
            "get_projects", "get_history_rankings", "get_temperatures_fans",
            "get_active_alerts", "get_settings", "report_usage",
            "quit_app", "stop_container", "stop_project", "set_preference"
        ]
        XCTAssertEqual(Set(names), expected)

        let mutations = Set(catalog.filter { $0.effect == .mutation }.map(\.name))
        XCTAssertEqual(
            mutations,
            ["quit_app", "stop_container", "stop_project", "set_preference"]
        )
        XCTAssertEqual(catalog.filter { $0.effect == .read }.count, 10)
        for tool in catalog {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) needs a description")
        }
    }

    // MARK: Reads

    func testOverviewReturnsSystemSampleJSON() async throws {
        let stub = StubProvider()
        stub.sample = StubProvider.makeSample()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .off, appRunning: false, directory: dir
        )

        let outcome = await tool.execute(name: "get_system_overview", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)
        XCTAssertNotNil(json["cpu"], "overview must carry a cpu section: \(outcome.text)")
        XCTAssertNotNil(json["memory"])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("mcp-audit.log").path),
            "reads are not audit-logged: they change nothing and would bury the mutation entries"
        )
    }

    func testTopAppsSortsByCPUDescendingAndHonorsLimit() async throws {
        let stub = StubProvider()
        stub.rollups = [
            StubProvider.makeRollup(name: "Low", pid: 1, cpu: 1.5, memory: 100),
            StubProvider.makeRollup(name: "High", pid: 2, cpu: 90, memory: 100),
            StubProvider.makeRollup(name: "Mid", pid: 3, cpu: 40, memory: 100)
        ]
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: false)

        let outcome = await tool.execute(
            name: "get_top_apps", arguments: ["metric": "cpu", "limit": "2"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        let apps = try jsonArray(outcome.text)
        XCTAssertEqual(apps.count, 2, "limit must be honored")
        XCTAssertEqual(apps[0]["displayName"] as? String, "High")
        XCTAssertEqual(apps[1]["displayName"] as? String, "Mid")
    }

    func testTopAppsNetworkSortsNilRatesLast() async throws {
        let stub = StubProvider()
        stub.rollups = [
            StubProvider.makeRollup(name: "Unknown", pid: 1, cpu: 0, memory: 0, netIn: nil),
            StubProvider.makeRollup(name: "Light", pid: 2, cpu: 0, memory: 0, netIn: 100),
            StubProvider.makeRollup(name: "Heavy", pid: 3, cpu: 0, memory: 0, netIn: 5_000)
        ]
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: false)

        let outcome = await tool.execute(
            name: "get_top_apps", arguments: ["metric": "network", "limit": "10"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        let apps = try jsonArray(outcome.text)
        XCTAssertEqual(
            apps.compactMap { $0["displayName"] as? String },
            ["Heavy", "Light", "Unknown"],
            "an unmeasured rate must sort last, never as zero"
        )
    }

    func testTopAppsRejectsUnboundedLimit() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: false)

        let outcome = await tool.execute(
            name: "get_top_apps", arguments: ["metric": "cpu", "limit": "100000"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("Invalid limit"), outcome.text)
        XCTAssertEqual(stub.topAppsCallCount, 0)
    }

    func testAppDetailUnknownIDIsError() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: false)

        let outcome = await tool.execute(name: "get_app_detail", arguments: ["id": "nope"])

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(
            outcome.text.contains("not found"),
            "provider message must surface verbatim: \(outcome.text)"
        )
    }

    // MARK: Error contract

    func testMissingArgumentIsError() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: false)

        let outcome = await tool.execute(name: "get_app_detail", arguments: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Missing argument: id")
        XCTAssertEqual(stub.appDetailCallCount, 0, "argument validation precedes the provider")
    }

    func testPaddedArgumentsAreForwardedAndAuditedTrimmed() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(
            name: "quit_app", arguments: ["id": "  4321\n", "force": " true "]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(
            stub.lastQuitAppID, "4321",
            "the value that passed validation must be the value the provider receives"
        )
        XCTAssertEqual(stub.lastQuitAppForce, true, "optional arguments are trimmed too")

        let entry = try XCTUnwrap(
            auditEntries(in: dir).first { $0["tool"] as? String == "quit_app" }
        )
        let audited = try XCTUnwrap(entry["arguments"] as? [String: String])
        XCTAssertEqual(
            audited["id"], "4321",
            "the audit line must record what was acted on, not what was typed"
        )
        XCTAssertEqual(audited["force"], "true")
    }

    func testBlankRequiredArgumentIsError() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .allowSession, appRunning: true)

        for blank in ["", "   ", "\n\t "] {
            let outcome = await tool.execute(
                name: "quit_app", arguments: ["id": blank]
            )
            XCTAssertTrue(outcome.isError, "id: \(blank.debugDescription)")
            XCTAssertEqual(outcome.text, "Missing argument: id")
        }
        XCTAssertEqual(
            stub.quitAppCallCount, 0,
            "a blank id must never reach a mutation provider, even when mutations are allowed"
        )
        XCTAssertNil(stub.lastQuitAppID)
    }

    func testUnknownToolIsError() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: false)

        let outcome = await tool.execute(name: "no_such_tool", arguments: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Unknown tool: no_such_tool")
    }

    // MARK: Mutations

    func testPermissionDeniedDoesNotCallProvider() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: true)

        let outcome = await tool.execute(name: "quit_app", arguments: ["id": "4321"])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(stub.quitAppCallCount, 0, "a denied mutation must never reach the provider")
        XCTAssertEqual(
            outcome.text, "MCP mutations are disabled in Portmaster settings.",
            "the caller must see the gate's reason, not a generic refusal"
        )
    }

    func testSuccessfulMutationWritesAuditEntry() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(name: "quit_app", arguments: ["id": "4321"])

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(stub.quitAppCallCount, 1)

        let entry = try XCTUnwrap(
            auditEntries(in: dir).first { $0["tool"] as? String == "quit_app" },
            "the allowed mutation must be audit-logged"
        )
        XCTAssertEqual(entry["outcome"] as? String, "allowed")
    }

    func testDeniedMutationWritesDeniedAuditEntry() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .off, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(name: "quit_app", arguments: ["id": "4321"])

        XCTAssertTrue(outcome.isError)
        let entries = try auditEntries(in: dir)
        XCTAssertEqual(entries.count, 1, "exactly one line per mutation attempt")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["tool"] as? String, "quit_app")
        XCTAssertEqual(entry["outcome"] as? String, "denied")
        XCTAssertEqual(
            entry["reason"] as? String, "MCP mutations are disabled in Portmaster settings."
        )
    }

    func testFailedMutationWritesFailedAuditEntry() async throws {
        let stub = StubProvider()
        stub.fail("quitApp", with: "PID 4321: still running after the stop signal")
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(name: "quit_app", arguments: ["id": "4321"])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(stub.quitAppCallCount, 1, "the gate allowed it, so it was attempted")

        let entry = try XCTUnwrap(
            auditEntries(in: dir).first { $0["tool"] as? String == "quit_app" }
        )
        XCTAssertEqual(
            entry["outcome"] as? String, "failed",
            "a permitted action that did not work must not read as allowed"
        )
        XCTAssertEqual(
            entry["reason"] as? String, "PID 4321: still running after the stop signal"
        )
    }
}

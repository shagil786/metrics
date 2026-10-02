import XCTest
import PortmasterCore
import PortmasterMCP

// MARK: - Stub

/// Canned `DataProvider` with per-method call counters and per-method thrown
/// errors, so a test can assert both "what was asked" and "what was answered".
/// `@unchecked Sendable` because the counters are guarded by a lock.
final class StubProvider: DataProvider, @unchecked Sendable {
    /// Provider-side failure. Carries the message the executor must surface.
    struct Failure: Error, Equatable {
        let message: String
    }

    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var failures: [String: Failure] = [:]

    // Canned results. Tests overwrite whichever one they exercise.
    var sample = StubProvider.makeSample()
    var rollups: [AppRollup] = []
    var details: [String: AppRollup] = [:]
    var stopReport = StopReport(results: ["4321": "stopped"])

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

    func fail(_ call: String, with message: String) {
        lock.withLock { failures[call] = Failure(message: message) }
    }

    func count(of call: String) -> Int {
        lock.withLock { counters[call] ?? 0 }
    }

    var quitAppCallCount: Int { count(of: "quitApp") }
    var stopContainerCallCount: Int { count(of: "stopContainer") }
    var stopProjectCallCount: Int { count(of: "stopProject") }
    var topAppsCallCount: Int { count(of: "topApps") }
    var appDetailCallCount: Int { count(of: "appDetail") }

    /// Counts the call, then throws when the test armed a failure for it.
    private func enter(_ call: String) throws {
        let failure: Failure? = lock.withLock {
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
        return DockerSample(availability: .running, containers: [])
    }

    func projects() async throws -> [PortmasterMCP.ProjectSummary] {
        try enter("projects")
        return []
    }

    func historyRankings(
        window: HistoryWindow, resource: HistoryResource?
    ) async throws -> [AppHistoryTrend] {
        try enter("historyRankings")
        return []
    }

    func temperaturesFans() async throws -> ThermalSample? {
        try enter("temperaturesFans")
        return nil
    }

    func activeAlerts() async throws -> [ActingUpAlert] {
        try enter("activeAlerts")
        return []
    }

    func settingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            temperatureUnit: "celsius", networkUnit: "bytes", cpuScale: "total",
            temperatureSource: "hottest", compactMenuBar: false,
            mutationMode: "off", alertsEnabled: true, retention: "hours24"
        )
    }

    func quitApp(id: String, force: Bool) async throws -> StopReport {
        try enter("quitApp")
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

    func setPreference(key: String, value: String) throws {
        try enter("setPreference")
    }
}

// MARK: - Tests

/// Covers the executor's read dispatch, its error contract, and the one thing
/// the gate must never be fooled on: a denied mutation never reaches the provider.
final class ToolExecutorReadTests: XCTestCase {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolExecutorReadTests-\(UUID().uuidString)")
    }

    private func executor(
        _ provider: DataProvider,
        mode: MCPMutationMode,
        appRunning: Bool,
        directory: URL
    ) -> ToolExecutor {
        ToolExecutor(
            provider: provider,
            gate: PermissionGate(settings: MCPSettings(mode: mode), appRunning: appRunning),
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

    // MARK: Catalog

    func testCatalogDeclaresThirteenToolsAndClassifiesEffects() {
        let catalog = ToolExecutor.catalog
        XCTAssertEqual(catalog.count, 13, "catalog must declare all 13 tools")

        let names = catalog.map(\.name)
        XCTAssertEqual(Set(names).count, 13, "tool names must be unique")

        let expected: Set<String> = [
            "get_system_overview", "get_top_apps", "get_app_detail", "get_containers",
            "get_projects", "get_history_rankings", "get_temperatures_fans",
            "get_active_alerts", "get_settings",
            "quit_app", "stop_container", "stop_project", "set_preference"
        ]
        XCTAssertEqual(Set(names), expected)

        let mutations = Set(catalog.filter { $0.effect == .mutation }.map(\.name))
        XCTAssertEqual(
            mutations,
            ["quit_app", "stop_container", "stop_project", "set_preference"]
        )
        XCTAssertEqual(catalog.filter { $0.effect == .read }.count, 9)
        for tool in catalog {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) needs a description")
        }
    }

    // MARK: Reads

    func testOverviewReturnsSystemSampleJSON() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        stub.sample = StubProvider.makeSample()
        let tool = executor(stub, mode: .off, appRunning: false, directory: dir)

        let outcome = await tool.execute(name: "get_system_overview", arguments: [:])

        XCTAssertFalse(outcome.isError, outcome.text)
        let json = try jsonObject(outcome.text)
        XCTAssertNotNil(json["cpu"], "overview must carry a cpu section: \(outcome.text)")
        XCTAssertNotNil(json["memory"])
    }

    func testTopAppsSortsByCPUDescendingAndHonorsLimit() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        stub.rollups = [
            StubProvider.makeRollup(name: "Low", pid: 1, cpu: 1.5, memory: 100),
            StubProvider.makeRollup(name: "High", pid: 2, cpu: 90, memory: 100),
            StubProvider.makeRollup(name: "Mid", pid: 3, cpu: 40, memory: 100)
        ]
        let tool = executor(stub, mode: .off, appRunning: false, directory: dir)

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
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        stub.rollups = [
            StubProvider.makeRollup(name: "Unknown", pid: 1, cpu: 0, memory: 0, netIn: nil),
            StubProvider.makeRollup(name: "Light", pid: 2, cpu: 0, memory: 0, netIn: 100),
            StubProvider.makeRollup(name: "Heavy", pid: 3, cpu: 0, memory: 0, netIn: 5_000)
        ]
        let tool = executor(stub, mode: .off, appRunning: false, directory: dir)

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

    func testAppDetailUnknownIDIsError() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        let tool = executor(stub, mode: .off, appRunning: false, directory: dir)

        let outcome = await tool.execute(name: "get_app_detail", arguments: ["id": "nope"])

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(
            outcome.text.contains("not found"),
            "provider message must surface verbatim: \(outcome.text)"
        )
    }

    // MARK: Error contract

    func testMissingArgumentIsError() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        let tool = executor(stub, mode: .off, appRunning: false, directory: dir)

        let outcome = await tool.execute(name: "get_app_detail", arguments: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Missing argument: id")
        XCTAssertEqual(stub.appDetailCallCount, 0, "argument validation precedes the provider")
    }

    func testUnknownToolIsError() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        let tool = executor(stub, mode: .off, appRunning: false, directory: dir)

        let outcome = await tool.execute(name: "no_such_tool", arguments: [:])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Unknown tool: no_such_tool")
    }

    // MARK: Mutations

    func testPermissionDeniedDoesNotCallProvider() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        let tool = executor(stub, mode: .off, appRunning: true, directory: dir)

        let outcome = await tool.execute(name: "quit_app", arguments: ["id": "4321"])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(stub.quitAppCallCount, 0, "a denied mutation must never reach the provider")
    }

    func testSuccessfulMutationWritesAuditEntry() async throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubProvider()
        let tool = executor(stub, mode: .allowSession, appRunning: true, directory: dir)

        let outcome = await tool.execute(name: "quit_app", arguments: ["id": "4321"])

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(stub.quitAppCallCount, 1)

        let logURL = dir.appendingPathComponent("mcp-audit.log")
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        let entries = contents.split(separator: "\n").map(String.init)
        let line = try XCTUnwrap(
            entries.first { $0.contains("\"tool\":\"quit_app\"") },
            "the allowed mutation must be audit-logged: \(contents)"
        )
        let entry = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(entry["outcome"] as? String, "allowed")
    }
}

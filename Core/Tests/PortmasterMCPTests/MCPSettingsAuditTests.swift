import XCTest
@testable import PortmasterMCP

final class MCPSettingsAuditTests: XCTestCase {

    // MARK: - MCPSettings

    func testSettingsDefaultsToOffWhenFileMissing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(MCPSettings.load(directory: dir).mode, .off)
    }

    func testSettingsRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var settings = MCPSettings()
        settings.mode = .allowSession
        try settings.save(directory: dir)

        XCTAssertEqual(MCPSettings.load(directory: dir).mode, .allowSession)
    }

    func testCorruptSettingsFileLoadsDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("mcp-settings.json")
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(MCPSettings.load(directory: dir).mode, .off)
    }

    // MARK: - AuditLog

    func testAuditLogAppendsOneJSONLinePerRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = AuditLog(directory: dir)
        log.record(tool: "get_status", arguments: [:], outcome: "allowed", reason: nil)
        log.record(
            tool: "stop_app",
            arguments: ["id": "dev.portmaster.app"],
            outcome: "denied",
            reason: "mutation mode is off"
        )

        let fileURL = dir.appendingPathComponent("mcp-audit.log")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)

        for line in lines {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "each line must be a JSON object"
            )
            for key in ["ts", "tool", "arguments", "outcome", "pid"] {
                XCTAssertNotNil(object[key], "missing key: \(key)")
            }
        }
    }

    func testAuditLogRecordsDenialReason() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = AuditLog(directory: dir)
        log.record(
            tool: "set_preference",
            arguments: ["key": "temperatureUnit"],
            outcome: "denied",
            reason: "blocked by policy"
        )

        let fileURL = dir.appendingPathComponent("mcp-audit.log")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("blocked by policy"))
    }

    func testAuditLogFileIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let log = AuditLog(directory: dir)
        log.record(tool: "get_status", arguments: [:], outcome: "allowed", reason: nil)

        let fileURL = dir.appendingPathComponent("mcp-audit.log")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.uint16Value, 0o600)
    }
}

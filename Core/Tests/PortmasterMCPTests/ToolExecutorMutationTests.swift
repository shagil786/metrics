import XCTest
import PortmasterCore
import PortmasterMCP

/// The mutation half of the tool surface: the gate, the preference allowlist,
/// and the audit line every attempt leaves behind.
///
/// What is under test is not that a stop worked — that is the provider's job —
/// but that nothing outside the allowlist can happen, and that every attempt,
/// allowed or denied, is on the record.
final class ToolExecutorMutationTests: XCTestCase {

    // MARK: Arguments reach the provider

    func testQuitAppPassesForceFlagToProvider() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .allowSession, appRunning: true)

        let outcome = await tool.execute(
            name: "quit_app", arguments: ["id": "4321", "force": "true"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(stub.quitAppCallCount, 1)
        XCTAssertEqual(
            stub.lastQuitAppForce, true,
            "force is the difference between a polite quit and a kill: it must not be dropped"
        )
        XCTAssertEqual(stub.lastQuitAppID, "4321")
    }

    func testStopContainerRequiresID() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .allowSession, appRunning: true)

        for arguments in [[String: String](), ["id": "   "]] {
            let outcome = await tool.execute(name: "stop_container", arguments: arguments)
            XCTAssertTrue(outcome.isError, arguments.debugDescription)
            XCTAssertEqual(outcome.text, "Missing argument: id")
        }
        XCTAssertEqual(
            stub.stopContainerCallCount, 0,
            "a missing or blank id must never reach a mutation provider, even when the gate allows it"
        )
    }

    // MARK: The gate is the only thing that decides whether a provider is called

    func testDeniedMutationAuditsDenial() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .off, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "temperatureUnit", "value": "fahrenheit"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(
            stub.count(of: "setPreference"), 0,
            "a denied mutation must be refused before the provider is touched"
        )

        let entries = try auditEntries(in: dir)
        XCTAssertEqual(entries.count, 1, "exactly one line per mutation attempt")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["tool"] as? String, "set_preference")
        XCTAssertEqual(entry["outcome"] as? String, "denied")
        XCTAssertEqual(
            entry["reason"] as? String, "MCP mutations are disabled in Portmaster settings.",
            "the log must carry the gate's reason, not a generic refusal"
        )
    }

    // MARK: set_preference allowlist

    func testSetPreferenceRejectsUnknownKey() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .allowSession, appRunning: true)

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "launchAtLogin", "value": "true"]
        )

        XCTAssertTrue(outcome.isError)
        // The whole sentence is pinned: a rejection that does not name the key
        // leaves the caller guessing which of its keys was the problem, and one
        // that does not list the allowlist makes it guess what to try instead.
        XCTAssertEqual(
            outcome.text,
            "Preference 'launchAtLogin' cannot be changed via MCP. "
                + "Allowed: compact, cpuScale, mcpMode, networkUnit, temperatureSource, temperatureUnit."
        )
        XCTAssertEqual(
            stub.count(of: "setPreference"), 0,
            "a key outside the allowlist must be refused before the provider is touched"
        )
        XCTAssertNil(stub.lastPreferenceKey)
    }

    func testSetPreferenceAllowlistsUnits() async throws {
        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .allowSession, appRunning: true)

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "temperatureUnit", "value": "fahrenheit"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(stub.count(of: "setPreference"), 1)
        XCTAssertEqual(
            stub.lastPreferenceKey, "temperatureUnit",
            "the key that passed the allowlist must be the key the provider receives"
        )
        XCTAssertEqual(stub.lastPreferenceValue, "fahrenheit")

        let json = try jsonObject(outcome.text)
        XCTAssertEqual(json["key"] as? String, "temperatureUnit")
        XCTAssertEqual(json["value"] as? String, "fahrenheit")
    }

    func testSetPreferenceMcpModeWritesSettingsFile() async throws {
        let stub = StubProvider()
        let settingsDirectory = try makeTemporaryDirectory(prefix: "\(name)-settings")
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true,
            settingsDirectory: settingsDirectory
        )
        XCTAssertEqual(
            MCPSettings.load(directory: settingsDirectory).mode, .off,
            "precondition: no settings file exists yet, so the default is read"
        )

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "mcpMode", "value": "allowSession"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(
            MCPSettings.load(directory: settingsDirectory).mode, .allowSession,
            "mcpMode must land in the settings file the gate reads, not only in a return value"
        )
        XCTAssertEqual(
            stub.count(of: "setPreference"), 0,
            "mcpMode is the MCP server's own policy rather than an app preference, so it "
                + "must not be routed through the provider's preferences blob"
        )
    }

    /// A mode that is not one of the three is refused, and refused *before* the
    /// write — otherwise a typo silently resets the user's mutation policy.
    func testSetPreferenceRejectsInvalidMcpModeValue() async throws {
        let stub = StubProvider()
        let settingsDirectory = try makeTemporaryDirectory(prefix: "\(name)-settings")
        try MCPSettings(mode: .confirmEach).save(directory: settingsDirectory)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true,
            settingsDirectory: settingsDirectory
        )

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "mcpMode", "value": "allowSessionn"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertTrue(outcome.text.contains("Invalid mcpMode"), outcome.text)
        XCTAssertEqual(
            MCPSettings.load(directory: settingsDirectory).mode, .confirmEach,
            "a rejected mode must leave the stored mode untouched"
        )
    }

    // MARK: A permitted action that does not work

    func testProviderFailureBecomesToolError() async throws {
        let stub = StubProvider()
        stub.fail("setPreference", with: "Invalid value for temperatureUnit: fahrenheit")
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "temperatureUnit", "value": "fahrenheit"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(
            stub.count(of: "setPreference"), 1, "the gate allowed it, so it was attempted"
        )
        XCTAssertTrue(
            outcome.text.contains("Invalid value for temperatureUnit"),
            "the provider's message is what tells the caller what to fix: \(outcome.text)"
        )

        let entry = try XCTUnwrap(
            auditEntries(in: dir).first { $0["tool"] as? String == "set_preference" }
        )
        XCTAssertEqual(
            entry["outcome"] as? String, "failed",
            "a permitted action that did not work must not read as allowed"
        )
        XCTAssertEqual(entry["reason"] as? String, "Invalid value for temperatureUnit: fahrenheit")
    }
}
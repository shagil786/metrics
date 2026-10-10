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

    /// A mutation attempt that could not even be parsed is still an attempt.
    ///
    /// It returns before the gate, so it used to leave nothing at all behind — and
    /// "an assistant tried to stop a container and nothing happened" is exactly the
    /// question the audit log exists to answer. The gate allowing is deliberate here,
    /// so the only thing that can produce a line is the malformed argument itself and
    /// not a refusal: `rejected` has to mean "the request never got as far as a
    /// decision", which is a different fact from `denied`.
    ///
    /// The second half is the boundary: a **read** with a missing argument is not a
    /// mutation attempt and is not logged. Widening the audit to malformed calls
    /// generally would bury the mutation lines under reads every client makes.
    func testMalformedMutationIsAuditedAsRejectedAndReadsStayUnlogged() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(name: "stop_container", arguments: ["id": "   "])

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(outcome.text, "Missing argument: id")
        XCTAssertEqual(
            stub.stopContainerCallCount, 0,
            "a blank id must never reach a mutation provider"
        )

        let entries = try auditEntries(in: dir)
        XCTAssertEqual(entries.count, 1, "exactly one line per mutation attempt")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["tool"] as? String, "stop_container")
        XCTAssertEqual(
            entry["outcome"] as? String, "rejected",
            "a call refused before the gate is neither allowed, denied nor failed"
        )
        XCTAssertEqual(
            entry["reason"] as? String, "Missing argument: id",
            "the log must name what the caller got wrong, not just that something was"
        )

        // A malformed *read* is not a mutation attempt, so it adds no line.
        let read = await tool.execute(name: "get_top_apps", arguments: [:])
        XCTAssertTrue(read.isError)
        XCTAssertEqual(try auditEntries(in: dir).count, 1, "reads are never logged")
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

    /// `tools/list` is the only place a client learns what it may write. A
    /// description that says "allowlisted" without naming the keys leaves the
    /// caller to guess, and one that omits the `compact` / `compactMenuBar`
    /// asymmetry makes it guess wrong using a name it just read from
    /// `get_settings`.
    func testCatalogDescriptionNamesEveryAllowedKeyAndBothNamingTraps() throws {
        let description = try XCTUnwrap(
            ToolExecutor.catalog.first { $0.name == "set_preference" }?.description
        )

        for key in ToolExecutor.allowedPreferenceKeys.sorted() {
            XCTAssertTrue(
                description.contains(key),
                "tools/list must name the allowed key '\(key)': \(description)"
            )
        }
        XCTAssertTrue(
            description.contains("rejected, not ignored"),
            "the client must learn that a rejected key is an error, not a silent no-op"
        )
        XCTAssertTrue(
            description.contains("compactMenuBar"),
            "get_settings reports the compact preference under another name: \(description)"
        )
        XCTAssertTrue(
            description.contains("mutation policy"),
            "mcpMode is the server's own policy, not an app preference: \(description)"
        )
    }

    /// The allowlist is defined once and every layer reads that one definition.
    ///
    /// Three written-out copies of a security-relevant list is three chances for
    /// the surface to contradict itself, and the bad case is specific: a key the
    /// executor accepts, refused further down with a message naming a key the
    /// client was just told was allowed. So the catalog's description, the
    /// executor's refusal and the provider's own refusal are all built from
    /// `ToolExecutor.allowedPreferenceKeys`, and this pins that they are.
    func testEveryLayerNamesTheSameAllowlist() async throws {
        let expected = ToolExecutor.allowedPreferenceKeys.sorted().joined(separator: ", ")
        let refusal = "Preference 'retention' cannot be changed via MCP. Allowed: \(expected)."

        // The catalog advertises exactly those keys — so a client cannot be told
        // a key is allowed by one surface and refused by another.
        let description = try XCTUnwrap(
            ToolExecutor.catalog.first { $0.name == "set_preference" }?.description
        )
        XCTAssertTrue(
            description.contains("Allowed keys: \(expected)."),
            "the catalog must advertise the executor's own list: \(description)"
        )

        let stub = StubProvider()
        let tool = try makeExecutor(provider: stub, mode: .allowSession, appRunning: true)
        let refused = await tool.execute(
            name: "set_preference", arguments: ["key": "retention", "value": "days30"]
        )
        XCTAssertTrue(refused.isError)
        XCTAssertEqual(refused.text, refusal)

        // And the provider, reached directly: two lists that had drifted apart
        // would fail exactly here.
        let suite = "dev.portmaster.mcp.tests.\(name).\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let provider = OnDemandProvider(preferencesDefaults: defaults, appRunning: { false })
        do {
            try await provider.setPreference(key: "retention", value: "days30")
            XCTFail("Only allowlisted preferences may be changed")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, refusal)
        }
    }

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
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

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

        let entry = try XCTUnwrap(
            auditEntries(in: dir).first { $0["tool"] as? String == "set_preference" }
        )
        XCTAssertEqual(
            entry["outcome"] as? String, "allowed",
            "a preference change that took effect must be on the record as allowed"
        )
    }

    /// `mcpMode` is the key that could widen the gate, so it is the one that most
    /// needs to be proven gated: a client that can set it while mutations are off
    /// owns the permission decision for every later call.
    func testSetPreferenceCannotWidenItsOwnGate() async throws {
        let stub = StubProvider()
        let settingsDirectory = try makeTemporaryDirectory(prefix: "\(name)-settings")
        try MCPSettings(mode: .off).save(directory: settingsDirectory)
        let tool = try makeExecutor(
            provider: stub, mode: .off, appRunning: true,
            settingsDirectory: settingsDirectory
        )

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "mcpMode", "value": "allowSession"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(stub.count(of: "setPreference"), 0)
        XCTAssertEqual(
            MCPSettings.load(directory: settingsDirectory).mode, .off,
            "the stored mode must be untouched: a granted mutation policy is something "
                + "the user does in the app, not something a client grants itself"
        )
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

    // MARK: handoff_context

    /// The whole point of the tool: the session the client named is the session that
    /// was handed off, and the success line says where the brief went. A handoff audit
    /// that said only "allowed" would not tell a reader which conversation moved.
    func testHandoffContextPassesBothArgumentsAndNotesTheBrief() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )
        let sessionID = UUID()

        let outcome = await tool.execute(
            name: "handoff_context",
            arguments: ["session_id": sessionID.uuidString, "target": "claude"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(stub.lastHandoff?.sessionID, sessionID)
        XCTAssertEqual(stub.lastHandoff?.target, "claude")

        let payload = try jsonObject(outcome.text)
        XCTAssertEqual(payload["briefPath"] as? String, "/tmp/brief.md")
        XCTAssertEqual(payload["citedLines"] as? [Int], [1, 2, 3])
        XCTAssertEqual(payload["launchedPID"] as? Int, 4242)
        XCTAssertEqual(payload["target"] as? String, "claude")

        let entries = try auditEntries(in: dir)
        XCTAssertEqual(entries.count, 1, "exactly one line per mutation attempt")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["tool"] as? String, "handoff_context")
        XCTAssertEqual(entry["outcome"] as? String, "allowed")
        let reason = try XCTUnwrap(entry["reason"] as? String)
        XCTAssertTrue(reason.hasPrefix("brief=/tmp/brief.md"), reason)
        XCTAssertTrue(reason.contains("lines=1,2,3"), reason)
    }

    /// The gate reaches this tool the way it reaches every mutation, and a refusal
    /// never touches the provider — a launch is the most expensive thing a mutation
    /// can do here, so the pre-provider rule matters most for it.
    func testHandoffContextIsDeniedByTheGateBeforeTheProviderRuns() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: true, directory: dir)

        let outcome = await tool.execute(
            name: "handoff_context",
            arguments: ["session_id": UUID().uuidString, "target": "claude"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(stub.count(of: "handoffContext"), 0)
        let entries = try auditEntries(in: dir)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["tool"] as? String, "handoff_context")
        XCTAssertEqual(entry["outcome"] as? String, "denied")
        XCTAssertEqual(
            entry["reason"] as? String, "MCP mutations are disabled in Portmaster settings."
        )
    }

    /// A session id that is not an id is refused inside dispatch — after the gate,
    /// like every other format check (`requireWindow`, `price`) — audited `failed`
    /// with the reason, and the provider never runs.
    func testHandoffContextRefusesASessionIdThatIsNotOneWithoutTouchingTheProvider()
        async throws
    {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(
            name: "handoff_context",
            arguments: ["session_id": "not-a-uuid", "target": "claude"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(stub.count(of: "handoffContext"), 0)
        let entry = try XCTUnwrap(auditEntries(in: dir).first)
        XCTAssertEqual(entry["outcome"] as? String, "failed")
        XCTAssertEqual(
            entry["reason"] as? String, "Invalid session_id: not an id Portmaster recorded."
        )
    }

    /// The note rides only payloads that carry one: an ordinary success still audits
    /// with no reason, so a reader knows a non-nil `reason` is an exception worth
    /// reading. The success audit changed for everyone in this task; this pins that
    /// it changed for no one else.
    func testAnOrdinarySuccessfulMutationStillAuditsWithNoReason() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "temperatureUnit", "value": "celsius"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        let entry = try XCTUnwrap(auditEntries(in: dir).first)
        XCTAssertEqual(entry["outcome"] as? String, "allowed")
        XCTAssertNil(entry["reason"] as? String)
    }
}

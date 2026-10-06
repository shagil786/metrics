// MCPPreferencesStoreTests: what a preference change has to pass before anything writes it.
//
// `PreferencesStore.validate` is the check the confirmation window runs before it will
// put a preference change to a person, and the check `LiveDataProvider.setPreference`
// runs before the app writes one. It is therefore the gate every `set_preference`
// goes through **except** `mcpMode`, which `ToolExecutor` intercepts for the MCP
// server's own policy — and that exception used to make `mcpMode` impossible to
// confirm: the window asked `validate`, `validate` had no case for it, and refused a
// key while listing that same key as allowed.
//
// So the property here is simple to state and was quietly false: **every key
// `ToolExecutor.allowedPreferenceKeys` advertises must survive `validate`.** A second
// copy of the allowlist in a test is the point — the drift this file exists to catch
// is exactly the two lists disagreeing.

import PortmasterMCP
import XCTest

final class MCPPreferencesStoreTests: XCTestCase {

    /// Every advertised key must reach a real preference or a real policy.
    ///
    /// Asserted against the executor's own list rather than a mirrored one, so a key
    /// added to the catalog is covered here the day it is added rather than the day
    /// somebody remembers this file.
    func testEveryAdvertisedKeyIsValidatable() throws {
        for key in ToolExecutor.allowedPreferenceKeys.sorted() {
            XCTAssertNoThrow(
                try PreferencesStore.validate(key: key, value: try Self.someValidValue(for: key)),
                "the confirmation window validates through this, so a key it refuses "
                    + "can never be confirmed: \(key)"
            )
        }
    }

    /// `mcpMode` is a mutation policy, not a temperature, so it has its own case.
    ///
    /// Pinned by name and by shape: a key with no case here falls into the `default:`
    /// branch, and that branch's message *lists the allowlist*, so the failure mode is
    /// a refusal that names `mcpMode` as allowed — self-contradictory, and exactly what
    /// the end-to-end script recorded.
    func testTheMCPModeIsValidatedAsAPolicyRatherThanRefused() throws {
        XCTAssertNoThrow(
            try PreferencesStore.validate(key: "mcpMode", value: "confirmEach"),
            "mcpMode is the MCP server's own mutation policy and must validate"
        )
        for mode in MCPMutationMode.allCases {
            XCTAssertNoThrow(try PreferencesStore.validate(key: "mcpMode", value: mode.rawValue))
        }

        do {
            try PreferencesStore.validate(key: "mcpMode", value: "allowSessionn")
            XCTFail("a mode that is not one of the three must be refused")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains("Invalid mcpMode"), error.message
            )
            // The refusal must not name the key it is refusing as allowed.
            let advertised = ToolExecutor.allowedPreferenceKeys.sorted().joined(separator: ", ")
            XCTAssertFalse(
                error.message.contains(advertised),
                "a refusal that quotes the allowlist must not be quoting the key it is "
                    + "refusing: \(error.message)"
            )
        } catch {
            XCTFail("threw \(error) rather than the tool error the client is told about")
        }
    }

    /// A key outside the allowlist still gets the one refusal, and it is the executor's
    /// own list rather than a second one.
    func testAKeyOutsideTheAllowlistIsRefusedWithTheExecutorsList() {
        do {
            try PreferencesStore.validate(key: "retention", value: "days30")
            XCTFail("only allowlisted keys may be changed via MCP")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error.message,
                "Preference 'retention' cannot be changed via MCP. Allowed: "
                    + ToolExecutor.allowedPreferenceKeysDescription() + "."
            )
        } catch {
            XCTFail("threw \(error) rather than the tool error the client is told about")
        }
    }

    /// A key nobody may write, offered with a value nobody may write, is refused on the
    /// key — so the sentence names the thing the caller got wrong.
    func testAnInvalidValueIsRefusedOnTheKey() {
        do {
            try PreferencesStore.validate(key: "temperatureUnit", value: "kelvin")
            XCTFail("kelvin is not a temperature unit this app can display")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, "Invalid value 'kelvin' for 'temperatureUnit'.")
        } catch {
            XCTFail("threw \(error) rather than the tool error the client is told about")
        }
    }

    /// One legal value per key, so the loop above is testing reachability rather than
    /// accidentally passing because a value happened to be accepted.
    private static func someValidValue(for key: String) throws -> String {
        switch key {
        case "temperatureUnit": return "celsius"
        case "networkUnit": return "bytes"
        case "cpuScale": return "perMac"
        case "temperatureSource": return "hottest"
        case "compact": return "true"
        case "mcpMode": return "off"
        default:
            throw XCTSkip("no sample value for \(key); add one rather than weakening the loop")
        }
    }
}
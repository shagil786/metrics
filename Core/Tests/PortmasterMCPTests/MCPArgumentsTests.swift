// MCPArgumentsTests and the catalog's wire shape.
//
// The coercion is the one place where the server interprets something a caller
// sent rather than passing it on, so its edge cases are worth pinning: a `true`
// that arrives as "1" would silently read as `false` for `quit_app`, and a JSON
// `null` that arrives as the string "null" would be a value the user never sent.

import Foundation
import PortmasterMCP
import XCTest

final class MCPArgumentsTests: XCTestCase {

    func testMissingArgumentsAreAnEmptyMap() {
        XCTAssertEqual(MCPArguments.strings(fromJSON: nil), [:])
        XCTAssertEqual(MCPArguments.strings(fromJSON: [:]), [:])
    }

    func testStringsPassThroughUnchanged() throws {
        let arguments = try jsonObject(#"{"metric":"cpu","id":"app:Somewhere"}"#)
        XCTAssertEqual(
            MCPArguments.strings(fromJSON: arguments), ["metric": "cpu", "id": "app:Somewhere"]
        )
    }

    func testBooleansArriveAsTrueAndFalseNotAsNumbers() throws {
        // The executor reads `force` as the string "true". A boolean that
        // round-tripped through a number would come back as "1" and read as
        // false, so a `quit_app` would send a polite signal the user did not ask
        // for.
        let arguments = try jsonObject(#"{"force":true,"other":false}"#)
        XCTAssertEqual(MCPArguments.strings(fromJSON: arguments), ["force": "true", "other": "false"])
    }

    func testIntegralNumbersLoseTheirPointZero() throws {
        // `limit: 10` and `limit: 10.0` are the same argument to a tool that
        // parses a number.
        let arguments = try jsonObject(#"{"a":10,"b":10.0,"c":-3}"#)
        XCTAssertEqual(MCPArguments.strings(fromJSON: arguments), ["a": "10", "b": "10", "c": "-3"])
    }

    func testFractionalNumbersKeepTheirFraction() throws {
        let arguments = try jsonObject(#"{"ratio":0.25}"#)
        XCTAssertEqual(MCPArguments.strings(fromJSON: arguments), ["ratio": "0.25"])
    }

    func testJSONNullIsAnAbsentArgumentNotTheStringNull() throws {
        // Absent is what a missing argument looks like to the executor, so the
        // tool reports the argument by name. The string "null" would instead be
        // a value the caller never sent.
        let arguments = try jsonObject(#"{"metric":null}"#)
        XCTAssertEqual(MCPArguments.strings(fromJSON: arguments), [:])
    }

    func testContainersArriveAsJSONTextRatherThanBeingGuessedAt() throws {
        let arguments = try jsonObject(#"{"metric":["cpu","memory"]}"#)
        let coerced = MCPArguments.strings(fromJSON: arguments)
        // Kept, not dropped: no tool reads one, so it fails on its own argument
        // error, which names the tool. Dropping it would make a bad call look
        // like a call with no arguments at all.
        XCTAssertEqual(coerced["metric"], #"["cpu","memory"]"#)
    }

    // MARK: The catalog on the wire

    func testCatalogListsEveryToolExactlyOnce() {
        let names = MCPCatalog.tools().map(\.name)
        XCTAssertEqual(names.sorted(), ToolExecutor.catalog.map(\.name).sorted())
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testSchemaDeclaresRequiredArgumentsAndMarksMutationsDestructive() throws {
        let encoded = String(decoding: try JSONEncoder().encode(MCPCatalog.tools()), as: UTF8.self)
        let byName = Dictionary(
            uniqueKeysWithValues: try jsonArray(encoded).compactMap { tool in
                tool["name"].flatMap { $0 as? String }.map { ($0, tool) }
            }
        )

        let topApps = try XCTUnwrap(byName["get_top_apps"])
        let topAppsSchema = try XCTUnwrap(topApps["inputSchema"] as? [String: Any])
        XCTAssertEqual(topAppsSchema["type"] as? String, "object")
        XCTAssertEqual(topAppsSchema["required"] as? [String], ["metric"])
        let annotations = try XCTUnwrap(topApps["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertNil(annotations["destructiveHint"], "a read is not destructive")

        let quitApp = try XCTUnwrap(byName["quit_app"])
        let quitSchema = try XCTUnwrap(quitApp["inputSchema"] as? [String: Any])
        XCTAssertEqual(quitSchema["required"] as? [String], ["id"])
        let mutationAnnotations = try XCTUnwrap(quitApp["annotations"] as? [String: Any])
        XCTAssertEqual(mutationAnnotations["readOnlyHint"] as? Bool, false)
        XCTAssertEqual(mutationAnnotations["destructiveHint"] as? Bool, true)

        // A tool with no arguments declares no `required` at all rather than an
        // empty list, which is what a client reads as "nothing required".
        let overview = try XCTUnwrap(byName["get_system_overview"])
        let overviewSchema = try XCTUnwrap(overview["inputSchema"] as? [String: Any])
        XCTAssertNil(overviewSchema["required"])
    }
}
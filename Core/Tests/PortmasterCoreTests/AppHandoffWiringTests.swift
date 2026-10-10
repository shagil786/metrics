// Core/Tests/PortmasterCoreTests/AppHandoffWiringTests.swift
// The App half of the handoff wiring, asserted from source — there is no App
// test target (`project.yml` declares the app and the Core package only), so
// the mechanism is the one `AppAgentSourceWiringTests` established: strip
// comments, fail loudly when a file is missing, pin each marker's occurrence
// count so a rename fails the claim instead of passing over nothing.
//
// What this proves: where the code is. It does not prove the sheet opens or a
// handoff runs — those are coordinator/MCP tests in PortmasterMCPTests.

import Foundation
import XCTest

final class AppHandoffWiringTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        let text = try? String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(
            text.map(Self.withoutComments),
            "\(relativePath) was not found at \(url.path) — the scan would pass over nothing",
            file: file, line: line
        )
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testTheSessionsCardRendersOneChainLineOnTheHeadOnly() throws {
        let overview = try source("App/OverviewView.swift")
        XCTAssertEqual(
            occurrences("chain.renderedLine", in: overview), 1,
            "the chain line has exactly one render site"
        )
        XCTAssertEqual(
            occurrences("session.handedOffFrom == nil", in: overview), 1,
            "rendered exactly where the head is identified — a second site would duplicate the report"
        )
        XCTAssertTrue(
            occurrences("struct SessionLine", in: overview) >= 1,
            "the row the chain line hangs on must exist"
        )
    }

    /// Comments stripped first, so a doc comment mentioning the marker cannot
    /// satisfy its own claim.
    private static func withoutComments(_ source: String) -> String {
        var characters = Array(source)
        var index = 0
        var inBlock = false
        while index < characters.count {
            let character = characters[index]
            if inBlock {
                if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    characters[index] = " "
                    characters[index + 1] = " "
                    inBlock = false
                    index += 2
                    continue
                }
                if !character.isNewline { characters[index] = " " }
                index += 1
                continue
            }
            if character == "/", index + 1 < characters.count {
                if characters[index + 1] == "*" {
                    characters[index + 1] = " "
                    inBlock = true
                    index += 1
                    continue
                }
                if characters[index + 1] == "/" {
                    // A line comment runs to the newline, which is kept so the next line
                    // starts where it would have.
                    while index < characters.count, !characters[index].isNewline {
                        characters[index] = " "
                        index += 1
                    }
                    continue
                }
            }
            index += 1
        }
        return String(characters)
    }

    // MARK: The affordance

    /// The strip's button opens one sheet, and the sheet offers both ways out the
    /// spec chose — the command the agent must run itself, and the handoff — behind
    /// the mode mirror and the kill switch, from the session the notice is about.
    func testTheStripOffersAnActionAndTheSheetOffersBothWaysOut() throws {
        let overview = try source("App/OverviewView.swift")

        XCTAssertTrue(
            overview.contains("struct PressureActionsSheet"),
            "the sheet the strip opens must exist beside the strip"
        )
        XCTAssertTrue(
            overview.contains(".sheet(isPresented:"),
            "the strip presents its actions as a sheet"
        )
        XCTAssertTrue(
            overview.contains("/compact"),
            "the sheet offers the exact command, because Portmaster cannot run it"
        )
        XCTAssertTrue(
            overview.contains("HandoffTargets.load"),
            "the sheet lists the configured receiving agents, not a hard-coded pair"
        )
        XCTAssertTrue(
            overview.contains("notice.sessionID"),
            "the handoff is of the session the notice is about"
        )
        XCTAssertTrue(
            overview.contains("AppDelegate.shared?.mcpHost.mode"),
            "the sheet mirrors the host's mode exactly as Settings does (ruling 16)"
        )
        XCTAssertTrue(
            overview.contains("contextHandoffsEnabled"),
            "the sheet respects the kill switch"
        )
    }

    /// Both surfaces reach one coordinator factory, and the app's own path writes its
    /// own audit line — the two claims only a whole-file scan can hold still.
    func testThePressGoesThroughOneCoordinatorAndAuditsItsOwnOrigin() throws {
        let appModel = try source("App/AppModel.swift")
        XCTAssertTrue(
            appModel.contains("func performHandoff(sessionID: UUID, target: String)"),
            "the app's handoff entry point must exist by this name"
        )
        XCTAssertTrue(
            appModel.contains("HandoffCoordinator.live(store:"),
            "both surfaces build the coordinator through one factory"
        )
        XCTAssertTrue(
            appModel.contains("recordAppHandoff"),
            "the app path writes its own audit line (ruling 10)"
        )

        let controller = try source("App/MCPHostController.swift")
        XCTAssertTrue(
            controller.contains("handoff: { sessionID, target in"),
            "the socket path reaches the same coordinator through the provider seam"
        )

        let coordinator = try source("Core/Sources/PortmasterMCP/HandoffCoordinator.swift")
        XCTAssertTrue(
            coordinator.contains(#""origin": "app""#),
            "the app's audit line carries origin, so the two surfaces are tellable apart"
        )
    }

    /// The kill switch has one authority (the coordinator) and one switch (Settings),
    /// named after what it switches.
    func testTheKillSwitchHasAToggleInTheGeneralSettings() throws {
        let settings = try source("App/SettingsView.swift")
        XCTAssertTrue(
            settings.contains("contextHandoffsEnabled"),
            "the kill switch must be settable where the other preferences live"
        )
        XCTAssertTrue(
            settings.contains("Agent handoffs"),
            "the toggle is named after what it switches"
        )
    }
}

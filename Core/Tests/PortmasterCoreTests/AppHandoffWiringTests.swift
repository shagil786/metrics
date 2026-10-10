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
}

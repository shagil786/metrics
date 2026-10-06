// MCPSettingsChromeTests: the page has no words of its own.
//
// `App/MCPSettingsTab.swift` is the one part of the MCP settings feature with no test
// target behind it — the app scheme builds and nothing runs. Everything it *decides* was
// moved into `MCPSettingsCopy` (sentences) and `MCPInstallCommand` (paths) precisely so it
// would have none, and this file is what makes that true rather than merely intended.
//
// The review that asked for it was right about the size of the gap: "the token is never on
// this page" was asserted over sixteen library strings, while eleven of the strings the
// page actually renders — the headings, the button labels, the "Copied" confirmation, the
// no-delegate fallback — were literals in the view that nothing inspected. A property
// asserted over part of a page is not a property of the page.
//
// So this reads the page's source and fails on any string literal that is not one the copy
// module owns. Two ways that can pass for the wrong reason are also checked: the file
// actually being where it is looked for, and `everyString` actually containing every
// literal the view does use.
//
// **Two files, not one.** `MCPSettingsTab.swift` is the page, but not the whole of it:
// `SettingsView.mcpTab` renders the no-host fallback itself, so a literal written there
// would have been exactly as invisible to the token test as one in the page — and it is
// *reachable* without the host, which makes it the more likely of the two to be edited.
// So `SettingsView.swift` is scanned too, but only its MCP region: the rest of that file
// is other settings pages, none of whose words this property is about.
//
// **What this does not do.** It is a source scan, not a render. It proves the page cannot
// *introduce* a string that the token test has not seen; it does not prove the page looks
// right, that a button does what it says, or that the copy and the layout agree about
// where something appears. Those remain build-only and are listed as such in the report.

import Foundation
@testable import PortmasterMCP
import XCTest

final class MCPSettingsChromeTests: XCTestCase {

    /// The repository root, four levels up from the test file: PortmasterMCPTests →
    /// Tests → Core → the repository root, which is where `App/` lives. The package root
    /// alone would be three, and `App/` is not inside the package.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PortmasterMCPTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Core
        .deletingLastPathComponent()  // repository root

    /// The page's own source, read once.
    private static let viewSource: String? = try? String(
        contentsOf: repositoryRoot.appendingPathComponent("App/MCPSettingsTab.swift"),
        encoding: .utf8
    )

    /// The MCP region of `SettingsView.swift`: from the marker comment to the next
    /// declaration, which is where the page and its fallback live.
    ///
    /// **Bounded on both ends rather than scanned whole, and deliberately.** The whole
    /// file is four other settings pages whose every string belongs to some other copy
    /// module; including them would make this test a red test over code it has nothing
    /// to say about, and the fix for that red test would be to delete the assertion.
    /// The bounds are markers rather than line numbers so that adding a line inside the
    /// region is invisible to this file and moving the region is not.
    static let settingsRegionStart = "// MARK: MCP"
    static let settingsRegionEnd = "private func bullet("

    private static let settingsRegion: String? = {
        guard let whole = try? String(
            contentsOf: repositoryRoot.appendingPathComponent("App/SettingsView.swift"),
            encoding: .utf8
        ) else { return nil }
        return region(in: whole, from: settingsRegionStart, to: settingsRegionEnd)
    }()

    /// The slice of `source` between the first line containing `start` and the first
    /// line after it containing `end`, or `nil` when either is absent.
    ///
    /// `nil` rather than a silent empty slice: a missing marker must fail the test that
    /// depends on it, because "the scan found no literals" is the pass-for-the-wrong-
    /// reason outcome the scanner test exists to rule out.
    static func region(in source: String, from start: String, to end: String) -> String? {
        guard let startRange = source.range(of: start) else { return nil }
        let remainder = source[startRange.upperBound...]
        guard let endRange = remainder.range(of: end) else { return nil }
        return String(remainder[..<endRange.lowerBound])
    }

    /// Literals the view may hold without the token test having seen them: SF Symbol
    /// names, which name a drawing rather than say anything to a person.
    ///
    /// Named rather than pattern-matched (`looks like an identifier`) so that adding one is
    /// a deliberate, visible act — a pattern would let any identifier-shaped string through,
    /// which is exactly the class of thing worth not doing.
    private static let nonUserFacingLiterals: Set<String> = [
        "checkmark.circle"
    ]

    /// Every string literal in the view, ignoring comments.
    ///
    /// Comments are stripped first because a doc comment discusses the strings it forbids
    /// — the sentence "the token is never on this page" is quoted right above the property
    /// that test enforces, so a naive scan reads the rule as a violation of it. Line
    /// comments and block comments both go; nothing is left that the page could render.
    private static func literals(in source: String) -> [String] {
        var found: [String] = []
        let characters = Array(withoutComments(source))
        var index = 0
        while index < characters.count {
            guard characters[index] == "\"" else {
                index += 1
                continue
            }
            var literal = ""
            index += 1
            while index < characters.count, characters[index] != "\"" {
                // A backslash escapes the next character, so `\"` does not end the
                // literal. Skipping it keeps the scan from splitting one string into two
                // halves it would then compare wrongly.
                if characters[index] == "\\", index + 1 < characters.count {
                    literal.append(characters[index + 1])
                    index += 2
                    continue
                }
                literal.append(characters[index])
                index += 1
            }
            index += 1
            found.append(literal)
        }
        return found.filter { !nonUserFacingLiterals.contains($0) }
    }

    /// The source with `// …` and `/* … */` replaced by spaces, so offsets still line up.
    ///
    /// Replaced rather than deleted because a deleted comment would join the code on either
    /// side of it into something else — two string literals becoming one, which the scan
    /// would then misread.
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

    /// The page's own words must all be the copy module's.
    ///
    /// This is the enforceable form of "the token is never on this page". A heading added
    /// to the view as a literal is now a red test rather than an unnoticed eleventh
    /// uncovered string — and, since the token test walks `everyString`, the only way to
    /// get through is to route the string past a test that checks it.
    func testThePageHasNoStringLiteralsOfItsOwn() throws {
        let known = Set(MCPSettingsCopy.everyString)
        var foreign: [String] = []

        let view = try XCTUnwrap(
            Self.viewSource, "App/MCPSettingsTab.swift was not found next to the package"
        )
        foreign += Self.literals(in: view).filter { !known.contains($0) }

        // The fallback the page cannot render without, rendered by `SettingsView` itself.
        let region = try XCTUnwrap(
            Self.settingsRegion,
            "the MCP region of App/SettingsView.swift was not found between "
                + "'\(Self.settingsRegionStart)' and '\(Self.settingsRegionEnd)'"
        )
        foreign += Self.literals(in: region).filter { !known.contains($0) }

        XCTAssertEqual(
            foreign, [],
            "these strings are rendered by the page but asserted by no test — "
                + "move them into MCPSettingsCopy"
        )
    }

    /// The region this file scans is a region, not the file: a slice taken by two
    /// markers has to actually contain the fallback, or the scan above covers nothing
    /// and reports success.
    func testTheSettingsRegionIsFoundAndIsNotTheWholeFile() throws {
        let region = try XCTUnwrap(Self.settingsRegion)
        XCTAssertTrue(
            region.contains("mcpTab"),
            "the slice must include the MCP page's fallback: \(region.prefix(200))"
        )
        XCTAssertFalse(
            region.contains("private func bullet"),
            "the slice must stop before the next declaration, or it is a whole file"
        )
        let whole = try XCTUnwrap(
            try? String(
                contentsOf: Self.repositoryRoot.appendingPathComponent("App/SettingsView.swift"),
                encoding: .utf8
            )
        )
        XCTAssertLessThan(
            region.count, whole.count,
            "the scanned region is a small part of the file, not all of it"
        )
    }

    /// The scanner itself, on input known to contain literals — because a scan that finds
    /// nothing passes the test above for the wrong reason. The view is *supposed* to hold no
    /// literals of its own, so "the scan found nothing" is the correct outcome there and a
    /// useless signal; here it is a bug being looked for.
    func testTheScannerFindsLiteralsIgnoresCommentsAndSkipsEscapes() {
        // Assembled rather than written as a Swift multiline literal, so the escapes under
        // test are the ones in the fixture and not a second layer of Swift's own.
        let escapedQuote = "\\" + "\""
        let source = [
            "// a comment with \"rendered words\" in it",
            "/* a block comment with \"more words\" too */",
            "let a = \"a real one\"",
            "let b = \"one with " + escapedQuote + " an escaped quote\"",
            "let c = \"checkmark.circle\"",
        ].joined(separator: "\n")
        XCTAssertEqual(
            Self.literals(in: source),
            // Unescaped, because that is the string Swift would render — comparing against
            // the source spelling would make this about Swift's escaping rather than the
            // scanner's quote handling.
            ["a real one", "one with \" an escaped quote"],
            "comments are not rendered, and an escaped quote does not end a literal"
        )
    }

    /// The view holding no literals is the intended state, so this asserts the count
    /// explicitly rather than letting an empty result pass by accident — and checks that the
    /// inventory is strictly larger, which is what says the view is drawing from the copy
    /// module rather than that nothing is being drawn.
    func testTheViewDrawsItsWordsFromTheInventory() throws {
        let source = try XCTUnwrap(
            Self.viewSource, "App/MCPSettingsTab.swift was not found next to the package"
        )
        XCTAssertEqual(
            Self.literals(in: source), [],
            "every string the page renders comes from MCPSettingsCopy"
        )
        XCTAssertGreaterThan(
            Set(MCPSettingsCopy.everyString).count, 25,
            "the view holds no literals, so the inventory is what the page is drawn from"
        )
    }

    /// The inventory is what the token test walks, so a page string that never reaches
    /// `everyString` is a string no test sees. The eleven literals this replaces — the
    /// headings, the two buttons, the copied label, the fallback — are named here so their
    /// removal from the view cannot pass silently.
    func testThePagesOwnStringsAreAllInTheInventory() {
        let inventory = Set(MCPSettingsCopy.everyString)
        let pageStrings = [
            MCPSettingsCopy.Chrome.policyHeading,
            MCPSettingsCopy.Chrome.modePickerLabel,
            MCPSettingsCopy.Chrome.modeHint,
            MCPSettingsCopy.Chrome.statusHeading,
            MCPSettingsCopy.Chrome.auditLogHeading,
            MCPSettingsCopy.Chrome.installHeading,
            MCPSettingsCopy.Chrome.clientsHeading,
            MCPSettingsCopy.Chrome.revealButton,
            MCPSettingsCopy.Chrome.copyButton,
            MCPSettingsCopy.Chrome.copiedLabel,
            MCPSettingsCopy.Chrome.noHostAvailable,
        ]
        XCTAssertEqual(pageStrings.count, 11, "one per literal this replaces")
        for string in pageStrings {
            XCTAssertTrue(inventory.contains(string), "not covered by any test: \(string)")
        }
    }

    /// The headings are what a person navigates by, so none of them is empty and none is
    /// two of another — a duplicated heading is a page whose two sections cannot be told
    /// apart when somebody reports "the MCP page is broken".
    func testNoHeadingIsEmptyOrShared() {
        let headings = [
            MCPSettingsCopy.Chrome.policyHeading,
            MCPSettingsCopy.Chrome.statusHeading,
            MCPSettingsCopy.Chrome.auditLogHeading,
            MCPSettingsCopy.Chrome.installHeading,
            MCPSettingsCopy.Chrome.clientsHeading,
        ]
        for heading in headings {
            XCTAssertFalse(heading.isEmpty, "an empty heading is not a heading")
        }
        XCTAssertEqual(Set(headings).count, headings.count, "\(headings)")
    }

    /// The button labels name what they do. "OK" on a control that copies a command to the
    /// clipboard is a button nobody can choose correctly, and the two labels must be
    /// distinguishable from each other in the same frame.
    func testTheButtonsSayWhatTheyDo() {
        XCTAssertEqual(MCPSettingsCopy.Chrome.copyButton, "Copy install command")
        XCTAssertEqual(MCPSettingsCopy.Chrome.revealButton, "Reveal in Finder")
        XCTAssertNotEqual(
            MCPSettingsCopy.Chrome.copyButton, MCPSettingsCopy.Chrome.revealButton
        )
        XCTAssertFalse(
            MCPSettingsCopy.Chrome.copiedLabel.isEmpty,
            "the confirmation after a copy needs words, not just an icon"
        )
    }
}

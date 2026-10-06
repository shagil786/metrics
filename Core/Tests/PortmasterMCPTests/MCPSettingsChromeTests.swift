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
// So this reads the view's source and fails on any string literal that is not one the copy
// module owns. Two ways that can pass for the wrong reason are also checked: the file
// actually being where it is looked for, and `everyString` actually containing every
// literal the view does use.
//
// **What this does not do.** It is a source scan, not a render. It proves the page cannot
// *introduce* a string that the token test has not seen; it does not prove the page looks
// right, that a button does what it says, or that the copy and the layout agree about
// where something appears. Those remain build-only and are listed as such in the report.

import Foundation
@testable import PortmasterMCP
import XCTest

final class MCPSettingsChromeTests: XCTestCase {

    /// The page's source, read once. Absent the file the scan is skipped rather than
    /// failed — a library test that cannot find an app file must not be a red test on a
    /// machine where the app is checked out elsewhere.
    private static let source: String? = {
        // Four levels up from the test file: PortmasterMCPTests → Tests → Core → the
        // repository root, which is where `App/` lives. The package root alone would be
        // three, and `App/` is not inside the package.
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PortmasterMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("App/MCPSettingsTab.swift")
        return try? String(contentsOf: view, encoding: .utf8)
    }()

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
        let source = try XCTUnwrap(
            Self.source, "App/MCPSettingsTab.swift was not found next to the package"
        )
        let known = Set(MCPSettingsCopy.everyString)
        let foreign = Self.literals(in: source).filter { !known.contains($0) }
        XCTAssertEqual(
            foreign, [],
            "these strings are rendered by the page but asserted by no test — "
                + "move them into MCPSettingsCopy"
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
            Self.source, "App/MCPSettingsTab.swift was not found next to the package"
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

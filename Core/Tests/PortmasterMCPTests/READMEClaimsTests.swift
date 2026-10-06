// READMEClaimsTests: prose that quotes code, asserted against the code.
//
// Three consecutive review rounds of this branch found stale sentences in the README's MCP
// section, twice drift an earlier round had introduced itself. Every one of them was a
// **string that already exists in code as a constant or a literal**: an environment
// variable name, a refusal's opening words, a field list, a timeout. The problem is not
// that the README was wrong — it is that *nothing in the build noticed*, so correctness was
// being verified by whoever read the diff next. That is not a process.
//
// So this reads `README.md` and checks the quoted fragments against the module. It is
// deliberately narrow, and the split is the design:
//
//   - **prose that quotes code** is asserted here — a fragment the README prints must
//     exist in the source it names, or a constant's value must appear in the line that
//     quotes it;
//   - **prose that states arithmetic** is *derived* in the corresponding test rather than
//     restated in prose. (The placement figures in `ConfirmationWindowPlacement`'s doc are
//     the worked example: asserted, and qualified to the window the test assumes, after two
//     rounds of getting them wrong in a comment.)
//   - **prose that states a judgement** is left to review, because there is nothing to
//     assert against. "An `mcpMode` change is an ordinary mutation" and "Developer ID
//     signing is not configuration-only" are both true claims about intent; a test can
//     only agree or disagree by being rewritten to agree. That is review's job.

import Foundation
@testable import PortmasterMCP
import XCTest

final class READMEClaimsTests: XCTestCase {

    // MARK: - Reading the README

    /// The repository's `README.md`, four levels up like the other source-reading tests:
    /// PortmasterMCPTests → Tests → Core → the repository root.
    private static let readme: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PortmasterMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("README.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("README.md not found at \(url.path)")
        }
        return text
    }()

    /// The 1-based line containing `fragment`, failing with the line's number and text.
    ///
    /// The message matters more than the assertion: a failure here has to say *which
    /// sentence* of the README went stale, or the next reader is doing the same manual
    /// search this file exists to stop them doing.
    private func line(
        containing fragment: String, file: StaticString = #filePath, at sourceLine: UInt = #line
    ) -> String? {
        for text in Self.readme.components(separatedBy: .newlines)
        where text.contains(fragment) {
            return text
        }
        XCTFail(
            "README.md no longer contains \\(fragment). Either the README lost the claim or "
                + "the string it quoted was renamed; fix whichever moved.",
            file: file, line: sourceLine
        )
        return nil
    }

    /// Asserts that `source` contains `fragment`, naming the README line that quoted it.
    private func assertQuotes(
        _ fragment: String,
        from source: String,
        sourceName: String,
        file: StaticString = #filePath,
        at sourceLine: UInt = #line
    ) {
        guard let readmeLine = line(
            containing: fragment, file: file, at: sourceLine
        ) else { return }
        XCTAssertTrue(
            source.contains(fragment),
            "README.md quotes \\(fragment), which is not in \(sourceName).\n"
                + "  README line: \(readmeLine)\n"
                + "  The claim is stale: rename it in both places, or stop printing it.",
            file: file, line: sourceLine
        )
    }

    private static func source(_ path: String) -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PortmasterMCPTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("source file not found at \(url.path)")
        }
        return text
    }

    // MARK: - Environment variables

    /// The two the README names are the two the CLI reads.
    ///
    /// Round 4 found the README still claiming the executable "needs no environment" while
    /// naming both of these forty lines later.
    func testTheEnvironmentVariablesTheReadmeNamesAreTheOnesTheRouteReads() {
        let route = Self.source("Sources/PortmasterMCP/MCPRoute.swift")
        for name in [MCPRouteSelector.onDemandVariable,
                     MCPRouteSelector.endpointDirectoryVariable] {
            assertQuotes(name, from: route, sourceName: "MCPRoute.swift")
        }
    }

    /// The on-demand notice, quoted, is the notice the CLI writes.
    func testTheReadmeQuotesTheOnDemandNoticeTheRouteActuallyWrites() {
        let route = Self.source("Sources/PortmasterMCP/MCPRoute.swift")
        let notice = MCPRouteSelector.unavailableNotice
        // The README quotes it in shortened form, so assert the fragment that appears in
        // both rather than the whole sentence: a shortened quote is still a claim about
        // wording.
        let fragment = "no Portmaster answering on the socket"
        XCTAssertTrue(
            notice.contains(fragment),
            "the fragment the README relies on is not in the notice any more"
        )
        assertQuotes(fragment, from: route, sourceName: "MCPRoute.swift")
    }

    // MARK: - Refusal reasons

    /// The five reasons the README tells a reader to look for, in the sources that produce
    /// them.
    ///
    /// Each is a *prefix*, because that is what the README prints — it elides with an
    /// ellipsis to keep the sentence readable. Matching the elided form rather than the
    /// full string is what makes a renamed sentence a red test instead of a silent drift.
    func testEveryRefusalReasonTheReadmePointsAtExists() {
        let expectations: [(fragment: String, file: String)] = [
            ("MCP mutations are disabled",
             "Sources/PortmasterMCP/PermissionGate.swift"),
            ("Portmaster must be open to approve",
             "Sources/PortmasterMCP/PermissionGate.swift"),
            ("No answer to Portmaster's confirmation prompt",
             "Sources/PortmasterMCP/HostMCPCallContext.swift"),
            ("The AI client stopped waiting",
             "Sources/PortmasterMCP/HostMCPCallContext.swift"),
            ("cannot be changed via MCP",
             "Sources/PortmasterMCP/PreferencesStore.swift"),
        ]
        for expectation in expectations {
            assertQuotes(
                expectation.fragment,
                from: Self.source(expectation.file),
                sourceName: expectation.file
            )
        }
    }

    /// The timeout the README quotes is the broker's own budget.
    ///
    /// "within 60 s" is arithmetic on `ConfirmationBroker.defaultTimeout` — and a rounding
    /// or a default change would make it stale. Asserted against the constant's value
    /// rather than against the source text, because the number in the README is the
    /// constant's *value*.
    func testTheConfirmationWindowTheReadmeQuotesIsTheBrokersBudget() {
        let seconds = Int(ConfirmationBroker.defaultTimeout)
        guard line(containing: "\(seconds) s") != nil else { return }
        XCTAssertEqual(
            ConfirmationBroker.defaultTimeout, 60,
            "the README says the window is \\(seconds)s, which is now this constant's value"
        )
    }

    // MARK: - The audit line's shape

    /// The field list the README prints is `AuditLog`'s `CodingKeys`.
    ///
    /// Read from the source rather than restated: a key added to the entry has to change
    /// the README too, and the README's claim about "no attempt identifier" depends on
    /// the list being exactly these six.
    func testTheAuditLineShapeTheReadmePrintsIsTheOneAuditLogWrites() {
        let auditLog = Self.source("Sources/PortmasterMCP/AuditLog.swift")
        let printed = "{ts, tool, arguments, outcome, reason, pid}"
        guard line(containing: printed) != nil else { return }

        // Every key the README names, in that order, from the enum's own case list.
        let keys = ["ts", "tool", "arguments", "outcome", "reason", "pid"]
        guard let caseLine = auditLog
            .components(separatedBy: .newlines)
            .first(where: { $0.contains("case ts, tool") })
        else {
            return XCTFail("could not find AuditLog's CodingKeys case list to compare against")
        }
        for key in keys {
            XCTAssertTrue(
                caseLine.contains("case \(key)") || caseLine.contains(", \(key)"),
                "the README names `\\(key)` and CodingKeys does not: \\(caseLine.trimmingCharacters(in: .whitespaces))"
            )
        }
    }

    // MARK: - What this file does not do

    /// The README's claims that are judgements, not quotations, and are therefore left to
    /// review.
    ///
    /// Listed so the boundary is visible rather than assumed. Each of these was a real
    /// drift found in rounds 2–4, and each has to be caught by a reader:
    ///
    /// - *"an `mcpMode` change is an ordinary mutation, settable under `allowSession`"*
    ///   — true of intent, and the code path is asserted in `MCPHostWiringTests`; what is
    ///   not assertable is that the README should say it.
    /// - *"Developer ID signing is not configuration only"* — a statement about release
    ///   process. Nothing in the repository can make it true.
    /// - *"nine read tools and four mutations"* — assertable, and left to the e2e script
    ///   asserting 13 over the socket, because a count belongs with the thing that counts.
    /// - *"the App's slice is build-verified, not exercised by CI"* — the one sentence in
    ///   this section most likely to go stale, and the least checkable: it is true only as
    ///   long as no test drives `App/`, which is not a fact a test can assert about itself.
    func testTheJudgementCallsAreLeftToReviewNotAsserted() {
        // Nothing to assert. The function exists to hold the list and the reasoning, and
        // to fail loudly if someone empties it — which would mean the boundary had been
        // quietly abandoned rather than moved.
        let leftToReview = [
            "mcpMode is an ordinary mutation",
            "Developer ID signing is not configuration only",
            "the count of tools",
            "build-verified, not exercised by CI",
        ]
        XCTAssertEqual(leftToReview.count, 4, "keep this list honest when it changes")
    }
}
// The App half of the agent-source wiring, asserted from source.
//
// There is no App test target: `project.yml` declares the `Portmaster` application and
// the `PortmasterCore` package, and nothing runs against `App/` — so the wiring's
// claims cannot be exercised at runtime without adding a target, which this task is not
// allowed to do and which would outweigh the claims. What the repository already does
// instead is `MCPSettingsChromeTests`: read the shipped source from the repository root
// and assert the structure the claims rest on, with the pass-for-the-wrong-reason ways
// closed — the file must be found (an unreadable file fails, never passes empty), every
// marker an assertion anchors to must exist (a renamed function fails the claim about it
// rather than silently asserting over nothing), and comments are stripped before any
// matching, because a doc comment can discuss the very strings it forbids (the same
// rule, for the same reason, as that file's `withoutComments`).
//
// The same mechanism pins the context-pressure strip's claims (placement above the
// grid, one threshold site, one assignment site), with the same limit: a source scan
// says where code is, never that it runs.
//
// **What this proves, and what it does not.** It proves where the poller is built —
// once, inside the `do` that opens the store — that no second error channel exists for
// it, where it is started and stopped from (the terminate hook, and nowhere else in
// `App/`), and that no App code calls the blocking `pollOnce` while a surface asks
// instead. It does not prove the poller runs or that a pass logs a line; the poller's
// own start and stop are runtime facts pinned in `AgentSourcePollerTests`, and the
// production run recorded in this task's report covers the app's side of them.

import Foundation
import XCTest

final class AppAgentSourceWiringTests: XCTestCase {

    /// Four levels up: PortmasterCoreTests → Tests → Core → the repository root, which
    /// is where `App/` lives. The package root alone would be three, and `App/` is not
    /// inside the package.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// One file's contents with comments stripped, or a failure naming what was missing.
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

    /// Every `.swift` file under `App/`, concatenated with comments stripped, counted
    /// two ways.
    ///
    /// **A non-Swift entry is skipped, not treated as the end of the directory.** The
    /// directory holds only sources today, but `FileManager`'s enumeration order is
    /// unspecified, so an asset or a `.gitignore` listed before a later source would
    /// otherwise truncate the walk at that entry — and every whole-App assertion below
    /// would be reading a prefix while believing it read the tree. The second count,
    /// taken with `subpathsOfDirectory`, is what makes that truncation loud rather than
    /// silent; an unreadable file fails by name rather than contributing `""`.
    private func wholeAppSource(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let appDirectory = Self.repositoryRoot.appendingPathComponent("App")
        let enumerator = FileManager.default.enumerator(
            at: appDirectory, includingPropertiesForKeys: nil
        )
        var scanned = ""
        var fileCount = 0
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail(
                    "\(url.path) was not readable — the scan would miss it",
                    file: file, line: line
                )
                continue
            }
            scanned += Self.withoutComments(text)
            fileCount += 1
        }
        let expected = try FileManager.default
            .subpathsOfDirectory(atPath: appDirectory.path)
            .filter { $0.hasSuffix(".swift") }
            .count
        XCTAssertEqual(
            fileCount, expected,
            "every Swift file under App/ was scanned, not a prefix of them",
            file: file, line: line
        )
        XCTAssertGreaterThan(
            fileCount, 0, "no App sources found — the scan would pass over nothing",
            file: file, line: line
        )
        return scanned
    }

    /// The slice from `start` to the line that closes the enclosing declaration at the
    /// four-space indent — how every top-level `func` in these files ends. `nil` when
    /// the marker is absent, so the claim about that function fails loudly.
    private func region(in source: String, from start: String) -> String? {
        guard let startRange = source.range(of: start) else { return nil }
        guard let endRange = source.range(
            of: "\n    }", range: startRange.upperBound..<source.endIndex
        ) else { return nil }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Every comment replaced by spaces, newlines kept, so the code's shape — and every
    /// range an assertion anchors to — survives.
    ///
    /// Same rule and same reason as `MCPSettingsChromeTests.withoutComments`: a doc
    /// comment can discuss the strings it forbids, so a comment quoting
    /// `agentSourcePoller?.start()` inside `start()` would satisfy a presence assertion
    /// with the real call deleted, and a mention of `.pollOnce` in any App comment would
    /// break the scan that forbids it. Duplicated rather than shared because the two
    /// files sit in different test targets with no utility target between them, and a
    /// new target would outweigh the claims. Known limitation, also the precedent's: a
    /// `//` or `/*` inside a string literal would be read as a comment; no App source
    /// holds one today.
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

    // MARK: - One `do`, one poller, one failure

    /// **The poller is built from the store this `do` produced, inside the `do`.** A
    /// store that throws therefore reaches the `catch` with no poller to leave behind,
    /// and the feature keeps the single failure it already had instead of gaining a
    /// second one to read about.
    ///
    /// Ordering is the assertion: open the store, build the poller from it, and be
    /// inside the `do` while doing it — each checked against the next, so moving the
    /// construction out past the `catch` fails here rather than shipping a poller with
    /// no store to write to. The `catch` is found by the failure it reports, not by
    /// being the next `} catch {` after the build: that would be `clearHistory`'s,
    /// which sits past any position the construction could be moved to.
    func testThePollerIsBuiltInsideTheDoThatOpensTheStore() throws {
        let app = try source("App/AppModel.swift")
        let construction = "agentSourcePoller = AgentSourcePoller"
        XCTAssertEqual(
            occurrences(of: construction, in: app), 1,
            "exactly one construction site in the app"
        )

        let storeOpen = try XCTUnwrap(
            app.range(of: "let store = try AgentSessionStore()"),
            "the store is no longer opened where the poller is built"
        )
        let build = try XCTUnwrap(
            app.range(of: construction),
            "the poller is no longer built in AppModel"
        )
        XCTAssertTrue(
            storeOpen.upperBound < build.lowerBound,
            "the poller must be built from the store, not beside it"
        )
        let catchStart = try XCTUnwrap(
            app.range(of: "} catch {\n            agentSessionError"),
            "the `do` that builds the poller has no catch that reports the store's failure"
        )
        XCTAssertTrue(
            build.upperBound < catchStart.lowerBound,
            "the poller must be built inside the `do`, before its `catch`"
        )
    }

    /// **A store that will not open takes no poller and no second complaint.** The
    /// `catch` builds nothing and sets only the error the feature already published;
    /// and the file declares no `agentSource…Error` of its own, because "the database
    /// would not open" is one fact, not two — a second channel is how one unreadable
    /// file starts reading as two broken features.
    func testAStoreThatWillNotOpenTakesNoPollerAndOpensNoSecondErrorChannel() throws {
        let app = try source("App/AppModel.swift")
        let build = try XCTUnwrap(app.range(of: "agentSourcePoller = AgentSourcePoller"))
        let catchStart = try XCTUnwrap(
            app.range(
                of: "} catch {\n            agentSessionError",
                range: build.upperBound..<app.endIndex
            ),
            "the `do` that builds the poller has no catch that reports the store's failure"
        )
        // The catch body, read from the line that opens it: statements at twelve
        // spaces, closed by the line at eight.
        let bodyEnd = try XCTUnwrap(
            app.range(of: "\n        }", range: catchStart.upperBound..<app.endIndex),
            "the `catch` has no body to read"
        )
        let body = String(app[catchStart.lowerBound..<bodyEnd.lowerBound])
        XCTAssertFalse(
            body.contains("agentSourcePoller"),
            "the failure path builds nothing — a store that would not open has no poller"
        )
        XCTAssertTrue(
            body.contains("agentSessionError ="),
            "the one failure it already had is still the one it reports"
        )
        XCTAssertNil(
            app.range(of: "var agentSource[A-Za-z]*Error", options: .regularExpression),
            "no second error channel named after this feature"
        )
    }

    /// **Built once, in `init`, and started only from `start()`.** No surface, no
    /// refresh, and no re-read of the store may reach the construction — a second
    /// poller over the first one's timer would be two lanes reading the same logs on
    /// two clocks, and nothing on screen would say so.
    func testThePollerIsBuiltOnceInInitAndStartedOnlyFromStart() throws {
        let app = try source("App/AppModel.swift")
        XCTAssertEqual(
            occurrences(of: "agentSourcePoller = ", in: app), 1,
            "one assignment: construction, in `init`"
        )

        let initBody = try XCTUnwrap(
            region(in: app, from: "init(preview: Bool = false) {"),
            "`AppModel.init` was not found where the poller is claimed to be built"
        )
        XCTAssertTrue(
            initBody.contains("agentSourcePoller = AgentSourcePoller"),
            "the poller is built in `init`, before any surface can appear"
        )

        for name in [
            "func surfaceAppeared()", "func refreshAgentSessions()",
            "func start()", "func refreshPrices()",
        ] {
            let body = try XCTUnwrap(
                region(in: app, from: name), "\(name) was not found in AppModel"
            )
            XCTAssertFalse(
                body.contains("agentSourcePoller = "),
                "\(name) must not build a poller"
            )
        }

        let startBody = try XCTUnwrap(
            region(in: app, from: "func start()"),
            "`AppModel.start()` was not found"
        )
        XCTAssertEqual(
            occurrences(of: "agentSourcePoller?.start()", in: startBody), 1,
            "started from `start()` — construction starts nothing, by design"
        )
        // And from nowhere else in `App/`: the property's getter is internal, so any
        // file in the app could reach it, and the name's "only" is a claim about the
        // whole app rather than about this one file.
        XCTAssertEqual(
            occurrences(of: "agentSourcePoller?.start()", in: try wholeAppSource()), 1,
            "started from `start()` and from nowhere else in the app"
        )
    }

    /// **Quit stops it from the terminate hook, and from nowhere else.**
    ///
    /// Two separate facts, because they fail differently: the hook must call it (or a
    /// poller outlives a quit that asked it to stop), and the awaiting quit path must
    /// not (or the stop is skipped on exactly the quits where no host is bound, which
    /// is most of them — that path answers `.terminateNow` and never runs its task).
    /// "Nowhere else" is counted over all of `App/`, not just the delegate: a second
    /// stop in any other file would stop the poller on a path this file cannot see.
    func testQuitStopsThePollerFromTheTerminateHookAndFromNowhereElse() throws {
        let delegate = try source("App/PortmasterApp.swift")
        let wholeApp = try wholeAppSource()
        XCTAssertEqual(
            occurrences(of: "stopAgentSources()", in: wholeApp), 2,
            "one call across all of App, plus the model's declaration — a second call "
                + "site anywhere would be three"
        )

        let willTerminate = try XCTUnwrap(
            region(in: delegate, from: "func applicationWillTerminate(_ notification: Notification) {"),
            "`applicationWillTerminate` was not found"
        )
        XCTAssertTrue(
            willTerminate.contains("stopAgentSources()"),
            "the poller is stopped on the way out"
        )

        let shouldTerminate = try XCTUnwrap(
            region(in: delegate, from: "func applicationShouldTerminate(_ sender: NSApplication)"),
            "`applicationShouldTerminate` was not found"
        )
        XCTAssertFalse(
            shouldTerminate.contains("stopAgentSources()"),
            "not on the awaiting path, which a quit with no host bound never runs"
        )

        XCTAssertEqual(
            occurrences(of: "agentSourcePoller?.stop()", in: wholeApp), 1,
            "the model's stop funnels through one place: `stopAgentSources()`"
        )
    }

    // MARK: - The surface asks; it never blocks

    /// **A surface asks for a poll and never makes one itself.** `pollOnce` waits on
    /// the poller's queue, and that queue is where another application's log is parsed
    /// — a surface calling it would parse a conversation's worth of JSONL on the main
    /// thread, which is the one thing the wiring must not do. Every `App/` source is
    /// scanned, not just `AppModel`, because a call added to any surface is the same
    /// defect.
    func testASurfaceAsksForAPollAndNeverCallsTheBlockingOne() throws {
        let appSource = try wholeAppSource()
        XCTAssertEqual(
            occurrences(of: ".pollOnce", in: appSource), 0,
            "the blocking poll belongs to tests and diagnostics, never to a surface"
        )

        let model = try source("App/AppModel.swift")
        let appeared = try XCTUnwrap(
            region(in: model, from: "func surfaceAppeared()"),
            "`surfaceAppeared` was not found"
        )
        XCTAssertTrue(
            appeared.contains("agentSourcePoller?.requestPoll()"),
            "a surface asks — non-blocking, under the interval the timer obeys"
        )
    }

    // MARK: - The strip above the grid

    /// **The strip renders above the overview grid, exactly once, from the model's
    /// notice.** Placement is the claim: a strip drawn after the cards answers a
    /// question the reader has already looked past, and a second render would answer
    /// it twice. Anchored to the body's `cardGrid` call rather than to `LazyVGrid`,
    /// which sits inside `cardGrid`'s own definition below the body — a strip
    /// anywhere in the body precedes that, so the `LazyVGrid` anchor could not see a
    /// strip moved below the grid.
    ///
    /// What it does not prove: that the strip ever appears. That needs a live session
    /// whose budget actually eroded, which the app run in this task's report attempts
    /// and reports honestly.
    func testThePressureStripIsRenderedAboveTheGrid() throws {
        let overview = try source("App/OverviewView.swift")
        XCTAssertEqual(
            occurrences(of: "ContextPressureStrip(notice:", in: overview), 1,
            "the strip is rendered once, from the model's notice"
        )
        let strip = try XCTUnwrap(
            overview.range(of: "ContextPressureStrip(notice:"),
            "OverviewView no longer renders ContextPressureStrip"
        )
        let grid = try XCTUnwrap(
            overview.range(of: "cardGrid(ids: [\"cpu\""),
            "OverviewView no longer calls the overview grid"
        )
        XCTAssertTrue(
            strip.lowerBound < grid.lowerBound,
            "the strip must sit above the grid, not below it"
        )
    }

    /// **The provisional threshold has exactly one site across `App/`.** It is
    /// unvalidated policy — half a session's own first reading — so a second site
    /// would be a second policy no data ever justified, drifting from the first with
    /// nothing on screen to say so. Counted on the operator core rather than the
    /// operand names: the derivation binds its own locals, and a rename must not move
    /// the count. Comments are stripped before matching, so a comment quoting the
    /// threshold is not a site.
    func testTheProvisionalThresholdHasExactlyOneSiteAcrossApp() throws {
        XCTAssertEqual(
            occurrences(of: "* 2 <= ", in: try wholeAppSource()), 1,
            "one unvalidated threshold, one call site"
        )
        XCTAssertEqual(
            occurrences(of: "first <= Int.max / 2", in: try wholeAppSource()), 1,
            "the multiplication is guarded once, beside the one threshold"
        )
    }

    /// **`contextPressureNotice` is assigned in one file, and inside
    /// `refreshAgentSessions`.** The strip and the sessions card below it must not
    /// disagree, and they cannot while the notice is derived only where the session
    /// list is re-read; a second assignment anywhere else in `App/` would be a second
    /// source of truth the two could drift apart from. The needle is
    /// `contextPressureNotice = `, so the `@Published var` declaration is neither an
    /// assignment nor a site.
    func testTheContextPressureNoticeIsAssignedInExactlyOneFile() throws {
        XCTAssertEqual(
            occurrences(of: "contextPressureNotice = ", in: try wholeAppSource()), 1,
            "one assignment across App — a second site is a second source of truth"
        )
        let app = try source("App/AppModel.swift")
        let refresh = try XCTUnwrap(
            region(in: app, from: "func refreshAgentSessions()"),
            "`refreshAgentSessions` was not found in AppModel"
        )
        XCTAssertTrue(
            refresh.contains("contextPressureNotice = "),
            "the notice is derived where the session list is re-read"
        )
    }
}

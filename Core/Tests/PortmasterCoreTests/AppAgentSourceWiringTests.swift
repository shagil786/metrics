// The App half of the agent-source wiring, asserted from source.
//
// There is no App test target: `project.yml` declares the `Portmaster` application and
// the `PortmasterCore` package, and nothing runs against `App/` — so the wiring's four
// claims cannot be exercised at runtime without adding a target, which this task is not
// allowed to do and which would outweigh the claims. What the repository already does
// instead is `MCPSettingsChromeTests`: read the shipped source from the repository root
// and assert the structure the claims rest on, with the pass-for-the-wrong-reason ways
// closed — the file must be found (an unreadable file fails, never passes empty), and
// every marker an assertion anchors to must exist (a renamed function fails the claim
// about it rather than silently asserting over nothing).
//
// **What this proves, and what it does not.** It proves where the poller is built —
// once, inside the `do` that opens the store — that no second error channel exists for
// it, where it is started and stopped from (the terminate hook, and nowhere on the
// awaiting quit path), and that no App code calls the blocking `pollOnce` while a
// surface asks instead. It does not prove the poller runs, that a pass logs a line, or
// that quitting stops it: those are runtime facts, and the runtime evidence for them is
// the production run recorded in this task's report, not this file.

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

    /// One file's contents, or a failure naming what was missing.
    private func source(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        let text = try? String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(
            text, "\(relativePath) was not found at \(url.path) — the scan would pass over nothing",
            file: file, line: line
        )
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

    // MARK: - One `do`, one poller, one failure

    /// **The poller is built from the store this `do` produced, inside the `do`.** A
    /// store that throws therefore reaches the `catch` with no poller to leave behind,
    /// and the feature keeps the single failure it already had instead of gaining a
    /// second one to read about.
    ///
    /// Ordering is the assertion: open the store, build the poller from it, and be
    /// inside the `do` while doing it — each checked against the next, so moving the
    /// construction out past the `catch` fails here rather than shipping a poller with
    /// no store to write to.
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
            app.range(of: "} catch {", range: build.upperBound..<app.endIndex),
            "the `do` that builds the poller has no `catch`"
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
            app.range(of: "} catch {", range: build.upperBound..<app.endIndex),
            "the `do` that builds the poller has no `catch`"
        )
        // The catch body: statements at eight spaces, closed by the next line at eight.
        let bodyEnd = try XCTUnwrap(
            app.range(of: "\n        }", range: catchStart.upperBound..<app.endIndex),
            "the `catch` has no body to read"
        )
        let body = String(app[catchStart.upperBound..<bodyEnd.lowerBound])
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
    }

    /// **Quit stops it from the terminate hook, and from nowhere else.**
    ///
    /// Two separate facts, because they fail differently: the hook must call it (or a
    /// poller outlives a quit that asked it to stop), and the awaiting quit path must
    /// not (or the stop is skipped on exactly the quits where no host is bound, which
    /// is most of them — that path answers `.terminateNow` and never runs its task).
    func testQuitStopsThePollerFromTheTerminateHookAndFromNowhereElse() throws {
        let delegate = try source("App/PortmasterApp.swift")
        XCTAssertEqual(
            occurrences(of: "stopAgentSources()", in: delegate), 1,
            "one call site in the whole delegate"
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

        let app = try source("App/AppModel.swift")
        XCTAssertEqual(
            occurrences(of: "agentSourcePoller?.stop()", in: app), 1,
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
        let enumerator = FileManager.default.enumerator(
            at: Self.repositoryRoot.appendingPathComponent("App"),
            includingPropertiesForKeys: nil
        )
        var appSource = ""
        var fileCount = 0
        while let url = enumerator?.nextObject() as? URL, url.pathExtension == "swift" {
            appSource += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            fileCount += 1
        }
        XCTAssertGreaterThan(fileCount, 0, "no App sources found — the scan would pass over nothing")
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
}

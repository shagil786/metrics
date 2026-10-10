// Core/Tests/PortmasterCoreTests/HandoffBriefExtractorTests.swift
import XCTest
import Foundation
@testable import PortmasterCore

final class HandoffBriefExtractorTests: XCTestCase {

    private func writeLog(_ lines: [String], name: String = "session.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Eight lines, numbered and role-tagged in the comments — every assertion below
    /// pins a line number, so a parser that counts wrong fails here and not later.
    private func fixtureLines(projectDir: String) -> [String] {
        [
            // 1 — goal text and cwd ride the first user turn
            #"{"type":"user","timestamp":"2026-10-10T12:00:00.000Z","cwd":"\#(projectDir)","message":{"role":"user","content":"Fix the flaky retry test and commit."}}"#,
            // 2 — an assistant text turn (state)
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"I will look at the retry test."}]}}"#,
            // 3 — a tool_result user entry: NOT a user turn
            #"{"type":"user","timestamp":"2026-10-10T12:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            // 4 — Bash mutation (Done)
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:10.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"grep -r retry Tests/"}}]}}"#,
            // 5 — Write mutation (Done and Files touched)
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:15.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"\#(projectDir)/fix.swift","content":"x"}}]}}"#,
            // 6 — in-flight Bash: no tool_result ever follows → Next
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:20.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift test --filter Retry"}}]}}"#,
            // 7 — last assistant text (state)
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:25.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Running the filter now."}]}}"#,
            // 8 — closing user turn (state)
            #"{"type":"user","timestamp":"2026-10-10T12:00:30.000Z","message":{"role":"user","content":"also update the changelog"}}"#,
        ]
    }

    func testEveryClaimCarriesTheLineItCameFrom() throws {
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent("proj").path
        let url = try writeLog(fixtureLines(projectDir: projectDir))

        let brief = try HandoffBriefExtractor.extract(from: url)

        XCTAssertEqual(brief.goal, BriefItem(text: "Fix the flaky retry test and commit.", line: 1))
        XCTAssertEqual(brief.workingDirectory, projectDir)
        XCTAssertEqual(brief.done, [
            BriefItem(text: "ran `grep -r retry Tests/`", line: 4),
            BriefItem(text: "wrote \(projectDir)/fix.swift", line: 5),
        ])
        XCTAssertEqual(brief.files, [
            BriefItem(text: "wrote \(projectDir)/fix.swift", line: 5),
        ])
        XCTAssertEqual(brief.state.map(\.line), [2, 7, 8],
                       "the closing turns are the last three conversation turns, in order")
        XCTAssertEqual(brief.next?.line, 6, "t3 never got a tool_result — it was in flight")
        XCTAssertEqual(brief.next?.text, "ran `swift test --filter Retry`")
        XCTAssertEqual(brief.citedLines, [1, 2, 4, 5, 6, 7, 8],
                       "deduplicated and sorted; line 3 is a tool_result and cites nothing")
        XCTAssertTrue(brief.dropped.isEmpty)
    }

    func testAToolResultArrayIsNotAUserTurn() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"x"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"still working"}]}}"#,
        ]
        let brief = HandoffBriefExtractor.extract(from: lines.joined(separator: "\n"), sourceLogPath: "/tmp/x.jsonl")
        XCTAssertNil(brief.goal, "no real user turn exists, so no goal is invented")
        XCTAssertEqual(brief.next?.text, "still working",
                       "with no dangling tool_use, Next is the last assistant text")
    }

    func testASystemReminderOnlyUserTurnIsNotAGoal() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"<system-reminder>watch the style</system-reminder>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"the real request"}}"#,
        ]
        let brief = HandoffBriefExtractor.extract(from: lines.joined(separator: "\n"), sourceLogPath: "/tmp/x.jsonl")
        XCTAssertEqual(brief.goal, BriefItem(text: "the real request", line: 2),
                       "a reminder-wrapped turn has no user text left after stripping")
    }

    func testALogWithNothingCitableYieldsNothing() throws {
        let lines = [
            #"{"type":"system","message":"booting"}"#,
            #"{"type":"mode","mode":"plan"}"#,
            "not json at all",
        ]
        let brief = HandoffBriefExtractor.extract(from: lines.joined(separator: "\n"), sourceLogPath: "/tmp/x.jsonl")
        XCTAssertNil(brief.goal)
        XCTAssertTrue(brief.done.isEmpty)
        XCTAssertTrue(brief.files.isEmpty)
        XCTAssertTrue(brief.state.isEmpty)
        XCTAssertNil(brief.next)
        XCTAssertNil(brief.workingDirectory)
        XCTAssertTrue(brief.citedLines.isEmpty, "zero citations is what the refusal test keys on")
    }

    func testALongCommandIsClippedAndSaysSo() throws {
        let long = String(repeating: "a", count: 400)
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"\#(long)"}}]}}"#,
        ]
        let brief = HandoffBriefExtractor.extract(from: lines.joined(separator: "\n"), sourceLogPath: "/tmp/x.jsonl")
        XCTAssertEqual(brief.done.first?.line, 1)
        XCTAssertEqual(brief.done.first?.text.count, 201, "200 characters plus the ellipsis")
        XCTAssertTrue(brief.done.first?.text.hasSuffix("…") ?? false)
    }

    func testTheRenderedBriefCitesEverySection() throws {
        let projectDir = "/tmp/proj"
        let url = try writeLog(fixtureLines(projectDir: projectDir))
        var brief = try HandoffBriefExtractor.extract(from: url)
        brief.sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")

        let markdown = brief.renderedMarkdown()

        XCTAssertTrue(markdown.contains("Session: 11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(markdown.contains("Source log: \(url.path)"))
        XCTAssertTrue(markdown.contains("## Goal\nFix the flaky retry test and commit. (line 1)"))
        XCTAssertTrue(markdown.contains("## Done"))
        XCTAssertTrue(markdown.contains("- ran `grep -r retry Tests/` (line 4)"))
        XCTAssertTrue(markdown.contains("## Files touched"))
        XCTAssertTrue(markdown.contains("## State"))
        XCTAssertTrue(markdown.contains("## Next\nran `swift test --filter Retry` (line 6)"))
        XCTAssertFalse(markdown.contains("## Dropped"), "nothing was dropped, so nothing is named")
    }
}

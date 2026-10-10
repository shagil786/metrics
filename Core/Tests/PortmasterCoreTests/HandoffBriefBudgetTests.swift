// Core/Tests/PortmasterCoreTests/HandoffBriefBudgetTests.swift
import XCTest
import Foundation
@testable import PortmasterCore

final class HandoffBriefBudgetTests: XCTestCase {

    private func brief(
        goal: String = "do the thing", done: [BriefItem] = [], files: [BriefItem] = [],
        state: [BriefItem] = [], next: BriefItem? = nil
    ) -> HandoffBrief {
        HandoffBrief(
            goal: BriefItem(text: goal, line: 1),
            done: done, files: files, state: state, next: next,
            workingDirectory: "/tmp/p", sourceLogPath: "/tmp/p/s.jsonl"
        )
    }

    private func pad(_ label: String, size: Int) -> String {
        label + String(repeating: "x", count: size)
    }

    func testASmallBriefIsUntouched() {
        let b = brief(state: [BriefItem(text: "hi", line: 9)])
        XCTAssertEqual(b.budgeted(), b, "a brief under budget keeps every word and says nothing was dropped")
    }

    func testStateGoesFirstAndNamesItself() {
        var b = brief()
        b = HandoffBrief(
            goal: b.goal, done: b.done, files: b.files,
            state: (1...40).map { BriefItem(text: pad("turn\($0) ", size: 128), line: $0) },
            next: nil, workingDirectory: b.workingDirectory, sourceLogPath: b.sourceLogPath
        )
        let budgeted = b.budgeted()
        XCTAssertTrue(budgeted.state.isEmpty, "state is the lowest-priority section")
        XCTAssertEqual(budgeted.dropped.count, 1)
        XCTAssertTrue(budgeted.dropped[0].hasPrefix("state: 40 closing turns dropped"))
        XCTAssertTrue(budgeted.dropped[0].contains("length budget"))
    }

    func testDoneIsTrimmedFromTheTailAndNamesHowMany() {
        let big = (1...80).map { BriefItem(text: pad("ran `cmd\($0)` ", size: 140), line: $0) }
        let b = brief(done: big, state: [])
        let budgeted = b.budgeted()
        XCTAssertFalse(budgeted.done.isEmpty, "the earliest mutations survive — they define the work")
        XCTAssertTrue(budgeted.done.count < big.count)
        let note = try? XCTUnwrap(budgeted.dropped.first { $0.hasPrefix("done:") })
        XCTAssertNotNil(note, "a trimmed section is named")
        XCTAssertTrue(note?.contains("\(big.count - budgeted.done.count) of \(big.count)") ?? false)
    }

    func testGoalIsClippedLoudlyNeverSilently() {
        let b = brief(goal: pad("huge ", size: 20_000))
        let budgeted = b.budgeted()
        XCTAssertLessThan(
            HandoffBrief.estimateTokens(budgeted.renderedMarkdown()),
            HandoffBrief.budgetTokens + 64,
            "the rendered brief fits the budget (plus the marker itself)"
        )
        XCTAssertTrue(budgeted.goal?.text.contains("[clipped to fit the handoff budget]") ?? false)
        XCTAssertEqual(budgeted.goal?.line, 1, "clipping text never moves the citation")
        XCTAssertTrue(budgeted.dropped.contains { $0.hasPrefix("goal:") })
    }

    func testTheEstimatorIsTheDocumentedHeuristic() {
        XCTAssertEqual(HandoffBrief.estimateTokens(String(repeating: "a", count: 4000)), 1000)
    }

    func testTheDropNotesCannotPushTheBriefBackOverItsOwnBudget() {
        // 60 done items at pad 158 trim to 32 items (1487 tokens); the done
        // note itself costs ~16 tokens, which used to cross the budget and
        // fire the goal clip on a goal that never shrank.
        let done = (1...60).map { BriefItem(text: pad("ran `cmd\($0)` ", size: 158), line: $0) }
        let b = brief(done: done)
        let budgeted = b.budgeted()
        XCTAssertLessThanOrEqual(
            HandoffBrief.estimateTokens(budgeted.renderedMarkdown()),
            HandoffBrief.budgetTokens,
            "a note about a drop may not cost more room than the drop freed"
        )
        XCTAssertNil(
            budgeted.dropped.first { $0.hasPrefix("goal:") },
            "a short goal that never shrank is never reported clipped"
        )
        XCTAssertEqual(budgeted.goal?.text, "do the thing", "the clip marker never claims a clip that did not happen")
        XCTAssertNotNil(budgeted.dropped.first { $0.hasPrefix("done:") }, "the done trim is still named")
    }
}

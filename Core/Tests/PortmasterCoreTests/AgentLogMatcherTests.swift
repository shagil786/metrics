// The uniqueness rule, with no filesystem anywhere in the file.
//
// "Is this session's log the one file, or one of two?" is the decision every figure in
// this feature rests on, and the wrong answer to it is a *number* rather than an
// absence. Getting it wrong is also easy: a directory walk in the way means a test that
// catches it has to write files, set timestamps and hope the clock cooperates. So the
// rule is here, taking two values and touching nothing.
import XCTest
import Foundation
@testable import PortmasterCore

final class AgentLogMatcherTests: XCTestCase {

    /// A window wide enough that only a deliberately-misplaced candidate falls out of
    /// it. `overlap` is a parameter rather than a constant so a test can say "outside"
    /// explicitly instead of computing a timestamp far enough away to be unambiguous.
    private let overlap: TimeInterval = 3600

    private func session(connectedAt: Date) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: UUID(), peerPID: 4242,
            clientName: "fixture", clientVersion: nil,
            connectedAt: connectedAt, endedAt: nil,
            usage: .notReported(reason: .noSource), cost: .noUsage
        )
    }

    private func candidate(
        _ name: String, modifiedAt: Date
    ) -> LogCandidate {
        LogCandidate(
            url: URL(fileURLWithPath: "/logs/\(name).jsonl"),
            modifiedAt: modifiedAt
        )
    }

    // MARK: - The one case that becomes a number

    /// Exactly one file overlapping the session. The only shape `Match.unique` has.
    func testOneCandidateInTheWindowIsAMatch() {
        let now = Date()
        let matched = candidate("only", modifiedAt: now)

        let match = AgentLogMatcher.match(
            [matched], for: session(connectedAt: now.addingTimeInterval(-60)), overlap: overlap
        )

        XCTAssertEqual(match, .unique(matched))
    }

    /// The file need not be the most recent, the only one, or anything but the one.
    /// What makes it a match is that nothing else overlaps — so a single file written
    /// *before* the connection still matches, which is the ordinary case for a log that
    /// ended as the session opened.
    func testASingleCandidateIsAMatchHoweverOldItIsWithinTheWindow() {
        let now = Date()
        let only = candidate("old", modifiedAt: now.addingTimeInterval(-overlap + 1))

        let match = AgentLogMatcher.match(
            [only], for: session(connectedAt: now), overlap: overlap
        )

        XCTAssertEqual(match, .unique(only))
    }

    // MARK: - Neither no files nor two

    /// Zero candidates is `ambiguous(0)`, and the count is carried so a caller can say
    /// "nothing to read" rather than "too much to choose between" — two different facts
    /// about the machine that a single optional would have merged.
    func testNoCandidatesIsAmbiguousWithZero() {
        let match = AgentLogMatcher.match(
            [], for: session(connectedAt: Date()), overlap: overlap
        )

        XCTAssertEqual(match, .ambiguous(count: 0))
    }

    /// **The case the rule exists for.** Two agents running side by side both overlap
    /// one window, and neither is more likely than the other. Taking the most recent
    /// would file each one's tokens against the other session — a wrong number, which
    /// is the one failure this design exists to prevent, and the one no downstream check
    /// would catch because it looks exactly like a real figure.
    func testTwoCandidatesAreAmbiguousAndNotBrokenIntoAPick() {
        let now = Date()
        let candidates = [
            candidate("agent-a", modifiedAt: now.addingTimeInterval(-30)),
            candidate("agent-b", modifiedAt: now.addingTimeInterval(-20)),
        ]

        let match = AgentLogMatcher.match(
            candidates, for: session(connectedAt: now.addingTimeInterval(-120)), overlap: overlap
        )

        XCTAssertEqual(match, .ambiguous(count: 2))
    }

    /// More than two is the same refusal, and the count must still say how many — a
    /// diagnostic that reports "ambiguous" for both two and twenty is not a diagnostic.
    func testManyCandidatesReportTheirCount() {
        let now = Date()
        let candidates = (0..<5).map { candidate("agent-\($0)", modifiedAt: now) }

        let match = AgentLogMatcher.match(
            candidates, for: session(connectedAt: now), overlap: overlap
        )

        XCTAssertEqual(match, .ambiguous(count: 5))
    }

    // MARK: - The window does the excluding

    /// A file outside the window is not a candidate, so it cannot make a match ambiguous
    /// either. This is why the count is computed after filtering: a month-old log on the
    /// machine must not turn one live agent's figure into a refusal.
    ///
    /// The sharpest form of the claim — one file in, one file out — because a rule that
    /// counted before filtering would answer `.ambiguous(count: 2)` here.
    func testACandidateOutsideTheWindowIsExcludedRatherThanCounted() {
        let now = Date()
        let live = candidate("live", modifiedAt: now.addingTimeInterval(-30))
        let ancient = candidate("ancient", modifiedAt: now.addingTimeInterval(-90 * 24 * 3600))

        let match = AgentLogMatcher.match(
            [live, ancient],
            for: session(connectedAt: now.addingTimeInterval(-120)),
            overlap: overlap
        )

        XCTAssertEqual(match, .unique(live))
    }

    /// Both bounds, because "outside the window" is two places: a log written before the
    /// session and one written after it are both outside, and a rule that checked only
    /// the lower bound would happily match a file stamped in the future by a machine
    /// with a wrong clock.
    func testAFutureCandidateIsExcludedToo() {
        let now = Date()
        let live = candidate("live", modifiedAt: now.addingTimeInterval(-30))
        let fromTheFuture = candidate("future", modifiedAt: now.addingTimeInterval(overlap + 60))

        let match = AgentLogMatcher.match(
            [live, fromTheFuture],
            for: session(connectedAt: now.addingTimeInterval(-120)),
            overlap: overlap
        )

        XCTAssertEqual(match, .unique(live))
    }

    /// Zero-width overlap: the window is the session's own instant, so only a file
    /// written exactly then matches. Exists to pin that `overlap` is applied to *both*
    /// sides of the comparison rather than added once by accident.
    func testZeroOverlapMatchesOnlyTheSessionInstantItself() {
        let at = Date()
        let match = AgentLogMatcher.match(
            [candidate("near", modifiedAt: at.addingTimeInterval(-1))],
            for: session(connectedAt: at),
            overlap: 0
        )

        XCTAssertEqual(match, .ambiguous(count: 0))
    }
}
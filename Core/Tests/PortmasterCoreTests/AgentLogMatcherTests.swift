// The one-to-one rule, with no filesystem anywhere in the file.
//
// "Which file is whose?" is the decision every figure in this feature rests on, and the
// wrong answer to it is a *number* rather than an absence. Getting it wrong is also easy:
// a directory walk in the way means a test that catches it has to write files, set
// timestamps and hope the clock cooperates. So the rule is here, taking two values and
// touching nothing.
import XCTest
import Foundation
@testable import PortmasterCore

final class AgentLogMatcherTests: XCTestCase {

    /// A window wide enough that only a deliberately-misplaced candidate falls out of
    /// it. `overlap` is a parameter rather than a constant so a test can say "outside"
    /// explicitly instead of computing a timestamp far enough away to be unambiguous.
    private let overlap: TimeInterval = 3600

    /// Everything is measured against one `now`, passed in. The poller takes one reading
    /// per pass; these tests take one per assertion.
    private let now = Date()

    private func session(_ connectedAgo: TimeInterval, id: UUID = UUID()) -> (id: UUID, connectedAt: Date) {
        (id: id, connectedAt: now.addingTimeInterval(-connectedAgo))
    }

    private func candidate(_ name: String, modifiedAgo: TimeInterval) -> LogCandidate {
        LogCandidate(
            url: URL(fileURLWithPath: "/logs/\(name).jsonl"),
            modifiedAt: now.addingTimeInterval(-modifiedAgo)
        )
    }

    private func match(
        _ candidates: [LogCandidate], _ sessions: [(id: UUID, connectedAt: Date)]
    ) -> [UUID: LogMatch] {
        AgentLogMatcher.match(candidates, for: sessions, overlap: overlap, now: now)
    }

    // MARK: - The one case that becomes a number

    /// Exactly one file in the session's window, and no other session that could claim
    /// it. The only shape `LogMatch.unique` has.
    func testOneCandidateOneSessionIsAMatch() {
        let only = session(60)
        let matched = candidate("only", modifiedAgo: 30)

        let result = match([matched], [only])

        XCTAssertEqual(result[only.id], .unique(matched))
    }

    /// The file need not be the most recent, the only one, or anything but the one.
    /// What makes it a match is that nothing else overlaps — so a single file written
    /// *before* the connection still matches, which is the ordinary case for a log that
    /// ended as the session opened.
    func testASingleCandidateIsAMatchHoweverOldItIsWithinTheWindow() {
        let only = session(0)
        let file = candidate("old", modifiedAgo: overlap - 1)

        let result = match([file], [only])

        XCTAssertEqual(result[only.id], .unique(file))
    }

    // MARK: - Nothing to read

    /// Zero candidates is `ambiguous(0)`, and the count is carried so a caller can say
    /// "nothing to read" rather than "too much to choose between" — two different facts
    /// about the machine that a single optional would have merged.
    func testNoCandidatesIsAmbiguousWithZero() {
        let only = session(60)

        XCTAssertEqual(match([], [only])[only.id], .ambiguous(count: 0))
    }

    /// Every session asked gets an entry, including the ones with nothing. The caller
    /// records an absence per session per source, so a session missing from the result
    /// would silently skip its `noSource` rather than report it.
    func testEverySessionAskedGetsAnAnswer() {
        let a = session(60)
        let b = session(120)
        let c = session(180)

        let result = match([], [a, b, c])

        XCTAssertEqual(Set(result.keys), [a.id, b.id, c.id])
    }

    // MARK: - More than one file

    /// **Two files is not a tie to break.** Taking the most recent would file each one's
    /// tokens against the other — a wrong number, which is the one failure this design
    /// exists to prevent, and the one no downstream check would catch because it looks
    /// exactly like a real figure.
    func testTwoCandidatesAreAmbiguousAndNotBrokenIntoAPick() {
        let only = session(120)
        let candidates = [
            candidate("agent-a", modifiedAgo: 30),
            candidate("agent-b", modifiedAgo: 20),
        ]

        XCTAssertEqual(match(candidates, [only])[only.id], .ambiguous(count: 2))
    }

    /// More than two is the same refusal, and the count must still say how many — a
    /// diagnostic that reports "ambiguous" for both two and twenty is not a diagnostic.
    func testManyCandidatesReportTheirCount() {
        let only = session(60)
        let candidates = (0..<5).map { candidate("agent-\($0)", modifiedAgo: 10) }

        XCTAssertEqual(match(candidates, [only])[only.id], .ambiguous(count: 5))
    }

    // MARK: - The rule that was missing: one file, many sessions

    /// **The same log claimed by three sessions belongs to none of them.** This is the
    /// defect the per-session version had: with every session's window running to *now*,
    /// one continuously-written conversation and three MCP connections made during it all
    /// contain the same file, so all three matched it and **the same tokens were recorded
    /// three times and priced three times** — a number where an absence belonged, and one
    /// nothing downstream could catch, because the fold keys on `sessionID` and each copy
    /// looked like distinct work.
    ///
    /// `count: 1` on each: one file, and it is not this session's alone.
    func testOneFileClaimedByThreeSessionsIsAmbiguousForAllThree() {
        let shared = candidate("shared", modifiedAgo: 30)
        let sessions = [session(60), session(120), session(180)]

        let result = match([shared], sessions)

        XCTAssertEqual(
            Set(result.values), [.ambiguous(count: 1)],
            "a file three sessions can claim must produce three refusals and no figure"
        )
    }

    /// The pass-level shape of the same thing, stated as the number it prevents: a
    /// session that has *already* been written to must not gain a second, identical
    /// reading of the same conversation.
    func testOneFileAndSeveralOverlappingSessionsYieldsNoMatchForAnyOfThem() {
        let shared = candidate("shared", modifiedAgo: 5)
        let sessions = (0..<5).map { session(Double($0) * 60) }

        let result = match([shared], sessions)

        XCTAssertEqual(sessions.count, 5)
        XCTAssertTrue(
            result.values.allSatisfy { $0 != .unique(shared) },
            "not one of five sessions may be handed the same conversation"
        )
        XCTAssertEqual(Set(result.values), [.ambiguous(count: 1)])
    }

    /// Contention is counted **per file**, against every session whose window reaches it.
    /// A session with exactly one candidate is still refused when another session's
    /// window reaches that same file — and because the windows nest, that is the common
    /// case for anything written recently. A per-session rule called this a match.
    func testAFileAnotherSessionCanAlsoSeeIsContestedEvenWithOneCandidate() {
        let live = candidate("live", modifiedAgo: 30)
        let stale = candidate("stale", modifiedAgo: 60 * 60 * 2)
        let older = session(60 * 60 * 3)
        let newer = session(30)

        let result = match([live, stale], [older, newer])

        // The older session sees both files: over-determined on its own account.
        XCTAssertEqual(result[older.id], .ambiguous(count: 2))
        // The newer one sees exactly one, and it is still not its own alone.
        XCTAssertEqual(result[newer.id], .ambiguous(count: 1))
    }

    // MARK: - Contention is not exclusivity

    /// **One session with a file and another with none: the first still wins.** The rule
    /// is that a file several sessions could claim belongs to none of them — not that a
    /// session is ambiguous whenever the store holds any other session. Refusing here
    /// would refuse a genuine match because an unrelated connection existed, which is
    /// the absence costing more than it should.
    func testAFileOnlyOneSessionCanSeeStillMatches() {
        let oldLog = candidate("old", modifiedAgo: 60 * 60 * 5)
        // Six hours and two hours ago, against a one-hour overlap: the five-hour-old file
        // is inside the older session's window and outside the newer one's.
        let older = session(60 * 60 * 6)
        let newer = session(60 * 60 * 2)

        let result = match([oldLog], [older, newer])

        XCTAssertEqual(result[older.id], .unique(oldLog))
        XCTAssertEqual(result[newer.id], .ambiguous(count: 0))
    }

    /// Sessions that can see nothing do not disturb the one that can.
    ///
    /// Both bystanders are **newer** than the owner, and that is not a convenience: a
    /// session older than the owner would have a window reaching further back, so it
    /// would see the same file and contend for it. A file that only one session can see
    /// is only visible to the oldest session whose window reaches it — the rule's shape,
    /// not a detail of this fixture.
    func testSessionsThatCanSeeNothingDoNotDisturbTheOneThatCan() {
        let file = candidate("only", modifiedAgo: 60 * 60 * 5)
        let owner = session(60 * 60 * 6)
        let recent = session(1)
        let older = session(60 * 60 * 2)

        let result = match([file], [owner, recent, older])

        XCTAssertEqual(result[owner.id], .unique(file))
        XCTAssertEqual(result[recent.id], .ambiguous(count: 0))
        XCTAssertEqual(result[older.id], .ambiguous(count: 0))
    }

    // MARK: - The window does the excluding

    /// A file outside the window is not a candidate, so it cannot make a match ambiguous
    /// either. This is why the count is computed after filtering: a month-old log on the
    /// machine must not turn one live agent's figure into a refusal.
    ///
    /// The sharpest form of the claim — one file in, one file out — because a rule that
    /// counted before filtering would answer `.ambiguous(count: 2)` here.
    func testACandidateOutsideTheWindowIsExcludedRatherThanCounted() {
        let live = candidate("live", modifiedAgo: 30)
        let ancient = candidate("ancient", modifiedAgo: 90 * 24 * 3600)
        let only = session(120)

        XCTAssertEqual(match([live, ancient], [only])[only.id], .unique(live))
    }

    /// Both bounds, because "outside the window" is two places: a log written before the
    /// session and one written after it are both outside, and a rule that checked only
    /// the lower bound would happily match a file stamped in the future by a machine
    /// with a wrong clock.
    func testAFutureCandidateIsExcludedToo() {
        let live = candidate("live", modifiedAgo: 30)
        let fromTheFuture = candidate("future", modifiedAgo: -(overlap + 60))
        let only = session(120)

        XCTAssertEqual(match([live, fromTheFuture], [only])[only.id], .unique(live))
    }

    /// Zero-width overlap: the window is the session's own instant, so only a file
    /// written exactly then matches. Exists to pin that `overlap` is applied to *both*
    /// sides of the comparison rather than added once by accident.
    func testZeroOverlapMatchesOnlyTheSessionInstantItself() {
        let only = (id: UUID(), connectedAt: now)
        let near = LogCandidate(
            url: URL(fileURLWithPath: "/logs/near.jsonl"), modifiedAt: now.addingTimeInterval(-1)
        )

        let result = AgentLogMatcher.match([near], for: [only], overlap: 0, now: now)

        XCTAssertEqual(result[only.id], .ambiguous(count: 0))
    }

    /// The same url listed twice is one file, not two. Without the dedupe a duplicate
    /// would both inflate a session's own count and register as contention against a
    /// session that has nothing to do with it — turning one unreadable file into two
    /// absences instead of one.
    func testTheSameFileListedTwiceCountsOnce() {
        let url = URL(fileURLWithPath: "/logs/same.jsonl")
        let duplicates = [
            LogCandidate(url: url, modifiedAt: now.addingTimeInterval(-30)),
            LogCandidate(url: url, modifiedAt: now.addingTimeInterval(-20)),
        ]
        let only = session(60)

        XCTAssertEqual(match(duplicates, [only])[only.id], .unique(duplicates[0]))
    }
}
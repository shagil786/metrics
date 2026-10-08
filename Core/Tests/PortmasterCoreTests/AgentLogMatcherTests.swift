// The matching rule, with no filesystem anywhere in the file.
//
// "Which conversation was this connection part of?" is the decision every figure in this
// feature rests on, and the wrong answer to it is a *number* rather than an absence.
// Getting it wrong is also easy: a directory walk in the way means a test that catches it
// has to write files, set timestamps and hope the clock cooperates. So the rule is here,
// taking two values and touching nothing.
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

    private func session(_ connectedAgo: TimeInterval, id: UUID = UUID())
        -> (id: UUID, connectedAt: Date)
    {
        (id: id, connectedAt: now.addingTimeInterval(-connectedAgo))
    }

    /// A conversation written between `fromAgo` and `toAgo` seconds before `now`.
    private func conversation(_ name: String, fromAgo: TimeInterval, toAgo: TimeInterval)
        -> LogCandidate
    {
        LogCandidate(
            url: URL(fileURLWithPath: "/logs/\(name).jsonl"),
            interval: LogInterval(
                start: now.addingTimeInterval(-fromAgo),
                end: now.addingTimeInterval(-toAgo),
            )
        )
    }

    /// A conversation with no interval at all — nothing said when it was written.
    private func unplaceable(_ name: String) -> LogCandidate {
        LogCandidate(url: URL(fileURLWithPath: "/logs/\(name).jsonl"), interval: nil)
    }

    private func match(
        _ candidates: [LogCandidate], _ sessions: [(id: UUID, connectedAt: Date)]
    ) -> [UUID: LogMatch] {
        AgentLogMatcher.match(candidates, for: sessions, overlap: overlap, now: now)
    }

    // MARK: - The one case that becomes a number

    /// A connection made **during** a conversation, and the only one that was. The only
    /// shape `LogMatch.unique` has.
    func testOneConversationSpanningTheConnectionIsAMatch() {
        let theConnection = session(2700)
        let theConversation = conversation("in-progress", fromAgo: 3600, toAgo: 1800)

        XCTAssertEqual(match([theConversation], [theConnection])[theConnection.id],
                       .unique(theConversation))
    }

    /// A connection at either extreme of the conversation — its first line and its last —
    /// is inside it. The ends are where a real connection lands: the agent starts, then
    /// Portmaster connects; the agent's last line, then the connection closes.
    func testAConnectionAtEitherEndOfTheConversationIsInside() {
        let conversation = conversation("edge", fromAgo: 3600, toAgo: 1800)

        for edge in [3600.0, 1800.0] {
            let atEnd = session(edge)
            XCTAssertEqual(match([conversation], [atEnd])[atEnd.id], .unique(conversation),
                           "a connection exactly at an end is inside, not outside")
        }
    }

    /// The tolerance pads the **conversation**, because that is the uncertain end of it:
    /// the first line is written after the agent started and the last before the
    /// connection closed. A connection a little outside the logged span can still be the
    /// same conversation, and the log not having said so is not evidence against it.
    func testTheTolerancePadsTheConversationsEnds() {
        let conversation = conversation("padded", fromAgo: 3600, toAgo: 1800)
        // 30 minutes before the first line and 30 minutes after the last, against a
        // one-hour tolerance.
        let before = session(3600 + 1800)
        let after = session(1800 - 1800)

        XCTAssertEqual(match([conversation], [before])[before.id], .unique(conversation))
        XCTAssertEqual(match([conversation], [after])[after.id], .unique(conversation))
    }

    // MARK: - Nothing to read

    /// No conversation spans this connection. `count: 0` is carried so a caller can say
    /// "nothing to read" rather than "too much to choose between" — two different facts
    /// about the machine that a single optional would have merged.
    func testNoConversationSpanningTheConnectionIsAmbiguousWithZero() {
        let theConnection = session(2700)

        XCTAssertEqual(match([], [theConnection])[theConnection.id], .ambiguous(count: 0))
    }

    /// Every session asked gets an entry, including the ones with no conversation
    /// spanning them. The caller records an absence per session per source, so a session
    /// missing from the result would silently skip its `noSource` rather than report it.
    func testEverySessionAskedGetsAnAnswer() {
        let a = session(2700)
        let b = session(5400)
        let c = session(60)

        XCTAssertEqual(Set(match([], [a, b, c]).keys), [a.id, b.id, c.id])
    }

    /// **The fix.** A connection from before the conversation happened is not inside it,
    /// and does not match.
    ///
    /// Under the rule this replaces — *is the file's last write inside the connection's
    /// window, where the window runs to now* — yesterday's connection matched a
    /// conversation that ended an hour ago, because every historical session's window
    /// reached forward to today and contained the log's last write. That is what made the
    /// feature near-inert: every past session claimed the one live file, the one-to-one
    /// rule below called the contention, and nobody matched.
    func testAConnectionFromBeforeTheConversationDoesNotMatch() {
        let conversation = conversation("last-hour", fromAgo: 3600, toAgo: 0)
        // A whole day earlier: far outside the tolerance, and squarely before the
        // conversation began.
        let yesterday = session(86_400)

        XCTAssertEqual(match([conversation], [yesterday])[yesterday.id], .ambiguous(count: 0))
    }

    /// The same claim at a finer grain: a connection before the first line is outside once
    /// it is more than the tolerance earlier, which is the boundary the rule draws.
    ///
    /// Two hours before, against a one-hour tolerance. The name says two hours because the
    /// fixture is two hours — an earlier version of this test was called
    /// `testAConnectionMinutesBeforeTheFirstLine…` while asserting `1800 + 7200`, and a
    /// test that does not test what its name says is worse than no test, because it
    /// silences the question it appears to ask.
    func testAConnectionTwoHoursBeforeTheFirstLineDoesNotMatch() {
        let conversation = conversation("later", fromAgo: 1800, toAgo: 900)
        let before = session(1800 + 7200)

        XCTAssertEqual(match([conversation], [before])[before.id], .ambiguous(count: 0))
    }

    /// **The other side of that boundary, and the cost of the padding.** Forty-five
    /// minutes before the first line is *inside* an hour of tolerance, so it matches — and
    /// is then billed for the whole conversation, including the part before it arrived.
    /// The tolerance is what makes a real connection matchable at all, and this is what it
    /// charges for it.
    func testAConnectionInsideTheMarginBeforeTheFirstLineStillMatches() {
        let conversation = conversation("early", fromAgo: 3600, toAgo: 1800)
        let insideTheMargin = session(3600 + 45 * 60)

        XCTAssertEqual(match([conversation], [insideTheMargin])[insideTheMargin.id],
                       .unique(conversation))
    }

    /// **And the margin is itself a contention source.** Two connections 40 and 59 minutes
    /// before one conversation's first line both fall inside the hour this adds, so both
    /// contend and neither matches — while the same two connections an hour apart are
    /// cleanly decidable. Widening the tolerance to catch more real matches widens the band
    /// in which no match is possible.
    func testTheMarginIsItselfAContentionSource() {
        let conversation = conversation("opening", fromAgo: 3600, toAgo: 1800)
        let fortyMinutesIn = session(3600 + 40 * 60)
        let fiftyNineMinutesIn = session(3600 + 59 * 60)

        let result = match([conversation], [fortyMinutesIn, fiftyNineMinutesIn])

        XCTAssertEqual(Set(result.values), [.ambiguous(count: 1)])
    }

    /// A connection from after the conversation ended, far enough past the tolerance.
    func testAConnectionFromAfterTheConversationDoesNotMatch() {
        let conversation = conversation("yesterday", fromAgo: 90_000, toAgo: 86_400)
        let today = session(0)

        XCTAssertEqual(match([conversation], [today])[today.id], .ambiguous(count: 0))
    }

    /// **A conversation that could not be placed matches nobody.** A log with no line
    /// timestamps — or one that could be read but not understood — gives nothing that can
    /// say whether this connection was inside it. It is still returned to the caller, so
    /// "a log exists here and cannot be placed" is visible to a diagnostic, but a claim it
    /// cannot support is the one thing this module never makes. The file's modification
    /// time would place it, and is deliberately not used: that is a point where a span is
    /// wanted, and padding one into a window rebuilt the rule this replaced.
    func testACandidateWithNoIntervalMatchesNobody() {
        let theConnection = session(60)
        let lonely = unplaceable("nowhere")

        let result = match([lonely], [theConnection])

        XCTAssertEqual(result[theConnection.id], .ambiguous(count: 0))
    }

    /// …and it does not make a genuine match ambiguous either. A file nobody can place
    /// must not take a figure down with it.
    func testAnUnplaceableCandidateDoesNotContendWithAGenuineOne() {
        let theConnection = session(2700)
        let real = conversation("real", fromAgo: 3600, toAgo: 1800)

        XCTAssertEqual(match([unplaceable("nowhere"), real], [theConnection])[theConnection.id],
                       .unique(real))
    }

    // MARK: - More than one conversation

    /// **Two conversations spanning one connection is not a tie to break.** Taking one
    /// would be a guess dressed as a finding, and the number it produces would look
    /// exactly like a real figure to everything downstream.
    func testTwoConversationsSpanningOneConnectionAreAmbiguous() {
        let theConnection = session(2700)
        let candidates = [
            conversation("agent-a", fromAgo: 3600, toAgo: 1800),
            conversation("agent-b", fromAgo: 3400, toAgo: 1900),
        ]

        XCTAssertEqual(match(candidates, [theConnection])[theConnection.id],
                       .ambiguous(count: 2))
    }

    /// More than two is the same refusal, and the count must still say how many — a
    /// diagnostic that reports "ambiguous" for both two and twenty is not a diagnostic.
    func testManyConversationsReportTheirCount() {
        let theConnection = session(2700)
        let candidates = (0..<5).map {
            conversation("agent-\($0)", fromAgo: 3600 + Double($0), toAgo: 1800)
        }

        XCTAssertEqual(match(candidates, [theConnection])[theConnection.id],
                       .ambiguous(count: 5))
    }

    /// One conversation spanning a connection and a second that is nowhere near it: the
    /// second must not turn the first into a refusal. A candidate is judged on whether it
    /// spans, not on existing.
    func testAConversationThatDoesNotSpanTheConnectionDoesNotCount() {
        let theConnection = session(2700)
        let during = conversation("during", fromAgo: 3600, toAgo: 1800)
        let lastWeek = conversation("last-week", fromAgo: 700_000, toAgo: 690_000)

        XCTAssertEqual(match([during, lastWeek], [theConnection])[theConnection.id],
                       .unique(during))
    }

    // MARK: - Two connections inside one conversation still contend

    /// **The one-to-one rule survives the interval rule.** Two MCP connections opened
    /// during one conversation both sit inside it, so each is genuinely a candidate and
    /// neither may win. The interval rule makes most cases decidable; it does not make
    /// contention impossible, and this is the case that remains.
    func testTwoConnectionsInsideOneConversationBothRefuse() {
        let conversation = conversation("shared", fromAgo: 3600, toAgo: 1800)
        let first = session(3300)
        let second = session(2100)

        let result = match([conversation], [first, second])

        XCTAssertEqual(
            Set(result.values), [.ambiguous(count: 1)],
            "one conversation, two connections inside it: neither may be handed a figure"
        )
    }

    /// Five connections during one conversation is the same refusal, five times over, and
    /// it is the shape that used to multiply one conversation's tokens across five
    /// sessions.
    func testFiveConnectionsInsideOneConversationProduceNoMatchForAnyOfThem() {
        let conversation = conversation("shared", fromAgo: 3600, toAgo: 1800)
        let connections = (0..<5).map { session(3300 - Double($0) * 300) }

        let result = match([conversation], connections)

        XCTAssertEqual(connections.count, 5)
        XCTAssertTrue(
            result.values.allSatisfy { $0 != .unique(conversation) },
            "not one of five connections may be handed the same conversation"
        )
        XCTAssertEqual(Set(result.values), [.ambiguous(count: 1)])
    }

    /// Contention is counted **per conversation**, against every connection that falls
    /// inside it — and a connection with exactly one conversation spanning it is still
    /// refused when another connection sits inside the same one.
    func testContentionIsPerConversationNotPerPass() {
        let shared = conversation("shared", fromAgo: 3600, toAgo: 1800)
        let other = conversation("other", fromAgo: 87_000, toAgo: 86_400)
        let firstInside = session(3300)
        let secondInside = session(2100)
        let farAway = session(86_700)

        let result = match([shared, other], [firstInside, secondInside, farAway])

        XCTAssertEqual(result[firstInside.id], .ambiguous(count: 1),
                       "two connections fall inside `shared`, so neither has it")
        XCTAssertEqual(result[secondInside.id], .ambiguous(count: 1))
        // Contention is counted per conversation: the third connection is inside `other`
        // and nobody else's, which is unaffected by what the other two are doing.
        XCTAssertEqual(result[farAway.id], .unique(other), "and the far one is his alone")
    }

    // MARK: - Contention is not exclusivity

    /// **Two conversations and two connections, one each, both match.** The rule is that
    /// a conversation several connections could claim belongs to none of them — not that a
    /// connection is ambiguous whenever the store holds more than one connection. The
    /// matcher can still do the ordinary thing, which is the point of matching on the
    /// interval rather than on the file's freshness.
    func testTwoConnectionsInTwoSeparateConversationsBothMatch() {
        // A day apart, not an hour: the tolerance pads each conversation by an hour, so
        // conversations closer together than twice that share everything.
        let older = conversation("older", fromAgo: 90_000, toAgo: 86_400)
        let newer = conversation("newer", fromAgo: 3600, toAgo: 3400)
        let first = session(88_000)
        let second = session(3500)

        let result = match([older, newer], [first, second])

        XCTAssertEqual(result[first.id], .unique(older))
        XCTAssertEqual(result[second.id], .unique(newer))
    }

    /// A third connection that falls inside neither conversation changes nothing for the
    /// two that do.
    func testAConnectionInsideNeitherConversationDoesNotDisturbTheOnesThatDo() {
        let during = conversation("during", fromAgo: 3600, toAgo: 1800)
        let owner = session(2700)
        // Both well outside the conversation's padded hour — a connection a minute ago
        // would be *inside* it, which is the rule working and not an exception to it.
        let recent = session(20_000)
        let ancient = session(200_000)

        let result = match([during], [owner, recent, ancient])

        XCTAssertEqual(result[owner.id], .unique(during))
        XCTAssertEqual(result[recent.id], .ambiguous(count: 0))
        XCTAssertEqual(result[ancient.id], .ambiguous(count: 0))
    }

    // MARK: - The clock

    /// A conversation stamped entirely after `now` is a clock artefact — a restored
    /// backup, a wrong machine clock — and a session row sharing that skew would "match"
    /// it, attributing a conversation to a connection that cannot have happened. This is
    /// why `now` is a parameter at all.
    func testAConversationWhollyInTheFutureMatchesNobody() {
        let future = LogInterval(
            start: now.addingTimeInterval(7200), end: now.addingTimeInterval(9000)
        )
        let skewed = LogCandidate(url: URL(fileURLWithPath: "/logs/skewed.jsonl"), interval: future)
        let alsoSkewed = (id: UUID(), connectedAt: now.addingTimeInterval(8000))

        XCTAssertEqual(match([skewed], [alsoSkewed])[alsoSkewed.id], .ambiguous(count: 0))
    }

    // MARK: - Identity

    /// The same url listed twice is one conversation, not two. Without the dedupe a
    /// duplicate would both inflate a connection's own count and register as contention
    /// against a connection that has nothing to do with it — turning one unreadable file
    /// into two absences instead of one.
    func testTheSameConversationListedTwiceCountsOnce() {
        let url = URL(fileURLWithPath: "/logs/same.jsonl")
        let duplicates = [
            LogCandidate(url: url, interval: LogInterval(
                start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800))),
            LogCandidate(url: url, interval: LogInterval(
                start: now.addingTimeInterval(-3500), end: now.addingTimeInterval(-1700))),
        ]
        let theConnection = session(2700)

        XCTAssertEqual(match(duplicates, [theConnection])[theConnection.id],
                       .unique(duplicates[0]))
    }
}
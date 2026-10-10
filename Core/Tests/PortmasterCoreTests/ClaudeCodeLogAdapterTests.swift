import XCTest
@testable import PortmasterCore

/// Tests for the first production adapter.
///
/// The fixtures are the shapes a real Claude Code log was observed to contain, not
/// shapes invented for convenience — including one taken from an actual summary line
/// with its real model name and real fractional cost. An adapter tested only against
/// tidy data it chose itself proves nothing about the file it will meet.
final class ClaudeCodeLogAdapterTests: XCTestCase {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("proj", isDirectory: true),
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func writeLog(_ json: String, in root: URL, name: String, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent("proj/\(name).jsonl")
        try json.write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    /// A real summary line, from an actual session log: a model whose name is not a
    /// public model id, fractional output, and cost fields this adapter must ignore.
    private let realSummary = """
    {"hasUnknownModelCost":false,"modelUsage":{"claude-fable-5":{"inputTokens":0,"outputTokens":16739,"thinkingTokens":0,"cacheReadInputTokens":0,"cacheCreationInputTokens":0,"webSearchRequests":0,"costUSD":0.8369500000000002}},"sessionId":"b8f0237e-ec68-4623-9504-daf0ef4a18fc","startTime":"2026-09-30T12:00:00.000Z","totalAPIDuration":1234,"totalCostUSD":0.8369500000000002,"totalDuration":99999,"totalLinesAdded":10,"totalLinesRemoved":2}
    """

    /// The shape a real log's timestamps have: `"timestamp":"…"` at a fixed offset,
    /// interleaved with lines that carry none — 354 of this machine's 423 lines do.
    ///
    /// The first and last stamps are the ones this file actually contains, taken from it,
    /// because the whole interval rule rests on reading a span out of a real file rather
    /// than a span invented for a test.
    private let timestampedLog = """
    {"type":"queue-operation","operation":"enqueue","timestamp":"2026-10-03T22:31:52.452Z","sessionId":"b8f0237e-ec68-4623-9504-daf0ef4a18fc","content":"add skill"}
    {"type":"queue-operation","operation":"dequeue","timestamp":"2026-10-03T22:31:52.457Z","sessionId":"b8f0237e-ec68-4623-9504-daf0ef4a18fc"}
    {"type":"mode","mode":"normal","sessionId":"b8f0237e-ec68-4623-9504-daf0ef4a18fc"}
    {"modelUsage":{"claude-fable-5":{"inputTokens":0,"outputTokens":16739,"thinkingTokens":0}}}
    {"type":"assistant","uuid":"3bdf1e0d-0f7a-4b18-a657-7b2aaca8fca6","timestamp":"2026-10-03T22:58:30.007Z"}
    {"type":"last-prompt","lastPrompt":"Try again","leafUuid":"3bdf1e0d-0f7a-4b18-a657-7b2aaca8fca6"}
    """

    /// `2026-10-03T22:31:52.452Z` and `2026-10-03T22:58:30.007Z`, as `Date`s. Written
    /// out rather than parsed by the code under test, so a bug in the parser cannot make
    /// the assertion agree with itself.
    private static let conversationStart = Date(timeIntervalSince1970: 1_791_066_712.452)
    private static let conversationEnd = Date(timeIntervalSince1970: 1_791_068_310.007)

    // MARK: - Parsing

    func testParsesTheRealSummaryLine() throws {
        let root = try makeRoot()
        let url = try writeLog(realSummary, in: root, name: "real")
        let parsed = try ClaudeCodeLogAdapter(projectsRoot: root).parse(url)

        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.modelID, "claude-fable-5")
        XCTAssertEqual(parsed.first?.input, 0)
        XCTAssertEqual(parsed.first?.output, 16739)
        // Zero reasoning tokens is a real zero, not an unknown, so it must not become
        // an optional.
        XCTAssertNil(parsed.first?.reasoning)
        XCTAssertNil(parsed.first?.cacheRead)
    }

    /// The whole point of reading this format: a session that escalated models has a
    /// per-model breakdown, and collapsing it to one entry would price the first
    /// model's tokens at the second model's rate.
    func testEscalatedModelsParseAsSeparateEntries() throws {
        let root = try makeRoot()
        let url = try writeLog("""
        {"modelUsage":{"model-a":{"inputTokens":100,"outputTokens":50,"thinkingTokens":0},"model-b":{"inputTokens":200,"outputTokens":75,"thinkingTokens":10}}}
        """, in: root, name: "escalated")

        let parsed = try ClaudeCodeLogAdapter(projectsRoot: root).parse(url)
        XCTAssertEqual(parsed.map(\.modelID), ["model-a", "model-b"])
        XCTAssertEqual(parsed.first?.input, 100)
        XCTAssertEqual(parsed.last?.output, 75)
        XCTAssertEqual(parsed.last?.reasoning, 10)
    }

    /// Totals are cumulative, so a file that reports the same figures on several lines
    /// must yield one set of figures, not their sum. This is the property that makes
    /// re-running the adapter idempotent.
    func testCumulativeLinesAreNotSummed() throws {
        let root = try makeRoot()
        let url = try writeLog("""
        {"modelUsage":{"model-a":{"inputTokens":100,"outputTokens":50}}}
        {"modelUsage":{"model-a":{"inputTokens":100,"outputTokens":50}}}
        {"modelUsage":{"model-a":{"inputTokens":100,"outputTokens":50}}}
        """, in: root, name: "cumulative")

        let parsed = try ClaudeCodeLogAdapter(projectsRoot: root).parse(url)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.input, 100)
        XCTAssertEqual(parsed.first?.output, 50)
    }

    /// Most lines in a real log carry nothing about usage at all. They must be skipped
    /// silently rather than failing the parse.
    func testUnrelatedLinesAreSkipped() throws {
        let root = try makeRoot()
        let url = try writeLog("""
        {"type":"user","message":{"role":"user","content":"hello"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}
        \(realSummary)
        """, in: root, name: "mixed")

        let parsed = try ClaudeCodeLogAdapter(projectsRoot: root).parse(url)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.output, 16739)
    }

    /// The known-unsound shape: a format change must be *refused*, not read as zero.
    func testFormatChangeIsRefusedNotReadAsZero() throws {
        let root = try makeRoot()
        let url = try writeLog("""
        {"totals":{"promptTokens":10,"completionTokens":20}}
        """, in: root, name: "changed")

        XCTAssertThrowsError(try ClaudeCodeLogAdapter(projectsRoot: root).parse(url)) { error in
            XCTAssertEqual(error as? TokenSourceError, .unrecognizedFormat)
        }
    }

    func testEmptyLogIsRefused() throws {
        let root = try makeRoot()
        let url = try writeLog("", in: root, name: "empty")
        XCTAssertThrowsError(try ClaudeCodeLogAdapter(projectsRoot: root).parse(url)) { error in
            XCTAssertEqual(error as? TokenSourceError, .unrecognizedFormat)
        }
    }

    func testMissingFileIsUnreadable() throws {
        let root = try makeRoot()
        let missing = root.appendingPathComponent("nope.jsonl")
        XCTAssertThrowsError(try ClaudeCodeLogAdapter(projectsRoot: root).parse(missing)) { error in
            XCTAssertEqual(error as? TokenSourceError, .unreadable)
        }
    }

    // MARK: - Context pressure

    /// The one untested link: this adapter's `contextPressure` hands a real log to the
    /// extractor, and the extractor's own tests never reach it. A reminder line in the
    /// shape Claude Code writes must come back as a reading, and the word `Infinite`
    /// must come back as no reading at all.
    func testAReminderLineProducesAReadingAndInfiniteDoesNot() throws {
        let root = try makeRoot()
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let url = try writeLog("""
        {"type":"user","content":"go"}
        {"type":"attachment","attachment":{"type":"total_tokens_reminder","text":"<total_tokens>14999357 tokens left</total_tokens>"},"timestamp":"2026-10-03T22:31:52.569Z"}
        """, in: root, name: "reminder")
        XCTAssertEqual(
            adapter.contextPressure(at: url),
            PressureReading(tokensLeft: 14_999_357, lineNumber: 2)
        )

        let infinite = try writeLog(
            #"{"type":"attachment","attachment":{"type":"total_tokens_reminder","text":"<total_tokens>Infinite tokens left</total_tokens>"}}"#,
            in: root, name: "infinite"
        )
        XCTAssertNil(adapter.contextPressure(at: infinite),
                     "a non-numeric rendering is an absence, never a zero")
    }

    // MARK: - Candidate matching

    /// A session, in the two-column form matching consumes.
    private func session(now: Date, connectedAgo: TimeInterval, id: UUID = UUID())
        -> (id: UUID, connectedAt: Date)
    {
        (id: id, connectedAt: now.addingTimeInterval(-connectedAgo))
    }

    /// The production path in one call: enumerate through the adapter, then match.
    private func run(
        adapter: ClaudeCodeLogAdapter, sessions: [(id: UUID, connectedAt: Date)], now: Date
    ) -> [UUID: LogMatch] {
        AgentLogMatcher.match(
            adapter.logCandidates(), for: sessions, overlap: overlap, now: now
        )
    }

    /// The window the poller configures, so these tests exercise the same overlap
    /// production uses rather than a number chosen for the fixture.
    private let overlap: TimeInterval = 60 * 60

    /// Every log in a fixture tree, unfiltered — the enumeration half on its own, so a
    /// test about what the adapter *reads* does not also depend on the matcher.
    private func found(_ root: URL) -> [LogCandidate] {
        ClaudeCodeLogAdapter(projectsRoot: root).logCandidates(newerThan: nil)
    }

    /// A connection made at an absolute instant, for placing one inside a conversation
    /// whose own times are absolute too.
    private func connected(_ at: Date) -> (id: UUID, connectedAt: Date) {
        (id: UUID(), connectedAt: at)
    }

    /// `logCandidates()` enumerates, and age is not its question: it is handed no
    /// session, so it has nothing to measure a file's age against. Every log in the tree
    /// comes back, and dropping the old ones is `AgentLogMatcher`'s job — which is the
    /// job that has the connection it would be dropped against.
    func testLogCandidatesReturnsEveryLogInTheTreeAtAnyAge() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "live", modified: now.addingTimeInterval(-30))
        try writeLog(realSummary, in: root, name: "ancient", modified: now.addingTimeInterval(-90 * 24 * 3600))

        let candidates = found(root)
        XCTAssertEqual(candidates.map(\.url.lastPathComponent), ["ancient.jsonl", "live.jsonl"])
        // Both are listed — age is the matcher's question — and neither is *placed*, since
        // `realSummary` carries no line timestamp. Listed-and-unplaced is the honest shape
        // for a log nothing can put in time.
        XCTAssertTrue(candidates.allSatisfy { $0.interval == nil })
    }

    // MARK: - Where the interval comes from

    /// **The interval is read out of the log's own lines, not off the filesystem.**
    ///
    /// The file is written with a modification time three months away from its contents
    /// on purpose, so the assertion cannot be satisfied by the fallback. This is the whole
    /// ruling: `mtime` says when the file was last touched, which places nothing inside a
    /// conversation, and only the log's own timestamps can say a connection fell during
    /// it.
    func testTheIntervalIsReadFromTheLogsOwnLineTimestamps() throws {
        let root = try makeRoot()
        let written = Date().addingTimeInterval(-90 * 24 * 3600)
        try writeLog(timestampedLog, in: root, name: "conversation", modified: written)

        let candidate = try XCTUnwrap(found(root).first)
        let interval = try XCTUnwrap(candidate.interval)

        XCTAssertEqual(
            interval.start.timeIntervalSince1970,
            Self.conversationStart.timeIntervalSince1970, accuracy: 0.002
        )
        XCTAssertEqual(
            interval.end.timeIntervalSince1970,
            Self.conversationEnd.timeIntervalSince1970, accuracy: 0.002
        )
        // And not the mtime the file was deliberately given. **Asserted as a difference
        // from the offset this test chose**, rather than against a fixed instant: an
        // earlier version pinned a hardcoded epoch, and around 2027-01-02 the two coincide
        // and the assertion starts failing for a reason that has nothing to do with the
        // code under it.
        XCTAssertGreaterThan(
            abs(interval.start.timeIntervalSince(written)), 60 * 24 * 3600,
            "the interval came from the log's lines, not from the file's mtime"
        )
    }

    /// **Min and max, not first line and last line.** This file has six timestamp pairs
    /// written out of order, so a scanner taking the first line's stamp as the start would
    /// be reporting an interval the log does not claim. Every line is read and the true
    /// extremes taken, which is why this is not a head-only read.
    func testOutOfOrderLinesDoNotShrinkTheInterval() throws {
        let root = try makeRoot()
        try writeLog("""
        {"type":"assistant","timestamp":"2026-10-03T22:40:00.000Z"}
        {"type":"mode","mode":"normal"}
        {"type":"assistant","timestamp":"2026-10-03T22:31:52.452Z"}
        {"type":"assistant","timestamp":"2026-10-03T22:58:30.007Z"}
        {"type":"assistant","timestamp":"2026-10-03T22:35:00.000Z"}
        """, in: root, name: "jumbled")

        let interval = try XCTUnwrap(
            ClaudeCodeLogAdapter(projectsRoot: root).logCandidates(newerThan: nil).first?.interval
        )

        XCTAssertEqual(
            interval.start.timeIntervalSince1970,
            Self.conversationStart.timeIntervalSince1970, accuracy: 0.002,
            "22:31 is on the third line, not the first"
        )
        XCTAssertEqual(
            interval.end.timeIntervalSince1970,
            Self.conversationEnd.timeIntervalSince1970, accuracy: 0.002
        )
    }

    /// **A log with no line timestamps is not placed at all.**
    ///
    /// The real observed summary line is exactly this shape — a `modelUsage` line with no
    /// `timestamp` — so the refusal is not hypothetical. The file is *still listed*, so a
    /// diagnostic can see that a log exists here and cannot be placed; what it cannot do is
    /// match anything.
    ///
    /// **Why no fallback to the modification time.** There was one, and it was removed: a
    /// point where a span is wanted cannot answer a containment question, and the only way
    /// to make it answer was to pad it — at which point a `±1h` window built from one
    /// filesystem timestamp was reporting `.unique` confidently. That is the rule this
    /// whole change replaced, rebuilt inside the new code. It could not be carried as
    /// weaker evidence either: `TokenUsageRecord` has no column for it and adding one is a
    /// schema migration.
    func testALogWithNoLineTimestampsIsListedButNotPlaced() throws {
        let root = try makeRoot()
        try writeLog(realSummary, in: root, name: "no-stamps", modified: Date().addingTimeInterval(-45 * 60))

        let candidates = found(root)

        XCTAssertEqual(candidates.count, 1, "a log here that cannot be placed is still visible")
        XCTAssertNil(candidates.first?.interval)
    }

    /// …and the matcher refuses it, rather than matching a point padded into a window.
    func testAnUnplacedLogMatchesNothingEvenWithAConnectionRightAtItsMtime() throws {
        let root = try makeRoot()
        let modified = Date().addingTimeInterval(-45 * 60)
        try writeLog(realSummary, in: root, name: "no-stamps", modified: modified)
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        // A connection at the file's own modification time — the most favourable moment
        // any fallback could be handed.
        let atItsMtime = session(now: Date(), connectedAgo: 45 * 60)
        XCTAssertEqual(
            run(adapter: adapter, sessions: [atItsMtime], now: Date())[atItsMtime.id],
            .ambiguous(count: 0),
            "one filesystem timestamp cannot place a connection inside a conversation"
        )
    }

    /// A `"timestamp"` key whose value is not a timestamp must not become one — and the
    /// fixture has to be able to fail, which the earlier version of this test could not.
    /// It used quoted prose inside a message body, where JSON's escaping means the marker
    /// bytes never appear at all; it would have passed with the parser replaced by
    /// `return 0`. A **nested** object with its own `timestamp` key does put the marker in
    /// the bytes, and its value is free to be anything.
    func testATimestampKeyWithANonTimestampValueIsNotReadAsOne() throws {
        let root = try makeRoot()
        try writeLog("""
        {"meta":{"timestamp":"last tuesday"},"type":"user"}
        {"nested":{"deeper":{"timestamp":null}},"type":"assistant"}
        {"modelUsage":{"claude-fable-5":{"inputTokens":0,"outputTokens":16739}}}
        """, in: root, name: "not-a-timestamp")

        let candidates = found(root)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates.first?.interval, "a key that looks right is not a timestamp")
    }

    /// **The key is found as a key, not as a fixed literal.** JSON-legal whitespace around
    /// the colon is legal, and matching `"timestamp":"` byte-for-byte dropped every
    /// timestamp in every file written that way — which is not one file failing to parse
    /// but the whole feature reverting to `mtime`, silently, with every test still green.
    func testJSONLegalWhitespaceAroundTheColonIsTolerated() throws {
        let root = try makeRoot()
        try writeLog("""
        { "type" : "assistant" , "timestamp" : "2026-10-03T22:31:52.452Z" }
        {"type":"assistant","timestamp":"2026-10-03T22:58:30.007Z"}
        """, in: root, name: "spaced")

        let interval = try XCTUnwrap(found(root).first?.interval)

        XCTAssertEqual(interval.start.timeIntervalSince1970,
                       Self.conversationStart.timeIntervalSince1970, accuracy: 0.002)
        XCTAssertEqual(interval.end.timeIntervalSince1970,
                       Self.conversationEnd.timeIntervalSince1970, accuracy: 0.002)
    }

    /// **Six or more fractional digits must not drop the timestamp.**
    ///
    /// The earlier parser stopped accumulating and left its cursor on a digit rather than
    /// on the `Z`, so the shape check rejected the whole value — and a log whose timestamps
    /// all carried six digits was unplaced, silently. Digits are now always consumed; only
    /// the arithmetic stops, at 100 ns.
    func testHighPrecisionTimestampsArePlacedNotRejected() throws {
        let root = try makeRoot()
        try writeLog("""
        {"type":"assistant","timestamp":"2026-10-03T22:31:52.452123789Z"}
        {"type":"assistant","timestamp":"2026-10-03T22:58:30.000000001Z"}
        {"type":"mode","mode":"normal"}
        """, in: root, name: "precise")

        let interval = try XCTUnwrap(found(root).first?.interval)

        XCTAssertEqual(interval.start.timeIntervalSince1970,
                       Self.conversationStart.timeIntervalSince1970, accuracy: 0.002)
        // 22:58:30 exactly: the trailing digits are all zeros, so the end of this
        // conversation is the whole second.
        XCTAssertEqual(interval.end.timeIntervalSince1970, 1_791_068_310, accuracy: 0.002)
    }

    /// **The precision the parser accepts, stated as a test.** Nine fractional digits are
    /// consumed and truncated at 100 ns, so the value is the instant to well under a
    /// microsecond — finer than anything this module prints. What it must never be is
    /// dropped, which is what the previous bound did.
    func testFractionalSecondsAreTruncatedRatherThanDropped() {
        let span = ClaudeCodeLogAdapter.lineTimestampSpan(
            in: Data(#"{"timestamp":"2026-10-03T22:31:52.452123456Z"}"#.utf8)
        )
        XCTAssertNotNil(span)
        // **Exactly six of the nine digits contribute** — `.452123` — and the remaining
        // three are consumed without contributing. That is the stated precision, and it is
        // a deliberate one: finer than 100 ns is finer than anything this module prints,
        // and consuming the rest without rejecting is what stops a high-precision log from
        // being unplaced.
        XCTAssertEqual(try XCTUnwrap(span).earliest,
                       Self.conversationStart.timeIntervalSince1970 + 0.000123,
                       accuracy: 1e-9)
    }

    /// **A year before 1970 is refused rather than computed.** It cannot occur in a log,
    /// and the branch that would have handled it subtracted a whole year *and* the current
    /// month, putting `1969-12-31T23:59:59Z` 365 days out — the one input here that
    /// produced a *wrong interval* rather than a fallback.
    func testAPre1970TimestampIsRefusedRatherThanMiscomputed() {
        let wrong = ClaudeCodeLogAdapter.lineTimestampSpan(
            in: Data(#"{"timestamp":"1969-12-31T23:59:59.000Z"}"#.utf8)
        )
        XCTAssertNil(wrong, "refused beats 365 days out")

        // And the epoch itself is exact, which is what the branch used to break.
        let origin = ClaudeCodeLogAdapter.lineTimestampSpan(
            in: Data(#"{"timestamp":"1970-01-01T00:00:00.000Z"}"#.utf8)
        )
        XCTAssertEqual(try XCTUnwrap(origin).earliest, 0)
    }

    /// **An offset-zone timestamp is refused, not read as UTC.** `+05:30` is legal JSON and
    /// legal ISO-8601; the shape check stops at the `Z`, so the value is dropped rather
    /// than silently five and a half hours out. The consequence is the whole file going
    /// unplaced, which is the honest direction and also the reason to say so here.
    func testAnOffsetZoneTimestampIsRefusedNotReadAsUTC() {
        XCTAssertNil(ClaudeCodeLogAdapter.lineTimestampSpan(
            in: Data(#"{"timestamp":"2026-10-03T22:31:52.452+05:30"}"#.utf8)
        ))
    }

    // MARK: - A connection, against a real interval

    /// The end-to-end shape of the ruling: a connection made **during** a conversation is
    /// that conversation's, even though the file's modification time is three months away
    /// from it — which is what a copied log, a restored backup, or a test fixture all look
    /// like, and what made matching on `mtime` the wrong question.
    func testAConnectionDuringTheConversationMatches() throws {
        let root = try makeRoot()
        try writeLog(timestampedLog, in: root, name: "conversation",
                     modified: Date().addingTimeInterval(-90 * 24 * 3600))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        // A connection at 22:40, inside 22:31:52 – 22:58:30.
        let during = connected(Self.conversationStart.addingTimeInterval(500))

        guard case .unique(let candidate) = run(
            adapter: adapter, sessions: [during], now: Date()
        )[during.id] else {
            return XCTFail("a connection made during the conversation is that conversation's")
        }
        XCTAssertEqual(candidate.url.lastPathComponent, "conversation.jsonl")
    }

    /// **The fix, end to end.** A connection from before the conversation is not inside
    /// it. Under the rule this replaces, this session matched: the file's last write was
    /// inside a window that ran to *now*, and every past session's window reached forward
    /// to today.
    func testAConnectionFromBeforeTheConversationDoesNotMatch() throws {
        let root = try makeRoot()
        try writeLog(timestampedLog, in: root, name: "conversation",
                     modified: Date().addingTimeInterval(-30))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        // The conversation ended in October; the connection is from today, days after.
        let today = session(now: Date(), connectedAgo: 0)

        XCTAssertEqual(
            run(adapter: adapter, sessions: [today], now: Date())[today.id],
            .ambiguous(count: 0),
            "a connection after the conversation is not inside it"
        )
    }

    func testALogWrittenDuringTheConnectionIsAMatch() throws {
        let root = try makeRoot()
        try writeLog(timestampedLog, in: root, name: "match")

        let theSession = connected(Self.conversationStart.addingTimeInterval(500))
        let outcome = run(
            adapter: ClaudeCodeLogAdapter(projectsRoot: root), sessions: [theSession], now: Date()
        )
        guard case .unique(let candidate) = outcome[theSession.id] else {
            return XCTFail("a connection inside the conversation is that conversation's")
        }
        XCTAssertEqual(candidate.url.lastPathComponent, "match.jsonl")
    }

    func testAConversationFromLongBeforeTheConnectionIsNotAMatch() throws {
        let root = try makeRoot()
        try writeLog(timestampedLog, in: root, name: "stale")

        let theSession = session(now: Date(), connectedAgo: 120)
        XCTAssertEqual(
            run(
                adapter: ClaudeCodeLogAdapter(projectsRoot: root),
                sessions: [theSession], now: Date()
            )[theSession.id],
            .ambiguous(count: 0),
            "a conversation from October is not today's connection"
        )
    }

    /// The case the uniqueness rule exists for: two agents running side by side both
    /// overlap one window. Both must be returned so the matcher can refuse — picking
    /// one here is the whole bug the rule prevents.
    func testTwoConversationsSpanningOneConnectionBothComeBackSoTheMatcherCanRefuse() throws {
        let root = try makeRoot()
        try writeLog(timestampedLog, in: root, name: "agent-a")
        try writeLog(timestampedLog, in: root, name: "agent-b")

        let theSession = connected(Self.conversationStart.addingTimeInterval(500))
        XCTAssertEqual(
            run(
                adapter: ClaudeCodeLogAdapter(projectsRoot: root),
                sessions: [theSession], now: Date()
            )[theSession.id],
            .ambiguous(count: 2)
        )
    }

    func testNonJSONLFilesAreIgnored() throws {
        let root = try makeRoot()
        let now = Date()
        let url = root.appendingPathComponent("proj/notes.txt")
        try realSummary.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)

        XCTAssertTrue(ClaudeCodeLogAdapter(projectsRoot: root).logCandidates(newerThan: nil).isEmpty)
    }

    func testMissingRootIsNoCandidatesNotACrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-root-\(UUID().uuidString)")
        XCTAssertTrue(ClaudeCodeLogAdapter(projectsRoot: missing).logCandidates(newerThan: nil).isEmpty)
    }

    /// **The age filter is a lower bound only, and it lives in the matcher for the upper
    /// one.** A file stamped in the future is enumerated and the matcher refuses it, since
    /// a conversation cannot have been written before `now`. That bound was once applied
    /// here behind a second `overlap`, which silently narrowed the matcher's window
    /// whenever it was set smaller — for no saving, since reading the modification date
    /// happens either way.
    func testAFutureStampedConversationIsEnumeratedAndThenRefusedByTheMatcher() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(timestampedLog, in: root, name: "live",
                     modified: now.addingTimeInterval(-30))
        try writeLog(timestampedLog, in: root, name: "skewed",
                     modified: now.addingTimeInterval(7200))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        XCTAssertEqual(
            found(root).map(\.url.lastPathComponent),
            ["live.jsonl", "skewed.jsonl"],
            "enumeration applies no age predicate of its own"
        )

        // A connection two hours from now shares the skewed file's interval and nothing
        // else, so it is refused by the matcher's own `now` bound.
        let skewed = connected(now.addingTimeInterval(7200))
        XCTAssertEqual(
            run(adapter: adapter, sessions: [skewed], now: now)[skewed.id],
            .ambiguous(count: 0)
        )
    }

    /// **The cost bound: a file older than the pass could match is never read.**
    ///
    /// `logCandidates()` without a bound reads every log on the machine at any age, and
    /// the scan is 2.63 ms per 712 KB — so ~300 conversations is ~0.8 s per pass and ~1 GB
    /// of logs is ~3.7 s, roughly 12% of a core continuously, spent on intervals the
    /// matcher throws away. The bound is safe because a conversation's interval cannot
    /// reach past its own last write: a file whose `mtime` predates the earliest instant
    /// any session could match has an interval that ends before it.
    func testTheAgeFilterExcludesFilesThePassCouldNotMatch() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(timestampedLog, in: root, name: "recent",
                     modified: now.addingTimeInterval(-30 * 60))
        try writeLog(timestampedLog, in: root, name: "ancient",
                     modified: now.addingTimeInterval(-90 * 24 * 3600))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        XCTAssertEqual(found(root).count, 2, "unbounded, both are read")

        let bound = now.addingTimeInterval(-60 * 60)
        let bounded = adapter.logCandidates(newerThan: bound)
        XCTAssertEqual(bounded.map(\.url.lastPathComponent), ["recent.jsonl"])
    }

    /// And the bound must not drop a file the matcher *would* have accepted: a conversation
    /// older than the bound is unreachable by construction, so the filter can only be
    /// wrong by being too eager, and this pins that it is not.
    func testTheAgeFilterKeepsEveryConversationTheMatcherWouldMatch() throws {
        let root = try makeRoot()
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)
        let connections = [
            connected(Self.conversationStart.addingTimeInterval(500)),
            session(now: Date(), connectedAgo: 90 * 24 * 3600),
        ]
        let bound = connections.map(\.connectedAt).min()!.addingTimeInterval(-overlap)

        // Written after the bound is computed but stamped well before it, so only the
        // interval can make it matchable — and it must.
        try writeLog(timestampedLog, in: root, name: "boundary",
                     modified: bound.addingTimeInterval(1))
        XCTAssertEqual(adapter.logCandidates(newerThan: bound).count, 1)
    }

    // MARK: - The runner, end to end from a real file

    /// Two logs in one window must produce `ambiguousMatch`, never a pick.
    func testTwoLogsInOneWindowRefuseRatherThanPick() throws {
        let root = try makeRoot()
        try writeLog(timestampedLog, in: root, name: "a")
        try writeLog(timestampedLog, in: root, name: "b")
        let theSession = connected(Self.conversationStart.addingTimeInterval(500))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter).run(
            sessionID: theSession.id,
            match: run(
                adapter: adapter, sessions: [theSession], now: Date()
            )[theSession.id] ?? .ambiguous(count: 0)
        )
        guard case .notReported(let reason) = outcome else {
            return XCTFail("two conversations must not produce a figure, got \(outcome)")
        }
        XCTAssertEqual(reason, .ambiguousMatch)
    }

    func testOneLogProducesOneRecordPerModel() throws {
        let root = try makeRoot()
        try writeLog("""
        {"type":"assistant","timestamp":"2026-10-03T22:31:52.452Z"}
        {"modelUsage":{"model-a":{"inputTokens":100,"outputTokens":50},"model-b":{"inputTokens":200,"outputTokens":75}}}
        {"type":"assistant","timestamp":"2026-10-03T22:58:30.007Z"}
        """, in: root, name: "escalated")
        let theSession = connected(Self.conversationStart.addingTimeInterval(500))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter).run(
            sessionID: theSession.id,
            match: run(
                adapter: adapter, sessions: [theSession], now: Date()
            )[theSession.id] ?? .ambiguous(count: 0)
        )
        guard case .reported(let records) = outcome else {
            return XCTFail("expected records, got \(outcome)")
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.modelID), ["model-a", "model-b"])
        XCTAssertTrue(records.allSatisfy { $0.sessionID == theSession.id })
        // One observation, so one instant — otherwise the latest-per-segment fold
        // would see a disagreement that is not real.
        XCTAssertEqual(Set(records.map(\.recordedAt)).count, 1)
        XCTAssertTrue(records.allSatisfy { $0.provenance == .parsedFromLog })
    }

    func testNoLogsIsNoSourceNotAmbiguous() throws {
        let root = try makeRoot()
        let now = Date()
        let theSession = session(now: now, connectedAgo: 10)
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter).run(
            sessionID: theSession.id,
            match: run(adapter: adapter, sessions: [theSession], now: now)[theSession.id] ?? .ambiguous(count: 0)
        )
        guard case .notReported(let reason) = outcome else {
            return XCTFail("expected absence, got \(outcome)")
        }
        XCTAssertEqual(reason, .noSource)
    }

    /// The one case a real log gets right: one session, one log, a figure per model.
    /// Everything above is a refusal; without this the file could be unreadable and
    /// every test here would still pass.
    func testASingleSessionWithASingleLogIsCounted() throws {
        let root = try makeRoot()
        try writeLog(timestampedLog, in: root, name: "only")
        let theSession = connected(Self.conversationStart.addingTimeInterval(500))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter).run(
            sessionID: theSession.id,
            match: run(
                adapter: adapter, sessions: [theSession], now: Date()
            )[theSession.id] ?? .ambiguous(count: 0)
        )
        guard case .reported(let records) = outcome, let record = records.first else {
            return XCTFail("expected a figure, got \(outcome)")
        }
        XCTAssertEqual(record.modelID, "claude-fable-5")
        XCTAssertEqual(record.output, 16739)
    }
}
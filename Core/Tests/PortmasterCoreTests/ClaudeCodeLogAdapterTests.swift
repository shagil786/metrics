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

        let found = ClaudeCodeLogAdapter(projectsRoot: root).logCandidates()
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["ancient.jsonl", "live.jsonl"])
        // Both ends of the interval must be the file's real mtime, since neither log
        // carries a line timestamp — see the fallback test for why that is labelled.
        let live = try XCTUnwrap(found.first { $0.url.lastPathComponent == "live.jsonl" })
        let onDisk = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(
                atPath: live.url.path
            )[.modificationDate]) as? Date
        )
        XCTAssertEqual(try XCTUnwrap(live.interval).start.timeIntervalSince1970,
                       onDisk.timeIntervalSince1970, accuracy: 1)
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

        let found = try XCTUnwrap(
            ClaudeCodeLogAdapter(projectsRoot: root).logCandidates().first
        )
        let interval = try XCTUnwrap(found.interval)

        XCTAssertEqual(interval.evidence, .lineTimestamps)
        XCTAssertEqual(
            interval.start.timeIntervalSince1970,
            Self.conversationStart.timeIntervalSince1970, accuracy: 0.002
        )
        XCTAssertEqual(
            interval.end.timeIntervalSince1970,
            Self.conversationEnd.timeIntervalSince1970, accuracy: 0.002
        )
        // And not the mtime the file was deliberately given.
        XCTAssertNotEqual(
            interval.start.timeIntervalSince1970,
            written.timeIntervalSince1970, accuracy: 60
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
            ClaudeCodeLogAdapter(projectsRoot: root).logCandidates().first?.interval
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

    /// **A log with no line timestamps falls back to its file metadata, and says so.**
    ///
    /// The real observed summary line is exactly this shape — a `modelUsage` line with no
    /// `timestamp` — so the fallback is not hypothetical. It is a *point* where a span is
    /// wanted, and `evidence` is the only thing stopping a caller reading it as the
    /// interval it is not. A weaker claim wearing a stronger claim's name is how a
    /// plausible wrong number ships.
    func testALogWithNoLineTimestampsFallsBackToFileMetadataAndSaysSo() throws {
        let root = try makeRoot()
        let modified = Date().addingTimeInterval(-45 * 60)
        try writeLog(realSummary, in: root, name: "no-stamps", modified: modified)

        let interval = try XCTUnwrap(
            ClaudeCodeLogAdapter(projectsRoot: root).logCandidates().first?.interval
        )

        XCTAssertEqual(interval.evidence, .fileModification)
        // Both ends are the one timestamp there is, so the "span" has no width — which is
        // the fact a caller needs and cannot infer from the numbers alone.
        XCTAssertEqual(interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970)
        XCTAssertEqual(interval.start.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
    }

    /// A timestamp that is not a timestamp must not become one. Quoted prose inside a
    /// message body can contain the marker; the shape check is what keeps that from
    /// inventing a conversation.
    func testAMarkerInProseIsNotReadAsATimestamp() throws {
        let root = try makeRoot()
        let modified = Date().addingTimeInterval(-45 * 60)
        try writeLog("""
        {"type":"user","message":{"role":"user","content":"why is \"timestamp\":\"nonsense\" in my log"}}
        {"modelUsage":{"claude-fable-5":{"inputTokens":0,"outputTokens":16739}}}
        """, in: root, name: "prose", modified: modified)

        let interval = try XCTUnwrap(
            ClaudeCodeLogAdapter(projectsRoot: root).logCandidates().first?.interval
        )

        XCTAssertEqual(interval.evidence, .fileModification, "prose is not a timestamp")
        XCTAssertEqual(interval.start.timeIntervalSince1970, modified.timeIntervalSince1970, accuracy: 1)
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

    func testALogModifiedDuringTheWindowIsACandidate() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "match", modified: now.addingTimeInterval(-30))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let theSession = session(now: now, connectedAgo: 120)
        guard case .unique(let candidate) = run(adapter: adapter, sessions: [theSession], now: now)[theSession.id] else {
            return XCTFail("a log written inside the window is this session's")
        }
        XCTAssertEqual(candidate.url.lastPathComponent, "match.jsonl")
    }

    func testALogFarOutsideTheWindowIsNotACandidate() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "stale", modified: now.addingTimeInterval(-90 * 24 * 3600))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let theSession = session(now: now, connectedAgo: 120)
        XCTAssertEqual(
            run(adapter: adapter, sessions: [theSession], now: now)[theSession.id],
            .ambiguous(count: 0),
            "a three-month-old log is not this session's"
        )
    }

    /// The case the uniqueness rule exists for: two agents running side by side both
    /// overlap one window. Both must be returned so the matcher can refuse — picking
    /// one here is the whole bug the rule prevents.
    func testTwoOverlappingLogsBothComeBackSoTheMatcherCanRefuse() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "agent-a", modified: now.addingTimeInterval(-30))
        try writeLog(realSummary, in: root, name: "agent-b", modified: now.addingTimeInterval(-20))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let theSession = session(now: now, connectedAgo: 120)
        XCTAssertEqual(
            run(adapter: adapter, sessions: [theSession], now: now)[theSession.id],
            .ambiguous(count: 2)
        )
    }

    func testNonJSONLFilesAreIgnored() throws {
        let root = try makeRoot()
        let now = Date()
        let url = root.appendingPathComponent("proj/notes.txt")
        try realSummary.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)

        XCTAssertTrue(ClaudeCodeLogAdapter(projectsRoot: root).logCandidates().isEmpty)
    }

    func testMissingRootIsNoCandidatesNotACrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-root-\(UUID().uuidString)")
        XCTAssertTrue(ClaudeCodeLogAdapter(projectsRoot: missing).logCandidates().isEmpty)
    }

    /// A file stamped in the future **is** enumerated, and the matcher refuses it.
    ///
    /// A machine whose clock is wrong, or a log restored from a backup, produces exactly
    /// this. It used to be dropped here, behind a second `overlap` the adapter carried
    /// alongside the poller's own: an upper bound configured in two places, which
    /// silently narrowed the matcher's window whenever it was set smaller, for no saving
    /// at all — `modificationDate(of:)` already reads every file's attributes. The
    /// matcher already has the bound, and the file has to reach it either way.
    func testAFutureStampedLogIsEnumeratedAndThenRefusedByTheMatcher() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "live", modified: now)
        try writeLog(realSummary, in: root, name: "skewed", modified: now.addingTimeInterval(7200))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        XCTAssertEqual(
            adapter.logCandidates().map(\.url.lastPathComponent),
            ["live.jsonl", "skewed.jsonl"],
            "enumeration applies no age predicate at all"
        )

        let theSession = session(now: now, connectedAgo: 120)
        guard case .unique(let candidate) = run(adapter: adapter, sessions: [theSession], now: now)[theSession.id] else {
            return XCTFail("the live log is the only matchable file")
        }
        XCTAssertEqual(candidate.url.lastPathComponent, "live.jsonl")
    }

    // MARK: - The runner, end to end from a real file

    /// Two logs in one window must produce `ambiguousMatch`, never a pick.
    func testTwoLogsInOneWindowRefuseRatherThanPick() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "a", modified: now.addingTimeInterval(-30))
        try writeLog(realSummary, in: root, name: "b", modified: now.addingTimeInterval(-20))
        let theSession = session(now: now, connectedAgo: 120)
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter).run(
            sessionID: theSession.id,
            match: run(adapter: adapter, sessions: [theSession], now: now)[theSession.id] ?? .ambiguous(count: 0)
        )
        guard case .notReported(let reason) = outcome else {
            return XCTFail("two logs must not produce a figure, got \(outcome)")
        }
        XCTAssertEqual(reason, .ambiguousMatch)
    }

    func testOneLogProducesOneRecordPerModel() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog("""
        {"modelUsage":{"model-a":{"inputTokens":100,"outputTokens":50},"model-b":{"inputTokens":200,"outputTokens":75}}}
        """, in: root, name: "escalated", modified: now.addingTimeInterval(-30))
        let theSession = session(now: now, connectedAgo: 120)
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter).run(
            sessionID: theSession.id,
            match: run(adapter: adapter, sessions: [theSession], now: now)[theSession.id] ?? .ambiguous(count: 0)
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
        let now = Date()
        try writeLog(realSummary, in: root, name: "only", modified: now.addingTimeInterval(-30))
        let theSession = session(now: now, connectedAgo: 120)
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter).run(
            sessionID: theSession.id,
            match: run(adapter: adapter, sessions: [theSession], now: now)[theSession.id] ?? .ambiguous(count: 0)
        )
        guard case .reported(let records) = outcome, let record = records.first else {
            return XCTFail("expected a figure, got \(outcome)")
        }
        XCTAssertEqual(record.modelID, "claude-fable-5")
        XCTAssertEqual(record.output, 16739)
    }
}
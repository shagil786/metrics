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

    private func snapshot(now: Date, connectedAgo: TimeInterval) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: UUID(), peerPID: 4242,
            clientName: "claude-code", clientVersion: nil,
            connectedAt: now.addingTimeInterval(-connectedAgo), endedAt: nil,
            usage: .notReported(reason: .noSource), cost: .noUsage
        )
    }

    /// Every log under the root, each with its real last-write time.
    private func candidates(root: URL, adapter: ClaudeCodeLogAdapter? = nil) -> [LogCandidate] {
        (adapter ?? ClaudeCodeLogAdapter(projectsRoot: root)).logCandidates()
    }

    /// The window the poller configures, so these tests exercise the same overlap
    /// production uses rather than a number chosen for the fixture.
    private let overlap: TimeInterval = 60 * 60

    /// Enumeration, not matching: every log in the tree comes back whatever its age,
    /// because this method is not given a session and deciding what overlaps one is
    /// `AgentLogMatcher`'s job. Splitting it here is what lets one walk serve every
    /// session in a pass.
    func testLogCandidatesReturnsEveryLogInTheTreeWhateverItsAge() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "live", modified: now.addingTimeInterval(-30))
        try writeLog(realSummary, in: root, name: "ancient", modified: now.addingTimeInterval(-90 * 24 * 3600))

        let found = candidates(root: root)
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["ancient.jsonl", "live.jsonl"])
        // The timestamp is the correlation, so it must be the file's real mtime.
        let live = try XCTUnwrap(found.first { $0.url.lastPathComponent == "live.jsonl" })
        let onDisk = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(
                atPath: live.url.path
            )[.modificationDate]) as? Date
        )
        XCTAssertEqual(live.modifiedAt.timeIntervalSince1970,
                       onDisk.timeIntervalSince1970, accuracy: 1)
    }

    func testALogModifiedDuringTheWindowIsACandidate() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "match", modified: now.addingTimeInterval(-30))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let match = AgentLogMatcher.match(
            candidates(root: root, adapter: adapter),
            for: snapshot(now: now, connectedAgo: 120),
            overlap: overlap
        )
        guard case .unique(let candidate) = match else {
            return XCTFail("a log written inside the window is this session's, got \(match)")
        }
        XCTAssertEqual(candidate.url.lastPathComponent, "match.jsonl")
    }

    func testALogFarOutsideTheWindowIsNotACandidate() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "stale", modified: now.addingTimeInterval(-90 * 24 * 3600))
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let match = AgentLogMatcher.match(
            candidates(root: root, adapter: adapter),
            for: snapshot(now: now, connectedAgo: 120),
            overlap: overlap
        )
        XCTAssertEqual(match, .ambiguous(count: 0), "a three-month-old log is not this session's")
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

        let match = AgentLogMatcher.match(
            candidates(root: root, adapter: adapter),
            for: snapshot(now: now, connectedAgo: 120),
            overlap: overlap
        )
        XCTAssertEqual(match, .ambiguous(count: 2))
    }

    func testNonJSONLFilesAreIgnored() throws {
        let root = try makeRoot()
        let now = Date()
        let url = root.appendingPathComponent("proj/notes.txt")
        try realSummary.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)

        XCTAssertTrue(candidates(root: root).isEmpty)
    }

    func testMissingRootIsNoCandidatesNotACrash() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-root-\(UUID().uuidString)")
        XCTAssertTrue(ClaudeCodeLogAdapter(projectsRoot: missing).logCandidates().isEmpty)
    }

    /// A file stamped past the adapter's clock tolerance is dropped at enumeration rather
    /// than handed to the matcher to discard.
    ///
    /// A machine whose clock is wrong, or a log restored from a backup, produces exactly
    /// this — and the session window cannot reach it, because a session cannot have
    /// connected in the future. It is the one bound that belongs in the enumeration: it
    /// is the same limit `AgentLogMatcher` applies, and keeping it here means a pass
    /// hands the matcher a list of files the matcher will not have to throw away.
    func testAFileStampedBeyondTheClockToleranceIsNotACandidate() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "live", modified: now)
        try writeLog(realSummary, in: root, name: "skewed", modified: now.addingTimeInterval(7200))

        let found = ClaudeCodeLogAdapter(projectsRoot: root, overlap: 60).logCandidates()
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["live.jsonl"])
    }

    // MARK: - Runner: the uniqueness rule

    /// Two candidates must produce `ambiguousMatch`, never a pick.
    func testRunnerRefusesTwoCandidatesAsAmbiguous() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog(realSummary, in: root, name: "a", modified: now.addingTimeInterval(-30))
        try writeLog(realSummary, in: root, name: "b", modified: now.addingTimeInterval(-20))
        let session = snapshot(now: now, connectedAgo: 120)
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter)
            .run(session: session, candidates: adapter.logCandidates(), overlap: overlap)
        guard case .notReported(let reason) = outcome else {
            return XCTFail("two candidates must not produce a figure, got \(outcome)")
        }
        XCTAssertEqual(reason, .ambiguousMatch)
    }

    func testRunnerProducesOneRecordPerModel() throws {
        let root = try makeRoot()
        let now = Date()
        try writeLog("""
        {"modelUsage":{"model-a":{"inputTokens":100,"outputTokens":50},"model-b":{"inputTokens":200,"outputTokens":75}}}
        """, in: root, name: "escalated", modified: now.addingTimeInterval(-30))
        let session = snapshot(now: now, connectedAgo: 120)
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter)
            .run(session: session, candidates: adapter.logCandidates(), overlap: overlap)
        guard case .reported(let records) = outcome else {
            return XCTFail("expected records, got \(outcome)")
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.modelID), ["model-a", "model-b"])
        // One observation, so one instant — otherwise the latest-per-provenance fold
        // would see a disagreement that is not real.
        XCTAssertEqual(Set(records.map(\.recordedAt)).count, 1)
        XCTAssertTrue(records.allSatisfy { $0.provenance == .parsedFromLog })
    }

    func testNoCandidatesIsNoSourceNotAmbiguous() throws {
        let root = try makeRoot()
        let adapter = ClaudeCodeLogAdapter(projectsRoot: root)

        let outcome = TokenSourceRunner(adapter: adapter)
            .run(
                session: snapshot(now: Date(), connectedAgo: 10),
                candidates: adapter.logCandidates(),
                overlap: overlap
            )
        guard case .notReported(let reason) = outcome else {
            return XCTFail("expected absence, got \(outcome)")
        }
        XCTAssertEqual(reason, .noSource)
    }
}
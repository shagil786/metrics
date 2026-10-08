// The adapter contract. A real adapter parses a vendor's private file format, and
// the failure this protocol must make impossible is a parse that half-succeeds and
// reports a plausible wrong number — so the fixture asserts that garbage in
// produces notReported rather than a figure.
import XCTest
import Foundation
@testable import PortmasterCore

/// Every `.json` file under a directory, with each one's last write time.
///
/// Shared by the fixtures here and in `AgentSourcePollerTests`, and the shape of what
/// `ClaudeCodeLogAdapter` does, because the correlation is the same problem in both
/// cases: a file's timestamp is the only thing tying it to a session.
func fixtureLogCandidates(in root: URL) -> [LogCandidate] {
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey]
    )) ?? []
    return contents
        .filter { $0.pathExtension == "json" }
        .compactMap { url in
            guard let modified = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            else { return nil }
            return LogCandidate(url: url, modifiedAt: modified)
        }
        .sorted { $0.url.path < $1.url.path }
}

/// Adapter over a JSON file the test writes, standing in for a vendor log.
///
/// **Correlates by time, not by the session's id.** A fixture keyed on the id would be
/// a convenience the real thing does not have — a session id is an MCP connection UUID
/// and a vendor's log is named for something else entirely — so keying on it here would
/// hide the one question `AgentLogMatcher` exists to answer. Every test below therefore
/// writes its file now and runs against a session connected now.
struct FixtureTokenAdapter: TokenSourceAdapter {
    let identifier = "fixture-agent"
    var root: URL

    func logCandidates() -> [LogCandidate] { fixtureLogCandidates(in: root) }

    func parse(_ url: URL) throws -> [RawAgentUsage] {
        let data = try Data(contentsOf: url)
        // `try?` on the decode, not just on the cast: a file that is not JSON at all
        // fails inside `JSONSerialization`, and letting that error out would break
        // this adapter's own contract — the file *was* read, so its shape was not
        // understood, which is `unrecognizedFormat` and not a foreign error type.
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let object = json as? [String: Any],
              let input = object["input"] as? Int,
              let output = object["output"] as? Int,
              let model = object["model"] as? String
        else {
            // A shape we do not understand is its own outcome, not a zero.
            throw TokenSourceError.unrecognizedFormat
        }
        return [RawAgentUsage(
            input: input, output: output,
            cacheRead: object["cache"] as? Int,
            reasoning: nil,
            modelID: model
        )]
    }
}

/// Adapter whose `parse` throws an error of its own, standing in for the naive
/// adapters phase C will write. `FixtureTokenAdapter` cannot cover this: every exit
/// it has is either `TokenSourceError` or unreachable, so a test using it would keep
/// passing if the runner's catch-all were deleted outright. It refuses every file —
/// isolating one refusal among several is `CountingTokenAdapter`'s job.
struct ThrowingTokenAdapter: TokenSourceAdapter {
    let identifier = "throwing-agent"
    var root: URL

    func logCandidates() -> [LogCandidate] { fixtureLogCandidates(in: root) }

    func parse(_ url: URL) throws -> [RawAgentUsage] {
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    }
}

final class TokenSourceAdapterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A session in the two-column form matching consumes, connected `connectedAgo`
    /// seconds before `now`.
    private func session(_ id: UUID = UUID(), now: Date, connectedAgo: TimeInterval = 0)
        -> (id: UUID, connectedAt: Date)
    {
        (id: id, connectedAt: now.addingTimeInterval(-connectedAgo))
    }

    private let now = Date()

    /// Wide enough that the only file a test deliberately places far away falls out of
    /// the window. Matches what `AgentSourcePoller` configures.
    private let overlap: TimeInterval = 60 * 60

    /// Enumerate and match the way a pass does, then hand the decision to the runner —
    /// so each test below says which files it put on disk and which session asked,
    /// rather than asserting an outcome whose inputs it never stated.
    private func outcome(
        adapter: any TokenSourceAdapter,
        session: (id: UUID, connectedAt: Date)
    ) -> TokenSourceOutcome {
        let match = AgentLogMatcher.match(
            adapter.logCandidates(), for: [session], overlap: overlap, now: now
        )
        return TokenSourceRunner(adapter: adapter).run(
            sessionID: session.id, match: match[session.id] ?? .ambiguous(count: 0)
        )
    }

    @discardableResult
    private func writeLog(_ json: String, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Locating

    /// An empty directory is an empty candidate list, which is normal and not a failure:
    /// most sessions have no readable log.
    func testMissingLogIsNoSourceNotAFailure() {
        XCTAssertTrue(FixtureTokenAdapter(root: root).logCandidates().isEmpty)
    }

    /// A file the test just wrote is a candidate carrying its real last-write time. The
    /// timestamp is not decoration — it is the whole correlation — so it must be the
    /// file's actual mtime rather than anything the test invented.
    func testAFileOnDiskIsACandidateCarryingItsLastWriteTime() throws {
        let written = try writeLog(#"{"input": 1, "output": 1, "model": "m"}"#, named: "a.json")

        let candidates = FixtureTokenAdapter(root: root).logCandidates()

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.url.lastPathComponent, written.lastPathComponent)
        let onDisk = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: written.path)[.modificationDate]) as? Date
        )
        XCTAssertEqual(candidate.modifiedAt.timeIntervalSince1970,
                       onDisk.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - Parsing

    func testValidLogParsesToUsage() throws {
        let url = try writeLog(
            #"{"input": 1200, "output": 300, "model": "m1", "cache": 50}"#, named: "log.json"
        )

        let raw = try XCTUnwrap(try FixtureTokenAdapter(root: root).parse(url).first)
        XCTAssertEqual(raw.input, 1200)
        XCTAssertEqual(raw.output, 300)
        XCTAssertEqual(raw.modelID, "m1")
        XCTAssertEqual(raw.cacheRead, 50)
    }

    func testGarbageLogThrowsUnrecognizedFormatRatherThanZero() throws {
        let url = root.appendingPathComponent("garbage.json")
        try #"{"totally": "different"}"#.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FixtureTokenAdapter(root: root).parse(url)) { error in
            XCTAssertEqual(error as? TokenSourceError, .unrecognizedFormat,
                           "an unknown shape must not become a number")
        }
    }

    func testNonJSONFileThrowsUnrecognizedFormat() throws {
        let url = root.appendingPathComponent("notes.txt")
        try "just some text".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FixtureTokenAdapter(root: root).parse(url)) { error in
            XCTAssertEqual(error as? TokenSourceError, .unrecognizedFormat)
        }
    }

    // MARK: - The runner's outcome mapping

    func testRunnerMapsSuccessToParsedRecord() throws {
        try writeLog(#"{"input": 10, "output": 5, "model": "m"}"#, named: "log.json")

        let outcome = outcome(
            adapter: FixtureTokenAdapter(root: root), session: session(now: now)
        )

        guard case .reported(let records) = outcome, let record = records.first else {
            return XCTFail("expected a record, got \(outcome)")
        }
        XCTAssertEqual(record.provenance, .parsedFromLog)
        XCTAssertEqual(record.input, 10)
    }

    func testRunnerMapsUnrecognizedFormatToNotReported() throws {
        try writeLog(#"{"nope": 1}"#, named: "log.json")

        let outcome = outcome(
            adapter: FixtureTokenAdapter(root: root), session: session(now: now)
        )

        XCTAssertEqual(outcome, .notReported(reason: .unrecognizedFormat))
    }

    func testRunnerMapsMissingLogToNoSource() {
        let outcome = outcome(
            adapter: FixtureTokenAdapter(root: root), session: session(now: now)
        )

        XCTAssertEqual(outcome, .notReported(reason: .noSource))
    }

    /// Zero candidates and two candidates are both refusals, and they are **different**
    /// absences. A machine whose agent has written no log is `noSource`; a machine
    /// running two agents side by side is `ambiguousMatch`. Collapsing them would send a
    /// user looking for a log that was never going to appear, or tell them two agents
    /// are running when none are.
    ///
    /// The rule this pins is one line in the runner's switch, and it is the line that
    /// keeps a candidate outside the window from being counted at all.
    func testRunnerTellsNoCandidatesApartFromTooMany() throws {
        let adapter = FixtureTokenAdapter(root: root)
        let s = session(now: now)

        XCTAssertEqual(outcome(adapter: adapter, session: s), .notReported(reason: .noSource))

        try writeLog(#"{"input": 1, "output": 1, "model": "m"}"#, named: "one.json")
        try writeLog(#"{"input": 2, "output": 2, "model": "m"}"#, named: "two.json")
        XCTAssertEqual(
            outcome(adapter: adapter, session: s), .notReported(reason: .ambiguousMatch)
        )
    }

    // MARK: - A record belongs to the session it was read for

    /// The record must carry the id of the session the decision was made for, so counts
    /// read from one session's log cannot be recorded against another's.
    ///
    /// The id is a parameter now rather than a runner field, which removes the stale-copy
    /// failure structurally — so what is left to assert is that the runner stamps exactly
    /// what it was handed rather than deriving one.
    func testRecordCarriesTheSessionIdItWasRunFor() throws {
        try writeLog(#"{"input": 7, "output": 3, "model": "m"}"#, named: "log.json")
        let located = session(now: now)
        // An id belonging to no log here, which is what a stale caller would carry.
        let unrelated = UUID()
        let adapter = FixtureTokenAdapter(root: root)

        let match = AgentLogMatcher.match(
            adapter.logCandidates(), for: [located], overlap: overlap, now: now
        )
        let outcome = TokenSourceRunner(adapter: adapter)
            .run(sessionID: located.id, match: match[located.id] ?? .ambiguous(count: 0))

        guard case .reported(let records) = outcome, let record = records.first else {
            return XCTFail("expected a record, got \(outcome)")
        }
        XCTAssertEqual(record.sessionID, located.id)
        XCTAssertNotEqual(record.sessionID, unrelated)
    }

    // MARK: - A foreign error is still an absence

    /// A real adapter parses JSON, plist or a line-oriented format and throws
    /// `DecodingError` or an `NSError` constantly. The runner's contract is that no
    /// caller has to interpret an error, so that error must arrive as a named
    /// absence. Deleting or narrowing the catch-all must fail here.
    func testRunnerMapsAForeignErrorToLogUnreadable() throws {
        try writeLog(#"{"input": 1, "output": 1, "model": "m"}"#, named: "log.json")
        let adapter = ThrowingTokenAdapter(root: root)

        let outcome = outcome(adapter: adapter, session: session(now: now))

        XCTAssertEqual(outcome, .notReported(reason: .logUnreadable))
    }
}

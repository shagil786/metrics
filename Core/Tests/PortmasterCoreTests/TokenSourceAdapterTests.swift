// The adapter contract. A real adapter parses a vendor's private file format, and
// the failure this protocol must make impossible is a parse that half-succeeds and
// reports a plausible wrong number — so the fixture asserts that garbage in
// produces notReported rather than a figure.
import XCTest
import Foundation
@testable import PortmasterCore

/// Adapter over a JSON file the test writes, standing in for a vendor log.
struct FixtureTokenAdapter: TokenSourceAdapter {
    let identifier = "fixture-agent"
    var root: URL

    func locateSessionLog(for session: AgentSessionSnapshot) -> URL? {
        let url = root.appendingPathComponent("\(session.id.uuidString).json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func parse(_ url: URL) throws -> RawAgentUsage {
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
        return RawAgentUsage(
            input: input, output: output,
            cacheRead: object["cache"] as? Int,
            reasoning: nil,
            modelID: model
        )
    }
}

/// Adapter whose `parse` throws an error of its own, standing in for the naive
/// adapters phase C will write. `FixtureTokenAdapter` cannot cover this: every exit
/// it has is either `TokenSourceError` or unreachable, so a test using it would keep
/// passing if the runner's catch-all were deleted outright.
struct ThrowingTokenAdapter: TokenSourceAdapter {
    let identifier = "throwing-agent"
    var root: URL

    func locateSessionLog(for session: AgentSessionSnapshot) -> URL? {
        let url = root.appendingPathComponent("\(session.id.uuidString).json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func parse(_ url: URL) throws -> RawAgentUsage {
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

    private func session() -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: UUID(), peerPID: 1, clientName: "fixture", clientVersion: nil,
            connectedAt: Date(), endedAt: nil,
            usage: .notReported(reason: .noSource), cost: .noUsage
        )
    }

    // MARK: - Locating

    func testMissingLogIsNoSourceNotAFailure() {
        let adapter = FixtureTokenAdapter(root: root)
        XCTAssertNil(adapter.locateSessionLog(for: session()))
    }

    // MARK: - Parsing

    func testValidLogParsesToUsage() throws {
        let s = session()
        let url = root.appendingPathComponent("\(s.id.uuidString).json")
        try #"{"input": 1200, "output": 300, "model": "m1", "cache": 50}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let raw = try FixtureTokenAdapter(root: root).parse(url)
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
        let s = session()
        let url = root.appendingPathComponent("\(s.id.uuidString).json")
        try #"{"input": 10, "output": 5, "model": "m"}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let outcome = TokenSourceRunner(adapter: FixtureTokenAdapter(root: root))
            .run(session: s)

        guard case .reported(let record) = outcome else {
            return XCTFail("expected a record, got \(outcome)")
        }
        XCTAssertEqual(record.provenance, .parsedFromLog)
        XCTAssertEqual(record.input, 10)
    }

    func testRunnerMapsUnrecognizedFormatToNotReported() {
        let s = session()
        try? #"{"nope": 1}"#.write(
            to: root.appendingPathComponent("\(s.id.uuidString).json"),
            atomically: true, encoding: .utf8
        )

        let outcome = TokenSourceRunner(adapter: FixtureTokenAdapter(root: root))
            .run(session: s)

        XCTAssertEqual(outcome, .notReported(reason: .unrecognizedFormat))
    }

    func testRunnerMapsMissingLogToNoSource() {
        let outcome = TokenSourceRunner(adapter: FixtureTokenAdapter(root: root))
            .run(session: session())

        XCTAssertEqual(outcome, .notReported(reason: .noSource))
    }

    // MARK: - A record belongs to the session it was read for

    /// The record must be stamped with the id of the session that was located, so
    /// counts read from one session's log cannot be recorded against another's.
    /// Under the earlier design — the runner holding its own `sessionID` beside the
    /// session passed to `run` — this is the mismatch: the runner would stamp
    /// whatever id it was constructed with, and nothing anywhere would object.
    func testRecordIsStampedWithTheSessionItWasRunAgainst() throws {
        let located = session()
        let url = root.appendingPathComponent("\(located.id.uuidString).json")
        try #"{"input": 7, "output": 3, "model": "m"}"#
            .write(to: url, atomically: true, encoding: .utf8)

        // An id belonging to no log here, which is what a stale runner would carry.
        let unrelated = session()

        let outcome = TokenSourceRunner(adapter: FixtureTokenAdapter(root: root))
            .run(session: located)

        guard case .reported(let record) = outcome else {
            return XCTFail("expected a record, got \(outcome)")
        }
        XCTAssertEqual(record.sessionID, located.id)
        XCTAssertNotEqual(record.sessionID, unrelated.id,
                          "the record must follow the session, not a separate id")
    }

    // MARK: - A foreign error is still an absence

    /// A real adapter parses JSON, plist or a line-oriented format and throws
    /// `DecodingError` or an `NSError` constantly. The runner's contract is that no
    /// caller has to interpret an error, so that error must arrive as a named
    /// absence. Deleting or narrowing the catch-all must fail here.
    func testRunnerMapsAForeignErrorToLogUnreadable() throws {
        let s = session()
        try #"{"input": 1, "output": 1, "model": "m"}"#
            .write(to: root.appendingPathComponent("\(s.id.uuidString).json"),
                   atomically: true, encoding: .utf8)

        let outcome = TokenSourceRunner(adapter: ThrowingTokenAdapter(root: root))
            .run(session: s)

        XCTAssertEqual(outcome, .notReported(reason: .logUnreadable))
    }
}

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

        let outcome = TokenSourceRunner(
            adapter: FixtureTokenAdapter(root: root), sessionID: s.id
        ).run()

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

        let outcome = TokenSourceRunner(
            adapter: FixtureTokenAdapter(root: root), sessionID: s.id
        ).run()

        XCTAssertEqual(outcome, .notReported(reason: .unrecognizedFormat))
    }

    func testRunnerMapsMissingLogToNoSource() {
        let outcome = TokenSourceRunner(
            adapter: FixtureTokenAdapter(root: root), sessionID: session().id
        ).run()

        XCTAssertEqual(outcome, .notReported(reason: .noSource))
    }
}

import XCTest
@testable import PortmasterCore

final class ContextPressureExtractorTests: XCTestCase {
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pressure-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func reminder(_ text: String, ts: String = "2026-10-03T22:31:52.569Z") -> String {
        #"{"type":"attachment","attachment":{"type":"total_tokens_reminder","text":"\#(text)"},"timestamp":"\#(ts)"}"#
    }

    func testTheNestedShapeClaudeCodeActuallyWritesReturnsTheWorstReading() throws {
        let url = try write([
            #"{"type":"user","content":"go"}"#,
            reminder("<total_tokens>15000000 tokens left</total_tokens>"),
            #"{"type":"assistant"}"#,
            reminder("<total_tokens>14999357 tokens left</total_tokens>"),
        ])
        let peak = try ContextPressureExtractor.peak(in: url)
        XCTAssertEqual(peak?.tokensLeft, 14999357, "worst means minimum")
        XCTAssertEqual(peak?.lineNumber, 4, "one-based line of that reading")
    }

    func testInfiniteIsNotAReading() throws {
        let url = try write([reminder("<total_tokens>Infinite tokens left</total_tokens>")])
        XCTAssertNil(try ContextPressureExtractor.peak(in: url),
                     "a non-numeric rendering is an absence, never a zero")
    }

    func testATwentyFiveDigitReadingIsAbsentNotTruncated() throws {
        let url = try write([
            reminder("<total_tokens>1234567890123456789012345 tokens left</total_tokens>"),
        ])
        XCTAssertNil(try ContextPressureExtractor.peak(in: url),
                     "beyond Int.max: absence, not truncation and not a crash")
    }

    func testALineThatIsNotJSONDoesNotStopTheRead() throws {
        let url = try write([
            "not json at all",
            reminder("<total_tokens>14999658 tokens left</total_tokens>"),
        ])
        XCTAssertEqual(try ContextPressureExtractor.peak(in: url)?.tokensLeft, 14999658)
    }

    func testNoRemindersIsNilNotZero() throws {
        let url = try write([#"{"type":"user","content":"hi"}"#])
        XCTAssertNil(try ContextPressureExtractor.peak(in: url),
                     "a file with no signal is not a file reporting zero")
    }

    func testTheTopLevelShapeThatDoesNotExistInTheLogIsNotRecognized() throws {
        let url = try write([#"{"type":"total_tokens_reminder","text":"<total_tokens>123 tokens left</total_tokens>"}"#])
        XCTAssertNil(try ContextPressureExtractor.peak(in: url),
                     "we recognize only the shape we have seen; guessing is the old bug")
    }

    func testEqualReadingsReportTheEarliestLine() throws {
        let url = try write([
            reminder("<total_tokens>14999357 tokens left</total_tokens>"),
            "x",
            reminder("<total_tokens>14999357 tokens left</total_tokens>"),
        ])
        XCTAssertEqual(try ContextPressureExtractor.peak(in: url)?.lineNumber, 1,
                       "line number identifies the reading, so ties take the first")
    }

    func testBlankLinesStillCountTowardTheLineNumber() throws {
        let url = try write([
            "",
            reminder("<total_tokens>14999357 tokens left</total_tokens>"),
        ])
        XCTAssertEqual(try ContextPressureExtractor.peak(in: url)?.lineNumber, 2,
                       "line number counts every physical line, blank ones included")
    }
}

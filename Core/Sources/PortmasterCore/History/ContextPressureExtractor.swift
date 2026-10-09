import Foundation

/// One numeric `tokens left` reading, and the line it came from.
///
/// The line number is part of the value rather than debug output: every claim this
/// project makes about a log file is traceable to a line in that file, and a pressure
/// figure nobody can point back to would be the exception.
public struct PressureReading: Sendable, Equatable {
    public let tokensLeft: Int
    /// One-based line in the file that produced this reading.
    public let lineNumber: Int
    public init(tokensLeft: Int, lineNumber: Int) {
        self.tokensLeft = tokensLeft
        self.lineNumber = lineNumber
    }
}

/// The minimum `tokens left` a Claude Code log has reported.
///
/// Minimum, not latest: readings oscillate as work opens and closes sub-contexts, so
/// the last value is not the worst one the session experienced.
///
/// **What the number counts is deliberately not named here.** Claude Code renders it
/// from a session-latched mode that may be a context budget, a task budget, or the
/// literal word `Infinite` — none of which the log states per reading. This extractor
/// reports the number the file printed and nothing about its meaning.
public enum ContextPressureExtractor {
    /// Numeric readings only. The reminder's text is `<total_tokens>N tokens left</total_tokens>`;
    /// a non-numeric rendering (Claude Code's `Infinite`) matches nothing here, which is
    /// the correct answer: it is an absence of a measurable budget, not a measurement.
    private static let pattern = #/<total_tokens>(\d+) tokens left<\/total_tokens>/#

    /// `nil` when no line carried a numeric reminder — an unreadable file throws instead,
    /// because "no reading" and "could not read" are different facts.
    public static func peak(in url: URL) throws -> PressureReading? {
        let text = try String(contentsOf: url, encoding: .utf8)
        var worst: PressureReading?
        for (offset, textLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated() {
            // A log mid-write can hold a partial line; unparseable JSON skips, it does not fail.
            guard let data = textLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let attachment = object["attachment"] as? [String: Any],
                  (attachment["type"] as? String) == "total_tokens_reminder",
                  let reminder = attachment["text"] as? String,
                  let match = reminder.firstMatch(of: pattern)
            else { continue }
            guard let value = Int(match.1) else { continue }
            let lineNumber = offset + 1
            if worst == nil || value < worst!.tokensLeft {
                worst = PressureReading(tokensLeft: value, lineNumber: lineNumber)
            }
        }
        return worst
    }
}

// Reading token counts out of Claude Code's own session logs.
//
// This is the first adapter the protocol was designed for, and it is also the first
// place two assumptions had to be checked against a real file rather than a guess.
//
// WHAT THE FORMAT ACTUALLY LOOKS LIKE (Claude Code, macOS)
//
// One JSONL file per session under `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`.
// Lines are heterogeneous: most carry nothing about usage, and a summary line carries
//
//   "modelUsage": { "<model>": { inputTokens, outputTokens, thinkingTokens,
//                              cacheReadInputTokens, cacheCreationInputTokens,
//                              costUSD } }
//   "totalCostUSD": 0.83695...
//
// Two properties of that shape drive everything here:
//
// 1. **It is per model.** A session that escalated `model-a` → `model-b` reports each
//    model's counts separately, so the breakdown is available and each model can be
//    priced at its own rate. That is what retires the known-unsound case where a
//    single cumulative total gets priced entirely at the newest model's rate.
//
// 2. **It is cumulative.** Reading one file twice gives the same totals, not a sum.
//    So this returns totals, and the runner's latest-per-segment fold is what makes
//    repeated runs idempotent.
//
// THE MATCHING PROBLEM
//
// A Portmaster session is an MCP connection UUID. This log is named for Claude Code's
// own session id. **The two share no key.** The only correlation is time: a log whose
// activity overlaps the connection's lifetime is a candidate. That is a heuristic, and
// a heuristic that picks when it is unsure produces a number that is confidently
// wrong — so `logCandidates` returns every log it can see and `AgentLogMatcher`
// applies the uniqueness rule. Two agents running at once overlap one window, and
// that is reported as an absence rather than resolved by a guess.
//
// HONEST LIMITS OF WHAT COMES BACK
//
// These are the limits this adapter has. They are not a complete account of what is
// wrong with parsed figures, and the ones below are not the whole list.
//
// - **THE FIGURE IS THE WHOLE CONVERSATION, NOT THE CONNECTED WINDOW.** This is the
//   largest of them and it is not about matching at all. `parse` returns cumulative
//   totals for the entire file, and a Claude Code log is one continuously-written file
//   per conversation — so the matcher proves only that the file's *last write* fell
//   inside a connection's window, which says nothing about where the conversation
//   began. A conversation that started an hour before the connection opened and ran for
//   twenty minutes after it closed contributes **all** of its tokens to the one session
//   whose window happened to contain its final timestamp. There is no per-window
//   subtraction to apply: the format carries no session boundary and the file records
//   nothing about when any given line's tokens were spent.
//
//   **It concentrates where there is no self-report.** `preferredProvenance` prefers
//   `selfReported` and bills the parsed figure only where none exists, so the sessions
//   most exposed to this are exactly the ones whose agent called no `report_usage`.
//
// - **`.ambiguousMatch` will be common on a machine with several sessions recorded**, and
//   that is the rule working rather than a failure to be tuned away. See
//   `AgentLogMatcher`: a file more than one session could claim belongs to none of them.
// - **A log whose shape has changed stays `unrecognizedFormat`** — never a partial
//   parse, which would be a plausible wrong number.
// - **Wiring this in makes two previously unreachable limitations reachable**: the
//   self-report/partial-log-parse overlap, which now *inflates* where it previously
//   *blocked* a figure (pinned by a test named `…ThatFigureIsKnownWrong`), and the 1%
//   disagreement tolerance, which has never been validated against real disagreement.
//   Neither is fixed by parsing a log, and both are documented in the README.
//
// WHAT IS *NOT* TAKEN FROM THE LOG
//
// `costUSD` and `totalCostUSD` are read and then ignored. They are Claude Code's
// pricing, and Portmaster's figures come from the user's own price table; adopting
// the vendor's number would put two price sources in one record and make it unclear
// which one a figure meant. The presence of those keys is only evidence that the line
// is the summary we are after.

import Foundation

/// Reads Claude Code session logs from their conventional location.
public struct ClaudeCodeLogAdapter: TokenSourceAdapter {
    public let identifier = "claude-code"

    /// `~/.claude/projects`, or an override so tests can point at a fixture tree
    /// instead of the developer's own sessions.
    ///
    /// **The only parameter, and that is the whole signature.** This adapter used to
    /// carry an `overlap` of its own; with the window applied by `AgentLogMatcher` it
    /// bounded nothing a caller could see — `logCandidates()` has no session to measure
    /// against, so any bound it applied here was a second, separately-configured window
    /// that silently narrowed the matcher whenever it was set smaller. `projectsRoot`
    /// alone says what this type actually decides.
    private let projectsRoot: URL

    /// No stored `FileManager`: it is not `Sendable`, and this type is required to be.
    /// Enumeration is a few calls against the default instance, which needs no stored
    /// reference — so the honest fix is not to silence the warning but to stop holding
    /// a non-Sendable type for a convenience that already exists.
    public init(projectsRoot: URL? = nil) {
        self.projectsRoot = projectsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Every log under the projects root, each with **the interval it was written
    /// across**, whatever its age.
    ///
    /// No session is consulted, and none could be: a pass asks once and matches every
    /// session against the result, so a method that filtered by a window would need a
    /// session it is not given. Age is therefore not this type's decision — it is
    /// `AgentLogMatcher`'s, and a month-old log reaches it and is dropped there, which is
    /// the only place with the connection it would be dropped against.
    public func logCandidates() -> [LogCandidate] {
        // A missing root is a machine that has never run the agent, which is an absence
        // rather than a failure, so an unwalkable directory yields nothing.
        guard let walker = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [LogCandidate] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            candidates.append(LogCandidate(url: url, interval: interval(of: url)))
        }
        // Sorted by path so a caller inspecting candidates sees a stable order.
        return candidates.sorted { $0.url.path < $1.url.path }
    }

    // MARK: - The conversation's interval

    /// When this conversation was being written, as the log itself says.
    ///
    /// **Line timestamps first, filesystem metadata only as a labelled fallback.** The
    /// log's own timestamps are the only evidence that can place a connection *inside* a
    /// conversation rather than merely near its last write — `mtime` says when the file
    /// was last touched and nothing about when it began, which is the whole difference
    /// between a span and a point. When no line carries one, `mtime` stands in and the
    /// candidate says so in `evidence`, because a weaker claim wearing a stronger one's
    /// name is how a plausible wrong number ships.
    ///
    /// Nil when neither source answers, which is the only case in which the file is still
    /// listed: a log that cannot be placed is visible to a diagnostic that way, and
    //  matches nobody.
    private func interval(of url: URL) -> LogInterval? {
        if let data = try? Data(contentsOf: url),
           let span = Self.lineTimestampSpan(in: data) {
            return LogInterval(
                start: Date(timeIntervalSince1970: span.earliest),
                end: Date(timeIntervalSince1970: span.latest),
                evidence: .lineTimestamps
            )
        }
        guard let modified = modificationDate(of: url) else { return nil }
        return LogInterval(start: modified, end: modified, evidence: .fileModification)
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Timestamp extraction

    /// Earliest and latest of every `"timestamp"` value in a JSONL log, as epoch seconds.
    ///
    /// **A byte scan for a fixed-width ISO-8601 shape, not `JSONSerialization` per line
    /// and not `ISO8601DateFormatter`.** Measured on this machine's 712 KB / 423-line
    /// log, warm, 200 iterations:
    ///
    /// | | |
    /// |---|---|
    /// | `attributesOfItem` (what a `stat` costs) | 0.04 ms |
    /// | read the whole file, touch nothing | 0.05 ms |
    /// | **this scan** | **1.05 ms** |
    /// | read all + `ISO8601DateFormatter` per line | 33.2 ms |
    ///
    /// So reading the file is not the cost — parsing the timestamps is, and by two and a
    /// half orders of magnitude. This is what makes the 30-second pass affordable: at
    /// 1 ms it is 0.003% of one core per conversation, where the obvious implementation
    /// would have been 0.03% per *line*. The cost is linear in the conversation's size,
    /// which is stated rather than bounded: a cap would truncate the interval at an
    /// arbitrary byte and quietly answer a different question.
    ///
    /// **Every line is read, so out-of-order timestamps are handled** — this file has six
    /// of them — and min and max are exact rather than the first and last line's values.
    /// A cheaper head-and-tail read would be 0.2 ms and wrong: the last timestamped line
    /// here is 419 of 423, and nothing guarantees a burst of lines is written in time
    /// order.
    ///
    /// The marker could in principle appear inside a message body quoting it. The fixed
    /// shape check below is what keeps that harmless — quoted prose does not parse as
    /// `YYYY-MM-DDTHH:MM:SS` — and a miss would cost a timestamp, never invent one.
    static func lineTimestampSpan(in data: Data) -> (earliest: Double, latest: Double)? {
        let bytes = [UInt8](data)
        let marker = Array("\"timestamp\":\"".utf8)
        var earliest = Double.infinity
        var latest = -Double.infinity
        var found = false
        var index = 0
        while index + marker.count + minimumStampLength <= bytes.count {
            var atMarker = true
            for offset in 0..<marker.count where bytes[index + offset] != marker[offset] {
                atMarker = false
                break
            }
            if atMarker,
               let epoch = iso8601Epoch(at: bytes, index + marker.count)
            {
                found = true
                if epoch < earliest { earliest = epoch }
                if epoch > latest { latest = epoch }
            }
            index += 1
        }
        return found ? (earliest, latest) : nil
    }

    /// The length of `YYYY-MM-DDTHH:MM:SS` with nothing optional: **19**, which is
    /// where the fraction and the `Z` may begin. Spelled as a constant rather than
    /// computed because getting it wrong by one silently skips the `.` and reads the
    /// first fraction digit as the second field — a parser that finds no timestamps and
    /// falls back, which is exactly the sort of quiet miss this whole change is about.
    private static let minimumStampLength = 19

    /// Epoch seconds for an ISO-8601 UTC timestamp at `start`, or nil if the bytes there
    /// are not one.
    ///
    /// Hand-rolled rather than `ISO8601DateFormatter`, which measured 33 ms for the same
    /// file. Days-from-epoch is counted directly instead: a log's 354 timestamps do not
    /// need a Gregorian calendar engine, and `DateFormatter` would be both slower and a
    /// locale dependency in the middle of a matching decision.
    private static func iso8601Epoch(at s: [UInt8], _ start: Int) -> Double? {
        func digits(_ offset: Int, _ width: Int) -> Int? {
            var value = 0
            for k in offset..<(offset + width) {
                let c = s[k]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        func isByte(_ offset: Int, _ character: UInt8) -> Bool { s[offset] == character }

        guard start + minimumStampLength <= s.count,
              isByte(start + 4, 45), isByte(start + 7, 45), isByte(start + 10, 84),
              isByte(start + 13, 58), isByte(start + 16, 58),
              let year = digits(start, 4), let month = digits(start + 5, 2),
              let day = digits(start + 8, 2), let hour = digits(start + 11, 2),
              let minute = digits(start + 14, 2), let second = digits(start + 17, 2),
              (1...12).contains(month)
        else { return nil }

        var fraction = 0.0
        var cursor = start + minimumStampLength
        if cursor < s.count, s[cursor] == 46 {
            cursor += 1
            var scale = 0.1
            while cursor < s.count, s[cursor] >= 48, s[cursor] <= 57, scale > 0.000_001 {
                fraction += Double(s[cursor] - 48) * scale
                scale *= 0.1
                cursor += 1
            }
        }
        // Only UTC is accepted, and only because it is the only shape this format uses.
        // A log written in an offset zone would be misread as UTC — a fact about this
        // adapter's input that belongs in its own comment, not silently absorbed here.
        guard cursor < s.count, s[cursor] == 90 /* Z */ else { return nil }

        let monthLengths = [31, Self.isLeapYear(year) ? 29 : 28, 31, 30, 31, 30,
                            31, 31, 30, 31, 30, 31]
        guard (1...31).contains(day), day <= monthLengths[month - 1],
              hour < 24, minute < 60, second < 61
        else { return nil }

        var days = 0
        if year >= 1970 {
            for y in 1970..<year { days += Self.isLeapYear(y) ? 366 : 365 }
            for m in 1..<month { days += monthLengths[m - 1] }
        } else {
            for y in year..<1970 { days -= Self.isLeapYear(y) ? 366 : 365 }
            for m in month...12 { days -= monthLengths[m - 1] }
        }
        days += day - 1
        return Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second) + fraction
    }

    private static func isLeapYear(_ year: Int) -> Bool {
        year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    }

    /// Parses the summary lines into one entry per model.
    ///
    /// **Throws rather than returning a partial total** if the file parses as JSONL
    /// but carries no `modelUsage` anywhere. A file whose shape has changed is the
    /// case this whole protocol exists for, and a parse that returned zeros would
    /// look identical to an agent that used nothing.
    public func parse(_ url: URL) throws -> [RawAgentUsage] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw TokenSourceError.unreadable
        }

        var latest: [String: RawAgentUsage] = [:]
        var sawModelUsage = false

        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = object["modelUsage"] as? [String: Any]
            else { continue }
            sawModelUsage = true
            for (model, entry) in usage {
                guard let counts = entry as? [String: Any] else { continue }
                let input = Self.int(counts["inputTokens"])
                let output = Self.int(counts["outputTokens"])
                let thinking = Self.int(counts["thinkingTokens"])
                let cacheRead = Self.optionalInt(counts["cacheReadInputTokens"])
                let latestForModel = latest[model]
                // Cumulative within a file, so a later line is a bigger total. Taking
                // it unconditionally would let a file whose lines ran out of order
                // report a smaller number than one it already had.
                if latestForModel == nil || (input + output) >= (latestForModel!.input + latestForModel!.output) {
                    latest[model] = RawAgentUsage(
                        input: input,
                        output: output,
                        cacheRead: cacheRead,
                        reasoning: thinking == 0 ? nil : thinking,
                        modelID: model
                    )
                }
            }
        }

        guard sawModelUsage, !latest.isEmpty else {
            // Readable, JSONL, and no usage in it. Either a format change or a session
            // that genuinely ran nothing — and the two cannot be told apart from
            // outside, so neither is claimed.
            throw TokenSourceError.unrecognizedFormat
        }
        // Sorted by model so the same file always yields the same order.
        return latest.keys.sorted().compactMap { latest[$0] }
    }

    // MARK: - Helpers

    /// A missing field is 0, not an absence: these counts are additive and a log that
    /// omits `thinkingTokens` means no thinking tokens, not "unknown".
    private static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return 0
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        guard value != nil else { return nil }
        let n = int(value)
        return n == 0 ? nil : n
    }
}
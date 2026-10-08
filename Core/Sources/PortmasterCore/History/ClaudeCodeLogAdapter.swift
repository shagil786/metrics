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
// own session id. **The two share no key.** The only correlation is time, and the
// question is which times: `AgentLogMatcher` asks whether the conversation's own interval
// contains the moment the connection opened. A connection during the conversation is that
// conversation's; yesterday's connection is not, because yesterday is not inside it.
//
// HONEST LIMITS OF WHAT COMES BACK
//
// These are the limits this adapter has. They are not a complete account of what is wrong
// with parsed figures, and the ones below are not the whole list.
//
// - **THE FIGURE IS THE WHOLE CONVERSATION, NOT THE CONNECTED WINDOW.** This is the
//   largest of them and it is not about matching at all. `parse` returns cumulative
//   totals for the entire file, and a Claude Code log is one continuously-written file per
//   conversation. The matcher establishes that the connection opened *during* the
//   conversation — it knows where the conversation began and when it ended, and that is
//   genuinely new — and none of that says *when any given token was spent*. A connection
//   that opened an hour before the first logged line still matches, and is billed for the
//   whole conversation including the part before it arrived. There is no subtraction to
//   apply: the format carries no per-line attribution of which model or call a token
//   belongs to across a session boundary, so there is no boundary to subtract at.
//
//   **It concentrates where there is no self-report.** `preferredProvenance` prefers
//   `selfReported` and bills the parsed figure only where none exists, so the sessions
//   most exposed to this are exactly the ones whose agent called no `report_usage`.
//
// - **One long conversation plus any second Portmaster connection inside it yields no
//   figures at all.** This is the shape of near-inertness the interval rule was meant to
//   remove, and it survives in a narrower form: one 8-hour conversation with four
//   connections inside it gives `ambiguousMatch` for all four, while four separate
//   20-minute conversations give a unique match for all four. So the feature is live or
//   inert depending on **whether the agent reused its MCP connection** — and connections
//   are re-established on `/mcp` reconnect, server restart, Portmaster restart, idle
//   timeout and sleep/wake. Nothing can be done about it here: the conversation is one
//   file, the tokens are one cumulative total, and there is no way to split it between two
//   connections without a per-call boundary the format does not carry.
//
// - **A log with no line timestamps is never placed.** Every line of this machine's log
//   carries `timestamp` on 362 of 423 lines and none of the other 61 matter, but a log
//   whose lines carry none cannot be placed in time at all and matches nothing. There is
//   deliberately no fallback to the file's modification time: a point where a span is
//   wanted cannot answer a question about containment, and padding one to make it answer
//   rebuilt the rule this replaced.
//
// - **`.ambiguousMatch` means one of two different things**, and `UsageUnavailableReason`
//   has one case for both, because a withdrawal record cannot carry which: one
//   conversation several connections fell inside, or several conversations one
//   connection fell inside. Neither is a tie to break.
//
// - **A log whose shape has changed stays `unrecognizedFormat`** — never a partial parse,
//   which would be a plausible wrong number.
//
// - **Wiring this in makes two previously unreachable limitations reachable**: the
//   self-report/partial-log-parse overlap, which now *inflates* where it previously
//   *blocked* a figure (pinned by a test named `…ThatFigureIsKnownWrong`), and the 1%
//   disagreement tolerance, which has never been validated against real disagreement.
//   Neither is fixed by parsing a log, and both are documented in the README.
//
// - **A figure already written is withdrawn, not left standing.** A conversation's
//   interval only grows, so a session uniquely matched at one pass can become
//   unattributable at the next. The pass that knows records that as
//   `TokenProvenance.parseWithdrawn` and the fold honours it, so the store stops showing
//   a priced figure for a session the current rule refuses.
//
// // WHAT IS *NOT* TAKEN FROM THE LOG
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
    /// across**, filtered by age.
    ///
    /// No session is consulted, and none could be: a pass asks once and matches every
    /// session against the result, so a method that filtered by a session would need a
    /// session it is not given. `newerThan` is not a session — it is the earliest instant
    /// any session in this pass could match, which the caller derives.
    ///
    /// **The age filter is a cost bound, and it is safe because the interval cannot reach
    /// past the file's own last write.** A conversation's last line was written at or
    /// before the moment the file was last modified, so a file whose `mtime` predates
    /// `newerThan` has an interval that ends before it, and no session at or after that
    /// instant can be inside it. Without the filter this method reads **every** `.jsonl`
    /// on the machine, at any age, every 30 seconds, forever — measured at 2.63 ms per
    /// 712 KB, so ~300 conversations is ~0.8 s per pass and ~1 GB of logs is ~3.7 s,
    /// roughly 12% of a core continuously, spent on intervals the matcher then discards.
    /// The cost is linear in the *number* of conversations on the machine, which is the
    /// axis that grows without limit and the one a per-conversation figure hides.
    ///
    /// The bound assumes a monotonic clock. A machine whose clock stepped backwards
    /// mid-conversation could leave a line stamped after the file's last write, and such a
    /// file would be dropped rather than matched — an absence, which is the direction
    /// that invents nothing.
    ///
    /// Its cost is visibility: a log older than the bound is not listed at all, so "there
    /// is a log here that cannot be placed" becomes "no log newer than the oldest session
    /// worth matching". A diagnostic wanting the full tree passes `nil`.
    public func logCandidates(newerThan: Date? = nil) -> [LogCandidate] {
        // A missing root is a machine that has never run the agent, which is an absence
        // rather than a failure, so an unwalkable directory yields nothing.
        guard let walker = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var candidates: [LogCandidate] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            // The enumerator already carries the modification date, so this reads it
            // rather than paying a second `attributesOfItem` per file to ask again.
            guard let modified = modificationDate(of: url) else { continue }
            if let newerThan, modified < newerThan { continue }
            candidates.append(LogCandidate(url: url, interval: interval(of: url)))
        }
        // Sorted by path so a caller inspecting candidates sees a stable order.
        return candidates.sorted { $0.url.path < $1.url.path }
    }

    // MARK: - The conversation's interval

    /// When this conversation was being written, as the log itself says.
    ///
    /// **Line timestamps only.** The log's own timestamps are the only evidence that can
    /// place a connection *inside* a conversation rather than merely near its last write.
    /// A file whose lines carry none yields nil — it is listed, and it matches nobody —
    /// because a modification time is a point where a span is wanted, and the only way to
    /// make a point answer a containment question was to pad it into a window, which is
    /// the rule this whole change removed.
    private func interval(of url: URL) -> LogInterval? {
        guard let data = try? Data(contentsOf: url),
              let span = Self.lineTimestampSpan(in: data)
        else { return nil }
        return LogInterval(
            start: Date(timeIntervalSince1970: span.earliest),
            end: Date(timeIntervalSince1970: span.latest)
        )
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Timestamp extraction

    /// Earliest and latest of every `"timestamp"` value in a JSONL log, as epoch seconds.
    ///
    /// **A byte scan for a fixed-width ISO-8601 shape, not `JSONSerialization` per line
    /// and not `ISO8601DateFormatter`.** Measured on this machine's 712 KB / 423-line log,
    /// warm, 200 iterations:
    ///
    /// | | |
    /// |---|---|
    /// | `attributesOfItem` (what a `stat` costs) | 0.04 ms |
    /// | read the whole file, touch nothing | 0.05 ms |
    /// | **this scan** | **1.05 ms** |
    /// | read all + `JSONSerialization` per line | 5.68 ms |
    /// | read all + byte-split + `contains` per line | 26.53 ms |
    /// | read all + `ISO8601DateFormatter` per line | 33.20 ms |
    ///
    /// Reading the file is not the cost — parsing the timestamps is, by two and a half
    /// orders of magnitude. `logCandidates(newerThan:)` bounds *which* files are read; this
    /// bounds what reading one costs.
    ///
    /// **Every line is read, so out-of-order timestamps are handled**: this log's are not
    /// monotonic — 6 adjacent pairs step backwards and 10 values fall below the running
    /// maximum — and min and max are exact rather than the first and last line's values. A
    /// cheaper head-and-tail read would be 0.19 ms and would report a span the log does not
    /// claim: the last timestamped line here is 419 of 423, and nothing guarantees a burst
    /// of lines is written in time order.
    ///
    /// The key is found as a key, not as a literal. JSON-legal whitespace around the colon
    /// (`"timestamp" : "…"`) is legal and appears in hand-formatted logs, and matching the
    /// fixed literal dropped **every** timestamp in **every** such file — which is not one
    /// file falling back to `mtime` but the whole feature reverting to the rule this change
    /// removed, with none of it visible. The marker is scanned for as `"timestamp"` and the
    /// separator around `:` is skipped, so the scan survives formatting.
    static func lineTimestampSpan(in data: Data) -> (earliest: Double, latest: Double)? {
        let bytes = [UInt8](data)
        let key = Array("\"timestamp\"".utf8)
        var earliest = Double.infinity
        var latest = -Double.infinity
        var found = false
        var index = 0
        while index + key.count + minimumStampLength <= bytes.count {
            guard matches(key, in: bytes, at: index) else {
                index += 1
                continue
            }
            // `"timestamp"` then JSON-legal whitespace, `:`, whitespace, then the opening
            // quote of the value. Everything about the shape is checked, because a key that
            // merely looks like this one — a nested object with its own `timestamp` — is
            // common and its value may be anything at all.
            guard let valueStart = valueStartAfterColon(
                bytes, from: index + key.count
            ) else {
                index += 1
                continue
            }
            if let epoch = iso8601Epoch(at: bytes, valueStart) {
                found = true
                if epoch < earliest { earliest = epoch }
                if epoch > latest { latest = epoch }
            }
            index += 1
        }
        return found ? (earliest, latest) : nil
    }

    /// The length of `YYYY-MM-DDTHH:MM:SS` with nothing optional: **19**, which is where
    /// the fraction and the `Z` may begin. Spelled as a constant because getting it wrong
    /// by one silently skips the `.` and reads the first fraction digit as a second field
    /// — a parser that then finds no timestamps at all and falls back, which is exactly the
    /// quiet miss this whole change is about, and which happened once.
    private static let minimumStampLength = 19

    private static func matches(_ pattern: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// Where the value begins, after `"timestamp"`, JSON-legal whitespace, `:` and more
    /// whitespace — or nil if the key is not followed by a quoted value.
    private static func valueStartAfterColon(_ bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        func skipWhitespace() {
            while cursor < bytes.count,
                  bytes[cursor] == 32 || bytes[cursor] == 9
                    || bytes[cursor] == 10 || bytes[cursor] == 13 {
                cursor += 1
            }
        }
        skipWhitespace()
        guard cursor < bytes.count, bytes[cursor] == 58 /* : */ else { return nil }
        cursor += 1
        skipWhitespace()
        guard cursor < bytes.count, bytes[cursor] == 34 /* " */ else { return nil }
        return cursor + 1
    }

    /// Epoch seconds for an ISO-8601 UTC timestamp at `start`, or nil if the bytes there
    /// are not one.
    ///
    /// Hand-rolled rather than `ISO8601DateFormatter`, which measured 33 ms for this file.
    /// Days-from-epoch is counted directly: a log's timestamps do not need a Gregorian
    /// calendar engine, and `DateFormatter` would be both slower and a locale dependency in
    /// the middle of a matching decision.
    ///
    /// **Precision accepted: any number of fractional digits, of which the first six
    /// contribute and the rest are truncated.** The earlier version stopped accumulating
    /// and left the cursor sitting on a digit rather than on the `Z`, so a timestamp with
    /// six or more fractional digits was *rejected* — and a file whose timestamps all had
    /// them fell back for the whole feature, silently. Digits are now always consumed to
    /// the end of the fraction; only the arithmetic stops, at 100 ns, which is finer than
    /// any figure this module prints.
    ///
    /// **Only `Z` is accepted, and the consequence of that is a dropped timestamp rather
    /// than a wrong one.** An offset form (`+05:30`) is rejected, so a log written in one
    /// contributes no interval at all and is placed by nothing. It is not read as UTC: the
    /// shape check refuses it first.
    ///
    /// Years before 1970 are refused for the same reason. They cannot occur in a log, and
    /// the branch that would have handled them subtracted a whole year *and* the current
    /// month, putting `1969-12-31T23:59:59Z` 365 days out — the one input class here that
    /// produced a wrong interval rather than a fallback.
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
              year >= 1970, (1...12).contains(month)
        else { return nil }

        var fraction = 0.0
        var cursor = start + minimumStampLength
        if cursor < s.count, s[cursor] == 46 /* . */ {
            cursor += 1
            var scale = 0.1
            // Every digit is consumed; only the arithmetic stops. Leaving a digit behind
            // would put the `Z` check below on a digit and reject the whole timestamp.
            // **Counted, not compared against a scale.** A `scale > 1e-7` test is decided
            // by a floating-point comparison that `1e-6 * 0.1` loses — it lands just above
            // 1e-7 in binary — so which digits contributed depended on rounding. An
            // integer count makes "the first six contribute" true rather than nearly true.
            var contributing = 0
            while cursor < s.count, s[cursor] >= 48, s[cursor] <= 57 {
                if contributing < 6 {
                    fraction += Double(s[cursor] - 48) * scale
                    contributing += 1
                }
                scale *= 0.1
                cursor += 1
            }
        }
        guard cursor < s.count, s[cursor] == 90 /* Z */ else { return nil }

        let monthLengths = [31, Self.isLeapYear(year) ? 29 : 28, 31, 30, 31, 30,
                            31, 31, 30, 31, 30, 31]
        guard (1...31).contains(day), day <= monthLengths[month - 1],
              hour < 24, minute < 60, second < 61
        else { return nil }

        var days = 0
        for year in 1970..<year { days += Self.isLeapYear(year) ? 366 : 365 }
        for month in 1..<month { days += monthLengths[month - 1] }
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
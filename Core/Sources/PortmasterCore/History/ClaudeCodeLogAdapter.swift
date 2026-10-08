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

    /// Every log under the projects root, with its last write time, **whatever its age**.
    ///
    /// No session is consulted, and none could be: a pass enumerates once and matches
    /// every session against the result, so a method that filtered by a window would
    /// need a session it is not given. Age is therefore not this type's decision — it
    /// is `AgentLogMatcher`'s, and a month-old log on the machine reaches the matcher
    /// and is dropped there, which is where the session it might belong to is known.
    ///
    /// Enumerated rather than indexed: the directory is one file per agent session on
    /// the machine. Every file is `stat`ed to read its timestamp whatever this does, so
    /// an index would only avoid a walk — not the syscall the cost is actually made of.
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
            // An unreadable timestamp leaves nothing to match on, so a file whose
            // modification time cannot be read is not a candidate — guessing one would
            // be a correlation invented rather than observed.
            guard let modified = modificationDate(of: url) else { continue }
            candidates.append(LogCandidate(url: url, modifiedAt: modified))
        }
        // Sorted by path so a caller inspecting candidates sees a stable order.
        return candidates.sorted { $0.url.path < $1.url.path }
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

    private func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

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
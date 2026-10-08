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
//    So this returns totals, and the runner's latest-per-provenance fold is what makes
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
// - **`.ambiguousMatch` will be common on a machine with several agents running**, and
//   that is the rule working rather than a failure to be tuned away. Two logs
//   overlapping one session means nothing ties either to it.
// - **A log whose shape has changed stays `unrecognizedFormat`** — never a partial
//   parse, which would be a plausible wrong number.
// - **Wiring this in makes two previously unreachable limitations reachable**: the
//   self-report/partial-log-parse overlap, which now *inflates* where it previously
//   *blocked* a figure (pinned by a test named `…ThatFigureIsKnownWrong`), and the 1%
//   disagreement tolerance, which has never been validated against real disagreement.
//   Neither is fixed by parsing a log, and both are documented in the README.
//
// WHAT IS NOT TAKEN FROM THE LOG
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
    private let projectsRoot: URL
    /// How far off the clock a file's timestamp may be and still be believed.
    ///
    /// **This is not the session window.** Generosity there is `overlap`, and it is
    /// `AgentLogMatcher`'s to apply, because a session is what it is measured against.
    /// What this guards is the other direction: a file stamped beyond `now + overlap`
    /// was not written by a session that has not connected yet, so it is dropped
    /// rather than handed to the matcher to discard. One condition, same bound the
    /// matcher uses, kept here so an adapter does not spend the machine's file list on
    /// entries that cannot match.
    private let overlap: TimeInterval

    /// No stored `FileManager`: it is not `Sendable`, and this type is required to be.
    /// Enumeration is a few calls against the default instance, which needs no stored
    /// reference — so the honest fix is not to silence the warning but to stop holding
    /// a non-Sendable type for a convenience that already exists.
    public init(
        projectsRoot: URL? = nil,
        overlap: TimeInterval = 60 * 60
    ) {
        self.projectsRoot = projectsRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
        self.overlap = overlap
    }

    /// Every log under the projects root, with its last write time. **No session is
    /// consulted**: matching a session against this list is `AgentLogMatcher`'s job, and
    /// doing it here would put one session's window into a method that sees none.
    ///
    /// Enumerated rather than indexed: the directory is one file per agent session on
    /// the machine. `AgentSourcePoller` asks once per pass on a 30-second lane, and the
    /// directory read is a handful of stat calls — so a maintained index would be more
    /// machinery than the question earns.
    public func logCandidates() -> [LogCandidate] {
        // A missing root is a machine that has never run the agent, which is an
        // absence rather than a failure, so an unwalkable directory yields nothing
        // instead of throwing.
        guard let walker = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let notAfter = Date().addingTimeInterval(overlap)
        var candidates: [LogCandidate] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            // An unreadable timestamp leaves nothing to match on, so a file whose
            // modification time cannot be read is not a candidate — guessing one would
            // be a correlation invented rather than observed.
            guard let modified = modificationDate(of: url), modified <= notAfter else {
                continue
            }
            candidates.append(LogCandidate(url: url, modifiedAt: modified))
        }
        // Sorted by path so a caller inspecting candidates sees a stable order, and so
        // the single-match case is deterministic on a machine holding more than one log.
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
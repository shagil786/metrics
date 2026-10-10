// Core/Sources/PortmasterCore/History/HandoffBrief.swift
import Foundation

/// One claim extracted from a conversation log, with the physical log line it
/// came from. The line is the whole point: a brief without citations is a
/// sentence we invented, and the receiving agent must be able to walk to the
/// source of every claim it acts on (spec §2).
public struct BriefItem: Equatable, Sendable {
    public let text: String
    /// 1-based physical line number in the source JSONL file.
    public let line: Int
    public init(text: String, line: Int) {
        self.text = text
        self.line = line
    }
}

/// A reconstructed handoff brief: the conversation, sourced. Sections that have
/// nothing behind them are `nil`/empty rather than zero-filled or paraphrased —
/// an absent Goal is a log that had no user turn, not a user who asked nothing.
public struct HandoffBrief: Equatable, Sendable {
    public let goal: BriefItem?
    /// Mutations observed: Write/Edit targets and commands run (spec §2).
    public let done: [BriefItem]
    /// The file operations among them, with their operation (spec §2). Overlaps
    /// `done` on purpose: the spec defines both sections, and a line may be
    /// cited by both.
    public let files: [BriefItem]
    /// The closing turns of the conversation (spec §2).
    public let state: [BriefItem]
    /// What was in flight, where it stopped (spec §2).
    public let next: BriefItem?
    /// The log's own `cwd`, parsed at extraction time — never guessed later
    /// (spec amendment 7).
    public let workingDirectory: String?
    public let sourceLogPath: String
    /// Set by the handoff coordinator before rendering: the extractor cannot
    /// know which Portmaster session's brief this is.
    public var sessionID: UUID?
    /// What the length budget dropped, in the budget's own words (spec §3).
    /// Empty until `budgeted()` runs.
    public var dropped: [String]

    public init(
        goal: BriefItem?, done: [BriefItem], files: [BriefItem],
        state: [BriefItem], next: BriefItem?, workingDirectory: String?,
        sourceLogPath: String, sessionID: UUID? = nil, dropped: [String] = []
    ) {
        self.goal = goal
        self.done = done
        self.files = files
        self.state = state
        self.next = next
        self.workingDirectory = workingDirectory
        self.sourceLogPath = sourceLogPath
        self.sessionID = sessionID
        self.dropped = dropped
    }

    /// Every distinct source line this brief cites, sorted — the audit line's
    /// `lines=` argument and the receiving agent's map back to the log.
    public var citedLines: [Int] {
        var lines = [goal?.line, next?.line].compactMap { $0 }
        lines += (done + files + state).map(\.line)
        return Array(Set(lines)).sorted()
    }

    /// The brief as it ships: header, then sections, then the Dropped list.
    /// Section bodies carry `(line N)` after each claim — the citation is part
    /// of the text the receiving agent reads, not metadata only we can see.
    public func renderedMarkdown() -> String {
        var out = "# Handoff brief\n\n"
        if let sessionID { out += "Session: \(sessionID.uuidString)\n" }
        out += "Source log: \(sourceLogPath)\n"
        if let workingDirectory { out += "Working directory: \(workingDirectory)\n" }
        out += "\n"
        if let goal {
            out += "## Goal\n\(goal.text) (line \(goal.line))\n\n"
        }
        func section(_ title: String, _ items: [BriefItem]) {
            guard !items.isEmpty else { return }
            out += "## \(title)\n"
            out += items.map { "- \($0.text) (line \($0.line))" }.joined(separator: "\n")
            out += "\n\n"
        }
        section("Done", done)
        section("Files touched", files)
        section("State", state)
        if let next {
            out += "## Next\n\(next.text) (line \(next.line))\n\n"
        }
        if !dropped.isEmpty {
            out += "## Dropped\n"
            out += dropped.map { "- \($0)" }.joined(separator: "\n")
            out += "\n"
        }
        return out
    }
}

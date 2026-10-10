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

extension HandoffBrief {
    /// The brief's cap in tokens, provisional: brief quality on real working
    /// sessions is unmeasured (spec §"Evidence is one exploratory session"), so
    /// this is named and recorded like the 1% tolerance and the half-first
    /// threshold rather than presented as a tuned figure.
    public static let budgetTokens = 1500

    /// Tokens as an estimate: **UTF-8 bytes / 4**, stated as an estimate. This
    /// repo has no tokenizer, and a heuristic cap needs a heuristic measure —
    /// what must be exact is that the cap is applied and its drops are named.
    public static func estimateTokens(_ text: String) -> Int {
        text.utf8.count / 4
    }

    /// Enforces the budget by dropping whole sections/items in the spec's
    /// priority order — goal > next > done > files, with state last (spec §3
    /// lists state nowhere in the priority, and the closing turns are the most
    /// reconstructable section) — and clipping the goal last. Every drop is
    /// recorded in `dropped`; truncation is never silent. The notes themselves
    /// cost room, so each pass re-checks the budget and note-inflation
    /// resumes the cascade rather than being allowed to overspend it.
    public func budgeted() -> HandoffBrief {
        // The brief's fields are immutable, so the budget works on locals and
        // reassembles through the shipped init at each checkpoint.
        var goal = self.goal
        var done = self.done
        var files = self.files
        var state = self.state
        var next = self.next
        var dropped = self.dropped
        let originalDoneCount = done.count
        // The clip marker is materialized inside `current()` only once a clip
        // has actually happened, so every budget check pays for the marker
        // the final render will carry — and a goal that never shrank never
        // claims one.
        var goalClipped = false
        func current() -> HandoffBrief {
            var effectiveGoal = goal
            if goalClipped, let item = goal {
                effectiveGoal = BriefItem(
                    text: item.text + "… [clipped to fit the handoff budget]",
                    line: item.line
                )
            }
            return HandoffBrief(
                goal: effectiveGoal, done: done, files: files, state: state, next: next,
                workingDirectory: workingDirectory, sourceLogPath: sourceLogPath,
                sessionID: sessionID, dropped: dropped
            )
        }
        func overBudget() -> Bool {
            Self.estimateTokens(current().renderedMarkdown()) > Self.budgetTokens
        }
        func recordDoneDrop() {
            let removed = originalDoneCount - done.count
            guard removed > 0 else { return }
            let note = "done: \(removed) of \(originalDoneCount) later entries dropped (length budget)"
            if let existing = dropped.lastIndex(where: { $0.hasPrefix("done:") }) {
                // A resumed trim updates the count in place — one note, never
                // a stack of them.
                dropped[existing] = note
            } else {
                dropped.append(note)
            }
        }
        guard overBudget() else { return current() }

        while overBudget() {
            if !state.isEmpty {
                let count = state.count
                state = []
                dropped.append(
                    "state: \(count) closing turns dropped (length budget; lowest priority)"
                )
                continue
            }

            if !files.isEmpty {
                let count = files.count
                files = []
                dropped.append(
                    "files: \(count) entries dropped (length budget; Done cites the same operations)"
                )
                continue
            }

            if !done.isEmpty {
                done.removeLast()
                recordDoneDrop()
                continue
            }

            if let item = next {
                next = nil
                dropped.append("next: \"\(item.text)\" dropped (length budget)")
                continue
            }

            // The goal is the one thing never dropped — a brief without the
            // user's request is not a brief. It is clipped, and the clip says
            // so, but only once the text has actually shrunk.
            if let item = goal, item.text.count > 64 {
                goal = BriefItem(text: String(item.text.prefix(item.text.count / 2)), line: item.line)
                if !goalClipped {
                    goalClipped = true
                    dropped.append("goal: clipped to fit the length budget (its line is unchanged)")
                }
                continue
            }

            // Nothing left that can shrink — over budget is the honest answer.
            break
        }
        return current()
    }
}

// Core/Sources/PortmasterCore/History/HandoffBriefExtractor.swift
import Foundation

/// Reconstructs a handoff brief from a Claude Code JSONL log.
///
/// Only claims the log makes are emitted, each with its line. Entries that are
/// not conversation turns (modes, attachments, reminders, tool results) are
/// skipped rather than reinterpreted; a section with nothing behind it stays
/// empty.
public enum HandoffBriefExtractor {

    public static func extract(from url: URL) throws -> HandoffBrief {
        let text = try String(contentsOf: url, encoding: .utf8)
        return extract(from: text, sourceLogPath: url.path)
    }

    public static func extract(from text: String, sourceLogPath: String) -> HandoffBrief {
        var goal: BriefItem?
        var turns: [BriefItem] = []          // user-string and assistant-text, line order
        var workingDirectory: String?

        // tool_use in line order, and the ids a tool_result ever answered.
        var toolUses: [(id: String, item: BriefItem, input: [String: Any])] = []
        var answered: Set<String> = []
        // Mutations keyed by their tool_use id: whether the in-flight call
        // stays in Done is decided after the walk, once the pending id is
        // known, so each claim must carry the id that produced it.
        var mutations: [(id: String, done: BriefItem, file: BriefItem?)] = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, raw) in lines.enumerated() {
            let lineNumber = offset + 1
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if workingDirectory == nil,
               let cwd = object["cwd"] as? String, !cwd.isEmpty {
                workingDirectory = cwd
            }

            switch object["type"] as? String {
            case "user":
                guard let message = object["message"] as? [String: Any] else { break }
                if let content = message["content"] as? String {
                    // Strip a wrapped system-reminder; a turn with nothing left
                    // after the marker carried no user words at all.
                    let visible = content
                        .components(separatedBy: "<system-reminder>").first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !visible.isEmpty {
                        let item = BriefItem(text: visible, line: lineNumber)
                        turns.append(item)
                        if goal == nil { goal = item }
                    }
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        if let id = block["tool_use_id"] as? String { answered.insert(id) }
                    }
                }
            case "assistant":
                guard let message = object["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]]
                else { break }
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            turns.append(BriefItem(text: text, line: lineNumber))
                        }
                    case "tool_use":
                        guard let id = block["id"] as? String,
                              let name = block["name"] as? String,
                              let input = block["input"] as? [String: Any]
                        else { continue }
                        toolUses.append((id, BriefItem(text: "", line: lineNumber), input))
                        if let claim = mutation(name: name, input: input, line: lineNumber) {
                            mutations.append((id, claim.done, claim.file))
                        }
                    default:
                        continue
                    }
                }
            default:
                continue
            }
        }

        // Next: the last tool_use no tool_result ever answered, else the last
        // assistant text — where it stopped, either way.
        let pending = toolUses.last(where: { !answered.contains($0.id) })
        let next: BriefItem?
        if let pending {
            next = BriefItem(text: nextText(for: pending), line: pending.item.line)
        } else {
            next = turns.last
        }

        // In a log that completes tool results, the call Next names as
        // unfinished is not also claimed by Done. A log with no tool_result
        // anywhere exhibits no completion mechanism to be missing from —
        // its observed action stays in Done.
        let inFlight = answered.isEmpty ? nil : pending?.id
        return HandoffBrief(
            goal: goal,
            done: mutations.filter { $0.id != inFlight }.map(\.done),
            files: mutations.filter { $0.id != inFlight }.compactMap(\.file),
            state: Array(turns.suffix(3)), next: next,
            workingDirectory: workingDirectory, sourceLogPath: sourceLogPath
        )
    }

    private static func mutation(
        name: String, input: [String: Any], line: Int
    ) -> (done: BriefItem, file: BriefItem?)? {
        switch name {
        case "Write":
            guard let path = input["file_path"] as? String else { return nil }
            let item = BriefItem(text: "wrote \(path)", line: line)
            return (done: item, file: item)
        case "Edit", "MultiEdit":
            guard let path = input["file_path"] as? String else { return nil }
            let item = BriefItem(text: "edited \(path)", line: line)
            return (done: item, file: item)
        case "NotebookEdit":
            guard let path = (input["notebook_path"] as? String) ?? (input["file_path"] as? String)
            else { return nil }
            let item = BriefItem(text: "edited \(path)", line: line)
            return (done: item, file: item)
        case "Bash":
            guard let command = input["command"] as? String else { return nil }
            return (done: BriefItem(text: clipped("ran `\(command)`"), line: line), file: nil)
        default:
            return nil
        }
    }

    /// One claim must stay on one line: a 40 kB command would blow the whole
    /// brief budget by itself, and a clipped claim is named by the ellipsis.
    private static func clipped(_ text: String) -> String {
        text.count > 200 ? String(text.prefix(200)) + "…" : text
    }

    private static func nextText(
        for pending: (id: String, item: BriefItem, input: [String: Any])
    ) -> String {
        if let command = pending.input["command"] as? String {
            return clipped("ran `\(command)`")
        }
        if let path = (pending.input["file_path"] as? String)
            ?? (pending.input["notebook_path"] as? String) {
            return path
        }
        // Last resort: a compact form of the input, clipped. The id itself is
        // tool plumbing, not a claim, so it is not printed.
        if let data = try? JSONSerialization.data(
            withJSONObject: pending.input, options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) {
            return json.count > 120 ? String(json.prefix(120)) + "…" : json
        }
        return "an in-flight tool call"
    }
}

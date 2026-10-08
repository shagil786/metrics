// Deciding which of an agent's log files, if any, belongs to which session.
//
// Split out of `TokenSourceRunner` and given no filesystem, because "which file is
// whose?" is the rule most likely to be got quietly wrong and the one hardest to test
// once it is tangled up with a directory walk. On its own it is a function of two
// values — a list of files and the machine's sessions — and every claim about it can be
// asserted without writing a file anywhere.
//
// WHAT THE CORRELATION IS
//
// A Portmaster session is an MCP connection UUID. An agent's log is named for that
// agent's own session. **The two share no key.** The only thing that ties them is
// time, so "which log is this session's" is really "which log was being written while
// this session was open" — a heuristic, and one that is more often wrong than right.
//
// THE RULE IS ONE-TO-ONE, AND IT RUNS OVER THE WHOLE PASS
//
// **A file that more than one session could claim belongs to none of them.** Not "to
// one of them", not "to the most recent of them": to none.
//
// The earlier version of this asked per session and got the mirror of its own rule
// wrong. "Two logs overlapping one session means nothing ties either to it" was
// enforced, and nothing enforced the reverse — that one log overlapping five sessions
// means nothing ties it to any of them. With a session window that runs to *now*, one
// continuously-written Claude Code conversation and five MCP connections made during it
// all contain the same file, so all five matched it: **the same 16,739 tokens recorded
// against five sessions and priced five times.** That is the failure this design exists
// to prevent, in the only direction a downstream check cannot catch — the fold keys on
// `(sessionID, provenance, model)`, so each session got its own plausible segment and
// nothing anywhere could tell the copies from distinct work.
//
// So the question is not "how many files could this session have?" but "how many
// sessions could claim this file?", and the second question cannot be answered one
// session at a time. Hence a whole-pass function: pure, no I/O, and testable with an
// empty list of files.
//
// CONSEQUENCES, stated rather than discovered
//
// - **Two sessions contending for one log both read `ambiguousMatch`.** Correct, and
//   strictly better than one of them winning — a figure is exactly what must not be
//   produced here.
// - **One session with one candidate and another with none: the first still wins.** The
//   rule is about *contention*, not exclusivity. A session nobody else can see into is
//   not ambiguous, and treating it as one would refuse a genuine match because an
//   unrelated session happened to be in the store.
// - **On a machine with several recorded sessions and one live log, nobody matches.** The
//   windows are nested — every session's runs to *now* — so any file the newest session
//   can see, every older session can see too, and the file is contested for all of
//   them. This is a real cost, not a rounding error: `AgentSessionStore` retains every
//   session it has ever recorded, so a machine whose MCP client has connected twice
//   stops producing parsed figures and reports honest absences instead. That is the
//   ruling working, and it is the honest answer to a question the store cannot yet ask
//   — but it means the parsed path is near-inert until retention is enabled. Fixed
//   here in the direction that cannot invent a number; fixing it in the useful
//   direction needs per-session token windows in the log format, which it does not have.
//
// `.ambiguous` is therefore expected to be common, and it is behaviour rather than a
// defect to be tuned away. A machine with one agent connection and one log gets figures.

import Foundation

/// One log file a source could describe, with the time it was last written.
///
/// The modification date travels with the url because it is the whole of the
/// correlation: a session id is an MCP connection UUID and a log is named for the
/// agent's own session, and neither one knows anything about the other.
public struct LogCandidate: Hashable, Sendable {
    public let url: URL
    public let modifiedAt: Date

    public init(url: URL, modifiedAt: Date) {
        self.url = url
        self.modifiedAt = modifiedAt
    }
}

/// What a pass of matching says about one session.
///
/// Named for what it is rather than `Match`: a two-case type called `Match` in a module
/// this size reads as "matched something" at a call site that only cares which of four
/// things went wrong.
///
/// One case per answer rather than an optional candidate plus a flag: "no file", "one
/// file but not this session's alone" and "several files" are three facts, and an
/// optional could carry any of them without saying which.
public enum LogMatch: Hashable, Sendable {
    /// Exactly one file overlaps the session, and no other session can claim it. The
    /// only shape that becomes a number.
    case unique(LogCandidate)
    /// Not attributable to this session. `count` is how many files its own window
    /// holds, which is what makes the three refusals tellable apart:
    ///
    /// - `0` — nothing to read; the machine has no log in this session's window.
    /// - `1` — one file, and one or more other sessions could claim it too. This is the
    ///   contention case, and it is why `count: 1` is not a match.
    /// - `2` or more — more than one file and nothing to choose between them.
    case ambiguous(count: Int)
}

/// The one-to-one rule, in one place.
///
/// A static pure function over `(candidates, sessions, overlap, now)` rather than a
/// nested type or a closure assembled at each call site: two sources matching files two
/// ways is two answers to one question, and this is the question. `now` is a parameter
/// rather than a clock read so a caller takes one reading per pass and every window in
/// that pass is judged against the same instant.
public enum AgentLogMatcher {
    /// One entry per session asked about, keyed by session id — including the sessions
    /// with nothing in their window, because the caller has to record an absence for
    /// each of them.
    ///
    /// **The whole pass at once.** A per-session signature cannot express this rule: it
    /// is the sessions that decide a file's fate, so a function that sees one session at
    /// a time is structurally unable to.
    public static func match(
        _ candidates: [LogCandidate],
        for sessions: [(id: UUID, connectedAt: Date)],
        overlap: TimeInterval,
        now: Date
    ) -> [UUID: LogMatch] {
        let windows = sessions.map {
            (id: $0.id, files: inWindow(candidates, connectedAt: $0.connectedAt, overlap: overlap, now: now))
        }

        // How many sessions could claim each file. Counted per distinct file per
        // session, so a url appearing twice in one window counts once here and once as a
        // duplicate below rather than inflating the contention of a file nobody shares.
        var claimants: [URL: Int] = [:]
        for window in windows {
            for file in window.files {
                claimants[file.url, default: 0] += 1
            }
        }

        var matches: [UUID: LogMatch] = [:]
        matches.reserveCapacity(windows.count)
        for window in windows {
            switch window.files.count {
            case 0:
                matches[window.id] = .ambiguous(count: 0)
            case 1:
                let only = window.files[0]
                matches[window.id] = claimants[only.url] == 1
                    ? .unique(only)
                    : .ambiguous(count: 1)
            default:
                matches[window.id] = .ambiguous(count: window.files.count)
            }
        }
        return matches
    }

    /// The candidates whose last write falls inside this session's window.
    ///
    /// Generous either side, because a log's modification time is its *last* write and a
    /// session's end is not observable: a tight bound would simply miss real matches. The
    /// cost of generosity is more candidates, which is the ambiguity above rather than a
    /// guess.
    ///
    /// The upper bound is `now`, not a guessed end. That is what keeps a connection open
    /// for hours matchable at all — and it is also why the windows nest and a live log
    /// is contested by every session that has ever been recorded.
    static func inWindow(
        _ candidates: [LogCandidate],
        connectedAt: Date,
        overlap: TimeInterval,
        now: Date
    ) -> [LogCandidate] {
        let since = connectedAt.addingTimeInterval(-overlap)
        let until = now.addingTimeInterval(overlap)
        var seen: Set<URL> = []
        var matched: [LogCandidate] = []
        for candidate in candidates where candidate.modifiedAt >= since
            && candidate.modifiedAt <= until
            && seen.insert(candidate.url).inserted
        {
            matched.append(candidate)
        }
        return matched
    }
}
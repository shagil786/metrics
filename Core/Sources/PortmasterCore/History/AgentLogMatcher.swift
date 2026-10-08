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
// time, and the question is which times.
//
// THE QUESTION IS "WAS THIS CONNECTION DURING THAT CONVERSATION", NOT "IS THE FILE
// FRESH"
//
// The first version asked whether the log's **last write** fell inside the session's
// window. That window has to run to *now*, because a session's end is not observable
// and a connection open for hours must stay matchable — and a window that runs to now
// contains today's log for *every* session ever recorded. So a user who had connected
// five times had five historical sessions all claiming the one live file, and the
// one-to-one rule below correctly called that contention: nobody matched. The feature
// was near-inert after a user's second connection, on the machine it was built for.
//
// The rule is now the interval, not the point:
//
// > **Does the conversation's interval contain the moment this session connected?**
//
// A conversation occupies a real span — Claude Code writes a `timestamp` on 354 of this
// machine's 423 lines, from `22:31:52.452Z` to `22:58:30.007Z`. A session connected at
// 22:40 is inside that. A session from last week is not, and not because a rule excluded
// it: last week is not inside the conversation. Five historical sessions stop contending,
// because only one of them connected *during* the conversation.
//
// **This is the ambiguity rule one level deeper.** "Time overlaps" was never a strong
// enough claim to build a money figure on — it was not strong enough to say a log was
// *this session's*, and it turns out it is not strong enough to say a log is *newer
// than* a session either.
//
// And the one-to-one rule stays, because interval containment does not make contention
// impossible: two MCP connections opened during one conversation both sit inside it and
// genuinely contend. That is the ambiguity rule doing the remaining work.
//
// WHAT IS STILL NOT CLAIMED
//
// Even a perfect interval says only that the connection happened *during* the
// conversation. It does not say the conversation's tokens were spent during the
// connection — see `ClaudeCodeLogAdapter`'s honest limits, where that is named as the
// largest one and still is.

import Foundation

/// Where a conversation's interval came from.
///
/// Carried on the candidate because the two are not the same kind of evidence, and a
/// caller that cannot tell them apart will trust the weaker one as though it were the
/// stronger. `fileModification` is one filesystem timestamp standing in for a whole
/// span; `lineTimestamps` is the log's own account of itself.
public enum LogIntervalEvidence: Hashable, Sendable {
    /// Earliest and latest of the log's own per-line timestamps.
    case lineTimestamps
    /// No line carried a timestamp, so the file's single modification time is used for
    /// both ends — a *point* where a span is wanted. It answers "was this file touched
    /// near the connection", which is the older and weaker question, and it is labelled
    /// so nobody reads it as the interval it is not.
    case fileModification
}

/// A conversation's span in time.
public struct LogInterval: Hashable, Sendable {
    public let start: Date
    public let end: Date
    public let evidence: LogIntervalEvidence

    public init(start: Date, end: Date, evidence: LogIntervalEvidence) {
        self.start = start
        self.end = end
        self.evidence = evidence
    }
}

/// One log file a source could describe, and when it was being written.
public struct LogCandidate: Hashable, Sendable {
    public let url: URL

    /// **Nil when nothing could place this file in time** — no line carried a timestamp
    /// *and* the filesystem would not say when it was written.
    ///
    /// Such a file is still returned, so that "there is a log here that cannot be placed"
    /// is visible to a diagnostic rather than looking like "no log". It matches nobody,
    /// because a claim it cannot support is the one thing this module never makes. The
    /// cost is that it reaches the session as `noSource`, which says no source could be
    /// *attributed* — the closest honest word in a set that has no separate one.
    public let interval: LogInterval?

    public init(url: URL, interval: LogInterval?) {
        self.url = url
        self.interval = interval
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
    /// Exactly one conversation spans this connection, and no other session's connection
    /// falls inside it. The only shape that becomes a number.
    case unique(LogCandidate)
    /// Not attributable to this session. `count` is how many files could describe it:
    ///
    /// - `0` — no conversation spans this connection's moment.
    /// - `1` — one does, and one or more other connections fall inside it too. This is
    ///   the contention case, and it is why `count: 1` is not a match.
    /// - `2` or more — several do, and nothing to choose between them.
    case ambiguous(count: Int)
}

/// The one-to-one rule, in one place.
///
/// A static pure function over `(candidates, sessions, overlap, now)` rather than a
/// nested type or a closure assembled at each call site: two sources matching files two
/// ways is two answers to one question, and this is the question. `now` is a parameter
/// rather than a clock read so a caller takes one reading per pass and every decision in
/// that pass is judged against the same instant.
public enum AgentLogMatcher {
    /// One entry per session asked about, keyed by session id — including the sessions
    /// with no conversation spanning them, because the caller has to record an absence
    /// for each of them.
    ///
    /// **The whole pass at once.** A per-session signature cannot express the contention
    /// rule: it is the sessions that decide a file's fate, so a function that sees one
    /// session at a time is structurally unable to.
    public static func match(
        _ candidates: [LogCandidate],
        for sessions: [(id: UUID, connectedAt: Date)],
        overlap: TimeInterval,
        now: Date
    ) -> [UUID: LogMatch] {
        let windows = sessions.map {
            (id: $0.id, files: spanning(candidates, connectedAt: $0.connectedAt, overlap: overlap, now: now))
        }

        // How many sessions fall inside each conversation. Counted per distinct file per
        // session, so a url appearing twice counts once here and once as a duplicate
        // below rather than inflating the contention of a file nobody shares.
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

    /// The candidates whose conversation spans the moment this session connected.
    ///
    /// **The tolerance pads both ends of the conversation, and neither end of the
    /// session.** A session is an instant — the moment the socket was accepted — so there
    /// is nothing to pad on that side. The conversation is the uncertain one at both
    /// ends: its first line is written after the agent started, and its last line before
    /// the connection closed, so a connection either side of the logged span can still be
    /// the same conversation. Padding it here rather than inside the adapter keeps one
    /// tolerance for one question — a second window configured in two places was what
    /// `ClaudeCodeLogAdapter.overlap` was, and deleting it is why there is one now.
    static func spanning(
        _ candidates: [LogCandidate],
        connectedAt: Date,
        overlap: TimeInterval,
        now: Date
    ) -> [LogCandidate] {
        var seen: Set<URL> = []
        var matched: [LogCandidate] = []
        for candidate in candidates {
            guard seen.insert(candidate.url).inserted, let span = candidate.interval else {
                continue
            }
            // A conversation wholly after `now` is a clock artefact, and a session row
            // sharing that same skew would "match" it — attributing a conversation to a
            // connection that cannot have happened. Refusing it is the only direction
            // that invents nothing, and it is why `now` is a parameter at all.
            //
            // **Padded by the same tolerance as everything else**, because a conversation
            // that began a moment after this pass's clock reading is not an artefact: the
            // pass asks its sources *after* taking the reading, so a log written in
            // between is the ordinary case of an agent starting up, not a machine with a
            // wrong clock. A zero-width version of this bound would refuse it.
            guard span.start <= now.addingTimeInterval(overlap) else { continue }
            guard connectedAt >= span.start.addingTimeInterval(-overlap),
                  connectedAt <= span.end.addingTimeInterval(overlap)
            else { continue }
            matched.append(candidate)
        }
        return matched
    }
}
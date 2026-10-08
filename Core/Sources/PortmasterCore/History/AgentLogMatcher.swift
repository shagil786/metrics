// Deciding which of an agent's log files, if any, belongs to one session.
//
// Split out of `TokenSourceRunner` and given no filesystem, because "is this one file
// or two?" is the rule most likely to be got quietly wrong and the one hardest to
// test once it is tangled up with a directory walk. On its own it is a function of two
// values — a list of files and a session — and every claim about it can be asserted
// without writing a file anywhere.
//
// WHAT THE CORRELATION IS
//
// A Portmaster session is an MCP connection UUID. An agent's log is named for that
// agent's own session. **The two share no key.** The only thing that ties them is
// time, so "which log is this session's" is really "which log was being written while
// this session was open" — a heuristic, and one that is more often wrong than right on
// a machine with two agents running.
//
// EXACTLY ONE IS THE ONLY ANSWER
//
// One candidate is a match. Zero and two-or-more are both not, and they are reported
// separately: nothing to read is a different fact from too much to choose between,
// and a session that has not started writing yet deserves different words from one
// whose file could belong to a colleague's agent.
//
// **Two candidates is not a tie to break.** Taking the most recent would file each
// one's tokens against the other — a wrong number rather than an absence, and the one
// failure this whole design exists to prevent. Two agents running side by side produce
// two logs overlapping one window; that is a fact about the machine, not about this
// session, and it stays an absence.
//
// `.ambiguous` will therefore be **common** on a busy machine, and it is correct
// behaviour rather than a bug to be tuned away. A machine running one agent at a time
// gets figures; a machine running three at once mostly gets honest refusals.

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

/// What a list of candidates says about one session.
///
/// One case per answer rather than an optional candidate plus a flag: "no file" and
/// "too many files" are the two states the matcher must never collapse, and an
/// optional could carry either without saying which.
public enum Match: Hashable, Sendable {
    /// Exactly one file overlaps the session. The only shape that becomes a number.
    case unique(LogCandidate)
    /// No overlapping file (`count == 0`), or more than one and nothing to choose
    /// between them. The count is carried so a caller can report the two apart and so
    /// a diagnostic can say how bad the ambiguity was.
    case ambiguous(count: Int)
}

/// The uniqueness rule, in one place.
///
/// A static pure function over `(candidates, session, overlap)` rather than a nested
/// type or a closure assembled at each call site: two adapters matching files two ways
/// is two answers to one question, and this is the question. Pure except for the
/// clock, which it reads once.
public enum AgentLogMatcher {
    public static func match(
        _ candidates: [LogCandidate],
        for session: AgentSessionSnapshot,
        overlap: TimeInterval
    ) -> Match {
        // Generous either side, because a log's modification time is its *last* write
        // and a session's end is not observable: a tight bound would simply miss real
        // matches. The cost of generosity is more candidates, which is the ambiguity
        // above rather than a guess.
        let since = session.connectedAt.addingTimeInterval(-overlap)
        // Runs to now rather than to a guessed end, which is what keeps a connection
        // open for hours still matchable at all.
        let until = Date().addingTimeInterval(overlap)

        let inWindow = candidates.filter { $0.modifiedAt >= since && $0.modifiedAt <= until }
        guard inWindow.count == 1, let only = inWindow.first else {
            return .ambiguous(count: inWindow.count)
        }
        return .unique(only)
    }
}
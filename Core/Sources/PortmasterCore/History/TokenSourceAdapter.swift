// Reading token counts out of an agent's own session logs.
//
// One adapter per vendor. The isolation is the point: parsing one agent's private
// file format must not be able to break another's, and a new adapter must be
// addable without touching the record or the query surface.
//
// `ClaudeCodeLogAdapter` is the first one that ships, and `AgentSourcePoller` is
// what asks it. The fixture in the tests is still a fixture: an adapter there proves
// the contract, not that any particular agent's file parses.

import Foundation

public enum TokenSourceError: Error, Hashable, Sendable {
    /// The file was read and its shape was not understood — the vendor changed it.
    /// Deliberately not a partial parse: a half-understood file that yields plausible
    /// numbers is worse than no file.
    case unrecognizedFormat
    case unreadable
}

/// One model's counts as they appear in a vendor's log, before conversion.
///
/// **One per model, not one per log.** A session that escalated `model-a` →
/// `model-b` has its first model's tokens inside the second model's total, and
/// pricing that whole total at the newest model's rate is the known-unsound case
/// this design documents. A log that breaks usage down per model can be recorded
/// as one entry per model, and each priced at its own rate — so an adapter that
/// can see the breakdown should always return several rather than collapsing them
/// into a single total.
public struct RawAgentUsage: Hashable, Sendable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int?
    public let reasoning: Int?
    public let modelID: String

    public init(input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.modelID = modelID
    }
}

public protocol TokenSourceAdapter: Sendable {
    /// Stable name for this source, used in diagnostics.
    var identifier: String { get }

    /// Every log this source could describe, with its last write time.
    ///
    /// **Enumerated once per pass — never once per session.** The old shape asked per
    /// session, so a machine with ten open sessions walked the agent's log directory
    /// ten times to answer ten questions one directory read answers. A session id and
    /// an agent's log filename share no key, so the only correlation is time, and
    /// time is already in hand: matching one session against a list is arithmetic.
    ///
    /// Empty is normal, not an error — and it is the absence a caller should reach
    /// without a walk at all, which is why a pass with no sessions never gets here.
    func logCandidates() -> [LogCandidate]

    /// Parses a located log into one entry per model. Throws
    /// `TokenSourceError.unrecognizedFormat` rather than returning partial counts.
    func parse(_ url: URL) throws -> [RawAgentUsage]
}

/// What an adapter run produced: records to append, or a reason there are none.
public enum TokenSourceOutcome: Hashable, Sendable {
    /// One record per model the log attributed usage to. Never collapsed to one.
    case reported([TokenUsageRecord])
    case notReported(reason: UsageUnavailableReason)
}

/// Runs one adapter against one session and maps every failure onto a named
/// absence, so no caller has to interpret an error to know what it does not know.
///
/// The candidate list is passed in rather than asked for, because one enumeration
/// per pass serves every session — see `logCandidates()`.
public struct TokenSourceRunner: Sendable {
    private let adapter: any TokenSourceAdapter
    private let now: @Sendable () -> Date

    /// The session id is taken from the session passed to `run(session:)`, never
    /// stored here: a second copy of an id that must equal the first is a copy that
    /// can be stale, and the result of a stale one is a number counted against the
    /// wrong session — the one failure here that is not an absence, and therefore
    /// the one no downstream check would catch.
    public init(
        adapter: any TokenSourceAdapter,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapter = adapter
        self.now = now
    }

    public func run(
        session: AgentSessionSnapshot,
        candidates: [LogCandidate],
        overlap: TimeInterval
    ) -> TokenSourceOutcome {
        // **Only a unique match is a match**, and `AgentLogMatcher` owns that rule so
        // it can be tested without a filesystem. Zero and many are both not-a-match,
        // but they are not the same absence: nothing to read is a machine that has not
        // written a log, while two or more is a machine running more than one agent.
        // Collapsing them would tell a user with nothing to count the same story as a
        // user whose figure could not be attributed.
        let url: URL
        switch AgentLogMatcher.match(candidates, for: session, overlap: overlap) {
        case .unique(let candidate):
            url = candidate.url
        case .ambiguous(let count):
            return .notReported(reason: count == 0 ? .noSource : .ambiguousMatch)
        }

        do {
            let raw = try adapter.parse(url)
            // Every model gets its own record at the same instant: they are one
            // observation, and recording them at different times would let the
            // latest-per-segment fold see a disagreement that is not there.
            let at = now()
            return .reported(raw.map { entry in
                TokenUsageRecord(
                    sessionID: session.id,
                    recordedAt: at,
                    input: entry.input,
                    output: entry.output,
                    cacheRead: entry.cacheRead,
                    reasoning: entry.reasoning,
                    modelID: entry.modelID,
                    provenance: .parsedFromLog
                )
            })
        } catch TokenSourceError.unrecognizedFormat {
            return .notReported(reason: .unrecognizedFormat)
        } catch TokenSourceError.unreadable {
            return .notReported(reason: .logUnreadable)
        } catch {
            // An adapter throwing something of its own is still an absence, and
            // still must not become a number.
            return .notReported(reason: .logUnreadable)
        }
    }
}

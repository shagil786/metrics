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

    /// Every log this source could describe, each with the interval it was written
    /// across.
    ///
    /// **Enumerated once per pass — never once per session.** The original shape asked
    /// per session, so a machine with ten open sessions walked the agent's log directory
    /// ten times to answer ten questions one directory read answers. A session id and an
    /// agent's log filename share no key, so the only correlation is time, and matching
    /// one session against a list is arithmetic.
    ///
    /// `newerThan` is an optional cost bound, not a filter the adapter applies to its own
    /// judgement: it is the earliest instant any session in this pass could match, derived
    /// by the caller. Passing it may omit candidates the caller would not have matched
    /// anyway; `nil` asks for everything.
    ///
    /// Empty is normal, not an error — and it is the absence a caller should reach without
    /// a walk at all, which is why a pass with no sessions never gets here.
    func logCandidates(newerThan: Date?) -> [LogCandidate]

    /// Parses a located log into one entry per model. Throws
    /// `TokenSourceError.unrecognizedFormat` rather than returning partial counts.
    func parse(_ url: URL) throws -> [RawAgentUsage]
}

/// What an adapter run produced: records to append, or a reason there are none.
public enum TokenSourceOutcome: Hashable, Sendable {
    /// One record per model the log attributed usage to. Never collapsed to one.
    case reported([TokenUsageRecord])
    case notReported(reason: UsageUnavailableReason)
    /// The pass's decision changed and a figure already stored for this session must stop
    /// counting. A record rather than a mutation, because the store is append-only and
    /// "retracting" needs a deliberate representation rather than a deletion the fold
    /// would then have to reason about being complete.
    case withdrew(parsedFromLog: Bool)
}

/// Turns one decision into records to persist, or a reason there are none.
///
/// Takes the session's **id** rather than a snapshot because a decision is already made
/// by the time it gets here, and the only thing left to stamp is the id. That is also
/// what lets the poller read two columns from the store per session instead of a
/// snapshot's worth — see `AgentSessionStore.sessionKeys()`.
public struct TokenSourceRunner: Sendable {
    private let adapter: any TokenSourceAdapter
    private let now: @Sendable () -> Date

    /// The session id is taken from the session passed to `run(sessionID:match:)`, never
    /// stored here: a second copy of an id that must equal the first is a copy that can
    /// be stale, and the result of a stale one is a number counted against the wrong
    /// session — the one failure here that is not an absence, and therefore the one no
    /// downstream check would catch.
    public init(
        adapter: any TokenSourceAdapter,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapter = adapter
        self.now = now
    }

    /// `readsParsedUsage` is the session's provenance from the pass's own snapshot of what
    /// it has already written, and it decides whether a refusal withdraws. See
    /// `AgentSourcePoller`.
    public func run(
        sessionID: UUID,
        match: LogMatch,
        readsParsedUsage: Bool = false
    ) -> TokenSourceOutcome {
        // Only `.unique` is a number. The three refusals collapse into two absences
        // because `UsageUnavailableReason` names two of them: nothing to read is a
        // machine that has not written a log, and both "too many conversations" and "this
        // conversation is not yours alone" are a machine whose figures cannot be
        // attributed. What is *not* collapsed is the step before this one — a conversation
        // several sessions could claim never reaches any of them, so none gets a figure.
        let url: URL
        switch match {
        case .unique(let candidate):
            url = candidate.url
        case .ambiguous(let count):
            // **A refusal withdraws a figure this session already had, and only then.**
            // A conversation's interval only grows while it runs, so a session uniquely
            // matched at one pass becomes unattributable at the next the moment a second
            // connection opens inside the same conversation. Without this the store kept
            // showing a priced figure for a session the current rule refuses — the
            // confidently-wrong-dollar direction, reached *by* the rule meant to prevent it.
            if count > 0, readsParsedUsage {
                return .withdrew(parsedFromLog: true)
            }
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
                    sessionID: sessionID,
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

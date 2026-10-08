// The slow lane that actually asks.
//
// `ClaudeCodeLogAdapter` reads a Claude Code session log and `TokenSourceRunner`
// turns one into records, and between them and `AgentSessionStore` there was no
// caller at all: the protocol existed, the outcome mapping existed, and nothing ever
// ran it. Everything in this slice was therefore unreachable in production and known
// so — the fold, the disagreement rule and the pricing path were all exercised only
// by tests. This is the caller, and wiring it is what makes those paths real.
//
// WHY A SEPARATE POLLER
//
// **Not** a collector on `SamplingEngine`. That engine measures this machine and its
// cadence is driven by whether a surface is visible; an agent log is another
// application's private file, its cost is a directory read per pass, and its
// questions are about sessions the engine has no concept of. Injecting the session
// store into it would take a boundary the engine's design rests on — that it knows
// about this machine and nothing else — and give it a reason to be constructed at
// all in a build with no agent sessions.
//
// The app starts this with the store. That wiring is a separate change; nothing here
// constructs a poller in production yet.

import Foundation

/// One session and one source that produced no figure, with the reason.
///
/// Carried per session rather than summarised per pass, because the reason is the
/// useful part: a machine whose agent sessions all read `noSource` and one that reads
/// `ambiguousMatch` need different words from the user, and a count of "0 figures"
/// cannot tell them apart.
public struct AgentSourceAbsence: Hashable, Sendable {
    public let sessionID: UUID
    /// The adapter's `identifier`, so two sources' refusals are not merged.
    public let source: String
    public let reason: UsageUnavailableReason

    public init(sessionID: UUID, source: String, reason: UsageUnavailableReason) {
        self.sessionID = sessionID
        self.source = source
        self.reason = reason
    }
}

/// A pass step that failed for a reason no `UsageUnavailableReason` names.
///
/// Only the store's own failures land here — an adapter's parse failures are already
/// named absences by the time they reach the poller. Recorded rather than thrown
/// because the alternative is one unwritable record aborting every session after it.
public struct AgentSourceFailure: Hashable, Sendable {
    /// `"store"` for the store itself, or an adapter's `identifier` where one applies.
    public let source: String
    public let sessionID: UUID?
    public let detail: String

    public init(source: String, sessionID: UUID?, detail: String) {
        self.source = source
        self.sessionID = sessionID
        self.detail = detail
    }
}

/// What one pass established, in the terms a caller can act on.
///
/// Exists so "did that pass really do nothing?" is answerable from a value rather than
/// inferred from the absence of a number — which is the distinction the whole
/// three-state usage type rests on, applied to the pass itself.
public struct AgentSourcePass: Hashable, Sendable {
    public let at: Date
    /// Sessions the pass read. Zero means the store held none.
    public let sessionsConsidered: Int
    /// Directory walks performed. **Zero when there were no sessions to match against**,
    /// and at most one per adapter otherwise — reported rather than assumed, because
    /// "no walk happened" is the claim worth being able to check.
    public let enumerations: Int
    /// Every record the pass persisted, in the order it wrote them.
    public let records: [TokenUsageRecord]
    public let absences: [AgentSourceAbsence]
    public let failures: [AgentSourceFailure]

    public init(
        at: Date,
        sessionsConsidered: Int,
        enumerations: Int,
        records: [TokenUsageRecord],
        absences: [AgentSourceAbsence],
        failures: [AgentSourceFailure]
    ) {
        self.at = at
        self.sessionsConsidered = sessionsConsidered
        self.enumerations = enumerations
        self.records = records
        self.absences = absences
        self.failures = failures
    }

    /// A pass with nothing to say: the shape returned before any work was attempted.
    ///
    /// Used for the two early returns — an unreadable store and an empty one — so
    /// neither has to spell five fields to say "nothing happened".
    static func idle(at: Date, sessionsConsidered: Int = 0, failures: [AgentSourceFailure] = [])
        -> AgentSourcePass
    {
        AgentSourcePass(
            at: at,
            sessionsConsidered: sessionsConsidered,
            enumerations: 0,
            records: [],
            absences: [],
            failures: failures
        )
    }
}

/// Asks every configured adapter about every open session, on a slow cadence.
///
/// The interval, the in-flight guard and the off-main-thread pass follow
/// `SamplingEngine.kickSlowCollectorsIfNeeded`: a pass that walks another app's
/// directory and parses JSONL must never run on the main queue, and a machine where
/// one pass takes longer than the interval must skip the next one rather than stack
/// them until the machine is doing nothing but parsing agent logs.
public final class AgentSourcePoller: @unchecked Sendable {
    /// Slow on purpose. A session's counts move in tens of thousands of tokens, and a
    /// pass that reads the same cumulative log twice inside that window learns nothing
    /// new — it only writes another record for the fold to discard.
    public static let pollInterval: TimeInterval = 30

    private let store: AgentSessionStore
    private let adapters: [any TokenSourceAdapter]
    /// How far either side of a session a log's last write may fall and still count as
    /// overlapping. Generous, because a log's modification time is its *last* write and
    /// a session's end is not observable; the cost of generosity is ambiguity, which is
    /// an absence rather than a guess.
    private let overlap: TimeInterval
    private let onPass: (@Sendable (AgentSourcePass) -> Void)?

    private let queue = DispatchQueue(label: "dev.portmaster.agentsources", qos: .utility)
    /// Every mutable field below is touched only on `queue`. `start()` hops there
    /// before touching `timer`, so there is no state a main-thread call and a tick can
    /// both reach at once.
    private var timer: DispatchSourceTimer?
    private var inFlight = false
    private var lastPassAt = Date.distantPast

    public init(
        store: AgentSessionStore,
        adapters: [any TokenSourceAdapter] = [ClaudeCodeLogAdapter()],
        overlap: TimeInterval = 60 * 60,
        onPass: (@Sendable (AgentSourcePass) -> Void)? = nil
    ) {
        self.store = store
        self.adapters = adapters
        self.overlap = overlap
        self.onPass = onPass
    }

    // MARK: - Lifecycle

    /// Starts the timer and takes the first pass off the main queue.
    ///
    /// `deadline: .now()` so the first pass runs immediately: a session that connected
    /// before the app launched has a log already, and waiting a full interval would
    /// show it uncounted for no reason a user could see.
    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: Self.pollInterval)
            t.setEventHandler { [weak self] in self?.kickIfNeeded() }
            self.timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // MARK: - The pass

    /// One pass, synchronously, on whatever queue the caller is already on.
    ///
    /// **No scheduling and no gating**, which is what makes it the right entry point
    /// for a test and for the one-off diagnostic run: neither has to wait on a clock or
    /// race an in-flight flag to see a result. `start()` is what gates.
    public func pollOnce() -> AgentSourcePass { runPass() }

    /// Interval gating and the overlap guard, then the pass. Runs on `queue`.
    private func kickIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPassAt) >= Self.pollInterval, !inFlight else {
            return
        }
        inFlight = true
        lastPassAt = now
        let pass = runPass()
        inFlight = false
        // Results cross to the main queue because that is where a caller reading them
        // will be, and because the store's own lock is not a substitute for the rule
        // that UI state changes happen where UI state lives.
        if let onPass {
            DispatchQueue.main.async { onPass(pass) }
        }
    }

    /// Reads every session once, enumerates each source once, and persists what it
    /// found.
    ///
    /// **Enumeration is here and not in the runner** because that is the whole of the
    /// per-pass saving: one directory walk per adapter, then arithmetic against a list.
    /// Asking per session was the shape this replaced, and on a machine with several
    /// agents open it walked the same tree once per session to learn the same thing.
    private func runPass() -> AgentSourcePass {
        let at = Date()

        let sessions: [AgentSessionSnapshot]
        do {
            sessions = try store.sessions()
        } catch {
            NSLog("Portmaster agent source poll could not read sessions: \(error)")
            return .idle(at: at, failures: [
                AgentSourceFailure(source: "store", sessionID: nil, detail: "\(error)")
            ])
        }

        // **No sessions means no walk.** Not a micro-optimisation: this is the state of
        // a machine with no MCP client ever connected, and the enumeration would
        // otherwise stat every agent log on the machine once a minute to conclude
        // there is nobody to attribute them to. Returned before `logCandidates` is
        // reached, and counted in `enumerations` so the claim is checkable.
        guard !sessions.isEmpty else { return .idle(at: at) }

        var enumerated: [(source: String, candidates: [LogCandidate], adapter: any TokenSourceAdapter)] = []
        for adapter in adapters {
            enumerated.append((adapter.identifier, adapter.logCandidates(), adapter))
        }

        var records: [TokenUsageRecord] = []
        var absences: [AgentSourceAbsence] = []
        var failures: [AgentSourceFailure] = []

        for session in sessions {
            for entry in enumerated {
                let runner = TokenSourceRunner(adapter: entry.adapter, now: { at })
                switch runner.run(session: session, candidates: entry.candidates, overlap: overlap) {
                case .reported(let found):
                    for record in found {
                        do {
                            try store.recordUsage(record)
                            records.append(record)
                        } catch {
                            // Logged and carried on. A record that will not write is
                            // this session's loss, not the next eight sessions'.
                            NSLog("Portmaster agent source poll could not record usage: \(error)")
                            failures.append(AgentSourceFailure(
                                source: entry.source, sessionID: session.id, detail: "\(error)"
                            ))
                        }
                    }
                case .notReported(let reason):
                    absences.append(AgentSourceAbsence(
                        sessionID: session.id, source: entry.source, reason: reason
                    ))
                }
            }
        }

        // The store's autosave is off, so without this a pass that wrote records leaves
        // them in memory until something else happens to save — which for a source only
        // this poller feeds is never. Once per pass rather than once per record: the
        // write is the same either way and a failure must not be retried per record.
        if !records.isEmpty {
            do {
                try store.flush()
            } catch {
                NSLog("Portmaster agent source poll could not flush usage: \(error)")
                failures.append(AgentSourceFailure(source: "store", sessionID: nil, detail: "\(error)"))
            }
        }

        return AgentSourcePass(
            at: at,
            sessionsConsidered: sessions.count,
            enumerations: enumerated.count,
            records: records,
            absences: absences,
            failures: failures
        )
    }
}
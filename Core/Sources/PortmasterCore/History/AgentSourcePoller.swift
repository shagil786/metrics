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
// application's private file and the engine has no concept of a session. Injecting the
// session store into it would take a boundary the engine's design rests on — that it
// knows about this machine and nothing else — and give it a reason to be constructed at
// all in a build with no agent sessions.
//
// The app starts this with the store, in `AppModel`'s opening `do` — so a store that
// would not open takes no poller with it — and stops it on the way out alongside the
// MCP host. Unconditional either way: reading another application's log is read-only
// and writes only to our own store, about sessions that connected to us.

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
    /// Sessions the pass matched against. Zero means the store held none.
    public let sessionsConsidered: Int
    /// **Sources asked**, which is one per adapter — *not* a count of filesystem walks.
    /// An adapter whose log directory does not exist was still asked and returned
    /// nothing having done no I/O, so this cannot stand in for "walks performed"; the
    /// no-sessions guard is observable instead by `sessionsConsidered == 0` with this
    /// also zero, since nothing is asked before a session exists to ask about.
    public let sourcesQueried: Int
    /// Every figure the pass wrote, in the order it wrote them.
    public let records: [TokenUsageRecord]
    /// Figures the pass took back — records whose only content is that an earlier one is no
    /// longer attributable. **Kept apart from `records`** so "how much did this pass write"
    /// and "what did this pass take back" are two answerable questions rather than one with
    /// a provenance filter on it.
    public let withdrawals: [TokenUsageRecord]
    public let absences: [AgentSourceAbsence]
    public let failures: [AgentSourceFailure]

    public init(
        at: Date,
        sessionsConsidered: Int,
        sourcesQueried: Int,
        records: [TokenUsageRecord],
        withdrawals: [TokenUsageRecord],
        absences: [AgentSourceAbsence],
        failures: [AgentSourceFailure]
    ) {
        self.at = at
        self.sessionsConsidered = sessionsConsidered
        self.sourcesQueried = sourcesQueried
        self.records = records
        self.withdrawals = withdrawals
        self.absences = absences
        self.failures = failures
    }

    /// A pass that was over before any source was asked. Used for the two early returns
    /// — an unreadable store and an empty one.
    static func idle(at: Date, sessionsConsidered: Int = 0, failures: [AgentSourceFailure] = [])
        -> AgentSourcePass
    {
        AgentSourcePass(
            at: at,
            sessionsConsidered: sessionsConsidered,
            sourcesQueried: 0,
            records: [],
            withdrawals: [],
            absences: [],
            failures: failures
        )
    }
}

/// Asks every configured adapter about every recorded session, on a slow cadence.
///
/// The interval gate and the in-flight flag follow `SamplingEngine`'s slow lane: a pass
/// that walks another app's directory and parses JSONL must never run on the main queue,
/// and a machine where one pass takes longer than the interval must skip the next rather
/// than stack them until it is doing nothing but parsing agent logs. It uses **one**
/// queue rather than that lane's two — the second hop exists there to keep the sampling
/// queue free while other collectors run, and nothing else shares this queue, so there
/// is nothing to keep free.
public final class AgentSourcePoller: @unchecked Sendable {
    /// Slow on purpose. A session's counts move in tens of thousands of tokens, and a
    /// pass that reads the same cumulative log twice inside that window learns nothing
    /// new — it only writes another record for the fold to discard.
    public static let pollInterval: TimeInterval = 30

    private let store: AgentSessionStore
    private let adapters: [any TokenSourceAdapter]
    /// How far either side of a conversation a connection may fall and still count as
    /// having been inside it. Generous, because a conversation's first line is written
    /// after the agent started and its last before the connection closed; the cost of
    /// generosity is a wider band in which two connections contend and neither matches,
    /// which is an absence rather than a guess.
    private let overlap: TimeInterval
    private let onPass: (@Sendable (AgentSourcePass) -> Void)?

    private let queue = DispatchQueue(label: "dev.portmaster.agentsources", qos: .utility)
    /// Every mutable field below is touched only on `queue`. `start()`, `stop()` and
    /// `requestPoll()` hop there before touching anything, so no state a caller can reach
    /// from another thread and a tick can also reach exists.
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

    /// One pass, returning what it found. **Blocking**, for a test or a one-off
    /// diagnostic: neither should have to wait on a clock or race a gate to see a result.
    ///
    /// Runs through `queue.sync`, so it cannot overlap a scheduled pass — the same
    /// no-overlap guarantee the timer obeys, applied here too. Without it the natural
    /// app shape (start on launch, poll again when a surface appears) would run two
    /// passes at once, and the in-flight flag above would be describing a guarantee this
    /// method broke. A UI surface wanting a fresher poll without blocking should use
    /// `requestPoll()`.
    public func pollOnce() -> AgentSourcePass {
        queue.sync { runPass(now: Date()) }
    }

    /// Asks for a pass without blocking the caller, under the same interval and
    /// in-flight rules a timer tick obeys. A poll too soon is dropped rather than
    /// queued, which is the point: the gate exists so a surface appearing cannot turn
    /// into a pass per appearance.
    public func requestPoll() {
        queue.async { [weak self] in self?.kickIfNeeded() }
    }

    /// Interval gating and the in-flight guard, then the pass. Runs on `queue`.
    private func kickIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastPassAt) >= Self.pollInterval, !inFlight else {
            return
        }
        inFlight = true
        lastPassAt = now
        let pass = runPass(now: now)
        inFlight = false
        // Results cross to the main queue because that is where a caller reading them
        // will be, and because the store's own lock is not a substitute for the rule
        // that UI state changes happen where UI state lives.
        if let onPass {
            DispatchQueue.main.async { onPass(pass) }
        }
    }

    /// Reads every session once, asks every source once, and persists what it found.
    ///
    /// **Asking is here and not in the runner** because that is the whole of the
    /// per-pass saving: one directory walk per source, then arithmetic against a list.
    /// Asking per session was the shape this replaced.
    ///
    /// **Matching is here for the same reason, and it is not the same kind of saving.**
    /// `AgentLogMatcher.match` is a whole-pass function because a file claimed by two
    /// sessions belongs to neither, and a per-session question cannot see that. One
    /// clock reading is taken for the pass and used for both the windows and the record
    /// timestamps, so every window in a pass is judged against one instant.
    private func runPass(now: Date) -> AgentSourcePass {
        let sessions: [(id: UUID, connectedAt: Date)]
        do {
            sessions = try store.sessionKeys()
        } catch {
            NSLog("Portmaster agent source poll could not read sessions: \(error)")
            return .idle(at: now, failures: [
                AgentSourceFailure(source: "store", sessionID: nil, detail: "\(error)")
            ])
        }

        // **No sessions means no walk.** Not a micro-optimisation: this is the state of
        // a machine with no MCP client ever connected, and asking would otherwise stat
        // every agent log on the machine once a minute to conclude there is nobody to
        // attribute them to. Returned before any source is asked, so `sourcesQueried`
        // is the checkable form of it.
        guard !sessions.isEmpty else { return .idle(at: now) }

        var records: [TokenUsageRecord] = []
        var withdrawals: [TokenUsageRecord] = []
        var absences: [AgentSourceAbsence] = []
        var failures: [AgentSourceFailure] = []

        // **What this store already believes, per session and provenance.** Read once, and
        // read for a reason: a refusal only withdraws a figure that exists, and a pass
        // that withdrew blindly would write a withdrawal for a session that never had a
        // parsed figure — leaving a `parseWithdrawn` record behind that outlives the
        // figure it was meant to cancel.
        var alreadyParsed: Set<UUID> = []
        do {
            for snapshot in try store.sessions() {
                if case .reported(let segments) = snapshot.usage,
                   segments.contains(where: { $0.provenance == .parsedFromLog }) {
                    alreadyParsed.insert(snapshot.id)
                }
            }
        } catch {
            NSLog("Portmaster agent source poll could not read existing usage: \(error)")
            failures.append(AgentSourceFailure(source: "store", sessionID: nil, detail: "\(error)"))
        }

        // The cost bound every source gets: no connection in this pass can match a
        // conversation that ended before the earliest one opened, less the tolerance.
        let earliestMatch = sessions.map(\.connectedAt).min()!
            .addingTimeInterval(-overlap)

        for adapter in adapters {
            let candidates = adapter.logCandidates(newerThan: earliestMatch)
            let matches = AgentLogMatcher.match(
                candidates, for: sessions, overlap: overlap, now: now
            )
            // One runner per source, not per session: it depends on the adapter and the
            // pass's single clock reading, neither of which varies with the session.
            let runner = TokenSourceRunner(adapter: adapter, now: { now })
            for session in sessions {
                switch runner.run(
                    sessionID: session.id,
                    match: matches[session.id] ?? .ambiguous(count: 0),
                    readsParsedUsage: alreadyParsed.contains(session.id)
                ) {
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
                                source: adapter.identifier, sessionID: session.id,
                                detail: "\(error)"
                            ))
                        }
                    }
                case .withdrew(let parsedFromLog):
                    let withdrawal = TokenUsageRecord(
                        sessionID: session.id,
                        recordedAt: now,
                        // No counts, and that is not a claim of zero: a withdrawal is
                        // filtered out before any display or cost sees it. A zero here
                        // would be the cheaper-looking option and is exactly the
                        // conflation this module exists to refuse.
                        input: 0, output: 0, cacheRead: nil, reasoning: nil,
                        modelID: "",
                        provenance: .parseWithdrawn
                    )
                    do {
                        try store.recordUsage(withdrawal)
                        withdrawals.append(withdrawal)
                    } catch {
                        NSLog("Portmaster agent source poll could not record a withdrawal: \(error)")
                        failures.append(AgentSourceFailure(
                            source: adapter.identifier, sessionID: session.id,
                            detail: "\(error)"
                        ))
                    }
                    absences.append(AgentSourceAbsence(
                        sessionID: session.id, source: adapter.identifier,
                        reason: .ambiguousMatch
                    ))
                    _ = parsedFromLog
                case .notReported(let reason):
                    absences.append(AgentSourceAbsence(
                        sessionID: session.id, source: adapter.identifier, reason: reason
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
            at: now,
            sessionsConsidered: sessions.count,
            sourcesQueried: adapters.count,
            records: records,
            withdrawals: withdrawals,
            absences: absences,
            failures: failures
        )
    }
}
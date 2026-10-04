import Foundation

/// One change an AI client has asked a person to confirm.
///
/// A request carries both a human summary ("Quit Mail?") and the exact targets
/// in plain language, because the whole point of the gate is that the person
/// approving it can tell what they are approving.
public struct MCPApprovalRequest: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case quitApp
        case stopContainer
        case stopProject
        case setPreference
    }

    public let id: UUID
    public let kind: Kind
    /// "Quit Mail?", "Stop container web", "Change temperatureUnit".
    public let summary: String
    /// The exact affected targets or key/value, in plain language.
    public let detail: String

    public init(id: UUID = UUID(), kind: Kind, summary: String, detail: String) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.detail = detail
    }
}

/// What a confirmed request resolved to. Every request resolves to exactly one of
/// these: a caller must never be left waiting, because a tool call that hangs is
/// a tool call the model cannot recover from.
public enum ApprovalOutcome: Equatable, Sendable {
    case approved
    /// Carries the reason so it can be shown to the AI client verbatim; "denied"
    /// alone tells the model nothing about whether retrying could help.
    case denied(reason: String)
    case timedOut
}

/// The approval state machine between an AI client's request to change something
/// and the change actually happening.
///
/// It does not present anything — whoever shows the prompt watches `pending` and
/// calls `decide`. What it owns is the part that has to be right no matter how
/// impatient or unlucky the caller is:
///
/// - **Nothing hangs, and nothing throws.** Every accepted request ends in
///   exactly one outcome: approved, denied with a reason, or `timedOut`. There is
///   no failure mode for a caller to catch, because a caller that cannot put the
///   question to a person answers its own request instead. A caller whose own
///   task is cancelled still gets resumed, because the broker resumes the
///   continuation regardless of what the awaiting task has since decided to do.
/// - **Requests are served one at a time, in order.** A burst of agent calls
///   queues instead of stacking prompts, because a person who sees three dialogs
///   at once can approve the wrong one. Only the request at the head of the queue
///   is presented; the rest wait their turn.
/// - **A stale answer is inert.** A decision that arrives after the timeout, for
///   an unknown id, or for a request a later one already replaced, finds nothing
///   to resume and does nothing. Resuming a `CheckedContinuation` twice traps, so
///   this is the one path that is not allowed to be clever.
public actor ConfirmationBroker {

    public static let defaultTimeout: TimeInterval = 60

    /// Longest real time a waiting task sleeps before re-reading the clock.
    /// Small enough for a test to move an injected clock and see the effect,
    /// large enough to be noise next to a person taking seconds to decide.
    private static let clockPollInterval: TimeInterval = 0.05

    private struct Entry {
        let request: MCPApprovalRequest
        let continuation: CheckedContinuation<ApprovalOutcome, Never>
        /// When this request's caller stops waiting, measured on `clock`.
        let deadline: Date
        var timeout: Task<Void, Never>?
    }

    private let timeout: TimeInterval
    private let clock: @Sendable () -> Date
    /// FIFO, oldest first. The head is the request being presented; the rest are
    /// waiting for it to be decided.
    private var queue: [Entry] = []

    /// - Parameters:
    ///   - timeout: how long a request may wait for a decision before it resolves
    ///     as `timedOut`. Silence is treated as a refusal, never as consent.
    ///   - clock: the source of "now" for the budget. Injectable so a test can
    ///     expire a 60-second budget without spending 60 seconds. The default is a
    ///     closure rather than the `Date.init` reference the interface spells,
    ///     because an unapplied initializer reference is not `@Sendable` and the
    ///     conversion warns.
    public init(
        timeout: TimeInterval = ConfirmationBroker.defaultTimeout,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.timeout = timeout
        self.clock = clock
    }

    /// The request currently awaiting a decision — at most one, because requests
    /// are served strictly in order. Empty when nothing is being presented.
    public var pending: [MCPApprovalRequest] {
        queue.first.map { [$0.request] } ?? []
    }

    /// How many requests are waiting for an answer, the presented one included.
    ///
    /// `pending` cannot report this: it holds at most the request being presented,
    /// so a presenter watching it can never tell a person that others are waiting,
    /// nor a caller that it is in the queue at all. This is the count to watch for
    /// "one shown, N-1 waiting"; the depth can be read without disturbing anything.
    public var queuedCount: Int { queue.count }

    /// Suspends until this request is decided, denied in bulk, or times out. Every
    /// accepted request returns an outcome, so nothing about this call can fail —
    /// including the caller failing to ask a person.
    ///
    /// The budget starts when the request is *made*, not when it reaches the head
    /// of the queue: a caller that queues behind three others is not owed a fourth
    /// budget, and no caller waits longer than `timeout` in total.
    ///
    /// "I could not put this to a person" — no prompt available, the app quitting
    /// — is reported by answering the request, not by throwing: call
    /// `decide(id:outcome: .denied(reason:))` for that request as soon as the
    /// caller knows. The reason is what reaches the AI client, so it should name
    /// what went wrong. There is deliberately no error case here: an outcome the
    /// model can read is worth more than a thrown error it has to translate.
    public func request(_ request: MCPApprovalRequest) async -> ApprovalOutcome {
        // Two entries sharing an id would make `decide` ambiguous — a stale answer
        // for the first could be delivered to the second — so the second caller is
        // told no instead of being queued behind an id it cannot be told apart
        // from. Answering it here rather than throwing keeps the rule that every
        // request ends in an outcome the model can read.
        guard !queue.contains(where: { $0.request.id == request.id }) else {
            return .denied(reason: "Another request with this id is already awaiting a decision.")
        }

        let deadline = clock().addingTimeInterval(timeout)
        return await withCheckedContinuation { continuation in
            queue.append(
                Entry(request: request, continuation: continuation, deadline: deadline)
            )
            // Armed here rather than when the request reaches the head, so the
            // budget cannot be silently extended by queueing. The task captures
            // the broker strongly and that is deliberate: a weak capture would let
            // a deallocated broker strand a suspended caller with no way to ever
            // resume it. The cycle is bounded by the budget, and `resume` cancels
            // the task, which ends it.
            //
            // The index is captured rather than recomputed as `queue.count - 1`
            // because the task belongs to *this* entry. Nothing can interleave
            // between the append and this line — the body is synchronous inside an
            // actor-isolated method — so the two are equivalent today, and if they
            // were ever separated by an await the task would be attached to some
            // other request and `expire` would cancel the wrong budget.
            let index = queue.count - 1
            queue[index].timeout = Task { [self] in
                await Self.wait(until: deadline, clock: clock)
                expire(id: request.id)
            }
        }
    }

    /// Answers a pending request, whatever its position in the queue. Answers for
    /// an id that is not pending — already decided, already timed out, never
    /// asked — are ignored.
    ///
    /// Deliberately not restricted to the request being presented: a presenter may
    /// be looking at a request the user has already answered, or at a window that
    /// outlived the queue, and the answer it holds belongs to that request's
    /// caller. Matching by id is what makes that safe — the answer reaches its own
    /// caller or nobody, and can never be applied to a different request. An answer
    /// for the wrong id is inert, so being generous here cannot mis-deliver.
    public func decide(id: UUID, outcome: ApprovalOutcome) {
        guard let index = queue.firstIndex(where: { $0.request.id == id }) else { return }
        resume(queue.remove(at: index), with: outcome)
    }

    /// Denies everything currently queued, in one shot, with the same reason.
    ///
    /// This is the shutdown path: the answer is already known, so waiting out the
    /// budget would only delay the tool call's failure.
    public func cancelAll(reason: String) {
        let entries = queue
        queue.removeAll()
        for entry in entries {
            resume(entry, with: .denied(reason: reason))
        }
    }

    // MARK: - Terminating a request

    /// The budget ran out. Looks the entry up by id rather than by position,
    /// because a queued request whose budget elapsed while it was still waiting
    /// has missed it just as surely as one that was being presented, and because
    /// `decide` can remove an entry from anywhere in the queue.
    ///
    /// In practice the head lapses first — every entry shares one budget and
    /// deadlines run in enqueue order — so this is a head removal today. The
    /// id lookup rather than `removeFirst()` is what keeps it correct anyway: an
    /// entry that is not where the timer expects it still gets its own caller
    /// resumed exactly once, and a timer's late fire still finds its own entry
    /// rather than someone else's.
    private func expire(id: UUID) {
        guard let index = queue.firstIndex(where: { $0.request.id == id }) else { return }
        resume(queue.remove(at: index), with: .timedOut)
    }

    /// The only place a continuation is resumed.
    ///
    /// Every caller removes the entry from `queue` before getting here, and the
    /// actor serialises those removals, so a continuation is resumed exactly
    /// once: `decide`, `expire` and `cancelAll` can race each other freely
    /// because only the first one to find the entry gets to resume it.
    private func resume(_ entry: Entry, with outcome: ApprovalOutcome) {
        // Cancels the budget task; when this *is* that task it only sets a flag on
        // a task that is already on its way out.
        entry.timeout?.cancel()
        entry.continuation.resume(returning: outcome)
    }

    /// Sleeps until `deadline` as `clock` sees it.
    ///
    /// Re-reads the clock every `clockPollInterval` of real time rather than
    /// sleeping the whole difference in one go: with an injected clock the
    /// deadline can move without real time moving, and a single long sleep would
    /// ignore that. With the real clock this is a 50 ms ticker over a budget that
    /// a person takes tens of seconds to decide — cheap next to the decision.
    private nonisolated static func wait(
        until deadline: Date,
        clock: @Sendable () -> Date
    ) async {
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSince(clock())
            if remaining <= 0 { return }
            try? await Task.sleep(for: .seconds(min(remaining, clockPollInterval)))
        }
    }
}

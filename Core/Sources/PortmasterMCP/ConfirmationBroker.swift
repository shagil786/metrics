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

/// The broker cannot ask, so the request fails rather than waiting out its budget.
///
/// The broker itself never throws this — it answers every request it accepts.
/// It belongs to the caller that has to put a question in front of a person, so
/// that a request can be failed at the moment the prompt cannot be shown instead
/// of after the caller has already waited.
public enum ConfirmationBrokerError: Error, Equatable, Sendable {
    case windowUnavailable(String)
}

/// The approval state machine between an AI client's request to change something
/// and the change actually happening.
///
/// It does not present anything — whoever shows the prompt watches `pending` and
/// calls `decide`. What it owns is the part that has to be right no matter how
/// impatient or unlucky the caller is:
///
/// - **Nothing hangs.** Every accepted request ends in exactly one outcome:
///   approved, denied with a reason, or `timedOut`. A caller whose own task is
///   cancelled still gets resumed, because the broker resumes the continuation
///   regardless of what the awaiting task has since decided to do.
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
        let continuation: CheckedContinuation<ApprovalOutcome, Error>
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

    /// Suspends until this request is decided, denied in bulk, or times out.
    ///
    /// The budget starts when the request is *made*, not when it reaches the head
    /// of the queue: a caller that queues behind three others is not owed a fourth
    /// budget, and no caller waits longer than `timeout` in total.
    public func request(_ request: MCPApprovalRequest) async throws -> ApprovalOutcome {
        let deadline = clock().addingTimeInterval(timeout)
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(
                Entry(request: request, continuation: continuation, deadline: deadline)
            )
            // Armed here rather than when the request reaches the head, so the
            // budget cannot be silently extended by queueing. The task captures
            // the broker strongly and that is deliberate: a weak capture would let
            // a deallocated broker strand a suspended caller with no way to ever
            // resume it. The cycle is bounded by the budget, and `resume` cancels
            // the task, which ends it.
            queue[queue.count - 1].timeout = Task { [self] in
                await Self.wait(until: deadline, clock: clock)
                expire(id: request.id)
            }
        }
    }

    /// Answers a pending request. Answers for an id that is not pending — already
    /// decided, already timed out, never asked — are ignored.
    ///
    /// Matching is by id rather than "whoever is at the head", so an answer for a
    /// request that has already moved on reaches its own caller (or nobody) and
    /// cannot be applied to a different request.
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

    /// The budget ran out. Removes the entry wherever it sits — a queued request
    /// whose budget elapsed while it was still waiting has missed it just as
    /// surely as one that was being presented.
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

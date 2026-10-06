// Which phase the stop sheet is in, and the one question that decides it:
// does the sheet open asking the person to confirm a graceful stop, or
// asking them to confirm a force quit?
//
// Extracted from `StopSheet` because the answer is a decision, and the
// decision is testable while the SwiftUI that renders it is not. The sheet's
// `@State` held this inline, so the force-first entry point — the reason a
// quiet dev server can be force-quit without a doomed graceful attempt first
// — was unreachable from a test.
import Darwin

public enum StopConfirmationPhase: Sendable, Equatable {
    /// Nothing has been requested yet. The sheet lists the confirmed members
    /// and waits.
    case confirm
    /// A signal is in flight.
    case running
    /// Every confirmed member has a recorded outcome.
    case done

    /// The phase a sheet opens in.
    ///
    /// `requestedForce` is how the sheet was opened, not a prediction about
    /// what will happen: a force request still has to pass a confirmation
    /// before anything is signalled, so it opens at `.confirm` like any other
    /// request. What it changes is which question `.confirm` is asking.
    public static func opening(forceFirst: Bool) -> StopConfirmationPhase { .confirm }

    /// The question `.confirm` is asking, given how the sheet was opened.
    ///
    /// A quiet dev server is the case that makes this worth having: it is
    /// detached, has no terminal attached, and is frequently a process that
    /// ignores SIGTERM outright. Making a person watch a graceful attempt
    /// time out before offering the only action they wanted is a worse
    /// experience than asking the real question first — and it is not a
    /// licence to skip the confirmation, which is still shown either way.
    public static func asksForceFirst(forceFirst: Bool) -> Bool { forceFirst }

    /// Whether the sheet should still offer a force quit to whatever survived.
    ///
    /// False once nothing survived — offering to force-quit nothing would put
    /// a button on screen that cannot do what its label says.
    public static func offersForceQuit(after outcomes: [pid_t: StopCoordinator.Outcome]) -> Bool {
        outcomes.values.contains { outcome in
            if case .stopped = outcome.status { return false }
            return true
        }
    }

    /// The members a force quit should target, given what has already been
    /// tried.
    ///
    /// Only members without a confirmed stop are eligible, so a second force
    /// attempt cannot re-signal something already gone. A member whose outcome
    /// is `stillRunning` or `failed` is still eligible — those are exactly the
    /// ones a force quit is for.
    public static func forceQuitCandidates(
        _ members: [ConfirmedProcess],
        after outcomes: [pid_t: StopCoordinator.Outcome]
    ) -> [ConfirmedProcess] {
        members.filter { member in
            if case .stopped? = outcomes[member.pid]?.status { return false }
            return true
        }
    }
}

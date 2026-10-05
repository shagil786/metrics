// MCPApprovalCopy: the words a person is asked with, and what a button means to the broker.
//
// `App/MCPConfirmationWindow.swift` is the surface; this is its content, and it lives
// here because the app target has no test target. Three things in that window are
// decisions rather than drawing, and each is the kind that rots quietly:
//
//  1. **What a change is called.** A prompt that showed every mutation as "Change?" would
//     ask a person to agree to something they cannot picture, and the four kinds here
//     are four different sentences on purpose.
//  2. **Exactly what will be touched.** The whole point of asking is that the person can
//     tell what they are approving, so the process names and pids, the container, or the
//     preference key and value are part of the copy — not a detail the view assembles.
//  3. **What each button does to the waiting request.** Approve is `.approved`; deny,
//     closing the window, and a window that could not be shown are all refusals *with a
//     reason*, because the reason is what the AI client reads and a bare "denied" tells
//     the model nothing about whether retrying could help.
//
// One implementation of each sentence, deliberately: `HostMCPCallContext` builds the
// question the broker holds out of the same `detail`, so the app cannot end up asking
// about one change and showing another. `MCPApprovalPresentationTests` walks the catalog
// to keep those two in agreement.

import Foundation

/// Every word the confirmation window shows, and the meaning of every press on it.
public enum MCPApprovalCopy {

    /// What a press on the window means to the broker's `decide`.
    ///
    /// Deliberately not a `Bool` and not an `ApprovalOutcome`: "the window was closed"
    /// and "the person said no" are different acts that reach the AI client differently,
    /// and a type that cannot tell them apart will eventually treat them alike.
    public enum Action: Equatable, Sendable {
        /// The person agreed.
        case approve
        /// The person said no.
        case deny
        /// The window went away without an answer — the close button, the red dot, or
        /// anything else that is not a decision.
        case closed
    }

    // MARK: - What the window calls a change

    /// The heading above the question: this kind of change, in words.
    ///
    /// Not the question itself — that is `MCPApprovalRequest.summary`, which carries
    /// the app id or container name and is built where the request is built. This says
    /// what sort of thing is being asked about, so a person reading only the heading
    /// knows whether they are about to quit something or change a setting.
    public static func summary(for kind: MCPApprovalRequest.Kind) -> String {
        switch kind {
        case .quitApp: return "Quit an app"
        case .stopContainer: return "Stop a container"
        case .stopProject: return "Stop a project"
        case .setPreference: return "Change a Portmaster preference"
        }
    }

    /// The button that grants consent, named after what it grants.
    ///
    /// "OK" on a window that stops processes is a button a person clicks without
    /// reading; this is the same button with the verb on it.
    public static func approveTitle(for kind: MCPApprovalRequest.Kind) -> String {
        switch kind {
        case .quitApp: return "Quit App"
        case .stopContainer: return "Stop Container"
        case .stopProject: return "Quit Project"
        case .setPreference: return "Change Preference"
        }
    }

    /// Shown above everything else, because the person reading this window did not ask
    /// for it: something else did.
    public static let requestedByClientNotice =
        "An AI client asked Portmaster to make this change."

    // MARK: - What the change will do, and to what

    /// The body of the prompt: the sentence, plus the exact targets when there are any.
    ///
    /// `targets` are the lines the window lists — a process name and pid per member, the
    /// container name, or `key = value` — and they are part of the copy rather than the
    /// view's business so that "the person is shown exactly what will be affected" is a
    /// property a test can hold still. Empty `targets` adds nothing at all: the request
    /// was built before anything resolved, so its sentence has to stand on its own.
    public static func detail(
        for kind: MCPApprovalRequest.Kind,
        arguments: [String: String],
        targets: [String]
    ) -> String {
        let sentence = whatItDoes(kind: kind, arguments: arguments)
        guard !targets.isEmpty else { return sentence }
        return ([sentence, leadIn(for: kind, count: targets.count)]
            + targets.map { "• \($0)" }).joined(separator: "\n")
    }

    /// The one sentence per kind, and nothing else.
    ///
    /// Separate from `detail` so the wording has exactly one home whether it is being
    /// asked with nothing resolved yet or shown with a list of processes.
    private static func whatItDoes(
        kind: MCPApprovalRequest.Kind, arguments: [String: String]
    ) -> String {
        switch kind {
        case .quitApp:
            let id = named(arguments["id"], fallback: "an app the client did not name")
            let forced = (arguments["force"] ?? "").lowercased() == "true"
            return forced
                ? "Quit every process of \(id) without asking it to save first."
                : "Quit every process of \(id), asking each to close cleanly first."
        case .stopContainer:
            let id = named(arguments["id"], fallback: "a container the client did not name")
            return "Run 'docker stop \(id)', which asks the container's own entrypoint to shut down."
        case .stopProject:
            let id = named(arguments["id"], fallback: "a project the client did not name")
            return "Quit every process belonging to \(id), asking each to close cleanly first."
        case .setPreference:
            let key = named(arguments["key"], fallback: "a preference the client did not name")
            let value = named(arguments["value"], fallback: "a value the client did not name")
            return "Change Portmaster's \(key) preference to \(value)."
        }
    }

    /// What the list under the sentence is a list *of*. One per kind, because "exactly
    /// these 3 processes" is not true of a container and "the container to stop" is not
    /// true of a preference.
    private static func leadIn(for kind: MCPApprovalRequest.Kind, count: Int) -> String {
        switch kind {
        case .quitApp, .stopProject:
            return "Portmaster will ask these \(count) processes to quit:"
        case .stopContainer:
            return "Portmaster will run 'docker stop' on:"
        case .setPreference:
            return "Portmaster will change:"
        }
    }

    /// An argument a client left out reads as a missing name, never as a hole in a
    /// sentence. The executor rejects such a call first; this is what a person would
    /// read if one ever got here, and `"Quit every process of , asking…"` is not that.
    private static func named(_ raw: String?, fallback: String) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return fallback }
        return trimmed
    }

    /// Said when the membership changed between showing the list and pressing Approve.
    ///
    /// The person is asked again rather than being told their approval covers a list
    /// they never saw: the executor recomputes membership from its own fresh reading,
    /// and "you approved stopping 3 processes" must not turn out to mean five.
    public static let listChangedNotice =
        "Portmaster's list changed while you were deciding. Review the new list and approve again."

    // MARK: - The rest of the window

    /// How many requests are still waiting behind the one being shown. Empty for none,
    /// because a lone request has nothing to say about company.
    public static func queuedNotice(additional: Int) -> String {
        switch additional {
        case ..<1: return ""
        case 1: return "1 more request is waiting behind this one."
        default: return "\(additional) more requests are waiting behind this one."
        }
    }

    /// The remaining budget, counted down.
    ///
    /// The AI client stops waiting at the broker's budget whether or not anyone is
    /// looking at this window, so the window shows the same number rather than leaving
    /// a person to discover the limit as a silent refusal later. Rounded up, so a budget
    /// with a fraction of a second left never reads as "0" — and a budget already spent
    /// says so instead of counting down from zero.
    public static func countdown(remaining: TimeInterval) -> String {
        let whole = Int(remaining.rounded(.up))
        guard whole > 0 else {
            return "The AI client's budget is spent; this action is being refused."
        }
        return "No answer in \(whole)s — Portmaster refuses this action and tells the AI client."
    }

    // MARK: - What a press means

    /// The outcome a press hands to `ConfirmationBroker.decide`.
    ///
    /// Total on purpose. There is no fourth thing a window can do, and a presenter that
    /// had to invent an outcome for "the window went away" would be the one place a
    /// request could be left without an answer.
    public static func outcome(for action: Action) -> ApprovalOutcome {
        switch action {
        case .approve: return .approved
        case .deny: return .denied(reason: deniedReason)
        case .closed: return .denied(reason: closedReason)
        }
    }

    /// Said when a person presses Deny.
    public static let deniedReason =
        "The request was denied in Portmaster, so this action was not taken."

    /// Said when the window goes away with nothing decided.
    ///
    /// Its own sentence rather than `deniedReason`'s, because the two mean different
    /// things to whoever is on the other end: one is an answer, the other is silence
    /// that Portmaster is reporting rather than passing on. Neither is consent.
    public static let closedReason =
        "Portmaster's confirmation window was closed without an answer, so this action was not taken."

    /// Said when no window could be shown at all.
    ///
    /// Immediate and unhedged, because the alternative is the client waiting out a
    /// 60-second budget for an answer that can never arrive. It names the app's own
    /// state and stops there: the request is refused, not delayed.
    public static let couldNotPresentReason =
        "Portmaster could not show the confirmation window."
}

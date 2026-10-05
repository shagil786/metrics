// MCPConfirmationWindow: the window a person answers an AI client in.
//
// This is what `confirmEach` mode is for. Until it exists the host had a seam
// (`MCPHostController.approvalPresenter`) and nothing behind it, so a confirmation was
// answered by an immediate refusal; with it, an AI client's request to change the
// machine becomes a question with Approve and Deny on it, and the broker's answer —
// not this window's own bookkeeping — is what the tool result is made of.
//
// Five properties decide whether this feature is usable, and each is a way it can be
// quietly wrong:
//
//  1. **One window, one decision at a time.** `present` shows whatever is at the *head*
//     of the broker's queue rather than the request it was handed, so a burst of agent
//     calls cannot stack dialogs, and the id the buttons answer is the id on screen
//     rather than the id a closure captured. `queuedCount` is shown, because a person
//     told nothing about the other two requests waiting behind this one has no way to
//     know they exist.
//  2. **Nothing hangs.** `present` returns whether it could show anything; a false is
//     answered immediately with `MCPApprovalCopy.couldNotPresentReason` rather than left
//     to the 60-second budget. A request Portmaster itself cannot perform — an app that
//     is not there, a container docker does not know — is refused with the *shared*
//     refusal the proxied path would have given, in the same words, because asking a
//     person to approve something that cannot happen is a question with no honest answer.
//  3. **Approving runs the confirmed stop, not a shortcut.** The list shown is an
//     `AppModel.StopTarget` built by the app's own membership machinery, rendered by the
//     same `StopTargetMemberList` the UI's sheet uses. The approval itself is *not*
//     performed here: `HostMCPCallContext` runs the tool after `.approved`, and
//     `LiveAppView.stopApp` signals `StopCoordinator.stopConfirmed` over its own freshly
//     computed membership. Stopping in the window as well would signal the same pids
//     twice — the second attempt finding processes already gone and reporting a failure
//     for a stop that had worked.
//  4. **The list cannot change under an approval.** That fresh recomputation is also why
//     the membership is re-resolved when Approve is pressed: if it moved, the person is
//     shown the new list and asked again rather than having their "yes" stretched over
//     processes they never saw. The window's copy claims this, so it has to be true.
//  5. **Deny is the default.** Closing the window — the button, the red dot, a quit —
//     answers the request with a reason instead of leaving it to time out, and the
//     countdown of the client's budget is on screen so the limit is something a person
//     can see rather than discover later as a silent refusal.
//
// The words are `MCPApprovalCopy`'s and the press-to-outcome mapping is too, because
// the app target has no test target; `MCPApprovalPresentationTests` holds both still.
// What is left here is drawing and the seams this file cannot be handed a test for:
// AppKit's window, the run-loop timer, and `AppModel`'s reading.

import AppKit
import PortmasterCore
import PortmasterMCP
import SwiftUI

/// The one window an AI client's request is confirmed in.
///
/// Owned by `AppDelegate` for the life of the app, like the main and settings windows:
/// it has to be reachable while Portmaster is a menu-bar-only accessory with no other
/// window open, which means it creates and orders its own `NSWindow` rather than
/// appearing inside a scene.
@MainActor
final class MCPConfirmationWindow: NSWindowController, NSWindowDelegate {

    /// How often the window re-reads the broker while something is on screen.
    ///
    /// One second: fast enough that the countdown moves and a request that timed out or
    /// was cancelled (a quit) is noticed while the person is still looking at the
    /// window, slow enough to be invisible next to the 60 seconds it is counting down.
    private static let tickInterval: TimeInterval = 1

    private let state = MCPApprovalState()
    private var broker: ConfirmationBroker?
    private var ticker: Timer?

    init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Presenting

    /// Shows the pending request and answers the broker. Returns false when a window
    /// could not be presented — the caller then denies with a reason, because a request
    /// nobody can answer must not wait out a 60-second budget.
    ///
    /// `request` is what the broker handed the presenter, and it is deliberately *not*
    /// what gets shown: the broker serves requests in order, so this may be the second
    /// of a burst and the one at the head is the one a person can answer. The argument
    /// is still worth having — it is the caller's proof that something is pending, and a
    /// `false` here is about this app's ability to show anything at all.
    func present(_ request: MCPApprovalRequest, broker: ConfirmationBroker) -> Bool {
        if window == nil { _ = makeWindow() }
        // Two ways this can fail, both of which mean the same thing to a caller: there is
        // no app to put a window on (`NSApp` is nil only while it tears down), or no
        // window could be made. Either way the request is refused rather than left to
        // time out.
        guard NSApp != nil, window != nil else { return false }
        self.broker = broker
        startTicking()
        Task { await reconcile() }
        return true
    }

    /// Puts the window on screen, if it is not already there.
    ///
    /// Called from `reconcile` rather than only from `present`, because the window can be
    /// closed while a request is still waiting — the person closes it, which answers that
    /// request but not the next one, and the next one's `present` has already been called
    /// by the time it is queued behind the first. Raising here rather than at the call
    /// site is what keeps that from leaving a request waiting behind a closed window.
    private func raise() {
        guard let window, !window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        // Accessory-app ordering rule, the same one `openMainWindow` documents: the app
        // is never active, so ordering front alone can leave the window under whatever
        // the user was using. Raised only when hidden, so a burst of queued requests
        // activates the app once rather than once each.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes the window without answering anything.
    ///
    /// For the quit path, where `MCPHostController.stop` has already denied every
    /// pending request: there is nothing left to ask about, and leaving a window up
    /// asking about a request that is already refused would be a lie.
    func dismiss() {
        state.request = nil
        stopTicking()
        close()
    }

    private func makeWindow() -> NSWindow? {
        let created = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        created.title = "Confirm AI Request"
        created.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: MCPConfirmationView(
                state: state,
                approve: { [weak self] in self?.approve() },
                deny: { [weak self] in self?.decide(.deny) }
            )
        )
        // The window manages its own size. A hosting view driving constraints while a
        // countdown re-renders is the same mid-layout constraint churn `openMainWindow`
        // documents, so the two agree on leaving the sizing to AppKit.
        host.sizingOptions = []
        created.contentView = host
        created.delegate = self
        window = created
        return created
    }

    // MARK: - Keeping the window and the broker in agreement

    /// Re-reads the broker and shows whatever it is actually waiting for.
    ///
    /// The broker is the only source of truth here, and it is read rather than tracked:
    /// a request can leave its queue three ways this window does not initiate — a person
    /// answered it, its budget ran out, or `cancelAll` denied it on the way out of the
    /// app — and a window that kept showing a decided request would be offering a button
    /// that goes nowhere.
    private func reconcile() async {
        guard let broker else { return }
        // Bounded by what was waiting: every refusal below removes one request, so the
        // queue is the loop's own bound. Without it a broker that somehow kept handing
        // back the same refused entry would spin the main actor instead of stopping.
        var refusalsLeft = await broker.queuedCount
        while true {
            let head = await broker.pending.first
            let queued = await broker.queuedCount
            let deadline = await broker.pendingDeadline

            state.remaining = deadline.map { $0.timeIntervalSinceNow } ?? 0
            // `queuedCount` includes the request on screen, which the window is already
            // showing; what a person needs to know is how many are behind it.
            state.queued = max(0, queued - 1)

            guard let head, refusalsLeft > 0 else {
                stopTicking()
                state.request = nil
                if window?.isVisible == true { close() }
                return
            }
            switch Self.resolve(head) {
            case .refused(let reason):
                // Portmaster cannot do this at all, so nobody is asked: the client is
                // told the same words the proxied path would have given it, at once.
                refusalsLeft -= 1
                await broker.decide(id: head.id, outcome: .denied(reason: reason))
                // And on to whatever is next — the refusal was this request's answer.
                continue
            case .shown(let resolved):
                let changed = state.request?.id != head.id
                state.request = head
                state.stopTarget = resolved.stopTarget
                state.targets = resolved.targets
                if changed { state.note = nil }
                raise()
                return
            }
        }
    }

    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reconcile() }
        }
        // `.common`, so the countdown keeps moving while a menu is tracking or a window
        // is being dragged — precisely when someone is deciding.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - Answering

    private func approve() {
        guard let request = state.request else { return }
        // Re-resolved, not trusted: the executor recomputes membership from its own
        // fresh reading after the approval, so a list that has moved since it was shown
        // must not be covered by a "yes" given to the old one. Refusing here is the
        // same answer as `reconcile`'s — the request cannot be performed, so the client
        // is told why rather than asked about something that is gone.
        switch Self.resolve(request) {
        case .refused(let reason):
            Task { await decideNow(request.id, .denied(reason: reason)) }
            return
        case .shown(let resolved):
            // Compared by pid, in order: identity is rechecked by the coordinator
            // anyway, so what matters is *which* processes, not their start times.
            if let before = state.stopTarget, let after = resolved.stopTarget,
                before.members.map({ $0.pid }) != after.members.map({ $0.pid }) {
                state.stopTarget = resolved.stopTarget
                state.targets = resolved.targets
                state.note = MCPApprovalCopy.listChangedNotice
                return
            }
            state.stopTarget = resolved.stopTarget
            state.targets = resolved.targets
        }
        Task { await decideNow(request.id, MCPApprovalCopy.outcome(for: .approve)) }
    }

    private func decide(_ action: MCPApprovalCopy.Action) {
        guard let request = state.request else { return }
        Task { await decideNow(request.id, MCPApprovalCopy.outcome(for: action)) }
    }

    /// Answers the broker and shows whatever is next, in that order.
    ///
    /// One hop rather than two, because two Tasks would race: a reconcile that read the
    /// queue before the answer landed would find the request still there and put it back
    /// on screen, and the person would watch the same prompt they just answered come
    /// back for a second. Cleared before the answer as well, so a close that follows —
    /// ours or theirs — cannot answer the same request twice.
    private func decideNow(_ id: UUID, _ outcome: ApprovalOutcome) async {
        state.request = nil
        state.note = nil
        await broker?.decide(id: id, outcome: outcome)
        await reconcile()
    }

    /// Closing the window is a refusal, because nobody answered.
    ///
    /// The request on screen is refused with its own reason, and anything still queued
    /// behind it is refused with the same words rather than left to time out. That second
    /// half is deliberate: nothing will raise this window again for a request that was
    /// already waiting when the person dismissed it, so a burst of three would otherwise
    /// leave two callers hanging for 60 seconds each and the person never asked. A
    /// request that arrives *after* this is a new arrival, and its own `present` raises a
    /// window for it.
    ///
    /// Only ever reached with something on screen: `decideNow` clears the request first,
    /// so the close this controller performs after a decision has nothing left to refuse
    /// and the answer that already went to the broker stands.
    func windowWillClose(_ notification: Notification) {
        stopTicking()
        guard let broker else { return }
        let dismissed = state.request?.id
        state.request = nil
        state.note = nil
        Task {
            if let dismissed {
                await broker.decide(
                    id: dismissed, outcome: MCPApprovalCopy.outcome(for: .closed)
                )
            }
            await broker.cancelAll(reason: MCPApprovalCopy.closedReason)
        }
    }

    // MARK: - What the request will touch

    /// A request resolved against the app's own reading, or the reason it cannot be.
    private enum Resolution {
        case shown(Resolved)
        /// The words the AI client will read. `OnDemandProvider`'s own, so the proxied
        /// path and this fallback cannot tell a caller two different stories.
        case refused(String)
    }

    private struct Resolved {
        /// Present for a quit or a project: the same value the UI's sheet stops, so the
        /// membership machinery is one implementation.
        var stopTarget: AppModel.StopTarget?
        /// One line per affected thing, for the kinds with no process list.
        var targets: [String]
    }

    /// Resolves what `request` will touch, or refuses it with the sentence the tool
    /// itself would have given.
    ///
    /// Every check here is one the executor would make anyway, asked *before* a person
    /// is troubled with it, and each is refused with the library's own helper rather than
    /// a local sentence: `appNotFound`, `noRunningProcessesMessage`,
    /// `dockerUnavailableMessage` and `containerNotFound` are shared precisely so the
    /// app and the proxied path cannot disagree about what is missing.
    private static func resolve(_ request: MCPApprovalRequest) -> Resolution {
        let model = AppModel.shared
        let id = request.arguments["id"] ?? ""

        switch request.kind {
        case .quitApp:
            // Preview data first: an id in a sample reading is not a process, and the
            // stop would be refused after the person had already agreed to it.
            if model.prefs.fixtureMode { return .refused(LiveAppView.previewDataStopRefusal) }
            guard let rollup = model.snapshot.rollups.first(where: { $0.id == id }) else {
                return .refused(OnDemandProvider.appNotFound(id).message)
            }
            // `project: nil` for the reason `LiveAppView.stopApp` gives: an app's
            // processes are not a project.
            let target = model.stopTarget(
                name: rollup.displayName, project: nil,
                members: ConfirmedStopPlan.ordered(rollup.processes)
            )
            guard !target.members.isEmpty else {
                return .refused(OnDemandProvider.noRunningProcessesMessage(for: rollup.displayName).message)
            }
            return .shown(Resolved(stopTarget: target, targets: []))

        case .stopProject:
            if model.prefs.fixtureMode { return .refused(LiveAppView.previewDataStopRefusal) }
            let target = model.projectStopTarget(id)
            guard !target.members.isEmpty else {
                return .refused(OnDemandProvider.noRunningProcessesMessage(forProject: id).message)
            }
            return .shown(Resolved(stopTarget: target, targets: []))

        case .stopContainer:
            // No preview-data guard here, and deliberately: `LiveAppView.stopContainer`
            // has none either, because a container is not a process in a reading — the
            // docker sample can be a sample and the stop is still a real `docker stop`.
            // Adding a refusal the write path does not have would be a second policy
            // about something the tool does not consider preview data.
            guard let docker = model.snapshot.docker else {
                return .refused(OnDemandProvider.dockerNotKnownMessage)
            }
            if let refusal = DockerContainerStop.refusal(container: id, in: docker) {
                return .refused(refusal.message)
            }
            return .shown(Resolved(stopTarget: nil, targets: [id]))

        case .setPreference:
            // `validate` is `apply` against a throwaway blob, so asking the question here
            // cannot disagree with the write: a key or value that would be refused is
            // refused now, with the same sentence.
            let key = request.arguments["key"] ?? ""
            let value = request.arguments["value"] ?? ""
            do {
                try PreferencesStore.validate(key: key, value: value)
            } catch let error as MCPToolError {
                return .refused(error.message)
            } catch {
                return .refused("\(error.localizedDescription)")
            }
            return .shown(Resolved(stopTarget: nil, targets: ["\(key) = \(value)"]))
        }
    }
}

/// What the window draws, and nothing else: the controller decides, this holds what it
/// decided, and every value is written from the main actor.
@MainActor
final class MCPApprovalState: ObservableObject {
    /// The request on screen, or `nil` when there is nothing to decide — which is also
    /// what stops a close from answering a request that has already been answered.
    @Published fileprivate(set) var request: MCPApprovalRequest?
    /// Set for a quit or a project; `nil` for a container or a preference.
    @Published fileprivate(set) var stopTarget: AppModel.StopTarget?
    /// One line per affected thing for the kinds with no process list.
    @Published fileprivate(set) var targets: [String] = []
    /// Seconds left of the client's budget, as the broker computed it.
    @Published fileprivate(set) var remaining: TimeInterval = 0
    /// How many requests are waiting behind this one.
    @Published fileprivate(set) var queued: Int = 0
    /// Why the person is being asked again, when they are.
    @Published fileprivate(set) var note: String?
}

private struct MCPConfirmationView: View {
    @ObservedObject var state: MCPApprovalState
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let request = state.request {
                header(for: request)
                Divider()
                body(for: request)
                if let note = state.note {
                    Label(note, systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                footer
            } else {
                // Only reachable for the frame between a decision and the next request:
                // `reconcile` closes the window as soon as it knows nothing is waiting.
                Text("Nothing is waiting for an answer.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.padding(18).frame(width: 520, height: 430)
    }

    private func header(for request: MCPApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                MCPApprovalCopy.summary(for: request.kind),
                systemImage: "exclamationmark.triangle"
            ).font(.headline).foregroundStyle(.orange)
            // The person reading this window did not ask for it. Saying so first is the
            // difference between consenting to a change and watching the app change
            // something on its own.
            Text(MCPApprovalCopy.requestedByClientNotice)
                .font(.caption).foregroundStyle(.secondary)
            Text(request.summary).font(.headline).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func body(for request: MCPApprovalRequest) -> some View {
        if let target = state.stopTarget {
            Text(MCPApprovalCopy.detail(
                for: request.kind, arguments: request.arguments, targets: []
            )).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                // The same list the sheet shows, over the same `StopTarget`, with the
                // force-quit sentence left out because nothing can be offered after an
                // answer has already gone back to the AI client.
                StopTargetMemberList(target: target, offersForceAfterwards: false)
            }
        } else {
            ScrollView {
                Text(MCPApprovalCopy.detail(
                    for: request.kind, arguments: request.arguments, targets: state.targets
                )).font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The client's budget is on screen rather than discovered later as a refusal
            // nobody was watching for.
            Text(MCPApprovalCopy.countdown(remaining: state.remaining))
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()
            let queued = MCPApprovalCopy.queuedNotice(additional: state.queued)
            if !queued.isEmpty {
                Text(queued).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                // Cancel action, and the window's close button behaves the same way:
                // neither is consent.
                Button("Deny", role: .cancel, action: deny).keyboardShortcut(.cancelAction)
                if let request = state.request {
                    Button(MCPApprovalCopy.approveTitle(for: request.kind), role: .destructive, action: approve)
                        .keyboardShortcut(.defaultAction)
                        .disabled(state.stopTarget?.members.isEmpty ?? false)
                }
            }
        }
    }
}

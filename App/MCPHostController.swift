// MCPHostController: the running app as an MCP host.
//
// Until this file, `MCPHostServer` was a library type nothing owned: a CLI could
// reach it in a test and nowhere else. This is the ownership — one host, started
// once when Portmaster launches and stopped when it quits, serving the app's own
// live data to any local client that can present the token from the endpoint file.
//
// Everything that is a *decision* rather than glue lives in the library, because the
// app target has no test target and a decision nothing can test is a decision that
// drifts: the mutation policy and a person's answer are `HostMCPCallContext`, the
// refusals are `OnDemandProvider`'s own, the docker stop is `DockerContainerStop`,
// the preference mapping is `PreferencesStore.apply`. What is left here is the
// thing only this file can know — which app state answers which closure, when the
// host starts and stops, and what the user is told about it. `MCPHostWiringTests`
// covers the decisions; the seams below are covered by Task 10's end-to-end script,
// because a wiring bug in this file has no symptom short of a real client talking
// to a real app.
//
// Three properties this file has to keep:
//
//  1. **Nothing here runs per sample.** There is no subscription to the app's
//     `@Published` state at all: every read publishes from the app when it is asked
//     (`LiveAppView`), so the cost is one main-actor hop per tool call and zero per
//     tick. A feature with nobody calling it costs one bound socket and one thread
//     parked in `poll`.
//  2. **The app is the writer.** Preference writes go through `AppModel.prefs`, so
//     the running app cannot clobber itself, and no `MCPSettings` file is written
//     behind the app's back — `mcpMode` is intercepted by the executor before the
//     provider is reached and never arrives here at all.
//  3. **Quitting takes the socket with it.** `stop()` denies every pending approval
//     first — so nothing waits out a 60-second budget on the way out — and then
//     removes the socket and the endpoint file. A file left behind would still be
//     rejected by `EndpointFileStore.read`'s pid check, but the honest thing is to
//     clean up rather than to rely on being caught.

import Foundation
import os
import PortmasterCore
import PortmasterMCP
import SwiftUI

/// What the host is doing, as far as the user is concerned.
///
/// `failed` carries the reason because the alternative is an app that silently has
/// no MCP host: the only other symptom of a failed bind is a CLI reporting that
/// there is no Portmaster answering, which points nowhere.
public enum MCPHostStatus: Equatable {
    case notRunning
    case listening(socket: URL)
    case failed(String)
}

/// Owns the MCP host for the life of the app.
@MainActor
final class MCPHostController: ObservableObject {

    /// Diagnostics for this file's own failures, on the same subsystem and category
    /// the library uses so one `log show --predicate` finds both.
    ///
    /// Only for what the library cannot log for itself: a settings file that could
    /// not be written. A host that failed to bind is already logged by
    /// `MCPHostServer.start`, and logging it twice would put two lines in the log
    /// where one is a fact.
    private static let log = Logger(subsystem: "app.portmaster", category: "mcp-host")

    /// Where a person answers an approval prompt.
    ///
    /// `nil` until Task 8 installs a presenter, and **that is the honest state, not a
    /// no-op**: with no window there is nobody to ask, so a confirmation is answered
    /// here immediately with a reason instead of being left to time out 60 seconds
    /// later. The brief's shape — a closure defaulting to `{ _ in }` — cannot
    /// distinguish "no window" from "a window that does nothing", and this one has to.
    var approvalPresenter: ((MCPApprovalRequest) -> Void)?

    /// The window `presentConfirmation` puts requests in, when there is one.
    ///
    /// Not `approvalPresenter`'s job to own: the presenter is a seam that can be absent
    /// (a headless launch, a test), and the rule that a request nobody can answer must be
    /// answered at once belongs with the broker rather than inside whatever the app
    /// happened to install. `nil` is that case, and it is answered like any other.
    @MainActor var confirmationWindow: MCPConfirmationWindow?

    @Published private(set) var status: MCPHostStatus = .notRunning
    /// The MCP server's own mutation policy, mirrored for display.
    ///
    /// **Read from `MCPSettings`, never from `AppPreferences`.** It is the MCP
    /// server's policy rather than an app preference, it is what the executor
    /// enforces on every call, and it is the only one of the two a client can reach
    /// through `set_preference`. Display-only: the host re-reads the file per call, so
    /// a value that has gone stale here changes nothing that is enforced.
    @Published private(set) var mode: MCPMutationMode
    /// Who is connected, mirrored for display. Refreshed on demand — see
    /// `refreshClients()` — rather than on a timer.
    @Published private(set) var clients: [MCPConnectedClient] = []
    /// The mode a person last chose and Portmaster could not write, or `nil`.
    ///
    /// **Published separately from `mode`, and never folded into it.** The mode stays
    /// unchanged when the save fails — reporting a policy the file does not have would be a
    /// lie the next tool call would contradict — which means the radio snaps back. Without
    /// this, a person who chose correctly on a machine with an unwritable settings file
    /// watches the control revert and has no way to tell a refusal from a failed write, and
    /// will reasonably conclude Portmaster decided their choice was not allowed. So the
    /// failure is carried here for Settings to say out loud, and it names the mode that did
    /// not stick.
    ///
    /// Cleared by the next successful `setMode`, so a failure that is later resolved does
    /// not keep explaining itself.
    @Published private(set) var modeSaveFailure: MCPMutationMode?

    /// Where the mutation-mode policy lives. `nil` is the per-user `~/.portmaster`,
    /// which is where a CLI looks for it too.
    private let directory: URL?
    private let broker = ConfirmationBroker()
    private let live: LiveAppView
    private var host: MCPHostServer?

    init(directory: URL? = nil) {
        self.directory = directory
        live = LiveAppView(loadMode: { MCPSettings.load(directory: directory).mode })
        // The documented default rather than a read of the file: this runs before
        // `applicationDidFinishLaunching`, so a read here would be a file open on a
        // path that may be replaced moments later, and a mode read too early is
        // wrong for longer than it is right. `start()` reads the file before any
        // surface can show anything, and `refreshFromSettings()` reads it every time
        // Settings opens.
        mode = MCPSettings.defaultMode
    }

    // MARK: - Lifecycle

    /// Binds the socket and starts serving. Safe to call twice: the second call
    /// returns without touching the first host, so a caller that does not know
    /// whether launch already ran it cannot end up with two.
    func start() {
        guard host == nil else { return }
        // Nothing is scheduled after this, and nothing is seeded either: every read
        // publishes from the app for itself. What is needed once, at launch, is the mode
        // Settings shows, and the history reader — the store behind it cannot change
        // under the app afterwards, so unlike the other three values it is not a
        // per-read question.
        refreshFromSettings()
        live.publishHistory(makeHistory())
        let started = MCPHostServer(
            socketURL: Self.socketURL(in: directory),
            endpointDirectory: directory,
            context: makeContext(),
            // The app's own store, opened once by `AppModel`. `nil` is a real answer —
            // it refuses `report_usage` with a reason — and it is passed through rather
            // than defaulted, so a store that failed to open cannot be papered over by
            // the host inventing one.
            sessionStore: AppModel.shared.agentSessionStore
        )
        do {
            try started.start()
        } catch {
            // `MCPHostServer.start` has already logged the reason and left nothing
            // bound behind, so this only publishes the failure to the UI.
            status = .failed("\(error.localizedDescription)")
            return
        }
        host = started
        status = .listening(socket: started.socketURL)
        refreshClients()
    }

    /// Whether a host is bound and serving.
    ///
    /// Read by `applicationShouldTerminate` to answer `.terminateNow` without an await
    /// when there is nothing to stop — which is the case for every launch whose bind
    /// failed, and for any quit after `stop()`.
    var isRunning: Bool { host != nil }

    /// Denies every pending approval, stops serving, and removes the socket and the
    /// endpoint file.
    ///
    /// Async because `MCPHostServer.stop` is: it closes every admitted connection,
    /// waits for the accept thread, and only then unlinks. Called from
    /// `applicationShouldTerminate` rather than `applicationWillTerminate`, which
    /// cannot await and would otherwise leave the socket file behind on every quit.
    func stop() async {
        // First, so nothing is left waiting on a person who is already leaving.
        await broker.cancelAll(reason: Self.quittingReason)
        // Then the window goes with them: the pending requests are already answered, so a
        // window still asking about one would offer a button that goes nowhere. Its own
        // close path cannot double-answer — `decide` ignores an id the broker no longer
        // holds.
        confirmationWindow?.dismiss()
        guard let host else {
            status = .notRunning
            return
        }
        await host.stop()
        self.host = nil
        clients = []
        status = .notRunning
    }

    /// What a pending approval is told when the app is quitting.
    ///
    /// Its own sentence rather than `PermissionGate`'s: that one is about a mode, and
    /// this is about the app going away — which is why no answer will ever arrive.
    static let quittingReason =
        "Portmaster is quitting, so this action was not taken."

    // MARK: - Published state

    /// Re-reads the mutation mode for display.
    ///
    /// Needed because an AI client can change `mcpMode` through `set_preference`,
    /// which writes the file and never reaches this controller — so the published
    /// mode would otherwise be stale until the next launch. Called when Settings
    /// opens, which is the only place it is shown. Nothing *enforced* depends on it:
    /// `get_settings` reads the file per call, and the gate does too.
    func refreshFromSettings() {
        mode = MCPSettings.load(directory: directory).mode
    }

    /// Republishes who is connected.
    ///
    /// Called rather than polled: the host holds the live list, and Settings is the
    /// only reader, so a timer would wake a menu-bar app once a second to update a
    /// row nobody is looking at. `openSettingsWindow()` calls this for the same reason
    /// it calls `refreshFromSettings()` — a client can connect, ask and disconnect
    /// entirely between two openings, so the list has to be read at the moment it is
    /// shown.
    func refreshClients() {
        clients = host?.connectedClients() ?? []
    }

    /// The ids of the sessions this host is serving right now.
    ///
    /// Read from the host rather than from `clients`, which is a display cache
    /// refreshed when Settings opens: a retention sweep may run minutes after the last
    /// refresh, and a stale list would let it delete the row of a connection that is
    /// still there — after which that connection's next report lands under an id no
    /// row names.
    ///
    /// `MCPConnectedClient.id` is the same UUID the host minted for the connection and
    /// wrote as the session's id at accept time, so this set is the set of session ids
    /// that can still receive reports.
    var connectedSessionIDs: Set<UUID> {
        Set(host?.connectedClients().map(\.id) ?? [])
    }

    /// Changes the mutation policy and persists it.
    ///
    /// Writes the same file the executor and the CLI read, so the three cannot
    /// disagree about what mode this MCP server is in. A failed write leaves the
    /// published mode unchanged — reporting a mode the file does not have would be a
    /// lie the next call would contradict.
    func setMode(_ mode: MCPMutationMode) {
        var settings = MCPSettings.load(directory: directory)
        settings.mode = mode
        do {
            try settings.save(directory: directory)
        } catch {
            Self.log.info("could not save the MCP mutation mode: \(error.localizedDescription, privacy: .public)")
            // Published so the page can say the write failed rather than leaving the radio
            // to snap back in silence. Deliberately *not* assigning `mode`: the file does
            // not have it, so displaying it would be a claim the next call contradicts.
            modeSaveFailure = mode
            return
        }
        self.mode = mode
        modeSaveFailure = nil
    }

    /// Where mutation attempts are recorded, for Settings to offer as a reveal.
    var auditLogURL: URL {
        AuditLog(directory: directory).fileURL
    }

    // MARK: - The socket and the call surface

    /// `~/.portmaster/mcp.sock`, beside the endpoint file that names it.
    ///
    /// Derived from the endpoint file's own location rather than from a second
    /// remembered path, because a CLI reads that file to find the socket and the two
    /// answering to different directories is the one bug nothing else would show.
    static func socketURL(in directory: URL?) -> URL {
        EndpointFileStore.defaultURL(directory: directory)
            .deletingLastPathComponent()
            .appendingPathComponent("mcp.sock")
    }

    private func makeContext() -> HostMCPCallContext {
        // Bound as locals so the context does not close over `self`: the controller
        // owns the host that owns the context, and a closure capturing it back would
        // be a cycle that only `stop()` breaks.
        let directory = self.directory
        let broker = self.broker
        return HostMCPCallContext(
            provider: makeProvider(),
            broker: broker,
            // Hopped to the main actor because a presenter opens a window, and the
            // call that asked is running on a socket thread.
            present: { [weak self] request in
                Task { @MainActor in self?.presentToUser(request) }
            },
            // Per call, from the same file every other reader uses: a mode change
            // must not need a relaunch to take effect.
            loadSettings: { MCPSettings.load(directory: directory) },
            appRunning: { AppLiveness.isPortmasterRunning() },
            auditDirectory: directory,
            settingsDirectory: directory,
            // The recorder only. **The session id is deliberately not here** — it would
            // be shared by every connection this host ever serves, and each one's
            // reports would then carry the same id. `MCPHostServer` binds one per
            // connection, at accept time, and passes it down per call.
            sessionRecorder: AppModel.shared.agentSessionStore.map { store in
                StoreSessionRecorder(store: store) {
                    // Hopped to the main actor because the surfaces that redraw on a
                    // new session are published there, and this closure is called from
                    // a socket thread.
                    Task { @MainActor in AppModel.shared.refreshAgentSessions() }
                }
            },
            // A closure for the same reason the recorder is not given an id: this
            // context is shared across every connection, so a set held here would be
            // a snapshot rather than the host's live state.
            // `[weak self]`, and not incidentally: `makeContext` exists so the
            // context does not close over the controller. A strong capture here
            // rebuilds the cycle controller → host → context → closure →
            // controller, which the comment above this function forbids in so many
            // words. `present:` six lines up is weak for the same reason.
            liveSessionIDs: { [weak self] in
                // `self` is read into a local before the hop, not captured *inside*
                // it: a `weak` reference is a mutable box, so using it directly in a
                // nested concurrently-executing closure is a SendableClosureCaptures
                // violation — a warning today, an error under the Swift 6 language
                // mode this project is not yet on.
                let controller = self
                return await MainActor.run {
                    controller?.connectedSessionIDs ?? Set<UUID>()
                }
            },
            // The same store the recorder appends to, so a price and the figures it
            // prices read one file. Resolved here rather than per call, like the
            // recorder above: the store is opened once at launch and never replaced,
            // so there is nothing later to pick up. Nil means `set_model_price`
            // refuses with a reason rather than accepting a price into nothing.
            priceWriter: AppModel.shared.agentSessionStore.map(StoreModelPriceWriter.init)
        )
    }

    /// The provider the tool surface reads.
    ///
    /// Every closure hands on to `live` and nothing else: the app is the sampler,
    /// the app is the writer, and the app's own coordinator is what signals a pid.
    /// Bound once as a local rather than captured through `self`, so the closures
    /// reference the state box rather than the controller — and so no closure can
    /// reach back into the controller from a socket thread.
    private func makeProvider() -> LiveDataProvider {
        let live = self.live
        return LiveDataProvider(
            snapshot: { try await live.snapshot() },
            alerts: { await live.alerts() },
            history: { live.history() },
            settings: { await live.settingsSnapshot() },
            // The app owns the write, so the app is what writes.
            applyPreference: { key, value in try await live.applyPreference(key: key, value: value) },
            stopApp: { id, force in try await live.stopApp(id: id, force: force) },
            stopContainerNamed: { id in try await live.stopContainer(id: id) },
            stopProject: { id in try await live.stopProject(id: id) },
            // Read over the app's own long-lived store — the same one the recorder
            // appends to. Read per call rather than captured, so a session recorded
            // a moment ago is visible to the very next tool call.
            // Read per call rather than captured, so a session recorded a moment ago
            // is visible to the very next tool call. Hopped to the main actor because
            // the store is owned there and this closure runs on a socket thread —
            // the same hop the `present:` closure above makes.
            sessionReading: {
                await MainActor.run {
                    AppModel.shared.agentSessionStore.map { StoreAgentSessionReading(store: $0) }
                }
            }
        )
    }

    /// Opens the window, or answers the request itself.
    ///
    /// The second half is the reason this is not just `approvalPresenter?(request)`:
    /// "nobody can be asked" is an answer, and it has to be given immediately with a
    /// reason the AI client can report. Left to the broker it would be a 60-second
    /// wait followed by a refusal nobody asked for in time.
    private func presentToUser(_ request: MCPApprovalRequest) {
        guard let approvalPresenter else {
            denyNow(request, reason: Self.noPresenterReason)
            return
        }
        approvalPresenter(request)
    }

    /// Puts `request` in `confirmationWindow`, or answers it here.
    ///
    /// Async because of the warm, and the warm is not optional. The window resolves the
    /// membership an approval would cover from the app's published reading, and the
    /// executor recomputes that membership from a *fresh* one once the approval arrives —
    /// so asking about a list read ten minutes ago would let an approval cover processes
    /// the person was never shown, with the window's own copy ("only the processes listed
    /// above") making the claim. Waking the sampler first is what makes that promise
    /// true; `resumeOnce` rather than `noteUserActivity`, for the reason
    /// `LiveAppView.snapshot` gives — a tool call is not a person at the keyboard, and it
    /// must not hold a menu-bar app sampling on its background cadence.
    ///
    /// Bounded by the wake budget, and inside the broker's own 60 seconds rather than
    /// added to them: the budget was armed when the request was queued, and this window
    /// opening is part of what that budget pays for.
    @MainActor
    func presentConfirmation(_ request: MCPApprovalRequest) async {
        // Only a stop needs a reading. A preference change depends on the user's
        // preferences, not on a sampler, so it is never held up by one that is asleep —
        // and never refused by one that cannot be woken.
        if Self.needsReading(request) {
            do {
                _ = try await live.snapshot()
            } catch let error as MCPToolError {
                // The same refusal the tool would have given, at once. `notReadyMessage`
                // is `OnDemandProvider`'s, so a client cannot be told "no reading yet"
                // here and something else by the proxied path.
                denyNow(request, reason: error.message)
                return
            } catch {
                denyNow(request, reason: "\(error.localizedDescription)")
                return
            }
        }
        guard let confirmationWindow, confirmationWindow.present(request, broker: broker) else {
            // A window that would not open is a refusal, not a wait: nobody is going to
            // answer a prompt that is not on screen.
            denyNow(request, reason: MCPApprovalCopy.couldNotPresentReason)
            return
        }
    }

    /// Whether resolving this request depends on the app's current reading.
    ///
    /// A quit and a project are decided by which processes exist right now, so they are
    /// refused when no reading can be had. A container stop, a preference change and a
    /// price are not: the first is docker's business, the second is the preferences
    /// blob's and the third is a number the client already has, and each would be
    /// refused by its own path with its own words if it could not be performed.
    static func needsReading(_ request: MCPApprovalRequest) -> Bool {
        switch request.kind {
        case .quitApp, .stopProject: return true
        case .stopContainer, .setPreference, .setModelPrice, .handoffContext: return false
        }
    }

    /// Answers a request now, with a reason the AI client can read.
    ///
    /// The one place a request can end without a person, so every reason that reaches
    /// it is written here or in `MCPApprovalCopy` — never assembled at a call site.
    private func denyNow(_ request: MCPApprovalRequest, reason: String) {
        Task { await broker.decide(id: request.id, outcome: .denied(reason: reason)) }
    }

    /// Said when a mutation needs confirmation and there is no window to ask in.
    ///
    /// Names the app's own state rather than the client's: the same call made with a
    /// presenter installed would be waiting on a person instead.
    static let noPresenterReason =
        "Portmaster could not ask you to confirm this action, so it was not taken. "
        + "Try again while Portmaster's window is on screen."

    /// The app's history, for the history tools, opened once and kept.
    ///
    /// Decided here rather than in the factory because the store is already open by
    /// the time this runs, and `LazyHistory` only needs a way to reach the same one.
    /// The one thing that is *not* published per read: the store's availability cannot
    /// change under the app, so a reader built once is the whole story.
    private func makeHistory() -> @Sendable () -> any HistoryReading {
        if let store = AppModel.shared.historyStore {
            let reading = StoreHistoryReading(store: store)
            return { reading }
        }
        let message = AppModel.shared.historyError
            ?? "Could not open the local history database."
        return { UnavailableHistoryReading(message: message) }
    }
}

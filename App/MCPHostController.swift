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
//  1. **Nothing here runs per sample.** The host starts once; mirroring is one
//     Combine subscription that *coalesces* — at most one pass in flight, and none at
//     all while no client is connected, so a burst of `@Published` writes (every
//     sample tick writes five) costs one copy rather than five, and an idle app costs
//     none. The one read that can still touch the main actor is a snapshot the mirror
//     could not answer (`LiveAppView.snapshot`), and it hops once and re-reads. A
//     feature with nobody on it costs one bound socket and one thread in `poll`.
//  2. **The app is the writer.** Preference writes go through `AppModel.prefs`, so
//     the running app cannot clobber itself, and no `MCPSettings` file is written
//     behind the app's back — `mcpMode` is intercepted by the executor before the
//     provider is reached and never arrives here at all.
//  3. **Quitting takes the socket with it.** `stop()` denies every pending approval
//     first — so nothing waits out a 60-second budget on the way out — and then
//     removes the socket and the endpoint file. A file left behind would still be
//     rejected by `EndpointFileStore.read`'s pid check, but the honest thing is to
//     clean up rather than to rely on being caught.

import Combine
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

    /// Where the mutation-mode policy lives. `nil` is the per-user `~/.portmaster`,
    /// which is where a CLI looks for it too.
    private let directory: URL?
    private let broker = ConfirmationBroker()
    private let live: LiveAppView
    private var host: MCPHostServer?
    private var mirror: AnyCancellable?
    /// Whether a mirror pass is already queued. See `scheduleMirrorPass`.
    private var mirrorPassPending = false

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
        startMirroring()
        let started = MCPHostServer(
            socketURL: Self.socketURL(in: directory),
            endpointDirectory: directory,
            context: makeContext()
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

    /// Republishes who is connected, and makes sure the mirror is current.
    ///
    /// Called rather than polled: the host holds the live list, and Settings is the
    /// only reader, so a timer would wake a menu-bar app once a second to update a
    /// row nobody is looking at. `openSettingsWindow()` calls this for the same reason
    /// it calls `refreshFromSettings()` — a client can connect, ask and disconnect
    /// entirely between two openings, so the list has to be read at the moment it is
    /// shown.
    ///
    /// The mirror pass matters as much as the list here: mirroring is skipped while no
    /// client is connected (see `scheduleMirrorPass`), so the moment a client
    /// connects is the moment the mirror has to be brought up to date — otherwise the
    /// first tool call of the first session could read a snapshot from before it
    /// connected.
    func refreshClients() {
        clients = host?.connectedClients() ?? []
        if !clients.isEmpty { scheduleMirrorPass() }
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
            return
        }
        self.mode = mode
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
            settingsDirectory: directory
        )
    }

    /// The provider the tool surface reads.
    ///
    /// Every closure hands on to `live` and nothing else: the app is the sampler,
    /// the app is the writer, and the app's own coordinator is what signals a pid.
    /// Bound once as a local rather than captured through `self`, so the eight
    /// closures reference the mirror rather than the controller — and so no closure
    /// can reach back into the controller from a socket thread.
    private func makeProvider() -> LiveDataProvider {
        let live = self.live
        return LiveDataProvider(
            snapshot: { try await live.snapshot() },
            alerts: { live.alerts() },
            history: { live.history() },
            settings: { live.settingsSnapshot() },
            // The app owns the write, so the app is what writes.
            applyPreference: { key, value in try await live.applyPreference(key: key, value: value) },
            stopApp: { id, force in try await live.stopApp(id: id, force: force) },
            stopContainerNamed: { id in try await live.stopContainer(id: id) },
            stopProject: { id in try await live.stopProject(id: id) }
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
            Task { await broker.decide(id: request.id, outcome: .denied(reason: Self.noPresenterReason)) }
            return
        }
        approvalPresenter(request)
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
    private func makeHistory() -> @Sendable () -> any HistoryReading {
        if let store = AppModel.shared.historyStore {
            let reading = StoreHistoryReading(store: store)
            return { reading }
        }
        let message = AppModel.shared.historyError
            ?? "Could not open the local history database."
        return { UnavailableHistoryReading(message: message) }
    }

    /// Keeps the mirror current for as long as the controller is alive.
    ///
    /// One subscription, installed once at `start`, plus a first copy.
    ///
    /// It is subscribed to `objectWillChange`, which fires on *every* `@Published`
    /// mutation — and the per-sample sink alone writes five of them, so an
    /// uncoalesced subscription would copy a whole `ObservationSnapshot` once per
    /// sample tick, for the life of the process, whether or not anything on the
    /// machine was reading it. Hence `scheduleMirrorPass`, which is where the two
    /// rules live: one pass at a time, and none while nobody is connected.
    func startMirroring() {
        guard mirror == nil else { return }
        refreshFromSettings()
        live.publishHistory(makeHistory())
        live.publishFromModel()
        // `objectWillChange` rather than the three publishers: one subscription for
        // three values, and any future `@Published` on the model keeps the mirror
        // honest without touching this file.
        mirror = AppModel.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleMirrorPass() }
    }

    /// Queues at most one mirror pass, and only when someone could read it.
    ///
    /// Coalescing because the notifications arrive in bursts and a pass reads a value
    /// that is the same for all of them: five writes inside one sample tick need one
    /// copy, and the pass runs *after* the turn that wrote them, so it sees the last
    /// one. The flag is cleared inside the task rather than before it, so a change
    /// that lands while a pass is in flight queues the next one instead of being
    /// dropped — losing the *last* notification before the next tick is how a mirror
    /// ends up one tick stale forever.
    ///
    /// Gating on a connected client because the mirror exists only to be read: with
    /// nobody connected there is no caller to answer, and this is the difference
    /// between a menu-bar app that samples all day and one that also copies a
    /// snapshot on every tick for nobody. `refreshClients()` re-arms it the moment a
    /// client is there, so nothing is ever read from a mirror that was switched off.
    private func scheduleMirrorPass() {
        guard !mirrorPassPending else { return }
        guard host?.connectedClients().isEmpty == false else { return }
        mirrorPassPending = true
        // `@Published` fires *before* the value changes, so the copy cannot happen
        // inside the notification: one main-actor turn later — after the setters have
        // returned — is when the new values are visible.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.live.publishFromModel()
            self.mirrorPassPending = false
        }
    }
}

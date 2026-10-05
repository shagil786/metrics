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
//  1. **Nothing here runs per sample.** The host starts once, mirroring is one
//     Combine subscription, and no read the tool surface does touches the main
//     actor. A feature that is off costs one bound socket and one thread parked in
//     `poll`.
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

    init(directory: URL? = nil) {
        self.directory = directory
        live = LiveAppView(loadMode: { MCPSettings.load(directory: directory).mode })
        // Read once here so Settings has something honest to show before the host
        // starts; `refreshFromSettings()` is what keeps it honest afterwards.
        mode = MCPSettings.load(directory: directory).mode
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

    /// Republishes who is connected.
    ///
    /// Called rather than polled: the host holds the live list, and Settings is the
    /// only reader, so a timer would wake a menu-bar app once a second to update a
    /// row nobody is looking at.
    func refreshClients() {
        clients = host?.connectedClients() ?? []
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
            snapshot: { try live.snapshot() },
            alerts: { live.alerts() },
            history: { live.history() },
            settings: { live.settingsSnapshot() },
            // The app owns the write, so the app is what writes.
            applyPreference: { key, value in try live.applyPreference(key: key, value: value) },
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
    /// One subscription, installed once at `start`, plus a first copy. This is the
    /// whole cost of the feature while it is up: nothing here runs per sample, and
    /// nothing wakes the app to look for changes.
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
            .sink { [weak self] _ in
                // `@Published` fires *before* the value changes, so copying here would
                // mirror the value the app is about to replace. One main-actor turn
                // later — after the setter has returned — is what the new value is
                // visible on.
                Task { @MainActor [weak self] in self?.live.publishFromModel() }
            }
    }
}

/// The app's published state, mirrored for the MCP tool path, plus the mutations that
/// only the app may perform.
///
/// `LiveDataProvider` reads three things from the app — the latest snapshot, the
/// current alerts, the current preferences — and **two of its three closures are
/// synchronous**. A synchronous read of main-actor state has exactly two options:
/// block the main thread, or read a copy. Blocking is the wrong one: an MCP call
/// would sit behind whatever the UI is doing, and a socket thread that can make the
/// main thread wait is a deadlock waiting for a busy frame. So the three values are
/// mirrored into a lock-protected box, updated on the main actor, and every closure
/// reads the box.
///
/// That is not a weaker answer. The app publishes these on the main actor and nothing
/// else writes them, so the mirror holds the value the hop would have returned; the
/// only difference is that a read does not wait for an update that is in flight.
final class LiveAppView: @unchecked Sendable {

    private let lock = NSLock()
    private var currentSnapshot: ObservationSnapshot = .empty
    private var currentAlerts: AlertsSnapshot = AlertsSnapshot(source: .live, alerts: [])
    private var currentPreferences = LiveAppView.placeholderPreferences
    private var currentHistory: @Sendable () -> any HistoryReading = {
        UnavailableHistoryReading(message: "Portmaster has not published its history yet.")
    }
    /// Where the mutation policy is read from. A closure because it is the app's
    /// configuration, not this type's business — and because a test seam is the only
    /// reason `directory` exists anywhere above either.
    private let loadMode: @Sendable () -> MCPMutationMode

    init(loadMode: @escaping @Sendable () -> MCPMutationMode) {
        self.loadMode = loadMode
    }

    // MARK: Mirroring (main actor)

    /// Copies whatever the app is holding right now.
    @MainActor
    func publishFromModel() {
        let model = AppModel.shared
        let snapshot = model.snapshot
        let alerts = model.alerts
        let preferences = model.prefs
        lock.withLock {
            currentSnapshot = snapshot
            currentAlerts = AlertsSnapshot(source: .live, alerts: alerts)
            currentPreferences = preferences
        }
    }

    /// Republishes the history reader, once the app's store is known.
    @MainActor
    func publishHistory(_ history: @escaping @Sendable () -> any HistoryReading) {
        lock.withLock { currentHistory = history }
    }

    // MARK: Reading (any thread)

    /// The app's latest published reading, or the one refusal both providers use.
    ///
    /// `.empty` is what the app holds before its first sweep, and an empty reading is
    /// not a reading: it would be a claim about the machine that nobody took. So
    /// absence arrives as a throw, in `OnDemandProvider`'s own words — the constant
    /// rather than the string, so this cannot drift from the on-demand path.
    func snapshot() throws -> ObservationSnapshot {
        let snapshot = lock.withLock { currentSnapshot }
        guard snapshot.at != .distantPast else {
            throw MCPToolError.samplerNotReady
        }
        return snapshot
    }

    func alerts() -> AlertsSnapshot { lock.withLock { currentAlerts } }

    /// The app's preferences as `get_settings` reports them.
    ///
    /// **The mutation mode is read from the policy file on every call, not from the
    /// mirror.** A client that just changed it through `set_preference` must see its
    /// own change in the very next `get_settings`, and the mirror is only refreshed
    /// when the app publishes something or Settings opens — so mirroring the mode
    /// would let the server report a policy the file no longer holds. The read is one
    /// small JSON file, on a tool call a client has already asked for.
    func settingsSnapshot() -> SettingsSnapshot {
        Self.settings(from: lock.withLock { currentPreferences }, mode: loadMode())
    }

    /// The app's history, opened on the first history question and kept.
    ///
    /// The factory runs under the lock, which is safe because this one only hands back
    /// a reader the controller already built — not a store to open. `LazyHistory` on
    /// the provider's side is what actually makes "opened once" true.
    func history() -> any HistoryReading { lock.withLock { currentHistory() } }

    // MARK: Mutations (hop to the app)

    /// Applies one allowlisted preference, through the app.
    ///
    /// `PreferencesStore.apply` is the on-demand path's own mapping — the same
    /// enums, the same refusals, the same case-insensitive reading of a value — so a
    /// client that can reach either provider cannot have a value applied by one and
    /// refused by the other. `LiveDataProvider` has already validated the key and
    /// value through `validate`, so this cannot fail on either; it is called anyway
    /// rather than assumed, because "the check happened elsewhere" is not a reason to
    /// drop the check that protects the user's preferences.
    ///
    /// Assigned back to `prefs` rather than mutated in place, so `didSet` saves the
    /// blob exactly as the Settings screen does.
    ///
    /// The one place this type blocks, and the reason is the provider's signature
    /// rather than a choice: `applyPreference` is synchronous, so a main-actor write
    /// has to be waited on rather than awaited. It cannot deadlock — the main thread
    /// never waits for an MCP call, and this only runs once the gate has approved the
    /// mutation — and `assumeIsolated` states the invariant the hop depends on rather
    /// than hiding it.
    func applyPreference(key: String, value: String) throws {
        @MainActor
        func write() throws {
            let model = AppModel.shared
            var preferences = model.prefs
            try PreferencesStore.apply(key: key, value: value, to: &preferences)
            model.prefs = preferences
        }
        if Thread.isMainThread {
            return try MainActor.assumeIsolated { try write() }
        }
        return try DispatchQueue.main.sync { try MainActor.assumeIsolated { try write() } }
    }

    /// Quits an app's processes, as the app would.
    ///
    /// Membership comes from the app's own published reading through the app's own
    /// `stopTarget`, so the list the coordinator signals is the one a person would
    /// see in the same stop from the UI — and the coordinator re-verifies each pid's
    /// identity immediately before signalling it.
    func stopApp(id: String, force: Bool) async throws -> StopReport {
        try await Self.refusePreviewData()
        let snapshot = try snapshot()
        guard let rollup = snapshot.rollups.first(where: { $0.id == id }) else {
            throw OnDemandProvider.appNotFound(id)
        }
        // `project: nil` for the same reason the menu's own app stop passes nil: an
        // app's processes are not a project, and naming one here would put the wrong
        // label in `StopTarget`.
        let target = await AppModel.shared.stopTarget(
            name: rollup.displayName,
            project: nil,
            members: ConfirmedStopPlan.ordered(rollup.processes)
        )
        guard !target.members.isEmpty else {
            throw OnDemandProvider.noRunningProcessesMessage(for: rollup.displayName)
        }
        return await Self.stop(target.members, force: force)
    }

    /// Stops a project's processes, through the app's own project target.
    func stopProject(id: String) async throws -> StopReport {
        try await Self.refusePreviewData()
        let target = await AppModel.shared.projectStopTarget(id)
        guard !target.members.isEmpty else {
            throw OnDemandProvider.noRunningProcessesMessage(forProject: id)
        }
        return await Self.stop(target.members, force: false)
    }

    /// Stops a container through the docker CLI.
    ///
    /// The same `DockerContainerStop` the on-demand path runs, so the argv, the
    /// refusals and the wording are one implementation. Only the "not known yet"
    /// refusal is this path's own, because only this path knows whether the app's
    /// docker pass has landed.
    func stopContainer(id: String) async throws -> StopReport {
        try await Self.refusePreviewData()
        let snapshot = try snapshot()
        guard let docker = snapshot.docker else {
            throw MCPToolError(message: OnDemandProvider.dockerNotKnownMessage)
        }
        return try await DockerContainerStop.stop(container: id, in: docker)
    }

    /// Signals confirmed targets and reports what happened to each pid.
    ///
    /// Keyed by pid as a string, the way `StopReport` carries them on the wire — the
    /// same mapping the on-demand path makes, so a stop reads identically whichever
    /// provider performed it.
    private static func stop(_ members: [ConfirmedProcess], force: Bool) async -> StopReport {
        let coordinator = await AppModel.shared.stopCoordinator
        let outcomes = await coordinator.stopConfirmed(members, force: force)
        return StopReport(results: Dictionary(uniqueKeysWithValues: outcomes.map { outcome in
            (String(outcome.key), StopReport.value(for: outcome.value.status))
        }))
    }

    /// Refuses a mutation while Portmaster is showing preview data.
    ///
    /// The app's own stop controls are disabled in preview mode for the same reason:
    /// an id in a sample reading is not a process, and the one thing
    /// `StopCoordinator` re-checks is whether a pid is the process it was — not
    /// whether it was ever the app an AI client asked about. The MCP path does not go
    /// through those controls, so it has to carry the rule itself.
    ///
    /// Preferences are not covered: `PreferencesStore.apply` writes the user's real
    /// preferences whatever the sampler is showing.
    private static func refusePreviewData() async throws {
        guard await AppModel.shared.prefs.fixtureMode else { return }
        throw MCPToolError(message: previewDataStopRefusal)
    }

    /// Said when a stop is asked for while Portmaster is showing preview data.
    static let previewDataStopRefusal =
        "Portmaster is showing preview data, so nothing was stopped. "
        + "Turn preview data off in Settings to let AI clients stop processes."


    // MARK: Settings

    /// The app's preferences as `get_settings` reports them.
    ///
    /// Six fields from `AppPreferences`, one from `MCPSettings` — and the split is
    /// the point: `mutationMode` is the MCP server's own policy, not something the
    /// app's preferences blob can hold, so it is read from the file the executor
    /// enforces it from rather than from memory that could disagree with it.
    private static func settings(
        from preferences: AppPreferences, mode: MCPMutationMode
    ) -> SettingsSnapshot {
        SettingsSnapshot(
            temperatureUnit: preferences.presentation.temperatureUnit.rawValue,
            networkUnit: preferences.presentation.networkUnit.rawValue,
            cpuScale: preferences.presentation.cpuScale.rawValue,
            temperatureSource: preferences.presentation.temperatureSource.rawValue,
            compactMenuBar: preferences.presentation.compact,
            mutationMode: mode.rawValue,
            alertsEnabled: preferences.alertsEnabled,
            retention: preferences.retention.rawValue
        )
    }

    /// A value to hold before the app has published anything. Never reported: the
    /// controller mirrors before it starts serving, and the mode is read per call.
    private static let placeholderPreferences = AppPreferences()
}
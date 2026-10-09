// AppModel: owns the sampling engine, history store, stop coordinator, and
// preferences. Single wiring point between the UI and PortmasterCore.
import Foundation
import SwiftUI
import Combine
import PortmasterCore
import ServiceManagement
import os

@MainActor
final class AppModel: ObservableObject {
    /// Single shared instance: menu bar, settings, and the AppKit-hosted
    /// main window all observe the same object.
    static let shared = AppModel()
    // MARK: - Subsystems

    @Published private(set) var engine: SamplingEngine
    let stopCoordinator: StopCoordinator
    let audioControls = AudioControls()
    var historyStore: HistoryStore?
    private(set) var historyReader: HistoryReader?
    @Published private(set) var historyError: String?
    /// Agent sessions and their token usage, opened once and owned here for the app's
    /// whole life — the same shape and the same reason as `historyStore` above.
    ///
    /// **Owned rather than opened per call**, and that is not tidiness: the MCP tool
    /// surface builds a fresh `ToolExecutor` for every call by design (so the
    /// permission gate re-reads the policy each time), so a store opened there would
    /// be a store per call — many `ModelContext`s over one file, each with a lock that
    /// only excludes the others inside this process.
    ///
    /// `nil` is a real state, not a failure to construct: the app then serves every
    /// other tool normally and `report_usage` refuses with a reason. Opening a
    /// database is allowed to fail, and pretending otherwise would mean an MCP client
    /// reporting tokens into a store nobody can read.
    var agentSessionStore: AgentSessionStore?
    /// The slow lane that reads agent logs, owned here for the same reason the store is.
    ///
    /// **Built in the same `do` that opens the store and nowhere else**, so the two
    /// cannot disagree: a store that would not open takes no poller with it, and the
    /// failure stays the one failure it already was rather than becoming two problems to
    /// read about. Built once — `init` runs before any surface appears, and neither a
    /// refresh nor a store refresh may reach here — and unconditional, like the MCP host
    /// it sits beside: a pass reads another application's own log and writes nothing but
    /// figures about sessions that connected to us, so there is no consent to ask for and
    /// nothing for a setting to turn off.
    ///
    /// `nil` is therefore only ever the store's nil. Not a second failure state.
    ///
    /// Its pass callback reports to `AppModel.shared` rather than to the instance that
    /// built it, deliberately: `preview: true` is never constructed, so `shared` is the
    /// owner, and capturing `self` strongly would close a cycle — model, poller,
    /// closure, model. A second instance would build a poller whose callback still
    /// reported to `shared`.
    private(set) var agentSourcePoller: AgentSourcePoller?
    /// Prices set in Settings, refreshed after each edit rather than observed.
    ///
    /// A `@Published` pair rather than one value because the Settings page shows two
    /// lists and either changing should redraw both — a model that just gained an
    /// input price moves from "needs a price" to "priced", and the row it leaves
    /// behind has to disappear with it.
    @Published private(set) var pricedModels: [String: AgentSessionStore.ModelPrice] = [:]
    @Published private(set) var modelsMissingAPrice: [String] = []

    /// Sessions for the Agent Sessions card.
    ///
    /// Refreshed on the card's slow lane rather than per tick: a session's cost
    /// changes only when an agent reports, and re-reading the store several times a
    /// second would spend work to redraw a number that is almost always identical.
    @Published private(set) var agentSessions: [AgentSessionSnapshot] = []

    /// Re-reads the sessions for the Overview card.
    func refreshAgentSessions() {
        guard let store = agentSessionStore else {
            agentSessions = []
            return
        }
        agentSessions = (try? store.sessions()) ?? []
    }

    /// One pass has finished, on the main queue.
    ///
    /// Logged every time and acted on only sometimes. "Did this lane ever run?" has
    /// otherwise no answer anywhere — a feature that produces nothing looks exactly like a
    /// feature that was never wired — and the pass that changed nothing is the one that
    /// says it is alive. A pass that wrote or took back a figure is `notice`, because that
    /// one moved a number the user can see; a pass that found the same totals again is
    /// `debug`, because a line every thirty seconds is not news.
    ///
    /// **Only a pass that changed something republishes.** Re-reading the store for a
    /// pass that wrote nothing would spend a read and a redraw every interval on a number
    /// that did not move — the same work `surfaceAppeared` deliberately does once rather
    /// than per tick.
    ///
    /// Failures are not logged here: the poller already reports each one it survives with
    /// its own `NSLog`, and a second line saying it again would be two lines in the log
    /// where one is a fact.
    func agentSourcePassCompleted(_ pass: AgentSourcePass) {
        let summary = "sessions=\(pass.sessionsConsidered) sources=\(pass.sourcesQueried) "
            + "wrote=\(pass.records.count) withdrew=\(pass.withdrawals.count) "
            + "absent=\(pass.absences.count)"
        if pass.records.isEmpty && pass.withdrawals.isEmpty {
            Self.agentSourceLog.debug("\(summary, privacy: .public)")
        } else {
            Self.agentSourceLog.notice("\(summary, privacy: .public)")
        }
        guard !pass.records.isEmpty || !pass.withdrawals.isEmpty else { return }
        refreshAgentSessions()
    }

    /// On the subsystem `MCPHostController` logs under, so one
    /// `log show --predicate` finds the app's own diagnostics rather than two commands.
    private static let agentSourceLog = Logger(
        subsystem: "app.portmaster", category: "agent-sources"
    )

    /// Re-reads both price lists from the store. Called when the Prices page appears
    /// and after every save, so what is on screen is what is on disk rather than a
    /// copy that can drift from it.
    func refreshPrices() {
        guard let store = agentSessionStore else {
            pricedModels = [:]
            modelsMissingAPrice = []
            return
        }
        pricedModels = Dictionary(
            uniqueKeysWithValues: (try? store.prices())?
                .map { ($0.modelID, $0) } ?? []
        )
        modelsMissingAPrice = (try? store.modelsMissingAPrice()) ?? []
    }
    /// Published and surfaced like `historyError` above, because a store that could not
    /// be opened is otherwise invisible: `report_usage` refuses forever with a generic
    /// reason and nothing anywhere says why, which reads as a broken tool rather than an
    /// unreadable database.
    @Published private(set) var agentSessionError: String?
    /// Kept for the detail sheet's on-demand lookups (path/args/cwd).
    private(set) var processCollectorRef: ProcessCollector?

    // MARK: - Preferences

    @Published var prefs: AppPreferences {
        didSet { prefs.save() }
    }

    /// Snapshot from the engine, mirrored for cheap view access.
    @Published private(set) var snapshot: ObservationSnapshot = .empty
    /// Recent "acting up" alerts (newest first), capped for the UI.
    @Published private(set) var alerts: [ActingUpAlert] = []
    /// In-memory sparkline histories for the Overview cards and popover.
    /// Not persisted — rebuilt live as sampling proceeds.
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memHistoryGB: [Double] = []
    @Published private(set) var netDownHistoryKB: [Double] = []
    @Published private(set) var dockerHistory = DockerHistory()
    @Published var selectedMenuApp: AppRollup?
    @Published var menuStopTarget: StopTarget?
    private let alertEngine = AlertEngine()
    private var cancellables = Set<AnyCancellable>()
    /// Keeps timers alive when macOS would otherwise App Nap us.
    private var napToken: NSObjectProtocol?
    /// Visible-surface refcount: popover and window each register.
    private var surfaceCount = 0

    // MARK: - Init

    init(preview: Bool = false) {
        var loaded = AppPreferences.load()
        if preview { loaded.fixtureMode = true }
        prefs = loaded

        let attributor = ProjectAttributor()
        let collector: ProcessCollector
        let engine: SamplingEngine
        if loaded.fixtureMode {
            collector = FixtureProcessCollector()
        } else {
            collector = LibprocProcessCollector()
        }
        processCollectorRef = collector  // preview details come from fixtures too
        if loaded.fixtureMode {
            engine = SamplingEngine(
                systemCollector: FixtureSystemCollector(),
                processCollector: collector,
                portCollector: FixturePortCollector(),
                attributor: attributor,
                cadence: loaded.cadence,
                nettopCollector: FixtureNettopProvider(),
                assertionCollector: FixtureAssertionProvider(),
                dockerCollector: FixtureDockerProvider(),
                thermalCollector: FixtureThermalProvider(),
                audioCollector: FixtureAudioProvider(), bluetoothCollector: FixtureBluetoothProvider()
            )
        } else {
            engine = SamplingEngine(
                systemCollector: MachSystemCollector(),
                processCollector: collector,
                portCollector: LsofPortScanner(),
                attributor: attributor,
                cadence: loaded.cadence
            )
        }
        self.engine = engine
        self.stopCoordinator = StopCoordinator(controller: KillProcessController())

        do {
            historyStore = try HistoryStore()
            historyReader = historyStore?.makeReader()
        } catch {
            historyError = (error as? HistoryStore.StoreError)?.errorDescription
                ?? error.localizedDescription
        }

        // Separate from the history store, and separate in the `catch` too: two files
        // that fail independently must not take each other down, or one unreadable
        // database would look like both were gone.
        //
        // The poller is built from the store this `do` produced rather than beside it, so
        // a poller exists exactly when the store opened — see `agentSourcePoller`.
        do {
            let store = try AgentSessionStore()
            agentSessionStore = store
            agentSourcePoller = AgentSourcePoller(store: store) { pass in
                Task { @MainActor in AppModel.shared.agentSourcePassCompleted(pass) }
            }
        } catch {
            agentSessionError = (error as? AgentSessionStore.StoreError)?.errorDescription
                ?? error.localizedDescription
        }

        engine.$latest
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                guard let self else { return }
                self.snapshot = snap
                self.audioControls.reconcile(snap.audio, rollups: snap.rollups)
                if let docker = snap.docker { self.dockerHistory.append(docker) }
                self.appendSparklineHistory(snap)
                self.record(snap)
            }
            .store(in: &cancellables)

        // Posted by the AppDelegate on app-activation notifications; unpauses
        // sampling after the idle pause (SamplingEngine.noteUserActivity).
        NotificationCenter.default.publisher(for: .portmasterUserActivity)
            .sink { [weak self] _ in self?.engine.noteUserActivity() }
            .store(in: &cancellables)

        // Start sampling from app lifecycle, not window appearance: the
        // background cadence keeps history recording even when no surface
        // is open. Visible windows raise the cadence via setSurfaceVisible.
        Task { @MainActor [weak self] in
            self?.start()
        }
    }

    // MARK: - Lifecycle

    /// Visible surfaces (popover, main window) register here so the engine
    /// samples at the live cadence while anything is on screen.
    func surfaceAppeared() {
        surfaceCount += 1
        engine.setSurfaceVisible(true)
        // Once when a surface appears, not per tick: a session's cost changes only
        // when an agent reports, so re-reading the store on the sampling cadence
        // would spend work redrawing a number that is almost always identical. The
        // card is correct on arrival and correct when the window opens, and an agent
        // that reports while the window is closed has its figure waiting there.
        refreshAgentSessions()
        // Asks for a pass rather than making one, and under the pass interval the timer
        // already obeys — so a window that opens and closes five times cannot become five
        // walks of somebody else's log directory, and a request inside the last interval
        // is dropped rather than stacked. What it buys is narrower than "no wait": in the
        // ordinary case the gate drops the request and the timer's own next tick is what
        // moves the card anyway, so this helps only when a tick was missed or a pass
        // overran and the schedule has fallen behind. What it deliberately does not do is
        // run a pass here, because `pollOnce` would parse a conversation's worth of log on
        // the main thread.
        agentSourcePoller?.requestPoll()
    }

    func surfaceDisappeared() {
        surfaceCount = max(0, surfaceCount - 1)
        engine.setSurfaceVisible(surfaceCount > 0)
    }

    func start() {
        engine.start()
        engine.setSurfaceVisible(false)
        // Started here rather than where it is built, for the reason the MCP host has its
        // own `start()`: construction is not running anything, and this is where the app
        // says it has begun. `start()` is called from every surface that appears and from
        // intents, so this line runs more than once per launch — the poller's own timer
        // guard drops all but the first, which is the same answer `MCPHostController.start`
        // gives its callers.
        agentSourcePoller?.start()
        // Dock visibility is a launch-time policy: a menu-bar-only accessory
        // app shows no Dock icon until it activates as a regular app.
        NSApp.setActivationPolicy(prefs.showInDock ? .regular : .accessory)
        // A menu-bar observer must keep sampling when hidden; without this
        // token macOS App Naps the process and timers stop firing.
        if napToken == nil {
            napToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Portmaster samples system metrics"
            )
        }
        pruneHistory()
        refreshAgentSessions()
    }

    /// Stops the poller on the way out.
    ///
    /// **Synchronous on purpose, and that is what decides where it is called from.**
    /// `MCPHostServer.stop` has to be awaited — it closes its admitted connections, waits
    /// for the accept thread, and only then unlinks — which is the whole reason the quit
    /// path has an `applicationShouldTerminate` that answers `.terminateLater` and the
    /// comment above it says so. This cannot be: it enqueues a cancel on the poller's own
    /// queue and returns. Calling it from there instead would put a second thing on a path
    /// whose `.terminateNow` answer — every quit with no host bound — would skip, and a
    /// poller that kept polling into a half-quit process is a worse thing than the
    /// cancellation being best-effort.
    ///
    /// Best-effort is the honest word: a pass already running is not interrupted and not
    /// waited for, so a pass that had written but not yet flushed at quit ends where the
    /// process ends. What stopping does buy is that the timer stops ticking — no further
    /// *scheduled* pass starts — and even that has a margin: a `requestPoll()` already
    /// enqueued on the poller's queue still runs its pass, because `stop()` cancels the
    /// timer and does not drain the queue. Stopping is not terminal either: a later
    /// `start()` begins the poller again, the way `MCPHostController` can be restarted
    /// once a stop has dropped its host.
    func stopAgentSources() {
        agentSourcePoller?.stop()
    }

    // MARK: - History recording

    private var lastHistoryAt: Date?
    private var lastPrune: Date = .distantPast

    private func record(_ snap: ObservationSnapshot) {
        // Preview data is labeled, isolated, and never persisted or alerted on:
        // synthetic snapshots must not mix into local history or acting-up
        // detection (review finding #8).
        guard !prefs.fixtureMode else { lastHistoryAt = nil; return }
        guard snap.at != .distantPast, let store = historyStore else { return }

        // Acting-up detection: plain-language alerts about apps (CPU-sustained,
        // memory-growth). Notification permission is requested only when the
        // user enables alerts in Settings — not at launch.
        if prefs.alertsEnabled {
            let fired = alertEngine.ingest(rollups: snap.rollups, at: snap.at, notify: true)
            if !fired.isEmpty {
                alerts.insert(contentsOf: fired, at: 0)
                if alerts.count > 100 { alerts.removeLast(alerts.count - 100) }
            }
        }
        let interval = lastHistoryAt.map { snap.at.timeIntervalSince($0) } ?? 0
        lastHistoryAt = snap.at
        store.recordExtended(system: snap.system, apps: snap.rollups, interval: interval)
        store.recordSystem(cpu: snap.system.cpu, memory: snap.system.memory, at: snap.at)
        let servicePids = Set(snap.services.map(\.process.pid))
        store.recordProcessPoints(snap.processes, at: snap.at, servicePids: servicePids)
        store.recordPortEvents(
            current: snap.ports,
            previous: lastPorts,
            projectFor: { pid in snap.processes.first { $0.pid == pid }?.projectID }
        )
        lastPorts = snap.ports

        if Date().timeIntervalSince(lastPrune) > 600 {
            pruneHistory()
        }
    }

    private var lastPorts: [ListeningPort] = []

    private func appendSparklineHistory(_ snap: ObservationSnapshot) {
        guard snap.at != .distantPast else { return }
        func push(_ array: inout [Double], _ value: Double) {
            array.append(value)
            if array.count > 40 { array.removeFirst(array.count - 40) }
        }
        push(&cpuHistory, snap.system.cpu.totalPercent)
        if snap.system.memory.totalBytes > 0 {
            push(&memHistoryGB, Double(snap.system.memory.usedBytes) / 1_073_741_824)
        }
        if let net = snap.system.network {
            push(&netDownHistoryKB, net.downBytesPerSec / 1024)
        }
        if let gpu = snap.system.gpu, let util = gpu.utilizationPercent {
            push(&gpuHistory, util)
        }
    }

    /// GPU utilization history for the GPU tab sparkline.
    @Published var gpuHistory: [Double] = []

    private func pruneHistory() {
        // Before the history guard, deliberately. Two databases fail independently, and
        // bounding the agent table must not depend on the other one opening — that is
        // the path B1 was raised about, and it was unreachable whenever the history
        // file was unreadable.
        pruneAgentSessions()
        guard let store = historyStore else { return }
        store.prune(olderThan: Date().addingTimeInterval(-prefs.retention.seconds))
        lastPrune = Date()
    }

    /// Sweeps agent sessions on **their own** retention, not the sample picker's.
    ///
    /// Absent or unreadable retention keeps everything. Falling back to the 30-day floor
    /// would delete spend on a schedule the user never chose, which is the same defect
    /// as an agent that reported nothing being shown as one that reported zero.
    func pruneAgentSessions() {
        guard let store = agentSessionStore,
              let seconds = prefs.agentSessionRetention?.seconds
        else { return }
        store.prune(
            olderThan: Date().addingTimeInterval(-seconds),
            keepingSessionIDs: liveSessionIDs()
        )
    }

    /// The session ids the MCP host is serving right now, for the sweep above.
    ///
    /// Injected rather than reached for: the host is owned by `AppDelegate` and this is
    /// its own singleton, so the seam has to be filled deliberately by whoever owns
    /// both. **Empty means nothing is connected**, which is why the default is empty
    /// rather than absent — this process is the only writer of that store, so while the
    /// host is not serving there is no connection left that could report again, and an
    /// empty set is the true answer rather than a guess.
    var liveSessionIDs: @MainActor () -> Set<UUID> = { [] }

    /// Clears both databases, because the button says all of it.
    ///
    /// Agent sessions are a second file, and leaving them behind would mean a button
    /// labelled "Clear All History" reports success while peer pids, client identity,
    /// model ids and token counts stay on disk — data on a category the user was never
    /// told was kept. The two clears are reported separately so neither failure can be
    /// hidden behind the other's success.
    func clearHistory() {
        clearHistoryError = nil
        historyActionStatus = nil
        guard let store = historyStore else {
            clearHistoryError = "No history database is open."
            return
        }
        do {
            try store.clearAll()
        } catch {
            clearHistoryError = "Clear failed: \(error.localizedDescription). Stored history is unchanged."
            return
        }
        do {
            // Nil store means nothing was ever written, so there is nothing to clear
            // and the message below is still true of it.
            try agentSessionStore?.clearAll()
        } catch {
            clearHistoryError = "System history is cleared, but agent sessions were not: "
                + "\(error.localizedDescription). Stored session records are unchanged."
            return
        }
        historyActionStatus = "History cleared. New readings, and any new agent sessions, "
            + "will be recorded while Portmaster runs."
    }

    /// Surfaced in Settings when clear/retention writes fail.
    @Published var clearHistoryError: String?
    @Published private(set) var historyActionStatus: String?

    func pruneNow() {
        pruneHistory()
    }

    /// Collector used by the process detail sheet (path/args/cwd lookups).
    var processCollector: ProcessCollector? {
        processCollectorRef
    }

    var historyRowCounts: (cpu: Int, mem: Int, process: Int, port: Int) {
        historyStore?.rowCounts() ?? (0, 0, 0, 0)
    }

    // MARK: - Derived values

    var menuBarText: String { statusText(prefs.menuBarMetric) }

    /// Warning state for the menu bar: the value crosses its alert
    /// threshold (CPU ≥ 50%, pressure above normal, top process ≥ 50%).
    /// Matches the reference's ⚠-prefixed menu-bar value.
    var menuBarWarn: Bool { statusWarning(prefs.menuBarMetric) }

    /// Busiest processes, apps first, capped for the popover.
    func topProcesses(_ limit: Int = 6) -> [ProcessRow] {
        snapshot.processes
            .filter { ($0.cpuPercent ?? 0) > 0.1 || ($0.memoryBytes ?? 0) > 100_000_000 }
            .sorted { ($0.cpuPercent ?? 0) > ($1.cpuPercent ?? 0) }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Preferences application

    func applyCadence() {
        engine.setCadence(prefs.cadence)
    }

    /// Immediate effect when the Show-in-Dock toggle changes in Settings.
    func applyDockPolicy() {
        NSApp.setActivationPolicy(prefs.showInDock ? .regular : .accessory)
    }

    /// Called from Settings when alerts are enabled: asks once, on demand.
    @Published var notificationStatus = "In-app alerts work without notification permission."
    func enableAlertsRequested() async {
        guard prefs.alertsEnabled else { return }
        let granted = await AlertEngine.requestAuthorizationIfNeeded()
        notificationStatus = granted ? "Notification Center delivery is authorized." : "Notification Center delivery is unavailable. Check Portmaster in System Settings → Notifications."
    }

    /// Rebuilds the engine when fixture mode toggles. Preview data is never
    /// the default; the change only takes effect from Settings.
    func rebuildEngineForFixtureMode() {
        audioControls.stopAll()
        let cadence = prefs.cadence
        let attributor = ProjectAttributor()
        let newEngine: SamplingEngine
        let newCollector: ProcessCollector
        if prefs.fixtureMode {
            newCollector = FixtureProcessCollector()
            newEngine = SamplingEngine(
                systemCollector: FixtureSystemCollector(),
                processCollector: newCollector,
                portCollector: FixturePortCollector(),
                attributor: attributor,
                cadence: cadence,
                nettopCollector: FixtureNettopProvider(),
                assertionCollector: FixtureAssertionProvider(),
                dockerCollector: FixtureDockerProvider(),
                thermalCollector: FixtureThermalProvider(),
                audioCollector: FixtureAudioProvider(), bluetoothCollector: FixtureBluetoothProvider()
            )
        } else {
            newCollector = LibprocProcessCollector()
            newEngine = SamplingEngine(
                systemCollector: MachSystemCollector(),
                processCollector: newCollector,
                portCollector: LsofPortScanner(),
                attributor: attributor,
                cadence: cadence
            )
        }
        // Detail lookups (path/args/cwd) must match the data source,
        // otherwise preview pids get live lookups (review finding #8).
        dockerHistory = DockerHistory()
        processCollectorRef = newCollector
        newEngine.start()
        engine.stop()
        engine = newEngine
        engine.$latest
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in
                guard let self else { return }
                self.snapshot = snap
                self.audioControls.reconcile(snap.audio, rollups: snap.rollups)
                if let docker = snap.docker { self.dockerHistory.append(docker) }
                self.appendSparklineHistory(snap)
                self.record(snap)
            }
            .store(in: &cancellables)
        engine.setSurfaceVisible(true)
    }

    // MARK: - Login item (SMAppService)

    var loginItemStatus: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Awaiting approval in System Settings"
        case .notRegistered: return "Not registered"
        case .notFound: return "Unavailable"
        @unknown default: return "Unknown"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Keep toggle honest: reflect actual system state on failure.
            prefs.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Stop actions

    func openApp(_ app: AppRollup, quit: Bool = false) {
        // Capture the fresh rollup before opening a closed window; the sheets
        // continue resolving live readings by app identity.
        guard !quit || !prefs.fixtureMode else { return }
        guard let current = snapshot.rollups.first(where: { $0.id == app.id }) else { return }
        if quit {
            menuStopTarget = stopTarget(name: current.displayName, project: nil,
                members: ConfirmedStopPlan.ordered(current.processes))
        } else { selectedMenuApp = current }
        AppDelegate.shared?.openMainWindow()
    }

    func processStopTarget(_ row: ProcessRow) -> StopTarget {
        stopTarget(name: row.displayName, project: row.projectID,
            members: ConfirmedStopPlan.process(row.pid, rows: snapshot.processes))
    }

    func projectStopTarget(_ id: String) -> StopTarget {
        stopTarget(name: id.components(separatedBy: "/").last ?? id, project: id,
            members: ConfirmedStopPlan.project(id, rows: snapshot.processes), isProject: true)
    }

    func stopTarget(name: String, project: String?, members: [ConfirmedProcess], isProject: Bool = false) -> StopTarget {
        let pids = Set(members.map(\.pid))
        return StopTarget(name: name, project: project, ports: snapshot.ports.filter { pids.contains($0.pid) }, members: members, isProject: isProject)
    }

    struct StopTarget: Identifiable {
        let id = UUID()
        let name: String
        let project: String?
        let ports: [ListeningPort]
        let members: [ConfirmedProcess]
        let isProject: Bool
    }
}

// AppModel: owns the sampling engine, history store, stop coordinator, and
// preferences. Single wiring point between the UI and PortmasterCore.
import Foundation
import SwiftUI
import Combine
import PortmasterCore
import ServiceManagement

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
    }

    func surfaceDisappeared() {
        surfaceCount = max(0, surfaceCount - 1)
        engine.setSurfaceVisible(surfaceCount > 0)
    }

    func start() {
        engine.start()
        engine.setSurfaceVisible(false)
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
        guard let store = historyStore else { return }
        store.prune(olderThan: Date().addingTimeInterval(-prefs.retention.seconds))
        lastPrune = Date()
    }

    func clearHistory() {
        clearHistoryError = nil
        historyActionStatus = nil
        guard let store = historyStore else {
            clearHistoryError = "No history database is open."
            return
        }
        do {
            try store.clearAll()
            historyActionStatus = "History cleared. New readings will be recorded while Portmaster runs."
        } catch {
            clearHistoryError = "Clear failed: \(error.localizedDescription). Stored history is unchanged."
        }
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

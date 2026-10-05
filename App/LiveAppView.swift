// LiveAppView: the app's published state, as the MCP tool path reads it.
//
// A separate file from `MCPHostController` because it is a different job: the
// controller decides *when* the host runs, and this type is *what* the tools answer
// with. It also keeps the eight provider closures together with the three rules they
// obey, rather than interleaved with socket lifecycle.

import Foundation
import PortmasterCore
import PortmasterMCP

/// The app's published state, for the MCP tool path, plus the mutations that only the
/// app may perform.
///
/// Every read **publishes from the app first and then reads a lock-protected copy**, so
/// a tool call answers with what Portmaster holds at the moment it was asked and never
/// with a copy that some scheduler may not have refreshed. The copy is what makes that
/// safe to do on every read: the main-actor hop happens outside the lock, so concurrent
/// calls do not queue behind each other while holding it, and all three values are read
/// together rather than one hop each.
///
/// That replaced a `Combine` subscription on the app's `objectWillChange`. Being fair
/// about what that cost: it was coalesced and skipped while no client was connected, so
/// it was not the per-tick work it looked like. What it could not do was be *correct* —
/// nothing observed a client connecting, so a preference the user changed while nobody
/// was connected was missing from that session's first `get_settings`, and the snapshot
/// path needed a freshness bound and a hop to cover for it. Publishing on read has no
/// schedule to keep, no gap to fall into, and no flag that has to be right.
final class LiveAppView: @unchecked Sendable {

    /// The copy. One lock for all three values, so a reader cannot see a snapshot from
    /// one instant and preferences from another.
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

    // MARK: Publishing (main actor)

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

    // MARK: Reading (publishes first, then answers off the main actor)

    /// The app's newest reading, woken into existence if it had gone quiet.
    ///
    /// Three steps, and each earns its place:
    ///
    /// 1. **Publish from the app**, so the answer is what Portmaster holds now. A copy
    ///    kept by a scheduler would be a step behind by construction, and how far
    ///    behind depends on whether that scheduler ran.
    /// 2. **Ask the app whether that reading is fresh enough** — `LiveDataProvider`'s
    ///    rule, not this file's, so both providers judge a reading the same way.
    /// 3. **If it is not, wake the sampler and wait once.** `SamplingEngine` pauses
    ///    itself after five idle minutes, which is the normal state of a menu-bar app
    ///    nobody is looking at; a refusal there would break every snapshot-backed tool
    ///    on a healthy app. One nudge, one bounded wait, and then the same freshness
    ///    rule decides — so a sampler that does not answer is refused for being idle
    ///    whether or not the host tried.
    func snapshot() async throws -> ObservationSnapshot {
        await MainActor.run { publishFromModel() }
        if let readable = try? LiveDataProvider.requireReadable(lock.withLock { currentSnapshot }) {
            return readable
        }
        let woken = await LiveDataProvider.wake(
            replacing: lock.withLock { currentSnapshot },
            // Both hops are main-actor reads of the app: the nudge is the engine's own
            // API, and the reading is `AppModel`'s published copy.
            //
            // `resumeOnce()`, **not** `noteUserActivity()`. A tool call is not a person
            // at the keyboard, and stamping activity here would let an assistant polling
            // every few minutes hold this menu-bar app sampling on its background
            // cadence forever — the idle pause exists so an app nobody is looking at
            // costs nothing, and this feature must not be what defeats it. `resumeOnce`
            // takes the one sample and leaves the clock where the user left it.
            //
            // It also has to come before the tick it wants, which `resumeOnce` guarantees
            // internally by setting its flag on the sampling queue immediately before the
            // tick it queues; `refreshNow()` alone would be queued behind that tick and
            // would hit the idle guard on a paused engine.
            nudge: {
                await MainActor.run { AppModel.shared.engine.resumeOnce() }
            },
            latest: { await MainActor.run { AppModel.shared.snapshot } }
        )
        // Published before the decision, and the box wins ties on freshness: the tick
        // can land between `wake`'s last poll and this line, and refusing while a fresh
        // reading is in hand is exactly the refusal this path exists to remove.
        await MainActor.run { publishFromModel() }
        let current = lock.withLock { currentSnapshot }
        return try LiveDataProvider.requireReadable(
            current.at > woken.at ? current : woken
        )
    }

    /// The app's current alerts, published fresh and then read.
    func alerts() async -> AlertsSnapshot {
        await MainActor.run { publishFromModel() }
        return lock.withLock { currentAlerts }
    }

    /// The app's preferences as `get_settings` reports them, published fresh and read.
    ///
    /// **The mutation mode is read from the policy file on every call, not from the
    /// copy.** A client that just changed it through `set_preference` must see its own
    /// change in the very next `get_settings`, and the executor enforces that same file
    /// — a copy of the mode could disagree with the policy actually being applied. The
    /// read is one small JSON file, on a tool call the client has already asked for.
    func settingsSnapshot() async -> SettingsSnapshot {
        await MainActor.run { publishFromModel() }
        return Self.settings(from: lock.withLock { currentPreferences }, mode: loadMode())
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
    /// **A suspension, not a block.** `LiveDataProvider.applyPreference` is `async`
    /// precisely so this hop is `await MainActor.run { … }`: the socket thread parks
    /// until the main actor is free and the app's main thread stays free to be free.
    /// The earlier shape — a synchronous seam filled by
    /// `DispatchQueue.main.sync { MainActor.assumeIsolated { … } }` — was correct on
    /// the day it was written and a hard crash the day something on the main actor
    /// waited for a tool call, which Task 8's confirmation window is one line away
    /// from doing. The invariant it depended on is now enforced by the type.
    func applyPreference(key: String, value: String) async throws {
        try await MainActor.run { try Self.writePreference(key: key, value: value) }
    }

    /// The whole main-actor half of a preference write, in one named place.
    @MainActor
    private static func writePreference(key: String, value: String) throws {
        let model = AppModel.shared
        var preferences = model.prefs
        try PreferencesStore.apply(key: key, value: value, to: &preferences)
        model.prefs = preferences
    }

    /// Quits an app's processes, as the app would.
    ///
    /// Membership comes from the app's own published reading through the app's own
    /// `stopTarget`, so the list the coordinator signals is the one a person would
    /// see in the same stop from the UI — and the coordinator re-verifies each pid's
    /// identity immediately before signalling it.
    func stopApp(id: String, force: Bool) async throws -> StopReport {
        try await Self.refusePreviewData()
        let snapshot = try await snapshot()
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
    ///
    /// `projectStopTarget` rather than `OnDemandProvider.projectSummaries(from:)`, which
    /// is what the summaries a client *reads* come from: project membership is a fact
    /// about processes that change every second, and the app's live snapshot is the
    /// authority for which ones are in a project now. Rebuilding it from a copy of the
    /// app's own snapshot would add a second definition that could only ever be staler.
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
        let snapshot = try await snapshot()
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

    /// A value to hold before the app has published anything. Never reported: every read
    /// publishes from the app first, and the mutation mode is read from the file.
    private static let placeholderPreferences = AppPreferences()
}

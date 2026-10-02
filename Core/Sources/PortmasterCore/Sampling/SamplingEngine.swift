// Sampling engine: orchestrates collectors into ObservationSnapshots on a
// conservative cadence. Slows down when no surface is visible and pauses after
// prolonged idleness. Never spins faster for visual smoothness.
import Foundation
import Combine

public final class SamplingEngine: ObservableObject, @unchecked Sendable {
    private let systemCollector: SystemCollector
    private let processCollector: ProcessCollector
    private let portCollector: PortCollector
    private let attributor: ProjectAttributor
    private let networkCollector = NetworkCollector()
    private let diskCollector = DiskCollector()
    /// Per-process network counters (nettop). Slow lane: one 5s pass per
    /// network poll, run on its own queue so ticks never wait on it.
    private let nettopCollector: NettopProviding
    private let nettopQueue = DispatchQueue(label: "dev.portmaster.nettop", qos: .utility)
    private var nettopInFlight = false
    private var priorNettop: [pid_t: (in: UInt64, out: UInt64, name: String)] = [:]
    private var priorNettopAt: Date?
    private var netRates: [pid_t: (in: Double, out: Double)] = [:]
    private var sessionTotals: (in: UInt64, out: UInt64) = (0, 0)
    /// Slow-lane collectors: sleep assertions (pmset), Docker containers
    /// (docker CLI), and read-only SMC sensors. One sequential lane means
    /// subprocess passes never stack up.
    private let assertionCollector: SleepAssertionProviding
    private let dockerCollector: DockerProviding
    private let thermalCollector: ThermalProviding
    private let audioCollector: AudioProviding
    private let bluetoothCollector: BluetoothProviding
    private var latestAudio: AudioSample?
    private var latestBluetooth: BluetoothSample?
    private var lastAudioAt = Date.distantPast
    private var lastBluetoothAt = Date.distantPast
    private let slowQueue = DispatchQueue(label: "dev.portmaster.slowlane", qos: .utility)
    private var slowInFlight = false
    private var lastAssertionAt = Date.distantPast
    private var lastDockerAt = Date.distantPast
    private var lastThermalAt = Date.distantPast
    private var latestThermal: ThermalSample?
    private var latestAssertions: [SleepAssertion] = []
    private var latestDocker: DockerSample?
    private let queue = DispatchQueue(label: "dev.portmaster.sampling", qos: .utility)

    private var timer: DispatchSourceTimer?
    private var priorStarts: [pid_t: Date] = [:]
    private var priorTicks: [pid_t: UInt64] = [:]
    /// Cumulative per-pid disk counters from the previous sweep (proc_pid_rusage).
    private var priorDisk: [pid_t: (read: UInt64, write: UInt64)] = [:]
    private var priorSweepAt: Date?
    private var priorPorts: [ListeningPort] = []
    private var lastNettopAt: Date = .distantPast
    private var lastPortPoll: Date = .distantPast
    private var lastLiveSampleAt: Date?
    private var activityLedger: [pid_t: Date] = [:]

    public private(set) var cadence: SamplingCadence
    /// true while a window or popover is visible (drives the faster cadence).
    public private(set) var isSurfaceVisible: Bool = false
    /// Idle pause: after this much user inactivity, sampling pauses entirely.
    public var idlePauseAfter: TimeInterval = 5 * 60

    @Published public private(set) var latest: ObservationSnapshot = .empty
    @Published public private(set) var isPaused: Bool = false
    /// Set when a collector fails outright so UI can show an honest error.
    @Published public private(set) var collectionError: String?

    /// Clears a stale collection error after a successful scan.
    public func clearCollectionError() {
        collectionError = nil
    }

    public init(
        systemCollector: SystemCollector,
        processCollector: ProcessCollector,
        portCollector: PortCollector,
        attributor: ProjectAttributor = ProjectAttributor(),
        cadence: SamplingCadence = .standard,
        nettopCollector: NettopProviding = NettopNetworkCollector(),
        assertionCollector: SleepAssertionProviding = PmsetAssertionCollector(),
        dockerCollector: DockerProviding = DockerCollector(),
        thermalCollector: ThermalProviding = SMCCollector(),
        audioCollector: AudioProviding = AudioCollector(),
        bluetoothCollector: BluetoothProviding = BluetoothCollector()
    ) {
        self.systemCollector = systemCollector
        self.processCollector = processCollector
        self.portCollector = portCollector
        self.attributor = attributor
        self.cadence = cadence
        self.nettopCollector = nettopCollector
        self.assertionCollector = assertionCollector
        self.dockerCollector = dockerCollector
        self.thermalCollector = thermalCollector
        self.audioCollector = audioCollector; self.bluetoothCollector = bluetoothCollector
    }

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil else { return }
        // First tick runs on the sampling queue, never the main thread: the
        // port scan can take seconds and must not stall app launch.
        queue.async { [weak self] in self?.tick() }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func setCadence(_ c: SamplingCadence) {
        cadence = c
        reschedule()
    }

    public func setSurfaceVisible(_ visible: Bool) {
        guard isSurfaceVisible != visible else { return }
        isSurfaceVisible = visible
        if visible {
            isPaused = false
            lastLiveSampleAt = Date()
        }
        reschedule()
    }

    /// Called by the app on user activity (NSWorkspace notifications upstream);
    /// unpauses sampling after idle pause.
    public func noteUserActivity() {
        if isPaused {
            isPaused = false
            lastLiveSampleAt = Date()
            reschedule()
        }
        lastLiveSampleAt = Date()
    }

    /// Immediate one-off refresh (pull-to-refresh / window open).
    public func refreshNow() {
        queue.async { [weak self] in self?.tick() }
    }

    // MARK: - Internals

    private func reschedule() {
        stop()
        let interval = currentInterval()
        scheduleNext(interval: interval)
    }

    private func currentInterval() -> TimeInterval {
        if isSurfaceVisible { return cadence.liveInterval }
        return cadence.backgroundInterval
    }

    private func scheduleNext(interval: TimeInterval) {
        timer?.cancel() // never leak a second timer chain
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }
    private func tick() {
        // Idle pause: no visible surface + no activity for a while → stop polling.
        if let last = lastLiveSampleAt,
           !isSurfaceVisible,
           Date().timeIntervalSince(last) > idlePauseAfter {
            if !isPaused {
                DispatchQueue.main.async { [weak self] in self?.isPaused = true }
            }
            scheduleNext(interval: 30) // cheap heartbeat to notice activity
            return
        }

        let now = Date()
        var system = SystemSample(at: now, cpu: .unknown, memory: .unknown)

        if let cpu = systemCollector.sampleCPU() {
            system = SystemSample(at: now, cpu: cpu, memory: system.memory)
        }
        if let mem = systemCollector.sampleMemory() {
            system = SystemSample(at: now, cpu: system.cpu, memory: mem)
        }
        // Overview cards: network/disk/battery enrich every tick. Battery is
        // nil on desktops; disk/network values are real or omitted.
        system.network = networkCollector.sample()
        system.disk = diskCollector.sample()
        system.battery = BatteryCollector.sample()
        system.gpu = GPUCollector.sample()
        system.thermal = latestThermal

        // Kick a nettop pass on the slow lane if none is in flight; results
        // land in netRates/sessionTotals for the NEXT tick (honest one-tick
        // lag, never interpolated).
        kickNettopIfNeeded()
        kickSlowCollectorsIfNeeded(now)

        var sweepRows: [ProcessRow] = []
        var projects: [ProjectIdentity] = []
        var workingDirs: [pid_t: String] = [:]

        if let sweep = processCollector.snapshot() {
            // Resolve cwd only for processes that plausibly matter (services and
            // non-system processes), to keep per-tick cost low.
            let interesting = sweep.records.filter { raw in
                raw.parentPid != nil && !Self.looksLikeSystemProcess(raw)
            }
            // Cap raised 200 → 600: review found busy machines leaving later
            // processes unattributed. cwd lookups stay cheap (one syscall each).
            for raw in interesting.prefix(600) {
                if let cwd = processCollector.workingDirectory(pid: raw.pid), !cwd.isEmpty {
                    workingDirs[raw.pid] = cwd
                }
            }

            let enriched = attributor.enrich(
                records: sweep.records,
                workingDirectories: workingDirs
            )
            sweepRows = computeProcessMetrics(rows: enriched.rows, sweepAt: sweep.at)
            projects = enriched.projects

            // Whole-disk Reading/Writing = summed observed per-process rates
            // (rusage is readable for the user's own processes; system daemons
            // running as other users are not observable without privileges —
            // the UI says what the figures cover). nil until two sweeps exist.
            if var d = system.disk {
                let reads = sweepRows.compactMap(\.diskReadBytesPerSec)
                let writes = sweepRows.compactMap(\.diskWriteBytesPerSec)
                d = DiskSample(
                    freeBytes: d.freeBytes, totalBytes: d.totalBytes,
                    readBytesPerSec: reads.isEmpty ? nil : reads.reduce(0, +),
                    writeBytesPerSec: writes.isEmpty ? nil : writes.reduce(0, +)
                )
                system.disk = d
            }
        }

        // Ports are polled on a slower rhythm than processes.
        var ports: [ListeningPort] = priorPorts
        let shouldPollPorts = priorPorts.isEmpty
            || now.timeIntervalSince(lastPortPoll) >= Self.portPollInterval
        if shouldPollPorts {
            if let fresh = portCollector.listeningPorts() {
                ports = fresh
                lastPortPoll = now
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.collectionError = "Port scan failed. Service list may be stale."
                }
            }
        }

        // Clear a stale error when a scan succeeds.
        if shouldPollPorts && collectionError != nil {
            DispatchQueue.main.async { [weak self] in self?.collectionError = nil }
        }

        let services = Self.buildServices(
            ports: ports, rows: sweepRows,
            priorActivity: &activityLedger
        )

        let snapshot = ObservationSnapshot(
            at: now, system: system, processes: sweepRows,
            ports: ports, services: services,
            rollups: AppRollupBuilder.build(from: sweepRows),
            sessionNet: priorNettopAt != nil
                ? (in: sessionTotals.in, out: sessionTotals.out)
                : (in: nil, out: nil),
            sleepAssertions: latestAssertions,
            docker: latestDocker, audio: latestAudio, bluetooth: latestBluetooth
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latest = snapshot
            self.objectWillChange.send()
        }

        scheduleNext(interval: currentInterval())
    }

static let portPollInterval: TimeInterval = 10

    public func refreshPeripherals() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastAudioAt = .distantPast; self.lastBluetoothAt = .distantPast
            self.kickSlowCollectorsIfNeeded(Date())
        }
    }

    public func refreshContainers() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastDockerAt = .distantPast
            self.kickSlowCollectorsIfNeeded(Date())
        }
    }

    /// Slow-lane cadences: pmset answers in tens of milliseconds, docker ps
    /// in a few hundred; docker stats (when containers run) needs longer.
    static let assertionPollInterval: TimeInterval = 30
    static let dockerPollInterval: TimeInterval = 15
    static let thermalPollInterval: TimeInterval = 5

    /// Kick the slow lane when any collector is due. Results
    /// apply on the sampling queue and surface the NEXT tick — same honest
    /// one-tick lag as nettop.
    private func kickSlowCollectorsIfNeeded(_ now: Date) {
        let assertionsDue = now.timeIntervalSince(lastAssertionAt) >= Self.assertionPollInterval
        let dockerDue = now.timeIntervalSince(lastDockerAt) >= Self.dockerPollInterval
        let thermalDue = now.timeIntervalSince(lastThermalAt) >= Self.thermalPollInterval
        let audioDue = now.timeIntervalSince(lastAudioAt) >= 2
        let bluetoothDue = now.timeIntervalSince(lastBluetoothAt) >= 60
        guard assertionsDue || dockerDue || thermalDue || audioDue || bluetoothDue, !slowInFlight else { return }
        slowInFlight = true
        if assertionsDue { lastAssertionAt = now }
        if dockerDue { lastDockerAt = now }
        if thermalDue { lastThermalAt = now }
        if audioDue { lastAudioAt = now }; if bluetoothDue { lastBluetoothAt = now }
        let assertions = assertionsDue ? assertionCollector : nil
        let docker = dockerDue ? dockerCollector : nil
        let thermal = thermalDue ? thermalCollector : nil
        let audio = audioDue ? audioCollector : nil
        let bluetooth = bluetoothDue ? bluetoothCollector : nil
        slowQueue.async { [weak self] in
            let audioResult = audio?.sample()
            let thermalResult = thermal?.sample()
            let bluetoothResult = bluetooth?.sample()
            let assertionResult = assertions?.sample()
            let dockerResult = docker?.sample()
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.slowInFlight = false
                if thermalDue { self.latestThermal = thermalResult }
                if let audioResult { self.latestAudio = audioResult }
                if let bluetoothResult { self.latestBluetooth = bluetoothResult }
                if let assertionResult { self.latestAssertions = assertionResult }
                if let dockerResult { self.latestDocker = dockerResult }
            }
        }
    }

    /// nettop cadence: its 5s latency and per-flow accounting mean a slower
    /// rhythm is both sufficient and cheaper. Rates persist between passes.
    static let nettopPollInterval: TimeInterval = 20

    /// Processes that listen on ports but are not developer services:
    /// Apple system daemons and infra binaries. Their ports never belong in
    /// the dev-service list, and they must never be offered a Stop action.
    static let systemListenerNames: Set<String> = [
        "rapportd", "ControlCenter", "AirPlayUIAgent", "coreservicesd",
        "sharingd", "AppleIDAuthAgent", "trustd", "nsurlsessiond",
        "nsurlstoraged", "cloudd", "bird", "findmydevice", "apsd",
        "mdnsresponder", "mDNSResponder", "configd", "dprivacyd",
        "identityservicesd", "idsd", "akd", "appleh13camad", "hidd",
        "ctkd", "secinitd", "symptomsd", "networkserviceproxy",
        "remoted", "homed", "screensharingd", "netbiosd", "webauthd",
        "ContainerManagerD", "passd", "applepayd",
    ]

    /// Seconds a service must show no CPU activity before the UI may call it
    /// "No recent CPU activity (looked back N minutes)".
    static let quietLookback: TimeInterval = 300

    /// A listener counts as a development service only if it is NOT a system
    /// daemon and either runs from a user-writable location, has a project
    /// attribution, or is a known dev runtime.
    static func isDevService(process: ProcessRow) -> Bool {
        let name = process.displayName.lowercased()
        if systemListenerNames.contains(process.displayName)
            || systemListenerNames.contains(name) {
            return false
        }
        if let path = process.executablePathHint {
            // System location → system service, regardless of name.
            if path.hasPrefix("/usr/libexec/") || path.hasPrefix("/System/")
                || path.hasPrefix("/usr/sbin/") || path.hasPrefix("/sbin/")
                || path.hasPrefix("/private/var/") {
                return false
            }
            // Homebrew and user locations are developer services.
            if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/")
                || path.hasPrefix("/Users/") {
                return true
            }
        }
        // Attributed to a project → dev service even if the path is odd.
        if process.projectID != nil { return true }
        // Known runtime names as a last resort (path unknown).
        return RuntimeLabel.classify(name: process.displayName, path: process.executablePathHint) != nil
    }

    static func looksLikeSystemProcess(_ raw: RawProcess) -> Bool {
        let systemNames: Set<String> = [
            "kernel_task", "launchd", "loginwindow", "WindowServer",
            "mds", "mds_stores", "mdworker_shared", "powerd", "auditd",
        ]
        return systemNames.contains(raw.name)
    }

    /// Convert cumulative ticks to percent-of-one-core using the previous sweep.
    /// First sweep after launch returns nil percents (honest: unknown yet).
    private func computeProcessMetrics(rows: [ProcessRow], sweepAt: Date) -> [ProcessRow] {
        defer {
            priorTicks = rows.reduce(into: [:]) { if let ticks = $1.cpuTicks { $0[$1.pid] = ticks } }
            priorStarts = rows.reduce(into: [:]) { if let start = $1.startedAt { $0[$1.pid] = start } }
            priorDisk = rows.reduce(into: [:]) { dict, row in
                if let read = row.diskReadBytes, let write = row.diskWriteBytes {
                    dict[row.pid] = (read, write)
                }
            }
        }
        guard let prevAt = priorSweepAt else {
            priorSweepAt = sweepAt
            return rows
        }
        let dt = max(0.001, sweepAt.timeIntervalSince(prevAt))

        priorSweepAt = sweepAt
        return rows.map { row in
            var r = row

            // Canonical process CPU is percent of one core. UI preferences
            // normalize once; history integrates this raw scale into CPU seconds.
            r.cpuPercent = Self.processCPUPercent(currentNanos: row.cpuTicks, previousNanos: priorTicks[row.pid],
                currentStart: row.startedAt, previousStart: priorStarts[row.pid], intervalSeconds: dt)

            // Disk: bytes-per-second from cumulative proc_pid_rusage counters.
            let rates = Self.diskRates(
                currentRead: row.diskReadBytes, currentWrite: row.diskWriteBytes,
                prior: priorDisk[row.pid], intervalSeconds: dt
            )
            r.diskReadBytesPerSec = rates.read
            r.diskWriteBytesPerSec = rates.write

            // Network: rates from the latest nettop diff (refreshed on its own
            // slower cadence). nil until the first pass completes.
            if let net = netRates[row.pid] {
                r.netInBytesPerSec = net.in
                r.netOutBytesPerSec = net.out
            }
            return r
        }
    }

    // MARK: - Per-process network (nettop slow lane)

    /// Start a nettop pass if the cadence allows and none is in flight. The
    /// pass runs off the sampling queue; its result is applied on that queue.
    private func kickNettopIfNeeded() {
        let now = Date()
        lockFreeGuard()
        guard now.timeIntervalSince(lastNettopAt) >= Self.nettopPollInterval else { return }
        if nettopInFlight { return }
        nettopInFlight = true
        lastNettopAt = now
        nettopQueue.async { [weak self] in
            guard let self else { return }
            let result = self.nettopCollector.sample()
            // Re-enter the sampling queue to mutate engine state safely.
            self.queue.async { [weak self] in
                guard let self else { return }
                self.nettopInFlight = false
                guard let rows = result else { return }
                self.absorbNettop(rows)
            }
        }
    }

    /// Placeholder no-op kept for clarity: all engine mutation happens on the
    /// sampling queue; this documents that kickNettopIfNeeded is called there.
    private func lockFreeGuard() {}

    typealias NetCounters = [pid_t: (in: UInt64, out: UInt64, name: String)]

    /// Result of diffing two nettop passes.
    struct NetDiff {
        var current: NetCounters
        var rates: [pid_t: (in: Double, out: Double)]
        var newIn: UInt64
        var newOut: UInt64
    }

    /// Pure nettop diff. Counters are cumulative per pid, so only pids present
    /// in BOTH passes contribute: a pid that left adds nothing further, a new
    /// pid's pre-observation lifetime bytes are baseline, never session
    /// traffic, and a counter reset yields 0. All arithmetic saturates, so
    /// extreme-but-parseable counters can never trap the sampling queue.
    /// `prior == nil` means first pass: baseline only.
    static func diffNettop(
        prior: NetCounters?, rows: [ProcessNetUsage], intervalSeconds: Double
    ) -> NetDiff {
        var current: NetCounters = [:]
        for row in rows {
            if let e = current[row.pid] {
                current[row.pid] = (e.in.saturatingAdd(row.bytesIn), e.out.saturatingAdd(row.bytesOut), row.name)
            } else {
                current[row.pid] = (row.bytesIn, row.bytesOut, row.name)
            }
        }
        var diff = NetDiff(current: current, rates: [:], newIn: 0, newOut: 0)
        guard let prior else { return diff }
        let dt = max(0.001, intervalSeconds)
        for (pid, now) in current {
            guard let before = prior[pid] else { continue }
            let dIn = now.in >= before.in ? now.in - before.in : 0
            let dOut = now.out >= before.out ? now.out - before.out : 0
            if dIn > 0 || dOut > 0 {
                diff.rates[pid] = (Double(dIn) / dt, Double(dOut) / dt)
            }
            diff.newIn = diff.newIn.saturatingAdd(dIn)
            diff.newOut = diff.newOut.saturatingAdd(dOut)
        }
        return diff
    }

    private func absorbNettop(_ rows: [ProcessNetUsage]) {
        let now = Date()
        let diff = Self.diffNettop(
            prior: priorNettopAt == nil ? nil : priorNettop,
            rows: rows,
            intervalSeconds: priorNettopAt.map { now.timeIntervalSince($0) } ?? 0
        )
        sessionTotals.in = sessionTotals.in.saturatingAdd(diff.newIn)
        sessionTotals.out = sessionTotals.out.saturatingAdd(diff.newOut)
        priorNettop = diff.current
        priorNettopAt = now
        netRates = diff.rates
    }

    /// Per-sweep disk rates. Counters are cumulative since process start, so
    /// the rate is the delta over the sweep interval. nil until two sweeps
    /// exist; nil after a counter reset (pid reuse) — never a fake number.
    static func diskRates(
        currentRead: UInt64?, currentWrite: UInt64?,
        prior: (read: UInt64, write: UInt64)?, intervalSeconds: Double
    ) -> (read: Double?, write: Double?) {
        guard intervalSeconds > 0,
              let curRead = currentRead, let curWrite = currentWrite,
              let prior
        else { return (nil, nil) }
        guard curRead >= prior.read, curWrite >= prior.write else { return (nil, nil) }
        let dt = max(0.001, intervalSeconds)
        return (
            Double(curRead - prior.read) / dt,
            Double(curWrite - prior.write) / dt
        )
    }

    static func coreCPUPercent(tickDeltaNanos: Double, intervalSeconds: Double) -> Double {
        guard intervalSeconds.isFinite, intervalSeconds > 0, tickDeltaNanos.isFinite, tickDeltaNanos >= 0 else { return 0 }
        return tickDeltaNanos / 1_000_000_000 / intervalSeconds * 100
    }

    static func processCPUPercent(currentNanos: UInt64?, previousNanos: UInt64?, currentStart: Date?, previousStart: Date?, intervalSeconds: Double) -> Double? {
        guard let currentNanos, let previousNanos, currentNanos >= previousNanos,
              let currentStart, currentStart == previousStart else { return nil }
        return coreCPUPercent(tickDeltaNanos: Double(currentNanos - previousNanos), intervalSeconds: intervalSeconds)
    }

    /// Convert a process tick delta to percent of TOTAL machine capacity —
    /// the same scale as the system CPU figure. One fully-busy core on an
    /// N-core Mac reads 100/N %, so app rows and the CPU headline compare.
    static func machineCPUPercent(tickDeltaNanos: Double, intervalSeconds: Double, coreCount: Int) -> Double {
        guard intervalSeconds > 0, coreCount > 0 else { return 0 }
        let coreSecondsUsed = tickDeltaNanos / 1_000_000_000.0
        let machineSeconds = intervalSeconds * Double(coreCount)
        return min(100, coreSecondsUsed / machineSeconds * 100)
    }

    /// Build DevService list: ports joined to processes, activity labeled from
    /// recent CPU ticks observed in the lookback window.
    static func buildServices(
        ports: [ListeningPort],
        rows: [ProcessRow],
        priorActivity: inout [pid_t: Date]
    ) -> [DevService] {
        // Defensive: last-wins instead of trapping if a duplicate pid ever
        // appears (fixture data, future collector changes).
        let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { _, second in second })
        var grouped: [pid_t: [ListeningPort]] = [:]
        for p in ports { grouped[p.pid, default: []].append(p) }

        let now = Date()
        var services: [DevService] = []
        for (pid, plist) in grouped {
            let process: ProcessRow
            if let row = byPid[pid] {
                process = row
            } else {
                // Port bound by a process we couldn't enrich (short-lived):
                // show it with unknown metrics, never a Stop recommendation.
                process = ProcessRow(
                    pid: pid,
                    name: plist.first?.processName ?? "pid \(pid)",
                    parentPid: nil
                )
            }
            // System daemons (rapportd etc.) are not developer services.
            guard isDevService(process: process) else { continue }

            // Activity must reflect observed time, never an assumed window.
            // The ledger holds the last busy moment, or the first sighting
            // for a service never seen busy, so "quiet for N" only ever
            // states silence Portmaster actually watched.
            let currentCPU = process.cpuPercent ?? 0
            if currentCPU > 1.0 || priorActivity[pid] == nil {
                priorActivity[pid] = now
            }
            let observedSince = priorActivity[pid] ?? now
            let activity: ServiceActivity = currentCPU > 1.0
                ? .active(lastSeen: now)
                : .quiet(lookbackSeconds: max(0, now.timeIntervalSince(observedSince)))
            let runtime = RuntimeLabel.classify(name: process.name, path: process.executablePathHint)
            services.append(DevService(
                process: process,
                ports: plist.sorted { $0.port < $1.port },
                activity: activity,
                runtimeLabel: runtime,
                projectID: process.projectID
            ))
        }
        // Forget pids that stopped listening so a reused pid starts fresh.
        priorActivity = priorActivity.filter { grouped[$0.key] != nil }
        return services.sorted { ($0.primaryPort ?? 0) < ($1.primaryPort ?? 0) }
    }
}

extension UInt64 {
    /// Addition that clamps at UInt64.max instead of trapping.
    func saturatingAdd(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}

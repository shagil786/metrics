// Port/service models: listening sockets and how they map to processes and projects.
import Foundation

/// One listening TCP socket endpooint bound by a process.
public struct ListeningPort: Identifiable, Hashable, Sendable {
    public let port: UInt16
    public let pid: pid_t
    public let processName: String
    /// IPv4 or IPv6 listener; a socket can bind both — one row per (port, pid).
    public let address: String
    /// nil when lsof could not map the socket owner (e.g. stale pid, permission).
    public let processResolved: Bool

    public init(
        port: UInt16, pid: pid_t, processName: String,
        address: String = "*", processResolved: Bool = true
    ) {
        self.port = port
        self.pid = pid
        self.processName = processName
        self.address = address
        self.processResolved = processResolved
    }

    public var id: String { "\(pid):\(port):\(address)" }

    public var displayAddress: String {
        address == "*" ? "*" : address
    }
}

/// Activity classification for a service. Deliberately conservative:
/// quiet is an observation, never a recommendation.
public enum ServiceActivity: Hashable, Sendable {
    /// Observed CPU above the quiet threshold within the lookback window.
    case active(lastSeen: Date?)
    /// No CPU activity above threshold in the lookback window.
    case quiet(lookbackSeconds: TimeInterval)

    public var isQuiet: Bool {
        if case .quiet = self { return true }
        return false
    }
}

/// A development service: a process with a listening port, enriched with
/// runtime guesses, project attribution, and conservative activity labeling.
public struct DevService: Identifiable, Hashable, Sendable {
    public let id: String
    public let process: ProcessRow
    public let ports: [ListeningPort]
    public let activity: ServiceActivity
    /// Best-effort runtime label ("Node.js", "Python", "Redis", …) — nil if unknown.
    public let runtimeLabel: String?
    public let projectID: String?

    public init(
        process: ProcessRow, ports: [ListeningPort], activity: ServiceActivity,
        runtimeLabel: String? = nil, projectID: String? = nil
    ) {
        self.process = process
        self.ports = ports
        self.activity = activity
        self.runtimeLabel = runtimeLabel
        self.projectID = projectID
        self.id = "\(process.pid)-\(ports.map(\.port).sorted().map(String.init).joined(separator: "-"))"
    }

    public var primaryPort: UInt16? { ports.map(\.port).min() }

    public var displayName: String {
        process.displayName
    }
}

/// Snapshot of everything one sweep knows, ready for rendering and persistence.
public struct ObservationSnapshot: Sendable {
    public let at: Date
    public let system: SystemSample
    public let processes: [ProcessRow]
    public let ports: [ListeningPort]
    public let services: [DevService]
    /// Processes rolled up under their owning app (Vitals-style model).
    public let rollups: [AppRollup]
    /// Cumulative bytes since app launch, from nettop diffs. Values are nil
    /// until the first nettop pass completes (honest unknown, never zero).
    public var sessionNet: (in: UInt64?, out: UInt64?)
    /// Sleep-preventing power assertions per process ("Keeping This Mac
    /// Awake"). Refreshed on a slow lane; empty until the first pass lands.
    public var sleepAssertions: [SleepAssertion]
    /// Docker containers via the docker CLI. nil until the first pass
    /// completes; availability reports notInstalled/daemonDown honestly.
    public var docker: DockerSample?
    public var audio: AudioSample?
    public var bluetooth: BluetoothSample?

    public init(
        at: Date, system: SystemSample, processes: [ProcessRow],
        ports: [ListeningPort], services: [DevService],
        rollups: [AppRollup] = [],
        sessionNet: (in: UInt64?, out: UInt64?) = (nil, nil),
        sleepAssertions: [SleepAssertion] = [],
        docker: DockerSample? = nil,
        audio: AudioSample? = nil, bluetooth: BluetoothSample? = nil
    ) {
        self.at = at
        self.system = system
        self.processes = processes
        self.ports = ports
        self.services = services
        self.rollups = rollups
        self.sessionNet = sessionNet
        self.sleepAssertions = sleepAssertions
        self.docker = docker
        self.audio = audio; self.bluetooth = bluetooth
    }

    public static let empty = ObservationSnapshot(
        at: .distantPast,
        system: SystemSample(at: .distantPast, cpu: .unknown, memory: .unknown),
        processes: [], ports: [], services: []
    )
}

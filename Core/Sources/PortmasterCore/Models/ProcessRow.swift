// ProcessRow: one snapshot of one pid, used by every surface.
import Foundation

/// Lifecycle state of a pid observed across snapshots.
public enum PidLifecycle: Hashable, Sendable {
    case continuing
    case exited
    case reused(previousName: String?)
}

/// A single process observation. `missing` fields are genuinely unknown —
/// Portmaster never substitutes plausible-looking values.
public struct ProcessRow: Identifiable, Hashable, Sendable {
    public let pid: pid_t
    public let name: String
    public let parentPid: pid_t?
    /// Child pids grouped under this process (direct children only).
    public var children: [pid_t]
    public let isAppBundle: Bool
    /// CPU percent of one core (0...~100×coreCount), before display normalization.
    /// Mutated by the sampler between sweeps; nil until a second sweep exists.
    public var cpuPercent: Double?
    /// Resident memory footprint in bytes.
    public let memoryBytes: UInt64?
    /// Wall-clock start time of the process, if the system exposed it.
    public let startedAt: Date?
    /// Cumulative CPU time converted from Mach ticks into nanoseconds.
    public let cpuTicks: UInt64?
    /// Cumulative disk bytes since process start (proc_pid_rusage), as the
    /// kernel reported them this sweep. nil = not reported. Rates are derived
    /// from these by the sampler, mirroring how cpuPercent comes from ticks.
    public let diskReadBytes: UInt64?
    public let diskWriteBytes: UInt64?
    public let lifecycle: PidLifecycle
    /// Project association, resolved by ProjectAttributor; nil = unattributed.
    public let projectID: String?
    /// Executable path carried through from the sweep (rollup grouping,
    /// detail sheet). Kept on-device; never transmitted.
    public var executablePathHint: String?
    /// Disk-write rate derived by the sampler from two sweeps of
    /// proc_pid_rusage counters. nil until the second sweep exists.
    public var diskWriteBytesPerSec: Double?
    /// Disk-read rate, same derivation as the write rate.
    public var diskReadBytesPerSec: Double?
    /// Per-process network rates from the latest nettop diff (refreshed on a
    /// slower cadence than ticks). nil until the first pass completes.
    public var netInBytesPerSec: Double?
    public var netOutBytesPerSec: Double?

    public init(
        pid: pid_t,
        name: String,
        parentPid: pid_t?,
        children: [pid_t] = [],
        isAppBundle: Bool = false,
        cpuPercent: Double? = nil,
        memoryBytes: UInt64? = nil,
        startedAt: Date? = nil,
        cpuTicks: UInt64? = nil,
        diskReadBytes: UInt64? = nil,
        diskWriteBytes: UInt64? = nil,
        lifecycle: PidLifecycle = .continuing,
        projectID: String? = nil,
        executablePathHint: String? = nil,
        diskWriteBytesPerSec: Double? = nil,
        diskReadBytesPerSec: Double? = nil,
        netInBytesPerSec: Double? = nil,
        netOutBytesPerSec: Double? = nil
    ) {
        self.pid = pid
        self.name = name
        self.parentPid = parentPid
        self.children = children
        self.isAppBundle = isAppBundle
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.startedAt = startedAt
        self.cpuTicks = cpuTicks
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.lifecycle = lifecycle
        self.projectID = projectID
        self.executablePathHint = executablePathHint
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.netInBytesPerSec = netInBytesPerSec
        self.netOutBytesPerSec = netOutBytesPerSec
    }
    public var id: Int32 { pid }

    /// Short display name: sanitized (nulls stripped) process name.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "PID \(pid)" : trimmed
    }
}

/// Field values that may be unknown. Never filled with zeros.
public enum MetricAvailability<Value: Hashable & Sendable>: Hashable, Sendable {
    case available(Value)
    case unavailable

    public var value: Value? {
        if case .available(let v) = self { return v }
        return nil
    }

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

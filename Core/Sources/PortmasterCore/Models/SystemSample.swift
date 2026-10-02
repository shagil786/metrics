// System-wide CPU and memory state + formatting helpers.
import Foundation

/// Aggregate machine CPU state derived from scheduler tick deltas.
public struct SystemCPU: Hashable, Sendable {
    /// Total machine CPU percent across all cores (100 = the whole Mac busy).
    public let totalPercent: Double
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double
    public let corePercents: [Double]
    /// Logical core count used to normalize percentages.
    public let coreCount: Int

    public init(
        totalPercent: Double, userPercent: Double, systemPercent: Double,
        idlePercent: Double, corePercents: [Double], coreCount: Int
    ) {
        self.totalPercent = totalPercent
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
        self.corePercents = corePercents
        self.coreCount = coreCount
    }

    public static let unknown = SystemCPU(
        totalPercent: 0, userPercent: 0, systemPercent: 0, idlePercent: 100,
        corePercents: [], coreCount: 0
    )
}

public enum MemoryPressureLevel: String, Hashable, Sendable {
    case normal
    case elevated
    case critical
}

/// Machine memory state. `pressureLevel` reflects the kernel's own
/// memorystatus pressure signal; `pressureRatio` is plain occupancy
/// (used/total) shown for context — the two are different things and
/// are labeled separately in the UI.
public struct SystemMemory: Hashable, Sendable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let pressureLevel: MemoryPressureLevel
    /// 0...1; >1 when swap is heavy (clamped for display).
    public let pressureRatio: Double
    /// Swap in use; nil when the value could not be read (never zero-filled).
    public let swapBytes: UInt64?
    /// Byte fields the collector could not obtain (e.g. swap) are nil, not zero.
    public let freeBytes: UInt64?
    public let appBytes: UInt64?
    public let wiredBytes: UInt64?
    public let compressedBytes: UInt64?

    public init(
        totalBytes: UInt64, usedBytes: UInt64, pressureLevel: MemoryPressureLevel,
        pressureRatio: Double, swapBytes: UInt64?, freeBytes: UInt64?,
        appBytes: UInt64?, wiredBytes: UInt64?, compressedBytes: UInt64?
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.pressureLevel = pressureLevel
        self.pressureRatio = pressureRatio
        self.swapBytes = swapBytes
        self.freeBytes = freeBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
    }

    public static let unknown = SystemMemory(
        totalBytes: 0, usedBytes: 0, pressureLevel: .normal, pressureRatio: 0,
        swapBytes: nil, freeBytes: nil, appBytes: nil, wiredBytes: nil, compressedBytes: nil
    )
}

/// One machine-wide sample stamped at collection time.
public struct SystemSample: Sendable {
    public let at: Date
    public let cpu: SystemCPU
    public let memory: SystemMemory
    /// Network throughput since the previous tick (nil on the first tick).
    public var network: NetworkSample?
    /// Root-volume capacity (nil when statfs fails).
    public var disk: DiskSample?
    /// Battery state (nil on desktops without an internal battery).
    public var battery: BatterySample?
    /// GPU state from the IORegistry (nil on Intel Macs / read failure).
    public var gpu: GPUSample?
    /// Read-only SMC sensors, refreshed on the slow lane; nil when unavailable.
    public var thermal: ThermalSample?

    public init(
        at: Date, cpu: SystemCPU, memory: SystemMemory,
        network: NetworkSample? = nil, disk: DiskSample? = nil,
        battery: BatterySample? = nil, gpu: GPUSample? = nil, thermal: ThermalSample? = nil
    ) {
        self.at = at
        self.cpu = cpu
        self.memory = memory
        self.network = network
        self.disk = disk
        self.battery = battery
        self.gpu = gpu
        self.thermal = thermal
    }
}

// MARK: - Formatting

public enum Fmt {
    /// Byte counts in developer-readable units (binary KiB/MiB/GiB).
    public static func bytes(_ b: UInt64?) -> String {
        guard let b else { return "—" }
        return bytes(b)
    }

    public static func bytes(_ b: UInt64) -> String {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        let d = Double(b)
        switch d {
        case ..<kb: return "\(b) B"
        case ..<mb: return String(format: "%.0f KB", d / kb)
        case ..<gb: return String(format: "%.0f MB", d / mb)
        default: return String(format: "%.1f GB", d / gb)
        }
    }

    /// CPU percent with light-touch precision (no fake decimals).
    public static func cpu(_ p: Double?) -> String {
        guard let p else { return "—" }
        if p >= 100 { return String(format: "%.0f%%", p) }
        if p >= 10 { return String(format: "%.1f%%", p) }
        return String(format: "%.1f%%", p)
    }

    public static func percent(_ p: Double) -> String {
        String(format: "%.0f%%", p)
    }

    /// Throughput in human units (kB/s, MB/s, GB/s).
    public static func rate(_ bytesPerSec: Double) -> String {
        let p = rateParts(bytesPerSec)
        return "\(p.value) \(p.unit)"
    }

    /// Throughput split for card layouts: big value + small unit.
    /// Trailing zeros are trimmed ("14 kB/s", "5.4 MB/s") to match the
    /// reference card formatting.
    public static func rateParts(_ bytesPerSec: Double) -> (value: String, unit: String) {
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        func trim(_ s: String) -> String {
            var out = s
            if out.contains(".") {
                while out.hasSuffix("0") { out.removeLast() }
                if out.hasSuffix(".") { out.removeLast() }
            }
            return out
        }
        switch bytesPerSec {
        case ..<kb: return (String(format: "%.0f", bytesPerSec), "B/s")
        case ..<mb: return (trim(String(format: "%.1f", bytesPerSec / kb)), "kB/s")
        case ..<gb: return (trim(String(format: "%.1f", bytesPerSec / mb)), "MB/s")
        default: return (trim(String(format: "%.2f", bytesPerSec / gb)), "GB/s")
        }
    }

    /// Elapsed time since a start date in compact form (3d 4h, 12m, 45s).
    public static func elapsed(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let secs = max(0, now.timeIntervalSince(date))
        let d = Int(secs) / 86400
        let h = (Int(secs) % 86400) / 3600
        let m = (Int(secs) % 3600) / 60
        let s = Int(secs) % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

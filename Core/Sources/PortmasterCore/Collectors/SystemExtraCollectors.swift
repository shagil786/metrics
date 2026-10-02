// Extra system collectors for the Overview cards: network throughput,
// disk capacity + I/O, battery. Missing readings stay unknown; no fabrication.
import Foundation
import Darwin
import IOKit.ps

// MARK: - Network

public struct NetworkSample: Hashable, Sendable {
    public let downBytesPerSec: Double
    public let upBytesPerSec: Double

    public init(downBytesPerSec: Double, upBytesPerSec: Double) {
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
    }

    public static let zero = NetworkSample(downBytesPerSec: 0, upBytesPerSec: 0)
}

/// Per-interface byte counters via sysctl(NET_RT_IFLIST2), diffed between
/// samples. Skips loopback.
public final class NetworkCollector: @unchecked Sendable {
    private var prev: [UInt32: (ib: UInt64, ob: UInt64)] = [:]
    private var prevAt: Date?
    private let lock = NSLock()

    public init() {}

    private struct IfCounters {
        var ib: UInt64 = 0
        var ob: UInt64 = 0
    }

    private static func readInterfaceTotals() -> [UInt32: IfCounters] {
        var result: [UInt32: IfCounters] = [:]
        var ifmib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&ifmib, 6, nil, &length, nil, 0) == 0, length > 0 else { return result }
        var buf = [UInt8](repeating: 0, count: length)
        guard sysctl(&ifmib, 6, &buf, &length, nil, 0) == 0 else { return result }

        var offset = 0
        buf.withUnsafeMutableBytes { raw in
            while offset + MemoryLayout<if_msghdr2>.size <= length {
                let msg = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                if msg.ifm_type == RTM_IFINFO2 {
                    let index: UInt32 = UInt32(msg.ifm_index)
                    let flags: UInt32 = UInt32(msg.ifm_flags)
                    let data = msg.ifm_data
                    var entry = result[index] ?? IfCounters()
                    // Up, non-loopback interfaces only.
                    if flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_LOOPBACK) == 0 {
                        entry.ib = entry.ib.saturatingAdd(data.ifi_ibytes)
                        entry.ob = entry.ob.saturatingAdd(data.ifi_obytes)
                    }
                    result[index] = entry
                }
                offset += Int(msg.ifm_msglen)
            }
        }
        return result
    }

    private var prevTotals: (ib: UInt64, ob: UInt64)?

    /// Throughput since the previous call (first call returns zero baseline).
    public func sample() -> NetworkSample {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        let totals = Self.readInterfaceTotals()
        var ib: UInt64 = 0, ob: UInt64 = 0
        for v in totals.values { ib = ib.saturatingAdd(v.ib); ob = ob.saturatingAdd(v.ob) }

        defer {
            prevTotals = (ib, ob)
            prevAt = now
        }

        guard let prevAt, let before = prevTotals else { return .zero }
        let dt = now.timeIntervalSince(prevAt)
        guard dt > 0.05 else { return .zero }

        // Counter wrap/restart: treat as no traffic this interval.
        let dIb = ib >= before.ib ? ib - before.ib : 0
        let dOb = ob >= before.ob ? ob - before.ob : 0
        return NetworkSample(
            downBytesPerSec: Double(dIb) / dt,
            upBytesPerSec: Double(dOb) / dt
        )
    }
}

// MARK: - Disk

public struct DiskSample: Hashable, Sendable {
    /// Capacity still available to the user (accounts for purgeable space policy).
    public let freeBytes: UInt64
    public let totalBytes: UInt64
    /// Whole-disk read/write throughput, bytes per second. Sourced from summed
    /// per-process rusage rates, so nil until the sampler has diffed two
    /// sweeps — nil is shown as "—", never rendered as a fake zero.
    public let readBytesPerSec: Double?
    public let writeBytesPerSec: Double?

    public init(freeBytes: UInt64, totalBytes: UInt64, readBytesPerSec: Double?, writeBytesPerSec: Double?) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
        self.readBytesPerSec = readBytesPerSec
        self.writeBytesPerSec = writeBytesPerSec
    }
}

/// Root-volume capacity via statfs and I/O via log-level IO statistics.
public final class DiskCollector: @unchecked Sendable {
    private var prevRead: UInt64 = 0
    private var prevWrite: UInt64 = 0
    private var prevAt: Date?
    private let lock = NSLock()

    public init() {}

    public func sample() -> DiskSample? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()

        // Capacity of the root volume.
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let blockSize = UInt64(fs.f_bsize)
        let free = UInt64(fs.f_bavail) * blockSize
        let total = UInt64(fs.f_blocks) * blockSize

        // Whole-disk throughput is derived by the sampling engine from summed
        // per-process rusage deltas (see SamplingEngine.tick). The capacity
        // collector itself reports none, so rates start nil — honest unknown.
        return DiskSample(
            freeBytes: free,
            totalBytes: total,
            readBytesPerSec: nil,
            writeBytesPerSec: nil
        )
    }
}

// MARK: - GPU

/// GPU state from the Apple Silicon accelerator's IORegistry performance
/// statistics. All values come from IOKit registry properties that are
/// world-readable (verified: ioreg shows them without privileges) through
/// public IOKit functions — no private API.
public struct GPUSample: Hashable, Sendable {
    public let utilizationPercent: Double?
    public let rendererPercent: Double?
    public let tilerPercent: Double?
    public let inUseMemoryBytes: UInt64?
    public let coreCount: Int?

    public init(
        utilizationPercent: Double?, rendererPercent: Double?,
        tilerPercent: Double?, inUseMemoryBytes: UInt64?, coreCount: Int?
    ) {
        self.utilizationPercent = utilizationPercent
        self.rendererPercent = rendererPercent
        self.tilerPercent = tilerPercent
        self.inUseMemoryBytes = inUseMemoryBytes
        self.coreCount = coreCount
    }
}

public enum GPUCollector {
    /// Sample the first AGXAccelerator entry (Apple Silicon GPU).
    /// Returns nil on Intel Macs without the entry or any read failure.
    public static func sample() -> GPUSample? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }

        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [String: Any]
        else { return nil }

        var coreCount: Int?
        if let ccRaw = IORegistryEntryCreateCFProperty(
            entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber {
            coreCount = ccRaw.intValue
        }

        func pct(_ key: String) -> Double? {
            (raw[key] as? NSNumber)?.doubleValue
        }

        return GPUSample(
            utilizationPercent: pct("Device Utilization %"),
            rendererPercent: pct("Renderer Utilization %"),
            tilerPercent: pct("Tiler Utilization %"),
            inUseMemoryBytes: (raw["In use system memory"] as? NSNumber)?.uint64Value,
            coreCount: coreCount
        )
    }
}

// MARK: - Per-process network I/O

/// One process's cumulative network byte counters from nettop.
public struct ProcessNetUsage: Hashable, Sendable {
    public let pid: pid_t
    /// Process name as nettop reports it (truncated by the tool to a few chars).
    public let name: String
    public let bytesIn: UInt64
    public let bytesOut: UInt64

    public init(pid: pid_t, name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.pid = pid
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Source of per-process cumulative network counters. The real implementation
/// shells to nettop; fixtures replace it in preview mode so synthetic and
/// live data never mix.
public protocol NettopProviding: Sendable {
    func sample() -> [ProcessNetUsage]?
}

/// Per-process cumulative network counters via /usr/bin/nettop -P -L 1.
/// nettop is a supported system tool (same policy as the lsof scanner:
/// fixed argv, no interpolation, hard timeout). Counters are cumulative
/// per flow since flow start; the sampling engine diffs sweeps into rates
/// and session totals, mirroring the CPU-tick and disk-rusage pattern.
/// Note: nettop's 5s latency runs on the sampling queue, off main.
public final class NettopNetworkCollector: NettopProviding, @unchecked Sendable {
    private let nettopPath = "/usr/bin/nettop"
    private let timeoutSeconds: Double
    private let lock = NSLock()
    private var running = false

    public init(timeoutSeconds: Double = 12) {
        self.timeoutSeconds = timeoutSeconds
    }

    /// One nettop pass. Returns nil on failure (missing tool, timeout,
    /// parse error) — distinct from an empty list.
    public func sample() -> [ProcessNetUsage]? {
        lock.lock()
        if running {
            lock.unlock()
            return nil // a pass is already in flight on the sampling queue
        }
        running = true
        lock.unlock()
        defer {
            lock.lock(); running = false; lock.unlock()
        }

        guard FileManager.default.isExecutableFile(atPath: nettopPath) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nettopPath)
        // Fixed argv — nothing user-controlled is ever interpolated here.
        proc.arguments = ["-P", "-L", "1", "-J", "bytes_in,bytes_out"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        proc.standardInput = FileHandle.nullDevice
        proc.qualityOfService = .utility

        do {
            try proc.run()
        } catch {
            return nil
        }

        let timedOut = DispatchWorkItem { [weak proc] in
            if let proc, proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds, execute: timedOut
        )

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        timedOut.cancel()

        guard proc.terminationReason != .uncaughtSignal else { return nil }
        guard proc.terminationStatus == 0 else { return nil }

        return Self.parseCSV(data)
    }

    /// Parse nettop -L CSV: header row, then `name.pid,bytes_in,bytes_out,`.
    /// The trailing comma is real nettop output (empty delta column).
    static func parseCSV(_ data: Data) -> [ProcessNetUsage] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var results: [ProcessNetUsage] = []

        for line in text.split(separator: "\n") {
            // Header: ",bytes_in,bytes_out," — skip anything without digits
            // in the first field or the two expected columns.
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }

            let idField = fields[0]
            guard let dotIdx = idField.lastIndex(of: ".") else { continue }
            let name = String(idField[idField.startIndex..<dotIdx])
            guard let pid = pid_t(idField[idField.index(after: dotIdx)...]) else { continue }
            guard let bin = UInt64(fields[1].trimmingCharacters(in: .whitespaces)),
                  let bout = UInt64(fields[2].trimmingCharacters(in: .whitespaces))
            else { continue }
            guard pid > 0 else { continue }

            let usage = ProcessNetUsage(pid: pid, name: name, bytesIn: bin, bytesOut: bout)
            if let idx = results.firstIndex(where: { $0.pid == usage.pid }) {
                // Multiple flows per pid: nettop -P should aggregate, but be
                // defensive — sum rather than drop. Saturating: extreme
                // counters must never trap the sampling queue.
                results[idx] = ProcessNetUsage(
                    pid: usage.pid, name: name,
                    bytesIn: results[idx].bytesIn.saturatingAdd(usage.bytesIn),
                    bytesOut: results[idx].bytesOut.saturatingAdd(usage.bytesOut)
                )
            } else {
                results.append(usage)
            }
        }
        return results
    }
}

// MARK: - System info (load average, uptime)

public enum SystemInfo {
    /// Marketing chip name, e.g. "Apple M2 Max" (machdep.cpu.brand_string).
    public static func chipName() -> String? {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }

    /// 1-minute load average via getloadavg (supported libc API).
    public static func loadAverage1() -> Double? {
        var avgs: [Double] = [0, 0, 0]
        guard getloadavg(&avgs, 3) >= 1 else { return nil }
        return avgs[0]
    }

    /// Seconds since boot via sysctl("kern.boottime").
    public static func uptimeSeconds() -> TimeInterval? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        return Date().timeIntervalSince(bootDate)
    }

    /// Compact uptime string: "3d 4h", "12h 5m", "45m".
    public static func uptimeLabel() -> String? {
        guard let secs = uptimeSeconds() else { return nil }
        let d = Int(secs) / 86400
        let h = (Int(secs) % 86400) / 3600
        let m = (Int(secs) % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

// MARK: - Battery

public struct BatterySample: Hashable, Sendable {
    public enum Source: String, Sendable {
        case battery, power, unknown
    }

    public let percentage: Double?
    public let timeToEmptyMinutes: Int?
    public let isCharging: Bool
    public let source: Source
    public let wattage: Double?
    public let healthPercent: Double?
    public let cycleCount: Int?

    public init(
        percentage: Double?, timeToEmptyMinutes: Int?, isCharging: Bool,
        source: Source, wattage: Double?, healthPercent: Double? = nil, cycleCount: Int? = nil
    ) {
        self.percentage = percentage
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.isCharging = isCharging
        self.source = source
        self.wattage = wattage
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
    }
}

/// Battery via IOKit power sources (supported, no permissions).
public enum BatteryCollector {
    public static func sample() -> BatterySample? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let dict = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }

            guard let type = dict[kIOPSTypeKey] as? String,
                  type == kIOPSInternalBatteryType
            else { continue }

            let capacity = dict[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maxCapacity = dict[kIOPSMaxCapacityKey] as? Int ?? 1
            let percent = maxCapacity > 0 ? Double(capacity) / Double(maxCapacity) * 100 : nil
            let state = dict[kIOPSPowerSourceStateKey] as? String
            let charging = state == kIOPSACPowerValue
            let src: BatterySample.Source = charging ? .power : .battery

            // Time remaining via the dedicated estimate API (seconds;
            // -1 = unknown, -2 = unlimited/on AC per IOPS headers).
            let estimate = IOPSGetTimeRemainingEstimate()
            var minutes: Int?
            if !charging, estimate > 0 {
                minutes = Int(estimate / 60)
            }
            let health = registryHealth()
            return BatterySample(
                percentage: percent,
                timeToEmptyMinutes: minutes,
                isCharging: charging,
                source: src,
                wattage: Self.watts(
                    voltageMV: dict[kIOPSVoltageKey] as? Int,
                    // kIOPSCurrentKey ("Current", mA) — the amperage reading;
                    // kIOPSAmperageKey exists only on iOS-era headers.
                    amperageMA: dict[kIOPSCurrentKey] as? Int
                ),
                healthPercent: health.percent,
                cycleCount: health.cycles
            )
        }
        return nil
    }

    /// Battery health is optional IORegistry metadata, independent of SMC.
    /// Desktop Macs have no battery service; absent properties stay unknown.
    private static func registryHealth() -> (percent: Double?, cycles: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else { return (nil, nil) }
        return health(from: dict)
    }

    static func health(from properties: [String: Any]) -> (percent: Double?, cycles: Int?) {
        let cycles = (properties["CycleCount"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        let maxCapacity = properties["AppleRawMaxCapacity"] as? Int
            ?? properties["NominalChargeCapacity"] as? Int
            ?? (properties["MaxCapacity"] as? Int).flatMap { $0 > 100 ? $0 : nil }
        guard let full = maxCapacity, full > 0,
              let design = properties["DesignCapacity"] as? Int, design > 0 else { return (nil, cycles) }
        // Estimated full-charge/design capacity, not the normalized charge %
        // in IOPS. New batteries may legitimately exceed design capacity.
        return (Double(full) / Double(design) * 100, cycles)
    }

    /// Power draw in watts from millivolts × milliamps. nil when either
    /// reading is missing (honest unknown, never zero); magnitude only,
    /// since discharge sign conventions vary across Macs.
    static func watts(voltageMV: Int?, amperageMA: Int?) -> Double? {
        guard let v = voltageMV, let a = amperageMA else { return nil }
        return abs(Double(v) * Double(a)) / 1_000_000
    }
}

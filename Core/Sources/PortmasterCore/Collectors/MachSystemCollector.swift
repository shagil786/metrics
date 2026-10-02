// Mach host-based machine-wide CPU + memory sampling.
// CPU: host_processor_info tick deltas. Memory: host_statistics64 + sysctl.
import Foundation
import Darwin

public final class MachSystemCollector: SystemCollector, @unchecked Sendable {
    /// Previous tick snapshot for CPU delta computation.
    private var prevTicks: [processor_info_array_t] = []
    private var prevCounts: [mach_msg_type_number_t] = []
    private var prevCores: [[UInt32]] = []
    private let lock = NSLock()

    public init() {}

    public func sampleCPU() -> SystemCPU? {
        lock.lock()
        defer { lock.unlock() }

        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &coreCount, &info, &count
        )
        guard kr == KERN_SUCCESS, let info, coreCount > 0 else { return nil }

        defer {
            let size = vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var cores: [UInt32] = []
        cores.reserveCapacity(Int(coreCount))
        var userSum: UInt64 = 0, sysSum: UInt64 = 0, idleSum: UInt64 = 0, totalSum: UInt64 = 0

        for i in 0..<Int(coreCount) {
            let user = UInt32(info[Int(i) * Int(CPU_STATE_MAX) + Int(CPU_STATE_USER)])
            let sys = UInt32(info[Int(i) * Int(CPU_STATE_MAX) + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(info[Int(i) * Int(CPU_STATE_MAX) + Int(CPU_STATE_IDLE)])
            let nice = UInt32(info[Int(i) * Int(CPU_STATE_MAX) + Int(CPU_STATE_NICE)])
            let total = user + sys + idle + nice

            let prevUser = prevCores.indices.contains(i) ? prevCores[i][0] : 0
            let prevSys = prevCores.indices.contains(i) ? prevCores[i][1] : 0
            let prevIdle = prevCores.indices.contains(i) ? prevCores[i][2] : 0
            let prevNice = prevCores.indices.contains(i) ? prevCores[i][3] : 0

            let dUser = user > prevUser ? user - prevUser : 0
            let dSys = sys > prevSys ? sys - prevSys : 0
            let dIdle = idle > prevIdle ? idle - prevIdle : 0
            let dNice = nice > prevNice ? nice - prevNice : 0
            let dTotal = dUser + dSys + dIdle + dNice

            let denom = Double(max(1, dTotal))
            let pct = Double(dUser + dSys + dNice) / denom * 100
            cores.append(UInt32(pct.rounded()))

            userSum += UInt64(dUser)
            sysSum += UInt64(dSys)
            idleSum += UInt64(dIdle)
            totalSum += UInt64(dTotal)
        }

        let denom = Double(max(1, totalSum))
        let cpu = SystemCPU(
            totalPercent: Double(userSum + sysSum) / denom * 100,
            userPercent: Double(userSum) / denom * 100,
            systemPercent: Double(sysSum) / denom * 100,
            idlePercent: Double(idleSum) / denom * 100,
            corePercents: cores.map { Double($0) },
            coreCount: Int(coreCount)
        )

        // Retain the raw tick arrays for the next delta.
        for i in 0..<Int(coreCount) {
            let vals = (0..<4).map { UInt32(info[i * Int(CPU_STATE_MAX) + $0]) }
            if i < prevCores.count { prevCores[i] = vals }
            else { prevCores.append(vals) }
        }
        _ = prevTicks
        _ = prevCounts

        return cpu
    }

    public func sampleMemory() -> SystemMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) { statsPtr in
            host_statistics64(
                host, HOST_VM_INFO64,
                host_info_t(OpaquePointer(statsPtr)), &count
            )
        }
        guard kr == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        _ = host_page_size(host, &pageSize)
        let page: UInt64 = UInt64(pageSize > 0 ? pageSize : 4096)

        let totalPhys = ProcessInfo.processInfo.physicalMemory

        let freePages = UInt64(stats.free_count)
        let activePages = UInt64(stats.active_count)
        let inactivePages = UInt64(stats.inactive_count)
        let wiredPages = UInt64(stats.wire_count)
        let compressedPages = UInt64(stats.compressor_page_count)
        let purgeablePages = UInt64(stats.purgeable_count)

        let freeB = freePages * page
        let activeB = activePages * page
        let wiredB = wiredPages * page
        let compressedB = compressedPages * page
        let inactiveB = inactivePages * page

        // "Used" mirrors top/Activity Monitor accounting:
        // app (active+inactive anonymous) + wired + compressor.
        // Validated against `top -l 1` PhysMem on the dev machine.
        let usedB = activeB + inactiveB + wiredB + compressedB
        let ratio = totalPhys > 0 ? Double(usedB) / Double(totalPhys) : 0

        // Swap via sysctl("vm.swapusage"): a binary xsw_usage struct.
        var swapB: UInt64? = nil
        var swapSize = 0
        sysctlbyname("vm.swapusage", nil, &swapSize, nil, 0)
        if swapSize >= MemoryLayout<xsw_usage>.size {
            var xsw = xsw_usage()
            if sysctlbyname("vm.swapusage", &xsw, &swapSize, nil, 0) == 0 {
                swapB = xsw.xsu_used
            }
        }

        // Pressure comes from the kernel's own jetsam signal —
        // kern.memorystatus_vm_pressure_level (1 normal, 2 warning, ≥3 critical) —
        // NOT from an occupancy ratio. An almost-full Mac can be under no
        // pressure; the kernel knows the difference and we defer to it.
        // Falls back to an occupancy heuristic only if the sysctl is unavailable.
        var kernelLevel: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        let levelRead = sysctlbyname(
            "kern.memorystatus_vm_pressure_level", &kernelLevel, &levelSize, nil, 0
        ) == 0
        let level: MemoryPressureLevel
        if levelRead, kernelLevel > 0 {
            level = Self.mapPressureLevel(kernelLevel)
        } else {
            let swapPressure: UInt64 = swapB ?? 0
            if ratio >= 0.95 || (swapPressure > 512 * 1024 * 1024 && ratio >= 0.85) {
                level = .critical
            } else if ratio >= 0.85 {
                level = .elevated
            } else {
                level = .normal
            }
        }

        return SystemMemory(
            totalBytes: totalPhys,
            usedBytes: usedB,
            pressureLevel: level,
            pressureRatio: min(ratio, 1.0),
            swapBytes: swapB,
            freeBytes: freeB,
            appBytes: activeB + inactiveB,
            wiredBytes: wiredB,
            compressedBytes: compressedB,
        )
    }

    /// Kernel memorystatus level → Portmaster state. Public for tests.
    public static func mapPressureLevel(_ kernelLevel: Int32) -> MemoryPressureLevel {
        switch kernelLevel {
        case ..<2: .normal
        case 2: .elevated
        default: .critical
        }
    }

    /// Snapshot without delta state — used at first launch when no prior tick exists.
    public static func oneShotCPU() -> SystemCPU? {
        let c = MachSystemCollector()
        _ = c.sampleCPU() // prime
        return c.sampleCPU() // now has delta
    }
}

// libproc-based process enumeration, per-pid metrics, cwd, and procargs2.
// Works for the calling user's processes without any special permission.
import Foundation
import Darwin
import PMShim

public final class LibprocProcessCollector: ProcessCollector {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t(); mach_timebase_info(&value); return value
    }()

    /// Whether the kernel advertises per-process energy accounting at all,
    /// from `ri_energy_nj` on the caller's own pid.
    ///
    /// This is a necessary condition, not a sufficient one. Measured on an M4
    /// Mac mini (macOS 26.6.2): `ri_energy_nj` was non-zero while
    /// `ri_billed_energy` stayed bit-for-bit constant through four seconds of
    /// idling and through two seconds of sustained CPU burn. The kernel
    /// publishes the field and never advances it. Treating this flag as "energy
    /// is being metered" would render that machine as a measured 0, so the flag
    /// only gates whether the counter is worth storing — see
    /// `EnergyRateMonitor` for the question that actually matters.
    public static let kernelAdvertisesEnergyAccounting: Bool = {
        var read: UInt64 = 0, written: UInt64 = 0, billed: UInt64 = 0, serviced: UInt64 = 0, nj: UInt64 = 0
        let ok = pm_rusage_counters(getpid(), &read, &written, &billed, &serviced, &nj) == 0
        return ok && nj > 0
    }()

    public init() {}

    /// PROC_PIDTASKINFO reports Mach absolute-time units, not nanoseconds.
    /// Use quotient/remainder arithmetic so conversion cannot overflow midway.
    static func machTicksToNanos(user: UInt64, system: UInt64, numer: UInt32, denom: UInt32) -> UInt64? {
        guard numer > 0, denom > 0 else { return nil }
        let total = user.saturatingAdd(system)
        let n = UInt64(numer), d = UInt64(denom)
        let (whole, overflow) = (total / d).multipliedReportingOverflow(by: n)
        if overflow { return .max }
        return whole.saturatingAdd((total % d) * n / d)
    }

    public func snapshot() -> ProcessSweep? {
        // Count first, then re-list with headroom: pids appear between calls.
        // CRITICAL: buffersize is measured in BYTES, not elements — passing an
        // element count truncated the sweep to ~¼ of the process table, which
        // silently hid every daemon and long-running service from the app.
        let n = Int(proc_listallpids(nil, 0))
        guard n > 0 else { return nil }
        let capacity = n + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let got = pids.withUnsafeMutableBufferPointer { buf in
            proc_listallpids(buf.baseAddress, Int32(buf.count * MemoryLayout<pid_t>.stride))
        }
        guard got > 0 else { return nil }

        let now = Date()
        var records: [RawProcess] = []
        records.reserveCapacity(Int(got))

        for i in 0..<Int(got) {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var bsd = proc_bsdinfo()
            let bsdRC = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, PM_PROC_PIDTBSDINFO_SIZE)
            guard bsdRC == PM_PROC_PIDTBSDINFO_SIZE else { continue }

            let isZombie = bsd.pbi_flags & PM_PROC_PBI_ZOMBIE != 0
            if isZombie { continue }

            var task = proc_taskinfo()
            let taskRC = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, PM_PROC_PIDTASKINFO_SIZE)
            let hasTask = taskRC == PM_PROC_PIDTASKINFO_SIZE
            let cpuTicks: UInt64 = hasTask ? Self.machTicksToNanos(user: task.pti_total_user, system: task.pti_total_system,
                numer: Self.timebase.numer, denom: Self.timebase.denom) ?? 0 : 0
            let resident: UInt64? = hasTask ? task.pti_resident_size : nil

            // Cumulative disk I/O and energy via proc_pid_rusage (supported
            // libproc API, same permission profile as the calls above). nil
            // when the pid exits mid-sweep — shown as unknown, never zero.
            //
            // One call for both: RUSAGE_INFO_CURRENT is rusage_info_v6 and
            // carries the energy counters beside the disk ones, so a second
            // call per process per sweep would buy nothing.
            var diskRead: UInt64 = 0, diskWrite: UInt64 = 0
            var billedEnergy: UInt64 = 0, servicedEnergy: UInt64 = 0, energyNJ: UInt64 = 0
            let countersOK = pm_rusage_counters(pid, &diskRead, &diskWrite,
                                                 &billedEnergy, &servicedEnergy, &energyNJ) == 0
            let diskOK = countersOK

            // Energy counters ride along with the disk read above.
            //
            // Recorded whenever the kernel offers the field at all
            // (`ri_energy_nj > 0`), NOT gated on the counter being non-zero.
            // That flag says the kernel claims to bill energy; it does not
            // promise the counter ever moves, and on at least one real machine
            // (an M4 Mac mini, macOS 26) it does not: the counter is populated
            // and frozen under a sustained CPU burn. Deciding "no accounting"
            // from a static zero value would report that machine as having
            // measured zero energy, which is a claim nobody can support.
            //
            // Whether these numbers mean anything is settled by whether any
            // counter ever advances — see EnergyRateMonitor, which turns that
            // observation into the machine-level answer the UI needs.
            let energyCounter: UInt64? = (countersOK && energyNJ > 0) ? billedEnergy : nil

            var pathBuf = [CChar](repeating: 0, count: 4096)
            let pathLen = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            let path = pathLen > 0 ? String(cString: pathBuf) : nil

            // pbi_comm is a C char tuple; decode until the first NUL.
            let comm = withUnsafeBytes(of: &bsd.pbi_comm) { raw -> String in
                let bytes = raw.bindMemory(to: UInt8.self)
                let end = bytes.firstIndex(of: 0) ?? bytes.count
                return String(decoding: bytes[..<end], as: UTF8.self)
            }

            // Prefer the executable's file name: pbi_comm truncates at 16
            // chars (MAXCOMLEN), which mangles helper processes like
            // "Google Chrome Helper (Renderer)".
            let name: String
            if let path {
                let base = (path as NSString).lastPathComponent
                name = base.isEmpty ? (comm.isEmpty ? "pid \(pid)" : comm) : base
            } else if !comm.isEmpty {
                name = comm
            } else {
                name = "pid \(pid)"
            }

            let isApp = path?.contains(".app/Contents/MacOS/") == true

            let startedAt: Date? = bsd.pbi_start_tvsec > 0
                ? Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000)
                : nil

            records.append(RawProcess(
                pid: pid,
                parentPid: bsd.pbi_ppid > 0 ? pid_t(bsd.pbi_ppid) : nil,
                name: name,
                cpuTicks: cpuTicks,
                residentBytes: resident,
                startedAt: startedAt,
                isAppBundle: isApp,
                executablePath: path,
                diskReadBytes: diskOK ? diskRead : nil,
                diskWriteBytes: diskOK ? diskWrite : nil,
                billedEnergyNanounits: energyCounter
            ))
        }

        return ProcessSweep(records: records, at: now)
    }

    public func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    public func workingDirectory(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard pm_cwd_path(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    public func commandArguments(pid: pid_t) -> [String]? {
        var args: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        let count = pm_procargs2(pid, &args)
        guard count > 0, let args else { return nil }
        defer { pm_free_args(args, count) }
        var result: [String] = []
        result.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            if let cstr = args[i] {
                result.append(String(cString: cstr))
            }
        }
        return result.isEmpty ? nil : result
    }
}

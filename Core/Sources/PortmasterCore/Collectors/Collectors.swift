// Collector protocols: every system-data surface sits behind one of these
// so unsupported features degrade cleanly and fixtures can replace live data.
import Foundation

/// Machine-wide CPU + memory sampling.
public protocol SystemCollector: Sendable {
    /// Sample machine CPU. Returns nil if the Mach host APIs fail.
    func sampleCPU() -> SystemCPU?
    /// Sample machine memory. Returns nil if unavailable.
    func sampleMemory() -> SystemMemory?
}

/// Enumerates processes with per-process metrics and metadata.
public protocol ProcessCollector: Sendable {
    /// One sweep of all visible processes. Returns nil when enumeration fails.
    func snapshot() -> ProcessSweep?
    /// Full executable path for a pid, when obtainable.
    func executablePath(pid: pid_t) -> String?
    /// Command arguments for a pid (details view; on-device only).
    func commandArguments(pid: pid_t) -> [String]?
    /// Current working directory for a pid, when the kernel exposes it.
    func workingDirectory(pid: pid_t) -> String?
}

/// Result of one process enumeration pass.
public struct ProcessSweep: Sendable {
    /// Raw per-pid records before attribution/tree assembly.
    public var records: [RawProcess]
    public var at: Date

    public init(records: [RawProcess], at: Date) {
        self.records = records
        self.at = at
    }
}

/// One process as the kernel reports it, before enrichment.
public struct RawProcess: Sendable {
    public let pid: pid_t
    public let parentPid: pid_t?
    public let name: String
    public let cpuTicks: UInt64
    public let residentBytes: UInt64?
    public let startedAt: Date?
    /// Bundle-backed app (has an .app path).
    public let isAppBundle: Bool
    public let executablePath: String?
    /// Cumulative disk bytes read/written since process start
    /// (proc_pid_rusage). nil when the kernel did not report them.
    public let diskReadBytes: UInt64?
    public let diskWriteBytes: UInt64?
    /// Cumulative billed energy counter (proc_pid_rusage `rusage_info_v6.ri_billed_energy`).
    /// A counter, not a rate — the sampler differences two sweeps to get one.
    ///
    /// nil means the kernel reported nothing usable, which on most current Macs
    /// means it does not bill energy per process at all. That is distinct from a
    /// process having used none, so it is nil here rather than 0.
    public let billedEnergyNanounits: UInt64?

    public init(
        pid: pid_t, parentPid: pid_t?, name: String, cpuTicks: UInt64,
        residentBytes: UInt64?, startedAt: Date?, isAppBundle: Bool,
        executablePath: String?, diskReadBytes: UInt64? = nil,
        diskWriteBytes: UInt64? = nil,
        billedEnergyNanounits: UInt64? = nil
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.name = name
        self.cpuTicks = cpuTicks
        self.residentBytes = residentBytes
        self.startedAt = startedAt
        self.isAppBundle = isAppBundle
        self.executablePath = executablePath
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.billedEnergyNanounits = billedEnergyNanounits
    }
}

/// Scans for listening TCP ports.
public protocol PortCollector: Sendable {
    /// All listening TCP endpoints. Returns nil if the scanner failed outright
    /// (distinct from an empty list).
    func listeningPorts() -> [ListeningPort]?
}

/// Process control. Isolated so a sandboxed build can ship a stub that reports unsupported.
public protocol ProcessControlling: Sendable {
    /// true when stop actions are supported in this build/distribution mode.
    var isSupported: Bool { get }
    /// Reason stop actions are unavailable, for UI messaging.
    var unsupportedReason: String? { get }
    /// Send a graceful-stop signal. Throws on failure (EPERM, ESRCH, ...).
    func gracefulStop(pid: pid_t) throws
    /// Send an immediate force-quit signal. Throws on failure.
    func forceQuit(pid: pid_t) throws
}

// MARK: - Runtime labels

/// Conservative runtime classification from executable path/name.
public enum RuntimeLabel {
    private static let table: [(String, String)] = [
        ("node", "Node.js"), ("deno", "Deno"), ("bun", "Bun"),
        ("python", "Python"), ("python3", "Python"), ("uvicorn", "Python (uvicorn)"),
        ("gunicorn", "Python (gunicorn)"), ("pip", "Python"),
        ("ruby", "Ruby"), ("puma", "Ruby (Puma)"), ("rails", "Ruby (Rails)"),
        ("java", "Java"), ("gradle", "Gradle"), ("kotlin", "Kotlin"),
        ("go", "Go"), ("gopls", "Go"),
        ("rustc", "Rust"), ("cargo", "Rust (cargo)"),
        ("php", "PHP"), ("php-fpm", "PHP"),
        ("redis", "Redis"), ("memcached", "Memcached"),
        ("postgres", "PostgreSQL"), ("mysql", "MySQL"), ("mariadb", "MariaDB"),
        ("mongod", "MongoDB"), ("sqlite", "SQLite"),
        ("nginx", "nginx"), ("caddy", "Caddy"), ("httpd", "Apache"),
        ("docker", "Docker"), ("containerd", "containerd"), ("com.docker", "Docker"),
        ("colima", "Colima"), ("lima", "Lima"), ("podman", "Podman"), ("orbstack", "OrbStack"),
        ("vite", "Vite"), ("webpack", "webpack"), ("esbuild", "esbuild"),
        ("ollama", "Ollama"), ("llama", "llama.cpp"), ("mlx", "MLX"),
        ("swift", "Swift"), ("swift-frontend", "Swift"), ("sourcekit", "SourceKit"),
        ("xcodebuild", "Xcode Build"), ("xctest", "XCTest"), ("simulator", "Simulator"),
        ("ssh", "SSH"), ("nginx", "nginx"), ("taplo", "Taplo"),
        ("yarn", "Yarn"), ("pnpm", "pnpm"), ("npm", "npm"),
    ]

    /// Best-effort label from a process name or executable path.
    public static func classify(name: String, path: String?) -> String? {
        let lowerName = name.lowercased()
        for (needle, label) in table where lowerName.contains(needle) {
            return label
        }
        if let path {
            let lowerPath = path.lowercased()
            for (needle, label) in table where lowerPath.contains("/\(needle)") {
                return label
            }
        }
        return nil
    }
}

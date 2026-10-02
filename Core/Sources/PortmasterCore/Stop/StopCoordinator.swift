// Stop coordinator: explicit user-initiated graceful stop and force quit.
// Isolated behind ProcessControlling so a sandboxed build can replace it
// with an unsupported stub.
import Foundation
import Darwin

public enum StopError: LocalizedError {
    case notSupported(reason: String)
    case permissionDenied(pid: pid_t)
    case processGone(pid: pid_t)
    case systemFailure(pid: pid_t, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case .notSupported(let reason):
            return reason
        case .permissionDenied(let pid):
            return "macOS denied the signal for PID \(pid). This process belongs to another user or is protected; Portmaster left it untouched."
        case .processGone(let pid):
            return "PID \(pid) already exited before the signal was sent."
        case .systemFailure(let pid, let errno):
            return "The system refused the stop request for PID \(pid) (error \(errno)). The process was not modified."
        }
    }
}

/// Default controller: SIGTERM for graceful, SIGKILL for force.
/// Both require an explicit user action upstream; nothing here is automatic.
public struct KillProcessController: ProcessControlling {
    public let isSupported = true
    public let unsupportedReason: String? = nil

    public init() {}

    public func gracefulStop(pid: pid_t) throws {
        try send(signal: SIGTERM, to: pid)
    }

    public func forceQuit(pid: pid_t) throws {
        try send(signal: SIGKILL, to: pid)
    }

    private func send(signal: Int32, to pid: pid_t) throws {
        // kill(2) is the source of truth. A pre-check via proc_pidinfo would
        // misclassify kernel-protected processes (EPERM there, but alive).
        guard pid > 1, pid != getpid() else { throw StopError.notSupported(reason: "This PID cannot be targeted by Portmaster.") }
        let result = kill(pid, signal)
        if result == 0 { return }

        switch errno {
        case EPERM: throw StopError.permissionDenied(pid: pid)
        case ESRCH: throw StopError.processGone(pid: pid)
        case let e: throw StopError.systemFailure(pid: pid, errno: e)
        }
    }
}

/// Stub for sandboxed builds: reports unsupported, never signals anything.
public struct UnsupportedProcessController: ProcessControlling {
    public let isSupported = false
    public let unsupportedReason: String? =
        "This build of Portmaster runs in the Mac App Store sandbox, which does not permit signaling other processes. Stop actions are disabled."
    public init() {}
    public func gracefulStop(pid: pid_t) throws { throw StopError.notSupported(reason: unsupportedReason ?? "unsupported") }
    public func forceQuit(pid: pid_t) throws { throw StopError.notSupported(reason: unsupportedReason ?? "unsupported") }
}

// MARK: - Stop orchestration with verification

/// Executes a user-approved stop and verifies the outcome. Never runs automatically.
public final class StopCoordinator: Sendable {
    private let controller: ProcessControlling
    /// Grace period before reporting "still running" after SIGTERM.
    private let verifyDelay: TimeInterval

    private let identityLookup: @Sendable (pid_t) -> IdentityState

    public init(controller: ProcessControlling, verifyDelay: TimeInterval = 3.0, identityLookup: @escaping @Sendable (pid_t) -> IdentityState = { StopCoordinator.liveIdentity($0) }) {
        self.controller = controller
        self.verifyDelay = verifyDelay
        self.identityLookup = identityLookup
    }

    public struct Outcome: Sendable {
        public enum Status: Sendable {
            case stopped
            case stillRunning
            case failed(message: String)
        }
        public let status: Status
        public let pid: pid_t
    }

    public enum IdentityState: Sendable { case running(startedAt: Date), gone, unavailable }

    public static func liveIdentity(_ pid: pid_t) -> IdentityState {
        guard pid > 1 else { return .unavailable }
        var bsd = proc_bsdinfo()
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, PM_PROC_PIDTBSDINFO_SIZE)
        guard rc == PM_PROC_PIDTBSDINFO_SIZE else { return errno == ESRCH ? .gone : .unavailable }
        if bsd.pbi_flags & PM_PROC_PBI_ZOMBIE != 0 { return .gone }
        guard bsd.pbi_start_tvsec > 0 else { return .unavailable }
        return .running(startedAt: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000))
    }

    /// Recheck every confirmed identity immediately before its signal. All
    /// signals share one grace period, so a large project doesn't take 3s per PID.
    public func stopConfirmed(_ targets: [ConfirmedProcess], force: Bool) async -> [pid_t: Outcome] {
        var results: [pid_t: Outcome] = [:]
        var signaled: [ConfirmedProcess] = []
        for target in targets where results[target.pid] == nil && !signaled.contains(where: { $0.pid == target.pid }) {
            func fail(_ message: String) { results[target.pid] = Outcome(status: .failed(message: message), pid: target.pid) }
            guard controller.isSupported else { fail(controller.unsupportedReason ?? "Stop actions are unavailable."); continue }
            guard target.pid > 1, target.pid != getpid(), let expected = target.startedAt else {
                fail("PID \(target.pid): identity unavailable or protected; left untouched."); continue
            }
            switch identityLookup(target.pid) {
            case .gone: results[target.pid] = Outcome(status: .stopped, pid: target.pid); continue
            case .unavailable: fail("PID \(target.pid): cannot verify identity; left untouched."); continue
            case .running(let actual):
                guard actual == expected else { fail("PID \(target.pid) now belongs to a different process; left untouched."); continue }
            }
            do {
                if force { try controller.forceQuit(pid: target.pid) } else { try controller.gracefulStop(pid: target.pid) }
                signaled.append(target)
            } catch { fail(error.localizedDescription) }
        }
        if !signaled.isEmpty {
            try? await Task.sleep(nanoseconds: UInt64(max(0, force ? min(0.5, verifyDelay) : verifyDelay) * 1_000_000_000))
        }
        for target in signaled {
            let status: Outcome.Status
            switch identityLookup(target.pid) {
            case .gone: status = .stopped
            case .running(let actual): status = actual == target.startedAt ? .stillRunning : .stopped
            case .unavailable: status = .stillRunning
            }
            results[target.pid] = Outcome(status: status, pid: target.pid)
        }
        return results
    }

    /// Send a graceful stop, then verify within the grace period.
    public func gracefulStop(pid: pid_t) async -> Outcome {
        guard controller.isSupported else {
            return Outcome(status: .failed(message: controller.unsupportedReason ?? "Stop actions are unavailable."), pid: pid)
        }
        do {
            try controller.gracefulStop(pid: pid)
        } catch {
            return Outcome(status: .failed(message: (error as? StopError)?.errorDescription ?? error.localizedDescription), pid: pid)
        }
        return await verifyExit(pid: pid)
    }

    /// Force quit immediately, then verify.
    public func forceQuit(pid: pid_t) async -> Outcome {
        guard controller.isSupported else {
            return Outcome(status: .failed(message: controller.unsupportedReason ?? "Stop actions are unavailable."), pid: pid)
        }
        do {
            try controller.forceQuit(pid: pid)
        } catch {
            return Outcome(status: .failed(message: (error as? StopError)?.errorDescription ?? error.localizedDescription), pid: pid)
        }
        return await verifyExit(pid: pid, delay: 0.5)
    }

    /// Stop a process tree: root first, then all descendants depth-first.
    /// Descendants are resolved live (a flat child list misses nested workers,
    /// and pids die/reparent mid-stop).
    public func stopTree(root: pid_t, children: [pid_t], force: Bool) async -> [pid_t: Outcome] {
        let collector = LibprocProcessCollector()
        var results: [pid_t: Outcome] = [:]

        func stopRecursively(_ pid: pid_t) async {
            guard results[pid] == nil else { return }
            // Resolve children NOW: the sweep's flat list may be stale.
            let kids = Self.descendants(of: pid, using: collector)
            for child in kids {
                await stopRecursively(child)
            }
            results[pid] = force ? await forceQuit(pid: pid) : await gracefulStop(pid: pid)
        }

        await stopRecursively(root)
        // Ensure any explicitly-listed children are covered even if reparented.
        for pid in children where results[pid] == nil {
            results[pid] = force ? await forceQuit(pid: pid) : await gracefulStop(pid: pid)
        }
        return results
    }

    /// All live descendants of a pid, depth-first, from a fresh sweep.
    static func descendants(of root: pid_t, using collector: LibprocProcessCollector) -> [pid_t] {
        guard let sweep = collector.snapshot() else { return [] }
        var childrenOf: [pid_t: [pid_t]] = [:]
        for raw in sweep.records {
            if let ppid = raw.parentPid {
                childrenOf[ppid, default: []].append(raw.pid)
            }
        }
        var result: [pid_t] = []
        var stack: [pid_t] = childrenOf[root] ?? []
        var seen = Set<pid_t>([root])
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            for child in childrenOf[pid] ?? [] where !seen.contains(child) {
                stack.append(child)
            }
        }
        return result
    }

    private func verifyExit(pid: pid_t, delay: TimeInterval? = nil) async -> Outcome {
        try? await Task.sleep(nanoseconds: UInt64((delay ?? verifyDelay) * 1_000_000_000))
        var bsd = proc_bsdinfo()
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, PM_PROC_PIDTBSDINFO_SIZE)
        if rc != PM_PROC_PIDTBSDINFO_SIZE {
            // ESRCH = gone (stopped). Anything else (e.g. EPERM on protected
            // processes) means we cannot verify — report honestly, not optimistically.
            return Outcome(
                status: errno == ESRCH ? .stopped : .stillRunning,
                pid: pid
            )
        }
        // The pid may still exist briefly as a zombie; treat as exited when marked.
        if bsd.pbi_flags & PM_PROC_PBI_ZOMBIE != 0 {
            return Outcome(status: .stopped, pid: pid)
        }
        return Outcome(status: .stillRunning, pid: pid)
    }
}

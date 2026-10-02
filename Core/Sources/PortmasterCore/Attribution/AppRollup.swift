// AppRollup: groups processes under the app that owns them (by .app bundle
// path). Helper processes inherit the host app so users see "60 apps instead
// of 1,000 processes" — the vitalsmac-style information model, original copy.
import Foundation

public struct AppRollup: Identifiable, Hashable, Sendable {
    /// Stable identity: bundle path for apps, executable name otherwise.
    public let id: String
    public let displayName: String
    public var processes: [ProcessRow]
    public let isAppBundle: Bool
    public var projectIDs: Set<String>

    public init(id: String, displayName: String, isAppBundle: Bool) {
        self.id = id
        self.displayName = displayName
        self.processes = []
        self.isAppBundle = isAppBundle
        self.projectIDs = []
    }

    public var totalCPU: Double {
        processes.reduce(0) { $0 + ($1.cpuPercent ?? 0) }
    }

    public var totalMemory: UInt64 {
        processes.reduce(0) { $0 + ($1.memoryBytes ?? 0) }
    }

    public var pidCount: Int { processes.count }

    public var maxProcessCPU: Double {
        processes.map { $0.cpuPercent ?? 0 }.max() ?? 0
    }

    /// Summed per-process disk-write rate. Values are nil until the sampler
    /// has two sweeps to diff, so the sum is meaningful only when non-nil.
    public var totalDiskWriteBytesPerSec: Double? {
        let rates = processes.compactMap { $0.diskWriteBytesPerSec }
        guard rates.count == processes.count, !rates.isEmpty else { return nil }
        return rates.reduce(0, +)
    }

    /// Summed per-process download rate. Rates refresh on nettop's slower
    /// cadence; nil until the first pass has run. A nil on any member means
    /// the sum is unknown, not partial.
    public var totalNetInBytesPerSec: Double? {
        let rates = processes.compactMap { $0.netInBytesPerSec }
        guard rates.count == processes.count, !rates.isEmpty else { return nil }
        return rates.reduce(0, +)
    }

    /// Executable names inside this app, for drill-down lists.
    public var memberNames: [String] {
        var seen = Set<String>()
        return processes.compactMap { p in
            guard seen.insert(p.displayName).inserted else { return nil }
            return p.displayName
        }
    }
}

public enum AppRollupBuilder {
    /// Bundle an executable path belongs to, e.g.
    /// "/Applications/Slack.app/Contents/MacOS/Slack" → "/Applications/Slack.app".
    static func bundleRoot(_ path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func displayName(forBundle bundlePath: String) -> String {
        ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Build rollups from one sweep. CLI/system binaries stay one-per-row
    /// under their own name (they ARE the "app" for dev services).
    public static func build(from rows: [ProcessRow]) -> [AppRollup] {
        var byKey: [String: AppRollup] = [:]
        var order: [String] = []

        for row in rows {
            let bundle = bundleRoot(row.executablePathHint)
            let key: String
            let displayName: String
            let isApp: Bool
            if let bundle {
                key = bundle
                displayName = Self.displayName(forBundle: bundle)
                isApp = true
            } else {
                key = "bin:" + row.displayName
                displayName = row.displayName
                isApp = false
            }

            if byKey[key] == nil {
                byKey[key] = AppRollup(id: key, displayName: displayName, isAppBundle: isApp)
                order.append(key)
            }
            byKey[key]?.processes.append(row)
            if let pid = row.projectID {
                byKey[key]?.projectIDs.insert(pid)
            }
        }

        return order.compactMap { byKey[$0] }
    }
}

/// Project-level summary for the Projects screen: process count, memory, and
/// listening ports for every detected repository. Pure aggregation, testable.
public struct ProjectSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public let processCount: Int
    public let memoryBytes: UInt64
    public let ports: [UInt16]

    public init(id: String, processCount: Int, memoryBytes: UInt64, ports: [UInt16]) {
        self.id = id
        self.processCount = processCount
        self.memoryBytes = memoryBytes
        self.ports = ports
    }

    /// Last path component of the project directory.
    public var displayName: String {
        let name = id.components(separatedBy: "/").last ?? id
        return name.isEmpty ? id : name
    }

    /// One summary per attributed project, sorted by memory (largest first).
    /// Ports join by pid membership; listeners from unattributed processes
    /// (system daemons, unattributed apps) never leak into a project.
    public static func build(
        processes: [ProcessRow], ports: [ListeningPort]
    ) -> [ProjectSummary] {
        let grouped = Dictionary(grouping: processes.filter { $0.projectID != nil }) { $0.projectID! }
        var summaries: [ProjectSummary] = []
        summaries.reserveCapacity(grouped.count)
        for (id, rows) in grouped {
            let pids = Set(rows.map { $0.pid })
            let projectPorts = Array(Set(
                ports.filter { pids.contains($0.pid) }.map { $0.port }
            )).sorted()
            summaries.append(ProjectSummary(
                id: id,
                processCount: rows.count,
                memoryBytes: rows.compactMap { $0.memoryBytes }.reduce(0, +),
                ports: projectPorts
            ))
        }
        return summaries.sorted { $0.memoryBytes > $1.memoryBytes }
    }
}

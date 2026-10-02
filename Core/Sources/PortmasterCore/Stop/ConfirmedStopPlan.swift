import Foundation
import Darwin

public struct ConfirmedProcess: Identifiable, Hashable, Sendable {
    public let pid: pid_t
    public let name: String
    public let startedAt: Date?
    public var id: pid_t { pid }
    public init(pid: pid_t, name: String, startedAt: Date?) { self.pid = pid; self.name = name; self.startedAt = startedAt }
}

/// Frozen confirmation membership: newly spawned or reparented processes are
/// never silently added after the user reviewed the list.
public enum ConfirmedStopPlan {
    public static func project(_ id: String, rows: [ProcessRow], ownPID: pid_t = getpid()) -> [ConfirmedProcess] {
        ordered(rows.filter { $0.projectID == id }, ownPID: ownPID)
    }
    public static func process(_ root: pid_t, rows: [ProcessRow], ownPID: pid_t = getpid()) -> [ConfirmedProcess] {
        var included = Set([root]); var changed = true
        while changed {
            changed = false
            for row in rows where row.parentPid.map(included.contains) == true {
                if included.insert(row.pid).inserted { changed = true }
            }
        }
        return ordered(rows.filter { included.contains($0.pid) }, ownPID: ownPID)
    }
    public static func ordered(_ rows: [ProcessRow], ownPID: pid_t = getpid()) -> [ConfirmedProcess] {
        var unique: [pid_t: ProcessRow] = [:]
        for row in rows where row.pid > 1 && row.pid != ownPID { unique[row.pid] = row }
        func depth(_ row: ProcessRow) -> Int {
            var cursor = row; var seen = Set([cursor.pid]); var result = 0
            while let parent = cursor.parentPid, let next = unique[parent], seen.insert(parent).inserted {
                result += 1; cursor = next
            }
            return result
        }
        return unique.values.sorted { depth($0) == depth($1) ? $0.pid < $1.pid : depth($0) > depth($1) }
            .map { ConfirmedProcess(pid: $0.pid, name: $0.displayName, startedAt: $0.startedAt) }
    }
}

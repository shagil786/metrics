// Project attribution: maps processes to project/repository identities using
// working directories and open-file paths. Best-effort; "Unattributed" is the
// honest label when evidence is missing.
import Foundation
import Darwin

public struct ProjectIdentity: Hashable, Sendable, Identifiable {
    /// Stable id derived from the root directory path.
    public let id: String
    /// Display name (repo folder name, e.g. "portmaster").
    public let name: String
    /// Root directory of the detected project.
    public let rootPath: String
    /// What evidence produced this attribution.
    public let evidence: String

    public init(id: String, name: String, rootPath: String, evidence: String) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.evidence = evidence
    }
}

public final class ProjectAttributor: @unchecked Sendable {
    /// Directory names treated as project roots when found in a cwd chain.
    private let projectMarkers: Set<String> = [
        ".git", "Package.swift", "project.yml", "Cargo.toml", "go.mod",
        "pyproject.toml", "setup.py", "package.json", "Gemfile", "pom.xml",
        "build.gradle", "Makefile", "CMakeLists.txt", "Podfile", "compose.yml",
        "docker-compose.yml", ".hg", ".svn",
    ]

    /// Repos cached per root path so ids stay stable within a session.
    private var cache: [String: (identity: ProjectIdentity?, checkedAt: Date)] = [:]
    private let lock = NSLock()

    public init() {}

    /// Attribute a process to a project using its working directory.
    /// Returns nil when the cwd is unknown or not inside a recognizable project.
    public func attribute(cwd: String?, executablePath: String? = nil) -> ProjectIdentity? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return project(forDirectory: cwd, evidence: "working directory")
    }

    /// Walk up from a directory looking for project markers. Caches results.
    public func project(forDirectory dir: String, evidence: String) -> ProjectIdentity? {
        lock.lock()
        if let hit = cache[dir], hit.identity != nil || Date().timeIntervalSince(hit.checkedAt) < 30 {
            lock.unlock()
            return hit.identity
        }
        lock.unlock()

        let resolved = Self.withoutTrailingSlash(dir)
        var current = resolved
        var found: ProjectIdentity?

        // Bounded walk: at most 8 levels up from the cwd.
        for _ in 0..<8 {
            let marker = Self.containsMarker(at: current, markers: projectMarkers)
            if marker {
                let name = (current as NSString).lastPathComponent
                let identity = ProjectIdentity(
                    id: "proj:" + current,
                    name: name.isEmpty ? current : name,
                    rootPath: current,
                    evidence: evidence
                )
                found = identity
                break
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty || parent == "/" {
                break
            }
            current = parent
        }

        lock.lock()
        cache[dir] = (found, Date())
        lock.unlock()
        return found
    }

    /// Enrich a sweep: attach project ids and assemble parent/child groupings.
    public func enrich(
        records: [RawProcess],
        workingDirectories: [pid_t: String],
        previous: [pid_t: ProcessRow]? = nil
    ) -> (rows: [ProcessRow], projects: [ProjectIdentity]) {
        var projects: [String: ProjectIdentity] = [:]
        var rows: [ProcessRow] = []
        rows.reserveCapacity(records.count)

        // CPU percent requires two sweeps; on the first, ticks are present but
        // percent is genuinely unknown (nil, not zero).
        for raw in records {
            var projectID: String?
            if let cwd = workingDirectories[raw.pid] {
                if let proj = project(forDirectory: cwd, evidence: "working directory") {
                    projectID = proj.id
                    projects[proj.id] = proj
                }
            }
            rows.append(ProcessRow(
                pid: raw.pid,
                name: raw.name,
                parentPid: raw.parentPid,
                children: [],
                isAppBundle: raw.isAppBundle,
                cpuPercent: nil,
                memoryBytes: raw.residentBytes,
                startedAt: raw.startedAt,
                cpuTicks: raw.cpuTicks > 0 ? raw.cpuTicks : nil,
                diskReadBytes: raw.diskReadBytes,
                diskWriteBytes: raw.diskWriteBytes,
                lifecycle: .continuing,
                projectID: projectID,
                executablePathHint: raw.executablePath
            ))
        }

        // Attach direct children.
        var byParent: [pid_t: [pid_t]] = [:]
        for row in rows {
            if let ppid = row.parentPid { byParent[ppid, default: []].append(row.pid) }
        }
        rows = rows.map { row in
            var r = row
            r.children = byParent[row.pid] ?? []
            return r
        }

        return (rows, projects.values.sorted { $0.name < $1.name })
    }

    static func withoutTrailingSlash(_ p: String) -> String {
        p.hasSuffix("/") && p.count > 1 ? String(p.dropLast()) : p
    }

    static func containsMarker(at dir: String, markers: Set<String>) -> Bool {
        // Enumerating a cwd can open cloud placeholders and stall the entire
        // sampling lane. Probe only the known marker names, without listing it.
        return markers.contains { marker in
            var info = stat()
            return lstat((dir as NSString).appendingPathComponent(marker), &info) == 0
        }
    }
}

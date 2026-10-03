// Docker containers via the docker CLI (`docker ps` + `docker stats`),
// same supported-subprocess policy as lsof/nettop/pmset: fixed argv, no
// user-controlled interpolation, hard timeout. Everything degrades
// honestly when Docker is absent or the daemon is down — availability is
// reported, never guessed.
import Foundation
import Darwin

public enum DockerAvailability: Hashable, Sendable {
    /// No docker binary found in the standard locations.
    case notInstalled
    /// Binary exists but the daemon did not answer (Docker Desktop stopped).
    case daemonDown
    /// Daemon answered; `containers` is authoritative (possibly empty).
    case running
}

public struct DockerContainer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let image: String
    /// Status verbatim from docker ("Up 8 minutes", "Exited (0) 2 days ago").
    public let statusText: String
    /// Published host ports, sorted ascending.
    public let ports: [UInt16]
    /// Live CPU percent from `docker stats --no-stream`; nil until a stats
    /// pass completes for this container.
    public let cpuPercent: Double?
    /// Resident memory in use (the left side of docker stats' "used/limit").
    public let memoryBytes: UInt64?
    public let networkInBytesPerSec: Double?
    public let networkOutBytesPerSec: Double?
    public let diskReadBytesPerSec: Double?
    public let diskWriteBytesPerSec: Double?

    public init(
        id: String, name: String, image: String, statusText: String,
        ports: [UInt16], cpuPercent: Double?, memoryBytes: UInt64?,
        networkInBytesPerSec: Double? = nil, networkOutBytesPerSec: Double? = nil,
        diskReadBytesPerSec: Double? = nil, diskWriteBytesPerSec: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.image = image
        self.statusText = statusText
        self.ports = ports
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.networkInBytesPerSec = networkInBytesPerSec
        self.networkOutBytesPerSec = networkOutBytesPerSec
        self.diskReadBytesPerSec = diskReadBytesPerSec
        self.diskWriteBytesPerSec = diskWriteBytesPerSec
    }

    /// "Up 8 minutes" → true; exited containers are not running.
    public var isRunning: Bool {
        statusText.lowercased().hasPrefix("up")
    }
}

public struct DockerSample: Hashable, Sendable {
    public let at: Date
    public let availability: DockerAvailability
    public let containers: [DockerContainer]

    public init(availability: DockerAvailability, containers: [DockerContainer], at: Date = Date()) {
        self.at = at
        self.availability = availability
        self.containers = containers
    }

    public var totalMemoryBytes: UInt64 {
        containers.reduce(0) { total, c in
            let (sum, overflow) = total.addingReportingOverflow(c.memoryBytes ?? 0)
            return overflow ? UInt64.max : sum
        }
    }

    public var runningContainers: [DockerContainer] {
        containers.filter(\.isRunning)
    }
}

public protocol DockerProviding: Sendable {
    func sample() -> DockerSample
}

public final class DockerCollector: DockerProviding, @unchecked Sendable {
    /// Standard docker CLI locations: Apple Silicon and Intel Homebrew,
    /// Docker Desktop symlinks, OrbStack. Newer CLIs live under ~/.docker/bin.
    static let candidatePaths: [String] = [
        "/opt/homebrew/bin/docker",
        "/usr/local/bin/docker",
        "/usr/bin/docker",
        NSHomeDirectory() + "/.docker/bin/docker",
        NSHomeDirectory() + "/.orbstack/bin/docker",
    ]

    private let samplingLock = NSLock()
    private var commandOverride: (([String]) -> String?)?
    private var clock: () -> Date = Date.init
    private var previousIO: [String: DockerIOCounters] = [:]
    private var previousAt: Date?
    private let timeoutSeconds: Double
    private let statsTimeoutSeconds: Double

    public init(timeoutSeconds: Double = 6, statsTimeoutSeconds: Double = 20) {
        self.timeoutSeconds = timeoutSeconds
        self.statsTimeoutSeconds = statsTimeoutSeconds
    }

    /// Deterministic subprocess and clock seam for collector integration tests.
    init(command: @escaping ([String]) -> String?, now: @escaping () -> Date) {
        timeoutSeconds = 6
        statsTimeoutSeconds = 20
        commandOverride = command
        clock = now
    }

    /// The docker CLI on this machine, or nil when there is none.
    /// Public so a caller that has to *run* docker (not just sample it) resolves
    /// the same paths this collector does rather than keeping a second list.
    public static func locate() -> String? {
        candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func sample() -> DockerSample {
        samplingLock.lock()
        defer { samplingLock.unlock() }
        guard let dockerPath = commandOverride == nil ? Self.locate() : "test" else {
            previousIO = [:]; previousAt = nil
            return DockerSample(availability: .notInstalled, containers: [])
        }

        guard let psOut = run(
            dockerPath,
            ["ps", "--all", "--no-trunc", "--format", "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"],
            timeoutSeconds: timeoutSeconds
        ) else {
            previousIO = [:]; previousAt = nil
            return DockerSample(availability: .daemonDown, containers: [])
        }

        var containers = Self.parsePS(psOut)
        // Stats only for containers that are actually up; --no-stream takes
        // a second or two per pass, acceptable on the slow lane.
        var at = clock()
        var nextIO: [String: DockerIOCounters] = [:]
        let upNames = containers.filter(\.isRunning).map(\.name)
        if !upNames.isEmpty,
           let statsOut = run(
            dockerPath,
            ["stats", "--no-stream", "--no-trunc", "--format", "{{.ID}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}"],
            timeoutSeconds: statsTimeoutSeconds
           ) {
            at = clock()
            let stats = Self.parseStats(statsOut)
            let io = Self.parseIO(statsOut)
            containers = containers.map { c in
                guard c.isRunning, let s = stats[c.id] else { return c }
                let counters = io[c.id]
                if let counters { nextIO[c.id] = counters }
                let rates = counters?.rates(since: previousIO[c.id], seconds: previousAt.map { at.timeIntervalSince($0) } ?? 0)
                return DockerContainer(
                    id: c.id, name: c.name, image: c.image, statusText: c.statusText,
                    ports: c.ports, cpuPercent: s.cpu, memoryBytes: s.mem,
                    networkInBytesPerSec: rates?.networkIn, networkOutBytesPerSec: rates?.networkOut,
                    diskReadBytesPerSec: rates?.diskRead, diskWriteBytesPerSec: rates?.diskWrite
                )
            }
        }
        previousIO = nextIO
        previousAt = at
        return DockerSample(availability: .running, containers: containers, at: at)
    }

    /// Run docker with fixed argv. Returns stdout when the exit status is 0;
    /// nil on any failure (missing daemon, timeout, crash) — callers map nil
    /// to daemonDown, never to fabricated data.
    private func run(_ path: String, _ arguments: [String], timeoutSeconds: Double) -> String? {
        if let commandOverride { return commandOverride(arguments) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments

        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
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
        let forceTimeout = DispatchWorkItem { [weak proc] in
            if let proc, proc.isRunning { _ = Darwin.kill(proc.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds + 2, execute: forceTimeout
        )
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeoutSeconds, execute: timedOut
        )

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        timedOut.cancel()
        forceTimeout.cancel()

        guard proc.terminationReason != .uncaughtSignal else { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stop only an immutable container ID, after the UI's confirmation.
    public func stop(id: String) -> Bool {
        guard let path = Self.locate() else { return false }
        return Self.performStop(id: id) { args in
            run(path, args, timeoutSeconds: args.first == "stop" ? 20 : 6)
        }
    }

    static func performStop(id: String, run: ([String]) -> String?) -> Bool {
        guard validContainerID(id),
              run(["stop", "--timeout", "10", id]) != nil,
              let state = run(["inspect", "--format", "{{.State.Running}}", id])
        else { return false }
        return state.trimmingCharacters(in: .whitespacesAndNewlines) == "false"
    }

    static func validContainerID(_ id: String) -> Bool {
        (id.count == 12 || id.count == 64) && id.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    static func parseIO(_ text: String) -> [String: DockerIOCounters] {
        var result: [String: DockerIOCounters] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 5 else { continue }
            let net = fields[3].components(separatedBy: "/")
            let disk = fields[4].components(separatedBy: "/")
            guard net.count == 2, disk.count == 2,
                  let ni = bytes(net[0]), let no = bytes(net[1]),
                  let dr = bytes(disk[0]), let dw = bytes(disk[1]) else { continue }
            result[fields[0]] = DockerIOCounters(networkIn: ni, networkOut: no, diskRead: dr, diskWrite: dw)
        }
        return result
    }

    // MARK: - Parsing

    /// Parse `docker ps --format` TSV: id, name, image, status, ports.
    /// Published host ports come from the "0.0.0.0:5671->5671/tcp" mappings.
    static func parsePS(_ text: String) -> [DockerContainer] {
        var results: [DockerContainer] = []
        for line in text.split(separator: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 5 else { continue }
            let id = fields[0].trimmingCharacters(in: .whitespaces)
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            let image = fields[2].trimmingCharacters(in: .whitespaces)
            let status = fields[3].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !name.isEmpty else { continue }
            results.append(DockerContainer(
                id: id, name: name, image: image, statusText: status,
                ports: publishedPorts(fields[4]), cpuPercent: nil, memoryBytes: nil
            ))
        }
        return results
    }

    /// Host-side published ports from a docker ps PORTS column.
    static func publishedPorts(_ column: String) -> [UInt16] {
        var found = Set<UInt16>()
        var scanner = Substring(column)
        // Matches ":5671->" — the host port of each published mapping.
        while let arrow = scanner.range(of: "->") {
            let before = scanner[..<arrow.lowerBound]
            if let colon = before.lastIndex(of: ":"),
               let port = UInt16(before[before.index(after: colon)...]) {
                found.insert(port)
            }
            scanner = scanner[arrow.upperBound...]
        }
        return found.sorted()
    }

    /// Parse `docker stats --no-stream --format` TSV: name, "0.10%",
    /// "190.4MiB / 7.656GiB". First field is the caller-selected ID or name.
    static func parseStats(_ text: String) -> [String: (cpu: Double, mem: UInt64)] {
        var results: [String: (cpu: Double, mem: UInt64)] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 3 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  let cpu = percent(fields[1]),
                  let mem = bytes(fields[2])
            else { continue }
            results[name] = (cpu, mem)
        }
        return results
    }

    /// Docker CPU percent may exceed 100 on a multi-core host.
    static func percent(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("%") else { return nil }
        guard let value = Double(trimmed.dropLast()), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// "190.4MiB / 7.656GiB" → the in-use side, in bytes.
    static func bytes(_ s: String) -> UInt64? {
        guard let usage = s.split(separator: "/").first else { return nil }
        let token = usage.trimmingCharacters(in: .whitespaces)
        // Split trailing unit from the number.
        let units: [(String, Double)] = [
            ("KiB", 1024), ("MiB", 1_048_576), ("GiB", 1_073_741_824), ("TiB", 1_099_511_627_776),
            ("kB", 1_000), ("MB", 1_000_000), ("GB", 1_000_000_000), ("B", 1),
        ]
        for (suffix, factor) in units {
            if token.hasSuffix(suffix) {
                guard let value = Double(token.dropLast(suffix.count)) else { return nil }
                let scaled = value * factor
                guard scaled.isFinite, scaled >= 0, scaled < Double(UInt64.max) else { return nil }
                return UInt64(scaled)
            }
        }
        return nil
    }
}

/// A missing baseline or a reset is unknown, never lifetime traffic presented as a rate.
struct DockerIOCounters {
    let networkIn: UInt64
    let networkOut: UInt64
    let diskRead: UInt64
    let diskWrite: UInt64

    func rates(since prior: Self?, seconds: Double) -> (networkIn: Double?, networkOut: Double?, diskRead: Double?, diskWrite: Double?) {
        func diff(_ current: UInt64, _ old: UInt64?) -> Double? {
            guard let old, current >= old, seconds.isFinite, seconds > 0 else { return nil }
            return Double(current - old) / seconds
        }
        return (diff(networkIn, prior?.networkIn), diff(networkOut, prior?.networkOut),
                diff(diskRead, prior?.diskRead), diff(diskWrite, prior?.diskWrite))
    }
}

public struct DockerHistory {
    public struct Point: Identifiable {
        public let at: Date
        public let containerID: String
        public let name: String
        public let memoryBytes: UInt64?
        public let networkBytesPerSec: Double?
        public let diskBytesPerSec: Double?
        public var id: String { "\(containerID)-\(at.timeIntervalSince1970)" }
    }
    public private(set) var points: [Point] = []
    private var lastAt: Date?
    public init() {}
    public mutating func append(_ sample: DockerSample) {
        guard lastAt != sample.at else { return }
        lastAt = sample.at
        for c in sample.runningContainers {
            points.append(Point(at: sample.at, containerID: c.id, name: c.name,
                                memoryBytes: c.memoryBytes,
                                networkBytesPerSec: c.networkInBytesPerSec.flatMap { i in c.networkOutBytesPerSec.map { i + $0 } },
                                diskBytesPerSec: c.diskReadBytesPerSec.flatMap { i in c.diskWriteBytesPerSec.map { i + $0 } }))
        }
        // Session history bounded by time and count, including many-container hosts.
        points.removeAll { $0.at < sample.at.addingTimeInterval(-1800) }
        if points.count > 7200 { points.removeFirst(points.count - 7200) }
    }
}

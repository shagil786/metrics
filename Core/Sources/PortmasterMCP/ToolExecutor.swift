// ToolExecutor: the MCP tool surface. Every call goes catalog → argument
// validation → permission gate (mutations only) → provider → JSON.
//
// Two invariants worth stating, because they are the whole security story:
//  1. The read/mutation decision comes from the catalog's `effect`, never from
//     anything a caller sent. A caller cannot ask to be treated as a read.
//  2. A denied mutation returns before the provider is touched, so there is no
//     code path in which a gate denial still performs the action.
import Foundation
import PortmasterCore

// MARK: - Wire payloads
//
// PortmasterCore's models are display models, not wire models, and are not
// `Codable`. These payloads are the MCP contract: flat, stable, and honest —
// an unmeasured value stays `null` rather than becoming a zero.

private struct CPUPayload: Encodable {
    let totalPercent: Double
    let userPercent: Double
    let systemPercent: Double
    let idlePercent: Double
    let coreCount: Int
    let corePercents: [Double]

    init(_ cpu: SystemCPU) {
        totalPercent = cpu.totalPercent
        userPercent = cpu.userPercent
        systemPercent = cpu.systemPercent
        idlePercent = cpu.idlePercent
        coreCount = cpu.coreCount
        corePercents = cpu.corePercents
    }
}

private struct MemoryPayload: Encodable {
    let totalBytes: UInt64
    let usedBytes: UInt64
    let pressureLevel: String
    let pressureRatio: Double
    let swapBytes: UInt64?
    let freeBytes: UInt64?
    let appBytes: UInt64?
    let wiredBytes: UInt64?
    let compressedBytes: UInt64?

    init(_ memory: SystemMemory) {
        totalBytes = memory.totalBytes
        usedBytes = memory.usedBytes
        pressureLevel = memory.pressureLevel.rawValue
        pressureRatio = memory.pressureRatio
        swapBytes = memory.swapBytes
        freeBytes = memory.freeBytes
        appBytes = memory.appBytes
        wiredBytes = memory.wiredBytes
        compressedBytes = memory.compressedBytes
    }
}

private struct NetworkPayload: Encodable {
    let downBytesPerSec: Double
    let upBytesPerSec: Double

    init(_ network: NetworkSample) {
        downBytesPerSec = network.downBytesPerSec
        upBytesPerSec = network.upBytesPerSec
    }
}

private struct DiskPayload: Encodable {
    let freeBytes: UInt64
    let totalBytes: UInt64
    let readBytesPerSec: Double?
    let writeBytesPerSec: Double?

    init(_ disk: DiskSample) {
        freeBytes = disk.freeBytes
        totalBytes = disk.totalBytes
        readBytesPerSec = disk.readBytesPerSec
        writeBytesPerSec = disk.writeBytesPerSec
    }
}

private struct BatteryPayload: Encodable {
    let percentage: Double?
    let timeToEmptyMinutes: Int?
    let isCharging: Bool
    let source: String
    let wattage: Double?
    let healthPercent: Double?
    let cycleCount: Int?

    init(_ battery: BatterySample) {
        percentage = battery.percentage
        timeToEmptyMinutes = battery.timeToEmptyMinutes
        isCharging = battery.isCharging
        source = battery.source.rawValue
        wattage = battery.wattage
        healthPercent = battery.healthPercent
        cycleCount = battery.cycleCount
    }
}

private struct GPUPayload: Encodable {
    let utilizationPercent: Double?
    let rendererPercent: Double?
    let tilerPercent: Double?
    let inUseMemoryBytes: UInt64?
    let coreCount: Int?

    init(_ gpu: GPUSample) {
        utilizationPercent = gpu.utilizationPercent
        rendererPercent = gpu.rendererPercent
        tilerPercent = gpu.tilerPercent
        inUseMemoryBytes = gpu.inUseMemoryBytes
        coreCount = gpu.coreCount
    }
}

private struct FanPayload: Encodable {
    let name: String?
    let currentRPM: Double?

    init(_ fan: FanSample) {
        name = fan.name
        currentRPM = fan.currentRPM
    }
}

private struct ThermalPayload: Encodable {
    let cpuTempC: Double?
    let gpuTempC: Double?
    let hottestTempC: Double?
    let fans: [FanPayload]

    init(_ thermal: ThermalSample) {
        cpuTempC = thermal.cpuTempC
        gpuTempC = thermal.gpuTempC
        hottestTempC = thermal.hottestTempC
        fans = thermal.fans.map(FanPayload.init)
    }
}

private struct SystemOverviewPayload: Encodable {
    let at: Date
    let cpu: CPUPayload
    let memory: MemoryPayload
    let network: NetworkPayload?
    let disk: DiskPayload?
    let battery: BatteryPayload?
    let gpu: GPUPayload?
    let thermal: ThermalPayload?

    init(_ sample: SystemSample) {
        at = sample.at
        cpu = CPUPayload(sample.cpu)
        memory = MemoryPayload(sample.memory)
        network = sample.network.map(NetworkPayload.init)
        disk = sample.disk.map(DiskPayload.init)
        battery = sample.battery.map(BatteryPayload.init)
        gpu = sample.gpu.map(GPUPayload.init)
        thermal = sample.thermal.map(ThermalPayload.init)
    }
}

private struct ProcessPayload: Encodable {
    let pid: Int32
    let name: String
    let isAppBundle: Bool
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let projectID: String?
    let lifecycle: String
    let netInBytesPerSec: Double?
    let netOutBytesPerSec: Double?
    let diskReadBytesPerSec: Double?
    let diskWriteBytesPerSec: Double?

    init(_ process: ProcessRow) {
        pid = process.pid
        name = process.displayName
        isAppBundle = process.isAppBundle
        cpuPercent = process.cpuPercent
        memoryBytes = process.memoryBytes
        projectID = process.projectID
        switch process.lifecycle {
        case .continuing: lifecycle = "continuing"
        case .exited: lifecycle = "exited"
        case .reused: lifecycle = "reused"
        }
        netInBytesPerSec = process.netInBytesPerSec
        netOutBytesPerSec = process.netOutBytesPerSec
        diskReadBytesPerSec = process.diskReadBytesPerSec
        diskWriteBytesPerSec = process.diskWriteBytesPerSec
    }
}

private struct AppRollupPayload: Encodable {
    let id: String
    let displayName: String
    let isAppBundle: Bool
    let pidCount: Int
    /// Sorted so the payload is byte-stable for a given snapshot.
    let projectIDs: [String]
    let totalCPU: Double
    let totalMemory: UInt64
    let netInBytesPerSec: Double?
    let diskWriteBytesPerSec: Double?
    let processes: [ProcessPayload]

    init(_ rollup: AppRollup) {
        id = rollup.id
        displayName = rollup.displayName
        isAppBundle = rollup.isAppBundle
        pidCount = rollup.pidCount
        projectIDs = rollup.projectIDs.sorted()
        totalCPU = rollup.totalCPU
        totalMemory = rollup.totalMemory
        netInBytesPerSec = rollup.totalNetInBytesPerSec
        diskWriteBytesPerSec = rollup.totalDiskWriteBytesPerSec
        processes = rollup.processes.map(ProcessPayload.init)
    }
}

private struct ContainerPayload: Encodable {
    let id: String
    let name: String
    let image: String
    let statusText: String
    let isRunning: Bool
    let ports: [Int]
    let cpuPercent: Double?
    let memoryBytes: UInt64?
    let networkInBytesPerSec: Double?
    let networkOutBytesPerSec: Double?
    let diskReadBytesPerSec: Double?
    let diskWriteBytesPerSec: Double?

    init(_ container: DockerContainer) {
        id = container.id
        name = container.name
        image = container.image
        statusText = container.statusText
        isRunning = container.isRunning
        ports = container.ports.map(Int.init)
        cpuPercent = container.cpuPercent
        memoryBytes = container.memoryBytes
        networkInBytesPerSec = container.networkInBytesPerSec
        networkOutBytesPerSec = container.networkOutBytesPerSec
        diskReadBytesPerSec = container.diskReadBytesPerSec
        diskWriteBytesPerSec = container.diskWriteBytesPerSec
    }
}

/// Docker availability travels as a plain string beside the container list, so
/// "Docker is not installed", "the daemon is down", and "here are zero
/// containers" are three answers a caller can tell apart. The first two are
/// states of the machine, not failures of the call — hence no error flag.
private struct ContainersPayload: Encodable {
    let at: Date
    let availability: String
    let containers: [ContainerPayload]

    init(_ sample: DockerSample) {
        at = sample.at
        switch sample.availability {
        case .notInstalled: availability = "notInstalled"
        case .daemonDown: availability = "daemonDown"
        case .running: availability = "running"
        }
        containers = sample.containers.map(ContainerPayload.init)
    }
}

/// One recorded app's totals over the requested window. `averageCPU` is nil
/// whenever no time was actually observed — an unobserved app must not read as
/// an idle one.
private struct HistoryTrendPayload: Encodable {
    let id: String
    let displayName: String
    let cpuSeconds: Double
    let observedSeconds: Double
    let averageCPU: Double?
    let peakMemory: Int64
    let lastSeen: Date

    init(_ trend: AppHistoryTrend) {
        id = trend.id
        displayName = trend.displayName
        cpuSeconds = trend.cpuSeconds
        observedSeconds = trend.observedSeconds
        averageCPU = trend.averageCPU
        peakMemory = trend.peakMemory
        lastSeen = trend.lastSeen
    }
}

/// Uniform shape for sensors: `available` false means "this machine reports no
/// SMC sensor", and every reading is then null rather than a fabricated zero.
private struct TemperaturesPayload: Encodable {
    let available: Bool
    let cpuTempC: Double?
    let gpuTempC: Double?
    let hottestTempC: Double?
    let fans: [FanPayload]

    init(_ thermal: ThermalSample?) {
        available = thermal != nil
        cpuTempC = thermal?.cpuTempC
        gpuTempC = thermal?.gpuTempC
        hottestTempC = thermal?.hottestTempC
        fans = thermal?.fans.map(FanPayload.init) ?? []
    }
}

/// One alert. Provenance is not per alert but per call, so it rides on
/// `AlertsPayload` beside the list rather than being repeated on each entry.
private struct AlertPayload: Encodable {
    let id: String
    let kind: String
    let appName: String
    let headline: String
    let detail: String
    let at: Date

    init(_ alert: ActingUpAlert) {
        id = alert.id
        kind = alert.kind.rawValue
        appName = alert.appName
        headline = alert.headline
        detail = alert.detail
        at = alert.at
    }
}

/// Alerts plus where they came from, and the source is present even when the
/// list is empty. That is the whole reason this is an object and not a bare
/// array: an empty array cannot tell a caller that the live engine ran and found
/// nothing from one that has not been able to answer at all.
private struct AlertsPayload: Encodable {
    let source: String
    let alerts: [AlertPayload]

    init(_ snapshot: AlertsSnapshot) {
        source = snapshot.source.rawValue
        alerts = snapshot.alerts.map(AlertPayload.init)
    }
}

/// One recorded reading of a single resource. `value` stays null when the sensor
/// had nothing to report: the line breaks there rather than drawing a zero.
private struct ResourceHistoryPointPayload: Encodable {
    let at: Date
    let metric: String
    let value: Double?

    init(_ point: ResourceHistoryPoint) {
        at = point.at
        metric = point.metric
        value = point.value
    }
}

// MARK: - Outcome

/// What a tool call returns to the MCP host: text plus whether it failed.
public struct ToolOutcome: Sendable {
    public let text: String
    public let isError: Bool

    public init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }
}

// MARK: - Catalog

/// Whether a tool observes or changes the machine. The executor asks the
/// catalog — never the caller — before consulting `PermissionGate`.
public enum ToolEffect: String, Sendable {
    case read
    case mutation
}

/// One entry of `tools/list`.
public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let arguments: [(name: String, required: Bool, help: String)]
    public let effect: ToolEffect
}

// MARK: - Executor

public struct ToolExecutor: Sendable {
    private let provider: DataProvider
    private let gate: PermissionGate
    private let audit: AuditLog

    public init(provider: DataProvider, gate: PermissionGate, audit: AuditLog) {
        self.provider = provider
        self.gate = gate
        self.audit = audit
    }

    /// All 13 tools the MCP server exposes. Names wired into dispatch stay in
    /// step with this list, because `execute` refuses anything not declared here.
    public static let catalog: [ToolDefinition] = [
        // Reads
        ToolDefinition(
            name: "get_system_overview",
            description: "Current machine state: CPU, memory, network throughput, "
                + "disk capacity and I/O, battery, GPU, and temperatures.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_top_apps",
            description: "Apps ranked by one metric, highest first. Metrics whose "
                + "rate has not been measured yet sort last, never as zero.",
            arguments: [
                (name: "metric", required: true, help: "cpu | memory | network | disk"),
                (name: "limit", required: false, help: "How many apps to return (1-100, default 10)")
            ],
            effect: .read
        ),
        ToolDefinition(
            name: "get_app_detail",
            description: "One app's totals plus a per-process breakdown.",
            arguments: [
                (name: "id", required: true, help: "App id from get_top_apps")
            ],
            effect: .read
        ),
        ToolDefinition(
            name: "get_containers",
            description: "Docker containers and whether Docker is installed, "
                + "with the daemon running, or down.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_projects",
            description: "Detected repositories with their process counts and "
                + "listening ports.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_history_rankings",
            description: "Apps ranked by recorded CPU time over a window.",
            arguments: [
                (name: "range", required: true, help: "1h | 12h | 24h | 7d | 30d"),
                (name: "resource", required: false, help: "HistoryResource raw value")
            ],
            effect: .read
        ),
        ToolDefinition(
            name: "get_temperatures_fans",
            description: "CPU/GPU/hottest sensor temperatures and fan RPMs. "
                + "Reports unavailable rather than guessing when sensors are absent.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_active_alerts",
            description: "Freshly evaluated 'this app is acting up' observations.",
            arguments: [],
            effect: .read
        ),
        ToolDefinition(
            name: "get_settings",
            description: "Current preferences, including the MCP mutation mode.",
            arguments: [],
            effect: .read
        ),
        // Mutations — every one of these is default-deny and audit-logged.
        ToolDefinition(
            name: "quit_app",
            description: "Quit an app's processes, verifying each pid's identity "
                + "immediately before signalling.",
            arguments: [
                (name: "id", required: true, help: "App id from get_top_apps"),
                (name: "force", required: false, help: "true | false (default false)")
            ],
            effect: .mutation
        ),
        ToolDefinition(
            name: "stop_container",
            description: "Stop a running Docker container.",
            arguments: [
                (name: "id", required: true, help: "Container id from get_containers")
            ],
            effect: .mutation
        ),
        ToolDefinition(
            name: "stop_project",
            description: "Stop every process belonging to a detected project, "
                + "with membership checks.",
            arguments: [
                (name: "id", required: true, help: "Project id from get_projects")
            ],
            effect: .mutation
        ),
        ToolDefinition(
            name: "set_preference",
            description: "Change one allowlisted preference. Keys outside the "
                + "allowlist are rejected, not ignored.",
            arguments: [
                (name: "key", required: true, help: "Allowlisted preference key"),
                (name: "value", required: true, help: "New value for that key")
            ],
            effect: .mutation
        )
    ]

    /// Largest number of apps `get_top_apps` will return for one call. Bounds a
    /// single response so a client cannot ask for an unbounded payload.
    public static let maxTopApps = 100

    /// Runs one tool call.
    ///
    /// Failure is data, not a thrown error: every problem comes back as a
    /// `ToolOutcome` with `isError` set, so the MCP host never has to guess.
    ///
    /// Audit vocabulary, one line per mutation attempt: `denied` (the gate
    /// refused, so no provider call happened and the line is written before any
    /// provider call), `allowed` / `failed` (written after the provider call
    /// returns). For an attempt that reached the provider the log therefore
    /// answers "did the stop actually work?" — not merely "was it permitted?".
    /// It cannot answer that for a denial, which never reached the action.
    public func execute(name: String, arguments: [String: String]) async -> ToolOutcome {
        guard let tool = Self.catalog.first(where: { $0.name == name }) else {
            return ToolOutcome(text: "Unknown tool: \(name)", isError: true)
        }
        // Trim once, here. The value that is validated must be the value that is
        // used and audited — a `" foo "` that passes a trim-based emptiness
        // check and is then looked up untrimmed would make the audit line
        // disagree with what was actually acted on. Absent and blank are the
        // same failure to a caller, so both report a missing argument.
        var normalized = arguments
        for argument in tool.arguments {
            guard let value = normalized[argument.name] else {
                if argument.required {
                    return ToolOutcome(
                        text: "Missing argument: \(argument.name)", isError: true
                    )
                }
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !argument.required else {
                return ToolOutcome(text: "Missing argument: \(argument.name)", isError: true)
            }
            normalized[argument.name] = trimmed
        }

        let isMutation = tool.effect == .mutation
        if isMutation, case .deny(let reason) = gate.decide(isMutation: true) {
            audit.record(tool: name, arguments: normalized, outcome: "denied", reason: reason)
            return ToolOutcome(text: reason, isError: true)
        }

        do {
            let payload = try await dispatch(tool, arguments: normalized)
            let text = try Self.encode(payload)
            if isMutation {
                audit.record(
                    tool: name, arguments: normalized, outcome: "allowed", reason: nil
                )
            }
            return ToolOutcome(text: text, isError: false)
        } catch {
            let reason = Self.failureText(for: error, tool: name)
            if isMutation {
                audit.record(tool: name, arguments: normalized, outcome: "failed", reason: reason)
            }
            return ToolOutcome(text: reason, isError: true)
        }
    }

    /// The caller-facing text for a failed call. A provider that throws a plain
    /// Swift error would otherwise render as `localizedDescription`'s
    /// "The operation couldn't be completed. (Module.Error error 1.)", so
    /// providers are expected to wrap failures in `MCPToolError`.
    private static func failureText(for error: Error, tool: String) -> String {
        switch error {
        case let error as MCPToolError:
            return error.message
        case let error as EncodingError:
            return "Could not encode \(tool) result: \(error)"
        default:
            return error.localizedDescription
        }
    }

    // MARK: Dispatch

    private func dispatch(
        _ tool: ToolDefinition, arguments: [String: String]
    ) async throws -> any Encodable {
        switch tool.name {
        case "get_system_overview":
            return SystemOverviewPayload(try await provider.systemOverview())

        case "get_top_apps":
            let metric = try Self.requireMetric(arguments["metric"])
            let limit = try Self.limit(arguments["limit"])
            let rollups = try await provider.topApps(metric: metric, limit: limit)
            // The provider may pre-filter for cost, but the executor is the one
            // place that decides "the top N by this metric", so it truncates.
            return Self.rank(rollups, by: metric).prefix(limit).map(AppRollupPayload.init)

        case "get_app_detail":
            return AppRollupPayload(try await provider.appDetail(id: Self.id(arguments)))

        case "get_containers":
            return ContainersPayload(try await provider.containers())

        case "get_projects":
            return try await provider.projects()

        case "get_history_rankings":
            // Both arguments are checked before the provider is touched, so an
            // unusable window or resource never reads history.
            let window = try Self.requireWindow(arguments["range"])
            if let resource = try Self.optionalResource(arguments["resource"]) {
                // A resource reading belongs to no app, so it is returned as the
                // recorded point it is. Reusing `AppHistoryTrend` here would
                // invent the app the reading was never attributed to.
                return try await provider.historyResources(window: window, resource: resource)
                    .map(ResourceHistoryPointPayload.init)
            }
            return try await provider.historyRankings(window: window, resource: nil)
                .map(HistoryTrendPayload.init)

        case "get_temperatures_fans":
            return TemperaturesPayload(try await provider.temperaturesFans())

        case "get_active_alerts":
            return AlertsPayload(try await provider.activeAlerts())

        case "get_settings":
            return provider.settingsSnapshot()

        case "quit_app":
            return try await provider.quitApp(id: Self.id(arguments), force: Self.flag(arguments))

        case "stop_container":
            return try await provider.stopContainer(id: Self.id(arguments))

        case "stop_project":
            return try await provider.stopProject(id: Self.id(arguments))

        // Declared in the catalog so `tools/list` is complete, but not yet wired:
        // `set_preference` (Task 5).
        default:
            throw MCPToolError(message: "Tool not implemented yet")
        }
    }

    // MARK: Argument parsing

    private static func id(_ arguments: [String: String]) -> String {
        arguments["id"] ?? ""
    }

    private static func flag(_ arguments: [String: String]) -> Bool {
        arguments["force"].map { $0.lowercased() == "true" } ?? false
    }

    private static func requireMetric(_ raw: String?) throws -> AppMetric {
        guard let raw, let metric = AppMetric(rawValue: raw) else {
            throw MCPToolError(message: "Invalid metric: \(raw ?? "")")
        }
        return metric
    }

    private static func requireWindow(_ raw: String?) throws -> HistoryWindow {
        guard let raw, let window = HistoryWindow(rawValue: raw) else {
            throw MCPToolError(message: "Invalid range: \(raw ?? "")")
        }
        return window
    }

    /// Absent means "no resource": the caller wants app trends. A value that is
    /// present but unknown is rejected rather than quietly dropped, because
    /// silently answering with app trends would look like the resource was
    /// honoured.
    private static func optionalResource(_ raw: String?) throws -> HistoryResource? {
        guard let raw else { return nil }
        guard let resource = HistoryResource(rawValue: raw) else {
            throw MCPToolError(message: "Invalid resource: \(raw)")
        }
        return resource
    }

    private static func limit(_ raw: String?) throws -> Int {
        guard let raw else { return 10 }
        guard let limit = Int(raw), limit > 0, limit <= maxTopApps else {
            throw MCPToolError(message: "Invalid limit: \(raw) (must be 1...\(maxTopApps))")
        }
        return limit
    }

    // MARK: Ranking

    /// Orders rollups by the requested metric, highest first. A nil total means
    /// "not measured yet" and sorts last — reading it as zero would rank an
    /// unmeasured app above a slow one, which reads as a fact about the app.
    private static func rank(_ rollups: [AppRollup], by metric: AppMetric) -> [AppRollup] {
        let total: (AppRollup) -> Double?
        switch metric {
        case .cpu: total = { $0.totalCPU }
        case .memory: total = { Double($0.totalMemory) }
        case .network: total = { $0.totalNetInBytesPerSec }
        case .disk: total = { $0.totalDiskWriteBytesPerSec }
        }
        return rollups.sorted { lhs, rhs in
            switch (total(lhs), total(rhs)) {
            case let (left?, right?):
                return left == right ? lhs.displayName < rhs.displayName : left > right
            case (nil, nil):
                return lhs.displayName < rhs.displayName
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            }
        }
    }

    // MARK: Encoding

    /// Sorted keys and unescaped slashes keep payloads byte-stable, so tests and
    /// humans diffing two calls for the same snapshot see the same text.
    private static func encode(_ payload: any Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPToolError(message: "Result was not valid UTF-8.")
        }
        return text
    }
}

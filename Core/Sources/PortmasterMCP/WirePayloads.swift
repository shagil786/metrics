// WirePayloads: the MCP wire contract.
//
// PortmasterCore's models are display models, not wire models, and several are
// not `Codable` at all. These payloads are the flat, stable, honest translation
// the host sees: an unmeasured value stays `null` rather than becoming a zero,
// and a subsystem that is unavailable reports that fact as data.
//
// They live apart from `ToolExecutor` because they are pure data: no gate, no audit
// log, no dispatch. The executor names exactly two of them —
// `SystemOverviewPayload` and `AppRollupPayload` — and every other type here exists
// only as one of those two's fields.
//
// Internal rather than private throughout, because `Encodable`'s synthesized
// conformance can only encode properties visible at the conforming type's own access
// level: a `private` field inside an internal struct would be silently dropped from
// the JSON rather than refused by the compiler.
import Foundation
import PortmasterCore

// MARK: - The machine snapshot
//
// PortmasterCore's models are display models, not wire models, and several are not
// `Codable` at all. The payloads below are the MCP contract: flat, stable, and
// honest — an unmeasured value stays `null` rather than becoming a zero, and a
// subsystem that is unavailable reports that fact as data.
//
// They live apart from `ToolExecutor` because they are pure data: no gate, no audit
// log, no dispatch. Visibility is per struct rather than one blanket level, because
// only the types the executor names need to be reachable from it.

// MARK: The overview's slice of one system sample.

struct CPUPayload: Encodable {
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

struct MemoryPayload: Encodable {
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

struct NetworkPayload: Encodable {
    let downBytesPerSec: Double
    let upBytesPerSec: Double

    init(_ network: NetworkSample) {
        downBytesPerSec = network.downBytesPerSec
        upBytesPerSec = network.upBytesPerSec
    }
}

struct DiskPayload: Encodable {
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

struct BatteryPayload: Encodable {
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

struct GPUPayload: Encodable {
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

struct FanPayload: Encodable {
    let name: String?
    let currentRPM: Double?

    init(_ fan: FanSample) {
        name = fan.name
        currentRPM = fan.currentRPM
    }
}

// `TemperaturesPayload` below answers the same sensors with the same three states;
// this one is the overview's slice of the same sample, where the surrounding sections
// are independently optional. It therefore carries `availability` too: the section's
// own presence says only that a pass has answered, not that the sensors produced
// readings, so the state has to be named or a caller would read presence as
// availability.
struct ThermalPayload: Encodable {
    let availability: String
    let available: Bool
    let cpuTempC: Double?
    let gpuTempC: Double?
    let hottestTempC: Double?
    let fans: [FanPayload]

    init(_ thermal: ThermalSample) {
        switch thermal.availability {
        case .available: availability = "available"
        case .noSensors: availability = "noSensors"
        case .notSampledYet: availability = "notSampledYet"
        }
        available = thermal.availability == .available
        cpuTempC = thermal.cpuTempC
        gpuTempC = thermal.gpuTempC
        hottestTempC = thermal.hottestTempC
        fans = thermal.fans.map(FanPayload.init)
    }
}

struct SystemOverviewPayload: Encodable {
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

// MARK: - The app rollup
//
// `get_top_apps` and `get_app_detail` answer with this, so it carries the per-process
// breakdown rather than totals alone: the id is what a caller passes to a mutation, so
// an app whose membership is not visible would be un-actionable.

struct ProcessPayload: Encodable {
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

struct AppRollupPayload: Encodable {
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

// MARK: - The reads with their own shape

struct ContainerPayload: Encodable {
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
struct ContainersPayload: Encodable {
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
struct HistoryTrendPayload: Encodable {
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

/// Uniform shape for sensors.
///
/// `availability` names which of the three sensor answers this payload carries,
/// the same plain string `ContainersPayload` uses, so "the sensors answered
/// nothing" and "the sensor pass has not reported yet" are states a caller can
/// tell apart. Only the second is ever an error: the provider refuses it, so a
/// payload always describes an observation. `available` stays for callers that
/// read only the flag, and is derived from `availability` rather than from the
/// readings — a payload must never claim availability and its numbers disagree.
///
/// The synthesized `Encodable` **omits** nil keys rather than emitting `null`, so
/// a sensor that did not answer is absent entirely — never a fabricated zero.
/// Anything reading these must treat a missing reading as unavailable rather
/// than defaulting it.
struct TemperaturesPayload: Encodable {
    let availability: String
    let available: Bool
    let cpuTempC: Double?
    let gpuTempC: Double?
    let hottestTempC: Double?
    let fans: [FanPayload]

    init(_ thermal: ThermalSample) {
        // `notSampledYet` is unreachable through the provider, which refuses it;
        // it is encoded rather than faked so a payload built elsewhere still
        // says what it carries.
        switch thermal.availability {
        case .available: availability = "available"
        case .noSensors: availability = "noSensors"
        case .notSampledYet: availability = "notSampledYet"
        }
        available = thermal.availability == .available
        cpuTempC = thermal.cpuTempC
        gpuTempC = thermal.gpuTempC
        hottestTempC = thermal.hottestTempC
        fans = thermal.fans.map(FanPayload.init)
    }
}

/// One alert. Provenance is not per alert but per call, so it rides on
/// `AlertsPayload` beside the list rather than being repeated on each entry.
struct AlertPayload: Encodable {
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
struct AlertsPayload: Encodable {
    let source: String
    let alerts: [AlertPayload]

    init(_ snapshot: AlertsSnapshot) {
        source = snapshot.source.rawValue
        alerts = snapshot.alerts.map(AlertPayload.init)
    }
}

/// The answer to `report_usage`. `recorded` is always true here — a refusal
/// arrives as a tool error, not as a payload saying `false`, because "Portmaster
/// declined to store this" and "this tool succeeded" must not be the same wire
/// shape for a caller reading them programmatically.
struct AgentUsageRecordedPayload: Encodable {
    let recorded: Bool
    let note: String

    init(note: String) {
        self.recorded = true
        self.note = note
    }
}

/// One recorded reading of a single resource. When the sensor had nothing to
/// report the synthesized `Encodable` omits `value` rather than emitting `null`,
/// so an unavailable reading is an absent key and the line breaks there instead
/// of dropping to zero. Consumers must check for the key's absence.
struct ResourceHistoryPointPayload: Encodable {
    let at: Date
    let metric: String
    let value: Double?

    init(_ point: ResourceHistoryPoint) {
        at = point.at
        metric = point.metric
        value = point.value
    }
}

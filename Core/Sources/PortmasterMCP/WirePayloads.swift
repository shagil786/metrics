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

// MARK: - Agent sessions

/// One session's usage as one entry per model, with the absence kept distinct from a
/// measured zero.
///
/// `segments` is **absent** for every not-reported case — `JSONEncoder` omits a nil
/// optional rather than writing `null` — and `reason` names which one. A caller cannot
/// read the missing list as "zero tokens", which would say a session was free when in
/// fact nobody counted it. That distinction is the whole reason `TokenUsage` is a
/// three-state value, and it would be lost the moment this payload collapsed to two
/// integers.
///
/// **Summing `segments` is the session's token count, counting all four components on
/// each entry** — `inputTokens`, `outputTokens`, `cacheReadTokens` and `reasoningTokens`,
/// because that is the set `cost` prices and a total missing two of them describes less
/// work than the money on the same payload. One entry per model, holding the
/// one reading Portmaster believes — the same choice `TokenUsage.preferredProvenance`
/// makes when costing, and the same one the Overview card makes, because two sources
/// measuring one piece of work are alternative readings of it and adding them counts the
/// session twice. A second reader of a model is therefore **not** a second segment: it
/// rides on that segment's `alternateTotals`, where it is visible and cannot be added.
///
/// **The sum under-reports a contested model, and a client has to notice.** Those entries
/// are listed with null counts, so a client that adds `seg["inputTokens"] ?? 0` drops that
/// model's tokens and gets a smaller total with nothing in the number saying so. Null
/// counts are the signal to look for rather than zero-fill: the same models are named by
/// `cost.reason == "conflict"`, and both readings of each are in `alternateTotals`, so a
/// client that wants a total it can defend checks for nulls before it adds anything up.
///
/// **There is no session-wide total and no session-wide provenance.** A session can run
/// two models, so one pair of counts would have to discard one of them — and a single
/// `provenance` naming a total would name it for figures no source produced: two models
/// counted by two sources have no common origin, and the one that sorts first is not the
/// one that saw all of it. Each segment names the source of its own counts.
struct TokenUsagePayload: Encodable {
    let reported: Bool
    /// One entry per model. Never empty for a reported session: a model whose readers
    /// disagree past the costing tolerance is reported with **null** counts rather than
    /// dropped, so the model is still visible and its absence still cannot read as zero.
    let segments: [SegmentPayload]?
    /// Why no figure exists: `noSource`, `logUnreadable`, `unrecognizedFormat`,
    /// `awaitingFirstReport`, `ambiguousMatch`. Present only when `reported` is false.
    let reason: String?

    /// **Precondition: `segments` is non-empty.** `aggregating` is what guarantees it —
    /// no records folds to `.notReported(.awaitingFirstReport)` rather than an empty
    /// `.reported`. Hand-built otherwise, the `.reported` branch below emits
    /// `reported: true` with an empty list, which is the exact shape this payload
    /// exists not to produce: a client reads that as a session that reported and used
    /// nothing.
    ///
    /// `cost` is read for its `conflict` case alone, and for that case only through
    /// `believableSegments` — the same resolution the Overview card runs, so the wire and
    /// the card cannot reach different verdicts about which models two readers could not
    /// agree on. The costing pass has already applied the tolerance; a second disagreement
    /// rule here would be a third answer to one question.
    init(_ usage: TokenUsage, cost: SessionCost) {
        let resolved = usage.believableSegments(cost: cost)
        switch usage {
        case .reported(let allReadings):
            self.reported = true
            self.segments = resolved.segments.map {
                SegmentPayload(
                    $0,
                    sessionReadings: allReadings,
                    isContested: resolved.contestedModels.contains($0.modelID)
                )
            }
            self.reason = nil
        case .notReported(let reason):
            self.reported = false
            self.segments = nil
            self.reason = reason.rawValue
        }
    }
}

/// One model's share of a session, with the source Portmaster believes for it.
///
/// `provenance` is per-segment rather than on the session, where it would have to
/// describe a figure that may span two sources: a number whose origin is unknown cannot
/// be audited, and a number with *several* origins cannot be labelled with one of them.
/// It is null for exactly one case — a model whose readers disagree past the costing
/// tolerance — and null there means what it means everywhere else in this file: nobody
/// can say.
struct SegmentPayload: Encodable {
    let model: String
    /// Null for a contested model, never 0: tokens were counted, but no reading of them
    /// can be believed, and a 0 would claim the session spent nothing.
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadTokens: Int?
    let reasoningTokens: Int?
    let provenance: String?
    /// Other readers' totals for **this same model**, keyed by provenance. They measure
    /// the same work as the counts above and must never be added to them — which is why
    /// they hang off the segment rather than sitting beside it in a list a client could
    /// append to the one it is summing. Absent when only one source reported the model;
    /// on a contested segment, whose counts are null, they are the only numbers there are.
    let alternateTotals: [String: Int]?

    /// `sessionReadings` is every segment the fold produced for this session, so the
    /// alternates for one model are found there rather than inferred from the segment
    /// that survived.
    init(
        _ segment: TokenUsageSegment,
        sessionReadings: [TokenUsageSegment],
        isContested: Bool
    ) {
        let sameModel = sessionReadings.filter { $0.modelID == segment.modelID }
        self.model = segment.modelID
        if isContested {
            // Both readings, because neither is the one the counts below came from —
            // there is no such one. Omitting the surviving reading would be the same
            // arbitrary choice the segment is refusing to make.
            self.inputTokens = nil
            self.outputTokens = nil
            self.cacheReadTokens = nil
            self.reasoningTokens = nil
            self.provenance = nil
            self.alternateTotals = Self.totals(sameModel)
        } else {
            self.inputTokens = segment.input
            self.outputTokens = segment.output
            self.cacheReadTokens = segment.cacheRead
            self.reasoningTokens = segment.reasoning
            self.provenance = segment.provenance.rawValue
            // Every reading of this model *except* the one these counts came from: that
            // one is already in them, and repeating it would invite the very double count
            // this field exists to prevent.
            self.alternateTotals = Self.totals(
                sameModel.filter { $0.provenance != segment.provenance }
            )
        }
    }

    /// Keyed by the provenance's raw value because a Swift enum is not a
    /// `CodingKey`-friendly JSON dictionary key, and a client reading this has no way to
    /// resolve `selfReported` to itself.
    ///
    /// Each value is input plus output, deliberately excluding cache reads and reasoning:
    /// that is the figure the disagreement rule compares, so it is the one an alternate
    /// has to be measured in to be worth showing.
    ///
    /// **The limit that leaves is that a parse's cache volume is unrecoverable.** A
    /// self-report that never mentions cache reads and a parse reporting 50,000 of them
    /// have the same `comparableTotal`, so the two do not disagree, the self-report wins,
    /// and the session is priced without the cache reads — a difference in what was
    /// billed that nothing on this wire can audit, because the reading that would show it
    /// reports only the figure it shares with the other. `cost.lines` shows what *was*
    /// billed, so the gap is visible as money; it is not visible as tokens. Widening this
    /// to all four components would make it auditable and would stop it being the figure
    /// the disagreement rule compares, so the limit is stated here rather than papered over.
    private static func totals(_ segments: [TokenUsageSegment]) -> [String: Int]? {
        guard !segments.isEmpty else { return nil }
        return segments.reduce(into: [String: Int]()) {
            $0[$1.provenance.rawValue] = $1.comparableTotal
        }
    }
}

/// A session's cost, with `notPriced` and `conflict` distinct from a priced zero.
struct SessionCostPayload: Encodable {
    let priced: Bool
    /// A string, not a JSON number: binary floating point cannot carry money and a
    /// decimal string round-trips through any client unchanged.
    let usd: String?
    /// The newest price table version **this figure actually multiplied**, never the
    /// table's current one — that would renumber the figure whenever an unrelated
    /// model's price was edited. `0` when no price was needed, which is a real case: a
    /// session whose every component count is zero spends nothing under any price, so
    /// there is no entry to name. A client must not read `0` as a broken table.
    let priceTableVersion: Int?
    /// `unpriced`, `conflict`, or `noUsage` when `priced` is false.
    let reason: String?
    /// The models that have no price, so a client can go and enter one. Populated for
    /// `unpriced` only: the models that *disagreed* are named by `disagreements`, which
    /// carries their numbers too, and a second list of the same ids would be a second
    /// answer to one question.
    let models: [String]?
    /// The per-model split behind the total, so a client can show a total as its parts:
    /// an escalated session priced as one number hides that two rates were involved.
    let lines: [CostLinePayload]?
    /// The same models counted differently by two sources, with **both** totals, so a
    /// client can put the choice to the user rather than merely asserting a
    /// disagreement. These are the models this cost refused to bill, which is why `usage`
    /// carries null counts for the same models rather than one reader's number as though
    /// it had settled anything.
    let disagreements: [DisagreementPayload]?

    init(_ cost: SessionCost) {
        switch cost {
        case .priced(let usd, let version, let lines):
            self.priced = true
            self.usd = NSDecimalNumber(decimal: usd).stringValue
            self.priceTableVersion = version
            self.reason = nil
            self.models = nil
            self.lines = lines.map(CostLinePayload.init)
            self.disagreements = nil
        case .notPriced(let models):
            self.priced = false
            self.usd = nil
            self.priceTableVersion = nil
            self.reason = "unpriced"
            self.models = models
            // A line behind a total that does not exist would be a figure with nothing
            // to add up to.
            self.lines = nil
            self.disagreements = nil
        case .conflict(let disagreements):
            self.priced = false
            self.usd = nil
            self.priceTableVersion = nil
            self.reason = "conflict"
            self.models = nil
            self.lines = nil
            self.disagreements = disagreements.map(DisagreementPayload.init)
        case .noUsage:
            self.priced = false
            self.usd = nil
            self.priceTableVersion = nil
            self.reason = "noUsage"
            self.models = nil
            self.lines = nil
            self.disagreements = nil
        }
    }
}

/// One model's share of a priced session. A decimal string for the same reason the
/// total is one: a JSON number would let a client round a money figure on its way out.
struct CostLinePayload: Encodable {
    let model: String
    let usd: String

    init(_ line: CostLine) {
        self.model = line.modelID
        self.usd = NSDecimalNumber(decimal: line.usd).stringValue
    }
}

/// One model's two readings, side by side.
struct DisagreementPayload: Encodable {
    let model: String
    /// Newest total per source, keyed by provenance. Both numbers, because the user is
    /// being asked to choose between them.
    let totals: [String: Int]

    init(_ disagreement: UsageDisagreement) {
        self.model = disagreement.modelID
        // Re-keyed by the provenance's raw value because a Swift enum is not a
        // `CodingKey`-friendly JSON dictionary key, and a client reading this has no
        // way to resolve `selfReported` to itself.
        self.totals = disagreement.totals.reduce(into: [String: Int]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
    }
}

struct AgentSessionPayload: Encodable {
    let id: String
    /// Omitted when the kernel would not say. `LOCAL_PEERPID` is a `getsockopt`
    /// that can simply fail, and 0 is a plausible-looking pid — every other
    /// optional in this file is left out rather than zero-filled, and an AI client
    /// reading this payload has no way to know 0 means "unknown". The same rule
    /// `MCPSettingsCopy` follows when it renders a process as "not known".
    let peerPID: Int32?
    /// First / worst numeric `tokens left` observed for this session. Omitted from
    /// the JSON when no reading exists — a client that shows `0` here is misreading
    /// the contract.
    public let tokensLeftFirst: Int?
    public let tokensLeftWorst: Int?
    /// Chain edges (spec §4). Omitted when nil: an unlinked session has no
    /// edge, and a JSON `null` here would read as "chain known to be absent"
    /// rather than "not linked" — the same rule as every other optional.
    let handedOffFrom: String?
    let handedOffTo: String?
    /// Always nil on the socket path today: the MCP SDK consumes the `initialize`
    /// handshake, so nothing in the host sees a client name. Carried anyway so a
    /// payload built elsewhere with one does not lose it.
    let clientName: String?
    let clientVersion: String?
    let connectedAt: Date
    /// Whether the host currently has this connection open, read from the host's
    /// live connection set at call time (`MCPHostController.connectedSessionIDs`).
    /// There is
    /// no `endedAt` on the wire because nothing observes a socket closing, and a
    /// payload that implied one would be inventing a fact.
    let isOpen: Bool
    let usage: TokenUsagePayload
    let cost: SessionCostPayload

    init(_ session: AgentSessionSnapshot, isOpen: Bool) {
        self.id = session.id.uuidString
        self.peerPID = session.peerPID > 0 ? session.peerPID : nil
        self.tokensLeftFirst = session.tokensLeftFirst
        self.tokensLeftWorst = session.tokensLeftWorst
        self.handedOffFrom = session.handedOffFrom?.uuidString
        self.handedOffTo = session.handedOffTo?.uuidString
        self.clientName = session.clientName
        self.clientVersion = session.clientVersion
        self.connectedAt = session.connectedAt
        self.isOpen = isOpen
        self.usage = TokenUsagePayload(session.usage, cost: session.cost)
        self.cost = SessionCostPayload(session.cost)
    }
}

struct AgentSessionsPayload: Encodable {
    let sessions: [AgentSessionPayload]
    /// Whether the store could be opened at all. False means the list is not
    /// "no sessions" but "nothing could be read", and a caller that collapses the
    /// two would tell a user they have no agent history when the database simply
    /// would not open.
    let storeAvailable: Bool
    let note: String?

    init(sessions: [AgentSessionPayload], storeAvailable: Bool, note: String?) {
        self.sessions = sessions
        self.storeAvailable = storeAvailable
        self.note = note
    }
}

// MARK: - Model prices

/// One price, as the surfaces show it.
///
/// `price` is a decimal string for the same reason a cost is: a JSON number would
/// let a client round a money figure, and these are the inputs every cost is
/// computed from.
struct ModelPricePayload: Encodable {
    let modelID: String
    let component: String
    let price: String
    let tableVersion: Int

    init(_ entry: AgentSessionStore.ModelPrice) {
        self.modelID = entry.modelID
        self.component = entry.component.rawValue
        self.price = NSDecimalNumber(decimal: entry.pricePerToken).stringValue
        self.tableVersion = entry.tableVersion
    }
}

struct ModelPricesPayload: Encodable {
    let prices: [ModelPricePayload]
    /// Models seen in recorded usage with no input price.
    ///
    /// A separate field rather than something inferred from `prices`: a client
    /// cannot tell "you have priced two models" from "these three sessions are
    /// costing nothing" without it, and the second is the one worth acting on.
    let missingPricesFor: [String]

    init(prices: [ModelPricePayload], missingPricesFor: [String]) {
        self.prices = prices
        self.missingPricesFor = missingPricesFor
    }
}

struct ModelPriceSetPayload: Encodable {
    let saved: Bool
    let note: String

    init(note: String) {
        self.saved = true
        self.note = note
    }
}

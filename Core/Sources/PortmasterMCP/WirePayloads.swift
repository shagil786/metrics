// WirePayloads: the MCP wire contract for the reads that have their own shape.
//
// PortmasterCore's models are display models, not wire models, and several are
// not `Codable` at all. These payloads are the flat, stable, honest translation
// the host sees: an unmeasured value stays `null` rather than becoming a zero,
// and a subsystem that is unavailable reports that fact as data.
//
// They live apart from `ToolExecutor` because they are pure data: no gate, no
// audit log, no dispatch. Internal rather than private so `ToolExecutor` and
// this file can see each other (`TemperaturesPayload` embeds `FanPayload`).
import Foundation
import PortmasterCore

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

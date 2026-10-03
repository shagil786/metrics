import Foundation
import SwiftData

/// Canonical stored units; display preferences never change saved readings.
public enum HistoryResource: String, CaseIterable, Sendable, Identifiable {
    case gpu, download, upload, diskRead, diskWrite, battery, watts, cpuTemperature, gpuTemperature, hottestTemperature, fan
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .gpu: "GPU %"; case .download: "Download"; case .upload: "Upload"
        case .diskRead: "Disk reads"; case .diskWrite: "Disk writes"
        case .battery: "Battery %"; case .watts: "Battery draw (W)"
        case .cpuTemperature: "CPU temperature"; case .gpuTemperature: "GPU temperature"
        case .hottestTemperature: "Hottest sensor"; case .fan: "Fastest fan (RPM)"
        }
    }
    public func reading(in sample: SystemSample) -> Double? {
        let value: Double?
        switch self {
        case .gpu: value = sample.gpu?.utilizationPercent
        case .download: value = sample.network?.downBytesPerSec
        case .upload: value = sample.network?.upBytesPerSec
        case .diskRead: value = sample.disk?.readBytesPerSec
        case .diskWrite: value = sample.disk?.writeBytesPerSec
        case .battery: value = sample.battery?.percentage
        case .watts: value = sample.battery?.wattage
        case .cpuTemperature: value = sample.thermal?.cpuTempC
        case .gpuTemperature: value = sample.thermal?.gpuTempC
        case .hottestTemperature: value = sample.thermal?.hottestTempC
        case .fan: value = sample.thermal?.fans.compactMap(\.currentRPM).max()
        }
        return value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}

@Model public final class ResourceHistoryPoint {
    public var at: Date
    public var metric: String
    /// nil is an unavailable reading and breaks the plotted line.
    public var value: Double?
    public init(at: Date, metric: String, value: Double?) {
        self.at = at; self.metric = metric; self.value = value
    }
}

/// New table leaves the original per-process schema and records intact.
@Model public final class AppHistoryPoint {
    public var at: Date
    public var appID: String
    public var displayName: String
    public var cpuSeconds: Double
    public var observedSeconds: Double
    public var memoryBytes: Int64?
    public var download: Double?
    public var upload: Double?
    public var diskRead: Double?
    public var diskWrite: Double?
    public init(at: Date, app: AppRollup, interval: TimeInterval) {
        self.at = at; self.appID = app.id; self.displayName = app.displayName
        // Cold starts, pauses, and sleep gaps contribute no fabricated duration.
        let duration = interval.isFinite && interval > 0 && interval <= 120 ? interval : 0
        let validCPU = !app.processes.isEmpty && app.processes.allSatisfy { $0.cpuPercent?.isFinite == true }
        self.observedSeconds = validCPU ? duration : 0
        self.cpuSeconds = validCPU ? max(0, app.totalCPU) / 100 * duration : 0
        let memory = app.processes.compactMap(\.memoryBytes)
        self.memoryBytes = memory.count == app.processes.count && !memory.isEmpty
            ? Int64(clamping: memory.reduce(UInt64(0)) { $0.saturatingAdd($1) }) : nil
        func rate(_ field: KeyPath<ProcessRow, Double?>) -> Double? {
            let values = app.processes.compactMap { $0[keyPath: field] }
            guard values.count == app.processes.count, !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            let sum = values.reduce(0, +); return sum.isFinite ? sum : nil
        }
        download = rate(\.netInBytesPerSec); upload = rate(\.netOutBytesPerSec)
        diskRead = rate(\.diskReadBytesPerSec); diskWrite = rate(\.diskWriteBytesPerSec)
    }
}

public struct AppHistoryTrend: Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var cpuSeconds: Double = 0
    public var observedSeconds: Double = 0
    public var peakMemory: Int64 = 0
    public var lastSeen: Date
    public var averageCPU: Double? { observedSeconds > 0 ? cpuSeconds / observedSeconds * 100 : nil }
    /// Clip the first recorded interval to the selected viewing window.
    public static func aggregate(_ points: [AppHistoryPoint], since: Date) -> [Self] {
        var grouped: [String: Self] = [:]
        for point in points where point.at >= since {
            var trend = grouped[point.appID] ?? Self(id: point.appID, displayName: point.displayName, lastSeen: point.at)
            let covered = max(0, min(point.observedSeconds, point.at.timeIntervalSince(since)))
            let ratio = point.observedSeconds > 0 ? covered / point.observedSeconds : 0
            trend.cpuSeconds += point.cpuSeconds * ratio
            trend.observedSeconds += covered
            if let memory = point.memoryBytes { trend.peakMemory = max(trend.peakMemory, memory) }
            if point.at >= trend.lastSeen { trend.displayName = point.displayName; trend.lastSeen = point.at }
            grouped[point.appID] = trend
        }
        return grouped.values.sorted { $0.cpuSeconds == $1.cpuSeconds ? $0.id < $1.id : $0.cpuSeconds > $1.cpuSeconds }
    }
}

/// One app's memory footprint at the first and last recorded reading of a
/// window.
///
/// A trend is a difference between two observations, so a caller that needs
/// "grew by X" cannot get it from `AppHistoryTrend`'s peak: a peak says how much
/// was held at the busiest moment, not how much was added. Only immutable values
/// leave the history reader, so this carries the two endpoints rather than the
/// stored models.
public struct AppMemorySpan: Sendable {
    public let appID: String
    public let displayName: String
    public let firstBytes: UInt64
    public let lastBytes: UInt64
    public let firstAt: Date
    public let lastAt: Date

    public init(
        appID: String, displayName: String,
        firstBytes: UInt64, lastBytes: UInt64, firstAt: Date, lastAt: Date
    ) {
        self.appID = appID
        self.displayName = displayName
        self.firstBytes = firstBytes
        self.lastBytes = lastBytes
        self.firstAt = firstAt
        self.lastAt = lastAt
    }

    /// Bytes added between the two observations. 0 when memory was released —
    /// a shrink is not growth, and never a wrap-around.
    public var growthBytes: UInt64 {
        lastBytes >= firstBytes ? lastBytes - firstBytes : 0
    }
}

public enum HistoryPlot {
    public struct Reading: Sendable {
        public let at: Date
        public let value: Double?
        public init(at: Date, value: Double?) { self.at = at; self.value = value }
    }
    public struct Point: Identifiable, Sendable {
        public let at: Date
        public let value: Double
        public let segment: Int
        public var id: Date { at }
    }
    /// Bounded chart output. A missing reading or long pause breaks the line;
    /// a bucket containing a gap is omitted rather than drawing through it.
    public static func downsample(_ readings: [Reading], maxPoints: Int = 200, maxGap: TimeInterval = 120) -> [Point] {
        guard maxPoints > 0, !readings.isEmpty else { return [] }
        let size = max(1, Int(ceil(Double(readings.count) / Double(maxPoints))))
        var result: [Point] = []; var segment = 0
        for start in stride(from: 0, to: readings.count, by: size) {
            let end = min(readings.count, start + size)
            let bucket = readings[start..<end]
            let hasGap = (start..<end).contains { i in
                readings[i].value?.isFinite != true || (i > 0 && readings[i].at.timeIntervalSince(readings[i - 1].at) > maxGap)
            }
            guard !hasGap else { segment += 1; continue }
            let average = bucket.compactMap(\.value).reduce(0, +) / Double(bucket.count)
            guard average.isFinite else { segment += 1; continue }
            result.append(Point(at: bucket.first!.at, value: average, segment: segment))
        }
        return result
    }
}

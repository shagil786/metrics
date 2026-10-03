import Foundation
import SwiftData

/// UI queries use fresh contexts created on this actor's executor, never the
/// writer's context or its lock. Only immutable values leave the actor.
public actor HistoryReader {
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    public func dayStats(metric: String, now: Date = Date()) throws -> CpuWindowStats {
        try Task.checkCancellation()
        let since = Calendar.current.startOfDay(for: now)
        let context = ModelContext(container)
        var values: [(value: Double, at: Date)] = []
        if metric == "cpu" {
            try context.enumerate(FetchDescriptor<CPUSample>(predicate: #Predicate { $0.at >= since }, sortBy: [SortDescriptor(\.at)]), batchSize: 500) { p in
                try Task.checkCancellation(); values.append((p.totalPercent, p.at))
            }
        } else if metric == "memory" {
            try context.enumerate(FetchDescriptor<MemSample>(predicate: #Predicate { $0.at >= since }, sortBy: [SortDescriptor(\.at)]), batchSize: 500) { p in
                try Task.checkCancellation(); values.append((Double(p.usedBytes) / 1_073_741_824, p.at))
            }
        }
        return CpuWindowStats.compute(samples: values, now: now)
    }

    public func chart(since: Date, metric: String, appID: String) throws -> [HistoryPlot.Point] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        var readings: [HistoryPlot.Reading] = []
        if !appID.isEmpty {
            let query = FetchDescriptor<AppHistoryPoint>(predicate: #Predicate { $0.at >= since && $0.appID == appID }, sortBy: [SortDescriptor(\.at)])
            try context.enumerate(query, batchSize: 500) { p in
                try Task.checkCancellation()
                let value: Double?
                switch metric {
                case "cpu": value = p.observedSeconds > 0 ? p.cpuSeconds / p.observedSeconds * 100 : nil
                case "memory": value = p.memoryBytes.map(Double.init)
                case "download": value = p.download
                case "upload": value = p.upload
                case "diskRead": value = p.diskRead
                case "diskWrite": value = p.diskWrite
                default: value = nil
                }
                readings.append(.init(at: p.at, value: value))
            }
        } else if metric == "cpu" {
            try context.enumerate(FetchDescriptor<CPUSample>(predicate: #Predicate { $0.at >= since }, sortBy: [SortDescriptor(\.at)]), batchSize: 500) { p in
                try Task.checkCancellation(); readings.append(.init(at: p.at, value: p.totalPercent))
            }
        } else if metric == "memory" {
            try context.enumerate(FetchDescriptor<MemSample>(predicate: #Predicate { $0.at >= since }, sortBy: [SortDescriptor(\.at)]), batchSize: 500) { p in
                try Task.checkCancellation(); readings.append(.init(at: p.at, value: Double(p.usedBytes)))
            }
        } else {
            try context.enumerate(FetchDescriptor<ResourceHistoryPoint>(predicate: #Predicate { $0.at >= since && $0.metric == metric }, sortBy: [SortDescriptor(\.at)]), batchSize: 500) { p in
                try Task.checkCancellation(); readings.append(.init(at: p.at, value: p.value))
            }
        }
        try Task.checkCancellation()
        return HistoryPlot.downsample(readings)
    }

    public func appTrends(since: Date) throws -> [AppHistoryTrend] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        var grouped: [String: AppHistoryTrend] = [:]
        try context.enumerate(FetchDescriptor<AppHistoryPoint>(predicate: #Predicate { $0.at >= since }), batchSize: 500) { point in
            try Task.checkCancellation()
            var trend = grouped[point.appID] ?? AppHistoryTrend(id: point.appID, displayName: point.displayName, lastSeen: point.at)
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

    /// First and last recorded memory per app over the window, for apps seen at
    /// least twice.
    ///
    /// Apps with a single reading are omitted: growth is the difference between
    /// two observations, and reporting a peak as growth would invent the missing
    /// half of the measurement.
    public func appMemorySpans(since: Date) throws -> [AppMemorySpan] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        var first: [String: (bytes: UInt64, at: Date, name: String)] = [:]
        var last: [String: (bytes: UInt64, at: Date)] = [:]
        try context.enumerate(FetchDescriptor<AppHistoryPoint>(predicate: #Predicate { $0.at >= since }, sortBy: [SortDescriptor(\.at)]), batchSize: 500) { point in
            try Task.checkCancellation()
            // nil memory is "not measured", so it is not an endpoint either.
            guard let bytes = point.memoryBytes, bytes >= 0 else { return }
            if first[point.appID] == nil {
                first[point.appID] = (UInt64(bytes), point.at, point.displayName)
            }
            last[point.appID] = (UInt64(bytes), point.at)
        }
        var spans: [AppMemorySpan] = []
        spans.reserveCapacity(first.count)
        for (appID, start) in first {
            guard let end = last[appID] else { continue }
            spans.append(AppMemorySpan(
                appID: appID, displayName: start.name,
                firstBytes: start.bytes, lastBytes: end.bytes,
                firstAt: start.at, lastAt: end.at
            ))
        }
        return spans.sorted { $0.lastAt == $1.lastAt ? $0.appID < $1.appID : $0.lastAt > $1.lastAt }
    }

    public func legacyTrends(since: Date) throws -> [HistoryStore.ProcessTrend] {
        try Task.checkCancellation()
        let context = ModelContext(container)
        var grouped: [String: HistoryStore.ProcessTrend] = [:]
        try context.enumerate(FetchDescriptor<ProcessPoint>(predicate: #Predicate { $0.at >= since }), batchSize: 500) { point in
            try Task.checkCancellation()
            let key = point.projectID ?? point.name
            var trend = grouped[key] ?? .init(key: key, totalCPU: 0, peakMemory: 0, samples: 0, lastSeen: point.at, projectID: point.projectID)
            trend.totalCPU += point.cpuPercent; trend.peakMemory = max(trend.peakMemory, point.memoryBytes)
            trend.samples += 1; trend.lastSeen = max(trend.lastSeen, point.at); grouped[key] = trend
        }
        return grouped.values.sorted { $0.totalCPU == $1.totalCPU ? $0.key < $1.key : $0.totalCPU > $1.totalCPU }
    }
}

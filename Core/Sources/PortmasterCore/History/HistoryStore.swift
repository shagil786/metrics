// History store: persists system + per-process samples with SwiftData and
// manages retention and clear-all. Only fields the features need are stored.
import Foundation
import SwiftData

public final class HistoryStore: @unchecked Sendable {
    private let container: ModelContainer
    private let context: ModelContext
    private let lock = NSLock()

    /// Reads own their context on a background actor; models never cross to the UI.
    public func makeReader() -> HistoryReader { HistoryReader(container: container) }

    public enum StoreError: LocalizedError {
        case initFailed(underlying: Error)
        case deleteFailed(underlying: Error)
        public var errorDescription: String? {
            switch self {
            case .initFailed(let e): "Could not open the local history database: \(e.localizedDescription)"
            case .deleteFailed(let e): "Could not delete stored history: \(e.localizedDescription)"
            }
        }
    }

    /// Store lives in Application Support/Portmaster (standard local location).
    public static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Portmaster", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.sqlite")
    }

    public init(storeURL: URL? = nil) throws {
        let url = storeURL ?? Self.defaultStoreURL()
        let config = ModelConfiguration(url: url)
        do {
            // Every model is listed, because SwiftData only persists models named
            // here — one left out of this list simply never saves, with nothing
            // failing. Adding a model means adding it here too.
            container = try ModelContainer(
                for: CPUSample.self, MemSample.self, ProcessPoint.self, PortEvent.self,
                AppHistoryPoint.self, ResourceHistoryPoint.self,
                AgentSession.self, TokenUsageRecordRow.self, ModelPriceEntry.self,
                configurations: config
            )
        } catch {
            throw StoreError.initFailed(underlying: error)
        }
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    // MARK: - Writes

    public func recordSystem(cpu: SystemCPU, memory: SystemMemory, at: Date) {
        lock.lock(); defer { lock.unlock() }
        context.insert(CPUSample(
            at: at,
            totalPercent: cpu.totalPercent,
            userPercent: cpu.userPercent,
            systemPercent: cpu.systemPercent
        ))
        context.insert(MemSample(
            at: at,
            usedBytes: Int64(memory.usedBytes),
            totalBytes: Int64(memory.totalBytes),
            pressureRatio: memory.pressureRatio,
            swapBytes: Int64(memory.swapBytes ?? 0)
        ))
        save()
    }

    public func recordProcessPoints(_ rows: [ProcessRow], at: Date, servicePids: Set<pid_t>) {
        lock.lock(); defer { lock.unlock() }
        // Cap per tick to keep the store predictable: only meaningful rows.
        let meaningful = rows
            .filter { ($0.cpuPercent ?? 0) > 0.5 || ($0.memoryBytes ?? 0) > 64 * 1024 * 1024 }
            .prefix(120)
        for row in meaningful {
            context.insert(ProcessPoint(
                at: at,
                pid: row.pid,
                name: row.name,
                cpuPercent: row.cpuPercent ?? 0,
                memoryBytes: Int64(row.memoryBytes ?? 0),
                projectID: row.projectID,
                isService: servicePids.contains(row.pid)
            ))
        }
        save()
    }

    public func recordPortEvents(
        current: [ListeningPort],
        previous: [ListeningPort],
        projectFor: (pid_t) -> String?
    ) {
        lock.lock(); defer { lock.unlock() }
        let prevKeys = Set(previous.map(\.id))
        let currKeys = Set(current.map(\.id))

        for port in current where !prevKeys.contains(port.id) {
            context.insert(PortEvent(
                at: Date(), port: Int(port.port), pid: port.pid,
                processName: port.processName,
                projectID: projectFor(port.pid), kind: "bound"
            ))
        }
        for port in previous where !currKeys.contains(port.id) {
            context.insert(PortEvent(
                at: Date(), port: Int(port.port), pid: port.pid,
                processName: port.processName,
                projectID: projectFor(port.pid), kind: "released"
            ))
        }
        save()
    }

    public func recordExtended(system: SystemSample, apps: [AppRollup], interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        for metric in HistoryResource.allCases {
            context.insert(ResourceHistoryPoint(at: system.at, metric: metric.rawValue, value: metric.reading(in: system)))
        }
        // Application bundles and meaningful CLI groups; cap bounded database growth.
        for app in apps.filter({ $0.isAppBundle || $0.totalCPU > 0.5 || $0.processes.contains(where: { ($0.memoryBytes ?? 0) > 64 * 1024 * 1024 }) }).prefix(120) {
            context.insert(AppHistoryPoint(at: system.at, app: app, interval: interval))
        }
        save()
    }

    public func resourceSamples(_ metric: HistoryResource, since: Date) -> [ResourceHistoryPoint] {
        lock.lock(); defer { lock.unlock() }
        let key = metric.rawValue
        return (try? context.fetch(FetchDescriptor<ResourceHistoryPoint>(predicate: #Predicate { $0.at >= since && $0.metric == key }, sortBy: [SortDescriptor(\.at)]))) ?? []
    }

    public func appSamples(appID: String, since: Date) -> [AppHistoryPoint] {
        lock.lock(); defer { lock.unlock() }
        return (try? context.fetch(FetchDescriptor<AppHistoryPoint>(predicate: #Predicate { $0.at >= since && $0.appID == appID }, sortBy: [SortDescriptor(\.at)]))) ?? []
    }

    public func appTrends(since: Date) -> [AppHistoryTrend] {
        lock.lock(); defer { lock.unlock() }
        let points = (try? context.fetch(FetchDescriptor<AppHistoryPoint>(predicate: #Predicate { $0.at >= since }, sortBy: [SortDescriptor(\.at)]))) ?? []
        return AppHistoryTrend.aggregate(points, since: since)
    }

    public func extendedRowCounts() -> (apps: Int, resources: Int) {
        lock.lock(); defer { lock.unlock() }
        return ((try? context.fetchCount(FetchDescriptor<AppHistoryPoint>())) ?? 0,
                (try? context.fetchCount(FetchDescriptor<ResourceHistoryPoint>())) ?? 0)
    }

    // MARK: - Reads

    public func cpuSamples(since: Date) -> [CPUSample] {
        lock.lock(); defer { lock.unlock() }
        let pid = FetchDescriptor<CPUSample>(
            predicate: #Predicate { $0.at >= since },
            sortBy: [SortDescriptor(\.at)]
        )
        return (try? context.fetch(pid)) ?? []
    }

    public func memSamples(since: Date) -> [MemSample] {
        lock.lock(); defer { lock.unlock() }
        let d = FetchDescriptor<MemSample>(
            predicate: #Predicate { $0.at >= since },
            sortBy: [SortDescriptor(\.at)]
        )
        return (try? context.fetch(d)) ?? []
    }

    public struct ProcessTrend: Identifiable, Hashable, Sendable {
        public let key: String        // name or project id
        public var totalCPU: Double
        public var peakMemory: Int64
        public var samples: Int
        public var lastSeen: Date
        public var projectID: String?

        public var id: String { key }
    }

    /// Aggregate per-name/per-project trends over a window.
    public func processTrends(since: Date) -> [ProcessTrend] {
        lock.lock(); defer { lock.unlock() }
        let d = FetchDescriptor<ProcessPoint>(
            predicate: #Predicate { $0.at >= since },
            sortBy: [SortDescriptor(\.at)]
        )
        guard let points = try? context.fetch(d) else { return [] }
        var byKey: [String: ProcessTrend] = [:]
        for p in points {
            let key = p.projectID ?? p.name
            var t = byKey[key] ?? ProcessTrend(
                key: key, totalCPU: 0, peakMemory: 0, samples: 0,
                lastSeen: p.at, projectID: p.projectID
            )
            t.totalCPU += p.cpuPercent
            t.peakMemory = max(t.peakMemory, p.memoryBytes)
            t.samples += 1
            t.lastSeen = max(t.lastSeen, p.at)
            byKey[key] = t
        }
        return byKey.values.sorted { $0.totalCPU > $1.totalCPU }
    }

    /// Distinct projects observed in the window.
    public func observedProjects(since: Date) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let d = FetchDescriptor<ProcessPoint>(
            predicate: #Predicate { $0.at >= since && $0.projectID != nil }
        )
        guard let points = try? context.fetch(d) else { return [] }
        return Set(points.compactMap(\.projectID))
    }

    public func rowCounts() -> (cpu: Int, mem: Int, process: Int, port: Int) {
        lock.lock(); defer { lock.unlock() }
        let cpu = (try? context.fetchCount(FetchDescriptor<CPUSample>())) ?? 0
        let mem = (try? context.fetchCount(FetchDescriptor<MemSample>())) ?? 0
        let proc = (try? context.fetchCount(FetchDescriptor<ProcessPoint>())) ?? 0
        let port = (try? context.fetchCount(FetchDescriptor<PortEvent>())) ?? 0
        return (cpu, mem, proc, port)
    }

    // MARK: - Retention & clear

    public func prune(olderThan cutoff: Date) {
        lock.lock(); defer { lock.unlock() }
        _ = try? context.delete(model: CPUSample.self, where: #Predicate { $0.at < cutoff })
        _ = try? context.delete(model: MemSample.self, where: #Predicate { $0.at < cutoff })
        _ = try? context.delete(model: ProcessPoint.self, where: #Predicate { $0.at < cutoff })
        _ = try? context.delete(model: PortEvent.self, where: #Predicate { $0.at < cutoff })
        _ = try? context.delete(model: AppHistoryPoint.self, where: #Predicate { $0.at < cutoff })
        _ = try? context.delete(model: ResourceHistoryPoint.self, where: #Predicate { $0.at < cutoff })
        save()
    }

    /// Delete every stored sample. Irreversible; Settings confirms first.
    /// Throws when deletion fails so the UI can tell the user (never silent).
    public func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        do {
            _ = try context.delete(model: CPUSample.self)
            _ = try context.delete(model: MemSample.self)
            _ = try context.delete(model: ProcessPoint.self)
            _ = try context.delete(model: PortEvent.self)
            _ = try context.delete(model: AppHistoryPoint.self)
            _ = try context.delete(model: ResourceHistoryPoint.self)
            try context.save()
        } catch {
            context.rollback()
            throw StoreError.deleteFailed(underlying: error)
        }
    }

    /// Best-effort save for routine writes; retention drops are not user-facing
    /// failures, but the error is logged for diagnostics.
    private func save() {
        do { try context.save() } catch { NSLog("Portmaster history save failed: \(error)") }
    }
}

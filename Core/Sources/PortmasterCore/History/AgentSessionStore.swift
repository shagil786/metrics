// Agent sessions: who connected, what they reported, what it cost.
//
// Usage is appended as `TokenUsageRecord`s and aggregated on read rather than
// stored as a running total. Reports arrive asynchronously — an agent reports at
// its own pace and a log adapter may be reading while the app writes — so a
// mutable total on the session row would mean every report rewrites it and two
// sources contend for one object.
//
// Cost is computed on read from a version-stamped price table, never stored. A
// price change then re-costs history instead of leaving figures that quietly
// describe a price from months ago.

import Foundation
import SwiftData

@Model
public final class AgentSession {
    /// The MCP connection id. Unique per connection, not per process: one agent may
    /// open two connections, and giving both the same id would merge two intentions.
    @Attribute(.unique) public var id: UUID
    /// `LOCAL_PEERPID`. 0 when the kernel will not say — the session is still real.
    public var peerPID: Int32
    /// From the MCP `initialize` handshake. Nil when the client sent none.
    public var clientName: String?
    public var clientVersion: String?
    public var connectedAt: Date
    public var lastToolCallAt: Date?
    /// Nil while the socket is open, which outlives the process.
    public var endedAt: Date?

    public init(
        id: UUID, peerPID: Int32, clientName: String?, clientVersion: String?,
        connectedAt: Date, lastToolCallAt: Date? = nil, endedAt: Date? = nil
    ) {
        self.id = id
        self.peerPID = peerPID
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.connectedAt = connectedAt
        self.lastToolCallAt = lastToolCallAt
        self.endedAt = endedAt
    }
}

@Model
public final class TokenUsageRecordRow {
    @Attribute(.unique) public var id: UUID
    public var sessionID: UUID
    public var recordedAt: Date
    public var inputTokens: Int
    public var outputTokens: Int
    /// Nil when the source omits these; they are priced differently from input.
    public var cacheReadTokens: Int?
    public var reasoningTokens: Int?
    public var modelID: String
    public var provenanceRaw: String

    public init(from record: TokenUsageRecord) {
        self.id = record.id
        self.sessionID = record.sessionID
        self.recordedAt = record.recordedAt
        self.inputTokens = record.input
        self.outputTokens = record.output
        self.cacheReadTokens = record.cacheRead
        self.reasoningTokens = record.reasoning
        self.modelID = record.modelID
        self.provenanceRaw = record.provenance.rawValue
    }

    public var value: TokenUsageRecord {
        TokenUsageRecord(
            id: id, sessionID: sessionID, recordedAt: recordedAt,
            input: inputTokens, output: outputTokens,
            cacheRead: cacheReadTokens, reasoning: reasoningTokens,
            modelID: modelID,
            provenance: TokenProvenance(rawValue: provenanceRaw) ?? .selfReported
        )
    }
}

/// One price for one model and one component. User-supplied because provider
/// pricing changes on someone else's schedule.
@Model
public final class ModelPriceEntry {
    @Attribute(.unique) public var key: String
    public var pricePerToken: Decimal
    public var tableVersion: Int

    public init(key: String, pricePerToken: Decimal, tableVersion: Int) {
        self.key = key
        self.pricePerToken = pricePerToken
        self.tableVersion = tableVersion
    }
}

public enum PriceComponent: String, Sendable {
    case input
    case output
    case cacheRead
    case reasoning

    var keySuffix: String { rawValue }
}

public struct AgentSessionSnapshot: Sendable {
    public let id: UUID
    public let peerPID: Int32
    public let clientName: String?
    public let clientVersion: String?
    public let connectedAt: Date
    public let endedAt: Date?
    public let usage: TokenUsage
    public let cost: SessionCost
}

public final class AgentSessionStore: @unchecked Sendable {
    /// Mirrors `HistoryStore.StoreError` rather than sharing it: the two stores
    /// open different files and can fail independently, so a caller holding one
    /// error should not be able to read it as the other.
    public enum StoreError: LocalizedError {
        case initFailed(underlying: Error)
        public var errorDescription: String? {
            switch self {
            case .initFailed(let e): "Could not open the local agent session database: \(e.localizedDescription)"
            }
        }
    }

    private let lock = NSLock()
    private let container: ModelContainer
    private let context: ModelContext
    private let url: URL

    public init(storeURL: URL? = nil) throws {
        url = storeURL ?? AgentSessionStore.defaultStoreURL()
        let config = ModelConfiguration(url: url)
        do {
            container = try ModelContainer(
                for: AgentSession.self, TokenUsageRecordRow.self, ModelPriceEntry.self,
                configurations: config
            )
        } catch {
            throw StoreError.initFailed(underlying: error)
        }
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public static func defaultStoreURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Portmaster", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agent-sessions.sqlite")
    }

    // MARK: - Writes

    public func recordSession(
        id: UUID, peerPID: Int32, clientName: String?, clientVersion: String?,
        connectedAt: Date
    ) throws {
        lock.lock(); defer { lock.unlock() }
        // Upsert by id: a reconnect reuses nothing, but a retried record must not
        // create a second row for one connection.
        if let existing = fetchSession(id) {
            existing.peerPID = peerPID
            existing.clientName = clientName
            existing.clientVersion = clientVersion
            return
        }
        context.insert(AgentSession(
            id: id, peerPID: peerPID,
            clientName: clientName, clientVersion: clientVersion,
            connectedAt: connectedAt
        ))
    }

    public func recordUsage(_ record: TokenUsageRecord) throws {
        lock.lock(); defer { lock.unlock() }
        context.insert(TokenUsageRecordRow(from: record))
    }

    public func setPrice(_ price: Decimal, modelID: String, component: PriceComponent = .input) throws {
        lock.lock(); defer { lock.unlock() }
        let key = "\(modelID)#\(component.keySuffix)"
        let current = currentVersionLocked()
        if let existing = fetchPrice(key) {
            // Bumping on every write keeps "which prices produced this figure"
            // answerable without a separate history of the table.
            existing.pricePerToken = price
            existing.tableVersion = current + 1
            return
        }
        context.insert(ModelPriceEntry(key: key, pricePerToken: price, tableVersion: current + 1))
    }

    public func flush() throws {
        lock.lock(); defer { lock.unlock() }
        try context.save()
    }

    // MARK: - Reads

    public func sessions() throws -> [AgentSessionSnapshot] {
        lock.lock(); defer { lock.unlock() }
        let descriptor = FetchDescriptor<AgentSession>(
            sortBy: [SortDescriptor(\.connectedAt)]
        )
        return try context.fetch(descriptor).map { row in
            AgentSessionSnapshot(
                id: row.id,
                peerPID: row.peerPID,
                clientName: row.clientName,
                clientVersion: row.clientVersion,
                connectedAt: row.connectedAt,
                endedAt: row.endedAt,
                usage: TokenUsage.aggregating(usageRecordsLocked(for: row.id)),
                cost: costLocked(for: row.id)
            )
        }
    }

    public func usage(for sessionID: UUID) throws -> TokenUsage {
        lock.lock(); defer { lock.unlock() }
        return TokenUsage.aggregating(usageRecordsLocked(for: sessionID))
    }

    public func cost(for sessionID: UUID) throws -> SessionCost {
        lock.lock(); defer { lock.unlock() }
        return costLocked(for: sessionID)
    }

    // MARK: - Locked helpers (callers already hold the lock)

    private func fetchSession(_ id: UUID) -> AgentSession? {
        var descriptor = FetchDescriptor<AgentSession>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func fetchPrice(_ key: String) -> ModelPriceEntry? {
        var descriptor = FetchDescriptor<ModelPriceEntry>(
            predicate: #Predicate { $0.key == key }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func usageRecordsLocked(for sessionID: UUID) -> [TokenUsageRecord] {
        let descriptor = FetchDescriptor<TokenUsageRecordRow>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.recordedAt)]
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.value)
    }

    private func currentVersionLocked() -> Int {
        let descriptor = FetchDescriptor<ModelPriceEntry>(
            sortBy: [SortDescriptor(\.tableVersion, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first?.tableVersion ?? 0
    }

    private func priceLocked(_ key: String) -> (Decimal, Int)? {
        guard let entry = fetchPrice(key) else { return nil }
        return (entry.pricePerToken, entry.tableVersion)
    }

    private func costLocked(for sessionID: UUID) -> SessionCost {
        let records = usageRecordsLocked(for: sessionID)
        guard !records.isEmpty else { return .noUsage }

        let latest = TokenUsage.latestPerProvenance(records)
        // The conflict rule lives in `TokenUsage`, and costing asks it rather than
        // re-deriving "do the sources disagree" from the raw records: one source
        // escalating models mid-session is history, not a disagreement, and pricing
        // it against the newest model is not ambiguous. Naming every model involved
        // keeps the reason visible instead of collapsing it to whichever sorted first.
        if TokenUsage.hasModelConflict(records) {
            return .notPriced(
                modelID: Set(latest.values.map(\.modelID)).sorted().joined(separator: "/")
            )
        }
        guard let record = latest[.selfReported] ?? latest[.parsedFromLog] else { return .noUsage }
        let modelID = record.modelID

        let components: [(PriceComponent, Int?)] = [
            (.input, record.input), (.output, record.output),
            (.cacheRead, record.cacheRead), (.reasoning, record.reasoning),
        ]
        // A component with no tokens needs no price: there is nothing to multiply,
        // so demanding an entry would report a missing price where there is no
        // spend. A component *with* tokens and no entry is a different fact — spend
        // that cannot be priced — and it says so rather than quietly dropping those
        // tokens, which would produce a total that cannot reconcile with an invoice.
        let spent = components.filter { ($0.1 ?? 0) > 0 }
        guard !spent.isEmpty else {
            // Zero tokens cost zero under any table, so the figure is exact; it
            // still names the prices it stands under rather than a version of 0,
            // which would read as "priced from nothing".
            return .priced(usd: 0, priceTableVersion: currentVersionLocked())
        }

        var total = Decimal(0)
        var version = 0
        for (component, count) in spent {
            guard let count,
                  let (price, entryVersion) = priceLocked("\(modelID)#\(component.keySuffix)")
            else {
                return .notPriced(modelID: modelID)
            }
            total += price * Decimal(count)
            version = max(version, entryVersion)
        }
        return .priced(usd: total, priceTableVersion: version)
    }
}
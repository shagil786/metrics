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
    /// The price as exact decimal **text**, not as a `Decimal`, even though the money
    /// itself is decimal. SQLite has no decimal storage class: a column declared
    /// `DECIMAL` is stored as a binary float (`typeof` reports `real`), so the digits
    /// are rounded in the file itself — `0.1234567890123456` comes back as
    /// `0.123456789012346`. A float near 15 significant digits is enough for a price
    /// like `0.0000015`, which is why that mistake survives an ordinary test, and not
    /// enough for a figure that must reconcile with an invoice. SQLite stores TEXT as
    /// TEXT, so these are the digits that come back.
    ///
    /// Nothing here should "simplify" this back to a `Decimal` property: the type
    /// would be more honest-looking and the arithmetic exact, while silently moving
    /// the rounding from memory into storage.
    public var pricePerTokenText: String
    public var tableVersion: Int

    public init(key: String, pricePerToken: Decimal, tableVersion: Int) {
        self.key = key
        self.pricePerTokenText = ModelPriceEntry.text(for: pricePerToken)
        self.tableVersion = tableVersion
    }

    /// The stored price, or nil when the text is not a number. Nil rather than zero: a
    /// row that cannot be read is a price that is not known, and zero would turn an
    /// unreadable row into a figure that looks computed.
    public var pricePerToken: Decimal? {
        // Strict before lenient: `Decimal(string:)` parses what it can and ignores the
        // rest, so `"1,5"` returns 1 and `"1.5abc"` returns 1.5. A wrong price is the
        // worse failure of the two — a missing one is visibly missing, a wrong one is
        // a figure that looks computed and cannot reconcile with an invoice.
        guard ModelPriceEntry.isDecimalNumber(pricePerTokenText) else { return nil }
        // `en_US_POSIX` so the decimal separator is a period whatever the user's locale
        // is — a price written under one locale must not stop parsing under another.
        return Decimal(string: pricePerTokenText, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Whether `text` is a decimal number and nothing else: digits, with at most one
    /// decimal point and at least one digit somewhere.
    ///
    /// The shape `text(for:)` writes, and the shape nothing else should be accepted as.
    /// Deliberately narrower than what `Decimal(string:)` tolerates, because tolerating
    /// `"1,5"` is a silently wrong price rather than a rejected one.
    ///
    /// Public because it is the same question wherever a price arrives from — a
    /// typed price in Settings and a price over MCP are one rule, not two, and two
    /// implementations of "is this a number" is how `"1,5"` comes to be accepted on
    /// one surface and rejected on the other.
    public static func isDecimalNumber(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        for part in parts where !part.isEmpty {
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        }
        return parts.contains { !$0.isEmpty }
    }

    /// `NSDecimalNumber` rather than `Decimal.description`: the latter is a rendering
    /// whose exact form is a Foundation detail, this one is the documented conversion
    /// to plain decimal text.
    static func text(for price: Decimal) -> String {
        NSDecimalNumber(decimal: price).stringValue
    }
}

public enum PriceComponent: String, Sendable {
    case input
    case output
    case cacheRead
    case reasoning

    var keySuffix: String { rawValue }

    /// The component a model id names when no component is given, which is the
    /// common case: a caller setting "the price of gpt-5" means the input price.
    public static let named: PriceComponent = .input
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
        case deleteFailed(underlying: Error)
        public var errorDescription: String? {
            switch self {
            case .initFailed(let e): "Could not open the local agent session database: \(e.localizedDescription)"
            case .deleteFailed(let e): "Could not delete stored agent sessions: \(e.localizedDescription)"
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
            existing.pricePerTokenText = ModelPriceEntry.text(for: price)
            existing.tableVersion = current + 1
            return
        }
        context.insert(ModelPriceEntry(key: key, pricePerToken: price, tableVersion: current + 1))
    }

    public func flush() throws {
        lock.lock(); defer { lock.unlock() }
        try context.save()
    }

    // MARK: - Price table reads

    /// One price, as the surfaces show it.
    public struct ModelPrice: Hashable, Sendable {
        public let modelID: String
        public let component: PriceComponent
        public let pricePerToken: Decimal
        /// The table version that last wrote this price. Carried so a figure can be
        /// traced to the price behind it, and so a table edit is visible as a version
        /// change rather than only as a different number.
        public let tableVersion: Int
    }

    /// Every price in the table, ordered by model then component so a UI list has a
    /// stable order without sorting one itself.
    ///
    /// A row whose stored text will not parse is **left out**, not shown as zero.
    /// The same reason the costing path treats it as absent: an unparseable price is
    /// an unknown price, and listing it as 0 would offer the user a figure to
    /// correct that looks like a real one.
    public func prices() throws -> [ModelPrice] {
        lock.lock(); defer { lock.unlock() }
        let table = priceTableLocked()
        var prices: [ModelPrice] = []
        prices.reserveCapacity(table.byKey.count)
        for key in table.byKey.keys.sorted() {
            guard let entry = table.byKey[key],
                  let pair = Self.splitPriceKey(key)
            else { continue }
            prices.append(ModelPrice(
                modelID: pair.0,
                component: pair.1,
                pricePerToken: entry.price,
                tableVersion: entry.version
            ))
        }
        return prices
    }

    /// Models that appear in recorded usage but have no input price.
    ///
    /// The list a price-entry surface should show first: these are the sessions
    /// currently reading *not priced*, so they are the ones whose numbers are
    /// missing. Distinct from "every model in the table", which says what is set
    /// rather than what is missing.
    public func modelsMissingAPrice() throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        var priced = Set<String>()
        for key in priceTableLocked().byKey.keys {
            guard let pair = Self.splitPriceKey(key), pair.1 == .input else { continue }
            priced.insert(pair.0)
        }
        let descriptor = FetchDescriptor<TokenUsageRecordRow>()
        let rows = (try? context.fetch(descriptor)) ?? []
        var seen = Set<String>()
        for row in rows { seen.insert(row.modelID) }
        return seen.subtracting(priced).sorted()
    }

    /// Splits the composite key `model#component`. Nil for anything else, so a
    /// malformed key is skipped rather than parsed into a model with no component.
    static func splitPriceKey(_ key: String) -> (String, PriceComponent)? {
        guard let hash = key.lastIndex(of: "#") else { return nil }
        let modelID = String(key[key.startIndex..<hash])
        guard !modelID.isEmpty,
              let component = PriceComponent(rawValue: String(key[key.index(after: hash)...]))
        else { return nil }
        return (modelID, component)
    }

    // MARK: - Reads

    public func sessions() throws -> [AgentSessionSnapshot] {
        lock.lock(); defer { lock.unlock() }
        let descriptor = FetchDescriptor<AgentSession>(
            sortBy: [SortDescriptor(\.connectedAt)]
        )
        let rows = try context.fetch(descriptor)
        // Three queries for the whole list, never three per row. Usage and cost both
        // need the session's records, and both need prices, so reading inside the map
        // repeats the same work once per session — an N+1 that gets worse the longer
        // history runs, against tables this file never prunes. The batching is the
        // reason to keep these two fetches above the loop: moving them back inside
        // would restore the per-row queries without changing any result.
        let recordsBySession = usageRecordsGroupedLocked()
        let table = priceTableLocked()
        return rows.map { row in
            let records = recordsBySession[row.id] ?? []
            return AgentSessionSnapshot(
                id: row.id,
                peerPID: row.peerPID,
                clientName: row.clientName,
                clientVersion: row.clientVersion,
                connectedAt: row.connectedAt,
                endedAt: row.endedAt,
                usage: TokenUsage.aggregating(records),
                cost: costLocked(records: records, table: table)
            )
        }
    }

    public func usage(for sessionID: UUID) throws -> TokenUsage {
        lock.lock(); defer { lock.unlock() }
        return TokenUsage.aggregating(usageRecordsLocked(for: sessionID))
    }

    public func cost(for sessionID: UUID) throws -> SessionCost {
        lock.lock(); defer { lock.unlock() }
        return costLocked(records: usageRecordsLocked(for: sessionID), table: priceTableLocked())
    }

    // MARK: - Retention & clear

    /// Delete every session and every usage record. Irreversible; the UI confirms
    /// first. Throws when deletion fails so the UI can tell the user (never silent).
    ///
    /// Both tables or neither: deleting the session rows alone would leave usage records
    /// under an id no row names, which every session-scoped read ignores and which
    /// `clearAll` would then report as cleared while it stayed on disk.
    ///
    /// The price table is kept, and that is the one thing here that is not history: it
    /// is configuration the user typed. Clearing samples does not un-type them.
    public func clearAll() throws {
        lock.lock(); defer { lock.unlock() }
        do {
            _ = try context.delete(model: TokenUsageRecordRow.self)
            _ = try context.delete(model: AgentSession.self)
            try context.save()
        } catch {
            context.rollback()
            throw StoreError.deleteFailed(underlying: error)
        }
    }

    /// Drop what the user asked to keep no longer than, best-effort and
    /// non-throwing, matching `HistoryStore.prune`: a retention sweep that failed on
    /// one row must not abort the rest, and the error is logged.
    ///
    /// `keepingSessionIDs` is the host's live set, and the parameter has no default
    /// because a sweep must be told what is still connected rather than guess. Deleting
    /// the row of a session the host is still serving is the orphan this method exists
    /// to avoid: the connection keeps its id in memory, `recordUsage` is a bare
    /// `context.insert` with no referential check, and every later report would land
    /// under an id no row names — invisible to every read here, and not collectable by
    /// the next sweep because the parent row is gone for good.
    ///
    /// **Usage is judged by `recordedAt`, never by the session's `connectedAt`.** The
    /// two are different questions: `connectedAt` is written once, at accept time, so a
    /// connection open for a month has a month-old stamp and a second-old figure.
    ///
    /// Sessions fall into three groups, and each is kept or dropped for its own reason:
    ///
    /// - **dropped whole** — stale, not connected, and nothing reported since the
    ///   cutoff. The row and all of its records go together, so a session is never
    ///   left claiming it has not reported when its records were deleted underneath it
    ///   (`awaitingFirstReport` would be a lie) and never left with records and no row.
    /// - **kept, records trimmed** — stale but still reporting. Records older than the
    ///   cutoff go, and that leaves the session's figures alone **only while every
    ///   segment that contributed still has a record at or after the cutoff.** With
    ///   one provenance that holds: aggregation reads the latest record per segment, and
    ///   a superseded one is never the one it reads.
    ///
    ///   Across two it does not, and this comment used to claim otherwise. A session
    ///   whose only `selfReported` record is older than the cutoff loses its whole source
    ///   when that record goes, so the aggregate moves to the other provenance, and
    ///   nothing in the output says a retention sweep just chose between them. Worse
    ///   than resolving a disagreement it would now *change a priced figure*: deleting
    ///   one side's reading of a model can leave a different model standing alone at a
    ///   different total, which is a number the user never saw before and cannot
    ///   account for. Deleting the *superseded* record of a provenance that still has a
    ///   newer one is inert; deleting the only record of one is not, and the trim
    ///   cannot tell the two apart without looking.
    ///
    ///   No adapter ships and nothing calls `TokenSourceRunner` in the app, so no
    ///   two-provenance session exists to be trimmed today; that is a reason it has no
    ///   test-driven need to be clever, not a reason to promise it cannot happen. What
    ///   would make trimming provably figure-preserving is deleting a record only when
    ///   a newer one exists for its own `(provenance, model)` pair, so no source can
    ///   disappear from an aggregate as a side effect of retention.
    /// - **kept whole** — the host is serving it. Nothing of it is touched, including a
    ///   record older than the cutoff: if it were deleted the session would read as
    ///   never having reported. The connection is what bounds that growth.
    public func prune(olderThan cutoff: Date, keepingSessionIDs live: Set<UUID>) {
        lock.lock(); defer { lock.unlock() }
        do {
            let stale = try context.fetch(FetchDescriptor<AgentSession>(
                predicate: #Predicate { $0.connectedAt < cutoff }
            ))
            // One query for "who reported since the cutoff", not one per session.
            let recentlyReported = try context.fetch(FetchDescriptor<TokenUsageRecordRow>(
                predicate: #Predicate { $0.recordedAt >= cutoff }
            )).reduce(into: Set<UUID>()) { $0.insert($1.sessionID) }

            var dropped: [UUID] = []
            var trimmed: [UUID] = []
            for session in stale {
                let id = session.id
                if live.contains(id) {
                    continue
                } else if recentlyReported.contains(id) {
                    trimmed.append(id)
                } else {
                    dropped.append(id)
                }
            }
            for id in dropped {
                _ = try context.delete(
                    model: TokenUsageRecordRow.self,
                    where: #Predicate { $0.sessionID == id }
                )
                _ = try context.delete(
                    model: AgentSession.self,
                    where: #Predicate { $0.id == id }
                )
            }
            for id in trimmed {
                _ = try context.delete(
                    model: TokenUsageRecordRow.self,
                    where: #Predicate { $0.sessionID == id && $0.recordedAt < cutoff }
                )
            }
            try context.save()
        } catch {
            context.rollback()
            NSLog("Portmaster agent session prune failed: \(error)")
        }
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
            sortBy: AgentSessionStore.recordOrder
        )
        return ((try? context.fetch(descriptor)) ?? []).map(\.value)
    }

    /// Record order, shared by every read of usage so the two paths cannot disagree.
    ///
    /// `latestPerSegment` breaks equal timestamps by array position, keeping the
    /// earlier element, so the order of tied rows is load-bearing: it decides which of
    /// two same-instant reports wins. SQLite makes no promise about the order of
    /// `ORDER BY` ties, and the batched and per-session fetches have different plans
    /// (`WHERE sessionID = X` against the full table), so tied rows can arrive in
    /// different orders and the same session could cost two different amounts
    /// depending on which API asked. `id` is unique and stable, so it decides ties the
    /// same way in both queries — which tie wins is still arbitrary, but it cannot
    /// change between reads.
    static let recordOrder = [
        SortDescriptor<TokenUsageRecordRow>(\.recordedAt),
        SortDescriptor<TokenUsageRecordRow>(\.id),
    ]

    /// Every session's records in one query. Grouping must not reorder a session's
    /// own records, which is what sorting by `recordOrder` before appending is for.
    private func usageRecordsGroupedLocked() -> [UUID: [TokenUsageRecord]] {
        let descriptor = FetchDescriptor<TokenUsageRecordRow>(
            sortBy: AgentSessionStore.recordOrder
        )
        var grouped: [UUID: [TokenUsageRecord]] = [:]
        for row in (try? context.fetch(descriptor)) ?? [] {
            grouped[row.sessionID, default: []].append(row.value)
        }
        return grouped
    }

    private func currentVersionLocked() -> Int {
        let descriptor = FetchDescriptor<ModelPriceEntry>(
            sortBy: [SortDescriptor(\.tableVersion, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first?.tableVersion ?? 0
    }

    /// The whole price table in one query, keyed for lookup. Costing needs several
    /// components per session, and each would otherwise be its own fetch — the same
    /// multiplication repeated in SQL rather than in memory.
    private func priceTableLocked() -> PriceTable {
        let all = (try? context.fetch(FetchDescriptor<ModelPriceEntry>())) ?? []
        var byKey: [String: (price: Decimal, version: Int)] = [:]
        var version = 0
        for entry in all {
            // A row whose text will not parse is left out of the table entirely, so
            // costing asks for a price, finds none, and says the model is unpriced —
            // rather than pricing tokens against a figure nobody can read.
            if let price = entry.pricePerToken {
                byKey[entry.key] = (price, entry.tableVersion)
            }
            version = max(version, entry.tableVersion)
        }
        return PriceTable(byKey: byKey, currentVersion: version)
    }

    private func costLocked(records: [TokenUsageRecord], table: PriceTable) -> SessionCost {
        guard !records.isEmpty else { return .noUsage }

        let segments = TokenUsage.segments(from: records)
        guard !segments.isEmpty else { return .noUsage }

        // Two sources counting one model differently is asked here rather than
        // re-derived below, so the list view and a single-session read cannot price the
        // same session differently.
        let disagreements = TokenUsage.hasMaterialDisagreement(
            segments, tolerance: Decimal(string: "0.01")!
        )
        if !disagreements.isEmpty {
            return .conflict(disagreements: disagreements)
        }

        // Past that check the sources agree, so each model has exactly one reading to
        // bill — and one model still has two segments, because agreeing readings are
        // still keyed on their provenance. Pricing both is not a rounding difference:
        // two 1,000-token readings of one session cost as 2,000 tokens, and no invoice
        // carries that line. The self-report wins, as it did before segments existed.
        let billable = TokenUsage.preferredProvenance(segments)

        // Each segment is priced at *its own* model's rate and the results summed.
        // Pricing a mixed total at one rate is the unsound figure segments exist to
        // remove — it cannot be reconciled with an invoice, because the invoice has
        // two lines and the total has one rate applied to both.
        var total = Decimal(0)
        var version = 0
        var lines: [CostLine] = []
        var unpriced: [String] = []

        for segment in billable {
            let components: [(PriceComponent, Int?)] = [
                (.input, segment.input), (.output, segment.output),
                (.cacheRead, segment.cacheRead), (.reasoning, segment.reasoning),
            ]
            // A component with no tokens needs no price: there is nothing to multiply,
            // so demanding an entry would report a missing price where there is no
            // spend. A component *with* tokens and no entry is a different fact.
            let spent = components.filter { ($0.1 ?? 0) > 0 }

            var segmentTotal = Decimal(0)
            var segmentPriced = true
            for (component, count) in spent {
                guard let count,
                      let (price, entryVersion) = table.price("\(segment.modelID)#\(component.keySuffix)")
                else {
                    segmentPriced = false
                    break
                }
                segmentTotal += price * Decimal(count)
                version = max(version, entryVersion)
            }
            guard segmentPriced else {
                unpriced.append(segment.modelID)
                continue
            }
            total += segmentTotal
            lines.append(CostLine(modelID: segment.modelID, usd: segmentTotal))
        }

        // **Never a partial total.** One segment with no price means the sum omits
        // spend, and a cost missing a model's spend is a wrong number — the specific
        // failure this type has always refused. Every unpriced model is named, because
        // pricing one of several does not make the total computable.
        guard unpriced.isEmpty else {
            return .notPriced(models: Set(unpriced).sorted())
        }
        // The newest price this figure consumed, never a version it did not use.
        // `version` is a maximum over the entries this computation actually read, so a
        // figure built from `model-a` at table version 1 and `model-b` at version 2
        // reports 2 — the newest price it stood under, not every price it rests on.
        // That is what the field can honestly mean; it is not a claim that one version
        // describes the whole table. A figure that consumed no entry at all — every
        // token count zero, so the total is exact under any table — falls back to the
        // table's current version, since a version of 0 would read as "priced from
        // nothing".
        return .priced(
            usd: total,
            priceTableVersion: max(version, table.currentVersion),
            // One line per model, so model id is a total order here and the sort is
            // stable rather than merely deterministic-ish. Before `preferredProvenance`
            // two lines could carry the same model and this comparator was not a total
            // order at all, so their relative order was whatever the fold happened to
            // produce.
            lines: lines.sorted { $0.modelID < $1.modelID }
        )
    }

    /// A read-only view of the price table for one costing pass. Small enough to be a
    /// value, so a caller cannot hold a half-read table across a later write.
    private struct PriceTable {
        /// Internal rather than private: `prices()` and `modelsMissingAPrice()`
        /// read it, and both are on the lock-holding side already.
        let byKey: [String: (price: Decimal, version: Int)]
        let currentVersion: Int

        init(byKey: [String: (price: Decimal, version: Int)], currentVersion: Int) {
            self.byKey = byKey
            self.currentVersion = currentVersion
        }

        func price(_ key: String) -> (Decimal, Int)? {
            guard let entry = byKey[key] else { return nil }
            return (entry.price, entry.version)
        }
    }
}

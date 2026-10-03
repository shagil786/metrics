// HistoryReading: the recorded-history questions the provider asks, behind a
// seam.
//
// The store is opened lazily by the provider (see `LazyHistory`), because most
// tool calls never touch history at all and opening a database to answer a
// process question would be both slow and rude to the user's Application Support
// directory.
import Foundation
import PortmasterCore

/// The history questions an on-demand alert evaluation and the history tools
/// ask. An injectable seam so a test can read from a seeded store — or refuse —
/// without touching the real database.
public protocol HistoryReading: Sendable {
    func appTrends(since: Date) async throws -> [AppHistoryTrend]
    func resourceSamples(_ resource: HistoryResource, since: Date) async throws -> [ResourceHistoryPoint]
    /// Only apps with at least two readings in the window; see `AppMemorySpan`.
    func appMemorySpans(since: Date) async throws -> [AppMemorySpan]
}

/// History reads over a `HistoryStore`: trends and memory endpoints through the
/// store's reader actor (which keeps the stored models inside it), resource
/// points through the store's own query.
///
/// One reader for the lifetime of the reading, as the app does, so an evaluation
/// that needs both trends and memory endpoints — which is every alert
/// evaluation — does not open a second context over the same store.
public struct StoreHistoryReading: HistoryReading {
    private let store: HistoryStore
    private let readers = ReaderBox()

    public init(storeURL: URL? = nil) throws {
        self.store = try HistoryStore(storeURL: storeURL)
    }

    /// The adapter over an already-open store, for a caller that keeps one
    /// around (the app does, for writing).
    public init(store: HistoryStore) {
        self.store = store
    }

    /// The store at the canonical Application Support location, or nil when it
    /// cannot be opened — so the provider can report that instead of answering
    /// every history tool with "no data".
    public static func defaultStore() -> StoreHistoryReading? {
        try? StoreHistoryReading(storeURL: nil)
    }

    public func appTrends(since: Date) async throws -> [AppHistoryTrend] {
        try await readers.get(store).appTrends(since: since)
    }

    public func resourceSamples(
        _ resource: HistoryResource, since: Date
    ) async throws -> [ResourceHistoryPoint] {
        store.resourceSamples(resource, since: since)
    }

    public func appMemorySpans(since: Date) async throws -> [AppMemorySpan] {
        try await readers.get(store).appMemorySpans(since: since)
    }

    /// Creates the store's reader once. A box rather than a stored `let`,
    /// because a reader cannot be built before the store it reads from.
    private final class ReaderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var reader: HistoryReader?

        func get(_ store: HistoryStore) -> HistoryReader {
            lock.lock()
            defer { lock.unlock() }
            if let reader { return reader }
            let created = store.makeReader()
            reader = created
            return created
        }
    }
}

/// Stands in when history cannot be opened at all. Every read fails with the
/// reason, so an unreachable database reads as a failure rather than as a
/// machine with no history.
public struct UnavailableHistoryReading: HistoryReading {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public func appTrends(since: Date) async throws -> [AppHistoryTrend] { throw MCPToolError(message: message) }
    public func resourceSamples(
        _ resource: HistoryResource, since: Date
    ) async throws -> [ResourceHistoryPoint] { throw MCPToolError(message: message) }
    public func appMemorySpans(since: Date) async throws -> [AppMemorySpan] { throw MCPToolError(message: message) }
}

/// Opens the store on the first history question and keeps it.
///
/// Most tool calls never touch history — a process list, a stop, a container —
/// and opening a database to answer those would be both slow and a write to the
/// user's Application Support directory they never asked for. So the factory runs
/// once, lazily, and only when a history read actually happens.
final class LazyHistory: @unchecked Sendable {
    private let lock = NSLock()
    private let factory: @Sendable () -> any HistoryReading
    private var reading: (any HistoryReading)?

    init(_ factory: @escaping @Sendable () -> any HistoryReading) {
        self.factory = factory
    }

    func get() -> any HistoryReading {
        lock.lock()
        defer { lock.unlock() }
        if let reading { return reading }
        let opened = factory()
        reading = opened
        return opened
    }
}

// SnapshotAcquisition: getting one honest reading of the machine, and keeping
// the most recent one for a moment.
//
// This is where the honesty rule lives. The sampler's "nothing collected yet"
// value is `ObservationSnapshot.empty`, and handing that on as if it were a
// measurement is the one failure mode that would make every other number in a
// payload a lie. So a read waits — for a real reading within a budget — and then
// says plainly that there isn't one yet.
//
// The cache is here rather than in the provider because it only makes sense
// against acquisition: a cached snapshot is one this file collected.
import Foundation
import PortmasterCore

// MARK: - Source

/// One reading of the machine's telemetry.
public protocol SnapshotSource: Sendable {
    /// A snapshot collected after this call started.
    ///
    /// - Throws: `MCPToolError` when no reading arrives within `maxWait`. A
    ///   source must never return `ObservationSnapshot.empty` as an answer: that
    ///   value means "the sampler has not produced anything", which is a fact
    ///   the caller deserves to hear.
    func currentSnapshot(maxWait: TimeInterval) async throws -> ObservationSnapshot
}

/// The live source: one long-lived `SamplingEngine`, started on first use.
///
/// Sampling continues between calls on purpose. Several readings Portmaster
/// reports are differences between sweeps — CPU and disk rates need two sweeps,
/// per-process network needs a `nettop` pass — so a sampler started and polled
/// once per tool call would report "unknown" forever. Keeping one engine alive
/// costs a background cadence and makes every call after the first honest.
public final class LiveSnapshotSource: SnapshotSource, @unchecked Sendable {
    /// The engine a live source collects from. Injected so a caller (or a test)
    /// can supply fixture collectors without this file knowing about them.
    public typealias EngineFactory = @Sendable () -> SamplingEngine

    private let engineFactory: EngineFactory
    private let lock = NSLock()
    private var engine: SamplingEngine?

    /// The production engine: real collectors, standard cadence. `surfaceVisible`
    /// is set by `currentSnapshot` rather than here, since it is a policy about
    /// being asked, not about existing.
    public static func defaultEngine() -> SamplingEngine {
        SamplingEngine(
            systemCollector: MachSystemCollector(),
            processCollector: LibprocProcessCollector(),
            portCollector: LsofPortScanner()
        )
    }

    public init(
        engineFactory: @escaping EngineFactory = { LiveSnapshotSource.defaultEngine() }
    ) {
        self.engineFactory = engineFactory
    }

    /// A reading older than this is stale enough to be worth asking for: the
    /// engine's live cadence is 2-5s, so anything under a second old is already
    /// the answer.
    static let refreshThreshold: TimeInterval = 1

    public func currentSnapshot(maxWait: TimeInterval) async throws -> ObservationSnapshot {
        let engine = self.engineOrStart()
        let requestedAt = Date()
        // Ask for a sweep only when the newest reading is already stale. Refreshing
        // on every attempt would stack a full process sweep per poll while a
        // caller waits, which is the opposite of the conservative cadence the
        // engine is built around.
        if Date().timeIntervalSince(engine.latest.at) > Self.refreshThreshold {
            engine.refreshNow()
        }

        let deadline = requestedAt.addingTimeInterval(max(0, maxWait))
        while Date() < deadline {
            let latest = engine.latest
            // The snapshot's own timestamp is the test: a sweep that *started*
            // after we asked carries `at > requestedAt`, so it cannot be a
            // leftover from before the call.
            if latest.at > requestedAt { return latest }
            try await Task.sleep(nanoseconds: SnapshotAcquisition.pollIntervalNanos)
        }
        let latest = engine.latest
        if latest.at > requestedAt { return latest }
        throw MCPToolError(message: SnapshotAcquisition.notReadyMessage)
    }

    /// The engine, created and started exactly once. `start()` runs its first
    /// tick on the sampling queue, so this call does not block on a port scan.
    private func engineOrStart() -> SamplingEngine {
        lock.lock()
        defer { lock.unlock() }
        if let engine { return engine }
        let fresh = engineFactory()
        // A tool call is a visible surface: read the live cadence, and never let
        // the engine's idle pause strand it between calls.
        fresh.setSurfaceVisible(true)
        fresh.start()
        engine = fresh
        return fresh
    }

    deinit {
        // The timer chain outlives this object otherwise, and keeps sweeping the
        // machine with nothing left to serve.
        engine?.stop()
    }
}

// MARK: - Cache

/// One cached snapshot and the wall time it was taken.
///
/// A class behind a lock because the acquisition is shared by concurrent tool
/// calls: without shared storage, "cache the snapshot for five seconds" would
/// mean nothing.
final class SnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (snapshot: ObservationSnapshot, at: Date)?

    /// The cached snapshot if it is younger than `ttl`. A non-positive `ttl`
    /// never hits, which is how a caller asks for an un-cached read.
    func snapshot(ttl: TimeInterval, now: Date) -> ObservationSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, now.timeIntervalSince(entry.at) < ttl else { return nil }
        return entry.snapshot
    }

    func store(_ snapshot: ObservationSnapshot, at: Date) {
        lock.lock()
        entry = (snapshot, at)
        lock.unlock()
    }
}

// MARK: - Acquisition

/// Collects a snapshot on demand, and serves the last one while it is fresh.
final class SnapshotAcquisition: @unchecked Sendable {
    /// Said when the sampler has not produced a reading yet. Every path that can
    /// report this uses this one string, so a caller sees the same explanation
    /// whichever tool asked.
    public static let notReadyMessage = "No reading available yet; the sampler is still starting."

    /// How often to ask the source again while waiting.
    static let pollIntervalNanos: UInt64 = 50_000_000
    /// Longest any single attempt may spend inside the source. The remaining
    /// budget is re-offered on the next poll instead, so one slow attempt cannot
    /// swallow the whole wait.
    static let maxAttemptWait: TimeInterval = 0.5

    private let source: any SnapshotSource
    private let cache: SnapshotCache
    private let cacheTTL: TimeInterval
    private let snapshotTimeout: TimeInterval
    private let now: @Sendable () -> Date

    init(
        source: any SnapshotSource,
        cacheTTL: TimeInterval,
        snapshotTimeout: TimeInterval,
        now: @escaping @Sendable () -> Date
    ) {
        self.source = source
        self.cache = SnapshotCache()
        self.cacheTTL = cacheTTL
        self.snapshotTimeout = snapshotTimeout
        self.now = now
    }

    /// A snapshot for a read, from the cache when it is fresh enough.
    ///
    /// `forceRefresh` skips the cache for actions that act on live pids: a stop
    /// built from a five-second-old list may target a pid that has since exited
    /// and been reused.
    func snapshot(forceRefresh: Bool = false) async throws -> ObservationSnapshot {
        if !forceRefresh, let cached = cache.snapshot(ttl: cacheTTL, now: now()) {
            return cached
        }
        let reading = try await firstReading()
        cache.store(reading, at: now())
        return reading
    }

    /// Asks the source for a real reading, waiting while the answer is "not yet".
    ///
    /// Only *not yet* is waited on. A source that fails outright fails the call
    /// straight away: retrying a broken collector for the whole budget would
    /// turn a clear error into a slow one, and would leave the caller guessing
    /// which subsystem is at fault. "Not yet" is the one failure worth waiting
    /// out, and it has its own message, so it is recognised by that message
    /// rather than by its type.
    ///
    /// The wait is measured on the real clock: a caller that injects a fixed clock
    /// is testing cache freshness, and a fake wait would either hang or skip the
    /// very wait this exists to guarantee.
    private func firstReading() async throws -> ObservationSnapshot {
        let deadline = Date().addingTimeInterval(max(0, snapshotTimeout))
        while true {
            // Outside the attempt below, so a cancelled caller stops here instead
            // of being caught and retried until the budget runs out.
            try Task.checkCancellation()
            let attempt: Result<ObservationSnapshot, Error>
            do {
                attempt = .success(
                    try await source.currentSnapshot(maxWait: Self.boundedWait(until: deadline))
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A genuine failure: report it now, do not spend the budget on it.
                if !Self.isNotReady(error) {
                    throw MCPToolError.wrapping(error, subsystem: "sampling")
                }
                attempt = .failure(error)
            }
            switch attempt {
            case .success(let reading) where reading.at != .distantPast:
                return reading
            case .success, .failure:
                // Either the source answered with nothing collected, or it said
                // "not yet". Both mean the same thing: keep waiting.
                break
            }
            if Date() >= deadline { throw MCPToolError(message: Self.notReadyMessage) }
            try await Task.sleep(nanoseconds: Self.pollIntervalNanos)
        }
    }

    /// "Not yet" is the one failure a source may raise that is worth waiting out.
    /// Anything else is a real fault in the collector.
    private static func isNotReady(_ error: Error) -> Bool {
        (error as? MCPToolError)?.message == notReadyMessage
    }

    /// Per-attempt wait: what is left of the budget, capped so one slow attempt
    /// cannot spend the whole budget on the source's own timeout.
    private static func boundedWait(until deadline: Date) -> TimeInterval {
        min(max(deadline.timeIntervalSinceNow, 0.05), maxAttemptWait)
    }
}

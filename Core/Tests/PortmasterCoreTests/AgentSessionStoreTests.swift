// Persistence and cost computation for agent sessions. The store registers its
// models explicitly in HistoryStore's container, so a model missing from that list
// would silently never persist — the round-trip test below is what catches it.
import XCTest
import Foundation
@testable import PortmasterCore

final class AgentSessionStoreTests: XCTestCase {

    private func makeStore() throws -> (AgentSessionStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-test-\(UUID().uuidString).sqlite")
        return (try AgentSessionStore(storeURL: url), url)
    }

    // MARK: - Round trip

    func testSessionSurvivesAWriteAndReload() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sessionID = UUID()
        try store.recordSession(
            id: sessionID,
            peerPID: 4242,
            clientName: "probe-agent",
            clientVersion: "1.2.3",
            connectedAt: Date(timeIntervalSince1970: 1000)
        )
        try store.flush()

        let reopened = try AgentSessionStore(storeURL: url)
        let sessions = try reopened.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, sessionID)
        XCTAssertEqual(sessions.first?.clientName, "probe-agent")
        XCTAssertEqual(sessions.first?.peerPID, 4242)
    }

    /// A client that cannot be named is still a session. "Something connected" is
    /// the useful half of the row, so a missing clientInfo is nil rather than a
    /// session that failed to open.
    func testSessionWithoutClientInfoStillRecords() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 0, clientName: nil, clientVersion: nil,
            connectedAt: Date()
        )
        let sessions = try store.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertNil(sessions.first?.clientName)
    }

    /// One process may back several connections. Collapsing them would make
    /// `Identifiable` a lie a SwiftUI List acts on by merging rows.
    func testOnePIDTwoConnectionsAreTwoSessions() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let a = UUID(), b = UUID()
        let now = Date()
        try store.recordSession(id: a, peerPID: 99, clientName: "x", clientVersion: nil, connectedAt: now)
        try store.recordSession(id: b, peerPID: 99, clientName: "x", clientVersion: nil, connectedAt: now.addingTimeInterval(1))

        XCTAssertEqual(try store.sessions().count, 2)
    }

    /// A connection may outlive its process while the socket stays open, so a
    /// session must survive the pid going away with no end time set.
    func testSessionSurvivesProcessExit() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let id = UUID()
        try store.recordSession(id: id, peerPID: 7, clientName: "gone", clientVersion: nil, connectedAt: Date())
        try store.flush()

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertNil(try reopened.sessions().first?.endedAt, "an open socket has no end")
    }

    // MARK: - Usage

    func testUsageRecordsAggregateByLatestNotSum() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        for (i, total) in [100, 250, 400].enumerated() {
            try store.recordUsage(TokenUsageRecord(
                sessionID: sid, recordedAt: Date(timeIntervalSince1970: Double(i)),
                input: total, output: total / 2, cacheRead: nil, reasoning: nil,
                modelID: "m", provenance: .selfReported
            ))
        }

        guard case .reported(let input, let output, _) = try store.usage(for: sid) else {
            return XCTFail("expected reported usage")
        }
        XCTAssertEqual(input, 400)
        XCTAssertEqual(output, 200)
    }

    func testSessionWithNoUsageReadsNotReported() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        XCTAssertEqual(try store.usage(for: sid), .notReported(reason: .awaitingFirstReport))
    }

    // MARK: - Cost

    func testCostUsesDecimalArithmeticExactly() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.setPrice(Decimal(string: "0.0000015")!, modelID: "m")
        try store.setPrice(Decimal(string: "0.000006")!, modelID: "m", component: .output)

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1_000, output: 500,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))

        guard case .priced(let usd, _) = try store.cost(for: sid) else {
            return XCTFail("expected a priced cost")
        }
        // 1000 * 0.0000015 + 500 * 0.000006 = 0.0015 + 0.003 = 0.0045 exactly.
        // Double would not land here, which is why this asserts exact equality.
        XCTAssertEqual(usd, Decimal(string: "0.0045")!)
    }

    func testUnpricedModelIsNotPricedZero() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1_000, output: 500,
            cacheRead: nil, reasoning: nil, modelID: "never-priced", provenance: .selfReported
        ))

        let cost = try store.cost(for: sid)
        XCTAssertEqual(cost, .notPriced(modelID: "never-priced"))
        XCTAssertNotEqual(cost, .priced(usd: Decimal(0), priceTableVersion: 1))
    }

    func testSessionWithNoUsageHasNoCostRatherThanZero() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        XCTAssertEqual(try store.cost(for: sid), .noUsage)
    }

    /// Changing a price re-costs history rather than leaving a stale figure, and the
    /// version changes so a displayed number can be traced to the prices behind it.
    func testPriceChangeBumpsVersionAndRecosts() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")
        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))

        guard case .priced(let before, let versionBefore) = try store.cost(for: sid) else {
            return XCTFail("expected priced")
        }
        XCTAssertEqual(before, Decimal(string: "0.001")!)
        XCTAssertEqual(versionBefore, 1)

        try store.setPrice(Decimal(string: "0.000002")!, modelID: "m")
        guard case .priced(let after, let versionAfter) = try store.cost(for: sid) else {
            return XCTFail("expected priced after change")
        }
        XCTAssertEqual(after, Decimal(string: "0.002")!)
        XCTAssertEqual(versionAfter, 2, "a re-cost must name the prices that produced it")
    }

    // MARK: - Cost wiring to TokenUsage's conflict rule

    /// One agent escalating models mid-session has an unambiguous newest figure, so
    /// it costs. Treating the superseded model as a conflict would block a cost that
    /// has no disagreement in it — the same scoping `TokenUsage.hasModelConflict` uses.
    func testCostSurvivesOneSourceSwitchingModelsMidSession() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        for (offset, model) in [(0.0, "model-a"), (5.0, "model-b")] {
            try store.recordUsage(TokenUsageRecord(
                sessionID: sid, recordedAt: Date(timeIntervalSince1970: offset),
                input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
                modelID: model, provenance: .selfReported
            ))
        }
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-b")

        guard case .priced(let usd, let version) = try store.cost(for: sid) else {
            return XCTFail("a single source switching models is history, not a conflict")
        }
        XCTAssertEqual(usd, Decimal(string: "0.001")!)
        XCTAssertEqual(version, 1)
    }

    /// The other direction, protecting the fix from over-correcting: two sources that
    /// disagree are still a conflict, and the cost stays unpriced with both models named.
    func testCostIsBlockedWhenSourcesDisagreeAboutTheModel() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 1),
            input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "model-a", provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 2),
            input: 2_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "model-b", provenance: .parsedFromLog
        ))
        // Prices for both, so a blocked cost cannot be mistaken for a missing one.
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-a")
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-b")

        XCTAssertEqual(try store.cost(for: sid), .conflict(models: ["model-a", "model-b"]))
    }

    /// A conflict is its own state, not `notPriced`. Both models here are priced, so
    /// reporting a missing price would point the user at the price table — the one
    /// recovery that cannot possibly work, because the block is the disagreement.
    func testConflictIsNotReportedAsAMissingPrice() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 1),
            input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "model-a", provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 2),
            input: 2_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "model-b", provenance: .parsedFromLog
        ))
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-a")
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-b")

        let cost = try store.cost(for: sid)
        XCTAssertNil(cost.usd, "a blocked cost is absence of a figure, never a figure")
        XCTAssertNotEqual(cost, .notPriced(modelID: "model-a"))
        XCTAssertNotEqual(cost, .notPriced(modelID: "model-b"))
        XCTAssertNotEqual(cost, .priced(usd: Decimal(0), priceTableVersion: 1))
        guard case .conflict(let models) = cost else {
            return XCTFail("expected a conflict naming both models")
        }
        XCTAssertEqual(Set(models), ["model-a", "model-b"])
    }

    /// The residual case scoping `hasModelConflict` to one figure per source has to
    /// keep: self-reporting escalates `model-a → model-b` at t=5 while a log adapter,
    /// still reading `model-a`, reports at t=3. Each source is internally consistent,
    /// and they disagree — which is what a conflict is. Ruled a conflict, so the cost
    /// stays blocked rather than being priced against whichever source wins.
    func testCostIsBlockedWhenAnEscalatingSourceIsOutrunByALaggingOne() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 1),
            input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "model-a", provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 3),
            input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "model-a", provenance: .parsedFromLog
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 5),
            input: 4_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "model-b", provenance: .selfReported
        ))
        // Both models priced, so a price is never the reason the cost is missing.
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-a")
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-b")

        XCTAssertEqual(try store.cost(for: sid), .conflict(models: ["model-a", "model-b"]))
    }

    // MARK: - Decimal at rest

    /// The price and the cost survive a real store boundary, still exactly.
    ///
    /// `autosaveEnabled` is off, so a test that never flushes and reopens reads the
    /// in-memory model — it would pass even if SwiftData persisted `Decimal` as a
    /// binary float, and the 7-digit figure asserted elsewhere would come back as
    /// `0.004500000000000001`. Reopening the same URL is the only thing that tests the
    /// value as it lies at rest, which is the value an invoice has to reconcile with.
    func testDecimalCostSurvivesAReopenedStore() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.setPrice(Decimal(string: "0.0000015")!, modelID: "m")
        try store.setPrice(Decimal(string: "0.000006")!, modelID: "m", component: .output)
        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1_000, output: 500,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        try store.flush()

        let reopened = try AgentSessionStore(storeURL: url)
        guard case .priced(let usd, _) = try reopened.cost(for: sid) else {
            return XCTFail("expected a priced cost read back from disk")
        }
        XCTAssertEqual(usd, Decimal(string: "0.0045")!)
    }

    /// The price itself, read back from disk rather than recomputed from the input,
    /// so a coercion shows up as a wrong price and not only as a wrong total.
    func testDecimalPriceIsExactAfterAReopen() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        try store.setPrice(Decimal(string: "0.0000015")!, modelID: "m")
        try store.flush()

        let reopened = try AgentSessionStore(storeURL: url)
        let sid = UUID()
        try reopened.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        // One token: the cost is the price, so any drift in the stored price shows
        // up undiluted.
        try reopened.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))

        guard case .priced(let usd, _) = try reopened.cost(for: sid) else {
            return XCTFail("expected a priced cost")
        }
        XCTAssertEqual(usd, Decimal(string: "0.0000015")!)
    }

    // MARK: - Batched reads

    /// `sessions()` reads records and prices once for the whole list instead of once
    /// per row. Grouping must therefore reproduce the per-session reads exactly — the
    /// batching is only safe while it agrees with `usage(for:)`/`cost(for:)`, and the
    /// sessions here are deliberately unlike each other so a shared-slice mistake has
    /// somewhere to show up.
    func testBatchedSessionReadsMatchThePerSessionReads() throws {
        let (store, url) = try makeStore()
        defer { try? FileManager.default.removeItem(at: url) }

        let base = Date(timeIntervalSince1970: 1_000)

        // Three records, latest per provenance wins: 400 in, not 100+250+400.
        let chatty = UUID()
        try store.recordSession(id: chatty, peerPID: 1, clientName: "chatty", clientVersion: nil, connectedAt: base)
        for (offset, total) in [100, 250, 400].enumerated() {
            try store.recordUsage(TokenUsageRecord(
                sessionID: chatty, recordedAt: base.addingTimeInterval(Double(offset)),
                input: total, output: total / 2, cacheRead: nil, reasoning: nil,
                modelID: "m", provenance: .selfReported
            ))
        }

        // No usage at all: `.noUsage` cost, and the one that used to trigger a
        // full-table price scan for every row.
        let quiet = UUID()
        try store.recordSession(id: quiet, peerPID: 2, clientName: "quiet", clientVersion: nil, connectedAt: base.addingTimeInterval(1))

        // Cache-read tokens, priced on a component beyond input/output.
        let cached = UUID()
        try store.recordSession(id: cached, peerPID: 3, clientName: "cached", clientVersion: nil, connectedAt: base.addingTimeInterval(2))
        try store.recordUsage(TokenUsageRecord(
            sessionID: cached, recordedAt: base, input: 1_000, output: 0,
            cacheRead: 2_000, reasoning: nil, modelID: "m", provenance: .parsedFromLog
        ))

        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")
        try store.setPrice(Decimal(string: "0.000002")!, modelID: "m", component: .output)
        try store.setPrice(Decimal(string: "0.0000005")!, modelID: "m", component: .cacheRead)

        let snapshots = try store.sessions()
        XCTAssertEqual(snapshots.map(\.id), [chatty, quiet, cached], "ordered by connectedAt")
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.usage, try store.usage(for: snapshot.id), "usage for \(snapshot.clientName ?? "?")")
            XCTAssertEqual(snapshot.cost, try store.cost(for: snapshot.id), "cost for \(snapshot.clientName ?? "?")")
        }
        // The cache-read component is included, so agreement cannot come from both
        // paths dropping it.
        guard case .priced(let cached, _) = try store.cost(for: cached) else {
            return XCTFail("expected the cached session to price")
        }
        XCTAssertEqual(cached, Decimal(string: "0.002")!)
    }
}

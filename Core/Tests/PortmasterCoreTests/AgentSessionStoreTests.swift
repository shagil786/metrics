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

        XCTAssertEqual(try store.cost(for: sid), .notPriced(modelID: "model-a/model-b"))
    }
}
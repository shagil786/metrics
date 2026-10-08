// `get_agent_sessions` — the first surface that makes recorded sessions visible.
//
// The thing worth testing is not that rows come back. It is that the three states
// survive the trip to the wire: a session that reported nothing must not reach a
// caller looking like a session that reported zero, and an unpriced model must not
// reach one looking free. A payload that collapsed either to a number would be the
// exact lie the rest of this branch exists to prevent.
//
// Fixtures are built through a real `AgentSessionStore` rather than by constructing
// `AgentSessionSnapshot` directly. That is deliberate: the snapshot's memberwise
// init is internal to `PortmasterCore`, and widening it for a test would make an
// API public for a reason that has nothing to do with a caller needing it.
import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

final class AgentSessionToolTests: XCTestCase {

    private var store: AgentSessionStore!

    override func setUpWithError() throws {
        store = try AgentSessionStore(
            storeURL: makeTemporaryDirectory(prefix: "agent-sessions")
                .appendingPathComponent("a.sqlite")
        )
    }

    override func tearDownWithError() throws {
        store = nil
    }

    // MARK: - Fixtures, written the way the product writes them

    /// Records a session and reads it back, so the snapshot under test is one the
    /// store actually produced rather than one assembled to suit the test.
    /// `connectedAt` is a parameter because `Date()` called twice in one test can
    /// land on the same instant — and the store sorts by it, so a tie orders the
    /// two rows arbitrarily. That is a real property of the data, not a quirk of
    /// the fixture: two agents connecting in the same instant have no defined order,
    /// and `sessions()` says so by sorting on the only timestamp it has.
    private func recorded(
        usage: [(input: Int, output: Int, model: String)],
        prices: [(model: String, input: Decimal)] = [],
        connectedAt: Date = Date()
    ) throws -> AgentSessionSnapshot {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 4242, clientName: nil, clientVersion: nil,
            connectedAt: connectedAt
        )
        for (i, step) in usage.enumerated() {
            for price in prices where price.model == step.model {
                try store.setPrice(price.input, modelID: price.model)
                try store.setPrice(Decimal(0), modelID: price.model, component: .output)
            }
            try store.recordUsage(TokenUsageRecord(
                sessionID: id,
                recordedAt: Date(timeIntervalSince1970: Double(i)),
                input: step.input, output: step.output,
                cacheRead: nil, reasoning: nil,
                modelID: step.model, provenance: .selfReported
            ))
        }
        try store.flush()
        return try XCTUnwrap(store.sessions().first { $0.id == id })
    }

    /// An executor on the **real** provider path, reading the store these tests
    /// write. A stub returning a hand-built list would test the payload against a
    /// list this file assembled, which is exactly the assumption a read tool should
    /// not be trusted on.
    private func executor(openSessionIDs: Set<UUID> = []) throws -> ToolExecutor {
        let store = try XCTUnwrap(self.store)
        let provider = OnDemandProvider(
            sessionReadingFactory: { StoreAgentSessionReading(store: store) }
        )
        return ToolExecutor(
            provider: provider,
            gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
            audit: AuditLog(directory: try makeTemporaryDirectory(prefix: "audit")),
            openSessionIDs: { openSessionIDs }
        )
    }

    /// The tool's payload as a caller would receive it — through the wire, not the
    /// payload struct. Anything lost in serialization is exactly what a caller sees.
    private func wire(
        limit: String? = nil, openSessionIDs: Set<UUID> = []
    ) async throws -> [String: Any] {
        var arguments: [String: String] = [:]
        if let limit { arguments["limit"] = limit }
        let outcome = await (try executor(openSessionIDs: openSessionIDs))
            .execute(name: "get_agent_sessions", arguments: arguments)
        XCTAssertFalse(outcome.isError, outcome.text)
        return try jsonObject(outcome.text)
    }

    // MARK: - The distinction that matters

    /// A session that recorded nothing must not serialize as zeros. This is the
    /// whole reason `TokenUsage` is three-state.
    func testSessionWithNoUsageIsNotZeroTokens() async throws {
        _ = try recorded(usage: [])
        let json = try await wire()
        let usage = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["usage"] as? [String: Any]
        )

        XCTAssertEqual(usage["reported"] as? Bool, false)
        // The key is *absent*, not zero and not null. `JSONEncoder` omits nil
        // optionals, so a caller that reads `inputTokens` gets nothing rather than
        // a number — which is the property that matters. A `0` here would be the
        // lie; an absent key is not.
        XCTAssertNil(usage["inputTokens"], "an absent figure must not be 0")
        XCTAssertNil(usage["outputTokens"])
        XCTAssertNotNil(usage["reason"] as? String, "an absence must name itself")
    }

    /// The inverse, and the pair that matters: a genuinely reported zero is a
    /// measurement and must not read like the case above.
    func testAReportedZeroIsNotTheSameAsNoReport() async throws {
        _ = try recorded(usage: [(0, 0, "m")], prices: [(model: "m", input: Decimal(1))])
        let json = try await wire()
        let usage = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["usage"] as? [String: Any]
        )

        XCTAssertEqual(usage["reported"] as? Bool, true)
        XCTAssertEqual(usage["inputTokens"] as? Int, 0)
        XCTAssertEqual(usage["provenance"] as? String, "selfReported")
        XCTAssertNil(usage["reason"] as? String, "a reported figure has no absence to name")
    }

    /// Provenance survives, so a caller can tell an agent's own count from one
    /// reconstructed from its log.
    func testProvenanceReachesTheCaller() async throws {
        _ = try recorded(usage: [(10, 5, "m")])
        let json = try await wire()
        let usage = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["usage"] as? [String: Any]
        )

        XCTAssertEqual(usage["provenance"] as? String, "selfReported")
    }

    /// A two-source session still names the source its figure came from. The wire shape
    /// carries one pair of counts, so it has to pick a provenance — and it must pick a
    /// real one rather than reporting nil, which would tell a caller nobody reported
    /// this session when in fact two sources did. Summing both instead would be the
    /// other wrong answer: the same tokens counted twice.
    func testTwoProvenanceFigureStillNamesItsSource() async throws {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 1, clientName: nil, clientVersion: nil, connectedAt: Date()
        )
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date(), input: 1_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        // Half a percent apart, so the two agree and the cost is not blocked.
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date().addingTimeInterval(1), input: 1_005, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .parsedFromLog
        ))
        try store.flush()

        let json = try await wire()
        let usage = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["usage"] as? [String: Any]
        )

        XCTAssertEqual(usage["provenance"] as? String, "selfReported")
        XCTAssertEqual(usage["inputTokens"] as? Int, 1_000, "one reading of the session, not two")
    }

    /// A priced session carries its figures and the price-table version that
    /// produced them, so a number can be traced back to the prices behind it.
    func testPricedSessionCarriesItsVersion() async throws {
        _ = try recorded(
            usage: [(1_000, 0, "m")],
            prices: [(model: "m", input: Decimal(string: "0.000002")!)]
        )
        let json = try await wire()
        let cost = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["cost"] as? [String: Any]
        )

        XCTAssertEqual(cost["priced"] as? Bool, true)
        // A string, not a JSON number: a client must not round a money figure.
        XCTAssertNotNil(cost["usd"] as? String)
        // The table version this figure was computed against, which is the table's
        // newest rather than the input price's: the fixture also wrote an output price
        // after the input one, taking the table to version 2. The field names the table
        // a figure was re-costed under, not every price it happens to have used.
        XCTAssertEqual(cost["priceTableVersion"] as? Int, 2)
    }

    /// An unpriced model is not a free one.
    func testUnpricedModelIsNotZeroCost() async throws {
        _ = try recorded(usage: [(1_000, 0, "never-priced")])
        let json = try await wire()
        let cost = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["cost"] as? [String: Any]
        )

        XCTAssertEqual(cost["priced"] as? Bool, false)
        XCTAssertNil(cost["usd"], "an unknown price must not read as $0.00")
        XCTAssertEqual(cost["reason"] as? String, "unpriced")
        XCTAssertEqual(cost["models"] as? [String], ["never-priced"])
    }

    /// A store that would not open is a different answer from no sessions.
    func testUnavailableStoreIsNotAnEmptyList() throws {
        let json = try encode(AgentSessionsPayload(
            sessions: [], storeAvailable: false,
            note: AgentSessionReadingFactory.unavailableMessage
        ))

        XCTAssertEqual(json["storeAvailable"] as? Bool, false)
        XCTAssertTrue((json["sessions"] as? [[String: Any]])?.isEmpty ?? false)
        XCTAssertNotNil(json["note"] as? String, "an unavailable store must say why")
    }

    func testEmptyStoreIsAvailableAndEmpty() throws {
        let json = try encode(AgentSessionsPayload(sessions: [], storeAvailable: true, note: nil))

        XCTAssertEqual(json["storeAvailable"] as? Bool, true)
        XCTAssertTrue((json["sessions"] as? [[String: Any]])?.isEmpty ?? false)
        XCTAssertNil(json["note"] as? String, "no note when the store opened fine")
    }

    private func encode(_ payload: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try JSONEncoder().encode(payload)
            ) as? [String: Any]
        )
    }

    // MARK: - isOpen

    /// Liveness comes from the host's live set, because nothing observes a socket
    /// closing and there is no stored end time to read.
    func testIsOpenComesFromTheLiveSet() async throws {
        let live = try recorded(usage: [(5, 5, "m")])
        let dead = try recorded(usage: [(7, 7, "m")])

        let json = try await wire(openSessionIDs: [live.id])
        let rows = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Bool)? in
            guard let id = row["id"] as? String, let isOpen = row["isOpen"] as? Bool else { return nil }
            return (id, isOpen)
        })

        XCTAssertEqual(byID[live.id.uuidString], true)
        XCTAssertEqual(byID[dead.id.uuidString], false)
    }

    /// With no live set — the stdio path, which observes no socket — every session
    /// reads closed. Accurate rather than unknown: that process has no open sessions.
    func testNoLiveSetMeansEverySessionReadsClosed() async throws {
        _ = try recorded(usage: [(5, 5, "m")])
        let json = try await wire(openSessionIDs: [])
        let row = try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first)

        XCTAssertEqual(row["isOpen"] as? Bool, false)
    }

    /// `endedAt` has no writer and never will until something observes the socket
    /// closing, so it must not appear on the wire implying a stored end time.
    func testNoEndedAtOnTheWire() async throws {
        _ = try recorded(usage: [(5, 5, "m")])
        let json = try await wire()
        let row = try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first)

        XCTAssertNil(row["endedAt"], "nothing observes a socket closing, so there is no end time")
    }

    // MARK: - Ordering

    /// Newest first, as the tool's description tells a client it is. The store
    /// hands rows back oldest-first, so this fails if the page is sliced without
    /// being sorted — which was the bug, and one that still reads plausibly.
    func testSessionsAreNewestFirst() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = try recorded(usage: [(1, 1, "m")], connectedAt: base)
        let newest = try recorded(usage: [(2, 2, "m")], connectedAt: base.addingTimeInterval(2))
        let middle = try recorded(usage: [(3, 3, "m")], connectedAt: base.addingTimeInterval(1))

        let json = try await wire()
        let rows = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        let ids = rows.compactMap { $0["id"] as? String }

        XCTAssertEqual(ids, [newest.id, middle.id, oldest.id].map(\.uuidString))
    }

    func testLimitKeepsTheNewest() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try recorded(usage: [(1, 1, "m")], connectedAt: base)
        let newest = try recorded(usage: [(2, 2, "m")], connectedAt: base.addingTimeInterval(1))

        let json = try await wire(limit: "1")
        let rows = try XCTUnwrap(json["sessions"] as? [[String: Any]])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["id"] as? String, newest.id.uuidString)
    }

    // MARK: - The states a provider has to be able to produce

    /// `storeAvailable: false` has to come out of a provider, not only out of a
    /// hand-built payload. Inverting the flag in either provider — reporting `true`
    /// for a store that would not open — is the "tell a user they have no agent
    /// history" failure, and nothing else would catch it.
    func testAProviderWithNoStoreReportsUnavailable() async throws {
        let provider = OnDemandProvider(
            sessionReadingFactory: { UnavailableAgentSessionReading() }
        )
        let executor = ToolExecutor(
            provider: provider,
            gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
            audit: AuditLog(directory: try makeTemporaryDirectory(prefix: "audit"))
        )

        let outcome = await executor.execute(name: "get_agent_sessions", arguments: [:])
        let json = try jsonObject(outcome.text)

        XCTAssertEqual(json["storeAvailable"] as? Bool, false)
        XCTAssertTrue((json["sessions"] as? [[String: Any]])?.isEmpty ?? false)
        XCTAssertNotNil(json["note"] as? String)
    }

    /// A source disagreement reaches the wire naming the model counted two ways. It is
    /// the case the README spends a paragraph on, so it should not be the one with no
    /// assertion.
    func testAConflictReachesTheWireNamingTheModel() throws {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 1, clientName: nil, clientVersion: nil, connectedAt: Date()
        )
        // One model, two sources, totals far enough apart to be a broken reader rather
        // than noise. The model is priced, so the block cannot be mistaken for a
        // missing price.
        try store.setPrice(Decimal(1), modelID: "m")
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date(), input: 10, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date().addingTimeInterval(1), input: 30, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .parsedFromLog
        ))
        try store.flush()

        let json = try encode(AgentSessionsPayload(
            sessions: [AgentSessionPayload(
                try XCTUnwrap(store.sessions().first { $0.id == id }), isOpen: false
            )],
            storeAvailable: true,
            note: nil
        ))
        let cost = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["cost"] as? [String: Any]
        )

        XCTAssertEqual(cost["priced"] as? Bool, false)
        XCTAssertEqual(cost["reason"] as? String, "conflict")
        XCTAssertEqual(cost["models"] as? [String], ["m"])
        XCTAssertNil(cost["usd"], "a conflict has no figure to report")
    }

    /// A session with no usage at all reads `noUsage`, which is distinct from both
    /// a priced zero and an unpriced model.
    func testNoUsageIsDistinctOnTheWire() async throws {
        _ = try recorded(usage: [])
        let json = try await wire()
        let cost = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["cost"] as? [String: Any]
        )

        XCTAssertEqual(cost["priced"] as? Bool, false)
        XCTAssertEqual(cost["reason"] as? String, "noUsage")
        XCTAssertNil(cost["usd"])
    }

    /// An unknown peer pid is left out rather than sent as 0, which is a plausible
    /// pid and would read as a measurement.
    func testUnknownPeerPIDIsOmittedRatherThanZero() throws {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 0, clientName: nil, clientVersion: nil, connectedAt: Date()
        )
        try store.flush()

        let json = try encode(AgentSessionsPayload(
            sessions: [
                AgentSessionPayload(try XCTUnwrap(store.sessions().first { $0.id == id }), isOpen: false)
            ],
            storeAvailable: true, note: nil
        ))
        let row = try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first)

        XCTAssertNil(row["peerPID"], "an unmeasurable pid must not cross the wire as 0")
    }

    // MARK: - The tool contract

    func testToolIsAReadWithOnlyOptionalArguments() {
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == "get_agent_sessions" }) else {
            return XCTFail("get_agent_sessions missing from the catalog")
        }
        // A read that writes nothing and asks nobody. Anything else would put it
        // behind a confirmation window for no reason.
        XCTAssertEqual(tool.effect, .read)
        XCTAssertTrue(tool.arguments.allSatisfy { !$0.required })
    }

    func testLimitIsValidatedRatherThanCoerced() async throws {
        let executor = try self.executor()
        for bad in ["0", "101", "lots", "-3"] {
            let outcome = await executor.execute(
                name: "get_agent_sessions", arguments: ["limit": bad]
            )
            XCTAssertTrue(
                outcome.isError,
                "limit '\(bad)' should be refused rather than silently coerced"
            )
        }
    }

    func testProviderIsAskedExactlyOnce() async throws {
        let stub = StubProvider()
        let executor = ToolExecutor(
            provider: stub,
            gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
            audit: AuditLog(directory: try makeTemporaryDirectory(prefix: "audit"))
        )
        _ = await executor.execute(name: "get_agent_sessions", arguments: [:])
        XCTAssertEqual(stub.count(of: "agentSessions"), 1)
    }
}
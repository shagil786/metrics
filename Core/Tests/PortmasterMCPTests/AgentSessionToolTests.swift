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
        // optionals, so a caller that reads `segments` gets nothing rather than
        // a list — which is the property that matters. A `[]` here would be the
        // lie; an absent key is not. And `[]` is worse than a `0` here, because
        // a client summing an empty list gets a zero for free rather than having
        // to say it knows of no segments.
        XCTAssertNil(usage["segments"], "an absent figure must not be an empty list")
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
        let segments = try XCTUnwrap(usage["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?["inputTokens"] as? Int, 0)
        XCTAssertNil(usage["reason"] as? String, "a reported figure has no absence to name")
    }

    /// Provenance survives, so a caller can tell an agent's own count from one
    /// reconstructed from its log. It rides on the segment now, which is the only
    /// place it is true of one number.
    func testProvenanceReachesTheCaller() async throws {
        _ = try recorded(usage: [(10, 5, "m")])
        let json = try await wire()
        let usage = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["usage"] as? [String: Any]
        )

        let segment = try XCTUnwrap((usage["segments"] as? [[String: Any]])?.first)
        XCTAssertEqual(segment["provenance"] as? String, "selfReported")
    }

    /// **Two sources on the same model are one segment, not two.** The log reader
    /// counted 1,005 against the agent's own 1,000 — half a percent apart, inside the
    /// tolerance, so this session is *priced* and not a conflict. Both readings measure
    /// the same piece of work, which is why:
    ///
    /// - the segment carries the reading Portmaster believes (1,000, self-reported, the
    ///   same preference costing makes), and
    /// - the other reading rides on `alternateTotals`, keyed by its own provenance.
    ///
    /// A second segment would have been the wrong shape twice over: summing it would
    /// report 2,005 tokens for a session billed on 1,000, and joining it to `cost.lines`
    /// by model would give two rows for one model and no way to tell which one the cost
    /// used. The alternative the payload rejected — silently keeping only one and saying
    /// nothing — is what made an agreeing pair look like a decision nobody made.
    func testASecondReaderOfOneModelIsAnAlternateRatherThanASecondSegment() async throws {
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
        // Priced, so the session has a `lines` half to be joined against below — an
        // unpriced model would have no line and the assertion would pass for free.
        try store.setPrice(Decimal(1), modelID: "m")
        try store.setPrice(Decimal(0), modelID: "m", component: .output)
        try store.flush()

        let json = try await wire()
        let session = try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first)
        let usage = try XCTUnwrap(session["usage"] as? [String: Any])
        let segments = try XCTUnwrap(usage["segments"] as? [[String: Any]])

        XCTAssertEqual(segments.count, 1, "one model is one entry, however many readers it has")
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segment["model"] as? String, "m")
        XCTAssertEqual(segment["provenance"] as? String, "selfReported")
        XCTAssertEqual(segment["inputTokens"] as? Int, 1_000)
        // Keyed on (model, provenance): a reduction on provenance alone would call two
        // *different* models the same fixture and pass while missing this bug entirely.
        XCTAssertEqual(
            segment["alternateTotals"] as? [String: Int],
            ["parsedFromLog": 1_005],
            "the other reader's total must be visible, attributed, and kept off the counts"
        )
        let summed = segments.reduce(0) { $0 + ($1["inputTokens"] as? Int ?? 0) }
        XCTAssertEqual(summed, 1_000,
                       "summing segments must be the session's tokens: 1,000, never 2,005")

        // And the cost half was billed on the same number, not on the one the payload
        // put in an alternate.
        let cost = try XCTUnwrap(session["cost"] as? [String: Any])
        let lines = try XCTUnwrap(cost["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.compactMap { $0["model"] as? String }, ["m"],
                       "a client joining segments to lines by model must find exactly one row")
    }

    /// Two different models, one self-reported and one parsed, are two segments and two
    /// rates — and still no session-wide provenance, because no single source name
    /// describes a figure spanning both.
    ///
    /// The interim payload emitted a summed count plus a `provenance` that had to be nil
    /// for exactly this case, and nil was doing real work: the alternative was naming
    /// whichever segment sorted first, and `"parsedFromLog"` sorts before
    /// `"selfReported"` — so a figure containing self-reported tokens would have been
    /// labelled as coming from a log that never saw them. A client auditing that number
    /// would have been told to trust the wrong reader.
    ///
    /// Removing the field is the stronger fix: there is no aggregate count to mislabel,
    /// so no future ordering change can put one back without failing here. Each segment
    /// still names its own source, so the origin is not lost — it is where it is true.
    func testAFigureSpanningBothSourcesCarriesNoAggregateProvenance() async throws {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 1, clientName: nil, clientVersion: nil, connectedAt: Date()
        )
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date(), input: 1_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "self-model", provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date().addingTimeInterval(1), input: 600, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "parsed-model", provenance: .parsedFromLog
        ))
        try store.flush()

        let json = try await wire()
        let usage = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["usage"] as? [String: Any]
        )

        XCTAssertNil(usage["provenance"] as? String,
                     "two sources contributed, so no session-wide name describes the figure")
        XCTAssertNil(usage["inputTokens"] as? Int,
                     "a summed count would have to discard one model, and its source with it")
        // The counts still arrive — one per model, each naming the source that measured
        // it. A session that reported must never read as one that did not.
        XCTAssertEqual(usage["reported"] as? Bool, true)
        let segments = try XCTUnwrap(usage["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 2)
        let byModel = segments.reduce(into: [String: String]()) {
            $0[$1["model"] as? String ?? "?"] = $1["provenance"] as? String ?? "?"
        }
        XCTAssertEqual(byModel, ["self-model": "selfReported", "parsed-model": "parsedFromLog"])
        // Different models cannot be readings of each other, so neither has an alternate.
        XCTAssertTrue(segments.allSatisfy { $0["alternateTotals"] == nil })
        XCTAssertEqual(
            segments.reduce(0) { $0 + ($1["inputTokens"] as? Int ?? 0) }, 1_600,
            "two models, two segments, one session: the sum is the whole of it"
        )
    }

    /// A priced session carries its figures and the price-table version that
    /// produced them, so a number can be traced back to the prices behind it.
    ///
    /// And it carries the **per-model split** behind that total, because a total is
    /// what a client shows last: asked why a session cost this much, the answer is one
    /// rate per model, and a payload carrying only the sum cannot give it.
    func testPricedSessionCarriesItsVersionAndItsLines() async throws {
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
        // The newest price this figure *used*, not the table's newest: the fixture also
        // wrote an output price after the input one, taking the table to version 2, but
        // the session has no output tokens, so nothing was multiplied by it. Naming it
        // would renumber the figure for a price that did not produce it.
        XCTAssertEqual(cost["priceTableVersion"] as? Int, 1)

        let lines = try XCTUnwrap(cost["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["model"] as? String, "m")
        XCTAssertNotNil(lines.first?["usd"] as? String,
                        "a per-model figure is money too, and floats cannot carry it")
        XCTAssertEqual(lines.first?["usd"] as? String, cost["usd"] as? String,
                       "one model priced means its line and the total are the same figure")
    }

    /// Two models, priced at their own rates, are two lines and one total — and the
    /// line a client shows next to each model adds up to the total it shows above them.
    func testEachModelIsPricedAtItsOwnRateAndTheLinesAddUpToTheTotal() async throws {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 1, clientName: nil, clientVersion: nil, connectedAt: Date()
        )
        // A log parse reports per model, which is the shape that yields two segments:
        // a self-report is one cumulative total and cannot be split after the fact.
        for (model, input) in [("model-a", 1_000), ("model-b", 500)] {
            try store.recordUsage(TokenUsageRecord(
                sessionID: id, recordedAt: Date(), input: input, output: 0,
                cacheRead: nil, reasoning: nil, modelID: model, provenance: .parsedFromLog
            ))
        }
        try store.setPrice(Decimal(string: "0.0000001")!, modelID: "model-a")
        try store.setPrice(Decimal(0), modelID: "model-a", component: .output)
        try store.setPrice(Decimal(string: "0.0000036")!, modelID: "model-b")
        try store.setPrice(Decimal(0), modelID: "model-b", component: .output)
        try store.flush()

        let json = try await wire()
        let cost = try XCTUnwrap(
            (try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first))["cost"] as? [String: Any]
        )

        let lines = try XCTUnwrap(cost["lines"] as? [[String: Any]])
        let byModel = lines.reduce(into: [String: String]()) {
            $0[$1["model"] as? String ?? "?"] = $1["usd"] as? String
        }
        XCTAssertEqual(byModel, ["model-a": "0.0001", "model-b": "0.0018"],
                       "each model's line is its own rate applied to its own tokens")
        XCTAssertEqual(cost["usd"] as? String, "0.0019",
                       "and the total is the sum of the lines, not a third computation")
    }

    /// The one assertion the whole segment shape exists to make possible: a session that
    /// ran two models says so, in both halves of its payload.
    ///
    /// The interim payload carried one pair of counts and one provenance, so it had to
    /// pick a model and the other vanished — not as a zero, but as *nothing*: a client
    /// asking "what did this session cost" was told one number, with no way to learn it
    /// was two rates. Asserted on the encoded session rather than on either payload
    /// struct, because the wire is the contract and a client never sees the Swift.
    ///
    /// Built through a real store rather than from a hand-made `AgentSessionSnapshot`:
    /// the snapshot's memberwise init is internal to `PortmasterCore`, and widening it
    /// for a test would make an API public for a reason no caller has. The records are
    /// written as a log parse writes them — one per model — which is the only shape a
    /// fold can segment; a self-report is one cumulative total and cannot be split after
    /// the fact.
    func testSessionPayloadCarriesBothModelSegments() throws {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 1, clientName: "escalated", clientVersion: nil, connectedAt: Date()
        )
        for (model, input, output) in [("model-a", 100, 50), ("model-b", 200, 75)] {
            try store.recordUsage(TokenUsageRecord(
                sessionID: id, recordedAt: Date(), input: input, output: output,
                cacheRead: nil, reasoning: nil, modelID: model, provenance: .parsedFromLog
            ))
        }
        // Priced on input alone, so each line is exactly one multiplication and the
        // figure asserted on below is a number a reader can check by hand.
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-a")
        try store.setPrice(Decimal(0), modelID: "model-a", component: .output)
        try store.setPrice(Decimal(string: "0.0000018")!, modelID: "model-b")
        try store.setPrice(Decimal(0), modelID: "model-b", component: .output)
        try store.flush()

        let payload = AgentSessionPayload(
            try XCTUnwrap(store.sessions().first { $0.id == id }), isOpen: true
        )
        let encoded = try JSONEncoder().encode(payload)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertTrue(text.contains("model-a"))
        XCTAssertTrue(text.contains("model-b"))
        XCTAssertTrue(text.contains("0.0001"), "model-a's own line, not just the total")
        // The payload must not collapse to one figure: the whole point of segments is
        // that a client can see there were two rates.
        XCTAssertFalse(text.contains("\"segments\":[]"))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let usage = try XCTUnwrap(object["usage"] as? [String: Any])
        let segments = try XCTUnwrap(usage["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 2, "two models, two segments, not one collapsed total")
        XCTAssertEqual(
            segments.compactMap { $0["model"] as? String }.sorted(), ["model-a", "model-b"]
        )
    }

    /// **The two halves must bill the same tokens.** A client shows `usage.segments`
    /// beside `cost.lines` — one number for "how much work", one for "what it cost" — so
    /// a figure where they count different work is a row whose two numbers cannot both
    /// be right, and nothing about it looks wrong.
    ///
    /// Priced at exactly one dollar per input token, which turns each cost line into
    /// that model's token count and lets the two halves be compared without doing any
    /// arithmetic the reader has to trust. The fixture deliberately includes a model with
    /// **two** readers: that is where the halves came apart before, because usage
    /// emitted both readings as segments while the cost billed the preferred one.
    func testUsageSegmentsAndCostLinesBillTheSameTokens() async throws {
        let id = UUID()
        try store.recordSession(
            id: id, peerPID: 1, clientName: nil, clientVersion: nil, connectedAt: Date()
        )
        // Two readers of one model, inside the tolerance, so it is priced — and only one
        // of them may be billed.
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date(), input: 1_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "model-a", provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date().addingTimeInterval(1), input: 1_005, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "model-a", provenance: .parsedFromLog
        ))
        // A second model with a single reader, so the join has to hold for both kinds.
        try store.recordUsage(TokenUsageRecord(
            sessionID: id, recordedAt: Date(), input: 500, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "model-b", provenance: .parsedFromLog
        ))
        for model in ["model-a", "model-b"] {
            try store.setPrice(Decimal(1), modelID: model)
            try store.setPrice(Decimal(0), modelID: model, component: .output)
        }
        try store.flush()

        let json = try await wire()
        let session = try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first)
        let segments = try XCTUnwrap(
            (try XCTUnwrap(session["usage"] as? [String: Any]))["segments"] as? [[String: Any]]
        )
        let cost = try XCTUnwrap(session["cost"] as? [String: Any])
        let lines = try XCTUnwrap(cost["lines"] as? [[String: Any]])

        // Joinable one-to-one first: a model appearing on both sides twice, or only on
        // one, is the shape that made the join impossible before.
        let segmentModels = segments.compactMap { $0["model"] as? String }.sorted()
        let lineModels = lines.compactMap { $0["model"] as? String }.sorted()
        XCTAssertEqual(segmentModels, ["model-a", "model-b"])
        XCTAssertEqual(lineModels, segmentModels, "both halves must name the same models")

        // And then equal token for token, which a price of $1 per token makes literal.
        let lineByModel = lines.reduce(into: [String: String]()) {
            $0[$1["model"] as? String ?? "?"] = $1["usd"] as? String
        }
        for segment in segments {
            let model = try XCTUnwrap(segment["model"] as? String)
            XCTAssertEqual(
                lineByModel[model], String(try XCTUnwrap(segment["inputTokens"] as? Int)),
                "model \(model): the tokens counted must be the tokens billed"
            )
        }
        XCTAssertEqual(cost["usd"] as? String, "1500",
                       "1,000 believed of model-a plus 500 of model-b, not 2,005")
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
        // A line behind a total that does not exist would be a figure with nothing to add
        // up to, and the same is true of a disagreement nothing disagreed about.
        XCTAssertNil(cost["lines"])
        XCTAssertNil(cost["disagreements"])
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

    /// A source disagreement reaches both halves of the wire, and neither half picks a
    /// reader. It is the case the README spends a paragraph on, so it should not be the
    /// one with no assertion — and a model name alone is not enough, because the repair
    /// is picking a reader, which needs to know what each one said.
    ///
    /// **The usage half is the assertion this task exists for.** Cost says `priced: false`
    /// and refuses a figure; if usage then handed back one reading's count as if it were
    /// the answer, the same payload would carry a confident token count beside a refusal
    /// to cost it, and the client would have to know which to believe. So a contested
    /// model keeps its segment — the model is real and still visible — with **null**
    /// counts and null provenance, and both readings in `alternateTotals`. Null rather
    /// than 0 because tokens *were* counted; null rather than one reader's number
    /// because neither reading is believed.
    func testAConflictNamesBothTotalsAndLeavesUsageWithoutACountItCanTrust() throws {
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
        let session = try XCTUnwrap((json["sessions"] as? [[String: Any]])?.first)
        let cost = try XCTUnwrap(session["cost"] as? [String: Any])

        XCTAssertEqual(cost["priced"] as? Bool, false)
        XCTAssertEqual(cost["reason"] as? String, "conflict")
        // `models` names the unpriced ones only; a contested model is named by
        // `disagreements`, which carries its numbers too, and two lists of the same ids
        // would be two answers to one question.
        XCTAssertNil(cost["models"])
        XCTAssertNil(cost["usd"], "a conflict has no figure to report")
        XCTAssertNil(cost["lines"], "and no line behind one either")

        let disagreements = try XCTUnwrap(cost["disagreements"] as? [[String: Any]])
        let entry = try XCTUnwrap(disagreements.first)
        XCTAssertEqual(entry["model"] as? String, "m")
        // Keyed by the provenance's raw value, because a client has no way to resolve a
        // Swift case name to itself — and both sides of it, because the user is being
        // asked to choose.
        XCTAssertEqual(
            entry["totals"] as? [String: Int],
            ["selfReported": 10, "parsedFromLog": 30],
            "a disagreement the client cannot act on is just an assertion that something is wrong"
        )

        // The usage half must not contradict the refusal above.
        let usage = try XCTUnwrap(session["usage"] as? [String: Any])
        XCTAssertEqual(usage["reported"] as? Bool, true,
                       "tokens were counted — the session is not an unreported one")
        let segments = try XCTUnwrap(usage["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1, "the model is still visible; it is its counts that are absent")
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segment["model"] as? String, "m")
        XCTAssertNil(segment["inputTokens"], "no reading of a contested model may be presented as the count")
        XCTAssertNil(segment["outputTokens"])
        XCTAssertNil(segment["provenance"] as? String,
                     "naming either reader would pick a winner the cost refused to pick")
        XCTAssertEqual(
            segment["alternateTotals"] as? [String: Int],
            ["selfReported": 10, "parsedFromLog": 30],
            "both readings, which on a contested segment are the only numbers there are"
        )
        XCTAssertEqual(
            segments.filter { $0["inputTokens"] != nil }.count, 0,
            "a session whose cost is refused must offer no count a client could total"
        )
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

    /// Pressure reaches the wire as integers when a reading exists, and the keys
    /// are absent — not null and not zero — when none does: the same absent-key
    /// contract the usage and pid figures follow.
    func testPressureReadsReachTheWireAsIntegersOrNotAtAll() async throws {
        let base = Date(timeIntervalSince1970: 1_000)
        let none = try recorded(usage: [], connectedAt: base)
        let some = try recorded(usage: [], connectedAt: base.addingTimeInterval(1))
        try store.recordPressure(sessionID: some.id, tokensLeft: 1_234)
        try store.flush()

        let json = try await wire()
        let rows = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        let noneRow = try XCTUnwrap(rows.first { $0["id"] as? String == none.id.uuidString })
        XCTAssertNil(noneRow["tokensLeftFirst"], "no reading is an absent key, never null")
        XCTAssertNil(noneRow["tokensLeftWorst"], "no reading is an absent key, never null")
        let someRow = try XCTUnwrap(rows.first { $0["id"] as? String == some.id.uuidString })
        XCTAssertEqual(someRow["tokensLeftFirst"] as? Int, 1_234)
        XCTAssertEqual(someRow["tokensLeftWorst"] as? Int, 1_234)
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

    // MARK: - Chain edges

    func testHandoffEdgesReachTheWireAndUnlinkedSessionsOmitThem() async throws {
        let sourceID = UUID(), targetID = UUID(), loneID = UUID()
        try store.recordSession(id: sourceID, peerPID: 1, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 100))
        try store.flush()
        _ = try store.recordHandoff(sourceID: sourceID, targetPID: 4242, targetName: "codex")
        try store.recordSession(id: targetID, peerPID: 4242, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 200))
        try store.recordSession(id: loneID, peerPID: 7, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 300))
        try store.flush()

        let json = try await wire()
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])

        let source = try XCTUnwrap(sessions.first { $0["id"] as? String == sourceID.uuidString })
        XCTAssertEqual(source["handedOffTo"] as? String, targetID.uuidString)
        XCTAssertNil(source["handedOffFrom"])
        XCTAssertNil(source["handoffTargetPID"], "the wire carries edges, not spawn plumbing")

        let target = try XCTUnwrap(sessions.first { $0["id"] as? String == targetID.uuidString })
        XCTAssertEqual(target["handedOffFrom"] as? String, sourceID.uuidString)
        XCTAssertNil(target["handedOffTo"])

        let lone = try XCTUnwrap(sessions.first { $0["id"] as? String == loneID.uuidString })
        XCTAssertNil(lone["handedOffFrom"], "absent key, not null and not zero")
        XCTAssertNil(lone["handedOffTo"])
    }
}
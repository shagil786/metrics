// Persistence and cost computation for agent sessions. The store owns its own
// container at `agent-sessions.sqlite`, so a model missing from that list would
// silently never persist — the round-trip test below is what catches it.
import XCTest
import Foundation
@testable import PortmasterCore

final class AgentSessionStoreTests: XCTestCase {

    /// A store in a directory of its own, removed when the test ends.
    ///
    /// A directory rather than a bare `.sqlite` path because SQLite writes two sidecar
    /// files beside the database — `-wal` and `-shm` — and deleting only the file named
    /// in the path leaves both behind, which is how a test run leaks two files per test.
    /// Self-registering teardown rather than a `defer` in each test, matching
    /// `TestJSON.makeTemporaryDirectory`: a `defer` that runs after a test has failed
    /// adds a second, unrelated error to the output.
    private func makeStore() throws -> AgentSessionStore {
        try makeStoreOnDisk().0
    }

    /// The same store with the path it was opened at, for the tests that reopen the
    /// file and read back what was flushed.
    private func makeStoreOnDisk() throws -> (AgentSessionStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("agent-sessions.sqlite")
        return (try AgentSessionStore(storeURL: url), url)
    }

    // MARK: - Round trip

    func testSessionSurvivesAWriteAndReload() throws {
        let (store, url) = try makeStoreOnDisk()

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
        let store = try makeStore()

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
        let store = try makeStore()

        let a = UUID(), b = UUID()
        let now = Date()
        try store.recordSession(id: a, peerPID: 99, clientName: "x", clientVersion: nil, connectedAt: now)
        try store.recordSession(id: b, peerPID: 99, clientName: "x", clientVersion: nil, connectedAt: now.addingTimeInterval(1))

        XCTAssertEqual(try store.sessions().count, 2)
    }

    /// A connection may outlive its process while the socket stays open, so a
    /// session must survive the pid going away with no end time set.
    func testSessionSurvivesProcessExit() throws {
        let (store, url) = try makeStoreOnDisk()

        let id = UUID()
        try store.recordSession(id: id, peerPID: 7, clientName: "gone", clientVersion: nil, connectedAt: Date())
        try store.flush()

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertNil(try reopened.sessions().first?.endedAt, "an open socket has no end")
    }

    // MARK: - Usage

    func testUsageRecordsAggregateByLatestNotSum() throws {
        let store = try makeStore()

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        for (i, total) in [100, 250, 400].enumerated() {
            try store.recordUsage(TokenUsageRecord(
                sessionID: sid, recordedAt: Date(timeIntervalSince1970: Double(i)),
                input: total, output: total / 2, cacheRead: nil, reasoning: nil,
                modelID: "m", provenance: .selfReported
            ))
        }

        guard case .reported(let segments) = try store.usage(for: sid),
              let only = segments.first else {
            return XCTFail("expected one reported segment")
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(only.input, 400)
        XCTAssertEqual(only.output, 200)
    }

    func testSessionWithNoUsageReadsNotReported() throws {
        let store = try makeStore()

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        XCTAssertEqual(try store.usage(for: sid), .notReported(reason: .awaitingFirstReport))
    }

    // MARK: - Cost

    func testCostUsesDecimalArithmeticExactly() throws {
        let store = try makeStore()

        try store.setPrice(Decimal(string: "0.0000015")!, modelID: "m")
        try store.setPrice(Decimal(string: "0.000006")!, modelID: "m", component: .output)

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1_000, output: 500,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))

        guard case .priced(let usd, _, _) = try store.cost(for: sid) else {
            return XCTFail("expected a priced cost")
        }
        // 1000 * 0.0000015 + 500 * 0.000006 = 0.0015 + 0.003 = 0.0045 exactly.
        // Double would not land here, which is why this asserts exact equality.
        XCTAssertEqual(usd, Decimal(string: "0.0045")!)
    }

    func testUnpricedModelIsNotPricedZero() throws {
        let store = try makeStore()

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1_000, output: 500,
            cacheRead: nil, reasoning: nil, modelID: "never-priced", provenance: .selfReported
        ))

        let cost = try store.cost(for: sid)
        XCTAssertEqual(cost, .notPriced(models: ["never-priced"]))
        XCTAssertNotEqual(cost, .priced(usd: Decimal(0), priceTableVersion: 1, lines: []))
    }

    func testSessionWithNoUsageHasNoCostRatherThanZero() throws {
        let store = try makeStore()

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        XCTAssertEqual(try store.cost(for: sid), .noUsage)
    }

    /// Changing a price re-costs history rather than leaving a stale figure, and the
    /// version changes so a displayed number can be traced to the prices behind it.
    func testPriceChangeBumpsVersionAndRecosts() throws {
        let store = try makeStore()

        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")
        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))

        guard case .priced(let before, let versionBefore, _) = try store.cost(for: sid) else {
            return XCTFail("expected priced")
        }
        XCTAssertEqual(before, Decimal(string: "0.001")!)
        XCTAssertEqual(versionBefore, 1)

        try store.setPrice(Decimal(string: "0.000002")!, modelID: "m")
        guard case .priced(let after, let versionAfter, _) = try store.cost(for: sid) else {
            return XCTFail("expected priced after change")
        }
        XCTAssertEqual(after, Decimal(string: "0.002")!)
        XCTAssertEqual(versionAfter, 2, "a re-cost must name the prices that produced it")
    }

    // MARK: - Cost wiring to TokenUsage's conflict rule

    /// One agent escalating models mid-session costs rather than blocking. This pins the
    /// current behaviour, not its soundness: a self-report is one cumulative total, so
    /// the newest reading still carries the old model's tokens inside it and the whole
    /// total is priced at the newest model's rate — a figure no invoice carries. The
    /// fold cannot separate that, because the old model's tokens are inside the total
    /// with nothing marking where they stop, so this stays a **documented limitation**
    /// rather than a per-model split, and asserting it is what stops it being forgotten.
    /// A `parsedFromLog` escalation is the opposite case, because those figures are
    /// disjoint: see `testTwoModelsArePricedAtTheirOwnRatesAndSummed`.
    func testCostSurvivesOneSourceSwitchingModelsMidSession() throws {
        let store = try makeStore()

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

        // One segment, not two. The two self-reports are prefixes of a single
        // cumulative total, so treating them as two models would price 1,000 tokens
        // twice — a different unsound figure from the one this limitation admits to.
        guard case .reported(let segments) = try store.usage(for: sid) else {
            return XCTFail("expected a reported usage")
        }
        XCTAssertEqual(segments.map(\.modelID), ["model-b"])

        guard case .priced(let usd, let version, let lines) = try store.cost(for: sid) else {
            return XCTFail("a single source switching models is not two sources disagreeing")
        }
        XCTAssertEqual(usd, Decimal(string: "0.001")!)
        XCTAssertEqual(version, 1)
        XCTAssertEqual(lines.map(\.modelID), ["model-b"])
    }

    /// Two models at different rates must be priced at their own rates and summed.
    /// Pricing a mixed total at one rate is the known-unsound case segments exist to
    /// remove, so this is the assertion the whole type change is for. Both readings come
    /// from a log parse, whose per-model figures are disjoint — the self-report path is
    /// the one that cannot be split, and `testCostSurvivesOneSourceSwitchingModelsMidSession`
    /// says why.
    func testTwoModelsArePricedAtTheirOwnRatesAndSummed() throws {
        let (store, _) = try makeStoreOnDisk()
        let session = UUID()
        try store.recordSession(
            id: session, peerPID: 1, clientName: "escalated", clientVersion: nil,
            connectedAt: Date()
        )
        let at = Date()
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: at, input: 100, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "model-a", provenance: .parsedFromLog
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: at, input: 900, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "model-b", provenance: .parsedFromLog
        ))
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-a")
        try store.setPrice(Decimal(string: "0.000002")!, modelID: "model-b")
        try store.flush()

        guard case .priced(let usd, _, let lines) = try store.cost(for: session) else {
            return XCTFail("expected a priced total")
        }
        XCTAssertEqual(usd, Decimal(string: "0.0019")!)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.first(where: { $0.modelID == "model-a" })?.usd,
                       Decimal(string: "0.0001")!)
        XCTAssertEqual(lines.first(where: { $0.modelID == "model-b" })?.usd,
                       Decimal(string: "0.0018")!)
    }

    /// One priced and one unpriced model must report the absence, naming the model,
    /// and never a total missing that model's cost — a partial cost is a wrong number.
    func testOneUnpricedModelSuppressesTheWholeTotal() throws {
        let (store, _) = try makeStoreOnDisk()
        let session = UUID()
        try store.recordSession(
            id: session, peerPID: 1, clientName: "partial", clientVersion: nil,
            connectedAt: Date()
        )
        let at = Date()
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: at, input: 100, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "priced", provenance: .parsedFromLog
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: at, input: 900, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "unpriced", provenance: .parsedFromLog
        ))
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "priced")
        try store.flush()

        guard case .notPriced(let models) = try store.cost(for: session) else {
            return XCTFail("expected notPriced, got \(try store.cost(for: session))")
        }
        XCTAssertEqual(models, ["unpriced"])
    }

    /// Two sources counting one model the same way describe one piece of work twice, and
    /// only one of them may be billed. This is the case agreement is silent about:
    /// `hasMaterialDisagreement` returns nothing below the tolerance, so nothing blocks
    /// the cost — but the two readings are still two segments, because they are keyed on
    /// their provenance. Priced together, a 1,000-token session whose agent also had a
    /// log parse costs as 2,000 and reports two lines for one model's work.
    func testAgreeingProvenancesOnOneModelArePricedOnceNotSummed() throws {
        let store = try makeStore()
        let session = UUID()
        try store.recordSession(
            id: session, peerPID: 1, clientName: "agreed", clientVersion: nil,
            connectedAt: Date()
        )
        let at = Date()
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: at, input: 1_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        // Half a percent apart: inside the 1% tolerance, so this is noise rather than a
        // broken reader, and the cost is produced rather than blocked.
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: at.addingTimeInterval(1), input: 1_005, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .parsedFromLog
        ))
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")
        try store.flush()

        // Agreement is not one source: both readings survive the fold, because the
        // disagreement rule compares them rather than discarding one.
        guard case .reported(let segments) = try store.usage(for: session) else {
            return XCTFail("expected both provenances to survive the fold")
        }
        XCTAssertEqual(segments.count, 2)

        guard case .priced(let usd, _, let lines) = try store.cost(for: session) else {
            return XCTFail("agreeing sources are not a conflict: \(try store.cost(for: session))")
        }
        XCTAssertEqual(lines.count, 1, "one model's work is one line")
        XCTAssertEqual(lines.first?.modelID, "m")
        // 1000 * 0.000001, the self-report — not 1000 + 1005 of the same tokens.
        XCTAssertEqual(usd, Decimal(string: "0.001")!)
        XCTAssertNotEqual(usd, Decimal(string: "0.002005")!, "two readings of one session are not added")
    }

    func testSameModelDisagreementSuppressesTheCostAndNamesBothTotals() throws {
        let store = try makeStore()
        let session = UUID()
        try store.recordSession(
            id: session, peerPID: 1, clientName: "disagree", clientVersion: nil,
            connectedAt: Date()
        )
        let at = Date()
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: at, input: 1000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: at, input: 1200, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .parsedFromLog
        ))
        // Priced, so the block cannot be mistaken for a missing price: "enter a price"
        // would do nothing here, and the repair is choosing a source.
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")
        try store.flush()

        guard case .conflict(let disagreements) = try store.cost(for: session),
              let only = disagreements.first else {
            return XCTFail("expected a conflict")
        }
        XCTAssertEqual(only.modelID, "m")
        XCTAssertEqual(only.totals[.selfReported], 1000)
        XCTAssertEqual(only.totals[.parsedFromLog], 1200)
    }

    /// A conflict is its own state, not `notPriced`. The model is priced here, so
    /// reporting a missing price would point the user at the price table — the one
    /// recovery that cannot possibly work, because the block is the disagreement.
    func testConflictIsNotReportedAsAMissingPrice() throws {
        let store = try makeStore()
        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 1),
            input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "m", provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(timeIntervalSince1970: 2),
            input: 2_000, output: 0, cacheRead: nil, reasoning: nil,
            modelID: "m", provenance: .parsedFromLog
        ))
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")

        let cost = try store.cost(for: sid)
        XCTAssertNil(cost.usd, "a blocked cost is absence of a figure, never a figure")
        XCTAssertNotEqual(cost, .notPriced(models: ["m"]))
        XCTAssertNotEqual(cost, .priced(usd: Decimal(0), priceTableVersion: 1, lines: []))
        guard case .conflict = cost else {
            return XCTFail("expected a conflict naming the model counted two ways")
        }
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
        let (store, url) = try makeStoreOnDisk()

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
        guard case .priced(let usd, _, _) = try reopened.cost(for: sid) else {
            return XCTFail("expected a priced cost read back from disk")
        }
        XCTAssertEqual(usd, Decimal(string: "0.0045")!)
    }

    /// The price itself, read back from disk rather than recomputed from the input,
    /// so a coercion shows up as a wrong price and not only as a wrong total.
    func testDecimalPriceIsExactAfterAReopen() throws {
        let (store, url) = try makeStoreOnDisk()

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

        guard case .priced(let usd, _, _) = try reopened.cost(for: sid) else {
            return XCTFail("expected a priced cost")
        }
        XCTAssertEqual(usd, Decimal(string: "0.0000015")!)
    }

    /// Sixteen significant figures, which is the point of storing prices as text.
    ///
    /// A `Double` has ~15, so a price held as one cannot come back as the digits that
    /// went in: stored in a `DECIMAL` column — which SQLite implements as a binary
    /// float — `0.1234567890123456` returns as `0.123456789012346`, and this assertion
    /// fails on the last digit. A short value like `0.0000015` cannot catch that,
    /// because `Double`→`Decimal` reconstructs the shortest decimal that round-trips
    /// and lands back on the original; that is exactly why the short reopen tests are
    /// kept but are not the ones to trust.
    func testSixteenDigitPriceSurvivesTheStoreExactly() throws {
        let (store, url) = try makeStoreOnDisk()

        let written = Decimal(string: "0.1234567890123456")!
        try store.setPrice(written, modelID: "m")
        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 1, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        try store.flush()

        let reopened = try AgentSessionStore(storeURL: url)
        guard case .priced(let usd, _, _) = try reopened.cost(for: sid) else {
            return XCTFail("expected a priced cost read back from disk")
        }
        XCTAssertEqual(usd, written, "the stored price is the price that went in, digit for digit")
    }

    /// A high-precision price multiplied by a real token count, so the digits have to
    /// survive both the write and the arithmetic, not merely sit in a file.
    func testSixteenDigitPriceMultipliesExactlyAfterAReopen() throws {
        let (store, url) = try makeStoreOnDisk()

        let written = Decimal(string: "0.0000001234567890123456")!
        try store.setPrice(written, modelID: "m")
        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 777, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        try store.flush()

        let reopened = try AgentSessionStore(storeURL: url)
        guard case .priced(let usd, _, _) = try reopened.cost(for: sid) else {
            return XCTFail("expected a priced cost read back from disk")
        }
        XCTAssertEqual(usd, written * Decimal(777))
    }

    // MARK: - Tied timestamps

    /// Many reports of one instant. `latestPerSegment` keeps the first of a tied set,
    /// so the order of tied rows decides which figure wins — and the batched and
    /// per-session reads are two queries with different plans, which SQLite makes no
    /// promise to return tied rows in the same order for. Without a stable order the
    /// same session costs two different amounts depending on which API asked: measured
    /// at 39 disagreements in 40 tied sessions.
    ///
    /// *Which* tied record wins is arbitrary — the report order carries no sequence
    /// number to arbitrate — so the assertion is not that a particular record wins. It
    /// is that every path picks the same one, and keeps picking it.
    func testTiedTimestampsCostTheSameWhicheverPathReadsThem() throws {
        let store = try makeStore()

        let sid = UUID()
        try store.recordSession(id: sid, peerPID: 1, clientName: "a", clientVersion: nil, connectedAt: Date())
        let instant = Date(timeIntervalSince1970: 5)
        for n in 0..<8 {
            try store.recordUsage(TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: instant,
                input: 1_000 + n, output: 0, cacheRead: nil, reasoning: nil,
                modelID: "m", provenance: .selfReported
            ))
        }
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")

        let viaCost = try store.cost(for: sid)
        let viaUsage = try store.usage(for: sid)
        let snapshot = try XCTUnwrap(try store.sessions().first)

        XCTAssertEqual(snapshot.cost, viaCost, "one session, one cost")
        XCTAssertEqual(snapshot.usage, viaUsage)
        // Re-read after the batched fetch has run, so a stable answer also has to be
        // stable across both paths having been taken.
        XCTAssertEqual(try store.cost(for: sid), viaCost)
        XCTAssertEqual(try store.sessions().first?.cost, viaCost)

        // The winner is one of the tied reports — not a figure from nowhere, and not a
        // sum of them.
        guard case .reported(let segments) = viaUsage, let input = segments.first?.input else {
            return XCTFail("expected a reported usage")
        }
        XCTAssertTrue((1_000..<1_008).contains(input), "one tied report wins: \(input)")
    }

    // MARK: - Batched reads

    /// `sessions()` reads records and prices once for the whole list instead of once
    /// per row. Grouping must therefore reproduce the per-session reads exactly — the
    /// batching is only safe while it agrees with `usage(for:)`/`cost(for:)`, and the
    /// sessions here are deliberately unlike each other so a shared-slice mistake has
    /// somewhere to show up.
    func testBatchedSessionReadsMatchThePerSessionReads() throws {
        let store = try makeStore()

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
        guard case .priced(let cached, _, _) = try store.cost(for: cached) else {
            return XCTFail("expected the cached session to price")
        }
        XCTAssertEqual(cached, Decimal(string: "0.002")!)
    }

    // MARK: - Retention & clear

    /// "Clear All History" has to mean it. Read through a **reopened** store, because
    /// the user clears the database and the app reads it back from disk: a clear that
    /// only emptied the in-memory context would pass a check against the live store
    /// while every row stayed in the file.
    ///
    /// Asserted field by field rather than as a row count, because a count of zero from
    /// the session list alone would still leave the usage records — the token counts —
    /// behind, which is the half of the data this is about.
    func testClearAllLeavesNoSessionAndNoUsageBehind() throws {
        let (store, url) = try makeStoreOnDisk()
        let sid = UUID()
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")
        try store.recordSession(
            id: sid, peerPID: 4242, clientName: "probe-agent", clientVersion: "1.2.3",
            connectedAt: Date(timeIntervalSince1970: 1000)
        )
        try store.recordUsage(TokenUsageRecord(
            sessionID: sid, recordedAt: Date(), input: 900_000, output: 12_345,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        try store.flush()

        try store.clearAll()

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertEqual(try reopened.sessions().count, 0, "the session row must be gone")
        XCTAssertEqual(
            try reopened.usage(for: sid), .notReported(reason: .awaitingFirstReport),
            "the usage records must be gone too, not just the row naming them"
        )
        XCTAssertEqual(try reopened.cost(for: sid), .noUsage)
        // The one thing `clearAll` deliberately keeps: prices the user typed are
        // configuration, and clearing samples does not un-type them.
        let sid2 = UUID()
        try reopened.recordSession(
            id: sid2, peerPID: 1, clientName: nil, clientVersion: nil, connectedAt: Date()
        )
        try reopened.recordUsage(TokenUsageRecord(
            sessionID: sid2, recordedAt: Date(), input: 1_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        XCTAssertEqual(
            try reopened.cost(for: sid2),
            .priced(usd: Decimal(string: "0.001")!, priceTableVersion: 1,
                    lines: [CostLine(modelID: "m", usd: Decimal(string: "0.001")!)])
        )
    }

    /// The basic sweep: a session that connected long ago and has said nothing since
    /// goes, with its records, while one inside the window stays.
    ///
    /// Both go together on purpose. Leaving the records behind would be an orphan no
    /// read can see and no later sweep can collect; leaving the row behind would be a
    /// session whose usage was deleted underneath it, which reads as "has not reported
    /// yet" — a lie about a session that did report.
    func testPruneDropsAStaleSessionThatHasNotReportedSinceTheCutoff() throws {
        let (store, url) = try makeStoreOnDisk()
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let stale = UUID(), recent = UUID()
        try store.recordSession(
            id: stale, peerPID: 1, clientName: "stale", clientVersion: nil,
            connectedAt: cutoff.addingTimeInterval(-60)
        )
        try store.recordSession(
            id: recent, peerPID: 1, clientName: "recent", clientVersion: nil,
            connectedAt: cutoff.addingTimeInterval(60)
        )
        // Both sessions' last report predates the cutoff, so age is decided by the
        // reports rather than by `connectedAt` alone.
        for id in [stale, recent] {
            try store.recordUsage(TokenUsageRecord(
                sessionID: id, recordedAt: cutoff.addingTimeInterval(-10), input: 500,
                output: 0, cacheRead: nil, reasoning: nil, modelID: "m",
                provenance: .selfReported
            ))
        }
        try store.flush()

        store.prune(olderThan: cutoff, keepingSessionIDs: [])

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertEqual(try reopened.sessions().map(\.id), [recent])
        XCTAssertEqual(
            try reopened.usage(for: stale), .notReported(reason: .awaitingFirstReport),
            "a pruned session's records must go with it, not survive as orphans"
        )
        guard case .reported(let segments) = try reopened.usage(for: recent),
              let input = segments.first?.input else {
            return XCTFail("the recent session must keep its usage")
        }
        XCTAssertEqual(input, 500)
    }

    /// The defect this round exists to fix: a session the host is still serving must
    /// survive a sweep, so the next report is not an orphan.
    ///
    /// The sequence is the reviewer's, in order — connect long ago, prune, report, prune
    /// again — because the second prune is what exposes the bug: it cannot collect
    /// anything, the parent row having been deleted by the first one while the
    /// connection carried on writing. `sessions()` returning empty at the end, with a
    /// usage record still in the file, is exactly the orphan state.
    func testPruneKeepsAStillConnectedSessionSoALaterReportIsNotAnOrphan() throws {
        let (store, url) = try makeStoreOnDisk()
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let live = UUID()
        try store.recordSession(
            id: live, peerPID: 4242, clientName: "long-lived", clientVersion: nil,
            connectedAt: cutoff.addingTimeInterval(-3_600)
        )
        try store.flush()

        // Stale by an hour, but the host says it is still serving this connection.
        store.prune(olderThan: cutoff, keepingSessionIDs: [live])

        try store.recordUsage(TokenUsageRecord(
            sessionID: live, recordedAt: cutoff.addingTimeInterval(60), input: 900,
            output: 0, cacheRead: nil, reasoning: nil, modelID: "m",
            provenance: .selfReported
        ))
        try store.flush()
        // And again, after the report: the newest sweep must not collect the row now
        // that it carries a record.
        store.prune(olderThan: cutoff, keepingSessionIDs: [live])

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertEqual(
            try reopened.sessions().map(\.id), [live],
            "a connection that is still serving keeps its session row through every sweep"
        )
        XCTAssertEqual(
            try reopened.usage(for: live),
            .reported(input: 900, output: 0, modelID: "m", provenance: .selfReported),
            "and the report it made after the sweep is readable, not an orphan"
        )
    }

    /// A still-connected session that has not reported recently keeps its **old** record
    /// too.
    ///
    /// Deleting it would leave the row present and empty, which this store reads as
    /// `awaitingFirstReport` — "a source exists and is readable, but has not reported
    /// yet". That is false: it did report, and Portmaster deleted the figure. The
    /// connection is what bounds this growth, and until it closes, its history is the
    /// user's.
    func testPruneKeepsAnOldRecordForAStillConnectedSession() throws {
        let (store, url) = try makeStoreOnDisk()
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let live = UUID()
        try store.recordSession(
            id: live, peerPID: 1, clientName: "quiet", clientVersion: nil,
            connectedAt: cutoff.addingTimeInterval(-3_600)
        )
        try store.recordUsage(TokenUsageRecord(
            sessionID: live, recordedAt: cutoff.addingTimeInterval(-600), input: 42,
            output: 0, cacheRead: nil, reasoning: nil, modelID: "m",
            provenance: .selfReported
        ))
        try store.flush()

        store.prune(olderThan: cutoff, keepingSessionIDs: [live])

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertEqual(
            try reopened.usage(for: live),
            .reported(input: 42, output: 0, modelID: "m", provenance: .selfReported),
            "deleting this record would make the session read as one that never reported"
        )
    }

    /// A stale session that is still reporting is kept, and its older records are
    /// trimmed — which changes nothing this store reports, because aggregation reads
    /// only the latest record per segment.
    ///
    /// The trimming is what keeps a chatty session from growing without bound, and the
    /// figure being identical before and after is what makes it safe: a sum would
    /// change here, a latest-record read cannot.
    func testPruneTrimsOldRecordsOfAStaleSessionThatIsStillReporting() throws {
        let (store, url) = try makeStoreOnDisk()
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let active = UUID()
        try store.recordSession(
            id: active, peerPID: 1, clientName: "chatty", clientVersion: nil,
            connectedAt: cutoff.addingTimeInterval(-3_600)
        )
        try store.recordUsage(TokenUsageRecord(
            sessionID: active, recordedAt: cutoff.addingTimeInterval(-600), input: 100,
            output: 0, cacheRead: nil, reasoning: nil, modelID: "m",
            provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: active, recordedAt: cutoff.addingTimeInterval(60), input: 900,
            output: 0, cacheRead: nil, reasoning: nil, modelID: "m",
            provenance: .selfReported
        ))
        try store.flush()
        let before = try store.usage(for: active)

        store.prune(olderThan: cutoff, keepingSessionIDs: [])

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertEqual(try reopened.sessions().map(\.id), [active])
        XCTAssertEqual(
            try reopened.usage(for: active), before,
            "trimming records older than the cutoff cannot move a latest-record figure"
        )
        guard case .reported(let segments) = try reopened.usage(for: active),
              let input = segments.first?.input else {
            return XCTFail("an actively reporting session must keep reporting")
        }
        XCTAssertEqual(input, 900)
    }

    /// The inverse of the test this replaces, and the property `prune` owes.
    ///
    /// The deleted `testPruneTrimmingCanResolveATwoProvenanceConflictIntoAPrice` pinned
    /// a sweep turning a stated disagreement into a confident figure for whichever model
    /// survived. Segments retired that particular shape — two models in two sources are
    /// two segments and both are priced — but the hazard did not go with it: the trim
    /// still deleted by session and timestamp, so it could remove the *only* record of
    /// one provenance and leave a different, still-priced figure behind, with nothing in
    /// the output saying retention had chosen it.
    ///
    /// The figures are the design's, so the assertion is not a matter of judgement:
    /// `0.0001 + 0.0018` = `0.0019` before the sweep, `0.0019` after it.
    ///
    /// **Written while red, on purpose.** A record may only go once a newer one exists
    /// for its own `(provenance, model)` pair, and until that rule landed the sole
    /// self-report below was exactly the record the trim took. This test alone cannot
    /// tell a trim that keeps every record from one that keeps the right ones, which is
    /// what the next test is for.
    func testPruneDoesNotChangeAFigureForATwoSourceSession() throws {
        let (store, url) = try makeStoreOnDisk()
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let session = UUID()
        try store.recordSession(
            id: session, peerPID: 1, clientName: "two-sources", clientVersion: nil,
            connectedAt: cutoff.addingTimeInterval(-3_600)
        )
        // The only self-reported record, and it is the old one. The parse is newer, so
        // this session is "still reporting" and lands in the trim group.
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: cutoff.addingTimeInterval(-600), input: 100,
            output: 0, cacheRead: nil, reasoning: nil, modelID: "model-a",
            provenance: .selfReported
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: cutoff.addingTimeInterval(60), input: 900,
            output: 0, cacheRead: nil, reasoning: nil, modelID: "model-b",
            provenance: .parsedFromLog
        ))
        // Both priced, so nothing after the sweep can be missing for want of a price and
        // the sweep is the only thing that could have changed the figure.
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-a")
        try store.setPrice(Decimal(string: "0.000002")!, modelID: "model-b")
        try store.flush()

        // 0.0001 + 0.0018. Two models in two sources is two segments, and both are
        // priced, so there is no disagreement for a sweep to resolve.
        guard case .priced(let usdBefore, _, let linesBefore) = try store.cost(for: session) else {
            return XCTFail("two priced segments are not a conflict: \(try store.cost(for: session))")
        }
        XCTAssertEqual(usdBefore, Decimal(string: "0.0019")!)
        XCTAssertEqual(linesBefore.map(\.modelID), ["model-a", "model-b"])
        let usageBefore = try store.usage(for: session)

        store.prune(olderThan: cutoff, keepingSessionIDs: [])

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertEqual(
            try reopened.usage(for: session), usageBefore,
            "a sweep changed the usage: the sole self-report is not a superseded record"
        )
        XCTAssertEqual(
            try reopened.cost(for: session).usd, Decimal(string: "0.0019")!,
            "0.0001 + 0.0018 before the sweep, and the same after it"
        )
    }

    /// The superseded case, which *should* still be deleted: a newer record for the
    /// same (provenance, model) means this one is unread, so removing it is inert.
    ///
    /// The other half of the fix. Keeping a segment's latest reading is only safe while
    /// the rest still goes — otherwise the trim trades a moved figure for a table that
    /// grows forever, and the sweep stops being a bound on anything.
    func testPruneStillDropsASupersededRecord() throws {
        let (store, url) = try makeStoreOnDisk()
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let session = UUID()
        try store.recordSession(
            id: session, peerPID: 1, clientName: "superseded", clientVersion: nil,
            connectedAt: cutoff.addingTimeInterval(-3_600)
        )
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: cutoff.addingTimeInterval(-600), input: 10,
            output: 0, cacheRead: nil, reasoning: nil, modelID: "m",
            provenance: .parsedFromLog
        ))
        try store.recordUsage(TokenUsageRecord(
            sessionID: session, recordedAt: cutoff.addingTimeInterval(60), input: 99,
            output: 0, cacheRead: nil, reasoning: nil, modelID: "m",
            provenance: .parsedFromLog
        ))
        try store.flush()

        store.prune(olderThan: cutoff, keepingSessionIDs: [])

        let reopened = try AgentSessionStore(storeURL: url)
        guard case .reported(let segments) = try reopened.usage(for: session) else {
            return XCTFail("expected usage to survive")
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].input, 99, "the newer reading is the one that survives")
    }

    // MARK: - Price text is parsed strictly

    /// Text that is not a number must be *absent*, not *nearly* a number.
    ///
    /// `Decimal(string:)` is lenient: it returns 1 for `"1,5"` and 1.5 for `"1.5abc"`,
    /// quietly rounding off or ignoring the rest. A missing price shows as missing, but
    /// a mis-parsed one is a wrong figure that looks computed and cannot reconcile with
    /// an invoice — the worse of the two failures, and the one this test pins.
    func testATextThatIsNotADecimalNumberIsNoPriceRatherThanAWrongOne() {
        for garbage in ["1,5", "1.5abc", "1 000", "", ".", "1.2.3", "0x10", "1e5", " 1"] {
            let entry = ModelPriceEntry(key: "m#input", pricePerToken: Decimal(0), tableVersion: 1)
            // Written directly, because the public path only ever writes canonical text.
            entry.pricePerTokenText = garbage
            XCTAssertNil(
                entry.pricePerToken,
                "\"\(garbage)\" is not a price, so it must not price anything"
            )
        }
        for canonical in ["0.0000015", "1", "0", "1234567.89", ".5"] {
            let entry = ModelPriceEntry(key: "m#input", pricePerToken: Decimal(0), tableVersion: 1)
            entry.pricePerTokenText = canonical
            XCTAssertNotNil(entry.pricePerToken, "\"\(canonical)\" is a price")
        }
    }
}

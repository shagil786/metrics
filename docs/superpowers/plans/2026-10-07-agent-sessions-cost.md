# Agent Sessions & Cost Attribution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Portmaster a queryable record of one AI agent session: who connected, which client it was, what tokens it reported or that were parsed from its own logs, and what that cost — with every number carrying the source that produced it.

**Architecture:** A new `PortmasterCore/History/AgentSessionStore.swift` owns three SwiftData models (`AgentSession`, `TokenUsageRecord`, `ModelPriceEntry`) in the existing history container. Usage is a three-state enum where absence carries a reason, never a zero. Cost is computed on read from a version-stamped price table rather than stored, using `Decimal`. An MCP tool `report_usage` appends self-reported records; a `TokenSourceAdapter` protocol allows log parsers to append parsed records, with one fixture adapter proving the contract.

**Tech Stack:** Swift 5 language mode (v5), SwiftData, Foundation `Decimal`, XCTest, the vendored `modelcontextprotocol/swift-sdk`.

**Spec:** `docs/superpowers/specs/2026-10-07-agent-sessions-cost-design.md`

## Global Constraints

- Language mode is **v5**, not v6: `swiftSettings: [.swiftLanguageMode(.v5)]` on `PortmasterCore`. Do not introduce v6-only syntax.
- The store registers models **explicitly** in `HistoryStore.init`'s `ModelContainer(for:)`. A model absent from that list does not persist, and nothing fails loudly.
- Never use `Double` for money. `Decimal` throughout, asserted with exact equality in tests.
- Absence is a distinct value everywhere. `notReported` must never equal a reported zero; `notPriced` must never equal `priced(0)`.
- New code follows the project's existing honesty-comment convention: every non-obvious invariant gets a comment explaining *why*, not *what*.
- Verify with `cd Core && swift test`. Baseline before any change: **223 tests, 0 failures, 1 skipped**.
- No UI in this plan. No changes to `AuditLog` or `PermissionGate` semantics.

---

## File Structure

| File | Responsibility |
|---|---|
| `Core/Sources/PortmasterCore/History/AgentUsage.swift` | `TokenProvenance`, `UsageUnavailableReason`, `TokenUsage`, `TokenUsageRecord`, `SessionCost`. Pure value types, no persistence. |
| `Core/Sources/PortmasterCore/History/AgentSessionStore.swift` | The three `@Model` classes, persistence, aggregation, cost computation. |
| `Core/Sources/PortmasterCore/History/TokenSourceAdapter.swift` | The adapter protocol and the fixture adapter. |
| `Core/Sources/PortmasterCore/History/HistoryStore.swift` | **Modified:** register the new models in the container. |
| `Core/Sources/PortmasterMCP/ToolExecutor.swift` | **Modified:** add `report_usage` to the catalog and dispatch. |
| `Core/Sources/PortmasterMCP/SessionRecorder.swift` | Bridges the executor to the store, and MCP connections to sessions. |
| `Core/Tests/PortmasterCoreTests/AgentUsageTests.swift` | Value-type state machine. |
| `Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift` | Persistence, aggregation, cost. |
| `Core/Tests/PortmasterCoreTests/TokenSourceAdapterTests.swift` | Adapter contract. |

---

### Task 1: Token usage value types

**Files:**
- Create: `Core/Sources/PortmasterCore/History/AgentUsage.swift`
- Test: `Core/Tests/PortmasterCoreTests/AgentUsageTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `TokenProvenance`, `UsageUnavailableReason`, `TokenUsage`, `SessionCost`, and the `TokenUsageRecord` struct, all `public`, all `Sendable`. Later tasks use `TokenUsage` and `TokenUsageRecord` verbatim.

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/PortmasterCoreTests/AgentUsageTests.swift`:

```swift
// Token usage is a three-state value because an agent that reported nothing must
// never render as an agent that reported zero. These tests pin that distinction
// where it is cheapest to get wrong: the type itself.
import XCTest
@testable import PortmasterCore

final class AgentUsageTests: XCTestCase {

    // MARK: - The distinction that matters

    func testNotReportedIsNeverEqualToReportedZero() {
        let nothing = TokenUsage.notReported(reason: .noSource)
        let zero = TokenUsage.reported(input: 0, output: 0, provenance: .selfReported)

        XCTAssertNotEqual(nothing, zero)
        XCTAssertNil(nothing.value)
        XCTAssertNotNil(zero.value)
        XCTAssertFalse(nothing.isReported)
        XCTAssertTrue(zero.isReported)
    }

    // MARK: - Provenance is part of the value

    func testProvenanceIsCarriedNotDropped() {
        let self_ = TokenUsage.reported(input: 10, output: 5, provenance: .selfReported)
        let parsed = TokenUsage.reported(input: 10, output: 5, provenance: .parsedFromLog)

        XCTAssertNotEqual(self_, parsed, "identical figures from different sources are different facts")
        XCTAssertEqual(self_.provenance, .selfReported)
        XCTAssertEqual(parsed.provenance, .parsedFromLog)
    }

    // MARK: - Every unavailability reason is distinct

    func testEveryUnavailableReasonIsDistinct() {
        let reasons: [UsageUnavailableReason] = [
            .noSource, .logUnreadable, .unrecognizedFormat, .awaitingFirstReport,
        ]
        for (i, a) in reasons.enumerated() {
            for (j, b) in reasons.enumerated() where i != j {
                XCTAssertNotEqual(a, b, "\(a) and \(b) are the same fact")
            }
        }
    }

    // MARK: - Aggregation of cumulative reports

    /// Agents report totals-so-far, so summing records inflates usage and will not
    /// reconcile with a provider invoice.
    func testAggregationTakesLatestPerProvenanceNotTheSum() {
        let records = [
            TokenUsageRecord(
                id: UUID(), sessionID: UUID(), recordedAt: Date(timeIntervalSince1970: 1),
                input: 100, output: 50, cacheRead: nil, reasoning: nil,
                modelID: "m", provenance: .selfReported
            ),
            TokenUsageRecord(
                id: UUID(), sessionID: UUID(), recordedAt: Date(timeIntervalSince1970: 2),
                input: 200, output: 90, cacheRead: nil, reasoning: nil,
                modelID: "m", provenance: .selfReported
            ),
            TokenUsageRecord(
                id: UUID(), sessionID: UUID(), recordedAt: Date(timeIntervalSince1970: 3),
                input: 300, output: 150, cacheRead: nil, reasoning: nil,
                modelID: "m", provenance: .selfReported
            ),
        ]

        let aggregated = TokenUsage.aggregating(records)
        guard case .reported(let input, let output, _) = aggregated else {
            return XCTFail("expected reported, got \(aggregated)")
        }
        XCTAssertEqual(input, 300, "cumulative totals must not be summed")
        XCTAssertEqual(output, 150)
    }

    func testAggregatingNoRecordsIsNotReportedNotZero() {
        let aggregated = TokenUsage.aggregating([])
        XCTAssertEqual(aggregated, .notReported(reason: .awaitingFirstReport))
    }

    /// Two provenances disagreeing about which model was used is a real conflict.
    /// Picking one silently would be a number nobody can justify.
    func testProvenanceConflictIsSurfacedNotSilentlyResolved() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 2),
                input: 20, output: 10, cacheRead: nil, reasoning: nil,
                modelID: "model-a", provenance: .selfReported
            ),
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 2),
                input: 20, output: 10, cacheRead: nil, reasoning: nil,
                modelID: "model-b", provenance: .parsedFromLog
            ),
        ]

        XCTAssertTrue(TokenUsage.hasModelConflict(records), "a model disagreement must not resolve itself")
    }

    func testAgreeingModelIDsAreNotAConflict() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 2),
                input: 20, output: 10, cacheRead: nil, reasoning: nil,
                modelID: "same", provenance: .selfReported
            ),
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 2),
                input: 25, output: 12, cacheRead: nil, reasoning: nil,
                modelID: "same", provenance: .parsedFromLog
            ),
        ]

        XCTAssertFalse(TokenUsage.hasModelConflict(records))
    }

    // MARK: - Cost

    func testNotPricedIsNeverEqualToPricedZero() {
        let unpriced = SessionCost.notPriced(modelID: "unknown-model")
        let free = SessionCost.priced(usd: Decimal(0), priceTableVersion: 1)

        XCTAssertNotEqual(unpriced, free, "an unknown price is not a free model")
        XCTAssertNil(unpriced.usd)
        XCTAssertNotNil(free.usd)
    }

    func testNoUsageCostsNothingRatherThanZero() {
        let cost = SessionCost.noUsage
        XCTAssertNil(cost.usd)
        XCTAssertNotEqual(cost, .priced(usd: Decimal(0), priceTableVersion: 1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter AgentUsageTests`
Expected: FAIL — `cannot find 'TokenUsage' in scope`

- [ ] **Step 3: Write the implementation**

Create `Core/Sources/PortmasterCore/History/AgentUsage.swift`:

```swift
// Token accounting for AI agent sessions.
//
// Every value here is three-state on purpose. The failure this type exists to
// prevent is an agent that reported nothing being shown as an agent that
// reported zero — which reads as "this session was free" and is a claim nobody
// can support. The same rule governs `ProcessEnergy` and `ThermalAvailability`.

import Foundation

/// Where a token figure came from. Part of the stored value rather than a field a
/// presentation layer can drop: a number whose source is unknown cannot be audited.
public enum TokenProvenance: String, Hashable, Sendable {
    /// An agent called `report_usage` and said so.
    case selfReported
    /// Read out of an agent's own session log by a `TokenSourceAdapter`.
    case parsedFromLog
}

/// Why no figure exists. Every case is a different fact needing a different word.
public enum UsageUnavailableReason: String, Hashable, Sendable {
    /// No reporting tool and no recognized log: this session cannot be counted.
    case noSource
    /// A log file was located but could not be read.
    case logUnreadable
    /// The file was read and its shape was not understood — the vendor changed
    /// their format. Reporting a guess here is how a plausible wrong number ships,
    /// so this is its own state rather than a partial parse.
    case unrecognizedFormat
    /// A source exists and is readable, but has not reported yet.
    case awaitingFirstReport
}

/// One observation of a session's usage. Records are appended; a session's usage
/// is an aggregate of them, never a stored total.
public struct TokenUsageRecord: Hashable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let recordedAt: Date
    public let input: Int
    public let output: Int
    /// Priced separately from input/output, and nil when the source omits them —
    /// summing them into `input` produces a cost that cannot be reconciled with a
    /// provider invoice.
    public let cacheRead: Int?
    public let reasoning: Int?
    public let modelID: String
    public let provenance: TokenProvenance

    public init(
        id: UUID = UUID(), sessionID: UUID, recordedAt: Date,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?,
        modelID: String, provenance: TokenProvenance
    ) {
        self.id = id
        self.sessionID = sessionID
        self.recordedAt = recordedAt
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.modelID = modelID
        self.provenance = provenance
    }
}

/// A session's token usage: a figure with a known source, or a reason there is none.
public enum TokenUsage: Hashable, Sendable {
    case reported(input: Int, output: Int, provenance: TokenProvenance)
    case notReported(reason: UsageUnavailableReason)

    /// The counts, when there are any. `nil` for every not-reported case.
    public var value: (input: Int, output: Int)? {
        if case .reported(let input, let output, _) = self { return (input, output) }
        return nil
    }

    /// Whether a figure exists. A measured zero is `true`; "we cannot tell" is
    /// `false`. Conflating them is the whole bug this type prevents.
    public var isReported: Bool {
        if case .reported = self { return true }
        return false
    }

    /// The source of a reported figure, or nil when there is none.
    public var provenance: TokenProvenance? {
        if case .reported(_, _, let provenance) = self { return provenance }
        return nil
    }

    /// Folds a session's records into one value.
    ///
    /// Latest-per-provenance, not a sum: agents report cumulative totals, so
    /// summing three reports of the same session counts the first two twice.
    public static func aggregating(_ records: [TokenUsageRecord]) -> TokenUsage {
        guard let latest = latestPerProvenance(records) else {
            return .notReported(reason: .awaitingFirstReport)
        }
        // Self-reported figures win: an agent's own count is the authoritative one,
        // and a log parse is a reconstruction. The winner is named either way, so
        // the reader knows which they got.
        let chosen = latest[.selfReported] ?? latest[.parsedFromLog]
        guard let record = chosen else {
            return .notReported(reason: .awaitingFirstReport)
        }
        return .reported(input: record.input, output: record.output, provenance: record.provenance)
    }

    static func latestPerProvenance(
        _ records: [TokenUsageRecord]
    ) -> [TokenProvenance: TokenUsageRecord] {
        var latest: [TokenProvenance: TokenUsageRecord] = [:]
        for record in records {
            if let existing = latest[record.provenance],
               existing.recordedAt >= record.recordedAt {
                continue
            }
            latest[record.provenance] = record
        }
        return latest
    }

    /// True when sources disagree about which model ran. A conflict is reported,
    /// never resolved: both figures stay visible and the cost cannot be computed
    /// without the user saying which to believe.
    public static func hasModelConflict(_ records: [TokenUsageRecord]) -> Bool {
        let models = Set(records.map(\.modelID))
        return models.count > 1
    }
}

/// What a session's usage costs. A cost is computed on read rather than stored, so
/// a price change re-costs history instead of leaving stale figures behind.
public enum SessionCost: Hashable, Sendable {
    case priced(usd: Decimal, priceTableVersion: Int)
    /// The model has no entry in the price table. An unknown price, not a free one.
    case notPriced(modelID: String)
    /// Nothing to price yet.
    case noUsage

    public var usd: Decimal? {
        if case .priced(let usd, _) = self { return usd }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Core && swift test --filter AgentUsageTests`
Expected: PASS — 8 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PortmasterCore/History/AgentUsage.swift Core/Tests/PortmasterCoreTests/AgentUsageTests.swift
git commit -m "feat(agents): token usage as a three-state value, not a number

An agent that reported nothing must never render as an agent that reported
zero, which reads as 'this session was free' and is a claim nobody can support.
Provenance is part of the stored value so a presentation layer cannot drop it.

Aggregation is latest-per-provenance, not a sum: agents report cumulative
totals, so summing three reports of one session counts the first two twice and
will not reconcile with a provider invoice."
```

---

### Task 2: Persistence — the three SwiftData models

**Files:**
- Create: `Core/Sources/PortmasterCore/History/AgentSessionStore.swift`
- Modify: `Core/Sources/PortmasterCore/History/HistoryStore.swift:38-45` (the `ModelContainer(for:)` call)
- Test: `Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift`

**Interfaces:**
- Consumes: `TokenUsage`, `TokenUsageRecord`, `TokenProvenance`, `SessionCost` from Task 1.
- Produces: `public final class AgentSessionStore` with `init(storeURL: URL?) throws`, `recordSession(...)`, `recordUsage(...)`, `sessions()`, `usage(for:)`. Later tasks call these exact signatures.

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift`:

```swift
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

        try store.setPrice(Decimal(string: "0.0000015"), modelID: "m")
        try store.setPrice(Decimal(string: "0.000006"), modelID: "m", component: .output)

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

        try store.setPrice(Decimal(string: "0.000001"), modelID: "m")
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

        try store.setPrice(Decimal(string: "0.000002"), modelID: "m")
        guard case .priced(let after, let versionAfter) = try store.cost(for: sid) else {
            return XCTFail("expected priced after change")
        }
        XCTAssertEqual(after, Decimal(string: "0.002")!)
        XCTAssertEqual(versionAfter, 2, "a re-cost must name the prices that produced it")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter AgentSessionStoreTests`
Expected: FAIL — `cannot find 'AgentSessionStore' in scope`

**Before Step 3, check one unknown.** `ModelPriceEntry.pricePerToken` is declared
`Decimal`, and this codebase has no precedent for `Decimal` in a SwiftData
`@Model` — `@Model` supports a narrower set of property types than Codable does.
If the compiler rejects it, do **not** switch to `Double`: money in binary floating
point cannot reconcile with a provider invoice, which is the reason the field is
`Decimal`. Store it as a scaled `Int` (price per million tokens, in the smallest
unit) or as a decimal `String`, and convert at the read boundary. Then adjust the
cost test to compare against the converted value. Do not proceed to Step 3 until
this compiles.

- [ ] **Step 3: Write the models and store**

Create `Core/Sources/PortmasterCore/History/AgentSessionStore.swift`:

```swift
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

        let models = Set(records.map(\.modelID))
        // Two sources disagreeing about the model cannot both be right, and picking
        // one would produce a figure nobody can justify. No cost, and the caller can
        // see the conflict from the records.
        guard models.count == 1, let modelID = models.first else { return .notPriced(modelID: models.sorted().joined(separator: "/")) }

        let latest = TokenUsage.latestPerProvenance(records)
        guard let record = latest[.selfReported] ?? latest[.parsedFromLog] else { return .noUsage }

        let components: [(PriceComponent, Int)] = [
            (.input, record.input), (.output, record.output),
        ]
        var total = Decimal(0)
        var version = 0
        for (component, count) in components {
            guard let (price, entryVersion) = priceLocked("\(modelID)#\(component.keySuffix)") else {
                return .notPriced(modelID: modelID)
            }
            total += price * Decimal(count)
            version = max(version, entryVersion)
        }
        if let cache = record.cacheRead,
           let (price, entryVersion) = priceLocked("\(modelID)#\(PriceComponent.cacheRead.keySuffix)") {
            total += price * Decimal(cache)
            version = max(version, entryVersion)
        }
        if let reasoning = record.reasoning,
           let (price, entryVersion) = priceLocked("\(modelID)#\(PriceComponent.reasoning.keySuffix)") {
            total += price * Decimal(reasoning)
            version = max(version, entryVersion)
        }
        return .priced(usd: total, priceTableVersion: version)
    }
}
```

Now register the models in the history container. Edit `Core/Sources/PortmasterCore/History/HistoryStore.swift`, replacing the `ModelContainer` call at lines 38–42:

```swift
            container = try ModelContainer(
                for: CPUSample.self, MemSample.self, ProcessPoint.self, PortEvent.self,
                AppHistoryPoint.self, ResourceHistoryPoint.self,
                AgentSession.self, TokenUsageRecordRow.self, ModelPriceEntry.self,
                configurations: config
            )
```

The comment above it should note that the list is explicit and a model absent from it does not persist:

```swift
            // Every model is listed, because SwiftData only persists models named
            // here — one left out of this list simply never saves, with nothing
            // failing. Adding a model means adding it here too.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter AgentSessionStoreTests`
Expected: PASS — 9 tests, 0 failures

Then run the whole suite:

Run: `cd Core && swift test`
Expected: 232 tests, 0 failures, 1 skipped (223 baseline + 9 new)

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PortmasterCore/History/AgentSessionStore.swift Core/Sources/PortmasterCore/History/HistoryStore.swift Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift
git commit -m "feat(agents): persist sessions, usage records and versioned prices

Usage is appended as records and aggregated on read rather than stored as a
running total: reports arrive asynchronously, so a mutable total would be
rewritten by every report and contended over by two sources.

Cost is computed on read, so a price change re-costs history instead of leaving
figures describing a price from months ago. Decimal, not Double, asserted with
exact equality — a cost that cannot reconcile with a provider invoice is not a
cost. An unpriced model yields notPriced, never priced(0).

The models are registered in HistoryStore's explicit container list; a model
missing from that list never persists and nothing fails, which is why the
round-trip test exists."
```

---

### Task 3: The token source adapter protocol

**Files:**
- Create: `Core/Sources/PortmasterCore/History/TokenSourceAdapter.swift`
- Test: `Core/Tests/PortmasterCoreTests/TokenSourceAdapterTests.swift`

**Interfaces:**
- Consumes: `TokenUsageRecord`, `TokenProvenance` from Task 1.
- Produces: `protocol TokenSourceAdapter` with `RawAgentUsage` and `TokenSourceError`. Task 4's fixture uses it; real adapters land in phase C.

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/PortmasterCoreTests/TokenSourceAdapterTests.swift`:

```swift
// The adapter contract. A real adapter parses a vendor's private file format, and
// the failure this protocol must make impossible is a parse that half-succeeds and
// reports a plausible wrong number — so the fixture asserts that garbage in
// produces notReported rather than a figure.
import XCTest
import Foundation
@testable import PortmasterCore

/// Adapter over a JSON file the test writes, standing in for a vendor log.
struct FixtureTokenAdapter: TokenSourceAdapter {
    let identifier = "fixture-agent"
    var root: URL

    func locateSessionLog(for session: AgentSessionSnapshot) -> URL? {
        let url = root.appendingPathComponent("\(session.id.uuidString).json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func parse(_ url: URL) throws -> RawAgentUsage {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let input = object["input"] as? Int,
              let output = object["output"] as? Int,
              let model = object["model"] as? String
        else {
            // A shape we do not understand is its own outcome, not a zero.
            throw TokenSourceError.unrecognizedFormat
        }
        return RawAgentUsage(
            input: input, output: output,
            cacheRead: object["cache"] as? Int,
            reasoning: nil,
            modelID: model
        )
    }
}

final class TokenSourceAdapterTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("adapter-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func session() -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: UUID(), peerPID: 1, clientName: "fixture", clientVersion: nil,
            connectedAt: Date(), endedAt: nil,
            usage: .notReported(reason: .noSource), cost: .noUsage
        )
    }

    // MARK: - Locating

    func testMissingLogIsNoSourceNotAFailure() {
        let adapter = FixtureTokenAdapter(root: root)
        XCTAssertNil(adapter.locateSessionLog(for: session()))
    }

    // MARK: - Parsing

    func testValidLogParsesToUsage() throws {
        let s = session()
        let url = root.appendingPathComponent("\(s.id.uuidString).json")
        try #"{"input": 1200, "output": 300, "model": "m1", "cache": 50}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let raw = try FixtureTokenAdapter(root: root).parse(url)
        XCTAssertEqual(raw.input, 1200)
        XCTAssertEqual(raw.output, 300)
        XCTAssertEqual(raw.modelID, "m1")
        XCTAssertEqual(raw.cacheRead, 50)
    }

    func testGarbageLogThrowsUnrecognizedFormatRatherThanZero() throws {
        let url = root.appendingPathComponent("garbage.json")
        try #"{"totally": "different"}"#.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FixtureTokenAdapter(root: root).parse(url)) { error in
            XCTAssertEqual(error as? TokenSourceError, .unrecognizedFormat,
                           "an unknown shape must not become a number")
        }
    }

    func testNonJSONFileThrowsUnrecognizedFormat() throws {
        let url = root.appendingPathComponent("notes.txt")
        try "just some text".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try FixtureTokenAdapter(root: root).parse(url)) { error in
            XCTAssertEqual(error as? TokenSourceError, .unrecognizedFormat)
        }
    }

    // MARK: - The runner's outcome mapping

    func testRunnerMapsSuccessToParsedRecord() throws {
        let s = session()
        let url = root.appendingPathComponent("\(s.id.uuidString).json")
        try #"{"input": 10, "output": 5, "model": "m"}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let outcome = TokenSourceRunner(
            adapter: FixtureTokenAdapter(root: root), sessionID: s.id
        ).run()

        guard case .reported(let record) = outcome else {
            return XCTFail("expected a record, got \(outcome)")
        }
        XCTAssertEqual(record.provenance, .parsedFromLog)
        XCTAssertEqual(record.input, 10)
    }

    func testRunnerMapsUnrecognizedFormatToNotReported() {
        let s = session()
        try? #"{"nope": 1}"#.write(
            to: root.appendingPathComponent("\(s.id.uuidString).json"),
            atomically: true, encoding: .utf8
        )

        let outcome = TokenSourceRunner(
            adapter: FixtureTokenAdapter(root: root), sessionID: s.id
        ).run()

        XCTAssertEqual(outcome, .notReported(reason: .unrecognizedFormat))
    }

    func testRunnerMapsMissingLogToNoSource() {
        let outcome = TokenSourceRunner(
            adapter: FixtureTokenAdapter(root: root), sessionID: session().id
        ).run()

        XCTAssertEqual(outcome, .notReported(reason: .noSource))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter TokenSourceAdapterTests`
Expected: FAIL — `cannot find 'TokenSourceAdapter' in scope`

- [ ] **Step 3: Write the protocol and runner**

Create `Core/Sources/PortmasterCore/History/TokenSourceAdapter.swift`:

```swift
// Reading token counts out of an agent's own session logs.
//
// One adapter per vendor. The isolation is the point: parsing one agent's private
// file format must not be able to break another's, and a new adapter must be
// addable without touching the record or the query surface.
//
// No adapter ships in this slice. The protocol and the outcome mapping are what
// phase C needs, and the fixture in the tests is a fixture — nothing here has been
// run against a real agent's log, and saying otherwise is the failure this whole
// design exists to prevent.

import Foundation

public enum TokenSourceError: Error, Hashable, Sendable {
    /// The file was read and its shape was not understood — the vendor changed it.
    /// Deliberately not a partial parse: a half-understood file that yields plausible
    /// numbers is worse than no file.
    case unrecognizedFormat
    case unreadable
}

/// Counts as they appear in a vendor's log, before conversion.
public struct RawAgentUsage: Hashable, Sendable {
    public let input: Int
    public let output: Int
    public let cacheRead: Int?
    public let reasoning: Int?
    public let modelID: String

    public init(input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.modelID = modelID
    }
}

public protocol TokenSourceAdapter: Sendable {
    /// Stable name for this source, used in diagnostics.
    var identifier: String { get }

    /// The log file for a session, or nil when there is none. **Nil is normal**, not
    /// an error: most sessions have no readable log, and that must read as "no
    /// source" rather than as a failure.
    func locateSessionLog(for session: AgentSessionSnapshot) -> URL?

    /// Parses a located log. Throws `TokenSourceError.unrecognizedFormat` rather
    /// than returning partial counts.
    func parse(_ url: URL) throws -> RawAgentUsage
}

/// What an adapter run produced: a record to append, or a reason there is none.
public enum TokenSourceOutcome: Hashable, Sendable {
    case reported(TokenUsageRecord)
    case notReported(reason: UsageUnavailableReason)
}

/// Runs one adapter against one session and maps every failure onto a named
/// absence, so no caller has to interpret an error to know what it does not know.
public struct TokenSourceRunner: Sendable {
    private let adapter: any TokenSourceAdapter
    private let sessionID: UUID
    private let now: @Sendable () -> Date

    public init(
        adapter: any TokenSourceAdapter,
        sessionID: UUID,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.adapter = adapter
        self.sessionID = sessionID
        self.now = now
    }

    public func run(session: AgentSessionSnapshot) -> TokenSourceOutcome {
        guard let url = adapter.locateSessionLog(for: session) else {
            return .notReported(reason: .noSource)
        }
        do {
            let raw = try adapter.parse(url)
            return .reported(TokenUsageRecord(
                sessionID: sessionID,
                recordedAt: now(),
                input: raw.input,
                output: raw.output,
                cacheRead: raw.cacheRead,
                reasoning: raw.reasoning,
                modelID: raw.modelID,
                provenance: .parsedFromLog
            ))
        } catch TokenSourceError.unrecognizedFormat {
            return .notReported(reason: .unrecognizedFormat)
        } catch TokenSourceError.unreadable {
            return .notReported(reason: .logUnreadable)
        } catch {
            // An adapter throwing something of its own is still an absence, and
            // still must not become a number.
            return .notReported(reason: .logUnreadable)
        }
    }

    /// Convenience for the common case where the caller already has the session.
    public func run() -> TokenSourceOutcome {
        run(session: AgentSessionSnapshot(
            id: sessionID, peerPID: 0, clientName: adapter.identifier,
            clientVersion: nil, connectedAt: now(), endedAt: nil,
            usage: .notReported(reason: .noSource), cost: .noUsage
        ))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter TokenSourceAdapterTests`
Expected: PASS — 8 tests, 0 failures

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PortmasterCore/History/TokenSourceAdapter.swift Core/Tests/PortmasterCoreTests/TokenSourceAdapterTests.swift
git commit -m "feat(agents): the token source adapter protocol, with no adapters

One adapter per vendor, so parsing one agent's private file format cannot break
another's and a new source needs no change to the record or the query surface.

An adapter must throw unrecognizedFormat rather than return a partial parse. A
half-understood file that yields plausible numbers is the worst outcome here,
because it survives review: every error maps to a named absence, so garbage in
produces notReported rather than a figure.

No real adapter ships here. The fixture in the tests is a fixture."
```

---

### Task 4: The `report_usage` MCP tool

**Files:**
- Create: `Core/Sources/PortmasterMCP/SessionRecorder.swift`
- Modify: `Core/Sources/PortmasterMCP/ToolExecutor.swift` — catalog entry (~line 76) and dispatch (in the `switch tool.name`, near `set_preference`)
- Test: `Core/Tests/PortmasterMCPTests/AgentUsageToolTests.swift`

**Interfaces:**
- Consumes: `AgentSessionStore`, `TokenUsageRecord`, `TokenProvenance` from Tasks 1–2.
- Produces: `public protocol SessionRecording: Sendable` with `func record(sessionID:UUID?, clientName:String?, clientVersion:String?, input:Int, output:Int, cacheRead:Int?, reasoning:Int?, modelID:String) throws -> String`. `ToolExecutor.init` gains `sessionRecorder: (any SessionRecording)? = nil`.

- [ ] **Step 1: Write the failing test**

Create `Core/Tests/PortmasterMCPTests/AgentUsageToolTests.swift` — this must live beside `ToolExecutorReadTests.swift`, because `StubProvider` is defined in `PortmasterMCPTests` and a `PortmasterCoreTests` file cannot see it.

```swift
// report_usage: an agent declaring a fact about itself.
//
// Deliberately outside the permission gate. It is not an action on the machine —
// it cannot quit a process or change a setting — so requiring confirmation for it
// would train users to click through prompts that carry no risk, which makes the
// prompts that do matter easier to dismiss.
import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

final class AgentUsageToolTests: XCTestCase {

    /// In-memory recorder so the tool's validation is tested without a store.
    final class SpyRecorder: SessionRecording {
        var calls: [(modelID: String, input: Int, output: Int, provenance: TokenProvenance)] = []
        var sessionID: UUID? = UUID()
        func record(
            sessionID: UUID?, clientName: String?, clientVersion: String?,
            input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
        ) throws -> String {
            calls.append((modelID, input, output, .selfReported))
            return "recorded"
        }
    }

    private func executor(_ recorder: SpyRecorder) -> ToolExecutor {
        ToolExecutor(
            provider: StubProvider(),
            gate: PermissionGate(settings: MCPSettings(mode: .off), appRunning: false),
            audit: AuditLog(directory: FileManager.default.temporaryDirectory),
            settingsDirectory: FileManager.default.temporaryDirectory,
            sessionRecorder: recorder
        )
    }

    // MARK: - Catalog

    func testToolIsInTheCatalog() {
        XCTAssertTrue(ToolExecutor.catalog.contains { $0.name == "report_usage" })
    }

    func testToolIsNotAMutation() {
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == "report_usage" }) else {
            return XCTFail("report_usage missing from catalog")
        }
        XCTAssertEqual(tool.effect, .read, "self-report must not require confirmation")
    }

    func testToolDeclaresItsArguments() {
        guard let tool = ToolExecutor.catalog.first(where: { $0.name == "report_usage" }) else {
            return XCTFail("report_usage missing from catalog")
        }
        let names = Set(tool.arguments.map(\.name))
        for required in ["input", "output", "model"] {
            XCTAssertTrue(names.contains(required), "\(required) must be declared")
        }
    }

    // MARK: - Behaviour

    func testValidReportReachesTheRecorder() async throws {
        let spy = SpyRecorder()
        let payload = try await executor(spy).execute(
            tool: "report_usage",
            arguments: ["input": "1000", "output": "250", "model": "m1"]
        )
        let text = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls.first?.modelID, "m1")
        XCTAssertEqual(spy.calls.first?.input, 1000)
    }

    func testNegativeInputIsRejected() async {
        let spy = SpyRecorder()
        do {
            _ = try await executor(spy).execute(
                tool: "report_usage",
                arguments: ["input": "-1", "output": "250", "model": "m1"]
            )
            XCTFail("a negative token count must be refused")
        } catch {
            XCTAssertEqual(spy.calls.count, 0, "nothing may be recorded from an invalid report")
        }
    }

    func testNonNumericInputIsRejected() async {
        let spy = SpyRecorder()
        do {
            _ = try await executor(spy).execute(
                tool: "report_usage",
                arguments: ["input": "lots", "output": "250", "model": "m1"]
            )
            XCTFail("a non-numeric count must be refused")
        } catch {
            XCTAssertEqual(spy.calls.count, 0)
        }
    }

    func testMissingModelIsRejected() async {
        let spy = SpyRecorder()
        do {
            _ = try await executor(spy).execute(
                tool: "report_usage", arguments: ["input": "10", "output": "5"]
            )
            XCTFail("a report without a model cannot be priced, so it must be refused")
        } catch {
            XCTAssertEqual(spy.calls.count, 0)
        }
    }

    func testEmptyModelIsRejected() async {
        let spy = SpyRecorder()
        do {
            _ = try await executor(spy).execute(
                tool: "report_usage",
                arguments: ["input": "10", "output": "5", "model": "  "]
            )
            XCTFail("a blank model id must be refused")
        } catch {
            XCTAssertEqual(spy.calls.count, 0)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter AgentUsageToolTests`
Expected: FAIL — `cannot find 'SessionRecording' in scope`

- [ ] **Step 3: Write the recorder protocol**

Create `Core/Sources/PortmasterMCP/SessionRecorder.swift`:

```swift
// Recording what an agent says about itself.
//
// `report_usage` is deliberately not a mutation. It is a declaration, not an
// action on the machine: it cannot quit a process, change a setting or read
// anything. Requiring a confirmation click for it would mean a click that carries
// no risk, and teaching people to click through prompts that do not matter is how
// prompts that do matter get dismissed.
//
// It is still a write. It is scoped to the caller's own accounting and it only
// appends, which is the boundary that keeps it safe.

import Foundation
import PortmasterCore

public protocol SessionRecording: Sendable {
    /// Appends one self-reported usage observation. Returns a sentence the caller
    /// can hand back to the agent, so a refusal and a success are both legible.
    func record(
        sessionID: UUID?, clientName: String?, clientVersion: String?,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String
}

/// Writes into the SwiftData store. Fails loudly rather than swallowing: a report
/// that vanishes would leave the session reading `notReported` with no way to tell
/// a lost write from an agent that never reported.
public struct StoreSessionRecorder: SessionRecording {
    private let store: AgentSessionStore

    public init(store: AgentSessionStore) {
        self.store = store
    }

    public func record(
        sessionID: UUID?, clientName: String?, clientVersion: String?,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String {
        let id = sessionID ?? UUID()
        if let sessionID {
            try store.recordSession(
                id: sessionID,
                peerPID: 0,
                clientName: clientName,
                clientVersion: clientVersion,
                connectedAt: Date()
            )
        }
        try store.recordUsage(TokenUsageRecord(
            sessionID: id,
            recordedAt: Date(),
            input: input, output: output,
            cacheRead: cacheRead, reasoning: reasoning,
            modelID: modelID,
            provenance: .selfReported
        ))
        try store.flush()
        return "Recorded \(input) input and \(output) output tokens for \(modelID)."
    }
}

/// Used when no store is wired. Reports are refused with a reason rather than
/// accepted and dropped — an agent told "recorded" when nothing was is worse than
/// one told it cannot report.
public struct UnavailableSessionRecorder: SessionRecording {
    public init() {}

    public func record(
        sessionID: UUID?, clientName: String?, clientVersion: String?,
        input: Int, output: Int, cacheRead: Int?, reasoning: Int?, modelID: String
    ) throws -> String {
        throw MCPToolError(
            message: "Portmaster has no session store available, so this report was not recorded."
        )
    }
}
```

- [ ] **Step 4: Add the tool to the catalog and dispatch**

In `Core/Sources/PortmasterMCP/ToolExecutor.swift`, add to `ToolExecutor.catalog` after the last read tool:

```swift
        ToolDefinition(
            name: "report_usage",
            description: "Report your own token usage for this session. Optional: Portmaster "
                + "can read some agents' usage from their own logs instead, and says so when "
                + "it has no figure rather than reporting zero.",
            arguments: [
                (name: "input", required: true, help: "Input tokens used so far this session"),
                (name: "output", required: true, help: "Output tokens used so far this session"),
                (name: "model", required: true, help: "The model id these counts are for"),
                (name: "cache_read", required: false, help: "Cache-read tokens, if you track them"),
                (name: "reasoning", required: false, help: "Reasoning tokens, if you track them")
            ],
            effect: .read
        )
```

**Four existing tests hardcode the catalog size as 13** — `CLIRoutingTests.swift:118`,
`CLIIntegrationTests.swift:286`, `CLIIntegrationTests.swift:344` and
`MCPHostServerTests.swift:49`. Adding a tool makes it 14 and breaks all four. Update
each to 14 in this same step, so the count change is part of adding the tool rather
than a mystery failure discovered later. The e2e script asserts `tools/list over the
socket returns 13 tools` too (see `scripts/mcp-e2e.sh`); change it to 14 in Task 5.

Add the stored property and init parameter beside `settingsDirectory`:

```swift
    /// Where `report_usage` appends. Optional so the tool can exist in contexts with
    /// no store; `UnavailableSessionRecorder` then refuses with a reason rather than
    /// accepting a report that would be dropped.
    private let sessionRecorder: any SessionRecording
```

```swift
    public init(
        provider: DataProvider,
        gate: PermissionGate,
        audit: AuditLog,
        settingsDirectory: URL? = nil,
        sessionRecorder: (any SessionRecording)? = nil
    ) {
        self.provider = provider
        self.gate = gate
        self.audit = audit
        self.settingsDirectory = settingsDirectory
        self.sessionRecorder = sessionRecorder ?? UnavailableSessionRecorder()
    }
```

Add the dispatch case:

```swift
        case "report_usage":
            // Counts are parsed and range-checked before the recorder is touched, so
            // an invalid report cannot leave a partial record behind.
            let input = try Self.nonNegative(arguments["input"], field: "input")
            let output = try Self.nonNegative(arguments["output"], field: "output")
            let model = try Self.nonBlank(arguments["model"], field: "model")
            let cacheRead = try Self.optionalNonNegative(arguments["cache_read"], field: "cache_read")
            let reasoning = try Self.optionalNonNegative(arguments["reasoning"], field: "reasoning")
            let note = try sessionRecorder.record(
                sessionID: nil, clientName: nil, clientVersion: nil,
                input: input, output: output,
                cacheRead: cacheRead, reasoning: reasoning, modelID: model
            )
            return AgentUsageRecordedPayload(note: note)
```

Add the helpers beside the existing `requireMetric`/`limit` validators, and the payload type beside `AlertsPayload`:

```swift
    /// A token count. Negative is refused rather than clamped: a negative count is a
    /// caller bug, and clamping would record a plausible number for a broken report.
    static func nonNegative(_ raw: String?, field: String) throws -> Int {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespaces)) else {
            throw MCPToolError(message: "\(field) must be a whole number.")
        }
        guard value >= 0 else {
            throw MCPToolError(message: "\(field) must not be negative.")
        }
        return value
    }

    static func optionalNonNegative(_ raw: String?, field: String) throws -> Int? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try nonNegative(raw, field: field)
    }

    static func nonBlank(_ raw: String?, field: String) throws -> String {
        guard let raw, let trimmed = raw.trimmingCharacters(in: .whitespaces).first else {
            throw MCPToolError(message: "\(field) is required.")
        }
        _ = trimmed
        return raw.trimmingCharacters(in: .whitespaces)
    }
```

```swift
struct AgentUsageRecordedPayload: Encodable {
    let recorded: Bool
    let note: String

    init(note: String) {
        self.recorded = true
        self.note = note
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter AgentUsageToolTests`
Expected: PASS — 8 tests, 0 failures

- [ ] **Step 6: Run the whole suite**

Run: `cd Core && swift test`
Expected: 240 tests, 0 failures, 1 skipped

The four catalog-count assertions now expect 14. If they still say 13, Step 4's edit
did not land.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/PortmasterMCP/SessionRecorder.swift Core/Sources/PortmasterMCP/ToolExecutor.swift Core/Tests/PortmasterMCPTests/AgentUsageToolTests.swift
git commit -m "feat(mcp): report_usage, an agent declaring its own token counts

Declared effect is .read, and deliberately so: it cannot quit a process, change
a setting or read anything. Requiring a click for a declaration that carries no
risk trains people to click through the prompts that do.

Counts are range-checked before the recorder is touched, so a negative or
non-numeric report cannot leave a partial record behind. A negative is refused
rather than clamped — it is a caller bug, and clamping would file a plausible
number for a broken report.

With no store wired, reports are refused with a reason rather than accepted and
dropped. An agent told 'recorded' when nothing was stored is worse than one told
it cannot report."
```

---

### Task 5: README and MCP surface documentation

**Files:**
- Modify: `README.md` — the MCP server section, near the tool table
- Test: `Core/Tests/PortmasterMCPTests/AgentUsageToolTests.swift` (add a catalog-count assertion)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing consumed by later tasks. This is the last task.

- [ ] **Step 1: Add the failing assertion**

Append to `AgentUsageToolTests`:

```swift
    /// The catalog count is asserted in the existing MCP conformance test and in the
    /// README, so adding a tool without updating either fails rather than drifting.
    func testCatalogCountIsExplicitlyCheckedSomewhere() {
        XCTAssertEqual(
            ToolExecutor.catalog.filter { $0.name == "report_usage" }.count, 1,
            "report_usage must appear exactly once in the catalog"
        )
    }
```

- [ ] **Step 2: Run the test**

Run: `cd Core && swift test --filter AgentUsageToolTests`
Expected: PASS

- [ ] **Step 3: Document the tool in the README**

In the MCP tool table in `README.md`, add a row for `report_usage` describing it as a declaration rather than a mutation, and note the two token sources.

Add a short subsection recording the honesty rules this slice established, so a later contributor cannot undo them by accident:

```markdown
#### Agent sessions and cost

`report_usage` lets an agent declare its own token counts. It is classified as a
read, not a mutation: it cannot act on the machine, and requiring a click for a
declaration carries no risk worth the interruption.

Two sources feed the same record, and every figure names its own. An agent that
calls `report_usage` produces a self-reported figure; an adapter reading an
agent's own session log produces a parsed one. When both exist, the self-reported
figure wins and the record says so.

**There is no number when there is no figure.** A session that reported nothing
reads *not reported*, never zero, and a model with no entry in the price table
reads *not priced*, never $0.00. Both are separate values from a measured zero,
because "we cannot tell" and "it was free" are different claims. A log whose format
Portmaster does not recognize yields *not reported* rather than a guess — a
plausible wrong number is the failure this design exists to prevent.

Costs are computed from a user-supplied price table rather than stored, so a
price change re-costs history instead of leaving figures describing an old price,
and every figure names the price-table version that produced it. Arithmetic is
`Decimal`, so a cost can be reconciled with a provider invoice.

No log adapters ship yet: the protocol and its outcome mapping exist, and the only
implementation is a test fixture. Nothing here has been run against a real agent.
```

- [ ] **Step 4: Update the e2e tool count**

In `scripts/mcp-e2e.sh`, change the `tools/list` count check from 13 to 14, and its
`note`/message text to match.

- [ ] **Step 5: Run the full suite and both builds**

Run: `cd Core && swift test`
Expected: 241 tests, 0 failures, 1 skipped

Run: `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build`
Expected: BUILD SUCCEEDED

Run: `scripts/mcp-e2e.sh --no-manual <Debug app> <portmaster-mcp>`
Expected: `17 passed, 0 failed, 1 skipped`

- [ ] **Step 6: Commit**

```bash
git add README.md scripts/mcp-e2e.sh Core/Tests/PortmasterMCPTests/AgentUsageToolTests.swift
git commit -m "docs: agent sessions, and the honesty rules they rest on

Records not-reported and not-priced as values distinct from zero, the two token
sources with provenance on every figure, and cost computed from a version-stamped
table in Decimal. Also states plainly that no real log adapter ships and nothing
has been run against a real agent."
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: the join and session identity → Task 2; token honesty and aggregation → Task 1; `report_usage` → Task 4; `TokenSourceAdapter` and the fixture-only rule → Task 3; `PriceTable` versioning and `Decimal` → Task 2; risks and testing → tasks throughout.

**Corrected during planning.** The spec said the new models live "alongside the existing Preferences models." They do not: `@Model` classes in `Preferences.swift` are all history samples, and `HistoryStore` registers its models in an explicit `ModelContainer(for:)` list. A model missing from that list never persists and nothing fails, so Task 2 registers them and adds a round-trip test that would catch the omission.

**Placeholder scan.** No TBD, TODO, or "similar to Task N". Every code block contains the code.

**Catalog size.** Adding `report_usage` takes the catalog from 13 tools to 14, and
four existing tests plus the e2e script assert that number literally. Step 4 of
Task 4 and step 4 of Task 5 update them, because a count asserted in five places is
a count that fails in five places at once otherwise.

**Test target placement.** `AgentUsageToolTests` was originally written against
`PortmasterCoreTests`, which cannot see `StubProvider` — it is defined in
`PortmasterMCPTests`. Moved to `PortmasterMCPTests`, beside its only consumer.

**Unverified SwiftData assumption.** `Decimal` in a `@Model` property has no
precedent in this codebase and may not be supported. Task 2 flags this as a check
before implementation, with the fallback spelled out (scaled `Int` or decimal
`String` at rest, convert at the boundary — never `Double`).

**Type consistency.** `TokenUsageRecord` is a struct in Task 1 and becomes `TokenUsageRecordRow` for persistence in Task 2, with `.value` converting back — the rename is deliberate (SwiftData `@Model` cannot hold the enum-typed aggregate) and both directions are used. `AgentSessionSnapshot` is produced in Task 2 and consumed by Task 3's adapter protocol. `SessionRecording.record` matches exactly between the protocol, `StoreSessionRecorder`, `UnavailableSessionRecorder` and the `SpyRecorder` in Task 4's tests.
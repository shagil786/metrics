# Per-model Token Segments — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A session's token usage represents every model that ran, each priced at its own rate, and retention sweeps cannot change a figure.

**Architecture:** `TokenUsage` becomes a list of per-model segments. The fold keys on `(provenance, modelID)` instead of provenance alone, so two models inside one provenance stop overwriting each other. `costLocked` prices each segment at its own model's rate and sums. `prune` deletes only records already superseded within their own segment.

**Tech Stack:** Swift 6, SwiftData, Swift Testing via XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-10-08-per-model-token-segments-design.md`

## Global Constraints

- **Unknown is never zero.** Every absence state stays distinct from a measured `0`. A total missing one model's cost is a wrong number and must never be printed.
- **Money is `Decimal`**, never binary floating point, end to end.
- **Sub-dollar figures render exactly.** `Fmt.usd` prints the stored decimal verbatim below $1; rounding `0.0000075` to six places produces a different number from the one computed.
- **1% tolerance** (`Decimal(string: "0.01")`) is the conflict threshold, relative to the larger of the two totals. It is a judgement call with no data behind it yet and is expected to be tuned.
- **Equal `recordedAt` keeps the earlier element.** Array order is the only tie-break available without a sequence number, so record ordering is load-bearing.
- **No migration ships.** `TokenUsageRecordRow` already stores `modelID` and `provenanceRaw`. Do not add a schema version for this work.
- Comments explain *why*, never *what*. Match the density and voice of the surrounding file.

---

### Task 1: Segment type and the `(provenance, modelID)` fold

The one change that stops models being lost. Everything else in this plan depends on it.

**Files:**
- Modify: `Core/Sources/PortmasterCore/History/AgentUsage.swift`
- Test: `Core/Tests/PortmasterCoreTests/AgentUsageTests.swift`

**Interfaces:**
- Consumes: `TokenUsageRecord` (existing, unchanged), `TokenProvenance` (existing, unchanged)
- Produces:
  - `public struct TokenUsageSegment: Hashable, Sendable` — fields `modelID: String`, `input: Int`, `output: Int`, `cacheRead: Int?`, `reasoning: Int?`, `provenance: TokenProvenance`; memberwise `public init`
  - `TokenUsage.reported([TokenUsageSegment])` replaces `.reported(input:output:provenance:)`
  - `TokenUsage.reported(input:output:modelID:provenance:) -> TokenUsage` — single-model convenience
  - `TokenUsage.latestPerSegment(_ records: [TokenUsageRecord]) -> [TokenUsageRecord]` — replaces `latestPerProvenance`

- [ ] **Step 1: Write the failing test**

Add to `AgentUsageTests.swift`:

```swift
    /// The regression that made `020f48e` wrong. Two models inside one provenance must
    /// both survive the fold: keyed on provenance alone they overwrite each other, and
    /// the aggregate silently drops one.
    func testTwoModelsInOneProvenanceBothSurviveTheFold() {
        let at = Date()
        let sid = UUID()
        let records = [
            TokenUsageRecord(sessionID: sid, recordedAt: at, input: 100, output: 50,
                             cacheRead: nil, reasoning: nil, modelID: "model-a",
                             provenance: .parsedFromLog),
            TokenUsageRecord(sessionID: sid, recordedAt: at, input: 200, output: 75,
                             cacheRead: nil, reasoning: nil, modelID: "model-b",
                             provenance: .parsedFromLog),
        ]
        let usage = TokenUsage.aggregating(records)
        guard case .reported(let segments) = usage else {
            return XCTFail("expected segments, got \(usage)")
        }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(Set(segments.map(\.modelID)), ["model-a", "model-b"])
        XCTAssertEqual(segments.reduce(0) { $0 + $1.input }, 300)
        XCTAssertEqual(segments.reduce(0) { $0 + $1.output }, 125)
    }

    func testOneModelIsStillASingleSegment() {
        let usage = TokenUsage.reported(input: 10, output: 5, modelID: "m", provenance: .selfReported)
        guard case .reported(let segments) = usage else {
            return XCTFail("expected segments, got \(usage)")
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].modelID, "m")
    }

    /// Same `(provenance, model)`: a later reading replaces the earlier one, because
    /// counters are cumulative and summing them would count the first twice.
    func testLaterReadingReplacesEarlierForTheSameSegment() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(sessionID: sid, recordedAt: Date(timeIntervalSince1970: 100),
                             input: 10, output: 5, cacheRead: nil, reasoning: nil,
                             modelID: "m", provenance: .parsedFromLog),
            TokenUsageRecord(sessionID: sid, recordedAt: Date(timeIntervalSince1970: 200),
                             input: 90, output: 45, cacheRead: nil, reasoning: nil,
                             modelID: "m", provenance: .parsedFromLog),
        ]
        XCTAssertEqual(TokenUsage.latestPerSegment(records).count, 1)
        XCTAssertEqual(TokenUsage.latestPerSegment(records).first?.input, 90)
    }

    func testDifferentProvenancesWithTheSameModelAreDistinctSegments() {
        let sid = UUID()
        let at = Date()
        let records = [
            TokenUsageRecord(sessionID: sid, recordedAt: at, input: 10, output: 5,
                             cacheRead: nil, reasoning: nil, modelID: "m",
                             provenance: .selfReported),
            TokenUsageRecord(sessionID: sid, recordedAt: at, input: 12, output: 6,
                             cacheRead: nil, reasoning: nil, modelID: "m",
                             provenance: .parsedFromLog),
        ]
        XCTAssertEqual(TokenUsage.latestPerSegment(records).count, 2)
    }

    func testNoRecordsIsAwaitingFirstReportNotZero() {
        guard case .notReported(let reason) = TokenUsage.aggregating([]) else {
            return XCTFail("expected absence")
        }
        XCTAssertEqual(reason, .awaitingFirstReport)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Core && swift test --filter AgentUsageTests`
Expected: FAIL — `TokenUsage` has no member `latestPerSegment`, and `.reported(input:output:modelID:provenance:)` does not exist.

- [ ] **Step 3: Implement the segment type and fold**

In `AgentUsage.swift`, add before `enum TokenUsage`:

```swift
/// One model's share of a session's usage, with the source that reported it.
///
/// **A list of these, not a single value, because one session can run two models.**
/// The type that preceded it carried `(input, output, provenance)` with no model at
/// all, so a fold keyed on provenance had to collapse an escalated session onto one
/// model — and it collapsed silently, discarding the other's tokens with no trace.
/// Keying on `(provenance, modelID)` makes two models two segments instead.
public struct TokenUsageSegment: Hashable, Sendable {
    public let modelID: String
    public let input: Int
    public let output: Int
    /// Priced separately from input/output, and nil when the source omits them —
    /// summing them into `input` produces a cost no provider invoice will reconcile.
    public let cacheRead: Int?
    public let reasoning: Int?
    /// Part of the segment, not a property of the session: the same model reported by
    /// two sources is two segments, which is what lets the two be compared.
    public let provenance: TokenProvenance

    public init(
        modelID: String, input: Int, output: Int,
        cacheRead: Int?, reasoning: Int?, provenance: TokenProvenance
    ) {
        self.modelID = modelID
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.reasoning = reasoning
        self.provenance = provenance
    }

    /// The comparable size of this segment: input plus output.
    ///
    /// **Deliberately excludes `cacheRead` and `reasoning`.** Disagreement is about
    /// whether two sources counted the same work, and cache reads are priced
    /// differently enough that a source reporting them where another does not is a
    /// pricing-shape difference, not a disagreement about the total.
    public var comparableTotal: Int { input + output }
}
```

Replace the `TokenUsage` enum's `reported` case and add the convenience constructor:

```swift
public enum TokenUsage: Hashable, Sendable {
    case reported([TokenUsageSegment])
    case notReported(reason: UsageUnavailableReason)

    /// The common case: one model, one source. Keeps the many call sites that only
    /// ever have a single model from spelling out a one-element array.
    public static func reported(
        input: Int, output: Int, modelID: String, provenance: TokenProvenance
    ) -> TokenUsage {
        .reported([TokenUsageSegment(
            modelID: modelID, input: input, output: output,
            cacheRead: nil, reasoning: nil, provenance: provenance
        )])
    }
}
```

Replace `latestPerProvenance` with:

```swift
    /// The latest reading for each `(provenance, modelID)` pair.
    ///
    /// Keyed on both, not on provenance alone. Keying on provenance alone made an
    /// escalated session's two models compete for one slot, and because the runner
    /// stamps every segment of one observation with the same instant, the tie-break
    /// below picked the earlier one and the later model was discarded.
    ///
    /// Ordered by provenance then model id so two runs over the same records produce
    /// the same array — the fold's output reaches a UI list, and an unstable order
    /// makes a diff of two reads look like a change when nothing moved.
    static func latestPerSegment(_ records: [TokenUsageRecord]) -> [TokenUsageRecord] {
        var latest: [TokenProvenance: [String: TokenUsageRecord]] = [:]
        for record in records {
            var byModel = latest[record.provenance] ?? [:]
            // `>=` keeps the earlier element: two reports sharing a timestamp are one
            // instant described twice, and array order is the only tie-break available
            // without a sequence number to arbitrate.
            if let existing = byModel[record.modelID],
               existing.recordedAt >= record.recordedAt {
                continue
            }
            byModel[record.modelID] = record
            latest[record.provenance] = byModel
        }
        return latest
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { _, byModel in
                byModel.sorted { $0.key < $1.key }.map(\.value)
            }
    }
```

Rewrite `aggregating`:

```swift
    public static func aggregating(_ records: [TokenUsageRecord]) -> TokenUsage {
        // Empty in, empty out: no records means no segment won, which the guard
        // reports as `awaitingFirstReport` rather than a zero.
        let segments = latestPerSegment(records).map { record in
            TokenUsageSegment(
                modelID: record.modelID, input: record.input, output: record.output,
                cacheRead: record.cacheRead, reasoning: record.reasoning,
                provenance: record.provenance
            )
        }
        guard !segments.isEmpty else {
            return .notReported(reason: .awaitingFirstReport)
        }
        return .reported(segments)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Core && swift test --filter AgentUsageTests`
Expected: the new tests PASS. Existing tests in this file may fail to compile — `.reported(input:output:provenance:)` no longer has that shape. Migrate each to the convenience constructor, which takes the same arguments plus `modelID:`, and add the `modelID` the test was implicitly assuming.

- [ ] **Step 5: Run the full Core suite**

Run: `cd Core && swift test`
Expected: FAIL in `AgentSessionStoreTests` and `AgentSessionWiringTests`, which assert the old aggregate shape. That is expected at this stage — Task 3 and Task 5 fix them. Confirm the failures are **only** aggregate-shape assertions, not new logic faults.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/PortmasterCore/History/AgentUsage.swift Core/Tests/PortmasterCoreTests/AgentUsageTests.swift
git commit -m "fix: key the usage fold on (provenance, model), not provenance alone

TokenUsage carried (input, output, provenance) with no model, so a fold keyed on
provenance had to collapse an escalated session onto one model. Because the runner
stamps every segment of one observation with the same instant, the tie-break picked
the earlier segment and the later model was discarded — measured at 67% of a real
session's output tokens, silently.

TokenUsage now holds [TokenUsageSegment], and latestPerSegment keys on
(provenance, modelID). Two models are two segments.

Output for the fold is ordered, because it reaches a UI list and an unstable order
makes two reads of unchanged records look like a change."
```

---

### Task 2: Repurpose `conflict` to mean same-model disagreement

**Files:**
- Modify: `Core/Sources/PortmasterCore/History/AgentUsage.swift`
- Test: `Core/Tests/PortmasterCoreTests/AgentUsageTests.swift`

**Interfaces:**
- Consumes: `TokenUsageSegment` (Task 1)
- Produces:
  - `public struct UsageDisagreement: Hashable, Sendable` — `modelID: String`, `totals: [TokenProvenance: Int]`
  - `TokenUsage.hasMaterialDisagreement(_ segments: [TokenUsageSegment], tolerance: Decimal) -> [UsageDisagreement]` — replaces `hasModelConflict(_ records:)`

- [ ] **Step 1: Write the failing tests**

```swift
    /// 20% apart is a broken reader, not rounding: the two must not be silently
    /// reconciled to one figure.
    func testSameModelDifferingWellBeyondToleranceIsADisagreement() {
        let segments = [
            TokenUsageSegment(modelID: "m", input: 1000, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .selfReported),
            TokenUsageSegment(modelID: "m", input: 1200, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
        ]
        let found = TokenUsage.hasMaterialDisagreement(
            segments, tolerance: Decimal(string: "0.01")!)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.modelID, "m")
        XCTAssertEqual(found.first?.totals[.selfReported], 1000)
        XCTAssertEqual(found.first?.totals[.parsedFromLog], 1200)
    }

    /// Two sources differing by less than the tolerance are noise, not a signal. Without
    /// a tolerance every trivial difference would pin a session in conflict forever.
    func testDifferenceUnderToleranceIsNotADisagreement() {
        let segments = [
            TokenUsageSegment(modelID: "m", input: 1000, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .selfReported),
            TokenUsageSegment(modelID: "m", input: 1005, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
        ]
        XCTAssertTrue(TokenUsage.hasMaterialDisagreement(
            segments, tolerance: Decimal(string: "0.01")!).isEmpty)
    }

    /// Different models are the normal case now, not a conflict: they are separate
    /// segments and each gets priced at its own rate.
    func testDifferentModelsAreNotADisagreement() {
        let segments = [
            TokenUsageSegment(modelID: "model-a", input: 100, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .selfReported),
            TokenUsageSegment(modelID: "model-b", input: 900, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
        ]
        XCTAssertTrue(TokenUsage.hasMaterialDisagreement(
            segments, tolerance: Decimal(string: "0.01")!).isEmpty)
    }

    /// Both totals zero: the ratio is 0/0 and must not divide.
    func testTwoZeroTotalsAreNotADisagreement() {
        let segments = [
            TokenUsageSegment(modelID: "m", input: 0, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .selfReported),
            TokenUsageSegment(modelID: "m", input: 0, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
        ]
        XCTAssertTrue(TokenUsage.hasMaterialDisagreement(
            segments, tolerance: Decimal(string: "0.01")!).isEmpty)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd Core && swift test --filter AgentUsageTests`
Expected: FAIL — `hasMaterialDisagreement` and `UsageDisagreement` do not exist.

- [ ] **Step 3: Implement**

Add:

```swift
/// Two sources reporting the same model with totals too far apart to be the same
/// work. The model may be priced perfectly well; what is missing is a reason to
/// prefer one source's count, so the cost cannot be computed at all.
public struct UsageDisagreement: Hashable, Sendable {
    public let modelID: String
    /// Newest reading per source, so the disagreement shows the two numbers the user
    /// is being asked to choose between rather than merely asserting that they differ.
    public let totals: [TokenProvenance: Int]

    public init(modelID: String, totals: [TokenProvenance: Int]) {
        self.modelID = modelID
        self.totals = totals
    }
}
```

Replace `hasModelConflict` with:

```swift
    /// Models the two sources report with totals that differ beyond `tolerance`.
    ///
    /// **This is not the rule it used to be.** It asked whether sources disagreed about
    /// *which model ran*, so that a mixed total was never priced at one rate. Segments
    /// make that unrepresentable — two models are two segments, each priced at its own
    /// rate — which leaves a different disagreement worth catching: the same model,
    /// counted differently by two readers. A self-report of 1,000 tokens against a log
    /// parse of 1,200 means one of the two is wrong, and silently preferring one is the
    /// same failure as losing a model.
    ///
    /// **Relative to the larger of the two totals**, so a small reading against a large
    /// one is not amplified, and a zero pair is skipped rather than divided.
    ///
    /// The tolerance is a judgement call with no data behind it yet. It exists because
    /// two readers of one session differ trivially, and a strict rule would pin a
    /// session in conflict over a single token. It is expected to be tuned against real
    /// disagreement before it is trusted.
    public static func hasMaterialDisagreement(
        _ segments: [TokenUsageSegment],
        tolerance: Decimal
    ) -> [UsageDisagreement] {
        var byModel: [String: [TokenProvenance: Int]] = [:]
        for segment in segments {
            byModel[segment.modelID, default: [:]][segment.provenance] = segment.comparableTotal
        }

        var found: [UsageDisagreement] = []
        for (modelID, totals) in byModel.sorted(by: { $0.key < $1.key }) {
            // One source cannot disagree with itself.
            guard totals.count > 1 else { continue }
            let values = totals.values.map(Decimal.init)
            guard let largest = values.max(), largest > 0 else { continue }
            let smallest = values.min() ?? 0
            let relativeDifference = (largest - smallest) / largest
            if relativeDifference > tolerance {
                found.append(UsageDisagreement(modelID: modelID, totals: totals))
            }
        }
        return found
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd Core && swift test --filter AgentUsageTests`
Expected: the four new tests PASS.

- [ ] **Step 5: Delete the now-dead `hasModelConflict` tests**

Remove every test in `AgentUsageTests.swift` that exercises `hasModelConflict`, and delete the function itself if `AgentSessionStore.costLocked` is the only remaining caller — Task 3 removes that call.

- [ ] **Step 6: Commit**

```bash
git add Core/Sources/PortmasterCore/History/AgentUsage.swift Core/Tests/PortmasterCoreTests/AgentUsageTests.swift
git commit -m "feat: conflict now means the same model counted two ways

Conflict used to mean two sources disagreed about which model ran, so a mixed total
was never priced at one rate. Segments make that unrepresentable, which leaves the
disagreement worth catching: the same model, counted differently by two readers. A
self-report of 1,000 against a log parse of 1,200 means one of them is wrong, and
silently preferring one is the same failure as losing a model.

Both totals are named, because the user is being asked to choose between them and
asserting only that they differ gives them nothing to choose with.

The threshold is relative to the larger total, so a small reading is not amplified,
and a zero pair is skipped rather than divided. 1% is a judgement call with no data
behind it and is expected to be tuned."
```

---

### Task 3: Price each segment at its own rate and sum

**Files:**
- Modify: `Core/Sources/PortmasterCore/History/AgentUsage.swift` (`SessionCost`)
- Modify: `Core/Sources/PortmasterCore/History/AgentSessionStore.swift` (`costLocked`)
- Test: `Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift`

**Interfaces:**
- Consumes: `TokenUsageSegment`, `UsageDisagreement` (Tasks 1–2), existing `PriceComponent`, `PriceTable.price(_:)`
- Produces:
  - `public struct CostLine: Hashable, Sendable` — `modelID: String`, `usd: Decimal`
  - `SessionCost.priced(usd: Decimal, priceTableVersion: Int, lines: [CostLine])`
  - `SessionCost.notPriced(models: [String])` — was `notPriced(modelID: String)`
  - `SessionCost.conflict(disagreements: [UsageDisagreement])` — was `conflict(models: [String])`

- [ ] **Step 1: Write the failing test**

In `AgentSessionStoreTests.swift`:

```swift
    /// Two models at different rates must be priced at their own rates and summed.
    /// Pricing a mixed total at one rate is the known-unsound case segments exist to
    /// remove, so this is the assertion the whole type change is for.
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

    func testSameModelDisagreementSuppressesTheCostAndNamesBothTotals() throws {
        let (store, _) = try makeStoreOnDisk()
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
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd Core && swift test --filter AgentSessionStoreTests`
Expected: FAIL — `priced` takes two associated values, `notPriced` takes one, `conflict` takes a different shape.

- [ ] **Step 3: Change `SessionCost`**

```swift
/// One model's contribution to a session's cost. Present so a total can be shown as
/// its parts rather than only its sum — an escalated session priced as one number
/// hides that two rates were involved.
public struct CostLine: Hashable, Sendable {
    public let modelID: String
    public let usd: Decimal

    public init(modelID: String, usd: Decimal) {
        self.modelID = modelID
        self.usd = usd
    }
}

public enum SessionCost: Hashable, Sendable {
    case priced(usd: Decimal, priceTableVersion: Int, lines: [CostLine])
    /// At least one model has no entry in the price table, so the total is unknown.
    /// **Every unpriced model is named**, because entering one price does not make the
    /// total computable while another model is still unpriced.
    case notPriced(models: [String])
    /// Sources counted the same model differently. Kept apart from `notPriced`: both
    /// models here may be priced perfectly well, so "enter a price" would do nothing,
    /// and reporting a missing price for a priced model is a claim the user can
    /// disprove.
    case conflict(disagreements: [UsageDisagreement])
    /// Nothing to price yet.
    case noUsage

    public var usd: Decimal? {
        switch self {
        case .priced(let usd, _, _): return usd
        // Every other case is absence of a figure, never a figure of zero.
        case .notPriced, .conflict, .noUsage: return nil
        }
    }
}
```

- [ ] **Step 4: Rewrite `costLocked`**

Replace the whole body of `costLocked` in `AgentSessionStore.swift`:

```swift
    private func costLocked(records: [TokenUsageRecord], table: PriceTable) -> SessionCost {
        guard !records.isEmpty else { return .noUsage }

        let segments = TokenUsage.latestPerSegment(records).map { record in
            TokenUsageSegment(
                modelID: record.modelID, input: record.input, output: record.output,
                cacheRead: record.cacheRead, reasoning: record.reasoning,
                provenance: record.provenance
            )
        }
        guard !segments.isEmpty else { return .noUsage }

        // Two sources counting one model differently is asked here rather than
        // re-derived below, so the list view and a single-session read cannot price the
        // same session differently.
        let disagreements = TokenUsage.hasMaterialDisagreement(
            segments, tolerance: Decimal(string: "0.01")!)
        if !disagreements.isEmpty {
            return .conflict(disagreements: disagreements)
        }

        // Each segment is priced at *its own* model's rate and the results summed.
        // Pricing a mixed total at one rate is the unsound figure segments exist to
        // remove — it cannot be reconciled with an invoice, because the invoice has
        // two lines and the total has one rate applied to both.
        var total = Decimal(0)
        var version = 0
        var lines: [CostLine] = []
        var unpriced: [String] = []

        for segment in segments {
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
        // Zero tokens cost zero under any table, so the figure is exact; it still names
        // the prices it stands under rather than a version of 0, which would read as
        // "priced from nothing".
        return .priced(
            usd: total, priceTableVersion: max(version, table.currentVersion),
            lines: lines.sorted { $0.modelID < $1.modelID }
        )
    }
```

- [ ] **Step 5: Run to verify the new tests pass**

Run: `cd Core && swift test --filter AgentSessionStoreTests`
Expected: the three new tests PASS. Remaining failures are old-shape assertions — continue to Step 6.

- [ ] **Step 6: Migrate the remaining old-shape assertions**

Run: `cd Core && swift test --filter AgentSessionStoreTests` and fix each failure by updating the expectation to the new shape:

- `.priced(usd: X, priceTableVersion: V)` → `.priced(usd: X, priceTableVersion: V, lines: [])` when the session has no spend, or with the computed `lines` when it does.
- `.notPriced(modelID: "m")` → `.notPriced(models: ["m"])`
- `.conflict(models: ["a", "b"])` → `.conflict(disagreements: [...])`. **Note:** several of these assert a *different models* case that is no longer a conflict at all — two models are now two segments. Delete those rather than translating them; they were pinning the old collapsing behaviour.

- [ ] **Step 7: Run the full Core suite**

Run: `cd Core && swift test`
Expected: Core PASS. MCP tests still fail on wire payloads — Task 5 fixes them.

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/PortmasterCore/History/AgentUsage.swift Core/Sources/PortmasterCore/History/AgentSessionStore.swift Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift
git commit -m "feat: price each segment at its own model's rate and sum

Pricing a mixed total at one rate is the unsound figure segments exist to remove: an
invoice has two lines and the total had one rate applied to both, so nothing
reconciles. Each segment is now priced at its own model's rate and the results
summed, with the per-model lines kept so a total can be shown as its parts.

One unpriced model suppresses the whole total and names every unpriced model, rather
than printing a sum that omits spend. Pricing one of several does not make the total
computable, so the absence has to name all of them.

Several existing .conflict(models:) assertions were deleted rather than translated:
they asserted that two different models conflict, which is no longer a conflict at
all — they were pinning the old collapsing behaviour."
```

---

### Task 4: Prune deletes only superseded records

Makes trimming figure-preserving. Independent of the segment work — this is a
separate defect, and this is its own fix.

**Files:**
- Modify: `Core/Sources/PortmasterCore/History/AgentSessionStore.swift` (`prune`)
- Test: `Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift`

**Interfaces:**
- Consumes: nothing from Tasks 1–3; `prune(olderThan: Date, keepingSessionIDs: Set<UUID>)` keeps its signature
- Produces: the same signature with corrected semantics. **No new public API.**

- [ ] **Step 1: Write the failing test**

Add to `AgentSessionStoreTests.swift`, and **delete `testPruneTrimmingCanResolveATwoProvenanceConflictIntoAPrice`** in the same edit — it asserts the defect:

```swift
    /// The inverse of the test this replaces. Two models in two sources is two
    /// segments and both are priced, so the sweep has nothing left to change — the
    /// property being asserted is that retention cannot move a figure.
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
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "model-a")
        try store.setPrice(Decimal(string: "0.000002")!, modelID: "model-b")
        try store.flush()

        let usageBefore = try store.usage(for: session)
        let costBefore = try store.cost(for: session)

        store.prune(olderThan: cutoff, keepingSessionIDs: [])

        let reopened = try AgentSessionStore(storeURL: url)
        XCTAssertEqual(try reopened.usage(for: session), usageBefore,
                       "a sweep changed the usage")
        XCTAssertEqual(try reopened.cost(for: session), costBefore,
                       "a sweep changed the cost")
    }

    /// The superseded case, which *should* still be deleted: a newer record for the
    /// same (provenance, model) means this one is unread, so removing it is inert.
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
```

- [ ] **Step 2: Run to verify the first test fails**

Run: `cd Core && swift test --filter "AgentSessionStoreTests/testPrune"`
Expected: `testPruneDoesNotChangeAFigureForATwoSourceSession` FAILS — the old trim deletes the sole self-report, so `usage` after the sweep is the parse's segment alone.

- [ ] **Step 3: Fix the trim**

In `prune`, replace the trim loop:

```swift
            // One query for "what is each segment's newest reading", not one per
            // session: a record may only be deleted when something newer exists for its
            // own (provenance, model) pair, and that is a property of the whole table.
            let newestPerSegment = try context.fetch(FetchDescriptor<TokenUsageRecordRow>()).reduce(
                into: [SegmentKey: Date]()
            ) { partial, row in
                let key = SegmentKey(
                    sessionID: row.sessionID,
                    provenance: row.provenanceRaw,
                    modelID: row.modelID
                )
                partial[key] = max(partial[key] ?? .distantPast, row.recordedAt)
            }

            for id in trimmed {
                // Delete the superseded and out-of-window records, and nothing else.
                // Deleting a segment's *latest* record would remove the segment, and a
                // provenance disappearing from a session is how a sweep used to turn a
                // disagreement into a confident figure — the retention policy choosing
                // between two sources nobody had chosen between.
                let sessionRows = try context.fetch(FetchDescriptor<TokenUsageRecordRow>(
                    predicate: #Predicate { $0.sessionID == id }
                ))
                for row in sessionRows {
                    let key = SegmentKey(
                        sessionID: row.sessionID,
                        provenance: row.provenanceRaw,
                        modelID: row.modelID
                    )
                    // No newer record for this pair means this *is* the segment's latest
                    // reading, and it must survive whatever the window says.
                    let superseded = newestPerSegment[key].map { row.recordedAt < $0 } ?? false
                    guard superseded, row.recordedAt < cutoff else { continue }
                    context.delete(row)
                }
            }
```

Add the key type near `prune`:

```swift
    /// Identity of a usage segment for retention purposes: the same
    /// `(provenance, model)` pair. A SwiftData model cannot be a dictionary key, so
    /// this is the value form of the three fields the trim needs.
    private struct SegmentKey: Hashable {
        let sessionID: UUID
        let provenance: String
        let modelID: String
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd Core && swift test --filter "AgentSessionStoreTests/testPrune"`
Expected: both new tests PASS.

- [ ] **Step 5: Rewrite the doc comment on `prune`**

The comment block at `AgentSessionStore.swift:415` says the trim is unsafe for two-provenance sessions and that "no adapter ships" so it cannot happen. Both halves are now false. Replace that block with:

```swift
    /// - **kept, records trimmed** — stale but still reporting. Records go, but a
    ///   record is only removed when a newer one exists for its own
    ///   `(provenance, model)` pair, so a segment's latest reading always survives.
    ///   Trimming is therefore figure-preserving: no provenance and no model can
    ///   disappear from an aggregate as a side effect of retention.
```

- [ ] **Step 6: Run the full Core suite**

Run: `cd Core && swift test`
Expected: Core PASS.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/PortmasterCore/History/AgentSessionStore.swift Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift
git commit -m "fix: prune deletes only records superseded within their own segment

The trim deleted by session and timestamp, so it could remove the only record of a
provenance. A two-source session would go from a stated disagreement to a confident
priced figure for whichever model survived — a retention sweep choosing between two
sources nobody had chosen between.

A record is now removed only when a newer one exists for the same (provenance,
model) pair and it falls outside the window, which makes trimming figure-preserving
by construction. No liveness table and no phase-C data model.

The superseded case is still deleted: a record with a newer sibling is unread, so
removing it is inert, and the test says so — otherwise this fix would trade unbounded
growth for stale rows.

Deletes the test that pinned the defect. It was green because it asserted the wrong
behaviour, and its inverse was written first."
```

---

### Task 5: Wire payloads

**Files:**
- Modify: `Core/Sources/PortmasterMCP/WirePayloads.swift`
- Test: `Core/Tests/PortmasterMCPTests/AgentSessionWiringTests.swift`

**Interfaces:**
- Consumes: `TokenUsageSegment`, `UsageDisagreement`, `CostLine` (Tasks 1–3)
- Produces: `TokenUsagePayload` with `segments: [SegmentPayload]?`, `SessionCostPayload` with `lines: [CostLinePayload]?` and `disagreements: [DisagreementPayload]?`

- [ ] **Step 1: Write the failing test**

In `AgentSessionWiringTests.swift`:

```swift
    func testSessionPayloadCarriesBothModelSegments() throws {
        let session = AgentSessionSnapshot(
            id: UUID(), peerPID: 1, clientName: "escalated", clientVersion: nil,
            connectedAt: Date(), endedAt: nil,
            usage: .reported([
                TokenUsageSegment(modelID: "model-a", input: 100, output: 50,
                                  cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
                TokenUsageSegment(modelID: "model-b", input: 200, output: 75,
                                  cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
            ]),
            cost: .priced(usd: Decimal(string: "0.0019")!, priceTableVersion: 3, lines: [
                CostLine(modelID: "model-a", usd: Decimal(string: "0.0001")!),
                CostLine(modelID: "model-b", usd: Decimal(string: "0.0018")!),
            ])
        )
        let json = try JSONEncoder().encode(AgentSessionPayload(session, isOpen: true))
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("model-a"))
        XCTAssertTrue(text.contains("model-b"))
        XCTAssertTrue(text.contains("0.0001"))
        // The payload must not collapse to one figure: the whole point of segments is
        // that a client can see there were two rates.
        XCTAssertFalse(text.contains("\"segments\":[]"))
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd Core && swift test --filter AgentSessionWiringTests`
Expected: FAIL — `TokenUsagePayload` has no `segments` and `SessionCostPayload` has no `lines`.

- [ ] **Step 3: Rewrite `TokenUsagePayload`**

```swift
/// One session's usage as a list of per-model segments, with the absence kept
/// distinct from a measured zero.
///
/// `segments` is null for every not-reported case and `reason` names which one. A
/// caller cannot read a null list as "zero tokens" — which would say a session was
/// free when in fact nobody counted it.
struct TokenUsagePayload: Encodable {
    let reported: Bool
    /// One entry per `(provenance, model)`. A list rather than two integers because a
    /// session can run two models, and a single pair of totals would have to pick one.
    let segments: [SegmentPayload]?
    /// Why no figure exists: `noSource`, `logUnreadable`, `unrecognizedFormat`,
    /// `awaitingFirstReport`, `ambiguousMatch`. Present only when `reported` is false.
    let reason: String?

    init(_ usage: TokenUsage) {
        switch usage {
        case .reported(let segments):
            self.reported = true
            self.segments = segments.map(SegmentPayload.init)
            self.reason = nil
        case .notReported(let reason):
            self.reported = false
            self.segments = nil
            self.reason = reason.rawValue
        }
    }
}

struct SegmentPayload: Encodable {
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int?
    let reasoningTokens: Int?
    /// Which source produced this segment. Never omitted in favour of a default: a
    /// number whose origin is unknown cannot be audited.
    let provenance: String

    init(_ segment: TokenUsageSegment) {
        self.model = segment.modelID
        self.inputTokens = segment.input
        self.outputTokens = segment.output
        self.cacheReadTokens = segment.cacheRead
        self.reasoningTokens = segment.reasoning
        self.provenance = segment.provenance.rawValue
    }
}
```

- [ ] **Step 4: Rewrite `SessionCostPayload`**

```swift
/// A session's cost, with `notPriced` and `conflict` distinct from a priced zero.
struct SessionCostPayload: Encodable {
    let priced: Bool
    /// A string, not a JSON number: binary floating point cannot carry money and a
    /// decimal string round-trips through any client unchanged.
    let usd: String?
    let priceTableVersion: Int?
    /// `unpriced`, `conflict`, or `noUsage` when `priced` is false.
    let reason: String?
    /// Every model with no price, so the client can show what is missing rather than
    /// only that something is.
    let models: [String]?
    /// The per-model split behind the total, so a client can show a total as its parts.
    let lines: [CostLinePayload]?
    /// The same models counted differently by two sources, with both numbers, so a
    /// client can put the choice to the user instead of asserting a disagreement.
    let disagreements: [DisagreementPayload]?

    init(_ cost: SessionCost) {
        self.lines = nil
        self.disagreements = nil
        switch cost {
        case .priced(let usd, let version, let lines):
            self.priced = true
            self.usd = NSDecimalNumber(decimal: usd).stringValue
            self.priceTableVersion = version
            self.reason = nil
            self.models = nil
            self.lines = lines.map { CostLinePayload(model: $0.modelID, usd: $0.usd) }
        case .notPriced(let models):
            self.priced = false
            self.usd = nil
            self.priceTableVersion = nil
            self.reason = "unpriced"
            self.models = models
        case .conflict(let disagreements):
            self.priced = false
            self.usd = nil
            self.priceTableVersion = nil
            self.reason = "conflict"
            self.models = disagreements.map(\.modelID)
            self.disagreements = disagreements.map(DisagreementPayload.init)
        case .noUsage:
            self.priced = false
            self.usd = nil
            self.priceTableVersion = nil
            self.reason = "noUsage"
            self.models = nil
        }
    }
}

struct CostLinePayload: Encodable {
    let model: String
    /// A decimal string, for the same reason the total is one.
    let usd: String

    init(model: String, usd: Decimal) {
        self.model = model
        self.usd = NSDecimalNumber(decimal: usd).stringValue
    }
}

struct DisagreementPayload: Encodable {
    let model: String
    /// Newest total per source, keyed by provenance. Both numbers, because the user is
    /// being asked to choose between them.
    let totals: [String: Int]

    init(_ disagreement: UsageDisagreement) {
        self.model = disagreement.modelID
        // Re-keyed by the provenance's raw value because a Swift enum is not a
        // `CodingKey`-friendly JSON dictionary key, and a client reading this has no
        // way to resolve `selfReported` to itself.
        self.totals = disagreement.totals.reduce(into: [String: Int]()) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd Core && swift test --filter AgentSessionWiringTests`
Expected: PASS.

- [ ] **Step 6: Run everything**

Run: `cd Core && swift test`
Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/PortmasterMCP/WirePayloads.swift Core/Tests/PortmasterMCPTests/AgentSessionWiringTests.swift
git commit -m "feat: sessions wire as per-model segments

A client could not see that a session ran two models, because the payload carried
two integers and a provenance and had to pick one. segments, lines and disagreements
carry the shape through: the per-model split, the per-model cost behind the total,
and both numbers of any disagreement.

Every money value stays a decimal string. Binary floating point cannot carry money
and a decimal string round-trips through any client unchanged."
```

---

### Task 6: Sessions card

**Files:**
- Modify: `App/OverviewView.swift` (`AgentSessionsCard` and `SessionLine`)

**Interfaces:**
- Consumes: the `TokenUsage` and `SessionCost` shapes from Tasks 1–3
- Produces: no new public API; UI only

- [ ] **Step 1: Update the aggregate line to name every model**

In `AgentSessionsCard`, replace the usage total so it names the models when there is
more than one, because a single summed token count is what hid the escalation:

```swift
    /// Tokens across the card, naming the models when there is more than one. A bare
    /// sum is what made an escalated session look like a single-model one.
    private var totalTokens: String {
        let segments = sessions.compactMap { session -> [TokenUsageSegment]? in
            guard case .reported(let segments) = session.usage else { return nil }
            return segments
        }.flatMap { $0 }

        let tokens = segments.reduce(0) { $0 + $1.input + $1.output }
        let models = Set(segments.map(\.modelID))
        guard models.count > 1 else { return Fmt.tokens(tokens) }
        return "\(Fmt.tokens(tokens)) tok · \(models.count) models"
    }
```

- [ ] **Step 2: Update `SessionLine.usage`**

```swift
    private var usage: String {
        switch session.usage {
        case .reported(let segments):
            let tokens = segments.reduce(0) { $0 + $1.input + $1.output }
            let models = Set(segments.map(\.modelID))
            // One model prints as it always did. Several print with their split,
            // because a single number cannot say two rates were involved.
            guard models.count > 1 else { return "\(Fmt.tokens(tokens)) tok" }
            let split = segments
                .sorted { $0.modelID < $1.modelID }
                .map { "\($0.modelID) \(Fmt.tokens($0.input + $0.output))" }
                .joined(separator: " · ")
            return "\(Fmt.tokens(tokens)) tok (\(split))"
        case .notReported(let reason):
            // Every reason in one short phrase each, so a row says which rather than
            // showing a dash that reads as zero.
            switch reason {
            case .noSource: return "no source"
            case .logUnreadable: return "log unreadable"
            case .unrecognizedFormat: return "log format unknown"
            case .awaitingFirstReport: return "not reported yet"
            // Two agent logs overlap this session and nothing ties either to it.
            case .ambiguousMatch: return "2 logs match"
            }
        }
    }
```

- [ ] **Step 3: Update `SessionLine.cost`**

```swift
    private var cost: String {
        switch session.cost {
        case .priced(let usd, _, let lines):
            guard lines.count > 1 else { return Fmt.usd(usd) }
            let split = lines
                .map { "\($0.modelID) \(Fmt.usd($0.usd))" }
                .joined(separator: " · ")
            return "\(Fmt.usd(usd)) (\(split))"
        case .notPriced(let models):
            // Name the models: entering one price does not make the total computable
            // while another is still unpriced.
            return models.count == 1 ? "not priced: \(models[0])" : "not priced: \(models.count) models"
        case .conflict(let disagreements):
            guard let only = disagreements.first else { return "conflict" }
            let parts = only.totals
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue) \(Fmt.tokens($0.value))" }
                .joined(separator: " / ")
            return "sources differ (\(parts))"
        case .noUsage:
            return "no usage"
        }
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build`
Expected: `** BUILD SUCCEEDED **` with no warnings.

- [ ] **Step 5: Commit**

```bash
git add App/OverviewView.swift
git commit -m "feat: the sessions card names the models behind a figure

A summed token count is what made an escalated session look like a single-model one,
so a row now prints the split when there is more than one model, and a priced total
prints its per-model lines. An unpriced total names every model missing a price,
because entering one does not make the total computable while another is unpriced.

A conflict prints both totals and which source reported each, rather than the word
'conflict' with nothing to act on."
```

---

### Task 7: Docs and end-to-end verification

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-10-02-mcp-support-design.md` (status only)

- [ ] **Step 1: Correct the README's claim about the adapter**

The README says per-model records "retire the known-unsound case." That was false
until Task 1. Update it to describe segments and the per-model split, and remove the
claim that a self-report can be priced per model — a cumulative report carries the
older model's tokens inside its total, so it cannot be.

- [ ] **Step 2: Run every suite**

```bash
cd Core && swift test
cd .. && xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build
./scripts/mcp-e2e.sh --no-manual \
  "$(xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')" \
  "$(find "$(xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} END{print d}')" -name portmaster-mcp -type f -perm +111 | head -1)"
```

Expected: Core PASS, build clean, e2e summary `17 passed, 0 failed, 1 skipped`.

- [ ] **Step 3: Record the baseline counts**

Run: `cd Core && swift test 2>&1 | grep -E "Executed [0-9]+ tests, with" | tail -2`
Expected: record the two totals and put them in the commit message.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/superpowers/specs/2026-10-02-mcp-support-design.md
git commit -m "docs: segments, and the correction 020f48e needed

The README claimed per-model records retired the known-unsound case. They did not:
the fold collapsed them. It now describes what actually ships, and records the limit
that remains — a single cumulative self-report carries the older model's tokens
inside its total, so it cannot be priced per model."
```

---

## Self-Review

**Spec coverage.** Decisions 1–5 map to Tasks 1–4. Wire and UI map to Tasks 5–6.
Doc corrections to Task 7. Every spec section has a task.

**Type consistency.** `TokenUsageSegment(modelID:input:output:cacheRead:reasoning:provenance:)`
is defined in Task 1 and used unchanged in Tasks 2, 3, 5. `latestPerSegment(_:)`
is Task 1 and used in Task 3. `UsageDisagreement(modelID:totals:)` is Task 2, used
in Tasks 3 and 5. `CostLine(modelID:usd:)` is Task 3, used in Task 5. No name
appears before it is defined.

**Ordering.** Task 2's `hasMaterialDisagreement` takes segments, so Task 1 must
land first. Task 3's `costLocked` consumes Tasks 1–2. Task 4 is independent and
could be done in parallel, but it is sequenced here so the suite is green between
tasks.

**Placeholder scan.** No TBD, no "similar to Task N", no unimplemented steps. Every
code block is complete and compilable as written.

**Known follow-ups, deliberately out of scope.** The adapter is still not wired
into polling; the `notPriced` wire field is still named `models` and could be
renamed once no client depends on the old shape; and the 1% tolerance needs tuning
against real disagreement data once sessions accumulate some.
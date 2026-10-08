// Token usage is a three-state value because an agent that reported nothing must
// never render as an agent that reported zero. These tests pin that distinction
// where it is cheapest to get wrong: the type itself.
import XCTest
@testable import PortmasterCore

final class AgentUsageTests: XCTestCase {

    // MARK: - The distinction that matters

    func testNotReportedIsNeverEqualToReportedZero() {
        let nothing = TokenUsage.notReported(reason: .noSource)
        let zero = TokenUsage.reported(input: 0, output: 0, modelID: "m", provenance: .selfReported)

        XCTAssertNotEqual(nothing, zero)
        XCTAssertFalse(nothing.isReported)
        XCTAssertTrue(zero.isReported)
    }

    // MARK: - Provenance is part of the value

    func testProvenanceIsCarriedNotDropped() {
        let self_ = TokenUsage.reported(input: 10, output: 5, modelID: "m", provenance: .selfReported)
        let parsed = TokenUsage.reported(input: 10, output: 5, modelID: "m", provenance: .parsedFromLog)

        XCTAssertNotEqual(self_, parsed, "identical figures from different sources are different facts")
        guard case .reported(let selfSegments) = self_,
              case .reported(let parsedSegments) = parsed else {
            return XCTFail("expected both to be reported")
        }
        XCTAssertEqual(selfSegments.first?.provenance, .selfReported)
        XCTAssertEqual(parsedSegments.first?.provenance, .parsedFromLog)
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

    /// Agents report totals-so-far, so summing records inflates usage and will not
    /// reconcile with a provider invoice.
    func testAggregationTakesLatestPerSegmentNotTheSum() {
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
        guard case .reported(let segments) = aggregated else {
            return XCTFail("expected reported, got \(aggregated)")
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].input, 300, "cumulative totals must not be summed")
        XCTAssertEqual(segments[0].output, 150)
    }

    func testAggregatingNoRecordsIsNotReportedNotZero() {
        let aggregated = TokenUsage.aggregating([])
        XCTAssertEqual(aggregated, .notReported(reason: .awaitingFirstReport))
    }

    /// Both sources survive the fold, each naming itself. Neither outranks the other
    /// now that a session is a list of segments rather than one chosen figure: there is
    /// nothing to choose between, because each is priced at its own model's rate.
    func testBothProvenancesSurviveTheFold() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 2),
                input: 20, output: 10, cacheRead: nil, reasoning: nil,
                modelID: "model-a", provenance: .selfReported
            ),
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 9),
                input: 99, output: 99, cacheRead: nil, reasoning: nil,
                modelID: "model-b", provenance: .parsedFromLog
            ),
        ]

        guard case .reported(let segments) = TokenUsage.aggregating(records) else {
            return XCTFail("expected segments")
        }
        XCTAssertEqual(Set(segments.map(\.provenance)), [.selfReported, .parsedFromLog])
    }

    func testAggregatingUsesTheLatestReadingOfTheOnlyProvenancePresent() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 1),
                input: 30, output: 15, cacheRead: nil, reasoning: nil,
                modelID: "model-a", provenance: .parsedFromLog
            ),
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 4),
                input: 80, output: 40, cacheRead: nil, reasoning: nil,
                modelID: "model-a", provenance: .parsedFromLog
            ),
        ]

        guard case .reported(let segments) = TokenUsage.aggregating(records),
              let only = segments.first else {
            return XCTFail("expected one segment")
        }
        XCTAssertEqual(only.provenance, .parsedFromLog)
        XCTAssertEqual(only.input, 80, "still latest-per-segment, not a sum")
    }

    /// A self-report escalating two models stays ONE segment, and that is the documented
    /// limitation rather than an oversight. `report_usage` sends one cumulative total for
    /// the session, so the second reading still contains the first one's tokens; keying
    /// the fold per model would count that prefix twice and price 1,000 tokens as 2,000.
    func testASelfReportEscalatingTwoModelsCollapsesToOneSegmentAndThatFigureIsKnownWrong() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(sessionID: sid, recordedAt: Date(timeIntervalSince1970: 1),
                             input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
                             modelID: "model-a", provenance: .selfReported),
            TokenUsageRecord(sessionID: sid, recordedAt: Date(timeIntervalSince1970: 5),
                             input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
                             modelID: "model-b", provenance: .selfReported),
        ]
        let folded = TokenUsage.latestPerSegment(records)
        XCTAssertEqual(folded.count, 1)
        XCTAssertEqual(folded.first?.modelID, "model-b", "the newest cumulative total wins")
    }

    /// The other side of the same distinction, and the reason the fold keys per model at
    /// all: a log parse's figures are disjoint, so an escalated session keeps both models'
    /// tokens instead of collapsing onto whichever came last.
    func testAParsedEscalationKeepsBothModels() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(sessionID: sid, recordedAt: Date(timeIntervalSince1970: 1),
                             input: 1_000, output: 0, cacheRead: nil, reasoning: nil,
                             modelID: "model-a", provenance: .parsedFromLog),
            TokenUsageRecord(sessionID: sid, recordedAt: Date(timeIntervalSince1970: 5),
                             input: 2_000, output: 0, cacheRead: nil, reasoning: nil,
                             modelID: "model-b", provenance: .parsedFromLog),
        ]
        XCTAssertEqual(TokenUsage.latestPerSegment(records).count, 2)
    }

    // MARK: - Choosing a provenance

    /// The disagreement rule's other half. Below the tolerance the sources agree, and
    /// agreeing readings of one model are still two segments — so one has to be dropped,
    /// or the model is billed twice. The self-report wins, as it did before segments.
    func testPreferredProvenanceKeepsTheSelfReportWhereBothReportOneModel() {
        let segments = [
            TokenUsageSegment(modelID: "m", input: 1_000, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .selfReported),
            TokenUsageSegment(modelID: "m", input: 1_005, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
        ]
        let chosen = TokenUsage.preferredProvenance(segments)
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen.first?.provenance, .selfReported)
        XCTAssertEqual(chosen.first?.input, 1_000, "the self-report's figure, not the parse's")
    }

    /// Ordering must not decide the winner. Segments arrive provenance-then-model, which
    /// happens to put the self-report first today; a rule that depended on that would
    /// reverse silently.
    func testPreferredProvenancePrefersTheSelfReportWhicheverOrderItArrivesIn() {
        let selfReport = TokenUsageSegment(
            modelID: "m", input: 1_000, output: 0,
            cacheRead: nil, reasoning: nil, provenance: .selfReported
        )
        let parsed = TokenUsageSegment(
            modelID: "m", input: 1_005, output: 0,
            cacheRead: nil, reasoning: nil, provenance: .parsedFromLog
        )
        for order in [[selfReport, parsed], [parsed, selfReport]] {
            XCTAssertEqual(
                TokenUsage.preferredProvenance(order).first?.provenance, .selfReported
            )
        }
    }

    /// Different models are different work, so nothing is dropped: each is billed at its
    /// own rate and both lines survive.
    func testPreferredProvenanceKeepsEveryModel() {
        let segments = [
            TokenUsageSegment(modelID: "model-a", input: 100, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .selfReported),
            TokenUsageSegment(modelID: "model-b", input: 900, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
        ]
        XCTAssertEqual(TokenUsage.preferredProvenance(segments), segments)
    }

    /// A model only one source saw comes through untouched — absence of a self-report is
    /// not a reason to invent one, and dropping it would lose the model's tokens.
    func testPreferredProvenanceLeavesAModelOnlyOneSourceReported() {
        let segments = [
            TokenUsageSegment(modelID: "model-a", input: 100, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .selfReported),
            TokenUsageSegment(modelID: "model-b", input: 900, output: 0,
                              cacheRead: nil, reasoning: nil, provenance: .parsedFromLog),
        ]
        let chosen = TokenUsage.preferredProvenance(segments)
        XCTAssertEqual(chosen.count, 2)
        XCTAssertEqual(Set(chosen.map(\.provenance)), [.selfReported, .parsedFromLog])
    }

    // MARK: - Disagreement

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

    // MARK: - The one resolution both surfaces run

    /// `believableSegments` replaced a rule written out twice — once by the MCP wire and
    /// once by the Overview card — and those tests exist because the rule is now the only
    /// place either surface can get it. They pin **both** former shapes at once: the wire
    /// needs a contested model listed with nothing to print, and the card needs it out of
    /// the sum while still naming it. A function that agreed with only one of them fails
    /// here.

    private func segment(
        _ model: String, _ input: Int, _ output: Int,
        cacheRead: Int? = nil, reasoning: Int? = nil,
        _ provenance: TokenProvenance
    ) -> TokenUsageSegment {
        TokenUsageSegment(
            modelID: model, input: input, output: output,
            cacheRead: cacheRead, reasoning: reasoning, provenance: provenance
        )
    }

    private func conflict(_ modelIDs: [String]) -> SessionCost {
        .conflict(disagreements: modelIDs.map {
            UsageDisagreement(
                modelID: $0, totals: [.selfReported: 1_000, .parsedFromLog: 1_200]
            )
        })
    }

    /// Nothing to contest: every model survives, one reading each. This is the case where
    /// the two readers agreed, and it is the one the wire and the card are both reducing.
    func testBelievableSegmentsKeepsEveryModelWhenNoSourceDisagrees() {
        let usage = TokenUsage.reported([
            segment("m", 1_000, 0, .selfReported),
            segment("m", 1_005, 0, .parsedFromLog),
            segment("other", 400, 50, .parsedFromLog),
        ])
        let resolved = usage.believableSegments(
            cost: .priced(usd: Decimal(1), priceTableVersion: 1, lines: [])
        )
        XCTAssertTrue(resolved.contestedModels.isEmpty)
        XCTAssertEqual(
            resolved.countable.map(\.modelID), ["m", "other"],
            "one segment per model, from the source to believe"
        )
        XCTAssertEqual(resolved.countable.first?.input, 1_000, "the self-report wins, as priced")
        XCTAssertTrue(resolved.hasCountableFigure)
    }

    /// A contested model is **listed but unnumbered**, which is what the wire emits and
    /// what the card filters down to. Asserted in both directions because the two former
    /// copies differed here and nothing else separated them.
    func testAContestedModelIsListedButNeverCountable() {
        let usage = TokenUsage.reported([
            segment("m", 1_000, 0, .selfReported),
            segment("m", 1_200, 0, .parsedFromLog),
        ])
        let resolved = usage.believableSegments(cost: conflict(["m"]))
        XCTAssertEqual(resolved.segments.map(\.modelID), ["m"], "the wire still lists the model")
        XCTAssertEqual(resolved.contestedModels, ["m"])
        XCTAssertTrue(resolved.countable.isEmpty, "the card prints no number for it")
        XCTAssertFalse(resolved.hasCountableFigure, "so the card must not print a zero")
    }

    /// Several models disagreeing is the ordinary multi-model shape of the same rule, and
    /// the case where a "first one only" reading would silently drop the rest.
    func testEveryDisagreeingModelIsContestedNotJustTheFirst() {
        let usage = TokenUsage.reported([
            segment("model-a", 1_000, 0, .selfReported),
            segment("model-a", 1_200, 0, .parsedFromLog),
            segment("model-b", 500, 0, .selfReported),
            segment("model-b", 900, 0, .parsedFromLog),
        ])
        let resolved = usage.believableSegments(cost: conflict(["model-a", "model-b"]))
        XCTAssertEqual(resolved.contestedModels, ["model-a", "model-b"])
        XCTAssertTrue(resolved.countable.isEmpty)
        XCTAssertFalse(resolved.hasCountableFigure)
    }

    /// Mixed: a clean model stays printable beside a contested one. Preference runs before
    /// the contest filter — if it ran after, both readings of the contested model would
    /// reach the sum and the clean model's count would not be the only one there.
    func testAContestedModelDoesNotDisplaceTheCleanModelBesideIt() {
        let usage = TokenUsage.reported([
            segment("model-a", 400, 0, .parsedFromLog),
            segment("model-b", 1_000, 0, .selfReported),
            segment("model-b", 1_200, 0, .parsedFromLog),
        ])
        let resolved = usage.believableSegments(cost: conflict(["model-b"]))
        XCTAssertEqual(resolved.countable.map(\.modelID), ["model-a"])
        XCTAssertEqual(resolved.countable.first?.input, 400)
        XCTAssertTrue(resolved.hasCountableFigure)
    }

    /// A cost case that is not a conflict must not contest anything, however its figures
    /// compare: an unpriced model was counted, just not priced.
    func testOnlyAConflictContestsAModel() {
        let usage = TokenUsage.reported([segment("m", 1_000, 0, .selfReported)])
        for cost in [
            SessionCost.priced(usd: Decimal(1), priceTableVersion: 1, lines: []),
            .notPriced(models: ["m"]),
            .noUsage,
        ] {
            let resolved = usage.believableSegments(cost: cost)
            XCTAssertTrue(resolved.contestedModels.isEmpty, "\(cost) is not a disagreement")
            XCTAssertTrue(resolved.hasCountableFigure)
        }
    }

    /// Nothing reported means no segments to believe, and `hasCountableFigure` false is
    /// what stops a display reaching for a zero.
    func testUnreportedUsageResolvesToNoSegmentsAtAll() {
        let resolved = TokenUsage.notReported(reason: .awaitingFirstReport)
            .believableSegments(cost: .noUsage)
        XCTAssertTrue(resolved.segments.isEmpty)
        XCTAssertTrue(resolved.contestedModels.isEmpty)
        XCTAssertFalse(resolved.hasCountableFigure)
    }

    /// The priced total and the token total cover the same work: cache reads and
    /// reasoning are priced separately, so a display that totals input and output alone
    /// describes less than the money beside it. A session whose tokens are all cache reads
    /// is the case that shows it — zero input and output, real spend.
    func testCacheReadsAndReasoningCountTowardTheFigureCostBills() {
        let cacheOnly = segment("m", 0, 0, cacheRead: 50_000, reasoning: nil, .parsedFromLog)
        XCTAssertEqual(cacheOnly.comparableTotal, 0, "what the disagreement rule compares")
        XCTAssertEqual(cacheOnly.billableTotal, 50_000, "what the display must total")

        let all = segment("m", 10, 20, cacheRead: 30, reasoning: 40, .parsedFromLog)
        XCTAssertEqual(all.billableTotal, 100)
    }

    /// An absent component is not a zero, and it contributes nothing — so the total is
    /// what was reported, never more than the wire carries.
    func testAnAbsentComponentContributesNothingToThePricedTotal() {
        let usage = TokenUsage.reported([
            segment("m", 10, 20, cacheRead: 30, reasoning: nil, .parsedFromLog)
        ])
        let resolved = usage.believableSegments(
            cost: .priced(usd: Decimal(1), priceTableVersion: 1, lines: [])
        )
        XCTAssertEqual(resolved.countable.first?.billableTotal, 60)
    }

    // MARK: - Cost

    func testNotPricedIsNeverEqualToPricedZero() {
        let unpriced = SessionCost.notPriced(models: ["unknown-model"])
        let free = SessionCost.priced(usd: Decimal(0), priceTableVersion: 1, lines: [])

        XCTAssertNotEqual(unpriced, free, "an unknown price is not a free model")
        XCTAssertNil(unpriced.usd)
        XCTAssertNotNil(free.usd)
    }

    func testNoUsageCostsNothingRatherThanZero() {
        let cost = SessionCost.noUsage
        XCTAssertNil(cost.usd)
        XCTAssertNotEqual(cost, .priced(usd: Decimal(0), priceTableVersion: 1, lines: []))
    }
}

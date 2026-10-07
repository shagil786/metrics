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

    /// An agent's own count is authoritative; a log parse is a reconstruction. The
    /// winner must be *named*, or the reader cannot tell which number they are
    /// looking at — and this is the rule that makes `hasModelConflict` load-bearing.
    func testAggregatingPrefersSelfReportedWhenBothProvenancesExist() {
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

        XCTAssertEqual(
            TokenUsage.aggregating(records).provenance, .selfReported,
            "a newer log parse must not outrank the agent's own count"
        )
    }

    func testAggregatingUsesParsedFromLogWhenNoSelfReportExists() {
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

        let aggregated = TokenUsage.aggregating(records)
        XCTAssertEqual(aggregated.provenance, .parsedFromLog)
        XCTAssertEqual(aggregated.value?.input, 80, "still latest-per-provenance, not a sum")
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

    /// An agent escalating mid-session is normal, not a conflict. Only the
    /// currently-effective figure per source counts: the superseded model is
    /// history, and treating it as a live disagreement would block a cost that
    /// has no actual ambiguity in it.
    func testModelSwitchWithinOneProvenanceIsNotAConflict() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 1),
                input: 20, output: 10, cacheRead: nil, reasoning: nil,
                modelID: "model-a", provenance: .selfReported
            ),
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 5),
                input: 60, output: 30, cacheRead: nil, reasoning: nil,
                modelID: "model-b", provenance: .selfReported
            ),
        ]

        XCTAssertFalse(
            TokenUsage.hasModelConflict(records),
            "one source escalating models is a fact about the session, not two sources disagreeing"
        )
    }

    /// The counterpart: two *different* sources naming different models is the real
    /// conflict the check exists for, and must survive the scoping fix above.
    func testModelDisagreementAcrossProvenancesIsStillAConflict() {
        let sid = UUID()
        let records = [
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 5),
                input: 60, output: 30, cacheRead: nil, reasoning: nil,
                modelID: "model-a", provenance: .selfReported
            ),
            TokenUsageRecord(
                id: UUID(), sessionID: sid, recordedAt: Date(timeIntervalSince1970: 5),
                input: 60, output: 30, cacheRead: nil, reasoning: nil,
                modelID: "model-b", provenance: .parsedFromLog
            ),
        ]

        XCTAssertTrue(TokenUsage.hasModelConflict(records))
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

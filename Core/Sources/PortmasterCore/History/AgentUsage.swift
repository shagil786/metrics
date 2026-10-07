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
/// is an aggregate of them, never a stored total. This assumes an agent's counters
/// only ever accumulate — a session that reset its own total mid-flight would drop
/// the earlier spend here, so a reset needs its own representation, not a
/// compensating record.
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
        // Empty in, empty out: no records means no provenance won, which the guard
        // below reports as `awaitingFirstReport` rather than a zero.
        let latest = latestPerProvenance(records)
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
            // `>=` means equal timestamps keep the earlier element: reports sharing a
            // timestamp are one instant described twice, and array order is the only
            // tie-break available without a sequence number to arbitrate.
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
    ///
    /// Scoped to the latest record per provenance, matching "sources disagree". What
    /// that scoping does *not* do is make an intra-provenance model change safe.
    /// Reports are cumulative, so a session that escalated `model-a` → `model-b` still
    /// carries `model-a`'s tokens in its newest total, and costing prices every token
    /// at `model-b`'s rate. That figure cannot be reconciled with an invoice. Fixing it
    /// means recording usage as per-model segments rather than one figure per session,
    /// which is a data-model change for a later phase; the behaviour here is unchanged
    /// and the limitation is recorded in the README rather than hidden behind a claim
    /// that the case cannot arise.
    public static func hasModelConflict(_ records: [TokenUsageRecord]) -> Bool {
        let models = Set(latestPerProvenance(records).values.map(\.modelID))
        return models.count > 1
    }
}

/// What a session's usage costs. A cost is computed on read rather than stored, so
/// a price change re-costs history instead of leaving stale figures behind.
public enum SessionCost: Hashable, Sendable {
    case priced(usd: Decimal, priceTableVersion: Int)
    /// The model has no entry in the price table. An unknown price, not a free one.
    case notPriced(modelID: String)
    /// Sources disagree about which model ran, so there is no figure to price. Kept
    /// apart from `notPriced` because it is a different fact with a different repair:
    /// both models here may be priced perfectly well, so "enter a price" would do
    /// nothing, and reporting a missing price for a model that has one is a claim the
    /// user can disprove.
    case conflict(models: [String])
    /// Nothing to price yet.
    case noUsage

    public var usd: Decimal? {
        switch self {
        case .priced(let usd, _): return usd
        // Every other case is absence of a figure, never a figure of zero.
        case .notPriced, .conflict, .noUsage: return nil
        }
    }
}

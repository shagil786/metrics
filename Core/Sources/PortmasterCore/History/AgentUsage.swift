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
    /// More than one candidate log could belong to this session, and nothing ties
    /// them to it. A distinct case rather than a silent pick: two agents running side
    /// by side both overlap one session's window, and choosing between them would
    /// file each one's tokens against the other session — a wrong number, which is
    /// worse than no number.
    case ambiguousMatch
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

extension TokenUsageRecord {
    /// The key this record folds under, which is not the same key for both sources.
    ///
    /// `parsedFromLog` keys on its model: the adapter reads one figure per model out of
    /// the log, and each is that model's own count, so two models are two disjoint
    /// pieces of work and keeping both is what stops a fold from losing one.
    ///
    /// `selfReported` keys on nothing but its provenance: `report_usage` sends one
    /// cumulative total for the whole session stamped with whichever model was in
    /// force, so two self-reports on different models are two *prefixes* of that total.
    /// Keying them apart would count the earlier prefix twice, which is the unsound
    /// escalation figure the README documents and segments deliberately do not claim
    /// to fix.
    var foldKey: String {
        switch provenance {
        case .selfReported: return ""
        case .parsedFromLog: return modelID
        }
    }
}

/// One model's share of a session's usage, with the source that reported it.
///
/// **A list of these, not a single value, because one session can run two models.**
/// The type that preceded it carried `(input, output, provenance)` with no model at
/// all, so a fold keyed on provenance had to collapse an escalated session onto one
/// model — and it collapsed silently, discarding the other's tokens with no trace.
/// A source that reports per model now yields one segment per model; a self-report
/// cannot, because it sends one cumulative total, and `foldKey` says which is which.
public struct TokenUsageSegment: Hashable, Sendable {
    public let modelID: String
    public let input: Int
    public let output: Int
    /// Priced separately from input/output, and nil when the source omits them —
    /// summing them into `input` produces a cost no provider invoice will reconcile.
    public let cacheRead: Int?
    public let reasoning: Int?
    /// Part of the segment, not a property of the session: the same model reported by
    /// two sources is two segments, which is what lets the two be compared. Two
    /// segments that *are* the same work are not priced as two — `preferredProvenance`
    /// picks one before anything is costed.
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

/// A session's token usage: one segment per model a source reported separately — or
/// one for a cumulative self-report — or a reason there is none.
public enum TokenUsage: Hashable, Sendable {
    /// **Never empty.** A figure with no segments is not a figure, and
    /// `isReported` is `true` for this case whatever the array holds — so an empty
    /// array would read as "reported, and nothing was used", which is the one shape
    /// the three-state type exists to rule out. `aggregating` is the constructor that
    /// guarantees it, turning no records into `.notReported(.awaitingFirstReport)`;
    /// anything hand-building this case owes the same check, because a payload built
    /// from an empty `.reported` emits `reported: true` with zero counts.
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

    /// Whether a figure exists. A measured zero is `true`; "we cannot tell" is
    /// `false`. Conflating them is the whole bug this type prevents.
    public var isReported: Bool {
        if case .reported = self { return true }
        return false
    }

    /// Folds a session's records into its segments.
    ///
    /// Latest-per-segment, not a sum: agents report cumulative totals, so summing
    /// three reports of the same session counts the first two twice.
    public static func aggregating(_ records: [TokenUsageRecord]) -> TokenUsage {
        // Empty in, empty out: no records means no segment won, which the guard
        // reports as `awaitingFirstReport` rather than a zero.
        let segments = segments(from: records)
        guard !segments.isEmpty else {
            return .notReported(reason: .awaitingFirstReport)
        }
        return .reported(segments)
    }

    /// The fold's records read as segments.
    ///
    /// Written once because two callers need it and the store's costing path has to
    /// agree with this one exactly: the sessions list prices a session from a batched
    /// read, and a single-session read prices the same session from its own read. If
    /// each spelled out its own mapping, the two could drift and the same session
    /// would cost two different amounts depending on which API asked.
    public static func segments(from records: [TokenUsageRecord]) -> [TokenUsageSegment] {
        latestPerSegment(records).map { record in
            TokenUsageSegment(
                modelID: record.modelID, input: record.input, output: record.output,
                cacheRead: record.cacheRead, reasoning: record.reasoning,
                provenance: record.provenance
            )
        }
    }

    /// The latest reading for each fold key.
    ///
    /// **The key is `(provenance, modelID)` only where a source reports per model.**
    /// Keying on provenance alone made an escalated session's two models compete for
    /// one slot, and because the runner stamps every segment of one observation with
    /// the same instant, the tie-break below picked the earlier one and the later
    /// model's tokens were discarded — 67% of that session's output, gone with no
    /// trace. Keying on the model as well is what stops it, and it is safe for a
    /// `parsedFromLog` record precisely because the adapter's figures are disjoint:
    /// one per model, each that model's own count.
    ///
    /// **A `selfReported` record keys on its provenance alone**, because `report_usage`
    /// sends one cumulative total for the whole session stamped with whichever model
    /// was in force. Two self-reports on different models are two *prefixes* of that
    /// one total, so treating them as two segments would count the earlier prefix's
    /// tokens a second time. That double count is not a corner case — it is the
    /// known-unsound escalation figure this change does not claim to fix, and it is
    /// why the self-report path keeps a documented limitation instead of a per-model
    /// split. Only a source able to break usage down per model is recorded faithfully.
    ///
    /// Ordered by provenance then key so two runs over the same records produce the
    /// same array — the fold's output reaches a UI list, and an unstable order makes
    /// a diff of two reads look like a change when nothing moved.
    static func latestPerSegment(_ records: [TokenUsageRecord]) -> [TokenUsageRecord] {
        var latest: [TokenProvenance: [String: TokenUsageRecord]] = [:]
        for record in records {
            var byModel = latest[record.provenance] ?? [:]
            // `>=` keeps the earlier element: two reports sharing a timestamp are one
            // instant described twice, and array order is the only tie-break available
            // without a sequence number to arbitrate.
            if let existing = byModel[record.foldKey],
               existing.recordedAt >= record.recordedAt {
                continue
            }
            byModel[record.foldKey] = record
            latest[record.provenance] = byModel
        }
        return latest
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { entry in
                entry.value.sorted { $0.key < $1.key }.map(\.value)
            }
    }

    /// One segment per model, from the source to believe when both report one.
    ///
    /// **The other half of the disagreement rule.** `hasMaterialDisagreement` returns
    /// nothing below the tolerance, which means the sources agree — and agreeing
    /// readings of one piece of work are still two segments, because they are keyed on
    /// their provenance. Pricing both is not a rounding difference: a self-report of
    /// 1,000 tokens against a log parse of the same 1,000 costs as 2,000, and the
    /// invoice carries one line. So a model is priced once, from `selfReported` where
    /// it exists, which is the same precedence the pre-segment fold used.
    ///
    /// Input must come from the fold, which guarantees at most one segment per
    /// `(model, provenance)`; a caller passing two would get both priced.
    public static func preferredProvenance(
        _ segments: [TokenUsageSegment]
    ) -> [TokenUsageSegment] {
        var preferred: [String: TokenProvenance] = [:]
        for segment in segments {
            let incumbent = preferred[segment.modelID]
            // Ranked rather than "first seen wins": the fold's order is fixed by
            // provenance's raw value and by the fold key, not by which source should be
            // believed, so reading precedence off arrival would invert the rule the day
            // that ordering changed — and `"parsedFromLog" < "selfReported"`, so parsed
            // segments do arrive first.
            if incumbent == nil || (incumbent == .parsedFromLog && segment.provenance == .selfReported) {
                preferred[segment.modelID] = segment.provenance
            }
        }
        return segments.filter { preferred[$0.modelID] == $0.provenance }
    }

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
            let values = totals.values.map { Decimal($0) }
            guard let largest = values.max(), largest > 0 else { continue }
            let smallest = values.min() ?? 0
            let relativeDifference = (largest - smallest) / largest
            if relativeDifference > tolerance {
                found.append(UsageDisagreement(modelID: modelID, totals: totals))
            }
        }
        return found
    }
}

/// What a session's usage costs. A cost is computed on read rather than stored, so
/// a price change re-costs history instead of leaving stale figures behind.
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

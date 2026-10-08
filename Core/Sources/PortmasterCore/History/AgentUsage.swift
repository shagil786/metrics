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
    /// A later pass decided this session's log is **no longer attributable to it**, and
    /// recorded that so a figure already written stops counting.
    ///
    /// **Carries no counts.** A conversation's interval only grows while it runs, so a
    /// session uniquely matched at one pass can become unattributable at the next: a
    /// second MCP connection opens inside the same conversation, and the one-to-one rule
    /// turns a clean match into a refusal for both. Without this record the store kept
    /// showing a priced figure for a session the current rule refuses — the
    /// confidently-wrong-dollar direction, reached *by* the rule that was supposed to
    /// prevent it, and reached silently because the pass that knew better was discarded.
    ///
    /// The zero counts are not a claim of zero: a withdrawal is filtered out before any
    /// display or cost ever sees it. Storing a zero would have been the cheaper-looking
    /// option and is exactly the conflation this module exists to refuse.
    case parseWithdrawn
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
    ///
    /// `parseWithdrawn` keys on nothing but its provenance, and that is the whole of what
    /// it must do: a withdrawal is about the *session's* parse as a whole, not about any
    /// one model, so it occupies one slot of its own rather than competing with a model
    /// id. No `parsedFromLog` record can land in that slot — its provenance differs —
    /// so a withdrawal can never shadow a reading, which is what keeps this additive and
    /// free of a schema change.
    var foldKey: String {
        switch provenance {
        case .selfReported, .parseWithdrawn: return ""
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

    /// Every token the costing pass prices: input plus output plus cache reads plus
    /// reasoning.
    ///
    /// **The figure a display must total to describe the same work its money does**, and
    /// the four components are what `costLocked` multiplies. A token figure built on
    /// `comparableTotal` instead describes less than the dollar figure beside it, and the
    /// gap is largest exactly where it is most visible: a session whose tokens are all
    /// cache reads totals zero and prints `0 tok` next to a real price.
    public var billableTotal: Int {
        input + output + (cacheRead ?? 0) + (reasoning ?? 0)
    }
}

/// The segments of a session whose counts a reader may believe, and the models it may not.
///
/// **One rule, because two surfaces ask it.** The MCP wire answers with segments and the
/// Overview card answers with a line of text, and each used to resolve this for itself.
/// They agreed, and nothing held them there: the answer is contested-first,
/// preferred-source-second, and either half written twice is one more place for them to
/// part company.
///
/// A contested model is **present and unnumbered** rather than dropped. That is the whole
/// difference between this and a filter: the model was counted, so removing it says the
/// session spent nothing where what is missing is a reason to believe either reading.
public struct BelievableSegments: Hashable, Sendable {
    /// One segment per model, from the source to believe. A contested model's segment is
    /// here too — nothing is printed from it, and the models in `contestedModels` are the
    /// only ones whose counts are withheld, so a caller enumerating models wants it listed.
    public let segments: [TokenUsageSegment]
    /// Models two sources counted too differently to choose between. Read from the cost,
    /// not recomputed: the costing pass has already applied the tolerance, and a second
    /// disagreement rule here would be a third answer to that question.
    public let contestedModels: Set<String>

    /// The segments whose counts may be printed: `segments` minus the contested models.
    public var countable: [TokenUsageSegment] {
        segments.filter { !contestedModels.contains($0.modelID) }
    }

    /// Whether any model's count survives to be printed. **A contested model is not one
    /// of them**: a session whose models are all contested has no figure to print, and must
    /// not print a zero.
    public var hasCountableFigure: Bool { !countable.isEmpty }

    public init(segments: [TokenUsageSegment], contestedModels: Set<String>) {
        self.segments = segments
        self.contestedModels = contestedModels
    }
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
    ///
    /// **Kept with no production reader.** The card and the wire both switch on the two
    /// cases, so nothing calls this — but it is the one expression of the distinction this
    /// type exists for that can be asserted directly, and the test that asserts it would
    /// otherwise have to restate the switch the accessor exists to replace.
    public var isReported: Bool {
        if case .reported = self { return true }
        return false
    }

    /// Folds a session's records into its segments.
    ///
    /// Latest-per-segment, not a sum: agents report cumulative totals, so summing
    /// three reports of the same session counts the first two twice.
    public static func aggregating(_ records: [TokenUsageRecord]) -> TokenUsage {
        let live = liveRecords(records)
        // Empty in, empty out: no records means no segment won, which the guard
        // reports as `awaitingFirstReport` rather than a zero.
        guard !live.isEmpty else {
            // **Records exist but none survived** — every reading a withdrawal has
            // superseded. That is not "nothing has reported": something did, and a later
            // pass said it cannot be attributed. Reporting it as `awaitingFirstReport`
            // would tell the user to wait for a report that has already arrived and been
            // withdrawn, which is advice that cannot help.
            return records.contains { $0.provenance == .parseWithdrawn }
                ? .notReported(reason: .ambiguousMatch)
                : .notReported(reason: .awaitingFirstReport)
        }
        return .reported(segments(from: live))
    }

    /// The records the fold keeps, with any reading a withdrawal has superseded dropped.
    ///
    /// **The single place a withdrawal is applied**, because the sessions list and a
    /// single-session read both read records and both price them: a rule written twice
    /// here is the same defect segments fixed, where two surfaces answered the same
    /// question separately and held in agreement by nothing.
    static func liveRecords(_ records: [TokenUsageRecord]) -> [TokenUsageRecord] {
        let folded = latestPerSegment(records)
        guard let withdrawal = folded.first(where: { $0.provenance == .parseWithdrawn }) else {
            return folded
        }
        // **`<=`, so a withdrawal wins a timestamp tie.** The fold breaks equal
        // timestamps by keeping the earlier element; here the absence and the reading
        // describe the same instant, and between "a figure we once believed" and "we no
        // longer can" the absence is the safer answer. This is a deliberate exception to
        // that convention and it is the only one.
        // **Dropped, never passed through.** A withdrawal is evidence about a reading, not
        // a reading: kept in the live set it would become a segment of its own — a model
        // named `""` reporting zero — which is the conflation this type exists to refuse.
        //
        // And it touches **only the parse**. A self-report is a different source with its
        // own evidence, and losing the log's claim on a conversation says nothing about
        // what an agent reported about its own usage. Dropping both would turn "we can no
        // longer attribute the log" into "the session reported nothing", which is a
        // different and much stronger claim.
        return folded.filter { record in
            guard record.provenance != .parseWithdrawn else { return false }
            guard record.provenance == .parsedFromLog else { return true }
            return record.recordedAt > withdrawal.recordedAt
        }
    }

    /// The fold's records read as segments.
    ///
    /// Written once because two callers need it and the store's costing path has to
    /// agree with this one exactly: the sessions list prices a session from a batched
    /// read, and a single-session read prices the same session from its own read. If
    /// each spelled out its own mapping, the two could drift and the same session
    /// would cost two different amounts depending on which API asked.
    public static func segments(from records: [TokenUsageRecord]) -> [TokenUsageSegment] {
        liveRecords(records).map { record in
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

    /// Resolves a session's usage against its cost into the segments a reader may print.
    ///
    /// The disagreement comes from the cost rather than from a disagreement rule run here,
    /// so the wire and the card cannot each reach their own verdict about which models two
    /// readers could not agree on.
    ///
    /// Order matters, and the contested set is consulted first only because it is the
    /// cheaper fact. Source preference is applied to *every* segment, contested ones
    /// included: a contested model's counts are withheld either way, so choosing between
    /// its two readings here would be precisely the arbitrary choice the segment refuses to
    /// make. Preference also still has to run before the contest filter, or a self-report
    /// and a parse of a contested model would both survive it as countable segments.
    public func believableSegments(cost: SessionCost) -> BelievableSegments {
        guard case .reported(let segments) = self else {
            return BelievableSegments(segments: [], contestedModels: [])
        }
        let contested: Set<String>
        if case .conflict(let disagreements) = cost {
            contested = Set(disagreements.map(\.modelID))
        } else {
            contested = []
        }
        return BelievableSegments(
            segments: TokenUsage.preferredProvenance(segments), contestedModels: contested
        )
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

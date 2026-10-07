# Per-model token segments — Design

Date: 2026-10-08
Status: Approved design, pending spec review
Path: Architectural
Supersedes nothing. Refines the data-model note in
`2026-10-07-agent-sessions-cost-design.md` and fixes a defect that commit
`020f48e` claimed to retire.

## Goal

Make a session's token usage represent **every model that ran**, priced at each
model's own rate, and make retention sweeps incapable of changing a figure.

## The defect this fixes

`020f48e` made `TokenSourceAdapter.parse` return `[RawAgentUsage]` — one entry
per model — and the commit message stated this "retires the known-unsound case"
where a session that escalated `model-a` → `model-b` is priced entirely at the
newest model's rate.

**That claim is false.** `TokenUsage.reported(input:output:provenance:)` has no
model field, so the type cannot represent two models and the fold must collapse
them. `latestPerProvenance` keys on provenance alone, and the runner stamps every
segment with one instant, so the earlier model wins.

Measured, on two records holding 300in + 125out across `model-a` and `model-b`:

    latestPerProvenance -> ["parsedFromLog/model-a"]
    aggregating         -> 100in + 50out

Model-b's 200in + 75out is discarded. That is 67% of the session's output tokens,
gone with no trace — worse than the defect it claimed to fix, which at least
reported the right token count at the wrong price.

The per-model records are stored correctly. The fold throws them away.

## Why now

Wiring the adapter into polling makes two provenances reachable on one session:
`selfReported` and `parsedFromLog`. That activates a second, already-documented
defect in `AgentSessionStore.prune` (`AgentSessionStore.swift:434`):

> No adapter ships and nothing calls `TokenSourceRunner` in the app, so no
> two-provenance session exists to be trimmed today; that is a reason it has no
> test-driven need to be clever, not a reason to promise it cannot happen.

Wiring the adapter makes that sentence false. The trim at
`AgentSessionStore.swift:475` deletes by session and timestamp, not by provenance,
so a sweep can delete the only self-report of a session and move the aggregate
from `conflict` to a clean priced figure for whichever model survived —
choosing between two disagreeing sources without saying so.
`testPruneTrimmingCanResolveATwoProvenanceConflictIntoAPrice` pins that today.

So the two defects are related but **not** the same fix. The fold loses models
within a provenance; the trim can drop a whole provenance. They need separate
changes, and wiring the adapter needs both — which is why the data model comes
first rather than the wiring.

## No migration

`TokenUsageRecordRow` already stores `sessionID`, `recordedAt`, `modelID`,
`provenanceRaw` and the token counts — the segmented data is **already on disk**.
Only the in-memory fold and `TokenUsage` change. Stored sessions need no
rewrite, and no schema migration ships with this.

## Decisions

### 1. `TokenUsage` carries segments

```swift
public struct TokenUsageSegment: Hashable, Sendable {
    public let modelID: String
    public let input: Int
    public let output: Int
    public let cacheRead: Int?
    public let reasoning: Int?
    public let provenance: TokenProvenance
}

public enum TokenUsage: Hashable, Sendable {
    case reported([TokenUsageSegment])
    case notReported(reason: UsageUnavailableReason)
}
```

A single-model convenience constructor keeps `report_usage` and most call sites
unchanged in shape:

```swift
extension TokenUsage {
    public static func reported(
        input: Int, output: Int, modelID: String, provenance: TokenProvenance
    ) -> TokenUsage
}
```

An **empty** `reported([])` is not valid — a session with no models is
`notReported(.awaitingFirstReport)`, which is what the empty guard already
produces.

### 2. The fold keys on `(provenance, modelID)`

`latestPerProvenance` becomes `latestPerSegment`. Two models inside one
provenance no longer overwrite each other, because they are different keys.

The tie-break rule is carried over unchanged: equal `recordedAt` keeps the
earlier element, since array order is the only tie-break available without a
sequence number. That ordering is load-bearing and stays documented as such.

This is the single change that stops models being lost.

### 3. Cost is priced per segment, then summed

Each segment is priced at **its own** model's rate and the results are summed.

- Every segment priced → `.priced(sum, breakdown)` where `breakdown` is one
  entry per model, so a card can show `model-a $x / model-b $y` rather than one
  total that hides the split.
- Any segment unpriced → `.notPriced(models:)`, naming the unpriced models.
  **Never a partial total.** A total missing one model's cost is a wrong number,
  and a partially-correct cost is exactly what this project refuses to print.
- A model priced as a range → `.range(low, high)`, summed across segments.

This also fixes the **self-report** path's escalation case, which is still live:
an agent that escalated models reports one cumulative total, and today it is
priced at the newest model's rate. Segments cannot fix that from a single
cumulative report — a cumulative total carries the old model's tokens inside it.
What segments fix is that the *adapter* path is right, and that any source able
to break usage down per model is recorded faithfully. The self-report path keeps
its documented limitation, which stays in the README rather than being hidden.

### 4. Conflict is repurposed

Conflict's current meaning — "sources disagree about which model ran" — becomes
unrepresentable, because different models are now segments rather than a
conflict. Its remaining job is the disagreement that segments do **not** explain:

> The same model, with totals differing by more than **1%** across provenances.

Self-report says 1,000 tokens; the log parse says 1,200. That is a real signal
that one of the two readers is wrong, and hiding it is the same failure as losing
a model. Cost becomes `.conflict` and the output names **both totals**, so the
disagreement is visible rather than merely present.

Below 1%, self-report wins as today. The tolerance exists because two readers of
the same session can differ trivially, and a strict rule would leave a session
permanently in conflict over a single token. 1% on a token count is noise; 20% is
a broken reader. **The threshold is a judgement call and is expected to be tuned
against real data.**

When both provenances are absent for a model, there is nothing to disagree about.

### 5. Prune deletes only superseded records

The trim must delete a record only when **both** hold:

- a newer record exists for the same `(sessionID, provenance, modelID)`, so the
  segment it belongs to survives, and
- the record falls outside the retention window.

This is the distinction the store's own comment says the trim "cannot tell the
two apart without looking" (`AgentSessionStore.swift:434`). Now it looks.

Effect: trimming is **figure-preserving by construction**. A segment's latest
record is never deleted, so no provenance and no model can disappear from a
session's aggregate as a side effect of retention.

Implementation: one query grouping records by `(sessionID, provenanceRaw,
modelID)` taking `max(recordedAt)`, then delete where
`recordedAt < min(cutoff, thatMax)`. That is the same "one query, not one per
session" discipline the existing prune already follows.

## Data flow

```
TokenUsageRecordRow (unchanged, already per (provenance, model))
        │
        ▼
  latestPerSegment  ── key: (provenance, modelID)
        │
        ▼
  TokenUsage.reported([TokenUsageSegment])
        │
        ├── hasMaterialDisagreement? ──▶ SessionCost.conflict(both totals)
        └── price each segment, sum ──▶ priced(breakdown) / notPriced(models) / range
```

## Error handling

- **Unknown stays unknown.** A segment with no price contributes to
  `notPriced`, never to a sum.
- **Empty is not zero.** `reported([])` cannot be constructed through the
  convenience initialiser's callers; a session whose records all trim away is
  `notReported`, not a zero figure.
- **Adapter refusals are unchanged.** `unrecognizedFormat` and `unreadable`
  still map to `notReported`, and `.ambiguousMatch` still means two candidate
  logs with nothing to tie them to the session.
- **A pruned-away segment is not a disagreement.** Prune no longer changes
  figures, so it cannot manufacture a conflict or resolve one.

## Testing

New tests, all against the fold and the trim:

- Two models in one provenance both survive the fold, and the aggregate reports
  their **sum**. This is the test whose absence let `020f48e` claim a fix it did
  not make; it is written first.
- A self-report and a parse of the **same model** differing by >1% produce
  `.conflict` naming both totals.
- The same pair differing by <1% resolves to self-report, not a conflict.
- Two models escalate within one self-report cumulative total: still one segment,
  still the documented limitation, asserted so it cannot be forgotten.
- **Prune does not change any session's usage or cost**, across a table of
  shapes: one provenance superseded; two provenances, one old; two models in one
  provenance; a segment whose only record is outside the window.
- `testPruneTrimmingCanResolveATwoProvenanceConflictIntoAPrice` is **deleted and
  replaced by its inverse**, with these exact figures so the replacement is not a
  matter of judgement:

  | | before prune | after prune |
  |---|---|---|
  | usage | two segments: `model-a` 100in (self-report), `model-b` 900in (parse) | identical |
  | cost | `0.0001 + 0.0018` = **`0.0019`** | **`0.0019`** |

  Under the old semantics that session was a `conflict` before the sweep and a
  `priced(0.0018)` after it. Under segments, two models are two segments and both
  are priced, so the sweep has nothing left to change — which is the property
  being asserted. The test is green today while asserting the defect; its inverse
  must be written **first**, before the prune change, and must fail.

Every existing test that constructs `.reported(input:output:provenance:)` or
asserts a single-model aggregate is updated to the segment form, so a change in
aggregate shape cannot pass silently against a stale expectation.

## Scope

**In:** the segment type, the fold, per-segment pricing, the repurposed conflict,
the prune fix, `get_agent_sessions` payloads, the sessions card.

**Out:** wiring the adapter into polling (next, and now unblocked);
process attribution; quota and reset tracking; the user-facing CLI.

**Deliberately not attempted:** making a single cumulative self-report
priceable per model. It is information-theoretically impossible — the old
model's tokens are inside the total with no way to separate them — so it stays a
documented limitation rather than a guess.

## Risks

- **Aggregate shape changes everywhere.** `TokenUsage` is public and used by MCP
  payloads and the UI. The blast radius is wide but mechanical.
- **A test asserting the old collapsing behaviour will fail** — correctly. That
  is the point, and it is why the replacement is written first.
- **The 1% tolerance is unvalidated.** It has no real-world data behind it yet;
  it should be revisited once sessions accumulate disagreement in practice.
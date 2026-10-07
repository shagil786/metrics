# Agent Sessions & Cost Attribution — Design

Date: 2026-10-07
Status: Approved design, pending spec review
Path: Architectural

## Goal

Make Portmaster able to say, for one AI agent session: who was it, what did it
call, how many tokens did it use, what did that cost, and which of those numbers
came from a source Portmaster can name.

This is the first slice of a larger product: Portmaster as the local
observability and control plane for a machine that has AI agents on it. Later
slices (out of scope here) make agents *operators* — permissioned, auditable
actions — and make them visible as *subjects* in the UI.

This slice is **data only. No UI.** The reason is that a wrong cost number is
worse than no cost number, and UI makes wrong numbers look finished. If the data
model is wrong, this phase should fail here rather than being shipped with a
chart in front of it.

## Decisions (from brainstorming)

1. **Both token sources, with provenance on every number.** A cooperative
   `report_usage` MCP tool, plus adapters that read known agents' own session
   files. Every recorded figure carries which source produced it.
2. **`report_usage` is not a mutation.** It is an agent declaring a fact about
   itself, not acting on the machine, so it does not go through the confirmation
   broker and does not require `confirmEach`. This is a policy decision, taken
   deliberately: it widens what an assistant can write, but only about itself.
3. **Absence is a value, never a zero.** An agent that reported nothing must
   never render as an agent that reported zero. This is the same rule as
   `ProcessEnergy` and `ThermalAvailability`.
4. **No traffic interception.** HTTPS makes it infeasible and a MITM proxy
   would break certificate pinning. Not attempting it is deliberate.
5. **Prices are user-supplied and versioned.** A cost figure is a claim about a
   price from a particular date, so it records which price table produced it.

## The join

Every later phase depends on one relationship:

```
MCP connection ─→ session ─→ usage (with provenance) ─→ cost (with price version)
                              └→ tool calls (already audit-logged)
```

The connection identity already exists (`MCPConnectedClient`: connection UUID,
peer pid, connected-at, last-tool-call). What is missing is *who the client is*:
the MCP SDK parses `clientInfo` (name, version) and Portmaster currently
discards it. Phase A records it.

## Data model

### Persistence

`AgentSession` is a SwiftData `@Model` in `PortmasterCore/Models/`, alongside
the existing `Preferences` models, in the same store and same migration
discipline: additive only, defaults that reproduce current behaviour, and
existing stores must load unchanged. Sessions are queryable with the rest of
history and inherit its retention behaviour.

Usage figures are **not** a SwiftData field on the session. They arrive
asynchronously — an agent reports at its own pace, and a log adapter may be
reading while the app writes — so they are appended to a separate
`TokenUsageRecord` model and aggregated on read. Storing a mutable
`TokenUsage` enum directly would mean every report rewrites the session row and
concurrent adapters contend for one object.

`PriceTable` is a `@Model` in the same store, version-stamped.

### `AgentSession`

| Field | Notes |
|---|---|
| `id` | the MCP connection UUID; unique per connection, not per process |
| `peerPID` | `LOCAL_PEERPID`; 0 when the kernel will not say |
| `clientName`, `clientVersion` | from `initialize`'s `clientInfo`; nil when absent |
| `connectedAt`, `lastToolCallAt`, `endedAt` | a connection may outlive its process |
| `usageRecords` | not a field: appended `TokenUsageRecord`s, aggregated on read |
| `priceTableVersion` | the table that produced the session's current cost |

One process may back several sessions (two connections, one agent); one session
may outlive its process while the socket stays open. Both are already true of
`MCPConnectedClient` and the model must not contradict them.

### Token honesty

```swift
enum TokenProvenance { case selfReported, parsedFromLog }

enum UsageUnavailableReason {
    case noSource           // no tool, no recognized log
    case logUnreadable
    case unrecognizedFormat // file parsed, shape not understood
    case awaitingFirstReport
}

enum TokenUsage {
    case reported(input: Int, output: Int, provenance: TokenProvenance)
    case notReported(reason: UsageUnavailableReason)
}
```

This is the *aggregate* for a session, produced by folding its
`TokenUsageRecord`s. A single record is one observation:

```swift
struct TokenUsageRecord {
    var id: UUID
    var sessionID: UUID
    var recordedAt: Date
    var input: Int
    var output: Int
    var cacheRead: Int?      // priced separately; nil when the source omits it
    var reasoning: Int?      // ditto
    var modelID: String
    var provenance: TokenProvenance
}
```

An agent reports cumulatively (its own total so far), so aggregation takes the
**latest record per provenance**, not the sum — summing cumulative reports
double-counts, and a provider invoice would not reconcile. Records from
different provenances are combined only when they agree on `modelID`; when they
disagree, the session keeps both and reports the conflict rather than picking
one silently.

`notReported(.unrecognizedFormat)` is the important one: an agent that upgrades
and changes its log layout must degrade to "not reported", **not** to a
plausible-looking wrong number. This is the exact failure the whole three-state
pattern exists to prevent, and it is the one most likely to occur in practice,
because it depends on a third party's file format.

Cached/reasoning tokens are recorded separately from input/output rather than
folded into them, because their pricing differs and summing them makes a cost
figure that cannot be reconciled with a provider invoice.

### `PriceTable`

User-editable, because provider pricing changes on someone else's schedule. Each
entry carries the date it was set.

Cost is **not stored** — it is computed from a session's latest usage records
and the current table, so that a price change re-costs historical sessions
rather than leaving stale figures behind. What is stored alongside a session is
the `priceTableVersion` that produced whatever cost the user last saw, so a
figure can always be traced to the prices behind it. A model with no entry in
the table yields **no cost**, distinct from a cost of zero: an unpriced model is
an unknown price, not a free one.

Cost is its own three-state value, for the same reason `TokenUsage` is:

```swift
enum SessionCost {
    case priced(usd: Decimal, priceTableVersion: Int)
    case notPriced(modelID: String)  // no entry in the table
    case noUsage                     // nothing to price yet
}
```

`Decimal`, not `Double`: money arithmetic in binary floating point cannot
reconcile with a provider invoice, which is the whole reason to show a cost.

## Sources

### 1. `report_usage` MCP tool

The cooperative path. An agent calls it with its own token counts and model id.
Precise when the agent is honest; absent when it is not. Recorded as
`.selfReported`.

Validation is the same allowlist discipline as `set_preference`: non-negative
integers, a known-or-user-added model id, and an explicit `source` string so a
number can be traced to the agent that sent it.

### 2. `TokenSourceAdapter` protocol

```swift
protocol TokenSourceAdapter {
    var identifier: String { get }
    func locateSessionLog(for session: AgentSession) -> URL?
    func parse(_ url: URL) throws -> RawUsage
}
```

One adapter per agent whose logs are read. Isolation matters here: parsing one
agent's private file format must not be able to break another's, and a new
adapter must be addable without touching the record or the query surface.

`locateSessionLog` returns nil when no file matches — a normal state, not an
error, and distinct from a file that exists but cannot be parsed.

Adapter implementations are **not** in this slice. The protocol, the
persistence, and the query surface are, plus one test fixture adapter proving
the contract. Real adapters land with phase C, where their output becomes
visible and their breakage becomes someone's problem.

## What this slice does not build

Stated so the scope is not quietly widened later:

- **No UI.** Sessions are queryable through Core and the MCP surface, not shown
  in the app.
- **No real log adapters.** Fixture only (see above).
- **No budget alerts, no currency conversion, no cost rollups** — phase C.
- **No changes to the permission gate's mode semantics.** `report_usage` is
  deliberately outside the gate; if that turns out to be wrong it is a spec
  amendment, not an implementation detail.
- **No changes to audit logging.** Tool calls are already audited; phase A
  attaches a session to them but does not alter the format.

## Risks

- **HIGH — silently wrong numbers from a third party's log format.** The whole
  design exists to prevent this. Mitigation: `unrecognizedFormat` is a distinct
  state, adapters must throw rather than return a partial parse, and the
  fixture adapter test asserts that garbage input yields `notReported`.
- **HIGH — provenance eroding into a lie.** If a UI later merges self-reported
  and parsed figures into one number, the provenance disappears and the record
  becomes unauditable. Mitigation: provenance is part of the stored type, not a
  field a presentation layer can drop.
- **MEDIUM — `report_usage` as a widening.** An agent can now write to
  Portmaster's store without confirmation. It can only write about itself, and
  only append. Recorded here as an accepted decision, not an oversight.
- **MEDIUM — pricing staleness and model-id drift.** Cost figures outlive the
  prices behind them, and a model id can be renamed upstream. Mitigation: cost
  is computed rather than stored, prices are version-stamped, and a model
  missing from the table yields `notPriced` — never `priced(0)`.
- **MEDIUM — cumulative reports double-counted.** Agents report totals, so a
  naive sum over records inflates usage. Mitigation: aggregation takes the
  latest record per provenance, asserted by a test with three cumulative
  reports for one session.
- **LOW — SwiftData migration.** New model, additive only. Existing stores must
  load unchanged, which is asserted.

## Testing

- Every `TokenUsage` state reachable and distinct, including that
  `.notReported` never equals a reported zero.
- A fixture adapter that returns valid input, garbage input (→
  `unrecognizedFormat`), and a missing file (→ `noSource`).
- Session identity: one pid, two connections → two sessions; process exits,
  socket stays open → session survives with `endedAt` nil.
- `report_usage` validation: negatives, unknown model, absent fields.
- Cost arithmetic against a known price table, in `Decimal`, asserting exact
  equality (not approximate).
- `notPriced` for a model absent from the table, asserted **not** equal to
  `priced(0)`.
- Cumulative aggregation: three cumulative reports for one session yield the
  latest total, not the sum.
- Provenance conflict: self-reported and parsed records disagreeing on
  `modelID` yields both plus a conflict flag, not a silent pick.
- Existing audit-log and MCP tests pass unchanged — phase A must not alter
  either surface.

## Verification bar

`cd Core && swift test` green, plus a new `AgentSessionTests` and
`TokenUsageTests`. No UI, so no browser verification. Nothing here may be
claimed as verified against a real agent session until one has actually run —
the fixture adapter is a fixture, and saying otherwise is the failure this
project has repeatedly corrected for.
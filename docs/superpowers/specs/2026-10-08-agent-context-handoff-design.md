# Agent context handoff — Design

Date: 2026-10-08
Status: Approved design, spec-reviewed 2026-10-10 (amendments at the end)
Path: Architectural
**Depends on:** `2026-10-08-per-model-token-segments-design.md` (`783df64`).
Chain totals require per-model pricing, so this cannot be implemented before
segments land. Written now so the two specs can be checked for consistency.

## Goal

When one agent runs out of usable context, carry the work to another agent
without the user losing the thread — and report the **whole thread's** cost as
one number.

## Two different failures, not one

The phrase "the agent consumed all its token" names two unrelated limits, and
conflating them produces the wrong feature:

| | Context window | Usage quota |
|---|---|---|
| What it is | how much fits in *this conversation* | how much you're allowed over a rolling window |
| Visible in the log? | **yes** | **no** — provider-side, per account |
| Can the same agent continue? | **yes**, via `/compact` | **no**, hard wall |
| Justifies handoff? | sometimes | yes |

Only the second makes handoff the *only* option. For the first, moving to a
different agent throws away a conversation the current agent could have
summarised itself. So the affordance offers **both**, and the user chooses.

## What was verified, and what was not

Verified against the one session log on this machine:

- Claude Code writes `<total_tokens>N tokens left</total_tokens>` into its own
  log. **311 readings, 5 distinct values**, decreasing 15000000 → 14999357.
  Context pressure is therefore knowable from the file we already parse.
- The signal is **not** a top-level `"type":"total_tokens_reminder"` entry as
  first assumed (zero exist). It is nested:
  `{"type":"attachment","attachment":{"type":"total_tokens_reminder","text":"<total_tokens>N tokens left</total_tokens>"}}`
  — 129 such entries. The parser must read the nested shape.
- The log contains the user's real request text, 116 user turns, 130 assistant
  turns, and every `tool_use` entry with its command line. Everything a brief
  needs is on disk.

**Not verified:**

- **Usage-quota exhaustion is not detectable, and this design does not pretend
  otherwise** — it triggers on context pressure, which is the thing we can
  actually see. Two corrections to earlier claims, both real errors: the first
  draft's "10 quota signals" was a regex matching `429` inside UUIDs; the
  second draft's "zero quota messages exist" is **now false** — logs on this
  machine contain `isApiErrorMessage:true, error:"rate_limit",
  apiErrorStatus:429` entries (70+ files). Those are per-minute rate limits,
  often transient (`apiErrorIsTransient`), not rolling-window quota state, and
  the design deliberately does not trigger on either.
- **Sample size is 1**, and that session is exploratory: 86 bash calls, **0
  commits, 0 recognised test runs**. Whether brief extraction produces useful
  output on real working sessions is untested.
- The receiving agents' CLI invocation shapes are assumed, not confirmed against
  installed versions.

## Design

### 1. Trigger: context pressure, tracked as a high-water mark

A session records the **minimum** `tokens left` it has reported — peak pressure
— not the latest. Latest would be wrong: readings oscillate as sub-contexts
open and close, so the final value is not the worst one experienced.

Data path (amendment): pressure does **not** ride `TokenSourceAdapter.parse`,
which returns `[RawAgentUsage]` and skips non-`modelUsage` lines by design. A
separate extractor reads the nested `attachment` shape and returns a
`PressureReading?`; the existing `AgentLogMatcher` pass attributes it to a
session, and the session row gains `peakPressureTokens: Int?` folded as
`min(existing, new)` across passes. Usage and pressure stay independent
provenances.

Both options are offered at pressure:

- **Continue here** — the same agent's own summarisation. *Amendment:* we cannot
  invoke it — the agent's `/compact` lives in its own TTY and we hold no channel
  to it. The affordance therefore **offers the exact command to run** rather than
  running it; "invoke" was unbuildable as written.
- **Hand off** — the automatic path below.

### 2. The brief: every claim sourced

Extracted from the log into a structured brief:

- **Goal** — the user's actual request text, not a paraphrase of it.
- **Done** — mutations observed: `Write`/`Edit` targets, commands run.
- **Files touched** — with the operation, not just the path.
- **State** — the closing turns of the conversation.
- **Next** — what was in flight, where it stopped.

**Every line cites the log line it came from.** This is what makes automatic
handoff defensible rather than merely convenient: when the receiving agent acts
on a claim, the claim is traceable to a line in a file on disk. A brief we
cannot cite is a sentence we invented, and it is dropped rather than emitted.

The brief is a **reconstruction by us of someone else's conversation** — the
single highest-risk step in this design. Citing is the mitigation; it is not
sufficient on its own, which is why §5 keeps the audit trail.

### 3. Length budget — the brief competes for the scarce resource

The brief is injected into the receiving agent's context, which is **the same
finite resource whose exhaustion triggered the handoff**. An unbounded brief
recreates the pressure it was written to escape.

So the brief is **capped by token count**, prioritising goal > next > done >
files. When anything is dropped, the brief **names what was dropped and why**.
Truncation is never silent — an unmentioned truncation produces a receiving
agent that is confidently missing half the task.

### 4. The chain — one thread, many sessions, one total

Sessions gain `handedOffFrom` / `handedOffTo`, forming a directed chain.
A thread of work spanning Claude → Codex reports:

```
$3.42 · 2 sessions · Claude ($2.14) → Codex ($1.28)
```

**One total, with each session's share itemised.** This is the actual prize, and
it is unreachable without per-model pricing — which is why this spec is
sequenced after segments. A single-provenance total across two providers is
exactly the number that cannot be reconciled with an invoice.

The chain also **settles the "unit of work" question** raised separately: for a
handed-off thread the unit is the chain itself, observed rather than inferred.
No commit counting, no test-runner classifier, no denominator guesswork.

A session may be handed off **once**. A second handoff from the same session is
refused rather than forming a cycle.

### 5. Automatic execution, gated by machinery that already exists

Automatic does not mean ungated. The MCP permission modes already include
**"Allow session"**, built for exactly this: actions that write to the machine,
authorised once and then trusted. So:

- Handoff **requires that mode**. Outside it, the affordance reads and explains
  rather than acting.
- Every handoff writes to the existing **audit log** — brief, source citations,
  target agent, and the invoking session.
- **Dry run first, launch second.** The brief is generated and stored; only then
  is the receiving agent started. A generation failure cannot produce a launch.
- **Refuse on an empty or unsourced brief.** If no claim survives citation, there
  is nothing to hand off and the reason is stated.
- **Context-pressure state can be disabled**, which turns the feature off without
  changing permissions.
- The receiving agent is launched with a **known working directory** — recorded
  from the session, never guessed from the brief.

Safety here is not a new concept bolted onto an automatic action. It is the
existing gate, used for something that deserves it.

### 6. Launching

The receiving agent is spawned with the brief on stdin, in the session's working
directory. The invocation shape per agent is configuration, not code — so
adding an agent is a config entry rather than a code path.

If the target CLI is not installed, the handoff **fails with that reason** and
offers the brief for manual use. It never silently does nothing.

## Scope

**In:** pressure detection, brief extraction with citation, length budget,
chain linking and chain totals, handoff execution behind the existing gate,
audit entries, the side/top affordance offering both options.

**Out:** quota detection (not detectable — see above); resuming the same agent
automatically; work-unit metrics by commit or test count (the chain supersedes
them for handed-off threads); brief quality for non-Claude sources until a
second adapter exists.

## Risks

- **Brief synthesis is the dangerous step.** A wrong "done" claim could have a
  receiving agent skip real work or redo finished work. Mitigation is citation
  plus audit, which reduces but does not eliminate it.
- **The trigger is the wrong half of the problem.** We detect context pressure,
  which is visible; we cannot detect quota exhaustion, which is the case where
  handoff is mandatory. The feature will fire on a pressure case where
  `/compact` was the better answer — hence offering both.
- **Automatic means errors are unattended.** A bad brief is acted on before a
  human sees it. This is accepted as the design's cost, bounded by the gate, the
  audit log and the kill switch.
- **Evidence is one exploratory session.** Brief quality on real working sessions
  is unmeasured. The first implementation should be read on real logs before the
  gate is opened.

## Spec review amendments (2026-10-10)

A codebase review against `main @ 8327ebb` found the design unexecutable as
written in seven places. Each amendment below is binding on the implementation.

1. **Chain identification (`handedOffTo`) was unspecified.** At handoff time we
   record the spawned process's PID on the source session
   (`handoffTargetPID: Int32?`); when a session later connects with
   `peerPID == handoffTargetPID`, the store — under its existing `NSLock` — sets
   `source.handedOffTo` and `target.handoffFrom` in one write. No session with
   that PID ever arriving leaves `handedOffTo == nil`: the chain stays one
   session, which is an honest absence, not a zero. Caveat known from
   `MCPHostServer`: `peerPID` is the process that connects to `mcp.sock` (often
   a CLI's relay child), so a relay whose PID differs from the spawned CLI will
   not link.
2. **Once-only and cycle-freedom** are cross-row invariants SwiftData cannot
   express. Enforced in `AgentSessionStore` under `NSLock`: refuse a second
   handoff from a source (`handedOffTo != nil`) or into a target
   (`handedOffFrom != nil`), returning the reason. Each node having ≤1 outgoing
   edge is what structurally prevents cycles — no separate cycle check.
3. **Migration:** `handedOffFrom`, `handedOffTo`, `handoffTargetPID` and
   `peakPressureTokens` are optional properties on the existing unversioned
   `ModelContainer` — lightweight migration. The repo has zero migration tests;
   one smoke test (open a pre-change store file, add the fields, re-open) ships
   with the task that adds them.
4. **The gate stays one enforcement point:** handoff is a mutation-effect
   catalog tool (`handoff_context`) going through `PermissionGate.decide` and
   `AuditLog` like every other mutation. A UI affordance is disabled and
   explanatory outside `.allowSession`, mirroring the same mode read — not a
   second gate implementation.
5. **Kill switch lives in `AppPreferences`, not `MCPSettings`.** `MCPSettings.load`
   falls back to defaults on any decode error, so adding a field would silently
   reset every existing user's mutation mode to `.off`. `AppPreferences` already
   uses `decodeIfPresent` throughout.
6. **Brief persistence:** written to `~/.portmaster/handoffs/<session-uuid>.md`
   *before* launch (the dry run); the audit line cites the path plus the log
   line numbers, rather than inlining a multi-KB brief as an argument value.
7. **Launch seam:** `SubprocessRunner.run` sets `standardInput =
   FileHandle.nullDevice`, so "brief on stdin" needs a new stdin-capable seam;
   `workingDirectory` is not on the session row (the log has `cwd`, we do not),
   so it is parsed at extraction time and carried with the brief — never guessed.
8. **Affordance placement:** the sessions card's footer is a fixed 30pt strip in
   a 208pt card and the card has no `detailLink` — two action buttons do not
   fit without redesigning it. `worthALook`/`ActingUpAlert.Kind` is closed and
   wrong-shaped (engine-sampled vitals, not log-derived state). The pressure
   state is a dedicated `@Published` on `AppModel`, fed by the poller pass like
   `agentSourcePassCompleted`, rendered as its own strip above the overview
   grid; the actions live in a sheet on that strip. No new `MainTab`, no fifth
   `ActingUpAlert.Kind`, no footer surgery.
9. **What the number means is unverified — and the spec's label was wrong to
   assume.** Claude Code's own source map (harness.dtmont.com, "Remaining
   tokens") shows the attachment's mode is session-latched and its meaning
   mode-dependent: `countdown` = model context budget − tokens used,
   `padded-countdown` = task budget remaining, `fixed` = constant `5000000`,
   `infinite` = the literal text `Infinite`. Our log (78 reminders, 116 user
   turns) shows a ceiling of exactly 15000000, plateaus, and **only two
   resets** — each immediately after an ordinary user prompt, each back to the
   exact ceiling, with **no compaction and no sidechain** in the file. Context
   consumption cannot explain it (the same session measured 16,739 output
   tokens while the counter moved −643). So: (a) the parser must tolerate a
   non-numeric `Infinite` and treat it as no reading, (b) the UI quotes the
   log's own words — `N tokens left` — and never renames it "context window",
   (c) the §1 trigger tracks worst-observed, and (d) the strip's appearance
   threshold is a **provisional literal** (worst ≤ half of the session's first
   reading, so a counter that never erodes never shouts), recorded like the 1%
   tolerance: unvalidated, one call site, named in the plan.
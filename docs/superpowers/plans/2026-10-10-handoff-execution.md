# Agent Context Handoff — Execution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a session's context pressure is visible, extract a citation-backed brief, link sessions into a once-only handoff chain with one honest thread total, and launch a receiving agent with the brief on stdin — behind the existing mutation gate, with a dry run before every launch and a kill switch in preferences.

**Architecture:** Three layers. (1) Pure Core: `HandoffBrief` + `HandoffBriefExtractor` parse a Claude Code JSONL log into cited sections under a token budget; store-level chain edges (`handedOffFrom`/`handedOffTo`/`handoffTargetPID`/`handoffTargetName`) on `AgentSession`, linked under the store's existing `NSLock`, with `ChainReport` computed in `sessions()`. (2) Host: `HandoffCoordinator` in PortmasterMCP runs the dry-run-then-launch sequence, exposed as the mutation catalog tool `handoff_context` (gate + audit + approval machinery unchanged, like every other mutation) and as `AppModel.performHandoff` for the UI. (3) App: the pressure strip gets a sheet offering both spec options (run `/compact` yourself, or hand off), plus a kill-switch toggle in Settings.

**Tech Stack:** Swift 5 (package pins `.swiftLanguageMode(.v5)` — no Regex literals), SwiftData lightweight migration, Foundation `JSONSerialization` line parsing, XCTest; App-side claims are source-scan tests (there is no App test target).

**Spec:** `docs/superpowers/specs/2026-10-08-agent-context-handoff-design.md` — sections 2–6 and amendments 1–9 are implemented here. Section 1 (pressure tracking) shipped in `docs/superpowers/plans/2026-10-10-context-pressure.md`; its field `peakPressureTokens` from the spec **is** the shipped `tokensLeftWorst` — no rename, quoted-numbers rules already hold.

## Global Constraints

- **Honesty rules (house contract):** unknown is `nil`, never zero; absence is never a partial total; every optional on the wire is omitted when nil (never `null`, never `0`); a figure nobody can compute says why instead of showing `0`.
- Comments explain **why**, never restate code.
- **Zero new build warnings.** The six pre-existing warnings in `MachSystemCollector`, `LsofPortScanner`, `SystemExtraCollectors`, `SamplingEngine`, `PortmasterApp` stay untouched.
- `Core/Package.resolved` gets dirtied by builds — leave it uncommitted.
- **No visual UI claims.** The app cannot be inspected (no assistive access, `osascript … -2528`). App-side verification is source-scan tests plus a successful `xcodebuild`. Never claim the sheet/strip/toggle was seen working.
- Suite counts drift as tests are added — growth is the signal; **zero failures** is the gate.
- Test commands: `swift test --filter <Name>` from `Core/`; full suite `swift test` from `Core/`; app compile `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build`.
- End-to-end gate (run at Task 7 completion): `scripts/mcp-e2e.sh --no-manual <absolute-app-path> <absolute-mcp-binary>` → 17/0/1 (passed/failed/skipped — the run tally, not a tool count; Task 6 raises the script's own tools/list expectation to 18), where the app comes from `xcodebuild -showBuildSettings` `BUILT_PRODUCTS_DIR` and the binary is `Core/.build/debug/portmaster-mcp`.
- Rulings below resolve spec gaps and are binding on the implementation; record any further ruling in the SDD ledger as `Ruling:` lines.

## Binding rulings (spec gaps resolved while writing this plan)

1. **Field names:** `handedOffFrom` / `handedOffTo` (spec §4 is authoritative; amendment 1's `handoffFrom` is a slip of the pen).
2. **`handoffTargetName`** is stored beside `handoffTargetPID`: the chain arrow needs the receiving agent's configured name because `clientName` is always nil on the socket path (`MCPHostServer.recordSession` passes `nil` — the SDK consumes `initialize`).
3. **Chain line placement:** `sessions()` sorts ascending by `connectedAt`, so the sessions-card footer shows the **oldest** rows first. The chain report renders on the chain **head** row (`handedOffFrom == nil && chain != nil`), which is therefore always among the visible rows; middle/tail rows show nothing (one line per chain, never a duplicate).
4. **Chain totals:** `ChainReport.totalUSD` is non-nil only when **every** member's `cost.usd` is non-nil; otherwise the line says `· total not priced` and prints no per-share dollars either. `get_agent_sessions` gains only `handedOffFrom`/`handedOffTo` — no totals on the wire (a limited query could otherwise compute a partial chain).
5. **Label rule:** head label = `clientName ?? "agent"` (same rule `SessionLine` already uses); every subsequent member = predecessor's `handoffTargetName ?? member.clientName ?? "agent"`.
6. **Budget:** `HandoffBrief.budgetTokens = 1500`, provisional and named (like the 1% tolerance and the half-first threshold). Estimator = `text.utf8.count / 4`, documented as an estimate — there is no tokenizer in this repo and a precise one is not worth a dependency for a heuristic cap. Drop order: state → files → done (tail first, one item at a time) → next → clip goal by halving, with `… [clipped to fit the handoff budget]`. Every drop lands in a `## Dropped` section naming what and why; truncation is never silent (spec §3).
7. **Section text:** Done and Files may cite the same log line (spec defines both sections; Done includes commands, Files is the file-operations subset). Bash commands are clipped at 200 characters with `…`; whole items are dropped intact before anything is clipped.
8. **Turn rules:** Goal = first user turn whose `message.content` is a **string** (a `tool_result` array is not a user turn), stripped at `<system-reminder>` and skipped if nothing remains. State = the last 3 conversation turns (user-string or assistant-text, in line order). Next = the last `tool_use` whose `tool_use_id` never appears in a later `tool_result`; if none, the last assistant text; if neither, the section is omitted.
9. **Target configuration:** `~/.portmaster/handoff-targets.json`, a `[String: {executable, arguments}]` map. Built-in defaults `claude` and `codex` (both bare executables, brief on stdin) apply when the file is absent, unreadable, or empty — the file overrides only when it decodes non-empty. The invocation shapes are **assumed, not confirmed** (spec §"Not verified") and the file exists so correcting them is an edit, not a code change.
10. **Audit note:** success lines for `handoff_context` carry `reason` = `brief=<path> lines=<n,…>` (first 20 cited line numbers + `+N more`), never the brief text (amendment 6). Mechanism: a private `MCPAuditNoting` protocol; `ToolExecutor`'s success `audit.record` uses `(payload as? MCPAuditNoting)?.auditNote`. The UI path writes its own audit line with the same tool name and `arguments` including `"origin": "app"` so the two surfaces are distinguishable.
11. **Approval machinery is mandatory, not optional:** `MCPApprovalPresentationTests` asserts mutations ↔ `MCPApprovalRequest.Kind` 1:1 and requires `sampleArguments(for:)` for every mutation. Adding `handoff_context` therefore **requires** a new `Kind.handoffContext` case, copy in all four `MCPApprovalCopy` switches, a `request(for:)` case, a `sampleArguments` entry, and the catalog-count assertions 17 → 18. (Amendment 8's "closed Kind" forbade a fifth `ActingUpAlert.Kind` for the *pressure notice*; this is the approval window's own enum and the tests mandate the pair.)
12. **Kill switch:** `AppPreferences.contextHandoffsEnabled`, default `true`, `decodeIfPresent` like its neighbours. The coordinator enforces it for **both** paths (single authority, reads `AppPreferences.load(from:)` per call — the house reads settings per call). A refusal throws `MCPToolError` → audit `failed` with the reason; `denied` stays reserved for gate-mode refusals (AuditLog's four-word vocabulary defines `denied` as "the gate refused"). Toggle lives in Settings → General beside the other `AppPreferences` toggles.
13. **Spawn-then-record, kill on refusal:** the coordinator launches first, then `recordHandoff` re-checks `handoffTargetPID == nil` under the lock; if it returns false the just-spawned pid is terminated and the handoff reported as refused. The once-only invariant is enforced where it is authoritative, not by a pre-check that races.
14. **PID reuse is a documented caveat, not solved:** a stale `handoffTargetPID` whose process died can be reused by an unrelated process that later connects to `mcp.sock`; amendment 1's relay-child caveat already accepts linkage as best-effort. The link is once-only into at most one target, which is the cycle-freedom the spec requires.
15. **Match overlap:** one authority — `AgentLogMatcher.defaultOverlap = 60 * 60`; the poller's init default and the coordinator both reference it.
16. **UI mode mirror:** the sheet reads `AppDelegate.shared?.mcpHost?.mode` — the same precedent `SettingsView` line 330 uses — and requires `.allowSession` (amendment 4). It is a mirror for disabling/auditing, not a second gate implementation; the MCP path's `PermissionGate` runs unchanged, whatever the mode.
17. **New seams, no churn:** `LiveDataProvider` gains an **optional** `handoff` closure (default `nil`, like `sessionReading`) so its five construction sites compile unchanged; `HandoffLaunching` is its own protocol — `ProcessRunning` (docker path) is not widened.
18. **Files:** `HandoffBrief.swift` + `HandoffBriefExtractor.swift` in `PortmasterCore/History` (log knowledge lives in Core, beside `ContextPressureExtractor`); `HandoffTargets.swift`, `HandoffLauncher.swift`, `HandoffCoordinator.swift` in `PortmasterMCP` (flat, beside the other host types).

## File structure

| File | Responsibility |
|---|---|
| Create `Core/Sources/PortmasterCore/History/HandoffBrief.swift` | Brief structs, budget, markdown rendering, `citedLines`, `auditNote`-shaped line list |
| Create `Core/Sources/PortmasterCore/History/HandoffBriefExtractor.swift` | JSONL line walk → cited sections |
| Modify `Core/Sources/PortmasterCore/History/AgentSessionStore.swift` | Four new model fields, `recordHandoff`, PID link in `recordSession`, snapshot fields, `ChainReport`/`ChainShare`, `sessions()` chaining |
| Modify `Core/Sources/PortmasterCore/History/AgentLogMatcher.swift` | `defaultOverlap` constant |
| Modify `Core/Sources/PortmasterCore/History/AgentSourcePoller.swift` | Init default references `AgentLogMatcher.defaultOverlap` |
| Modify `Core/Sources/PortmasterCore/Models/Preferences.swift` | `contextHandoffsEnabled` |
| Create `Core/Sources/PortmasterMCP/HandoffTargets.swift` | Target config load (defaults + JSON override) |
| Create `Core/Sources/PortmasterMCP/HandoffLauncher.swift` | `HandoffLaunching` + `SystemHandoffLauncher` (PATH resolve, stdin launch, terminate) |
| Create `Core/Sources/PortmasterMCP/HandoffCoordinator.swift` | Dry-run-then-launch flow, `HandoffOutcome` (+ `auditNote`) |
| Modify `Core/Sources/PortmasterMCP/ToolExecutor.swift` | Catalog entry, dispatch case, `sessionUUID` helper, `MCPAuditNoting`, success-audit reason |
| Modify `Core/Sources/PortmasterMCP/DataProvider.swift` | `handoffContext` requirement |
| Modify `Core/Sources/PortmasterMCP/LiveDataProvider.swift` | Optional `handoff` closure + method |
| Modify `Core/Sources/PortmasterMCP/OnDemandProvider.swift` | Honest refusal method |
| Modify `Core/Sources/PortmasterMCP/WirePayloads.swift` | `HandoffContextPayload`; `handedOffFrom`/`handedOffTo` on `AgentSessionPayload` |
| Modify `Core/Sources/PortmasterMCP/ConfirmationBroker.swift` | `Kind.handoffContext` |
| Modify `Core/Sources/PortmasterMCP/MCPApprovalCopy.swift` | Copy for the new kind (4 switches) |
| Modify `Core/Sources/PortmasterMCP/HostMCPCallContext.swift` | `request(for:)` case |
| Modify `App/MCPHostController.swift` | `handoff:` closure in `makeProvider()`; `needsReading` case for the new approval kind |
| Modify `App/MCPConfirmationWindow.swift` | `resolve(_:)` case for `handoffContext` (the approval window validates before a person is asked) |
| Modify `App/AppModel.swift` | `performHandoff` (the sheet calls it; the MCP path audits through the executor instead) |
| Modify `App/OverviewView.swift` | Strip → button + `PressureActionsSheet`; chain line in `SessionLine` |
| Modify `App/SettingsView.swift` | Kill-switch toggle (General tab) |
| Tests (per task) | Listed inside each task |

---

### Task 1: The brief extractor — every claim carries its line

**Files:**
- Create: `Core/Sources/PortmasterCore/History/HandoffBrief.swift`
- Create: `Core/Sources/PortmasterCore/History/HandoffBriefExtractor.swift`
- Test: `Core/Tests/PortmasterCoreTests/HandoffBriefExtractorTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces:
  - `public struct BriefItem { public let text: String; public let line: Int; public init(text: String, line: Int) }`
  - `public struct HandoffBrief { goal, done, files, state, next, workingDirectory, sourceLogPath, sessionID, dropped; citedLines; public init(...); renderedMarkdown() -> String }`
  - `public enum HandoffBriefExtractor { public static func extract(from url: URL) throws -> HandoffBrief; public static func extract(from text: String, sourceLogPath: String) -> HandoffBrief }`
  - `line` is always the **1-based physical line number** in the source file (same convention as `ContextPressureExtractor`, blank lines counted).

- [ ] **Step 1: Write the failing extractor tests**

```swift
// Core/Tests/PortmasterCoreTests/HandoffBriefExtractorTests.swift
import XCTest
import Foundation
@testable import PortmasterCore

final class HandoffBriefExtractorTests: XCTestCase {

    private func writeLog(_ lines: [String], name: String = "session.jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brief-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Eight lines, numbered and role-tagged in the comments — every assertion below
    /// pins a line number, so a parser that counts wrong fails here and not later.
    private func fixtureLines(projectDir: String) -> [String] {
        [
            // 1 — goal text and cwd ride the first user turn
            #"{"type":"user","timestamp":"2026-10-10T12:00:00.000Z","cwd":"\#(projectDir)","message":{"role":"user","content":"Fix the flaky retry test and commit."}}"#,
            // 2 — an assistant text turn (state)
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"I will look at the retry test."}]}}"#,
            // 3 — a tool_result user entry: NOT a user turn
            #"{"type":"user","timestamp":"2026-10-10T12:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            // 4 — Bash mutation (Done)
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:10.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"grep -r retry Tests/"}}]}}"#,
            // 5 — Write mutation (Done and Files touched)
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:15.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"\#(projectDir)/fix.swift","content":"x"}}]}}"#,
            // 6 — in-flight Bash: no tool_result ever follows → Next
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:20.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"swift test --filter Retry"}}]}}"#,
            // 7 — last assistant text (state)
            #"{"type":"assistant","timestamp":"2026-10-10T12:00:25.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Running the filter now."}]}}"#,
            // 8 — closing user turn (state)
            #"{"type":"user","timestamp":"2026-10-10T12:00:30.000Z","message":{"role":"user","content":"also update the changelog"}}"#,
        ]
    }

    func testEveryClaimCarriesTheLineItCameFrom() throws {
        let projectDir = FileManager.default.temporaryDirectory.appendingPathComponent("proj").path
        let url = try writeLog(fixtureLines(projectDir: projectDir))

        let brief = try HandoffBriefExtractor.extract(from: url)

        XCTAssertEqual(brief.goal, BriefItem(text: "Fix the flaky retry test and commit.", line: 1))
        XCTAssertEqual(brief.workingDirectory, projectDir)
        XCTAssertEqual(brief.done, [
            BriefItem(text: "ran `grep -r retry Tests/`", line: 4),
            BriefItem(text: "wrote \(projectDir)/fix.swift", line: 5),
        ])
        XCTAssertEqual(brief.files, [
            BriefItem(text: "wrote \(projectDir)/fix.swift", line: 5),
        ])
        XCTAssertEqual(brief.state.map(\.line), [2, 7, 8],
                       "the closing turns are the last three conversation turns, in order")
        XCTAssertEqual(brief.next?.line, 6, "t3 never got a tool_result — it was in flight")
        XCTAssertEqual(brief.next?.text, "ran `swift test --filter Retry`")
        XCTAssertEqual(brief.citedLines, [1, 2, 4, 5, 6, 7, 8],
                       "deduplicated and sorted; line 3 is a tool_result and cites nothing")
        XCTAssertTrue(brief.dropped.isEmpty)
    }

    func testAToolResultArrayIsNotAUserTurn() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"x"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"still working"}]}}"#,
        ]
        let brief = HandoffBriefExtractor.extract(from: lines.joined(separator: "\n"), sourceLogPath: "/tmp/x.jsonl")
        XCTAssertNil(brief.goal, "no real user turn exists, so no goal is invented")
        XCTAssertEqual(brief.next?.text, "still working",
                       "with no dangling tool_use, Next is the last assistant text")
    }

    func testASystemReminderOnlyUserTurnIsNotAGoal() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"<system-reminder>watch the style</system-reminder>"}}"#,
            #"{"type":"user","message":{"role":"user","content":"the real request"}}"#,
        ]
        let brief = HandoffBriefExtractor.extract(from: lines.joined(separator: "\n"), sourceLogPath: "/tmp/x.jsonl")
        XCTAssertEqual(brief.goal, BriefItem(text: "the real request", line: 2),
                       "a reminder-wrapped turn has no user text left after stripping")
    }

    func testALogWithNothingCitableYieldsNothing() throws {
        let lines = [
            #"{"type":"system","message":"booting"}"#,
            #"{"type":"mode","mode":"plan"}"#,
            "not json at all",
        ]
        let brief = HandoffBriefExtractor.extract(from: lines.joined(separator: "\n"), sourceLogPath: "/tmp/x.jsonl")
        XCTAssertNil(brief.goal)
        XCTAssertTrue(brief.done.isEmpty)
        XCTAssertTrue(brief.files.isEmpty)
        XCTAssertTrue(brief.state.isEmpty)
        XCTAssertNil(brief.next)
        XCTAssertNil(brief.workingDirectory)
        XCTAssertTrue(brief.citedLines.isEmpty, "zero citations is what the refusal test keys on")
    }

    func testALongCommandIsClippedAndSaysSo() throws {
        let long = String(repeating: "a", count: 400)
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{"command":"\#(long)"}}]}}"#,
        ]
        let brief = HandoffBriefExtractor.extract(from: lines.joined(separator: "\n"), sourceLogPath: "/tmp/x.jsonl")
        XCTAssertEqual(brief.done.first?.line, 1)
        XCTAssertEqual(brief.done.first?.text.count, 201, "200 characters plus the ellipsis")
        XCTAssertTrue(brief.done.first?.text.hasSuffix("…") ?? false)
    }

    func testTheRenderedBriefCitesEverySection() throws {
        let projectDir = "/tmp/proj"
        let url = try writeLog(fixtureLines(projectDir: projectDir))
        var brief = try HandoffBriefExtractor.extract(from: url)
        brief.sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")

        let markdown = brief.renderedMarkdown()

        XCTAssertTrue(markdown.contains("Session: 11111111-2222-3333-4444-555555555555"))
        XCTAssertTrue(markdown.contains("Source log: \(url.path)"))
        XCTAssertTrue(markdown.contains("## Goal\nFix the flaky retry test and commit. (line 1)"))
        XCTAssertTrue(markdown.contains("## Done"))
        XCTAssertTrue(markdown.contains("- ran `grep -r retry Tests/` (line 4)"))
        XCTAssertTrue(markdown.contains("## Files touched"))
        XCTAssertTrue(markdown.contains("## State"))
        XCTAssertTrue(markdown.contains("## Next\nran `swift test --filter Retry` (line 6)"))
        XCTAssertFalse(markdown.contains("## Dropped"), "nothing was dropped, so nothing is named")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `Core/`): `swift test --filter HandoffBriefExtractorTests`
Expected: FAIL to compile — `HandoffBrief`, `HandoffBriefExtractor`, `BriefItem` do not exist.

- [ ] **Step 3: Write the brief types and extractor**

```swift
// Core/Sources/PortmasterCore/History/HandoffBrief.swift
import Foundation

/// One claim extracted from a conversation log, with the physical log line it
/// came from. The line is the whole point: a brief without citations is a
/// sentence we invented, and the receiving agent must be able to walk to the
/// source of every claim it acts on (spec §2).
public struct BriefItem: Equatable, Sendable {
    public let text: String
    /// 1-based physical line number in the source JSONL file.
    public let line: Int
    public init(text: String, line: Int) {
        self.text = text
        self.line = line
    }
}

/// A reconstructed handoff brief: the conversation, sourced. Sections that have
/// nothing behind them are `nil`/empty rather than zero-filled or paraphrased —
/// an absent Goal is a log that had no user turn, not a user who asked nothing.
public struct HandoffBrief: Equatable, Sendable {
    public let goal: BriefItem?
    /// Mutations observed: Write/Edit targets and commands run (spec §2).
    public let done: [BriefItem]
    /// The file operations among them, with their operation (spec §2). Overlaps
    /// `done` on purpose: the spec defines both sections, and a line may be
    /// cited by both.
    public let files: [BriefItem]
    /// The closing turns of the conversation (spec §2).
    public let state: [BriefItem]
    /// What was in flight, where it stopped (spec §2).
    public let next: BriefItem?
    /// The log's own `cwd`, parsed at extraction time — never guessed later
    /// (spec amendment 7).
    public let workingDirectory: String?
    public let sourceLogPath: String
    /// Set by the handoff coordinator before rendering: the extractor cannot
    /// know which Portmaster session's brief this is.
    public var sessionID: UUID?
    /// What the length budget dropped, in the budget's own words (spec §3).
    /// Empty until `budgeted()` runs.
    public var dropped: [String]

    public init(
        goal: BriefItem?, done: [BriefItem], files: [BriefItem],
        state: [BriefItem], next: BriefItem?, workingDirectory: String?,
        sourceLogPath: String, sessionID: UUID? = nil, dropped: [String] = []
    ) {
        self.goal = goal
        self.done = done
        self.files = files
        self.state = state
        self.next = next
        self.workingDirectory = workingDirectory
        self.sourceLogPath = sourceLogPath
        self.sessionID = sessionID
        self.dropped = dropped
    }

    /// Every distinct source line this brief cites, sorted — the audit line's
    /// `lines=` argument and the receiving agent's map back to the log.
    public var citedLines: [Int] {
        var lines = [goal?.line, next?.line].compactMap { $0 }
        lines += (done + files + state).map(\.line)
        return Array(Set(lines)).sorted()
    }

    /// The brief as it ships: header, then sections, then the Dropped list.
    /// Section bodies carry `(line N)` after each claim — the citation is part
    /// of the text the receiving agent reads, not metadata only we can see.
    public func renderedMarkdown() -> String {
        var out = "# Handoff brief\n\n"
        if let sessionID { out += "Session: \(sessionID.uuidString)\n" }
        out += "Source log: \(sourceLogPath)\n"
        if let workingDirectory { out += "Working directory: \(workingDirectory)\n" }
        out += "\n"
        if let goal {
            out += "## Goal\n\(goal.text) (line \(goal.line))\n\n"
        }
        func section(_ title: String, _ items: [BriefItem]) {
            guard !items.isEmpty else { return }
            out += "## \(title)\n"
            out += items.map { "- \($0.text) (line \($0.line))" }.joined(separator: "\n")
            out += "\n\n"
        }
        section("Done", done)
        section("Files touched", files)
        section("State", state)
        if let next {
            out += "## Next\n\(next.text) (line \(next.line))\n\n"
        }
        if !dropped.isEmpty {
            out += "## Dropped\n"
            out += dropped.map { "- \($0)" }.joined(separator: "\n")
            out += "\n"
        }
        return out
    }
}
```

```swift
// Core/Sources/PortmasterCore/History/HandoffBriefExtractor.swift
import Foundation

/// Reconstructs a handoff brief from a Claude Code JSONL log.
///
/// Only claims the log makes are emitted, each with its line. Entries that are
/// not conversation turns (modes, attachments, reminders, tool results) are
/// skipped rather than reinterpreted; a section with nothing behind it stays
/// empty.
public enum HandoffBriefExtractor {

    public static func extract(from url: URL) throws -> HandoffBrief {
        let text = try String(contentsOf: url, encoding: .utf8)
        return extract(from: text, sourceLogPath: url.path)
    }

    public static func extract(from text: String, sourceLogPath: String) -> HandoffBrief {
        var goal: BriefItem?
        var done: [BriefItem] = []
        var files: [BriefItem] = []
        var turns: [BriefItem] = []          // user-string and assistant-text, line order
        var next: BriefItem?
        var workingDirectory: String?

        // tool_use in line order, and the ids a tool_result ever answered.
        var toolUses: [(id: String, item: BriefItem, input: [String: Any])] = []
        var answered: Set<String> = []

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, raw) in lines.enumerated() {
            let lineNumber = offset + 1
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if workingDirectory == nil,
               let cwd = object["cwd"] as? String, !cwd.isEmpty {
                workingDirectory = cwd
            }

            switch object["type"] as? String {
            case "user":
                guard let message = object["message"] as? [String: Any] else { break }
                if let content = message["content"] as? String {
                    // Strip a wrapped system-reminder; a turn with nothing left
                    // after the marker carried no user words at all.
                    let visible = content
                        .components(separatedBy: "<system-reminder>").first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !visible.isEmpty {
                        let item = BriefItem(text: visible, line: lineNumber)
                        turns.append(item)
                        if goal == nil { goal = item }
                    }
                } else if let blocks = message["content"] as? [[String: Any]] {
                    for block in blocks where block["type"] as? String == "tool_result" {
                        if let id = block["tool_use_id"] as? String { answered.insert(id) }
                    }
                }
            case "assistant":
                guard let message = object["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]]
                else { break }
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            turns.append(BriefItem(text: text, line: lineNumber))
                        }
                    case "tool_use":
                        guard let id = block["id"] as? String,
                              let name = block["name"] as? String,
                              let input = block["input"] as? [String: Any]
                        else { continue }
                        toolUses.append((id, BriefItem(text: "", line: lineNumber), input))
                        recordMutation(
                            name: name, input: input, line: lineNumber,
                            done: &done, files: &files
                        )
                    default:
                        continue
                    }
                }
            default:
                continue
            }
        }

        // Next: the last tool_use no tool_result ever answered, else the last
        // assistant text — where it stopped, either way.
        if let pending = toolUses.last(where: { !answered.contains($0.id) }) {
            next = BriefItem(text: nextText(for: pending), line: pending.item.line)
        } else if let lastText = turns.last {
            next = lastText
        }

        return HandoffBrief(
            goal: goal, done: done, files: files,
            state: Array(turns.suffix(3)), next: next,
            workingDirectory: workingDirectory, sourceLogPath: sourceLogPath
        )
    }

    private static func recordMutation(
        name: String, input: [String: Any], line: Int,
        done: inout [BriefItem], files: inout [BriefItem]
    ) {
        switch name {
        case "Write":
            guard let path = input["file_path"] as? String else { return }
            let item = BriefItem(text: "wrote \(path)", line: line)
            done.append(item)
            files.append(item)
        case "Edit", "MultiEdit":
            guard let path = input["file_path"] as? String else { return }
            let item = BriefItem(text: "edited \(path)", line: line)
            done.append(item)
            files.append(item)
        case "NotebookEdit":
            guard let path = (input["notebook_path"] as? String) ?? (input["file_path"] as? String)
            else { return }
            let item = BriefItem(text: "edited \(path)", line: line)
            done.append(item)
            files.append(item)
        case "Bash":
            guard let command = input["command"] as? String else { return }
            // One line must stay one line: a 40 kB command would blow the whole
            // brief budget by itself, and a clipped command is named by the ellipsis.
            let clipped = command.count > 200
                ? String(command.prefix(200)) + "…"
                : command
            done.append(BriefItem(text: "ran `\(clipped)`", line: line))
        default:
            return
        }
    }

    private static func nextText(
        for pending: (id: String, item: BriefItem, input: [String: Any])
    ) -> String {
        if let command = pending.input["command"] as? String {
            let clipped = command.count > 200 ? String(command.prefix(200)) + "…" : command
            return "ran `\(clipped)`"
        }
        if let path = (pending.input["file_path"] as? String)
            ?? (pending.input["notebook_path"] as? String) {
            return "\(pending.id.isEmpty ? "" : "")\(path)"
        }
        // Last resort: a compact form of the input, clipped. The id itself is
        // tool plumbing, not a claim, so it is not printed.
        if let data = try? JSONSerialization.data(
            withJSONObject: pending.input, options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) {
            return json.count > 120 ? String(json.prefix(120)) + "…" : json
        }
        return "an in-flight tool call"
    }
}
```

Note: in `nextText`, the `file_path` branch is simply `return path` — drop the pointless `pending.id.isEmpty ? "" : ""` ternary shown above; it is a leftover of drafting and must not be written that way. The committed form is `return path`.

- [ ] **Step 4: Run the test to verify it passes**

Run (from `Core/`): `swift test --filter HandoffBriefExtractorTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PortmasterCore/History/HandoffBrief.swift \
        Core/Sources/PortmasterCore/History/HandoffBriefExtractor.swift \
        Core/Tests/PortmasterCoreTests/HandoffBriefExtractorTests.swift
git commit -m "feat: the brief cites the line behind every claim"
```

---

### Task 2: The length budget — the brief competes for the resource it escapes

**Files:**
- Modify: `Core/Sources/PortmasterCore/History/HandoffBrief.swift`
- Test: `Core/Tests/PortmasterCoreTests/HandoffBriefBudgetTests.swift`

**Interfaces:**
- Consumes: `HandoffBrief` from Task 1.
- Produces:
  - `public static let budgetTokens: Int` (= 1500, provisional)
  - `public static func estimateTokens(_ text: String) -> Int`
  - `public func budgeted() -> HandoffBrief` — copy with `dropped` filled, items removed, goal clipped, never silent.

- [ ] **Step 1: Write the failing budget tests**

```swift
// Core/Tests/PortmasterCoreTests/HandoffBriefBudgetTests.swift
import XCTest
import Foundation
@testable import PortmasterCore

final class HandoffBriefBudgetTests: XCTestCase {

    private func brief(
        goal: String = "do the thing", done: [BriefItem] = [], files: [BriefItem] = [],
        state: [BriefItem] = [], next: BriefItem? = nil
    ) -> HandoffBrief {
        HandoffBrief(
            goal: BriefItem(text: goal, line: 1),
            done: done, files: files, state: state, next: next,
            workingDirectory: "/tmp/p", sourceLogPath: "/tmp/p/s.jsonl"
        )
    }

    private func pad(_ label: String, size: Int) -> String {
        label + String(repeating: "x", count: size)
    }

    func testASmallBriefIsUntouched() {
        let b = brief(state: [BriefItem(text: "hi", line: 9)])
        XCTAssertEqual(b.budgeted(), b, "a brief under budget keeps every word and says nothing was dropped")
    }

    func testStateGoesFirstAndNamesItself() {
        var b = brief()
        b = HandoffBrief(
            goal: b.goal, done: b.done, files: b.files,
            state: (1...40).map { BriefItem(text: pad("turn\($0) ", size: 120), line: $0) },
            next: nil, workingDirectory: b.workingDirectory, sourceLogPath: b.sourceLogPath
        )
        let budgeted = b.budgeted()
        XCTAssertTrue(budgeted.state.isEmpty, "state is the lowest-priority section")
        XCTAssertEqual(budgeted.dropped.count, 1)
        XCTAssertTrue(budgeted.dropped[0].hasPrefix("state: 40 closing turns dropped"))
        XCTAssertTrue(budgeted.dropped[0].contains("length budget"))
    }

    func testDoneIsTrimmedFromTheTailAndNamesHowMany() {
        let big = (1...80).map { BriefItem(text: pad("ran `cmd\($0)` ", size: 140), line: $0) }
        let b = brief(done: big, state: [])
        let budgeted = b.budgeted()
        XCTAssertFalse(budgeted.done.isEmpty, "the earliest mutations survive — they define the work")
        XCTAssertTrue(budgeted.done.count < big.count)
        let note = try? XCTUnwrap(budgeted.dropped.first { $0.hasPrefix("done:") })
        XCTAssertNotNil(note, "a trimmed section is named")
        XCTAssertTrue(note?.contains("\(big.count - budgeted.done.count) of \(big.count)") ?? false)
    }

    func testGoalIsClippedLoudlyNeverSilently() {
        let b = brief(goal: pad("huge ", size: 20_000))
        let budgeted = b.budgeted()
        XCTAssertLessThan(
            HandoffBrief.estimateTokens(budgeted.renderedMarkdown()),
            HandoffBrief.budgetTokens + 64,
            "the rendered brief fits the budget (plus the marker itself)"
        )
        XCTAssertTrue(budgeted.goal?.text.contains("[clipped to fit the handoff budget]") ?? false)
        XCTAssertEqual(budgeted.goal?.line, 1, "clipping text never moves the citation")
        XCTAssertTrue(budgeted.dropped.contains { $0.hasPrefix("goal:") })
    }

    func testTheEstimatorIsTheDocumentedHeuristic() {
        XCTAssertEqual(HandoffBrief.estimateTokens(String(repeating: "a", count: 4000)), 1000)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `Core/`): `swift test --filter HandoffBriefBudgetTests`
Expected: FAIL to compile — `budgeted()`, `budgetTokens`, `estimateTokens` do not exist.

- [ ] **Step 3: Implement the budget**

Append to `HandoffBrief.swift`:

```swift
extension HandoffBrief {
    /// The brief's cap in tokens, provisional: brief quality on real working
    /// sessions is unmeasured (spec §"Evidence is one exploratory session"), so
    /// this is named and recorded like the 1% tolerance and the half-first
    /// threshold rather than presented as a tuned figure.
    public static let budgetTokens = 1500

    /// Tokens as an estimate: **UTF-8 bytes / 4**, stated as an estimate. This
    /// repo has no tokenizer, and a heuristic cap needs a heuristic measure —
    /// what must be exact is that the cap is applied and its drops are named.
    public static func estimateTokens(_ text: String) -> Int {
        text.utf8.count / 4
    }

    /// Enforces the budget by dropping whole sections/items in the spec's
    /// priority order — goal > next > done > files, with state last (spec §3
    /// lists state nowhere in the priority, and the closing turns are the most
    /// reconstructable section) — and clipping the goal last. Every drop is
    /// recorded in `dropped`; truncation is never silent.
    public func budgeted() -> HandoffBrief {
        var b = self
        func overBudget() -> Bool {
            Self.estimateTokens(b.renderedMarkdown()) > Self.budgetTokens
        }
        guard overBudget() else { return b }

        if !b.state.isEmpty {
            let count = b.state.count
            b.state = []
            b.dropped.append(
                "state: \(count) closing turns dropped (length budget; lowest priority)"
            )
            if !overBudget() { return b }
        }

        if !b.files.isEmpty {
            let count = b.files.count
            b.files = []
            b.dropped.append(
                "files: \(count) entries dropped (length budget; Done cites the same operations)"
            )
            if !overBudget() { return b }
        }

        let doneCount = b.done.count
        while !b.done.isEmpty && overBudget() {
            b.done.removeLast()
        }
        let removed = doneCount - b.done.count
        if removed > 0 {
            b.dropped.append(
                "done: \(removed) of \(doneCount) later entries dropped (length budget)"
            )
        }
        if !overBudget() { return b }

        if let item = b.next {
            b.next = nil
            b.dropped.append("next: \"\(item.text)\" dropped (length budget)")
            if !overBudget() { return b }
        }

        // The goal is the one thing never dropped — a brief without the user's
        // request is not a brief. It is clipped, and the clip says so.
        if let goal = b.goal {
            var text = goal.text
            while overBudget() && text.count > 64 {
                text = String(text.prefix(text.count / 2))
            }
            text += "… [clipped to fit the handoff budget]"
            b.goal = BriefItem(text: text, line: goal.line)
            b.dropped.append("goal: clipped to fit the length budget (its line is unchanged)")
        }
        return b
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run (from `Core/`): `swift test --filter HandoffBriefBudgetTests && swift test --filter HandoffBriefExtractorTests`
Expected: PASS (5 budget + 6 extractor).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PortmasterCore/History/HandoffBrief.swift \
        Core/Tests/PortmasterCoreTests/HandoffBriefBudgetTests.swift
git commit -m "feat: the brief names what the length budget dropped"
```

---

### Task 3: Store chain edges — handed off once, linked by observed PID

**Files:**
- Modify: `Core/Sources/PortmasterCore/History/AgentSessionStore.swift`
- Test: `Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift` (extend; the migration test at line 177 gains assertions)

**Interfaces:**
- Consumes: `SessionCost.usd`, existing `fetchSession`, `NSLock` discipline.
- Produces:
  - Model fields on `AgentSession`: `handedOffFrom: UUID?`, `handedOffTo: UUID?`, `handoffTargetPID: Int32?`, `handoffTargetName: String?`
  - `@discardableResult public func recordHandoff(sourceID: UUID, targetPID: Int32, targetName: String) throws -> Bool` — false when source missing or already handed off; no save (caller flushes).
  - `recordSession` additionally links: when the connecting row's `peerPID` equals some row's `handoffTargetPID` and neither side is linked, sets both edges in the same locked write (spec amendment 1).
  - `AgentSessionSnapshot` gains `handedOffFrom`, `handedOffTo`, `handoffTargetPID`, `handoffTargetName`, `chain: ChainReport?`
  - `public struct ChainShare { sessionID: UUID; label: String; usd: Decimal? }`
  - `public struct ChainReport { shares: [ChainShare]; totalUSD: Decimal?; var renderedLine: String }`

- [ ] **Step 1: Write the failing tests** (append a `// MARK: - Handoff chain` section to `AgentSessionStoreTests.swift`)

```swift
    // MARK: - Handoff chain

    func testASecondHandoffFromTheSameSessionIsRefused() throws {
        let store = try makeStore()
        let id = UUID()
        try store.recordSession(id: id, peerPID: 1, clientName: nil, clientVersion: nil,
                                connectedAt: Date())
        XCTAssertTrue(try store.recordHandoff(sourceID: id, targetPID: 4242, targetName: "codex"))
        XCTAssertFalse(try store.recordHandoff(sourceID: id, targetPID: 9999, targetName: "claude"),
                       "a session hands off once; a second spawn would fork the thread")
        let s = try XCTUnwrap(store.sessions().first { $0.id == id })
        XCTAssertEqual(s.handoffTargetPID, 4242, "the refused attempt must not overwrite the first")
        XCTAssertEqual(s.handoffTargetName, "codex")
        XCTAssertNil(s.handedOffTo, "an unarrived target leaves the edge absent, not zero")
    }

    func testAConnectingPeerPIDLinksBothSessionsInOneWrite() throws {
        let store = try makeStore()
        let sourceID = UUID(), targetID = UUID()
        try store.recordSession(id: sourceID, peerPID: 1, clientName: "a", clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 100))
        _ = try store.recordHandoff(sourceID: sourceID, targetPID: 4242, targetName: "codex")
        try store.recordSession(id: targetID, peerPID: 4242, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 200))
        try store.flush()

        let source = try XCTUnwrap(store.sessions().first { $0.id == sourceID })
        let target = try XCTUnwrap(store.sessions().first { $0.id == targetID })
        XCTAssertEqual(source.handedOffTo, targetID)
        XCTAssertEqual(target.handedOffFrom, sourceID)
        XCTAssertNil(source.handedOffFrom, "the head has no predecessor")
        XCTAssertNil(target.handedOffTo, "the tail has no successor yet")
    }

    func testAStaleTargetPIDThatNeverArrivesStaysUnlinked() throws {
        let store = try makeStore()
        let id = UUID()
        try store.recordSession(id: id, peerPID: 1, clientName: nil, clientVersion: nil,
                                connectedAt: Date())
        _ = try store.recordHandoff(sourceID: id, targetPID: 4242, targetName: "codex")
        let s = try XCTUnwrap(store.sessions().first { $0.id == id })
        XCTAssertNil(s.handedOffTo, "nobody arrived with that pid — an honest absence")
        XCTAssertNil(s.chain, "no observed link means no chain")
    }

    func testAnAlreadyLinkedTargetIsNotStolenByASecondClaim() throws {
        let store = try makeStore()
        let sourceID = UUID(), targetID = UUID(), otherID = UUID()
        try store.recordSession(id: sourceID, peerPID: 1, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 100))
        _ = try store.recordHandoff(sourceID: sourceID, targetPID: 4242, targetName: "codex")
        try store.recordSession(id: targetID, peerPID: 4242, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 200))
        try store.recordSession(id: otherID, peerPID: 4242, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 300))
        let target = try XCTUnwrap(store.sessions().first { $0.id == targetID })
        let other = try XCTUnwrap(store.sessions().first { $0.id == otherID })
        XCTAssertEqual(target.handedOffFrom, sourceID, "into-target is once only (amendment 2)")
        XCTAssertNil(other.handedOffFrom)
        let source = try XCTUnwrap(store.sessions().first { $0.id == sourceID })
        XCTAssertNil(source.handedOffTo, "the first link stands")
    }

    func testAChainReportsOneTotalWithEachShareItemised() throws {
        let store = try makeStore()
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")
        let sourceID = UUID(), targetID = UUID()
        try store.recordSession(id: sourceID, peerPID: 1, clientName: "Claude", clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 100))
        try store.recordUsage(TokenUsageRecord(
            sessionID: sourceID, recordedAt: Date(), input: 2_000_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        _ = try store.recordHandoff(sourceID: sourceID, targetPID: 4242, targetName: "codex")
        try store.recordSession(id: targetID, peerPID: 4242, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 200))
        try store.recordUsage(TokenUsageRecord(
            sessionID: targetID, recordedAt: Date(), input: 1_000_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        try store.flush()

        let source = try XCTUnwrap(store.sessions().first { $0.id == sourceID })
        let target = try XCTUnwrap(store.sessions().first { $0.id == targetID })
        let chain = try XCTUnwrap(source.chain)
        XCTAssertEqual(chain, target.chain, "both ends see the same chain")
        XCTAssertEqual(chain.shares.map(\.sessionID), [sourceID, targetID], "head first")
        XCTAssertEqual(chain.shares.map(\.label), ["Claude", "codex"],
                       "the tail is labelled by the target we spawned (ruling 2)")
        XCTAssertEqual(chain.totalUSD, Decimal(string: "0.003"),
                       "2,000,000 + 1,000,000 tokens at $0.000001")
        XCTAssertEqual(
            chain.renderedLine,
            "$0.003 · 2 sessions · Claude ($0.002) → codex ($0.001)"
        )
    }

    func testAChainWithOneUnpricedMemberHasNoTotalAtAll() throws {
        let store = try makeStore()
        try store.setPrice(Decimal(string: "0.000001")!, modelID: "m")
        let sourceID = UUID(), targetID = UUID()
        try store.recordSession(id: sourceID, peerPID: 1, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 100))
        try store.recordUsage(TokenUsageRecord(
            sessionID: sourceID, recordedAt: Date(), input: 1_000_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "m", provenance: .selfReported
        ))
        _ = try store.recordHandoff(sourceID: sourceID, targetPID: 4242, targetName: "codex")
        try store.recordSession(id: targetID, peerPID: 4242, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 200))
        try store.recordUsage(TokenUsageRecord(
            sessionID: targetID, recordedAt: Date(), input: 1_000_000, output: 0,
            cacheRead: nil, reasoning: nil, modelID: "unpriced", provenance: .selfReported
        ))
        try store.flush()

        let source = try XCTUnwrap(store.sessions().first { $0.id == sourceID })
        let chain = try XCTUnwrap(source.chain)
        XCTAssertNil(chain.totalUSD, "a partial total is the exact lie this repo exists to prevent")
        XCTAssertEqual(
            chain.renderedLine,
            "2 sessions · agent → codex · total not priced",
            "no dollars at all when the total is unknown — not a partial itemisation"
        )
    }

    func testAStandAloneSessionHasNoChain() throws {
        let store = try makeStore()
        let id = UUID()
        try store.recordSession(id: id, peerPID: 1, clientName: nil, clientVersion: nil,
                                connectedAt: Date())
        let s = try XCTUnwrap(store.sessions().first { $0.id == id })
        XCTAssertNil(s.chain)
    }
```

Note on `Fmt.usd`: the `$0.003` strings above assume `Fmt.usd` renders sub-dollar decimals verbatim (`"$0.003"` — its documented behaviour for `amount < 1`). If the exact expected string differs once run, fix the **expected literal** to the formatter's true output in the same commit and note it in the ledger; do not change `Fmt`.

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `Core/`): `swift test --filter AgentSessionStoreTests`
Expected: FAIL to compile — `recordHandoff`, `handoffTargetPID`, `chain`, `ChainReport` do not exist.

- [ ] **Step 3: Implement the store changes**

On `AgentSession`, after `tokensLeftWorst`:

```swift
    /// The session this one handed off to, set when a spawned target's PID
    /// connects back (spec §4, amendment 1). Nil is "not observed" — never a
    /// zero and never "no chain".
    public var handedOffFrom: UUID?
    /// The session that handed off to this one. The pair is written together,
    /// under the store's lock, in `recordSession`.
    public var handedOffTo: UUID?
    /// PID of the agent process this session spawned at handoff. Set once
    /// (`recordHandoff` refuses a second), read by the link in `recordSession`.
    public var handoffTargetPID: Int32?
    /// The configured target name that PID was spawned as ("codex"). Carried so
    /// the chain arrow can name the receiver: `clientName` is always nil on the
    /// socket path, because the MCP SDK consumes `initialize`.
    public var handoffTargetName: String?
```

On `AgentSessionSnapshot`, after `tokensLeftWorst`:

```swift
    public let handedOffFrom: UUID?
    public let handedOffTo: UUID?
    public let handoffTargetPID: Int32?
    public let handoffTargetName: String?
    /// The chain this session belongs to, computed across the whole table in
    /// `sessions()`; nil for a session with no observed handoff edge.
    public let chain: ChainReport?
```

After the `PriceComponent` enum (or anywhere at file scope in this file), add:

```swift
/// One session's share of a handoff chain, with the label the chain line shows.
public struct ChainShare: Equatable, Sendable {
    public let sessionID: UUID
    public let label: String
    /// Nil when this session's cost is unknown — an unpriced member, a
    /// conflict, or no usage. A nil share forces a nil chain total: a chain
    /// total is one figure or it is absent (ruling 4).
    public let usd: Decimal?
}

/// The observed thread: every session linked by handoff edges, head first,
/// with one total only when every member's cost is known.
public struct ChainReport: Equatable, Sendable {
    public let shares: [ChainShare]
    public let totalUSD: Decimal?

    /// `$3.42 · 2 sessions · Claude ($2.14) → Codex ($1.28)` (spec §4), or the
    /// no-total form that names the absence instead of leaving a hole.
    public var renderedLine: String {
        let names = shares.map(\.label).joined(separator: " → ")
        let count = shares.count
        guard let totalUSD else {
            return "\(count) sessions · \(names) · total not priced"
        }
        let itemised = shares.compactMap { share -> String? in
            share.usd.map { "\(share.label) (\(Fmt.usd($0)))" }
        }
        guard itemised.count == shares.count else {
            return "\(count) sessions · \(names) · total not priced"
        }
        return "\(Fmt.usd(totalUSD)) · \(count) sessions · "
            + itemised.joined(separator: " → ")
    }
}
```

`recordSession` becomes (replacing the whole function):

```swift
    public func recordSession(
        id: UUID, peerPID: Int32, clientName: String?, clientVersion: String?,
        connectedAt: Date
    ) throws {
        lock.lock(); defer { lock.unlock() }
        let session: AgentSession
        // Upsert by id: a reconnect reuses nothing, but a retried record must not
        // create a second row for one connection.
        if let existing = fetchSession(id) {
            existing.peerPID = peerPID
            existing.clientName = clientName
            existing.clientVersion = clientVersion
            session = existing
        } else {
            let created = AgentSession(
                id: id, peerPID: peerPID,
                clientName: clientName, clientVersion: clientVersion,
                connectedAt: connectedAt
            )
            context.insert(created)
            session = created
        }

        // The link, inside the same lock that guards every other invariant
        // (spec amendment 1): a connecting process whose pid is a recorded
        // handoff target claims the edge — both sides, one write. Once-only in
        // both directions: a source with `handedOffTo` set does not re-link, and
        // a target already claimed does not get a second predecessor (amendment 2).
        // Each node having at most one outgoing edge is what structurally
        // prevents cycles; no separate cycle check exists because none is needed.
        guard peerPID > 0,
              session.handedOffFrom == nil,
              let source = linkableSourceLocked(peerPID: peerPID),
              source.id != session.id
        else { return }
        source.handedOffTo = session.id
        session.handedOffFrom = source.id
    }

    /// The unlinked source row whose recorded target PID is `peerPID`, oldest
    /// claim first so a stale-PID collision is at least deterministic.
    private func linkableSourceLocked(peerPID: Int32) -> AgentSession? {
        let descriptor = FetchDescriptor<AgentSession>(
            predicate: #Predicate {
                $0.handoffTargetPID == peerPID && $0.handedOffTo == nil
            },
            sortBy: [SortDescriptor(\.connectedAt)]
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        return matches.first
    }
```

If `#Predicate` rejects the optional `Int32? == Int32` comparison, fall back to fetching all sessions and filtering in Swift (`$0.handoffTargetPID == peerPID && $0.handedOffTo == nil`) — the table is small, the lock already serialises it, and the comment says which form is in use.

Add after `recordPressure`:

```swift
    /// Records that `sourceID` spawned `targetPID` (spec amendment 1). The
    /// authoritative once-only check lives here, under the lock, not in a
    /// pre-check that could race a second handoff between read and spawn.
    ///
    /// Returns false when the source does not exist or has already handed off.
    /// No save: the coordinator flushes immediately after a successful launch,
    /// so a crash cannot leave a spawned agent unrecorded.
    @discardableResult
    public func recordHandoff(
        sourceID: UUID, targetPID: Int32, targetName: String
    ) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let source = fetchSession(sourceID) else { return false }
        guard source.handoffTargetPID == nil else { return false }
        source.handoffTargetPID = targetPID
        source.handoffTargetName = targetName
        return true
    }
```

`sessions()` — keep the fetches and the per-row map, then chain (replace the `return rows.map` statement):

```swift
        let snapshots = rows.map { row -> AgentSessionSnapshot in
            let records = recordsBySession[row.id] ?? []
            return AgentSessionSnapshot(
                id: row.id,
                peerPID: row.peerPID,
                clientName: row.clientName,
                clientVersion: row.clientVersion,
                connectedAt: row.connectedAt,
                endedAt: row.endedAt,
                tokensLeftFirst: row.tokensLeftFirst,
                tokensLeftWorst: row.tokensLeftWorst,
                handoffTargetPID: row.handoffTargetPID,
                handoffTargetName: row.handoffTargetName,
                handedOffFrom: row.handedOffFrom,
                handedOffTo: row.handedOffTo,
                usage: TokenUsage.aggregating(records),
                cost: costLocked(records: records, table: table),
                chain: nil
            )
        }
        return Self.chaining(snapshots)

    /// Attaches each linked session's `ChainReport` (spec §4). One walk per
    /// chain, memoised by head — recomputing per row would walk the same chain
    /// once per member on every read of a list that already batches its other
    /// queries for the same reason.
    static func chaining(_ snapshots: [AgentSessionSnapshot]) -> [AgentSessionSnapshot] {
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        var reports: [UUID: ChainReport] = [:]

        // Walk up to the head, then forward — both hops bounded by the table
        // size so a corrupt pair of pointers cannot spin under the store's read.
        func members(from id: UUID) -> [AgentSessionSnapshot] {
            guard var node = byID[id] else { return [] }
            var hops = 0
            while let from = node.handedOffFrom, hops <= snapshots.count,
                  let next = byID[from] {
                node = next
                hops += 1
            }
            var list = [node]
            hops = 0
            while let to = node.handedOffTo, hops <= snapshots.count,
                  let next = byID[to] {
                list.append(next)
                node = next
                hops += 1
            }
            return list
        }

        var output: [AgentSessionSnapshot] = []
        output.reserveCapacity(snapshots.count)
        for snapshot in snapshots {
            guard snapshot.handedOffFrom != nil || snapshot.handedOffTo != nil else {
                output.append(snapshot)
                continue
            }
            let chain = members(from: snapshot.id)
            guard chain.count > 1 else {
                output.append(snapshot)
                continue
            }
            let headID = chain[0].id
            let report = reports[headID] ?? Self.chainReport(chain)
            reports[headID] = report
            output.append(snapshot.withChain(report))
        }
        return output
    }

    static func chainReport(_ members: [AgentSessionSnapshot]) -> ChainReport {
        var shares: [ChainShare] = []
        shares.reserveCapacity(members.count)
        for (index, member) in members.enumerated() {
            // Head: whatever the session says about itself (today always
            // "agent", because the host never sees `initialize`). Tail: the
            // target name we spawned, which we do know (ruling 5).
            let label = index == 0
                ? (member.clientName ?? "agent")
                : (members[index - 1].handoffTargetName ?? member.clientName ?? "agent")
            shares.append(ChainShare(sessionID: member.id, label: label, usd: member.cost.usd))
        }
        let priced = shares.compactMap(\.usd)
        let total = priced.count == shares.count ? priced.reduce(0, +) : nil
        return ChainReport(shares: shares, totalUSD: total)
    }
```

Add to `AgentSessionSnapshot`:

```swift
    private func withChain(_ report: ChainReport?) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: id, peerPID: peerPID, clientName: clientName, clientVersion: clientVersion,
            connectedAt: connectedAt, endedAt: endedAt,
            tokensLeftFirst: tokensLeftFirst, tokensLeftWorst: tokensLeftWorst,
            handoffTargetPID: handoffTargetPID, handoffTargetName: handoffTargetName,
            handedOffFrom: handedOffFrom, handedOffTo: handedOffTo,
            usage: usage, cost: cost, chain: report
        )
    }
```

Extend the migration test `testAStoreWrittenBeforeTheFieldsExistedStillOpens` (line 177) — after the existing two nil assertions:

```swift
        XCTAssertNil(session?.handedOffFrom, "a pre-chain file has no edges, and nil is not a zero")
        XCTAssertNil(session?.handedOffTo)
        XCTAssertNil(session?.handoffTargetPID)
        XCTAssertNil(session?.handoffTargetName)
        XCTAssertNil(session?.chain, "no observed link is not an observed chain")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (from `Core/`): `swift test --filter AgentSessionStoreTests`
Expected: PASS (existing tests + 7 new; the migration test gains 5 assertions). If the `$0.003`-style money strings disagree with `Fmt.usd`, correct the expected literals only (ruling note in the ledger).

- [ ] **Step 5: Commit**

```bash
git add Core/Sources/PortmasterCore/History/AgentSessionStore.swift \
        Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift
git commit -m "feat: a session remembers where its work was handed to"
```

---

### Task 4: The wire and the sessions card carry the chain

**Files:**
- Modify: `Core/Sources/PortmasterMCP/WirePayloads.swift` (`AgentSessionPayload`)
- Modify: `App/OverviewView.swift` (`SessionLine`)
- Test: `Core/Tests/PortmasterMCPTests/AgentSessionToolTests.swift` (extend)
- Test: `Core/Tests/PortmasterCoreTests/AppHandoffWiringTests.swift` (new source-scan file)

**Interfaces:**
- Consumes: `AgentSessionSnapshot.chain`, `ChainReport.renderedLine` (Task 3).
- Produces: wire fields `handedOffFrom`/`handedOffTo` (UUID strings, omitted when nil); `SessionLine` renders `chain.renderedLine` as a second line **only** on the head row.

- [ ] **Step 1: Write the failing wire test** (append to `AgentSessionToolTests.swift`)

```swift
    // MARK: - Chain edges

    func testHandoffEdgesReachTheWireAndUnlinkedSessionsOmitThem() async throws {
        let sourceID = UUID(), targetID = UUID(), loneID = UUID()
        try store.recordSession(id: sourceID, peerPID: 1, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 100))
        try store.flush()
        _ = try store.recordHandoff(sourceID: sourceID, targetPID: 4242, targetName: "codex")
        try store.recordSession(id: targetID, peerPID: 4242, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 200))
        try store.recordSession(id: loneID, peerPID: 7, clientName: nil, clientVersion: nil,
                                connectedAt: Date(timeIntervalSince1970: 300))
        try store.flush()

        let json = try await wire()
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])

        let source = try XCTUnwrap(sessions.first { $0["id"] as? String == sourceID.uuidString })
        XCTAssertEqual(source["handedOffTo"] as? String, targetID.uuidString)
        XCTAssertNil(source["handedOffFrom"])
        XCTAssertNil(source["handoffTargetPID"], "the wire carries edges, not spawn plumbing")

        let target = try XCTUnwrap(sessions.first { $0["id"] as? String == targetID.uuidString })
        XCTAssertEqual(target["handedOffFrom"] as? String, sourceID.uuidString)
        XCTAssertNil(target["handedOffTo"])

        let lone = try XCTUnwrap(sessions.first { $0["id"] as? String == loneID })
        XCTAssertNil(lone["handedOffFrom"], "absent key, not null and not zero")
        XCTAssertNil(lone["handedOffTo"])
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run (from `Core/`): `swift test --filter AgentSessionToolTests`
Expected: FAIL — payload has no `handedOffTo` key (assertion 1 fails or key missing).

- [ ] **Step 3: Implement the wire fields and the card line**

In `WirePayloads.swift`, `AgentSessionPayload` — after `tokensLeftWorst`:

```swift
    /// Chain edges (spec §4). Omitted when nil: an unlinked session has no
    /// edge, and a JSON `null` here would read as "chain known to be absent"
    /// rather than "not linked" — the same rule as every other optional.
    let handedOffFrom: String?
    let handedOffTo: String?
```

In `init(_ session: AgentSessionSnapshot, isOpen:)`:

```swift
        self.handedOffFrom = session.handedOffFrom?.uuidString
        self.handedOffTo = session.handedOffTo?.uuidString
```

In `App/OverviewView.swift`, `SessionLine` — wrap the existing `HStack` in a `VStack` and add the head-only chain line (ruling 3):

```swift
private struct SessionLine: View {
    let session: AgentSessionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.clientName ?? "agent")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(usage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(cost)
                    .font(.system(size: 10, design: .monospaced))
            }
            // The head renders the whole thread's line; middle and tail rows
            // stay single — one report per chain, placed where the oldest-first
            // footer is guaranteed to show it (ruling 3).
            if session.handedOffFrom == nil, let chain = session.chain {
                Text(chain.renderedLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel("Handoff chain: \(chain.renderedLine)")
            }
        }
    }
    // `usage` and `cost` computed properties unchanged.
}
```

(The `usage`/`cost` private computed properties below `body` are untouched.)

- [ ] **Step 4: Write the failing source-scan test**

```swift
// Core/Tests/PortmasterCoreTests/AppHandoffWiringTests.swift
// The App half of the handoff wiring, asserted from source — there is no App
// test target (`project.yml` declares the app and the Core package only), so
// the mechanism is the one `AppAgentSourceWiringTests` established: strip
// comments, fail loudly when a file is missing, pin each marker's occurrence
// count so a rename fails the claim instead of passing over nothing.
//
// What this proves: where the code is. It does not prove the sheet opens or a
// handoff runs — those are coordinator/MCP tests in PortmasterMCPTests.

import Foundation
import XCTest

final class AppHandoffWiringTests: XCTestCase {

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(
        _ relativePath: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> String {
        let url = Self.repositoryRoot.appendingPathComponent(relativePath)
        let text = try? String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(
            text.map(Self.withoutComments),
            "\(relativePath) was not found at \(url.path) — the scan would pass over nothing",
            file: file, line: line
        )
    }

    private func occurrences(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testTheSessionsCardRendersOneChainLineOnTheHeadOnly() throws {
        let overview = try source("App/OverviewView.swift")
        XCTAssertEqual(
            occurrences("chain.renderedLine", in: overview), 1,
            "the chain line has exactly one render site"
        )
        XCTAssertEqual(
            occurrences("session.handedOffFrom == nil", in: overview), 1,
            "rendered exactly where the head is identified — a second site would duplicate the report"
        )
        XCTAssertTrue(
            occurrences("struct SessionLine", in: overview) >= 1,
            "the row the chain line hangs on must exist"
        )
    }

    /// Comments stripped first, so a doc comment mentioning the marker cannot
    /// satisfy its own claim.
    private static func withoutComments(_ text: String) -> String {
        var out = ""
        var inBlock = false
        var inString = false
        var previous: Character? = nil
        for character in text {
            if inBlock {
                if character == "*" && previous == "/" { inBlock = false; previous = nil; continue }
                if character == "/" && previous == "*" { inBlock = false; previous = nil; continue }
                if character == "\n" { out.append(character) }
                previous = character
                continue
            }
            if !inString && character == "/" && previous == "/" {
                inBlock = true  // reused as line-or-block: see below
                // Handle `//` line comments: consume until newline.
                // (Implemented as: mark and skip.)
                previous = character
                continue
            }
            if character == "\"" { inString.toggle() }
            out.append(character)
            previous = character
        }
        return out
    }
}
```

The sketch above is not shippable — line comments must be consumed to end of line. Write the real helper by copying `withoutComments` **verbatim** from `Core/Tests/PortmasterCoreTests/AppAgentSourceWiringTests.swift` (it already handles `//`, `/* */`, and string literals, and its proven behaviour is the point: two different copies of this helper must behave identically or the two scan suites disagree about what "in the source" means).

- [ ] **Step 5: Run both tests to verify they pass**

Run (from `Core/`): `swift test --filter AgentSessionToolTests && swift test --filter AppHandoffWiringTests`
Expected: PASS.

- [ ] **Step 6: Compile the app (the card change lives in App/)**

Run: `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build`
Expected: **BUILD SUCCEEDED**, zero new warnings (six pre-existing warnings in untouched files are fine).

- [ ] **Step 7: Commit**

```bash
git add Core/Sources/PortmasterMCP/WirePayloads.swift \
        App/OverviewView.swift \
        Core/Tests/PortmasterMCPTests/AgentSessionToolTests.swift \
        Core/Tests/PortmasterCoreTests/AppHandoffWiringTests.swift
git commit -m "feat: the wire and the sessions card say where the work went"
```

---

### Task 5: Launching — invocation is configuration, the brief rides stdin

**Files:**
- Create: `Core/Sources/PortmasterMCP/HandoffTargets.swift`
- Create: `Core/Sources/PortmasterMCP/HandoffLauncher.swift`
- Test: `Core/Tests/PortmasterMCPTests/HandoffTargetsTests.swift`
- Test: `Core/Tests/PortmasterMCPTests/HandoffLauncherTests.swift`

**Interfaces:**
- Consumes: `MCPSettings.defaultDirectory`.
- Produces:
  - `public struct HandoffTarget: Codable, Equatable, Sendable { executable: String; arguments: [String] }`
  - `public enum HandoffTargets { public static let defaults: [String: HandoffTarget]; public static let fileName: String; public static func load(directory: URL?) -> [String: HandoffTarget] }`
  - `public protocol HandoffLaunching: Sendable { func resolve(_ executable: String, path: String?) -> String?; func launch(executable: String, arguments: [String], workingDirectory: String, stdinText: String) throws -> Int32; func terminate(pid: Int32) }`
  - `public struct SystemHandoffLauncher: HandoffLaunching`

- [ ] **Step 1: Write the failing target-config tests**

```swift
// Core/Tests/PortmasterMCPTests/HandoffTargetsTests.swift
import XCTest
import Foundation
import PortmasterCore
import PortmasterMCP

final class HandoffTargetsTests: XCTestCase {

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("targets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testDefaultsOfferTheTwoAgentsTheSpecNames() {
        let targets = HandoffTargets.load(directory: URL(fileURLWithPath: "/nonexistent"))
        XCTAssertEqual(Set(targets.keys), ["claude", "codex"])
        XCTAssertEqual(targets["claude"]?.executable, "claude")
        XCTAssertEqual(targets["codex"]?.executable, "codex")
        XCTAssertEqual(targets["codex"]?.arguments, [],
                       "invocation shapes are assumed, not confirmed (spec) — bare CLI, brief on stdin")
    }

    func testAValidFileOverridesTheDefaults() throws {
        let dir = try temporaryDirectory()
        let json = #"{"gemini":{"executable":"/opt/gemini/bin/gem","arguments":["--yolo"]}}"#
        try json.write(
            to: dir.appendingPathComponent(HandoffTargets.fileName),
            atomically: true, encoding: .utf8
        )
        let targets = HandoffTargets.load(directory: dir)
        XCTAssertEqual(Set(targets.keys), ["gemini"], "a file that decodes replaces the map")
        XCTAssertEqual(targets["gemini"]?.executable, "/opt/gemini/bin/gem")
        XCTAssertEqual(targets["gemini"]?.arguments, ["--yolo"])
    }

    func testAnUnreadableOrEmptyFileFallsBackToDefaults() throws {
        let dir = try temporaryDirectory()
        let url = dir.appendingPathComponent(HandoffTargets.fileName)
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(HandoffTargets.load(directory: dir).keys), ["claude", "codex"])
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(Set(HandoffTargets.load(directory: dir).keys), ["claude", "codex"],
                       "an empty map is nobody's configuration, not every target removed")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run (from `Core/`): `swift test --filter HandoffTargetsTests`
Expected: FAIL to compile — `HandoffTargets` does not exist.

- [ ] **Step 3: Implement target configuration**

```swift
// Core/Sources/PortmasterMCP/HandoffTargets.swift
import Foundation

/// How to start one receiving agent. Configuration, not code: the spec's §6
/// promise is that adding an agent is a config entry, and the exact shapes are
/// **assumed rather than confirmed** against installed CLIs (spec, "Not
/// verified") — so they belong somewhere an edit fixes, not a rebuild.
public struct HandoffTarget: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public init(executable: String, arguments: [String] = []) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum HandoffTargets {
    /// Key → target. The key is what `handoff_context`'s `target` argument and
    /// the affordance's picker say, and it is what the chain line shows for the
    /// spawned side (ruling 2).
    public static let defaults: [String: HandoffTarget] = [
        "claude": HandoffTarget(executable: "claude"),
        "codex": HandoffTarget(executable: "codex"),
    ]

    public static let fileName = "handoff-targets.json"

    /// The file's map when it exists, decodes, and is non-empty; the defaults
    /// otherwise. Read per handoff, the same way this repo reads settings per
    /// call, so a corrected file takes effect without restarting anything.
    public static func load(directory: URL? = nil) -> [String: HandoffTarget] {
        let dir = directory ?? MCPSettings.defaultDirectory
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: HandoffTarget].self, from: data),
              !map.isEmpty
        else { return defaults }
        return map
    }
}
```

- [ ] **Step 4: Write the failing launcher tests**

```swift
// Core/Tests/PortmasterMCPTests/HandoffLauncherTests.swift
import XCTest
import Foundation
import PortmasterMCP

final class HandoffLauncherTests: XCTestCase {

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testResolveFindsAnExecutableOnAGivenPath() throws {
        let dir = try temporaryDirectory()
        let stub = dir.appendingPathComponent("agentx")
        try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let launcher = SystemHandoffLauncher()
        XCTAssertEqual(launcher.resolve("agentx", path: dir.path), stub.path)
        XCTAssertNil(launcher.resolve("not-installed-xyz", path: dir.path),
                     "a missing CLI is a fact the handoff must be able to report")
    }

    func testResolveAcceptsAnAbsolutePathThatExists() throws {
        let launcher = SystemHandoffLauncher()
        XCTAssertEqual(launcher.resolve("/bin/sh", path: "/nowhere"), "/bin/sh")
        XCTAssertNil(launcher.resolve("/definitely/not/here", path: "/nowhere"))
    }

    /// The brief arrives on stdin: `/bin/sh -c 'cat > file'` is the receiving
    /// agent in miniature, and the file is the assertion.
    func testTheBriefRidesStdinToTheChild() throws {
        let dir = try temporaryDirectory()
        let received = dir.appendingPathComponent("received.txt")
        let launcher = SystemHandoffLauncher()

        _ = try launcher.launch(
            executable: "/bin/sh",
            arguments: ["-c", "cat > \(received.path)"],
            workingDirectory: dir.path,
            stdinText: "# Handoff brief\n\n## Goal\ndo the thing (line 1)\n"
        )

        let deadline = Date().addingTimeInterval(5)
        var content = ""
        while Date() < deadline {
            content = (try? String(contentsOf: received, encoding: .utf8)) ?? ""
            if content.contains("do the thing") { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(content.contains("## Goal\ndo the thing (line 1)"),
                      "the receiving agent reads the brief from stdin, verbatim")
    }

    func testAMissingWorkingDirectoryIsRefusedNotGuessed() throws {
        let launcher = SystemHandoffLauncher()
        XCTAssertThrowsError(try launcher.launch(
            executable: "/bin/sh", arguments: ["-c", "true"],
            workingDirectory: "/definitely/not/a/dir-\(UUID().uuidString)",
            stdinText: "x"
        )) { error in
            XCTAssertTrue("\(error)".contains("working directory"), "the refusal names the fact")
        }
    }
}
```

- [ ] **Step 5: Run to verify failure**

Run (from `Core/`): `swift test --filter HandoffLauncherTests`
Expected: FAIL to compile — `SystemHandoffLauncher` does not exist.

- [ ] **Step 6: Implement the launcher**

```swift
// Core/Sources/PortmasterMCP/HandoffLauncher.swift
import Darwin
import Foundation

/// The process seam a handoff needs and the docker path does not: the brief on
/// stdin, a real working directory, a pid back for the chain, and the ability
/// to terminate a spawn whose bookkeeping then refused it. `ProcessRunning` is
/// deliberately not widened — it nulls stdin (spec amendment 7) and its other
/// callers have no use for any of this.
public protocol HandoffLaunching: Sendable {
    /// Absolute path of `executable`, searched on `path` (`$PATH` when nil),
    /// or nil when it is not installed — the fact §6 requires the failure to
    /// carry.
    func resolve(_ executable: String, path: String?) -> String?
    /// Starts the process with `stdinText` written to its stdin and stdin then
    /// closed (EOF after the brief), in `workingDirectory`. Returns the pid
    /// without waiting for exit — the agent runs for hours.
    func launch(
        executable: String, arguments: [String],
        workingDirectory: String, stdinText: String
    ) throws -> Int32
    func terminate(pid: Int32)
}

public struct SystemHandoffLauncher: HandoffLaunching {
    public init() {}

    public func resolve(_ executable: String, path: String?) -> String? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        let search = path ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in search.split(separator: ":") {
            let candidate = "\(directory)/\(executable)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public func launch(
        executable: String, arguments: [String],
        workingDirectory: String, stdinText: String
    ) throws -> Int32 {
        guard FileManager.default.fileExists(atPath: workingDirectory) else {
            throw MCPToolError(
                message: "The working directory \(workingDirectory) no longer exists."
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw MCPToolError(
                message: "Could not start \(executable): \(error.localizedDescription)"
            )
        }
        do {
            // Brief, then EOF: the agent reads its prompt from stdin and keeps
            // its own TTY for the conversation (spec §6).
            try input.fileHandleForWriting.write(Data(stdinText.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw MCPToolError(
                message: "Could not deliver the brief to \(executable): \(error.localizedDescription)"
            )
        }
        let pid = process.processIdentifier
        // Reap without waiting: the task's strong capture keeps the `Process`
        // alive until the child exits, so no zombie and no blocked tool call.
        Task.detached(priority: .utility) { _ = process.waitUntilExit() }
        return pid
    }

    public func terminate(pid: Int32) {
        kill(pid, SIGTERM)
    }
}
```

- [ ] **Step 7: Run both suites to verify they pass**

Run (from `Core/`): `swift test --filter HandoffTargetsTests && swift test --filter HandoffLauncherTests`
Expected: PASS (3 + 4 tests).

- [ ] **Step 8: Commit**

```bash
git add Core/Sources/PortmasterMCP/HandoffTargets.swift \
        Core/Sources/PortmasterMCP/HandoffLauncher.swift \
        Core/Tests/PortmasterMCPTests/HandoffTargetsTests.swift \
        Core/Tests/PortmasterMCPTests/HandoffLauncherTests.swift
git commit -m "feat: an agent is launched by configuration, with the brief on stdin"
```

---

### Task 6: The coordinator and `handoff_context` — dry run, gate, audit, kill switch

**Files:**
- Create: `Core/Sources/PortmasterMCP/HandoffCoordinator.swift`
- Modify: `Core/Sources/PortmasterCore/Models/Preferences.swift` (`contextHandoffsEnabled`)
- Modify: `Core/Sources/PortmasterCore/History/AgentLogMatcher.swift` (`defaultOverlap`)
- Modify: `Core/Sources/PortmasterCore/History/AgentSourcePoller.swift` (init default → `AgentLogMatcher.defaultOverlap`)
- Modify: `Core/Sources/PortmasterMCP/ToolExecutor.swift` (catalog, dispatch, `sessionUUID`, `MCPAuditNoting`, success audit)
- Modify: `Core/Sources/PortmasterMCP/DataProvider.swift`, `LiveDataProvider.swift`, `OnDemandProvider.swift`
- Modify: `Core/Sources/PortmasterMCP/HostMCPCallContext.swift` (`request(for:)` case)
- Modify: `Core/Sources/PortmasterMCP/ConfirmationBroker.swift` (`Kind.handoffContext`)
- Modify: `Core/Sources/PortmasterMCP/MCPApprovalCopy.swift` (four switches)
- Modify: `App/MCPConfirmationWindow.swift` (`resolve(_:)` case; the window validates a handoff before a person is asked, like every other kind)
- Modify: `App/MCPHostController.swift` (`needsReading` case — a handoff resolves no processes)
- Tests: `Core/Tests/PortmasterCoreTests/AppPreferencesHandoffTests.swift` (new)
- Tests: `Core/Tests/PortmasterMCPTests/HandoffCoordinatorTests.swift` (new)
- Tests: extend `ToolExecutorMutationTests.swift`, `ToolExecutorReadTests.swift` (17→18), `MCPHostServerTests.swift` (17→18 ×2), `MCPApprovalPresentationTests.swift` (`sampleArguments`), `LiveDataProviderTests.swift`

**Interfaces:**
- Consumes: Tasks 1/2 (brief), Task 3 (store), Task 5 (targets/launcher), `AgentLogMatcher.match`, `ClaudeCodeLogAdapter`, `PermissionGate`/`AuditLog` (unchanged machinery), `AppPreferences`.
- Produces:
  - `public struct HandoffOutcome: Sendable, Equatable { briefPath: String; citedLines: [Int]; launchedPID: Int32; target: String; public var auditNote: String; public init(...) }`
  - `public struct HandoffCoordinator: Sendable { public init(store:adapter:launcher:defaults:handoffDirectory:); public func handoff(sessionID: UUID, target: String) throws -> HandoffOutcome }`
  - DataProvider: `func handoffContext(sessionID: UUID, target: String) async throws -> HandoffOutcome`
  - Catalog tool `handoff_context` (mutation; args `session_id`, `target`, both required)

- [ ] **Step 1: Write the failing kill-switch tests**

```swift
// Core/Tests/PortmasterCoreTests/AppPreferencesHandoffTests.swift
import XCTest
import Foundation
@testable import PortmasterCore

final class AppPreferencesHandoffTests: XCTestCase {

    func testHandoffsAreOnWhenTheKeyWasNeverWritten() throws {
        let defaults = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "") }
        let decoded = AppPreferences.load(from: defaults)
        XCTAssertTrue(decoded.contextHandoffsEnabled,
                      "the kill switch exists to be turned off, so its default is on")
    }

    func testTheKillSwitchSurvivesARoundTrip() throws {
        let defaults = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        var prefs = AppPreferences()
        prefs.contextHandoffsEnabled = false
        prefs.save(to: defaults)
        XCTAssertFalse(AppPreferences.load(from: defaults).contextHandoffsEnabled)
    }

    func testAnUnknownNewerValueDoesNotResetTheOtherPreferences() throws {
        // A blob written by a future build where the key is a string: the
        // decode must survive the way every other preference does.
        let defaults = UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!
        var prefs = AppPreferences()
        prefs.alertsEnabled = false
        prefs.save(to: defaults)
        var data = try XCTUnwrap(defaults.data(forKey: AppPreferences.defaultsKey))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["contextHandoffsEnabled"] = "on"  // wrong type for this build
        data = try JSONSerialization.data(withJSONObject: json)
        defaults.set(data, forKey: AppPreferences.defaultsKey)
        let decoded = AppPreferences.load(from: defaults)
        XCTAssertFalse(decoded.alertsEnabled, "the rest of the blob still decodes")
        XCTAssertTrue(decoded.contextHandoffsEnabled,
                      "an unreadable value reads as absent, and absent means the switch stays on")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run (from `Core/`): `swift test --filter AppPreferencesHandoffTests`
Expected: FAIL to compile — `contextHandoffsEnabled` does not exist.

- [ ] **Step 3: Implement the kill-switch preference**

In `Core/Sources/PortmasterCore/Models/Preferences.swift` (`AppPreferences`):
- Add field after `showInDock`:
```swift
    /// Whether a pressured session may hand off to another agent at all — the
    /// spec's kill switch (§5): an off switch that stops the feature without
    /// touching permissions. Default on: the permission mode is the real gate
    /// (handoffs still require `allowSession`), so this is the big red button,
    /// not the lock.
    public var contextHandoffsEnabled: Bool
```
- Init parameter `contextHandoffsEnabled: Bool = true` + `self.contextHandoffsEnabled = contextHandoffsEnabled`.
- `CodingKeys`: add `contextHandoffsEnabled`.
- `init(from decoder:)`:
```swift
        contextHandoffsEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .contextHandoffsEnabled
        ) ?? true
```

Re-run: `swift test --filter AppPreferencesHandoffTests` → PASS (3).

- [ ] **Step 4: Write the failing coordinator tests**

```swift
// Core/Tests/PortmasterMCPTests/HandoffCoordinatorTests.swift
import XCTest
import Foundation
import PortmasterCore
@testable import PortmasterMCP

/// The coordinator's flow: dry run before launch, refusals that name their
/// reason, the brief written before anything spawns, and the once-only record.
final class HandoffCoordinatorTests: XCTestCase {

    private final class FakeLauncher: HandoffLaunching, @unchecked Sendable {
        var resolveResult: ((String) -> String?)?
        private(set) var launches: [(executable: String, arguments: [String], cwd: String, stdin: String)] = []
        private(set) var terminated: [Int32] = []
        var nextPID: Int32 = 4242

        func resolve(_ executable: String, path: String?) -> String? {
            resolveResult?(executable) ?? executable
        }

        func launch(
            executable: String, arguments: [String],
            workingDirectory: String, stdinText: String
        ) throws -> Int32 {
            launches.append((executable, arguments, workingDirectory, stdinText))
            return nextPID
        }

        func terminate(pid: Int32) { terminated.append(pid) }
    }

    private final class Harness {
        let root: URL
        let projectsRoot: URL
        let handoffDir: URL
        let store: AgentSessionStore
        let launcher: FakeLauncher
        let defaults: UserDefaults
        let sessionID = UUID()
        let connectedAt = Date(timeIntervalSinceNow: -100)
        let workingDir: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
            projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
            handoffDir = root.appendingPathComponent("handoffs", isDirectory: true)
            workingDir = root.appendingPathComponent("work", isDirectory: true)
            for dir in [projectsRoot, handoffDir, workingDir] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            store = try AgentSessionStore(
                storeURL: root.appendingPathComponent("sessions.sqlite")
            )
            launcher = FakeLauncher()
            defaults = UserDefaults(suiteName: "handoff-\(UUID().uuidString)")!
        }

        func writeLog(_ lines: [String]) throws -> URL {
            let dir = projectsRoot.appendingPathComponent("-tmp-work", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(sessionID.uuidString).jsonl")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        }

        func recordSession() throws {
            try store.recordSession(
                id: sessionID, peerPID: 1, clientName: nil, clientVersion: nil,
                connectedAt: connectedAt
            )
            try store.flush()
        }

        func makeCoordinator() throws -> HandoffCoordinator {
            HandoffCoordinator(
                store: store,
                adapter: ClaudeCodeLogAdapter(projectsRoot: projectsRoot),
                launcher: launcher,
                defaults: defaults,
                handoffDirectory: handoffDir
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation()["SuiteName"] as? String ?? "")
        }
    }

    /// Timestamps spread around `connectedAt` so the conversation's interval
    /// contains the connection (AgentLogMatcher's rule), all in the past so
    /// nothing reads as a future clock artefact. Line numbers are the fixture's.
    private func fixture(workingDir: String, withCwd: Bool = true) -> [String] {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func ts(_ offset: TimeInterval) -> String {
            fmt.string(from: Date(timeIntervalSinceNow: offset))
        }
        let cwdField = withCwd ? #","#cwd":"\#(workingDir)""# : ""
        return [
            #"{"type":"user","timestamp":"\#(ts(-120))"\#(cwdField),"message":{"role":"user","content":"Fix the flaky retry test."}}"#,
            #"{"type":"assistant","timestamp":"\#(ts(-115))","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"assistant","timestamp":"\#(ts(-110))","message":{"role":"assistant","content":[{"type":"text","text":"Running the tests now."}]}}"#,
        ]
    }

    func testHappyPathWritesTheBriefThenLaunchesThenRecords() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        let coordinator = try h.makeCoordinator()

        let outcome = try coordinator.handoff(sessionID: h.sessionID, target: "codex")

        XCTAssertEqual(outcome.launchedPID, 4242)
        XCTAssertEqual(outcome.target, "codex")
        let brief = try String(contentsOf: URL(fileURLWithPath: outcome.briefPath), encoding: .utf8)
        XCTAssertTrue(brief.contains("## Goal\nFix the flaky retry test. (line 1)"))
        XCTAssertTrue(brief.contains("Working directory: \(h.workingDir.path)"))
        XCTAssertEqual(outcome.citedLines, [1, 2, 3])
        XCTAssertEqual(h.launcher.launches.count, 1)
        XCTAssertEqual(h.launcher.launches[0].cwd, h.workingDir.path)
        XCTAssertTrue(h.launcher.launches[0].stdin.contains("## Goal"),
                      "the brief is what the agent reads, not a path it must go fetch")

        // The record survives a reopen: a crash after launch must not orphan the chain.
        let reopened = try AgentSessionStore(storeURL: h.root.appendingPathComponent("sessions.sqlite"))
        let snapshot = try XCTUnwrap(reopened.sessions().first { $0.id == h.sessionID })
        XCTAssertEqual(snapshot.handoffTargetPID, 4242)
        XCTAssertEqual(snapshot.handoffTargetName, "codex")
    }

    func testTheKillSwitchRefusesBeforeAnythingHappens() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        var prefs = AppPreferences()
        prefs.contextHandoffsEnabled = false
        prefs.save(to: h.defaults)
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            XCTAssertTrue("\($0)".contains("disabled in Portmaster settings"))
        }
        XCTAssertEqual(h.launcher.launches.count, 0, "a disabled feature spawns nothing")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: h.handoffDir.path).count, 0,
            "and writes nothing"
        )
    }

    func testAnUnknownTargetNamesTheOnesThatExist() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "gpt9")) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("Unknown handoff target"))
            XCTAssertTrue(message.contains("claude"), "the refusal teaches the valid values")
            XCTAssertTrue(message.contains("codex"))
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
    }

    func testASecondHandoffIsRefusedAndNothingSpawns() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        let coordinator = try h.makeCoordinator()
        _ = try coordinator.handoff(sessionID: h.sessionID, target: "codex")

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "claude")) {
            XCTAssertTrue("\($0)".contains("already handed off"))
        }
        XCTAssertEqual(h.launcher.launches.count, 1, "the thread forks only once")
    }

    func testALogWithNoCwdSavesTheBriefThenRefusesToLaunch() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: "", withCwd: false))
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("working directory"), "the refusal names the fact")
            XCTAssertTrue(message.contains("brief was saved"), "…and offers the brief (§6)")
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: h.handoffDir.path),
            ["\(h.sessionID.uuidString).md"],
            "the dry run produced the brief even though the launch did not happen"
        )
    }

    func testAMissingCLISavesTheBriefThenFailsWithThatReason() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog(fixture(workingDir: h.workingDir.path))
        h.launcher.resolveResult = { _ in nil }
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("not installed"), "§6: fails with that reason")
            XCTAssertTrue(message.contains("brief was saved"))
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
    }

    func testAnUnsourcedLogIsRefusedWithNothingWritten() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        _ = try h.writeLog([
            #"{"type":"system","message":"booting"}"#,
            #"{"type":"mode","mode":"plan"}"#,
        ])
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            XCTAssertTrue("\($0)".contains("nothing to hand off"), "§5: refuse an unsourced brief")
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: h.handoffDir.path)) ?? []
        XCTAssertTrue(contents.isEmpty, "a brief we cannot cite is never written")
    }

    func testNoMatchingLogIsRefusedBeforeExtraction() throws {
        let h = try Harness()
        defer { h.cleanup() }
        try h.recordSession()
        // projectsRoot exists but holds no logs at all.
        let coordinator = try h.makeCoordinator()

        XCTAssertThrowsError(try coordinator.handoff(sessionID: h.sessionID, target: "codex")) {
            XCTAssertTrue("\($0)".contains("not uniquely attributable"))
        }
        XCTAssertEqual(h.launcher.launches.count, 0)
    }
}
```

- [ ] **Step 5: Run to verify failure**

Run (from `Core/`): `swift test --filter HandoffCoordinatorTests`
Expected: FAIL to compile — `HandoffCoordinator` does not exist.

- [ ] **Step 6: Implement the overlap constant and the coordinator**

`AgentLogMatcher.swift` (top of the enum):

```swift
    /// How far outside a session's connect moment a conversation's interval may
    /// reach and still match it. One authority: the poller's default and the
    /// handoff coordinator's re-match both reference this, because two call
    /// sites drifting on the tolerance would match different files to the same
    /// session depending on which path asked (ruling 15).
    public static let defaultOverlap: TimeInterval = 60 * 60
```

`AgentSourcePoller.swift` init — change only the default:

```swift
        overlap: TimeInterval = AgentLogMatcher.defaultOverlap,
```

`Core/Sources/PortmasterMCP/HandoffCoordinator.swift`:

```swift
import Foundation
import PortmasterCore

/// Everything one completed handoff did, for the caller and for the audit line.
/// The brief's path rather than its text: an audit line cites where to read
/// (spec amendment 6), never a multi-KB document as an argument value.
public struct HandoffOutcome: Sendable, Equatable {
    public let briefPath: String
    /// Physical source lines the brief cites — the audit's `lines=` tail.
    public let citedLines: [Int]
    public let launchedPID: Int32
    public let target: String

    public init(briefPath: String, citedLines: [Int], launchedPID: Int32, target: String) {
        self.briefPath = briefPath
        self.citedLines = citedLines
        self.launchedPID = launchedPID
        self.target = target
    }

    /// `brief=<path> lines=<n,…>` — the whole audit note, bounded at 20 line
    /// numbers plus a count so one line stays one line (AuditLog's own rule for
    /// arguments applies here in spirit: bounded and marked, never silently cut).
    public var auditNote: String {
        let listed = citedLines.prefix(20).map(String.init).joined(separator: ",")
        let more = citedLines.count > 20 ? ",+\(citedLines.count - 20) more" : ""
        return "brief=\(briefPath) lines=\(listed)\(more)"
    }
}

/// Spec §5's sequence, in order, and every refusal along it:
/// kill switch → session → target config → uniquely matched log → extract →
/// budget → **write the brief** (the dry run) → cwd exists → CLI installed →
/// spawn → record under the lock (terminate on refusal). A generation failure
/// cannot produce a launch because the launch is after the brief; an empty or
/// unsourced brief cannot produce a file because the citation check is before
/// the write.
public struct HandoffCoordinator: Sendable {
    private let store: AgentSessionStore
    private let adapter: any TokenSourceAdapter
    private let launcher: any HandoffLaunching
    private let defaults: UserDefaults
    private let handoffDirectory: URL

    public init(
        store: AgentSessionStore,
        adapter: any TokenSourceAdapter = ClaudeCodeLogAdapter(),
        launcher: any HandoffLaunching = SystemHandoffLauncher(),
        defaults: UserDefaults = .standard,
        handoffDirectory: URL? = nil
    ) {
        self.store = store
        self.adapter = adapter
        self.launcher = launcher
        self.defaults = defaults
        self.handoffDirectory = handoffDirectory
            ?? MCPSettings.defaultDirectory.appendingPathComponent("handoffs", isDirectory: true)
    }

    public func handoff(sessionID: UUID, target targetKey: String) throws -> HandoffOutcome {
        // 1. The kill switch, read per call the way this repo reads settings
        // per call. Off means the feature is off for every path — the tool's
        // gate and the UI's mirror both funnel through here.
        guard AppPreferences.load(from: defaults).contextHandoffsEnabled else {
            throw MCPToolError(message: "Context handoffs are disabled in Portmaster settings.")
        }

        // 2. The session, and the once-only check as of now (authoritative
        // re-check happens again in `recordHandoff`, under the lock).
        let sessions = try store.sessions()
        guard let source = sessions.first(where: { $0.id == sessionID }) else {
            throw MCPToolError(message: "No session \(sessionID.uuidString) is recorded.")
        }
        guard source.handoffTargetPID == nil else {
            throw MCPToolError(message: "This session has already handed off; a thread hands off once.")
        }

        // 3. The target, from configuration.
        let targets = HandoffTargets.load()
        guard let target = targets[targetKey] else {
            let known = targets.keys.sorted().joined(separator: ", ")
            throw MCPToolError(
                message: "Unknown handoff target '\(targetKey)'. Known targets: \(known)."
            )
        }

        // 4. The log — the same matcher the poller uses, scoped to this one
        // session, so "uniquely attributable" means exactly what usage
        // attribution means.
        let candidates = adapter.logCandidates(
            newerThan: source.connectedAt.addingTimeInterval(-AgentLogMatcher.defaultOverlap)
        )
        let matches = AgentLogMatcher.match(
            candidates,
            for: [(id: source.id, connectedAt: source.connectedAt)],
            overlap: AgentLogMatcher.defaultOverlap,
            now: Date()
        )
        guard case .unique(let log) = matches[source.id] else {
            throw MCPToolError(
                message: "This session's conversation log is not uniquely attributable, "
                    + "so no brief can be cited from it."
            )
        }

        // 5. Extract and budget. A read failure and an uncitable log are
        // different facts and say different things.
        let brief: HandoffBrief
        do {
            brief = try HandoffBriefExtractor.extract(from: log.url)
        } catch {
            throw MCPToolError(
                message: "Could not read \(log.url.path): \(error.localizedDescription)"
            )
        }
        var draft = brief
        draft.sessionID = sessionID
        let budgeted = draft.budgeted()
        guard !budgeted.citedLines.isEmpty else {
            throw MCPToolError(
                message: "No cited content was found in \(log.url.path), "
                    + "so there is nothing to hand off."
            )
        }

        // 6. THE DRY RUN: the brief exists on disk before anything spawns
        // (spec §5, amendment 6).
        let briefPath = try writeBrief(budgeted)

        // 7. Working directory: recorded from the log, never guessed
        // (amendment 7). Missing means refused — with the brief offered.
        guard let cwd = budgeted.workingDirectory, isDirectory(cwd) else {
            throw MCPToolError(
                message: "The log records no usable working directory, so the agent "
                    + "cannot be started there. The brief was saved at \(briefPath.path) "
                    + "for manual use."
            )
        }

        // 8. The CLI must exist (§6).
        guard let executable = launcher.resolve(target.executable, path: nil) else {
            throw MCPToolError(
                message: "\(target.executable) is not installed (not found on PATH). "
                    + "The brief was saved at \(briefPath.path) for manual use."
            )
        }

        // 9. Spawn. The brief, verbatim, on stdin.
        let pid: Int32
        do {
            pid = try launcher.launch(
                executable: executable, arguments: target.arguments,
                workingDirectory: cwd, stdinText: budgeted.renderedMarkdown()
            )
        } catch {
            throw MCPToolError(
                message: "\(target.executable) could not be started: \((error as? MCPToolError)?.message
                    ?? error.localizedDescription). The brief was saved at \(briefPath.path) "
                    + "for manual use."
            )
        }

        // 10. Record under the lock. If a second handoff won the race, the
        // process we just spawned is ours to undo — the spawn was contingent
        // on this write, and a refusal must leave nothing running.
        guard try store.recordHandoff(
            sourceID: sessionID, targetPID: pid, targetName: targetKey
        ) else {
            launcher.terminate(pid: pid)
            throw MCPToolError(
                message: "This session has already handed off; the new agent was stopped."
            )
        }
        try store.flush()

        return HandoffOutcome(
            briefPath: briefPath.path,
            citedLines: budgeted.citedLines,
            launchedPID: pid,
            target: targetKey
        )
    }

    private func writeBrief(_ brief: HandoffBrief) throws -> URL {
        try FileManager.default.createDirectory(
            at: handoffDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = handoffDirectory.appendingPathComponent(
            "\(brief.sessionID?.uuidString ?? UUID().uuidString).md"
        )
        try brief.renderedMarkdown().write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
        return url
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }
}
```

- [ ] **Step 7: Verify the coordinator suite passes**

The coordinator suite must now pass — it was red at Step 5, when none of these types existed. Run (from `Core/`): `swift test --filter HandoffCoordinatorTests && swift test --filter AgentSourcePollerTests && swift test --filter AgentLogMatcherTests` — expected: PASS. The poller's default moved to the shared constant with the same value (`60 * 60`), so its behaviour is unchanged; the matcher and poller tests pin that.

- [ ] **Step 8: Write the failing wiring tests**

The coordinator exists but no client can reach it: not in the catalog, not in dispatch, not on the provider seam, not in the approval window. These tests pin every edge.

`Core/Tests/PortmasterMCPTests/ToolExecutorReadTests.swift` — the catalog test (line ~224) becomes:

```swift
    func testCatalogDeclaresEighteenToolsAndClassifiesEffects() {
        let catalog = ToolExecutor.catalog
        XCTAssertEqual(catalog.count, 18, "catalog must declare all 18 tools")

        let names = catalog.map(\.name)
        XCTAssertEqual(Set(names).count, 18, "tool names must be unique")

        let expected: Set<String> = [
            "get_system_overview", "get_top_apps", "get_app_detail", "get_containers",
            "get_projects", "get_history_rankings", "get_temperatures_fans", "get_agent_sessions",
            "get_active_alerts", "get_settings", "get_model_prices", "report_usage",
            "quit_app", "stop_container", "stop_project", "set_preference", "set_model_price",
            "handoff_context"
        ]
        XCTAssertEqual(Set(names), expected)

        let mutations = Set(catalog.filter { $0.effect == .mutation }.map(\.name))
        XCTAssertEqual(
            mutations,
            ["quit_app", "stop_container", "stop_project", "set_preference",
             "set_model_price", "handoff_context"]
        )
        XCTAssertEqual(catalog.filter { $0.effect == .read }.count, 12)
        for tool in catalog {
            XCTAssertFalse(tool.description.isEmpty, "\(tool.name) needs a description")
        }
    }
```

`Core/Tests/PortmasterMCPTests/MCPHostServerTests.swift` — both count assertions become 18, and both messages that name 17 say 18 (line 49: `"the catalog is 18 tools, and all of them must be listed"`; line 180: `"the host must keep serving after rejecting a wrong token"` keeps its text, its count becomes 18).

`Core/Tests/PortmasterMCPTests/CLIRoutingTests.swift` line 118:

```swift
        XCTAssertEqual(relayed.count, 18, "the catalog is 18 tools")
```

`Core/Tests/PortmasterMCPTests/MCPApprovalPresentationTests.swift` — `sampleArguments(for:)` (line 538) gains its case (this is the test that forces it):

```swift
        case "handoff_context":
            return ["session_id": "0B1D3F00-0000-0000-0000-000000000001", "target": "claude"]
```

`Core/Tests/PortmasterMCPTests/ToolExecutorReadTests.swift` — `StubProvider`, beside its `agentSessions` method (the shared stub the mutation tests use):

```swift
    /// A canned handoff plus the arguments it was asked for: "the executor passed the
    /// session the client named" is a claim only the provider can answer.
    var handoffResult = HandoffOutcome(
        briefPath: "/tmp/brief.md", citedLines: [1, 2, 3], launchedPID: 4242, target: "claude"
    )
    private(set) var lastHandoff: (sessionID: UUID, target: String)?

    func handoffContext(sessionID: UUID, target: String) async throws -> HandoffOutcome {
        try enter("handoffContext")
        lastHandoff = (sessionID, target)
        return handoffResult
    }
```

`Core/Tests/PortmasterMCPTests/ToolExecutorMutationTests.swift` — a new `// MARK: handoff_context` section:

```swift
    // MARK: handoff_context

    /// The whole point of the tool: the session the client named is the session that
    /// was handed off, and the success line says where the brief went. A handoff audit
    /// that said only "allowed" would not tell a reader which conversation moved.
    func testHandoffContextPassesBothArgumentsAndNotesTheBrief() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )
        let sessionID = UUID()

        let outcome = await tool.execute(
            name: "handoff_context",
            arguments: ["session_id": sessionID.uuidString, "target": "claude"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        XCTAssertEqual(stub.lastHandoff?.sessionID, sessionID)
        XCTAssertEqual(stub.lastHandoff?.target, "claude")

        let payload = try jsonObject(outcome.text)
        XCTAssertEqual(payload["briefPath"] as? String, "/tmp/brief.md")
        XCTAssertEqual(payload["citedLines"] as? [Int], [1, 2, 3])
        XCTAssertEqual(payload["launchedPID"] as? Int, 4242)
        XCTAssertEqual(payload["target"] as? String, "claude")

        let entries = try auditEntries(in: dir)
        XCTAssertEqual(entries.count, 1, "exactly one line per mutation attempt")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["tool"] as? String, "handoff_context")
        XCTAssertEqual(entry["outcome"] as? String, "allowed")
        let reason = try XCTUnwrap(entry["reason"] as? String)
        XCTAssertTrue(reason.hasPrefix("brief=/tmp/brief.md"), reason)
        XCTAssertTrue(reason.contains("lines=1,2,3"), reason)
    }

    /// The gate reaches this tool the way it reaches every mutation, and a refusal
    /// never touches the provider — a launch is the most expensive thing a mutation
    /// can do here, so the pre-provider rule matters most for it.
    func testHandoffContextIsDeniedByTheGateBeforeTheProviderRuns() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(provider: stub, mode: .off, appRunning: true, directory: dir)

        let outcome = await tool.execute(
            name: "handoff_context",
            arguments: ["session_id": UUID().uuidString, "target": "claude"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(stub.count(of: "handoffContext"), 0)
        let entries = try auditEntries(in: dir)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["tool"] as? String, "handoff_context")
        XCTAssertEqual(entry["outcome"] as? String, "denied")
        XCTAssertEqual(
            entry["reason"] as? String, "MCP mutations are disabled in Portmaster settings."
        )
    }

    /// A session id that is not an id is refused inside dispatch — after the gate,
    /// like every other format check (`requireWindow`, `price`) — audited `failed`
    /// with the reason, and the provider never runs.
    func testHandoffContextRefusesASessionIdThatIsNotOneWithoutTouchingTheProvider()
        async throws
    {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(
            name: "handoff_context",
            arguments: ["session_id": "not-a-uuid", "target": "claude"]
        )

        XCTAssertTrue(outcome.isError)
        XCTAssertEqual(stub.count(of: "handoffContext"), 0)
        let entry = try XCTUnwrap(auditEntries(in: dir).first)
        XCTAssertEqual(entry["outcome"] as? String, "failed")
        XCTAssertEqual(
            entry["reason"] as? String, "Invalid session_id: not an id Portmaster recorded."
        )
    }

    /// The note rides only payloads that carry one: an ordinary success still audits
    /// with no reason, so a reader knows a non-nil `reason` is an exception worth
    /// reading. The success audit changed for everyone in this task; this pins that
    /// it changed for no one else.
    func testAnOrdinarySuccessfulMutationStillAuditsWithNoReason() async throws {
        let stub = StubProvider()
        let dir = try makeTemporaryDirectory(prefix: name)
        let tool = try makeExecutor(
            provider: stub, mode: .allowSession, appRunning: true, directory: dir
        )

        let outcome = await tool.execute(
            name: "set_preference", arguments: ["key": "temperatureUnit", "value": "celsius"]
        )

        XCTAssertFalse(outcome.isError, outcome.text)
        let entry = try XCTUnwrap(auditEntries(in: dir).first)
        XCTAssertEqual(entry["outcome"] as? String, "allowed")
        XCTAssertNil(entry["reason"] as? String)
    }
```

`Core/Tests/PortmasterMCPTests/LiveDataProviderTests.swift` — the private `makeProvider` helper gains a defaulted seam (nothing else changes; every existing call compiles):

```swift
        mutations: RecordedMutations = RecordedMutations(),
        handoff: (@Sendable (UUID, String) async throws -> HandoffOutcome)? = nil
    ) -> LiveDataProvider {
        LiveDataProvider(
            snapshot: { try await published.current() },
            alerts: alerts,
            history: history.open,
            settings: { Self.settings },
            // Wrapped rather than passed as method references: a reference to a
            // class method is not `@Sendable`, and these seams cross actors.
            applyPreference: { key, value in mutations.applyPreference(key: key, value: value) },
            stopApp: { id, force in try await mutations.stopApp(id: id, force: force) },
            stopContainerNamed: { id in try await mutations.stopContainer(id: id) },
            stopProject: { id in try await mutations.stopProject(id: id) },
            handoff: handoff
        )
    }
```

plus, in the same file:

```swift
    // MARK: Handoff

    /// The seam is the coordinator: the provider passes both arguments through and
    /// returns what the coordinator did, unchanged.
    func testTheHandoffSeamReceivesTheCallAndReturnsItsOutcome() async throws {
        let recorder = HandoffRecorder()
        let provider = makeProvider(
            Self.snapshot(),
            handoff: { sessionID, target in
                recorder.ask(sessionID: sessionID, target: target)
                return HandoffOutcome(
                    briefPath: "/tmp/b.md", citedLines: [4, 5], launchedPID: 7, target: target
                )
            }
        )
        let sessionID = UUID()

        let got = try await provider.handoffContext(sessionID: sessionID, target: "codex")

        XCTAssertEqual(
            got,
            HandoffOutcome(briefPath: "/tmp/b.md", citedLines: [4, 5], launchedPID: 7, target: "codex")
        )
        XCTAssertEqual(recorder.last?.sessionID, sessionID)
        XCTAssertEqual(recorder.last?.target, "codex")
    }

    /// A provider built without the seam refuses by name rather than inventing an
    /// outcome: there is no honest success value for a launch nobody performed.
    func testAProviderWithNoHandoffSeamSaysItDidNotHandOff() async throws {
        let provider = makeProvider(Self.snapshot())
        do {
            _ = try await provider.handoffContext(sessionID: UUID(), target: "claude")
            XCTFail("a provider with no handoff path must refuse, not answer")
        } catch let error as MCPToolError {
            XCTAssertEqual(
                error.message,
                "The Portmaster app did not offer a handoff path, so nothing was handed off."
            )
        }
    }

    private final class HandoffRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: (sessionID: UUID, target: String)?
        func ask(sessionID: UUID, target: String) { lock.withLock { storage = (sessionID, target) } }
        var last: (sessionID: UUID, target: String)? { lock.withLock { storage } }
    }
```

`Core/Tests/PortmasterMCPTests/OnDemandProviderTests.swift` — one test beside the other refusals:

```swift
    /// No running app means no session log to brief from and no app-owned store to
    /// record the link in, so the on-demand path says so instead of simulating one.
    func testHandoffContextRefusesBecauseThereIsNoRunningApp() async throws {
        let provider = OnDemandProvider(appRunning: { false })
        do {
            _ = try await provider.handoffContext(sessionID: UUID(), target: "claude")
            XCTFail("a handoff without the app must be refused, not simulated")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.message, OnDemandProvider.handoffUnavailableMessage)
        }
    }
```

- [ ] **Step 9: Run to verify failure**

From `Core/`:

```
swift test --filter ToolExecutorReadTests          # fails: catalog is 17, the test says 18
swift test --filter MCPHostServerTests             # fails: 17 ≠ 18
swift test --filter CLIRoutingTests                # fails: 17 ≠ 18
swift test --filter MCPApprovalPresentationTests   # fails: handoff_context has no sample arguments
swift test --filter ToolExecutorMutationTests      # fails: Unknown tool: handoff_context
swift test --filter LiveDataProviderTests          # does not compile: handoffContext/handoff do not exist
swift test --filter OnDemandProviderTests          # does not compile: handoffContext does not exist
```

The two compile failures are the red for the two seams that do not exist yet; every other suite fails on its assertions at runtime. Expected: failures everywhere, and the failures name this task.

- [ ] **Step 10: Implement the wiring**

`Core/Sources/PortmasterMCP/DataProvider.swift` — the requirement, after `setPreference`:

```swift
    /// A dry run, a launch, and a once-only record: the handoff flow itself, which
    /// `HandoffCoordinator` owns. The provider is the seam so the executor never
    /// learns where a session store or a log directory lives.
    func handoffContext(sessionID: UUID, target: String) async throws -> HandoffOutcome
```

`Core/Sources/PortmasterMCP/LiveDataProvider.swift` — property beside `sessionReadingSource`:

```swift
    private let handoffSource: (@Sendable (UUID, String) async throws -> HandoffOutcome)?
```

init — one more parameter after `sessionReading`, assigned at the end of the body:

```swift
        sessionReading: (@Sendable () async -> (any AgentSessionReadingSource)?)? = nil,
        handoff: (@Sendable (UUID, String) async throws -> HandoffOutcome)? = nil
```

```swift
        self.sessionReadingSource = sessionReading
        self.handoffSource = handoff
```

the method, beside `agentSessions`:

```swift
    // MARK: Handoff

    /// The app's own coordinator, through the seam wired at construction. Refused by
    /// name when the seam is absent rather than answered with a fake outcome: there
    /// is no honest success value for a launch nobody performed.
    public func handoffContext(sessionID: UUID, target: String) async throws -> HandoffOutcome {
        guard let handoffSource else {
            throw MCPToolError(
                message: "The Portmaster app did not offer a handoff path, so nothing was handed off."
            )
        }
        return try await handoffSource(sessionID, target)
    }
```

`Core/Sources/PortmasterMCP/OnDemandProvider.swift` — beside the other shared message constants and beside `agentSessions`:

```swift
    /// Said when there is no running app to read a session's log from or to own the
    /// session database. One string for the refusal, shared the way the others are,
    /// because a caller can reach either provider for the same tool.
    public static let handoffUnavailableMessage =
        "Portmaster's app is not running, so it cannot read the session's log or open "
        + "the session history to hand it off."
```

```swift
    public func handoffContext(sessionID _: UUID, target _: String) async throws -> HandoffOutcome {
        throw MCPToolError(message: Self.handoffUnavailableMessage)
    }
```

`Core/Sources/PortmasterMCP/WirePayloads.swift` — beside `AgentSessionsPayload`:

```swift
/// What a completed `handoff_context` did, on the wire: where the brief landed, which
/// source lines it cites, the receiving agent's pid, and which configured target ran.
struct HandoffContextPayload: Encodable {
    let outcome: HandoffOutcome

    init(_ outcome: HandoffOutcome) { self.outcome = outcome }

    private enum CodingKeys: String, CodingKey {
        case briefPath, citedLines, launchedPID, target
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(outcome.briefPath, forKey: .briefPath)
        try container.encode(outcome.citedLines, forKey: .citedLines)
        try container.encode(outcome.launchedPID, forKey: .launchedPID)
        try container.encode(outcome.target, forKey: .target)
    }
}
```

`Core/Sources/PortmasterMCP/ToolExecutor.swift` — four edits.

Catalog: the last entry, after `set_model_price`, still inside the array:

```swift
        ToolDefinition(
            name: "handoff_context",
            description: "Write this session's context brief and launch a receiving "
                + "agent to continue it in the session's own working directory. A "
                + "session hands off at most once.",
            arguments: [
                (name: "session_id", required: true, help: "Session id from get_agent_sessions"),
                (name: "target", required: true, help: "Receiving agent: claude | codex, or a configured name")
            ],
            effect: .mutation
        ),
```

Dispatch: a case after `report_usage`, before `default`:

```swift
        case "handoff_context":
            let sessionID = try Self.sessionUUID(arguments)
            let target = try Self.nonBlank(arguments["target"], field: "target")
            let outcome = try await provider.handoffContext(sessionID: sessionID, target: target)
            return HandoffContextPayload(outcome)
```

The parser, in the `// MARK: Argument parsing` section beside `requireSessionID`:

```swift
    /// The `session_id` argument as a UUID.
    ///
    /// Its own helper rather than `requireSessionID`: that one reads the connection's
    /// own binding (`report_usage` records against the caller's session), while a
    /// handoff names its session explicitly — any recorded session may be handed off,
    /// not only the one the call arrived on.
    private static func sessionUUID(_ arguments: [String: String]) throws -> UUID {
        let raw = try nonBlank(arguments["session_id"], field: "session_id")
        guard let id = UUID(uuidString: raw) else {
            throw MCPToolError(message: "Invalid session_id: not an id Portmaster recorded.")
        }
        return id
    }
```

The success audit and its note protocol — the protocol and its conformance at file scope (bottom of the file, outside the class):

```swift
/// The `reason` a successful call carries, for payloads that have one.
///
/// The executor's vocabulary stays four words (`allowed`/`denied`/`failed`/`rejected`);
/// this is the note that rides the `allowed` line, so the log records not only that a
/// handoff ran but where its brief went (ruling 10). Payloads without the conformance
/// audit with no reason, exactly as before.
private protocol MCPAuditNoting {
    var auditNote: String { get }
}

extension HandoffContextPayload: MCPAuditNoting {
    var auditNote: String { outcome.auditNote }
}
```

(If the compiler refuses a file-private conformance of a type declared in another file, widen `MCPAuditNoting` to internal — its name already scopes it to this module — and record the widening as a `Ruling:` line in the ledger.)

and the success audit itself, in `execute`:

```swift
            if isMutation {
                audit.record(
                    tool: name, arguments: normalized, outcome: "allowed",
                    reason: (payload as? MCPAuditNoting)?.auditNote
                )
            }
```

`Core/Sources/PortmasterMCP/HostMCPCallContext.swift` — a case in `request(for:arguments:)`'s switch, before `default`:

```swift
        case "handoff_context":
            kind = .handoffContext
            summary = "Hand off this session to \(arguments["target"] ?? "the target agent")?"
```

`Core/Sources/PortmasterMCP/ConfirmationBroker.swift` — the sixth `Kind` case:

```swift
        /// A context handoff: a receiving agent launched to continue this session.
        /// Its own kind because the approval is about a launch into another process —
        /// the person must be told an agent is about to be started with this
        /// conversation — not about stopping something or writing a value.
        case handoffContext
```

`Core/Sources/PortmasterMCP/MCPApprovalCopy.swift` — all four switches (the compiler finds them; each needs its case):

```swift
        // summary(for:)
        case .handoffContext: return "Hand off a session"

        // approveTitle(for:)
        case .handoffContext: return "Hand Off Session"

        // whatItDoes(kind:arguments:)
        case .handoffContext:
            let target = named(arguments["target"], fallback: "an agent the client did not name")
            return "Write this session's context brief and launch '\(target)' to continue "
                + "the conversation in the session's own working directory."

        // leadIn(for:count:) — never reached today (this kind's requests carry no
        // resolved targets), kept truthful for the day one does.
        case .handoffContext:
            return "The brief will be handed to:"
```

`App/MCPHostController.swift` — `needsReading(_:)` (line ~443): a handoff resolves no processes:

```swift
        case .handoffContext: return false
```

Edit the existing false line to read:

```swift
        case .stopContainer, .setPreference, .setModelPrice, .handoffContext: return false
```

`App/MCPConfirmationWindow.swift` — `resolve(_:)` (line ~427): the window validates before a person is asked, the same way `set_preference` and `set_model_price` do:

```swift
        case .handoffContext:
            // Preview data first, as everywhere: a session in a synthetic reading has
            // no log to brief from, so the handoff the write would perform does not
            // exist to approve.
            if model.prefs.fixtureMode { return .refused(LiveAppView.previewDataStopRefusal) }
            let session = request.arguments["session_id"] ?? ""
            guard UUID(uuidString: session) != nil else {
                return .refused("Invalid session_id: not an id Portmaster recorded.")
            }
            let target = request.arguments["target"] ?? ""
            guard HandoffTargets.load().keys.contains(target) else {
                return .refused("'\(target)' is not a configured handoff target.")
            }
            return .shown(Resolved(
                stopTarget: nil,
                targets: ["\(target) — continue session \(session)"]
            ))
```

`scripts/mcp-e2e.sh` — the gate counts one more tool now: line 12's comment (`must return 17 tools` → `must return 18 tools`) and line 341:

```bash
check 'tools/list over the socket returns 18 tools' "$tool_count" '18'
```

- [ ] **Step 11: Run everything to pass**

From `Core/`:

```
swift test
```

Expected: **zero failures**. The counts are 18/12/6 (total/reads/mutations), the approval walk describes `handoff_context` in six places, and the coordinator suite is green.

Then compile the App, because two of this step's edits live in `App/`:

```
xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build
```

Expected: `BUILD SUCCEEDED`, no new warnings (the six pre-existing ones in untouched files stay).

- [ ] **Step 12: Commit**

```bash
git add Core/Sources/PortmasterMCP/ToolExecutor.swift \
        Core/Sources/PortmasterMCP/DataProvider.swift \
        Core/Sources/PortmasterMCP/LiveDataProvider.swift \
        Core/Sources/PortmasterMCP/OnDemandProvider.swift \
        Core/Sources/PortmasterMCP/WirePayloads.swift \
        Core/Sources/PortmasterMCP/HostMCPCallContext.swift \
        Core/Sources/PortmasterMCP/ConfirmationBroker.swift \
        Core/Sources/PortmasterMCP/MCPApprovalCopy.swift \
        App/MCPHostController.swift \
        App/MCPConfirmationWindow.swift \
        Core/Tests/PortmasterMCPTests/ToolExecutorReadTests.swift \
        Core/Tests/PortmasterMCPTests/ToolExecutorMutationTests.swift \
        Core/Tests/PortmasterMCPTests/MCPHostServerTests.swift \
        Core/Tests/PortmasterMCPTests/CLIRoutingTests.swift \
        Core/Tests/PortmasterMCPTests/MCPApprovalPresentationTests.swift \
        Core/Tests/PortmasterMCPTests/LiveDataProviderTests.swift \
        Core/Tests/PortmasterMCPTests/OnDemandProviderTests.swift \
        scripts/mcp-e2e.sh
git commit -m "feat: handoff_context runs through the gate, the audit, and the approval window"
```

Do not add `Core/Package.resolved` if a build dirtied it.

---

### Task 7: The affordance — the strip asks, the app hands off

No visual claims are made or permitted (Global Constraints): this task's proof is the source-scan tests, a green package suite, a successful app build, and the e2e gate.

**Files:**
- Modify: `App/OverviewView.swift` (strip button + `PressureActionsSheet`; add `import AppKit` and `import PortmasterMCP`)
- Modify: `App/AppModel.swift` (add `import PortmasterMCP`; `performHandoff`)
- Modify: `App/MCPHostController.swift` (`handoff:` seam in `makeProvider()`)
- Modify: `App/SettingsView.swift` (kill-switch toggle, General tab)
- Modify: `Core/Sources/PortmasterMCP/HandoffCoordinator.swift` (`live(store:)`, `recordAppHandoff`)
- Modify: `Core/Tests/PortmasterCoreTests/AppHandoffWiringTests.swift` (three scans)
- Gate: `swift test` (zero failures), `xcodebuild` (BUILD SUCCEEDED, no new warnings), `scripts/mcp-e2e.sh --no-manual …` (all checks pass, tally 17/0/1, tools/list expects 18)

**Interfaces:**
- Consumes: `ContextPressureNotice(sessionID, clientName, tokensLeftWorst)` (`AppModel.swift:73`), `HandoffTargets.load()` (`URL? = nil` → `MCPSettings.defaultDirectory`), `AppDelegate.shared?.mcpHost?.mode` (the App-internal controller, `private(set) var mode`), `model.prefs.contextHandoffsEnabled` (persisted by `prefs`' `didSet { prefs.save() }`), Tasks 1–6.
- Produces:
  - `AppModel.performHandoff(sessionID: UUID, target: String) throws -> HandoffOutcome`
  - `HandoffCoordinator.live(store:) -> HandoffCoordinator`; `HandoffCoordinator.recordAppHandoff(sessionID:target:result:)`
  - `PressureActionsSheet` (SwiftUI, in `OverviewView.swift`)
  - audit lines carrying `"origin": "app"`

- [ ] **Step 1: Write the failing source-scan tests**

Append to `Core/Tests/PortmasterCoreTests/AppHandoffWiringTests.swift` (the file Task 4 created; its `source(_:)` helper reads any repository-relative file with comments stripped, and its "the file must be found or the test fails" rule applies to every path here):

```swift
    // MARK: The affordance

    /// The strip's button opens one sheet, and the sheet offers both ways out the
    /// spec chose — the command the agent must run itself, and the handoff — behind
    /// the mode mirror and the kill switch, from the session the notice is about.
    func testTheStripOffersAnActionAndTheSheetOffersBothWaysOut() throws {
        let overview = try source("App/OverviewView.swift")

        XCTAssertTrue(
            overview.contains("struct PressureActionsSheet"),
            "the sheet the strip opens must exist beside the strip"
        )
        XCTAssertTrue(
            overview.contains(".sheet(isPresented:"),
            "the strip presents its actions as a sheet"
        )
        XCTAssertTrue(
            overview.contains("/compact"),
            "the sheet offers the exact command, because Portmaster cannot run it"
        )
        XCTAssertTrue(
            overview.contains("HandoffTargets.load"),
            "the sheet lists the configured receiving agents, not a hard-coded pair"
        )
        XCTAssertTrue(
            overview.contains("notice.sessionID"),
            "the handoff is of the session the notice is about"
        )
        XCTAssertTrue(
            overview.contains("AppDelegate.shared?.mcpHost?.mode"),
            "the sheet mirrors the host's mode exactly as Settings does (ruling 16)"
        )
        XCTAssertTrue(
            overview.contains("contextHandoffsEnabled"),
            "the sheet respects the kill switch"
        )
    }

    /// Both surfaces reach one coordinator factory, and the app's own path writes its
    /// own audit line — the two claims only a whole-file scan can hold still.
    func testThePressGoesThroughOneCoordinatorAndAuditsItsOwnOrigin() throws {
        let appModel = try source("App/AppModel.swift")
        XCTAssertTrue(
            appModel.contains("func performHandoff(sessionID: UUID, target: String)"),
            "the app's handoff entry point must exist by this name"
        )
        XCTAssertTrue(
            appModel.contains("HandoffCoordinator.live(store:"),
            "both surfaces build the coordinator through one factory"
        )
        XCTAssertTrue(
            appModel.contains("recordAppHandoff"),
            "the app path writes its own audit line (ruling 10)"
        )

        let controller = try source("App/MCPHostController.swift")
        XCTAssertTrue(
            controller.contains("handoff: { sessionID, target in"),
            "the socket path reaches the same coordinator through the provider seam"
        )

        let coordinator = try source("Core/Sources/PortmasterMCP/HandoffCoordinator.swift")
        XCTAssertTrue(
            coordinator.contains(#""origin": "app""#),
            "the app's audit line carries origin, so the two surfaces are tellable apart"
        )
    }

    /// The kill switch has one authority (the coordinator) and one switch (Settings),
    /// named after what it switches.
    func testTheKillSwitchHasAToggleInTheGeneralSettings() throws {
        let settings = try source("App/SettingsView.swift")
        XCTAssertTrue(
            settings.contains("contextHandoffsEnabled"),
            "the kill switch must be settable where the other preferences live"
        )
        XCTAssertTrue(
            settings.contains("Agent handoffs"),
            "the toggle is named after what it switches"
        )
    }
```

- [ ] **Step 2: Run to verify failure**

From `Core/`: `swift test --filter AppHandoffWiringTests` — expected: the three new tests fail naming the needles that are not yet in the sources (the Task 4 tests in the same file stay green).

- [ ] **Step 3: The coordinator factory and the app's audit line**

`Core/Sources/PortmasterMCP/HandoffCoordinator.swift` — two statics inside `struct HandoffCoordinator`, at the end after `isDirectory(_:)`:

```swift
    /// The app's own coordinator: the log root Claude Code writes to, the system
    /// launcher, the per-user defaults, and briefs beside them. One construction for
    /// both surfaces, so the MCP path and the strip cannot drift on where a brief
    /// lands or which defaults a kill switch is read from.
    public static func live(store: AgentSessionStore) -> HandoffCoordinator {
        HandoffCoordinator(
            store: store,
            adapter: ClaudeCodeLogAdapter(),
            launcher: SystemHandoffLauncher(),
            defaults: .standard,
            handoffDirectory: MCPSettings.defaultDirectory.appendingPathComponent("handoffs")
        )
    }

    /// The UI path's own audit line (ruling 10): the same tool name, `origin: app`,
    /// so one log tells a person's press from an assistant's call. Success carries
    /// the brief note and failure the refusal — the same two things the executor's
    /// line records for the MCP path.
    public static func recordAppHandoff(
        sessionID: UUID, target: String, result: Result<HandoffOutcome, Error>
    ) {
        let audit = AuditLog(directory: MCPSettings.defaultDirectory)
        let arguments = ["session_id": sessionID.uuidString, "target": target, "origin": "app"]
        switch result {
        case .success(let handoff):
            audit.record(
                tool: "handoff_context", arguments: arguments,
                outcome: "allowed", reason: handoff.auditNote
            )
        case .failure(let error):
            let reason = (error as? MCPToolError)?.message ?? error.localizedDescription
            audit.record(
                tool: "handoff_context", arguments: arguments,
                outcome: "failed", reason: reason
            )
        }
    }
```

- [ ] **Step 4: `AppModel.performHandoff`**

`App/AppModel.swift` — add the import at the top (beside `import PortmasterCore`):

```swift
import PortmasterMCP
```

and the method beside `refreshAgentSessions`:

```swift
    /// One handoff from the app's own surface (ruling 10): the coordinator does the
    /// work, and this path writes its own audit line — same tool name, `origin: app` —
    /// so the log tells a person's press apart from an assistant's tool call. The MCP
    /// path audits through the executor instead; neither path audits twice.
    func performHandoff(sessionID: UUID, target: String) throws -> HandoffOutcome {
        guard let store = agentSessionStore else {
            throw MCPToolError(
                message: "Session history is not available, so nothing was handed off."
            )
        }
        let result = Result {
            try HandoffCoordinator.live(store: store)
                .handoff(sessionID: sessionID, target: target)
        }
        HandoffCoordinator.recordAppHandoff(sessionID: sessionID, target: target, result: result)
        return try result.get()
    }
```

- [ ] **Step 5: The strip's button and the sheet**

`App/OverviewView.swift` — add the imports after `import PortmasterCore`:

```swift
import AppKit
import PortmasterMCP
```

replace `struct ContextPressureStrip` (line ~780) wholesale with:

```swift
struct ContextPressureStrip: View {
    let notice: AppModel.ContextPressureNotice
    @State private var showingActions = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
            Text("\(notice.clientName ?? "Agent") — \(Fmt.tokens(notice.tokensLeftWorst)) tokens left (worst observed)")
                .font(.callout)
            Spacer()
            Button("Take Action…") { showingActions = true }
                .accessibilityLabel("Take action on this session's context pressure")
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(notice.clientName ?? "Agent"), \(Fmt.tokens(notice.tokensLeftWorst)) tokens left, worst observed")
        .sheet(isPresented: $showingActions) {
            PressureActionsSheet(notice: notice)
        }
    }
}

/// Both ways out of context pressure, in the words the spec chose: run `/compact`
/// in the agent's own terminal (Portmaster holds no channel to that prompt — it
/// offers the exact command instead), or hand the conversation to a receiving
/// agent. The handoff is a launch and obeys everything a launch obeys: the MCP
/// mode mirror disables it with the reason shown, the kill switch disables it
/// with its reason shown, and a refusal arrives as text rather than silence.
struct PressureActionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let notice: AppModel.ContextPressureNotice

    @State private var copiedCompact = false
    @State private var resultLine: String?

    private var modeAllowsHandoff: Bool {
        AppDelegate.shared?.mcpHost?.mode == .allowSession
    }

    private var blockedReason: String? {
        if !model.prefs.contextHandoffsEnabled {
            return "Agent handoffs are switched off in Settings → General."
        }
        if !modeAllowsHandoff {
            return "Handoffs run only while Portmaster's MCP mode allows session actions (Settings → MCP)."
        }
        return nil
    }

    private var targets: [String] { HandoffTargets.load().keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(notice.clientName ?? "Agent") — \(Fmt.tokens(notice.tokensLeftWorst)) tokens left (worst observed)")
                .font(.headline)
            Text("This conversation can outgrow one context window. Two ways forward:")
                .font(.subheadline)

            Button(copiedCompact ? "Copied /compact" : "Copy /compact") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("/compact", forType: .string)
                copiedCompact = true
            }
            Text("Portmaster cannot run it for you: `/compact` belongs to the agent's own prompt, which has no channel from here. Copy it and paste it in that terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(targets, id: \.self) { target in
                Button("Hand off to \(target)") {
                    do {
                        let outcome = try model.performHandoff(
                            sessionID: notice.sessionID, target: target
                        )
                        resultLine = "Handing off to \(target) — brief written at \(outcome.briefPath)"
                    } catch {
                        resultLine = (error as? MCPToolError)?.message ?? error.localizedDescription
                    }
                }
                .disabled(blockedReason != nil)
                .accessibilityLabel("Hand this session off to \(target)")
            }
            if let blocked = blockedReason {
                Text(blocked)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = resultLine {
                Text(line)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Close") { dismiss() }
        }
        .padding(20)
        .frame(minWidth: 440, alignment: .leading)
    }
}
```

(The strip's original two visual lines — gauge icon, tokens-left text, spacer, padding, background, accessibility label — are unchanged above; only the button and the sheet are new.)

- [ ] **Step 6: The socket path's seam**

`App/MCPHostController.swift` — `makeProvider()` (line 353) builds `LiveDataProvider(...)` whose last argument is `sessionReading:` (line 372). Close that argument with a comma and add the seam as the new last argument, so the call ends:

```swift
            sessionReading: {
                await MainActor.run {
                    AppModel.shared.agentSessionStore.map { StoreAgentSessionReading(store: $0) }
                }
            },
            // One coordinator for both surfaces: this closure runs on a socket thread
            // and the store is main-actor owned, so it hops exactly the way the reads
            // above hop — to the same factory the pressure strip calls.
            handoff: { sessionID, target in
                try await MainActor.run {
                    guard let store = AppModel.shared.agentSessionStore else {
                        throw MCPToolError(
                            message: "Session history is not available, so nothing was handed off."
                        )
                    }
                    return try HandoffCoordinator.live(store: store)
                        .handoff(sessionID: sessionID, target: target)
                }
            }
        )
    }
```

(The `try await MainActor.run { try … }` shape is the one `App/LiveAppView.swift:173` already proves compiles in this target; `MCPToolError` and `HandoffCoordinator` are visible because the file already imports `PortmasterMCP`.)

- [ ] **Step 7: The kill-switch toggle**

`App/SettingsView.swift` — in the General tab's `VStack`, immediately after the preview-data toggle's caption `Text`, add:

```swift
            Divider()

            Toggle("Agent handoffs", isOn: Binding(
                get: { model.prefs.contextHandoffsEnabled },
                set: { model.prefs.contextHandoffsEnabled = $0 }
            ))
            Text("Lets Portmaster write this session's context brief and launch a receiving agent when you ask from the pressure strip or from an MCP client. One switch for both paths: while it is off, nothing is launched and nothing is recorded as handed off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
```

(`model.prefs` saves itself: `@Published var prefs` has `didSet { prefs.save() }`, the same mechanism the surrounding toggles rely on.)

- [ ] **Step 8: Run the scans to pass**

From `Core/`: `swift test --filter AppHandoffWiringTests` — expected: PASS (all three new needles found; the two Task 4 tests unchanged).

- [ ] **Step 9: Full verification**

From `Core/`:

```
swift test
```

Expected: **zero failures** (both test targets; suite counts have grown throughout — growth is the signal).

App build (there is no App test target; this is its verification):

```
xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build
```

Expected: `BUILD SUCCEEDED`, no new warnings.

End-to-end gate — build the MCP binary, resolve the app path, run the script:

```
# from Core/
swift build
# from the repository root:
APP="$(xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -showBuildSettings | awk '/ BUILT_PRODUCTS_DIR = /{print $3}')/Portmaster.app"
scripts/mcp-e2e.sh --no-manual "$APP" "$PWD/Core/.build/debug/portmaster-mcp"
```

Expected: every check passes; the summary reads `17 passed, 0 failed, 1 skipped` and `mcp-e2e: OK` (the tally is the run's own pass/fail/skip count — with `--no-manual` the click-dependent confirmation is the one skip; the script's `tools/list` check now expects **18** tools).

Evidence to capture in the task report: the three command outputs above, verbatim (never a claim from reading source alone).

- [ ] **Step 10: Commit**

```bash
git add App/OverviewView.swift \
        App/AppModel.swift \
        App/MCPHostController.swift \
        App/SettingsView.swift \
        Core/Sources/PortmasterMCP/HandoffCoordinator.swift \
        Core/Tests/PortmasterCoreTests/AppHandoffWiringTests.swift
git commit -m "feat: the pressure strip offers both ways out — compact, or hand off"
```

Do not add `Core/Package.resolved` if a build dirtied it.

---

## Completion checklist (against the spec, sections 2–6)

- [ ] **Brief (§2, rulings 6–8):** Goal/Done/Files/State/Next from the log with physical-line citations; budget ≤ `HandoffBrief.budgetTokens` (1500) with `## Dropped` naming every drop; clipping never silent.
- [ ] **Chain (§4, rulings 1–5):** one handoff per session, linked by observed PID under the store's lock, `ChainReport` with a total only when every member is priced, one chain line on the head row.
- [ ] **Execution (§5, rulings 10–15):** `handoff_context` behind the existing gate; audit lines carry `brief=… lines=…` (MCP) or the same note with `origin: app` (UI); approval window describes it in its own kind; kill switch refuses both paths in one place; dry run before launch, spawn-then-record, termination on refusal.
- [ ] **Launching (§6, ruling 9):** brief on stdin, cwd from the session record, target from `~/.portmaster/handoff-targets.json` or the built-in defaults, not-installed and empty-brief refusals offer the reason.
- [ ] **Affordance (§"the affordance", rulings 16):** strip → sheet offers `/compact` (copy) and hand-off; mode and kill switch disable with the reason shown, never silently.
- [ ] **Gates:** `swift test` zero failures; `xcodebuild` BUILD SUCCEEDED with no new warnings; `scripts/mcp-e2e.sh --no-manual` → `17 passed, 0 failed, 1 skipped`, `mcp-e2e: OK`, tools/list = 18.

Anything that forced a decision not in the 18 rulings is recorded in the SDD ledger as a `Ruling:` line before it is implemented.

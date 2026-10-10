# Context Pressure (agent-session token signal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Read Claude Code's own `tokens left` readings from the logs we already poll, attribute the worst observed value to each uniquely-matched session, and surface it above the overview grid — without ever claiming to know what the number measures.

**Architecture:** A new pure extractor reads the nested `attachment` shape (`{"type":"attachment","attachment":{"type":"total_tokens_reminder",...}}`) and returns the minimum numeric reading with its line number. The poller calls it through a defaulted protocol method (only Claude's adapter overrides), folds `first`/`worst` onto the session row under the store's existing lock, and the wire carries both as nullable ints. The App renders one strip above the overview grid when a live session's worst reading has eroded past a provisional threshold.

**Tech Stack:** Swift 5.9+, SwiftData (`@Model`, lightweight migration), XCTest, SwiftUI. macOS 14.

**Spec:** `docs/superpowers/specs/2026-10-08-agent-context-handoff-design.md` — **§1 plus amendments 3, 8, 9 are binding**. Amendment 9 is the one that decides naming: the value's meaning is mode-dependent and unverified, `Infinite` is a legal rendering, and the UI quotes the log's words.

---

## Global Constraints

- **Unknown is never zero.** No reading → `nil`, rendered as absence. A `0` here would be a claim.
- **The UI never renames the value.** It says `tokens left` (the log's own words). Never "context window", never a percentage of an assumed budget.
- **`Infinite` is not a reading.** Non-numeric reminder text is skipped, not crashed on, not coerced.
- **Amendment 9's threshold is provisional:** `worst * 2 <= first`, one call site, named in a comment as unvalidated — same treatment as the 1% disagreement tolerance.
- **No settings toggle.** Log polling is unconditional by standing ruling; the handoff kill switch belongs to a later plan.
- **Do not touch** the fold, disagreement rule, matching rule (`AgentLogMatcher`), wire `usage`/`cost` payloads, or the sessions card.
- Both suites green, `** BUILD SUCCEEDED **` with zero new warnings (six pre-existing), e2e 17/0/1 at the plan's end.
- Comments explain *why*, never restate code. No comments in tests beyond naming the claim.

---

### Task 1: ContextPressureExtractor

**Files:**
- Create: `Core/Sources/PortmasterCore/History/ContextPressureExtractor.swift`
- Test: `Core/Tests/PortmasterCoreTests/ContextPressureExtractorTests.swift`

**Interfaces:**
- Consumes: nothing (pure; reads a file).
- Produces (Task 2 relies on these exactly):
  - `public struct PressureReading: Sendable, Equatable { public let tokensLeft: Int; public let lineNumber: Int; public init(tokensLeft: Int, lineNumber: Int) }`
  - `public enum ContextPressureExtractor { public static func peak(in url: URL) throws -> PressureReading? }` — `nil` when the file has no numeric reminder; `throws` only for I/O failure.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import PortmasterCore

final class ContextPressureExtractorTests: XCTestCase {
    private func write(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pressure-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func reminder(_ text: String, ts: String = "2026-10-03T22:31:52.569Z") -> String {
        #"{"type":"attachment","attachment":{"type":"total_tokens_reminder","text":"\#(text)"},"timestamp":"\#(ts)"}"#
    }

    func testTheNestedShapeClaudeCodeActuallyWritesReturnsTheWorstReading() throws {
        let url = try write([
            #"{"type":"user","content":"go"}"#,
            reminder("<total_tokens>15000000 tokens left</total_tokens>"),
            #"{"type":"assistant"}"#,
            reminder("<total_tokens>14999357 tokens left</total_tokens>"),
        ])
        let peak = try ContextPressureExtractor.peak(in: url)
        XCTAssertEqual(peak?.tokensLeft, 14999357, "worst means minimum")
        XCTAssertEqual(peak?.lineNumber, 4, "one-based line of that reading")
    }

    func testInfiniteIsNotAReading() throws {
        let url = try write([reminder("<total_tokens>Infinite tokens left</total_tokens>")])
        XCTAssertNil(try ContextPressureExtractor.peak(in: url),
                     "a non-numeric rendering is an absence, never a zero")
    }

    func testALineThatIsNotJSONDoesNotStopTheRead() throws {
        let url = try write([
            "not json at all",
            reminder("<total_tokens>14999658 tokens left</total_tokens>"),
        ])
        XCTAssertEqual(try ContextPressureExtractor.peak(in: url)?.tokensLeft, 14999658)
    }

    func testNoRemindersIsNilNotZero() throws {
        let url = try write([#"{"type":"user","content":"hi"}"#])
        XCTAssertNil(try ContextPressureExtractor.peak(in: url),
                     "a file with no signal is not a file reporting zero")
    }

    func testTheTopLevelShapeThatDoesNotExistInTheLogIsNotRecognized() throws {
        let url = try write([#"{"type":"total_tokens_reminder","text":"<total_tokens>123 tokens left</total_tokens>"}"#])
        XCTAssertNil(try ContextPressureExtractor.peak(in: url),
                     "we recognize only the shape we have seen; guessing is the old bug")
    }

    func testEqualReadingsReportTheEarliestLine() throws {
        let url = try write([
            reminder("<total_tokens>14999357 tokens left</total_tokens>"),
            "x",
            reminder("<total_tokens>14999357 tokens left</total_tokens>"),
        ])
        XCTAssertEqual(try ContextPressureExtractor.peak(in: url)?.lineNumber, 1,
                       "line number identifies the reading, so ties take the first")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter ContextPressureExtractorTests`
Expected: FAIL — `cannot find 'ContextPressureExtractor' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// One numeric `tokens left` reading, and the line it came from.
///
/// The line number is part of the value rather than debug output: every claim this
/// project makes about a log file is traceable to a line in that file, and a pressure
/// figure nobody can point back to would be the exception.
public struct PressureReading: Sendable, Equatable {
    public let tokensLeft: Int
    /// One-based line in the file that produced this reading.
    public let lineNumber: Int
    public init(tokensLeft: Int, lineNumber: Int) {
        self.tokensLeft = tokensLeft
        self.lineNumber = lineNumber
    }
}

/// The minimum `tokens left` a Claude Code log has reported.
///
/// Minimum, not latest: readings oscillate as work opens and closes sub-contexts, so
/// the last value is not the worst one the session experienced.
///
/// **What the number counts is deliberately not named here.** Claude Code renders it
/// from a session-latched mode that may be a context budget, a task budget, or the
/// literal word `Infinite` — none of which the log states per reading. This extractor
/// reports the number the file printed and nothing about its meaning.
public enum ContextPressureExtractor {
    /// Numeric readings only. The reminder's text is `<total_tokens>N tokens left</total_tokens>`;
    /// a non-numeric rendering (Claude Code's `Infinite`) matches nothing here, which is
    /// the correct answer: it is an absence of a measurable budget, not a measurement.
    private static let pattern = /<total_tokens>(\d+) tokens left<\/total_tokens>/

    /// `nil` when no line carried a numeric reminder — an unreadable file throws instead,
    /// because "no reading" and "could not read" are different facts.
    public static func peak(in url: URL) throws -> PressureReading? {
        let text = try String(contentsOf: url, encoding: .utf8)
        var worst: PressureReading?
        for (offset, textLine) in text.split(separator: "\n", omittingEmptySubsequences: true)
            .enumerated() {
            // A log mid-write can hold a partial line; unparseable JSON skips, it does not fail.
            guard let data = textLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let attachment = object["attachment"] as? [String: Any],
                  (attachment["type"] as? String) == "total_tokens_reminder",
                  let reminder = attachment["text"] as? String,
                  let match = reminder.firstMatch(of: pattern)
            else { continue }
            guard let value = Int(match.1) else { continue }
            let lineNumber = offset + 1
            if worst == nil || value < worst!.tokensLeft {
                worst = PressureReading(tokensLeft: value, lineNumber: lineNumber)
            }
        }
        return worst
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Core && swift test --filter ContextPressureExtractorTests`
Expected: PASS — 6 tests.

- [ ] **Step 5: Run the whole Core suite, then commit**

Run: `cd Core && swift test` → 0 failures (both targets; absolute counts drift — growth by the new tests is the signal, not the total).

```bash
git add Core/Sources/PortmasterCore/History/ContextPressureExtractor.swift \
        Core/Tests/PortmasterCoreTests/ContextPressureExtractorTests.swift
git commit -m "feat: the log's own tokens-left readings, minimum by line"
```

---

### Task 2: Store, poller attribution, and wire

**Files:**
- Modify: `Core/Sources/PortmasterCore/History/AgentSessionStore.swift` (model `:16-31`, snapshot `:162-171`, fetch/snapshot site `:351`)
- Modify: `Core/Sources/PortmasterCore/History/TokenSourceAdapter.swift` (defaulted protocol method)
- Modify: `Core/Sources/PortmasterCore/History/ClaudeCodeLogAdapter.swift` (override)
- Modify: `Core/Sources/PortmasterCore/History/AgentSourcePoller.swift` (pass loop `:293-302`, pass struct)
- Modify: `Core/Sources/PortmasterMCP/WirePayloads.swift` (session payload)
- Test: `Core/Tests/PortmasterCoreTests/AgentSessionStoreTests.swift`, `Core/Tests/PortmasterCoreTests/AgentSourcePollerTests.swift`
- Test: MCP session-payload test file (where `SessionPayload` is already tested)

**Interfaces:**
- Consumes: `ContextPressureExtractor.peak(in:)` → `PressureReading?` (Task 1); `LogMatch.unique(LogCandidate)` with `LogCandidate.url`.
- Produces (Task 3 relies on these exactly):
  - `AgentSession.tokensLeftFirst: Int?`, `AgentSession.tokensLeftWorst: Int?`
  - `AgentSessionSnapshot.tokensLeftFirst: Int?`, `AgentSessionSnapshot.tokensLeftWorst: Int?`
  - `AgentSessionStore.recordPressure(sessionID: UUID, tokensLeft: Int) throws`
  - `TokenSourceAdapter.contextPressure(at url: URL) -> PressureReading?` (default `nil`)
  - `AgentSourcePass.pressureUpdates: Int`
  - Wire: `SessionPayload` gains `tokensLeftFirst: Int?`, `tokensLeftWorst: Int?` — JSON `null` when absent.

- [ ] **Step 1: Write the failing store tests**

Real helpers in `AgentSessionStoreTests.swift`: `makeStoreOnDisk() throws -> (AgentSessionStore, URL)` (URL is the `.sqlite` file), `recordSession(id:peerPID:clientName:clientVersion:connectedAt:)`, `sessions() throws -> [AgentSessionSnapshot]`. Write against those:

```swift
    func testFirstReadingIsSetOnceAndWorstOnlyFalls() throws {
        let store = try makeStore()
        let id = UUID()
        try store.recordSession(id: id, peerPID: 1, clientName: "c", clientVersion: nil,
                                connectedAt: Date())
        try store.recordPressure(sessionID: id, tokensLeft: 5000)
        try store.recordPressure(sessionID: id, tokensLeft: 4000)
        try store.recordPressure(sessionID: id, tokensLeft: 6000)
        let s = try store.sessions().first { $0.id == id }!
        XCTAssertEqual(s.tokensLeftFirst, 5000, "first means first observed, set once")
        XCTAssertEqual(s.tokensLeftWorst, 4000, "worst means minimum; a later recovery is not history")
    }

    func testPressureForAnUnknownSessionRecordsNothing() throws {
        let store = try makeStore()
        try store.recordPressure(sessionID: UUID(), tokensLeft: 123)
        XCTAssertTrue(try store.sessions().isEmpty, "no row is invented for an id we do not have")
    }
```

The migration test is a third test in the same file, written exactly:

```swift
    func testAStoreWrittenBeforeTheFieldsExistedStillOpens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("agent-sessions.sqlite")

        var id: UUID
        do {
            let store = try AgentSessionStore(storeURL: fileURL)
            id = UUID()
            try store.recordSession(id: id, peerPID: 7, clientName: "c", clientVersion: nil,
                                    connectedAt: Date())
        } // store released: its container drops its connection before the ALTER below

        // Column names read from the live schema rather than guessed: CoreData's
        // Z-prefixed spelling is an implementation detail this test should not assert.
        let info = try runSQL(fileURL, "PRAGMA table_info(AgentSession);")
        XCTAssertTrue(info.contains("ZTOKENSLEFTFIRST") && info.contains("ZTOKENSWORST"),
                      "sanity: the current schema really carries the fields")
        try runSQL(fileURL, "ALTER TABLE AgentSession DROP COLUMN ZTOKENSLEFTFIRST;")
        try runSQL(fileURL, "ALTER TABLE AgentSession DROP COLUMN ZTOKENSWORST;")

        let reopened = try AgentSessionStore(storeURL: fileURL)
        let session = try reopened.sessions().first { $0.id == id }
        XCTAssertNotNil(session, "an old file must still open — lightweight migration")
        XCTAssertNil(session?.tokensLeftFirst, "not-yet-migrated means nil, never zero")
        XCTAssertNil(session?.tokensLeftWorst)
    }

    /// Runs one statement through `/usr/bin/sqlite3` in its own process — the ALTER needs
    /// the write lock, and a separate process is the honest way to know nothing local
    /// holds it. `PRAGMA table_info` returns `cid|name|type|notnull|dflt|pk`.
    private func runSQL(_ file: URL, _ sql: String) throws -> String { ... Process ... }
```

If `table_info(AgentSession)` names the table differently (SwiftData's entity naming), read the real name from `sqlite_master` first and use it — report which you found. If the ALTER cannot take the lock because the container lingers, **say so in the report**; do not skip the test quietly.

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter AgentSessionStoreTests`
Expected: FAIL — `value of type 'AgentSession' has no member 'tokensLeftFirst'`.

- [ ] **Step 3: Implement the model, fold, and snapshot**

On `AgentSession` (directly under `endedAt`):

```swift
    /// First numeric `tokens left` this session's conversation reported, per the poller.
    /// `nil` means no reading exists — never that the budget is empty.
    public var tokensLeftFirst: Int?
    /// Worst (minimum) `tokens left` observed across passes. Fold: set on first
    /// observation, thereafter `min(existing, new)` — a recovery is not a rewrite of
    /// what the session already survived.
    public var tokensLeftWorst: Int?
```

Mirror both on `AgentSessionSnapshot` (its memberwise construction site is `AgentSessionStore.swift:351`). New store method, under the same `NSLock` every other write uses:

```swift
    /// Folds one pressure observation onto the session. The only two facts kept are the
    /// first value seen and the worst value seen; intermediate values are deliberately
    /// not stored, because the strip needs a reference point and a floor, not a history.
    ///
    /// `throws` for symmetry with `recordSession`/`recordUsage` (neither has a throwing
    /// body either), and no save: persistence rides the pass's existing `flush()` at the
    /// end of `AgentSourcePoller.runPass`, so a save here would be a second write
    /// discipline to keep in step with the first.
    public func recordPressure(sessionID: UUID, tokensLeft: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard let session = fetchSession(sessionID) else { return }
        if session.tokensLeftFirst == nil { session.tokensLeftFirst = tokensLeft }
        session.tokensLeftWorst =
            session.tokensLeftWorst.map { min($0, tokensLeft) } ?? tokensLeft
    }
```

Also mirror both fields into the `AgentSessionSnapshot` literal at `AgentSessionStore.swift:351` (they are the only new values; the rest of the literal is untouched).

- [ ] **Step 4: Wire the adapter seam and the pass**

In `TokenSourceAdapter.swift`, a defaulted extension method (a format we don't know cannot claim a signal):

```swift
    /// Peak `tokens left` this source's format reports, or `nil` when it has no such
    /// signal. Defaulted so a format without the concept still conforms — absence is
    /// the answer for it, not an error.
    func contextPressure(at url: URL) -> PressureReading? { nil }
```

`ClaudeCodeLogAdapter` overrides: `func contextPressure(at url: URL) -> PressureReading? { try? ContextPressureExtractor.peak(in: url) }` — a read failure yields no reading, which is honest: we do not know, rather than knowing zero.

In the pass loop (`AgentSourcePoller.swift:293-302`), hoist `let match = matches[session.id] ?? .ambiguous(count: 0)` and use it for both the runner and, immediately after the runner's switch:

```swift
            // Pressure is attributed by the same one-to-one rule as usage: a conversation
            // two connections contend for attributes nothing, because a claim it cannot
            // support is the one thing this pass never makes.
            if case .unique(let candidate) = match,
               let reading = adapter.contextPressure(at: candidate.url) {
                do {
                    try store.recordPressure(
                        sessionID: session.id, tokensLeft: reading.tokensLeft)
                    pressureUpdates += 1
                } catch {
                    NSLog("Portmaster agent source poll could not record pressure: \(error)")
                    failures.append(AgentSourceFailure(
                        source: adapter.identifier, sessionID: session.id,
                        detail: "\(error)"))
                }
            }
```

The `do`/`catch` mirrors `recordUsage`'s in the same loop — same failure list, same log line shape, because a write that will not persist deserves the same reporting whether it is a token figure or a pressure figure.

Add `public let pressureUpdates: Int` to `AgentSourcePass`. There are exactly **two** construction sites, both in `AgentSourcePoller.swift` (`:111` empty-pass constant, `:368` returning pass) — initialise `0` at both; tests only *read* pass fields, so nothing else changes. `AppModel` consumes the counter in Task 3.

- [ ] **Step 5: Wire the session payload**

On the session payload struct in `WirePayloads.swift` (next to `peerPID`):

```swift
    /// First / worst numeric `tokens left` observed for this session. `null` when no
    /// reading exists — a client that shows `0` here is misreading the contract.
    public let tokensLeftFirst: Int?
    public let tokensLeftWorst: Int?
```

Initialise from the snapshot. Add one MCP test asserting the JSON: both `null` when the snapshot's are nil; integers when set. Match the file's existing JSON-assertion style (do not invent a new one).

- [ ] **Step 6: Write the poller tests**

Extend the suite's existing `CountingTokenAdapter` (`AgentSourcePollerTests.swift:18`) with an optional answer — no new adapter type:

```swift
    /// What `contextPressure` reports. `nil` (the default) keeps every existing test
    /// asserting what it asserted before this field existed.
    var pressure: PressureReading?
    func contextPressure(at url: URL) -> PressureReading? { pressure }
```

Then three tests, using the suite's real helpers — `makeStore()`, `recordSession(_:connectedAt:) -> UUID`, `private let overlap = 600`, `.pollOnce()`, and candidate construction copied from `testThreeSessionsShareOneAskAndDoNotShareItsFigure`:

```swift
    func testAUniqueMatchRecordsTheAdaptersPressureReading() throws {
        let store = try makeStore()
        let sessionID = try recordSession(store, connectedAt: now)
        let adapter = CountingTokenAdapter(candidates: [/* candidate spanning `now`, as in
            testThreeSessionsShareOneAskAndDoNotShareItsFigure */])
        adapter.pressure = PressureReading(tokensLeft: 14999357, lineNumber: 4)

        let pass = AgentSourcePoller(store: store, adapters: [adapter], overlap: overlap)
            .pollOnce()

        let snapshot = try store.sessions().first { $0.id == sessionID }!
        XCTAssertEqual(snapshot.tokensLeftFirst, 14999357)
        XCTAssertEqual(snapshot.tokensLeftWorst, 14999357)
        XCTAssertEqual(pass.pressureUpdates, 1, "one matched session, one update")
    }

    func testAContestedSessionGetsNoPressure() throws {
        // Two sessions whose connectedAt both fall inside one candidate — the same
        // setup testThreeSessionsShareOneAskAndDoNotShareItsFigure uses, which makes
        // every match ambiguous. Pressure set on the adapter anyway:
        // both snapshots' tokensLeftWorst stay nil, pass.pressureUpdates == 0.
        // The attribution rule is one rule, not one rule for numbers and another for text.
    }

    func testPressureIsRecordedWhenNoUsageWas() throws {
        // Same unique-match setup, adapter returns no usage (its parse returns []) but
        // pressure set: pass.records empty, pressureUpdates == 1.
        // Absence of usage and absence of pressure are independent facts.
    }
```

Bodies 2 and 3 follow body 1's exact structure; their comments state the assertions to pin.

- [ ] **Step 7: Run to verify pass**

Run: `cd Core && swift test` (one command; both `PortmasterCoreTests` and `PortmasterMCPTests` live in this package).
Expected: 0 failures, 1 pre-existing skip; Core grows by the store + poller tests, MCP by one wire test.

- [ ] **Step 8: Build and commit**

`xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build` → `** BUILD SUCCEEDED **`, zero new warnings (six pre-existing).

```bash
git add -A 'Core/Sources' 'Core/Tests' && git reset 'Core/Package.resolved'
git commit -m "feat: a session remembers the first and worst tokens-left it saw"
```

---

### Task 3: The strip above the grid

**Files:**
- Modify: `App/AppModel.swift` (`refreshAgentSessions`, near `agentSourcePassCompleted`)
- Modify: `App/OverviewView.swift` (strip above the grid; `worthALook` at `:192-228` is the shape to follow, not the type to extend)
- Test: `Core/Tests/PortmasterCoreTests/AppAgentSourceWiringTests.swift` (source-scan precedent: comments stripped before matching, whole-`App/` walk skips non-Swift files)

**Interfaces:**
- Consumes: `AgentSessionSnapshot.tokensLeftFirst/.tokensLeftWorst`, `liveSessionIDs`, `Fmt.tokens(_:)`, `refreshAgentSessions()`, `pass.pressureUpdates`.
- Produces: `AppModel.contextPressureNotice: ContextPressureNotice?`; a `ContextPressureStrip` view.

- [ ] **Step 1: Write the failing source-scan tests** (App has no test target; follow this repo's existing pattern exactly, including comment-stripping)

Pin these three claims:
1. `OverviewView.swift` renders `ContextPressureStrip` **above** the grid (assert both the call and that its source position precedes the grid's `LazyVGrid`/`grid` call).
2. The operator core `* 2 <= ` appears **exactly once** across the whole stripped `App/` tree (a second threshold is a second unvalidated policy). Assert on the operator core, not the operand names, so the test pins the policy's *site count* rather than the spelling of local variables.
3. The derivation lives in `refreshAgentSessions` — `contextPressureNotice` is assigned in exactly one file (a second assignment site is a second source of truth).

- [ ] **Step 2: Run to verify failure**

Run: `cd Core && swift test --filter AppAgentSourceWiringTests`
Expected: FAIL — strip not yet rendered.

- [ ] **Step 3: Implement**

`AppModel`:

```swift
    /// One live session whose budget has visibly eroded, worth a strip above the grid.
    struct ContextPressureNotice: Equatable {
        let sessionID: UUID
        let clientName: String?
        let tokensLeftWorst: Int
    }

    @Published private(set) var contextPressureNotice: ContextPressureNotice?
```

Derive it inside `refreshAgentSessions()` — the single place the session list is re-read, so the strip cannot disagree with the card below it:

```swift
        // Provisional: half the session's own first reading. Unvalidated against real
        // data — we have never watched a budget actually erode — so it lives at this one
        // call site, named, like the 1% disagreement tolerance. Absent first or worst
        // means no notice: we do not invent a reference point.
        contextPressureNotice = agentSessions
            .filter { liveSessionIDs().contains($0.id) }
            .compactMap { s -> ContextPressureNotice? in
                guard let first = s.tokensLeftFirst, let worst = s.tokensLeftWorst,
                      worst * 2 <= first else { return nil }
                return ContextPressureNotice(
                    sessionID: s.id, clientName: s.clientName, tokensLeftWorst: worst)
            }
            .min { $0.tokensLeftWorst < $1.tokensLeftWorst }
```

Then in `agentSourcePassCompleted`, extend the republish guard: refresh when `pressureUpdates > 0` too (a pass that moved the worst value must move the strip).

View (in `OverviewView.swift`, above the grid where `worthALook` sits):

```swift
/// The log's own words, deliberately: the number's meaning is mode-dependent and
/// unverified, so we quote what Claude Code printed and assert nothing about it.
struct ContextPressureStrip: View {
    let notice: AppModel.ContextPressureNotice
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
            Text("\(notice.clientName ?? "Agent") — \(Fmt.tokens(notice.tokensLeftWorst)) tokens left (worst observed)")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("Agent budget notice")
    }
}
```

Wire: `if let notice = model.contextPressureNotice { ContextPressureStrip(notice: notice) }` immediately above the grid. **No buttons in this plan** — the actions (Continue / Hand off) belong to the handoff plan; a button that cannot act is a lie about what exists.

- [ ] **Step 4: Run to verify pass**

Run: `cd Core && swift test --filter AppAgentSourceWiringTests`
Expected: PASS.

- [ ] **Step 5: Mutation-check, then full verification**

Deliberately break each claim and confirm the matching test goes red, then revert:
- render the strip *below* the grid → test 1 red;
- duplicate the threshold in a comment **and** a second real site → test 2 red (remember comments are stripped first, so the second must be real code);
- assign `contextPressureNotice` in a second file → test 3 red.

Then run everything and paste real output:
1. `cd Core && swift test` — 0 failures, both suites, twice.
2. `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build` — `** BUILD SUCCEEDED **`, zero new warnings.
3. `./scripts/mcp-e2e.sh --no-manual <app> <mcp>` — 17 passed, 0 failed, 1 skipped (bundle from `-showBuildSettings` `BUILT_PRODUCTS_DIR`; MCP at `Core/.build/debug/portmaster-mcp`).
4. **Run the app.** The strip needs a live session with an eroding budget to appear, which we have never observed — so the honest check is that the app runs, the Overview renders, the poller logs its pass line (`log stream` for `category == "agent-sources"`), and no console errors. Report exactly what you saw; do not claim you saw the strip unless you did.

- [ ] **Step 6: Commit**

```bash
git add -A 'App' 'Core/Tests'
git commit -m "feat: the overview says when a live session's tokens-left has eroded"
```

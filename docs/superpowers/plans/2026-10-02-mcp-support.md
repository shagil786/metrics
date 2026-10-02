# MCP Support (Slice 1: Core + CLI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `portmaster-mcp`, a stdio MCP server that lets AI assistants read Portmaster telemetry and perform gated mutations (quit/stop, allowlisted preference writes), working without the Portmaster app running.

**Architecture:** A new `PortmasterMCP` Swift library in `Core/` holds tool definitions, a `ToolExecutor` over a `DataProvider` protocol, a default-deny `PermissionGate`, and a file-based `AuditLog`. A new `portmaster-mcp` executable wires the executor to an stdio MCP server (official `modelcontextprotocol/swift-sdk`). Slice 1 uses only the `OnDemandProvider` (own `SamplingEngine` instance, on-demand sampling, 5 s cache); `LiveProvider` + in-app confirmation arrive in slice 2 per the spec.

**Tech Stack:** Swift 5 language mode, SwiftPM (tools 6.0), `modelcontextprotocol/swift-sdk` (product `MCP`), XCTest, xcodegen (`project.yml`) untouched in slice 1.

**Spec:** `docs/superpowers/specs/2026-10-02-mcp-support-design.md` — the plan argues from the spec; executors read both.

## Global Constraints

- Repository is **not a git repo** (as of 2026-10-02): skip all commit steps; a task is done when its verification commands pass. (If git has since been initialized, commit per task.)
- Tests: `cd Core && swift test` must stay green for **all** suites (147+ pre-existing tests plus these).
- App build: `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build` must stay green after the `Core/Package.swift` change.
- Language mode v5 for repo targets; platform floor macOS 14.
- Local-only surface: files under `~/.portmaster/` and stdout stdio. No sockets, no network egress in slice 1.
- Fan-speed control, push notifications, arbitrary settings writes, `MCPHost`/discovery file/streamable-HTTP: **out of scope** (spec Non-goals).
- `set_preference` allowlist is exactly: `temperatureUnit`, `networkUnit`, `cpuScale`, `temperatureSource`, `compact`, `mcpMode`. Any other key → explicit rejection error.
- Mutation modes: `off` (default), `confirmEach`, `allowSession` — default is **off**.

## Review Focus

Conditions the spec implies that a reader's happy-path tests will not catch; each is pinned to a task below:

1. **First on-demand tick is empty** — a caller must get honest "no data yet / sampler still starting", never fabricated zeros. Pinned in Task 6 (snapshot-wait timeout test).
2. **`set_preference` clobbering** — read-modify-write of the app's `PortmasterPreferences` JSON blob must preserve every sibling field and refuse unknown keys/values. Pinned in Task 5 (preserve-siblings + unknown-key tests).
3. **Mutation silently succeeding under `off`/`confirmEach`** — gate must deny before the provider is ever invoked, and the denial must be audit-logged. Pinned in Task 2 (gate matrix) and Task 5 (provider-not-called + denied-audit-entry tests).
4. **Docker daemon down / SMC unavailable** — these are unavailable *states*, not exceptions; the tool returns the UI's honest availability data. Pinned in Task 4 (daemonDown mapping test).
5. **stdio JSON-RPC framing** — the binary must complete `initialize` → `tools/list` → `tools/call` exactly as MCP clients speak it. Pinned in Task 7 (subprocess integration test).

---

### Task 1: Package scaffolding, `MCPSettings`, `AuditLog`

**Files:**
- Modify: `Core/Package.swift`
- Create: `Core/Sources/PortmasterMCP/MCPSettings.swift`
- Create: `Core/Sources/PortmasterMCP/AuditLog.swift`
- Test: `Core/Tests/PortmasterMCPTests/MCPSettingsAuditTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces (all `public`, module `PortmasterMCP`):
  - `enum MCPMutationMode: String, CaseIterable, Codable, Sendable { case off, confirmEach, allowSession }`
  - `struct MCPSettings: Sendable { var mode: MCPMutationMode; static let defaultMode: MCPMutationMode = .off; static func fileURL(directory: URL?) -> URL; static func load(directory: URL? = nil) -> MCPSettings; func save(directory: URL? = nil) throws }` — JSON file at `~/.portmaster/mcp-settings.json`; `directory` parameter exists for test injection; corrupt/missing file loads as defaults.
  - `struct AuditLog: Sendable { init(directory: URL? = nil); func record(tool: String, arguments: [String: String], outcome: String, reason: String?) }` — appends one JSON line `{ts, tool, arguments, outcome, reason, pid}` to `~/.portmaster/mcp-audit.log`, file mode `0600`, directory created `0700`.

- [ ] **Step 1: Write the failing tests**

Test file `Core/Tests/PortmasterMCPTests/MCPSettingsAuditTests.swift` (XCTest, inject a temp directory per test):

```swift
func testSettingsDefaultsToOffWhenFileMissing()        // MCPSettings.load(directory: tmp).mode == .off
func testSettingsRoundTrip()                           // save(.allowSession) in tmp dir → load == .allowSession
func testCorruptSettingsFileLoadsDefaults()            // write "not json" → load == .off
func testAuditLogAppendsOneJSONLinePerRecord()         // 2 records → 2 lines, decodable as [String: Any] with keys ts/tool/arguments/outcome/pid
func testAuditLogRecordsDenialReason()                 // record(outcome: "denied", reason: "…") → line contains that reason
func testAuditLogFileIsOwnerOnly()                     // after record, file permissions == 0o600
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Core && swift test --filter MCPSettingsAuditTests`
Expected: FAIL — target `PortmasterMCPTests` does not exist (or module missing).

- [ ] **Step 3: Scaffold the package**

Edit `Core/Package.swift`: add dependency
`.package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "<latest release tag>")`
— first run `git ls-remote --tags --sort=-v:refname https://github.com/modelcontextprotocol/swift-sdk | head -5` to pick the tag, and confirm the local toolchain parses it (`swift --version` must be ≥ 6.1 because the SDK declares tools 6.1; if the toolchain is older, stop and ask the human to upgrade Xcode rather than forking the SDK). Add targets:

```swift
.target(name: "PortmasterMCP", dependencies: ["PortmasterCore", .product(name: "MCP", package: "swift-sdk")],
        swiftSettings: [.swiftLanguageMode(.v5)]),
.executableTarget(name: "portmaster-mcp", dependencies: ["PortmasterMCP"],
        swiftSettings: [.swiftLanguageMode(.v5)]),
.testTarget(name: "PortmasterMCPTests", dependencies: ["PortmasterMCP"],
        swiftSettings: [.swiftLanguageMode(.v5)])
```

Add the `MCP` product also to nothing else. Create empty `Sources/PortmasterMCP/.keep`-style placeholder plus a minimal `Sources/portmaster-mcp/main.swift` containing `print("")` (replaced in Task 7) so all targets compile.

- [ ] **Step 4: Implement `MCPSettings` and `AuditLog`**

Per the Produces block; use `FileManager` for directory creation with `0700` and `chmod(0o600)` on the log file. JSON via `JSONEncoder`/`JSONDecoder`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd Core && swift test --filter MCPSettingsAuditTests`
Expected: PASS (6 tests).

- [ ] **Step 6: Full regression check**

Run: `cd Core && swift test`
Expected: PASS — all pre-existing suites still green.

---

### Task 2: `PermissionGate`

**Files:**
- Create: `Core/Sources/PortmasterMCP/PermissionGate.swift`
- Test: `Core/Tests/PortmasterMCPTests/PermissionGateTests.swift`

**Interfaces:**
- Consumes: `MCPMutationMode`, `MCPSettings` (Task 1).
- Produces:
  - `enum GateDecision: Equatable, Sendable { case allow; case deny(reason: String) }`
  - `struct PermissionGate: Sendable { init(settings: MCPSettings, appRunning: Bool); func decide(isMutation: Bool) -> GateDecision }`

Exact decision table (slice-1 semantics, per spec):

| mode | read | mutation |
|---|---|---|
| `off` | allow | deny `"MCP mutations are disabled in Portmaster settings."` |
| `confirmEach` | allow | deny `"Portmaster must be open to approve this action."` (slice 1 has no `MCPHost`; Task 8 documents this) |
| `allowSession` | allow | `appRunning == true` → allow; else deny `"Session grants apply only while Portmaster is running."` |

- [ ] **Step 1: Write the failing test**

`PermissionGateTests.swift`:

```swift
func testReadsAlwaysAllowedInEveryMode()               // 3 modes × decide(isMutation: false) == .allow
func testOffDeniesMutationsWithExactReason()           // reason == "MCP mutations are disabled in Portmaster settings."
func testConfirmEachDeniesEvenWhenAppRunning()         // mode .confirmEach, appRunning true → deny, reason == "Portmaster must be open to approve this action."
func testAllowSessionAllowsWhenAppRunning()
func testAllowSessionDeniesWhenAppClosed()             // reason == "Session grants apply only while Portmaster is running."
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter PermissionGateTests`
Expected: FAIL — `PermissionGate` not found.

- [ ] **Step 3: Implement the decision table** in `PermissionGate.swift` (a `switch` over `settings.mode`; reads return `.allow` before the switch).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Core && swift test --filter PermissionGateTests`
Expected: PASS (5 tests).

---

### Task 3: `DataProvider` protocol, tool catalog, `ToolExecutor` (snapshot reads)

**Files:**
- Create: `Core/Sources/PortmasterMCP/DataProvider.swift`
- Create: `Core/Sources/PortmasterMCP/ToolExecutor.swift`
- Test: `Core/Tests/PortmasterMCPTests/ToolExecutorReadTests.swift`
- Test helper (same file or `StubProvider.swift`): `final class StubProvider: DataProvider`

**Interfaces:**
- Consumes: `PermissionGate`, `AuditLog` (Tasks 1–2); `PortmasterCore` types (`SystemSample`, `AppRollup`, `DockerSample`, `AppHistoryTrend`, `HistoryResource`, `ThermalSample`, `ActingUpAlert`, `AppPreferences`).
- Produces:
  - `enum AppMetric: String, Sendable { case cpu, memory, network, disk }`
  - `enum HistoryWindow: String, Sendable { case h1 = "1h", h12 = "12h", h24 = "24h", d7 = "7d", d30 = "30d"; var since: Date { … } }` (now minus 1 h/12 h/24 h/7 d/30 d)
  - `struct ProjectSummary: Codable, Sendable { let id: String; let name: String; let processCount: Int; let ports: [Int] }`
  - `struct SettingsSnapshot: Codable, Sendable { let temperatureUnit: String; let networkUnit: String; let cpuScale: String; let temperatureSource: String; let compactMenuBar: Bool; let mutationMode: String; let alertsEnabled: Bool; let retention: String }`
  - `struct StopReport: Codable, Sendable { let results: [String: String] }` — keys `"<pid>"`, values `"stopped" | "failed: <msg>" | "unsupported"` (derived from `StopCoordinator.Outcome.Status`).
  - `struct ToolOutcome: Sendable { let text: String; let isError: Bool }`
  - `struct MCPToolError: Error, Equatable, Sendable { let message: String }`
  - `protocol DataProvider: Sendable` — full method list:

```swift
func systemOverview() async throws -> SystemSample
func topApps(metric: AppMetric, limit: Int) async throws -> [AppRollup]
func appDetail(id: String) async throws -> AppRollup
func containers() async throws -> DockerSample
func projects() async throws -> [ProjectSummary]
func historyRankings(window: HistoryWindow, resource: HistoryResource?) async throws -> [AppHistoryTrend]
func temperaturesFans() async throws -> ThermalSample?
func activeAlerts() async throws -> [ActingUpAlert]
func settingsSnapshot() -> SettingsSnapshot
func quitApp(id: String, force: Bool) async throws -> StopReport
func stopContainer(id: String) async throws -> StopReport
func stopProject(id: String) async throws -> StopReport
func setPreference(key: String, value: String) throws
```

  - `struct ToolDefinition: Sendable { let name: String; let description: String; let arguments: [(name: String, required: Bool, help: String)] }`
  - `struct ToolExecutor: Sendable { init(provider: DataProvider, gate: PermissionGate, audit: AuditLog); static let catalog: [ToolDefinition]; func execute(name: String, arguments: [String: String]) async -> ToolOutcome }`

`execute` contract: unknown tool → `ToolOutcome(text: "Unknown tool: <name>", isError: true)`; missing required argument → `"Missing argument: <arg>"`; any thrown error → `MCPToolError.message` text with `isError: true`; success → JSON-encoded payload of the returned model via `JSONEncoder` (sorted keys for test stability).

This task implements only: `get_system_overview`, `get_top_apps`, `get_app_detail`. Catalog declares all 13 tools (9 read + 4 mutation) with descriptions now; unimplemented names return `"Tool not implemented yet"` error until Tasks 4–5.

- [ ] **Step 1: Write the failing tests**

`ToolExecutorReadTests.swift` with a `StubProvider` (stored canned values, call counters, per-method thrown error):

```swift
func testOverviewReturnsSystemSampleJSON()             // execute("get_system_overview") → !isError, JSON has "cpu" key
func testTopAppsSortsByCPUDescendingAndHonorsLimit()   // metric "cpu", limit "2" → 2 rollups, first has highest totalCPU
func testTopAppsNetworkSortsNilRatesLast()             // stub rollups with nil totalNetInBytesPerSec sort after known values
func testAppDetailUnknownIDIsError()                   // id "nope" → isError, message contains "not found"
func testMissingArgumentIsError()                      // get_app_detail without id → text == "Missing argument: id"
func testUnknownToolIsError()
func testUnimplementedToolIsError()                    // e.g. get_containers → isError (until Task 4)
func testPermissionDeniedDoesNotCallProvider()         // gate mode .off; execute("quit_app", …) → isError; stub.quitAppCallCount == 0
func testSuccessfulMutationWritesAuditEntry()          // mode .allowSession + appRunning; quit_app → audit file gains outcome "allowed"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Core && swift test --filter ToolExecutorReadTests`
Expected: FAIL — module/types missing.

- [ ] **Step 3: Implement `DataProvider.swift` and `ToolExecutor.swift`**

`execute` flow: look up catalog → validate required args → if mutation (name in mutation set `["quit_app","stop_container","stop_project","set_preference"]`) run `gate.decide(isMutation: true)`, audit the decision, and on `.deny` return `isError` without touching the provider → dispatch to the provider method → encode result. `get_top_apps` metric mapping: `cpu → totalCPU`, `memory → totalMemory` (both non-optional), `network → totalNetInBytesPerSec`, `disk → totalDiskWriteBytesPerSec` (nil-safe: nil sorts last).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter ToolExecutorReadTests`
Expected: PASS (9 tests).

---

### Task 4: Remaining read tools in `ToolExecutor`

**Files:**
- Modify: `Core/Sources/PortmasterMCP/ToolExecutor.swift`
- Test: `Core/Tests/PortmasterMCPTests/ToolExecutorReadMoreTests.swift`

**Interfaces:**
- Consumes: Task 3's `ToolExecutor.execute`, `DataProvider`, stub.
- Produces: same interface; the previously-unimplemented read names now dispatch: `get_containers`, `get_projects`, `get_history_rankings`, `get_temperatures_fans`, `get_active_alerts`, `get_settings`.

Dispatch semantics (pin exactly):
- `get_containers` → provider `containers()`; output includes `availability` field from `DockerSample.availability` (`.notInstalled` / `.daemonDown` / running) plus container list — an availability problem is **data**, `isError: false`.
- `get_projects` → `projects()`; argument: none.
- `get_history_rankings` → args: `range` (required, one of `1h|12h|24h|7d|30d` → `HistoryWindow`, else error `"Invalid range: <v>"`), `resource` (optional, `HistoryResource.rawValue` else error `"Invalid resource: <v>"`; absent → app trends).
- `get_temperatures_fans` → `temperaturesFans()`; `nil` sample → `{"available": false}` not an error.
- `get_active_alerts` → `activeAlerts()`; output array + `source` field supplied by provider payload (live vs history-approximate — see Task 6).
- `get_settings` → `settingsSnapshot()`.

- [ ] **Step 1: Write the failing tests**

```swift
func testContainersDaemonDownIsDataNotError()          // stub DockerSample(availability: .daemonDown, containers: []) → isError false, text contains "daemonDown"
func testProjectsDerivesSummaryFields()                // (stub returns prebuilt summaries) → JSON has id/name/processCount/ports
func testHistoryRankingsInvalidRangeIsError()          // range "3h" → isError, text == "Invalid range: 3h"
func testHistoryRankingsValidRangeMapsSinceDate()      // capture provider-received HistoryWindow == .h12 for "12h"
func testHistoryRankingsInvalidResourceIsError()
func testTemperaturesUnavailableIsDataNotError()       // nil → text contains "\"available\":false"
func testGetActiveAlertsReturnsAlertJSON()
func testGetSettingsReturnsSnapshotJSON()              // has "mutationMode" key
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Core && swift test --filter ToolExecutorReadMoreTests`
Expected: FAIL — tools return `"Tool not implemented yet"`.

- [ ] **Step 3: Implement the six dispatch cases** per the semantics above.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter ToolExecutorReadMoreTests`
Expected: PASS (8 tests).

---

### Task 5: Mutation tools in `ToolExecutor` (gate, audit, allowlist)

**Files:**
- Modify: `Core/Sources/PortmasterMCP/ToolExecutor.swift`
- Test: `Core/Tests/PortmasterMCPTests/ToolExecutorMutationTests.swift`

**Interfaces:**
- Consumes: `PermissionGate`, `AuditLog`, `DataProvider`, `StopReport` (Tasks 1–3).
- Produces: mutation dispatch inside `execute`; allowlist constant `ToolExecutor.allowedPreferenceKeys: Set<String> = ["temperatureUnit", "networkUnit", "cpuScale", "temperatureSource", "compact", "mcpMode"]` (`mcpMode` writes `MCPSettings` directly, not app prefs).

Dispatch semantics:
- `quit_app` → args `id` (required), `force` (optional, `"true"`/`"false"`, default false) → `provider.quitApp(id:force:)`.
- `stop_container` → `id` required → `provider.stopContainer(id:)`.
- `stop_project` → `id` required → `provider.stopProject(id:)`.
- `set_preference` → `key` + `value` required; key ∉ allowlist → `MCPToolError("Preference '<key>' cannot be changed via MCP. Allowed: <sorted list>.")`; else `provider.setPreference(key:value:)` (invalid enum value errors surface from the provider).
- Every mutation attempt: `audit.record(...)` with outcome `"allowed"` or `"denied"` + gate reason, **before** dispatch (deny) or after provider result (allowed/failed — outcome `"allowed"` with provider errors reported as tool error text, since the gate allowed the attempt).

- [ ] **Step 1: Write the failing tests**

```swift
func testQuitAppPassesForceFlagToProvider()            // allowSession+appRunning, force "true" → stub received force == true; outcome isError false
func testStopContainerRequiresID()
func testDeniedMutationAuditsDenial()                  // mode .off → audit line outcome "denied", provider untouched
func testSetPreferenceRejectsUnknownKey()              // key "launchAtLogin" → isError, message contains "cannot be changed via MCP", provider untouched
func testSetPreferenceAllowlistsUnits()                // key "temperatureUnit", value "fahrenheit" → provider called with both
func testSetPreferenceMcpModeWritesSettingsFile()      // key "mcpMode", value "allowSession" → MCPSettings.load(dir) == .allowSession (inject dir via settings provider seam)
func testProviderFailureBecomesToolError()             // stub throws StopError… → isError true, text contains provider message
```

Note on `testSetPreferenceMcpModeWritesSettingsFile`: to keep this testable, `ToolExecutor` gets an extra init parameter `settingsDirectory: URL? = nil` threaded into the `mcpMode` write path (defaults to production location).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Core && swift test --filter ToolExecutorMutationTests`
Expected: FAIL — mutations return `"Tool not implemented yet"`.

- [ ] **Step 3: Implement mutation dispatch + allowlist** per semantics.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter ToolExecutorMutationTests`
Expected: PASS (7 tests).

---

### Task 6: `OnDemandProvider`

**Files:**
- Create: `Core/Sources/PortmasterMCP/OnDemandProvider.swift`
- Test: `Core/Tests/PortmasterMCPTests/OnDemandProviderTests.swift`

**Interfaces:**
- Consumes: `DataProvider` protocol (Task 3); `PortmasterCore`: `SamplingEngine` (default collectors, `refreshNow()`, `latest`, `setSurfaceVisible(true)`), `HistoryStore.defaultStoreURL()` + `makeReader()`, `HistoryReader.appTrends(since:)`/`resourceSamples(_:since:)`, `StopCoordinator(KillProcessController())`, `ConfirmedProcess.project/process/ordered`, `AppPreferences.load/save(to:)`, `UserDefaults(suiteName: "dev.portmaster.app")`.
- Produces:

```swift
public struct OnDemandProvider: DataProvider {
    public init(snapshotSource: SnapshotSource = .live(engineFactory: DefaultEngineFactory()),
                 historyReader: HistoryReading? = nil,          // nil → HistoryStore at default URL
                 appRunning: @escaping @Sendable () -> Bool = { AppLiveness.isPortmasterRunning() },
                 cacheTTL: TimeInterval = 5,
                 now: @escaping @Sendable () -> Date = Date.init,
                 preferencesDomain: String = "dev.portmaster.app",
                 settingsDirectory: URL? = nil)
}
public enum AppLiveness { public static func isPortmasterRunning() -> Bool }  // NSRunningApplication.runningApplications(withBundleIdentifier: "dev.portmaster.app").nonEmpty
protocol SnapshotSource: Sendable { func currentSnapshot(maxWait: TimeInterval) async throws -> ObservationSnapshot }
```

`SnapshotSource.live` builds one long-lived `SamplingEngine` (surface visible, started lazily on first call), and `currentSnapshot` waits until `latest.at` advances past the call start or `maxWait` (default 10 s) elapses → on timeout throw `MCPToolError("No reading available yet; the sampler is still starting.")` (**Review Focus #1**: never return `.empty` as if it were data).

Method semantics:
- All snapshot reads (`systemOverview`, `topApps`, `appDetail`, `containers`, `projects`, `temperaturesFans`) call `currentSnapshot`, cache the snapshot 5 s (`cacheTTL`) keyed by wall time (`now()`), then map. `projects()` derives `ProjectSummary` by grouping `snapshot.processes` on `projectID` (skip nil), name = last path component of the id, ports = `snapshot.ports` whose `pid` is in the group, `port` field of `ListeningPort`.
- `historyRankings` → `HistoryReader.appTrends(since: window.since)` or `resourceSamples(_:since:)` mapped into the same trend shape (resource mode returns one synthetic trend per point is wrong — instead return raw points encoded by executor: see note below).
- `activeAlerts` → best-effort history evaluation (spec: poll, honest): if reader has samples within the last 10 minutes, evaluate sustained CPU (`AppHistoryTrend.averageCPU >= AlertEngine.cpuThreshold` over `since: now-10min`) and memory growth (`peakMemory` delta ≥ `AlertEngine.memGrowthBytes` over `since: now-1h`) into `ActingUpAlert`s with `id` prefixed `"history:"`; attach `source: "history-approximate"` in executor output. If no samples in window → empty array, same source note. Live per-app disk/network hammering remains live-only (spec Task 6 note → README).
- `settingsSnapshot()` → `AppPreferences.load(from: UserDefaults(suiteName: "dev.portmaster.app") ?? .standard)` mapped to `SettingsSnapshot` + `MCPSettings.load(directory:)` mode.
- `quitApp/stopContainer/stopProject` → build `[ConfirmedProcess]` from a fresh snapshot (`appDetail`-style lookup / container id match / `ConfirmedProcess.project(id:rows:)`), then `StopCoordinator(KillProcessController()).stopConfirmed(targets, force:)` → map `Outcome.Status` to `StopReport.results`. Own PID exclusion is handled by `ConfirmedProcess` factories (`ownPID: getpid()`).
- `setPreference` → if `appRunning()` throw `MCPToolError("Portmaster is running; close it before changing preferences via MCP (live writes arrive with the MCP host).")` (**Review Focus #2** lives here): otherwise read the app-domain blob (`UserDefaults(suiteName: prefsDomain)?.data(forKey: AppPreferences.defaultsKey)`), decode `AppPreferences`, mutate only the allowlisted field, re-encode, write back — sibling fields preserved by construction; `mcpMode` short-circuits to `MCPSettings.save` instead.
  - Value validation: enum fields accept only their `enum` raw values (e.g. `temperatureUnit`: `celsius|fahrenheit`), `compact`: `true|false` — else `MCPToolError("Invalid value '<v>' for '<key>'.")`.

- [ ] **Step 1: Write the failing tests**

Use a stub `SnapshotSource` returning canned `ObservationSnapshot`s and a temp history store seeded via `HistoryStore` fixtures; inject temp dirs for settings/preferences (preferences: inject `UserDefaults(suiteName:)` alternative — add `preferencesDefaults: UserDefaults` init parameter instead of only a domain string; default to `UserDefaults(suiteName: "dev.portmaster.app") ?? .standard`).

```swift
func testSnapshotTimeoutThrowsHonestError()            // stub source never advances → throws message == "No reading available yet; the sampler is still starting."
func testSnapshotCachedWithinTTL()                     // source call counter == 2 after two reads inside TTL; == 3 after now() advances past TTL
func testProjectsGroupsProcessesAndJoinsPorts()
func testContainersMapsAvailabilityThrough()           // daemonDown snapshot → DockerSample returned intact
func testActiveAlertsWithStaleHistoryReturnsEmptyWithSource()
func testActiveAlertsFromHistoryApproximation()        // seeded trends avg 60% CPU → 1 alert, id prefix "history:"
func testSetPreferenceAppOpenDenies()                  // appRunning true → throws "…close it before…"
func testSetPreferenceWritesAllowlistedFieldOnly()     // seed prefs blob with menuBarMetric .network; write temperatureUnit; reload → unit changed AND menuBarMetric still .network (**Review Focus #2**)
func testSetPreferenceInvalidValueThrows()
func testQuitAppStopsStubbedPids()                     // use a process-controller seam: inject `ProcessControlling` mock recording pids (add init param `stopController: ProcessControlling = KillProcessController()`)
```

Note: make `OnDemandProvider` take injectable `processController` and `preferencesDefaults` seams in its init so no test signals a real process or touches real preferences.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd Core && swift test --filter OnDemandProviderTests`
Expected: FAIL — type missing.

- [ ] **Step 3: Implement `OnDemandProvider` + `AppLiveness` + `SnapshotSource`** per the Produces block.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd Core && swift test --filter OnDemandProviderTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Full regression**

Run: `cd Core && swift test`
Expected: all green.

---

### Task 7: `portmaster-mcp` stdio executable + integration test

**Files:**
- Modify: `Core/Sources/portmaster-mcp/main.swift`
- Test: `Core/Tests/PortmasterMCPTests/CLIIntegrationTests.swift`

**Interfaces:**
- Consumes: `ToolExecutor` (+ `catalog`), `OnDemandProvider`, `PermissionGate`, `AuditLog` (Tasks 1–6); MCP SDK (`import MCP`) — verify exact API names against the pinned SDK docs (`swift build` errors are the source of truth; the SDK provides `Server`, a stdio transport, and list/call tool handlers).
- Produces: executable product `portmaster-mcp` that speaks MCP over stdin/stdout: `initialize` handshake, `tools/list` from `ToolExecutor.catalog` (names, descriptions, JSON-schema-ish argument hints), `tools/call` → `executor.execute(name:arguments:)` with `arguments` coerced to `[String: String]` (non-string JSON values stringified; missing → `[:]`).

- [ ] **Step 1: Write the failing integration test**

`CLIIntegrationTests.swift` — locate the binary once per run via `Process` on `swift build --show-bin-path` (build the product first with `swift build --product portmaster-mcp` in `setUp` if the binary is absent):

```swift
func testInitializeToolsListAndCallGetSettings() async throws
// spawn binary; write newline-delimited JSON-RPC:
// 1) {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}
// 2) {"jsonrpc":"2.0","method":"notifications/initialized"}
// 3) {"jsonrpc":"2.0","id":2,"method":"tools/list"}
// 4) {"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_settings","arguments":{}}}
// assert: reply 1 has "serverInfo"; reply 3 lists exactly the 13 catalog names;
//         reply 4 result has "content" whose text parses as JSON with "mutationMode"
func testUnknownToolCallReturnsToolError()             // tools/call name "nope" → result.isError == true
```

Skip (not fail) with `XCTSkip` if `swift build` of the product fails for toolchain reasons unrelated to the test, but never skip on assertion failures.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Core && swift test --filter CLIIntegrationTests`
Expected: FAIL — binary is a stub (`print("")`), no MCP responses.

- [ ] **Step 3: Implement `main.swift`**

Build `ToolExecutor(provider: OnDemandProvider(), gate: PermissionGate(settings: .load(), appRunning: AppLiveness.isPortmasterRunning()), audit: AuditLog())`; register catalog + dispatch on an MCP `Server` over stdio; run until EOF. Keep `main.swift` thin — any logic beyond wiring belongs in a `CLI` helper in the library (testable).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Core && swift test --filter CLIIntegrationTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Full regression**

Run: `cd Core && swift test`
Expected: all green.

---

### Task 8: README docs, end-to-end manual verification, final gate

**Files:**
- Modify: `README.md` (add an "MCP (AI assistants)" section)

**Interfaces:**
- Consumes: everything above.
- Produces: documentation only.

- [ ] **Step 1: Write the README section**

Cover: what it is (1 paragraph); build (`cd Core && swift build -c release --product portmaster-mcp`); register with Claude Code (`claude mcp add portmaster -- ~/.portmaster/bin/portmaster-mcp` — use `swift build --show-bin-path -c release` for the real path); tool list table (13 tools, one line each); mutation modes + how to flip `mcpMode` (`~/.portmaster/mcp-settings.json`, default `off`); audit log location (`~/.portmaster/mcp-audit.log`); slice-1 limitations (`confirmEach` always asks for a running Portmaster window that cannot approve yet — use `allowSession` with the app open; preference writes require the app closed; alerts are history-approximate; live provider/MCP host coming in slice 2).

- [ ] **Step 2: Manual end-to-end read**

Run:
```bash
cd Core && swift build --product portmaster-mcp
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_system_overview","arguments":{}}}' \
 | .build/debug/portmaster-mcp
```
Expected: JSON-RPC replies; the `tools/call` result contains a real CPU/memory payload or the honest "still starting" error — never fabricated zeros.

- [ ] **Step 3: Manual mutation gate check**

Run the same pipeline with `tools/call` `quit_app` while `mcp-settings.json` is default (`off`).
Expected: `isError` true, text `"MCP mutations are disabled in Portmaster settings."`; `~/.portmaster/mcp-audit.log` gained a `denied` line.

- [ ] **Step 4: App regression build**

Run: `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build`
Expected: BUILD SUCCEEDED (package change didn't break the app target).

- [ ] **Step 5: Full test suite + cleanup**

Run: `cd Core && swift test`
Expected: all suites green. Confirm no debug prints left in `main.swift`; confirm `git status` (if a repo now exists) shows only intended files.

---

## Self-review record

- **Spec coverage:** components (Tasks 1–3, 6–7), tool catalog incl. all 13 tools (3–5), permission gate + audit (2, 5), data flows (6), security (local files, 0600, allowlist — 1, 5, 6), error handling (3, 4, 6), testing strategy (each task), non-goals (Global Constraints). Slice 2/3 transports deliberately absent. Gap found and closed: spec's "token-checked discovery file" belongs to slice 2 and is excluded here; app-liveness in slice 1 uses `NSRunningApplication` instead (documented in Task 6/8).
- **Type consistency:** `PermissionGate(settings:appRunning:)`, `ToolExecutor(provider:gate:audit:settingsDirectory:)`, `DataProvider` signatures, and allowlist strings are used identically across Tasks 2–7.
- **Review Focus:** all five lines have owning tasks with named tests (1→Task 6, 2→Task 5+6, 3→Tasks 2+5, 4→Task 4, 5→Task 7).
- **Proportion:** code blocks are signatures, decision tables, and test names; bodies are left to implementers.

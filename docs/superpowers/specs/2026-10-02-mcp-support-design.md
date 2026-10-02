# MCP Support for Portmaster — Design

Date: 2026-10-02
Status: Approved design, pending spec review
Path: Architectural

## Goal

Make Portmaster queryable and controllable by AI assistants (Claude Code,
Cursor, ChatGPT desktop, etc.) via the Model Context Protocol, matching the
"your AI can ask Vitals" direction Vitals has announced but not shipped.

## Decisions (from brainstorming)

1. **Scope:** read tools + mutating actions (quit/stop) + alerts/config
   (alerts read/poll; settings read plus limited allowlisted writes).
2. **Deployment:** both — a `portmaster-mcp` stdio CLI and an in-app host.
   The CLI is a thin client: it talks to the running app for live data and
   falls back to on-demand sampling when the app is closed.
3. **Mutation gating:** configurable, default-deny. Modes: Off / Confirm each
   (in-app confirmation sheet) / Allow session. Every mutation attempt is
   audit-logged.
4. **Alerts/config:** polling tool for alerts (no push notifications);
   `set_preference` restricted to an allowlist (units, menu-bar/layout
   basics, MCP permissions).

## Approach

Shared MCP core with two hosts (Approach 1, chosen over app-only HTTP and
standalone-only variants), built incrementally:

- **Slice 1 (this plan):** `PortmasterMCP` library + `portmaster-mcp` CLI
  (stdio) with both providers, permission gate, audit log.
- **Slice 2 (later, out of scope here):** app's `MCPHost` over a Unix socket,
  confirmation-sheet integration, discovery file.
- **Slice 3 (optional, later):** streamable-HTTP transport on `127.0.0.1`
  for URL-based clients (e.g. ChatGPT desktop).

Native Swift only: the official `modelcontextprotocol/swift-sdk` provides
server support; no Node dependency.

## Components

### 1. `PortmasterMCP` library (new target in `Core/`)

Transport-agnostic brain:

- `ToolExecutor` — implements every tool against the data layer; single
  source of tool behavior for all hosts/transports.
- `DataProvider` protocol — data access abstraction with two
  implementations:
  - `LiveProvider` — IPC client to the running app (slice 2; slice 1
    constructs it only to detect app availability and otherwise falls back).
  - `OnDemandProvider` — runs `PortmasterCore` collectors directly per
    call, with a 5-second result cache to avoid hammering `lsof`/SMC.
    Uses `FixtureCollectors` in tests.
- `PermissionGate` — evaluates mode × app-up/down × tool class; default-deny
  for mutations. Modes stored in shared preferences:
  - `off` — mutations refused outright.
  - `confirmEach` — mutation requires the app open (confirmation sheet).
    Slice 1 (no `MCPHost` yet) always returns "Portmaster must be open to
    approve" when a mutation is attempted; slice 2 wires the sheet.
  - `allowSession` — mutations auto-approved while the app is running
    (app liveness = discovery file present and pid alive, even in slice 1
    before `MCPHost` exists); denied when closed; always audit-logged.
- `AuditLog` — append-only file `~/.portmaster/mcp-audit.log`; one line per
  mutation attempt (granted or denied): timestamp, tool, args, outcome,
  client pid.
- Tool registration on `modelcontextprotocol/swift-sdk`.

### 2. `portmaster-mcp` executable (new CLI target)

Stdio MCP server for Claude Code / Cursor. On each tool call it selects the
provider: `MCPHost` reachable (slice 2+) → `LiveProvider`; otherwise →
`OnDemandProvider` with a fallback warning prefix on read results. In
slice 1 there is no `MCPHost`, so all reads are on-demand; the availability
probe still runs so `allowSession` can evaluate app liveness.

### 3. App-side `MCPHost` (slice 2, specified here for coherence)

Serves the same `ToolExecutor` over a Unix domain socket at
`~/.portmaster/mcp.sock` (mode `0600`), writing a discovery file
`{socket, token, pid}` on launch and removing it on quit. Random token
validated on every request. Mutations arriving here pop the existing
confirmation sheet and wait up to 60 s (timeout → denied + audit entry).
Settings gains an MCP section: mode radio (Off / Confirm each / Allow
session) and audit-log path display.

## Tool catalog

### Read tools (always available)

| Tool | Args | Source |
|---|---|---|
| `get_system_overview` | — | snapshot: CPU/mem/disk/net/GPU/temps |
| `get_top_apps` | metric, limit | `AppRollup` |
| `get_app_detail` | app id | rollup + inside-app breakdown |
| `get_containers` | — | container collector |
| `get_projects` | — | project attribution + ports |
| `get_history_rankings` | range (1h/12h/24h/7d/30d), metric | `HistoryStore` |
| `get_temperatures_fans` | — | SMC collector |
| `get_active_alerts` | — | `AlertEngine`, evaluated fresh per call |
| `get_settings` | — | current prefs |

### Mutation tools (gated)

| Tool | Args | Flow |
|---|---|---|
| `quit_app` | app id, force? | `StopCoordinator` confirmed flow |
| `stop_container` | container id | `StopCoordinator` |
| `stop_project` | project id | whole-project stop with membership checks |
| `set_preference` | key, value | allowlist only; non-allowlisted keys are rejected with an explicit error, not silently ignored |

## Data flow

- **App open:** tool call → `LiveProvider` → Unix socket → app's
  `ToolExecutor` → `SamplingEngine` snapshot (~1 s fresh); mutation path
  pops the confirm sheet, response waits ≤ 60 s.
- **App closed:** tool call → `OnDemandProvider` → collectors per call
  (5 s cache); reads succeed with a fallback-warning prefix;
  `confirmEach`/`off` mutations deny with a plain-language message;
  `allowSession` mutations deny when closed (session = app running).
  Headless mutation without the app is an explicit non-goal of v1.

## Security

- Socket owner-only (`0600`); random token checked per request.
- Mutations default-deny; every attempt audit-logged.
- Allowlist enforced server-side for `set_preference`.
- Read tools expose only data the app already displays; no new data-access
  surface beyond existing collectors.

## Error handling

- Provider unavailable / token mismatch → tool `isError` with plain-language
  message.
- Fallback reads succeed with a warning prefix noting on-demand data.
- Confirm timeout (60 s) → denied + audit entry.
- Collector failure (e.g., Docker daemon down) → returns the same
  unavailable state the UI renders, not an exception.
- `OnDemandProvider` startup failure → tool error naming the failing
  collector.

## Testing

- Unit (`Core/Tests`): `ToolExecutor` against fixtures — every tool, happy
  and failure paths; `PermissionGate` matrix (mode × app-up/down ×
  allowlist); audit-log format.
- IPC: protocol encode/decode round-trips; auth rejection (slice 2).
- Integration: spawn `portmaster-mcp`, drive stdio JSON-RPC
  (`initialize` → `tools/list` → `tools/call`), assert responses.
- Live: register in Claude Code, verify a read end-to-end; mutations
  verified manually against the confirm sheet (slice 2).

## Non-goals / explicit exclusions

- Fan-speed control remains out of scope (SMC writes; matches parity-audit
  policy).
- Push notifications for alerts (unreliable across MCP clients).
- Arbitrary settings writes.
- Slice 2/3 transports and headless mutation.

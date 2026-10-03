# MCP Slice 2 — Live App Host, In-App Confirmation, Settings — Design

Date: 2026-10-02
Status: Approved design, pending spec review
Path: Architectural
Builds on: `docs/superpowers/specs/2026-10-02-mcp-support-design.md` (slice 1, merged)

## Goal

Make the running Portmaster app an MCP server over a local socket, so an AI
client reads live telemetry instead of a cold sweep, and so `confirmEach`
mutations are approved by a person in a window instead of always refusing.
Keeping slice 1's on-demand path as the fallback means the server still works
with the app closed.

## Decisions (from brainstorming)

| # | Decision |
|---|---|
| 1 | Full slice 2 as specified: app-hosted executor, live reads, real confirmation, Settings section, liveness tracking. |
| 2 | Transport: Unix domain socket at `~/.portmaster/mcp.sock` (0600) plus a rotating token in a discovery file. |
| 3 | Confirmation surfaces in a dedicated small window (not a notification, not the popover). |
| 4 | Under `confirmEach`, **every** mutation is approved by a person — process stops, container stops, and `set_preference`. |
| 5 | Slice 2 also absorbs the deferred honesty fixes (`AlertSource.live`, thermal availability) and the tidy-ups (payload split, malformed-mutation audit line, flaky engine-probe skip). |
| 6 | Socket-first with on-demand fallback; `PORTMASTER_MCP=on-demand` forces the fallback even when the app is up. |
| 7 | The socket carries **MCP JSON-RPC verbatim**. The app is a full MCP server; the CLI relays and only falls back to its own executor when the socket is unavailable. |
| 8 | Auth: owner-only socket **and** a random token, minted per app launch, compared in constant time. |
| 9 | Settings → MCP: mode radio, status line, audit log path + Reveal in Finder, "Copy install command", and a connected-clients list (pid, last call). |
| 10 | Testing: the risky logic lives in the library and is covered by `swift test` over a real socket, plus one scripted end-to-end run against the real app. |

## Architecture

One protocol, two hosts of the same `ToolExecutor`, one authority per call.

```
Claude Code ──stdio──> portmaster-mcp ──┬── socket (app live) ──> MCPHostServer ──> ToolExecutor
                                        │                            reads: AppModel.snapshot
                                        │                            mutation: ConfirmationBroker ─> window
                                        └── on-demand fallback ──> ToolExecutor (local)
```

The app is a second MCP server with a different transport; the CLI becomes a
router. Slice 3's streamable-HTTP endpoint is "the same server, one more
listener" — no second protocol.

## Components

### Library (`Core/Sources/PortmasterMCP/`)

- `EndpointFile` — writes and reads `~/.portmaster/mcp-endpoint.json`
  (`{socket, token, pid}`), file `0600` inside a `0700` directory. The app
  mints a fresh 32-byte hex token per launch and removes the file on quit.
  Constant-time comparison lives here. Also exposes staleness (socket missing,
  pid not alive) so a crash degrades to the fallback rather than an error.
- `MCPHostServer` — Unix socket listener: bind (cleaning a stale socket),
  accept, authenticate, then serve MCP JSON-RPC using `ToolExecutor` with two
  injected dependencies: a `LiveDataProvider` and a `ConfirmationBroker`.
- `ConfirmationBroker` — the state machine: `request(_:) async -> Outcome`
  queues a pending request, waits for approve/deny, and denies on a 60 s
  timeout. Queue-behind: a second mutation waits for the first decision. No
  SwiftUI, so it is testable with an injected clock.
- `LiveDataProvider` — a `DataProvider` backed by the app's published snapshot
  and alerts; alerts report `AlertSource.live`.
- `SocketMCPClient` — CLI side: connect, authenticate, relay stdio ⇄ socket,
  and translate connect/auth/EOF failures into a fallback signal rather than a
  transport error.
- Honesty fixes: `ThermalSample` gains the availability distinction
  `DockerSample.availability` already has, so "no sensors" and "not sampled
  yet" stop sharing one answer.
- Tidy-ups: move the remaining payload DTOs out of `ToolExecutor.swift`; log
  malformed mutation attempts (`result: "rejected"`) so the audit trail can
  distinguish "never attempted" from "never reached"; make the pre-existing
  engine-probe test skip on timeout like its sibling.

### App (`App/`)

- `MCPHostController` — owns the host's lifecycle (start with the app, stop on
  quit), binds `LiveDataProvider` to `AppModel`'s published snapshot, alerts and
  preferences, and supplies the confirmation UI.
- `MCPConfirmationWindow` — a small `NSWindowController` presenting the pending
  request. Approving a stop reuses the existing `StopSheet` phase machine and
  `StopCoordinator.stopConfirmed`; preferences get a compact view naming the
  key and value.
- `SettingsView` — the MCP section from decision 9.

## Data flow

**App running (socket live).** `initialize` and `tools/list` relay untouched,
so a client sees the same 13 tools either way. Reads answer from
`AppModel.snapshot` (~1 s fresh) and alerts from `AppModel.alerts` with
`source: "live"`. Every mutation waits on the broker: approve → the app performs
the action and returns the real result; deny → tool error naming the denial; 60 s
silence → denied. Both the gate decision and the confirmation outcome are
audit-logged, so the log distinguishes "allowed by policy and approved by a
person" from "allowed by policy, nobody asked" (`allowSession`). The audit line
is written once, by whoever handled the call.

**App closed or socket unavailable.** Slice 1's path, unchanged: reads from
`OnDemandProvider` (cold sweep, 5 s cache); mutations denied unless
`allowSession` *and* the app is running — which it is not — so in practice all
mutations are refused while closed. `PORTMASTER_MCP=on-demand` forces this path
when the app is up (wedged-app escape hatch).

**Token lifecycle.** Minted on launch, written with the socket path and pid,
removed on quit. A stale socket, wrong token or dead pid is treated as "app not
available": one stderr line, then fallback.

**Preferences.** When the app is handling the call it applies preference writes
itself, in memory through `AppModel.prefs`, so a running app never clobbers its
own state and the slice-1 refusal ("close the app first") does not apply to that
path. When the CLI is handling the call on its own, slice 1's rules stand
unchanged: `mcpMode` writes `MCPSettings`, and every other allowlisted write is
refused while the app is running.

**Gate ownership.** In the proxied path the CLI performs **no** gating: it
relays, and the app's `PermissionGate` (built per call from `MCPSettings` plus
its own liveness) is the only authority. The CLI's gate exists solely for the
on-demand fallback. One authority per call, never two.

## Security

- Socket `0600`; endpoint file `0600` in a `0700` directory; token 32 random
  bytes hex, constant-time compare, never logged and never present in tool
  output or error text.
- An unauthenticated or wrong-token connection is closed immediately, before
  any protocol bytes are written.
- Mutations stay default-deny (`off`). No new path reaches a signal, a write or
  a subprocess outside the gate and (under `confirmEach`) a person's approval.
- Reads add no data-access surface; `executablePathHint` is still never
  transmitted.
- `set_preference` remains restricted to the six allowlisted keys, from the
  single definition in `ToolExecutor`.

## Error handling

- Connect, auth or EOF failure → one stderr line, then the on-demand path for
  that call; the client sees a normal tool result.
- App dies mid-mutation → the relayed call returns `isError` naming the cause.
  No mutation is assumed to have happened and no success is invented.
- Deny or timeout → `isError` with the reason and `outcome: "denied"` audited.
- Bursts of mutations queue behind the pending decision (one window, one
  decision at a time).
- Thermal reports its availability honestly, mirroring Docker.

## Testing

- `swift test`: socket + token round-trip against a live listener; wrong and
  absent tokens rejected; endpoint file permissions and staleness detection;
  `ConfirmationBroker` approve / deny / timeout / queue-behind with a test
  clock; `SocketMCPClient` relay against a real server; `LiveDataProvider`
  against an app-shaped snapshot; payload-move regression; malformed-mutation
  audit line.
- Scripted end-to-end (`scripts/mcp-e2e.sh`): build and launch the real app,
  pipe `initialize → tools/list → tools/call` through the real binary, assert a
  mutation is denied with the app closed, then assert the confirmation path
  answers when it is open. This is the one thing unit tests cannot prove.
- `xcodebuild -scheme Portmaster -configuration Debug build` must stay green;
  the app target keeps no unit-test target.

## Non-goals

- Streamable HTTP / URL-based clients (slice 3).
- Changing the mutation mode policy or the preference allowlist.
- Per-tool permission toggles in Settings.
- Notifications or the menu-bar popover as approval surfaces.
- Sandboxing the app, or hardening beyond the owner-only socket plus token.
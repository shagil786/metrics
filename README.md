# Portmaster

Developer workstation observability for macOS. Portmaster answers five questions from one menu-bar app:

1. What is using my CPU and memory right now?
2. Which **app** (not 1,000 helper processes) caused the load?
3. Which local development services are using ports?
4. Which services look quiet — and what exactly would stop if I chose to stop one?
5. What has been acting up while I wasn't looking?

All observation is local. No account, no analytics, no telemetry, no cloud upload — nothing to send, and no entitlement to send it with.

## Build & run

Requires Xcode with the macOS 14 SDK or newer and [xcodegen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate          # creates Portmaster.xcodeproj from project.yml
open Portmaster.xcodeproj  # select the Portmaster scheme, Cmd+R
```

Or from the shell:

```sh
xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Portmaster-*/Build/Products/Debug/Portmaster.app
```

Core tests (parser, attribution, sampling math, plus live-system smoke tests):

```sh
cd Core && swift test
```

The same package also builds the MCP server, which has its own build and registration steps: [MCP server (for AI assistants)](#mcp-server-for-ai-assistants).

## What's in the box

- **Menu bar readouts** — separate native items for CPU, kernel memory-pressure state, memory used, busiest-process CPU, GPU, temperature, download, upload and disk writes. Each can show a value, graph or both, with optional icon/caption and compact sizing. macOS owns their ⌘-drag order. Right-click opens window/Settings/Quit actions; the shared dropdown has its own configurable tabs and overview tiles/list.
- **Overview** — machine summary, CPU history, memory-pressure bar, busiest processes, plus a "Worth a Look" strip of the newest acting-up alerts and an explicit pill whenever sampling is paused.
- **Hardware & Sensors** — read-only AppleSMC temperature and fan readings. The Overview Hardware card shows the hottest sensor, CPU/GPU maxima, and maximum fan RPM; the popover Sensors tab lists individual fans. Discovery runs off the sampling queue, caches temperature-type keys, and re-reads them about every 5 s while a surface is open (slower in the background). Absent or invalid readings show “—”; fanless and unreadable fans are not conflated with 0 RPM. Settings can show the hottest temperature in the menu bar. Battery capacity health and charge cycles appear only when battery IORegistry metadata supplies them.
- **Inside App** — the app-detail sheet behind every rollup's Details button: the app's processes grouped into semantic categories (browsers get their real anatomy — Tabs / GPU / Extensions / Browser / Network — Docker splits out its Linux-VM engine), a headline sentence ("Tabs use 82% of its memory"), a segmented share bar with a Memory/CPU toggle, and expandable member lists. Categorization is pure Core code with tests.
- **Projects & Ports** — listening services grouped by detected project, with search and an activity filter. Quiet services are labeled "No recent CPU activity (observed over the last 5 minutes)" — an observation, never a recommendation.
- **Containers** — Docker containers via the docker CLI (`docker ps` + `docker stats --no-stream`, slow lane, fixed argv, hard timeout). Availability is stated verbatim: not installed / daemon down / running; per-container CPU and memory appear only when docker stats answers.
- **Keeping This Mac Awake** — the sleep-preventing power assertions macOS attributes to each process, read from `pmset -g assertions` (window Power tab and popover battery tab). Sourced from macOS's own assertion list, never inferred from CPU or energy use.
- **Processes** — searchable, sortable list grouped by app and project ("Unattributed" when evidence is missing). Details (executable path, arguments, working directory) are fetched only when you open the detail sheet and stay on-device.
- **App rollups** — every helper/renderer process is grouped under its host app, so you see dozens of apps instead of a thousand processes. Helpers inherit the app's CPU and memory totals; the popover shows the three busiest apps.
- **Acting-up alerts** — plain-language observations in the Alerts tab, the Overview strip, and Notification Center: "Chrome is keeping the CPU busy — 70% average over the last 10 minutes", "Slack keeps using more memory — up 1.4 GB in the last hour", "Encoder is hammering the disk — 62 MB/s written on average over the last 10 minutes", "Syncer is using a lot of network — 11 MB/s downloaded on average over the last 10 minutes". Thresholds: 50%+ CPU averaged over a full 10-minute window, 1 GB+ memory growth within an hour, 50 MB/s disk writes or 10 MB/s downloads averaged over 10 minutes; at most one alert per app per kind per hour. Notification permission is requested only when you enable alerts. Per-app power-draw alerting isn't offered — macOS doesn't expose it through supported APIs.
- **History** — 1 h / 12 h / 24 h / 7 d / 30 d viewing ranges, separate from 24 h / 3 d / 7 d / 30 d retention. System charts cover CPU, memory, GPU, network, disk I/O, battery readings, temperatures and fastest fan where available. App charts cover CPU, memory and reported network/disk rates. Bundle identities combine helpers across PID changes; rankings integrate elapsed CPU time and show recorded averages and peak memory. Missing readings and pauses break lines; plots are bounded to ~200 points. Legacy process/project records stay separate. Large-store queries still run on the main thread and can stall range changes; asynchronous aggregation is pending.
- **Settings** — sidebar pages with a live readout preview, window/dropdown layout controls, Celsius/Fahrenheit, network bytes/bits, app/process CPU per core/per Mac, configurable global shortcuts, sampling cadence (2/3/5 s live, 15/30/60 s background), retention, login item, Dock visibility, privacy and preview data. System CPU/GPU stay whole-chip percentages; Docker CPU uses its VM's basis. Use Arrange for available window sections; statistics strips move as groups.
- **Shortcuts actions** — get an observed reading with units, get the current busiest app, open Portmaster and show its dropdown. Readings wait for a recent snapshot and label preview data. Build metadata contains all four actions; end-to-end invocation from Apple's Shortcuts app remains unverified.

## Stop actions (destructive, user-initiated only)

Graceful stop sends SIGTERM; force quit sends SIGKILL and is offered after an unsuccessful graceful attempt, with another confirmation. Project quit includes every currently attributed process, including non-listeners. The confirmation freezes the exact names/PIDs and affected ports. Start times are rechecked before each signal; reused or unknown identities are skipped, newly spawned processes require a new confirmation, and outcomes cover the whole confirmed set. No process is stopped automatically.

## MCP server (for AI assistants)

Portmaster ships a local [MCP](https://modelcontextprotocol.io) server, `portmaster-mcp`, so an AI assistant can read the same machine telemetry the menu bar shows — CPU, memory, apps, containers, projects, history, temperatures, alerts, settings — and, only if you say so, act on it. It speaks MCP over stdio, runs entirely on this Mac, and never listens on the network. Nothing is uploaded.

**With Portmaster running, the CLI talks to the app.** It opens a Unix socket at `~/.portmaster/mcp.sock` and the running app answers every call, so an assistant reads the app's live snapshot rather than starting one of its own, and a mutation is decided by the app's own permission gate and — under `confirmEach` — by a person looking at a window. **With the app closed, the CLI does the work itself**: each read spins up a short-lived sampler and tears it down again, so nothing is left sweeping the machine between calls.

The handoff is three files in `~/.portmaster` (a `0700` directory):

| File | What it is |
| --- | --- |
| `mcp.sock` | The socket the running app serves MCP on. `0600`. |
| `mcp-endpoint.json` | `{socket, token, pid}`, `0600`. The token is a fresh 64-character random value minted at every launch and rotated with it; `pid` is how a stale file left by a crash is recognised as stale. **Read this file if you are debugging a connection, and do not paste its contents anywhere** — the token is a live credential for your machine's process list and stop actions. |
| `mcp-settings.json` | The mutation mode (below). |

Build the CLI from the same package as the core:

```sh
cd Core && swift build -c release --product portmaster-mcp
```

**If you built the app, you do not need to do the above.** `Portmaster.app` ships the CLI inside itself at `Contents/Resources/portmaster-mcp`, and Settings → MCP offers **Copy install command**, which fills in the right absolute path for the build you are looking at. Use the button; the README path below is for someone running the CLI straight out of a checkout.

The binary lands in SwiftPM's release bin directory; ask SwiftPM where that is rather than assuming a path, because it varies per machine and per toolchain:

```sh
cd Core && swift build -c release --show-bin-path   # e.g. /Users/you/portmaster/Core/.build/out/Products/Release
```

Register it with an MCP client once it is built. For Claude Code, from the repository root:

```sh
claude mcp add portmaster -- "$(cd Core && swift build -c release --show-bin-path)/portmaster-mcp"
```

Use the path exactly as `--show-bin-path` prints it — it is already absolute, so prefixing it with anything (`$PWD/`, say) yields a path that does not exist. It differs per machine and per toolchain, which is why the command asks rather than hardcodes; a toolchain that printed a relative path would need an absolute prefix before `claude mcp add` stores it, since the client spawns the binary with its own working directory rather than yours. This form registers in the default `--scope local`, meaning it is available in this project only; pass `--scope user` to make it available everywhere you use the client.

`claude mcp add` syntax can vary by client version — if your client rejects that line, check its MCP docs for the current form and pass the same absolute binary path. The executable takes no arguments and needs no environment; stdout carries JSON-RPC and nothing else.

### Tools

Nine read tools and four mutations. A read never changes anything; a mutation is default-deny until you choose a mode (below).

| Tool | What it does | Arguments |
| --- | --- | --- |
| `get_system_overview` | CPU, memory, network, disk, battery, GPU, temperatures in one snapshot | — |
| `get_top_apps` | Apps ranked by one metric, highest first | `metric` (required: `cpu`/`memory`/`network`/`disk`), `limit` (1–100, default 10) |
| `get_app_detail` | One app's totals plus a per-process breakdown | `id` (required, from `get_top_apps`) |
| `get_containers` | Docker containers, and whether Docker is installed / daemon up / down | — |
| `get_projects` | Detected repositories with process counts and listening ports | — |
| `get_history_rankings` | Apps ranked by recorded CPU time over a window. **Passing `resource` switches the response shape**: you get that one resource's recorded readings as `{at, metric, value}` points, which belong to no app — not per-app rankings | `range` (required: `1h`/`12h`/`24h`/`7d`/`30d`), `resource` (optional; changes the response shape, see the note below) |
| `get_temperatures_fans` | Sensor temperatures and fan RPMs | — |
| `get_active_alerts` | "This app is acting up" observations, with provenance | — |
| `get_settings` | Current preferences, including the MCP mutation mode | — |
| `quit_app` | **Mutation** — quit an app's processes | `id` (required), `force` (optional, default false) |
| `stop_container` | **Mutation** — stop a running Docker container | `id` (required) |
| `stop_project` | **Mutation** — stop every process in a detected project | `id` (required) |
| `set_preference` | **Mutation** — change one allowlisted preference | `key`, `value` (both required) |

A value that has not been measured is **left out** of the payload rather than filled with a plausible zero. What "left out" looks like depends on the shape: an entire section of `get_system_overview` (say `battery`) is simply absent, and inside a *series* such as a `get_history_rankings` resource reading, each point is present and only its `value` is absent — so treat a missing `value` as a gap in the line, not as a zero. A refusal — mutation disabled, unknown app, bad argument — arrives as the tool's own text with `isError` set; it is not a transport failure.

### Mutation modes

Mode lives in `~/.portmaster/mcp-settings.json` as one key:

```json
{ "mode": "off" }
```

| Mode | Effect |
| --- | --- |
| `off` (default) | Every mutation is refused: *"MCP mutations are disabled in Portmaster settings."* |
| `confirmEach` | Every mutation opens a **confirmation window in the Portmaster app** — "Confirm AI Request", naming the change and what it would affect — and runs only if you press its button. If the app is not running there is nobody to ask, so it is refused: *"Portmaster must be open to approve this action."* If nobody answers within 60 seconds the window says so and refuses. Silence is never consent. |
| `allowSession` | Mutations are permitted while the Portmaster app is running, and refused when it is not. Nothing is asked. |

**`off` is the default, and an MCP client cannot turn it off.** Changing the mode is itself a mutation, so with `mode: off` the server refuses the very call that would grant it. Turning mutations on is a user action: **Settings → MCP**, or edit `~/.portmaster/mcp-settings.json` yourself. That is deliberate — an assistant cannot widen its own permissions.

The Settings page also shows whether the server is listening (and on which socket), how many clients are connected, the most recent audit lines with a **Reveal in Finder** button for the log itself, and the install command. The mode is re-read on every call, so changing it takes effect immediately — no restart.

### Talking to a wedged app

If Portmaster is running but not answering (the window is up, the tools hang), set `PORTMASTER_MCP=on-demand` in the environment your MCP client spawns the CLI in. The session then ignores the socket and does slice 1's own sweep, and says so on stderr. `PORTMASTER_MCP_ENDPOINT_DIR` points the CLI at a different `~/.portmaster` — a test seam, not something to set by hand.

`set_preference` accepts only allowlisted keys: `compact`, `cpuScale`, `mcpMode`, `networkUnit`, `temperatureSource`, `temperatureUnit`. Anything else is rejected rather than ignored. Note the naming asymmetry: the key you *write* is `compact`, while `get_settings` *reports* that same preference as `compactMenuBar`.

### Audit log

Every **mutation attempt** appends one JSON line to `~/.portmaster/mcp-audit.log` (owner-readable only, `0600`, inside a `0700` directory):

```json
{"arguments":{"id":"nonexistent-app-id-for-gate-check"},"tool":"quit_app","pid":60663,"ts":"2026-10-03T17:02:13Z","reason":"MCP mutations are disabled in Portmaster settings.","outcome":"denied"}
```

`outcome` is one of four words:

| Outcome | Meaning |
| --- | --- |
| `rejected` | The request was malformed — a required argument missing or blank — and was refused before the gate, so no policy was consulted and nothing was touched. |
| `denied` | The gate refused, or nobody answered (or refused) a confirmation. Still nothing was touched. |
| `allowed` | The action succeeded. |
| `failed` | It was permitted but did not work. |

`rejected` is separated from `denied` because it was not a decision *you* made — a client calling `stop_container` with no `id` is a client with a bug, and counting it among your refusals would misattribute it. `reason` carries the explanation, or is `null` when there is nothing to add. Reads are never logged — they change nothing, and logging them would bury the entries that matter. **The token is never in this log, or in any other.**

The line is written *after* the action for `allowed`/`failed`, so for anything that reached the provider the log answers "did the stop actually work?", not merely "was it permitted?".

### Limitations in this release

- **`confirmEach` needs your client to keep the connection open.** The confirmation can wait up to 60 s, but the CLI's stdio session gives up about 10 s after your client closes its end of the pipe. A long-lived client (Claude Code and friends do keep the pipe open) is fine; a one-shot client that writes a request and closes stdin loses the answer — and the audit log records nothing for it, so a lost confirmation leaves no trace. Same for an app you quit mid-prompt.
- **`mcpMode` cannot be confirmed.** Under `confirmEach`, a `set_preference` for `mcpMode` is refused before the window opens, with a message that contradicts itself: *"Preference 'mcpMode' cannot be changed via MCP. Allowed: compact, cpuScale, mcpMode, …"*. The confirmation window checks a preference change against the app's own preferences, and the MCP server's own policy is not one of them. `mcpMode` still works under `allowSession`, where no window is involved.
- **The confirmation window is a window, not a sheet.** It is raised in front of whatever you were using (`orderFrontRegardless` plus an app activation), so expect Portmaster to come forward when a prompt arrives.
- **Preference writes from the on-demand path need the app closed.** With no app running there is nothing holding the preferences blob, so `set_preference` refuses rather than write something the next launch would overwrite. With the app running it applies the change live. Either way `mcpMode` is the exception — the app never holds it.
- **Alerts are history-approximate.** `get_active_alerts` reports `source: "history-approximate"` and reconstructs sustained-CPU and memory-growth alerts from recorded history: the observation is real, its freshness is not. Per-app disk and network hammering is live-only and is therefore *not* fabricated — those alert kinds simply do not appear from history.
- **`get_settings` can report defaults it did not read.** When the preferences blob cannot be decoded, the read falls back to default values while writes refuse over the same blob. Reading back defaults right after a successful write means this, not a lost write.
- **`get_temperatures_fans` separates "nothing observed yet" from "nothing readable".** The SMC pass runs on the sampler’s slow lane and lands a tick after it is kicked, so the first read on a cold sampler has no reading at all — and answering `available: false` for that would be a claim about the hardware that nothing observed. While no sensor reading has been observed the tool refuses with *“Temperature and fan readings are not known yet; no sensor reading has been observed.”* Retry a moment later. Once a pass has read the SMC the payload says which answer it carries in `availability`: `"available"` with the readings, or `"noSensors"` when a completed pass over a readable SMC produced no plausible reading (`available: false`, and no reading invented for a sensor that said none). `"noSensors"` is what this collector verified, not a claim about the hardware: it decodes `flt `/`sp78` temperature keys and plausible values only, so a Mac whose sensors answer in another type reads the same way. `available` stays as a convenience flag for callers that read only that one field, and `get_system_overview`’s `thermal` section carries the same two fields.
- **Reads have a ~10 s budget.** The first read on a cold sampler waits for a full process sweep, port scan and `nettop` pass. If that budget expires the tool says *"No reading available yet; the sampler is still starting."* instead of returning zeros — retry a moment later.
- **`stop_container` shells out to Docker.** It runs `docker stop -- <id>` with fixed argv (no shell), so Docker must be installed with the daemon up.
- **The app's slice of this server is build-verified, not exercised by CI.** `scripts/mcp-e2e.sh` drives the real CLI against a real app build — socket, catalog, refusal, audit line, and the confirmation up to the point where a person must click — but the Settings page, the confirmation window and the status/clients readouts have only been compiled and looked at, never driven by an automated test. `scripts/mcp-e2e.sh` needs a real click for its last check; everything before that click is asserted.

## Permissions and distribution

- The read-only dashboard needs **no permissions** — it reads your own user's processes and socket tables.
- Direct distribution build (App Sandbox **off**). That's what makes per-process metrics, project attribution, and stop actions possible; a sandboxed Mac App Store build would show "Unattributed" for other apps' processes and would have stop actions disabled.
- Hardened runtime is on; the app is ad-hoc signed for local development. For wider distribution, add Developer ID signing and notarization — configuration only, no code changes.
- **The bundled `portmaster-mcp` is signed ad-hoc, and that is not release-ready.** The app's post-build script signs the nested executable with `codesign -s -`, which is enough to run it from a locally built app and nothing more: a nested executable has to carry the app's own **Developer ID** signature for Gatekeeper on another Mac, and `scripts/package-dmg.sh` re-signs nothing. **A released build has to sign the bundle once, deepest first, before packaging** — `Contents/Resources/portmaster-mcp`, then the app. Until that exists, a notarized app would ship a CLI that Gatekeeper refuses, and the Settings page would name a path that does not work on a user's machine. Nothing here has been checked against a notarized copy.
- [Local DMG packaging and signed-update setup](Support/Release.md): the installer includes an Applications shortcut. Sparkle checks are disabled until a real HTTPS feed and Ed25519 public key are configured. Developer ID signing/notarization and actual update delivery remain release work.
- New installs see a welcome screen; legacy preferences skip it. Welcome can be reopened from Settings → Privacy. Notification permission is requested through an explicit Alerts action rather than at launch.
- Launch-at-login uses `SMAppService` (macOS 13+); if approval is pending, Settings shows the exact status.

## Minimum macOS

macOS 14 (Sonoma). The floor is set by Swift Charts + `NavigationSplitView`-era APIs the UI relies on (13) plus modern `Settings` and `Table` behaviors (14). Collectors themselves (Mach host APIs, libproc, lsof) work back much further, but v1 targets one floor to keep the surface testable.

## Honest limitations (shown in the UI, not hidden)

- AppleSMC's sensor keys and encodings are undocumented and can change with hardware/firmware. Temperature grouping uses key-name conventions, not per-model calibration. Read-only temperature/fan readings are verified on an M4; Intel fixed-point encodings have unit tests, but have not been tested on live Intel hardware. No fan-control writes are implemented. Battery health is full-charge/design capacity from optional IORegistry properties; it is not a service recommendation or charge percentage.
- Per-process values need two sampling sweeps; the first shows "—" instead of a plausible number.
- Port ownership comes from `lsof` snapshots every ~10 s; brand-new or very short-lived listeners may lag by one poll.
- Project attribution is heuristic (working directories + project markers); anything unrecognized is "Unattributed".
- Per-app GPU attribution, energy impact and power watts remain unavailable through the supported collectors; system GPU and reported per-process disk I/O are shown.
- Process CPU is stored as percent of one core and can exceed 100 for multithreaded work. Mach ticks are converted through the machine timebase; the per-Mac display preference divides by the core count once.

## Preview mode

Settings → General → "Use preview data" swaps in synthetic fixtures, labeled "Preview data — not your machine" in every surface. It is never the default and never mixed with live data.

## Layout

```
project.yml              XcodeGen manifest (app target, macOS 14)
App/                     SwiftUI app: menu bar, windows, sheets, settings
Core/                    PortmasterCore package (no UI deps)
  Sources/PMShim/        C shim: proc_pidinfo cwd, KERN_PROCARGS2 argv
  Sources/PortmasterCore/
    Models/              ProcessRow, SystemSample, ports, preferences, SwiftData models
    Collectors/          Mach CPU/memory, libproc processes, lsof ports,
                         nettop, pmset sleep assertions, docker CLI, read-only SMC sensors
    Attribution/         project attribution heuristics, app rollups,
                         AppBreakdown ("what's inside this app")
    Sampling/            cadence engine (2s live / 15s background, idle pause,
                         slow lane for nettop/pmset/docker/SMC)
    Stop/                SIGTERM/SIGKILL coordinator with verification
    History/             SwiftData store, retention, clear-all
    Fixtures/            preview data (opt-in, labeled)
  Sources/PortmasterMCP/ MCP tool catalog, permission gate, audit log,
                         on-demand provider (no UI, no app required)
  Sources/portmaster-mcp/ stdio executable serving MCP on stdin/stdout
  Tests/                 parser/attribution/breakdown unit tests + live smoke tests
                         (+ PortmasterMCPTests for the tool layer)
design-reference/        captured frames of the Vitals 1.2 reference video
```

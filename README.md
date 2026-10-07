# Portmaster

Developer workstation observability for macOS. Portmaster answers five questions from one menu-bar app:

1. What is using my CPU and memory right now?
2. Which **app** (not 1,000 helper processes) caused the load?
3. Which local development services are using ports?
4. Which services look quiet — and what exactly would stop if I chose to stop one?
5. What has been acting up while I wasn't looking?

All observation is local. No account, no analytics, no telemetry, no cloud upload — nothing to send, and no entitlement to send it with.

## Build & run

Requires Xcode with the macOS 14 SDK or newer and [xcodegen](https://github.com/yonaskolb/XcodeGen). Portmaster builds for **Apple silicon and Intel** (macOS 14 or later); `project.yml` pins both architectures, and `scripts/package-dmg.sh` refuses to package a bundle that is missing either.

What a given Mac actually reports still depends on the model. GPU state comes back nil on Intel, SMC sensor keys are named differently from Apple silicon, and per-app volume needs macOS 14.2 or later. Those cases read as absent rather than as zero — see *Hardware & Sensors* below — so a Mac that cannot report something shows "—" instead of a number nobody measured. **Intel hardware has not been exercised on this build**: the app cross-compiles and the app-level behaviour above is by design, but the per-model sensor coverage is unverified until someone runs it on an Intel Mac.

```sh
xcodegen generate          # creates Portmaster.xcodeproj from project.yml
open Portmaster.xcodeproj  # select the Portmaster scheme, Cmd+R
```

Or from the shell:

```sh
xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Portmaster-*/Build/Products/Debug/Portmaster.app
```

A Cmd+R build is single-architecture and fine for local work. Anything you intend to **ship or hand to someone else** needs both architectures on the command line:

```sh
xcodebuild -project Portmaster.xcodeproj -scheme Portmaster \
  -configuration Release ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
```

The `ARCHS` override is load-bearing, not decoration. `project.yml` already pins `ARCHS = arm64 x86_64`, but the `Core` Swift package that the app links does not inherit the app target's settings — it builds for the host architecture. Without the command-line override the package compiles one slice, the app links a single-architecture binary, and **the build still reports success**; only `lipo -archs` on the product reveals it. `scripts/package-dmg.sh` asserts both slices are present and refuses to package otherwise, which is why the failure surfaces at package time rather than in a user's hands.

Verify before shipping:

```sh
lipo -archs ~/Library/Developer/Xcode/DerivedData/Portmaster-*/Build/Products/Release/Portmaster.app/Contents/MacOS/Portmaster
# expect: arm64 x86_64
```

### Signing a release build

The Release build is not signed by `xcodebuild`, and `scripts/package-dmg.sh` re-signs nothing — it only packages a bundle that is already signed. Signing is a separate step, and skipping it produces a build that fails on the first launch rather than at distribution time:

```sh
scripts/sign-and-notarize.sh --identity "Developer ID Application: …" \
  ~/Library/Developer/Xcode/DerivedData/Portmaster-*/Build/Products/Release/Portmaster.app
scripts/package-dmg.sh <that path> /absolute/output.dmg
```

Every nested code object is signed with the app's identity, deepest first: the embedded `portmaster-mcp`, Sparkle's `Autoupdate`, `Updater.app` and its XPC services, then the framework, then the app. A nested executable left with a different signature is the specific failure this exists to prevent — Gatekeeper checks each one separately, so the app would open while the Settings page's "Copy install command" names a binary that will not start.

`--ad-hoc` signs for local use with no certificate. That build runs on your machine and anywhere Gatekeeper is overridden, and is not distributable.

**The hardened runtime is off by default and re-applied by the script when it has a Team ID to apply it to.** `--options runtime` is required for notarization, but it also enables library validation, which requires every loaded image to share the main executable's Team ID. Neither an ad-hoc nor a self-signed certificate has one, so a hardened bundle signed with either dies at dyld before it draws a window — measured on this repository's own Release build, which could not launch at all until the flag was dropped. The script detects the missing Team ID and says so rather than emitting a bundle that looks signed and does not run.

Notarization itself has **never been run** in this repository: there is no Apple-issued `Developer ID Application` certificate available, and `notarytool` needs stored credentials. Everything up to the notarization submit is exercised; everything after it is written from Apple's documented requirements and has not been observed. Treat a release as unverified at that step.

Core tests (parser, attribution, sampling math, plus live-system smoke tests):

```sh
cd Core && swift test
```

The same package also builds the MCP server, which has its own build and registration steps: [MCP server (for AI assistants)](#mcp-server-for-ai-assistants).

## What's in the box

- **Menu bar readouts** — separate native items for CPU, kernel memory-pressure state, memory used, busiest-process CPU, GPU, temperature, download, upload and disk writes. Each can show a value, graph or both, with optional icon/caption and compact sizing. macOS owns their ⌘-drag order. Right-click opens window/Settings/Quit actions; the shared dropdown has its own configurable tabs and overview tiles/list.
- **Overview** — machine summary, CPU history, memory-pressure bar, busiest processes, plus a "Worth a Look" strip of the newest acting-up alerts and an explicit pill whenever sampling is paused.
- **Hardware & Sensors** — read-only AppleSMC temperature and fan readings. The Overview Hardware card shows the hottest sensor, CPU/GPU maxima, and maximum fan RPM; the popover Sensors tab lists individual fans. Discovery runs off the sampling queue, caches temperature-type keys, and re-reads them about every 5 s while a surface is open (slower in the background). Absent or invalid readings show “—”; fanless and unreadable fans are not conflated with 0 RPM. Settings can show the hottest temperature in the menu bar. Battery capacity health and charge cycles appear only when battery IORegistry metadata supplies them. Coverage varies by model: which SMC keys a Mac exposes differs between Apple silicon and Intel, and a machine that publishes none of them reports "No sensors" as its own state rather than as an absence of readings.
- **Inside App** — the app-detail sheet behind every rollup's Details button: the app's processes grouped into semantic categories (browsers get their real anatomy — Tabs / GPU / Extensions / Browser / Network — Docker splits out its Linux-VM engine), a headline sentence ("Tabs use 82% of its memory"), a segmented share bar with a Memory/CPU toggle, and expandable member lists. Categorization is pure Core code with tests.
- **Projects & Ports** — listening services grouped by detected project, with search and an activity filter. Quiet services are labeled "No recent CPU activity (observed over the last 5 minutes)" — an observation, never a recommendation.
- **Containers** — Docker containers via the docker CLI (`docker ps` + `docker stats --no-stream`, slow lane, fixed argv, hard timeout). Availability is stated verbatim: not installed / daemon down / running; per-container CPU and memory appear only when docker stats answers.
- **Per-process energy** — read from `proc_pid_rusage`'s `rusage_info_v6` energy counters, the same supported libproc call that already supplies per-process disk I/O, so it adds no new API surface and needs no elevated permission. It reports one of three states and never a fabricated number. **Measured:** the kernel can advertise per-process energy accounting (`ri_energy_nj` non-zero) while never advancing the counter — on an M4 Mac mini (macOS 26.6.2) `ri_billed_energy` stayed bit-identical through four seconds idle and through two seconds of sustained CPU burn, so every process would read exactly 0 forever. Portmaster therefore treats "a rate has ever been observed on this machine" as the precondition for publishing any energy figure: until a counter advances, energy reports as *not reported*, which is not the same claim as a measured zero. Once a machine has produced a rate it keeps reporting, because an idle stretch is a process that was idle rather than a capability that vanished. A process that exits mid-sweep, a counter that moves backwards (pid restart), and the first pair of samples before any rate exists all report *not sampled yet*. The SDK documents no unit for these counters and no Apple documentation states one, so values are carried as raw counters and rates as "energy units per second"; **the scale has not been confirmed against hardware that meters energy, and nothing here is rendered as watts.** Per-app power-draw alerting remains off for the same reason it always was — see *Acting-up alerts*.
- **Keeping This Mac Awake** — the sleep-preventing power assertions macOS attributes to each process, read from `pmset -g assertions` (window Power tab and popover battery tab). Sourced from macOS's own assertion list, never inferred from CPU or energy use.
- **Processes** — searchable, sortable list grouped by app and project ("Unattributed" when evidence is missing). Details (executable path, arguments, working directory) are fetched only when you open the detail sheet and stay on-device.
- **App rollups** — every helper/renderer process is grouped under its host app, so you see dozens of apps instead of a thousand processes. Helpers inherit the app's CPU and memory totals; the popover shows the three busiest apps.
- **Acting-up alerts** — plain-language observations in the Alerts tab, the Overview strip, and Notification Center: "Chrome is keeping the CPU busy — 70% on average for 10 minutes.", "Slack keeps using more memory — Up 1.4 GB in the last 1 hour, now 3.3 GB.", "Encoder is hammering the disk — 62 MB/s written on average for 10 minutes.", "Syncer is using a lot of network — 11 MB/s downloaded on average for 10 minutes." Every sentence lives in `AlertCopy` and names its window from the threshold constants, so changing a threshold cannot leave the wording describing a window that is no longer used; an alert reconstructed from recorded history rather than measured live says so, so a reader or an MCP client can tell an approximation from a reading. Thresholds: 50%+ CPU averaged over a full 10-minute window, 1 GB+ memory growth within an hour, 50 MB/s disk writes or 10 MB/s downloads averaged over 10 minutes; at most one alert per app per kind per hour. Notification permission is requested only when you enable alerts. Per-app power-draw alerting isn't offered — macOS doesn't expose it through supported APIs.
- **History** — 1 h / 12 h / 24 h / 7 d / 30 d viewing ranges, separate from 24 h / 3 d / 7 d / 30 d retention. System charts cover CPU, memory, GPU, network, disk I/O, battery readings, temperatures and fastest fan where available. App charts cover CPU, memory and reported network/disk rates. Bundle identities combine helpers across PID changes; rankings integrate elapsed CPU time and show recorded averages and peak memory. Missing readings and pauses break lines; plots are bounded to ~200 points. Legacy process/project records stay separate. Large-store queries still run on the main thread and can stall range changes; asynchronous aggregation is pending.
- **Export** — the Overview's Export menu offers two shapes of answer: the current readings as CSV, for something that will read them, and a 1200 × 630 **share card** as PNG (rendered at 2×, so 2400 × 1260), for something that will only look at it. The card carries the machine name, memory used of total, CPU, the five apps holding the most memory with their process counts, and the timestamp — deliberately no charts and no alerts, because a card that tries to show everything at that size shows nothing legibly. It is always light, whatever appearance your Mac is in: `Theme.canvas` is a dynamic colour that would resolve against your current setting and silently produce a dark card for a post you meant to be light. Every figure on it is `Fmt`'s own output, so it cannot disagree with the dashboard it was copied from, and both exports are refused before anything has been sampled — a card of no data still looks like data.
- **Settings** — sidebar pages with a live readout preview, window/dropdown layout controls, Celsius/Fahrenheit, network bytes/bits, app/process CPU per core/per Mac, configurable global shortcuts, sampling cadence (2/3/5 s live, 15/30/60 s background), retention, login item, Dock visibility, privacy and preview data. System CPU/GPU stay whole-chip percentages; Docker CPU uses its VM's basis. Use Arrange for available window sections; statistics strips move as groups.
- **Shortcuts actions** — get an observed reading with units, get the current busiest app, open Portmaster and show its dropdown. Readings wait for a recent snapshot and label preview data. Build metadata contains all four actions; end-to-end invocation from Apple's Shortcuts app remains unverified.

## Stop actions (destructive, user-initiated only)

Graceful stop sends SIGTERM; force quit sends SIGKILL and is offered after an unsuccessful graceful attempt, with another confirmation. A dev server showing "No recent CPU activity" also gets a **Force Quit…** button on its row, because a quiet server is usually detached with no terminal attached and often ignores SIGTERM — asking for the force quit first skips an attempt that would only time out, and still shows the full confirmation. Quiet is an observation, not a verdict: it says no CPU was seen in the lookback window, not that the service is safe to kill. Project quit includes every currently attributed process, including non-listeners. The confirmation freezes the exact names/PIDs and affected ports. Start times are rechecked before each signal; reused or unknown identities are skipped, newly spawned processes require a new confirmation, and outcomes cover the whole confirmed set. No process is stopped automatically.

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

`claude mcp add` syntax can vary by client version — if your client rejects that line, check its MCP docs for the current form and pass the same absolute binary path. The executable takes no arguments; stdout carries JSON-RPC and nothing else. It reads two environment variables, both documented under *Talking to a wedged app*, and needs neither.

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

A value that has not been measured is **left out** of the payload rather than filled with a plausible zero. What "left out" looks like depends on the shape: an entire section of `get_system_overview` (say `battery`) is simply absent, and inside a *series* such as a `get_history_rankings` resource reading, each point is present and only its `value` is absent — so treat a missing `value` as a gap in the line, not as a zero. A refusal — mutation disabled, unknown app, missing argument — arrives as the tool's own text with `isError` set; it is not a transport failure.

### Mutation modes

Mode lives in `~/.portmaster/mcp-settings.json` as one key:

```json
{ "mode": "off" }
```

| Mode | Effect |
| --- | --- |
| `off` (default) | Every mutation is refused: *"MCP mutations are disabled in Portmaster settings."* |
| `confirmEach` | Every mutation that could be carried out opens a **confirmation window in the Portmaster app** — "Confirm AI Request", naming the change and what it would affect — and runs only if you press its button. If the app is not running there is nobody to ask, so it is refused: *"Portmaster must be open to approve this action."* If nobody answers within 60 seconds the window says so and refuses. Silence is never consent. A mutation **missing a required argument** never reaches a window at all — it is refused as `rejected` before anyone is asked, because there is nothing to ask about. |
| `allowSession` | Mutations are permitted while the Portmaster app is running, and refused when it is not. Nothing is asked. |

**`off` is the default, and an MCP client cannot turn it off.** Changing the mode is itself a mutation, so with `mode: off` the server refuses the very call that would grant it. Turning mutations on is a user action: **Settings → MCP**, or edit `~/.portmaster/mcp-settings.json` yourself. That is deliberate — an assistant cannot widen its own permissions. The one exception is `mcpMode` **itself**, which is an ordinary mutation: once `allowSession` is on, a client can change the mode through the normal path, and under `confirmEach` it can do so with a click. It still cannot do it from `off`.

The Settings page also shows whether the server is listening (and on which socket), how many clients are connected, **the audit log's path** with a **Reveal in Finder** button, and the install command. It does not show the log's contents — read it with `tail -f ~/.portmaster/mcp-audit.log` or open it in an editor. The mode is re-read on every call, so changing it takes effect immediately — no restart.

### Talking to a wedged app

If Portmaster is running but not answering (the window is up, the tools hang), set `PORTMASTER_MCP=on-demand` in the environment your MCP client spawns the CLI in. The session then ignores the socket and does its own sweep, and says so on stderr: *"portmaster-mcp: PORTMASTER_MCP=on-demand, so this session is doing its own sweep even though Portmaster may be up."* — deliberately **not** *"no Portmaster answering on the socket"*, which is the other notice and a different situation: that one is written when the CLI probed, found nothing, and fell back on its own. Here Portmaster is probably up, which is the whole reason you set the variable, so telling you otherwise would point you away from the app you were trying to route around.

`PORTMASTER_MCP_ENDPOINT_DIR` points the CLI at a different `~/.portmaster` — a test seam, not something to set by hand.

`set_preference` accepts only allowlisted keys: `compact`, `cpuScale`, `mcpMode`, `networkUnit`, `temperatureSource`, `temperatureUnit`. Anything else is rejected rather than ignored. Note the naming asymmetry: the key you *write* is `compact`, while `get_settings` *reports* that same preference as `compactMenuBar`.

### Audit log

Almost every **mutation attempt** appends one JSON line to `~/.portmaster/mcp-audit.log` (owner-readable only, `0600`, inside a `0700` directory) — the two cases that leave no line are named at the end of this section, so read it before you rely on it:

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

**Almost every mutation attempt leaves a line, including the ones that never happened.** An attempt whose client gave up before anybody answered is recorded (`denied`, reason *"The AI client stopped waiting for an answer…"*), and so is one where the app was quitting underneath it (`denied`, reason *"Portmaster is quitting…"*). That is the class of question the log exists for — "did my assistant try that?" — and it used to be invisible for exactly the attempts that mattered most.

**The exception, so you are not sent looking for a line that is not there:** if the app is *killed or crashes* while a confirmation is on screen, the process that would write the line is the one that died, and nothing is recorded. There is also a narrow race in which a client that disconnects at the same moment an approval arrives can leave two lines for one attempt — one `denied` from this path and one `allowed` from the tool layer. Both are known and neither is silent. One thing the line cannot help with: a line is `{ts, tool, arguments, outcome, reason, pid}` with no attempt identifier, so nothing links a doubled pair together — two genuine consecutive attempts at the same tool look identical to one attempt recorded twice. **Treat refusal counts as approximate**, and if you need to know whether one specific action happened, look at the machine rather than the log.

**When the CLI says Portmaster isn't running, believe it only sometimes.** Two different failures used to produce that one sentence. If a client *probe* fails — no endpoint file, no socket, a refused token — then "Portmaster isn't running" is the honest summary. If a **call times out** — the handshake succeeded, the catalog came back, and then a tool call went silent — it now says *"Portmaster did not answer this call within N seconds, so no answer was received. Whether it took effect is not knowable from here — check the audit log and your machine before retrying."* The second sentence is the important one: the CLI gave up at its budget, and the app may well finish the call a moment later, so **it does not claim the action did not happen.** Look for a confirmation window, and check the audit log and the machine, before you retry — retrying a change that already went through is how you get it twice.

**Reading it when something looks wrong.** The `reason` is the fastest discriminator, because each refusal has its own sentence rather than a shared one: *"MCP mutations are disabled…"* is the mode, *"Portmaster must be open to approve…"* is `confirmEach` with no app to ask, *"No answer to Portmaster's confirmation prompt…"* is a person who was asked and did not answer within 60 s, *"The AI client stopped waiting…"* is a client that hung up, and *"Preference 'X' cannot be changed via MCP"* is a key outside the allowlist.

### Limitations in this release

- **Approve takes a deliberate click: move the pointer onto the button, then click.** The window raises itself in front of whatever you were using and is placed **beside your pointer, never under it** — on a screen with room to spare. Return does nothing on that window, and neither does any other key; the Approve button also stays disabled until the pointer *enters* it. On a shorter screen, where the window cannot fit entirely above or below the cursor, the window overlaps the pointer instead — so there the disabled-until-hovered rule is what stands between a parked cursor and a consent. Either way, only clicking **Change Preference** (or its per-kind equivalent) approves. Escape still means Deny. If a change you did not click through happens, that is a bug worth reporting with the audit line, not a mis-click.
- **The confirmation window is a window, not a sheet.** It is raised in front of whatever you were using, so expect Portmaster to come forward when a prompt arrives.
- **Preference writes from the on-demand path need the app closed.** With no app running there is nothing holding the preferences blob, so `set_preference` refuses rather than write something the next launch would overwrite. With the app running it applies the change live. Either way `mcpMode` is the exception — the app never holds it.
- **Alerts are history-approximate.** `get_active_alerts` reports `source: "history-approximate"` and reconstructs sustained-CPU and memory-growth alerts from recorded history: the observation is real, its freshness is not. Per-app disk and network hammering is live-only and is therefore *not* fabricated — those alert kinds simply do not appear from history.
- **`get_settings` can report defaults it did not read.** When the preferences blob cannot be decoded, the read falls back to default values while writes refuse over the same blob. Reading back defaults right after a successful write means this, not a lost write.
- **`get_temperatures_fans` separates "nothing observed yet" from "nothing readable".** The SMC pass runs on the sampler’s slow lane and lands a tick after it is kicked, so the first read on a cold sampler has no reading at all — and answering `available: false` for that would be a claim about the hardware that nothing observed. While no sensor reading has been observed the tool refuses with *“Temperature and fan readings are not known yet; no sensor reading has been observed.”* Retry a moment later. Once a pass has read the SMC the payload says which answer it carries in `availability`: `"available"` with the readings, or `"noSensors"` when a completed pass over a readable SMC produced no plausible reading (`available: false`, and no reading invented for a sensor that said none). `"noSensors"` is what this collector verified, not a claim about the hardware: it decodes `flt `/`sp78` temperature keys and plausible values only, so a Mac whose sensors answer in another type reads the same way. `available` stays as a convenience flag for callers that read only that one field, and `get_system_overview`’s `thermal` section carries the same two fields.
- **Reads have a ~10 s budget.** The first read on a cold sampler waits for a full process sweep, port scan and `nettop` pass. If that budget expires the tool says *"No reading available yet; the sampler is still starting."* instead of returning zeros — retry a moment later.
- **`stop_container` shells out to Docker.** It runs `docker stop -- <id>` with fixed argv (no shell), so Docker must be installed with the daemon up.
- **The app's slice of this server is not exercised by CI.** `scripts/mcp-e2e.sh` drives the real CLI against a real app build — socket, catalog, refusal, audit line, and the confirmation. Run it unattended with `--no-manual`, which asserts everything up to that click and reports the click itself as `SKIP` rather than pretending it passed:

  ```sh
  scripts/mcp-e2e.sh --no-manual \
    "$(cd ~/Library/Developer/Xcode/DerivedData && ls -d Portmaster-*/Build/Products/Debug/Portmaster.app | head -1)" \
    "$(cd Core && swift build --show-bin-path)/portmaster-mcp"
  ```

  Without `--no-manual` the last check needs a real click and **fails** if nobody makes it — that is the intended default, not a broken script. The Settings page, the confirmation window and the status/clients readouts still have no automated driver; the window has been rendered and read by a person, never pressed by a test.

## Permissions and distribution

- The read-only dashboard needs **no permissions** — it reads your own user's processes and socket tables.
- Direct distribution build (App Sandbox **off**). That's what makes per-process metrics, project attribution, and stop actions possible; a sandboxed Mac App Store build would show "Unattributed" for other apps' processes and would have stop actions disabled.
- Hardened runtime is on; the app is ad-hoc signed for local development. For wider distribution it needs Developer ID signing and notarization — and that is **not** configuration only: the signing step below has to reach inside the bundle.
- **The bundled `portmaster-mcp` is signed ad-hoc, and that is not release-ready.** The app's post-build script signs the nested executable with `codesign -s -`, which is enough to run it from a locally built app and nothing more: a nested executable has to carry the app's own **Developer ID** signature for Gatekeeper on another Mac, and `scripts/package-dmg.sh` re-signs nothing. **A released build has to sign the bundle once, deepest first, before packaging** — `Contents/Resources/portmaster-mcp`, then the app. Until that exists, a notarized app would ship a CLI that Gatekeeper refuses, and the Settings page would name a path that does not work on a user's machine. Nothing here has been checked against a notarized copy.
- [Local DMG packaging and signed-update setup](Support/Release.md): the installer includes an Applications shortcut. Sparkle checks are disabled until a real HTTPS feed and Ed25519 public key are configured. Signing is handled by `scripts/sign-and-notarize.sh` (see [Signing a release build](#signing-a-release-build)); notarization and actual update delivery remain release work, because neither has an Apple-issued Developer ID certificate available here.
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
  Sources/PortmasterMCP/ MCP tool catalog, permission gate, audit log, wire payloads,
                         Unix-socket host + relay client, confirmation broker and window
                         placement, on-demand provider (no UI, no app required)
  Sources/portmaster-mcp/ stdio executable: serves MCP on stdin/stdout, and routes each
                         session to the running app when there is one
  Tests/                 parser/attribution/breakdown unit tests + live smoke tests
                         (+ PortmasterMCPTests for the tool layer)
design-reference/        captured frames of the Vitals 1.2 reference video
```

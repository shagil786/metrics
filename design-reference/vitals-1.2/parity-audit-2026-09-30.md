# Vitals / Portmaster parity audit

Checked September 30, 2026. **Full changelog and video parity is not complete.** The earlier statement that every video feature was implemented was too broad.

Reference: [live changelog](https://vitalsmac.com/changelog), covering 1.0.0 through the newly listed 1.2.1. The 60 rows below correspond one-to-one with its 60 listed bullets; compound entries remain Partial if any significant component is absent. Reference labels are abbreviated, not a reproduction of the release notes.

Video: [the requested post](https://x.com/attacomsian/status/2104994461608751245). Direct X retrieval returned HTTP 403. I inspected all four existing contact sheets covering 0–65 seconds, plus detailed saved stills. I did not redownload or replay the original video; smoothness cannot be established from still frames.

Scope: current App/, Core/Sources/, Core/Tests/, Support/ and project.yml. The code graph was freshly reindexed, every module page was collected, and coverage gaps in ProcessesView and SMCCollector were checked in source. Negative feature findings were corroborated with scoped text searches and target/dependency configuration. Graph relationships are best-effort, so material conclusions use the source itself.

## Confirmed defects, ordered by impact

1. **[P2] Invalid network counters can crash the background collector.** `SystemExtraCollectors.swift:331` adds duplicate-PID UInt64 counters without an overflow check. Two accepted rows whose sum exceeds UInt64.max trap; the engine also uses unchecked additions at `SamplingEngine.swift:464` and `:478`. Ordinary UInt64 parsing rejects negative/unparseable input but still accepts extreme valid integers. This leaves the new safety requirement unmet. No crash was deliberately induced on the user's app.
2. **[P2] Network baselines and session totals are incorrect.** `SamplingEngine.swift:460` only populates `fresh` after a previous timestamp exists, so the first pass is discarded. For counters 1,000 then 1,200, the next delta becomes 1,200 rather than 200. At `:474`, totals are differenced across a changing process population: if A increases 100→150 while B's previous 100 disappears, aggregate 150−200 is clamped to zero and A's real 50 bytes are lost. New processes can also contribute pre-observation lifetime traffic. Rates, session counters and alert input are affected.
3. **[P2] Inside App values remain a captured snapshot.** `InsideAppSheet.swift:14` stores a value-type rollup, and `:25` computes groups from that captured value. `ProcessesView.swift:46` presents it without reconciling to the latest rollup. Leave the sheet open while app usage changes: its totals and category shares do not follow subsequent sampling. The EnvironmentObject is declared but not used to refresh these values.
4. **[P2] Quiet-state copy can claim an unobserved interval.** `SamplingEngine.swift:554` defaults a never-busy process to a quiet interval and ignores `windowCovered`. A newly seen idle listener can therefore receive a five-minute observation label immediately. This undermines the project inactivity equivalence.
5. **[P3] Reference documentation is stale.** `design-reference/vitals-1.2/README.md:29` still classifies temperature/fan reading as omitted even though it now exists. Its broad private-API explanation is not evidence of implementation or feasibility for every other missing subsystem.

These are audit findings; this turn does not change application behavior.

## Status totals

| Status | Listed bullets |
|---|---:|
| Covered | 6 |
| Partial | 18 |
| Missing | 20 |
| Defective | 2 |
| Unverified | 4 |
| Excluded | 2 |
| N/A | 8 |

Covered = a functional counterpart exists in source; it does not imply fresh end-to-end validation of every hardware case. Partial = some significant components exist. Missing = no corresponding implementation was found. Defective = relevant code exists but has a confirmed correctness problem. Unverified = no sufficient performance/hardware/regression evidence. Excluded = previously deferred, still not completed. N/A = vendor-specific commercial or identity behavior outside the monitoring target.

## Every listed changelog entry

| Release | Reference item | Status | Current source evidence / remaining work |
|---|---|---|---|
| 1.2.1 | Inline termination | **Missing** | Popover app rows have no action; Docker observation has no stop controller. [MenuBarPanel.swift](/Users/mdshagilnizami/code/projects/metrics/App/MenuBarPanel.swift:1122); [DockerCollector.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Collectors/DockerCollector.swift:94) |
| 1.2.1 | Fan adjustment | **Excluded** | Prior scope deliberately excludes SMC writes. Read-only RPM collection is implemented; it does not satisfy this entry. [SMCCollector.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Collectors/SMCCollector.swift:92) |
| 1.2.1 | Battery efficiency | **Missing** | Cadence depends on surface visibility, not battery source. GPU sampling and history recording still run each tick. [SamplingEngine.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Sampling/SamplingEngine.swift:140); [AppModel.swift](/Users/mdshagilnizami/code/projects/metrics/App/AppModel.swift:173) |
| 1.2.1 | Counter safety | **Defective** | Unchecked UInt64 additions remain in parsing and aggregation; no invalid-counter cleanup implementation was found. See finding 1. [SystemExtraCollectors.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Collectors/SystemExtraCollectors.swift:331) |
| 1.2 | App anatomy | **Partial** | Category shares, headline and expansion exist. Firefox/Dia are absent from the browser-name set; Electron renderers are grouped by process type, not individual window. The detail values also freeze. [AppBreakdown.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Attribution/AppBreakdown.swift:35); [InsideAppSheet.swift](/Users/mdshagilnizami/code/projects/metrics/App/InsideAppSheet.swift:14) |
| 1.2 | Docker telemetry | **Partial** | CPU, RAM, status and published ports exist on both surfaces. The model has no network or block-I/O fields, and the window has no telemetry chart. [DockerCollector.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Collectors/DockerCollector.swift:20); [ContainersViews.swift](/Users/mdshagilnizami/code/projects/metrics/App/ContainersViews.swift:65) |
| 1.2 | Heat attribution | **Missing** | Temperatures and CPU rankings exist independently. No temperature-triggered explanation or associated app termination workflow was found. [MenuBarPanel.swift](/Users/mdshagilnizami/code/projects/metrics/App/MenuBarPanel.swift:675) |
| 1.2 | Sleep holders | **Partial** | Both surfaces show process, assertion kind and detail. The model drops assertion age, so duration cannot be shown. [SleepAssertionCollector.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Collectors/SleepAssertionCollector.swift:8) |
| 1.2 | Global keybindings | **Missing** | Settings has no shortcut registration or shortcut editor. Scoped source search found no global-key handler. [SettingsView.swift](/Users/mdshagilnizami/code/projects/metrics/App/SettingsView.swift:29) |
| 1.2 | Automation actions | **Missing** | No AppIntent/AppShortcuts implementation or extension target in the app/package/project configuration. |
| 1.2 | Microphone monitoring | **Missing** | No audio input-device, input-level or capture-client collection/UI was found in the bounded source scope. |
| 1.2 | Status options | **Partial** | Pressure selection exists. There is no compact-size preference or menu-bar network readout. [Preferences.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Models/Preferences.swift:5) |
| 1.2 | Rendering efficiency | **Unverified** | Slower background cadence exists, but covered-window detection is absent and no before/after CPU or memory benchmark establishes the claimed efficiency. [AppModel.swift](/Users/mdshagilnizami/code/projects/metrics/App/AppModel.swift:125) |
| 1.2 | Docked inspector | **Missing** | The implementation is a modal sheet over the content, rather than a pane which changes the chart layout. [ProcessesView.swift](/Users/mdshagilnizami/code/projects/metrics/App/ProcessesView.swift:46) |
| 1.2 | Keyboard navigation | **Missing** | Popover tabs are images with tap gestures, without focusable tab buttons, number-key bindings or a specific escape handler. [MenuBarPanel.swift](/Users/mdshagilnizami/code/projects/metrics/App/MenuBarPanel.swift:92) |
| 1.2 | Hourly rankings | **Partial** | The store applies an exact since-date predicate. UI ranges omit 1h and 12h, and ranking sums process CPU samples instead of integrating stable app usage over time. [HistoryStore.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/History/HistoryStore.swift:145); [Preferences.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Models/Preferences.swift:55) |
| 1.2 | Raw-name filtering | **Covered** | Grouped search includes helper process names, while flat search uses the process display name derived from its original name. [ProcessesView.swift](/Users/mdshagilnizami/code/projects/metrics/App/ProcessesView.swift:147); [ProcessRow.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Models/ProcessRow.swift:91) |
| 1.2 | Intel wattage | **Excluded** | Per-app watts were deliberately deferred. The current power ring is explicitly based on CPU share, not watts. [OverviewView.swift](/Users/mdshagilnizami/code/projects/metrics/App/OverviewView.swift:350) |
| 1.2 | Mixer stability | **Missing** | There is no mixer implementation to provide stable slider ordering or device filtering. |
| 1.1.1 | Audio restoration | **Missing** | No per-app audio controls, saved levels or restoration on relaunch were found. |
| 1.1 | Readout customization | **Partial** | One MenuBarExtra, four metric choices, and hottest temperature are present. Independent items, graphs, configurable captions/icons, disk readout and selectable CPU/GPU temperature are absent. [PortmasterApp.swift](/Users/mdshagilnizami/code/projects/metrics/App/PortmasterApp.swift:14); [Preferences.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Models/Preferences.swift:5) |
| 1.1 | Audio/peripherals | **Missing** | Neither audio nor Bluetooth appears in the fixed main-window or popover tab definitions. [MainWindow.swift](/Users/mdshagilnizami/code/projects/metrics/App/MainWindow.swift:67); [MenuBarPanel.swift](/Users/mdshagilnizami/code/projects/metrics/App/MenuBarPanel.swift:10) |
| 1.1 | Layout editing | **Partial** | The Sensors tab exists. Tab lists and card order are fixed; no persisted visibility/order editor or alternate list layout exists. [MainWindow.swift](/Users/mdshagilnizami/code/projects/metrics/App/MainWindow.swift:67); [OverviewView.swift](/Users/mdshagilnizami/code/projects/metrics/App/OverviewView.swift:110) |
| 1.1 | Secondary-click menu | **Missing** | The status item has no context menu with the required commands. Opening the panel exposes ordinary controls instead. [PortmasterApp.swift](/Users/mdshagilnizami/code/projects/metrics/App/PortmasterApp.swift:14) |
| 1.1 | Surface appearance | **Partial** | Card backgrounds use regularMaterial, but no preference switches the dropdown between material and solid fill. [Theme.swift](/Users/mdshagilnizami/code/projects/metrics/App/Theme.swift:195) |
| 1.1 | Settings preview | **Missing** | Settings is a four-page TabView, without a layout editor or arrangement preview. [SettingsView.swift](/Users/mdshagilnizami/code/projects/metrics/App/SettingsView.swift:12) |
| 1.1 | App deep-linking | **Missing** | Popover app rows have no app-specific navigation action; the footer only opens the main window. [MenuBarPanel.swift](/Users/mdshagilnizami/code/projects/metrics/App/MenuBarPanel.swift:1122); [MenuBarPanel.swift](/Users/mdshagilnizami/code/projects/metrics/App/MenuBarPanel.swift:1164) |
| 1.1 | Compatibility repairs | **Partial** | SMC decoding and optional battery-health fields exist. M5/laptop parity is unverified; history lacks stable app identity and there is no corresponding folder-permission status UI. [SystemExtraCollectors.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Collectors/SystemExtraCollectors.swift:474); [HistoryStore.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/History/HistoryStore.swift:154) |
| 1.0.9 | Unit preferences | **Missing** | Formatting is fixed; preferences contain no temperature, network-unit or CPU-scale setting. [Preferences.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Models/Preferences.swift:83); [SystemSample.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Models/SystemSample.swift:113) |
| 1.0.9 | Extra numerals | **Covered** | CPU uptime, percentage accompanying pressure status, and disk occupancy are implemented in the dashboard/detail UI. [OverviewView.swift](/Users/mdshagilnizami/code/projects/metrics/App/OverviewView.swift:133); [OverviewView.swift](/Users/mdshagilnizami/code/projects/metrics/App/OverviewView.swift:154); [OverviewView.swift](/Users/mdshagilnizami/code/projects/metrics/App/OverviewView.swift:215) |
| 1.0.9 | Visual transitions | **Partial** | Tab selection animates and hover affects styling. No complete counterpart to the reference chart/hover motion was established. [MainWindow.swift](/Users/mdshagilnizami/code/projects/metrics/App/MainWindow.swift:142) |
| 1.0.9 | Activation continuity | **N/A** | Portmaster has no vendor license system; this vendor-specific repair is outside the monitoring feature target. |
| 1.0.9 | Chrome stability | **Partial** | Main-window sizing and fixed panel width exist. Status-text width is variable and explicit popover dismissal was not verified in this audit. [PortmasterApp.swift](/Users/mdshagilnizami/code/projects/metrics/App/PortmasterApp.swift:88); [AppModel.swift](/Users/mdshagilnizami/code/projects/metrics/App/AppModel.swift:248) |
| 1.0.8 | List efficiency | **Unverified** | Lazy lists exist, but no comparative profiling establishes a specific CPU reduction. [ProcessesView.swift](/Users/mdshagilnizami/code/projects/metrics/App/ProcessesView.swift:185) |
| 1.0.7 | Port presentation | **Partial** | Known system listeners are filtered. Project badges stay in a horizontal row capped at three ports instead of a wrapping list of all ports. [SamplingEngine.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Sampling/SamplingEngine.swift:321); [WindowDetailViews.swift](/Users/mdshagilnizami/code/projects/metrics/App/WindowDetailViews.swift:751) |
| 1.0.7 | Measurement repairs | **Defective** | Alert threshold tests pass, but per-process network initialization and session aggregation remain incorrect. Locale-safe number formatting is also not established. See finding 2. [SamplingEngine.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Sampling/SamplingEngine.swift:460) |
| 1.0.7 | Small-window behavior | **Unverified** | The window enforces a minimum size, but this audit did not test all tabs at that size or a many-core machine. [PortmasterApp.swift](/Users/mdshagilnizami/code/projects/metrics/App/PortmasterApp.swift:98) |
| 1.0.7 | Miscellaneous repairs | **Unverified** | The changelog is not specific enough to map every historical bug; several named subsystems have no Portmaster implementation. |
| 1.0.6 | Dock visibility | **Covered** | Persisted setting and NSApplication activation policy are implemented. [SettingsView.swift](/Users/mdshagilnizami/code/projects/metrics/App/SettingsView.swift:56); [AppModel.swift](/Users/mdshagilnizami/code/projects/metrics/App/AppModel.swift:299) |
| 1.0.6 | Install experience | **Missing** | No DMG installer or drag-to-Applications packaging asset/script was found; build instructions are Xcode-based. |
| 1.0.5 | Termination escalation | **Covered** | Project/service process targets can use the confirmation sheet and escalate after a failed graceful attempt. No destructive action was run during the audit. [ProjectsPortsView.swift](/Users/mdshagilnizami/code/projects/metrics/App/ProjectsPortsView.swift:113); [StopSheet.swift](/Users/mdshagilnizami/code/projects/metrics/App/StopSheet.swift:128) |
| 1.0.5 | Project-wide stop | **Missing** | A stop target represents one root/tree. There is no action that collects every independent process belonging to a project. [AppModel.swift](/Users/mdshagilnizami/code/projects/metrics/App/AppModel.swift:385) |
| 1.0.4 | Key sanitation | **N/A** | No corresponding license-entry field exists in Portmaster. |
| 1.0.3 | Review solicitation | **N/A** | The vendor feedback/review service is not part of the local monitoring target; no analogous Portmaster flow exists. |
| 1.0.3 | License copy | **N/A** | Portmaster has no corresponding activation flow. |
| 1.0.2 | Key retrieval | **N/A** | No corresponding vendor-key recovery service. |
| 1.0.2 | Activation disclosure | **N/A** | No license activation payload is sent by this app. |
| 1.0.1 | Intel support | **Partial** | Core uses macOS frameworks with optional GPU/SMC values, but this audit did not build a universal artifact or test Intel hardware. [Package.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Package.swift:8) |
| 1.0.1 | First-run experience | **Missing** | Launch opens the main window directly; no dedicated onboarding flow exists. The license component is N/A. [PortmasterApp.swift](/Users/mdshagilnizami/code/projects/metrics/App/PortmasterApp.swift:64) |
| 1.0.1 | License management | **N/A** | No paid license/deactivation feature is part of the current product. |
| 1.0.1 | Update delivery | **Missing** | No updater framework, appcast or update command was found in source/configuration. |
| 1.0.1 | Vendor branding | **N/A** | The reference icon is vendor identity, not a shared monitoring feature; no claim of identical branding is made. |
| 1.0.0 | App aggregation | **Partial** | CPU/RAM and observed disk-write/download rollups exist. App wattage is absent and network rollups are affected by the counter defects. [AppRollup.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Attribution/AppRollup.swift:23) |
| 1.0.0 | Subsystem views | **Covered** | Overview and CPU, memory, disk, network, GPU and power views are wired to the sampling model. Availability differs by hardware. [MainWindow.swift](/Users/mdshagilnizami/code/projects/metrics/App/MainWindow.swift:178) |
| 1.0.0 | Resource alerts | **Covered** | CPU, memory-growth, disk and network alert kinds and their sustained-window tests exist. This does not prove that the flawed live network input is correct. [AlertEngine.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Alerts/AlertEngine.swift:1) |
| 1.0.0 | Project observation | **Partial** | Attribution, port grouping and quiet labels exist. No project-idle alert exists, and quiet labels can appear before the claimed observation window is covered. [SamplingEngine.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Sampling/SamplingEngine.swift:548) |
| 1.0.0 | Historical usage | **Partial** | 24h/7d/30d and an extra 3d range exist. 12h, resource-complete history and app-stable rankings are absent. [HistoryView.swift](/Users/mdshagilnizami/code/projects/metrics/App/HistoryView.swift:72); [HistoryStore.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/History/HistoryStore.swift:145) |
| 1.0.0 | Audio levels | **Missing** | No audio mixer exists in source. |
| 1.0.0 | Peripheral telemetry | **Partial** | Read-only temperature/fan readings and root-volume statistics exist. Audio levels, Bluetooth batteries and mounted-volume inventory are absent. [OverviewView.swift](/Users/mdshagilnizami/code/projects/metrics/App/OverviewView.swift:192); [SystemExtraCollectors.swift](/Users/mdshagilnizami/code/projects/metrics/Core/Sources/PortmasterCore/Collectors/SystemExtraCollectors.swift:123) |
| 1.0.0 | Status dashboard | **Partial** | A working live value and navigable panel exist; customization and several reference tabs/actions remain absent. [PortmasterApp.swift](/Users/mdshagilnizami/code/projects/metrics/App/PortmasterApp.swift:14) |

## Video comparison

| Reference time | Observed surface | Portmaster assessment |
|---|---|---|
| 0–2 s | Compact overview, audio row, app ranking | **Partial.** Core readings and rankings exist, but the panel layout differs and audio is absent. |
| 3–4 s | CPU detail | **Core counterpart present.** Percentages, load, history and app ranking exist. This is not a pixel/animation parity certification. |
| 5–6 s | Memory detail | **Partial.** App/wired/compressed/swap and ranking exist, but there is no explicit cached-memory field or row. |
| 7 s | Disk detail | **Partial.** Root-volume usage and observed process I/O exist; a complete mounted-volume inventory does not. |
| 8–9 s | Network detail | **Partial / defective.** Rates, session totals and rankings are implemented but affected by findings 1–2. |
| 10 s | GPU detail | **Partial.** Real M4 GPU aggregate readings exist; app GPU utilization is deliberately absent. |
| 11–16 s | Battery details and assertion list | **Partial.** Battery/health/cycle fields and awake process reasons exist; assertion duration and per-app wattage do not. Laptop metadata remains unverified live. |
| 17 s | Audio input/output and app sliders | **Missing.** No corresponding source subsystem or UI. |
| 18 s | Connected peripheral panel | **Missing.** The reference demonstrates an empty state, not a battery-bearing device; Portmaster has no corresponding panel at all. |
| 19–20 s | Project counts, badges and RAM | **Partial.** Project attribution/summary exists, but the UI caps badges and does not offer a whole-project operation. |
| 21–25 s | Container dropdown | **Partial.** The panel lists containers and CPU/RAM/ports; it does not supply the whole later window workflow. |
| 26–30 s | Main subsystem cards and alerts | **Partial overall.** Six metric cards and resource-alert strip exist. The reference's project-idle alert, section structure and complete detail workflow differ. |
| 31–43 s | Chrome inspector, category-share toggle | **Partial.** Headline, segmented shares and expanders exist; presentation is modal and captured values freeze. App-level resource/history cards from the reference are absent. |
| 44–57 s | Safari inspector | **Partial.** WebKit grouping exists; the same modal/frozen-detail restrictions apply. |
| 58–65 s | Container window | **Partial.** CPU/RAM/status/ports table exists. Missing: container history area chart, per-container share visualization, largest-container card, network and disk columns, and filter controls. See the saved 60-second still. |

Useful direct comparisons:

- [Reference overview](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/t_31.0.png) versus [current live Hardware/overview](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/smc-verification/overview.png).
- [Reference container window](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/t_60.0.png) versus [previously captured Portmaster container window](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/pm_02_containers.png). The Portmaster capture establishes an availability state on this machine, not populated-container telemetry.
- [Reference Chrome detail](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/t_34.0.png) versus [previous Portmaster Inside App capture](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/pm_04_inside_app.png). A matching headline alone does not establish live-update or presentation parity.

## Remaining work, in practical order

1. Correct network overflow/baselines/totals, reconcile the open app sheet to live snapshots, and make inactivity labels match the observed interval.
2. Complete container data/visualization and add user-confirmed container actions. Complete app navigation/actions on the panel and thermal-context explanations.
3. Build the absent audio and peripheral subsystems; preserve the previously agreed boundaries for unsupported/deferred behavior.
4. Add configurable status items, tab/card arrangements, unit settings, key navigation/global bindings and automation integrations.
5. Finish history ranges/identity/aggregation, project-wide targeting, packaging/updating and first-run UX.
6. Benchmark hidden/covered/on-battery behavior and verify Intel, M5, internal-battery and dense-window configurations. Do not convert undocumented compatibility assumptions into a completed status.

## Verification and limits

Fresh check: `swift test --package-path Core` passed **82/82** with zero failures on this M4 during the audit. These tests do not cover the missing systems or the network/inspector defects above. The previous same-session Xcode app build succeeded; it was not repeated in this audit because application source was not modified.

This turn adds only this report. No process/container termination was tested, no saved app preferences were changed, and Portmaster was not launched for a fresh visual sweep. Current SMC visual evidence comes from the earlier same-session captures; other Portmaster captures are prior evidence cross-checked against current code. Original video replay, animation timing, Intel/M5 hardware, internal-battery metadata and exact cross-language formatting were not verified.

## Fix log

**Batch 1 — confirmed defects 1–5: fixed.**

- **1. Counter overflow:** every UInt64 counter sum saturates (`UInt64.saturatingAdd`): nettop duplicate-pid parsing, the engine diff, session totals, and interface totals. Changelog row *Counter safety*: Defective → Covered.
- **2. Baselines/totals:** `SamplingEngine.diffNettop` is now pure. The first pass sets the baseline. Only pids present in both passes contribute; departed pids no longer cancel survivors, and a new pid's lifetime bytes count as baseline. *Measurement repairs*: Defective → Partial, because locale-safe formatting is still open.
- **3. Inside App freeze:** the sheet keeps only the rollup's identity and reads values from `model.snapshot` on every sample. If the app quits, it shows the last observed values with a label saying so.
- **4. Quiet interval:** a listener's first sighting starts its observation window. The label only states silence that was actually observed. Pids that stop listening are dropped from the ledger.
- **5. README:** updated; temperature and fan readings are implemented, and the other subsystems are listed as open work.

Verification: `swift test --package-path Core` passed 92/92 (10 new in `ParityDefectTests`). `xcodebuild` Debug build succeeded. No live UI sweep was done for the sheet refresh.

### Batch 2 — container telemetry/actions, menu-bar app actions, heat context

Implemented on 2026-09-30, following batch 1:

- Container received/sent and block read/write rates from Docker's cumulative counters. Full container IDs join ps and stats, so renaming/replacing a container cannot reuse another container's baseline. First readings, counter resets and failed readings remain unknown. Successful reads carry a timestamp to deduplicate the slow-lane cache.
- Container memory/network/disk history chart with metric selection, per-container series and a bounded 30-minute session history. Observed points avoid inventing continuity through missing readings. History clears when switching data sources.
- Container Stop… confirmation with impact text, background command execution, bounded command lifetime, fixed arguments and validated immutable IDs. A successful stop command must also be confirmed by `inspect` reporting `State.Running=false`; otherwise the sheet reports failure. Preview stops are disabled.
- CPU, memory, network, disk and Busiest menu-bar app rows open Inside App on click. Their context menus and accessibility actions offer Inside App and Quit…, reusing the existing confirmed process stop flow in the main window. Preview quit actions are disabled.
- Overview and Sensors show macOS thermal pressure alongside the three busiest current CPU groups and link to Inside App. This is possible-contributor context, not per-app temperature attribution or watts. Per-app GPU attribution remains unavailable.

Validation: final `swift test --package-path Core` passed **102/102**, including **10 new ContainerParityTests**. Focused `swift test --package-path Core --filter ContainerParityTests` passed 10/10. Final Debug `xcodebuild` succeeded. Existing compiler warnings remain. Snapshot-based final diff reviewed because this workspace has no Git repository.

Live checks: M4 Sensors readings and heat context displayed; a heat contributor opened Inside App. An open Chrome Inside App sheet changed from 3.2 GB / 43 processes to 2.4 GB / 42 processes, visibly confirming batch 1's live-update fix. The main Containers tab correctly displayed the unavailable Docker daemon state. Menu-bar app accessibility actions were exposed; the actual popover's detail/quit click paths were not fully exercised. No running user app or container was stopped.

Limits: Docker CLI is installed but its daemon is down. Running-container rates/history, chart layout with populated data, and the container confirmation sheet were build/test verified, not live verified against a running daemon. The Sensors screenshot uses the existing window-hosted debug panel, not the actual menu-bar popover. Container history is session-only; this batch does not complete all outstanding changelog/video parity.

Screenshots and notes: [batch-2-verification](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/batch-2-verification/README.md). Portmaster was quit after verification; saved preferences compared identical.

Docker command semantics checked against [stats documentation](https://docs.docker.com/reference/cli/docker/container/stats/) and [stop documentation](https://docs.docker.com/reference/cli/docker/container/stop/), and the installed CLI's help.

### Batch 3 — audio controls, input activity/meter and Bluetooth batteries

Implemented on 2026-10-01, following batch 2. The original audit tables above describe the pre-fix snapshot; this log records the subsequent changes without claiming a complete new parity audit.

- Audio and Bluetooth views are wired into the main window and menu-bar panel. Live device/client telemetry runs on the engine's slow lane; unavailable values remain distinct from empty or zero values. Preview providers do not access hardware.
- Default-output volume control and temporary per-app volume/mute controls are implemented. Per-app controls use explicit opt-in Core Audio process taps on macOS 14.2+, support one mono/stereo float32 output stream, preserve process identity, and reject unsupported formats. The real-time callback uses bounded gain changes and atomic state; an independent watchdog checks route failure and output-device changes. Removal checks teardown results and reports failed cleanup rather than claiming success. No default output device is changed.
- Input-active process observations and default input device are shown with a virtual/loopback caveat. The microphone meter requests permission only on explicit enable, does not save/send samples, and stops on input configuration changes. Application quit and preview switches request cleanup of temporary audio resources.
- Connected Bluetooth inventory merges HID registry battery data with connected-only system_profiler output. Unknown and invalid percentages remain unknown; component batteries are supported when reported. Polling is bounded and does not pair devices or initiate an active scan.
- One existing CPU history test assumed that one hour before the test was always today; it failed after midnight. Its test clock now uses local noon. Production history logic was not changed.

Validation: final `swift test --package-path Core` passed **112/112**, including **10 new AudioPeripheralTests**. The focused audio/peripheral suite passed **10/10**. Debug `xcodebuild` succeeded. Snapshot-based final diff reviewed; existing compiler warnings remain.

Live evidence: Audio showed Mac mini Speakers at 81% and the C270 webcam input. An active Chrome mixer row was observed in the accessibility tree. Bluetooth cards showed Magic Keyboard **63%** and Magic Mouse **57%**, matching read-only hardware readings. Portmaster was quit afterward; saved preferences compared identical. No system volume, user-app audio route or microphone permission was changed.

Limits: actual per-app tap routing/playback/mute and removal, Audio Recording/Microphone permission flows, microphone level capture, device-switch recovery, connected earbud component readings and the actual menu-bar popover remain unverified live. Mixer persistence/automatic restoration remain deferred. Source/build completion does not establish full reference behavior or visual parity. Screenshots and detailed checks: [batch-3-verification](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/batch-3-verification/README.md).

Public API reference: [Apple's Core Audio tap capture documentation](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps); supported OS versions and HAL property contracts were also checked against the installed SDK headers.

### Batch 4 — menu-bar readouts, arrangement, units, keyboard and App Intents

Implemented on 2026-10-01. The reference changelog was refreshed; its latest entry remains 1.2.1 dated 2026-09-30. This is a batch fix log, not a new certification of every original audit row.

- Replaced the single SwiftUI menu-bar item with separately identified native status items. CPU, memory-pressure state, memory used, top-process CPU, GPU, temperature, download, upload and disk-write readouts support value/graph/both, icon/caption and compact sizing. Temperature can follow CPU/GPU/hottest. Autosave names let macOS own ordering; an empty/duplicate configuration has a safe fallback. Right-click actions open the window, Settings or Quit. Update delivery remains batch 5 work.
- Added sidebar Settings and a live readout preview. Window tabs, dropdown tabs, overview cards/rings and dropdown overview tiles can show/hide/reorder independently. The dropdown has tiles/list and translucent/solid options. Arrange exposes grouped sections for CPU, Memory, Disk, Network, GPU, Power, Containers and Audio. Statistic cards move as a strip; unlisted tabs keep one content group. Arbitrary arrangement of every nested card/section is still partial.
- Added Celsius/Fahrenheit, network bytes/bits and per-core/per-Mac app/process CPU. Raw samples/history and alert thresholds are unchanged. System CPU/GPU remain whole-chip; Docker CPU remains on the VM basis. Network container labels/history use the selected display units. Memory pressure uses the actual kernel state; occupancy is labelled used, and the pressure graph represents categorical states.
- Added native global window/dropdown shortcut registration and settings, validation and conflict reporting. Added real dropdown buttons and ⌘1–⌘0, Tab/Shift-Tab and Esc navigation. Window and Settings entry points dismiss the dropdown and share the actual delegate instance instead of relying on a cast through SwiftUI's delegate wrapper.
- Added App Intents/App Shortcuts for an observed reading, busiest current app, opening the window and showing the dropdown. Readings wait for a recent snapshot, report unavailable values and label previews; these actions do not stop processes, change audio or capture a microphone.

Verification: **123/123 Core tests pass**, including **11 PresentationTests**. Final Debug build succeeds; extracted metadata contains four intents and four App Shortcuts. Source/configuration snapshot diff reviewed and codebase graph refreshed.

Live checks: sidebar Settings, unit examples (104°F / 8.0 Mbit/s / 10.0% on ten cores), CPU app-list reordering, saved readout configuration after relaunch, and the actual dropdown's ⌘5 → Network, Tab → GPU and Esc dismissal. Temporary shortcut configuration registered without an error. Portmaster was quit, verification preferences were restored, and complete before/after preference exports compared identical.

Limits: global shortcut triggering from another app was not established by synthetic key attempts; end-to-end Shortcuts execution, native status-item pixel/drag behavior, context-menu clicks, every arrangement/appearance combination and non-US keyboard positions remain unverified. Per-card arrangement inside grouped statistic strips and unsupported tab groups remain partial. [Screenshots and detailed notes](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/batch-4-verification/README.md).

### Batch 5 — history, whole-project quit, welcome and distribution

Implemented on 2026-10-01. Historical rows above remain the original audit snapshot; this fix log records current changes and limits.

- Added independent 1h/12h/24h/7d/30d viewing ranges; retention stays separate. New app history groups helpers by bundle identity, persists across PID changes, integrates elapsed CPU seconds, clips the first interval to the selected window, and skips unknown CPU/sleep gaps. New resource history stores GPU, network, disk, battery, temperatures and fan readings where available. App CPU/memory/network/disk charts and legacy process/project records remain distinguishable. Unknown readings break chart lines rather than becoming zero.
- Kept the original SwiftData tables. An isolated migration test preserved all **51,065** existing rows; extended tables are included in retention and clear. Local history backup was made before native launch.
- Whole-project quit freezes every currently attributed process, including non-listeners, shows exact names/PIDs/ports, checks start times before signaling and reports the entire set after one shared grace period. Unknown/reused identities are left untouched; newly spawned processes require another confirmation. Existing app/process stop entry points use the same confirmed membership. Force recovery has a second confirmation.
- Native verification uncovered a project-attribution directory-enumeration stall. Direct marker checks and a 30-second miss cache replaced listing whole working directories.
- Native CPU readings uncovered Mach-timebase and scale errors: PROC_PIDTASKINFO counters are now converted to nanoseconds; process sampling uses canonical per-core CPU and the per-Mac display divides once. New/reused/reset process readings set a baseline. Old CPU records cannot be retrospectively corrected.
- New installs get a welcome screen; legacy preferences skip it. Welcome is reopenable. Notification Center permission now requires an explicit Alerts action rather than a launch prompt.
- Added pinned Sparkle **2.10.0**, update settings and menu entries. Unconfigured builds do not start/check the updater. Automatic checks/downloading default off; profiling is disabled and archive signatures are verified before extraction. Real release feed/public key are still absent.
- Added a verified local drag-to-Applications DMG and reusable packaging script, plus release configuration/signing/notarization/appcast instructions. The DMG is an ad-hoc development build, not a public signed/notarized release.

Validation: **147/147 Core tests** and final **24/24 HistoryDeliveryTests** pass; Debug build passes. Native 12-hour sensor history, elapsed CPU rankings, welcome and disabled update state observed. An owned project with two listeners and one non-listener was stopped through the confirmation sheet; all three PIDs exited. Final DMG checksum, mounted contents, Applications symlink and embedded app signature verified. App quit; preference exports restored exactly. Source/configuration snapshot diff reviewed.

Remaining: release hosting/keys/signing/notarization and actual update delivery; large-store history responsiveness (main-thread fetch/aggregation caused multi-second range changes); app-scope/every-resource/unit/30-day combinations; native force recovery; cross-hardware and preceding audio/keyboard/arrangement limitations. The next batch should start with history performance and the remaining validation gaps, not claim complete parity. [Detailed evidence](/Users/mdshagilnizami/code/projects/metrics/design-reference/vitals-1.2/batch-5-verification/README.md).

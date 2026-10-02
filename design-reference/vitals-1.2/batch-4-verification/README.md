# Batch 4 — readouts, layout, units, keyboard and automation

Implemented and checked on the M4 Mac mini on 2026-10-01.

## Evidence

- [Layout settings](layout-settings.png): CPU value + graph and a separate memory-pressure readout restored after relaunch. The final pressure preview shows the kernel state, Elevated, rather than occupancy. Icon/caption choices are reflected in the preview.
- [Unit settings](units.png): Fahrenheit example 104°F, network example 8.0 Mbit/s, and per-Mac app/process CPU example 10.0% on ten cores. System CPU/GPU remain whole-chip percentages. Disk stays in bytes; Docker CPU remains on its VM basis.
- [CPU reordered](cpu-reordered.png) and [Arrange controls](arrange.png): the app list moved before the statistics strip. These captures were taken before selecting the per-Mac CPU scale later in the run.
- The actual native menu-bar popover was opened from the window toolbar. ⌘5 selected Network, Tab advanced to GPU, and Esc dismissed it. This check used the real popover, not the window-hosted debug panel.
- Adding a second readout and selecting CPU Both persisted in the preferences. The final build restored those settings. Physical ⌘-drag movement and rendered status-item pixel layout were not exercised.

## Verification

- Final `swift test --package-path Core`: **123/123 passed**, including **11 new PresentationTests** covering legacy/partial preference migration, independent layout round trips, removal of obsolete/duplicate IDs, recovery from all-hidden layouts, duplicate/empty status items, unit conversions, unknown readings and valid shortcut configuration.
- Final Debug `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -derivedDataPath /tmp/portmaster-smc-build build`: **BUILD SUCCEEDED**.
- Xcode's extracted `Metadata.appintents/extract.actionsdata` contains `GetPortmasterReading`, `GetPortmasterBusiestApp`, `OpenPortmasterWindow` and `ShowPortmasterDropdown`, plus four App Shortcuts.
- Source/configuration changes reviewed against the pre-batch snapshot because this workspace is not a Git repository. The codebase graph was refreshed; its recorded partial ranges in unrelated SMC/audio-shim code and existing process-view expressions are not treated as complete source coverage.
- Portmaster was quit after checking. Only the preference data and Settings window frame changed by verification were restored; the before/after exported preference domains compared identical. No app/container termination, audio capture, new OS permission or system volume change was exercised.

## Scope and limits

Window tabs, overview cards/rings, dropdown tabs and overview tiles have independent persistent orders/visibility, with a recoverable first-item fallback. CPU/Memory/Disk/Network sections can arrange their hero, statistics strip and apps; GPU, Power, Containers and Audio expose their relevant groups. Statistics cards move as a strip. Tabs without a section catalog keep their content together and explain this in Arrange. Individual statistic cards, arbitrary rearrangement of every nested section, and a complete reference layout clone remain open work.

Global window/dropdown shortcuts use native Carbon registration, validate modifiers/keys, unregister old bindings and report registration/conflict errors. A temporary ⌥⌘P choice registered without an error. Synthetic shortcut attempts did not establish successful global triggering from another app; that remains unverified. Routing uses the actual app delegate instance rather than casting SwiftUI's application-delegate wrapper, and popup presentation explicitly activates the accessory app after showing it.

The four App Intents are implemented and have extracted metadata, but they were not invoked end-to-end from Apple's Shortcuts app. Compact mode, native context-menu clicks, status-item drag persistence, non-US key positions, every hidden/reordered combination and opaque/translucent presentation need further live checks. The dropdown's local ⌘1–⌘0/Tab/Esc controls were exercised successfully.

Pressure graphs track the categorical Normal/Elevated/Critical states on a fixed three-state scale. No numeric kernel pressure percentage is invented. Readout graphs reset between live and preview data sources; raw process CPU history is converted at render time so switching CPU scale does not mix scales in one graph.

References: [Vitals changelog](https://vitalsmac.com/changelog), [Apple status-item autosave identities](https://developer.apple.com/documentation/appkit/nsstatusitem/autosavename-swift.property), and [Apple App Intents](https://developer.apple.com/documentation/appintents/appintent).

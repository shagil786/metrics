# Batch 5 verification — 2026-10-01

Implemented history ranges/identity/CPU-time aggregation/resource charts, frozen project-wide quit, first-run welcome, Sparkle integration and local DMG packaging. This is implementation evidence, not a claim that every historical Vitals audit row is complete.

## Checks performed

- Full Core suite: **147/147**, no failures. Command: `PORTMASTER_LEGACY_HISTORY=/tmp/pm-batch5-legacy/history.sqlite swift test --package-path Core`. Log: `/tmp/pm-batch5-tests.log`.
- Final focused suite: **24/24 HistoryDeliveryTests**, no failures. Same environment with `--filter HistoryDeliveryTests`; `/tmp/pm-batch5-history-tests.log`.
- Debug app build: `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -derivedDataPath /tmp/portmaster-smc-build build`; `/tmp/pm-batch5-build.log`.
- Legacy migration opened an isolated copy of the actual pre-upgrade database: **1,278 CPU + 1,278 memory + 48,145 process + 364 port = 51,065 rows**, all preserved. The original database and sidecars were backed up before launch. Normal configured retention continues to prune older rows.
- Persistence tests reopen the new tables and verify pruning/clear. Other tests cover elapsed-time weighting, first-window clipping, PID changes, helper memory aggregation, unknown rates, chart gaps/bounds, onboarding migration, updater configuration validation, confirmed stop membership, reused identities, failed signals and force recovery.
- A live busy-worker test checks the CPU counter. An independent M4 probe measured Mach timebase **125/3** and about **24 million ticks per busy-core second**, converting to about **1 billion nanoseconds**. Collector conversion and canonical per-core sampling now match the display/history contract. Intel 1/1 conversion is unit-tested, not hardware-tested.
- Live sampling initially stalled inside `contentsOfDirectory` in project attribution. Direct marker `lstat` probes replaced enumeration; misses cache for 30 seconds. Tests cover a FIFO path without opening it and a `.git` directory.

## Native evidence

- [Welcome](welcome.png): first-run screen and Get Started observed. Legacy preferences default to having completed onboarding.
- [12-hour CPU-temperature history](history-12h-temperature.png): selected 12h range, real recorded temperatures with gaps and elapsed CPU-time rankings. New app history survived relaunch; canonical samples showed meaningful CPU seconds and averages.
- [Project confirmation](project-confirmation.png): the owned temporary project had two HTTP servers on ports **52363/52364** and a non-listening `sleep` worker. The sheet listed exactly PIDs **26782, 26783, 26784**. Clicking Graceful Stop returned a stopped result for all three; subsequent `ps` checks confirm they exited. No unrelated project/app was stopped. Native force-quit recovery was not exercised; mock tests cover it.
- [Updates unconfigured](updates-unconfigured.png): automatic-check toggle and Check for Updates disabled, with the missing release configuration stated explicitly. No update feed was requested.
- The final [development DMG](/Users/mdshagilnizami/code/projects/metrics/dist/Portmaster-batch5-development.dmg) passed `hdiutil verify`, mounted read-only, contained an Applications symlink targeting `/Applications`, and its copied app passed `codesign --verify --deep --strict`. It was detached afterward. It was not installed or published.
- Portmaster was quit. The only verification-created preference key was removed; complete before/after preference exports compared identical. No audio/microphone/notification permission or system-volume change was made.

## Remaining limits

- Release host/appcast URL and Ed25519 public key are missing. Developer ID signing, notarization, published appcast, and actual old-to-new update installation are not verified. See [release instructions](/Users/mdshagilnizami/code/projects/metrics/Support/Release.md) and [Sparkle documentation](https://sparkle-project.org/documentation/).
- Large-store history queries run on the main thread. Native range/reading changes with accumulated history took several seconds; bounded plotted points do not bound database fetch or aggregation work. Move querying/aggregation off the main thread in the performance batch.
- App-scoped chart switching, every resource/range/unit combination, long 30-day stores and release/universal builds were not exercised live this batch. Battery/watts remain unavailable on this desktop; unavailable history stays blank. App helper identity is bundle path, CLI identity is executable name; old records cannot be retroactively assigned identities or corrected CPU timing.
- Hardware coverage remains M4. Intel/M5/laptop validation, Bluetooth earbud components, audio tap/microphone flows, native menu-bar drag ordering, global shortcut delivery, Shortcuts execution, and arbitrary nested card arrangement retain the preceding batch limits.

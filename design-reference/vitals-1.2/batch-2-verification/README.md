# Batch 2 verification — 2026-09-30

- [Sensors](sensors.png): live M4 readings and CPU/thermal-pressure context in the existing window-hosted menu-bar debug panel. This is not an actual popover capture.
- [Containers unavailable](containers-unavailable.png): real CLI installed, daemon down; honest availability state.
- [Inside App](inside-app.png): real Chrome sheet; subsequent accessibility observation confirmed values changed while it remained open (3.2 GB / 43 processes → 2.4 GB / 42 processes).

Core tests: 102/102; ten new container parity tests. Debug app build passed. Container delta parsing, baselines, replacement IDs, failure recovery, history deduplication/expiration, numeric bounds, stop arguments and stop-state confirmation covered by tests. Populated chart layout and actual container stop UI were not live verified because the daemon was unavailable. Actual menu-bar action click paths were not fully exercised; the shared detail route was verified from heat context. No user apps or containers were stopped. Saved preferences unchanged; app quit.

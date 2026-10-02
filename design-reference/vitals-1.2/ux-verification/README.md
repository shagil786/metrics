# Reference design correction — 2026-10-01

Compared against https://vitalsmac.com/ and the saved 1.2 video frames `../t_27.5.png` (Overview) and `../t_34.0.png` (Inside App).

## Current native captures

- `overview.png`: real 1792 × 1000 pt main window, single compact navigation pill, six metric cards in three columns, thin area/line charts and three live app/memory distribution cards.
- `hardware.png`: lower Overview with real SMC temperatures/fan RPM, heat context, sound and Bluetooth summaries.
- `cpu-sidebar.png`: CPU page with Chrome's live detail sidebar and grouped memory breakdown.
- `dropdown.png`: the actual live status popover, captured during the preceding clean-build verification.

All readings are live. Worth a Look appears when actual alerts exist; no alert data was injected for these captures. macOS appearance was dark. The main window now fits its default size to the available screen, up to 1792 × 1000 pt. The six metric cards remain at most three columns; the Hardware section uses four columns on a wide window.

## Changes retained

History reads now run through an actor with fresh SwiftData contexts, cancellation and explicit loading/error states. Projects and app lists no longer silently truncate their rows. Project search and readable stop confirmation, wrapping settings, accessible audio controls and clear availability explanations remain in place. The main app detail opens beside the active tab rather than changing tabs or covering the window.

## Verification

- `xcodebuild ... -derivedDataPath /tmp/pm-reference-final clean build`: BUILD SUCCEEDED; log `/tmp/pm-reference-final-build.log`.
- `swift test` in Core: 153 tests, 0 failures; log `/tmp/pm-ux-all-tests.log`. Six new HistoryReader tests included. No Core source changed after this run.
- Native checks: all eight numbered detail tabs; History chart and rankings; More picker and Alerts route; live Chrome detail, breakdown expansion and close; Overview chart style selection; current-readings CSV saved and validated (10 metric rows, units, shared timestamp); all six Settings pages; project search with match/no-match states and the previously hidden tenth project; quit confirmation cancelled; actual status popover opened through the keyboard command.
- After the last clean build: verified the new 1792 × 1000 pt Overview, three-column metric grid, Chrome sidebar and lower Hardware section.

Earlier incremental build artifacts produced SwiftUI material-renderer crashes. A separate clean ASAN build showed no memory error in the exercised flows; clean normal output also passed the recorded navigation flows. Stale build output is a suspected cause, not a proven diagnosis.

## Remaining limits

Light appearance and minimum 980 × 780 pt resizing were not visually verified. Changing app volume, microphone permissions, stopping containers, and clearing real history were not exercised. No process was stopped and no history was cleared. Long-range history rankings can take several seconds while the UI remains responsive.

This pass corrects the reference layout and interaction defects; it does not certify every Vitals changelog feature or pixel-perfect parity. The app displays three truthful distribution cards rather than inventing unavailable per-app power watts. This Mac mini shows AC power rather than fabricated battery data. Fan control and full persistent per-app audio routing remain outside the public-API implementation.

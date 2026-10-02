# Compact layout correction

This pass supersedes the earlier 1792-point window sizing. The app now defaults to **1120 × 800 points** (minimum 980 × 700), bounded by the display. Native Retina captures are 2240 × 1600 pixels; pixels are not window points.

Reference: [Vitals interactive app demo](https://vitalsmac.com/). The demo was inspected in the browser, including Sound, Bluetooth, Projects, GPU and Battery. Measured demo content was approximately 1032 CSS pixels wide. Its Sound/Bluetooth summary rows were approximately 70 pixels tall, GPU/Battery heroes 200 pixels, and GPU stat cards 110 pixels. These informed the structures and scale; reference demo numbers were not used as live readings.

## Changes

- Hardware: three 128-point summaries, with heat context in a collapsed disclosure.
- Sound: compact output summary, aligned app/status/volume/level columns, and a collapsed microphone section. A separate narrow row layout preserves app names in the menu panel.
- Bluetooth: device table with bounded battery meters, percentages and component rows.
- Projects: one full-width table with ports, memory, search and existing confirmation actions.
- GPU: shorter chart hero, average and peak of recent samples, memory and core statistics; explanatory notes collapse.
- Battery on this Mac mini: a 70-point AC summary and an awake section. Raw assertion details remain in tooltips.
- Shared detail typography and chart heights were reduced; default navigation fits the smaller window.

## Evidence

Native captures: [Hardware](hardware.png), [Sound](sound.png), [Bluetooth](bluetooth.png), [GPU](gpu.png), [Battery](power.png), [Projects](projects.png), [Sound menu panel](sound-dropdown.png).

Native checks covered all six affected pages, microphone disclosure expansion, Projects search match/no-match/reset, and the narrow Sound panel. No volume, microphone permission, per-app control or process-termination action was activated. The final inspection also corrected the Hardware count label to Audio clients; that text-only correction was rebuilt after these captures.

Validation:

```sh
xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -derivedDataPath /tmp/pm-density-build clean build
xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -derivedDataPath /tmp/pm-density-build build
```

Both passed. Source diff reviewed across six App files. Core was unchanged, so Core tests were not rerun in this UI pass. The graph index was refreshed. The review bundle is `dist/Portmaster-design-review.app`. The app was quit and the preferences domain was verified to exactly match its pre-inspection state.

## Limits

Light appearance and an interactive resize to the minimum window size were not verified. The MacBook battery branch compiled but could not be exercised on this Mac mini. Per-app GPU activity and power watts remain unavailable; this pass does not establish full feature parity or pixel-perfect fidelity. Existing peripheral permission and volume-control operations were preserved but not exercised.

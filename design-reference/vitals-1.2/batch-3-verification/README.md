# Batch 3 — audio and Bluetooth verification

Verified on the M4 Mac mini on 2026-10-01. These captures show the main window, not the actual menu-bar popover.

- [Audio](audio.png): Mac mini Speakers at 81%, C270 HD WEBCAM input, microphone meter opt-in, and the mixer availability state. The system output volume was not changed. An active Chrome row with an Enable control button was observed in the accessibility tree during this run; it was no longer active when the saved screenshot was taken.
- [Bluetooth](bluetooth.png): Magic Keyboard at 63% and Magic Mouse at 57%, matching the read-only hardware probes. Disconnected paired devices are excluded. Earbud component batteries are parser-tested, not verified with connected earbuds on this machine.

## Checks

- Final `swift test --package-path Core`: **112/112 passed**, zero failures.
- `swift test --package-path Core --filter AudioPeripheralTests`: **10/10 passed**. Coverage includes Bluetooth parsing, missing/invalid batteries, disconnected inventory, preview providers, attenuation, mute, gain ramps, mono/stereo buffer layouts, invalid-buffer handling and a read-only live collector smoke check.
- Debug `xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -derivedDataPath /tmp/portmaster-smc-build build`: **BUILD SUCCEEDED**. Existing compiler warnings remain.
- Snapshot-based source/configuration diff reviewed; this workspace has no Git repository.
- Portmaster was quit after verification. Exported saved preferences compared identical before and after the run.

## Remaining live verification

Per-app control is implemented using temporary public Core Audio process taps, with explicit enable/remove controls, attenuation/mute, checked buffer formats and teardown checks. The supported route is one mono/stereo float32 output stream on macOS 14.2 or later. Levels are session-only; persistence and automatic restoration remain deferred. No default audio device is changed.

No Enable control or Enable microphone meter button was clicked during this verification. Audio Recording/Microphone permission flows, audible per-app attenuation and mute, route creation/removal and failure recovery, microphone readings, and live device switching therefore remain unverified. The menu-bar Audio/Bluetooth views are build verified, but were not separately exercised in the actual popover.

Input activity is a HAL process-stream observation; virtual/loopback input is not proof that an app uses a physical microphone. Only the explicitly enabled meter captures input, and its samples are neither saved nor sent.

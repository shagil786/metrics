# SMC verification — September 30, 2026

Completed the unfinished SMC feature in the current workspace. Observation is read-only; no fan-control commands were added.

## Implemented

- Slow-lane SMC sampling attached to `SystemSample.thermal`, with an injectable thermal provider and separate preview provider.
- Overview Hardware card, popover Sensors tab, and hottest-temperature menu-bar choice.
- Optional battery capacity health and cycle count from the battery IORegistry. These are independent of SMC temperature/fan keys.
- Correct little-endian float payloads (real M4 sample: `F0Ac`, `flt `, bytes `00 00 7a 44` = 1000 RPM), legacy `fpe2` divisor, stable fan names, memory-sensor exclusion from CPU grouping, and clearing of readings after collector failure.

## Verification

Commands run successfully:

```sh
swift test --package-path Core --filter SMCCollectorTests
swift test --package-path Core
xcodebuild -project Portmaster.xcodeproj -scheme Portmaster -configuration Debug -derivedDataPath /tmp/portmaster-smc-build build
```

12 SMC/health/integration tests passed; the full Core suite passed **82/82**, with zero failures. The app build succeeded. The existing unused-variable warning in SamplingEngine remains, along with the normal AppIntents metadata warning.

A standalone C probe against the existing PMShim enumerated **1375** keys on this M4. The final live Core smoke test returned CPU maximum **76.58°C**, GPU maximum **51.88°C**, hottest **76.58°C**, and fan **1001 RPM**. These are observations at that instant, not fixtures or expected constants.

- [Overview capture](overview.png): live Hardware card, including CPU/GPU temperature and fan RPM, shown in the main app window.
- [Sensors capture](sensors.png): real live data in the same MenuBarPanel view used by the popover, hosted with `PORTMASTER_POPOVER=1 PORTMASTER_PANEL_TAB=sensors` for deterministic capture. This is a debug-hosted panel capture, not a capture of the actual status-item popover.
- Accessibility inspection confirmed the live Sensors values changed between observations and confirmed **Hottest sensor temperature** appears in Settings → General → Menu bar shows. The existing **CPU %** choice was left selected; the new temperature value was not captured in the actual status item.
- The saved `PortmasterPreferences` value matched byte-for-byte before and after verification. Portmaster was quit using its Quit button; the inspector confirmed it was no longer running.

## Limits

Intel fixed-point decoding was unit-tested, not verified on live Intel hardware. This M4 desktop has no internal battery, so battery-health parsing was unit-tested but laptop health/cycle readings were not verified live. Temperature grouping uses undocumented SMC key conventions and may differ across hardware/firmware. These limitations also appear in the main README.

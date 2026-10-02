# Vitals 1.2 reference frames

Frames captured (2026-09-30) from the product video in
[@attacomsian's tweet](https://x.com/attacomsian/status/2104994461608751245)
announcing Vitals 1.2 (vitalsmac.com). The video is the visual/functional
target Portmaster is being completed against.

- `t_<seconds>.png` — half-resolution (1792px) stills at key moments.
- `sheet_01..04.png` — contact sheets, 1 frame per second across the 66s video.

Key timestamps:

| t (s)  | Screen |
| ------ | ------ |
| 0.5    | Popover Overview tab (metric rows + Busiest Right Now) |
| 4.0    | Popover CPU tab (hero + Top Apps) |
| 6.5    | Popover Memory tab (App/Wired/Compressed/Cached + Top Apps) |
| 8.5    | Popover Network tab (rates + session totals + Top Apps by Download) |
| 10.5   | Popover GPU tab |
| 12.5   | Popover Battery tab + **Keeping This Mac Awake** section |
| 19.5   | Popover Projects tab (ports as badges, memory per project) |
| 24.5   | Popover **Containers** tab (Docker) |
| 27.5   | Main window Overview: six metric cards |
| 34.0   | Main window: Right Now donuts, Hardware (temps/fans, Volume Mixer, Bluetooth), Over Time charts |
| 31–38  | App detail sidebar — **Inside Google Chrome**: "Tabs use 82% of its memory" |
| 44–56  | Inside Safari breakdown |
| 60     | Containers window tab: chart, By Container, container table |

Implemented since capture: read-only temperature and fan RPM via the SMC
(`SMCCollector.swift`; see `smc-verification/`). Fan *control* (SMC writes)
remains out of scope.

Deliberately deferred: per-app power watts and per-app GPU utilisation.

Batch 3 implements temporary per-app volume control through public Core Audio
process taps (macOS 14.2+), read-only input/output activity, an opt-in microphone
meter, and connected Bluetooth battery cards. Volume routing and the microphone
meter await permission-gated listening/input verification; live keyboard/mouse
battery readings and Audio/Bluetooth UI were verified. Mixer levels reset when
control is removed or the app exits; restoration/persistence remains deferred.
Current status of every changelog item lives in `parity-audit-2026-09-30.md`.

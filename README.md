# Vitals

A lightweight macOS menu bar widget for live hardware vitals — CPU load with a
sparkline, per-core P/E split, die temperature, power draw, memory, disk,
network throughput, GPU, fan and battery health.

The bar shows only what changes moment to moment and is worth a glance: CPU
graph, CPU temperature and memory. Everything else lives in the click-through
popover, and any metric can be moved to the bar from the right-click menu.

Menu bar only: no Dock icon, no windows, no background daemon.

## Why

Existing vitals apps are heavy enough to distort the numbers they report. This
one is built around measured cost rather than feel.

| | CPU (one core) | Memory |
|---|---|---|
| Empty menu bar app (control) | 0.01% | 25 MB |
| Vitals @ 5s refresh | 0.25% | 24 MB |
| **Vitals @ 2s refresh (default)** | **0.51%** | **24 MB** |
| Vitals @ 1s refresh | 0.80% | 24 MB |

Memory rises to ~38 MB once the detail popover has been opened, and stays there.

## Design

Cost is dominated by the AppKit status item redraw, **not** by reading sensors —
sampling with the UI update disabled measures 0.20%. Refresh rate is therefore
the main lever, and it is exposed in the right-click menu.

Sensor reads are tiered by measured cost:

| Tier | Interval | Sources | Cost per sample |
|---|---|---|---|
| fast | refresh rate | CPU load, memory, network | ~30 µs |
| medium | 5 s | CPU temperature, power draw | ~680 µs |
| slow | 30 s | GPU, battery, fan | ~2.5 ms |
| disk | 300 s | disk capacity | ~5.8 ms |

Everything is read in-process through Mach, IOKit and SMC. Nothing shells out to
`powermetrics`, `top` or `ps`, and nothing needs `sudo`.

Sampling runs on a `.utility` background queue, so it lands on efficiency cores.
The menu bar is redrawn only when a value that is actually visible has changed.
Timers carry generous leeway so the OS can coalesce wakeups, and sampling
suspends on sleep and resumes on wake.

## Build

Requires the Command Line Tools. No Xcode project, and no SwiftPM — the
`libPackageDescription.dylib` shipped with CLT does not match its own compiler,
so the build drives `clang` and `swiftc` directly.

```sh
./build.sh             # build into .build/
./build.sh --install   # build, install to /Applications, restart the app
```

`--install` quits the running copy first. Replacing the bundle under a live
process leaves it running the old code until it restarts anyway.

## Checking it works

There is no unit test suite. The thing that actually breaks is a sensor path, when
Apple moves a key or changes a unit, and that only shows up against real hardware.
So there is a range check over every sampler instead:

```sh
clang -O2 -c src/smc.c -o /tmp/smc.o -Isrc
swiftc -O -swift-version 5 -import-objc-header src/Bridging.h \
    src/Sensors.swift tools/sanity/main.swift /tmp/smc.o \
    -framework IOKit -framework AppKit -o /tmp/sanity && /tmp/sanity
```

It exits non-zero if any reading falls outside a plausible range.

## Icon

`tools/make-icon.swift` draws the icon at all ten sizes macOS wants. `Vitals.icns`
is committed, so a normal build does not regenerate it:

```sh
swiftc -O tools/make-icon.swift -o /tmp/gen
/tmp/gen /tmp/Vitals.iconset
iconutil -c icns /tmp/Vitals.iconset -o Vitals.icns
```

## Layout

```
src/smc.c, CSensors.h   SMC access over the AppleSMC ioctl ABI
src/Sensors.swift       all samplers
src/UI.swift            menu bar drawing
src/Detail.swift        SwiftUI detail popover
src/main.swift          app delegate, tiers, menu
build.sh                clang + swiftc -> .build/Vitals.app
tools/make-icon.swift   draws Vitals.icns
tools/sanity/           range check over every sampler
```

The SMC ioctl struct is written in C deliberately. Swift does not reproduce its
layout — a hand-rolled Swift version comes out 76 bytes against C's 80, and the
mismatch fails silently, with every read returning nil.

## Usage

- **Left click** — detail popover
- **Right click** — choose metrics, refresh rate, launch at login, quit

## Notes

Temperature and power come from undocumented SMC keys and the private
`IOHIDEventSystemClient` API. Both are what every tool in this category uses and
neither needs entitlements, but they rule out the Mac App Store and may shift
between major macOS releases. Missing sensors degrade to hidden rather than
crashing.

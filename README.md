# Ice Cube

[![CI](https://github.com/thijsvos/icecube/actions/workflows/ci.yml/badge.svg)](https://github.com/thijsvos/icecube/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)
![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-black)

An open-source menu-bar fan controller and thermal monitor for **Apple Silicon
MacBooks**. Live stacked temperature/RPM charts, a draggable fan-curve editor,
one-click presets — built on a hardened privilege split: the app only ever
*reads* sensors, while a tiny root helper daemon owns every fan write and
enforces safety limits the UI cannot override. **Zero third-party
dependencies**; small footprint is a design goal, not an accident.

> **Status: beta.** Fully functional — monitoring, manual control, curves,
> presets, boot persistence — developed and tested on a MacBook Pro 14" M2 Pro
> (Mac14,9) under macOS 26. Other Apple Silicon Macs should work for
> monitoring out of the box; fan-control write paths for M3/M4 (`Ftst`
> unlock) and M5 are implemented from community research but unverified —
> reports welcome (see below).

## Features

| Feature | |
| --- | --- |
| Menu-bar popover with live stacked charts (CPU, GPU, per-fan RPM) | ✅ |
| 1/5/15/60-min windows, pause, hover crosshair, min/avg/max | ✅ |
| Fan-curve editor: drag points, double-click add, keyboard nudge, live marker | ✅ |
| Presets: Quiet · Balanced · Cold · Max + your own (plus “macOS”, which hands the fans back) | ✅ |
| Manual per-fan sliders (watchdogged, never persisted) | ✅ |
| Curve keeps running at boot, app closed — daemon-side | ✅ |
| Sensors browser (every SMC key, live) + JSON diagnostics export | ✅ |
| CSV history export, temperature alerts, launch at login, °C/°F | ✅ |
| Update check via GitHub Releases (link only, never auto-install) | ✅ |

## Safety design

Fan control can cook a machine when done carelessly. Ice Cube's rules are
enforced **in the root daemon**, where the UI (or a bug in it) cannot reach:

- Every RPM write is clamped to the fan's firmware-reported safe range — and
  because Apple Silicon firmware treats those limits as *advisory* (it will
  happily accept 0 RPM), the daemon's clamp is the real guard. A 0-RPM target
  is never written, not even while releasing control.
- A temperature ceiling (die 104 °C / others 95 °C, debounced) overrides any
  user setting with maximum cooling until things cool down.
- Manual mode is always watchdogged: if the app stops heartbeating for 15 s,
  fans revert to automatic. Only curve mode may run app-less, and only when
  you opt in.
- Every write is verified by read-back and audit-logged (`log stream
  --predicate 'subsystem == "io.github.thijsvos.icecube"'`).
- **The guardian**: we found during development that macOS 26 does not
  reliably resume fan management after *any* fan app releases control (fans
  can sit stopped while the die climbs past 90 °C). Ice Cube therefore never
  assumes macOS took the wheel back: if the machine is warm and nothing is
  cooling it, the daemon drives the fans itself along a built-in curve and
  hands back only when it's genuinely cool.

## Why a root helper?

Writing fan speeds on Apple Silicon requires root — that's firmware-enforced,
not a choice. Ice Cube keeps that surface tiny: a single daemon (registered via
`SMAppService`, approved once by you in System Settings) that speaks a
five-method XPC protocol, pinned to the app's code signature in both
directions. The app itself contains **no fan-write code at all**.

## Install

Ice Cube is not in the App Store (sandboxed apps cannot touch the SMC).

**Building from source is the recommended path, and currently the only one
that gives you fan control.** Prebuilt archives on the
[Releases](https://github.com/thijsvos/icecube/releases) page are unsigned
until the project moves to a paid Apple Developer account: macOS will quarantine
them, and — more importantly — the root helper will only register on a Mac that
trusts the identity that signed it, which in practice is the machine that built
it. Downloaded builds therefore give you **monitoring only**. Building from
source signs with your own Apple ID (a free one works) and everything runs.

```bash
git clone https://github.com/thijsvos/icecube && cd icecube
brew bundle              # xcodegen + swiftformat
xcodegen generate
sh scripts/set-team.sh YOURTEAMID   # your Apple Development team (free ID works)
sh scripts/install-debug.sh          # builds, installs to /Applications, launches
```

### First run

Ice Cube opens a short setup window by itself and walks you through the one
permission it needs. It watches for your approval and moves on as soon as you
give it — no restarting, no hunting through menus. If the app isn't in your
Applications folder yet, it offers to move itself there first.

**Monitoring works immediately without any of this.** The permission is only
for *changing* fan speeds, and you can skip it and turn it on later from the
Ice Cube menu.

Behind the scenes that permission registers a small background service
(`SMAppService`), which macOS requires you to approve once under System
Settings → General → Login Items & Extensions. That's an Apple rule, not an
Ice Cube one — the setup flow just makes it a single button instead of a
scavenger hunt.

## Uninstall

1. Ice Cube popover → Settings… → Fan Control Setup → **Turn Off Fan Control**
   (hands the fans back to macOS and removes the background service).
2. Quit Ice Cube, delete `/Applications/Ice Cube.app`.
3. Optional leftovers: `~/Library/Application Support/IceCube` (your presets)
   and `sudo rm -rf "/Library/Application Support/IceCube"` (the daemon's
   persisted config).

## Supporting a new Mac model

Temperature-sensor keys change with every Apple SoC generation. If your model
shows few or oddly-labeled sensors: popover → **Sensors…** → **Export
Diagnostics…**, then open a "New Mac model report" issue with the JSON
attached. That file is exactly what's needed to add a curated mapping.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The short version: `swift test` must
stay green, SwiftFormat clean, the safety invariants are non-negotiable, and
everything must work in simulated mode (`ICECUBE_SIMULATED=1`) — CI has no
fans.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Apple. Use at your own
risk; the safety systems are engineered carefully, but you are pointing
software at your own hardware.

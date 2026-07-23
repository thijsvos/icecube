# Zephyr

Zephyr is an open-source menu-bar app for fan control and thermal monitoring on
Apple Silicon MacBooks. It aims to combine live stacked temperature/RPM charts, a
draggable fan-curve editor, and presets with a hardened privilege split: the app
only ever *reads* sensors, while a tiny root helper daemon owns every fan write
and enforces safety limits that the UI cannot override. Zero third-party
dependencies; small footprint is a core goal.

## Status: pre-alpha (Phase 0)

**This does not control fans yet.** The current scaffold runs entirely on
simulated data — a mock SMC provider feeding the menu-bar UI. Real sensor reads,
the helper daemon, and actual fan control land in later phases. Do not expect
anything useful as an end user yet.

## Planned features

| Feature | Status |
| --- | --- |
| Menu-bar popover with live temp + fan RPM charts | in progress (simulated data) |
| Fan-curve editor (draggable points, hysteresis, per-fan or linked) | planned |
| Presets: Auto / Quiet / Balanced / Max / Custom | planned |
| Manual fan speed (watchdogged, never persisted) | planned |
| Curve keeps running at boot, without the app open | planned |
| Sensors browser + diagnostics export (to support new Mac models) | planned |
| History with CSV export, notifications, launch at login | planned |
| Update check via GitHub Releases (link only, no auto-install) | planned |

## Safety

Safety is a headline feature, enforced in the daemon where the UI cannot reach
it. All fan writes happen daemon-side and are clamped to each fan's
firmware-reported `[min, max]` range — firmware treats those limits as advisory
(it can accept 0 RPM), so our clamp is *the* guard, not belt-and-braces. A
temperature ceiling overrides any user curve: if monitored sensors cross it, the
daemon forces cooling regardless of configuration. Manual (fixed-RPM) mode is
always covered by a 15-second heartbeat watchdog and is never persisted — if the
app disappears, fans revert to system automatic control. Every write is verified
by read-back and audit-logged.

## Why a root helper?

Writing SMC fan keys on Apple Silicon is firmware-restricted to root;
unprivileged writes fail, while sensor *reads* need no privileges at all. So the
app stays unprivileged and a minimal LaunchDaemon (installed via `SMAppService`,
approved by you in System Settings) is the only component that can write — it
clamps, verifies, and logs every command the app sends it over XPC.

## Building

Requires macOS 14+, Xcode 26.6, and Homebrew. The Xcode project is generated
from `project.yml` — never edit build settings in the Xcode GUI.

```sh
brew bundle                # installs xcodegen + swiftformat
xcodegen generate          # creates the gitignored Zephyr.xcodeproj
xcodebuild -project Zephyr.xcodeproj -scheme Zephyr -configuration Debug \
  -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
(cd ZephyrKit && swift test)
sh scripts/verify-bundle.sh

# Run with simulated data (no hardware access):
ZEPHYR_SIMULATED=1 build/Build/Products/Debug/Zephyr.app/Contents/MacOS/Zephyr
```

To build signed (needed later for the real helper), write your team ID once with
`scripts/set-team.sh <TEAM_ID>` — it lands in the gitignored
`Configs/Local.xcconfig`.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.

## Non-goals

- **Intel fan control.** v1 is Apple-Silicon-only. The `SMCProviding` seam is
  kept clean so the community can port the Intel write path — contributions
  welcome.
- **Overclocking / voltage / power limits.** macOS does not expose this;
  "fan curves like Afterburner" means the monitoring and curves, not the OC panel.
- **Mac App Store.** SMC writes and a root daemon are incompatible with the App
  Sandbox. Distribution will be notarized GitHub releases.

## License

MIT — see [LICENSE](LICENSE).

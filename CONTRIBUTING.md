# Contributing to Ice Cube

Thanks for helping! Ice Cube is small on purpose — the bar for merging is
"keeps the machine safe, keeps the code readable, keeps the footprint small."

## Setup

```bash
brew bundle          # xcodegen + swiftformat
xcodegen generate    # the .xcodeproj is generated and gitignored
```

- **Never edit build settings, schemes, or file membership in the Xcode GUI**
  — they are wiped on regeneration. Edit `project.yml` and re-run
  `xcodegen generate`. Your signing team lives only in the gitignored
  `Configs/Local.xcconfig` (`scripts/set-team.sh`).
- UI work needs no hardware or root: run the **"Ice Cube (Simulated)"** scheme.
  Every feature must be demonstrable in simulated mode.

## Development loop

```bash
xcodebuild -project IceCube.xcodeproj -scheme IceCube -configuration Debug \
  -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
(cd IceCubeKit && swift test)      # the fortress — must stay green
swiftformat --lint .              # must be clean
sh scripts/verify-bundle.sh       # bundle layout sanity
```

Helper-daemon changes additionally need `sh scripts/install-debug.sh` and a
**Re-register** from the app's Settings (launchd keeps running the old binary
otherwise — the #1 "why isn't my change live" trap).

## Rules that are not up for debate

1. **The safety invariants** (watchdog, clamping, temperature ceiling,
   read-back verification, revert-on-everything, the guardian). PRs that
   weaken them are closed, kindly but firmly.
2. The app process must contain **no SMC write path**. Writes live in
   `IceCubeHelper/` only.
3. **No third-party dependencies.** None.
4. Testable logic goes in **IceCubeKit** with tests. The write sequencer and
   SafetyMonitor changes need tests against the fake firmwares.
5. No GPL-derived code. MIT references (Stats, SMCKit, macos-smc-fan) may
   inform an approach — attribute in `docs/CREDITS.md`, write our own code.

## Style

Swift 6, strict concurrency. SwiftFormat (config in repo) settles formatting
arguments. Every file starts with a one-line "what this is" comment; public
API gets doc comments; files stay under ~300 lines. UI follows the anti-jump
rule: nothing may resize, reflow, or flicker on its own.

## Adding support for a new Mac model

The curated sensor maps live in `IceCubeKit/Sources/IceCubeKit/SMC/SMCKeyMaps.swift`.
Take a diagnostics JSON (Sensors… → Export Diagnostics…), identify the
die/GPU/battery keys, add a generation entry + tests, and include the JSON in
the PR. Fan-control write paths for untested generations (M3/M4/M5) ship
flagged experimental until a hardware report confirms them.

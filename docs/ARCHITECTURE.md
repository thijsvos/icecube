# Ice Cube architecture

A short orientation for contributors. The roadmap and full technical detail live
in [PLAN.md](../PLAN.md).

## The three components

```
IceCube.xcodeproj
├── Ice Cube            SwiftUI app: MenuBarExtra UI, charts, curve editor,
│                     settings, read-only SMC polling for display
├── IceCubeHelper      Root LaunchDaemon (SMAppService): owns ALL SMC writes,
│                     runs the fan-curve control loop, enforces safety
└── IceCubeKit         Local Swift package (no UI, no root): SMC key parsing,
                      encodings, curve math, models, XPC protocol, mock provider
                      → this is where unit tests live
```

The app never writes to the SMC. It sends the desired curve/preset over XPC
(mach service `io.github.thijsvos.icecube.helper.xpc`); the daemon runs the
control loop so curves keep working even when the app is closed.

## Why reads are unprivileged and writes are root-side

SMC temperature and fan *reads* need no privileges — the app polls them directly
for smooth 1 Hz charts. Fan *writes* are firmware-restricted to root on Apple
Silicon, so they live exclusively in IceCubeHelper, a LaunchDaemon registered via
`SMAppService` and approved by the user in System Settings. This keeps the
privileged surface tiny and auditable: the daemon accepts only a narrow,
codesign-pinned XPC protocol, and no XPC method exists that can weaken safety.

## The SMCProviding seam and simulated mode

All hardware access in the app goes through the read-only `SMCProviding`
protocol (`IceCubeKit/Sources/IceCubeKit/SMCProviding.swift`). Two implementations:
`MockSMCProvider` (thermal simulation — the default in CI and whenever
`ICECUBE_SIMULATED=1` or `--simulated` is set, and all Phase 0 runs) and
`SystemSMCProvider` (real IOKit reads, Phase 1). The committed
"Ice Cube (Simulated)" scheme runs the app on mock data with zero hardware access.
The seam also keeps v1 honest about scope: Apple-Silicon-only, with the protocol
clean enough for a community Intel port.

## Safety invariants (daemon-enforced)

- Every RPM target is clamped to the fan's firmware-reported `[F{i}Mn, F{i}Mx]`.
  Firmware treats these as advisory (0 RPM can be accepted) — our clamp is THE
  guard, including never-0-RPM.
- Temperature ceiling with debounce: sustained over-threshold forces cooling
  regardless of the user's configuration.
- Manual (fixed-RPM) mode is always watchdogged by a 15 s app heartbeat and is
  never persisted; only curve mode may run without the app.
- Revert-to-auto on: daemon start without a valid persisted config, XPC
  invalidation, SIGTERM, repeated sensor-read failure, wake-reassert failure.
- Every write is read-back-verified and audit-logged (key, value, reason).

## XcodeGen workflow

`IceCube.xcodeproj` is generated and gitignored. Edit `project.yml`, then run
`xcodegen generate` — never change settings, schemes, or file membership in the
Xcode GUI, because regeneration wipes those edits. Machine-specific signing
(DEVELOPMENT_TEAM) lives only in the gitignored `Configs/Local.xcconfig`
(written by `scripts/set-team.sh`); CI has no such file and builds unsigned.
`scripts/verify-bundle.sh` asserts the helper binary and launchd plist land at
the exact bundle paths SMAppService needs.

## Where to go next

- [PLAN.md](../PLAN.md) — the phased roadmap and SMC technical reference.
- [CLAUDE.md](../CLAUDE.md) — ground rules for contributors and coding agents.
- [XCODE_GUIDE.md](../XCODE_GUIDE.md) — the human-only Xcode/signing steps.

## Phase 4–5 additions (2026-07-23)

- **Curve pipeline**: `FanCurve` (normalized, monotone) + `CurveFollower`
  (hysteresis + ramp) in IceCubeKit; the daemon's control loop evaluates the
  hottest die sensor per 2 s tick and writes quantized targets with read-back
  verification. Persistent curve configs live root-owned at
  `/Library/Application Support/IceCube/config.json` and resume at boot.
- **The guardian**: in auto mode the daemon watches for "warm machine,
  nothing cooling" (macOS 26 does not reliably resume fan management after a
  fan app releases control — field-verified) and drives the fans itself along
  a built-in curve until things are genuinely cool.
- **App-side stores**: presets (`~/Library/Application Support/IceCube/
  presets.json`), settings (UserDefaults), chart history (60 min ring
  buffers, CSV-exportable), update checker (GitHub releases/latest).

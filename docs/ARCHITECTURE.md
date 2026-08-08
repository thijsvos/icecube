# Ice Cube architecture

A short orientation for contributors. The roadmap and full technical detail live
in [PLAN.md](../PLAN.md).

## The three components

```
IceCube.xcodeproj
├── Ice Cube            SwiftUI app: MenuBarExtra UI, charts, curve editor,
│                     settings, read-only SMC polling for display
├── IceCubeHelper      Root LaunchDaemon (SMAppService). The XPC listener, the
│                     root-owned config store, and the three files in the whole
│                     project that touch raw IOKit: SMCWritePort (the only SMC
│                     writer that exists), SystemPowerWatcher (sleep/wake
│                     notifications), SystemCapabilityReader (is a display
│                     lit?). Deliberately thin — policy lives in IceCubeKit.
└── IceCubeKit         Local Swift package (no UI, no root): SMC key parsing,
                      encodings, curve math, models, XPC protocol, mock
                      provider, read-only SMC access (SMCConnection /
                      SystemSMCProvider — reads need no root, and there is
                      deliberately no write method), AND the daemon's brain:
                      DaemonCore, SafetyMonitor, FanGuardian, SleepLatch,
                      FanWriteSequencer, which reach hardware only through the
                      SMCControlPort protocol. Plus the icecube-diag CLI.
                      → this is where unit tests live
```

The app never writes to the SMC. It sends the desired curve/preset over XPC
(mach service `io.github.thijsvos.icecube.helper.xpc`); the daemon runs the
control loop so curves keep working even when the app is closed.

The daemon's *logic* lives in IceCubeKit, which the app links, for a blunt
reason: a command-line-tool target cannot be unit-tested, and safety code that
cannot be tested is safety code that silently rots. `DaemonCore` takes an
`SMCControlPort` and a `FanConfigStoring`, so the watchdog, the ceiling, the
sleep latch and the revert/engage race guards are all exercised against a
scripted fake firmware. The *capability* boundary is unchanged, and is now
enforced by a symbol check rather than by where the files sit — see below.

## Why reads are unprivileged and writes are root-side

SMC temperature and fan *reads* need no privileges — the app polls them directly
for smooth 1 Hz charts. Fan *writes* are firmware-restricted to root on Apple
Silicon, so they live exclusively in IceCubeHelper, a LaunchDaemon registered via
`SMAppService` and approved by the user in System Settings. This keeps the
privileged surface tiny and auditable: the daemon accepts only a narrow,
codesign-pinned XPC protocol, and no XPC method exists that can weaken safety.

Three things are helper-only, and each is one careless `import` away from
silently ceasing to be:

- **`SMCWritePort`** — the only SMC writer in the system.
- **`SystemPowerWatcher`** — the pre-sleep hand-back writes fans, so its
  trigger belongs to the helper alone.
- **`SystemCapabilityReader`** — raw IOKit; the pure half the app may link is
  `PowerCapabilities` in IceCubeKit.

`scripts/verify-bundle.sh` asserts all three with `nm`, in both directions: the
app binary must contain none of them, and the helper must contain all of them —
a helper without a writer means fan control is dead, without a power watcher the
fans run through sleep, and without a capability reader every unpark falls back
to "cannot tell", which never proves a full wake, so the daemon sits parked
until the failsafe with the user's curve silently inert. This check is not
belt-and-braces: since `DaemonCore` moved into IceCubeKit, layout alone no
longer proves anything, and this *is* the guarantee.

## The SMCProviding seam and simulated mode

All hardware access in the app goes through the read-only `SMCProviding`
protocol (`IceCubeKit/Sources/IceCubeKit/SMCProviding.swift`). Two implementations:
`MockSMCProvider` (thermal simulation — the default in CI and whenever
`ICECUBE_SIMULATED=1` or `--simulated` is set, and all Phase 0 runs) and
`SystemSMCProvider` (real IOKit reads, Phase 1). The committed
"Ice Cube (Simulated)" scheme runs the app on mock data with zero hardware access.
The protocol answers two different questions about sensors, and keeping them
apart is now load-bearing across the app. `temperatures()` is **what is
reporting** — sensors that have produced a usable reading this process.
`sensorInventory()` is **what the Mac has** — stable from the first poll,
independent of what any cluster is doing at this instant. Anything that sizes
itself uses the inventory (the popover list, the Sensors window); anything that
displays a number uses the readings. Sizing to the reporting set would grow the
popover 192 pt under the user's cursor as gated clusters wake up.

The seam also keeps v1 honest about scope: Apple-Silicon-only, with the protocol
clean enough for a community Intel port.

## Sensor discovery is decided by existence, not by a reading

Membership in the sensor list is a property of the Mac, so it is decided from
the one signal that does not change between two runs: whether the firmware knows
the key. It is never decided from a value.

The old rule admitted a curated sensor only if its first read looked plausible,
and on Apple Silicon that is a coin flip. A power-gated CPU cluster does not
fail a read — it returns a frozen firmware sentinel, measured on Mac14,9 as
exactly 6.70 °C and 4.63 °C, applied to a whole cluster at a time. Idle, the
P-cluster is gated at 66.9 % of instants and the E-cluster at 21.8 %, so ten
`icecube-diag` runs resolved 8, 12, 16 or 20 of 20 sensors depending on the
millisecond they happened to start. Retrying does not help: a gated key does not
refresh at all, and immediate, +5 ms and +50 ms retries recovered 0 of 18
misses. The two conditions do separate cleanly, and that is what makes existence
safe to trust — an absent key **throws** every time, a gated one never does.
Verified 20/20 across runs.

Both sides do this, in the same way and for the same reason:

- **App** — `IceCubeKit/…/SMC/SensorAdmission.swift`, a pure function over probe
  results so the rule is testable outside `SystemSMCProvider`.
- **Daemon** — via a `readDouble` **whose value is discarded**: the error
  answers both questions. Deliberately not `port.hasKey`, which collapses "no
  such key" into the same `false` as a transport failure. This one is
  safety-relevant — the daemon logged `resolved 8 temperature sensors` and ran
  on that set for thirteen hours, its only silicon input the two GPU dies, while
  the 104 °C die ceiling is the one release allowed to spin fans in a closed bag.

Plausibility keeps its old job on the **value** path, where a sentinel still
cannot reach a curve, a chart or the ceiling. One consequence is worth knowing:
the published list is **monotone** — it grows as gated clusters wake, and never
shrinks or reorders.

## Safety invariants (daemon-enforced)

- Every RPM target is clamped to the fan's firmware-reported `[F{i}Mn, F{i}Mx]`.
  Firmware treats these as advisory (0 RPM can be accepted) — our clamp is THE
  guard, including never-0-RPM.
- Temperature ceiling with debounce, per sensor class: sustained over-threshold
  forces cooling regardless of the user's configuration. It is also the one rule
  that stays armed while the machine is parked for sleep — the only fan noise a
  closed bag is allowed to make.
- Manual (fixed-RPM) mode is always watchdogged by a 15 s app heartbeat and is
  never persisted; only curve mode may run without the app.
- Revert-to-auto on: daemon start without a valid persisted config, XPC
  invalidation, SIGTERM, repeated sensor-read failure, wake-reassert failure.
- The fans are **parked** — handed back to the firmware — on
  `kIOMessageSystemWillSleep`, and nothing is written to a fan again until the
  machine is proven awake. `F{i}Md = 1` survives sleep on Apple Silicon, so
  without this the fans run forced for the entire closed-lid window.
- A **dark wake is not a wake**. The latch drops only on a positive
  `PowerCapabilities` read showing a display is powered — not on a heartbeat,
  not on elapsed time. A heartbeat *can* arrive during a dark wake; assuming it
  could not drove both fans to 6800 RPM for 69 s inside a closed laptop. Keyed
  on "a display is lit" rather than lid state, so a clamshell Mac driving an
  external display keeps full fan control.
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
  buffers, CSV-exportable), update checker (GitHub releases/latest), and —
  since 2026-08-08 — cooling history (`cooling-history.json` beside the
  presets: settled °C/W readings per fan-speed band, raw for a week, day
  summaries for two years, fingerprinted to this Mac by a salted serial
  hash so Migration Assistant cannot transplant a baseline; the policy —
  recorder gates, retention, the trend verdict — lives in
  `IceCubeKit/History/`, the app owns only the file. A simulated launch is
  redirected to a temp sandbox and seeded with fabricated months so the
  trend UI stays demonstrable; asserted in `SimulatedIsolationTests` and
  re-checked at runtime by CI's smoke test).

# CLAUDE.md — Project Ice Cube

Ice Cube (name decided 2026-07-23; identifiers frozen at first public release) is an **open-source macOS menu bar app for fan control and thermal monitoring**: live graphs in the style of MSI Afterburner's hardware monitor, custom temperature→fan curves, presets, and a privileged helper daemon that performs the actual SMC writes.

Read **PLAN.md** for the full roadmap and technical reference. **XCODE_GUIDE.md** contains steps only the human can do (signing, approvals, notarization) — when a task requires one of those, stop and tell the owner exactly which section of that guide to follow.

## Owner profile (tailor everything to this)

- Test machine: **M2 Pro MacBook Pro (Mac14,9).** v1 is **Apple-Silicon-only**; the Intel write path is a non-goal left to the community (keep `SMCProviding` clean so a port stays possible). When a decision trades off between architectures, favor Apple Silicon.
- **Free Apple ID** (personal team). Local dev signing and helper approval work; **no notarization or Developer ID** until the owner upgrades. Phase 6 public release is gated on that — don't build release automation before it's unblocked.
- Apple Development cert expires **2026-08-15** (auto-renews). Sudden XPC code-signing/pinning failures near that date = cert renewal, not a code bug.
- Owner is **brand new to Swift and Xcode.** Do everything you can from the CLI yourself. When the owner must act in Xcode or System Settings, give exact click-by-click steps and cite the XCODE_GUIDE.md section number. Explain jargon on first use. Never assume they know where a panel is.

## Ground rules

1. Work milestone by milestone in PLAN.md §5 order. Do not start Phase N+1 until Phase N acceptance criteria pass.
2. **All hardware access goes through the `SMCProviding` protocol.** Never call IOKit directly from UI or feature code.
3. **Simulated mode must always work.** `ICECUBE_SIMULATED=1` (env var or `--simulated` launch arg) swaps in `MockSMCProvider`. Every feature must be demonstrable in simulated mode with no root, no helper, no real SMC. CI runs simulated only.
4. **Safety invariants are non-negotiable.** Never remove, weaken, or bypass:
   - Daemon-side watchdog: no app heartbeat for 15 s **and** config does not persist without app → revert to auto. Manual (fixed-RPM) mode is **always** watchdogged regardless of the persist toggle — only curve mode may run app-less.
   - Daemon reverts to auto on XPC invalidation, on its own shutdown, and on start — **unless** a valid persisted curve config loads, which it resumes instead (the Phase 4 boot promise, PLAN.md §4.3.3).
   - Temperature ceiling: **per sensor class**, with an N-tick debounce so one glitched reading can't slam the fans — die sensors 104 °C, everything else 95 °C (`SafetyMonitor.Limits`, PLAN.md §4.3.2). Over ceiling → daemon forces max fans regardless of user curve, releasing only 5 °C below. Die sensors legitimately run 95–105 °C under load, which is why they are not held to the 95 °C bar.
   - All RPM writes clamped to the SMC-reported `[F{i}Mn, F{i}Mx]` range for that fan.
   - `F{i}Mn`/`F{i}Mx` are **advisory** in firmware (0 RPM can be accepted) — the daemon clamp is the only real guard.
   - On system wake, re-verify and re-assert or revert (firmware silently resets manual control across sleep).
   - **Manual mode is never the persisted default** — no app launch may put the fans under fixed-RPM control on its own. (`StartupPolicy` can only ever produce a curve; unit-tested.)
   - A user who has never chosen a mode starts in the **Balanced curve** (owner decision, 2026-07-25). macOS's own policy — let it get hot, then spin hard — is what people install this app to avoid.
   - **Auto is not user-selectable** (owner decision, 2026-07-26). The "macOS" preset and the "Hand Back to macOS" button are both gone: nobody installs a fan-control app to stop controlling their fans, and on Mac14,9 the hand-back did not work anyway (macOS left the fans parked while the die climbed past 90 °C). `FanConfig.Mode.auto` survives as the daemon's resting state and the target of every safety revert; the honest exit is Settings → "Turn Off Fan Control", which removes the daemon. This supersedes the earlier rule that an explicit Auto choice is honoured forever — `StartupPolicy.Preference.automatic` no longer exists, so a stored one fails to decode and lands on the fallback curve.
5. Never modify code-signing settings, team IDs, or entitlements without asking. Never commit certificates, notary credentials, or private keys. Never run `sudo`, installers, or `sfltool` yourself — hand those commands to the owner.
6. Don't copy code from GPL projects (smcFanControl). MIT-licensed references (Stats, SMCKit, agoodkind/macos-smc-fan) may inform the approach; write our own implementation and attribute inspirations in `docs/CREDITS.md`.
7. **The Xcode project is GENERATED**: edit `project.yml` and run `xcodegen generate` — never change build settings, schemes, or file membership in the Xcode GUI (wiped on regeneration). The signing team lives only in gitignored `Configs/Local.xcconfig`.

## Architecture (see PLAN.md §2–4 for detail)

```
IceCube.xcodeproj
├── Ice Cube            SwiftUI app: MenuBarExtra UI, charts, curve editor,
│                     settings, read-only SMC polling for display
├── IceCubeHelper      Root LaunchDaemon (SMAppService). Holds the ONLY SMC
│                     writer (SMCWritePort — raw IOKit, never linked into the
│                     app), the XPC listener, and the root-owned ConfigStore.
│                     Deliberately thin: policy lives in IceCubeKit.
└── IceCubeKit         Local Swift package (no UI, no root): SMC key parsing,
                      encodings, curve math, models, XPC protocol, mock provider,
                      read-only SMC access (SMCConnection/SystemSMCProvider —
                      reads need no root; there is deliberately NO write method),
                      AND the daemon's brain — DaemonCore, SafetyMonitor,
                      FanGuardian, FanWriteSequencer — which drive hardware only
                      through the `SMCControlPort` protocol
                      plus the `icecube-diag` CLI (swift run icecube-diag)
                      → this is where unit tests live
```

The app never writes to the SMC. It sends the desired curve/preset over XPC; the daemon runs the control loop (~2 s tick) so curves keep working even if the app quits (user-configurable).

**Why the daemon's logic lives in IceCubeKit, not IceCubeHelper:** a command-line tool target cannot be unit-tested, and safety code that cannot be tested is safety code that silently rots. `DaemonCore` takes `any SMCControlPort` + `any FanConfigStoring`, so every invariant (watchdog, ceiling, revert-on-invalidation, wake re-assert, the revert/engage race guards) is exercised against a scripted fake firmware in `DaemonCoreTests`. The *capability* boundary is unchanged and still enforced: only `IceCubeHelper` contains a concrete writer, so the app binary has no way to write the SMC even though it links the orchestration code. Verify with `nm -a "…/Ice Cube.app/Contents/MacOS/Ice Cube" | grep -c SMCWritePort` → must be 0.

## Build & test commands

```bash
# Regenerate the (gitignored) Xcode project from project.yml — always run first
xcodegen generate

# App (Debug, unsigned-friendly for CI)
xcodebuild -project IceCube.xcodeproj -scheme IceCube -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO

# Unit tests (IceCubeKit — pure Swift, no signing, no hardware)
cd IceCubeKit && swift test

# Run app in simulated mode from CLI after building
ICECUBE_SIMULATED=1 "./build/Build/Products/Debug/Ice Cube.app/Contents/MacOS/Ice Cube"

# Lint/format (once configured in Phase 0)
swiftformat --lint .
```

If a build needs signing (running the real helper), tell the owner to do it in Xcode per XCODE_GUIDE.md §4 — don't fight signing from the CLI.

## Code conventions

- Swift 6 language mode (strict concurrency), macOS 14.0 deployment target.
- SwiftUI + `@Observable` for app state; `@MainActor` for anything touching UI.
- Default isolation: app target uses **MainActor default isolation**; IceCubeHelper + IceCubeKit use **nonisolated default**.
- `HelperProtocol` reply closures are `@escaping @Sendable`.
- Actors for polling/IO (`SMCPoller` in the app, `SMCWritePort` in the daemon); models are `Sendable` value types.
- **No third-party dependencies. Period.** (Sparkle dropped — Phase 6 uses a hand-rolled GitHub Releases version check.) Foundation/AppKit/SwiftUI/Charts only.
- Errors: typed `IceCubeError` enum in IceCubeKit; never `fatalError` in daemon code paths.
- Every SMC call checks the firmware result byte (`SMCResult`), not just `kern_return_t`.
- Bundle ids: app `io.github.thijsvos.icecube`, helper `io.github.thijsvos.icecube.helper`, mach service `io.github.thijsvos.icecube.helper.xpc`.
- Logging: `os.Logger`, subsystem `io.github.thijsvos.icecube`, categories `smc`, `xpc`, `curve`, `ui`. Daemon logs must make every write auditable (key, value, reason).
- File header comment on new files: one line saying what the file is for. Keep files under ~300 lines; split by feature.

## Definition of done (every task)

Builds clean with no new warnings → `swift test` passes → feature works in simulated mode → safety invariants untouched → PLAN.md checkbox ticked with a one-line note if implementation deviated from plan.

**"No new warnings" is enforced, not aspirational.** CI compiles with
`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` (xcodebuild) and `-Xswiftc -warnings-as-errors`
(`swift test`), so a warning fails the build. It is deliberately *not* set in
`project.yml`: a local build still tolerates the half-finished code you get mid-edit, and
the gate is on what lands rather than on how you get there. Check locally before pushing by
appending those flags to the commands above.

When a macOS SDK deprecation fails CI on a PR that did not cause it, fix the deprecation —
do not delete the flag.

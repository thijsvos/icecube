# Ice Cube — Implementation Plan

A beautiful, open-source macOS menu bar fan controller and thermal monitor. Real-time stacked graphs in the spirit of MSI Afterburner's hardware monitor, a draggable fan-curve editor, presets, and a hardened root helper that does the actual writing — with safety guardrails everywhere.

This document is the single source of truth for Claude Code. Companion docs: `CLAUDE.md` (rules + commands), `XCODE_GUIDE.md` (human-only steps).

---

## 0. Vision, scope, non-goals

**Vision.** The fan app people screenshot: gorgeous dark dashboard, buttery live charts, a curve editor that feels like a pro tool, and trustworthy behavior (never leaves your Mac cooking). Three pillars sit alongside the looks: **small footprint** (a menu-bar app should be nearly invisible in Activity Monitor), **zero third-party dependencies** (everything hand-rolled or vendored — the whole codebase auditable in an afternoon), and **safety as a headline feature** (all SMC writes daemon-side, clamped, watchdogged, read-back-verified — see §4.3).

**Scope.** Fan monitoring + control and temperature monitoring on **Apple Silicon** Macs, via the SMC (System Management Controller). v1 is Apple-Silicon-only.

**Non-goals (be explicit in the README too):**
- No Intel support in v1. The Intel write path (`FS! ` + fpe2) is out of scope entirely — community port welcome; `SMCProviding` stays hardware-agnostic so an Intel provider can slot in later without touching the rest of the app.
- No GPU/CPU overclocking, voltage, or power-limit control — macOS does not expose this. "Like Afterburner" means the *monitoring graphs and fan curves*, not the OC panel.
- No Mac App Store distribution. SMC writes + a root daemon are incompatible with the App Sandbox. Distribution is notarized GitHub releases.
- No Windows/Linux, no iOS.
- No kernel extensions. Everything is userspace IOKit + a LaunchDaemon.
- No third-party dependencies — not even Sparkle. Updates are a tiny hand-rolled GitHub Releases version check, link-only (§5 Phase 6).

---

## 1. Feature specification

### 1.1 Menu bar
- `MenuBarExtra` with `.window` style (rich popover, not a plain menu).
- Configurable status item: fan glyph, current max temp, fan RPM, or compact "temp + RPM" text; option to show the hottest sensor's value; monochrome template icon that respects light/dark.
- Left-click opens dashboard popover; ⌥-click quick-switches preset (stretch). **Reality check:** click interception is not achievable in pure `MenuBarExtra` — there is no first-party API (FB11984872). Cheap v1 variant: read `NSEvent.modifierFlags` when the popover opens (popover still appears, already switched). The full no-popover variant needs a small **vendored** AppKit status-item shim (~100 lines we write and own — still zero dependencies).

### 1.2 Dashboard popover (the Afterburner moment)
- Header: current preset, per-fan RPM (actual → target), hottest sensor badge.
- **Stacked live charts** (Swift Charts): one row per metric group — CPU temp(s), GPU/SoC temp(s), each fan's RPM. Area-gradient fill, per-series accent colors, 1 s sampling, selectable window (1 / 5 / 15 / 60 min), pause button, crosshair value readout on hover (`chartOverlay`), min/avg/max in each row's header.
- **Downsampling is a hard requirement, not a nicety** (Phase 2): ≤ ~600 visible points per series (min-max or LTTB, computed in `ChartStore` off the main actor). The 60-min window at 1 s is 3600/series ≈ 21.6K points across ~6 series — squarely in Swift Charts' documented degradation zone. No implicit animations on live marks; hover/crosshair state scoped per chart row so one crosshair doesn't invalidate every row.
- Quick controls: preset picker (Auto / Quiet / Balanced / Max / Custom…), per-fan manual slider when in Manual mode (with a visible "manual mode" warning tint).
- "Open Ice Cube" button → full window. **Reality check:** programmatic popover dismissal has no first-party API (FB11984872), and window focus from an LSUIElement app needs `NSApp.activate(ignoringOtherApps: true)` (plus an activation-policy flip to `.regular` if needed, reverting to `.accessory` on last window close). Encapsulate the whole timing-sensitive dance in one `WindowOpener` type — never cargo-culted around the codebase.

### 1.3 Main window
- **Curve editor**: temperature (x, 30–110 °C) vs fan output (y, % of that fan's max RPM). 3–8 draggable control points, add/remove by double-click, monotonic-x enforcement, live preview line of "where we'd be right now." Per-fan curves or linked-all mode. Parameters: input sensor (Max of all / CPU / GPU / pick-list), hysteresis (°C), ramp smoothing (max ΔRPM per second). **Implementation note:** plain SwiftUI `Canvas` + draggable handle circles, NOT Swift Charts — hit-testing handles and enforcing monotonic-x is simpler without ChartProxy round-trips; Swift Charts stays display-only.
- **History**: session charts with longer retention (ring buffer, ~4 h at 2 s), CSV export.
- **Sensors browser**: every discovered SMC key with live value — doubles as the community "diagnostics report" for supporting new Mac models (export as JSON, ties into GitHub issue template).
- **Settings**: launch at login (`SMAppService.mainApp`), sampling intervals, °C/°F, menu bar display, "keep curve running when app quits" toggle (curve mode only — manual mode is always watchdogged, §4.3.1), temp-alert notification thresholds (UserNotifications), check-for-updates (hand-rolled GitHub Releases version check, link-only — Phase 6).
- Onboarding sheet on first run: what the helper is, why it needs admin approval, the safety guarantees, link to source.

### 1.4 Behaviors that make it feel "modern & trustworthy"
- Watchdog + auto-revert everywhere (see §4.3). Quitting the app (by default) hands the fans back — but on a machine above 45 °C the daemon then holds them at their **minimum** rather than letting them stop (2026-07-26). Two reasons, both measured on Mac14,9: macOS frequently does not reclaim parked fans at all (§4.3 field finding), and a fan restarted from a standstill needs 4.4 s where one already turning needs ~1 s. Truly returning the fans means removing the daemon — Settings → "Turn Off Fan Control".
- High-temp override to full cooling no matter what — per-sensor-class thresholds with debounce (§4.3.2).
- Notifications: "CPU exceeded 90 °C", "Reverted to Auto (watchdog)".
- Light on the machine: chart rendering pauses and app-side polling downshifts when the popover is closed — small footprint is a feature, not an accident.
- Full keyboard/VoiceOver accessibility on the curve editor (arrow keys nudge selected point); respects Reduce Motion.
- Localizable strings from day one (String Catalog).
- Crash-safe: daemon state machine assumes the app can vanish at any time.

---

## 2. System architecture

```
┌────────────────────────── Ice Cube.app (user) ──────────────────────────┐
│  SwiftUI UI (MenuBarExtra + windows)                                  │
│  ChartStore (ring buffers)  CurveEditorModel  SettingsStore           │
│  SMCPollingActor ──reads──▶ SMCProviding  (READ-ONLY: temps, RPMs)    │
│  HelperClient (NSXPCConnection, codesign-pinned) ── heartbeat ──┐     │
└───────────────────────────────┬─────────────────────────────────┼─────┘
                                │ XPC (mach service)              │
┌───────────────────────────────▼─────────────────────────────────▼─────┐
│  IceCubeHelper (root LaunchDaemon via SMAppService)                    │
│  ControlLoop (2 s): sensor read → active curve → clamp → SMC write    │
│  SafetyMonitor: watchdog, temp ceiling, revert-on-exit                │
│  SMCWritePort (READ+WRITE, the only writer in the system)            │
└───────────────────────────────────────────────────────────────────────┘
```

Key decisions:
- **The daemon owns control.** The app is a configurator/visualizer. This gives "fan curve active at boot without the app running" for free and keeps the root surface tiny.
- **Reads don't need root.** The app polls the SMC read-only at 1 s for silky charts; the daemon reads independently at 2 s for control. Never assume the app's numbers reached the daemon.
- **IceCubeKit** (local Swift package, consumed by both targets — declared once in `project.yml`) holds everything testable: SMC key model + encodings, curve interpolation/hysteresis math, `SMCProviding` protocol, `MockSMCProvider` (thermal simulation), XPC protocol types, preset codecs. UI and daemon are thin shells over it; `swift test` in `IceCubeKit/` is the test entry point.

---

## 3. SMC technical reference

### 3.1 Access
- Match IOService `"AppleSMC"` (exists on Intel *and* Apple Silicon), `IOServiceOpen`, then `IOConnectCallStructMethod` with selector `2` (kSMCHandleYPCEvent) and an `SMCParamStruct`.
- Commands: read key = 5, write key = 6, get key info = 9, get key by index = 8 (with `#KEY` count) — index enumeration powers the Sensors browser.
- Reads work unprivileged; writes are firmware-gated to root — unprivileged writes fail with `kIOReturnNotPrivileged` (`0xE00002C1`).
- Study (do not copy GPL code): **agoodkind/macos-smc-fan** (MIT — primary Apple Silicon write-path reference: Ftst research, mode-3 semantics, per-generation behavior), **exelban/Stats** (MIT — best real-world key maps; its fan control is legacy/unmaintained but the key tables are canonical), **beltex/SMCKit** (MIT — Intel-era param-struct layout, frozen ~2017), smcFanControl (GPL, unmaintained since 2022 — concepts only), VirtualSMC docs (key catalog).

### 3.2 Fan keys (Apple Silicon)
| Key | Meaning | Type | Notes |
|---|---|---|---|
| `FNum` | fan count | `ui8` | 0 ⇒ fanless machine (monitoring only) |
| `F{i}Ac` | actual RPM | `flt` | little-endian IEEE-754 float32 |
| `F{i}Tg` | target RPM | `flt` (write) | clamp before every write |
| `F{i}Mn` / `F{i}Mx` | min/max RPM | `flt` | **advisory, NOT firmware-enforced** — 0 RPM can be accepted; our daemon-side clamp is the real guard |
| `F{i}Md` / `F{i}md` | per-fan mode | `ui8` (write) | 0 = auto, 1 = forced, 3 = **system** (thermalmonitord/AppleCLPC in control — the Apple Silicon *resting* state; treating 3 as plain "auto" makes read-backs look like failures). Casing varies by generation — M5 uses lowercase `F{i}md`; **probe at runtime** |
| `Ftst` | force/test unlock flag | `ui8` (write) | write 1 → thermalmonitord yields mode writes (needed on M3/M4; present on M1/M2; absent on M5) |

Encodings: `flt` = little-endian IEEE-754 float32; `ui8/ui16/ui32` unsigned integers. The Intel-era `fpe2` codec (big-endian 16-bit fixed point, value = raw »2) **remains implemented + unit-tested in IceCubeKit** — useful for future reads and a community Intel port — but no Intel write sequence ships. Build encoders/decoders with exhaustive unit tests; this is where fan apps historically have bugs.

**Write sequence — generation-aware state machine** (per exelban/stats `unlockFanControl()`, PR #2924 / issue #2928, and agoodkind/macos-smc-fan):
1. Probe mode-key casing once (`F{i}Md` vs `F{i}md`).
2. Try the direct write: mode = 1.
3. On firmware result **0x82** (rejected): write `Ftst = 1`, wait ~3–4 s for thermalmonitord to yield, then retry the mode write at ~100 ms intervals for up to 10 s.
4. Write `F{i}Tg` (LE float32, clamped to `[Mn, Mx]`).
5. Verify **by read-back AND behaviorally**: the mode sticks *and* actual RPM converges toward target within ~10 s — otherwise surface "control rejected by system"; never silently lie.

Revert = mode 0 per fan (+ `Tg` 0), then `Ftst = 0` after the last fan. All writes serialized on one queue. **Every SMC call checks the `SMCParamStruct` result byte** (0x00 success, 0x82 firmware-rejected, 0x84 key-not-found) — IOKit can return `kIOReturnSuccess` on a firmware-rejected write. Capability matrix: **M1/M2 = direct path** (owner-verifiable on the M2 Pro); **M3/M4 = Ftst path, ships experimental** until community diagnostics confirm it. Note: the first transition *into* manual mode can lag ~5–6.5 s on Ftst-generation chips; reverting to auto is always fast.

**Field correction (2026-07-26):** the auto-mode safety net below matched SMC **mode 0 only**, but our own hand-back writes mode 3 — so the fans macOS declined to reclaim were never picked up at all, and sat dead indefinitely. It now matches any non-forced mode, and the decision is taken at the *instant* of the hand-back rather than on the next tick: the fans coast to a standstill in ~2.5 s, faster than a 2 s tick can react, and once stopped nothing software can do makes them start quickly (2317 and 4600 both took 9.4 s in back-to-back traces).

**Field correction (2026-07-23, Mac14,9 / macOS 26.4.1):** the reference revert sequence ("mode 0 + Tg 0") left the fans **stopped at 0 RPM** — thermalmonitord did not reclaim them. Corrected revert: park `F{i}Tg` at `F{i}Mn` first, then mode 0, then attempt mode 3 (explicit hand-back; rejection tolerated). A 0-RPM target is never written, not even on revert. Additionally the daemon runs an auto-mode safety net every tick: a fan with `Mn > 0` sitting at ~0 RPM in mode 0 for 3 ticks gets its target re-parked at minimum and a mode-3 hand-back attempt (§4.3 defense in depth).

### 3.3 Temperature keys
Vary per chip generation. Attested Apple Silicon families: **M1** `Tp*`/`Tg0*`; **M2** `Tp0*`/`Tp1*`, `Tg0f`/`Tg0j`; **M3** `Te0*`/`Tf*`; **M4** `Te0*`/`Tp0*`/`Tm*p`; **M5** `Tp0*`/`Tg0-1*`; plus AS-wide `TaLP`/`TaRF`/`TH0x`/`TB1T`/`TB2T`/`TW0P` (airflow, heatpipe, battery, water/skin proximity). Note that Stats and smctemp **disagree** on some M2 P-core labels — the community diagnostics pipeline is the *core mechanism* for key mapping, not a fallback. Strategy: ship a curated key map keyed by hardware model (`hw.model` sysctl) seeded from Stats' tables and cross-checked against narugit/smctemp; unknown models fall back to "enumerate all `T***` keys of sensible type, filter 0 < v < 120 °C, label by key"; the Sensors browser + diagnostics export lets the community contribute mappings.

### 3.4 Read-path notes
- Some Apple Silicon temps are also exposed via private `IOHIDEventSystemClient` APIs. **v1 sticks to SMC keys only** — one code path, fewer private-API risks. Revisit only if key coverage proves poor.
- Cache key info (type/size) per key; poll with a single reusable connection; never poll faster than 500 ms.
- Firmware **resets `Ftst` across sleep** — manual control is silently lost on wake. The daemon listens for IOKit power notifications and re-asserts (or reverts) fan state on wake (§4.3.6).

---

## 4. Privileged helper & security model

### 4.1 Registration (SMAppService, macOS 13+)
- Helper = plain executable target `IceCubeHelper`, embedded at `Ice Cube.app/Contents/MacOS/IceCubeHelper`.
- Launchd plist lives at `IceCube/Support/io.github.thijsvos.icecube.helper.plist` in the repo, copied into the bundle at `Ice Cube.app/Contents/Library/LaunchDaemons/io.github.thijsvos.icecube.helper.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.github.thijsvos.icecube.helper</string>
  <key>BundleProgram</key><string>Contents/MacOS/IceCubeHelper</string>
  <key>MachServices</key><dict>
    <key>io.github.thijsvos.icecube.helper.xpc</key><true/>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>AssociatedBundleIdentifiers</key>
  <array><string>io.github.thijsvos.icecube</string></array>
</dict></plist>
```

- **`RunAtLoad` is load-bearing:** `MachServices` alone gives on-demand XPC launch only — the "curve active at boot before the app runs" promise (Phase 4) is impossible without it.
- App calls `SMAppService.daemon(plistName: "io.github.thijsvos.icecube.helper.plist")`: `.register()`, surface `.status`, and on `.requiresApproval` show onboarding UI + `SMAppService.openSystemSettingsLoginItems()`. Include a Debug menu with Register / Unregister / Status / "Re-register" (needed after rebuilds — see XCODE_GUIDE §6).

### 4.2 XPC hardening
- Helper: `NSXPCListener(machServiceName:)`; in the delegate, call `setCodeSigningRequirement(_:)` on each new connection before resuming. **Two requirement variants per TN3127 — they are NOT interchangeable:**
  - **DEV (Apple Development signing, Phases 0–5):** `identifier "io.github.thijsvos.icecube" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.1] and certificate leaf[subject.OU] = "TEAMID"`
  - **RELEASE (Developer ID, Phase 6):** `identifier "io.github.thijsvos.icecube" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "TEAMID"`
  - Derive both from a dumped designated requirement (`codesign -d -r- Ice Cube.app`), **never hand-write**; validate candidates offline with `codesign --verify -R`. The Team ID is the certificate's **OU value**, NOT the parenthesized suffix in the certificate name. The real Team ID lives only in gitignored `Configs/Local.xcconfig` → injected build setting → generated Swift constant; DEBUG builds may relax to identifier-only with a loud log warning.
- App side mirrors the requirement on its `NSXPCConnection` (`options: .privileged`).
- Protocol (in IceCubeKit), deliberately tiny — reply closures are `@escaping @Sendable` (Swift 6 strict concurrency):

```swift
@objc public protocol HelperProtocol {
    func getVersion(reply: @escaping @Sendable (String) -> Void)
    func apply(configData: Data, reply: @escaping @Sendable (NSError?) -> Void) // Codable FanConfig: mode, curves, preset
    func setAllAuto(reply: @escaping @Sendable (NSError?) -> Void)
    func heartbeat()
    func getStatus(reply: @escaping @Sendable (Data) -> Void) // Codable HelperStatus
}
```
- Version handshake on connect; mismatch → app prompts "update helper" (re-register).

### 4.3 SafetyMonitor spec (daemon-side, cannot be disabled by the app)
1. Watchdog: last heartbeat > 15 s **and** config says "don't persist without app" → all fans auto. **Manual (fixed-RPM) mode is ALWAYS watchdogged regardless of the persist toggle — only curve mode may run app-less.**
2. Temp ceiling: **per-sensor-class thresholds** (die sensors legitimately reach 95–105 °C under sustained load; proximity sensors run far cooler) with an **N-consecutive-tick debounce** (a single glitched reading never trips it) → force full cooling until comfortably below threshold; log + notify via app when it reconnects.
3. On daemon start: **load + validate the persisted config and resume it; missing/invalid → auto** (NOT unconditional auto — that broke boot persistence). Crash-recovery, `setAllAuto`, XPC invalidation with non-persistent config, and SIGTERM → write auto mode for every fan.
4. Every write: clamp, verify by read-back (behavioral, §3.2), log via `os.Logger`. **Read-back failure: retry once → revert to auto → log.**
5. Sensor read failure > 3 consecutive ticks while in manual/curve mode → revert to auto.
6. On system wake: re-verify fan mode/targets and **re-assert or revert** (firmware resets `Ftst` across sleep, §3.4). Also self-test the write path (write + read-back) after daemon start and after OS updates before claiming curves are active.
7. Daemon-side persistence: `/Library/Application Support/IceCube/`, **root-owned**, atomic writes, validated + **versioned** schema; corrupt or stale config at boot → auto.

---

## 5. Milestones

Work in order. Each phase ends with its acceptance criteria demonstrably true (simulated mode counts, except where marked **[HW]** = needs real hardware, owner in the loop).

### Phase 0 — Scaffold & simulated heartbeat
- [x] Repo layout: committed `project.yml` (XcodeGen 2.46.0 generates the **gitignored** `IceCube.xcodeproj`), `IceCube/`, `IceCubeHelper/`, `IceCubeKit/` (local SPM package), `Configs/` (`Shared.xcconfig` committed, containing `#include? "Local.xcconfig"`; gitignored `Local.xcconfig` holds `DEVELOPMENT_TEAM`), `scripts/`, `docs/`, `.github/`.
- [x] Git bootstrap (done 2026-07-23): `git init` + per-repo personal identity (GitHub noreply email — the global git email is the owner's work address); MIT LICENSE (copyright 2026 thijsvos) committed **now**, moved up from Phase 6. Repo stays **local-only** for now — no GitHub remote yet.
- [x] Bundle prefix **decided**: `io.github.thijsvos.icecube` (app), `io.github.thijsvos.icecube.helper` (helper), `io.github.thijsvos.icecube.helper.xpc` (mach service) — applied consistently to target settings, launchd Label, plist filename, MachService name, log subsystem, and pinning identifier (one atomic set; one free rename allowed until first public release).
- [x] `project.yml`: app target (SwiftUI, macOS 14.0, sandbox OFF, LSUIElement), helper `tool` target embedded to `Contents/MacOS` + plist copied to `Contents/Library/LaunchDaemons`, both depending on IceCubeKit; Swift 6 language mode everywhere (app target MainActor default isolation; helper + Kit nonisolated); committed `Ice Cube (Simulated)` scheme (`ICECUBE_SIMULATED=1`); `scripts/verify-bundle.sh` asserts the bundle layout after every build.
- [x] IceCubeKit: `SMCProviding` protocol, models (`Fan`, `SensorReading`, `FanConfig`, `Preset`, `FanMode` incl. `.system` = 3), `MockSMCProvider` (2 fans, CPU/GPU temps as noisy sine + random load spikes; fans respond to targets with inertia), typed `IceCubeError` distinguishing firmware result bytes (0x82/0x84) from IOKit errors.
- [x] MenuBarExtra showing live mock temp/RPM text; basic popover with numbers.
- [x] `swift test` green (SMCKeyCodec fully implemented with 30 byte-fixture tests — pulled forward from Phase 1), SwiftFormat config, `.gitignore` (xcodeproj, `Local.xcconfig`, build/), CI workflow committed: pinned `runs-on: macos-26` + explicit Xcode 26.6 select, build (`CODE_SIGNING_ALLOWED=NO`) + `swift test` + verify-bundle — **activates on first push** (dormant while the repo is local-only).
- **Accept:** `ICECUBE_SIMULATED=1` run shows live-updating menu bar + popover; `swift test` green; `scripts/verify-bundle.sh` passes; CI workflow committed (runs on first push).

### Phase 0.5 — Helper approval spike **[HW]** (gate before Phase 3)
- [x] Throwaway do-nothing daemon, personal-team (Apple Development) signing, run from /Applications: register → approve in Login Items → `sudo launchctl print system/io.github.thijsvos.icecube.helper` → XPC ping round-trip as root.
- [x] Outcome decides the Phase 3+ helper story. **Documented fallback if free-Apple-ID approval fails:** owner manually installs the daemon plist via `sudo launchctl bootstrap` for Phases 3–5; SMAppService deferred to Phase 6 / paid-account upgrade.
- [x] Note: macOS 26.4.x has a known BTM corruption bug (backgroundtaskmanagementd misbehaving; approval toggles failing for reasons unrelated to our code). If registration hangs, suspect the OS first; `sfltool resetbtm` + reboot is the **last resort** — it resets background-item approvals for ALL apps on the Mac (owner decision).
- ANSWERED 2026-07-23: **free-Apple-ID SMAppService root-daemon registration + approval WORKS** on Mac14,9 / macOS 26.4.1 (approved once; re-registration never re-prompts; daemon auto-starts via RunAtLoad). The fallback was never needed.
- **Accept:** a definitive answer — free-ID path confirmed, or the fallback adopted and documented.

### Phase 1 — Real SMC reads & sensors browser
- [x] `SMCConnection` (IOKit param-struct calls) using the Phase 0 `SMCKeyCodec`; key-info cache, index enumeration.
- [x] `SystemSMCProvider` (read-only) behind the protocol; provider chosen at composition root by env/arg.
- [x] Fan discovery (`FNum`, per-fan Ac/Mn/Mx), temp discovery via curated map + fallback filter (§3.3).
- [x] Sensors browser window + JSON diagnostics export.
- [x] `SMCPollingActor` publishing snapshots at 1 s; menu bar shows real values. **[HW]**
- Note (2026-07-23): done as planned, plus a `icecube-diag` CLI (SPM executable in IceCubeKit) that prints the diagnostics summary/JSON without the app — verified on the owner's Mac14,9: 2169 keys, 2 fans (F{i}Mn 2317 / F{i}Mx 6800), all 20 curated M2 sensors resolved with plausible values. Mock fan ranges corrected to the measured ones.
- **Accept:** on owner's Mac, real RPMs/temps visible and plausible; `FNum ≥ 1` confirmed (if it's 0 the machine is fanless — e.g. MacBook Air — and the control phases need a different test Mac; monitoring still works); diagnostics export produces a valid report; all codec tests pass.

### Phase 2 — Dashboard & charts
- [x] `ChartStore` ring buffers (per-series, 3600 samples) + **hard downsampling budget: ≤ ~600 visible points per series** (min-max or LTTB, computed off the main actor) — see §1.2; raw 60-min windows are in Swift Charts' documented degradation zone. *(min-max bucketing; budget + spike-survival unit-tested)*
- [x] Stacked Swift Charts rows with gradient fills, window switcher, pause, hover crosshair, min/avg/max; **no implicit animations on live marks; hover state scoped per chart row**. *(CPU/GPU/per-fan rows, fixed y domains; hover readout swaps in the header — fixed layout slots)*
- [x] Menu bar display options (icon/temp/RPM/combo) in Settings. *(plain Window scene, not the Settings scene — LSUIElement focus reliability)*
- [ ] Dark-first visual polish pass; 60 fps scrolling verified with Instruments in simulated mode. *(2026-07-23: materials-based, fixed domains, ~1% CPU with ingest running; the Instruments/eyeball pass needs the owner — implementation done)*
- **Accept:** popover dashboard looks and feels Afterburner-grade in simulated mode; no dropped frames on an idle machine with the point budget enforced.

### Phase 3 — Helper, XPC, manual control **[HW]**
- [x] IceCubeHelper: XPC listener + codesign pinning (TN3127 dev variant, §4.2), `SMCWritePort` + `FanWriteSequencer` write path = the generation-aware Apple Silicon state machine (§3.2: casing probe → direct mode write → Ftst unlock fallback), result-byte checking on every call, read-back + behavioral verification.
- [x] SafetyMonitor per §4.3, with unit-tested state machine in IceCubeKit (time + temps injected). *(2026-07-25: `DaemonCore` + `ConfigStore` also moved into IceCubeKit behind `SMCControlPort`/`FanConfigStoring`, so the daemon's own revert/wake/watchdog paths are unit-tested too — see `DaemonCoreTests`. `SMCWritePort` stays helper-only; the app binary contains no writer.)*
- [x] SMAppService registration flow (or the Phase 0.5 fallback) + onboarding sheet + Debug menu (register/unregister/status).
- [x] App `HelperClient`: connection lifecycle, heartbeat (5 s), reconnect/backoff, version handshake.
- [x] Manual mode UI: per-fan sliders, prominent revert-to-auto, warning tint.
- **Accept (owner-verified, M2 Pro):** approve helper once → slider moves a real fan; read-back confirms `F0Md == 1` (or `F0md == 1`) and `Tg` equals the commanded value; the helper reports **which unlock branch ran** (direct vs Ftst); killing the app → fans return to auto ≤ 15 s; `log stream` shows clamped, audited writes.

### Phase 4 — Curves, presets, control loop
- [x] Curve model: monotonic piecewise-linear interpolation, hysteresis, ramp limiter — pure functions, property-based tests (never NaN, never out of clamp, monotone response).
- [x] Daemon ControlLoop consuming `FanConfig`; "persist without app" honored (curve mode only, §4.3.1). *(2026-07-26: write sequences are now serialized behind a lock plus an intent counter — `engageManual` writes a mode and a target per fan and suspends on every one, so two engages interleaved and the fans ended up wherever the last WRITE landed rather than wherever the newest INTENT said. Closes vet finding W5.)*
- [x] Curve editor UI (drag points, keyboard nudge, live "you are here" marker, per-fan/linked).
- [x] Presets: built-ins (Quiet/Balanced/Cold/Max) + user presets, JSON in `~/Library/Application Support/IceCube/`, quick-switch in popover. There was a fifth, "macOS", that handed the fans back; renaming it from "Auto" and fencing it off behind a divider both failed to stop people reading it as the app's smart mode, and it was removed on 2026-07-26. Every preset now means Ice Cube is driving; turning fan control off is Settings → "Turn Off Fan Control", which removes the daemon (the only thing that actually returns the fans — see the guardian field finding in §4.3).
- Note (2026-07-23): implemented — FanCurve (normalized invariants, 90 tests total incl. property sweep), CurveFollower (hysteresis deadband + ramp limiter), daemon curve loop with read-back verify + wake re-assert + root-owned persistence (/Library/Application Support/IceCube, atomic, schema-validated, manual never persisted), Canvas curve editor (drag/double-click/⌫/arrows, live marker incl. hysteresis preview dot — works simulated), presets quick-switch in popover + user presets JSON. Deviations: per-fan curve editing deferred (model supports per-fan overrides; editor ships linked-all); input-sensor pick-list deferred (input = hottest die sensor); protocol bumped to v2. Owner-pending: Quiet-vs-Max audible check and the reboot-persist test.
- **Accept:** in simulated mode, heating the fake CPU visibly walks the curve with hysteresis; on hardware, a Quiet vs Max preset audibly differs; reboot with "persist" on → curve active before app launch.

### Phase 5 — Modern-app polish
- [x] Settings: launch at login, intervals, units, notifications thresholds, persist-toggle.
- [x] UserNotifications alerts (permission flow handled gracefully).
- [x] History window + CSV export; onboarding; accessibility audit (VoiceOver labels, keyboard-only curve editing); String Catalog; Reduce Motion.
- [ ] App icon (Icon Composer `.icon`) + menu bar template icons (owner supplies or we generate placeholder); popover surfaces built on system materials, verified on macOS 26 Tahoe.
- **Accept:** run through a "new user" script end-to-end without touching the mouse for core flows; VoiceOver can read the dashboard.

### Phase 6 — Open source & releases

- Note (2026-07-23): community docs (README/CONTRIBUTING/CODE_OF_CONDUCT/SECURITY, issue + PR templates), docs/ (SMC-KEYS with field findings, RELEASING, CREDITS, ARCHITECTURE updated), uninstall documented, in-app GitHub-releases update checker (Settings → Updates) all done. REMAINING, owner-gated: (1) publish the repo (`gh repo create` — owner's explicit call), after which CI activates; (2) notarized public release — paid Apple account.
**Gate:** signing/notarization tasks require a paid Apple Developer account. Until the owner upgrades, do everything else in this phase and distribute unsigned tester builds (XCODE_GUIDE §8 item 4).
- [x] README (feature table, safety section, "why root helper" FAQ, uninstall section — unregister daemon + remove files), CONTRIBUTING, CODE_OF_CONDUCT, SECURITY.md, issue templates (bug + "new Mac model report" using diagnostics JSON), PR template. (LICENSE landed in Phase 0.) *(2026-07-25: CI/licence/platform badges added; download-vs-build-from-source consequences spelled out. **Screenshots still owner-supplied** — the one item here a machine cannot produce.)*
- [x] docs/: ARCHITECTURE.md, SMC-KEYS.md (living key map), RELEASING.md, CREDITS.md.
- [x] Update check: tiny hand-rolled GitHub Releases API version check — compare tags, link to the releases page, **no auto-install, no Sparkle, zero dependencies**. Note: replacing the app replaces the embedded helper; the version handshake (§4.2) detects mismatch and prompts re-register.
- [x] Release workflow: `.github/workflows/release.yml` — tag → gate on tag/version agreement, lint + tests, then **two modes chosen automatically**: with Developer ID secrets it signs, notarizes (`notarytool` with an App Store Connect key), staples and builds a DMG; without them it ships an unsigned zip labelled as such. Always a draft. *(2026-07-25: written ahead of the paid account deliberately, so the upgrade is "add six secrets" rather than "write CI". **Untested end-to-end** — never run against real Actions. Still requires the §4.2 RELEASE pinning change before a Developer ID build can talk to its helper; docs/RELEASING.md says so.)*
- [x] CI hardening: lint + tests + build + bundle-layout, plus a **capability-boundary check** (`nm` proves the app binary links no SMC writer — the guarantee that replaced "the writer lives in another target" once DaemonCore moved into IceCubeKit) and a simulated-mode smoke test.
- **Accept:** a clean Mac can download the DMG, pass Gatekeeper, approve helper, and control fans; `v0.1.0` public.

---

## 6. Testing strategy
- **IceCubeKit = the fortress**: codecs (byte-level fixtures from real Macs), curve math (property tests), SafetyMonitor state machine (simulated clock), preset codecs. Target >90 % coverage here; UI coverage is best-effort.
- Simulated mode for all UI dev + CI; a `ThermalScenario` script type (idle → load spike → cooldown) drives repeatable demos.
- Manual HW checklist (docs/TESTPLAN.md): approval flow, watchdog, ceiling override (use scenario injection, don't actually cook the Mac), fast user switching, on owner hardware before each release.
- **Sleep/wake acceptance test [HW]:** with a curve (and separately, manual mode) active, sleep the Mac ≥ 1 min, wake → daemon re-asserts control (or reverts and reports "control lost") within one control tick; verified via read-back + `log stream`. Firmware resets `Ftst` across sleep (§3.4), so this must be exercised on hardware, not simulated.

## 7. Risks & mitigations
- **SMC keys vary wildly per model** → curated map + fallback enumeration + community diagnostics pipeline (§3.3). Biggest ongoing cost; design for it.
- **Free-Apple-ID helper approval unproven** → Phase 0.5 spike with the fallback documented *before* it runs (manual `sudo launchctl bootstrap` install for Phases 3–5).
- **macOS 26.4.x BTM corruption bug** → registration/approval may misbehave for reasons unrelated to our code; `sfltool resetbtm` + reboot is the last resort (resets background-item approvals for ALL apps).
- **Apple changes SMC/BTM behavior in new macOS** → keep write paths isolated in `SMCWritePort`; CI on latest macOS runner; release notes discipline. Point updates have broken write paths before (macOS 15.3/15.4) — hence the §4.3.6 post-update self-test.
- **Signing cert expiry mid-project** → owner's Apple Development cert expires **2026-08-15**; Xcode auto-renews, but if XPC pinning suddenly fails around that date, suspect certificate renewal — not code.
- **Helper approval UX friction** → onboarding invests here; Debug re-register; XCODE_GUIDE troubleshooting §7.
- **Forced-fan misuse (user sets 0 %)** → clamp to `F{i}Mn` (the firmware won't stop us — §3.2 — so the clamp is THE guard), ceiling override, warning UI in manual mode.
- **Notarization/signing complexity** → all human steps scripted + documented; CI does releases so it's done the same way every time.

## 8. Open-source & release engineering
MIT license (matches SMCKit/Stats ecosystem; avoids GPL entanglement — we reference smcFanControl concepts only). Conventional commits, `main` protected, squash merges. Versioning: semver, `v0.x` until Phase 6 accept. Publish a short SECURITY.md (root helper = report privately). Screenshots/GIFs generated from simulated mode with a demo scenario so they're reproducible.

## 9. Reference material for Claude Code
- Apple docs: `SMAppService`, `NSXPCConnection` (+ `setCodeSigningRequirement`), TN3127 (requirement strings), `MenuBarExtra`, Swift Charts, `UserNotifications`, `IOConnectCallStructMethod`.
- **agoodkind/macos-smc-fan (MIT): primary Apple Silicon write-path reference** — Ftst mechanism, mode-3 semantics, per-generation differences, sleep/wake reset.
- exelban/Stats (MIT): SMC key maps — its fan control is legacy/unmaintained, but the key tables are canonical. narugit/smctemp: temperature-key cross-check (disagrees with Stats on some M2 labels; both feed the curated map).
- beltex/SMCKit (MIT): Intel-era param-struct layout reference, frozen ~2017. VirtualSMC key docs: key catalog. smcFanControl (GPL, unmaintained since 2022): historical Intel behavior — read, don't copy.
- UI (reference only — we vendor our own ~100-line shim, no dependencies): orchetect/MenuBarExtraAccess (NSStatusItem access patterns), steipete.me settings-window post (LSUIElement window-focus dance).

## 10. Owner decisions (confirmed 2026-07-22, revised 2026-07-23)
1. **Name & identifiers**: marketing name still open — `Ice Cube` is the working codename. Bundle prefix is **decided now**: `io.github.thijsvos.icecube` (helper `.helper`, mach service `.helper.xpc`). One free rename allowed until the first public release; after that identifiers are frozen (BTM approvals + codesign pinning depend on them).
2. **Account**: free Apple ID (personal team). Free-ID helper approval is **an assumption under test, not a fact** — one primary source claims paid Developer ID is required for SMAppService privileged helpers; the Phase 0.5 spike settles it, with the fallback (manual `sudo launchctl bootstrap` install for Phases 3–5) documented in advance. Phase 6 notarized public release waits on a paid upgrade regardless.
3. **Hardware**: Apple Silicon **only** — confirmed. Intel is out of scope entirely (community port welcome; `SMCProviding` stays hardware-agnostic; fpe2 codec kept + tested). Within AS, per-generation: M1/M2 direct write path (owner-verifiable on the M2 Pro); M3/M4 Ftst path ships **experimental** until community diagnostics confirm.
4. **Minimum macOS**: 14.0 confirmed (`@Observable` stays; old-Intel reach is not a priority for this owner).
5. **Updates**: hand-rolled GitHub Releases version check, link-only — no Sparkle, no auto-install (zero-dependency rule).
6. **Git identity**: per-repo GitHub noreply email (the global git config carries the owner's work address; keep it out of public history).

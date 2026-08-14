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
- Left-click opens dashboard popover; ⌥-click quick-switches preset. **Done 2026-07-27, both variants.** **Reality check:** click interception is not achievable in pure `MenuBarExtra` — there is no first-party API (FB11984872). Cheap v1 variant: read `NSEvent.modifierFlags` when the popover opens (popover still appears, already switched). The full no-popover variant needs a small **vendored** AppKit status-item shim (~100 lines we write and own — still zero dependencies). Both shipped: the cheap variant is the default, and Settings → Menu bar → "⌥-click switches preset silently" swaps in `StatusItemController` via `MenuBarExtra(isInserted:)` (available since macOS 13, one below our target). `MenuBarModeCoordinator` owns the swap in one place because the real hazard is not AppKit — it is stranding `isPopoverVisible` at true, which costs ~17 % CPU with no visible symptom, from either direction.

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
- **Manual control SURVIVES sleep, and that is the hazard.** On Apple Silicon a written `F{i}Md = 1` and its `F{i}Tg` keep being honoured across sleep, and nothing of the daemon's runs while the machine is asleep — so the tick, the watchdog and the ceiling are all inert. `Ftst` is an unlock flag, not the mode latch (clearing it re-locks *future* writes; it does not release a fan that is already forced), and on Mac14,9 the key **does not exist at all** (2169 keys dumped with `icecube-diag --json`). This bullet previously claimed the opposite — that the firmware reset `Ftst` across sleep and cleaned up for us — and that false model is why the sleep half went unwritten until 2026-07-28. The contract therefore has two halves: the daemon registers for IOKit root-power-domain notifications, hands every fan back on `kIOMessageSystemWillSleep` **before acknowledging**, and re-asserts (or reverts) on wake (§4.3.6).

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
- App calls `SMAppService.daemon(plistName: "io.github.thijsvos.icecube.helper.plist")`: `.register()`, surface `.status`, and on `.requiresApproval` show onboarding UI + `SMAppService.openSystemSettingsLoginItems()`. Expose Register / Unregister / Status / re-register (the last needed after rebuilds — see XCODE_GUIDE §4.4). *Shipped as **Settings → Fan Control**, not the Debug menu written here: an `LSUIElement` app has no menu bar of its own, so there was nowhere to hang one. The re-register control is the **Reinstall** button.*

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
6. **On system sleep: park the fans.** On `kIOMessageSystemWillSleep` the daemon hands every fan back to the firmware and only then acknowledges IOKit (budget 6 s, well under IOKit's 30 s cap). A park is deliberately **not** a revert — `config`, the persisted curve and the ceiling hysteresis all survive it, so waking resumes the user's own curve instead of silently landing in auto. Three consequences are part of the contract, not emergent: the **temperature ceiling stays armed** on every parked tick (the ticks that run while parked are dark wakes, when the SoC is fully live); the **watchdog and any deferred revert are postponed** to the first tick after the latch releases; and **`connectionInvalidated` is skipped** while parked, because the fans are already with macOS — the strongest form of what that invariant produces — and re-grabbing them would defeat the sleep. On system wake: re-verify fan mode/targets and **re-assert or revert** (§3.4). Also self-test the write path (write + read-back) after daemon start and after OS updates before claiming curves are active.
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
- Note (2026-07-30): the sensors window now opens as tall as its own list instead of a fixed 480 pt — `SensorsWindowMetrics` turns (sensor count, fan count, screen height) into a `.defaultSize`, clamped to 320…860 pt and to the screen. 377 pt for the 6-sensor simulated list, 617–713 pt on Mac14,9, capped on a Mac whose sensors are enumerated rather than curated. Arithmetic rather than layout because a SwiftUI `Window` ignores its content's `idealHeight` and a `List` has no intrinsic height to offer (both measured on macOS 26.4, along with every constant in the formula — a probe walking the `NSTableView` behind the `List` confirms 8 rows fit 377 pt exactly, with no scrollbar and 22 pt to spare). The content's own `minHeight` had been silently overriding any smaller default, so it is now derived from the same type. Window id bumped to `sensors.v2` — a saved `NSWindow Frame` outranks `.defaultSize`, so without a fresh identity nobody who had already opened the window would ever see the change.
- Fix (2026-07-30): "the settings window pops up when I close the sensors window" — it was never opening. Clicking away from a window does not close it, and an `LSUIElement` app has no Dock icon, no ⌘-Tab entry and no Window menu, so a window off screen is unreachable and invisible rather than merely backgrounded; AppKit then promotes it when the front window closes (captured live: `order window: 460ca op: 1 relative: 460cc`, 5 ms after the Sensors window closed, with no `context (0 → …)` line — nothing was created). `WindowOpener.openFromPopover` now retracts whatever the menu bar left behind first, for the windows that hold no unsaved work (Sensors, Settings, About — never Curves or Setup). Cost, accepted: Sensors and Settings can no longer be on screen together via the menu bar. Latent since the app had a second window; surfaced by the sizing change above, whose smaller sensors frame stopped covering the stale settings frame.
- Fix (2026-07-30): app-side sensor discovery is deterministic. It admitted a curated sensor only if its *first read* passed `isPlausibleTemperature` — but on Apple Silicon a power-gated CPU cluster returns a frozen firmware sentinel (measured on Mac14,9: exactly 6.70 °C and 4.63 °C, whole cluster at once, P-cluster gated at 66.9 % of idle instants and E-cluster at 21.8 %), so the read said "dead sensor" and the key was disowned for the life of the process. Ten `icecube-diag` runs used to return 8/12/16/20 of 20; they now return **20 discovered, every time**. Membership is decided by key **existence** instead (`SensorAdmission`, unit-tested): an absent key throws on probe (13 of 13 absent candidates, every attempt) while a gated one never does, and one cached `keyInfo` call costs less SMC traffic than the value probe it replaces. `isPlausibleTemperature` keeps its job on the *value* path, so a 6.70 °C sentinel is still never displayed, charted, or fed to `hottestDie`.
  - The real cost of the old rule was not the varying count: launching while idle **permanently** hid the 8 P-core sensors, so the app never showed P-core temperatures even under full load. Measured after the fix — idle, the list sits at 12 of 20 for 95 s+; under `yes ×6`, all 20 report on the first tick.
  - Consequences, deliberate: the published list is now **monotone** (grows as clusters wake, never shrinks or reorders) rather than fixed at discovery, so `SensorStabilizer`'s contract comment was corrected and `ChartStore` now latches its CPU/GPU rows **on** instead of one-shot — otherwise a launch with the GPU asleep silently lost that chart series for the session. The Sensors window's height now derives from the *inventory*, not the reporting list, so it no longer persists a frame sized for whatever happened to be awake.
- Follow-up (2026-07-30 — **closed 2026-08-01**, see the sensor entry in Phase 6's log below): `DaemonCore` had the same value-based admission on its own path (`DaemonCore.swift:1411`), and there it is **safety-relevant**. Its re-probe fires only when an already-admitted sensor goes missing (`:1489`), and a sensor never admitted can never go missing — so a daemon that probes while the machine is idle excludes the 8 P-core **die** sensors for its whole lifetime. Those are the hottest points on the SoC under load and the reason the die-class ceiling is 104 °C; the curve input ("hottest die sensor") would be driven by GPU/E-core readings instead. `SensorAdmission` was the ready-made fix, but three of the daemon's five admission rules were unpinned by tests (a mutation run deleted the second-chance read, the ≥120 clamp, and implausible-≠-missing, and all 303 tests stayed green), so a green `swift test` was not evidence a migration preserved behaviour. **How it was closed:** the migration was preceded by its own commit of characterization tests — nine, each confirmed to fail against a mutation of its rule — of which exactly one changed semantics under the migration, and that is the evidence the other six survived.
- **Accept:** on owner's Mac, real RPMs/temps visible and plausible; `FNum ≥ 1` confirmed (if it's 0 the machine is fanless — e.g. MacBook Air — and the control phases need a different test Mac; monitoring still works); diagnostics export produces a valid report; all codec tests pass.

### Phase 2 — Dashboard & charts
- [x] `ChartStore` ring buffers (per-series, 3600 samples) + **hard downsampling budget: ≤ ~600 visible points per series** (min-max or LTTB, computed off the main actor) — see §1.2; raw 60-min windows are in Swift Charts' documented degradation zone. *(min-max bucketing; budget + spike-survival unit-tested)*
- [x] Stacked Swift Charts rows with gradient fills, window switcher, pause, hover crosshair, min/avg/max; **no implicit animations on live marks; hover state scoped per chart row**. *(CPU/GPU/per-fan rows, fixed y domains; hover readout swaps in the header — fixed layout slots)*
- [x] Menu bar display options (icon/temp/RPM/combo) in Settings. *(plain Window scene, not the Settings scene — LSUIElement focus reliability)*
- [x] Dark-first visual polish pass; 60 fps verified. *(2026-07-27: owner confirms the look is Afterburner-grade. Frame budget measured rather than eyeballed — `ChartStoreTests.rowsFitInsideAFrame`, worst of 50 runs per window on Mac14,9 in release: 1-min 1.6 ms · 5-min 1.6 ms · 15-min 2.0 ms · **60-min 3.3 ms**. The 60-minute window was the documented hazard (§1.2) and lands at a fifth of a 60 fps frame — while never needing to fit in one: `rows(window:)` runs once per 1 Hz poll, only while the popover is visible, on an actor and therefore off the main thread. Against the interval it really runs on, 3.3 ms is 0.3 %. Live app measured at 0.1 % CPU / 30.6 MB with the popover closed and ingest running.)*
- **Accept:** popover dashboard looks and feels Afterburner-grade in simulated mode; no dropped frames on an idle machine with the point budget enforced.

### Phase 3 — Helper, XPC, manual control **[HW]**
- [x] IceCubeHelper: XPC listener + codesign pinning (TN3127 dev variant, §4.2), `SMCWritePort` + `FanWriteSequencer` write path = the generation-aware Apple Silicon state machine (§3.2: casing probe → direct mode write → Ftst unlock fallback), result-byte checking on every call, read-back + behavioral verification.
- [x] SafetyMonitor per §4.3, with unit-tested state machine in IceCubeKit (time + temps injected). *(2026-07-25: `DaemonCore` + `ConfigStore` also moved into IceCubeKit behind `SMCControlPort`/`FanConfigStoring`, so the daemon's own revert/wake/watchdog paths are unit-tested too — see `DaemonCoreTests`. `SMCWritePort` stays helper-only; the app binary contains no writer.)*
- [x] Sleep half of the power contract (§3.4, §4.3.6) — the daemon parks the fans on `kIOMessageSystemWillSleep` and writes no fan until it wakes. *(2026-07-28, protocol v20. Owner-reported: "close the lid and the fans stay on." Only the **wake** half had ever been written, on the false §3.4 premise that firmware resets `Ftst` across sleep — `Ftst` is not even present on Mac14,9. Measured from the owner's own logs: `curve engaged` 18:16:39 → `Clamshell Sleep` 18:21:47 → **994 s of forced fans and total daemon silence** → released at 18:38:20 only because an unrelated 2 s Power Nap dark wake ran one tick and the watchdog fired on a "995 s stale heartbeat" that was really the nap. New: `SystemPowerWatcher` (helper-only IOKit plumbing), `SleepLatch` + `SystemPowerMessage` (IceCubeKit, pure), `DaemonCore.prepareForSleep()`/`systemDidPowerOn()`. The park deliberately does **not** reuse `revertEverything`, which wipes `config` and deletes the persisted curve — that would have made every lid close silently uninstall the user's fan control, and armed `autoSafetyNet`'s un-debounced floor rung so the Mac went to sleep **louder**. 34 new tests; `verify-bundle.sh` now also proves the app links no `SystemPowerWatcher`. **Owner-verified on hardware the same day:** lid close → `fans parked for sleep in 0.0098 seconds (config kept: curve)` and the fans audibly stop; `pmset -g log` "Delays to Sleep notifications" names only `com.apple.bluetooth.sleep` (1542 ms), never IceCubeHelper; wake → fans re-commanded **179 ms** after `kIOMessageSystemHasPoweredOn` (09:25:49.311 → 09:25:49.490). The few seconds the owner perceived before the fans audibly return is spin-up from a genuine standstill, which `FanGuardian` already documents as ~9 s and is the cost of the fans actually stopping. One field regression found and fixed in the same session: a tick landing 9 ms **inside** the hand-back saw `parkLanded` still false and logged "the pre-sleep hand-back never landed" about the sequence that was landing as it spoke — hardware was never at risk (`parkInFlight` collapsed it to one `revertAllAuto`), but the log said the opposite of the truth, which is the v19 class of bug. Guarded on `parkInFlight` and pinned by `inFlightParkIsNotReportedAsFailed`, which was confirmed to fail without the guard.)*
- [x] SMAppService registration flow (or the Phase 0.5 fallback) + onboarding sheet + register/unregister/status controls. *(Shipped in **Settings → Fan Control**, not as the Debug menu §4.1 specified — an `LSUIElement` app has no menu bar to hang one on. "Re-register" is the **Reinstall** button. This checkbox read "+ Debug menu" until 2026-08-02, which sent XCODE_GUIDE and CONTRIBUTING chasing a menu that never existed.)*
- [x] App `HelperClient`: connection lifecycle, heartbeat (5 s), reconnect/backoff, version handshake.
- [x] Manual mode UI: per-fan sliders, prominent revert-to-auto, warning tint.
- **Accept (owner-verified, M2 Pro):** approve helper once → slider moves a real fan; read-back confirms `F0Md == 1` (or `F0md == 1`) and `Tg` equals the commanded value; the helper reports **which unlock branch ran** (direct vs Ftst); killing the app → fans return to auto ≤ 15 s; `log stream` shows clamped, audited writes.

### Phase 4 — Curves, presets, control loop
- [x] Curve model: monotonic piecewise-linear interpolation, hysteresis, ramp limiter — pure functions, property-based tests (never NaN, never out of clamp, monotone response).
- [x] Daemon ControlLoop consuming `FanConfig`; "persist without app" honored (curve mode only, §4.3.1). *(2026-07-26: write sequences are now serialized behind a lock plus an intent counter — `engageManual` writes a mode and a target per fan and suspends on every one, so two engages interleaved and the fans ended up wherever the last WRITE landed rather than wherever the newest INTENT said. Closes vet finding W5.)*
- [x] Curve editor UI (drag points, keyboard nudge, live "you are here" marker, per-fan/linked). *(2026-08-13: **Apply Curve now closes the window** — owner request. The editor is a workbench, and its disappearance is the only receipt it has: it shows no status of its own. Which is why it closes on success **only**. A refusal keeps the window and says why in the warning register; a config the daemon deferred because the Mac is parked keeps it too, in the calm one — closing there would claim a curve is running while it sits in the wake queue, and would take the hand-drawn points with it, the same loss `WindowOpener.closableFromMenuBar` keeps `curves` out of that set to avoid. The three-way decision is `CurveApplyPolicy`, pure and in the app test bundle, because `canApply` is false in simulated mode: applying a curve needs real hardware, so nothing else about this can be exercised off the owner's Mac. Five tests, each confirmed to fail against a mutation of its branch. **Follow-up: the editor now SHOWS the curve the fans are running** — `CurveEditorSeed` decides which curve, `CurveEditorModel.follow(_:)` decides when. Closing on Apply made a pre-existing wart the common path: SwiftUI tears a `Window` scene's content down on close, so apply-then-reopen showed the Balanced default while the hardware ran the curve just drawn, and the natural reading of that is "the app forgot my curve". Precedence copied from `PresetHighlight.isActive` and for its stated reason — the daemon's `activeCurve` outranks the app's memory of what it sent, because the truth about what is enforced lives in the daemon — with hysteresis and ramp taken from `lastAppliedConfig` **only when it describes that same curve**, so a boot-resumed profile cannot borrow another curve's smoothing. Manual, auto and a fresh install still open on Balanced. Nine more tests, each mutation-confirmed. **The first trigger was wrong and hardware said so** (2026-08-14): seeding once, on the window appearing, did nothing at all on the owner's Mac — four presets applied, editor still on Balanced, and still Balanced after ⌘W and reopening. Appearance is the wrong event: a `Window` scene's content can outlive the window being shut, nothing tears it down when the window is merely raised, and `closableFromMenuBar` deliberately never closes this one — so "on appear" can mean "once, at launch, before the app knew anything", then never again. It is a subscription now: the editor adopts whatever the daemon reports, on every status change, until the user touches something (drag, add, remove, nudge, either slider, or loading a preset by name), after which nothing overwrites their curve. Three more tests, one walking all seven ways of taking the wheel; the decision is logged (`curve editor: daemon=… → adopted`) for the reason `WindowOpener.closeStaleWindows` logs its own, and that log is what confirmed the fix on hardware: `preset: Max applied` 08:10:49 → `→ adopted` 08:10:53 → `→ already shown` 08:10:55.)*
- [x] Presets: built-ins (Quiet/Balanced/Cold/Max) + user presets, JSON in `~/Library/Application Support/IceCube/`, quick-switch in popover. There was a fifth, "macOS", that handed the fans back; renaming it from "Auto" and fencing it off behind a divider both failed to stop people reading it as the app's smart mode, and it was removed on 2026-07-26. Every preset now means Ice Cube is driving; turning fan control off is Settings → "Turn Off Fan Control", which removes the daemon (the only thing that actually returns the fans — see the guardian field finding in §4.3).
- Note (2026-07-23): implemented — FanCurve (normalized invariants, 90 tests total incl. property sweep), CurveFollower (hysteresis deadband + ramp limiter), daemon curve loop with read-back verify + wake re-assert + root-owned persistence (/Library/Application Support/IceCube, atomic, schema-validated, manual never persisted), Canvas curve editor (drag/double-click/⌫/arrows, live marker incl. hysteresis preview dot — works simulated), presets quick-switch in popover + user presets JSON. Deviations: per-fan curve editing deferred (model supports per-fan overrides; editor ships linked-all); input-sensor pick-list deferred (input = hottest die sensor); protocol bumped to v2. Owner-pending: Quiet-vs-Max audible check and the reboot-persist test.
- **Accept:** in simulated mode, heating the fake CPU visibly walks the curve with hysteresis; on hardware, a Quiet vs Max preset audibly differs; reboot with "persist" on → curve active before app launch.

### Phase 5 — Modern-app polish
- [x] Settings: launch at login, intervals, units, notifications thresholds, persist-toggle.
- [x] UserNotifications alerts (permission flow handled gracefully).
- [x] CSV export; onboarding; accessibility audit (VoiceOver labels, keyboard-only curve editing); String Catalog; Reduce Motion.
  - No separate History *window* shipped: the charts live in the popover dashboard, and a second window showing the same rows was cut as duplicate surface. CSV export covers the "I want the numbers out" case it was for.
- [x] App icon + menu bar glyph + popover surfaces on system materials. *(2026-07-27: two of the three sub-items were settled differently from this line and the checkbox was simply never updated. **Icon:** ships as `AppIcon.icns` from the Noto artwork, declared final by the owner — Tahoe's Icon Composer `.icon` format remains a nice-to-have, not a gap. **Menu bar glyph:** deliberately NOT a tinted template — it is rendered in colour because "looks like ice" is the brand, and `MenuBarGlyph.swift` records that reasoning. **Surfaces:** `LiquidGlass.swift` builds on `.ultraThinMaterial`; confirmed on macOS 26.4.1.)*
- **Accept:** run through a "new user" script end-to-end without touching the mouse for core flows; VoiceOver can read the dashboard.

### Phase 6 — Open source & releases

- Note (2026-07-23): community docs (README/CONTRIBUTING/CODE_OF_CONDUCT/SECURITY, issue + PR templates), docs/ (SMC-KEYS with field findings, RELEASING, CREDITS, ARCHITECTURE updated), uninstall documented, in-app GitHub-releases update checker (Settings → Updates) all done. REMAINING, owner-gated: notarized public release — paid Apple account. *(2026-07-27: the repo is published at github.com/thijsvos/icecube and CI is active; v0.1.0–v0.1.2 shipped as unsigned prereleases.)*
**Gate:** signing/notarization tasks require a paid Apple Developer account. Until the owner upgrades, do everything else in this phase and distribute unsigned tester builds (XCODE_GUIDE §8 item 4).
- [x] README (feature table, safety section, "why root helper" FAQ, uninstall section — unregister daemon + remove files), CONTRIBUTING, CODE_OF_CONDUCT, SECURITY.md, issue templates (bug + "new Mac model report" using diagnostics JSON), PR template. (LICENSE landed in Phase 0.) *(2026-07-25: CI/licence/platform badges added; download-vs-build-from-source consequences spelled out. **Screenshots still owner-supplied** — the one item here a machine cannot produce.)*
- [x] docs/: ARCHITECTURE.md, SMC-KEYS.md (living key map), RELEASING.md, CREDITS.md.
- [x] Update check: tiny hand-rolled GitHub Releases API version check — compare tags, link to the releases page, **no auto-install, no Sparkle, zero dependencies**. Note: replacing the app replaces the embedded helper; the version handshake (§4.2) detects mismatch and prompts re-register.
- [x] Release workflow: `.github/workflows/release.yml` — tag → gate on tag/version agreement, lint + tests, then **two modes chosen automatically**: with Developer ID secrets it signs, notarizes (`notarytool` with an App Store Connect key), staples and builds a DMG; without them it ships an unsigned zip labelled as such. Always a draft. *(2026-07-25: written ahead of the paid account deliberately, so the upgrade is "add six secrets" rather than "write CI". 2026-07-27: **proven end-to-end** — three tagged runs (v0.1.0, v0.1.1, v0.1.2) built, drafted and published green on real Actions, in the unsigned mode. The signed path is still unexercised. The §4.2 RELEASE pinning is now **implemented**: `CodesignPinning` carries both requirements and picks by reading its own certificate chain at runtime, and both strings were verified with `codesign --verify -R` against real third-party binaries of each kind. Only the combination — our identifier under a Developer ID chain — remains unprovable until the account is upgraded; docs/RELEASING.md carries the hand-verification steps.)*
- [x] CI hardening: lint + tests + build + bundle-layout, plus a **capability-boundary check** (`nm` proves the app binary links no SMC writer — the guarantee that replaced "the writer lives in another target" once DaemonCore moved into IceCubeKit) and a simulated-mode smoke test.
- **Accept:** a clean Mac can download the DMG, pass Gatekeeper, approve helper, and control fans; `v0.1.0` public.

---

## 6. Testing strategy
- **IceCubeKit = the fortress**: codecs (byte-level fixtures from real Macs), curve math (property tests), SafetyMonitor state machine (simulated clock), preset codecs. Target >90 % coverage here; UI coverage is best-effort.
- Simulated mode for all UI dev + CI. **Correction (2026-08-08, precedent #56):** this line promised a `ThermalScenario` script type that was never built. What actually drives repeatable demos is `MockSMCSimulation`'s deterministic schedule — quiet stretches, 30–60 s spikes, roughly one bucket in seven a sustained load, wander damped deep inside steady stretches so the settle rule passes like it does on the real machine (measured: 69 % of simulated ticks settle, in both fan bands).
- Manual HW checklist (docs/TESTPLAN.md): approval flow, watchdog, ceiling override (use scenario injection, don't actually cook the Mac), fast user switching, on owner hardware before each release.
- **Dark-wake gate (2026-07-31, §4.3.6).** The sleep latch may now drop only when a `PowerCapabilities` read positively proves a **full wake** — the `kIOPMSystemCapabilityGraphics` video bit, set on 24 of 24 full wakes and 0 of 176 dark wakes across a week of the owner's `pmset -g log`. Every existing unpark rule keeps its own evidence (the power-on edge, heartbeat-after-a-nap, the missed-wake failsafe) and is AND-ed with that necessary condition, so nothing can unpark that could not unpark before. Three deliberate exceptions and choices: the **temperature ceiling release stays ungated** — it is the one release allowed to make noise in a closed bag, because by then the alternative is heat; the **missed-wake failsafe stands down** inside a confirmed dark wake (`SleepLatch.deferMissedWake()`) instead of releasing after 300 s, which was the second route to the same bug; and a daemon that **starts inside a dark wake** (launchd `KeepAlive`, a crash, `softwareupdate`) loads and reports the persisted curve but writes no fan until a display appears — the boot promise is "the curve is live before the app launches", not "the fans move the instant launchd starts us". The discriminator is deliberately *not* lid state: a docked MacBook driving an external panel reads `AppleClamshellState = Yes` under full load, and gating on that would leave it parked with only the 104 °C ceiling between it and a thermal problem. An unreadable capability is never treated as a wake, but the boot hold and the missed-wake failsafe stay bounded so it cannot mean "parked forever". Reader is `IceCubeHelper/SystemCapabilityReader.swift` (dlsym `IOPMConnectionGetSystemCapabilities`, falling back to `IOPMrootDomain`'s `"System Capabilities"`; measured `0x1F` and `0x0F` respectively on Mac14,9 — they differ only above the video bit). 12 new tests; the headline one was confirmed to fail against the old heartbeat rule.
- **Readable errors, and a config that waits for the wake (2026-08-01, protocol v22).** The owner found `The operation couldn't be completed. (IceCubeKit.IceCubeError error 7.)` in the popover after a lid close. Three defects stacked behind that one line. (1) `HelperService` replied `error as NSError`, and Swift supplies a `LocalizedError`'s message through a lazy userInfo *value provider* that reads the Swift error still boxed inside the bridge — the box does not survive XPC encoding, so **every** `IceCubeError` the app has ever shown was this string with a different number in it. `WireError.wire(_:)` now materialises the description into `userInfo` before the reply, merging rather than replacing so a `DecodingError`'s own debug keys survive, and carries a stable `wireName` (a *name*, because the bridged `code` is the enum's declaration-order tag and inserting a case silently renumbers every matcher below it). (2) `.systemAsleep` is the daemon correctly declining a write while parked — not a failure. The app now classifies it as *deferred*, holds the config, re-sends it on the next healthy maintenance pass, and shows one grey sentence instead of an orange error; nothing else in the app re-sent a config after a wake, so a curve refused during a park was simply never applied until the user happened to click a preset. Manual targets expire after 60 s (`shouldResend`), curves never do. (3) The error slot was the one prose `Text` in the Control card without `.fixedSize`, so any real sentence was clipped at the popover's 380 pt — fixed there and in `PopoverView.errorRow`. Surfaced by the dark-wake gate, which lengthened the parked window from seconds to eight minutes and so turned a rare silent path into a routine one. 15 new tests, including a witness that the bare bridge still loses the message and a mutation-confirmed pair covering the deferral.
- **The daemon sees its own sensors, and the popover stays on screen (2026-08-01).** Two follow-ups from the sensor work, closed. (1) `DaemonCore` still admitted a curated sensor only when a *reading* of it looked plausible, so a power-gated cluster's frozen sentinel disowned every P-core for the daemon's lifetime: the owner's live daemon logged `resolved 8 temperature sensors` and ran on that set for 13 hours — 8 of 20, its only silicon input the two GPU dies, while the 104 °C die ceiling is the one release allowed to spin the fans inside a closed lid. Membership now comes from key existence, probed with a `readDouble` **whose value is discarded** (the error answers both questions, so `SMCControlPort` gains nothing). Deliberately not `port.hasKey`: it is `(try? keyInfo) != nil`, which collapses "no such key" into the same `false` as a transport failure — the distinction the empty-probe rule exists for — and reports no wire type, so a key that decodes to nothing would throw every tick, count as missing every tick, and re-trip the partial-failure re-probe forever. That is where the old dead-key loop would have moved. **The migration was preceded by its own commit of characterization tests**, because a mutation run showed only 2 of the 7 rules in this path were pinned by anything: nine tests, each confirmed to fail against a mutation of its rule, two rules found by reading rather than from the list — and of those nine, exactly one changed semantics under the migration, which is the evidence the other six survived. (2) `PopoverView`'s sensor list was a bare `ForEach` with no height discipline. Measured at 193 sensors: SwiftUI's `MenuBarExtra` does not clamp at all — 380×3113 pt on a 1130 pt screen, bottom edge 1985 pt below the display, taking the footer and with it the app's only Quit; it leaves the screen at **29 sensors**, and Mac14,9 reports 20. Vendored hosting clamps the window and clips the header and fans off the top instead. `SensorListMetrics` now reserves a scroll region sized from the sensor **inventory**, not the rows currently reporting — which also removes the 192 pt self-resize the monotone list performs while the user watches, during the ~85 s a gated cluster takes to report.
- **Sleep/wake acceptance test [HW]:** with a curve (and separately, manual mode) active, sleep the Mac ≥ 1 min, wake → daemon re-asserts control (or reverts and reports "control lost") within one control tick; verified via read-back + `log stream`. Manual control survives sleep in firmware (§3.4), so this must be exercised on hardware, not simulated. Four checks, all on the closed-lid gesture rather than an idle timeout — a lid close is a forced *clamshell* sleep and skips the `kIOMessageCanSystemSleep` round entirely, so an idle-sleep test would pass while the reported bug survived:
  1. **Audible.** Close the lid with a curve engaged; the fans must spin down within about a second.
  2. **Read-back.** Open the lid and run `icecube-diag` immediately: mode must be `auto`/`system`, not `forced`, and the curve must re-engage within a tick or two.
  3. **No sleep regression.** `pmset -g log | grep -iE "Delays to Sleep|Clamshell Sleep"` — `IceCubeHelper` must appear in no delay line, and lid-close → `Entering Sleep state` must stay well under a second.
  4. **A closed-lid night.** Between the evening `Clamshell Sleep` and the morning `Wake … [CDNVA]` there must be **no** `curve engaged`, `holding fans at minimum`, `guardian:` or `SAFETY:` lines — while `pmset -g log` confirms the `DarkWake … [CDNP]` cycles really happened. **SETTLED 2026-07-31, and the pre-registered remedy was wrong.** `kIOMessageSystemHasPoweredOn` is clean: all five `wake: resuming … (the system powered on)` lines land on `[CDNVA]`/`[CDNVAP]` full wakes, including three `DarkWake to FullWake` promotions, and no pure `[CDNP]` ever produced one. The rule that fired on dark wakes was **heartbeat-after-a-nap** (3 of 3 `[CDNP]`/`[CDNPB]` wakes), because the menu-bar app's 5 s timer runs perfectly well inside a dark wake — so gating on `sawNap` would not have helped either: the nap was real. On 00:31:51 an rtc/Maintenance dark wake unparked the daemon and drove both fans to 6800 RPM for 69 s with the lid shut. The remedy is a positive `PowerCapabilities` full-wake determination gating **every** discretionary unpark — see the §4.3.6 note below.

### Cooling efficiency (2026-08-02)

Added system power to the snapshot and derived a cooling-efficiency index (°C/W) from it —
`CoolingEfficiency` in IceCubeKit, a Sensors-window readout, an opt-in chart row,
and `DiagnosticsReport` schema v4. `SMCProviding.power()` had been implemented on
both providers since Phase 1 and called only by `icecube-diag --watch`; this is
what it was for.

**`ProcessInfo.thermalState` was considered and rejected.** It is the obvious way
to ask macOS whether a Mac is struggling, and it is unused repo-wide. Probed on
Mac14,9 before committing to the alternative:

```
$ pmset -g therm
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
```

Zero thermal log lines in six hours. A feature built on it would read "nominal"
forever on the only machine that can verify it. Measuring the physics directly
also keeps us inside §3.4's "SMC keys only, one code path, fewer private-API
risks", which an IOReport-based power reading would not.

Measured on hardware: at a fixed 5950 RPM, R held at 0.89–0.93 °C/W across
21.5–24.0 W — the load-invariance the feature depends on. Fan-speed dependence
measured 2026-08-03 once a stray load was cleared: **1.04–1.13 °C/W at 3550 RPM
against 0.89–0.93 at 5950**, i.e. ~20 % better heat transfer for 68 % more fan.
A third sample that session read 1.89 while the die was still falling, and is
recorded in docs/THERMAL.md as the settle rule earning its keep — an unsettled
quotient measures nothing and looks exactly like a real reading.

### "Why is it hot?" — the diagnosis window (2026-08-07)

Turned the readings into an answer. `ThermalDiagnosis` (pure, in IceCubeKit)
takes a snapshot, the settled `R`, a per-process sample and the daemon's active
curve, and answers four questions — how hot against the 104 °C ceiling, whether
the power drawn explains it, what is producing it, and whether the curve has
cooling left. Shown in its own window, opened from the popover.

**The one new primitive is `proc_pid_rusage`'s `ri_energy_nj`** — cumulative
per-process energy in nanojoules, public SDK surface (`sys/resource.h`), no
entitlement and no root. Differenced over an interval it yields real **watts**,
which is why it was chosen over Activity Monitor's unitless "Energy Impact":
putting a made-up score beside genuine SMC watts would invite a comparison
neither figure supports. Measured on Mac14,9: **410 of 616 PIDs readable
unprivileged, 205 denied** (root-owned, including `kernel_task` and
`WindowServer`).

**The design constraint is that the two power figures must never be conflated.**
System watts come from the SMC (`PSTR`, the whole machine); attributed watts come
from the kernel (CPU energy, readable processes only). They do not sum, and the
window states the remainder rather than hiding it — a real reading was 41.6 W
system against 9.9 W attributed. A truncation bug that summed only the *displayed*
twelve processes instead of all 408 was caught during development; it would have
inflated "unattributed" and understated what the app can account for.

**Two claims are deliberately not made.** Degradation ("your cooling is 18 %
worse") still needs persistence and is still a follow-up. And the one
load-versus-cooling judgement — a hot die below 15 W — is keyed on **watts, not
on `R`**, because `R` is not comparable between machines and this has to hold on
hardware nobody here has measured.

Privacy is a first-class constraint, not a footnote: process names are absent
from the diagnostics JSON, never written to disk, collected only while the window
is open, and discarded on close. `MockProcessSampler` numbers its fake PIDs from
900001 — above Darwin's PID ceiling of 99999 — so a simulated run cannot name a
real process even by coincidence; the first version numbered from 1000, which
this machine reaches (observed to 99423), and the isolation test passed by luck.
Full accounting in docs/DIAGNOSIS.md.

The feature found its own motivating case while being built: two orphaned `yes`
processes had been pinning 100 % CPU for 2 h 52 m, holding the fans at 6800 RPM,
with no screen in the app able to name them.

### Cooling history — the degradation tracker (2026-08-08)

THERMAL.md's "the most valuable one" follow-up, landed: settled °C/W readings
persist across launches (`~/Library/Application Support/IceCube/
cooling-history.json`), are filed under fan-speed bands, and feed a verdict —
*"cooling is 18 % worse than in June"*, its post-cleaning twin, an abrupt-change
warning, or a refusal that names what is missing. The discipline is the
feature: the recording bar sits **above** the display bar (10 W floor, dense
window, fans holding one speed), the trend runs on day-band **medians** (the
settle rule's rare failures all push `R` up — the 1.89 °C/W transient — so a
mean drifts toward exactly the false claim this must never make), the baseline
is the *earliest* qualifying window by rule rather than a search, comparisons
never cross a fan band or a **Mark as Cleaned** boundary, and nothing is
called under 10 % (~4× the measured noise). The file is fingerprinted with a
salted serial hash so Migration Assistant — including a same-model warranty
replacement — sets a foreign history aside instead of inheriting its
degradation; a newer schema loads read-only rather than being overwritten; and
history is deliberately absent from the diagnostics export (a timestamp series
is an attendance record). Surfaces: the Diagnose window's fifth question (the
claim its own doc had filed under "not yet possible"), a trend row in the
Sensors window's Cooling section (+28 pt, metrics updated per that file's
convention), and the Cooling History window — one band at a time, dots not
lines across gaps, axis frozen per window-open, drawn from
`CoolingTrend.seriesByBand`, the same data the verdict judged. Landing it
surfaced and fixed two shipped defects: the settle window was quietly ~40 s
against five documented claims of 20 (the simulated model settled on 0.9 % of
ticks — the °C/W readout was barely demonstrable), and a backward clock step
wedged the tracker's window for the life of the process. The simulated model
gained flat-holds and sustained-load buckets (69 % of ticks now settle, both
fan bands, measured) plus seeded histories
(`ICECUBE_SIMULATED_HISTORY=stable|rising|jump|improved|baseline|sparse`) so
every verdict state is demonstrable and screenshot-able with no hardware.
~150 new tests across the recorder gates, retention invariants (whole-day
pruning exists because the outlier test caught mid-day pruning re-folding a
day down to its own worst transient), the verdict's refusals, the file's
custody, and the copy's honesty rules — mutation-verified per house practice.
Deferred, deliberately: the R-vs-RPM "what the noise buys you" chart (the
schema already carries everything it needs) and any notification for any
trend state (#81's lesson stands).

### The hand-back audit (2026-08-14) — protocol v27

An adversarial audit of the daemon's error paths (six suspected defects sent to
independent verifiers told to *refute* them; six confirmed or partly confirmed,
none refuted, four more found afterwards) turned up **one defect in six places**,
all sharing the worst failure signature this program has: **fans physically
forced while `config.mode == .auto`**, which by construction disarms the watchdog
(`SafetyMonitor.swift:92`), the ceiling (`:77`) and all three FanGuardian filters
(`FanGuardian.swift:285-287`, `:316-318`, `:333-335`) — while the decision
timeline draws the opposite of what happened.

`revertEverything` has caught, throttled and retried its write failures since the
day it was written, and its comment says why. Five siblings never got the memo.
Fixed:

- `FanWriteSequencer.revertAllAuto` returned **silently** when the mode key would
  not resolve — zero writes, no throw, from a `throws` method whose contract is
  that failures are reported. Now it throws, and the suffix-independent half of
  the hand-back (parking `Tg` at the floor) happens either way.
- The guardian's `.release` and `.reparkOrphans` branches recorded their sentence
  *before* writing and swallowed the result in `try?`. Now they write first,
  report what landed, and `.release` sets `revertPending` so the tick's existing
  deferred-revert retry converges.
- **`shutdown()` returned `Void` and `main.swift` called `exit(0)` regardless** —
  after cancelling the tick that `revertEverything` was relying on to retry. On
  the uninstall path (`unregister()` SIGTERMs the daemon *and* removes the job)
  that stranded the fans with no daemon, no safety nets and no way back short of
  a reboot. It now returns `Bool`, the SIGTERM handler retries within a declared
  `ExitTimeOut`, and exits non-zero so `KeepAlive/SuccessfulExit` brings it back.
- The app dropped `setAllAuto`'s failure during uninstall, and skipped the call
  entirely when merely `.disconnected` — leaving the boot promise on disk for the
  next install to resume.
- **Self-heal wiped the user's chosen curve.** `reregister()` → `unregister()` →
  `memory.forgetEverything()`, and `maintain()` self-heals automatically on
  `.versionMismatch` — the designed upgrade path — so *every* app update that
  bumped `protocolVersion` silently reset the user to Balanced.
  `unregister(forgettingIntent:)` now distinguishes a repair from a decision.

Also proven, having been documented but not: the ceiling debounce is
**consecutive** (`overCeilingTicks = 0` survived deletion — the existing test's
cool tick is followed by three more hot ones and it only inspects the third), and
revert-on-XPC-invalidation applies to a **non-persisting curve** (every existing
test of that path used `manualConfig()`, so the clause could be deleted with CI
green). Every test added here was mutation-verified.

Still open, and deliberately out of scope: the release-pipeline items found
alongside — hardened runtime is off on both targets so `notarytool` will reject
the first signed build; the DMG is never signed, notarized or stapled; and the
`Restarting after` tripwire that commit `ee223fe`'s message claims to have added
exists in no commit in history.

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

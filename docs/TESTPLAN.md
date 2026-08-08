# TESTPLAN.md — the manual hardware checklist

Referenced by PLAN.md §6 as the pre-release gate, and missing from the repo
until 2026-08-08. Everything in it was already written down; it was scattered
across PLAN.md's phase notes, which is not somewhere you can work through with
a Mac in front of you.

**Run this on the owner's Mac before tagging a release.** CI cannot: there is no
SMC on a GitHub runner, no root daemon, no lid, and no sleep. Everything below
is a thing only real hardware can answer.

## What this does *not* cover, and why

Say this out loud so nobody looks for a step that cannot exist.

- **The temperature ceiling cannot be triggered here.** PLAN.md says "use
  scenario injection, don't actually cook the Mac" — but scenario injection
  lives in `DaemonCoreTests`, driving `DaemonCore` against scripted fake
  firmware. There is no runtime injection into the shipping daemon, by design:
  a way to tell a root daemon "pretend it is 110 °C" is a way to make it spin
  your fans. So the ceiling is proved by unit test, and what you check on
  hardware is the *plumbing* underneath it — §4 below, that the daemon really
  sees die sensors. A ceiling that fires on sensors the daemon never admitted
  protects nothing, and that exact failure shipped once.
- **Anything that needs a second Mac model.** Only Mac14,9 (M2 Pro) is verified.
  M1/M3/M4/M5 write paths are implemented from research and have never run.
- **Notarization and Gatekeeper.** Needs the paid account.

## Before you start

```sh
# A signed build, installed to /Applications. Release, not Debug.
sh scripts/install.sh

# The daemon's own log. Use the absolute path: `log` is shadowed in this
# shell, and a shadowed `log` returns nothing, which reads exactly like a
# daemon that said nothing.
/usr/bin/log stream --predicate 'subsystem == "io.github.thijsvos.icecube"' --info
```

Note the subsystem: a simulated run and the test suites deliberately log to
`io.github.thijsvos.icecube.tests` instead, so the stream above is the real
daemon and nothing else.

Keep `swift run icecube-diag` handy in a second terminal — it reads the SMC
directly and needs no root, so it is the independent witness for every claim
the app makes.

---

## 1. Approval flow (needed after any protocol bump)

- [ ] Fresh install on a machine that has never approved the helper: the setup
      window appears on its own and advances **without being clicked** as you
      approve in System Settings.
- [ ] Approve → the window reaches `ready` and fan control works.
- [ ] **Protocol bump case.** After installing a build whose
      `HelperConstants.protocolVersion` differs, the app must notice and
      re-register. This is the one that has bitten: installing a new app does
      **not** restart the running daemon, launchd keeps the old one, and the
      version string is the only thing that triggers re-registration.
      `docs/RELEASING.md` records the incident — the dark-wake safety fix was
      "deployed" while the fans went on being driven by the daemon it was
      written to stop.
- [ ] Settings → Fan Control → **Check Fan Control** returns a clean verdict.

## 2. Watchdog

- [ ] With **manual** (fixed-RPM) control active, quit Ice Cube.
- [ ] Within ~15 s the fans return to system control. Confirm with
      `icecube-diag`: mode is `auto`/`system`, not `forced`.
- [ ] With a **curve** active and "Keep the curve running when Ice Cube quits"
      **on**, quit the app: the curve keeps running. This is the one case that
      survives app exit, and manual mode must never behave this way regardless
      of that toggle.

## 3. Sleep / wake — use the lid, not an idle timeout

A lid close is a forced *clamshell* sleep and skips the
`kIOMessageCanSystemSleep` round entirely, so an idle-sleep test passes while
the reported bug survives. All four checks are on the closed-lid gesture.

- [ ] **Audible.** Close the lid with a curve engaged; the fans spin down
      within about a second.
- [ ] **Read-back.** Open the lid and run `icecube-diag` immediately: mode is
      `auto`/`system`, and the curve re-engages within a tick or two.
- [ ] **No sleep regression.**
      `pmset -g log | grep -iE "Delays to Sleep|Clamshell Sleep"` —
      `IceCubeHelper` appears in no delay line, and lid-close → `Entering Sleep
      state` stays well under a second.
- [ ] **A closed-lid night.** Between the evening `Clamshell Sleep` and the
      morning `Wake … [CDNVA]` there must be **no** `curve engaged`, `holding
      fans at minimum`, `guardian:` or `SAFETY:` lines — while `pmset -g log`
      confirms the `DarkWake … [CDNP]` cycles really happened. This is the
      check that caught a dark wake driving both fans to 6800 RPM for 69 s with
      the lid shut.

## 4. The daemon can see its own sensors

The ceiling and the guardian are only as good as the sensor set the daemon
admitted, and a daemon that probed while the machine was idle once resolved 8
of 20 — its only silicon input the two GPU dies — and ran that way for 13 hours.

- [ ] In the log stream, find the daemon's `resolved N temperature sensors
      (model …)` line. On Mac14,9, **N must be 20**, and the model must be the
      real one.
- [ ] Cross-check the app's own read path, which resolves sensors separately:
      `icecube-diag` prints `Sensors: N reporting of M discovered`. On Mac14,9
      that reads `20 reporting of 20 discovered` once the clusters are awake.
      The two numbers come from different code and should agree; if the daemon
      sees fewer than the CLI does, the ceiling is guarding a smaller set than
      you think.
- [ ] Put the machine under load for a minute (a build, or `yes` in a few
      shells — **and kill them afterwards**), then confirm the P-core `Tp…`
      sensors are among those reported.

## 5. Fast user switching

- [ ] Switch to a second account and back. The daemon keeps running (it is
      system-scoped, not per-user); the app reconnects and shows live values.
- [ ] No duplicate daemon, no orphaned control: `icecube-diag` agrees with the
      app about the current mode.

## 6. Presets and curves

- [ ] Each built-in preset applies, and the fans audibly change between Quiet
      and Max.
- [ ] Save a custom curve. It appears in the popover preset row, in Settings →
      Active preset, and in ⌥-click cycling.
- [ ] Delete it from the popover's context menu; it disappears everywhere.
- [ ] Save over an existing name → confirmation appears before it replaces.
- [ ] Unplug / replug power with the power rule enabled: the preset switches.

## 7. Housekeeping

- [ ] Menu bar reading matches `icecube-diag` (within a tick).
- [ ] Settings → Turn Off Fan Control removes the daemon; the fans return to
      macOS and `icecube-diag` confirms `auto`.
- [ ] Reinstall works after that without a reboot.

## Cooling history

- [ ] After a stretch of steady use, the Sensors window's Cooling section
      shows a trend line and the Cooling History window shows readings; quit
      and relaunch Ice Cube — the reading count survives.
- [ ] **Clear History** empties it after its confirmation, and the verdict
      returns to "Building a baseline" / "No readings yet".
- [ ] `ICECUBE_SIMULATED=1` with `ICECUBE_SIMULATED_HISTORY=jump` shows the
      abrupt-change verdict with the warning triangle, and the real
      `cooling-history.json` is untouched afterwards.

---

## Recording the result

Tick the boxes in the release PR, or say which you skipped and why. A skipped
check that nobody mentions is indistinguishable from a passed one — which is
the failure mode this whole file exists to prevent, and the same one that let
`verify-bundle.sh` report a green guarantee it had never tested.

# XCODE_GUIDE.md — The human's handbook for Ice Cube

Everything Claude Code *can't* do for you lives here: installing Xcode, identity/signing, approving the root helper, debugging it, and shipping notarized releases. Written for someone who has never fought Xcode before. Menu names drift slightly between macOS/Xcode versions — the flow doesn't.

**Daily TL;DR**
- Build/run UI work: no Xcode needed — `ICECUBE_SIMULATED=1`, commands in CLAUDE.md.
- Anything touching the real helper: open Xcode, run the **Ice Cube** scheme, and if the helper misbehaves after a rebuild → Debug menu → **Re-register helper**.
- Signing errors? 90 % of the time: `Configs/Local.xcconfig` is missing or stale (re-run `scripts/set-team.sh`), or you changed a setting in Xcode's GUI and a regeneration wiped it. See §7.

**Brand new to Xcode? Learn only these three things today** — pick up everything else on demand:
1. The **scheme selector** in the top toolbar: it picks *what* runs. You'll toggle between "Ice Cube (Simulated)" and "Ice Cube".
2. **⌘B** builds, **⌘R** builds and runs, **⇧⌘K** cleans when things get weird.
3. The project file is **generated**: `IceCube.xcodeproj` is disposable output that XcodeGen rebuilds from the committed `project.yml`. Anything you change in Xcode's settings GUI gets silently wiped on the next regeneration — so *never* change build settings there. Settings live in `project.yml`; your signing Team lives in a gitignored file that a one-time script writes for you (§2).

Everything else, let Claude Code drive — and paste any error message you don't understand straight into it.

---

## 1. One-time machine setup
1. Install **Xcode** from the Mac App Store (big download; get coffee). Launch once so it installs components.
2. Terminal:
   ```bash
   xcode-select --install                 # command line tools (ok if it says already installed)
   sudo xcodebuild -license accept
   xcodebuild -version                    # sanity check
   ```
3. Xcode → **Settings → Accounts** → `+` → sign in with your Apple ID.
   - **Free Apple ID**: gives you a "Personal Team". Confirmed fine for **building and running** everything — simulated and real. The one *unproven* part is macOS **approving the root helper** under a free ID: a 15-minute spike (the very first run in §4) settles it. If that spike fails, the fallback is a **manually installed daemon** — you run a provided script with `sudo` — until you go paid. Free-ID limits regardless: no notarization, apps you give to others get scary Gatekeeper warnings, certs expire quickly.
   - **Apple Developer Program ($99/yr)**: needed for Phase 6 (Developer ID signing + notarization = clean installs for the public).

## 2. First open of the project
1. Install XcodeGen (one-time): `brew install xcodegen` — or just `brew bundle` in the repo root; a `Brewfile` is provided.
2. Generate the project: `xcodegen generate` (repo root). Run it again whenever `project.yml` changes or files are added — it's cheap, and Claude Code usually has already done it for you.
3. `open IceCube.xcodeproj`.
4. **Set your Team — once, with the script, not the GUI**: run `scripts/set-team.sh`. It writes `DEVELOPMENT_TEAM` into the gitignored `Configs/Local.xcconfig`, which both targets pick up automatically (same Team on both = XPC pinning happy). Do **not** pick a Team in Signing & Capabilities — the next `xcodegen generate` throws that away, and you're back to mystery signing errors.
5. If Xcode offers to **upgrade or convert the project** to a newer format — **decline**. The project is regenerated from `project.yml`; any conversion gets wiped and only causes churn.
6. Bundle IDs are already the real ones (`io.github.thijsvos.icecube` and friends) — there is nothing to rename.
7. Sanity-check (look, don't touch): select the **Ice Cube** target → **Signing & Capabilities** — "Automatically manage signing" ✅, your Team shown, and **no App Sandbox capability** (sandboxed apps can't open the SMC or install daemons; Hardened Runtime ON is fine and required for release). Same check for **IceCubeHelper**.
8. Product → Build (⌘B). First build resolves the local IceCubeKit package; be patient.

## 3. Running in simulated mode (no root, no approvals)
Scheme selector (top bar) → **Ice Cube (Simulated)** → ⌘R. That's it — the scheme ships pre-generated from `project.yml` with `ICECUBE_SIMULATED=1` already baked in, so there is nothing to edit. You should see the menu bar item with fake-but-lively data. This is the mode for all UI/chart/curve work.

## 4. Real hardware: approving the helper (Phase 3+)
The helper is a **LaunchDaemon registered via SMAppService** — macOS makes you bless it once.

**Your first pass through this section IS the spike.** Whether macOS will approve a root helper signed with a free Apple ID is the project's single riskiest unknown: one credible source flatly says it needs a paid account, Apple's own guidance suggests a free Apple Development cert should work, and nobody has confirmed it first-hand. So the first run happens *early*, with a deliberately do-nothing helper, and takes about 15 minutes. Succeeds → the free-ID path is proven and everything proceeds as designed. Fails → no drama: the fallback is a **manually installed daemon** (you run a provided script with `sudo` after each helper rebuild) until/unless you upgrade to a paid account.

1. **Run the app from /Applications for helper testing.** Product → Build, then drag the built app there (Product → Show Build Folder in Finder → Products/Debug), or use the `scripts/install.sh` Claude Code provides. Registering daemons from Xcode's DerivedData path is flaky and every rebuild changes the binary anyway.
2. Launch Ice Cube. Heads-up: it's an **LSUIElement** app — **no Dock icon, ever**; the menu bar item is the only UI, so look up, not down. Go through onboarding → **Enable fan control**. macOS shows a notification / takes you to **System Settings → General → Login Items & Extensions** (older: "Login Items"). Toggle **Ice Cube** ON under "Allow in the Background"; enter your admin password if asked.
3. Back in Ice Cube, helper status should read *enabled*, and the Debug menu → Helper Status shows a version. Try a manual fan slider — you should hear it.
4. **After every rebuild of the helper**, macOS may still run the *old* registered copy. Fix: Ice Cube Debug menu → **Re-register helper** (it unregisters + registers; once approved, re-registering doesn't re-prompt for your password). This is the #1 "why isn't my change live" trap.

## 5. Signing & entitlements — the 3-minute mental model
- **Code signing** = cryptographic identity on every binary. Xcode's "Automatic" handles day-to-day.
- **Why no sandbox**: sandboxed apps can't open the SMC or install daemons. This is normal for hardware utilities and why we ship outside the App Store.
- **Hardened Runtime** (release requirement for notarization): fine for us; we need no exceptions.
- **XPC pinning**: app and helper each verify the other's signature is *your Team*. This is why both targets must share the Team, and why an unsigned CI build can't talk to a real helper (by design — CI is simulated-only).
- Your **Team ID** (10 chars): Xcode → Settings → Accounts → your team → Membership details, or `grep`-able from the built app: `codesign -dv --verbose=2 path/to/Ice Cube.app` (look at `TeamIdentifier=`). Careful: it is **not** the parenthesized suffix in your certificate's display name ("Apple Development: you@… (XXXXXXXXXX)") — trust `TeamIdentifier=`. The Team lives only in the gitignored `Configs/Local.xcconfig`, written by `scripts/set-team.sh` — if you ever switch teams, re-run the script and tell Claude Code (the pinning requirement embeds it).

## 6. Debugging like you mean it
- **App**: normal Xcode debugging (⌘R, breakpoints). One quirk: **LSUIElement behavior only manifests on a clean launch, not an Xcode stop/start** — so if Dock-icon or focus behavior looks wrong, quit the app fully and relaunch it before believing what you see.
- **Helper (a root daemon — different rules):**
  - Logs first: `log stream --predicate 'subsystem == "io.github.thijsvos.icecube"' --level debug` (or Console.app, search the subsystem). Every SMC write is logged with key/value/reason — read this before anything else.
  - Attach a debugger: Xcode → Debug → Attach to Process by PID or Name… → `IceCubeHelper` (Xcode will ask to take you root). Or set the *helper* scheme's Run → "Wait for the executable to be launched", then trigger it from the app.
  - Is it even running? `sudo launchctl print system/io.github.thijsvos.icecube.helper`.
- **Inspect Background Task Management** (what SMAppService talks to): `sfltool dumpbtm | less` — search for icecube. Nuclear reset: `sudo sfltool resetbtm` (⚠️ resets approvals for *every* app on the Mac; you'll re-approve things — last resort only).
- **Fans stuck after a crash?** They auto-revert (watchdog), but belt-and-braces: relaunch Ice Cube → preset **Auto**, or reboot — SMC returns to system control.

## 7. Troubleshooting table
| Symptom | Likely cause → fix |
|---|---|
| `register()` throws "Operation not permitted" / SMAppServiceErrorDomain | Running from DerivedData, or plist filename/Label/BundleProgram don't all match, or helper unsigned/different team → run from /Applications, re-check the four names, same Team, rebuild |
| Toggle in Login Items flips back OFF | Stale BTM state → Re-register from Debug menu; if still stuck, `sudo sfltool resetbtm`, reboot, approve again |
| Registration/toggle broken on macOS 26.4.x, `backgroundtaskmanagementd` at high CPU | Known OS bug in 26.4 — not your code → update macOS if a newer point release exists; otherwise `sudo sfltool resetbtm` + reboot (⚠️ resets approvals for **every** app — last resort) |
| XPC pinning suddenly fails near **2026-08-15** with no code change | Apple Development cert auto-renewed (free-ID certs are short-lived) → rebuild + Debug menu → Re-register helper |
| Helper enabled but XPC connects then instantly invalidates | Codesign pinning rejecting: teams differ, or DEBUG vs release requirement mismatch → confirm both targets' Team; check helper log for the rejection line |
| Slider moves, fans don't | Wrong write path for your architecture, or values out of clamp → check helper log read-back lines; run Sensors browser and confirm `F0Mn/F0Mx` look sane |
| "Ice Cube is damaged and can't be opened" on another Mac | Unsigned/un-notarized build + quarantine → recipient runs `xattr -dr com.apple.quarantine /Applications/Ice Cube.app` (dev builds only) — or do §8 properly |
| Build suddenly weird after big changes | Clean build folder (⇧⌘K), delete `~/Library/Developer/Xcode/DerivedData/IceCube-*`, retry |
| Notifications never appear | macOS denied permission → System Settings → Notifications → Ice Cube → Allow |
| No temps on your model | Key map gap → Sensors browser → Export diagnostics → open a "new Mac model" issue (or feed the JSON to Claude Code) |

Standing habit: **after each macOS 26.x point release, do a quick status-item smoke test** — run the Simulated scheme, confirm the menu bar item appears and its popover opens. Tahoe point releases have broken menu-bar apps before.

## 8. Releasing to the world (paid account; Phase 6)
One-time:
1. developer.apple.com → Certificates → create **Developer ID Application** cert (Xcode → Settings → Accounts → Manage Certificates… can do it too).
2. Store notarization credentials for `notarytool` — pick **one** of the two auth methods; both end in the same keychain profile, so the per-release commands never change.

   **Option A — App Store Connect API key** (recommended: scoped, revocable, no password to rotate). App Store Connect → Users & Access → **Integrations → App Store Connect API** → create a key (role: Developer), download the `.p8`:
   ```bash
   xcrun notarytool store-credentials "icecube-notary" \
     --key ~/keys/AuthKey_XXXXXXXXXX.p8 \
     --key-id "XXXXXXXXXX" \
     --issuer "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
   ```

   **Option B — app-specific password** (quicker to set up). Generate at account.apple.com → Sign-In and Security → App-Specific Passwords:
   ```bash
   xcrun notarytool store-credentials "icecube-notary" \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID" \
     --password "app-specific-pw"
   ```

Per release (scripted in `scripts/release.sh` + CI, but know the moves):
   ```bash
   xcodebuild -project IceCube.xcodeproj -scheme IceCube -configuration Release archive -archivePath build/Ice Cube.xcarchive
   # export with Developer ID (Xcode Organizer → Distribute App → Direct Distribution, or exportOptions.plist in CI)
   ditto -c -k --keepParent build/export/Ice Cube.app build/Ice Cube.zip
   xcrun notarytool submit build/Ice Cube.zip --keychain-profile icecube-notary --wait
   xcrun stapler staple build/export/Ice Cube.app
   # then package the *stapled* app into the DMG (create-dmg via Homebrew)
   ```
3. Upload the DMG to a **GitHub Release** with a semver tag (e.g. `v1.2.0`). That's the entire update pipeline: the app's built-in update check is a tiny hand-rolled call to the GitHub Releases API that compares versions and shows a "new version available — open release page" link. No auto-install, no appcast, no signing keys to manage — the release tag is the single source of truth.
4. Free-account interim option: share unsigned builds with the `xattr` incantation above and a warning — fine for testers, not for the public.

## 9. Mini-glossary
**SMC** — the controller chip that owns fans/sensors. **Entitlements** — declared app permissions baked into the signature. **Notarization** — Apple malware-scans your app so Gatekeeper trusts it. **LaunchDaemon** — root background process managed by launchd. **XPC** — Apple's IPC; our app↔helper phone line. **BTM** — Background Task Management, the System Settings machinery that approves the helper. **DerivedData** — Xcode's build cache; deleting it fixes ghosts. **XcodeGen** — the tool that generates `IceCube.xcodeproj` from the committed `project.yml`; the project file is disposable output, never edited by hand.

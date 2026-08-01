# Releasing Ice Cube

Releases are automated by `.github/workflows/release.yml`, triggered by pushing
a `v*` tag. The workflow picks its own mode:

| Developer ID secrets | Artifact | Release marked |
| --- | --- | --- |
| present | signed + notarized + stapled `.dmg` | draft |
| absent (today) | unsigned `.zip` | draft + pre-release |

Either way the release is created as a **draft** — nothing goes public until
you read the generated notes and press publish.

## Repo setup (done 2026-07-27, kept as a record)

The repo went public at github.com/thijsvos/icecube. These were configured via
the API at the time; they are listed so a future maintainer (or a fork) knows
what the committed config assumes rather than discovering it by breakage:

- [x] **Allow auto-merge** — `dependabot-auto-merge.yml` cannot queue a merge
      without it, and every routine bump would wait on a human forever.
- [x] **Dependabot alerts + security updates** — free on public repos, and the
      only vulnerability surface here is GitHub Actions.
- [x] **Branch protection on `main` requiring `build-and-test`** — auto-merge
      merges when *required* checks pass; with none required it merges
      immediately, which defeats the gate. Admins can still push directly, on
      purpose, so an emergency fix is not blocked.
- [x] `docs/img/` holds `popover.png`, `curve-editor.png`, `sensors.png` and
      `first-run.png`; `README.md` links all four.
- [ ] *Still open, optional:* a shot of the setup window for "First run". It
      can only be taken while fan control is **off** (with it on there is no
      setup entry point at all), so the free moment is a clean-machine install
      test — not unregistering a working daemon to stage a photo.
- [ ] *Stale since 2026-08-01:* `sensors.png` and `popover.png` were taken on
      2026-07-26 and show UI that no longer ships. The Sensors window now sizes
      itself to the sensor inventory rather than to a hardcoded 560×480, and the
      popover's sensor list now has a bounded scroll region sized from the
      inventory instead of an unclamped `ForEach`. Retake both from a machine
      that has been under load long enough to report all its sensors — an idle
      launch used to photograph as few as 8 of Mac14,9's 20.

## Version bump checklist

1. `project.yml` → `CFBundleShortVersionString` (and `CFBundleVersion`).
   The workflow **refuses to build** if the tag and this value disagree, so a
   build can never be labelled one version while reporting another.
2. `HelperConstants.protocolVersion` — bump it whenever the **daemon's
   behaviour** changed, not only when the XPC surface did. Users must then
   re-register the helper, and the app's version-handshake UI walks them
   through it. Getting this wrong ships a fix that never reaches anyone's fans;
   see below.
3. `xcodegen generate`, then a full test + lint pass locally.
4. Tag and push:

   ```bash
   git tag v0.1.0
   git push origin v0.1.0
   ```

5. Watch Actions → Release. On success, edit the draft's notes and publish.

The notes are generated from commit subjects since the previous tag (`chore:`
and `ci:` commits filtered out), with a safety summary and — in unsigned mode —
the Gatekeeper caveat prepended.

### A daemon-only fix still needs a protocol bump

Installing a new app does not restart the running daemon. launchd keeps the old
one, and the version string is the only thing that tells the app to offer a
re-registration — so a behaviour-only fix shipped without a bump installs a new
app beside the old, unfixed daemon, and nothing anywhere says so. The app logs
`setup: not shown` and looks perfectly healthy, because from its side the
versions match.

This is not hypothetical. It is how the dark-wake safety fix was first
"deployed": the fans went on being driven by the daemon it was written to stop.
v21 and v22 were both bumped with a byte-identical interface for exactly this
reason. **If the daemon binary would behave differently, bump it — protocol
change or not.**

The rule and the recent changelog live on the constant itself in
[`HelperProtocol.swift`](../IceCubeKit/Sources/IceCubeKit/Helper/HelperProtocol.swift);
older entries are in [PROTOCOL-HISTORY.md](PROTOCOL-HISTORY.md). Read the last
few before adding one — the rule sitting above them was written after this went
wrong.

The workflow notices a bump between tags and prepends an "Upgrading from …"
section to the notes, pointing users at **Update Now**. It reports what you did.
It cannot tell you what you should have done.

## Today: unsigned releases (free Apple ID)

Notarization requires a paid Developer account. Until then the workflow ships
an unsigned zip and says so loudly in the release notes, because the
consequences for a downloader are real:

- Gatekeeper refuses the app until they clear quarantine
  (`xattr -dr com.apple.quarantine "/Applications/Ice Cube.app"`).
- **Helper registration only works on a Mac that trusts the signing identity**,
  which in practice means the machine that built it. Remote testers get
  monitoring; for fan control they must build from source.

Say both things in every release announcement, not just the generated notes.

## Switching on signed releases

When the Developer ID upgrade lands, add these repository secrets
(Settings → Secrets and variables → Actions). No workflow edit is needed — the
signed path activates as soon as the certificate and notary key are both
present.

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | base64 of the exported *Developer ID Application* `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | that export's password |
| `DEVELOPER_ID_TEAM_ID` | your 10-character team ID |
| `NOTARY_KEY_P8` | base64 of the App Store Connect API `.p8` key |
| `NOTARY_KEY_ID` | the key's ID |
| `NOTARY_ISSUER_ID` | the issuer UUID |

Produce the base64 blobs with `base64 -i cert.p12 | pbcopy`. Never commit any
of these files; the repo's `.gitignore` does not know about them, so keep them
outside the working tree entirely.

See XCODE_GUIDE §8 for obtaining the certificate and the notary key.

### Code signing pinning — no change needed, but verify it

This used to be a required code change. Since 2026-07-27 `CodesignPinning`
carries **both** requirements and picks between them by reading its own
certificate chain:

| signed with | requirement imposed on the peer |
| --- | --- |
| Apple Development | WWDR intermediate `6.2.1` + team OU |
| Developer ID Application | Developer ID CA `6.2.6` + leaf marker `6.1.13` + team OU |

Detection is at runtime, not `#if DEBUG`, because Release builds are signed
with Apple Development today — a compile-time switch would break
`scripts/install.sh` the day it landed — and because a fork with its own
Developer ID must not have to edit pinning code.

The two are not interchangeable: ship a Developer ID build against the
development requirement and the app and its helper refuse to talk to each
other, which presents as "connecting…" forever in the popover with nothing
saying why.

**What is proven, and what isn't.** Both strings were checked with
`codesign --verify -R` against real third-party binaries — a Developer
ID-signed app matches the distribution requirement and not the development one,
and Ice Cube's own Apple Development build matches the development one and not
the distribution one. What cannot be proven until the account is upgraded is
the *combination*: our identifier and our Team ID under a Developer ID chain.

So on the first Developer ID build, verify by hand before shipping:

```bash
codesign -d -r- "/Applications/Ice Cube.app"        # dump the real requirement
codesign --verify -R="<the distribution requirement>" "/Applications/Ice Cube.app"
```

Then install it and confirm the popover reaches "connected" rather than
"connecting…". `CodesignPinningTests` covers the string shapes and that each
variant selects its own.

## Rolling back

Draft releases can simply be deleted. If a published release turns out bad:
delete the release (the tag can stay), fix forward, and cut a new patch
version — the in-app update check lists `/releases` and offers the highest
version it finds, so removing the bad release is enough to stop offering it.

It lists rather than reading `releases/latest` on purpose. `latest` excludes
prereleases, and every release here is one, so that endpoint returned 404 and
the check reported "up to date" to everyone forever (#12). Marking a release
as latest is not an escape either — GitHub refuses that flag on a prerelease.
Drafts are excluded by the client, which is why deleting a bad release works
but merely un-publishing it back to draft also would.

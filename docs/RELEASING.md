# Releasing Ice Cube

Releases are automated by `.github/workflows/release.yml`, triggered by pushing
a `v*` tag. The workflow picks its own mode:

| Developer ID secrets | Artifact | Release marked |
| --- | --- | --- |
| present | signed + notarized + stapled `.dmg` | draft |
| absent (today) | unsigned `.zip` | draft + pre-release |

Either way the release is created as a **draft** — nothing goes public until
you read the generated notes and press publish.

## Before the FIRST public push

- [ ] `docs/img/` contains `popover.png`, `curve-editor.png`, `sensors.png`
      and `first-run.png`. `README.md` links to all four, so a missing one shows a
      broken image to everyone who opens the repo. See
      [docs/img/README.md](img/README.md) for how to capture them.
- [ ] *Optional:* a shot of the setup window for the "First run" section. It
      can only be taken while fan control is **off** (with it on, Settings
      offers "Reinstall" and there is no setup entry point at all), so the
      free moment to take it is during a clean-machine install test — not by
      unregistering a working daemon for a photo.

## Version bump checklist

1. `project.yml` → `CFBundleShortVersionString` (and `CFBundleVersion`).
   The workflow **refuses to build** if the tag and this value disagree, so a
   build can never be labelled one version while reporting another.
2. If the XPC surface or `FanConfig` semantics changed:
   `HelperConstants.protocolVersion` — users must re-register the helper, and
   the app's version-handshake UI walks them through it.
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

### One code change is still required

`CodesignPinning.developmentRequirement` builds the **TN3127 development**
requirement (WWDR intermediate, marker `1.2.840.113635.100.6.2.1`). Developer
ID-signed builds need the *distribution* variant instead — markers `6.2.6` plus
leaf `6.1.13`. The two are not interchangeable: ship a Developer ID build
against the development requirement and the app and its helper will refuse to
talk to each other, which presents as "connecting…" forever in the popover.

`CodesignPinningTests` asserts the current shape, so that test is the thing to
update alongside the requirement string.

## Rolling back

Draft releases can simply be deleted. If a published release turns out bad:
delete the release (the tag can stay), fix forward, and cut a new patch
version — the in-app update check reads `releases/latest`, so removing the bad
release is enough to stop offering it.

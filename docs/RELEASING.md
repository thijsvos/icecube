# Releasing Zephyr

## Version bump checklist

1. `project.yml` → `CFBundleShortVersionString` (and `CFBundleVersion`).
2. If the XPC surface or `FanConfig` semantics changed:
   `HelperConstants.protocolVersion` — users must re-register the helper, the
   app's version-handshake UI walks them through it.
3. `xcodegen generate`, full test + lint pass, update CHANGELOG section in
   the GitHub release notes.

## Current process (free Apple ID — interim)

Notarization needs a paid Developer account; until then releases are
**unsigned tester builds**:

```bash
git tag v0.x.y && git push --tags
xcodegen generate
xcodebuild -project Zephyr.xcodeproj -scheme Zephyr -configuration Release \
  -derivedDataPath build build          # signed with your dev cert (local use)
ditto -c -k --keepParent build/Build/Products/Release/Zephyr.app build/Zephyr-v0.x.y.zip
```

Attach the zip to a GitHub Release. Testers on other Macs must clear
quarantine (`xattr -dr com.apple.quarantine /Applications/Zephyr.app`) and
will see Gatekeeper warnings — say so in the release notes, every time.
Dev-cert-signed builds only run helper registration on Macs that trust the
cert, i.e. effectively the dev machine; remote testers should build from
source until notarization lands.

## Future process (paid account — Phase 6 completion)

Per XCODE_GUIDE §8: Developer ID cert → `notarytool store-credentials` →
archive, export with Developer ID, `notarytool submit --wait`, `stapler
staple`, package the *stapled* app into a DMG, attach to the release. Then a
GitHub Actions release workflow can do it on tag push (cert + notary key as
repo secrets). The in-app update checker (Settings… → Updates) reads
`releases/latest` — no appcast, no keys, nothing else to maintain.

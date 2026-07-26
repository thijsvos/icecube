#!/bin/sh
# install.sh — build a SIGNED Ice Cube and install it to /Applications.
#
# Defaults to a RELEASE build, because this is the script the README points new
# users at and a Debug build is the wrong thing to run all day: unoptimized
# Swift, assertions live, and measurably more CPU for an app whose whole pitch
# is being invisible in Activity Monitor. It used to be Debug-only, named
# install-debug.sh, which quietly made "follow the README" mean "run the slow
# build forever".
#
#   scripts/install.sh            release build (what users want)
#   scripts/install.sh --debug    debug build (what contributors want when
#                                 testing daemon changes — see CONTRIBUTING.md)
#
# Registering the daemon from Xcode's DerivedData path is flaky (XCODE_GUIDE §4);
# run this, then launch Ice Cube from /Applications.
set -eu
cd "$(dirname "$0")/.."

CONFIG=Release
case "${1:-}" in
    --debug) CONFIG=Debug ;;
    "") ;;
    *) echo "usage: $0 [--debug]" >&2; exit 2 ;;
esac

if [ ! -f Configs/Local.xcconfig ]; then
    echo "error: Configs/Local.xcconfig missing — run scripts/set-team.sh <TEAMID> first." >&2
    exit 1
fi

echo "==> Generating project"
xcodegen generate

echo "==> Building (signed, $CONFIG)"
BUILD_LOG=$(mktemp)
if ! xcodebuild -project IceCube.xcodeproj -scheme IceCube -configuration "$CONFIG" \
    -derivedDataPath build build > "$BUILD_LOG" 2>&1; then
    # NEVER install a stale artifact: a failed build must abort loudly
    # (a leftover app bundle from an earlier build would pass a mere
    # existence check and silently ship old code).
    echo "error: BUILD FAILED — first errors:" >&2
    grep -E " error:" "$BUILD_LOG" | head -10 >&2
    rm -f "$BUILD_LOG"
    exit 1
fi
grep -E "warning: code sign" "$BUILD_LOG" || true
rm -f "$BUILD_LOG"

APP="build/Build/Products/$CONFIG/Ice Cube.app"
if [ ! -d "$APP" ]; then
    echo "error: build reported success but no app bundle exists." >&2
    exit 1
fi

echo "==> Verifying signature"
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|Authority" || {
    echo "error: app is unsigned — the helper cannot be registered. Fix signing first." >&2
    exit 1
}

echo "==> Installing to /Applications (quitting any running copy)"
pkill -x "Ice Cube" 2>/dev/null || true
rm -rf "/Applications/Ice Cube.app"
ditto "$APP" "/Applications/Ice Cube.app"

echo "==> Launching"
open "/Applications/Ice Cube.app"
echo "Done. Ice Cube opens its setup window if fan control needs attention."
echo "Note: replacing the app does NOT restart the running background service."
echo "The app detects the stale version and offers 'Update Now' — take it, or"
echo "fan control keeps running the PREVIOUS build (XCODE_GUIDE §4.4)."

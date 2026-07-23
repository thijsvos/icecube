#!/bin/sh
# install-debug.sh — build a SIGNED debug Ice Cube and install it to /Applications for helper testing.
# Registering the daemon from Xcode's DerivedData path is flaky (XCODE_GUIDE §4);
# run this, then launch Ice Cube from /Applications.
set -eu
cd "$(dirname "$0")/.."

if [ ! -f Configs/Local.xcconfig ]; then
    echo "error: Configs/Local.xcconfig missing — run scripts/set-team.sh <TEAMID> first." >&2
    exit 1
fi

echo "==> Generating project"
xcodegen generate

echo "==> Building (signed, Debug)"
BUILD_LOG=$(mktemp)
if ! xcodebuild -project IceCube.xcodeproj -scheme IceCube -configuration Debug \
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

APP="build/Build/Products/Debug/Ice Cube.app"
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
echo "Done. Now: popover → Enable Fan Control → approve in System Settings (XCODE_GUIDE §4)."

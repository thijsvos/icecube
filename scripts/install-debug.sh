#!/bin/sh
# install-debug.sh — build a SIGNED debug Zephyr and install it to /Applications for helper testing.
# Registering the daemon from Xcode's DerivedData path is flaky (XCODE_GUIDE §4);
# run this, then launch Zephyr from /Applications.
set -eu
cd "$(dirname "$0")/.."

if [ ! -f Configs/Local.xcconfig ]; then
    echo "error: Configs/Local.xcconfig missing — run scripts/set-team.sh <TEAMID> first." >&2
    exit 1
fi

echo "==> Generating project"
xcodegen generate

echo "==> Building (signed, Debug)"
xcodebuild -project Zephyr.xcodeproj -scheme Zephyr -configuration Debug \
    -derivedDataPath build build | grep -E "error:|warning: code sign|BUILD" || true

APP="build/Build/Products/Debug/Zephyr.app"
if [ ! -d "$APP" ]; then
    echo "error: build failed — open Zephyr.xcodeproj in Xcode and check Signing (XCODE_GUIDE §2)." >&2
    exit 1
fi

echo "==> Verifying signature"
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|Authority" || {
    echo "error: app is unsigned — the helper cannot be registered. Fix signing first." >&2
    exit 1
}

echo "==> Installing to /Applications (quitting any running copy)"
pkill -x Zephyr 2>/dev/null || true
rm -rf /Applications/Zephyr.app
ditto "$APP" /Applications/Zephyr.app

echo "==> Launching"
open /Applications/Zephyr.app
echo "Done. Now: popover → Enable Fan Control → approve in System Settings (XCODE_GUIDE §4)."

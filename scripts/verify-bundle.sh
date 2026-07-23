#!/bin/sh
# verify-bundle.sh — asserts the built Zephyr.app contains the helper binary and
# the LaunchDaemon plist at the exact paths SMAppService requires. Run after every
# build (CI does); it catches XcodeGen/Xcode embedding regressions early, before
# they surface as inscrutable helper-registration failures.
#
# Usage: scripts/verify-bundle.sh [path/to/Zephyr.app]
# Default app path: build/Build/Products/Debug/Zephyr.app

set -eu

APP=${1:-build/Build/Products/Debug/Zephyr.app}
HELPER_REL="Contents/MacOS/ZephyrHelper"
PLIST_REL="Contents/Library/LaunchDaemons/io.github.thijsvos.zephyr.helper.plist"

if [ ! -d "$APP" ]; then
    echo "FAIL: app bundle not found at: $APP" >&2
    echo "      Build first (see README), or pass the app path as the first argument." >&2
    exit 1
fi

fail=0

if [ -f "$APP/$HELPER_REL" ]; then
    echo "ok: $HELPER_REL"
else
    echo "FAIL: helper binary missing at $HELPER_REL" >&2
    fail=1
fi

if [ -f "$APP/$PLIST_REL" ]; then
    echo "ok: $PLIST_REL"
else
    echo "FAIL: launchd plist missing at $PLIST_REL" >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "Bundle layout is wrong — SMAppService registration would fail at runtime." >&2
    echo "Check the copyFiles build phases in project.yml, then 'xcodegen generate' and rebuild." >&2
    exit 1
fi

echo "Bundle layout verified: $APP"

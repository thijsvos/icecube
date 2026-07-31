#!/bin/sh
# verify-bundle.sh — asserts the built Ice Cube.app contains the helper binary and
# the LaunchDaemon plist at the exact paths SMAppService requires. Run after every
# build (CI does); it catches XcodeGen/Xcode embedding regressions early, before
# they surface as inscrutable helper-registration failures.
#
# Usage: scripts/verify-bundle.sh [path/to/Ice Cube.app]
# Default app path: build/Build/Products/Debug/Ice Cube.app

set -eu

APP=${1:-build/Build/Products/Debug/Ice Cube.app}
HELPER_REL="Contents/MacOS/IceCubeHelper"
PLIST_REL="Contents/Library/LaunchDaemons/io.github.thijsvos.icecube.helper.plist"

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

# THE CAPABILITY BOUNDARY. The app must contain no SMC writer, ever.
#
# This used to be guaranteed by file layout: the only writer, SMCWritePort,
# lived in the helper target and nothing else did. Since DaemonCore moved into
# IceCubeKit (which the app links) so its safety logic could be unit-tested,
# layout alone no longer proves it — the orchestration is in the app binary and
# only the concrete writer is not. That makes this check the actual guarantee,
# and it is one careless `import` away from silently regressing.
APP_BIN="$APP/Contents/MacOS/Ice Cube"
HELPER_BIN="$APP/$HELPER_REL"

if [ -f "$APP_BIN" ]; then
    writers=$(nm -a "$APP_BIN" 2>/dev/null | grep -c "SMCWritePort" || true)
    if [ "$writers" -eq 0 ]; then
        echo "ok: app binary contains no SMC writer"
    else
        echo "FAIL: app binary references SMCWritePort ($writers symbols)" >&2
        echo "      The unprivileged app must never link a writer. Something moved" >&2
        echo "      SMCWritePort (or a copy of it) out of the IceCubeHelper target." >&2
        fail=1
    fi
else
    echo "FAIL: app binary missing at Contents/MacOS/Ice Cube" >&2
    fail=1
fi

# The same boundary for the power plumbing, for the same reason: the app must
# never be able to drive fan state off a system power notification. Only
# IceCubeHelper may register with the root power domain.
if [ -f "$APP_BIN" ]; then
    watchers=$(nm -a "$APP_BIN" 2>/dev/null | grep -c "SystemPowerWatcher" || true)
    if [ "$watchers" -eq 0 ]; then
        echo "ok: app binary contains no system-power watcher"
    else
        echo "FAIL: app binary references SystemPowerWatcher ($watchers symbols)" >&2
        echo "      The pre-sleep hand-back writes fans, so its trigger belongs" >&2
        echo "      to the helper alone. Something moved it out of IceCubeHelper." >&2
        fail=1
    fi
    readers=$(nm -a "$APP_BIN" 2>/dev/null | grep -c "SystemCapabilityReader" || true)
    if [ "$readers" -eq 0 ]; then
        echo "ok: app binary contains no power-capability reader"
    else
        echo "FAIL: app binary references SystemCapabilityReader ($readers symbols)" >&2
        echo "      Raw IOKit belongs to the helper alone; the pure half the app" >&2
        echo "      may link is PowerCapabilities in IceCubeKit." >&2
        fail=1
    fi
fi

# And the converse: the helper must actually have one, or fan control is dead.
if [ -f "$HELPER_BIN" ]; then
    if [ "$(nm -a "$HELPER_BIN" 2>/dev/null | grep -c "SMCWritePort" || true)" -gt 0 ]; then
        echo "ok: helper binary contains the SMC writer"
    else
        echo "FAIL: helper binary has no SMCWritePort — fan control cannot work" >&2
        fail=1
    fi
    # The sleep half of the power contract (PLAN.md §4.3.6). Without this the
    # daemon leaves the fans forced for the whole closed-lid window — the bug
    # protocol v20 exists to fix — and nothing else in the bundle would say so.
    if [ "$(nm -a "$HELPER_BIN" 2>/dev/null | grep -c "SystemPowerWatcher" || true)" -gt 0 ]; then
        echo "ok: helper binary registers for system power notifications"
    else
        echo "FAIL: helper binary has no SystemPowerWatcher — the fans would keep" >&2
        echo "      spinning through sleep (PLAN.md §4.3.6)" >&2
        fail=1
    fi
    # The dark-wake gate. Without a capability reader every unpark falls back to
    # "cannot tell", which never proves a full wake — so the daemon would sit
    # parked until the missed-wake failsafe, and the machine would run on
    # firmware auto with the user's curve silently inert.
    if [ "$(nm -a "$HELPER_BIN" 2>/dev/null | grep -c "SystemCapabilityReader" || true)" -gt 0 ]; then
        echo "ok: helper binary can tell a dark wake from a full one"
    else
        echo "FAIL: helper binary has no SystemCapabilityReader — the daemon could" >&2
        echo "      not prove a wake is real (PLAN.md §4.3.6 dark-wake gate)" >&2
        fail=1
    fi
fi

if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "Bundle verification failed — see the messages above." >&2
    echo "Layout problems: check the copyFiles build phases in project.yml, then" >&2
    echo "'xcodegen generate' and rebuild. Boundary problems are a code change." >&2
    exit 1
fi

echo "Bundle verified: $APP"

#!/bin/sh
# coverage.sh — prints line coverage for both targets. Reports; never gates.
#
# WHY THIS EXISTS
#
# PLAN.md §6 has asked for ">90 % coverage" of IceCubeKit since the project
# started, and until 2026-08-07 nothing measured it. Every coverage figure in
# the repo's history was produced by hand, once, and pasted into a commit body —
# so by ci.yml's own standard ("a rule nothing checks is a rule that decays")
# the target had decayed. The first real measurement found the Kit at 93.6 %,
# which is to say the target was being met and nobody could have known.
#
# WHY IT DOES NOT FAIL THE BUILD
#
# Two reasons, and both matter more than they look.
#
# 1. SMCConnection IS the IOKit syscalls — `IOConnectCallStructMethod` and the
#    80-byte param struct. It sits at a flat 0 % and there is no honest way to
#    change that without a Mac in the loop, so it is excluded below and that
#    exclusion is the most important line in this script.
#
#    SystemSMCProvider used to be excluded beside it, on the same grounds. That
#    stopped being true on 2026-08-08: the `SMCReadPort` seam made its ~140
#    lines of decision logic reachable and they now sit at ~70 %. Leaving it
#    filtered would have hidden both that gain and any later regression, so it
#    is back in the figure. Worth remembering the general lesson — an exclusion
#    list is a claim about what is possible, and claims go stale.
#
# 2. PLAN.md calls app-target coverage "best-effort" on purpose: most of those
#    files are SwiftUI view bodies, which cannot be usefully unit-tested and
#    which the project has repeatedly chosen to hollow out into pure types
#    instead. A threshold there would punish the right design.
#
# So: print, watch the trend, and argue for a floor later with data in hand.

set -eu
cd "$(dirname "$0")/.."

echo "==> IceCubeKit"
(
    cd IceCubeKit
    swift test --enable-code-coverage >/dev/null 2>&1
    BIN=$(swift build --show-bin-path)
    xcrun llvm-cov report \
        "$BIN/IceCubeKitPackageTests.xctest/Contents/MacOS/IceCubeKitPackageTests" \
        -instr-profile "$BIN/codecov/default.profdata" \
        -ignore-filename-regex='(Tests|\.build|SMCConnection\.swift)/?' \
        2>/dev/null | tail -3
)

echo
echo "==> Ice Cube.app (best-effort — PLAN.md §6)"
xcodebuild test -project IceCube.xcodeproj -scheme IceCube \
    -configuration Debug -derivedDataPath build \
    -enableCodeCoverage YES -resultBundlePath build/coverage.xcresult \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=YES DEVELOPMENT_TEAM="" >/dev/null 2>&1
xcrun xccov view --report --only-targets build/coverage.xcresult 2>/dev/null \
    | grep -E "Ice Cube.app|IceCubeHelper"
rm -rf build/coverage.xcresult

echo
echo "Excluded from the Kit figure: SMCConnection — see the header."

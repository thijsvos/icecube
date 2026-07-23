#!/bin/sh
# set-team.sh — one-time setup: writes your Apple Development team ID into the
# gitignored Configs/Local.xcconfig so Xcode can sign both targets automatically.
#
# Usage: scripts/set-team.sh <TEAM_ID>
#
# Finding your 10-character team ID:
#   * Xcode -> Settings -> Accounts -> select your Apple ID -> the ID is shown
#     next to your team name, or
#   * codesign -dv <any app you have built>   -> the "TeamIdentifier=" line.
# Careful: the team ID is the certificate's OU value, NOT the parenthesized
# suffix in the certificate's display name.

set -eu

if [ $# -ne 1 ]; then
    echo "Usage: $0 <TEAM_ID>" >&2
    echo "" >&2
    echo "Find your 10-character team ID via:" >&2
    echo "  - Xcode -> Settings -> Accounts (shown next to your team name), or" >&2
    echo "  - codesign -dv <a built .app>  (the TeamIdentifier= line)" >&2
    exit 1
fi

TEAM_ID=$1

case $TEAM_ID in
    [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) ;;
    *)
        echo "Warning: '$TEAM_ID' does not look like a 10-character team ID (A-Z, 0-9)." >&2
        echo "Writing it anyway — double-check with 'codesign -dv' after your next build." >&2
        ;;
esac

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG_DIR="$REPO_ROOT/Configs"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_DIR/Local.xcconfig" <<EOF
// Local.xcconfig — machine-specific signing settings. Gitignored; NEVER commit.
// Regenerate any time with: scripts/set-team.sh <TEAM_ID>
DEVELOPMENT_TEAM = $TEAM_ID
CODE_SIGN_STYLE = Automatic
EOF

echo "Wrote $CONFIG_DIR/Local.xcconfig (DEVELOPMENT_TEAM = $TEAM_ID)."
echo "No project regeneration needed — Xcode reads the xcconfig on the next build."

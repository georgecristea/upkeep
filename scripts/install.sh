#!/usr/bin/env bash
set -euo pipefail

# Build, package, and (re)install this app into /Applications, then relaunch it.
# The one command to run after a change. The same script lives in VoxKey, ClipVault, and Upkeep.
#
#   ./scripts/install.sh
#
# What it does: package-app.sh (universal release build, ad-hoc or Developer ID signed) →
# quit any running copy (dist/, /Applications, .build) → copy dist/<App>.app to /Applications →
# repoint the launch-at-login agent (if enabled) at /Applications → launch.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT_DIR/Packaging/Info.plist"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$PLIST")"
TARGET="/Applications/$APP_NAME.app"

"$ROOT_DIR/scripts/package-app.sh"

if pgrep -xq "$APP_NAME"; then
    echo "Quitting running ${APP_NAME}..."
    pkill -x "$APP_NAME" || true
    for _ in $(seq 1 40); do pgrep -xq "$APP_NAME" || break; sleep 0.25; done
fi

rm -rf "$TARGET"
cp -R "$ROOT_DIR/dist/$APP_NAME.app" "$TARGET"

# MUKLaunchAtLoginManager writes ~/Library/LaunchAgents/<bundle id>.plist pointing at wherever the
# app ran from when the toggle was flipped. Keep it pointing at /Applications.
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
if [[ -f "$AGENT" ]]; then
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:1 $TARGET" "$AGENT" 2>/dev/null || true
    launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || true
fi

open "$TARGET"
echo "✅ Installed and launched $TARGET ($(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST"))"

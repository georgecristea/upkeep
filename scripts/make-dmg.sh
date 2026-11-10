#!/usr/bin/env bash
set -euo pipefail

# Builds a drag-to-Applications DMG from dist/Upkeep.app.
# Run ./scripts/package-app.sh first (or scripts/notarize.sh for a notarized build).

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/dist/Upkeep.app"
DMG="$ROOT_DIR/dist/Upkeep.dmg"

if [[ ! -d "$APP" ]]; then
    echo "No app at $APP — run ./scripts/package-app.sh first." >&2
    exit 1
fi

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Upkeep" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "Wrote $DMG"

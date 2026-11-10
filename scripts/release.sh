#!/usr/bin/env bash
set -euo pipefail

# Build a DMG and publish it as a GitHub release.
#
# USAGE:
#   ./scripts/release.sh v0.1.3
#
# Requires the `gh` CLI, authenticated (`gh auth status`). The build is ad-hoc signed and not
# notarized, so the release notes explain how to get past Gatekeeper.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Upkeep"
REPO="georgecristea/upkeep"
cd "$ROOT_DIR"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
    echo "Usage: ./scripts/release.sh <tag>   e.g. ./scripts/release.sh v0.1.3" >&2
    exit 1
fi

# Build the .app and the drag-to-Applications DMG.
"$ROOT_DIR/scripts/package-app.sh"
"$ROOT_DIR/scripts/make-dmg.sh"

DMG="$ROOT_DIR/dist/$APP_NAME.dmg"
[[ -f "$DMG" ]] || { echo "No DMG at $DMG" >&2; exit 1; }

VERSION="${TAG#v}"
NOTES="$(cat <<EOF
**Install:** download **$APP_NAME.dmg**, open it, and drag $APP_NAME into Applications.

Upkeep is a front end for the \`upkeep\` CLI: install the CLI first (see the README).

This build is not notarized by Apple yet, so macOS blocks the first launch. Open it once with
**System Settings → Privacy & Security → Open Anyway**, or run:

\`\`\`sh
xattr -dr com.apple.quarantine /Applications/$APP_NAME.app
\`\`\`
EOF
)"

gh release create "$TAG" "$DMG" \
    --repo "$REPO" \
    --title "$APP_NAME $VERSION" \
    --notes "$NOTES" \
    --latest

echo "✅ Released $TAG → https://github.com/$REPO/releases/tag/$TAG"

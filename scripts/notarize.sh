#!/usr/bin/env bash
set -euo pipefail

# Distribution build: Developer ID signing + hardened runtime + notarization + stapling,
# then a notarized DMG. Run this instead of package-app.sh when shipping to other people.
#
# ONE-TIME PREREQUISITES (the only manual step we can't script — needs your Apple account):
#   1. Apple Developer Program membership (~$99/yr).
#   2. A "Developer ID Application" certificate in your keychain:
#        Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application
#   3. Store notary credentials once (app-specific password from appleid.apple.com):
#        xcrun notarytool store-credentials Upkeep \
#          --apple-id "you@example.com" --team-id "TEAMID" --password "xxxx-xxxx-xxxx-xxxx"
#
# USAGE:
#   ./scripts/notarize.sh
#   (overrides) DEV_ID="Developer ID Application: Name (TEAMID)" NOTARY_PROFILE=Upkeep ./scripts/notarize.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT_DIR/dist/Upkeep.app"
ENTITLEMENTS="$ROOT_DIR/Packaging/Upkeep.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-Upkeep}"
DEV_ID="${DEV_ID:-}"

if [[ -z "$DEV_ID" ]]; then
    DEV_ID="$(security find-identity -v -p codesigning \
        | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -n1)"
fi
if [[ -z "$DEV_ID" ]]; then
    echo "ERROR: No 'Developer ID Application' certificate found in the keychain." >&2
    echo "See the one-time prerequisites at the top of this script." >&2
    exit 1
fi
echo "Signing identity: $DEV_ID"

# 1. Build + assemble the .app (Dev-ID base signature via CODE_SIGN_IDENTITY).
CODE_SIGN_IDENTITY="$DEV_ID" "$ROOT_DIR/scripts/package-app.sh"

# 2. Re-sign with hardened runtime + entitlements + secure timestamp.
#    (Upkeep embeds no third-party frameworks, so there's nothing to sign inside-out.)
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3. Notarize: submit a zip, wait for the verdict, staple the ticket onto the .app.
ZIP="$ROOT_DIR/dist/Upkeep-notarize.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"

# 4. Build the DMG from the stapled app and staple the DMG too.
"$ROOT_DIR/scripts/make-dmg.sh"
xcrun stapler staple "$ROOT_DIR/dist/Upkeep.dmg" || true

echo "✅ Notarized + stapled. Ship: $ROOT_DIR/dist/Upkeep.dmg"

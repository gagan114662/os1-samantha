#!/bin/bash
#
# Notarize the dist/OS1.app bundle with Apple.
#
# One-time setup required (you, not this script):
#   1. Apple Developer account ($99/yr): https://developer.apple.com/
#   2. Create a "Developer ID Application" certificate via Xcode → Settings →
#      Accounts → your team → "Manage Certificates" → + → Developer ID Application.
#      The cert lands in your login keychain.
#   3. Create an app-specific password at https://appleid.apple.com → Sign-In and
#      Security → App-Specific Passwords. Call it "OS1 notarization".
#   4. Save credentials to `notarytool` once:
#        xcrun notarytool store-credentials os1-notary \
#          --apple-id   <your-apple-id-email> \
#          --team-id    <your-team-id-from-developer-portal> \
#          --password   <the-app-specific-password>
#
# After that, every release goes through:
#   OS1_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     ./scripts/build-macos-app.sh
#   ./scripts/notarize.sh
#
# This script:
#   - re-signs with hardened runtime (required for notarization)
#   - zips the .app
#   - submits to Apple via notarytool, waits for the verdict
#   - staples the notarization ticket back onto the .app
#   - verifies with `spctl --assess`

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/OS1.app"
ZIP_PATH="$ROOT_DIR/dist/OS1.zip"
PROFILE="${NOTARY_PROFILE:-os1-notary}"

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: $APP_PATH not found. Run scripts/build-macos-app.sh first." >&2
    exit 1
fi

# Check that the app is signed with a Developer ID, not ad-hoc.
# Apple rejects ad-hoc-signed apps from notarization.
identity_line=$(codesign -dv "$APP_PATH" 2>&1 | grep -E "^Authority|^Signature=" || true)
if echo "$identity_line" | grep -q "Signature=adhoc"; then
    cat >&2 <<'EOF'
ERROR: dist/OS1.app is ad-hoc signed. Notarization requires a Developer ID.

Re-build with your cert:
  OS1_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
    ./scripts/build-macos-app.sh

(Then re-run this script.)
EOF
    exit 1
fi

# Re-codesign with hardened runtime + timestamp (notarization requires both).
if [[ -n "${OS1_CODESIGN_IDENTITY:-}" ]]; then
    echo "==> Re-signing $APP_PATH with hardened runtime ($OS1_CODESIGN_IDENTITY)"
    codesign --force \
        --options runtime \
        --timestamp \
        --sign "$OS1_CODESIGN_IDENTITY" \
        --identifier "com.elementsoftware.os1" \
        "$APP_PATH"
fi

echo "==> Zipping bundle for upload"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take 1-10 minutes)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$PROFILE" \
    --wait

echo "==> Stapling notarization ticket onto the .app"
xcrun stapler staple "$APP_PATH"

echo "==> Verifying"
spctl --assess --type execute --verbose "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo
echo "✅ Notarized + stapled. dist/OS1.app is ready to ship."
echo "   Users on a clean Mac will not see the 'unidentified developer' Gatekeeper warning."

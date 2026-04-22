#!/bin/bash
# Build, sign, notarize, and staple Teale.app for direct distribution.
#
# Prerequisites (one-time):
#   1. Copy .env.signing.example -> .env.signing and fill in.
#   2. Run: xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#            --key /path/to/AuthKey_XXXX.p8 --key-id XXXX --issuer YYYY
#      (stores App Store Connect API creds in login Keychain — no plaintext on disk).
#
# Usage: ./scripts/sign-macos.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [ ! -f .env.signing ]; then
    echo "ERROR: .env.signing not found. Copy .env.signing.example and fill in." >&2
    exit 1
fi
# shellcheck disable=SC1091
source .env.signing

: "${SIGNING_IDENTITY:?SIGNING_IDENTITY must be set in .env.signing}"
: "${NOTARY_PROFILE:?NOTARY_PROFILE must be set in .env.signing}"

APP=".build/Teale.app"
ZIP=".build/Teale.zip"

echo "==> Building and signing (SIGNING_IDENTITY=${SIGNING_IDENTITY})"
SIGNING_IDENTITY="${SIGNING_IDENTITY}" ./bundle.sh

echo "==> Zipping for notarization submission"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "==> Submitting to Apple notary service (this can take several minutes)"
xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait

echo "==> Stapling ticket to app bundle"
xcrun stapler staple "${APP}"

echo "==> Verifying with Gatekeeper"
spctl -a -vvv --type execute "${APP}"

echo "==> Re-zipping with stapled ticket for distribution"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"

echo "==> Creating DMG for drag-to-Applications install"
DMG=".build/Teale.dmg"
STAGING=".build/dmg-staging"
rm -rf "${STAGING}" "${DMG}"
mkdir -p "${STAGING}"
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
hdiutil create -volname "Teale" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}"
codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG}"

echo "==> Notarizing DMG"
xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${DMG}"
spctl -a -vvv --type install "${DMG}"
rm -rf "${STAGING}"

SIZE=$(du -sh "${APP}" | cut -f1)
DMG_SIZE=$(du -sh "${DMG}" | cut -f1)
echo ""
echo "Signed + notarized + stapled: ${APP} (${SIZE})"
echo "Distributable archive:        ${ZIP}"
echo "Distributable DMG:            ${DMG} (${DMG_SIZE})"

#!/usr/bin/env bash
# Developer-ID-sign Teale.app and package as a distributable .dmg.
# Notarization is skipped (requires an App Store Connect notary profile
# stored in the keychain — see .env.signing). The output DMG is signed but
# not notarized; distributing it will show Gatekeeper warnings until you
# run `xcrun notarytool submit --keychain-profile teale-notary --wait` +
# `xcrun stapler staple` on both the .app and the .dmg.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# shellcheck disable=SC1091
source .env.signing
: "${SIGNING_IDENTITY:?SIGNING_IDENTITY must be set in .env.signing}"

APP=".build/Teale.app"
DMG=".build/Teale.dmg"
STAGING=".build/dmg-staging"

echo "==> bundle.sh with Developer ID signing"
SIGNING_IDENTITY="${SIGNING_IDENTITY}" ./bundle.sh

echo "==> Building DMG"
rm -rf "${STAGING}" "${DMG}"
mkdir -p "${STAGING}"
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
hdiutil create -volname "Teale" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}"
codesign --force --sign "${SIGNING_IDENTITY}" --timestamp "${DMG}"
rm -rf "${STAGING}"

APP_SIZE=$(du -sh "${APP}" | cut -f1)
DMG_SIZE=$(du -sh "${DMG}" | cut -f1)
echo
echo "Signed .app: ${APP} (${APP_SIZE})"
echo "Signed .dmg: ${DMG} (${DMG_SIZE})"
echo
echo "To notarize later (one-time creds setup required):"
echo "  xcrun notarytool submit \"${DMG}\" --keychain-profile \"${NOTARY_PROFILE}\" --wait"
echo "  xcrun stapler staple \"${DMG}\""
echo "  spctl -a -vvv --type install \"${DMG}\""

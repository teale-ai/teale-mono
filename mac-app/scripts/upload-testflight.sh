#!/bin/bash
# Archive TealeCompanion, export an IPA, and upload to TestFlight.
#
# Expects env vars (from .env.signing locally, or CI secrets):
#   TEAM_ID              — 10-char Apple Developer team ID
#   API_KEY_ID           — App Store Connect API key ID
#   API_ISSUER_ID        — App Store Connect API issuer ID
#   API_KEY_PATH         — absolute path to AuthKey_XXXX.p8
#
# Usage: ./scripts/upload-testflight.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

if [ -f .env.signing ]; then
    # shellcheck disable=SC1091
    source .env.signing
fi

: "${TEAM_ID:?TEAM_ID required}"
: "${API_KEY_ID:?API_KEY_ID required}"
: "${API_ISSUER_ID:?API_ISSUER_ID required}"
: "${API_KEY_PATH:?API_KEY_PATH required (path to AuthKey_XXXX.p8)}"

ARCHIVE=".build/TealeCompanion.xcarchive"
EXPORT_DIR=".build/ipa"
IPA="${EXPORT_DIR}/TealeCompanion.ipa"

# Render ExportOptions.plist with team ID substituted.
EXPORT_PLIST=".build/ExportOptions.plist"
mkdir -p .build
sed "s/__TEAM_ID__/${TEAM_ID}/g" scripts/ExportOptions.plist > "${EXPORT_PLIST}"

echo "==> Archiving TealeCompanion for iOS"
rm -rf "${ARCHIVE}"
xcodebuild \
    -scheme TealeCompanion \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "${ARCHIVE}" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    archive

echo "==> Exporting IPA"
rm -rf "${EXPORT_DIR}"
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_PLIST}" \
    -allowProvisioningUpdates

if [ ! -f "${IPA}" ]; then
    # exportArchive names the IPA after the scheme/product; find it.
    IPA=$(find "${EXPORT_DIR}" -maxdepth 1 -name '*.ipa' | head -n1)
fi

echo "==> Uploading ${IPA} to App Store Connect / TestFlight"
xcrun altool --upload-app \
    --type ios \
    --file "${IPA}" \
    --apiKey "${API_KEY_ID}" \
    --apiIssuer "${API_ISSUER_ID}"

echo ""
echo "Upload submitted. Check App Store Connect → TestFlight in ~5-10 min."
echo "Note: altool reads the API key from ~/.appstoreconnect/private_keys/AuthKey_${API_KEY_ID}.p8"
echo "      or ~/private_keys/, ./private_keys/, or ./. Place \$API_KEY_PATH there if needed."

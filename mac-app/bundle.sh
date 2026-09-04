#!/bin/bash
# Build and bundle InferencePoolApp as a macOS .app.
# Uses xcodebuild to properly compile Metal shaders required by MLX.
set -euo pipefail

DERIVED_DATA=".build/xcode"
APP_NAME="Teale"
APP_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-"-"}"
ENTITLEMENTS="Sources/InferencePoolApp/InferencePool.entitlements"

# Prefer Xcode over Command Line Tools for xcodebuild (needed for Metal shaders).
if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# Regenerate BuildVersion.swift with current git info
if [ -x scripts/generate-version.sh ]; then
    scripts/generate-version.sh
fi

echo "Building Teale (Release via xcodebuild)..."
xcodebuild \
    -scheme Teale \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'platform=macOS' \
    build \
    2>&1 | tail -5

BINARY="${DERIVED_DATA}/Build/Products/Release/Teale"
METALLIB_BUNDLE="${DERIVED_DATA}/Build/Products/Release/mlx-swift_Cmlx.bundle"

if [ ! -f "${BINARY}" ]; then
    echo "ERROR: Binary not found at ${BINARY}"
    exit 1
fi

echo "Creating app bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy binary and strip debug symbols
cp "${BINARY}" "${MACOS_DIR}/Teale"
strip "${MACOS_DIR}/Teale"

# Bundle the teale CLI (Rust) when the caller prebuilt it. The release
# workflow builds it from the repo-root workspace and points
# TEALE_CLI_BINARY at the binary; local ad-hoc builds skip it.
# NOTE: bundled as "teale-cli", not "teale" - macOS ships on
# case-insensitive APFS by default, where "teale" and "Teale" (the app
# binary) are the same file and the copy would silently overwrite the
# app. The /usr/local/bin/teale symlink points at teale-cli.
TEALE_CLI_BUNDLED=0
if [ -n "${TEALE_CLI_BINARY:-}" ] && [ -f "${TEALE_CLI_BINARY}" ]; then
    cp "${TEALE_CLI_BINARY}" "${MACOS_DIR}/teale-cli"
    strip "${MACOS_DIR}/teale-cli" 2>/dev/null || true
    chmod 755 "${MACOS_DIR}/teale-cli"
    if cmp -s "${MACOS_DIR}/Teale" "${MACOS_DIR}/teale-cli"; then
        echo "ERROR: Contents/MacOS/teale-cli overwrote the Teale app binary (case-insensitive filesystem collision)"
        exit 1
    fi
    TEALE_CLI_BUNDLED=1
    echo "  Bundled teale CLI into Contents/MacOS/teale-cli"
else
    echo "  NOTE: TEALE_CLI_BINARY not set — .app will not contain the teale CLI"
fi

RELEASE_PRODUCTS_DIR="${DERIVED_DATA}/Build/Products/Release"

# Copy SwiftPM resource bundles, including the MLX metal library bundle.
FOUND_BUNDLES=0
for bundle in "${RELEASE_PRODUCTS_DIR}"/*.bundle; do
    if [ ! -d "${bundle}" ]; then
        continue
    fi

    cp -R "${bundle}" "${RESOURCES_DIR}/"
    FOUND_BUNDLES=1
    echo "  Included resource bundle $(basename "${bundle}") ($(du -sh "${bundle}" | cut -f1))"
done

if [ "${FOUND_BUNDLES}" -eq 0 ]; then
    echo "WARNING: No resource bundles found in ${RELEASE_PRODUCTS_DIR}"
elif [ ! -d "${METALLIB_BUNDLE}" ]; then
    echo "WARNING: Metal shader bundle not found — inference will not work"
fi

# Copy SwiftPM/Xcode resource bundles.
find "${DERIVED_DATA}/Build/Products/Release" -maxdepth 1 -name '*.bundle' -type d | while read -r bundle; do
    cp -R "${bundle}" "${RESOURCES_DIR}/"
done

# Copy Info.plist and app icon
cp Sources/InferencePoolApp/Info.plist "${CONTENTS_DIR}/Info.plist"
if [ -f "Sources/InferencePoolApp/AppIcon.icns" ]; then
    cp Sources/InferencePoolApp/AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
    echo "  Included app icon"
fi

# Embed the Developer ID provisioning profile if present. Required by AMFI to
# authorize restricted entitlements (e.g. com.apple.developer.networking.multicast)
# under Hardened Runtime.
if [ -f "Sources/InferencePoolApp/embedded.provisionprofile" ]; then
    cp "Sources/InferencePoolApp/embedded.provisionprofile" "${CONTENTS_DIR}/embedded.provisionprofile"
    echo "  Included embedded.provisionprofile"
fi

BUILD_DATE="$(date '+%Y.%m.%d')"
BUILD_TIME="$(date '+%H:%M')"
BUILD_NUMBER="$(date '+%Y%m%d%H%M')"
GIT_HASH="$(git rev-parse --short HEAD 2>/dev/null || echo 'nogit')"
BUILD_VERSION="${BUILD_DATE}-${BUILD_TIME}-${GIT_HASH}"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${BUILD_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :TealeBuildDate" "${CONTENTS_DIR}/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :TealeBuildDate string ${BUILD_VERSION}" "${CONTENTS_DIR}/Info.plist"

# Local ad-hoc signing cannot carry restricted entitlements like multicast networking.
# Only attach entitlements when signing with a real identity.
if [ "${SIGNING_IDENTITY}" = "-" ]; then
    codesign --force --deep --sign - "${APP_DIR}"
else
    # Inside-out signing: nested executables and bundles first, then outer app.
    # --options runtime (Hardened Runtime) and --timestamp are required for notarization.
    if [ "${TEALE_CLI_BUNDLED}" -eq 1 ]; then
        codesign --force --sign "${SIGNING_IDENTITY}" \
            --timestamp --options runtime \
            "${MACOS_DIR}/teale-cli"
    fi
    for nested in "${RESOURCES_DIR}"/*.bundle; do
        [ -d "${nested}" ] && codesign --force --sign "${SIGNING_IDENTITY}" \
            --timestamp --options runtime "${nested}"
    done
    codesign --force --sign "${SIGNING_IDENTITY}" \
        --entitlements "${ENTITLEMENTS}" \
        --timestamp --options runtime \
        "${APP_DIR}"
    echo "==> Verifying signature"
    codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
fi

SIZE=$(du -sh "${APP_DIR}" | cut -f1)
echo ""
echo "App bundle created at: ${APP_DIR} (${SIZE})"
echo ""
echo "To run:"
echo "  open '.build/${APP_NAME}.app'"
echo ""
echo "The app will appear as a brain icon in your menu bar (top-right)."

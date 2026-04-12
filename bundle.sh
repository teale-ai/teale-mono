#!/bin/bash
# Build and bundle InferencePoolApp as a macOS .app.
# Uses xcodebuild to properly compile Metal shaders required by MLX.
set -e

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

echo "Building InferencePoolApp (Release via xcodebuild)..."
xcodebuild \
    -scheme InferencePoolApp \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'platform=macOS' \
    build \
    2>&1 | tail -5

BINARY="${DERIVED_DATA}/Build/Products/Release/InferencePoolApp"
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
cp "${BINARY}" "${MACOS_DIR}/InferencePoolApp"
strip "${MACOS_DIR}/InferencePoolApp"

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

# Copy SwiftPM/Xcode resource bundles such as AuthKit's bundled Supabase config.
find "${DERIVED_DATA}/Build/Products/Release" -maxdepth 1 -name '*.bundle' -type d | while read -r bundle; do
    cp -R "${bundle}" "${RESOURCES_DIR}/"
done

# Copy Info.plist
cp Sources/InferencePoolApp/Info.plist "${CONTENTS_DIR}/Info.plist"

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
    codesign --force --deep --sign "${SIGNING_IDENTITY}" --entitlements "${ENTITLEMENTS}" "${APP_DIR}"
fi

SIZE=$(du -sh "${APP_DIR}" | cut -f1)
echo ""
echo "App bundle created at: ${APP_DIR} (${SIZE})"
echo ""
echo "To run:"
echo "  open '.build/${APP_NAME}.app'"
echo ""
echo "The app will appear as a brain icon in your menu bar (top-right)."

#!/bin/bash
# Build and bundle InferencePoolApp as a macOS .app
# Uses xcodebuild to properly compile Metal shaders required by MLX
set -e

DERIVED_DATA=".build/xcode"
APP_NAME="Teale"
APP_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

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

# Copy Metal shader library bundle (required for MLX inference)
if [ -d "${METALLIB_BUNDLE}" ]; then
    cp -R "${METALLIB_BUNDLE}" "${RESOURCES_DIR}/"
    echo "  Included Metal shader library ($(du -sh "${METALLIB_BUNDLE}" | cut -f1))"
else
    echo "WARNING: Metal shader bundle not found — inference will not work"
fi

# Copy Info.plist
cp Sources/InferencePoolApp/Info.plist "${CONTENTS_DIR}/Info.plist"

# Sign with ad-hoc signature + entitlements (required for MenuBarExtra + network)
# TODO: Replace with Developer ID for distribution: --sign "Developer ID Application: ..."
codesign --force --sign - --entitlements Sources/InferencePoolApp/InferencePool.entitlements "${APP_DIR}"

SIZE=$(du -sh "${APP_DIR}" | cut -f1)
echo ""
echo "App bundle created at: ${APP_DIR} (${SIZE})"
echo ""
echo "To run:"
echo "  open '.build/${APP_NAME}.app'"
echo ""
echo "The app will appear as a brain icon in your menu bar (top-right)."

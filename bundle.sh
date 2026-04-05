#!/bin/bash
# Build and bundle InferencePoolApp as a macOS .app
set -e

echo "Building InferencePoolApp..."
swift build -c debug

APP_NAME="Inference Pool"
APP_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BINARY=".build/arm64-apple-macosx/debug/InferencePoolApp"

echo "Creating app bundle..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

# Copy binary
cp "${BINARY}" "${MACOS_DIR}/InferencePoolApp"

# Copy Info.plist
cp Sources/InferencePoolApp/Info.plist "${CONTENTS_DIR}/Info.plist"

# Sign with ad-hoc signature + entitlements (required for MenuBarExtra + network)
codesign --force --sign - --entitlements Sources/InferencePoolApp/InferencePool.entitlements "${APP_DIR}"

echo ""
echo "✓ App bundle created at: ${APP_DIR}"
echo ""
echo "To run:"
echo "  open '.build/${APP_NAME}.app'"
echo ""
echo "The app will appear as a brain icon in your menu bar (top-right)."

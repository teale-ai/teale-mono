#!/usr/bin/env bash
set -euo pipefail

# Build LiteRT-LM static engine library for Android aarch64.
# Requires: Bazel 7+, Android NDK r28b+
#
# This is a one-time setup step. The resulting libengine.a and accelerator
# .so files are copied into lib/ for linking during cargo build.

cd "$(dirname "$0")/.."

LITERT_LM_DIR="${LITERT_LM_DIR:-../LiteRT-LM}"
LIB_DIR="lib/android_arm64"

echo "=== LiteRT-LM static library build ==="

# Check prerequisites
if ! command -v bazel &>/dev/null && ! command -v bazelisk &>/dev/null; then
    echo "ERROR: Bazel not found. Install via:"
    echo "  brew install bazelisk"
    exit 1
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    if [ -d "/opt/homebrew/share/android-ndk" ]; then
        export ANDROID_NDK_HOME="/opt/homebrew/share/android-ndk"
    elif [ -d "$HOME/Library/Android/sdk/ndk" ]; then
        export ANDROID_NDK_HOME="$(ls -d "$HOME/Library/Android/sdk/ndk"/*/ 2>/dev/null | sort -V | tail -1)"
    else
        echo "ERROR: ANDROID_NDK_HOME not set. Install NDK via:"
        echo "  brew install --cask android-ndk"
        exit 1
    fi
fi

echo "NDK: $ANDROID_NDK_HOME"

# Clone LiteRT-LM if not present
if [ ! -d "$LITERT_LM_DIR" ]; then
    echo "Cloning LiteRT-LM..."
    git clone https://github.com/google-ai-edge/LiteRT-LM "$LITERT_LM_DIR"
fi

cd "$LITERT_LM_DIR"

# Build the C engine static library for Android arm64
echo "Building LiteRT-LM C engine (android_arm64)..."
bazel build --config=android_arm64 //c:engine

# Copy artifacts
cd -
mkdir -p "$LIB_DIR"

echo "Copying build artifacts..."
cp "$LITERT_LM_DIR/bazel-bin/c/libengine.a" "$LIB_DIR/"

# Copy C header
cp "$LITERT_LM_DIR/c/engine.h" lib/engine.h 2>/dev/null || true

# Copy prebuilt GPU accelerator shared libraries
if [ -d "$LITERT_LM_DIR/prebuilt/android_arm64" ]; then
    echo "Copying GPU accelerator plugins..."
    cp "$LITERT_LM_DIR/prebuilt/android_arm64"/*.so "$LIB_DIR/" 2>/dev/null || true
fi

echo ""
echo "=== Build complete ==="
echo "Static library: $LIB_DIR/libengine.a"
echo "GPU plugins:    $LIB_DIR/*.so"
echo ""
echo "Now build teale-node with LiteRT-LM support:"
echo "  ./scripts/build-android.sh --features litert"

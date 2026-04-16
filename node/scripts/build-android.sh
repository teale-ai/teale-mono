#!/usr/bin/env bash
set -euo pipefail

# Build teale-node for Android (aarch64).
# Requires: Rust toolchain + Android NDK.
#
# Install NDK:  brew install --cask android-ndk  (macOS)
#               sdkmanager "ndk;27.2.12479018"   (Linux/CI)
#
# Install Rust target:
#   rustup target add aarch64-linux-android

cd "$(dirname "$0")/.."

echo "=== teale-node Android build ==="

# Find NDK toolchain
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
    NDK="$ANDROID_NDK_HOME"
elif [ -d "/opt/homebrew/share/android-ndk" ]; then
    NDK="/opt/homebrew/share/android-ndk"
elif [ -d "$HOME/Library/Android/sdk/ndk" ]; then
    NDK="$(ls -d "$HOME/Library/Android/sdk/ndk"/*/ 2>/dev/null | sort -V | tail -1)"
elif [ -d "$HOME/Android/Sdk/ndk" ]; then
    NDK="$(ls -d "$HOME/Android/Sdk/ndk"/*/ 2>/dev/null | sort -V | tail -1)"
else
    echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME or install via:"
    echo "  macOS:  brew install --cask android-ndk"
    echo "  Linux:  sdkmanager 'ndk;27.2.12479018'"
    exit 1
fi

# Detect host OS for prebuilt toolchain path
case "$(uname -s)" in
    Darwin) HOST_TAG="darwin-x86_64" ;;
    Linux)  HOST_TAG="linux-x86_64" ;;
    *)      echo "Unsupported host OS"; exit 1 ;;
esac

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"

if [ ! -f "$TOOLCHAIN/bin/aarch64-linux-android35-clang" ]; then
    # Fall back to lower API levels
    CLANG=$(ls "$TOOLCHAIN/bin"/aarch64-linux-android*-clang 2>/dev/null | sort -V | tail -1)
    if [ -z "$CLANG" ]; then
        echo "ERROR: Cannot find aarch64-linux-android clang in $TOOLCHAIN/bin/"
        exit 1
    fi
else
    CLANG="$TOOLCHAIN/bin/aarch64-linux-android35-clang"
fi

AR="$TOOLCHAIN/bin/llvm-ar"
STRIP="$TOOLCHAIN/bin/llvm-strip"

echo "NDK:   $NDK"
echo "CC:    $CLANG"
echo "AR:    $AR"
echo ""

# Ensure target is installed
rustup target add aarch64-linux-android 2>/dev/null || true

# Build
echo "Building teale-node for aarch64-linux-android (release)..."
CC_aarch64_linux_android="$CLANG" \
AR_aarch64_linux_android="$AR" \
    cargo build --release --target aarch64-linux-android

# Strip debug symbols
BINARY="target/aarch64-linux-android/release/teale-node"
echo "Stripping debug symbols..."
"$STRIP" "$BINARY"

SIZE=$(ls -lh "$BINARY" | awk '{print $5}')
echo ""
echo "=== Build complete ==="
echo "Binary: $BINARY ($SIZE)"
echo ""
echo "Deploy to device via ADB:"
echo "  adb push $BINARY /data/local/tmp/teale-node"
echo "  adb push teale-node.toml /data/local/tmp/teale-node.toml"
echo "  adb shell chmod +x /data/local/tmp/teale-node"
echo "  adb shell /data/local/tmp/teale-node --config /data/local/tmp/teale-node.toml"
echo ""
echo "Or copy to Termux on device:"
echo "  adb push $BINARY /storage/emulated/0/Download/teale-node"
echo "  # Then in Termux: cp /storage/emulated/0/Download/teale-node \$PREFIX/bin/"

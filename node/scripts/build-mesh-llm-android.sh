#!/usr/bin/env bash
set -euo pipefail

# Build mesh-llm for Android (aarch64) via the NDK.
#
# Why this exists: upstream ships only glibc-linked Linux binaries
# (`mesh-llm-aarch64-unknown-linux-gnu.tar.gz`), which Android's bionic
# libc cannot load. This script clones upstream source, applies two
# minimal patches, and cross-compiles a bionic-native binary.
#
# Requires:
#   - Rust toolchain (same one teale-node uses)
#   - Android NDK (`brew install --cask android-ndk` on macOS)
#   - rustup target add aarch64-linux-android
#   - git
#
# Output: <OUT_DIR>/mesh-llm (default: ./build/mesh-llm-android/mesh-llm)
#
# Verified 2026-04-16 with mesh-llm 0.62.1 on an Apple M4 Pro build host,
# resulting binary runs on a Pixel 9 Pro Fold (Android 15, API 36).

MESH_LLM_REPO="${MESH_LLM_REPO:-https://github.com/Mesh-LLM/mesh-llm}"
MESH_LLM_REF="${MESH_LLM_REF:-main}"
OUT_DIR="${OUT_DIR:-$(pwd)/build/mesh-llm-android}"
SRC_DIR="${SRC_DIR:-$OUT_DIR/src}"

echo "=== mesh-llm Android build ==="

# --- 1. locate NDK ------------------------------------------------------
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
    NDK="$ANDROID_NDK_HOME"
elif [ -d "/opt/homebrew/share/android-ndk" ]; then
    NDK="/opt/homebrew/share/android-ndk"
elif [ -d "$HOME/Library/Android/sdk/ndk" ]; then
    NDK="$(ls -d "$HOME/Library/Android/sdk/ndk"/*/ 2>/dev/null | sort -V | tail -1)"
elif [ -d "$HOME/Android/Sdk/ndk" ]; then
    NDK="$(ls -d "$HOME/Android/Sdk/ndk"/*/ 2>/dev/null | sort -V | tail -1)"
else
    echo "ERROR: Android NDK not found. Set ANDROID_NDK_HOME or run 'brew install --cask android-ndk'." >&2
    exit 1
fi

case "$(uname -s)" in
    Darwin) HOST_TAG="darwin-x86_64" ;;
    Linux)  HOST_TAG="linux-x86_64" ;;
    *)      echo "Unsupported host OS"; exit 1 ;;
esac

TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
CLANG="$TOOLCHAIN/bin/aarch64-linux-android35-clang"
if [ ! -f "$CLANG" ]; then
    CLANG=$(ls "$TOOLCHAIN/bin"/aarch64-linux-android*-clang 2>/dev/null | sort -V | tail -1)
    if [ -z "$CLANG" ]; then
        echo "ERROR: Cannot find aarch64-linux-android clang in $TOOLCHAIN/bin/" >&2
        exit 1
    fi
fi
AR="$TOOLCHAIN/bin/llvm-ar"
RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
STRIP="$TOOLCHAIN/bin/llvm-strip"

echo "NDK:   $NDK"
echo "CC:    $CLANG"
echo ""

# --- 2. fetch source ----------------------------------------------------
mkdir -p "$OUT_DIR"
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "Cloning $MESH_LLM_REPO @ $MESH_LLM_REF into $SRC_DIR..."
    git clone --depth=1 --branch "$MESH_LLM_REF" "$MESH_LLM_REPO" "$SRC_DIR"
else
    echo "Updating $SRC_DIR..."
    git -C "$SRC_DIR" fetch --depth=1 origin "$MESH_LLM_REF"
    git -C "$SRC_DIR" checkout -f FETCH_HEAD
fi

# --- 3. apply patches ---------------------------------------------------
# Patch 1: replace native-tls (openssl) with rustls-tls on reqwest.
# openssl-sys vendoring fails under NDK; rustls is pure Rust.
CARGO="$SRC_DIR/mesh-llm/Cargo.toml"
if ! grep -q 'rustls-tls' "$CARGO"; then
    echo "Patching $CARGO to use rustls-tls..."
    # macOS sed needs -i ''
    sed -i.bak \
      's|reqwest = { version = "0.12", features = \["stream", "json"\] }|reqwest = { version = "0.12", default-features = false, features = ["stream", "json", "rustls-tls", "http2", "charset"] }|' \
      "$CARGO"
    rm -f "$CARGO.bak"
fi

# Patch 2: stub ui/dist so include_dir! finds a directory.
# The web console UI is a TypeScript build we don't need on Android.
UI_DIST="$SRC_DIR/mesh-llm/ui/dist"
if [ ! -d "$UI_DIST" ]; then
    echo "Stubbing $UI_DIST (headless build)..."
    mkdir -p "$UI_DIST"
    touch "$UI_DIST/.placeholder"
fi

# --- 4. build -----------------------------------------------------------
rustup target add aarch64-linux-android 2>/dev/null || true

echo ""
echo "Building mesh-llm for aarch64-linux-android (release)..."
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
export CC_aarch64_linux_android="$CLANG"
export CXX_aarch64_linux_android="$CLANG++"
export AR_aarch64_linux_android="$AR"
export RANLIB_aarch64_linux_android="$RANLIB"
export ANDROID_NDK_ROOT="$NDK"

( cd "$SRC_DIR" && cargo build --release --target aarch64-linux-android -p mesh-llm )

BIN_SRC="$SRC_DIR/target/aarch64-linux-android/release/mesh-llm"
BIN_OUT="$OUT_DIR/mesh-llm"
cp "$BIN_SRC" "$BIN_OUT"
"$STRIP" "$BIN_OUT"
SIZE=$(ls -lh "$BIN_OUT" | awk '{print $5}')

echo ""
echo "=== Build complete ==="
echo "Binary: $BIN_OUT ($SIZE)"
echo ""
echo "Deploy to Pixel:"
echo "  adb push $BIN_OUT /data/local/tmp/mesh-llm"
echo "  adb shell chmod 755 /data/local/tmp/mesh-llm"
echo ""
echo "Run on device (HOME must point at a writable dir — Android shell defaults to /):"
echo "  adb shell 'cd /data/local/tmp && HOME=/data/local/tmp ./mesh-llm --version'"

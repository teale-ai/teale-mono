#!/bin/sh
set -e

REPO="taylorhou/teale-mac-app"
APP_NAME="Teale"
APP_DIR="/Applications/${APP_NAME}.app"

echo ""
echo "  Installing Teale..."
echo ""

# ── Preflight ──

if [ "$(uname)" != "Darwin" ]; then
    echo "Error: Teale requires macOS. See https://github.com/$REPO for other platforms."
    exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "Error: Teale requires Apple Silicon (M1 or later)."
    echo "Your architecture: $ARCH"
    exit 1
fi

OS_VERSION=$(sw_vers -productVersion | cut -d. -f1)
if [ "$OS_VERSION" -lt 14 ] 2>/dev/null; then
    echo "Error: Teale requires macOS 14 Sonoma or later."
    echo "Your version: $(sw_vers -productVersion)"
    exit 1
fi

# ── Download from GitHub Releases ──

LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
    | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [ -n "$LATEST" ]; then
    URL="https://github.com/$REPO/releases/download/$LATEST/Teale.zip"
    echo "  Downloading Teale $LATEST..."

    TMPDIR=$(mktemp -d)
    trap "rm -rf $TMPDIR" EXIT

    if curl -fsSL "$URL" -o "$TMPDIR/Teale.zip" 2>/dev/null; then
        echo "  Installing to $APP_DIR..."

        # Remove previous install
        if [ -d "$APP_DIR" ]; then
            rm -rf "$APP_DIR"
        fi

        # Unzip preserving macOS metadata
        ditto -x -k "$TMPDIR/Teale.zip" /Applications

        # Strip quarantine flag (safety net for edge cases)
        xattr -cr "$APP_DIR" 2>/dev/null || true

        echo ""
        echo "  Teale $LATEST installed."
        echo ""
        echo "  Launching..."
        open "$APP_DIR"
        echo ""
        echo "  Look for the brain icon in your menu bar (top-right)."
        echo ""
        exit 0
    fi
fi

# ── Fallback: build from source ──

echo "  No pre-built release found. Building from source..."
echo "  This requires Xcode and takes a few minutes."
echo ""

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Error: Xcode is required to build from source."
    echo "Install it from the App Store, then retry."
    exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

git clone --depth 1 "https://github.com/$REPO.git" "$TMPDIR/teale"
cd "$TMPDIR/teale"

echo "  Building (this takes a few minutes)..."
./bundle.sh

if [ -d ".build/Teale.app" ]; then
    rm -rf "$APP_DIR" 2>/dev/null || true
    cp -R ".build/Teale.app" "$APP_DIR"
    xattr -cr "$APP_DIR" 2>/dev/null || true

    echo ""
    echo "  Teale installed."
    echo ""
    echo "  Launching..."
    open "$APP_DIR"
    echo ""
    echo "  Look for the brain icon in your menu bar (top-right)."
    echo ""
else
    echo "Error: Build failed. Please open an issue at:"
    echo "  https://github.com/$REPO/issues"
    exit 1
fi

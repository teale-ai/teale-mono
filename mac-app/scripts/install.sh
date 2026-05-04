#!/bin/sh
set -e

REPO="teale-ai/teale-mono"
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

# ── Optional: Rapid-MLX backend (Apache 2.0, ~25% faster than llama.cpp) ──
#
# Asks once after a successful install. Reads from /dev/tty so the prompt
# works under `curl … | sh`. In genuinely headless contexts (no tty), it
# silently prints a hint and skips the install.
offer_rapid_mlx_install() {
    if command -v rapid-mlx >/dev/null 2>&1; then
        return 0   # already installed
    fi

    if [ ! -t 1 ] && [ ! -e /dev/tty ]; then
        echo ""
        echo "  Optional: install Rapid-MLX for ~25% faster inference:"
        echo "    brew install raullenchai/rapid-mlx/rapid-mlx"
        return 0
    fi

    echo ""
    echo "  Optional: Rapid-MLX is a faster MLX engine (~25% higher TPS"
    echo "  than llama.cpp on Apple Silicon, Apache 2.0)."
    printf "  Install Rapid-MLX now via Homebrew? [y/N] "

    answer=""
    if [ -e /dev/tty ]; then
        read answer </dev/tty || answer=""
    else
        read answer || answer=""
    fi

    case "$answer" in
        y|Y|yes|YES|Yes)
            if ! command -v brew >/dev/null 2>&1; then
                echo "  Homebrew not found. Install it from https://brew.sh and re-run:"
                echo "    brew install raullenchai/rapid-mlx/rapid-mlx"
                return 0
            fi
            echo "  Installing Rapid-MLX (this can take a few minutes)..."
            if brew install raullenchai/rapid-mlx/rapid-mlx; then
                echo ""
                echo "  Rapid-MLX installed. In Teale, open Settings → Inference"
                echo "  Engine → Rapid-MLX, then pick a model alias (try qwen3.6-35b)."
            else
                echo "  Rapid-MLX install failed. You can retry later with:"
                echo "    brew install raullenchai/rapid-mlx/rapid-mlx"
            fi
            ;;
        *)
            echo "  Skipped. Install later with:"
            echo "    brew install raullenchai/rapid-mlx/rapid-mlx"
            ;;
    esac
}

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

        offer_rapid_mlx_install

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
cd "$TMPDIR/teale/mac-app"

echo "  Building (this takes a few minutes)..."
./bundle.sh

if [ -d ".build/Teale.app" ]; then
    rm -rf "$APP_DIR" 2>/dev/null || true
    cp -R ".build/Teale.app" "$APP_DIR"
    xattr -cr "$APP_DIR" 2>/dev/null || true

    echo ""
    echo "  Teale installed."

    offer_rapid_mlx_install

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

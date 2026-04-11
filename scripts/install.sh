#!/bin/sh
set -e

REPO="taylorhou/teale-mac-app"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="teale"

echo "Installing Teale..."

# Check macOS
if [ "$(uname)" != "Darwin" ]; then
    echo "Error: Teale only runs on macOS (Apple Silicon)."
    exit 1
fi

# Check Apple Silicon
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "Warning: Teale is optimized for Apple Silicon. Performance on $ARCH may be limited."
fi

# Try downloading pre-built binary from GitHub releases
LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/' || true)

if [ -n "$LATEST" ]; then
    URL="https://github.com/$REPO/releases/download/$LATEST/teale-macos-${ARCH}"
    echo "Downloading Teale $LATEST..."
    if curl -fsSL "$URL" -o /tmp/teale 2>/dev/null; then
        chmod +x /tmp/teale
        sudo mv /tmp/teale "$INSTALL_DIR/$BINARY_NAME"
        echo ""
        echo "Teale $LATEST installed to $INSTALL_DIR/$BINARY_NAME"
        print_quickstart
        exit 0
    fi
fi

# Fallback: build from source
echo "No pre-built binary available. Building from source..."
echo "This requires Xcode Command Line Tools and takes ~2 minutes."

if ! command -v swift >/dev/null 2>&1; then
    echo "Error: Swift not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

git clone --depth 1 "https://github.com/$REPO.git" "$TMPDIR/teale"
cd "$TMPDIR/teale"
swift build -c release --product teale 2>&1 | tail -5

sudo mkdir -p "$INSTALL_DIR"
sudo cp ".build/release/teale" "$INSTALL_DIR/$BINARY_NAME"

echo ""
echo "Teale installed to $INSTALL_DIR/$BINARY_NAME"
echo ""
echo "Get started:"
echo "  teale up                      # Start your node"
echo "  teale login                   # Optional: link to your account"
echo "  teale up --maximize-earnings  # Earn more credits"
echo "  teale status                  # Check node status"
echo ""

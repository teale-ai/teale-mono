#!/usr/bin/env bash
set -euo pipefail

# Build teale-node for all supported platforms.
# Requires: Rust toolchain, platform-specific linkers or Docker for cross-compilation.

cd "$(dirname "$0")/.."

echo "=== teale-node multi-platform build ==="

# Native build (current platform)
echo "Building native ($(rustc -vV | grep host | cut -d' ' -f2))..."
cargo build --release
echo "  -> target/release/teale-node"

# Linux x86_64 (requires Docker or cross-compiler)
if command -v cross &>/dev/null; then
    echo "Building Linux x86_64 (via cross)..."
    cross build --release --target x86_64-unknown-linux-gnu 2>/dev/null && \
        echo "  -> target/x86_64-unknown-linux-gnu/release/teale-node" || \
        echo "  SKIP: cross build failed (Docker required)"

    echo "Building Linux aarch64 (via cross)..."
    cross build --release --target aarch64-unknown-linux-gnu 2>/dev/null && \
        echo "  -> target/aarch64-unknown-linux-gnu/release/teale-node" || \
        echo "  SKIP: cross build failed (Docker required)"

    echo "Building Windows x86_64 (via cross)..."
    cross build --release --target x86_64-pc-windows-gnu 2>/dev/null && \
        echo "  -> target/x86_64-pc-windows-gnu/release/teale-node.exe" || \
        echo "  SKIP: cross build failed (Docker required)"

    echo "Building Android aarch64 (via cross)..."
    cross build --release --target aarch64-linux-android 2>/dev/null && \
        echo "  -> target/aarch64-linux-android/release/teale-node" || \
        echo "  SKIP: cross build failed (Docker/NDK required)"
else
    echo "SKIP cross-compilation: install 'cross' (cargo install cross) and Docker"
    echo "  Or build natively on each target platform with: cargo build --release"
fi

# Docker images
if command -v docker &>/dev/null; then
    echo "Building Docker image (CUDA)..."
    docker build -t teale/node . && echo "  -> teale/node (CUDA)" || echo "  SKIP: Docker build failed"

    echo "Building Docker image (CPU)..."
    docker build -f Dockerfile.cpu -t teale/node-cpu . && echo "  -> teale/node-cpu" || echo "  SKIP: Docker build failed"
else
    echo "SKIP Docker images: Docker not installed"
fi

echo "=== Build complete ==="

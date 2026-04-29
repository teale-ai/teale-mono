# teale-node Docker image — NVIDIA CUDA GPU support
# Build: docker build -t teale/node .
# Run:   docker run -v /path/to/models:/models --gpus all teale/node

# Stage 1: Build teale-node
FROM rust:1.85-bookworm AS builder

WORKDIR /build
COPY Cargo.toml Cargo.lock* ./
COPY src/ src/

RUN cargo build --release

# Stage 2: Runtime with llama.cpp
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install pre-built llama-server from llama.cpp releases.
# The latest releases no longer publish a dedicated Linux CUDA tarball, so we
# stage the generic Ubuntu x64 build here unless the caller mounts their own
# CUDA-enabled binary.
RUN set -eux; \
    release="$(curl -fsSL https://api.github.com/repos/ggml-org/llama.cpp/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"; \
    archive="llama-${release}-bin-ubuntu-x64.tar.gz"; \
    curl -fsSL "https://github.com/ggml-org/llama.cpp/releases/download/${release}/${archive}" -o /tmp/llama.tar.gz; \
    tar -xzf /tmp/llama.tar.gz -C /tmp; \
    server="$(find /tmp -type f -name llama-server -print -quit)"; \
    test -n "${server}"; \
    cp "${server}" /usr/local/bin/llama-server; \
    chmod +x /usr/local/bin/llama-server || \
    echo "WARNING: Could not download llama-server. Mount your own binary at /usr/local/bin/llama-server"

COPY --from=builder /build/target/release/teale-node /usr/local/bin/teale-node

# Default config location
WORKDIR /app
COPY teale-node.example.toml /app/teale-node.toml

# Model directory
VOLUME /models

# Override config values via environment or mount your own teale-node.toml
ENTRYPOINT ["teale-node", "--config", "/app/teale-node.toml"]

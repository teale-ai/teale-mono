# teale-node Docker image — NVIDIA CUDA runtime base
#
# teale-node is a member of the repo's Cargo workspace (version, edition and
# teale-protocol come from the root Cargo.toml), so build from the REPO ROOT:
#   docker build -f node/Dockerfile -t teale/node .
# Run:
#   docker run -v /path/to/models:/models -v /path/to/teale-node.toml:/app/teale-node.toml \
#     --gpus all teale/node

# Stage 1: Build teale-node
FROM rust:1-bookworm AS builder

WORKDIR /build
# Workspace manifest + every member manifest cargo needs to load the
# workspace; only teale-node (and teale-protocol) are compiled.
COPY Cargo.toml Cargo.lock ./
COPY protocol/ protocol/
COPY node/ node/
COPY gateway/ gateway/
COPY stress/ stress/
COPY cli/ cli/

RUN cargo build --release -p teale-node

# Stage 2: Runtime with llama.cpp
FROM nvidia/cuda:12.8.1-runtime-ubuntu24.04

# Keep in sync with .github/llama-cpp-version.
ARG LLAMA_RELEASE=b8840

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    libcurl4 \
    libgomp1 \
    && rm -rf /var/lib/apt/lists/*

# Pre-built llama-server from llama.cpp releases. Releases no longer publish a
# dedicated Linux CUDA tarball, so this stages the generic Ubuntu x64 build;
# mount your own CUDA-enabled binary at /usr/local/bin/llama-server for GPU.
RUN set -eux; \
    archive="llama-${LLAMA_RELEASE}-bin-ubuntu-x64.tar.gz"; \
    curl -fsSL "https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_RELEASE}/${archive}" -o /tmp/llama.tar.gz; \
    mkdir -p /tmp/llama /opt/llama; \
    tar -xzf /tmp/llama.tar.gz -C /tmp/llama; \
    server="$(find /tmp/llama -type f -name llama-server -print -quit)"; \
    test -n "${server}"; \
    cp -a "$(dirname "${server}")/." /opt/llama/; \
    ln -s /opt/llama/llama-server /usr/local/bin/llama-server; \
    rm -rf /tmp/llama /tmp/llama.tar.gz

ENV LD_LIBRARY_PATH=/opt/llama

COPY --from=builder /build/target/release/teale-node /usr/local/bin/teale-node

# Default config location (mount your own teale-node.toml over it)
WORKDIR /app
COPY node/teale-node.example.toml /app/teale-node.toml

# Model directory
VOLUME /models

ENTRYPOINT ["teale-node", "--config", "/app/teale-node.toml"]

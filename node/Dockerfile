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

# Install pre-built llama-server from llama.cpp releases
# Users can override this by mounting their own binary
RUN curl -L https://github.com/ggml-org/llama.cpp/releases/latest/download/llama-server-linux-cuda12-x64 \
    -o /usr/local/bin/llama-server && \
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

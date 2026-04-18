# Multi-stage build for the teale-mono workspace.
# Build context MUST be the monorepo root (passed via flyctl --dockerfile).
FROM rust:1.84-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config libssl-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
# teale-mono flat layout: Cargo.toml at root; crates as siblings.
COPY Cargo.toml Cargo.lock ./
COPY protocol protocol
COPY node node
COPY gateway gateway
COPY stress stress

RUN cargo build --release -p teale-gateway


FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -r -u 10001 teale && mkdir -p /data && chown teale:teale /data

WORKDIR /app
COPY --from=builder /build/target/release/teale-gateway /usr/local/bin/teale-gateway
COPY gateway/models.yaml /app/models.yaml
COPY gateway/gateway.toml /app/gateway.toml

USER teale
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

CMD ["/usr/local/bin/teale-gateway", "--config", "/app/gateway.toml", "--models-yaml", "/app/models.yaml"]

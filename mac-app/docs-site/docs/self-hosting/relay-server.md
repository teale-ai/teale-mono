# Self-Hosting the Relay Server

Run your own TealeNet relay for private deployments or development.

## Overview

The Teale relay is a Bun WebSocket server that handles peer registration, discovery, signaling, and fallback data transport. It is stateless and runs in a single process. You can self-host it for private networks, development, or to reduce latency for your region.

## Quick Start

### From Source

```bash
git clone https://github.com/teale-ai/teale.git
cd teale/relay
bun install
bun run server.ts
```

The server starts on port 3000 by default.

### Docker

```bash
docker build -t teale-relay .
docker run -p 3000:3000 teale-relay
```

### Fly.io

```bash
cd relay
fly deploy
```

The included `fly.toml` configures a single shared-cpu-1x instance with 256 MB RAM.

## Configuration

The relay server accepts configuration via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | HTTP and WebSocket listen port |

## Pointing Clients to Your Relay

After deploying your relay, configure Teale clients to use it:

**CLI:**
```bash
teale config set wan_relay_url wss://my-relay.example.com/ws
```

**macOS App:** Open Settings and update the WAN Relay URL field.

**TealeSDK:** Pass the relay URL in contributor options.

## HTTP Endpoints

Your relay exposes the same endpoints as the public relay:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Returns `{"ok": true, "peers": N}` |
| `GET` | `/peers` | List connected peers (truncated node IDs) |
| `GET` | `/metrics` | Server metrics |
| `GET` | `/ws` | WebSocket upgrade (requires `?node=` query parameter) |

### Metrics Response

```json
{
  "peers": 42,
  "messagesPerMinute": 156,
  "relaySessionsActive": 3,
  "uptimeSeconds": 86400,
  "totalMessages": 12345
}
```

## Monitoring

Use the `/metrics` endpoint for monitoring. Key metrics:

- **peers** -- number of connected WebSocket clients
- **messagesPerMinute** -- message throughput
- **relaySessionsActive** -- active relayed data sessions (peers communicating through the relay)
- **uptimeSeconds** -- server uptime

For production deployments, poll `/metrics` and alert on:
- Peer count dropping to zero (possible crash/restart)
- Messages per minute exceeding expected load
- Relay sessions growing unboundedly (possible leak)

## TLS / Reverse Proxy

The relay server itself does not terminate TLS. For `wss://` connections, place it behind a reverse proxy:

**Caddy:**
```
my-relay.example.com {
    reverse_proxy localhost:3000
}
```

**nginx:**
```nginx
server {
    listen 443 ssl;
    server_name my-relay.example.com;

    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    location / {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
    }
}
```

The `proxy_read_timeout` must be long enough to keep WebSocket connections alive (at least 60 seconds, ideally much longer).

## Resource Requirements

| Scale | CPU | RAM | Bandwidth | Cost |
|-------|-----|-----|-----------|------|
| Development | Shared | 256 MB | Minimal | Free |
| 1-100 peers | Shared | 256 MB | < 1 GB/mo | ~$4/mo |
| 100-1K peers | 1 vCPU | 512 MB | < 10 GB/mo | ~$6/mo |
| 1K-10K peers | 2 vCPU | 1 GB | < 100 GB/mo | ~$20/mo |

The relay is stateless and lightweight. A single process handles thousands of concurrent WebSocket connections.

## Limitations

- **Single process** -- no built-in horizontal scaling or sharding
- **In-memory state** -- peer registry is lost on restart (peers reconnect automatically)
- **No authentication** -- any node can register (authentication is at the Ed25519 identity level, not the relay level)

For scaling beyond a single process, see [Relay Scaling](relay-scaling.md).

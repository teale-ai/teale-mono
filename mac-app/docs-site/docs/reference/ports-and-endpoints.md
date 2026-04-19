# Ports and Endpoints

Network services, default ports, and configuration options.

## Services

| Service | Default Address | Configurable | Description |
|---------|----------------|-------------|-------------|
| HTTP API | `localhost:11435` | `--port` flag | OpenAI-compatible REST API for chat completions, model management, and app control |
| Relay | `wss://relay.teale.com/ws` | `wan_relay_url` setting | WebSocket relay server for WAN peer discovery and signaling |
| STUN | `stun.l.google.com:19302` | -- | STUN server for NAT type detection and public address discovery |
| Bonjour | `_teale._tcp` | -- | mDNS/Bonjour service type for LAN peer discovery |

## HTTP API

The local HTTP API runs on `localhost:11435` by default and provides an OpenAI-compatible interface.

### Changing the Port

**CLI:**
```bash
teale serve --port 8080
```

**Config:**
```bash
teale config set port 8080
```

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/chat/completions` | OpenAI-compatible chat completions |
| `GET` | `/v1/models` | List available models |
| `GET` | `/health` | Health check |
| `GET` | `/app/snapshot` | Full app state snapshot |
| `GET` | `/app/settings` | Current settings |
| `PUT` | `/app/settings` | Update settings |
| `GET` | `/app/models` | Model management |
| `POST` | `/app/models/load` | Load a model |
| `POST` | `/app/models/unload` | Unload a model |
| `GET` | `/app/peers` | Connected peers |
| `GET` | `/app/wallet` | Wallet balance and transactions |
| `GET` | `/app/ptn` | PTN memberships |
| `POST` | `/app/agent/run` | Run an agent task |
| `GET` | `/app/apikeys` | List API keys |
| `POST` | `/app/apikeys` | Create API key |
| `DELETE` | `/app/apikeys/:id` | Delete API key |

See [API Reference](../api/index.md) for full documentation of each endpoint.

## Relay Server

The relay server handles WAN peer discovery, signaling, and fallback data transport.

### Default Relay

```
wss://relay.teale.com/ws
```

### Custom Relay

Point your node to a self-hosted relay:

```bash
teale config set wan_relay_url wss://my-relay.example.com/ws
```

### Relay HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Server health and peer count |
| `GET` | `/peers` | Connected peers (truncated IDs) |
| `GET` | `/metrics` | Server metrics (messages/min, sessions, uptime) |
| `GET` | `/ws` | WebSocket upgrade (requires `?node=` parameter) |

See [Self-Hosting](../self-hosting/relay-server.md) for running your own relay.

## STUN Servers

Used for NAT traversal. These are public Google STUN servers.

| Server | Port |
|--------|------|
| `stun.l.google.com` | 19302 |
| `stun1.l.google.com` | 19302 |

STUN servers are not configurable in the current version.

## Bonjour / mDNS

LAN discovery uses Bonjour (macOS/iOS) or mDNS (Linux) to find peers on the local network.

| Field | Value |
|-------|-------|
| Service type | `_teale._tcp` |
| Domain | `local.` |
| TXT record | Contains node ID and loaded models |

Bonjour discovery is automatic and requires no configuration. It works without internet access.

## Firewall Rules

For direct P2P connections, the following ports may need to be allowed:

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 51820 | UDP | Inbound/Outbound | WireGuard-style P2P connections |
| 11435 | TCP | Inbound (localhost only) | Local HTTP API |

The relay connection uses standard HTTPS (port 443) which is typically allowed by firewalls.

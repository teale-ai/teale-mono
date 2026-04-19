# WAN Networking

Connect to Teale peers across the internet. WAN networking enables earning credits from remote users, joining the public inference network, and building geographically distributed clusters.

---

## Prerequisites

- Teale installed and running
- Internet connection

## Step 1: Enable WAN

```bash
teale config set wan_enabled true
```

Or in the desktop app: Settings > Networking > Enable WAN.

## Step 2: Automatic connection

Once WAN is enabled, Teale:

1. **Generates an Ed25519 identity** on first connect. The keypair is stored in the system Keychain. Your public key (64 hex characters) is your node ID on the network.
2. **Connects to the relay** at `wss://relay.teale.com/ws` via WebSocket. The relay handles peer discovery and signaling.
3. **Detects your NAT type** using STUN (Google STUN servers). This determines whether direct peer-to-peer connections are possible.

No manual configuration is needed for basic WAN participation.

## Step 3: Verify connection

```bash
teale status
```

Look for `wan: connected` and your public node ID in the output.

View WAN peers:

```bash
teale peers --wan
```

## How connections work

### Direct P2P (preferred)

When NAT allows it, Teale establishes direct QUIC connections between peers. This provides the lowest latency and highest throughput. Direct connections work when at least one peer has a permissive NAT (full cone or restricted cone).

### Relay fallback

When both peers are behind symmetric NAT, direct connections are not possible. Traffic routes through the relay server at `wss://relay.teale.com/ws`. This adds approximately 50-100ms of latency depending on geographic distance to the relay.

### End-to-end encryption

All peer-to-peer traffic --- whether direct or relayed --- is encrypted using the Noise protocol. The relay cannot read message contents. Only the two communicating peers hold the session keys.

## Custom relay

To use your own relay server instead of the default:

```bash
teale config set wan_relay_url wss://my-relay.example.com/ws
```

See [Self-Hosting a Relay](../self-hosting/relay-server.md) for relay server setup instructions.

## NAT types and connectivity

| Your NAT       | Peer's NAT     | Connection type |
|----------------|----------------|-----------------|
| Full cone      | Any            | Direct P2P      |
| Restricted     | Full cone      | Direct P2P      |
| Restricted     | Restricted     | Direct P2P      |
| Symmetric      | Full cone      | Direct P2P      |
| Symmetric      | Symmetric      | Relay fallback   |

Teale detects your NAT type automatically and chooses the best connection strategy.

## Monitoring WAN traffic

```bash
teale status              # Connection state, NAT type, relay status
teale peers --wan         # Connected WAN peers
```

---

## Next steps

- [LAN Cluster Setup](lan-cluster.md) --- connect peers on your local network
- [Set Up a Private Network](setup-ptn.md) --- create a PTN for trusted groups
- [Networking](../concepts/networking.md) --- full networking architecture
- [Earn Credits](earn-credits.md) --- monetize your node on the public network

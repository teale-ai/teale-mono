# LAN Cluster Setup

Connect multiple Macs on the same local network into a cluster. Requests automatically route to the best available peer based on loaded models and current load.

---

## Prerequisites

- Two or more Macs with Teale installed
- All Macs on the same local network (same subnet)

## Step 1: Enable clustering

On each Mac:

```bash
teale config set cluster_enabled true
```

Or in the desktop app: Settings > Cluster > Enable.

## Step 2: Verify peer discovery

Peers discover each other automatically via Bonjour (mDNS/DNS-SD). No manual IP configuration is needed.

Check that peers are visible:

```bash
teale peers --cluster
```

This lists all discovered LAN peers along with their node ID, loaded models, and hardware specs.

If peers are not appearing:

1. Confirm all Macs are on the same subnet.
2. Check that your router or firewall does not block mDNS (port 5353 UDP).
3. Verify Teale is running on each peer: `teale status`.

## Step 3: Set a cluster passcode (optional)

To restrict which nodes can join, set a shared passcode:

```bash
teale config set cluster_passcode "my-secret"
```

All peers must use the same passcode. Nodes with a mismatched or missing passcode are rejected during the handshake. Without a passcode, any Teale node on the local network can join.

## How routing works

When you send an inference request, Teale's smart routing picks the best peer:

1. **Model match.** Only peers with the requested model loaded are considered.
2. **Lowest load.** Among matching peers, the one with the fewest active requests wins.
3. **Local preference.** If your own node has the model loaded and is not overloaded, it serves the request locally without a network hop.

Routing is transparent --- you send requests to `localhost:11435` as usual, and Teale handles distribution.

## Model sharing

Peers can download models from each other instead of fetching from HuggingFace Hub. Models are transferred in 1 MB chunks over the persistent TCP connection.

To trigger a peer-to-peer model download:

```bash
teale models download llama-3.1-8b-instruct-4bit
```

Teale checks LAN peers first. If a peer has the model, it downloads from the peer. Otherwise, it falls back to HuggingFace Hub.

## Heartbeat intervals

Each peer connection maintains a health check heartbeat. The interval adapts based on cluster stability:

| Interval   | When used                            |
|------------|--------------------------------------|
| 5 seconds  | New connections, unstable peers       |
| 15 seconds | Default for established connections   |
| 30 seconds | Long-running stable clusters          |

A peer that misses three consecutive heartbeats is marked as disconnected and removed from the routing pool. It reconnects automatically when it comes back online.

## Monitoring

View cluster status at a glance:

```bash
teale status              # Your node's status
teale peers --cluster     # All LAN peers
```

---

## Next steps

- [WAN Networking](wan-networking.md) --- connect peers across the internet
- [Connect iPhone to Mac](connect-ios-companion.md) --- add iOS devices to your cluster
- [Networking](../concepts/networking.md) --- full networking architecture

# Relay Scaling Roadmap

How the relay architecture evolves from 1K to 10B devices.

## Key Insight

The relay's importance **inversely correlates with network size**. At small scale, the relay does everything (discovery, signaling, data transport). At large scale, the relay should only bootstrap -- peers find each other and communicate directly. The goal is not to build a relay that handles 10B connections, but to build a system where 10B devices do not need the relay.

## Current Architecture

- Single-process Bun WebSocket server
- 256 MB Fly.io VM, single region (Dallas)
- Stateless, in-memory peer registry
- Handles registration, discovery, signaling, and relayed data

**Cost:** ~$4/month

---

## 1K Devices

**What breaks:** Discover payloads get large (~500 KB). Broadcast storms from `peerJoined`/`peerLeft` are noticeable.

**Changes:**
1. Add server-side filtering to discover (model, tier, region)
2. Rate-limit discover calls (1 per 10 seconds per node)
3. Replace `peerJoined`/`peerLeft` broadcasts with poll-based discovery
4. Add `/metrics` endpoint for observability

**Architecture:** Single process, single region.

**Cost:** ~$6/month

---

## 10K Devices

**What breaks:** Single process hits memory wall. Single region means 150ms+ RTT for half the planet.

**Changes:**
1. Multi-region deployment: `sea` (Asia), `ams` (Europe), `nrt` (Japan)
2. Redis for shared state: peer registry moves from in-memory Map to Redis with TTL keys
3. Paginated discover: return top-K peers ranked by relevance (latency, model match, capacity)
4. Connection-aware routing: Fly.io routes to nearest region, cross-region signaling via Redis pub/sub

**Architecture:** Multiple stateless relay processes + Redis. Horizontal scaling within each region.

**Cost:** ~$50/month (3-4 regions + Redis)

---

## 100K Devices

**What breaks:** Redis becomes a hotspot for discovery queries. Relayed data at scale burns bandwidth.

**Changes:**
1. Split signaling from relay data: separate Signal server (register, discover, offer/answer) from Relay server (relayData)
2. Tiered discovery: weight results by same region, compatible hardware, and capacity
3. Better NAT traversal: target less than 5% of traffic flowing through relay
4. Distributed peer registry: Redis Cluster, DragonflyDB, or SQLite on Fly.io LiteFS

**Architecture:** Signal fleet + Relay fleet + Distributed KV. Each independently scalable.

**Cost:** ~$200-500/month

---

## 1M Devices

**What breaks:** Centralized discovery cannot scale -- 1M devices polling overwhelms any central service.

**Changes:**
1. Gossip-based peer discovery: peers exchange peer lists with neighbors (like BitTorrent PEX)
2. Relay becomes bootstrap-only: new devices get initial peers from relay, then disconnect
3. DHT for model routing: Kademlia-style distributed hash table for finding model-serving peers
4. Super-nodes: well-connected peers with public IPs volunteer as discovery hubs
5. Geographic clustering: peers self-organize into regional clusters

**Architecture:** Bootstrap relay (tiny) + DHT + Gossip + Super-nodes.

**Cost:** ~$50/month (relay is just a seed list)

---

## 10M Devices

**What breaks:** Gossip convergence time. DHT churn. Bootstrap relay hammered by new devices.

**Changes:**
1. Hierarchical gossip: regions, zones, and clusters with elected coordinators
2. Multiple bootstrap relays behind anycast DNS
3. Persistent peer identity + reputation system
4. Model-specific overlay networks: each popular model has its own gossip cluster
5. Invest heavily in NAT traversal (even 5% relay fallback = 500K relayed connections)

**Architecture:** Hierarchical gossip + Model overlays + Regional bootstrap + Reputation system.

**Cost:** ~$200/month (bootstrap infrastructure)

---

## 100M Devices

**What breaks:** DHT lookup latency. Gossip bandwidth overhead. Protocol upgrade coordination.

**Changes:**
1. Adopt libp2p: handles NAT traversal, peer routing, gossip (GossipSub), DHT (Kademlia), and relay (Circuit Relay v2)
2. Content-addressed model distribution (like IPFS)
3. Protocol versioning and gradual rollout
4. Sybil resistance: proof-of-hardware, stake-based reputation, certificate-based identity
5. Monitoring via sampling (0.1% of traffic)

**Architecture:** libp2p mesh + Content-addressed models + Certificate trust.

**Cost:** ~$500/month (Teale relay is one of many bootstrap seeds)

---

## 1B Devices

**Changes:**
1. Federated architecture: regional operators run interoperable relays (like email)
2. Sparse routing tables: O(log N) peer knowledge (Kademlia), ~30 hops max, 3-5 in practice
3. Edge caching of popular models (CDN-like distribution)
4. Formalized economic incentives: electricity-based pricing becomes essential
5. Multi-transport: WebSocket, QUIC, WebTransport, TCP, Bluetooth mesh

**Architecture:** Federated mesh + Economic incentives + Multi-transport + Edge model caching. This is an internet-scale protocol.

---

## 10B Devices

At this scale (~15B connected devices on Earth), Teale is a protocol standard, not a product.

1. Open standard like HTTP or SMTP, multiple implementations
2. Hardware-native support: OS networking stacks integrate Teale discovery (like mDNS/Bonjour but for AI)
3. Zero-infrastructure bootstrap: local broadcast, Bluetooth, QR codes, NFC
4. Planetary-scale model sharding across thousands of devices

**Architecture:** Open protocol standard + OS-level integration. There is no relay.

---

## Summary

| Scale | Relay Role | Architecture | Cost |
|-------|-----------|-------------|------|
| 1K | Central hub | Single process + filters | $6/mo |
| 10K | Regional hubs | Multi-region + Redis | $50/mo |
| 100K | Signal + relay split | Service fleet + distributed KV | $500/mo |
| 1M | Bootstrap seed | DHT + gossip + super-nodes | $50/mo |
| 10M | Regional bootstrap | Hierarchical gossip + model overlays | $200/mo |
| 100M | One of many seeds | libp2p mesh + content-addressed models | $500/mo |
| 1B | Federation operator | Federated protocol + incentives | N/A |
| 10B | Does not exist | Open standard in hardware | $0 |

The relay cost does not scale linearly because the relay's job shrinks as the network matures. This aligns with Teale's zero-central-storage philosophy.

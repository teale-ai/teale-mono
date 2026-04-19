# Relay Scaling Roadmap: 1K to 10B Devices

## Context

`relay.teale.com/ws` is a single-process Bun WebSocket server on a 256MB Fly.io VM in Dallas. It handles peer registration, discovery, signaling, and relayed data transport. Currently stateless, in-memory, no horizontal scaling path. This document maps what breaks and what changes at each order of magnitude.

## Key Assumption

The relay's job shrinks as the network matures. At small scale, the relay does everything (discovery + signaling + data transport). At large scale, the relay should only bootstrap — peers find each other and communicate directly. **The goal is not to build a relay that handles 10B WebSocket connections. It's to build a system where 10B devices don't need the relay.**

---

## Current Cost: ~$3-4/month

- Fly.io shared-cpu-1x, 256MB RAM, single region (`dfw`), always-on
- Bandwidth well within Fly.io's 100GB free tier
- Stateless pass-through — no storage costs

## Current Bottlenecks

1. **Broadcast storms** — `peerJoined`/`peerLeft` fan out to every connected peer: O(N) per event
2. **Discover returns full peer list** — serializes all peers into one JSON blob
3. **In-memory Map** — all peer state in a single process
4. **Single region** — 150ms+ RTT for peers far from Dallas
5. **No horizontal scaling path** — no shared state, no sharding

---

## Tier 1: 1K devices

**What breaks:** Broadcast storms are annoying but survivable. Discover payloads (~500KB) are chunky.

**Changes:**
- Bump VM to 512MB (~$6/mo)
- Add `model` and `tier` filters to discover (server-side filtering instead of returning all peers)
- Rate-limit discover calls (1/30s per node)
- Replace full `peerJoined`/`peerLeft` broadcasts with opt-in subscriptions (subscribe to specific models/tiers)
- Add metrics endpoint (connected peers, messages/sec, relay bandwidth)

**Architecture:** Still single process, single region. Fine.

---

## Tier 2: 10K devices

**What breaks:** Single process hits memory wall (~10-50K WS connections on 1GB). Single region means 150ms+ RTT for half the planet. Broadcast is now untenable even with subscriptions.

**Changes:**
- **Multi-region deployment**: Add `sea` (Asia), `ams` (Europe), `nrt` (Japan) relay instances
- **Redis for shared state**: Peer registry moves from in-memory Map to Redis with TTL keys. Each relay instance is stateless and reads/writes to shared Redis.
- **Drop live presence entirely**: No more `peerJoined`/`peerLeft` broadcasts. Peers poll discover on a timer or when they need a peer. Eliminates O(N) fan-out completely.
- **Paginated discover**: Return top-K peers ranked by relevance (latency, model match, capacity) instead of all peers.
- **Connection-aware routing**: Fly.io routes to nearest region automatically. Cross-region signaling forwarded via Redis pub/sub.

**Architecture:** Multiple stateless relay processes + Redis. Horizontal scaling within each region.

**Cost:** ~$30-50/mo (3-4 regions x $8/mo + Redis ~$10/mo)

---

## Tier 3: 100K devices

**What breaks:** Redis becomes a hotspot for discovery queries. Relayed data transport at scale burns bandwidth. Signaling volume is high.

**Changes:**
- **Separate signaling from relay data**: Split into two services:
  - **Signal server**: Handles register, discover, offer/answer/ICE. Lightweight, stateless, reads from distributed peer registry.
  - **Relay server**: Handles only `relayData` for peers that can't connect directly. Scales independently based on bandwidth demand.
- **Tiered discovery**: Discovery returns peers weighted by same region first, compatible hardware/model, and capacity/load.
- **Push peers harder toward direct connections**: Invest in better NAT traversal (TURN-like relay as last resort, STUN for most cases). Target <5% of traffic flowing through relay.
- **Distributed peer registry**: Redis Cluster, DragonflyDB, or SQLite on Fly.io LiteFS for read replicas.

**Architecture:** Signal fleet + Relay fleet + Distributed KV. Each independently scalable.

**Cost:** ~$200-500/mo

---

## Tier 4: 1M devices

**What breaks:** Centralized discovery can't scale — even paginated, the registry is being hammered by 1M devices polling. Centralized anything is a bottleneck.

**Changes:**
- **Gossip-based peer discovery**: Peers maintain a local view of the network by exchanging peer lists with their neighbors (like BitTorrent PEX — Peer Exchange). Each peer knows ~100-500 other peers. Discovery becomes decentralized.
- **Relay becomes a bootstrap service only**: New devices connect to the relay to get an initial set of peers, then disconnect. Ongoing discovery happens peer-to-peer via gossip.
- **DHT (Distributed Hash Table) for model routing**: `GET model:llama-3.2-3b` returns a set of peers serving that model. Peers self-publish to the DHT. Chord or Kademlia-style routing.
- **Super-nodes**: Well-connected peers with public IPs and good uptime volunteer as discovery hubs. Relay maintains a curated list of super-nodes. New peers bootstrap from super-nodes.
- **Geographic clustering**: Peers self-organize into regional clusters. Intra-cluster discovery is local gossip. Inter-cluster routing goes through designated gateway peers.

**Architecture:** Bootstrap relay (tiny) + DHT + Gossip protocol + Super-nodes. The relay is now a seed list, not a central service.

**Cost:** Relay itself drops to ~$50/mo (just bootstrap). Network cost shifts to participant peers.

---

## Tier 5: 10M devices

**What breaks:** Gossip protocol convergence time. DHT churn (10M devices joining/leaving). Bootstrap relay gets hammered by new devices.

**Changes:**
- **Hierarchical gossip**: Organize into regions > zones > clusters. Gossip stays within cluster, cross-cluster routing via elected coordinators.
- **Multiple bootstrap relays behind anycast DNS**: `relay.teale.com` resolves to nearest of 20+ global bootstrap nodes via GeoDNS or anycast. Each bootstrap node only knows about peers in its region.
- **Persistent peer identity + reputation**: Peers build reputation over time (uptime, bandwidth contributed, inference quality). High-reputation peers become preferred routes and super-nodes.
- **Model-specific overlays**: Each popular model has its own overlay network. `llama-3.2-3b` peers form their own gossip cluster. Reduces routing noise.
- **NAT traversal success rate is critical**: Even 5% relay fallback = 500K relayed connections. Invest heavily in ICE/STUN/TURN infrastructure or use existing networks (libp2p).

**Architecture:** Hierarchical gossip + Model overlays + Regional bootstrap + Reputation system. Fully decentralized for steady-state operation.

**Cost:** Bootstrap infra ~$200/mo. The network itself is self-sustaining.

---

## Tier 6: 100M devices

**What breaks:** DHT lookup latency across 100M nodes. Gossip protocol bandwidth overhead. Software update/protocol upgrade coordination.

**Changes:**
- **Adopt proven P2P infrastructure**: At this scale, you're reimplementing BitTorrent/IPFS. Use libp2p as the transport layer — it handles NAT traversal, peer routing, gossip (GossipSub), DHT (Kademlia), and relay (Circuit Relay v2) out of the box.
- **Content-addressed model distribution**: Models distributed via content-addressed blocks (like IPFS). Peers serving the same model naturally cluster.
- **Protocol versioning and gradual rollout**: Can't upgrade 100M devices at once. Need protocol negotiation, backward compatibility, and canary rollouts.
- **Trust and abuse prevention**: Sybil resistance becomes critical. Proof-of-hardware (attested by Secure Enclave/TPM), stake-based reputation, or certificate-based identity (Ed25519 keys + PTN certificates already exist).
- **Monitoring shifts to sampling**: Can't monitor every node. Sample 0.1% of traffic for health metrics. Anomaly detection for abuse.

**Architecture:** libp2p-based mesh + Content-addressed model distribution + Certificate-based trust. Teale relay is just one of many bootstrap seeds.

---

## Tier 7: 1B devices

**What breaks:** Larger than BitTorrent's peak. Protocol overhead from gossiping across 1B nodes. Geographic and political fragmentation (firewalls, regulations).

**Changes:**
- **Federated architecture**: Regional operators run Teale federations (think email — anyone can run a relay, they interoperate). Teale Inc. runs the default federation, but enterprises/countries can run their own.
- **Sparse routing tables**: Each peer knows O(log N) other peers (Kademlia-style). For 1B devices, that's ~30 routing hops max for any lookup. In practice, caching and locality reduce this to 3-5 hops.
- **Edge caching of popular models**: If 100M devices want Llama 3.2 3B, don't route them all through DHT. CDN-like model distribution — popular models are everywhere, cached at the edge.
- **Economic incentives formalized**: Electricity-based pricing (already a TealeNet concept) becomes essential. Peers are compensated for bandwidth, compute, and relay services. Without incentives, free-riders dominate.
- **Multi-transport**: Not every device speaks WebSocket. Support QUIC, WebTransport, TCP, Bluetooth mesh for IoT. The relay protocol becomes transport-agnostic.

**Architecture:** Federated mesh network + Economic incentive layer + Multi-transport + Edge model caching. This is an internet-scale protocol, not a service.

---

## Tier 8: 10B devices

**What breaks:** There are ~8B humans and ~15B connected devices on Earth. This is the entire internet.

**Changes:**
- **Teale IS the protocol, not a product**: At this scale, Teale is an open standard like HTTP or SMTP. Multiple implementations, multiple relay operators, governed by a standards body or foundation.
- **Hardware-native support**: Inference routing baked into OS networking stacks or chipsets. Apple, Qualcomm, etc. ship Teale-compatible discovery as a system service (like mDNS/Bonjour but for AI inference).
- **Zero-infrastructure bootstrap**: Devices discover each other via local network broadcast, Bluetooth, QR codes, NFC — no internet bootstrap needed. The relay doesn't exist anymore; it's been replaced by the protocol itself embedded in every device.
- **Planetary-scale model sharding**: Large models are sharded across thousands of devices. Routing a query to "GPT-5" means finding the right shard group, not a single peer. This is essentially a distributed supercomputer.

**Architecture:** Open protocol standard + OS-level integration + Multi-modal discovery + Distributed model sharding. There is no relay.

---

## Summary

| Scale | Relay Role | Key Architecture | Estimated Infra Cost |
|-------|-----------|-----------------|---------------------|
| 1K | Central hub | Single process + filters | $6/mo |
| 10K | Regional hubs | Multi-region + Redis | $50/mo |
| 100K | Signal + relay split | Service fleet + distributed KV | $500/mo |
| 1M | Bootstrap seed | DHT + gossip + super-nodes | $50/mo |
| 10M | Regional bootstrap | Hierarchical gossip + model overlays | $200/mo |
| 100M | One of many seeds | libp2p mesh + content-addressed models | $500/mo |
| 1B | Federation operator | Federated protocol + economic incentives | N/A (protocol) |
| 10B | Doesn't exist | Open standard baked into hardware | $0 (it's a protocol) |

The relay's cost doesn't scale linearly because **the relay's importance scales inversely with network size**. The roadmap is about progressively decentralizing until the relay disappears entirely — which aligns with Teale's zero-central-storage philosophy.

## Practical Next Steps (targeting 1K-10K)

1. Add server-side filtering to discover (model, tier, region)
2. Drop `peerJoined`/`peerLeft` broadcasts — make discover poll-based
3. Add a `/metrics` endpoint for observability
4. Prepare for multi-region by extracting peer state into a Redis-compatible store
5. Rate-limit discover and register calls

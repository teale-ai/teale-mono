# NAT Traversal

How TealeNet nodes establish direct connections through NAT devices.

## Overview

Most consumer devices sit behind NAT (Network Address Translation), which prevents inbound connections. TealeNet uses STUN for NAT type detection and address discovery, ICE-style candidate exchange for hole-punching, and relay fallback when direct connections are impossible.

## STUN

TealeNet uses STUN (Session Traversal Utilities for NAT, RFC 5389) to discover a node's public IP address and NAT type.

### Binding Request

1. Send a STUN Binding Request to a STUN server
2. The request contains the magic cookie `0x2112A442` in the header
3. The server responds with an `XorMappedAddress` attribute containing the node's public IP and port (XOR'd with the magic cookie)

### Default STUN Servers

| Server | Port |
|--------|------|
| `stun.l.google.com` | 19302 |
| `stun1.l.google.com` | 19302 |

## NAT Types

| Type | Value | Direct Connection | Description |
|------|-------|-------------------|-------------|
| Full Cone | `fullCone` | Yes | Any external host can send to the mapped address |
| Restricted Cone | `restrictedCone` | Yes | Only hosts the node has sent to can reply |
| Port Restricted | `portRestricted` | Yes (with hole-punch) | Only the specific host:port pair can reply |
| Symmetric | `symmetric` | No (relay required) | Different mapping for each destination; unpredictable external port |
| Unknown | `unknown` | Attempt, then relay | NAT type could not be determined |

## Hole-Punching

Hole-punching works for `fullCone`, `restrictedCone`, and `portRestricted` NAT types. Both peers simultaneously send packets to each other's discovered public address, creating NAT mappings that allow bidirectional traffic.

### Procedure

1. Both nodes discover their public address via STUN
2. Exchange addresses through relay signaling (`offer`/`answer`)
3. Both nodes simultaneously send packets to each other's public address
4. NAT devices create or widen mappings, allowing replies through
5. Once bidirectional traffic flows, the direct connection is established

## Symmetric NAT

Symmetric NAT assigns a different external port for each destination. Since the external port is unpredictable, hole-punching fails. These connections **require relay fallback**.

Symmetric NAT is common on:
- Corporate networks
- Mobile carrier networks (some)
- Strict firewall configurations

## Signaling Flow

Connection establishment uses `offer` and `answer` messages through the relay.

### 1. Offer

The initiator sends an `offer` with its connection information:

```json
{
  "offer": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "uuid",
    "connectionInfo": {
      "publicIP": "1.2.3.4",
      "publicPort": 51820,
      "localIP": "192.168.1.10",
      "localPort": 51820,
      "natType": "fullCone",
      "wgPublicKey": "hex..."
    },
    "signature": "hex..."
  }
}
```

### 2. Answer

The responder replies with its own connection information:

```json
{
  "answer": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "uuid",
    "connectionInfo": {
      "publicIP": "5.6.7.8",
      "publicPort": 51820,
      "localIP": "192.168.2.20",
      "localPort": 51820,
      "natType": "restrictedCone",
      "wgPublicKey": "hex..."
    },
    "signature": "hex..."
  }
}
```

### 3. ICE Candidates

Additional candidates can be exchanged via `iceCandidate` messages:

```json
{
  "iceCandidate": {
    "fromNodeID": "...",
    "toNodeID": "...",
    "sessionID": "uuid",
    "candidate": {
      "ip": "1.2.3.4",
      "port": 51820,
      "type": "serverReflexive",
      "priority": 100
    }
  }
}
```

## ICE Candidate Types

| Type | Description | Priority |
|------|-------------|----------|
| `host` | Local network address (LAN IP) | Highest |
| `serverReflexive` | Public address discovered via STUN | Medium |
| `relayed` | Address allocated by a relay/TURN server | Lowest |

Candidates are tried in priority order. Host candidates enable direct LAN connections. Server reflexive candidates enable connections through NAT. Relayed candidates are the fallback.

## Connection Decision Matrix

| Initiator NAT | Responder NAT | Strategy |
|--------------|---------------|----------|
| Full Cone | Any | Direct connection |
| Restricted Cone | Full Cone / Restricted Cone | Hole-punch |
| Port Restricted | Full Cone / Restricted Cone / Port Restricted | Hole-punch |
| Symmetric | Any | Relay fallback |
| Any | Symmetric | Relay fallback |

## Relay Fallback

When direct connection is not possible:

1. Initiator sends `relayOpen` to the relay server
2. Relay forwards to the target peer
3. Target replies with `relayReady`
4. Both peers exchange data via `relayData` messages through the relay

Relay connections have higher latency and consume relay server bandwidth, but they always work regardless of NAT configuration.

## LAN Optimization

On the local network, Teale uses Bonjour/mDNS (`_teale._tcp`) for discovery. LAN connections bypass the relay entirely, connecting directly via TCP on the discovered local address. No NAT traversal is needed.

# Private TealeNet

A Private TealeNet (PTN) is a private subnet of Teale nodes with certificate-based membership, guaranteed capacity, and fixed pricing.

## Why use a PTN

The public Teale network (WWTN) is open to everyone, with market-driven pricing and best-effort scheduling. A PTN gives you:

- **Known participants.** Only members with valid certificates can join.
- **Guaranteed capacity.** PTN traffic gets 70% of scheduling weight via Weighted Fair Queuing.
- **Fixed pricing.** Administrators set the rate --- no auctions, no price fluctuations.
- **Privacy.** PTN IDs are broadcast in node capabilities, so only members of the same PTN communicate for PTN-scoped requests.

## How membership works

### Certificate Authority

Every PTN has a Certificate Authority (CA), which is an Ed25519 keypair. The CA's public key serves as the PTN ID --- a 64-character hex string that uniquely identifies the network.

The node that creates the PTN holds the CA private key and can issue certificates and invite tokens.

### Invite flow

```
CA Admin                    New Member
   |                            |
   |--- Generate invite token ->|
   |    (nonce + expiry)        |
   |                            |
   |<-- Submit join request ----|
   |    (node ID + invite)      |
   |                            |
   |--- Issue certificate ----->|
   |    (signed by CA)          |
   |                            |
```

1. An admin generates a time-limited invite token containing a nonce and expiry timestamp.
2. The invite is shared out-of-band (message, email, QR code).
3. The invited node submits a join request with its Ed25519 public key and the invite token.
4. The CA verifies the invite, then issues a signed certificate for the new member.

### Certificates

A PTN certificate contains:

| Field | Description |
|-------|-------------|
| `ptnID` | The CA's public key hex (identifies the network) |
| `nodeID` | The member's Ed25519 public key hex |
| `role` | `admin`, `provider`, or `consumer` |
| `issuedAt` | Unix timestamp of issuance |
| `expiresAt` | Optional expiry timestamp (nil = no expiry) |
| `issuerNodeID` | The public key of the node that issued the certificate |

Certificates are signed with Ed25519 over canonical (sorted-keys) JSON. Any node can verify a certificate against the PTN's CA public key without contacting the CA.

### Roles

| Role | Can invite | Can serve inference | Can request inference |
|------|-----------|--------------------|--------------------|
| `admin` | Yes | Yes | Yes |
| `provider` | No | Yes | Yes |
| `consumer` | No | No | Yes |

Admins can issue certificates and manage membership. Providers serve inference to other PTN members. Consumers can only request inference, not serve it.

## Network isolation

Each node broadcasts its PTN memberships as part of its capabilities during discovery. When a PTN member sends an inference request scoped to their PTN:

1. The request scheduler checks the PTN ID against available providers.
2. Only providers with a valid certificate for that PTN are considered.
3. The request gets 70% WFQ priority over public WWTN traffic.
4. Pricing uses the PTN's fixed rate, not the WWTN auction.

PTN traffic and WWTN traffic share the same physical connections and relay infrastructure. Isolation is logical, enforced by certificate verification at the application layer.

## Certificate lifecycle

- **Issuance:** CA signs a certificate for a new member after verifying their invite token.
- **Verification:** Any node verifies a certificate by checking its Ed25519 signature against the CA public key.
- **Expiry:** Certificates can have an optional expiry timestamp. Expired certificates are rejected.
- **Revocation:** Admins can revoke certificates. Revoked node IDs are tracked in the PTN store.

## Use cases

- **Company internal AI.** Run inference on company Macs, accessible only to employees. No data leaves the organization's devices.
- **Research groups.** Share compute across lab machines with guaranteed capacity for experiments.
- **Gaming clans.** Dedicated AI capacity for game-related inference without competing with public traffic.
- **Families.** Connect household Macs into a private inference pool with no configuration beyond scanning an invite QR code.

## Related pages

- [Security Model](security-model.md) --- Ed25519 identity and certificate verification
- [Credit Economy](credit-economy.md) --- fixed pricing vs. WWTN auctions
- [Networking](networking.md) --- how PTN traffic travels over the same infrastructure
- To set up a PTN, see [Set Up a Private Network](../guides/setup-ptn.md)

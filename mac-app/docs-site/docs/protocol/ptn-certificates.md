# PTN Certificates

Certificate-based membership for Private TealeNets.

## Overview

A Private TealeNet (PTN) is an invite-only subnet where access is controlled by a certificate authority (CA). The PTN creator generates an Ed25519 CA keypair. The CA public key becomes the PTN ID. Membership is granted by issuing signed certificates to nodes.

## PTN Creation

When a user creates a new PTN:

1. Generate a new Ed25519 keypair (the CA keypair)
2. The CA public key (hex-encoded) becomes the PTN ID
3. The creator's node receives an `admin` certificate signed by the CA
4. The CA private key is stored on the creator's device

```
PTN ID = hex_encode(ca_public_key)   // 64 hex characters
```

## Certificate Structure

### PTNCertificatePayload

The payload that gets signed by the CA.

```json
{
  "ptnID": "a1b2c3...ca-public-key-hex",
  "nodeID": "d4e5f6...member-public-key-hex",
  "role": "provider",
  "issuedAt": 1713100000.0,
  "expiresAt": 1744636000.0,
  "issuerNodeID": "a1b2c3...issuer-node-hex"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ptnID` | string | CA public key hex (identifies the PTN) |
| `nodeID` | string | Member's Ed25519 public key hex |
| `role` | string | One of: `admin`, `provider`, `consumer` |
| `issuedAt` | number | Unix timestamp of issuance |
| `expiresAt` | number or null | Unix timestamp of expiry (null = no expiry) |
| `issuerNodeID` | string | Node ID of the admin who issued this certificate |

### PTNCertificate

The signed certificate that a member holds.

```json
{
  "payload": { ...PTNCertificatePayload... },
  "signature": "hex-encoded-ed25519-signature"
}
```

## Signature

The signature is computed over the **canonical JSON** encoding of the payload:

1. Encode the `PTNCertificatePayload` as JSON with **sorted keys** (deterministic key ordering)
2. Sign the resulting bytes with the CA's Ed25519 private key
3. Hex-encode the signature

```
canonical_json = json_encode(payload, sorted_keys=true)
signature = ed25519_sign(ca_private_key, canonical_json)
hex_signature = hex_encode(signature)
```

Sorted keys are critical for reproducible signatures. Different JSON encoders may produce different key orderings, so canonicalization ensures that any implementation can verify signatures produced by any other.

## Verification

To verify a certificate:

1. Obtain the PTN's CA public key (from the PTN ID or from the join response)
2. Compute the canonical JSON of the certificate payload (sorted keys)
3. Verify the Ed25519 signature against the CA public key
4. Check that `expiresAt` is null or in the future

```
canonical_json = json_encode(certificate.payload, sorted_keys=true)
valid = ed25519_verify(ca_public_key, canonical_json, certificate.signature)
expired = certificate.payload.expiresAt != null && now > certificate.payload.expiresAt
```

## Roles

| Role | Capabilities |
|------|-------------|
| `admin` | Can issue certificates, invite new members, revoke memberships, manage PTN settings |
| `provider` | Can serve inference requests to PTN members |
| `consumer` | Can request inference from PTN providers |

Admins have all the capabilities of providers and consumers in addition to management privileges.

## Invite Tokens

Invitations are shared as base64url-encoded JSON tokens.

### Token Structure

```json
{
  "ptnID": "a1b2c3...",
  "ptnName": "My Team",
  "inviterNodeID": "d4e5f6...",
  "nonce": "hex-encoded-16-random-bytes",
  "expiresAt": 1713103600.0
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ptnID` | string | PTN to join |
| `ptnName` | string | Human-readable PTN name |
| `inviterNodeID` | string | Node ID of the admin who created the invite |
| `nonce` | string | 16 random bytes hex-encoded (prevents replay) |
| `expiresAt` | number | Unix timestamp of token expiry |

**Default validity:** 1 hour.

### Encoding

Tokens are encoded as base64url (RFC 4648 Section 5) of the JSON, producing a string of approximately 100-150 characters that can be shared via any text channel.

```
token_string = base64url_encode(json_encode(invite_token))
```

## Join Flow

1. Admin creates an invite token and shares the encoded string
2. Joiner decodes the token and verifies it has not expired
3. Joiner sends a `ptnJoinRequest` to the inviter's node via relay:
   ```json
   {
     "inviteToken": { ...PTNInviteToken... },
     "joinerNodeID": "...",
     "joinerDisplayName": "My Laptop"
   }
   ```
4. Inviter validates the token, issues a certificate, and sends a `ptnJoinResponse`:
   ```json
   {
     "certificate": { ...PTNCertificate... },
     "ptnName": "My Team",
     "caPublicKeyHex": "a1b2c3...",
     "accepted": true
   }
   ```
5. Joiner stores the certificate and CA public key locally
6. Joiner advertises the PTN ID in `capabilities.ptnIDs` during subsequent registrations

## CA Key Transfer

For multi-admin setups, the CA private key can be exported from one admin node and imported on another. This allows multiple devices to issue certificates. The transfer should be done over an encrypted channel (e.g., a Noise-encrypted peer connection).

## Security Considerations

1. **CA key is the root of trust.** Compromise of the CA private key means an attacker can issue certificates for any node. Protect it accordingly.
2. **Nonce in invites prevents replay.** Each invite token has a unique 16-byte nonce. Even if intercepted, a token can only be used once and expires quickly.
3. **Certificate expiry.** Set `expiresAt` for non-admin certificates to limit the blast radius of compromised node keys.
4. **Canonical JSON is required.** Signature verification will fail if the JSON encoder does not produce sorted keys.

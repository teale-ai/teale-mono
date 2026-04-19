# Private TealeNet (PTN)

Endpoints for managing Private TealeNet memberships. A PTN is a closed, CA-signed network of trusted nodes that can share inference capacity privately.

---

## List PTN Memberships

```
GET /v1/app/ptn
```

Returns all PTN memberships for this node.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Response

```json
{
  "memberships": [
    {
      "ptnID": "ptn-abc123",
      "name": "Acme Corp",
      "role": "admin",
      "members": 12,
      "status": "active"
    }
  ]
}
```

### Example

```bash
curl http://localhost:11435/v1/app/ptn
```

---

## Create PTN

```
POST /v1/app/ptn/create
```

Create a new Private TealeNet. The creating node becomes the initial admin and CA.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | Yes | Display name for the PTN |

```json
{
  "name": "Acme Corp"
}
```

### Response

```json
{
  "ptnID": "ptn-abc123",
  "name": "Acme Corp",
  "role": "admin"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/ptn/create \
  -H "Content-Type: application/json" \
  -d '{"name": "Acme Corp"}'
```

---

## Generate Invite

```
POST /v1/app/ptn/invite
```

Generate a one-time invite code that another node can use to request membership.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `ptnID` | string | Yes | ID of the PTN to generate an invite for |

```json
{
  "ptnID": "ptn-abc123"
}
```

### Response

```json
{
  "inviteCode": "invite-xyz789..."
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/ptn/invite \
  -H "Content-Type: application/json" \
  -d '{"ptnID": "ptn-abc123"}'
```

---

## Issue Certificate

```
POST /v1/app/ptn/issue-cert
```

Issue a signed membership certificate to a node, granting it access to the PTN.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `ptnID` | string | Yes | ID of the PTN |
| `nodeID` | string | Yes | ID of the node to issue a certificate for |
| `role` | string | No | Role to assign. Default: `provider` |

```json
{
  "ptnID": "ptn-abc123",
  "nodeID": "node-def456",
  "role": "provider"
}
```

### Response

```json
{
  "certData": "cert-signed-data...",
  "nodeID": "node-def456",
  "role": "provider"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/ptn/issue-cert \
  -H "Content-Type: application/json" \
  -d '{"ptnID": "ptn-abc123", "nodeID": "node-def456", "role": "provider"}'
```

---

## Join with Certificate

```
POST /v1/app/ptn/join-with-cert
```

Join a PTN using a signed membership certificate.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `certData` | string | Yes | Signed certificate data received from a PTN admin |

```json
{
  "certData": "cert-signed-data..."
}
```

### Response

```json
{
  "ptnID": "ptn-abc123",
  "name": "Acme Corp",
  "role": "provider",
  "status": "active"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/ptn/join-with-cert \
  -H "Content-Type: application/json" \
  -d '{"certData": "cert-signed-data..."}'
```

---

## Leave PTN

```
POST /v1/app/ptn/leave
```

Leave a PTN. This revokes the node's membership and removes the local certificate.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `ptnID` | string | Yes | ID of the PTN to leave |

```json
{
  "ptnID": "ptn-abc123"
}
```

### Response

```json
{
  "status": "left",
  "ptnID": "ptn-abc123"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/ptn/leave \
  -H "Content-Type: application/json" \
  -d '{"ptnID": "ptn-abc123"}'
```

---

## Promote to Admin

```
POST /v1/app/ptn/promote-admin
```

Promote a member node to admin role within a PTN.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `ptnID` | string | Yes | ID of the PTN |
| `nodeID` | string | Yes | ID of the node to promote |

```json
{
  "ptnID": "ptn-abc123",
  "nodeID": "node-def456"
}
```

### Response

```json
{
  "nodeID": "node-def456",
  "role": "admin"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/ptn/promote-admin \
  -H "Content-Type: application/json" \
  -d '{"ptnID": "ptn-abc123", "nodeID": "node-def456"}'
```

---

## Import CA Key

```
POST /v1/app/ptn/import-ca-key
```

Import a CA signing key for a PTN. This is used to transfer CA authority between nodes or restore from backup.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `ptnID` | string | Yes | ID of the PTN |
| `caKeyHex` | string | Yes | Hex-encoded CA private key |

```json
{
  "ptnID": "ptn-abc123",
  "caKeyHex": "a1b2c3d4e5f6..."
}
```

### Response

```json
{
  "status": "imported",
  "ptnID": "ptn-abc123"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/ptn/import-ca-key \
  -H "Content-Type: application/json" \
  -d '{"ptnID": "ptn-abc123", "caKeyHex": "a1b2c3d4e5f6..."}'
```

---

## Recover PTN

```
POST /v1/app/ptn/recover
```

Recover a PTN membership that has become disconnected or corrupted.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `ptnID` | string | Yes | ID of the PTN to recover |

```json
{
  "ptnID": "ptn-abc123"
}
```

### Response

```json
{
  "status": "recovered",
  "ptnID": "ptn-abc123"
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/ptn/recover \
  -H "Content-Type: application/json" \
  -d '{"ptnID": "ptn-abc123"}'
```

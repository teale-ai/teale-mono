# teale ptn

Manage Private TealeNet (PTN) memberships.

## Synopsis

```
teale ptn <subcommand> [options]
```

## Description

A Private TealeNet (PTN) is a closed network of trusted nodes that share inference capacity. PTN membership is controlled by CA-signed certificates issued by admins.

## Subcommands

### teale ptn list

List all PTN memberships for this node.

```
teale ptn list [--json]
```

| Option | Type | Description |
|---|---|---|
| `--json` | flag | Output machine-readable JSON |

```bash
teale ptn list
```

---

### teale ptn create

Create a new PTN. This node becomes the initial admin and certificate authority.

```
teale ptn create <name>
```

| Argument | Type | Description |
|---|---|---|
| `<name>` | string | Display name for the PTN (required) |

```bash
teale ptn create "Acme Corp"
```

---

### teale ptn invite

Generate a one-time invite code for a PTN.

```
teale ptn invite <ptnID>
```

| Argument | Type | Description |
|---|---|---|
| `<ptnID>` | string | ID of the PTN (required) |

```bash
teale ptn invite ptn-abc123
```

---

### teale ptn issue-cert

Issue a signed membership certificate to a node.

```
teale ptn issue-cert <ptnID> <nodeID> [--role <role>]
```

| Argument/Option | Type | Default | Description |
|---|---|---|---|
| `<ptnID>` | string | | ID of the PTN (required) |
| `<nodeID>` | string | | ID of the node to certify (required) |
| `--role` | string | provider | Role to assign (`provider` or `admin`) |

```bash
teale ptn issue-cert ptn-abc123 node-def456
teale ptn issue-cert ptn-abc123 node-def456 --role admin
```

---

### teale ptn join

Join a PTN using a signed certificate.

```
teale ptn join <certData>
```

| Argument | Type | Description |
|---|---|---|
| `<certData>` | string | Signed certificate data (required) |

```bash
teale ptn join "cert-signed-data..."
```

---

### teale ptn leave

Leave a PTN and revoke local membership.

```
teale ptn leave <ptnID>
```

| Argument | Type | Description |
|---|---|---|
| `<ptnID>` | string | ID of the PTN to leave (required) |

```bash
teale ptn leave ptn-abc123
```

---

### teale ptn promote-admin

Promote a member to admin role within a PTN.

```
teale ptn promote-admin <ptnID> <nodeID>
```

| Argument | Type | Description |
|---|---|---|
| `<ptnID>` | string | ID of the PTN (required) |
| `<nodeID>` | string | ID of the node to promote (required) |

```bash
teale ptn promote-admin ptn-abc123 node-def456
```

---

### teale ptn import-ca-key

Import a CA signing key for a PTN. Used to transfer CA authority or restore from backup.

```
teale ptn import-ca-key <ptnID> <caKeyHex>
```

| Argument | Type | Description |
|---|---|---|
| `<ptnID>` | string | ID of the PTN (required) |
| `<caKeyHex>` | string | Hex-encoded CA private key (required) |

```bash
teale ptn import-ca-key ptn-abc123 a1b2c3d4e5f6...
```

---

### teale ptn recover

Recover a PTN membership that has become disconnected or corrupted.

```
teale ptn recover <ptnID>
```

| Argument | Type | Description |
|---|---|---|
| `<ptnID>` | string | ID of the PTN to recover (required) |

```bash
teale ptn recover ptn-abc123
```

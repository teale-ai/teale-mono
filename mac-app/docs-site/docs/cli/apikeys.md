# teale apikeys

Manage API keys for node authentication.

## Synopsis

```
teale apikeys <subcommand> [options]
```

## Description

API keys are used for authentication when `allow_network_access` is enabled. Use these commands to generate, list, and revoke keys.

## Subcommands

### teale apikeys list

List all API keys.

```
teale apikeys list [--json]
```

| Option | Type | Description |
|---|---|---|
| `--json` | flag | Output machine-readable JSON |

```bash
teale apikeys list
```

```
ID                                    NAME          PREFIX        CREATED
550e8400-e29b-41d4-a716-446655440000  Development   sk-...abc1    2026-04-10
```

---

### teale apikeys generate

Generate a new API key. The full key is displayed once -- store it securely.

```
teale apikeys generate <name>
```

| Argument | Type | Description |
|---|---|---|
| `<name>` | string | Display name for the key (required) |

```bash
teale apikeys generate "CI Pipeline"
```

```
Key generated successfully.
Name: CI Pipeline
Key:  sk-teale-abc123def456ghi789...

Store this key securely -- it will not be shown again.
```

---

### teale apikeys revoke

Revoke an API key. The key stops working immediately.

```
teale apikeys revoke <id>
```

| Argument | Type | Description |
|---|---|---|
| `<id>` | string | UUID of the key to revoke (required) |

```bash
teale apikeys revoke 550e8400-e29b-41d4-a716-446655440000
```

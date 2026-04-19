# teale agent

Manage agent profile and conversations.

## Synopsis

```
teale agent <subcommand> [options]
```

## Subcommands

### teale agent profile

Show this node's agent profile.

```
teale agent profile [--json]
```

| Option | Type | Description |
|---|---|---|
| `--json` | flag | Output machine-readable JSON |

```bash
teale agent profile
```

---

### teale agent directory

List agents discoverable on the network.

```
teale agent directory [--json]
```

| Option | Type | Description |
|---|---|---|
| `--json` | flag | Output machine-readable JSON |

```bash
teale agent directory
```

---

### teale agent conversations

List agent-to-agent conversations this node has participated in.

```
teale agent conversations [--json]
```

| Option | Type | Description |
|---|---|---|
| `--json` | flag | Output machine-readable JSON |

```bash
teale agent conversations
```

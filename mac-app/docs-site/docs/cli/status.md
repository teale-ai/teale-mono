# teale status

Show the current status of the running Teale node.

## Synopsis

```
teale status [options]
```

## Description

Displays a summary of the node's current state, including the loaded model, hardware, connected peers, and wallet balance.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `--port` | integer | 11435 | HTTP port of the Teale node |
| `--api-key` | string | | API key for authentication |
| `--json` | flag | | Output machine-readable JSON |

## Examples

### Show status

```bash
teale status
```

### JSON output for scripting

```bash
teale status --json
```

### Connect to a node on a custom port

```bash
teale status --port 9000
```

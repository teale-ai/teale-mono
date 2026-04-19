# teale peers

List connected peers.

## Synopsis

```
teale peers [options]
```

## Description

Shows all peers currently connected to this node, including their hardware, loaded model, and connection type (LAN or WAN).

## Options

| Option | Type | Description |
|---|---|---|
| `--wan` | flag | Show only WAN peers |
| `--cluster` | flag | Show only LAN cluster peers |
| `--json` | flag | Output machine-readable JSON |

## Examples

### List all peers

```bash
teale peers
```

```
PEER             TYPE  MODEL              CHIP         MEMORY  LATENCY
Office iMac      lan   llama-3.1-8b-q4    Apple M4     64 GB   2 ms
Home Mac Mini    wan   qwen3-4b-q4        Apple M2     16 GB   45 ms
```

### LAN peers only

```bash
teale peers --cluster
```

### WAN peers only

```bash
teale peers --wan
```

### JSON output for scripting

```bash
teale peers --json
```

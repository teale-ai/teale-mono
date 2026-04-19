# teale serve

Start a headless Teale daemon with no GUI.

## Synopsis

```
teale serve [options]
```

## Description

Starts the Teale node as a headless daemon, suitable for servers, VMs, or background operation. The node runs without any graphical interface and is controlled entirely via the HTTP API or CLI commands.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `--port` | integer | 11435 | HTTP server port |
| `--model` | string | auto | Model to auto-load on startup |
| `--cluster` | flag | | Enable LAN cluster discovery |
| `--wan` | flag | | Enable WAN peer-to-peer networking |

## Examples

### Start headless daemon

```bash
teale serve
```

### Start with LAN clustering and WAN enabled

```bash
teale serve --cluster --wan
```

### Start with a specific model on a custom port

```bash
teale serve --port 9000 --model llama-3.1-8b-q4
```

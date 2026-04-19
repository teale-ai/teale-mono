# teale up

Start the Teale node and join the inference network.

## Synopsis

```
teale up [options]
```

## Description

Starts the Teale node, loads a model, and begins accepting inference requests from local clients and network peers. This is the primary way to start Teale with the full GUI experience (menu bar app on macOS).

If no model is specified, Teale automatically selects the best model for your hardware.

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `--port` | integer | 11435 | HTTP server port |
| `--model` | string | auto | Override the auto-selected model |
| `--maximize-earnings` | flag | | Enable keep-awake, auto-manage models, and allocate more storage |
| `--setup` | flag | | Re-run the first-time setup wizard |

## Examples

### Start with defaults

```bash
teale up
```

### Start on a custom port

```bash
teale up --port 8080
```

### Start with a specific model

```bash
teale up --model llama-3.1-8b-q4
```

### Start in maximize-earnings mode

```bash
teale up --maximize-earnings
```

### Re-run initial setup

```bash
teale up --setup
```

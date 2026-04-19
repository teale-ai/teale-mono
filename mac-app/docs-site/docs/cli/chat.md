# teale chat

Send a chat message to the running node.

## Synopsis

```
teale chat <prompt> [options]
```

## Description

Sends a single chat message to the node and prints the response. The response is streamed to stdout as it is generated.

## Arguments

| Argument | Required | Description |
|---|---|---|
| `<prompt>` | Yes | The message to send |

## Options

| Option | Type | Default | Description |
|---|---|---|---|
| `--port` | integer | 11435 | HTTP port of the Teale node |
| `--api-key` | string | | API key for authentication |
| `--model` | string | current | Model to use for this request |

## Examples

### Send a simple message

```bash
teale chat "What is the capital of France?"
```

### Use a specific model

```bash
teale chat "Explain quantum computing" --model qwen3-4b-q4
```

### Connect to a node on a custom port with an API key

```bash
teale chat "Hello" --port 9000 --api-key sk-teale-abc123
```

# CLI Reference

The Teale CLI provides full control over your Teale node from the command line. Every feature available in the GUI app has a corresponding CLI command.

## Installation

### Homebrew

```bash
brew install teale
```

### Direct Download

Download the latest binary from the [releases page](https://github.com/teale-ai/teale/releases) and add it to your `PATH`.

## How It Works

All CLI commands communicate with a running Teale node via its local HTTP API (default `http://localhost:11435`). The CLI is a thin client -- the node process does the actual work.

To start a node, use `teale up` or `teale serve`. All other commands require a running node.

## Global Options

These options are available on most commands:

| Option | Type | Default | Description |
|---|---|---|---|
| `--port` | integer | 11435 | HTTP port of the Teale node |
| `--api-key` | string | | API key for authentication (required when `allow_network_access` is enabled) |
| `--json` | flag | | Output machine-readable JSON instead of human-friendly text |

## Commands

| Command | Description |
|---|---|
| `teale up` | Start the node and join the inference network |
| `teale down` | Stop the running node |
| `teale serve` | Start a headless daemon (no GUI) |
| `teale status` | Show node status |
| `teale chat` | Send a chat message |
| `teale login` | Sign in via phone OTP |
| `teale models` | Manage models (list, load, download, unload) |
| `teale config` | Read or write settings |
| `teale ptn` | Manage Private TealeNet memberships |
| `teale wallet` | Manage wallet and credits |
| `teale peers` | List connected peers |
| `teale agent` | Agent profile and conversations |
| `teale apikeys` | Manage API keys |

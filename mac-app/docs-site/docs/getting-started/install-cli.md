# Install the CLI

Install the Teale command-line interface on macOS or Linux. The CLI has full feature parity with the GUI app --- 13 commands and 30+ subcommands covering inference, networking, wallet, and configuration.

---

## Install

### macOS or Linux (Homebrew)

```bash
brew install teale
```

### Binary download

Download the latest binary from [GitHub Releases](https://github.com/teale-ai/teale/releases). Binaries are available for:

- macOS (Apple Silicon)
- macOS (Intel)
- Linux (x86_64)
- Linux (aarch64)

After downloading:

```bash
chmod +x teale
sudo mv teale /usr/local/bin/
```

## Verify

Check that Teale is installed and running:

```bash
teale status
```

You should see output showing the node status, loaded model, and network connectivity.

## Quick reference

```bash
teale up                    # Start the inference server
teale down                  # Stop the server
teale status                # Show node status and loaded model
teale chat "Hello!"         # Send a one-shot message
teale models list           # List available models
teale models pull <name>    # Download a specific model
teale wallet balance        # Check your USDC balance
teale config show           # Show current configuration
```

Run `teale --help` for the full command list, or `teale <command> --help` for details on any command.

## Configuration

Teale stores its configuration and models in `~/.teale/` on Linux and `~/Library/Application Support/Teale/` on macOS. You can override the data directory with:

```bash
export TEALE_HOME=/path/to/data
```

## Uninstall

```bash
brew uninstall teale
```

Or remove the binary manually:

```bash
sudo rm /usr/local/bin/teale
rm -rf ~/.teale  # Linux
rm -rf ~/Library/Application\ Support/Teale  # macOS
```

---

## Next steps

- [Quickstart: Chat](quickstart-chat.md) --- chat with a model from your terminal
- [Quickstart: API](quickstart-api.md) --- use the OpenAI-compatible local API
- [Quickstart: Earn](quickstart-earn.md) --- contribute compute and earn USDC

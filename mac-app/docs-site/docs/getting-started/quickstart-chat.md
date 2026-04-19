# Quickstart: Chat

Start chatting with a local AI model in under a minute. No accounts, no API keys, no cloud.

---

## Using the desktop app

1. **Install Teale.** Download from [teale.com/download](https://teale.com/download) or run `brew install --cask teale`. See [Install on Mac](install-mac.md) for details.

2. **Click the Teale icon in your menu bar.** It appears near the clock after launching the app.

3. **Wait for the model to download.** Teale automatically selects and downloads a model based on your available RAM. For a Mac with 16 GB, this is typically Llama 3.1 8B (4-bit quantized, about 4.5 GB). You only download once.

4. **Type a message and start chatting.** Inference runs entirely on your Mac. Nothing is sent to the cloud.

## Using the CLI

Start the inference server and send a message:

```bash
teale up
teale chat "What is the meaning of life?"
```

For an interactive conversation:

```bash
teale chat
```

This opens a REPL where you can type messages back and forth. Press `Ctrl+C` to exit.

### Switch models

List available models and pull a different one:

```bash
teale models list
teale models pull qwen-2.5-7b-instruct-4bit
teale chat --model qwen-2.5-7b-instruct-4bit "Explain quantum computing"
```

## What happens under the hood

When you send a message, Teale:

1. Loads the model into your Mac's unified memory (first message may take a few seconds).
2. Runs inference on Apple Silicon using Metal acceleration.
3. Streams tokens back as they are generated.

All processing stays on your machine. No data leaves your device unless you explicitly connect to the Teale network.

---

## Next steps

- [Quickstart: API](quickstart-api.md) --- integrate Teale into your applications
- [Quickstart: Earn](quickstart-earn.md) --- share your compute and earn USDC
- [Install the CLI](install-cli.md) --- full CLI reference and configuration

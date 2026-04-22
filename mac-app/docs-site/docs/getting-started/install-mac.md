# Install on Mac

Install the Teale desktop app on macOS. Includes the menu bar app, built-in chat, and the full CLI.

---

## Requirements

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1, M2, M3, M4, or later)
- **8 GB RAM** minimum (16 GB+ recommended for larger models)

## Install

### Option A: Download the DMG

1. Grab the latest **Teale.dmg** from the [GitHub releases page](https://github.com/teale-ai/teale-mono/releases/latest).
2. Open the DMG and drag Teale to your Applications folder.
3. Launch Teale from Applications. The app is notarized by Apple, so Gatekeeper opens it without warnings.

### Option B: One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/teale-ai/teale-mono/main/mac-app/scripts/install.sh | sh
```

Downloads the latest release, installs to `/Applications/Teale.app`, and launches it.

## First launch

When you launch Teale for the first time:

1. **Menu bar icon appears.** Teale runs as a MenuBarExtra --- look for the Teale icon in your menu bar, near the clock.
2. **Click the icon** to open the Teale popover.
3. **A model downloads automatically.** Teale selects a model based on your available RAM:

    | RAM | Default model |
    |-----|---------------|
    | 8 GB | Llama 3.1 8B (4-bit, ~4.5 GB) |
    | 16 GB | Llama 3.1 8B (4-bit) |
    | 32 GB+ | Llama 3.1 70B (4-bit, ~36 GB) |

4. **Start chatting.** Once the model finishes downloading, you can type a message and get a response immediately.

The CLI is bundled with the desktop app. After installing, you can also use Teale from your terminal:

```bash
teale status
```

## Updating

Teale checks for updates automatically. When one is available, click **Update** in Settings → About, or re-run the one-line install.

## Uninstall

Drag Teale from Applications to the Trash. To also remove downloaded models and configuration:

```bash
rm -rf ~/Library/Application\ Support/Teale
```

---

## Next steps

- [Quickstart: Chat](quickstart-chat.md) --- start a conversation in under a minute
- [Quickstart: API](quickstart-api.md) --- use the OpenAI-compatible API
- [Quickstart: Earn](quickstart-earn.md) --- share compute and earn USDC

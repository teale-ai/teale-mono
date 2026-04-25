# Install on Mac

Install the released Teale macOS app and start local or network inference from the desktop UI.

---

## Requirements

- **macOS 14+** (Sonoma or later)
- **Apple Silicon** (M1, M2, M3, M4, or later)
- **8 GB RAM** minimum
- **16 GB+ RAM** recommended if you plan to keep larger models loaded

## Install

1. Download the latest macOS build from the [GitHub releases page](https://github.com/teale-ai/teale-mono/releases/latest).
2. Open `Teale.dmg` or `Teale.zip`.
3. Move `Teale.app` into `/Applications`.
4. Launch `Teale.app`.

## macOS security prompt

The current mac release is Developer ID signed but not notarized.

If macOS blocks the first launch:

1. Right-click `Teale.app` and choose **Open**.
2. Or go to **System Settings > Privacy & Security > Open Anyway**.

## First launch

1. Open the **Supply** tab.
2. Use the recommended action or pick a model from the catalog.
3. Wait for the transfer to finish and for the model to load.
4. Open **teale** to start chatting locally or select a live Teale Network model.
5. Open the settings gear in the top right to choose language and display units.

## Local API

The mac app exposes the released local API at:

```text
http://127.0.0.1:11435/v1
```

See [Quickstart: API](quickstart-api.md) and [API Reference](../api/index.md).

## Uninstall

Move `Teale.app` to the Trash. To also remove local app data and downloaded models:

```bash
rm -rf ~/Library/Application\ Support/Teale
```

---

## Next steps

- [Quickstart: Chat](quickstart-chat.md)
- [Quickstart: API](quickstart-api.md)
- [Quickstart: Earn](quickstart-earn.md)
- [App overview](../guides/app-overview.md)

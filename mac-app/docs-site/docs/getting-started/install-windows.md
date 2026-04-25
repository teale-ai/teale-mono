# Install on Windows

Install the released Teale Windows app and use the same core flow as macOS: load a local model, chat locally, use live Teale Network models, and manage your device wallet from the desktop app.

---

## Requirements

- **Windows 10 or Windows 11** on x64 hardware
- Enough local RAM or VRAM for the model you plan to load
- Internet access if you want Teale Network demand, sign-in, or wallet sync

## Install

1. Download the latest `Teale.exe` from the [GitHub releases page](https://github.com/teale-ai/teale-mono/releases/latest).
2. Run the installer.
3. Launch Teale from the Start menu or desktop shortcut.

## First launch

1. Open the **Supply** tab.
2. Use the recommended action or choose a model from the catalog.
3. Watch transfer progress until the model is loaded.
4. Open **teale** to chat locally or switch to a live Teale Network model.
5. Open the settings gear in the top right to choose language and display units.

## Local endpoints

The Windows release exposes two local surfaces:

- Companion control API: `http://127.0.0.1:11437/v1/app`
- Local model API: shown in the **Demand** tab and returned by `GET /v1/app`

In most Windows installs the local model base URL is:

```text
http://127.0.0.1:11436/v1
```

See [Quickstart: API](quickstart-api.md) and [API Reference](../api/index.md).

## Next steps

- [Quickstart: Chat](quickstart-chat.md)
- [Quickstart: API](quickstart-api.md)
- [Quickstart: Earn](quickstart-earn.md)
- [App overview](../guides/app-overview.md)

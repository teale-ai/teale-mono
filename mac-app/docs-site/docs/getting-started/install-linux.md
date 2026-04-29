# Install on Linux

Install the released Teale Linux desktop bundle and use the same shared desktop companion UI as Windows.

---

## Requirements

- **Linux x86_64**
- A graphical desktop session
- A systemd user session for the background `teale-node` service
- WebKitGTK runtime libraries

On Ubuntu or Debian, install the desktop runtime first:

```bash
sudo apt-get update
sudo apt-get install -y libgtk-3-0 libwebkit2gtk-4.1-0 libsoup-3.0-0 libvulkan1 xdg-utils desktop-file-utils
```

## Install

1. Download `Teale-linux-x86_64.tar.gz` from the [GitHub releases page](https://github.com/teale-ai/teale-mono/releases/latest).
2. Extract it.
3. Run:

```bash
cd Teale-linux-x86_64
./install.sh
```

The installer copies the desktop bundle into your user profile, registers the `teale://` callback handler, installs a `teale-node` user service, and opens the Teale window.

## First launch

1. Open **Supply**.
2. Use the recommended action or pick a model from the catalog.
3. Wait for the transfer to finish and for the model to load.
4. Open **teale** to start chatting locally or switch to a live Teale Network model.
5. Open the settings gear in the top right to choose language and display units.

## Local endpoints

The Linux desktop bundle exposes the same companion surfaces as Windows:

- Companion control API: `http://127.0.0.1:11437/v1/app`
- Local model API: shown in the **Demand** tab and returned by `GET /v1/app`

In most Linux installs the local model base URL is:

```text
http://127.0.0.1:11436/v1
```

## Uninstall

Run:

```bash
~/.local/share/teale/uninstall.sh
```

This removes the user-level Teale install, service, config, and local state.

## Next steps

- [Quickstart: Chat](quickstart-chat.md)
- [Quickstart: API](quickstart-api.md)
- [Quickstart: Earn](quickstart-earn.md)
- [App overview](../guides/app-overview.md)

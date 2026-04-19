# Headless Server Mode

Run Teale as a persistent background service on always-on hardware --- Mac Mini, Mac Studio, or Linux servers. No GUI required.

---

## Prerequisites

- Teale CLI installed ([Install the CLI](../getting-started/install-cli.md))
- A machine that stays powered on

## Quick start

```bash
teale serve --port 11435 --model qwen3-8b-4bit --cluster --wan
```

This starts Teale in headless mode with:

- HTTP API on port 11435
- The specified model loaded and ready
- LAN cluster discovery enabled
- WAN networking enabled

## Command flags

| Flag         | Description                                    | Default  |
|--------------|------------------------------------------------|----------|
| `--port`     | HTTP API port                                  | `11435`  |
| `--model`    | Model to load on startup                       | none     |
| `--cluster`  | Enable LAN cluster discovery                    | off      |
| `--wan`      | Enable WAN networking                           | off      |

## Enable remote access

By default, Teale binds to `127.0.0.1`. To accept connections from other machines:

```bash
teale config set allow_network_access true
```

Then generate an API key for remote clients:

```bash
teale apikeys generate "remote-access"
```

Remote clients must include this key in the `Authorization: Bearer <key>` header. See [API Key Management](api-keys.md).

## Auto-start with launchd (macOS)

Create a launchd plist to start Teale automatically on boot.

1. Create the plist file at `~/Library/LaunchAgents/com.teale.serve.plist`:

    ```xml
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.teale.serve</string>
        <key>ProgramArguments</key>
        <array>
            <string>/usr/local/bin/teale</string>
            <string>serve</string>
            <string>--port</string>
            <string>11435</string>
            <string>--model</string>
            <string>qwen3-8b-4bit</string>
            <string>--cluster</string>
            <string>--wan</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>/tmp/teale-serve.log</string>
        <key>StandardErrorPath</key>
        <string>/tmp/teale-serve.err</string>
    </dict>
    </plist>
    ```

2. Load the service:

    ```bash
    launchctl load ~/Library/LaunchAgents/com.teale.serve.plist
    ```

3. Verify it is running:

    ```bash
    launchctl list | grep teale
    teale status
    ```

To stop and unload:

```bash
launchctl unload ~/Library/LaunchAgents/com.teale.serve.plist
```

## Auto-start with systemd (Linux)

Create a systemd unit file at `/etc/systemd/system/teale.service`:

```ini
[Unit]
Description=Teale Inference Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/teale serve --port 11435 --model qwen3-8b-4bit --cluster --wan
Restart=always
RestartSec=5
User=teale

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl enable teale
sudo systemctl start teale
```

Check status:

```bash
sudo systemctl status teale
```

## Docker

Run Teale as a Docker container:

```bash
docker run -p 11435:11435 teale/node --model Qwen3-8B-GGUF
```

For persistent model storage, mount a volume:

```bash
docker run -p 11435:11435 -v teale-models:/data/models teale/node --model Qwen3-8B-GGUF
```

## Monitoring

Check node status programmatically:

```bash
teale status --json
```

This outputs JSON suitable for monitoring dashboards, health checks, and alerting systems. It includes model state, active connections, request counts, and resource usage.

---

## Next steps

- [API Key Management](api-keys.md) --- secure remote access
- [Earn Credits](earn-credits.md) --- earn from your always-on server
- [WAN Networking](wan-networking.md) --- connect to the public network
- [LAN Cluster Setup](lan-cluster.md) --- join other nodes on the local network

# Connect iPhone to Mac

Use the TealeCompanion app on your iPhone to chat with models running on your Mac. Inference stays on your local network --- nothing leaves your devices.

---

## Prerequisites

- Mac with Teale running and cluster enabled
- iPhone or iPad running iOS 17 or later
- Both devices on the same Wi-Fi network

## Step 1: Enable clustering on your Mac

If clustering is not already enabled:

```bash
teale config set cluster_enabled true
```

Or in the desktop app: Settings > Cluster > Enable.

Verify your Mac is advertising to the local network:

```bash
teale status
```

You should see `cluster: enabled` and `bonjour: advertising` in the output.

## Step 2: Install TealeCompanion

Download TealeCompanion from the App Store on your iPhone or iPad.

## Step 3: Open TealeCompanion

Launch the app. TealeCompanion automatically discovers Macs running Teale on your local network via Bonjour. Your Mac should appear in the device list within a few seconds.

If your Mac does not appear:

1. Confirm both devices are on the same Wi-Fi network (same subnet).
2. Check that your router does not block mDNS traffic between devices.
3. Restart Teale on your Mac: `teale down && teale up`.

## Step 4: Start chatting

Tap your Mac in the device list to connect. Select a model and start a conversation. All inference runs on your Mac --- the iPhone sends prompts over the local network and streams responses back.

## Dual mode (iPad with M-series)

iPads with M-series chips can also run small models on-device using MLX. TealeCompanion detects compatible hardware and offers the option to run inference locally on the iPad as a fallback when no Mac is available.

To enable on-device inference, go to TealeCompanion Settings > On-Device Inference > Enable.

## Optional: Cluster passcode

If you have set a cluster passcode on your Mac, TealeCompanion will prompt for it on first connection:

```bash
# On your Mac
teale config set cluster_passcode "my-secret"
```

Enter the same passcode in TealeCompanion when prompted. All peers in the cluster must use the same passcode.

---

## Next steps

- [LAN Cluster Setup](lan-cluster.md) --- connect multiple Macs on the same network
- [How Teale Works](../concepts/how-teale-works.md) --- understand the architecture
- [Manage Models](manage-models.md) --- choose which models are available

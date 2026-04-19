# Earn Credits

Share your Mac's idle compute with the Teale network and earn USDC for every inference request you serve.

---

## Prerequisites

- Mac with Apple Silicon (M1 or later)
- Teale installed ([Install on Mac](../getting-started/install-mac.md) or [Install the CLI](../getting-started/install-cli.md))
- AC power recommended

## Quick start

```bash
teale up --maximize-earnings
```

This single command starts Teale in full earning mode. It handles model selection, networking, and power management automatically.

## What `--maximize-earnings` does

When you pass `--maximize-earnings`, Teale makes several optimizations:

1. **Keeps the system awake.** Prevents sleep so your node stays available to the network around the clock.
2. **Auto-manages models.** Downloads and loads the largest model that fits in your available RAM (reserving 4 GB for macOS). If network demand shifts, Teale may swap models automatically.
3. **Increases storage allocation.** Raises the default model storage limit so Teale can cache multiple models for fast switching.
4. **Enables WAN networking.** Connects to the Teale relay so requests can reach you from the public network, not just your LAN.

### Model selection by RAM

Teale picks the largest quantized model that fits in your available memory (total RAM minus 4 GB for the OS):

| Mac RAM | Usable for inference | Typical model       |
|---------|---------------------|---------------------|
| 16 GB   | ~12 GB              | 8B (4-bit)          |
| 32 GB   | ~28 GB              | 32B (4-bit)         |
| 64 GB   | ~60 GB              | 70B (4-bit)         |
| 128 GB  | ~124 GB             | 70B (8-bit) or 405B (4-bit) |

Larger models are in higher demand and earn more per token.

## Monitor your earnings

Check your balance at any time:

```bash
teale wallet balance
```

View recent transactions:

```bash
teale wallet transactions --limit 10
```

Check node status (loaded model, active connections, requests served):

```bash
teale status
```

## Optimization tips

1. **Plug into AC power.** Teale throttles inference on battery to preserve battery health. AC power unlocks full throughput.
2. **Use ethernet.** Wired connections reduce latency and improve reliability, which means your node wins more routing decisions.
3. **Schedule overnight contribution.** If you prefer not to share compute during the day, configure a contribution schedule:

    ```bash
    teale config set schedule.earn "22:00-08:00"
    ```

    Or in the desktop app: Settings > Contribution Schedule.

4. **Keep Teale updated.** Newer versions include performance improvements and support for newer models.
5. **More RAM = more earnings.** Larger models serve more use cases and command higher prices.

## How pricing works

Providers earn **95%** of the inference cost. The remaining 5% is a network fee that funds relay infrastructure and protocol development.

The cost of a request is calculated as:

```
cost = (tokens / 1000) * (params * 0.1) * quantMultiplier / 10000
```

- **tokens** --- number of tokens generated
- **params** --- model parameter count in billions (e.g. 8 for an 8B model)
- **quantMultiplier** --- adjusts for quantization level (higher precision = higher cost)

### Electricity cost floor

Teale ensures you never lose money by enforcing an electricity cost floor. If the market price for a request would be less than the electricity required to serve it, your node declines the request.

Configure your local electricity rate:

```bash
teale config set electricity_cost 0.12
```

The value is in USD per kWh. Teale uses this along with measured power draw to calculate your cost floor.

## Configure earning without `--maximize-earnings`

You can enable earning mode with finer control:

```bash
teale up
teale config set wan_enabled true
teale config set auto_manage_models true
teale config set max_storage_gb 50
```

This gives you the same behavior with explicit control over each setting.

---

## Next steps

- [Wallet and Payments](wallet-and-payments.md) --- manage your balance, view transactions, and send credits
- [Manage Models](manage-models.md) --- manually control which models are downloaded and loaded
- [Headless Server Mode](headless-server.md) --- run Teale on an always-on Mac Mini or server

# Quickstart: Earn

Share your idle compute with the Teale network and earn USDC. Your Mac runs inference for other users while you are away.

---

## How earnings work

When your Mac serves inference requests from the network, you earn USDC for each completion. Pricing is transparent:

- **Providers earn 95%** of the inference cost.
- **5% network fee** covers relay infrastructure and protocol development.

Pricing is market-driven and based on compute cost. You are paid in USDC --- no speculative tokens.

## Step by step

### 1. Install Teale

If you haven't already, install Teale on your Mac. See [Install on Mac](install-mac.md) or [Install the CLI](install-cli.md).

### 2. Enable earning mode

Via the CLI:

```bash
teale up --maximize-earnings
```

Or in the desktop app: open Settings and toggle **Contribute to network**.

This tells Teale to optimize for throughput and accept requests from the network.

### 3. Teale configures itself

When earning mode is active, Teale:

- Selects the best model for your hardware (maximizing tokens-per-second for your RAM and GPU).
- Connects to the Teale network and registers your node as a provider.
- Starts accepting inference requests from other users.

You do not need to choose a model or configure networking manually.

### 4. Check your earnings

```bash
teale wallet balance
```

This shows your current USDC balance, pending earnings, and payout history.

### 5. Withdraw

```bash
teale wallet withdraw --to <your-wallet-address>
```

Withdrawals are sent to any USDC-compatible wallet address (Ethereum, Base, Solana, etc.).

## Tips for maximizing earnings

- **Plug in to AC power.** Teale throttles inference on battery to preserve battery health.
- **Use ethernet.** Wired connections have lower latency and higher reliability, which means your node gets more requests.
- **Schedule overnight contribution.** If you don't want to share compute during the day, schedule earning mode for nights and weekends:

    ```bash
    teale config set schedule.earn "22:00-08:00"
    ```

- **More RAM = more earnings.** Larger models serve more use cases and earn more per token. A 32 GB Mac can run 70B-class models that are in higher demand.
- **Keep Teale updated.** Newer versions include performance improvements and support for newer models.

## Monitoring

Check your node's status and earnings at any time:

```bash
teale status              # Node status, model, connections
teale wallet balance      # Current balance and history
teale wallet history      # Detailed transaction log
```

---

## Next steps

- [Quickstart: Chat](quickstart-chat.md) --- use Teale for your own conversations
- [Quickstart: API](quickstart-api.md) --- build applications on the local API

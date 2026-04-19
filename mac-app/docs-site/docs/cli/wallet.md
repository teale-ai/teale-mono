# teale wallet

Manage wallet and credits.

## Synopsis

```
teale wallet <subcommand> [options]
```

## Subcommands

### teale wallet balance

Show the current wallet balance and summary statistics.

```
teale wallet balance [--json]
```

| Option | Type | Description |
|---|---|---|
| `--json` | flag | Output machine-readable JSON |

```bash
teale wallet balance
```

```
Balance:      5.432 credits
Total earned: 12.100 credits
Total spent:  6.668 credits
Transactions: 247
```

---

### teale wallet transactions

List recent transactions.

```
teale wallet transactions [--limit <int>] [--json]
```

| Option | Type | Default | Description |
|---|---|---|---|
| `--limit` | integer | 20 | Maximum number of transactions to show |
| `--json` | flag | | Output machine-readable JSON |

```bash
teale wallet transactions
teale wallet transactions --limit 50
teale wallet transactions --json
```

---

### teale wallet send

Send credits to a peer.

```
teale wallet send <amount> <peerID> [--memo <text>]
```

| Argument/Option | Type | Description |
|---|---|---|
| `<amount>` | number | Amount of credits to send (required) |
| `<peerID>` | string | ID of the recipient peer (required) |
| `--memo` | string | Optional memo for the transaction |

```bash
teale wallet send 0.5 node-def456
teale wallet send 1.0 node-def456 --memo "Thanks for the compute"
```

---

### teale wallet solana

Show Solana wallet bridge status, including on-chain address and balance.

```
teale wallet solana [--json]
```

| Option | Type | Description |
|---|---|---|
| `--json` | flag | Output machine-readable JSON |

```bash
teale wallet solana
```

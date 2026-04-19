# Wallet and Payments

Teale has a built-in wallet for earning, spending, and transferring USDC credits. All settlements happen on the Solana blockchain.

---

## Prerequisites

- Teale installed and running

## Check your balance

```bash
teale wallet balance
```

This shows your current USDC balance, pending earnings, and wallet address.

## Welcome bonus

On first use, Teale credits your wallet with **$0.01 USDC** --- enough to send a few hundred inference requests and try the network without any setup.

## View transactions

See your transaction history:

```bash
teale wallet transactions
```

Limit the number of results:

```bash
teale wallet transactions --limit 10
```

### Transaction types

| Type           | Description                                              |
|----------------|----------------------------------------------------------|
| `earned`       | Credits received for serving inference requests           |
| `spent`        | Credits paid to providers for requests you sent           |
| `bonus`        | Welcome bonus or promotional credits                      |
| `adjustment`   | Network corrections (e.g., failed delivery refunds)       |
| `transfer`     | Peer-to-peer credit transfers                             |
| `sdkEarning`   | Credits earned via TealeSDK-integrated third-party apps   |

## Send credits to a peer

Transfer credits directly to another Teale node:

```bash
teale wallet send 0.001 <peerID> --memo "thanks"
```

The `--memo` flag is optional and attaches a note to the transaction.

## Solana settlement

Teale settles credits on the Solana blockchain using USDC (SPL token). Check your on-chain status:

```bash
teale wallet solana
```

This shows your Solana wallet address, on-chain USDC balance, and recent settlement transactions.

### How settlement works

1. Credits accumulate in Teale's off-chain ledger as you earn and spend.
2. Periodically, Teale settles net balances on-chain in a single Solana transaction.
3. Settlement is automatic --- you do not need to trigger it manually.
4. On-chain settlement uses compressed transactions to minimize fees.

## Pricing reference

For providers, the cost of a request determines your earnings:

```
cost = (tokens / 1000) * (params * 0.1) * quantMultiplier / 10000
```

Providers receive 95% of this cost. See [Credit Economy](../concepts/credit-economy.md) for full pricing details.

---

## Next steps

- [Earn Credits](earn-credits.md) --- start earning by sharing compute
- [Credit Economy](../concepts/credit-economy.md) --- how pricing and settlement work
- [Solana Settlement](../concepts/solana-settlement.md) --- on-chain settlement details

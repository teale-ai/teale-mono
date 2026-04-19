# Solana Settlement

WalletKit bridges the local credit ledger to the Solana blockchain, enabling USDC deposits, withdrawals, and on-chain settlement.

## Overview

Teale's credit economy runs on a local ledger by default --- fast, free, and private. When users want to move real money in or out, WalletKit connects to Solana for USDC transfers. This hybrid approach keeps everyday inference transactions instant and feeless while providing a path to real-value settlement.

```
[Local Credit Ledger] <---> [WalletBridge] <---> [Solana RPC]
       (fast, free)            (bridge)         (on-chain USDC)
```

## Solana identity

### Key generation

WalletKit generates a Solana-compatible keypair using BIP39:

1. A 12 or 24-word mnemonic is generated from cryptographic randomness.
2. The mnemonic derives a seed using PBKDF2.
3. The seed derives an Ed25519 keypair (the same curve used for Teale node identity, but a separate keypair).
4. The public key is encoded as a Base58 Solana address.

The mnemonic and private key are stored in the system Keychain. Users can back up the mnemonic to recover their wallet on a new device.

### SolanaIdentity

The `SolanaIdentity` type manages:

- Keypair generation and secure storage
- Base58 address encoding and display
- Signing Solana transactions with the private key

## Deposits

The `DepositMonitor` watches for incoming USDC transfers to the user's Solana address:

1. It polls the Solana RPC endpoint for new token account transactions.
2. When a USDC transfer to the user's address is detected, it verifies the transaction signature.
3. The deposit amount is credited to the local ledger with the on-chain transaction signature stored for reference.

Users deposit by sending USDC to their Teale wallet's Solana address from any Solana wallet or exchange.

## Withdrawals

The `WithdrawalService` sends USDC from the Teale wallet to an external Solana address:

1. The user specifies the recipient address and amount.
2. WalletKit constructs a Solana SPL token transfer instruction.
3. The transaction is signed with the local private key.
4. The signed transaction is submitted to the Solana RPC endpoint.
5. On confirmation, the local ledger is debited and the transaction signature is recorded.

## On-chain transaction tracking

Every deposit and withdrawal records the Solana transaction signature in the local credit ledger (`txSignature` field on `USDCTransaction`). This provides:

- **Auditability:** Users can verify any deposit or withdrawal on a Solana block explorer.
- **Dispute resolution:** On-chain signatures are cryptographic proof of payment.
- **Reconciliation:** The local ledger can be reconciled against on-chain history at any time.

## WalletBridge

`WalletBridge` is the central coordinator that ties everything together:

| Component | Responsibility |
|-----------|---------------|
| `SolanaIdentity` | Keypair management and transaction signing |
| `SolanaRPCService` | HTTP calls to Solana RPC (getBalance, sendTransaction, etc.) |
| `DepositMonitor` | Watch for incoming USDC transfers |
| `WithdrawalService` | Send USDC to external addresses |

WalletBridge exposes a clean interface to the rest of the app. CreditKit calls WalletBridge when it needs to move funds on-chain; the rest of the time, the local ledger handles everything.

## Current state

Teale currently operates with a local credit ledger and optional on-chain settlement:

- **Local transactions** (earning from serving inference, spending on remote inference) are recorded in the local JSON ledger. They are instant and free.
- **On-chain settlement** is used when users want to deposit external USDC, withdraw earnings, or transfer credits to another wallet.
- **Future direction:** As the network grows, periodic batch settlement may replace per-transaction on-chain writes to reduce fees.

## USDC on Solana

Teale uses USDC (USD Coin) on Solana because:

- **Stable value.** USDC is pegged 1:1 to the US dollar. No price volatility.
- **Low fees.** Solana transaction fees are typically under $0.01.
- **Fast finality.** Solana confirms transactions in roughly 400 milliseconds.
- **Wide support.** USDC on Solana is supported by major exchanges and wallets.

## Related pages

- [Credit Economy](credit-economy.md) --- pricing, revenue split, and the local ledger
- [Security Model](security-model.md) --- key storage and cryptographic identity

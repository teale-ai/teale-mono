# Credit Economy

Teale uses USDC (a dollar-pegged stablecoin on Solana) for all payments between nodes. Pricing is transparent, formula-driven, and designed to ensure providers always cover their electricity costs.

## Pricing formula

The cost of an inference request is:

```
cost = (tokens / 1000) * modelComplexity * quantizationMultiplier / 10,000
```

The result is in USDC.

### Model complexity

Model complexity scales linearly with parameter count:

```
modelComplexity = parameterBillions * 0.1
```

| Model size | Complexity factor |
|-----------|-------------------|
| 1B | 0.1 |
| 8B | 0.8 |
| 32B | 3.2 |
| 70B | 7.0 |

### Quantization multiplier

Lower precision is cheaper because it uses less memory and compute:

| Quantization | Multiplier |
|-------------|------------|
| q4 (4-bit) | 1.0x |
| q8 (8-bit) | 1.5x |
| fp16 (16-bit) | 2.0x |

### Example

Generating 1,000 tokens on an 8B parameter model at q4 quantization:

```
cost = (1000 / 1000) * 0.8 * 1.0 / 10,000
     = 0.00008 USDC
     = $0.000080
```

## Revenue split

- **Provider earns 95%** of the inference cost.
- **5% network fee** funds relay infrastructure and development.

For the example above, the provider earns $0.000076 and the network fee is $0.000004.

## Electricity cost floor

Providers should never lose money on inference. The electricity floor ensures the effective price always covers the real cost of running the hardware:

```
electricityCost = (tokens / tokensPerSecond) * (watts / 3,600,000) * costPerKWh * 1.2
```

The `1.2` multiplier adds a 20% margin over raw electricity cost.

The effective price charged is:

```
effectivePrice = max(tokenPrice, electricityCost)
```

If the token-based price is below the electricity floor, the floor price is used instead.

## Worked example

**Scenario:** Running an 8B q4 model on an M4 Pro (38W inference power draw, 50 tokens/second, $0.12/kWh electricity rate). Generating 1,000 tokens.

**Token-based price:**

```
tokenPrice = (1000 / 1000) * 0.8 * 1.0 / 10,000
           = $0.000080
```

**Electricity floor:**

```
secondsOfCompute = 1000 / 50 = 20 seconds
kWhUsed          = (38 * 20) / 3,600,000 = 0.000211 kWh
rawCost          = 0.000211 * 0.12 = $0.0000253
electricityFloor = $0.0000253 * 1.2 = $0.0000304
```

**Effective price:** `max($0.000080, $0.0000304)` = **$0.000080**

In this case, the token-based price exceeds the electricity floor, so the standard price applies. On slower hardware or with expensive electricity, the floor would kick in.

**Provider earnings:** $0.000080 * 0.95 = **$0.000076**

## WWTN reverse auction

On the public network (WWTN --- Wider World Teale Network), pricing is market-driven via reverse auction:

1. The requestor posts a job with a maximum bid per 1,000 tokens.
2. Available providers automatically bid their floor price plus a margin (floor * 1.1, scaled by demand).
3. The lowest bid wins. Ties are broken by quality score (measured speed and reliability).
4. If no bid comes in under the maximum, the request is not fulfilled.

This creates a competitive market where providers are incentivized to run efficient hardware and keep electricity costs low.

## PTN fixed pricing

Private TealeNet members use fixed-rate pricing instead of auctions. The PTN administrator sets the rate, and all members pay the same price. This provides predictable costs and avoids the overhead of the auction mechanism. See [Private TealeNet](private-tealenet.md) for details.

## Wallet mechanics

- **Welcome bonus:** New users receive $0.01 USDC to start using the network immediately.
- **Minimum balance for remote inference:** $0.0001 USDC. Below this, only local inference is available.
- **Local inference is always free.** Running models on your own device costs nothing.
- **Credit ledger:** All transactions are stored locally in a JSON ledger with optional on-chain settlement via Solana. See [Solana Settlement](solana-settlement.md).

## Transaction types

| Type | Description |
|------|-------------|
| `earned` | Credits received for serving inference |
| `spent` | Credits paid for consuming remote inference |
| `bonus` | Welcome bonus or promotional credits |
| `adjustment` | Manual corrections |
| `transfer` | Peer-to-peer credit transfers |
| `sdkEarning` | Credits earned via TealeSDK contribution |

## Scheduling priority

The `RequestScheduler` uses Weighted Fair Queuing to allocate capacity:

- **PTN requests:** 70% weight
- **WWTN requests:** 30% weight
- **Zero idle waste:** If one queue is empty, the other gets 100% of capacity

This means PTN members always get reliable performance, while WWTN traffic fills any remaining capacity at market rates.

## Related pages

- [Solana Settlement](solana-settlement.md) --- on-chain USDC settlement
- [Private TealeNet](private-tealenet.md) --- fixed pricing and priority scheduling
- [Inference Providers](inference-providers.md) --- the CreditAwareProvider middleware

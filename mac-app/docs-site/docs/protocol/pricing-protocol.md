# Pricing Protocol

Token-based pricing with electricity floor, PTN fixed rates, and WWTN reverse auction.

## Overview

TealeNet uses a token-based pricing model where the cost of inference is determined by model complexity, quantization level, and a minimum electricity cost floor that ensures providers always cover their operating costs. Pricing differs between Private TealeNets (PTN) and the World Wide TealeNet (WWTN).

## Token-Based Pricing Formula

```
cost = (tokens / 1000) * complexity * quantizationMultiplier / 10,000
```

Where:
- `tokens` -- number of tokens generated
- `complexity` -- model parameter count in billions multiplied by 0.1 (e.g., 8B model = 0.8)
- `quantizationMultiplier` -- multiplier based on quantization level

### Complexity Factor

```
complexity = parameterCountB * 0.1
```

| Model Size | Complexity Factor |
|-----------|-------------------|
| 1B | 0.1 |
| 3B | 0.3 |
| 4B | 0.4 |
| 8B | 0.8 |
| 14B | 1.4 |
| 24B | 2.4 |
| 27B | 2.7 |
| 32B | 3.2 |
| 109B | 10.9 |

### Quantization Multiplier

| Quantization | Multiplier |
|-------------|------------|
| q4 | 1.0x |
| q8 | 1.5x |
| fp16 | 2.0x |

Higher-precision quantizations require more memory and compute, reflected in higher pricing.

## Electricity Floor

The electricity floor ensures providers never earn less than the cost of electricity plus a margin.

```
electricity_floor = (watts * seconds_of_compute / 3,600,000) * cost_per_kWh * margin
```

Where:
- `watts` -- device power draw during inference (from [HardwareCapability.estimatedInferenceWatts](node-capabilities.md))
- `seconds_of_compute` -- `tokenCount / tokensPerSecond`
- `cost_per_kWh` -- provider's local electricity rate (USD)
- `margin` -- markup multiplier (default **1.2**, i.e., 20% margin over raw electricity cost)

### Effective Cost

The actual charge is the **maximum** of the token-based price and the electricity floor:

```
effective_cost = max(token_price, electricity_floor)
```

This ensures that even for small models on power-hungry hardware, the provider covers their costs.

## Revenue Split

| Recipient | Share |
|-----------|-------|
| Provider | 95% |
| Network fee | 5% |

The provider earns 95% of the effective cost. The 5% network fee funds relay infrastructure and development.

## PTN Pricing

Within a Private TealeNet, pricing uses a **fixed rate** set by the PTN admin. There is no auction. All members of the PTN pay the same rate for inference.

PTN pricing is typically lower than WWTN pricing since members are contributing resources to a shared pool and trust is established via [certificates](ptn-certificates.md).

## WWTN Reverse Auction

On the World Wide TealeNet (public network), pricing uses a **reverse auction**:

1. **Providers post bids** -- each provider advertises a per-1K-token price for each model they serve
2. **Requesters pick lowest bid** -- when a requester needs inference, they select the provider with the lowest bid
3. **Tiebreak by quality score** -- if multiple providers bid the same price, the provider with the higher quality score (based on uptime, speed, and accuracy) wins
4. **Auto-bid formula** -- providers can enable automatic bidding:
   ```
   auto_bid = electricity_floor * 1.1 * demand_multiplier
   ```
   Where `demand_multiplier` adjusts based on current network demand (higher demand = higher bids accepted).

## WFQ Scheduling

When a provider serves both PTN and WWTN traffic, requests are scheduled using **Weighted Fair Queuing** (WFQ):

| Queue | Weight |
|-------|--------|
| PTN | 70% |
| WWTN | 30% |

When one queue is empty, the other gets 100% of capacity. This ensures PTN members get priority while WWTN traffic is still served.

## Pricing Examples

See [Pricing Tables](../reference/pricing-tables.md) for computed cost tables by model and quantization.

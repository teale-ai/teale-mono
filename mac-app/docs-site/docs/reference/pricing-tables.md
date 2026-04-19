# Pricing Tables

Computed cost tables by model, quantization, and hardware.

## Pricing Formula

```
cost_per_1K_tokens = (parameterCountB * 0.1) * quantizationMultiplier / 10,000
```

See [Pricing Protocol](../protocol/pricing-protocol.md) for the full specification.

## Cost per 1K Tokens by Model

### q4 Quantization (1.0x multiplier)

| Model | Parameters | Complexity | Cost per 1K Tokens |
|-------|-----------|-----------|-------------------|
| Llama 3.2 1B | 1B | 0.1 | $0.00001 |
| Llama 3.2 3B | 3B | 0.3 | $0.00003 |
| Gemma 3 4B | 4B | 0.4 | $0.00004 |
| Llama 3.1 8B | 8B | 0.8 | $0.00008 |
| Qwen 3 8B | 8B | 0.8 | $0.00008 |
| Phi 4 14B | 14B | 1.4 | $0.00014 |
| Mistral Small 24B | 24B | 2.4 | $0.00024 |
| Gemma 3 27B | 27B | 2.7 | $0.00027 |
| Qwen 3 32B | 32B | 3.2 | $0.00032 |
| Llama 4 Scout 109B | 109B | 10.9 | $0.00109 |

### q8 Quantization (1.5x multiplier)

| Model | Parameters | Cost per 1K Tokens |
|-------|-----------|-------------------|
| Llama 3.2 1B | 1B | $0.000015 |
| Llama 3.2 3B | 3B | $0.000045 |
| Gemma 3 4B | 4B | $0.000060 |
| Llama 3.1 8B | 8B | $0.000120 |
| Qwen 3 8B | 8B | $0.000120 |
| Phi 4 14B | 14B | $0.000210 |
| Mistral Small 24B | 24B | $0.000360 |
| Gemma 3 27B | 27B | $0.000405 |
| Qwen 3 32B | 32B | $0.000480 |
| Llama 4 Scout 109B | 109B | $0.001635 |

### fp16 Quantization (2.0x multiplier)

| Model | Parameters | Cost per 1K Tokens |
|-------|-----------|-------------------|
| Llama 3.2 1B | 1B | $0.000020 |
| Llama 3.2 3B | 3B | $0.000060 |
| Gemma 3 4B | 4B | $0.000080 |
| Llama 3.1 8B | 8B | $0.000160 |
| Qwen 3 8B | 8B | $0.000160 |
| Phi 4 14B | 14B | $0.000280 |
| Mistral Small 24B | 24B | $0.000480 |
| Gemma 3 27B | 27B | $0.000540 |
| Qwen 3 32B | 32B | $0.000640 |
| Llama 4 Scout 109B | 109B | $0.002180 |

## Electricity Floor Examples

The electricity floor ensures providers cover their power costs plus a 20% margin. Assumes $0.12/kWh electricity rate and 30 tokens/second generation speed.

### Formula

```
seconds = tokenCount / tokensPerSecond
kWh = (watts * seconds) / 3,600,000
floor = kWh * costPerKWh * 1.2
```

### Apple M1 (20W)

| Tokens | Seconds | kWh | Electricity | Floor (1.2x) |
|--------|---------|-----|-------------|---------------|
| 100 | 3.3s | 0.0000183 | $0.0000022 | $0.0000026 |
| 1,000 | 33.3s | 0.000185 | $0.0000222 | $0.0000266 |
| 10,000 | 333s | 0.00185 | $0.000222 | $0.000266 |

### Apple M4 Pro (38W)

| Tokens | Seconds | kWh | Electricity | Floor (1.2x) |
|--------|---------|-----|-------------|---------------|
| 100 | 3.3s | 0.0000348 | $0.0000042 | $0.0000050 |
| 1,000 | 33.3s | 0.000352 | $0.0000422 | $0.0000506 |
| 10,000 | 333s | 0.00352 | $0.000422 | $0.000506 |

### NVIDIA RTX 4090 (300W)

| Tokens | Seconds | kWh | Electricity | Floor (1.2x) |
|--------|---------|-----|-------------|---------------|
| 100 | 3.3s | 0.000275 | $0.0000330 | $0.0000396 |
| 1,000 | 33.3s | 0.00278 | $0.000333 | $0.000400 |
| 10,000 | 333s | 0.0278 | $0.00333 | $0.00400 |

## Token Price vs. Electricity Floor

For most models on efficient hardware (Apple Silicon), the token-based price exceeds the electricity floor. The floor becomes relevant for:

- **Small models on power-hungry hardware** (e.g., 1B model on RTX 4090)
- **High electricity rates** (e.g., >$0.30/kWh)
- **Slow generation speed** (CPU-only inference)

The effective price is always `max(token_price, electricity_floor)`.

## Revenue Split

| Recipient | Share |
|-----------|-------|
| Provider | 95% |
| Network fee | 5% |

**Example:** Serving 1,000 tokens of Qwen 3 8B (q4):
- Total cost: $0.00008
- Provider earns: $0.000076
- Network fee: $0.000004

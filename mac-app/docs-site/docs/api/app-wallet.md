# Wallet

Endpoints for managing the node's credit wallet, viewing transactions, and interacting with the Solana bridge.

---

## Get Balance

```
GET /v1/app/wallet
```

Returns the current wallet balance and summary statistics.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Response

```json
{
  "currentBalance": 5.432,
  "totalEarned": 12.100,
  "totalSpent": 6.668,
  "transactionCount": 247
}
```

| Field | Type | Description |
|---|---|---|
| `currentBalance` | number | Current credit balance |
| `totalEarned` | number | Total credits earned from providing inference |
| `totalSpent` | number | Total credits spent on inference requests |
| `transactionCount` | integer | Total number of transactions |

### Example

```bash
curl http://localhost:11435/v1/app/wallet
```

---

## List Transactions

```
GET /v1/app/wallet/transactions
```

Returns a list of recent wallet transactions.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Query Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `limit` | integer | 20 | Maximum number of transactions to return |

### Response

```json
{
  "transactions": [
    {
      "id": "tx-abc123",
      "type": "earn",
      "amount": 0.003,
      "peerID": "node-def456",
      "memo": "inference: llama-3.1-8b-q4",
      "timestamp": "2026-04-14T10:30:00Z"
    },
    {
      "id": "tx-abc124",
      "type": "spend",
      "amount": 0.001,
      "peerID": "node-ghi789",
      "memo": "inference: qwen3-4b-q4",
      "timestamp": "2026-04-14T10:25:00Z"
    }
  ]
}
```

### Example

```bash
curl "http://localhost:11435/v1/app/wallet/transactions?limit=10"
```

---

## Send Credits

```
POST /v1/app/wallet/send
```

Send credits to another peer.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Request Body

| Field | Type | Required | Description |
|---|---|---|---|
| `amount` | number | Yes | Amount of credits to send |
| `peerID` | string | Yes | ID of the recipient peer |
| `memo` | string | No | Optional memo for the transaction |

```json
{
  "amount": 0.001,
  "peerID": "node-def456",
  "memo": "Thanks for the compute!"
}
```

### Response

```json
{
  "transactionID": "tx-xyz789",
  "amount": 0.001,
  "peerID": "node-def456",
  "newBalance": 5.431
}
```

### Example

```bash
curl -X POST http://localhost:11435/v1/app/wallet/send \
  -H "Content-Type: application/json" \
  -d '{"amount": 0.001, "peerID": "node-def456", "memo": "Thanks for the compute!"}'
```

---

## Solana Wallet Status

```
GET /v1/app/wallet/solana
```

Returns the status of the Solana wallet bridge, including the on-chain address and balance.

### Authentication

Optional. Required when `allow_network_access` is enabled.

### Response

```json
{
  "address": "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU",
  "balance": 0.5,
  "status": "connected"
}
```

### Example

```bash
curl http://localhost:11435/v1/app/wallet/solana
```

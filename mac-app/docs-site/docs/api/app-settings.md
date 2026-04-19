# App Settings

```
PATCH /v1/app/settings
```

Update one or more application settings. Only the fields included in the request body are modified; all other settings remain unchanged.

## Authentication

Optional. Required when `allow_network_access` is enabled.

```
Authorization: Bearer <your-api-key>
```

## Request Body

A JSON object containing one or more setting keys with their new values.

| Key | Type | Description |
|---|---|---|
| `cluster_enabled` | boolean | Enable LAN cluster discovery |
| `wan_enabled` | boolean | Enable WAN peer-to-peer networking |
| `wan_relay_url` | string | URL of the WAN relay server |
| `max_storage_gb` | number | Maximum disk storage for downloaded models (GB) |
| `org_capacity_reservation` | number | Fraction of capacity reserved for organization (0.0 to 1.0) |
| `cluster_passcode` | string | Passcode for LAN cluster membership |
| `allow_network_access` | boolean | Require API key authentication for all requests |
| `electricity_cost` | number | Electricity cost per kWh |
| `electricity_currency` | string | Currency code for electricity cost (e.g. `USD`, `EUR`) |
| `electricity_margin` | number | Margin added to electricity cost for pricing |
| `keep_awake` | boolean | Prevent the system from sleeping while node is running |
| `auto_manage_models` | boolean | Automatically download and swap models based on demand |
| `inference_backend` | string | Inference backend to use (e.g. `mlx`, `llama.cpp`) |
| `language` | string | UI language code (e.g. `en`, `zh`) |

## Response

Returns the full updated settings object.

```json
{
  "cluster_enabled": true,
  "wan_enabled": true,
  "wan_relay_url": "wss://relay.teale.com",
  "max_storage_gb": 50,
  "org_capacity_reservation": 0.0,
  "cluster_passcode": "",
  "allow_network_access": false,
  "electricity_cost": 0.12,
  "electricity_currency": "USD",
  "electricity_margin": 0.1,
  "keep_awake": true,
  "auto_manage_models": true,
  "inference_backend": "mlx",
  "language": "en"
}
```

## Examples

### Enable WAN networking

```bash
curl -X PATCH http://localhost:11435/v1/app/settings \
  -H "Content-Type: application/json" \
  -d '{"wan_enabled": true}'
```

### Update multiple settings

```bash
curl -X PATCH http://localhost:11435/v1/app/settings \
  -H "Content-Type: application/json" \
  -d '{
    "keep_awake": true,
    "auto_manage_models": true,
    "max_storage_gb": 100
  }'
```

### Set electricity pricing

```bash
curl -X PATCH http://localhost:11435/v1/app/settings \
  -H "Content-Type: application/json" \
  -d '{
    "electricity_cost": 0.15,
    "electricity_currency": "USD",
    "electricity_margin": 0.2
  }'
```

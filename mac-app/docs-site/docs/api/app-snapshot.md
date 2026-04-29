# App State and Network Metadata

The released apps expose app state under `GET /v1/app`, but the response shape differs by platform.

## macOS

Request:

```bash
curl http://127.0.0.1:11435/v1/app
```

The macOS snapshot includes:

- `appVersion`
- `loadedModelID`
- `engineStatus`
- `isServerRunning`
- `auth`
- `demand`
- `settings`
- `models`

The `demand` block is useful for external clients because it exposes:

- `local_base_url`
- `local_model_id`
- `network_base_url`
- `network_bearer_token`

`network_bearer_token` is the app's rotating device bearer. It is useful for the app's own transport and short-lived debugging, but persistent direct gateway clients should use a revocable human-account API key from **Account > direct gateway api keys** instead.

## Windows

Request:

```bash
curl http://127.0.0.1:11437/v1/app
```

The Windows snapshot includes:

- `app_version`
- `service_state`
- `state_reason`
- `device`
- `auth`
- `demand`
- `wallet`
- `wallet_transactions`
- `loaded_model_id`
- `models`
- `active_transfer`

## Windows network metadata

The Windows companion API also exposes the data used by the Demand and Home tabs:

### GET /v1/app/network/models

Returns the live Teale Network model table with:

- model ID
- context length
- live device count
- TTFT
- TPS
- prompt pricing
- completion pricing

### GET /v1/app/network/stats

Returns high-level network totals such as:

- total devices
- total RAM
- total models
- average TTFT
- average TPS
- total credits earned
- total credits spent
- total USDC distributed

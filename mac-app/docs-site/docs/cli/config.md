# teale config

Read or write node settings.

## Synopsis

```
teale config <subcommand> [options]
```

## Subcommands

### teale config get

Show current settings. With no key argument, shows all settings.

```
teale config get [key] [--json]
```

| Argument/Option | Type | Description |
|---|---|---|
| `[key]` | string | Optional setting key to read (omit for all settings) |
| `--json` | flag | Output machine-readable JSON |

```bash
# Show all settings
teale config get

# Show a single setting
teale config get wan_enabled

# JSON output
teale config get --json
```

---

### teale config set

Update a setting.

```
teale config set <key> <value>
```

| Argument | Type | Description |
|---|---|---|
| `<key>` | string | Setting key (required) |
| `<value>` | string | New value (required) |

```bash
teale config set wan_enabled true
teale config set max_storage_gb 100
teale config set electricity_cost 0.15
```

## Setting Keys

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
| `electricity_currency` | string | Currency code for electricity cost |
| `electricity_margin` | number | Margin added to electricity cost for pricing |
| `keep_awake` | boolean | Prevent system sleep while node is running |
| `auto_manage_models` | boolean | Automatically download and swap models based on demand |
| `inference_backend` | string | Inference backend (e.g. `mlx`, `llama.cpp`) |
| `language` | string | UI language code (e.g. `en`, `zh`) |

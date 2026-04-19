# teale models

Manage models on the node.

## Synopsis

```
teale models <subcommand> [options]
```

## Subcommands

### teale models list

List all available models, including their download and load status.

```
teale models list [--json]
```

| Option | Type | Description |
|---|---|---|
| `--json` | flag | Output machine-readable JSON |

```bash
teale models list
```

```
MODEL                STATUS      SIZE
llama-3.1-8b-q4      loaded      4.7 GB
qwen3-4b-q4          downloaded  2.3 GB
gemma-3-12b-q4       available   7.1 GB
```

---

### teale models load

Load a downloaded model into GPU memory.

```
teale models load <model> [--download]
```

| Argument/Option | Type | Description |
|---|---|---|
| `<model>` | string | Model ID to load (required) |
| `--download` | flag | Download the model first if not already downloaded |

```bash
teale models load llama-3.1-8b-q4
```

```bash
teale models load gemma-3-12b-q4 --download
```

---

### teale models download

Download a model to local storage.

```
teale models download <model>
```

| Argument | Type | Description |
|---|---|---|
| `<model>` | string | Model ID to download (required) |

```bash
teale models download qwen3-4b-q4
```

---

### teale models unload

Unload the currently loaded model from GPU memory.

```
teale models unload
```

No arguments or options.

```bash
teale models unload
```

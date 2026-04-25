# Manage Models

The released apps split model management into two different views:

- **Supply** for local downloadable models
- **Demand** and **Home** for models that are actually available to use right now

---

## Local catalog

Use **Supply** to manage the local machine:

- download a model
- watch transfer progress
- load a model into memory
- unload the active model

The recommended action is the fastest way to get a working local model on a fresh install.

## What counts as available

Teale only presents models as chat targets when they are immediately usable:

- the local model must be loaded
- network models must be loaded on another live machine and visible to the Teale Network

Downloaded but unloaded models are not treated as available chat targets.

## Home chat model picker

The chat thread model picker is intentionally narrower than the local catalog.

It shows:

- your loaded local model
- live Teale Network models that are currently serving somewhere on the network
- `teale-auto` when the app can choose the best route for you

That means the list changes as other machines load or unload models.

## Demand model table

The **Demand > teale network models** table is the source of truth for current live network capacity. It shows:

- model ID
- context length
- number of live devices
- TTFT
- TPS
- prompt pricing
- completion pricing

## Practical workflow

1. Use **Supply** to get one good local model loaded.
2. Use **teale** for low-latency local chat.
3. Use the Home picker or Demand table when you want a bigger remote model such as Qwen or Kimi that is already live somewhere else on the Teale Network.

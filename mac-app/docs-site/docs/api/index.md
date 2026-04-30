# API Reference

This reference only documents the HTTP surfaces that ship in the currently released macOS, Windows, and Linux apps.

## Base URLs

| Surface | Base URL | Notes |
|---|---|---|
| macOS local API | `http://127.0.0.1:11435` | OpenAI-compatible local server plus app endpoints |
| Windows local model API | see `demand.local_base_url` | Usually `http://127.0.0.1:11436/v1` |
| Windows companion API | `http://127.0.0.1:11437` | Companion state, network metadata, wallet, and account endpoints |
| Linux local model API | see `demand.local_base_url` | Usually `http://127.0.0.1:11436/v1` |
| Linux companion API | `http://127.0.0.1:11437` | Companion state, network metadata, wallet, and account endpoints |
| Teale Network gateway | `https://gateway.teale.com` | Use a revocable human-account API key |

## Authentication

- Local macOS requests may require a bearer token if local network exposure is enabled for the app.
- Teale Network gateway requests should use a revocable human-account API key from **Account > direct gateway api keys**.
- In-app network chat already uses the bearer automatically.

## OpenAI-compatible endpoints

These are the main endpoints most external clients need:

- [GET /health](health.md)
- [GET /v1/models](models.md)
- [POST /v1/chat/completions](chat-completions.md)

`teale-auto` is supported on the macOS app and lets Teale pick the best currently available route.

## App endpoints in the released apps

- [App state and network metadata](app-snapshot.md)
- [Model download/load/unload](app-models.md)
- [Wallet and account endpoints](app-wallet.md)

## Platform notes

- The macOS app exposes `/v1/app` from the same local port as chat and models.
- The Windows and Linux releases expose `/v1/app` from the companion server on `127.0.0.1:11437`.
- The Windows and Linux **Demand** tabs also give you a copyable local curl and network curl so you do not have to assemble URLs manually.

# App Overview

The released macOS and Windows apps share the same top-level structure:

- `teale`
- `supply`
- `demand`
- `wallet`
- `account`

The docs below describe only the functionality that is in those released tabs.

---

## Header controls

The top-right header contains:

- a settings gear
- an `x.com` button
- a share-copy button

The settings gear currently includes:

- **Language**: English, Spanish, Portuguese (Brazil), Filipino (Philippines)
- **Display units**: Credits or USD

The Credits/USD switch is a display preference. The underlying network balance is still tracked in Teale credits.

## teale

The Home tab combines:

- device overview
- network stats
- thread-based chat

The model picker in the chat thread shows:

- the current local loaded model
- live Teale Network models that are loaded and ready to serve right now

Network entries expose prompt and completion pricing directly in the picker.

## supply

Supply is where you:

- see device state, hardware, power, backend, and current model
- unload the active local model
- inspect earnings
- use the recommended model action
- watch transfer progress
- browse the catalog of downloadable local models

## demand

Demand exposes both local and network inference:

- **local inference** shows the local base URL and a ready-to-copy curl request
- **teale network models** shows live loaded network models with context, device count, TTFT, TPS, and pricing
- **teale network** shows the gateway base URL, bearer token, and a ready-to-copy network curl request

Inside the app, Teale uses the device bearer automatically for network chat.

## wallet

Wallet is the device-wallet surface. It shows:

- device ID
- current device balance
- USDC reference balance
- earning rate
- send form
- ledger export

The released apps currently support sending **Teale credits** from the app. USDC is displayed, but USDC transfers are not part of the released app flow.

## account

Account is optional. Teale works without human sign-in.

After sign-in, the released apps show:

- sign-in state
- account identifiers
- linked devices

The Windows app also exposes account-wallet controls and linked-device actions in this tab.

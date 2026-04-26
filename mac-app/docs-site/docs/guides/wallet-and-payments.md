# Wallet and Payments

The released apps expose Teale's wallet features through the desktop UI.

---

## Device wallet

Both macOS and Windows show a device wallet with:

- device ID
- credits balance
- USDC reference balance
- earning rate
- ledger history
- CSV export

The device ID is the public receive address for the device wallet. Sharing it publicly is fine; sending funds out still requires bearer-authenticated access to the sender's wallet.

This is the wallet that earns while your device is available and serving.

## Credits vs USD

The settings gear lets you switch the display between Credits and USD.

- **Credits** is the native network balance.
- **USD** is a display conversion for the same balance and pricing.

Changing the toggle does not move funds or switch settlement rails. It only changes how the app labels and formats amounts.

## Sending credits

The currently released apps support sending **Teale credits** from the app.

Supported recipient styles:

- device ID
- phone number
- email
- GitHub username

Routing behavior:

- sending to a device ID lands in that device wallet
- sending to an account identifier lands in that account wallet

USDC transfers are not part of the current released app flow.

## Account wallet

The Windows release exposes an additional account-wallet section in **Account** for linked human accounts.

That view can:

- show account-level balance
- send credits from the account wallet
- sweep linked device balances into the account wallet
- remove devices from the linked-device list

## Ledger export

Use the **Export CSV** action in the wallet ledger when you need a portable record of:

- credits earned
- credits spent
- timestamps
- request or model metadata when available

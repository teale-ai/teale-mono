# Wallet and Account Endpoints

The released apps expose device-wallet operations directly, and the Windows and Linux companions also expose account-level wallet and linked-device operations.

## Device wallet

### GET /v1/app/wallet

macOS returns the current device wallet snapshot, including:

- `deviceID`
- balance
- total earned
- total spent

### GET /v1/app/wallet/transactions

macOS returns recent wallet transactions. The request supports a `limit` query parameter.

### POST /v1/app/wallet/send

Both released apps support sending Teale credits from the device wallet.

```bash
curl http://127.0.0.1:11435/v1/app/wallet/send \
  -H "Content-Type: application/json" \
  -d '{
    "asset": "credits",
    "recipient": "tailor512g1s-mac-studio.local",
    "amount": 1000000,
    "memo": "test send"
  }'
```

The released send flow is for **Teale credits**. USDC transfers are not part of the current app flow.

## Routing rules

- device IDs route to the destination device wallet
- phone, email, and GitHub username route to the destination account wallet
- sharing a device ID publicly is safe for receiving funds; spending still requires the sender's own bearer-authenticated wallet session

## Windows and Linux account endpoints

The Windows and Linux companion APIs also expose account state under `127.0.0.1:11437`.

### GET /v1/app/account

Returns:

- account user ID
- account balance
- USDC reference balance
- display name
- phone, email, GitHub username
- linked devices
- account ledger entries

### POST /v1/app/account/link

Links the local device to a human account record.

### POST /v1/app/account/send

Sends credits from the account wallet.

### POST /v1/app/account/sweep

Sweeps a linked device balance into the account wallet.

### POST /v1/app/account/devices/remove

Removes a device from the linked-device list.

## Windows and Linux auth session lookup

`POST /v1/app/auth/session` is part of the released Windows and Linux auth flow and is used to hydrate the local companion session from an access token.

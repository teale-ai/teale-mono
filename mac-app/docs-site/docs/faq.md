# Frequently Asked Questions

Common questions about the released macOS, Windows, and Linux apps.

## What do these docs cover?

Only the currently released Teale desktop apps on macOS, Windows, and Linux, plus the API surfaces they expose locally.

Older docs about protocol internals, PTNs, SDKs, self-hosting, and broader platform support were intentionally removed from this docs site.

## Does Teale work without sign-in?

Yes. Local inference always works with a loaded local model. The internet is only needed for Teale Network demand, wallet sync, linked-device account features, and remote model access.

## Can I use OpenAI-compatible tools with it?

Yes. The released apps expose OpenAI-compatible `/v1/models` and `/v1/chat/completions` endpoints.

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:11435/v1",
    api_key="not-needed"
)
```

See [Quickstart: API](getting-started/quickstart-api.md).

## Why does the model list change over time?

The released apps only show models that are available right now:

- your loaded local model
- live Teale Network models that are currently loaded somewhere else

Downloaded but unloaded models do not appear as chat targets.

## What is the difference between Credits and USD in the UI?

The toggle is a display preference.

- **Credits** is the native Teale balance.
- **USD** is a formatted conversion of the same balance and pricing.

## Can I send USDC from the app?

No. The released apps currently support sending **Teale credits**. USDC is shown in the UI as a reference balance.

## What recipients can I send credits to?

You can send to:

- device IDs
- phone numbers
- email addresses
- GitHub usernames

Device IDs route to device wallets. Account identifiers route to account wallets.

## What languages are supported in the released apps?

- English
- Spanish
- Portuguese (Brazil)
- Filipino (Philippines)

## Why did macOS block the app the first time?

The current mac release is Developer ID signed but not notarized. Use:

- right-click `Teale.app` > **Open**
- or **System Settings > Privacy & Security > Open Anyway**

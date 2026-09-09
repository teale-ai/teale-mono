# Consuming Teale inference

Teale is an OpenAI-compatible inference gateway at `https://gateway.teale.com`,
served by a distributed fleet of contributor machines. Anyone can consume.
No invite, no account approval: your wallet is a key you generate yourself.

## The wallet model

- Your **device key** (an ed25519 keypair you mint locally) is your wallet root.
  First sign-in deposits **100,000 credits ($0.10)** into your wallet.
- Usage draws down per token at catalog prices (`GET /v1/models`).
- Empty wallet = `402 Payment Required`. No credits, no service.
- When you run out: **earn** by supplying your own machine's inference to the
  fleet, or **pay** - top up with USDC on Solana (below).
- 1 USDC = 1,000,000 credits. Suppliers cash out credits to USDC (1.8% treasury
  fee).

## 1. Mint your device key

```bash
openssl genpkey -algorithm ed25519 -out device_sk.pem
# your deviceID = the raw 32-byte pubkey, hex:
openssl pkey -in device_sk.pem -pubout -outform DER | tail -c 32 | xxd -p -c 64
```

Keep `device_sk.pem` safe. Whoever holds it holds the wallet.

## 2. Sign in (challenge + exchange)

```bash
GW=https://gateway.teale.com
DID=<your 64-char hex deviceID>

curl -s $GW/v1/auth/device/challenge \
  -H 'content-type: application/json' -d "{\"deviceID\":\"$DID\"}"
# -> {"nonce":"<base64>","expiresAt":<unix>}

# sign the nonce BYTES (base64-decode first) with your device key.
# ed25519 is a one-shot algorithm: openssl needs the input as a file.
echo -n '<nonce>' | base64 -d > nonce.bin
openssl pkeyutl -sign -inkey device_sk.pem -rawin -in nonce.bin | xxd -p -c 256

curl -s $GW/v1/auth/device/exchange \
  -H 'content-type: application/json' \
  -d "{\"deviceID\":\"$DID\",\"nonce\":\"<nonce>\",\"signature\":\"<sig hex>\"}"
# -> {"token":"tok_dev_...","expiresAt":...,"welcomeBonus":100000}
```

Challenges are rate-limited per source IP (10/hour) - it is the anti-farming
ceiling on the welcome grant, not a limit on usage.

## 3. Link an account and mint an API key

```bash
curl -s $GW/v1/account/link -H "Authorization: Bearer tok_dev_..." \
  -H 'content-type: application/json' \
  -d '{"accountUserID":"you@example.com","deviceName":"my-box","platform":"cli"}'

curl -s $GW/v1/keys -X POST -H "Authorization: Bearer tok_dev_..." \
  -H 'content-type: application/json' -d '{"name":"first"}'
# -> {"token":"tk_live_...", ...}   <- your inference key
```

Keys can carry their own credit limits (`"creditLimit": N`) - scope a key for
a script or a teammate without handing them the wallet.

## 4. Call inference

```bash
curl -s $GW/v1/chat/completions \
  -H "Authorization: Bearer tk_live_..." -H 'content-type: application/json' \
  -d '{"model":"teale/auto","messages":[{"role":"user","content":"hello"}]}'
```

`teale/auto` routes to the smallest healthy model that fits your context.
Pin a model directly (`zai-org/glm-5.3-flash`, `qwen/qwen3.6-35b-a3b`,
`nousresearch/hermes-3-llama-3.1-8b`) when you care which one answers.
`max_tokens` is clamped to what your balance can afford; an empty wallet
returns `402` with `balance` and `required` in the error.

## 5. Check the wallet, top up

```bash
curl -s $GW/v1/credits -H "Authorization: Bearer tk_live_..."

# on-chain wallet state (deposit coordinates live here once enabled):
curl -s $GW/v1/account/wallet/onchain -H "Authorization: Bearer tok_dev_..."
# after sending USDC (Solana) to the treasury with your memo, claim the tx:
curl -s $GW/v1/account/wallet/deposit-treasury -H "Authorization: Bearer tok_dev_..." \
  -H 'content-type: application/json' -d '{"txSignature":"<solana tx sig>"}'
#   -> verified on-chain, credits land. Anyone can pay into any account:
#   the sender never gets wallet access, only the deposit.
```

## Notes

- Everything above is also what the Mac/Android apps do under the hood; this
  doc is the same path without the app.
- Prompts are processed in plaintext on supplier machines, as with any
  inference API. Do not send what you would not send to a third party.
- Supply side (earning by serving your hardware) is fleet-allowlisted today.

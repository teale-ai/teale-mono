# goose x Teale pilot (@teale_ai dogfood)

Validates that goose (Block's agent CLI) can run on Teale's own inference
before wiring it to the @teale_ai X account.

## 1. Mint the goose-bot API key (Taylor, in the app, or any logged-in session)

The CLI only lists keys; creation needs an account session:
- App UI: account > API keys > create, name `goose-bot`, **set a credit limit**
  (e.g. 50,000,000 credits = $50) so a runaway agent loop can't drain the account.
- Or curl with an account session token:
  `curl -X POST https://teale-gateway.fly.dev/v1/keys -H "Authorization: Bearer <session>" -H 'Content-Type: application/json' -d '{"name":"goose-bot","creditLimit":50000000}'`

## 2. goose provider

Copy `teale.json` to `~/.config/goose/providers/teale.json`, then:

```
export TEALE_API_KEY=<minted key>
export GOOSE_PROVIDER=teale
export GOOSE_MODEL="qwen/qwen3.6-35b-a3b"
goose session        # interactive
goose run -t "..."   # headless (bot loop)
```

## 3. Pilot probe (run BEFORE the goose e2e)

`pilot.py` drives the gateway directly through a realistic 5-turn agentic
sequence (tool call -> result -> answer -> second tool -> answer, plus a
non-streaming control) and prints per-turn TTFT, chunk inter-arrival,
tool-call delta shape (incremental vs block), finish reasons, the
tools-lane-exhausted header, and verdicts for silent tool loss.

```
TEALE_API_KEY=... python3 pilot.py
```

Pass criteria for wiring goose to the X account:
- streamed tool deltas incremental OR block-style both fine IF goose parses them (verify with one real `goose session` after);
- no silent tool loss on any turn;
- TTFT shape consistent with the canary gate numbers.

## Sequencing

Run after the fleet promotes mac-v2026.09.05.0313 (flock guard + #179
relay healing) and 16's manual push lands, so the pilot's load rides the
fixed paths. Keep 2+ tools-capable suppliers (qwen3.6-35b-a3b) loaded
during the pilot; a single wedged supplier drops the tools lane.

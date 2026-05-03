# Gateway operational scripts

Out-of-band patches we apply to the Kimi K2.6 suppliers
(`tailor512g1` + `tailor512g8`) when the supply-side mlx stack misbehaves.
The supply scripts themselves live on the machines (under
`/Users/tailor512*/teale-kimi-q8/`), not in this repo, so we keep the
patchers here as the canonical record.

## `patch-kimi-supplier-thinking.py`
Sets `--chat-template-args '{"enable_thinking": false}'` on the upstream
`mlx_lm.server` invocation. Idempotent; re-running on a host that already
has the false-thinking arg replaces it cleanly.

## `patch-kimi-supplier-reasoning.py`
Patches `mlx-openai-proxy.py` so SSE deltas with `delta.reasoning` get
folded into `delta.content`. Kimi K2.6 keeps emitting chain-of-thought
tokens in a `reasoning` field even with `enable_thinking: false`; without
this fold, OpenAI/Anthropic clients see zero content and small
`max_tokens` requests `finish_reason: length` empty.

## Usage
```sh
for h in tailor512g8 tailor512g1; do
  scp gateway/scripts/patch-kimi-supplier-reasoning.py "$h:/tmp/"
  ssh "$h" "python3 /tmp/patch-kimi-supplier-reasoning.py"
done
```

The scripts kickstart `com.teale.kimi-k26-mlx-server` themselves; allow
20-30 s for the mlx backend to reload Kimi before benchmarking.

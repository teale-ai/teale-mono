# Reversible agent connectors (first slice)

The Rust `teale` CLI can add a Teale provider to OpenCode or Hermes. This
command does not need the daemon and never calls inference. Claude Code and
Codex are follow-up slices; the Swift mac-app CLI does not have this command.
Use the Rust CLI binary built from `cli/`.

```sh
teale connections list
teale connections add opencode --model-file model.json
teale connections add hermes --model-file model.json --set-model
teale connections remove hermes
teale connections recover
```

Provide the API key through `TEALE_API_KEY` (or a variable named with
`--key-env`), never a command-line argument. No automatic key minting, wallet
access, purchase, or cloud fallback occurs. The endpoint defaults to
`https://gateway.teale.com/v1`; using it for inference later consumes credits.
Connector setup itself does not spend credits. HTTP endpoints are accepted only
on loopback. Remote HTTPS inference is not an offline/private-local promise.

Model metadata is explicit, not guessed from the model name:

```json
{
  "id": "qwen/qwen3.6-35b-a3b",
  "name": "Qwen3.6",
  "contextWindow": 32768,
  "maxOutputTokens": 8192,
  "vision": false,
  "tools": true,
  "reasoningEfforts": ["none", "high"]
}
```

That is a schema example, not a verified catalog capability assertion. Use
limits and capabilities confirmed for the chosen backend. OpenCode receives
context/output limits, modalities, tool capability and reasoning variants.
Hermes receives a Chat Completions custom provider; existing agent reasoning
preferences are left untouched. Its custom provider format does not expose all
these capability fields.

Default model/provider selection is unchanged unless `--set-model` is given.
There is no automatic session restart, skill installation or configuration sync.
The command does not claim the harness is installed, or that an end-to-end
conversation succeeded. Verify the selected harness version and tool streaming
before promoting it to production.

## Configuration and ownership

OpenCode honors `OPENCODE_CONFIG`, then `XDG_CONFIG_HOME`. If multiple global
OpenCode files exist, setup refuses to guess between them; pass `--config` after
checking the merged effective configuration, including project overrides.
Hermes honors `HERMES_HOME`. An explicit `--config` selects a destination.
Existing `provider.teale` / `providers.teale` entries are never adopted or
replaced without a receipt. Invalid/non-mapping files are rejected.

JSONC and YAML are edited using lossless syntax trees, preserving unrelated
comments/values. A persistent receipt under `~/.teale/connections/` records the
exact before/after bytes. Remove restores the exact original file only when its
current bytes still equal the connector-written bytes. Any later edit, even an
unrelated edit, causes a conflict with no changes. This deliberately conservative
first slice does not merge user edits. Keep the receipt and reconcile the config
manually rather than forcing an overwrite. There is no `--force` shortcut.

An OS advisory lock serializes connector processes and releases on process death.
A journal is synced before any mutation; each file is replaced atomically.
`recover` rolls back interrupted writes only if each affected file still equals
its recorded before/after state. Other edits stop recovery without deleting the
journal. Journal and receipts contain API keys and original config secrets;
Unix files are 0600 and the connector state directory 0700. No credentials are
printed by list or completion output. Windows writes are refused until ACL
support exists. Symlink destinations/parents are refused.

The lock covers Teale connector processes, not arbitrary editors. Byte checks
before each write/restore catch ordinary concurrent edits, but a non-cooperating
writer can race the final check and atomic rename. Close config editors while
connecting/disconnecting. Parent directory metadata and OS permissions are not
restored to their former values; replacement config files use 0600. Multi-file
operations are journaled/recoverable, not globally atomic to observers.

## Verification and upstream

`cargo test -p teale-cli --locked`, `cargo clippy -p teale-cli --all-targets
--locked -- -D warnings`, and `cargo fmt -p teale-cli -- --check` cover this slice.
Binary smoke tests use temporary homes, fake credentials, add/remove exact-byte
restoration, explicit model switching, and post-connect edit conflicts. They do
not prove compatibility with a live OpenCode/Hermes release or execute paid
inference. Full workspace/platform CI and peer review are required before merge.

The transaction/projection design was informed by Magnitude, reviewed at
9187740037f41fb208849ac66afb41b41a00c304. This Rust slice is independently written;
no Magnitude TypeScript implementation is vendored. Consult
`packages/harness-connections` in that source for the original design. Third-party
crate licenses are carried by their distributions; audit them in release review.

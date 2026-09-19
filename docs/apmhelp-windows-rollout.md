# APM Help Windows PIN rollout

## Release gate

1. Merge the rollout commit on green CI.
2. Push a `teale-YYYY.MM.DD.HHMM` tag from the exact green commit. The Windows workflow must publish `Teale.exe` and `checksums.txt` on that release.
3. Verify the release asset checksum and confirm the installer embeds the same `teale-node.exe` and `teale-tray.exe` commit.
4. Use the direct `Teale.exe` asset URL. Do not send `/releases/latest`, which can resolve to a Mac-only release.
5. On a disposable authenticated test node, confirm `teale-node pin create <temporary-name>` reaches the gateway create route instead of returning 404, then delete the temporary PIN. The September 19 shipped CLI was stale and failed this check; current source maps local `/v1/app/pins/create` to gateway `POST /v1/pins`.
6. Until Authenticode is enabled, state plainly that Windows shows Unknown publisher and requires **More info -> Run anyway**, then UAC approval.

## One-machine canary

Choose a staff-owned Windows 10/11 x64 laptop with at least 16 GB RAM, 10 GB free disk, administrator access, AC power, and outbound HTTPS/WSS access to GitHub, model hosting, gateway.teale.com, and relay.teale.com.

Keep the APM join PIN out of chat, tickets, logs, and command transcripts. Fleet obtains it from Taylor's live PIN admin surface and enters it locally.

### Fresh install and enrollment

1. Record existing Teale services, processes, config, data, and model directories. Use a machine with no prior Teale identity for the first canary.
2. Run the verified installer locally as administrator:
   ```powershell
   .\Teale.exe /PINCODE=<enter-locally> /LOG=C:\Teale\logs\installer-canary.log
   ```
3. Confirm exactly one `TealeNode` service and one per-user `teale-tray.exe` process, with the leaf tray icon.
4. Confirm `C:\Teale\config\teale-node.toml` has a `[pin]` join code configured without printing its value.
5. Confirm the gateway shows one pending device under the expected APM PIN. Taylor/admin approves that exact device id.
6. Confirm the node changes from pending to active, receives its netmap, and remains outside the default public-supply lane.

### Model and employee-lane proof

The rollout target is one pinned model across 150+ staff machines, consumed by APM Help for its own bill-entry work. Do not promote a model from a generic chat smoke test. The current 16 GB-compatible starting candidate is `nousresearch/hermes-3-llama-3.1-8b` (5.7 GB Q5_K_M, 8k default context), but it is a candidate until it passes the bill-entry acceptance set. The Windows catalog's other 16 GB option is Llama 3.1 8B Q4_K_M. Qwen 3 8B is currently marked 24 GB and is not a 16 GB fleet default.

If bills arrive as images or PDFs, extract text/OCR before this text-model lane unless the selected model and runtime have separately passed a multimodal test. Never infer a successful bill-entry field from an unread image.

1. Build a de-identified, labeled acceptance set representative of APM's real bills: vendor, invoice number, invoice date, due date, subtotal, tax, total, currency, account/coding fields, line items, and duplicate indicators. Define exact-match and tolerance rules before testing.
2. Benchmark both 16 GB-compatible candidates on the same Windows canary and acceptance set. Require valid schema output, field-level accuracy agreed with APM, no invented required fields, p50/p95 latency, peak working set below safe machine headroom, and stable behavior through at least 100 consecutive jobs. Record model file checksum, prompt/schema version, context size, and runtime flags.
3. Select one winner and apply that single model as the APM PIN's desired model policy. Confirm download, checksum, load, `/health`, and active model status.
4. Send the acceptance workload from an APM-side client authenticated to the APM PIN lane. This is the actual demand path, not a node-local ping.
5. Require dispatch evidence naming the canary employee node and the APM PIN. Confirm schema-valid responses, usage accounting, and no appearance in the public catalog/default lane.
6. Kill/rework rule: any public-lane eligibility, unapproved node id, missing accounting, hidden fleet fallback, schema drift, identity reset, or acceptance-threshold miss stops rollout.

### Capacity proof

Treat capacity as measured bill-entry jobs, not model tokens in isolation. Start each 16 GB laptop at one concurrent request; raising per-node concurrency competes for RAM and must pass a separate benchmark.

For measured per-node throughput `r` completed bills/minute and simultaneously available staff fraction `a`, conservative fleet capacity is:

```
steady bills/minute = 150 * a * r
hourly capacity      = 60 * 150 * a * r
headroom-adjusted    = hourly capacity * 0.70
```

Use the 30% reserve for offline laptops, retries, tail latency, and workday churn until production telemetry justifies a different reserve. Before each rollout stage, load test the APM-authenticated PIN path at the expected arrival rate for 60 minutes and at 2x that rate for 15 minutes. Record completed/failed jobs, p50/p95/p99 latency, queue depth, retries, node utilization, and distinct serving nodes. The plan for 150 machines must show both the bill-entry arrival rate and measured `r`; machine count alone is not a capacity claim.

### Reboot and upgrade

1. Reboot. Confirm the service starts once, the tray starts once, PIN membership remains active, the node identity is unchanged, and the model returns healthy without re-enrollment.
2. Publish a canary rebuild (or use the next green build). Confirm the login-time updater detects only `teale-*` releases containing `Teale.exe` and opens the correct asset.
3. Install over top. Confirm identity/model preservation, one service/tray, active PIN membership, and a second employee-lane request.

## Rollout gate

Proceed beyond one machine only after every step passes and telemetry is clean for one workday. Batch the next 5 machines, then 20%, then the remainder. Stop on SmartScreen/help-desk friction above 10%, install failure above 2%, any duplicate process, any identity reset, or any employee node entering the default lane.

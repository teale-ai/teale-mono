# Oncall runbook — teale-gateway + supply fleet

Short, actionable playbook for the first 2 weeks after OpenRouter approval.
Keep this open in a tab while on-call.

## Dashboards / endpoints

| What | URL |
|---|---|
| Gateway health | https://gateway.teale.com/health |
| Gateway metrics | https://gateway.teale.com/metrics |
| Fly.io app | https://fly.io/apps/teale-gateway |
| Relay health | https://relay.teale.com/health (if exposed) |
| Logs (Fly) | `fly logs -a teale-gateway` |

Key metric queries (Prometheus / `/metrics`):

```
# success rate by model (last 5 min)
sum(rate(gateway_requests_total{status="ok"}[5m])) by (model) /
  sum(rate(gateway_requests_total[5m])) by (model)

# p95 TTFT by model
histogram_quantile(0.95, sum(rate(gateway_ttft_seconds_bucket[5m])) by (le, model))

# devices connected
gateway_devices_connected

# devices eligible per model
gateway_devices_eligible

# retries by reason
rate(gateway_retries_total[5m])
```

## Symptom → action

### "All requests 503 `model_unavailable`"
- Check `gateway_devices_eligible{model="..."}` — is it below the per-model floor (3 for 70B+, 2 else)?
- Run `fly ssh console -a teale-gateway` → `curl localhost:8080/health`; confirm the gateway itself is healthy.
- `fly logs` → look for `relay connect failed` or `peer_closed` spikes. If yes, relay is down: check https://relay.teale.com/health.
- If relay is fine, check individual supply nodes (SSH, `systemctl status teale-node` on Linux or `launchctl list | grep teale` on macOS).

### "p95 TTFT spiked to >10 s"
- Which model? `gateway_ttft_seconds` bucketed by model.
- Is a Mac thermal-throttling? Check heartbeat thermalLevel in node logs.
- Is the fleet under-supplied? If `gateway_devices_eligible{model=...}` = minimum, scale the fleet before the model breaks.
- Check `gateway_retries_total{reason="timeout"}` — if it's climbing, upstream devices are slow, consider quarantining more aggressively.

### "Requests are succeeding but OpenRouter reports low success rate"
- OR counts the whole round-trip; check their traces vs ours.
- `gateway_requests_total{status="error"}` — what's the breakdown? Open `records.jsonl` on the gateway host for a recent sample.
- Possible: we're returning 200 with `[DONE]` before a fault, but content is empty. Check `tokens_out` distribution.

### "Gateway crash / OOM"
- Fly auto-restarts; confirm in `fly status`. If restart loop, SSH and run manually to see panic.
- Check memory growth curve in `process_resident_memory_bytes` over prior 24 h — leak? Recent PR?
- Immediate mitigation: `fly scale memory 1024 -a teale-gateway` doubles RAM while you investigate.

### "Supply node disappears mid-stream"
- Expected failure mode; gateway retries once to next-best device.
- If it happens repeatedly from the same nodeID, quarantine-loop is likely:
  - `fly logs -a teale-gateway | grep <nodeID>` — look for error patterns.
  - SSH to that node, check `teale-node` logs.
  - Often: llama-server OOM after a long completion; bump `context_size` down or reduce concurrency cap.

### "OpenRouter paged us — 5xx rate >1% for 15 min"
- Status page: https://status.teale.com (update with whatever we set up)
- If gateway-side: roll back the most recent deploy (`fly releases rollback -a teale-gateway`)
- If fleet-side: open `gateway_devices_connected` — if the number dropped suddenly, a shared dependency (relay, DNS) regressed. Check cloudflare / DNS providers.
- Post-mortem template in `.context/postmortems/`

## Deploys

| Component | Command |
|---|---|
| Gateway | `fly deploy -a teale-gateway` from `gateway/` |
| Relay | `fly deploy -a teale-relay` from `relay/` |
| Node (macOS) | `brew upgrade teale-node` (homebrew formula auto-bumps on release) |
| Node (Linux) | `curl -sSL install.teale.com \| sh` or package manager |
| Node (Windows) | Inno Setup installer auto-updates via GitHub releases |

### Rollback

```bash
fly releases list -a teale-gateway
fly releases rollback <id> -a teale-gateway
```

Do NOT rollback if a relay/gateway protocol field changed between versions;
supply nodes running the older build won't know the new field. Check release
notes before rolling back.

## Scheduled maintenance

1. Announce 24 h ahead on status page.
2. Window at lowest-traffic hour (03:00 UTC).
3. Scale gateway to `min_machines_running = 1`, drain, upgrade, scale back.
4. Sanity-run `stress/scenarios/cold_start.toml` immediately after.

## Shared secrets

- `GATEWAY_TOKENS` — Fly secret. `fly secrets list -a teale-gateway`.
- Ed25519 gateway identity: persisted on Fly volume `/data/gateway-identity.key`.
- DO NOT commit any of the above.

## Escalation

1. On-call primary: Taylor Hou (taylor@apmhelp.com)
2. Backup: TBD — assign before go-live
3. OpenRouter partner contact: TBD (from onboarding email)

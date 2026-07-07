# PIN enterprise rollout runbook

Deploying a Private Inference Network to a company fleet (tested target:
200+ employees, ~90% Windows / ~10% macOS). Prompts and completions never
leave company devices; gateway.teale.com coordinates membership and token
counts only.

## 0. Prerequisites

- One IT owner with a Teale account, signed in on at least one device
  (this account becomes the network **owner/admin**).
- Optionally a second account for the **modelrator** role (fleet model
  management without membership powers).
- Fleet reachability: UDP between office devices (LAN traffic is direct;
  cross-site traffic uses UDP hole-punching). Allow outbound UDP and
  outbound HTTPS to gateway.teale.com.

## 1. Create the network

On the admin's device (app → networks → *Create network*, or CLI):

```
teale-node pin create "acme-corp"
# → created network 'acme-corp'
# → join PIN: 7K2M-9QX4-TC   (share it; you approve each device)
```

Record the join PIN. Treat it like a wifi password: anyone who has it can
*request* to join — approval is the real gate, so a leak is an annoyance,
not a breach. Rotate any time (`pin rotate-code`); members are unaffected.

## 2. Windows mass deployment (Intune / SCCM / GPO)

The installer accepts a PIN preseed. Deploy per your usual silent-install
flow:

```
Teale.exe /VERYSILENT /SUPPRESSMSGBOXES /PINCODE=7K2M-9QX4-TC
```

(`TEALE_PIN_JOIN_CODE` in the service environment works too.) On first
start each node auto-submits a join request and keeps re-knocking until
approved. Nothing else is needed on the endpoint.

Batch-approve as requests arrive (app → networks → pending banner, or):

```
teale-node pin requests                       # list pending devices
teale-node pin approve <device-id>            # one
teale-node pin requests --json | jq -r '.[].deviceId' | \
  xargs -n1 teale-node pin approve            # all pending
```

Machine names come through automatically (device display name = hostname);
rename anything unclear: `pin rename-device <device-id> "Front Desk"`.

## 3. macOS (the 10%)

Mac users install the Teale app normally, open networks, and enter the
join PIN. Same approval queue.

## 4. Push the standard model loadout

The modelrator (or admin) sets the desired loadout per serving device —
devices download and load autonomously and report progress:

```
teale-node pin models <device-id> qwen3-4b-instruct --state loaded
```

Or from the app: networks → Models tab → set desired per device. Devices
refusing pushes (local "Allow remote model management" opt-out) show as
`opted_out`. Watch convergence in the same tab (loaded / downloading /
error with reason).

Employees then use private inference from:
- the Teale app chat (provider: pin), and
- `http://127.0.0.1:11437/v1/app/chat/completions` with
  `{"provider":"pin","model":"…","messages":[…]}` for IDEs/scripts on any
  member machine.

## 5. Day-2 operations

| Situation | Action |
|---|---|
| Employee offboards | `pin remove-device <id>` then `pin rotate-code`. Netmaps refresh within ~60 s; the device loses control-plane access immediately. |
| Laptop lost/stolen | Same as offboarding. Data-plane sessions from the removed key are refused on every peer after the next netmap refresh. |
| Machine misbehaving | Disable (temporary, admin-only) instead of remove. |
| Usage review | networks → Usage tab, or `pin usage --by device` / `--by consumer` / `--by model`. Token counts only — PINs have no credits or billing. |
| Second admin | Have them sign in to a Teale account, link a device, then `PUT /v1/pins/:id/roles/:account {"role":"admin"}` (app UI: settings → roles). Never leave a single-admin network. |
| Gateway outage | Inference on the office LAN keeps working from cached netmaps (up to 24 h). Membership changes queue until the gateway returns. |

## 6. Troubleshooting

- **Join request never appears**: check outbound HTTPS to
  gateway.teale.com; confirm the code (`pin status` on the endpoint shows
  `pending` when the knock landed). Knocks are rate-limited to 5/hour per
  device — a mistyped code five times means a quiet hour; rotate-code and
  retry if in doubt.
- **Devices show but inference fails between sites**: UDP blocked.
  LAN-local traffic still works; for cross-site, allow outbound UDP
  (any port ≥1024) or place sites on a shared VPN. Relay fallback for
  fully-blocked UDP is on the roadmap (spec §16 Phase 2).
- **Model push stuck in `downloading`**: check the device's disk space and
  the Models tab error tooltip (`last_error` from the device).
- **`opted_out` on a machine that should serve**: someone toggled off
  "Allow remote model management" locally — it's device-sovereign by
  design; ask the user or reimage policy-side.
- **Windows service logs**: `C:\Teale\logs\` + `pin status --json` on the
  endpoint.

## 7. Security posture (what IT should know)

- Transport: Noise_IK (X25519 / ChaCha20-Poly1305 / BLAKE2s), mutual
  authentication against a gateway-signed membership snapshot (netmap)
  that devices verify with a pinned gateway key.
- The gateway sees: device metadata, model ids, token counts, scheduling
  requests (model + context size). It never sees prompts or completions —
  including the relay fallback path (ciphertext only).
- The join PIN only grants the right to file a join request. Approval,
  removal, disable, rotation: admin-only. Model policy: admin/modelrator.
- Devices can additionally opt into the public DIN (earning credits) —
  PIN requests always jump the queue ahead of public work unless the
  device explicitly opts for equal priority. Company-only fleets should
  set the network default `dinContributionDefault=false` (settings tab).

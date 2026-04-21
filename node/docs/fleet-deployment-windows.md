# Windows Fleet Deployment Guide — Partner Pilot

Deploy teale-node as TealeNet supply nodes across a partner fleet of Windows
laptops. **Pilot spec:** Windows 10 (build 17763+) or 11, **16 GB RAM or
more**, Intel or AMD iGPU (Vulkan accelerates decode 2–3× over CPU). No
NVIDIA GPU required, but if present is auto-offloaded via Vulkan/CUDA.

## Two deployment paths

### A) Contributor-driven (recommended for mixed end-user laptops)

Each contributor:

1. Downloads `Teale.exe` from the Drive / download link you send.
2. Windows SmartScreen shows **"Windows protected your PC — unknown publisher."**
   One-time click: **More info → Run anyway**. (This warning disappears once
   the code-signing cert is active; until then, include that instruction in
   your onboarding email.)
3. UAC prompt → Yes.
4. Installer wizard: **Welcome** (what Teale does) → **Behavior** (one
   checkbox, pre-checked: "Keep supplying when lid is closed on AC") →
   **Install**.
5. Under-16-GB machines see a friendly "coming soon for smaller devices"
   message and exit without installing.
6. ≥16-GB machines see a visible progress bar downloading the 5.7 GB
   Hermes-3-Llama-3.1-8B Q5 model, then the NSSM-wrapped service starts
   and the tray icon appears.

### B) Admin-driven (SCCM / GPO / PowerShell Remoting)

Use `scripts/deploy-windows.ps1` for silent / scripted installs.

```powershell
# Basic — picks Vulkan llama-server, Hermes-3-8B Q5, enables lid-closed supply:
.\deploy-windows.ps1 -AllowSupplyLidClosed

# Network file share for the model (fleet rollouts, avoids 195× HF downloads):
.\deploy-windows.ps1 -ModelSharePath "\\fileserver\teale\models\hermes-3-llama-3.1-8b-Q5_K_M.gguf" `
    -AllowSupplyLidClosed

# CPU-only fallback (for machines that fail Vulkan init — rare):
.\deploy-windows.ps1 -LlamaBuild cpu -AllowSupplyLidClosed
```

## Prerequisites

- Windows 10 (17763+) / Windows 11, x64
- **16 GB RAM minimum** (script refuses to install on less; `-SkipRamGate` overrides for dev)
- ~10 GB free disk (6 GB model + binaries + logs)
- Outbound network access to `wss://relay.teale.com` (port 443)
- Administrator access on target machines
- `teale-node.exe` (Rust release build, x86_64-pc-windows-msvc)

## Installer build (`Teale.exe`)

CI-based: push `teale-v<version>` tag → `.github/workflows/windows-installer.yml`
builds, runs ISCC, uploads artifact. Download, upload to Drive, share link.

Manual build: see `node/installer/BUILD-INSTALLER.txt`.

Once the code-signing cert arrives, uncomment the signtool step in the
workflow and add `CERT_PFX_BASE64` + `CERT_PASSWORD` to repo secrets. Next
release becomes SmartScreen-clean.

## Model distribution strategies

**Option A — Google Drive link** (pilot default). Contributors download
both `Teale.exe` and the GGUF pulls from HuggingFace at install time.
Works for ~200 contributors; HuggingFace is fine unless you're rolling to
a China-heavy fleet.

**Option B — Network file share** (LAN):
```powershell
# Stage on the server:
mkdir \\fileserver\teale\models
Copy-Item hermes-3-llama-3.1-8b-Q5_K_M.gguf \\fileserver\teale\models\

# Deploy pointing at the share:
.\deploy-windows.ps1 -ModelSharePath "\\fileserver\teale\models\hermes-3-llama-3.1-8b-Q5_K_M.gguf" -AllowSupplyLidClosed
```

**Option C — BranchCache + BITS** (WAN / multi-site): host the GGUF on
internal HTTPS and enable BranchCache via GPO. `Start-BitsTransfer`
leverages it automatically — first machine per subnet pulls from the
server, subsequent machines peer-pull.

**Option D — Override URL via env var** (for custom mirror):
Set `TEALE_MODEL_URL` before running the installer / deploy script. The
post-install PS1 falls back to the HuggingFace URL if the primary fails.

## Fleet deployment methods

### PowerShell Remoting (WinRM)

```powershell
$machines = Get-Content .\machine-list.txt

Invoke-Command -ComputerName $machines -ThrottleLimit 20 `
    -FilePath \\share\teale\deploy-windows.ps1 `
    -ArgumentList @("-ModelSharePath", "\\fileserver\teale\models\hermes-3-llama-3.1-8b-Q5_K_M.gguf",
                    "-AllowSupplyLidClosed")
```

### Group Policy Startup Script

1. Place `deploy-windows.ps1`, `teale-node.exe`, and the model on SYSVOL or a share.
2. GPO: Computer Config > Policies > Windows Settings > Scripts > Startup.
3. Add PS script with parameters:
   ```
   -TealeNodePath "\\share\teale\teale-node.exe"
   -ModelSharePath "\\share\teale\models\hermes-3-llama-3.1-8b-Q5_K_M.gguf"
   -AllowSupplyLidClosed
   ```
4. Link the GPO to the OU containing target machines. Runs on next reboot.

### SCCM Task Sequence

1. Package containing `teale-node.exe`, `deploy-windows.ps1`, the GGUF.
2. Task sequence runs the deploy script with fleet-standard args.
3. Deploy to a device collection targeting the ≥16 GB machines.

## Pilot behavior (what contributors see)

1. **Tray icon appears** post-install (green = supplying, yellow = on
   battery / paused, gray = user-paused, red = disconnected).
2. Hover tooltip: *"Teale — Supplying · 12 requests · 4,800 credits today"*.
3. Right-click menu:
   - **Pause supply** — toggles user-pause. Tray goes gray. Service keeps
     running, just stops accepting new inference.
   - **Resume supply** — clears the user-pause flag.
   - **Open Teale dashboard** — opens `https://teale.com/supply` in browser.
   - **Quit** — closes the tray (service continues in background).
4. Lid-closed on AC → still supplying, screen dark, Wi-Fi up, fans may
   spin up slightly. Machine awake until lid opened again.
5. Unplug AC → tray flips yellow within ~5 seconds, node deregisters from
   gateway routing; supply resumes within ~30 seconds of reconnecting AC.
6. Scheduled task on every user logon pings GitHub Releases; if a newer
   `Teale.exe` is published, shows a Windows toast and opens the download
   link. User installs over top (identity key preserved).

## Monitoring

### Service status across fleet

```powershell
$machines = Get-Content .\machine-list.txt
Invoke-Command -ComputerName $machines -ScriptBlock {
    Get-Service TealeNode | Select-Object MachineName, Status
}
```

### Local status endpoint (tray's data source)

On any contributor machine, inspect the live state the tray is showing:

```powershell
Invoke-RestMethod http://127.0.0.1:11437/status | ConvertTo-Json
# { "state": "supplying",
#   "supplying_since": "1745234567",
#   "requests_today": 12,
#   "credits_today": 4800,
#   "on_ac": true,
#   "paused_reason": null }
```

### Logs

```powershell
# Last 20 lines of stdout log:
Get-Content "\\MACHINE\C$\Teale\logs\teale-node-stdout.log" -Tail 20

# Stderr for Vulkan init failures / relay connection errors:
Get-Content "\\MACHINE\C$\Teale\logs\teale-node-stderr.log" -Tail 50
```

### Verify in gateway

Registered nodes appear under their catalog slug in `/v1/models` healthy-
supplier counts:

```bash
curl -sH "Authorization: Bearer $TEALE_TOKEN" https://gateway.teale.com/v1/models \
  | jq '.data[] | select(.id=="nousresearch/hermes-3-llama-3.1-8b")'
```

### Fleet-wide restart

```powershell
Invoke-Command -ComputerName $machines -ScriptBlock { Restart-Service TealeNode }
```

## Updating

### Via Inno Setup installer (recommended)

Publish a new `Teale.exe` (bumped `#define AppVer`) to GitHub Releases
with a tag like `teale-v0.3.0`. Every contributor's on-logon scheduled
task will catch it, toast them, and open the download. Contributor
double-clicks the new installer; Inno Setup upgrades in place.

### Via file share (GPO-managed fleet)

```powershell
Invoke-Command -ComputerName $machines -ScriptBlock {
    Stop-Service TealeNode
    Copy-Item "\\share\teale\teale-node.exe" "C:\Teale\bin\teale-node.exe" -Force
    Start-Service TealeNode
}
```

## Uninstall

Via Add/Remove Programs → Teale → Uninstall. Removes service, tray, model,
config. **Identity key under `C:\Teale\data` is preserved** across
reinstalls so credit-earning history carries over. To fully reset, manually
delete `C:\Teale\data` before reinstalling.

## Troubleshooting

### "Windows protected your PC" screen blocks install

Expected until the code-signing cert is live. Instruct contributors to
click **More info → Run anyway** once. This is one-time per `Teale.exe`
hash; updates trigger the same dialog unless the new build is signed with
the same cert identity.

### Installer reports RAM < 16 GB and exits

Working as intended for the pilot scope. Smaller-RAM tier support is
planned post-pilot. Override with `deploy-windows.ps1 -SkipRamGate` for
dev testing only.

### Vulkan init fails on startup

Tray shows red, `teale-node-stderr.log` has `ggml_vulkan: failed to init`.
Causes and fixes:
- **Old drivers** — run Windows Update + the vendor's GPU driver update.
- **No supported GPU** — the machine has Intel HD 3000 / pre-2014 silicon;
  fall back to CPU with `deploy-windows.ps1 -LlamaBuild cpu`.
- **Vulkan runtime missing** — install the Vulkan Runtime from LunarG or
  reinstall the GPU driver (which bundles it).

### Service won't start

`Get-Content C:\Teale\logs\teale-node-stderr.log -Tail 50` usually points
at: missing GGUF file (download didn't finish), llama-server binary
corrupted (re-run installer), or relay connection blocked (firewall /
corporate proxy — check outbound 443 to `relay.teale.com`).

### Machine sleeps despite lid-closed checkbox

Double-check the power plan:
```powershell
powercfg /query SCHEME_CURRENT SUB_BUTTONS 5ca83367-6e45-459f-a27b-476b1d01c936
```
Lid close action on AC should be 0 ("Do nothing"). Corporate policies
sometimes override user powercfg changes — contact IT if overrides are
reverting the setting.

### Tray icon doesn't appear

Tray is per-user, starts via Startup-folder shortcut. If it went missing:
`Start-Process "C:\Teale\bin\teale-tray.exe"` to relaunch. Tray auto-
reconnects to the service when the service is restored.

## Pilot escalation path

- Gateway issues → `reference_gateway_relay.md` has deploy and bearer
  token. `fly deploy -c gateway/fly.toml` for emergency rollbacks.
- Scheduler-skipping of battery-paused nodes can be verified via
  `gateway/tests/registry_and_scheduler.rs::scheduler_skips_battery_paused_laptop`.
- All Hermes-3 8B routes: `gateway/models.yaml` catalog entry at line 101.

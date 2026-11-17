# Windows Fleet Deployment Guide — Partner Pilot

Deploy teale-node as TealeNet supply nodes across a partner fleet of Windows
laptops. **Pilot spec:** Windows 10 (build 17763+) or 11, **16 GB RAM or
more**, Intel or AMD iGPU (Vulkan accelerates decode 2–3× over CPU). No
NVIDIA GPU required.

## Two deployment paths

### A) Contributor-driven (recommended for mixed end-user laptops)

Each contributor:

1. Downloads `Teale.exe` from the link you send (a GitHub release asset or
   your Drive copy of it).
2. Windows SmartScreen shows **"Windows protected your PC — unknown publisher."**
   One-time click: **More info → Run anyway**. (This warning disappears once
   the code-signing cert is active; until then, include that instruction in
   your onboarding email.)
3. UAC prompt → Yes.
4. Installer wizard: **Welcome** (what Teale does) → **Behavior** (one
   checkbox, pre-checked: "Keep supplying when the lid is closed (AC only)")
   → **Install**.
5. Under-16-GB machines see a friendly "coming soon for smaller devices"
   message and exit without installing.
6. On ≥16-GB machines the installer copies the binaries, registers the
   NSSM-wrapped `TealeNode` service and starts it, then opens the Teale
   window. **No model is downloaded during setup**: the window recommends
   the best model for the machine and the contributor starts the download
   there (Hermes-3-Llama-3.1-8B Q5_K_M, 5.7 GB, on a 16 GB laptop). The
   node checks the file's SHA-256 before it is used.

### B) Admin-driven (SCCM / GPO / PowerShell Remoting)

Use `scripts/deploy-windows.ps1` for silent / scripted installs. Unlike the
installer it can stage a model up front.

```powershell
# Basic — picks Vulkan or CPU llama-server, downloads Hermes-3-8B Q5 (hash-checked),
# enables lid-closed supply:
.\deploy-windows.ps1 -AllowSupplyLidClosed

# Network file share for the model (fleet rollouts, avoids 195x HF downloads).
# Pass the file's SHA-256 so the copy is verified:
.\deploy-windows.ps1 -ModelSharePath "\\fileserver\teale\models\hermes-3-llama-3.1-8b-Q5_K_M.gguf" `
    -ModelSha256 b2fb813afad50963f29a9e69cd844a02add63d6a29f965fef4e084fdd10075d3 `
    -AllowSupplyLidClosed

# CPU-only fallback (for machines that fail Vulkan init — rare):
.\deploy-windows.ps1 -LlamaBuild cpu -AllowSupplyLidClosed
```

The llama.cpp release defaults to the repo pin in `.github/llama-cpp-version`
(`b8840` when the script is copied without the repo) and its zip is checked
against the published SHA-256. NSSM (nssm.cc) publishes no checksums; on
locked-down fleets stage `nssm.exe` yourself.

## Prerequisites

- Windows 10 (17763+) / Windows 11, x64
- **16 GB RAM minimum** (both paths refuse to install on less; `deploy-windows.ps1 -SkipRamGate` overrides for dev)
- ~10 GB free disk (6 GB model + binaries + logs)
- Outbound network access to `wss://relay.teale.com` and `https://gateway.teale.com` (port 443)
- Administrator access on target machines
- `teale-node.exe` (Rust release build, x86_64-pc-windows-msvc) for path B

## Installer build (`Teale.exe`)

CI-based: push a tag `teale-YYYY.MM.DD.HHMM` (for example
`teale-2026.11.13.1946`). `.github/workflows/windows-installer.yml` builds the
binaries, runs ISCC with `/DAppVer=<the tag without "teale-">`, and publishes
`Teale.exe` plus `checksums.txt` on that release. Hand staff the release
asset's direct URL; do not use GitHub `/releases/latest`, which can point at a
macOS-only release.

Manual build: see `node/installer/BUILD-INSTALLER.txt`.

Once the code-signing cert arrives, uncomment the signtool step in the
workflow and add `CERT_PFX_BASE64` + `CERT_PASSWORD` to repo secrets. Next
release becomes SmartScreen-clean.

## What the install changes on the machine

- `C:\Teale` (fixed path): `bin\`, `config\`, `models\`, `logs\`, `data\`.
  Permissions are reset so only SYSTEM and Administrators can write anywhere
  under it; standard users get read/execute. `C:\Teale\data` (node identity
  key, gateway account session) is readable only by SYSTEM and
  Administrators.
- Service `TealeNode` (NSSM, LocalSystem, auto start, below-normal priority).
  Stopping it sends Ctrl+C and waits up to 35 s so in-flight requests drain.
- Lid-closed checkbox ticked: AC standby and hibernate timeouts set to never
  and lid-close on AC set to "do nothing". The previous values are recorded in
  `C:\Teale\config\powercfg-backup.txt` and restored on uninstall. While a
  request is running the node additionally blocks idle sleep.
- Scheduled task `TealeUpdateCheck`: runs `check-update.ps1` unelevated at
  every user's logon (see Updating).
- `teale://` URL protocol and a per-user startup shortcut for the tray.

## Model distribution strategies

**Option A — In-app download** (contributor path, default). The Teale window
downloads the recommended GGUF from Hugging Face and verifies its SHA-256.

**Option B — Network file share** (LAN, admin path):
```powershell
# Stage on the server:
mkdir \\fileserver\teale\models
Copy-Item hermes-3-llama-3.1-8b-Q5_K_M.gguf \\fileserver\teale\models\

# Deploy pointing at the share:
.\deploy-windows.ps1 -ModelSharePath "\\fileserver\teale\models\hermes-3-llama-3.1-8b-Q5_K_M.gguf" `
    -ModelSha256 b2fb813afad50963f29a9e69cd844a02add63d6a29f965fef4e084fdd10075d3 -AllowSupplyLidClosed
```

**Option C — Internal mirror + BranchCache** (WAN / multi-site): host the GGUF
on internal HTTPS, enable BranchCache via GPO, and run
`deploy-windows.ps1 -ModelUrl https://mirror.example/hermes.gguf -ModelSha256 <hash>`.
The script uses `Start-BitsTransfer`, which leverages BranchCache: the first
machine per subnet pulls from the server, the rest peer-pull.

## Fleet deployment methods

### PowerShell Remoting (WinRM)

```powershell
$machines = Get-Content .\machine-list.txt

Invoke-Command -ComputerName $machines -ThrottleLimit 20 `
    -FilePath \\share\teale\deploy-windows.ps1 `
    -ArgumentList @("-ModelSharePath", "\\fileserver\teale\models\hermes-3-llama-3.1-8b-Q5_K_M.gguf",
                    "-ModelSha256", "b2fb813afad50963f29a9e69cd844a02add63d6a29f965fef4e084fdd10075d3",
                    "-AllowSupplyLidClosed")
```

### Group Policy Startup Script

1. Place `deploy-windows.ps1`, `teale-node.exe`, and the model on SYSVOL or a share.
2. GPO: Computer Config > Policies > Windows Settings > Scripts > Startup.
3. Add PS script with parameters:
   ```
   -TealeNodePath "\\share\teale\teale-node.exe"
   -ModelSharePath "\\share\teale\models\hermes-3-llama-3.1-8b-Q5_K_M.gguf"
   -ModelSha256 b2fb813afad50963f29a9e69cd844a02add63d6a29f965fef4e084fdd10075d3
   -AllowSupplyLidClosed
   ```
4. Link the GPO to the OU containing target machines. Runs on next reboot.

### SCCM Task Sequence

1. Package containing `teale-node.exe`, `deploy-windows.ps1`, the GGUF.
2. Task sequence runs the deploy script with fleet-standard args.
3. Deploy to a device collection targeting the ≥16 GB machines.

Private Inference Network preseed: `Teale.exe /VERYSILENT /PINCODE=XXXX-XXXX-XX`
makes the node submit a join request on first start; the network admin
approves it from the app or `teale-node pin`.

## Pilot behavior (what contributors see)

1. **Tray icon appears** after install. Two states: **green leaf** while
   serving, **gray leaf** for everything else (starting, downloading,
   paused, waiting for AC, offline, disconnected).
2. Hover tooltip: a headline (for example *"Teale — Serving"*,
   *"Teale — Waiting for AC"*, *"Teale — Paused"*) and one detail line (the
   loaded model, download progress, or the reason it is not serving).
3. Right-click menu:
   - **Pause supply** — sets the user-pause flag. Service keeps running
     (model stays loaded), it just stops taking new inference.
   - **Resume supply** — clears the user-pause flag.
   - **Open Teale** — opens the companion window (the UI bundled into the
     tray; it never loads remote pages).
   - **Close tray icon (Teale keeps supplying)** — exits only the tray
     process; the service continues in the background.
   - **Quit Teale (stop supplying)** — after a confirmation and a UAC prompt,
     stops the `TealeNode` service (in-flight requests drain first; this also
     ends `llama-server.exe` and frees the model's memory), then exits the
     tray. Nothing restarts it until the next Windows boot (service is
     `SERVICE_AUTO_START`) or an admin runs `Start-Service TealeNode`. If the
     UAC prompt is declined the tray stays up and says so.
4. Lid closed on AC (checkbox ticked) → still supplying, screen dark, Wi-Fi
   up, fans may spin up slightly. Group Policy can override the lid setting;
   see Troubleshooting.
5. Unplug AC → within a few seconds the node stops advertising itself to the
   gateway and the tray shows *"Waiting for AC"* at its next 5 s refresh;
   supply resumes after AC returns.
6. Sign-in: the Teale window signs in with an emailed 6-digit code (gateway
   account). The node keeps the session in `C:\Teale\data` and uses it to
   link this device to the account.

## Monitoring

### Service status across fleet

```powershell
$machines = Get-Content .\machine-list.txt
Invoke-Command -ComputerName $machines -ScriptBlock {
    Get-Service TealeNode | Select-Object MachineName, Status
}
```

### Local status endpoint (tray's data source)

On any contributor machine, inspect the live state the tray is showing (the
control API answers only on 127.0.0.1 and rejects browser pages from other
origins):

```powershell
Invoke-RestMethod http://127.0.0.1:11437/status | ConvertTo-Json
# { "state": "supplying",
#   "supplying_since": "1745234567",
#   "requests_today": 12,
#   "credits_today": 4800,
#   "on_ac": true,
#   "paused_reason": null,
#   "throttle_level": 100 }
```

### Logs

```powershell
# Last 20 lines of stdout log:
Get-Content "\\MACHINE\C$\Teale\logs\teale-node-stdout.log" -Tail 20

# Stderr for Vulkan init failures / relay connection errors:
Get-Content "\\MACHINE\C$\Teale\logs\teale-node-stderr.log" -Tail 50
```

The tray writes `tray.log` (rotated at 1 MiB) to `C:\Teale\logs` when it can,
otherwise to `%LOCALAPPDATA%\Teale\logs` of the signed-in user.

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

### Via the installer (recommended)

Publish a new release tagged `teale-YYYY.MM.DD.HHMM` (CI stamps the same
version into the installer). At each user's logon the `TealeUpdateCheck`
task compares the highest such release that has `Teale.exe` with
`C:\Teale\version.txt`. Only a **strictly newer** version prompts the user;
on "Yes" it downloads `Teale.exe`, verifies its SHA-256 against the
release's `checksums.txt`, and only then starts the installer, which
upgrades in place (identity key and models preserved). A failed check opens
the release page instead. Builds stamped `0.0.0.0` (local builds without
`/DAppVer`) are never prompted.

### Via file share (GPO-managed fleet)

```powershell
Invoke-Command -ComputerName $machines -ScriptBlock {
    Stop-Service TealeNode
    Copy-Item "\\share\teale\teale-node.exe" "C:\Teale\bin\teale-node.exe" -Force
    Start-Service TealeNode
}
```

## Uninstall

Via Add/Remove Programs → Teale → Uninstall. Removes the service, the tray,
the update task, binaries, config and logs, and restores the recorded power
settings. **`C:\Teale\data` (identity key) and `C:\Teale\models` (downloaded
GGUFs) are kept** so credit-earning history and downloads survive a
reinstall. To fully reset, delete `C:\Teale\data` (and `C:\Teale\models` to
reclaim disk) after uninstalling.

`deploy-windows.ps1 -Uninstall` removes the service and restores the power
settings; add `-RemoveFiles` to delete `C:\Teale` entirely.

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

Tray stays gray, `teale-node-stderr.log` has `ggml_vulkan: failed to init`.
Causes and fixes:
- **Old drivers** — run Windows Update + the vendor's GPU driver update.
- **No supported GPU** — the machine has Intel HD 3000 / pre-2014 silicon;
  fall back to CPU with `deploy-windows.ps1 -LlamaBuild cpu`.
- **Vulkan runtime missing** — install the Vulkan Runtime from LunarG or
  reinstall the GPU driver (which bundles it).

### Service won't start

`Get-Content C:\Teale\logs\teale-node-stderr.log -Tail 50` usually points
at: a missing or corrupt GGUF (re-download it from the Teale window; a
checksum mismatch is reported there), a corrupted llama-server binary
(re-run the installer), or the relay connection being blocked (firewall /
corporate proxy — check outbound 443 to `relay.teale.com`).

### Machine sleeps despite lid-closed checkbox

Double-check the power plan:
```powershell
powercfg /query SCHEME_CURRENT SUB_BUTTONS 5ca83367-6e45-459f-a27b-476b1d01c936
```
Lid close action on AC should be 0 ("Do nothing"). Corporate policies
sometimes override user powercfg changes — contact IT if overrides are
reverting the setting. The node's own wake request only prevents *idle*
sleep while a request is running; it cannot override lid or policy sleep.

### Tray icon doesn't appear

Tray is per-user, starts via Startup-folder shortcut. If it went missing:
`Start-Process "C:\Teale\bin\teale-tray.exe"` to relaunch. Tray auto-
reconnects to the service when the service is restored.

## Pilot escalation path

- Gateway issues → escalate to the Teale gateway on-call; emergency gateway
  rollbacks are done from `gateway/fly.toml` by the gateway owners.
- Scheduler-skipping of battery-paused nodes can be verified via
  `gateway/tests/registry_and_scheduler.rs::scheduler_skips_battery_paused_laptop`.
- Hermes-3 8B routing: the `nousresearch/hermes-3-llama-3.1-8b` entry in
  `gateway/models.yaml`.

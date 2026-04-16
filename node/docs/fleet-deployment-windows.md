# Windows Fleet Deployment Guide

Deploy teale-node to a fleet of Windows machines as TealeNet supply nodes.

## Prerequisites

- Windows 10/11 x64 with 16GB+ RAM
- Outbound network access to `wss://relay.teale.com` (port 443)
- Administrator access on target machines
- Pre-built `teale-node.exe` for Windows (see [Building](#building-teale-nodeexe))

## Building teale-node.exe

**Option A: Cross-compile from macOS/Linux** (requires [cross](https://github.com/cross-rs/cross)):
```bash
cross build --release --target x86_64-pc-windows-gnu
# Output: target/x86_64-pc-windows-gnu/release/teale-node.exe
```

**Option B: Build natively on Windows** (requires [Rust](https://rustup.rs/)):
```powershell
cargo build --release
# Output: target\release\teale-node.exe
```

## Quick Start — Single Machine

```powershell
# Place teale-node.exe next to the script, then:
.\scripts\deploy-windows.ps1
```

This downloads llama-server, NSSM, and the default model (Qwen3-4B Q4_K_M, ~2.8GB), then installs and starts the TealeNode Windows Service.

## Model Distribution (Fleet)

Downloading the model individually on 200+ machines is wasteful. Choose a strategy:

### Option A: Network File Share (recommended for LAN)

Stage the model on a Windows file share accessible to all machines:

```powershell
# On your file server:
mkdir \\fileserver\teale\models
# Copy the GGUF model there

# Deploy with share path:
.\deploy-windows.ps1 -ModelSharePath "\\fileserver\teale\models\qwen3-4b-q4_k_m.gguf"
```

The script copies the model locally to `C:\Teale\models\`. For fast LANs, you could also point the config directly at the UNC path (requires the SYSTEM account to have read access to the share).

### Option B: BranchCache + BITS (WAN / multi-site)

Host the model on an internal HTTPS server and enable BranchCache via Group Policy. The deploy script uses `Start-BitsTransfer`, which automatically leverages BranchCache — the first machine per subnet downloads from your server, subsequent machines pull from the peer cache.

### Option C: SCCM / Intune Package

Package the model file as an SCCM application or Intune Win32 app. Deploy it to `C:\Teale\models\` as a prerequisite before running the deploy script.

### Option D: Pre-staged Image

For air-gapped or imaging-based deployments, include `C:\Teale\models\` in your golden image.

## Fleet Deployment Methods

### Method A: PowerShell Remoting (WinRM)

```powershell
# Ensure WinRM is enabled on target machines (often already on for domain-joined PCs)
$machines = Get-Content .\machine-list.txt

# Copy files to a share accessible from all machines, then:
Invoke-Command -ComputerName $machines -ThrottleLimit 20 -FilePath \\share\teale\deploy-windows.ps1 -ArgumentList @(
    "-ModelSharePath", "\\fileserver\teale\models\qwen3-4b-q4_k_m.gguf"
)
```

Use `-ThrottleLimit` to control concurrency and avoid saturating the network.

### Method B: Group Policy Startup Script

1. Place `deploy-windows.ps1`, `teale-node.exe`, and the model on a SYSVOL or network share
2. Create a GPO: Computer Configuration > Policies > Windows Settings > Scripts > Startup
3. Add the PowerShell script with parameters:
   ```
   -TealeNodePath "\\share\teale\teale-node.exe" -ModelSharePath "\\share\teale\models\qwen3-4b-q4_k_m.gguf"
   ```
4. Link the GPO to the OU containing target machines
5. Machines execute on next reboot

### Method C: SCCM Task Sequence

1. Create a package containing `teale-node.exe` and `deploy-windows.ps1`
2. Create a task sequence that runs the deploy script
3. Deploy to a device collection targeting your 16GB machines

## 32GB Test Machine

For the test machine with more RAM, use a larger model for better quality:

```powershell
# Larger model with bigger context:
.\deploy-windows.ps1 -ContextSize 16384 -DisplayName "TestBench-32GB" `
    -ModelUrl "https://huggingface.co/Qwen/Qwen3-14B-GGUF/resolve/main/qwen3-14b-q4_k_m.gguf"
```

## Monitoring

### Check service status across fleet

```powershell
$machines = Get-Content .\machine-list.txt
Invoke-Command -ComputerName $machines -ScriptBlock { Get-Service TealeNode | Select-Object MachineName, Status }
```

### View logs remotely

```powershell
# Last 20 lines of stdout log:
Get-Content "\\MACHINE\C$\Teale\logs\teale-node-stdout.log" -Tail 20

# Check stderr for errors:
Get-Content "\\MACHINE\C$\Teale\logs\teale-node-stderr.log" -Tail 50
```

### Verify nodes in relay

From a Teale demand node (Mac/iPhone app), the connected supply nodes appear in the peer list. You can also check the stdout log for `Registered with relay` confirmation.

### Fleet-wide restart

```powershell
Invoke-Command -ComputerName $machines -ScriptBlock { Restart-Service TealeNode }
```

## Updating

### Update teale-node binary

```powershell
# Fleet-wide binary update:
Invoke-Command -ComputerName $machines -ScriptBlock {
    Stop-Service TealeNode
    Copy-Item "\\share\teale\teale-node.exe" "C:\Teale\bin\teale-node.exe" -Force
    Start-Service TealeNode
}
```

### Update the model

```powershell
Invoke-Command -ComputerName $machines -ScriptBlock {
    Stop-Service TealeNode
    Copy-Item "\\share\teale\models\new-model.gguf" "C:\Teale\models\new-model.gguf" -Force
    # Update the config to point to the new model, then:
    Start-Service TealeNode
}
```

## Uninstall

```powershell
# Remove service only:
.\deploy-windows.ps1 -Uninstall

# Remove service and all files:
.\deploy-windows.ps1 -Uninstall -RemoveFiles
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Service fails to start | llama-server crash (OOM) | Reduce `context_size` or use a smaller model |
| "Failed to connect" in logs | Firewall blocking outbound 443 | Allow outbound TCP 443 to `relay.teale.com` |
| High CPU / machine slow | Too many inference threads | Reduce `--threads` in `extra_args` |
| Service starts then stops | Config error | Check `C:\Teale\logs\teale-node-stderr.log` |
| Model download fails | Network / proxy issue | Use `-ModelSharePath` instead |
| Identity key missing | APPDATA not set correctly | Check NSSM env: `nssm get TealeNode AppEnvironmentExtra` |

## File Layout

After deployment, each machine has:

```
C:\Teale\
├── bin\
│   ├── teale-node.exe        # Supply node agent
│   ├── llama-server.exe      # Inference engine
│   └── nssm.exe              # Service manager
├── config\
│   └── teale-node.toml       # Node configuration
├── data\
│   └── Teale\
│       └── wan-identity.key  # Ed25519 identity (auto-generated)
├── logs\
│   ├── teale-node-stdout.log # Application log
│   └── teale-node-stderr.log # Error log
└── models\
    └── qwen3-4b-q4_k_m.gguf # GGUF model (~2.8GB)
```

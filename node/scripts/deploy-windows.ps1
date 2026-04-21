#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys teale-node as a Windows Service for TealeNet supply node operation.

.DESCRIPTION
    Fully provisions a Windows machine as a TealeNet supply node:
    - Downloads llama-server (CPU variant) from llama.cpp releases
    - Downloads NSSM (Non-Sucking Service Manager) for service wrapping
    - Downloads or copies the GGUF model file
    - Generates teale-node.toml with machine-specific settings
    - Installs and starts TealeNode as a Windows Service

    Safe to re-run for upgrades (idempotent). Use -Uninstall to remove.

.EXAMPLE
    # Basic install (downloads model from Hugging Face):
    .\deploy-windows.ps1

    # Install using a model from a network share (recommended for fleet):
    .\deploy-windows.ps1 -ModelSharePath "\\fileserver\teale\models\qwen3-4b-q4_k_m.gguf"

    # Install on test machine:
    .\deploy-windows.ps1 -DisplayName "TestBench-32GB"

    # Uninstall:
    .\deploy-windows.ps1 -Uninstall
#>

[CmdletBinding()]
param(
    # Installation directory
    [string]$InstallDir = "C:\Teale",

    # Path to teale-node.exe (defaults to same directory as this script or .\teale-node.exe)
    [string]$TealeNodePath = "",

    # UNC path or local path to a pre-staged GGUF model (skips download)
    [string]$ModelSharePath = "",

    # Direct download URL for the GGUF model
    [string]$ModelUrl = "https://huggingface.co/NousResearch/Hermes-3-Llama-3.1-8B-GGUF/resolve/main/Hermes-3-Llama-3.1-8B.Q5_K_M.gguf",

    # Model filename (derived from URL if not set)
    [string]$ModelFilename = "",

    # llama.cpp release tag for downloading llama-server (Vulkan build)
    [string]$LlamaRelease = "b8840",

    # llama-server build variant: "vulkan" (Intel/AMD iGPU, recommended) or "cpu"
    [ValidateSet("vulkan","cpu")]
    [string]$LlamaBuild = "vulkan",

    # GPU layers to offload (0 = CPU-only, 999 = all). Auto-set based on build.
    [int]$GpuLayers = -1,

    # Context window size (8192 comfortably fits 8B-Q5 on a 16 GB laptop)
    [int]$ContextSize = 8192,

    # Node display name (defaults to hostname)
    [string]$DisplayName = $env:COMPUTERNAME,

    # Relay server URL
    [string]$RelayUrl = "wss://relay.teale.com/ws",

    # Allow supply while lid is closed on AC power (configures powercfg).
    # Matches the installer wizard's "Behavior" page default.
    [switch]$AllowSupplyLidClosed,

    # Skip the RAM gate (pilot minimum is 16 GB). Use only for dev machines.
    [switch]$SkipRamGate,

    # Remove the TealeNode service and optionally all files
    [switch]$Uninstall,

    # When uninstalling, also delete all files in InstallDir
    [switch]$RemoveFiles
)

$ErrorActionPreference = "Stop"
$ServiceName = "TealeNode"

# --- Paths ---
$BinDir    = Join-Path $InstallDir "bin"
$ModelDir  = Join-Path $InstallDir "models"
$ConfigDir = Join-Path $InstallDir "config"
$LogDir    = Join-Path $InstallDir "logs"
$DataDir   = Join-Path $InstallDir "data"

$NssmExe       = Join-Path $BinDir "nssm.exe"
$LlamaExe      = Join-Path $BinDir "llama-server.exe"
$TealeExe      = Join-Path $BinDir "teale-node.exe"
$ConfigFile    = Join-Path $ConfigDir "teale-node.toml"

# ============================================================
# UNINSTALL
# ============================================================
if ($Uninstall) {
    Write-Host "=== Uninstalling TealeNode ===" -ForegroundColor Yellow

    # Stop and remove the service
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-Host "Stopping service..."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        if (Test-Path $NssmExe) {
            & $NssmExe remove $ServiceName confirm
        } else {
            sc.exe delete $ServiceName
        }
        Write-Host "Service removed."
    } else {
        Write-Host "Service not found, nothing to remove."
    }

    if ($RemoveFiles -and (Test-Path $InstallDir)) {
        Write-Host "Removing $InstallDir..."
        Remove-Item -Recurse -Force $InstallDir
        Write-Host "Files removed."
    }

    Write-Host "=== Uninstall complete ===" -ForegroundColor Green
    exit 0
}

# ============================================================
# INSTALL / UPGRADE
# ============================================================

# RAM gate — pilot minimum is 16 GB. Bypass with -SkipRamGate for dev.
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1073741824, 1)
if (-not $SkipRamGate -and $ramGB -lt 16) {
    Write-Error "This machine has $ramGB GB RAM. Pilot minimum is 16 GB. Use -SkipRamGate to override (not recommended)."
    exit 1
}

# Pick the right default for GPU layers based on llama build:
#   vulkan → 999 (full offload), cpu → 0.
if ($GpuLayers -eq -1) {
    $GpuLayers = if ($LlamaBuild -eq "vulkan") { 999 } else { 0 }
}

Write-Host "=== Deploying TealeNode ===" -ForegroundColor Cyan
Write-Host "  Install dir:  $InstallDir"
Write-Host "  Display name: $DisplayName"
Write-Host "  RAM:          $ramGB GB"
Write-Host "  llama build:  $LlamaBuild"
Write-Host "  GPU layers:   $GpuLayers"
Write-Host "  Context size: $ContextSize"
Write-Host "  Lid-closed:   $([bool]$AllowSupplyLidClosed)"
Write-Host ""

# --- Create directory structure ---
foreach ($dir in @($BinDir, $ModelDir, $ConfigDir, $LogDir, $DataDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Host "Created: $dir"
    }
}

# --- Resolve teale-node.exe ---
if ($TealeNodePath -eq "") {
    # Look in common locations
    $candidates = @(
        (Join-Path $PSScriptRoot "teale-node.exe"),
        (Join-Path $PSScriptRoot "..\target\x86_64-pc-windows-gnu\release\teale-node.exe"),
        (Join-Path $PSScriptRoot "..\target\release\teale-node.exe"),
        ".\teale-node.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $TealeNodePath = (Resolve-Path $c).Path
            break
        }
    }
}

if ($TealeNodePath -eq "" -or -not (Test-Path $TealeNodePath)) {
    $msg = "teale-node.exe not found. Use -TealeNodePath or place it next to this script: " + $PSScriptRoot + "\teale-node.exe"
    Write-Error $msg
    exit 1
}

Write-Host "Found teale-node.exe at $TealeNodePath"
Copy-Item -Path $TealeNodePath -Destination $TealeExe -Force

# --- Download NSSM ---
if (-not (Test-Path $NssmExe)) {
    Write-Host "Downloading NSSM..."
    $nssmZip = Join-Path $env:TEMP "nssm-2.24.zip"
    $nssmExtract = Join-Path $env:TEMP "nssm-2.24"

    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip -UseBasicParsing
    Expand-Archive -Path $nssmZip -DestinationPath $env:TEMP -Force
    $nssmSrc = Join-Path $nssmExtract "win64\nssm.exe"
    Copy-Item -Path $nssmSrc -Destination $NssmExe -Force

    Remove-Item -Path $nssmZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $nssmExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "NSSM installed at $NssmExe"
} else {
    Write-Host "NSSM already present at $NssmExe"
}

# --- Download llama-server ---
if (-not (Test-Path $LlamaExe)) {
    Write-Host "Downloading llama-server $LlamaBuild release $LlamaRelease..."
    $llamaZip = Join-Path $env:TEMP "llama-server-win-$LlamaBuild.zip"
    $llamaUrl = "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaRelease/llama-$LlamaRelease-bin-win-$LlamaBuild-x64.zip"

    Invoke-WebRequest -Uri $llamaUrl -OutFile $llamaZip -UseBasicParsing
    $llamaExtract = Join-Path $env:TEMP "llama-extract"
    Expand-Archive -Path $llamaZip -DestinationPath $llamaExtract -Force

    # Find llama-server.exe in the extracted archive (may be nested)
    $found = Get-ChildItem -Path $llamaExtract -Recurse -Filter "llama-server.exe" | Select-Object -First 1
    if ($found) {
        Copy-Item -Path $found.FullName -Destination $LlamaExe -Force
        # Also copy any DLLs in the same directory (runtime dependencies)
        $dllDir = Split-Path $found.FullName
        Get-ChildItem -Path $dllDir -Filter "*.dll" | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $BinDir -Force
        }
    } else {
        Write-Error "llama-server.exe not found in downloaded archive. Check release tag: $LlamaRelease"
        exit 1
    }

    Remove-Item -Path $llamaZip -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $llamaExtract -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "llama-server installed at $LlamaExe"
} else {
    Write-Host "llama-server already present at $LlamaExe"
}

# --- Download or copy model ---
if ($ModelFilename -eq "") {
    if ($ModelSharePath -ne "") {
        $ModelFilename = Split-Path $ModelSharePath -Leaf
    } else {
        # Extract filename from URL (strip query params)
        $ModelFilename = ($ModelUrl -split '\?')[0] -replace '.+/', ''
    }
}
$ModelPath = Join-Path $ModelDir $ModelFilename

if (-not (Test-Path $ModelPath)) {
    if ($ModelSharePath -ne "") {
        Write-Host "Copying model from share: $ModelSharePath"
        Copy-Item -Path $ModelSharePath -Destination $ModelPath -Force
    } else {
        Write-Host "Downloading model: $ModelFilename  (this may take a while...)"
        # Use BITS for resumable download with progress
        try {
            Start-BitsTransfer -Source $ModelUrl -Destination $ModelPath -Description "Downloading $ModelFilename"
        } catch {
            Write-Host "BITS transfer failed, falling back to Invoke-WebRequest..."
            Invoke-WebRequest -Uri $ModelUrl -OutFile $ModelPath -UseBasicParsing
        }
    }
    $fileSize = [math]::Round((Get-Item $ModelPath).Length / 1048576, 1)
    Write-Host "Model ready at $ModelPath -- $fileSize megabytes"
} else {
    $fileSize = [math]::Round((Get-Item $ModelPath).Length / 1048576, 1)
    Write-Host "Model already present at $ModelPath -- $fileSize megabytes"
}

# --- Calculate thread count ---
$logicalCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$threads = [math]::Max(2, $logicalCores - 2)
Write-Host "CPU: $logicalCores logical cores, using $threads threads for inference"

# --- Generate teale-node.toml ---
# Use forward slashes for TOML (Rust handles both on Windows)
$llamaPath  = $LlamaExe.Replace('\', '/')
$modelToml  = $ModelPath.Replace('\', '/')
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1073741824, 1)

$tomlContent = @"
# teale-node configuration -- auto-generated by deploy-windows.ps1
# Machine: $env:COMPUTERNAME | RAM: $ramGB GB | Cores: $logicalCores

[relay]
url = "$RelayUrl"

[llama]
binary = "$llamaPath"
model = "$modelToml"
gpu_layers = $GpuLayers
context_size = $ContextSize
port = 11436
extra_args = ["--threads", "$threads"]

[node]
display_name = "$DisplayName"
gpu_backend = "$LlamaBuild"
"@

Set-Content -Path $ConfigFile -Value $tomlContent -Encoding UTF8
Write-Host "Config written to $ConfigFile"

# --- Install or update Windows Service via NSSM ---
$existingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue

if ($existingService) {
    Write-Host "Service already exists, stopping for update..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    # Update the executable path (in case of upgrade)
    & $NssmExe set $ServiceName Application $TealeExe
    & $NssmExe set $ServiceName AppParameters "--config `"$ConfigFile`""
} else {
    Write-Host "Installing TealeNode service..."
    & $NssmExe install $ServiceName $TealeExe
    & $NssmExe set $ServiceName AppParameters "--config `"$ConfigFile`""
}

# Configure service properties
& $NssmExe set $ServiceName AppDirectory $InstallDir
& $NssmExe set $ServiceName DisplayName "Teale Node"
& $NssmExe set $ServiceName Description "TealeNet inference supply node"

# Logging
$stdoutLog = Join-Path $LogDir "teale-node-stdout.log"
$stderrLog = Join-Path $LogDir "teale-node-stderr.log"
& $NssmExe set $ServiceName AppStdout $stdoutLog
& $NssmExe set $ServiceName AppStderr $stderrLog
& $NssmExe set $ServiceName AppRotateFiles 1
& $NssmExe set $ServiceName AppRotateBytes 10485760

# Restart on failure (5s delay)
& $NssmExe set $ServiceName AppRestartDelay 5000

# Auto-start on boot
& $NssmExe set $ServiceName Start SERVICE_AUTO_START

# Set APPDATA so identity key lands under C:\Teale\data instead of system profile
& $NssmExe set $ServiceName AppEnvironmentExtra "APPDATA=$DataDir"

# Run at Below Normal priority — contributor's own apps always win the CPU.
& $NssmExe set $ServiceName AppPriority BELOW_NORMAL_PRIORITY_CLASS

# --- Power configuration for lid-closed supply (AC only) ---
if ($AllowSupplyLidClosed) {
    Write-Host "Configuring Windows power plan for lid-closed supply on AC..."
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    # GUID: 4f971e89 = "Power buttons and lid", 5ca83367 = "Lid close action"
    powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
    powercfg /setactive SCHEME_CURRENT
    Write-Host "Power plan: machine stays awake on AC even with lid closed. Screen can still turn off."
}

# --- Start the service ---
Write-Host ""
Write-Host "Starting TealeNode service..."
Start-Service -Name $ServiceName
Start-Sleep -Seconds 5

# --- Verify ---
$svc = Get-Service -Name $ServiceName
if ($svc.Status -eq "Running") {
    Write-Host ""
    Write-Host "=== TealeNode deployed successfully ===" -ForegroundColor Green
    Write-Host "  Service status: Running"
    Write-Host "  Display name:   $DisplayName"
    Write-Host "  Config:         $ConfigFile"
    Write-Host "  Logs:           $LogDir"
    Write-Host "  Identity key:   $DataDir\Teale\wan-identity.key"
    Write-Host ""
    Write-Host "Check logs:  Get-Content $stdoutLog -Tail 20"
    Write-Host "Stop:        Stop-Service $ServiceName"
    Write-Host "Uninstall:   .\deploy-windows.ps1 -Uninstall"
} else {
    Write-Host ""
    Write-Host "=== WARNING: Service not running ===" -ForegroundColor Red
    Write-Host "  Status: $($svc.Status)"
    Write-Host "  Check logs: Get-Content $stderrLog -Tail 50"
    exit 1
}

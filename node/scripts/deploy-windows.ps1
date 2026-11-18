#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys teale-node as a Windows Service for TealeNet supply node operation.

.DESCRIPTION
    Fully provisions a Windows machine as a TealeNet supply node:
    - Downloads llama-server from llama.cpp releases (auto-selecting Vulkan on
      newer integrated GPUs, CPU on older Intel laptops)
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

    # Expected SHA-256 of the GGUF (hex). Defaults to the pinned hash of the
    # default Hermes-3 URL; pass it for any other -ModelUrl / -ModelSharePath.
    [string]$ModelSha256 = "",

    # llama.cpp release tag for downloading llama-server. Defaults to the repo
    # pin in .github/llama-cpp-version (b8840 when that file is not around).
    [string]$LlamaRelease = "",

    # llama-server build variant: "vulkan" or "cpu". If omitted, the script
    # auto-selects CPU for older Intel laptops even when a Vulkan runtime is installed.
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
$DefaultModelUrl = "https://huggingface.co/NousResearch/Hermes-3-Llama-3.1-8B-GGUF/resolve/main/Hermes-3-Llama-3.1-8B.Q5_K_M.gguf"
# Hugging Face LFS object id (= SHA-256) of the default model.
$DefaultModelSha256 = "b2fb813afad50963f29a9e69cd844a02add63d6a29f965fef4e084fdd10075d3"
# SHA-256 of llama.cpp release zips, from the GitHub release asset digests.
$PinnedLlamaZipSha256 = @{
    "llama-b8840-bin-win-vulkan-x64.zip" = "2981b327976fd96e7116ea63a69364c4e34b60c9403990a48d8c00e9625c7634"
    "llama-b8840-bin-win-cpu-x64.zip"    = "29f020e87cef66f978f19d72ab9306edad19237a85f02bcc53555196c4ee5baa"
}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-LlamaReleasePin {
    $pinFile = Join-Path $PSScriptRoot "..\..\.github\llama-cpp-version"
    if (Test-Path $pinFile) {
        $value = (Get-Content -Path $pinFile -Raw).Trim()
        if ($value -match '^b\d+$') { return $value }
    }
    return "b8840"
}

function Assert-FileSha256 {
    param([string]$Path, [string]$Expected, [string]$What)
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected.ToLowerInvariant()) {
        Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
        throw "$What failed SHA-256 verification (expected $Expected, got $actual); file deleted."
    }
    Write-Host "  SHA-256 verified for $What"
}

# Expected SHA-256 of a llama.cpp release asset: pinned for the repo's
# release, otherwise the digest GitHub publishes for the asset.
function Get-LlamaZipSha256 {
    param([string]$Release, [string]$AssetName)
    if ($PinnedLlamaZipSha256.ContainsKey($AssetName)) { return $PinnedLlamaZipSha256[$AssetName] }
    try {
        $info = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$Release" -UseBasicParsing -TimeoutSec 30
        $asset = $info.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
        if ($asset -and $asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { return $Matches[1] }
    } catch {
        Write-Warning "Could not read the published digest for ${AssetName}: $($_.Exception.Message)"
    }
    return $null
}

# Same hardening as the installer's post-install.ps1: SYSTEM + Administrators
# full control, Users read/execute, data\ (identity key, account session)
# SYSTEM + Administrators only.
function Set-TealeInstallAcl {
    param([string]$Root, [string]$DataDir)
    $system = "*S-1-5-18"; $admins = "*S-1-5-32-544"; $users = "*S-1-5-32-545"
    & icacls.exe $Root /inheritance:r /grant:r "${system}:(OI)(CI)F" "${admins}:(OI)(CI)F" "${users}:(OI)(CI)RX" /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Root" }
    & icacls.exe "$Root\*" /reset /T /C /Q | Out-Null
    & icacls.exe $DataDir /inheritance:r /grant:r "${system}:(OI)(CI)F" "${admins}:(OI)(CI)F" /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $DataDir" }
    & icacls.exe "$DataDir\*" /reset /T /C /Q | Out-Null
}

function Get-PowerAcIndex {
    param([string]$Scheme, [string]$SubGroup, [string]$Setting)
    $text = (& powercfg.exe /query $Scheme $SubGroup $Setting) -join "`n"
    $values = [regex]::Matches($text, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value }
    if ($values.Count -lt 2) { return $null }
    return [Convert]::ToUInt32($values[$values.Count - 2].Substring(2), 16)
}

# Record the AC sleep/hibernate/lid values once, before changing them.
function Save-PowerSettings {
    param([string]$BackupPath)
    if (Test-Path $BackupPath) { return }
    $schemeLine = (& powercfg.exe /getactivescheme) -join " "
    $match = [regex]::Match($schemeLine, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw "could not read the active power scheme" }
    $scheme = $match.Value
    $lines = @("scheme=$scheme")
    foreach ($pair in @(@("SUB_SLEEP", "STANDBYIDLE"), @("SUB_SLEEP", "HIBERNATEIDLE"), @("SUB_BUTTONS", "LIDACTION"))) {
        $value = Get-PowerAcIndex $scheme $pair[0] $pair[1]
        if ($null -ne $value) { $lines += "$($pair[0]) $($pair[1])=$value" }
    }
    Set-Content -Path $BackupPath -Value $lines -Encoding ASCII
}

function Restore-PowerSettings {
    param([string]$BackupPath)
    if (-not (Test-Path $BackupPath)) { return }
    $scheme = $null
    foreach ($line in Get-Content -Path $BackupPath) {
        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) { continue }
        if ($parts[0] -eq "scheme") { $scheme = $parts[1].Trim(); continue }
        if (-not $scheme) { continue }
        $names = $parts[0].Trim().Split(" ")
        if ($names.Count -ne 2) { continue }
        & powercfg.exe /setacvalueindex $scheme $names[0] $names[1] $parts[1].Trim()
    }
    $active = (& powercfg.exe /getactivescheme) -join " "
    if ($scheme -and ($active -match [regex]::Escape($scheme))) { & powercfg.exe /setactive $scheme }
    Remove-Item -Path $BackupPath -Force -ErrorAction SilentlyContinue
    Write-Host "Restored the power settings recorded before lid-closed supply was enabled."
}

function Test-TealePrefersVulkan {
    param(
        [string]$CpuName
    )

    if ($null -eq $CpuName) {
        $CpuName = ""
    }
    $lower = $CpuName.ToLowerInvariant()
    if ($lower.Contains("intel")) {
        if ((($lower.Contains("core")) -and ($lower.Contains("ultra"))) -or $lower.Contains("iris xe") -or $lower.Contains("arc")) {
            return $true
        }

        $match = [regex]::Match($lower, 'i[3579]-([0-9]{4,5})')
        if ($match.Success) {
            $digits = $match.Groups[1].Value
            if ($digits.Length -ge 5) {
                return [int]$digits.Substring(0, 2) -ge 11
            }
            if ($digits.Length -eq 4) {
                $firstTwo = [int]$digits.Substring(0, 2)
                if ($firstTwo -ge 10 -and $firstTwo -le 29) {
                    return $firstTwo -ge 11
                }
                return $false
            }
        }
        return $false
    }

    if ($lower.Contains("amd")) {
        return $true
    }

    return $true
}

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
$PowerBackupPath = Join-Path $ConfigDir "powercfg-backup.txt"

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

    Restore-PowerSettings -BackupPath $PowerBackupPath

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

if (-not $LlamaRelease) {
    $LlamaRelease = Get-LlamaReleasePin
}
if (-not $ModelSha256 -and $ModelSharePath -eq "" -and $ModelUrl -eq $DefaultModelUrl) {
    $ModelSha256 = $DefaultModelSha256
}

# RAM gate — pilot minimum is 16 GB. Bypass with -SkipRamGate for dev.
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1073741824, 1)
if (-not $SkipRamGate -and $ramGB -lt 16) {
    Write-Error "This machine has $ramGB GB RAM. Pilot minimum is 16 GB. Use -SkipRamGate to override (not recommended)."
    exit 1
}

$cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
if (-not $PSBoundParameters.ContainsKey('LlamaBuild')) {
    $vulkanDll = Join-Path $env:SystemRoot "System32\vulkan-1.dll"
    if ((Test-Path $vulkanDll) -and (Test-TealePrefersVulkan -CpuName $cpuName)) {
        $LlamaBuild = "vulkan"
    } else {
        $LlamaBuild = "cpu"
    }
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
Write-Host "  CPU:          $cpuName"
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

    # nssm.cc publishes no checksums, so this download cannot be hash-pinned;
    # stage nssm.exe yourself (or from a trusted share) on locked-down fleets.
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile $nssmZip -UseBasicParsing
    Expand-Archive -Path $nssmZip -DestinationPath $env:TEMP -Force
    $nssmSrc = Join-Path $nssmExtract "win64\nssm.exe"
    Copy-Item -Path $nssmSrc -Destination $NssmExe -Force
    if ((Get-Item $NssmExe).Length -lt 100000) {
        throw "downloaded nssm.exe looks truncated"
    }

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
    $llamaAsset = "llama-$LlamaRelease-bin-win-$LlamaBuild-x64.zip"
    $llamaUrl = "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaRelease/llama-$LlamaRelease-bin-win-$LlamaBuild-x64.zip"

    Invoke-WebRequest -Uri $llamaUrl -OutFile $llamaZip -UseBasicParsing
    $llamaSha256 = Get-LlamaZipSha256 -Release $LlamaRelease -AssetName $llamaAsset
    if ($llamaSha256) {
        Assert-FileSha256 -Path $llamaZip -Expected $llamaSha256 -What $llamaAsset
    } else {
        throw "No SHA-256 is known for $llamaAsset; refusing to install an unverified llama-server."
    }
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
    if ($ModelSha256) {
        Assert-FileSha256 -Path $ModelPath -Expected $ModelSha256 -What $ModelFilename
    } else {
        Write-Warning "No -ModelSha256 given; $ModelFilename was not integrity-checked."
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
$registryPath = (Join-Path $ConfigDir "model-registry.json").Replace('\', '/')

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

[control]
port = 11437
registry_path = "$registryPath"

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

# Stop = Ctrl+C, then up to 35 s for the node to drain in-flight requests
# (shutdown_timeout_seconds = 30) before NSSM escalates (default 1.5 s).
& $NssmExe set $ServiceName AppStopMethodConsole 35000
& $NssmExe set $ServiceName AppStopMethodWindow 5000
& $NssmExe set $ServiceName AppStopMethodThreads 5000
& $NssmExe set $ServiceName AppKillProcessTree 1

# Lock down C:\Teale (no user-writable binaries run as LocalSystem; the
# identity key is readable by SYSTEM/Administrators only).
Set-TealeInstallAcl -Root $InstallDir -DataDir $DataDir

# --- Power configuration for lid-closed supply (AC only) ---
if ($AllowSupplyLidClosed) {
    Write-Host "Configuring Windows power plan for lid-closed supply on AC..."
    Save-PowerSettings -BackupPath $PowerBackupPath
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

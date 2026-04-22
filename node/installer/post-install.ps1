# TealeNode post-install script — run by the Inno Setup installer after file
# extraction. Generates config, installs and starts the Windows service, then
# lets the Teale companion app drive runtime model download/load management.
# Also applies power-configuration (powercfg) when the user opted into
# lid-closed supply on the installer wizard.

param(
    [string]$InstallDir = "C:\Teale",
    # When "1", allow supply while lid is closed on AC power. Set by the
    # installer wizard's Behavior page. Default off for conservative opt-in.
    [string]$AllowSupplyLidClosed = "1",
    # Optional installer-provided backup directory used when an older Teale
    # install is removed before upgrading. Models are restored from here.
    [string]$PreservedModelsDir = "",
    # Optional test-only override to make Teale behave like a lower-RAM
    # machine for recommendation and compatibility gating.
    [string]$AssumedRamGB = ""
)

$ErrorActionPreference = "Stop"
$ServiceName = "TealeNode"

# --- Paths ---
$BinDir    = Join-Path $InstallDir "bin"
$ModelDir  = Join-Path $InstallDir "models"
$ConfigDir = Join-Path $InstallDir "config"
$LogDir    = Join-Path $InstallDir "logs"
$DataDir   = Join-Path $InstallDir "data"

$NssmExe    = Join-Path $BinDir "nssm.exe"
$LlamaExe   = Join-Path $BinDir "llama-server.exe"
$TealeExe   = Join-Path $BinDir "teale-node.exe"
$ConfigFile = Join-Path $ConfigDir "teale-node.toml"
$TranscriptPath = Join-Path $LogDir "post-install.log"

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        $exitCode = 0
    }

    if ($exitCode -ne 0) {
        $renderedArgs = if ($Arguments) { $Arguments -join " " } else { "" }
        throw "Command failed with exit code $exitCode: $FilePath $renderedArgs"
    }
}

# --- Create directories ---
foreach ($dir in @($ModelDir, $ConfigDir, $LogDir, $DataDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Start-Transcript -Path $TranscriptPath -Force | Out-Null

if ($PreservedModelsDir -and (Test-Path $PreservedModelsDir)) {
    Write-Host "Restoring preserved models from $PreservedModelsDir"
    New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
    Get-ChildItem -LiteralPath $PreservedModelsDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
        Move-Item -LiteralPath $_.FullName -Destination $ModelDir -Force
    }
    Remove-Item -LiteralPath $PreservedModelsDir -Force -Recurse -ErrorAction SilentlyContinue
}

# --- RAM gate: pilot is 16 GB+ only ---
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1073741824, 1)
if ($ramGB -lt 16) {
    # Unsupported — show a friendly message and bail cleanly. The installer
    # already extracted files, but the service won't be installed so they
    # can safely uninstall via Add/Remove Programs.
    $msg = "Teale needs 16 GB of RAM or more. This machine has $ramGB GB.`n`n" + `
           "We are working on support for smaller devices and will let you know when it's ready. " + `
           "You can uninstall Teale from Settings > Apps for now."
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show($msg, "Teale — Unsupported RAM", "OK", "Information") | Out-Null
    Write-Host "RAM check failed: $ramGB GB < 16 GB minimum. Exiting without installing service."
    exit 0
}

# --- Detect Vulkan runtime (deploy-windows.ps1 already downloads the
#     Vulkan llama-server build; this check just confirms the Vulkan loader
#     is present on the system so we can set gpu_backend accordingly) ---
$vulkanDll = "$env:SystemRoot\System32\vulkan-1.dll"
if (Test-Path $vulkanDll) {
    $gpuBackend = "vulkan"
    $gpuLayers = 999
    Write-Host "Vulkan runtime detected. GPU offload enabled."
} else {
    $gpuBackend = "cpu"
    $gpuLayers = 0
    Write-Host "No Vulkan runtime found. Falling back to CPU-only inference."
}

# --- Generate config ---
$logicalCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$threads = [math]::Max(2, $logicalCores - 2)
$appEnvironment = @("APPDATA=$DataDir")

if ($AssumedRamGB) {
    [double]$parsedAssumedRam = 0
    $parsedOk = [double]::TryParse(
        $AssumedRamGB,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsedAssumedRam
    )

    if ($parsedOk -and $parsedAssumedRam -gt 0) {
        $appEnvironment += "TEALE_TOTAL_RAM_GB=$parsedAssumedRam"
        Write-Host "Using test RAM override for Teale: $parsedAssumedRam GB"
    } else {
        Write-Warning "Ignoring invalid -AssumedRamGB value '$AssumedRamGB'"
    }
}

$llamaPath = $LlamaExe.Replace('\', '/')
$tomlContent = @"
# teale-node configuration -- auto-generated by TealeNode installer
# Machine: $env:COMPUTERNAME | RAM: $ramGB GB | Cores: $logicalCores | GPU: $gpuBackend

[relay]
url = "wss://relay.teale.com/ws"

[llama]
binary = "$llamaPath"
model = ""
gpu_layers = $gpuLayers
context_size = 8192
port = 11436
extra_args = ["--threads", "$threads"]

[control]
port = 11437
registry_path = "C:/Teale/config/model-registry.json"

[node]
display_name = "$env:COMPUTERNAME"
gpu_backend = "$gpuBackend"
"@

Set-Content -Path $ConfigFile -Value $tomlContent -Encoding UTF8
Write-Host "Config written to $ConfigFile"
Write-Host "No model is downloaded during install. Teale Companion will recommend and download one after setup."

# --- Apply power configuration if user opted into lid-closed supply ---
if ($AllowSupplyLidClosed -eq "1") {
    Write-Host "Configuring Windows power plan for lid-closed supply on AC..."
    # Never sleep on AC. Hibernation also disabled on AC.
    powercfg /change standby-timeout-ac 0
    powercfg /change hibernate-timeout-ac 0
    # Lid close action on AC = 0 (Do Nothing). The GUID below is the
    # well-known "lid close action" power setting.
    # Source: https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/power-button-and-lid-settings
    powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
    powercfg /setactive SCHEME_CURRENT
    Write-Host "Power plan: machine stays awake on AC even with lid closed. Screen can still turn off."
} else {
    Write-Host "Lid-closed supply NOT enabled (user did not opt in). Default sleep behavior preserved."
}

# --- Stop existing service if upgrading ---
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Invoke-Checked $NssmExe remove $ServiceName confirm
}

# --- Install service via NSSM ---
if (-not (Test-Path $NssmExe)) {
    throw "nssm.exe not found at $NssmExe"
}

Invoke-Checked $NssmExe install $ServiceName $TealeExe
Invoke-Checked $NssmExe set $ServiceName AppParameters "--config `"$ConfigFile`""
Invoke-Checked $NssmExe set $ServiceName AppDirectory $InstallDir
Invoke-Checked $NssmExe set $ServiceName DisplayName "Teale Node"
Invoke-Checked $NssmExe set $ServiceName Description "TealeNet inference supply node"

$stdoutLog = Join-Path $LogDir "teale-node-stdout.log"
$stderrLog = Join-Path $LogDir "teale-node-stderr.log"
Invoke-Checked $NssmExe set $ServiceName AppStdout $stdoutLog
Invoke-Checked $NssmExe set $ServiceName AppStderr $stderrLog
Invoke-Checked $NssmExe set $ServiceName AppRotateFiles 1
Invoke-Checked $NssmExe set $ServiceName AppRotateBytes 10485760
Invoke-Checked $NssmExe set $ServiceName AppRestartDelay 5000
Invoke-Checked $NssmExe set $ServiceName Start SERVICE_AUTO_START
Invoke-Checked $NssmExe set $ServiceName AppEnvironmentExtra ($appEnvironment -join "`n")
# Run at Below Normal priority so contributor's foreground apps are never
# starved. Teale is a good citizen — user's own work always wins the CPU.
Invoke-Checked $NssmExe set $ServiceName AppPriority BELOW_NORMAL_PRIORITY_CLASS

# --- Start the service ---
Start-Service -Name $ServiceName

Write-Host "TealeNode service installed and started."
Stop-Transcript | Out-Null

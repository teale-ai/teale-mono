# TealeNode post-install script - run by the Inno Setup installer after file
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
    # Optional Private Inference Network join code for IT mass deployment.
    # When set, the node auto-submits a join request on first start and the
    # PIN admin batch-approves from the app or CLI. Also honors the
    # TEALE_PIN_JOIN_CODE environment variable.
    [string]$PinJoinCode = ""
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
$TranscriptCapturePath = Join-Path $LogDir "post-install-transcript.log"
$PowerBackupPath = Join-Path $ConfigDir "powercfg-backup.txt"
$TranscriptStarted = $false

function Write-InstallLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $timestamp = [DateTime]::UtcNow.ToString("o")
    Add-Content -Path $TranscriptPath -Value "[$timestamp] $Message"
}

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
        throw ("Command failed with exit code {0}: {1} {2}" -f $exitCode, $FilePath, $renderedArgs)
    }
}

# Well-known SIDs (locale-independent, unlike "Administrators"/"Users").
$SidSystem = "*S-1-5-18"
$SidAdmins = "*S-1-5-32-544"
$SidUsers  = "*S-1-5-32-545"

function Invoke-Icacls {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    & icacls.exe @Arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("icacls failed with exit code {0}: {1}" -f $LASTEXITCODE, ($Arguments -join " "))
    }
}

# Lock down the install tree. C:\ grants Authenticated Users "Modify" by
# inheritance, which would let any local user replace binaries or scripts that
# run as LocalSystem (the service) or copy the node identity key. Result:
#   C:\Teale\**       SYSTEM + Administrators full control, Users read/execute
#   C:\Teale\data\**  SYSTEM + Administrators only (identity key, account session)
function Set-TealeInstallAcl {
    param([string]$Root, [string]$DataDir)

    Invoke-Icacls $Root /inheritance:r /grant:r "${SidSystem}:(OI)(CI)F" "${SidAdmins}:(OI)(CI)F" "${SidUsers}:(OI)(CI)RX" /C /Q
    # Make everything below inherit exactly that (drops explicit ACEs).
    Invoke-Icacls "$Root\*" /reset /T /C /Q
    if (-not (Test-Path $DataDir)) {
        New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    }
    Invoke-Icacls $DataDir /inheritance:r /grant:r "${SidSystem}:(OI)(CI)F" "${SidAdmins}:(OI)(CI)F" /C /Q
    Invoke-Icacls "$DataDir\*" /reset /T /C /Q
}

# powercfg value index (seconds / enum) of one setting on the AC side. The
# query output is localized, so take the hex values: the last two are the
# current AC and DC indexes.
function Get-PowerAcIndex {
    param([string]$Scheme, [string]$SubGroup, [string]$Setting)
    $text = (& powercfg.exe /query $Scheme $SubGroup $Setting) -join "`n"
    $values = [regex]::Matches($text, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value }
    if ($values.Count -lt 2) { return $null }
    return [Convert]::ToUInt32($values[$values.Count - 2].Substring(2), 16)
}

# Record the AC sleep/hibernate/lid values before Teale changes them, so the
# uninstaller can put them back. Never overwrites an existing backup (a
# reinstall must not record Teale's own zeros as "original").
function Save-PowerSettings {
    param([string]$BackupPath)
    if (Test-Path $BackupPath) { return }
    $schemeLine = (& powercfg.exe /getactivescheme) -join " "
    $match = [regex]::Match($schemeLine, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if (-not $match.Success) { throw "could not read the active power scheme" }
    $scheme = $match.Value
    $standby = Get-PowerAcIndex $scheme SUB_SLEEP STANDBYIDLE
    $hibernate = Get-PowerAcIndex $scheme SUB_SLEEP HIBERNATEIDLE
    $lid = Get-PowerAcIndex $scheme SUB_BUTTONS LIDACTION
    $lines = @("scheme=$scheme")
    if ($null -ne $standby) { $lines += "SUB_SLEEP STANDBYIDLE=$standby" }
    if ($null -ne $hibernate) { $lines += "SUB_SLEEP HIBERNATEIDLE=$hibernate" }
    if ($null -ne $lid) { $lines += "SUB_BUTTONS LIDACTION=$lid" }
    Set-Content -Path $BackupPath -Value $lines -Encoding ASCII
}

# Register the on-logon update check for every interactive user, unelevated.
function Register-TealeUpdateTask {
    param([string]$InstallDir)
    $script = Join-Path $InstallDir "check-update.ps1"
    $action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName "TealeUpdateCheck" -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
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
                return [int]$digits.Substring(0, 1) -ge 11
            }
        }
        return $false
    }

    if ($lower.Contains("amd")) {
        return $true
    }

    return $true
}

# --- Create directories ---
foreach ($dir in @($ModelDir, $ConfigDir, $LogDir, $DataDir)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

Write-InstallLog "post-install.ps1 starting"

try {
    try {
        Start-Transcript -Path $TranscriptCapturePath -Append -ErrorAction Stop | Out-Null
        $TranscriptStarted = $true
    } catch {
        Write-InstallLog "Start-Transcript failed: $($_.Exception.Message)"
    }

    if ($PreservedModelsDir -and (Test-Path $PreservedModelsDir)) {
        Write-InstallLog "Restoring preserved models from $PreservedModelsDir"
        New-Item -ItemType Directory -Path $ModelDir -Force | Out-Null
        Get-ChildItem -LiteralPath $PreservedModelsDir -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Move-Item -LiteralPath $_.FullName -Destination $ModelDir -Force
        }
        Remove-Item -LiteralPath $PreservedModelsDir -Force -Recurse -ErrorAction SilentlyContinue
    }

    # After the model restore, so moved-in files pick up the hardened ACL.
    Write-InstallLog "Hardening install directory permissions."
    Set-TealeInstallAcl -Root $InstallDir -DataDir $DataDir

    # --- RAM gate: pilot is 16 GB+ only ---
    $ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1073741824, 1)
    if ($ramGB -lt 16) {
        $msg = "Teale needs 16 GB of RAM or more. This machine has $ramGB GB.`n`n" + `
               "We are working on support for smaller devices and will let you know when it's ready. " + `
               "You can uninstall Teale from Settings > Apps for now."
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($msg, "Teale - Unsupported RAM", "OK", "Information") | Out-Null
        Write-InstallLog "RAM check failed: $ramGB GB < 16 GB minimum. Exiting without installing service."
        return
    }

    $cpuName = (Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)
    $vulkanDll = "$env:SystemRoot\System32\vulkan-1.dll"
    if ((Test-Path $vulkanDll) -and (Test-TealePrefersVulkan -CpuName $cpuName)) {
        $gpuBackend = "vulkan"
        $gpuLayers = 999
        Write-InstallLog "Vulkan backend selected for CPU: $cpuName"
    } else {
        $gpuBackend = "cpu"
        $gpuLayers = 0
        Write-InstallLog "CPU backend selected for CPU: $cpuName"
    }

    $logicalCores = (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    $threads = [math]::Max(2, $logicalCores - 2)
    $appEnvironment = @("APPDATA=$DataDir")

    $llamaPath = $LlamaExe.Replace('\', '/')
    $registryPath = (Join-Path $ConfigDir "model-registry.json").Replace('\', '/')
    $effectivePinCode = if ($PinJoinCode) { $PinJoinCode } elseif ($env:TEALE_PIN_JOIN_CODE) { $env:TEALE_PIN_JOIN_CODE } else { "" }
    $pinSection = if ($effectivePinCode) {
        "`n[pin]`njoin_code = `"$effectivePinCode`"`nport = 41642"
    } else { "" }
    if ($effectivePinCode) {
        Write-InstallLog "Private network join preseeded (code ends ...$($effectivePinCode.Substring([math]::Max(0, $effectivePinCode.Length - 2))))."
    }
    # Relay display name: neutral alias, not the machine hostname (#252).
    # Stable per machine so operators can tell their own nodes apart without
    # leaking hostnames, model labels, or inventory detail to the global relay.
    # (MD5-derived: string GetHashCode() is process-randomized on .NET Core.)
    $nodeHash = [BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($env:COMPUTERNAME))).Replace("-", "").Substring(0, 4).ToLower()
    $nodeAlias = "teale-" + $nodeHash
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
registry_path = "$registryPath"

[node]
display_name = "$nodeAlias"
gpu_backend = "$gpuBackend"
$pinSection
"@

    Set-Content -Path $ConfigFile -Value $tomlContent -Encoding UTF8
    Write-InstallLog "Config written to $ConfigFile"

    if ($AllowSupplyLidClosed -eq "1") {
        Write-InstallLog "Configuring Windows power plan for lid-closed supply on AC."
        try {
            Save-PowerSettings -BackupPath $PowerBackupPath
            Write-InstallLog "Previous power settings recorded in $PowerBackupPath."
        } catch {
            Write-InstallLog "Could not record previous power settings: $($_.Exception.Message)"
        }
        powercfg /change standby-timeout-ac 0
        powercfg /change hibernate-timeout-ac 0
        powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
        powercfg /setactive SCHEME_CURRENT
    } else {
        Write-InstallLog "Lid-closed supply not enabled."
    }

    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        Write-InstallLog "Removing existing service definition."
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Invoke-Checked $NssmExe remove $ServiceName confirm
    }

    if (-not (Test-Path $NssmExe)) {
        throw "nssm.exe not found at $NssmExe"
    }

    Write-InstallLog "Installing service via NSSM."
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
    Invoke-Checked $NssmExe set $ServiceName AppPriority BELOW_NORMAL_PRIORITY_CLASS
    # Stop = Ctrl+C to the node's console, then wait up to 35 s so it can
    # drain in-flight requests (shutdown_timeout_seconds = 30) before NSSM
    # escalates. NSSM's default is 1.5 s, which killed requests mid-stream.
    Invoke-Checked $NssmExe set $ServiceName AppStopMethodConsole 35000
    Invoke-Checked $NssmExe set $ServiceName AppStopMethodWindow 5000
    Invoke-Checked $NssmExe set $ServiceName AppStopMethodThreads 5000
    Invoke-Checked $NssmExe set $ServiceName AppKillProcessTree 1

    try {
        Register-TealeUpdateTask -InstallDir $InstallDir
        Write-InstallLog "Registered TealeUpdateCheck for every user logon."
    } catch {
        Write-InstallLog "Could not register the update-check task: $($_.Exception.Message)"
    }

    Write-InstallLog "Starting TealeNode service."
    Start-Service -Name $ServiceName
    Write-InstallLog "TealeNode service installed and started."
} catch {
    Write-InstallLog "ERROR: $($_.Exception.Message)"
    throw
} finally {
    if ($TranscriptStarted) {
        Stop-Transcript | Out-Null
    }
}

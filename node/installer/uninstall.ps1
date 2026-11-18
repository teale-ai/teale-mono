# TealeNode uninstall script - run by the Inno Setup uninstaller before file removal.

$ServiceName = "TealeNode"
$InstallDir = $PSScriptRoot
if (-not $InstallDir) { $InstallDir = "C:\Teale" }
$NssmExe = Join-Path $InstallDir "bin\nssm.exe"
$PowerBackupPath = Join-Path $InstallDir "config\powercfg-backup.txt"

# Stop the tray app if it's running (per-user process, not a service).
Get-Process -Name "teale-tray" -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.CloseMainWindow() | Out-Null } catch {}
    try { $_ | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
}

# Stop and remove the NSSM-wrapped service. Stop-Service lets NSSM deliver
# Ctrl+C and wait for the node's drain (AppStopMethodConsole).
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path $NssmExe) {
        & $NssmExe remove $ServiceName confirm
    } else {
        sc.exe delete $ServiceName
    }
}

# Put back the AC sleep / hibernate / lid-close settings recorded by
# post-install.ps1 before it enabled lid-closed supply.
if (Test-Path $PowerBackupPath) {
    $scheme = $null
    foreach ($line in Get-Content -Path $PowerBackupPath) {
        $parts = $line.Split("=", 2)
        if ($parts.Count -ne 2) { continue }
        if ($parts[0] -eq "scheme") {
            $scheme = $parts[1].Trim()
            continue
        }
        if (-not $scheme) { continue }
        $names = $parts[0].Trim().Split(" ")
        if ($names.Count -ne 2) { continue }
        & powercfg.exe /setacvalueindex $scheme $names[0] $names[1] $parts[1].Trim()
    }
    # Re-apply only if that scheme is still the active one.
    $active = (& powercfg.exe /getactivescheme) -join " "
    if ($scheme -and ($active -match [regex]::Escape($scheme))) {
        & powercfg.exe /setactive $scheme
    }
    Remove-Item -Path $PowerBackupPath -Force -ErrorAction SilentlyContinue
}

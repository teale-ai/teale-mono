# TealeNode uninstall script — run by the Inno Setup uninstaller before file removal.

$ServiceName = "TealeNode"
$NssmExe = "C:\Teale\bin\nssm.exe"

# Stop the tray app if it's running (per-user process, not a service).
Get-Process -Name "teale-tray" -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.CloseMainWindow() | Out-Null } catch {}
    try { $_ | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
}

# Stop and remove the NSSM-wrapped service.
if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path $NssmExe) {
        & $NssmExe remove $ServiceName confirm
    } else {
        sc.exe delete $ServiceName
    }
}

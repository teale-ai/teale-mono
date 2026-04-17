# TealeNode uninstall script — run by the Inno Setup uninstaller before file removal.

$ServiceName = "TealeNode"
$NssmExe = "C:\Teale\bin\nssm.exe"

if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path $NssmExe) {
        & $NssmExe remove $ServiceName confirm
    } else {
        sc.exe delete $ServiceName
    }
}

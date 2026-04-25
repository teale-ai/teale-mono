# Teale updater engine — runs from the scheduled task at login / in the
# background, and can also be triggered manually by the tray app.

param(
    [switch]$Quiet,
    [switch]$ForceDownload,
    [switch]$InstallDownloaded
)

$ErrorActionPreference = "Stop"

$InstallDir = "C:\Teale"
$VersionFile = Join-Path $InstallDir "version.txt"
$ConfigDir = Join-Path $InstallDir "config"
$SettingsFile = Join-Path $ConfigDir "updater-settings.json"
$StateFile = Join-Path $ConfigDir "updater-state.json"
$UpdatesDir = Join-Path $InstallDir "updates"
$TrayExe = Join-Path $InstallDir "bin\teale-tray.exe"
$Repo = "teale-ai/teale-mono"
$ReleasesApi = "https://api.github.com/repos/$Repo/releases?per_page=20"

function Get-UnixTimestamp {
    return [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Get-DefaultUpdaterSettings {
    return @{
        auto_download = $false
        auto_install_after_download = $false
    }
}

function Get-DefaultUpdaterState {
    return @{
        latest_tag = $null
        latest_release_url = $null
        downloaded_tag = $null
        downloaded_installer_path = $null
        status = "idle"
        last_error = $null
        last_checked_at = $null
        last_downloaded_at = $null
        last_installed_at = $null
    }
}

function Ensure-ParentDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$DefaultValue
    )

    if (-not (Test-Path $Path)) {
        return $DefaultValue.Clone()
    }

    try {
        $raw = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $DefaultValue.Clone()
    }

    $result = $DefaultValue.Clone()
    foreach ($key in @($result.Keys)) {
        if ($null -ne $raw.$key) {
            $result[$key] = $raw.$key
        }
    }
    return $result
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$Value
    )

    Ensure-ParentDirectory -Path $Path
    $payload = [PSCustomObject]$Value | ConvertTo-Json -Depth 8
    Set-Content -Path $Path -Value $payload -Encoding UTF8
}

function Get-NormalizedVersionNumber($value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    $normalized = [string]$value
    $normalized = $normalized -replace '^teale-', ''
    $normalized = $normalized -replace '^v', ''
    $normalized = $normalized -replace '\.', ''
    if ($normalized -notmatch '^\d+$') { return $null }
    return [int64]$normalized
}

function Get-LatestWindowsRelease($releases) {
    $latestRelease = $null
    $latestVersion = $null

    foreach ($release in $releases) {
        if ($release.draft -or $release.prerelease) { continue }

        $tag = [string]$release.tag_name
        if (-not $tag.StartsWith("teale-")) { continue }

        $asset = $release.assets | Where-Object { $_.name -eq "Teale.exe" } | Select-Object -First 1
        if ($null -eq $asset) { continue }

        $version = Get-NormalizedVersionNumber $tag
        if ($null -eq $version) { continue }

        if ($null -eq $latestVersion -or $version -gt $latestVersion) {
            $latestRelease = $release
            $latestVersion = $version
        }
    }

    return $latestRelease
}

function Show-TealeToast {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    if ($Quiet) { return }

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

        $template = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$Title</text>
      <text>$Body</text>
    </binding>
  </visual>
</toast>
"@
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Teale").Show($toast)
    } catch {
        # Toasts are best-effort only.
    }
}

function Test-IsSystemAccount {
    try {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq "S-1-5-18"
    } catch {
        return $false
    }
}

function Remove-StaleInstallerFiles {
    param(
        [string]$KeepPath
    )

    if (-not (Test-Path $UpdatesDir)) {
        return
    }

    Get-ChildItem -Path $UpdatesDir -Filter "Teale-*.exe" -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($KeepPath -and $_.FullName -eq $KeepPath) {
            return
        }
        Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Download-UpdateInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssetUrl,
        [Parameter(Mandatory = $true)]
        [string]$Tag
    )

    if (-not (Test-Path $UpdatesDir)) {
        New-Item -ItemType Directory -Path $UpdatesDir -Force | Out-Null
    }

    $safeTag = $Tag -replace '[^A-Za-z0-9._-]', '_'
    $targetPath = Join-Path $UpdatesDir "Teale-$safeTag.exe"
    $tempPath = "$targetPath.part"

    if (Test-Path $targetPath) {
        Remove-StaleInstallerFiles -KeepPath $targetPath
        return $targetPath
    }

    try {
        Invoke-WebRequest -Uri $AssetUrl -OutFile $tempPath -UseBasicParsing -TimeoutSec 600
        Move-Item -Path $tempPath -Destination $targetPath -Force
        Remove-StaleInstallerFiles -KeepPath $targetPath
        return $targetPath
    } finally {
        if (Test-Path $tempPath) {
            Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-DownloadedUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$State
    )

    $installerPath = [string]$State.downloaded_installer_path
    if ([string]::IsNullOrWhiteSpace($installerPath) -or -not (Test-Path $installerPath)) {
        $State.downloaded_tag = $null
        $State.downloaded_installer_path = $null
        $State.status = "available"
        Write-JsonFile -Path $StateFile -Value $State
        return $false
    }

    $State.status = "installing"
    $State.last_error = $null
    Write-JsonFile -Path $StateFile -Value $State

    try {
        $process = Start-Process `
            -FilePath $installerPath `
            -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART" `
            -WindowStyle Hidden `
            -PassThru `
            -Wait

        if ($null -eq $process -or $process.ExitCode -ne 0) {
            $exitCode = if ($null -eq $process) { "unknown" } else { [string]$process.ExitCode }
            throw "Installer exited with code $exitCode."
        }

        if (Test-Path $installerPath) {
            Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
        }

        $State.downloaded_tag = $null
        $State.downloaded_installer_path = $null
        $State.status = "up_to_date"
        $State.last_error = $null
        $State.last_installed_at = Get-UnixTimestamp
        Remove-StaleInstallerFiles
        Write-JsonFile -Path $StateFile -Value $State

        if ((-not (Test-IsSystemAccount)) -and (Test-Path $TrayExe)) {
            Start-Process -FilePath $TrayExe | Out-Null
        }

        return $true
    } catch {
        $State.status = "error"
        $State.last_error = $_.Exception.Message
        Write-JsonFile -Path $StateFile -Value $State
        Show-TealeToast -Title "Teale update failed" -Body $State.last_error
        return $false
    }
}

if (-not (Test-Path $VersionFile)) { exit 0 }

$settings = Read-JsonFile -Path $SettingsFile -DefaultValue (Get-DefaultUpdaterSettings)
$state = Read-JsonFile -Path $StateFile -DefaultValue (Get-DefaultUpdaterState)

if ($InstallDownloaded -and $state.downloaded_installer_path) {
    if (Install-DownloadedUpdate -State $state) {
        exit 0
    }
}

$installed = (Get-Content $VersionFile -Raw).Trim()
if ($installed -eq "") { exit 0 }
$installedVersion = Get-NormalizedVersionNumber $installed
if ($null -eq $installedVersion) { exit 0 }

try {
    $releases = Invoke-RestMethod -Uri $ReleasesApi -UseBasicParsing -TimeoutSec 20
} catch {
    exit 0
}

$release = Get-LatestWindowsRelease $releases
if ($null -eq $release) { exit 0 }

$latestTag = [string]$release.tag_name
$latestVersion = Get-NormalizedVersionNumber $latestTag
if ($null -eq $latestVersion) { exit 0 }

$state.latest_tag = $latestTag
$state.latest_release_url = [string]$release.html_url
$state.last_checked_at = Get-UnixTimestamp
$state.last_error = $null

if ($latestVersion -le $installedVersion) {
    $state.status = "up_to_date"
    if ($state.downloaded_tag -eq $latestTag) {
        $state.downloaded_tag = $null
        $state.downloaded_installer_path = $null
    }
    Remove-StaleInstallerFiles
    Write-JsonFile -Path $StateFile -Value $state
    exit 0
}

$asset = $release.assets | Where-Object { $_.name -eq "Teale.exe" } | Select-Object -First 1
if ($null -eq $asset -or [string]::IsNullOrWhiteSpace($asset.browser_download_url)) {
    exit 0
}

$shouldDownload = $ForceDownload -or [bool]$settings.auto_download
if (-not $shouldDownload) {
    $state.status = "available"
    Write-JsonFile -Path $StateFile -Value $state
    Show-TealeToast -Title "Teale update available" -Body "Teale $latestTag is available for this PC."
    exit 0
}

try {
    $state.status = "downloading"
    Write-JsonFile -Path $StateFile -Value $state

    $installerPath = Download-UpdateInstaller -AssetUrl ([string]$asset.browser_download_url) -Tag $latestTag
    $state.downloaded_tag = $latestTag
    $state.downloaded_installer_path = $installerPath
    $state.last_downloaded_at = Get-UnixTimestamp
    $state.status = "downloaded"
    $state.last_error = $null
    Write-JsonFile -Path $StateFile -Value $state

    $shouldInstall = $InstallDownloaded -or [bool]$settings.auto_install_after_download
    if ($shouldInstall) {
        [void](Install-DownloadedUpdate -State $state)
        exit 0
    }

    Show-TealeToast -Title "Teale update ready" -Body "Teale $latestTag is downloaded and ready to install."
} catch {
    $state.status = "error"
    $state.last_error = $_.Exception.Message
    Write-JsonFile -Path $StateFile -Value $state
    Show-TealeToast -Title "Teale update failed" -Body $state.last_error
}

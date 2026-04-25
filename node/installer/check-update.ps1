# Teale update checker — runs on user login via Scheduled Task.
# Checks GitHub releases for a newer Windows installer and opens the download
# page if found.

$ErrorActionPreference = "SilentlyContinue"

$VersionFile = "C:\Teale\version.txt"
$Repo = "teale-ai/teale-mono"
$ReleasesApi = "https://api.github.com/repos/$Repo/releases?per_page=20"

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

# Read installed version
if (-not (Test-Path $VersionFile)) { exit 0 }
$installed = (Get-Content $VersionFile -Raw).Trim()
if ($installed -eq "") { exit 0 }
$installedVersion = Get-NormalizedVersionNumber $installed
if ($null -eq $installedVersion) { exit 0 }

# Check GitHub for latest Windows release
try {
    $releases = Invoke-RestMethod -Uri $ReleasesApi -UseBasicParsing -TimeoutSec 10
} catch {
    exit 0
}

$release = Get-LatestWindowsRelease $releases
if ($null -eq $release) { exit 0 }

$latest = [string]$release.tag_name
$latestVersion = Get-NormalizedVersionNumber $latest
if ($null -eq $latestVersion) { exit 0 }

if ($latestVersion -le $installedVersion) { exit 0 }

# Newer version available — find the Teale.exe asset URL or fall back to release page
$releaseUrl = $release.html_url
$assetUrl = ""
foreach ($asset in $release.assets) {
    if ($asset.name -eq "Teale.exe") {
        $assetUrl = $asset.browser_download_url
        break
    }
}

# Show a toast notification if possible, otherwise a simple message box
$title = "Teale Update Available"
$message = "A new version of Teale is available: $latest (you have $installed). Opening download page..."

try {
    # Windows 10/11 toast notification
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

    $template = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$title</text>
      <text>New Windows build $latest available (installed: $installed)</text>
    </binding>
  </visual>
</toast>
"@
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($template)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Teale").Show($toast)
} catch {
    # Fallback: no toast, just open the browser
}

# Open the download page
if ($assetUrl -ne "") {
    Start-Process $assetUrl
} else {
    Start-Process $releaseUrl
}

# TealeNode update checker — runs on user login via Scheduled Task.
# Checks GitHub releases for a newer version and opens the download page if found.

$ErrorActionPreference = "SilentlyContinue"

$VersionFile = "C:\Teale\version.txt"
$Repo = "teale-ai/teale-node"
$ReleasesApi = "https://api.github.com/repos/$Repo/releases/latest"

# Read installed version
if (-not (Test-Path $VersionFile)) { exit 0 }
$installed = (Get-Content $VersionFile -Raw).Trim()
if ($installed -eq "") { exit 0 }

# Check GitHub for latest release
try {
    $release = Invoke-RestMethod -Uri $ReleasesApi -UseBasicParsing -TimeoutSec 10
} catch {
    exit 0
}

$latest = $release.tag_name
if ($null -eq $latest -or $latest -eq "") { exit 0 }

# Normalize (strip leading "v" for comparison)
$installedClean = $installed -replace '^v', ''
$latestClean = $latest -replace '^v', ''

if ($installedClean -eq $latestClean) { exit 0 }

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
$title = "Teale Node Update Available"
$message = "A new version of Teale Node is available: $latest (you have $installed). Opening download page..."

try {
    # Windows 10/11 toast notification
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

    $template = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>$title</text>
      <text>New version $latest available (installed: $installed)</text>
    </binding>
  </visual>
</toast>
"@
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($template)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Teale Node").Show($toast)
} catch {
    # Fallback: no toast, just open the browser
}

# Open the download page
if ($assetUrl -ne "") {
    Start-Process $assetUrl
} else {
    Start-Process $releaseUrl
}

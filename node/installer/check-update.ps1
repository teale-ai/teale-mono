# Teale update checker — runs on user login via Scheduled Task.
# Checks GitHub releases for a newer Windows installer and offers a
# direct "Download and install update" action when one is available.

$ErrorActionPreference = "SilentlyContinue"

$VersionFile = "C:\Teale\version.txt"
$Repo = "teale-ai/teale-mono"
$ReleasesApi = "https://api.github.com/repos/$Repo/releases?per_page=20"

function Normalize-Version([string]$Value) {
    if ($null -eq $Value) { return "" }
    return (($Value -replace '^teale-v', '') -replace '^v', '').Trim()
}

function Escape-Xml([string]$Value) {
    if ($null -eq $Value) { return "" }
    return [System.Security.SecurityElement]::Escape($Value)
}

# Read installed version
if (-not (Test-Path $VersionFile)) { exit 0 }
$installed = (Get-Content $VersionFile -Raw).Trim()
if ($installed -eq "") { exit 0 }
$installedClean = Normalize-Version $installed

# Check GitHub for the newest Windows installer release
try {
    $releases = Invoke-RestMethod -Uri $ReleasesApi -UseBasicParsing -TimeoutSec 10
} catch {
    exit 0
}

$release = $releases |
    Where-Object {
        -not $_.draft -and
        -not $_.prerelease -and
        ($_.assets | Where-Object { $_.name -eq "Teale.exe" })
    } |
    Sort-Object { [DateTimeOffset]$_.published_at } -Descending |
    Select-Object -First 1

if ($null -eq $release) { exit 0 }
$latest = $release.tag_name
if ($null -eq $latest -or $latest -eq "") { exit 0 }
$latestClean = Normalize-Version $latest

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

$launchUrl = if ($assetUrl -ne "") { $assetUrl } else { $releaseUrl }

# Show a toast notification if possible, otherwise open the installer URL directly.
$title = "Teale Update Available"
$message = "Teale $latestClean is available (installed: $installedClean)."
$actionLabel = "Download and install update"

try {
    # Windows 10/11 toast notification
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

    $launchUrlXml = Escape-Xml $launchUrl
    $titleXml = Escape-Xml $title
    $messageXml = Escape-Xml $message
    $actionLabelXml = Escape-Xml $actionLabel

    $template = @"
<toast activationType="protocol" launch="$launchUrlXml">
  <visual>
    <binding template="ToastGeneric">
      <text>$titleXml</text>
      <text>$messageXml</text>
      <text>Click Download and install update to get the newest Windows build.</text>
    </binding>
  </visual>
  <actions>
    <action content="$actionLabelXml" activationType="protocol" arguments="$launchUrlXml" />
  </actions>
</toast>
"@
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($template)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Teale").Show($toast)
} catch {
    if ($launchUrl -ne "") {
        Start-Process $launchUrl
    }
}

# Teale update checker - runs unelevated at every user's logon (scheduled task
# TealeUpdateCheck, registered by post-install.ps1).
#
# Offers an update only when the newest published Windows release
# (tag teale-YYYY.MM.DD.HHMM with a Teale.exe asset) is strictly newer than
# the installed version. Before the downloaded installer is started, its
# SHA-256 must match the Teale.exe line of that release's checksums.txt;
# otherwise nothing is run and the release page is opened instead.

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$InstallDir = $PSScriptRoot
if (-not $InstallDir) { $InstallDir = "C:\Teale" }
$VersionFile = Join-Path $InstallDir "version.txt"
$Repo = "teale-ai/teale-mono"
$ReleasesApi = "https://api.github.com/repos/$Repo/releases?per_page=30"
$TagPattern = '^teale-(\d{4}\.\d{2}\.\d{2}\.\d{4})$'

# "v2026.11.13.1946" / "teale-2026.11.13.1946" / "2026.11.13.1946" -> [version]
function ConvertTo-TealeVersion([string]$Value) {
    if ($null -eq $Value) { return $null }
    $clean = (($Value.Trim() -replace '^teale-', '') -replace '^v', '')
    $parsed = $null
    if ([version]::TryParse($clean, [ref]$parsed)) { return $parsed }
    return $null
}

function Show-TealeMessage([string]$Text, [string]$Buttons, [string]$Icon) {
    Add-Type -AssemblyName PresentationFramework
    return [System.Windows.MessageBox]::Show($Text, "Teale update", $Buttons, $Icon)
}

# --- Installed version ---
if (-not (Test-Path $VersionFile)) { exit 0 }
$installed = ConvertTo-TealeVersion ((Get-Content $VersionFile -Raw))
# 0.0.0.0 = local build without /DAppVer: never nag a developer machine.
if ($null -eq $installed -or $installed -eq [version]"0.0.0.0") { exit 0 }

# --- Newest Windows release ---
try {
    $releases = Invoke-RestMethod -Uri $ReleasesApi -UseBasicParsing -TimeoutSec 10
} catch {
    exit 0
}

$candidates = foreach ($release in $releases) {
    if ($release.draft -or $release.prerelease) { continue }
    if ($release.tag_name -notmatch $TagPattern) { continue }
    $installer = $release.assets | Where-Object { $_.name -eq "Teale.exe" } | Select-Object -First 1
    if (-not $installer) { continue }
    $version = ConvertTo-TealeVersion $release.tag_name
    if ($null -eq $version) { continue }
    [pscustomobject]@{ Version = $version; Release = $release; Installer = $installer }
}
$latest = $candidates | Sort-Object -Property Version -Descending | Select-Object -First 1
if ($null -eq $latest) { exit 0 }

# Strictly newer only: a dev build, a re-tagged or yanked release must not
# offer a downgrade or nag on every logon.
if ($latest.Version -le $installed) { exit 0 }

$releaseUrl = $latest.Release.html_url
$answer = Show-TealeMessage ("Teale $($latest.Version) is available (installed: $installed).`n`n" +
    "Download and install it now?") "YesNo" "Information"
if ("$answer" -ne "Yes") { exit 0 }

# --- Download and verify ---
$checksumsAsset = $latest.Release.assets | Where-Object { $_.name -eq "checksums.txt" } | Select-Object -First 1
$workDir = Join-Path $env:TEMP ("TealeUpdate-" + $latest.Version)
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$installerPath = Join-Path $workDir "Teale.exe"
$checksumsPath = Join-Path $workDir "checksums.txt"

$verified = $false
$reason = "the release has no checksums.txt"
if ($checksumsAsset) {
    try {
        Invoke-WebRequest -Uri $checksumsAsset.browser_download_url -OutFile $checksumsPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        Invoke-WebRequest -Uri $latest.Installer.browser_download_url -OutFile $installerPath -UseBasicParsing -TimeoutSec 1800 -ErrorAction Stop
        $expected = $null
        foreach ($line in Get-Content -Path $checksumsPath) {
            # sha256sum format: "<hex>  Teale.exe" (or "<hex> *Teale.exe")
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?Teale\.exe\s*$') {
                $expected = $Matches[1].ToLowerInvariant()
                break
            }
        }
        $actual = (Get-FileHash -Path $installerPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($null -eq $expected) {
            $reason = "checksums.txt has no entry for Teale.exe"
        } elseif ($actual -ne $expected) {
            $reason = "the downloaded installer does not match its published SHA-256"
        } else {
            $verified = $true
        }
    } catch {
        $reason = "the download failed ($($_.Exception.Message))"
    }
}

if ($verified) {
    Start-Process -FilePath $installerPath
} else {
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue
    Show-TealeMessage ("The Teale update was not installed because $reason.`n`n" +
        "The release page will open so you can download it manually.") "OK" "Warning" | Out-Null
    if ($releaseUrl) { Start-Process $releaseUrl }
}

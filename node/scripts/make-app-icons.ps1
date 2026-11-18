# Generates the Windows/Linux app icon assets from the Teale favicon.
#
#   powershell -ExecutionPolicy Bypass -File node\scripts\make-app-icons.ps1
#
# Source: gateway/src/handlers/favicon.png (1024x1024, the teale.com favicon,
# identical to mac-app/scripts/icon_1024.png). Its corners outside the rounded
# square are opaque black, so they are made transparent first; otherwise the
# icon shows black corners on a light taskbar or Start menu.
#
# Outputs (commit them; nothing generates them at build time):
#   node/installer/teale.ico                    Start-menu shortcut, setup.exe, uninstall entry
#   node/teale-tray/assets/teale-app-32.rgba    window title-bar icon (raw RGBA, 32x32)
#   node/teale-tray/assets/teale-app-256.rgba   taskbar / Alt-Tab icon (raw RGBA, 256x256)
#
# Uses only System.Drawing, so it runs on any Windows machine without extra tools.

param(
    [string]$Source = (Join-Path $PSScriptRoot "..\..\gateway\src\handlers\favicon.png")
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$repo = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$icoPath = Join-Path $repo "node\installer\teale.ico"
$assetDir = Join-Path $repo "node\teale-tray\assets"
$argb = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb

$src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Source))
$n = $src.Width
if ($src.Height -ne $n) { throw "source must be square" }

# Measure the rounded-square corner radius along the diagonal: the first
# non-black pixel sits at r * (1 - 1/sqrt(2)) from the corner.
$i = 0
while ($i -lt ($n / 2)) {
    $c = $src.GetPixel($i, $i)
    if (($c.R + $c.G + $c.B) -gt 6) { break }
    $i++
}
$radius = [math]::Round($i / (1 - 1 / [math]::Sqrt(2)))
Write-Host "source ${n}x${n}, corner radius ~$radius px"

# Paint the source through an anti-aliased rounded-rectangle path so the
# black corners become transparent.
$masked = New-Object System.Drawing.Bitmap $n, $n, $argb
$g = [System.Drawing.Graphics]::FromImage($masked)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.Clear([System.Drawing.Color]::Transparent)
$d = 2 * $radius
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$path.AddArc(0, 0, $d, $d, 180, 90)
$path.AddArc($n - $d, 0, $d, $d, 270, 90)
$path.AddArc($n - $d, $n - $d, $d, $d, 0, 90)
$path.AddArc(0, $n - $d, $d, $d, 90, 90)
$path.CloseFigure()
$brush = New-Object System.Drawing.TextureBrush $src
$g.FillPath($brush, $path)
$g.Dispose()

function Resize-Icon([System.Drawing.Bitmap]$bmp, [int]$size) {
    $out = New-Object System.Drawing.Bitmap $size, $size, $argb
    $gr = [System.Drawing.Graphics]::FromImage($out)
    $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gr.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gr.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $gr.Clear([System.Drawing.Color]::Transparent)
    $attr = New-Object System.Drawing.Imaging.ImageAttributes
    $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
    $rect = New-Object System.Drawing.Rectangle 0, 0, $size, $size
    $gr.DrawImage($bmp, $rect, 0, 0, $bmp.Width, $bmp.Height,
        [System.Drawing.GraphicsUnit]::Pixel, $attr)
    $gr.Dispose()
    return $out
}

# Top-down BGRA bytes of a 32bpp ARGB bitmap.
function Get-Bgra([System.Drawing.Bitmap]$bmp) {
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $argb)
    $rowBytes = $bmp.Width * 4
    $bytes = New-Object byte[] ($rowBytes * $bmp.Height)
    for ($y = 0; $y -lt $bmp.Height; $y++) {
        $rowPtr = [IntPtr]::Add($data.Scan0, $y * $data.Stride)
        [System.Runtime.InteropServices.Marshal]::Copy($rowPtr, $bytes, $y * $rowBytes, $rowBytes)
    }
    $bmp.UnlockBits($data)
    return , $bytes
}

function Get-Rgba([System.Drawing.Bitmap]$bmp) {
    $b = Get-Bgra $bmp
    for ($k = 0; $k -lt $b.Length; $k += 4) {
        $t = $b[$k]; $b[$k] = $b[$k + 2]; $b[$k + 2] = $t
    }
    return , $b
}

# Classic DIB icon entry (BITMAPINFOHEADER + bottom-up BGRA + 1bpp AND mask):
# the most compatible encoding for the small sizes.
function Get-DibEntry([System.Drawing.Bitmap]$bmp) {
    $s = $bmp.Width
    $bgra = Get-Bgra $bmp
    $maskStride = [int]([math]::Ceiling($s / 32.0) * 4)
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter $ms
    $w.Write([int32]40); $w.Write([int32]$s); $w.Write([int32]($s * 2))
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int32]0)
    $w.Write([int32]($s * $s * 4 + $maskStride * $s))
    $w.Write([int32]0); $w.Write([int32]0); $w.Write([int32]0); $w.Write([int32]0)
    for ($y = $s - 1; $y -ge 0; $y--) { $w.Write($bgra, $y * $s * 4, $s * 4) }
    for ($y = $s - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $maskStride
        for ($x = 0; $x -lt $s; $x++) {
            if ($bgra[($y * $s + $x) * 4 + 3] -eq 0) {
                $row[[int][math]::Floor($x / 8)] = $row[[int][math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8))
            }
        }
        $w.Write($row)
    }
    $w.Flush()
    return , $ms.ToArray()
}

# .ico: classic DIB entries at every size. PNG-compressed 256 px entries are
# smaller but some readers (Inno Setup's resource updater, .NET's Icon class)
# mis-decode them, and the file size is irrelevant for an installer icon.
$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$entries = @()
foreach ($s in $sizes) {
    $bmp = Resize-Icon $masked $s
    $payload = Get-DibEntry $bmp
    $entries += , @($s, $payload)
    $bmp.Dispose()
}
$fs = [System.IO.File]::Create($icoPath)
$w = New-Object System.IO.BinaryWriter $fs
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    $s = $e[0]; $len = $e[1].Length
    $dim = if ($s -ge 256) { 0 } else { $s }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int32]$len); $w.Write([int32]$offset)
    $offset += $len
}
foreach ($e in $entries) { $w.Write($e[1]) }
$w.Flush(); $fs.Dispose()
Write-Host "wrote $icoPath ($((Get-Item $icoPath).Length) bytes, sizes $($sizes -join ','))"

foreach ($s in 32, 256) {
    $bmp = Resize-Icon $masked $s
    $out = Join-Path $assetDir "teale-app-$s.rgba"
    [System.IO.File]::WriteAllBytes($out, (Get-Rgba $bmp))
    $bmp.Dispose()
    Write-Host "wrote $out ($((Get-Item $out).Length) bytes)"
}

$masked.Dispose()
$src.Dispose()

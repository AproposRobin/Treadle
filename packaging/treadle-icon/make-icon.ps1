<#
  Renders Treadle.svg (32 px and up) and Treadle-small.svg (16, 24 px) to PNG with headless Chrome, then packs
  Treadle.ico: 256 as a PNG entry, the others as 32-bit BMP entries (with an AND mask), the usual layout that
  every Windows resource compiler and shell reads. No installs: Chrome (or Edge) and System.Drawing only.
  Usage (Windows PowerShell 5.1): powershell -File packaging\treadle-icon\make-icon.ps1
  Writes Treadle-<n>.png and Treadle.ico next to this script; the browser's scratch profile and the render
  pages live in -Work (default %TEMP%\treadle-icon) and are deleted at the end.
#>
param([string]$Dir = $PSScriptRoot, [string]$Out = $PSScriptRoot, [string]$Work = (Join-Path $env:TEMP "treadle-icon"))
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$browser = @("C:\Program Files\Google\Chrome\Application\chrome.exe", "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw "no Chrome or Edge found" }
New-Item -ItemType Directory -Force -Path $Out | Out-Null
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$profileDir = Join-Path $Work "chrome-profile"
$sizes = @(16, 24, 32, 48, 64, 128, 256)
foreach ($n in $sizes) {
    $svg = if ($n -le 24) { "Treadle-small.svg" } else { "Treadle.svg" }
    $html = Join-Path $Work "render-$n.html"
    $svgText = [IO.File]::ReadAllText((Join-Path $Dir $svg)) -replace '(<svg[^>]*?)width="256" height="256"', "`$1width=`"$n`" height=`"$n`""
    [IO.File]::WriteAllText($html, "<!doctype html><html><head><style>html,body{margin:0;padding:0;background:transparent;overflow:hidden}svg{display:block}</style></head><body>$svgText</body></html>")
    $png = Join-Path $Out "Treadle-$n.png"
    if (Test-Path $png) { Remove-Item $png }
    $args = @("--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1", "--no-first-run",
        "--user-data-dir=$profileDir", "--default-background-color=00000000", "--window-size=$([Math]::Max($n, 600)),$($n + 400)", "--screenshot=$png", ("file:///" + ($html -replace '\\', '/')))
    $p = Start-Process -FilePath $browser -ArgumentList $args -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "browser timed out at $n" }
    for ($i = 0; $i -lt 50 -and -not (Test-Path $png); $i++) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path $png)) { throw "no screenshot for $n" }
    # The window is larger than the icon (headless windows have a minimum size and a viewport smaller than the
    # window); the icon sits at the top left, so crop it out.
    $shot = [System.Drawing.Bitmap]::FromFile($png)
    $crop = $shot.Clone((New-Object System.Drawing.Rectangle(0, 0, $n, $n)), [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $shot.Dispose()
    $crop.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $crop.Dispose()
    Remove-Item $html
}

function Get-BmpEntry([string]$png) {
    $bmp = [System.Drawing.Bitmap]::FromFile($png)
    $n = $bmp.Width
    $ms = New-Object IO.MemoryStream
    $bw = New-Object IO.BinaryWriter($ms)
    $maskStride = [int]([Math]::Ceiling($n / 32.0) * 4)
    # BITMAPINFOHEADER: height counts the XOR and AND images
    $bw.Write([int32]40); $bw.Write([int32]$n); $bw.Write([int32]($n * 2)); $bw.Write([int16]1); $bw.Write([int16]32)
    $bw.Write([int32]0); $bw.Write([int32]($n * $n * 4 + $maskStride * $n)); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([int32]0)
    for ($y = $n - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $n; $x++) { $c = $bmp.GetPixel($x, $y); $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A) }
    }
    for ($y = $n - 1; $y -ge 0; $y--) {
        $row = New-Object byte[] $maskStride
        for ($x = 0; $x -lt $n; $x++) { if ($bmp.GetPixel($x, $y).A -eq 0) { $row[[int][Math]::Floor($x / 8)] = $row[[int][Math]::Floor($x / 8)] -bor (0x80 -shr ($x % 8)) } }
        $bw.Write($row)
    }
    $bmp.Dispose(); $bw.Flush()
    return , $ms.ToArray()
}

$entries = @()
foreach ($n in $sizes) {
    $png = Join-Path $Out "Treadle-$n.png"
    $data = if ($n -eq 256) { [IO.File]::ReadAllBytes($png) } else { Get-BmpEntry $png }
    $entries += , @($n, $data)
}
$ico = Join-Path $Out "Treadle.ico"
$fs = [IO.File]::Create($ico); $w = New-Object IO.BinaryWriter($fs)
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$entries.Count)
$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    $n = $e[0]; $d = $e[1]
    $dim = if ($n -ge 256) { 0 } else { $n }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int32]$d.Length); $w.Write([int32]$offset)
    $offset += $d.Length
}
foreach ($e in $entries) { $w.Write([byte[]]$e[1]) }
$w.Close()
for ($i = 0; $i -lt 20; $i++) { try { Remove-Item -Recurse -Force -LiteralPath $Work -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 500 } }
Get-Item $ico | Select-Object Name, Length

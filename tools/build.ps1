# zDPI derleme betigi. Ek arac gerekmez: Windows'taki .NET Framework 4.8 derleyicisi kullanilir.
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1             -> zDPI.exe (repo kokune)
#   powershell -ExecutionPolicy Bypass -File tools\build.ps1 -Release    -> + dist\zDPI-vX.Y.Z.zip ve SHA256SUMS.txt
param(
    [switch]$Release,
    # Yonetici istemeyen derleme: yalnizca arayuzu denemek icin (motor yonetici ister)
    [switch]$AsInvoker,
    [string]$Out
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent
$gui  = Join-Path $root 'gui'
$fw   = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$ico  = Join-Path $gui 'zdpi.ico'
if (-not $Out) { $Out = Join-Path $root 'zDPI.exe' }

# Surum motorda ve arayuzde ayni olmali
$version = [regex]::Match((Get-Content (Join-Path $root 'core\zdpi.ps1') -Raw), "\`$ZdpiVersion = '([^']+)'").Groups[1].Value
$guiVersion = [regex]::Match((Get-Content (Join-Path $gui 'App.cs') -Raw), 'const string Version = "([^"]+)"').Groups[1].Value
if (-not $version -or $version -ne $guiVersion) { throw "Surumler farkli: core\zdpi.ps1=$version, gui\App.cs=$guiVersion" }

# ---------------------------------------------------------------- logo (.ico)
# Arayuzdeki logoyla ayni cizim: 76 birimlik yuvarlak kare, #990033 tonlarinda, beyaz "z".
function New-LogoPng([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.PixelOffsetMode = 'HighQuality'
    $k = $size / 76.0
    $r = 19 * $k * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $r, $r, 180, 90)
    $path.AddArc($size - $r - 0.01, 0, $r, $r, 270, 90)
    $path.AddArc($size - $r - 0.01, $size - $r - 0.01, $r, $r, 0, 90)
    $path.AddArc(0, $size - $r - 0.01, $r, $r, 90, 90)
    $path.CloseFigure()
    $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush (New-Object System.Drawing.Point 0, -1), (New-Object System.Drawing.Point 0, ($size + 1)),
        ([System.Drawing.Color]::FromArgb(255, 0xB0, 0x0A, 0x44)), ([System.Drawing.Color]::FromArgb(255, 0x7A, 0x00, 0x28))
    $g.FillPath($fill, $path)
    # Kucuk boyutlarda cizgi biraz kalinlasir, 16 px'te de okunur kalsin
    $w = [Math]::Max(7.5 * $k, [Math]::Min(2.2, $size / 7.0))
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), $w
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $pts = @(
        (New-Object System.Drawing.PointF (26 * $k), (26.5 * $k)),
        (New-Object System.Drawing.PointF (50 * $k), (26.5 * $k)),
        (New-Object System.Drawing.PointF (26 * $k), (49.5 * $k)),
        (New-Object System.Drawing.PointF (50 * $k), (49.5 * $k))
    )
    $g.DrawLines($pen, $pts)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return ,$ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$pngs = foreach ($s in $sizes) { ,(New-LogoPng $s) }
$fs = [System.IO.File]::Create($ico)
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()

# ---------------------------------------------------------------- derleme
$manifest = Join-Path $gui 'app.manifest'
if ($AsInvoker) {
    $manifest = Join-Path $env:TEMP 'zdpi_asinvoker.manifest'
    (Get-Content (Join-Path $gui 'app.manifest') -Raw) -replace 'requireAdministrator', 'asInvoker' |
        Set-Content $manifest -Encoding UTF8
}

New-Item -ItemType Directory -Path (Split-Path $Out -Parent) -Force | Out-Null
& (Join-Path $fw 'csc.exe') /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 `
    "/out:$Out" "/win32icon:$ico" "/win32manifest:$manifest" `
    "/resource:$(Join-Path $gui 'ui.xaml'),ui.xaml" `
    "/r:$fw\WPF\PresentationFramework.dll" "/r:$fw\WPF\PresentationCore.dll" "/r:$fw\WPF\WindowsBase.dll" `
    "/r:$fw\System.Xaml.dll" "/r:$fw\System.ServiceProcess.dll" `
    (Join-Path $gui 'App.cs')
if ($LASTEXITCODE -ne 0) { throw 'Derleme basarisiz.' }
Write-Host ("zDPI.exe  " + $version + "  ->  " + $Out)
if (-not $Release) { return }

# ---------------------------------------------------------------- dagitim paketi
# Kullaniciya giden zip: zDPI.exe + core + kisa kullanim ve lisans dosyalari.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$name = 'zDPI-v' + $version
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zipPath = Join-Path $dist ($name + '.zip')
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

$files = @('zDPI.exe', 'README.txt', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
           'core\zdpi.ps1', 'core\winws.exe', 'core\cygwin1.dll', 'core\WinDivert.dll', 'core\WinDivert64.sys')
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    foreach ($f in $files) {
        $src = if ($f -eq 'zDPI.exe') { $Out } else { Join-Path $root $f }
        $entry = $name + '/' + ($f -replace '\\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $src, $entry, 'Optimal')
    }
} finally { $zip.Dispose() }

$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), "$hash *$name.zip`n")
Write-Host ("$name.zip  ->  " + $zipPath)
Write-Host ("SHA256     " + $hash)

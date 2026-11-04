# Собирает IPA_PILOTDREDD.exe (запускатор с иконкой) и иконку src/GUI/Assets/app.ico.
# Нужен только csc.exe из .NET Framework 4 — он есть в каждой Windows 10/11.
# Пример: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Launcher.ps1 [-OutDir <папка>] [-RebuildIcon]
param([string]$OutDir, [switch]$RebuildIcon)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = $appRoot }
Import-Module (Join-Path $appRoot 'src/Core/IPADredd.Core.psm1') -Force -DisableNameChecking
$version = Get-DreddVersion

# ---- Иконка: скруглённый квадрат цвета акцента со стрелкой загрузки, PNG-кадры 16…256 в одном .ico ----
$ico = Join-Path $appRoot 'src/GUI/Assets/app.ico'
if ($RebuildIcon -or -not (Test-Path $ico)) {
    Add-Type -AssemblyName System.Drawing
    [void][System.IO.Directory]::CreateDirectory((Split-Path $ico -Parent))
    $frames = foreach ($size in 16, 24, 32, 48, 64, 128, 256) {
        $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.Clear([System.Drawing.Color]::Transparent)
        $r = [single]($size * 0.22)
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $w = [single]($size - 1)
        $path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90); $path.AddArc($w - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
        $path.AddArc($w - 2 * $r, $w - 2 * $r, 2 * $r, 2 * $r, 0, 90); $path.AddArc(0, $w - 2 * $r, 2 * $r, 2 * $r, 90, 90); $path.CloseFigure()
        $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0, 0)), (New-Object System.Drawing.Point(0, $size)), [System.Drawing.Color]::FromArgb(255, 0x4F, 0x8E, 0xF7), [System.Drawing.Color]::FromArgb(255, 0x25, 0x63, 0xD9))
        $g.FillPath($brush, $path)
        # Стрелка загрузки: вертикаль, «галочка», полка снизу.
        $penW = [single][Math]::Max(1.5, $size * 0.085)
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, $penW)
        $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
        $cx = [single]($size / 2); $top = [single]($size * 0.22); $tip = [single]($size * 0.62); $arm = [single]($size * 0.18)
        $g.DrawLine($pen, $cx, $top, $cx, $tip)
        $g.DrawLines($pen, [System.Drawing.PointF[]]@((New-Object System.Drawing.PointF(($cx - $arm), ($tip - $arm))), (New-Object System.Drawing.PointF($cx, $tip)), (New-Object System.Drawing.PointF(($cx + $arm), ($tip - $arm)))))
        $shelf = [single]($size * 0.78)
        $g.DrawLine($pen, [single]($size * 0.27), $shelf, [single]($size * 0.73), $shelf)
        $g.Dispose()
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        [pscustomobject]@{ Size = $size; Bytes = $ms.ToArray() }
    }
    # Формат ICO: заголовок, каталог, PNG-данные.
    $out = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($out)
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$frames.Count)
    $offset = 6 + 16 * $frames.Count
    foreach ($f in $frames) {
        $d = if ($f.Size -ge 256) { 0 } else { $f.Size }
        $bw.Write([byte]$d); $bw.Write([byte]$d); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$f.Bytes.Length); $bw.Write([uint32]$offset)
        $offset += $f.Bytes.Length
    }
    foreach ($f in $frames) { $bw.Write($f.Bytes) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($ico, $out.ToArray())
    Write-Output "Icon: $ico"
}

# ---- Запускатор ----
$csc = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'csc.exe (.NET Framework 4) not found' }
$src = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Launcher\Launcher.cs'), [System.Text.Encoding]::UTF8)
$src = $src.Replace('public const string Version = "0.0.0.0";', ('public const string Version = "{0}.0";' -f $version))
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dredd_launcher_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.cs')
[System.IO.File]::WriteAllText($tmp, $src, (New-Object System.Text.UTF8Encoding($true)))
$exe = Join-Path $OutDir 'IPA_PILOTDREDD.exe'
try {
    $o = & $csc /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 "/win32icon:$ico" "/out:$exe" /reference:System.Windows.Forms.dll $tmp 2>&1
    if ($LASTEXITCODE -ne 0) { throw "csc failed:`n$($o -join "`n")" }
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
Write-Output ("Launcher: {0} ({1:N0} KB)" -f $exe, ((Get-Item $exe).Length / 1KB))

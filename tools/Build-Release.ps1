# Сборка portable-релиза IPA PILOTDREDD (zip) без личных данных: распаковал в любую папку → IPA_PILOTDREDD.exe.
# По умолчанию без MainApp: ipatool-cpp (со встроенными библиотеками Apple) и ideviceinstaller (GPL) программа
# скачивает при первом запуске из официального релиза IPA Downloader. -IncludeBinaries — сборка для себя, с MainApp.
# Пример: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Release.ps1
param(
    [string]$MainAppSource = (Join-Path (Split-Path $PSScriptRoot -Parent) 'MainApp'),
    [ValidateSet('windows_amd64', 'all')][string]$Platforms = 'windows_amd64',
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'),
    [switch]$IncludeBinaries
)
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $appRoot 'src/Core/IPADredd.Core.psm1') -Force -DisableNameChecking
$version = Get-DreddVersion
if ($IncludeBinaries -and -not (Test-Path $MainAppSource)) { throw "MainApp source not found: $MainAppSource" }

$name = "IPA_PILOTDREDD_$version"
$stage = Join-Path $OutDir $name
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'Files') | Out-Null

# Код и документация (без Apps, Logs, истории, настроек, кэша покупок):
foreach ($item in 'VERSION', 'IPA_Dredd.ps1', 'Start_IPA_Dredd_Windows.bat', 'README.md', 'CHANGELOG.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'src', 'tools', 'tests', 'docs') {
    if (-not (Test-Path (Join-Path $appRoot $item))) { continue }
    Copy-Item -LiteralPath (Join-Path $appRoot $item) -Destination $stage -Recurse
}
Copy-Item -LiteralPath (Join-Path $appRoot 'Files/AppsList.txt') -Destination (Join-Path $stage 'Files')
# AppsListCustom.txt не кладём: при копировании новой версии поверх старой он затёр бы «Мой список» (программа создаёт файл сама).

# Запускатор с иконкой — один и тот же exe из релиза в релиз (tools/Launcher), пересборка только при изменении исходников:
$launcherDir = Join-Path $PSScriptRoot 'Launcher'
$launcherExe = Join-Path $launcherDir 'IPA_PILOTDREDD.exe'
$launcherHash = Join-Path $launcherDir 'launcher.sha256'
$current = & (Join-Path $PSScriptRoot 'Get-LauncherSourceHash.ps1')
$recorded = if (Test-Path $launcherHash) { (Get-Content -LiteralPath $launcherHash -Raw).Trim() } else { '' }
if (-not (Test-Path $launcherExe) -or $recorded -ne $current) {
    Write-Warning 'Launcher sources changed: rebuilding tools/Launcher/IPA_PILOTDREDD.exe — commit it together with launcher.sha256.'
    & (Join-Path $PSScriptRoot 'Build-Launcher.ps1') | Out-Null
}
Copy-Item -LiteralPath $launcherExe -Destination (Join-Path $stage 'IPA_PILOTDREDD.exe')
# В архиве копия tools/ без готового exe (он уже лежит в корне программы):
Remove-Item -LiteralPath (Join-Path $stage 'tools\Launcher\IPA_PILOTDREDD.exe') -ErrorAction SilentlyContinue

# Бинарники и версия ipatool:
$folders = if (-not $IncludeBinaries) { @() } elseif ($Platforms -eq 'all') { 'windows_amd64', 'macOS_arm64', 'macOS_amd64', 'linux_amd64' } else { @('windows_amd64') }
foreach ($f in $folders) {
    $src = Join-Path $MainAppSource $f
    if (Test-Path $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $stage "MainApp/$f") -Recurse }
    else { Write-Warning "Missing binaries for $f" }
}
$tv = Join-Path $MainAppSource 'ipatool-version.txt'
if ($IncludeBinaries -and (Test-Path $tv)) { Copy-Item -LiteralPath $tv -Destination (Join-Path $stage 'MainApp') }

# Защита от случайной утечки личных данных:
$personal = 'Settings.txt', 'PurchasedAppsList.json', 'DownloadHistory.json', 'Queue.json', 'account', 'cookies', 'keychain-passphrase'
$leaks = @(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object {
    $_.Extension -in '.ipa', '.log' -or $_.Name -in $personal -or $_.FullName -match '\\Files\\(Purchases|Cache)\\' -or $_.FullName -match '\\MainApp_previous\\'
})
if ($leaks) { throw "Personal data in release: $($leaks.FullName -join ', ')" }

$suffix = if (-not $IncludeBinaries) { 'portable' } elseif ($Platforms -eq 'all') { 'portable_full_all' } else { 'portable_full' }
$zip = Join-Path $OutDir ("{0}_{1}.zip" -f $name, $suffix)
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
# Записи добавляются вручную с разделителем "/": ZipFile.CreateFromDirectory в .NET Framework пишет "\".
$fs = [System.IO.File]::Open($zip, 'Create')
$archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $baseLen = (Split-Path $stage -Parent).Length + 1
    foreach ($file in Get-ChildItem -LiteralPath $stage -Recurse -File) {
        $entryName = $file.FullName.Substring($baseLen).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $entryName, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $archive.Dispose(); $fs.Dispose() }
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output ("Release: {0} ({1:N1} MB)`nSHA-256: {2}" -f $zip, ((Get-Item $zip).Length / 1MB), $sha)

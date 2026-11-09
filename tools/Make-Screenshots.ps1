# Скриншоты для README (docs/images): копия программы с демо-аккаунтом user@example.com и публичными приложениями.
# Личные данные не используются: история покупок вымышленная, метаданные и иконки — публичный iTunes Lookup.
# Пример: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Make-Screenshots.ps1
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docs\images'))
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'IPADreddDemo'
$copy = Join-Path $work 'app'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory (Join-Path $copy 'Files') | Out-Null
foreach ($i in 'VERSION', 'src', 'tests', 'tools', 'IPA_Dredd.ps1') { Copy-Item (Join-Path $appRoot $i) -Destination $copy -Recurse }
Copy-Item (Join-Path $appRoot 'Files\AppsList.txt') (Join-Path $copy 'Files')

Import-Module (Join-Path $copy 'src\Core\IPADredd.Core.psm1') -Force -DisableNameChecking
$ctx = New-DreddContext -AppRoot $copy
$email = 'user@example.com'

# Демо-история покупок: известные бесплатные приложения (ID из App Store) и пара снятых с продажи.
$demo = @(
    @('686449807', 'Telegram', '2019-03-14'), @('310633997', 'WhatsApp Messenger', '2016-07-02'), @('389801252', 'Instagram', '2015-11-20'),
    @('544007664', 'YouTube', '2014-05-11'), @('324684580', 'Spotify', '2017-01-09'), @('585027354', 'Google Maps', '2018-08-23'),
    @('985746746', 'Discord', '2021-02-17'), @('1232780281', 'Notion', '2022-10-05'), @('570060128', 'Duolingo', '2020-04-28'),
    @('284993459', 'Shazam', '2013-12-30'), @('422689480', 'Gmail', '2016-02-14'), @('363590051', 'Netflix', '2019-09-01'),
    @('642831690', 'Flappy Bird', '2014-01-25'), @('592447445', 'Vine', '2015-06-12'), @('447188370', 'Snapchat', '2018-03-03')
)
$apps = foreach ($d in $demo) {
    $r = [pscustomobject][ordered]@{ Id = $d[0]; Name = $d[1]; PurchaseDate = $d[2]; Price = '$0.00'; Lookup = 'Unknown'; LookupAt = ''; StoreName = ''; Version = ''; BundleId = ''; MinIOS = ''; SizeBytes = 0L; Artist = ''; ArtworkUrl = ''; LastErrorKey = ''; LastErrorMessage = ''; LastAttemptAt = '' }
    $r
}
$apps = @($apps)
$lk = Invoke-DreddStoreLookup -Ids @($apps | ForEach-Object { $_.Id }) -Country 'us'
& (Get-Module IPADredd.Core) { param($a, $l) Merge-DreddPurchaseLookup -Apps $a -LookupResult $l } $apps $lk
# Одна неудачная попытка — чтобы был виден статус «Не удалось скачать»:
$nf = $apps | Where-Object { $_.Id -eq '363590051' }
$nf.LastErrorKey = 'Err.Unavailable'; $nf.LastErrorMessage = 'Purchase error: item is temporarily unavailable'; $nf.LastAttemptAt = (Get-Date).AddDays(-1).ToString('s')
Save-DreddPurchaseLibrary -Context $ctx -Email $email -Library ([pscustomobject]@{ Storefront = 'US'; ScannedAt = (Get-Date).ToString('s'); LookupOk = $lk.Ok; Apps = $apps })

# Иконки: купленные + первые популярные (для экрана поиска).
$popular = @(Get-DreddPopularApps -Context $ctx | Select-Object -First 40)
$lk2 = Invoke-DreddStoreLookup -Ids @($popular | ForEach-Object { $_.ID }) -Country 'us'
$withArt = @($apps | Where-Object { $_.ArtworkUrl }) + @($lk2.Found.Keys | ForEach-Object { [pscustomobject]@{ Id = $_; ArtworkUrl = $lk2.Found[$_].ArtworkUrl } })
[void](Save-DreddIcons -Context $ctx -Apps $withArt)

# Скачанные IPA: Telegram (актуальная версия) и Spotify (старая → «Есть обновление»). Минимальные архивы с метаданными.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
function New-DemoIpa([string]$Id, [string]$Name, [string]$Version, [string]$Bundle) {
    $path = Join-Path $ctx.DownloadDir ("{0}_{1}_iOS_15.0+.ipa" -f ($Name -replace '\W', '_'), $Version)
    $fs = [System.IO.File]::Open($path, 'Create'); $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    $info = "<?xml version=`"1.0`"?><plist version=`"1.0`"><dict><key>CFBundleDisplayName</key><string>$Name</string><key>CFBundleIdentifier</key><string>$Bundle</string><key>CFBundleShortVersionString</key><string>$Version</string><key>CFBundleVersion</key><string>1</string><key>MinimumOSVersion</key><string>15.0</string></dict></plist>"
    $meta = "<?xml version=`"1.0`"?><plist version=`"1.0`"><dict><key>itemId</key><integer>$Id</integer><key>artistName</key><string>Demo</string></dict></plist>"
    foreach ($e in @(@("Payload/$Name.app/Info.plist", $info), @('iTunesMetadata.plist', $meta), @("Payload/$Name.app/$Name", 'x'))) {
        $w = New-Object System.IO.StreamWriter($zip.CreateEntry($e[0]).Open()); $w.Write($e[1]); $w.Dispose()
    }
    $zip.Dispose(); $fs.Dispose()
    return $path
}
$tg = $apps | Where-Object { $_.Id -eq '686449807' }
$f1 = New-DemoIpa '686449807' 'Telegram' $(if ($tg.Version) { $tg.Version } else { '12.0' }) 'ph.telegra.Telegraph'
$f2 = New-DemoIpa '324684580' 'Spotify' '8.9.0' 'com.spotify.client'
foreach ($h in @(@('Download', '686449807', 'Telegram', $tg.Version, [System.IO.Path]::GetFileName($f1), ''), @('Install', '686449807', 'Telegram', $tg.Version, '', 'iPhone'), @('Download', '324684580', 'Spotify', '8.9.0', [System.IO.Path]::GetFileName($f2), ''))) {
    Add-DreddHistoryEntry -Context $ctx -Kind $h[0] -AppId $h[1] -Name $h[2] -Version $h[3] -File $h[4] -Target $h[5] -Result Success
}

# Снимки: фейковый ipatool отвечает «вошли как user@example.com», фейковые инструменты — «Test iPhone».
$state = Join-Path $work 'fake_state'
New-Item -ItemType Directory $state | Out-Null
New-Item -ItemType File (Join-Path $state 'logged_in') | Out-Null
$env:FAKE_STATE_DIR = $state
$env:FAKE_WIFI_DEVICE = '1'   # второй iPhone по Wi-Fi — колонка «Подключение»
$shots = Join-Path $work 'shots'
Push-Location $copy
try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File IPA_Dredd.ps1 -SelfTest -Demo -Screenshot $shots -TestIpatool 'tests\fixtures\fake-ipatool.cmd' }
finally { Pop-Location }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory $OutDir | Out-Null }
Copy-Item (Join-Path $shots '*.png') $OutDir -Force
Get-ChildItem $OutDir -Filter *.png | ForEach-Object { "{0} ({1:N0} KB)" -f $_.Name, ($_.Length / 1KB) }

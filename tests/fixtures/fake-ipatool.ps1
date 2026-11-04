# Фейковый ipatool для тестов: повторяет формат JSON-ответов ipatool-cpp (проверено на версии из 4.2).
# Переменные окружения: FAKE_STATE_DIR (файлы состояния), FAKE_SLOW=1 (медленная загрузка для теста отмены).
$ErrorActionPreference = 'Stop'
$a = @($args)
$state = $env:FAKE_STATE_DIR
if ($state) { Add-Content -LiteralPath (Join-Path $state 'calls.log') -Value ($a -join ' ') -Encoding UTF8 }

function Get-Arg([string[]]$names) {
    for ($i = 0; $i -lt $a.Count - 1; $i++) { if ($names -contains $a[$i]) { return $a[$i + 1] } }
    return $null
}
function Out-Json($obj) { [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress -Depth 5)) }

$cmd = $a[0]
if ($cmd -eq 'auth') { $cmd = 'auth ' + $a[1] }

switch ($cmd) {
    'auth info' {
        if ($state -and (Test-Path (Join-Path $state 'logged_in'))) {
            Out-Json @{ email = 'user@example.com'; name = 'Test User'; storefront = 'US'; success = $true }; exit 0
        }
        [Console]::Error.WriteLine('Error: no saved account, please log in'); exit 1
    }
    'auth login' {
        $p = Get-Arg @('-p', '--password'); $code = Get-Arg @('-a', '--auth-code')
        if ($p -eq 'need2fa' -and -not $code) { [Console]::Error.WriteLine('Error: 2FA code is required; run the command again and supply a code using the --auth-code flag'); exit 1 }
        if ($p -eq 'wrong') { [Console]::Error.WriteLine('Error: MZFinance.BadLogin.Configurator_message: incorrect password'); exit 1 }
        New-Item -ItemType File -Force -Path (Join-Path $state 'logged_in') | Out-Null
        if ($env:FAKE_IPATOOL_HOME) { Set-Content -LiteralPath (Join-Path $env:FAKE_IPATOOL_HOME 'account') -Value 'fake' }
        [Console]::Out.WriteLine('INF success=true'); exit 0
    }
    'auth revoke' { Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $state 'logged_in'); exit 0 }
    'kbsync' { exit 0 }
    'search' {
        Out-Json @{ apps = @(@{ bundleID = 'ph.telegra.Telegraph'; id = 686449807; name = 'Telegram Messenger'; price = 0.0; version = '12.0' }, @{ bundleID = 'com.example.fake'; id = 1234567; name = 'Fake App'; price = 0.0; version = '1.0' }); count = 2 }
        exit 0
    }
    'list-versions' { Out-Json @{ bundleID = ''; externalVersionIdentifiers = @('100', '200', '300'); success = $true }; exit 0 }
    'get-version-metadata' {
        $v = Get-Arg @('--external-version-id')
        Out-Json @{ displayVersion = "1.0.$v"; externalVersionID = $v; releaseDate = '2024-01-02T00:00:00Z'; success = $true }; exit 0
    }
    'list-purchases' {
        # Как у реального ipatool-cpp: подписки и встроенные покупки вперемешку, повторы одного ID, даты "Oct 31, 2026".
        Out-Json @{ apps = @(
            @{ id = 1111111; kind = 'iOS App'; name = 'Old App'; price = '$ 0,00'; purchaseDate = 'May 1, 2020' },
            @{ id = 2222222; kind = 'iOS App'; name = 'New App'; price = '$ 0,00'; purchaseDate = 'Jul 9, 2023' },
            @{ id = 2222222; kind = 'iOS App'; name = 'New App'; price = '$ 0,00'; purchaseDate = 'Jan 3, 2024' },
            @{ id = 3333333; kind = 'Mac App'; name = 'Mac Only'; price = 0; purchaseDate = 'Jan 1, 2022' },
            @{ id = 4444444; kind = 'Subscription'; name = 'Some Plan'; price = '1,99 $'; purchaseDate = 'Feb 2, 2024' },
            @{ id = 5555555; kind = 'In-App Purchase'; name = 'Coins'; price = '0,99 $'; purchaseDate = 'Feb 3, 2024' }); count = 6 }
        exit 0
    }
    'purchase' { $id = Get-Arg @('-i'); if ($id -eq '999') { [Console]::Error.WriteLine('Error: paid app, price 1.99'); exit 1 }; [Console]::Out.WriteLine('INF success=true'); exit 0 }
    'download' {
        $id = Get-Arg @('-i'); $out = Get-Arg @('-o')
        if ($id -eq '999') { [Console]::Error.WriteLine('Error: license is required: you have not purchased this item'); exit 1 }
        $steps = if ($env:FAKE_SLOW -eq '1') { 200 } else { 4 }
        for ($i = 1; $i -le $steps; $i++) {
            # Формат реального ipatool-cpp: одно и то же значение повторяется много раз.
            [Console]::Out.WriteLine(('PROGRESS:{0}' -f [int]($i * 100 / $steps)))
            [Console]::Out.WriteLine(('PROGRESS:{0}' -f [int]($i * 100 / $steps)))
            Start-Sleep -Milliseconds $(if ($env:FAKE_SLOW -eq '1') { 100 } else { 20 })
        }
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $fs = [System.IO.File]::Open($out, 'Create')
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        $plist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDisplayName</key><string>Fake App</string>
<key>CFBundleIdentifier</key><string>com.example.fake</string>
<key>CFBundleShortVersionString</key><string>2.5.1</string>
<key>CFBundleVersion</key><string>251</string>
<key>MinimumOSVersion</key><string>15.0</string>
</dict></plist>
"@
        $meta = "<?xml version=`"1.0`"?><plist version=`"1.0`"><dict><key>itemId</key><integer>$id</integer><key>artistName</key><string>Example Inc.</string><key>appleId</key><string>buyer@example.com</string></dict></plist>"
        foreach ($pair in @(@('Payload/Fake.app/Info.plist', $plist), @('iTunesMetadata.plist', $meta), @('Payload/Fake.app/Fake', 'binary'))) {
            $e = $zip.CreateEntry($pair[0]); $w = New-Object System.IO.StreamWriter($e.Open()); $w.Write($pair[1]); $w.Dispose()
        }
        $zip.Dispose(); $fs.Dispose()
        [Console]::Out.WriteLine('INF output=' + $out + ' success=true')
        exit 0
    }
    default { [Console]::Error.WriteLine("Unknown command: $cmd"); exit 2 }
}

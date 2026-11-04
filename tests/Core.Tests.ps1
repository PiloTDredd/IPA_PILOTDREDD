# Тесты ядра IPADredd.Core. Без сети и без реального ~/.ipatool: всё в изолированной временной папке.

Import-Module (Join-Path $appRoot 'src/Core/IPADredd.Core.psm1') -Force -DisableNameChecking

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('IPADreddTests_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][System.IO.Directory]::CreateDirectory($TestRoot)
$fixtures = Join-Path $here 'fixtures'

function New-TestContext {
    $root = Join-Path $TestRoot ('app_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [void][System.IO.Directory]::CreateDirectory((Join-Path $root 'Files'))
    $list = @('Telegram: 686449807', 'YouTube: 544007664', 'Банк [тест]: 1111111111', 'Дубль: 686449807', 'Сбербанк Онлайн: 492224193', 'Шереметьево: 1068124428', 'App6: 100006', 'App7: 100007', 'App8: 100008', 'App9: 100009', 'App10: 100010') -join "`n"
    [System.IO.File]::WriteAllText((Join-Path $root 'Files/AppsList.txt'), $list, (New-Object System.Text.UTF8Encoding($false)))
    $home1 = Join-Path $root '.ipatool'
    [void][System.IO.Directory]::CreateDirectory($home1)
    $ctx = New-DreddContext -AppRoot $root -IpatoolHome $home1 -TempRoot (Join-Path $root 'tmp')
    $ctx.Binaries = [pscustomobject]@{ Root = $fixtures; RootSource = 'test'; Ipatool = (Join-Path $fixtures 'fake-ipatool.cmd'); IdeviceInstaller = $null; IdeviceId = $null; IdeviceInfo = $null; MissingDlls = @(); Candidates = @(); Notes = @() }
    $state = Join-Path $root 'state'
    [void][System.IO.Directory]::CreateDirectory($state)
    $env:FAKE_STATE_DIR = $state
    $env:FAKE_IPATOOL_HOME = $home1
    $env:FAKE_SLOW = $null
    return $ctx
}

# ---------------- Код и кодировка ----------------

Test 'All scripts parse without errors' {
    $bad = @()
    foreach ($f in Get-ChildItem -LiteralPath $appRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
        $t = $null; $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$t, [ref]$e)
        if ($e.Count) { $bad += "$($f.Name): $($e[0].Message)" }
    }
    Assert-Equal 0 $bad.Count ($bad -join '; ')
}

Test 'All scripts are UTF-8 with BOM (required by Windows PowerShell 5.1)' {
    $noBom = @(Get-ChildItem -LiteralPath $appRoot -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' } | Where-Object {
        $b = [System.IO.File]::ReadAllBytes($_.FullName); -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    } | ForEach-Object { $_.Name })
    Assert-Equal 0 $noBom.Count ("Without BOM: " + ($noBom -join ', '))
}

Test 'XAML files are well-formed XML' {
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $appRoot 'src/GUI') -Recurse -Filter '*.xaml') {
        $x = New-Object System.Xml.XmlDocument
        $x.LoadXml([System.IO.File]::ReadAllText($f.FullName))
    }
}

Test 'Module exports the public API' {
    $cmds = @(Get-Command -Module IPADredd.Core)
    Assert-True ($cmds.Count -ge 80) "Only $($cmds.Count) commands exported"
    foreach ($n in 'Invoke-DreddDownload', 'Connect-DreddAppleId', 'Get-DreddDevices', 'Get-DreddIpaMetadata', 'Protect-LogText', 'Get-DreddProp') {
        Assert-True ([bool](Get-Command $n -ErrorAction SilentlyContinue)) "$n missing"
    }
}

# ---------------- Маскирование ----------------

Test 'Protect-LogText masks emails, passwords, passphrase, auth code and cookies' {
    $t = Protect-LogText 'ipatool auth login -e john.doe@mail.ru -p S3cr3t!pass -a 123456 --keychain-passphrase abcdef0123'
    Assert-NotMatch $t 'S3cr3t' 'password leaked.'
    Assert-NotMatch $t '123456' 'auth code leaked.'
    Assert-NotMatch $t 'abcdef0123' 'passphrase leaked.'
    Assert-NotMatch $t 'john\.doe' 'email local part leaked.'
    Assert-Match $t 'j\*\*\*@mail\.ru' 'email should be masked as j***@mail.ru.'
    $c = Protect-LogText "Cookie: session=abc123; mz_at0=xyz`nSet-Cookie: x=y`npassword=hunter2&token=tok42"
    Assert-NotMatch $c 'abc123|xyz|hunter2|tok42' 'cookie/token leaked.'
    $s = Protect-LogText 'value TopSecretValue here' -SecretValues @('TopSecretValue')
    Assert-NotMatch $s 'TopSecretValue' 'explicit secret leaked.'
    Assert-Equal "plain text" (Protect-LogText ("$([char]27)[32mplain text$([char]27)[0m")) 'ANSI codes not removed.'
}

# ---------------- Настройки и списки ----------------

Test 'Settings keep unknown 4.2 keys and normalize values' {
    $ctx = New-TestContext
    [System.IO.File]::WriteAllText($ctx.SettingsPath, "Language=EN`r`nMode=Downloader`r`nKeychainEnabled=False`r`nTheme=Purple`r`n")
    $s = Get-DreddSettings -Path $ctx.SettingsPath
    Assert-Equal 'EN' $s['Language']
    Assert-Equal 'Dark' $s['Theme'] 'invalid theme must fall back to Dark.'
    Set-DreddSetting -Path $ctx.SettingsPath -Key 'Theme' -Value 'Light' -Settings $s
    $raw = [System.IO.File]::ReadAllText($ctx.SettingsPath)
    Assert-Match $raw 'Mode=Downloader' 'unknown key lost.'
    Assert-Match $raw 'Theme=Light'
    Assert-Equal 'Light' $s['Theme']
}

Test 'Apps lists: parsing, duplicates, search with special characters, ID queries' {
    $ctx = New-TestContext
    $pop = @(Get-DreddPopularApps -Context $ctx)
    Assert-Equal 11 $pop.Count
    Assert-Equal 10 @(Remove-DreddDuplicateIds -Items $pop).Count 'duplicate ID not removed.'
    Assert-Equal 1 @(Search-DreddLocalApps -Context $ctx -Query '[тест]').Count 'literal [ ] search failed.'
    Assert-Equal 0 @(Search-DreddLocalApps -Context $ctx -Query '*?[').Count
    Assert-Equal 1 @(Search-DreddLocalApps -Context $ctx -Query 'сбер').Count 'case-insensitive Cyrillic search failed.'
    Assert-Equal @('686449807', '544007664') (Split-DreddIdQuery '686449807, 544007664')
    Assert-Equal $null (Split-DreddIdQuery '12345, abc')
    Assert-Equal $null (Split-DreddIdQuery '12345')
}

Test 'Custom list overrides names and rejects duplicates' {
    $ctx = New-TestContext
    Assert-True (Add-DreddCustomApp -Context $ctx -Name 'Мой Телеграм' -AppId '686449807')
    Assert-False (Add-DreddCustomApp -Context $ctx -Name 'Again' -AppId '686449807') 'duplicate accepted.'
    Assert-Equal 'Мой Телеграм' (Resolve-DreddAppName -Context $ctx -AppId '686449807')
    $found = @(Search-DreddLocalApps -Context $ctx -Query 'тел')
    Assert-Equal 'Custom' $found[0].Source
}

# ---------------- Истории ----------------

Test 'PurchasedAppsList: reads 4.1 object format, always writes arrays' {
    $ctx = New-TestContext
    $legacy = '{ "a@example.com": { "name": "Шереметьево", "appid": "1068124428" }, "b@example.com": [ { "name": "X", "appid": "1" } ] }'
    [System.IO.File]::WriteAllText($ctx.PurchasedPath, $legacy)
    Assert-Equal 1 @(Get-DreddPurchasedApps -Context $ctx -Account 'a@example.com').Count
    Assert-Equal 2 @(Get-DreddPurchasedApps -Context $ctx).Count
    [void](Add-DreddPurchasedApp -Context $ctx -Account 'c@example.com' -AppId '686449807' -Name 'Telegram')
    $raw = [System.IO.File]::ReadAllText($ctx.PurchasedPath)
    Assert-Match $raw '"c@example\.com":\s*\[' 'single element must be an array.'
    Assert-Match $raw '"a@example\.com":\s*\[' 'legacy object must become an array.'
    $parsed = $raw | ConvertFrom-Json
    Assert-Equal 'Telegram' @($parsed.'c@example.com')[0].Name
    Assert-False (Add-DreddPurchasedApp -Context $ctx -Account 'c@example.com' -AppId '686449807' -Name 'Telegram') 'duplicate added.'
}

Test 'Download history masks account email' {
    $ctx = New-TestContext
    Add-DreddHistoryEntry -Context $ctx -Kind Download -AppId '1' -Name 'One' -Version '1.0' -Account 'secret.person@example.com' -File 'One.ipa'
    Add-DreddHistoryEntry -Context $ctx -Kind Install -Name 'One' -Target 'iPhone' -Result Error -Message 'fail'
    $h = @(Get-DreddDownloadHistory -Context $ctx)
    Assert-Equal 2 $h.Count
    Assert-NotMatch ([System.IO.File]::ReadAllText($ctx.HistoryPath)) 'secret\.person' 'email stored in history.'
}

# ---------------- plist и IPA ----------------

function New-BinaryPlist {
    # Минимальный bplist00: словарь из ASCII-ключей и строк (ASCII или UTF-16).
    param([System.Collections.Specialized.OrderedDictionary]$Dict)
    $objects = New-Object System.Collections.Generic.List[byte[]]
    $encStr = {
        param([string]$s)
        $ascii = -not ($s.ToCharArray() | Where-Object { [int]$_ -gt 127 })
        if ($ascii) { $bytes = [System.Text.Encoding]::ASCII.GetBytes($s); $type = 0x50 } else { $bytes = [System.Text.Encoding]::BigEndianUnicode.GetBytes($s); $type = 0x60 }
        $len = $s.Length
        $hdr = if ($len -lt 15) { [byte[]]@($type -bor $len) } else { [byte[]]@(($type -bor 0x0F), 0x10, $len) }
        , ([byte[]](@($hdr) + @($bytes)))
    }
    $n = $Dict.Count
    $objects.Add($null)
    foreach ($k in $Dict.Keys) { $objects.Add((& $encStr $k)) }
    foreach ($k in $Dict.Keys) { $objects.Add((& $encStr ([string]$Dict[$k]))) }
    $refs = [byte[]](1..(2 * $n))
    $objects[0] = [byte[]](@([byte](0xD0 -bor $n)) + $refs)
    $ms = New-Object System.IO.MemoryStream
    $hdr = [System.Text.Encoding]::ASCII.GetBytes('bplist00'); $ms.Write($hdr, 0, 8)
    $offsets = @()
    foreach ($o in $objects) { $offsets += [int]$ms.Position; $ms.Write($o, 0, $o.Length) }
    $tableOffset = [int]$ms.Position
    foreach ($off in $offsets) { $ms.WriteByte([byte]$off) }
    $trailer = New-Object byte[] 32
    $trailer[6] = 1; $trailer[7] = 1; $trailer[15] = [byte]$objects.Count; $trailer[23] = 0; $trailer[31] = [byte]$tableOffset
    $ms.Write($trailer, 0, 32)
    return , $ms.ToArray()
}

Test 'PlistReader parses XML and binary plists' {
    $xml = [System.Text.Encoding]::UTF8.GetBytes('<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>A</key><string>Привет</string><key>N</key><integer>42</integer><key>B</key><true/><key>L</key><array><string>x</string></array></dict></plist>')
    $d = [IPADredd.PlistReader]::Parse($xml)
    Assert-Equal 'Привет' $d['A']
    Assert-Equal 42 $d['N']
    Assert-Equal $true $d['B']
    $o = New-Object System.Collections.Specialized.OrderedDictionary
    $o['CFBundleIdentifier'] = 'com.test.app'; $o['MinimumOSVersion'] = '14.0'; $o['CFBundleDisplayName'] = 'Тест'
    $bin = New-BinaryPlist $o
    $bd = [IPADredd.PlistReader]::Parse($bin)
    Assert-Equal 'com.test.app' $bd['CFBundleIdentifier']
    Assert-Equal '14.0' $bd['MinimumOSVersion']
    Assert-Equal 'Тест' $bd['CFBundleDisplayName'] 'UTF-16 string failed.'
}

function New-TestIpa {
    param([string]$Path, [byte[]]$InfoPlist)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $fs = [System.IO.File]::Open($Path, 'Create')
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    $e = $zip.CreateEntry('Payload/Test.app/Info.plist'); $s = $e.Open(); $s.Write($InfoPlist, 0, $InfoPlist.Length); $s.Dispose()
    $e2 = $zip.CreateEntry('iTunesMetadata.plist'); $w = New-Object System.IO.StreamWriter($e2.Open())
    $w.Write('<?xml version="1.0"?><plist version="1.0"><dict><key>itemId</key><integer>777777</integer><key>appleId</key><string>buyer@example.com</string></dict></plist>'); $w.Dispose()
    $zip.Dispose(); $fs.Dispose()
}

Test 'IPA metadata from binary Info.plist (bug A1 of 4.2) without reading the buyer Apple ID' {
    $o = New-Object System.Collections.Specialized.OrderedDictionary
    $o['CFBundleName'] = 'BinApp'; $o['CFBundleIdentifier'] = 'com.bin.app'; $o['CFBundleShortVersionString'] = '3.2.1'; $o['MinimumOSVersion'] = '16.4'
    $ipa = Join-Path $TestRoot 'bin.ipa'
    New-TestIpa -Path $ipa -InfoPlist (New-BinaryPlist $o)
    $m = Get-DreddIpaMetadata -Path $ipa
    Assert-Equal $null $m.Error
    Assert-Equal 'BinApp' $m.Name
    Assert-Equal '3.2.1' $m.Version
    Assert-Equal '16.4' $m.MinIOS
    Assert-Equal '777777' $m.AppStoreId
    Assert-NotMatch (($m | Out-String)) 'buyer@example' 'buyer Apple ID must not be read.'
    $broken = Join-Path $TestRoot 'broken.ipa'
    [System.IO.File]::WriteAllText($broken, 'not a zip')
    Assert-True ([bool](Get-DreddIpaMetadata -Path $broken).Error) 'broken IPA must report an error.'
}

function New-ZipWithEntries {
    param([string]$Path, [hashtable]$Entries)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $fs = [System.IO.File]::Open($Path, 'Create')
    $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    foreach ($k in $Entries.Keys) {
        $bytes = $Entries[$k]
        if ($bytes -is [string]) { $bytes = [System.Text.Encoding]::UTF8.GetBytes($bytes) }
        $s = $zip.CreateEntry($k).Open(); $s.Write($bytes, 0, $bytes.Length); $s.Dispose()
    }
    $zip.Dispose(); $fs.Dispose()
}

function New-MachO64 {
    # Минимальный Mach-O 64 с одной командой LC_ENCRYPTION_INFO_64 (0x2C) и заданным cryptid.
    param([int]$CryptId)
    $b = New-Object byte[] 64
    [BitConverter]::GetBytes([Convert]::ToUInt32('FEEDFACF', 16)).CopyTo($b, 0)
    [BitConverter]::GetBytes([uint32]1).CopyTo($b, 16)      # ncmds
    [BitConverter]::GetBytes([uint32]24).CopyTo($b, 20)     # sizeofcmds
    [BitConverter]::GetBytes([uint32]0x2C).CopyTo($b, 32)   # cmd
    [BitConverter]::GetBytes([uint32]24).CopyTo($b, 36)     # cmdsize
    [BitConverter]::GetBytes([uint32]$CryptId).CopyTo($b, 48)
    return , $b
}

Test 'Signature: Ad Hoc profile, UDID and expiry checks; decrypted Mach-O; App Store build' {
    $info = '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleName</key><string>Sig</string><key>CFBundleExecutable</key><string>Sig</string><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>'
    $exp = (Get-Date).AddDays(30).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $prov = "<?xml version=`"1.0`"?><plist version=`"1.0`"><dict><key>Name</key><string>Test Profile</string><key>TeamName</key><string>Test Team</string><key>ExpirationDate</key><date>$exp</date><key>ProvisionedDevices</key><array><string>00008130-AAAA</string></array><key>Entitlements</key><dict><key>get-task-allow</key><false/></dict></dict></plist>"
    $provBytes = [byte[]](@([byte]0x30, [byte]0x82, [byte]0x01) + [System.Text.Encoding]::UTF8.GetBytes($prov) + @([byte]0xA0, [byte]0x00))
    $adhoc = Join-Path $TestRoot 'adhoc.ipa'
    New-ZipWithEntries -Path $adhoc -Entries @{ 'Payload/Sig.app/Info.plist' = $info; 'Payload/Sig.app/embedded.mobileprovision' = $provBytes; 'Payload/Sig.app/Sig' = (New-MachO64 0) }
    $m = Get-DreddIpaMetadata -Path $adhoc
    Assert-Equal 'AdHoc' $m.SignType
    Assert-Equal 'Test Team' $m.SignTeam
    Assert-Equal $null (Test-DreddSignatureForDevice -SignType $m.SignType -SignExpires $m.SignExpires -SignDevices $m.SignDevices -Udid '00008130-aaaa') 'UDID in profile must pass (case-insensitive).'
    Assert-Equal 'Sign.Problem.NoDevice' (Test-DreddSignatureForDevice -SignType $m.SignType -SignExpires $m.SignExpires -SignDevices $m.SignDevices -Udid '00008130-BBBB').Key
    Assert-Equal 'Sign.Problem.Expired' (Test-DreddSignatureForDevice -SignType 'AdHoc' -SignExpires (Get-Date).AddDays(-1) -SignDevices @('X') -Udid 'X').Key

    $dec = Join-Path $TestRoot 'decrypted.ipa'
    New-ZipWithEntries -Path $dec -Entries @{ 'Payload/Sig.app/Info.plist' = $info; 'Payload/Sig.app/Sig' = (New-MachO64 0); 'Payload/Sig.app/SC_Info/Sig.sinf' = 'x' }
    $d = Get-DreddIpaMetadata -Path $dec
    Assert-Equal 'Decrypted' $d.SignType 'decrypted binary (cryptid=0) must not be treated as App Store even with SC_Info.'
    Assert-True (Test-DreddSignatureForDevice -SignType $d.SignType -Udid 'X').Blocking

    $store = Join-Path $TestRoot 'store.ipa'
    New-ZipWithEntries -Path $store -Entries @{ 'Payload/Sig.app/Info.plist' = $info; 'Payload/Sig.app/Sig' = (New-MachO64 1) }
    $s = Get-DreddIpaMetadata -Path $store
    Assert-Equal 'AppStore' $s.SignType
    Assert-True $s.Encrypted
    Assert-False (Test-DreddSignatureForDevice -SignType 'AppStore' -Udid 'X').Blocking
}

Test 'Import-DreddIpaToLibrary copies without overwriting and keeps the original' {
    $src = Join-Path $TestRoot 'import_src'; $lib = Join-Path $TestRoot 'import_lib'
    [void][System.IO.Directory]::CreateDirectory($src)
    $f = Join-Path $src 'My App.ipa'; [System.IO.File]::WriteAllText($f, 'ipa')
    $a = Import-DreddIpaToLibrary -Path $f -Folder $lib
    $b = Import-DreddIpaToLibrary -Path $f -Folder $lib
    Assert-Equal 'My App.ipa' ([System.IO.Path]::GetFileName($a))
    Assert-Equal 'My App_2.ipa' ([System.IO.Path]::GetFileName($b))
    Assert-True ([System.IO.File]::Exists($f)) 'original must remain.'
    Assert-Equal $a (Import-DreddIpaToLibrary -Path $a -Folder $lib) 'a file already in the library must not be copied again.'
}

Test 'File names: template, invalid characters, no overwrite' {
    Assert-Equal 'My_App_1.0_iOS_15.0+.ipa' (Get-DreddIpaFileName -Name 'My: App?' -Version '1.0' -MinIOS '15.0')
    Assert-Equal 'App_unknown_iOS_NA+.ipa' (Get-DreddIpaFileName -Name '' -Version '' -MinIOS '')
    Assert-Equal 'X_1_iOS_12+_user@example.com.ipa' (Get-DreddIpaFileName -Name 'X' -Version '1' -MinIOS '12' -Account 'user@example.com')
    $dir = Join-Path $TestRoot 'names'; [void][System.IO.Directory]::CreateDirectory($dir)
    [System.IO.File]::WriteAllText((Join-Path $dir 'a.ipa'), 'x')
    Assert-Equal (Join-Path $dir 'a_2.ipa') (Get-DreddUniquePath -Folder $dir -FileName 'a.ipa')
}

Test 'iOS version comparison' {
    Assert-True (Test-DreddIosCompatible -MinIOS '15.0' -DeviceVersion '17.2.1')
    Assert-False (Test-DreddIosCompatible -MinIOS '16.4' -DeviceVersion '16.3')
    Assert-True (Test-DreddIosCompatible -MinIOS '15' -DeviceVersion '15.0')
    Assert-Equal $null (Test-DreddIosCompatible -MinIOS 'NA' -DeviceVersion '17.0')
}

# ---------------- Процессы ----------------

Test 'Argument quoting follows Windows rules' {
    Assert-Equal 'a "b c" "x\"y" "C:\dir with space\\"' (ConvertTo-DreddArgumentString @('a', 'b c', 'x"y', 'C:\dir with space\'))
    Assert-Equal '""' (ConvertTo-DreddArgumentString @(''))
}

Test 'Invoke-DreddProcess captures output, exit code and masks the command line' {
    $r = Invoke-DreddProcess -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo hello & echo oops 1>&2 & exit 3') -SecretValues @('hello')
    Assert-Equal 3 $r.ExitCode
    Assert-Match $r.StdOut 'hello'
    Assert-Match $r.StdErr 'oops'
    Assert-NotMatch $r.CommandLine 'hello' 'secret visible in command line.'
}

Test 'Invoke-DreddProcess timeout and cancellation kill the process tree' {
    $r = Invoke-DreddProcess -FilePath 'cmd.exe' -ArgumentList @('/c', 'ping -n 30 127.0.0.1 >nul') -TimeoutSec 1
    Assert-True $r.TimedOut 'timeout not detected.'
    Assert-True ($r.Duration.TotalSeconds -lt 8) "timeout took $($r.Duration.TotalSeconds) s."
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter(700)
    $r2 = Invoke-DreddProcess -FilePath 'cmd.exe' -ArgumentList @('/c', 'ping -n 30 127.0.0.1 >nul') -CancellationToken $cts.Token
    Assert-True $r2.Cancelled 'cancel not detected.'
    Assert-True ($r2.Duration.TotalSeconds -lt 8) "cancel took $($r2.Duration.TotalSeconds) s."
}

# ---------------- Бинарники ----------------

Test 'Find-DreddBinaries prefers settings, then app MainApp, then 4.2, then 4.1' {
    $base = Join-Path $TestRoot ('bins_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $app = Join-Path $base 'IPA_Dredd_4.3.0'
    $v42 = Join-Path $base 'IPA_Downloader_4.2.0/MainApp/windows_amd64'
    [void][System.IO.Directory]::CreateDirectory($app); [void][System.IO.Directory]::CreateDirectory($v42)
    foreach ($f in 'ipatool-cpp-windows-amd64.exe', 'idevice_id.exe', 'ideviceinstaller.exe', 'ideviceinfo.exe') { [System.IO.File]::WriteAllText((Join-Path $v42 $f), '') }
    $b = Find-DreddBinaries -AppRoot $app
    Assert-Equal 'v4.2' $b.RootSource
    Assert-True ([bool]$b.IdeviceId)
    Assert-True (@($b.MissingDlls).Count -eq 11) 'DLLs should be reported as missing.'
    $own = Join-Path $app 'MainApp/windows_amd64'; [void][System.IO.Directory]::CreateDirectory($own)
    [System.IO.File]::WriteAllText((Join-Path $own 'ipatool-cpp-windows-amd64.exe'), '')
    $b2 = Find-DreddBinaries -AppRoot $app
    Assert-Equal 'app' $b2.RootSource
    Assert-True ($b2.IdeviceId -like '*IPA_Downloader_4.2.0*') 'device tools should fall back to 4.2 folder.'
    $b3 = Find-DreddBinaries -AppRoot $app -Configured (Join-Path $base 'IPA_Downloader_4.2.0/MainApp')
    Assert-Equal 'settings' $b3.RootSource
}

# ---------------- Аккаунты ----------------

Test 'Accounts: park, restore, forget (4.2 layout), path traversal rejected' {
    $ctx = New-TestContext
    $h = $ctx.IpatoolHome
    foreach ($f in 'account', 'cookies', 'login') { [System.IO.File]::WriteAllText((Join-Path $h $f), "A-$f") }
    [System.IO.File]::WriteAllText((Join-Path $h 'keychain-passphrase'), 'KP')
    Save-DreddActiveAccount -Context $ctx -Email 'a@example.com'
    Assert-False ([System.IO.File]::Exists((Join-Path $h 'account'))) 'active file not moved.'
    Assert-Equal 'A-account' ([System.IO.File]::ReadAllText((Join-Path $h 'a@example.com/account')))
    Assert-Equal 1 @(Get-DreddSavedAccounts -Context $ctx).Count
    [void](Restore-DreddSavedAccount -Context $ctx -Email 'a@example.com')
    Assert-True ([System.IO.File]::Exists((Join-Path $h 'cookies')))
    Assert-False ([System.IO.Directory]::Exists((Join-Path $h 'a@example.com'))) 'empty account folder not removed.'
    Clear-DreddActiveAccount -Context $ctx
    Assert-True ([System.IO.File]::Exists((Join-Path $h 'keychain-passphrase'))) 'keychain-passphrase must never be deleted.'
    Assert-False (Test-DreddAccountName '..\evil')
    Assert-False (Test-DreddAccountName 'a/b')
    $threw = $false; try { Remove-DreddSavedAccount -Context $ctx -Email '..' } catch { $threw = $true }
    Assert-True $threw 'path traversal accepted.'
}

# ---------------- ipatool (фейк) ----------------

Test 'Auth info: no session and active session' {
    $ctx = New-TestContext
    $r = Get-DreddAuthInfo -Context $ctx
    Assert-False $r.Success
    [System.IO.File]::WriteAllText((Join-Path $ctx.IpatoolHome 'account'), 'x')
    New-Item -ItemType File -Path (Join-Path $env:FAKE_STATE_DIR 'logged_in') | Out-Null
    $log = New-Object System.Collections.Generic.List[object]
    $r2 = Get-DreddAuthInfo -Context $ctx -Reporter $log
    Assert-True $r2.Success
    Assert-Equal 'user@example.com' $r2.Email
    Assert-Equal 'US' $r2.Storefront
    Assert-NotMatch (($log | ForEach-Object { $_.Message }) -join "`n") 'Test User' 'account owner name written to the log.'
}

Test 'Login: 2FA request, wrong password, success creates login marker; password never logged' {
    $ctx = New-TestContext
    $log = New-Object System.Collections.Generic.List[object]
    $r = Connect-DreddAppleId -Context $ctx -Email 'user@example.com' -Password 'need2fa' -Reporter $log
    Assert-False $r.Success
    Assert-True $r.NeedsCode '2FA not detected.'
    $r2 = Connect-DreddAppleId -Context $ctx -Email 'user@example.com' -Password 'wrong' -Reporter $log
    Assert-Equal 'Err.BadCredentials' $r2.ErrorKey
    $sec = New-Object System.Security.SecureString; foreach ($c in 'goodPassw0rd'.ToCharArray()) { $sec.AppendChar($c) }
    $r3 = Connect-DreddAppleId -Context $ctx -Email 'user@example.com' -Password $sec -Reporter $log
    Assert-True $r3.Success "login failed: $($r3.ErrorKey) $($r3.Message)"
    Assert-True (Test-DreddLoginMarker -Context $ctx) 'login marker (4.2 compatibility) not created.'
    $all = ($log | ForEach-Object { $_.Message }) -join "`n"
    Assert-NotMatch $all 'goodPassw0rd|need2fa|wrong ' 'password leaked into reporter messages.'
    $calls = [System.IO.File]::ReadAllText((Join-Path $env:FAKE_STATE_DIR 'calls.log'))
    Assert-Match $calls 'kbsync --refresh' 'kbsync not called after login.'
}

Test 'Login with ParkCurrentAs restores the previous session on failure' {
    $ctx = New-TestContext
    [System.IO.File]::WriteAllText((Join-Path $ctx.IpatoolHome 'account'), 'OLD')
    [System.IO.File]::WriteAllText((Join-Path $ctx.IpatoolHome 'login'), '')
    $r = Connect-DreddAppleId -Context $ctx -Email 'new@example.com' -Password 'wrong' -ParkCurrentAs 'old@example.com'
    Assert-False $r.Success
    Assert-Equal 'OLD' ([System.IO.File]::ReadAllText((Join-Path $ctx.IpatoolHome 'account'))) 'previous session not restored.'
}

Test 'Search, versions (newest first), metadata, purchases (iOS only, newest first)' {
    $ctx = New-TestContext
    $s = Search-DreddApps -Context $ctx -Query 'Telegram' -IncludeAppStore
    Assert-True $s.Ok
    $tg = @($s.Apps | Where-Object { $_.ID -eq '686449807' })
    Assert-Equal 1 $tg.Count 'local and App Store results not merged by ID.'
    Assert-Equal '12.0' $tg[0].Version 'App Store version not merged into the local result.'
    $v = Get-DreddAppVersions -Context $ctx -AppId '686449807'
    Assert-Equal @('300', '200', '100') $v.VersionIds
    $m = Get-DreddVersionMetadata -Context $ctx -AppId '686449807' -VersionId '200'
    Assert-Equal '1.0.200' $m.DisplayVersion
    Assert-Equal '2024-01-02' $m.ReleaseDate
    $p = Get-DreddAccountPurchases -Context $ctx
    Assert-True $p.Ok
    Assert-Equal @('2222222', '1111111') @($p.Apps | ForEach-Object { $_.ID })
}

Test 'Purchase writes PurchasedAppsList only on success (fix A6)' {
    $ctx = New-TestContext
    $bad = Invoke-DreddPurchase -Context $ctx -AppId '999' -AppName 'Paid' -Account 'user@example.com'
    Assert-False $bad.Ok
    Assert-False ([System.IO.File]::Exists($ctx.PurchasedPath)) 'failed purchase recorded.'
    $ok = Invoke-DreddPurchase -Context $ctx -AppId '686449807' -AppName 'Telegram' -Account 'user@example.com'
    Assert-True $ok.Ok
    Assert-Equal 1 @(Get-DreddPurchasedApps -Context $ctx -Account 'user@example.com').Count
}

Test 'Download: temp folder, rename, no overwrite, history, progress' {
    $ctx = New-TestContext
    $msgs = New-Object System.Collections.Generic.List[object]
    $r = Invoke-DreddDownload -Context $ctx -AppId '1234567' -AppName 'Fake App' -Account 'user@example.com' -Reporter $msgs
    Assert-True $r.Ok "download failed: $($r.Error.Key) $($r.Error.Message)"
    Assert-Equal 'Fake_App_2.5.1_iOS_15.0+.ipa' ([System.IO.Path]::GetFileName($r.Path))
    Assert-Equal '15.0' $r.Metadata.MinIOS
    $r2 = Invoke-DreddDownload -Context $ctx -AppId '1234567' -AppName 'Fake App' -Account 'user@example.com'
    Assert-Equal 'Fake_App_2.5.1_iOS_15.0+_2.ipa' ([System.IO.Path]::GetFileName($r2.Path)) 'existing file overwritten.'
    Assert-Equal 0 @([System.IO.Directory]::GetDirectories($ctx.TempRoot)).Count 'temp folder not cleaned.'
    Assert-Equal 2 @(Get-DreddDownloadHistory -Context $ctx).Count
    $pct = @($msgs | Where-Object { $_.Type -eq 'progress' -and $_.Value.Percent -ne $null } | ForEach-Object { $_.Value.Percent })
    Assert-True ($pct -contains 100) 'progress percent not parsed.'
    $calls = [System.IO.File]::ReadAllText((Join-Path $env:FAKE_STATE_DIR 'calls.log'))
    Assert-NotMatch $calls '--purchase' '--purchase must not be added unless requested.'
}

Test 'Download: missing license is explained when auto-purchase is off' {
    $ctx = New-TestContext
    $r = Invoke-DreddDownload -Context $ctx -AppId '999' -AppName 'Paid'
    Assert-False $r.Ok
    Assert-Equal 'Err.LicenseNoPurchase' $r.Error.Key
}

Test 'Download: cancellation stops ipatool and cleans up' {
    $ctx = New-TestContext
    $env:FAKE_SLOW = '1'
    try {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.CancelAfter(2500)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-DreddDownload -Context $ctx -AppId '1234567' -AppName 'Fake App' -CancellationToken $cts.Token
        Assert-True $r.Cancelled 'not cancelled.'
        Assert-True ($sw.Elapsed.TotalSeconds -lt 12) "cancel took $($sw.Elapsed.TotalSeconds) s."
        Assert-Equal 0 @([System.IO.Directory]::GetDirectories($ctx.TempRoot)).Count 'temp folder not cleaned after cancel.'
        Assert-Equal 0 @([System.IO.Directory]::GetFiles($ctx.DownloadDir, '*.ipa')).Count 'file appeared after cancel.'
    } finally { $env:FAKE_SLOW = $null }
}

Test 'Error mapping and progress parsing' {
    Assert-Equal 'Err.AuthCode' (Resolve-DreddToolError 'Error: 2FA code is required').Key
    Assert-Equal 'Err.Network' (Resolve-DreddToolError 'Error: Could not resolve host: apple.com').Key
    Assert-Equal 'Err.License' (Resolve-DreddToolError 'Error: license is required').Key
    Assert-Equal 'Err.Unavailable' (Resolve-DreddToolError 'Purchase error: item is temporarily unavailable').Key
    Assert-Equal 'Err.Unknown' (Resolve-DreddToolError 'Something odd').Key
    Assert-Equal 45.5 (Get-DreddProgressFromLine 'downloading 45.5% (10 MB)')
    Assert-Equal 37 (Get-DreddProgressFromLine 'PROGRESS:37')
    Assert-Equal $null (Get-DreddProgressFromLine 'no progress here')
    Assert-Equal $null (Get-DreddProgressFromLine '250%')
    Assert-Equal $null (Get-DreddProgressFromLine 'PROGRESS:250')
}

Test 'Download progress lines do not flood the log; DSID is masked' {
    $ctx = New-TestContext
    $msgs = New-Object System.Collections.Generic.List[object]
    $r = Invoke-DreddDownload -Context $ctx -AppId '1234567' -AppName 'Fake App' -Reporter $msgs
    Assert-True $r.Ok
    Assert-Equal 0 @($msgs | Where-Object { $_.Type -eq 'log' -and $_.Message -match 'PROGRESS' }).Count 'PROGRESS lines written to the log.'
    $pct = @($msgs | Where-Object { $_.Type -eq 'progress' -and $null -ne $_.Value.Percent } | ForEach-Object { $_.Value.Percent })
    # Сообщения из вывода ipatool — без Bytes (тики по размеру папки и финальные 100% идут с Bytes).
    $fromTool = @($msgs | Where-Object { $_.Type -eq 'progress' -and $null -ne $_.Value.Percent -and $null -eq $_.Value.Bytes } | ForEach-Object { $_.Value.Percent })
    Assert-True ($fromTool.Count -gt 0) 'no progress from tool output.'
    Assert-Equal @($fromTool | Select-Object -Unique).Count $fromTool.Count 'repeated progress values are reported more than once.'
    Assert-NotMatch (Protect-LogText '12:00:32 INF dsid=12345678901 header=00 kbsync=AAAA success=true') '12345678901' 'DSID leaked.'
}

# ---------------- Библиотека покупок ----------------

function New-FakeLookup {
    # Подмена iTunes Lookup: возвращает данные только для перечисленных ID; -Fail — сетевая ошибка.
    param([hashtable]$Apps, [switch]$Fail)
    $script:FakeLookupApps = $Apps; $script:FakeLookupFail = [bool]$Fail; $script:FakeLookupUrls = New-Object System.Collections.Generic.List[string]
    return {
        param($url)
        $script:FakeLookupUrls.Add($url)
        if ($script:FakeLookupFail) { throw 'The remote name could not be resolved' }
        $ids = ([regex]::Match($url, 'id=([\d,]+)').Groups[1].Value -split ',')
        $res = @(foreach ($id in $ids) { if ($script:FakeLookupApps.ContainsKey($id)) { $a = $script:FakeLookupApps[$id]; @{ trackId = [long]$id; trackName = $a.Name; version = $a.Version; bundleId = "com.example.$id"; minimumOsVersion = '15.0'; fileSizeBytes = 1048576; sellerName = 'Example'; artworkUrl100 = "https://is1-ssl.mzstatic.com/image/thumb/x/$id/100x100bb.jpg" } } })
        return (@{ resultCount = $res.Count; results = $res } | ConvertTo-Json -Depth 4 -Compress)
    }
}

Test 'Purchase history: only iOS apps, one record per ID, earliest date' {
    $ctx = New-TestContext
    $p = Get-DreddAccountPurchases -Context $ctx
    Assert-True $p.Ok
    Assert-Equal @('2222222', '1111111') @($p.Apps | ForEach-Object { $_.ID }) 'subscriptions/IAP/Mac apps or duplicates not filtered.'
    Assert-Equal ([datetime]'2023-07-09') ($p.Apps[0].SortDate.Date) 'earliest purchase date not kept.'
}

Test 'Purchase library: scan, App Store lookup, statuses, cache without email' {
    $ctx = New-TestContext
    $fetch = New-FakeLookup @{ '2222222' = @{ Name = 'New App'; Version = '3.0' } }
    $r = Update-DreddPurchaseLibrary -Context $ctx -Email 'User@Example.com' -Storefront 'RU' -Fetch $fetch
    Assert-True $r.Ok
    Assert-True $r.LookupOk
    Assert-Match $script:FakeLookupUrls[0] 'country=ru' 'lookup not done in the account region.'
    $path = Get-DreddPurchaseCachePath -Context $ctx -Email 'user@example.com'
    Assert-True ([System.IO.File]::Exists($path)) 'cache not saved (or key depends on email case).'
    Assert-NotMatch $path 'example' 'email in the cache file name.'
    $lib = Read-DreddPurchaseLibrary -Context $ctx -Email 'user@example.com'
    Assert-Equal 2 $lib.Apps.Count
    $new = $lib.Apps | Where-Object { $_.Id -eq '2222222' }
    $old = $lib.Apps | Where-Object { $_.Id -eq '1111111' }
    Assert-Equal 'Available' (Get-DreddPurchaseStatus $new)
    Assert-Equal 'NotInStore' (Get-DreddPurchaseStatus $old) 'missing in App Store must be NotInStore, not "not purchased".'
    Assert-Equal 'Downloaded' (Get-DreddPurchaseStatus $new -LocalVersion '3.0')
    Assert-Equal 'UpdateAvailable' (Get-DreddPurchaseStatus $new -LocalVersion '2.9.1')
    Assert-Equal '2023-07-09' $new.PurchaseDate
}

Test 'Purchase library: failed lookup gives Unverified; attempt errors survive a rescan' {
    $ctx = New-TestContext
    $r = Update-DreddPurchaseLibrary -Context $ctx -Email 'user@example.com' -Storefront 'US' -Fetch (New-FakeLookup @{} -Fail)
    Assert-True $r.Ok 'scan must succeed even if the lookup fails.'
    Assert-False $r.LookupOk
    foreach ($a in $r.Library.Apps) { Assert-Equal 'Unverified' (Get-DreddPurchaseStatus $a) 'lookup failure must not look like NotInStore.' }
    Assert-True (Set-DreddPurchaseAttempt -Context $ctx -Email 'user@example.com' -AppId '1111111' -ErrorKey 'Err.Unavailable' -Message 'item is temporarily unavailable')
    [void](Update-DreddPurchaseLibrary -Context $ctx -Email 'user@example.com' -Storefront 'US' -Fetch (New-FakeLookup @{ '2222222' = @{ Name = 'New App'; Version = '1.0' } }))
    $lib = Read-DreddPurchaseLibrary -Context $ctx -Email 'user@example.com'
    $old = $lib.Apps | Where-Object { $_.Id -eq '1111111' }
    Assert-Equal 'Failed' (Get-DreddPurchaseStatus $old)
    Assert-Equal 'Err.Unavailable' $old.LastErrorKey
    [void](Set-DreddPurchaseAttempt -Context $ctx -Email 'user@example.com' -AppId '1111111' -ErrorKey '')
    $old = (Read-DreddPurchaseLibrary -Context $ctx -Email 'user@example.com').Apps | Where-Object { $_.Id -eq '1111111' }
    Assert-Equal 'NotInStore' (Get-DreddPurchaseStatus $old) 'successful attempt must clear the error.'
    $u = Update-DreddPurchaseLibrary -Context $ctx -Email 'user@example.com' -Storefront '143469-16,29' -Fetch (New-FakeLookup @{})
    Assert-True $u.Ok
    Assert-Equal 0 $script:FakeLookupUrls.Count 'lookup must not guess a region it does not know.'
}

Test 'History: remove selected entries and clear all, files untouched' {
    $ctx = New-TestContext
    Add-DreddHistoryEntry -Context $ctx -Kind Download -AppId '1' -Name 'One' -Result Success
    Add-DreddHistoryEntry -Context $ctx -Kind Install -AppId '2' -Name 'Two' -Result Error
    Add-DreddHistoryEntry -Context $ctx -Kind Download -AppId '3' -Name 'Three' -Result Success
    $h = @(Get-DreddDownloadHistory -Context $ctx)
    $two = $h | Where-Object { $_.Name -eq 'Two' }
    Assert-Equal 1 (Remove-DreddHistoryEntries -Context $ctx -Keys @(Get-DreddHistoryKey $two))
    Assert-Equal @('One', 'Three') @(Get-DreddDownloadHistory -Context $ctx | ForEach-Object { $_.Name } | Sort-Object)
    Assert-Equal 2 (Remove-DreddHistoryEntries -Context $ctx -All)
    Assert-Equal 0 @(Get-DreddDownloadHistory -Context $ctx).Count
}

function New-FakeToolRelease {
    # Архив релиза как у upstream: <root>/MainApp/windows_amd64/ipatool-cpp-*.cmd (печатает "ipatool").
    param([string]$Dir, [string]$Text = 'ipatool-cpp test build')
    $src = Join-Path $Dir 'src'
    $plat = Join-Path $src 'IPA_Downloader_9.9.9\MainApp\windows_amd64'
    [void][System.IO.Directory]::CreateDirectory($plat)
    [System.IO.File]::WriteAllText((Join-Path $plat 'ipatool-cpp-windows-amd64.cmd'), "@echo $Text`r`n")
    $zip = Join-Path $Dir 'release.zip'
    [System.IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    return $zip
}

Test 'Tool update: silent check compares the bundled upstream version' {
    $ctx = New-TestContext
    $ctx.Binaries.RootSource = 'app'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $ctx.AppRoot 'MainApp'))
    [System.IO.File]::WriteAllText((Join-Path $ctx.AppRoot 'MainApp\ipatool-version.txt'), '4.3.3')
    $rel = { param($tag, $digest) $j = @{ tag_name = $tag; assets = @(@{ name = "IPA_Downloader_$tag.zip"; size = 1000; browser_download_url = "https://github.com/x/y/releases/download/$tag/a.zip"; digest = $digest }) } | ConvertTo-Json -Depth 4; { $j }.GetNewClosure() }
    $same = Test-DreddToolUpdate -Context $ctx -Fetch (& $rel '4.3.3' ('sha256:' + ('a' * 64)))
    Assert-True $same.Ok
    Assert-False $same.IsNewer 'same version reported as an update.'
    $newer = Test-DreddToolUpdate -Context $ctx -Fetch (& $rel '4.3.10' ('sha256:' + ('b' * 64)))
    Assert-True $newer.IsNewer '4.3.10 must be newer than 4.3.3.'
    Assert-True $newer.CanInstall
    $noSum = Test-DreddToolUpdate -Context $ctx -Fetch (& $rel '4.4.0' $null)
    Assert-False $noSum.CanInstall 'install without a checksum must be refused.'
    Assert-Equal 'NoChecksum' $noSum.Reason
    $off = Test-DreddToolUpdate -Context $ctx -Fetch { throw 'The remote name could not be resolved' }
    Assert-False $off.Ok
}

Test 'Tool update: checksum is enforced, files replaced with a backup' {
    $ctx = New-TestContext
    $ctx.Binaries.RootSource = 'app'
    $plat = Join-Path $ctx.AppRoot 'MainApp\windows_amd64'
    [void][System.IO.Directory]::CreateDirectory($plat)
    $old = Join-Path $plat 'ipatool-cpp-windows-amd64.cmd'
    [System.IO.File]::WriteAllText($old, "@echo ipatool old`r`n")
    [System.IO.File]::WriteAllText((Join-Path $ctx.AppRoot 'MainApp\ipatool-version.txt'), '4.3.3')
    $zip = New-FakeToolRelease -Dir (Join-Path $TestRoot ('rel_' + [guid]::NewGuid().ToString('N').Substring(0, 6)))
    $sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $release = [pscustomobject]@{ Tag = '9.9.9'; Version = '9.9.9'; Url = ''; Asset = [pscustomobject]@{ Name = 'a.zip'; Url = 'https://example.com/a.zip'; Size = 1; Sha256 = ('0' * 64) } }
    $bad = Install-DreddToolUpdate -Context $ctx -Release $release -ZipPath $zip
    Assert-Equal 'Err.UpdateChecksum' $bad.ErrorKey
    Assert-Match ([System.IO.File]::ReadAllText($old)) 'old' 'file replaced despite a checksum mismatch.'
    $release.Asset.Sha256 = $sha
    $ok = Install-DreddToolUpdate -Context $ctx -Release $release -ZipPath $zip
    Assert-True $ok.Ok "install failed: $($ok.ErrorKey) $($ok.Message)"
    Assert-Match ([System.IO.File]::ReadAllText($old)) 'test build' 'ipatool not replaced.'
    Assert-Match ([System.IO.File]::ReadAllText((Join-Path $ctx.AppRoot 'MainApp_previous\windows_amd64\ipatool-cpp-windows-amd64.cmd'))) 'old' 'no backup of the previous ipatool.'
    Assert-Equal '9.9.9' (Get-DreddToolVersion $ctx)
    Assert-Equal 0 @([System.IO.Directory]::GetDirectories($ctx.TempRoot, 'update_*')).Count 'update temp folder not cleaned.'
}

Test 'First run without binaries: components installed from the release archive' {
    $ctx = New-TestContext
    $ctx.Binaries = [pscustomobject]@{ Root = $null; RootSource = $null; Ipatool = $null; IdeviceInstaller = $null; IdeviceId = $null; IdeviceInfo = $null; MissingDlls = @(); Candidates = @(); Notes = @() }
    $dir = Join-Path $TestRoot ('setup_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $zip = New-FakeToolRelease -Dir $dir
    # В архиве релиза рядом с ipatool лежат инструменты устройств и DLL:
    Remove-Item $zip
    $plat = Join-Path $dir 'src\IPA_Downloader_9.9.9\MainApp\windows_amd64'
    foreach ($f in 'ideviceinstaller.exe', 'idevice_id.exe', 'libplist-2.0.dll') { [System.IO.File]::WriteAllText((Join-Path $plat $f), 'x') }
    [System.IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $dir 'src'), $zip)
    $chk = Test-DreddToolUpdate -Context $ctx -Fetch { '{"tag_name":"9.9.9","assets":[{"name":"a.zip","size":1,"browser_download_url":"https://example.com/a.zip","digest":"sha256:' + ('c' * 64) + '"}]}' }
    Assert-True $chk.NeedsSetup
    Assert-True $chk.CanInstall 'setup must be possible without an own MainApp.'
    $release = [pscustomobject]@{ Tag = '9.9.9'; Version = '9.9.9'; Url = ''; Asset = [pscustomobject]@{ Name = 'a.zip'; Url = 'https://example.com/a.zip'; Size = 1; Sha256 = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() } }
    $r = Install-DreddToolUpdate -Context $ctx -Release $release -ZipPath $zip
    Assert-True $r.Ok "setup failed: $($r.ErrorKey) $($r.Message)"
    foreach ($f in 'ipatool-cpp-windows-amd64.cmd', 'ideviceinstaller.exe', 'idevice_id.exe', 'libplist-2.0.dll') {
        Assert-True ([System.IO.File]::Exists((Join-Path $ctx.AppRoot "MainApp\windows_amd64\$f"))) "$f not installed."
    }
    Assert-False ([System.IO.Directory]::Exists((Join-Path $ctx.AppRoot 'MainApp_previous'))) 'first setup must not create a backup.'
    Assert-Equal '9.9.9' (Get-DreddToolVersion $ctx)
}

Test 'Queue state: saved per account, empty queue removes the file' {
    $ctx = New-TestContext
    $a = Get-DreddAccountKey 'a@example.com'; $b = Get-DreddAccountKey 'b@example.com'
    Save-DreddQueue -Context $ctx -Items @(
        [pscustomobject]@{ AppId = '111'; AppName = 'One'; VersionId = ''; VersionText = ''; Purchase = $false; InstallUdid = 'UDID-1'; InstallDevice = 'iPhone'; AccountKey = $a },
        [pscustomobject]@{ AppId = '222'; AppName = 'Two'; VersionId = '9'; VersionText = '2.0'; Purchase = $true; InstallUdid = ''; InstallDevice = ''; AccountKey = $b },
        [pscustomobject]@{ AppId = 'bad'; AppName = 'Bad'; AccountKey = $a })
    $mine = @(Read-DreddQueue -Context $ctx -AccountKey $a)
    Assert-Equal 1 $mine.Count 'queue of another account or invalid ID returned.'
    Assert-Equal 'UDID-1' $mine[0].InstallUdid 'install target lost.'
    Assert-Equal 2 @(Read-DreddQueue -Context $ctx).Count
    Assert-NotMatch ([System.IO.File]::ReadAllText((Join-Path $ctx.FilesDir 'Queue.json'))) 'example\.com' 'email stored in the queue file.'
    Save-DreddQueue -Context $ctx -Items @()
    Assert-False ([System.IO.File]::Exists((Join-Path $ctx.FilesDir 'Queue.json'))) 'empty queue must remove the file.'
}

Test 'Version comparison' {
    Assert-Equal -1 (Compare-DreddVersion '1.2' '1.10')
    Assert-Equal 0 (Compare-DreddVersion '2.0' '2.0.0')
    Assert-Equal 1 (Compare-DreddVersion '26.17.3' '26.9')
    Assert-Equal $null (Compare-DreddVersion '1.0b' '1.0')
}

# ---------------- Диагностика и локализация ----------------

Test 'Diagnostic report contains no email or Windows user name' {
    $ctx = New-TestContext
    $ctx.Settings['RemoteListBaseUrl'] = 'https://example.com/me@example.com/'
    $rep = New-DreddDiagnosticReport -Context $ctx
    Assert-NotMatch $rep '[\w.+-]{2,}@example\.com' 'email in report.'
    if ([Environment]::UserName.Length -ge 3) { Assert-NotMatch $rep ([regex]::Escape([Environment]::UserName)) 'user name in report.' }
    Assert-Match $rep '\[Checks\]'
}

Test 'Localization: RU and EN have the same keys; every key used in XAML and GUI code exists' {
    $ru = Get-DreddStrings -Language RU
    $en = Get-DreddStrings -Language EN
    $onlyRu = @($ru.Keys | Where-Object { -not $en.ContainsKey($_) })
    $onlyEn = @($en.Keys | Where-Object { -not $ru.ContainsKey($_) })
    Assert-Equal 0 ($onlyRu.Count + $onlyEn.Count) ("RU only: $($onlyRu -join ', '); EN only: $($onlyEn -join ', ')")
    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $appRoot 'src/GUI') -Recurse -Filter '*.xaml') {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($t, 'x:Uid="([^"]+)"')) { [void]$used.Add($m.Groups[1].Value) }
        foreach ($m in [regex]::Matches($t, '"@([A-Za-z][\w.]+)"')) { [void]$used.Add($m.Groups[1].Value) }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $appRoot 'src/GUI') -Recurse -Filter '*.ps1') + @(Get-Item (Join-Path $appRoot 'IPA_Dredd.ps1'))) {
        $t = [System.IO.File]::ReadAllText($f.FullName)
        foreach ($m in [regex]::Matches($t, "\b(?:T|TF)\s+'([A-Za-z][\w.]+)'")) { [void]$used.Add($m.Groups[1].Value) }
    }
    foreach ($p in 'Dashboard', 'Catalog', 'Downloads', 'Library', 'Devices', 'Accounts', 'Settings', 'Diagnostics') { [void]$used.Add("Page.$p.Title"); [void]$used.Add("Page.$p.Subtitle") }
    foreach ($s in 'Queued', 'Running', 'Done', 'Error', 'Cancelled') { [void]$used.Add("Status.$s") }
    foreach ($s in 'app', 'v4.2', 'v4.1', 'settings') { [void]$used.Add("Source.$s") }
    foreach ($s in 'Popular', 'Custom', 'AppStore', 'ID', 'Purchases', 'Script') { [void]$used.Add("Source.App.$s") }
    foreach ($s in 'Ready', 'NotTrusted', 'Error') { [void]$used.Add("Device.Status.$s") }
    foreach ($c in (Get-DreddDiagnostics -Context (New-TestContext))) { [void]$used.Add("Diag.Check.$($c.Id)"); [void]$used.Add($c.HintKey) }
    foreach ($id in 'Dlls', 'AppleDriver') { [void]$used.Add("Diag.Check.$id") }
    # Ключи ошибок, которые возвращает Core:
    $coreText = (Get-ChildItem -LiteralPath (Join-Path $appRoot 'src/Core') -Filter '*.ps1' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
    foreach ($m in [regex]::Matches($coreText, "'(Err\.[A-Za-z]+)'")) { [void]$used.Add($m.Groups[1].Value) }
    foreach ($m in [regex]::Matches($coreText, "'(Diag\.Hint\.[A-Za-z]+)'")) { [void]$used.Add($m.Groups[1].Value) }
    $missing = @($used | Where-Object { -not $ru.ContainsKey($_) } | Sort-Object)
    Assert-Equal 0 $missing.Count ("Missing keys: " + ($missing -join ', '))
}

# Уборка
Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
$env:FAKE_STATE_DIR = $null; $env:FAKE_IPATOOL_HOME = $null

# Устройства iPhone/iPad по кабелю и по Wi-Fi: idevice_id, ideviceinfo, ideviceinstaller (поведение 4.2 + модель, статус, подключение).
# Wi-Fi (-n) работает только для устройства, которое уже сопряжено с этим ПК по кабелю и у которого включена
# синхронизация по Wi-Fi («Apple Devices»/iTunes → «Показывать этот iPhone при подключении к Wi-Fi»).

function ConvertTo-DreddIosVersion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -notmatch '^\d+(\.\d+){0,3}$') { return $null }
    $parts = @($t -split '\.')
    while ($parts.Count -lt 2) { $parts += '0' }
    return [version]($parts -join '.')
}

function Test-DreddIosCompatible {
    # $true — совместимо, $false — устройство старее требуемого, $null — сравнить нельзя.
    param([string]$MinIOS, [string]$DeviceVersion)
    $req = ConvertTo-DreddIosVersion $MinIOS
    $dev = ConvertTo-DreddIosVersion $DeviceVersion
    if ($null -eq $req -or $null -eq $dev) { return $null }
    return ($dev -ge $req)
}

function Get-DreddDeviceToolEnv {
    param($Context)
    $root = $null
    if ($Context.Binaries.IdeviceId) { $root = [System.IO.Path]::GetDirectoryName($Context.Binaries.IdeviceId) }
    elseif ($Context.Binaries.IdeviceInstaller) { $root = [System.IO.Path]::GetDirectoryName($Context.Binaries.IdeviceInstaller) }
    if (-not $root) { return @{} }
    return @{ PATH = ($root + [System.IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PATH')) }
}

function ConvertFrom-DreddUdidList {
    # Вывод idevice_id -l / -n → список UDID. Строка может быть «UDID» или «UDID (USB|Network)».
    param([string]$Text)
    return @($Text -split "`r?`n" | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ -match '^[0-9A-Fa-f-]{20,}$' } | Select-Object -Unique)
}

function Get-DreddDevices {
    <#
      Список подключённых устройств: UDID, Name, ProductType, iOSVersion, Status (Ready | NotTrusted | Error), Detail,
      Connection (usb | network). Ищет по кабелю (idevice_id -l) и по сети (idevice_id -n); устройство, видимое и так и так, — usb.
      Возвращает объект: Ok, Devices, ErrorKey, Message.
    #>
    param([Parameter(Mandatory)]$Context, $Reporter, $CancellationToken)
    $b = $Context.Binaries
    if (-not $b.IdeviceId) {
        return [pscustomobject]@{ Ok = $false; Devices = @(); ErrorKey = 'Err.NoIdeviceId'; Message = '' }
    }
    $env1 = Get-DreddDeviceToolEnv $Context
    $list = Invoke-DreddProcess -FilePath $b.IdeviceId -ArgumentList @('-l') -TimeoutSec 20 -CancellationToken $CancellationToken -Environment $env1
    if ($list.Cancelled) { return [pscustomobject]@{ Ok = $false; Devices = @(); ErrorKey = 'Err.Cancelled'; Message = '' } }
    $usb = ConvertFrom-DreddUdidList $list.StdOut
    $net = @()
    $netList = Invoke-DreddProcess -FilePath $b.IdeviceId -ArgumentList @('-n') -TimeoutSec 20 -CancellationToken $CancellationToken -Environment $env1
    if ($netList.Cancelled) { return [pscustomobject]@{ Ok = $false; Devices = @(); ErrorKey = 'Err.Cancelled'; Message = '' } }
    if ($netList.ExitCode -eq 0) { $net = @(ConvertFrom-DreddUdidList $netList.StdOut | Where-Object { $usb -notcontains $_ }) }
    Write-DreddReport -Reporter $Reporter -Type log -Level Debug -Area 'Devices' -Message ("USB: {0}, Wi-Fi: {1}" -f $usb.Count, $net.Count)
    if ($list.ExitCode -ne 0 -and $usb.Count -eq 0 -and $net.Count -eq 0) {
        $msg = (Protect-LogText $list.Output).Trim()
        Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Devices' -Message ("idevice_id: exit {0} {1}" -f $list.ExitCode, $msg)
        # usbmuxd/драйвер Apple недоступен — отличаем от «нет устройств», если есть понятный текст.
        $key = 'Err.NoDevices'
        if ($msg -match '(?i)(usbmux|unable to connect|could not connect|no such file)') { $key = 'Err.UsbMux' }
        return [pscustomobject]@{ Ok = $false; Devices = @(); ErrorKey = $key; Message = $msg }
    }

    $found = @($usb | ForEach-Object { @{ Udid = $_; Conn = 'usb' } }) + @($net | ForEach-Object { @{ Udid = $_; Conn = 'network' } })
    $devices = foreach ($f in $found) {
        if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { break }
        $udid = $f.Udid
        $netArg = @(if ($f.Conn -eq 'network') { '-n' })
        $d = [ordered]@{ UDID = $udid; Name = $null; ProductType = $null; iOSVersion = $null; DeviceClass = $null; Status = 'Ready'; Detail = ''; Connection = $f.Conn }
        if ($f.Conn -eq 'usb') {
            # Имя по сети даёт ideviceinfo (DeviceName), отдельный запрос idevice_id не нужен.
            $n = Invoke-DreddProcess -FilePath $b.IdeviceId -ArgumentList @($udid) -TimeoutSec 15 -CancellationToken $CancellationToken -Environment $env1
            if ($n.ExitCode -eq 0) { $d.Name = ($n.StdOut.Trim() -split "`r?`n" | Select-Object -First 1) }
        }
        if ($b.IdeviceInfo) {
            $i = Invoke-DreddProcess -FilePath $b.IdeviceInfo -ArgumentList ($netArg + @('-u', $udid)) -TimeoutSec 20 -CancellationToken $CancellationToken -Environment $env1
            if ($i.ExitCode -eq 0) {
                foreach ($line in ($i.StdOut -split "`r?`n")) {
                    if ($line -match '^(\w+):\s*(.*)$') {
                        switch ($Matches[1]) {
                            'DeviceName' { if (-not $d.Name) { $d.Name = $Matches[2].Trim() } }
                            'ProductType' { $d.ProductType = $Matches[2].Trim() }
                            'ProductVersion' { $d.iOSVersion = $Matches[2].Trim() }
                            'DeviceClass' { $d.DeviceClass = $Matches[2].Trim() }
                        }
                    }
                }
            } else {
                $txt = (Protect-LogText $i.Output).Trim()
                $d.Detail = $txt
                if ($txt -match '(?i)(pair|trust|lockdown|password protected|invalid host)') { $d.Status = 'NotTrusted' } else { $d.Status = 'Error' }
            }
        }
        if (-not $d.Name) { $d.Name = 'iOS device' }
        [pscustomobject]$d
    }
    $devices = @($devices)
    return [pscustomobject]@{ Ok = $true; Devices = $devices; ErrorKey = $(if ($devices.Count -eq 0) { 'Err.NoDevices' } else { $null }); Message = '' }
}

function Install-DreddIpa {
    <#
      Установка IPA на устройство: копия во временную папку (ASCII-путь, как Temp.ipa в 4.2) → install, при ошибке upgrade.
      Результат: Ok, ErrorKey, Message, Output.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$IpaPath,
        [string]$UDID,
        $Reporter,
        $CancellationToken
    )
    $inst = $Context.Binaries.IdeviceInstaller
    if (-not $inst) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.NoInstaller'; Message = ''; Output = '' } }
    if (-not [System.IO.File]::Exists($IpaPath)) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.NoFile'; Message = $IpaPath; Output = '' } }

    $temp = Join-Path $Context.TempRoot ('install_' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($temp)
    $tmpIpa = Join-Path $temp 'app.ipa'
    $env1 = Get-DreddDeviceToolEnv $Context
    $dreddInstReporter = $Reporter
    $onLine = {
        param($line, $stream)
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        $p = Get-DreddProgressFromLine $line
        if ($null -ne $p) { Write-DreddReport -Reporter $dreddInstReporter -Type progress -Area 'Install' -Value @{ Percent = $p } }
        Write-DreddReport -Reporter $dreddInstReporter -Type log -Level Debug -Area 'Install' -Message $line
    }
    try {
        [System.IO.File]::Copy($IpaPath, $tmpIpa, $true)
        $r = $null
        $conn = $null
        # До трёх попыток: iPad/iPhone мог на время пропасть из usbmuxd (блокировка, переподключение USB-C, хаб),
        # а по Wi-Fi заблокированный iPhone «засыпает» и lockdownd не отвечает («Mux error»).
        $maxAttempts = 3
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            $baseArgs = @()
            if ($UDID) {
                # Где устройство сейчас: по кабелю (-l) или по сети (-n). Ждём до ~10 с, пока оно появится.
                $conn = Wait-DreddDeviceConnection -Context $Context -Udid $UDID -TimeoutSec 10 -CancellationToken $CancellationToken
                if (-not $conn) {
                    if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.Cancelled'; Message = ''; Output = '' } }
                    return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.DeviceGone'; Message = "No device found with udid $UDID"; Output = '' }
                }
                $baseArgs = @('-u', $UDID)
                if ($conn -eq 'network') { $baseArgs += '-n'; Write-DreddReport -Reporter $Reporter -Type log -Level Info -Area 'Install' -Message 'Wi-Fi' }
            }
            $r = Invoke-DreddProcess -FilePath $inst -ArgumentList ($baseArgs + @('install', $tmpIpa)) -TimeoutSec 900 -CancellationToken $CancellationToken -OnLine $onLine -Environment $env1
            if ($r.Cancelled) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.Cancelled'; Message = ''; Output = $r.Output } }
            # Нет связи с устройством — upgrade не поможет, сразу к повтору.
            if ($r.ExitCode -ne 0 -and $r.Output -notmatch $script:ReDeviceConnError) {
                Write-DreddReport -Reporter $Reporter -Type log -Level Info -Area 'Install' -Message 'install → upgrade'
                $r = Invoke-DreddProcess -FilePath $inst -ArgumentList ($baseArgs + @('upgrade', $tmpIpa)) -TimeoutSec 900 -CancellationToken $CancellationToken -OnLine $onLine -Environment $env1
                if ($r.Cancelled) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.Cancelled'; Message = ''; Output = $r.Output } }
            }
            if ($attempt -lt $maxAttempts -and $r.Output -match $script:ReDeviceConnError) {
                Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Install' -Message ("device not responding ({0}), retry {1}/{2}" -f $conn, $attempt, ($maxAttempts - 1))
                if ($conn -eq 'network') { Write-DreddReport -Reporter $Reporter -Type status -Area 'Install' -Message 'wifiwait' }
                for ($w = 0; $w -lt (3 * $attempt); $w++) {
                    if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.Cancelled'; Message = ''; Output = '' } }
                    Start-Sleep -Seconds 1
                }
                continue
            }
            break
        }
        # Некоторые сборки ideviceinstaller возвращают 0 при ERROR в выводе — проверяем текст.
        $failedText = $r.Output -match '(?im)^\s*(ERROR|Error:)'
        if ($r.ExitCode -eq 0 -and -not $failedText) {
            return [pscustomobject]@{ Ok = $true; ErrorKey = $null; Message = ''; Output = (Protect-LogText $r.Output) }
        }
        $msg = (Protect-LogText $r.Output).Trim()
        $lastLine = @($msg -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        $key = Get-DreddDeviceErrorKey -Text $msg -Connection $conn
        if (-not $key) { $key = 'Err.InstallFailed' }
        return [pscustomobject]@{ Ok = $false; ErrorKey = $key; Message = ($lastLine -join ''); Output = $msg }
    } finally {
        try { if ([System.IO.Directory]::Exists($temp)) { [System.IO.Directory]::Delete($temp, $true) } } catch { }
    }
}

# Нет связи с устройством (а не отказ установки): пропало из usbmuxd или по Wi-Fi не отвечает lockdownd.
$script:ReDeviceConnError = '(?i)(No device found|device not found|Mux error)'

function Get-DreddDeviceErrorKey {
    <#
      Ключ ошибки по выводу libimobiledevice с учётом подключения ($null — не ошибка связи/доверия):
        «Mux error» по Wi-Fi — iPhone заблокирован/уснул или вне сети (Err.WifiUnreachable), а не «нет доверия»;
        pair/trust/password protected/invalid host — Err.NotTrusted; устройство пропало — Err.DeviceGone.
    #>
    param([string]$Text, [string]$Connection)
    if ($Text -match '(?i)(pairing|not paired|trust|password protected|invalid host|user denied)') { return 'Err.NotTrusted' }
    if ($Text -match $script:ReDeviceConnError -or $Text -match '(?i)Could not connect to lockdownd') {
        if ($Connection -eq 'network') { return 'Err.WifiUnreachable' }
        if ($Text -match '(?i)(No device found|device not found|Mux error)') { return 'Err.DeviceGone' }
        return 'Err.NotTrusted'
    }
    return $null
}

function Get-DreddDeviceConnection {
    # 'usb' — устройство видно по кабелю, 'network' — по Wi-Fi (синхронизация по сети), $null — не видно.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Udid, $CancellationToken)
    $id = $Context.Binaries.IdeviceId
    if (-not $id) { return 'usb' }   # без idevice_id проверить нельзя — пробуем как раньше
    $env1 = Get-DreddDeviceToolEnv $Context
    foreach ($mode in @(@('-l', 'usb'), @('-n', 'network'))) {
        $r = Invoke-DreddProcess -FilePath $id -ArgumentList @($mode[0]) -TimeoutSec 15 -CancellationToken $CancellationToken -Environment $env1
        $found = @($r.StdOut -split "`r?`n" | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ -and $_.Equals($Udid, [StringComparison]::OrdinalIgnoreCase) })
        if ($found.Count -gt 0) { return $mode[1] }
    }
    return $null
}

function Wait-DreddDeviceConnection {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Udid, [int]$TimeoutSec = 10, $CancellationToken)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        $c = Get-DreddDeviceConnection -Context $Context -Udid $Udid -CancellationToken $CancellationToken
        if ($c) { return $c }
        if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { return $null }
        Start-Sleep -Seconds 2
    } while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec)
    return $null
}

# ---------------- Приложения на устройстве ----------------

function ConvertFrom-DreddDeviceAppsXml {
    # XML-вывод «ideviceinstaller list --xml» → записи BundleId, Version, Build, Name, ItemId.
    # $null, если это не plist-массив; иначе массив (возможно, пустой — на устройстве нет приложений) одним объектом.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $start = $Text.IndexOf('<?xml')
    if ($start -lt 0) { $start = $Text.IndexOf('<plist') }
    if ($start -lt 0) { return $null }
    $end = $Text.LastIndexOf('</plist>')
    if ($end -lt $start) { return $null }
    $xml = $Text.Substring($start, $end - $start + 8)
    try { $root = [IPADredd.PlistReader]::Parse([System.Text.Encoding]::UTF8.GetBytes($xml)) } catch { return $null }
    if (-not ($root -is [System.Collections.IList])) { return $null }
    $apps = foreach ($d in $root) {
        $bid = [IPADredd.PlistReader]::GetString($d, 'CFBundleIdentifier')
        if (-not $bid) { continue }
        $name = [IPADredd.PlistReader]::GetString($d, 'CFBundleDisplayName')
        if (-not $name) { $name = [IPADredd.PlistReader]::GetString($d, 'CFBundleName') }
        $itemId = $null
        # iTunesMetadata (data) — plist App Store с itemId: по нему сопоставляем даже без bundle id из Lookup.
        $meta = $null
        if ($d -is [System.Collections.IDictionary] -and ([System.Collections.IDictionary]$d).Contains('iTunesMetadata')) { $meta = $d['iTunesMetadata'] }
        if ($meta -is [byte[]] -and $meta.Length -gt 8) {
            try { $itemId = [IPADredd.PlistReader]::GetString([IPADredd.PlistReader]::Parse($meta), 'itemId') } catch { $itemId = $null }
        }
        [pscustomobject]@{
            BundleId = $bid; Name = [string]$name
            Version = [string][IPADredd.PlistReader]::GetString($d, 'CFBundleShortVersionString')
            Build = [string][IPADredd.PlistReader]::GetString($d, 'CFBundleVersion')
            ItemId = $(if ($itemId -match '^\d+$') { $itemId } else { $null })
        }
    }
    $list = @($apps | Where-Object { $_ })
    return , $list
}

function ConvertFrom-DreddDeviceAppsText {
    <#
      Текстовый вывод «ideviceinstaller list» → записи. Понимает оба формата:
        1.1.1+:  CFBundleIdentifier, CFBundleShortVersionString, CFBundleDisplayName   (заголовок)
                 com.example.app, "1.2.3", "Example"
        1.1.0:   Total: N apps
                 com.example.app - Example 1.2.3
    #>
    param([string]$Text)
    $apps = foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l -or $l -match '^(CFBundleIdentifier|Total:)') { continue }
        if ($l -match '^([A-Za-z0-9][A-Za-z0-9._-]*),\s*"([^"]*)"(?:,\s*"(.*)")?$') {
            [pscustomobject]@{ BundleId = $Matches[1]; Version = $Matches[2]; Build = ''; Name = [string]$Matches[3]; ItemId = $null }
        } elseif ($l -match '^([A-Za-z0-9][A-Za-z0-9._-]*)\s+-\s+(.*?)\s+(\S+)$') {
            [pscustomobject]@{ BundleId = $Matches[1]; Version = $Matches[3]; Build = ''; Name = $Matches[2]; ItemId = $null }
        }
    }
    return $apps
}

function Get-DreddDeviceApps {
    <#
      Пользовательские приложения на устройстве (ideviceinstaller list --user). Результат: Ok, Apps, Format, ErrorKey, Message.
      Форматы вывода разных сборок ideviceinstaller различаются, поэтому три попытки:
        1) XML + iTunesMetadata (App Store ID); 2) XML без него; 3) текст.
      Если ни одна не разобралась — Ok = $false и начало вывода в журнале (без личных данных).
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Udid, [string]$Connection, $Reporter, $CancellationToken)
    $inst = $Context.Binaries.IdeviceInstaller
    if (-not $inst) { return [pscustomobject]@{ Ok = $false; Apps = @(); Format = $null; ErrorKey = 'Err.NoInstaller'; Message = '' } }
    if (-not $Connection) { $Connection = Get-DreddDeviceConnection -Context $Context -Udid $Udid -CancellationToken $CancellationToken }
    if (-not $Connection) { return [pscustomobject]@{ Ok = $false; Apps = @(); Format = $null; ErrorKey = 'Err.DeviceGone'; Message = '' } }
    $base = @('-u', $Udid)
    if ($Connection -eq 'network') { $base += '-n' }
    $attrs = @('-a', 'CFBundleIdentifier', '-a', 'CFBundleShortVersionString', '-a', 'CFBundleVersion', '-a', 'CFBundleDisplayName', '-a', 'CFBundleName')
    $tries = @(
        @{ Format = 'xml+meta'; Args = (@('list', '--user', '--xml') + $attrs + @('-a', 'iTunesMetadata')) },
        @{ Format = 'xml'; Args = (@('list', '--user', '--xml') + $attrs) },
        @{ Format = 'text'; Args = @('list', '--user') }
    )
    $env1 = Get-DreddDeviceToolEnv $Context
    $last = $null
    foreach ($t in $tries) {
        $r = Invoke-DreddProcess -FilePath $inst -ArgumentList ($base + $t.Args) -TimeoutSec 180 -CancellationToken $CancellationToken -Environment $env1
        $last = $r
        if ($r.Cancelled) { return [pscustomobject]@{ Ok = $false; Apps = @(); Format = $null; ErrorKey = 'Err.Cancelled'; Message = '' } }
        if ($r.ExitCode -ne 0 -or $r.Output -match $script:ReDeviceConnError) {
            $ek = Get-DreddDeviceErrorKey -Text $r.Output -Connection $Connection
            if ($ek) { return [pscustomobject]@{ Ok = $false; Apps = @(); Format = $null; ErrorKey = $ek; Message = (Protect-LogText $r.Output).Trim() } }
        }
        $apps = $null
        if ($r.ExitCode -eq 0) {
            if ($t.Format -eq 'text') {
                $apps = @(ConvertFrom-DreddDeviceAppsText $r.StdOut)
                # Пустой текстовый список при непустом выводе — формат не распознан, а не «ничего не установлено».
                if ($apps.Count -eq 0 -and @($r.StdOut -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^\s*(CFBundleIdentifier|Total:)' }).Count -gt 0) { $apps = $null }
            } else { $apps = ConvertFrom-DreddDeviceAppsXml $r.StdOut }
        }
        if ($null -ne $apps) {
            $apps = @($apps)
            Write-DreddReport -Reporter $Reporter -Type log -Level Info -Area 'Devices' -Message ("ideviceinstaller list: {0} apps ({1})" -f $apps.Count, $t.Format)
            return [pscustomobject]@{ Ok = $true; Apps = $apps; Format = $t.Format; ErrorKey = $null; Message = '' }
        }
        $head = Protect-LogText $r.Output
        if ($head.Length -gt 300) { $head = $head.Substring(0, 300) + '…' }
        Write-DreddReport -Reporter $Reporter -Type log -Level Debug -Area 'Devices' -Message ("ideviceinstaller list ({0}): exit {1}, not parsed: {2}" -f $t.Format, $r.ExitCode, $head)
    }
    $msg = (Protect-LogText $last.Output).Trim()
    if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) + '…' }
    Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Devices' -Message ("ideviceinstaller list: output not recognized: {0}" -f $msg)
    return [pscustomobject]@{ Ok = $false; Apps = @(); Format = $null; ErrorKey = 'Err.DeviceAppsFormat'; Message = $msg }
}

function Compare-DreddDeviceApps {
    <#
      Сопоставляет покупки с приложениями на устройстве. Возвращает hashtable App Store ID → { State; DeviceVersion }.
        Installed — стоит на устройстве;  Outdated — стоит, но в App Store версия новее;
        Missing   — на устройстве нет;    Unknown  — сопоставить нельзя (нет bundle id: снято с продажи и не скачано).
      Сопоставление: App Store ID из iTunesMetadata устройства, иначе bundle id (из Lookup или из скачанного IPA — -LocalBundles: ID → bundle id).
    #>
    param([object[]]$Apps, [object[]]$DeviceApps, [hashtable]$LocalBundles = @{})
    $byItem = @{}; $byBundle = @{}
    $hasItemIds = $false
    foreach ($d in @($DeviceApps)) {
        if (-not $d) { continue }
        if ($d.ItemId) {
            $byItem[[string]$d.ItemId] = $d
            # Synthetic — запись, добавленная программой после установки, а не полученная от устройства.
            if (-not ($d.PSObject.Properties['Synthetic'] -and $d.Synthetic)) { $hasItemIds = $true }
        }
        if ($d.BundleId) { $byBundle[$d.BundleId.ToLowerInvariant()] = $d }
    }
    # Если устройство отдало App Store ID, отсутствие ID среди них означает «не установлено» и без bundle id.
    $res = @{}
    foreach ($a in @($Apps)) {
        if (-not $a -or -not $a.Id) { continue }
        $id = [string]$a.Id
        $dev = $byItem[$id]
        $bundle = if ($a.BundleId) { [string]$a.BundleId } elseif ($LocalBundles.ContainsKey($id)) { [string]$LocalBundles[$id] } else { '' }
        if (-not $dev -and $bundle) { $dev = $byBundle[$bundle.ToLowerInvariant()] }
        if ($dev) {
            $state = 'Installed'
            if ($a.Lookup -eq 'Found' -and (Compare-DreddVersion $dev.Version $a.Version) -eq -1) { $state = 'Outdated' }
            $res[$id] = [pscustomobject]@{ State = $state; DeviceVersion = [string]$dev.Version }
        } elseif ($bundle -or $hasItemIds) {
            $res[$id] = [pscustomobject]@{ State = 'Missing'; DeviceVersion = '' }
        } else {
            $res[$id] = [pscustomobject]@{ State = 'Unknown'; DeviceVersion = '' }
        }
    }
    return $res
}
# Библиотека покупок Apple ID: история покупок (ipatool list-purchases --all) + публичный iTunes Lookup API.
# Кэш по аккаунту: Files/Purchases/<хеш email>.json (email в имени файла не хранится, см. docs/SECURITY.md).
#
# Что известно достоверно и что нет (AUDIT_4.4.md §4):
#   • запись в истории = аккаунт когда-то купил/получил приложение;
#   • Lookup по региону аккаунта: есть ли приложение в App Store сейчас (Found) или нет (Missing);
#   • «нельзя скачать» известно только после реальной неудачной попытки (LastErrorKey);
#   • устанавливалось ли приложение на устройство — по истории узнать нельзя.

$script:PurchaseLibraryFormat = 1
$script:LookupBatchSize = 150

function Get-DreddAccountKey {
    # Имя файла кэша: первые 16 символов SHA-256 от email в нижнем регистре.
    param([Parameter(Mandatory)][string]$Email)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Email.Trim().ToLowerInvariant())) } finally { $sha.Dispose() }
    return (($bytes | Select-Object -First 8 | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-DreddPurchaseCachePath {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email)
    return Join-Path (Join-Path $Context.FilesDir 'Purchases') ((Get-DreddAccountKey $Email) + '.json')
}

function Get-DreddIconFolder {
    param([Parameter(Mandatory)]$Context)
    return Join-Path $Context.FilesDir 'Cache\Icons'
}

function Get-DreddIconPath {
    # Путь к сохранённой иконке или $null.
    param([Parameter(Mandatory)]$Context, [string]$AppId)
    if ($AppId -notmatch '^\d+$') { return $null }
    $p = Join-Path (Get-DreddIconFolder $Context) "$AppId.jpg"
    if ([System.IO.File]::Exists($p)) { return $p }
    return $null
}

function ConvertTo-DreddCountryCode {
    # Регион аккаунта из auth info → двухбуквенный код для Lookup. Иное значение — $null (статусы «не удалось проверить»).
    param([string]$Storefront)
    if ($Storefront -and $Storefront.Trim() -match '^[A-Za-z]{2}$') { return $Storefront.Trim().ToLowerInvariant() }
    return $null
}

function Compare-DreddVersion {
    # -1 / 0 / 1 для версий вида 1.2.3; $null, если версии нельзя сравнить численно.
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $null }
    $pa = @($A.Trim() -split '\.'); $pb = @($B.Trim() -split '\.')
    if (@($pa + $pb | Where-Object { $_ -notmatch '^\d+$' }).Count -gt 0) {
        if ($A.Trim() -eq $B.Trim()) { return 0 }
        return $null
    }
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $pa.Count) { [long]$pa[$i] } else { 0L }
        $y = if ($i -lt $pb.Count) { [long]$pb[$i] } else { 0L }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

function New-DreddPurchaseRecord {
    param([string]$Id, [string]$Name)
    [pscustomobject][ordered]@{
        Id = $Id; Name = $Name; PurchaseDate = ''; Price = ''
        Lookup = 'Unknown'; LookupAt = ''
        StoreName = ''; Version = ''; BundleId = ''; MinIOS = ''; SizeBytes = 0L; Artist = ''; ArtworkUrl = ''
        LastErrorKey = ''; LastErrorMessage = ''; LastAttemptAt = ''
    }
}

function ConvertTo-DreddPurchaseRecord {
    # Запись из JSON кэша → объект со всеми полями (старые кэши без новых полей тоже читаются).
    param($Item)
    $r = New-DreddPurchaseRecord -Id ([string](Get-DreddProp $Item 'Id')) -Name ([string](Get-DreddProp $Item 'Name'))
    foreach ($p in @($r.PSObject.Properties)) {
        if ($p.Name -in 'Id', 'Name') { continue }
        $v = Get-DreddProp $Item $p.Name $null
        if ($null -ne $v) { $r.($p.Name) = $(if ($p.Name -eq 'SizeBytes') { [long]$v } else { [string]$v }) }
    }
    return $r
}

function Read-DreddPurchaseLibrary {
    # Кэш библиотеки покупок аккаунта или $null, если сканирования ещё не было.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email)
    $data = Read-DreddJsonFile -Path (Get-DreddPurchaseCachePath -Context $Context -Email $Email)
    if ($null -eq $data) { return $null }
    $apps = @(@(Get-DreddProp $data 'Apps' @()) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-DreddPurchaseRecord $_ } | Where-Object { $_.Id })
    [pscustomobject]@{
        Storefront = [string](Get-DreddProp $data 'Storefront' '')
        ScannedAt  = [string](Get-DreddProp $data 'ScannedAt' '')
        LookupOk   = [bool](Get-DreddProp $data 'LookupOk' $false)
        Apps       = $apps
    }
}

function Save-DreddPurchaseLibrary {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email, [Parameter(Mandatory)]$Library)
    $obj = [ordered]@{
        Format = $script:PurchaseLibraryFormat; Storefront = [string]$Library.Storefront; ScannedAt = [string]$Library.ScannedAt
        LookupOk = [bool]$Library.LookupOk; Apps = @($Library.Apps)
    }
    Write-DreddTextFile -Path (Get-DreddPurchaseCachePath -Context $Context -Email $Email) -Content (ConvertTo-Json -InputObject $obj -Depth 4)
}

function Invoke-DreddStoreLookup {
    <#
      Публичный iTunes Lookup API пачками. Возвращает Ok (все пачки ответили), Found (hashtable ID → данные), Failed (ID без ответа).
      ID, которых нет ни в Found, ни в Failed, — запрос прошёл, но App Store их в этом регионе не знает.
    #>
    param([string[]]$Ids, [Parameter(Mandatory)][string]$Country, $Reporter, $CancellationToken, [scriptblock]$Fetch)
    if (-not $Fetch) { $Fetch = { param($url) Invoke-DreddWebText -Url $url -TimeoutSec 30 } }
    $found = @{}
    $failed = New-Object System.Collections.Generic.List[string]
    $ids2 = @($Ids | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
    for ($i = 0; $i -lt $ids2.Count; $i += $script:LookupBatchSize) {
        $batch = @($ids2[$i..([Math]::Min($i + $script:LookupBatchSize, $ids2.Count) - 1)])
        if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { foreach ($b in $batch) { $failed.Add($b) }; continue }
        $url = 'https://itunes.apple.com/lookup?entity=software&country={0}&id={1}' -f [uri]::EscapeDataString($Country), ($batch -join ',')
        try {
            $json = (& $Fetch $url) | ConvertFrom-Json
            foreach ($res in @(Get-DreddProp $json 'results' @())) {
                $tid = [string](Get-DreddProp $res 'trackId')
                if (-not $tid) { continue }
                $art = [string](Get-DreddProp $res 'artworkUrl100' (Get-DreddProp $res 'artworkUrl60' ''))
                $found[$tid] = [pscustomobject]@{
                    Name = [string](Get-DreddProp $res 'trackName'); Version = [string](Get-DreddProp $res 'version')
                    BundleId = [string](Get-DreddProp $res 'bundleId'); MinIOS = [string](Get-DreddProp $res 'minimumOsVersion')
                    SizeBytes = [long](Get-DreddProp $res 'fileSizeBytes' 0); Artist = [string](Get-DreddProp $res 'sellerName' (Get-DreddProp $res 'artistName' ''))
                    ArtworkUrl = $art
                }
            }
        } catch {
            foreach ($b in $batch) { $failed.Add($b) }
            Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Purchases' -Message ("App Store lookup: " + $_.Exception.Message)
        }
        Write-DreddReport -Reporter $Reporter -Type status -Area 'Purchases' -Message 'lookup' -Value @{ Done = [Math]::Min($i + $batch.Count, $ids2.Count); Total = $ids2.Count }
    }
    [pscustomobject]@{ Ok = ($failed.Count -eq 0); Found = $found; Failed = $failed.ToArray() }
}

function Merge-DreddPurchaseLookup {
    # Применяет результат Lookup к записям. Записи из Failed остаются со старыми данными, но Lookup = Unknown.
    param([object[]]$Apps, $LookupResult)
    $failed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in @($LookupResult.Failed)) { [void]$failed.Add([string]$f) }
    $now = (Get-Date).ToString('s')
    foreach ($a in $Apps) {
        if ($failed.Contains($a.Id)) { $a.Lookup = 'Unknown'; continue }
        $a.LookupAt = $now
        if ($LookupResult.Found.ContainsKey($a.Id)) {
            $s = $LookupResult.Found[$a.Id]
            $a.Lookup = 'Found'; $a.StoreName = $s.Name; $a.Version = $s.Version; $a.BundleId = $s.BundleId
            $a.MinIOS = $s.MinIOS; $a.SizeBytes = [long]$s.SizeBytes; $a.Artist = $s.Artist; $a.ArtworkUrl = $s.ArtworkUrl
            if (-not $a.Name) { $a.Name = $s.Name }
        } else {
            $a.Lookup = 'Missing'
        }
    }
}

function Update-DreddPurchaseLibrary {
    <#
      Полное сканирование: история покупок → объединение с кэшем (сохраняются ошибки попыток и данные Lookup)
      → Lookup по региону аккаунта → сохранение. Результат: Ok, Library, Error{Key,Message}, LookupOk.
      Если история покупок не получена, кэш не меняется.
    #>
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email, [string]$Storefront,
        $Reporter, $CancellationToken, [scriptblock]$Fetch
    )
    Write-DreddReport -Reporter $Reporter -Type status -Area 'Purchases' -Message 'history'
    $p = Get-DreddAccountPurchases -Context $Context -Reporter $Reporter -CancellationToken $CancellationToken
    if (-not $p.Ok) { return [pscustomobject]@{ Ok = $false; Library = $null; Error = $p.Error; LookupOk = $false } }

    $old = Read-DreddPurchaseLibrary -Context $Context -Email $Email
    $prev = @{}
    if ($old) { foreach ($a in $old.Apps) { $prev[$a.Id] = $a } }
    $apps = foreach ($h in @($p.Apps)) {
        $rec = if ($prev.ContainsKey($h.ID)) { $prev[$h.ID] } else { New-DreddPurchaseRecord -Id $h.ID -Name $h.Name }
        if ($h.Name) { $rec.Name = $h.Name }
        $rec.PurchaseDate = if ($h.SortDate -ne [datetime]::MinValue) { $h.SortDate.ToString('yyyy-MM-dd') } else { [string]$h.PurchaseDate }
        $rec.Price = [string]$h.Price
        $rec
    }
    $apps = @($apps)

    $country = ConvertTo-DreddCountryCode $Storefront
    $lookupOk = $false
    # LookupOffline — самопроверка GUI без сети.
    if ($country -and $apps.Count -gt 0 -and -not $Context.LookupOffline) {
        Write-DreddReport -Reporter $Reporter -Type status -Area 'Purchases' -Message 'lookup' -Value @{ Done = 0; Total = $apps.Count }
        $lk = Invoke-DreddStoreLookup -Ids @($apps | ForEach-Object { $_.Id }) -Country $country -Reporter $Reporter -CancellationToken $CancellationToken -Fetch $Fetch
        Merge-DreddPurchaseLookup -Apps $apps -LookupResult $lk
        $lookupOk = $lk.Ok
    } else {
        foreach ($a in $apps) { if ($a.Lookup -ne 'Found') { $a.Lookup = 'Unknown' } }
        if (-not $country -and $apps.Count -gt 0) { Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Purchases' -Message "Unknown account region '$Storefront': App Store availability not checked" }
    }

    $lib = [pscustomobject]@{ Storefront = [string]$Storefront; ScannedAt = (Get-Date).ToString('s'); LookupOk = $lookupOk; Apps = $apps }
    Save-DreddPurchaseLibrary -Context $Context -Email $Email -Library $lib
    return [pscustomobject]@{ Ok = $true; Library = $lib; Error = $null; LookupOk = $lookupOk }
}

function Set-DreddPurchaseAttempt {
    # Результат реальной попытки загрузки: ErrorKey пустой — успех (ошибка сбрасывается).
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email, [Parameter(Mandatory)][string]$AppId, [string]$ErrorKey, [string]$Message)
    $lib = Read-DreddPurchaseLibrary -Context $Context -Email $Email
    if (-not $lib) { return $false }
    $a = $lib.Apps | Where-Object { $_.Id -eq $AppId } | Select-Object -First 1
    if (-not $a) { return $false }
    if ($ErrorKey -eq 'Err.Cancelled') { return $false }
    $a.LastErrorKey = [string]$ErrorKey
    $a.LastErrorMessage = $(if ($ErrorKey) { Protect-LogText $Message } else { '' })
    $a.LastAttemptAt = (Get-Date).ToString('s')
    Save-DreddPurchaseLibrary -Context $Context -Email $Email -Library $lib
    return $true
}

function Get-DreddPurchaseStatus {
    <#
      Статус приложения из истории покупок:
        UpdateAvailable — скачано, в App Store версия новее;   Downloaded — есть в локальной библиотеке;
        Failed          — последняя попытка загрузки не удалась (текст Apple в LastErrorMessage);
        Available       — есть в App Store региона аккаунта;    NotInStore — в App Store региона не найдено;
        Unverified      — проверить не удалось.
      -LocalVersion: версия файла в локальной библиотеке (или $null, если файла нет).
    #>
    param([Parameter(Mandatory)]$App, [string]$LocalVersion)
    if ($LocalVersion) {
        if ($App.Lookup -eq 'Found' -and (Compare-DreddVersion $LocalVersion $App.Version) -eq -1) { return 'UpdateAvailable' }
        return 'Downloaded'
    }
    if ($App.LastErrorKey) { return 'Failed' }
    switch ($App.Lookup) {
        'Found' { return 'Available' }
        'Missing' { return 'NotInStore' }
        default { return 'Unverified' }
    }
}

function Save-DreddIcons {
    # Скачивает недостающие иконки (Files/Cache/Icons/<ID>.jpg). Сообщение data { Id; Path } на каждую иконку.
    param([Parameter(Mandatory)]$Context, [object[]]$Apps, $Reporter, $CancellationToken)
    $dir = Get-DreddIconFolder $Context
    if (-not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = "IPA-PilotDredd/$script:DreddVersion"
    $n = 0
    try {
        foreach ($a in @($Apps)) {
            if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { break }
            if ($a.Id -notmatch '^\d+$' -or $a.ArtworkUrl -notmatch '^https://[\w.-]+\.mzstatic\.com/') { continue }
            $path = Join-Path $dir "$($a.Id).jpg"
            if ([System.IO.File]::Exists($path)) { continue }
            # Иконка 64×64 вместо 100×100: в списке она 32 px (×2 для высокого DPI).
            $url = $a.ArtworkUrl -replace '/\d+x\d+bb\.(jpg|png)$', '/64x64bb.jpg'
            try {
                $tmp = "$path.part"
                $wc.DownloadFile($url, $tmp)
                [System.IO.File]::Move($tmp, $path)
                $n++
                Write-DreddReport -Reporter $Reporter -Type data -Area 'Icons' -Value @{ Id = $a.Id; Path = $path }
            } catch {
                try { if ([System.IO.File]::Exists("$path.part")) { [System.IO.File]::Delete("$path.part") } } catch { }
            }
        }
    } finally { $wc.Dispose() }
    return $n
}

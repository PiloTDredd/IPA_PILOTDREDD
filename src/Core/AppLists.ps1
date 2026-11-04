# Списки приложений: Files/AppsList.txt (популярные) и Files/AppsListCustom.txt (свой). Формат "Имя: ID".

$script:ListCache = @{}

function Read-DreddAppsList {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Read-DreddTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s*(.+?)\s*:\s*(\d+)\s*$') {
            $result.Add([pscustomobject]@{ Name = $Matches[1].Trim().TrimStart([char]0xFEFF); ID = $Matches[2] })
        }
    }
    return $result.ToArray()
}

function Remove-DreddDuplicateIds {
    # Удаление дублей по ID с сохранением порядка (как Remove-Duplicate-IDs в 4.2).
    param([object[]]$Items)
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($i in $Items) {
        if ($null -eq $i) { continue }
        if ($seen.Add([string]$i.ID)) { $out.Add($i) }
    }
    return $out.ToArray()
}

function Get-DreddCachedList {
    param([string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return @() }
    $fi = New-Object System.IO.FileInfo($Path)
    $stamp = '{0}:{1}' -f $fi.LastWriteTimeUtc.Ticks, $fi.Length
    $c = $script:ListCache[$Path]
    if ($c -and $c.Stamp -eq $stamp) { return $c.Items }
    $items = @(Read-DreddAppsList -Path $Path)
    $script:ListCache[$Path] = @{ Stamp = $stamp; Items = $items }
    return $items
}

function Get-DreddPopularApps {
    param([Parameter(Mandatory)]$Context)
    return @(Get-DreddCachedList -Path $Context.AppsListPath)
}

function Get-DreddCustomApps {
    param([Parameter(Mandatory)]$Context)
    return @(Remove-DreddDuplicateIds -Items @(Get-DreddCachedList -Path $Context.CustomListPath))
}

function Add-DreddCustomApp {
    # Добавляет "Имя: ID" в свой список. Возвращает $false, если ID уже есть.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$AppId)
    if ($AppId -notmatch '^\d+$') { throw "Invalid App ID" }
    $Name = ($Name -replace '[\r\n:]', ' ').Trim()
    if (-not $Name) { $Name = $AppId }
    $existing = @(Get-DreddCustomApps -Context $Context)
    if (@($existing | Where-Object { $_.ID -eq $AppId }).Count -gt 0) { return $false }
    $raw = Read-DreddTextFile -Path $Context.CustomListPath
    if ($null -eq $raw) { $raw = '' }
    if ($raw.Length -gt 0 -and -not $raw.EndsWith("`n")) { $raw += "`n" }
    $raw += "$($Name): $AppId`n"
    Write-DreddTextFile -Path $Context.CustomListPath -Content $raw
    return $true
}

function Split-DreddIdQuery {
    # "123456, 7891011" → массив ID, если все части — числа от 6 цифр (правило 4.2). Иначе $null.
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $null }
    $parts = @($Query.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $null }
    if (@($parts | Where-Object { $_ -notmatch '^\d{6,}$' }).Count -gt 0) { return $null }
    return @($parts | Select-Object -Unique)
}

function Resolve-DreddAppName {
    # Имя по ID: сначала свой список, затем популярный.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$AppId)
    $c = @(Get-DreddCustomApps -Context $Context) | Where-Object { $_.ID -eq $AppId } | Select-Object -First 1
    if ($c) { return $c.Name }
    $p = @(Get-DreddPopularApps -Context $Context) | Where-Object { $_.ID -eq $AppId } | Select-Object -First 1
    if ($p) { return $p.Name }
    return $null
}

function Search-DreddLocalApps {
    # Поиск по названию или части ID: свой список, затем популярный (без ID из своего). Без масок (исправление G6).
    param([Parameter(Mandatory)]$Context, [string]$Query, [ValidateSet('All', 'Popular', 'Custom')][string]$Scope = 'All')
    $custom = @(); $popular = @()
    if ($Scope -ne 'Popular') { $custom = @(Get-DreddCustomApps -Context $Context) }
    if ($Scope -ne 'Custom') { $popular = @(Get-DreddPopularApps -Context $Context) }
    $customIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($c in $custom) { [void]$customIds.Add($c.ID) }
    $q = if ($Query) { $Query.Trim() } else { '' }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $custom) {
        if ((Test-DreddContains $c.Name $q) -or (Test-DreddContains $c.ID $q)) {
            $out.Add([pscustomobject]@{ Name = $c.Name; ID = $c.ID; BundleId = ''; Version = ''; Source = 'Custom' })
        }
    }
    foreach ($p in $popular) {
        if ($customIds.Contains($p.ID)) { continue }
        if ((Test-DreddContains $p.Name $q) -or (Test-DreddContains $p.ID $q)) {
            $out.Add([pscustomobject]@{ Name = $p.Name; ID = $p.ID; BundleId = ''; Version = ''; Source = 'Popular' })
        }
    }
    return @(Remove-DreddDuplicateIds -Items $out.ToArray())
}

function Search-DreddApps {
    <#
      Полный поиск как в 4.2: список ID через запятую → приложения по ID; иначе свой → популярный → App Store.
      Дубли по ID убираются, у результатов из App Store сохраняется версия и bundle id.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Query, [switch]$IncludeAppStore, [int]$Limit = 25, $Reporter, $CancellationToken)
    $ids = Split-DreddIdQuery $Query
    if ($ids) {
        $rows = foreach ($id in $ids) {
            $name = Resolve-DreddAppName -Context $Context -AppId $id
            [pscustomobject]@{ Name = $(if ($name) { $name } else { $id }); ID = $id; BundleId = ''; Version = ''; Source = 'ID' }
        }
        return [pscustomobject]@{ Ok = $true; Apps = @($rows); Error = $null }
    }
    $local = @(Search-DreddLocalApps -Context $Context -Query $Query)
    $store = @(); $err = $null
    if ($IncludeAppStore -and -not [string]::IsNullOrWhiteSpace($Query)) {
        $s = Search-DreddAppStore -Context $Context -Query $Query.Trim() -Limit $Limit -Reporter $Reporter -CancellationToken $CancellationToken
        $store = @($s.Apps); $err = $s.Error
    }
    # Для локальных совпадений, найденных и в App Store, подставляем версию из App Store:
    $byId = @{}
    foreach ($s in $store) { $byId[$s.ID] = $s }
    foreach ($l in $local) {
        if ($byId.ContainsKey($l.ID)) { $l.Version = $byId[$l.ID].Version; $l.BundleId = $byId[$l.ID].BundleId }
    }
    $all = @(Remove-DreddDuplicateIds -Items (@($local) + @($store)))
    return [pscustomobject]@{ Ok = ($null -eq $err); Apps = $all; Error = $err }
}

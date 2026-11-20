# Доступность приложений из списка «Популярных» в App Store по регионам (4.7, «светофор»).
# Анализ 2026-11-11: из ~700 приложений списка больше половины удалены из App Store совсем — без метки пользователь узнаёт об этом
# только по ошибке загрузки. Проверка — публичный iTunes Lookup по регионам (по умолчанию RU, US, KZ).
# Файл Files/AppsAvailability.json: { CheckedAt; Countries[]; Apps { "<ID>": "ru,us" | "" } } — "" значит «нет ни в одном регионе».
# Делается каждую ночь GitHub Actions (tools/Update-AppsAvailability.ps1, ветка data); программа скачивает готовый файл
# вместе со списком приложений. ID, которых в файле нет, — «не проверено» (метки нет).

$script:AvailabilityCountries = @('ru', 'us', 'kz')

function Get-DreddAvailabilityPath { param([Parameter(Mandatory)]$Context) Join-Path $Context.FilesDir 'AppsAvailability.json' }

function Test-DreddAvailabilityContent {
    # Корректный файл доступности: JSON с Countries и хотя бы 10 приложениями в Apps.
    param([string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content) -or $Content -match '(?i)<html|<!doctype') { return $false }
    try { $j = $Content | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    $apps = Get-DreddProp $j 'Apps' $null
    if (-not $apps -or -not (Get-DreddProp $j 'Countries' $null)) { return $false }
    return (@($apps.PSObject.Properties | Where-Object { $_.Name -match '^\d+$' }).Count -ge 10)
}

function Read-DreddAppsAvailability {
    <#
      Файл доступности → { CheckedAt; Countries[]; Apps (hashtable ID → string[] регионов) } или $null, если файла нет или он битый.
    #>
    param([Parameter(Mandatory)]$Context, [string]$Path)
    if (-not $Path) { $Path = Get-DreddAvailabilityPath $Context }
    $t = Read-DreddTextFile -Path $Path
    if (-not (Test-DreddAvailabilityContent $t)) { return $null }
    $j = $t | ConvertFrom-Json
    $apps = @{}
    foreach ($p in $j.Apps.PSObject.Properties) {
        if ($p.Name -notmatch '^\d+$') { continue }
        $apps[$p.Name] = @(([string]$p.Value) -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -match '^[a-z]{2}$' })
    }
    return [pscustomobject]@{ CheckedAt = [string](Get-DreddProp $j 'CheckedAt' ''); Countries = @($j.Countries); Apps = $apps }
}

function Get-DreddAppsAvailability {
    <#
      Проверка по iTunes Lookup: для каждого региона — какие ID App Store знает. Результат: Ok (все запросы ответили),
      CheckedAt, Countries, Apps (hashtable ID → string[] регионов), Failed (ID, по которым хоть один регион не ответил).
      -Fetch — подмена загрузки для тестов (как в Invoke-DreddStoreLookup).
    #>
    param([Parameter(Mandatory)][string[]]$Ids, [string[]]$Countries = $script:AvailabilityCountries, $Reporter, $CancellationToken, [scriptblock]$Fetch)
    $ids2 = @($Ids | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
    $apps = @{}; foreach ($id in $ids2) { $apps[$id] = @() }
    $failed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($cc in $Countries) {
        $p = @{ Ids = $ids2; Country = $cc; Reporter = $Reporter; CancellationToken = $CancellationToken }
        if ($Fetch) { $p['Fetch'] = $Fetch }
        $lk = Invoke-DreddStoreLookup @p
        foreach ($f in @($lk.Failed)) { [void]$failed.Add([string]$f) }
        foreach ($id in $lk.Found.Keys) { if ($apps.ContainsKey($id)) { $apps[$id] = @($apps[$id]) + $cc } }
        Write-DreddReport -Reporter $Reporter -Type log -Area 'Lists' -Message ("{0}: {1} / {2}" -f $cc.ToUpperInvariant(), $lk.Found.Count, $ids2.Count)
    }
    return [pscustomobject]@{
        Ok = ($failed.Count -eq 0); CheckedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Countries = @($Countries); Apps = $apps; Failed = @($failed)
    }
}

function Save-DreddAppsAvailability {
    # Пишет файл доступности (ID по возрастанию — чтобы ночные изменения было видно в diff).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Data)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('{' + "`n")
    [void]$sb.Append('  "CheckedAt": ' + (ConvertTo-Json -InputObject ([string]$Data.CheckedAt)) + ",`n")
    [void]$sb.Append('  "Countries": [' + ((@($Data.Countries) | ForEach-Object { '"' + $_ + '"' }) -join ', ') + "],`n")
    [void]$sb.Append('  "Apps": {' + "`n")
    $keys = @($Data.Apps.Keys | Where-Object { $_ -match '^\d+$' } | Sort-Object { [long]$_ })
    for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]
        $v = (@($Data.Apps[$k]) -join ',')
        [void]$sb.Append(('    "{0}": "{1}"' -f $k, $v) + $(if ($i -lt $keys.Count - 1) { ",`n" } else { "`n" }))
    }
    [void]$sb.Append("  }`n}`n")
    Write-DreddTextFile -Path $Path -Content $sb.ToString()
}

function Get-DreddAvailabilityLabel {
    <#
      Метка для строки списка: Available — есть в регионе пользователя (метку не показываем); OtherRegion — только в других
      проверенных регионах (Regions — где именно); Removed — нет ни в одном (скачается, скорее всего, только если уже покупали);
      '' — не проверялось. -Country: регион аккаунта (двухбуквенный), по умолчанию ru.
    #>
    param($Availability, [string]$Id, [string]$Country = 'ru')
    $none = [pscustomobject]@{ Label = ''; Regions = @() }
    if (-not $Availability -or -not $Id -or -not $Availability.Apps.ContainsKey($Id)) { return $none }
    $home2 = if ($Country -match '^[A-Za-z]{2}$') { $Country.ToLowerInvariant() } else { 'ru' }
    $regions = @($Availability.Apps[$Id])
    if ($regions.Count -eq 0) { return [pscustomobject]@{ Label = 'Removed'; Regions = @() } }
    if ($regions -contains $home2) { return [pscustomobject]@{ Label = 'Available'; Regions = $regions } }
    # Регион аккаунта не проверялся (например, DE) — судить о нём нельзя, кроме «удалено отовсюду».
    if (@($Availability.Countries) -notcontains $home2) { return $none }
    return [pscustomobject]@{ Label = 'OtherRegion'; Regions = $regions }
}

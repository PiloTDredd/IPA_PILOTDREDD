# Истории: PurchasedAppsList.json (совместим с 4.1/4.2) и DownloadHistory.json (новый, 4.3).

function Read-DreddJsonFile {
    param([string]$Path)
    $raw = Read-DreddTextFile -Path $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    try { return ($raw.TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Get-DreddPurchasedApps {
    <#
      Читает PurchasedAppsList.json. Поддерживает форматы:
        4.0 (старый): [ {name, appid}, ... ]
        4.1/4.2:      { "<email>": [ {...} ] } или { "<email>": {...} } (одиночный объект, баг B9)
      Без -Account возвращает все записи всех аккаунтов (поле Account).
    #>
    param([Parameter(Mandatory)]$Context, [string]$Account)
    $data = Read-DreddJsonFile -Path $Context.PurchasedPath
    if ($null -eq $data) { return @() }
    $rows = New-Object System.Collections.Generic.List[object]
    $add = {
        param($item, $acc)
        if ($null -eq $item) { return }
        $id = [string](Get-DreddProp $item 'AppID' (Get-DreddProp $item 'appid'))
        $name = [string](Get-DreddProp $item 'Name' (Get-DreddProp $item 'name'))
        if ($id) { $rows.Add([pscustomobject]@{ Name = $name; ID = $id; Account = $acc; Source = 'Purchased' }) }
    }
    if ($data -is [System.Array]) {
        foreach ($i in $data) { & $add $i '' }
    } else {
        foreach ($p in $data.PSObject.Properties) {
            if ($Account -and $p.Name -ne $Account) { continue }
            foreach ($i in @($p.Value)) { & $add $i $p.Name }
        }
    }
    return $rows.ToArray()
}

function Add-DreddPurchasedApp {
    <#
      Добавляет приложение в историю «получено скриптом» для аккаунта. Сортировка как в 4.2: порядок в списках
      (популярный, затем свой), затем по имени. Значение аккаунта всегда записывается массивом.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$Name)
    $data = Read-DreddJsonFile -Path $Context.PurchasedPath
    $ordered = [ordered]@{}
    if ($data -and -not ($data -is [System.Array])) {
        foreach ($p in $data.PSObject.Properties) {
            $ordered[$p.Name] = @(@($p.Value) | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject]@{ Name = [string](Get-DreddProp $_ 'Name' (Get-DreddProp $_ 'name')); AppID = [string](Get-DreddProp $_ 'AppID' (Get-DreddProp $_ 'appid')) }
            })
        }
    }
    $list = @()
    if ($ordered.Contains($Account)) { $list = @($ordered[$Account]) }

    # Справочник порядка и актуальных имён:
    $ref = @{}
    $popular = @(Get-DreddPopularApps -Context $Context)
    for ($i = 0; $i -lt $popular.Count; $i++) { if (-not $ref.ContainsKey($popular[$i].ID)) { $ref[$popular[$i].ID] = @{ Index = $i; Name = $popular[$i].Name } } }
    $custom = @(Get-DreddCustomApps -Context $Context)
    for ($i = 0; $i -lt $custom.Count; $i++) {
        if ($ref.ContainsKey($custom[$i].ID)) { $ref[$custom[$i].ID].Name = $custom[$i].Name }
        else { $ref[$custom[$i].ID] = @{ Index = $popular.Count + $i; Name = $custom[$i].Name } }
    }

    $exists = $false
    foreach ($item in $list) {
        if ($ref.ContainsKey($item.AppID)) { $item.Name = $ref[$item.AppID].Name }
        if ($item.AppID -eq $AppId) { $exists = $true }
    }
    if (-not $exists) { $list += [pscustomobject]@{ Name = $Name; AppID = $AppId } }

    $list = @($list | Sort-Object @{ Expression = { if ($ref.ContainsKey($_.AppID)) { $ref[$_.AppID].Index } else { [int]::MaxValue } } }, @{ Expression = { "$($_.Name)".ToUpperInvariant().Replace('Ё', 'Е') } })
    $ordered[$Account] = $list

    # Ручная сборка JSON: гарантирует массив даже для одного элемента в PS 5.1.
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("{`r`n")
    $keys = @($ordered.Keys)
    for ($k = 0; $k -lt $keys.Count; $k++) {
        $key = $keys[$k]
        [void]$sb.Append('    ' + (ConvertTo-Json -InputObject ([string]$key) -Compress) + ': [')
        $items = @($ordered[$key])
        for ($j = 0; $j -lt $items.Count; $j++) {
            $obj = [ordered]@{ Name = [string]$items[$j].Name; AppID = [string]$items[$j].AppID }
            [void]$sb.Append("`r`n        " + (ConvertTo-Json -InputObject $obj -Compress))
            if ($j -lt $items.Count - 1) { [void]$sb.Append(',') }
        }
        if ($items.Count -gt 0) { [void]$sb.Append("`r`n    ") }
        [void]$sb.Append(']')
        if ($k -lt $keys.Count - 1) { [void]$sb.Append(',') }
        [void]$sb.Append("`r`n")
    }
    [void]$sb.Append('}')
    Write-DreddTextFile -Path $Context.PurchasedPath -Content $sb.ToString()
    return (-not $exists)
}

function Get-DreddDownloadHistory {
    param([Parameter(Mandatory)]$Context, [int]$Last = 0)
    $data = Read-DreddJsonFile -Path $Context.HistoryPath
    if ($null -eq $data) { return @() }
    $rows = @($data | Where-Object { $null -ne $_ })
    $rows = @($rows | Sort-Object { [string](Get-DreddProp $_ 'Date' '') } -Descending)
    if ($Last -gt 0) { $rows = @($rows | Select-Object -First $Last) }
    return $rows
}

function Get-DreddHistoryKey {
    # Идентификатор записи истории (своего ID у записей нет): дата, тип, App Store ID, имя.
    param($Entry)
    return ('{0}|{1}|{2}|{3}' -f (Get-DreddProp $Entry 'Date' ''), (Get-DreddProp $Entry 'Kind' 'Download'), (Get-DreddProp $Entry 'AppID' ''), (Get-DreddProp $Entry 'Name' ''))
}

function Remove-DreddHistoryEntries {
    # Удаляет записи истории по ключам Get-DreddHistoryKey; -All — всю историю. Файлы IPA не трогаются. Возвращает число удалённых.
    param([Parameter(Mandatory)]$Context, [string[]]$Keys, [switch]$All)
    $data = Read-DreddJsonFile -Path $Context.HistoryPath
    if ($null -eq $data) { return 0 }
    $rows = @($data | Where-Object { $null -ne $_ })
    if ($All) { $keep = @() }
    else {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($k in @($Keys)) { if ($k) { [void]$set.Add($k) } }
        $keep = @($rows | Where-Object { -not $set.Contains((Get-DreddHistoryKey $_)) })
    }
    Write-DreddTextFile -Path $Context.HistoryPath -Content (ConvertTo-Json -InputObject $keep -Depth 4)
    return ($rows.Count - $keep.Count)
}

function Add-DreddHistoryEntry {
    # Kind: Download | Purchase | Install. Хранятся последние 500 записей. Email аккаунта маскируется.
    param(
        [Parameter(Mandatory)]$Context,
        [ValidateSet('Download', 'Purchase', 'Install')][string]$Kind = 'Download',
        [string]$AppId, [string]$Name, [string]$Version, [string]$Account, [string]$File, [string]$Target,
        [ValidateSet('Success', 'Error', 'Cancelled')][string]$Result = 'Success', [string]$Message
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $data = Read-DreddJsonFile -Path $Context.HistoryPath
    if ($data) { foreach ($d in @($data)) { if ($null -ne $d) { $rows.Add($d) } } }
    $rows.Add([pscustomobject][ordered]@{
        Date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); Kind = $Kind; AppID = $AppId; Name = $Name; Version = $Version
        Account = (Protect-DreddEmail $Account); File = $File; Target = $Target; Result = $Result; Message = (Protect-LogText $Message)
    })
    $keep = @($rows.ToArray() | Select-Object -Last 500)
    Write-DreddTextFile -Path $Context.HistoryPath -Content (ConvertTo-Json -InputObject $keep -Depth 4)
}

# Пакетная установка (4.7): список приложений → скачать и поставить по очереди → отчёт «установлено / не встало и почему».
# Сами очереди загрузок и установок живут в окне (GUI/Pages/Downloads.ps1, Devices.ps1) и работают по одной задаче за раз.
# Здесь — учёт пакета и отчёт: без UI, с тестами. На этом строятся «Обновить всё на iPhone», массовая установка из «Покупок»
# и (дальше) мастер переезда на новый iPhone.
#
# Состояния записи: Pending (ждёт загрузки/установки), Installed, Failed (с причиной), Skipped (не ставилось: уже стоит,
# не подходит к iOS — причина), Cancelled. Пакет завершён, когда не осталось Pending.

$script:BatchStates = @('Pending', 'Installed', 'Failed', 'Skipped', 'Cancelled')

function New-DreddBatch {
    <#
      -Items: { Id; Name } — что ставим. -Skipped: { Id; Name; Reason } — что отсеяно сразу (попадёт в отчёт как «пропущено»).
      -Kind: Install (поставить) или Update («Обновить всё»). Одинаковые ID внутри пакета схлопываются.
    #>
    param(
        [ValidateSet('Install', 'Update')][string]$Kind = 'Install',
        [string]$DeviceName,
        [string]$Udid,
        [object[]]$Items,
        [object[]]$Skipped
    )
    $list = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($i in @($Items)) {
        if (-not $i) { continue }
        $id = [string](Get-DreddProp $i 'Id' '')
        if (-not $id -or -not $seen.Add($id)) { continue }
        $list.Add([pscustomobject]@{ Id = $id; Name = [string](Get-DreddProp $i 'Name' $id); State = 'Pending'; Reason = '' })
    }
    foreach ($s in @($Skipped)) {
        if (-not $s) { continue }
        $id = [string](Get-DreddProp $s 'Id' '')
        if (-not $id -or -not $seen.Add($id)) { continue }
        $list.Add([pscustomobject]@{ Id = $id; Name = [string](Get-DreddProp $s 'Name' $id); State = 'Skipped'; Reason = [string](Get-DreddProp $s 'Reason' '') })
    }
    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N'); Kind = $Kind; DeviceName = $DeviceName; Udid = $Udid
        StartedAt = (Get-Date); FinishedAt = $null; Items = $list; Reported = $false
    }
}

function Set-DreddBatchItem {
    <#
      Итог по приложению: меняет только запись в состоянии Pending (повтор уже завершённого — это новый пакет).
      Возвращает $true, если запись нашлась и изменилась. Когда Pending не осталось — ставит FinishedAt.
    #>
    param(
        [Parameter(Mandatory)]$Batch,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Installed', 'Failed', 'Skipped', 'Cancelled')][string]$State,
        [string]$Reason
    )
    $item = $Batch.Items | Where-Object { $_.Id -eq $Id -and $_.State -eq 'Pending' } | Select-Object -First 1
    if (-not $item) { return $false }
    $item.State = $State
    $item.Reason = if ($State -in 'Failed', 'Skipped') { [string]$Reason } else { '' }
    if (Test-DreddBatchDone $Batch) { $Batch.FinishedAt = Get-Date }
    return $true
}

function Test-DreddBatchDone {
    param([Parameter(Mandatory)]$Batch)
    return @($Batch.Items | Where-Object { $_.State -eq 'Pending' }).Count -eq 0
}

function Get-DreddBatchReport {
    <#
      Сводка пакета: Total, Installed, Failed, Skipped, Cancelled, Pending, Done, Duration (TimeSpan),
      FailedGroups / SkippedGroups — одинаковые причины вместе: { Reason; Names[] }, самые частые первыми,
      FailedIds — для «Повторить неудачные».
    #>
    param([Parameter(Mandatory)]$Batch)
    $count = @{}; foreach ($s in $script:BatchStates) { $count[$s] = 0 }
    foreach ($i in $Batch.Items) { $count[$i.State]++ }
    $group = {
        param($state)
        $g = [ordered]@{}
        foreach ($i in @($Batch.Items | Where-Object { $_.State -eq $state })) {
            $k = if ([string]::IsNullOrWhiteSpace($i.Reason)) { '' } else { $i.Reason.Trim() }
            if (-not $g.Contains($k)) { $g[$k] = New-Object System.Collections.Generic.List[string] }
            $g[$k].Add($i.Name)
        }
        @($g.Keys | ForEach-Object { [pscustomobject]@{ Reason = $_; Names = $g[$_].ToArray() } } | Sort-Object -Property @{ Expression = { $_.Names.Count }; Descending = $true }, Reason)
    }
    $end = if ($Batch.FinishedAt) { $Batch.FinishedAt } else { Get-Date }
    return [pscustomobject]@{
        Total = $Batch.Items.Count; Installed = $count.Installed; Failed = $count.Failed; Skipped = $count.Skipped
        Cancelled = $count.Cancelled; Pending = $count.Pending; Done = ($count.Pending -eq 0)
        Duration = ($end - $Batch.StartedAt)
        FailedGroups = (& $group 'Failed'); SkippedGroups = (& $group 'Skipped')
        FailedIds = @($Batch.Items | Where-Object { $_.State -eq 'Failed' } | ForEach-Object { $_.Id })
    }
}

function Select-DreddUpdateAll {
    <#
      «Обновить всё на iPhone»: из строк «Покупок» { Id; Name; Badge; Busy } берёт те, у которых на iPhone старая версия
      (Badge = Outdated) и которые сейчас не качаются (Busy). Результат — { Id; Name } в исходном порядке.
    #>
    param([object[]]$Rows)
    return @($Rows | Where-Object { $_ -and $_.Badge -eq 'Outdated' -and -not $_.Busy } | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Name = [string]$_.Name } })
}

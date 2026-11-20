# Светофор «Популярных» (4.7): проверяет по iTunes Lookup, в каких регионах (RU, US, KZ) есть каждое приложение из Files/AppsList.txt,
# и пишет Files/AppsAvailability.json. Запускается каждую ночь в GitHub Actions (.github/workflows/apps-availability.yml),
# результат публикуется в ветку data; программа скачивает его вместе со списком приложений. Можно запустить и вручную.
# -RefreshList: сначала взять свежий AppsList.txt из источника списка (RemoteListBaseUrl, по умолчанию kda2495).
# Если часть запросов не ответила — для этих ID остаются прошлые значения; если не ответило больше 20% — выход с ошибкой.
param([switch]$RefreshList, [string]$OutFile, [string[]]$Countries = @('ru', 'us', 'kz'))
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $appRoot 'src/Core/IPADredd.Core.psm1') -Force -DisableNameChecking
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('IPADreddAvail_' + [guid]::NewGuid().ToString('N'))
$ctx = New-DreddContext -AppRoot $appRoot -IpatoolHome (Join-Path $tmpRoot 'ipatool') -TempRoot $tmpRoot
if (-not $OutFile) { $OutFile = Get-DreddAvailabilityPath $ctx }

if ($RefreshList) {
    $base = ([string](Get-DreddDefaultSettings)['RemoteListBaseUrl']).TrimEnd('/')
    $txt = Invoke-DreddWebText -Url "$base/AppsList.txt" -Retries 2
    if (-not (Test-DreddAppsListContent $txt)) { throw "AppsList.txt from $base is invalid" }
    Write-DreddTextFile -Path $ctx.AppsListPath -Content $txt
}

$ids = @(Read-DreddAppsList -Path $ctx.AppsListPath | ForEach-Object { [string]$_.ID } | Where-Object { $_ -match '^\d+$' } | Select-Object -Unique)
if ($ids.Count -lt 10) { throw "AppsList.txt: only $($ids.Count) IDs" }
Write-Output ("Apps: {0}, regions: {1}" -f $ids.Count, ($Countries -join ', '))

$reporter = { param($m) if ($m.Type -eq 'log') { Write-Output ("  " + $m.Message) } }
$r = Get-DreddAppsAvailability -Ids $ids -Countries $Countries -Reporter $reporter
if ($r.Failed.Count -gt 0) {
    $prev = Read-DreddAppsAvailability -Context $ctx -Path $OutFile
    Write-Output ("No answer for {0} IDs, keeping previous values" -f $r.Failed.Count)
    if ($r.Failed.Count -gt [Math]::Max(10, $ids.Count * 0.2)) { throw "Too many failed lookups: $($r.Failed.Count) of $($ids.Count)" }
    foreach ($id in $r.Failed) {
        if ($prev -and $prev.Apps.ContainsKey($id)) { $r.Apps[$id] = $prev.Apps[$id] } else { $r.Apps.Remove($id) }
    }
}
Save-DreddAppsAvailability -Path $OutFile -Data $r

$home1 = $Countries[0]
$n = @{ Home = 0; Other = 0; Removed = 0 }
foreach ($id in $r.Apps.Keys) {
    $c = @($r.Apps[$id])
    if ($c.Count -eq 0) { $n.Removed++ } elseif ($c -contains $home1) { $n.Home++ } else { $n.Other++ }
}
Write-Output ("{0}: {1} · other regions only: {2} · removed everywhere: {3} → {4}" -f $home1.ToUpperInvariant(), $n.Home, $n.Other, $n.Removed, $OutFile)
try { if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force } } catch { }

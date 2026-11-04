# Обновление AppsList.txt / Warning.txt с GitHub и проверка новых версий (ADR-013).

function Test-DreddAppsListContent {
    # Корректный список: не HTML и хотя бы 10 строк "Имя: ID".
    param([string]$Content)
    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }
    if ($Content -match '(?i)<html|<!doctype') { return $false }
    $n = 0
    foreach ($line in ($Content -split "`r?`n")) { if ($line -match '^\s*(.+?)\s*:\s*(\d+)\s*$') { $n++ } }
    return ($n -ge 10)
}

function Invoke-DreddWebText {
    param([string]$Url, [int]$TimeoutSec = 15)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.UserAgent = "IPA-PilotDredd/$script:DreddVersion"
    $resp = $req.GetResponse()
    try {
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } finally { $resp.Dispose() }
}

function Update-DreddRemoteLists {
    # Возвращает: AppsListUpdated, WarningUpdated, Count, Errors[].
    param([Parameter(Mandatory)]$Context, $Reporter)
    $base = ([string]$Context.Settings['RemoteListBaseUrl']).TrimEnd('/')
    $res = [ordered]@{ AppsListUpdated = $false; WarningUpdated = $false; Count = 0; Errors = @() }
    if (-not $base -or $base -notmatch '^https://') { $res.Errors += 'RemoteListBaseUrl must start with https://'; return [pscustomobject]$res }
    try {
        $txt = Invoke-DreddWebText -Url "$base/AppsList.txt"
        if (Test-DreddAppsListContent $txt) {
            Write-DreddTextFile -Path $Context.AppsListPath -Content $txt
            $res.AppsListUpdated = $true
            $res.Count = @(Read-DreddAppsList -Path $Context.AppsListPath).Count
        } else { $res.Errors += 'AppsList.txt: invalid content' }
    } catch { $res.Errors += ('AppsList.txt: ' + $_.Exception.Message) }
    try {
        $w = Invoke-DreddWebText -Url "$base/Warning.txt"
        if ($w -notmatch '(?i)<html|<!doctype') {
            Write-DreddTextFile -Path $Context.WarningPath -Content $w
            $res.WarningUpdated = $true
        }
    } catch { $res.Errors += ('Warning.txt: ' + $_.Exception.Message) }
    foreach ($e in $res.Errors) { Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Lists' -Message $e }
    return [pscustomobject]$res
}


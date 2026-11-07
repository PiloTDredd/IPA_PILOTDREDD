# Обновление ipatool-cpp из релизов upstream (kda2495/IPA_Downloader).
# Версия встроенного ipatool записана в MainApp/ipatool-version.txt (номер релиза upstream, из которого он взят).
# Установка: архив релиза → проверка SHA-256 из GitHub API → проверка запуска → резервная копия в MainApp_previous → замена.
# Релиз IPA PILOTDREDD бинарники не содержит (в ipatool-cpp вшиты библиотеки Apple, ideviceinstaller — GPL):
# при первом запуске компоненты ставятся отсюда же из официального релиза upstream (-Setup / NeedsSetup).

function Test-DreddNeedsSetup {
    # Компонентов нет совсем: ни ipatool в MainApp/настройках/папках 4.x.
    param([Parameter(Mandatory)]$Context)
    return -not $Context.Binaries.Ipatool
}

$script:ToolVersionFile = 'ipatool-version.txt'

function Get-DreddMainAppDir {
    # Папка MainApp рядом с программой — только её программа обновляет сама (чужие папки 4.2/настроек не трогаются).
    param([Parameter(Mandatory)]$Context)
    return Join-Path $Context.AppRoot 'MainApp'
}

function Get-DreddToolVersion {
    # Номер релиза upstream встроенного ipatool или $null, если неизвестен.
    param([Parameter(Mandatory)]$Context)
    $f = Join-Path (Get-DreddMainAppDir $Context) $script:ToolVersionFile
    $t = Read-DreddTextFile -Path $f
    if ($t -and $t.Trim() -match '^\d+(\.\d+){1,3}$') { return $t.Trim() }
    return $null
}

function Get-DreddLatestRelease {
    # Последний релиз upstream: Tag, Version, Url, Asset { Name, Url, Size, Sha256 } (архив релиза).
    param([Parameter(Mandatory)]$Context, [scriptblock]$Fetch)
    if (-not $Fetch) { $Fetch = { param($url) Invoke-DreddWebText -Url $url -TimeoutSec 20 } }
    $repo = [string]$Context.Settings['UpdateRepo']
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { throw 'Invalid UpdateRepo' }
    $json = (& $Fetch "https://api.github.com/repos/$repo/releases/latest") | ConvertFrom-Json
    $tag = [string](Get-DreddProp $json 'tag_name')
    $asset = $null
    foreach ($a in @(Get-DreddProp $json 'assets' @())) {
        $name = [string](Get-DreddProp $a 'name')
        if ($name -notmatch '\.zip$') { continue }
        $digest = [string](Get-DreddProp $a 'digest' '')
        $asset = [pscustomobject]@{
            Name = $name; Url = [string](Get-DreddProp $a 'browser_download_url'); Size = [long](Get-DreddProp $a 'size' 0)
            Sha256 = $(if ($digest -match '^sha256:([0-9a-fA-F]{64})$') { $Matches[1].ToLowerInvariant() } else { $null })
        }
        break
    }
    [pscustomobject]@{ Tag = $tag; Version = [regex]::Match($tag, '\d+(\.\d+)+').Value; Url = "https://github.com/$repo/releases"; Asset = $asset }
}

function Test-DreddAppUpdate {
    <#
      Новая версия самой IPA PILOTDREDD (релизы AppRepo на GitHub). Результат: Ok, Current, Latest, IsNewer, Url, Notes, Error.
      Только уведомление: файлы программы не заменяются (пользователь копирует новую папку поверх старой).
      Url — всегда страница релиза на github.com (чужой адрес из ответа не открывается).
    #>
    param([Parameter(Mandatory)]$Context, [scriptblock]$Fetch)
    if (-not $Fetch) { $Fetch = { param($url) Invoke-DreddWebText -Url $url -TimeoutSec 20 } }
    $res = [ordered]@{ Ok = $false; Current = $script:DreddVersion; Latest = $null; IsNewer = $false; Url = $null; Notes = ''; Error = $null }
    $repo = [string]$Context.Settings['AppRepo']
    if ($repo -notmatch '^[\w.-]+/[\w.-]+$') { $res.Error = 'Invalid AppRepo'; return [pscustomobject]$res }
    try {
        $json = (& $Fetch "https://api.github.com/repos/$repo/releases/latest") | ConvertFrom-Json
        $tag = [string](Get-DreddProp $json 'tag_name')
        $ver = [regex]::Match($tag, '\d+\.\d+\.\d+').Value
        $res.Ok = $true
        $res.Latest = $ver
        $res.Url = "https://github.com/$repo/releases/latest"
        $html = [string](Get-DreddProp $json 'html_url' '')
        if ($html -match "^https://github\.com/$([regex]::Escape($repo))/releases/") { $res.Url = $html }
        # Заметки к релизу: без markdown-заголовков и пустых строк, не длиннее 500 символов.
        $body = [string](Get-DreddProp $json 'body' '')
        $lines = @($body -split "`r?`n" | ForEach-Object { ($_ -replace '^\s*#+\s*', '' -replace '\*\*', '').TrimEnd() } | Where-Object { $_.Trim() })
        $notes = $lines -join "`n"
        if ($notes.Length -gt 500) { $notes = $notes.Substring(0, 500).TrimEnd() + '…' }
        $res.Notes = $notes
        if ($ver) { $res.IsNewer = (Compare-DreddVersion $script:DreddVersion $ver) -eq -1 }
    } catch { $res.Error = $_.Exception.Message }
    return [pscustomobject]$res
}

function Test-DreddToolUpdate {
    <#
      Тихая проверка: Ok, Current, Latest, IsNewer, CanInstall, Reason, Release, NeedsSetup.
      CanInstall — можно обновить автоматически (MainApp рядом с программой или компонентов нет вовсе, у архива есть SHA-256).
      NeedsSetup — первый запуск: компонентов нет, установка возьмёт и инструменты устройств.
    #>
    param([Parameter(Mandatory)]$Context, [scriptblock]$Fetch)
    $current = Get-DreddToolVersion $Context
    $setup = Test-DreddNeedsSetup $Context
    $res = [ordered]@{ Ok = $false; Current = $current; Latest = $null; IsNewer = $false; CanInstall = $false; Reason = $null; Release = $null; Error = $null; NeedsSetup = $setup }
    try { $rel = Get-DreddLatestRelease -Context $Context -Fetch $Fetch }
    catch { $res.Error = $_.Exception.Message; return [pscustomobject]$res }
    $res.Ok = $true; $res.Release = $rel; $res.Latest = $rel.Version
    if ($setup -or -not $current) { $res.IsNewer = [bool]$rel.Version }
    elseif ($rel.Version) { $res.IsNewer = (Compare-DreddVersion $current $rel.Version) -eq -1 }
    if (-not $res.IsNewer) { return [pscustomobject]$res }
    if (-not $setup -and $Context.Binaries.RootSource -ne 'app') { $res.Reason = 'NotOwnFolder' }
    elseif (-not $rel.Asset) { $res.Reason = 'NoAsset' }
    elseif (-not $rel.Asset.Sha256) { $res.Reason = 'NoChecksum' }
    else { $res.CanInstall = $true }
    return [pscustomobject]$res
}

function Save-DreddWebFile {
    # Загрузка файла с прогрессом (сообщения progress { Percent; Bytes }) и отменой.
    param([string]$Url, [string]$Path, [long]$ExpectedSize, $Reporter, $CancellationToken)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = "IPA-PilotDredd/$script:DreddVersion"
    $req.Timeout = 30000; $req.ReadWriteTimeout = 60000
    $resp = $req.GetResponse()
    try {
        $total = if ($resp.ContentLength -gt 0) { $resp.ContentLength } else { $ExpectedSize }
        $in = $resp.GetResponseStream()
        $out = [System.IO.File]::Create($Path)
        try {
            $buf = New-Object byte[] 262144
            $done = 0L; $lastPct = -1
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { throw (New-Object System.OperationCanceledException) }
                $out.Write($buf, 0, $n); $done += $n
                $pct = if ($total -gt 0) { [int]($done * 100 / $total) } else { $null }
                if ($pct -ne $lastPct) { $lastPct = $pct; Write-DreddReport -Reporter $Reporter -Type progress -Area 'Update' -Value @{ Percent = $pct; Bytes = $done } }
            }
        } finally { $out.Dispose(); $in.Dispose() }
    } finally { $resp.Dispose() }
}

function Install-DreddToolUpdate {
    <#
      Ставит ipatool из архива релиза. Результат: Ok, Version, ErrorKey, Message.
      Файлы заменяются только после проверки хеша и пробного запуска; при сбое замены всё возвращается из резервной копии.
    #>
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Release, $Reporter, $CancellationToken, [string]$ZipPath)
    $fail = { param($k, $m) [pscustomobject]@{ Ok = $false; Version = $null; ErrorKey = $k; Message = $m } }
    # -Setup: первая установка — вся папка платформы (ipatool + инструменты устройств и их DLL).
    $setup = Test-DreddNeedsSetup $Context
    if (-not $setup -and $Context.Binaries.RootSource -ne 'app') { return (& $fail 'Err.UpdateNotOwnFolder' '') }
    $asset = $Release.Asset
    if (-not $asset -or -not $asset.Sha256) { return (& $fail 'Err.UpdateNoChecksum' '') }
    $mainApp = Get-DreddMainAppDir $Context
    $work = Join-Path $Context.TempRoot ('update_' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($work)
    try {
        $zip = $ZipPath
        if (-not $zip) {
            $zip = Join-Path $work 'release.zip'
            Write-DreddReport -Reporter $Reporter -Type status -Area 'Update' -Message 'download'
            try { Save-DreddWebFile -Url $asset.Url -Path $zip -ExpectedSize $asset.Size -Reporter $Reporter -CancellationToken $CancellationToken }
            catch [System.OperationCanceledException] { return (& $fail 'Err.Cancelled' '') }
            catch { return (& $fail 'Err.Network' $_.Exception.Message) }
        }
        Write-DreddReport -Reporter $Reporter -Type status -Area 'Update' -Message 'verify'
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($hash -ne $asset.Sha256) { return (& $fail 'Err.UpdateChecksum' "$hash ≠ $($asset.Sha256)") }

        $x = Join-Path $work 'x'
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $x)
        # Новые ipatool по платформам: …/MainApp/<платформа>/ipatool-cpp-*
        $new = @{}
        foreach ($f in [System.IO.Directory]::GetFiles($x, 'ipatool-cpp-*', [System.IO.SearchOption]::AllDirectories)) {
            $plat = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($f))
            $parent = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($f)))
            if ($parent -eq 'MainApp') { $new[$plat] = $f }
        }
        $platDir = $Context.Platform.BinaryFolder
        if (-not $new.ContainsKey($platDir)) { return (& $fail 'Err.UpdateBadArchive' "no ipatool for $platDir") }

        # Пробный запуск нового ipatool для текущей платформы (без аргументов печатает справку).
        $probe = Invoke-DreddProcess -FilePath $new[$platDir] -TimeoutSec 20 -CancellationToken $CancellationToken
        if ($probe.Output -notmatch 'ipatool') { return (& $fail 'Err.UpdateBadArchive' 'new ipatool does not start') }

        Write-DreddReport -Reporter $Reporter -Type status -Area 'Update' -Message 'install'
        $backupRoot = Join-Path $Context.AppRoot 'MainApp_previous'
        $replaced = New-Object System.Collections.Generic.List[object]
        try {
            foreach ($plat in $new.Keys) {
                $destDir = Join-Path $mainApp $plat
                if ($setup -and $plat -eq $platDir) {
                    # Первая установка: копируем всю папку платформы из релиза (файлы, которых ещё нет).
                    [void][System.IO.Directory]::CreateDirectory($destDir)
                    foreach ($f in [System.IO.Directory]::GetFiles([System.IO.Path]::GetDirectoryName($new[$plat]))) {
                        $to = Join-Path $destDir ([System.IO.Path]::GetFileName($f))
                        if (-not [System.IO.File]::Exists($to)) { [System.IO.File]::Copy($f, $to); $replaced.Add(@{ Dest = $to; Backup = $null; New = $true }) }
                    }
                    continue
                }
                if (-not [System.IO.Directory]::Exists($destDir)) { continue }
                $name = [System.IO.Path]::GetFileName($new[$plat])
                $dest = Join-Path $destDir $name
                if ([System.IO.File]::Exists($dest)) {
                    $bdir = Join-Path $backupRoot $plat
                    [void][System.IO.Directory]::CreateDirectory($bdir)
                    [System.IO.File]::Copy($dest, (Join-Path $bdir $name), $true)
                }
                [System.IO.File]::Copy($new[$plat], $dest, $true)
                $replaced.Add(@{ Dest = $dest; Backup = (Join-Path (Join-Path $backupRoot $plat) $name) })
            }
        } catch {
            foreach ($r in $replaced) {
                try {
                    if ($r.New) { if ([System.IO.File]::Exists($r.Dest)) { [System.IO.File]::Delete($r.Dest) } }
                    elseif ($r.Backup -and [System.IO.File]::Exists($r.Backup)) { [System.IO.File]::Copy($r.Backup, $r.Dest, $true) }
                } catch { }
            }
            return (& $fail 'Err.UpdateInstall' $_.Exception.Message)
        }
        $prev = Get-DreddToolVersion $Context
        if ($prev) { Write-DreddTextFile -Path (Join-Path $backupRoot $script:ToolVersionFile) -Content $prev }
        Write-DreddTextFile -Path (Join-Path $mainApp $script:ToolVersionFile) -Content $Release.Version
        Write-DreddReport -Reporter $Reporter -Type log -Level Success -Area 'Update' -Message ("ipatool {0} → {1}" -f $prev, $Release.Version)
        return [pscustomobject]@{ Ok = $true; Version = $Release.Version; ErrorKey = $null; Message = '' }
    } finally {
        try { if ([System.IO.Directory]::Exists($work)) { [System.IO.Directory]::Delete($work, $true) } } catch { }
    }
}

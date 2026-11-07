# Загрузка IPA во временную папку (-o), проверка, переименование, перенос, история (ADR-007, ADR-008, ADR-009).

$script:RePercent = New-Object System.Text.RegularExpressions.Regex('(?<!\d)(\d{1,3}(?:[.,]\d+)?)\s?%', 'Compiled')
# ipatool-cpp при загрузке печатает строки "PROGRESS:37" (проверено по журналу реальной загрузки 2026-10-24).
$script:ReToolProgress = New-Object System.Text.RegularExpressions.Regex('^\s*PROGRESS:\s*(\d{1,3}(?:[.,]\d+)?)\s*$', 'Compiled')

function Get-DreddProgressFromLine {
    # Процент из строки вывода: "PROGRESS:N" (ipatool-cpp) или "N%" (ideviceinstaller и старые сборки).
    param([string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return $null }
    $tm = $script:ReToolProgress.Match($Line)
    $m = if ($tm.Success) { @($tm) } else { $script:RePercent.Matches($Line) }
    if ($m.Count -eq 0) { return $null }
    $v = 0.0
    $txt = $m[$m.Count - 1].Groups[1].Value.Replace(',', '.')
    if ([double]::TryParse($txt, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
        if ($v -ge 0 -and $v -le 100) { return $v }
    }
    return $null
}

function Get-DreddQueuePath { param($Context) Join-Path $Context.FilesDir 'Queue.json' }

function Save-DreddQueue {
    <#
      Незавершённая очередь загрузок (Files/Queue.json), чтобы продолжить после перезапуска.
      Items: AppId, AppName, VersionId, VersionText, Purchase, InstallUdid, InstallDevice, AccountKey (хеш email, не сам email).
      Пустой список удаляет файл.
    #>
    param([Parameter(Mandatory)]$Context, [object[]]$Items)
    $path = Get-DreddQueuePath $Context
    $rows = @($Items | Where-Object { $_ -and $_.AppId -match '^\d+$' } | ForEach-Object {
        [ordered]@{
            AppId = [string]$_.AppId; AppName = [string]$_.AppName; VersionId = [string]$_.VersionId; VersionText = [string]$_.VersionText
            Purchase = [bool]$_.Purchase; InstallUdid = [string]$_.InstallUdid; InstallDevice = [string]$_.InstallDevice; AccountKey = [string]$_.AccountKey
        }
    })
    if ($rows.Count -eq 0) { if ([System.IO.File]::Exists($path)) { [System.IO.File]::Delete($path) }; return }
    Write-DreddTextFile -Path $path -Content (ConvertTo-Json -InputObject $rows -Depth 3)
}

function Read-DreddQueue {
    # Сохранённая очередь; -AccountKey — только записи этого аккаунта.
    param([Parameter(Mandatory)]$Context, [string]$AccountKey)
    $data = Read-DreddJsonFile -Path (Get-DreddQueuePath $Context)
    if ($null -eq $data) { return @() }
    $rows = @($data | Where-Object { $_ -and ([string](Get-DreddProp $_ 'AppId')) -match '^\d+$' } | ForEach-Object {
        [pscustomobject]@{
            AppId = [string](Get-DreddProp $_ 'AppId'); AppName = [string](Get-DreddProp $_ 'AppName'); VersionId = [string](Get-DreddProp $_ 'VersionId')
            VersionText = [string](Get-DreddProp $_ 'VersionText'); Purchase = [bool](Get-DreddProp $_ 'Purchase' $false)
            InstallUdid = [string](Get-DreddProp $_ 'InstallUdid'); InstallDevice = [string](Get-DreddProp $_ 'InstallDevice'); AccountKey = [string](Get-DreddProp $_ 'AccountKey')
        }
    })
    if ($AccountKey) { $rows = @($rows | Where-Object { $_.AccountKey -eq $AccountKey }) }
    return $rows
}

function Get-DreddFolderSize {
    param([string]$Folder)
    if (-not [System.IO.Directory]::Exists($Folder)) { return 0 }
    $sum = 0L
    foreach ($f in [System.IO.Directory]::GetFiles($Folder, '*', [System.IO.SearchOption]::AllDirectories)) {
        try { $sum += (New-Object System.IO.FileInfo($f)).Length } catch { }
    }
    return $sum
}

function Test-DreddFreeSpace {
    <#
      Хватит ли места на дисках временной папки и папки загрузок. Нужно: размер из App Store × 1,5 + 200 МБ
      (сжатый IPA бывает чуть больше заявленного), а если размер неизвестен — 300 МБ. Результат: Ok, Drive, FreeBytes, NeedBytes.
      Если свободное место узнать нельзя (сетевая папка) — Ok, загрузка не блокируется.
    #>
    param([string[]]$Folders, [long]$ExpectedBytes)
    $need = if ($ExpectedBytes -gt 0) { [long]($ExpectedBytes * 1.5) + 200MB } else { 300MB }
    foreach ($f in @($Folders | Where-Object { $_ })) {
        try {
            $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($f))
            if (-not $root -or $root.StartsWith('\\')) { continue }
            $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace
            if ($free -lt $need) { return [pscustomobject]@{ Ok = $false; Drive = $root.TrimEnd('\'); FreeBytes = $free; NeedBytes = $need } }
        } catch { }
    }
    return [pscustomobject]@{ Ok = $true; Drive = $null; FreeBytes = 0L; NeedBytes = $need }
}

function Invoke-DreddDownload {
    <#
      Скачивает приложение. Результат: Ok, Path, Metadata, Error{Key,Message}, Cancelled.
      Сообщения прогресса: Type=progress, Value = @{ Percent = <0..100 | $null>; Bytes = <long> }.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$AppId,
        [string]$AppName,
        [string]$VersionId,
        [string]$VersionLabel,
        [switch]$Purchase,
        [string]$Account,
        [string]$DestinationFolder,
        [long]$ExpectedBytes,
        $Reporter,
        $CancellationToken
    )
    if ($AppId -notmatch '^\d+$') { return [pscustomobject]@{ Ok = $false; Path = $null; Metadata = $null; Cancelled = $false; Error = [pscustomobject]@{ Key = 'Err.InvalidId'; Message = $AppId } } }
    if (-not $DestinationFolder) { $DestinationFolder = $Context.DownloadDir }
    if (-not [System.IO.Directory]::Exists($DestinationFolder)) { [void][System.IO.Directory]::CreateDirectory($DestinationFolder) }
    $space = Test-DreddFreeSpace -Folders @($Context.TempRoot, $DestinationFolder) -ExpectedBytes $ExpectedBytes
    if (-not $space.Ok) {
        $msg = '{0}: {1:N0} MB < {2:N0} MB' -f $space.Drive, ($space.FreeBytes / 1MB), ($space.NeedBytes / 1MB)
        Write-DreddReport -Reporter $Reporter -Type log -Level Error -Area 'Download' -Message ("✖ {0}: {1}" -f $(if ($AppName) { $AppName } else { $AppId }), $msg)
        return [pscustomobject]@{ Ok = $false; Path = $null; Metadata = $null; Cancelled = $false; Error = [pscustomobject]@{ Key = 'Err.NoSpace'; Message = $msg } }
    }

    $temp = Join-Path $Context.TempRoot ([guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($temp)
    $tempFile = Join-Path $temp "$AppId.ipa"
    $label = if ($AppName) { $AppName } else { $AppId }

    try {
        $a = @('download', '-i', $AppId, '-o', $tempFile)
        if ($VersionId) { $a += @('--external-version-id', $VersionId) }
        if ($Purchase) { $a += '--purchase' }

        Write-DreddReport -Reporter $Reporter -Type log -Area 'Download' -Message ("▶ {0} (ID {1}{2})" -f $label, $AppId, $(if ($VersionLabel) { ", v$VersionLabel" } elseif ($VersionId) { ", version id $VersionId" } else { '' }))
        Write-DreddReport -Reporter $Reporter -Type progress -Area 'Download' -Value @{ Percent = $null; Bytes = 0L }

        # Прогресс: процент из вывода, а если его нет — растущий размер временной папки.
        $dreddDlReporter = $Reporter; $dreddDlTemp = $temp
        $dreddDlState = @{ Percent = $null; LastPercentAt = [datetime]::MinValue }
        $onLine = {
            param($line, $stream)
            $p = Get-DreddProgressFromLine $line
            if ($null -ne $p) {
                # ipatool повторяет одно и то же значение сотни раз — отправляем только изменения.
                if ($dreddDlState.Percent -eq $p) { return }
                $dreddDlState.Percent = $p
                Write-DreddReport -Reporter $dreddDlReporter -Type progress -Area 'Download' -Value @{ Percent = $p; Bytes = $null }
            } elseif (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-DreddReport -Reporter $dreddDlReporter -Type log -Level Debug -Area 'Download' -Message $line
            }
        }
        $onTick = {
            $bytes = Get-DreddFolderSize $dreddDlTemp
            Write-DreddReport -Reporter $dreddDlReporter -Type progress -Area 'Download' -Value @{ Percent = $dreddDlState.Percent; Bytes = $bytes }
        }
        $r = Invoke-DreddIpatool -Context $Context -Arguments $a -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 0 -Area 'Download' -OnLine $onLine -OnTick $onTick

        if ($r.Cancelled) {
            Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Download' -Message "■ $label"
            return [pscustomobject]@{ Ok = $false; Path = $null; Metadata = $null; Cancelled = $true; Error = [pscustomobject]@{ Key = 'Err.Cancelled'; Message = '' } }
        }

        # ipatool может сохранить файл под своим именем — берём любой .ipa во временной папке.
        $produced = @([System.IO.Directory]::GetFiles($temp, '*.ipa', [System.IO.SearchOption]::AllDirectories))
        if (-not $r.Ok -or $produced.Count -eq 0) {
            $err = $r.Error
            if (-not $err) { $err = [pscustomobject]@{ Key = 'Err.NoFile'; Message = 'ipatool finished without an IPA file' } }
            if ($err.Key -eq 'Err.License' -and -not $Purchase) { $err = [pscustomobject]@{ Key = 'Err.LicenseNoPurchase'; Message = $err.Message } }
            Write-DreddReport -Reporter $Reporter -Type log -Level Error -Area 'Download' -Message ("✖ {0}: {1}" -f $label, $err.Message)
            return [pscustomobject]@{ Ok = $false; Path = $null; Metadata = $null; Cancelled = $false; Error = $err }
        }

        $src = $produced[0]
        $meta = Get-DreddIpaMetadata -Path $src
        if ($meta.Error) {
            return [pscustomobject]@{ Ok = $false; Path = $null; Metadata = $meta; Cancelled = $false; Error = [pscustomobject]@{ Key = 'Err.BadIpa'; Message = $meta.Error } }
        }

        # Имя: из списка/запроса, иначе из метаданных (как 4.2: название из списка приоритетнее CFBundleName).
        $finalName = $AppName
        if ([string]::IsNullOrWhiteSpace($finalName) -or $finalName -eq $AppId) { $finalName = Resolve-DreddAppName -Context $Context -AppId $AppId }
        if ([string]::IsNullOrWhiteSpace($finalName)) { $finalName = $meta.Name }
        $acc = $null
        if (ConvertTo-DreddBool $Context.Settings['FileNameIncludeAccount']) { $acc = $Account }
        $fileName = Get-DreddIpaFileName -Name $finalName -Version $meta.Version -MinIOS $meta.MinIOS -Account $acc
        $dest = Get-DreddUniquePath -Folder $DestinationFolder -FileName $fileName
        [System.IO.File]::Move($src, $dest)
        $meta = Get-DreddIpaMetadata -Path $dest

        Add-DreddHistoryEntry -Context $Context -Kind Download -AppId $AppId -Name $finalName -Version $meta.Version -Account $Account -File ([System.IO.Path]::GetFileName($dest)) -Result Success
        if ($Purchase -and $Account) { [void](Add-DreddPurchasedApp -Context $Context -Account $Account -AppId $AppId -Name $finalName) }
        Write-DreddReport -Reporter $Reporter -Type progress -Area 'Download' -Value @{ Percent = 100.0; Bytes = $meta.SizeBytes }
        Write-DreddReport -Reporter $Reporter -Type log -Level Success -Area 'Download' -Message ("✔ {0} → {1}" -f $label, [System.IO.Path]::GetFileName($dest))
        return [pscustomobject]@{ Ok = $true; Path = $dest; Metadata = $meta; Cancelled = $false; Error = $null }
    } finally {
        try { if ([System.IO.Directory]::Exists($temp)) { [System.IO.Directory]::Delete($temp, $true) } } catch { }
    }
}

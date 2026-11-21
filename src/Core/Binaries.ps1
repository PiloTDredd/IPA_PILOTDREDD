# Поиск ipatool и инструментов libimobiledevice (ADR-004).

function Get-DreddBinaryCandidates {
    param([Parameter(Mandatory)][string]$AppRoot, [string]$Configured)
    $parent = [System.IO.Path]::GetDirectoryName($AppRoot.TrimEnd('\', '/'))
    $list = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrWhiteSpace($Configured)) { $list.Add([pscustomobject]@{ Path = $Configured; Source = 'settings' }) }
    $list.Add([pscustomobject]@{ Path = (Join-Path $AppRoot 'MainApp'); Source = 'app' })
    if ($parent) {
        $list.Add([pscustomobject]@{ Path = (Join-Path $parent (Join-Path 'IPA_Downloader_4.2.0' 'MainApp')); Source = 'v4.2' })
        $list.Add([pscustomobject]@{ Path = (Join-Path $parent 'MainApp'); Source = 'v4.1' })
    }
    return $list.ToArray()
}

function Find-DreddFileByPattern {
    param([string]$Folder, [string]$Pattern)
    if (-not $Folder -or -not [System.IO.Directory]::Exists($Folder)) { return $null }
    $f = [System.IO.Directory]::GetFiles($Folder, $Pattern) | Sort-Object | Select-Object -First 1
    return $f
}

function Select-DreddIpatoolFile {
    <#
      Какой ipatool запускать, если в папке их несколько (ADR-028). Не «первый по алфавиту»:
        1) каноническое имя: после «ipatool-cpp-» сразу платформа (ipatool-cpp-windows-amd64.exe) — его пишут установка и обновления;
        2) иначе распознанная версия в имени (ipatool-cpp-1.3.4-windows-amd64.exe) — самая высокая;
        3) иначе нераспознанная версия (ipatool-cpp-1.3.4b-…);
        4) иначе прочие (старые раскладки 4.1/4.2 с одним файлом).
      Внутри группы и при равных версиях — первый по имени (порядок на входе не важен).
    #>
    param([string[]]$Files)
    $all = @($Files | Where-Object { $_ } | Sort-Object { [System.IO.Path]::GetFileName($_).ToLowerInvariant() }, { $_ })
    if ($all.Count -le 1) { return ($all | Select-Object -First 1) }
    $name = { param($f) [System.IO.Path]::GetFileName($f) }
    $canonical = @($all | Where-Object { (& $name $_) -match '^ipatool-cpp-[A-Za-z]' })
    if ($canonical.Count -gt 0) { return $canonical[0] }
    $reVersioned = '^ipatool-cpp-(\d+(?:\.\d+)+)-'
    $best = $null; $bestVer = $null
    foreach ($f in $all) {
        $m = [regex]::Match((& $name $f), $reVersioned)
        if (-not $m.Success) { continue }
        $v = $m.Groups[1].Value
        if (-not $best -or (Compare-DreddVersion $v $bestVer) -eq 1) { $best = $f; $bestVer = $v }
    }
    if ($best) { return $best }
    $unparsed = @($all | Where-Object { (& $name $_) -match '^ipatool-cpp-\d' })
    if ($unparsed.Count -gt 0) { return $unparsed[0] }
    return $all[0]
}

function Find-DreddCommand {
    param([string]$Name)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-DreddBinaries {
    <#
      Возвращает объект с путями: Ipatool, IdeviceInstaller, IdeviceId, IdeviceInfo; Root (папка платформы), RootSource,
      Candidates (что проверялось), MissingDlls (Windows), Notes.
    #>
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string]$Configured,
        $Platform = (Get-DreddPlatform)
    )
    $result = [ordered]@{
        Root = $null; RootSource = $null; Ipatool = $null; IdeviceInstaller = $null; IdeviceId = $null; IdeviceInfo = $null
        MissingDlls = @(); Candidates = @(); Notes = @()
    }
    $checked = @()
    foreach ($c in (Get-DreddBinaryCandidates -AppRoot $AppRoot -Configured $Configured)) {
        $platformDir = $c.Path
        # Путь может указывать как на MainApp, так и сразу на папку платформы:
        $sub = Join-Path $c.Path $Platform.BinaryFolder
        if ([System.IO.Directory]::Exists($sub)) { $platformDir = $sub }
        $ipatoolPattern = if ($Platform.IsWindows) { 'ipatool*.exe' } else { 'ipatool*' }
        $found = @()
        if ([System.IO.Directory]::Exists($platformDir)) { $found = @([System.IO.Directory]::GetFiles($platformDir, $ipatoolPattern)) }
        $ipatool = Select-DreddIpatoolFile -Files $found
        $checked += [pscustomobject]@{ Path = $platformDir; Source = $c.Source; Found = [bool]$ipatool }
        if ($ipatool -and -not $result.Ipatool) {
            $result.Root = $platformDir
            $result.RootSource = $c.Source
            $result.Ipatool = $ipatool
            if ($found.Count -gt 1) {
                $result.Notes += ('several ipatool files: {0}; using {1}' -f (($found | ForEach-Object { [System.IO.Path]::GetFileName($_) }) -join ', '), [System.IO.Path]::GetFileName($ipatool))
            }
        }
    }
    $result.Candidates = $checked

    if ($Platform.IsWindows) {
        # Инструменты устройств ищем в той же папке; если их там нет (4.1), — в других кандидатах.
        $folders = @()
        if ($result.Root) { $folders += $result.Root }
        $folders += @($checked | Where-Object { $_.Path -ne $result.Root } | ForEach-Object { $_.Path })
        foreach ($folder in $folders) {
            $id = Find-DreddFileByPattern -Folder $folder -Pattern 'idevice_id*.exe'
            $inst = Find-DreddFileByPattern -Folder $folder -Pattern 'ideviceinstaller*.exe'
            if ($id -and $inst) {
                $result.IdeviceId = $id
                $result.IdeviceInstaller = $inst
                $result.IdeviceInfo = Find-DreddFileByPattern -Folder $folder -Pattern 'ideviceinfo*.exe'
                if ($folder -ne $result.Root) { $result.Notes += "device tools from $folder" }
                break
            }
        }
        if (-not $result.IdeviceInstaller) {
            # 4.1: статический ideviceinstaller без idevice_id — установка возможна, выбор устройств нет.
            foreach ($folder in $folders) {
                $inst = Find-DreddFileByPattern -Folder $folder -Pattern 'ideviceinstaller*.exe'
                if ($inst) { $result.IdeviceInstaller = $inst; $result.Notes += 'idevice_id not found'; break }
            }
        }
    } else {
        $result.IdeviceInstaller = Find-DreddCommand 'ideviceinstaller'
        $result.IdeviceId = Find-DreddCommand 'idevice_id'
        $result.IdeviceInfo = Find-DreddCommand 'ideviceinfo'
        if ($result.Ipatool) {
            try {
                if ($Platform.IsMac) { & xattr -cr $result.Root 2>$null }
                & chmod +x $result.Ipatool 2>$null
            } catch { }
        }
    }
    return [pscustomobject]$result
}

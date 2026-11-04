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
        $ipatool = Find-DreddFileByPattern -Folder $platformDir -Pattern $ipatoolPattern
        $checked += [pscustomobject]@{ Path = $platformDir; Source = $c.Source; Found = [bool]$ipatool }
        if ($ipatool -and -not $result.Ipatool) {
            $result.Root = $platformDir
            $result.RootSource = $c.Source
            $result.Ipatool = $ipatool
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

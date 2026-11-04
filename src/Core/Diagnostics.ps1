# Диагностика окружения и безопасный отчёт (без email, имени пользователя и содержимого ~/.ipatool).

function Test-DreddWritable {
    param([string]$Folder)
    try {
        if (-not [System.IO.Directory]::Exists($Folder)) { [void][System.IO.Directory]::CreateDirectory($Folder) }
        $probe = Join-Path $Folder ('.write_test_' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($probe, 'x')
        [System.IO.File]::Delete($probe)
        return $true
    } catch { return $false }
}

function Get-DreddEnvironment {
    # Быстрая сводка для Dashboard (без сети и без запуска ipatool).
    param([Parameter(Mandatory)]$Context)
    $b = $Context.Binaries
    $libCount = 0; $libSize = 0L
    if ([System.IO.Directory]::Exists($Context.DownloadDir)) {
        foreach ($f in [System.IO.Directory]::GetFiles($Context.DownloadDir, '*.ipa')) { $libCount++; $libSize += (New-Object System.IO.FileInfo($f)).Length }
    }
    [pscustomobject]@{
        Version          = $Context.Version
        Platform         = $Context.Platform
        BinaryRoot       = $b.Root
        BinarySource     = $b.RootSource
        HasIpatool       = [bool]$b.Ipatool
        HasInstaller     = [bool]$b.IdeviceInstaller
        HasIdeviceId     = [bool]$b.IdeviceId
        HasIdeviceInfo   = [bool]$b.IdeviceInfo
        MissingDlls      = @($b.MissingDlls)
        HasSessionFiles  = [System.IO.File]::Exists((Join-Path $Context.IpatoolHome 'account'))
        HasLoginMarker   = [System.IO.File]::Exists((Join-Path $Context.IpatoolHome 'login'))
        HasPassphrase    = [System.IO.File]::Exists((Join-Path $Context.IpatoolHome 'keychain-passphrase'))
        SavedAccounts    = @(Get-DreddSavedAccounts -Context $Context).Count
        DownloadDir      = $Context.DownloadDir
        LibraryCount     = $libCount
        LibrarySizeBytes = $libSize
        PopularCount     = @(Get-DreddPopularApps -Context $Context).Count
        CustomCount      = @(Get-DreddCustomApps -Context $Context).Count
    }
}

function Get-DreddDiagnostics {
    <#
      Таблица проверок: Id, Status (OK | Warning | Error), Detail, HintKey. Тексты подсказок — ключи локализации Diag.*.
    #>
    param([Parameter(Mandatory)]$Context)
    $b = $Context.Binaries
    $p = $Context.Platform
    $checks = New-Object System.Collections.Generic.List[object]
    $add = { param($id, $status, $detail, $hint) $checks.Add([pscustomobject]@{ Id = $id; Status = $status; Detail = $detail; HintKey = $hint }) }

    & $add 'BinaryRoot' $(if ($b.Root) { 'OK' } else { 'Error' }) $(if ($b.Root) { "$($b.Root) [$($b.RootSource)]" } else { (@($b.Candidates | ForEach-Object { $_.Path }) -join '; ') }) 'Diag.Hint.BinaryRoot'
    $ipaDetail = ''
    if ($b.Ipatool) { $ipaDetail = "{0} ({1:N1} MB)" -f [System.IO.Path]::GetFileName($b.Ipatool), ((New-Object System.IO.FileInfo($b.Ipatool)).Length / 1MB) }
    & $add 'Ipatool' $(if ($b.Ipatool) { 'OK' } else { 'Error' }) $ipaDetail 'Diag.Hint.Ipatool'
    & $add 'IdeviceInstaller' $(if ($b.IdeviceInstaller) { 'OK' } else { 'Warning' }) $(if ($b.IdeviceInstaller) { [System.IO.Path]::GetFileName($b.IdeviceInstaller) } else { '' }) $(if ($p.IsWindows) { 'Diag.Hint.DeviceToolsWin' } elseif ($p.IsMac) { 'Diag.Hint.DeviceToolsMac' } else { 'Diag.Hint.DeviceToolsLinux' })
    & $add 'IdeviceId' $(if ($b.IdeviceId) { 'OK' } else { 'Warning' }) $(if ($b.IdeviceId) { [System.IO.Path]::GetFileName($b.IdeviceId) } else { '' }) $(if ($p.IsWindows) { 'Diag.Hint.DeviceToolsWin' } elseif ($p.IsMac) { 'Diag.Hint.DeviceToolsMac' } else { 'Diag.Hint.DeviceToolsLinux' })
    & $add 'IdeviceInfo' $(if ($b.IdeviceInfo) { 'OK' } else { 'Warning' }) $(if ($b.IdeviceInfo) { [System.IO.Path]::GetFileName($b.IdeviceInfo) } else { '' }) 'Diag.Hint.IdeviceInfo'
    if ($p.IsWindows -and $b.IdeviceId) {
        $missing = @($b.MissingDlls)
        & $add 'Dlls' $(if ($missing.Count -eq 0) { 'OK' } else { 'Error' }) $(if ($missing.Count -eq 0) { '11/11' } else { $missing -join ', ' }) 'Diag.Hint.Dlls'
    }
    if ($p.IsWindows) {
        $amds = $null
        try { $amds = Get-Service -Name 'Apple Mobile Device Service' -ErrorAction Stop } catch { }
        $appleDevices = $null
        try { $appleDevices = Get-Process -Name 'AppleMobileDeviceProcess', 'AppleDevices' -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { }
        $st = if ($amds -and $amds.Status -eq 'Running') { 'OK' } elseif ($amds) { 'Warning' } elseif ($appleDevices) { 'OK' } else { 'Warning' }
        $detail = if ($amds) { "Apple Mobile Device Service: $($amds.Status)" } elseif ($appleDevices) { 'Apple Devices' } else { 'not found' }
        & $add 'AppleDriver' $st $detail 'Diag.Hint.AppleDriver'
    }
    & $add 'AppsList' $(if (@(Get-DreddPopularApps -Context $Context).Count -gt 0) { 'OK' } else { 'Warning' }) ("{0}" -f @(Get-DreddPopularApps -Context $Context).Count) 'Diag.Hint.AppsList'
    & $add 'DownloadDir' $(if (Test-DreddWritable $Context.DownloadDir) { 'OK' } else { 'Error' }) $Context.DownloadDir 'Diag.Hint.Writable'
    & $add 'FilesDir' $(if (Test-DreddWritable $Context.FilesDir) { 'OK' } else { 'Error' }) $Context.FilesDir 'Diag.Hint.Writable'
    & $add 'TempDir' $(if (Test-DreddWritable $Context.TempRoot) { 'OK' } else { 'Error' }) $Context.TempRoot 'Diag.Hint.Writable'
    $hasSession = [System.IO.File]::Exists((Join-Path $Context.IpatoolHome 'account'))
    & $add 'Session' $(if ($hasSession) { 'OK' } else { 'Warning' }) $(if ($hasSession) { 'account: yes' } else { 'account: no' }) 'Diag.Hint.Session'
    try {
        $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Context.DownloadDir))
        $freeGb = [Math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        & $add 'FreeSpace' $(if ($freeGb -ge 2) { 'OK' } else { 'Warning' }) ("{0} GB" -f $freeGb) 'Diag.Hint.FreeSpace'
    } catch { }
    return $checks.ToArray()
}

function Protect-DreddPath {
    # Заменяет домашнюю папку на ~ и имя пользователя на <user>.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $home1 = [Environment]::GetFolderPath('UserProfile')
    if ($home1) { $Text = $Text.Replace($home1, '~') }
    $user = [Environment]::UserName
    if ($user -and $user.Length -ge 2) { $Text = [regex]::Replace($Text, [regex]::Escape($user), '<user>', 'IgnoreCase') }
    return (Protect-LogText $Text)
}

function New-DreddDiagnosticReport {
    param([Parameter(Mandatory)]$Context)
    $p = $Context.Platform
    $envInfo = Get-DreddEnvironment -Context $Context
    $sb = New-Object System.Text.StringBuilder
    $w = { param($s) [void]$sb.AppendLine((Protect-DreddPath $s)) }
    & $w "IPA PILOTDREDD $($Context.Version) — diagnostic report"
    & $w ("Generated: {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date))
    & $w ''
    & $w "[System]"
    & $w "OS: $($p.OSDescription) ($($p.Arch))"
    & $w "PowerShell: $($p.PSVersion) $($p.PSEdition)"
    & $w "Runtime: $($p.Runtime)"
    & $w "App root: $($Context.AppRoot)"
    & $w ''
    & $w "[Checks]"
    foreach ($c in (Get-DreddDiagnostics -Context $Context)) { & $w ("{0,-17} {1,-8} {2}" -f $c.Id, $c.Status, $c.Detail) }
    & $w ''
    & $w "[Binaries]"
    foreach ($c in @($Context.Binaries.Candidates)) { & $w ("candidate [{0}] {1} → {2}" -f $c.Source, $c.Path, $(if ($c.Found) { 'ipatool found' } else { '-' })) }
    foreach ($n in @($Context.Binaries.Notes)) { & $w "note: $n" }
    & $w ''
    & $w "[Data]"
    & $w "Library: $($envInfo.LibraryCount) IPA, $([Math]::Round($envInfo.LibrarySizeBytes / 1MB, 1)) MB"
    & $w "Lists: popular $($envInfo.PopularCount), custom $($envInfo.CustomCount)"
    & $w "Session files: $($envInfo.HasSessionFiles); login marker: $($envInfo.HasLoginMarker); passphrase file: $($envInfo.HasPassphrase); saved accounts: $($envInfo.SavedAccounts)"
    & $w ''
    & $w "[Settings]"
    foreach ($k in $Context.Settings.Keys) { & $w ("{0}={1}" -f $k, $Context.Settings[$k]) }
    return $sb.ToString()
}

function Export-DreddDiagnosticReport {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Path)
    Write-DreddTextFile -Path $Path -Content (New-DreddDiagnosticReport -Context $Context)
    return $Path
}

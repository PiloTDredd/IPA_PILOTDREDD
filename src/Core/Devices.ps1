# Устройства iPhone/iPad по USB: idevice_id, ideviceinfo, ideviceinstaller (поведение 4.2 + модель и статус).

function ConvertTo-DreddIosVersion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $t = $Text.Trim()
    if ($t -notmatch '^\d+(\.\d+){0,3}$') { return $null }
    $parts = @($t -split '\.')
    while ($parts.Count -lt 2) { $parts += '0' }
    return [version]($parts -join '.')
}

function Test-DreddIosCompatible {
    # $true — совместимо, $false — устройство старее требуемого, $null — сравнить нельзя.
    param([string]$MinIOS, [string]$DeviceVersion)
    $req = ConvertTo-DreddIosVersion $MinIOS
    $dev = ConvertTo-DreddIosVersion $DeviceVersion
    if ($null -eq $req -or $null -eq $dev) { return $null }
    return ($dev -ge $req)
}

function Get-DreddDeviceToolEnv {
    param($Context)
    $root = $null
    if ($Context.Binaries.IdeviceId) { $root = [System.IO.Path]::GetDirectoryName($Context.Binaries.IdeviceId) }
    elseif ($Context.Binaries.IdeviceInstaller) { $root = [System.IO.Path]::GetDirectoryName($Context.Binaries.IdeviceInstaller) }
    if (-not $root) { return @{} }
    return @{ PATH = ($root + [System.IO.Path]::PathSeparator + [Environment]::GetEnvironmentVariable('PATH')) }
}

function Get-DreddDevices {
    <#
      Список подключённых устройств: UDID, Name, ProductType, iOSVersion, Status (Ready | NotTrusted | Error), Detail.
      Возвращает объект: Ok, Devices, ErrorKey, Message.
    #>
    param([Parameter(Mandatory)]$Context, $Reporter, $CancellationToken)
    $b = $Context.Binaries
    if (-not $b.IdeviceId) {
        return [pscustomobject]@{ Ok = $false; Devices = @(); ErrorKey = 'Err.NoIdeviceId'; Message = '' }
    }
    $env1 = Get-DreddDeviceToolEnv $Context
    $list = Invoke-DreddProcess -FilePath $b.IdeviceId -ArgumentList @('-l') -TimeoutSec 20 -CancellationToken $CancellationToken -Environment $env1
    if ($list.Cancelled) { return [pscustomobject]@{ Ok = $false; Devices = @(); ErrorKey = 'Err.Cancelled'; Message = '' } }
    $udids = @($list.StdOut -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[0-9A-Fa-f-]{20,}$' } | Select-Object -Unique)
    if ($list.ExitCode -ne 0 -and $udids.Count -eq 0) {
        $msg = (Protect-LogText $list.Output).Trim()
        Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Devices' -Message ("idevice_id: exit {0} {1}" -f $list.ExitCode, $msg)
        # usbmuxd/драйвер Apple недоступен — отличаем от «нет устройств», если есть понятный текст.
        $key = 'Err.NoDevices'
        if ($msg -match '(?i)(usbmux|unable to connect|could not connect|no such file)') { $key = 'Err.UsbMux' }
        return [pscustomobject]@{ Ok = $false; Devices = @(); ErrorKey = $key; Message = $msg }
    }

    $devices = foreach ($udid in $udids) {
        if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { break }
        $d = [ordered]@{ UDID = $udid; Name = $null; ProductType = $null; iOSVersion = $null; DeviceClass = $null; Status = 'Ready'; Detail = '' }
        $n = Invoke-DreddProcess -FilePath $b.IdeviceId -ArgumentList @($udid) -TimeoutSec 15 -CancellationToken $CancellationToken -Environment $env1
        if ($n.ExitCode -eq 0) { $d.Name = ($n.StdOut.Trim() -split "`r?`n" | Select-Object -First 1) }
        if ($b.IdeviceInfo) {
            $i = Invoke-DreddProcess -FilePath $b.IdeviceInfo -ArgumentList @('-u', $udid) -TimeoutSec 20 -CancellationToken $CancellationToken -Environment $env1
            if ($i.ExitCode -eq 0) {
                foreach ($line in ($i.StdOut -split "`r?`n")) {
                    if ($line -match '^(\w+):\s*(.*)$') {
                        switch ($Matches[1]) {
                            'DeviceName' { if (-not $d.Name) { $d.Name = $Matches[2].Trim() } }
                            'ProductType' { $d.ProductType = $Matches[2].Trim() }
                            'ProductVersion' { $d.iOSVersion = $Matches[2].Trim() }
                            'DeviceClass' { $d.DeviceClass = $Matches[2].Trim() }
                        }
                    }
                }
            } else {
                $txt = (Protect-LogText $i.Output).Trim()
                $d.Detail = $txt
                if ($txt -match '(?i)(pair|trust|lockdown|password protected|invalid host)') { $d.Status = 'NotTrusted' } else { $d.Status = 'Error' }
            }
        }
        if (-not $d.Name) { $d.Name = 'iOS device' }
        [pscustomobject]$d
    }
    $devices = @($devices)
    return [pscustomobject]@{ Ok = $true; Devices = $devices; ErrorKey = $(if ($devices.Count -eq 0) { 'Err.NoDevices' } else { $null }); Message = '' }
}

function Install-DreddIpa {
    <#
      Установка IPA на устройство: копия во временную папку (ASCII-путь, как Temp.ipa в 4.2) → install, при ошибке upgrade.
      Результат: Ok, ErrorKey, Message, Output.
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$IpaPath,
        [string]$UDID,
        $Reporter,
        $CancellationToken
    )
    $inst = $Context.Binaries.IdeviceInstaller
    if (-not $inst) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.NoInstaller'; Message = ''; Output = '' } }
    if (-not [System.IO.File]::Exists($IpaPath)) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.NoFile'; Message = $IpaPath; Output = '' } }

    $temp = Join-Path $Context.TempRoot ('install_' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($temp)
    $tmpIpa = Join-Path $temp 'app.ipa'
    $env1 = Get-DreddDeviceToolEnv $Context
    $dreddInstReporter = $Reporter
    $onLine = {
        param($line, $stream)
        if ([string]::IsNullOrWhiteSpace($line)) { return }
        $p = Get-DreddProgressFromLine $line
        if ($null -ne $p) { Write-DreddReport -Reporter $dreddInstReporter -Type progress -Area 'Install' -Value @{ Percent = $p } }
        Write-DreddReport -Reporter $dreddInstReporter -Type log -Level Debug -Area 'Install' -Message $line
    }
    try {
        [System.IO.File]::Copy($IpaPath, $tmpIpa, $true)
        $baseArgs = @()
        if ($UDID) { $baseArgs = @('-u', $UDID) }
        $r = Invoke-DreddProcess -FilePath $inst -ArgumentList ($baseArgs + @('install', $tmpIpa)) -TimeoutSec 900 -CancellationToken $CancellationToken -OnLine $onLine -Environment $env1
        if ($r.Cancelled) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.Cancelled'; Message = ''; Output = $r.Output } }
        if ($r.ExitCode -ne 0) {
            Write-DreddReport -Reporter $Reporter -Type log -Level Info -Area 'Install' -Message 'install → upgrade'
            $r = Invoke-DreddProcess -FilePath $inst -ArgumentList ($baseArgs + @('upgrade', $tmpIpa)) -TimeoutSec 900 -CancellationToken $CancellationToken -OnLine $onLine -Environment $env1
            if ($r.Cancelled) { return [pscustomobject]@{ Ok = $false; ErrorKey = 'Err.Cancelled'; Message = ''; Output = $r.Output } }
        }
        # Некоторые сборки ideviceinstaller возвращают 0 при ERROR в выводе — проверяем текст.
        $failedText = $r.Output -match '(?im)^\s*(ERROR|Error:)'
        if ($r.ExitCode -eq 0 -and -not $failedText) {
            return [pscustomobject]@{ Ok = $true; ErrorKey = $null; Message = ''; Output = (Protect-LogText $r.Output) }
        }
        $msg = (Protect-LogText $r.Output).Trim()
        $lastLine = @($msg -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        $key = 'Err.InstallFailed'
        if ($msg -match '(?i)(pair|trust|lockdown)') { $key = 'Err.NotTrusted' }
        elseif ($msg -match '(?i)(No device found|device not found)') { $key = 'Err.NoDevices' }
        return [pscustomobject]@{ Ok = $false; ErrorKey = $key; Message = ($lastLine -join ''); Output = $msg }
    } finally {
        try { if ([System.IO.Directory]::Exists($temp)) { [System.IO.Directory]::Delete($temp, $true) } } catch { }
    }
}

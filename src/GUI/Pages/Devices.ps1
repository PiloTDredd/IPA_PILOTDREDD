# Устройства: поиск по кабелю и Wi-Fi, установка IPA на выбранные устройства с проверкой минимальной iOS.

$script:DeviceRows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.DeviceRow]
$script:DeviceScanTask = $null
$script:InstallTask = $null
$script:DeviceScanError = $null

function Initialize-DevicesPage {
    $u = $script:UI
    $u.DevGrid.ItemsSource = $script:DeviceRows
    $u.DevScanBtn.Add_Click({ Safe { Start-DreddDeviceScan } })
    $u.DevInstallBtn.Add_Click({ Safe { Start-DreddInstall } })
    $u.DevCancelBtn.Add_Click({ Safe { if ($script:InstallTask) { Stop-DreddTask $script:InstallTask.Id } } })
    $u.DevGrid.Add_SelectionChanged({ Safe { Update-DevicesButtons } })
    $u.DevIpaGrid.Add_SelectionChanged({ Safe { Update-DevicesButtons } })
    $u.DevAddFileBtn.Add_Click({ Safe { $f = Select-DreddIpaFiles; if ($f) { Add-DreddExternalIpas $f -Select } } })
}

function Show-DevicesPage {
    if (-not $script:LibraryLoaded -and -not $script:LibraryTask) { Start-DreddLibraryRefresh }
    Update-DevicesTexts
}

function Update-DevicesTexts {
    $u = $script:UI
    $b = $script:Ctx.Binaries
    $hint = ''
    if (-not $b.IdeviceId -and -not $b.IdeviceInstaller) {
        $hint = T 'Err.NoIdeviceId'
        if ($script:Ctx.Platform.IsWindows) { $hint += "`n" + (T 'Diag.Hint.DeviceToolsWin') }
        elseif ($script:Ctx.Platform.IsMac) { $hint += "`n" + (T 'Diag.Hint.DeviceToolsMac') }
        else { $hint += "`n" + (T 'Diag.Hint.DeviceToolsLinux') }
    } elseif ($script:DeviceScanTask) { $hint = T 'Devices.Scanning' }
    elseif (-not $script:DevicesScanned) { $hint = T 'Devices.PressScan' }
    elseif ($script:DeviceRows.Count -eq 0) {
        $hint = if ($script:DeviceScanError -eq 'Err.UsbMux') { T 'Err.UsbMux' } else { T 'Devices.NoneHint' }
    }
    $u.DevEmptyText.Text = $hint
    $u.DevEmptyText.Visibility = if ($hint) { 'Visible' } else { 'Collapsed' }
    $u.DevStatusText.Text = if ($script:DevicesScanned) { TF 'Devices.Found' @($script:DeviceRows.Count) } else { '' }
    foreach ($r in $script:DeviceRows) {
        $r.StatusText = T "Device.Status.$($r.Status)"
        $r.ConnectionText = if ($r.Connection) { T "Device.Conn.$($r.Connection)" } else { '' }
    }
    Update-DevicesButtons
}

function Update-DevicesButtons {
    $u = $script:UI
    $busy = [bool]$script:InstallTask
    $u.DevScanBtn.IsEnabled = -not $script:DeviceScanTask -and -not $busy -and [bool]$script:Ctx.Binaries.IdeviceId
    $u.DevInstallBtn.IsEnabled = -not $busy -and [bool]$script:Ctx.Binaries.IdeviceInstaller -and $u.DevIpaGrid.SelectedItems.Count -gt 0 -and $script:DeviceRows.Count -gt 0
    $u.DevCancelBtn.IsEnabled = $busy
}

function Start-DreddDeviceScan {
    if ($script:DeviceScanTask) { return }
    if (-not $script:Ctx.Binaries.IdeviceId) { Update-DevicesTexts; return }
    $script:DeviceScanTask = Start-DreddTask -Name (T 'Task.ScanDevices') -Script {
        Get-DreddDevices -Context $Context -Reporter $Reporter -CancellationToken $Token
    } -OnComplete {
        param($r)
        $script:DeviceScanTask = $null
        $script:DevicesScanned = $true
        $script:DeviceScanError = $r.ErrorKey
        $script:DeviceRows.Clear()
        foreach ($d in @($r.Devices)) {
            if ($null -eq $d) { continue }
            $row = New-Object IPADredd.Gui.DeviceRow
            $row.Name = $d.Name; $row.Model = $d.ProductType; $row.IosVersion = $d.iOSVersion; $row.Udid = $d.UDID
            $row.Status = $d.Status; $row.Detail = $d.Detail
            $row.Connection = $d.Connection
            $script:DeviceRows.Add($row)
        }
        $script:Devices = @($r.Devices | Where-Object { $_ })
        if ($script:DeviceRows.Count -eq 1) { $script:UI.DevGrid.SelectedIndex = 0 }
        Add-DreddLog -Level Info -Area 'Devices' -Message (TF 'Devices.Found' @($script:DeviceRows.Count))
        Update-DevicesTexts
        Resume-DreddPendingInstall
        # Совместимость с iOS найденного iPhone — в «Покупках».
        if (Get-Command Update-DreddPurchaseStatuses -ErrorAction SilentlyContinue) { Update-DreddPurchaseStatuses }
    } -OnError {
        param($m)
        $script:DeviceScanTask = $null
        Add-DreddLog -Level Error -Area 'Devices' -Message $m
        Update-DevicesTexts
    }
    Update-DevicesTexts
}

function Start-DreddInstall {
    $u = $script:UI
    $ipas = @($u.DevIpaGrid.SelectedItems)
    $devices = @($u.DevGrid.SelectedItems)
    if ($devices.Count -eq 0 -and $script:DeviceRows.Count -eq 1) { $devices = @($script:DeviceRows[0]) }
    if ($ipas.Count -eq 0) { [void](Show-DreddDialog -Title (T 'Devices.Install') -Message (T 'Devices.SelectIpa') -Kind Info); return }
    if ($devices.Count -eq 0) { [void](Show-DreddDialog -Title (T 'Devices.Install') -Message (T 'Devices.SelectDevice') -Kind Info); return }

    # Пары (IPA, устройство): минимальная iOS и подпись. Блокирующие проблемы — iOS почти наверняка откажет.
    # Обычные массивы, а не List[object]: в PowerShell 5.1 @() над List[object] падает («Argument types do not match»).
    $pairs = @()
    $blocking = @()
    $warnings = @()
    foreach ($ipa in $ipas) {
        foreach ($d in $devices) {
            $problems = @()
            $isBlocked = $false
            if ((Test-DreddIosCompatible -MinIOS $ipa.MinIos -DeviceVersion $d.IosVersion) -eq $false) {
                $problems += TF 'Devices.IosTooOld' @($ipa.MinIos, $d.IosVersion); $isBlocked = $true
            }
            $sig = Test-DreddSignatureForDevice -SignType $ipa.SignType -SignExpires $ipa.SignExpires -SignDevices $ipa.SignDevices -Udid $d.Udid
            if ($sig) {
                $problems += T $sig.Key
                if ($sig.Blocking) { $isBlocked = $true }
            }
            $pairs += [pscustomobject]@{ Path = $ipa.Path; Name = $ipa.Name; Version = $ipa.Version; MinIos = $ipa.MinIos; Udid = $d.Udid; Device = $d.Name; DeviceIos = $d.IosVersion; Ok = -not $isBlocked }
            if ($problems.Count -gt 0) {
                $line = "• {0} → {1}: {2}" -f $ipa.Name, $d.Name, ($problems -join '; ')
                if ($isBlocked) { $blocking += $line } else { $warnings += $line }
            }
        }
    }
    if ($blocking.Count -gt 0) {
        $msg = (T 'Devices.ProblemsText') + "`n`n" + (($blocking + $warnings) -join "`n")
        $buttons = @(@{ Key = 'cancel'; Text = (T 'Common.Cancel') }, @{ Key = 'force'; Text = (T 'Devices.InstallAnyway'); Kind = 'Danger' })
        if (@($pairs | Where-Object { $_.Ok }).Count -gt 0) { $buttons += @{ Key = 'skip'; Text = (T 'Devices.SkipProblems'); Kind = 'Primary' } }
        $choice = Show-DreddDialog -Title (T 'Devices.ProblemsTitle') -Message $msg -Kind Warning -Buttons $buttons
        if ($choice -eq 'skip') { $pairs = @($pairs | Where-Object { $_.Ok }) }
        elseif ($choice -ne 'force') { return }
    } else {
        $names = ($devices | ForEach-Object { $_.Name }) -join ', '
        $msg = TF 'Devices.ConfirmText' @($ipas.Count, $names)
        if ($warnings.Count -gt 0) { $msg += "`n`n" + ($warnings -join "`n") }
        if (-not (Confirm-Dredd -Title (T 'Devices.ConfirmTitle') -Message $msg -YesText (T 'Devices.Install'))) { return }
    }
    if ($pairs.Count -eq 0) { return }

    $u.DevProgress.Visibility = 'Visible'; $u.DevProgress.Value = 0
    $u.DevProgressText.Text = ''
    $script:InstallTask = Start-DreddTask -Name (T 'Task.Install') -Arguments @{ Pairs = $pairs } -Script {
        $results = @()
        $i = 0
        foreach ($p in $A.Pairs) {
            if ($Token.IsCancellationRequested) { break }
            $i++
            Write-DreddReport -Reporter $Reporter -Type data -Area 'Install' -Value @{ Index = $i; Total = $A.Pairs.Count; Name = $p.Name; Device = $p.Device }
            Write-DreddReport -Reporter $Reporter -Type log -Area 'Install' -Message ("▶ {0} → {1} ({2}/{3})" -f $p.Name, $p.Device, $i, $A.Pairs.Count)
            $r = Install-DreddIpa -Context $Context -IpaPath $p.Path -UDID $p.Udid -Reporter $Reporter -CancellationToken $Token
            $res = if ($r.Ok) { 'Success' } elseif ($r.ErrorKey -eq 'Err.Cancelled') { 'Cancelled' } else { 'Error' }
            Add-DreddHistoryEntry -Context $Context -Kind Install -Name $p.Name -Version $p.Version -Target $p.Device -File ([System.IO.Path]::GetFileName($p.Path)) -Result $res -Message $r.Message
            if ($r.Ok) { Write-DreddReport -Reporter $Reporter -Type log -Level Success -Area 'Install' -Message ("✔ {0} → {1}" -f $p.Name, $p.Device) }
            else { Write-DreddReport -Reporter $Reporter -Type log -Level Error -Area 'Install' -Message ("✖ {0} → {1}: {2} {3}" -f $p.Name, $p.Device, $r.ErrorKey, $r.Message) }
            $results += [pscustomobject]@{ Name = $p.Name; Device = $p.Device; Ok = $r.Ok; ErrorKey = $r.ErrorKey; Message = $r.Message }
        }
        , $results
    } -OnMessage {
        param($item)
        $u = $script:UI
        if ($item.Type -eq 'data' -and $item.Value) {
            $v = $item.Value
            $u.DevProgress.Value = [Math]::Max(0, ($v.Index - 1)) / [Math]::Max(1, $v.Total) * 100
            $u.DevProgressText.Text = TF 'Devices.Progress' @($v.Index, $v.Total, $v.Name, $v.Device)
        }
    } -OnComplete {
        param($results)
        $script:InstallTask = $null
        $u = $script:UI
        $u.DevProgress.Value = 100
        $ok = @($results | Where-Object { $_.Ok }).Count
        $fail = @($results | Where-Object { -not $_.Ok })
        $u.DevProgressText.Text = TF 'Devices.Summary' @($ok, $fail.Count)
        Start-DreddNextAutoInstall
        Update-DevicesButtons
        if ($fail.Count -gt 0) {
            $lines = $fail | ForEach-Object { "• $($_.Name) → $($_.Device): $(Get-DreddErrorText $_.ErrorKey $_.Message)" }
            [void](Show-DreddDialog -Title (TF 'Devices.Summary' @($ok, $fail.Count)) -Message ($lines -join "`n") -Kind Warning)
        }
    } -OnError {
        param($m)
        $script:InstallTask = $null
        $script:UI.DevProgressText.Text = $m
        Add-DreddLog -Level Error -Area 'Install' -Message $m
        Update-DevicesButtons
    }
    Update-DevicesButtons
}

# ---------------- «Скачать и установить» / «Установить на iPhone» ----------------
# Установка без диалогов: проверка iOS и подписи, затем по одной через общий $script:InstallTask.

$script:AutoInstallQueue = New-Object System.Collections.Generic.List[object]
$script:PendingInstall = $null

function Get-DreddInstallTarget {
    <#
      Устройство для установки: единственное готовое; выбранное на экране «Устройства»; иначе — выбор в диалоге.
      Если готовых нет — запускает поиск и откладывает действие ($Retry выполнится после сканирования). Возвращает строку устройства или $null.
    #>
    param([scriptblock]$Retry)
    if (-not $script:Ctx.Binaries.IdeviceInstaller) {
        Show-DreddToast -Kind Error -Title (T 'Err.NoInstaller') -Text (T 'Diag.Hint.DeviceToolsWin') -AutoHideMs 8000
        return $null
    }
    $ready = @($script:DeviceRows | Where-Object { $_.Status -eq 'Ready' })
    if ($ready.Count -eq 0) {
        $script:PendingInstall = $Retry
        Show-DreddToast -Kind Info -Title (T 'Install.Searching') -Text (T 'Install.SearchingText') -Progress
        Start-DreddDeviceScan
        return $null
    }
    if ($ready.Count -eq 1) { return $ready[0] }
    $sel = @($script:UI.DevGrid.SelectedItems | Where-Object { $_.Status -eq 'Ready' })
    if ($sel.Count -eq 1) { return $sel[0] }
    $buttons = @(@{ Key = 'cancel'; Text = (T 'Common.Cancel') })
    foreach ($d in ($ready | Select-Object -First 3)) { $buttons += @{ Key = $d.Udid; Text = $d.Name; Kind = 'Primary' } }
    $choice = Show-DreddDialog -Title (T 'Install.ChooseDevice') -Message (T 'Install.ChooseDeviceText') -Kind Question -Buttons $buttons
    return ($ready | Where-Object { $_.Udid -eq $choice } | Select-Object -First 1)
}

function Invoke-DreddInstallApps {
    <#
      «Установить на iPhone» из «Покупок» и «Поиска». Apps: объекты { Id; Name; Local } — Local = путь к уже скачанному IPA
      (тогда только установка), иначе загрузка с установкой после неё. -Purchase — флаг --purchase для новых загрузок.
    #>
    param([object[]]$Apps, [bool]$Purchase)
    $apps = @($Apps | Where-Object { $_ -and $_.Id })
    if ($apps.Count -eq 0) { return }
    $script:PendingInstallApps = $apps
    $script:PendingInstallPurchase = $Purchase
    $dev = Get-DreddInstallTarget -Retry { Invoke-DreddInstallApps $script:PendingInstallApps $script:PendingInstallPurchase }
    if (-not $dev) { return }
    $toDownload = @($apps | Where-Object { -not $_.Local })
    if ($toDownload.Count -gt 0 -and -not (Test-DreddLoggedIn)) { return }
    foreach ($a in $apps) {
        if ($a.Local) { Add-DreddAutoInstall -Path $a.Local -Name $a.Name -Udid $dev.Udid -DeviceName $dev.Name }
        else { Add-DreddDownloadItem -AppId $a.Id -AppName $a.Name -Purchase $Purchase -InstallUdid $dev.Udid -InstallDevice $dev.Name }
    }
    Add-DreddLog -Level Info -Area 'Install' -Message (TF 'Install.Queued' @($apps.Count, $dev.Name))
    Show-DreddToast -Kind Info -Title (TF 'Install.Queued' @($apps.Count, $dev.Name)) -Text $(if ($toDownload.Count -gt 0) { T 'Install.QueuedText' } else { '' }) -AutoHideMs 4000 -Low
}

function Resume-DreddPendingInstall {
    # После сканирования: отложенное «Установить» продолжается, если iPhone нашёлся.
    $retry = $script:PendingInstall
    if (-not $retry) { return }
    $script:PendingInstall = $null
    if (@($script:DeviceRows | Where-Object { $_.Status -eq 'Ready' }).Count -gt 0) { Hide-DreddToast; & $retry; return }
    $text = if (@($script:DeviceRows | Where-Object { $_.Status -eq 'NotTrusted' }).Count -gt 0) { T 'Device.Status.NotTrusted' } else { T 'Devices.NoneHint' }
    Show-DreddToast -Kind Warning -Title (T 'Install.NoDevice') -Text $text -ActionText (T 'Install.OpenDevices') -Action { Show-DreddPage 'Devices' }
}

function Add-DreddAutoInstall {
    # Ставит IPA в очередь установок. Блокирующие проблемы (iOS старее, подпись) — не ставим, объясняем в уведомлении.
    param([string]$Path, [string]$Name, [string]$Udid, [string]$DeviceName, $QueueItem)
    if (-not [System.IO.File]::Exists($Path)) { return }
    $meta = Get-DreddIpaMetadata -Path $Path
    $dev = $script:DeviceRows | Where-Object { $_.Udid -eq $Udid } | Select-Object -First 1
    $problem = $null
    if ($dev -and (Test-DreddIosCompatible -MinIOS $meta.MinIOS -DeviceVersion $dev.IosVersion) -eq $false) { $problem = TF 'Devices.IosTooOld' @($meta.MinIOS, $dev.IosVersion) }
    else {
        $sig = Test-DreddSignatureForDevice -SignType $meta.SignType -SignExpires $meta.SignExpires -SignDevices $meta.SignDevices -Udid $Udid
        if ($sig -and $sig.Blocking) { $problem = T $sig.Key }
    }
    if ($problem) {
        if ($QueueItem) { Set-DreddQueueStatus $QueueItem 'InstallError'; $QueueItem.Error = $problem }
        Show-DreddToast -Kind Warning -Title (TF 'Install.Skipped' @($Name, $DeviceName)) -Text $problem
        return
    }
    if ($QueueItem) { Set-DreddQueueStatus $QueueItem 'InstallQueued' }
    $script:AutoInstallQueue.Add([pscustomobject]@{ Path = $Path; Name = $Name; Version = $meta.Version; Udid = $Udid; Device = $DeviceName; Item = $QueueItem })
    Start-DreddNextAutoInstall
}

function Start-DreddNextAutoInstall {
    if ($script:InstallTask -or $script:AutoInstallQueue.Count -eq 0) { return }
    $job = $script:AutoInstallQueue[0]
    $script:AutoInstallQueue.RemoveAt(0)
    $script:AutoInstallJob = $job
    if ($job.Item) { Set-DreddQueueStatus $job.Item 'Installing' }
    $script:InstallTask = Start-DreddTask -Name (TF 'Task.InstallOne' @($job.Name)) -Arguments @{ Job = $job } -Script {
        $j = $A.Job
        Write-DreddReport -Reporter $Reporter -Type log -Area 'Install' -Message ("▶ {0} → {1}" -f $j.Name, $j.Device)
        $r = Install-DreddIpa -Context $Context -IpaPath $j.Path -UDID $j.Udid -Reporter $Reporter -CancellationToken $Token
        $res = if ($r.Ok) { 'Success' } elseif ($r.ErrorKey -eq 'Err.Cancelled') { 'Cancelled' } else { 'Error' }
        Add-DreddHistoryEntry -Context $Context -Kind Install -Name $j.Name -Version $j.Version -Target $j.Device -File ([System.IO.Path]::GetFileName($j.Path)) -Result $res -Message $r.Message
        $r
    } -OnComplete {
        param($r)
        $script:InstallTask = $null
        $job = $script:AutoInstallJob
        if ($r.Ok) {
            if ($job.Item) { Set-DreddQueueStatus $job.Item 'Installed' }
            # Сравнение с iPhone: только что установленное больше не «нет на iPhone».
            if ($job.Item -and $job.Item.AppId -and (Get-Command Set-DreddDeviceAppInstalled -ErrorAction SilentlyContinue)) {
                Set-DreddDeviceAppInstalled -AppId $job.Item.AppId -Udid $job.Udid -Version $job.Version
            }
            Add-DreddLog -Level Success -Area 'Install' -Message ("✔ {0} → {1}" -f $job.Name, $job.Device)
            Show-DreddToast -Kind Success -Title (TF 'Install.Done' @($job.Name, $job.Device)) -AutoHideMs 5000 -Low
        } else {
            $txt = Get-DreddErrorText $r.ErrorKey $r.Message
            if ($job.Item) { Set-DreddQueueStatus $job.Item 'InstallError'; $job.Item.Error = $txt }
            Add-DreddLog -Level Error -Area 'Install' -Message ("✖ {0} → {1}: {2}" -f $job.Name, $job.Device, $txt)
            if ($r.ErrorKey -ne 'Err.Cancelled') { Show-DreddToast -Kind Error -Title (TF 'Install.Failed' @($job.Name, $job.Device)) -Text $txt }
        }
        Update-DevicesButtons
        Update-DownloadsHistory
        Start-DreddNextAutoInstall
    } -OnError {
        param($m)
        $script:InstallTask = $null
        $job = $script:AutoInstallJob
        if ($job.Item) { Set-DreddQueueStatus $job.Item 'InstallError'; $job.Item.Error = $m }
        Add-DreddLog -Level Error -Area 'Install' -Message $m
        Update-DevicesButtons
        Start-DreddNextAutoInstall
    }
    Update-DevicesButtons
}
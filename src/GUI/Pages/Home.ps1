# Главная: карточка iPhone, плитки «Нет на iPhone / На iPhone / Обновить», текущая загрузка, «Недавно», первые шаги.
# Данные не свои: устройства — $script:DeviceRows/$script:Devices (Devices.ps1), сравнение — $script:DeviceCompare (Purchases.ps1),
# очередь — $script:Queue/$script:ActiveDownload (Downloads.ps1), история — Get-DreddDownloadHistory.

$script:AccountRefreshing = $false

function Initialize-HomePage {
    $u = $script:UI
    # «На кофе» — та же ссылка, что «Поддержать PILOTDREDD» в «Диагностике»; без https-адреса кнопка скрыта.
    $u.SideTipBtn.Add_Click({ Safe { Open-DreddUrl ([string]$script:Ctx.Settings['TipJarUrl']) } })
    $u.SideTipBtn.Visibility = if ([string]$script:Ctx.Settings['TipJarUrl'] -match '^https://') { 'Visible' } else { 'Collapsed' }

    $u.HomeInstallBtn.Add_Click({ Safe { $f = @(Select-DreddIpaFiles); if ($f.Count -gt 0) { Invoke-DreddInstallFiles $f } } })
    $u.HomeScanBtn.Add_Click({ Safe { Start-DreddDeviceScan; Update-HomeDevice } })
    $u.HomeDevicesBtn.Add_Click({ Safe { Show-DreddPage 'Devices' } })
    $u.HomeTileMissing.Add_Click({ Safe { Open-DreddHomeTile 'NotOnDevice' } })
    $u.HomeTileOn.Add_Click({ Safe { Open-DreddHomeTile 'OnDevice' } })
    $u.HomeTileUpdate.Add_Click({ Safe { Open-DreddHomeTile 'OnDevice' 'DeviceOutdated' } })
    $u.HomeDlCancelBtn.Add_Click({ Safe { $q = $script:UI.HomeDlActive.DataContext; if ($q) { Stop-DreddDownloadItem $q } } })
    $u.HomeDlQueueLink.Add_Click({ Safe { Show-DreddPage 'Downloads' } })
    $u.HomeAllDownloadsBtn.Add_Click({ Safe { Show-DreddPage 'Downloads' } })
    $u.HomeOpenPurchasesBtn.Add_Click({ Safe { Show-DreddPage 'Purchases' } })
    $u.HomeStep1Btn.Add_Click({ Safe { Start-DreddUpdateCheck -InstallNow } })
    $u.HomeStep2Btn.Add_Click({ Safe { Show-DreddPage 'Accounts' } })
    $u.HomeStep3Btn.Add_Click({ Safe { Start-DreddDeviceScan; Update-HomePage } })
}

function Show-HomePage { Update-HomePage }

function Update-DreddHome {
    # Для чужих экранов: обновить «Главную», только если она сейчас открыта (при показе она обновится сама).
    param([ValidateSet('All', 'Download', 'Recent', 'Tiles')][string]$Part = 'All')
    if ($script:CurrentPage -ne 'Home' -or -not $script:UI['PageHome']) { return }
    switch ($Part) {
        'Download' { Update-HomeDownload }
        'Recent' { Update-HomeRecent }
        'Tiles' { Update-HomeTiles; Update-HomeDevice }
        default { Update-HomePage }
    }
}

function Update-HomePage {
    Update-HomeSetup
    Update-HomeDevice
    Update-HomeTiles
    Update-HomeDownload
    Update-HomeRecent
}

# ---------------- Первые шаги ----------------

function Set-DreddHomeStep {
    # State: Done | Current | Todo.
    param([int]$N, [string]$State, [string]$Text)
    $u = $script:UI
    $u["HomeStep${N}Text"].Text = $Text
    $circle = $u["HomeStep${N}Circle"]; $num = $u["HomeStep${N}Num"]; $btn = $u["HomeStep${N}Btn"]; $box = $u["HomeStep$N"]
    $u["HomeStep${N}Done"].Visibility = if ($State -eq 'Done') { 'Visible' } else { 'Collapsed' }
    $btn.Visibility = if ($State -eq 'Done') { 'Collapsed' } else { 'Visible' }
    # Style = $null отключил бы и неявный стиль кнопок темы — поэтому ClearValue.
    if ($State -eq 'Current') { $btn.Style = $script:App.Resources['PrimaryButton'] } else { $btn.ClearValue([System.Windows.FrameworkElement]::StyleProperty) }
    $btn.Content.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $(if ($State -eq 'Current') { 'Brush.AccentText' } else { 'Brush.Text' }))
    switch ($State) {
        'Done' {
            $num.Text = [string][char]0x2713
            $circle.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Brush.SuccessSoft')
            $circle.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'Brush.SuccessSoft')
            $num.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Success')
            $box.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        }
        'Current' {
            $num.Text = [string]$N
            $circle.Fill = [System.Windows.Media.Brushes]::Transparent
            $circle.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'Brush.Accent')
            $num.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Accent')
            $box.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Brush.Accent')
        }
        default {
            $num.Text = [string]$N
            $circle.Fill = [System.Windows.Media.Brushes]::Transparent
            $circle.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'Brush.Scroll')
            $num.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.TextMuted')
            $box.BorderBrush = [System.Windows.Media.Brushes]::Transparent
        }
    }
}

function Test-DreddHomeSetupNeeded {
    # Мастер первых шагов виден, пока нет компонентов или входа (проверка входа при запуске ещё идёт — не мигаем).
    if (-not $script:Ctx.Binaries.Ipatool) { return $true }
    if ($script:AccountRefreshing) { return $false }
    return -not ($script:Account -and $script:Account.Success)
}

function Update-HomeSetup {
    $u = $script:UI
    if (-not (Test-DreddHomeSetupNeeded)) { $u.HomeSetupCard.Visibility = 'Collapsed'; $u.HomeDevCard.Visibility = 'Visible'; return }
    $u.HomeSetupCard.Visibility = 'Visible'
    $u.HomeDevCard.Visibility = 'Collapsed'
    $hasTools = [bool]$script:Ctx.Binaries.Ipatool
    $signedIn = [bool]($script:Account -and $script:Account.Success)
    $dev = @($script:DeviceRows | Where-Object { $_.Status -eq 'Ready' }) | Select-Object -First 1
    $done = 0
    if ($hasTools) { $done++; Set-DreddHomeStep 1 'Done' (T 'Home.Step1.DoneText') } else { Set-DreddHomeStep 1 'Current' (T 'Home.Step1.Todo') }
    if ($signedIn) { $done++; Set-DreddHomeStep 2 'Done' (TF 'Home.Step2.DoneText' @($script:Account.Email)) }
    else { Set-DreddHomeStep 2 $(if ($hasTools) { 'Current' } else { 'Todo' }) (T 'Home.Step2.Todo') }
    if ($dev) { $done++; Set-DreddHomeStep 3 'Done' (TF 'Home.Step3.DoneText' @($dev.Name)) }
    else { Set-DreddHomeStep 3 $(if ($hasTools -and $signedIn) { 'Current' } else { 'Todo' }) $(if ($script:DeviceScanTask) { T 'Home.Searching' } else { T 'Home.Step3.Todo' }) }
    $u.HomeStep1Btn.IsEnabled = -not $script:UpdateTask
    $u.HomeStep3Btn.IsEnabled = [bool]$script:Ctx.Binaries.IdeviceId -and -not $script:DeviceScanTask
    $u.HomeSetupProgress.Value = $done
    $u.HomeSetupProgressText.Text = TF 'Home.Setup.Progress' @($done)
}

# ---------------- Карточка iPhone ----------------

function Get-DreddHomeDevice {
    # Какое устройство показать: то, с которым сравнивали покупки; иначе первое готовое (кабель раньше Wi-Fi); иначе любое найденное.
    $rows = @($script:DeviceRows)
    if ($rows.Count -eq 0) { return $null }
    if ($script:DeviceCompare) {
        $c = $rows | Where-Object { $_.Udid -eq $script:DeviceCompare.Udid -and $_.Status -eq 'Ready' } | Select-Object -First 1
        if ($c) { return $c }
    }
    $ready = @($rows | Where-Object { $_.Status -eq 'Ready' } | Sort-Object { if ($_.Connection -eq 'network') { 1 } else { 0 } })
    if ($ready.Count -gt 0) { return $ready[0] }
    return $rows[0]
}

function Update-HomeDevice {
    $u = $script:UI
    $dev = Get-DreddHomeDevice
    $count = @($script:DeviceRows).Count
    $u.HomeDevicesBtnText.Text = if ($count -gt 1) { TF 'Home.AllDevicesN' @($count) } else { T 'Home.AllDevices' }
    $ready = $dev -and $dev.Status -eq 'Ready'
    $u.HomeDevInfo.Visibility = if ($ready) { 'Visible' } else { 'Collapsed' }
    $u.HomeNoDevInfo.Visibility = if ($ready) { 'Collapsed' } else { 'Visible' }
    $u.HomeInstallBtn.Visibility = if ($ready) { 'Visible' } else { 'Collapsed' }
    $u.HomeScanBtn.Visibility = if ($ready) { 'Collapsed' } else { 'Visible' }
    $u.HomeScanBtn.IsEnabled = [bool]$script:Ctx.Binaries.IdeviceId -and -not $script:DeviceScanTask
    $u.HomeInstallBtn.IsEnabled = [bool]$script:Ctx.Binaries.IdeviceInstaller
    # Телефон-картинка: в цвет акцента, когда iPhone на связи; серый контур — когда нет.
    $shapeBrush = if ($ready) { 'Brush.Accent' } else { 'Brush.Scroll' }
    $u.HomePhoneShape.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, $shapeBrush)
    $u.HomePhoneNotch.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, $shapeBrush)
    if ($ready) { $u.HomePhoneShape.SetResourceReference([System.Windows.Controls.Border]::BackgroundProperty, 'Brush.AccentSoft') }
    else { $u.HomePhoneShape.Background = [System.Windows.Media.Brushes]::Transparent }

    if ($ready) {
        $u.HomeDevName.Text = $dev.Name
        $u.HomeDevConn.Text = if ($dev.Connection) { T "Device.Conn.$($dev.Connection)" } else { '' }
        $details = TF 'Home.DevDetails' @($dev.Model, $dev.IosVersion)
        if ($script:DeviceCompare -and $script:DeviceCompare.Udid -eq $dev.Udid) {
            $details += TF 'Home.DevApps' @(@($script:DeviceCompare.Apps | Where-Object { -not $_.Synthetic }).Count)
        }
        $u.HomeDevDetails.Text = $details
        $raw = @($script:Devices) | Where-Object { $_.UDID -eq $dev.Udid } | Select-Object -First 1
        $total = [long](Get-DreddProp $raw 'DiskTotal' 0); $free = [long](Get-DreddProp $raw 'DiskFree' 0)
        if ($total -gt 0) {
            $u.HomeDevSpacePanel.Visibility = 'Visible'
            $u.HomeDevSpaceBar.Value = [Math]::Round(($total - $free) * 100.0 / $total)
            $u.HomeDevSpaceText.Text = TF 'Home.DevSpace' @((Format-DreddSize $free), (Format-DreddSize $total))
        } else { $u.HomeDevSpacePanel.Visibility = 'Collapsed' }
        return
    }
    $b = $script:Ctx.Binaries
    if (-not $b.IdeviceId) {
        $u.HomeNoDevTitle.Text = T 'Home.NoDevTitle'
        $hint = if ($script:Ctx.Platform.IsWindows) { 'Diag.Hint.DeviceToolsWin' } elseif ($script:Ctx.Platform.IsMac) { 'Diag.Hint.DeviceToolsMac' } else { 'Diag.Hint.DeviceToolsLinux' }
        $u.HomeNoDevText.Text = (T 'Err.NoIdeviceId') + "`n" + (T $hint)
    } elseif ($script:DeviceScanTask) {
        $u.HomeNoDevTitle.Text = T 'Home.Searching'
        $u.HomeNoDevText.Text = T 'Home.NoDevText'
    } elseif ($dev -and $dev.Status -eq 'NotTrusted') {
        $u.HomeNoDevTitle.Text = TF 'Home.NotTrustedTitle' @($dev.Name)
        $u.HomeNoDevText.Text = T 'Home.NotTrustedText'
    } else {
        $u.HomeNoDevTitle.Text = T 'Home.NoDevTitle'
        $u.HomeNoDevText.Text = if ($script:DeviceScanError -eq 'Err.UsbMux') { T 'Err.UsbMux' } elseif ($dev) { "$($dev.Name): $($dev.StatusText)" } else { T 'Home.NoDevText' }
    }
}

function Invoke-DreddInstallFiles {
    # «Установить IPA с диска…» и перетаскивание на «Главную»: файлы ставятся на iPhone по очереди, без копирования в библиотеку.
    param([string[]]$Paths)
    $files = @($Paths | Where-Object { $_ -and [System.IO.File]::Exists($_) })
    if ($files.Count -eq 0) { return }
    $script:PendingInstallFiles = $files
    $dev = Get-DreddInstallTarget -Retry { Invoke-DreddInstallFiles $script:PendingInstallFiles }
    if (-not $dev) { return }
    foreach ($f in $files) {
        $m = Get-DreddIpaMetadata -Path $f
        $name = if ($m.Name) { $m.Name } else { [System.IO.Path]::GetFileNameWithoutExtension($f) }
        Add-DreddAutoInstall -Path $f -Name $name -Udid $dev.Udid -DeviceName $dev.Name
    }
    Add-DreddLog -Level Info -Area 'Install' -Message (TF 'Install.Queued' @($files.Count, $dev.Name))
    Show-DreddToast -Kind Info -Title (TF 'Install.Queued' @($files.Count, $dev.Name)) -AutoHideMs 4000 -Low
}

# ---------------- Плитки ----------------

function Update-HomeTiles {
    $u = $script:UI
    $n = @{ Missing = 0; On = 0; Outdated = 0 }
    $outdated = @()
    foreach ($row in $script:PurchaseRows) {
        switch ($row.DeviceState) {
            'Missing' { $n.Missing++ }
            'Installed' { $n.On++ }
            'Outdated' { $n.On++; $n.Outdated++; $outdated += $row.Name }
        }
    }
    if ($script:DeviceCompare) {
        $u.HomeTileMissingCount.Text = [string]$n.Missing
        $u.HomeTileOnCount.Text = [string]$n.On
        $u.HomeTileUpdateCount.Text = [string]$n.Outdated
        $u.HomeTileMissingText.Text = T 'Home.Tile.MissingText'
        $u.HomeTileOnText.Text = TF 'Home.Tile.OnText' @($script:DeviceCompare.Name)
        $u.HomeTileUpdateText.Text = if ($n.Outdated -gt 0) { TF 'Home.Tile.UpdateText' @((($outdated | Select-Object -First 2) -join ', ')) } else { T 'Home.Tile.UpdateNone' }
        return
    }
    foreach ($c in 'HomeTileMissingCount', 'HomeTileOnCount', 'HomeTileUpdateCount') { $u[$c].Text = [string][char]0x2014 }
    $hint = if ($script:DeviceAppsTask) { T 'Home.Tile.Comparing' }
            elseif ($script:PurchaseRows.Count -eq 0) { T 'Home.Tile.NeedPurchases' }
            elseif (@($script:DeviceRows | Where-Object { $_.Status -eq 'Ready' }).Count -eq 0) { T 'Home.Tile.NeedDevice' }
            else { T 'Home.Tile.Compare' }
    foreach ($t in 'HomeTileMissingText', 'HomeTileOnText', 'HomeTileUpdateText') { $u[$t].Text = $hint }
}

function Open-DreddHomeTile {
    # Плитка → нужная вкладка «Покупок» (и фильтр). Сравнения ещё не было — запускаем его (вкладку откроет «Сравнить с iPhone»).
    param([string]$Tab, [string]$Extra = '')
    Show-DreddPage 'Purchases'
    if ($script:DeviceCompare) { Set-DreddPurchaseFilter -Tab $Tab -Extra $Extra; return }
    if ($script:PurchaseRows.Count -gt 0) { Start-DreddDeviceAppsScan }
}

# ---------------- Текущая загрузка ----------------

function Update-HomeDownload {
    $u = $script:UI
    $q = $script:ActiveDownload
    if (-not $q) { $q = @($script:Queue | Where-Object { $_.Status -in 'Running', 'Installing' }) | Select-Object -First 1 }
    if (-not $q) { $q = @($script:Queue | Where-Object { $_.Status -in 'Queued', 'InstallQueued' }) | Select-Object -First 1 }
    if (-not $q) {
        $u.HomeDlActive.DataContext = $null
        $u.HomeDlActive.Visibility = 'Collapsed'
        $u.HomeDlEmpty.Visibility = 'Visible'
        return
    }
    $u.HomeDlActive.DataContext = $q
    $u.HomeDlActive.Visibility = 'Visible'
    $u.HomeDlEmpty.Visibility = 'Collapsed'
    $u.HomeDlInitial.Text = if ($q.AppName) { $q.AppName.Substring(0, 1).ToUpperInvariant() } else { '?' }
    $more = @($script:Queue | Where-Object { $_ -ne $q -and $_.Status -in 'Queued', 'InstallQueued' }).Count
    $u.HomeDlQueueText.Text = if ($more -gt 0) { TF 'Home.QueueMore' @($more) } else { '' }
    $u.HomeDlQueueLink.Visibility = if ($more -gt 0) { 'Visible' } else { 'Collapsed' }
    $u.HomeDlCancelBtn.IsEnabled = $q.Status -in 'Queued', 'Running'
}

# ---------------- Недавно ----------------

function Format-DreddHomeDate {
    param([string]$Date)
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Date, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$d)) { return $Date }
    $time = $d.ToString('HH:mm')
    if ($d.Date -eq [datetime]::Today) { return TF 'Home.Today' @($time) }
    if ($d.Date -eq [datetime]::Today.AddDays(-1)) { return TF 'Home.Yesterday' @($time) }
    return $d.ToString('d MMM, HH:mm')
}

function Update-HomeRecent {
    $rows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.SimpleRow]
    foreach ($h in @(Get-DreddDownloadHistory -Context $script:Ctx -Last 4)) {
        $r = New-Object IPADredd.Gui.SimpleRow
        $name = [string](Get-DreddProp $h 'Name' '')
        $ver = [string](Get-DreddProp $h 'Version' '')
        $kind = [string](Get-DreddProp $h 'Kind' 'Download')
        $res = [string](Get-DreddProp $h 'Result' 'Success')
        $target = [string](Get-DreddProp $h 'Target' '')
        $r.C1 = if ($name) { $name.Substring(0, 1).ToUpperInvariant() } else { '?' }
        $r.C2 = if ($ver) { "$name $ver" } else { $name }
        $r.C3 = Format-DreddHomeDate ([string](Get-DreddProp $h 'Date' ''))
        if ($target) { $r.C3 += " · $target" }
        $r.Status = $res
        $r.C5 = if ($res -eq 'Success') {
            switch ($kind) { 'Install' { T 'Home.Recent.Installed' } 'Uninstall' { T 'Home.Recent.Uninstalled' } 'Purchase' { T 'Home.Recent.Purchased' } default { T 'Home.Recent.Downloaded' } }
        } else { T "Result.$res" }
        $r.Detail = [string](Get-DreddProp $h 'Message' '')
        $rows.Add($r)
    }
    $script:UI.HomeRecentList.ItemsSource = $rows
    $script:UI.HomeRecentEmpty.Visibility = if ($rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }
}

# Покупки: библиотека приложений из истории покупок Apple ID — иконки, статусы, фильтры, скачивание (AUDIT_4.4.md §4).

$script:PurchaseRows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.PurchaseRow]
$script:PurchaseById = @{}        # ID → строка таблицы
$script:PurchaseApps = @{}        # ID → запись кэша (Read-DreddPurchaseLibrary)
$script:PurchaseBase = @{}        # ID → статус без учёта очереди (для вкладок)
$script:PurchaseLib = $null
$script:PurchaseEmail = $null     # аккаунт, чья библиотека показана
$script:PurchaseFilter = 'All'
$script:PurchaseScanTask = $null
$script:PurchaseLoadTask = $null
$script:PurchaseIconTask = $null
$script:PurchaseScanError = $null
$script:PurchaseScanStep = $null

# Порядок сортировки по статусу: сначала то, что требует действия.
$script:PurchaseStatusOrder = @{ Running = 0; Queued = 1; UpdateAvailable = 2; Available = 3; Failed = 4; NotInStore = 5; Unverified = 6; Downloaded = 7 }
$script:PurchaseTabs = [ordered]@{
    PurTabAll = 'All'; PurTabAvailable = 'Available'; PurTabDownloaded = 'Downloaded'
    PurTabUpdates = 'UpdateAvailable'; PurTabMissing = 'NotInStore'; PurTabProblems = 'Problems'
}

function Initialize-PurchasesPage {
    $u = $script:UI
    $u.PurGrid.ItemsSource = $script:PurchaseRows
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:PurchaseRows)
    $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('SortDate', 'Descending')))
    $view.Filter = [System.Predicate[object]] { param($o) Test-DreddPurchaseVisible $o }

    foreach ($name in $script:PurchaseTabs.Keys) {
        $u[$name].Tag = $script:PurchaseTabs[$name]
        $u[$name].Add_Checked({ param($s, $e) Safe { $script:PurchaseFilter = $s.Tag; Update-PurchasesView } })
    }
    # Поиск с небольшой задержкой: фильтр 1000+ строк на каждую букву не нужен.
    $script:PurSearchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PurSearchTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $script:PurSearchTimer.Add_Tick({ Safe { $script:PurSearchTimer.Stop(); Update-PurchasesView } })
    $u.PurSearch.Add_TextChanged({ $script:PurSearchTimer.Stop(); $script:PurSearchTimer.Start() })

    $u.PurScanBtn.Add_Click({ Safe { Start-DreddPurchaseScan } })
    $u.PurCancelBtn.Add_Click({ Safe { if ($script:PurchaseScanTask) { Stop-DreddTask $script:PurchaseScanTask.Id } } })
    $u.PurEmptyBtn.Add_Click({ Safe { Invoke-DreddPurchaseEmptyAction } })
    $u.PurDownloadBtn.Add_Click({ Safe { Invoke-DreddPurchaseDownload @($script:UI.PurGrid.SelectedItems) } })
    $u.PurRetryBtn.Add_Click({ Safe { Invoke-DreddPurchaseDownload @($script:PurchaseRows | Where-Object { $script:PurchaseBase[$_.Id] -eq 'Failed' }) } })
    $u.PurVersionBtn.Add_Click({ Safe { Invoke-DreddPurchaseVersions } })
    $u.PurInstallBtn.Add_Click({ Safe { Invoke-DreddPurchaseInstall @($script:UI.PurGrid.SelectedItems) } })
    $u.PurMenuInstall.Add_Click({ Safe { Invoke-DreddPurchaseInstall @($script:UI.PurGrid.SelectedItems) } })
    $u.PurShowFileBtn.Add_Click({ Safe { $r = $script:UI.PurGrid.SelectedItem; if ($r -and $r.LocalPath) { Open-DreddPath $r.LocalPath -Select } } })
    $u.PurGrid.Add_SelectionChanged({ Safe { Update-PurchaseButtons } })
    $u.PurGrid.Add_MouseDoubleClick({ param($s, $e) Safe {
        $row = Get-DreddRowFromEvent $e
        if ($row) { Invoke-DreddPurchaseRowAction $row }
    } })
    $u.PurGrid.Add_PreviewKeyDown({ param($s, $e) Safe {
        $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        if ($e.Key -eq 'Return') { Invoke-DreddPurchaseDownload @($script:UI.PurGrid.SelectedItems); $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'C') { Copy-DreddPurchaseIds; $e.Handled = $true }
    } })
    # Кнопка действия в строке: один обработчик на всю таблицу.
    $u.PurGrid.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($s, $e)
        Safe {
            $btn = $e.OriginalSource
            if ($btn -is [System.Windows.Controls.Button] -and $btn.Tag -is [IPADredd.Gui.PurchaseRow]) { Invoke-DreddPurchaseRowAction $btn.Tag; $e.Handled = $true }
        }
    })
    $u.PurMenuDownload.Add_Click({ Safe { Invoke-DreddPurchaseDownload @($script:UI.PurGrid.SelectedItems) } })
    $u.PurMenuVersion.Add_Click({ Safe { Invoke-DreddPurchaseVersions } })
    $u.PurMenuShow.Add_Click({ Safe { $r = $script:UI.PurGrid.SelectedItem; if ($r -and $r.LocalPath) { Open-DreddPath $r.LocalPath -Select } } })
    $u.PurMenuStore.Add_Click({ Safe {
        $r = $script:UI.PurGrid.SelectedItem
        if ($r) {
            $cc = ConvertTo-DreddCountryCode $(if ($script:PurchaseLib) { $script:PurchaseLib.Storefront } else { '' })
            Open-DreddUrl ('https://apps.apple.com/{0}app/id{1}' -f $(if ($cc) { "$cc/" } else { '' }), $r.Id)
        }
    } })
    $u.PurMenuCopyId.Add_Click({ Safe { Copy-DreddPurchaseIds } })
    $u.PurGrid.Add_ContextMenuOpening({ Safe { Update-PurchaseButtons } })
    Update-PurchasesView
}

function Show-PurchasesPage { Update-PurchasesView }

function Get-DreddRowFromEvent {
    # Строка таблицы под курсором (двойной клик по заголовку или пустому месту не считается).
    param($E)
    $d = $E.OriginalSource
    while ($d -and -not ($d -is [System.Windows.Controls.DataGridRow])) {
        if ($d -is [System.Windows.Controls.Primitives.DataGridColumnHeader] -or $d -is [System.Windows.Controls.Button]) { return $null }
        $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d)
    }
    if ($d) { return $d.Item }
    return $null
}

# ---------------- Загрузка библиотеки аккаунта ----------------

function Sync-DreddPurchaseAccount {
    # Вызывается при любом изменении аккаунта: показывает библиотеку текущего Apple ID (из кэша).
    $a = $script:Account
    $email = if ($a -and $a.Success) { $a.Email } else { $null }
    if ($email -eq $script:PurchaseEmail) { Update-PurchasesView; return }
    if ($script:PurchaseScanTask) { Stop-DreddTask $script:PurchaseScanTask.Id }
    $script:PurchaseEmail = $email
    $script:PurchaseScanError = $null
    Set-DreddPurchaseLibrary $null
    if (-not $email) { return }
    $script:PurchaseLoadTask = Start-DreddTask -Name (T 'Task.PurchasesLoad') -Silent -Arguments @{ Email = $email } -Script {
        Read-DreddPurchaseLibrary -Context $Context -Email $A.Email
    } -OnComplete {
        param($lib, $t)
        $script:PurchaseLoadTask = $null
        if ($script:PurchaseEmail -ne $t.Email) { Update-PurchasesView; return }
        Set-DreddPurchaseLibrary $lib
    } -OnError {
        param($m)
        $script:PurchaseLoadTask = $null
        Add-DreddLog -Level Error -Area 'Purchases' -Message $m
        Update-PurchasesView
    }
    $script:PurchaseLoadTask | Add-Member -NotePropertyName Email -NotePropertyValue $email -Force
    Update-PurchasesView
}

function Set-DreddPurchaseLibrary {
    param($Library)
    $script:PurchaseLib = $Library
    $script:PurchaseApps = @{}
    $script:PurchaseById = @{}
    $script:PurchaseBase = @{}
    $script:PurchaseRows.Clear()
    if ($Library) {
        foreach ($a in @($Library.Apps)) {
            if (-not $a -or -not $a.Id -or $script:PurchaseApps.ContainsKey($a.Id)) { continue }
            $script:PurchaseApps[$a.Id] = $a
            $row = New-Object IPADredd.Gui.PurchaseRow
            $row.Id = $a.Id
            $dt = [datetime]::MinValue
            if ([datetime]::TryParseExact([string]$a.PurchaseDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$dt)) {
                $row.SortDate = $dt; $row.PurchaseDateText = $dt.ToString('d')
            } else { $row.PurchaseDateText = [string]$a.PurchaseDate }
            $row.IconPath = Get-DreddIconPath -Context $script:Ctx -AppId $a.Id
            $script:PurchaseById[$a.Id] = $row
            Update-DreddPurchaseRow $row
            $script:PurchaseRows.Add($row)
        }
        Start-DreddIconFetch
    }
    Update-PurchasesView
    if (Get-Command Update-CatalogStatuses -ErrorAction SilentlyContinue) { Update-CatalogStatuses }
}

function Get-DreddLocalIpaMap {
    # App Store ID → самая новая версия в локальной библиотеке (Version, Path).
    $map = @{}
    foreach ($l in $script:LibraryRows) {
        if (-not $l.AppStoreId -or $l.HasError) { continue }
        $cur = $map[$l.AppStoreId]
        if (-not $cur -or (Compare-DreddVersion $cur.Version $l.Version) -eq -1) { $map[$l.AppStoreId] = @{ Version = $l.Version; Path = $l.Path } }
    }
    return $map
}

function Update-DreddPurchaseStatuses {
    # Пересчёт всех строк (после обновления локальной библиотеки, смены языка, загрузки).
    $map = Get-DreddLocalIpaMap
    foreach ($row in $script:PurchaseRows) { Update-DreddPurchaseRow $row -LocalMap $map }
    Update-PurchasesView
}

function Update-DreddPurchaseRow {
    param([IPADredd.Gui.PurchaseRow]$Row, [hashtable]$LocalMap)
    $a = $script:PurchaseApps[$Row.Id]
    if (-not $a) { return }
    if (-not $LocalMap) { $LocalMap = Get-DreddLocalIpaMap }
    $local = $LocalMap[$Row.Id]

    $Row.Name = if ($a.Name) { $a.Name } elseif ($a.StoreName) { $a.StoreName } else { $a.Id }
    $Row.Artist = if ($a.Artist) { [string]$a.Artist } else { "ID $($a.Id)" }
    $Row.SizeBytes = [long]$a.SizeBytes
    $Row.SizeText = if ($a.SizeBytes -gt 0) { Format-DreddSize $a.SizeBytes } else { '—' }
    $Row.LocalPath = if ($local) { $local.Path } else { $null }
    $Row.SearchText = ("{0} {1} {2} {3} {4}" -f $Row.Name, $a.StoreName, $a.Artist, $a.Id, $a.BundleId)

    $base = Get-DreddPurchaseStatus -App $a -LocalVersion $(if ($local) { $local.Version } else { $null })
    $script:PurchaseBase[$Row.Id] = $base
    $Row.VersionText = switch ($base) {
        'UpdateAvailable' { '{0} → {1}' -f $local.Version, $a.Version }
        'Downloaded' { [string]$local.Version }
        default { if ($a.Version) { [string]$a.Version } else { '—' } }
    }
    $region = if ($script:PurchaseLib -and $script:PurchaseLib.Storefront) { $script:PurchaseLib.Storefront } else { '?' }

    # Очередь загрузок важнее сохранённого статуса.
    $q = $null
    if ($script:Queue) { $q = $script:Queue | Where-Object { $_.AppId -eq $Row.Id -and $_.Status -in 'Queued', 'Running', 'InstallQueued', 'Installing' } | Select-Object -First 1 }
    if ($q -and $q.Status -in 'InstallQueued', 'Installing') {
        $Row.Status = 'Running'
        $Row.ShowProgress = ($q.Status -eq 'Installing')
        $Row.IsIndeterminate = $true
        $Row.StatusText = if ($q.Status -eq 'Installing') { TF 'Purchases.St.Installing' @($q.InstallDevice) } else { T 'Status.InstallQueued' }
        $Row.StatusDetail = $null
        $Row.ActionText = T 'Purchases.Show'
        $Row.StatusOrder = $script:PurchaseStatusOrder['Running']
        return
    }
    if ($q) {
        $Row.Status = $q.Status
        $Row.ShowProgress = ($q.Status -eq 'Running')
        $Row.IsIndeterminate = [bool]$q.IsIndeterminate
        $Row.Progress = $q.Progress
        $Row.StatusText = if ($q.Status -eq 'Running') { if ($q.IsIndeterminate) { T 'Purchases.St.Starting' } else { TF 'Purchases.St.Running' @([int]$q.Progress) } } else { T 'Status.Queued' }
        $Row.StatusDetail = $null
        $Row.ActionText = T 'Common.Cancel'
        $Row.StatusOrder = $script:PurchaseStatusOrder[$q.Status]
        return
    }
    $Row.ShowProgress = $false
    $Row.Status = $base
    $Row.StatusOrder = $script:PurchaseStatusOrder[$base]
    switch ($base) {
        'Available' { $Row.StatusText = T 'Purchases.St.Available'; $Row.StatusDetail = $null; $Row.ActionText = T 'Purchases.Download' }
        'Downloaded' {
            $Row.ActionText = T 'Purchases.Show'
            if ($a.Lookup -eq 'Missing') {
                # Снятое с продажи и уже скачанное — редкая копия, это стоит видеть.
                $Row.StatusText = T 'Purchases.St.DownloadedMissing'
                $Row.StatusDetail = TF 'Purchases.Detail.DownloadedMissing' @($local.Path, $region)
            } else { $Row.StatusText = T 'Purchases.St.Downloaded'; $Row.StatusDetail = $local.Path }
        }
        'UpdateAvailable' {
            $Row.StatusText = TF 'Purchases.St.Update' @($a.Version)
            $Row.StatusDetail = TF 'Purchases.Detail.Update' @($local.Version, $a.Version)
            $Row.ActionText = T 'Purchases.Update'
        }
        'NotInStore' { $Row.StatusText = T 'Purchases.St.NotInStore'; $Row.StatusDetail = TF 'Purchases.Detail.NotInStore' @($region); $Row.ActionText = T 'Purchases.Try' }
        'Failed' {
            $Row.StatusText = T 'Purchases.St.Failed'
            $when = ''
            try { if ($a.LastAttemptAt) { $when = ([datetime]$a.LastAttemptAt).ToString('g') } } catch { }
            $Row.StatusDetail = (TF 'Purchases.Detail.Failed' @($when)) + "`n" + (Get-DreddErrorText $a.LastErrorKey $a.LastErrorMessage)
            $Row.ActionText = T 'Purchases.Retry'
        }
        default { $Row.StatusText = T 'Purchases.St.Unverified'; $Row.StatusDetail = T 'Purchases.Detail.Unverified'; $Row.ActionText = T 'Purchases.Download' }
    }
}

function Update-DreddPurchaseFromQueue {
    # Хук очереди загрузок (Downloads.ps1): статус и прогресс приложения в строке библиотеки.
    param($Item)
    if (-not $Item) { return }
    $row = $script:PurchaseById[$Item.AppId]
    if (-not $row) { return }
    if ($Item.Status -in 'Done', 'Error', 'Cancelled') {
        $a = $script:PurchaseApps[$Item.AppId]
        # То же, что ядро записало в кэш (Set-DreddPurchaseAttempt), — без повторного чтения файла.
        if ($a -and $Item.Status -eq 'Done') { $a.LastErrorKey = ''; $a.LastErrorMessage = '' }
        elseif ($a -and $Item.Status -eq 'Error' -and $Item.ErrorKey) { $a.LastErrorKey = $Item.ErrorKey; $a.LastErrorMessage = $Item.ErrorMessage; $a.LastAttemptAt = (Get-Date).ToString('s') }
    }
    Update-DreddPurchaseRow $row
    Update-PurchaseCounts
}

# ---------------- Представление ----------------

function Test-DreddPurchaseVisible {
    param($Row)
    $base = $script:PurchaseBase[$Row.Id]
    $ok = switch ($script:PurchaseFilter) {
        'All' { $true }
        'Downloaded' { $base -in 'Downloaded', 'UpdateAvailable' }
        'Problems' { $base -in 'Failed', 'Unverified' }
        # Вкладка «Нет в App Store» — все снятые с продажи, в том числе уже скачанные.
        'NotInStore' { Test-DreddPurchaseMissing $Row.Id }
        default { $base -eq $script:PurchaseFilter }
    }
    if (-not $ok) { return $false }
    $q = $script:PurchaseQuery
    if ([string]::IsNullOrEmpty($q)) { return $true }
    return ([string]$Row.SearchText).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Test-DreddPurchaseMissing {
    param([string]$Id)
    $a = $script:PurchaseApps[$Id]
    return ($a -and $a.Lookup -eq 'Missing')
}

function Update-PurchaseCounts {
    $c = @{ All = 0; Available = 0; Downloaded = 0; UpdateAvailable = 0; NotInStore = 0; Problems = 0 }
    foreach ($id in $script:PurchaseBase.Keys) {
        $c.All++
        if (Test-DreddPurchaseMissing $id) { $c.NotInStore++ }
        switch ($script:PurchaseBase[$id]) {
            'Available' { $c.Available++ }
            'Downloaded' { $c.Downloaded++ }
            'UpdateAvailable' { $c.Downloaded++; $c.UpdateAvailable++ }
            'NotInStore' { }
            default { $c.Problems++ }
        }
    }
    foreach ($name in $script:PurchaseTabs.Keys) {
        $key = $script:PurchaseTabs[$name]
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = T "Purchases.Tab.$key"
        $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = [string]$c[$key]; $t2.Margin = '6,0,0,0'; $t2.Opacity = 0.6
        [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
        $script:UI[$name].Content = $sp
        # Пустые вкладки (кроме «Все») прячем, чтобы не было лишнего.
        $script:UI[$name].Visibility = if ($key -eq 'All' -or $c[$key] -gt 0 -or $script:PurchaseFilter -eq $key) { 'Visible' } else { 'Collapsed' }
    }
}

function Update-PurchasesView {
    $u = $script:UI
    $q = $u.PurSearch.Text
    $script:PurchaseQuery = if ([string]::IsNullOrWhiteSpace($q)) { '' } else { $q.Trim() }
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:PurchaseRows).Refresh()
    Update-PurchaseCounts

    $scanning = [bool]$script:PurchaseScanTask
    $loading = [bool]$script:PurchaseLoadTask
    $loggedIn = $script:Account -and $script:Account.Success
    $u.PurScanBtn.IsEnabled = $loggedIn -and -not $scanning -and [bool]$script:Ctx.Binaries.Ipatool
    $u.PurCancelBtn.Visibility = if ($scanning) { 'Visible' } else { 'Collapsed' }
    $u.PurSearch.IsEnabled = $script:PurchaseRows.Count -gt 0

    # Строка состояния сканирования справа от поиска.
    $info = ''
    if ($scanning) { $info = if ($script:PurchaseScanStep) { $script:PurchaseScanStep } else { T 'Purchases.Step.history' } }
    elseif ($script:PurchaseLib -and $script:PurchaseLib.ScannedAt) {
        $when = $script:PurchaseLib.ScannedAt
        try { $when = ([datetime]$script:PurchaseLib.ScannedAt).ToString('g') } catch { }
        $info = TF 'Purchases.ScannedAt' @($when)
        if ($script:PurchaseLib.Storefront) { $info += ' · ' + (TF 'Dash.Storefront' @($script:PurchaseLib.Storefront)) }
        if (-not $script:PurchaseLib.LookupOk) { $info += ' · ' + (T 'Purchases.LookupPartial') }
    }
    $u.PurScanInfo.Text = $info

    # Пустые состояния: одно понятное действие.
    $title = $null; $text = ''; $btn = $null; $busy = $false
    if (-not $script:Ctx.Binaries.Ipatool) { $title = T 'Setup.Title'; $text = T 'Setup.EmptyText'; $btn = 'Setup'; $busy = [bool]$script:UpdateTask }
    elseif (-not $loggedIn) { $title = T 'Purchases.Empty.LoginTitle'; $text = T 'Purchases.Empty.LoginText'; $btn = 'Login' }
    elseif ($loading) { $title = T 'Purchases.Empty.Loading'; $busy = $true }
    elseif ($script:PurchaseRows.Count -eq 0) {
        if ($scanning) { $title = T 'Purchases.Empty.Scanning'; $text = T 'Purchases.Empty.ScanningText'; $busy = $true }
        elseif ($script:PurchaseScanError) { $title = T 'Purchases.Empty.ErrorTitle'; $text = $script:PurchaseScanError; $btn = 'Scan' }
        elseif ($script:PurchaseLib) { $title = T 'Purchases.Empty.NoApps'; $text = T 'Purchases.Empty.NoAppsText'; $btn = 'Scan' }
        else { $title = T 'Purchases.Empty.NeverTitle'; $text = T 'Purchases.Empty.NeverText'; $btn = 'Scan' }
    } elseif ($u.PurGrid.Items.Count -eq 0) { $title = T 'Purchases.Empty.Filtered'; $text = T 'Purchases.Empty.FilteredText' }

    if ($title) {
        $u.PurEmptyTitle.Text = $title
        $u.PurEmptyText.Text = $text
        $u.PurEmptyText.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
        $u.PurBusy.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
        $u.PurEmptyBtn.Tag = $btn
        if ($btn) { $u.PurEmptyBtn.Content = switch ($btn) { 'Login' { T 'Dash.Login' } 'Setup' { T 'Setup.Install' } default { T 'Purchases.Scan' } }; $u.PurEmptyBtn.Visibility = 'Visible' }
        else { $u.PurEmptyBtn.Visibility = 'Collapsed' }
        $u.PurEmptyPanel.Visibility = 'Visible'
    } else { $u.PurEmptyPanel.Visibility = 'Collapsed' }
    Update-PurchaseButtons
}

function Update-PurchaseButtons {
    $u = $script:UI
    $sel = @($u.PurGrid.SelectedItems)
    $dl = @($sel | Where-Object { $script:PurchaseBase[$_.Id] -ne 'Downloaded' -and $_.Status -notin 'Queued', 'Running' })
    $hasTool = [bool]$script:Ctx.Binaries.Ipatool
    $u.PurDownloadText.Text = if ($dl.Count -gt 1) { TF 'Purchases.DownloadN' @($dl.Count) } else { T 'Purchases.Download' }
    $u.PurDownloadBtn.IsEnabled = $hasTool -and $dl.Count -gt 0
    $u.PurVersionBtn.IsEnabled = $hasTool -and $sel.Count -eq 1
    $allLocal = $sel.Count -gt 0 -and @($sel | Where-Object { $script:PurchaseBase[$_.Id] -ne 'Downloaded' }).Count -eq 0
    $u.PurInstallText.Text = if ($allLocal) { T 'Purchases.Install' } else { T 'Purchases.DownloadInstall' }
    $u.PurInstallBtn.IsEnabled = $sel.Count -gt 0 -and [bool]$script:Ctx.Binaries.IdeviceInstaller -and ($allLocal -or $hasTool)
    $u.PurMenuInstall.Header = $u.PurInstallText.Text
    $u.PurMenuInstall.IsEnabled = $u.PurInstallBtn.IsEnabled
    $u.PurShowFileBtn.IsEnabled = $sel.Count -eq 1 -and [bool]$sel[0].LocalPath
    $failed = @($script:PurchaseBase.Values | Where-Object { $_ -eq 'Failed' }).Count
    $u.PurRetryBtn.Visibility = if ($failed -gt 0) { 'Visible' } else { 'Collapsed' }
    $u.PurMenuDownload.IsEnabled = $u.PurDownloadBtn.IsEnabled
    $u.PurMenuVersion.IsEnabled = $u.PurVersionBtn.IsEnabled
    $u.PurMenuShow.IsEnabled = $u.PurShowFileBtn.IsEnabled
    $u.PurMenuStore.IsEnabled = $sel.Count -eq 1
    $u.PurMenuCopyId.IsEnabled = $sel.Count -gt 0
    $u.PurSelText.Text = if ($sel.Count -gt 0) { TF 'Purchases.Selected' @($sel.Count, $u.PurGrid.Items.Count) } elseif ($script:PurchaseRows.Count -gt 0) { TF 'Purchases.Shown' @($u.PurGrid.Items.Count, $script:PurchaseRows.Count) } else { '' }
}

# ---------------- Действия ----------------

function Invoke-DreddPurchaseEmptyAction {
    switch ($script:UI.PurEmptyBtn.Tag) {
        'Login' { Show-DreddPage 'Accounts'; [void]$script:UI.AccLoginEmail.Focus() }
        'Scan' { Start-DreddPurchaseScan }
        'Setup' { Start-DreddUpdateCheck -InstallNow }
    }
}

function Invoke-DreddPurchaseRowAction {
    param([IPADredd.Gui.PurchaseRow]$Row)
    if (-not $Row) { return }
    if ($Row.Status -in 'Queued', 'Running') {
        $q = $script:Queue | Where-Object { $_.AppId -eq $Row.Id -and $_.Status -in 'Queued', 'Running' } | Select-Object -First 1
        if ($q) { Stop-DreddDownloadItem $q }
        return
    }
    if ($script:PurchaseBase[$Row.Id] -eq 'Downloaded') { if ($Row.LocalPath) { Open-DreddPath $Row.LocalPath -Select }; return }
    Invoke-DreddPurchaseDownload @($Row)
}

function Invoke-DreddPurchaseDownload {
    # Купленные приложения скачиваются без --purchase: лицензия уже есть (или её нельзя получить для снятых с продажи).
    param([object[]]$Rows)
    $rows = @($Rows | Where-Object { $_ -and $script:PurchaseBase[$_.Id] -ne 'Downloaded' -and $_.Status -notin 'Queued', 'Running' })
    if ($rows.Count -eq 0 -or -not (Test-DreddLoggedIn)) { return }
    foreach ($r in $rows) { Add-DreddDownloadItem -AppId $r.Id -AppName $r.Name -Purchase $false }
    Add-DreddLog -Level Info -Area 'Download' -Message (TF 'Log.Queued' @($rows.Count))
    foreach ($r in $rows) { Update-DreddPurchaseRow $r }
    Update-PurchaseButtons
}

function Invoke-DreddPurchaseInstall {
    # Скачанное — сразу на iPhone; остальное (и «есть обновление») — скачать, затем установить. Без --purchase.
    param([object[]]$Rows)
    $apps = @($Rows | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Local = $(if ($script:PurchaseBase[$_.Id] -eq 'Downloaded') { $_.LocalPath } else { $null }) }
    })
    Invoke-DreddInstallApps -Apps $apps -Purchase $false
    foreach ($r in @($Rows)) { if ($r) { Update-DreddPurchaseRow $r } }
}

function Invoke-DreddPurchaseVersions {
    $r = $script:UI.PurGrid.SelectedItem
    if ($r -and (Test-DreddLoggedIn)) { Show-DreddVersionsDialog -AppId $r.Id -AppName $r.Name -NoPurchase }
}

function Copy-DreddPurchaseIds {
    $ids = @($script:UI.PurGrid.SelectedItems | ForEach-Object { $_.Id })
    if ($ids.Count -gt 0) { [System.Windows.Clipboard]::SetText(($ids -join ', ')); Add-DreddLog -Level Info -Area 'Purchases' -Message (TF 'Log.Copied' @($ids -join ', ')) }
}

function Start-DreddPurchaseScan {
    if ($script:PurchaseScanTask) { return }
    if (-not (Test-DreddLoggedIn)) { return }
    $a = $script:Account
    $script:PurchaseScanError = $null
    $script:PurchaseScanStep = T 'Purchases.Step.history'
    Add-DreddLog -Level Info -Area 'Purchases' -Message (T 'Log.PurchasesLoading')
    $script:PurchaseScanTask = Start-DreddTask -Name (T 'Task.Purchases') -Arguments @{ Email = $a.Email; Storefront = $a.Storefront } -Script {
        Update-DreddPurchaseLibrary -Context $Context -Email $A.Email -Storefront $A.Storefront -Reporter $Reporter -CancellationToken $Token
    } -OnMessage {
        param($item)
        if ($item.Type -ne 'status') { return }
        $script:PurchaseScanStep = if ($item.Message -eq 'lookup' -and $item.Value) { TF 'Purchases.Step.lookupN' @($item.Value.Done, $item.Value.Total) } else { T "Purchases.Step.$($item.Message)" }
        $script:UI.PurScanInfo.Text = $script:PurchaseScanStep
    } -OnComplete {
        param($r, $t)
        $script:PurchaseScanTask = $null
        $script:PurchaseScanStep = $null
        if ($t.Email -ne $script:PurchaseEmail) { Update-PurchasesView; return }
        if ($r.Ok) {
            Add-DreddLog -Level Success -Area 'Purchases' -Message (TF 'Log.PurchasesLoaded' @(@($r.Library.Apps).Count))
            if (-not $r.LookupOk) { Add-DreddLog -Level Warning -Area 'Purchases' -Message (T 'Purchases.LookupPartialLog') }
            Set-DreddPurchaseLibrary $r.Library
        } elseif ($r.Error.Key -ne 'Err.Cancelled') {
            $script:PurchaseScanError = Get-DreddErrorText $r.Error.Key $r.Error.Message
            Add-DreddLog -Level Error -Area 'Purchases' -Message $script:PurchaseScanError
            Update-PurchasesView
        } else { Update-PurchasesView }
    } -OnError {
        param($m)
        $script:PurchaseScanTask = $null
        $script:PurchaseScanStep = $null
        $script:PurchaseScanError = $m
        Add-DreddLog -Level Error -Area 'Purchases' -Message $m
        Update-PurchasesView
    }
    $script:PurchaseScanTask | Add-Member -NotePropertyName Email -NotePropertyValue $a.Email -Force
    Update-PurchasesView
}

function Start-DreddIconFetch {
    # Иконки догружаются в фоне и появляются в строках по мере загрузки.
    if ($script:PurchaseIconTask -or $script:SelfTestMode) { return }
    $need = @($script:PurchaseApps.Values | Where-Object { $_.ArtworkUrl -and -not $script:PurchaseById[$_.Id].HasIcon } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; ArtworkUrl = $_.ArtworkUrl } })
    if ($need.Count -eq 0) { return }
    $script:PurchaseIconTask = Start-DreddTask -Name (T 'Task.Icons') -Silent -Arguments @{ Apps = $need } -Script {
        Save-DreddIcons -Context $Context -Apps $A.Apps -Reporter $Reporter -CancellationToken $Token
    } -OnMessage {
        param($item)
        if ($item.Type -ne 'data' -or -not $item.Value) { return }
        $row = $script:PurchaseById[$item.Value.Id]
        if ($row) { $row.IconPath = $item.Value.Path }
    } -OnComplete {
        $script:PurchaseIconTask = $null
    } -OnError {
        param($m)
        $script:PurchaseIconTask = $null
        Add-DreddLog -Level Warning -Area 'Icons' -Message $m
    }
}

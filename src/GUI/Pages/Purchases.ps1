# Покупки: библиотека приложений из истории покупок Apple ID — иконки, статусы, фильтры, скачивание (AUDIT_4.4.md §4).

$script:PurchaseRows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.PurchaseRow]
$script:PurchaseById = @{}        # ID → строка таблицы
$script:PurchaseApps = @{}        # ID → запись кэша (Read-DreddPurchaseLibrary)
$script:PurchaseBase = @{}        # ID → статус без учёта очереди (для вкладок)
$script:PurchaseBadge = @{}       # ID → плашка «На iPhone» (Get-DreddPurchaseDeviceBadge)
$script:PurchaseTabSet = @{}      # ID → вкладки и фильтры, в которые попадает строка (Get-DreddPurchaseTabs)
$script:PurchaseLib = $null
$script:PurchaseEmail = $null     # аккаунт, чья библиотека показана
$script:PurchaseFilter = 'All'
$script:PurchaseScanTask = $null
$script:PurchaseLoadTask = $null
$script:PurchaseIconTask = $null
$script:PurchaseScanError = $null
$script:PurchaseScanStep = $null
# Сравнение с iPhone: @{ Udid; Name; Ios; Apps (ideviceinstaller list); At } и результат ID → { State; DeviceVersion }.
$script:DeviceCompare = $null
$script:DeviceMap = @{}
$script:DeviceAppsTask = $null
$script:DeviceStateOrder = @{ Missing = 0; Outdated = 1; Installed = 2; Unknown = 3 }

# Порядок сортировки по статусу: сначала то, что требует действия.
$script:PurchaseStatusOrder = @{ Running = 0; Queued = 1; UpdateAvailable = 2; Available = 3; Failed = 4; NotInStore = 5; Unverified = 6; Downloaded = 7 }
# Четыре главные вкладки; редкое — в меню «Фильтр» (сужает выбранную вкладку). Ключи — из Get-DreddPurchaseTabs.
$script:PurchaseTabs = [ordered]@{ PurTabAll = 'All'; PurTabNotOnDevice = 'NotOnDevice'; PurTabOnDevice = 'OnDevice'; PurTabDownloaded = 'Downloaded' }
$script:PurchaseFilterItems = [ordered]@{
    PurFltDeviceOutdated = 'DeviceOutdated'; PurFltUpdateAvailable = 'UpdateAvailable'; PurFltNotInStore = 'NotInStore'
    PurFltIncompatible = 'Incompatible'; PurFltFailed = 'Failed'
}
$script:PurchaseExtra = ''        # ключ фильтра из меню или ''
$script:PurchaseFailedCount = 0   # сколько «не удалось скачать» (для «Повторить неудачные» в меню)
$script:DeviceAutoTried = @{}     # UDID → автосравнение уже запускалось в этом сеансе

function Set-DreddPurchaseFilter {
    # Вкладка и (необязательно) фильтр — для плиток «Главной», снимков экрана и «Сбросить фильтр».
    param([string]$Tab = 'All', [string]$Extra = '')
    $script:PurchaseExtra = $Extra
    $name = @($script:PurchaseTabs.Keys | Where-Object { $script:PurchaseTabs[$_] -eq $Tab })[0]
    if ($name -and -not $script:UI[$name].IsChecked) { $script:UI[$name].IsChecked = $true } else { Update-PurchasesView }
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
    foreach ($name in $script:PurchaseFilterItems.Keys) {
        $u[$name].Tag = $script:PurchaseFilterItems[$name]
        # Повторный выбор того же фильтра снимает его.
        $u[$name].Add_Click({ param($s, $e) Safe { $script:PurchaseExtra = if ($script:PurchaseExtra -eq $s.Tag) { '' } else { [string]$s.Tag }; Update-PurchasesView } })
    }
    $u.PurFltReset.Add_Click({ Safe { $script:PurchaseExtra = ''; Update-PurchasesView } })
    $u.PurFilterBtn.Add_Click({ Safe {
        $m = $script:UI.PurFilterMenu
        $m.PlacementTarget = $script:UI.PurFilterBtn; $m.Placement = 'Bottom'; $m.IsOpen = $true
    } })
    # Поиск с небольшой задержкой: фильтр 1000+ строк на каждую букву не нужен.
    $script:PurSearchTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:PurSearchTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $script:PurSearchTimer.Add_Tick({ Safe { $script:PurSearchTimer.Stop(); Update-PurchasesView } })
    $u.PurSearch.Add_TextChanged({ $script:PurSearchTimer.Stop(); $script:PurSearchTimer.Start() })

    $u.PurScanBtn.Add_Click({ Safe { Start-DreddPurchaseScan } })
    $u.PurDeviceBtn.Add_Click({ Safe { Start-DreddDeviceAppsScan } })
    # Колонка «На iPhone» видна, когда есть с чем сравнивать (DataGridColumn не ищется по x:Name — берём по SortMemberPath).
    $script:PurDeviceColumn = $u.PurGrid.Columns | Where-Object { $_.SortMemberPath -eq 'DeviceOrder' } | Select-Object -First 1
    $u.PurCancelBtn.Add_Click({ Safe { if ($script:PurchaseScanTask) { Stop-DreddTask $script:PurchaseScanTask.Id } } })
    $u.PurEmptyBtn.Add_Click({ Safe { Invoke-DreddPurchaseEmptyAction } })
    $u.PurMenuRetry.Add_Click({ Safe { Invoke-DreddPurchaseDownload @($script:PurchaseRows | Where-Object { $script:PurchaseBase[$_.Id] -eq 'Failed' }) } })
    # Панель выбора и меню: массовая установка пропускает то, что уже стоит или не подходит к iOS устройства.
    $u.PurInstallBtn.Add_Click({ Safe { Invoke-DreddPurchaseInstall @($script:UI.PurGrid.SelectedItems) -SkipUnfit } })
    $u.PurMenuInstall.Add_Click({ Safe { Invoke-DreddPurchaseInstall @($script:UI.PurGrid.SelectedItems) -SkipUnfit } })
    $u.PurUninstallBtn.Add_Click({ Safe { Invoke-DreddPurchaseUninstall @($script:UI.PurGrid.SelectedItems) } })
    $u.PurMenuUninstall.Add_Click({ Safe { Invoke-DreddPurchaseUninstall @($script:UI.PurGrid.SelectedItems) } })
    $u.PurSelClearBtn.Add_Click({ Safe { $script:UI.PurGrid.UnselectAll() } })
    $u.PurSelMoreBtn.Add_Click({ Safe { Show-DreddPurchaseMenu $script:UI.PurSelMoreBtn } })
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
            if ($btn -is [System.Windows.Controls.Button] -and $btn.Tag -is [IPADredd.Gui.PurchaseRow]) {
                if ($btn.CommandParameter -eq 'more') {
                    # «⋯»: меню относится к этой строке, если она не входит в уже выбранные.
                    $g = $script:UI.PurGrid
                    if (-not $g.SelectedItems.Contains($btn.Tag)) { $g.SelectedItems.Clear(); $g.SelectedItem = $btn.Tag }
                    Show-DreddPurchaseMenu $btn
                } else { Invoke-DreddPurchaseRowAction $btn.Tag }
                $e.Handled = $true
            }
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

function Show-DreddPurchaseMenu {
    # Меню строки («⋯», правый клик) открывается под кнопкой.
    param($Target)
    Update-PurchaseButtons
    $m = $script:UI.PurMenu
    $m.PlacementTarget = $Target; $m.Placement = 'Bottom'; $m.IsOpen = $true
}

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
    $script:PurchaseBadge = @{}
    $script:PurchaseTabSet = @{}
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
        Update-DreddDeviceCompare
        $localMap = Get-DreddLocalIpaMap
        foreach ($row in $script:PurchaseRows) { Update-DreddPurchaseRow $row -LocalMap $localMap }
        Start-DreddIconFetch
        Start-DreddDeviceAutoCompare
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
    # Пересчёт всех строк (после обновления локальной библиотеки, смены языка, загрузки, поиска устройств).
    Update-DreddDeviceCompare
    $map = Get-DreddLocalIpaMap
    foreach ($row in $script:PurchaseRows) { Update-DreddPurchaseRow $row -LocalMap $map }
    Update-PurchasesView
}

function Update-DreddPurchaseRow {
    param([IPADredd.Gui.PurchaseRow]$Row, [hashtable]$LocalMap)
    $a = $script:PurchaseApps[$Row.Id]
    if (-not $a) { return }
    Update-DreddPurchaseDeviceInfo $Row
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
    Update-DreddPurchaseTabCache $Row
    $Row.VersionText = switch ($base) {
        'UpdateAvailable' { '{0} → {1}' -f $local.Version, $a.Version }
        'Downloaded' { [string]$local.Version }
        default { if ($a.Version) { [string]$a.Version } else { '—' } }
    }
    $region = if ($script:PurchaseLib -and $script:PurchaseLib.Storefront) { $script:PurchaseLib.Storefront } else { '?' }
    $Row.IsOnPc = [bool]$local
    $Row.PcText = T 'Purchases.Pc'
    $Row.PcHint = if ($local) { (T 'Purchases.PcHint') + "`n" + $local.Path } else { $null }
    $Row.SubText = if ($Row.PurchaseDateText) { '{0} · {1}' -f $Row.Artist, (TF 'Purchases.Bought' @($Row.PurchaseDateText)) } else { $Row.Artist }

    # Очередь загрузок важнее сохранённого статуса: вместо второй строки — ход загрузки, кнопка — «Отмена».
    $q = $null
    if ($script:Queue) { $q = $script:Queue | Where-Object { $_.AppId -eq $Row.Id -and $_.Status -in 'Queued', 'Running', 'InstallQueued', 'Installing' } | Select-Object -First 1 }
    if ($q -and $q.Status -in 'InstallQueued', 'Installing') {
        $Row.Status = 'Running'
        $Row.ShowProgress = ($q.Status -eq 'Installing')
        $Row.IsIndeterminate = $true
        $Row.StatusText = if ($q.Status -eq 'Installing') { TF 'Purchases.St.Installing' @($q.InstallDevice) } else { T 'Status.InstallQueued' }
        $Row.StatusDetail = $null
        $Row.Note = $Row.StatusText
        $Row.Action = 'None'
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
        $Row.Note = $Row.StatusText
        $Row.ActionText = T 'Common.Cancel'
        $Row.ActionEnabled = $true
        $Row.Action = 'Cancel'
        $Row.StatusOrder = $script:PurchaseStatusOrder[$q.Status]
        return
    }
    $Row.ShowProgress = $false
    $Row.Status = $base
    $Row.StatusOrder = $script:PurchaseStatusOrder[$base]
    # Заметка показывается только там, где есть что сказать; «можно скачать» и «скачано» видно и так (метка «ПК»).
    $note = ''
    switch ($base) {
        'Available' { $Row.StatusText = T 'Purchases.St.Available'; $Row.StatusDetail = $null }
        'Downloaded' {
            if ($a.Lookup -eq 'Missing') {
                # Снятое с продажи и уже скачанное — редкая копия, это стоит видеть.
                $Row.StatusText = T 'Purchases.St.DownloadedMissing'
                $Row.StatusDetail = TF 'Purchases.Detail.DownloadedMissing' @($local.Path, $region)
                $note = T 'Purchases.St.NotInStore'
            } else { $Row.StatusText = T 'Purchases.St.Downloaded'; $Row.StatusDetail = $local.Path }
        }
        'UpdateAvailable' {
            $Row.StatusText = TF 'Purchases.St.Update' @($a.Version)
            $Row.StatusDetail = TF 'Purchases.Detail.Update' @($local.Version, $a.Version)
        }
        'NotInStore' { $Row.StatusText = T 'Purchases.St.NotInStore'; $Row.StatusDetail = TF 'Purchases.Detail.NotInStore' @($region); $note = $Row.StatusText }
        'Failed' {
            $Row.StatusText = T 'Purchases.St.Failed'
            $when = ''
            try { if ($a.LastAttemptAt) { $when = ([datetime]$a.LastAttemptAt).ToString('g') } } catch { }
            $Row.StatusDetail = (TF 'Purchases.Detail.Failed' @($when)) + "`n" + (Get-DreddErrorText $a.LastErrorKey $a.LastErrorMessage)
            $note = $Row.StatusText
        }
        default { $Row.StatusText = T 'Purchases.St.Unverified'; $Row.StatusDetail = T 'Purchases.Detail.Unverified'; $note = $Row.StatusText }
    }
    $Row.Note = $note

    # Одна кнопка — главное действие строки (правило в ядре).
    $badge = [string]$script:PurchaseBadge[$Row.Id]
    $action = Get-DreddPurchaseRowAction -Status $base -Badge $badge
    $Row.Action = $action
    $Row.ActionEnabled = $action -ne 'Blocked'
    $Row.ActionText = switch ($action) {
        'Install' { T 'Purchases.ToDevice' }
        'Update' { T 'Purchases.Update' }
        'Blocked' { $Row.DeviceText }
        'Download' { if ($base -eq 'Failed') { T 'Purchases.Retry' } elseif ($base -eq 'NotInStore') { T 'Purchases.Try' } else { T 'Purchases.Download' } }
        default { '' }
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
        elseif ($a -and $Item.Status -eq 'Error' -and $Item.ErrorKey -and $Item.ErrorKey -ne 'Err.NoSpace') { $a.LastErrorKey = $Item.ErrorKey; $a.LastErrorMessage = $Item.ErrorMessage; $a.LastAttemptAt = (Get-Date).ToString('s') }
    }
    Update-DreddPurchaseRow $row
    Update-PurchaseCounts
}

# ---------------- Представление ----------------

function Update-DreddPurchaseTabCache {
    # Вкладки и фильтры строки считаются в ядре (Get-DreddPurchaseTabs) при каждом изменении статуса или состояния на iPhone.
    param([IPADredd.Gui.PurchaseRow]$Row)
    $a = $script:PurchaseApps[$Row.Id]
    if (-not $a -or -not $script:PurchaseBase.ContainsKey($Row.Id)) { return }
    $script:PurchaseTabSet[$Row.Id] = @(Get-DreddPurchaseTabs -App $a -Status $script:PurchaseBase[$Row.Id] -DeviceState $Row.DeviceState -Badge $script:PurchaseBadge[$Row.Id])
}

function Test-DreddPurchaseVisible {
    param($Row)
    $tabs = $script:PurchaseTabSet[$Row.Id]
    if ($script:PurchaseFilter -ne 'All' -and $tabs -notcontains $script:PurchaseFilter) { return $false }
    if ($script:PurchaseExtra -and $tabs -notcontains $script:PurchaseExtra) { return $false }
    $q = $script:PurchaseQuery
    if ([string]::IsNullOrEmpty($q)) { return $true }
    return ([string]$Row.SearchText).IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Update-PurchaseCounts {
    $c = @{ All = 0; Available = 0; Downloaded = 0; UpdateAvailable = 0; NotInStore = 0; Problems = 0; Failed = 0; NotOnDevice = 0; OnDevice = 0; DeviceOutdated = 0; Incompatible = 0 }
    foreach ($tabs in $script:PurchaseTabSet.Values) { foreach ($t in $tabs) { $c[$t]++ } }
    foreach ($name in $script:PurchaseTabs.Keys) {
        $key = $script:PurchaseTabs[$name]
        $sp = New-Object System.Windows.Controls.StackPanel
        $sp.Orientation = 'Horizontal'
        $t1 = New-Object System.Windows.Controls.TextBlock; $t1.Text = T "Purchases.Tab.$key"
        [void]$sp.Children.Add($t1)
        # Число для вкладок устройства — только после сравнения: «0» до него читалось бы как «на iPhone ничего нет».
        if ($key -notin 'NotOnDevice', 'OnDevice' -or $script:DeviceCompare) {
            $t2 = New-Object System.Windows.Controls.TextBlock; $t2.Text = [string]$c[$key]; $t2.Margin = '6,0,0,0'; $t2.Opacity = 0.6
            [void]$sp.Children.Add($t2)
        }
        $script:UI[$name].Content = $sp
    }
    # Меню «Фильтр»: счётчик справа, выбранный пункт отмечен; пустые пункты неактивны.
    foreach ($name in $script:PurchaseFilterItems.Keys) {
        $key = $script:PurchaseFilterItems[$name]
        $on = $script:PurchaseExtra -eq $key
        $script:UI[$name].Header = $(if ($on) { [string][char]0x2713 + ' ' } else { '' }) + (T "Purchases.Flt.$key")
        $script:UI[$name].InputGestureText = [string]$c[$key]
        $script:UI[$name].IsEnabled = $on -or $c[$key] -gt 0
    }
    $script:UI.PurFltReset.IsEnabled = [bool]$script:PurchaseExtra
    $script:UI.PurFilterText.Text = if ($script:PurchaseExtra) { T "Purchases.Flt.$($script:PurchaseExtra)" } else { T 'Purchases.Filter' }
    $script:UI.PurFilterBtn.SetResourceReference([System.Windows.Controls.Control]::BorderBrushProperty, $(if ($script:PurchaseExtra) { 'Brush.Accent' } else { 'Brush.Border' }))
    $script:PurchaseFailedCount = $c.Failed
    Update-DreddHome 'Tiles'
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
    $u.PurDeviceBtn.IsEnabled = $script:PurchaseRows.Count -gt 0 -and -not $script:DeviceAppsTask -and [bool]$script:Ctx.Binaries.IdeviceInstaller
    if ($script:PurDeviceColumn) {
        $script:PurDeviceColumn.Visibility = if ($script:DeviceCompare -or (Get-DreddPurchaseTargetDevice)) { 'Visible' } else { 'Collapsed' }
    }
    $u.PurCancelBtn.Visibility = if ($scanning) { 'Visible' } else { 'Collapsed' }
    $u.PurSearch.IsEnabled = $script:PurchaseRows.Count -gt 0

    # Шапка слева: «Приложений: N · обновлено …» (во время сканирования — его шаг).
    $info = ''
    if ($scanning) { $info = if ($script:PurchaseScanStep) { $script:PurchaseScanStep } else { T 'Purchases.Step.history' } }
    elseif ($script:PurchaseLib -and $script:PurchaseLib.ScannedAt) {
        $when = $script:PurchaseLib.ScannedAt
        try { $when = ([datetime]$script:PurchaseLib.ScannedAt).ToString('g') } catch { }
        $info = TF 'Purchases.Info' @($script:PurchaseRows.Count, $when)
        if ($script:PurchaseLib.Storefront) { $info += ' · ' + (TF 'Dash.Storefront' @($script:PurchaseLib.Storefront)) }
        if (-not $script:PurchaseLib.LookupOk) { $info += ' · ' + (T 'Purchases.LookupPartial') }
    }
    $u.PurInfoText.Text = $info
    $u.PurInfoText.ToolTip = if ($info) { $info } else { $null }

    # Шапка справа: с каким iPhone сравнено и ссылка «Сравнить снова» (до сравнения — «Сравнить с iPhone»).
    $devInfo = ''
    if ($script:DeviceAppsTask) { $devInfo = TF 'Purchases.DevScanning' @($script:DeviceAppsTask.DeviceName) }
    elseif ($script:DeviceCompare) { $devInfo = TF 'Purchases.DevInfo' @($script:DeviceCompare.Name, $script:DeviceCompare.At.ToString('t')) }
    $u.PurDevInfo.Text = $devInfo
    $u.PurDevDot.Visibility = if ($script:DeviceCompare -and -not $script:DeviceAppsTask) { 'Visible' } else { 'Collapsed' }
    $u.PurDeviceBtnText.Text = if ($script:DeviceCompare) { T 'Purchases.DeviceRescan' } else { T 'Purchases.DeviceScan' }
    $u.PurDeviceBtn.Visibility = if ($u.PurDeviceBtn.IsEnabled) { 'Visible' } else { 'Collapsed' }

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
    } elseif ($u.PurGrid.Items.Count -eq 0) {
        # Вкладки устройства до сравнения пусты не потому, что на iPhone ничего нет.
        if ($script:PurchaseFilter -in 'NotOnDevice', 'OnDevice' -and -not $script:DeviceCompare) {
            if ($script:DeviceAppsTask) { $title = TF 'Purchases.DevScanning' @($script:DeviceAppsTask.DeviceName); $busy = $true }
            else { $title = T 'Purchases.Empty.CompareTitle'; $text = T 'Purchases.Empty.CompareText'; if ($u.PurDeviceBtn.IsEnabled) { $btn = 'Compare' } }
        } else { $title = T 'Purchases.Empty.Filtered'; $text = T 'Purchases.Empty.FilteredText' }
    }

    if ($title) {
        $u.PurEmptyTitle.Text = $title
        $u.PurEmptyText.Text = $text
        $u.PurEmptyText.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
        $u.PurBusy.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
        $u.PurEmptyBtn.Tag = $btn
        if ($btn) { $u.PurEmptyBtn.Content = switch ($btn) { 'Login' { T 'Dash.Login' } 'Setup' { T 'Setup.Install' } 'Compare' { T 'Purchases.DeviceScan' } default { T 'Purchases.Scan' } }; $u.PurEmptyBtn.Visibility = 'Visible' }
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

    # Главная кнопка панели: «Обновить на iPhone», если все подходящие — старые версии, иначе «На iPhone».
    # Уже стоящее и не подходящее к iOS устройства в массовую установку не идёт.
    $fit = @(Get-DreddPurchaseInstallable $sel)
    $allLocal = $fit.Count -gt 0 -and @($fit | Where-Object { $script:PurchaseBase[$_.Id] -ne 'Downloaded' }).Count -eq 0
    $allOld = $fit.Count -gt 0 -and @($fit | Where-Object { $script:PurchaseBadge[$_.Id] -ne 'Outdated' }).Count -eq 0
    $label = if ($allOld) { 'Purchases.UpdateOnDevice' } else { 'Purchases.ToDevice' }
    $u.PurInstallText.Text = if ($fit.Count -gt 1) { TF ($label + 'N') @($fit.Count) } else { T $label }
    $u.PurInstallBtn.IsEnabled = $fit.Count -gt 0 -and [bool]$script:Ctx.Binaries.IdeviceInstaller -and ($allLocal -or $hasTool)
    # Ставить нечего (всё выбранное уже на iPhone или не подходит) — кнопку не показываем вовсе.
    $u.PurInstallBtn.Visibility = if ($fit.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $u.PurMenuInstall.Header = $u.PurInstallText.Text
    $u.PurMenuInstall.IsEnabled = $u.PurInstallBtn.IsEnabled

    $onDev = @(Get-DreddPurchaseOnDevice $sel)
    $u.PurUninstallBtn.Visibility = if ($onDev.Count -gt 0) { 'Visible' } else { 'Collapsed' }
    $u.PurUninstallBtn.IsEnabled = $onDev.Count -gt 0 -and [bool]$script:Ctx.Binaries.IdeviceInstaller -and -not $script:UninstallTask
    $u.PurUninstallText.Text = if ($onDev.Count -gt 1) { TF 'Purchases.UninstallN' @($onDev.Count) } else { T 'Purchases.Uninstall' }
    $u.PurMenuUninstall.Visibility = $u.PurUninstallBtn.Visibility
    $u.PurMenuUninstall.IsEnabled = $u.PurUninstallBtn.IsEnabled

    $u.PurMenuDownload.Header = if ($dl.Count -gt 1) { '{0} ({1})' -f (T 'Catalog.Download'), $dl.Count } else { T 'Catalog.Download' }
    $u.PurMenuDownload.IsEnabled = $hasTool -and $dl.Count -gt 0
    $u.PurMenuVersion.IsEnabled = $hasTool -and $sel.Count -eq 1
    $u.PurMenuShow.IsEnabled = $sel.Count -eq 1 -and [bool]$sel[0].LocalPath
    $u.PurMenuStore.IsEnabled = $sel.Count -eq 1
    $u.PurMenuCopyId.IsEnabled = $sel.Count -gt 0
    $failed = [int]$script:PurchaseFailedCount
    $u.PurMenuRetry.Visibility = if ($failed -gt 0) { 'Visible' } else { 'Collapsed' }
    $u.PurMenuRetry.Header = '{0} ({1})' -f (T 'Purchases.RetryFailed'), $failed

    # Низ: без выбора — счётчик и подсказка, при выборе — панель действий.
    if ($sel.Count -gt 0) {
        $u.PurSelCount.Text = TF 'Purchases.SelCount' @($sel.Count)
        $names = @($sel | Select-Object -First 3 | ForEach-Object { $_.Name })
        $u.PurSelNames.Text = ($names -join ', ') + $(if ($sel.Count -gt 3) { ' ' + (TF 'Purchases.AndMore' @($sel.Count - 3)) } else { '' })
        $u.PurSelBar.Visibility = 'Visible'; $u.PurFootPanel.Visibility = 'Collapsed'
    } else {
        $u.PurSelBar.Visibility = 'Collapsed'; $u.PurFootPanel.Visibility = 'Visible'
        $u.PurSelText.Text = if ($script:PurchaseRows.Count -gt 0) { (TF 'Purchases.Shown' @($u.PurGrid.Items.Count, $script:PurchaseRows.Count)) + ' · ' + (T 'Purchases.FootHint') } else { '' }
    }
}

function Get-DreddPurchaseInstallable {
    # Что из выбранного есть смысл ставить на iPhone: не стоит там в свежей версии и подходит к его iOS.
    param([object[]]$Rows)
    return @($Rows | Where-Object { $_ -and $script:PurchaseBadge[$_.Id] -notin 'Installed', 'NeedIos' -and $_.Status -notin 'Queued', 'Running' })
}

# ---------------- Действия ----------------

function Invoke-DreddPurchaseEmptyAction {
    switch ($script:UI.PurEmptyBtn.Tag) {
        'Login' { Show-DreddPage 'Accounts'; [void]$script:UI.AccLoginEmail.Focus() }
        'Scan' { Start-DreddPurchaseScan }
        'Setup' { Start-DreddUpdateCheck -InstallNow }
        'Compare' { Start-DreddDeviceAppsScan }
    }
}

function Invoke-DreddPurchaseRowAction {
    # Кнопка строки и двойной клик: главное действие (Get-DreddPurchaseRowAction), во время загрузки — отмена.
    param([IPADredd.Gui.PurchaseRow]$Row)
    if (-not $Row) { return }
    if ($Row.Status -in 'Queued', 'Running') {
        $q = $script:Queue | Where-Object { $_.AppId -eq $Row.Id -and $_.Status -in 'Queued', 'Running' } | Select-Object -First 1
        if ($q) { Stop-DreddDownloadItem $q }
        return
    }
    switch ($Row.Action) {
        'Install' { Invoke-DreddPurchaseInstall @($Row) }
        'Update' { Invoke-DreddPurchaseInstall @($Row) }
        'Download' { Invoke-DreddPurchaseDownload @($Row) }
        'Blocked' { }
        # Кнопки нет (стоит на iPhone или уже скачано): двойной клик показывает файл, если он есть.
        default { if ($Row.LocalPath) { Open-DreddPath $Row.LocalPath -Select } }
    }
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
    # -SkipUnfit (массовая установка): пропустить то, что уже стоит на iPhone или не подходит к его iOS, и сказать об этом.
    param([object[]]$Rows, [switch]$SkipUnfit)
    if ($SkipUnfit) {
        $all = @($Rows | Where-Object { $_ })
        $Rows = @(Get-DreddPurchaseInstallable $all)
        $skipped = $all.Count - $Rows.Count
        if ($skipped -gt 0) { Add-DreddLog -Level Warning -Area 'Install' -Message (TF 'Purchases.Skipped' @($skipped)) }
        if ($Rows.Count -eq 0) {
            if ($skipped -gt 0) { Show-DreddToast -Kind Info -Title (TF 'Purchases.Skipped' @($skipped)) -AutoHideMs 6000 }
            return
        }
    }
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
        $script:UI.PurInfoText.Text = $script:PurchaseScanStep
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

# ---------------- Сравнение с iPhone ----------------

function Get-DreddPurchaseTargetDevice {
    # Устройство для колонки «На iPhone»: то, с которым сравнивали, иначе единственное готовое. @{ Udid; Name; Ios } или $null.
    if ($script:DeviceCompare) { return $script:DeviceCompare }
    $ready = @($script:DeviceRows | Where-Object { $_.Status -eq 'Ready' })
    if ($ready.Count -eq 1) { return @{ Udid = $ready[0].Udid; Name = $ready[0].Name; Ios = $ready[0].IosVersion } }
    return $null
}

function Get-DreddLocalBundleMap {
    # App Store ID → bundle id из скачанных IPA (для приложений, которых нет в App Store и Lookup не дал bundle id).
    $m = @{}
    foreach ($l in $script:LibraryRows) { if ($l.AppStoreId -and $l.BundleId -and -not $m.ContainsKey($l.AppStoreId)) { $m[$l.AppStoreId] = $l.BundleId } }
    return $m
}

function Update-DreddDeviceCompare {
    # Пересчитывает сопоставление «покупки ↔ приложения на iPhone» (после сканирования, смены аккаунта, новых IPA).
    $script:DeviceMap = @{}
    if (-not $script:DeviceCompare -or $script:PurchaseApps.Count -eq 0) { return }
    $script:DeviceMap = Compare-DreddDeviceApps -Apps @($script:PurchaseApps.Values) -DeviceApps @($script:DeviceCompare.Apps) -LocalBundles (Get-DreddLocalBundleMap)
}

function Update-DreddPurchaseDeviceInfo {
    # Колонка «На iPhone»: состояние на устройстве и совместимость с его iOS (минимальная iOS — из App Store Lookup).
    param([IPADredd.Gui.PurchaseRow]$Row)
    $a = $script:PurchaseApps[$Row.Id]
    $dev = Get-DreddPurchaseTargetDevice
    if (-not $a -or -not $dev) {
        $Row.DeviceState = ''; $Row.DeviceText = ''; $Row.DeviceDetail = $null; $Row.DeviceOrder = 9
        $Row.Badge = ''
        $script:PurchaseBadge[$Row.Id] = ''
        Update-DreddPurchaseTabCache $Row
        return
    }
    $m = $script:DeviceMap[$Row.Id]
    $state = if ($script:DeviceCompare -and $m) { $m.State } else { '' }
    $badge = Get-DreddPurchaseDeviceBadge -App $a -DeviceState $state -DeviceIos $dev.Ios
    $Row.DeviceState = $state
    $Row.Badge = $badge
    $script:PurchaseBadge[$Row.Id] = $badge
    Update-DreddPurchaseTabCache $Row
    $Row.DeviceOrder = if ($state) { $script:DeviceStateOrder[$state] } else { 9 }
    $text = ''; $detail = $null
    switch ($state) {
        'Installed' { $text = TF 'Purchases.Dev.Installed' @($m.DeviceVersion); $detail = TF 'Purchases.DevDetail.Installed' @($dev.Name, $m.DeviceVersion) }
        'Outdated' { $text = TF 'Purchases.Dev.Outdated' @($m.DeviceVersion); $detail = TF 'Purchases.DevDetail.Outdated' @($dev.Name, $m.DeviceVersion, $a.Version) }
        'Missing' { $text = T 'Purchases.Dev.Missing'; $detail = TF 'Purchases.DevDetail.Missing' @($dev.Name) }
        'Unknown' { $text = T 'Purchases.Dev.Unknown'; $detail = T 'Purchases.DevDetail.Unknown' }
    }
    # Не установлено и не пойдёт на iOS этого устройства — важнее, чем «нет».
    if ($badge -eq 'NeedIos') {
        $text = TF 'Purchases.Dev.NeedIos' @($a.MinIOS)
        $need = TF 'Purchases.DevDetail.NeedIos' @($a.MinIOS, $dev.Name, $dev.Ios)
        $detail = if ($detail) { "$detail`n$need" } else { $need }
    }
    $Row.DeviceText = $text
    $Row.DeviceDetail = $detail
}

function Start-DreddDeviceAppsScan {
    <#
      «Сравнить с iPhone»: список приложений устройства → сопоставление с покупками.
      По кнопке: при необходимости ищет iPhone, по итогу открывает «Нет на iPhone» и показывает уведомление.
      -Device (автосравнение): уже найденное устройство; тихо — без уведомлений и смены вкладки, итог только в журнале.
    #>
    param($Device)
    if ($script:DeviceAppsTask) { return }
    $auto = [bool]$Device
    if ($script:PurchaseRows.Count -eq 0) {
        if (-not $auto) { Show-DreddToast -Kind Info -Title (T 'Purchases.DevNeedLibrary') -Text (T 'Purchases.DevNeedLibraryText') -AutoHideMs 6000 }
        return
    }
    $dev = if ($auto) { $Device } else { Get-DreddInstallTarget -Retry { Start-DreddDeviceAppsScan } }
    if (-not $dev) { return }
    if (-not $auto) { Hide-DreddToast }
    $script:DeviceAutoTried[$dev.Udid] = $true
    $script:DeviceAppsTask = Start-DreddTask -Name (T 'Task.DeviceApps') -Silent:$auto -Arguments @{ Udid = $dev.Udid; Connection = $dev.Connection } -Script {
        Get-DreddDeviceApps -Context $Context -Udid $A.Udid -Connection $A.Connection -Reporter $Reporter -CancellationToken $Token
    } -OnComplete {
        param($r, $t)
        $script:DeviceAppsTask = $null
        if ($r.Ok) {
            $script:DeviceCompare = @{ Udid = $t.Udid; Name = $t.DeviceName; Ios = $t.Ios; Apps = @($r.Apps); At = Get-Date }
            Update-DreddPurchaseStatuses
            $n = @{ Installed = 0; Missing = 0; Unknown = 0 }
            foreach ($row in $script:PurchaseRows) {
                switch ($row.DeviceState) { 'Installed' { $n.Installed++ } 'Outdated' { $n.Installed++ } 'Missing' { $n.Missing++ } 'Unknown' { $n.Unknown++ } }
            }
            $text = TF 'Purchases.DevDoneText' @($n.Installed, $n.Missing, $n.Unknown)
            Add-DreddLog -Level Success -Area 'Devices' -Message ((TF 'Purchases.DevDone' @($t.DeviceName)) + ': ' + $text)
            if (-not $t.Auto) {
                if ($n.Missing -gt 0) { Set-DreddPurchaseFilter -Tab 'NotOnDevice' }
                Show-DreddToast -Kind Success -Title (TF 'Purchases.DevDone' @($t.DeviceName)) -Text $text -AutoHideMs 8000
            }
        } elseif ($r.ErrorKey -ne 'Err.Cancelled') {
            $txt = Get-DreddErrorText $r.ErrorKey $(if ($r.ErrorKey -eq 'Err.DeviceAppsFormat') { '' } else { $r.Message })
            # Автосравнение не мешает уведомлениями: ошибка в журнале, сравнить можно ссылкой в шапке.
            Add-DreddLog -Level $(if ($t.Auto) { 'Warning' } else { 'Error' }) -Area 'Devices' -Message ((TF 'Purchases.DevFailed' @($t.DeviceName)) + ': ' + $txt)
            if (-not $t.Auto) { Show-DreddToast -Kind Error -Title (TF 'Purchases.DevFailed' @($t.DeviceName)) -Text $txt }
        }
        Update-PurchasesView
    } -OnError {
        param($m, $t)
        $script:DeviceAppsTask = $null
        Add-DreddLog -Level Error -Area 'Devices' -Message $m
        if (-not $t.Auto) { Show-DreddToast -Kind Error -Title (TF 'Purchases.DevFailed' @($t.DeviceName)) -Text $m }
        Update-PurchasesView
    }
    $script:DeviceAppsTask | Add-Member -NotePropertyName Udid -NotePropertyValue $dev.Udid -Force
    $script:DeviceAppsTask | Add-Member -NotePropertyName DeviceName -NotePropertyValue $dev.Name -Force
    $script:DeviceAppsTask | Add-Member -NotePropertyName Ios -NotePropertyValue $dev.IosVersion -Force
    $script:DeviceAppsTask | Add-Member -NotePropertyName Auto -NotePropertyValue $auto -Force
    Update-PurchasesView
}

function Start-DreddDeviceAutoCompare {
    # Сравнение само: iPhone найден (ровно один готовый), покупки загружены, с этим телефоном в этом сеансе ещё не сравнивали.
    # Самопроверка и снимки экрана управляют сравнением сами.
    if ($script:SelfTestMode -or $script:DeviceAppsTask -or $script:PurchaseRows.Count -eq 0) { return }
    if (-not $script:Ctx.Binaries.IdeviceInstaller) { return }
    $ready = @($script:DeviceRows | Where-Object { $_.Status -eq 'Ready' })
    if ($ready.Count -ne 1) { return }
    $dev = $ready[0]
    if ($script:DeviceAutoTried[$dev.Udid]) { return }
    if ($script:DeviceCompare -and $script:DeviceCompare.Udid -eq $dev.Udid) { return }
    Start-DreddDeviceAppsScan -Device $dev
}

function Get-DreddPurchaseOnDevice {
    # Выбранные строки, которые стоят на iPhone, с которым сравнивали, и для которых известен bundle id на устройстве.
    param([object[]]$Rows)
    if (-not $script:DeviceCompare) { return @() }
    return @($Rows | Where-Object { $_ -and $_.DeviceState -in 'Installed', 'Outdated' -and $script:DeviceMap[$_.Id] -and $script:DeviceMap[$_.Id].DeviceBundleId })
}

$script:UninstallTask = $null

function Invoke-DreddPurchaseUninstall {
    # «Удалить с iPhone»: с подтверждением (данные приложения на телефоне тоже удаляются), по одному, с итогом.
    param([object[]]$Rows)
    $rows = @(Get-DreddPurchaseOnDevice $Rows)
    if ($rows.Count -eq 0 -or $script:UninstallTask) { return }
    $dev = $script:DeviceCompare
    $names = (@($rows | Select-Object -First 8 | ForEach-Object { "• $($_.Name)" }) + @(if ($rows.Count -gt 8) { TF 'Purchases.AndMore' @($rows.Count - 8) })) -join "`n"
    if (-not (Confirm-Dredd -Title (TF 'Purchases.UninstallTitle' @($rows.Count, $dev.Name)) -Message ((T 'Purchases.UninstallText') + "`n`n" + $names) -YesText (T 'Purchases.Uninstall') -Danger -Kind Warning)) { return }
    $items = @($rows | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; BundleId = $script:DeviceMap[$_.Id].DeviceBundleId; Version = $script:DeviceMap[$_.Id].DeviceVersion } })
    $script:UninstallTask = Start-DreddTask -Name (T 'Task.Uninstall') -Arguments @{ Items = $items; Udid = $dev.Udid; Device = $dev.Name } -Script {
        $results = @()
        foreach ($it in $A.Items) {
            if ($Token.IsCancellationRequested) { break }
            $r = Uninstall-DreddApp -Context $Context -BundleId $it.BundleId -UDID $A.Udid -Reporter $Reporter -CancellationToken $Token
            $res = if ($r.Ok) { 'Success' } elseif ($r.ErrorKey -eq 'Err.Cancelled') { 'Cancelled' } else { 'Error' }
            Add-DreddHistoryEntry -Context $Context -Kind Uninstall -AppId $it.Id -Name $it.Name -Version $it.Version -Target $A.Device -Result $res -Message $r.Message
            if ($r.Ok) { Write-DreddReport -Reporter $Reporter -Type log -Level Success -Area 'Uninstall' -Message ("✔ {0} ✕ {1}" -f $it.Name, $A.Device) }
            else { Write-DreddReport -Reporter $Reporter -Type log -Level Error -Area 'Uninstall' -Message ("✖ {0}: {1} {2}" -f $it.Name, $r.ErrorKey, $r.Message) }
            $results += [pscustomobject]@{ Id = $it.Id; Name = $it.Name; BundleId = $it.BundleId; Ok = $r.Ok; ErrorKey = $r.ErrorKey; Message = $r.Message }
        }
        , $results
    } -OnComplete {
        param($results)
        $script:UninstallTask = $null
        $ok = @($results | Where-Object { $_.Ok })
        $fail = @($results | Where-Object { -not $_.Ok -and $_.ErrorKey -ne 'Err.Cancelled' })
        if ($ok.Count -gt 0 -and $script:DeviceCompare) {
            # Удалённое больше не «на iPhone»: убираем из списка приложений устройства и пересчитываем сравнение.
            $gone = @($ok | ForEach-Object { $_.BundleId.ToLowerInvariant() })
            $script:DeviceCompare.Apps = @($script:DeviceCompare.Apps | Where-Object { -not $_.BundleId -or $gone -notcontains $_.BundleId.ToLowerInvariant() })
            Update-DreddPurchaseStatuses
        }
        $title = TF 'Purchases.Uninstalled' @($ok.Count, $script:DeviceCompare.Name)
        if ($fail.Count -gt 0) {
            $lines = $fail | ForEach-Object { "• $($_.Name): $(Get-DreddErrorText $_.ErrorKey $_.Message)" }
            Show-DreddToast -Kind Warning -Title $title -Text ($lines -join "`n")
        } elseif ($ok.Count -gt 0) { Show-DreddToast -Kind Success -Title $title -AutoHideMs 5000 -Low }
        if (Get-Command Update-DownloadsHistory -ErrorAction SilentlyContinue) { Update-DownloadsHistory }
        Update-PurchasesView
    } -OnError {
        param($m)
        $script:UninstallTask = $null
        Add-DreddLog -Level Error -Area 'Uninstall' -Message $m
        Update-PurchaseButtons
    }
    Update-PurchaseButtons
}

function Set-DreddDeviceAppInstalled {
    # После успешной установки на тот же iPhone, с которым сравнивали: приложение отмечается как установленное.
    param([string]$AppId, [string]$Udid, [string]$Version)
    if (-not $script:DeviceCompare -or $script:DeviceCompare.Udid -ne $Udid -or $AppId -notmatch '^\d+$') { return }
    $a = $script:PurchaseApps[$AppId]
    $bundle = if ($a -and $a.BundleId) { [string]$a.BundleId } else { [string](Get-DreddLocalBundleMap)[$AppId] }
    # Synthetic: App Store ID добавлен программой, а не получен от устройства (не влияет на правило «нет ID — нет на iPhone»).
    $script:DeviceCompare.Apps = @($script:DeviceCompare.Apps | Where-Object { $_.ItemId -ne $AppId -and (-not $bundle -or $_.BundleId -ne $bundle) }) +
        @([pscustomobject]@{ BundleId = $bundle; Name = ''; Version = $Version; Build = ''; ItemId = $AppId; Synthetic = $true })
    Update-DreddDeviceCompare
    $row = $script:PurchaseById[$AppId]
    # Строка целиком: вместе с плашкой меняется и кнопка действия.
    if ($row) { Update-DreddPurchaseRow $row }
    Update-PurchasesView
}

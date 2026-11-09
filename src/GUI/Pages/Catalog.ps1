# Поиск: App Store + популярные + свой список. Покупки аккаунта — на экране «Покупки» (Purchases.ps1).

$script:CatalogRows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.CatalogRow]
$script:CatalogSource = 'Popular'
$script:StoreResults = @()          # результаты App Store для последнего запроса
$script:StoreQuery = $null
$script:CatalogTask = $null
$script:CatalogError = $null

function Initialize-CatalogPage {
    $u = $script:UI
    $u.CatalogGrid.ItemsSource = $script:CatalogRows
    foreach ($pair in @(@('SrcSearch', 'Search'), @('SrcPopular', 'Popular'), @('SrcCustom', 'Custom'))) {
        $u[$pair[0]].Tag = $pair[1]
        $u[$pair[0]].Add_Checked({ param($s, $e) Safe { Set-DreddCatalogSource $s.Tag } })
    }
    $u.CatalogQuery.Add_TextChanged({ Safe { Update-CatalogView } })
    $u.CatalogQuery.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Safe { Start-DreddStoreSearch } } })
    $u.CatalogSearchBtn.Add_Click({ Safe { Start-DreddStoreSearch } })
    $u.CatalogCancelBtn.Add_Click({ Safe { if ($script:CatalogTask) { Stop-DreddTask $script:CatalogTask.Id } } })
    $u.CatalogGrid.Add_SelectionChanged({ Safe { Update-CatalogButtons } })
    $u.CatalogGrid.Add_MouseDoubleClick({ Safe { if ($script:UI.CatalogGrid.SelectedItem) { Invoke-DreddCatalogDownload } } })
    $u.CatalogDownloadBtn.Add_Click({ Safe { Invoke-DreddCatalogDownload } })
    $u.CatalogVersionBtn.Add_Click({ Safe { $r = $script:UI.CatalogGrid.SelectedItem; if ($r -and (Test-DreddLoggedIn)) { Show-DreddVersionsDialog -AppId $r.Id -AppName $r.Name } } })
    $u.CatMenuPurchase.Add_Click({ Safe { Invoke-DreddCatalogPurchase } })
    $u.CatMenuAddCustom.Add_Click({ Safe { Invoke-DreddCatalogAddCustom } })
    $u.CatMenuCopyId.Add_Click({ Safe {
        $ids = @($script:UI.CatalogGrid.SelectedItems | ForEach-Object { $_.Id })
        if ($ids.Count -gt 0) { [System.Windows.Clipboard]::SetText(($ids -join ', ')); Add-DreddLog -Level Info -Area 'Catalog' -Message (TF 'Log.Copied' @($ids -join ', ')) }
    } })
    $u.CatalogAutoPurchase.Add_Click({ Safe { Set-DreddAutoPurchase ([bool]$script:UI.CatalogAutoPurchase.IsChecked) } })
    $u.CatMenuDownload.Add_Click({ Safe { Invoke-DreddCatalogDownload } })
    $u.CatMenuInstall.Add_Click({ Safe { Invoke-DreddCatalogInstall @($script:UI.CatalogGrid.SelectedItems) } })
    $u.CatalogInstallBtn.Add_Click({ Safe { Invoke-DreddCatalogInstall @($script:UI.CatalogGrid.SelectedItems) } })
    $u.CatMenuVersion.Add_Click({ Safe { $script:UI.CatalogVersionBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
    $u.CatalogGrid.Add_PreviewKeyDown({ param($s, $e) Safe {
        $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        if ($e.Key -eq 'Return') { Invoke-DreddCatalogDownload; $e.Handled = $true }
        elseif ($ctrl -and $e.Key -eq 'C') { $script:UI.CatMenuCopyId.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent))); $e.Handled = $true }
    } })
    $script:CatalogIconTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:CatalogIconTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:CatalogIconTimer.Add_Tick({ Safe { $script:CatalogIconTimer.Stop(); Start-DreddCatalogIconFetch } })
}

function Show-CatalogPage {
    $script:UI.CatalogAutoPurchase.IsChecked = ConvertTo-DreddBool $script:Ctx.Settings['AutoPurchase']
    Update-CatalogView
}

function Set-DreddCatalogSource {
    param([string]$Source)
    $script:CatalogSource = $Source
    $script:CatalogError = $null
    Update-CatalogView
}

function Get-DreddSourceText {
    param([string]$Source)
    return T "Source.App.$Source"
}

function New-DreddCatalogRow {
    param($Item, [string]$Source)
    $r = New-Object IPADredd.Gui.CatalogRow
    $r.Name = [string]$Item.Name
    $r.Id = [string]$Item.ID
    $r.Version = [string](Get-DreddProp $Item 'Version' '')
    $r.BundleId = [string](Get-DreddProp $Item 'BundleId' '')
    $src = $Source
    if (-not $src) { $src = [string](Get-DreddProp $Item 'Source' 'Popular') }
    $r.Source = $src
    $r.SourceText = Get-DreddSourceText $src
    $r.PurchaseDate = [string](Get-DreddProp $Item 'PurchaseDate' '')
    $sd = Get-DreddProp $Item 'SortDate' $null
    if ($sd -is [datetime]) { $r.SortDate = $sd }
    if (-not $r.Version -and $script:CatalogVersions.ContainsKey($r.Id)) { $r.Version = $script:CatalogVersions[$r.Id] }
    $r.IconPath = Get-DreddIconPath -Context $script:Ctx -AppId $r.Id
    return $r
}

# ---------------- Иконки и версии для списков ----------------
# Для строк без иконки — iTunes Lookup (регион аккаунта или US) и загрузка иконок в общий кэш Files/Cache/Icons.
# Каждый ID запрашивается не больше одного раза за запуск.

$script:CatalogVersions = @{}
$script:CatalogIconTried = New-Object 'System.Collections.Generic.HashSet[string]'
$script:CatalogIconTask = $null

function Request-DreddCatalogIcons {
    if ($script:SelfTestMode -or -not $script:CatalogIconTimer) { return }
    $script:CatalogIconTimer.Stop(); $script:CatalogIconTimer.Start()
}

function Start-DreddCatalogIconFetch {
    if ($script:CatalogIconTask) { return }
    $ids = @($script:CatalogRows | Where-Object { -not $_.HasIcon -and $_.Id -match '^\d+$' -and $script:CatalogIconTried.Add($_.Id) } | ForEach-Object { $_.Id } | Select-Object -First 600)
    if ($ids.Count -eq 0) { return }
    $cc = if ($script:Account -and $script:Account.Success) { ConvertTo-DreddCountryCode $script:Account.Storefront } else { $null }
    if (-not $cc) { $cc = 'us' }
    $script:CatalogIconTask = Start-DreddTask -Name (T 'Task.Icons') -Silent -Arguments @{ Ids = $ids; Country = $cc } -Script {
        $lk = Invoke-DreddStoreLookup -Ids $A.Ids -Country $A.Country -CancellationToken $Token
        $apps = foreach ($id in $lk.Found.Keys) {
            $f = $lk.Found[$id]
            Write-DreddReport -Reporter $Reporter -Type data -Area 'Icons' -Value @{ Id = $id; Version = $f.Version }
            [pscustomobject]@{ Id = $id; ArtworkUrl = $f.ArtworkUrl }
        }
        Save-DreddIcons -Context $Context -Apps @($apps) -Reporter $Reporter -CancellationToken $Token
    } -OnMessage {
        param($item)
        if ($item.Type -ne 'data' -or -not $item.Value) { return }
        $v = $item.Value
        if ($v.Version) { $script:CatalogVersions[$v.Id] = $v.Version }
        foreach ($r in $script:CatalogRows) {
            if ($r.Id -ne $v.Id) { continue }
            if ($v.Path) { $r.IconPath = $v.Path }
            if ($v.Version -and -not $r.Version) { $r.Version = $v.Version }
        }
        $p = $script:PurchaseById[$v.Id]
        if ($p -and $v.Path -and -not $p.HasIcon) { $p.IconPath = $v.Path }
    } -OnComplete {
        $script:CatalogIconTask = $null
        Request-DreddCatalogIcons
    } -OnError {
        param($m)
        $script:CatalogIconTask = $null
        Add-DreddLog -Level Warning -Area 'Icons' -Message $m
    }
}

function Update-CatalogView {
    # Перестраивает таблицу для текущего источника и строки поиска (локально, без сети).
    $u = $script:UI
    $q = $u.CatalogQuery.Text
    $items = New-Object System.Collections.Generic.List[object]
    switch ($script:CatalogSource) {
        'Search' {
            $ids = Split-DreddIdQuery $q
            if ($ids) {
                foreach ($id in $ids) {
                    $n = Resolve-DreddAppName -Context $script:Ctx -AppId $id
                    $items.Add((New-DreddCatalogRow ([pscustomobject]@{ Name = $(if ($n) { $n } else { $id }); ID = $id }) 'ID'))
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($q)) {
                $local = @(Search-DreddLocalApps -Context $script:Ctx -Query $q)
                $seen = New-Object 'System.Collections.Generic.HashSet[string]'
                $store = @()
                if ($script:StoreQuery -and $q.Trim() -eq $script:StoreQuery) { $store = @($script:StoreResults) }
                $storeById = @{}; foreach ($s in $store) { $storeById[$s.ID] = $s }
                foreach ($l in $local) {
                    if ($seen.Add($l.ID)) {
                        $row = New-DreddCatalogRow $l
                        if ($storeById.ContainsKey($l.ID)) { $row.Version = $storeById[$l.ID].Version }
                        $items.Add($row)
                    }
                }
                foreach ($s in $store) { if ($seen.Add($s.ID)) { $items.Add((New-DreddCatalogRow $s 'AppStore')) } }
            }
        }
        'Popular' { foreach ($a in @(Search-DreddLocalApps -Context $script:Ctx -Query $q -Scope Popular)) { $items.Add((New-DreddCatalogRow $a 'Popular')) } }
        'Custom' { foreach ($a in @(Search-DreddLocalApps -Context $script:Ctx -Query $q -Scope Custom)) { $items.Add((New-DreddCatalogRow $a 'Custom')) } }
    }
    $script:CatalogRows.Clear()
    foreach ($i in $items) { $script:CatalogRows.Add($i) }
    Update-CatalogStatuses
    Update-CatalogEmptyState
    Update-CatalogButtons
    Request-DreddCatalogIcons
}

function Test-DreddContainsUi {
    param([string]$Text, [string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $true }
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text.IndexOf($Query.Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Update-CatalogStatuses {
    $purchased = New-Object 'System.Collections.Generic.HashSet[string]'
    $acc = if ($script:Account -and $script:Account.Success) { $script:Account.Email } else { $null }
    if ($acc) { foreach ($p in @(Get-DreddPurchasedApps -Context $script:Ctx -Account $acc)) { [void]$purchased.Add($p.ID) } }
    # «Нет в истории покупок» — только если история этого аккаунта получена; иначе статус неизвестен и не показывается.
    $history = $script:PurchaseApps
    $haveHistory = $script:PurchaseLib -and $script:PurchaseEmail -and $acc -and ($script:PurchaseEmail -eq $acc)
    foreach ($r in $script:CatalogRows) {
        if ($script:LibraryIds.Contains($r.Id) -or ($r.BundleId -and $script:LibraryBundles.Contains($r.BundleId))) { $r.StatusText = T 'Catalog.InLibrary' }
        elseif ($haveHistory -and $history.ContainsKey($r.Id)) { $r.StatusText = T 'Catalog.InHistory' }
        elseif ($purchased.Contains($r.Id)) { $r.StatusText = T 'Catalog.Purchased' }
        elseif ($haveHistory) { $r.StatusText = T 'Catalog.NotInHistory' }
        else { $r.StatusText = '' }
    }
}

function Update-CatalogEmptyState {
    $u = $script:UI
    $busy = [bool]$script:CatalogTask
    $u.CatalogBusy.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    $u.CatalogCancelBtn.Visibility = if ($busy) { 'Visible' } else { 'Collapsed' }
    $u.CatalogSearchBtn.IsEnabled = -not $busy -and [bool]$script:Ctx.Binaries.Ipatool
    $text = $null
    if ($busy) { $text = T 'Catalog.Loading' }
    elseif ($script:CatalogError) { $text = $script:CatalogError }
    elseif ($script:CatalogRows.Count -eq 0) {
        $q = $script:UI.CatalogQuery.Text
        switch ($script:CatalogSource) {
            'Search' { $text = if ([string]::IsNullOrWhiteSpace($q)) { T 'Catalog.EmptySearch' } else { T 'Catalog.NothingFound' } }
            'Custom' { $text = if ([string]::IsNullOrWhiteSpace($q)) { T 'Catalog.EmptyCustom' } else { T 'Catalog.NothingFound' } }
            default { $text = T 'Catalog.NothingFound' }
        }
    }
    if ($text) { $u.CatalogEmptyText.Text = $text; $u.CatalogEmptyPanel.Visibility = 'Visible' } else { $u.CatalogEmptyPanel.Visibility = 'Collapsed' }
    $u.CatalogCount.Text = TF 'Catalog.Count' @($script:CatalogRows.Count)
}

function Update-CatalogButtons {
    $u = $script:UI
    $n = $u.CatalogGrid.SelectedItems.Count
    $hasTool = [bool]$script:Ctx.Binaries.Ipatool
    $u.CatalogDownloadBtn.IsEnabled = $n -gt 0 -and $hasTool
    $u.CatalogVersionBtn.IsEnabled = $n -eq 1 -and $hasTool
    $u.CatMenuPurchase.IsEnabled = $n -gt 0 -and $hasTool
    $u.CatMenuAddCustom.IsEnabled = $n -gt 0
    $u.CatMenuCopyId.IsEnabled = $n -gt 0
    $u.CatMenuDownload.IsEnabled = $u.CatalogDownloadBtn.IsEnabled
    $u.CatMenuInstall.IsEnabled = $n -gt 0 -and [bool]$script:Ctx.Binaries.IdeviceInstaller
    $u.CatalogInstallBtn.IsEnabled = $u.CatMenuInstall.IsEnabled
    $u.CatMenuVersion.IsEnabled = $u.CatalogVersionBtn.IsEnabled
}

function Start-DreddStoreSearch {
    $q = $script:UI.CatalogQuery.Text.Trim()
    if (-not $q -or $script:CatalogTask) { return }
    if ($script:CatalogSource -ne 'Search') { $script:UI.SrcSearch.IsChecked = $true }
    if (Split-DreddIdQuery $q) { Update-CatalogView; return }
    if (-not (Test-DreddLoggedIn)) { return }
    $script:CatalogError = $null
    $script:PendingStoreQuery = $q
    $script:CatalogTask = Start-DreddTask -Name (T 'Task.StoreSearch') -Arguments @{ Query = $q } -Script {
        Search-DreddAppStore -Context $Context -Query $A.Query -Limit 25 -Reporter $Reporter -CancellationToken $Token
    } -OnComplete {
        param($r, $t)
        $script:CatalogTask = $null
        if ($r.Ok) {
            $script:StoreResults = @($r.Apps)
            $script:StoreQuery = $script:PendingStoreQuery
            Add-DreddLog -Level Info -Area 'Catalog' -Message (TF 'Log.StoreResults' @(@($r.Apps).Count))
        } elseif ($r.Error.Key -ne 'Err.Cancelled') {
            $script:CatalogError = Get-DreddErrorText $r.Error.Key $r.Error.Message
            Add-DreddLog -Level Error -Area 'Catalog' -Message $script:CatalogError
        }
        Update-CatalogView
    } -OnError {
        param($m)
        $script:CatalogTask = $null
        $script:CatalogError = $m
        Update-CatalogView
    }
    Update-CatalogEmptyState
}

function Invoke-DreddCatalogInstall {
    # «На iPhone»: уже скачанное ставится из файла, остальное — скачать и установить.
    param([object[]]$Rows)
    $map = Get-DreddLocalIpaMap
    $apps = @($Rows | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Name = $_.Name; Local = $(if ($map[$_.Id]) { $map[$_.Id].Path } else { $null }) } })
    Invoke-DreddInstallApps -Apps $apps -Purchase (ConvertTo-DreddBool $script:Ctx.Settings['AutoPurchase'])
}

function Get-DreddCatalogDownloaded {
    # Строки, которые уже скачаны в той же (или более новой) версии. Версия в строке неизвестна — считаем скачанным.
    param([object[]]$Rows, [hashtable]$Map)
    return @($Rows | Where-Object {
        $l = $Map[$_.Id]
        $l -and (-not $_.Version -or (Compare-DreddVersion $l.Version $_.Version) -ge 0)
    })
}

function Invoke-DreddCatalogDownload {
    $sel = @($script:UI.CatalogGrid.SelectedItems)
    if ($sel.Count -eq 0 -or -not (Test-DreddLoggedIn)) { return }
    # Уже скачанное не качаем повторно молча (раньше каждое нажатие давало новый файл _2, _3…): спрашиваем.
    $map = Get-DreddLocalIpaMap
    $have = @(Get-DreddCatalogDownloaded -Rows $sel -Map $map)
    if ($have.Count -gt 0) {
        $names = ($have | ForEach-Object { '• {0} {1}' -f $_.Name, $map[$_.Id].Version }) -join "`n"
        $buttons = @(@{ Key = 'cancel'; Text = (T 'Common.Cancel') }, @{ Key = 'again'; Text = (T 'Catalog.DownloadAgain') })
        if ($script:Ctx.Binaries.IdeviceInstaller) { $buttons += @{ Key = 'install'; Text = (T 'Catalog.ToIphone'); Kind = 'Primary' } }
        $choice = Show-DreddDialog -Title (T 'Catalog.AlreadyTitle') -Message ((T 'Catalog.AlreadyText') + "`n`n" + $names) -Kind Question -Buttons $buttons
        if ($choice -eq 'install') { Invoke-DreddCatalogInstall $have; $sel = @($sel | Where-Object { $have -notcontains $_ }) }
        elseif ($choice -ne 'again') { $sel = @($sel | Where-Object { $have -notcontains $_ }) }
        if ($sel.Count -eq 0) { return }
    }
    $purchase = ConvertTo-DreddBool $script:Ctx.Settings['AutoPurchase']
    foreach ($r in $sel) { Add-DreddDownloadItem -AppId $r.Id -AppName $r.Name -Purchase $purchase }
    Add-DreddLog -Level Info -Area 'Download' -Message (TF 'Log.Queued' @($sel.Count))
    Show-DreddPage 'Downloads'
}

function Invoke-DreddCatalogPurchase {
    $sel = @($script:UI.CatalogGrid.SelectedItems)
    if ($sel.Count -eq 0 -or -not (Test-DreddLoggedIn)) { return }
    $names = ($sel | Select-Object -First 8 | ForEach-Object { "• $($_.Name) ($($_.Id))" }) -join "`n"
    if ($sel.Count -gt 8) { $names += "`n…" }
    if (-not (Confirm-Dredd -Title (TF 'Catalog.PurchaseTitle' @($sel.Count)) -Message ((T 'Catalog.PurchaseText') + "`n`n" + $names) -YesText (T 'Catalog.PurchaseOnly'))) { return }
    $apps = @($sel | ForEach-Object { [pscustomobject]@{ ID = $_.Id; Name = $_.Name } })
    [void](Start-DreddTask -Name (T 'Task.Purchase') -Arguments @{ Apps = $apps; Account = $script:Account.Email } -Script {
        $res = @()
        foreach ($a in $A.Apps) {
            if ($Token.IsCancellationRequested) { break }
            $r = Invoke-DreddPurchase -Context $Context -AppId $a.ID -AppName $a.Name -Account $A.Account -Reporter $Reporter -CancellationToken $Token
            $status = if ($r.Ok) { 'Success' } else { 'Error' }
            Add-DreddHistoryEntry -Context $Context -Kind Purchase -AppId $a.ID -Name $a.Name -Account $A.Account -Result $status -Message $(if ($r.Error) { $r.Error.Message } else { '' })
            if ($r.Ok) { Write-DreddReport -Reporter $Reporter -Type log -Level Success -Area 'Purchase' -Message ("✔ {0} ({1})" -f $a.Name, $a.ID) }
            else { Write-DreddReport -Reporter $Reporter -Type log -Level Error -Area 'Purchase' -Message ("✖ {0} ({1}): {2}" -f $a.Name, $a.ID, $r.Error.Message) }
            $res += [pscustomobject]@{ ID = $a.ID; Name = $a.Name; Ok = $r.Ok; Key = $(if ($r.Error) { $r.Error.Key } else { $null }) }
        }
        , $res
    } -OnComplete {
        param($res)
        $ok = @($res | Where-Object { $_.Ok }).Count
        Add-DreddLog -Level Info -Area 'Purchase' -Message (TF 'Log.PurchaseSummary' @($ok, @($res).Count))
        Update-CatalogStatuses
    })
}

function Invoke-DreddCatalogAddCustom {
    $sel = @($script:UI.CatalogGrid.SelectedItems)
    $added = 0
    foreach ($r in $sel) { if (Add-DreddCustomApp -Context $script:Ctx -Name $r.Name -AppId $r.Id) { $added++ } }
    Add-DreddLog -Level Success -Area 'Catalog' -Message (TF 'Log.CustomAdded' @($added, $sel.Count))
    if ($script:CatalogSource -eq 'Custom') { Update-CatalogView }
}

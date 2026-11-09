# Библиотека IPA: фоновая индексация, фильтр, детали, подпись, добавление файлов с диска, установка, удаление.

$script:LibraryRows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.LibraryRow]
$script:LibraryIds = New-Object 'System.Collections.Generic.HashSet[string]'
$script:LibraryBundles = New-Object 'System.Collections.Generic.HashSet[string]'
$script:LibraryTask = $null
$script:LibraryLoaded = $false
# Внешние IPA (вне папки библиотеки), добавленные для установки без копирования. Переживают обновление библиотеки.
$script:ExternalIpas = New-Object 'System.Collections.Generic.List[string]'

function Initialize-LibraryPage {
    $u = $script:UI
    $u.LibGrid.ItemsSource = $script:LibraryRows
    # Отдельное представление для экрана устройств: фильтр библиотеки не должен на него влиять.
    $u.DevIpaGrid.ItemsSource = [System.Windows.Data.ListCollectionView]::new($script:LibraryRows)
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:LibraryRows)
    $view.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription('Date', 'Descending')))
    $u.LibSearch.Add_TextChanged({ Safe { Update-LibraryFilter } })
    $u.LibAddBtn.Add_Click({ Safe { $f = Select-DreddIpaFiles; if ($f) { Import-DreddIpaFiles $f } } })
    $u.LibRefreshBtn.Add_Click({ Safe { Start-DreddLibraryRefresh } })
    $u.LibOpenFolderBtn.Add_Click({ Safe { Open-DreddPath $script:Ctx.DownloadDir } })
    $u.LibGrid.Add_SelectionChanged({ Safe { Update-LibraryDetails } })
    $u.LibGrid.Add_MouseDoubleClick({ Safe { $r = $script:UI.LibGrid.SelectedItem; if ($r) { Open-DreddPath $r.Path -Select } } })
    $u.LibShowBtn.Add_Click({ Safe { $r = $script:UI.LibGrid.SelectedItem; if ($r) { Open-DreddPath $r.Path -Select } } })
    $u.LibDeleteBtn.Add_Click({ Safe { Remove-DreddLibraryItems } })
    $u.LibInstallBtn.Add_Click({ Safe { Invoke-DreddInstallFromLibrary } })

    # Перетаскивание .ipa в окно: на «Главной» — сразу установка на iPhone; на «Устройствах» — в список установки
    # без копирования; на остальных — в библиотеку.
    $script:Window.Add_DragOver({ param($s, $e)
        $e.Effects = if (@(Get-DreddDroppedIpas $e).Count -gt 0) { [System.Windows.DragDropEffects]::Copy } else { [System.Windows.DragDropEffects]::None }
        $e.Handled = $true
    })
    $script:Window.Add_Drop({ param($s, $e) Safe {
        $files = @(Get-DreddDroppedIpas $e)
        if ($files.Count -eq 0) { return }
        if ($script:CurrentPage -eq 'Home') { Invoke-DreddInstallFiles $files }
        elseif ($script:CurrentPage -eq 'Devices') { Add-DreddExternalIpas $files -Select }
        else { Import-DreddIpaFiles $files }
    } })
    Update-LibraryDetails
}

function Show-LibraryPage {
    if (-not $script:LibraryLoaded -and -not $script:LibraryTask) { Start-DreddLibraryRefresh }
    Update-LibraryTexts
}

function Update-LibraryTexts {
    $u = $script:UI
    $u.LibCount.Text = TF 'Library.Count' @($script:LibraryRows.Count, (Format-DreddSize (($script:LibraryRows | Measure-Object -Property SizeBytes -Sum).Sum)))
    if ($script:LibraryTask) {
        $u.LibEmptyText.Text = T 'Library.Loading'; $u.LibBusy.Visibility = 'Visible'; $u.LibEmptyPanel.Visibility = 'Visible'
    } elseif ($script:LibraryRows.Count -eq 0) {
        $u.LibEmptyText.Text = (TF 'Library.Empty' @($script:Ctx.DownloadDir)) + "`n" + (T 'Library.AddHint'); $u.LibBusy.Visibility = 'Collapsed'; $u.LibEmptyPanel.Visibility = 'Visible'
    } else { $u.LibEmptyPanel.Visibility = 'Collapsed' }
    foreach ($r in $script:LibraryRows) { $r.SignText = Format-DreddSignText $r }
    Update-LibraryDetails
}

function Format-DreddSignText {
    # Короткий текст подписи для таблицы.
    param($Row)
    if (-not $Row.SignType) { return '' }
    $t = T "Sign.Type.$($Row.SignType)"
    if ($Row.SignExpires -is [datetime]) {
        $exp = [datetime]$Row.SignExpires
        if ($exp -lt (Get-Date)) { $t += ' · ' + (T 'Sign.ExpiredShort') } else { $t += ' · ' + (TF 'Sign.Until' @($exp.ToString('d'))) }
    }
    if ($Row.IsExternal) { $t += ' · ' + (T 'Library.External') }
    return $t
}

function ConvertTo-DreddLibraryRow {
    param($m, [switch]$External)
    $r = New-Object IPADredd.Gui.LibraryRow
    $r.Name = if ($m.Error) { $m.FileName } else { [string]$m.Name }
    $r.BundleId = [string]$m.BundleId
    $r.Version = if ($m.Error) { T 'Library.ReadError' } else { [string]$m.Version }
    $r.Build = [string]$m.Build
    $r.MinIos = [string]$m.MinIOS
    $r.AppStoreId = [string]$m.AppStoreId
    $r.Artist = [string]$m.Artist
    $r.SizeBytes = [long]$m.SizeBytes
    $r.SizeText = Format-DreddSize $m.SizeBytes
    if ($m.Modified) { $r.Date = [datetime]$m.Modified; $r.DateText = ([datetime]$m.Modified).ToString('g') }
    $r.FileName = [string]$m.FileName
    $r.Path = [string]$m.Path
    $r.Error = [string]$m.Error
    $r.SignType = [string]$m.SignType
    $r.SignExpires = $m.SignExpires
    $r.SignDevices = [string[]]@($m.SignDevices | Where-Object { $_ })
    $r.IsExternal = [bool]$External
    $r.SignText = Format-DreddSignText $r
    return $r
}

function Start-DreddLibraryRefresh {
    if ($script:LibraryTask) { return }
    # TaskRunner отдаёт последний объект вывода, поэтому массив возвращается одним объектом (", $items").
    $script:LibraryTask = Start-DreddTask -Name (T 'Task.Library') -Silent -Arguments @{ Folder = $script:Ctx.DownloadDir; External = $script:ExternalIpas.ToArray() } -Script {
        $items = @(Get-DreddLibrary -Folder $A.Folder -Reporter $Reporter -CancellationToken $Token)
        $ext = @(foreach ($p in $A.External) { if ([System.IO.File]::Exists($p)) { Get-DreddIpaMetadata -Path $p } })
        , @{ Items = $items; External = $ext }
    } -OnComplete {
        param($res)
        $script:LibraryTask = $null
        $script:LibraryLoaded = $true
        $script:LibraryRows.Clear()
        $script:LibraryIds.Clear(); $script:LibraryBundles.Clear()
        foreach ($m in @($res.Items)) {
            if ($null -eq $m) { continue }
            $script:LibraryRows.Add((ConvertTo-DreddLibraryRow $m))
            if ($m.AppStoreId) { [void]$script:LibraryIds.Add([string]$m.AppStoreId) }
            if ($m.BundleId) { [void]$script:LibraryBundles.Add([string]$m.BundleId) }
        }
        foreach ($m in @($res.External)) { if ($null -ne $m) { $script:LibraryRows.Add((ConvertTo-DreddLibraryRow $m -External)) } }
        Update-LibraryFilter
        Update-LibraryTexts
        if (Get-Command Update-CatalogStatuses -ErrorAction SilentlyContinue) { Update-CatalogStatuses }
        if (Get-Command Update-DevicesButtons -ErrorAction SilentlyContinue) { Update-DevicesButtons }
        if (Get-Command Update-DreddPurchaseStatuses -ErrorAction SilentlyContinue) { Update-DreddPurchaseStatuses }
    } -OnError {
        param($m)
        $script:LibraryTask = $null
        Add-DreddLog -Level Error -Area 'Library' -Message $m
        Update-LibraryTexts
    }
    Update-LibraryTexts
}

function Update-LibraryFilter {
    $q = $script:UI.LibSearch.Text
    $view = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:UI.LibGrid.ItemsSource)
    if ([string]::IsNullOrWhiteSpace($q)) { $view.Filter = $null }
    else {
        $script:LibFilterText = $q.Trim()
        $view.Filter = [System.Predicate[object]] {
            param($o)
            $q2 = $script:LibFilterText
            return ($o.Name.IndexOf($q2, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                   ("$($o.BundleId)".IndexOf($q2, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                   ("$($o.Version)".IndexOf($q2, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                   ("$($o.FileName)".IndexOf($q2, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                   ("$($o.AppStoreId)" -eq $q2)
        }
    }
}

function Get-DreddSignDetails {
    # Подробное описание подписи для панели деталей.
    param($Row)
    if (-not $Row.SignType) { return '' }
    $lines = @(T "Sign.Type.$($Row.SignType)")
    if ($Row.SignExpires -is [datetime]) { $lines += TF 'Sign.ExpiresLine' @(([datetime]$Row.SignExpires).ToString('g')) }
    if (@($Row.SignDevices).Count -gt 0) { $lines += TF 'Sign.DevicesLine' @(@($Row.SignDevices).Count) }
    $lines += T "Sign.Hint.$($Row.SignType)"
    return ($lines -join "`n")
}

function Update-LibraryDetails {
    $u = $script:UI
    $sel = @($u.LibGrid.SelectedItems)
    $r = $u.LibGrid.SelectedItem
    $has = $null -ne $r
    $u.LibInstallBtn.IsEnabled = $has -and [bool]$script:Ctx.Binaries.IdeviceInstaller
    $u.LibShowBtn.IsEnabled = $has
    $u.LibDeleteBtn.IsEnabled = $has
    if (-not $has) {
        $u.LibDName.Text = T 'Library.SelectHint'; $u.LibDBundle.Text = ''
        foreach ($n in 'LibDVersion', 'LibDBuild', 'LibDMinIos', 'LibDAppId', 'LibDArtist', 'LibDSize', 'LibDDate', 'LibDSign', 'LibDFile') { $u[$n].Text = '' }
        return
    }
    $u.LibDName.Text = if ($sel.Count -gt 1) { TF 'Library.SelectedMany' @($sel.Count) } else { $r.Name }
    $u.LibDBundle.Text = $r.BundleId
    $u.LibDVersion.Text = $r.Version
    $u.LibDBuild.Text = $r.Build
    $u.LibDMinIos.Text = $r.MinIos
    $u.LibDAppId.Text = $r.AppStoreId
    $u.LibDArtist.Text = $r.Artist
    $u.LibDSize.Text = $r.SizeText
    $u.LibDDate.Text = $r.DateText
    $u.LibDSign.Text = Get-DreddSignDetails $r
    $file = if ($r.IsExternal) { $r.Path } else { $r.FileName }
    $u.LibDFile.Text = if ($r.HasError) { "$file`n$(T 'Library.ReadError'): $($r.Error)" } else { $file }
}

function Remove-DreddLibraryItems {
    $sel = @($script:UI.LibGrid.SelectedItems)
    if ($sel.Count -eq 0) { return }
    $own = @($sel | Where-Object { -not $_.IsExternal })
    $ext = @($sel | Where-Object { $_.IsExternal })
    # Внешние файлы только убираются из списка: исходный файл пользователя не удаляется.
    foreach ($r in $ext) { [void]$script:ExternalIpas.Remove($r.Path); [void]$script:LibraryRows.Remove($r) }
    if ($ext.Count -gt 0) { Add-DreddLog -Level Info -Area 'Library' -Message (TF 'Log.ExternalRemoved' @($ext.Count)) }
    if ($own.Count -gt 0) {
        $msg = if ($own.Count -eq 1) { TF 'Library.DeleteOne' @($own[0].FileName) } else { TF 'Library.DeleteMany' @($own.Count) }
        if (Confirm-Dredd -Title (T 'Library.DeleteTitle') -Message $msg -YesText (T 'Library.Delete') -Danger -Kind Warning) {
            foreach ($r in $own) {
                try {
                    [System.IO.File]::Delete($r.Path)
                    [void]$script:LibraryRows.Remove($r)
                    Add-DreddLog -Level Info -Area 'Library' -Message (TF 'Log.Deleted' @($r.FileName))
                } catch { Add-DreddLog -Level Error -Area 'Library' -Message "$($r.FileName): $($_.Exception.Message)" }
            }
        }
    }
    Update-LibraryTexts
}

function Invoke-DreddInstallFromLibrary {
    $sel = @($script:UI.LibGrid.SelectedItems)
    if ($sel.Count -eq 0) { return }
    Show-DreddPage 'Devices'
    $script:UI.DevIpaGrid.SelectedItems.Clear()
    foreach ($r in $sel) { [void]$script:UI.DevIpaGrid.SelectedItems.Add($r) }
    if (-not $script:DevicesScanned) { Start-DreddDeviceScan }
}

# ---------------- IPA с диска ----------------

function Select-DreddIpaFiles {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'iOS App (*.ipa)|*.ipa'
    $dlg.Multiselect = $true
    $dlg.Title = T 'Library.AddIpa'
    if ($dlg.ShowDialog()) { return @($dlg.FileNames) }
    return @()
}

function Get-DreddDroppedIpas {
    param($DragArgs)
    if (-not $DragArgs.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return @() }
    return @($DragArgs.Data.GetData([System.Windows.DataFormats]::FileDrop) | Where-Object { $_ -match '\.ipa$' -and [System.IO.File]::Exists($_) })
}

function Import-DreddIpaFiles {
    # Копирует IPA в папку библиотеки в фоне (файлы бывают большими), затем обновляет библиотеку.
    param([string[]]$Paths)
    $Paths = @($Paths | Where-Object { $_ })
    if ($Paths.Count -eq 0) { return }
    Add-DreddLog -Level Info -Area 'Library' -Message (TF 'Log.Importing' @($Paths.Count))
    [void](Start-DreddTask -Name (T 'Task.Import') -Arguments @{ Paths = $Paths; Folder = $script:Ctx.DownloadDir } -Script {
        $done = @()
        foreach ($p in $A.Paths) {
            if ($Token.IsCancellationRequested) { break }
            try {
                $dest = Import-DreddIpaToLibrary -Path $p -Folder $A.Folder
                Write-DreddReport -Reporter $Reporter -Type log -Level Success -Area 'Library' -Message ("✔ {0}" -f [System.IO.Path]::GetFileName($dest))
                $done += $dest
            } catch {
                Write-DreddReport -Reporter $Reporter -Type log -Level Error -Area 'Library' -Message ("✖ {0}: {1}" -f [System.IO.Path]::GetFileName($p), $_.Exception.Message)
            }
        }
        , $done
    } -OnComplete {
        param($done)
        Add-DreddLog -Level Info -Area 'Library' -Message (TF 'Log.Imported' @(@($done).Count))
        Start-DreddLibraryRefresh
    })
}

function Add-DreddExternalIpas {
    # Добавляет IPA с диска в список установки без копирования (метаданные читаются сразу: это быстро).
    param([string[]]$Paths, [switch]$Select)
    $added = @()
    $folder = [System.IO.Path]::GetFullPath($script:Ctx.DownloadDir).TrimEnd('\', '/')
    foreach ($p in @($Paths | Where-Object { $_ })) {
        $full = [System.IO.Path]::GetFullPath($p)
        $existing = $script:LibraryRows | Where-Object { $_.Path -eq $full } | Select-Object -First 1
        if ($existing) { $added += $existing; continue }
        $m = Get-DreddIpaMetadata -Path $full
        $isExternal = [System.IO.Path]::GetDirectoryName($full).TrimEnd('\', '/') -ne $folder
        $row = if ($isExternal) { ConvertTo-DreddLibraryRow $m -External } else { ConvertTo-DreddLibraryRow $m }
        if ($isExternal -and -not $script:ExternalIpas.Contains($full)) { $script:ExternalIpas.Add($full) }
        $script:LibraryRows.Add($row)
        $added += $row
        if ($m.Error) { Add-DreddLog -Level Error -Area 'Library' -Message ("{0}: {1}" -f $m.FileName, $m.Error) }
        else { Add-DreddLog -Level Info -Area 'Library' -Message (TF 'Log.ExternalAdded' @($m.Name, $m.Version, (T "Sign.Type.$($m.SignType)"))) }
    }
    if ($Select -and $added.Count -gt 0) {
        $script:UI.DevIpaGrid.SelectedItems.Clear()
        foreach ($r in $added) { [void]$script:UI.DevIpaGrid.SelectedItems.Add($r) }
    }
    Update-LibraryTexts
    if (Get-Command Update-DevicesButtons -ErrorAction SilentlyContinue) { Update-DevicesButtons }
}

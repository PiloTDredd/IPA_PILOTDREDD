# Загрузки: очередь (одна загрузка за раз), прогресс, отмена, история; диалог выбора версии.

$script:Queue = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.QueueItem]
$script:ActiveDownload = $null

function Initialize-DownloadsPage {
    $u = $script:UI
    $u.DlQueueGrid.ItemsSource = $script:Queue
    $u.DlChangeFolderBtn.Add_Click({ Safe { Select-DreddDownloadFolder } })
    $u.DlOpenFolderBtn.Add_Click({ Safe { Open-DreddPath $script:Ctx.DownloadDir } })
    $u.DlCancelBtn.Add_Click({ Safe { foreach ($q in @($script:UI.DlQueueGrid.SelectedItems)) { Stop-DreddDownloadItem $q } } })
    $u.DlCancelAllBtn.Add_Click({ Safe {
        if (@($script:Queue | Where-Object { $_.Status -in 'Queued', 'Running' }).Count -eq 0) { return }
        if (Confirm-Dredd -Title (T 'Downloads.CancelAllTitle') -Message (T 'Downloads.CancelAllText') -YesText (T 'Downloads.CancelAll') -Danger) {
            foreach ($q in @($script:Queue)) { Stop-DreddDownloadItem $q }
        }
    } })
    $u.DlRetryBtn.Add_Click({ Safe {
        foreach ($q in @($script:UI.DlQueueGrid.SelectedItems)) {
            if ($q.Status -eq 'InstallError' -and $q.FilePath) { $q.Error = ''; Add-DreddAutoInstall -Path $q.FilePath -Name $q.AppName -Udid $q.InstallUdid -DeviceName $q.InstallDevice -QueueItem $q; continue }
            if ($q.Status -in 'Error', 'Cancelled') { Set-DreddQueueStatus $q 'Queued'; $q.Error = ''; $q.Progress = 0 }
        }
        Start-DreddNextDownload
    } })
    $u.DlClearBtn.Add_Click({ Safe {
        foreach ($q in @($script:Queue | Where-Object { $_.Status -in 'Done', 'Error', 'Cancelled', 'Installed', 'InstallError' })) { [void]$script:Queue.Remove($q) }
        Update-DownloadsTexts
    } })
    $u.DlShowFileBtn.Add_Click({ Safe { $q = $script:UI.DlQueueGrid.SelectedItem; if ($q -and $q.FilePath) { Open-DreddPath $q.FilePath -Select } } })
    $u.DlQueueGrid.Add_SelectionChanged({ Safe { Update-DownloadsButtons } })
    $u.DlQueueGrid.Add_MouseDoubleClick({ Safe { $q = $script:UI.DlQueueGrid.SelectedItem; if ($q -and $q.FilePath) { Open-DreddPath $q.FilePath -Select } } })
    $u.DlAutoPurchase.Add_Click({ Safe { Set-DreddAutoPurchase ([bool]$script:UI.DlAutoPurchase.IsChecked) } })
    $u.DlHistoryRemoveBtn.Add_Click({ Safe { Remove-DreddHistoryRows } })
    $u.DlHistoryClearBtn.Add_Click({ Safe { Remove-DreddHistoryRows -All } })
    $u.DlHistoryGrid.Add_SelectionChanged({ Safe { Update-DownloadsHistoryButtons } })
    $u.DlHistoryGrid.Add_PreviewKeyDown({ param($s, $e) Safe { if ($e.Key -eq 'Delete') { Remove-DreddHistoryRows; $e.Handled = $true } } })
}

function Show-DownloadsPage { Update-DownloadsTexts; Update-DownloadsHistory }

function Update-DownloadsTexts {
    $u = $script:UI
    $u.DlFolder.Text = $script:Ctx.DownloadDir
    $u.DlAutoPurchase.IsChecked = ConvertTo-DreddBool $script:Ctx.Settings['AutoPurchase']
    foreach ($q in $script:Queue) {
        $q.StatusText = T "Status.$($q.Status)"
        # «последняя» показывается, пока версия неизвестна; после загрузки — фактическая версия из IPA.
        if (-not $q.VersionId -and -not $q.FilePath) { $q.VersionText = T 'Downloads.Latest' }
    }
    $u.DlQueueEmpty.Visibility = if ($script:Queue.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-DownloadsButtons
}

function Update-DownloadsButtons {
    $u = $script:UI
    $sel = @($u.DlQueueGrid.SelectedItems)
    $u.DlCancelBtn.IsEnabled = @($sel | Where-Object { $_.Status -in 'Queued', 'Running' }).Count -gt 0
    $u.DlRetryBtn.IsEnabled = @($sel | Where-Object { $_.Status -in 'Error', 'Cancelled', 'InstallError' }).Count -gt 0
    $u.DlShowFileBtn.IsEnabled = @($sel | Where-Object { $_.FilePath }).Count -gt 0
    $u.DlCancelAllBtn.IsEnabled = @($script:Queue | Where-Object { $_.Status -in 'Queued', 'Running' }).Count -gt 0
    $u.DlClearBtn.IsEnabled = @($script:Queue | Where-Object { $_.Status -in 'Done', 'Error', 'Cancelled', 'Installed', 'InstallError' }).Count -gt 0
}

function Update-DownloadsHistory {
    $rows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.SimpleRow]
    foreach ($h in @(Get-DreddDownloadHistory -Context $script:Ctx -Last 50)) {
        $r = New-Object IPADredd.Gui.SimpleRow
        $kind = [string](Get-DreddProp $h 'Kind' 'Download')
        $r.C6 = T "Kind.$kind"
        $r.Key = Get-DreddHistoryKey $h
        $r.Detail = [string](Get-DreddProp $h 'Message' '')
        if ($kind -eq 'Install') { $r.C4 = [string](Get-DreddProp $h 'Target' '') }
        $r.C1 = [string](Get-DreddProp $h 'Date'); $r.C2 = [string](Get-DreddProp $h 'Name'); $r.C3 = [string](Get-DreddProp $h 'Version')
        if (-not $r.C4) { $r.C4 = [string](Get-DreddProp $h 'File') }
        $res = [string](Get-DreddProp $h 'Result' 'Success'); $r.Status = $res; $r.C5 = T "Result.$res"
        $rows.Add($r)
    }
    $script:UI.DlHistoryGrid.ItemsSource = $rows
    $script:UI.DlHistoryClearBtn.IsEnabled = $rows.Count -gt 0
    Update-DownloadsHistoryButtons
}

function Update-DownloadsHistoryButtons {
    $script:UI.DlHistoryRemoveBtn.IsEnabled = $script:UI.DlHistoryGrid.SelectedItems.Count -gt 0
}

function Remove-DreddHistoryRows {
    # Выбранные записи — без подтверждения (это только журнал операций); вся история — с подтверждением.
    param([switch]$All)
    if ($All) {
        if (-not (Confirm-Dredd -Title (T 'Downloads.HistoryClearTitle') -Message (T 'Downloads.HistoryClearText') -YesText (T 'Downloads.HistoryClear') -Danger -Kind Warning)) { return }
        [void](Remove-DreddHistoryEntries -Context $script:Ctx -All)
        Add-DreddLog -Level Info -Area 'Download' -Message (T 'Log.HistoryCleared')
    } else {
        $keys = @($script:UI.DlHistoryGrid.SelectedItems | ForEach-Object { $_.Key })
        if ($keys.Count -eq 0) { return }
        $n = Remove-DreddHistoryEntries -Context $script:Ctx -Keys $keys
        Add-DreddLog -Level Info -Area 'Download' -Message (TF 'Log.HistoryRemoved' @($n))
    }
    Update-DownloadsHistory
}

function Set-DreddQueueStatus {
    param($Item, [string]$Status)
    $Item.Status = $Status
    $Item.StatusText = T "Status.$Status"
    $Item.ShowProgress = ($Status -eq 'Running')
    if (Get-Command Update-DreddPurchaseFromQueue -ErrorAction SilentlyContinue) { Update-DreddPurchaseFromQueue $Item }
    Save-DreddQueueState
}

# ---------------- Очередь между запусками ----------------
# Files/Queue.json хранит «В очереди» и «Загрузка» (начатая загрузка после перезапуска начнётся заново: ipatool не докачивает).
# Отложенные записи прошлого запуска ($script:QueueDeferred) сохраняются, пока пользователь их не продолжит.

$script:QueueDeferred = @()
$script:QueueRestoreAsked = @{}

function Save-DreddQueueState {
    if ($script:SelfTestMode -or $script:Closing) { return }
    $live = @($script:Queue | Where-Object { $_.Status -in 'Queued', 'Running' })
    $keys = @{}; foreach ($q in $live) { $keys["$($q.AppId)|$($q.VersionId)"] = $true }
    $deferred = @($script:QueueDeferred | Where-Object { -not $keys.ContainsKey("$($_.AppId)|$($_.VersionId)") })
    try { Save-DreddQueue -Context $script:Ctx -Items (@($live) + @($deferred)) } catch { Add-DreddLog -Level Warning -Area 'Download' -Message $_.Exception.Message }
}

function Invoke-DreddQueueRestore {
    # Один раз для аккаунта за запуск: «Незавершённые загрузки: N — Продолжить?»
    if ($script:SelfTestMode -or -not ($script:Account -and $script:Account.Success)) { return }
    $key = Get-DreddAccountKey $script:Account.Email
    if ($script:QueueRestoreAsked.ContainsKey($key)) { return }
    $script:QueueRestoreAsked[$key] = $true
    $items = @(Read-DreddQueue -Context $script:Ctx -AccountKey $key | Where-Object {
        $i = $_; @($script:Queue | Where-Object { $_.AppId -eq $i.AppId -and $_.VersionId -eq $i.VersionId -and $_.Status -in 'Queued', 'Running' }).Count -eq 0 })
    $script:QueueDeferred = @(Read-DreddQueue -Context $script:Ctx)
    if ($items.Count -eq 0) { return }
    $script:QueueRestoreItems = $items
    $names = (@($items | Select-Object -First 3 | ForEach-Object { $_.AppName }) -join ', ') + $(if ($items.Count -gt 3) { " +$($items.Count - 3)" } else { '' })
    Show-DreddToast -Kind Info -Title (TF 'Queue.RestoreTitle' @($items.Count)) -Text $names -ActionText (T 'Queue.Resume') -Action { Resume-DreddSavedQueue }
}

function Resume-DreddSavedQueue {
    $items = @($script:QueueRestoreItems)
    $ids = @{}; foreach ($i in $items) { $ids["$($i.AppId)|$($i.VersionId)"] = $true }
    $script:QueueDeferred = @($script:QueueDeferred | Where-Object { -not $ids.ContainsKey("$($_.AppId)|$($_.VersionId)") })
    foreach ($i in $items) {
        Add-DreddDownloadItem -AppId $i.AppId -AppName $i.AppName -VersionId $i.VersionId -VersionText $i.VersionText -Purchase $i.Purchase -InstallUdid $i.InstallUdid -InstallDevice $i.InstallDevice
    }
    Add-DreddLog -Level Info -Area 'Download' -Message (TF 'Log.Queued' @($items.Count))
}

function Add-DreddDownloadItem {
    # -InstallUdid: после загрузки установить на это устройство (Add-DreddAutoInstall, Devices.ps1).
    param([string]$AppId, [string]$AppName, [string]$VersionId, [string]$VersionText, [bool]$Purchase, [string]$InstallUdid, [string]$InstallDevice)
    # Повторная постановка того же (ID + версия), пока он в очереди, не нужна — но можно добавить установку.
    $dup = @($script:Queue | Where-Object { $_.AppId -eq $AppId -and $_.VersionId -eq $VersionId -and $_.Status -in 'Queued', 'Running' })
    if ($dup.Count -gt 0) {
        if ($InstallUdid) { $dup[0].InstallUdid = $InstallUdid; $dup[0].InstallDevice = $InstallDevice; Save-DreddQueueState }
        return
    }
    $q = New-Object IPADredd.Gui.QueueItem
    $q.Id = [guid]::NewGuid().ToString('N')
    $q.AppId = $AppId; $q.AppName = $AppName; $q.VersionId = $VersionId; $q.Purchase = $Purchase
    $q.InstallUdid = $InstallUdid; $q.InstallDevice = $InstallDevice
    if ($script:Account -and $script:Account.Success) { $q.AccountKey = Get-DreddAccountKey $script:Account.Email }
    $q.VersionText = if ($VersionText) { $VersionText } elseif ($VersionId) { $VersionId } else { T 'Downloads.Latest' }
    Set-DreddQueueStatus $q 'Queued'
    $script:Queue.Add($q)
    Update-DownloadsTexts
    Start-DreddNextDownload
}

function Stop-DreddDownloadItem {
    param($Item)
    if ($Item.Status -eq 'Queued') { Set-DreddQueueStatus $Item 'Cancelled' }
    elseif ($Item.Status -eq 'Running' -and $Item.TaskId) { Stop-DreddTask $Item.TaskId; $Item.StatusText = T 'Status.Cancelling' }
    Update-DownloadsButtons
}

function Start-DreddNextDownload {
    if ($script:ActiveDownload) { return }
    $next = $script:Queue | Where-Object { $_.Status -eq 'Queued' } | Select-Object -First 1
    if (-not $next) { Update-DownloadsButtons; return }
    $script:ActiveDownload = $next
    Set-DreddQueueStatus $next 'Running'
    $next.IsIndeterminate = $true
    $next.Progress = 0
    $next.ProgressText = T 'Downloads.Starting'
    $account = if ($script:Account -and $script:Account.Success) { $script:Account.Email } else { $null }
    $task = Start-DreddTask -Name (TF 'Task.Download' @($next.AppName)) -Arguments @{
        AppId = $next.AppId; AppName = $next.AppName; VersionId = $next.VersionId; VersionLabel = $(if ($next.VersionId) { $next.VersionText } else { $null })
        Purchase = $next.Purchase; Account = $account; Dest = $script:Ctx.DownloadDir
    } -Script {
        $r = Invoke-DreddDownload -Context $Context -AppId $A.AppId -AppName $A.AppName -VersionId $A.VersionId -VersionLabel $A.VersionLabel `
            -Purchase:([bool]$A.Purchase) -Account $A.Account -DestinationFolder $A.Dest -Reporter $Reporter -CancellationToken $Token
        # Результат реальной попытки — в библиотеку покупок аккаунта (если приложение там есть).
        if ($A.Account -and -not $r.Cancelled) {
            try { [void](Set-DreddPurchaseAttempt -Context $Context -Email $A.Account -AppId $A.AppId -ErrorKey $(if ($r.Ok) { '' } else { $r.Error.Key }) -Message $(if ($r.Ok) { '' } else { $r.Error.Message })) } catch { }
        }
        $r
    } -OnMessage {
        param($item)
        $q = $script:ActiveDownload
        if (-not $q -or $item.Type -ne 'progress' -or $null -eq $item.Value) { return }
        $v = $item.Value
        $pct = $v['Percent']; $bytes = $v['Bytes']
        if ($null -ne $pct) {
            $q.IsIndeterminate = $false
            $q.Progress = [double]$pct
            $q.ProgressText = if ($bytes) { '{0:N0}% · {1}' -f $pct, (Format-DreddSize $bytes) } else { '{0:N0}%' -f $pct }
        } elseif ($bytes) {
            $q.IsIndeterminate = $true
            $q.ProgressText = TF 'Downloads.Received' @((Format-DreddSize $bytes))
        }
        if (Get-Command Update-DreddPurchaseFromQueue -ErrorAction SilentlyContinue) { Update-DreddPurchaseFromQueue $q }
    } -OnComplete {
        param($r)
        $q = $script:ActiveDownload
        $script:ActiveDownload = $null
        if ($q) {
            $q.IsIndeterminate = $false
            if ($r.Ok) {
                Set-DreddQueueStatus $q 'Done'
                $q.Progress = 100
                $q.FilePath = $r.Path
                $q.FileName = [System.IO.Path]::GetFileName($r.Path)
                if ($r.Metadata -and $r.Metadata.Version) { $q.VersionText = $r.Metadata.Version }
                if ($q.InstallUdid) { Add-DreddAutoInstall -Path $r.Path -Name $q.AppName -Udid $q.InstallUdid -DeviceName $q.InstallDevice -QueueItem $q }
            } elseif ($r.Cancelled) {
                Set-DreddQueueStatus $q 'Cancelled'
                Add-DreddHistoryEntry -Context $script:Ctx -Kind Download -AppId $q.AppId -Name $q.AppName -Result Cancelled
            } else {
                $q.ErrorKey = $r.Error.Key; $q.ErrorMessage = $r.Error.Message
                Set-DreddQueueStatus $q 'Error'
                $q.Error = Get-DreddErrorText $r.Error.Key $r.Error.Message
                $q.StatusText = T "Status.Error"
                Add-DreddHistoryEntry -Context $script:Ctx -Kind Download -AppId $q.AppId -Name $q.AppName -Result Error -Message $r.Error.Message
                Add-DreddLog -Level Error -Area 'Download' -Message ("{0}: {1}" -f $q.AppName, $q.Error)
            }
        }
        Update-DownloadsHistory
        if ($r.Ok) { Start-DreddLibraryRefresh }
        Start-DreddNextDownload
        Update-DownloadsTexts
    } -OnError {
        param($m)
        $q = $script:ActiveDownload
        $script:ActiveDownload = $null
        if ($q) { Set-DreddQueueStatus $q 'Error'; $q.Error = $m }
        Add-DreddLog -Level Error -Area 'Download' -Message $m
        Start-DreddNextDownload
        Update-DownloadsTexts
    }
    $next.TaskId = $task.Id
    Update-DownloadsButtons
}

# ---------------- Диалог выбора версии ----------------

function Show-DreddVersionsDialog {
    # -NoPurchase: приложение из истории покупок — лицензия уже есть, флажок «Получать лицензию» выключен.
    param([string]$AppId, [string]$AppName, [switch]$NoPurchase)
    $ui = @{}
    $dlg = New-DreddWindow -Path (Join-Path $script:GuiRoot 'VersionsDialog.xaml') -Into $ui
    $script:VerUI = $ui
    $script:VerDialog = $dlg
    $script:VerAppId = $AppId
    $script:VerAppName = $AppName
    $script:VerRows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.VersionRow]
    $script:VerTask = $null
    $script:VerLoaded = 0
    $dlg.Title = T 'Versions.Title'
    if ($script:Window.IsVisible) { $dlg.Owner = $script:Window }
    # Локализация элементов диалога:
    $saved = $script:LocEntries; $script:LocEntries = New-Object System.Collections.Generic.List[object]
    Register-DreddLocalization $dlg; Set-DreddLanguage $script:Ctx.Settings['Language']
    $script:LocEntries = $saved

    $ui.VerTitle.Text = $AppName
    $ui.VerSubtitle.Text = TF 'Versions.Subtitle' @($AppId)
    $ui.VerGrid.ItemsSource = $script:VerRows
    $ui.VerAutoPurchase.IsChecked = (ConvertTo-DreddBool $script:Ctx.Settings['AutoPurchase']) -and -not $NoPurchase
    $ui.VerMoreBtn.IsEnabled = $false
    $ui.VerDownloadBtn.IsEnabled = $false
    $ui.VerGrid.Add_SelectionChanged({ Safe { $script:VerUI.VerDownloadBtn.IsEnabled = $script:VerUI.VerGrid.SelectedItems.Count -gt 0 } })
    $ui.VerMoreBtn.Add_Click({ Safe { Start-DreddVersionMetadataBatch } })
    $ui.VerCancelBtn.Add_Click({ Safe { $script:VerDialog.Close() } })
    $ui.VerDownloadBtn.Add_Click({ Safe {
        $purchase = [bool]$script:VerUI.VerAutoPurchase.IsChecked
        $sel = @($script:VerUI.VerGrid.SelectedItems | Sort-Object Index)
        foreach ($v in $sel) {
            $label = if ($v.Loaded -and $v.DisplayVersion -and $v.DisplayVersion -ne '…') { $v.DisplayVersion } else { $v.VersionId }
            Add-DreddDownloadItem -AppId $script:VerAppId -AppName $script:VerAppName -VersionId $v.VersionId -VersionText $label -Purchase $purchase
        }
        Add-DreddLog -Level Info -Area 'Download' -Message (TF 'Log.Queued' @($sel.Count))
        $script:VerDialog.Close()
        Show-DreddPage 'Downloads'
    } })
    $dlg.Add_Closed({ if ($script:VerTask) { Stop-DreddTask $script:VerTask.Id } })

    $purchaseList = (ConvertTo-DreddBool $script:Ctx.Settings['AutoPurchase']) -and -not $NoPurchase
    $ui.VerBusy.Visibility = 'Visible'
    $ui.VerStatus.Text = T 'Versions.Loading'
    $script:VerTask = Start-DreddTask -Name (T 'Task.Versions') -Arguments @{ AppId = $AppId; Purchase = $purchaseList } -Script {
        Get-DreddAppVersions -Context $Context -AppId $A.AppId -Purchase:([bool]$A.Purchase) -Reporter $Reporter -CancellationToken $Token
    } -OnComplete {
        param($r)
        $script:VerTask = $null
        if (-not $script:VerDialog.IsVisible) { return }
        $script:VerUI.VerBusy.Visibility = 'Collapsed'
        if (-not $r.Ok) {
            $script:VerUI.VerStatus.Text = Get-DreddErrorText $r.Error.Key $r.Error.Message
            return
        }
        $i = 0
        foreach ($id in $r.VersionIds) {
            $i++
            $row = New-Object IPADredd.Gui.VersionRow
            $row.Index = $i; $row.VersionId = $id
            $script:VerRows.Add($row)
        }
        $script:VerUI.VerStatus.Text = TF 'Versions.Count' @($r.VersionIds.Count)
        Start-DreddVersionMetadataBatch
    } -OnError {
        param($m)
        $script:VerTask = $null
        $script:VerUI.VerBusy.Visibility = 'Collapsed'
        $script:VerUI.VerStatus.Text = $m
    }
    [void]$dlg.ShowDialog()
}

function Start-DreddVersionMetadataBatch {
    # Номера версий догружаются пачками по 15 (каждая — отдельный запрос к App Store).
    if ($script:VerTask) { return }
    $batch = @($script:VerRows | Where-Object { -not $_.Loaded } | Select-Object -First 15)
    if ($batch.Count -eq 0) { $script:VerUI.VerMoreBtn.IsEnabled = $false; return }
    $script:VerUI.VerMoreBtn.IsEnabled = $false
    $script:VerUI.VerBusy.Visibility = 'Visible'
    $ids = @($batch | ForEach-Object { $_.VersionId })
    $script:VerTask = Start-DreddTask -Name (T 'Task.VersionMeta') -Silent -Arguments @{ AppId = $script:VerAppId; Ids = $ids } -Script {
        foreach ($id in $A.Ids) {
            if ($Token.IsCancellationRequested) { break }
            $m = Get-DreddVersionMetadata -Context $Context -AppId $A.AppId -VersionId $id -Reporter $Reporter -CancellationToken $Token
            Write-DreddReport -Reporter $Reporter -Type data -Area 'Versions' -Value @{ Id = $id; Version = $m.DisplayVersion; Date = $m.ReleaseDate; Ok = $m.Ok }
        }
        $true
    } -OnMessage {
        param($item)
        if ($item.Type -ne 'data' -or -not $script:VerRows) { return }
        $v = $item.Value
        foreach ($row in $script:VerRows) {
            if ($row.VersionId -eq $v.Id) {
                $row.Loaded = $true
                $row.DisplayVersion = if ($v.Version) { $v.Version } else { '—' }
                $row.ReleaseDate = [string]$v.Date
                break
            }
        }
    } -OnComplete {
        $script:VerTask = $null
        if (-not $script:VerDialog.IsVisible) { return }
        $script:VerUI.VerBusy.Visibility = 'Collapsed'
        $left = @($script:VerRows | Where-Object { -not $_.Loaded }).Count
        $script:VerUI.VerMoreBtn.IsEnabled = $left -gt 0
        $script:VerUI.VerStatus.Text = TF 'Versions.Loaded' @(($script:VerRows.Count - $left), $script:VerRows.Count)
    }
}

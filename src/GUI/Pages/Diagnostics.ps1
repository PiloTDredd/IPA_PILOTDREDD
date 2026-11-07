# Диагностика: проверки окружения, отчёт без личных данных, журналы, обновление списков, проверка версий.

function Initialize-DiagnosticsPage {
    $u = $script:UI
    $u.DiagRefreshBtn.Add_Click({ Safe { Update-DreddContextPaths -Context $script:Ctx; Update-DiagnosticsPage; Update-DreddShell; Add-DreddLog -Level Info -Area 'Diag' -Message (T 'Log.DiagRefreshed') } })
    $u.DiagExportBtn.Add_Click({ Safe { Export-DreddDiagnosticsUi } })
    $u.DiagOpenLogsBtn.Add_Click({ Safe { Open-DreddPath $script:Ctx.LogsDir } })
    $u.DiagUpdateListsBtn.Add_Click({ Safe { Start-DreddListsUpdate } })
    $u.DiagCheckUpdatesBtn.Add_Click({ Safe { Start-DreddUpdateCheck } })
    $u.DiagRepoLink.Add_Click({ Safe { Open-DreddUrl 'https://github.com/PiloTDredd/IPA_PILOTDREDD' } })
    # Чаевые автору PILOTDREDD: адрес — настройка TipJarUrl (по умолчанию CloudTips); без https-адреса кнопка скрыта.
    $u.DiagTipLink.Add_Click({ Safe { Open-DreddUrl ([string]$script:Ctx.Settings['TipJarUrl']) } })
    $u.DiagTipLink.Visibility = if ([string]$script:Ctx.Settings['TipJarUrl'] -match '^https://') { 'Visible' } else { 'Collapsed' }
}

function Show-DiagnosticsPage { Update-DiagnosticsPage }

function Update-DiagnosticsPage {
    $u = $script:UI
    $rows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.SimpleRow]
    foreach ($c in (Get-DreddDiagnostics -Context $script:Ctx)) {
        $r = New-Object IPADredd.Gui.SimpleRow
        $r.Key = $c.Id
        $r.C1 = T "Diag.Check.$($c.Id)"
        $r.Status = $c.Status
        $r.C2 = T "Diag.Status.$($c.Status)"
        $r.C3 = Protect-LogText ([string]$c.Detail)
        $r.C4 = if ($c.Status -ne 'OK') { T $c.HintKey } else { '' }
        $rows.Add($r)
    }
    $u.DiagGrid.ItemsSource = $rows
    $p = $script:Ctx.Platform
    $u.DiagSystem.Text = @(
        "IPA PILOTDREDD $($script:Ctx.Version)"
        "ipatool:    $(if ($v = Get-DreddToolVersion $script:Ctx) { "ipatool-cpp из релиза IPA Downloader $v (upstream)" } else { '?' })"
        "OS:         $($p.OSDescription) ($($p.Arch))"
        "PowerShell: $($p.PSVersion) $($p.PSEdition)"
        "Runtime:    $($p.Runtime)"
        "App:        $($script:Ctx.AppRoot)"
        "Logs:       $($script:Ctx.LogsDir)"
    ) -join "`n"
}

function Export-DreddDiagnosticsUi {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.FileName = 'IPA_Dredd_diagnostics_{0:yyyyMMdd_HHmm}.txt' -f (Get-Date)
    $dlg.Filter = 'Text (*.txt)|*.txt'
    $dlg.InitialDirectory = $script:Ctx.AppRoot
    if ($dlg.ShowDialog()) {
        [void](Export-DreddDiagnosticReport -Context $script:Ctx -Path $dlg.FileName)
        Add-DreddLog -Level Success -Area 'Diag' -Message (TF 'Log.ReportSaved' @($dlg.FileName))
        Open-DreddPath $dlg.FileName -Select
    }
}

function Start-DreddListsUpdate {
    param([switch]$Silent)
    [void](Start-DreddTask -Name (T 'Task.UpdateLists') -Silent:$Silent -Script {
        Update-DreddRemoteLists -Context $Context -Reporter $Reporter
    } -OnComplete {
        param($r, $t)
        if ($r.AppsListUpdated) { Add-DreddLog -Level Success -Area 'Lists' -Message (TF 'Log.ListsUpdated' @($r.Count)) }
        elseif (-not $t.Silent) { Add-DreddLog -Level Warning -Area 'Lists' -Message (T 'Log.ListsNotUpdated') }
        if (Get-Command Update-CatalogView -ErrorAction SilentlyContinue) { Update-CatalogView }
        Update-DreddShell
    })
}

# ---------------- Проверка и установка обновлений ipatool ----------------

$script:UpdateTask = $null

function Start-DreddUpdateCheck {
    # Тихая проверка (при запуске или по кнопке): итог — одно уведомление «всё готово» или «есть обновление».
    # -InstallNow: сразу установить, если есть что (кнопка «Загрузить компоненты» на пустом экране).
    param([switch]$Startup, [switch]$InstallNow)
    if ($script:UpdateTask) { return }
    $script:UpdateCheckStartup = [bool]$Startup
    $script:UpdateInstallNow = [bool]$InstallNow
    if (-not $Startup) { Show-DreddToast -Kind Info -Title (T 'Update.Checking') -Progress }
    $script:UpdateTask = Start-DreddTask -Name (T 'Task.CheckUpdates') -Silent:$Startup -Script {
        $r = Test-DreddToolUpdate -Context $Context
        # Новая версия самой программы (свои релизы на GitHub) — в том же запросе, одно уведомление.
        $app = $null
        try { $app = Test-DreddAppUpdate -Context $Context } catch { }
        $r | Add-Member -NotePropertyName AppUpdate -NotePropertyValue $app -Force
        $r
    } -OnComplete {
        param($r)
        $script:UpdateTask = $null
        $script:LastUpdateCheck = $r
        $app = $r.AppUpdate
        if ($app -and $app.Ok) { Add-DreddLog -Level Info -Area 'Update' -Message (TF 'Log.AppVersion' @($app.Current, $app.Latest)) }
        elseif ($app -and $app.Error) { Add-DreddLog -Level Warning -Area 'Update' -Message (TF 'Err.UpdateCheck' @($app.Error)) }
        if ($app -and $app.IsNewer -and -not $script:UpdateInstallNow -and -not ($r.IsNewer -and $r.NeedsSetup)) {
            # Новая IPA PILOTDREDD важнее остального: исправления, которые иначе до пользователя не дойдут.
            $script:LastAppUpdate = $app
            $text = TF 'AppUpdate.Text' @($app.Current)
            if ($app.Notes) { $text += "`n`n" + ((@($app.Notes -split "`n") | Select-Object -First 6) -join "`n") }
            if ($r.Ok -and $r.IsNewer -and $r.CanInstall) { $text += "`n`n" + (T 'AppUpdate.ToolToo') }
            Show-DreddToast -Kind Info -Title (TF 'AppUpdate.Title' @($app.Latest)) -Text $text -ActionText (T 'AppUpdate.Open') -Action { Open-DreddUrl $script:LastAppUpdate.Url }
        } elseif (-not $r.Ok) {
            Add-DreddLog -Level Warning -Area 'Update' -Message (TF 'Err.UpdateCheck' @($r.Error))
            Show-DreddToast -Kind Warning -Title (T 'Update.CheckFailed') -Text (T 'Update.CheckFailedText') -AutoHideMs 7000 -Low
        } elseif ($r.IsNewer -and $r.CanInstall -and $script:UpdateInstallNow) {
            Start-DreddToolUpdate
        } elseif ($r.IsNewer -and $r.CanInstall -and $r.NeedsSetup) {
            $size = if ($r.Release.Asset.Size -gt 0) { Format-DreddSize $r.Release.Asset.Size } else { '?' }
            Show-DreddToast -Kind Info -Title (T 'Setup.Title') -Text (TF 'Setup.Text' @($size)) -ActionText (T 'Setup.Install') -Action { Start-DreddToolUpdate }
        } elseif ($r.IsNewer -and $r.CanInstall) {
            $size = if ($r.Release.Asset.Size -gt 0) { Format-DreddSize $r.Release.Asset.Size } else { '?' }
            $cur = if ($r.Current) { $r.Current } else { T 'Update.Unknown' }
            Show-DreddToast -Kind Info -Title (TF 'Update.Available' @($r.Latest)) -Text (TF 'Update.AvailableText' @($cur, $size)) `
                -ActionText (T 'Update.Install') -Action { Start-DreddToolUpdate }
        } elseif ($r.IsNewer) {
            Show-DreddToast -Kind Warning -Title (TF 'Update.Available' @($r.Latest)) -Text (T "Update.Reason.$($r.Reason)") `
                -ActionText (T 'Update.OpenPage') -Action { Open-DreddUrl $script:LastUpdateCheck.Release.Url }
        } else {
            Show-DreddToast -Kind Success -Title (T 'Update.AllGood') -Text (Get-DreddReadyText $r) -AutoHideMs 6000 -Low:$script:UpdateCheckStartup
        }
        if (Get-Command Update-DiagnosticsPage -ErrorAction SilentlyContinue) { if ($script:CurrentPage -eq 'Diagnostics') { Update-DiagnosticsPage } }
    } -OnError {
        param($m)
        $script:UpdateTask = $null
        Add-DreddLog -Level Warning -Area 'Update' -Message (TF 'Err.UpdateCheck' @($m))
        if (-not $script:UpdateCheckStartup) { Show-DreddToast -Kind Warning -Title (T 'Update.CheckFailed') -Text $m -AutoHideMs 7000 }
    }
}

function Get-DreddReadyText {
    # «ipatool — актуальная версия · Apple ID: …» — короткая сводка готовности к работе (без номеров чужих версий).
    param($Check)
    $parts = @(TF 'Update.ToolLatest' @($Check.Current))
    if ($script:Account -and $script:Account.Success) { $parts += TF 'Update.AccountOk' @($script:Account.Email) }
    else { $parts += T 'Update.AccountNone' }
    if (-not $script:Ctx.Binaries.IdeviceInstaller) { $parts += T 'Update.NoDeviceTools' }
    return ($parts -join "`n")
}

function Start-DreddToolUpdate {
    $r = $script:LastUpdateCheck
    if (-not $r -or -not $r.CanInstall -or $script:UpdateTask) { return }
    # Пока ipatool работает (загрузка, сканирование), заменить его файл нельзя.
    if ($script:ActiveDownload -or $script:PurchaseScanTask -or $script:CatalogTask) {
        Show-DreddToast -Kind Warning -Title (T 'Update.Busy') -Text (T 'Update.BusyText') -ActionText (T 'Update.Install') -Action { Start-DreddToolUpdate }
        return
    }
    $script:UpdateIsSetup = [bool]$r.NeedsSetup
    Show-DreddToast -Kind Info -Title $(if ($r.NeedsSetup) { T 'Setup.Installing' } else { T 'Update.Installing' }) -Text (T 'Update.Step.download') -Progress
    $script:UpdateTask = Start-DreddTask -Name (T 'Task.ToolUpdate') -Arguments @{ Release = $r.Release } -Script {
        Install-DreddToolUpdate -Context $Context -Release $A.Release -Reporter $Reporter -CancellationToken $Token
    } -OnMessage {
        param($item)
        if ($item.Type -eq 'progress' -and $item.Value) {
            Set-DreddToastProgress -Percent $item.Value.Percent -Text (TF 'Update.Downloaded' @((Format-DreddSize $item.Value.Bytes)))
        } elseif ($item.Type -eq 'status') {
            Set-DreddToastProgress -Percent $null -Text (T "Update.Step.$($item.Message)")
        }
    } -OnComplete {
        param($res)
        $script:UpdateTask = $null
        if ($res.Ok) {
            Update-DreddContextPaths -Context $script:Ctx
            $script:LastUpdateCheck = $null
            if ($script:UpdateIsSetup) {
                # Первая установка компонентов: теперь можно проверить вход и поискать iPhone.
                Show-DreddToast -Kind Success -Title (T 'Setup.Done') -Text (T 'Setup.DoneText') -AutoHideMs 8000
                Start-DreddAccountRefresh
                if ($script:Ctx.Binaries.IdeviceId) { Start-DreddDeviceScan }
                Update-PurchasesView
                if (Get-Command Update-DevicesTexts -ErrorAction SilentlyContinue) { Update-DevicesTexts }
            } else {
                Show-DreddToast -Kind Success -Title (TF 'Update.Done' @($res.Version)) -Text (T 'Update.DoneText') -AutoHideMs 8000
            }
        } elseif ($res.ErrorKey -ne 'Err.Cancelled') {
            Show-DreddToast -Kind Error -Title (T 'Update.Failed') -Text (Get-DreddErrorText $res.ErrorKey $res.Message)
        } else { Hide-DreddToast }
        if ($script:CurrentPage -eq 'Diagnostics') { Update-DiagnosticsPage }
    } -OnError {
        param($m)
        $script:UpdateTask = $null
        Show-DreddToast -Kind Error -Title (T 'Update.Failed') -Text $m
    }
}

# Оболочка окна: состояние аккаунта (боковая панель), сообщение автора списков, журнал, горячие клавиши.

$script:Account = $null      # результат Get-DreddAuthInfo
$script:Devices = @()        # результаты Get-DreddDevices
$script:DevicesScanned = $false
$script:WarningDismissed = $false

function Initialize-ShellPage {
    $u = $script:UI
    $u.SideAccountBtn.Add_Click({ Safe { Show-DreddPage 'Accounts' } })
    $u.WarningClose.Add_Click({ Safe { $script:WarningDismissed = $true; $script:UI.WarningBanner.Visibility = 'Collapsed' } })

    # Журнал свёрнут по умолчанию; состояние запоминается.
    $u.LogToggle.IsChecked = ConvertTo-DreddBool $script:Ctx.Settings['LogExpanded']
    $u.LogToggle.Add_Click({ Safe {
        Set-DreddSetting -Path $script:Ctx.SettingsPath -Key 'LogExpanded' -Value ([string][bool]$script:UI.LogToggle.IsChecked) -Settings $script:Ctx.Settings
        if ($script:UI.LogToggle.IsChecked) { $script:UI.LogBox.ScrollToEnd() }
    } })

    $script:Window.Add_PreviewKeyDown({ param($s, $e) Safe { Invoke-DreddShortcut $e } })
}

function Invoke-DreddShortcut {
    # Ctrl+F — поиск на экране, F5 — обновить/сканировать, Ctrl+L — журнал, Ctrl+1…5 — разделы.
    param($E)
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $key = if ($E.Key -eq 'System') { $E.SystemKey } else { $E.Key }
    if ($ctrl -and $key -eq 'L') { $script:UI.LogToggle.IsChecked = -not $script:UI.LogToggle.IsChecked; $E.Handled = $true; return }
    if ($ctrl -and $key -eq 'F') {
        $box = @{ Purchases = 'PurSearch'; Catalog = 'CatalogQuery'; Library = 'LibSearch' }[$script:CurrentPage]
        if ($box) { [void]$script:UI[$box].Focus(); $script:UI[$box].SelectAll(); $E.Handled = $true }
        return
    }
    if ($ctrl) {
        $pages = @{ D1 = 'Purchases'; D2 = 'Catalog'; D3 = 'Downloads'; D4 = 'Library'; D5 = 'Devices' }
        if ($pages.ContainsKey([string]$key)) { Show-DreddPage $pages[[string]$key]; $E.Handled = $true }
        return
    }
    if ($key -eq 'F5') {
        switch ($script:CurrentPage) {
            'Purchases' { Start-DreddPurchaseScan }
            'Library' { Start-DreddLibraryRefresh }
            'Devices' { Start-DreddDeviceScan }
            'Accounts' { Start-DreddAccountRefresh }
            'Diagnostics' { Update-DiagnosticsPage }
        }
        $E.Handled = $true
    }
}

function Update-DreddShell {
    # Сообщение автора списков (Files/Warning.txt), пока пользователь его не закрыл.
    $u = $script:UI
    $warn = $null
    try { $warn = [System.IO.File]::ReadAllText($script:Ctx.WarningPath) } catch { }
    if (-not $script:WarningDismissed -and -not [string]::IsNullOrWhiteSpace($warn)) {
        $u.WarningText.Text = $warn.Trim()
        $u.WarningBanner.Visibility = 'Visible'
    } else { $u.WarningBanner.Visibility = 'Collapsed' }
}

function Update-DreddAccountUi {
    # Аккаунт в боковой панели и на странице Apple ID; при смене аккаунта — его библиотека покупок.
    $u = $script:UI
    $a = $script:Account
    if ($a -and $a.Success) {
        $u.SideAccountDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Brush.Success')
        $u.SideAccountText.Text = $a.Email
        $u.SideAccountDetail.Text = if ($a.Storefront) { TF 'Dash.Storefront' @($a.Storefront) } else { '' }
    } else {
        $u.SideAccountDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Brush.Warning')
        $u.SideAccountText.Text = T 'Account.NotLoggedIn'
        $u.SideAccountDetail.Text = if ($a -and $a.ErrorKey -eq 'Err.SessionInvalid') { T 'Err.SessionInvalid' } else { T 'Side.SignInHint' }
    }
    if (Get-Command Update-AccountsPage -ErrorAction SilentlyContinue) { Update-AccountsPage }
    if (Get-Command Sync-DreddPurchaseAccount -ErrorAction SilentlyContinue) { Sync-DreddPurchaseAccount }
    # Незавершённые загрузки прошлого запуска — предложить продолжить (один раз для аккаунта).
    if ($a -and $a.Success -and (Get-Command Invoke-DreddQueueRestore -ErrorAction SilentlyContinue)) { Invoke-DreddQueueRestore }
}

function Start-DreddAccountRefresh {
    param([switch]$Silent)
    if (-not $script:Ctx.Binaries.Ipatool) { $script:Account = $null; Update-DreddAccountUi; return }
    [void](Start-DreddTask -Name (T 'Task.CheckAccount') -Silent:$Silent -Script {
        Get-DreddAuthInfo -Context $Context -Reporter $Reporter -CancellationToken $Token
    } -OnComplete {
        param($r)
        $script:Account = $r
        if ($r -and $r.Success) {
            # Совместимость с 4.2: маркер login должен существовать при действующей сессии.
            Set-DreddLoginMarker -Context $script:Ctx
            Add-DreddLog -Level Info -Area 'Account' -Message (TF 'Log.AccountActive' @($r.Email, $r.Storefront))
        } elseif ($r -and $r.ErrorKey -eq 'Err.SessionInvalid') {
            Add-DreddLog -Level Warning -Area 'Account' -Message (T 'Err.SessionInvalid')
        }
        Update-DreddAccountUi
    })
}

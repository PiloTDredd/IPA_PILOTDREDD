# Аккаунты Apple ID: вход (форма и консоль), 2FA, переключение, выход, забыть сохранённый.

$script:LoginTask = $null

function Initialize-AccountsPage {
    $u = $script:UI
    $u.AccCheckBtn.Add_Click({ Safe { Start-DreddAccountRefresh } })
    $u.AccLogoutBtn.Add_Click({ Safe { Invoke-DreddLogout } })
    $u.AccLoginBtn.Add_Click({ Safe { Start-DreddLogin } })
    $u.AccLoginCancelBtn.Add_Click({ Safe { if ($script:LoginTask) { Stop-DreddTask $script:LoginTask.Id } } })
    $u.AccConsoleLoginBtn.Add_Click({ Safe { Start-DreddConsoleLoginFlow } })
    $u.AccSwitchBtn.Add_Click({ Safe { Invoke-DreddAccountSwitch } })
    $u.AccForgetBtn.Add_Click({ Safe { Invoke-DreddAccountForget } })
    $u.AccSavedList.Add_SelectionChanged({ Safe { Update-AccountsButtons } })
    $u.AccLoginPassword.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Safe { Start-DreddLogin } } })
    $u.AccLoginCode.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Safe { Start-DreddLogin } } })
}

function Show-AccountsPage { Update-AccountsPage }

function Update-AccountsPage {
    $u = $script:UI
    $a = $script:Account
    $loggedIn = $a -and $a.Success
    if ($loggedIn) {
        $u.AccStatusDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Brush.Success')
        $u.AccEmail.Text = $a.Email
        $parts = @()
        if ($a.Name) { $parts += $a.Name }
        if ($a.Storefront) { $parts += (TF 'Dash.Storefront' @($a.Storefront)) }
        $u.AccDetail.Text = $parts -join ' · '
        $u.AccLoginTitle.Text = T 'Accounts.AddTitle'
    } else {
        $u.AccStatusDot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, 'Brush.Warning')
        $u.AccEmail.Text = T 'Account.NotLoggedIn'
        $u.AccDetail.Text = if ($a -and $a.ErrorKey -eq 'Err.SessionInvalid') { T 'Err.SessionInvalid' } elseif (-not $script:Ctx.Binaries.Ipatool) { T 'Err.NoIpatool' } else { T 'Account.NotLoggedInHint' }
        $u.AccLoginTitle.Text = T 'Accounts.LoginTitle'
    }
    $u.AccLogoutBtn.IsEnabled = [bool]$loggedIn
    $u.AccLoginBtn.IsEnabled = [bool]$script:Ctx.Binaries.Ipatool -and -not $script:LoginTask
    $u.AccConsoleLoginBtn.IsEnabled = [bool]$script:Ctx.Binaries.Ipatool -and -not $script:LoginTask

    $rows = New-Object System.Collections.ObjectModel.ObservableCollection[IPADredd.Gui.SimpleRow]
    foreach ($s in @(Get-DreddSavedAccounts -Context $script:Ctx)) {
        if ($loggedIn -and $s.Email -eq $a.Email) { continue }
        $r = New-Object IPADredd.Gui.SimpleRow
        $r.Key = $s.Email; $r.C1 = $s.Email
        $r.C2 = if ($s.HasSession) { T 'Accounts.SessionSaved' } else { T 'Accounts.NoSession' }
        $rows.Add($r)
    }
    $u.AccSavedList.ItemsSource = $rows
    $u.AccSavedEmpty.Visibility = if ($rows.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    Update-AccountsButtons
}

function Update-AccountsButtons {
    $sel = $script:UI.AccSavedList.SelectedItem
    $busy = [bool]$script:LoginTask
    $script:UI.AccSwitchBtn.IsEnabled = ($null -ne $sel) -and -not $busy
    $script:UI.AccForgetBtn.IsEnabled = ($null -ne $sel) -and -not $busy
}

function Set-DreddLoginBusy {
    param([bool]$Busy)
    $u = $script:UI
    $u.AccLoginBusy.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $u.AccLoginCancelBtn.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $u.AccLoginBtn.IsEnabled = -not $Busy
    $u.AccConsoleLoginBtn.IsEnabled = -not $Busy
    $u.AccLoginEmail.IsEnabled = -not $Busy
    $u.AccLoginPassword.IsEnabled = -not $Busy
    $u.AccLoginCode.IsEnabled = -not $Busy
    Update-AccountsButtons
}

function Show-DreddLoginError {
    param([string]$Text)
    $u = $script:UI
    if ($Text) { $u.AccLoginError.Text = $Text; $u.AccLoginError.Visibility = 'Visible' }
    else { $u.AccLoginError.Visibility = 'Collapsed' }
}

function Start-DreddLogin {
    $u = $script:UI
    if ($script:LoginTask) { return }
    $email = $u.AccLoginEmail.Text.Trim()
    if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Show-DreddLoginError (T 'Err.EmailFormat'); return }
    if ($u.AccLoginPassword.SecurePassword.Length -eq 0) { Show-DreddLoginError (T 'Err.PasswordEmpty'); return }
    Show-DreddLoginError $null
    $park = $null
    if ($script:Account -and $script:Account.Success) {
        if ($script:Account.Email -eq $email) { Show-DreddLoginError (T 'Accounts.AlreadyActive'); return }
        $park = $script:Account.Email
    }
    $code = $null
    if ($u.AccCodePanel.Visibility -eq 'Visible') { $code = $u.AccLoginCode.Text.Trim() }
    Set-DreddLoginBusy $true
    Add-DreddLog -Level Info -Area 'Account' -Message (TF 'Log.LoginStart' @($email))
    $script:LoginTask = Start-DreddTask -Name (T 'Task.Login') -Arguments @{
        Email = $email; Password = $u.AccLoginPassword.SecurePassword.Copy(); Code = $code; Park = $park
    } -Script {
        Connect-DreddAppleId -Context $Context -Email $A.Email -Password $A.Password -AuthCode $A.Code -ParkCurrentAs $A.Park -Reporter $Reporter -CancellationToken $Token
    } -OnComplete {
        param($r)
        $script:LoginTask = $null
        Set-DreddLoginBusy $false
        $u = $script:UI
        if ($r.Success) {
            $u.AccLoginPassword.Clear(); $u.AccLoginCode.Clear(); $u.AccCodePanel.Visibility = 'Collapsed'; $u.AccLoginEmail.Clear()
            $script:Account = $r.Account
            Add-DreddLog -Level Success -Area 'Account' -Message (TF 'Log.LoginOk' @($r.Account.Email))
            Update-DreddAccountUi
            # После входа — сразу к библиотеке покупок этого аккаунта.
            Show-DreddPage 'Purchases'
        } elseif ($r.NeedsCode) {
            $u.AccCodePanel.Visibility = 'Visible'
            [void]$u.AccLoginCode.Focus()
            Show-DreddLoginError (T 'Accounts.CodeRequired')
            Add-DreddLog -Level Warning -Area 'Account' -Message (T 'Accounts.CodeRequired')
        } else {
            $txt = Get-DreddErrorText $r.ErrorKey $r.Message
            Show-DreddLoginError $txt
            Add-DreddLog -Level Error -Area 'Account' -Message $txt
            Update-DreddAccountUi
        }
    } -OnError {
        param($m)
        $script:LoginTask = $null
        Set-DreddLoginBusy $false
        Show-DreddLoginError $m
        Add-DreddLog -Level Error -Area 'Account' -Message $m
    }
}

function Start-DreddConsoleLoginFlow {
    if ($script:LoginTask) { return }
    $park = $null
    if ($script:Account -and $script:Account.Success) {
        if (-not (Confirm-Dredd -Title (T 'Accounts.ConsoleAddTitle') -Message (TF 'Accounts.ConsoleAddText' @($script:Account.Email)))) { return }
        $park = $script:Account.Email
        Save-DreddActiveAccount -Context $script:Ctx -Email $park
    }
    $p = Start-DreddConsoleLogin -Context $script:Ctx -PromptText (T 'Accounts.ConsolePrompt')
    Add-DreddLog -Level Info -Area 'Account' -Message (T 'Log.ConsoleLoginStarted')
    Set-DreddLoginBusy $true
    $script:LoginTask = Start-DreddTask -Name (T 'Task.ConsoleLogin') -Arguments @{ Pid = $p.Id; Park = $park } -Script {
        $proc = $null
        try { $proc = [System.Diagnostics.Process]::GetProcessById($A.Pid) } catch { }
        while ($proc -and -not $proc.HasExited) {
            if ($Token.IsCancellationRequested) { break }
            Start-Sleep -Milliseconds 400
        }
        $info = Get-DreddAuthInfo -Context $Context -Reporter $Reporter
        if ($info.Success) {
            $info = Complete-DreddLogin -Context $Context -Reporter $Reporter -CancellationToken $Token
        } elseif ($A.Park) {
            Clear-DreddActiveAccount -Context $Context
            [void](Restore-DreddSavedAccount -Context $Context -Email $A.Park)
            $info = Get-DreddAuthInfo -Context $Context -Reporter $Reporter
            $info | Add-Member -NotePropertyName Restored -NotePropertyValue $true -Force
        }
        $info
    } -OnComplete {
        param($r)
        $script:LoginTask = $null
        Set-DreddLoginBusy $false
        $script:Account = $r
        if ($r.Success -and -not ($r.PSObject.Properties['Restored'])) {
            Add-DreddLog -Level Success -Area 'Account' -Message (TF 'Log.LoginOk' @($r.Email))
        } else {
            Add-DreddLog -Level Warning -Area 'Account' -Message (T 'Log.ConsoleLoginFailed')
        }
        Update-DreddAccountUi
    }
}

function Invoke-DreddLogout {
    $a = $script:Account
    if (-not ($a -and $a.Success)) { return }
    if (-not (Confirm-Dredd -Title (T 'Accounts.LogoutTitle') -Message (TF 'Accounts.LogoutText' @($a.Email)) -YesText (T 'Accounts.Logout') -Danger -Kind Warning)) { return }
    [void](Start-DreddTask -Name (T 'Task.Logout') -Script {
        Disconnect-DreddAppleId -Context $Context -Reporter $Reporter -CancellationToken $Token
    } -OnComplete {
        $script:Account = $null
        Add-DreddLog -Level Success -Area 'Account' -Message (T 'Log.LoggedOut')
        Update-DreddAccountUi
    })
}

function Invoke-DreddAccountSwitch {
    $sel = $script:UI.AccSavedList.SelectedItem
    if (-not $sel) { return }
    $current = $null
    if ($script:Account -and $script:Account.Success) { $current = $script:Account.Email }
    Set-DreddLoginBusy $true
    $script:LoginTask = Start-DreddTask -Name (T 'Task.SwitchAccount') -Arguments @{ Email = $sel.Key; Current = $current } -Script {
        Switch-DreddAccount -Context $Context -Email $A.Email -CurrentEmail $A.Current -Reporter $Reporter -CancellationToken $Token
    } -OnComplete {
        param($r)
        $script:LoginTask = $null
        Set-DreddLoginBusy $false
        $script:Account = $r
        if ($r.Success) { Add-DreddLog -Level Success -Area 'Account' -Message (TF 'Log.Switched' @($r.Email)) }
        else { Add-DreddLog -Level Error -Area 'Account' -Message (T 'Err.SessionInvalid') }
        Update-DreddAccountUi
    } -OnError {
        param($m)
        $script:LoginTask = $null
        Set-DreddLoginBusy $false
        Add-DreddLog -Level Error -Area 'Account' -Message $m
        Update-DreddAccountUi
    }
}

function Invoke-DreddAccountForget {
    $sel = $script:UI.AccSavedList.SelectedItem
    if (-not $sel) { return }
    if (-not (Confirm-Dredd -Title (T 'Accounts.ForgetTitle') -Message (TF 'Accounts.ForgetText' @($sel.Key)) -YesText (T 'Accounts.Forget') -Danger -Kind Warning)) { return }
    Remove-DreddSavedAccount -Context $script:Ctx -Email $sel.Key
    Add-DreddLog -Level Info -Area 'Account' -Message (TF 'Log.Forgotten' @($sel.Key))
    Update-AccountsPage
}

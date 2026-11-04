# Настройки: язык, тема, пути, поведение, безопасность. Всё сохраняется в Files/Settings.txt сразу.

$script:SettingsLoading = $false

function Save-DreddSetting {
    param([string]$Key, [string]$Value)
    Set-DreddSetting -Path $script:Ctx.SettingsPath -Key $Key -Value $Value -Settings $script:Ctx.Settings
    Add-DreddLog -Level Debug -Area 'Settings' -Message "$Key=$Value"
}

function Initialize-SettingsPage {
    $u = $script:UI
    $u.SetLangRu.Add_Checked({ Safe { if (-not $script:SettingsLoading) { Set-DreddUiLanguage 'RU' } } })
    $u.SetLangEn.Add_Checked({ Safe { if (-not $script:SettingsLoading) { Set-DreddUiLanguage 'EN' } } })
    $u.SetThemeDark.Add_Checked({ Safe { if (-not $script:SettingsLoading) { Save-DreddSetting 'Theme' 'Dark'; Set-DreddTheme 'Dark' } } })
    $u.SetThemeLight.Add_Checked({ Safe { if (-not $script:SettingsLoading) { Save-DreddSetting 'Theme' 'Light'; Set-DreddTheme 'Light' } } })

    $u.SetDownloadFolderBtn.Add_Click({ Safe { Select-DreddDownloadFolder } })
    $u.SetDownloadFolderReset.Add_Click({ Safe { Save-DreddSetting 'DownloadFolder' ''; Invoke-DreddPathsChanged } })
    $u.SetBinaryRootBtn.Add_Click({ Safe {
        $p = Select-DreddFolder -Description (T 'Settings.BinaryRoot') -Initial $script:Ctx.Binaries.Root
        if ($p) { Save-DreddSetting 'BinaryRoot' $p; Invoke-DreddPathsChanged }
    } })
    $u.SetBinaryRootReset.Add_Click({ Safe { Save-DreddSetting 'BinaryRoot' ''; Invoke-DreddPathsChanged } })

    $u.SetUpdateLists.Add_Click({ Safe { Save-DreddSetting 'UpdateListsOnStartup' ([string][bool]$script:UI.SetUpdateLists.IsChecked) } })
    $u.SetCheckUpdates.Add_Click({ Safe { Save-DreddSetting 'CheckUpdatesOnStartup' ([string][bool]$script:UI.SetCheckUpdates.IsChecked) } })
    $u.SetAutoPurchase.Add_Click({ Safe { Set-DreddAutoPurchase ([bool]$script:UI.SetAutoPurchase.IsChecked) } })
    $u.SetFileNameAccount.Add_Click({ Safe { Save-DreddSetting 'FileNameIncludeAccount' ([string][bool]$script:UI.SetFileNameAccount.IsChecked) } })
    $u.SetRemoteUrlSave.Add_Click({ Safe {
        $url = $script:UI.SetRemoteUrl.Text.Trim().TrimEnd('/')
        if ($url -notmatch '^https://[^\s]+$') { [void](Show-DreddDialog -Title (T 'Settings.RemoteUrl') -Message (T 'Err.UrlHttps') -Kind Warning); return }
        Save-DreddSetting 'RemoteListBaseUrl' $url
        Add-DreddLog -Level Success -Area 'Settings' -Message (T 'Log.Saved')
    } })
    $u.SetKeychain.Add_Click({ Safe {
        $on = [bool]$script:UI.SetKeychain.IsChecked
        if ($on -and -not (Confirm-Dredd -Title (T 'Settings.Keychain') -Message (T 'Settings.KeychainConfirm') -Kind Warning)) {
            $script:UI.SetKeychain.IsChecked = $false; return
        }
        Save-DreddSetting 'KeychainEnabled' ([string]$on)
    } })
    $u.SetDebug.Add_Click({ Safe {
        $on = [bool]$script:UI.SetDebug.IsChecked
        Save-DreddSetting 'DebugEnabled' ([string]$on)
        Add-DreddLog -Level Info -Area 'Settings' -Message $(if ($on) { T 'Log.DebugOn' } else { T 'Log.DebugOff' })
    } })
    if (-not $script:Ctx.Platform.IsWindows) { $u.SetKeychain.IsEnabled = $false }
}

function Show-SettingsPage { Update-SettingsPage }

function Update-SettingsPage {
    $u = $script:UI; $s = $script:Ctx.Settings
    $script:SettingsLoading = $true
    try {
        $u.SetLangRu.IsChecked = ($s['Language'] -eq 'RU'); $u.SetLangEn.IsChecked = ($s['Language'] -eq 'EN')
        $u.SetThemeDark.IsChecked = ($s['Theme'] -ne 'Light'); $u.SetThemeLight.IsChecked = ($s['Theme'] -eq 'Light')
        $u.SetDownloadFolder.Text = $script:Ctx.DownloadDir
        $u.SetBinaryRoot.Text = [string]$s['BinaryRoot']
        $b = $script:Ctx.Binaries
        $u.SetBinaryInfo.Text = if ($b.Root) { TF 'Settings.BinaryFound' @($b.Root, (T "Source.$($b.RootSource)")) } else { T 'Err.NoIpatool' }
        $u.SetUpdateLists.IsChecked = ConvertTo-DreddBool $s['UpdateListsOnStartup']
        $u.SetCheckUpdates.IsChecked = ConvertTo-DreddBool $s['CheckUpdatesOnStartup']
        $u.SetAutoPurchase.IsChecked = ConvertTo-DreddBool $s['AutoPurchase']
        $u.SetFileNameAccount.IsChecked = ConvertTo-DreddBool $s['FileNameIncludeAccount']
        $u.SetKeychain.IsChecked = ConvertTo-DreddBool $s['KeychainEnabled']
        $u.SetDebug.IsChecked = ConvertTo-DreddBool $s['DebugEnabled']
        $u.SetRemoteUrl.Text = [string]$s['RemoteListBaseUrl']
    } finally { $script:SettingsLoading = $false }
}

function Set-DreddUiLanguage {
    param([ValidateSet('RU', 'EN')][string]$Language)
    Save-DreddSetting 'Language' $Language
    Set-DreddLanguage $Language
    Update-DreddPageHeader
    Update-DreddBusyIndicator
    # Динамические тексты всех экранов:
    Update-DreddAccountUi
    Update-DreddShell
    if (Get-Command Update-CatalogView -ErrorAction SilentlyContinue) { Update-CatalogView }
    if (Get-Command Update-DownloadsTexts -ErrorAction SilentlyContinue) { Update-DownloadsTexts }
    if (Get-Command Update-LibraryTexts -ErrorAction SilentlyContinue) { Update-LibraryTexts }
    if (Get-Command Update-DevicesTexts -ErrorAction SilentlyContinue) { Update-DevicesTexts }
    if (Get-Command Update-DiagnosticsPage -ErrorAction SilentlyContinue) { Update-DiagnosticsPage }
    Update-SettingsPage
}

function Set-DreddAutoPurchase {
    param([bool]$On)
    Save-DreddSetting 'AutoPurchase' ([string]$On)
    foreach ($n in 'CatalogAutoPurchase', 'DlAutoPurchase', 'SetAutoPurchase') {
        if ($script:UI[$n] -and $script:UI[$n].IsChecked -ne $On) { $script:UI[$n].IsChecked = $On }
    }
}

function Select-DreddDownloadFolder {
    $p = Select-DreddFolder -Description (T 'Settings.DownloadFolder') -Initial $script:Ctx.DownloadDir
    if ($p) { Save-DreddSetting 'DownloadFolder' $p; Invoke-DreddPathsChanged }
}

function Invoke-DreddPathsChanged {
    Update-DreddContextPaths -Context $script:Ctx
    Add-DreddLog -Level Info -Area 'Settings' -Message (TF 'Log.PathsUpdated' @($script:Ctx.DownloadDir))
    Update-SettingsPage
    if (Get-Command Update-DownloadsTexts -ErrorAction SilentlyContinue) { Update-DownloadsTexts }
    Update-DreddShell
    if (Get-Command Start-DreddLibraryRefresh -ErrorAction SilentlyContinue) { Start-DreddLibraryRefresh }
}

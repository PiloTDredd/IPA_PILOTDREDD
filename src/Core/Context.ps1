# Контекст приложения: пути, настройки, платформа, бинарники.

function New-DreddContext {
    param(
        [Parameter(Mandatory)][string]$AppRoot,
        [string]$IpatoolHome,
        [string]$TempRoot
    )
    $AppRoot = [System.IO.Path]::GetFullPath($AppRoot)
    $platform = Get-DreddPlatform
    $filesDir = Join-Path $AppRoot 'Files'
    $logsDir = Join-Path $AppRoot 'Logs'
    $settingsPath = Join-Path $filesDir 'Settings.txt'
    foreach ($d in @($filesDir, $logsDir)) {
        if (-not [System.IO.Directory]::Exists($d)) { [void][System.IO.Directory]::CreateDirectory($d) }
    }
    $customList = Join-Path $filesDir 'AppsListCustom.txt'
    if (-not [System.IO.File]::Exists($customList)) { Write-DreddTextFile -Path $customList -Content '' }

    if (-not $IpatoolHome) { $IpatoolHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ipatool' }
    if (-not $TempRoot) { $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'IPADredd' }

    $ctx = [hashtable]::Synchronized(@{
        AppRoot        = $AppRoot
        FilesDir       = $filesDir
        LogsDir        = $logsDir
        SettingsPath   = $settingsPath
        AppsListPath   = Join-Path $filesDir 'AppsList.txt'
        CustomListPath = $customList
        WarningPath    = Join-Path $filesDir 'Warning.txt'
        PurchasedPath  = Join-Path $filesDir 'PurchasedAppsList.json'
        HistoryPath    = Join-Path $filesDir 'DownloadHistory.json'
        IpatoolHome    = $IpatoolHome
        TempRoot       = $TempRoot
        Platform       = $platform
        Settings       = $null
        DownloadDir    = $null
        Binaries       = $null
        # 'auto' — использовать keychain-passphrase, если файл есть; 'none' — без passphrase (выясняется при проверке сессии).
        PassphraseMode = 'auto'
        Version        = $script:DreddVersion
    })
    $ctx.Settings = Get-DreddSettings -Path $settingsPath
    Update-DreddContextPaths -Context $ctx
    return $ctx
}

function Update-DreddContextPaths {
    # Пересчитывает папку загрузок и бинарники после изменения настроек.
    param([Parameter(Mandatory)]$Context)
    $dl = [string]$Context.Settings['DownloadFolder']
    if ([string]::IsNullOrWhiteSpace($dl)) { $dl = Join-Path $Context.AppRoot 'Apps' }
    elseif (-not [System.IO.Path]::IsPathRooted($dl)) { $dl = Join-Path $Context.AppRoot $dl }
    $Context.DownloadDir = [System.IO.Path]::GetFullPath($dl)
    try {
        if (-not [System.IO.Directory]::Exists($Context.DownloadDir)) { [void][System.IO.Directory]::CreateDirectory($Context.DownloadDir) }
    } catch { }
    $Context.Binaries = Find-DreddBinaries -AppRoot $Context.AppRoot -Configured ([string]$Context.Settings['BinaryRoot']) -Platform $Context.Platform
}

#requires -Version 5.1
<#
    IPA PILOTDREDD — GUI (Windows PowerShell 5.1 + WPF).
    Параметры:
      -SelfTest            собрать окно и все экраны, переключить темы и языки, вывести результат и выйти (код 0/1)
      -Screenshot <папка>  сохранить PNG каждого экрана (тёмная и светлая тема) и выйти
      -NoBackground        не запускать фоновые задачи при старте
      -TestIpatool <путь>  (только с -SelfTest, для разработки) подменить ipatool фейком и прогнать сценарий
                           покупки → поиск → очередь загрузки → библиотека → отмена через настоящий TaskRunner
#>
param(
    [switch]$SelfTest,
    [string]$Screenshot,
    [switch]$NoBackground,
    [string]$TestIpatool,
    # -Demo (с -Screenshot и -TestIpatool): снимки для README на демо-данных, подготовленных tools/Make-Screenshots.ps1
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

# Лаунчер скрывает консоль, поэтому ошибка запуска показывается окном и пишется в Logs/startup-error.log.
trap {
    $msg = "$($_.Exception.Message)`n$($_.InvocationInfo.PositionMessage)"
    try {
        $logDir = Join-Path $PSScriptRoot 'Logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        Add-Content -LiteralPath (Join-Path $logDir 'startup-error.log') -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg) -Encoding UTF8
    } catch { }
    if ($SelfTest -or $Screenshot) { Write-Output "SELFTEST FAILED: $msg"; exit 1 }
    try {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("IPA PILOTDREDD could not start:`n`n$msg", 'IPA PILOTDREDD', 'OK', 'Error')
    } catch { Write-Error $msg }
    exit 1
}

# WPF требует STA. Windows PowerShell 5.1 с -File запускается в STA; на всякий случай перезапускаемся.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $argsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    if ($SelfTest) { $argsList += '-SelfTest' }
    if ($Screenshot) { $argsList += @('-Screenshot', "`"$Screenshot`"") }
    if ($NoBackground) { $argsList += '-NoBackground' }
    if ($TestIpatool) { $argsList += @('-TestIpatool', "`"$TestIpatool`"") }
    if ($Demo) { $argsList += '-Demo' }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argsList -Wait -PassThru -NoNewWindow
    exit $p.ExitCode
}

$coreModule = Join-Path $PSScriptRoot 'src/Core/IPADredd.Core.psm1'
Import-Module $coreModule -Force -DisableNameChecking

. (Join-Path $PSScriptRoot 'src/GUI/Gui.ps1')
. (Join-Path $PSScriptRoot 'src/GUI/TaskRunner.ps1')
# Сборки WPF и классы строк (ViewModels.cs) нужны до подключения страниц: они создают коллекции этих типов.
Initialize-DreddApplication
foreach ($page in 'Shell', 'Purchases', 'Catalog', 'Downloads', 'Library', 'Devices', 'Accounts', 'Settings', 'Diagnostics') {
    . (Join-Path $PSScriptRoot "src/GUI/Pages/$page.ps1")
}

$script:SelfTestMode = [bool]($SelfTest -or $Screenshot)
$script:Ctx = New-DreddContext -AppRoot $PSScriptRoot

$script:Window = New-DreddWindow -Path (Join-Path $PSScriptRoot 'src/GUI/MainWindow.xaml')
$script:UI.AppVersionText.Text = "v$($script:Ctx.Version)"
$script:Window.Title = "IPA PILOTDREDD $($script:Ctx.Version)"
# Иконка окна и панели задач (та же, что у IPA_PILOTDREDD.exe).
$script:AppIconPath = Join-Path $PSScriptRoot 'src/GUI/Assets/app.ico'
if ([System.IO.File]::Exists($script:AppIconPath)) {
    try { $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($script:AppIconPath))) } catch { }
}

Register-DreddLocalization $script:Window
Set-DreddLanguage $script:Ctx.Settings['Language']
Set-DreddTheme $script:Ctx.Settings['Theme']
Initialize-DreddTaskRunner -CoreModulePath $coreModule

# ---- Навигация и журнал ----
$script:UI.NavPurchases.Add_Checked({ Safe { if ($script:CurrentPage -ne 'Purchases') { Show-DreddPage 'Purchases' } } })
$script:UI.NavCatalog.Add_Checked({ Safe { if ($script:CurrentPage -ne 'Catalog') { Show-DreddPage 'Catalog' } } })
$script:UI.NavDownloads.Add_Checked({ Safe { if ($script:CurrentPage -ne 'Downloads') { Show-DreddPage 'Downloads' } } })
$script:UI.NavLibrary.Add_Checked({ Safe { if ($script:CurrentPage -ne 'Library') { Show-DreddPage 'Library' } } })
$script:UI.NavDevices.Add_Checked({ Safe { if ($script:CurrentPage -ne 'Devices') { Show-DreddPage 'Devices' } } })
$script:UI.NavAccounts.Add_Checked({ Safe { if ($script:CurrentPage -ne 'Accounts') { Show-DreddPage 'Accounts' } } })
$script:UI.NavSettings.Add_Checked({ Safe { if ($script:CurrentPage -ne 'Settings') { Show-DreddPage 'Settings' } } })
$script:UI.NavDiagnostics.Add_Checked({ Safe { if ($script:CurrentPage -ne 'Diagnostics') { Show-DreddPage 'Diagnostics' } } })

$script:UI.LogErrorsOnly.Add_Click({ Safe { Update-DreddLogView } })
$script:UI.LogClearBtn.Add_Click({ Safe { $script:LogLines.Clear(); $script:UI.LogBox.Clear(); $script:UI.LogLastLine.Text = '' } })
$script:UI.LogCopyBtn.Add_Click({ Safe { if ($script:UI.LogBox.Text) { [System.Windows.Clipboard]::SetText($script:UI.LogBox.Text) } } })
$script:UI.LogOpenBtn.Add_Click({ Safe {
    $f = Join-Path $script:Ctx.LogsDir ((Get-Date).ToString('yyyy-MM-dd') + '.log')
    if ([System.IO.File]::Exists($f)) { Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$f`"" } else { Open-DreddPath $script:Ctx.LogsDir }
} })

Initialize-DreddToast
Initialize-ShellPage
Initialize-PurchasesPage
Initialize-CatalogPage
Initialize-DownloadsPage
Initialize-LibraryPage
Initialize-DevicesPage
Initialize-AccountsPage
Initialize-SettingsPage
Initialize-DiagnosticsPage

Update-DreddBusyIndicator
Update-DreddAccountUi
Update-DreddShell
Show-DreddPage 'Purchases'
Add-DreddLog -Level Info -Area 'App' -Message (TF 'Log.Started' @($script:Ctx.Version, $script:Ctx.Platform.OSDescription, $script:Ctx.Platform.PSVersion))
if (-not $script:Ctx.Binaries.Ipatool) { Add-DreddLog -Level Error -Area 'App' -Message (T 'Err.NoIpatool') }
else { Add-DreddLog -Level Info -Area 'App' -Message (TF 'Dash.BinarySource' @((T "Source.$($script:Ctx.Binaries.RootSource)"))) }

# ---- Закрытие ----
$script:Window.Add_Closing({
    param($s, $e)
    $active = Get-DreddActiveTaskCount
    if ($active -gt 0 -and -not $script:SelfTestMode -and -not $script:ForceClose) {
        if (-not (Confirm-Dredd -Title (T 'App.ExitTitle') -Message (TF 'App.ExitText' @($active)) -YesText (T 'App.ExitYes') -Danger -Kind Warning)) {
            $e.Cancel = $true
        }
    }
    # Дальше задачи будут остановлены — очередь в Files/Queue.json больше не переписываем (продолжится при следующем запуске).
    if (-not $e.Cancel) { $script:Closing = $true }
})

# ---- Самопроверка / снимки экранов ----
function Save-DreddScreenshot {
    param([string]$Path)
    $root = $script:Window.Content
    $script:Window.UpdateLayout()
    $w = [int]$root.ActualWidth; $h = [int]$root.ActualHeight
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bg = New-Object System.Windows.Media.DrawingVisual
    $dc = $bg.RenderOpen()
    $dc.DrawRectangle($script:Window.Background, $null, (New-Object System.Windows.Rect(0, 0, $w, $h)))
    $dc.Close()
    $bmp.Render($bg)
    $bmp.Render($root)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [System.IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
}

function Wait-DreddUi {
    param([int]$Ms = 300)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Ms) {
        $frame = New-Object System.Windows.Threading.DispatcherFrame
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ $frame.Continue = $false })
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        Invoke-DreddTaskPump
        Start-Sleep -Milliseconds 20
    }
}

if ($SelfTest -or $Screenshot) {
    $errors = New-Object System.Collections.Generic.List[string]
    $script:Window.ShowActivated = $false
    $script:Window.WindowStartupLocation = 'Manual'
    $script:Window.Left = -20000; $script:Window.Top = 0
    $script:Window.Show()
    try {
        if ($Screenshot -and -not [System.IO.Directory]::Exists($Screenshot)) { [void][System.IO.Directory]::CreateDirectory($Screenshot) }
        if ($Demo -and $Screenshot -and $TestIpatool) {
            # Снимки для README: демо-аккаунт user@example.com, кэш покупок и иконки уже лежат в копии программы.
            $wait = { param([scriptblock]$Cond, [int]$Ms = 30000) $sw2 = [System.Diagnostics.Stopwatch]::StartNew(); while (-not (& $Cond) -and $sw2.ElapsedMilliseconds -lt $Ms) { Wait-DreddUi 150 }; & $Cond }
            $script:Ctx.Binaries.Ipatool = (Resolve-Path $TestIpatool).Path
            $fx = Split-Path $script:Ctx.Binaries.Ipatool -Parent
            $script:Ctx.Binaries.Root = $fx
            $script:Ctx.Binaries.IdeviceId = Join-Path $fx 'fake-idevice_id.cmd'
            $script:Ctx.Binaries.IdeviceInfo = Join-Path $fx 'fake-ideviceinfo.cmd'
            $script:Ctx.Binaries.IdeviceInstaller = Join-Path $fx 'fake-ideviceinstaller.cmd'
            Start-DreddLibraryRefresh
            [void](& $wait { -not $script:LibraryTask })
            Start-DreddAccountRefresh
            [void](& $wait { $script:Account -and $script:Account.Success -and -not $script:PurchaseLoadTask -and $script:PurchaseRows.Count -gt 0 })
            Start-DreddDeviceScan
            [void](& $wait { -not $script:DeviceScanTask })
            Update-DreddPurchaseStatuses
            $shots = @(
                @{ Theme = 'Dark'; Page = 'Purchases'; Name = 'purchases_dark' }, @{ Theme = 'Light'; Page = 'Purchases'; Name = 'purchases_light' },
                @{ Theme = 'Dark'; Page = 'Purchases'; Tab = 'PurTabMissing'; Name = 'purchases_removed' },
                @{ Theme = 'Dark'; Page = 'Catalog'; Tab = 'SrcPopular'; Name = 'search_popular' },
                @{ Theme = 'Dark'; Page = 'Downloads'; Name = 'downloads' }, @{ Theme = 'Dark'; Page = 'Devices'; Name = 'devices' })
            foreach ($s in $shots) {
                Set-DreddTheme $s.Theme; Set-DreddLanguage 'RU'
                Show-DreddPage $s.Page
                $script:UI.PurTabAll.IsChecked = $true; $script:UI.SrcSearch.IsChecked = $true
                if ($s.Tab) { $script:UI[$s.Tab].IsChecked = $true }
                if ($s.Page -eq 'Devices' -and $script:UI.DevIpaGrid.Items.Count -gt 0) { $script:UI.DevIpaGrid.SelectedIndex = 0 }
                Wait-DreddUi 1200
                Save-DreddScreenshot (Join-Path $Screenshot ($s.Name + '.png'))
            }
            $script:ForceClose = $true; $script:Window.Close(); Close-DreddTaskRunner -WaitMs 2000
            Write-Output "DEMO OK: $($shots.Count) screenshots"
            exit 0
        }
        # Локальные данные без сети: библиотека и устройства (если есть инструменты).
        Start-DreddLibraryRefresh
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($script:LibraryTask -and $sw.ElapsedMilliseconds -lt 30000) { Wait-DreddUi 200 }
        $script:UI.CatalogQuery.Text = 'Telegram'
        foreach ($theme in 'Dark', 'Light') {
            Set-DreddTheme $theme
            foreach ($lang in 'RU', 'EN') {
                Set-DreddLanguage $lang
                foreach ($p in $script:Pages) {
                    try {
                        Show-DreddPage $p
                        Wait-DreddUi 250
                        if ($Screenshot -and $lang -eq $(if ($theme -eq 'Dark') { 'RU' } else { 'EN' })) {
                            Save-DreddScreenshot (Join-Path $Screenshot ("{0}_{1}_{2}.png" -f $theme, $lang, $p))
                        }
                    } catch { $errors.Add("$theme/$lang/${p}: $($_.Exception.Message)") }
                }
            }
        }
        if ($SelfTest -and $TestIpatool) {
            # Сценарий на фейковом ipatool через настоящий TaskRunner (runspace, очередь, колбэки UI).
            $wait = { param([scriptblock]$Cond, [int]$Ms = 30000) $sw2 = [System.Diagnostics.Stopwatch]::StartNew(); while (-not (& $Cond) -and $sw2.ElapsedMilliseconds -lt $Ms) { Wait-DreddUi 150 }; & $Cond }
            $script:Ctx.Binaries.Ipatool = (Resolve-Path $TestIpatool).Path
            $script:Ctx.Binaries.Root = Split-Path $script:Ctx.Binaries.Ipatool -Parent
            Set-DreddLanguage 'RU'
            Start-DreddAccountRefresh
            if (-not (& $wait { $script:Account -and $script:Account.Success })) { $errors.Add('scenario: account refresh failed') }
            # Библиотека покупок: сканирование без сети (Lookup отключён) → статусы «не проверено», без ложного «не куплено».
            $script:Ctx.LookupOffline = $true
            Show-DreddPage 'Purchases'
            Start-DreddPurchaseScan
            if (-not (& $wait { -not $script:PurchaseScanTask -and $script:PurchaseRows.Count -gt 0 })) { $errors.Add("scenario: purchase scan failed ($($script:PurchaseScanError))") }
            elseif ($script:PurchaseRows.Count -ne 2) { $errors.Add("scenario: purchases show $($script:PurchaseRows.Count) apps, expected 2 (iOS apps only, no duplicates)") }
            elseif (@($script:PurchaseRows | Where-Object { $_.Status -ne 'Unverified' }).Count -gt 0) { $errors.Add('scenario: offline lookup must give Unverified statuses') }
            $script:UI.PurSearch.Text = 'old'; $script:PurchaseQuery = 'old'; Update-PurchasesView
            if ($script:UI.PurGrid.Items.Count -ne 1) { $errors.Add("scenario: purchase search shows $($script:UI.PurGrid.Items.Count) rows") }
            $script:UI.PurSearch.Text = ''; Update-PurchasesView
            $p2 = $script:PurchaseById['2222222']
            Invoke-DreddPurchaseRowAction $p2
            if (-not (& $wait { $p2.Status -eq 'Downloaded' } 60000)) { $errors.Add("scenario: purchase row after download is '$($p2.Status)'") }
            $qp = $script:Queue | Where-Object { $_.AppId -eq '2222222' } | Select-Object -First 1
            if ($qp -and $qp.Purchase) { $errors.Add('scenario: purchased app downloaded with --purchase') }
            if ($Screenshot) { Save-DreddScreenshot (Join-Path $Screenshot 'Scenario_Purchases.png') }
            Show-DreddPage 'Catalog'
            $script:UI.SrcSearch.IsChecked = $true
            $script:UI.CatalogQuery.Text = 'Telegram'
            Start-DreddStoreSearch
            if (-not (& $wait { -not $script:CatalogTask -and @($script:StoreResults).Count -gt 0 })) { $errors.Add('scenario: store search failed') }
            $fake = $script:CatalogRows | Where-Object { $_.Id -eq '1234567' } | Select-Object -First 1
            if (-not $fake) { $errors.Add('scenario: App Store row missing in catalog') }
            else {
                $script:UI.CatalogGrid.SelectedItems.Clear(); [void]$script:UI.CatalogGrid.SelectedItems.Add($fake)
                Invoke-DreddCatalogDownload
                if (-not (& $wait { @($script:Queue | Where-Object { $_.Status -in 'Done', 'Error' }).Count -gt 0 } 60000)) { $errors.Add('scenario: download did not finish') }
                $q = $script:Queue | Select-Object -First 1
                if ($q.Status -ne 'Done') { $errors.Add("scenario: download status $($q.Status) $($q.Error)") }
                if (-not (& $wait { -not $script:LibraryTask -and @($script:LibraryRows | Where-Object { $_.AppStoreId -eq '1234567' }).Count -gt 0 })) { $errors.Add('scenario: library not refreshed') }
                if ($fake.StatusText -ne (T 'Catalog.InLibrary')) { $errors.Add("scenario: catalog status '$($fake.StatusText)'") }
                # Фильтр библиотеки (ICollectionView + предикат):
                Show-DreddPage 'Library'
                $script:UI.LibSearch.Text = 'zzz-no-match'; Wait-DreddUi 100
                if ($script:UI.LibGrid.Items.Count -ne 0) { $errors.Add("scenario: library filter shows $($script:UI.LibGrid.Items.Count) rows for a non-matching query") }
                $script:UI.LibSearch.Text = 'com.example'; Wait-DreddUi 100
                # Оба фейковых IPA (из «Покупок» и из «Поиска») имеют bundle id com.example.fake.
                if ($script:UI.LibGrid.Items.Count -ne $script:LibraryRows.Count) { $errors.Add("scenario: library filter by bundle id shows $($script:UI.LibGrid.Items.Count) rows") }
                if ($script:UI.DevIpaGrid.Items.Count -ne $script:LibraryRows.Count) { $errors.Add('scenario: library filter must not affect the devices page') }
                $script:UI.LibSearch.Text = ''
                # IPA с диска: внешний файл (без копирования) и импорт в библиотеку.
                $extDir = Join-Path ([System.IO.Path]::GetTempPath()) ('dredd_ext_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                [void][System.IO.Directory]::CreateDirectory($extDir)
                $extFile = Join-Path $extDir 'External.ipa'
                [System.IO.File]::Copy($q.FilePath, $extFile)
                Show-DreddPage 'Devices'
                Add-DreddExternalIpas @($extFile) -Select
                $extRow = $script:LibraryRows | Where-Object { $_.Path -eq $extFile } | Select-Object -First 1
                if (-not $extRow -or -not $extRow.IsExternal) { $errors.Add('scenario: external IPA not added') }
                elseif ($script:UI.DevIpaGrid.SelectedItems.Count -ne 1) { $errors.Add('scenario: external IPA not selected for install') }
                elseif (-not $extRow.SignText) { $errors.Add('scenario: signature text empty') }
                $script:UI.LibGrid.SelectedItems.Clear(); [void]$script:UI.LibGrid.SelectedItems.Add($extRow)
                Remove-DreddLibraryItems
                if (-not [System.IO.File]::Exists($extFile)) { $errors.Add('scenario: removing an external IPA deleted the user file!') }
                if (@($script:LibraryRows | Where-Object { $_.Path -eq $extFile }).Count -ne 0) { $errors.Add('scenario: external IPA not removed from list') }
                $before = $script:LibraryRows.Count
                Import-DreddIpaFiles @($extFile)
                if (-not (& $wait { -not $script:LibraryTask -and $script:LibraryRows.Count -eq $before + 1 } 20000)) { $errors.Add("scenario: import did not add a library row ($($script:LibraryRows.Count))") }
                Remove-Item -LiteralPath $extDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            # Отмена: медленная загрузка
            $env:FAKE_SLOW = '1'
            Add-DreddDownloadItem -AppId '7654321' -AppName 'Slow App' -Purchase $false
            [void](& $wait { $script:ActiveDownload -and $script:ActiveDownload.AppId -eq '7654321' } 10000)
            Wait-DreddUi 1500
            $slow = $script:Queue | Where-Object { $_.AppId -eq '7654321' } | Select-Object -First 1
            Stop-DreddDownloadItem $slow
            if (-not (& $wait { $slow.Status -eq 'Cancelled' } 15000)) { $errors.Add("scenario: cancel failed, status $($slow.Status)") }
            $env:FAKE_SLOW = $null
            Show-DreddPage 'Downloads'
            Wait-DreddUi 300
            if ($script:UI.DlHistoryGrid.Items.Count -lt 1) { $errors.Add('scenario: download history empty') }
            if ($Screenshot) { Wait-DreddUi 300; Save-DreddScreenshot (Join-Path $Screenshot 'Scenario_Downloads.png'); Show-DreddPage 'Library'; $script:UI.LibGrid.SelectedIndex = 0; Wait-DreddUi 300; Save-DreddScreenshot (Join-Path $Screenshot 'Scenario_Library.png') }
        }
        # «Скачать и установить» без инструментов устройств: понятное уведомление, а не тихий отказ.
        if ($TestIpatool -and -not $script:Ctx.Binaries.IdeviceInstaller -and $script:PurchaseRows.Count -gt 0) {
            Show-DreddPage 'Purchases'; Hide-DreddToast
            Invoke-DreddPurchaseInstall @($script:PurchaseRows[0])
            if ($script:UI.Toast.Visibility -ne 'Visible' -or $script:UI.ToastTitle.Text -ne (T 'Err.NoInstaller')) { $errors.Add("scenario: install without device tools shows '$($script:UI.ToastTitle.Text)'") }
            Hide-DreddToast
        }
        # «Скачать и установить» на фейковом устройстве: поиск iPhone → загрузка → установка → статусы и история.
        if ($TestIpatool -and $script:PurchaseById['1111111']) {
            $fx = Split-Path (Resolve-Path $TestIpatool).Path -Parent
            $script:Ctx.Binaries.IdeviceId = Join-Path $fx 'fake-idevice_id.cmd'
            $script:Ctx.Binaries.IdeviceInfo = Join-Path $fx 'fake-ideviceinfo.cmd'
            $script:Ctx.Binaries.IdeviceInstaller = Join-Path $fx 'fake-ideviceinstaller.cmd'
            $env:FAKE_INSTALL_LOG = Join-Path ([System.IO.Path]::GetTempPath()) ('dredd_install_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
            $old = $script:PurchaseById['1111111']
            Invoke-DreddPurchaseInstall @($old)
            if (-not (& $wait { @($script:DeviceRows).Count -gt 0 -and -not $script:DeviceScanTask } 20000)) { $errors.Add('scenario: fake device not found') }
            $qi = $null
            if (-not (& $wait { $script:qi = $script:Queue | Where-Object { $_.AppId -eq '1111111' } | Select-Object -First 1; $script:qi -and $script:qi.Status -in 'Installed', 'InstallError', 'Error' } 60000)) { $errors.Add("scenario: download+install did not finish ($($script:qi.Status))") }
            elseif ($script:qi.Status -ne 'Installed') { $errors.Add("scenario: download+install ended with $($script:qi.Status): $($script:qi.Error)") }
            elseif (-not ([System.IO.File]::Exists($env:FAKE_INSTALL_LOG) -and [System.IO.File]::ReadAllText($env:FAKE_INSTALL_LOG) -match '00008110-000A1B2C3D4E5F60 install')) { $errors.Add('scenario: ideviceinstaller not called for the device') }
            if (@(Get-DreddDownloadHistory -Context $script:Ctx | Where-Object { $_.Kind -eq 'Install' -and $_.Target -eq 'Test iPhone' }).Count -lt 1) { $errors.Add('scenario: install not in history') }
            if ($Screenshot) { Show-DreddPage 'Downloads'; Wait-DreddUi 300; Save-DreddScreenshot (Join-Path $Screenshot 'Scenario_Install.png') }
            Remove-Item -LiteralPath $env:FAKE_INSTALL_LOG -ErrorAction SilentlyContinue; $env:FAKE_INSTALL_LOG = $null
            Hide-DreddToast
            # «Сравнить с iPhone»: список приложений устройства (XML с App Store ID) → вкладка «Нет на iPhone».
            Show-DreddPage 'Purchases'
            Start-DreddDeviceAppsScan
            if (-not (& $wait { -not $script:DeviceAppsTask -and $script:DeviceCompare } 30000)) { $errors.Add('scenario: device apps scan failed') }
            else {
                $n1 = $script:PurchaseById['1111111']; $n2 = $script:PurchaseById['2222222']
                if ($n2.DeviceState -ne 'Installed') { $errors.Add("scenario: app with App Store ID on the device is '$($n2.DeviceState)'") }
                if ($n1.DeviceState -ne 'Missing') { $errors.Add("scenario: app missing on the device is '$($n1.DeviceState)'") }
                if (-not $script:UI.PurTabNotOnDevice.IsChecked -or $script:UI.PurGrid.Items.Count -ne 1) { $errors.Add("scenario: 'Not on iPhone' tab shows $($script:UI.PurGrid.Items.Count) rows") }
                if ($script:PurDeviceColumn.Visibility -ne 'Visible') { $errors.Add('scenario: On iPhone column hidden') }
                if ($Screenshot) { Wait-DreddUi 300; Save-DreddScreenshot (Join-Path $Screenshot 'Scenario_DeviceCompare.png') }
                Set-DreddDeviceAppInstalled -AppId '1111111' -Udid '00008110-000A1B2C3D4E5F60' -Version '2.5.1'
                if ($n1.DeviceState -ne 'Installed') { $errors.Add("scenario: installed app still '$($n1.DeviceState)'") }
                $script:UI.PurTabAll.IsChecked = $true
            }
            Hide-DreddToast
            # Wi-Fi: второе устройство только по сети.
            $env:FAKE_WIFI_DEVICE = '1'
            Start-DreddDeviceScan
            [void](& $wait { -not $script:DeviceScanTask } 20000)
            $wifi = $script:DeviceRows | Where-Object { $_.Connection -eq 'network' } | Select-Object -First 1
            if (-not $wifi -or $wifi.ConnectionText -ne (T 'Device.Conn.network') -or $wifi.Name -ne 'Test iPad') { $errors.Add('scenario: Wi-Fi device not shown') }
            if ($Screenshot) { Show-DreddPage 'Devices'; Wait-DreddUi 300; Save-DreddScreenshot (Join-Path $Screenshot 'Scenario_WiFi.png') }
            $env:FAKE_WIFI_DEVICE = $null
        }
        # Уведомление о готовности (как после тихой проверки при запуске):
        Set-DreddLanguage 'RU'; Show-DreddPage 'Purchases'
        Show-DreddToast -Kind Success -Title (T 'Update.AllGood') -Text (Get-DreddReadyText ([pscustomobject]@{ Current = '4.3.3' }))
        Wait-DreddUi 300
        if ($Screenshot) { Save-DreddScreenshot (Join-Path $Screenshot 'Toast_Ready.png') }
        if ($script:UI.Toast.Visibility -ne 'Visible') { $errors.Add('toast not shown') }
        Hide-DreddToast
        # Непереведённые элементы (текст совпадает с ключом):
        foreach ($lang in 'RU', 'EN') {
            Set-DreddLanguage $lang
            foreach ($e in $script:LocEntries) {
                if (-not $script:Strings.ContainsKey($e.Key)) { $errors.Add("missing $lang key: $($e.Key)") }
            }
        }
    } finally {
        $script:ForceClose = $true
        $script:Window.Close()
        Close-DreddTaskRunner -WaitMs 2000
    }
    $uiErrors = @($script:LogLines | Where-Object { $_.Level -eq 'Error' -and $_.Line -match '\[UI\]|\[Task\]' })
    foreach ($u in $uiErrors) { $errors.Add($u.Line) }
    if ($errors.Count -gt 0) {
        Write-Output "SELFTEST FAILED ($($errors.Count))"
        $errors | Select-Object -Unique | ForEach-Object { Write-Output " - $_" }
        exit 1
    }
    Write-Output ("SELFTEST OK: {0} pages x 2 themes x 2 languages, {1} localized elements, library {2} IPA" -f $script:Pages.Count, $script:LocEntries.Count, $script:LibraryRows.Count)
    exit 0
}

# ---- Обычный запуск ----
if (-not $NoBackground) {
    $script:Window.Add_ContentRendered({
        Safe {
            Start-DreddAccountRefresh -Silent
            Start-DreddLibraryRefresh
            if ($script:Ctx.Binaries.IdeviceId) { Start-DreddDeviceScan }
            if (ConvertTo-DreddBool $script:Ctx.Settings['UpdateListsOnStartup']) { Start-DreddListsUpdate -Silent }
            # Тихая проверка обновлений — чуть позже, чтобы в итоговом уведомлении уже был статус Apple ID.
            # Без компонентов (первый запуск portable-версии) проверка нужна всегда — она предложит их загрузить.
            if ((ConvertTo-DreddBool $script:Ctx.Settings['CheckUpdatesOnStartup']) -or -not $script:Ctx.Binaries.Ipatool) {
                $script:StartupCheckTimer = New-Object System.Windows.Threading.DispatcherTimer
                $script:StartupCheckTimer.Interval = [TimeSpan]::FromSeconds(2)
                $script:StartupCheckTimer.Add_Tick({ $script:StartupCheckTimer.Stop(); Safe { Start-DreddUpdateCheck -Startup } })
                $script:StartupCheckTimer.Start()
            }
        }
    })
}

try {
    [void]$script:Window.ShowDialog()
} finally {
    Close-DreddTaskRunner
}

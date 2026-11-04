# Инфраструктура GUI: загрузка XAML, локализация, темы, журнал, диалоги, навигация.

$script:GuiRoot = $PSScriptRoot
$script:UI = @{}
$script:LocEntries = New-Object System.Collections.Generic.List[object]
$script:Strings = @{}
$script:LogLines = New-Object System.Collections.Generic.List[object]
$script:ThemeCache = @{}
$script:CurrentPage = 'Purchases'
$script:Pages = @('Purchases', 'Catalog', 'Downloads', 'Library', 'Devices', 'Accounts', 'Settings', 'Diagnostics')

function Initialize-DreddApplication {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms
    if (-not ('IPADredd.Gui.QueueItem' -as [type])) {
        # PurchaseRow загружает иконки (BitmapImage) — нужны сборки WPF.
        $refs = @([System.Windows.Media.ImageSource].Assembly.Location, [System.Windows.DependencyObject].Assembly.Location, [System.Xaml.XamlReader].Assembly.Location, 'System.Xml')
        Add-Type -TypeDefinition ([System.IO.File]::ReadAllText((Join-Path $script:GuiRoot 'Native/ViewModels.cs'))) -Language CSharp -ReferencedAssemblies $refs -ErrorAction Stop
    }
    $app = [System.Windows.Application]::Current
    if (-not $app) {
        $app = New-Object System.Windows.Application
        $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
    }
    $script:App = $app
    $app.Resources.MergedDictionaries.Clear()
    $app.Resources.MergedDictionaries.Add((Get-DreddThemeDictionary 'Dark'))
    $app.Resources.MergedDictionaries.Add((Import-DreddXaml (Join-Path $script:GuiRoot 'Themes/Styles.xaml')))
}

function Import-DreddXaml {
    param([string]$Path)
    return [System.Windows.Markup.XamlReader]::Parse([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
}

function Get-DreddThemeDictionary {
    param([ValidateSet('Dark', 'Light')][string]$Name)
    if (-not $script:ThemeCache.ContainsKey($Name)) {
        $script:ThemeCache[$Name] = Import-DreddXaml (Join-Path $script:GuiRoot "Themes/$Name.xaml")
    }
    return $script:ThemeCache[$Name]
}

function Set-DreddTheme {
    param([ValidateSet('Dark', 'Light')][string]$Name)
    $script:App.Resources.MergedDictionaries[0] = Get-DreddThemeDictionary $Name
}

function New-DreddWindow {
    # Загружает окно из XAML и складывает именованные элементы в $script:UI (или в переданный словарь).
    param([string]$Path, [hashtable]$Into = $script:UI)
    $xamlText = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $window = [System.Windows.Markup.XamlReader]::Parse($xamlText)
    foreach ($m in [regex]::Matches($xamlText, 'x:Name="([A-Za-z0-9_]+)"')) {
        $el = $window.FindName($m.Groups[1].Value)
        if ($null -ne $el) { $Into[$m.Groups[1].Value] = $el }
    }
    return $window
}

# ---------------- Локализация ----------------

function T {
    param([string]$Key)
    if ($script:Strings.ContainsKey($Key)) { return $script:Strings[$Key] }
    return $Key
}

function TF {
    param([string]$Key, [object[]]$Values)
    $fmt = T $Key
    try { return [string]::Format([System.Globalization.CultureInfo]::CurrentCulture, $fmt, $Values) } catch { return $fmt }
}

function Register-DreddLocalization {
    # Собирает элементы с x:Uid, заголовки колонок "@Key" и подсказки Tag="@Key".
    param([System.Windows.DependencyObject]$Root)
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    $seen = New-Object 'System.Collections.Generic.HashSet[object]'
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if (-not $seen.Add($node)) { continue }
        if ($node -is [System.Windows.UIElement] -and $node.Uid) {
            $script:LocEntries.Add([pscustomobject]@{ Element = $node; Kind = 'Uid'; Key = $node.Uid })
        }
        if ($node -is [System.Windows.FrameworkElement] -and ($node.ToolTip -is [string]) -and $node.ToolTip.StartsWith('@')) {
            $script:LocEntries.Add([pscustomobject]@{ Element = $node; Kind = 'ToolTip'; Key = $node.ToolTip.Substring(1) })
        }
        if ($node -is [System.Windows.Controls.TextBox] -and ($node.Tag -is [string]) -and $node.Tag.StartsWith('@')) {
            $script:LocEntries.Add([pscustomobject]@{ Element = $node; Kind = 'Tag'; Key = $node.Tag.Substring(1) })
        }
        if ($node -is [System.Windows.Controls.DataGrid]) {
            foreach ($col in $node.Columns) {
                if (($col.Header -is [string]) -and $col.Header.StartsWith('@')) {
                    $script:LocEntries.Add([pscustomobject]@{ Element = $col; Kind = 'Header'; Key = $col.Header.Substring(1) })
                }
            }
        }
        # Контекстное меню не входит в логическое дерево элемента — обходим его отдельно.
        if ($node -is [System.Windows.FrameworkElement] -and $node.ContextMenu) { $stack.Push($node.ContextMenu) }
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($node)) {
            if ($child -is [System.Windows.DependencyObject]) { $stack.Push($child) }
        }
    }
}

function Set-DreddLanguage {
    param([ValidateSet('RU', 'EN')][string]$Language)
    $script:Strings = Get-DreddStrings -Language $Language
    $culture = if ($Language -eq 'RU') { 'ru-RU' } else { 'en-US' }
    try { [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture) } catch { }
    foreach ($e in $script:LocEntries) {
        $text = T $e.Key
        switch ($e.Kind) {
            'Uid' {
                $el = $e.Element
                if ($el -is [System.Windows.Controls.TextBlock]) { $el.Text = $text }
                elseif ($el -is [System.Windows.Controls.ContentControl]) { $el.Content = $text }
                elseif ($el -is [System.Windows.Controls.HeaderedItemsControl]) { $el.Header = $text }
            }
            'Tag' { $e.Element.Tag = $text }
            'ToolTip' { $e.Element.ToolTip = $text }
            'Header' { $e.Element.Header = $text }
        }
    }
}

# ---------------- Журнал ----------------

function Add-DreddLog {
    param(
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')][string]$Level = 'Info',
        [string]$Area = 'App',
        [string]$Message,
        [switch]$NoFile
    )
    if ([string]::IsNullOrEmpty($Message)) { return }
    $Message = Protect-LogText $Message
    $tag = switch ($Level) { 'Success' { 'OK' } 'Warning' { 'WARN' } 'Error' { 'ERROR' } 'Debug' { 'DEBUG' } default { 'INFO' } }
    $line = Format-DreddLogLine -Level $tag -Area $Area -Message $Message
    if (-not $NoFile -and $script:Ctx) { Write-DreddLogFile -LogsDir $script:Ctx.LogsDir -Line $line }
    $isDebugOn = $script:Ctx -and (ConvertTo-DreddBool $script:Ctx.Settings['DebugEnabled'])
    if ($Level -eq 'Debug' -and -not $isDebugOn) { return }
    $entry = [pscustomobject]@{ Level = $Level; Line = $line }
    $script:LogLines.Add($entry)
    if ($null -eq $script:UI['LogBox']) { return }
    if ($script:LogLines.Count -gt 5000) {
        $script:LogLines.RemoveRange(0, 1000)
        Update-DreddLogView
    } elseif (-not $script:UI.LogErrorsOnly.IsChecked -or $Level -in 'Error', 'Warning') {
        $script:UI.LogBox.AppendText($line + "`r`n")
        $script:UI.LogBox.ScrollToEnd()
    }
    if ($Level -ne 'Debug') { $script:UI.LogLastLine.Text = $line }
}

function Update-DreddLogView {
    $errorsOnly = [bool]$script:UI.LogErrorsOnly.IsChecked
    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $script:LogLines) {
        if ($errorsOnly -and $e.Level -notin 'Error', 'Warning') { continue }
        [void]$sb.AppendLine($e.Line)
    }
    $script:UI.LogBox.Text = $sb.ToString()
    $script:UI.LogBox.ScrollToEnd()
}

function Write-DreddUiError {
    param($ErrorRecord, [string]$Area = 'UI')
    $msg = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        "$($ErrorRecord.Exception.Message) @ $($ErrorRecord.InvocationInfo.ScriptName | Split-Path -Leaf):$($ErrorRecord.InvocationInfo.ScriptLineNumber)"
    } else { "$ErrorRecord" }
    Add-DreddLog -Level Error -Area $Area -Message $msg
}

function Safe {
    # Обёртка для обработчиков событий: исключение пишется в журнал, а не роняет окно.
    param([scriptblock]$Block)
    try { . $Block } catch { Write-DreddUiError $_ }
}

# ---------------- Диалоги ----------------

function Show-DreddDialog {
    <#
      -Buttons: массив @{ Key = 'yes'; Text = '...'; Kind = 'Primary'|'Danger'|'' }. Возвращает Key нажатой кнопки или $null.
    #>
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Question', 'Success')][string]$Kind = 'Info',
        [object[]]$Buttons
    )
    if ($script:SelfTestMode) { Add-DreddLog -Level Info -Area 'Dialog' -Message "$Title — $Message"; return $null }
    if (-not $Buttons) { $Buttons = @(@{ Key = 'ok'; Text = (T 'Common.OK'); Kind = 'Primary' }) }
    $ui = @{}
    $dlg = New-DreddWindow -Path (Join-Path $script:GuiRoot 'Dialog.xaml') -Into $ui
    $dlg.Title = 'IPA PILOTDREDD'
    if ($script:Window -and $script:Window.Icon) { $dlg.Icon = $script:Window.Icon }
    if ($script:Window -and $script:Window.IsVisible) { $dlg.Owner = $script:Window }
    $ui.DlgTitle.Text = $Title
    $ui.DlgMessage.Text = $Message
    if ([string]::IsNullOrEmpty($Message)) { $ui.DlgMessage.Visibility = 'Collapsed' }
    $glyph = @{ Info = [char]0xE946; Warning = [char]0xE7BA; Error = [char]0xEA39; Question = [char]0xE9CE; Success = [char]0xE930 }[$Kind]
    $brushKey = @{ Info = 'Brush.Accent'; Warning = 'Brush.Warning'; Error = 'Brush.Danger'; Question = 'Brush.Accent'; Success = 'Brush.Success' }[$Kind]
    $ui.DlgIcon.Text = [string]$glyph
    $ui.DlgIcon.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $brushKey)
    $script:DialogResult = $null
    foreach ($b in $Buttons) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $b.Text
        $btn.Tag = $b.Key
        $btn.MinWidth = 96
        $btn.Margin = '8,0,0,0'
        if ($b.Kind -eq 'Primary') { $btn.Style = $script:App.Resources['PrimaryButton']; $btn.IsDefault = $true }
        elseif ($b.Kind -eq 'Danger') { $btn.Style = $script:App.Resources['DangerButton'] }
        if ($b.Key -in 'cancel', 'no') { $btn.IsCancel = $true }
        $btn.Add_Click({ param($s, $e) $script:DialogResult = $s.Tag; [System.Windows.Window]::GetWindow($s).Close() })
        [void]$ui.DlgButtons.Children.Add($btn)
    }
    [void]$dlg.ShowDialog()
    return $script:DialogResult
}

function Show-DreddToast {
    <#
      Неблокирующее уведомление в правом нижнем углу. -Action — скриптблок кнопки ActionText;
      -AutoHideMs — скрыть через N мс (0 — пока не закроют). -Progress — показать полосу (значение задаёт Set-DreddToastProgress).
    #>
    param(
        [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Kind = 'Info',
        [string]$Title, [string]$Text, [string]$ActionText, [scriptblock]$Action, [int]$AutoHideMs = 0, [switch]$Progress, [switch]$NoLater,
        # -Low: информационное — не заменяет видимое уведомление, которое ждёт ответа (кнопка действия).
        [switch]$Low
    )
    $u = $script:UI
    if (-not $u['Toast']) { return }
    if ($Low -and $u.Toast.Visibility -eq 'Visible' -and $script:ToastAction) {
        Add-DreddLog -Level Info -Area 'Notice' -Message (("{0}. {1}" -f $Title, $Text) -replace '\r?\n', ' · ').Trim(' ', '.')
        return
    }
    if ($script:ToastTimer) { $script:ToastTimer.Stop() }
    $glyph = @{ Info = [char]0xE946; Warning = [char]0xE7BA; Error = [char]0xEA39; Success = [char]0xE930 }[$Kind]
    $brush = @{ Info = 'Brush.Accent'; Warning = 'Brush.Warning'; Error = 'Brush.Danger'; Success = 'Brush.Success' }[$Kind]
    $u.ToastIcon.Text = [string]$glyph
    $u.ToastIcon.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $brush)
    $u.ToastTitle.Text = $Title
    $u.ToastText.Text = $Text
    $u.ToastText.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
    $u.ToastProgress.Visibility = if ($Progress) { 'Visible' } else { 'Collapsed' }
    $u.ToastProgress.IsIndeterminate = [bool]$Progress
    $script:ToastAction = $Action
    $u.ToastAction.Content = $ActionText
    $u.ToastAction.Visibility = if ($ActionText -and $Action) { 'Visible' } else { 'Collapsed' }
    $u.ToastLater.Visibility = if ($ActionText -and $Action -and -not $NoLater) { 'Visible' } else { 'Collapsed' }
    $u.ToastButtons.Visibility = if ($ActionText -and $Action) { 'Visible' } else { 'Collapsed' }
    $u.Toast.Visibility = 'Visible'
    Add-DreddLog -Level $(if ($Kind -eq 'Success') { 'Success' } elseif ($Kind -eq 'Info') { 'Info' } else { $Kind }) -Area 'Notice' -Message (("{0}. {1}" -f $Title, $Text) -replace '\r?\n', ' · ').Trim(' ', '.')
    if ($AutoHideMs -gt 0) {
        if (-not $script:ToastTimer) {
            $script:ToastTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:ToastTimer.Add_Tick({ $script:ToastTimer.Stop(); Hide-DreddToast })
        }
        $script:ToastTimer.Interval = [TimeSpan]::FromMilliseconds($AutoHideMs)
        $script:ToastTimer.Start()
    }
}

function Set-DreddToastProgress {
    param($Percent, [string]$Text)
    $u = $script:UI
    if ($null -ne $Percent) { $u.ToastProgress.IsIndeterminate = $false; $u.ToastProgress.Value = [double]$Percent }
    if ($Text) { $u.ToastText.Text = $Text; $u.ToastText.Visibility = 'Visible' }
}

function Hide-DreddToast {
    if ($script:ToastTimer) { $script:ToastTimer.Stop() }
    if ($script:UI['Toast']) { $script:UI.Toast.Visibility = 'Collapsed' }
    $script:ToastAction = $null
}

function Initialize-DreddToast {
    $u = $script:UI
    $u.ToastClose.Add_Click({ Safe { Hide-DreddToast } })
    $u.ToastLater.Add_Click({ Safe { Hide-DreddToast } })
    $u.ToastAction.Add_Click({ Safe { $a = $script:ToastAction; Hide-DreddToast; if ($a) { & $a } } })
    # Наведение мыши останавливает автоскрытие, чтобы уведомление можно было дочитать.
    $u.Toast.Add_MouseEnter({ if ($script:ToastTimer) { $script:ToastTimer.Stop() } })
}

function Confirm-Dredd {
    param([string]$Title, [string]$Message, [string]$YesText = (T 'Common.Yes'), [switch]$Danger, [ValidateSet('Warning', 'Question')][string]$Kind = 'Question')
    $yesKind = if ($Danger) { 'Danger' } else { 'Primary' }
    $r = Show-DreddDialog -Title $Title -Message $Message -Kind $Kind -Buttons @(
        @{ Key = 'cancel'; Text = (T 'Common.Cancel'); Kind = '' },
        @{ Key = 'yes'; Text = $YesText; Kind = $yesKind }
    )
    return ($r -eq 'yes')
}

function Select-DreddFolder {
    param([string]$Description, [string]$Initial)
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $Description
    $d.ShowNewFolderButton = $true
    if ($Initial -and [System.IO.Directory]::Exists($Initial)) { $d.SelectedPath = $Initial }
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    return $null
}

function Open-DreddPath {
    param([string]$Path, [switch]$Select)
    if ([string]::IsNullOrEmpty($Path)) { return }
    if ($Select -and [System.IO.File]::Exists($Path)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$Path`""; return }
    if ([System.IO.Directory]::Exists($Path)) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Path`"" }
}

function Open-DreddUrl {
    param([string]$Url)
    if ($Url -notmatch '^https://') { return }
    Start-Process -FilePath $Url
}

# ---------------- Форматирование ----------------

function Format-DreddSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} {1}' -f ($Bytes / 1GB), (T 'Unit.GB')) }
    if ($Bytes -ge 1MB) { return ('{0:N1} {1}' -f ($Bytes / 1MB), (T 'Unit.MB')) }
    if ($Bytes -ge 1KB) { return ('{0:N0} {1}' -f ($Bytes / 1KB), (T 'Unit.KB')) }
    return ('{0:N0} {1}' -f $Bytes, (T 'Unit.B'))
}

function Get-DreddErrorText {
    # Ключ ошибки Core (Err.*) → понятный текст + исходное сообщение ipatool (если есть).
    param([string]$Key, [string]$Message)
    if (-not $Key) { $Key = 'Err.Unknown' }
    $text = T $Key
    if ($text -eq $Key) { $text = T 'Err.Unknown' }
    if ($Message -and $Key -notin 'Err.Cancelled') { $text = "$text ($Message)" }
    return $text
}

# ---------------- Навигация ----------------

function Show-DreddPage {
    param([ValidateSet('Purchases', 'Catalog', 'Downloads', 'Library', 'Devices', 'Accounts', 'Settings', 'Diagnostics')][string]$Name)
    foreach ($p in $script:Pages) {
        $script:UI["Page$p"].Visibility = if ($p -eq $Name) { 'Visible' } else { 'Collapsed' }
    }
    if (-not $script:UI["Nav$Name"].IsChecked) { $script:UI["Nav$Name"].IsChecked = $true }
    $script:CurrentPage = $Name
    Update-DreddPageHeader
    $handler = "Show-${Name}Page"
    if (Get-Command $handler -ErrorAction SilentlyContinue) { & $handler }
}

function Update-DreddPageHeader {
    $script:UI.PageTitle.Text = T "Page.$($script:CurrentPage).Title"
    $script:UI.PageSubtitle.Text = T "Page.$($script:CurrentPage).Subtitle"
}

function Test-DreddLoggedIn {
    # Для действий App Store. Если входа нет — предлагает перейти в «Аккаунты».
    if ($script:Account -and $script:Account.Success) { return $true }
    if (-not $script:Ctx.Binaries.Ipatool) {
        [void](Show-DreddDialog -Title (T 'Err.NoIpatool') -Message (T 'Diag.Hint.Ipatool') -Kind Error)
        return $false
    }
    $r = Show-DreddDialog -Title (T 'Login.RequiredTitle') -Message (T 'Login.RequiredText') -Kind Info -Buttons @(
        @{ Key = 'cancel'; Text = (T 'Common.Cancel') }, @{ Key = 'go'; Text = (T 'Login.GoToAccounts'); Kind = 'Primary' })
    if ($r -eq 'go') { Show-DreddPage 'Accounts' }
    return $false
}

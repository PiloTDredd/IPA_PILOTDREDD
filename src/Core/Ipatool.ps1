# Обёртка над ipatool-cpp. Все вызовы идут через Invoke-DreddProcess (маскирование, отмена, таймаут).

$script:ReAuthCode = New-Object System.Text.RegularExpressions.Regex('(?i)(2fa|two[- ]factor|auth(entication)?[- ]?code|verification code|security code|-a CODE)', 'Compiled')

function Get-DreddPassphraseFile { param($Context) Join-Path $Context.IpatoolHome 'keychain-passphrase' }

function Get-DreddPassphrase {
    # Возвращает passphrase из ~/.ipatool/keychain-passphrase (DPAPI, Windows) или $null.
    param([Parameter(Mandatory)]$Context)
    if ($Context.PassphraseMode -eq 'none') { return $null }
    if (-not $Context.Platform.IsWindows) { return $null }
    $file = Get-DreddPassphraseFile $Context
    if (-not [System.IO.File]::Exists($file)) { return $null }
    try {
        $enc = ([System.IO.File]::ReadAllText($file)).Trim()
        if (-not $enc) { return $null }
        $secure = ConvertTo-SecureString -String $enc -ErrorAction Stop
        return [System.Net.NetworkCredential]::new('', $secure).Password
    } catch {
        return $null
    }
}

function New-DreddPassphrase {
    # Создаёт и СНАЧАЛА сохраняет (DPAPI) новый passphrase — исправление G3 прототипа. Только Windows.
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Platform.IsWindows) { return $null }
    if (-not [System.IO.Directory]::Exists($Context.IpatoolHome)) { [void][System.IO.Directory]::CreateDirectory($Context.IpatoolHome) }
    $kp = [guid]::NewGuid().ToString('N')
    $enc = ConvertTo-SecureString -String $kp -AsPlainText -Force | ConvertFrom-SecureString
    Write-DreddTextFile -Path (Get-DreddPassphraseFile $Context) -Content $enc
    $Context.PassphraseMode = 'auto'
    return $kp
}

function ConvertFrom-DreddToolJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $lines = @(($script:ReAnsi.Replace($Text, '')) -split "`r?`n")
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $l = $lines[$i].Trim()
        if ($l.StartsWith('{') -or $l.StartsWith('[')) {
            try { return ($l | ConvertFrom-Json -ErrorAction Stop) } catch { }
        }
    }
    # Текстовый режим ipatool: "HH:mm:ss INF apps=[...] count=N"
    $m = [regex]::Match($Text, '(?m)\bapps=(\[.*\])')
    if ($m.Success) {
        try { return [pscustomobject]@{ apps = ($m.Groups[1].Value | ConvertFrom-Json -ErrorAction Stop) } } catch { }
    }
    return $null
}

function Test-DreddNeedsAuthCode {
    param([string]$Output)
    if ([string]::IsNullOrEmpty($Output)) { return $false }
    return $script:ReAuthCode.IsMatch($Output)
}

function Resolve-DreddToolError {
    <#
      Переводит ответ ipatool в ключ подсказки (Err.*) и короткое сообщение. Тексты ipatool проверены не для всех
      сценариев (см. docs/ARCHITECTURE.md §6): неизвестный ответ возвращается как Err.Unknown с исходным текстом.
    #>
    param([string]$Output, [int]$ExitCode = 1)
    $clean = Protect-LogText -Text $Output
    $lines = @($clean -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $msgLine = $lines | Where-Object { $_ -match '(?i)\b(error|err|failed|fail)\b' } | Select-Object -Last 1
    if (-not $msgLine) { $msgLine = $lines | Select-Object -Last 1 }
    if (-not $msgLine) { $msgLine = "exit code $ExitCode" }
    if ($msgLine.Length -gt 400) { $msgLine = $msgLine.Substring(0, 400) + '…' }

    $key = 'Err.Unknown'
    if ($script:ReAuthCode.IsMatch($clean)) { $key = 'Err.AuthCode' }
    elseif ($clean -match '(?i)(decrypt|passphrase|keychain)') { $key = 'Err.Passphrase' }
    elseif ($clean -match '(?i)(not logged in|no (saved )?account|login required|please (log|sign) ?in|unauthori[sz]ed|token.*expired|session.*expired)') { $key = 'Err.NotLoggedIn' }
    elseif ($clean -match '(?i)(badlogin|incorrect|invalid (credentials|password|apple id)|wrong password|password.*(invalid|incorrect))') { $key = 'Err.BadCredentials' }
    elseif ($clean -match '(?i)(license|not purchased|purchase required|you (have|do) not (own|purchased)|STDQ|item not found in purchases|needs? (to be )?purchased)') { $key = 'Err.License' }
    elseif ($clean -match '(?i)temporarily unavailable') { $key = 'Err.Unavailable' }
    elseif ($clean -match '(?i)(not available in|storefront|region|country)') { $key = 'Err.Region' }
    elseif ($clean -match '(?i)(could not resolve|timed? ?out|connection|network|ssl|tls|curl|unreachable|socket)') { $key = 'Err.Network' }
    elseif ($clean -match '(?i)(paid app|price)') { $key = 'Err.Paid' }
    [pscustomobject]@{ Key = $key; Message = $msgLine }
}

function Invoke-DreddIpatool {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$Json,
        $Reporter,
        $CancellationToken,
        [int]$TimeoutSec = 120,
        [string[]]$SecretValues = @(),
        [string]$Area = 'ipatool',
        [scriptblock]$OnLine,
        [scriptblock]$OnTick,
        [string]$WorkingDirectory,
        [switch]$NoPassphrase,
        [string]$Passphrase,
        # Не писать вывод в журнал (auth info/login: там имя владельца аккаунта и прочие личные данные).
        [switch]$QuietOutput
    )
    $exe = $Context.Binaries.Ipatool
    if (-not $exe -or -not [System.IO.File]::Exists($exe)) { throw (New-Object System.IO.FileNotFoundException('ipatool not found')) }

    $args2 = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Arguments) { $args2.Add($a) }
    if ($Json) { $args2.Add('--format'); $args2.Add('json') }
    $kp = $null
    if (-not $NoPassphrase) {
        if ($PSBoundParameters.ContainsKey('Passphrase')) { $kp = $Passphrase } else { $kp = Get-DreddPassphrase -Context $Context }
    }
    if (-not [string]::IsNullOrEmpty($kp)) {
        $args2.Add('--keychain-passphrase'); $args2.Add($kp)
        $SecretValues = @($SecretValues) + $kp
    }
    if (ConvertTo-DreddBool $Context.Settings['DebugEnabled']) { $args2.Add('--debug') }

    if (-not $WorkingDirectory) {
        $WorkingDirectory = $Context.TempRoot
        if (-not [System.IO.Directory]::Exists($WorkingDirectory)) { [void][System.IO.Directory]::CreateDirectory($WorkingDirectory) }
    }
    $sep = [System.IO.Path]::PathSeparator
    $envVars = @{ PATH = ($Context.Binaries.Root + $sep + [Environment]::GetEnvironmentVariable('PATH')) }

    if (-not $OnLine -and $QuietOutput) { $OnLine = { param($line, $stream) } }
    if (-not $OnLine) {
        # Без GetNewClosure: скриптблок видит переменные этой функции через динамическую область видимости
        # (он вызывается из Invoke-DreddProcess, ниже по стеку), и остаётся в сессии модуля.
        $dreddLineReporter = $Reporter; $dreddLineSecrets = $SecretValues; $dreddLineArea = $Area
        $OnLine = {
            param($line, $stream)
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-DreddReport -Reporter $dreddLineReporter -Type log -Level Debug -Area $dreddLineArea -Message $line -SecretValues $dreddLineSecrets
            }
        }
    }

    $res = Invoke-DreddProcess -FilePath $exe -ArgumentList $args2.ToArray() -WorkingDirectory $WorkingDirectory `
        -TimeoutSec $TimeoutSec -CancellationToken $CancellationToken -OnLine $OnLine -OnTick $OnTick `
        -Environment $envVars -SecretValues $SecretValues
    Write-DreddReport -Reporter $Reporter -Type log -Level Debug -Area $Area -Message ("{0} → exit {1} ({2:N1} s)" -f $res.CommandLine, $res.ExitCode, $res.Duration.TotalSeconds)

    $jsonObj = $null
    if ($Json) { $jsonObj = ConvertFrom-DreddToolJson -Text $res.StdOut; if ($null -eq $jsonObj) { $jsonObj = ConvertFrom-DreddToolJson -Text $res.Output } }
    $err = $null
    if (-not $res.Success) {
        if ($res.Cancelled) { $err = [pscustomobject]@{ Key = 'Err.Cancelled'; Message = 'Cancelled' } }
        elseif ($res.TimedOut) { $err = [pscustomobject]@{ Key = 'Err.Timeout'; Message = "Timeout ($TimeoutSec s)" } }
        else { $err = Resolve-DreddToolError -Output $res.Output -ExitCode $res.ExitCode }
    } elseif ($Json -and $jsonObj -and ($jsonObj.PSObject.Properties['success']) -and -not $jsonObj.success) {
        $err = Resolve-DreddToolError -Output $res.Output -ExitCode 1
    }
    $res | Add-Member -NotePropertyName Json -NotePropertyValue $jsonObj -Force
    $res | Add-Member -NotePropertyName Error -NotePropertyValue $err -Force
    $res | Add-Member -NotePropertyName Ok -NotePropertyValue ($null -eq $err) -Force
    return $res
}

function Get-DreddAuthInfo {
    <#
      Проверка сессии: auth info. Если с passphrase не получилось, пробуем без неё (сессия 4.2 с KeychainEnabled=False).
      Возвращает Success, Email, Name, Storefront, ErrorKey.
    #>
    param([Parameter(Mandatory)]$Context, $Reporter, $CancellationToken)
    $empty = [pscustomobject]@{ Success = $false; Email = $null; Name = $null; Storefront = $null; ErrorKey = 'Err.NotLoggedIn'; HasSessionFiles = $false }
    $accountFile = Join-Path $Context.IpatoolHome 'account'
    $empty.HasSessionFiles = [System.IO.File]::Exists($accountFile)
    if (-not $Context.Binaries.Ipatool) { $empty.ErrorKey = 'Err.NoIpatool'; return $empty }
    if (-not $empty.HasSessionFiles) { return $empty }

    $attempts = @($false)
    if ($Context.PassphraseMode -ne 'none' -and (Get-DreddPassphrase -Context $Context)) { $attempts = @($false, $true) }
    foreach ($noKp in $attempts) {
        $r = Invoke-DreddIpatool -Context $Context -Arguments @('auth', 'info') -Json -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 30 -Area 'Account' -NoPassphrase:$noKp -QuietOutput
        $j = $r.Json
        $ok = $r.ExitCode -eq 0 -and $j -and (Get-DreddProp $j 'success' $false)
        if (-not $ok -and $r.ExitCode -eq 0 -and -not $j) {
            # Текстовый вывод (старый ipatool): "... email=... success=true"
            $plain = $script:ReAnsi.Replace($r.Output, '')
            if ($plain -match 'success=true') {
                $ok = $true
                $j = [pscustomobject]@{
                    email = if ($plain -match 'email=(\S+)') { $Matches[1] } else { $null }
                    name = if ($plain -match 'name=(.+?)\s+storefront=') { $Matches[1] } else { $null }
                    storefront = if ($plain -match 'storefront=(\S+)') { $Matches[1] } else { $null }
                }
            }
        }
        if ($ok) {
            if ($noKp) { $Context.PassphraseMode = 'none' }
            return [pscustomobject]@{
                Success = $true; Email = [string](Get-DreddProp $j 'email'); Name = [string](Get-DreddProp $j 'name')
                Storefront = [string](Get-DreddProp $j 'storefront'); ErrorKey = $null; HasSessionFiles = $true
            }
        }
        if ($r.Cancelled) { break }
    }
    $empty.ErrorKey = 'Err.SessionInvalid'
    return $empty
}

function Set-DreddLoginMarker {
    param([Parameter(Mandatory)]$Context)
    if (-not [System.IO.Directory]::Exists($Context.IpatoolHome)) { [void][System.IO.Directory]::CreateDirectory($Context.IpatoolHome) }
    $marker = Join-Path $Context.IpatoolHome 'login'
    if (-not [System.IO.File]::Exists($marker)) { [System.IO.File]::WriteAllBytes($marker, [byte[]]@()) }
}

function Test-DreddLoginMarker {
    param([Parameter(Mandatory)]$Context)
    return [System.IO.File]::Exists((Join-Path $Context.IpatoolHome 'login'))
}

function Complete-DreddLogin {
    # После успешного входа: kbsync --refresh (как 4.1/4.2), маркер login (совместимость с 4.2), auth info.
    param([Parameter(Mandatory)]$Context, $Reporter, $CancellationToken)
    Write-DreddReport -Reporter $Reporter -Type status -Area 'Account' -Message 'kbsync'
    # Вывод kbsync содержит DSID аккаунта — в журнал не пишется (ADR-015).
    $k = Invoke-DreddIpatool -Context $Context -Arguments @('kbsync', '--refresh') -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 180 -Area 'Account' -QuietOutput
    if (-not $k.Ok) { Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Account' -Message ("kbsync: " + $k.Error.Message) }
    Set-DreddLoginMarker -Context $Context
    return Get-DreddAuthInfo -Context $Context -Reporter $Reporter -CancellationToken $CancellationToken
}

function Connect-DreddAppleId {
    <#
      Вход по email/паролю (ADR-006). Пароль передаётся одному вызову ipatool и маскируется в журнале.
      -ParkCurrentAs <email>: перед входом «припарковать» текущую сессию (добавление аккаунта); при неудаче — вернуть.
      Результат: Success, NeedsCode, ErrorKey, Message, Account (auth info).
    #>
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)]$Password,
        [string]$AuthCode,
        [string]$ParkCurrentAs,
        $Reporter,
        $CancellationToken
    )
    $plain = $Password
    if ($Password -is [System.Security.SecureString]) { $plain = [System.Net.NetworkCredential]::new('', $Password).Password }
    $Email = $Email.Trim()
    if ($Email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        return [pscustomobject]@{ Success = $false; NeedsCode = $false; ErrorKey = 'Err.EmailFormat'; Message = ''; Account = $null }
    }

    $parked = $false
    if ($ParkCurrentAs -and [System.IO.File]::Exists((Join-Path $Context.IpatoolHome 'account'))) {
        Save-DreddActiveAccount -Context $Context -Email $ParkCurrentAs
        $parked = $true
    }

    $kp = Get-DreddPassphrase -Context $Context
    if (-not $kp -and $Context.Platform.IsWindows -and (ConvertTo-DreddBool $Context.Settings['KeychainEnabled'])) {
        $kp = New-DreddPassphrase -Context $Context
    }
    if ($kp) { $Context.PassphraseMode = 'auto' }

    $loginArgs = @('auth', 'login', '-e', $Email, '-p', $plain)
    $secrets = @($plain)
    if (-not [string]::IsNullOrWhiteSpace($AuthCode)) { $loginArgs += @('-a', $AuthCode.Trim()); $secrets += $AuthCode.Trim() }

    Write-DreddReport -Reporter $Reporter -Type status -Area 'Account' -Message 'login'
    $params = @{
        Context = $Context; Arguments = $loginArgs; Reporter = $Reporter; CancellationToken = $CancellationToken
        TimeoutSec = 180; SecretValues = $secrets; Area = 'Account'; QuietOutput = $true
    }
    if ($kp) { $params['Passphrase'] = $kp } else { $params['NoPassphrase'] = $true }
    $r = Invoke-DreddIpatool @params
    $plain = $null

    if ($r.ExitCode -eq 0 -and -not $r.Cancelled -and -not $r.TimedOut) {
        $info = Complete-DreddLogin -Context $Context -Reporter $Reporter -CancellationToken $CancellationToken
        if ($info.Success) {
            # Удаляем устаревшую «припаркованную» копию этого же аккаунта (поведение 4.2):
            if ($info.Email -and (Test-DreddAccountName $info.Email)) {
                $old = Join-Path $Context.IpatoolHome $info.Email
                if ([System.IO.Directory]::Exists($old)) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
            }
            return [pscustomobject]@{ Success = $true; NeedsCode = $false; ErrorKey = $null; Message = ''; Account = $info }
        }
    }

    # Неудача: возвращаем припаркованную сессию
    $needsCode = (-not $r.Cancelled) -and [string]::IsNullOrWhiteSpace($AuthCode) -and (Test-DreddNeedsAuthCode $r.Output)
    if ($parked) {
        Clear-DreddActiveAccount -Context $Context
        Restore-DreddSavedAccount -Context $Context -Email $ParkCurrentAs
    } elseif (-not (Test-DreddLoginMarker -Context $Context)) {
        Clear-DreddActiveAccount -Context $Context
    }
    $e = $r.Error
    if (-not $e) { $e = [pscustomobject]@{ Key = 'Err.SessionInvalid'; Message = '' } }
    if ($needsCode) { $e = [pscustomobject]@{ Key = 'Err.AuthCode'; Message = $e.Message } }
    return [pscustomobject]@{ Success = $false; NeedsCode = $needsCode; ErrorKey = $e.Key; Message = $e.Message; Account = $null }
}

function Start-DreddConsoleLogin {
    <#
      Интерактивный вход в отдельном консольном окне (пароль вводится скрыто, в аргументы не попадает).
      Passphrase передаётся через переменную окружения, чтобы не светиться в заголовке окна. Возвращает Process.
    #>
    param([Parameter(Mandatory)]$Context, [string]$PromptText = 'Press Enter to close')
    if (-not $Context.Platform.IsWindows) { throw 'Console login from GUI is supported on Windows only' }
    $exe = $Context.Binaries.Ipatool
    if (-not $exe) { throw (New-Object System.IO.FileNotFoundException('ipatool not found')) }
    $kp = Get-DreddPassphrase -Context $Context
    if (-not $kp -and (ConvertTo-DreddBool $Context.Settings['KeychainEnabled'])) { $kp = New-DreddPassphrase -Context $Context }

    $exeEsc = $exe.Replace("'", "''")
    $rootEsc = ([string]$Context.Binaries.Root).Replace("'", "''")
    $promptEsc = $PromptText.Replace("'", "''")
    $cmd = @"
`$env:Path = '$rootEsc;' + `$env:Path
`$a = @('auth','login')
if (`$env:IPADREDD_KP) { `$a += @('--keychain-passphrase', `$env:IPADREDD_KP) }
Remove-Item Env:IPADREDD_KP -ErrorAction SilentlyContinue
& '$exeEsc' @a
`$code = `$LASTEXITCODE
Write-Host ''
Read-Host '$promptEsc' | Out-Null
exit `$code
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $prev = [Environment]::GetEnvironmentVariable('IPADREDD_KP', 'Process')
    try {
        if ($kp) { [Environment]::SetEnvironmentVariable('IPADREDD_KP', $kp, 'Process') }
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded -PassThru
    } finally {
        [Environment]::SetEnvironmentVariable('IPADREDD_KP', $prev, 'Process')
    }
    return $p
}

function Disconnect-DreddAppleId {
    # Выход из текущего аккаунта: auth revoke + удаление активных файлов. Настройки и другие аккаунты не трогаются.
    param([Parameter(Mandatory)]$Context, $Reporter, $CancellationToken)
    if ($Context.Binaries.Ipatool -and [System.IO.File]::Exists((Join-Path $Context.IpatoolHome 'account'))) {
        $r = Invoke-DreddIpatool -Context $Context -Arguments @('auth', 'revoke') -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 60 -Area 'Account'
        if (-not $r.Ok) { Write-DreddReport -Reporter $Reporter -Type log -Level Warning -Area 'Account' -Message ("auth revoke: " + $r.Error.Message) }
    }
    Clear-DreddActiveAccount -Context $Context
    return $true
}

function Search-DreddAppStore {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Query, [int]$Limit = 25, $Reporter, $CancellationToken)
    $r = Invoke-DreddIpatool -Context $Context -Arguments @('search', $Query, '--limit', "$Limit", '--non-interactive') -Json -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 60 -Area 'Catalog'
    $rows = @()
    if ($r.Json) {
        foreach ($a in @(Get-DreddProp $r.Json 'apps' @())) {
            if ($null -eq $a) { continue }
            $rows += [pscustomobject]@{
                Name = [string](Get-DreddProp $a 'name'); ID = [string](Get-DreddProp $a 'id'); BundleId = [string](Get-DreddProp $a 'bundleID')
                Version = [string](Get-DreddProp $a 'version'); Price = (Get-DreddProp $a 'price'); Source = 'AppStore'
            }
        }
    }
    [pscustomobject]@{ Ok = $r.Ok; Apps = $rows; Error = $r.Error }
}

function Get-DreddAppVersions {
    # ID версий (новые первыми). -Purchase как в 4.2 (получить лицензию, если нужно).
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$AppId, [switch]$Purchase, $Reporter, $CancellationToken)
    $a = @('list-versions', '-i', $AppId)
    if ($Purchase) { $a += '--purchase' }
    $r = Invoke-DreddIpatool -Context $Context -Arguments $a -Json -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 120 -Area 'Versions'
    $ids = @()
    if ($r.Json) { $ids = @(Get-DreddProp $r.Json 'externalVersionIdentifiers' @() | ForEach-Object { [string]$_ }) }
    elseif ($r.ExitCode -eq 0) { $ids = @([regex]::Matches($r.Output, '(?<=")\d+(?=")') | ForEach-Object { $_.Value }) }
    [array]::Reverse($ids)
    [pscustomobject]@{ Ok = ($r.Ok -and $ids.Count -gt 0); VersionIds = $ids; Error = $(if ($r.Ok -and $ids.Count -eq 0) { [pscustomobject]@{ Key = 'Err.NoVersions'; Message = '' } } else { $r.Error }) }
}

function Get-DreddVersionMetadata {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$VersionId, $Reporter, $CancellationToken)
    $r = Invoke-DreddIpatool -Context $Context -Arguments @('get-version-metadata', '-i', $AppId, '--external-version-id', $VersionId) -Json -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 60 -Area 'Versions'
    $ver = $null; $date = $null
    if ($r.Json) {
        $ver = [string](Get-DreddProp $r.Json 'displayVersion')
        $rd = Get-DreddProp $r.Json 'releaseDate'
        if ($rd) { try { $date = ([datetime]$rd).ToString('yyyy-MM-dd') } catch { $date = [string]$rd } }
    } elseif ($r.Output -match 'displayVersion=([^\s,]+)') { $ver = $Matches[1] }
    [pscustomobject]@{ Ok = $r.Ok; VersionId = $VersionId; DisplayVersion = $ver; ReleaseDate = $date; Error = $r.Error }
}

function ConvertTo-DreddPurchaseDate {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{ Text = ''; Sort = [datetime]::MinValue } }
    $dt = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dt)) {
        return [pscustomobject]@{ Text = $dt.ToString('dd.MM.yyyy'); Sort = $dt }
    }
    $months = @{ Jan = 1; Feb = 2; Mar = 3; Apr = 4; May = 5; Jun = 6; Jul = 7; Aug = 8; Sep = 9; Oct = 10; Nov = 11; Dec = 12 }
    if ($Text -match '(\d{1,2})\D+?([A-Za-z]{3})[A-Za-z]*\D*?(\d{4})' -and $months.ContainsKey($Matches[2])) {
        $dt = New-Object datetime ([int]$Matches[3]), ([int]$months[$Matches[2]]), ([int]$Matches[1])
        return [pscustomobject]@{ Text = $dt.ToString('dd.MM.yyyy'); Sort = $dt }
    }
    return [pscustomobject]@{ Text = $Text; Sort = [datetime]::MinValue }
}

function Get-DreddAccountPurchases {
    # История покупок аккаунта: list-purchases --all (в ipatool — experimental). Только iOS-приложения, новые первыми.
    param([Parameter(Mandatory)]$Context, $Reporter, $CancellationToken)
    $r = Invoke-DreddIpatool -Context $Context -Arguments @('list-purchases', '--all') -Json -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 900 -Area 'Purchases'
    # В истории есть подписки, встроенные покупки и Mac-приложения; одно приложение может встречаться несколько раз
    # (повторное «получение»). Оставляем только приложения iOS/iPadOS, по одной записи на ID — с самой ранней датой.
    $byId = [ordered]@{}
    if ($r.Json) {
        foreach ($a in @(Get-DreddProp $r.Json 'apps' @())) {
            if ($null -eq $a) { continue }
            $kind = [string](Get-DreddProp $a 'kind')
            $id = [string](Get-DreddProp $a 'id')
            if ($kind -and $kind -notmatch '^(iOS|iPhone|iPad)\b') { continue }
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $d = ConvertTo-DreddPurchaseDate ([string](Get-DreddProp $a 'purchaseDate'))
            $row = [pscustomobject]@{ Name = [string](Get-DreddProp $a 'name'); ID = $id; PurchaseDate = $d.Text; SortDate = $d.Sort; Price = [string](Get-DreddProp $a 'price'); Source = 'Purchases' }
            if ($byId.Contains($id)) {
                $prev = $byId[$id]
                if ($row.SortDate -ne [datetime]::MinValue -and ($prev.SortDate -eq [datetime]::MinValue -or $row.SortDate -lt $prev.SortDate)) {
                    if (-not $row.Name) { $row.Name = $prev.Name }
                    $byId[$id] = $row
                }
            } else { $byId[$id] = $row }
        }
    }
    $rows = @($byId.Values | Sort-Object -Property SortDate -Descending)
    $ok = $r.Ok -and ($null -ne $r.Json)
    $err = $r.Error
    if ($r.Ok -and $null -eq $r.Json) { $err = [pscustomobject]@{ Key = 'Err.Unknown'; Message = 'Unexpected list-purchases output' } }
    [pscustomobject]@{ Ok = $ok; Apps = $rows; Error = $err }
}

function Invoke-DreddPurchase {
    # Получение бесплатной лицензии. В PurchasedAppsList.json пишем только при успехе (исправление A6).
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$AppId, [string]$AppName, [string]$Account, $Reporter, $CancellationToken)
    $r = Invoke-DreddIpatool -Context $Context -Arguments @('purchase', '-i', $AppId) -Reporter $Reporter -CancellationToken $CancellationToken -TimeoutSec 120 -Area 'Purchase'
    if ($r.Ok -and $Account) {
        $name = $AppName
        if ([string]::IsNullOrWhiteSpace($name)) { $name = Resolve-DreddAppName -Context $Context -AppId $AppId }
        if ($name) { Add-DreddPurchasedApp -Context $Context -Account $Account -AppId $AppId -Name $name }
    }
    [pscustomobject]@{ Ok = $r.Ok; Error = $r.Error }
}

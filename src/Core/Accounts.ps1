# Несколько Apple ID: раскладка ~/.ipatool, совместимая с 4.2 (ADR-005).
#   активный аккаунт:  ~/.ipatool/{account,cookies,login}
#   сохранённые:       ~/.ipatool/<email>/{account,cookies,login}
# 4.3 только перемещает эти файлы и никогда не читает их содержимое.

$script:AuthFileNames = @('account', 'cookies', 'login')

function Test-DreddAccountName {
    # Имя папки аккаунта: без разделителей путей и «..» (защита от выхода за пределы ~/.ipatool).
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -match '[\\/:*?"<>|]' -or $Name -match '^\.+$' -or $Name.Contains('..')) { return $false }
    return $true
}

function Get-DreddSavedAccounts {
    param([Parameter(Mandatory)]$Context)
    if (-not [System.IO.Directory]::Exists($Context.IpatoolHome)) { return @() }
    $list = foreach ($d in [System.IO.Directory]::GetDirectories($Context.IpatoolHome)) {
        $name = [System.IO.Path]::GetFileName($d)
        if (-not (Test-DreddAccountName $name)) { continue }
        $hasAccount = [System.IO.File]::Exists((Join-Path $d 'account'))
        [pscustomobject]@{ Email = $name; Path = $d; HasSession = $hasAccount }
    }
    return @($list | Sort-Object Email)
}

function Save-DreddActiveAccount {
    # «Паркует» активную сессию в ~/.ipatool/<email>/.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email)
    if (-not (Test-DreddAccountName $Email)) { throw "Invalid account name" }
    $target = Join-Path $Context.IpatoolHome $Email
    [void][System.IO.Directory]::CreateDirectory($target)
    foreach ($f in $script:AuthFileNames) {
        $src = Join-Path $Context.IpatoolHome $f
        if ([System.IO.File]::Exists($src)) {
            $dst = Join-Path $target $f
            if ([System.IO.File]::Exists($dst)) { [System.IO.File]::Delete($dst) }
            [System.IO.File]::Move($src, $dst)
        }
    }
}

function Restore-DreddSavedAccount {
    # Возвращает сохранённую сессию в активные файлы и удаляет пустую папку аккаунта.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email)
    if (-not (Test-DreddAccountName $Email)) { throw "Invalid account name" }
    $src = Join-Path $Context.IpatoolHome $Email
    if (-not [System.IO.Directory]::Exists($src)) { return $false }
    foreach ($f in $script:AuthFileNames) {
        $from = Join-Path $src $f
        if ([System.IO.File]::Exists($from)) {
            $to = Join-Path $Context.IpatoolHome $f
            if ([System.IO.File]::Exists($to)) { [System.IO.File]::Delete($to) }
            [System.IO.File]::Move($from, $to)
        }
    }
    if (@([System.IO.Directory]::GetFileSystemEntries($src)).Count -eq 0) { [System.IO.Directory]::Delete($src) }
    return $true
}

function Clear-DreddActiveAccount {
    # Удаляет только активные файлы сессии. keychain-passphrase и сохранённые аккаунты не трогаются (в отличие от 4.2).
    param([Parameter(Mandatory)]$Context)
    foreach ($f in $script:AuthFileNames) {
        $p = Join-Path $Context.IpatoolHome $f
        if ([System.IO.File]::Exists($p)) { [System.IO.File]::Delete($p) }
    }
}

function Switch-DreddAccount {
    # Переключение на сохранённый аккаунт. CurrentEmail — email активной сессии (если есть), её паркуем.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email, [string]$CurrentEmail, $Reporter, $CancellationToken)
    $hasActive = [System.IO.File]::Exists((Join-Path $Context.IpatoolHome 'account'))
    if ($hasActive) {
        if ($CurrentEmail -and (Test-DreddAccountName $CurrentEmail)) {
            Save-DreddActiveAccount -Context $Context -Email $CurrentEmail
        } else {
            # Активная сессия без известного email (недействительна) — не паркуем «UnknownAccount», а удаляем.
            Clear-DreddActiveAccount -Context $Context
        }
    }
    [void](Restore-DreddSavedAccount -Context $Context -Email $Email)
    $info = Get-DreddAuthInfo -Context $Context -Reporter $Reporter -CancellationToken $CancellationToken
    if ($info.Success) { Set-DreddLoginMarker -Context $Context }
    return $info
}

function Remove-DreddSavedAccount {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Email)
    if (-not (Test-DreddAccountName $Email)) { throw "Invalid account name" }
    $p = Join-Path $Context.IpatoolHome $Email
    if ([System.IO.Directory]::Exists($p)) { Remove-Item -LiteralPath $p -Recurse -Force }
}

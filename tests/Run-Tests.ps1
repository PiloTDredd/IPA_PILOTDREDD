# Минимальный раннер тестов (без зависимости от версии Pester, ADR-014).
# Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 [-Filter <подстрока>]
param([string]$Filter)

$ErrorActionPreference = 'Stop'
$script:TestResults = New-Object System.Collections.Generic.List[object]
$script:CurrentTest = $null

function Test {
    param([string]$Name, [scriptblock]$Body)
    if ($Filter -and $Name -notlike "*$Filter*") { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:CurrentTest = $Name
    try {
        & $Body
        $script:TestResults.Add([pscustomobject]@{ Name = $Name; Ok = $true; Error = $null; Ms = $sw.ElapsedMilliseconds })
        Write-Host ("  [PASS] {0} ({1} ms)" -f $Name, $sw.ElapsedMilliseconds) -ForegroundColor Green
    } catch {
        $script:TestResults.Add([pscustomobject]@{ Name = $Name; Ok = $false; Error = $_.Exception.Message; Ms = $sw.ElapsedMilliseconds })
        Write-Host ("  [FAIL] {0}: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
        if ($_.InvocationInfo) { Write-Host ("         at line {0}: {1}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim()) -ForegroundColor DarkGray }
    }
}

function Assert-True { param($Value, [string]$Message = 'Expected true') if (-not $Value) { throw $Message } }
function Assert-False { param($Value, [string]$Message = 'Expected false') if ($Value) { throw $Message } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = @($Expected) -join '|'; $a = @($Actual) -join '|'
        if ($e -ne $a) { throw "$Message Expected [$e], got [$a]" }
        return
    }
    if ($Expected -ne $Actual) { throw "$Message Expected [$Expected], got [$Actual]" }
}
function Assert-Match { param([string]$Text, [string]$Pattern, [string]$Message) if ($Text -notmatch $Pattern) { throw "$Message Text [$Text] does not match [$Pattern]" } }
function Assert-NotMatch { param([string]$Text, [string]$Pattern, [string]$Message) if ($Text -match $Pattern) { throw "$Message Text [$Text] must not match [$Pattern]" } }

$here = $PSScriptRoot
$appRoot = Split-Path $here -Parent
Write-Host "IPA Dredd tests — PowerShell $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition)" -ForegroundColor Cyan
foreach ($file in Get-ChildItem -LiteralPath $here -Filter '*.Tests.ps1' | Sort-Object Name) {
    Write-Host "`n$($file.Name)" -ForegroundColor Cyan
    . $file.FullName
}

$failed = @($script:TestResults | Where-Object { -not $_.Ok })
Write-Host ("`nTotal: {0}, passed: {1}, failed: {2}" -f $script:TestResults.Count, ($script:TestResults.Count - $failed.Count), $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
if ($failed.Count) { exit 1 } else { exit 0 }

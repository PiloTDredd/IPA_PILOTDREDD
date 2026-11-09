# Самопроверка GUI со сценарием на фейковом ipatool — в копии приложения (%TEMP%\IPADreddSelfTest), Files/ и Apps/ не трогаются.
# -Screenshots <папка> — снимки экранов; -NoScenario — только построение экранов.
# -ViaLauncher — запуск через IPA_PILOTDREDD.exe (tools/Launcher): проверка встроенного PowerShell запускатора.
param([string]$Screenshots, [switch]$NoScenario, [switch]$ViaLauncher)
$appRoot = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([System.IO.Path]::GetTempPath()) 'IPADreddSelfTest'
$copy = Join-Path $work 'app'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory (Join-Path $copy 'Files') | Out-Null
foreach ($i in 'src', 'tests', 'tools', 'IPA_Dredd.ps1') { Copy-Item (Join-Path $appRoot $i) -Destination $copy -Recurse }
Copy-Item (Join-Path $appRoot 'Files\AppsList.txt') (Join-Path $copy 'Files')
$state = Join-Path $work 'fake_state'
New-Item -ItemType Directory $state | Out-Null
New-Item -ItemType File (Join-Path $state 'logged_in') | Out-Null
$env:FAKE_STATE_DIR = $state
Push-Location $copy
try {
    $t = @('-SelfTest')
    if ($Screenshots) { $t += @('-Screenshot', $Screenshots) }
    if (-not $NoScenario) { $t += @('-TestIpatool', 'tests\fixtures\fake-ipatool.cmd') }
    if ($ViaLauncher) {
        # Окно самопроверки скрыто за краем экрана; результат — код возврата exe и Logs/selftest-result.txt.
        Copy-Item (Join-Path $appRoot 'tools\Launcher\IPA_PILOTDREDD.exe') $copy
        $env:IPADREDD_SELFTEST_RESULT = Join-Path $copy 'Logs\selftest-result.txt'
        $p = Start-Process -FilePath (Join-Path $copy 'IPA_PILOTDREDD.exe') -ArgumentList $t -Wait -PassThru
        $code = $p.ExitCode
        if (Test-Path $env:IPADREDD_SELFTEST_RESULT) { Get-Content $env:IPADREDD_SELFTEST_RESULT }
        Write-Output "LAUNCHER EXIT: $code"
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File IPA_Dredd.ps1 @t
        $code = $LASTEXITCODE
    }
} finally { Pop-Location }
exit $code

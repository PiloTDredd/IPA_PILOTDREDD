# Самопроверка GUI со сценарием на фейковом ipatool — в копии приложения (%TEMP%\IPADreddSelfTest), Files/ и Apps/ не трогаются.
# -Screenshots <папка> — снимки экранов; -NoScenario — только построение экранов.
param([string]$Screenshots, [switch]$NoScenario)
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
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', 'IPA_Dredd.ps1', '-SelfTest')
    if ($Screenshots) { $a += @('-Screenshot', $Screenshots) }
    if (-not $NoScenario) { $a += @('-TestIpatool', 'tests\fixtures\fake-ipatool.cmd') }
    & powershell.exe @a
    $code = $LASTEXITCODE
} finally { Pop-Location }
exit $code

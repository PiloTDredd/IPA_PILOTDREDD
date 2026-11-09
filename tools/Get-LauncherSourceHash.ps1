# SHA-256 исходников запускатора (Launcher.cs + иконка): если совпадает с tools/Launcher/launcher.sha256 — готовый exe актуален.
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot -Parent
$sha = [System.Security.Cryptography.SHA256]::Create()
$ms = New-Object System.IO.MemoryStream
foreach ($f in (Join-Path $PSScriptRoot 'Launcher\Launcher.cs'), (Join-Path $appRoot 'src\GUI\Assets\app.ico')) {
    $b = [System.IO.File]::ReadAllBytes($f)
    # Launcher.cs — без учёта переводов строк (git на Windows может хранить CRLF или LF).
    if ($f -like '*.cs') { $b = [System.Text.Encoding]::UTF8.GetBytes(([System.Text.Encoding]::UTF8.GetString($b) -replace "`r`n", "`n")) }
    $ms.Write($b, 0, $b.Length)
}
-join ($sha.ComputeHash($ms.ToArray()) | ForEach-Object { $_.ToString('x2') })

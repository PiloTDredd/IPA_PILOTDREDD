# Приводит все .ps1/.psm1/.psd1 к UTF-8 с BOM: Windows PowerShell 5.1 читает файлы без BOM как ANSI и ломает кириллицу.
param([string]$Root = (Split-Path $PSScriptRoot -Parent))

$bomEncoding = New-Object System.Text.UTF8Encoding($true)
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if (-not $hasBom) {
        $text = $utf8Strict.GetString($bytes)
        [System.IO.File]::WriteAllText($_.FullName, $text, $bomEncoding)
        Write-Output "BOM added: $($_.FullName.Substring($Root.Length + 1))"
    }
}

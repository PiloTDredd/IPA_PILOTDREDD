# Локализация: src/Localization/<lang>.json (ключ → текст).

$script:StringsCache = @{}

function Get-DreddLanguages { return @('RU', 'EN') }

function Get-DreddStrings {
    param([ValidateSet('RU', 'EN')][string]$Language = 'RU', [string]$Folder)
    if (-not $Folder) { $Folder = Join-Path (Split-Path $script:CoreRoot -Parent) 'Localization' }
    $file = Join-Path $Folder ($Language.ToLowerInvariant() + '.json')
    if ($script:StringsCache.ContainsKey($file)) { return $script:StringsCache[$file] }
    $obj = (Read-DreddTextFile -Path $file).TrimStart([char]0xFEFF) | ConvertFrom-Json
    $h = @{}
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
    $script:StringsCache[$file] = $h
    return $h
}

# Настройки в Files/Settings.txt (формат Key=Value, как в 4.1/4.2).

function Get-DreddDefaultSettings {
    [ordered]@{
        Language               = 'RU'
        Theme                  = 'Dark'
        DownloadFolder         = ''
        BinaryRoot             = ''
        UpdateListsOnStartup   = 'True'
        CheckUpdatesOnStartup  = 'True'
        AutoPurchase           = 'True'
        FileNameIncludeAccount = 'False'
        KeychainEnabled        = 'False'
        DebugEnabled           = 'False'
        RemoteListBaseUrl      = 'https://raw.githubusercontent.com/kda2495/IPA_Downloader/refs/heads/main/Files'
        UpdateRepo             = 'kda2495/IPA_Downloader'   # первая установка: набор компонентов IPA Downloader
        ToolRepo               = 'Sorvigolova/ipatool'       # обновления ipatool-cpp напрямую
        # Релизы самой программы: при запуске — уведомление «Вышла IPA PILOTDREDD X» (без автоматической замены файлов).
        AppRepo                = 'PiloTDredd/IPA_PILOTDREDD'
        # Чаевые автору IPA PILOTDREDD (кнопка «Поддержать PILOTDREDD» в «Диагностике»).
        TipJarUrl              = 'https://pay.cloudtips.ru/p/129557e1'
    }
}

function ConvertTo-DreddBool {
    param($Value)
    if ($Value -is [bool]) { return $Value }
    return ("$Value".Trim() -match '^(true|1|yes|on)$')
}

function Get-DreddSettings {
    param([Parameter(Mandatory)][string]$Path)
    $settings = Get-DreddDefaultSettings
    $raw = Read-DreddTextFile -Path $Path
    if ($raw) {
        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match '^\s*([^=#][^=]*?)\s*=\s*(.*)$') {
                $settings[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    # Нормализация значений:
    if ($settings['Language'] -notmatch '^(RU|EN)$') { $settings['Language'] = 'RU' }
    if ($settings['Theme'] -notmatch '^(Dark|Light)$') { $settings['Theme'] = 'Dark' }
    return $settings
}

function Set-DreddSetting {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Key,
        [AllowEmptyString()][string]$Value,
        [System.Collections.IDictionary]$Settings
    )
    if ($Key -notmatch '^[A-Za-z][A-Za-z0-9_]*$') { throw "Invalid setting key: $Key" }
    $Value = ($Value -replace "[`r`n]", ' ').Trim()
    # Сохраняем существующие строки (в том числе ключи 4.2, о которых 4.3 не знает):
    $current = [ordered]@{}
    $raw = Read-DreddTextFile -Path $Path
    if ($raw) {
        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match '^\s*([^=#][^=]*?)\s*=\s*(.*)$') { $current[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    $current[$Key] = $Value
    $lines = foreach ($k in $current.Keys) { "$k=$($current[$k])" }
    Write-DreddTextFile -Path $Path -Content (($lines -join "`r`n") + "`r`n")
    if ($Settings) { $Settings[$Key] = $Value }
}

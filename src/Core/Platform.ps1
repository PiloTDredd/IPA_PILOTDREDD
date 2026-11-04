# Определение платформы и общие утилиты.

function Get-DreddVersion { return $script:DreddVersion }

function Get-DreddPlatform {
    $ri = [System.Runtime.InteropServices.RuntimeInformation]
    $os = [System.Runtime.InteropServices.OSPlatform]
    $isWin = $ri::IsOSPlatform($os::Windows)
    $isMac = $ri::IsOSPlatform($os::OSX)
    $arch = $ri::OSArchitecture.ToString().ToLowerInvariant()

    $folder = if ($isWin) { 'windows_amd64' }
              elseif ($isMac) { if ($arch -eq 'arm64') { 'macOS_arm64' } else { 'macOS_amd64' } }
              else { 'linux_amd64' }

    [pscustomobject]@{
        IsWindows   = $isWin
        IsMac       = $isMac
        IsLinux     = (-not $isWin -and -not $isMac)
        Arch        = $arch
        Name        = if ($isWin) { 'Windows' } elseif ($isMac) { 'macOS' } else { 'Linux' }
        OSVersion   = [System.Environment]::OSVersion.VersionString
        OSDescription = $ri::OSDescription
        PSVersion   = $PSVersionTable.PSVersion.ToString()
        PSEdition   = $PSVersionTable.PSEdition
        Runtime     = $ri::FrameworkDescription
        BinaryFolder = $folder
        ExeSuffix   = if ($isWin) { '.exe' } else { '' }
    }
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-DreddTextFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-DreddTextFile {
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content)
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [void][System.IO.Directory]::CreateDirectory($dir) }
    # Запись через временный файл, чтобы не оставить полузаписанный файл при сбое:
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, $script:Utf8NoBom)
    if ([System.IO.File]::Exists($Path)) {
        # File.Replace атомарен на NTFS; на файловых системах без его поддержки — копирование.
        # ReplaceFile сохраняет часть атрибутов старого файла — время изменения ставим явно (по нему работают кэши списков).
        try { [System.IO.File]::Replace($tmp, $Path, $null); [System.IO.File]::SetLastWriteTimeUtc($Path, [DateTime]::UtcNow) }
        catch { [System.IO.File]::Copy($tmp, $Path, $true); [System.IO.File]::Delete($tmp) }
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Test-DreddContains {
    # Регистронезависимый поиск подстроки без масок и регулярок.
    param([string]$Text, [string]$Query)
    if ([string]::IsNullOrEmpty($Query)) { return $true }
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return $Text.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Get-DreddProp {
    # Безопасное чтение свойства у объекта из JSON (свойства может не быть).
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] } else { return $Default }
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}

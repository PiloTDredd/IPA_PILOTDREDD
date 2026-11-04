# IPADredd.Core — бизнес-логика IPA Dredd без UI.
# Совместим с Windows PowerShell 5.1 и PowerShell 7.

$script:CoreRoot = $PSScriptRoot
# Единственный источник номера версии — файл VERSION в корне приложения (окно, exe, релиз, User-Agent).
$script:DreddVersion = '0.0.0'
$versionFile = Join-Path (Split-Path (Split-Path $script:CoreRoot -Parent) -Parent) 'VERSION'
if ([System.IO.File]::Exists($versionFile)) {
    $v = [System.IO.File]::ReadAllText($versionFile).Trim()
    if ($v -match '^\d+\.\d+\.\d+$') { $script:DreddVersion = $v }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# C#-помощник для plist компилируется один раз на процесс (тип общий для всех runspace):
if (-not ('IPADredd.PlistReader' -as [type])) {
    $plistSource = [System.IO.File]::ReadAllText((Join-Path $script:CoreRoot 'Native/PlistReader.cs'))
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -TypeDefinition $plistSource -Language CSharp -ReferencedAssemblies 'System.Xml', 'System.Xml.ReaderWriter', 'System.Collections', 'System.Collections.NonGeneric', 'System.Runtime.Extensions' -ErrorAction Stop
    } else {
        Add-Type -TypeDefinition $plistSource -Language CSharp -ReferencedAssemblies 'System.Xml' -ErrorAction Stop
    }
}

$parts = @(
    'Platform', 'Settings', 'Logging', 'Process', 'Binaries', 'Context',
    'Ipatool', 'Accounts', 'AppLists', 'History', 'Purchases', 'Library', 'Downloads',
    'Devices', 'Diagnostics', 'RemoteLists', 'Updates', 'Localization'
)
foreach ($part in $parts) {
    . (Join-Path $script:CoreRoot "$part.ps1")
}

Export-ModuleMember -Function @(
    # Platform / Context / Settings
    'Get-DreddPlatform', 'Get-DreddVersion', 'New-DreddContext', 'Update-DreddContextPaths',
    'Get-DreddProp', 'Test-DreddContains', 'Read-DreddTextFile', 'Write-DreddTextFile',
    'Get-DreddSettings', 'Set-DreddSetting', 'Get-DreddDefaultSettings', 'ConvertTo-DreddBool',
    # Logging / Reporting
    'Protect-LogText', 'Protect-DreddEmail', 'Write-DreddReport', 'Write-DreddLogFile', 'Format-DreddLogLine',
    # Process
    'Invoke-DreddProcess', 'ConvertTo-DreddArgumentString', 'Stop-DreddProcessTree',
    # Binaries
    'Find-DreddBinaries', 'Get-DreddBinaryCandidates',
    # ipatool
    'Invoke-DreddIpatool', 'Get-DreddPassphrase', 'New-DreddPassphrase', 'Get-DreddAuthInfo', 'Connect-DreddAppleId',
    'Start-DreddConsoleLogin', 'Complete-DreddLogin', 'Disconnect-DreddAppleId', 'Search-DreddAppStore', 'Get-DreddAppVersions',
    'Get-DreddVersionMetadata', 'Get-DreddAccountPurchases', 'Invoke-DreddPurchase', 'Resolve-DreddToolError',
    'Test-DreddNeedsAuthCode', 'ConvertFrom-DreddToolJson',
    # Accounts
    'Get-DreddSavedAccounts', 'Save-DreddActiveAccount', 'Restore-DreddSavedAccount', 'Clear-DreddActiveAccount',
    'Switch-DreddAccount', 'Remove-DreddSavedAccount', 'Test-DreddAccountName', 'Test-DreddLoginMarker', 'Set-DreddLoginMarker',
    # Lists
    'Read-DreddAppsList', 'Get-DreddPopularApps', 'Get-DreddCustomApps', 'Add-DreddCustomApp', 'Remove-DreddDuplicateIds',
    'Search-DreddLocalApps', 'Search-DreddApps', 'Resolve-DreddAppName', 'Split-DreddIdQuery',
    # History
    'Get-DreddPurchasedApps', 'Add-DreddPurchasedApp', 'Get-DreddDownloadHistory', 'Add-DreddHistoryEntry', 'Get-DreddHistoryKey', 'Remove-DreddHistoryEntries',
    # Purchase library
    'Get-DreddAccountKey', 'Get-DreddPurchaseCachePath', 'Get-DreddIconPath', 'ConvertTo-DreddCountryCode', 'Compare-DreddVersion',
    'Read-DreddPurchaseLibrary', 'Save-DreddPurchaseLibrary', 'Invoke-DreddStoreLookup', 'Merge-DreddPurchaseLookup',
    'Update-DreddPurchaseLibrary', 'Set-DreddPurchaseAttempt', 'Get-DreddPurchaseStatus', 'Save-DreddIcons',
    # Library
    'Get-DreddIpaMetadata', 'Get-DreddLibrary', 'Get-DreddSignatureInfo', 'Test-DreddSignatureForDevice', 'Import-DreddIpaToLibrary', 'Get-DreddIpaFileName', 'Get-DreddUniquePath', 'ConvertTo-DreddSafeFileName',
    # Downloads
    'Invoke-DreddDownload', 'Get-DreddProgressFromLine', 'Save-DreddQueue', 'Read-DreddQueue',
    # Devices
    'Get-DreddDevices', 'Install-DreddIpa', 'ConvertTo-DreddIosVersion', 'Test-DreddIosCompatible',
    # Diagnostics
    'Get-DreddEnvironment', 'Get-DreddDiagnostics', 'New-DreddDiagnosticReport', 'Export-DreddDiagnosticReport',
    # Remote
    'Update-DreddRemoteLists', 'Get-DreddLatestRelease', 'Test-DreddAppsListContent',
    # Updates
    'Get-DreddToolVersion', 'Test-DreddToolUpdate', 'Install-DreddToolUpdate', 'Test-DreddNeedsSetup',
    # Localization
    'Get-DreddStrings', 'Get-DreddLanguages'
)

# Локальная библиотека IPA: метаданные из Info.plist и iTunesMetadata.plist (XML и бинарные, ADR-010).

function Read-DreddZipEntryBytes {
    param([System.IO.Compression.ZipArchiveEntry]$Entry, [int]$MaxBytes = 16MB)
    if ($Entry.Length -gt $MaxBytes) { throw "Entry too large: $($Entry.FullName)" }
    $s = $Entry.Open()
    try {
        $ms = New-Object System.IO.MemoryStream
        $s.CopyTo($ms)
        return $ms.ToArray()
    } finally { $s.Dispose() }
}

function Get-DreddIpaMetadata {
    <#
      Возвращает: Path, FileName, Name, DisplayName, BundleName, BundleId, Version, Build, MinIOS, AppStoreId, Artist,
      SizeBytes, Modified, Error. Apple ID покупателя из iTunesMetadata.plist НЕ читается.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $fi = New-Object System.IO.FileInfo($Path)
    $meta = [ordered]@{
        Path = $fi.FullName; FileName = $fi.Name; Name = [System.IO.Path]::GetFileNameWithoutExtension($fi.Name)
        DisplayName = $null; BundleName = $null; BundleId = $null; Version = $null; Build = $null; MinIOS = $null
        AppStoreId = $null; Artist = $null; SizeBytes = 0; Modified = $null; Error = $null
        # Подпись: AppStore | AdHoc | Development | Enterprise | Distribution | Unsigned | Unknown
        SignType = 'Unknown'; SignTeam = $null; SignProfile = $null; SignExpires = $null; SignDevices = @(); Encrypted = $false
    }
    if (-not $fi.Exists) { $meta.Error = 'File not found'; return [pscustomobject]$meta }
    $meta.SizeBytes = $fi.Length
    $meta.Modified = $fi.LastWriteTime
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($fi.FullName)
        $infoEntry = $null; $itunesEntry = $null; $provEntry = $null; $hasCodeSig = $false
        foreach ($e in $zip.Entries) {
            $n = $e.FullName
            if ($null -eq $infoEntry -and $n -match '^Payload/[^/]+\.app/Info\.plist$') { $infoEntry = $e }
            elseif ($null -eq $itunesEntry -and $n -eq 'iTunesMetadata.plist') { $itunesEntry = $e }
            elseif ($null -eq $provEntry -and $n -match '^Payload/[^/]+\.app/embedded\.mobileprovision$') { $provEntry = $e }
            elseif ($n -match '^Payload/[^/]+\.app/_CodeSignature/CodeResources$') { $hasCodeSig = $true }
        }
        if (-not $infoEntry) { throw 'Info.plist not found' }
        $info = [IPADredd.PlistReader]::Parse((Read-DreddZipEntryBytes $infoEntry))
        $get = { param($k) [IPADredd.PlistReader]::GetString($info, $k) }
        # Флаг шифрования FairPlay в исполняемом файле: 1 — сборка App Store, 0 — расшифрованный IPA.
        $cryptId = $null
        $exeName = & $get 'CFBundleExecutable'
        if ($exeName) {
            $appDir = [regex]::Match($infoEntry.FullName, '^Payload/[^/]+\.app/').Value
            $exeEntry = $zip.GetEntry($appDir + $exeName)
            if ($exeEntry) { try { $cryptId = Get-DreddMachOCryptId (Read-DreddZipEntryHead $exeEntry 4MB) } catch { } }
        }
        $meta.Encrypted = ($cryptId -eq 1)
        $sig = Get-DreddSignatureInfo -ProvisionBytes $(if ($provEntry) { Read-DreddZipEntryBytes $provEntry } else { $null }) `
            -HasItunesMetadata ([bool]$itunesEntry) -CryptId $cryptId -HasCodeSignature $hasCodeSig
        foreach ($k in 'SignType', 'SignTeam', 'SignProfile', 'SignExpires', 'SignDevices') { $meta[$k] = $sig.$k }
        $meta.DisplayName = & $get 'CFBundleDisplayName'
        $meta.BundleName = & $get 'CFBundleName'
        $meta.BundleId = & $get 'CFBundleIdentifier'
        $meta.Version = & $get 'CFBundleShortVersionString'
        $meta.Build = & $get 'CFBundleVersion'
        $meta.MinIOS = & $get 'MinimumOSVersion'
        if ($meta.DisplayName) { $meta.Name = $meta.DisplayName } elseif ($meta.BundleName) { $meta.Name = $meta.BundleName }
        if (-not $meta.Version) { $meta.Version = $meta.Build }
        if ($itunesEntry) {
            try {
                $it = [IPADredd.PlistReader]::Parse((Read-DreddZipEntryBytes $itunesEntry))
                $meta.AppStoreId = [IPADredd.PlistReader]::GetString($it, 'itemId')
                $meta.Artist = [IPADredd.PlistReader]::GetString($it, 'artistName')
                $itName = [IPADredd.PlistReader]::GetString($it, 'itemName')
                if ($itName -and -not $meta.DisplayName) { $meta.Name = $itName }
            } catch { }
        }
    } catch {
        $meta.Error = $_.Exception.Message
    } finally {
        if ($zip) { $zip.Dispose() }
    }
    return [pscustomobject]$meta
}

function Get-DreddSignatureInfo {
    <#
      Тип подписи IPA по embedded.mobileprovision (CMS-контейнер с XML plist внутри) и признакам App Store-сборки.
      Без профиля: iTunesMetadata.plist или SC_Info → AppStore; только _CodeSignature → Unknown; ничего → Unsigned.
    #>
    param([byte[]]$ProvisionBytes, [bool]$HasItunesMetadata, $CryptId, [bool]$HasCodeSignature)
    $r = [ordered]@{ SignType = 'Unknown'; SignTeam = $null; SignProfile = $null; SignExpires = $null; SignDevices = @() }
    if ($ProvisionBytes -and $ProvisionBytes.Length -gt 0) {
        try {
            # Plist лежит в профиле открытым текстом между "<?xml" и "</plist>".
            $latin = [System.Text.Encoding]::GetEncoding(28591).GetString($ProvisionBytes)
            $start = $latin.IndexOf('<?xml')
            $end = $latin.IndexOf('</plist>')
            if ($start -ge 0 -and $end -gt $start) {
                $len = $end + 8 - $start
                $xml = New-Object byte[] $len
                [Array]::Copy($ProvisionBytes, $start, $xml, 0, $len)
                $p = [IPADredd.PlistReader]::Parse($xml)
                $r.SignProfile = [IPADredd.PlistReader]::GetString($p, 'Name')
                $r.SignTeam = [IPADredd.PlistReader]::GetString($p, 'TeamName')
                if ($p.ContainsKey('ExpirationDate') -and $p['ExpirationDate'] -is [datetime]) { $r.SignExpires = ([datetime]$p['ExpirationDate']).ToLocalTime() }
                $devices = @()
                if ($p.ContainsKey('ProvisionedDevices')) { $devices = @($p['ProvisionedDevices'] | ForEach-Object { [string]$_ }) }
                $r.SignDevices = $devices
                $allDevices = $p.ContainsKey('ProvisionsAllDevices') -and $p['ProvisionsAllDevices'] -eq $true
                $getTaskAllow = $false
                if ($p.ContainsKey('Entitlements') -and $p['Entitlements'] -is [System.Collections.IDictionary]) {
                    # У Dictionary<string,object> метод Contains реализован явно — из PowerShell используем ContainsKey.
                    $ent = $p['Entitlements']
                    $getTaskAllow = $ent.ContainsKey('get-task-allow') -and $ent['get-task-allow'] -eq $true
                }
                if ($allDevices) { $r.SignType = 'Enterprise' }
                elseif ($devices.Count -gt 0) { $r.SignType = $(if ($getTaskAllow) { 'Development' } else { 'AdHoc' }) }
                else { $r.SignType = 'Distribution' }
                return [pscustomobject]$r
            }
        } catch { }
    }
    if ($CryptId -eq 0) { $r.SignType = 'Decrypted' }          # подпись Apple нарушена — нужна переподпись
    elseif ($CryptId -eq 1) { $r.SignType = 'AppStore' }
    elseif ($HasItunesMetadata) { $r.SignType = 'AppStore' }
    elseif ($HasCodeSignature) { $r.SignType = 'Unknown' }
    else { $r.SignType = 'Unsigned' }
    return [pscustomobject]$r
}

function Read-DreddZipEntryHead {
    # Первые MaxBytes байт записи zip (заголовок и load commands Mach-O лежат в начале файла).
    param([System.IO.Compression.ZipArchiveEntry]$Entry, [int]$MaxBytes = 4MB)
    $s = $Entry.Open()
    try {
        $want = [int][Math]::Min([long]$MaxBytes, $Entry.Length)
        $buf = New-Object byte[] $want
        $read = 0
        while ($read -lt $want) { $n = $s.Read($buf, $read, $want - $read); if ($n -le 0) { break }; $read += $n }
        if ($read -lt $want) { $tmp = New-Object byte[] $read; [Array]::Copy($buf, $tmp, $read); return , $tmp }
        return , $buf
    } finally { $s.Dispose() }
}

function Get-DreddMachOCryptId {
    # cryptid из LC_ENCRYPTION_INFO(_64) первого среза Mach-O: 1 — зашифрован FairPlay, 0 — нет, $null — не найдено.
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -lt 32) { return $null }
    # Литералы 0xFEEDFACF и т.п. в PowerShell 5.1 — отрицательные int, поэтому константы задаются через ToUInt32.
    $FAT = [Convert]::ToUInt32('CAFEBABE', 16); $MH64 = [Convert]::ToUInt32('FEEDFACF', 16); $MH32 = [Convert]::ToUInt32('FEEDFACE', 16)
    $be = { param($o) ([uint32]$Bytes[$o] -shl 24) -bor ([uint32]$Bytes[$o + 1] -shl 16) -bor ([uint32]$Bytes[$o + 2] -shl 8) -bor [uint32]$Bytes[$o + 3] }
    $le = { param($o) [BitConverter]::ToUInt32($Bytes, $o) }
    $base = 0
    if ((& $be 0) -eq $FAT) {
        # Универсальный бинарник: берём первый срез (fat_arch: cputype, cpusubtype, offset, size, align — big endian).
        if ((& $be 4) -lt 1) { return $null }
        $base = [int](& $be 16)
        if ($base + 32 -gt $Bytes.Length) { return $null }
    }
    $magic = & $le $base
    if ($magic -eq $MH64) { $hdr = 32 } elseif ($magic -eq $MH32) { $hdr = 28 } else { return $null }
    $ncmds = & $le ($base + 16)
    $off = $base + $hdr
    for ($i = 0; $i -lt $ncmds -and $off + 8 -le $Bytes.Length; $i++) {
        $cmd = & $le $off
        $size = & $le ($off + 4)
        if ($cmd -eq 0x21 -or $cmd -eq 0x2C) {
            if ($off + 20 -gt $Bytes.Length) { return $null }
            return [int](& $le ($off + 16))
        }
        if ($size -lt 8) { return $null }
        $off += [int]$size
    }
    return $null
}

function Test-DreddSignatureForDevice {
    <#
      Подходит ли подпись IPA устройству. Возвращает $null (ок) или объект { Key; Blocking }:
      Blocking = $true — iOS почти наверняка откажет в установке; $false — предупреждение.
    #>
    param([string]$SignType, $SignExpires, [string[]]$SignDevices, [string]$Udid)
    switch ($SignType) {
        'Unsigned' { return [pscustomobject]@{ Key = 'Sign.Problem.Unsigned'; Blocking = $true } }
        'Decrypted' { return [pscustomobject]@{ Key = 'Sign.Problem.Decrypted'; Blocking = $true } }
        'Distribution' { return [pscustomobject]@{ Key = 'Sign.Problem.Distribution'; Blocking = $true } }
        'Unknown' { return [pscustomobject]@{ Key = 'Sign.Problem.Unknown'; Blocking = $false } }
    }
    if ($SignExpires -is [datetime] -and $SignExpires -lt (Get-Date)) { return [pscustomobject]@{ Key = 'Sign.Problem.Expired'; Blocking = $true } }
    if ($SignType -in 'AdHoc', 'Development' -and $Udid) {
        $match = @($SignDevices | Where-Object { $_ -and $_.Equals($Udid, [StringComparison]::OrdinalIgnoreCase) })
        if ($match.Count -eq 0) { return [pscustomobject]@{ Key = 'Sign.Problem.NoDevice'; Blocking = $true } }
    }
    if ($SignType -eq 'AppStore') { return [pscustomobject]@{ Key = 'Sign.Problem.AppStore'; Blocking = $false } }
    return $null
}

function Import-DreddIpaToLibrary {
    # Копирует IPA в папку библиотеки (оригинал не трогается, совпадающие имена не перезаписываются). Возвращает путь копии.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Folder)
    $src = [System.IO.Path]::GetFullPath($Path)
    if (-not [System.IO.File]::Exists($src)) { throw "File not found: $src" }
    if (-not [System.IO.Directory]::Exists($Folder)) { [void][System.IO.Directory]::CreateDirectory($Folder) }
    $folderFull = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    if ([System.IO.Path]::GetDirectoryName($src).TrimEnd('\', '/') -eq $folderFull) { return $src }
    $dest = Get-DreddUniquePath -Folder $folderFull -FileName ([System.IO.Path]::GetFileName($src))
    [System.IO.File]::Copy($src, $dest, $false)
    return $dest
}

function Get-DreddLibrary {
    param([Parameter(Mandatory)][string]$Folder, $Reporter, $CancellationToken)
    if (-not [System.IO.Directory]::Exists($Folder)) { return @() }
    $files = @([System.IO.Directory]::GetFiles($Folder, '*.ipa') | ForEach-Object { New-Object System.IO.FileInfo($_) } | Sort-Object LastWriteTime -Descending)
    $out = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($f in $files) {
        if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) { break }
        $n++
        Write-DreddReport -Reporter $Reporter -Type progress -Area 'Library' -Value ([double]$n / [Math]::Max(1, $files.Count) * 100)
        $out.Add((Get-DreddIpaMetadata -Path $f.FullName))
    }
    return $out.ToArray()
}

function ConvertTo-DreddSafeFileName {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() + [char[]]'\/:*?"<>|'
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) { if ($invalid -notcontains $ch -and -not [char]::IsControl($ch)) { [void]$sb.Append($ch) } }
    $s = ($sb.ToString() -replace '\s+', '_').Trim('_', '.', ' ')
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80).TrimEnd('_', '.') }
    return $s
}

function Get-DreddIpaFileName {
    # Шаблон ADR-007: {Name}_{Version}_iOS_{MinIOS}+[_{Account}].ipa
    param([string]$Name, [string]$Version, [string]$MinIOS, [string]$Account)
    $n = ConvertTo-DreddSafeFileName $Name; if (-not $n) { $n = 'App' }
    $v = ConvertTo-DreddSafeFileName $Version; if (-not $v) { $v = 'unknown' }
    $m = ConvertTo-DreddSafeFileName $MinIOS; if (-not $m) { $m = 'NA' }
    $file = "{0}_{1}_iOS_{2}+" -f $n, $v, $m
    $a = ConvertTo-DreddSafeFileName $Account
    if ($a) { $file += "_$a" }
    return "$file.ipa"
}

function Get-DreddUniquePath {
    # Не перезаписывает существующие файлы: name.ipa → name_2.ipa → name_3.ipa …
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$FileName)
    $candidate = Join-Path $Folder $FileName
    if (-not [System.IO.File]::Exists($candidate)) { return $candidate }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext = [System.IO.Path]::GetExtension($FileName)
    for ($i = 2; $i -lt 10000; $i++) {
        $candidate = Join-Path $Folder ("{0}_{1}{2}" -f $base, $i, $ext)
        if (-not [System.IO.File]::Exists($candidate)) { return $candidate }
    }
    throw 'Cannot find a free file name'
}

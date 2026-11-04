# Журналирование и маскирование секретов (ADR-012, SECURITY.md).

$script:ReAnsi = New-Object System.Text.RegularExpressions.Regex('\x1b\[[0-9;?]*[A-Za-z]', 'Compiled')
$script:ReEmail = New-Object System.Text.RegularExpressions.Regex('(?<![\w.+-])([A-Za-z0-9])[A-Za-z0-9._%+-]*@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)', 'Compiled')
$script:ReSecretArg = New-Object System.Text.RegularExpressions.Regex('(?i)(?<=(?:^|\s)(?:-p|--password|-a|--auth-code|--keychain-passphrase)(?:\s+|=))("[^"]*"|\S+)', 'Compiled')
$script:ReSecretHeader = New-Object System.Text.RegularExpressions.Regex('(?i)\b(cookie|set-cookie|authorization|x-dsid|x-apple-[\w-]*token|x-token|mz-[\w-]*token)(\s*[:=]\s*)([^\r\n]+)', 'Compiled')
$script:ReSecretKv = New-Object System.Text.RegularExpressions.Regex('(?i)\b(password|passwordToken|token|dsPersonId|dsid|kbsync|passphrase)(\s*[=:]\s*|"\s*:\s*")([^\s",&]+)', 'Compiled')

function Protect-DreddEmail {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return $script:ReEmail.Replace($Text, '$1***@$2')
}

function Protect-LogText {
    <#
      Удаляет ANSI-коды и маскирует секреты: значения аргументов -p/--password/-a/--auth-code/--keychain-passphrase,
      заголовки cookie/authorization, пары password=/token=, email и явно переданные значения SecretValues.
    #>
    param([AllowNull()][string]$Text, [string[]]$SecretValues)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $t = $script:ReAnsi.Replace($Text, '')
    if ($SecretValues) {
        foreach ($s in $SecretValues) {
            if (-not [string]::IsNullOrEmpty($s) -and $s.Length -ge 3) { $t = $t.Replace($s, '***') }
        }
    }
    $t = $script:ReSecretArg.Replace($t, '***')
    $t = $script:ReSecretHeader.Replace($t, '$1$2***')
    $t = $script:ReSecretKv.Replace($t, '$1$2***')
    $t = Protect-DreddEmail $t
    return $t
}

function Format-DreddLogLine {
    param([string]$Level = 'INFO', [string]$Area = 'App', [string]$Message, [datetime]$Time = (Get-Date))
    return ('{0} [{1}] [{2}] {3}' -f $Time.ToString('HH:mm:ss'), $Level.ToUpperInvariant(), $Area, $Message)
}

function Write-DreddLogFile {
    param([string]$LogsDir, [string]$Line)
    if ([string]::IsNullOrEmpty($LogsDir)) { return }
    try {
        if (-not [System.IO.Directory]::Exists($LogsDir)) { [void][System.IO.Directory]::CreateDirectory($LogsDir) }
        $file = Join-Path $LogsDir ((Get-Date).ToString('yyyy-MM-dd') + '.log')
        [System.IO.File]::AppendAllText($file, $Line + [Environment]::NewLine, $script:Utf8NoBom)
    } catch {
        # Журнал не должен ронять операцию.
    }
}

function Write-DreddReport {
    <#
      Отправляет сообщение «наверх»: в очередь GUI (ConcurrentQueue), в скриптблок или в файл журнала.
      Type: log | progress | status | data
    #>
    param(
        $Reporter,
        [ValidateSet('log', 'progress', 'status', 'data')][string]$Type = 'log',
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')][string]$Level = 'Info',
        [string]$Area = 'Core',
        [string]$Message,
        $Value,
        [string[]]$SecretValues
    )
    if ($Message) { $Message = Protect-LogText -Text $Message -SecretValues $SecretValues }
    $item = [pscustomobject]@{
        Type    = $Type
        Level   = $Level
        Area    = $Area
        Message = $Message
        Value   = $Value
        Time    = Get-Date
        TaskId  = $null
    }
    if ($null -eq $Reporter) { return }
    if ($Reporter -is [scriptblock]) { & $Reporter $item; return }
    # Репортёр задачи GUI: @{ Queue = ConcurrentQueue; TaskId = '...'; LogsDir = '...' }
    if ($Reporter -is [System.Collections.IDictionary] -and $Reporter.Contains('Queue')) {
        $item.TaskId = $Reporter['TaskId']
        $Reporter['Queue'].Enqueue($item)
        return
    }
    if ($Reporter.PSObject.Methods['Enqueue']) { $Reporter.Enqueue($item); return }
    if ($Reporter -is [System.Collections.IList]) { [void]$Reporter.Add($item) }
}

# Запуск внешних программ: построчное чтение вывода без колбэков, отмена, таймаут (ADR-003).

function ConvertTo-DreddArgumentString {
    # Экранирование аргументов по правилам CommandLineToArgvW (Windows) / .NET.
    param([string[]]$ArgumentList)
    $parts = foreach ($a in $ArgumentList) {
        if ($null -eq $a) { continue }
        if ($a.Length -gt 0 -and $a -notmatch '[\s"]') { $a; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $backslashes = 0
        foreach ($ch in $a.ToCharArray()) {
            if ($ch -eq '\') { $backslashes++; continue }
            if ($ch -eq '"') {
                [void]$sb.Append([char]'\', $backslashes * 2 + 1)
                [void]$sb.Append('"')
            } else {
                if ($backslashes -gt 0) { [void]$sb.Append([char]'\', $backslashes) }
                [void]$sb.Append($ch)
            }
            $backslashes = 0
        }
        if ($backslashes -gt 0) { [void]$sb.Append([char]'\', $backslashes * 2) }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    return ($parts -join ' ')
}

function Stop-DreddProcessTree {
    param([System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try {
        if ($Process.HasExited) { return }
        $platform = Get-DreddPlatform
        if ($platform.IsWindows) {
            $tk = Start-Process -FilePath 'taskkill.exe' -ArgumentList '/PID', $Process.Id, '/T', '/F' -WindowStyle Hidden -PassThru -Wait -ErrorAction SilentlyContinue
        }
        if (-not $Process.HasExited) { $Process.Kill() }
    } catch {
        try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
    }
}

function Invoke-DreddProcess {
    <#
      Запускает программу, читает stdout/stderr построчно в цикле опроса (без событий .NET, безопасно для runspace).
      -OnLine  { param($Line, $Stream) }  — вызывается для каждой строки (Stream = 'out' | 'err');
      -OnTick  { }                         — вызывается примерно раз в 500 мс (например, для прогресса по размеру файла);
      -CancellationToken                   — отмена убивает дерево процессов;
      -TimeoutSec                          — 0 = без ограничения.
      Возвращает объект: ExitCode, StdOut, StdErr, Output, Cancelled, TimedOut, Duration, CommandLine (замаскирована).
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory,
        [int]$TimeoutSec = 0,
        $CancellationToken,
        [scriptblock]$OnLine,
        [scriptblock]$OnTick,
        [hashtable]$Environment,
        [string[]]$SecretValues,
        [string]$StandardInput
    )

    $argString = ConvertTo-DreddArgumentString -ArgumentList $ArgumentList
    $maskedCmd = Protect-LogText -Text ("{0} {1}" -f [System.IO.Path]::GetFileName($FilePath), $argString) -SecretValues $SecretValues

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        foreach ($k in $Environment.Keys) { $psi.EnvironmentVariables[$k] = [string]$Environment[$k] }
    }

    $stdout = New-Object System.Text.StringBuilder
    $stderr = New-Object System.Text.StringBuilder
    $all = New-Object System.Collections.Generic.List[string]
    $cancelled = $false
    $timedOut = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    try {
        if ($StandardInput) { $proc.StandardInput.Write($StandardInput) }
        $proc.StandardInput.Close()
    } catch { }

    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()
    $lastTick = 0
    $killedAt = $null

    try {
        while ($true) {
            $didWork = $false

            if ($null -ne $outTask -and $outTask.IsCompleted) {
                $line = $null
                try { $line = $outTask.Result } catch { $line = $null }
                if ($null -eq $line) { $outTask = $null }
                else {
                    [void]$stdout.AppendLine($line); $all.Add($line)
                    if ($OnLine) { try { & $OnLine $line 'out' } catch { } }
                    $outTask = $proc.StandardOutput.ReadLineAsync()
                }
                $didWork = $true
            }
            if ($null -ne $errTask -and $errTask.IsCompleted) {
                $line = $null
                try { $line = $errTask.Result } catch { $line = $null }
                if ($null -eq $line) { $errTask = $null }
                else {
                    [void]$stderr.AppendLine($line); $all.Add($line)
                    if ($OnLine) { try { & $OnLine $line 'err' } catch { } }
                    $errTask = $proc.StandardError.ReadLineAsync()
                }
                $didWork = $true
            }

            if ($null -eq $outTask -and $null -eq $errTask) { break }

            if ($null -eq $killedAt) {
                if ($null -ne $CancellationToken -and $CancellationToken.IsCancellationRequested) {
                    $cancelled = $true
                    Stop-DreddProcessTree -Process $proc
                    $killedAt = $sw.ElapsedMilliseconds
                } elseif ($TimeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -ge $TimeoutSec) {
                    $timedOut = $true
                    Stop-DreddProcessTree -Process $proc
                    $killedAt = $sw.ElapsedMilliseconds
                }
            } elseif (($sw.ElapsedMilliseconds - $killedAt) -gt 3000) {
                # Потоки не закрылись после завершения процесса (держит дочерний процесс) — выходим.
                break
            }

            if ($OnTick -and ($sw.ElapsedMilliseconds - $lastTick) -ge 500) {
                $lastTick = $sw.ElapsedMilliseconds
                try { & $OnTick } catch { }
            }

            if (-not $didWork) { Start-Sleep -Milliseconds 30 }
        }
        if (-not $proc.WaitForExit(5000)) { Stop-DreddProcessTree -Process $proc; [void]$proc.WaitForExit(2000) }
    } finally {
        if (-not $proc.HasExited) { Stop-DreddProcessTree -Process $proc }
    }

    $exitCode = -1
    try { $exitCode = $proc.ExitCode } catch { }
    $proc.Dispose()
    $sw.Stop()

    [pscustomobject]@{
        ExitCode    = $exitCode
        StdOut      = $stdout.ToString()
        StdErr      = $stderr.ToString()
        Output      = ($all -join [Environment]::NewLine)
        Lines       = $all.ToArray()
        Cancelled   = $cancelled
        TimedOut    = $timedOut
        Duration    = $sw.Elapsed
        CommandLine = $maskedCmd
        Success     = ($exitCode -eq 0 -and -not $cancelled -and -not $timedOut)
    }
}

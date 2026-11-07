# Фоновые задачи: runspace-пул + очередь сообщений + DispatcherTimer (ADR-003).
# Скрипт задачи передаётся строкой и выполняется в runspace с импортированным IPADredd.Core.
# Внутри доступны: $Context, $Reporter, $Token (CancellationToken), $A (hashtable аргументов).

$script:TaskQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:Tasks = [ordered]@{}
$script:RunspacePool = $null
$script:TaskTimer = $null

$script:TaskWrapper = @'
param($__script, $Context, $Reporter, $Token, $A)
$ErrorActionPreference = 'Stop'
$__sb = [scriptblock]::Create($__script)
. $__sb
'@

function Initialize-DreddTaskRunner {
    param([Parameter(Mandatory)][string]$CoreModulePath, [int]$MaxThreads = 8)
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { }
    $iss.ImportPSModule(@($CoreModulePath))
    $script:RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $iss, $Host)
    $script:RunspacePool.Open()

    $script:TaskTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:TaskTimer.Interval = [TimeSpan]::FromMilliseconds(100)
    $script:TaskTimer.Add_Tick({ Invoke-DreddTaskPump })
    $script:TaskTimer.Start()
}

function Start-DreddTask {
    <#
      -Name       короткое имя для журнала/индикатора
      -Script     текст скрипта (строка или scriptblock — используется только его текст)
      -Arguments  hashtable, доступен в задаче как $A
      -OnComplete { param($Result, $Task) }  — в потоке UI, $Result = последний объект вывода
      -OnError    { param($Message, $Task) }
      -OnMessage  { param($Item, $Task) }    — progress/status/data-сообщения задачи (в потоке UI)
      -Silent     не показывать в глобальном индикаторе занятости
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Script,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnComplete,
        [scriptblock]$OnError,
        [scriptblock]$OnMessage,
        [switch]$Silent
    )
    $id = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $cts = New-Object System.Threading.CancellationTokenSource
    $reporter = @{ Queue = $script:TaskQueue; TaskId = $id }
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $script:RunspacePool
    [void]$ps.AddScript($script:TaskWrapper).AddArgument([string]$Script).AddArgument($script:Ctx).AddArgument($reporter).AddArgument($cts.Token).AddArgument($Arguments)
    $task = [pscustomobject]@{
        Id = $id; Name = $Name; PowerShell = $ps; Handle = $null; Cts = $cts
        OnComplete = $OnComplete; OnError = $OnError; OnMessage = $OnMessage; Silent = [bool]$Silent
        Started = Get-Date; Cancelled = $false
    }
    $script:Tasks[$id] = $task
    $task.Handle = $ps.BeginInvoke()
    Add-DreddLog -Level Debug -Area 'Task' -Message "start $Name [$id]"
    Update-DreddBusyIndicator
    return $task
}

function Stop-DreddTask {
    param([string]$Id)
    if ($Id -and $script:Tasks.Contains($Id)) {
        $t = $script:Tasks[$Id]
        $t.Cancelled = $true
        try { $t.Cts.Cancel() } catch { }
    }
}

function Stop-AllDreddTasks {
    foreach ($id in @($script:Tasks.Keys)) { Stop-DreddTask $id }
}

function Get-DreddActiveTaskCount { return $script:Tasks.Count }

function Invoke-DreddTaskPump {
    # 1) разбираем очередь сообщений; 2) завершаем выполненные задачи.
    $item = $null
    $n = 0
    while ($n -lt 500 -and $script:TaskQueue.TryDequeue([ref]$item)) {
        $n++
        try {
            $task = $null
            if ($item.TaskId -and $script:Tasks.Contains($item.TaskId)) { $task = $script:Tasks[$item.TaskId] }
            if ($item.Type -eq 'log') {
                Add-DreddLog -Level $item.Level -Area $item.Area -Message $item.Message
            } elseif ($task -and $task.OnMessage) {
                & $task.OnMessage $item $task
            }
            if ($item.Type -eq 'status' -and $item.Message -and $task -and -not $task.Silent) {
                $script:UI.GlobalBusyText.Text = "$($task.Name): $(T ("Status.Step.$($item.Message)"))"
            }
        } catch { Write-DreddUiError $_ 'Task' }
    }

    foreach ($id in @($script:Tasks.Keys)) {
        $t = $script:Tasks[$id]
        if (-not $t.Handle.IsCompleted) { continue }
        $script:Tasks.Remove($id)
        $result = $null; $errMsg = $null
        try {
            $out = $t.PowerShell.EndInvoke($t.Handle)
            if ($out -and $out.Count -gt 0) { $result = $out[$out.Count - 1] }
            if ($t.PowerShell.HadErrors -and $null -eq $result) {
                $e = $t.PowerShell.Streams.Error | Select-Object -First 1
                if ($e) { $errMsg = $e.Exception.Message }
            }
        } catch {
            $ex = $_.Exception
            while ($ex.InnerException) { $ex = $ex.InnerException }
            $errMsg = $ex.Message
        } finally {
            try { $t.PowerShell.Dispose() } catch { }
            try { $t.Cts.Dispose() } catch { }
        }
        Add-DreddLog -Level Debug -Area 'Task' -Message ("end {0} [{1}] {2:N1}s" -f $t.Name, $id, ((Get-Date) - $t.Started).TotalSeconds)
        try {
            if ($errMsg) {
                if ($t.OnError) { & $t.OnError $errMsg $t }
                else { Add-DreddLog -Level Error -Area $t.Name -Message $errMsg }
            } elseif ($t.OnComplete) {
                & $t.OnComplete $result $t
            }
        } catch { Write-DreddUiError $_ 'Task' }
        Update-DreddBusyIndicator
    }
}

function Update-DreddBusyIndicator {
    $visible = @($script:Tasks.Values | Where-Object { -not $_.Silent })
    if ($null -eq $script:UI['GlobalBusy']) { return }
    if ($visible.Count -gt 0) {
        $script:UI.GlobalBusy.Visibility = 'Visible'
        if (-not $script:UI.GlobalBusyText.Text) { $script:UI.GlobalBusyText.Text = $visible[0].Name }
    } else {
        $script:UI.GlobalBusy.Visibility = 'Collapsed'
        $script:UI.GlobalBusyText.Text = ''
    }
    $script:UI.StatusRight.Text = if ($script:Tasks.Count -gt 0) { TF 'Side.Tasks' @($script:Tasks.Count) } else { '' }
}

function Close-DreddTaskRunner {
    param([int]$WaitMs = 4000)
    Stop-AllDreddTasks
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($script:Tasks.Count -gt 0 -and $sw.ElapsedMilliseconds -lt $WaitMs) {
        foreach ($id in @($script:Tasks.Keys)) {
            if ($script:Tasks[$id].Handle.IsCompleted) { try { $script:Tasks[$id].PowerShell.Dispose() } catch { }; $script:Tasks.Remove($id) }
        }
        Start-Sleep -Milliseconds 100
    }
    if ($script:TaskTimer) { $script:TaskTimer.Stop() }
    if ($script:RunspacePool) { try { $script:RunspacePool.Close(); $script:RunspacePool.Dispose() } catch { } }
}

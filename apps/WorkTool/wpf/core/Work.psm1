# 화면 밖 작업. 디스크 · 네트워크(공유 폴더)에 닿는 일과 다른 앱에 묻는 일은 화면 스레드에서 하지 않고 이 모듈로 보낸다.
# 탭은 실행 공간 · 스레드를 직접 만들지 않고 이 모듈의 함수만 쓴다 (tests\Test-Core.ps1이 검사).
#
#   Start-WtWork { param($path) ... } -ArgumentList $path -OnDone { param($w) ... }
#       화면 밖에서 PowerShell 코드를 돌린다. 끝나면 화면 스레드에서 -OnDone을 부른다 ($w.Result · $w.Error · $w.TimedOut · $w.Context).
#   Invoke-WtWork { ... } -TimeoutMs 5000         화면 밖에서 돌리고 정한 시간까지만 기다린다 (저장처럼 결과가 바로 필요할 때)
#   Wait-WtWork $w -Milliseconds 80               정한 시간까지만 기다린다. 로컬 경로는 이 안에 끝나서 화면이 깜빡이지 않는다
#   Open-WtPath $path                             파일 · 폴더를 원래 프로그램 · 탐색기로 연다 (있는지 확인과 셸 열기 모두 화면 밖)
#   Start-WtWork -Call (New-WtCall ([System.IO.File]) ReadAllText $path)
#       .NET 메서드 하나만 부를 때는 실행 공간 없이 스레드 풀에서 부른다 (가장 빠르다. 파일 읽기 · 있는지 보기 등)
#
# - PowerShell 코드는 실행 공간 하나에서 새 스레드로 돈다. 정상으로 끝난 실행 공간은 상태(변수)를 지우고 다시 쓴다.
#   끝나지 않았거나 멈춘 작업의 실행 공간은 다시 쓰지 않는다. 작업끼리 변수가 섞이지 않는다.
#   기본은 빈 세션(언어와 .NET만, 명령 없음)이라 빠르다. Get-ChildItem 같은 명령이 필요하면 -Session Default.
#   -Call 작업은 스레드 풀(백그라운드 스레드)에서 돌아서, 끝나지 않아도 프로세스가 끝나는 것을 붙잡지 않는다.
# - 끝나지 않는 작업(응답 없는 공유 폴더의 OS 요청)은 기다리지 않고 버린다. 취소 · 시간 초과 · 앱 종료 모두 같다.
#   실행 공간의 Stop · Close · Dispose는 그 작업이 끝나기를 기다리므로 끝나지 않은 작업에는 부르지 않는다.
#   버린 작업은 끝나는 대로 치운다. 같은 키(-Key)에 시간이 지난 작업이 남아 있으면 Test-WtWorkStuck이 $true다.
# - PowerShell은 프로세스가 끝날 때 열린 실행 공간을 모두 닫으며 그 안의 작업이 끝나기를 기다린다(PowerShell 7.6 LocalRunspace).
#   그래서 앱 전용 프로세스는 마지막에 Exit-WtOwnProcess로 끝낸다. 버린 작업이 남아도 프로세스가 끝난다.
#
# 이벤트 처리기 · -OnDone은 나중에 불리므로, 만든 함수의 지역 변수 대신 $w.Context와 $script: 변수를 쓴다.

$ErrorActionPreference = 'Stop'

$script:jobs = [System.Collections.Generic.List[object]]::new()   # 끝나지 않은 작업 (버린 것 포함)
$script:timer = $null
$script:nextId = 0
$script:maxJobs = 64       # 끝나지 않은 작업이 이만큼이면 새로 시작하지 않는다 (응답 없는 경로를 계속 눌러도 스레드가 끝없이 늘지 않게)
$script:pollMs = 30        # 끝난 작업을 화면으로 가져오는 간격
$script:sessions = @{}     # 세션 틀. 실행 공간을 만들 때마다 복사해 쓴다
$script:idle = @{}         # 다시 쓸 실행 공간 (세션|아파트 → Stack). 정상으로 끝난 작업의 것만, 상태를 지운 뒤 넣는다
$script:idleMax = 2        # 종류(세션 · 아파트)마다 남겨 둘 수. 기본 명령 세션은 메모리를 더 써서 적게 둔다
$script:taskRun = $null    # Task.Run<T>(Func<T>) 정의. 결과 형식마다 닫은 것을 아래 표에 둔다
$script:taskRunTyped = @{}

# ---- 작업 ------------------------------------------------------------------------------------

<#
.NET 메서드 하나를 인수 없는 호출로 묶는다. Start-WtWork -Call · Invoke-WtWork -Call에 넘긴다.
  New-WtCall ([System.IO.File]) ReadAllText $path    정적 메서드와 그 첫 인수 (글자 · 객체처럼 참조 형식인 인수 하나)
  New-WtCall $fileInfo get_Length                    객체의 인수 없는 메서드
#>
function New-WtCall {
    param([Parameter(Mandatory, Position = 0)]$Target, [Parameter(Mandatory, Position = 1)][string]$Method, [Parameter(Position = 2)]$Argument)
    if ($Target -is [type]) {
        $mi = $Target.GetMethod($Method, [type[]]@($Argument.GetType()))
        $bound = $Argument
    } else {
        $mi = $Target.GetType().GetMethod($Method, [type[]]@())
        $bound = $Target
    }
    if (-not $mi) { throw [System.MissingMethodException]::new("$Method 메서드를 찾지 못했습니다.") }
    [Delegate]::CreateDelegate([System.Func`1].MakeGenericType($mi.ReturnType), $bound, $mi)
}

# 묶은 호출을 스레드 풀에서 시작한다 (Task.Run). 실행 공간도 PowerShell 코드도 쓰지 않는다
function Start-WtWorkCall([Delegate]$Call) {
    $type = $Call.Method.ReturnType
    if (-not $script:taskRunTyped.ContainsKey($type)) {
        if (-not $script:taskRun) {
            $script:taskRun = [System.Threading.Tasks.Task].GetMethods() | Where-Object {
                $_.Name -eq 'Run' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'Func`1' -and $_.GetParameters()[0].ParameterType.GetGenericArguments()[0].IsGenericParameter
            } | Select-Object -First 1
        }
        $script:taskRunTyped[$type] = $script:taskRun.MakeGenericMethod($type)
    }
    $script:taskRunTyped[$type].Invoke($null, @($Call))
}

# 실행 공간 하나: 남겨 둔 것이 있으면 그것을, 없으면 새로 연다
function Get-WtWorkRunspace([string]$Session, [bool]$Sta) {
    $kind = "$Session|$(if ($Sta) { 'STA' } else { 'MTA' })"
    $stack = $script:idle[$kind]
    while ($stack -and $stack.Count) {
        $rs = $stack.Pop()
        if ($rs.RunspaceStateInfo.State -eq 'Opened' -and $rs.RunspaceAvailability -eq 'Available') { return $rs }
        try { $rs.Dispose() } catch { }
    }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace((Get-WtWorkSession $Session))
    # 호출마다 새 스레드. ReuseThread는 실행 공간을 버리기 전까지 스레드를 붙잡는다
    $rs.ThreadOptions = 'UseNewThread'
    $rs.ApartmentState = if ($Sta) { 'STA' } else { 'MTA' }
    try { $rs.Open() } catch { $rs.Dispose(); throw }
    $rs
}

# 정상으로 끝난 작업의 실행 공간: 변수를 지우고 남겨 둔다 (자리가 없으면 버린다)
function Save-WtWorkRunspace($Job) {
    $rs = $Job.Runspace
    $kind = "$($Job.Session)|$(if ($Job.Sta) { 'STA' } else { 'MTA' })"
    if (-not $script:idle.ContainsKey($kind)) { $script:idle[$kind] = [System.Collections.Generic.Stack[object]]::new() }
    $stack = $script:idle[$kind]
    if ($stack.Count -lt $script:idleMax -and $rs.RunspaceStateInfo.State -eq 'Opened') {
        try { $rs.ResetRunspaceState(); $stack.Push($rs); return } catch { }
    }
    try { $rs.Dispose() } catch { }
}

function Get-WtWorkSession([string]$Kind) {
    if (-not $script:sessions.ContainsKey($Kind)) {
        $iss = if ($Kind -eq 'Default') { [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault() }
        else {
            # 빈 세션: 명령은 하나도 넣지 않는다. 빈 세션의 기본 언어 모드(NoLanguage)는 스크립트를 못 돌려서 보통 PowerShell과 같게 둔다
            $empty = [System.Management.Automation.Runspaces.InitialSessionState]::Create()
            $empty.LanguageMode = 'FullLanguage'
            $empty
        }
        $script:sessions[$Kind] = $iss
    }
    $script:sessions[$Kind]
}

<#
화면 밖에서 PowerShell 코드를 돌린다. 기다리지 않고 바로 돌아온다. 작업 객체를 돌려준다.
  -Script        { param(...) ... } 또는 같은 글. 마지막 출력이 결과($w.Result). 배열을 결과 하나로 주려면 , @(...)
                 실행 공간 전역에 $WtCancel이 있다. 취소 · 시간 초과면 $WtCancel.Value가 $true (긴 작업은 사이사이 본다)
  -ArgumentList  넘길 값들 (차례대로 param에 들어간다). 배열 하나를 넘기려면 -ArgumentList (, $array)
  -Functions     이 코드가 부르는 함수 (Get-Command 결과). 정의를 코드 앞에 붙인다
  -Session       Empty(기본: 언어 · .NET만, 가장 빠름) | Default(기본 명령 · 모듈)
  -Sta           STA 스레드에서 돌린다 (셸 열기 · 클립보드 · UI Automation 일부)
  -OnDone        { param($w) } 끝나면(성공 · 실패 · 시간 초과) 화면 스레드에서 한 번 부른다. Stop-WtWork로 멈춘 작업은 부르지 않는다
                 $w.State: done · failed · timedout, $w.Result · $w.Error(글) · $w.Exception · $w.TimedOut · $w.Context
  -Context       -OnDone에 그대로 넘길 값
  -Key           같은 대상(예: 같은 공유 폴더)을 묶는 이름. 이 키로 시간이 지난 작업이 남아 있으면 Test-WtWorkStuck이 $true
  -TimeoutMs     이 시간 안에 끝나지 않으면 기다리지 않고 timedout으로 -OnDone을 부른다 (작업은 버린다). 0이면 끝날 때까지
  -WaitMs        시작한 뒤 이 시간까지는 기다린다. 그 안에 끝나면 -OnDone을 부르고 돌아온다
                 -OnDone 안에서 부른 쪽의 상태를 바꾸면, 부른 함수가 끝난 뒤 Wait-WtWork로 기다리는 편이 안전하다
  -Call          -Script 대신 New-WtCall로 묶은 .NET 호출 하나. 실행 공간 없이 스레드 풀에서 부른다 ($WtCancel 없음)
  -Reserved      끝나지 않은 작업 수 한도($script:maxJobs)를 보지 않는다. 수가 정해진 작업만 쓴다:
                 한 번에 하나씩 도는 통로(저장 · 잠금)와 실행 하나에 하나뿐인 정리(남은 자식 끝내기).
                 응답 없는 읽기가 한도를 채워도 저장 · 정리는 막히지 않게
되돌릴 수 없는 일(셸 열기 · 프로세스 만들기)을 하는 코드는 그 직전에 잠금 안에서 취소를 보고 $WtCancel.Committed를 $true로 둔다:
  [System.Threading.Monitor]::Enter($WtCancel.SyncRoot); try { if ($WtCancel.Value) { return }; $WtCancel.Committed = $true } finally { [System.Threading.Monitor]::Exit($WtCancel.SyncRoot) }
  그러면 시간 초과 · 멈춤 때 $w.Committed로 「이미 넘겼는지」를 정확히 안다 (넘기기 전이면 끝내 하지 않는다)
#>
function Start-WtWork {
    param(
        [Parameter(Position = 0)]$Script,
        [object[]]$ArgumentList = @(),
        [System.Management.Automation.CommandInfo[]]$Functions = @(),
        [ValidateSet('Empty', 'Default')][string]$Session = 'Empty',
        [switch]$Sta,
        [scriptblock]$OnDone,
        $Context = $null,
        [string]$Key = '',
        [int]$TimeoutMs = 0,
        [int]$WaitMs = 0,
        [Delegate]$Call,
        [switch]$Reserved
    )
    if (-not $Script -and -not $Call) { throw [System.ArgumentException]::new('-Script나 -Call을 주세요.') }
    Clear-WtWorkFinished
    if (-not $Reserved -and $script:jobs.Count -ge $script:maxJobs) {
        throw [System.InvalidOperationException]::new('응답하지 않는 작업이 많아 새 작업을 시작하지 않습니다. 네트워크 연결을 확인하고 잠시 뒤 다시 시도하세요.')
    }
    $job = New-WtWorkJob $Key
    $job.Context = $Context; $job.OnDone = $OnDone; $job.TimeoutMs = $TimeoutMs; $job.Session = $Session; $job.Sta = [bool]$Sta
    if ($Call) {
        $job.Task = Start-WtWorkCall $Call
        $job.Handle = $job.Task
    } else {
        # 함수 정의를 앞에 두고 본문은 스크립트 블록으로 감싸 넘긴 값을 그대로 param에 넣는다 (글을 코드로 바꾸는 Invoke-Expression · ScriptBlock.Create 없음)
        $text = [System.Text.StringBuilder]::new()
        [void]$text.Append("`$ErrorActionPreference = 'Stop'`n")
        foreach ($f in $Functions) { [void]$text.Append("function $($f.Name) {`n$($f.Definition)`n}`n") }
        [void]$text.Append("& {`n$(if ($Script -is [scriptblock]) { $Script.ToString() } else { [string]$Script })`n} @args`n")
        $rs = Get-WtWorkRunspace $Session ([bool]$Sta)
        $ps = $null
        try {
            $rs.SessionStateProxy.SetVariable('WtCancel', $job.Cancel)
            $ps = [powershell]::Create()
            $ps.Runspace = $rs
            [void]$ps.AddScript($text.ToString(), $true)
            foreach ($a in $ArgumentList) { [void]$ps.AddArgument($a) }
            $job.PowerShell = $ps; $job.Runspace = $rs
            $job.Handle = $ps.BeginInvoke()
        } catch {
            if ($ps) { $ps.Dispose() }
            $rs.Dispose()
            throw
        }
    }
    $script:jobs.Add($job)
    if ($WaitMs -gt 0) { [void](Wait-WtWork $job -Milliseconds $WaitMs) }
    if (-not $job.Finished -and ($OnDone -or $TimeoutMs -gt 0)) { Start-WtWorkTimer }
    $job
}

# 취소 표시를 한다. 작업 코드가 같은 잠금 안에서 「되돌릴 수 없는 일을 시작함(Committed)」을 표시하므로, 둘 중 하나만 먼저 일어난다
function Set-WtWorkCancel($Job) {
    $c = $Job.Cancel
    [System.Threading.Monitor]::Enter($c.SyncRoot)
    try { $c.Value = $true; $Job.Committed = [bool]$c.Committed } finally { [System.Threading.Monitor]::Exit($c.SyncRoot) }
}

# 작업 기록 하나
function New-WtWorkJob([string]$Key) {
    $script:nextId++
    [pscustomobject]@{
        Id = $script:nextId; Key = $Key; State = 'running'; Result = $null; Output = @(); Error = $null; Exception = $null
        TimedOut = $false; Stuck = $false; Stopped = $false; Finished = $false; Committed = $false; Context = $null; OnDone = $null
        TimeoutMs = 0; Watch = [System.Diagnostics.Stopwatch]::StartNew(); Cancel = [hashtable]::Synchronized(@{ Value = $false })
        Session = 'Empty'; Sta = $false; PowerShell = $null; Runspace = $null; Task = $null; Handle = $null
    }
}

# 끝난 작업의 결과를 거두고 실행 공간을 버린다. 처음 끝났을 때만 -OnDone을 부른다
function Complete-WtWorkJob($Job) {
    if ($Job.Finished) { return }
    $Job.Finished = $true
    [void]$script:jobs.Remove($Job)
    $wasRunning = $Job.State -eq 'running'
    if ($Job.Task) {
        if ($Job.Task.IsFaulted -or $Job.Task.IsCanceled) {
            $Job.Exception = if ($Job.Task.Exception) { $Job.Task.Exception.GetBaseException() } else { [System.OperationCanceledException]::new() }
            $Job.Error = $Job.Exception.Message
            if ($wasRunning) { $Job.State = 'failed' }
        } else {
            $Job.Result = $Job.Task.Result
            $Job.Output = @(, $Job.Result)
            if ($wasRunning) { $Job.State = 'done' }
        }
        $Job.Task = $null; $Job.Handle = $null
    } else {
        $reuse = $false
        try {
            $out = $Job.PowerShell.EndInvoke($Job.Handle)
            $Job.Output = @($out)
            if ($out.Count) {
                $r = $out[$out.Count - 1]
                # 해시 테이블 · 배열 · .NET 객체는 감싼 것을 벗긴다 (PSCustomObject는 그대로)
                if ($null -ne $r -and $r.psobject.BaseObject -isnot [System.Management.Automation.PSCustomObject]) { $r = $r.psobject.BaseObject }
                $Job.Result = $r
            }
            if ($wasRunning) { $Job.State = 'done' }
            $reuse = $wasRunning
        } catch {
            $Job.Exception = Get-WtWorkException $_.Exception
            $Job.Error = $Job.Exception.Message
            if ($wasRunning) { $Job.State = 'failed' }
            $reuse = $wasRunning
        } finally {
            try { $Job.PowerShell.Dispose() } catch { }
            # 제때 끝난 작업의 실행 공간만 다시 쓴다 (시간이 지났거나 멈춘 작업의 것은 버린다)
            if ($reuse) { Save-WtWorkRunspace $Job } else { try { $Job.Runspace.Dispose() } catch { } }
            $Job.PowerShell = $null; $Job.Runspace = $null
        }
    }
    if ($wasRunning -and $Job.OnDone) { Invoke-WtWorkDone $Job }
}

# 작업 안에서 난 오류의 원래 예외 (IOException 등). EndInvoke · 메서드 호출이 감싼 것을 벗긴다
function Get-WtWorkException([Exception]$Exception) {
    $e = $Exception.GetBaseException()
    if ($e -is [System.Management.Automation.IContainsErrorRecord] -and $e.ErrorRecord.Exception -and
        -not [object]::ReferenceEquals($e.ErrorRecord.Exception, $e)) { $e = $e.ErrorRecord.Exception.GetBaseException() }
    $e
}

function Invoke-WtWorkDone($Job) {
    try { [void](& $Job.OnDone $Job) }
    catch {
        try { Show-WtError $_ '화면 밖 작업 결과' } catch { Write-Warning "화면 밖 작업 결과 처리 실패: $($_.Exception.Message)" }
    }
}

# 끝난 작업을 거두고, 시간이 지난 작업을 알린다. 화면 타이머가 부르고, 검사에서도 직접 부른다
function Update-WtWork {
    foreach ($j in @($script:jobs.ToArray())) {
        if ($j.Finished) { continue }
        if ($j.Handle.IsCompleted) { Complete-WtWorkJob $j; continue }
        if ($j.State -eq 'running' -and $j.TimeoutMs -gt 0 -and $j.Watch.ElapsedMilliseconds -ge $j.TimeoutMs) {
            $j.State = 'timedout'; $j.TimedOut = $true; $j.Stuck = $true; Set-WtWorkCancel $j
            if ($j.OnDone) { Invoke-WtWorkDone $j }
        }
    }
    if ($script:timer -and -not (Test-WtWorkWatched)) { $script:timer.Stop() }
}

# 타이머로 지켜볼 작업(결과를 기다리거나 시간을 재는 작업)이 남았는지
function Test-WtWorkWatched {
    foreach ($j in $script:jobs) { if ($j.State -eq 'running' -and ($j.OnDone -or $j.TimeoutMs -gt 0)) { return $true } }
    $false
}

# 버린 작업 중 끝난 것을 치운다 (-OnDone은 부르지 않는다)
function Clear-WtWorkFinished {
    foreach ($j in @($script:jobs.ToArray())) {
        if ($j.State -ne 'running' -and -not $j.Finished -and $j.Handle.IsCompleted) { Complete-WtWorkJob $j }
    }
}

function Start-WtWorkTimer {
    if (-not $script:timer) {
        $type = 'System.Windows.Threading.DispatcherTimer' -as [type]
        if (-not $type) { return }   # WPF가 없으면(검사) Update-WtWork · Wait-WtWork로 거둔다
        $script:timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
        $script:timer.Interval = [TimeSpan]::FromMilliseconds($script:pollMs)
        $script:timer.Add_Tick({
                try { Update-WtWork } catch { try { Show-WtError $_ '화면 밖 작업' } catch { } }
            })
    }
    if (-not $script:timer.IsEnabled) { $script:timer.Start() }
}

<#
작업이 끝나기를 정한 시간까지만 기다린다. 그 안에 끝난 것은 거두고 -OnDone을 부른다. 모두 끝났으면 $true.
  -All  지금 도는 작업 모두 (시간이 지나 버린 것은 빼고). 검사에서 쓴다
#>
function Wait-WtWork {
    param([Parameter(Position = 0)][object[]]$Job = @(), [int]$Milliseconds = 0, [switch]$All)
    $targets = [System.Collections.Generic.List[object]]::new()
    if ($All) { foreach ($j in $script:jobs) { if ($j.State -eq 'running') { $targets.Add($j) } } }
    else { foreach ($j in $Job) { if ($j) { $targets.Add($j) } } }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($j in $targets) {
        if ($j.Finished -or $j.Handle.IsCompleted) { continue }
        $left = $Milliseconds - $watch.ElapsedMilliseconds
        if ($left -le 0) { break }
        if ($j.Task) { [void][System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($j.Task), [int]$left) }
        else { [void]$j.Handle.AsyncWaitHandle.WaitOne([int]$left) }
    }
    $finished = $true
    foreach ($j in $targets) {
        if (-not $j.Finished -and $j.Handle.IsCompleted) { Complete-WtWorkJob $j }
        if (-not $j.Finished) { $finished = $false }
    }
    $finished
}

# 작업을 멈춘다. 기다리지 않는다: 취소 표시($WtCancel)만 하고 버린다. -OnDone은 부르지 않는다
function Stop-WtWork([Parameter(Position = 0)][object[]]$Job) {
    foreach ($j in @($Job)) {
        if (-not $j -or $j.Finished) { continue }
        Set-WtWorkCancel $j
        $j.Stopped = $true
        $j.OnDone = $null
        if ($j.State -eq 'running') { $j.State = 'stopped' }
        if ($j.Handle.IsCompleted) { Complete-WtWorkJob $j }
    }
}

# 앱을 끝낼 때 셸이 부른다. 남은 작업을 모두 버리고 기다리지 않는다
function Stop-WtAllWork {
    Stop-WtWork @($script:jobs.ToArray())
    if ($script:timer) { $script:timer.Stop() }
    Update-WtPathCursor
}

# 이 키로 시간이 지나 버린 작업이 아직 돌고 있는지 (응답 없는 공유 폴더에 또 묻지 않으려고 본다)
# -SlowerThanMs: 시간이 지나지 않았어도 이만큼 넘게 도는 작업이 있으면 $true (느린 곳은 기다리지 않으려고 본다)
function Test-WtWorkStuck([string]$Key, [int]$SlowerThanMs = 0) {
    if (-not $Key) { return $false }
    Clear-WtWorkFinished
    foreach ($j in $script:jobs) {
        if ($j.Finished -or $j.Key -ne $Key) { continue }
        if ($j.Stuck -or ($SlowerThanMs -gt 0 -and $j.Watch.ElapsedMilliseconds -ge $SlowerThanMs)) { return $true }
    }
    $false
}

<#
화면 밖에서 돌리고 정한 시간까지만 기다려 결과를 돌려준다. 실패하면 작업 안의 예외를 그대로 올린다.
시간 안에 끝나지 않으면 TimeoutException (작업은 버린다). 같은 키에 시간이 지난 작업이 남아 있으면 기다리지 않고 바로 TimeoutException.
#>
function Invoke-WtWork {
    param(
        [Parameter(Position = 0)]$Script,
        [object[]]$ArgumentList = @(),
        [System.Management.Automation.CommandInfo[]]$Functions = @(),
        [ValidateSet('Empty', 'Default')][string]$Session = 'Empty',
        [switch]$Sta,
        [string]$Key = '',
        [Parameter(Mandatory)][int]$TimeoutMs,
        [Delegate]$Call,
        [switch]$Reserved
    )
    if (Test-WtWorkStuck $Key) { throw [System.TimeoutException]::new('앞서 보낸 요청이 아직 응답하지 않습니다.') }
    if ($Call) {
        # 호출 하나는 작업 기록 없이 바로 기다린다 (가장 잦은 저장 읽기용). 시간이 지났을 때만 기록해 이 키를 「답 없음」으로 둔다
        $task = Start-WtWorkCall $Call
        if (-not $task.IsCompleted -and [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($task), $TimeoutMs) -lt 0) {
            $late = New-WtWorkJob $Key
            $late.State = 'timedout'; $late.TimedOut = $true; $late.Stuck = $true; $late.Task = $task; $late.Handle = $task
            $script:jobs.Add($late)
            throw [System.TimeoutException]::new("$([Math]::Ceiling($TimeoutMs / 1000))초 안에 응답하지 않았습니다.")
        }
        if ($task.IsFaulted -or $task.IsCanceled) { throw $(if ($task.Exception) { $task.Exception.GetBaseException() } else { [System.OperationCanceledException]::new() }) }
        return , $task.Result
    }
    $job = Start-WtWork -Script $Script -ArgumentList $ArgumentList -Functions $Functions -Session $Session -Sta:$Sta -Key $Key -Reserved:$Reserved
    if (-not (Wait-WtWork $job -Milliseconds $TimeoutMs)) {
        $job.State = 'timedout'; $job.TimedOut = $true; $job.Stuck = $true; Set-WtWorkCancel $job
        throw [System.TimeoutException]::new("$([Math]::Ceiling($TimeoutMs / 1000))초 안에 응답하지 않았습니다.")
    }
    if ($job.State -eq 'failed') { throw $job.Exception }
    , $job.Result
}

# 지금 상태 (검사 · 진단용): 도는 작업 · 버린 작업 수 · 타이머
function Get-WtWorkInfo {
    Clear-WtWorkFinished
    [pscustomobject]@{
        Running = @($script:jobs | Where-Object { $_.State -eq 'running' }).Count
        Abandoned = @($script:jobs | Where-Object { $_.State -ne 'running' }).Count
        Timer = [bool]($script:timer -and $script:timer.IsEnabled)
    }
}

# 경로가 속한 곳(드라이브 · \\서버\공유)의 키. 같은 곳에 응답 없는 작업이 남았는지 볼 때 쓴다
function Get-WtPathKey([string]$Path) {
    $root = ''
    try { $root = [System.IO.Path]::GetPathRoot($Path) } catch { }
    'path:' + ([string]$root).TrimEnd('\', '/').ToLowerInvariant()
}

# ---- 앱 프로세스 끝내기 ----------------------------------------------------------------------

# 이 프로세스가 이 스크립트만을 위해 띄운 것인지: 명령 줄이 -File <이 스크립트>이고 -NoExit가 없다
# (사용자가 쓰던 PowerShell 창에서 바로 띄운 경우는 아니다. 그 창을 끄면 안 된다)
function Test-WtOwnProcess([Parameter(Mandatory)][string]$ScriptPath) {
    $argv = [Environment]::GetCommandLineArgs()
    for ($i = 1; $i -lt $argv.Count; $i++) {
        $a = [string]$argv[$i]
        if ($a -match '^-(?i:noe|noex|noexi|noexit)$') { return $false }
        if ($a -match '^-(?i:c|co|com|comm|comma|comman|command|cwa|commandwithargs|e|ec|encodedcommand)$') { return $false }
        if ($a -match '^-(?i:f|fi|fil|file)$') {
            if ($i + 1 -ge $argv.Count) { return $false }
            try { return [System.IO.Path]::GetFullPath([string]$argv[$i + 1]) -ieq [System.IO.Path]::GetFullPath($ScriptPath) } catch { return $false }
        }
    }
    $false
}

<#
앱을 끝낸 뒤 진입 스크립트(Start-WorkTool.ps1)가 마지막에 부른다. 이 앱만을 위해 띄운 프로세스면 여기서 프로세스를 끝낸다.
PowerShell은 끝날 때 열려 있는 실행 공간을 모두 닫으면서 그 안의 작업이 끝나기를 기다린다. 응답 없는 공유 폴더를 기다리는
OS 요청은 돌아오지 않으므로, 그대로 두면 창은 닫혀도 프로세스가 남는다. 저장 · 잠금 해제 같은 정리는 모두 끝난 뒤에 부른다.
사용자가 쓰던 PowerShell 창에서 바로 띄운 경우에는 그 창을 끄지 않게 아무것도 하지 않는다.
#>
function Exit-WtOwnProcess([Parameter(Mandatory)][string]$ScriptPath, [int]$ExitCode = 0) {
    if (-not (Test-WtOwnProcess $ScriptPath)) { return }
    [Console]::Out.Flush()
    [System.Environment]::Exit($ExitCode)
}

# ---- 경로 열기 -------------------------------------------------------------------------------

$script:openTimeoutMs = 5000   # 이 시간 안에 답이 없으면 기다리지 않고 알린다

# 여는 방법 정하기 (WPF 없이): 속성(-1 = 없음) → 'open'(원래 프로그램 · 폴더는 탐색기) | 'reveal'(탐색기에서 선택) | 'missing'
#   -Reveal: 있으면 탐색기에서 선택. -OpenTypes를 주면 폴더와 그 확장자만 열고 나머지(실행 파일 등)는 탐색기에서 선택
function Get-WtPathOpenAction([int]$Attributes, [string]$Path, [bool]$Reveal = $false, [string[]]$OpenTypes = @()) {
    if ($Attributes -eq -1) { return 'missing' }
    if ($Reveal) { return 'reveal' }
    if ($Attributes -band [int][System.IO.FileAttributes]::Directory) { return 'open' }
    if (-not @($OpenTypes).Count) { return 'open' }
    if (@($OpenTypes) -contains [System.IO.Path]::GetExtension($Path).ToLowerInvariant()) { 'open' } else { 'reveal' }
}

# 화면 밖(STA)에서 확인하고 연다. STA 스레드라 .NET이 셸 열기용 스레드를 따로 만들지 않는다.
# 셸에 넘기기 직전에 잠금 안에서 취소(시간 초과)를 보고 「넘김(Committed)」을 표시한다. 그래서 넘기기 전에 시간이 지났으면 늦게 확인돼도 열지 않고,
# 넘긴 뒤에 시간이 지났으면(셸이 늦게 여는 중) 화면이 그 사실대로 알린다. 셸 호출 자체는 중간에 멈출 수 없다
$script:openWork = {
    param($path, $reveal, $openTypes)
    $attr = Get-WtPathAttributes $path
    $act = Get-WtPathOpenAction $attr $path $reveal $openTypes
    if ($act -eq 'missing') { return @{ Action = $act; Skipped = $false } }
    [System.Threading.Monitor]::Enter($WtCancel.SyncRoot)
    try {
        if ($WtCancel.Value) { return @{ Action = $act; Skipped = $true } }
        $WtCancel.Committed = $true
    } finally { [System.Threading.Monitor]::Exit($WtCancel.SyncRoot) }
    if ($act -eq 'reveal') {
        $start = [System.Diagnostics.ProcessStartInfo]::new([System.IO.Path]::Combine([Environment]::GetFolderPath('Windows'), 'explorer.exe'), "/select,`"$path`"")
        $start.UseShellExecute = $false
    } else {
        $start = [System.Diagnostics.ProcessStartInfo]::new($path)
        $start.UseShellExecute = $true
    }
    Invoke-WtShellStart $start $act
    @{ Action = $act; Skipped = $false }
}

# 경로의 속성 (-1 = 없음). 네트워크 오류는 예외로 올린다 (화면 밖에서 부른다)
function Get-WtPathAttributes([string]$Path) { [int][System.IO.FileInfo]::new($Path).Attributes }

# 셸에 열기를 넘긴다 (화면 밖 STA에서 부른다). 검사는 이것만 바꿔 끼워 실제로 열지 않는다
function Invoke-WtShellStart($Start, [string]$Action) {
    try { $p = [System.Diagnostics.Process]::Start($Start) }
    catch [System.ComponentModel.Win32Exception] {
        # 연결된 프로그램이 없으면 Windows의 「연결 프로그램」 창으로 고르게 한다 (Invoke-Item과 같게)
        if ($_.Exception.NativeErrorCode -ne 1155 -or $Action -ne 'open') { throw }
        $Start.Verb = 'openas'
        $p = [System.Diagnostics.Process]::Start($Start)
    }
    if ($p) { $p.Dispose() }
}

function Get-WtPathTimeoutText([string]$Path) {
    "경로가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인한 뒤 다시 누르세요. 늦게 답이 와도 열지 않습니다.`n$Path"
}

function Get-WtPathLateText([string]$Path) {
    "열기를 프로그램에 넘겼지만 응답이 늦습니다. 응답이 오면 늦게 열릴 수 있습니다.`n$Path"
}

<#
파일 · 폴더를 연다. 있는지 확인과 셸 열기 모두 화면 밖에서 하므로 응답 없는 공유 폴더에서도 화면이 멈추지 않는다.
  기본: 폴더는 탐색기로, 파일은 원래 프로그램으로 연다
  -Reveal      탐색기에서 그 항목을 골라 보여 준다
  -OpenTypes   폴더와 이 확장자(소문자 '.pdf' 등)만 열고, 나머지(실행 파일 · 스크립트 등)는 탐색기에서 골라 보여 준다
  -NotFound    없을 때 알릴 글 (기본: 찾을 수 없습니다 + 경로)
- 확인하는 동안 커서가 AppStarting(화살표 + 모래시계). 같은 경로를 확인 중에 또 누르면 겹쳐 시작하지 않는다.
- $script:openTimeoutMs 안에 답이 없으면 기다리지 않고 알린다. 셸에 넘기기 전(있는지 · 폴더인지 확인 중)이었으면 늦게 확인돼도 열지 않는다.
  이미 셸에 넘긴 뒤였으면 셸 호출은 멈출 수 없으므로, 늦게 열릴 수 있다고 사실대로 알린다.
  같은 곳(드라이브 · 공유)에 답이 없는 확인이 남아 있으면 새로 묻지 않고 바로 알린다.
#>
function Open-WtPath {
    param([Parameter(Mandatory)][string]$Path, [switch]$Reveal, [string[]]$OpenTypes = @(), [string]$NotFound = '')
    foreach ($j in $script:jobs) {
        if ($j.State -eq 'running' -and $j.Context -is [hashtable] -and $j.Context.Open -and $j.Context.Path -ieq $Path) { return }
    }
    $key = Get-WtPathKey $Path
    if (Test-WtWorkStuck $key) { Show-WtMessage (Get-WtPathTimeoutText $Path) 'WorkTool' 'Warning'; return }
    try {
        [void](Start-WtWork -Script $script:openWork -ArgumentList @($Path, [bool]$Reveal, [string[]]@($OpenTypes)) -Functions (Get-Command Get-WtPathOpenAction, Get-WtPathAttributes, Invoke-WtShellStart) -Sta `
                -Key $key -TimeoutMs $script:openTimeoutMs -Context @{ Open = $true; Path = $Path; NotFound = $NotFound } -OnDone { param($w) Complete-WtPathOpen $w })
    } catch {
        Show-WtMessage "경로를 열지 못했습니다.`n$Path`n$($_.Exception.Message)" 'WorkTool' 'Warning'
        return
    }
    Update-WtPathCursor
}

# 확인 결과: 없음 · 실패 · 시간 초과만 알린다 (연 것은 원래 프로그램 · 탐색기가 보인다)
function Complete-WtPathOpen($Job) {
    Update-WtPathCursor
    $path = $Job.Context.Path
    if ($Job.TimedOut) { Show-WtMessage $(if ($Job.Committed) { Get-WtPathLateText $path } else { Get-WtPathTimeoutText $path }) 'WorkTool' 'Warning'; return }
    if ($Job.State -eq 'failed') {
        Show-WtMessage "경로를 확인하지 못했습니다. 접근 권한과 경로를 확인하세요.`n$path`n$($Job.Error)" 'WorkTool' 'Warning'
        return
    }
    if ($Job.Result.Action -eq 'missing') {
        Show-WtMessage $(if ($Job.Context.NotFound) { $Job.Context.NotFound } else { "찾을 수 없습니다.`n$path" })
    }
}

# 확인 중이면 커서를 AppStarting으로, 기다리는 확인이 없으면 원래대로
$script:pathCursor = $null   # 바꾸기 전 커서 @{ Old }
function Update-WtPathCursor {
    if (-not ('System.Windows.Input.Mouse' -as [type])) { return }
    $waiting = $false
    foreach ($j in $script:jobs) { if ($j.State -eq 'running' -and $j.Context -is [hashtable] -and $j.Context.Open) { $waiting = $true; break } }
    $busy = [System.Windows.Input.Cursors]::AppStarting
    if ($waiting -and -not $script:pathCursor) {
        $script:pathCursor = @{ Old = [System.Windows.Input.Mouse]::OverrideCursor }
        [System.Windows.Input.Mouse]::OverrideCursor = $busy
    } elseif (-not $waiting -and $script:pathCursor) {
        if ([object]::ReferenceEquals([System.Windows.Input.Mouse]::OverrideCursor, $busy)) { [System.Windows.Input.Mouse]::OverrideCursor = $script:pathCursor.Old }
        $script:pathCursor = $null
    }
}

Export-ModuleMember -Function New-WtCall, Start-WtWork, Invoke-WtWork, Wait-WtWork, Stop-WtWork, Stop-WtAllWork, Update-WtWork, Test-WtWorkStuck,
    Get-WtWorkInfo, Get-WtPathKey, Test-WtOwnProcess, Exit-WtOwnProcess, Get-WtPathOpenAction, Open-WtPath

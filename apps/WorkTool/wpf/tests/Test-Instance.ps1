<#
.SYNOPSIS
    한 번만 뜨기 · 빠른 적기 등록 · 바로 가기 대상을 검사한다.

.DESCRIPTION
    - 진입 스크립트(Start-WorkTool.ps1)와 개인 PC 실행 보조(build\start-launcher.ps1)의 한 번만 뜨기 함수가 글자까지 같은지,
      데이터 폴더 이름 규칙(같은 폴더 = 같은 이름, 대소문자 · 끝 \ 무시, datapath.txt)을 본다.
    - 프로세스: 실제 진입 코드(Start-WorkTool.ps1의 try 앞부분)로 만든 시험 대역 앱을 먼저 띄우고, 실행 보조 · 앱 프로세스 ·
      개인 PC 실행 보조를 다시 켜서 새 앱을 띄우지 않고 신호(보이기 · 빠른 적기)만 보내고 끝나는지, 끝나는 중인 앱은 끝날 때까지
      기다렸다가 이어서 뜨는지 본다. 임시 데이터 폴더와 콘솔 없는 프로세스만 쓰고 창은 띄우지 않는다.
    - 셸: 신호를 화면 스레드에서 한 번에 받아 보이기 · 빠른 적기(가짜 탭)로 나누고 다 했다고 알리는지, 등록이 없거나 꺼졌으면
      보이기로 가는지, 끝낼 때 신호를 닫는지, 도움말 → 정보의 바로 가기 대상 글 · [복사] · 좌표 경로를 본다(숨김 호스트).
    tests\Test-Core.ps1이 부르고, 혼자 돌려도 된다.

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/tests/Test-Instance.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { Write-Host 'SKIP 한 번만 뜨기 (Windows에서만)'; return }
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-WtTestCore
Add-Type -AssemblyName WindowsBase, PresentationCore, PresentationFramework, System.Windows.Forms
$root = Split-Path $PSScriptRoot -Parent
$entryPath = Join-Path $root 'Start-WorkTool.ps1'
$launcherPath = Join-Path $root 'build/start-launcher.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wt-instance-' + [guid]::NewGuid().ToString('N'))
$owned = [Collections.Generic.List[Diagnostics.Process]]::new()
$test = New-WtTestData 'instance'

function Get-WtTestFunctionText([string]$Path, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name }, $true)
    if ($fn) { $fn.Extent.Text.Replace("`r`n", "`n") } else { '' }
}

# 콘솔 없는 pwsh 하나를 낮은 우선순위로 띄운다(창 없음)
function Start-WtTestPwsh([string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    foreach ($a in @('-NoLogo', '-NoProfile') + $Arguments) { $info.ArgumentList.Add($a) }
    $p = [Diagnostics.Process]::Start($info)
    try { $p.PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }
    $script:owned.Add($p)
    $p
}

function Wait-WtTestFile([string]$Path, [scriptblock]$Until, [int]$Seconds = 20) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
        $lines = if ([IO.File]::Exists($Path)) { @(try { [IO.File]::ReadAllLines($Path) | Where-Object { $_ } } catch { }) } else { @() }
        if (& $Until $lines) { return $true }
        Start-Sleep -Milliseconds 50
    }
    $false
}
function Get-WtTestLines([string]$Path) { if ([IO.File]::Exists($Path)) { @([IO.File]::ReadAllLines($Path) | Where-Object { $_ }) } else { @() } }

# 틀려도 멈추지 않고 모두 본 뒤 끝에서 실패로 알린다. 구역 하나가 오류로 멈추면 그 구역만 실패로 센다
$script:failed = 0
function Assert-WtInstance([string]$Name, [bool]$Ok, $Detail = '') {
    if ($Ok) { Write-Host "PASS $Name" } else { Write-Host ("FAIL $Name $Detail").TrimEnd() -ForegroundColor Red; $script:failed++ }
}
function Invoke-WtInstanceSection([string]$Name, [scriptblock]$Body) {
    try { . $Body } catch { Write-Host "FAIL $Name 오류: $($_.Exception.Message) $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red; $script:failed++ }
}

try {
    $addonsBefore = & (Get-Module Addons) { , $script:addons.ToArray() }
    $global:wtInstanceProbe = @{ Front = 0; Captured = 0; Errors = [Collections.Generic.List[string]]::new(); Copied = ''; Refresh = 0 }
    $shell = Get-Module Shell
    # 바로 가기 대상 시험 폴더(여러 구역이 같이 쓴다. 구역 안 변수는 그 구역에만 남는다)
    $devDir = Join-Path $tmp 'dev'; $zipDir = Join-Path $tmp 'zip'; $soloDir = Join-Path $tmp 'solo'
    foreach ($dir in $devDir, $zipDir, $soloDir) { [void][IO.Directory]::CreateDirectory($dir) }
    foreach ($f in @((Join-Path $devDir 'Start-WorkTool.ps1'), (Join-Path $zipDir 'WorkTool-WPF.ps1'), (Join-Path $zipDir 'Start-WorkTool-Launcher.ps1'), (Join-Path $soloDir 'WorkTool-WPF.ps1'))) { Set-Content -LiteralPath $f -Value '#' -Encoding utf8 }
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'
    $wantDev = '"{0}" -NoProfile -WindowStyle Hidden -File "{1}"' -f $pwshPath, (Join-Path $devDir 'Start-WorkTool.ps1')
    $wantZip = '"{0}" -NoProfile -WindowStyle Hidden -File "{1}"' -f $pwshPath, (Join-Path $zipDir 'Start-WorkTool-Launcher.ps1')
    $wantSolo = '"{0}" -NoProfile -WindowStyle Hidden -File "{1}"' -f $pwshPath, (Join-Path $soloDir 'WorkTool-WPF.ps1')

    # ---- 진입 스크립트 · 개인 PC 실행 보조가 같은 함수를 쓴다 ----
    $same = foreach ($name in 'Get-WtInstanceName', 'Send-WtInstanceSignal') {
        $a = Get-WtTestFunctionText $entryPath $name; $b = Get-WtTestFunctionText $launcherPath $name
        [pscustomobject]@{ Name = $name; Ok = [bool]$a -and $a -ceq $b }
    }
    Assert-WtInstance '한 번만 뜨기: 진입 스크립트와 개인 PC 실행 보조의 이름 · 신호 함수가 글자까지 같다' (-not @($same | Where-Object { -not $_.Ok }).Count) (($same | ForEach-Object { "$($_.Name)=$($_.Ok)" }) -join ' ')

    # ---- 이름: 데이터 폴더 경로로 정한다 ----
    . $launcherPath
    Invoke-WtInstanceSection '한 번만 뜨기 이름' {
    $appA = Join-Path $tmp 'a'; $appB = Join-Path $tmp 'b'; $appC = Join-Path $tmp 'c'; $appD = Join-Path $tmp 'd'
    foreach ($dir in $appA, $appB, $appC, $appD) { [void][IO.Directory]::CreateDirectory($dir) }
    Set-Content -LiteralPath (Join-Path $appA 'datapath.txt') -Value 'X:\Data\WorkTool' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $appB 'datapath.txt') -Value "x:\data\worktool\`r`n둘째 줄은 읽지 않음" -Encoding utf8BOM
    Set-Content -LiteralPath (Join-Path $appC 'datapath.txt') -Value 'X:\Data\Other' -Encoding utf8
    $nameA = Get-WtInstanceName $appA; $nameB = Get-WtInstanceName $appB; $nameC = Get-WtInstanceName $appC; $nameD = Get-WtInstanceName $appD
    $docsName = Get-WtInstanceName $tmp
    Assert-WtInstance '한 번만 뜨기 이름: 같은 데이터 폴더(대소문자 · 끝 \ · BOM 무시)는 같은 이름, 다른 폴더는 다른 이름, datapath.txt가 없으면 문서\WorkTool' (
        $nameA -cmatch '^Local\\WorkTool\.[0-9A-F]{32}$' -and $nameA -ceq $nameB -and $nameA -cne $nameC -and $nameD -ceq $docsName -and $nameD -cne $nameA) "$nameA / $nameB / $nameC / $nameD"
    }

    # ---- 프로세스: 실제 진입 코드로 만든 시험 대역 앱 ----
    Invoke-WtInstanceSection '한 번만 뜨기 프로세스' {
    $app =Join-Path $tmp "앱 O'Brien & (검사)"
    [void][IO.Directory]::CreateDirectory($app)
    Set-Content -LiteralPath (Join-Path $app 'datapath.txt') -Value (Join-Path $tmp 'data') -Encoding utf8
    $entryText = [IO.File]::ReadAllText($entryPath)
    $prefix = $entryText.Substring(0, $entryText.IndexOf("`ntry {"))
    $probeBody = @'

# ---- 시험 대역 앱: 진입 코드가 이 데이터 폴더의 앱이 된 뒤 여기로 온다. 받은 신호를 적고 다 했다고 알린다 ----
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'ran.txt') -Value $PID
$closed = $false
$deadline = [datetime]::UtcNow.AddSeconds(120)
while (-not [System.IO.File]::Exists((Join-Path $PSScriptRoot 'stop'))) {
    if ([datetime]::UtcNow -gt $deadline) { exit 24 }
    if (-not $closed) {
        if ($instance.Show.WaitOne(0)) { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'signals.txt') -Value 'show'; [void]$instance.Ready.Set() }
        if ($instance.Capture.WaitOne(0)) { Add-Content -LiteralPath (Join-Path $PSScriptRoot 'signals.txt') -Value 'capture'; [void]$instance.Ready.Set() }
        # 끝내는 중 흉내: 셸처럼 신호를 먼저 닫고 프로세스는 조금 더 남는다
        if ([System.IO.File]::Exists((Join-Path $PSScriptRoot 'closing'))) { foreach ($k in 'Show', 'Capture', 'Ready', 'Info') { $instance[$k].Dispose() }; $closed = $true }
    }
    Start-Sleep -Milliseconds 20
}
Close-WtInstance $instance
exit 0
'@
    $probe = Join-Path $app 'probe.ps1'
    [IO.File]::WriteAllText($probe, $prefix + "`n" + $probeBody, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $launcherPath -Destination (Join-Path $app 'Start-WorkTool-Launcher.ps1')
    $ran = Join-Path $app 'ran.txt'; $signals = Join-Path $app 'signals.txt'

    # 1) 앱이 안 떠 있을 때 -QuickMemo: 앱이 되고, 다 뜬 뒤 빠른 적기를 열도록 자기 신호를 남긴다
    $holder = Start-WtTestPwsh @('-STA', '-File', $probe, '-AppProcess', '-QuickMemo')
    $started = Wait-WtTestFile $ran { param($l) $l.Count -ge 1 }
    $ownCapture = Wait-WtTestFile $signals { param($l) @($l | Where-Object { $_ -ceq 'capture' }).Count -ge 1 } 10
    Assert-WtInstance '한 번만 뜨기: 앱이 안 떠 있으면 -QuickMemo 앱 프로세스가 앱이 되고, 다 뜬 뒤 빠른 적기 신호를 스스로 받는다' ($started -and $ownCapture -and -not $holder.HasExited) "(시작 $started · 빠른 적기 $ownCapture · 끝남 $($holder.HasExited))"

    # 2) 실행 보조 단계(단일 파일 · 바로 가기): 떠 있는 앱에 빠른 적기 신호만 보내고, 새 앱 프로세스를 띄우지 않고 끝난다
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $quick = Start-WtTestPwsh @('-File', $probe, '-QuickMemo')
    $quickEnded = $quick.WaitForExit(20000); $quickMs = $watch.ElapsedMilliseconds
    $gotCapture = Wait-WtTestFile $signals { param($l) @($l | Where-Object { $_ -ceq 'capture' }).Count -ge 2 } 10
    Start-Sleep -Milliseconds 1500
    Assert-WtInstance '한 번만 뜨기: 실행 보조 -QuickMemo는 떠 있는 앱에 빠른 적기만 알리고 새 앱 없이 끝난다' (
        $quickEnded -and $quick.ExitCode -eq 0 -and $gotCapture -and (Get-WtTestLines $ran).Count -eq 1) "(끝남 $quickEnded · 코드 $(if ($quickEnded) { $quick.ExitCode }) · 신호 $gotCapture · 앱 $((Get-WtTestLines $ran).Count) · ${quickMs}ms)"

    # 3) 앱 프로세스로 바로 켬(개인 PC zip · 동시에 두 번): 모듈을 불러오기 전에 보이기 신호만 보내고 끝난다
    $twice = Start-WtTestPwsh @('-STA', '-File', $probe, '-AppProcess')
    $twiceEnded = $twice.WaitForExit(20000)
    $gotShow = Wait-WtTestFile $signals { param($l) @($l | Where-Object { $_ -ceq 'show' }).Count -ge 1 } 10
    Assert-WtInstance '한 번만 뜨기: 두 번째 앱 프로세스는 같은 데이터를 만지지 않고 보이기 신호만 보내고 끝난다' (
        $twiceEnded -and $twice.ExitCode -eq 0 -and $gotShow -and (Get-WtTestLines $ran).Count -eq 1) "(끝남 $twiceEnded · 신호 $gotShow · 앱 $((Get-WtTestLines $ran).Count))"

    # 4) 개인 PC 실행 보조(zip의 Start-WorkTool-Launcher.ps1): 바로 가기에서 -QuickMemo · 인자 없음을 받는다
    $launcherCopy = Join-Path $app 'Start-WorkTool-Launcher.ps1'
    $lq = Start-WtTestPwsh @('-File', $launcherCopy, '-ScriptPath', $probe, '-QuickMemo')
    $lqEnded = $lq.WaitForExit(20000)
    $lqCapture = Wait-WtTestFile $signals { param($l) @($l | Where-Object { $_ -ceq 'capture' }).Count -ge 3 } 10
    $ls = Start-WtTestPwsh @('-File', $launcherCopy, '-ScriptPath', $probe)
    $lsEnded = $ls.WaitForExit(20000)
    $lsShow = Wait-WtTestFile $signals { param($l) @($l | Where-Object { $_ -ceq 'show' }).Count -ge 2 } 10
    Start-Sleep -Milliseconds 1500
    Assert-WtInstance '한 번만 뜨기: 개인 PC 실행 보조도 -QuickMemo · 보이기 신호만 보내고 새 앱 없이 끝난다' (
        $lqEnded -and $lq.ExitCode -eq 0 -and $lqCapture -and $lsEnded -and $ls.ExitCode -eq 0 -and $lsShow -and (Get-WtTestLines $ran).Count -eq 1) (
        "(빠른 적기 $lqEnded/$(if ($lqEnded) { $lq.ExitCode })/$lqCapture · 보이기 $lsEnded/$(if ($lsEnded) { $ls.ExitCode })/$lsShow · 앱 $((Get-WtTestLines $ran).Count))")
    $info = New-WtLaunchStartInfo $probe -QuickMemo
    Assert-WtInstance '한 번만 뜨기: 개인 PC 실행 보조는 앱이 없을 때 -QuickMemo를 앱 프로세스에 넘긴다' (
        $info.ArgumentList.Count -eq 7 -and $info.ArgumentList[5] -ceq '-AppProcess' -and $info.ArgumentList[6] -ceq '-QuickMemo') (@($info.ArgumentList) -join ' ')

    # 5) 끝나는 중인 앱(신호를 닫음): 새 앱 프로세스는 그 앱이 끝날 때까지 기다렸다가 이어서 뜬다(신호를 잃지 않고 둘이 겹치지 않음)
    Set-Content -LiteralPath (Join-Path $app 'closing') -Value 'closing' -Encoding utf8
    Start-Sleep -Milliseconds 500
    $next = Start-WtTestPwsh @('-STA', '-File', $probe, '-AppProcess')
    Start-Sleep -Milliseconds 2500
    $waiting = -not $next.HasExited -and (Get-WtTestLines $ran).Count -eq 1
    Set-Content -LiteralPath (Join-Path $app 'stop') -Value 'stop' -Encoding utf8
    $holderEnded = $holder.WaitForExit(20000)
    $nextRan = Wait-WtTestFile $ran { param($l) $l.Count -ge 2 } 20
    $nextEnded = $next.WaitForExit(20000)
    Assert-WtInstance '한 번만 뜨기: 끝나는 중인 앱이 있으면 새 앱 프로세스는 기다렸다가 그 앱이 끝난 뒤 이어서 뜬다' (
        $waiting -and $holderEnded -and $nextRan -and $nextEnded -and $next.ExitCode -eq 0) "(기다림 $waiting · 앞 앱 끝남 $holderEnded · 이어서 $nextRan · 끝남 $nextEnded)"

    # 6) 앱이 없을 때 실행 보조 단계 -QuickMemo(바로 가기 키로 처음 켬): 콘솔 없는 앱 프로세스에 -QuickMemo:True를 넘겨, 그 앱이 다 뜬 뒤 빠른 적기를 연다
    foreach ($name in 'stop', 'closing', 'signals.txt') { $old = Join-Path $app $name; if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old } }
    $first = Start-WtTestPwsh @('-File', $probe, '-QuickMemo')
    $firstEnded = $first.WaitForExit(20000)
    $spawned = Wait-WtTestFile $ran { param($l) $l.Count -ge 3 } 20
    $spawnCapture = Wait-WtTestFile $signals { param($l) @($l | Where-Object { $_ -ceq 'capture' }).Count -ge 1 } 10
    Set-Content -LiteralPath (Join-Path $app 'stop') -Value 'stop' -Encoding utf8
    Assert-WtInstance '한 번만 뜨기: 앱이 없을 때 실행 보조 -QuickMemo는 콘솔 없는 앱 프로세스에 넘기고, 그 앱이 빠른 적기 신호를 스스로 받는다' (
        $firstEnded -and $first.ExitCode -eq 0 -and $spawned -and $spawnCapture -and @((Get-WtTestLines $ran) | Where-Object { $_ -ceq [string]$first.Id }).Count -eq 0) "(끝남 $firstEnded · 앱 $spawned · 신호 $spawnCapture)"
    }

    # ---- 셸: 신호 받기 · 나누기 (가짜 탭, 창 없음) ----
    Invoke-WtInstanceSection '셸 신호' {
    $shellChecks = & $shell {
        $saved = @{ Instance = $script:instance; Window = $script:window; Ui = $script:ui; Current = $script:current; Views = $script:views; Exiting = $script:exiting
            Front = ${function:Show-WtMainFront}; ShowError = ${function:Show-WtError} }
        try {
            & (Get-Module Addons) { $script:addons.Clear() }
            function script:Show-WtMainFront { $global:wtInstanceProbe.Front++ }
            function script:Show-WtError { param($ErrorRecord, $Where) $global:wtInstanceProbe.Errors.Add([string]$Where) }
            $new = { [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset) }
            $script:instance = @{ Show = & $new; Capture = & $new; Ready = & $new }
            $script:exiting = $false
            $probe = $global:wtInstanceProbe
            $idle = (Invoke-WtInstanceSignals) -eq $false -and -not $script:instance.Ready.WaitOne(0)
            [void]$script:instance.Show.Set()
            $shown = (Invoke-WtInstanceSignals) -and $probe.Front -eq 1 -and $script:instance.Ready.WaitOne(0)
            # 등록 없음: 빠른 적기 신호는 보이기로
            [void]$script:instance.Capture.Set()
            $none = (Invoke-WtInstanceSignals) -and $probe.Front -eq 2 -and $script:instance.Ready.WaitOne(0)
            Register-WtAddon -Id 'cap-a' -Title '가짜 적기' -Order 20 -NewView { [System.Windows.Controls.Border]::new() } `
                -QuickCapture @{ Name = '가짜 빠른 적기'; Key = 'Ctrl + Alt + Q'; Open = { $global:wtInstanceProbe.Captured++ } }
            Register-WtAddon -Id 'cap-b' -Title '뒤 적기' -Order 30 -NewView { [System.Windows.Controls.Border]::new() } `
                -QuickCapture @{ Name = '뒤 빠른 적기'; Open = { throw '뒤 탭은 부르지 않아야 함' } }
            $first = Get-WtQuickCapture
            [void]$script:instance.Capture.Set()
            $captured = (Invoke-WtInstanceSignals) -and $probe.Captured -eq 1 -and $probe.Front -eq 2 -and $script:instance.Ready.WaitOne(0) -and $script:captureStale
            # 둘이 한꺼번에 와도 틱 하나에서 둘 다 하고 다 했다는 알림은 한 번
            [void]$script:instance.Show.Set(); [void]$script:instance.Capture.Set()
            $both = (Invoke-WtInstanceSignals) -and $probe.Captured -eq 2 -and $probe.Front -eq 3 -and $script:instance.Ready.WaitOne(0) -and -not $script:instance.Ready.WaitOne(0)
            # 앞 탭을 끄면 다음 등록, 실패하면 보이기 + 알림
            Set-WtSetting 'addons.disabled' @('cap-a')
            [void]$script:instance.Capture.Set()
            $fallback = (Invoke-WtInstanceSignals) -and $probe.Front -eq 4 -and $probe.Errors.Count -eq 1 -and $probe.Errors[0] -like '뒤 빠른 적기*'
            Set-WtSetting 'addons.disabled' @('cap-a', 'cap-b')
            [void]$script:instance.Capture.Set()
            $off = (Invoke-WtInstanceSignals) -and $probe.Front -eq 5 -and $probe.Captured -eq 2
            Set-WtSetting 'addons.disabled' @()
            $badCapture = $null
            try { Register-WtAddon -Id 'cap-bad' -Title '잘못' -NewView { [System.Windows.Controls.Border]::new() } -QuickCapture @{ Name = ''; Open = { } } } catch { $badCapture = $_.Exception.Message }
            # 타이머: 화면 스레드 DispatcherTimer 하나(0.2초). 끝낼 때(Stop-WtApp) 신호를 닫는다
            Start-WtInstanceTimer
            $timer = $script:instanceTimer
            $timerOk = $timer -is [System.Windows.Threading.DispatcherTimer] -and $timer.IsEnabled -and $timer.Interval.TotalMilliseconds -eq 200
            $handles = $script:instance
            $script:exiting = $true
            [void](Stop-WtApp)
            $closed = -not $timer.IsEnabled -and $null -eq $script:instance -and $handles.Show.SafeWaitHandle.IsClosed -and $handles.Capture.SafeWaitHandle.IsClosed -and $handles.Ready.SafeWaitHandle.IsClosed
            $script:exiting = $false
            @{ Idle = $idle; Shown = $shown; None = $none; First = ($first.Id -ceq 'cap-a' -and $first.QuickCapture.Name -ceq '가짜 빠른 적기' -and $first.QuickCapture.Key -ceq 'Ctrl + Alt + Q')
                Captured = $captured; Both = $both; Fallback = $fallback; Off = $off; Bad = [bool]$badCapture; Timer = $timerOk; Closed = $closed
                Detail = "앞 $($probe.Front) · 적기 $($probe.Captured) · 오류 $($probe.Errors -join ',') · 잘못 $badCapture" }
        } finally {
            $script:instance = $saved.Instance; $script:window = $saved.Window; $script:ui = $saved.Ui; $script:current = $saved.Current; $script:views = $saved.Views; $script:exiting = $saved.Exiting
            Set-Item function:script:Show-WtMainFront $saved.Front; Set-Item function:script:Show-WtError $saved.ShowError
        }
    }
    Assert-WtInstance '셸 신호: 받은 것이 없으면 아무것도 하지 않고, 보이기 신호는 앱 창을 앞으로 · 다 했다고 알린다' ($shellChecks.Idle -and $shellChecks.Shown) $shellChecks.Detail
    Assert-WtInstance '셸 신호: 빠른 적기는 등록한 켜진 탭(메뉴 순서로 처음) 하나를 부르고, 등록이 없으면 보이기로 간다' ($shellChecks.None -and $shellChecks.First -and $shellChecks.Captured) $shellChecks.Detail
    Assert-WtInstance '셸 신호: 보이기 · 빠른 적기가 한꺼번에 와도 한 틱에서 둘 다 하고 알림은 한 번' $shellChecks.Both $shellChecks.Detail
    Assert-WtInstance '셸 신호: 앞 탭을 끄면 다음 등록, 실패하면 보이기 + 알림, 모두 끄면 보이기 · 잘못된 등록은 막는다' ($shellChecks.Fallback -and $shellChecks.Off -and $shellChecks.Bad) $shellChecks.Detail
    Assert-WtInstance '셸 신호: 화면 스레드 타이머(0.2초)로 보고, 끝낼 때 타이머를 멈추고 신호 손잡이를 닫는다' ($shellChecks.Timer -and $shellChecks.Closed) $shellChecks.Detail
    }

    # 앞으로 가져오기: Windows가 못 가져오면 잠깐 맨 위로 두었다가 활성화되면 푼다. 빠른 적기 뒤 앱 창을 다시 보면 지금 화면을 새로 그린다
    if (Test-WtTestWpf) { Invoke-WtInstanceSection '앞으로 가져오기' {
    $frontChecks = & $shell {
        $saved = @{ Window = $script:window; Ui = $script:ui; Current = $script:current; Views = $script:views; Stale = $script:captureStale; Show = ${function:Show-WtMainWindow} }
        try {
            $script:captureStale = $false
            & (Get-Module Addons) { $script:addons.Clear() }
            function script:Show-WtMainWindow { }
            $script:window = [System.Windows.Window]::new()
            Show-WtMainFront
            $held = $script:window.Topmost -and $script:frontTimer.IsEnabled
            Invoke-WtMainActivated
            $released = -not $script:window.Topmost -and -not $script:frontTimer.IsEnabled
            Register-WtAddon -Id 'cap-page' -Title '가짜 화면' -NewView { [System.Windows.Controls.Border]::new() } -Refresh { param($v) $global:wtInstanceProbe.Refresh++ }
            $script:ui = @{ PageHost = [System.Windows.Controls.ContentControl]::new() }; $script:views = @{}; $script:current = $null
            Select-WtPage 'cap-page'
            $before = $global:wtInstanceProbe.Refresh
            Invoke-WtMainActivated
            $quiet = $global:wtInstanceProbe.Refresh -eq $before
            $script:captureStale = $true
            Invoke-WtMainActivated
            $redrawn = $global:wtInstanceProbe.Refresh -eq $before + 1 -and -not $script:captureStale
            Invoke-WtMainActivated
            $once = $global:wtInstanceProbe.Refresh -eq $before + 1
            @{ Held = $held; Released = $released; Quiet = $quiet; Redrawn = $redrawn; Once = $once; Detail = "맨 위 $held/$released · 다시 그림 $($global:wtInstanceProbe.Refresh - $before)" }
        } finally {
            if ($script:frontTimer) { $script:frontTimer.Stop() }
            $script:window = $saved.Window; $script:ui = $saved.Ui; $script:current = $saved.Current; $script:views = $saved.Views; $script:captureStale = $saved.Stale
            Set-Item function:script:Show-WtMainWindow $saved.Show
        }
    }
    Assert-WtInstance '앞으로 가져오기: 앞에 못 가져오면 잠깐 맨 위로 두고, 앱 창이 활성화되면 맨 위를 푼다' ($frontChecks.Held -and $frontChecks.Released) $frontChecks.Detail
    Assert-WtInstance '빠른 적기 뒤: 앱 창을 다시 보면 지금 화면을 한 번만 새로 그리고, 평소 활성화에는 그리지 않는다' ($frontChecks.Quiet -and $frontChecks.Redrawn -and $frontChecks.Once) $frontChecks.Detail
    } } else { Write-Host 'SKIP 앞으로 가져오기 (Windows STA에서만)' }

    # ---- 바로 가기 대상 (도움말 → 정보) ----
    Invoke-WtInstanceSection '바로 가기 대상' {
    $targets = & $shell {
        param($dev, $zip, $solo)
        $saved = $script:entryPath
        try {
            $out = @{}
            foreach ($pair in @(@('Dev', $dev), @('Zip', $zip), @('Solo', $solo))) {
                $script:entryPath = $pair[1]
                $out[$pair[0]] = @{ Show = (Get-WtLaunchTarget); Capture = (Get-WtLaunchTarget -QuickCapture) }
            }
            $script:entryPath = 'C:\' + ('긴폴더이름' * 50) + '\WorkTool-WPF.ps1'
            $out.Long = Get-WtLaunchTarget
            $script:entryPath = ''
            $out.Empty = Get-WtLaunchTarget
            $out
        } finally { $script:entryPath = $saved }
    } (Join-Path $devDir 'Start-WorkTool.ps1') (Join-Path $zipDir 'WorkTool-WPF.ps1') (Join-Path $soloDir 'WorkTool-WPF.ps1')
    Assert-WtInstance '바로 가기 대상: 지금 pwsh로 콘솔을 숨겨 진입 파일(옆에 실행 보조가 있으면 그것)을 부르고, 빠른 적기는 -QuickMemo를 붙인다' (
        $targets.Dev.Show.Text -ceq $wantDev -and $targets.Dev.Capture.Text -ceq "$wantDev -QuickMemo" -and $targets.Dev.Show.Fast -and
        $targets.Zip.Show.Text -ceq $wantZip -and $targets.Zip.Capture.Text -ceq "$wantZip -QuickMemo" -and $targets.Zip.Show.Fast -and
        $targets.Solo.Show.Text -ceq $wantSolo -and -not $targets.Solo.Show.Fast -and -not $targets.Solo.Show.TooLong -and
        $targets.Long.TooLong -and $null -eq $targets.Empty -and $targets.Dev.Show.Text -notmatch 'ExecutionPolicy|Bypass|EncodedCommand|-Command') (
        "$($targets.Dev.Capture.Text) / $($targets.Zip.Show.Text) / $($targets.Solo.Show.Fast)")
    }

    if (Test-WtTestWpf) { Invoke-WtInstanceSection '도움말 → 정보' {
        # 도움말 → 정보: 대상 두 줄 · [복사] · 만드는 법. 숨김 호스트에 놓고 [복사]를 실제 배치 좌표에서 누른다
        & (Get-Module Pages) { $script:setClipboard = { param($Text) $global:wtInstanceProbe.Copied = $Text } }
        & (Get-Module Addons) { $script:addons.Clear() }
        Register-WtAddon -Id 'cap-help' -Title '가짜 적기' -NewView { [System.Windows.Controls.Border]::new() } -QuickCapture @{ Name = '가짜 빠른 적기'; Key = 'Ctrl + Alt + Q'; Open = { } }
        & $shell { param($p) $script:entryPath = $p } (Join-Path $devDir 'Start-WorkTool.ps1')
        $helpRoot = [System.Windows.Controls.Border]::new()
        $helpRoot.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $helpRoot.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
        $helpParams = [System.Windows.Interop.HwndSourceParameters]::new('Instance help test'); $helpParams.WindowStyle = 0; $helpParams.Width = 944; $helpParams.Height = 1400
        $helpSource = [System.Windows.Interop.HwndSource]::new($helpParams); $helpSource.RootVisual = $helpRoot
        try {
            $page = New-WtHelpPage
            Select-WtPageTab $page '정보'
            $helpRoot.Child = $page
            $helpRoot.Measure([System.Windows.Size]::new(944, 1400)); $helpRoot.Arrange([System.Windows.Rect]::new(0, 0, 944, 1400)); $helpRoot.UpdateLayout()
            $info = $page.Tag.Tabs.SelectedItem.Content.Content
            $texts = @(Get-WtTestTexts $info)
            $copyButtons = [Collections.Generic.List[object]]::new()
            $walk = { param($n) if ($n -is [System.Windows.Controls.Button] -and [System.Windows.Automation.AutomationProperties]::GetName($n) -like '*복사') { $copyButtons.Add($n) }; foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($n)) { if ($c -is [System.Windows.DependencyObject]) { & $walk $c } } }
            & $walk $info
            $hasRows = ($texts -contains 'WorkTool 보이기') -and ($texts -contains '가짜 빠른 적기') -and ($texts -contains $wantDev) -and ($texts -contains "$wantDev -QuickMemo") -and
                @($texts | Where-Object { $_ -like '*Ctrl + Alt + W*' }).Count -and @($texts | Where-Object { $_ -like '*Ctrl + Alt + Q*' }).Count -and
                @($texts | Where-Object { $_ -like '*새로 만들기*바로 가기*' }).Count -and @($texts | Where-Object { $_ -like '*바로 가기 키*' }).Count
            $routes = foreach ($b in $copyButtons) { (Test-WtTestInputPath -View $helpRoot -Element $b -Target $b -BringIntoView).Ok }
            $copyButtons[1].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
            Assert-WtInstance '도움말 → 정보: 「바로 가기 키」에 보이기 · 빠른 적기 대상 두 줄 · 권하는 키 · 만드는 법이 있다' $hasRows (($texts | Where-Object { $_ -match 'pwsh|Ctrl|바로 가기' }) -join ' | ')
            Assert-WtInstance '도움말 → 정보: [복사] 두 개가 실제 배치 좌표에서 닿고, 누르면 그 줄의 대상 글을 복사한다' (
                $copyButtons.Count -eq 2 -and -not @($routes | Where-Object { -not $_ }).Count -and $global:wtInstanceProbe.Copied -ceq "$wantDev -QuickMemo") "(단추 $($copyButtons.Count) · 경로 $($routes -join ',') · 복사 $($global:wtInstanceProbe.Copied))"
        } finally { $helpRoot.Child = $null; $helpSource.RootVisual = $null; $helpSource.Dispose() }
    } } else { Write-Host 'SKIP 도움말 → 정보 화면 (Windows STA에서만)' }
} finally {
    & (Get-Module Addons) { param($restore) $script:addons.Clear(); foreach ($a in $restore) { $script:addons.Add($a) } } $addonsBefore
    if (Test-Path -LiteralPath $tmp) { foreach ($dir in Get-ChildItem -LiteralPath $tmp -Directory) { Set-Content -LiteralPath (Join-Path $dir.FullName 'stop') -Value 'stop' -Encoding utf8 } }
    foreach ($p in $owned) {
        try { if (-not $p.HasExited -and -not $p.WaitForExit(5000)) { $p.Kill(); [void]$p.WaitForExit(5000) } } catch { }
        $p.Dispose()
    }
    $safe = [IO.Path]::GetFullPath($tmp)
    if ((Split-Path $safe -Leaf) -notmatch '^wt-instance-[a-f0-9]{32}$' -or -not $safe.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw '임시 경로 검증 실패' }
    if (Test-Path -LiteralPath $safe) { Remove-Item -LiteralPath $safe -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-WtTestData $test
}
if ($script:failed) { throw "FAIL 한 번만 뜨기 검사 $script:failed 건" }

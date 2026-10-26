<#
.SYNOPSIS
    개인 PC 실행 파일이 콘솔 없이 GUI를 띄우고 보조 프로세스를 끝내는지 검사한다.
.DESCRIPTION
    임시 데이터 폴더와 전용 WorkTool 창만 사용한다. 사용자 데이터나 기존 창은 조회하지 않는다.
.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/tests/Test-Launcher.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { Write-Host 'SKIP 실행 파일 (Windows에서만)'; return }
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'build/start-launcher.ps1')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wt-launcher-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $tmp "한글 O'Brien & (검사)! %test%"
# 저장소 구성(start-dev.cmd · build\start-launcher.ps1 · Start-WorkTool.ps1)을 흉내 내는 폴더
$devFixture = Join-Path $tmp "원본 O'Brien & (검사)! %test%"
[void][IO.Directory]::CreateDirectory($fixture)
[void][IO.Directory]::CreateDirectory((Join-Path $devFixture 'build'))
$owned = [Collections.Generic.List[Diagnostics.Process]]::new()

function Assert-Launcher([string]$Name, [bool]$Ok) {
    if (-not $Ok) { throw "FAIL 실행 파일: $Name" }
    Write-Host "PASS 실행 파일: $Name"
}

# 저장소의 .cmd를 zip에 넣을 때처럼 CRLF로 바꿔 복사한다
function Copy-WtLauncherCmd([string]$Source, [string]$Destination) {
    $cmd = [IO.File]::ReadAllText($Source).Replace("`r`n", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText($Destination, $cmd, [Text.UTF8Encoding]::new($false))
}

# 더블클릭처럼 .cmd를 실행하고, 실행 보조가 끝난 뒤 전용 GUI가 남긴 상태를 읽는다
function Invoke-WtLauncherCmd([string]$Dir, [string]$CmdName) {
    $cmdInfo = [Diagnostics.ProcessStartInfo]::new()
    $cmdInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    # 현재 폴더를 명령 검색에서 빼는 환경(NoDefaultCurrentDirectoryInExePath)에서도 찾도록 .\를 붙인다
    $cmdInfo.Arguments = "/d /c .\$CmdName"
    $cmdInfo.WorkingDirectory = $Dir
    $cmdInfo.UseShellExecute = $false; $cmdInfo.CreateNoWindow = $true
    $cmdInfo.RedirectStandardOutput = $true; $cmdInfo.RedirectStandardError = $true
    $bootstrap = [Diagnostics.Process]::Start($cmdInfo)
    $script:owned.Add($bootstrap)
    # GUI가 출력 핸들을 물려받으므로, 출력은 GUI가 끝나야 다 읽힌다
    $run = [pscustomobject]@{
        Bootstrap = $bootstrap; Gui = $null; State = $null
        Out = $bootstrap.StandardOutput.ReadToEndAsync(); Err = $bootstrap.StandardError.ReadToEndAsync()
    }
    if (-not $bootstrap.WaitForExit(15000)) { throw '실행 보조 프로세스가 종료되지 않았습니다.' }
    if ($bootstrap.ExitCode -ne 0) { throw "실행 보조 실패: $($run.Out.GetAwaiter().GetResult()) $($run.Err.GetAwaiter().GetResult())" }
    $statePath = Join-Path $Dir 'state.json'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $statePath)) {
        if ($watch.Elapsed.TotalSeconds -gt 15) { throw '전용 GUI 창이 시작되지 않았습니다.' }
        Start-Sleep -Milliseconds 50
    }
    # 파일 작성이 끝난 뒤 읽는다.
    for ($i=0; $i -lt 20 -and -not $run.State; $i++) {
        try { $run.State = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { Start-Sleep -Milliseconds 25 }
    }
    if (-not $run.State) { throw '전용 GUI 검사 결과를 읽지 못했습니다.' }
    $run.Gui = [Diagnostics.Process]::GetProcessById($run.State.Pid)
    $script:owned.Add($run.Gui)
    $run
}

# 전용 GUI에 끝내라고 알리고, 제때 끝났는지 돌려준다
function Stop-WtLauncherGui($Run, [string]$Dir) {
    Set-Content -LiteralPath (Join-Path $Dir 'stop') -Value 'stop' -Encoding utf8
    if (-not $Run.Gui.WaitForExit(10000)) { return $false }
    [void]$Run.Out.GetAwaiter().GetResult(); [void]$Run.Err.GetAwaiter().GetResult()
    $true
}

try {
    Copy-Item -LiteralPath (Join-Path $root 'build/start-launcher.ps1') -Destination (Join-Path $fixture 'Start-WorkTool-Launcher.ps1')
    Copy-WtLauncherCmd (Join-Path $root 'build/start-worktool.cmd') (Join-Path $fixture 'Start-WorkTool.cmd')
    Set-Content -LiteralPath (Join-Path $fixture 'datapath.txt') -Value (Join-Path $fixture 'data') -Encoding utf8
    $entry = Join-Path $fixture 'WorkTool-WPF.ps1'
    $sample = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
$source = '__SOURCE__'
. (Join-Path $source 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $source 'addons/home/Home.psm1') -Force -DisableNameChecking
$script:sampleRoot = $PSScriptRoot
$script:sampleShell = Get-Module Shell
$script:sampleDeadline = [datetime]::UtcNow.AddSeconds(20)
$script:sampleReported = $false
$script:sampleTimer = [Windows.Threading.DispatcherTimer]::new()
$script:sampleTimer.Interval = [timespan]::FromMilliseconds(50)
$script:sampleTimer.Add_Tick({
    $window = Get-WtWindow
    if ($window -and $window.IsVisible -and -not $script:sampleReported) {
        # 응답 없는 공유 폴더를 기다리는 것처럼 끝나지 않는 화면 밖 작업을 남긴다. 그래도 창을 닫으면 프로세스가 끝나야 한다
        $script:sampleHung = Start-WtWork { [void][System.Threading.ManualResetEvent]::new($false).WaitOne() } -OnDone { }
        [pscustomobject]@{
            HungWork = $script:sampleHung.State
            Pid = $PID; Visible = $window.IsVisible; WindowState = [string]$window.WindowState
            IconWidth = $window.Icon.PixelWidth; HasOverlay = [bool]$window.TaskbarItemInfo.Overlay
            Description = $window.TaskbarItemInfo.Description
            Apartment = [string][Threading.Thread]::CurrentThread.GetApartmentState()
            Tiered = $env:DOTNET_TieredCompilation
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:sampleRoot 'state.json') -Encoding utf8
        $script:sampleReported = $true
    }
    if ((Test-Path -LiteralPath (Join-Path $script:sampleRoot 'stop')) -or [datetime]::UtcNow -gt $script:sampleDeadline) {
        $script:sampleTimer.Stop()
        & $script:sampleShell { Exit-WtApp }
    }
})
$script:sampleTimer.Start()
try { Start-WtApp -AppRoot $PSScriptRoot } finally { $script:sampleTimer.Stop() }
# 실제 진입 스크립트(Start-WorkTool.ps1)처럼 앱 전용 프로세스를 끝낸다
Exit-WtOwnProcess -ScriptPath $PSCommandPath
'@
    $sample = $sample.Replace('__SOURCE__', $root.Replace("'", "''"))
    [IO.File]::WriteAllText($entry, $sample, [Text.UTF8Encoding]::new($false))
    # 저장소 구성: start-dev.cmd가 build\start-launcher.ps1로 옆의 Start-WorkTool.ps1을 띄운다
    Copy-Item -LiteralPath (Join-Path $root 'build/start-launcher.ps1') -Destination (Join-Path $devFixture 'build/start-launcher.ps1')
    Copy-WtLauncherCmd (Join-Path $root 'start-dev.cmd') (Join-Path $devFixture 'start-dev.cmd')
    Set-Content -LiteralPath (Join-Path $devFixture 'datapath.txt') -Value (Join-Path $devFixture 'data') -Encoding utf8
    [IO.File]::WriteAllText((Join-Path $devFixture 'Start-WorkTool.ps1'), $sample, [Text.UTF8Encoding]::new($false))

    $info = New-WtLaunchStartInfo $entry
    Assert-Launcher '콘솔 생성과 셸 실행을 끈다' ($info.CreateNoWindow -and -not $info.UseShellExecute)
    Assert-Launcher '특수문자 경로를 하나의 파일 인수로 전달한다' ($info.ArgumentList.Count -eq 5 -and $info.ArgumentList[4] -ceq $entry -and $info.WorkingDirectory -ceq $fixture)
    Assert-Launcher '실행 정책 우회 옵션을 넣지 않는다' (-not ($info.ArgumentList -match 'ExecutionPolicy|Bypass|EncodedCommand'))
    Assert-Launcher 'GUI 프로세스에만 계층 컴파일 끄기를 전달한다' ($info.Environment['DOTNET_TieredCompilation'] -ceq '0')
    Push-Location -LiteralPath $fixture
    try { $relative = New-WtLaunchStartInfo '.\WorkTool-WPF.ps1' } finally { Pop-Location }
    Assert-Launcher '상대 경로는 지금 위치 기준 전체 경로로 넘긴다' ($relative.ArgumentList[4] -ceq $entry -and $relative.WorkingDirectory -ceq $fixture)

    $run = Invoke-WtLauncherCmd $fixture 'Start-WorkTool.cmd'
    $state = $run.State
    Assert-Launcher 'CMD는 끝나고 별도 GUI 프로세스만 계속 실행한다' ($run.Bootstrap.HasExited -and -not $run.Gui.HasExited -and $state.Visible)
    # 상속된 표준 입력 핸들이 있어도 콘솔 창이 있다는 뜻은 아니다. 이 검사에서 만든 PID의 창만 확인한다.
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $ownedCondition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, [int]$state.Pid)
    $ownedWindows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $ownedCondition)
    Assert-Launcher '이 프로세스에는 WorkTool GUI 창 하나만 있다' ($ownedWindows.Count -eq 1 -and $ownedWindows[0].Current.Name -eq 'WorkTool')
    Assert-Launcher 'GUI는 STA·보통 창 상태로 실행한다' ($state.Apartment -eq 'STA' -and $state.WindowState -eq 'Normal')
    Assert-Launcher 'GUI가 계층 컴파일 끄기 설정을 상속한다' ($state.Tiered -ceq '0')
    Assert-Launcher '전체 창 아이콘을 적용하고 작은 배지를 제거한다' ($state.IconWidth -eq 32 -and -not $state.HasOverlay -and $state.Description -eq 'WorkTool')
    Assert-Launcher '끝나지 않는 화면 밖 작업이 남아 있어도(응답 없는 공유 폴더 흉내) GUI 종료 뒤 프로세스가 끝난다' ($state.HungWork -eq 'running' -and (Stop-WtLauncherGui $run $fixture))

    $dev = Invoke-WtLauncherCmd $devFixture 'start-dev.cmd'
    Assert-Launcher '저장소 실행 파일(start-dev.cmd)도 CMD는 끝나고 원본 GUI만 STA로 남는다' ($dev.Bootstrap.HasExited -and -not $dev.Gui.HasExited -and $dev.State.Visible -and $dev.State.Apartment -eq 'STA')
    Assert-Launcher '저장소 실행 파일의 GUI도 종료 뒤 프로세스가 끝난다' (Stop-WtLauncherGui $dev $devFixture)

    # 실제 진입 코드만 떼어, 앱 대신 인수/종료 코드를 기록한다. 재실행은 최대 한 번이어야 한다.
    $realEntry = [IO.File]::ReadAllText((Join-Path $root 'Start-WorkTool.ps1'))
    $prefix = $realEntry.Substring(0, $realEntry.IndexOf("`ntry {"))
    $prefix = $prefix.Replace('param()', 'param([string]$Marker)')
    $prefix = $prefix.Replace("`$ErrorActionPreference = 'Stop'", "`$ErrorActionPreference = 'Stop'`nAdd-Content -LiteralPath (Join-Path `$PSScriptRoot 'hops.txt') -Value `$PID")
    $probe = Join-Path $fixture 'restart-probe.ps1'
    $probeBody = @'
[pscustomobject]@{ Marker = $Marker; Tiered = $env:DOTNET_TieredCompilation; Apartment = [string][Threading.Thread]::CurrentThread.GetApartmentState() } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'restart.json') -Encoding utf8
exit 23
'@
    [IO.File]::WriteAllText($probe, ($prefix + "`n" + $probeBody), [Text.UTF8Encoding]::new($false))
    foreach ($tiered in '1','0') {
        [IO.File]::WriteAllText((Join-Path $fixture 'hops.txt'), '')
        $probeInfo = [Diagnostics.ProcessStartInfo]::new()
        $probeInfo.FileName = Join-Path $PSHOME 'pwsh.exe'; $probeInfo.UseShellExecute = $false; $probeInfo.CreateNoWindow = $true
        $probeInfo.Environment['DOTNET_TieredCompilation'] = $tiered
        foreach ($arg in @('-NoLogo','-NoProfile','-STA','-File',$probe,'-Marker',"한글 O'Brien & (검사)! %test%")) { $probeInfo.ArgumentList.Add($arg) }
        $probeProcess = [Diagnostics.Process]::Start($probeInfo); $script:owned.Add($probeProcess)
        if (-not $probeProcess.WaitForExit(15000)) { throw '재실행 검사가 끝나지 않았습니다.' }
        $probeState = Get-Content (Join-Path $fixture 'restart.json') -Raw | ConvertFrom-Json
        $hops = @(Get-Content (Join-Path $fixture 'hops.txt') | Where-Object { $_ })
        Assert-Launcher "계층 컴파일 $tiered 입력: 재실행 횟수·인수·종료 코드 보존" (
            $hops.Count -eq $(if ($tiered -eq '0') { 1 } else { 2 }) -and $probeProcess.ExitCode -eq 23 -and
            $probeState.Marker -ceq "한글 O'Brien & (검사)! %test%" -and $probeState.Tiered -ceq '0' -and $probeState.Apartment -eq 'STA')
    }

    $bad = Join-Path $fixture 'bad.ps1'
    Set-Content -LiteralPath $bad -Value 'function {' -Encoding utf8
    $rejected = $false
    try { [void](New-WtLaunchStartInfo $bad) } catch { $rejected = $true }
    Assert-Launcher '문법이 깨진 파일은 숨겨진 프로세스로 보내지 않는다' $rejected
    $rejected = $false
    try { [void](New-WtLaunchStartInfo (Join-Path $fixture 'missing.ps1')) } catch { $rejected = $true }
    Assert-Launcher '없는 실행 파일은 시작 전에 알린다' $rejected
    Set-Content -LiteralPath $entry -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3"
    $rejected = $false
    try { [void](New-WtLaunchStartInfo $entry) } catch { $rejected = $true }
    Assert-Launcher '다운로드 차단 표시는 우회하지 않고 알린다' $rejected
} finally {
    foreach ($dir in @($fixture, $devFixture)) {
        if (Test-Path -LiteralPath $dir) { Set-Content -LiteralPath (Join-Path $dir 'stop') -Value 'stop' -Encoding utf8 }
    }
    foreach ($process in $owned) {
        if (-not $process.HasExited -and -not $process.WaitForExit(5000)) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $safe = [IO.Path]::GetFullPath($tmp)
    if ((Split-Path $safe -Leaf) -notmatch '^wt-launcher-[a-f0-9]{32}$' -or -not $safe.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw '임시 경로 검증 실패' }
    Remove-Item -LiteralPath $safe -Recurse -Force
}

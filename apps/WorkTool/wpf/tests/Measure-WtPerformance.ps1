<#
.SYNOPSIS
    창을 띄우지 않고 예산을 제한해 WPF 화면 구성 비용을 가볍게 확인한다.
.DESCRIPTION
    A~H 전체 성능 합격 검사가 아니다. UI Automation·창 활성화·업무 실행·200회 전환을 하지 않는다.
    단일 자식 프로세스를 낮은 우선순위와 분리된 입출력으로 실행한다. 기존 창과 실제 데이터는 사용하지 않는다.
    동기 화면의 구성·재사용·배치만 확인하므로 실제 탭 응답 시간으로 해석하지 않는다.
.PARAMETER OutputPath
    결과 JSON을 보관할 새 폴더. 생략하면 시스템 임시 폴더를 만든다.
.PARAMETER MaxCpuSeconds
    자식의 전체 CPU 시간 예산. 기본 3초이며 0.5~5초 범위다.
.PARAMETER MaxWallSeconds
    자식 실행의 벽시계 제한. 기본 45초이며 10~60초 범위다.
.PARAMETER MaxSystemCpuPercent
    선택적인 시작 전 전체 CPU 부하 한도. 기본 100%로 기존 부하에 따른 실행 제한은 두지 않는다.
.EXAMPLE
    pwsh -NoProfile -STA -File ./Measure-WtPerformance.ps1 -OutputPath ./.work/perf-light-new
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$OutputPath,
    [ValidateRange(.5,5)][double]$MaxCpuSeconds = 3,
    [ValidateRange(10,60)][int]$MaxWallSeconds = 45,
    [ValidateRange(1,100)][int]$MaxSystemCpuPercent = 100,
    [switch]$LightWorker,
    [string]$AppRoot
)

# ===== 고정 확인 조건 =====
$Config = @{ ContentWidth = 1046; ContentHeight = 630; PauseMilliseconds = 150 }
$ErrorActionPreference = 'Stop'
$script:source = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestKit.ps1')

function Get-PerfLoad {
    try { [double](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -OperationTimeoutSec 2 -ErrorAction Stop).PercentProcessorTime }
    catch { $null }
}

function Write-PerfLightResult($Result) {
    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputPath 'light-result.json') -Encoding utf8
}
function Initialize-PerfFixture($Test) {
    # New-WtTestData가 설정한 AppRoot를 확인한 뒤에만 저장한다.
    if ((Get-WtDataRoot) -ne $Test.Data) { throw '측정 데이터 경로가 임시 폴더와 다릅니다.' }
    $stamp = '2026-01-01 09:00:00'
    $body = @'
# 가짜 업무 메모
측정 전용 내용입니다. **확인** · `SRV-01` #점검

| 항목 | 결과 |
| --- | --- |
| 가짜 장비 | 정상 |

```powershell
Get-Date
```

```mermaid
flowchart LR
  A[접수] --> B[확인] --> C[완료]
```
'@
    $memos = @(foreach ($i in 1..300) {
        @{ id = "memo-$i"; title = ('가짜 메모 {0:000}' -f $i); body = ($body + ("`n가짜 기록을 확인합니다." * (25 + $i % 50))); tags = @('점검'); lock = $null; created = $stamp; updated = $stamp }
    })
    Write-WtStore memo -Items $memos
    $today = [datetime]::Today
    # 일정 · 근태는 schema 2 형식 (docs/plans/schedule-attendance-design.md). 측정이 이전(schema 1 → 2) 비용을 재지 않게 바로 2로 쓴다
    $inv = [Globalization.CultureInfo]::InvariantCulture
    Write-WtStore schedule -Schema 2 -Items @(foreach ($i in 1..300) {
        $day = $today.AddDays(($i % 300) - 150).ToString('yyyy-MM-dd', $inv)
        [ordered]@{ id = "schedule-$i"; kind = 'event'; title = "가짜 일정 $i"; note = '가짜 일정'; start = [ordered]@{ date = $day; time = '09:00' }; end = [ordered]@{ date = $day; time = '10:00' }
            repeat = $null; alarms = @(); tags = @(); created = $null; updated = $null; deleted = $null; origin = $null }
    })
    Write-WtStore attendance -Schema 2 -Items @(foreach ($i in 0..364) {
        $day = $today.AddDays(-$i).ToString('yyyy-MM-dd', $inv)
        [ordered]@{ id = "attendance-$i"; kind = 'work'; start = [ordered]@{ date = $day; time = '09:00' }; end = [ordered]@{ date = $day; time = '18:00' }; place = '가짜 장소'; note = '가짜 기록'; tags = @()
            created = $null; updated = $null; deleted = $null; origin = $null }
    })
    $docs = Join-Path $Test.Root 'documents'
    [void][IO.Directory]::CreateDirectory($docs)
    foreach ($i in 1..50) { [void][IO.Directory]::CreateDirectory((Join-Path $docs ('folder-{0:00}' -f $i))) }
    foreach ($i in 1..1000) { [IO.File]::WriteAllText((Join-Path $docs ('file-{0:0000}.txt' -f $i)), '') }
    $scripts = Join-Path $Test.Root 'scripts'
    [void][IO.Directory]::CreateDirectory($scripts)
    foreach ($i in 1..20) {
        [IO.File]::WriteAllText((Join-Path $scripts ('Test-Sample{0:00}.ps1' -f $i)), "<#`n.SYNOPSIS`n    가짜 측정 스크립트`n.PARAMETER Name`n    가짜 이름`n#>`nparam([string]`$Name = 'SRV-01')`nWrite-Output `"확인: `$Name`"")
    }
    Write-WtStore workflows -Items @()
    Write-WtStore workflow-runs -Items @(foreach ($i in 1..100) {
        @{ id = "run-$i"; script = (Join-Path $scripts 'Test-Sample01.ps1'); name = '가짜 측정'; flow = ''; flowId = ''; mode = 'app'; whatIf = $false; values = @{}; started = $stamp; ended = $stamp; status = 'success'; exitCode = 0; tail = @('확인: SRV-01') }
    })
    Set-WtSetting 'docs.roots' @($docs)
    Set-WtSetting 'docs.last' $docs
    Set-WtSetting 'workflows.roots' @($scripts)
}

if ($MyInvocation.InvocationName -eq '.') { return }

if ($LightWorker) {
    # 내부 실행도 반드시 부모가 만든 임시 경로에만 쓴다.
    $safeApp = [IO.Path]::GetFullPath($AppRoot)
    $safeRoot = Split-Path $safeApp -Parent
    $expectedData = Join-Path $safeRoot 'data'
    if ((Split-Path $safeApp -Leaf) -ne 'app' -or
        (Split-Path $safeRoot -Leaf) -notmatch '^wt-perf-light-[a-f0-9]{32}$' -or
        -not $safeRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or
        (Get-Content -LiteralPath (Join-Path $safeApp 'datapath.txt') -TotalCount 1) -cne $expectedData) {
        throw '경량 확인 임시 경로 검증 실패'
    }
    $process = [Diagnostics.Process]::GetCurrentProcess()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $rows = [Collections.Generic.List[object]]::new()
    $failure = $null; $reason = '완료'
    try {
        if (-not (Test-WtTestWpf)) { throw 'Windows STA에서 실행하세요.' }
        Import-WtTestCore
        Set-WtAppRoot $safeApp; Initialize-WtSettings
        foreach ($file in Get-ChildItem (Join-Path $script:source 'addons') -Filter '*.psm1' -Recurse | Sort-Object FullName) {
            Import-Module $file.FullName -Force -DisableNameChecking
        }
        Initialize-PerfFixture ([pscustomobject]@{Root=$safeRoot; App=$safeApp; Data=$expectedData})
        $shellModule = Get-Module Shell
        $hostView = [Windows.Controls.ContentControl]::new()
        $hostView.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
        $hostView.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
        Set-WtResource $hostView FontFamily 'Font.UI'
        Set-WtResource $hostView FontSize 'F.Body'
        Set-WtResource $hostView Foreground 'B.Text'
        # Window나 HwndSource를 만들지 않는다. 오류도 대화상자로 표시하지 않는다.
        & $shellModule { function script:Show-WtError { param($ErrorRecord,$Action) throw $ErrorRecord } }
        foreach ($phase in 'construct','reuse') {
            foreach ($id in @('home','schedule','attendance','memo','workflows','_settings','_help','docs','active-tasks')) {
                $process.Refresh()
                if ($process.TotalProcessorTime.TotalSeconds -ge $MaxCpuSeconds -or $watch.Elapsed.TotalSeconds -ge $MaxWallSeconds) {
                    $reason = '예산 한도'; break
                }
                $cpu = $process.TotalProcessorTime.TotalMilliseconds
                $step = [Diagnostics.Stopwatch]::StartNew()
                $page = & $shellModule { param($pageId) Get-WtPageView $pageId } $id
                # 비동기 수집 탭은 생성만 본다. 실제 UIA나 runspace 수집을 시작하지 않는다.
                $scope = '동기 갱신·배치'
                if ($id -in 'docs','active-tasks') { $scope = '화면 생성·배치만' }
                elseif ($page.Addon -and $page.Addon.Refresh) { [void](& $page.Addon.Refresh $page.View) }
                $hostView.Content = $page.View
                $size = [Windows.Size]::new($Config.ContentWidth,$Config.ContentHeight)
                $hostView.Measure($size)
                $hostView.Arrange([Windows.Rect]::new(0,0,$size.Width,$size.Height))
                $hostView.UpdateLayout()
                $step.Stop(); $process.Refresh()
                $rows.Add([pscustomobject]@{ Phase=$phase; Page=$id; Scope=$scope; WallMs=$step.Elapsed.TotalMilliseconds; CpuMs=($process.TotalProcessorTime.TotalMilliseconds-$cpu) })
                [Threading.Thread]::Sleep($Config.PauseMilliseconds)
            }
            if ($reason -ne '완료') { break }
        }
    } catch { $failure = $_.Exception.Message; $reason = '오류' }
    finally {
        if (Get-Command Get-WtAddon -ErrorAction SilentlyContinue) {
            foreach ($addon in @(Get-WtAddon -All)) {
                if ($addon.OnExit) { try { [void](& $addon.OnExit) } catch { } }
            }
        }
    }
    $process.Refresh()
    Write-PerfLightResult ([ordered]@{ Mode='offscreen-light'; Reason=$reason; Failure=$failure; ComparableToAH=$false; Rows=@($rows.ToArray()); CpuSeconds=$process.TotalProcessorTime.TotalSeconds; WallSeconds=$watch.Elapsed.TotalSeconds })
    if ($failure) { exit 1 }
    exit 0
}

if (-not $IsWindows) { throw 'Windows에서 실행하세요.' }
if (-not $OutputPath) { $OutputPath = Join-Path ([IO.Path]::GetTempPath()) ('wt-perf-light-result-' + [guid]::NewGuid().ToString('N')) }
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $OutputPath) { throw '결과를 덮어쓰지 않도록 새 OutputPath를 지정하세요.' }
[void][IO.Directory]::CreateDirectory($OutputPath)
$load = Get-PerfLoad
if ($MaxSystemCpuPercent -lt 100 -and ($null -eq $load -or $load -gt $MaxSystemCpuPercent)) {
    Write-PerfLightResult ([ordered]@{ Mode='offscreen-light'; Reason='시스템 부하로 생략'; LoadBefore=$load; MaxSystemCpuPercent=$MaxSystemCpuPercent; ComparableToAH=$false; Rows=@() })
    Write-Host "경량 확인 생략: 전체 CPU $load% (한도 $MaxSystemCpuPercent%)"
    return
}

# 부모가 소유한 임시 폴더만 만들며, 강제 중단해도 같은 경로만 정리한다.
$root = Join-Path ([IO.Path]::GetTempPath()) ('wt-perf-light-' + [guid]::NewGuid().ToString('N'))
$test = [pscustomobject]@{ Root=$root; App=(Join-Path $root 'app'); Data=(Join-Path $root 'data') }
[void][IO.Directory]::CreateDirectory($test.App)
Set-Content -LiteralPath (Join-Path $test.App 'datapath.txt') -Value $test.Data -Encoding utf8
$child = $null; $stopReason = $null; $loads = [Collections.Generic.List[double]]::new()
$parentWatch = [Diagnostics.Stopwatch]::StartNew()
try {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'pwsh.exe'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.Environment['DOTNET_TieredCompilation'] = '0'
    foreach ($arg in @('-NoLogo','-NoProfile','-STA','-File',$PSCommandPath,'-LightWorker','-AppRoot',$test.App,'-OutputPath',$OutputPath,'-MaxCpuSeconds',"$MaxCpuSeconds",'-MaxWallSeconds',"$MaxWallSeconds")) { $info.ArgumentList.Add($arg) }
    $child = [Diagnostics.Process]::Start($info)
    $child.StandardInput.Close()
    $outTask = $child.StandardOutput.ReadToEndAsync(); $errorTask = $child.StandardError.ReadToEndAsync()
    $child.PriorityClass = 'BelowNormal'
    while (-not $child.WaitForExit(200)) {
        $child.Refresh()
        if ($child.TotalProcessorTime.TotalSeconds -ge $MaxCpuSeconds) { $stopReason='CPU 예산 한도'; break }
        if ($parentWatch.Elapsed.TotalSeconds -ge $MaxWallSeconds) { $stopReason='시간 한도'; break }
        # 감시 루프에서 CIM 등 외부 조회를 하지 않아 예산 확인이 지연되지 않게 한다.
    }
    if ($stopReason -and -not $child.HasExited) { $child.Kill($true); [void]$child.WaitForExit(5000) }
    $child.Refresh()
    $resultFile = Join-Path $OutputPath 'light-result.json'
    $result = $null
    if (Test-Path -LiteralPath $resultFile) {
        try { $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json -AsHashtable }
        catch { if (-not $stopReason) { throw } }
    }
    # 예산 중단이 자식의 JSON 쓰기와 겹쳐도 중단 사유는 온전히 남긴다.
    if (-not $result) { $result = [ordered]@{ Mode='offscreen-light'; Reason=$(if ($stopReason) { $stopReason } else { '자식 종료 시 결과 없음' }); ComparableToAH=$false; Rows=@() } }
    $result.LoadBefore=$load; $result.LoadSamples=@($loads.ToArray())
    $result.CpuSeconds=$child.TotalProcessorTime.TotalSeconds; $result.WallSeconds=$parentWatch.Elapsed.TotalSeconds
    if ($stopReason) { $result.Reason=$stopReason }
    $result.ExitCode=$child.ExitCode
    Write-PerfLightResult $result
    Write-Host "경량 확인: $($result.Reason), CPU $([Math]::Round($result.CpuSeconds,2))초, 벽시계 $([Math]::Round($result.WallSeconds,2))초, 창 표시 없음"
} finally {
    if ($child) { if (-not $child.HasExited) { $child.Kill($true); [void]$child.WaitForExit(5000) }; $child.Dispose() }
    Remove-WtTestData $test
}

<#
.SYNOPSIS
    활성 작업의 설정·표·닫기를 가짜 데이터와 전용 테스트 창으로 검사한다.
.DESCRIPTION
    사용자 창/브라우저/데이터는 읽거나 닫지 않는다. UI Automation 검사는 이 스크립트가 만든 창 핸들만 사용한다.
    tests\Test-Core.ps1이 찾아서 돌린다.
.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/active-tasks/Test-ActiveTasks.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param([string]$PreviewPath, [string[]]$BrowserPath = @())

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'ActiveTasks.psm1') -Force -DisableNameChecking
$module = Get-Module ActiveTasks
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('wt-active-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tmp)
Set-Content -LiteralPath (Join-Path $tmp 'datapath.txt') -Value (Join-Path $tmp 'data') -Encoding utf8
Set-WtAppRoot $tmp
Initialize-WtSettings
$fixture = $null

function Assert-Active([string]$Name, [bool]$Ok) {
    if (-not $Ok) { throw "FAIL 활성 작업: $Name" }
    Write-Host "PASS 활성 작업: $Name"
}
function Invoke-TestWorker($Request) {
    if (-not $Request.ContainsKey('Handles')) { throw '테스트에서는 전용 창 핸들을 반드시 지정해야 합니다.' }
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript((Get-WtTaskWorker).ToString()).AddArgument($Request)
    $async = $ps.BeginInvoke()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $async.IsCompleted) {
            if ($watch.Elapsed.TotalSeconds -gt 20) { $Request.Cancel.Value = $true; throw '전용 테스트 창의 UIA 응답 시간 초과' }
            # STA 테스트 창이 UIA 요청을 처리하도록 메시지만 돌린다.
            $frame = [System.Windows.Threading.DispatcherFrame]::new()
            $pulse = [System.Windows.Threading.DispatcherTimer]::new()
            $pulse.Interval = [timespan]::FromMilliseconds(25)
            $pulse.Tag = $frame
            $pulse.Add_Tick({ param($s, $e) $s.Stop(); $s.Tag.Continue = $false })
            $pulse.Start(); [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        }
        $values = @($ps.EndInvoke($async))
        if (-not $values.Count -or $values[-1] -isnot [System.Collections.IDictionary]) { throw ($ps.Streams.Error | Select-Object -First 1) }
        $values[-1]
    } finally {
        if ($async.IsCompleted) { $ps.Dispose(); $rs.Dispose() }
        else { [void]$ps.BeginStop($null, $null); $rs.CloseAsync() }
    }
}

try {
    Assert-Active '기본은 수동 · 5분' ((Get-WtTaskRefresh).mode -eq 'manual' -and (Get-WtTaskRefresh).minutes -eq 5)
    foreach ($valid in '1', '5', '1440', ' 10 ') { Assert-Active "분 입력 $valid" ((ConvertTo-WtTaskMinutes $valid) -gt 0) }
    foreach ($invalid in '', '0', '-1', '1.5', '1e2', '1441', '999999999999999') {
        $threw = $false; try { [void](ConvertTo-WtTaskMinutes $invalid) } catch { $threw = $true }
        Assert-Active "잘못된 분 입력 거절 [$invalid]" $threw
    }
    Set-WtTaskRefresh 'auto' '3'; Initialize-WtSettings
    Assert-Active '자동 모드와 간격 저장 · 재읽기' ((Get-WtTaskRefresh).mode -eq 'auto' -and (Get-WtTaskRefresh).minutes -eq 3)
    Set-WtTaskRefresh 'manual' '3'
    Assert-Active '수동 전환은 간격을 기억' ((Get-WtTaskRefresh).mode -eq 'manual' -and (Get-WtTaskRefresh).minutes -eq 3)
    $before = Get-Content -LiteralPath (Get-WtSettingsPath) -Raw
    try { Set-WtTaskRefresh 'auto' '0' } catch { }
    Assert-Active '입력 오류는 설정을 바꾸지 않음' ((Get-Content -LiteralPath (Get-WtSettingsPath) -Raw) -eq $before)
    $now = [datetime]::UtcNow
    Assert-Active '기한이 된 자동 갱신' (Test-WtTaskAutoDue 'auto' $now $now $true $false $false)
    Assert-Active '수동/숨김/대화상자/처리 중에는 자동 갱신 안 함' (
        -not (Test-WtTaskAutoDue 'manual' $now $now $true $false $false) -and
        -not (Test-WtTaskAutoDue 'auto' $now $now $false $false $false) -and
        -not (Test-WtTaskAutoDue 'auto' $now $now $true $true $false) -and
        -not (Test-WtTaskAutoDue 'auto' $now $now $true $false $true) -and
        -not (Test-WtTaskAutoDue 'auto' $now $now.AddMinutes(1) $true $false $false))
    $rows = @(
        [pscustomobject]@{ Id = 'a'; AppKey = 'chrome'; AppLabel = 'Google Chrome'; Title = '같은 제목'; DisplayTitle = '같은 제목'; Kind = 'tab'; KindLabel = '탭'; WindowNumber = 1; WindowLabel = '창 1'; Status = '현재 탭'; Selected = $true; CanClose = $true; CloseHint = '선택' },
        [pscustomobject]@{ Id = 'b'; AppKey = 'chrome'; AppLabel = 'Google Chrome'; Title = '같은 제목'; DisplayTitle = '같은 제목'; Kind = 'tab'; KindLabel = '탭'; WindowNumber = 2; WindowLabel = '창 2'; Status = ''; Selected = $false; CanClose = $true; CloseHint = '선택' },
        [pscustomobject]@{ Id = 'c'; AppKey = 'msedge'; AppLabel = 'Microsoft Edge'; Title = '읽기 제한'; DisplayTitle = '읽기 제한'; Kind = 'unavailable'; KindLabel = '창'; WindowNumber = 1; WindowLabel = '창 1'; Status = '탭 확인 불가'; Selected = $false; CanClose = $false; CloseHint = '닫기 지원 안 됨' }
    )
    Assert-Active '같은 제목의 다른 항목 유지 · 프로그램 필터' (@(Find-WtTaskItems $rows '같은 제목' 'chrome').Count -eq 2)
    Assert-Active '부분 선택은 그룹 중간 상태' ($null -eq (Get-WtTaskCheckState $rows))
    Assert-Active '닫기 불가 항목은 그룹 전체 선택 계산에서 제외' ((Get-WtTaskCheckState @($rows[0], $rows[2])) -eq $true)
    & $module { param($data) $script:items = $data } $rows
    $copy = @($rows | ForEach-Object { $_.PSObject.Copy() }); $copy[0].Selected = $false
    & $module { param($data) Set-WtTaskSnapshot $data } $copy
    Assert-Active '새로 고침은 ID로 선택 유지' ((& $module { $script:items[0].Selected }) -eq $true)
    $hostIds = @(Get-WtTaskHostIds)
    Assert-Active 'WorkTool을 띄운 프로세스 목록에 자기 자신은 없음' ($hostIds -notcontains $PID -and -not @($hostIds | Where-Object { $_ -isnot [int] }).Count)
    Set-WtTaskRefresh 'manual' '5'

    if ($IsWindows -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, UIAutomationClient, UIAutomationTypes
        $addon = Get-WtAddon -Id 'active-tasks'
        $view = @(& $addon.NewView | Where-Object { $_ -is [Windows.UIElement] })[-1]
        $view.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $view.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
        Set-WtResource $view Background 'B.WindowBg'
        & $module { Update-WtTaskList -KeepSelection }
        $view.Measure([Windows.Size]::new(1048, 632)); $view.Arrange([Windows.Rect]::new(0, 0, 1048, 632)); $view.UpdateLayout()
        Assert-Active '표 · 그룹을 렌더링' ((& $module { $script:ui.Grid.Items.Count }) -eq 3)
        & $module {
            $script:testGridSource = $script:ui.Grid.ItemsSource; $script:testModel = $script:items[0]
            $script:lastScan = [datetime]::Today.AddDays(-1)
            $data = @($script:items | ForEach-Object { $_.PSObject.Copy() })
            Set-WtTaskSnapshot $data; Update-WtTaskList -KeepSelection
        }
        Assert-Active '같은 수집 결과는 표·바인딩 객체 재사용 · 수집 시각 갱신' (& $module {
            [object]::ReferenceEquals($script:testGridSource,$script:ui.Grid.ItemsSource) -and
                [object]::ReferenceEquals($script:testModel,$script:items[0]) -and $script:lastScan -ge [datetime]::Today
        })
        & $module {
            $script:testOriginalRows = @($script:items)
            $data = @($script:items | ForEach-Object { $_.PSObject.Copy() }); $data[0].Status = '바뀐 상태'
            Set-WtTaskSnapshot $data; Update-WtTaskList -KeepSelection
        }
        Assert-Active '같은 ID의 상태가 바뀌면 표에 새 결과를 반영한다' (& $module {
            -not [object]::ReferenceEquals($script:testGridSource,$script:ui.Grid.ItemsSource) -and $script:items[0].Status -eq '바뀐 상태'
        })
        & $module { Set-WtTaskSnapshot $script:testOriginalRows; Update-WtTaskList -KeepSelection }
        Assert-Active '우클릭 메뉴에 수동 · 자동' ((& $module { $script:ui.Refresh.ContextMenu.Items.Count }) -eq 2)
        Assert-Active '수동 메뉴 체크와 간격 표시' ((& $module { $script:ui.Manual.IsChecked }) -and (& $module { $script:ui.Mode.Text }) -eq '수동')
        Set-WtTaskRefresh 'auto' '2'
        Assert-Active '자동 적용 시 모드 표시 갱신' ((& $module { $script:ui.Mode.Text }) -eq '자동 · 2분' -and (& $module { $script:ui.Auto.IsChecked }))
        & $module { $script:ui.Manual.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent)) }
        Assert-Active '수동 메뉴 클릭은 자동 갱신 중지' ((Get-WtTaskRefresh).mode -eq 'manual')
        # 실제 대화상자와 타이머 연결을 검사하되, 수집 함수는 가짜 호출 기록으로 교체한다.
        $shellModule = Get-Module Shell
        $testHost = [Windows.Window]::new(); $testHost.Title = 'WorkTool 표 검사'; $testHost.Width = 1100; $testHost.Height = 700
        $testHost.ShowInTaskbar = $false; $testHost.ShowActivated = $false; $testHost.Content = $view
        & $shellModule { param($window) $script:window = $window } $testHost
        & $module {
            $script:originalStart = (Get-Command Start-WtTaskJob).ScriptBlock
            $script:originalModal = Get-Command New-WtModal
            $script:testJobs = 0
            Set-Item Function:script:Start-WtTaskJob -Value { param($Action, $Targets) $script:testJobs++; $script:next = [datetime]::UtcNow.AddMinutes(5) }
            Set-Item Function:script:New-WtModal -Value {
                param($Title)
                $dialog = & $script:originalModal $Title
                $script:testButtons = $dialog.Buttons
                $dialog.Window.Add_ContentRendered({
                    param($s, $e)
                    try {
                        $script:testPaused = $script:paused
                        $script:next = [datetime]::UtcNow.AddMinutes(-1); Invoke-WtTaskTick
                        if ($script:testScenario -eq 'cancel') { $s.Tag.Box.Text = '9' }
                        else {
                            $s.Tag.Box.Text = if ($script:testScenario -eq 'invalid') { '0' } else { '7' }
                            $script:testButtons.Children[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                            $script:testErrorVisible = $s.Tag.Error.Visibility -eq 'Visible'
                        }
                    } finally { if ($s.IsVisible) { $s.DialogResult = $false } }
                })
                $dialog
            }
        }
        try {
            $testHost.Show(); $testHost.UpdateLayout(); $testHost.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ContextIdle)
            Assert-Active '실제 그룹 머리글 체크 상태' ((& $module { $script:ui.GroupChecks.Count }) -eq 2 -and $null -eq (& $module { $script:ui.GroupChecks['Google Chrome'].IsChecked }))
            & $module {
                $check = $script:ui.GroupChecks['Google Chrome']; $check.IsChecked = $true
                $check.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
            Assert-Active '그룹 체크는 해당 프로그램의 닫기 가능한 행만 선택' ((& $module { @($script:items | Where-Object Selected).Count }) -eq 2)
            $testHost.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ContextIdle)
            Assert-Active '그룹 체크 뒤 다시 만든 같은 그룹 체크박스로 포커스를 돌려준다' ([object]::ReferenceEquals([Windows.Input.FocusManager]::GetFocusedElement($testHost), (& $module { $script:ui.GroupChecks['Google Chrome'] })))
            & $module {
                $rowCheck = Get-WtVisualChild (Find-WtTaskRow $script:ui.Grid 'b') ([Windows.Controls.CheckBox])
                $rowCheck.IsChecked = $false
                $rowCheck.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
            }
            $testHost.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ContextIdle)
            $focused = [Windows.Input.FocusManager]::GetFocusedElement($testHost)
            Assert-Active '행 체크 뒤 같은 항목 체크박스로 포커스를 돌려준다' ($focused -is [Windows.Controls.CheckBox] -and $focused.Tag -eq 'task' -and $focused.DataContext.Id -eq 'b' -and -not (& $module { ($script:items | Where-Object Id -eq 'b').Selected }))
            & $module { $node = Get-WtVisualChild $script:ui.Grid ([Windows.Controls.Expander]); $node.IsExpanded = $false; Update-WtTaskList -KeepSelection }
            $testHost.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::ContextIdle)
            Assert-Active '새로 고침 후 접은 그룹 유지' (-not (& $module { (Get-WtVisualChild $script:ui.Grid ([Windows.Controls.Expander])).IsExpanded }))
            & $module { $script:ui.Search.Text = '읽기' }
            Assert-Active '검색 변경은 숨은 항목의 체크 해제' ((& $module { @($script:items | Where-Object Selected).Count }) -eq 0 -and (& $module { $script:visible.Count }) -eq 1)
            & $module { $script:ui.Search.Text = ''; $script:testScenario = 'cancel'; Show-WtTaskRefreshDialog }
            Assert-Active '모달 취소는 모드/간격 유지' ((Get-WtTaskRefresh).mode -eq 'manual' -and (Get-WtTaskRefresh).minutes -eq 2)
            Set-WtTaskRefresh 'auto' '2'
            & $module { $script:testScenario = 'invalid'; Show-WtTaskRefreshDialog }
            Assert-Active '모달 입력 오류는 인라인 표시 · 이전 설정 유지' ((& $module { $script:testErrorVisible }) -and (Get-WtTaskRefresh).minutes -eq 2)
            Assert-Active '모달이 열려 있는 동안 자동 수집 안 함' ((& $module { $script:testPaused }) -and (& $module { $script:testJobs }) -eq 0)
            & $module { $script:testScenario = 'valid'; Show-WtTaskRefreshDialog }
            Assert-Active '모달 적용은 자동 · 7분으로 저장' ((Get-WtTaskRefresh).mode -eq 'auto' -and (Get-WtTaskRefresh).minutes -eq 7)
            & $module { $script:next = [datetime]::UtcNow.AddMinutes(-1); Invoke-WtTaskTick }
            Assert-Active '보이는 탭에서 실제 타이머 경로가 수집 호출' ((& $module { $script:testJobs }) -eq 1)
            $testHost.Hide()
            & $module { $script:next = [datetime]::UtcNow.AddMinutes(-1); Invoke-WtTaskTick }
            Assert-Active '창을 숨기면 자동 수집 안 함' ((& $module { $script:testJobs }) -eq 1)
            Assert-Active '숨긴 탭의 유휴 타이머 중지' (-not (& $module { $script:timer.IsEnabled }))
            $testHost.Show()
            Assert-Active '다시 보이면 타이머 재시작' (& $module { $script:timer.IsEnabled })
            $testHost.Content = $null
            Assert-Active '탭을 떼어 내면 유휴 타이머 중지' (-not (& $module { $script:timer.IsEnabled }))
        } finally {
            $testHost.Close(); & $shellModule { $script:window = $null }
            & $module { Stop-WtTasks; Set-Item Function:script:Start-WtTaskJob -Value $script:originalStart; Remove-Item Function:script:New-WtModal }
        }
        # 실제 비동기 시작/완료 경로. worker만 빈 가짜 스냅샷으로 바꿔 데스크톱 조회를 막는다.
        & $module {
            $script:savedWorker = $script:worker
            $script:worker = { param($request) @{ Items = @(); FailedWindows = 0; Canceled = $false } }
            $script:timer = [Windows.Threading.DispatcherTimer]::new()
            Start-WtTaskJob 'scan'
            $first = $script:job
            Start-WtTaskJob 'scan'
            if (-not [object]::ReferenceEquals($first, $script:job)) { throw '중복 작업이 시작되었습니다.' }
        }
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while ((& $module { [bool]$script:job }) -and $watch.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 25; Update-WtWork }
            Assert-Active '비동기 수집 완료 · 중복 실행 방지' (-not (& $module { [bool]$script:job }) -and (& $module { $script:items.Count }) -eq 0)
            # 호출마다 새 스레드: 앞 호출의 변수가 남지 않는다 (실행 공간은 상태를 지운 뒤 다시 쓸 수 있다). 끝난 작업은 실행 공간을 놓는다
            $seen = [Collections.Generic.List[object]]::new()
            [AppDomain]::CurrentDomain.SetData('WtTestTaskSeen', $seen)
            & $module {
                $script:worker = {
                    param($request)
                    [AppDomain]::CurrentDomain.GetData('WtTestTaskSeen').Add(@{
                            Thread = [Threading.Thread]::CurrentThread.ManagedThreadId; Runspace = [runspace]::DefaultRunspace.InstanceId
                            Left = [bool](Get-Variable testLeftover -Scope Global -ErrorAction SilentlyContinue)
                        })
                    $global:testLeftover = 1
                    @{ Items = @(); FailedWindows = 0; Canceled = $false }
                }
            }
            $works = foreach ($i in 1..2) {
                & $module { Start-WtTaskJob 'scan'; $script:job.Work }
                $watch.Restart()
                while ((& $module { [bool]$script:job }) -and $watch.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 25; Update-WtWork }
            }
            [AppDomain]::CurrentDomain.SetData('WtTestTaskSeen', $null)
            Assert-Active '호출마다 새 스레드이고, 앞 호출의 변수가 남지 않으며, 끝난 작업은 실행 공간을 놓는다' (
                $seen.Count -eq 2 -and $seen[0].Thread -ne $seen[1].Thread -and
                -not $seen[0].Left -and -not $seen[1].Left -and @($works | Where-Object { $_.Finished -and -not $_.Runspace }).Count -eq 2)
            & $module { Invoke-WtTaskTick }
            Assert-Active '숨긴 탭도 실행 결과 회수 뒤 타이머 중지' (-not (& $module { $script:timer.IsEnabled }))
            # 응답 없는 프로그램: 수집이 돌아오지 않아도 끝낼 때 기다리지 않고 버린다
            $gate = New-WtTestGate
            try {
                & $module { param($hang) $script:worker = $hang; Start-WtTaskJob 'scan' } $wtTestHang
                $entered = $gate.Entered.WaitOne(5000)
                $watch.Restart(); & $module { Stop-WtTasks }; $stopMs = $watch.ElapsedMilliseconds
                Assert-Active "응답 없는 수집이 남아도 끝낼 때 기다리지 않는다 (${stopMs}ms)" ($entered -and $stopMs -lt 200 -and -not (& $module { $script:job }) -and (Get-WtWorkInfo).Running -eq 0)
            } finally { Remove-WtTestGate $gate }
        } finally { & $module { Stop-WtTasks; $script:worker = $script:savedWorker } }
        Assert-Active '끝낸 뒤 남은 화면 밖 작업이 없다' ((Get-WtWorkInfo).Running -eq 0 -and (Get-WtWorkInfo).Abandoned -eq 0)
        if ($PreviewPath) {
            $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(1048, 632, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
            $bitmap.Render($view)
            $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
            $stream = [IO.File]::Create($PreviewPath); try { $encoder.Save($stream) } finally { $stream.Dispose() }
        }

        # 일반 사용자 창은 열거하지 않는다. 아래 전용 핸들 하나만 worker에 전달한다.
        $fixture = [Windows.Window]::new(); $fixture.Title = 'WorkTool 전용 UIA 테스트'; $fixture.Width = 400; $fixture.Height = 240
        $fixture.ShowActivated = $false; $fixture.ShowInTaskbar = $false
        $tabs = [Windows.Controls.TabControl]::new()
        $tabRefs = [Collections.Generic.List[object]]::new()   # 제목이 모두 같으므로 어떤 탭이 남았는지는 객체로 확인한다
        for ($i = 0; $i -lt 3; $i++) {
            $tab = [Windows.Controls.TabItem]::new(); $tabRefs.Add($tab)
            [Windows.Automation.AutomationProperties]::SetName($tab, '같은 제목')
            $header = [Windows.Controls.StackPanel]::new(); $header.Orientation = 'Horizontal'
            $label = [Windows.Controls.TextBlock]::new(); $label.Text = '같은 제목'; [void]$header.Children.Add($label)
            $button = [Windows.Controls.Button]::new(); $button.Content = '닫기'; $button.Tag = @{ Tabs = $tabs; Tab = $tab }
            [Windows.Automation.AutomationProperties]::SetName($button, '탭 닫기')
            $button.Add_Click({ param($s, $e) $s.Tag.Tabs.Items.Remove($s.Tag.Tab) })
            [void]$header.Children.Add($button); $tab.Header = $header; $tab.Content = '가짜 페이지'; [void]$tabs.Items.Add($tab)
        }
        $fixture.Content = $tabs; $fixture.Show()
        $handle = [Windows.Interop.WindowInteropHelper]::new($fixture).Handle.ToInt64()
        $request = @{ Action = 'scan'; Handles = @($handle); BrowserNames = @((Get-Process -Id $PID).ProcessName); SelfProcessId = -1; Cancel = [hashtable]::Synchronized(@{ Value = $false }) }
        $missingScopeRejected = $false
        try { [void](Invoke-TestWorker @{ Action = 'scan'; Cancel = [hashtable]::Synchronized(@{ Value = $false }) }) } catch { $missingScopeRejected = $true }
        Assert-Active '전용 핸들 지정 자체가 없으면 테스트 실행 거절' $missingScopeRejected
        foreach ($badHandles in @(@(), @(0))) {
            $invalidRequest = @{ Action = 'scan'; Handles = $badHandles; SelfProcessId = -1; Cancel = [hashtable]::Synchronized(@{ Value = $false }) }
            $rejected = $false; try { [void](Invoke-TestWorker $invalidRequest) } catch { $rejected = $true }
            Assert-Active '빈 테스트 핸들은 전체 창 조회 없이 거절' $rejected
        }
        $snapshot = Invoke-TestWorker $request
        Assert-Active '전용 창의 탭 3개 수집' (@($snapshot.Items | Where-Object Kind -eq tab).Count -eq 3)
        Assert-Active '같은 창·같은 제목은 탭 순서를 표시' (@($snapshot.Items | Where-Object DisplayTitle -match '\(탭 [123]\)').Count -eq 3)
        $target = @($snapshot.Items | Where-Object Kind -eq tab)[0]
        $wrong = $target.PSObject.Copy(); $wrong.ProcessStart = 0
        $request.Action = 'close'; $request.Targets = @($wrong)
        $bad = Invoke-TestWorker $request
        Assert-Active '프로세스 식별 불일치는 닫지 않음' ($bad.Results[0].State -eq 'failed' -and $tabs.Items.Count -eq 3)
        $wrongTitle = $target.PSObject.Copy(); $wrongTitle.Title = '다른 제목'
        $request.Targets = @($wrongTitle)
        $bad = Invoke-TestWorker $request
        Assert-Active '실제 제목이 달라지면 닫지 않음' ($bad.Results[0].State -eq 'failed' -and $tabs.Items.Count -eq 3)
        # 1번째와 3번째 탭을 고른다. 제목이나 순서로 고르면 가운데 탭이 닫히므로 식별자로 닫는지 가려진다.
        $tabRows = @($snapshot.Items | Where-Object Kind -eq tab | Sort-Object TabIndex)
        $request.Targets = @($tabRows[0], $tabRows[2])
        $request.Cancel.Value = $true
        $canceled = Invoke-TestWorker $request
        Assert-Active '취소된 일괄 닫기는 아무 탭도 닫지 않음' (@($canceled.Results | Where-Object State -eq canceled).Count -eq 2 -and $tabs.Items.Count -eq 3)
        $request.Cancel.Value = $false
        $hostRequest = $request.Clone(); $hostRequest.HostProcessIds = @($PID)
        $refused = Invoke-TestWorker $hostRequest
        Assert-Active 'WorkTool을 띄운 프로그램의 창·탭은 닫지 않음' (@($refused.Results | Where-Object State -eq failed).Count -eq 2 -and $tabs.Items.Count -eq 3)
        $closed = Invoke-TestWorker $request
        Assert-Active '같은 제목이어도 고른 두 탭만 닫고 가운데 탭 유지' (@($closed.Results | Where-Object State -eq closed).Count -eq 2 -and $tabs.Items.Count -eq 1 -and [object]::ReferenceEquals($tabs.Items[0], $tabRefs[1]))
        $hostScan = Invoke-TestWorker @{ Action = 'scan'; Handles = @($handle); BrowserNames = @((Get-Process -Id $PID).ProcessName); SelfProcessId = -1; HostProcessIds = @($PID); Cancel = [hashtable]::Synchronized(@{ Value = $false }) }
        $hostRows = @($hostScan.Items)
        Assert-Active 'WorkTool을 띄운 프로그램 창은 닫기 불가로 표시' ($hostRows.Count -eq 1 -and $hostRows[0].Kind -eq 'window' -and -not $hostRows[0].CanClose -and $hostRows[0].Status -eq 'WorkTool 실행 중')
        $request.Action = 'scan'; $request.BrowserNames = @('not-a-browser')
        $snapshot = Invoke-TestWorker $request
        $windowTarget = @($snapshot.Items)[0]
        $fixture.Add_Closing({ param($s, $e) if ($s.Tag -eq 'keep') { $e.Cancel = $true } })
        $fixture.Tag = 'keep'; $request.Action = 'close'; $request.Targets = @($windowTarget)
        $kept = Invoke-TestWorker $request
        Assert-Active '프로그램이 닫기를 막으면 확인 필요' ($kept.Results[0].State -eq 'confirmation' -and $fixture.IsVisible)
        $fixture.Tag = $null
        $closed = Invoke-TestWorker $request
        Assert-Active '일반 창 닫기 결과 확인' ($closed.Results[0].State -eq 'closed' -and -not $fixture.IsVisible)
        foreach ($exe in $BrowserPath) {
            # 호출자가 명시한 설치된 브라우저만 검사한다. 기존 프로필은 읽지 않는다.
            $profile = Join-Path $tmp ('browser-' + [guid]::NewGuid().ToString('N'))
            $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
            $titleA = "WorkTool Test A $suffix"; $titleB = "WorkTool Test B $suffix"
            $urlA = 'data:text/html,' + [uri]::EscapeDataString("<title>$titleA</title><p>Fake test page A</p>")
            $urlB = 'data:text/html,' + [uri]::EscapeDataString("<title>$titleB</title><p>Fake test page B</p>")
            $browser = Start-Process -FilePath $exe -ArgumentList @("--user-data-dir=`"$profile`"", '--no-first-run', '--no-default-browser-check', '--disable-background-networking', '--disable-sync', '--new-window', $urlA, $urlB) -WindowStyle Hidden -PassThru
            try {
                $watch = [Diagnostics.Stopwatch]::StartNew()
                $browserHandle = 0L
                do { Start-Sleep -Milliseconds 100; $browser.Refresh(); $browserHandle = $browser.MainWindowHandle.ToInt64() } while (-not $browserHandle -and -not $browser.HasExited -and $watch.Elapsed.TotalSeconds -lt 15)
                if (-not $browserHandle) { throw '격리 브라우저의 전용 창을 찾지 못했습니다.' }
                Start-Sleep -Seconds 2
                $request = @{ Action = 'scan'; Handles = @($browserHandle); SelfProcessId = -1; Cancel = [hashtable]::Synchronized(@{ Value = $false }) }
                $snapshot = Invoke-TestWorker $request
                Assert-Active '지정한 테스트 핸들 외에는 수집하지 않음' (@($snapshot.Items | Where-Object Handle -ne $browserHandle).Count -eq 0)
                $realTabs = @($snapshot.Items | Where-Object { $_.Kind -eq 'tab' -and $_.Title -match [regex]::Escape($suffix) })
                if ($realTabs.Count -ne 2) { Write-Host "전용 브라우저 결과: 항목 $(@($snapshot.Items).Count), 탭 $(@($snapshot.Items | Where-Object Kind -eq tab).Count), 읽기 실패 $($snapshot.FailedWindows)" }
                Assert-Active "$($browser.ProcessName): 새 프로필의 테스트 탭 2개" ($realTabs.Count -eq 2)
                $request.Action = 'close'; $request.Targets = @($realTabs | Where-Object Title -eq $titleA)
                Assert-Active '브라우저 닫기 검사 대상은 정확히 한 탭' ($request.Targets.Count -eq 1)
                $closed = Invoke-TestWorker $request
                if ($closed.Results[0].State -ne 'closed') {
                    Write-Host ("전용 테스트 탭 닫기 결과: {0} / {1}; CanClose={2}" -f $closed.Results[0].State, $closed.Results[0].Message, $request.Targets[0].CanClose)
                }
                Assert-Active "$($browser.ProcessName): 지정한 테스트 탭만 닫기" ($closed.Results[0].State -eq 'closed')
                $request.Action = 'scan'; $snapshot = Invoke-TestWorker $request
                Assert-Active "$($browser.ProcessName): 다른 테스트 탭 유지" (@($snapshot.Items | Where-Object Title -eq $titleB).Count -eq 1 -and @($snapshot.Items | Where-Object Title -eq $titleA).Count -eq 0)
            } finally {
                $browser.Refresh()
                if (-not $browser.HasExited) {
                    [void]$browser.CloseMainWindow()
                    if (-not $browser.WaitForExit(5000)) {
                        # 이 검사에서 만든 새 프로필의 프로세스 트리만 정리한다. 앱 기능에는 강제 종료가 없다.
                        $browser.Kill($true); $browser.WaitForExit()
                    }
                }
                $browser.Dispose()
            }
        }
    } else { Write-Host 'SKIP 활성 작업 WPF/UIA (Windows STA에서만)' }
} finally {
    if ($fixture) { $fixture.Tag = $null; $fixture.Close() }
    & $module { Stop-WtTasks }
    # 이 검사에서 만든 임시 경로만 정리한다.
    $safe = [IO.Path]::GetFullPath($tmp)
    if ((Split-Path $safe -Leaf) -notmatch '^wt-active-[a-f0-9]{32}$' -or -not $safe.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw '임시 경로 검증 실패' }
    try { Remove-Item -LiteralPath $safe -Recurse -Force } catch { Write-Warning "테스트 임시 폴더 정리 실패: $safe" }
}

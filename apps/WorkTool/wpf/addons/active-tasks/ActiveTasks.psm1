# 활성 작업. 창/탭 제목은 메모리에만 두고, 새로 고침 설정만 Settings를 통해 저장한다.
# 수집/닫기는 별도 MTA runspace에서 Windows 기본 UI Automation으로 처리한다.
$ErrorActionPreference = 'Stop'
$script:ui = @{}
$script:items = @()
$script:snapshotKey = $null
$script:snapshotVersion = 0
$script:listKey = $null
$script:visible = @()
$script:expanded = @{}
$script:job = $null
$script:workerRunspace = $null
$script:timer = $null
$script:paused = $false
$script:next = [datetime]::MaxValue
$script:lastScan = $null
$script:resultText = ''
$script:lastError = ''
$script:appFilter = '*'
$script:sortColumn = 'DisplayTitle'
$script:sortDirection = 'Ascending'
$script:focusTarget = $null   # 표를 다시 만든 뒤 포커스를 돌려줄 체크박스 @{ Id } 또는 @{ Group }
Register-WtSettingDefault 'tasks.refresh' @{ mode = 'manual'; minutes = 5 }

function ConvertTo-WtTaskMinutes([string]$Text) {
    $value = 0
    if ($Text.Trim() -notmatch '^[0-9]+$' -or -not [int]::TryParse($Text.Trim(), [ref]$value) -or $value -lt 1 -or $value -gt 1440) {
        throw '1~1,440분 사이의 정수를 입력하세요.'
    }
    $value
}

function Get-WtTaskRefresh {
    $option = Get-WtSetting 'tasks.refresh'
    try {
        $minutes = ConvertTo-WtTaskMinutes ([string]$option.minutes)
        $mode = if ($option.mode -eq 'auto') { 'auto' } else { 'manual' }
        @{ mode = $mode; minutes = $minutes }
    } catch { @{ mode = 'manual'; minutes = 5 } }
}

function Set-WtTaskRefresh([string]$Mode, [string]$Minutes) {
    if ($Mode -notin @('manual', 'auto')) { throw '새로 고침 모드를 확인하세요.' }
    $value = ConvertTo-WtTaskMinutes $Minutes
    $previous = Get-WtTaskRefresh
    try { Set-WtSetting 'tasks.refresh' @{ mode = $Mode; minutes = $value } }
    catch {
        # Settings가 파일 쓰기 전에 메모리를 바꾸므로, 쓰기 실패 시 메모리도 되돌린다.
        try { Set-WtSetting 'tasks.refresh' $previous } catch { }
        throw
    }
    $script:next = [datetime]::UtcNow.AddMinutes($value)
    Update-WtTaskStatus
}

function Test-WtTaskAutoDue([string]$Mode, [datetime]$Now, [datetime]$Due, [bool]$Visible, [bool]$Paused, [bool]$Busy) {
    $Mode -eq 'auto' -and $Visible -and -not $Paused -and -not $Busy -and $Now -ge $Due
}

function Find-WtTaskItems([object[]]$Items, [string]$Query, [string]$App = '*') {
    $words = @($Query.Trim() -split '\s+' | Where-Object { $_ })
    @($Items | Where-Object {
        $row = $_
        $ok = $App -eq '*' -or $row.AppKey -eq $App
        foreach ($word in $words) { if ($row.DisplayTitle.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false } }
        $ok
    })
}

function Get-WtTaskCheckState([object[]]$Items) {
    $available = @($Items | Where-Object CanClose)
    $picked = @($available | Where-Object Selected).Count
    if (-not $picked) { return $false }
    if ($picked -eq $available.Count) { return $true }
    $null
}

# WorkTool을 띄운 터미널 · 편집기 같은 조상 프로세스. 그 창을 닫으면 WorkTool도 꺼지므로 표에는 보여 주되 닫지 않는다.
# 탐색기 · 시스템 프로세스에서 멈춘다(그 창들은 그대로 닫을 수 있게). 이미 끝난 부모의 PID를 다른 프로그램이 받았으면 시작 시각으로 걸러 낸다.
function Get-WtTaskHostIds {
    $ids = [System.Collections.Generic.List[int]]::new()
    $stop = @('explorer', 'svchost', 'sihost', 'services', 'wininit', 'winlogon', 'userinit', 'RuntimeBroker', 'csrss', 'smss')
    try {
        $child = Get-Process -Id $PID
        for ($depth = 0; $depth -lt 8; $depth++) {
            $parent = $child.Parent
            if (-not $parent -or $parent.ProcessName -in $stop -or $parent.StartTime -gt $child.StartTime) { break }
            $ids.Add($parent.Id)
            $child = $parent
        }
    } catch { }
    $ids.ToArray()
}

function Set-WtTaskSnapshot([object[]]$Items) {
    $key = ConvertTo-Json -Compress -Depth 5 -InputObject @($Items | Select-Object -Property * -ExcludeProperty Selected)
    $picked = @{}
    foreach ($row in $script:items) { if ($row.Selected) { $picked[$row.Id] = $true } }
    foreach ($row in $Items) { $row.Selected = $row.CanClose -and $picked.ContainsKey($row.Id) }
    if ($script:snapshotKey -cne $key) {
        $script:items = @($Items); $script:snapshotKey = $key; $script:snapshotVersion++
    }
    $script:lastScan = Get-Date
}

# 이 스크립트 블록은 같은 모듈의 소스다. 묶음 배포에서도 외부 파일/모듈이 필요 없다.
# Handles/BrowserNames는 격리된 검사에서만 주입한다. 실제 화면에서는 지정하지 않는다.
$script:worker = {
    param($request)
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $A = [System.Windows.Automation.AutomationElement]
    $T = [System.Windows.Automation.TreeScope]
    $C = [System.Windows.Automation.ControlType]
    $all = [System.Windows.Automation.Condition]::TrueCondition

    function Get-Pattern($element, $pattern) {
        $value = $null
        if ($element.TryGetCurrentPattern($pattern, [ref]$value)) { return $value }
        $null
    }
    function Get-Identity($element) { $element.GetRuntimeId() -join '.' }
    function Get-TabTitle([string]$text) {
        # Edge가 탭 접근성 이름 끝에 늦게 덧붙이는 메모리 안내는 페이지 제목이 아니다.
        $text -replace '\s+-\s+(?:메모리 사용량|Memory usage)\s+-\s+[\d.,]+\s*(?:KB|MB|GB|TB)\s*$', ''
    }
    function Get-ProcessInfo([int]$number) {
        $p = Get-Process -Id $number -ErrorAction Stop
        try { @{ Name = $p.ProcessName; Start = $p.StartTime.ToUniversalTime().Ticks } } finally { $p.Dispose() }
    }
    function Get-TabClose($tab) {
        $condition = [System.Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $C::Button)
        foreach ($button in $tab.FindAll($T::Descendants, $condition)) {
            $info = $button.Current
            if (($info.Name -match '^(Close tab|Close|탭 닫기|닫기)(\s|$)' -or $info.AutomationId -match '^(TabCloseButton|CloseTabButton)$') -and $info.IsEnabled) {
                $invoke = Get-Pattern $button ([System.Windows.Automation.InvokePattern]::Pattern)
                if ($invoke) { return $button }
            }
        }
        $null
    }
    function Get-Tabs($window) {
        $queue = [Collections.Generic.Queue[object]]::new()
        $queue.Enqueue(@{ Element = $window; Depth = 0 })
        $tabs = [Collections.Generic.List[object]]::new()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $seen = 0; $partial = $false
        while ($queue.Count) {
            if ($request.Cancel.Value -or $seen -ge 600 -or $watch.Elapsed.TotalSeconds -gt 4) { $partial = $true; break }
            $node = $queue.Dequeue(); $seen++
            $element = $node.Element
            try {
                $type = $element.Current.ControlType
                # 웹 페이지 본문으로 내려가지 않는다. 페이지 안 ARIA 탭을 브라우저 탭으로 오인하지 않는다.
                if ($type -eq $C::Document) { continue }
                if ($type -eq $C::TabItem) { $tabs.Add($element); continue }
                if ($node.Depth -ge 10) { $partial = $true; continue }
                foreach ($child in $element.FindAll($T::Children, $all)) {
                    $queue.Enqueue(@{ Element = $child; Depth = $node.Depth + 1 })
                }
            } catch { $partial = $true }
        }
        @{ Tabs = @($tabs.ToArray()); Partial = $partial }
    }
    function New-Row($windowInfo, $processInfo, [string]$windowId, [int]$ordinal, [string]$kind, [string]$title, [string]$runtime, [int]$tabIndex, [bool]$canClose, [string]$status) {
        $labels = @{ chrome = 'Google Chrome'; msedge = 'Microsoft Edge'; whale = '네이버 웨일'; EXCEL = 'Microsoft Excel'; WINWORD = 'Microsoft Word'; POWERPNT = 'Microsoft PowerPoint'; explorer = '파일 탐색기'; notepad = '메모장' }
        $appLabel = $processInfo.Name
        if ($labels.ContainsKey($appLabel)) { $appLabel = $labels[$appLabel] }
        [pscustomobject]@{
            Id = "${windowId}/${kind}/${runtime}"; AppKey = $processInfo.Name; AppLabel = $appLabel
            Title = $title; DisplayTitle = $title; Kind = $kind; KindLabel = $(if ($kind -eq 'tab') { '탭' } else { '창' })
            WindowKey = $windowId; WindowNumber = $ordinal; WindowLabel = "창 $ordinal"; TabIndex = $tabIndex
            ProcessId = $windowInfo.ProcessId; ProcessStart = $processInfo.Start; Handle = $windowInfo.NativeWindowHandle
            WindowRuntime = $windowInfo.Runtime; Runtime = $runtime; Status = $status; Selected = $false
            CanClose = $canClose; CloseHint = $(if ($canClose) { '닫을 항목 선택' } else { '이 항목은 여기서 닫을 수 없습니다. 원래 프로그램에서 확인하세요.' })
        }
    }
    function Read-Snapshot {
        $windows = @()
        if ($request.ContainsKey('Handles')) {
            if (-not @($request.Handles).Count -or @($request.Handles | Where-Object { -not $_ -or [long]$_ -le 0 }).Count) { throw '지정한 창 식별자가 없습니다. 전체 창 조회로 전환하지 않습니다.' }
            foreach ($handle in $request.Handles) { $windows += $A::FromHandle([intptr]$handle) }
        }
        else {
            $condition = [System.Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $C::Window)
            $windows = @($A::RootElement.FindAll($T::Children, $condition))
        }
        $rows = [Collections.Generic.List[object]]::new()
        $ordinals = @{}; $failed = 0
        # 탭 단위로 다루는 Chromium 계열 브라우저. 탭을 못 읽으면 창 전체를 닫는 대신 '탭 확인 불가'로 둔다
        $browsers = if ($request.BrowserNames) { $request.BrowserNames } else { @('chrome', 'msedge', 'whale') }
        $hosts = @($request.HostProcessIds)
        foreach ($window in $windows) {
            if ($request.Cancel.Value) { break }
            try {
                $info = $window.Current
                if (-not $info.NativeWindowHandle -or $info.ProcessId -eq $request.SelfProcessId -or -not $info.Name) { continue }
                $wp = Get-Pattern $window ([System.Windows.Automation.WindowPattern]::Pattern)
                if ($wp -and $wp.Current.IsModal) { continue }
                if ($info.ClassName -in @('Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Progman', 'WorkerW')) { continue }
                $processInfo = Get-ProcessInfo $info.ProcessId
                $windowRuntime = Get-Identity $window
                $wi = @{ ProcessId = $info.ProcessId; NativeWindowHandle = $info.NativeWindowHandle; Runtime = $windowRuntime }
                $windowId = '{0}:{1}:{2}:{3}' -f $info.ProcessId, $processInfo.Start, $info.NativeWindowHandle, $windowRuntime
                if (-not $ordinals.ContainsKey($processInfo.Name)) { $ordinals[$processInfo.Name] = 0 }
                $ordinals[$processInfo.Name]++
                $ordinal = $ordinals[$processInfo.Name]
                $minimized = $wp -and $wp.Current.WindowVisualState -eq 'Minimized'
                if ($info.ProcessId -in $hosts) {
                    $row = New-Row $wi $processInfo $windowId $ordinal 'window' $info.Name $windowRuntime 0 $false 'WorkTool 실행 중'
                    $row.CloseHint = 'WorkTool이 이 프로그램에서 실행 중입니다. 닫으면 WorkTool도 꺼지므로 여기서는 닫지 않습니다.'
                    $rows.Add($row)
                    continue
                }
                if ($processInfo.Name -notin $browsers) {
                    $status = if ($minimized) { '최소화' } elseif (-not $wp) { '닫기 지원 안 됨' } else { '' }
                    $rows.Add((New-Row $wi $processInfo $windowId $ordinal 'window' $info.Name $windowRuntime 0 ([bool]$wp) $status))
                    continue
                }
                $read = Get-Tabs $window
                $index = 0
                foreach ($tab in $read.Tabs) {
                    $index++
                    try {
                        $tabInfo = $tab.Current
                        $selection = Get-Pattern $tab ([System.Windows.Automation.SelectionItemPattern]::Pattern)
                        $states = @()
                        if ($selection -and $selection.Current.IsSelected) { $states += '현재 탭' }
                        if ($minimized) { $states += '최소화된 창' }
                        $close = Get-TabClose $tab
                        if (-not $close) { $states += '닫기 지원 안 됨' }
                        $title = if ($tabInfo.Name) { Get-TabTitle $tabInfo.Name } else { "제목 없는 탭 $index" }
                        $rows.Add((New-Row $wi $processInfo $windowId $ordinal 'tab' $title (Get-Identity $tab) $index ([bool]$close) ($states -join ' · ')))
                    } catch { $read.Partial = $true }
                }
                if (-not $read.Tabs.Count -or $read.Partial) {
                    $status = if ($read.Tabs.Count) { '일부 탭 확인 불가' } else { '탭 확인 불가' }
                    $rows.Add((New-Row $wi $processInfo $windowId $ordinal 'unavailable' $info.Name $windowRuntime 0 $false $status))
                }
            } catch { $failed++ }
        }
        foreach ($duplicates in @($rows | Where-Object Kind -eq 'tab' | Group-Object WindowKey, Title | Where-Object Count -gt 1)) {
            foreach ($row in $duplicates.Group) { $row.DisplayTitle = '{0} (탭 {1})' -f $row.Title, $row.TabIndex }
        }
        @{ Items = @($rows.ToArray()); FailedWindows = $failed; Canceled = [bool]$request.Cancel.Value }
    }
    function Find-Target($target) {
        $processInfo = Get-ProcessInfo $target.ProcessId
        if ($processInfo.Start -ne $target.ProcessStart) { throw '프로그램이 다시 시작되었습니다. 새로 고침하세요.' }
        $window = $A::FromHandle([intptr]$target.Handle)
        if ($window.Current.ProcessId -ne $target.ProcessId -or (Get-Identity $window) -ne $target.WindowRuntime) { throw '창이 바뀌었습니다. 새로 고침하세요.' }
        $wp = Get-Pattern $window ([System.Windows.Automation.WindowPattern]::Pattern)
        if ($wp -and $wp.Current.WindowInteractionState -eq 'BlockedByModalWindow') { throw '원래 프로그램의 확인창을 처리하세요.' }
        if ($target.Kind -eq 'window') { return $window }
        if ($target.Kind -ne 'tab') { throw '닫기를 지원하지 않는 항목입니다.' }
        $read = Get-Tabs $window
        foreach ($tab in $read.Tabs) { if ((Get-Identity $tab) -eq $target.Runtime) { return $tab } }
        if ($read.Partial) { throw '탭을 다시 확인하지 못했습니다.' }
        $null
    }
    if ($request.Action -eq 'scan') { Read-Snapshot; return }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($target in $request.Targets) {
        $state = 'failed'; $message = ''
        try {
            if ($request.Cancel.Value) { $state = 'canceled'; $message = '취소됨' }
            elseif ($target.ProcessId -in @($request.HostProcessIds)) { throw 'WorkTool이 실행 중인 프로그램이라 닫지 않습니다.' }
            else {
                $element = Find-Target $target
                if (-not $element) { $state = 'gone'; $message = '이미 없음' }
                else {
                    $currentTitle = if ($target.Kind -eq 'tab') { Get-TabTitle $element.Current.Name } else { $element.Current.Name }
                    if ($currentTitle -ne $target.Title) { throw '제목이 바뀌었습니다. 새로 고침 후 다시 선택하세요.' }
                    if ($target.Kind -eq 'window') {
                        $pattern = Get-Pattern $element ([System.Windows.Automation.WindowPattern]::Pattern)
                        if (-not $pattern) { throw '이 창은 여기서 닫을 수 없습니다.' }
                        $pattern.Close()
                    } else {
                        $button = Get-TabClose $element
                        if (-not $button) { throw '이 탭은 여기서 닫을 수 없습니다.' }
                        $pattern = Get-Pattern $button ([System.Windows.Automation.InvokePattern]::Pattern)
                        $pattern.Invoke()
                    }
                    $state = 'confirmation'; $message = '확인 필요'
                    for ($attempt = 0; $attempt -lt 10; $attempt++) {
                        if ($request.Cancel.Value) { break }
                        [Threading.Thread]::Sleep(150)
                        try {
                            # 닫힌 탭의 원래 UIA 요소를 먼저 확인한다. 다른 UI 영역을 못 읽어도 이 요소의 소멸은 확인할 수 있다.
                            [void]$element.GetCurrentPropertyValue($A::NameProperty, $true)
                            if (-not (Find-Target $target)) { $state = 'closed'; $message = '닫힘'; break }
                        } catch [System.Windows.Automation.ElementNotAvailableException] { $state = 'closed'; $message = '닫힘'; break }
                        catch {
                            $message = '확인 필요: ' + $_.Exception.Message
                            if ($_.Exception.Message -eq '원래 프로그램의 확인창을 처리하세요.') { break }
                        }
                    }
                }
            }
        } catch { $message = $_.Exception.Message }
        $results.Add([pscustomobject]@{ Id = $target.Id; Title = $target.DisplayTitle; State = $state; Message = $message })
    }
    @{ Results = @($results.ToArray()) }
}

function Get-WtTaskWorker { $script:worker }

function Start-WtTaskJob([string]$Action, [object[]]$Targets = @()) {
    if ($script:job) { return }
    $cancel = [hashtable]::Synchronized(@{ Value = $false })
    $ps = $null
    try {
        if (-not $script:workerRunspace -or $script:workerRunspace.RunspaceStateInfo.State -ne 'Opened') {
            if ($script:workerRunspace) { $script:workerRunspace.Dispose(); $script:workerRunspace = $null }
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            # 실행 공간은 재사용하되 호출마다 새 스레드다. ReuseThread로 남는 실행 스레드를 만들지 않는다.
            $runspace.ApartmentState = 'MTA'; $runspace.ThreadOptions = 'UseNewThread'
            try { $runspace.Open(); $script:workerRunspace = $runspace } catch { $runspace.Dispose(); throw }
        }
        $runspace = $script:workerRunspace
        $ps = [powershell]::Create(); $ps.Runspace = $runspace
        # 부모 조회도 배경에서 한다. 함수와 작업 본문을 스크립트 하나에 그대로 넣어 지역 범위로 돌린다(실행 공간에 남기지 않는다).
        # 글을 코드로 바꾸는 [scriptblock]::Create는 쓰지 않는다 (AGENTS.md 「코드 규칙」 4번)
        $runner = "param(`$request)`ntry {`nfunction Get-WtTaskHostIds {`n$((Get-Command Get-WtTaskHostIds).Definition)`n}`n" +
            "`$request.HostProcessIds = @(Get-WtTaskHostIds)`n& {`n$($script:worker.ToString())`n} `$request`n} finally { `$Error.Clear() }"
        [void]$ps.AddScript($runner, $true).AddArgument(@{ Action = $Action; Targets = $Targets; SelfProcessId = $PID; Cancel = $cancel })
        $handle = $ps.BeginInvoke()
        $script:job = @{ PowerShell = $ps; Runspace = $runspace; Handle = $handle; Cancel = $cancel; Action = $Action; Started = [datetime]::UtcNow }
        $script:timer.Start()
        Update-WtTaskStatus
    } catch { if ($ps) { $ps.Dispose() }; throw }
}

function Complete-WtTaskJob {
    if (-not $script:job -or -not $script:job.Handle.IsCompleted) { return }
    $job = $script:job; $script:job = $null
    $scanNext = $false
    try {
        $output = @($job.PowerShell.EndInvoke($job.Handle))
        if (-not $output.Count -or $output[-1] -isnot [System.Collections.IDictionary]) { throw ($job.PowerShell.Streams.Error | Select-Object -First 1) }
        $result = $output[-1]
        if ($job.Action -eq 'scan') {
            if (-not $result.Canceled) {
                Set-WtTaskSnapshot @($result.Items)
                $script:lastError = if ($result.FailedWindows) { "창 $($result.FailedWindows)개를 읽지 못했습니다. 해당 프로그램을 확인한 뒤 새로 고침하세요." } else { '' }
                Update-WtTaskList -KeepSelection
            }
        } else {
            $counts = @{}
            foreach ($state in 'closed', 'gone', 'confirmation', 'failed', 'canceled') { $counts[$state] = @($result.Results | Where-Object State -eq $state).Count }
            $script:resultText = '{0:HH:mm:ss} 처리: 닫힘 {1} · 이미 없음 {2} · 확인 필요 {3} · 실패 {4} · 취소 {5}' -f (Get-Date), $counts.closed, $counts.gone, $counts.confirmation, $counts.failed, $counts.canceled
            $script:ui.Result.ToolTip = ($result.Results | ForEach-Object { "$($_.Title): $($_.Message)" }) -join "`n"
            $script:lastError = if ($counts.confirmation -or $counts.failed) { '원래 프로그램에서 저장 확인이나 닫기 결과를 확인하세요. 처리 결과에 마우스를 올리면 항목별 결과가 보입니다.' } else { '' }
            $scanNext = $true
        }
    } catch { $script:lastError = '작업을 완료하지 못했습니다. 다시 시도하세요.'; $script:ui.Status.ToolTip = $_.Exception.Message }
    finally { $job.PowerShell.Dispose() }
    $option = Get-WtTaskRefresh; $script:next = [datetime]::UtcNow.AddMinutes($option.minutes)
    Update-WtTaskStatus
    if ($scanNext) { Start-WtTaskJob 'scan' }
}

function Invoke-WtTaskTick {
    Complete-WtTaskJob
    if (-not $script:ui.Count) { return }
    # 숨겨진 화면에서도 실행 중인 결과는 회수한다. 완료 뒤에는 다음에 보일 때까지 멈춘다.
    if (-not $script:ui.Root.IsVisible -and -not $script:job) { $script:timer.Stop(); return }
    $window = Get-WtWindow
    $visible = $script:ui.Root.IsVisible -and $window -and $window.IsVisible -and $window.WindowState -ne 'Minimized'
    $option = Get-WtTaskRefresh
    if (Test-WtTaskAutoDue $option.mode ([datetime]::UtcNow) $script:next ([bool]$visible) $script:paused ([bool]$script:job)) { Start-WtTaskJob 'scan' }
    if ($script:job -and ([datetime]::UtcNow - $script:job.Started).TotalSeconds -gt 10) { $script:ui.Status.Text = '응답을 기다리는 중입니다. 취소하면 다음 항목부터 중단합니다.' }
}

function Stop-WtTasks {
    if ($script:timer) { $script:timer.Stop(); $script:timer = $null }
    $runspace = $script:workerRunspace; $script:workerRunspace = $null
    if ($script:job) {
        $job = $script:job; $script:job = $null; $job.Cancel.Value = $true
        if ($job.Handle.IsCompleted) { $job.PowerShell.Dispose(); $job.Runspace.Dispose() }
        else { [void]$job.PowerShell.BeginStop($null, $null); $job.Runspace.CloseAsync() }
        $runspace = $null
    }
    if ($runspace) { $runspace.Dispose() }
}

function Update-WtTaskStatus {
    if (-not $script:ui.Count) { return }
    $option = Get-WtTaskRefresh
    $script:ui.Mode.Text = if ($option.mode -eq 'auto') { "자동 · $($option.minutes)분" } else { '수동' }
    $script:ui.Manual.IsChecked = $option.mode -eq 'manual'; $script:ui.Auto.IsChecked = $option.mode -eq 'auto'
    $picked = @($script:items | Where-Object { $_.Selected -and $_.CanClose })
    $script:ui.Close.Content = "선택 닫기 $($picked.Count)"
    $script:ui.Close.IsEnabled = $picked.Count -gt 0 -and -not $script:job
    $script:ui.Refresh.IsEnabled = -not $script:job
    $script:ui.Cancel.IsEnabled = [bool]$script:job
    $script:ui.Status.Text = if ($script:job) { if ($script:job.Cancel.Value) { '취소 요청됨 · 현재 항목의 응답을 기다립니다' } else { '처리 중…' } }
        elseif ($script:lastError) { $script:lastError }
        elseif ($script:lastScan) { '{0}개 선택 · {1}개 표시 · 마지막 수집 {2:HH:mm:ss}' -f $picked.Count, $script:visible.Count, $script:lastScan }
        else { '새로 고침하면 실행 중인 창과 탭을 표시합니다.' }
    $script:ui.Result.Text = $script:resultText
    $script:ui.Result.Visibility = if ($script:resultText) { 'Visible' } else { 'Collapsed' }
    $script:ui.Empty.Text = if ($script:items.Count) { '검색 결과가 없습니다.' } else { '표시할 창이나 탭이 없습니다.' }
    $script:ui.Empty.Visibility = if ($script:visible.Count -or $script:job) { 'Collapsed' } else { 'Visible' }
    foreach ($key in @($script:ui.GroupChecks.Keys)) {
        $check = $script:ui.GroupChecks[$key]
        $groupRows = @($script:visible | Where-Object AppLabel -eq $key)
        $check.IsChecked = Get-WtTaskCheckState $groupRows
        $check.IsEnabled = @($groupRows | Where-Object CanClose).Count -gt 0
    }
}

function Update-WtTaskList([switch]$KeepSelection) {
    if (-not $script:ui.Count) { return }
    if (-not $KeepSelection) { foreach ($row in $script:items) { $row.Selected = $false } }
    $key = ConvertTo-Json -Compress -Depth 4 -InputObject @($script:snapshotVersion, $script:ui.Search.Text, $script:appFilter, $script:sortColumn, $script:sortDirection, @($script:items | Where-Object Selected | ForEach-Object Id))
    if ($script:listKey -ceq $key) { Update-WtTaskStatus; return }
    $scroll = Get-WtVisualChild $script:ui.Grid ([System.Windows.Controls.ScrollViewer])
    $offset = if ($scroll) { $scroll.VerticalOffset } else { 0 }
    $script:visible = @(Find-WtTaskItems $script:items $script:ui.Search.Text $script:appFilter)
    $list = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($row in $script:visible) { $list.Add($row) }
    $view = [System.Windows.Data.ListCollectionView]::new($list)
    $view.GroupDescriptions.Add([System.Windows.Data.PropertyGroupDescription]::new('AppLabel'))
    $view.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('AppLabel', 'Ascending'))
    $view.SortDescriptions.Add([System.ComponentModel.SortDescription]::new($script:sortColumn, $script:sortDirection))
    $script:ui.GroupChecks = @{}
    $script:ui.Grid.ItemsSource = $view
    $script:ui.Grid.UpdateLayout()
    if ($scroll) { $scroll.ScrollToVerticalOffset($offset) }
    Update-WtTaskStatus
    $script:listKey = $key
}

# 표를 다시 만들면 방금 누른 체크박스가 새것으로 바뀐다. 같은 항목 · 같은 그룹의 체크박스로 포커스를 돌려줘
# Space · Tab으로 이어서 고를 수 있게 한다.
function Restore-WtTaskFocus {
    $target = $script:focusTarget; $script:focusTarget = $null
    if (-not $target -or -not $script:ui.Count) { return }
    $check = $null
    if ($target.Group) { $check = $script:ui.GroupChecks[$target.Group] }
    else {
        $item = $script:visible | Where-Object Id -eq $target.Id | Select-Object -First 1
        if ($item) {
            $script:ui.Grid.ScrollIntoView($item)
            $row = Find-WtTaskRow $script:ui.Grid $target.Id
            if ($row) { $check = Get-WtVisualChild $row ([System.Windows.Controls.CheckBox]) }
        }
    }
    if ($check) { [void]$check.Focus() }
}

function Find-WtTaskRow($Root, [string]$Id) {
    if ($Root -is [System.Windows.Controls.DataGridRow]) { if ([string]$Root.Item.Id -eq $Id) { return $Root }; return $null }
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root); $i++) {
        $found = Find-WtTaskRow ([System.Windows.Media.VisualTreeHelper]::GetChild($Root, $i)) $Id
        if ($found) { return $found }
    }
    $null
}

function Show-WtTaskRefreshDialog {
    if ($script:paused) { return }
    $script:paused = $true
    try {
        $option = Get-WtTaskRefresh
        $dialog = New-WtModal '자동 새로 고침'
        [void](Add-WtChild $dialog.Body (New-WtText '새로 고침 간격'))
        $input = New-WtMinuteInput $option.minutes; [void](Add-WtChild $dialog.Body $input.Root)
        [void](Add-WtChild $dialog.Body (New-WtText '1~1,440분 사이의 정수를 입력하세요.' 'T.Sub'))
        [void](Add-WtChild $dialog.Body (New-WtText '활성 작업 탭을 보는 동안 자동으로 갱신합니다.' 'T.Sub'))
        $apply = New-WtButton '적용' -Kind Primary; $apply.IsDefault = $true
        $cancel = New-WtButton '취소'; $cancel.IsCancel = $true
        $dialog.Window.Tag = @{ Box = $input.Box; Error = $dialog.Error }
        $apply.Tag = $dialog.Window
        $apply.Add_Click({
            param($s, $e)
            $w = $s.Tag
            try { Set-WtTaskRefresh 'auto' $w.Tag.Box.Text; $w.DialogResult = $true }
            catch { $w.Tag.Error.Text = $_.Exception.Message; $w.Tag.Error.Visibility = 'Visible'; [void]$w.Tag.Box.Focus() }
        })
        [void](Add-WtChild $dialog.Buttons $apply); [void](Add-WtChild $dialog.Buttons $cancel)
        $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Box.Focus(); $s.Tag.Box.SelectAll() })
        [void]$dialog.Window.ShowDialog()
    } finally { $script:paused = $false }
}

function Close-WtSelectedTasks {
    if ($script:job -or $script:paused) { return }
    $targets = @($script:items | Where-Object { $_.Selected -and $_.CanClose } | ForEach-Object { $_.PSObject.Copy() })
    if (-not $targets.Count) { return }
    $script:paused = $true
    $accepted = $false
    try {
        $dialog = New-WtModal "선택한 $($targets.Count)개 항목을 닫을까요?"
        $summary = '창 {0}개 · 탭 {1}개' -f @($targets | Where-Object Kind -eq 'window').Count, @($targets | Where-Object Kind -eq 'tab').Count
        [void](Add-WtChild $dialog.Body (New-WtText $summary 'T.Sub'))
        $scroll = [System.Windows.Controls.ScrollViewer]::new(); $scroll.MaxHeight = 320; $scroll.VerticalScrollBarVisibility = 'Auto'
        $list = New-WtStack Vertical 8
        foreach ($target in $targets) {
            [void](Add-WtChild $list (New-WtText $target.DisplayTitle))
            [void](Add-WtChild $list (New-WtText "$($target.AppLabel) · $($target.WindowLabel) · $($target.KindLabel)" 'T.Sub'))
        }
        $scroll.Content = $list; [void](Add-WtChild $dialog.Body $scroll)
        [void](Add-WtChild $dialog.Body (New-WtText '저장 확인은 원래 프로그램에서 처리하세요.' 'T.Sub'))
        $close = New-WtButton '닫기' -Kind Danger; $close.Tag = $dialog.Window
        $close.Add_Click({ param($s, $e) $s.Tag.DialogResult = $true })
        $cancel = New-WtButton '취소'; $cancel.IsCancel = $true; $dialog.Window.Tag = $cancel
        [void](Add-WtChild $dialog.Buttons $close); [void](Add-WtChild $dialog.Buttons $cancel)
        $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Focus() })
        $accepted = $dialog.Window.ShowDialog() -eq $true
    } finally { $script:paused = $false }
    if ($accepted) { Start-WtTaskJob 'close' $targets }
}

function New-WtActiveTasksView {
    Stop-WtTasks
    $script:listKey = $null
    $script:ui = @{}
    $page = New-WtTaskPage
    $header = New-WtPageHeader '활성 작업' '' $null
    [System.Windows.Controls.DockPanel]::SetDock($header, 'Top'); [void]$page.Panel.Children.Add($header)
    $tools = [System.Windows.Controls.WrapPanel]::new(); $tools.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $search = New-WtSearchBox '이름으로 찾기'; $search.Root.Width = 280; $search.Root.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    $search.Box.Add_TextChanged({ Update-WtTaskList })
    [void]$tools.Children.Add($search.Root)
    $filter = New-WtButton '모든 프로그램'; $filter.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    $filter.Add_Click({
        param($s, $e)
        $menu = New-WtContextMenu
        $options = @([pscustomobject]@{ AppKey = '*'; AppLabel = '모든 프로그램' }) + @($script:items | Sort-Object AppLabel -Unique)
        foreach ($option in $options) {
            $mi = [System.Windows.Controls.MenuItem]::new(); $mi.Header = $option.AppLabel; $mi.Tag = $option.AppKey
            $mi.IsChecked = $script:appFilter -eq $option.AppKey
            $mi.Add_Click({ param($sender, $event) $script:appFilter = $sender.Tag; $script:ui.Filter.Content = $sender.Header; Update-WtTaskList })
            [void]$menu.Items.Add($mi)
        }
        $s.ContextMenu = $menu; $menu.PlacementTarget = $s; $menu.IsOpen = $true
    })
    [void]$tools.Children.Add($filter)
    $mode = New-WtText '' 'T.Sub'; $mode.VerticalAlignment = 'Center'; $mode.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    [void]$tools.Children.Add($mode)
    $refresh = New-WtButton '새로 고침' -Kind Primary -Icon 0xE72C -ToolTip "새로 고침 (F5)`n우클릭: 수동 / 자동"
    $refresh.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    $refresh.Add_Click({ Start-WtTaskJob 'scan' })
    $menu = New-WtContextMenu
    $manual = [System.Windows.Controls.MenuItem]::new(); $manual.Header = '수동'
    $manual.Add_Click({ try { $option = Get-WtTaskRefresh; Set-WtTaskRefresh 'manual' $option.minutes } catch { Show-WtError $_ '새로 고침 설정' } })
    $auto = [System.Windows.Controls.MenuItem]::new(); $auto.Header = '자동…'; $auto.Add_Click({ Show-WtTaskRefreshDialog })
    [void]$menu.Items.Add($manual); [void]$menu.Items.Add($auto); $refresh.ContextMenu = $menu
    $menu.Add_Opened({ Update-WtTaskStatus })
    [System.Windows.Controls.ContextMenuService]::SetShowOnDisabled($refresh, $true)
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($refresh, $true)
    [void]$tools.Children.Add($refresh)
    $close = New-WtButton '선택 닫기' -Kind Danger; $close.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    $close.Add_Click({ Close-WtSelectedTasks }); [void]$tools.Children.Add($close)
    $cancel = New-WtButton '취소'; $cancel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $cancel.Add_Click({ if ($script:job) { $script:job.Cancel.Value = $true; Update-WtTaskStatus } }); [void]$tools.Children.Add($cancel)
    [System.Windows.Controls.DockPanel]::SetDock($tools, 'Top'); [void]$page.Panel.Children.Add($tools)
    $bottom = New-WtStack Vertical 4; $bottom.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $status = New-WtText '' 'T.Sub'; $result = New-WtText '' 'T.Sub'
    [void](Add-WtChild $bottom $status); [void](Add-WtChild $bottom $result)
    [System.Windows.Controls.DockPanel]::SetDock($bottom, 'Bottom'); [void]$page.Panel.Children.Add($bottom)
    $area = [System.Windows.Controls.Grid]::new()
    $grid = New-WtTaskGrid; [void]$area.Children.Add($grid)
    $empty = New-WtText '' 'T.Sub'; $empty.HorizontalAlignment = 'Center'; $empty.VerticalAlignment = 'Center'; $empty.IsHitTestVisible = $false
    [void]$area.Children.Add($empty); [void]$page.Panel.Children.Add($area)
    $script:ui = @{ Root = $page.Root; Grid = $grid; Empty = $empty; Search = $search.Box; Filter = $filter; Mode = $mode; Refresh = $refresh; Manual = $manual; Auto = $auto; Close = $close; Cancel = $cancel; Status = $status; Result = $result; GroupChecks = @{} }
    $grid.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $check = $e.OriginalSource
        if ($check -isnot [System.Windows.Controls.CheckBox]) { return }
        if ($check.Tag -eq 'group') {
            foreach ($row in @($check.DataContext.Items)) { if ($row.CanClose) { $row.Selected = $check.IsChecked -eq $true } }
            $script:focusTarget = @{ Group = [string]$check.DataContext.Name }
        } elseif ($check.Tag -eq 'task') {
            $check.DataContext.Selected = $check.IsChecked -eq $true
            $script:focusTarget = @{ Id = [string]$check.DataContext.Id }
        }
        else { return }
        Update-WtTaskList -KeepSelection
        # 그룹 체크박스는 그룹 머리글이 다시 만들어진 뒤(Loaded) 등록되므로 그보다 늦은 순서로 돌려준다
        [void]$s.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ Restore-WtTaskFocus })
    })
    # Loaded는 자식에서 버블링하지 않으므로 GroupItem 스타일에서 직접 받는다.
    $groupStyle = [System.Windows.Style]::new([System.Windows.Controls.GroupItem], $grid.GroupStyle[0].ContainerStyle)
    $groupStyle.Setters.Add([System.Windows.EventSetter]::new([System.Windows.FrameworkElement]::LoadedEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $check = Get-WtVisualChild $s ([System.Windows.Controls.CheckBox])
        if ($check -and $check.Tag -eq 'group') {
            $script:ui.GroupChecks[$check.DataContext.Name] = $check; Update-WtTaskStatus
        }
        $element = Get-WtVisualChild $s ([System.Windows.Controls.Expander])
        if ($element -and $element.Tag -eq 'task-group') {
            if ($script:expanded.ContainsKey($element.DataContext.Name)) { $element.IsExpanded = $script:expanded[$element.DataContext.Name] }
        }
    }))
    $grid.GroupStyle[0].ContainerStyle = $groupStyle
    $groupHandler = [System.Windows.RoutedEventHandler]{ param($s, $e) if ($e.OriginalSource -is [System.Windows.Controls.Expander] -and $e.OriginalSource.IsLoaded) { $script:expanded[$e.OriginalSource.DataContext.Name] = $e.OriginalSource.IsExpanded } }
    $grid.AddHandler([System.Windows.Controls.Expander]::ExpandedEvent, $groupHandler)
    $grid.AddHandler([System.Windows.Controls.Expander]::CollapsedEvent, $groupHandler)
    $grid.Add_Sorting({
        param($s, $e)
        $e.Handled = $true
        if ($script:sortColumn -eq $e.Column.SortMemberPath) { $script:sortDirection = if ($script:sortDirection -eq 'Ascending') { 'Descending' } else { 'Ascending' } }
        else { $script:sortColumn = $e.Column.SortMemberPath; $script:sortDirection = 'Ascending' }
        foreach ($column in $s.Columns) { $column.SortDirection = $null }
        $e.Column.SortDirection = $script:sortDirection
        Update-WtTaskList -KeepSelection
    })
    $page.Root.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'F5') { Start-WtTaskJob 'scan'; $e.Handled = $true }
        if ($e.Key -eq 'F' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { [void]$script:ui.Search.Focus(); $e.Handled = $true }
    })
    $script:timer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:timer.Interval = [timespan]::FromMilliseconds(250); $script:timer.Add_Tick({ Invoke-WtTaskTick })
    $page.Root.Add_Loaded({ if ($script:timer) { $script:timer.Start() } })
    $page.Root.Add_Unloaded({ if ($script:timer -and -not $script:job) { $script:timer.Stop() } })
    $page.Root.Add_IsVisibleChanged({
        param($s, $e)
        if (-not $script:timer) { return }
        if ($s.IsVisible -or $script:job) { $script:timer.Start() } else { $script:timer.Stop() }
    })
    Update-WtTaskList -KeepSelection
    $page.Root
}

Register-WtAddon -Id 'active-tasks' -Title '활성 작업' -Icon 0xE7C4 -Order 60 `
    -NewView { New-WtActiveTasksView } -Refresh { param($view) Start-WtTaskJob 'scan' } -OnExit { Stop-WtTasks } `
    -Help @(
        '활성 작업은 열린 창과 Chrome·Edge·웨일 탭을 모아 보고 선택한 항목을 닫습니다. 새로 고침 버튼을 우클릭하면 수동·자동을 고를 수 있고, 자동은 분 단위 간격을 설정합니다.'
        '자동 갱신은 활성 작업 탭을 보는 동안만 동작합니다. 읽기 제한 항목은 원래 프로그램에서 확인하세요. 닫을 때 저장 확인도 원래 프로그램에서 처리합니다.') `
    -Shortcuts @(@('F5', '새로 고침'), @('Ctrl + F', '이름으로 거르기'), @('Shift + F10', '새로 고침 버튼의 수동/자동 메뉴'))

Export-ModuleMember -Function ConvertTo-WtTaskMinutes, Get-WtTaskRefresh, Set-WtTaskRefresh, Test-WtTaskAutoDue,
    Find-WtTaskItems, Get-WtTaskCheckState, Get-WtTaskWorker, Get-WtTaskHostIds

# 셸: 메인 창 틀, 왼쪽 메뉴, 제목 줄 버튼, 트레이, 단축키, 화면 전환.
# 메뉴는 Addons.psm1에 등록된 애드온 목록으로 만든다. 탭을 더하거나 빼도 이 파일은 고치지 않는다.
#
# 창은 WindowStyle=None으로 만들고 제목 줄은 직접 그린다. 투명도를 100%보다 낮게 고르면 투명 창(AllowsTransparency)으로 띄운다.
# 그래서 이 창 안에는 WindowsFormsHost · WebBrowser를 넣지 않는다 (투명 창에서는 그려지지 않는다).
# 투명 창은 ClearType을 못 쓰고 회색조로 글자를 그려서, 100%면 보통 창으로 띄운다 (Start-WtApp). 글자는 Ideal 모드로 그린다.
#
# 이벤트 처리기는 나중에 디스패처가 부르므로, 만든 함수의 지역 변수를 볼 수 없다.
# 처리기 안에서는 $script: 변수와 $s(보낸 요소)의 Tag만 쓴다.

$ErrorActionPreference = 'Stop'

$script:window = $null
$script:ui = $null
$script:frame = $null
$script:themeDict = $null
$script:notify = $null
$script:views = @{}
$script:utilityWindows = @{}
$script:navButtons = @{}
$script:navGroups = @()
$script:badgeTimer = $null
$script:sidePanels = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()
$script:current = $null
$script:selecting = $false
$script:settingHandlerRegistered = $false
$script:exiting = $false
$script:trayTipShown = $false
$script:maxed = $false
$script:fullscreen = $false
$script:restoreBounds = $null
$script:fullFromMax = $false   # 최대화 상태에서 전체 화면으로 갔는지
$script:settingBounds = $false # 코드로 창 위치 · 크기를 바꾸는 중
$script:icon = $null
$script:lastImport = $null
$script:warmQueue = $null      # 켠 뒤 미리 만들 화면 ID (Start-WtWarmUp)
$script:warmTimer = $null
$script:warmEnabled = $false  # WORKTOOL_WARMUP=1인 진단 세션에서만 켠다
$script:warmStarted = $false  # ContentRendered가 다시 와도 세션당 한 번만 예약
$script:forceOpaque = $false  # WORKTOOL_FORCE_OPAQUE=1: 설정을 저장하지 않는 불투명 창
$script:writingDropped = $false   # 끝낼 때 사용자가 「저장을 기다리지 않고 끝내기」를 골랐는지
$script:exitAsking = $false       # 끝내기 전에 묻는 중(그사이 트레이 종료 등이 또 와도 겹쳐 묻지 않게)
$script:forwardingKey = $false    # 화면 밖 포커스의 키를 화면에 다시 올리는 중(Invoke-WtPageKey)
$script:instance = $null          # 한 번만 뜨기: 진입 스크립트가 넘긴 신호 손잡이 @{ Show; Capture; Ready; Info } (Start-WorkTool.ps1 Enter-WtInstance)
$script:instanceTimer = $null     # 그 신호를 보는 화면 스레드 타이머
$script:frontTimer = $null        # 앞으로 못 가져왔을 때 잠깐 맨 위로 둔 것을 푸는 타이머
$script:captureStale = $false     # 빠른 적기 뒤 앱 창을 다시 보면 지금 화면을 한 번 새로 그린다
$script:entryPath = ''            # 바로 가기 대상에 쓸 진입 파일(Start-WorkTool.ps1 · WorkTool-WPF.ps1)

$script:shellXaml = Get-WtShellXaml

function Get-WtWindow { $script:window }

# ---- 화면 전환 --------------------------------------------------------------------------------

# 스크립트 블록의 출력 중 화면 요소만 고른다 (실수로 섞여 나온 숫자 등은 버린다)
function Get-WtElements($Output) {
    @($Output | Where-Object { $_ -is [System.Windows.UIElement] })
}

function Get-WtPageView([string]$Id) {
    if ($Id -in '_settings', '_help') {
        # 등록 객체도 비교하므로 같은 ID의 탭을 다시 등록한 경우까지 반영한다.
        $registrations = @(foreach ($a in @(Get-WtAddon -All)) {
            [ordered]@{ Identity = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($a); Id = $a.Id; Title = $a.Title
                Description = $a.Description; Required = $a.Required; Order = $a.Order; Help = $a.Help; Shortcuts = $a.Shortcuts }
        })
        $settings = @(foreach ($name in 'theme.color','ui.opacity','ui.fontScale','window.closeToTray','addons.disabled','legacy.path') {
            [ordered]@{ Key = $name; Value = (Get-WtSetting $name) }
        })
        $key = ConvertTo-Json -Compress -Depth 8 -InputObject @(
            (Get-WtDataRoot), $settings, $registrations, (Find-WtLegacyFolder), (Get-WtLastImport))
        if (-not $script:views.ContainsKey($Id) -or $script:views[$Id].Key -cne $key) {
            $view = if ($Id -eq '_settings') { New-WtSettingsPage } else { New-WtHelpPage }
            $script:views[$Id] = @{ View = $view; Addon = $null; Key = $key }
        }
        return $script:views[$Id]
    }
    # 화면을 만든 뒤 숨긴 탭도 열지 않는다. 다시 켜면 같은 화면을 재사용해 편집 상태를 유지한다.
    $a = Get-WtAddon -Id $Id
    if (-not $a) { return $null }
    if (-not $script:views.ContainsKey($Id)) {
        $view = Get-WtElements (& $a.NewView) | Select-Object -Last 1
        if (-not $view) { throw "애드온 '$Id'가 화면을 돌려주지 않았습니다." }
        $script:views[$Id] = @{ View = $view; Addon = $a }
    }
    $script:views[$Id]
}

function Select-WtPage([string]$Id, [string]$Tab = '', [switch]$Refresh) {
    if ($Id -in '_settings', '_help') { Show-WtUtilityPage $Id $Tab -Refresh:$Refresh; return }
    [void](Invoke-WtPageSelection $Id)
}

# 보이기와 앞으로 가져오기는 한 통로로 한다. 창 없는 검사에서는 이 통로만 대신한다.
function Show-WtUtilityHost($Window) {
    if (-not $Window.IsVisible) { $Window.Show() }
    if ($Window.WindowState -eq 'Minimized') { $Window.WindowState = 'Normal' }
    [void]$Window.Activate()
}

function Show-WtUtilityPage([ValidateSet('_settings','_help')][string]$Id, [string]$Tab = '', [switch]$Refresh) {
    if (-not $Tab -and $script:utilityWindows.ContainsKey($Id)) {
        $tabs = $script:utilityWindows[$Id].Body.Child.Tag.Tabs
        if ($tabs -and $tabs.SelectedItem) { $Tab = [string]$tabs.SelectedItem.Header }
    }
    # 열린 창의 입력·고른 탭은 다시 열기만으로 버리지 않는다. 데이터 위치를 바꾼 경우만 명시적으로 다시 읽는다.
    $page = if ($script:utilityWindows.ContainsKey($Id) -and -not $Refresh) { @{ View = $script:utilityWindows[$Id].Body.Child } } else { Get-WtPageView $Id }
    if (-not $script:utilityWindows.ContainsKey($Id)) {
        $title = if ($Id -eq '_settings') { 'WorkTool · 설정' } else { 'WorkTool · 도움말' }
        $hostWindow = New-WtUtilityWindow $title
        $win = $hostWindow.Window
        $hostWindow.Body.Child = $page.View
        $win.Tag = @{ Id = $Id; Host = $hostWindow; BoundsKey = "window.$($Id.TrimStart('_')).bounds" }
        $savedBounds = Get-WtSetting $win.Tag.BoundsKey
        try {
            if ($savedBounds -and [double]::IsFinite([double]$savedBounds.Left) -and [double]::IsFinite([double]$savedBounds.Top) -and
                [double]::IsFinite([double]$savedBounds.Width) -and [double]::IsFinite([double]$savedBounds.Height) -and
                $savedBounds.Width -ge $win.MinWidth -and $savedBounds.Height -ge $win.MinHeight) {
                $win.WindowStartupLocation = 'Manual'
                $win.Left = $savedBounds.Left; $win.Top = $savedBounds.Top
                $win.Width = $savedBounds.Width; $win.Height = $savedBounds.Height
            }
        } catch { } # 잘못된 옛 위치는 첫 크기·가운데 배치로 연다.
        $win.Add_Closing({
            param($s, $e)
            if (-not $script:exiting -and -not (Save-WtPendingChanges -Purpose switch -Only $s.Tag.Id)) { $e.Cancel = $true; return }
            $bounds = if ($s.WindowState -eq 'Normal') { [System.Windows.Rect]::new($s.Left, $s.Top, $s.Width, $s.Height) } else { $s.RestoreBounds }
            if (-not $bounds.IsEmpty -and [double]::IsFinite($bounds.Left) -and [double]::IsFinite($bounds.Top)) {
                Set-WtSetting $s.Tag.BoundsKey @{ Left = $bounds.Left; Top = $bounds.Top; Width = $bounds.Width; Height = $bounds.Height }
            }
        })
        $win.Add_Closed({ param($s, $e) $s.Tag.Host.Body.Child = $null; [void]$script:utilityWindows.Remove($s.Tag.Id) })
        $win.Add_KeyDown({ param($s, $e) Invoke-WtUtilityKey $s $e })
        $script:utilityWindows[$Id] = $hostWindow
    } else {
        $hostWindow = $script:utilityWindows[$Id]
        $hostWindow.Body.Child = $page.View
    }
    if ($Tab) { Select-WtPageTab $page.View $Tab }
    Show-WtUtilityHost $hostWindow.Window
}

function Invoke-WtUtilityKey($Window, $Event, $Modifiers = [System.Windows.Input.Keyboard]::Modifiers) {
    if ($Event.Handled) { return }
    if ($Event.Key -eq 'F1') { Select-WtPage '_help'; $Event.Handled = $true; return }
    if (($Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -and $Event.Key -eq 'OemComma') {
        Select-WtPage '_settings'; $Event.Handled = $true; return
    }
    if ($Event.Key -ne 'Escape') { return }
    if (-not (Close-WtOpenTransient $Window)) { $Window.Close() }
    $Event.Handled = $true
}

function Close-WtUtilityWindows {
    foreach ($hostWindow in @($script:utilityWindows.Values)) { $hostWindow.Window.Close() }
    $script:utilityWindows.Count -eq 0
}

# 지금 화면이 떠 있는데 키보드 포커스가 화면 밖(왼쪽 메뉴 · 제목 줄 단추 · 창 자체)에 있으면, 셸이 처리하지 않은 키를
# 그 탭에 넘긴다. 화면 안에 포커스가 있으면 화면이 직접 받으므로 넘기지 않는다. 처리했으면 $true
# - PageKey를 등록한 탭은 그 등록이 받는다.
# - 등록하지 않은 탭은 화면 맨 위 요소(NewView가 돌려준 것)에 같은 키를 PreviewKeyDown으로 다시 올린다. 화면 안에 포커스가 있을 때
#   받던 처리기가 그대로 받는다(탭을 옮긴 직후 Ctrl+F · F5가 목록을 한 번 눌러야 먹던 것, 11-24 실사용)
function Invoke-WtPageKey([System.Windows.Input.Key]$Key, [System.Windows.Input.ModifierKeys]$Modifiers) {
    if (-not $script:current -or -not $script:ui) { return $false }
    $view = $script:ui.PageHost.Content
    if (-not $view -or $view.IsKeyboardFocusWithin) { return $false }
    $addon = Get-WtAddon -Id $script:current
    if (-not $addon) { return $false }
    if ($addon.PageKey) { return @(& $addon.PageKey $Key $Modifiers)[-1] -eq $true }
    if ($view -isnot [System.Windows.UIElement]) { return $false }
    $source = [System.Windows.PresentationSource]::FromVisual($view)
    if (-not $source) { return $false }
    $forward = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $source, [Environment]::TickCount, $Key)
    $forward.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
    # 다시 올린 키도 창을 지나 내려가므로, 그동안 창의 키 처리(Invoke-WtShellKey)는 건너뛴다
    $script:forwardingKey = $true
    try { $view.RaiseEvent($forward) } finally { $script:forwardingKey = $false }
    $forward.Handled
}

# 앱 창의 단축키(창의 PreviewKeyDown). 셸 단축키를 먼저 보고, 처리하지 않은 키는 지금 화면에 넘긴다(Invoke-WtPageKey)
function Invoke-WtShellKey($KeyArgs) {
    if ($script:forwardingKey) { return }
    if (Invoke-WtWorkSetupKey $KeyArgs) { return }
    $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $key = if ($KeyArgs.Key -eq 'System') { $KeyArgs.SystemKey } else { $KeyArgs.Key }
    $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    if ($ctrl -and $shift -and $key -eq 'B') { Switch-WtPanelCycle; $KeyArgs.Handled = $true; return }
    if ($key -eq 'F11') { Switch-WtFullScreen; $KeyArgs.Handled = $true; return }
    if ($key -eq 'Escape' -and $script:fullscreen) { Switch-WtFullScreen; $KeyArgs.Handled = $true; return }
    if ($key -eq 'F1') { Select-WtPage '_help'; $KeyArgs.Handled = $true; return }
    if ($ctrl -and $key -eq 'OemComma') { Select-WtPage '_settings'; $KeyArgs.Handled = $true; return }
    if ($ctrl -and [int]$key -ge [int][System.Windows.Input.Key]::D1 -and [int]$key -le [int][System.Windows.Input.Key]::D9) {
        $ids = @(Get-WtAddon | ForEach-Object { $_.Id })
        $idx = [int]$key - [int][System.Windows.Input.Key]::D1
        if ($idx -lt $ids.Count) { Select-WtPage $ids[$idx] }
        $KeyArgs.Handled = $true
        return
    }
    if (Invoke-WtPageKey $key ([System.Windows.Input.Keyboard]::Modifiers)) { $KeyArgs.Handled = $true }
}

# 공개된 Select-WtPage의 출력은 그대로 두고, 항목 열기는 전환 성공 여부까지 확인한다.
# -NoSave: 떠나는 화면의 저장 확인을 건너뛴다(끝낼 때 물을 탭 화면을 보일 때. 그 저장은 바로 뒤 끝내기 저장 단계가 맡는다)
function Invoke-WtPageSelection([string]$Id, [switch]$NoSave) {
    if ($script:selecting -or -not $Id) { return $false }
    $script:selecting = $true
    try {
        # 떠나는 화면에 저장하지 못한 내용이 있으면 묻는다 (다른 화면의 저장 상태는 그 화면을 떠날 때 묻는다)
        if (-not $NoSave -and $script:current -and $Id -ne $script:current -and -not (Save-WtPendingChanges -Purpose switch -Only $script:current)) { return $false }
        $page = Get-WtPageView $Id
        if (-not $page) { return $false }
        if ($page.Addon -and $page.Addon.Refresh) { [void](& $page.Addon.Refresh $page.View) }
        $script:ui.PageHost.Content = $page.View
        $script:current = $Id
        Update-WtCurrentSidePanels
        Update-WtNavBadges
        return $true
    } catch {
        foreach ($k in @($script:navButtons.Keys)) { $script:navButtons[$k].Button.IsChecked = ($k -eq $script:current) }
        Show-WtError $_ "화면 열기: $Id"
        return $false
    } finally {
        foreach ($k in @($script:navButtons.Keys)) { $script:navButtons[$k].Button.IsChecked = ($k -eq $script:current) }
        $script:selecting = $false
    }
}

# 데이터를 다시 가져온 뒤 현재 화면을 갱신한다. 숨긴 화면도 재진입할 때 갱신한다.
function Open-WtPage {
    param([Parameter(Mandatory)][string]$Id, [hashtable]$Args = @{})
    if ($Id -in '_settings','_help') { Show-WtUtilityPage $Id ([string]$Args.Tab); return }
    $addon = Get-WtAddon -Id $Id
    if (-not $addon -or $addon.Id -cne $Id) { return }
    $selected = Invoke-WtPageSelection $Id
    if ($selected -and $script:current -ceq $Id -and $addon.OnOpen) {
        try { [void](& $addon.OnOpen $Args) } catch { Write-Warning "항목 열기: $($_.Exception.Message)" }
    }
}

function Reset-WtViews {
    if (-not (Save-WtPendingChanges)) { return }
    if ($script:current) {
        $id = $script:current
        $script:current = $null
        Select-WtPage $id
    }
}

function Initialize-WtMainPage {
    $first = @(Get-WtAddon) | Select-Object -First 1
    if ($first) { Select-WtPage $first.Id; return $first.Id }
    $script:current = $null
    $script:ui.PageHost.Content = New-WtText '켜진 탭이 없습니다.'
    # 첫 업무시간 입력을 마치면 Close-WtFirstWorkSetup이 설정 창을 연다.
    if (-not (Test-WtWorkSetupRequired)) { Select-WtPage '_settings' }
    '_settings'
}

# ---- 미리 만들기 ------------------------------------------------------------------------------

# 켠 뒤 한가할 때 아직 안 연 화면을 하나씩 미리 만들어 둔다. 처음 누를 때도 다시 누를 때처럼 빨리 뜨게 하려는 것이다.
# 탭은 등록할 때 WarmUp을 준 것만(Addons.psm1 참고), 그다음 설정 · 도움말 차례다.
# 화면 하나를 만드는 동안은 화면 스레드를 쓰므로, 하나 끝날 때마다 쉬어서 그사이 들어온 입력을 먼저 처리한다
function Start-WtWarmUp {
    if (-not $script:warmEnabled -or $script:warmStarted -or $script:exiting) { return }
    $script:warmStarted = $true
    $ids = @(Get-WtAddon | Where-Object { $_.WarmUp } | ForEach-Object { $_.Id }) + @('_settings', '_help')
    $script:warmQueue = [System.Collections.Generic.Queue[string]]::new([string[]]$ids)
    if (-not $script:warmTimer) {
        $script:warmTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $script:warmTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:warmTimer.Add_Tick({
            if ($script:exiting) { $script:warmTimer.Stop(); return }
            # ApplicationIdle도 실행을 시작하면 UI를 점유한다. 사용 중이거나 숨긴 창에서는 만들지 않는다.
            if (-not (Test-WtCanWarmUp)) { return }
            if (-not (Invoke-WtWarmUpStep)) { $script:warmTimer.Stop() }
        })
    }
    $script:warmTimer.Start()
}

function Test-WtCanWarmUp {
    $w = $script:window
    $script:warmEnabled -and -not $script:exiting -and $w -and
        -not [System.Windows.Interop.ComponentDispatcher]::IsThreadModal -and
        $w.IsVisible -and $w.IsEnabled -and -not $w.IsActive -and
        $w.WindowState -ne [System.Windows.WindowState]::Minimized -and -not $script:selecting
}

# 미리 만들기 한 단계. 아직 남은 것이 있으면 $true
function Invoke-WtWarmUpStep {
    if ($script:exiting -or -not $script:warmEnabled) { return $false }
    while ($script:warmQueue -and $script:warmQueue.Count) {
        $id = $script:warmQueue.Dequeue()
        if ($id -eq $script:current -or $script:utilityWindows.ContainsKey($id) -or ($id -notlike '_*' -and $script:views.ContainsKey($id))) { continue }   # 이미 열었다
        try {
            $page = Get-WtPageView $id
            if (-not $page) { continue }
            if ($page.Addon -and $page.Addon.WarmUp -eq 'Full' -and $page.Addon.Refresh) { [void](& $page.Addon.Refresh $page.View) }
            # 안 보이는 자리에 잠깐 붙여 틀 적용 · 글자 배치까지 해 두고, 바로 떼어 실제 자리로 옮길 수 있게 한다
            $script:ui.WarmHost.Content = $page.View
            $script:ui.WarmHost.UpdateLayout()
        } catch {
            # 미리 만들기는 덤이다. 실패하면 그 화면을 열 때 원래대로 만들고, 오류도 그때 알린다
            if ($id -ne $script:current) { [void]$script:views.Remove($id) }
        } finally { $script:ui.WarmHost.Content = $null }
        return [bool]$script:warmQueue.Count
    }
    $false
}

# ---- 왼쪽 메뉴 --------------------------------------------------------------------------------

# Order 순으로 만난 묶음을 한 번씩 그린다. 묶음 이름과 탭 목록은 등록 객체에만 있다.
function Get-WtNavGroups {
    $groups = [System.Collections.Generic.List[object]]::new()
    foreach ($addon in @(Get-WtAddon)) {
        $group = $groups | Where-Object { $_.Name -eq $addon.Group } | Select-Object -First 1
        if (-not $group) {
            $group = [pscustomobject]@{ Name = $addon.Group; Items = [System.Collections.Generic.List[object]]::new() }
            $groups.Add($group)
        }
        $group.Items.Add($addon)
    }
    $groups.ToArray()
}

function Update-WtNav {
    $panel = $script:ui.NavPanel
    $panel.Children.Clear()
    $script:navButtons = @{}
    $script:navGroups = @()
    foreach ($group in @(Get-WtNavGroups)) {
        if ($panel.Children.Count) {
            $line = New-WtNavSeparator
            [void]$panel.Children.Add($line)
            $script:navGroups += $line
        }
        foreach ($addon in $group.Items) {
            $rb = [System.Windows.Controls.RadioButton]::new()
            Set-WtStyle $rb 'Nav'
            $rb.GroupName = 'WtNav'
            $rb.Tag = $addon.Id
            Set-WtNavToolTip $rb $addon.Title
            [System.Windows.Automation.AutomationProperties]::SetName($rb, $addon.Title)
            $row = (Get-WtStyleDictionary)['Shell.NavItem'].LoadContent()
            $parts = @{ Button = $rb; Addon = $addon; Value = $null; Icon = $row.FindName('Icon'); IconDot = $row.FindName('IconDot') }
            $parts.Icon.Text = [string][char]$addon.Icon
            $rb.Content = $row
            $rb.IsChecked = ($addon.Id -eq $script:current)
            $rb.Add_Checked({ param($s, $e) Select-WtPage ([string]$s.Tag) })
            [void]$panel.Children.Add($rb)
            $script:navButtons[$addon.Id] = $parts
        }
    }
    Update-WtNavBadges
}

# 한 출처가 실패해도 다른 배지·상태 항목은 계속 계산한다.
function Update-WtNavBadges {
    Invoke-WtReadAction {
        foreach ($item in $script:navButtons.Values) {
            if (-not $item.Addon -or -not $item.IconDot) { continue }
            $value = $null
            $state = ''
            if ($item.Addon.Badge) {
                try {
                    $result = & $item.Addon.Badge
                    if ($result -is [string] -and $result -ceq 'dot') { $value = 'dot' }
                    elseif ($null -ne $result -and [Type]::GetTypeCode($result.GetType()) -in @('Byte','SByte','Int16','UInt16','Int32','UInt32','Int64','UInt64','Single','Double','Decimal')) {
                        $value = $result.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    if ($value -eq 'dot' -or ($null -ne $value -and [double]$value -gt 0)) {
                        $state = $item.Addon.BadgeToolTip -f $value
                    }
                } catch { $value = $null; $state = '' }
            }
            $item.Value = $value
            Set-WtNavToolTip $item.Button $(if ($state) { "$($item.Addon.Title) · $state" } else { $item.Addon.Title })
            # 화면 읽기 이름은 탭 이름 그대로 두고(매크로 · 보조 기술이 늘 같은 이름으로 찾게), 상태는 도움말 글로 준다
            [System.Windows.Automation.AutomationProperties]::SetName($item.Button, [string]$item.Addon.Title)
            [System.Windows.Automation.AutomationProperties]::SetHelpText($item.Button, [string]$state)
            $dot = ($item.Addon.BadgeKind -eq 'dot' -and $value -eq 'dot') -or
                ($item.Addon.BadgeKind -eq 'active' -and $null -ne $value -and $value -ne 'dot' -and [double]$value -ge 1)
            Set-WtNavBadge $item $dot
        }
        Update-WtStatusBar
    }
}

function Update-WtStatusBar {
    Invoke-WtReadAction {
        if (-not $script:ui -or -not $script:ui.StatusLeft) { return }
        $script:ui.StatusLeft.Children.Clear()
        $script:ui.StatusLeft.ColumnDefinitions.Clear()
        $script:ui.StatusRight.Children.Clear()
        foreach ($addon in @(Get-WtAddon)) {
            if (-not $addon.StatusItems) { continue }
            try { $items = @(& $addon.StatusItems) } catch { continue }
            $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($item in $items) {
                try {
                    if (-not $item.Key -or $item.Key -cnotmatch '^[a-z0-9-]+$' -or -not $item.Text -or $item.Side -cnotin 'left','right' -or
                        -not $item.Open -or $item.Open.Id -cne $addon.Id -or ($null -ne $item.Open.Args -and $item.Open.Args -isnot [hashtable]) -or
                        -not $keys.Add([string]$item.Key)) { continue }
                    $button = New-WtStatusButton ([string]$item.Text) -Icon ([int]$item.Icon)
                    $button.ToolTip = if ($item.ToolTip) { [string]$item.ToolTip } else { [string]$item.Text }
                    $button.Tag = @{ Id = $addon.Id; Args = $(if ($item.Open.Args) { $item.Open.Args } else { @{} }) }
                    [System.Windows.Automation.AutomationProperties]::SetAutomationId($button, "Status-$($addon.Id)-$($item.Key)")
                    [System.Windows.Automation.AutomationProperties]::SetName($button, [string]$item.Text)
                    $button.Add_Click({ param($s, $e) Open-WtPage -Id $s.Tag.Id -Args $s.Tag.Args })
                    if ($item.Side -ceq 'right') { [void]$script:ui.StatusRight.Children.Add($button) }
                    else {
                        $column = [System.Windows.Controls.ColumnDefinition]::new()
                        $column.Width = [System.Windows.GridLength]::Auto
                        [System.Windows.Controls.Grid]::SetColumn($button, $script:ui.StatusLeft.Children.Count)
                        $script:ui.StatusLeft.ColumnDefinitions.Add($column)
                        [void]$script:ui.StatusLeft.Children.Add($button)
                    }
                } catch { continue }
            }
        }
        # 알람을 잠시 끈 동안: 오른쪽 맨 앞(오른쪽 줄은 오른쪽부터 쌓이므로 마지막에 넣는다)에 코어 항목. 누르면 바로 다시 켠다
        $pause = try { Get-WtNoticePause } catch { $null }
        if ($pause -and $pause.Paused) {
            $button = New-WtStatusButton $pause.Text -Icon 0xE708
            $button.ToolTip = '누르면 알람을 다시 켭니다.'
            [System.Windows.Automation.AutomationProperties]::SetAutomationId($button, 'Status-core-pause')
            [System.Windows.Automation.AutomationProperties]::SetName($button, $pause.Text)
            $button.Add_Click({ param($s, $e) [void](Set-WtNoticePause off) })
            [void]$script:ui.StatusRight.Children.Add($button)
        }
        Set-WtStatusLayout $script:ui.StatusLeft
    }
}
function Start-WtNavBadgeTimer {
    if ($script:badgeTimer) { $script:badgeTimer.Stop() }
    $script:badgeTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:badgeTimer.Interval = [TimeSpan]::FromMinutes(1)
    $script:badgeTimer.Add_Tick({ Update-WtNavBadges })
    $script:badgeTimer.Start()
}

# ---- 보조 칸 공용 틀 --------------------------------------------------------------------------
# Content는 보조 내용만. 반환 Grid는 부모의 Auto 열에 둔다. Key는 탭별 설정 키이며 Width는 2판에 있는 폭만 받는다.
# 여러 보조 칸이면 첫 번째만 창 단축키가 맡는다. 따로 접는 칸은 -Independent로 만든다.
function New-WtSidePanel {
    param(
        [Parameter(Mandatory)][System.Windows.UIElement]$Content,
        [ValidateSet('Right','Left')][string]$Side = 'Right',
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter(Mandatory)][string]$Title,
        [ValidateSet(220,280,288)][int]$Width = 288,
        [switch]$Independent
    )
    Register-WtSettingDefault $Key $false
    $root = (Get-WtStyleDictionary)['Shell.SidePanel'].LoadContent()
    $panel = @{ Root = $root; Side = $Side; Key = $Key; Width = $Width; Independent = [bool]$Independent; Narrow = $null; NarrowOpen = $false; Collapsed = $false; Cycle = '' }
    foreach ($name in 'Expanded','Rail','Header','Collapse','CollapseGlyph','Open','OpenGlyph','Title','Content') { $panel[$name] = $root.FindName($name) }
    $panel.Content.Content = $Content
    $panel.Title.Text = $Title
    $panel.Collapse.ToolTip = "$Title 접기"
    $panel.Open.ToolTip = "$Title 펼치기"
    [System.Windows.Automation.AutomationProperties]::SetName($panel.Collapse, "$Title 접기")
    [System.Windows.Automation.AutomationProperties]::SetName($panel.Open, "$Title 펼치기")
    $panel.Collapse.Tag = $panel; $panel.Open.Tag = $panel
    $panel.Collapse.Add_Click({ param($s, $e) $s.Tag.Cycle = ''; Set-WtSidePanelCollapsed $s.Tag $true })
    $panel.Open.Add_Click({ param($s, $e) $s.Tag.Cycle = ''; Set-WtSidePanelCollapsed $s.Tag $false })
    $script:sidePanels.Add($root, $panel)
    $root.Add_Loaded({ param($s, $e) $p = $null; if ($script:sidePanels.TryGetValue($s, [ref]$p)) { Update-WtSidePanel $p } })
    Update-WtSidePanel $panel
    $root
}

function Update-WtSidePanel($Panel) {
    $width = if ($script:window) { if ($script:window.ActualWidth -gt 0) { $script:window.ActualWidth } else { $script:window.Width } } else { (Get-WtStyleDictionary)['F.SidePanel.Breakpoint'] }
    $narrow = $Panel.Side -eq 'Right' -and $width -lt (Get-WtStyleDictionary)['F.SidePanel.Breakpoint']
    if ($Panel.Narrow -ne $narrow) { $Panel.NarrowOpen = $false }
    $Panel.Narrow = $narrow
    $Panel.Collapsed = if ($narrow) { -not $Panel.NarrowOpen } else { [bool](Get-WtSetting $Panel.Key) }
    Set-WtSidePanelLayout $Panel $Panel.Collapsed $narrow
}

function Set-WtSidePanelCollapsed($Panel, [bool]$Collapsed) {
    if ($Panel.Narrow) { $Panel.NarrowOpen = -not $Collapsed }
    Set-WtSetting $Panel.Key $Collapsed
    Update-WtSidePanel $Panel
}

# 현재 화면 아래만 찾으므로 다른 탭의 보조 칸을 접지 않는다. 약한 참조여서 버린 화면도 붙잡지 않는다.
function Get-WtSidePanels($Root) {
    if ($null -eq $Root -or $Root -isnot [System.Windows.DependencyObject]) { return }
    $panel = $null
    if ($script:sidePanels.TryGetValue($Root, [ref]$panel)) { $panel; return }
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Root)) {
        if ($child -is [System.Windows.DependencyObject]) { Get-WtSidePanels $child }
    }
}

function Update-WtCurrentSidePanels {
    if ($script:ui -and $script:ui.PageHost) {
        foreach ($panel in @(Get-WtSidePanels $script:ui.PageHost.Content)) { Update-WtSidePanel $panel }
    }
}

function Switch-WtPanelCycle {
    $panel = @(Get-WtSidePanels $script:ui.PageHost.Content | Where-Object { -not $_.Independent }) | Select-Object -First 1
    if (-not $panel) { return }
    Update-WtSidePanel $panel
    Set-WtSidePanelCollapsed $panel (-not $panel.Collapsed)
}
<#
창 단축키를 화면 안 요소가 대신 쓰게 넘긴다. 그 요소(또는 그 안)에 포커스가 있으면 셸은 그 키를 처리하지 않는다.
  Register-WtKeyOwner $element 'Ctrl+B'     예: 메모 편집기는 Ctrl+B를 굵게로 쓴다. 셸은 Ctrl+B를 처리하지 않는다
요소가 사라지면 등록도 같이 사라진다(약한 참조).
#>
$script:keyOwners = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Register-WtKeyOwner([Parameter(Mandatory)][System.Windows.DependencyObject]$Element, [Parameter(Mandatory)][string[]]$Keys) {
    $script:keyOwners.AddOrUpdate($Element, [string[]]$Keys)
}

# $From: 찾기 시작할 요소 (기본은 키보드 포커스가 있는 요소)
function Test-WtKeyOwned([string]$Key, $From = [System.Windows.Input.Keyboard]::FocusedElement) {
    if ($Key -eq 'Ctrl+Shift+B') { return $false }   # 창 짜임 전용 키는 편집 칸에 넘기지 않는다
    $el = $From
    while ($el) {
        $keys = $null
        if ($script:keyOwners.TryGetValue($el, [ref]$keys) -and $keys -contains $Key) { return $true }
        $parent = $null
        if ($el -is [System.Windows.Media.Visual]) { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($el) }
        if (-not $parent -and $el -is [System.Windows.DependencyObject]) { $parent = [System.Windows.LogicalTreeHelper]::GetParent($el) }
        $el = $parent
    }
    $false
}

# ---- 창 크기 · 투명도 -------------------------------------------------------------------------

function Set-WtOpacity([double]$Percent = -1) {
    if ($script:forceOpaque) { $script:window.Opacity = 1.0; return }
    if ($Percent -lt 0) { $Percent = [double](Get-WtSetting 'ui.opacity') }
    if (-not $script:window.AllowsTransparency) { return }   # 보통 창으로 띄웠으면 다시 시작해야 투명도가 바뀐다 (Test-WtOpacityNeedsRestart)
    $script:window.Opacity = [Math]::Max(0.6, [Math]::Min(1.0, $Percent / 100))
}

# 투명도를 이 값으로 바꾸면 다시 시작해야 하는지. 투명 창 여부는 창을 보이기 전에만 정할 수 있다 (Start-WtApp)
function Test-WtOpacityNeedsRestart([double]$Percent) {
    $script:window -and $script:window.AllowsTransparency -ne ($Percent -lt 100)
}

# 창이 있는 화면의 작업 영역(또는 전체) 크기를 WPF 단위로
function Get-WtScreenRect([switch]$Full) {
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($script:window).Handle
    $screen = [System.Windows.Forms.Screen]::FromHandle($hwnd)
    $r = if ($Full) { $screen.Bounds } else { $screen.WorkingArea }
    $m = [System.Windows.PresentationSource]::FromVisual($script:window).CompositionTarget.TransformFromDevice
    $tl = $m.Transform([System.Windows.Point]::new($r.Left, $r.Top))
    $br = $m.Transform([System.Windows.Point]::new($r.Right, $r.Bottom))
    [System.Windows.Rect]::new($tl, $br)
}

function Get-WtBounds { [System.Windows.Rect]::new($script:window.Left, $script:window.Top, $script:window.Width, $script:window.Height) }

function Set-WtBounds([System.Windows.Rect]$R) {
    $script:settingBounds = $true
    try {
        $script:window.Left = $R.Left
        $script:window.Top = $R.Top
        $script:window.Width = $R.Width
        $script:window.Height = $R.Height
    } finally {
        $script:settingBounds = $false
    }
}

function Update-WtMaxGlyph {
    $script:ui.MaxGlyph.Text = [string][char]$(if ($script:maxed -or $script:fullscreen) { 0xE923 } else { 0xE922 })
    $script:ui.MaxButton.ToolTip = if ($script:maxed -or $script:fullscreen) { '이전 크기로' } else { '최대화' }
    $script:ui.Frame.BorderThickness = [System.Windows.Thickness]::new($(if ($script:maxed -or $script:fullscreen) { 0 } else { 1 }))
}

# 최대화는 WindowState 대신 작업 영역 크기로 맞춘다 (테두리 없는 창을 Maximized로 두면 작업 표시줄을 덮는다)
function Switch-WtMaximize {
    if ($script:fullscreen) { Switch-WtFullScreen; return }
    if ($script:maxed) {
        Set-WtBounds $script:restoreBounds
        $script:maxed = $false
    } else {
        $script:restoreBounds = Get-WtBounds
        Set-WtBounds (Get-WtScreenRect)
        $script:maxed = $true
    }
    Update-WtMaxGlyph
}

function Switch-WtFullScreen {
    if ($script:fullscreen) {
        $script:fullscreen = $false
        if ($script:fullFromMax) {
            Set-WtBounds (Get-WtScreenRect)
            $script:maxed = $true
        } else {
            Set-WtBounds $script:restoreBounds
            $script:maxed = $false
        }
    } else {
        $script:fullFromMax = $script:maxed
        if (-not $script:maxed) { $script:restoreBounds = Get-WtBounds }
        Set-WtBounds (Get-WtScreenRect -Full)
        $script:fullscreen = $true
    }
    Update-WtMaxGlyph
}

# ---- 트레이 · 종료 ----------------------------------------------------------------------------

# 앱 아이콘 그림 하나(PNG): 강조색 둥근 사각형에 흰 W. 파일 없이 그린다
function New-WtAppIconPng([int]$Size, [string]$Hex) {
    $dv = [System.Windows.Media.DrawingVisual]::new()
    $dc = $dv.RenderOpen()
    $bg = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $r = [Math]::Max(2, $Size * 0.22)
    $dc.DrawRoundedRectangle($bg, $null, [System.Windows.Rect]::new(0, 0, $Size, $Size), $r, $r)
    $tf = [System.Windows.Media.Typeface]::new([System.Windows.Media.FontFamily]::new('Segoe UI'), [System.Windows.FontStyles]::Normal,
        [System.Windows.FontWeights]::Bold, [System.Windows.FontStretches]::Normal)
    $ft = [System.Windows.Media.FormattedText]::new('W', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Windows.FlowDirection]::LeftToRight, $tf, $Size * 0.62, [System.Windows.Media.Brushes]::White, 1.0)
    $geo = $ft.BuildGeometry([System.Windows.Point]::new(0, 0))
    $b = $geo.Bounds
    # 글자 모양(잉크)의 가운데를 그림 가운데에 맞춘다. 작은 크기에서 흐리지 않게 정수 위치로
    $dc.PushTransform([System.Windows.Media.TranslateTransform]::new([Math]::Round(($Size - $b.Width) / 2 - $b.X), [Math]::Round(($Size - $b.Height) / 2 - $b.Y)))
    $dc.DrawGeometry([System.Windows.Media.Brushes]::White, $null, $geo)
    $dc.Pop()
    $dc.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($Size, $Size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = [System.IO.MemoryStream]::new()
    $enc.Save($ms)
    , $ms.ToArray()
}

# 앱 아이콘(.ico 내용): 크기별 그림을 하나로 묶는다. 트레이(16~24) · 제목 줄 · 작업 표시줄(24~48) · 큰 아이콘(256)에서
# Windows가 화면 배율에 맞는 크기를 고르므로 늘리거나 줄여서 흐려지지 않는다.
function New-WtAppIconBytes {
    $hex = (Get-WtThemeColors).Accent
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 256)
    $pngs = @(foreach ($s in $sizes) { , (New-WtAppIconPng $s $hex) })
    $ms = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($ms)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)   # ICO 머리: 예약 · 종류(1=아이콘) · 개수
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]
        $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256))   # 너비 · 높이 (256은 0)
        $w.Write([byte]0); $w.Write([byte]0)                     # 색 수 · 예약
        $w.Write([uint16]1); $w.Write([uint16]32)                # 면 · 색 깊이
        $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write([byte[]]$p) }
    $w.Flush()
    , $ms.ToArray()
}

# 창 · 트레이 아이콘을 지금 테마 색으로 (다시) 만든다
function Update-WtAppIcon {
    $bytes = New-WtAppIconBytes
    $old = $script:icon
    $script:icon = [System.Drawing.Icon]::new([System.IO.MemoryStream]::new($bytes), [System.Windows.Forms.SystemInformation]::SmallIconSize)
    # 아이콘 해석기로 읽은 그림을 주면 WPF가 그 안에서 제목 줄 · 작업 표시줄에 맞는 크기를 고른다
    $dec = [System.Windows.Media.Imaging.IconBitmapDecoder]::new([System.IO.MemoryStream]::new($bytes),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    # 창이 생성된 뒤에도 다시 설정해 Windows가 창의 정식 아이콘을 갱신하게 한다.
    $script:window.Icon = $null
    $script:window.Icon = ($dec.Frames | Where-Object PixelWidth -eq 32 | Select-Object -First 1)
    if (-not $script:window.TaskbarItemInfo) { $script:window.TaskbarItemInfo = [System.Windows.Shell.TaskbarItemInfo]::new() }
    $script:window.TaskbarItemInfo.Description = 'WorkTool'
    $script:window.TaskbarItemInfo.Overlay = $null
    if ($script:notify) { $script:notify.Icon = $script:icon }
    if ($old) { $old.Dispose() }
}

function Show-WtMainWindow {
    $script:window.Show()
    if ($script:window.WindowState -eq 'Minimized') { $script:window.WindowState = 'Normal' }
    [void]$script:window.Activate()
}

# ---- 한 번만 뜨기 · 빠른 적기 --------------------------------------------------------------------
# 진입 스크립트가 이 데이터 폴더의 앱이 되면 신호 손잡이를 넘긴다(Start-WtApp -Instance). 다시 켠 실행 보조가 신호를 보내면
# 화면 스레드 타이머가 WaitOne(0)으로 보고(다른 스레드 콜백 없음) 보이기 · 빠른 적기를 한 뒤 Ready로 다 했다고 알린다.
# 그러면 실행 보조가 그 창을 앞으로 가져온다(단축키로 켠 실행 보조에만 Windows가 그 권한을 준다). 등록 자리는 탭 이름이 아니라
# 쓰임새(Register-WtAddon -QuickCapture)다

function Start-WtInstanceTimer {
    if ($script:instanceTimer) { $script:instanceTimer.Stop() }
    $script:instanceTimer = $null
    if (-not $script:instance) { return }
    $script:instanceTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:instanceTimer.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:instanceTimer.Add_Tick({ [void](Invoke-WtInstanceSignals) })
    $script:instanceTimer.Start()
}

# 받은 신호를 처리한다. 하나라도 처리했으면 다 했다고 알리고 $true
function Invoke-WtInstanceSignals {
    $signals = $script:instance
    if (-not $signals -or $script:exiting) { return $false }
    $done = $false
    try {
        if ($signals.Show -and $signals.Show.WaitOne(0)) { $done = $true; Show-WtMainFront }
        if ($signals.Capture -and $signals.Capture.WaitOne(0)) { $done = $true; Invoke-WtQuickCapture }
    } catch { Show-WtError $_ '다시 켠 WorkTool의 요청' }
    finally { if ($done -and $signals.Ready) { try { [void]$signals.Ready.Set() } catch { } } }
    $done
}

# 끝내기를 시작할 때: 더 받지 않는다. 그사이 켠 실행 보조는 신호를 못 찾고 새 앱 프로세스를 띄우며,
# 그 앱은 이 앱이 끝날 때까지 기다렸다가 이어서 뜬다(Start-WorkTool.ps1 Enter-WtInstance). 앱이 살아 있음(Mutex)은 진입 스크립트가 놓는다
function Stop-WtInstanceSignals {
    if ($script:instanceTimer) { $script:instanceTimer.Stop(); $script:instanceTimer = $null }
    $signals = $script:instance
    $script:instance = $null
    if (-not $signals) { return }
    foreach ($key in 'Show', 'Capture', 'Ready', 'Info') { if ($signals[$key]) { try { $signals[$key].Dispose() } catch { } } }
}

# 보이기: 트레이 · 최소화에서 꺼내 앞으로. 다른 프로그램이 앞에 있어 Windows가 바로 활성화하지 않으면 잠깐 맨 위로 올려 보이게 두고,
# 활성화되거나(실행 보조가 앞으로 가져옴) 3초가 지나면 맨 위를 푼다. 그래도 못 가져오면 Windows가 작업 표시줄 단추를 깜빡인다
function Show-WtMainFront {
    if (-not $script:window) { return }
    Show-WtMainWindow
    if ($script:window.IsActive) { return }
    # 이미 맨 위면 다시 맨 위 무리의 가장 앞으로 올린다(나중에 뜬 알람 창보다 앞)
    $script:window.Topmost = $false
    $script:window.Topmost = $true
    if (-not $script:frontTimer) {
        $script:frontTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:frontTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:frontTimer.Add_Tick({ Clear-WtFrontHold })
    }
    $script:frontTimer.Stop()
    $script:frontTimer.Start()
}

function Clear-WtFrontHold {
    if ($script:frontTimer) { $script:frontTimer.Stop() }
    if ($script:window -and $script:window.Topmost) { $script:window.Topmost = $false }
}

# 빠른 적기 신호: 등록한 켜진 탭의 창을 연다. 등록이 없거나 꺼졌거나, 앱이 대화상자로 묻는 중이거나, 실패하면 앱 창을 보인다
function Invoke-WtQuickCapture {
    $addon = Get-WtQuickCapture
    if (-not $addon -or [System.Windows.Interop.ComponentDispatcher]::IsThreadModal) { Show-WtMainFront; return }
    try {
        [void](& $addon.QuickCapture.Open)
        $script:captureStale = $true
    } catch {
        Show-WtMainFront
        Show-WtError $_ "$($addon.QuickCapture.Name) 열기"
    }
}

# 앱 창이 활성화될 때: 잠깐 맨 위로 둔 것을 풀고, 빠른 적기로 데이터가 바뀐 뒤면 지금 화면을 한 번 새로 그린다(홈 바로 가기 · 메모 목록)
function Invoke-WtMainActivated {
    Clear-WtFrontHold
    if (-not $script:captureStale -or $script:selecting -or -not $script:current -or $script:exiting) { return }
    $script:captureStale = $false
    [void](Invoke-WtPageSelection $script:current)
}

<#
바탕 화면 바로 가기의 「대상」 글(도움말 → 정보). 지금 쓰는 pwsh로 콘솔 창을 숨겨(-WindowStyle Hidden) 진입 파일을 부른다.
옆에 개인 PC 실행 보조(Start-WorkTool-Launcher.ps1)가 있으면 그것을 부른다: 작은 파일이라 앱이 떠 있을 때 신호를 빨리 보낸다.
앱은 바로 가기를 만들지 않는다. 사용자가 이 글로 만들고 Windows 기본 「바로 가기 키」를 단다.
결과: @{ Text; File; Fast(작은 파일을 부름); TooLong(대상 칸 260자를 넘음) }. 진입 파일을 모르면 $null
#>
function Get-WtLaunchTarget([switch]$QuickCapture) {
    $entry = $script:entryPath
    if (-not $entry) { return $null }
    $file = $entry
    $launcher = Join-Path ([System.IO.Path]::GetDirectoryName($entry)) 'Start-WorkTool-Launcher.ps1'
    # 앱 폴더가 응답 없는 공유 폴더여도 화면이 멈추지 않게 화면 밖에서 본다. 답이 늦으면 진입 파일을 쓴다
    try { if (Invoke-WtWork -Call (New-WtCall ([System.IO.File]) Exists $launcher) -Key (Get-WtPathKey $launcher) -TimeoutMs 1500) { $file = $launcher } } catch { }
    $text = '"{0}" -NoProfile -WindowStyle Hidden -File "{1}"' -f (Join-Path $PSHOME 'pwsh.exe'), $file
    if ($QuickCapture) { $text += ' -QuickMemo' }
    [pscustomobject]@{ Text = $text; File = $file; TooLong = $text.Length -gt 259
        Fast = $file -cne $entry -or [System.IO.Path]::GetFileName($entry) -ceq 'Start-WorkTool.ps1' }
}

# 저장하지 못한 내용이 있을 때 묻는다. 'retry'(다시 시도) · 'proceed'(그대로 끝내기 · 이동) · 'cancel' 중 하나를 돌려준다.
# -Text: 기본 문구 대신 보일 글. -NoCancel: [취소]가 없다 (정리를 시작한 뒤)
function Show-WtPendingChoice([string]$Purpose, [string]$Title, [string]$Text = '', [switch]$NoCancel) {
    $exit = $Purpose -eq 'exit'
    $dialog = New-WtModal $(if ($exit) { '저장하지 않고 끝낼까요?' } else { '저장하지 않고 이동할까요?' })
    $message = if ($Text) { $Text }
    elseif ($exit) { "$Title 화면에서 저장하지 못한 내용은 끝내면 사라집니다." }
    else { "$Title 화면에서 저장하지 못한 내용은 그 화면에 그대로 남습니다." }
    $body = New-WtText $message
    $body.TextWrapping = 'Wrap'
    [void](Add-WtChild $dialog.Body $body)
    $retry = New-WtButton '다시 시도' -Kind Primary; $retry.IsDefault = $true
    $go = if ($exit) { New-WtButton '끝내기' -Kind Danger } else { New-WtButton '이동' }
    $dialog.Window.Tag = @{ Choice = 'cancel'; Focus = $retry }
    foreach ($pair in @(@($retry, 'retry'), @($go, 'proceed'))) {
        $pair[0].Tag = @{ Window = $dialog.Window; Choice = $pair[1] }
        $pair[0].Add_Click({ param($s, $e) $s.Tag.Window.Tag.Choice = $s.Tag.Choice; $s.Tag.Window.DialogResult = $true })
        [void](Add-WtChild $dialog.Buttons $pair[0])
    }
    if (-not $NoCancel) { $cancel = New-WtButton '취소'; $cancel.IsCancel = $true; [void](Add-WtChild $dialog.Buttons $cancel) }
    $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Focus.Focus() })
    [void]$dialog.Window.ShowDialog()
    [string]$dialog.Window.Tag.Choice
}

# 저장 통로에 쓰는 중인 것이 남았을 때 (데이터 폴더가 늦게 답함). 창은 멈추지 않고, 저장이 끝나면 저절로 닫힌다.
# 'done'(저장이 끝남) · 'proceed'(기다리지 않고 끝내기 · 이동) · 'cancel' 중 하나. -NoCancel이면 [취소]가 없다 (정리를 시작한 뒤)
function Show-WtWritingChoice([string]$Purpose, [switch]$NoCancel) {
    $exit = $Purpose -eq 'exit'
    $dialog = New-WtModal '저장하는 중입니다'
    $text = New-WtText "데이터 폴더에 저장하는 중입니다. 저장이 끝나면 바로 $(if ($exit) { '끝냅니다' } else { '이동합니다' })." 'T.Body'
    $text.TextWrapping = 'Wrap'
    [void](Add-WtChild $dialog.Body $text)
    $state = New-WtText '' 'T.Sub'
    [void](Add-WtChild $dialog.Body $state)
    $go = New-WtButton $(if ($exit) { '저장을 기다리지 않고 끝내기' } else { '기다리지 않고 이동' }) -Kind Danger
    $go.Tag = $dialog.Window
    $go.Add_Click({ param($s, $e) $s.Tag.Tag.Choice = 'proceed'; $s.Tag.DialogResult = $true })
    [void](Add-WtChild $dialog.Buttons $go)
    if (-not $NoCancel) { $cancel = New-WtButton '취소'; $cancel.IsCancel = $true; [void](Add-WtChild $dialog.Buttons $cancel) }
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $dialog.Window.Tag = @{ Choice = 'cancel'; Timer = $timer; State = $state }
    $timer.Tag = $dialog.Window
    $timer.Add_Tick({
            param($s, $e)
            $w = $s.Tag
            if (-not (Test-WtDataWriting)) { $s.Stop(); $w.Tag.Choice = 'done'; $w.DialogResult = $true; return }
            $st = Get-WtDataWriteState
            $w.Tag.State.Text = "$(if ($st.Slow) { '응답 없음' } else { '저장하는 중' }) · $($st.Seconds)초 · 남은 저장 $($st.Count)개"
        })
    $timer.Start()
    try { [void]$dialog.Window.ShowDialog() } finally { $timer.Stop() }
    [string]$dialog.Window.Tag.Choice
}

# 저장하지 않은 내용을 저장한다. 계속해도 되면 $true.
# -Purpose exit · switch: 저장하지 못하면 다시 시도 · 그대로 진행 · 취소를 묻는다. 막기만 하면 끄거나 옮길 방법이 없어진다.
#          check: 묻지 않고 알린 뒤 $false (예전 데이터 가져오기처럼 덮어쓰는 작업 전)
# -Only: 그 애드온만 확인한다 (화면을 떠날 때는 떠나는 화면만)
function Save-WtPendingChanges([ValidateSet('check', 'switch', 'exit')][string]$Purpose = 'check', [string]$Only = '') {
    foreach ($a in @(Get-WtAddon -All)) {
        if (-not $a.SavePending -or ($Only -and $a.Id -ne $Only)) { continue }
        while ($true) {
            $saved = $false
            try { $saved = (@(& $a.SavePending) | Select-Object -Last 1) -ne $false }
            catch { Show-WtError $_ "저장 확인: $($a.Title)" }
            if ($saved) { break }
            if ($Purpose -eq 'check') {
                Show-WtMessage "$($a.Title) 화면에 저장하지 못한 내용이 있습니다. 저장 오류를 해결한 뒤 다시 시도하세요." '저장 확인' 'Warning'
                return $false
            }
            # 트레이에 숨어 있으면 창을 띄워서 무엇을 저장하지 못했는지 볼 수 있게 한다
            if ($script:window -and -not $script:window.IsVisible) { Show-WtMainWindow }
            $choice = Show-WtPendingChoice $Purpose $a.Title
            if ($choice -eq 'retry') { continue }
            if ($choice -eq 'proceed') { break }
            return $false
        }
    }
    # 저장 통로에 쓰지 못하고 남은 내용(데이터 폴더가 늦게 실패함)이 있으면, 덮어쓰는 작업 전에는 멈춘다 (끝낼 때는 Confirm-WtDataWrites가 묻는다)
    if ($Purpose -eq 'check' -and @(Get-WtDataUnsaved).Count) {
        Show-WtMessage "데이터 폴더에 저장하지 못한 내용이 있습니다 ($((@(Get-WtDataUnsaved) | ForEach-Object Name) -join ', ')). 다시 저장한 뒤 시도하세요." '저장 확인' 'Warning'
        return $false
    }
    $true
}

<#
끝내기 전에 저장 통로를 확인한다. 아직 파일에 쓰이지 않은 내용을 말없이 버리고 끝내지 않는다.
  쓰는 중이면: 끝날 때까지 기다리는 창 (창은 멈추지 않고, 다 쓰면 저절로 닫힌다)
  쓰지 못하고 남은 내용이 있으면: [다시 시도] · [끝내기] · [취소]
사용자가 버리기를 고르면 $script:writingDropped. 계속해도 되면 $true, [취소]면 $false.
-NoCancel: 정리(OnExit)를 시작한 뒤라 취소가 없다. 창을 그냥 닫으면 다시 묻는다
#>
function Confirm-WtDataWrites([switch]$NoCancel) {
    while (-not $script:writingDropped) {
        if (Test-WtDataWriting) {
            if ($script:window -and -not $script:window.IsVisible) { Show-WtMainWindow }
            $choice = Show-WtWritingChoice exit -NoCancel:$NoCancel
            if ($choice -eq 'proceed') { $script:writingDropped = $true; break }
            if ($choice -eq 'cancel' -and -not $NoCancel) { return $false }
            continue
        }
        $left = @(Get-WtDataUnsaved)
        if (-not $left.Count) { break }
        if ($script:window -and -not $script:window.IsVisible) { Show-WtMainWindow }
        $text = "데이터 폴더에 저장하지 못한 내용이 있습니다 ($(($left | ForEach-Object Name) -join ', ')).`n$($left[0].Message)`n`n끝내면 이 내용은 사라집니다."
        $choice = Show-WtPendingChoice exit '데이터 폴더' -Text $text -NoCancel:$NoCancel
        if ($choice -eq 'retry') { Resume-WtDataWrites; continue }
        if ($choice -eq 'proceed') { $script:writingDropped = $true; break }
        if (-not $NoCancel) { return $false }
    }
    $true
}

<#
끝내기 전에 탭에 묻는다(Register-WtAddon -ConfirmExit). 끝내면 사라질 내용(저장하지 않은 편집 폼 등)이 있는 탭만 Pending이 $true다.
물을 탭이 있으면 트레이에 숨은 창을 띄우고 그 탭 화면을 보인 뒤 Confirm을 부른다(고칠 곳 · 저장 오류가 보이게).
화면을 옮길 때 떠나는 화면의 저장 확인은 건너뛴다: 그 저장은 바로 뒤 끝내기 저장 단계(Save-WtPendingChanges)가 맡고, 여기서 물으면 순서가 바뀐다.
하나라도 $false(취소 · 저장 실패)면 $false. 탭의 함수가 실패하면 알리고 끝내기를 막지 않는다(끌 수 없는 상태를 만들지 않는다)
#>
function Confirm-WtAddonExit {
    foreach ($a in @(Get-WtAddon -All)) {
        if (-not $a.ConfirmExit) { continue }
        $pending = $false
        try { $pending = (@(& $a.ConfirmExit.Pending) | Select-Object -Last 1) -eq $true } catch { Show-WtError $_ "끝내기 확인: $($a.Title)" }
        if (-not $pending) { continue }
        if ($script:window -and -not $script:window.IsVisible) { Show-WtMainWindow }
        if ($script:ui -and $script:current -ne $a.Id -and (Get-WtAddon -Id $a.Id)) { [void](Invoke-WtPageSelection $a.Id -NoSave) }
        $ok = $true
        try { $ok = (@(& $a.ConfirmExit.Confirm) | Select-Object -Last 1) -ne $false } catch { Show-WtError $_ "끝내기 확인: $($a.Title)" }
        if (-not $ok) { return $false }
    }
    $true
}

# 저장을 확인한 뒤에만(또는 저장하지 않고 끝내기를 고른 뒤에만) 트레이·타이머를 정리하고 메시지 돌리기를 멈춘다.
# 탭의 OnExit 뒤에 남은 화면 밖 작업(응답 없는 공유 폴더 조회 등)은 기다리지 않고 모두 버린다 (core\Work.psm1)
# 묻는 순서: 탭이 묻기(고친 폼: 저장 · 저장 안 함 · 취소) → 저장 통로 마무리(SavePending, 실패면 다시 시도 · 끝내기) → 보조 창 닫기 →
# 쓰는 중 · 쓰지 못한 내용 확인. 앞에서 취소하면 뒤는 묻지 않아 창이 겹치지 않는다. 묻는 동안 또 끝내기가 오면(트레이 종료 등) 바로 $false
function Stop-WtApp {
    if (-not $script:exiting) {
        if ($script:exitAsking) { return $false }
        $script:exitAsking = $true
        try {
            $script:writingDropped = $false
            if (-not (Confirm-WtAddonExit)) { return $false }
            if (-not (Save-WtPendingChanges -Purpose exit)) { return $false }
            # 보조 창 위치를 저장한 쓰기도 종료 확인에 포함한다.
            if (-not (Close-WtUtilityWindows)) { return $false }
            if (-not (Confirm-WtDataWrites)) { return $false }
            foreach ($a in @(Get-WtAddon -All)) {
                if ($a.OnExit) { try { [void](& $a.OnExit) } catch { Show-WtError $_ "끝내기 전 저장: $($a.Title)" } }
            }
            # 정리 중에 시작한 저장(실행 기록 등)도 같다. 정리는 이미 했으니 취소는 없다
            [void](Confirm-WtDataWrites -NoCancel)
        } finally { $script:exitAsking = $false }
    }
    $script:exiting = $true
    Stop-WtInstanceSignals   # 다시 켠 실행 보조는 이제 이 앱을 찾지 않고, 새 앱이 이 앱이 끝나기를 기다린다
    if ($script:writingDropped) { try { Stop-WtDataWrites } catch { } }   # 사용자가 기다리지 않고 끝내기를 골랐다
    try { Stop-WtAllWork } catch { }
    if ($script:warmTimer) { $script:warmTimer.Stop() }
    if ($script:badgeTimer) { $script:badgeTimer.Stop() }
    if ($script:frontTimer) { $script:frontTimer.Stop() }
    try { Stop-WtAddonTicks } catch { }
    try { Clear-WtNotices } catch { }
    try { $script:notify.Visible = $false; $script:notify.Dispose() } catch { }
    try { if ($script:icon) { $script:icon.Dispose() } } catch { }
    if ($script:frame) { $script:frame.Continue = $false }
    $true
}

function Exit-WtApp {
    if (-not (Stop-WtApp)) { return }
    try { $script:window.Close() } catch { }
}

function Update-WtCloseTip {
    $script:ui.CloseButton.ToolTip = if ([bool](Get-WtSetting 'window.closeToTray')) { '닫기 (트레이에서 계속 실행)' } else { '닫기' }
}

# 트레이 메뉴(디자인 6절): 열기 · 알람 잠시 끄기 ›(1시간 · 오늘 하루 · 다시 켤 때까지) · 구분선 · 종료.
# 알람을 끈 동안은 잠시 끄기 대신 「알람 다시 켜기 (꺼짐 ~ 15:30)」. 열 때마다 지금 상태로 맞춘다
function New-WtTrayMenu {
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    [void]$menu.Items.Add('열기', $null, { Show-WtMainWindow })
    $pause = [System.Windows.Forms.ToolStripMenuItem]::new('알람 잠시 끄기')
    foreach ($mode in @(@('hour', '1시간'), @('today', '오늘 하루'), @('manual', '다시 켤 때까지'))) {
        $sub = [System.Windows.Forms.ToolStripMenuItem]::new($mode[1])
        $sub.Tag = $mode[0]
        $sub.Add_Click({ param($s, $e) [void](Set-WtNoticePause ([string]$s.Tag)) })
        [void]$pause.DropDownItems.Add($sub)
    }
    $resume = [System.Windows.Forms.ToolStripMenuItem]::new('알람 다시 켜기')
    $resume.Add_Click({ [void](Set-WtNoticePause off) })
    [void]$menu.Items.Add($pause)
    [void]$menu.Items.Add($resume)
    [void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
    [void]$menu.Items.Add('종료', $null, { Exit-WtApp })
    $menu.Tag = @{ Pause = $pause; Resume = $resume }
    $menu.Add_Opening({ param($s, $e) Update-WtTrayMenu $s })
    Update-WtTrayMenu $menu
    $menu
}
function Update-WtTrayMenu($Menu, [datetime]$Now = (Get-Date)) {
    $state = try { Get-WtNoticePause $Now } catch { $null }
    $paused = $state -and $state.Paused
    $Menu.Tag.Pause.Visible = -not $paused
    $Menu.Tag.Resume.Visible = $paused
    if ($paused) { $Menu.Tag.Resume.Text = "알람 다시 켜기 ($($state.Text -replace '^알람 ', ''))" }
}

function New-WtTrayIcon([System.Drawing.Icon]$Icon) {
    $n = [System.Windows.Forms.NotifyIcon]::new()
    $n.Icon = $Icon
    $n.Text = 'WorkTool'
    $n.ContextMenuStrip = New-WtTrayMenu
    $n.Add_MouseDoubleClick({ Show-WtMainWindow })
    $n.Visible = $true
    $n
}

# ---- 예전 데이터 가져오기 ----------------------------------------------------------------------

# 예전 WorkTool(WinForms) data 폴더에서 탭마다 데이터를 가져온다.
# -Force가 없으면 아직 저장소가 없는 탭만 가져온다 (처음 실행할 때).
function Import-WtLegacyData([switch]$Force) {
    if ($Force -and -not (Save-WtPendingChanges)) { throw '저장하지 못한 내용이 있어 가져오기를 취소했습니다.' }
    $folder = Find-WtLegacyFolder
    $result = @{ Folder = $folder; Count = 0; Tabs = @(); At = $null }
    if (-not $folder) { return $result }
    foreach ($a in @(Get-WtAddon -All)) {
        if (-not $a.ImportLegacy) { continue }
        if (-not $Force -and (Test-WtStore $a.Id)) { continue }
        $n = & $a.ImportLegacy $folder | Select-Object -Last 1
        if ($null -ne $n) {
            $result.Count += [int]$n
            $result.Tabs += "$($a.Title) $n"
        }
    }
    if ($result.Tabs.Count) {
        $result.At = Get-Date
        $script:lastImport = $result
    }
    $result
}

function Get-WtLastImport { $script:lastImport }

# ---- 시작 -------------------------------------------------------------------------------------

function Initialize-WtShellSettings {
    if ($script:settingHandlerRegistered) { return }
    Register-WtSettingHandler {
        param($key, $value)
        if (-not $script:ui -or $script:exiting) { return }
        switch -Wildcard ($key) {
            'theme.color' { Update-WtAppIcon }
            'ui.opacity' { Set-WtOpacity }
            'window.closeToTray' { Update-WtCloseTip }
            'addons.disabled' { Update-WtNav }
            'notice.pausedUntil' { Update-WtStatusBar }
        }
    }
    $script:settingHandlerRegistered = $true
}

function Initialize-WtShellButtons {
    $script:ui.MinButton.Add_Click({ $script:window.WindowState = 'Minimized' })
    $script:ui.MaxButton.Add_Click({ Switch-WtMaximize })
    $script:ui.CloseButton.Add_Click({ $script:window.Close() })
    $script:ui.SettingsButton.Add_Click({ Select-WtPage '_settings' })
    $script:ui.HelpButton.Add_Click({ Select-WtPage '_help' })
}

# -ScriptPath: 진입 파일(바로 가기 대상 글에 쓴다). -Instance: 진입 스크립트의 한 번만 뜨기 신호 손잡이(없으면 신호를 받지 않는다)
function Start-WtApp {
    param([Parameter(Mandatory)][string]$AppRoot, [string]$ScriptPath = '', [hashtable]$Instance)

    $script:exiting = $false
    $script:entryPath = $ScriptPath
    $script:instance = if ($Instance -and $Instance.Show -and $Instance.Capture) { $Instance } else { $null }
    $script:captureStale = $false
    $script:notify = $null
    $script:views = @{}
    $script:utilityWindows = @{}
    $script:current = $null
    $script:maxed = $false
    $script:fullscreen = $false
    $script:warmEnabled = $env:WORKTOOL_WARMUP -eq '1'
    $script:warmStarted = $false
    $script:warmQueue = $null
    if ($script:warmTimer) { $script:warmTimer.Stop() }
    $script:forceOpaque = $env:WORKTOOL_FORCE_OPAQUE -eq '1'
    Set-WtAppRoot $AppRoot
    $dataLock = Open-WtDataLock
    try {
    Initialize-WtSettings
    # 올해 · 내년 공휴일을 채운다. 이미 채운 해는 건너뛰고(파일만 읽음), 설정에서 끌 수 있다. 실패해도 시작은 막지 않는다
    try { [void](Update-WtAutoHolidays -Years @([datetime]::Today.Year, ([datetime]::Today.Year + 1))) } catch { }
    $script:themeDict = New-WtThemeDictionary

    $w = ConvertFrom-WtXaml $script:shellXaml
    $script:window = $w
    $script:ui = Get-WtNamedElements $w $script:shellXaml
    $w.Resources.MergedDictionaries.Add($script:themeDict)
    $w.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    # 투명 창은 ClearType이 꺼져 글자가 흐리게(회색조로) 그려진다. 불투명도 100%로 시작하면 보통 창으로 만들어 또렷하게 그린다
    if ($script:forceOpaque -or [double](Get-WtSetting 'ui.opacity') -ge 100) {
        $w.AllowsTransparency = $false
        $w.Opacity = 1.0
        $w.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'B.WindowBg')
    }

    Update-WtAppIcon
    $w.Add_ContentRendered({ Update-WtAppIcon; Start-WtWarmUp })
    $w.Add_Activated({ try { Invoke-WtMainActivated } catch { Show-WtError $_ '화면 새로 그리기' } })
    $w.Add_SizeChanged({ Update-WtCurrentSidePanels })
    $script:ui.StatusLeft.Add_SizeChanged({ param($s, $e) Set-WtStatusLayout $s })

    # 제목 줄 버튼
    Initialize-WtShellButtons

    # 제목 줄을 두 번 누르면 Windows가 Maximized로 바꾼다 → 작업 영역 최대화로 바꿔 준다
    $w.Add_StateChanged({
            if ($script:window.WindowState -eq 'Maximized') {
                $script:window.WindowState = 'Normal'
                Switch-WtMaximize
            }
        })

    # 최대화 · 전체 화면 상태에서 제목 줄을 끌어 옮기면 그 표시를 푼다 (다음 최대화 버튼이 바로 최대화하도록)
    $w.Add_LocationChanged({
            if ($script:settingBounds -or -not ($script:maxed -or $script:fullscreen)) { return }
            $script:maxed = $false
            $script:fullscreen = $false
            Update-WtMaxGlyph
        })

    # X는 기본으로 트레이로 숨긴다. 직접 고른 닫기 동작은 저장된 설정을 따른다.
    $w.Add_Closing({
            param($s, $e)
            if (-not $script:exiting -and (Close-WtFirstWorkSetup -UseDefaults)) { $e.Cancel = $true; return }
            if ($script:exiting) { return }
            if (-not [bool](Get-WtSetting 'window.closeToTray')) { $e.Cancel = -not (Stop-WtApp); return }
            $e.Cancel = $true
            if (-not (Close-WtUtilityWindows)) { return }
            $s.Hide()
            if (-not $script:trayTipShown) {
                $script:notify.ShowBalloonTip(3000, 'WorkTool', '트레이에서 계속 실행 중입니다. 끄려면 트레이 아이콘 우클릭 → 종료.',
                    [System.Windows.Forms.ToolTipIcon]::Info)
                $script:trayTipShown = $true
            }
        })

    $w.Add_PreviewKeyDown({
            param($s, $e)
            try { Invoke-WtShellKey $e } catch { Show-WtError $_ '단축키' }
        })

    if ($global:WorkToolUnhandledHandler) {
        try { $w.Dispatcher.remove_UnhandledException($global:WorkToolUnhandledHandler) } catch { }
    }
    $global:WorkToolUnhandledHandler = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler] {
        param($s, $e)
        Show-WtError $e.Exception '처리되지 않은 오류'
        $e.Handled = $true
    }
    $w.Dispatcher.add_UnhandledException($global:WorkToolUnhandledHandler)

    # 설정이 바뀌면 바로 반영한다
    Initialize-WtShellSettings

    # 처음 실행이면 예전 WorkTool 데이터를 가져온다 (이미 가져온 탭은 건너뜀)
    try { [void](Import-WtLegacyData) } catch { Show-WtError $_ '예전 데이터 가져오기' }

    Update-WtNav
    Start-WtNavBadgeTimer
    # 탭이 등록한, 화면에 묶지 않은 작업(일정 알람 확인 등). 트레이로 숨거나 다른 탭을 볼 때도 돈다
    [void](Start-WtAddonTicks)
    Update-WtCloseTip
    Set-WtOpacity
    $script:notify = New-WtTrayIcon $script:icon

    # 창이 닫힐 때까지 메시지를 돌린다. Dispatcher를 끄지 않으므로 같은 창에서 다시 실행해도 된다.
    $script:frame = [System.Windows.Threading.DispatcherFrame]::new()
    $w.Show()
    # 실행 파일이 콘솔을 최소화해서 띄우면(start /min) 첫 창도 최소화돼서 뜬다 → 원래 크기로 앞에 띄운다
    if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
    [void]$w.Activate()
    $initialPage = Initialize-WtMainPage
    Show-WtFirstWorkSetup $w $initialPage
    # 다 뜬 뒤부터 다시 켠 실행 보조의 신호를 받는다(뜨는 동안 온 신호 · 자기 -QuickMemo도 첫 틱에 처리한다)
    Start-WtInstanceTimer
    if (-not $script:exiting) { [System.Windows.Threading.Dispatcher]::PushFrame($script:frame) }
    } finally {
        Stop-WtInstanceSignals
        if ($script:frontTimer) { $script:frontTimer.Stop() }
        if ($script:badgeTimer) { $script:badgeTimer.Stop() }
        if ($script:warmTimer) { $script:warmTimer.Stop() }
        try { Stop-WtAddonTicks } catch { }
        try { Clear-WtNotices } catch { }
        $script:warmQueue = $null
        try {
            if ($script:notify) { $script:notify.Visible = $false; $script:notify.Dispose() }
            if ($script:icon) { $script:icon.Dispose() }
        } finally { Close-WtDataLock $dataLock }
    }
}

Export-ModuleMember -Function Get-WtWindow, Select-WtPage, Open-WtPage, Reset-WtViews, Update-WtNav, Update-WtNavBadges, Register-WtKeyOwner, Test-WtKeyOwned,
    New-WtSidePanel, Switch-WtPanelCycle, Set-WtOpacity, Test-WtOpacityNeedsRestart,
    Switch-WtMaximize, Switch-WtFullScreen, Show-WtMainWindow, Exit-WtApp, Import-WtLegacyData, Get-WtLastImport, Start-WtApp,
    New-WtTrayMenu, Update-WtTrayMenu, Get-WtLaunchTarget

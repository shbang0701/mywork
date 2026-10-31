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
        $settings = @(foreach ($name in 'theme.color','theme.accent','ui.opacity','ui.fontScale','window.closeToTray','addons.disabled','legacy.path') {
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

function Select-WtPage([string]$Id) {
    [void](Invoke-WtPageSelection $Id)
}

# 공개된 Select-WtPage의 출력은 그대로 두고, 항목 열기는 전환 성공 여부까지 확인한다.
function Invoke-WtPageSelection([string]$Id) {
    if ($script:selecting -or -not $Id) { return $false }
    $script:selecting = $true
    try {
        # 떠나는 화면에 저장하지 못한 내용이 있으면 묻는다 (다른 화면의 저장 상태는 그 화면을 떠날 때 묻는다)
        if ($script:current -and $Id -ne $script:current -and -not (Save-WtPendingChanges -Purpose switch -Only $script:current)) { return $false }
        $page = Get-WtPageView $Id
        if (-not $page) { return $false }
        if ($page.Addon -and $page.Addon.Refresh) { [void](& $page.Addon.Refresh $page.View) }
        $script:ui.PageHost.Content = $page.View
        foreach ($k in @($script:navButtons.Keys)) { $script:navButtons[$k].Button.IsChecked = ($k -eq $Id) }
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
        if ($id -eq $script:current -or ($id -notlike '_*' -and $script:views.ContainsKey($id))) { continue }   # 이미 열었다
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
        if ($group.Name) {
            $style = if ($script:navGroups.Count) { 'T.NavGroup.Next' } else { 'T.NavGroup' }
            $heading = New-WtText $group.Name $style
            [void]$panel.Children.Add($heading)
            $script:navGroups += $heading
        }
        foreach ($addon in $group.Items) {
            $rb = [System.Windows.Controls.RadioButton]::new()
            Set-WtStyle $rb 'Nav'
            $rb.GroupName = 'WtNav'
            $rb.Tag = $addon.Id
            $rb.ToolTip = $addon.Title
            [System.Windows.Automation.AutomationProperties]::SetName($rb, $addon.Title)
            $row = (Get-WtStyleDictionary)['Shell.NavItem'].LoadContent()
            $parts = @{ Button = $rb; Addon = $addon; Value = $null }
            foreach ($name in 'Icon','Label','Count','Dot','IconDot') { $parts[$name] = $row.FindName($name) }
            $parts.Icon.Text = [string][char]$addon.Icon
            $parts.Label.Text = $addon.Title
            $parts.Dot.ToolTip = $addon.BadgeToolTip
            $parts.IconDot.ToolTip = $addon.BadgeToolTip
            $rb.Content = $row
            $rb.IsChecked = ($addon.Id -eq $script:current)
            $rb.Add_Checked({ param($s, $e) Select-WtPage ([string]$s.Tag) })
            [void]$panel.Children.Add($rb)
            $script:navButtons[$addon.Id] = $parts
        }
    }
    Update-WtNavBadges
}

# 배지 계산은 선택·새로 그리기·분 타이머에서만. 한 출처가 실패해도 다른 배지는 계속 계산한다.
function Update-WtNavBadges {
    foreach ($item in $script:navButtons.Values) {
        $value = $null
        if ($item.Addon.Badge) {
            try {
                $result = & $item.Addon.Badge
                if ($result -is [string] -and $result -ceq 'dot') { $value = 'dot' }
                elseif ($null -ne $result -and [Type]::GetTypeCode($result.GetType()) -in @('Byte','SByte','Int16','UInt16','Int32','UInt32','Int64','UInt64','Single','Double','Decimal')) {
                    $value = $result.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                }
            } catch { $value = $null }
        }
        $item.Value = $value
        $item.Count.Text = if ($null -ne $value -and $value -ne 'dot') { $value } else { '' }
    }
    Update-WtCollapsed
}

function Start-WtNavBadgeTimer {
    if ($script:badgeTimer) { $script:badgeTimer.Stop() }
    $script:badgeTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:badgeTimer.Interval = [TimeSpan]::FromMinutes(1)
    $script:badgeTimer.Add_Tick({ Update-WtNavBadges })
    $script:badgeTimer.Start()
}

function Update-WtCollapsed {
    if ($script:ui -and $script:ui.NavBorder) {
        Set-WtNavLayout $script:ui $script:navButtons.Values $script:navGroups ([bool](Get-WtSetting 'nav.collapsed'))
    }
}

function Switch-WtCollapsed {
    Set-WtSetting 'nav.collapsed' (-not [bool](Get-WtSetting 'nav.collapsed'))
    Update-WtCollapsed
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
        [ValidateSet(220,280,308)][int]$Width = 308,
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
    $narrow = $width -lt (Get-WtStyleDictionary)['F.SidePanel.Breakpoint']
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
    if (-not $panel) { Switch-WtCollapsed; return }
    Update-WtSidePanel $panel
    $nav = [bool](Get-WtSetting 'nav.collapsed')
    if (-not $panel.Collapsed -and -not $nav) { $panel.Cycle = 'close-nav'; Set-WtSidePanelCollapsed $panel $true }
    elseif ($panel.Collapsed -and -not $nav -and $panel.Cycle -eq 'open-side') { $panel.Cycle = ''; Set-WtSidePanelCollapsed $panel $false }
    elseif (-not $nav) { $panel.Cycle = 'open-nav'; Switch-WtCollapsed }
    else { $panel.Cycle = 'open-side'; Switch-WtCollapsed }
}

<#
창 단축키를 화면 안 요소가 대신 쓰게 넘긴다. 그 요소(또는 그 안)에 포커스가 있으면 셸은 그 키를 처리하지 않는다.
  Register-WtKeyOwner $element 'Ctrl+B'     예: 메모 편집기는 Ctrl+B를 굵게로 쓴다. 다른 곳에서는 그대로 메뉴 접기
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
    $hex = (Get-WtThemeColors ([string](Get-WtSetting 'theme.color'))).Accent
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

# 저장을 확인한 뒤에만(또는 저장하지 않고 끝내기를 고른 뒤에만) 트레이·타이머를 정리하고 메시지 돌리기를 멈춘다.
# 탭의 OnExit 뒤에 남은 화면 밖 작업(응답 없는 공유 폴더 조회 등)은 기다리지 않고 모두 버린다 (core\Work.psm1)
function Stop-WtApp {
    if (-not $script:exiting) {
        $script:writingDropped = $false
        if (-not (Save-WtPendingChanges -Purpose exit)) { return $false }
        if (-not (Confirm-WtDataWrites)) { return $false }
        foreach ($a in @(Get-WtAddon -All)) {
            if ($a.OnExit) { try { [void](& $a.OnExit) } catch { Show-WtError $_ "끝내기 전 저장: $($a.Title)" } }
        }
        # 정리 중에 시작한 저장(실행 기록 등)도 같다. 정리는 이미 했으니 취소는 없다
        [void](Confirm-WtDataWrites -NoCancel)
    }
    $script:exiting = $true
    if ($script:writingDropped) { try { Stop-WtDataWrites } catch { } }   # 사용자가 기다리지 않고 끝내기를 골랐다
    try { Stop-WtAllWork } catch { }
    if ($script:warmTimer) { $script:warmTimer.Stop() }
    if ($script:badgeTimer) { $script:badgeTimer.Stop() }
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

function New-WtTrayIcon([System.Drawing.Icon]$Icon) {
    $n = [System.Windows.Forms.NotifyIcon]::new()
    $n.Icon = $Icon
    $n.Text = 'WorkTool'
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    [void]$menu.Items.Add('열기', $null, { Show-WtMainWindow })
    [void]$menu.Items.Add('종료', $null, { Exit-WtApp })
    $n.ContextMenuStrip = $menu
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
            'theme.color' { Update-WtThemeDictionary $script:themeDict; Update-WtAppIcon }
            'ui.opacity' { Set-WtOpacity }
            'nav.collapsed' { Update-WtCollapsed }
            'window.closeToTray' { Update-WtCloseTip }
            'addons.disabled' { Update-WtNav }
        }
    }
    $script:settingHandlerRegistered = $true
}

function Start-WtApp {
    param([Parameter(Mandatory)][string]$AppRoot)

    $script:exiting = $false
    $script:notify = $null
    $script:views = @{}
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
    $w.Add_SizeChanged({ Update-WtCurrentSidePanels })

    # 제목 줄 · 메뉴 아래 버튼
    $script:ui.CollapseButton.Add_Click({ Switch-WtCollapsed })
    $script:ui.MinButton.Add_Click({ $script:window.WindowState = 'Minimized' })
    $script:ui.MaxButton.Add_Click({ Switch-WtMaximize })
    $script:ui.CloseButton.Add_Click({ $script:window.Close() })
    $script:ui.SettingsButton.Add_Click({ Select-WtPage '_settings' })
    $script:ui.HelpButton.Add_Click({ Select-WtPage '_help' })

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

    # X(닫기)는 앱을 끝낸다. 설정에서 '트레이로 숨기기'를 켜면 트레이로 숨기고, 끄는 건 트레이 아이콘 우클릭 → 종료
    $w.Add_Closing({
            param($s, $e)
            if (-not $script:exiting -and (Close-WtFirstWorkSetup -UseDefaults)) { $e.Cancel = $true; return }
            if ($script:exiting) { return }
            if (-not [bool](Get-WtSetting 'window.closeToTray')) { $e.Cancel = -not (Stop-WtApp); return }
            $e.Cancel = $true
            $s.Hide()
            if (-not $script:trayTipShown) {
                $script:notify.ShowBalloonTip(3000, 'WorkTool', '트레이에서 계속 실행 중입니다. 끄려면 트레이 아이콘 우클릭 → 종료.',
                    [System.Windows.Forms.ToolTipIcon]::Info)
                $script:trayTipShown = $true
            }
        })

    $w.Add_PreviewKeyDown({
            param($s, $e)
            try {
                if (Invoke-WtWorkSetupKey $e) { return }
                $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
                $key = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
                $shift = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
                if ($ctrl -and $shift -and $key -eq 'B') { Switch-WtPanelCycle; $e.Handled = $true; return }
                if ($ctrl -and $key -eq 'B' -and -not (Test-WtKeyOwned 'Ctrl+B')) { Switch-WtCollapsed; $e.Handled = $true; return }
                if ($key -eq 'F11') { Switch-WtFullScreen; $e.Handled = $true; return }
                if ($key -eq 'Escape' -and $script:fullscreen) { Switch-WtFullScreen; $e.Handled = $true; return }
                if ($key -eq 'F1') { Select-WtPage '_help'; $e.Handled = $true; return }
                if ($ctrl -and $key -eq 'OemComma') { Select-WtPage '_settings'; $e.Handled = $true; return }
                if ($ctrl -and [int]$key -ge [int][System.Windows.Input.Key]::D1 -and [int]$key -le [int][System.Windows.Input.Key]::D9) {
                    $ids = @(Get-WtAddon | ForEach-Object { $_.Id })
                    $idx = [int]$key - [int][System.Windows.Input.Key]::D1
                    if ($idx -lt $ids.Count) { Select-WtPage $ids[$idx] }
                    $e.Handled = $true
                }
            } catch { Show-WtError $_ '단축키' }
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
    Update-WtCloseTip
    Set-WtOpacity
    $script:notify = New-WtTrayIcon $script:icon

    # 창이 닫힐 때까지 메시지를 돌린다. Dispatcher를 끄지 않으므로 같은 창에서 다시 실행해도 된다.
    $script:frame = [System.Windows.Threading.DispatcherFrame]::new()
    $w.Show()
    # 실행 파일이 콘솔을 최소화해서 띄우면(start /min) 첫 창도 최소화돼서 뜬다 → 원래 크기로 앞에 띄운다
    if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
    [void]$w.Activate()
    $first = @(Get-WtAddon)[0]
    if ($first) { Select-WtPage $first.Id } else { Select-WtPage '_settings' }
    Show-WtFirstWorkSetup $w $(if ($first) { $first.Id } else { '_settings' })
    if (-not $script:exiting) { [System.Windows.Threading.Dispatcher]::PushFrame($script:frame) }
    } finally {
        if ($script:badgeTimer) { $script:badgeTimer.Stop() }
        if ($script:warmTimer) { $script:warmTimer.Stop() }
        $script:warmQueue = $null
        try {
            if ($script:notify) { $script:notify.Visible = $false; $script:notify.Dispose() }
            if ($script:icon) { $script:icon.Dispose() }
        } finally { Close-WtDataLock $dataLock }
    }
}

Export-ModuleMember -Function Get-WtWindow, Select-WtPage, Open-WtPage, Reset-WtViews, Update-WtNav, Switch-WtCollapsed, Register-WtKeyOwner, Test-WtKeyOwned,
    New-WtSidePanel, Switch-WtPanelCycle, Set-WtOpacity, Test-WtOpacityNeedsRestart,
    Switch-WtMaximize, Switch-WtFullScreen, Show-WtMainWindow, Exit-WtApp, Import-WtLegacyData, Get-WtLastImport, Start-WtApp

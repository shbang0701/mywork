# 일정 화면. 데이터 편집·반복·루틴 증적은 ScheduleData, 모양은 공통 UI가 맡는다.
$ErrorActionPreference = 'Stop'
$script:inv = [Globalization.CultureInfo]::InvariantCulture
$script:view = $null
$script:month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
$script:selected = [datetime]::Today
$script:form = $null
$script:homeTimer = $null
$script:homeTimeline = $null
$script:focusKey = $null   # 체크한 뒤 다시 그린 목록에서 포커스를 돌려줄 회차 키
$script:picker = $null
# 3단계 보기(설계 14장): due(할 일) · calendar · table · routines. 마지막 보기는 설정 schedule.view에 남긴다
$script:viewModes = @('due', 'calendar', 'table', 'routines')
$script:viewMode = 'calendar'
$script:viewSync = $false        # 보기 단추를 코드에서 맞추는 중(Checked 처리 건너뜀)
$script:search = $null           # 찾기 칸 @{ Root; Box }
$script:searchTimer = $null
$script:collapsed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)   # 할 일에서 접은 묶음
$script:tableItems = @()
$script:tableUpdating = $false
Register-WtSettingDefault 'schedule.view' 'calendar'

function Format-WtAlarm($Minutes) {
    if ($null -eq $Minutes -or "$Minutes" -eq '') { return $null }
    $m = [int]$Minutes
    if ($m -eq 0) { '정시' } elseif ($m -eq 1440) { '하루 전' } elseif ($m % 60 -eq 0) { "$($m / 60)시간 전" } else { "${m}분 전" }
}

# 반복 규칙(ConvertFrom-WtScheduleItem의 Repeat) → 짧은 이름
function Get-WtRepeatLabel($Rule) {
    if (-not $Rule) { return $null }
    $n = [int]$Rule.Interval
    switch ($Rule.Freq) {
        'daily' { if ($n -eq 1) { '매일' } else { "${n}일마다" } }
        'weekly' {
            $weekdays = $Rule.Days.Count -eq 5 -and -not @($Rule.Days | Where-Object { [int]$_ -eq 0 -or [int]$_ -eq 6 }).Count
            if ($n -eq 1 -and $weekdays) { '평일' } elseif ($n -eq 1) { '매주' } elseif ($n -eq 2) { '격주' } else { "${n}주마다" }
        }
        'monthly' { if ($n -eq 1) { '매월' } else { "${n}개월마다" } }
        'yearly' { if ($n -eq 1) { '매년' } else { "${n}년마다" } }
    }
}
function Get-WtScheduleToolTip($Occ) {
    $when = if ($Occ.LastDay -gt $Occ.Start.Date) { Get-WtEventSpan $Occ } elseif ($Occ.AllDay) { '하루 종일' } else {
        $Occ.Start.ToString('HH:mm', $script:inv) + $(if ($Occ.End -gt $Occ.Start) { '–' + $Occ.End.ToString('HH:mm', $script:inv) })
    }
    @(@($Occ.Title, $when, (Get-WtRepeatLabel $Occ.Entry.Repeat)) + @($Occ.Alarms | ForEach-Object { Format-WtAlarm $_ }) | Where-Object { $_ }) -join [Environment]::NewLine
}
function Get-WtScheduleLine($Occ) {
    if ($Occ.AllDay) { $Occ.Title } else { $Occ.Start.ToString('HH:mm', $script:inv) + ' ' + $Occ.Title }
}

function New-WtScheduleView {
    $xaml = @"
<Grid {NS} Style="{DynamicResource Schedule.Page}">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <Border Style="{DynamicResource Panel.Surface}">
    <DockPanel>
      <DockPanel DockPanel.Dock="Top" Style="{DynamicResource Schedule.Header}">
        <StackPanel x:Name="Nav" Orientation="Horizontal" DockPanel.Dock="Right" VerticalAlignment="Center"/>
        <StackPanel x:Name="HeadLeft" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="MonthButton" Style="{DynamicResource Schedule.MonthButton}" ToolTip="해 · 달 고르기">
            <StackPanel Orientation="Horizontal"><TextBlock x:Name="Month" Style="{DynamicResource Schedule.Month}"/><TextBlock Text="&#xE70D;" Style="{DynamicResource Schedule.MonthChevron}"/></StackPanel>
          </Button>
          <StackPanel x:Name="TableNav" Style="{DynamicResource Schedule.TableNav}" Visibility="Collapsed"/>
          <TextBlock x:Name="ViewTitle" Style="{DynamicResource Schedule.ViewTitle}" Visibility="Collapsed"/>
        </StackPanel>
        <Popup x:Name="MonthPopup" StaysOpen="False" Placement="Bottom" AllowsTransparency="True" VerticalOffset="4" PlacementTarget="{Binding ElementName=MonthButton}"/>
      </DockPanel>
      <DockPanel Style="{DynamicResource Schedule.Body}">
        <Grid>
          <DockPanel x:Name="CalendarHost">
            <UniformGrid x:Name="Week" Columns="7" DockPanel.Dock="Top"/>
            <Border BorderThickness="0,1,0,0" BorderBrush="{DynamicResource B.Border.Muted}">
              <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
                <Grid><UniformGrid x:Name="Days" Columns="7"/><Grid x:Name="Bars"/></Grid>
              </ScrollViewer>
            </Border>
          </DockPanel>
          <DockPanel x:Name="TableHost" Visibility="Collapsed">
            <Border x:Name="TableHead" DockPanel.Dock="Top" Style="{DynamicResource Schedule.TableHead}"/>
            <TextBlock x:Name="TableNote" DockPanel.Dock="Bottom" Style="{DynamicResource Table.Empty}" Visibility="Collapsed"/>
            <Grid><ListBox x:Name="TableList" Style="{DynamicResource Schedule.TableList}"/><TextBlock x:Name="TableEmpty" Style="{DynamicResource Table.Empty}" VerticalAlignment="Top" Visibility="Collapsed"/></Grid>
          </DockPanel>
          <DockPanel x:Name="RoutineHost" Visibility="Collapsed">
            <Border x:Name="RoutineHead" DockPanel.Dock="Top" Style="{DynamicResource Schedule.TableHead}"/>
            <TextBlock x:Name="RoutineNote" DockPanel.Dock="Bottom" Style="{DynamicResource Table.Empty}" Visibility="Collapsed"/>
            <Grid><ListBox x:Name="RoutineList" Style="{DynamicResource Schedule.RoutineList}"/><TextBlock x:Name="RoutineEmpty" Style="{DynamicResource Table.Empty}" VerticalAlignment="Top" Visibility="Collapsed"/></Grid>
          </DockPanel>
        </Grid>
      </DockPanel>
    </DockPanel>
  </Border>
  <Grid x:Name="Side" Grid.Column="1" Style="{DynamicResource Schedule.Side}"/>
</Grid>
"@
    $root = ConvertFrom-WtXaml $xaml
    $script:view = Get-WtNamedElements $root $xaml
    $script:view.Root = $root; $script:cells = @(); $script:form = $null
    # 머리줄: 「2026년 11월 ⌄」을 누르면 해 · 달 고르기(그 안에 「오늘」). 달력 칸에서는 PageUp · PageDown으로 달을 옮긴다.
    # ‹ 오늘 ›는 표 보기에만 둔다(2026-11-05 승호). 오른쪽 Nav 자리는 찾기 · 깔때기 · 보기 전환(3단계, Initialize-WtScheduleHeader)
    $script:picker = New-WtMonthPicker $script:view.MonthPopup { param([datetime]$Month) $script:month = $Month; Update-WtScheduleView } -OnToday { Set-WtScheduleDate ([datetime]::Today) }
    $script:view.MonthButton.Add_Click({ Open-WtMonthPicker $script:picker $script:month })
    $script:view.Days.Add_PreviewKeyDown({
        param($s, $e)
        $step = Get-WtPageStep $e.Key
        if (-not $step) { return }
        $e.Handled = $true
        $script:month = $script:month.AddMonths($step); Update-WtScheduleView
        $first = @($script:cells | Where-Object { $_.Button.DataContext -eq $script:month })[0]
        if ($first) { [void]$first.Button.Focus() }
    })
    foreach ($name in '일', '월', '화', '수', '목', '금', '토') {
        $text = New-WtText $name 'Schedule.Weekday'
        if ($name -eq '일') { Set-WtResource $text Foreground 'B.Cal.Holiday' }
        if ($name -eq '토') { Set-WtResource $text Foreground 'B.Cal.Saturday' }
        [void]$script:view.Week.Children.Add($text)
    }
    for ($i = 0; $i -lt 42; $i++) {
        $cell = @{}; $cell.Button = [Windows.Controls.Button]::new(); Set-WtStyle $cell.Button 'Schedule.Day'
        $col = New-WtStack; $head = [Windows.Controls.Grid]::new(); Set-WtStyle $head 'Schedule.DayHead'
        $cell.Circle = [Windows.Controls.Border]::new(); Set-WtStyle $cell.Circle 'Schedule.DateCircle'
        $cell.Number = New-WtText '' 'Schedule.Date'; $cell.Circle.Child = $cell.Number
        # 휴무일 이름은 날짜 오른쪽(머리 줄 안)에 둔다. 아래에 두면 그 칸만 칩이 내려가 여러 날 막대와 어긋난다
        $cell.Holiday = New-WtText '' 'Schedule.Holiday'
        [void]$head.Children.Add($cell.Circle); [void]$head.Children.Add($cell.Holiday); [void]$col.Children.Add($head)
        $cell.Chips = @()
        for ($j = 0; $j -lt 2; $j++) {
            $chip = [Windows.Controls.Border]::new(); Set-WtStyle $chip 'Schedule.Chip'
            $chip.Child = New-WtText '' 'Schedule.ChipText'; $cell.Chips += $chip; [void]$col.Children.Add($chip)
        }
        $cell.More = New-WtText '' 'Schedule.More'; [void]$col.Children.Add($cell.More)
        $cell.Button.Content = $col; $cell.Button.Add_Click({ param($s, $e) Set-WtScheduleDate $s.DataContext })
        $cell.Button.ContextMenu = New-WtContextMenu
        $cell.Button.Add_ContextMenuOpening({ param($s, $e) Update-WtScheduleDayMenu $s })
        [void]$script:view.Days.Children.Add($cell.Button); $script:cells += $cell
    }
    $script:detail = [Windows.Controls.ContentControl]::new()
    $side = New-WtSidePanel -Side Right -Key 'schedule.sidebarCollapsed' -Title '일정' -Width 288 -Content $script:detail
    $script:side = @{ Root = $side }
    foreach ($name in 'Expanded', 'Rail', 'Header', 'Title', 'Open', 'Collapse') { $script:side[$name] = $side.FindName($name) }
    $add = New-WtButton '' -Kind Icon -Icon 0xE710 -ToolTip '새로 만들기'; Set-WtStyle $add 'Schedule.Add'
    [Windows.Automation.AutomationProperties]::SetName($add, '새로 만들기')
    [Windows.Controls.DockPanel]::SetDock($add, 'Right'); $script:side.Header.Children.Insert(1, $add); $script:side.Add = $add
    $menu = New-WtHomePinContextMenu
    foreach ($name in '새 일정', '새 루틴') {
        $item = [Windows.Controls.MenuItem]::new(); $item.Header = $name; $item.Tag = $name
        $item.Add_Click({ param($s, $e) Show-WtScheduleForm -Kind $(if ($s.Tag -eq '새 일정') { 'event' } else { 'routine' }) })
        [void]$menu.Items.Add($item)
    }
    $add.ContextMenu = $menu
    $add.Add_Click({ param($s, $e) $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.Placement = 'Bottom'; $s.ContextMenu.IsOpen = $true })
    [void]$script:view.Side.Children.Add($side)
    $mode = [string](Get-WtSetting 'schedule.view')
    $script:viewMode = if ($mode -cin $script:viewModes) { $mode } else { 'calendar' }
    Initialize-WtScheduleHeader
    Initialize-WtScheduleLists
    $root
}

# ---- 3단계 머리줄 · 표 · 할 일 · 루틴 보기 (설계 14장, 디자인 README 「일정」) ---------------------------------

# 메뉴 안의 묶음 이름(누를 수 없는 줄)
function New-WtScheduleMenuCaption([string]$Text) {
    $item = [Windows.Controls.MenuItem]::new(); $item.Header = $Text; $item.IsEnabled = $false; $item
}

# 오른쪽: 찾기 칸 · 깔때기 · 보기 전환 [할 일 n | 달력 | 표 | 루틴]. 왼쪽 표 보기의 ‹ 오늘 ›
function Initialize-WtScheduleHeader {
    $v = $script:view
    $script:search = New-WtSearchBox '찾기' -Compact; Set-WtStyle $script:search.Root 'Schedule.Search'
    [Windows.Automation.AutomationProperties]::SetName($script:search.Box, '일정 찾기')
    [Windows.Automation.AutomationProperties]::SetAutomationId($script:search.Box, 'Schedule-Search')
    $script:searchTimer = [Windows.Threading.DispatcherTimer]::new(); $script:searchTimer.Interval = [timespan]::FromMilliseconds(120)
    $script:searchTimer.Add_Tick({ param($s, $e) $s.Stop(); Invoke-WtScheduleSearch })
    $script:search.Box.Add_TextChanged({ param($s, $e) if ($script:searchTimer) { $script:searchTimer.Stop(); $script:searchTimer.Start() } })
    $script:search.Box.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [Windows.Input.Key]::Escape -and $s.Text) { $e.Handled = $true; $s.Text = '' }
            elseif ($e.Key -eq [Windows.Input.Key]::Enter) { $e.Handled = $true; $script:searchTimer.Stop(); Invoke-WtScheduleSearch }
        })
    [void]$v.Nav.Children.Add($script:search.Root)
    $filter = New-WtButton '' -Kind Icon -Icon 0xE71C -ToolTip '조건 더하기'; Set-WtStyle $filter 'Schedule.Filter'
    [Windows.Automation.AutomationProperties]::SetName($filter, '조건 더하기'); [Windows.Automation.AutomationProperties]::SetAutomationId($filter, 'Schedule-Filter')
    $filter.ContextMenu = New-WtHomePinContextMenu
    $filter.Add_Click({ param($s, $e) Update-WtScheduleFilterMenu $s.ContextMenu; $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.Placement = 'Bottom'; $s.ContextMenu.IsOpen = $true })
    [void]$v.Nav.Children.Add($filter); $v.Filter = $filter
    $v.ViewTabs = @{}
    foreach ($spec in @(@('due', 0, '할 일'), @('calendar', 0xE787, '달력 보기'), @('table', 0xE8FD, '표 보기'), @('routines', 0xE8EE, '루틴 보기'))) {
        $tab = [Windows.Controls.RadioButton]::new(); $tab.GroupName = 'ScheduleView'; $tab.Tag = $spec[0]
        if ($spec[1]) {
            Set-WtStyle $tab 'Schedule.ViewTab'; $tab.Content = New-WtText ([string][char]$spec[1]) 'Schedule.ViewTabIcon'; $tab.ToolTip = $spec[2]
        } else {
            Set-WtStyle $tab 'Schedule.ViewTabText'
            $label = [Windows.Controls.TextBlock]::new(); $label.VerticalAlignment = 'Center'; $label.Inlines.Add([Windows.Documents.Run]::new($spec[2]))
            $count = [Windows.Documents.Run]::new(''); $count.SetResourceReference([Windows.Documents.TextElement]::FontSizeProperty, 'F.Caption')
            $count.SetResourceReference([Windows.Documents.TextElement]::ForegroundProperty, 'B.Text.Tertiary'); $label.Inlines.Add($count)
            $tab.Content = $label; $v.DueCount = $count
        }
        [Windows.Automation.AutomationProperties]::SetName($tab, $spec[2]); [Windows.Automation.AutomationProperties]::SetAutomationId($tab, "Schedule-View-$($spec[0])")
        $tab.Add_Checked({ param($s, $e) if (-not $script:viewSync) { Set-WtScheduleViewMode ([string]$s.Tag) } })
        [void]$v.Nav.Children.Add($tab); $v.ViewTabs[$spec[0]] = $tab
    }
    foreach ($spec in @(@(-1, 0xE76B, '이전 달 (PageUp)'), @(0, 0, '오늘'), @(1, 0xE76C, '다음 달 (PageDown)'))) {
        $button = if ($spec[1]) { New-WtButton '' -Kind Icon -Icon $spec[1] -ToolTip $spec[2] } else { New-WtButton '오늘' -ToolTip '이번 달 · 오늘로 가기' }
        Set-WtStyle $button $(if ($spec[1]) { 'Schedule.MonthMove' } else { 'Schedule.TodayButton' })
        [Windows.Automation.AutomationProperties]::SetName($button, $spec[2]); $button.Tag = $spec[0]
        $button.Add_Click({ param($s, $e) Move-WtScheduleTableMonth ([int]$s.Tag) })
        [void]$v.TableNav.Children.Add($button)
    }
}

# 표 · 루틴 보기의 머리 줄과 목록 동작(누르기 · 체크 · Enter · Space · PageUp/PageDown · 우클릭)
function Initialize-WtScheduleLists {
    $v = $script:view
    $head = [Windows.Controls.Grid]::new()
    foreach ($width in 40, 120, 80, 0, 140, 88) {
        $column = [Windows.Controls.ColumnDefinition]::new(); $column.Width = if ($width) { [Windows.GridLength]::new($width) } else { [Windows.GridLength]::new(1, 'Star') }
        $head.ColumnDefinitions.Add($column)
    }
    $i = 0
    foreach ($name in '', '날짜', '시각', '제목', '태그', '기한') {
        if ($name) { $text = New-WtText $name 'Table.HeadText'; [Windows.Controls.Grid]::SetColumn($text, $i); [void]$head.Children.Add($text) }
        $i++
    }
    $v.TableHead.Child = $head
    $routineHead = [Windows.Controls.Grid]::new()
    foreach ($width in 0, 220, 72, 72, 60) {
        $column = [Windows.Controls.ColumnDefinition]::new(); $column.Width = if ($width) { [Windows.GridLength]::new($width) } else { [Windows.GridLength]::new(1, 'Star') }
        $routineHead.ColumnDefinitions.Add($column)
    }
    $i = 0
    foreach ($name in '이름', '규칙', '시각', '오늘', '메모') {
        $text = New-WtText $name 'Table.HeadText'; [Windows.Controls.Grid]::SetColumn($text, $i)
        if ($i -eq 0) { $text.Margin = [Windows.Thickness]::new(30, 0, 12, 0) }   # 이름 앞 루틴 아이콘(12 + 6)만큼 들여 이름 글자와 맞춘다
        [void]$routineHead.Children.Add($text); $i++
    }
    $v.RoutineHead.Child = $routineHead
    [Windows.Automation.AutomationProperties]::SetName($v.TableList, '일정 표'); [Windows.Automation.AutomationProperties]::SetName($v.RoutineList, '루틴 목록')
    $list = $v.TableList
    # 체크 상자: 누른 줄의 회차 · 차례만 바꾸고 다시 그린다. 마우스 · Space · 화면 읽기(UIA Toggle) 모두 Checked/Unchecked로 온다.
    # 줄을 다시 쓰거나 가상화로 상자를 재활용할 때도 묶은 값(Done)이 들어오며 같은 일이 생기므로, 상자 값이 줄의 Done과 다를 때만 저장한다
    $onToggle = [Windows.RoutedEventHandler]{
        param($s, $e)
        $box = $e.OriginalSource
        if ($box -isnot [Windows.Controls.CheckBox] -or -not $box.DataContext -or $box.DataContext.IsHead -or $script:tableUpdating) { return }
        if ([bool]$box.IsChecked -eq [bool]$box.DataContext.Done) { return }
        $e.Handled = $true; Set-WtScheduleTableCheck $box.DataContext ([bool]$box.IsChecked)
    }
    $list.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent, $onToggle)
    $list.AddHandler([Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, $onToggle)
    # 줄을 누르면 편집 폼(묶음 머리는 접기 · 펴기). 체크 상자를 누른 것은 빼고, 이미 처리된 누름까지 받는다
    $list.AddHandler([Windows.UIElement]::MouseLeftButtonUpEvent, [Windows.Input.MouseButtonEventHandler]{
            param($s, $e)
            $node = $e.OriginalSource
            while ($node -and $node -isnot [Windows.Controls.ListBoxItem]) {
                if ($node -is [Windows.Controls.CheckBox]) { return }
                $node = if ($node -is [Windows.Media.Visual] -or $node -is [Windows.Media.Media3D.Visual3D]) { [Windows.Media.VisualTreeHelper]::GetParent($node) } else { [Windows.LogicalTreeHelper]::GetParent($node) }
            }
            if ($node) { Open-WtScheduleTableItem $node.DataContext }
        }, $true)
    $list.Add_PreviewKeyDown({
            param($s, $e)
            $item = $s.SelectedItem
            $step = Get-WtPageStep $e.Key
            if ($step -and $script:viewMode -ceq 'table' -and -not (Get-WtScheduleQueryText)) { $e.Handled = $true; Move-WtScheduleTableMonth $step; return }
            if (-not $item) { return }
            if ($e.Key -eq [Windows.Input.Key]::Enter) { $e.Handled = $true; Open-WtScheduleTableItem $item }
            elseif ($e.Key -eq [Windows.Input.Key]::Space) {
                $e.Handled = $true
                if ($item.IsHead) { Open-WtScheduleTableItem $item } elseif ($item.CanCheck) { Set-WtScheduleTableCheck $item (-not $item.Done) }
            }
        })
    $routines = $v.RoutineList
    $routines.AddHandler([Windows.UIElement]::MouseLeftButtonUpEvent, [Windows.Input.MouseButtonEventHandler]{
            param($s, $e)
            $node = $e.OriginalSource
            while ($node -and $node -isnot [Windows.Controls.ListBoxItem]) { $node = if ($node -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($node) } else { [Windows.LogicalTreeHelper]::GetParent($node) } }
            if ($node -and $node.DataContext) { Show-WtScheduleForm -Kind routine -Id ([string]$node.DataContext.Id) }
        }, $true)
    # 우클릭한 줄을 먼저 고른다(목록은 우클릭으로 고르지 않는다)
    $routines.Add_PreviewMouseRightButtonDown({
            param($s, $e)
            $node = $e.OriginalSource
            while ($node -and $node -isnot [Windows.Controls.ListBoxItem]) { $node = if ($node -is [Windows.Media.Visual]) { [Windows.Media.VisualTreeHelper]::GetParent($node) } else { [Windows.LogicalTreeHelper]::GetParent($node) } }
            if ($node) { $node.IsSelected = $true; [void]$node.Focus() }
        })
    $menu = New-WtHomePinContextMenu
    foreach ($name in '편집', '삭제') {
        $item = [Windows.Controls.MenuItem]::new(); $item.Header = $name; $item.Tag = $name
        $item.Add_Click({ param($s, $e) Invoke-WtScheduleRoutineAction ([string]$s.Tag) })
        [void]$menu.Items.Add($item)
    }
    $routines.ContextMenu = $menu
    $routines.Add_ContextMenuOpening({ param($s, $e) if (-not $s.SelectedItem) { $e.Handled = $true } })
    $routines.Add_PreviewKeyDown({
            param($s, $e)
            if (-not $s.SelectedItem) { return }
            if ($e.Key -eq [Windows.Input.Key]::Enter) { $e.Handled = $true; Invoke-WtScheduleRoutineAction '편집' }
            elseif ($e.Key -eq [Windows.Input.Key]::Delete) { $e.Handled = $true; Invoke-WtScheduleRoutineAction '삭제' }
        })
}

function Get-WtScheduleQueryText { if ($script:search) { ([string]$script:search.Box.Text).Trim() } else { '' } }

# 보기를 바꾸고 기억한다
function Set-WtScheduleViewMode([string]$Mode) {
    if ($Mode -cnotin $script:viewModes) { return }
    $script:viewMode = $Mode
    try { Set-WtSetting 'schedule.view' $Mode } catch { }
    Update-WtScheduleView
}

# 찾기 칸 글이 멈추면(120ms) 찾는다. 달력 · 루틴 보기에서 쓰면 표 보기로 바꾼다(결과는 줄 목록이다)
function Invoke-WtScheduleSearch {
    if (-not $script:view) { return }
    if ((Get-WtScheduleQueryText) -and $script:viewMode -cin 'calendar', 'routines') { Set-WtScheduleViewMode 'table'; return }
    Update-WtScheduleView
}

# 표 보기 ‹ 오늘 ›: 앞 · 뒤 달, 0이면 이번 달 · 오늘
function Move-WtScheduleTableMonth([int]$Step) {
    if ($Step -eq 0) { $script:selected = [datetime]::Today; $script:month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1); $script:form = $null }
    else { $script:month = $script:month.AddMonths($Step) }
    Update-WtScheduleView
}

# 머리줄: 보기마다 제목 · 단추를 맞춘다. 할 일 수는 보기 단추 숫자로 늘 보인다
function Update-WtScheduleHeader([string]$Title, [string]$Count) {
    $v = $script:view; $mode = $script:viewMode
    $script:viewSync = $true
    try { foreach ($key in @($v.ViewTabs.Keys)) { $v.ViewTabs[$key].IsChecked = $key -ceq $mode } } finally { $script:viewSync = $false }
    $monthShown = $mode -ceq 'calendar' -or ($mode -ceq 'table' -and -not $Title)
    $v.MonthButton.Visibility = if ($monthShown) { 'Visible' } else { 'Collapsed' }
    $v.TableNav.Visibility = if ($mode -ceq 'table' -and -not $Title) { 'Visible' } else { 'Collapsed' }
    $v.ViewTitle.Visibility = if ($monthShown) { 'Collapsed' } else { 'Visible' }
    if (-not $monthShown) {
        $v.ViewTitle.Inlines.Clear(); $v.ViewTitle.Inlines.Add([Windows.Documents.Run]::new($Title))
        if ($Count) { $run = [Windows.Documents.Run]::new("  $Count"); $run.SetResourceReference([Windows.Documents.TextElement]::ForegroundProperty, 'B.Text.Tertiary'); $v.ViewTitle.Inlines.Add($run) }
        [Windows.Automation.AutomationProperties]::SetName($v.ViewTitle, "$Title $Count".Trim())
    }
    Update-WtScheduleDueTab
}

# 보기 단추 「할 일 n」의 숫자(메뉴 개수와 같은 셈)
function Update-WtScheduleDueTab {
    $v = $script:view; if (-not $v -or -not $v.DueCount) { return }
    $dueCount = try { Get-WtScheduleDueCount } catch { $null }
    $v.DueCount.Text = if ($null -ne $dueCount) { "  $dueCount" } else { '' }
    $v.ViewTabs['due'].ToolTip = if ($null -ne $dueCount) { "할 일 $dueCount개 (기한 지남 · 오늘 · 마감 임박)" } else { '할 일' }
}

# 사이드바 · 홈에서 루틴을 체크한 뒤: 보고 있는 표 · 할 일 · 루틴 보기와 숫자를 맞춘다(사이드바 목록은 체크한 곳이 이미 다시 그림)
function Update-WtScheduleAfterRoutineCheck {
    if ($script:view) {
        if ($script:viewMode -ceq 'routines') { Update-WtScheduleRoutineView }
        elseif ($script:viewMode -cin 'due', 'table') { Update-WtScheduleTable }
        else { Update-WtScheduleDueTab }
    }
    if (Get-Command Update-WtNavBadges -ErrorAction Ignore) { Update-WtNavBadges }
}

# 표의 기간 글: 날짜만 「11월 3일 ~ 6일」(달 · 해가 바뀌면 그만큼 더 쓴다). 시각은 시각 칸에 있다
function Get-WtScheduleRangeText($Row) {
    $first = $Row.Start.Date; $last = $Row.LastDay
    $end = if ($last.Year -ne $first.Year) { $last.ToString('yyyy년 M월 d일', $script:inv) } elseif ($last.Month -ne $first.Month) { $last.ToString('M월 d일', $script:inv) } else { $last.ToString('d일', $script:inv) }
    "$($first.ToString('M월 d일', $script:inv)) ~ $end"
}

# 줄 → 표에 그릴 값. 할 일은 묶음 머리를 끼우고, 접은 묶음의 줄은 뺀다. 같은 날 둘째 줄부터 날짜를 비운다(여러 날은 늘 기간)
function ConvertTo-WtScheduleTableItems([object[]]$Rows, [switch]$Due) {
    $today = [datetime]::Today; $prev = $null; $group = $null
    $names = @{ overdue = '기한 지남'; today = '오늘'; soon = '마감 임박' }
    foreach ($row in @($Rows)) {
        if ($Due -and $row.Group -cne $group) {
            $group = $row.Group; $prev = $null
            $closed = $script:collapsed.Contains($group)
            [pscustomobject]@{ IsHead = $true; Group = $group; HeadName = $names[$group]; HeadCount = [string]@($Rows | Where-Object Group -CEQ $group).Count
                HeadGlyph = [string][char]$(if ($closed) { 0xE76C } else { 0xE70D }); Key = "head:$group"; Done = $false; CanCheck = $false; Row = $null
                DateText = ''; TimeText = ''; Title = $names[$group]; Tags = @(); DueText = ''; DueWarn = 'Collapsed'; DueStrong = $false
                RoutineShown = 'Collapsed'; MemoShown = 'Collapsed'; MemoCount = ''; Progress = ''; ProgressShown = 'Collapsed'; CheckTip = ''; CheckName = '' }
        }
        if ($Due -and $script:collapsed.Contains($row.Group)) { continue }
        $dateText = if ($row.Multi) { Get-WtScheduleRangeText $row } elseif ($Due -and $row.Group -ceq 'today') { '' } elseif ($prev -and $prev.Date -eq $row.Date -and -not $prev.Multi) { '' } else { Format-WtDate $row.Date 'M월 d일 ddd' }
        $timeText = if ($row.Kind -ceq 'routine') { if ($null -ne $row.Time) { $row.Start.ToString('HH:mm', $script:inv) } else { '' } } elseif ($row.AllDay) { '하루 종일' } else { $row.Start.ToString('HH:mm', $script:inv) }
        # $due로 쓰면 파라미터 -Due와 같은 변수다(PowerShell 변수는 대소문자를 가리지 않음)
        $dueInfo = Get-WtScheduleDue $row $today
        $memo = if (@($row.Links).Count) { @(Get-WtScheduleLinkRows @($row.Links) | Where-Object State -EQ 'ok').Count } else { 0 }
        $label = "$(if ($timeText -and $timeText -cne '하루 종일') { $timeText + ' ' })$($row.Title)"
        [pscustomobject]@{ IsHead = $false; Group = $row.Group; Key = $row.Key; Row = $row; Done = [bool]$row.Done; CanCheck = $true
            DateText = $dateText; TimeText = $timeText; Title = $row.Title; Tags = @($row.Tags | ForEach-Object { "#$_" }); DueText = $dueInfo.Text
            DueWarn = $(if ($dueInfo.Overdue) { 'Visible' } else { 'Collapsed' }); DueStrong = $dueInfo.Overdue -or $dueInfo.Text -ceq '오늘'
            RoutineShown = $(if ($row.Kind -ceq 'routine') { 'Visible' } else { 'Collapsed' }); MemoShown = $(if ($memo) { 'Visible' } else { 'Collapsed' }); MemoCount = [string]$memo
            Progress = [string]$row.Progress; ProgressShown = $(if ($row.Progress) { 'Visible' } else { 'Collapsed' })
            CheckTip = $(if ($row.Done) { '끝냄 풀기' } else { '끝냄으로 표시' }); CheckName = "$label 끝냄"; HeadName = ''; HeadCount = ''; HeadGlyph = '' }
        $prev = $row
    }
}

# 표 · 할 일 보기를 다시 그린다. 틀린 찾기 식은 앞 결과를 두고 찾기 칸에 이유를 보인다(메모 찾기와 같음)
function Update-WtScheduleTable {
    $v = $script:view; $query = Get-WtScheduleQueryText; $mode = $script:viewMode
    $result = $null; $problem = ''; $title = ''; $count = ''
    try {
        if ($mode -ceq 'due') {
            $result = Get-WtScheduleDueRows
            if ($query) {
                $parsed = ConvertFrom-WtScheduleQuery $query
                if ($parsed.Success) { $result.Rows = @($result.Rows | Where-Object { Test-WtScheduleRowMatch $parsed.Root $_ }) } else { $result = [pscustomobject]@{ Success = $false; Error = $parsed.Error } }
            }
            $title = '할 일'
        } elseif ($query) {
            $result = Find-WtScheduleRows $query; $title = '찾기 결과'
        } else { $result = Get-WtScheduleMonthRows $script:month }
    } catch { $problem = $_.Exception.Message }
    $box = $script:search.Box
    if ($result -and -not $result.Success) {
        Set-WtResource $box BorderBrush 'B.Status.Error.Icon'; $box.ToolTip = "찾기 식을 확인하세요. $($result.Error.Reason)"
        Update-WtScheduleHeader $title $(if ($title) { [string]@($script:tableItems | Where-Object { -not $_.IsHead }).Count } else { '' })
        return
    }
    $box.ClearValue([Windows.Controls.Control]::BorderBrushProperty); $box.ToolTip = $null
    $rows = if ($result) { @($result.Rows) } else { @() }
    # 할 일 제목의 숫자는 할 일 수와 같은 셈(안 끝낸 일정 + 오늘 차례가 남은 루틴, 시간마다는 루틴 하나)
    if ($title -ceq '찾기 결과') { $count = [string]$result.Count }
    elseif ($title) { $count = [string](@($rows | Where-Object { $_.Kind -ceq 'event' -and -not $_.Done }).Count + @($rows | Where-Object { $_.Kind -ceq 'routine' -and -not $_.RoutineDone } | ForEach-Object RoutineId | Select-Object -Unique).Count) }
    Update-WtScheduleHeader $title $count
    $items = @(ConvertTo-WtScheduleTableItems $rows -Due:($mode -ceq 'due'))
    $script:tableItems = $items
    $script:tableUpdating = $true
    try {
        $v.TableList.ItemsSource = $items
        $focus = if ($script:focusKey) { @($items | Where-Object { $_.Key -ceq $script:focusKey } | Select-Object -First 1) } else { @() }
        $target = if ($focus.Count) { $focus[0] } elseif ($mode -ceq 'due') { $null } else { @($items | Where-Object { -not $_.IsHead -and $_.Row.Date -ge [datetime]::Today } | Select-Object -First 1)[0] }
        if ($target) {
            $v.TableList.ScrollIntoView($target)
            if ($focus.Count) {
                $v.TableList.SelectedItem = $target; $v.TableList.UpdateLayout()
                $container = $v.TableList.ItemContainerGenerator.ContainerFromItem($target); if ($container) { [void]$container.Focus() }
            }
        }
    } finally { $script:tableUpdating = $false; $script:focusKey = $null }
    $v.TableEmpty.Text = if ($problem) { $problem } elseif ($mode -ceq 'due') { '할 일이 없습니다.' } elseif ($query) { '찾은 일정이 없습니다.' } else { '일정이 없습니다.' }
    $v.TableEmpty.Visibility = if ($problem -or -not $items.Count) { 'Visible' } else { 'Collapsed' }
    $notes = @(); if ($result -and $result.Truncated) { $notes += "결과가 많아 $($rows.Count)줄까지 보입니다. 조건을 더하세요." }
    if ($result) { $notes += @($result.Problems) }
    $v.TableNote.Text = ($notes -join ' '); $v.TableNote.Visibility = if ($notes.Count) { 'Visible' } else { 'Collapsed' }
}

# 표 줄을 누르거나 Enter: 묶음 머리면 접기 · 펴기, 일정 · 루틴이면 오른쪽 편집 폼
function Open-WtScheduleTableItem($Item) {
    if ($null -eq $Item -or $script:tableUpdating) { return }
    if ($Item.IsHead) {
        if (-not $script:collapsed.Remove([string]$Item.Group)) { [void]$script:collapsed.Add([string]$Item.Group) }
        $script:focusKey = $Item.Key; Update-WtScheduleTable; return
    }
    $row = $Item.Row
    $script:selected = $row.Date
    $script:side.Title.Text = Format-WtDate $script:selected 'M월 d일 dddd'
    if ($row.Kind -ceq 'event') { Show-WtScheduleForm -Kind event -Occurrence $row.Occurrence } else { Show-WtScheduleForm -Kind routine -Id $row.RoutineId }
}

# 표 · 할 일의 체크: 일정 회차는 event-log, 루틴 차례는 routine-log에 남긴다
function Set-WtScheduleTableCheck($Item, [bool]$Done) {
    $row = $Item.Row
    try {
        $result = if ($row.Kind -ceq 'event') { Set-WtEventCheck -Event $row.Occurrence.Entry.Id -Date (ConvertTo-WtDateText $row.Occurrence.Original) -Done $Done }
        else { Set-WtRoutineCheck -Routine $row.RoutineId -Slot $row.Slot -Done $Done }
        if (-not $result.Success) { throw $result.Reason }
    } catch { $script:view.TableNote.Text = "체크를 저장하지 못했습니다. $($_.Exception.Message)"; $script:view.TableNote.Visibility = 'Visible' }
    $script:focusKey = $row.Key
    Update-WtScheduleView
    if (Get-Command Update-WtNavBadges -ErrorAction Ignore) { Update-WtNavBadges }
}

# 루틴 규칙 글: 매일 · 평일 · 월 · 수 · 금 · 2시간마다 · 09:00 ~ 17:00 (+ 근무 요일만)
function Get-WtRoutineRuleText($Entry) {
    if ($Entry.State -ceq 'broken') { return '고칠 항목' }
    if ($Entry.State -ceq 'readonly') { return '새 버전의 루틴' }
    $names = @('', '월', '화', '수', '목', '금', '토', '일')
    $text = switch -CaseSensitive ($Entry.Freq) {
        'daily' { '매일' }
        'weekly' {
            $days = @($Entry.Days | Sort-Object -Unique)
            if (($days -join ',') -ceq '1,2,3,4,5') { '평일' } elseif ($days.Count -eq 7) { '매일' } else { (@($days | ForEach-Object { $names[$_] }) -join ' · ') }
        }
        'hourly' { "$($Entry.Every)시간마다 · $($Entry.From.ToString('hh\:mm', $script:inv)) ~ $($Entry.To.ToString('hh\:mm', $script:inv))" }
        default { [string]$Entry.Freq }
    }
    if ($Entry.WorkdaysOnly) { $text += ' · 근무 요일만' }
    $text
}

# 루틴 보기: 모든 루틴(지운 것 빼고), 시각 없는 것 → 시각순 → 제목. 오늘 진행은 끝낸 차례 수/전체
function Update-WtScheduleRoutineView {
    $v = $script:view; $problem = ''; $items = @()
    try {
        $entries = @(Get-WtRoutineEntries (Get-WtScheduleData).Store | Where-Object { $_.State -cne 'deleted' })
        $today = @{}
        try { foreach ($group in @(Get-WtRoutineSlots -Date ([datetime]::Today) | Group-Object { $_.Routine.Id })) { $today[$group.Name] = @($group.Group) } } catch { $problem = $_.Exception.Message }
        $items = @(foreach ($entry in $entries) {
                # 없는 키를 @()로 감싸면 @($null) 한 개가 된다. 오늘 차례가 없으면 빈 목록
                $slots = if ($today.ContainsKey($entry.Id)) { @($today[$entry.Id]) } else { @() }
                $timeKey = if ($entry.Freq -ceq 'hourly' -and $null -ne $entry.From) { $entry.From } elseif ($null -ne $entry.Time) { $entry.Time } else { $null }
                $memo = if (@($entry.Links).Count) { @(Get-WtScheduleLinkRows @($entry.Links) | Where-Object State -EQ 'ok').Count } else { 0 }
                [pscustomobject]@{ Id = $entry.Id; Title = $entry.Title; RuleText = Get-WtRoutineRuleText $entry
                    TimeText = $(if ($entry.Freq -cne 'hourly' -and $null -ne $entry.Time) { $entry.Time.ToString('hh\:mm', $script:inv) } else { '—' })
                    TodayText = $(if ($slots.Count) { "$(@($slots | Where-Object Done).Count)/$($slots.Count)" } else { '오늘 없음' }); TodayStrong = $slots.Count -gt 0
                    MemoShown = $(if ($memo) { 'Visible' } else { 'Collapsed' }); MemoCount = [string]$memo; Problem = $entry.State -cne 'ok'
                    SortTimed = $null -ne $timeKey; SortTime = $(if ($null -ne $timeKey) { $timeKey } else { [timespan]::Zero }) }
            }) | Sort-Object -Culture 'ko-KR' -Property SortTimed, SortTime, Title
    } catch { $problem = $_.Exception.Message }
    Update-WtScheduleHeader '루틴' ([string]@($items).Count)
    $v.RoutineList.ItemsSource = @($items)
    $v.RoutineEmpty.Text = if ($problem -and -not @($items).Count) { $problem } else { '루틴이 없습니다.' }
    $v.RoutineEmpty.Visibility = if (-not @($items).Count) { 'Visible' } else { 'Collapsed' }
    $v.RoutineNote.Text = if ($problem -and @($items).Count) { $problem } else { '' }
    $v.RoutineNote.Visibility = if ($v.RoutineNote.Text) { 'Visible' } else { 'Collapsed' }
}

function Invoke-WtScheduleRoutineAction([string]$Action) {
    $item = $script:view.RoutineList.SelectedItem
    if (-not $item) { return }
    if ($Action -ceq '편집') { Show-WtScheduleForm -Kind routine -Id ([string]$item.Id); return }
    $result = Set-WtRoutineDeleted -Id ([string]$item.Id)
    if (-not $result.Success) { $script:view.RoutineNote.Text = "루틴을 지우지 못했습니다. $($result.Reason)"; $script:view.RoutineNote.Visibility = 'Visible'; return }
    $script:form = $null; Update-WtScheduleView
}

# 깔때기: 상태 · 종류 · 태그(많이 쓴 순 8). 고르면 찾기 칸 글에 더하고, 이미 있으면 뺀다. 지금 식에 있는 조건은 앞에 ✓
function Update-WtScheduleFilterMenu($Menu) {
    $Menu.Items.Clear()
    $parsed = ConvertFrom-WtScheduleQuery (Get-WtScheduleQueryText)
    $present = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($parsed.Success) {
        $nodes = if ($parsed.Root.Kind -ceq 'and') { @($parsed.Root.Children) } else { @($parsed.Root) }
        foreach ($node in $nodes) {
            if ($node.Kind -ceq 'term') { [void]$present.Add("$($node.Field):$($node.Value)") }
            elseif ($node.Kind -ceq 'not' -and $node.Child.Kind -ceq 'term') { [void]$present.Add("-$($node.Child.Field):$($node.Child.Value)") }
        }
    }
    $add = { param([string]$Header, [string]$Key, [string]$Term)
        $item = [Windows.Controls.MenuItem]::new(); $on = $present.Contains($Key)
        $item.Header = if ($on) { "✓ $Header" } else { $Header }; $item.Tag = $Term
        $item.Add_Click({ param($s, $e) Switch-WtScheduleQueryTerm ([string]$s.Tag) })
        [void]$Menu.Items.Add($item)
    }
    [void]$Menu.Items.Add((New-WtScheduleMenuCaption '상태'))
    & $add '안 끝낸 것' 'is:open' 'is:open'; & $add '끝낸 것' 'is:done' 'is:done'
    [void]$Menu.Items.Add((New-WtScheduleMenuCaption '종류'))
    & $add '일정만' '-is:routine' '-is:routine'; & $add '루틴만' 'is:routine' 'is:routine'
    $data = Get-WtScheduleData
    $tags = @($data.Entries | Where-Object { $_.State -ceq 'ok' } | ForEach-Object { @($_.Tags) } | Where-Object { $_ } | Group-Object | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name | Select-Object -First 8)
    if ($tags.Count) {
        [void]$Menu.Items.Add((New-WtScheduleMenuCaption '태그'))
        foreach ($tag in $tags) { & $add "#$($tag.Name)" "tag:$($tag.Name)" "#$($tag.Name)" }
    }
}

# 찾기 칸 글에서 조건 하나를 넣거나 뺀다(낱말 단위). 태그는 #태그 · tag:태그 · tag:"태그"를 같은 조건으로 본다
function Switch-WtScheduleQueryTerm([string]$Term) {
    $box = $script:search.Box; $text = [string]$box.Text
    $spellings = @($Term)
    if ($Term.StartsWith('#')) { $name = $Term.Substring(1); $spellings += @("tag:$name", "tag:`"$name`"") }
    $found = $false
    foreach ($spelling in $spellings) {
        $pattern = '(?<=^|\s)' + [regex]::Escape($spelling) + '(?=\s|$)'
        if ([regex]::IsMatch($text, $pattern, 'IgnoreCase')) { $text = [regex]::Replace($text, $pattern, '', 'IgnoreCase'); $found = $true }
    }
    $text = ([regex]::Replace($text, '\s{2,}', ' ')).Trim()
    if (-not $found) { $text = ("$text $Term").Trim() }
    $box.Text = $text
    $script:searchTimer.Stop(); Invoke-WtScheduleSearch
}

# 날짜 칸 우클릭: 새 일정 · 새 루틴 · 휴무일로 지정(회사 · 개인) 또는 휴무일 해제. 휴무일은 코어(core\Calendar.psm1)에 저장한다
function Update-WtScheduleDayMenu($Button) {
    $menu = $Button.ContextMenu; $menu.Items.Clear(); $date = [datetime]$Button.DataContext
    foreach ($name in '새 일정', '새 루틴') {
        $item = [Windows.Controls.MenuItem]::new(); $item.Header = $name; $item.Tag = @{ Date = $date; Kind = $(if ($name -eq '새 일정') { 'event' } else { 'routine' }) }
        $item.Add_Click({ param($s, $e) Set-WtScheduleDate $s.Tag.Date; Show-WtScheduleForm -Kind $s.Tag.Kind })
        [void]$menu.Items.Add($item)
    }
    [void]$menu.Items.Add([Windows.Controls.Separator]::new())
    $holiday = Get-WtHolidayData
    $dateText = ConvertTo-WtDateText $date
    $here = @($holiday.Entries | Where-Object { $_.State -eq 'ok' -and $_.DateText -ceq $dateText })
    if ($here.Count) {
        $item = [Windows.Controls.MenuItem]::new(); $item.Header = '휴무일 해제'; $item.Tag = @{ Date = $dateText; Kinds = @($here.Kind | Select-Object -Unique); Name = '' }
        $item.Add_Click({ param($s, $e) Set-WtScheduleHoliday $s.Tag.Date $s.Tag.Kinds $false })
        [void]$menu.Items.Add($item)
    } else {
        $parent = [Windows.Controls.MenuItem]::new(); $parent.Header = '휴무일로 지정'
        foreach ($kind in @(@('company', '회사 휴무'), @('personal', '개인 휴무'))) {
            $item = [Windows.Controls.MenuItem]::new(); $item.Header = $kind[1]; $item.Tag = @{ Date = $dateText; Kinds = @($kind[0]); Name = $kind[1] }
            $item.Add_Click({ param($s, $e) Set-WtScheduleHoliday $s.Tag.Date $s.Tag.Kinds $true $s.Tag.Name })
            [void]$parent.Items.Add($item)
        }
        [void]$menu.Items.Add($parent)
    }
    if ($holiday.Error) {
        foreach ($item in @($menu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] -and [string]$_.Header -like '휴무일*' })) {
            $item.IsEnabled = $false; $item.ToolTip = $holiday.Error; [Windows.Controls.ToolTipService]::SetShowOnDisabled($item, $true)
        }
    }
}
function Set-WtScheduleHoliday([string]$Date, [string[]]$Kinds, [bool]$Enabled, [string]$Name = '') {
    try {
        foreach ($kind in $Kinds) {
            $result = Set-WtHolidayDate (Get-WtHolidayData).Store $Date $kind -Enabled $Enabled -Name $Name
            if (-not $result.Success) { throw $result.Reason }
        }
    } catch { Show-WtMessage "휴무일을 저장하지 못했습니다. $($_.Exception.Message)" 'WorkTool' 'Warning' }
    Update-WtScheduleView
}

function Set-WtScheduleDate([datetime]$Date) {
    $script:selected = $Date.Date; $script:month = [datetime]::new($Date.Year, $Date.Month, 1); $script:form = $null
    Update-WtScheduleView
}
# 달력 칩 글자. 끝낸 일정은 앞에 체크 표시(CheckMark E73E)를 붙인다. 색만으로 끝냄을 알리지 않게 한다
function Set-WtChipText($TextBlock, [string]$Text, [bool]$Done) {
    if (-not $Done) { $TextBlock.Text = $Text; return }
    $TextBlock.Inlines.Clear()
    $mark = [Windows.Documents.Run]::new([string][char]0xE73E); Set-WtStyle $mark 'Schedule.ChipMark'
    $TextBlock.Inlines.Add($mark); $TextBlock.Inlines.Add([Windows.Documents.Run]::new(' ' + $Text))
}
# 보이는 보기만 다시 그린다(달력 · 표 · 할 일 · 루틴). 오른쪽 사이드바는 어느 보기든 고른 날 목록 또는 편집 폼
function Update-WtScheduleView {
    if (-not $script:view) { return }
    $v = $script:view; $mode = $script:viewMode
    $v.CalendarHost.Visibility = if ($mode -ceq 'calendar') { 'Visible' } else { 'Collapsed' }
    $v.TableHost.Visibility = if ($mode -cin 'due', 'table') { 'Visible' } else { 'Collapsed' }
    $v.RoutineHost.Visibility = if ($mode -ceq 'routines') { 'Visible' } else { 'Collapsed' }
    $data = Get-WtScheduleData
    $v.Month.Text = $script:month.ToString('yyyy년 M월', $script:inv)
    [Windows.Automation.AutomationProperties]::SetName($v.MonthButton, "$($v.Month.Text), 해 · 달 고르기")
    switch ($mode) {
        'calendar' { Update-WtScheduleHeader '' ''; Update-WtScheduleCalendar $data }
        'routines' { Update-WtScheduleRoutineView }
        default { Update-WtScheduleTable }
    }
    $script:side.Title.Text = Format-WtDate $script:selected 'M월 d일 dddd'
    $script:side.Add.IsEnabled = -not [bool]$data.Error; $script:side.Add.ToolTip = if ($data.Error) { $data.Error } else { '새로 만들기' }
    if (-not $script:form) { Show-WtScheduleDay }
}
# 달력 보기: 42칸 · 칩 · 여러 날 막대
function Update-WtScheduleCalendar($data) {
    $start = $script:month.AddDays(-[int]$script:month.DayOfWeek)
    $count = [int]([math]::Ceiling(([int]$script:month.DayOfWeek + [datetime]::DaysInMonth($script:month.Year, $script:month.Month)) / 7.0) * 7)
    if ($count -lt 35) { $count = 35 }
    $rows = $count / 7
    $script:view.Days.Rows = $rows
    $days = Get-WtScheduleDays $data.Entries $start 42
    $doneKeys = try { Get-WtEventDone } catch { $null }
    $occurrences = @(Get-WtScheduleOccurrences $data.Entries $start $start.AddDays($count - 1))
    $segments = @(Get-WtScheduleLanes $occurrences $start $rows)
    $calendar = Get-WtCalendarItems $start $start.AddDays(41) -Exclude @('schedule')
    for ($i = 0; $i -lt 42; $i++) {
        $cell = $script:cells[$i]; $date = $start.AddDays($i); $items = @($calendar.Days[$i].Items)
        $cell.Button.Visibility = if ($i -lt $count) { 'Visible' } else { 'Collapsed' }; $cell.Button.DataContext = $date
        [Windows.Automation.AutomationProperties]::SetName($cell.Button, (ConvertTo-WtDateText $date))
        $mark = Get-WtCalendarMark $date $items
        Set-WtStyle $cell.Button $(if ($date -eq [datetime]::Today) { 'Schedule.Today' } elseif ($mark.DayOff) { 'Schedule.DayOff' } else { 'Schedule.Day' })
        $cell.Button.BorderThickness = [Windows.Thickness]::new($(if ($i % 7) { 1 } else { 0 }), $(if ($i -ge 7) { 1 } else { 0 }), 0, 0)  # 뒤 칸의 바탕이 앞 칸의 선을 덮지 않게 뒤 칸이 그린다.
        $cell.Button.Tag = if ($date -eq $script:selected) { 'Selected' } else { '' }; $cell.Number.Text = [string]$date.Day
        Set-WtResource $cell.Number Foreground $(if ($date -eq [datetime]::Today) { 'B.OnAccent' } elseif ($date.Month -ne $script:month.Month) { 'B.Text.Disabled' } elseif ($mark.Kind) { $mark.Fore } elseif ($date.DayOfWeek -eq [DayOfWeek]::Sunday) { 'B.Cal.Holiday' } elseif ($date.DayOfWeek -eq [DayOfWeek]::Saturday) { 'B.Cal.Saturday' } else { 'B.Text.Primary' })
        if ($date -eq [datetime]::Today) { Set-WtResource $cell.Circle Background 'B.Accent' }
        elseif ($mark.Kind -and $date.Month -eq $script:month.Month) { Set-WtResource $cell.Circle Background $mark.Back }
        else { $cell.Circle.ClearValue([Windows.Controls.Border]::BackgroundProperty) }
        Set-WtResource $cell.Number FontWeight $(if ($date -eq [datetime]::Today) { 'F.BodyStrong.Weight' } else { 'F.Body.Weight' })
        $work = @($items | Where-Object { $_.Kind -cin @('work', 'overtime', 'trip') })
        $reasons = @($items | Where-Object { $_.Kind -cin @('public', 'company', 'personal', 'leave') } | ForEach-Object Text)
        $cell.Circle.ToolTip = if ($work.Count) { @($work.Text) -join [Environment]::NewLine } elseif ($reasons.Count) { $reasons -join ' · ' } else { Format-WtDate $date 'dddd' }
        $holidays = @($items | Where-Object { $_.Kind -cin @('public', 'company', 'personal') } | ForEach-Object Text) -join ' · '
        $cell.Holiday.Text = $holidays; $cell.Holiday.ToolTip = $holidays; $cell.Holiday.Visibility = if ($holidays) { 'Visible' } else { 'Collapsed' }
        # 칩 자리 0 · 1: 여러 날 막대가 쓴 자리는 비워 두고(막대는 위 겹침 층에 그린다), 남은 자리에 근태 기록 → 하루 일정 순
        $row = [math]::Floor($i / 7); $col = $i % 7
        $here = @($segments | Where-Object { $_.Row -eq $row -and $_.A -le $col -and $_.B -ge $col })
        $taken = @($here | ForEach-Object Lane)
        $records = @($items | Where-Object { $_.Kind -cin @('leave', 'overtime') })
        $singles = @(@($days[$i]) | Where-Object { $null -ne $_ -and $_.LastDay -le $_.Start.Date })
        $lines = @($records) + @($singles)
        $plain = if ($mark.DayOff -or $date -eq [datetime]::Today) { 'B.Bg.Surface' } else { 'B.Bg.Subtle' }
        $used = 0; $last = -1
        for ($j = 0; $j -lt 2; $j++) {
            $chip = $cell.Chips[$j]
            if ($taken -contains $j) { $chip.Visibility = 'Hidden'; $last = $j; continue }
            if ($used -ge $lines.Count) { $chip.Visibility = 'Collapsed'; continue }
            $line = $lines[$used]; $used++; $last = $j; $chip.Visibility = 'Visible'
            if ($line.PSObject.Properties['Style']) {
                Set-WtChipText $chip.Child $line.Text $false; $chip.ToolTip = $line.Text
                Set-WtResource $chip Background "B.$($line.Style)Bg"; Set-WtResource $chip.Child Foreground "B.$($line.Style)"
            } else {
                $done = $null -ne $doneKeys -and $doneKeys.Contains($line.Key)
                Set-WtChipText $chip.Child (Get-WtScheduleLine $line) $done; $chip.ToolTip = Get-WtScheduleToolTip $line
                Set-WtResource $chip Background $plain; Set-WtResource $chip.Child Foreground $(if ($done) { 'B.Text.Tertiary' } else { 'B.Text.Primary' })
            }
        }
        # 막대 앞의 빈 자리는 막대 줄을 맞추려고 남기고(Hidden), 뒤에 아무것도 없는 빈 자리만 접는다
        for ($j = 0; $j -lt $last; $j++) { if ($cell.Chips[$j].Visibility -eq 'Collapsed') { $cell.Chips[$j].Visibility = 'Hidden' } }
        $hidden = @(@($lines | Select-Object -Skip $used) + @($here | Where-Object { $_.Lane -ge 2 } | ForEach-Object Occ))
        $cell.More.Text = if ($hidden.Count) { '+' + $hidden.Count } else { '' }
        $cell.More.ToolTip = @($hidden | ForEach-Object { if ($_.PSObject.Properties['Style']) { $_.Text } else { Get-WtScheduleLine $_ } }) -join [Environment]::NewLine
        $cell.More.Visibility = if ($hidden.Count) { 'Visible' } else { 'Collapsed' }
    }
    Update-WtScheduleBars $segments $rows $start $doneKeys
}
# 여러 날 막대 겹침 층. 주마다 줄(lane) 0 · 1을 7칸 격자로 놓고, 막대는 걸친 칸만큼 이어 그린다.
# 막대를 누르면 누른 자리의 날짜를 고른다(칸을 누른 것과 같다). 빈 곳은 아래 날짜 칸이 누름을 받는다
function Update-WtScheduleBars([object[]]$Segments, [int]$Rows, [datetime]$Start, $DoneKeys) {
    $bars = $script:view.Bars; $bars.Children.Clear(); $bars.RowDefinitions.Clear()
    for ($r = 0; $r -lt $Rows; $r++) { $bars.RowDefinitions.Add([Windows.Controls.RowDefinition]::new()) }
    foreach ($week in @($Segments | Where-Object { $_.Lane -lt 2 } | Group-Object Row)) {
        $row = [int]$week.Name
        $stack = New-WtStack; Set-WtStyle $stack 'Schedule.BarLanes'; [Windows.Controls.Grid]::SetRow($stack, $row)
        $maxLane = [int]($week.Group | Measure-Object Lane -Maximum).Maximum
        $lanes = @(for ($l = 0; $l -le $maxLane; $l++) {
                $grid = [Windows.Controls.Grid]::new(); Set-WtStyle $grid 'Schedule.BarLane'
                for ($c = 0; $c -lt 7; $c++) { $grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new()) }
                [void]$stack.Children.Add($grid); $grid
            })
        foreach ($seg in $week.Group) {
            $occ = $seg.Occ
            $done = $null -ne $DoneKeys -and $DoneKeys.Contains($occ.Key)
            $bar = [Windows.Controls.Border]::new()
            Set-WtStyle $bar $(if ($seg.FromPrev -and $seg.ToNext) { 'Schedule.BarMiddle' } elseif ($seg.FromPrev) { 'Schedule.BarFromPrev' } elseif ($seg.ToNext) { 'Schedule.BarToNext' } else { 'Schedule.Bar' })
            [Windows.Controls.Grid]::SetColumn($bar, $seg.A); [Windows.Controls.Grid]::SetColumnSpan($bar, $seg.B - $seg.A + 1)
            $text = New-WtText '' 'Schedule.ChipText'
            $label = if (-not $occ.AllDay -and -not $seg.FromPrev) { $occ.Start.ToString('HH:mm', $script:inv) + ' ' + $occ.Title } else { $occ.Title }
            Set-WtChipText $text $label $done
            if ($done) { Set-WtResource $text Foreground 'B.Text.Tertiary' }
            $bar.Child = $text; $bar.ToolTip = Get-WtScheduleToolTip $occ
            $bar.Tag = @{ Start = $Start.AddDays($row * 7); Lane = $lanes[$seg.Lane] }
            $bar.Add_MouseLeftButtonUp({
                param($s, $e)
                $lane = $s.Tag.Lane
                $col = [math]::Max(0, [math]::Min(6, [math]::Floor($e.GetPosition($lane).X / [math]::Max(1, $lane.ActualWidth / 7))))
                Set-WtScheduleDate $s.Tag.Start.AddDays($col)
            })
            [void]$lanes[$seg.Lane].Children.Add($bar)
        }
        [void]$bars.Children.Add($stack)
    }
}

function New-WtRoutineList([datetime]$Date) {
    $list = New-WtStack; $slots = @(Get-WtRoutineSlots -Date $Date)
    # 시각 없는 루틴 → 시각순 → 제목(설계 14.2). 시간마다는 보이는 차례의 시각으로 줄을 세운다
    $groups = @(foreach ($group in @($slots | Group-Object { $_.Routine.Id })) {
            $all = @($group.Group); $hourly = $all[0].Slot.Length -gt 10
            $shown = if (-not $hourly -or $Date.Date -lt [datetime]::Today) { $all } else {
                $next = @($all | Where-Object Next | Select-Object -First 1)
                if ($next.Count) { $next } else { @($all[-1]) }
            }
            $time = if ($hourly) { $shown[0].Slot.Substring(11) } else { [string]$all[0].Routine.Time }
            [pscustomobject]@{ All = $all; Hourly = $hourly; Shown = $shown; Timed = [bool]$time; Time = $time; Title = [string]$all[0].Routine.Title }
        }) | Sort-Object -Culture 'ko-KR' -Property Timed, Time, Title
    foreach ($entry in @($groups)) {
        $all = $entry.All; $hourly = $entry.Hourly; $shown = $entry.Shown
        foreach ($slot in @($shown)) {
            $row = [Windows.Controls.DockPanel]::new()
            if ($hourly) {
                $counter = New-WtText ("$(@($all | Where-Object Done).Count)/$($all.Count)") 'Schedule.RoutineCount'
                [Windows.Controls.DockPanel]::SetDock($counter, 'Right'); [void]$row.Children.Add($counter)
            }
            $linkCount = New-WtScheduleLinkCount @(Get-WtScheduleLinks $slot.Routine)
            if ($linkCount) { [Windows.Controls.DockPanel]::SetDock($linkCount, 'Right'); [void]$row.Children.Add($linkCount) }
            $check = [Windows.Controls.CheckBox]::new(); Set-WtStyle $check 'Checklist.Row'
            $label = $(if ($hourly) { $slot.Slot.Substring(11) + ' ' } elseif ($slot.Routine.Time) { [string]$slot.Routine.Time + ' ' }) + $slot.Routine.Title
            $check.Content = New-WtText $label 'Schedule.EventTitle'
            $binding = [Windows.Data.Binding]::new('Foreground'); $binding.Source = $check
            [void]$check.Content.SetBinding([Windows.Controls.TextBlock]::ForegroundProperty, $binding)
            $check.IsChecked = $slot.Done; [Windows.Automation.AutomationProperties]::SetName($check, $label)
            $check.ToolTip = $label
            $check.Tag = @{ Slot = $slot; Date = $Date; List = $list; Updating = $false }
            $onCheck = {
                param($s, $e)
                if ($s.Tag.Updating) { return }
                try {
                    $result = Set-WtRoutineCheck -Routine $s.Tag.Slot.Routine.Id -Slot $s.Tag.Slot.Slot -Done ([bool]$s.IsChecked)
                    if (-not $result.Success) { throw $result.Reason }
                    Update-WtRoutineList $s.Tag.List $s.Tag.Date
                    Update-WtScheduleAfterRoutineCheck
                } catch {
                    $s.Tag.Updating = $true
                    try { $s.IsChecked = -not $s.IsChecked; $s.ToolTip = $_.Exception.Message } finally { $s.Tag.Updating = $false }
                }
            }
            $check.Add_Checked($onCheck); $check.Add_Unchecked($onCheck)
            $menu = New-WtHomePinContextMenu
            foreach ($name in '편집', '삭제') {
                $item = [Windows.Controls.MenuItem]::new(); $item.Header = $name; $item.Tag = @{ Id = $slot.Routine.Id; Action = $name; Date = $Date; List = $list }
                $item.Add_Click({
                    param($s, $e)
                    if ($s.Tag.Action -eq '편집') {
                        if ($script:view -and $script:view.Root.IsVisible) { Show-WtScheduleForm -Kind routine -Id $s.Tag.Id }
                        else { Open-WtPage -Id schedule -Args @{ Date = $s.Tag.Date; RoutineId = $s.Tag.Id } }
                    } else {
                        $result = Set-WtRoutineDeleted -Id $s.Tag.Id
                        if ($result.Success) { Update-WtRoutineList $s.Tag.List $s.Tag.Date }
                    }
                })
                [void]$menu.Items.Add($item)
            }
            $check.ContextMenu = $menu; [void]$row.Children.Add($check); [void]$list.Children.Add($row)
        }
    }
    if (-not $slots.Count) { [void]$list.Children.Add((New-WtText '루틴 없음' 'T.Sub')) }
    $list
}
function Update-WtRoutineList($List, [datetime]$Date) {
    $replacement = New-WtRoutineList $Date; $List.Children.Clear()
    foreach ($child in @($replacement.Children)) {
        [void]$replacement.Children.Remove($child); [void]$List.Children.Add($child)
        foreach ($check in @($child.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] })) {
            $check.Tag.List = $List
            foreach ($item in $check.ContextMenu.Items) { $item.Tag.List = $List }
        }
    }
    if ($List.Tag) { $List.Tag.Head.Content = New-WtCardHeader $List.Tag.Title (Get-WtRoutineCount $Date) }
    if ($List.DataContext -is [Windows.Controls.Border] -and -not @(Get-WtRoutineSlots -Date $Date).Count) { $List.DataContext.Visibility = 'Collapsed' }
}
# 끝낸 루틴 수 / 전체. 시간마다 루틴은 그날 차례를 모두 끝내야 하나로 센다.
function Get-WtRoutineCount([datetime]$Date) {
    $groups = @(Get-WtRoutineSlots -Date $Date | Group-Object { $_.Routine.Id })
    if ($groups.Count) { "$(@($groups | Where-Object { -not @($_.Group | Where-Object { -not $_.Done }).Count }).Count)/$($groups.Count)" }
}
# 제목 · 개수 · 목록. 체크하면 Update-WtRoutineList가 개수까지 다시 쓴다.
function New-WtRoutineSection([string]$Title, [datetime]$Date) {
    $col = New-WtStack; $head = [Windows.Controls.ContentControl]::new(); $head.Focusable = $false
    $head.Content = New-WtCardHeader $Title (Get-WtRoutineCount $Date)
    $list = New-WtRoutineList $Date; $list.Tag = @{ Head = $head; Title = $Title }
    [void]$col.Children.Add($head); [void]$col.Children.Add($list)
    @{ Root = $col; List = $list }
}
function Show-WtScheduleDay {
    $script:form = $null
    $body = [Windows.Controls.DockPanel]::new(); Set-WtStyle $body 'Schedule.SideBody'
    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $col = New-WtStack; $data = Get-WtScheduleData
    if ($data.Error) { [void]$col.Children.Add((New-WtText $data.Error 'Schedule.Error')) }
    else {
        $occurrences = @((Get-WtScheduleDays $data.Entries $script:selected 1)[0])
        $doneKeys = $null; $doneError = ''
        try { $doneKeys = Get-WtEventDone } catch { $doneError = $_.Exception.Message }
        if ($doneError -and $occurrences.Count) { [void]$col.Children.Add((New-WtText $doneError 'Schedule.Error')) }
        foreach ($occurrence in $occurrences) { [void]$col.Children.Add((New-WtEventRow $occurrence $script:selected $doneKeys)) }
        if (-not $occurrences.Count) { [void]$col.Children.Add((New-WtText '일정 없음' 'T.Sub')) }
        $separator = [Windows.Controls.Border]::new(); Set-WtStyle $separator 'Schedule.Separator'; [void]$col.Children.Add($separator)
        try { [void]$col.Children.Add((New-WtRoutineSection '루틴' $script:selected).Root) } catch { [void]$col.Children.Add((New-WtText $_.Exception.Message 'Schedule.Error')) }
    }
    $scroll.Content = $col; [void]$body.Children.Add($scroll); $script:detail.Content = $body
}

# 시각 칸. 하루 종일 · 여러 날 일정의 사이 날은 「하루 종일」, 시각 있는 일정의 첫날은 시작 시각, 마지막 날은 「~끝 시각」
function Get-WtEventWhen($Occ, [datetime]$Day) {
    if ($Occ.AllDay) { return '하루 종일' }
    if ($Day.Date -le $Occ.Start.Date) { return $Occ.Start.ToString('HH:mm', $script:inv) }
    if ($Day.Date -ge $Occ.LastDay) { return '~' + $Occ.End.ToString('HH:mm', $script:inv) }
    '하루 종일'
}
# 여러 날 일정의 기간 줄. 하루짜리는 빈 글. 예: 「11월 3일 ~ 6일 · 3일째」, 「11월 5일 22:00 ~ 6일 02:00」
function Get-WtEventSpan($Occ, $Day) {
    if ($Occ.LastDay -le $Occ.Start.Date) { return '' }
    $last = $Occ.LastDay
    $endDay = if ($last.Year -ne $Occ.Start.Year) { $last.ToString('yyyy년 M월 d일', $script:inv) } elseif ($last.Month -ne $Occ.Start.Month) { $last.ToString('M월 d일', $script:inv) } else { $last.ToString('d일', $script:inv) }
    if ($Occ.AllDay) {
        $range = "$($Occ.Start.ToString('M월 d일', $script:inv)) ~ $endDay"
        if ($null -eq $Day) { return $range }
        return "$range · $((([datetime]$Day).Date - $Occ.Start.Date).Days + 1)일째"
    }
    "$($Occ.Start.ToString('M월 d일 HH:mm', $script:inv)) ~ $endDay $($Occ.End.ToString('HH:mm', $script:inv))"
}

# 오른쪽 목록의 일정 줄: 체크 상자 + [시각 · 제목](누르면 편집 폼). 체크는 회차마다 event-log.json에 남는다(ScheduleData)
function New-WtEventRow($Occ, [datetime]$Day, $DoneKeys) {
    $done = $null -ne $DoneKeys -and $DoneKeys.Contains($Occ.Key)
    $label = Get-WtScheduleLine $Occ
    $row = [Windows.Controls.DockPanel]::new()
    $check = [Windows.Controls.CheckBox]::new(); Set-WtStyle $check 'Schedule.EventCheck'
    $check.IsChecked = $done; $check.IsEnabled = $null -ne $DoneKeys
    $check.ToolTip = if ($null -eq $DoneKeys) { '체크 기록을 읽지 못했습니다.' } elseif ($done) { '끝냄 풀기' } else { '끝냄으로 표시' }
    [Windows.Automation.AutomationProperties]::SetName($check, "$label 끝냄")
    [Windows.Automation.AutomationProperties]::SetAutomationId($check, "Schedule-Check-$($Occ.Key)")
    $check.Tag = @{ Occ = $Occ; Updating = $false }
    $check.Add_Checked({ param($s, $e) Set-WtScheduleCheck $s }); $check.Add_Unchecked({ param($s, $e) Set-WtScheduleCheck $s })
    if ($script:focusKey -and $script:focusKey -ceq $Occ.Key) { $script:focusKey = $null; $check.Add_Loaded({ param($s, $e) [void]$s.Focus() }) }
    [Windows.Controls.DockPanel]::SetDock($check, 'Left'); [void]$row.Children.Add($check)
    $button = New-WtButton ''; Set-WtStyle $button 'Schedule.EventRow'
    $content = [Windows.Controls.DockPanel]::new(); Set-WtStyle $content 'Schedule.EventBody'
    $when = New-WtText (Get-WtEventWhen $Occ $Day) 'Schedule.EventTime'; [Windows.Controls.DockPanel]::SetDock($when, 'Left'); [void]$content.Children.Add($when)
    $linkCount = New-WtScheduleLinkCount @(Get-WtScheduleLinks $Occ.Entry $Occ.Original)
    if ($linkCount) { [Windows.Controls.DockPanel]::SetDock($linkCount, 'Right'); [void]$content.Children.Add($linkCount) }
    $text = New-WtStack; $title = New-WtText $Occ.Title 'Schedule.EventTitle'; [void]$text.Children.Add($title)
    if ($done) { Set-WtResource $title Foreground 'B.Text.Tertiary' }
    $span = Get-WtEventSpan $Occ $Day
    if ($span) { [void]$text.Children.Add((New-WtText $span 'Schedule.EventSub')) }
    [void]$content.Children.Add($text)
    $button.Content = $content; $button.Tag = $Occ; $button.ToolTip = Get-WtScheduleToolTip $Occ
    [Windows.Automation.AutomationProperties]::SetName($button, $label)
    $button.Add_Click({ param($s, $e) Show-WtScheduleForm -Kind event -Occurrence $s.Tag })
    [void]$row.Children.Add($button)
    $row
}
function Set-WtScheduleCheck($Check) {
    if ($Check.Tag.Updating) { return }
    $occ = $Check.Tag.Occ
    try {
        $result = Set-WtEventCheck -Event $occ.Entry.Id -Date (ConvertTo-WtDateText $occ.Original) -Done ([bool]$Check.IsChecked)
        if (-not $result.Success) { throw $result.Reason }
        $script:focusKey = $occ.Key
        Update-WtScheduleView
        if (Get-Command Update-WtNavBadges -ErrorAction Ignore) { Update-WtNavBadges }
    } catch {
        $Check.Tag.Updating = $true
        try { $Check.IsChecked = -not $Check.IsChecked; $Check.ToolTip = $_.Exception.Message } finally { $Check.Tag.Updating = $false }
    }
}

function Add-WtScheduleField([string]$Key, [string]$Label, $Control) {
    $field = New-WtStack; Set-WtStyle $field 'Schedule.Field'
    if ($Label) { [void]$field.Children.Add((New-WtText $Label 'Schedule.FieldLabel')) }
    [void]$field.Children.Add($Control); $errorText = New-WtText '' 'Schedule.Error'; $errorText.Visibility = 'Collapsed'; [void]$field.Children.Add($errorText)
    [Windows.Automation.AutomationProperties]::SetName($Control, $(if ($Label) { $Label } else { [string]$Control.Content }))
    [Windows.Automation.AutomationProperties]::SetAutomationId($Control, "Schedule-$Key")
    $script:form.Fields[$Key] = $Control; $script:form.Errors[$Key] = $errorText; $script:form.Rows[$Key] = $field; [void]$script:form.Panel.Children.Add($field)
}
# 「시작 ~ 끝」 두 칸을 한 줄에 둔다(날짜 · 시각). 칸마다 이름과 자동화 id를 따로 단다. 오류는 같은 줄 아래에 쓴다
function Add-WtScheduleRange([string]$Key, [string]$EndKey, [string]$Label, [string]$From, [string]$To, [string]$FromName, [string]$ToName) {
    $grid = [Windows.Controls.Grid]::new()
    foreach ($width in 'Star', 'Auto', 'Star') {
        $column = [Windows.Controls.ColumnDefinition]::new()
        $column.Width = if ($width -eq 'Auto') { [Windows.GridLength]::Auto } else { [Windows.GridLength]::new(1, 'Star') }
        $grid.ColumnDefinitions.Add($column)
    }
    $fromBox = New-WtScheduleInput $From; $toBox = New-WtScheduleInput $To; $dash = New-WtText '~' 'Schedule.RangeDash'
    [Windows.Controls.Grid]::SetColumn($dash, 1); [Windows.Controls.Grid]::SetColumn($toBox, 2)
    foreach ($child in $fromBox, $dash, $toBox) { [void]$grid.Children.Add($child) }
    Add-WtScheduleField $Key $Label $grid
    [Windows.Automation.AutomationProperties]::SetAutomationId($grid, "Schedule-$Key-range")
    [Windows.Automation.AutomationProperties]::SetName($fromBox, $FromName); [Windows.Automation.AutomationProperties]::SetAutomationId($fromBox, "Schedule-$Key")
    [Windows.Automation.AutomationProperties]::SetName($toBox, $ToName); [Windows.Automation.AutomationProperties]::SetAutomationId($toBox, "Schedule-$EndKey")
    $f = $script:form
    $f.Fields[$Key] = $fromBox; $f.Fields[$EndKey] = $toBox; $f.Errors[$EndKey] = $f.Errors[$Key]; $f.Rows[$EndKey] = $f.Rows[$Key]
}
function New-WtScheduleInput([string]$Value) { $inputBox = [Windows.Controls.TextBox]::new(); Set-WtStyle $inputBox Input; $inputBox.Text = $Value; $inputBox }
function New-WtScheduleCombo([string[]]$Values, [string]$Selected) {
    $comboBox = [Windows.Controls.ComboBox]::new(); Set-WtStyle $comboBox Combo
    foreach ($value in $Values) { [void]$comboBox.Items.Add($value) }; $comboBox.SelectedItem = $Selected; $comboBox
}
function New-WtScheduleCheck([string]$Label, [bool]$Checked) {
    $checkBox = [Windows.Controls.CheckBox]::new(); Set-WtStyle $checkBox Check; $checkBox.Content = $Label; $checkBox.IsChecked = $Checked; $checkBox
}
# ---- 관련 메모 (2단계, 설계 13장). 다른 탭은 코어 등록 목록(Get-WtRelatedSource)으로만 부른다 ----

# 연결 → 화면 줄 정보. 출처마다 Find를 한 번 부른다. State: ok · missing(지운 항목) · off(꺼진 탭) · error(읽지 못함)
function Get-WtScheduleLinkRows([object[]]$Links) {
    $Links = @($Links | Where-Object { $_ -and $_.Page -and $_.Key })
    $sources = @{}; foreach ($s in @(Get-WtRelatedSource)) { $sources[$s.Page] = $s }
    $found = @{}; $failed = @{}
    foreach ($page in @($Links | ForEach-Object Page | Select-Object -Unique)) {
        $found[$page] = @{}
        if (-not $sources.ContainsKey($page)) { continue }
        try {
            foreach ($hit in @(& $sources[$page].Find ([string[]]@($Links | Where-Object Page -CEQ $page | ForEach-Object Key)))) {
                if ($hit -and $hit.Key) { $found[$page][[string]$hit.Key] = $hit }
            }
        } catch { $failed[$page] = $_.Exception.Message }
    }
    foreach ($l in @($Links)) {
        $src = $sources[$l.Page]; $hit = if ($found.ContainsKey($l.Page)) { $found[$l.Page][$l.Key] } else { $null }
        $state = if (-not $src) { 'off' } elseif ($failed.ContainsKey($l.Page)) { 'error' } elseif (-not $hit -or $hit.Missing) { 'missing' } else { 'ok' }
        $title = if ($hit -and $hit.Title) { [string]$hit.Title } elseif ($state -eq 'off') { '꺼진 탭의 항목' } else { $l.Key }
        [pscustomobject]@{ Link = $l; Source = $src; State = $state; Title = $title; Sub = $(if ($hit) { [string]$hit.Sub } else { '' }); Reason = [string]$failed[$l.Page] }
    }
}

# 일정 · 루틴 줄 끝의 관련 메모 수(아이콘 12 + 숫자). 지운 항목 · 꺼진 탭은 세지 않는다. 없으면 $null
function New-WtScheduleLinkCount([object[]]$Links) {
    if (-not @($Links).Count) { return $null }
    $rows = @(Get-WtScheduleLinkRows $Links | Where-Object State -EQ 'ok')
    if (-not $rows.Count) { return $null }
    $box = New-WtStack Horizontal; Set-WtStyle $box 'Schedule.LinkCount'
    $icon = New-WtText ([string][char]$(if ($rows[0].Source.Icon) { $rows[0].Source.Icon } else { 0xE70B })) 'Schedule.LinkCountIcon'
    [void]$box.Children.Add($icon); [void]$box.Children.Add((New-WtText ([string]$rows.Count) 'Schedule.LinkCountText'))
    $box.ToolTip = (@($rows | ForEach-Object Title) -join [Environment]::NewLine)
    [Windows.Automation.AutomationProperties]::SetName($box, "관련 항목 $($rows.Count)개")
    $box
}

function Set-WtScheduleLinkError([string]$Message) {
    $f = $script:form; if (-not $f -or -not $f.LinkError) { return }
    $f.LinkError.Text = $Message; $f.LinkError.Visibility = if ($Message) { 'Visible' } else { 'Collapsed' }
}

# 폼 맨 아래 「관련 메모 n」: 줄 · 우클릭 · [새 메모 ⌄] · [기존 메모 고르기]. 붙이기 · 빼기 뒤에 이 함수로 다시 그린다
function Update-WtScheduleLinks {
    $f = $script:form; if (-not $f -or -not $f.LinkBox) { return }
    $box = $f.LinkBox; $box.Children.Clear()
    $sources = @(Get-WtRelatedSource)
    if (-not $sources.Count) { $box.Visibility = 'Collapsed'; return }
    $box.Visibility = 'Visible'
    $links = @(); $readError = ''
    if ($f.Id) { try { $links = @(Get-WtScheduleItemLinks $f.Id $f.LinkDate) } catch { $readError = $_.Exception.Message } }
    $rows = @(Get-WtScheduleLinkRows $links)
    $label = if ($sources.Count -eq 1) { "관련 $($sources[0].Name)" } else { '관련 항목' }
    $head = New-WtText $label 'Schedule.LinkHead'
    $count = [Windows.Documents.Run]::new("  $(@($rows | Where-Object State -EQ 'ok').Count)")
    $count.SetResourceReference([Windows.Documents.TextElement]::ForegroundProperty, 'B.Text.Tertiary'); $head.Inlines.Add($count)
    [void]$box.Children.Add($head)
    foreach ($row in $rows) {
        $button = New-WtButton ''; Set-WtStyle $button 'Schedule.LinkRow'
        $body = [Windows.Controls.DockPanel]::new(); Set-WtStyle $body 'Schedule.LinkBody'
        $glyph = if ($row.Source -and $row.Source.Icon) { $row.Source.Icon } else { 0xE70B }
        $icon = New-WtText ([string][char]$glyph) 'Schedule.LinkIcon'; [Windows.Controls.DockPanel]::SetDock($icon, 'Left'); [void]$body.Children.Add($icon)
        $name = if ($row.Source) { $row.Source.Name } else { '항목' }
        $scopeText = switch ($row.State) {
            'off' { '꺼진 탭' }; 'missing' { "지운 $name" }; 'error' { '읽지 못함' }
            default { if ($f.Repeat) { if ($row.Link.Date) { '이 회차' } else { '모든 회차' } } else { '' } }
        }
        $scope = New-WtText $scopeText 'Schedule.LinkScope'; [Windows.Controls.DockPanel]::SetDock($scope, 'Right'); [void]$body.Children.Add($scope)
        $title = New-WtText $row.Title 'Schedule.LinkTitle'; [void]$body.Children.Add($title)
        if ($row.State -ne 'ok') { Set-WtResource $title Foreground 'B.Text.Disabled'; Set-WtResource $icon Foreground 'B.Text.Disabled' }
        $button.Content = $body; $button.Tag = $row
        $button.ToolTip = if ($row.State -eq 'error') { $row.Reason } elseif ($row.Sub) { "$($row.Title)$([Environment]::NewLine)$($row.Sub)" } else { $row.Title }
        [Windows.Automation.AutomationProperties]::SetName($button, "$($row.Title) $scopeText".Trim())
        [Windows.Automation.AutomationProperties]::SetAutomationId($button, "Schedule-Link-$($row.Link.Page)-$($row.Link.Key)")
        $button.Add_Click({ param($s, $e) if ($s.Tag.State -eq 'ok') { Invoke-WtScheduleLinkAction 'window' $s.Tag } })
        $menu = New-WtHomePinContextMenu
        # if 식으로 받으면 원소 하나짜리 목록이 풀리므로 분기 안에서 대입한다
        if ($row.State -eq 'ok') { $actions = @(@('window', '새 창으로 보기'), @('open', "$name 탭에서 열기"), '-', @('remove', '연결 빼기')) } else { $actions = @(, @('remove', '연결 빼기')) }
        foreach ($a in $actions) {
            if ($a -is [string]) { [void]$menu.Items.Add([Windows.Controls.Separator]::new()); continue }
            $item = [Windows.Controls.MenuItem]::new(); $item.Header = $a[1]; $item.Tag = @{ Action = $a[0]; Row = $row }
            $item.Add_Click({ param($s, $e) Invoke-WtScheduleLinkAction $s.Tag.Action $s.Tag.Row }); [void]$menu.Items.Add($item)
        }
        $button.ContextMenu = $menu
        [void]$box.Children.Add($button)
    }
    $bar = New-WtStack Horizontal 8; Set-WtStyle $bar 'Schedule.LinkButtons'
    $why = if ($f.Kind -eq 'routine') { '루틴을 먼저 저장하세요.' } else { '일정을 먼저 저장하세요.' }
    foreach ($src in $sources) {
        $templates = @($src.Templates)
        $new = New-WtButton "새 $($src.Name)"
        if ($templates.Count -gt 1) {
            $content = New-WtStack Horizontal; $label = [Windows.Controls.TextBlock]::new(); $label.Text = "새 $($src.Name)"; $label.VerticalAlignment = 'Center'
            [void]$content.Children.Add($label); [void]$content.Children.Add((New-WtText ([string][char]0xE70D) 'Schedule.LinkChevron')); $new.Content = $content
            $menu = New-WtHomePinContextMenu
            foreach ($t in $templates) {
                $item = [Windows.Controls.MenuItem]::new(); $item.Header = $t.Name; $item.Tag = @{ Source = $src; Template = $t.Id }
                $item.Add_Click({ param($s, $e) Invoke-WtScheduleLinkNew $s.Tag.Source $s.Tag.Template }); [void]$menu.Items.Add($item)
            }
            $new.ContextMenu = $menu
            $new.Add_Click({ param($s, $e) $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.Placement = 'Bottom'; $s.ContextMenu.IsOpen = $true })
        } else {
            $new.Tag = @{ Source = $src; Template = $templates[0].Id }
            $new.Add_Click({ param($s, $e) Invoke-WtScheduleLinkNew $s.Tag.Source $s.Tag.Template })
        }
        $pick = New-WtButton "기존 $($src.Name) 고르기"; $pick.Tag = $src
        $pick.Add_Click({ param($s, $e) Invoke-WtScheduleLinkPick $s.Tag })
        foreach ($b in $new, $pick) {
            [Windows.Automation.AutomationProperties]::SetName($b, $(if ($b -eq $new) { "새 $($src.Name)" } else { "기존 $($src.Name) 고르기" }))
            [Windows.Automation.AutomationProperties]::SetAutomationId($b, "Schedule-Link$(if ($b -eq $new) { 'New' } else { 'Pick' })-$($src.Page)")
            if (-not $f.Id) { $b.IsEnabled = $false; $b.ToolTip = $why; [Windows.Controls.ToolTipService]::SetShowOnDisabled($b, $true) }
            [void](Add-WtChild $bar $b)
        }
    }
    [void]$box.Children.Add($bar)
    $f.LinkError = New-WtText '' 'Schedule.Error'; $f.LinkError.Visibility = 'Collapsed'; [void]$box.Children.Add($f.LinkError)
    if ($readError) { Set-WtScheduleLinkError $readError }
}

# 붙이기 · 빼기는 바로 저장하고 폼의 핸들을 새 핸들로 바꾼다(폼 [저장]이 낡은 핸들로 거부되지 않게, 설계 13.3).
# 다시 그리면서 파일을 다시 읽으면 그 전 핸들은 낡으므로(1.9) 다시 그린 뒤의 핸들을 받는다
function Set-WtScheduleLinkResult($Result) {
    if (-not $Result.Success) { throw $Result.Reason }
    $script:form.Store = $Result.Store
    Update-WtScheduleLinks
    $data = Get-WtScheduleData
    if (-not $data.Error) { $script:form.Store = $data.Store }
}
function Invoke-WtScheduleLinkNew($Source, [string]$Template) {
    $f = $script:form; if (-not $f -or -not $f.Id) { return }
    try {
        $subject = $f.Fields.title.Text.Trim(); if (-not $subject) { $subject = $f.LinkSubject }
        $day = if ($f.LinkDate) { ConvertFrom-WtDateText $f.LinkDate } else { $script:selected }
        $seed = @{ Template = $Template; Title = "$($day.ToString('MM-dd', $script:inv)) $subject"; Subject = $subject }
        $key = [string](@(& $Source.New $seed) | Select-Object -Last 1)
        if (-not $key) { throw "새 $($Source.Name)을(를) 만들지 못했습니다." }
        Set-WtScheduleLinkResult (Add-WtScheduleLink -Store (Get-WtScheduleData).Store -Id $f.Id -Page $Source.Page -Key $key -Date $f.LinkDate)
        Open-WtPage -Id $Source.Page -Args @{ Key = $key; Edit = $true }
    } catch { Set-WtScheduleLinkError $_.Exception.Message }
}
function Invoke-WtScheduleLinkPick($Source) {
    $f = $script:form; if (-not $f -or -not $f.Id) { return }
    try {
        $existing = [string[]]@(Get-WtScheduleItemLinks $f.Id $f.LinkDate | Where-Object Page -CEQ $Source.Page | ForEach-Object Key)
        $key = [string](@(& $Source.Pick $existing) | Select-Object -Last 1)
        if (-not $key) { return }
        Set-WtScheduleLinkResult (Add-WtScheduleLink -Store (Get-WtScheduleData).Store -Id $f.Id -Page $Source.Page -Key $key)
    } catch { Set-WtScheduleLinkError $_.Exception.Message }
}
function Invoke-WtScheduleLinkAction([string]$Action, $Row) {
    $f = $script:form
    try {
        switch ($Action) {
            'window' { [void](& $Row.Source.Window $Row.Link.Key) }
            'open' { Open-WtPage -Id $Row.Source.Page -Args @{ Key = $Row.Link.Key } }
            'remove' {
                if (-not $f -or -not $f.Id) { return }
                Set-WtScheduleLinkResult (Remove-WtScheduleLink -Store (Get-WtScheduleData).Store -Id $f.Id -Page $Row.Link.Page -Key $Row.Link.Key -Date $Row.Link.Date)
            }
        }
    } catch { Set-WtScheduleLinkError $_.Exception.Message }
}

function Show-WtScheduleForm([ValidateSet('event', 'routine')][string]$Kind, $Occurrence, [string]$Id) {
    $store = (Get-WtScheduleData).Store; $entry = $null
    if ($Kind -eq 'routine' -and $Id) { $entry = @($store.Items | Where-Object id -CEQ $Id)[0] }
    if ($Occurrence) { $Id = $Occurrence.Entry.Id }
    $body = [Windows.Controls.DockPanel]::new(); Set-WtStyle $body 'Schedule.SideBody'
    $buttons = [Windows.Controls.DockPanel]::new(); [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom')
    $delete = New-WtButton '삭제'; $delete.Visibility = if ($Id) { 'Visible' } else { 'Collapsed' }; [void]$buttons.Children.Add($delete)
    $actions = New-WtStack Horizontal 8; $actions.HorizontalAlignment = 'Right'
    $save = New-WtButton '저장' Primary; $cancel = New-WtButton '취소'
    [void](Add-WtChild $actions $save); [void](Add-WtChild $actions $cancel); [void]$buttons.Children.Add($actions); [void]$body.Children.Add($buttons)
    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $col = New-WtStack; Set-WtStyle $col 'Schedule.Form'; $scroll.Content = $col; [void]$body.Children.Add($scroll)
    $script:form = @{ Kind = $Kind; Id = $Id; Occurrence = $Occurrence; Store = $store; Fields = @{}; Errors = @{}; Rows = @{}; Panel = $col; Save = $save }
    Add-WtScheduleField title '제목' (New-WtScheduleInput $(if ($Occurrence) { $Occurrence.Title } elseif ($entry) { $entry.title } else { '' }))
    if ($Kind -eq 'event') {
        $date = if ($Occurrence) { $Occurrence.Start.Date } else { $script:selected }
        # 끝 날짜: 하루 종일은 마지막 날, 시각 있는 일정은 끝 시각의 날짜(밤을 넘기면 다음 날)
        $endDate = if (-not $Occurrence) { $date } elseif ($Occurrence.AllDay) { $Occurrence.LastDay } else { $Occurrence.End.Date }
        Add-WtScheduleRange date endDate '날짜' (ConvertTo-WtDateText $date) (ConvertTo-WtDateText $endDate) '시작 날짜' '끝 날짜'
        Add-WtScheduleField allDay '' (New-WtScheduleCheck '하루 종일' ($Occurrence -and $Occurrence.AllDay))
        Add-WtScheduleRange start end '시각' $(if ($Occurrence -and -not $Occurrence.AllDay) { $Occurrence.Start.ToString('HH:mm', $script:inv) } else { Get-WtSetting 'work.start' }) $(if ($Occurrence -and -not $Occurrence.AllDay -and $Occurrence.End -gt $Occurrence.Start) { $Occurrence.End.ToString('HH:mm', $script:inv) } else { '' }) '시작 시각' '끝 시각'
        $repeat = if ($Occurrence) { Get-WtRepeatLabel $Occurrence.Entry.Repeat } else { '없음' }; if (-not $repeat) { $repeat = '없음' }
        $repeatOptions = @('없음', '매일', '매주', '격주', '매월'); if ($repeat -notin $repeatOptions) { $repeatOptions += $repeat }
        Add-WtScheduleField repeat '반복' (New-WtScheduleCombo $repeatOptions $repeat)
        Add-WtScheduleField until '끝나는 날' (New-WtScheduleInput $(if ($Occurrence -and $Occurrence.Entry.Repeat.Until) { ConvertTo-WtDateText $Occurrence.Entry.Repeat.Until } else { '' }))
        $alarm = if ($Occurrence -and @($Occurrence.Alarms).Count) { Format-WtAlarm $Occurrence.Alarms[0] } else { '없음' }
        $alarmOptions = @('없음', '5분 전', '10분 전', '30분 전', '1시간 전'); if ($alarm -notin $alarmOptions) { $alarmOptions += $alarm }
        Add-WtScheduleField alarm '알람' (New-WtScheduleCombo $alarmOptions $alarm)
        # 태그(설계 14.1): 계열 전체의 칸. 쉼표 · 공백으로 나누고 #은 없어도 된다
        Add-WtScheduleField tags '태그' (New-WtScheduleInput $(if ($Occurrence) { @($Occurrence.Entry.Tags) -join ', ' } else { '' }))
        $script:form.Fields.tags.ToolTip = '쉼표로 나눠 씁니다. 예: 점검, 작업'
        $script:form.Fields.allDay.Add_Click({ Update-WtScheduleFormFields }); $script:form.Fields.repeat.Add_SelectionChanged({ Update-WtScheduleFormFields })
        foreach ($key in 'date', 'endDate') { $script:form.Fields[$key].Add_TextChanged({ Update-WtScheduleFormFields }) }
    } else {
        $freq = if ($entry) { switch ($entry.routine.freq) { daily { '매일' }; weekly { '요일' }; hourly { '시간마다' } } } else { '매일' }
        Add-WtScheduleField freq '주기' (New-WtScheduleCombo @('매일', '요일', '시간마다') $freq)
        $week = [Windows.Controls.Primitives.UniformGrid]::new(); $week.Columns = 7; $dayNames = @('월', '화', '수', '목', '금', '토', '일')
        for ($i = 1; $i -le 7; $i++) {
            $checkBox = New-WtScheduleCheck $dayNames[$i - 1] ($entry -and $i -in @($entry.routine.days)); $checkBox.Tag = $i
            [Windows.Automation.AutomationProperties]::SetName($checkBox, $dayNames[$i - 1]); [void]$week.Children.Add($checkBox)
        }
        Add-WtScheduleField days '요일' $week
        # 시각(설계 14.2): 매일 · 요일 루틴의 선택 칸. 비우면 시각 없음
        Add-WtScheduleField time '시각' (New-WtScheduleInput $(if ($entry -and [string]$entry.routine.freq -cne 'hourly' -and $entry.routine.time) { [string]$entry.routine.time } else { '' }))
        $script:form.Fields.time.ToolTip = '비워 두면 시각 없이 그날의 루틴입니다. 예: 09:00'
        Add-WtScheduleField every '간격 시간' (New-WtScheduleInput $(if ($entry -and $entry.routine.freq -eq 'hourly') { [string]$entry.routine.every } else { '2' }))
        Add-WtScheduleField start '시작' (New-WtScheduleInput $(if ($entry -and $entry.routine.freq -eq 'hourly') { $entry.routine.from } else { Get-WtSetting 'work.start' }))
        Add-WtScheduleField end '끝 시각' (New-WtScheduleInput $(if ($entry -and $entry.routine.freq -eq 'hourly') { $entry.routine.to } else { Get-WtSetting 'work.end' }))
        Add-WtScheduleField workdays '' (New-WtScheduleCheck '근무 요일만' ($entry -and $entry.routine.workdaysOnly))
        $script:form.Fields.workdays.ToolTip = '체크하면 근무 요일(설정 → 업무시간)이 아닌 날을 뺍니다. 휴무일 · 휴가에는 늘 빠집니다.'
        $script:form.Fields.freq.Add_SelectionChanged({ Update-WtScheduleFormFields })
    }
    $f0 = $script:form
    $f0.LinkDate = if ($Kind -eq 'event' -and $Occurrence) { ConvertTo-WtDateText $Occurrence.Original } else { $null }
    $f0.Repeat = [bool]($Kind -eq 'event' -and $Occurrence -and $Occurrence.Entry.Repeat)
    $f0.LinkSubject = if ($Occurrence) { [string]$Occurrence.Title } elseif ($entry) { [string]$entry.title } else { '' }
    $f0.LinkBox = New-WtStack; Set-WtStyle $f0.LinkBox 'Schedule.LinkSection'; [void]$col.Children.Add($f0.LinkBox)
    Update-WtScheduleLinks
    $save.Add_Click({ Save-WtScheduleForm }); $cancel.Add_Click({ Show-WtScheduleDay }); $delete.Add_Click({ Remove-WtScheduleForm })
    Update-WtScheduleFormFields; $script:detail.Content = $body
    if ($script:side.Rail.Visibility -eq 'Visible') { $script:side.Open.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
    [void]$script:form.Fields.title.Focus()
}
function Update-WtScheduleFormFields {
    if (-not $script:form) { return }; $f = $script:form
    if ($f.Kind -eq 'event') {
        # 끝 날짜가 시작보다 뒤면 하루 종일로 고정한다. 밤을 넘는 시각 일정은 새로 만들지 않는다(근태 업무외로 적음, 설계 9.x).
        # 예전에 저장된 밤 넘김 일정은 그대로 열고 고칠 수 있다(시각을 바꾸지 않으면 저장된다)
        $from = ConvertFrom-WtDateText $f.Fields.date.Text; $to = ConvertFrom-WtDateText $f.Fields.endDate.Text
        $legacy = $f.Occurrence -and -not $f.Occurrence.AllDay -and $f.Occurrence.End.Date -gt $f.Occurrence.Start.Date
        if ($from -and $to -and $to -gt $from -and -not $legacy) {
            $f.Fields.allDay.IsChecked = $true; $f.Fields.allDay.IsEnabled = $false
            $f.Fields.allDay.ToolTip = '여러 날 일정은 하루 종일로 저장합니다. 밤을 넘는 작업은 근태의 업무외로 적으세요.'
            [Windows.Controls.ToolTipService]::SetShowOnDisabled($f.Fields.allDay, $true)
        } else { $f.Fields.allDay.IsEnabled = $true; $f.Fields.allDay.ToolTip = $null }
        foreach ($key in 'start', 'end') { $f.Fields[$key].IsEnabled = -not $f.Fields.allDay.IsChecked }
        $f.Rows.until.Visibility = if ($f.Fields.repeat.SelectedItem -ne '없음') { 'Visible' } else { 'Collapsed' }
    } else {
        $f.Rows.days.Visibility = if ($f.Fields.freq.SelectedItem -eq '요일') { 'Visible' } else { 'Collapsed' }
        $f.Rows.time.Visibility = if ($f.Fields.freq.SelectedItem -ne '시간마다') { 'Visible' } else { 'Collapsed' }
        foreach ($key in 'every', 'start', 'end') { $f.Rows[$key].Visibility = if ($f.Fields.freq.SelectedItem -eq '시간마다') { 'Visible' } else { 'Collapsed' } }
    }
}
function Set-WtScheduleFormError([string]$Key, [string]$Message) {
    $script:form.Errors[$Key].Text = $Message; $script:form.Errors[$Key].Visibility = 'Visible'
    [Windows.Automation.AutomationProperties]::SetHelpText($script:form.Fields[$Key], $Message)
}
function Save-WtScheduleForm([string]$Scope) {
    $f = $script:form; if (-not $f) { return }
    foreach ($errorText in $f.Errors.Values) { $errorText.Text = ''; $errorText.Visibility = 'Collapsed' }
    $fields = $f.Fields
    if (-not $fields.title.Text.Trim()) { Set-WtScheduleFormError title '제목을 입력하세요.'; return }
    try {
        if ($f.Kind -eq 'event') {
            $date = ConvertFrom-WtDateText $fields.date.Text
            if (-not $date) { Set-WtScheduleFormError date '날짜를 확인하세요.'; return }
            # 끝 날짜를 비우면 시작 날짜와 같다. 끝 날짜가 뒤면 여러 날 일정이다
            $lastDay = if ($fields.endDate.Text.Trim()) { ConvertFrom-WtDateText $fields.endDate.Text } else { $date }
            if (-not $lastDay -or $lastDay -lt $date) { Set-WtScheduleFormError endDate '끝 날짜를 확인하세요. 시작 날짜와 같거나 뒤여야 합니다.'; return }
            $spanDays = ($lastDay - $date).Days
            $endDateText = ConvertTo-WtDateText $lastDay
            $start = $null; $end = $null
            if (-not $fields.allDay.IsChecked) {
                $start = ConvertFrom-WtTimeText $fields.start.Text
                if ($null -eq $start) { Set-WtScheduleFormError start '시작 시각을 확인하세요.'; return }
                if ($fields.end.Text) {
                    $end = ConvertFrom-WtTimeText $fields.end.Text
                    if ($null -eq $end -or ($spanDays -eq 0 -and $end -lt $start)) { Set-WtScheduleFormError end '끝 시각을 확인하세요.'; return }
                } elseif ($spanDays -gt 0) { Set-WtScheduleFormError end '여러 날 일정은 끝 시각을 넣으세요.'; return }
            }
            $repeat = $null
            if ($fields.repeat.SelectedItem -ne '없음') {
                $oldLabel = if ($f.Occurrence) { Get-WtRepeatLabel $f.Occurrence.Entry.Repeat }
                if ($f.Occurrence -and $fields.repeat.SelectedItem -eq $oldLabel) { $repeat = Copy-WtItem $f.Occurrence.Entry.Item.repeat }
                else {
                    $freq = switch ($fields.repeat.SelectedItem) { 매일 { 'daily' }; 매주 { 'weekly' }; 격주 { 'weekly' }; 매월 { 'monthly' } }
                    $repeat = @{ freq = $freq; interval = $(if ($fields.repeat.SelectedItem -eq '격주') { 2 } else { 1 }); days = $null; monthDay = $null; nth = $null; count = $null; until = $null; skip = @(); changes = @{} }
                }
                $until = if ($fields.until.Text) { ConvertFrom-WtDateText $fields.until.Text }
                if ($fields.until.Text -and (-not $until -or $until -lt $date)) { Set-WtScheduleFormError until '끝나는 날을 확인하세요.'; return }
                Set-WtField $repeat until $(if ($until) { ConvertTo-WtDateText $until } else { $null }); if ($until) { Set-WtField $repeat count $null }
            }
            $alarms = if ($fields.alarm.SelectedItem -eq '없음') { @() } elseif ($f.Occurrence -and $fields.alarm.SelectedItem -eq (Format-WtAlarm @($f.Occurrence.Alarms)[0])) {
                @($f.Occurrence.Alarms | ForEach-Object { @{ before = $_ } })
            } else { @(@{ before = $(switch ($fields.alarm.SelectedItem) { '5분 전' { 5 }; '10분 전' { 10 }; '30분 전' { 30 }; '1시간 전' { 60 } }) }) }
            $dayText = ConvertTo-WtDateText $date
            $tags = @(ConvertFrom-WtScheduleTagText $fields.tags.Text)
            $patch = @{ title = $fields.title.Text; start = @{ date = $dayText; time = $(if ($null -ne $start) { $fields.start.Text } else { $null }) }
                end = $(if ($fields.allDay.IsChecked) { @{ date = $endDateText; time = $null } } elseif ($null -ne $end) { @{ date = $endDateText; time = $fields.end.Text } } else { $null }); repeat = $repeat; alarms = $alarms; tags = $tags }
            if ($f.Occurrence -and $f.Occurrence.Entry.Repeat -and -not $Scope) {
                $menu = New-WtHomePinContextMenu
                foreach ($name in '이 회차만', '이후 모두') {
                    $item = [Windows.Controls.MenuItem]::new(); $item.Header = $name; $item.Tag = $name
                    $item.Add_Click({ param($s, $e) Save-WtScheduleForm -Scope $s.Tag }); [void]$menu.Items.Add($item)
                }
                $f.Save.ContextMenu = $menu; $menu.PlacementTarget = $f.Save; $menu.Placement = 'Top'; $menu.IsOpen = $true; return
            }
            if ($Scope -eq '이 회차만') {
                if ($fields.repeat.SelectedItem -cne (Get-WtRepeatLabel $f.Occurrence.Entry.Repeat)) { Set-WtScheduleFormError repeat '이후 모두를 고르세요.'; return }
                $oldUntil = if ($f.Occurrence.Entry.Repeat.Until) { ConvertTo-WtDateText $f.Occurrence.Entry.Repeat.Until } else { '' }
                if ($fields.until.Text -cne $oldUntil) { Set-WtScheduleFormError until '이후 모두를 고르세요.'; return }
                # 태그는 계열 전체의 칸이라 회차만 바꿀 수 없다(설계 14.1)
                if (($tags -join '|') -cne (@($f.Occurrence.Entry.Tags) -join '|')) { Set-WtScheduleFormError tags '태그는 이후 모두를 골라 바꾸세요.'; return }
                $patch.Remove('repeat'); $patch.Remove('tags'); $result = Set-WtScheduleOccurrence $f.Store -Id $f.Id -OriginalDate (ConvertTo-WtDateText $f.Occurrence.Original) -Patch $patch
            } elseif ($Scope -eq '이후 모두') {
                $result = Save-WtScheduleItem $f.Store $patch -Id $f.Id -FromDate (ConvertTo-WtDateText $f.Occurrence.Original)
            } else { $result = Save-WtScheduleItem $f.Store $patch -Id $f.Id }
        } else {
            $freq = switch ($fields.freq.SelectedItem) { 매일 { 'daily' }; 요일 { 'weekly' }; 시간마다 { 'hourly' } }
            $rule = @{ freq = $freq; workdaysOnly = [bool]$fields.workdays.IsChecked }
            if ($freq -ne 'hourly') {
                # 시각은 선택 칸. 비우면 null로 넘겨 저장 함수가 칸을 뺀다(설계 14.2)
                $timeText = $fields.time.Text.Trim()
                if ($timeText -and $null -eq (ConvertFrom-WtTimeText $timeText)) { Set-WtScheduleFormError time '시각을 확인하세요. 예: 09:00'; return }
                $rule.time = if ($timeText) { $timeText } else { $null }
            }
            if ($freq -eq 'weekly') {
                $rule.days = @($fields.days.Children | Where-Object IsChecked | ForEach-Object Tag)
                if (-not $rule.days.Count) { Set-WtScheduleFormError days '요일을 고르세요.'; return }
            }
            if ($freq -eq 'hourly') {
                $every = 0
                if (-not [int]::TryParse($fields.every.Text, [ref]$every) -or $every -lt 1 -or $every -gt 12) { Set-WtScheduleFormError every '간격 시간을 확인하세요.'; return }
                $start = ConvertFrom-WtTimeText $fields.start.Text; $end = ConvertFrom-WtTimeText $fields.end.Text
                if ($null -eq $start) { Set-WtScheduleFormError start '시작 시각을 확인하세요.'; return }
                if ($null -eq $end -or $end -le $start) { Set-WtScheduleFormError end '끝 시각을 확인하세요.'; return }
                $rule.every = $every; $rule.from = $fields.start.Text; $rule.to = $fields.end.Text
            }
            $patch = @{ title = $fields.title.Text; routine = $rule }; if (-not $f.Id) { $patch.start = @{ date = ConvertTo-WtDateText $script:selected } }
            $result = Save-WtRoutine $f.Store $patch -Id $f.Id -From ([datetime]::Today)
        }
        if (-not $result.Success) { Set-WtScheduleFormError title $result.Reason; return }
        if ($f.Kind -eq 'event') { $script:selected = $date; $script:month = [datetime]::new($date.Year, $date.Month, 1) }
        $script:form = $null; Update-WtScheduleView
    } catch { Set-WtScheduleFormError title $_.Exception.Message }
}
function Remove-WtScheduleForm {
    $f = $script:form; if (-not $f -or -not $f.Id) { return }
    try {
        $result = if ($f.Kind -eq 'routine') { Set-WtRoutineDeleted $f.Store -Id $f.Id } else { Set-WtScheduleDeleted $f.Store -Id $f.Id }
        if (-not $result.Success) { Set-WtScheduleFormError title $result.Reason; return }
        $script:form = $null; Update-WtScheduleView
    } catch { Set-WtScheduleFormError title $_.Exception.Message }
}

# 홈 「오늘 일정」 · 다음 일정 줄. 끝낸 회차는 제목 앞에 ✓를 붙이고(Done), 다음 일정 줄 · 메뉴 개수에서는 뺀다
function Get-WtScheduleHomeItems {
    $data = Get-WtScheduleData
    $today = [datetime]::Today
    $doneKeys = try { Get-WtEventDone } catch { $null }
    @(foreach ($occurrence in @(Get-WtScheduleOccurrences $data.Entries $today $today)) {
        $done = $null -ne $doneKeys -and $doneKeys.Contains($occurrence.Key)
        $when = if ($occurrence.AllDay) { '하루 종일' } else { $occurrence.Start.ToString('HH:mm', $script:inv) + '–' + $(if ($occurrence.End) { $occurrence.End.ToString('HH:mm', $script:inv) } else { '' }) }
        $details = @($occurrence.Title, $when)
        $repeatText = Get-WtRepeatLabel $occurrence.Entry.Repeat
        if ($repeatText) { $details += $repeatText }
        foreach ($alarm in @($occurrence.Alarms)) { $details += Format-WtAlarm $alarm }
        if ($done) { $details += '끝냄' }
        [pscustomobject]@{ Id = $occurrence.Entry.Id; Title = $(if ($done) { '✓ ' + $occurrence.Title } else { $occurrence.Title }); Start = $occurrence.Start; End = $occurrence.End
            AllDay = $occurrence.AllDay; Alarm = @($occurrence.Alarms).Count -gt 0; ToolTip = (@($details | Where-Object { $_ }) -join "`n"); Done = $done }
    })
}
function New-WtNextEventHomeLine {
    $script:homeNext = New-WtNextEventLine @(Get-WtScheduleHomeItems | Where-Object { -not $_.Done })
    $script:homeNext
}
function New-WtScheduleHomeCards {
    $data = Get-WtScheduleData
    $today = [datetime]::Today
    $items = Get-WtScheduleHomeItems
    if ($script:homeTimer) { $script:homeTimer.Stop() }
    $timeline = New-WtTimeline -Items $items -Date $today -Page 'schedule' -ErrorText $data.Error
    $script:homeTimeline = $timeline.Timeline
    $script:homeTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:homeTimer.Interval = [timespan]::FromMinutes(1)
    $script:homeTimer.Add_Tick({ Update-WtTimelineNow $script:homeTimeline; if ($script:homeNext) { Update-WtNextEventLine $script:homeNext } })
    $timeline.Card.Add_Loaded({ if ($script:homeTimer) { Update-WtTimelineNow $script:homeTimeline; if ($script:homeNext) { Update-WtNextEventLine $script:homeNext }; $script:homeTimer.Start() } })
    $timeline.Card.Add_Unloaded({ if ($script:homeTimer) { $script:homeTimer.Stop() } })
    $timeline.Card
}
function New-WtRoutineHomeCard {
    if (-not @(Get-WtRoutineSlots -Date ([datetime]::Today)).Count) { return }
    $card = New-WtCard; Set-WtStyle $card 'Home.Card'
    $section = New-WtRoutineSection '오늘 루틴' ([datetime]::Today); $section.List.DataContext = $card
    $card.Child = $section.Root; $card
}
function Open-WtScheduleArgs($OpenArgs) {
    if (-not $script:view) { return }
    $date = if ($OpenArgs.Date -is [datetime]) { $OpenArgs.Date.Date } elseif ($OpenArgs.Date) { ConvertFrom-WtDateText ([string]$OpenArgs.Date) }
    if ($OpenArgs.Id) {
        $data = Get-WtScheduleData; $entry = @($data.Entries | Where-Object { $_.Id -ceq [string]$OpenArgs.Id -and $_.State -eq 'ok' } | Select-Object -First 1)
        if (-not $entry.Count) { return }; if (-not $date) { $date = $entry[0].Start.Date }
        $occurrence = @(Get-WtScheduleOccurrences $entry $date $date | Select-Object -First 1)
        if (-not $occurrence.Count) { return }; Set-WtScheduleDate $date; Show-WtScheduleForm -Kind event -Occurrence $occurrence[0]
    } elseif ($date) { Set-WtScheduleDate $date; if ($OpenArgs.RoutineId) { Show-WtScheduleForm -Kind routine -Id $OpenArgs.RoutineId } }
}

# 메뉴 개수 = 할 일 수(기한 지남 + 오늘 남은 일정 · 루틴 + 마감 임박, 설계 14.5). 보기 단추의 숫자와 같다
Register-WtAddon -Id 'schedule' -Title '일정' -Icon 0xE787 -Group '일과' -Order 20 -WarmUp Full -Badge { $data = Get-WtScheduleData; if ($data.Error) { throw $data.Error }; Get-WtScheduleDueCount } -NewView { New-WtScheduleView } -Refresh { param($view) Update-WtScheduleView } -HomeCards @(@{ Slot = 'head'; Order = 10; Card = { New-WtNextEventHomeLine } }, @{ Slot = 'main'; Order = 10; Card = { New-WtScheduleHomeCards } }, @{ Slot = 'side'; Order = 20; Card = { New-WtRoutineHomeCard } }) -CalendarHost -OnOpen { param($OpenArgs) Open-WtScheduleArgs $OpenArgs } -OnExit { if ($script:homeTimer) { $script:homeTimer.Stop() } } -ImportLegacy { param($folder) Import-WtScheduleLegacy $folder } -Shortcuts @(@('PageUp / PageDown', '달력 칸 · 표에서 이전 달 / 다음 달'), @('Enter / Space', '표에서 줄 열기 / 체크')) -Help @('보기는 할 일 · 달력 · 표 · 루틴 네 가지입니다. 할 일은 기한 지남 · 오늘 · 마감 임박만 모아 보여 줍니다.', '달력에서 일정과 반복 일정을 확인합니다. 여러 날 일정은 이어진 막대로 보입니다.', '일정 줄의 체크 상자로 끝낸 회차를 표시합니다.', '찾기: 낱말 · #태그 · title: · 2026-11-05 · 2026-10-01..2026-10-31 · is:done · is:open · is:routine, 빼기는 -, 또는은 OR, 묶음은 ( ).', '날짜를 우클릭해 회사 · 개인 휴무를 지정합니다. 공휴일은 앱이 해마다 채웁니다(설정 → 휴무일).')
Export-ModuleMember -Function Format-WtAlarm, Get-WtRepeatLabel

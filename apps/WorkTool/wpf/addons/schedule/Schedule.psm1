# 일정 화면. 데이터 편집·반복·루틴 증적은 ScheduleData, 모양은 공통 UI가 맡는다.
$ErrorActionPreference = 'Stop'
$script:inv = [Globalization.CultureInfo]::InvariantCulture
$script:view = $null
$script:month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
$script:selected = [datetime]::Today
$script:form = $null
$script:homeTimer = $null
$script:homeTimeline = $null

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
    $when = if ($Occ.AllDay) { '하루 종일' } else {
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
  <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
  <DockPanel Style="{DynamicResource Schedule.Header}">
    <TextBlock x:Name="Month" Style="{DynamicResource Schedule.Month}" DockPanel.Dock="Left"/>
    <StackPanel x:Name="Nav" Orientation="Horizontal" HorizontalAlignment="Left"/>
  </DockPanel>
  <DockPanel Grid.Row="1">
    <UniformGrid x:Name="Week" Columns="7" DockPanel.Dock="Top"/>
    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
      <UniformGrid x:Name="Days" Columns="7"/>
    </ScrollViewer>
  </DockPanel>
  <Grid x:Name="Side" Grid.Column="1" Grid.Row="1" Style="{DynamicResource Schedule.Side}"/>
</Grid>
"@
    $root = ConvertFrom-WtXaml $xaml
    $script:view = Get-WtNamedElements $root $xaml
    $script:view.Root = $root; $script:cells = @(); $script:form = $null
    foreach ($step in -1, 1) {
        $button = New-WtButton '' -Kind Icon -Icon $(if ($step -lt 0) { 0xE76B } else { 0xE76C }) -ToolTip $(if ($step -lt 0) { '이전 달' } else { '다음 달' })
        Set-WtStyle $button 'Schedule.MonthMove'
        [Windows.Automation.AutomationProperties]::SetName($button, [string]$button.ToolTip)
        $button.Tag = $step
        $button.Add_Click({ param($s, $e) $script:month = $script:month.AddMonths([int]$s.Tag); Update-WtScheduleView })
        [void]$script:view.Nav.Children.Add($button)
    }
    $today = New-WtButton '오늘'; Set-WtStyle $today 'Schedule.MonthToday'; $today.Add_Click({ Set-WtScheduleDate ([datetime]::Today) }); [void]$script:view.Nav.Children.Add($today)
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
        $cell.Mark = New-WtText '' 'Schedule.Mark'
        [void]$head.Children.Add($cell.Circle); [void]$head.Children.Add($cell.Mark); [void]$col.Children.Add($head)
        $cell.Holiday = New-WtText '' 'Schedule.Holiday'; [void]$col.Children.Add($cell.Holiday)
        $cell.Chips = @()
        for ($j = 0; $j -lt 2; $j++) {
            $chip = [Windows.Controls.Border]::new(); Set-WtStyle $chip 'Schedule.Chip'
            $chip.Child = New-WtText '' 'Schedule.ChipText'; $cell.Chips += $chip; [void]$col.Children.Add($chip)
        }
        $cell.More = New-WtText '' 'Schedule.More'; [void]$col.Children.Add($cell.More)
        $cell.Button.Content = $col; $cell.Button.Add_Click({ param($s, $e) Set-WtScheduleDate $s.DataContext })
        [void]$script:view.Days.Children.Add($cell.Button); $script:cells += $cell
    }
    $script:detail = [Windows.Controls.ContentControl]::new()
    $side = New-WtSidePanel -Side Right -Key 'schedule.sidebarCollapsed' -Title '일정' -Width 308 -Content $script:detail
    $script:side = @{ Root = $side }
    foreach ($name in 'Expanded', 'Rail', 'Header', 'Title', 'Open', 'Collapse') { $script:side[$name] = $side.FindName($name) }
    Set-WtStyle $script:side.Expanded 'Schedule.SideBorder'; Set-WtStyle $script:side.Title 'Schedule.SideTitle'
    $side.Add_Loaded({ $script:side.Expanded.ClearValue([Windows.Controls.Border]::BorderThicknessProperty) })
    $root.Add_SizeChanged({ $script:side.Expanded.ClearValue([Windows.Controls.Border]::BorderThicknessProperty) })
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
    $root
}

function Set-WtScheduleDate([datetime]$Date) {
    $script:selected = $Date.Date; $script:month = [datetime]::new($Date.Year, $Date.Month, 1); $script:form = $null
    Update-WtScheduleView
}
function Update-WtScheduleView {
    if (-not $script:view) { return }
    $data = Get-WtScheduleData
    $script:view.Month.Text = $script:month.ToString('yyyy년 M월', $script:inv)
    $start = $script:month.AddDays(-[int]$script:month.DayOfWeek)
    $count = [int]([math]::Ceiling(([int]$script:month.DayOfWeek + [datetime]::DaysInMonth($script:month.Year, $script:month.Month)) / 7.0) * 7)
    if ($count -lt 35) { $count = 35 }
    $script:view.Days.Rows = $count / 7
    $days = Get-WtScheduleDays $data.Entries $start 42
    $calendar = Get-WtCalendarItems $start $start.AddDays(41) -Exclude @('schedule')
    for ($i = 0; $i -lt 42; $i++) {
        $cell = $script:cells[$i]; $date = $start.AddDays($i); $items = @($calendar.Days[$i].Items)
        $cell.Button.Visibility = if ($i -lt $count) { 'Visible' } else { 'Collapsed' }; $cell.Button.DataContext = $date
        [Windows.Automation.AutomationProperties]::SetName($cell.Button, (ConvertTo-WtDateText $date))
        $mark = Get-WtCalendarMark $date $items
        Set-WtStyle $cell.Button $(if ($date -eq [datetime]::Today) { 'Schedule.Today' } elseif ($mark.DayOff) { 'Schedule.DayOff' } else { 'Schedule.Day' })
        $cell.Button.Tag = if ($date -eq $script:selected) { 'Selected' } else { '' }; $cell.Number.Text = [string]$date.Day
        Set-WtResource $cell.Number Foreground $(if ($date -eq [datetime]::Today) { 'B.OnAccent' } elseif ($date.Month -ne $script:month.Month) { 'B.Text.Tertiary' } elseif ($date.DayOfWeek -eq [DayOfWeek]::Sunday) { 'B.Cal.Holiday' } elseif ($date.DayOfWeek -eq [DayOfWeek]::Saturday) { 'B.Cal.Saturday' } else { 'B.Text.Primary' })
        if ($date -eq [datetime]::Today) { Set-WtResource $cell.Circle Background 'B.Accent' } else { $cell.Circle.ClearValue([Windows.Controls.Border]::BackgroundProperty) }
        Set-WtResource $cell.Number FontWeight $(if ($date -eq [datetime]::Today) { 'F.BodyStrong.Weight' } else { 'F.Body.Weight' })
        $cell.Mark.Text = if ($mark.Glyph) { [string][char]$mark.Glyph } else { '' }; Set-WtResource $cell.Mark Foreground $mark.Brush
        $work = @($items | Where-Object { $_.Kind -cin @('work', 'overtime', 'trip') })
        $reasons = @($items | Where-Object { $_.Kind -cin @('public', 'company', 'personal', 'leave') } | ForEach-Object Text)
        $cell.Mark.ToolTip = if ($work.Count) { @($work.Text) -join [Environment]::NewLine } elseif ($reasons.Count) { $reasons -join ' · ' } else { Format-WtDate $date 'dddd' }
        [Windows.Automation.AutomationProperties]::SetName($cell.Mark, [string]$cell.Mark.ToolTip)
        $holidays = @($items | Where-Object { $_.Kind -cin @('public', 'company', 'personal') } | ForEach-Object Text) -join ' · '
        $cell.Holiday.Text = $holidays; $cell.Holiday.ToolTip = $holidays; $cell.Holiday.Visibility = if ($holidays) { 'Visible' } else { 'Collapsed' }
        $occurrences = @($days[$i])
        for ($j = 0; $j -lt 2; $j++) {
            $chip = $cell.Chips[$j]; $chip.Visibility = if ($j -lt $occurrences.Count) { 'Visible' } else { 'Collapsed' }
            if ($j -lt $occurrences.Count) { $chip.Child.Text = Get-WtScheduleLine $occurrences[$j]; $chip.ToolTip = Get-WtScheduleToolTip $occurrences[$j] }
        }
        $cell.More.Text = if ($occurrences.Count -gt 2) { '+' + ($occurrences.Count - 2) } else { '' }
        $cell.More.ToolTip = @($occurrences | Select-Object -Skip 2 | ForEach-Object { Get-WtScheduleLine $_ }) -join [Environment]::NewLine
        $cell.More.Visibility = if ($occurrences.Count -gt 2) { 'Visible' } else { 'Collapsed' }
    }
    $script:side.Title.Text = Format-WtDate $script:selected 'M월 d일 dddd'
    $script:side.Add.IsEnabled = -not [bool]$data.Error; $script:side.Add.ToolTip = if ($data.Error) { $data.Error } else { '새로 만들기' }
    if (-not $script:form) { Show-WtScheduleDay }
}

function New-WtRoutineList([datetime]$Date) {
    $list = New-WtStack; $slots = @(Get-WtRoutineSlots -Date $Date)
    foreach ($group in @($slots | Group-Object { $_.Routine.Id })) {
        $all = @($group.Group); $hourly = $all[0].Slot.Length -gt 10
        $shown = if (-not $hourly -or $Date.Date -lt [datetime]::Today) { $all } else {
            $next = @($all | Where-Object Next | Select-Object -First 1)
            if ($next.Count) { $next } else { @($all[-1]) }
        }
        foreach ($slot in @($shown)) {
            $row = [Windows.Controls.DockPanel]::new()
            if ($hourly) {
                $counter = New-WtText ("$(@($all | Where-Object Done).Count)/$($all.Count)") 'Schedule.RoutineCount'
                [Windows.Controls.DockPanel]::SetDock($counter, 'Right'); [void]$row.Children.Add($counter)
            }
            $check = [Windows.Controls.CheckBox]::new(); Set-WtStyle $check 'Checklist.Row'
            $label = $(if ($hourly) { $slot.Slot.Substring(11) + ' ' }) + $slot.Routine.Title
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
    if ($List.DataContext -is [Windows.Controls.Border] -and -not @(Get-WtRoutineSlots -Date $Date).Count) { $List.DataContext.Visibility = 'Collapsed' }
}
function Show-WtScheduleDay {
    $script:form = $null
    $body = [Windows.Controls.DockPanel]::new(); Set-WtStyle $body 'Schedule.SideBody'
    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $col = New-WtStack; $data = Get-WtScheduleData
    if ($data.Error) { [void]$col.Children.Add((New-WtText $data.Error 'Schedule.Error')) }
    else {
        $occurrences = @((Get-WtScheduleDays $data.Entries $script:selected 1)[0])
        foreach ($occurrence in $occurrences) {
            $button = New-WtButton ''; Set-WtStyle $button 'Schedule.EventRow'; $row = [Windows.Controls.DockPanel]::new()
            $when = New-WtText $(if ($occurrence.AllDay) { '하루 종일' } else { $occurrence.Start.ToString('HH:mm', $script:inv) }) 'Schedule.EventTime'
            [Windows.Controls.DockPanel]::SetDock($when, 'Left'); [void]$row.Children.Add($when); [void]$row.Children.Add((New-WtText $occurrence.Title 'Schedule.EventTitle'))
            $button.Content = $row; $button.Tag = $occurrence; $button.ToolTip = Get-WtScheduleToolTip $occurrence
            [Windows.Automation.AutomationProperties]::SetName($button, (Get-WtScheduleLine $occurrence))
            $button.Add_Click({ param($s, $e) Show-WtScheduleForm -Kind event -Occurrence $s.Tag }); [void]$col.Children.Add($button)
        }
        if (-not $occurrences.Count) { [void]$col.Children.Add((New-WtText '일정 없음' 'T.Sub')) }
        $separator = [Windows.Controls.Border]::new(); Set-WtStyle $separator 'Schedule.Separator'; [void]$col.Children.Add($separator)
        try { [void]$col.Children.Add((New-WtRoutineList $script:selected)) } catch { [void]$col.Children.Add((New-WtText $_.Exception.Message 'Schedule.Error')) }
    }
    $scroll.Content = $col; [void]$body.Children.Add($scroll); $script:detail.Content = $body
}

function Add-WtScheduleField([string]$Key, [string]$Label, $Control) {
    $field = New-WtStack; Set-WtStyle $field 'Schedule.Field'
    if ($Label) { [void]$field.Children.Add((New-WtText $Label 'Schedule.FieldLabel')) }
    [void]$field.Children.Add($Control); $errorText = New-WtText '' 'Schedule.Error'; $errorText.Visibility = 'Collapsed'; [void]$field.Children.Add($errorText)
    [Windows.Automation.AutomationProperties]::SetName($Control, $(if ($Label) { $Label } else { [string]$Control.Content }))
    [Windows.Automation.AutomationProperties]::SetAutomationId($Control, "Schedule-$Key")
    $script:form.Fields[$Key] = $Control; $script:form.Errors[$Key] = $errorText; $script:form.Rows[$Key] = $field; [void]$script:form.Panel.Children.Add($field)
}
function New-WtScheduleInput([string]$Value) { $inputBox = [Windows.Controls.TextBox]::new(); Set-WtStyle $inputBox Input; $inputBox.Text = $Value; $inputBox }
function New-WtScheduleCombo([string[]]$Values, [string]$Selected) {
    $comboBox = [Windows.Controls.ComboBox]::new(); Set-WtStyle $comboBox Combo
    foreach ($value in $Values) { [void]$comboBox.Items.Add($value) }; $comboBox.SelectedItem = $Selected; $comboBox
}
function New-WtScheduleCheck([string]$Label, [bool]$Checked) {
    $checkBox = [Windows.Controls.CheckBox]::new(); Set-WtStyle $checkBox Check; $checkBox.Content = $Label; $checkBox.IsChecked = $Checked; $checkBox
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
        Add-WtScheduleField date '날짜' (New-WtScheduleInput (ConvertTo-WtDateText $date))
        Add-WtScheduleField allDay '' (New-WtScheduleCheck '하루 종일' ($Occurrence -and $Occurrence.AllDay))
        Add-WtScheduleField start '시작' (New-WtScheduleInput $(if ($Occurrence -and -not $Occurrence.AllDay) { $Occurrence.Start.ToString('HH:mm', $script:inv) } else { Get-WtSetting 'work.start' }))
        Add-WtScheduleField end '끝 시각' (New-WtScheduleInput $(if ($Occurrence -and -not $Occurrence.AllDay -and $Occurrence.End -gt $Occurrence.Start) { $Occurrence.End.ToString('HH:mm', $script:inv) } else { '' }))
        $repeat = if ($Occurrence) { Get-WtRepeatLabel $Occurrence.Entry.Repeat } else { '없음' }; if (-not $repeat) { $repeat = '없음' }
        $repeatOptions = @('없음', '매일', '매주', '격주', '매월'); if ($repeat -notin $repeatOptions) { $repeatOptions += $repeat }
        Add-WtScheduleField repeat '반복' (New-WtScheduleCombo $repeatOptions $repeat)
        Add-WtScheduleField until '끝나는 날' (New-WtScheduleInput $(if ($Occurrence -and $Occurrence.Entry.Repeat.Until) { ConvertTo-WtDateText $Occurrence.Entry.Repeat.Until } else { '' }))
        $alarm = if ($Occurrence -and @($Occurrence.Alarms).Count) { Format-WtAlarm $Occurrence.Alarms[0] } else { '없음' }
        $alarmOptions = @('없음', '5분 전', '10분 전', '30분 전', '1시간 전'); if ($alarm -notin $alarmOptions) { $alarmOptions += $alarm }
        Add-WtScheduleField alarm '알람' (New-WtScheduleCombo $alarmOptions $alarm)
        $script:form.Fields.allDay.Add_Click({ Update-WtScheduleFormFields }); $script:form.Fields.repeat.Add_SelectionChanged({ Update-WtScheduleFormFields })
    } else {
        $freq = if ($entry) { switch ($entry.routine.freq) { daily { '매일' }; weekly { '요일' }; hourly { '시간마다' } } } else { '매일' }
        Add-WtScheduleField freq '주기' (New-WtScheduleCombo @('매일', '요일', '시간마다') $freq)
        $week = [Windows.Controls.Primitives.UniformGrid]::new(); $week.Columns = 7; $dayNames = @('월', '화', '수', '목', '금', '토', '일')
        for ($i = 1; $i -le 7; $i++) {
            $checkBox = New-WtScheduleCheck $dayNames[$i - 1] ($entry -and $i -in @($entry.routine.days)); $checkBox.Tag = $i
            [Windows.Automation.AutomationProperties]::SetName($checkBox, $dayNames[$i - 1]); [void]$week.Children.Add($checkBox)
        }
        Add-WtScheduleField days '요일' $week
        Add-WtScheduleField every '간격 시간' (New-WtScheduleInput $(if ($entry -and $entry.routine.freq -eq 'hourly') { [string]$entry.routine.every } else { '2' }))
        Add-WtScheduleField start '시작' (New-WtScheduleInput $(if ($entry -and $entry.routine.freq -eq 'hourly') { $entry.routine.from } else { Get-WtSetting 'work.start' }))
        Add-WtScheduleField end '끝 시각' (New-WtScheduleInput $(if ($entry -and $entry.routine.freq -eq 'hourly') { $entry.routine.to } else { Get-WtSetting 'work.end' }))
        Add-WtScheduleField workdays '' (New-WtScheduleCheck '쉬는 날 빼기' ($entry -and $entry.routine.workdaysOnly))
        $script:form.Fields.freq.Add_SelectionChanged({ Update-WtScheduleFormFields })
    }
    $save.Add_Click({ Save-WtScheduleForm }); $cancel.Add_Click({ Show-WtScheduleDay }); $delete.Add_Click({ Remove-WtScheduleForm })
    Update-WtScheduleFormFields; $script:detail.Content = $body
    if ($script:side.Rail.Visibility -eq 'Visible') { $script:side.Open.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
    [void]$script:form.Fields.title.Focus()
}
function Update-WtScheduleFormFields {
    if (-not $script:form) { return }; $f = $script:form
    if ($f.Kind -eq 'event') {
        foreach ($key in 'start', 'end') { $f.Fields[$key].IsEnabled = -not $f.Fields.allDay.IsChecked }
        $f.Rows.until.Visibility = if ($f.Fields.repeat.SelectedItem -ne '없음') { 'Visible' } else { 'Collapsed' }
    } else {
        $f.Rows.days.Visibility = if ($f.Fields.freq.SelectedItem -eq '요일') { 'Visible' } else { 'Collapsed' }
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
            # 예전 기간 일정은 날짜 칸 하나로 편집해도 원래 날짜 간격을 보존한다.
            $spanDays = if ($f.Occurrence) { ($f.Occurrence.End.Date - $f.Occurrence.Start.Date).Days } else { 0 }
            $endDateText = ConvertTo-WtDateText $date.AddDays($spanDays)
            $start = $null; $end = $null
            if (-not $fields.allDay.IsChecked) {
                $start = ConvertFrom-WtTimeText $fields.start.Text
                if ($null -eq $start) { Set-WtScheduleFormError start '시작 시각을 확인하세요.'; return }
                if ($fields.end.Text) {
                    $end = ConvertFrom-WtTimeText $fields.end.Text
                    if ($null -eq $end -or ($spanDays -eq 0 -and $end -lt $start)) { Set-WtScheduleFormError end '끝 시각을 확인하세요.'; return }
                }
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
            $patch = @{ title = $fields.title.Text; start = @{ date = $dayText; time = $(if ($null -ne $start) { $fields.start.Text } else { $null }) }
                end = $(if ($fields.allDay.IsChecked) { @{ date = $endDateText; time = $null } } elseif ($null -ne $end) { @{ date = $endDateText; time = $fields.end.Text } } else { $null }); repeat = $repeat; alarms = $alarms }
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
                $patch.Remove('repeat'); $result = Set-WtScheduleOccurrence $f.Store -Id $f.Id -OriginalDate (ConvertTo-WtDateText $f.Occurrence.Original) -Patch $patch
            } elseif ($Scope -eq '이후 모두') {
                $result = Save-WtScheduleItem $f.Store $patch -Id $f.Id -FromDate (ConvertTo-WtDateText $f.Occurrence.Original)
            } else { $result = Save-WtScheduleItem $f.Store $patch -Id $f.Id }
        } else {
            $freq = switch ($fields.freq.SelectedItem) { 매일 { 'daily' }; 요일 { 'weekly' }; 시간마다 { 'hourly' } }
            $rule = @{ freq = $freq; workdaysOnly = [bool]$fields.workdays.IsChecked }
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

function New-WtScheduleHomeCards {
    $data = Get-WtScheduleData
    $today = [datetime]::Today
    $items = @(foreach ($occurrence in @(Get-WtScheduleOccurrences $data.Entries $today $today)) {
        $when = if ($occurrence.AllDay) { '하루 종일' } else { $occurrence.Start.ToString('HH:mm', $script:inv) + '–' + $(if ($occurrence.End) { $occurrence.End.ToString('HH:mm', $script:inv) } else { '' }) }
        $details = @($occurrence.Title, $when)
        $repeatText = Get-WtRepeatLabel $occurrence.Entry.Repeat
        if ($repeatText) { $details += $repeatText }
        foreach ($alarm in @($occurrence.Alarms)) { $details += Format-WtAlarm $alarm }
        [pscustomobject]@{ Id = $occurrence.Entry.Id; Title = $occurrence.Title; Start = $occurrence.Start; End = $occurrence.End
            AllDay = $occurrence.AllDay; Alarm = @($occurrence.Alarms).Count -gt 0; ToolTip = (@($details | Where-Object { $_ }) -join "`n") }
    })
    if ($script:homeTimer) { $script:homeTimer.Stop() }
    $timeline = New-WtTimeline -Items $items -Date $today -Page 'schedule' -ErrorText $data.Error
    $script:homeTimeline = $timeline.Timeline
    $script:homeTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:homeTimer.Interval = [timespan]::FromMinutes(1)
    $script:homeTimer.Add_Tick({ Update-WtTimelineNow $script:homeTimeline })
    $timeline.Card.Add_Loaded({ if ($script:homeTimer) { Update-WtTimelineNow $script:homeTimeline; $script:homeTimer.Start() } })
    $timeline.Card.Add_Unloaded({ if ($script:homeTimer) { $script:homeTimer.Stop() } })
    $timeline.Card
}
function New-WtRoutineHomeCard {
    if (-not @(Get-WtRoutineSlots -Date ([datetime]::Today)).Count) { return }
    $card = New-WtCard; Set-WtStyle $card 'Home.Card'; $col = New-WtStack
    [void]$col.Children.Add((New-WtCardHeader '오늘 루틴'))
    $list = New-WtRoutineList ([datetime]::Today); $list.DataContext = $card
    [void]$col.Children.Add($list); $card.Child = $col; $card
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

Register-WtAddon -Id 'schedule' -Title '일정' -Icon 0xE787 -Group '일과' -Order 20 -WarmUp Full -Badge { $data = Get-WtScheduleData; if ($data.Error) { throw $data.Error }; @(Get-WtScheduleOccurrences $data.Entries ([datetime]::Today) ([datetime]::Today)).Count } -NewView { New-WtScheduleView } -Refresh { param($view) Update-WtScheduleView } -HomeCards @(@{ Slot = 'main'; Order = 10; Card = { New-WtScheduleHomeCards } }, @{ Slot = 'side'; Order = 20; Card = { New-WtRoutineHomeCard } }) -CalendarHost -OnOpen { param($OpenArgs) Open-WtScheduleArgs $OpenArgs } -OnExit { if ($script:homeTimer) { $script:homeTimer.Stop() } } -ImportLegacy { param($folder) Import-WtScheduleLegacy $folder } -Help '달력에서 일정과 반복 일정을 확인합니다.'
Export-ModuleMember -Function Format-WtAlarm, Get-WtRepeatLabel

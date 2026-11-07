# 근태 화면. 원자료·계산·저장은 AttendanceData, 모양은 core/Ui의 Attendance.*가 맡는다.
$ErrorActionPreference = 'Stop'
$script:inv = [Globalization.CultureInfo]::InvariantCulture
$script:month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
$script:view = $null
$script:form = $null
$script:kindNames = @{ work = '근무'; leave = '휴가'; trip = '출장'; overtime = '업무외'; 'leave-grant' = '대휴 발생'; other = '기타' }
# 폼의 휴가 종류(이 순서). 오전 · 오후를 모르는 예전 반차(half)는 그 기록을 고칠 때만 더한다. 이름은 AttendanceData의 표(Get-WtLeaveTypeName)
$script:leaveChoices = @('annual', 'half-am', 'half-pm', 'comp', 'sick', 'family', 'other')
# 다른 탭(일정)의 날짜 메뉴가 부르는 동작(설계 15.6). 이 모듈 안에서 만든 스크립트 블록이라 이 모듈의 함수를 부를 수 있다
$script:quickLeaveAction = { param($Arg) Add-WtAttQuickLeave $Arg }
$script:openAction = { param($Arg) Open-WtPage -Id 'attendance' -Args $Arg }

function Format-WtHours([int]$Minutes) { [math]::Floor($Minutes / 60).ToString('0', $script:inv) + ':' + ($Minutes % 60).ToString('00', $script:inv) }
function Format-WtDays([double]$Days) { $Days.ToString('0.#', $script:inv) }
function Test-WtAttInMonth($Entry, [datetime]$Month) {
    $Entry.State -ne 'deleted' -and $Entry.StartDate -and $Entry.StartDate -lt $Month.AddMonths(1) -and $Entry.EndDate -ge $Month
}
function Get-WtAttKindName($Entry) {
    if ($Entry.Kind -ceq 'other') {
        $origin = Get-WtField $Entry.Item 'origin'; $row = Get-WtField $origin 'row'; $original = [string](Get-WtField $row 'Type')
        if ($original) { return $original }
    }
    if ($Entry.Kind -ceq 'leave' -and $Entry.LeaveType) { return Get-WtLeaveTypeName $Entry.LeaveType }
    if ($script:kindNames.ContainsKey($Entry.Kind)) { $script:kindNames[$Entry.Kind] } else { $Entry.Kind }
}
# 표 한 줄. 반차는 시작 · 끝에 휴가 구간(그날 규칙 또는 그날만 다른 시각), 휴가의 시간 칸은 그 달 몫 일수, 대휴 발생은 +일수
function New-WtAttTableRow($Entry, [datetime]$Month, $DayOff) {
    $range = Get-WtLeaveRange $Entry
    $last = $Month.AddMonths(1).AddDays(-1)
    [pscustomobject]@{
        Date = Format-WtDate $Entry.StartDate 'M/d (ddd)'; Kind = Get-WtAttKindName $Entry
        Start = $(if ($range) { $range[0].ToString('HH:mm', $script:inv) } elseif ($Entry.HasTime) { $Entry.Start.ToString('HH:mm', $script:inv) } else { '' })
        End = $(if ($range) { $range[1].ToString('HH:mm', $script:inv) } elseif ($Entry.HasTime -and $Entry.HasEnd) { $Entry.End.ToString('HH:mm', $script:inv) } else { '' })
        Place = $(if ($Entry.Kind -ceq 'work' -or ($Entry.Kind -ceq 'overtime' -and $Entry.How -ceq 'onsite')) { '작업장' } elseif ($Entry.Kind -ceq 'overtime' -and $Entry.How -ceq 'remote') { '원격' } else { '—' })
        Travel = $(if ($Entry.Kind -ceq 'overtime' -and $Entry.Travel -gt 0) { $Entry.Travel.ToString($script:inv) } else { '' })
        Duration = $(if ($Entry.Kind -ceq 'leave') { "$(Format-WtDays (Get-WtLeaveDays $Entry $Month $last $DayOff))일" } elseif ($Entry.Kind -ceq 'leave-grant') { "+$(Format-WtDays $Entry.LeaveDays)일" }
            elseif ($null -ne $Entry.Minutes) { Format-WtHours $Entry.Minutes } else { '' })
        Note = $Entry.Note; Problem = $(if ($Entry.Problem) { $Entry.Problem } elseif ($Entry.Kind -ceq 'work' -and -not $Entry.HasEnd) { '퇴근 기록 없음' } else { '' }); Entry = $Entry
    }
}
function New-WtAttendanceView {
    $xaml = @"
<Grid {NS} Style="{DynamicResource Attendance.Page}">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <Border Style="{DynamicResource Panel.Surface}">
    <DockPanel>
      <DockPanel x:Name="Header" DockPanel.Dock="Top" Style="{DynamicResource Attendance.Header}">
        <StackPanel x:Name="Actions" Orientation="Horizontal" DockPanel.Dock="Right" HorizontalAlignment="Right"/>
        <StackPanel x:Name="Nav" Orientation="Horizontal" HorizontalAlignment="Left"/>
      </DockPanel>
      <Grid Style="{DynamicResource Attendance.TableHost}"><ContentControl x:Name="TableHost"/><TextBlock x:Name="Empty" Text="기록이 없습니다." Style="{DynamicResource T.Sub}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Grid>
    </DockPanel>
  </Border>
  <Grid x:Name="SideHost" Grid.Column="1"/>
</Grid>
"@
    $root = ConvertFrom-WtXaml $xaml
    $script:view = Get-WtNamedElements $root $xaml; $script:view.Root = $root; $script:form = $null; $script:viewKey = $null
    $script:view.Actions.Tag = [double]8
    $previous = New-WtButton '' Icon -Icon 0xE76B -ToolTip '이전 달'; $previous.Tag = -1
    $next = New-WtButton '' Icon -Icon 0xE76C -ToolTip '다음 달'; $next.Tag = 1
    $script:monthLabel = New-WtText '' 'Attendance.Month'
    foreach ($button in $previous, $next) {
        [Windows.Automation.AutomationProperties]::SetName($button, [string]$button.ToolTip)
        $button.Add_Click({ param($s, $e) $script:month = $script:month.AddMonths([int]$s.Tag); $script:form = $null; Update-WtAttendanceView })
    }
    [void]$script:view.Nav.Children.Add($previous); [void]$script:view.Nav.Children.Add($script:monthLabel); [void]$script:view.Nav.Children.Add($next)
    foreach ($spec in @(@('출근','work-start'), @('퇴근','work-end'), @('업무외 시작','over'), @('','new'))) {
        $button = if ($spec[1] -ceq 'new') { New-WtButton '' Icon -Icon 0xE710 -ToolTip '직접 입력' } else { New-WtButton $spec[0] }
        [Windows.Automation.AutomationProperties]::SetName($button, $(if ($spec[1] -ceq 'new') { '직접 입력' } else { $spec[0] }))
        if ($spec[1] -cne 'new') { Set-WtStyle $button 'Attendance.Action' }
        $button.Tag = $spec[1]; $button.Add_Click({ param($s, $e) if ($s.Tag -ceq 'new') { Show-WtAttForm } else { Invoke-WtAttClock $s.Tag } })
        $script:view[$spec[1]] = $button; [void](Add-WtChild $script:view.Actions $button)
    }
    $script:table = (Get-WtStyleDictionary)['Attendance.TableView'].LoadContent(); $script:view.TableHost.Content = $script:table
    $script:table.Add_SelectionChanged({ param($s, $e) if (-not $script:refreshing -and $s.SelectedItem) { Show-WtAttForm $s.SelectedItem.Entry } })
    # 취소 후 같은 선택 행을 다시 눌러도 폼을 연다. 선택 변경만으로는 이 클릭을 받지 못한다.
    $script:table.Add_PreviewMouseUp({
        param($s, $e)
        if ($e.ChangedButton -ne [Windows.Input.MouseButton]::Left) { return }
        $row = [Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource)
        if ($row -is [Windows.Controls.DataGridRow] -and $row.Item -and (-not $script:form -or -not $script:form.Entry -or $script:form.Entry.Id -cne $row.Item.Entry.Id)) { Show-WtAttForm $row.Item.Entry }
    })
    $script:detail = [Windows.Controls.ContentControl]::new()
    $sideRoot = New-WtSidePanel -Content $script:detail -Side Right -Key 'attendance.sidebar.collapsed' -Title '이번 달' -Width 288
    $script:side = @{ Root = $sideRoot }; foreach ($name in 'Title','Open','Rail') { $script:side[$name] = $sideRoot.FindName($name) }; [void]$script:view.SideHost.Children.Add($sideRoot)
    $root
}
function Show-WtAttSummary {
    $script:form = $null; $script:side.Title.Text = '이번 달'
    $body = [Windows.Controls.DockPanel]::new(); Set-WtStyle $body 'Attendance.Body'
    $col = New-WtStack
    $summary = Get-WtAttendanceSummary $script:month $script:data.Entries
    $total = $summary.OvertimeSite + $summary.OvertimeRemote + $summary.OvertimeUnknown
    $rows = @(@('출근', "$(Format-WtDays $summary.WorkDays)일", $false), @('휴가', "$(Format-WtDays $summary.LeaveDays)일", $false),
        @('출장', "$(Format-WtDays $summary.TripDays)일 · $($summary.TripCount)건", $false), @('초과근무', (Format-WtHours $total), $false),
        @('작업장', (Format-WtHours $summary.OvertimeSite), $true), @('원격', (Format-WtHours $summary.OvertimeRemote), $true))
    if ($summary.OvertimeUnknown -gt 0) { $rows += ,@('장소 없음', (Format-WtHours $summary.OvertimeUnknown), $true) }
    $rows += ,@('이동', (Format-WtHours $summary.Travel), $false)
    if ($summary.NoLeaveDays -gt 0) { $rows += ,@('퇴근 기록 없음', "$($summary.NoLeaveDays)일", $false) }
    # 대휴(전체 기간, 설계 15.3): 생긴 것이나 쓴 것이 있을 때만 구분선 아래에 남음 · 발생 · 사용(앞으로 쓸 것 포함)
    $comp = Get-WtCompBalance $script:data.Entries
    if ($comp.Granted -or $comp.Used) {
        $rows += ,'-'
        $rows += ,@('대휴 남음', "$(Format-WtDays $comp.Left)일", $false)
        $rows += ,@('발생', "$(Format-WtDays $comp.Granted)일", $true)
        $rows += ,@('사용', "$(Format-WtDays $comp.Used)일", $true)
    }
    foreach ($row in $rows) {
        if ($row -is [string]) { $divider = [Windows.Controls.Border]::new(); Set-WtStyle $divider 'Attendance.SummaryDivider'; [void]$col.Children.Add($divider); continue }
        $line = [Windows.Controls.DockPanel]::new(); Set-WtStyle $line $(if ($row[2]) { 'Attendance.SummaryChild' } else { 'Attendance.SummaryRow' })
        $value = New-WtText $row[1] 'Attendance.Number'; [Windows.Controls.DockPanel]::SetDock($value, 'Right'); [void]$line.Children.Add($value)
        [Windows.Automation.AutomationProperties]::SetName($value, "$($row[0]) $($row[1])")
        [void]$line.Children.Add((New-WtText $row[0] 'Attendance.CellText')); [void]$col.Children.Add($line)
    }
    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'; $scroll.Content = $col
    [void]$body.Children.Add($scroll); $script:detail.Content = $body
}
function Update-WtAttendanceView {
    if (-not $script:view) { return }
    $script:data = Get-WtAttendanceData; $holidays = Get-WtHolidayData
    # 업무시간은 기간별 규칙이라(설계 15.1) 처음부터 규칙과 뒤 규칙 목록을 같이 본다
    $key = @($script:data.Stamp, $holidays.Stamp, $script:month.Ticks, [datetime]::Today.Ticks, (Get-WtSetting 'attendance.tripDays'),
        (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale'), (ConvertTo-Json -Compress -Depth 6 -InputObject @((Get-WtWorkHours -From ''), (Get-WtSetting 'work.periods')))) -join '|'
    if ($script:viewKey -ceq $key) { return }
    $script:refreshing = $true
    try {
        $script:monthLabel.Text = Format-WtDate $script:month 'yyyy년 M월'
        $dayOff = Get-WtHolidayDates $script:month $script:month.AddMonths(1).AddDays(-1)
        $rows = @(foreach ($entry in @($script:data.Entries | Where-Object { Test-WtAttInMonth $_ $script:month } | Sort-Object Start, Id)) { New-WtAttTableRow $entry $script:month $dayOff })
        $script:table.ItemsSource = $rows
        $script:view.Empty.Visibility = if ($rows.Count) { 'Collapsed' } else { 'Visible' }
        $script:table.ToolTip = @($script:data.Error, $holidays.Error, @($script:data.Entries | Where-Object { $_.State -cin 'broken','readonly' } | ForEach-Object Problem)) | Where-Object { $_ } | Join-String -Separator "`n"
        $today = @($script:data.Entries | Where-Object { $_.State -ceq 'ok' -and $_.Kind -ceq 'work' -and $_.StartDate -eq [datetime]::Today })
        $script:view['work-start'].IsEnabled = -not $script:data.Error -and $today.Count -eq 0
        $script:view['work-start'].ToolTip = if ($script:data.Error) { $script:data.Error } elseif ($today.Count) { '출근' } else { $null }
        $script:view['work-end'].IsEnabled = -not $script:data.Error -and ($today.Count -eq 1 -or @($today | Where-Object { -not $_.HasEnd }).Count -eq 1)
        $script:view['work-end'].ToolTip = '퇴근'
        # 강조 버튼은 화면당 하나다. 지금 누를 수 있는 쪽에만 준다.
        $clock = if ($script:view['work-start'].IsEnabled) { 'work-start' } elseif ($script:view['work-end'].IsEnabled) { 'work-end' } else { '' }
        foreach ($id in 'work-start', 'work-end') { Set-WtStyle $script:view[$id] $(if ($id -ceq $clock) { 'Attendance.Action.Primary' } else { 'Attendance.Action' }) }
        $script:view.over.IsEnabled = -not $script:data.Error; $script:view.new.IsEnabled = -not $script:data.Error
        $open = @($script:data.Entries | Where-Object { $_.State -ceq 'ok' -and $_.Kind -ceq 'overtime' -and -not $_.HasEnd })
        $overLabel = if ($open.Count) { '업무외 끝' } else { '업무외 시작' }; $script:view.over.Content = $overLabel
        [Windows.Automation.AutomationProperties]::SetName($script:view.over, $overLabel)
        $script:view.over.IsEnabled = -not $script:data.Error -and $open.Count -le 1
        if (-not $script:form) { Show-WtAttSummary }
        $script:viewKey = $key
    } finally { $script:refreshing = $false }
}
function Invoke-WtAttClock([string]$Action) {
    try {
        $store = $script:data.Store
        if ($Action -ceq 'work-start') { $result = Start-WtAttendanceRecord $store }
        elseif ($Action -ceq 'work-end') {
            $entry = @($script:data.Entries | Where-Object { $_.State -ceq 'ok' -and $_.Kind -ceq 'work' -and $_.StartDate -eq [datetime]::Today })
            $open = @($entry | Where-Object { -not $_.HasEnd }); $target = if ($open.Count -eq 1) { $open[0] } else { $entry[0] }
            $at = Get-WtStamp; $now = ConvertFrom-WtStamp $at
            $result = Save-WtAttendanceItem $store @{ end = @{ date = ConvertTo-WtDateText $now.DateTime; time = $now.ToString('HH:mm', $script:inv) } } -Id $target.Id -At $at -ClockPoint end
        } elseif ($script:view.over.Content -ceq '업무외 끝') { $result = Stop-WtAttendanceRecord $store -Kind overtime }
        else { $result = Start-WtAttendanceRecord $store -Kind overtime -How remote }
        if (-not $result.Success) { throw $result.Reason }
        $script:form = $null; $script:viewKey = $null; Update-WtAttendanceView
    } catch { $script:view.Actions.ToolTip = $_.Exception.Message; $script:viewKey = $null; Update-WtAttendanceView }
}
function Add-WtAttField([string]$Key, [string]$Label, $Control) {
    $field = New-WtStack; Set-WtStyle $field 'Attendance.Field'
    if ($Label) { [void]$field.Children.Add((New-WtText $Label 'Attendance.Label')) }
    [void]$field.Children.Add($Control); $errorText = New-WtText '' 'Attendance.Error'; $errorText.Visibility = 'Collapsed'; [void]$field.Children.Add($errorText)
    [Windows.Automation.AutomationProperties]::SetName($Control, $(if ($Label) { $Label } else { [string]$Control.Content }))
    [Windows.Automation.AutomationProperties]::SetAutomationId($Control, "Attendance-$Key")
    $script:form.Fields[$Key] = $Control; $script:form.Errors[$Key] = $errorText; $script:form.Rows[$Key] = $field; [void]$script:form.Panel.Children.Add($field)
}
function New-WtAttInput([string]$Value) {
    $box = [Windows.Controls.TextBox]::new(); Set-WtStyle $box Input
    $binding = [Windows.Data.Binding]::new('Value'); $binding.Source = [pscustomobject]@{ Value = $Value }
    $binding.Mode = 'TwoWay'; $binding.UpdateSourceTrigger = 'PropertyChanged'
    [void]$box.SetBinding([Windows.Controls.TextBox]::TextProperty, $binding); $box
}
function New-WtAttCombo([string[]]$Values, [string]$Selected) {
    $combo = [Windows.Controls.ComboBox]::new(); Set-WtStyle $combo Combo
    foreach ($value in $Values) { [void]$combo.Items.Add($value) }; $combo.SelectedItem = $Selected; $combo
}
# 폼에서 고른 휴가 종류의 코드(annual · half-am …). 휴가가 아니거나 모르면 ''
function Get-WtAttLeaveCode {
    $name = [string]$script:form.Fields.leaveType.SelectedItem
    if ($script:form.LeaveCodes.ContainsKey($name)) { $script:form.LeaveCodes[$name] } else { '' }
}
# 그날 업무시간 규칙의 반차 시각 @('HH:mm', 'HH:mm'). 날짜를 못 읽으면 오늘 규칙
function Get-WtAttHalfTimes([string]$Code, [string]$DateText) {
    $day = ConvertFrom-WtDateText $DateText
    if (-not $day) { $day = [datetime]::Today }
    $hours = Get-WtWorkHours -Date $day
    $split = Get-WtHalfDaySplit $hours
    if ($Code -ceq 'half-am') { @([string]$hours['work.start'], $split) } else { @($split, [string]$hours['work.end']) }
}
# 종류에 맞춰 칸을 보이고 숨긴다(설계 15.7). 근무 · 업무외: 시작 · 끝 시각(+다음 날), 휴가: 휴가 종류 + 반차면 시작 · 끝 시각, 아니면 끝 날짜,
# 출장: 끝 날짜, 대휴 발생: 일수, 기타: 예전 기록 그대로. 종류 · 휴가 종류를 바꾸면(처음 열 때 말고) 시각 · 날짜 칸을 비우고, 반차면 그날 규칙의 시각으로 채운다
function Set-WtAttFormKind {
    $f = $script:form.Fields
    $kindText = [string]$f.kind.SelectedItem
    $code = if ($kindText -ceq '휴가') { Get-WtAttLeaveCode } else { '' }
    $half = $code -cin @('half-am', 'half-pm')
    $clock = $kindText -cin @('근무', '업무외')
    $old = $script:form.Entry
    $timed = $clock -or $half -or ($kindText -ceq '기타' -and $old -and $old.Kind -ceq 'other' -and $old.HasTime)
    $show = @{ place = $kindText -ceq '업무외'; out = $kindText -ceq '업무외'; back = $kindText -ceq '업무외'; next = $clock
        leaveType = $kindText -ceq '휴가'; days = $kindText -ceq '대휴 발생'; start = $timed; end = $kindText -cne '대휴 발생' }
    foreach ($key in @($show.Keys)) { $script:form.Rows[$key].Visibility = if ($show[$key]) { 'Visible' } else { 'Collapsed' } }
    $endLabel = if ($timed) { '끝' } else { '끝 날짜' }
    $script:form.Rows.end.Children[0].Text = $endLabel
    [Windows.Automation.AutomationProperties]::SetName($f.end, $endLabel)
    if (-not $script:form.ChangingKind) {
        $script:form.ChangingKind = $true
        try {
            $f.start.Text = ''
            $f.end.Text = ''; $f.next.IsChecked = $false
            if ($half) { $times = @(Get-WtAttHalfTimes $code $f.date.Text); $f.start.Text = $times[0]; $f.end.Text = $times[1] }
        } finally { $script:form.ChangingKind = $false }
    }
}
# Entry = 고칠 기록. 새 기록이면 Date(yyyy-MM-dd) · Kind(work · leave …)로 처음 값을 정할 수 있다(일정 우클릭 「여러 날 · 다른 종류…」)
function Show-WtAttForm($Entry, [string]$Date = '', [string]$Kind = '') {
    $body = [Windows.Controls.DockPanel]::new(); Set-WtStyle $body 'Attendance.Body'
    $buttons = [Windows.Controls.DockPanel]::new(); [Windows.Controls.DockPanel]::SetDock($buttons, 'Bottom')
    $delete = New-WtButton '삭제'; $delete.Visibility = if ($Entry -and $Entry.State -ceq 'ok') { 'Visible' } else { 'Collapsed' }; [void]$buttons.Children.Add($delete)
    $actions = New-WtStack Horizontal 8; $actions.HorizontalAlignment = 'Right'
    $save = New-WtButton '저장' Primary; $cancel = New-WtButton '취소'
    [void](Add-WtChild $actions $save); [void](Add-WtChild $actions $cancel); [void]$buttons.Children.Add($actions); [void]$body.Children.Add($buttons)
    $scroll = [Windows.Controls.ScrollViewer]::new(); $scroll.VerticalScrollBarVisibility = 'Auto'; $scroll.HorizontalScrollBarVisibility = 'Disabled'
    $col = New-WtStack
    $script:form = @{ Entry = $Entry; Store = $script:data.Store; Fields = @{}; Errors = @{}; Rows = @{}; Panel = $col; ChangingKind = $true; LeaveCodes = @{} }
    $day = if ($Entry) { $Entry.StartDate } elseif ($Date) { ConvertFrom-WtDateText $Date } else { $null }
    if (-not $day) { $day = if ($script:month.Year -eq [datetime]::Today.Year -and $script:month.Month -eq [datetime]::Today.Month) { [datetime]::Today } else { $script:month } }
    Add-WtAttField date '날짜' (New-WtAttInput (ConvertTo-WtDateText $day))
    $kindCode = if ($Entry) { $Entry.Kind } elseif ($Kind) { $Kind } else { 'work' }
    $kindLabel = if ($script:kindNames.ContainsKey($kindCode)) { $script:kindNames[$kindCode] } else { $kindCode }
    Add-WtAttField kind '종류' (New-WtAttCombo @('근무','휴가','출장','업무외','대휴 발생','기타', $kindLabel | Select-Object -Unique) $kindLabel)
    $codes = @($script:leaveChoices)
    if ($Entry -and $Entry.LeaveType -ceq 'half') { $codes += 'half' }
    foreach ($c in $codes) { $script:form.LeaveCodes[(Get-WtLeaveTypeName $c)] = $c }
    $leaveName = Get-WtLeaveTypeName $(if ($Entry -and $Entry.Kind -ceq 'leave' -and $Entry.LeaveType) { $Entry.LeaveType } else { 'annual' })
    Add-WtAttField leaveType '휴가 종류' (New-WtAttCombo @($codes | ForEach-Object { Get-WtLeaveTypeName $_ }) $leaveName)
    Add-WtAttField days '일수' (New-WtAttInput $(if ($Entry -and $Entry.Kind -ceq 'leave-grant' -and $null -ne $Entry.LeaveDays) { Format-WtDays $Entry.LeaveDays } else { '1' }))
    # 반차는 시각 없는 기록도 그날 규칙의 휴가 구간을 보여 준다(같은 시각으로 저장하면 시각 없이 남는다)
    $range = if ($Entry) { Get-WtLeaveRange $Entry } else { $null }
    Add-WtAttField start '시작' (New-WtAttInput $(if ($range) { $range[0].ToString('HH:mm', $script:inv) } elseif ($Entry -and $Entry.HasTime) { $Entry.Start.ToString('HH:mm', $script:inv) } else { '' }))
    Add-WtAttField end '끝' (New-WtAttInput $(if ($range) { $range[1].ToString('HH:mm', $script:inv) } elseif ($Entry -and $Entry.HasEnd) { if ($Entry.HasTime) { $Entry.End.ToString('HH:mm', $script:inv) } else { ConvertTo-WtDateText $Entry.EndDate } } else { '' }))
    $next = [Windows.Controls.CheckBox]::new(); Set-WtStyle $next Check; $next.Content = '다음 날'; $next.IsChecked = $Entry -and $Entry.EndDate -gt $Entry.StartDate
    Add-WtAttField next '' $next
    Add-WtAttField place '장소' (New-WtAttCombo @('—','작업장','원격') $(if ($Entry -and $Entry.How -ceq 'onsite') { '작업장' } elseif ($Entry -and $Entry.How -ceq 'remote') { '원격' } else { '—' }))
    Add-WtAttField out '이동 가는 길 분' (New-WtAttInput $(if ($Entry -and $Entry.TravelOut) { [string]$Entry.TravelOut } else { '' }))
    Add-WtAttField back '이동 오는 길 분' (New-WtAttInput $(if ($Entry -and $Entry.TravelBack) { [string]$Entry.TravelBack } else { '' }))
    $note = New-WtAttInput $(if ($Entry) { $Entry.Note } else { '' }); Set-WtStyle $note 'Attendance.Note'; Add-WtAttField note '메모' $note
    Set-WtAttFormKind; $script:form.ChangingKind = $false
    $script:form.Fields.kind.Add_SelectionChanged({ Set-WtAttFormKind })
    $script:form.Fields.leaveType.Add_SelectionChanged({ Set-WtAttFormKind })
    $cancel.Add_Click({ Show-WtAttSummary })
    $save.Add_Click({ Save-WtAttForm })
    $delete.Add_Click({
        try { $result = Set-WtAttendanceDeleted $script:form.Store $script:form.Entry.Id; if (-not $result.Success) { throw $result.Reason }; $script:form = $null; $script:viewKey = $null; Update-WtAttendanceView }
        catch { Set-WtAttFormError note $_.Exception.Message }
    })
    $save.IsEnabled = -not $Entry -or $Entry.State -ceq 'ok'
    if ($Entry -and $Entry.Problem) { $save.ToolTip = $Entry.Problem }
    $scroll.Content = $col; [void]$body.Children.Add($scroll); $script:detail.Content = $body; $script:side.Title.Text = '기록 편집'
    if ($script:side.Rail.Visibility -eq 'Visible') { $script:side.Open.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent)) }
}
function Set-WtAttFormError([string]$Key, [string]$Message) {
    $script:form.Errors[$Key].Text = $Message; $script:form.Errors[$Key].Visibility = 'Visible'
    [Windows.Automation.AutomationProperties]::SetHelpText($script:form.Fields[$Key], $Message)
    if ($script:form.Fields[$Key] -is [Windows.Controls.TextBox]) {
        $binding = $script:form.Fields[$Key].GetBindingExpression([Windows.Controls.TextBox]::TextProperty)
        $errorInfo = [Windows.Controls.ValidationError]::new([Windows.Controls.ExceptionValidationRule]::new(), $binding, $Message, $null)
        [Windows.Controls.Validation]::MarkInvalid($binding, $errorInfo)
    }
}
function Save-WtAttForm {
    $fields = $script:form.Fields; $old = $script:form.Entry
    foreach ($key in $script:form.Errors.Keys) {
        $script:form.Errors[$key].Text = ''; $script:form.Errors[$key].Visibility = 'Collapsed'; [Windows.Automation.AutomationProperties]::SetHelpText($fields[$key], '')
        if ($fields[$key] -is [Windows.Controls.TextBox]) { [Windows.Controls.Validation]::ClearInvalid($fields[$key].GetBindingExpression([Windows.Controls.TextBox]::TextProperty)) }
    }
    $date = ConvertFrom-WtDateText $fields.date.Text
    if (-not $date) { Set-WtAttFormError date '날짜는 yyyy-MM-dd 형식으로 입력하세요.' }
    $kind = switch ([string]$fields.kind.SelectedItem) { '근무' { 'work' }; '휴가' { 'leave' }; '출장' { 'trip' }; '업무외' { 'overtime' }; '대휴 발생' { 'leave-grant' }; '기타' { 'other' }; default { if ($old) { $old.Kind } else { 'other' } } }
    $leaveCode = if ($kind -ceq 'leave') { Get-WtAttLeaveCode } else { '' }
    $half = $leaveCode -cin @('half-am', 'half-pm')
    $timed = $kind -cin @('work','overtime') -or $half -or ($kind -ceq 'other' -and $old -and $old.HasTime)
    $startTime = $null; $endTime = $null; $end = $null; $grantDays = $null
    if ($kind -ceq 'leave-grant') {
        # 대휴 발생: 날짜 하나 + 생긴 일수(0.5 단위). 설계 15.3
        $number = 0.0
        $ok = [double]::TryParse($fields.days.Text.Trim(), [Globalization.NumberStyles]::Float, $script:inv, [ref]$number)
        if (-not $ok -or $number -le 0 -or $number -gt 366 -or $number * 2 -ne [math]::Floor($number * 2)) { Set-WtAttFormError days '일수는 0.5일 단위로 적으세요.' } else { $grantDays = $number }
    } elseif ($half) {
        # 반차: 같은 날 시작 ~ 끝 시각. 그날 규칙과 같으면 시각 없이 저장해 규칙을 따른다(설계 15.2)
        $startTime = ConvertFrom-WtTimeText $fields.start.Text; $endTime = ConvertFrom-WtTimeText $fields.end.Text
        if ($null -eq $startTime) { Set-WtAttFormError start '시각은 HH:mm 형식으로 입력하세요.' }
        if ($null -eq $endTime) { Set-WtAttFormError end '시각은 HH:mm 형식으로 입력하세요.' }
        elseif ($null -ne $startTime -and $endTime -le $startTime) { Set-WtAttFormError end '끝이 시작보다 늦어야 합니다.' }
        elseif ($date) { $end = @{ date = ConvertTo-WtDateText $date; time = $fields.end.Text } }
    } elseif ($timed) {
        $startTime = ConvertFrom-WtTimeText $fields.start.Text
        if ($null -eq $startTime) { Set-WtAttFormError start '시각은 HH:mm 형식으로 입력하세요.' }
        if ($fields.end.Text) {
            $endTime = ConvertFrom-WtTimeText $fields.end.Text
            if ($null -eq $endTime) { Set-WtAttFormError end '시각은 HH:mm 형식으로 입력하세요.' }
            elseif ($date) {
                # 기존 여러 날 기록은 다음 날 체크가 그대로면 원래 날짜 차이를 보존한다.
                $offset = if ($fields.next.IsChecked) { if ($old -and $old.HasEnd -and $old.EndDate -gt $old.StartDate) { ($old.EndDate - $old.StartDate).Days } else { 1 } } else { 0 }
                $endDate = $date.AddDays($offset)
                if ($null -ne $startTime -and ($endDate + $endTime) -lt ($date + $startTime)) { Set-WtAttFormError end '끝이 시작보다 이릅니다.' }
                $end = @{ date = ConvertTo-WtDateText $endDate; time = $fields.end.Text }
            }
        }
    } else {
        if ($fields.start.Text) { Set-WtAttFormError start '출장 · 휴가는 날짜만 적으세요.' }
        if ($fields.end.Text) {
            $endDate = ConvertFrom-WtDateText $fields.end.Text
            if (-not $endDate) { Set-WtAttFormError end '날짜는 yyyy-MM-dd 형식으로 입력하세요.' }
            elseif ($date -and $endDate -lt $date) { Set-WtAttFormError end '끝이 시작보다 이릅니다.' }
            else { $end = @{ date = $fields.end.Text; time = $null } }
        }
    }
    $travel = @{}
    if ($kind -ceq 'overtime') {
        foreach ($key in 'out','back') {
            $number = 0
            if ($fields[$key].Text -and ($fields[$key].Text -cnotmatch '^[0-9]+$' -or -not [int]::TryParse($fields[$key].Text, [ref]$number) -or $number -gt 1440)) { Set-WtAttFormError $key '이동은 0~1440의 정수 분으로 입력하세요.' }
            $travel[$key] = $number
        }
    }
    if (@($script:form.Errors.Values | Where-Object Text).Count) { return }
    $patch = @{ kind = $kind; start = @{ date = $fields.date.Text; time = $(if ($timed) { $fields.start.Text } else { $null }) }; end = $end; note = $fields.note.Text }
    if ($kind -ceq 'overtime') {
        $patch.overtime = @{ how = $(switch ([string]$fields.place.SelectedItem) { '작업장' { 'onsite' }; '원격' { 'remote' }; default { $null } }) }
        # 없는 선택 칸은 메모만 고쳐도 자동으로 채우지 않는다.
        if ($fields.out.Text -or $fields.back.Text -or ($old -and $null -ne (Get-WtField $old.Item 'travel'))) { $patch.travel = $travel }
    }
    if ($kind -ceq 'leave') {
        # 종류가 바뀌면 사람이 정한 일수는 지운다(같은 종류면 그대로 둔다)
        $patch.leave = @{ type = $leaveCode }
        if (-not $old -or $old.Kind -cne 'leave' -or $old.LeaveType -cne $leaveCode) { $patch.leave.days = $null }
        if ($half -and $date) {
            $rule = @(Get-WtAttHalfTimes $leaveCode $fields.date.Text)
            if ($fields.start.Text -ceq $rule[0] -and $fields.end.Text -ceq $rule[1]) { $patch.start.time = $null; $patch.end = $null }
        }
    }
    if ($kind -ceq 'leave-grant') { $patch.start.time = $null; $patch.end = $null; $patch.leave = @{ type = 'comp'; days = $grantDays } }
    try {
        $result = Save-WtAttendanceItem $script:form.Store $patch -Id $(if ($old) { $old.Id } else { '' })
        if (-not $result.Success) { Set-WtAttFormError end $result.Reason; return }
        $script:form = $null; $script:viewKey = $null; Update-WtAttendanceView
    } catch { Set-WtAttFormError note $_.Exception.Message }
}
# 다른 탭(일정)의 날짜 칸 우클릭 항목(설계 15.6). 그날 휴가가 있으면 「휴가 보기 · 종류」(근태 탭의 그 기록), 없으면 「휴가 넣기 ›」
function Get-WtAttDateMenu([datetime]$Date) {
    $data = Get-WtAttendanceData
    if ($data.Error) { return @{ Header = '휴가 넣기'; IsEnabled = $false; ToolTip = $data.Error } }
    $here = @($data.Entries | Where-Object { $_.State -ceq 'ok' -and $_.Kind -ceq 'leave' -and $_.StartDate -le $Date -and $_.EndDate -ge $Date } | Sort-Object Start, Id)
    if ($here.Count) { return @{ Header = "휴가 보기 · $(Get-WtLeaveTypeName $here[0].LeaveType)"; Action = $script:openAction; Arg = @{ Id = $here[0].Id } } }
    $dateText = ConvertTo-WtDateText $Date
    $items = @(foreach ($code in 'annual', 'half-am', 'half-pm', 'comp') { @{ Header = Get-WtLeaveTypeName $code; Action = $script:quickLeaveAction; Arg = @{ Date = $dateText; Type = $code } } })
    $items += '-'
    $items += @{ Header = '여러 날 · 다른 종류…'; Action = $script:openAction; Arg = @{ NewLeave = $dateText } }
    @{ Header = '휴가 넣기'; Items = $items }
}
# 우클릭 「휴가 넣기 › 연차」 등: 그날 하루 휴가를 바로 넣는다. 반차는 그날 규칙의 시각을 따르므로 시각 없이 저장한다
function Add-WtAttQuickLeave($Arg) {
    $data = Get-WtAttendanceData
    if ($data.Error) { throw $data.Error }
    $result = Save-WtAttendanceItem $data.Store @{ kind = 'leave'; start = @{ date = [string]$Arg.Date; time = $null }; end = $null; leave = @{ type = [string]$Arg.Type; days = $null }; note = '' }
    if (-not $result.Success) { throw $result.Reason }
    $script:viewKey = $null
}
# 다른 탭에서 연 근태: Id면 그 기록의 달로 가서 편집 폼, NewLeave(yyyy-MM-dd)면 그날 휴가 새 폼
function Open-WtAttArgs($OpenArgs) {
    if (-not $script:view -or $null -eq $OpenArgs) { return }
    $entry = $null; $newDate = $null
    if ($OpenArgs.Id) {
        $entry = @((Get-WtAttendanceData).Entries | Where-Object { $_.Id -ceq [string]$OpenArgs.Id -and $_.State -ne 'deleted' }) | Select-Object -First 1
        if (-not $entry) { return }
        $target = $entry.StartDate
    } elseif ($OpenArgs.NewLeave) {
        $newDate = ConvertFrom-WtDateText ([string]$OpenArgs.NewLeave)
        if (-not $newDate) { return }
        $target = $newDate
    } else { return }
    $script:month = [datetime]::new($target.Year, $target.Month, 1); $script:form = $null; $script:viewKey = $null
    Update-WtAttendanceView
    if ($entry) { Show-WtAttForm $entry } else { Show-WtAttForm $null -Date (ConvertTo-WtDateText $newDate) -Kind 'leave' }
}
Register-WtAddon -Id 'attendance' -Title '근태' -Icon 0xE823 -Group '일과' -Order 30 -WarmUp Full `
    -Badge {
        $data = Get-WtAttendanceData; if ($data.Error) { throw $data.Error }
        # 쉬는 날(근무 요일 아님 · 휴무일 · 하루 종일 휴가)에는 찍을 일이 없어 점을 띄우지 않는다
        if (Test-WtAttRestDay ([datetime]::Today) $data.Entries) { return $null }
        if (-not @($data.Entries | Where-Object { $_.State -ceq 'ok' -and $_.Kind -ceq 'work' -and $_.HasTime -and $_.StartDate -eq [datetime]::Today }).Count) { 'dot' }
    } `
    -BadgeToolTip '오늘 안 찍음' -NewView { New-WtAttendanceView } -Refresh { param($view) Update-WtAttendanceView } `
    -OnOpen { param($OpenArgs) Open-WtAttArgs $OpenArgs } `
    -DateMenu { param([datetime]$Date) Get-WtAttDateMenu $Date } `
    -CalendarItems { param([datetime]$From, [datetime]$To) $data = Get-WtAttendanceData; if ($data.Error) { throw $data.Error }; Get-WtAttendanceCalendarItems $From $To $data.Entries } `
    -ImportLegacy { param($folder) Import-WtAttendanceLegacy $folder } `
    -Help @('월별 출퇴근 기록과 초과근무를 확인합니다.', '휴가는 종류(연차 · 오전 반차 · 오후 반차 · 대휴 등)를 고릅니다. 반차는 설정 → 업무시간의 반차 나누는 시각을 따르고, 그날만 다르면 폼에서 시각을 고칩니다.', '대휴는 「대휴 발생」 기록으로 생긴 일수를 넣으면 사이드바에 남은 일수가 보입니다. 일정 달력 날짜를 우클릭해 휴가를 바로 넣을 수도 있습니다.')
Export-ModuleMember -Function Format-WtHours, Format-WtDays, Test-WtAttInMonth

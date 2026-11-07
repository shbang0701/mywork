# 셸에 붙은 기본 화면: 설정, 도움말. 메뉴 아래 톱니바퀴 · 물음표 버튼으로 연다.
# 이벤트 처리기는 $script: 변수와 보낸 요소의 Tag만 쓴다 (Shell.psm1 머리말 참고).

$ErrorActionPreference = 'Stop'

$script:addonChecks = @()
$script:opacityLabel = $null
$script:opacityTimer = $null
$script:pendingOpacity = 100
$script:opacityNote = $null
$script:firstWorkSetup = $null

# ---- 설정 -------------------------------------------------------------------------------------

# 100%는 글자를 또렷하게 그리는 보통 창, 그 아래는 투명 창이다. 둘 사이를 오가면 다시 시작해야 적용된다
function Update-WtOpacityNote([double]$Percent) {
    $note = if (-not (Test-WtOpacityNeedsRestart $Percent)) { '' } elseif ($Percent -lt 100) { 'WorkTool을 다시 시작하면 적용됩니다.' } else { '다시 시작하면 글자가 더 또렷해집니다.' }
    $script:opacityNote.Text = $note
    $script:opacityNote.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
}

# 설정 행: 왼쪽 라벨 + 오른쪽 값. 부모에 SetIsSharedSizeScope를 켜면 라벨 칸 폭이 맞는다. 행 사이는 12다.
function New-WtSettingRow([string]$Label, $Control, [string]$Note) {
    $row = [System.Windows.Controls.Grid]::new()
    Set-WtStyle $row 'Setting.Row'
    $labelColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $labelColumn.Width = [System.Windows.GridLength]::Auto
    $labelColumn.SharedSizeGroup = 'WtSettingLabels'
    $row.ColumnDefinitions.Add($labelColumn)
    $row.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
    $text = New-WtText $Label 'Setting.Label'
    if ($Note) { $Control.ToolTip = $Note }
    [void]$row.Children.Add($text)
    $Control.VerticalAlignment = 'Center'
    $Control.HorizontalAlignment = 'Left'
    [System.Windows.Controls.Grid]::SetColumn($Control, 1)
    [void]$row.Children.Add($Control)
    $row.Tag = $text
    $row
}

function New-WtThemeCard {
    $card = New-WtCard
    $col = New-WtStack Vertical
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)

    # 파스텔: 이름과 견본. 색·모양은 공통 자원만 참조한다.
    $swatches = New-WtStack Horizontal
    $current = [string](Get-WtSetting 'theme.color')
    $palettes = Get-WtPalette
    if (-not $palettes.Contains($current)) { $current = @($palettes.Keys)[0] }
    foreach ($key in $palettes.Keys) {
        $p = $palettes[$key]
        $rb = [System.Windows.Controls.RadioButton]::new()
        Set-WtStyle $rb 'Swatch'
        $rb.GroupName = 'WtTheme'
        $rb.Tag = $key
        $rb.Content = $p.Label
        $rb.ToolTip = $p.Label
        Set-WtResource $rb 'Background' ("B.Accent." + (Get-Culture).TextInfo.ToTitleCase($key))
        $rb.IsChecked = ($key -eq $current)
        $rb.Add_Checked({
            param($s, $e)
            Set-WtSetting 'theme.color' ([string]$s.Tag)
        })
        [void]$swatches.Children.Add($rb)
    }
    [void](Add-WtChild $col (New-WtSettingRow '색' $swatches))

    # 창 투명도: 끌면 바로 보이고, 손을 떼고 잠시 뒤 저장한다
    $op = New-WtStack Horizontal 12
    $slider = [System.Windows.Controls.Slider]::new()
    Set-WtStyle $slider 'Range'
    [System.Windows.Automation.AutomationProperties]::SetName($slider, '불투명도')
    $slider.Minimum = 60
    $slider.Maximum = 100
    $slider.TickFrequency = 5
    $slider.IsSnapToTickEnabled = $true
    $slider.Width = 240
    $slider.Value = [double](Get-WtSetting 'ui.opacity')
    $slider.VerticalAlignment = 'Center'
    $script:opacityLabel = New-WtText ('{0}%' -f [int]$slider.Value) 'T.Strong'
    $script:opacityLabel.VerticalAlignment = 'Center'
    if (-not $script:opacityTimer) {
        $script:opacityTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:opacityTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:opacityTimer.Add_Tick({
                param($s, $e)
                $s.Stop()
                Set-WtSetting 'ui.opacity' ([int]$script:pendingOpacity)
            })
    }
    $slider.Add_ValueChanged({
            param($s, $e)
            $script:pendingOpacity = [int]$e.NewValue
            $script:opacityLabel.Text = '{0}%' -f $script:pendingOpacity
            Set-WtOpacity $script:pendingOpacity
            Update-WtOpacityNote $script:pendingOpacity
            $script:opacityTimer.Stop()
            $script:opacityTimer.Start()
        })
    [void](Add-WtChild $op $slider)
    [void](Add-WtChild $op $script:opacityLabel)
    $opCol = New-WtStack Vertical 4
    [void](Add-WtChild $opCol $op)
    $script:opacityNote = New-WtText '' 'T.Sub'
    [void](Add-WtChild $opCol $script:opacityNote)
    Update-WtOpacityNote $slider.Value
    [void](Add-WtChild $col (New-WtSettingRow '불투명도' $opCol '60% ~ 100%'))

    # 글자 크기
    $seg = New-WtSegmented @(@('s', '작게'), @('m', '보통'), @('l', '크게')) ([string](Get-WtSetting 'ui.fontScale')) 'WtFont' {
        param($value) Set-WtSetting 'ui.fontScale' $value
    }
    [void](Add-WtChild $col (New-WtSettingRow '글자 크기' $seg))

    # 닫기 버튼(X)
    $close = New-WtSegmented @(@('exit', '끝내기'), @('tray', '트레이로 숨기기')) $(if (Get-WtSetting 'window.closeToTray') { 'tray' } else { 'exit' }) 'WtClose' {
        param($value) Set-WtSetting 'window.closeToTray' ($value -eq 'tray')
    }
    [void](Add-WtChild $col (New-WtSettingRow '닫기 버튼 (X)' $close '트레이 아이콘을 우클릭한 뒤 종료를 누르세요.'))

    $card.Child = $col
    $card
}

function New-WtMenuCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 4
    $disabled = @(Get-WtSetting 'addons.disabled')
    $script:addonChecks = @()
    foreach ($a in @(Get-WtAddon -All)) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        Set-WtStyle $cb 'Check'
        $cb.HorizontalAlignment = 'Left'
        $cb.Content = if ($a.Description) { "$($a.Title) — $($a.Description)" } else { $a.Title }
        $cb.Tag = $a.Id
        $cb.IsChecked = $a.Required -or ($disabled -notcontains $a.Id)
        $cb.IsEnabled = -not $a.Required
        $cb.Add_Click({
                $off = @($script:addonChecks | Where-Object { $_.IsEnabled -and -not $_.IsChecked } | ForEach-Object { [string]$_.Tag })
                Set-WtSetting 'addons.disabled' $off
            })
        $script:addonChecks += $cb
        [void](Add-WtChild $col $cb)
    }
    $card.Child = $col
    $card
}

function New-WtDataCard {
    $card = New-WtCard
    $col = New-WtStack Vertical
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)

    $root = Get-WtDataRoot
    $path = New-WtText $root 'T.Body'
    Set-WtResource $path 'FontFamily' 'Font.Mono'
    $open = New-WtButton '폴더 열기' -Icon 0xE8B7
    $open.HorizontalAlignment = 'Left'
    $open.Tag = $root
    $open.Add_Click({ param($s, $e) Open-WtPath ([string]$s.Tag) })
    $box = New-WtStack Vertical 8
    [void](Add-WtChild $box $path)
    [void](Add-WtChild $box $open)
    [void](Add-WtChild $col (New-WtSettingRow '데이터 폴더' $box '앱 폴더의 datapath.txt 첫 줄에 데이터 경로를 적으세요.'))

    $legacy = Find-WtLegacyFolder
    $lbox = New-WtStack Vertical 8
    $ltext = New-WtText $(if ($legacy) { $legacy } else { '찾지 못함' }) 'T.Body'
    Set-WtResource $ltext 'FontFamily' 'Font.Mono'
    [void](Add-WtChild $lbox $ltext)
    $btns = New-WtStack Horizontal 8
    $pick = New-WtButton '위치 고르기'
    $pick.Add_Click({
            $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
            $dlg.Description = '예전 WorkTool의 data 폴더를 고르세요 (memo.csv · schedule.csv · attendance.csv가 있는 폴더)'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-WtSetting 'legacy.path' $dlg.SelectedPath
                Select-WtPage '_settings'
            }
        })
    $again = New-WtButton '다시 가져오기' -Kind Primary
    $again.IsEnabled = [bool]$legacy
    $again.Add_Click({
            $tabs = @(Get-WtAddon -All | Where-Object { $_.ImportLegacy } | ForEach-Object { $_.Title }) -join ' · '
            if (-not (Confirm-WtYesNo "예전 WorkTool 데이터로 새 버전의 데이터($tabs)를 다시 채웁니다.`n새 버전에서 쓰거나 고친 내용은 사라집니다 (지금 파일은 .bak으로 하나 남음). 계속할까요?")) { return }
            try {
                $r = Import-WtLegacyData -Force
                Reset-WtViews
                Show-WtMessage ("가져왔습니다: {0}" -f ($r.Tabs -join ', '))
            } catch { Show-WtError $_ '다시 가져오기' }
        })
    [void](Add-WtChild $btns $pick)
    [void](Add-WtChild $btns $again)
    [void](Add-WtChild $lbox $btns)
    [void](Add-WtChild $col (New-WtSettingRow '예전 데이터 가져오기' $lbox))

    $card.Child = $col
    $card
}

function New-WtTabbedPage([string]$Title, [object[]]$Sections) {
    $page = New-WtPage -Fill
    $heading = New-WtPageHeader $Title
    [System.Windows.Controls.DockPanel]::SetDock($heading, 'Top')
    [void](Add-WtChild $page.Panel $heading)
    $tabs = [System.Windows.Controls.TabControl]::new()
    Set-WtStyle $tabs 'Tabs'
    [System.Windows.Automation.AutomationProperties]::SetName($tabs, "$Title 하위 탭")
    foreach ($section in $Sections) {
        $item = [System.Windows.Controls.TabItem]::new()
        Set-WtStyle $item 'Tab'
        $item.Header = $section[0]
        $scroll = [System.Windows.Controls.ScrollViewer]::new()
        $scroll.VerticalScrollBarVisibility = 'Auto'
        $scroll.HorizontalScrollBarVisibility = 'Disabled'
        $scroll.Focusable = $false
        $scroll.Content = $section[1]
        $item.Content = $scroll
        [void]$tabs.Items.Add($item)
    }
    $tabs.SelectedIndex = 0
    [void](Add-WtChild $page.Panel $tabs)
    $page.Root
}

function New-WtSettingsPage {
    $work = New-WtWorkHoursForm
    $workCard = New-WtCard
    $workCard.Child = $work.Root
    New-WtTabbedPage '설정' @(
        @('일반', (New-WtThemeCard)), @('업무시간', $workCard), @('휴무일', (New-WtHolidayCard)),
        @('탭', (New-WtMenuCard)), @('데이터', (New-WtDataCard)))
}

# ---- 휴무일: 공휴일 자동 채우기 · 해마다 목록 · 더하기 · 이름 바꾸기 · 지우기 (저장은 core\Calendar.psm1) ----
# 일정 · 근태 탭을 꺼도 휴무일은 계산에 쓰이므로 설정 화면(코어)에 둔다. 일정 달력 우클릭으로는 회사 휴무만 넣는다(개인 휴무는 여기서).
$script:holidayUi = $null
$script:holidayKinds = [ordered]@{ public = '공휴일'; company = '회사 휴무'; personal = '개인 휴무' }

function New-WtHolidayCard {
    $card = New-WtCard
    $col = New-WtStack Vertical
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)
    $auto = [System.Windows.Controls.CheckBox]::new(); Set-WtStyle $auto 'Check'
    $auto.Content = '자동으로 넣기'; $auto.IsChecked = [bool](Get-WtSetting 'holidays.auto')
    [System.Windows.Automation.AutomationProperties]::SetName($auto, '공휴일 자동으로 넣기')
    $auto.Add_Click({ param($s, $e) Set-WtSetting 'holidays.auto' ([bool]$s.IsChecked); Update-WtHolidayTable })
    $again = New-WtButton '다시 계산' -Kind Link -ToolTip '고른 해의 자동 공휴일을 계산대로 다시 넣습니다. 지운 자동 공휴일도 다시 들어옵니다.'
    $again.Add_Click({ Invoke-WtHolidayFill -Force; Update-WtHolidayTable })
    $line = New-WtStack Horizontal 12
    foreach ($child in @($auto, (New-WtText '설 · 추석 · 대체공휴일 포함' 'T.Sub'), $again)) { $child.VerticalAlignment = 'Center'; [void](Add-WtChild $line $child) }
    [void](Add-WtChild $col (New-WtSettingRow '공휴일' $line))
    $bar = [System.Windows.Controls.DockPanel]::new(); Set-WtStyle $bar 'Holiday.Bar'
    $add = New-WtButton '휴무일 추가' -Icon 0xE710; $add.Add_Click({ Show-WtHolidayDialog })
    [System.Windows.Controls.DockPanel]::SetDock($add, 'Right'); [void]$bar.Children.Add($add)
    $nav = New-WtStack Horizontal 4
    $yearText = New-WtText '' 'Holiday.Year'
    foreach ($step in -1, 0, 1) {
        if ($step -eq 0) { [void](Add-WtChild $nav $yearText); continue }
        $tip = if ($step -lt 0) { '이전 해' } else { '다음 해' }
        $b = New-WtButton '' -Kind Icon -Icon $(if ($step -lt 0) { 0xE76B } else { 0xE76C }) -ToolTip $tip
        [System.Windows.Automation.AutomationProperties]::SetName($b, $tip); $b.Tag = $step
        $b.Add_Click({ param($s, $e) $script:holidayUi.Year += [int]$s.Tag; Update-WtHolidayTable })
        [void](Add-WtChild $nav $b)
    }
    [void]$bar.Children.Add($nav)
    $table = New-WtStack Vertical; Set-WtStyle $table 'Table.Simple'
    [void](Add-WtChild $col $bar); [void](Add-WtChild $col $table)
    $script:holidayUi = @{ Year = [datetime]::Today.Year; YearText = $yearText; Table = $table }
    Update-WtHolidayTable
    $card.Child = $col
    $card
}

# 자동 공휴일 채우기. -Force는 고른 해를 계산대로 다시 맞춘다(설정을 꺼 두었어도 한다)
function Invoke-WtHolidayFill([switch]$Force) {
    try {
        $r = Update-WtAutoHolidays -Years @($script:holidayUi.Year) -Force:$Force
        if (-not $r.Success) { throw $r.Reason }
    } catch { Show-WtMessage "공휴일을 넣지 못했습니다. $($_.Exception.Message)" 'WorkTool' 'Warning' }
}

# 고른 해의 표. 자동으로 넣기가 켜져 있으면 처음 보는 해도 채운다(한 번만, 지운 날은 되살리지 않음)
function Update-WtHolidayTable {
    $ui = $script:holidayUi; if (-not $ui) { return }
    $ui.YearText.Text = "$($ui.Year)년"
    if ([bool](Get-WtSetting 'holidays.auto')) { try { [void](Update-WtAutoHolidays -Years @($ui.Year)) } catch { } }
    $table = $ui.Table; $table.Children.Clear()
    $data = Get-WtHolidayData
    if ($data.Error) { [void](Add-WtChild $table (New-WtText $data.Error 'T.Error')); return }
    $head = [System.Windows.Controls.Border]::new(); Set-WtStyle $head 'Table.Head'
    $head.Child = New-WtHolidayRowGrid @('날짜', '요일', '이름', '종류', '넣은 곳') 'Table.HeadText'
    [void](Add-WtChild $table $head)
    $rows = @($data.Entries | Where-Object { $_.State -in 'ok', 'readonly' -and $_.Date -and $_.Date.Year -eq $ui.Year } | Sort-Object Date, Kind)
    $ko = [System.Globalization.CultureInfo]::GetCultureInfo('ko-KR')
    foreach ($entry in $rows) {
        $origin = Get-WtField $entry.Item 'origin'
        $from = if (Test-WtRecordObject $origin) { [string](Get-WtField $origin 'from') } else { '' }
        $where = switch ($from) { 'auto' { '자동' } 'paste' { '붙여 넣기' } default { '직접' } }
        $kind = if ($script:holidayKinds.Contains($entry.Kind)) { $script:holidayKinds[$entry.Kind] } else { $entry.Kind }
        $row = [System.Windows.Controls.Border]::new(); Set-WtStyle $row 'Table.Row'
        $row.Child = New-WtHolidayRowGrid @($entry.Date.ToString('M월 d일', $ko), $entry.Date.ToString('ddd', $ko), $entry.Name, $kind, $where) 'Table.Cell'
        [System.Windows.Automation.AutomationProperties]::SetName($row, "$($entry.Date.ToString('M월 d일', $ko)) $($entry.Name) $kind")
        $row.Tag = $entry
        $menu = New-WtContextMenu
        foreach ($action in '이름 바꾸기', '지우기') {
            $item = [System.Windows.Controls.MenuItem]::new(); $item.Header = $action; $item.Tag = @{ Entry = $entry; Action = $action }
            $item.IsEnabled = $entry.State -eq 'ok'
            $item.Add_Click({ param($s, $e) if ($s.Tag.Action -eq '지우기') { Remove-WtHolidayEntry $s.Tag.Entry } else { Show-WtHolidayDialog -Entry $s.Tag.Entry } })
            [void]$menu.Items.Add($item)
        }
        $row.ContextMenu = $menu
        $row.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Delete' -and $s.Tag.State -eq 'ok') { Remove-WtHolidayEntry $s.Tag; $e.Handled = $true } elseif ($e.Key -eq 'F2' -and $s.Tag.State -eq 'ok') { Show-WtHolidayDialog -Entry $s.Tag; $e.Handled = $true } })
        [void](Add-WtChild $table $row)
    }
    if (-not $rows.Count) { [void](Add-WtChild $table (New-WtText '이 해에는 휴무일이 없습니다.' 'Table.Empty')) }
}
# 표 한 줄: 날짜 110 · 요일 56 · 이름(나머지) · 종류 110 · 넣은 곳 90. 머리 줄과 같은 칸을 쓴다
function New-WtHolidayRowGrid([string[]]$Values, [string]$Style) {
    $grid = [System.Windows.Controls.Grid]::new()
    $widths = @(110, 56, -1, 110, 90)
    for ($i = 0; $i -lt 5; $i++) {
        $column = [System.Windows.Controls.ColumnDefinition]::new()
        $column.Width = if ($widths[$i] -lt 0) { [System.Windows.GridLength]::new(1, 'Star') } else { [System.Windows.GridLength]::new($widths[$i]) }
        $grid.ColumnDefinitions.Add($column)
        $text = New-WtText $Values[$i] $(if ($Style -eq 'Table.Cell' -and $i -in 1, 3, 4) { 'Table.CellSub' } else { $Style })
        [System.Windows.Controls.Grid]::SetColumn($text, $i); [void]$grid.Children.Add($text)
    }
    $grid
}
function Remove-WtHolidayEntry($Entry) {
    try {
        $r = Set-WtHolidayDate (Get-WtHolidayData).Store $Entry.DateText $Entry.Kind -Enabled $false
        if (-not $r.Success) { throw $r.Reason }
    } catch { Show-WtMessage "휴무일을 지우지 못했습니다. $($_.Exception.Message)" 'WorkTool' 'Warning' }
    Update-WtHolidayTable
}

# 휴무일 추가(날짜 ~ 끝 날짜, 이름, 종류) 또는 이름 바꾸기(-Entry). 하루 하나씩 저장한다(연휴는 날마다 한 항목)
function Show-WtHolidayDialog($Entry) {
    $dialog = New-WtModal $(if ($Entry) { '휴무일 이름 바꾸기' } else { '휴무일 추가' })
    $fields = @{}
    $today = [datetime]::Today
    $first = if ($script:holidayUi -and $script:holidayUi.Year -ne $today.Year) { [datetime]::new($script:holidayUi.Year, 1, 1) } else { $today }
    if (-not $Entry) {
        [void](Add-WtChild $dialog.Body (New-WtText '날짜' 'Setting.Label'))
        $range = New-WtStack Horizontal 8
        foreach ($key in 'From', 'To') {
            $box = [System.Windows.Controls.TextBox]::new(); Set-WtStyle $box 'Input'; $box.Width = 140; $box.Text = ConvertTo-WtDateText $first
            [System.Windows.Automation.AutomationProperties]::SetName($box, $(if ($key -eq 'From') { '시작 날짜' } else { '끝 날짜' }))
            $fields[$key] = $box; [void](Add-WtChild $range $box)
            if ($key -eq 'From') { $dash = New-WtText '~' 'Schedule.RangeDash'; [void](Add-WtChild $range $dash) }
        }
        [void](Add-WtChild $dialog.Body $range)
    }
    [void](Add-WtChild $dialog.Body (New-WtText '이름' 'Setting.Label'))
    $name = [System.Windows.Controls.TextBox]::new(); Set-WtStyle $name 'Input'; $name.Text = if ($Entry) { $Entry.Name } else { '회사 휴무' }
    [System.Windows.Automation.AutomationProperties]::SetName($name, '이름'); $fields.Name = $name
    [void](Add-WtChild $dialog.Body $name)
    if (-not $Entry) {
        [void](Add-WtChild $dialog.Body (New-WtText '종류' 'Setting.Label'))
        $kind = [System.Windows.Controls.ComboBox]::new(); Set-WtStyle $kind 'Combo'
        foreach ($k in $script:holidayKinds.Keys) { [void]$kind.Items.Add($script:holidayKinds[$k]) }
        $kind.SelectedIndex = 1; [System.Windows.Automation.AutomationProperties]::SetName($kind, '종류'); $fields.Kind = $kind
        [void](Add-WtChild $dialog.Body $kind)
    }
    $ok = New-WtButton $(if ($Entry) { '바꾸기' } else { '추가' }) -Kind Primary; $ok.IsDefault = $true
    $cancel = New-WtButton '취소'; $cancel.IsCancel = $true
    $dialog.Window.Tag = @{ Fields = $fields; Entry = $Entry; Error = $dialog.Error }
    $ok.Tag = $dialog.Window
    $ok.Add_Click({
        param($s, $e)
        $w = $s.Tag
        $reason = Save-WtHolidayDialog $w.Tag.Fields $w.Tag.Entry
        if ($reason) { $w.Tag.Error.Text = $reason; $w.Tag.Error.Visibility = 'Visible' } else { $w.DialogResult = $true }
    })
    [void](Add-WtChild $dialog.Buttons $ok); [void](Add-WtChild $dialog.Buttons $cancel)
    $dialog.Window.Add_ContentRendered({ param($s, $e) $f = $s.Tag.Fields; $target = if ($f.From) { $f.From } else { $f.Name }; [void]$target.Focus(); $target.SelectAll() })
    if ($dialog.Window.ShowDialog() -eq $true) { Update-WtHolidayTable }
}
# 대화상자 값 저장. 틀리면 이유를 돌려준다(저장 안 함)
function Save-WtHolidayDialog($Fields, $Entry) {
    $name = $Fields.Name.Text.Trim()
    if (-not $name) { return '이름을 입력하세요.' }
    try {
        if ($Entry) {
            $r = Set-WtHolidayDate (Get-WtHolidayData).Store $Entry.DateText $Entry.Kind -Name $name -Note $Entry.Note
            if (-not $r.Success) { return $r.Reason }
            return ''
        }
        $from = ConvertFrom-WtDateText $Fields.From.Text.Trim(); $to = ConvertFrom-WtDateText $Fields.To.Text.Trim()
        if (-not $from) { return '시작 날짜를 확인하세요. 예: 2026-12-31' }
        if (-not $to -or $to -lt $from) { return '끝 날짜를 확인하세요. 시작 날짜와 같거나 뒤여야 합니다.' }
        if (($to - $from).Days -gt 30) { return '한 번에 31일까지 넣을 수 있습니다.' }
        $kind = @($script:holidayKinds.Keys)[$Fields.Kind.SelectedIndex]
        $store = (Get-WtHolidayData).Store
        for ($d = $from; $d -le $to; $d = $d.AddDays(1)) {
            $r = Set-WtHolidayDate $store (ConvertTo-WtDateText $d) $kind -Name $name
            if (-not $r.Success) { return $r.Reason }
            $store = $r.Store
        }
        if ($script:holidayUi) { $script:holidayUi.Year = $from.Year }
        ''
    } catch { $_.Exception.Message }
}

# ---- 업무시간: 첫 설정과 일반 설정이 같은 입력 · 검사를 사용한다. ------------------------------

function Get-WtWorkFormHours($Form) {
    $hours = @{ 'work.days' = @($Form.Days | Where-Object IsChecked | ForEach-Object { [int]$_.Tag.Day }) }
    foreach ($k in $Form.Boxes.Keys) { $hours[$k] = $Form.Boxes[$k].Text }
    $hours
}

function Update-WtWorkForm($Form, [switch]$Save) {
    if ($Form.Loading) { return $false }
    $hours = Get-WtWorkFormHours $Form
    $errors = Get-WtWorkHoursErrors $hours
    foreach ($k in $Form.Errors.Keys) {
        $message = if ($errors.Contains($k)) { [string]$errors[$k] } else { '' }
        $Form.Errors[$k].Text = $message
        $Form.Errors[$k].Visibility = if ($message) { 'Visible' } else { 'Collapsed' }
        if ($Form.Boxes.ContainsKey($k)) {
            $box = $Form.Boxes[$k]
            $binding = $box.GetBindingExpression([System.Windows.FrameworkElement]::DataContextProperty)
            if ($message) {
                $errorInfo = [System.Windows.Controls.ValidationError]::new([System.Windows.Controls.ExceptionValidationRule]::new(), $binding, $message, $null)
                [System.Windows.Controls.Validation]::MarkInvalid($binding, $errorInfo)
            } else { [System.Windows.Controls.Validation]::ClearInvalid($binding) }
        }
    }
    Update-WtHalfDayHint $Form $hours $errors
    if ($errors.Count) { return $false }
    if ($Save) { Set-WtWorkHours $hours -From $Form.From }
    $true
}

# 반차 나누는 시각 옆 안내: 지금 값으로 계산한 오전 · 오후 반차 시간대(비우면 자동). 틀린 칸이 있으면 비운다
function Update-WtHalfDayHint($Form, [hashtable]$Hours, $Errors) {
    if (-not $Form.HalfHint) { return }
    if (@($Errors.Keys | Where-Object { $_ -cne 'work.days' }).Count) { $Form.HalfHint.Text = ''; return }
    $split = Get-WtHalfDaySplit $Hours
    $auto = if ($Hours['work.halfDay']) { '' } else { ' (자동)' }
    $Form.HalfHint.Text = "오전 반차 $($Hours['work.start']) ~ $split · 오후 반차 $split ~ $($Hours['work.end'])$auto"
}

function Reset-WtWorkForm($Form) {
    $Form.Loading = $true
    try {
        $hours = if ($Form.FirstSetup) { Get-WtWorkHours -Defaults } else { Get-WtWorkHours -From $Form.From }
        if ($null -eq $hours) { $Form.From = ''; $hours = Get-WtWorkHours -From '' }
        foreach ($cb in $Form.Days) { $cb.IsChecked = $hours['work.days'] -contains $cb.Tag.Day }
        foreach ($k in $Form.Boxes.Keys) { $Form.Boxes[$k].Text = $hours[$k] }
    } finally { $Form.Loading = $false }
    [void](Update-WtWorkForm $Form)
}

# ---- 업무시간 기간(설계 15.1): 적용 기간 고르기 · 새 기간 · 기간 지우기 ------------------------------

# 기간 목록 @{ From; Label }. 「처음부터」 다음에 적용 시작일 순. 끝 날짜는 다음 기간 앞날, 오늘 적용되는 기간에 「 · 지금」
function Get-WtWorkPeriodChoices {
    $periods = @(Get-WtWorkPeriods)
    $current = [string](Get-WtWorkHours)['work.from']
    $froms = @('') + @($periods | ForEach-Object { $_.From })
    for ($i = 0; $i -lt $froms.Count; $i++) {
        $label = if ($froms[$i]) { "$($froms[$i])부터" } else { '처음부터' }
        if ($i + 1 -lt $froms.Count) { $label += ' ~ ' + (ConvertTo-WtDateText (ConvertFrom-WtDateText $froms[$i + 1]).AddDays(-1)) }
        if ($froms[$i] -ceq $current) { $label += ' · 지금' }
        [pscustomobject]@{ From = $froms[$i]; Label = $label }
    }
}

# 기간 고르기 칸을 다시 채우고 From 기간을 고른다(없으면 오늘 적용되는 기간)
function Update-WtWorkPeriodPicker($Form, [string]$From) {
    if (-not $Form.Periods) { return }
    $choices = @(Get-WtWorkPeriodChoices)
    if ($From -cnotin @($choices | ForEach-Object { $_.From })) { $From = [string](Get-WtWorkHours)['work.from'] }
    $Form.Loading = $true
    try {
        $Form.Periods.Items.Clear(); $Form.PeriodFroms = @($choices | ForEach-Object { $_.From })
        foreach ($c in $choices) { [void]$Form.Periods.Items.Add($c.Label) }
        $Form.Periods.SelectedIndex = [array]::IndexOf($Form.PeriodFroms, $From)
    } finally { $Form.Loading = $false }
    $Form.From = $From
    $Form.RemovePeriod.Visibility = if ($From) { 'Visible' } else { 'Collapsed' }
    Reset-WtWorkForm $Form
}

# 새 기간: 적용 시작일을 받아 그날 규칙을 복사해 더하고, 그 기간을 고른다
function Show-WtWorkPeriodDialog($Form) {
    $dialog = New-WtModal '새 업무시간 기간'
    [void](Add-WtChild $dialog.Body (New-WtText '적용 시작일' 'Setting.Label'))
    $box = [System.Windows.Controls.TextBox]::new(); Set-WtStyle $box 'Input'; $box.Width = 160; $box.HorizontalAlignment = 'Left'
    $box.Text = ConvertTo-WtDateText ([datetime]::Today); [System.Windows.Automation.AutomationProperties]::SetName($box, '적용 시작일')
    [void](Add-WtChild $dialog.Body $box)
    [void](Add-WtChild $dialog.Body (New-WtText '그날부터 새 규칙을 씁니다. 처음 값은 그날 쓰던 규칙을 복사하니 아래에서 고치세요.' 'T.Sub'))
    $ok = New-WtButton '추가' -Kind Primary; $ok.IsDefault = $true
    $cancel = New-WtButton '취소'; $cancel.IsCancel = $true
    $dialog.Window.Tag = @{ Box = $box; Error = $dialog.Error; From = '' }
    $ok.Tag = $dialog.Window
    $ok.Add_Click({
        param($s, $e)
        $w = $s.Tag; $from = $w.Tag.Box.Text.Trim()
        try { Add-WtWorkPeriod $from; $w.Tag.From = $from; $w.DialogResult = $true }
        catch { $w.Tag.Error.Text = $_.Exception.Message; $w.Tag.Error.Visibility = 'Visible' }
    })
    [void](Add-WtChild $dialog.Buttons $ok); [void](Add-WtChild $dialog.Buttons $cancel)
    $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Box.Focus(); $s.Tag.Box.SelectAll() })
    if ($dialog.Window.ShowDialog() -eq $true) { Update-WtWorkPeriodPicker $Form $dialog.Window.Tag.From }
}

# 고른 기간을 지운다(묻고 나서). 그 기간의 날은 앞 기간 규칙을 따른다
function Remove-WtWorkPeriodChoice($Form) {
    if (-not $Form.From) { return }
    if (-not (Confirm-WtYesNo "$($Form.From)부터의 업무시간 기간을 지울까요?`n그 기간의 날은 앞 기간의 규칙으로 계산합니다.")) { return }
    try { Remove-WtWorkPeriod $Form.From } catch { Show-WtMessage "기간을 지우지 못했습니다. $($_.Exception.Message)" 'WorkTool' 'Warning' }
    Update-WtWorkPeriodPicker $Form ''
}

function New-WtWorkHoursForm([switch]$FirstSetup) {
    $col = New-WtStack Vertical
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)
    $form = @{ Root = $col; Boxes = @{}; Errors = @{}; Days = @(); FirstSetup = [bool]$FirstSetup; Loading = $true; Start = $null
        From = ''; Periods = $null; PeriodFroms = @(); RemovePeriod = $null; HalfHint = $null }
    if (-not $FirstSetup) {
        # 적용 기간: 고른 기간의 규칙을 아래에서 고친다. 새 기간은 적용 시작일을 받는다(설계 15.1)
        $periodRow = New-WtStack Horizontal 8
        $picker = [System.Windows.Controls.ComboBox]::new(); Set-WtStyle $picker 'Combo'; $picker.Width = 240; $picker.Tag = $form
        [System.Windows.Automation.AutomationProperties]::SetName($picker, '적용 기간')
        [System.Windows.Automation.AutomationProperties]::SetAutomationId($picker, 'Settings-WorkPeriod')
        $picker.Add_SelectionChanged({
                param($s, $e)
                $f = $s.Tag
                if ($f.Loading -or $s.SelectedIndex -lt 0) { return }
                $f.From = $f.PeriodFroms[$s.SelectedIndex]
                $f.RemovePeriod.Visibility = if ($f.From) { 'Visible' } else { 'Collapsed' }
                Reset-WtWorkForm $f
            })
        $add = New-WtButton '새 기간'; $add.Tag = $form; $add.Add_Click({ param($s, $e) Show-WtWorkPeriodDialog $s.Tag })
        $remove = New-WtButton '기간 지우기' -Kind Danger; $remove.Tag = $form; $remove.Add_Click({ param($s, $e) Remove-WtWorkPeriodChoice $s.Tag })
        $form.Periods = $picker; $form.RemovePeriod = $remove
        foreach ($c in $picker, $add, $remove) { [void](Add-WtChild $periodRow $c) }
        [void](Add-WtChild $col (New-WtSettingRow '적용 기간' $periodRow))
    }
    $daysCol = New-WtStack Vertical 4
    $daysRow = [System.Windows.Controls.WrapPanel]::new()
    $dayNames = @('월', '화', '수', '목', '금', '토', '일')
    for ($n = 1; $n -le 7; $n++) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        Set-WtStyle $cb 'Check'
        $cb.Content = $dayNames[$n - 1]
        $cb.Margin = [System.Windows.Thickness]::new(0, 0, 16, 0)
        $cb.Tag = @{ Form = $form; Day = $n }
        $cb.Add_Click({ param($s, $e) [void](Update-WtWorkForm $s.Tag.Form -Save:(-not $s.Tag.Form.FirstSetup)) })
        $form.Days += $cb
        [void]$daysRow.Children.Add($cb)
    }
    [void](Add-WtChild $daysCol $daysRow)
    $dayError = New-WtText '' 'T.Sub'
    Set-WtResource $dayError Foreground 'B.Status.Error.Text'
    $form.Errors['work.days'] = $dayError
    [void](Add-WtChild $daysCol $dayError)
    [void](Add-WtChild $col (New-WtSettingRow '일하는 요일' $daysCol))
    $timeFields = @(@('work.start', '시작 시각'), @('work.end', '끝 시각'), @('work.lunchStart', '점심 시작 시각'), @('work.lunchEnd', '점심 끝 시각'))
    # 반차 나누는 시각은 일반 설정에만(첫 설정은 짧게 둔다). 비우면 자동
    if (-not $FirstSetup) { $timeFields += , @('work.halfDay', '반차 나누는 시각') }
    foreach ($field in $timeFields) {
        $group = New-WtStack Vertical 4
        $box = [System.Windows.Controls.TextBox]::new()
        Set-WtStyle $box 'Setting.Time'
        [System.Windows.Automation.AutomationProperties]::SetName($box, $field[1])
        $box.Tag = $form
        # 별도 바인딩에 오류를 연결한다. Text를 직접 바꾸는 UIA 입력도 바인딩을 끊지 않는다.
        $binding = [System.Windows.Data.Binding]::new()
        $binding.Source = [pscustomobject]@{ Field = $field[0] }
        [void]$box.SetBinding([System.Windows.FrameworkElement]::DataContextProperty, $binding)
        $box.Add_TextChanged({ param($s, $e) [void](Update-WtWorkForm $s.Tag) })
        $box.Add_LostKeyboardFocus({ param($s, $e) if (-not $s.Tag.FirstSetup) { [void](Update-WtWorkForm $s.Tag -Save) } })
        $box.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Return' -and -not $s.Tag.FirstSetup) { [void](Update-WtWorkForm $s.Tag -Save); $e.Handled = $true }
        })
        $form.Boxes[$field[0]] = $box
        if ($field[0] -ceq 'work.halfDay') {
            # 옆에 지금 값으로 계산한 시간대(F.Caption · B.Text.Tertiary)
            $line = New-WtStack Horizontal 12
            $hint = New-WtText '' 'T.CaptionMuted'; $hint.VerticalAlignment = 'Center'; $form.HalfHint = $hint
            [void](Add-WtChild $line $box); [void](Add-WtChild $line $hint); [void](Add-WtChild $group $line)
        } else { [void](Add-WtChild $group $box) }
        $errorText = New-WtText '' 'T.Sub'
        Set-WtResource $errorText Foreground 'B.Status.Error.Text'
        [System.Windows.Automation.AutomationProperties]::SetLiveSetting($errorText, 'Polite')
        $form.Errors[$field[0]] = $errorText
        [void](Add-WtChild $group $errorText)
        $row = New-WtSettingRow $field[1] $group
        [System.Windows.Automation.AutomationProperties]::SetLabeledBy($box, $row.Tag)
        [void](Add-WtChild $col $row)
    }
    if ($FirstSetup) {
        $start = New-WtButton '시작' -Kind Primary
        $start.HorizontalAlignment = 'Left'
        $start.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
        $start.Tag = $form
        $start.Add_Click({ param($s, $e) if (Update-WtWorkForm $s.Tag -Save) { [void](Close-WtFirstWorkSetup) } })
        $form.Start = $start
        [void](Add-WtChild $col $start)
    }
    $col.Tag = $form
    # 다시 보일 때 기간 목록도 새로 읽는다(다른 곳에서 기간이 바뀌었을 수 있다)
    $col.Add_Loaded({ param($s, $e) if ($s.Tag.Periods) { Update-WtWorkPeriodPicker $s.Tag $s.Tag.From } else { Reset-WtWorkForm $s.Tag } })
    if ($form.Periods) { Update-WtWorkPeriodPicker $form '' } else { Reset-WtWorkForm $form }
    $form
}

# 창 안의 본문을 덮는다. 제목 줄은 남기며 메뉴 · 단축키로 설정을 건너뛰지 못한다.
function Show-WtFirstWorkSetup($Window, [string]$HomePage) {
    if ($script:firstWorkSetup -or -not (Test-WtWorkSetupRequired)) { return }
    $page = New-WtPage
    $page.Panel.Margin = [System.Windows.Thickness]::new(16)
    $close = New-WtButton -Kind Icon -Icon 0xE711 -ToolTip '닫기 (Esc)'
    [System.Windows.Automation.AutomationProperties]::SetName($close, '업무시간 닫기')
    $close.Add_Click({ [void](Close-WtFirstWorkSetup -UseDefaults) })
    $heading = New-WtPageHeader '업무시간' -Right $close
    $heading.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [void](Add-WtChild $page.Panel $heading)
    $form = New-WtWorkHoursForm -FirstSetup
    [void](Add-WtChild $page.Panel $form.Root)
    $overlay = [System.Windows.Controls.Border]::new()
    Set-WtResource $overlay Background 'B.Bg.Surface'
    $overlay.Child = $page.Root
    [System.Windows.Controls.Grid]::SetRow($overlay, 1)
    $grid = $Window.Content.Child
    $script:firstWorkSetup = @{ Window = $Window; Grid = $grid; Overlay = $overlay; Form = $form; Home = $HomePage }
    [void]$grid.Children.Add($overlay)
    [System.Windows.Input.KeyboardNavigation]::SetTabNavigation($overlay, 'Cycle')
    [void]$form.Boxes['work.start'].Focus()
}

# 닫기 · Esc는 편집 중인 값 대신 기본값을 저장한다. 셸의 X도 같은 통로를 사용한다.
function Close-WtFirstWorkSetup([switch]$UseDefaults) {
    if (-not $script:firstWorkSetup) { return $false }
    if ($UseDefaults) {
        Set-WtWorkHours (Get-WtWorkHours -Defaults)
    }
    $setup = $script:firstWorkSetup
    [void]$setup.Grid.Children.Remove($setup.Overlay)
    $script:firstWorkSetup = $null
    Select-WtPage $setup.Home
    $true
}

function Invoke-WtWorkSetupKey($Event) {
    if (-not $script:firstWorkSetup) { return $false }
    if ($Event.Key -eq 'Escape') { [void](Close-WtFirstWorkSetup -UseDefaults); $Event.Handled = $true; return $true }
    # 첫 설정 중에는 셸의 화면 전환 단축키만 막는다. 입력칸의 Ctrl+A · C · V는 유지한다.
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
    if ($Event.Key -in 'F1', 'F11' -or ($ctrl -and ($Event.Key -in 'B', 'OemComma' -or ($Event.Key -ge 'D1' -and $Event.Key -le 'D9')))) {
        $Event.Handled = $true
        return $true
    }
    $false
}

# ---- 도움말 -----------------------------------------------------------------------------------

function New-WtKeyRow([string]$Keys, [string]$What, [switch]$Header) {
    $row = [System.Windows.Controls.Border]::new()
    Set-WtResource $row BorderBrush 'B.Border.Muted'
    $row.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $row.Padding = [System.Windows.Thickness]::new(0, 8, 0, 8)
    $grid = [System.Windows.Controls.Grid]::new()
    $keyColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $keyColumn.Width = [System.Windows.GridLength]::Auto
    $keyColumn.SharedSizeGroup = 'WtHelpKeys'
    $grid.ColumnDefinitions.Add($keyColumn)
    $grid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
    $k = if ($Header) { New-WtText $Keys 'T.Strong' } else { New-WtTag $Keys }
    $k.MinWidth = 120
    $k.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $whatText = New-WtText $What $(if ($Header) { 'T.Strong' } else { 'T.Body' })
    [System.Windows.Controls.Grid]::SetColumn($whatText, 1)
    [void]$grid.Children.Add($k)
    [void]$grid.Children.Add($whatText)
    $row.Child = $grid
    $row
}

# 탭이 등록한 단축키를 메뉴 순서대로 모은다. 키와 설명이 같으면 한 줄로 묶는다 (예: 문서 · 활성 작업: 새로 고침)
function Get-WtShortcutRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @(Get-WtAddon)) {
        foreach ($s in @($a.Shortcuts)) {
            $same = $rows | Where-Object { $_.Key -ceq $s[0] -and $_.What -ceq $s[1] } | Select-Object -First 1
            if ($same) { $same.Titles.Add($a.Title); continue }
            $titles = [System.Collections.Generic.List[string]]::new()
            $titles.Add($a.Title)
            $rows.Add([pscustomobject]@{ Key = [string]$s[0]; What = [string]$s[1]; Titles = $titles })
        }
    }
    foreach ($r in $rows) { [pscustomobject]@{ Key = $r.Key; Text = '{0}: {1}' -f ($r.Titles -join ' · '), $r.What } }
}

function New-WtHelpPage {
    $keys = New-WtCard
    $col = New-WtStack Vertical
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)
    [void](Add-WtChild $col (New-WtKeyRow '키' '하는 일' -Header))
    foreach ($r in @(
            @('Ctrl + 1 ~ 9', '메뉴 순서대로 화면 이동'),
            @('Ctrl + B', '메뉴 접기 / 펼치기'),
            @('Ctrl + Shift + B', '사이드바 접기 순서 전환'),
            @('F11', '전체 화면 (Esc로 나가기)'),
            @('Ctrl + ,', '설정'),
            @('F1', '도움말'))) {
        [void](Add-WtChild $col (New-WtKeyRow $r[0] $r[1]))
    }
    foreach ($r in @(Get-WtShortcutRows)) { [void](Add-WtChild $col (New-WtKeyRow $r.Key $r.Text)) }
    $keys.Child = $col

    $tabs = New-WtStack Vertical 16
    foreach ($a in @(Get-WtAddon)) {
        $section = New-WtStack Vertical 8
        [void](Add-WtChild $section (New-WtCardHeader $a.Title))
        foreach ($line in @($a.Help)) { [void](Add-WtChild $section (New-WtText $line 'T.Body')) }
        if ($a.HelpCard) {
            try {
                foreach ($el in @(& $a.HelpCard)) { if ($el -is [System.Windows.UIElement]) { [void](Add-WtChild $section $el) } }
            } catch {
                [void](Add-WtChild $section (New-WtText "$($a.Title) 도움말을 만들지 못했습니다: $($_.Exception.Message)" 'T.Sub'))
            }
        }
        [void](Add-WtChild $tabs $section)
    }

    $tabsCard = New-WtCard
    $tabsCard.Child = $tabs

    $win = New-WtCard
    $col = New-WtStack Vertical
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)
    $rootText = New-WtText (Get-WtDataRoot) 'T.Body'
    Set-WtResource $rootText 'FontFamily' 'Font.Mono'
    [void](Add-WtChild $col (New-WtSettingRow '데이터 폴더' $rootText))
    $win.Child = $col
    New-WtTabbedPage '도움말' @(@('단축키', $keys), @('탭', $tabsCard), @('정보', $win))
}

Export-ModuleMember -Function New-WtSettingsPage, New-WtHelpPage, Show-WtFirstWorkSetup, Close-WtFirstWorkSetup, Invoke-WtWorkSetupKey

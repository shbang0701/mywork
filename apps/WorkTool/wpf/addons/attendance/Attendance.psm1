# 근태 탭 화면 (1단계: 보기 전용). 기록 · 지금 출근 · 퇴근은 2단계에서 옮긴다.
# 데이터 형식 · 읽기 · 예전 데이터 가져오기 · 월 요약 규칙은 AttendanceData.psm1 (화면 없음). 이 파일은 그 결과를 그리기만 한다.
# 저장 값은 영문 코드(work · half-pm …)이고, 화면 이름은 아래 표에서 꺼낸다. 이름을 바꿔도 옛 기록의 계산은 그대로다.

$ErrorActionPreference = 'Stop'

$script:month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
$script:body = $null
$script:monthLabel = $null
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture

# 코드 → 화면 이름 · 표시 색 (Theme.psm1의 Att.*)
$script:kindNames = @{ work = '출근'; overtime = '업무외시간'; trip = '출장'; leave = '휴가'; other = '기타' }
$script:kindColor = @{ work = 'Att.Work'; overtime = 'Att.Over'; trip = 'Att.Trip'; leave = 'Att.Leave' }
$script:leaveNames = @{ annual = '연차'; half = '반차'; 'half-am' = '오전 반차'; 'half-pm' = '오후 반차'; sick = '병가'; family = '경조사'; comp = '대체 휴무'; other = '휴가' }
$script:howNames = @{ remote = '원격'; onsite = '현장' }

function Format-WtHours([int]$Minutes) {
    $h = [Math]::Round($Minutes / 60, 1)
    if ($h -eq [Math]::Floor($h)) { $h.ToString('0', $script:inv) } else { $h.ToString('0.0', $script:inv) }
}

function Format-WtDays([double]$Days) { $Days.ToString('0.#', $script:inv) }

# 그 달과 겹치는 계산할 수 있는 기록
function Test-WtAttInMonth($Entry, [datetime]$Month) {
    $first = [datetime]::new($Month.Year, $Month.Month, 1)
    $Entry.State -eq 'ok' -and $Entry.StartDate -le $first.AddMonths(1).AddDays(-1) -and $Entry.EndDate -ge $first
}

function New-WtAttTiles($Summary, [int]$Columns) {
    $g = [System.Windows.Controls.Primitives.UniformGrid]::new()
    $g.Columns = $Columns
    foreach ($t in @(
            @('출근', "$($Summary.WorkDays)", '일', 'Att.Work'),
            @('업무외시간', (Format-WtHours $Summary.OverMinutes), "시간 · $($Summary.OverCount)건", 'Att.Over'),
            @('출장', "$($Summary.TripDays)", "일 · $($Summary.TripCount)건", 'Att.Trip'),
            @('휴가', (Format-WtDays $Summary.LeaveDays), '일', 'Att.Leave'))) {
        $tile = New-WtStatTile $t[0] $t[1] $t[2] $t[3]
        $tile.Margin = [System.Windows.Thickness]::new(0, 0, 10, 10)
        [void]$g.Children.Add($tile)
    }
    $g
}

# 기록 한 줄: 날짜 · 종류 · 시간(또는 휴가 종류 · 일수) · 장소와 메모
function New-WtAttRow($Entry) {
    $s = $Entry.StartDate
    $e = $Entry.EndDate
    $dateText = if ($e -gt $s) { '{0} ~ {1}' -f (Format-WtDate $s "M'/'d"), (Format-WtDate $e "M'/'d") } else { Format-WtDate $s "M'/'d (ddd)" }
    $date = New-WtText $dateText 'T.Body'
    $date.Width = 110
    $tagBox = [System.Windows.Controls.Border]::new()
    $tagBox.Width = 130
    $name = $script:kindNames[$Entry.Kind]
    $color = $script:kindColor[$Entry.Kind]
    $tagBox.Child = if ($color) { New-WtTag $name "${color}Bg" $color } else { New-WtTag $name }
    $hm = { param($t) $t.ToString('HH:mm', $script:inv) }
    $time = switch ($Entry.Kind) {
        'work' {
            if (-not $Entry.HasTime) { '시각 없음' }
            elseif ($Entry.HasEnd) { '{0} ~ {1} ({2}시간)' -f (& $hm $Entry.Start), (& $hm $Entry.End), (Format-WtHours $Entry.Minutes) }
            else { '{0} ~ 퇴근 기록 없음' -f (& $hm $Entry.Start) }
        }
        'overtime' {
            $how = $script:howNames[[string]$Entry.How]
            $text = if (-not $Entry.HasTime) { '시각 없음' }
            elseif ($Entry.HasEnd) { '{0} ~ {1} ({2}시간)' -f (& $hm $Entry.Start), (& $hm $Entry.End), (Format-WtHours $Entry.Minutes) }
            else { '{0} ~ 끝 시각 없음' -f (& $hm $Entry.Start) }
            if ($how) { "$text · $how" } else { $text }
        }
        'leave' {
            $ln = $script:leaveNames[[string]$Entry.LeaveType]
            if ($null -ne $Entry.LeaveDays) { '{0} {1}일' -f $ln, (Format-WtDays $Entry.LeaveDays) } else { $ln }
        }
        default { if ($e -gt $s) { '{0}일' -f (($e - $s).Days + 1) } else { '하루' } }
    }
    $timeText = New-WtText ([string]$time) 'T.Body'
    $timeText.Width = 190
    $noteParts = @($Entry.Place, $Entry.Ref, $Entry.Note) | Where-Object { $_ }
    $note = New-WtText ($noteParts -join ' · ') 'T.Sub'
    New-WtListRow @($date, $tagBox, $timeText, $note)
}

# 못 읽은 파일 · 고칠 항목 · 새 버전 기록 안내 카드들. 없으면 아무것도 돌려주지 않는다.
# 휴무일 파일을 못 읽으면 휴가 일수가 주말만 빼고 계산되므로 그것도 알린다
function New-WtAttNotices($Data, $Holidays) {
    if ($Holidays -and $Holidays.Error) {
        $card = New-WtCard
        $col = New-WtStack Vertical 8
        [void](Add-WtChild $col (New-WtTag '휴무일을 읽지 못해 휴가 · 출장 일수에서 주말만 뺐습니다' 'WarnBg' 'Warn'))
        [void](Add-WtChild $col (New-WtText $Holidays.Error 'T.Sub'))
        $card.Child = $col
        $card
    }
    if ($Data.Error) {
        $card = New-WtCard
        $col = New-WtStack Vertical 8
        [void](Add-WtChild $col (New-WtCardHeader '근태 파일을 읽지 못했습니다'))
        [void](Add-WtChild $col (New-WtTag '읽기 전용' 'WarnBg' 'Warn'))
        [void](Add-WtChild $col (New-WtText $Data.Error 'T.Body'))
        [void](Add-WtChild $col (New-WtText '파일은 바꾸지 않았습니다. 데이터 폴더의 attendance.json과 백업(.bak)을 확인하세요.' 'T.Sub'))
        $card.Child = $col
        $card
        return
    }
    foreach ($g in @(
            @('broken', '고칠 항목', '날짜 · 시각을 읽지 못해 목록과 합계에서 뺐습니다. 저장할 때는 그대로 둡니다.'),
            @('readonly', '새 버전에서 만든 기록', '이 버전이 모르는 값이 있어 읽기만 하고, 목록과 합계에서 뺐습니다. 저장할 때는 그대로 둡니다.'))) {
        $rows = @($Data.Entries | Where-Object { $_.State -eq $g[0] })
        if (-not $rows.Count) { continue }
        $card = New-WtCard
        $col = New-WtStack Vertical
        [void](Add-WtChild $col (New-WtCardHeader $g[1] "$($rows.Count)"))
        [void](Add-WtChild $col (New-WtText $g[2] 'T.Sub'))
        foreach ($r in $rows) {
            $label = @($(if ($r.StartDate) { Format-WtDate $r.StartDate "M'/'d" }), $r.Id) | Where-Object { $_ }
            $name = New-WtText ($label -join ' · ') 'T.Body'
            $name.Width = 200
            $name.TextTrimming = 'CharacterEllipsis'
            [void](Add-WtChild $col (New-WtListRow @($name, (New-WtText $r.Problem 'T.Sub'))))
        }
        $card.Child = $col
        $card
    }
}

function New-WtAttendanceView {
    $script:viewKey = $null
    $page = New-WtPage
    $nav = New-WtStack Horizontal 6
    $prev = New-WtButton '' -Icon 0xE76B -ToolTip '이전 달'
    $prev.Tag = -1
    $next = New-WtButton '' -Icon 0xE76C -ToolTip '다음 달'
    $next.Tag = 1
    $thisMonth = New-WtButton '이번 달'
    $thisMonth.Tag = 0
    foreach ($b in $prev, $next, $thisMonth) {
        $b.Add_Click({
                param($s, $e)
                $step = [int]$s.Tag
                $script:month = if ($step -eq 0) { [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1) } else { $script:month.AddMonths($step) }
                Update-WtAttendanceView
            })
    }
    $script:monthLabel = New-WtText '' 'T.H2'
    $script:monthLabel.VerticalAlignment = 'Center'
    $script:monthLabel.Margin = [System.Windows.Thickness]::new(6, 0, 6, 0)
    [void](Add-WtChild $nav $prev)
    [void](Add-WtChild $nav $script:monthLabel)
    [void](Add-WtChild $nav $next)
    [void](Add-WtChild $nav $thisMonth)
    [void](Add-WtChild $page.Panel (New-WtPageHeader '근태' '보기 전용 · 기록과 「지금 출근」은 2단계에서 옮깁니다' $nav))
    $script:body = New-WtStack Vertical 16
    [void](Add-WtChild $page.Panel $script:body)
    $page.Root
}

function Update-WtAttendanceView {
    $data = Get-WtAttendanceData
    $holidays = Get-WtHolidayData
    $key = @($data.Stamp, $holidays.Stamp, $script:month.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale'), (Get-WtSetting 'attendance.tripDays')) -join '|'
    if ($script:viewKey -ceq $key) { return }
    $script:monthLabel.Text = Format-WtDate $script:month 'yyyy년 M월'
    $script:body.Children.Clear()
    foreach ($n in @(New-WtAttNotices $data $holidays)) { [void](Add-WtChild $script:body $n) }
    [void](Add-WtChild $script:body (New-WtAttTiles (Get-WtAttendanceSummary $script:month $data.Entries) 4))
    $card = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader ('{0} 기록' -f (Format-WtDate $script:month 'M월'))))
    $rows = @($data.Entries | Where-Object { Test-WtAttInMonth $_ $script:month } |
        Sort-Object -Property @{ Expression = { $_.Start }; Descending = $true }, @{ Expression = { $_.Id }; Descending = $true })
    foreach ($r in $rows) { [void](Add-WtChild $col (New-WtAttRow $r)) }
    if (-not $rows.Count) { [void](Add-WtChild $col (New-WtText '이 달에는 기록이 없습니다.' 'T.Sub')) }
    $card.Child = $col
    [void](Add-WtChild $script:body $card)
    $script:viewKey = $key
}

function New-WtAttendanceHomeCard {
    $data = Get-WtAttendanceData
    $holidays = Get-WtHolidayData
    $key = @($data.Stamp, $holidays.Stamp, [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale'), (Get-WtSetting 'attendance.tripDays')) -join '|'
    if ($script:homeKey -ceq $key -and $script:homeCard -and -not $script:homeCard.Parent) { return $script:homeCard }
    $month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
    $card = New-WtCard
    $col = New-WtStack Vertical 8
    [void](Add-WtChild $col (New-WtCardHeader ('근태 · {0}' -f (Format-WtDate $month 'M월')) '' '근태 열기' 'attendance'))
    $in = $data.Entries | Where-Object { $_.State -eq 'ok' -and $_.Kind -eq 'work' -and $_.StartDate -eq [datetime]::Today } | Sort-Object Start | Select-Object -First 1
    $status = if ($data.Error) { New-WtTag '근태 파일을 읽지 못했습니다' 'WarnBg' 'Warn' }
    elseif ($in -and $in.HasEnd) { New-WtTag ('오늘 출근 {0} · 퇴근 {1}' -f $in.Start.ToString('HH:mm', $script:inv), $in.End.ToString('HH:mm', $script:inv)) 'SuccessBg' 'Success' }
    elseif ($in -and $in.HasTime) { New-WtTag "오늘 출근 $($in.Start.ToString('HH:mm', $script:inv))" 'SuccessBg' 'Success' }
    elseif ($in) { New-WtTag '오늘 출근' 'SuccessBg' 'Success' }
    else { New-WtTag '아직 출근 기록 없음' 'WarnBg' 'Warn' }
    [void](Add-WtChild $col $status)
    [void](Add-WtChild $col (New-WtAttTiles (Get-WtAttendanceSummary $month $data.Entries) 2))
    $card.Child = $col
    $script:homeCard = $card; $script:homeKey = $key
    $card
}

Register-WtAddon -Id 'attendance' -Title '근태' -Icon 0xE823 -Order 30 -WarmUp Full `
    -NewView { New-WtAttendanceView } `
    -Refresh { param($view) Update-WtAttendanceView } `
    -HomeCard { New-WtAttendanceHomeCard } `
    -ImportLegacy { param($folder) Import-WtAttendanceLegacy $folder } `
    -Help '근태는 보기만 합니다. 기록 · 지금 출근은 2단계에서 옮깁니다.'

Export-ModuleMember -Function Format-WtHours, Format-WtDays, Test-WtAttInMonth

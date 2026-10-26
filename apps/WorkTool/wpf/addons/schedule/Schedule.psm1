# 일정 탭 화면 (1단계: 보기 전용). 편집 · 알람은 2단계에서 옮긴다.
# 데이터 형식 · 읽기 · 예전 데이터 가져오기 · 반복 펼치기는 ScheduleData.psm1 (화면 없음). 이 파일은 그 결과를 그리기만 한다.
# 파일을 못 읽거나(더 새 버전 · 깨짐) 항목 몇 개를 못 읽어도 화면은 열린다: 못 읽은 이유 · 고칠 항목 · 새 버전 항목을 따로 보여 준다.

$ErrorActionPreference = 'Stop'

$script:list = $null
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
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

# 한 줄: 시각 · 표시(반복 · 알람 · 바뀐 회차 · 태그) · 제목. $Day는 이 줄을 놓는 날(여러 날에 걸친 일정의 둘째 날부터는 「~끝 시각」)
function New-WtScheduleRow($Occ, [string]$DayLabel, $Day) {
    $parts = [System.Collections.Generic.List[object]]::new()
    if ($DayLabel) {
        $d = New-WtText $DayLabel 'T.Sub'
        $d.Width = 84
        $parts.Add($d)
    }
    $when = if ($Occ.AllDay) { '하루 종일' }
    elseif ($null -eq $Day -or $Occ.Start.Date -ge ([datetime]$Day).Date) { $Occ.Start.ToString('HH:mm', $script:inv) }
    elseif ($Occ.LastDay -eq ([datetime]$Day).Date) { '~' + $Occ.End.ToString('HH:mm', $script:inv) }
    else { '하루 종일' }
    $t = New-WtText $when 'T.Strong'
    $t.Width = 72
    $parts.Add($t)
    $tags = New-WtStack Horizontal 6
    $rep = Get-WtRepeatLabel $Occ.Entry.Repeat
    if ($rep) { [void](Add-WtChild $tags (New-WtTag $rep -Icon 0xE8EE)) }
    $al = Format-WtAlarm @($Occ.Alarms)[0]
    if ($al) { [void](Add-WtChild $tags (New-WtTag $al -Icon 0xEA8F)) }
    if ($Occ.Changed) { [void](Add-WtChild $tags (New-WtTag '이 회차만 바뀜')) }
    foreach ($tag in @($Occ.Entry.Tags)) { if ($tag) { [void](Add-WtChild $tags (New-WtTag "#$tag")) } }
    if ($tags.Children.Count) { $parts.Add($tags) }
    $title = New-WtText $Occ.Title 'T.Body'
    $title.TextTrimming = 'CharacterEllipsis'
    $title.TextWrapping = 'NoWrap'
    $parts.Add($title)
    # 제목이 남는 폭을 채우도록 맨 끝에 둔다 (표시는 제목 앞)
    New-WtListRow $parts.ToArray()
}

# 못 읽은 파일 · 고칠 항목 · 새 버전 항목 안내 카드들. 없으면 아무것도 돌려주지 않는다
function New-WtScheduleNotices($Data) {
    if ($Data.Error) {
        $card = New-WtCard
        $col = New-WtStack Vertical 8
        [void](Add-WtChild $col (New-WtCardHeader '일정 파일을 읽지 못했습니다'))
        [void](Add-WtChild $col (New-WtTag '읽기 전용' 'WarnBg' 'Warn'))
        [void](Add-WtChild $col (New-WtText $Data.Error 'T.Body'))
        [void](Add-WtChild $col (New-WtText '파일은 바꾸지 않았습니다. 데이터 폴더의 schedule.json과 백업(.bak)을 확인하세요.' 'T.Sub'))
        $card.Child = $col
        $card
        return
    }
    foreach ($g in @(
            @('broken', '고칠 항목', '날짜 · 시각을 읽지 못해 목록과 알람에서 뺐습니다. 저장할 때는 그대로 둡니다.'),
            @('readonly', '새 버전에서 만든 항목', '이 버전이 모르는 값이 있어 읽기만 하고, 목록과 알람에서 뺐습니다. 저장할 때는 그대로 둡니다.'))) {
        $rows = @($Data.Entries | Where-Object { $_.State -eq $g[0] })
        if (-not $rows.Count) { continue }
        $card = New-WtCard
        $col = New-WtStack Vertical
        [void](Add-WtChild $col (New-WtCardHeader $g[1] "$($rows.Count)"))
        [void](Add-WtChild $col (New-WtText $g[2] 'T.Sub'))
        foreach ($r in $rows) {
            $name = New-WtText $(if ($r.Title) { $r.Title } elseif ($r.Id) { $r.Id } else { '(이름 없음)' }) 'T.Body'
            $name.Width = 200
            $name.TextTrimming = 'CharacterEllipsis'
            [void](Add-WtChild $col (New-WtListRow @($name, (New-WtText $r.Problem 'T.Sub'))))
        }
        $card.Child = $col
        $card
    }
}

function New-WtScheduleView {
    $script:viewKey = $null
    $page = New-WtPage
    [void](Add-WtChild $page.Panel (New-WtPageHeader '일정' '보기 전용 · 편집과 알람은 2단계에서 옮깁니다'))
    $script:body = New-WtStack Vertical 16
    [void](Add-WtChild $page.Panel $script:body)
    $page.Root
}

function Update-WtScheduleView {
    $data = Get-WtScheduleData
    $key = @($data.Stamp, [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:viewKey -ceq $key) { return }
    $script:body.Children.Clear()
    foreach ($n in @(New-WtScheduleNotices $data)) { [void](Add-WtChild $script:body $n) }
    $card = New-WtCard
    $script:list = New-WtStack Vertical
    $card.Child = $script:list
    [void](Add-WtChild $script:body $card)
    [void](Add-WtChild $script:list (New-WtCardHeader '다가오는 14일'))
    $days = Get-WtScheduleDays $data.Entries ([datetime]::Today) 14
    $any = $false
    for ($i = 0; $i -lt 14; $i++) {
        $day = [datetime]::Today.AddDays($i)
        $label = if ($i -eq 0) { '오늘' } elseif ($i -eq 1) { '내일' } else { Format-WtDate $day "M'/'d (ddd)" }
        foreach ($o in $days[$i]) {
            [void](Add-WtChild $script:list (New-WtScheduleRow $o $label $day))
            $label = ''
            $any = $true
        }
    }
    if (-not $any) { [void](Add-WtChild $script:list (New-WtText '다가오는 일정이 없습니다.' 'T.Sub')) }
    $script:viewKey = $key
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

# 기존 14일 목록만 선택·스크롤한다. 날짜만 받거나 목록 밖이면 탭만 연다.
function Open-WtScheduleArgs($OpenArgs) {
    if (-not $OpenArgs.Id -or -not $script:list) { return }
    $data = Get-WtScheduleData
    $days = Get-WtScheduleDays $data.Entries ([datetime]::Today) 14
    $rowIndex = 1; $chosen = $null
    for ($i = 0; $i -lt 14; $i++) {
        foreach ($occurrence in $days[$i]) {
            $row = $script:list.Children[$rowIndex++]
            $matches = $occurrence.Entry.Id -ceq [string]$OpenArgs.Id -and
                (-not $OpenArgs.Date -or ([datetime]$OpenArgs.Date).Date -eq [datetime]::Today.AddDays($i))
            if ($matches) { $chosen = $row }
        }
    }
    if ($chosen) {
        foreach ($row in @($script:list.Children | Select-Object -Skip 1 | Where-Object { $_ -is [System.Windows.Controls.Border] })) {
            Set-WtTargetRowSelected $row ([object]::ReferenceEquals($row, $chosen))
        }
        $chosen.BringIntoView()
    }
}

Register-WtAddon -Id 'schedule' -Title '일정' -Icon 0xE787 -Group '일과' -Order 20 -WarmUp Full `
    -Badge { $data = Get-WtScheduleData; if ($data.Error) { throw $data.Error }; @(Get-WtScheduleOccurrences $data.Entries ([datetime]::Today) ([datetime]::Today)).Count } `
    -NewView { New-WtScheduleView } `
    -Refresh { param($view) Update-WtScheduleView } `
    -HomeCard { New-WtScheduleHomeCards } -HomeSlot main -HomeOrder 10 -CalendarHost `
    -OnOpen { param($OpenArgs) Open-WtScheduleArgs $OpenArgs } `
    -OnExit { if ($script:homeTimer) { $script:homeTimer.Stop() } } `
    -ImportLegacy { param($folder) Import-WtScheduleLegacy $folder } `
    -Help '달력에서 일정과 반복 일정을 확인합니다.'

Export-ModuleMember -Function Format-WtAlarm, Get-WtRepeatLabel

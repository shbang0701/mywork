# 근태 탭 (1단계: 보기 전용). 기록 · 지금 출근은 2단계에서 옮긴다.
# 저장소 attendance.json (schema 1). 항목:
#   id, type(출근 | 업무외시간 근무 | 출장 | 휴가), startDate, endDate, startTime, endTime, place, detail, updated

$ErrorActionPreference = 'Stop'

$script:schema = 1
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
$script:body = $null
$script:monthLabel = $null

# 종류 → 표시 색 (Theme.psm1의 Att.*)
$script:typeColor = @{ '출근' = 'Att.Work'; '업무외시간 근무' = 'Att.Over'; '출장' = 'Att.Trip'; '휴가' = 'Att.Leave' }

function ConvertTo-AttDate([string]$Text) { [datetime]::ParseExact($Text, 'yyyy-MM-dd', $script:inv) }

function Get-WtAttendanceItems { Get-WtStoreItems -Name 'attendance' -Schema $script:schema }

# 기록이 그 달과 겹치는지
function Test-WtAttInMonth($Item, [datetime]$Month) {
    $first = $Month.Date
    $last = $first.AddMonths(1).AddDays(-1)
    $s = ConvertTo-AttDate $Item.startDate
    $e = if ($Item.endDate) { ConvertTo-AttDate $Item.endDate } else { $s }
    $s -le $last -and $e -ge $first
}

# 업무외시간 근무 분. 끝 시각이 시작보다 이르면 다음 날로 본다.
function Get-WtAttMinutes($Item) {
    if (-not $Item.startTime -or -not $Item.endTime) { return 0 }
    $a = [timespan]::ParseExact($Item.startTime, 'hh\:mm', $script:inv)
    $b = [timespan]::ParseExact($Item.endTime, 'hh\:mm', $script:inv)
    $m = ($b - $a).TotalMinutes
    if ($m -le 0) { $m += 1440 }
    [int]$m
}

# 그 달 요약: 출근 일수, 업무외 시간, 출장 건수, 휴가 일수(반차 0.5)
function Get-WtAttendanceSummary([datetime]$Month, [object[]]$Items) {
    if ($null -eq $Items) { $Items = Get-WtAttendanceItems }
    $first = $Month.Date
    $last = $first.AddMonths(1).AddDays(-1)
    $inMonth = @($Items | Where-Object { Test-WtAttInMonth $_ $first })
    $work = @($inMonth | Where-Object { $_.type -eq '출근' } | ForEach-Object { $_.startDate } | Sort-Object -Unique).Count
    $over = ($inMonth | Where-Object { $_.type -eq '업무외시간 근무' } | ForEach-Object { Get-WtAttMinutes $_ } | Measure-Object -Sum).Sum
    $trip = @($inMonth | Where-Object { $_.type -eq '출장' }).Count
    $leave = 0.0
    foreach ($r in ($inMonth | Where-Object { $_.type -eq '휴가' })) {
        if ($r.detail -like '*반차*') { $leave += 0.5; continue }
        $s = ConvertTo-AttDate $r.startDate
        $e = if ($r.endDate) { ConvertTo-AttDate $r.endDate } else { $s }
        if ($s -lt $first) { $s = $first }
        if ($e -gt $last) { $e = $last }
        $leave += ($e - $s).Days + 1
    }
    [pscustomobject]@{ Work = $work; OverMinutes = [int]$over; Trip = $trip; Leave = $leave }
}

function Format-WtHours([int]$Minutes) {
    $h = [Math]::Round($Minutes / 60, 1)
    if ($h -eq [Math]::Floor($h)) { '{0:0}' -f $h } else { '{0:0.0}' -f $h }
}

# 예전 attendance.csv → attendance.json. 가져온 개수를 돌려준다.
function Import-WtAttendanceLegacy([string]$Folder) {
    $rows = Import-WtLegacyCsv $Folder 'attendance'
    if ($null -eq $rows) { return $null }
    $items = foreach ($r in $rows) {
        [ordered]@{
            id        = [string]$r.Id
            type      = [string]$r.Type
            startDate = [string]$r.StartDate
            endDate   = if ($r.EndDate) { [string]$r.EndDate } else { [string]$r.StartDate }
            startTime = [string]$r.StartTime
            endTime   = [string]$r.EndTime
            place     = [string]$r.Place
            detail    = [string]$r.Detail
            updated   = [string]$r.Updated
        }
    }
    Write-WtStore -Name 'attendance' -Schema $script:schema -Items @($items) -Extra @{ importedFrom = $Folder }
    @($items).Count
}

function New-WtAttTiles($Summary, [int]$Columns) {
    $g = [System.Windows.Controls.Primitives.UniformGrid]::new()
    $g.Columns = $Columns
    foreach ($t in @(
            @('출근', "$($Summary.Work)", '일', 'Att.Work'),
            @('업무외시간', (Format-WtHours $Summary.OverMinutes), '시간', 'Att.Over'),
            @('출장', "$($Summary.Trip)", '건', 'Att.Trip'),
            @('휴가', ('{0:0.#}' -f $Summary.Leave), '일', 'Att.Leave'))) {
        $tile = New-WtStatTile $t[0] $t[1] $t[2] $t[3]
        $tile.Margin = [System.Windows.Thickness]::new(0, 0, 10, 10)
        [void]$g.Children.Add($tile)
    }
    $g
}

function New-WtAttRow($Item) {
    $s = ConvertTo-AttDate $Item.startDate
    $e = if ($Item.endDate) { ConvertTo-AttDate $Item.endDate } else { $s }
    $dateText = if ($e -gt $s) { '{0} ~ {1}' -f (Format-WtDate $s "M'/'d"), (Format-WtDate $e "M'/'d") } else { Format-WtDate $s "M'/'d (ddd)" }
    $date = New-WtText $dateText 'T.Body'
    $date.Width = 110
    $color = $script:typeColor[[string]$Item.type]
    if (-not $color) { $color = 'Chip' }
    $tagBox = [System.Windows.Controls.Border]::new()
    $tagBox.Width = 130
    $tagBox.Child = New-WtTag $Item.type "${color}Bg" $color
    if (-not $script:typeColor[[string]$Item.type]) { $tagBox.Child = New-WtTag $Item.type }
    $time = switch ([string]$Item.type) {
        '출근' { $Item.startTime }
        '업무외시간 근무' { '{0}–{1} ({2}시간)' -f $Item.startTime, $Item.endTime, (Format-WtHours (Get-WtAttMinutes $Item)) }
        '휴가' { if ($Item.detail) { $Item.detail } else { '휴가' } }
        default { if ($e -gt $s) { '{0}일' -f (($e - $s).Days + 1) } else { '하루' } }
    }
    $timeText = New-WtText ([string]$time) 'T.Body'
    $timeText.Width = 170
    $noteParts = @($Item.place, $(if ($Item.type -ne '휴가') { $Item.detail })) | Where-Object { $_ }
    $note = New-WtText ($noteParts -join ' · ') 'T.Sub'
    New-WtListRow @($date, $tagBox, $timeText, $note)
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
    $key = @((Get-WtStoreStamp 'attendance'), $script:month.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:viewKey -ceq $key) { return }
    $items = Get-WtAttendanceItems
    $script:monthLabel.Text = Format-WtDate $script:month 'yyyy년 M월'
    $script:body.Children.Clear()
    [void](Add-WtChild $script:body (New-WtAttTiles (Get-WtAttendanceSummary $script:month $items) 4))
    $card = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader ('{0} 기록' -f (Format-WtDate $script:month 'M월'))))
    $rows = @($items | Where-Object { Test-WtAttInMonth $_ $script:month } |
        Sort-Object -Property @{ Expression = { $_.startDate }; Descending = $true }, @{ Expression = { $_.startTime }; Descending = $true })
    foreach ($r in $rows) { [void](Add-WtChild $col (New-WtAttRow $r)) }
    if (-not $rows.Count) { [void](Add-WtChild $col (New-WtText '이 달에는 기록이 없습니다.' 'T.Sub')) }
    $card.Child = $col
    [void](Add-WtChild $script:body $card)
    $script:viewKey = $key
}

function New-WtAttendanceHomeCard {
    $key = @((Get-WtStoreStamp 'attendance'), [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:homeKey -ceq $key -and $script:homeCard -and -not $script:homeCard.Parent) { return $script:homeCard }
    $items = Get-WtAttendanceItems
    $month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
    $card = New-WtCard
    $col = New-WtStack Vertical 8
    [void](Add-WtChild $col (New-WtCardHeader ('근태 · {0}' -f (Format-WtDate $month 'M월')) '' '근태 열기' 'attendance'))
    $today = [datetime]::Today.ToString('yyyy-MM-dd', $script:inv)
    $in = $items | Where-Object { $_.type -eq '출근' -and $_.startDate -eq $today } | Select-Object -First 1
    $status = if ($in) { New-WtTag "오늘 출근 $($in.startTime)" 'SuccessBg' 'Success' } else { New-WtTag '아직 출근 기록 없음' 'WarnBg' 'Warn' }
    [void](Add-WtChild $col $status)
    [void](Add-WtChild $col (New-WtAttTiles (Get-WtAttendanceSummary $month $items) 2))
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

Export-ModuleMember -Function Get-WtAttendanceItems, Test-WtAttInMonth, Get-WtAttMinutes, Get-WtAttendanceSummary,
    Format-WtHours, Import-WtAttendanceLegacy

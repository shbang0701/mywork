# 일정 탭 (1단계: 보기 전용). 편집 · 알람은 2단계에서 옮긴다.
# 저장소 schedule.json (schema 1). 항목:
#   id, title, startDate, endDate(기간 일정. 하루짜리는 startDate와 같음), time(''=하루 종일), endTime,
#   note, alarm(분 전, $null=없음), repeat(''|daily|weekdays|weekly), tags[], lastAlarm, updated

$ErrorActionPreference = 'Stop'

$script:schema = 1
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:repeatNames = @{ daily = '매일'; weekdays = '평일'; weekly = '매주' }
$script:list = $null

function ConvertTo-SchDate([string]$Text) { [datetime]::ParseExact($Text, 'yyyy-MM-dd', $script:inv) }

function Get-WtScheduleItems { Get-WtStoreItems -Name 'schedule' -Schema $script:schema }

# $Item이 $Day에 있는지 (반복 포함)
function Test-WtScheduleOn($Item, [datetime]$Day) {
    $d = $Day.Date
    $start = ConvertTo-SchDate $Item.startDate
    $end = if ($Item.endDate) { ConvertTo-SchDate $Item.endDate } else { $start }
    if ($d -lt $start) { return $false }
    switch ([string]$Item.repeat) {
        'daily' { return $true }
        'weekdays' { return [int]$d.DayOfWeek -ge 1 -and [int]$d.DayOfWeek -le 5 }
        'weekly' { return $d.DayOfWeek -eq $start.DayOfWeek }
        default { return $d -le $end }
    }
}

# 그날 일정을 시간 순서로 (하루 종일이 먼저)
function Get-WtScheduleOn([datetime]$Day, [object[]]$Items) {
    if ($null -eq $Items) { $Items = Get-WtScheduleItems }
    @($Items | Where-Object { Test-WtScheduleOn $_ $Day } | Sort-Object { if ($_.time) { $_.time } else { '' } }, { $_.title })
}

# 여러 날을 그릴 때 항목의 날짜를 한 번만 읽는다. 반복 판단과 날짜별 정렬은 하루 조회와 같다.
function Get-WtScheduleRange([datetime]$From, [int]$Count, [object[]]$Items) {
    $dates = @(); $buckets = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $dates += $From.Date.AddDays($i)
        $buckets += , [Collections.Generic.List[object]]::new()
    }
    foreach ($item in $Items) {
        $start = [datetime]::ParseExact($item.startDate, 'yyyy-MM-dd', $script:inv)
        $end = if ($item.endDate) { [datetime]::ParseExact($item.endDate, 'yyyy-MM-dd', $script:inv) } else { $start }
        for ($i = 0; $i -lt $Count; $i++) {
            $day = $dates[$i]
            if ($day -lt $start) { continue }
            $on = switch ([string]$item.repeat) {
                'daily' { $true }
                'weekdays' { [int]$day.DayOfWeek -ge 1 -and [int]$day.DayOfWeek -le 5 }
                'weekly' { $day.DayOfWeek -eq $start.DayOfWeek }
                default { $day -le $end }
            }
            if ($on) { $buckets[$i].Add($item) }
        }
    }
    $result = @()
    foreach ($bucket in $buckets) {
        $result += , @($bucket | Sort-Object { if ($_.time) { $_.time } else { '' } }, { $_.title })
    }
    , $result
}

function Format-WtAlarm($Alarm) {
    if ($null -eq $Alarm -or "$Alarm" -eq '') { return $null }
    $m = [int]$Alarm
    if ($m -eq 0) { '정시' } elseif ($m -eq 1440) { '하루 전' } elseif ($m % 60 -eq 0) { "$($m / 60)시간 전" } else { "${m}분 전" }
}

# 예전 schedule.csv → schedule.json. 가져온 개수를 돌려준다.
function Import-WtScheduleLegacy([string]$Folder) {
    $rows = Import-WtLegacyCsv $Folder 'schedule'
    if ($null -eq $rows) { return $null }
    $items = foreach ($r in $rows) {
        [ordered]@{
            id        = [string]$r.Id
            title     = [string]$r.Title
            startDate = [string]$r.Date
            endDate   = [string]$r.Date
            time      = [string]$r.Time
            endTime   = ''
            note      = [string]$r.Note
            alarm     = if ("$($r.Alarm)" -eq '') { $null } else { [int]$r.Alarm }
            repeat    = [string]$r.Repeat
            tags      = @()
            lastAlarm = [string]$r.LastAlarm
            updated   = [string]$r.Updated
        }
    }
    Write-WtStore -Name 'schedule' -Schema $script:schema -Items @($items) -Extra @{ importedFrom = $Folder }
    @($items).Count
}

# 한 줄: 시각 · 제목 · 표시(반복 · 알람)
function New-WtScheduleRow($Item, [string]$DayLabel) {
    $parts = [System.Collections.Generic.List[object]]::new()
    if ($DayLabel) {
        $d = New-WtText $DayLabel 'T.Sub'
        $d.Width = 84
        $parts.Add($d)
    }
    $t = New-WtText $(if ($Item.time) { $Item.time } else { '하루 종일' }) 'T.Strong'
    $t.Width = 72
    $parts.Add($t)
    $tags = New-WtStack Horizontal 6
    $rep = $script:repeatNames[[string]$Item.repeat]
    if ($rep) { [void](Add-WtChild $tags (New-WtTag $rep -Icon 0xE8EE)) }
    $al = Format-WtAlarm $Item.alarm
    if ($al) { [void](Add-WtChild $tags (New-WtTag $al -Icon 0xEA8F)) }
    foreach ($tag in @($Item.tags)) { if ($tag) { [void](Add-WtChild $tags (New-WtTag "#$tag")) } }
    if ($tags.Children.Count) { $parts.Add($tags) }
    $title = New-WtText $Item.title 'T.Body'
    $title.TextTrimming = 'CharacterEllipsis'
    $title.TextWrapping = 'NoWrap'
    $parts.Add($title)
    # 제목이 남는 폭을 채우도록 맨 끝에 둔다 (표시는 제목 앞)
    New-WtListRow $parts.ToArray()
}

function New-WtScheduleView {
    $script:viewKey = $null
    $page = New-WtPage
    [void](Add-WtChild $page.Panel (New-WtPageHeader '일정' '보기 전용 · 편집과 알람은 2단계에서 옮깁니다'))
    $card = New-WtCard
    $script:list = New-WtStack Vertical
    $card.Child = $script:list
    [void](Add-WtChild $page.Panel $card)
    $page.Root
}

function Update-WtScheduleView {
    $key = @((Get-WtStoreStamp 'schedule'), [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:viewKey -ceq $key) { return }
    $items = Get-WtScheduleItems
    $days = Get-WtScheduleRange ([datetime]::Today) 14 $items
    $script:list.Children.Clear()
    [void](Add-WtChild $script:list (New-WtCardHeader '다가오는 14일'))
    $any = $false
    for ($i = 0; $i -lt 14; $i++) {
        $day = [datetime]::Today.AddDays($i)
        $label = if ($i -eq 0) { '오늘' } elseif ($i -eq 1) { '내일' } else { Format-WtDate $day "M'/'d (ddd)" }
        foreach ($it in $days[$i]) {
            [void](Add-WtChild $script:list (New-WtScheduleRow $it $label))
            $label = ''
            $any = $true
        }
    }
    if (-not $any) { [void](Add-WtChild $script:list (New-WtText '다가오는 일정이 없습니다.' 'T.Sub')) }
    $script:viewKey = $key
}

function New-WtScheduleHomeCards {
    $key = @((Get-WtStoreStamp 'schedule'), [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:homeKey -ceq $key -and $script:homeCards -and -not @($script:homeCards | Where-Object Parent).Count) { return $script:homeCards }
    $items = Get-WtScheduleItems
    $days = Get-WtScheduleRange ([datetime]::Today) 8 $items
    $today = @($days[0])

    $c1 = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '오늘 일정' "$($today.Count)" '일정 열기' 'schedule'))
    foreach ($it in $today) { [void](Add-WtChild $col (New-WtScheduleRow $it)) }
    if (-not $today.Count) { [void](Add-WtChild $col (New-WtText '오늘은 일정이 없습니다.' 'T.Sub')) }
    $c1.Child = $col

    $c2 = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '다가오는 7일'))
    $n = 0
    for ($i = 1; $i -le 7; $i++) {
        $day = [datetime]::Today.AddDays($i)
        foreach ($it in $days[$i]) {
            if ($it.repeat -eq 'daily' -or $it.repeat -eq 'weekdays') { continue }   # 매일 반복은 오늘 카드에서만
            [void](Add-WtChild $col (New-WtScheduleRow $it (Format-WtDate $day "M'/'d (ddd)")))
            $n++
        }
    }
    if (-not $n) { [void](Add-WtChild $col (New-WtText '다가오는 일정이 없습니다.' 'T.Sub')) }
    $c2.Child = $col

    $script:homeCards = @($c1, $c2); $script:homeKey = $key
    $script:homeCards
}

Register-WtAddon -Id 'schedule' -Title '일정' -Icon 0xE787 -Order 20 `
    -NewView { New-WtScheduleView } `
    -Refresh { param($view) Update-WtScheduleView } `
    -HomeCard { New-WtScheduleHomeCards } `
    -ImportLegacy { param($folder) Import-WtScheduleLegacy $folder } `
    -Help '일정은 보기만 합니다. 편집과 알람은 2단계에서 옮깁니다.'

Export-ModuleMember -Function Get-WtScheduleItems, Test-WtScheduleOn, Get-WtScheduleOn, Format-WtAlarm, Import-WtScheduleLegacy

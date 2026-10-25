# 일정 데이터 (화면 없음): 형식 검사 · schema 1 → 2 이전 · 예전 CSV 가져오기(합치기) · 반복 펼치기. 화면은 Schedule.psm1.
# 형식과 규칙 전체: docs/plans/schedule-attendance-design.md 「일정 형식」. 공통 틀(날짜 모양 · 지운 표시 · 합치기)은 core\Records.psm1
# 저장소 schedule.json (schema 2). 항목:
#   id       한 번 정하면 바꾸지 않는다. 새로 = 12자리 16진수, 예전 CSV의 id(s1 등)는 그대로
#   kind     "event"(일정). 모르는 값이면 읽기 전용 (2차 후보: task 할 일 · oncall 당번)
#   title · note   글 (비면 "")
#   start    { date, time }. time = null이면 하루 종일
#   end      { date, time } 또는 null. null이면 시작과 같은 날(시각 있는 일정은 그 시각 하나). 끝 날짜는 그날 포함.
#            하루 종일이면 end.time도 null, 시각 있는 일정이면 end.time도 있어야 한다. 밤을 넘기면 끝 날짜가 다음 날이다
#   repeat   null 또는 { freq, interval, days, monthDay, nth, until, count, skip, changes } (RFC 5545 반복 규칙 일부를 칸으로)
#              freq daily · weekly · monthly · yearly / interval 1 이상(2 = 격주 · 두 달마다) / days ["mon" … "sun"] 또는 null
#              monthDay 1~31 · -1(말일), 그 날이 없는 달은 건너뛴다 / nth 1~5 · -1(마지막): 그 달 몇째 days 요일
#              until 그날 포함 · count 회차 수. 둘 다 null이면 끝없음
#              skip [원래 날짜] 빠지는 회차 / changes { "원래 날짜": { start · end · title · note · alarms 중 바뀐 칸 } } 그 회차만 바뀜
#              주는 월요일에 시작한다(격주를 셀 때). 회차 하나는 "<id>@<원래 날짜>"로 가리킨다
#   alarms   [ { before: 분 } ]. 시작 몇 분 전(하루 종일은 그날 0시 기준). before가 없는 알람(더 새 앱의 모양)은 울리지 않는다
#   tags     [ 글 ]
#   rev      사람이 고친 횟수(0부터, 고칠 때마다 +1, core\Records.psm1 Set-WtItemEdited). 다시 가져오기가 「이 앱에서 고쳤는지」를 이것으로 본다
#   created · updated · deleted   앱이 찍는 시각. deleted가 있으면 지운 항목(목록에서 숨김, 90일 뒤 { id, deleted }만 남김)
#   origin   null 또는 { from: "winforms-csv", at, rev, row: 예전 CSV 줄 그대로, via: "schema1" · prev: 올리기 전 항목(1단계 WPF 파일에서 올렸을 때),
#            dupOf: 예전 데이터 안에서 id가 겹쳐 따로 남긴 줄의 원래 id }
#   숫자 범위: before 0~527040 · interval 1~999 · count 1~9999 (밖이면 그 항목만 고칠 항목). 날짜는 1900~2199년
# 저장은 저장소 핸들로만 한다(Get-WtScheduleData의 Store → Save-WtScheduleItems). 읽지 못한 파일 · 읽은 뒤 바뀐 파일에는 쓰지 않는다
# 읽기 규칙: 모르는 칸 · 맨 위 키는 그대로 둔다. 모르는 kind · freq · 요일 코드가 든 항목은 읽기 전용(계산 · 알람에서 뺌),
#   날짜를 못 읽는 항목은 「고칠 항목」. 두 경우 모두 저장할 때 그대로 쓰고, 나머지 항목은 평소대로 쓴다.
# 울린 알람 · 다시 알림 같은 앱 상태는 이 파일에 두지 않는다 (2단계: 따로 상태 파일. 잃어도 데이터는 멀쩡하다)

$ErrorActionPreference = 'Stop'

$script:schema = 2
$script:kinds = @('event')
$script:freqs = @('daily', 'weekly', 'monthly', 'yearly')
$script:dayCodes = @('sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat')   # [DayOfWeek] 순서
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:cache = $null
$script:lastImport = $null
# 숫자 칸의 범위 (형식 계약. 밖이면 그 항목만 고칠 항목). 해석은 core\Records.psm1의 ConvertFrom-WtWhole 하나로 한다
$script:limits = @{ before = @(0, 527040); interval = @(1, 999); count = @(1, 9999) }   # before: 366일(분)까지
<#
예전 schedule.csv의 칸 하나가 정하는 항목 칸 (다시 가져올 때 이 경로만 기존 항목에 옮긴다. 나머지 칸은 건드리지 않는다).
Date는 매주 반복의 요일도 정한다. LastAlarm · Updated는 데이터로 옮기지 않으므로 경로가 없다(origin.row에만 남는다)
#>
$script:csvOwned = @{
    Date = @('start.date', 'repeat.days'); Time = @('start.time'); Title = @('title'); Note = @('note')
    Alarm = @('alarms'); Repeat = @('repeat.freq', 'repeat.interval', 'repeat.days')
}

# ---- 읽기 · 쓰기 ------------------------------------------------------------------------------

# 저장소 핸들 (core\Storage.psm1 Open-WtStore). schema 1 파일이면 2로 올려 읽는다. 읽지 못하면 State = error
function Open-WtScheduleStore {
    Open-WtStore -Name 'schedule' -Schema $script:schema -Migrate { param($doc, $from) Update-WtScheduleSchema $doc $from }
}

<#
항목을 저장한다. 읽은 핸들(Get-WtScheduleData의 Store)과, 그 핸들의 Items를 고친 목록을 넘긴다(모르는 칸 · null · 깨진 항목이 그대로 남게).
읽지 못한 파일 · 읽은 뒤 바뀐 파일에는 쓰지 않고 예외를 올린다(Save-WtStore). 지운 지 오래된 항목은 { id, deleted }만 남긴다.
저장한 뒤에는 Get-WtScheduleData로 다시 받는다
#>
function Save-WtScheduleItems($Store, [object[]]$Items) {
    Save-WtStore -Store $Store -Items @(Compress-WtDeletedItems @($Items))
    $script:cache = $null
}

<#
화면 · 홈 카드가 같이 쓰는 읽은 결과. 파일이 바뀌지 않았으면 다시 읽지 않는다. 못 읽어도 예외를 올리지 않는다(화면이 오류를 보여 준다).
@{ Store = 저장소 핸들(저장할 때 넘긴다); Items = 저장된 그대로(null · 깨진 항목 포함, 저장할 때 이것을 고친다)
   Entries = 항목마다 ConvertFrom-WtScheduleItem (Items와 같은 순서); Error = 못 읽은 이유 | $null }
#>
function Get-WtScheduleData {
    $stamp = Get-WtStoreStamp 'schedule'
    if ($script:cache -and $script:cache.Stamp -ceq $stamp) { return $script:cache }
    $store = Open-WtScheduleStore
    $err = $store.Error
    $items = $store.Items
    $entries = @(foreach ($i in $items) { ConvertFrom-WtScheduleItem $i })
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($e in $entries) {
        if (-not $e.Id) { continue }
        if (-not $seen.Add($e.Id) -and $e.State -ne 'deleted') { $e.State = 'broken'; $e.Problem = "id가 앞 항목과 겹칩니다: '$($e.Id)'" }
    }
    $script:cache = [pscustomobject]@{ Stamp = $stamp; Store = $store; Items = $items; Entries = $entries; Error = $err }
    $script:cache
}

# ---- 항목 하나 읽기 ---------------------------------------------------------------------------

function Test-WtSchObject($Value) { $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [ValueType] -and $Value -isnot [array] }

# 객체의 칸 이름 · 값 쌍. 저장 파일에서 읽은 객체(PSCustomObject)와 앱이 만든 해시 테이블을 같게 다룬다
function Get-WtSchPairs($Object) {
    if ($Object -is [System.Collections.IDictionary]) { foreach ($k in @($Object.Keys)) { [pscustomobject]@{ Name = [string]$k; Value = $Object[$k] } } }
    else { foreach ($p in @($Object.PSObject.Properties)) { [pscustomobject]@{ Name = $p.Name; Value = $p.Value } } }
}

# { date, time } 하나 → @{ Date; Time([timespan] | $null); Problem }
function Read-WtSchPoint($Point, [string]$What) {
    if (-not (Test-WtSchObject $Point)) { return @{ Problem = "${What} 모양이 틀렸습니다" } }
    $d = ConvertFrom-WtDateText ([string]$Point.date)
    if ($null -eq $d) { return @{ Problem = "${What} 날짜를 읽지 못했습니다: '$($Point.date)'" } }
    $t = $null
    if ($null -ne $Point.time) {
        $t = ConvertFrom-WtTimeText ([string]$Point.time)
        if ($null -eq $t) { return @{ Problem = "${What} 시각을 읽지 못했습니다: '$($Point.time)'" } }
    }
    @{ Date = $d; Time = $t; Problem = '' }
}

<#
start · end → 계산용 시간 @{ Start; End; AllDay; LastDay; Problem }
  하루 종일: Start = 첫날 0시, End = 끝날 0시(그날 포함). 시각 있는 일정: 실제 시각(끝이 없으면 End = Start)
  LastDay: 걸친 마지막 날. 시각 있는 일정이 다음 날 0시에 끝나면 그 앞날이다
#>
function Get-WtSchTiming($StartPoint, $EndPoint) {
    $s = Read-WtSchPoint $StartPoint '시작'
    if ($s.Problem) { return @{ Problem = $s.Problem } }
    $allDay = $null -eq $s.Time
    $start = if ($allDay) { $s.Date } else { $s.Date + $s.Time }
    $end = $start
    if ($null -ne $EndPoint) {
        $e = Read-WtSchPoint $EndPoint '끝'
        if ($e.Problem) { return @{ Problem = $e.Problem } }
        if (($null -eq $e.Time) -ne $allDay) { return @{ Problem = '시작과 끝 중 한쪽에만 시각이 있습니다' } }
        $end = if ($allDay) { $e.Date } else { $e.Date + $e.Time }
        if ($end -lt $start) { return @{ Problem = '끝이 시작보다 이릅니다' } }
    }
    $last = if ($allDay) { $end } elseif ($end -gt $start -and $end.TimeOfDay -eq [timespan]::Zero) { $end.AddDays(-1) } else { $end.Date }
    @{ Start = $start; End = $end; AllDay = $allDay; LastDay = $last.Date; Problem = '' }
}

# alarms 목록 → @{ List(int[] 분 전); Problem }. before가 없는 알람은 이 앱이 모르는 모양이라 건너뛴다
function Read-WtSchAlarms($Alarms) {
    $list = [System.Collections.Generic.List[int]]::new()
    foreach ($a in @($Alarms)) {
        if ($null -eq $a) { continue }
        if (-not (Test-WtSchObject $a)) { return @{ List = @(); Problem = "알람 모양이 틀렸습니다: '$a'" } }
        $b = $a.PSObject.Properties['before']
        if (-not $b) { continue }
        $m = ConvertFrom-WtWhole $b.Value $script:limits.before[0] $script:limits.before[1]
        if ($null -eq $m) { return @{ List = @(); Problem = "알람을 읽지 못했습니다(0~$($script:limits.before[1])분 정수): '$($b.Value)'" } }
        $list.Add([int]$m)
    }
    @{ List = $list.ToArray(); Problem = '' }
}

# repeat 객체 → @{ Rule; State(ok · readonly · broken); Problem }. changes는 시간을 알아야 해서 ConvertFrom-WtScheduleItem이 읽는다
function Read-WtSchRepeat($Repeat) {
    if (-not (Test-WtSchObject $Repeat)) { return @{ State = 'broken'; Problem = '반복 규칙 모양이 틀렸습니다' } }
    $freq = [string]$Repeat.freq
    if ($script:freqs -cnotcontains $freq) { return @{ State = 'readonly'; Problem = "새 버전의 반복입니다: '$freq'" } }
    $rule = @{ Freq = $freq; Interval = 1; Days = [System.Collections.Generic.List[System.DayOfWeek]]::new(); MonthDay = $null; Nth = $null
        Until = $null; Count = $null; Skip = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); Changes = @{}; RawChanges = $null }
    $raw = Get-WtField $Repeat 'interval'
    if ($null -ne $raw) {
        $v = ConvertFrom-WtWhole $raw $script:limits.interval[0] $script:limits.interval[1]
        if ($null -eq $v) { return @{ State = 'broken'; Problem = "반복 간격을 읽지 못했습니다(1~$($script:limits.interval[1]) 정수): '$raw'" } }
        $rule.Interval = [int]$v
    }
    if ($null -ne $Repeat.days) {
        foreach ($c in @($Repeat.days)) {
            $i = [Array]::IndexOf($script:dayCodes, [string]$c)
            if ($i -lt 0) { return @{ State = 'readonly'; Problem = "새 버전의 요일 표시입니다: '$c'" } }
            if (-not $rule.Days.Contains([System.DayOfWeek]$i)) { $rule.Days.Add([System.DayOfWeek]$i) }
        }
    }
    $raw = Get-WtField $Repeat 'monthDay'
    if ($null -ne $raw) {
        $v = ConvertFrom-WtWhole $raw -1 31
        if ($freq -ne 'monthly' -or $null -eq $v -or $v -eq 0) { return @{ State = 'broken'; Problem = "날짜 반복(monthDay)을 읽지 못했습니다: '$raw'" } }
        $rule.MonthDay = [int]$v
    }
    $raw = Get-WtField $Repeat 'nth'
    if ($null -ne $raw) {
        $v = ConvertFrom-WtWhole $raw -1 5
        if ($freq -ne 'monthly' -or $null -eq $v -or $v -eq 0 -or -not $rule.Days.Count -or $null -ne $rule.MonthDay) {
            return @{ State = 'broken'; Problem = "몇째 요일 반복(nth)을 읽지 못했습니다: '$raw'" }
        }
        $rule.Nth = [int]$v
    }
    if ($null -ne $Repeat.until) {
        $rule.Until = ConvertFrom-WtDateText ([string]$Repeat.until)
        if ($null -eq $rule.Until) { return @{ State = 'broken'; Problem = "반복 끝나는 날을 읽지 못했습니다: '$($Repeat.until)'" } }
    }
    # count는 칸이 없으면 PowerShell이 붙인 Count(1)가 나오므로 Get-WtField로 읽는다
    $count = Get-WtField $Repeat 'count'
    if ($null -ne $count) {
        $v = ConvertFrom-WtWhole $count $script:limits.count[0] $script:limits.count[1]
        if ($null -eq $v) { return @{ State = 'broken'; Problem = "반복 횟수를 읽지 못했습니다(1~$($script:limits.count[1]) 정수): '$count'" } }
        if ($null -ne $rule.Until) { return @{ State = 'broken'; Problem = '반복 끝나는 날과 횟수가 둘 다 있습니다' } }
        $rule.Count = [int]$v
    }
    foreach ($k in @($Repeat.skip)) {
        if ($null -eq $k) { continue }
        if ($null -eq (ConvertFrom-WtDateText ([string]$k))) { return @{ State = 'broken'; Problem = "건너뛸 회차 날짜를 읽지 못했습니다: '$k'" } }
        [void]$rule.Skip.Add([string]$k)
    }
    if ($null -ne $Repeat.changes) {
        if (-not (Test-WtSchObject $Repeat.changes)) { return @{ State = 'broken'; Problem = '회차 바꿈(changes) 모양이 틀렸습니다' } }
        $rule.RawChanges = $Repeat.changes
    }
    @{ Rule = $rule; State = 'ok'; Problem = '' }
}

# 회차 하나의 바뀐 칸 → @{ Timing | $null; Title | $null; Note | $null; Alarms | $null; Problem }. 시작만 바꾸면 길이는 그대로 둔다
function Read-WtSchChange($Entry, [string]$Key, $Change) {
    if (-not (Test-WtSchObject $Change)) { return @{ Problem = "회차 $Key 바꿈 모양이 틀렸습니다" } }
    $c = @{ Timing = $null; Title = $null; Note = $null; Alarms = $null; Problem = '' }
    $ps = @{}
    foreach ($p in (Get-WtSchPairs $Change)) { $ps[$p.Name] = $p }
    if ($ps['start'] -or $ps['end']) {
        $sp = if ($ps['start']) { $ps['start'].Value } else { @{ date = $Key; time = $Entry.Item.start.time } }
        if ($ps['end']) { $ep = $ps['end'].Value }
        else {
            $st = Get-WtSchTiming $sp $null
            if ($st.Problem) { return @{ Problem = "회차 $Key 바꿈: $($st.Problem)" } }
            $ep = $null
            if ($st.AllDay -and $Entry.AllDay -and $Entry.LastDay -gt $Entry.Start.Date) {
                $ep = @{ date = ConvertTo-WtDateText ($st.Start.AddDays(($Entry.LastDay - $Entry.Start.Date).Days)); time = $null }
            } elseif (-not $st.AllDay -and -not $Entry.AllDay -and $Entry.End -gt $Entry.Start) {
                $ne = $st.Start + ($Entry.End - $Entry.Start)
                $ep = @{ date = ConvertTo-WtDateText $ne; time = $ne.ToString('HH:mm', $script:inv) }
            }
        }
        $t = Get-WtSchTiming $sp $ep
        if ($t.Problem) { return @{ Problem = "회차 $Key 바꿈: $($t.Problem)" } }
        $c.Timing = $t
    }
    if ($ps['title']) { $c.Title = [string]$ps['title'].Value }
    if ($ps['note']) { $c.Note = [string]$ps['note'].Value }
    if ($ps['alarms']) {
        $al = Read-WtSchAlarms $ps['alarms'].Value
        if ($al.Problem) { return @{ Problem = "회차 $Key 바꿈: $($al.Problem)" } }
        $c.Alarms = $al.List
    }
    $c
}

<#
저장된 항목 하나 → 화면 · 계산용 값. 저장 파일은 바꾸지 않는다(Item에 원래 객체가 그대로 있다).
State: ok(계산 · 알람에 씀) · readonly(새 버전의 값이 있어 읽기만) · broken(고칠 항목) · deleted(지운 항목)
나머지: Id · Kind · Title · Note · Start · End · AllDay · LastDay · Repeat(규칙 | $null) · Alarms(int[]) · Tags · Problem(이유)
#>
function ConvertFrom-WtScheduleItem($Item) {
    $e = [ordered]@{ Id = ''; Item = $Item; State = 'ok'; Problem = ''; Kind = ''; Title = ''; Note = ''
        Start = $null; End = $null; AllDay = $true; LastDay = $null; Repeat = $null; Alarms = @(); Tags = @() }
    if (Test-WtDeleted $Item) { $e.Id = [string]$Item.id; $e.State = 'deleted'; return [pscustomobject]$e }
    if (-not (Test-WtSchObject $Item)) { $e.State = 'broken'; $e.Problem = '항목 모양이 틀렸습니다'; return [pscustomobject]$e }
    $e.Id = [string]$Item.id; $e.Kind = [string]$Item.kind; $e.Title = [string]$Item.title; $e.Note = [string]$Item.note
    $e.Tags = @(foreach ($t in @($Item.tags)) { if ($null -ne $t -and "$t" -ne '') { [string]$t } })
    $problem = ''
    $timing = Get-WtSchTiming $Item.start $Item.end
    if ($timing.Problem) { $problem = $timing.Problem }
    else { $e.Start = $timing.Start; $e.End = $timing.End; $e.AllDay = $timing.AllDay; $e.LastDay = $timing.LastDay }
    # 새 버전의 값(모르는 종류 · 반복)은 고칠 항목이 아니다. 더 새 앱에서는 맞는 값이라 읽기 전용으로만 둔다
    if ($script:kinds -cnotcontains $e.Kind) { $e.State = 'readonly'; $e.Problem = "새 버전의 일정 종류입니다: '$($e.Kind)'"; return [pscustomobject]$e }
    if ($null -ne $Item.repeat) {
        $r = Read-WtSchRepeat $Item.repeat
        if ($r.State -eq 'readonly') { $e.State = 'readonly'; $e.Problem = $r.Problem; return [pscustomobject]$e }
        if ($r.State -eq 'broken' -and -not $problem) { $problem = $r.Problem }
        if ($r.State -eq 'ok') { $e.Repeat = $r.Rule }
    }
    if (-not $e.Id -and -not $problem) { $problem = 'id가 없습니다' }
    $common = Get-WtRecordProblem $Item
    if ($common -and -not $problem) { $problem = $common }
    $al = Read-WtSchAlarms $Item.alarms
    if ($al.Problem -and -not $problem) { $problem = $al.Problem }
    $e.Alarms = $al.List
    if (-not $problem -and $e.Repeat -and $e.Repeat.RawChanges) {
        $entryView = [pscustomobject]$e
        foreach ($p in @(Get-WtSchPairs $e.Repeat.RawChanges)) {
            if ($null -eq (ConvertFrom-WtDateText $p.Name)) { $problem = "바꾼 회차 날짜를 읽지 못했습니다: '$($p.Name)'"; break }
            $c = Read-WtSchChange $entryView $p.Name $p.Value
            if ($c.Problem) { $problem = $c.Problem; break }
            $e.Repeat.Changes[$p.Name] = $c
        }
    }
    if ($problem) { $e.State = 'broken'; $e.Problem = $problem }
    [pscustomobject]$e
}

# ---- 반복 펼치기 ------------------------------------------------------------------------------

# 한 달 안의 반복 날짜들(오름차순). $First = 그 달 1일. 그 날이 없는 달은 비어 있다
function Get-WtSchMonthDates($Rule, [datetime]$First, [datetime]$Start) {
    $dim = [datetime]::DaysInMonth($First.Year, $First.Month)
    $list = [System.Collections.Generic.List[datetime]]::new()
    if ($null -ne $Rule.MonthDay) {
        $day = if ($Rule.MonthDay -eq -1) { $dim } else { $Rule.MonthDay }
        if ($day -le $dim) { $list.Add($First.AddDays($day - 1)) }
    } elseif ($null -ne $Rule.Nth) {
        foreach ($dow in $Rule.Days) {
            if ($Rule.Nth -eq -1) {
                $last = $First.AddDays($dim - 1)
                $list.Add($last.AddDays(-(([int]$last.DayOfWeek - [int]$dow + 7) % 7)))
            } else {
                $d = $First.AddDays(([int]$dow - [int]$First.DayOfWeek + 7) % 7 + 7 * ($Rule.Nth - 1))
                if ($d.Month -eq $First.Month) { $list.Add($d) }
            }
        }
    } elseif ($Rule.Days.Count) {
        for ($i = 0; $i -lt $dim; $i++) { $d = $First.AddDays($i); if ($Rule.Days.Contains($d.DayOfWeek)) { $list.Add($d) } }
    } elseif ($Start.Day -le $dim) {
        $list.Add($First.AddDays($Start.Day - 1))
    }
    $list.Sort()
    , $list
}

<#
반복의 원래 날짜들: $Start(첫 회차 날짜)부터 규칙대로 센 날짜 중 $From ~ $To(그날 포함) 안의 것, 오름차순.
until은 그날 포함, count는 회차 수(건너뛴 회차도 센다. RFC 5545와 같다). 없는 날(31일 · 2월 29일)은 회차가 아니고 세지도 않는다.
skip(건너뛰기)은 여기서 빼지 않는다(Get-WtScheduleOccurrences가 뺀다)
#>
function Get-WtRepeatDates($Rule, [datetime]$Start, [datetime]$From, [datetime]$To) {
    $s = $Start.Date
    $lo = $From.Date
    $limit = $To.Date
    if ($null -ne $Rule.Until -and $Rule.Until -lt $limit) { $limit = $Rule.Until }
    $out = [System.Collections.Generic.List[datetime]]::new()
    if ($limit -lt $s -or $limit -lt $lo) { return , $out }
    $count = $Rule.Count
    $step = [int]$Rule.Interval
    $n = 0
    switch ($Rule.Freq) {
        'daily' {
            $k = 0
            if ($null -eq $count -and $lo -gt $s) { $k = [int][Math]::Floor(($lo - $s).Days / $step) }
            while ($true) {
                $d = $s.AddDays($k * $step)
                if ($d -gt $limit -or ($null -ne $count -and $k -ge $count)) { break }
                if ($d -ge $lo) { $out.Add($d) }
                $k++
            }
        }
        'weekly' {
            $days = if ($Rule.Days.Count) { @($Rule.Days) } else { @($s.DayOfWeek) }
            $offsets = @($days | ForEach-Object { ([int]$_ + 6) % 7 } | Sort-Object -Unique)
            $week0 = $s.AddDays(-(([int]$s.DayOfWeek + 6) % 7))
            $w = 0
            if ($null -eq $count -and $lo -gt $week0) { $w = [int]([Math]::Floor((($lo - $week0).Days / 7) / $step) * $step) }
            $stop = $false
            while (-not $stop) {
                $ws = $week0.AddDays(7 * $w)
                if ($ws -gt $limit) { break }
                foreach ($o in $offsets) {
                    $d = $ws.AddDays($o)
                    if ($d -lt $s) { continue }
                    if ($d -gt $limit) { $stop = $true; break }
                    $n++
                    if ($null -ne $count -and $n -gt $count) { $stop = $true; break }
                    if ($d -ge $lo) { $out.Add($d) }
                }
                $w += $step
            }
        }
        'monthly' {
            $base = [datetime]::new($s.Year, $s.Month, 1)
            $m = 0
            if ($null -eq $count) {
                $gap = ($lo.Year - $s.Year) * 12 + $lo.Month - $s.Month
                if ($gap -gt 0) { $m = [int]([Math]::Floor($gap / $step) * $step) }
            }
            $stop = $false
            while (-not $stop) {
                $first = $base.AddMonths($m)
                if ($first -gt $limit) { break }
                foreach ($d in (Get-WtSchMonthDates $Rule $first $s)) {
                    if ($d -lt $s) { continue }
                    if ($d -gt $limit) { $stop = $true; break }
                    $n++
                    if ($null -ne $count -and $n -gt $count) { $stop = $true; break }
                    if ($d -ge $lo) { $out.Add($d) }
                }
                $m += $step
            }
        }
        'yearly' {
            $y = 0
            if ($null -eq $count -and $lo.Year -gt $s.Year) { $y = [int]([Math]::Floor(($lo.Year - $s.Year) / $step) * $step) }
            while ($s.Year + $y -le $limit.Year) {
                $year = $s.Year + $y
                $y += $step
                if ($s.Month -eq 2 -and $s.Day -eq 29 -and -not [datetime]::IsLeapYear($year)) { continue }
                $d = [datetime]::new($year, $s.Month, $s.Day)
                if ($d -gt $limit) { break }
                $n++
                if ($null -ne $count -and $n -gt $count) { break }
                if ($d -ge $lo) { $out.Add($d) }
            }
        }
    }
    , $out
}

# 회차 하나. 바뀐 회차면 바뀐 칸을 쓴다
function New-WtSchOccurrence($Entry, [datetime]$Original, $Change) {
    $shift = $Original.Date - $Entry.Start.Date
    $o = [ordered]@{ Key = "$($Entry.Id)@$(ConvertTo-WtDateText $Original)"; Entry = $Entry; Original = $Original.Date
        Start = $Entry.Start + $shift; End = $Entry.End + $shift; LastDay = $Entry.LastDay + $shift; AllDay = $Entry.AllDay
        Title = $Entry.Title; Note = $Entry.Note; Alarms = $Entry.Alarms; Changed = $false }
    if ($Change) {
        $o.Changed = $true
        if ($Change.Timing) { $o.Start = $Change.Timing.Start; $o.End = $Change.Timing.End; $o.LastDay = $Change.Timing.LastDay; $o.AllDay = $Change.Timing.AllDay }
        if ($null -ne $Change.Title) { $o.Title = $Change.Title }
        if ($null -ne $Change.Note) { $o.Note = $Change.Note }
        if ($null -ne $Change.Alarms) { $o.Alarms = $Change.Alarms }
    }
    [pscustomobject]$o
}

<#
$From ~ $To(날짜, 그날 포함)와 겹치는 회차들. 계산할 수 있는 항목(State ok)만 쓴다. 시작 순서(같으면 하루 종일 먼저, 그다음 제목)
회차: Key("<id>@<원래 날짜>") · Entry · Original(원래 날짜) · Start · End · LastDay · AllDay · Title · Note · Alarms · Changed
여러 날에 걸친 회차는 시작이 범위 앞이어도 범위에 걸치면 들어간다. 다른 날로 옮긴 회차(changes)는 옮긴 날로 들어간다
#>
function Get-WtScheduleOccurrences([object[]]$Entries, [datetime]$From, [datetime]$To) {
    $lo = $From.Date
    $hi = $To.Date
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($Entries)) {
        if ($null -eq $e -or $e.State -ne 'ok') { continue }
        if (-not $e.Repeat) {
            if ($e.Start.Date -le $hi -and $e.LastDay -ge $lo) { $list.Add((New-WtSchOccurrence $e $e.Start.Date $null)) }
            continue
        }
        $rule = $e.Repeat
        $span = ($e.LastDay - $e.Start.Date).Days
        $done = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($d in (Get-WtRepeatDates $rule $e.Start $lo.AddDays(-$span) $hi)) {
            $key = ConvertTo-WtDateText $d
            [void]$done.Add($key)
            if ($rule.Skip.Contains($key)) { continue }
            $o = New-WtSchOccurrence $e $d $rule.Changes[$key]
            if ($o.Start.Date -le $hi -and $o.LastDay -ge $lo) { $list.Add($o) }
        }
        # 범위 밖의 회차를 이 범위 안으로 옮긴 경우. 반복에 없는 날짜의 바꿈은 쓰지 않는다
        foreach ($key in @($rule.Changes.Keys)) {
            if ($done.Contains($key) -or $rule.Skip.Contains($key)) { continue }
            $c = $rule.Changes[$key]
            if (-not $c.Timing -or $c.Timing.Start.Date -gt $hi -or $c.Timing.LastDay -lt $lo) { continue }
            $d = ConvertFrom-WtDateText $key
            if (-not (Get-WtRepeatDates $rule $e.Start $d $d).Count) { continue }
            $list.Add((New-WtSchOccurrence $e $d $c))
        }
    }
    @($list | Sort-Object -Culture 'ko-KR' -Property @{ Expression = { $_.Start } }, @{ Expression = { -not $_.AllDay } }, @{ Expression = { $_.Title } }, @{ Expression = { $_.Key } })
}

<#
$From부터 $Count일 동안 날마다의 회차 목록(목록의 목록). 여러 날에 걸친 회차는 걸친 날마다 들어간다.
하루 안에서는 하루 종일 · 앞날부터 이어진 것 → 시각 → 제목 순서
#>
function Get-WtScheduleDays([object[]]$Entries, [datetime]$From, [int]$Count) {
    $lo = $From.Date
    $buckets = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++) { $buckets.Add([System.Collections.Generic.List[object]]::new()) }
    foreach ($o in (Get-WtScheduleOccurrences $Entries $lo $lo.AddDays($Count - 1))) {
        $a = [Math]::Max(0, ($o.Start.Date - $lo).Days)
        $b = [Math]::Min($Count - 1, ($o.LastDay - $lo).Days)
        for ($i = $a; $i -le $b; $i++) { $buckets[$i].Add($o) }
    }
    $result = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        $day = $lo.AddDays($i)
        $result.Add(@($buckets[$i] | Sort-Object -Culture 'ko-KR' -Property @{ Expression = { -not $_.AllDay -and $_.Start.Date -ge $day } },
                @{ Expression = { if ($_.Start.Date -lt $day) { [timespan]::Zero } else { $_.Start.TimeOfDay } } }, @{ Expression = { $_.Title } }, @{ Expression = { $_.Key } }))
    }
    , $result.ToArray()
}

# ---- 예전 데이터 ------------------------------------------------------------------------------

function New-WtSchRule([string]$Freq, [string[]]$Days) {
    $d = $null
    if ($Days -and $Days.Count) { $d = [string[]]$Days }
    [ordered]@{ freq = $Freq; interval = 1; days = $d; monthDay = $null; nth = $null; until = $null; count = $null; skip = @(); changes = [ordered]@{} }
}

<#
예전 WinForms schedule.csv 줄 하나 → schema 2 항목. 못 읽는 날짜 · 시각은 원래 글을 그 칸에 두어 「고칠 항목」이 되게 하고, 줄 전체는 origin.row에 남긴다.
  Repeat: daily → 매일, weekdays → 매주 월~금, weekly → 매주(시작일 요일). 모르는 글은 { freq: 그 글 } (읽기 전용)
  Alarm: '' → 없음, 숫자 → [{ before }]. LastAlarm(울린 알람)은 데이터로 옮기지 않는다(origin.row에만 남음)
  id가 빈 줄은 줄 내용으로 정한 id(csv-…)를 붙인다. 같은 줄은 다시 가져와도 같은 id다
#>
function ConvertFrom-WtScheduleRow($Row, [string]$At) {
    $id = ([string]$Row.Id).Trim()
    if (-not $id) {
        $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes((Get-WtRowKey $Row)))
        $id = 'csv-' + [Convert]::ToHexString($hash).Substring(0, 12).ToLowerInvariant()
    }
    $rawDate = ([string]$Row.Date).Trim()
    $date = ConvertFrom-WtLegacyDate $rawDate
    $rawTime = ([string]$Row.Time).Trim()
    $time = $null
    if ($rawTime) { $time = ConvertFrom-WtLegacyTime $rawTime; if (-not $time) { $time = $rawTime } }
    $alarms = [System.Collections.Generic.List[object]]::new()
    $alarm = ([string]$Row.Alarm).Trim()
    if ($alarm -match '^\d{1,6}$') { $alarms.Add([ordered]@{ before = [int]$alarm }) }
    elseif ($alarm) { $alarms.Add([ordered]@{ before = $alarm }) }
    $repeatText = ([string]$Row.Repeat).Trim()
    $repeat = $null
    switch -CaseSensitive ($repeatText) {
        '' { break }
        'daily' { $repeat = New-WtSchRule 'daily' $null; break }
        'weekdays' { $repeat = New-WtSchRule 'weekly' @('mon', 'tue', 'wed', 'thu', 'fri'); break }
        'weekly' {
            $day = if ($date) { $script:dayCodes[[int](ConvertFrom-WtDateText $date).DayOfWeek] } else { '' }
            $repeat = New-WtSchRule 'weekly' ([string[]]@($day | Where-Object { $_ })); break
        }
        default { $repeat = [ordered]@{ freq = $repeatText } }
    }
    [pscustomobject][ordered]@{
        id = $id; kind = 'event'; title = [string]$Row.Title; note = [string]$Row.Note
        start = [ordered]@{ date = $(if ($date) { $date } else { $rawDate }); time = $time }
        end = $null; repeat = $repeat; alarms = $alarms.ToArray(); tags = @(); rev = 0
        created = $null; updated = $At; deleted = $null
        origin = [ordered]@{ from = 'winforms-csv'; at = $At; rev = 0; row = $Row }
    }
}

# 예전 값 하나: 비면 $null, 읽으면 정한 모양, 못 읽으면 원래 글 그대로 (그러면 그 항목은 「고칠 항목」이 되고 원문이 남는다)
function ConvertFrom-WtSchLegacyValue([string]$Text, [ValidateSet('date', 'time')][string]$What) {
    $raw = $Text.Trim()
    if (-not $raw) { return $null }
    $v = if ($What -eq 'date') { ConvertFrom-WtLegacyDate $raw } else { ConvertFrom-WtLegacyTime $raw }
    if ($v) { $v } else { $raw }
}

<#
schema 1(1단계 WPF) → 2. 1단계 WPF는 예전 CSV를 칸 이름만 바꿔 옮긴 것이라, 예전 CSV 줄로 되돌린 뒤 같은 길(ConvertFrom-WtScheduleRow)로 바꾼다.
그래서 이전한 뒤 예전 CSV를 다시 가져와도 같은 줄은 「그대로」로 합쳐진다.
1단계에만 있던 칸(기간 · 끝 시각 · 태그)은 옮기고, 못 읽는 끝 날짜 · 시각은 원래 글 그대로 두어 「고칠 항목」으로 남긴다.
옮기기 전 항목 전체(1단계에만 있던 칸 포함)는 origin.prev에 그대로 남긴다. 모르는 칸도 항목에 옮긴다. null · 모양이 틀린 항목도 같은 자리에 둔다
#>
function Update-WtScheduleSchema($Doc, [int]$From) {
    if ($From -ne 1) { throw "일정 schema $From에서 올리는 방법이 없습니다." }
    $at = Get-WtStamp
    $known = @('id', 'title', 'startDate', 'endDate', 'time', 'endTime', 'note', 'alarm', 'repeat', 'tags', 'lastAlarm', 'updated')
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($old in @($Doc.items)) {
        if (-not (Test-WtSchObject $old)) { $list.Add($old); continue }
        $row = [pscustomobject][ordered]@{
            Id = [string]$old.id; Date = [string]$old.startDate; Time = [string]$old.time; Title = [string]$old.title; Note = [string]$old.note
            Alarm = $(if ($null -eq $old.alarm) { '' } else { [string]$old.alarm }); Repeat = [string]$old.repeat
            LastAlarm = [string]$old.lastAlarm; Updated = [string]$old.updated
        }
        $new = ConvertFrom-WtScheduleRow $row $at
        $new.origin['via'] = 'schema1'
        $new.origin['prev'] = Copy-WtItem $old
        $endDate = ConvertFrom-WtSchLegacyValue ([string]$old.endDate) 'date'
        $endTime = ConvertFrom-WtSchLegacyValue ([string]$old.endTime) 'time'
        if (($null -ne $endDate -and $endDate -ne $new.start.date) -or $null -ne $endTime) {
            $new.end = [ordered]@{ date = $(if ($null -ne $endDate) { $endDate } else { $new.start.date }); time = $endTime }
        }
        $tags = @(foreach ($t in @($old.tags)) { if ($null -ne $t -and "$t" -ne '') { [string]$t } })
        if ($tags.Count) { $new.tags = $tags }
        foreach ($p in @($old.PSObject.Properties)) {
            if ($known -notcontains $p.Name -and -not $new.PSObject.Properties[$p.Name]) { Set-WtField $new $p.Name $p.Value }
        }
        $list.Add($new)
    }
    Set-WtField $Doc 'items' $list.ToArray()
    $Doc
}

<#
예전 WinForms schedule.csv를 가져온다. 덮어쓰지 않고 합친다(core\Records.psm1 Merge-WtLegacyItems, 예전 칸 → 항목 칸 지도 $script:csvOwned):
새 줄은 더하고, 이 앱에서 고치거나(rev) 지운 항목은 그대로 두며, 예전 앱에서만 바뀐 줄은 바뀐 칸이 정하는 경로만 기존 항목에 옮긴다.
가져온 개수(더함 + 바꿈)를 돌려준다. 지금 파일을 읽지 못하면(더 새 버전 · 깨짐) 가져오지 않고 예외를 올린다 — 못 읽은 파일을 덮어쓰지 않게
#>
function Import-WtScheduleLegacy([string]$Folder) {
    $csv = Read-WtLegacyCsv $Folder 'schedule'
    if ($null -eq $csv) { return $null }
    $store = Open-WtScheduleStore
    if ($store.State -eq 'error') { throw $store.Error }
    $at = Get-WtStamp
    $incoming = @(Copy-WtItem @(foreach ($r in $csv.Rows) { ConvertFrom-WtScheduleRow $r $at }))
    $m = Merge-WtLegacyItems -Items $store.Items -Incoming $incoming -Owned $script:csvOwned
    $legacy = [ordered]@{ file = $csv.File; sha256 = $csv.Sha256; encoding = $csv.Encoding; rows = $csv.Rows.Count; at = $at }
    Save-WtStore -Store $store -Items @(Compress-WtDeletedItems @($m.Items)) -Extra @{ importedFrom = $Folder; legacy = $legacy }
    $script:cache = $null
    $script:lastImport = $m
    $m.Added + $m.Updated
}

# 마지막 가져오기의 합친 결과 (Added · Updated · Unchanged · KeptDeleted · Conflicts · Missing · Duplicates)
function Get-WtScheduleLastImport { $script:lastImport }

Export-ModuleMember -Function Open-WtScheduleStore, Save-WtScheduleItems, Get-WtScheduleData, ConvertFrom-WtScheduleItem,
    Get-WtRepeatDates, Get-WtScheduleOccurrences, Get-WtScheduleDays, ConvertFrom-WtScheduleRow, Update-WtScheduleSchema,
    Import-WtScheduleLegacy, Get-WtScheduleLastImport
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
#   alarms   [ { before: 분 } ]. 시작 몇 분 전(하루 종일은 그날 0시 기준). before가 null이면 꺼진 알람, before가 없는 알람(더 새 앱의 모양)은 울리지 않는다
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
Date는 매주 반복의 요일도 정한다. LastAlarm · Updated는 데이터로 옮기지 않으므로 경로가 없다(origin.row에만 남는다).
목록 칸의 소유: alarms는 첫 원소의 before만(예전 앱은 알람이 하나뿐이다. 다른 원소 · 첫 원소의 다른 칸은 이 앱 · 더 새 앱의 것),
  예전 앱에서 알람을 끄면 첫 원소의 before가 null(꺼진 알람)이 된다. repeat.days는 요일 글 목록이라 통째로 소유한다.
  tags · repeat.skip은 CSV가 소유하지 않는다
#>
$script:csvOwned = @{
    Date = @('start.date', 'repeat.days'); Time = @('start.time'); Title = @('title'); Note = @('note')
    Alarm = @('alarms[0].before'); Repeat = @('repeat.freq', 'repeat.interval', 'repeat.days')
}

# ---- 읽기 · 쓰기 ------------------------------------------------------------------------------

# 저장소 핸들 (core\Storage.psm1 Open-WtStore). schema 1 파일이면 2로 올려 읽는다. 읽지 못하면 State = error
function Open-WtScheduleStore {
    Open-WtStore -Name 'schedule' -Schema $script:schema -Migrate { param($doc, $from) Update-WtScheduleSchema $doc $from }
}

<#
항목을 저장한다. 읽은 핸들(Get-WtScheduleData의 Store)과, 그 핸들의 Items를 고친 목록을 넘긴다(모르는 칸 · null · 깨진 항목이 그대로 남게).
읽지 못한 파일 · 그 핸들로 읽은 뒤 바뀐 파일(같은 핸들로 누가 먼저 저장한 경우 포함)에는 쓰지 않고 예외를 올린다(Save-WtStore, 낙관적 잠금).
캐시의 항목 객체는 화면 · 홈 카드가 같이 보므로 고칠 항목은 Copy-WtItem으로 복사해서 고친다. 지운 지 오래된 항목은 { id, deleted }만 남긴다.
저장한 뒤에는 Get-WtScheduleData로 다시 받는다(이 핸들은 더 쓸 수 없다)
#>
function Save-WtScheduleItems($Store, [object[]]$Items) {
    [void](Save-WtStore -Store $Store -Items @(Compress-WtDeletedItems @($Items)))
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
    if ($null -eq $Object) { return }
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

# alarms 목록 → @{ List(int[] 분 전); Problem }. before가 없는 알람은 이 앱이 모르는 모양이라 건너뛰고, before가 null이면 꺼진 알람이라 건너뛴다
function Read-WtSchAlarms($Alarms) {
    $list = [System.Collections.Generic.List[int]]::new()
    foreach ($a in @($Alarms)) {
        if ($null -eq $a) { continue }
        if (-not (Test-WtSchObject $a)) { return @{ List = @(); Problem = "알람 모양이 틀렸습니다: '$a'" } }
        $b = Get-WtField $a 'before'
        if ($null -eq $b) { continue }
        $m = ConvertFrom-WtWhole $b $script:limits.before[0] $script:limits.before[1]
        if ($null -eq $m) { return @{ List = @(); Problem = "알람을 읽지 못했습니다(0~$($script:limits.before[1])분 정수): '$b'" } }
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
            $original = ConvertFrom-WtDateText $p.Name
            if ($e.Repeat.Skip.Contains($p.Name) -or -not (Get-WtRepeatDates $e.Repeat $e.Start $original $original).Count) { continue }
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
    [void](Save-WtStore -Store $store -Items @(Compress-WtDeletedItems @($m.Items)) -Extra @{ importedFrom = $Folder; legacy = $legacy })
    $script:cache = $null
    $script:lastImport = $m
    $m.Added + $m.Updated
}

# 마지막 가져오기의 합친 결과 (Added · Updated · Unchanged · KeptDeleted · Conflicts · Missing · Duplicates)
function Get-WtScheduleLastImport { $script:lastImport }

# ---- 편집 (화면 없음) -------------------------------------------------------------------------

# 알람의 아는 칸을 고칠 때 소리 등 모르는 칸은 남긴다. 줄을 줄이면 남은 before만 끈다.
function Merge-WtSchPatch($Target, $Patch) {
    $regular = [ordered]@{}
    foreach ($pair in @(Get-WtSchPairs $Patch)) {
        if ($pair.Name -cne 'alarms') { $regular[$pair.Name] = $pair.Value; continue }
        $read = Read-WtSchAlarms $pair.Value
        if ($read.Problem) { return $read.Problem }
        $incoming = @($pair.Value | Where-Object { $null -ne $_ })
        $existing = @()
        if ($null -ne $Target.alarms) { $existing = @($Target.alarms) }
        $alarms = [System.Collections.Generic.List[object]]::new()
        for ($i = 0; $i -lt [Math]::Max($incoming.Count, $existing.Count); $i++) {
            $alarm = if ($i -lt $existing.Count -and (Test-WtRecordObject $existing[$i])) { Copy-WtItem $existing[$i] } else { [pscustomobject]@{} }
            if ($i -lt $incoming.Count) { Merge-WtRecordPatch $alarm $incoming[$i] }
            elseif ($null -ne (Get-WtField $alarm 'before')) { Set-WtField $alarm 'before' $null }
            $alarms.Add($alarm)
        }
        Set-WtField $Target 'alarms' $alarms.ToArray()
    }
    Merge-WtRecordPatch $Target $regular
    ''
}

function Get-WtSchRuleKey($Entry) {
    if (-not $Entry.Repeat) { return '' }
    $r = $Entry.Repeat
    @($r.Freq, $r.Interval, (@($r.Days | ForEach-Object { [int]$_ } | Sort-Object) -join ','), $r.MonthDay, $r.Nth,
        $Entry.Start.Ticks, $Entry.AllDay) -join '|'
}

# Patch: title · note · start · end · repeat · alarms · tags. Id 없으면 새 일정.
# FromDate는 원래 회차 날짜(이 회차부터 끝까지). 결과: Success · Reason · Id · Store(다음 저장 핸들).
function Save-WtScheduleItem($Store, $Patch, [string]$Id, [string]$FromDate, [string]$At = (Get-WtStamp)) {
    $fail = [pscustomobject]@{ Success = $false; Reason = ''; Id = $Id; Store = $Store }
    if ($Store.Name -cne 'schedule') { $fail.Reason = '일정 저장소 핸들이 아닙니다'; return $fail }
    if (-not (ConvertFrom-WtStamp $At)) { $fail.Reason = '앱 시각을 읽지 못했습니다'; return $fail }
    if (-not (Test-WtRecordObject $Patch)) { $fail.Reason = '바꿀 칸은 객체여야 합니다'; return $fail }
    $pairs = @(Get-WtSchPairs $Patch)
    if (@($pairs | Where-Object { $_.Name -cnotin @('title', 'note', 'start', 'end', 'repeat', 'alarms', 'tags') }).Count) {
        $fail.Reason = '편집할 수 없는 칸입니다'; return $fail
    }
    $edit = Get-WtRecordEdit $Store $Id
    if (-not $edit.Success) { $fail.Reason = $edit.Reason; return $fail }
    $old = $null
    if ($Id) {
        $old = ConvertFrom-WtScheduleItem (Copy-WtItem $edit.Item)
        if ($old.State -in 'readonly', 'deleted') { $fail.Reason = '읽기 전용 · 지운 항목은 편집할 수 없습니다'; return $fail }
    } else {
        $edit.Item = [pscustomobject][ordered]@{ id = New-WtId; kind = 'event'; title = ''; note = ''; start = $null; end = $null
            repeat = $null; alarms = @(); tags = @(); rev = 0; created = $At; updated = $At; deleted = $null; origin = $null }
    }
    $patchProblem = Merge-WtSchPatch $edit.Item $Patch
    if ($patchProblem) { $fail.Reason = $patchProblem; return $fail }
    foreach ($field in 'title', 'note') { Set-WtField $edit.Item $field ([string](Get-WtField $edit.Item $field)) }
    $entry = ConvertFrom-WtScheduleItem $edit.Item
    if ($entry.State -ne 'ok') { $fail.Reason = $entry.Problem; return $fail }
    if ($entry.Repeat) {
        foreach ($key in @($entry.Repeat.Changes.Keys)) {
            $timing = $entry.Repeat.Changes[$key].Timing
            if ($timing -and -not $timing.AllDay -and $timing.Start.Date -ne $timing.End.Date) {
                $oldTiming = if ($old -and $old.Repeat) { $old.Repeat.Changes[$key].Timing } else { $null }
                if (-not $oldTiming -or $oldTiming.Start -ne $timing.Start -or $oldTiming.End -ne $timing.End) {
                    $fail.Reason = '날짜를 넘는 시각 기록은 근태의 업무외시간으로 적으세요'; return $fail
                }
            }
        }
    }
    if (-not $entry.AllDay -and $entry.End.Date -ne $entry.Start.Date -and
        (-not $old -or $old.Start -ne $entry.Start -or $old.End -ne $entry.End)) {
        $fail.Reason = '날짜를 넘는 시각 기록은 근태의 업무외시간으로 적으세요'; return $fail
    }
    $split = $old -and ((Get-WtSchRuleKey $old) -cne (Get-WtSchRuleKey $entry)) -and ($old.Repeat -or $entry.Repeat)
    if ($FromDate) { $split = $true }
    if ($split) {
        if (-not $old -or $old.State -ne 'ok') { $fail.Reason = '정상인 계열만 나눌 수 있습니다'; return $fail }
        $cut = if ($FromDate) { ConvertFrom-WtDateText $FromDate } else { $old.Start.Date }
        if (-not $cut -or ($old.Repeat -and -not (Get-WtRepeatDates $old.Repeat $old.Start $cut $cut).Count) -or
            (-not $old.Repeat -and $cut -ne $old.Start.Date)) { $fail.Reason = '반복에 있는 원래 회차 날짜를 고르세요'; return $fail }
        # 시작을 따로 바꾸지 않았으면 고른 회차로 옮기고 길이는 유지한다.
        if ($entry.Start -eq $old.Start) {
            $shift = $cut - $old.Start.Date
            Set-WtField $edit.Item.start 'date' (ConvertTo-WtDateText ($entry.Start + $shift))
            if ($null -ne $edit.Item.end) { Set-WtField $edit.Item.end 'date' (ConvertTo-WtDateText ($entry.End + $shift)) }
        }
        if ($edit.Item.repeat) {
            Set-WtField $edit.Item.repeat 'skip' @()
            Set-WtField $edit.Item.repeat 'changes' ([pscustomobject]@{})
            # 횟수를 따로 고치지 않았다면 앞의 원래 회차 수만큼 뺀다(skip도 회차다).
            $rp = Get-WtField $Patch 'repeat'
            $hasCount = @(Get-WtSchPairs $rp | Where-Object Name -ceq 'count').Count -gt 0
            if ($old.Repeat -and $null -ne $old.Repeat.Count -and -not $hasCount -and $cut -gt $old.Start.Date) {
                $before = (Get-WtRepeatDates $old.Repeat $old.Start $old.Start $cut.AddDays(-1)).Count
                Set-WtField $edit.Item.repeat 'count' ([Math]::Max(1, $old.Repeat.Count - $before))
            }
        }
        $previous = Copy-WtItem $old.Item
        $hasPrevious = $old.Repeat -and $cut -gt $old.Start.Date -and (Get-WtRepeatDates $old.Repeat $old.Start $old.Start $cut.AddDays(-1)).Count -gt 0
        if ($hasPrevious) {
            Set-WtField $previous.repeat 'until' (ConvertTo-WtDateText $cut.AddDays(-1))
            Set-WtField $previous.repeat 'count' $null
            Set-WtItemEdited $previous $At
        } else { [void](Set-WtRecordDeleted $previous $true $At) }
        $edit.Items[$edit.Index] = $previous
        Set-WtField $edit.Item 'id' (New-WtId)
        Set-WtField $edit.Item 'origin' ([pscustomobject]@{ from = 'split'; id = $Id; at = $At })
        Set-WtField $edit.Item 'created' $At
        Set-WtField $edit.Item 'rev' 0
        $entry = ConvertFrom-WtScheduleItem $edit.Item
        if ($entry.State -ne 'ok') { $fail.Reason = $entry.Problem; return $fail }
        $edit.Items += , $edit.Item
    } elseif ($Id) { Set-WtItemEdited $edit.Item $At }
    else { $edit.Items += , $edit.Item }
    $next = Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $At))
    $script:cache = $null
    [pscustomobject]@{ Success = $true; Reason = ''; Id = $edit.Item.id; Store = $next }
}

function Set-WtScheduleDeleted($Store, [string]$Id, [bool]$Deleted = $true, [string]$At = (Get-WtStamp)) {
    $edit = Get-WtRecordEdit $Store $Id
    $reason = $edit.Reason
    if ($Store.Name -cne 'schedule') { $reason = '일정 저장소 핸들이 아닙니다' }
    if (-not $Id) { $reason = 'id를 고르세요' }
    if (-not $reason -and (ConvertFrom-WtScheduleItem $edit.Item).State -eq 'readonly') { $reason = '읽기 전용 항목입니다' }
    if (-not $reason) { $reason = Set-WtRecordDeleted $edit.Item $Deleted $At }
    if (-not $reason -and -not $Deleted -and (ConvertFrom-WtScheduleItem $edit.Item).State -ne 'ok') { $reason = '내용을 복구할 수 없는 항목입니다' }
    if ($reason) { return [pscustomobject]@{ Success = $false; Reason = $reason; Id = $Id; Store = $Store } }
    $next = Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $At))
    $script:cache = $null
    [pscustomobject]@{ Success = $true; Reason = ''; Id = $Id; Store = $next }
}

# 원래 회차 날짜 하나를 건너뛰거나 바꾼다. Reset이면 그 예외만 없앤다.
function Set-WtScheduleOccurrence($Store, [string]$Id, [string]$OriginalDate, $Patch, [switch]$Skip, [switch]$Reset, [string]$At = (Get-WtStamp)) {
    $edit = Get-WtRecordEdit $Store $Id
    $reason = $edit.Reason
    if ($Store.Name -cne 'schedule' -or -not (ConvertFrom-WtStamp $At)) { $reason = '일정 핸들 · 앱 시각을 확인하세요' }
    $e = if ($edit.Success -and $Id) { ConvertFrom-WtScheduleItem $edit.Item } else { $null }
    $day = ConvertFrom-WtDateText $OriginalDate
    if (-not $e -or $e.State -ne 'ok' -or -not $e.Repeat -or -not $day) { $reason = '정상인 반복 회차를 고르세요' }
    elseif (-not (Get-WtRepeatDates $e.Repeat $e.Start $day $day).Count) { $reason = '반복에 없는 회차입니다' }
    if (-not $Skip -and -not $Reset) {
        if (-not (Test-WtRecordObject $Patch) -or @(Get-WtSchPairs $Patch | Where-Object { $_.Name -cnotin @('start', 'end', 'title', 'note', 'alarms') }).Count) {
            $reason = '회차에서 바꿀 수 없는 칸입니다'
        }
    }
    if ($reason) { return [pscustomobject]@{ Success = $false; Reason = $reason; Id = $Id; Store = $Store } }
    $r = $edit.Item.repeat
    $skipDates = @($r.skip | Where-Object { $null -ne $_ -and $_ -cne $OriginalDate })
    $changes = [ordered]@{}
    foreach ($p in @(Get-WtSchPairs $r.changes)) { $changes[$p.Name] = $p.Value }
    if ($Reset) { $changes.Remove($OriginalDate) }
    elseif ($Skip) { $skipDates += $OriginalDate }
    else {
        if (-not $changes.Contains($OriginalDate)) { $changes[$OriginalDate] = [pscustomobject]@{} }
        $patchProblem = Merge-WtSchPatch $changes[$OriginalDate] $Patch
        if ($patchProblem) { return [pscustomobject]@{ Success = $false; Reason = $patchProblem; Id = $Id; Store = $Store } }
        $c = Read-WtSchChange $e $OriginalDate $changes[$OriginalDate]
        if ($c.Problem) { return [pscustomobject]@{ Success = $false; Reason = $c.Problem; Id = $Id; Store = $Store } }
        if ($c.Timing -and -not $c.Timing.AllDay -and $c.Timing.Start.Date -ne $c.Timing.End.Date) {
            return [pscustomobject]@{ Success = $false; Reason = '날짜를 넘는 시각 기록은 근태의 업무외시간으로 적으세요'; Id = $Id; Store = $Store }
        }
    }
    Set-WtField $r 'skip' $skipDates
    Set-WtField $r 'changes' (Copy-WtItem $changes)
    Set-WtItemEdited $edit.Item $At
    $next = Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $At))
    $script:cache = $null
    [pscustomobject]@{ Success = $true; Reason = ''; Id = $Id; Store = $next }
}

# ---- 알람 (앱이 켜져 있는 동안, 소리 · 타이머 없음) --------------------------------------------

function Open-WtScheduleAlarmStore { Open-WtStore -Name 'schedule-state' -Schema 1 }

# (Previous, Now] 현지 벽시계 구간. Previous 없으면 첫 실행이라 지난 알람은 울리지 않는다.
# 상태는 회차 키 + before로 구분한다(한 회차의 여러 알람이 서로 막지 않게).
function Get-WtScheduleAlarms($Now, $Previous, [object[]]$Entries, $StateStore) {
    $r = [pscustomobject]@{ Success = $true; Reason = ''; Alarms = @() }
    $nowAt = ConvertFrom-WtStamp ([string]$Now)
    $prevAt = ConvertFrom-WtStamp ([string]$Previous)
    if (-not $nowAt -or ($Previous -and -not $prevAt)) { $r.Success = $false; $r.Reason = '앱 시각을 읽지 못했습니다'; return $r }
    if (-not $prevAt) { return $r }
    if ($nowAt -lt $prevAt -or $nowAt.DateTime -lt $prevAt.DateTime) { $r.Success = $false; $r.Reason = '지금 시각이 앞서 본 시각보다 이릅니다'; return $r }
    if ($StateStore -and $StateStore.State -eq 'error') { $r.Success = $false; $r.Reason = $StateStore.Error; return $r }
    $fired = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($i in @($StateStore.Items)) { if ($i.key) { [void]$fired.Add([string]$i.key) } }
    $list = [System.Collections.Generic.List[object]]::new()
    # 366일 앞의 일정도 미리 알람을 줄 수 있다. 옮긴 회차는 기존 펼치기 함수가 찾는다.
    $lo = $prevAt.DateTime.Date
    $hi = $nowAt.DateTime.Date.AddDays(366)
    if ($hi -gt [datetime]::new(2199, 12, 31)) { $hi = [datetime]::new(2199, 12, 31) }
    foreach ($o in @(Get-WtScheduleOccurrences $Entries $lo $hi)) {
        foreach ($before in @($o.Alarms)) {
            $due = $o.Start.AddMinutes(-$before)
            $key = "$($o.Key)/$before"
            if ($due -gt $prevAt.DateTime -and $due -le $nowAt.DateTime -and $fired.Add($key)) {
                $list.Add([pscustomobject]@{ Key = $key; OccurrenceKey = $o.Key; Id = $o.Entry.Id; OriginalDate = ConvertTo-WtDateText $o.Original
                    Before = $before; Due = $due; Title = $o.Title; Note = $o.Note; Start = $o.Start })
            }
        }
    }
    $r.Alarms = @($list | Sort-Object Due, Key -Culture 'ko-KR')
    $r
}

# 실제 알림을 받아들인 뒤에만 호출한다. 실패 · 낡은 핸들은 Save-WtStore의 예외 그대로다.
function Save-WtScheduleAlarms($Store, [object[]]$Alarms, [string]$At = (Get-WtStamp)) {
    $now = ConvertFrom-WtStamp $At
    if ($Store.Name -cne 'schedule-state' -or -not $now) { return [pscustomobject]@{ Success = $false; Reason = '알람 상태 핸들 · 시각을 확인하세요'; Store = $Store } }
    $items = [System.Collections.Generic.List[object]]::new()
    $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($i in @($Store.Items)) {
        $atValue = ConvertFrom-WtStamp ([string]$i.at)
        if ($atValue -and $atValue -lt $now.AddDays(-7)) { continue }
        $items.Add((Copy-WtItem $i))
        if ($i.key) { [void]$keys.Add([string]$i.key) }
    }
    foreach ($a in @($Alarms)) {
        if (-not $a.Key -or -not $a.OccurrenceKey -or $null -eq (ConvertFrom-WtWhole $a.Before 0 527040)) {
            return [pscustomobject]@{ Success = $false; Reason = '알람 결과 목록을 넘기세요'; Store = $Store }
        }
        if ($keys.Add([string]$a.Key)) { $items.Add([pscustomobject]@{ key = [string]$a.Key; occurrence = [string]$a.OccurrenceKey; before = $a.Before; at = $At }) }
    }
    $next = Save-WtStore $Store $items.ToArray()
    [pscustomobject]@{ Success = $true; Reason = ''; Store = $next }
}

# ---- 루틴 (schedule schema 2 · routine-log schema 1, 화면 없음) --------------------------------

# 기존 일정 해석기는 routine을 계속 읽기 전용으로 본다. 루틴만 이 해석기로 따로 읽는다.
function ConvertFrom-WtRoutineItem($Item) {
    $e = [pscustomobject]@{ Id = ''; Title = ''; Item = $Item; State = 'ok'; Problem = ''; Start = $null
        Freq = ''; Days = @(); Every = $null; From = $null; To = $null; WorkdaysOnly = $false }
    if (-not (Test-WtRecordObject $Item)) { $e.State = 'broken'; $e.Problem = '항목 모양이 틀렸습니다'; return $e }
    $e.Id = [string](Get-WtField $Item 'id'); $e.Title = [string](Get-WtField $Item 'title')
    if (Test-WtDeleted $Item) { $e.State = 'deleted'; return $e }
    $rule = Get-WtField $Item 'routine'
    $e.Freq = [string](Get-WtField $rule 'freq')
    if ((Get-WtField $Item 'kind') -cne 'routine' -or ((Test-WtRecordObject $rule) -and $e.Freq -cnotin 'daily', 'weekly', 'hourly')) {
        $e.State = 'readonly'; $e.Problem = '새 버전의 루틴 종류 · 빈도입니다'; return $e
    }
    $e.Start = ConvertFrom-WtDateText ([string](Get-WtField (Get-WtField $Item 'start') 'date'))
    $problem = Get-WtRecordProblem $Item
    if (-not $problem -and (-not $e.Id -or -not $e.Start -or -not (Test-WtRecordObject $rule))) { $problem = '루틴 id · 시작 날짜 · 규칙을 확인하세요' }
    $only = Get-WtField $rule 'workdaysOnly'
    if ($null -ne $only) {
        if ($only -isnot [bool]) { $problem = 'workdaysOnly는 참거짓이어야 합니다' } else { $e.WorkdaysOnly = $only }
    }
    if ($e.Freq -ceq 'weekly') {
        $days = Get-WtField $rule 'days'
        if ($days -isnot [array] -or $days.Count -eq 0) { $problem = '고른 요일 목록이 필요합니다' }
        else {
            foreach ($day in $days) {
                $whole = ConvertFrom-WtWhole $day 1 7
                if ($null -eq $whole) { $problem = '요일은 월=1부터 일=7까지 정수입니다'; break }
                $e.Days += [int]$whole
            }
        }
    }
    if ($e.Freq -ceq 'hourly') {
        $e.Every = ConvertFrom-WtWhole (Get-WtField $rule 'every') 1 12
        $e.From = ConvertFrom-WtTimeText ([string](Get-WtField $rule 'from'))
        $e.To = ConvertFrom-WtTimeText ([string](Get-WtField $rule 'to'))
        if ($null -eq $e.Every -or $null -eq $e.From -or $null -eq $e.To -or $e.From -ge $e.To) { $problem = '시간 간격(1~12) · 같은 날의 시작/끝 시각을 확인하세요' }
    }
    if ($problem) { $e.State = 'broken'; $e.Problem = $problem }
    $e
}

function ConvertFrom-WtRoutineDate($Value) {
    if ($Value -is [datetime]) { return ConvertFrom-WtDateText (ConvertTo-WtDateText $Value) }
    ConvertFrom-WtDateText ([string]$Value)
}

function Get-WtRoutineStamp([string]$At) {
    $stamp = ConvertFrom-WtStamp $At
    if ($null -ne $stamp) { Get-WtStamp ($stamp.ToOffset([timespan]::FromHours(9))) }
}

function Get-WtRoutineEntries($Store) {
    if ($Store.State -notin 'ok', 'missing') { throw "schedule.json은 읽지 못했습니다. ($($Store.Error))" }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Store.Items) {
        # 다른 kind와 id가 겹친 경우도 편집 · 계산에 쓰지 않는다.
        $id = [string](Get-WtField $item 'id')
        $duplicate = $id -and -not $seen.Add($id)
        if ((Get-WtField $item 'kind') -cne 'routine') { continue }
        $entry = ConvertFrom-WtRoutineItem $item
        if ($duplicate -and $entry.State -ne 'deleted') { $entry.State = 'broken'; $entry.Problem = 'id가 앞 항목과 겹칩니다' }
        $entry
    }
}

# work.days와 휴무일은 코어에서, 휴가는 코어 달력 출처에서 묻는다. 다른 탭 함수는 부르지 않는다.
function Test-WtRoutineDayOff([datetime]$Date) {
    $day = (([int]$Date.DayOfWeek + 6) % 7) + 1
    if ($day -notin @(Get-WtSetting 'work.days')) { return $true }
    $holiday = Get-WtHolidayData
    if ($holiday.Error) { throw $holiday.Error }
    if ((Get-WtHolidayDates $Date $Date).Contains((ConvertTo-WtDateText $Date))) { return $true }
    $calendar = Get-WtCalendarItems $Date $Date -Exclude @('schedule')
    if (-not $calendar.Success) { throw ($calendar.Errors.Reason -join '; ') }
    @($calendar.Items | Where-Object { $_.Kind -ceq 'leave' }).Count -gt 0
}

function Get-WtRoutineSlotKeys($Entry, [datetime]$Date) {
    if ($Entry.State -ne 'ok' -or $Date -lt $Entry.Start) { return }
    if ($Entry.Freq -ceq 'weekly' -and ((([int]$Date.DayOfWeek + 6) % 7) + 1) -notin $Entry.Days) { return }
    if ($Entry.WorkdaysOnly -and (Test-WtRoutineDayOff $Date)) { return }
    $dateText = ConvertTo-WtDateText $Date
    if ($Entry.Freq -cne 'hourly') { $dateText; return }
    for ($minute = [int]$Entry.From.TotalMinutes; $minute -lt $Entry.To.TotalMinutes; $minute += [int]$Entry.Every * 60) {
        $dateText + 'T' + $Date.AddMinutes($minute).ToString('HH:mm', $script:inv)
    }
}

function Get-WtRoutineRuleKey($Entry) {
    @($Entry.Start.Ticks, $Entry.Freq, (@($Entry.Days | Sort-Object -Unique) -join ','), $Entry.Every,
        $Entry.From, $Entry.To, $Entry.WorkdaysOnly) -join '|'
}

# Store 생략은 지금 핸들. 결과 Success/Reason/Id/Store와 낡은 핸들 예외는 2a 편집 함수와 같다.
function New-WtRoutine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Title, [Parameter(Mandatory)][string]$Freq,
        [object[]]$Days, $Every, [string]$From, [string]$To, [switch]$WorkdaysOnly, $Start, $Store,
        [string]$At = (Get-WtStamp))
    if ($null -eq $Store) { $Store = Open-WtScheduleStore }
    $stamp = Get-WtRoutineStamp $At
    $date = if ($null -eq $Start) { if ($stamp) { ConvertTo-WtDateText (ConvertFrom-WtStamp $stamp).Date } } else { $parsed = ConvertFrom-WtRoutineDate $Start; if ($parsed) { ConvertTo-WtDateText $parsed } }
    $rule = [ordered]@{ freq = $Freq }
    if ($Freq -ceq 'weekly') { $rule.days = @($Days) }
    if ($Freq -ceq 'hourly') {
        $rule.every = $Every
        $rule.from = if ($PSBoundParameters.ContainsKey('From')) { $From } else { [string](Get-WtSetting 'work.start') }
        $rule.to = if ($PSBoundParameters.ContainsKey('To')) { $To } else { [string](Get-WtSetting 'work.end') }
    }
    if ($WorkdaysOnly) { $rule.workdaysOnly = $true }
    if (($PSBoundParameters.ContainsKey('Days') -and $Freq -cne 'weekly') -or
        (($PSBoundParameters.ContainsKey('Every') -or $PSBoundParameters.ContainsKey('From') -or $PSBoundParameters.ContainsKey('To')) -and $Freq -cne 'hourly')) {
        return [pscustomobject]@{ Success = $false; Reason = '빈도에 맞는 요일 · 시간 칸만 적으세요'; Id = ''; Store = $Store }
    }
    Save-WtRoutine -Store $Store -Patch @{ title = $Title; start = @{ date = $date }; routine = $rule } -At $At
}

# Patch는 title/start/routine. 규칙 변경은 기존 편집의 기본값처럼 첫 회차부터 나눈다(옛 계열 지운 표시).
function Save-WtRoutine($Store, $Patch, [string]$Id, [string]$At = (Get-WtStamp)) {
    if ($null -eq $Store) { $Store = Open-WtScheduleStore }
    $fail = [pscustomobject]@{ Success = $false; Reason = ''; Id = $Id; Store = $Store }
    $stamp = Get-WtRoutineStamp $At
    if ($Store.Name -cne 'schedule' -or -not $stamp -or -not (Test-WtRecordObject $Patch)) { $fail.Reason = '일정 핸들 · 앱 시각 · 바꿀 칸을 확인하세요'; return $fail }
    if (@(Get-WtSchPairs $Patch | Where-Object { $_.Name -cnotin 'title', 'start', 'routine' }).Count) { $fail.Reason = '편집할 수 없는 칸입니다'; return $fail }
    $edit = Get-WtRecordEdit $Store $Id
    if (-not $edit.Success) { $fail.Reason = $edit.Reason; return $fail }
    $old = $null
    if ($Id) {
        $old = ConvertFrom-WtRoutineItem (Copy-WtItem $edit.Item)
        if ($old.State -in 'readonly', 'deleted') { $fail.Reason = '읽기 전용 · 지운 루틴은 편집할 수 없습니다'; return $fail }
    } else {
        $edit.Item = [pscustomobject][ordered]@{ id = New-WtId; kind = 'routine'; title = ''; start = $null; routine = $null
            created = $stamp; updated = $stamp; rev = 0; deleted = $null }
    }
    Merge-WtRecordPatch $edit.Item $Patch
    # 빈도를 바꿀 때만 옛 빈도의 알려진 칸을 비운다. 모르는 칸은 깊은 복사에 그대로 남는다.
    $newRule = Get-WtField $edit.Item 'routine'
    if ($old -and (Test-WtRecordObject $newRule) -and $old.Freq -cne [string](Get-WtField $newRule 'freq')) {
        $keep = switch -CaseSensitive ([string](Get-WtField $newRule 'freq')) { weekly { @('days') }; hourly { @('every', 'from', 'to') }; default { @() } }
        foreach ($field in 'days', 'every', 'from', 'to') { if ($field -cnotin $keep) { $newRule.PSObject.Properties.Remove($field) } }
    }
    Set-WtField $edit.Item 'title' ([string](Get-WtField $edit.Item 'title'))
    $entry = ConvertFrom-WtRoutineItem $edit.Item
    if ($entry.State -ne 'ok') { $fail.Reason = $entry.Problem; return $fail }
    if ($old -and (Get-WtRoutineRuleKey $old) -cne (Get-WtRoutineRuleKey $entry)) {
        if ($old.State -ne 'ok') { $fail.Reason = '정상인 루틴만 나눌 수 있습니다'; return $fail }
        $previous = Copy-WtItem $old.Item
        $reason = Set-WtRecordDeleted $previous $true $stamp
        if ($reason) { $fail.Reason = $reason; return $fail }
        $edit.Items[$edit.Index] = $previous
        Set-WtField $edit.Item 'id' (New-WtId)
        Set-WtField $edit.Item 'origin' ([pscustomobject]@{ from = 'split'; id = $Id; at = $stamp })
        Set-WtField $edit.Item 'created' $stamp; Set-WtField $edit.Item 'updated' $stamp; Set-WtField $edit.Item 'rev' 0
        $edit.Items += , $edit.Item
    } elseif ($Id) { Set-WtItemEdited $edit.Item $stamp }
    else { $edit.Items += , $edit.Item }
    $next = Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $stamp))
    $script:cache = $null
    [pscustomobject]@{ Success = $true; Reason = ''; Id = $edit.Item.id; Store = $next }
}

function Set-WtRoutineDeleted($Store, [string]$Id, [bool]$Deleted = $true, [string]$At = (Get-WtStamp)) {
    if ($null -eq $Store) { $Store = Open-WtScheduleStore }
    $edit = Get-WtRecordEdit $Store $Id
    $reason = $edit.Reason; $stamp = Get-WtRoutineStamp $At
    if ($Store.Name -cne 'schedule' -or -not $Id -or -not $stamp) { $reason = '일정 핸들 · id · 앱 시각을 확인하세요' }
    if (-not $reason -and (ConvertFrom-WtRoutineItem $edit.Item).State -eq 'readonly') { $reason = '읽기 전용 항목입니다' }
    if (-not $reason) { $reason = Set-WtRecordDeleted $edit.Item $Deleted $stamp }
    if (-not $reason -and -not $Deleted -and (ConvertFrom-WtRoutineItem $edit.Item).State -ne 'ok') { $reason = '내용을 복구할 수 없는 루틴입니다' }
    if ($reason) { return [pscustomobject]@{ Success = $false; Reason = $reason; Id = $Id; Store = $Store } }
    $next = Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $stamp))
    $script:cache = $null
    [pscustomobject]@{ Success = $true; Reason = ''; Id = $Id; Store = $next }
}

function Read-WtRoutineSlot([string]$Slot) {
    if ($Slot -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2})?$') {
        $date = ConvertFrom-WtDateText $Slot.Substring(0, 10)
        if ($date -and ($Slot.Length -eq 10 -or $null -ne (ConvertFrom-WtTimeText $Slot.Substring(11)))) { return $date }
    }
    $null
}

function Test-WtRoutineLogItem($Item) {
    (Test-WtRecordObject $Item) -and (Get-WtField $Item 'id') -is [string] -and [bool]$Item.id -and
        (Get-WtField $Item 'routine') -is [string] -and [bool]$Item.routine -and
        $null -ne (Read-WtRoutineSlot ([string](Get-WtField $Item 'slot'))) -and
        $null -ne (ConvertFrom-WtStamp ([string](Get-WtField $Item 'at'))) -and -not (Get-WtRecordProblem $Item)
}

# Date는 yyyy-MM-dd 또는 datetime. Now는 시험/화면의 같은 시각을 고정할 때만 넘긴다.
function Get-WtRoutineSlots($Date, [string]$Now = (Get-WtStamp)) {
    $day = ConvertFrom-WtRoutineDate $Date; $stamp = Get-WtRoutineStamp $Now
    if (-not $day -or -not $stamp) { throw '날짜 · 앱 시각을 확인하세요' }
    $entries = @(Get-WtRoutineEntries (Get-WtScheduleData).Store)
    $log = Open-WtStore -Name 'routine-log' -Schema 1
    if ($log.State -notin 'ok', 'missing') { throw "routine-log.json은 읽지 못했습니다. ($($log.Error))" }
    $nowDate = (ConvertFrom-WtStamp $stamp).DateTime
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $done = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in $log.Items) {
        $id = [string](Get-WtField $item 'id')
        if (-not $id -or -not $seen.Add($id) -or (Test-WtDeleted $item) -or -not (Test-WtRoutineLogItem $item)) { continue }
        # 글 길이를 앞에 써서 id 안의 구분 글자와 충돌하지 않는다.
        $key = $item.routine.Length.ToString($script:inv) + ':' + $item.routine + $item.slot
        if (-not $done.ContainsKey($key)) { $done.Add($key, $item) }
    }
    foreach ($entry in $entries) {
        $nextFound = $false
        foreach ($slot in @(Get-WtRoutineSlotKeys $entry $day)) {
            $key = $entry.Id.Length.ToString($script:inv) + ':' + $entry.Id + $slot
            $record = if ($done.ContainsKey($key)) { $done[$key] } else { $null }
            $isNext = $false
            if ($entry.Freq -ceq 'hourly' -and -not $nextFound) {
                $time = ConvertFrom-WtTimeText $slot.Substring(11)
                if ($day.Add($time) -gt $nowDate) { $isNext = $true; $nextFound = $true }
            }
            [pscustomobject]@{ Routine = [pscustomobject]@{ Id = $entry.Id; Title = $entry.Title }; Slot = $slot
                Done = $null -ne $record; DoneAt = $(if ($record) { $record.at } else { $null }); Next = $isNext }
        }
    }
}

# Store는 쓰는 routine-log 핸들. 일정은 현재 저장소에서 읽어 차례가 실제 있는지 확인한다.
function Set-WtRoutineCheck([string]$Routine, [string]$Slot, [bool]$Done, $Store, [string]$At = (Get-WtStamp)) {
    if ($null -eq $Store) { $Store = Open-WtStore -Name 'routine-log' -Schema 1 }
    $fail = [pscustomobject]@{ Success = $false; Reason = ''; Id = ''; Store = $Store }
    $stamp = Get-WtRoutineStamp $At; $day = Read-WtRoutineSlot $Slot
    if ($Store.Name -cne 'routine-log' -or -not $stamp -or -not $day -or -not $Routine) { $fail.Reason = '기록 핸들 · 앱 시각 · 루틴 · 차례 키를 확인하세요'; return $fail }
    $edit = Get-WtRecordEdit $Store ''
    $entries = @(Get-WtRoutineEntries (Get-WtScheduleData).Store | Where-Object { $_.Id -ceq $Routine })
    if ($entries.Count -ne 1 -or $Slot -cnotin @(Get-WtRoutineSlotKeys $entries[0] $day)) { $fail.Reason = '루틴에 없는 차례입니다'; return $fail }
    $matches = @($edit.Items | Where-Object { (Get-WtField $_ 'routine') -ceq $Routine -and (Get-WtField $_ 'slot') -ceq $Slot })
    if ($matches.Count -gt 1) { $fail.Reason = '같은 루틴 · 차례 기록이 겹칩니다'; return $fail }
    $id = ''
    if ($matches.Count) {
        $item = $matches[0]; $id = [string]$item.id
        if (-not (Test-WtRoutineLogItem $item) -or @($edit.Items | Where-Object { (Get-WtField $_ 'id') -ceq $id }).Count -ne 1) { $fail.Reason = '체크 기록의 형식 · id를 확인하세요'; return $fail }
        if ($Done) {
            if (Test-WtDeleted $item) {
                $reason = Set-WtRecordDeleted $item $false $stamp
                if ($reason) { $fail.Reason = $reason; return $fail }
            } else { Set-WtItemEdited $item $stamp }
            Set-WtField $item 'at' $stamp
        } elseif (-not (Test-WtDeleted $item)) { [void](Set-WtRecordDeleted $item $true $stamp) }
        else { return [pscustomobject]@{ Success = $true; Reason = ''; Id = $id; Store = $Store } }
    } elseif ($Done) {
        $id = New-WtId
        $edit.Items += , [pscustomobject][ordered]@{ id = $id; routine = $Routine; slot = $Slot; at = $stamp; deleted = $null
            created = $stamp; updated = $stamp; rev = 0 }
    } else { return [pscustomobject]@{ Success = $true; Reason = ''; Id = ''; Store = $Store } }
    $next = Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $stamp))
    [pscustomobject]@{ Success = $true; Reason = ''; Id = $id; Store = $next }
}

# slot의 날짜로 양끝 포함. 지운 기록도, 지운 루틴의 기록도 원자료 그대로 돌려준다.
function Get-WtRoutineHistory($From, $To, [string]$Routine, $Store) {
    $first = ConvertFrom-WtRoutineDate $From; $last = ConvertFrom-WtRoutineDate $To
    if (-not $first -or -not $last -or $first -gt $last) { throw '날짜 범위를 확인하세요' }
    if ($null -eq $Store) { $Store = Open-WtStore -Name 'routine-log' -Schema 1 }
    if ($Store.Name -cne 'routine-log' -or $Store.State -notin 'ok', 'missing') { throw "체크 기록을 읽지 못했습니다. ($($Store.Error))" }
    foreach ($item in $Store.Items) {
        $date = Read-WtRoutineSlot ([string](Get-WtField $item 'slot'))
        if ($date -and $date -ge $first -and $date -le $last -and (-not $Routine -or (Get-WtField $item 'routine') -ceq $Routine)) { Copy-WtItem $item }
    }
}

Export-ModuleMember -Function Open-WtScheduleStore, Save-WtScheduleItems, Get-WtScheduleData, ConvertFrom-WtScheduleItem,
    Get-WtRepeatDates, Get-WtScheduleOccurrences, Get-WtScheduleDays, ConvertFrom-WtScheduleRow, Update-WtScheduleSchema,
    Import-WtScheduleLegacy, Get-WtScheduleLastImport, Save-WtScheduleItem, Set-WtScheduleDeleted, Set-WtScheduleOccurrence,
    Open-WtScheduleAlarmStore, Get-WtScheduleAlarms, Save-WtScheduleAlarms,
    New-WtRoutine, Save-WtRoutine, Set-WtRoutineDeleted, Get-WtRoutineSlots, Set-WtRoutineCheck, Get-WtRoutineHistory

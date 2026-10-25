# 근태 데이터 (화면 없음): 형식 검사 · schema 1 → 2 이전 · 예전 CSV 가져오기(합치기) · 월 요약 규칙. 화면은 Attendance.psm1.
# 형식과 규칙 전체: docs/plans/schedule-attendance-design.md 「근태 형식」. 공통 틀은 core\Records.psm1, 휴무일은 core\Calendar.psm1
# 저장소 attendance.json (schema 2). 항목:
#   id       한 번 정하면 바꾸지 않는다. 예전 CSV의 id는 그대로
#   kind     work 출근 · 퇴근 / overtime 업무외시간 · 출동 / trip 출장 / leave 휴가 / other 기타(보이기만, 계산에서 뺌)
#            모르는 값이면 읽기 전용 (2차 후보: oncall 대기 · leave-grant 연차 발생 · month-close 월 마감)
#   start    { date, time }. time = null이면 날짜만 (출장 · 휴가)
#   end      { date, time } 또는 null. 끝 날짜는 그날 포함. 밤을 넘기거나 24시간이 넘어도 끝 날짜를 그대로 적는다
#            work의 end = null이면 「퇴근 기록 없음」(0시간이 아니라 모름). overtime의 end = null이면 「끝 시각 없음」
#            시작과 끝은 둘 다 시각이 있거나 둘 다 없다
#   place · note   글 (비면 ""). place: 출장지 · 현장
#   tags     [ 글 ]
#   overtime { how: "remote" 원격 · "onsite" 현장 · null, ref: 관련 번호(작업 · 변경 · 장애 번호, 글) }   kind = overtime일 때
#   leave    { type, days }   kind = leave일 때
#            type annual 연차 · half 반차 · half-am 오전 반차 · half-pm 오후 반차 · sick 병가 · family 경조사 · comp 대체 휴무 · other 기타
#            days null = 규칙대로 센다(아래), 숫자 = 사람이 정한 차감 일수(회사가 정한 사실이라 저장한다)
#   rev · created · updated · deleted · origin   일정과 같다 (core\Records.psm1, ScheduleData.psm1 맨 위)
#   범위: 출근 · 업무외 기록 하나는 31일까지, leave.days는 0~366 (밖이면 그 항목만 고칠 항목). 저장은 저장소 핸들로만 한다(Save-WtAttendanceItems)
# 하루 근무 시간 · 월 합계 같은 계산 값은 저장하지 않는다. 계산 규칙은 이 파일의 Get-WtAttendanceSummary 하나에 모으고 이름(att-2)을 붙인다.
# 읽기 규칙: 모르는 칸 · 맨 위 키는 그대로 둔다. 모르는 kind · leave.type · overtime.how가 든 항목은 읽기 전용(계산에서 뺌),
#   날짜 · 시각을 못 읽는 항목은 「고칠 항목」. 두 경우 모두 저장할 때 그대로 쓴다.

$ErrorActionPreference = 'Stop'

$script:schema = 2
$script:rule = 'att-2'
$script:kinds = @('work', 'overtime', 'trip', 'leave', 'other')
$script:leaveTypes = @('annual', 'half', 'half-am', 'half-pm', 'sick', 'family', 'comp', 'other')
$script:halfTypes = @('half', 'half-am', 'half-pm')
$script:hows = @('remote', 'onsite')
$script:typeMap = @{ '출근' = 'work'; '업무외시간 근무' = 'overtime'; '출장' = 'trip'; '휴가' = 'leave' }
$script:leaveMap = @{ '연차' = 'annual'; '오전 반차' = 'half-am'; '오후 반차' = 'half-pm'; '병가' = 'sick'; '경조사' = 'family'; '대체 휴무' = 'comp' }
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:cache = $null
$script:lastImport = $null
# 숫자 칸 · 길이의 범위 (형식 계약. 밖이면 그 항목만 고칠 항목). 해석은 core\Records.psm1의 ConvertFrom-WtWhole · ConvertFrom-WtNumber 하나로 한다
$script:maxSpanDays = 31            # 출근 · 업무외 기록 하나의 길이 (31일까지)
$script:maxLeaveDays = 366          # 사람이 정한 휴가 일수
<#
예전 attendance.csv의 칸 하나가 정하는 항목 칸 (다시 가져올 때 이 경로만 기존 항목에 옮긴다. 나머지 칸은 건드리지 않는다).
업무외 끝 날짜는 시작 날짜 · 시각에 따라 정해지므로 StartDate · StartTime도 end.date를 정한다. 종류(Type)가 바뀌면 종류별 칸을 통째로 다시 맞춘다.
목록 칸 tags는 CSV가 소유하지 않는다
#>
$script:csvOwned = @{
    Type = @('kind', 'start.time', 'end', 'overtime', 'leave', 'note', 'place')
    StartDate = @('start.date', 'end.date'); StartTime = @('start.time', 'end.date'); EndDate = @('end.date'); EndTime = @('end.time', 'end.date')
    Place = @('place'); Detail = @('note', 'leave.type')
}

# 월 요약 규칙의 고를 수 있는 값 (설정 화면은 2단계)
Register-WtSettingDefault 'attendance.tripDays' 'all'   # 출장 일수: all = 걸친 날 모두 · workdays = 주말 · 휴무일 빼고

# ---- 읽기 · 쓰기 ------------------------------------------------------------------------------

# 저장소 핸들 (core\Storage.psm1 Open-WtStore). schema 1 파일이면 2로 올려 읽는다. 읽지 못하면 State = error
function Open-WtAttendanceStore {
    Open-WtStore -Name 'attendance' -Schema $script:schema -Migrate { param($doc, $from) Update-WtAttendanceSchema $doc $from }
}

# 항목을 저장한다. 읽은 핸들(Get-WtAttendanceData의 Store)과 그 핸들의 Items를 고친 목록을 넘긴다 (Save-WtScheduleItems와 같은 약속)
function Save-WtAttendanceItems($Store, [object[]]$Items) {
    [void](Save-WtStore -Store $Store -Items @(Compress-WtDeletedItems @($Items)))
    $script:cache = $null
}

# 화면 · 홈 카드가 같이 쓰는 읽은 결과 @{ Stamp; Store; Items; Entries; Error }. 못 읽어도 예외를 올리지 않는다 (ScheduleData.psm1과 같은 약속)
function Get-WtAttendanceData {
    $stamp = Get-WtStoreStamp 'attendance'
    if ($script:cache -and $script:cache.Stamp -ceq $stamp) { return $script:cache }
    $store = Open-WtAttendanceStore
    $err = $store.Error
    $items = $store.Items
    $entries = @(foreach ($i in $items) { ConvertFrom-WtAttendanceItem $i })
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($e in $entries) {
        if (-not $e.Id) { continue }
        if (-not $seen.Add($e.Id) -and $e.State -ne 'deleted') { $e.State = 'broken'; $e.Problem = "id가 앞 항목과 겹칩니다: '$($e.Id)'" }
    }
    $script:cache = [pscustomobject]@{ Stamp = $stamp; Store = $store; Items = $items; Entries = $entries; Error = $err }
    $script:cache
}

# ---- 항목 하나 읽기 ---------------------------------------------------------------------------

function Test-WtAttObject($Value) { $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [ValueType] -and $Value -isnot [array] }

function Read-WtAttPoint($Point, [string]$What) {
    if (-not (Test-WtAttObject $Point)) { return @{ Problem = "${What} 모양이 틀렸습니다" } }
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
저장된 항목 하나 → 화면 · 계산용 값. 저장 파일은 바꾸지 않는다(Item에 원래 객체가 그대로 있다).
State: ok · readonly(새 버전의 값) · broken(고칠 항목) · deleted
나머지: Id · Kind · StartDate · EndDate(그날 포함) · Start · End([datetime], 시각이 없으면 날짜 0시) · HasTime · HasEnd
        Minutes(시작~끝 분, 시각이 없거나 끝이 없으면 $null) · Place · Note · How · Ref · LeaveType · LeaveDays(사람이 정한 일수 | $null) · Problem
#>
function ConvertFrom-WtAttendanceItem($Item) {
    $e = [ordered]@{ Id = ''; Item = $Item; State = 'ok'; Problem = ''; Kind = ''; StartDate = $null; EndDate = $null; Start = $null; End = $null
        HasTime = $false; HasEnd = $false; Minutes = $null; Place = ''; Note = ''; How = $null; Ref = ''; LeaveType = $null; LeaveDays = $null }
    if (Test-WtDeleted $Item) { $e.Id = [string]$Item.id; $e.State = 'deleted'; return [pscustomobject]$e }
    if (-not (Test-WtAttObject $Item)) { $e.State = 'broken'; $e.Problem = '항목 모양이 틀렸습니다'; return [pscustomobject]$e }
    $e.Id = [string]$Item.id; $e.Kind = [string]$Item.kind; $e.Place = [string]$Item.place; $e.Note = [string]$Item.note
    $problem = ''
    $s = Read-WtAttPoint $Item.start '시작'
    if ($s.Problem) { $problem = $s.Problem }
    else {
        $e.StartDate = $s.Date; $e.HasTime = $null -ne $s.Time
        $e.Start = if ($e.HasTime) { $s.Date + $s.Time } else { $s.Date }
        $e.EndDate = $s.Date; $e.End = $e.Start
        if ($null -ne $Item.end) {
            $f = Read-WtAttPoint $Item.end '끝'
            if ($f.Problem) { $problem = $f.Problem }
            elseif (($null -ne $f.Time) -ne $e.HasTime) { $problem = '시작과 끝 중 한쪽에만 시각이 있습니다' }
            else {
                $e.HasEnd = $true; $e.EndDate = $f.Date
                $e.End = if ($e.HasTime) { $f.Date + $f.Time } else { $f.Date }
                if ($e.End -lt $e.Start) { $problem = '끝이 시작보다 이릅니다' }
                elseif ($e.Kind -in 'work', 'overtime' -and ($e.End - $e.Start).TotalDays -gt $script:maxSpanDays) { $problem = "기록 하나가 $($script:maxSpanDays)일을 넘습니다" }
                elseif ($e.HasTime) { $e.Minutes = [int]($e.End - $e.Start).TotalMinutes }
            }
        }
    }
    # 새 버전의 값은 고칠 항목이 아니다. 더 새 앱에서는 맞는 값이라 읽기 전용으로만 둔다
    if ($script:kinds -cnotcontains $e.Kind) { $e.State = 'readonly'; $e.Problem = "새 버전의 근태 종류입니다: '$($e.Kind)'"; return [pscustomobject]$e }
    if ($e.Kind -eq 'overtime') {
        $o = $Item.overtime
        if ($null -ne $o) {
            if (-not (Test-WtAttObject $o)) { if (-not $problem) { $problem = '업무외 정보(overtime) 모양이 틀렸습니다' } }
            else {
                $e.Ref = [string]$o.ref
                if ($null -ne $o.how) {
                    if ($script:hows -cnotcontains [string]$o.how) { $e.State = 'readonly'; $e.Problem = "새 버전의 업무외 방식입니다: '$($o.how)'"; return [pscustomobject]$e }
                    $e.How = [string]$o.how
                }
            }
        }
    }
    if ($e.Kind -eq 'leave') {
        $l = $Item.leave
        if (-not (Test-WtAttObject $l) -or $null -eq $l.type) { if (-not $problem) { $problem = '휴가 종류가 없습니다' } }
        else {
            if ($script:leaveTypes -cnotcontains [string]$l.type) { $e.State = 'readonly'; $e.Problem = "새 버전의 휴가 종류입니다: '$($l.type)'"; return [pscustomobject]$e }
            $e.LeaveType = [string]$l.type
            $days = Get-WtField $l 'days'
            if ($null -ne $days) {
                $v = ConvertFrom-WtNumber $days 0 $script:maxLeaveDays
                if ($null -eq $v) { if (-not $problem) { $problem = "휴가 일수를 읽지 못했습니다(0~$($script:maxLeaveDays)): '$days'" } }
                else { $e.LeaveDays = $v }
            }
        }
    }
    if (-not $e.Id -and -not $problem) { $problem = 'id가 없습니다' }
    $common = Get-WtRecordProblem $Item
    if ($common -and -not $problem) { $problem = $common }
    if ($problem) { $e.State = 'broken'; $e.Problem = $problem }
    [pscustomobject]$e
}

# ---- 월 요약 (규칙 att-2) ---------------------------------------------------------------------

function Test-WtAttWorkday([datetime]$Day, $DayOff) {
    $Day.DayOfWeek -ne [System.DayOfWeek]::Saturday -and $Day.DayOfWeek -ne [System.DayOfWeek]::Sunday -and
        -not ($DayOff -and $DayOff.Contains((ConvertTo-WtDateText $Day)))
}

# 휴가 한 건이 그 달에 쓰는 일수. 사람이 정한 days가 있으면 시작한 달에 그 값을 센다.
# 없으면 그 달에 걸친 날 중 근무일(주말 · 휴무일 빼고) 수, 반차 종류는 그 × 0.5
function Get-WtLeaveDays($Entry, [datetime]$First, [datetime]$Last, $DayOff) {
    if ($null -ne $Entry.LeaveDays) { if ($Entry.StartDate -ge $First -and $Entry.StartDate -le $Last) { return $Entry.LeaveDays } else { return 0.0 } }
    $a = if ($Entry.StartDate -lt $First) { $First } else { $Entry.StartDate }
    $b = if ($Entry.EndDate -gt $Last) { $Last } else { $Entry.EndDate }
    $n = 0
    for ($d = $a; $d -le $b; $d = $d.AddDays(1)) { if (Test-WtAttWorkday $d $DayOff) { $n++ } }
    if ($script:halfTypes -contains $Entry.LeaveType) { $n * 0.5 } else { [double]$n }
}

<#
그 달 요약 (규칙 att-2). 계산할 수 있는 항목(State ok)만 쓴다. 저장하지 않고 열 때마다 계산한다.
  출근   WorkDays 출근한 날 수(같은 날 여러 번은 하루) · WorkMinutes 퇴근까지 적힌 근무 분 · WorkOpen 퇴근 기록 없는 출근 수
  업무외 시작한 날이 그 달인 기록. OverMinutes 분 합계 · OverCount 건수 · OverOpen 끝 시각 없는 건수(분에 넣지 않음)
  출장   그 달에 걸친 기록. TripCount 건수 · TripDays 일수($TripDays: all = 걸친 날 모두, workdays = 근무일만)
  휴가   LeaveDays: Get-WtLeaveDays 합계 (근무일 = 토 · 일 · 휴무일이 아닌 날)
         = LeaveFixed(사람이 정한 days, 확정) + LeaveEstimated(days가 null이라 지금 규칙 · 휴무일로 센 잠정 값)
  Skipped 계산에서 뺀 항목 수(읽기 전용 · 고칠 항목). other(기타)는 셈에 넣지 않는다
$DayOff: 휴무일 날짜 모음(yyyy-MM-dd). 주지 않으면 core\Calendar.psm1의 휴무일을 쓴다
#>
function Get-WtAttendanceSummary([datetime]$Month, [object[]]$Entries, $DayOff, [string]$TripDays) {
    $first = [datetime]::new($Month.Year, $Month.Month, 1)
    $last = $first.AddMonths(1).AddDays(-1)
    if ($null -eq $DayOff) { $DayOff = Get-WtHolidayDates $first $last }
    if (-not $TripDays) { $TripDays = [string](Get-WtSetting 'attendance.tripDays') }
    $r = [ordered]@{ Rule = $script:rule; Month = $first; WorkDays = 0; WorkMinutes = 0; WorkOpen = 0; OverMinutes = 0; OverCount = 0; OverOpen = 0
        TripCount = 0; TripDays = 0; LeaveDays = 0.0; LeaveFixed = 0.0; LeaveEstimated = 0.0; Skipped = 0 }
    $workDates = [System.Collections.Generic.HashSet[datetime]]::new()
    foreach ($e in @($Entries)) {
        if ($null -eq $e -or $e.State -eq 'deleted') { continue }
        if ($e.State -ne 'ok') { $r.Skipped++; continue }
        switch ($e.Kind) {
            'work' {
                if ($e.StartDate -lt $first -or $e.StartDate -gt $last) { break }
                [void]$workDates.Add($e.StartDate)
                if ($null -ne $e.Minutes) { $r.WorkMinutes += $e.Minutes } else { $r.WorkOpen++ }
            }
            'overtime' {
                if ($e.StartDate -lt $first -or $e.StartDate -gt $last) { break }
                $r.OverCount++
                if ($null -ne $e.Minutes) { $r.OverMinutes += $e.Minutes } else { $r.OverOpen++ }
            }
            'trip' {
                if ($e.EndDate -lt $first -or $e.StartDate -gt $last) { break }
                $r.TripCount++
                $a = if ($e.StartDate -lt $first) { $first } else { $e.StartDate }
                $b = if ($e.EndDate -gt $last) { $last } else { $e.EndDate }
                for ($d = $a; $d -le $b; $d = $d.AddDays(1)) { if ($TripDays -ne 'workdays' -or (Test-WtAttWorkday $d $DayOff)) { $r.TripDays++ } }
            }
            'leave' {
                if ($e.EndDate -lt $first -or $e.StartDate -gt $last) { break }
                $n = Get-WtLeaveDays $e $first $last $DayOff
                $r.LeaveDays += $n
                if ($null -ne $e.LeaveDays) { $r.LeaveFixed += $n } else { $r.LeaveEstimated += $n }
            }
        }
    }
    $r.WorkDays = $workDates.Count
    [pscustomobject]$r
}

# ---- 예전 데이터 ------------------------------------------------------------------------------

function ConvertFrom-WtAttPoint([string]$Date, [string]$Time) {
    $d = ConvertFrom-WtLegacyDate $Date
    $rawTime = $Time.Trim()
    $t = $null
    if ($rawTime) { $t = ConvertFrom-WtLegacyTime $rawTime; if (-not $t) { $t = $rawTime } }
    [ordered]@{ date = $(if ($d) { $d } else { $Date.Trim() }); time = $t }
}

<#
예전 WinForms attendance.csv 줄 하나 → schema 2 항목. 못 읽는 날짜 · 시각은 원래 글을 그 칸에 두어 「고칠 항목」이 되게 하고, 줄 전체는 origin.row에 남긴다.
  Type: 출근 → work, 업무외시간 근무 → overtime, 출장 → trip, 휴가 → leave, 모르는 글 → other(원래 글은 note 앞과 origin.row에)
  업무외시간 근무의 끝: EndTime ≤ StartTime이면 다음 날로 본다(예전 앱의 규칙. 가져올 때 한 번만 추측한다). EndTime이 없으면 end = null
  휴가 Detail: 연차 · 오전 반차 · 오후 반차 · 병가 · 경조사 · 대체 휴무 → 코드, 그 밖에 「반차」가 든 글 → half, 나머지 → other(글은 note에)
  휴가 days는 null(규칙대로 센다). 예전 앱의 규칙(주말 빼기, 반차 × 0.5)과 같은 값이 나온다
#>
function ConvertFrom-WtAttendanceRow($Row, [string]$At) {
    $id = ([string]$Row.Id).Trim()
    if (-not $id) {
        $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes((Get-WtRowKey $Row)))
        $id = 'csv-' + [Convert]::ToHexString($hash).Substring(0, 12).ToLowerInvariant()
    }
    $type = ([string]$Row.Type).Trim()
    $kind = $script:typeMap[$type]
    if (-not $kind) { $kind = 'other' }
    $detail = [string]$Row.Detail
    $start = ConvertFrom-WtAttPoint ([string]$Row.StartDate) ([string]$Row.StartTime)
    $endDateText = if (([string]$Row.EndDate).Trim()) { [string]$Row.EndDate } else { [string]$Row.StartDate }
    $item = [ordered]@{ id = $id; kind = $kind; start = $start; end = $null; place = [string]$Row.Place; note = $detail; tags = @(); rev = 0 }
    switch ($kind) {
        { $_ -in 'work', 'overtime' } {
            # 끝 날짜는 StartDate(예전 앱의 출근 · 업무외 EndDate는 늘 StartDate와 같다). EndTime ≤ StartTime이면 다음 날로 한 번만 추측한다.
            # 예전 앱의 출근에는 퇴근 시각이 없어서 보통 end = null이다(EndTime이 있으면 버리지 않고 퇴근으로 쓴다)
            if (([string]$Row.EndTime).Trim()) {
                $end = ConvertFrom-WtAttPoint ([string]$Row.StartDate) ([string]$Row.EndTime)
                $a = ConvertFrom-WtTimeText ([string]$start.time)
                $b = ConvertFrom-WtTimeText ([string]$end.time)
                $sd = ConvertFrom-WtDateText ([string]$start.date)
                if ($null -ne $a -and $null -ne $b -and $sd -and $b -le $a) { $end.date = ConvertTo-WtDateText $sd.AddDays(1) }
                $item.end = $end
            }
            if ($kind -eq 'overtime') { $item.overtime = [ordered]@{ how = $null; ref = '' } }
        }
        'leave' {
            $lt = $script:leaveMap[$detail.Trim()]
            if (-not $lt) { $lt = if ($detail -like '*반차*') { 'half' } else { 'other' } }
            $end = ConvertFrom-WtAttPoint $endDateText ''
            if ($end.date -ne $start.date) { $item.end = $end }
            $item.leave = [ordered]@{ type = $lt; days = $null }
            if ($script:leaveMap[$detail.Trim()]) { $item.note = '' }
        }
        default {
            # trip · other: 날짜 기간. other는 원래 종류 이름을 note 앞에 둔다
            $end = ConvertFrom-WtAttPoint $endDateText ([string]$Row.EndTime)
            if ($null -ne $start.time -and $null -eq $end.time) { $end = $null }
            elseif ($null -eq $start.time) { $end.time = $null }
            if ($end -and ($end.date -ne $start.date -or $end.time -ne $start.time)) { $item.end = $end }
            if ($kind -eq 'other' -and $type) { $item.note = if ($detail) { "${type}: $detail" } else { $type } }
        }
    }
    $item.created = $null; $item.updated = $At; $item.deleted = $null
    $item.origin = [ordered]@{ from = 'winforms-csv'; at = $At; rev = 0; row = $Row }
    [pscustomobject]$item
}

<#
schema 1(1단계 WPF) → 2. 1단계 WPF는 예전 CSV를 칸 이름만 바꿔 옮긴 것이라, 예전 CSV 줄로 되돌린 뒤 같은 길(ConvertFrom-WtAttendanceRow)로 바꾼다.
못 읽는 날짜 · 시각은 원래 글 그대로 「고칠 항목」이 된다. 옮기기 전 항목 전체는 origin.prev에 남기고, 모르는 칸도 옮긴다. null · 모양이 틀린 항목도 같은 자리에 둔다
#>
function Update-WtAttendanceSchema($Doc, [int]$From) {
    if ($From -ne 1) { throw "근태 schema $From에서 올리는 방법이 없습니다." }
    $at = Get-WtStamp
    $known = @('id', 'type', 'startDate', 'endDate', 'startTime', 'endTime', 'place', 'detail', 'updated')
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($old in @($Doc.items)) {
        if (-not (Test-WtAttObject $old)) { $list.Add($old); continue }
        $row = [pscustomobject][ordered]@{
            Id = [string]$old.id; Type = [string]$old.type; StartDate = [string]$old.startDate; EndDate = [string]$old.endDate
            StartTime = [string]$old.startTime; EndTime = [string]$old.endTime; Place = [string]$old.place; Detail = [string]$old.detail; Updated = [string]$old.updated
        }
        $new = ConvertFrom-WtAttendanceRow $row $at
        $new.origin['via'] = 'schema1'
        $new.origin['prev'] = Copy-WtItem $old
        foreach ($p in @($old.PSObject.Properties)) {
            if ($known -notcontains $p.Name -and -not $new.PSObject.Properties[$p.Name]) { Set-WtField $new $p.Name $p.Value }
        }
        $list.Add($new)
    }
    Set-WtField $Doc 'items' $list.ToArray()
    $Doc
}

# 예전 WinForms attendance.csv를 가져온다. 덮어쓰지 않고 합친다 (Import-WtScheduleLegacy와 같은 약속). 가져온 개수(더함 + 바꿈)를 돌려준다
function Import-WtAttendanceLegacy([string]$Folder) {
    $csv = Read-WtLegacyCsv $Folder 'attendance'
    if ($null -eq $csv) { return $null }
    $store = Open-WtAttendanceStore
    if ($store.State -eq 'error') { throw $store.Error }
    $at = Get-WtStamp
    $incoming = @(Copy-WtItem @(foreach ($r in $csv.Rows) { ConvertFrom-WtAttendanceRow $r $at }))
    $m = Merge-WtLegacyItems -Items $store.Items -Incoming $incoming -Owned $script:csvOwned
    $legacy = [ordered]@{ file = $csv.File; sha256 = $csv.Sha256; encoding = $csv.Encoding; rows = $csv.Rows.Count; at = $at }
    [void](Save-WtStore -Store $store -Items @(Compress-WtDeletedItems @($m.Items)) -Extra @{ importedFrom = $Folder; legacy = $legacy })
    $script:cache = $null
    $script:lastImport = $m
    $m.Added + $m.Updated
}

function Get-WtAttendanceLastImport { $script:lastImport }

Export-ModuleMember -Function Open-WtAttendanceStore, Save-WtAttendanceItems, Get-WtAttendanceData, ConvertFrom-WtAttendanceItem,
    Get-WtLeaveDays, Get-WtAttendanceSummary, ConvertFrom-WtAttendanceRow, Update-WtAttendanceSchema, Import-WtAttendanceLegacy, Get-WtAttendanceLastImport

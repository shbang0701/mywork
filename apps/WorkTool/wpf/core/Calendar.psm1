# 달력 공용 데이터. 탭 이름을 쓰지 않는다.
# 휴무일(공휴일 · 회사 휴무 · 개인 휴무)은 여러 탭이 같이 쓰는 날짜 데이터라 코어에 둔다(일정 달력 표시 · 근태 휴가 일수 계산).
# 탭끼리 서로 부르지 않으므로 탭은 이 모듈의 함수만 부른다. 그래서 어떤 탭을 빼도 휴무일과 다른 탭의 계산은 그대로다.
# 저장소 holidays.json (schema 1). 항목 하나 = 하루:
#   id, date("yyyy-MM-dd"), name, kind(public 공휴일 · company 회사 휴무 · personal 개인 휴무), note,
#   created, updated, deleted, origin({ from: "paste" · "manual", at } 등)
#   - 연휴는 날마다 한 항목. 같은 날에 여러 항목이 있어도 된다(계산에는 하루로 센다)
#   - 모르는 kind가 든 항목은 읽기 전용이고 계산에서 뺀다. 저장할 때는 그대로 둔다
#   - 날짜를 못 읽는 항목은 「고칠 항목」으로 두고 계산에서 뺀다. 나머지 항목은 그대로 쓴다
# 공휴일은 앱이 해마다 계산해 채운다(Update-WtAutoHolidays, 설정 holidays.auto). 외부에서 받아오지 않는다.
# 임시공휴일 · 선거일 · 회사 · 개인 휴무는 사람이 넣는다(설정 → 휴무일, 일정 달력 우클릭). 붙여 넣기도 그대로 쓸 수 있다.

$ErrorActionPreference = 'Stop'

$script:holidaySchema = 1
$script:holidayKinds = @('public', 'company', 'personal')
$script:holidayCache = $null
$script:calendarSources = [System.Collections.Generic.List[object]]::new()
Register-WtSettingDefault 'holidays.auto' $true   # 공휴일 자동 채우기

# 항목 하나를 계산용으로 읽는다. State: ok · readonly(새 버전 값) · broken(고칠 항목) · deleted
function ConvertFrom-WtHolidayItem($Item) {
    $e = [ordered]@{ Id = [string]$Item.id; Item = $Item; State = 'ok'; Problem = ''; Date = $null; DateText = [string]$Item.date
        Name = [string]$Item.name; Kind = [string]$Item.kind; Note = [string]$Item.note }
    if (Test-WtDeleted $Item) { $e.State = 'deleted'; return [pscustomobject]$e }
    $e.Date = ConvertFrom-WtDateText $e.DateText
    if (-not (Test-WtRecordObject $Item)) { $e.State = 'broken'; $e.Problem = '항목 모양이 틀렸습니다'; return [pscustomobject]$e }
    $common = Get-WtRecordProblem $Item
    if (-not $e.Id) { $e.State = 'broken'; $e.Problem = 'id가 없습니다' }
    elseif ($common) { $e.State = 'broken'; $e.Problem = $common }
    elseif ($script:holidayKinds -cnotcontains $e.Kind) { $e.State = 'readonly'; $e.Problem = "새 버전의 휴무 종류입니다: '$($e.Kind)'" }   # 모르는 값이 틀린 값보다 먼저
    elseif (-not $e.Date) { $e.State = 'broken'; $e.Problem = "날짜를 읽지 못했습니다: '$($e.DateText)'" }
    [pscustomobject]$e
}

<#
휴무일 저장소를 읽는다. 파일이 바뀌지 않았으면 앞서 읽은 것을 돌려준다.
@{ Store = 저장소 핸들(저장할 때 넘긴다); Items = 저장된 항목 그대로(null · 깨진 항목 포함, 저장할 때 이것을 고친다)
   Entries = 항목마다 ConvertFrom-WtHolidayItem; Error = 못 읽었으면 이유, 아니면 $null }
못 읽어도 예외를 올리지 않는다(부르는 탭의 화면 · 계산이 멈추지 않게). 그때 핸들은 저장을 거부한다
#>
function Get-WtHolidayData {
    $stamp = Get-WtStoreStamp 'holidays'
    if ($script:holidayCache -and $script:holidayCache.Stamp -ceq $stamp) { return $script:holidayCache }
    $store = Open-WtStore -Name 'holidays' -Schema $script:holidaySchema
    $err = $store.Error
    $items = $store.Items
    $entries = @(foreach ($i in $items) { ConvertFrom-WtHolidayItem $i })
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($e in $entries) {
        if (-not $e.Id) { continue }
        if (-not $seen.Add($e.Id) -and $e.State -ne 'deleted') { $e.State = 'broken'; $e.Problem = "id가 앞 항목과 겹칩니다: '$($e.Id)'" }
    }
    $script:holidayCache = [pscustomobject]@{ Stamp = $stamp; Store = $store; Items = $items; Entries = $entries; Error = $err }
    $script:holidayCache
}

# 계산에 쓰는 휴무일 날짜 모음 (yyyy-MM-dd, 읽을 수 있고 아는 종류만). -From · -To를 주면 그 사이(그날 포함)만
function Get-WtHolidayDates([Nullable[datetime]]$From, [Nullable[datetime]]$To) {
    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($e in (Get-WtHolidayData).Entries) {
        if ($e.State -ne 'ok') { continue }
        if ($null -ne $From -and $e.Date -lt ([datetime]$From).Date) { continue }
        if ($null -ne $To -and $e.Date -gt ([datetime]$To).Date) { continue }
        [void]$set.Add($e.DateText)
    }
    , $set
}

# 휴무일 항목을 저장한다 (2단계 화면이 쓴다). 읽은 핸들(Get-WtHolidayData의 Store)과 그 Items를 고친 목록을 넘긴다.
# 읽지 못한 파일 · 읽은 뒤 바뀐 파일에는 쓰지 않는다(Save-WtStore). 지운 지 오래된 항목은 { id, deleted }만 남긴다
function Save-WtHolidayItems($Store, [object[]]$Items) {
    [void](Save-WtStore -Store $Store -Items @(Compress-WtDeletedItems @($Items)))
    $script:holidayCache = $null
}

# 날짜 하나 · 종류 하나를 표시하거나 해제한다. 다른 종류는 남기고, 같은 종류의 중복은 모두 해제한다.
function Set-WtHolidayDate($Store, [string]$Date, [string]$Kind, [bool]$Enabled = $true, [string]$Name = '', [string]$Note = '', [string]$At = (Get-WtStamp)) {
    $reason = ''
    if ($Store.Name -cne 'holidays' -or -not (ConvertFrom-WtDateText $Date) -or $Kind -cnotin $script:holidayKinds -or -not (ConvertFrom-WtStamp $At)) {
        $reason = '휴무일 핸들 · 날짜 · 종류 · 앱 시각을 확인하세요'
    }
    if ($reason) { return [pscustomobject]@{ Success = $false; Reason = $reason; Store = $Store } }
    $edit = Get-WtRecordEdit $Store ''
    $matches = @($edit.Items | Where-Object { (ConvertFrom-WtHolidayItem $_).State -eq 'ok' -and $_.date -ceq $Date -and $_.kind -ceq $Kind })
    if ($Enabled) {
        if ($matches.Count) {
            foreach ($item in $matches) { Set-WtField $item 'name' $Name; Set-WtField $item 'note' $Note; Set-WtItemEdited $item $At }
        } else {
            $edit.Items += , [pscustomobject][ordered]@{ id = New-WtId; date = $Date; name = $Name; kind = $Kind; note = $Note; rev = 0
                created = $At; updated = $At; deleted = $null; origin = $null }
        }
    } else { foreach ($item in $matches) { [void](Set-WtRecordDeleted $item $true $At) } }
    $next = Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $At))
    $script:holidayCache = $null
    [pscustomobject]@{ Success = $true; Reason = ''; Store = $next }
}

# 1년치 붙여 넣기를 먼저 확인한다. 빈 줄은 무시, 같은 날짜 · 같은 이름은 하나, 이름이 다르면 줄 오류.
function ConvertFrom-WtHolidayPaste([string]$Text, [int]$Year) {
    $items = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $n = 0
    foreach ($line in ($Text -split '\r\n|\n|\r')) {
        $n++
        if (-not $line.Trim()) { continue }
        $reason = ''
        if ($Year -lt 1900 -or $Year -gt 2199) { $reason = '연도는 1900~2199로 적으세요' }
        elseif ($line -notmatch '^\s*([0-9]{4}-[0-9]{2}-[0-9]{2})[\t ]+(.+?)\s*$') { $reason = 'yyyy-MM-dd 이름 순서로 적으세요' }
        else {
            $dateText = $Matches[1]; $nameText = $Matches[2].Trim()
            $dateValue = ConvertFrom-WtDateText $dateText
            if (-not $dateValue) { $reason = '없는 날짜입니다' }
            elseif ($dateValue.Year -ne $Year) { $reason = '고른 해의 날짜가 아닙니다' }
            elseif (-not $nameText) { $reason = '공휴일 이름이 없습니다' }
            elseif ($seen.ContainsKey($dateText) -and $seen[$dateText] -cne $nameText) { $reason = '같은 날짜에 다른 이름이 있습니다' }
            elseif (-not $seen.ContainsKey($dateText)) {
                $seen[$dateText] = $nameText
                $items.Add([pscustomobject]@{ Date = $dateText; Name = $nameText })
            }
        }
        if ($reason) { $errors.Add([pscustomobject]@{ Line = $n; Text = $line; Reason = $reason }) }
    }
    if (-not $n -or $Year -lt 1900 -or $Year -gt 2199) {
        if (-not $errors.Count) { $errors.Add([pscustomobject]@{ Line = 0; Text = ''; Reason = '연도는 1900~2199로 적으세요' }) }
    }
    [pscustomobject]@{ Success = $errors.Count -eq 0; Reason = $(if ($errors.Count) { '잘못된 줄을 고친 뒤 다시 확인하세요' } else { '' })
        Items = $items.ToArray(); Errors = $errors.ToArray(); Year = $Year }
}

# 틀린 줄 · 빈 목록은 저장하지 않는다. 고른 해의 public만 맞추며 회사 · 개인 휴무와 모르는 항목은 그대로다.
function Import-WtHolidayPaste($Store, [string]$Text, [int]$Year, [string]$At = (Get-WtStamp)) {
    $parsed = ConvertFrom-WtHolidayPaste $Text $Year
    if ($Store.Name -cne 'holidays' -or -not (ConvertFrom-WtStamp $At)) { $parsed.Success = $false; $parsed.Reason = '휴무일 핸들 · 앱 시각을 확인하세요' }
    if (-not $parsed.Items.Count -and $parsed.Success) { $parsed.Success = $false; $parsed.Reason = '빈 목록으로 공휴일을 지우지 않습니다' }
    if (-not $parsed.Success) { return [pscustomobject]@{ Success = $false; Reason = $parsed.Reason; Errors = $parsed.Errors; Store = $Store } }
    $edit = Get-WtRecordEdit $Store ''
    $wanted = @{}
    foreach ($entry in $parsed.Items) { $wanted[$entry.Date] = $entry.Name }
    $kept = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $edit.Items) {
        $entry = ConvertFrom-WtHolidayItem $item
        if ($entry.State -ne 'ok' -or $entry.Kind -cne 'public' -or $entry.Date.Year -ne $Year) { continue }
        if ($wanted.ContainsKey($entry.DateText) -and $kept.Add($entry.DateText)) {
            Set-WtField $item 'name' $wanted[$entry.DateText]
            Set-WtItemEdited $item $At
        } else { [void](Set-WtRecordDeleted $item $true $At) }
    }
    foreach ($entry in $parsed.Items) {
        if (-not $kept.Add($entry.Date)) { continue }
        $edit.Items += , [pscustomobject][ordered]@{ id = New-WtId; date = $entry.Date; name = $entry.Name; kind = 'public'; note = ''; rev = 0
            created = $At; updated = $At; deleted = $null; origin = [pscustomobject]@{ from = 'paste'; at = $At } }
    }
    $next = Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $At))
    $script:holidayCache = $null
    [pscustomobject]@{ Success = $true; Reason = ''; Errors = @(); Store = $next }
}

# ---- 공휴일 자동 계산 -------------------------------------------------------------------------
# 인터넷 없이 .NET 한국 음력 달력(KoreanLunisolarCalendar)으로 설 · 추석 · 부처님오신날까지 계산한다(2000~2050년).
# 임시공휴일 · 선거일은 계산하지 않는다(사람이 넣는다). 대체공휴일(관공서의 공휴일에 관한 규정):
#   설 · 추석 연휴(3일): 2014년부터. 연휴의 일요일, 연휴와 겹친 다른 공휴일마다 연휴 다음 첫 평일
#   어린이날 2014년부터 · 삼일절 · 광복절 · 개천절 · 한글날 2021-08-15부터 · 부처님오신날 · 성탄절 2023-05-04부터:
#     토 · 일이나 다른 공휴일과 겹치면 다음 첫 평일. 한 날에 공휴일이 여럿 겹쳐도 대체공휴일은 하루다
#   신정 · 현충일은 대체공휴일이 없다. 「평일」은 토 · 일 · 공휴일 · 앞서 정한 대체공휴일이 아닌 날이다
$script:lunar = [System.Globalization.KoreanLunisolarCalendar]::new()
$script:substituteFrom = @{ lunar = [datetime]'2014-01-01'; child = [datetime]'2014-01-01'; national = [datetime]'2021-08-15'; late = [datetime]'2023-05-04' }

# 음력 날짜 → 양력. 윤달이 있는 해는 윤달부터 달 번호가 하나 밀린다(GetLeapMonth가 그 번호, 0이면 윤달 없음)
function ConvertFrom-WtLunarDate([int]$Year, [int]$Month, [int]$Day) {
    $leap = $script:lunar.GetLeapMonth($Year)
    $index = if ($leap -gt 0 -and $Month -ge $leap) { $Month + 1 } else { $Month }
    $script:lunar.ToDateTime($Year, $index, $Day, 0, 0, 0, 0).Date
}

# 그해 공휴일(대체공휴일 포함), 날짜순. 항목: Date · DateText · Name. 계산할 수 없는 해(2000년 앞 · 2050년 뒤)는 빈 목록
function Get-WtKoreanHolidays([int]$Year) {
    if ($Year -lt 2000 -or $Year -gt 2050) { return @() }
    $base = [System.Collections.Generic.List[object]]::new()
    foreach ($f in @(@(1, 1, '신정', ''), @(3, 1, '삼일절', 'national'), @(5, 5, '어린이날', 'child'), @(6, 6, '현충일', ''),
            @(8, 15, '광복절', 'national'), @(10, 3, '개천절', 'national'), @(10, 9, '한글날', 'national'), @(12, 25, '성탄절', 'late'))) {
        $base.Add([pscustomobject]@{ Date = [datetime]::new($Year, $f[0], $f[1]); Name = $f[2]; Rule = $f[3]; Group = $f[2]; End = $null })
    }
    $base.Add([pscustomobject]@{ Date = (ConvertFrom-WtLunarDate $Year 4 8); Name = '부처님오신날'; Rule = 'late'; Group = '부처님오신날'; End = $null })
    foreach ($p in @(@(1, 1, '설날'), @(8, 15, '추석'))) {
        $day = ConvertFrom-WtLunarDate $Year $p[0] $p[1]
        foreach ($k in -1, 0, 1) {
            $base.Add([pscustomobject]@{ Date = $day.AddDays($k); Name = $(if ($k) { "$($p[2]) 연휴" } else { $p[2] }); Rule = 'lunar'; Group = $p[2]; End = $day.AddDays(1) })
        }
    }
    $taken = [System.Collections.Generic.HashSet[datetime]]::new()
    foreach ($b in $base) { [void]$taken.Add($b.Date) }
    # 대체공휴일이 필요한 날: (찾기 시작할 날, 붙일 이름). 한 날짜에서 하나, 연휴는 그 일요일 · 겹친 날마다 하나
    $needs = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($base | Group-Object { $_.Date.Ticks } | Sort-Object { [long]$_.Name })) {
        $here = @($group.Group)
        $date = $here[0].Date
        $eligible = @($here | Where-Object { $_.Rule -and $date -ge $script:substituteFrom[$_.Rule] })
        if (-not $eligible.Count) { continue }
        $overlap = @($here | ForEach-Object Group | Select-Object -Unique).Count -ge 2
        $weekend = @($eligible | Where-Object { $date.DayOfWeek -eq 'Sunday' -or ($_.Rule -ne 'lunar' -and $date.DayOfWeek -eq 'Saturday') }).Count -gt 0
        if (-not $overlap -and -not $weekend) { continue }
        $anchor = $date
        foreach ($e in $eligible) { if ($e.End -and $e.End -gt $anchor) { $anchor = $e.End } }
        $needs.Add([pscustomobject]@{ Anchor = $anchor; Name = (@($eligible | ForEach-Object Group | Select-Object -Unique) -join ' · ') })
    }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $base) { $result.Add([pscustomobject]@{ Date = $b.Date; DateText = (ConvertTo-WtDateText $b.Date); Name = $b.Name }) }
    foreach ($n in @($needs | Sort-Object Anchor)) {
        $d = $n.Anchor.AddDays(1)
        while ($d.DayOfWeek -eq 'Saturday' -or $d.DayOfWeek -eq 'Sunday' -or $taken.Contains($d)) { $d = $d.AddDays(1) }
        [void]$taken.Add($d)
        $result.Add([pscustomobject]@{ Date = $d; DateText = (ConvertTo-WtDateText $d); Name = "대체공휴일 ($($n.Name))" })
    }
    @($result | Sort-Object Date, Name)
}

<#
자동 공휴일을 holidays.json에 채운다(공휴일 · origin.from = auto). 해마다 한 번만 채우고, 채운 해를 맨 위 autoYears에 적는다.
그래서 사람이 지운 날은 되살아나지 않고, 고친 이름도 그대로다. 그날 이미 공휴일이 있으면(붙여 넣기 · 직접) 더하지 않는다.
-Force(설정의 「다시 계산」)는 그 해의 자동 항목을 계산 결과로 다시 맞춘다(지운 자동 항목은 되살리고, 계산에 없는 자동 항목은 지운다).
설정 holidays.auto가 꺼져 있으면 아무것도 하지 않는다(-Force는 끈 상태에서도 쓴다).
돌려주는 값: Success · Reason · Added(더한 수) · Store
#>
function Update-WtAutoHolidays([int[]]$Years, [string]$At = (Get-WtStamp), [switch]$Force) {
    $data = Get-WtHolidayData
    $fail = [pscustomobject]@{ Success = $false; Reason = ''; Added = 0; Store = $data.Store }
    if ($data.Error) { $fail.Reason = $data.Error; return $fail }
    if (-not (ConvertFrom-WtStamp $At)) { $fail.Reason = '앱 시각을 확인하세요'; return $fail }
    if (-not $Force -and -not [bool](Get-WtSetting 'holidays.auto')) { return [pscustomobject]@{ Success = $true; Reason = ''; Added = 0; Store = $data.Store } }
    $doneYears = [System.Collections.Generic.SortedSet[int]]::new()
    $saved = if ($data.Store.Doc) { $data.Store.Doc.PSObject.Properties['autoYears'] } else { $null }
    if ($saved) { foreach ($y in @($saved.Value)) { $n = 0; if ([int]::TryParse([string]$y, [ref]$n)) { [void]$doneYears.Add($n) } } }
    $todo = @($Years | Where-Object { $_ -ge 2000 -and $_ -le 2050 -and ($Force -or -not $doneYears.Contains($_)) } | Select-Object -Unique)
    if (-not $todo.Count) { return [pscustomobject]@{ Success = $true; Reason = ''; Added = 0; Store = $data.Store } }
    $edit = Get-WtRecordEdit $data.Store ''
    $added = 0
    foreach ($year in $todo) {
        $want = @{}
        foreach ($h in (Get-WtKoreanHolidays $year)) { if (-not $want.ContainsKey($h.DateText)) { $want[$h.DateText] = $h.Name } }
        $public = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($item in $edit.Items) {
            $entry = ConvertFrom-WtHolidayItem $item
            if ($entry.State -ne 'ok' -or $entry.Date.Year -ne $year -or $entry.Kind -cne 'public') { continue }
            $origin = Get-WtField $item 'origin'
            $from = if (Test-WtRecordObject $origin) { [string](Get-WtField $origin 'from') } else { '' }
            if ($Force -and $from -ceq 'auto' -and -not $want.ContainsKey($entry.DateText)) { [void](Set-WtRecordDeleted $item $true $At); continue }
            [void]$public.Add($entry.DateText)
        }
        foreach ($dateText in @($want.Keys | Sort-Object)) {
            if (-not $public.Add($dateText)) { continue }
            $edit.Items += , [pscustomobject][ordered]@{ id = New-WtId; date = $dateText; name = $want[$dateText]; kind = 'public'; note = ''; rev = 0
                created = $At; updated = $At; deleted = $null; origin = [pscustomobject]@{ from = 'auto'; at = $At } }
            $added++
        }
        [void]$doneYears.Add($year)
    }
    $next = Save-WtStore $data.Store @(Compress-WtDeletedItems $edit.Items -Now (ConvertFrom-WtStamp $At)) -Extra @{ autoYears = @($doneYears) }
    $script:holidayCache = $null
    [pscustomobject]@{ Success = $true; Reason = ''; Added = $added; Store = $next }
}

function Get-WtHolidayCalendarItems([datetime]$From, [datetime]$To) {
    $data = Get-WtHolidayData
    if ($data.Error) { throw $data.Error }
    foreach ($entry in $data.Entries) {
        if ($entry.State -ne 'ok' -or $entry.Date -lt $From.Date -or $entry.Date -gt $To.Date) { continue }
        [pscustomobject]@{ Date = $entry.Date; Kind = $entry.Kind; Text = $entry.Name; Style = 'Sub'; AllDay = $true; Time = $null; Id = $entry.Id; Page = '' }
    }
}

# 코어 · 탭의 공용 달력 출처. null이면 해제, 같은 Id는 바꿔 끼운다.
function Register-WtCalendarSource([string]$Id, [scriptblock]$CalendarItems, [string]$Page = '') {
    if (-not $Id) { throw '달력 출처 id가 필요합니다.' }
    for ($i = $script:calendarSources.Count - 1; $i -ge 0; $i--) {
        if ($script:calendarSources[$i].Id -ceq $Id) { $script:calendarSources.RemoveAt($i) }
    }
    if ($null -ne $CalendarItems) { $script:calendarSources.Add([pscustomobject]@{ Id = $Id; Page = $Page; CalendarItems = $CalendarItems }) }
}

function Get-WtCalendarSource { $script:calendarSources.ToArray() }

Register-WtCalendarSource -Id 'holidays' -CalendarItems { param([datetime]$From, [datetime]$To) Get-WtHolidayCalendarItems $From $To }

Export-ModuleMember -Function ConvertFrom-WtHolidayItem, Get-WtHolidayData, Get-WtHolidayDates, Save-WtHolidayItems,
    Set-WtHolidayDate, ConvertFrom-WtHolidayPaste, Import-WtHolidayPaste, Get-WtHolidayCalendarItems, Register-WtCalendarSource, Get-WtCalendarSource,
    ConvertFrom-WtLunarDate, Get-WtKoreanHolidays, Update-WtAutoHolidays

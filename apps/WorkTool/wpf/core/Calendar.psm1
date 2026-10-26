# 달력 공용 데이터. 탭 이름을 쓰지 않는다.
# 휴무일(공휴일 · 회사 휴무 · 개인 휴무)은 여러 탭이 같이 쓰는 날짜 데이터라 코어에 둔다(일정 달력 표시 · 근태 휴가 일수 계산).
# 탭끼리 서로 부르지 않으므로 탭은 이 모듈의 함수만 부른다. 그래서 어떤 탭을 빼도 휴무일과 다른 탭의 계산은 그대로다.
# 저장소 holidays.json (schema 1). 항목 하나 = 하루:
#   id, date("yyyy-MM-dd"), name, kind(public 공휴일 · company 회사 휴무 · personal 개인 휴무), note,
#   created, updated, deleted, origin({ from: "paste" · "manual", at } 등)
#   - 연휴는 날마다 한 항목. 같은 날에 여러 항목이 있어도 된다(계산에는 하루로 센다)
#   - 모르는 kind가 든 항목은 읽기 전용이고 계산에서 뺀다. 저장할 때는 그대로 둔다
#   - 날짜를 못 읽는 항목은 「고칠 항목」으로 두고 계산에서 뺀다. 나머지 항목은 그대로 쓴다
# 공휴일 목록은 사람이 1년에 한 번 붙여 넣는다(외부에서 받아오지 않는다). 붙여 넣기 · 편집 화면과 달력 표시 등록은 2단계에서 더한다.

$ErrorActionPreference = 'Stop'

$script:holidaySchema = 1
$script:holidayKinds = @('public', 'company', 'personal')
$script:holidayCache = $null
$script:calendarSources = [System.Collections.Generic.List[object]]::new()

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
    Set-WtHolidayDate, ConvertFrom-WtHolidayPaste, Import-WtHolidayPaste, Get-WtHolidayCalendarItems, Register-WtCalendarSource, Get-WtCalendarSource

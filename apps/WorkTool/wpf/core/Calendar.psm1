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
    Save-WtStore -Store $Store -Items @(Compress-WtDeletedItems @($Items))
    $script:holidayCache = $null
}

Export-ModuleMember -Function ConvertFrom-WtHolidayItem, Get-WtHolidayData, Get-WtHolidayDates, Save-WtHolidayItems

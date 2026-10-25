# 기록 형식의 공통 틀. 어느 탭에나 같은 모양 · 규칙만 두고, 칸의 뜻은 탭이 정한다. 디스크에 닿지 않는다(저장은 Storage.psm1).
# 규칙 전체는 docs/plans/schedule-attendance-design.md 「공통 규칙」.
# - 날짜 · 시각은 세 모양만 쓴다
#     날짜만            "2026-10-28"                      시간대 없음 (하루 종일 · 휴가 날짜 · 휴무일)
#     사람이 정한 시각  { "date": "2026-10-28", "time": "22:00" }   24시간 HH:mm, 현지 벽시계, 시간대 없음. time이 null이면 시각 없음
#     앱이 찍는 시각    "2026-10-25T21:54:29+09:00"       created · updated · deleted · saved. 시간대 포함 (Get-WtStamp)
# - 글을 만들고 읽는 것은 문화권(ko-KR · en-US …)과 상관없이 같다 (InvariantCulture, 그레고리력)
# - 지운 기록은 deleted에 찍는 시각을 넣어 표시만 한다. 오래되면 내용을 비우고 { id, deleted }만 남긴다 (Compress-WtDeletedItems)
# - 날짜는 1900-01-01 ~ 2199-12-31만 받는다(계산이 넘치지 않게). 숫자 칸은 정한 범위의 정수만 받는다(ConvertFrom-WtWhole)
# - 예전(WinForms) CSV는 너그럽게 읽는다: Excel이 바꾼 2026/10/1 · 2026. 10. 1. · 9:30 · 오후 2:30 등 (ConvertFrom-WtLegacy*)
# - 가져온 기록은 origin = { from, at, rev, row }에 원본 줄을 통째로 남기고, 다시 가져올 때는 덮어쓰지 않고 합친다 (Merge-WtLegacyItems)
# - 사람이 고친 횟수는 rev(0부터, 고칠 때마다 +1, Set-WtItemEdited)로 센다. 「이 앱에서 고쳤는지」는 시각이 아니라 rev로 정한다
# - id는 글 그대로 비교한다(대소문자를 가린다, StringComparer.Ordinal). s1과 S1은 다른 항목이다

$ErrorActionPreference = 'Stop'

$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:ko = [System.Globalization.CultureInfo]::GetCultureInfo('ko-KR')
$script:stampFormat = "yyyy-MM-dd'T'HH:mm:sszzz"
$script:minYear = 1900
$script:maxYear = 2199
$script:legacyDates = [string[]]@('yyyy-M-d', 'yyyy/M/d', 'yyyy.M.d', 'yyyy. M. d', 'yyyyMMdd', 'M/d/yyyy')
$script:legacyTimes = [string[]]@('H:mm', 'H:mm:ss', 'h:mm tt', 'h:mm:ss tt')
$script:legacyTimesKo = [string[]]@('tt h:mm', 'tt h:mm:ss')
$script:legacyStamps = [string[]]@('yyyy-M-d H:mm:ss', 'yyyy-M-d H:mm', 'yyyy/M/d H:mm:ss', 'yyyy/M/d H:mm', 'yyyy. M. d H:mm:ss', 'yyyy. M. d H:mm',
    "yyyy-MM-dd'T'HH:mm:ss", 'M/d/yyyy H:mm:ss', 'M/d/yyyy H:mm', 'M/d/yyyy h:mm:ss tt', 'M/d/yyyy h:mm tt')
$script:legacyStampsKo = [string[]]@('yyyy-M-d tt h:mm:ss', 'yyyy-M-d tt h:mm', 'yyyy. M. d tt h:mm:ss', 'yyyy. M. d tt h:mm')

# ---- 날짜 · 시각 ------------------------------------------------------------------------------

# 앱이 찍는 시각: "2026-10-25T21:54:29+09:00". -At이 없으면 지금. [datetime]은 이 PC의 시간대로 본다
function Get-WtStamp($At) {
    $t = if ($null -eq $At) { [DateTimeOffset]::Now } elseif ($At -is [DateTimeOffset]) { $At } else { [DateTimeOffset]::new([datetime]$At) }
    $t.ToString($script:stampFormat, $script:inv)
}

# 앱이 찍은 시각 → [DateTimeOffset]. 모양이 다르면 $null
function ConvertFrom-WtStamp([string]$Text) {
    $r = [DateTimeOffset]::MinValue
    if ($Text -and [DateTimeOffset]::TryParseExact($Text, $script:stampFormat, $script:inv, [System.Globalization.DateTimeStyles]::None, [ref]$r)) { return $r }
    $null
}

# 날짜 글 "yyyy-MM-dd" → [datetime](그날 0시). 모양이 다르거나, 없는 날이거나, 1900~2199년 밖이면 $null
function ConvertFrom-WtDateText([string]$Text) {
    $d = [datetime]::MinValue
    if ($Text -and [datetime]::TryParseExact($Text, 'yyyy-MM-dd', $script:inv, [System.Globalization.DateTimeStyles]::None, [ref]$d) -and
        $d.Year -ge $script:minYear -and $d.Year -le $script:maxYear) { return $d }
    $null
}

<#
숫자 칸 하나를 정수로 읽는다. 정수이고 $Min ~ $Max 안이면 [long], 아니면 $null (글 · 참거짓 · 소수 · 범위 밖 · 아주 큰 수 모두 $null).
JSON 숫자는 크기에 따라 Int64 · Double · BigInteger로 들어오므로 모두 여기서 한 번에 본다. 범위는 형식마다 정하고 설계 문서에 적는다
#>
function ConvertFrom-WtWhole($Value, [long]$Min, [long]$Max) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or $Value -is [char]) { return $null }
    # 정수인지는 받은 형식 그대로 본다. Decimal로 먼저 바꾸면 1e-30이 0, 1.0000000000000002가 1이 되어 정수로 잘못 통과한다
    if ($Value -is [int] -or $Value -is [long]) { $w = [long]$Value }
    elseif ($Value -is [double]) {
        if (-not [double]::IsFinite($Value) -or [Math]::Truncate($Value) -ne $Value) { return $null }
        # 큰 Double도 반올림 없이 옮기고, Int64 밖이면 변환 전에 거부한다
        $whole = [System.Numerics.BigInteger]$Value
        if ($whole -lt [long]::MinValue -or $whole -gt [long]::MaxValue) { return $null }
        $w = [long]$whole
    }
    elseif ($Value -is [decimal]) {
        if ([Math]::Truncate($Value) -ne $Value -or $Value -lt [long]::MinValue -or $Value -gt [long]::MaxValue) { return $null }
        $w = [long]$Value
    }
    elseif ($Value -is [System.Numerics.BigInteger]) {
        if ($Value -lt [long]::MinValue -or $Value -gt [long]::MaxValue) { return $null }
        $w = [long]$Value
    }
    else { return $null }
    if ($w -lt $Min -or $w -gt $Max) { return $null }
    $w
}

# 숫자 칸 하나를 수로 읽는다(소수 됨). $Min ~ $Max 안의 유한한 수면 [double], 아니면 $null
function ConvertFrom-WtNumber($Value, [double]$Min, [double]$Max) {
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string] -or $Value -is [char]) { return $null }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double])) { return $null }
    $v = [double]$Value
    if (-not [double]::IsFinite($v) -or $v -lt $Min -or $v -gt $Max) { return $null }
    $v
}

function ConvertTo-WtDateText([datetime]$Date) { $Date.ToString('yyyy-MM-dd', $script:inv) }

# 시각 글 "HH:mm"(00:00~23:59) → [timespan]. 모양이 다르면 $null
function ConvertFrom-WtTimeText([string]$Text) {
    if ($Text -cnotmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') { return $null }
    [timespan]::new([int]$Text.Substring(0, 2), [int]$Text.Substring(3, 2), 0)
}

# ---- 예전(WinForms) CSV 값 --------------------------------------------------------------------
# Excel에서 열었다 저장하면 2026-10-01 → 2026/10/1, 09:30 → 9:30처럼 바뀔 수 있다. 읽을 수 있으면 정한 모양으로, 없으면 $null

function ConvertFrom-WtLegacyDate([string]$Text) {
    $t = "$Text".Trim().TrimEnd('.').Trim()
    if (-not $t) { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($t, $script:legacyDates, $script:inv, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$d)) { return ConvertTo-WtDateText $d }
    $null
}

function ConvertFrom-WtLegacyTime([string]$Text) {
    $t = "$Text".Trim()
    if (-not $t) { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($t, $script:legacyTimes, $script:inv, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$d) -or
        [datetime]::TryParseExact($t, $script:legacyTimesKo, $script:ko, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$d)) {
        return $d.ToString('HH:mm', $script:inv)
    }
    $null
}

# 예전 고친 시각(시간대 없음, 예: 2026-10-25 21:54:29) → 앱이 찍는 시각. 시간대는 가져오는 PC의 것을 붙인다
function ConvertFrom-WtLegacyStamp([string]$Text) {
    $t = "$Text".Trim()
    if (-not $t) { return $null }
    if (ConvertFrom-WtStamp $t) { return $t }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($t, $script:legacyStamps, $script:inv, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$d) -or
        [datetime]::TryParseExact($t, $script:legacyStampsKo, $script:ko, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$d)) {
        return Get-WtStamp $d
    }
    $null
}

# ---- 항목 다루기 ------------------------------------------------------------------------------

# 칸 하나의 값. 없으면 $null. $obj.count처럼 쓰면 칸이 없을 때 PowerShell이 붙인 Count(1)가 나오므로 이 함수로 읽는다.
# 목록 값은 펴지 않고 그대로 돌려준다(항목 하나짜리 목록 · 빈 목록도 목록으로)
function Get-WtField($Object, [string]$Name) {
    if ($null -eq $Object -or $Object -is [string] -or $Object -is [ValueType]) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return , $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { , $p.Value } else { $null }
}

# 칸 하나를 넣는다. 있으면 값만 바꾸고, 없으면 더한다 (읽은 객체를 그대로 두고 아는 칸만 고치기 위해)
function Set-WtField($Object, [string]$Name, $Value) {
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value; return }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

# 깊은 복사. JSON으로 한 번 오가므로 저장 파일에서 읽은 것과 같은 모양(PSCustomObject · 문자열 날짜)이 된다.
# 배열을 주면 복사한 항목을 하나씩 내보낸다(부르는 쪽에서 @()로 받는다)
function Copy-WtItem($Value) {
    if ($null -eq $Value) { return $null }
    $copy = ConvertTo-Json -InputObject $Value -Depth 20 -Compress | ConvertFrom-Json -Depth 20 -DateKind String -NoEnumerate
    $copy
}

# 저장 파일에서 읽은 객체(또는 해시 테이블)인지. null · 글 · 숫자 · 배열이 아니다
function Test-WtRecordObject($Value) { $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [ValueType] -and $Value -isnot [array] }

# 지운 표시가 있는지. deleted가 null · '' · false가 아니면 지운 것이다
function Test-WtDeleted($Item) {
    if (-not (Test-WtRecordObject $Item)) { return $false }
    $v = Get-WtField $Item 'deleted'
    if ($null -eq $v -or ($v -is [bool] -and -not $v)) { return $false }
    "$v" -ne ''
}

# 사람이 고친 횟수 rev. 없으면 0, 0 이상의 정수가 아니면 -1(알 수 없음: 합칠 때 「고쳤음」으로 본다)
function Get-WtItemRevision($Item) {
    if (-not (Test-WtRecordObject $Item)) { return 0 }
    $hasRev = if ($Item -is [System.Collections.IDictionary]) { $Item.Contains('rev') } else { $null -ne $Item.PSObject.Properties['rev'] }
    if (-not $hasRev) { return 0 }
    $v = Get-WtField $Item 'rev'
    $w = ConvertFrom-WtWhole $v 0 2147483647
    if ($null -eq $w) { -1 } else { [int]$w }
}

# 사람이 이 항목을 고쳤다고 적는다: rev + 1, updated = 지금. 편집 · 지우기 · 되살리기는 모두 이 함수를 거친다
# (같은 초에 고쳐도 rev가 달라지므로, 다시 가져오기가 고친 내용을 덮지 않는다)
function Set-WtItemEdited($Item, $At) {
    $rev = Get-WtItemRevision $Item
    Set-WtField $Item 'rev' ([Math]::Max(0, $rev) + 1)
    Set-WtField $Item 'updated' $(if ($null -eq $At) { Get-WtStamp } else { [string]$At })
}

# 공통 틀이 아는 문제(어느 탭에나 같다). 없으면 ''. 지금은 예전 데이터 안에서 id가 겹쳐 따로 남긴 줄(origin.dupOf)
function Get-WtRecordProblem($Item) {
    if (-not (Test-WtRecordObject $Item)) { return '' }
    $dup = Get-WtField (Get-WtField $Item 'origin') 'dupOf'
    if ($null -ne $dup -and "$dup" -ne '') { return "예전 데이터에서 id가 앞 줄과 겹쳐 따로 남긴 줄입니다 (원래 id '$dup')" }
    ''
}

# 지운 지 $Days일이 지난 항목은 내용을 비우고 { id, deleted }만 남긴다. id를 남겨야 다시 가져오기 · 합치기에서 되살아나지 않는다.
# 지운 시각을 읽을 수 없으면 그대로 둔다. 나머지 항목(null · 깨진 항목 포함)은 그대로 같은 자리에 돌려준다
function Compress-WtDeletedItems([object[]]$Items, [int]$Days = 90, $Now) {
    $limit = $(if ($null -eq $Now) { [DateTimeOffset]::Now } else { [DateTimeOffset]$Now }).AddDays(-$Days)
    foreach ($i in $Items) {
        if ((Test-WtDeleted $i) -and @($i.PSObject.Properties).Count -gt 2) {
            $at = ConvertFrom-WtStamp ([string](Get-WtField $i 'deleted'))
            if ($at -and $at -lt $limit) { [pscustomobject][ordered]@{ id = $i.id; deleted = $i.deleted }; continue }
        }
        , $i   # 깨진 항목이 목록(배열)이어도 펴지 않고 한 항목으로 내보낸다 (빈 배열 · null도 그 자리에)
    }
}

# 줄 하나(CSV 줄 · 객체)를 비교용 글 하나로. 칸 이름 순서와 상관없이 같은 내용이면 같은 글이다
function Get-WtRowKey($Row) {
    if ($null -eq $Row) { return '' }
    $pairs = if ($Row -is [System.Collections.IDictionary]) {
        foreach ($k in $Row.Keys) { "$k=$([string]$Row[$k])" }
    } else {
        foreach ($p in $Row.PSObject.Properties) { "$($p.Name)=$([string]$p.Value)" }
    }
    $list = [string[]]@($pairs)
    [Array]::Sort($list, [StringComparer]::Ordinal)
    $list -join [char]0x1F
}

# 두 줄(CSV 줄)에서 값이 다른 칸 이름들. 한쪽에만 있는 칸도 다르다고 본다
function Get-WtChangedColumns($Old, $New) {
    $a = @{}; $b = @{}
    foreach ($p in @($(if ($null -ne $Old) { $Old.PSObject.Properties }))) { $a[$p.Name] = [string]$p.Value }
    foreach ($p in @($(if ($null -ne $New) { $New.PSObject.Properties }))) { $b[$p.Name] = [string]$p.Value }
    $names = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($k in @($a.Keys) + @($b.Keys)) { [void]$names.Add($k) }
    foreach ($k in $names) { if (-not $a.ContainsKey($k) -or -not $b.ContainsKey($k) -or $a[$k] -cne $b[$k]) { $k } }
}

<#
칸 경로 하나("start.date" 처럼 점으로 잇는다)의 값을 $Source에서 $Target으로 옮긴다. 그 경로 밖의 칸은 건드리지 않는다.
가는 길의 앞부분이 한쪽에서 null(없음)이면 그 앞부분을 통째로 맞춘다 (예: 예전 데이터에서 반복이 없어지면 repeat = null).
목록 칸은 원소 번호로 적는다("alarms[0].before" = 첫 원소의 before만). 그 원소의 다른 칸과 다른 원소는 건드리지 않는다.
  $Source에 그 원소가 있고 $Target에 없으면 그 원소를 목록 그 자리에 끼워 넣는다(뒤 원소는 그대로 뒤로).
  $Source에 그 원소가 없으면 $Target 원소의 그 칸만 null로 둔다(원소와 그 확장 칸은 남는다).
$Source에 그 칸이 없고 $Target에도 없으면 아무것도 하지 않는다
#>
function Copy-WtPathValue($Target, $Source, [string]$Path) {
    $parts = $Path.Split('.')
    $t = $Target; $s = $Source
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $m = [regex]::Match($parts[$i], '^([^\[\]]+)\[(\d+)\]$')
        if ($m.Success) {
            $name = $m.Groups[1].Value; $at = [int]$m.Groups[2].Value
            # Get-WtField는 목록을 한 덩어리로 돌려주므로 변수에 받은 뒤 @()로 본다 (@(Get-WtField …)는 목록을 한 겹 더 싼다)
            $sRaw = Get-WtField $s $name; $tRaw = Get-WtField $t $name
            $sl = @($sRaw); $tl = @($tRaw)
            $se = $null; $te = $null
            if ($null -ne $sRaw -and $at -lt $sl.Count) { $se = $sl[$at] }
            if ($null -ne $tRaw -and $at -lt $tl.Count) { $te = $tl[$at] }
            if ((Test-WtRecordObject $te)) { $t = $te; $s = $se; continue }
            if ($null -eq $se) { return }
            $list = [System.Collections.Generic.List[object]]::new()
            if ($null -ne $tRaw) { foreach ($x in $tl) { $list.Add($x) } }
            $list.Insert([Math]::Min($at, $list.Count), $se)
            Set-WtField $t $name $list.ToArray()
            return
        }
        $sv = Get-WtField $s $parts[$i]
        $tv = Get-WtField $t $parts[$i]
        if ($null -eq $sv -or -not (Test-WtRecordObject $tv)) {
            if ($null -ne $sv -or $null -ne $tv) { Set-WtField $t $parts[$i] $sv }
            return
        }
        $t = $tv; $s = $sv
    }
    $leaf = $parts[$parts.Count - 1]
    $sv = Get-WtField $s $leaf
    if ($null -eq $sv -and $null -eq (Get-WtField $t $leaf) -and -not ($t.PSObject.Properties[$leaf])) { return }
    Set-WtField $t $leaf $sv
}

<#
예전 앱에서 가져온 항목을 지금 항목에 합친다. 덮어쓰지 않는다.
  $Items    지금 저장된 항목 (저장 파일에서 읽은 그대로. null · 깨진 항목도 같은 자리에 그대로 남는다)
  $Incoming 예전 데이터를 지금 형식으로 바꾼 항목. 저마다 origin = { from = $From; at; rev; row }가 있다
  $Owned    예전 데이터의 칸 하나가 정하는 항목 칸 경로들 @{ 'Title' = @('title'); 'Date' = @('start.date', …) } (탭이 정한다)
id는 글 그대로(대소문자를 가려서) 짝짓는다. 규칙
  - 새 id → 더한다
  - 지금 쪽에서 지운 항목 → 되살리지 않는다
  - 예전 줄이 그대로 → 그대로 둔다
  - 예전 줄이 바뀌었고 지금 쪽에서 고치지 않았다(rev = origin.rev) → 바뀐 예전 칸이 정하는 경로만 기존 객체에 옮긴다.
    그 밖의 칸(이 앱 · 더 새 앱이 더한 칸, 중첩 칸 포함)은 그대로다. origin.row · origin.at · updated를 새 값으로
  - 예전 줄이 바뀌었고 지금 쪽에서도 고쳤다(rev ≠ origin.rev) → 지금 값을 두고 Conflicts에 적는다
  - 지금 쪽에서 만든 항목(origin.from이 다름)과 id가 겹침 → 지금 값을 두고 Conflicts에 적는다
  - 예전 데이터 안에서 id가 겹친 뒤 줄 → 처음 줄과 내용까지 같으면 하나로 친다(dup을 만들지 않는다). 내용이 다르면 버리지 않는다:
    id를 'dup-' + 줄 내용 해시로 바꾸고 origin.dupOf에 원래 id를 적어 따로 남긴다(탭이 「고칠 항목」으로 보여 준다, Get-WtRecordProblem).
    그런 줄끼리 내용까지 같으면 하나만 남는다
  - rev · origin.rev 중 하나라도 0 이상 정수가 아니면 「고쳤음」으로 본다
  - 예전 데이터에서 없어진 항목 → 지우지 않고 Missing에 적기만 한다
#>
function Merge-WtLegacyItems([object[]]$Items, [object[]]$Incoming, [hashtable]$Owned, [string]$From = 'winforms-csv') {
    if ($null -eq $Owned) { throw 'Merge-WtLegacyItems: 예전 칸 → 항목 칸 지도(-Owned)가 필요합니다.' }
    $merged = [System.Collections.Generic.List[object]]::new()
    $index = [System.Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
    foreach ($i in @($Items)) {
        $merged.Add($i)
        if (-not (Test-WtRecordObject $i)) { continue }
        $k = [string]$i.id
        if ($k -and -not $index.ContainsKey($k)) { $index[$k] = $merged.Count - 1 }
    }
    $r = [ordered]@{ Added = 0; Updated = 0; Unchanged = 0; KeptDeleted = 0
        Conflicts = [System.Collections.Generic.List[string]]::new(); Missing = [System.Collections.Generic.List[string]]::new(); Duplicates = [System.Collections.Generic.List[string]]::new() }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $firstRow = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)   # id마다 처음 나온 줄의 내용
    foreach ($n in @($Incoming)) {
        $id = [string]$n.id
        $rowKey = Get-WtRowKey $n.origin.row
        if (-not $seen.Add($id)) {
            if ($firstRow.ContainsKey($id) -and $firstRow[$id] -ceq $rowKey) { continue }   # id와 내용까지 같은 줄은 하나로 (잃는 것이 없다)
            $hash = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($rowKey))
            $dup = 'dup-' + [Convert]::ToHexString($hash).Substring(0, 12).ToLowerInvariant()
            Set-WtField $n 'id' $dup
            Set-WtField $n.origin 'dupOf' $id
            $id = $dup
            if (-not $seen.Add($id)) { continue }
            $r.Duplicates.Add($id)
        } else { $firstRow[$id] = $rowKey }
        if (-not $index.ContainsKey($id)) { $merged.Add($n); $index[$id] = $merged.Count - 1; $r.Added++; continue }
        $old = $merged[$index[$id]]
        if (Test-WtDeleted $old) { $r.KeptDeleted++; continue }
        $o = Get-WtField $old 'origin'
        if (-not (Test-WtRecordObject $o) -or [string](Get-WtField $o 'from') -ne $From) { $r.Conflicts.Add($id); continue }
        $changed = @(Get-WtChangedColumns (Get-WtField $o 'row') $n.origin.row)
        if (-not $changed.Count) { $r.Unchanged++; continue }
        # rev · origin.rev 중 하나라도 잘못된 값(-1)이면 고쳤음으로 본다 (둘 다 잘못돼 같은 -1이어도)
        $revNow = Get-WtItemRevision $old; $revThen = Get-WtItemRevision $o
        if ($revNow -lt 0 -or $revThen -lt 0 -or $revNow -ne $revThen) { $r.Conflicts.Add($id); continue }
        $paths = [System.Collections.Generic.List[string]]::new()
        foreach ($c in $changed) { foreach ($p in @($Owned[$c])) { if ($p -and -not $paths.Contains($p)) { $paths.Add($p) } } }
        foreach ($p in $paths) { Copy-WtPathValue $old $n $p }
        Set-WtField $o 'row' $n.origin.row
        Set-WtField $o 'at' $n.origin.at
        if ($paths.Count) { Set-WtField $old 'updated' $n.updated; $r.Updated++ } else { $r.Unchanged++ }
    }
    foreach ($i in @($Items)) {
        if (-not (Test-WtRecordObject $i) -or (Test-WtDeleted $i)) { continue }
        $o = Get-WtField $i 'origin'
        if (-not (Test-WtRecordObject $o) -or [string](Get-WtField $o 'from') -ne $From) { continue }
        if (-not $seen.Contains([string]$i.id)) { $r.Missing.Add([string]$i.id) }
    }
    $r.Items = $merged.ToArray()
    [pscustomobject]$r
}

Export-ModuleMember -Function Get-WtStamp, ConvertFrom-WtStamp, ConvertFrom-WtDateText, ConvertTo-WtDateText, ConvertFrom-WtTimeText,
    ConvertFrom-WtWhole, ConvertFrom-WtNumber, ConvertFrom-WtLegacyDate, ConvertFrom-WtLegacyTime, ConvertFrom-WtLegacyStamp,
    Test-WtRecordObject, Get-WtField, Set-WtField, Copy-WtItem, Test-WtDeleted, Get-WtItemRevision, Set-WtItemEdited, Get-WtRecordProblem,
    Compress-WtDeletedItems, Get-WtRowKey, Get-WtChangedColumns, Copy-WtPathValue, Merge-WtLegacyItems

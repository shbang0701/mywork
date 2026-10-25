# 기록 형식의 공통 틀. 어느 탭에나 같은 모양 · 규칙만 두고, 칸의 뜻은 탭이 정한다. 디스크에 닿지 않는다(저장은 Storage.psm1).
# 규칙 전체는 docs/plans/schedule-attendance-design.md 「공통 규칙」.
# - 날짜 · 시각은 세 모양만 쓴다
#     날짜만            "2026-10-28"                      시간대 없음 (하루 종일 · 휴가 날짜 · 휴무일)
#     사람이 정한 시각  { "date": "2026-10-28", "time": "22:00" }   24시간 HH:mm, 현지 벽시계, 시간대 없음. time이 null이면 시각 없음
#     앱이 찍는 시각    "2026-10-25T21:54:29+09:00"       created · updated · deleted · saved. 시간대 포함 (Get-WtStamp)
# - 글을 만들고 읽는 것은 문화권(ko-KR · en-US …)과 상관없이 같다 (InvariantCulture, 그레고리력)
# - 지운 기록은 deleted에 찍는 시각을 넣어 표시만 한다. 오래되면 내용을 비우고 { id, deleted }만 남긴다 (Compress-WtDeletedItems)
# - 예전(WinForms) CSV는 너그럽게 읽는다: Excel이 바꾼 2026/10/1 · 2026. 10. 1. · 9:30 · 오후 2:30 등 (ConvertFrom-WtLegacy*)
# - 가져온 기록은 origin = { from, at, row }에 원본 줄을 통째로 남기고, 다시 가져올 때는 덮어쓰지 않고 합친다 (Merge-WtLegacyItems)

$ErrorActionPreference = 'Stop'

$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:ko = [System.Globalization.CultureInfo]::GetCultureInfo('ko-KR')
$script:stampFormat = "yyyy-MM-dd'T'HH:mm:sszzz"
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

# 날짜 글 "yyyy-MM-dd" → [datetime](그날 0시). 모양이 다르거나 없는 날이면 $null
function ConvertFrom-WtDateText([string]$Text) {
    $d = [datetime]::MinValue
    if ($Text -and [datetime]::TryParseExact($Text, 'yyyy-MM-dd', $script:inv, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    $null
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

# 칸 하나의 값. 없으면 $null. $obj.count처럼 쓰면 칸이 없을 때 PowerShell이 붙인 Count(1)가 나오므로 이 함수로 읽는다
function Get-WtField($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
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

# 지운 표시가 있는지. deleted가 null · '' · false가 아니면 지운 것이다
function Test-WtDeleted($Item) {
    if ($null -eq $Item -or $Item -is [string] -or $Item -is [ValueType]) { return $false }
    $v = $Item.deleted
    if ($null -eq $v -or ($v -is [bool] -and -not $v)) { return $false }
    "$v" -ne ''
}

# 지운 지 $Days일이 지난 항목은 내용을 비우고 { id, deleted }만 남긴다. id를 남겨야 다시 가져오기 · 합치기에서 되살아나지 않는다.
# 지운 시각을 읽을 수 없으면 그대로 둔다. 나머지 항목은 그대로 돌려준다
function Compress-WtDeletedItems([object[]]$Items, [int]$Days = 90, $Now) {
    $limit = $(if ($null -eq $Now) { [DateTimeOffset]::Now } else { [DateTimeOffset]$Now }).AddDays(-$Days)
    foreach ($i in $Items) {
        if ($null -eq $i) { continue }
        if ((Test-WtDeleted $i) -and @($i.PSObject.Properties).Count -gt 2) {
            $at = ConvertFrom-WtStamp ([string]$i.deleted)
            if ($at -and $at -lt $limit) { [pscustomobject][ordered]@{ id = $i.id; deleted = $i.deleted }; continue }
        }
        $i
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

<#
예전 앱에서 가져온 항목을 지금 항목에 합친다. 덮어쓰지 않는다.
  $Items    지금 저장된 항목 (저장 파일에서 읽은 그대로)
  $Incoming 예전 데이터를 지금 형식으로 바꾼 항목. 저마다 origin = { from = $From; at; row }가 있다
규칙 (id로 짝짓는다)
  - 새 id → 더한다
  - 지금 쪽에서 지운 항목 → 되살리지 않는다
  - 예전 줄이 그대로 → 그대로 둔다
  - 예전 줄이 바뀌었고 지금 쪽에서 고치지 않았다(updated = origin.at) → 새 값으로 바꾼다. 지금 항목에만 있는 칸은 옮겨 둔다
  - 예전 줄이 바뀌었고 지금 쪽에서도 고쳤다 → 지금 값을 두고 Conflicts에 적는다
  - 지금 쪽에서 만든 항목(origin.from이 다름)과 id가 겹침 → 지금 값을 두고 Conflicts에 적는다
  - 예전 데이터에서 없어진 항목 → 지우지 않고 Missing에 적기만 한다
#>
function Merge-WtLegacyItems([object[]]$Items, [object[]]$Incoming, [string]$From = 'winforms-csv') {
    $merged = [System.Collections.Generic.List[object]]::new()
    $index = @{}
    foreach ($i in @($Items)) {
        if ($null -eq $i) { continue }
        $merged.Add($i)
        $k = [string]$i.id
        if ($k -and -not $index.ContainsKey($k)) { $index[$k] = $merged.Count - 1 }
    }
    $r = [ordered]@{ Added = 0; Updated = 0; Unchanged = 0; KeptDeleted = 0; Conflicts = [System.Collections.Generic.List[string]]::new(); Missing = [System.Collections.Generic.List[string]]::new() }
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($n in @($Incoming)) {
        $id = [string]$n.id
        if (-not $seen.Add($id)) { continue }   # 예전 데이터 안에서 id가 겹치면 앞의 것만
        if (-not $index.ContainsKey($id)) { $merged.Add($n); $index[$id] = $merged.Count - 1; $r.Added++; continue }
        $old = $merged[$index[$id]]
        if (Test-WtDeleted $old) { $r.KeptDeleted++; continue }
        $o = $old.origin
        if (-not $o -or [string]$o.from -ne $From) { $r.Conflicts.Add($id); continue }
        if ((Get-WtRowKey $o.row) -ceq (Get-WtRowKey $n.origin.row)) { $r.Unchanged++; continue }
        if ([string]$old.updated -cne [string]$o.at) { $r.Conflicts.Add($id); continue }
        foreach ($p in @($old.PSObject.Properties)) { if (-not $n.PSObject.Properties[$p.Name]) { Set-WtField $n $p.Name $p.Value } }
        $merged[$index[$id]] = $n
        $r.Updated++
    }
    foreach ($i in @($Items)) {
        if ($null -eq $i -or (Test-WtDeleted $i) -or -not $i.origin -or [string]$i.origin.from -ne $From) { continue }
        if (-not $seen.Contains([string]$i.id)) { $r.Missing.Add([string]$i.id) }
    }
    $r.Items = $merged.ToArray()
    [pscustomobject]$r
}

Export-ModuleMember -Function Get-WtStamp, ConvertFrom-WtStamp, ConvertFrom-WtDateText, ConvertTo-WtDateText, ConvertFrom-WtTimeText,
    ConvertFrom-WtLegacyDate, ConvertFrom-WtLegacyTime, ConvertFrom-WtLegacyStamp,
    Get-WtField, Set-WtField, Copy-WtItem, Test-WtDeleted, Compress-WtDeletedItems, Get-WtRowKey, Merge-WtLegacyItems

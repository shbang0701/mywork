<#
.SYNOPSIS
    근태 탭을 임시 데이터로 검사한다: 형식 · schema 이전 · 모르는 값 보존 · 예전 데이터 가져오기(합치기) · 월 요약 규칙(att-2) · 화면.

.DESCRIPTION
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.
    근태 표시 색의 대비는 테마 값이라 tests\Test-Core.ps1이 검사한다.
    고정 시험 자료(fixtures\)는 더하기만 하고 고치지 않는다. 형식을 바꾸면 옛 자료는 그대로 두고 새 자료를 더한다.
    그래야 예전에 쓴 파일이 계속 읽히는지 늘 확인된다. 모두 가짜 값이다.
      legacy.csv      예전 WinForms attendance.csv (BOM 붙은 UTF-8). Excel이 바꾼 날짜 · 시각, 자정 넘김, 모르는 종류, 깨진 줄
      v1.json         1단계 WPF가 쓴 schema 1
      v2.json         schema 2 대표 예 (퇴근 · 밤샘 근무 · 원격 · 현장 출동 · 하루 넘는 업무외 · 휴가 종류 · 사람이 정한 일수 · 달 넘김)
      v2-future.json  더 새 앱이 쓴 schema 2 흉내 (모르는 맨 위 키 · 칸 · kind · leave.type · overtime.how)
      v2-edge.json    null 항목 · 31일 넘는 기록 · 범위 밖 휴가 일수(BigInteger · 음수) · 확정 일수 0.5 · 2199년 뒤 날짜 · rev (2026-10-26 검토 반례)
    휴무일은 tests\fixtures\holidays.json(코어 고정 시험 자료)을 쓴다: 10/3 · 10/9 공휴일, 10/8 개인 휴무, 11/20 회사 휴무.
    월 합계 기대 값은 여기에 못 박아 둔다. 규칙(att-2)을 바꿔 값이 바뀌면 이 파일을 일부러 고쳐야 한다.

.EXAMPLE
    pwsh -NoProfile -File apps/WorkTool/wpf/addons/attendance/Test-Attendance.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'AttendanceData.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Attendance.psm1') -Force -DisableNameChecking
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$holidayFixture = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/fixtures/holidays.json'
$d = { param($t) [datetime]::ParseExact($t, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
$tests = [System.Collections.Generic.List[object]]::new()

function Copy-WtTestFixture([string]$Name) { [System.IO.File]::Copy((Join-Path $fixtures $Name), (Get-WtStorePath 'attendance'), $true) }
function Copy-WtTestHolidays { [System.IO.File]::Copy($holidayFixture, (Get-WtStorePath 'holidays'), $true) }
function Read-WtTestDoc { [System.IO.File]::ReadAllText((Get-WtStorePath 'attendance')) | ConvertFrom-Json -Depth 20 -DateKind String }
function Get-WtTestJson($Value) { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }
function Get-WtTestById($Entries) { $m = @{}; foreach ($e in @($Entries)) { if ($e.Id -and -not $m.ContainsKey($e.Id)) { $m[$e.Id] = $e } }; $m }
function Format-WtTestSummary($Summary) {
    'work {0}/{1}/{2} · over {3}/{4}/{5} · trip {6}/{7} · leave {8} · skip {9}' -f $Summary.WorkDays, $Summary.WorkMinutes, $Summary.WorkOpen,
        $Summary.OverMinutes, $Summary.OverCount, $Summary.OverOpen, $Summary.TripDays, $Summary.TripCount, $Summary.LeaveDays.ToString([System.Globalization.CultureInfo]::InvariantCulture), $Summary.Skipped
}

try {
    # ---- 예전 CSV (legacy.csv) ----
    $test = New-WtTestData 'attendance'; $tests.Add($test)
    Copy-WtTestHolidays
    [void][System.IO.Directory]::CreateDirectory($test.Legacy)
    [System.IO.File]::Copy((Join-Path $fixtures 'legacy.csv'), (Join-Path $test.Legacy 'attendance.csv'))
    $r = Import-WtLegacyData
    Assert-WtTest '근태: 예전 CSV를 가져온다 (모르는 종류 · 깨진 줄도 버리지 않음)' ($r.Count -eq 13 -and $r.Tabs.Count -eq 1) "($($r.Count) / $($r.Tabs -join ', '))"
    $data = Get-WtAttendanceData
    $byId = Get-WtTestById $data.Entries
    $doc = Read-WtTestDoc
    Assert-WtTest '근태: 저장 값은 영문 코드, 원본 줄은 origin에' ($doc.schema -eq 2 -and (($doc.items | ForEach-Object kind) -join ',') -eq 'work,work,overtime,overtime,trip,leave,leave,work,leave,overtime,leave,other,work' -and
        $doc.items[5].leave.type -eq 'half-pm' -and $doc.items[5].origin.row.Detail -eq '오후 반차' -and $doc.legacy.rows -eq 13)
    Assert-WtTest '근태: 출근은 퇴근 기록 없음(0시간이 아니라 모름)' ($byId.t1.State -eq 'ok' -and -not $byId.t1.HasEnd -and $null -eq $byId.t1.Minutes -and $byId.t1.Start -eq (& $d '2026-10-21').AddMinutes(527))
    Assert-WtTest '근태: 업무외 끝이 시작보다 이르면 가져올 때 한 번만 다음 날로 (끝 날짜를 적는다)' (
        $byId.t4.Item.end.date -eq '2026-10-14' -and $byId.t4.Minutes -eq 120 -and $byId.t3.Minutes -eq 150 -and $byId.t10.State -eq 'ok' -and $null -eq $byId.t10.Item.end)
    Assert-WtTest '근태: Excel이 바꾼 날짜(2026/10/5)와 9:00을 읽는다' ($byId.t9.Item.start.date -eq '2026-10-05' -and $byId.t9.Item.end.date -eq '2026-10-09' -and $byId.t10.Item.start.time -eq '09:00')
    Assert-WtTest '근태: 휴가 글 → 코드 (연차 · 오후 반차 · 반차), 출장지 · 메모' (
        $byId.t7.LeaveType -eq 'annual' -and $byId.t6.LeaveType -eq 'half-pm' -and $byId.t11.LeaveType -eq 'half' -and $byId.t11.Note -eq '반차' -and $byId.t7.Note -eq '' -and
        $byId.t5.Kind -eq 'trip' -and $byId.t5.Place -eq '데이터센터' -and $byId.t5.EndDate -eq (& $d '2026-10-17') -and $byId.t5.Note -eq '점검')
    Assert-WtTest '근태: 모르는 종류는 기타(원래 이름을 메모에), 깨진 날짜는 고칠 항목' ($byId.t12.Kind -eq 'other' -and $byId.t12.Note -eq '재택: 예전 앱이 모르는 종류' -and
        $byId.t13.State -eq 'broken' -and $byId.t13.Item.start.date -eq '2026-13-01')
    $sum = Get-WtAttendanceSummary (& $d '2026-10-01') $data.Entries
    $text = Format-WtTestSummary $sum
    Assert-WtTest '근태 att-2 10월: 출근 날 수 · 업무외(자정 넘김) · 출장 일수와 건수 · 휴가(주말 · 휴무일 빼기, 반차 0.5) · 뺀 항목' (
        $text -eq 'work 1/0/2 · over 270/3/1 · trip 2/1 · leave 5.5 · skip 1' -and $sum.Rule -eq 'att-2') $text
    $text = Format-WtTestSummary (Get-WtAttendanceSummary (& $d '2026-10-01') $data.Entries ([System.Collections.Generic.HashSet[string]]::new()))
    Assert-WtTest '근태 att-2: 휴무일이 없으면 휴가 일수가 예전 앱 규칙(주말 빼기 · 반차 × 0.5)과 같다' ($text -like '* leave 7.5 *') $text
    $text = Format-WtTestSummary (Get-WtAttendanceSummary (& $d '2026-10-01') $data.Entries $null 'workdays')
    Assert-WtTest '근태 att-2: 출장 일수를 근무일만 세는 설정 (지운 휴무는 휴무가 아님)' ($text -like '* trip 1/1 *') $text
    $text = Format-WtTestSummary (Get-WtAttendanceSummary (& $d '2026-09-01') $data.Entries)
    Assert-WtTest '근태 att-2 9월: 달을 넘긴 휴가는 그 달에 걸친 날만' ($text -eq 'work 1/0/1 · over 0/0/0 · trip 0/0 · leave 1 · skip 1') $text

    # ---- 다시 가져오기: 덮어쓰지 않고 합친다 ----
    $r2 = Import-WtLegacyData -Force
    Assert-WtTest '근태 합치기: 그대로인 CSV는 아무것도 바꾸지 않는다' ($r2.Count -eq 0 -and (Get-WtAttendanceLastImport).Unchanged -eq 13)
    $data = Get-WtAttendanceData
    $items = @($data.Items)
    foreach ($i in $items) {
        # 가져온 같은 초에 고쳐도 rev로 「이 앱에서 고침」을 알아본다
        if ($i.id -eq 't1') { Set-WtField $i 'end' ([pscustomobject]@{ date = '2026-10-21'; time = '18:10' }); Set-WtItemEdited $i $i.origin.at }
        if ($i.id -eq 't2') { $i.deleted = Get-WtStamp; Set-WtItemEdited $i }
        if ($i.id -eq 't3') { $i | Add-Member -NotePropertyName approved -NotePropertyValue '모르는 칸'; $i.start | Add-Member -NotePropertyName zone -NotePropertyValue 'Asia/Seoul' }
    }
    Save-WtAttendanceItems $data.Store $items
    $csv = [System.IO.File]::ReadAllText((Join-Path $fixtures 'legacy.csv'))
    $csv = $csv.Replace('"t1","출근","2026-10-21","2026-10-21","08:47"', '"t1","출근","2026-10-21","2026-10-21","08:40"')
    $csv = $csv.Replace('"t3","업무외시간 근무","2026-10-20","2026-10-20","19:00","21:30"', '"t3","업무외시간 근무","2026-10-20","2026-10-20","19:00","22:00"')
    Write-WtTestLegacyCsv $test 'attendance' $csv
    $r3 = Import-WtLegacyData -Force
    $m = Get-WtAttendanceLastImport
    $after = Get-WtTestById (Get-WtAttendanceData).Entries
    Assert-WtTest '근태 합치기: 예전 앱에서만 바뀐 기록은 새 값, 이 앱에서 고친 기록(퇴근)은 그대로 · 충돌로, 지운 기록은 되살리지 않는다' (
        $r3.Count -eq 1 -and $after.t3.Minutes -eq 180 -and $after.t1.HasEnd -and $after.t1.Start -eq (& $d '2026-10-21').AddMinutes(527) -and ($m.Conflicts -join ',') -eq 't1' -and
        $after.t2.State -eq 'deleted' -and $m.KeptDeleted -eq 1) "($($r3.Count) · 충돌 $($m.Conflicts -join ','))"
    Assert-WtTest '근태 합치기: 바뀐 예전 칸(EndTime)이 정하는 경로(end.time · end.date)만 옮기고, 모르는 칸 · 중첩 칸(start.zone)은 그대로' (
        $after.t3.Item.approved -eq '모르는 칸' -and $after.t3.Item.start.zone -eq 'Asia/Seoul' -and $after.t3.Item.end.time -eq '22:00' -and $after.t3.Item.rev -eq 0 -and $after.t3.Note -eq '패치')

    # ---- 1단계 WPF 파일 (v1.json) → schema 2 ----
    $test = New-WtTestData 'attendance-v1'; $tests.Add($test)
    Copy-WtTestFixture 'v1.json'
    $original = [System.IO.File]::ReadAllBytes((Get-WtStorePath 'attendance'))
    $data = Get-WtAttendanceData
    $byId = Get-WtTestById $data.Entries
    $doc = Read-WtTestDoc
    $backups = @(Get-ChildItem -LiteralPath $test.Data -Filter 'attendance.json.schema1.*.bak')
    Assert-WtTest '근태 이전: schema 1 → 2, 맨 위 키 · 모르는 칸을 잃지 않는다' (-not $data.Error -and $doc.schema -eq 2 -and $doc.importedFrom -eq 'C:\WorkTool\data' -and $doc._fixture -like '고정 시험 자료*' -and
        @($data.Entries | Where-Object State -eq 'ok').Count -eq 5 -and $byId.t7.Item.approved -eq '모르는 칸' -and $byId.t7.Item.origin.via -eq 'schema1') "$($data.Error)"
    Assert-WtTest '근태 이전: 바꾸기 전 원본을 날짜 붙은 백업으로 그대로 남긴다' ($backups.Count -eq 1 -and
        [Convert]::ToHexString([System.IO.File]::ReadAllBytes($backups[0].FullName)) -eq [Convert]::ToHexString($original))
    Assert-WtTest '근태 이전: 한글 종류 → 코드, 자정 넘김 끝 날짜, 반차 · 연차' ($byId.t1.Kind -eq 'work' -and $byId.t4.Kind -eq 'overtime' -and $byId.t4.Item.end.date -eq '2026-10-14' -and
        $byId.t6.LeaveType -eq 'half-pm' -and $byId.t7.LeaveType -eq 'annual' -and $byId.t5.Kind -eq 'trip')

    # ---- schema 2 대표 예 (v2.json) ----
    $test = New-WtTestData 'attendance-v2'; $tests.Add($test)
    Copy-WtTestHolidays
    Copy-WtTestFixture 'v2.json'
    $original = [System.IO.File]::ReadAllBytes((Get-WtStorePath 'attendance'))
    $data = Get-WtAttendanceData
    $byId = Get-WtTestById $data.Entries
    $states = (@($data.Entries) | ForEach-Object { $_.State } | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    Assert-WtTest '근태 v2: 모두 읽힌다, 읽기만 해서는 파일을 바꾸지 않는다' ($states -eq 'deleted=2 ok=11' -and
        [Convert]::ToHexString([System.IO.File]::ReadAllBytes((Get-WtStorePath 'attendance'))) -eq [Convert]::ToHexString($original)) $states
    Assert-WtTest '근태 v2: 밤샘 근무 · 하루 넘는 출동은 끝 날짜까지 센다' ($byId.w2a2b3c4d5e6.Minutes -eq 570 -and $byId.o2a2b3c4d5e6.Minutes -eq 1560 -and
        $byId.o2a2b3c4d5e6.How -eq 'onsite' -and $byId.o2a2b3c4d5e6.Ref -eq 'INC-0002' -and $byId.o1a2b3c4d5e6.How -eq 'remote')
    $text = Format-WtTestSummary (Get-WtAttendanceSummary (& $d '2026-11-01') $data.Entries)
    Assert-WtTest '근태 att-2 11월: 퇴근 · 밤샘 · 출동 · 출장 · 휴가(회사 휴무 빼기 · 오전 반차 · 사람이 정한 일수 · 달 넘김)' ($text -eq 'work 3/1140/1 · over 1710/2/0 · trip 3/1 · leave 4.5 · skip 0') $text
    $text = Format-WtTestSummary (Get-WtAttendanceSummary (& $d '2026-12-01') $data.Entries)
    Assert-WtTest '근태 att-2 12월: 달을 넘긴 병가는 12월 몫만' ($text -eq 'work 0/0/0 · over 0/0/0 · trip 0/0 · leave 1 · skip 0') $text

    # ---- 더 새 앱이 쓴 파일 (v2-future.json) ----
    $test = New-WtTestData 'attendance-future'; $tests.Add($test)
    Copy-WtTestFixture 'v2-future.json'
    $before = [System.IO.File]::ReadAllText((Get-WtStorePath 'attendance')) | ConvertFrom-Json -Depth 20 -DateKind String
    $data = Get-WtAttendanceData
    $byId = Get-WtTestById $data.Entries
    $ro = (@($data.Entries | Where-Object State -eq 'readonly') | ForEach-Object { $_.Id.Substring(0, 2) }) -join ','
    Assert-WtTest '근태 새 버전: 모르는 kind(leave-grant · month-close · oncall) · 휴가 종류 · 업무외 방식은 읽기 전용' ($ro -eq 'g1,m1,n1,l9,o9' -and
        $byId.w9a2b3c4d5e6.State -eq 'ok' -and $byId.w9a2b3c4d5e6.Minutes -eq 540 -and $byId.r9a2b3c4d5e6.State -eq 'ok') $ro
    $text = Format-WtTestSummary (Get-WtAttendanceSummary (& $d '2026-11-01') $data.Entries ([System.Collections.Generic.HashSet[string]]::new()))
    Assert-WtTest '근태 새 버전: 읽기 전용 기록은 합계에서 빠진다' ($text -eq 'work 1/540/0 · over 0/0/0 · trip 2/1 · leave 0 · skip 5') $text
    $items = @($data.Items)
    $items[0].note = '이 앱에서 고친 메모'; Set-WtItemEdited $items[0]
    Save-WtAttendanceItems $data.Store $items
    $saved = Read-WtTestDoc
    $sameOthers = $true
    for ($i = 1; $i -lt $before.items.Count; $i++) { if ((Get-WtTestJson $before.items[$i]) -cne (Get-WtTestJson $saved.items[$i])) { $sameOthers = $false } }
    Assert-WtTest '근태 새 버전: 한 기록을 고쳐 저장해도 모르는 맨 위 키 · 칸 · 기록이 그대로' (
        (Get-WtTestJson $saved.contract) -ceq (Get-WtTestJson $before.contract) -and $sameOthers -and $saved.items[0].note -eq '이 앱에서 고친 메모' -and
        (Get-WtTestJson $saved.items[0].breaks) -ceq (Get-WtTestJson $before.items[0].breaks) -and $saved.items[0].geo.site -eq '본사' -and $saved.items[0].start.zone -eq 'Asia/Seoul')

    # ---- 경계 값 (v2-edge.json, 2026-10-26 검토 반례) ----
    $test = New-WtTestData 'attendance-edge'; $tests.Add($test)
    Copy-WtTestFixture 'v2-edge.json'
    $before = [System.IO.File]::ReadAllText((Get-WtStorePath 'attendance')) | ConvertFrom-Json -Depth 20 -DateKind String
    $data = Get-WtAttendanceData
    $states = (@($data.Entries) | ForEach-Object { $_.State }) -join ','
    Assert-WtTest '근태 경계 값: null 항목 · 31일 넘는 기록 · 범위 밖 휴가 일수 · 2199년 뒤 날짜는 그 항목만 고칠 항목 (예외 없음)' (
        -not $data.Error -and $states -eq 'ok,broken,broken,broken,broken,ok,broken') $states
    $sum = Get-WtAttendanceSummary (& $d '2026-11-01') $data.Entries ([System.Collections.Generic.HashSet[string]]::new())
    Assert-WtTest '근태 att-2: 휴가 일수는 확정(days 숫자)과 잠정(규칙으로 셈)을 나눠 돌려준다' ($sum.LeaveDays -eq 0.5 -and $sum.LeaveFixed -eq 0.5 -and $sum.LeaveEstimated -eq 0 -and $sum.Skipped -eq 5)
    $items = @($data.Items)
    $items[0].note = '고친 메모'; Set-WtItemEdited $items[0]
    Save-WtAttendanceItems $data.Store $items
    $saved = Read-WtTestDoc
    $same = $true
    for ($i = 1; $i -lt $before.items.Count; $i++) { if ((Get-WtTestJson $before.items[$i]) -cne (Get-WtTestJson $saved.items[$i])) { $same = $false } }
    Assert-WtTest '근태 경계 값: 한 기록을 고쳐 저장해도 null · 깨진 기록이 같은 자리에 같은 값, rev는 1 오른다' ($same -and @($saved.items).Count -eq 7 -and $null -eq $saved.items[1] -and $saved.items[0].rev -eq 3)
    [System.IO.File]::WriteAllText((Get-WtStorePath 'attendance'), '', [System.Text.UTF8Encoding]::new($false))
    $data = Get-WtAttendanceData
    $saveError = $null; try { Save-WtAttendanceItems $data.Store @() } catch { $saveError = $_.Exception.Message }
    Assert-WtTest '근태 저장 거부: 빈 파일은 깨진 파일로 알리고 저장하지 않는다' ($data.Error -like '*비어 있습니다*' -and $saveError -and [System.IO.File]::ReadAllText((Get-WtStorePath 'attendance')) -eq '')

    # ---- 규칙 하나씩 ----
    $base = '"id": "x", "place": "", "note": "", "tags": []'
    $cases = [ordered]@{
        '끝이 시작보다 이름' = "{ $base, ""kind"": ""work"", ""start"": { ""date"": ""2026-10-02"", ""time"": ""09:00"" }, ""end"": { ""date"": ""2026-10-01"", ""time"": ""18:00"" } }"
        '한쪽에만 시각' = "{ $base, ""kind"": ""work"", ""start"": { ""date"": ""2026-10-01"", ""time"": ""09:00"" }, ""end"": { ""date"": ""2026-10-01"", ""time"": null } }"
        '휴가 종류 없음' = "{ $base, ""kind"": ""leave"", ""start"": { ""date"": ""2026-10-01"", ""time"": null }, ""end"": null }"
        '휴가 일수가 글' = "{ $base, ""kind"": ""leave"", ""start"": { ""date"": ""2026-10-01"", ""time"": null }, ""end"": null, ""leave"": { ""type"": ""annual"", ""days"": ""1"" } }"
        '없는 시각' = "{ $base, ""kind"": ""work"", ""start"": { ""date"": ""2026-10-01"", ""time"": ""9:00"" }, ""end"": null }"
    }
    $wrong = @(foreach ($k in $cases.Keys) { $e = ConvertFrom-WtAttendanceItem ($cases[$k] | ConvertFrom-Json -DateKind String); if ($e.State -ne 'broken') { "$k=$($e.State)" } })
    Assert-WtTest '근태 규칙: 틀린 값은 고칠 항목' (-not $wrong.Count) ($wrong -join ', ')

    # ---- 문화권이 달라도 같은 결과 ----
    $rows = (Read-WtLegacyCsv $fixtures 'legacy').Rows
    $v2 = (Get-Content -LiteralPath (Join-Path $fixtures 'v2.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -DateKind String).items
    $off = [System.Collections.Generic.HashSet[string]]::new([string[]]@('2026-11-20'))
    $snapshot = {
        $converted = Get-WtTestJson @(foreach ($row in $rows) { ConvertFrom-WtAttendanceRow $row '2026-10-26T09:00:00+09:00' })
        $entries = @(foreach ($i in $v2) { ConvertFrom-WtAttendanceItem $i })
        "$converted|$(Format-WtTestSummary (Get-WtAttendanceSummary (& $d '2026-11-01') $entries $off 'all'))"
    }
    $thread = [System.Threading.Thread]::CurrentThread
    $oldCulture = $thread.CurrentCulture
    $results = @{}
    try {
        foreach ($c in 'en-US', 'ko-KR', 'th-TH', 'ar-SA', 'de-DE') { $thread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($c); $results[$c] = & $snapshot }
    } finally { $thread.CurrentCulture = $oldCulture }
    Assert-WtTest '근태: 문화권(en-US · ko-KR · th-TH · ar-SA · de-DE 소수점 쉼표)이 달라도 가져오기 · 합계가 같다' (@($results.Values | Sort-Object -Unique).Count -eq 1)

    # 같은 캐시 핸들을 받은 두 곳 중 먼저 저장한 내용은 뒤의 옛 목록으로 덮지 않는다
    $test = New-WtTestData 'attendance-shared'; $tests.Add($test)
    Copy-WtTestFixture 'v2.json'
    $data = Get-WtAttendanceData; $other = Get-WtAttendanceData
    $a = @(Copy-WtItem @($data.Items)); $a[0].note = 'A가 고침'
    $b = @(Copy-WtItem @($other.Items)); $b[0].place = 'B의 옛 목록'
    Save-WtAttendanceItems $data.Store $a
    $lateError = $null; try { Save-WtAttendanceItems $other.Store $b } catch { $lateError = $_.Exception.Message }
    Assert-WtTest '근태 저장 거부: 공유 캐시의 옛 핸들은 먼저 저장한 내용을 덮지 않는다 (낙관적 잠금)' (
        [object]::ReferenceEquals($data.Store, $other.Store) -and $lateError -like '*바뀌었습니다*' -and
        (Read-WtTestDoc).items[0].note -eq 'A가 고침' -and (Read-WtTestDoc).items[0].place -eq '') $lateError

    # ---- 읽을 수 없는 파일 ----
    $test = New-WtTestData 'attendance-bad'; $tests.Add($test)
    [System.IO.File]::WriteAllText((Get-WtStorePath 'attendance'), '{ "schema": 3, "items": [] }', [System.Text.UTF8Encoding]::new($false))
    $data = Get-WtAttendanceData
    Assert-WtTest '근태 못 읽는 파일: 오류로 알리고 파일은 그대로' ($data.Error -like '*더 새 버전*' -and [System.IO.File]::ReadAllText((Get-WtStorePath 'attendance')) -ceq '{ "schema": 3, "items": [] }')

    if (Test-WtTestWpf) {
        $test = New-WtTestData 'attendance-view'; $tests.Add($test)
        [void][System.IO.Directory]::CreateDirectory($test.Legacy)
        [System.IO.File]::Copy((Join-Path $fixtures 'legacy.csv'), (Join-Path $test.Legacy 'attendance.csv'))
        [void](Import-WtLegacyData)
        $module = Get-Module Attendance
        $view = New-WtTestView 'attendance'
        & $module { Update-WtAttendanceView; $script:testFirst = $script:body.Children[0]; Update-WtAttendanceView }
        Assert-WtTest '근태 화면: 같은 월과 데이터는 화면을 재사용한다' (& $module { [object]::ReferenceEquals($script:testFirst, $script:body.Children[0]) })
        & $module { $script:month = $script:month.AddMonths(-1); Update-WtAttendanceView }
        Assert-WtTest '근태 화면: 달을 바꾸면 다시 만들고 재진입해도 고른 달 유지' (& $module {
            $month = $script:month; $changed = -not [object]::ReferenceEquals($script:testFirst, $script:body.Children[0])
            Update-WtAttendanceView; $changed -and $script:month -eq $month
        })
        $data = Get-WtAttendanceData
        $items = @($data.Items)
        $items[0].note = '외부에서 바꾼 기록'
        $items[0].start.date = ([datetime]::Today.AddMonths(-1)).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        Set-WtItemEdited $items[0]
        Save-WtAttendanceItems $data.Store $items
        & $module { Update-WtAttendanceView }
        $texts = @(Get-WtTestTexts $view)
        Assert-WtTest '근태 화면: 저장이 바뀌면 다시 들어올 때 반영하고, 고칠 항목을 보여 준다' ($texts -contains '외부에서 바꾼 기록' -and @($texts | Where-Object { $_ -like '고칠 항목*' }).Count -eq 1)
        $card = & $module { New-WtAttendanceHomeCard }
        Assert-WtTest '근태 화면: 홈 카드' (@(Get-WtTestTexts $card | Where-Object { $_ -like '근태 · *' }).Count -eq 1)
        [System.IO.File]::WriteAllText((Get-WtStorePath 'holidays'), '{ "schema": 9, "items": [] }', [System.Text.UTF8Encoding]::new($false))
        & $module { Update-WtAttendanceView }
        Assert-WtTest '근태 화면: 휴무일을 못 읽으면 주말만 뺐다고 알린다' (@(Get-WtTestTexts $view | Where-Object { $_ -like '휴무일을 읽지 못해*' }).Count -eq 1)
        [System.IO.File]::WriteAllText((Get-WtStorePath 'attendance'), '{ "schema": 3, "items": [] }', [System.Text.UTF8Encoding]::new($false))
        & $module { Update-WtAttendanceView }
        Assert-WtTest '근태 화면: 못 읽는 파일이면 화면은 열고 이유를 보여 준다' ((Get-WtTestTexts $view) -contains '근태 파일을 읽지 못했습니다')
    }
} finally {
    foreach ($t in $tests) { Remove-WtTestData $t }
}

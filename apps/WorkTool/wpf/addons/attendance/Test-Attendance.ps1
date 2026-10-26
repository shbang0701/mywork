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
      v2-travel.json  이동 · 겹침 우선순위 · 초과근무 고정 예 (11월 작업장 960 · 원격 390 · 장소 없음 120 · 이동 116분)
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

    Assert-WtTest '장소 없는 예전 CSV: 작업장 0 · 원격 0 · 장소 없음 270분 (원자료 null 그대로)' ($sum.OvertimeSite -eq 0 -and $sum.OvertimeRemote -eq 0 -and $sum.OvertimeUnknown -eq 270 -and $null -eq $byId.t3.Item.overtime.how)

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

    # ---- 근태 4: 못 박은 분 단위 기대 값. 규칙을 복제해서 기대 값을 만들지 않는다. ----
    $travelDoc = Get-Content (Join-Path $fixtures 'v2-travel.json') -Raw | ConvertFrom-Json -Depth 30 -DateKind String
    $travelBefore = Get-WtTestJson $travelDoc
    $travelEntries = @(foreach ($item in $travelDoc.items) { ConvertFrom-WtAttendanceItem $item })
    $travelOff = [Collections.Generic.HashSet[string]]::new([string[]]@('2026-11-20'))
    $november = & $d '2026-11-01'
    $travelSum = Get-WtAttendanceSummary $november $travelEntries $travelOff
    Assert-WtTest '초과 합계: 작업장 960 · 원격 390 · 장소 없음 120 · 이동 116 · 퇴근 없는 날 1' ($travelSum.OvertimeSite -eq 960 -and $travelSum.OvertimeRemote -eq 390 -and $travelSum.OvertimeUnknown -eq 120 -and $travelSum.Travel -eq 116 -and $travelSum.NoLeaveDays -eq 1) ($travelSum | ConvertTo-Json -Compress)
    $dayCases = @(
        @('2026-11-02',120,0,0,0,0), @('2026-11-03',0,0,0,0,0), @('2026-11-04',0,0,0,11,1),
        @('2026-11-05',0,150,0,0,0), @('2026-11-07',240,120,120,105,0), @('2026-11-18',180,0,0,0,0),
        @('2026-11-20',300,0,0,0,0), @('2026-11-23',120,0,0,0,0), @('2026-11-30',0,120,0,0,0))
    foreach ($case in $dayCases) {
        $dayEntries = @($travelEntries | Where-Object { $_.StartDate -eq (& $d $case[0]) })
        $got = Get-WtAttendanceSummary $november $dayEntries $travelOff
        Assert-WtTest "초과 $($case[0]): 작업장 $($case[1]) · 원격 $($case[2]) · 장소 없음 $($case[3]) · 이동 $($case[4]) · 미퇴근 $($case[5])" ($got.OvertimeSite -eq $case[1] -and $got.OvertimeRemote -eq $case[2] -and $got.OvertimeUnknown -eq $case[3] -and $got.Travel -eq $case[4] -and $got.NoLeaveDays -eq $case[5])
    }
    $decemberSum = Get-WtAttendanceSummary (& $d '2026-12-01') $travelEntries $travelOff
    Assert-WtTest '자정·달 넘김은 통째 시작한 달: 12월 초과와 이동 0' ($decemberSum.OvertimeSite -eq 0 -and $decemberSum.OvertimeRemote -eq 0 -and $decemberSum.OvertimeUnknown -eq 0 -and $decemberSum.Travel -eq 0)
    $savedHours = Get-WtWorkHours
    try {
        Set-WtSetting 'work.days' @(6,7)
        $mon = Get-WtAttendanceSummary $november @($travelEntries | Where-Object Id -ceq 'early-late') $travelOff
        $sat = Get-WtAttendanceSummary $november @($travelEntries | Where-Object { $_.StartDate -eq (& $d '2026-11-07') }) $travelOff
        Assert-WtTest 'work.days=토·일: 월요일 660분 · 토요일 정규시간 안 0분 (점심 포함 정규시간 제외)' ($mon.OvertimeSite -eq 660 -and $sat.OvertimeSite -eq 0 -and $sat.OvertimeRemote -eq 0 -and $sat.OvertimeUnknown -eq 0 -and $sat.Travel -eq 105)
        Set-WtWorkHours @{ 'work.days'=@(1,2,3,4,5); 'work.start'='10:00'; 'work.end'='17:00'; 'work.lunchStart'='12:30'; 'work.lunchEnd'='13:30' }
        $shift = Get-WtAttendanceSummary $november @($travelEntries | Where-Object Id -ceq 'early-late') $travelOff
        Assert-WtTest '업무시간 설정 변경: 08~19에서 10~17 제외 = 작업장 240분' ($shift.OvertimeSite -eq 240)
    } finally { Set-WtWorkHours $savedHours }
    $thread = [Threading.Thread]::CurrentThread; $oldCulture = $thread.CurrentCulture
    try {
        foreach ($culture in 'ko-KR','en-US','th-TH','ar-SA','de-DE') {
            $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
            $got = Get-WtAttendanceSummary $november $travelEntries $travelOff
            Assert-WtTest "초과 5개 문화권 $culture : 960 / 390 / 120 / 116 / 1" ($got.OvertimeSite -eq 960 -and $got.OvertimeRemote -eq 390 -and $got.OvertimeUnknown -eq 120 -and $got.Travel -eq 116 -and $got.NoLeaveDays -eq 1)
        }
    } finally { $thread.CurrentCulture = $oldCulture }
    Assert-WtTest '조회·계산은 travel·how 등 원자료를 바꾸지 않음' ((Get-WtTestJson $travelDoc) -ceq $travelBefore)
    $travelItem = @($travelDoc.items | Where-Object id -ceq 'weekend-site')[0]
    foreach ($badTravel in @(@{out=-1;back=0}, @{out=0;back=1441}, @{out=0.5;back=0}, @{out='1';back=0}, @{out=$true;back=0}, @{out=0}, '틀린 모양', $null)) {
        $bad = Copy-WtItem $travelItem; $bad.travel = $badTravel
        Assert-WtTest 'travel 범위·형식 검사: 잘못된 값은 고칠 항목' ((ConvertFrom-WtAttendanceItem $bad).State -ceq 'broken')
    }
    $edgeTravel = Copy-WtItem $travelItem; $edgeTravel.travel = @{out=0;back=1440}
    Assert-WtTest 'travel 끝값 0·1440 허용' ((ConvertFrom-WtAttendanceItem $edgeTravel).Travel -eq 1440)

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

    # ---- 2a 지금 기록 · 직접 편집 · 보고 글 ----
    $test = New-WtTestData 'attendance-edit'; $tests.Add($test)
    $store = Open-WtAttendanceStore
    $r = Start-WtAttendanceRecord $store -At '2026-11-02T08:47:12+09:00'
    $workId = $r.Id
    $duplicate = Start-WtAttendanceRecord $r.Store -At '2026-11-02T08:48:00+09:00'
    Assert-WtTest '지금 출근: 벽시계 · at 증거 · 원래 핸들 보존, 같은 날 두 번 누르면 이유로 거부' ($r.Success -and $r.Store.Items[0].start.date -ceq '2026-11-02' -and
        $r.Store.Items[0].start.time -ceq '08:47' -and $r.Store.Items[0].start.at -ceq '2026-11-02T08:47:12+09:00' -and $store.Items.Count -eq 0 -and -not $duplicate.Success -and $duplicate.Reason)
    $r = Stop-WtAttendanceRecord $r.Store -At '2026-11-02T18:10:24+09:00'
    $e = ConvertFrom-WtAttendanceItem $r.Store.Items[0]
    Assert-WtTest '지금 퇴근: 분 계산 · end.at · rev 증가' ($r.Success -and $e.Minutes -eq 563 -and $e.Item.end.at -ceq '2026-11-02T18:10:24+09:00' -and $e.Item.rev -eq 1) $r.Reason
    $r = Save-WtAttendanceItem $r.Store @{ start = @{ time = '09:00'; zone = '남길 칸' }; note = '직접 고침' } -Id $workId -At '2026-11-03T09:00:00+09:00'
    Assert-WtTest '근태 직접 편집: 바꾼 점의 at 삭제 · 안 바꾼 끝의 증거 보존' ($r.Success -and -not $r.Store.Items[0].start.PSObject.Properties['at'] -and
        $r.Store.Items[0].end.at -ceq '2026-11-02T18:10:24+09:00' -and $r.Store.Items[0].start.zone -ceq '남길 칸') $r.Reason
    $r = Save-WtAttendanceItem $r.Store @{ kind = 'work'; start = @{ date = '2026-11-02'; time = '20:00' } } -At '2026-11-03T09:00:00+09:00'
    $entries = @(foreach ($i in $r.Store.Items) { ConvertFrom-WtAttendanceItem $i })
    $s = Get-WtAttendanceSummary (& $d '2026-11-01') $entries
    Assert-WtTest '근태 요약: 같은 날 출근 두 기록도 하루 · 퇴근 없는 기록은 0분 대신 미완료 수' ($r.Success -and $s.WorkDays -eq 1 -and $s.WorkMinutes -eq 550 -and $s.WorkOpen -eq 1)
    $r = Start-WtAttendanceRecord $r.Store -Kind overtime -How onsite -Ref 'INC-0001' -Place '시험 현장' -At '2026-11-30T23:30:12+09:00'
    $overId = $r.Id
    $r = Stop-WtAttendanceRecord $r.Store -Kind overtime -At '2026-12-01T01:00:25+09:00'
    $over = @($r.Store.Items | Where-Object id -ceq $overId)[0]
    Assert-WtTest '업무외 두 번 기록: 자정 · 달 넘김 · 원격/현장 · 관련번호 · 양쪽 증거' ($r.Success -and $over.end.date -ceq '2026-12-01' -and
        $over.overtime.how -ceq 'onsite' -and $over.overtime.ref -ceq 'INC-0001' -and $over.start.at -ceq '2026-11-30T23:30:12+09:00' -and $over.end.at -ceq '2026-12-01T01:00:25+09:00') $r.Reason
    $entries = @(foreach ($i in $r.Store.Items) { ConvertFrom-WtAttendanceItem $i })
    $nov = Get-WtAttendanceSummary (& $d '2026-11-01') $entries
    $dec = Get-WtAttendanceSummary (& $d '2026-12-01') $entries
    Assert-WtTest '업무외 월 귀속: 90분 전부 시작한 11월, 12월은 0건' ($nov.OverMinutes -eq 90 -and $nov.OverCount -eq 1 -and $dec.OverCount -eq 0)
    $r = Save-WtAttendanceItem $r.Store @{ kind = 'overtime'; start = @{ date = '2026-11-10'; time = '09:00' }; overtime = @{ how = 'remote'; ref = 'CHG-0001' } } -At '2026-12-02T09:00:00+09:00'
    $r = Save-WtAttendanceItem $r.Store @{ kind = 'overtime'; start = @{ date = '2026-11-11'; time = '09:00' } } -At '2026-12-02T09:00:00+09:00'
    $ambiguous = Stop-WtAttendanceRecord $r.Store -Kind overtime -At '2026-11-11T10:00:00+09:00'
    $earlier = Stop-WtAttendanceRecord $r.Store -Kind overtime -Id $r.Id -At '2026-11-10T10:00:00+09:00'
    $tooLong = Save-WtAttendanceItem $r.Store @{ end = @{ date = '2026-12-13'; time = '09:00' } } -Id $r.Id -At '2026-12-13T09:00:00+09:00'
    Assert-WtTest '업무외 입력 거부: 열린 두 기록 선택 · 끝 역행 · 31일 초과는 이유로' (-not $ambiguous.Success -and $ambiguous.Reason -and -not $earlier.Success -and $earlier.Reason -and -not $tooLong.Success -and $tooLong.Reason)
    $r = Stop-WtAttendanceRecord $r.Store -Kind overtime -Id $r.Id -At '2026-11-11T10:00:00+09:00'
    Assert-WtTest '업무외 끝: Id를 고르면 그 기록 하나만 닫음' ($r.Success -and @($r.Store.Items | Where-Object { $_.kind -eq 'overtime' -and $null -eq $_.end }).Count -eq 1) $r.Reason
    $r = Set-WtAttendanceDeleted $r.Store $r.Id -At '2026-12-02T09:00:00+09:00'
    $r = Set-WtAttendanceDeleted $r.Store $r.Id -Deleted $false -At '2026-12-03T09:00:00+09:00'
    Assert-WtTest '근태 편집: 지운 표시 · 되살리기' ($r.Success -and -not (Test-WtDeleted @($r.Store.Items | Where-Object id -ceq $r.Id)[0])) $r.Reason
    $calendar = Get-WtAttendanceCalendarItems (& $d '2026-11-30') (& $d '2026-12-01') @(foreach ($i in $r.Store.Items) { ConvertFrom-WtAttendanceItem $i })
    Assert-WtTest '근태 달력: 월을 넘는 업무외는 두 날, 스타일은 쓰임새 이름' (((@($calendar).Date | ForEach-Object { ConvertTo-WtDateText $_ }) -join ',') -eq '2026-11-30,2026-12-01' -and
        @($calendar | Where-Object Style -cne 'Att.Over').Count -eq 0)
    $workCalendarEntries = @(foreach ($json in @(
        '{"id":"work-closed","kind":"work","start":{"date":"2026-10-27","time":"09:02"},"end":{"date":"2026-10-27","time":"18:10"}}',
        '{"id":"work-open","kind":"work","start":{"date":"2026-10-27","time":"09:02"},"end":null}')) {
        ConvertFrom-WtAttendanceItem ($json | ConvertFrom-Json -DateKind String)
    })
    $workCalendar = @(Get-WtAttendanceCalendarItems (& $d '2026-10-27') (& $d '2026-10-27') $workCalendarEntries)
    Assert-WtTest '근태 달력 퇴근 있음: 근무 시작–끝(en dash) · 다른 칸 유지' ($workCalendar.Count -eq 2 -and
        $workCalendar[0].Text -ceq '근무 09:02–18:10' -and $workCalendar[0].Date -eq (& $d '2026-10-27') -and
        $workCalendar[0].Kind -ceq 'work' -and $workCalendar[0].Style -ceq 'Att.Work' -and -not $workCalendar[0].AllDay -and
        $workCalendar[0].Time -ceq '09:02' -and $workCalendar[0].Id -ceq 'work-closed' -and $workCalendar[0].Page -ceq 'attendance')
    Assert-WtTest '근태 달력 퇴근 없음: 근무 시작만 · 다른 칸 유지' ($workCalendar[1].Text -ceq '근무 09:02' -and
        $workCalendar[1].Date -eq (& $d '2026-10-27') -and $workCalendar[1].Kind -ceq 'work' -and
        $workCalendar[1].Style -ceq 'Att.Work' -and -not $workCalendar[1].AllDay -and $workCalendar[1].Time -ceq '09:02' -and
        $workCalendar[1].Id -ceq 'work-open' -and $workCalendar[1].Page -ceq 'attendance')

    $reportItems = @(
        '{"id":"w","kind":"work","start":{"date":"2028-02-29","time":"08:00"},"end":null,"note":"미완료"}',
        '{"id":"o","kind":"overtime","start":{"date":"2028-02-29","time":"23:30"},"end":{"date":"2028-03-01","time":"01:00"},"overtime":{"how":"remote","ref":"INC-0002"},"note":"=1+1\n두 줄"}',
        '{"id":"l","kind":"leave","start":{"date":"2028-02-25","time":null},"end":{"date":"2028-02-29","time":null},"leave":{"type":"half-am","days":null}}',
        '{"id":"f","kind":"leave","start":{"date":"2028-02-28","time":null},"leave":{"type":"half-pm","days":1.25}}',
        '{"id":"t","kind":"trip","start":{"date":"2028-02-26","time":null},"end":{"date":"2028-02-29","time":null},"place":"시험 출장지"}'
    ) | ForEach-Object { $_ | ConvertFrom-Json -DateKind String }
    $reportEntries = @(foreach ($i in $reportItems) { ConvertFrom-WtAttendanceItem $i })
    $reportOff = [Collections.Generic.HashSet[string]]::new([string[]]@('2028-02-28', '2028-02-29'))
    $expectedReport = @(
        "종류`t시작일`t시작시각`t종료일`t종료시각`t분`t휴가일수`t산정`t장소`t방식`t관련번호`t메모`t상태",
        "휴가`t2028-02-25`t`t2028-02-29`t`t`t0.5`t잠정`t`t`t`t`t",
        "출장`t2028-02-26`t`t2028-02-29`t`t`t`t`t시험 출장지`t`t`t`t",
        "휴가`t2028-02-28`t`t`t`t`t1.25`t확정`t`t`t`t`t",
        "출근`t2028-02-29`t08:00`t`t`t`t`t`t`t`t`t미완료`t퇴근 기록 없음",
        "업무외`t2028-02-29`t23:30`t2028-03-01`t01:00`t90`t`t`t`t원격`tINC-0002`t'=1+1 두 줄`t"
    ) -join "`r`n"
    $thread = [Threading.Thread]::CurrentThread; $oldCulture = $thread.CurrentCulture
    $snapshots = @()
    try {
        foreach ($culture in 'ko-KR', 'en-US', 'th-TH', 'ar-SA', 'ja-JP') {
            $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
            $report = Get-WtAttendanceReport (& $d '2028-02-01') $reportEntries $reportOff 'workdays'
            $snapshots += $report.Text
            Assert-WtTest "근태 2a $culture : 윤일 · 반차와 휴무일 · 확정 일수 · 출장 건수/근무일 규칙" ($report.Summary.LeaveEstimated -eq 0.5 -and
                $report.Summary.LeaveFixed -eq 1.25 -and $report.Summary.TripCount -eq 1 -and $report.Summary.TripDays -eq 0 -and $report.Summary.OverMinutes -eq 90)
        }
    } finally { $thread.CurrentCulture = $oldCulture }
    Assert-WtTest '월 보고: 5개 문화권 모두 못 박은 탭 구분 글 (CRLF · 빈 칸 · 미완료 · 수식 방지)과 정확히 같음' (@($snapshots | Where-Object { $_ -cne $expectedReport }).Count -eq 0) $snapshots[0]
    $march = Get-WtAttendanceReport (& $d '2028-03-01') $reportEntries $reportOff
    Assert-WtTest '월 보고: 달 넘는 업무외는 시작 달에만, 다음 달 빈 보고는 제목 한 줄' ($march.Rows -eq 0 -and $march.Text -ceq ($expectedReport -split "`r`n")[0])
    $onlyHoliday = ConvertFrom-WtAttendanceItem ('{"id":"h","kind":"leave","start":{"date":"2028-02-29","time":null},"leave":{"type":"half-pm","days":null}}' | ConvertFrom-Json -DateKind String)
    Assert-WtTest '휴가: 휴무일 하루의 반차는 0일' ((Get-WtAttendanceSummary (& $d '2028-02-01') @($onlyHoliday) $reportOff).LeaveDays -eq 0)
    $calendarResult = Get-WtCalendarItems (& $d '2026-11-30') (& $d '2026-12-01')
    Assert-WtTest '근태 달력 등록: 코어 목록만 조회해도 근태 출처의 두 날짜를 받음' ($calendarResult.Success -and @($calendarResult.Items | Where-Object Page -ceq 'attendance').Count -eq 2) $calendarResult.Reason

    if (Test-WtTestWpf) {
        $test = New-WtTestData 'attendance-view'; $tests.Add($test)
        Copy-WtTestFixture 'v2-travel.json'; Copy-WtTestHolidays
        $module = Get-Module Attendance
        & $module { $script:month = [datetime]::new(2026,11,1) }
        $view = New-WtTestView 'attendance'
        $view.Measure([Windows.Size]::new(1080,616)); $view.Arrange([Windows.Rect]::new(0,0,1080,616)); $view.UpdateLayout()
        & $module { Update-WtAttendanceView; $script:testFirst = $script:table.ItemsSource; Update-WtAttendanceView }
        Assert-WtTest '근태 화면: 같은 월과 데이터는 표 재사용' (& $module { [object]::ReferenceEquals($script:testFirst, $script:table.ItemsSource) })
        Assert-WtTest '근태 표: 날짜순 8열·U14 폭·행 32·— 장소' (& $module {
            ($script:table.Columns | ForEach-Object Header) -join ',' -ceq '날짜,종류,시작,끝,장소,이동,시간,메모' -and
            ($script:table.Columns | Select-Object -First 7 | ForEach-Object { $_.Width.Value }) -join ',' -ceq '90,80,64,64,72,56,64' -and
            $script:table.RowHeight -eq 32 -and @($script:table.ItemsSource | Where-Object { $_.Entry.Id -ceq 'weekend-unknown' -and $_.Place -ceq '—' }).Count -eq 1
        })
        Assert-WtTest '근태 요약: 장소 없음·퇴근 기록 없음 표시, 기존 홈 카드 등록 없음' ((Get-WtTestTexts $view) -contains '장소 없음' -and (Get-WtTestTexts $view) -contains '퇴근 기록 없음' -and -not (Get-WtAddon -Id attendance).HomeCard)
        & $module { $entry = @($script:data.Entries | Where-Object Id -ceq 'weekend-unknown')[0]; Show-WtAttForm $entry; $script:form.Fields.note.Text = '메모만 변경'; Save-WtAttForm }
        $unknown = @((Get-WtAttendanceData).Items | Where-Object id -ceq 'weekend-unknown')[0]
        Assert-WtTest '편집: 메모만 고치면 how=null·기존 이동 보존' ($null -eq $unknown.overtime.how -and $unknown.travel.out -eq 20 -and $unknown.travel.back -eq 5)
        & $module { $entry = @($script:data.Entries | Where-Object Id -ceq 'weekend-unknown')[0]; Show-WtAttForm $entry; $script:form.Fields.place.SelectedItem = '원격'; Save-WtAttForm }
        $changed = Get-WtAttendanceSummary $november (Get-WtAttendanceData).Entries $travelOff
        Assert-WtTest '편집: 장소 선택은 해당 기록만 원격으로 재분류 (Unknown 0 · Remote 510)' ($changed.OvertimeUnknown -eq 0 -and $changed.OvertimeRemote -eq 510)
        Assert-WtTest '요약: 장소 없음 0이면 숨김' ((Get-WtTestTexts $view) -notcontains '장소 없음')
        Assert-WtTest '표: 취소 후 같은 선택 행을 다시 클릭해도 편집 폼을 연다' (& $module {
            $script:table.SelectedItem = $script:table.ItemsSource[0]; Show-WtAttSummary
            $script:view.Root.UpdateLayout()
            $row = $script:table.ItemContainerGenerator.ContainerFromIndex(0)
            $mouse = [Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)
            $mouse.RoutedEvent = [Windows.Input.Mouse]::PreviewMouseUpEvent
            $row.RaiseEvent($mouse)
            $script:form -and $script:form.Entry.Id -ceq $script:table.ItemsSource[0].Entry.Id
        })
        Assert-WtTest '직접 입력: 선택 달의 1일과 빈 시작·끝·이동·메모로 연다' (& $module {
            Show-WtAttForm
            $script:form.Fields.date.Text -ceq '2026-11-01' -and $script:form.Fields.start.Text -ceq '' -and $script:form.Fields.end.Text -ceq '' -and
                $script:form.Fields.out.Text -ceq '' -and $script:form.Fields.back.Text -ceq '' -and $script:form.Fields.note.Text -ceq ''
        })
        $beforeBad = [IO.File]::ReadAllText((Get-WtStorePath 'attendance'))
        & $module { Show-WtAttForm; $script:form.Fields.date.Text = '2026-11-12'; $script:form.Fields.start.Text = '18:00'; $script:form.Fields.end.Text = '09:00'; Save-WtAttForm }
        Assert-WtTest '폼: 이른 끝은 해당 칸 아래 오류·저장 안 함' ((Get-WtTestTexts $view) -contains '끝이 시작보다 이릅니다.' -and (& $module { [Windows.Controls.Validation]::GetHasError($script:form.Fields.end) }) -and [IO.File]::ReadAllText((Get-WtStorePath 'attendance')) -ceq $beforeBad)
        & $module { $script:form.Fields.next.IsChecked = $true; Save-WtAttForm }
        Assert-WtTest '폼: 다음 날 체크로 밤샘 직접 입력 저장' (@((Get-WtAttendanceData).Entries | Where-Object { $_.StartDate -eq [datetime]::new(2026,11,12) -and $_.Minutes -eq 900 }).Count -eq 1)
        & $module { $script:month = $script:month.AddMonths(-1); $script:form = $null; Update-WtAttendanceView }
        Assert-WtTest '근태 화면: 달 이동 후 이전 달 자료·0인 미퇴근 줄 숨김' ((Get-WtTestTexts $view) -notcontains '퇴근 기록 없음' -and (& $module { $script:table.ItemsSource.Count -eq 1 }))
        [IO.File]::WriteAllText((Get-WtStorePath 'attendance'), '{ "schema": 3, "items": [] }', [Text.UTF8Encoding]::new($false))
        & $module { $script:viewKey = $null; Update-WtAttendanceView }
        Assert-WtTest '못 읽는 파일: 쓰기 버튼 비활성·이유 툴팁, 빈 화면 유지' (& $module { -not $script:view.new.IsEnabled -and $script:table.ToolTip -like '*더 새 버전*' })
    }
} finally {
    foreach ($t in $tests) { Remove-WtTestData $t }
}

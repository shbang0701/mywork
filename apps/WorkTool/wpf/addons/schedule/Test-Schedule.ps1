<#
.SYNOPSIS
    일정 탭을 임시 데이터로 검사한다: 형식 · schema 이전 · 모르는 값 보존 · 예전 데이터 가져오기(합치기) · 반복 펼치기 · 화면.

.DESCRIPTION
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.
    고정 시험 자료(fixtures\)는 더하기만 하고 고치지 않는다. 형식을 바꾸면 옛 자료는 그대로 두고 새 자료를 더한다.
    그래야 예전에 쓴 파일이 계속 읽히는지 늘 확인된다. 모두 가짜 값이다.
      legacy.csv      예전 WinForms schedule.csv (BOM 붙은 UTF-8). Excel이 바꾼 날짜 · 시각, 모르는 반복, 깨진 줄, id 없는 줄
      v1.json         1단계 WPF가 쓴 schema 1
      v2.json         schema 2 대표 예 (매월 31일 · 둘째 화요일 · 말일 · 2월 29일 · 격주 · 건너뛰기 · 한 회차 바꿈 · 자정 넘김 · 지운 항목)
      v2-future.json  더 새 앱이 쓴 schema 2 흉내 (모르는 맨 위 키 · 칸 · kind · freq · 요일 코드 · 알람 모양)
      legacy-dup.csv  대소문자만 다른 id · 같은 id 둘째 줄 · 완전히 같은 줄 (2026-10-26 검토 반례)
      v1-bad-end.json schema 1의 읽지 못하는 끝 값 · null 항목 · 1단계에만 있던 칸 · Int32보다 큰 알람
      v2-edge.json    null 항목 · 범위를 넘는 정수(Int32 · Int64 · BigInteger) · 범위 밖 날짜 · 소수 알람 · rev
      legacy-same.csv id와 내용까지 같은 두 줄 (재확인 반례)
      v1-raw-items.json  items 안의 목록 · 빈 목록 · null · 글 항목
      v2-edge-float.json 1e-30 · 1.0000000000000002 · 10.0 · 꺼진 알람(before null)
    기대 값(회차 목록 등)은 여기에 못 박아 둔다. 규칙을 바꿔 값이 바뀌면 이 파일을 일부러 고쳐야 한다.

.EXAMPLE
    pwsh -NoProfile -File apps/WorkTool/wpf/addons/schedule/Test-Schedule.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'ScheduleData.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Schedule.psm1') -Force -DisableNameChecking
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$d = { param($t) [datetime]::ParseExact($t, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
$tests = [System.Collections.Generic.List[object]]::new()

function Copy-WtTestFixture([string]$Name) { [System.IO.File]::Copy((Join-Path $fixtures $Name), (Get-WtStorePath 'schedule'), $true) }
function Read-WtTestDoc { [System.IO.File]::ReadAllText((Get-WtStorePath 'schedule')) | ConvertFrom-Json -Depth 20 -DateKind String }
function Get-WtTestKeys($Occurrences) { (@($Occurrences) | ForEach-Object { $_.Key }) -join ',' }
function Get-WtTestJson($Value) { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }
function Get-WtTestById($Entries) { $m = @{}; foreach ($e in @($Entries)) { if ($e.Id -and -not $m.ContainsKey($e.Id)) { $m[$e.Id] = $e } }; $m }
function ConvertTo-WtTestItem([string]$Json) { $Json | ConvertFrom-Json -Depth 20 -DateKind String }

try {
    # ---- 예전 CSV (legacy.csv) ----
    $test = New-WtTestData 'schedule'; $tests.Add($test)
    [void][System.IO.Directory]::CreateDirectory($test.Legacy)
    [System.IO.File]::Copy((Join-Path $fixtures 'legacy.csv'), (Join-Path $test.Legacy 'schedule.csv'))
    $r = Import-WtLegacyData
    Assert-WtTest '일정: 예전 CSV를 가져온다 (깨진 줄 · id 없는 줄도 버리지 않음)' ($r.Count -eq 8 -and $r.Tabs.Count -eq 1) "($($r.Count) / $($r.Tabs -join ', '))"
    $data = Get-WtScheduleData
    $byId = Get-WtTestById $data.Entries
    $doc = Read-WtTestDoc
    Assert-WtTest '일정: 가져온 파일은 schema 2 · 가져온 위치 · CSV 해시를 남긴다' ($doc.schema -eq 2 -and $doc.importedFrom -eq $test.Legacy -and $doc.legacy.sha256.Length -eq 64 -and $doc.legacy.encoding -eq 'utf-8' -and $doc.legacy.rows -eq 8) "($($doc.schema) · $($doc.importedFrom) · $($doc.legacy.rows))"
    Assert-WtTest '일정: 가져온 항목은 원본 줄을 origin에 남기고, 울린 알람은 데이터에 넣지 않는다' (
        -not @($doc.items | Where-Object { $_.origin.from -ne 'winforms-csv' -or $null -eq $_.origin.row }).Count -and
        $doc.items[0].origin.row.LastAlarm -eq '2026-10-22 09:30' -and -not ($doc.items[0].PSObject.Properties.Name -contains 'lastAlarm'))
    $s1 = $byId.s1
    Assert-WtTest '일정: weekly → 매주 시작일 요일, 알람 → [{ before }]' ($s1.State -eq 'ok' -and $s1.Repeat.Freq -eq 'weekly' -and ($s1.Repeat.Days -join ',') -eq 'Thursday' -and ($s1.Alarms -join ',') -eq '10' -and $s1.Start -eq (& $d '2026-10-01').AddHours(9.5))
    Assert-WtTest '일정: Excel이 바꾼 날짜 · 시각(2026/10/1 · 9:30 · 2026. 10. 30. · 오후 2:30)을 읽는다' (
        $byId.s2.State -eq 'ok' -and $byId.s2.Item.start.date -eq '2026-10-01' -and $byId.s2.Item.start.time -eq '09:30' -and
        $byId.s5.Item.start.date -eq '2026-10-30' -and $byId.s5.Item.start.time -eq '14:30' -and ($byId.s5.Alarms -join ',') -eq '60')
    Assert-WtTest '일정: weekdays → 매주 월~금, daily → 매일, 쉼표 · 따옴표 · 여러 줄 메모' (
        ($byId.s2.Repeat.Days -join ',') -eq 'Monday,Tuesday,Wednesday,Thursday,Friday' -and $byId.s4.Repeat.Freq -eq 'daily' -and ($byId.s4.Alarms -join ',') -eq '0' -and
        $byId.s2.Note -eq '쉼표, 따옴표 "확인"' -and ($byId.s3.Note -replace "`r`n", "`n") -eq "첫 줄`n둘째 줄" -and $byId.s3.AllDay)
    Assert-WtTest '일정: 모르는 반복 값은 읽기 전용, 깨진 날짜는 고칠 항목(원래 글을 남김)' (
        $byId.s6.State -eq 'readonly' -and $byId.s7.State -eq 'broken' -and $byId.s7.Problem -like '*날짜*' -and $byId.s7.Item.start.date -eq '내일' -and $byId.s7.Item.origin.row.Date -eq '내일')
    $noId = @($data.Entries | Where-Object { $_.Id -like 'csv-*' })
    Assert-WtTest '일정: id 없는 줄은 줄 내용으로 정한 id를 받는다' ($noId.Count -eq 1 -and $noId[0].State -eq 'ok' -and $noId[0].Title -eq 'id 없는 줄')
    $order = (@((Get-WtScheduleDays $data.Entries (& $d '2026-10-22') 1)[0]) | ForEach-Object { $_.Entry.Id }) -join ','
    Assert-WtTest '일정: 하루 일정은 시각 순서, 같은 시각이면 제목 순서 (08:00 매일 점검 · 09:30 백업 확인 · 09:30 주간 회의)' ($order -eq 's4,s2,s1') $order

    # ---- 다시 가져오기: 덮어쓰지 않고 합친다 ----
    $noIdKey = $noId[0].Id
    $r2 = Import-WtLegacyData -Force
    $m = Get-WtScheduleLastImport
    Assert-WtTest '일정 합치기: 그대로인 CSV는 아무것도 바꾸지 않고, id 없는 줄도 같은 id' ($r2.Count -eq 0 -and $m.Unchanged -eq 8 -and (Get-WtTestById (Get-WtScheduleData).Entries).ContainsKey($noIdKey))
    $data = Get-WtScheduleData
    $items = @($data.Items)
    foreach ($i in $items) {
        if ($i.id -eq 's1') { $i.title = '이 앱에서 고친 제목'; Set-WtItemEdited $i }
        if ($i.id -eq 's4') { $i.deleted = Get-WtStamp; Set-WtItemEdited $i }
    }
    Save-WtScheduleItems $data.Store $items
    $csv = [System.IO.File]::ReadAllText((Join-Path $fixtures 'legacy.csv'))
    $csv = $csv.Replace('"s1","2026-10-01","09:30","주간 회의"', '"s1","2026-10-01","09:30","예전 앱에서 고친 제목"')
    $csv = $csv.Replace('"쉼표, 따옴표 ""확인"""', '"예전 앱에서 고친 메모"')
    $csv = [regex]::Replace($csv, '"s3".*?둘째 줄","","","",""\r?\n', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    $csv += '"s9","2026-11-03","13:00","새로 더한 줄","","","","",""' + "`r`n"
    Write-WtTestLegacyCsv $test 'schedule' $csv
    $r3 = Import-WtLegacyData -Force
    $m = Get-WtScheduleLastImport
    $after = Get-WtTestById (Get-WtScheduleData).Entries
    Assert-WtTest '일정 합치기: 새 줄은 더하고, 예전 앱에서만 바뀐 줄은 새 값으로' ($r3.Count -eq 2 -and $m.Added -eq 1 -and $m.Updated -eq 1 -and $after.s9.Title -eq '새로 더한 줄' -and $after.s2.Note -eq '예전 앱에서 고친 메모') "($($r3.Count) · 더함 $($m.Added) · 바꿈 $($m.Updated))"
    Assert-WtTest '일정 합치기: 이 앱에서 고친 항목은 두고 충돌로 알리고, 지운 항목은 되살리지 않는다' (
        $after.s1.Title -eq '이 앱에서 고친 제목' -and ($m.Conflicts -join ',') -eq 's1' -and $after.s4.State -eq 'deleted' -and $m.KeptDeleted -eq 1)
    Assert-WtTest '일정 합치기: 예전 CSV에서 없어진 항목은 지우지 않고 알리기만' ($after.s3.State -eq 'ok' -and ($m.Missing -join ',') -eq 's3')

    # ---- 1단계 WPF 파일 (v1.json) → schema 2 ----
    $test = New-WtTestData 'schedule-v1'; $tests.Add($test)
    Copy-WtTestFixture 'v1.json'
    $original = [System.IO.File]::ReadAllBytes((Get-WtStorePath 'schedule'))
    $data = Get-WtScheduleData
    $byId = Get-WtTestById $data.Entries
    $doc = Read-WtTestDoc
    $backups = @(Get-ChildItem -LiteralPath $test.Data -Filter 'schedule.json.schema1.*.bak')
    Assert-WtTest '일정 이전: schema 1을 읽으면 2로 올려 쓰고, 맨 위 키를 잃지 않는다' (-not $data.Error -and $doc.schema -eq 2 -and $doc.importedFrom -eq 'C:\WorkTool\data' -and $doc._fixture -like '고정 시험 자료*' -and @($data.Entries | Where-Object State -eq 'ok').Count -eq 5) "$($data.Error)"
    Assert-WtTest '일정 이전: 바꾸기 전 원본을 날짜 붙은 백업으로 그대로 남긴다' ($backups.Count -eq 1 -and $backups[0].Name -match '^schedule\.json\.schema1\.\d{8}-\d{6}\.bak$' -and
        [Convert]::ToHexString([System.IO.File]::ReadAllBytes($backups[0].FullName)) -eq [Convert]::ToHexString($original))
    Assert-WtTest '일정 이전: 날짜처럼 보이는 글은 글 그대로 (자동 [datetime] 변환 없음)' ($byId.s3.Note -ceq '2026-10-25T21:54:29' -and $doc.items[2].note -ceq '2026-10-25T21:54:29')
    Assert-WtTest '일정 이전: 기간 · 태그 · 모르는 칸을 옮기고, origin은 예전 CSV 줄 모양' (
        $byId.s8.AllDay -and $byId.s8.LastDay -eq (& $d '2026-11-03') -and ($byId.s8.Tags -join ',') -eq '교육' -and $byId.s8.Item.color -eq '모르는 칸' -and
        $byId.s1.Item.origin.via -eq 'schema1' -and $byId.s1.Item.origin.row.Alarm -eq '10' -and $byId.s1.Item.origin.row.Date -eq '2026-10-01' -and $byId.s1.Item.updated -eq $byId.s1.Item.origin.at)
    $null = Get-WtScheduleData
    Assert-WtTest '일정 이전: 한 번만 바꾸고 백업도 하나' (@(Get-ChildItem -LiteralPath $test.Data -Filter 'schedule.json.schema1.*.bak').Count -eq 1)
    [void][System.IO.Directory]::CreateDirectory($test.Legacy)
    [System.IO.File]::Copy((Join-Path $fixtures 'legacy.csv'), (Join-Path $test.Legacy 'schedule.csv'))
    [void](Import-WtLegacyData -Force)
    $m = Get-WtScheduleLastImport
    Assert-WtTest '일정 이전: 올린 뒤 예전 CSV를 다시 가져와도 같은 줄은 그대로 (s1 · s4), 1단계에만 있던 항목은 알리기만 (s8)' (
        $m.Unchanged -eq 2 -and $m.Updated -eq 2 -and $m.Added -eq 4 -and ($m.Missing -join ',') -eq 's8') "(그대로 $($m.Unchanged) · 바꿈 $($m.Updated) · 더함 $($m.Added) · 없어짐 $($m.Missing -join ','))"

    # ---- schema 2 대표 예 (v2.json) ----
    $test = New-WtTestData 'schedule-v2'; $tests.Add($test)
    Copy-WtTestFixture 'v2.json'
    $original = [System.IO.File]::ReadAllBytes((Get-WtStorePath 'schedule'))
    $data = Get-WtScheduleData
    $byId = Get-WtTestById $data.Entries
    $states = (@($data.Entries) | ForEach-Object { $_.State } | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    Assert-WtTest '일정 v2: 모두 읽힌다 (지운 항목 2 · 나머지 계산 가능), 읽기만 해서는 파일을 바꾸지 않는다' ($states -eq 'deleted=2 ok=9' -and
        [Convert]::ToHexString([System.IO.File]::ReadAllBytes((Get-WtStorePath 'schedule'))) -eq [Convert]::ToHexString($original)) $states
    $keys = Get-WtTestKeys (Get-WtScheduleOccurrences $data.Entries (& $d '2026-10-26') (& $d '2026-11-15'))
    $expected = 'a1b2c3d4e5f6@2026-10-28,s1@2026-10-29,c6c2c3d4e5f6@2026-10-30,c1c2c3d4e5f6@2026-10-31,c3c2c3d4e5f6@2026-10-31,b1b2c3d4e5f6@2026-11-02,c5c2c3d4e5f6@2026-11-02,c5c2c3d4e5f6@2026-11-04,s1@2026-11-05,c2c2c3d4e5f6@2026-11-10'
    Assert-WtTest '일정 v2: 3주 회차 목록 (기간 · 반복 · 건너뛰기 · 한 회차 바꿈 · 자정 넘김)' ($keys -eq $expected) $keys
    $dates = { param($id, $from, $to) (@((Get-WtScheduleOccurrences @($byId[$id]) (& $d $from) (& $d $to))) | ForEach-Object { $_.Start.ToString('yyyy-MM-dd', $inv) }) -join ',' }
    Assert-WtTest '일정 v2: 매월 31일은 31일이 없는 달을 건너뛴다' ((& $dates 'c1c2c3d4e5f6' '2026-01-01' '2027-12-31') -eq '2026-01-31,2026-03-31,2026-05-31,2026-07-31,2026-08-31,2026-10-31,2026-12-31')
    Assert-WtTest '일정 v2: 둘째 화요일 6회 (count)' ((& $dates 'c2c2c3d4e5f6' '2026-01-01' '2027-12-31') -eq '2026-10-13,2026-11-10,2026-12-08,2027-01-12,2027-02-09,2027-03-09')
    Assert-WtTest '일정 v2: 말일(monthDay -1)' ((& $dates 'c3c2c3d4e5f6' '2026-10-01' '2027-03-31') -eq '2026-10-31,2026-11-30,2026-12-31,2027-01-31,2027-02-28,2027-03-31')
    Assert-WtTest '일정 v2: 2월 29일 매년은 윤년에만' ((& $dates 'c4c2c3d4e5f6' '2024-01-01' '2032-12-31') -eq '2024-02-29,2028-02-29,2032-02-29')
    Assert-WtTest '일정 v2: 격주 월 · 수, 끝나는 날 포함' ((& $dates 'c5c2c3d4e5f6' '2026-10-01' '2026-12-31') -eq '2026-10-05,2026-10-07,2026-10-19,2026-10-21,2026-11-02,2026-11-04,2026-11-16,2026-11-18,2026-11-30')
    $moved = @(Get-WtScheduleOccurrences @($byId.s1) (& $d '2026-11-06') (& $d '2026-11-06'))
    Assert-WtTest '일정 v2: 다른 날로 옮긴 회차는 옮긴 날에, 바꾼 칸만 바뀐다' ($moved.Count -eq 1 -and $moved[0].Key -eq 's1@2026-11-05' -and $moved[0].Changed -and
        $moved[0].Start -eq (& $d '2026-11-06').AddHours(10) -and $moved[0].Note -eq '목요일 휴무로 금요일에' -and $moved[0].Title -eq '주간 회의' -and
        -not @(Get-WtScheduleOccurrences @($byId.s1) (& $d '2026-11-05') (& $d '2026-11-05')).Count)
    $days = Get-WtScheduleDays $data.Entries (& $d '2026-10-30') 3
    $daysText = (@($days | ForEach-Object { (@($_) | ForEach-Object { $_.Entry.Id.Substring(0, 2) }) -join '+' }) -join ' | ')
    Assert-WtTest '일정 v2: 날마다 목록 (자정을 넘긴 일정은 다음 날에도, 하루 종일 · 이어진 일정이 먼저)' ($daysText -eq 'c6 | c1+c6+c3 | ') $daysText
    $span = Get-WtScheduleDays @($byId.b1b2c3d4e5f6) (& $d '2026-11-01') 5
    Assert-WtTest '일정 v2: 하루 종일 기간 일정은 걸친 날마다' ((@($span | ForEach-Object { @($_).Count }) -join ',') -eq '0,1,1,1,0')

    # ---- 더 새 앱이 쓴 파일 (v2-future.json) ----
    $test = New-WtTestData 'schedule-future'; $tests.Add($test)
    Copy-WtTestFixture 'v2-future.json'
    $before = [System.IO.File]::ReadAllText((Get-WtStorePath 'schedule')) | ConvertFrom-Json -Depth 20 -DateKind String
    $data = Get-WtScheduleData
    $byId = Get-WtTestById $data.Entries
    Assert-WtTest '일정 새 버전: 모르는 kind · freq · 요일 코드는 읽기 전용, 모르는 칸 · 알람 모양만 있으면 그대로 쓴다' (
        -not $data.Error -and $byId.f1f2f3f4f5f6.State -eq 'ok' -and ($byId.f1f2f3f4f5f6.Alarms -join ',') -eq '5' -and
        $byId.f2f2f3f4f5f6.State -eq 'readonly' -and $byId.f3f2f3f4f5f6.State -eq 'readonly' -and $byId.f4f2f3f4f5f6.State -eq 'readonly' -and $byId.f5f2f3f4f5f6.State -eq 'ok')
    $occ = @(Get-WtScheduleOccurrences $data.Entries (& $d '2026-10-26') (& $d '2026-11-08'))
    Assert-WtTest '일정 새 버전: 읽기 전용 항목은 회차(계산 · 알람)에서 빠진다' ((Get-WtTestKeys $occ) -eq 'f5f2f3f4f5f6@2026-10-26,f1f2f3f4f5f6@2026-10-29,f5f2f3f4f5f6@2026-11-02' -and
        $occ[2].Title -eq '바뀐 제목') (Get-WtTestKeys $occ)
    $items = @($data.Items)
    $items[0].title = '이 앱에서 고친 제목'
    Save-WtScheduleItems $data.Store $items
    $saved = Read-WtTestDoc
    $sameOthers = $true
    for ($i = 1; $i -lt $before.items.Count; $i++) { if ((Get-WtTestJson $before.items[$i]) -cne (Get-WtTestJson $saved.items[$i])) { $sameOthers = $false } }
    Assert-WtTest '일정 새 버전: 한 항목을 고쳐 저장해도 모르는 맨 위 키 · 칸 · 항목이 그대로' (
        (Get-WtTestJson $saved.sync) -ceq (Get-WtTestJson $before.sync) -and $saved._fixture -ceq $before._fixture -and $saved.items.Count -eq $before.items.Count -and $sameOthers -and
        $saved.items[0].title -eq '이 앱에서 고친 제목' -and $saved.items[0].color -eq '#C00000' -and $saved.items[0].location.room -eq '3층 회의실' -and
        $saved.items[0].start.zone -eq 'Asia/Seoul' -and $saved.items[0].alarms[1].at -ceq '2026-10-29T08:00' -and $saved.items[0].alarms[0].sound -eq 'chime')

    # ---- 규칙 하나씩 (고칠 항목 · 횟수 · 끝나는 날) ----
    $base = '"id": "x", "kind": "event", "title": "x", "note": "", "alarms": [], "tags": []'
    $cases = [ordered]@{
        '끝나는 날과 횟수 둘 다' = "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": null }, ""end"": null, ""repeat"": { ""freq"": ""daily"", ""until"": ""2026-10-05"", ""count"": 3 } }"
        '끝이 시작보다 이름' = "{ $base, ""start"": { ""date"": ""2026-10-02"", ""time"": ""10:00"" }, ""end"": { ""date"": ""2026-10-01"", ""time"": ""11:00"" } }"
        '한쪽에만 시각' = "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": ""10:00"" }, ""end"": { ""date"": ""2026-10-02"", ""time"": null } }"
        '글로 쓴 알람' = "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": ""10:00"" }, ""end"": null, ""alarms"": [ { ""before"": ""10"" } ] }"
        '매주에 monthDay' = "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": null }, ""end"": null, ""repeat"": { ""freq"": ""weekly"", ""monthDay"": 3 } }"
        '요일 없는 nth' = "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": null }, ""end"": null, ""repeat"": { ""freq"": ""monthly"", ""nth"": 2 } }"
        '없는 날짜' = "{ $base, ""start"": { ""date"": ""2026-02-30"", ""time"": null }, ""end"": null }"
        '24시' = "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": ""24:00"" }, ""end"": null }"
    }
    $wrong = @(foreach ($k in $cases.Keys) { $e = ConvertFrom-WtScheduleItem (ConvertTo-WtTestItem $cases[$k]); if ($e.State -ne 'broken') { "$k=$($e.State)" } })
    Assert-WtTest '일정 규칙: 틀린 값은 고칠 항목' (-not $wrong.Count) ($wrong -join ', ')
    $e = ConvertFrom-WtScheduleItem (ConvertTo-WtTestItem "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": null }, ""end"": null, ""repeat"": { ""freq"": ""daily"", ""interval"": 2, ""count"": 4, ""skip"": [ ""2026-10-03"" ] } }")
    Assert-WtTest '일정 규칙: 횟수는 건너뛴 회차도 센다 (RFC 5545)' ((Get-WtTestKeys (Get-WtScheduleOccurrences @($e) (& $d '2026-09-01') (& $d '2026-12-31'))) -eq 'x@2026-10-01,x@2026-10-05,x@2026-10-07') (Get-WtTestKeys (Get-WtScheduleOccurrences @($e) (& $d '2026-09-01') (& $d '2026-12-31')))
    $e = ConvertFrom-WtScheduleItem (ConvertTo-WtTestItem "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": null }, ""end"": null, ""repeat"": { ""freq"": ""weekly"" } }")
    Assert-WtTest '일정 규칙: 요일 없는 매주는 시작일 요일, 칸이 없어도 기본값' ($e.State -eq 'ok' -and (Get-WtTestKeys (Get-WtScheduleOccurrences @($e) (& $d '2026-10-01') (& $d '2026-10-15'))) -eq 'x@2026-10-01,x@2026-10-08,x@2026-10-15')
    $e = ConvertFrom-WtScheduleItem (ConvertTo-WtTestItem "{ $base, ""start"": { ""date"": ""2026-10-01"", ""time"": ""09:00"" }, ""end"": null, ""repeat"": { ""freq"": ""daily"", ""until"": ""2026-10-03"" } }")
    Assert-WtTest '일정 규칙: 끝나는 날은 그날 포함, 범위가 시작보다 한참 뒤여도 빠르게 건너뛴다' (
        (Get-WtTestKeys (Get-WtScheduleOccurrences @($e) (& $d '2026-09-01') (& $d '2026-12-31'))) -eq 'x@2026-10-01,x@2026-10-02,x@2026-10-03')
    $e = ConvertFrom-WtScheduleItem (ConvertTo-WtTestItem "{ $base, ""start"": { ""date"": ""2000-01-03"", ""time"": ""09:00"" }, ""end"": null, ""repeat"": { ""freq"": ""weekly"", ""interval"": 3, ""days"": [ ""mon"" ] } }")
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $far = Get-WtTestKeys (Get-WtScheduleOccurrences @($e) (& $d '2026-10-01') (& $d '2026-10-31'))
    # 2000-01-03(월)부터 3주마다: 2026-10-05는 1396주째(3의 배수 아님), 2026-10-19가 1398주째
    Assert-WtTest "일정 규칙: 오래전에 시작한 3주마다 반복도 주 간격을 지키고 빠르게 건너뛴다 ($($watch.ElapsedMilliseconds)ms)" ($far -eq 'x@2026-10-19' -and $watch.ElapsedMilliseconds -lt 2000) $far

    # ---- 문화권이 달라도 같은 결과 (날짜 글 · 숫자) ----
    $rows = (Read-WtLegacyCsv $fixtures 'legacy').Rows
    $v2 = (Get-Content -LiteralPath (Join-Path $fixtures 'v2.json') -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 -DateKind String).items
    $snapshot = {
        $converted = Get-WtTestJson @(foreach ($row in $rows) { ConvertFrom-WtScheduleRow $row '2026-10-26T09:00:00+09:00' })
        $entries = @(foreach ($i in $v2) { ConvertFrom-WtScheduleItem $i })
        $occ = (@(Get-WtScheduleOccurrences $entries (& $d '2026-10-01') (& $d '2027-03-31')) | ForEach-Object { "$($_.Key)=$($_.Start.ToString('yyyy-MM-dd HH:mm', $inv))~$($_.End.ToString('yyyy-MM-dd HH:mm', $inv))" }) -join ';'
        "$converted|$occ"
    }
    $thread = [System.Threading.Thread]::CurrentThread
    $oldCulture = $thread.CurrentCulture
    $results = @{}
    try {
        foreach ($c in 'en-US', 'ko-KR', 'th-TH', 'ar-SA') { $thread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($c); $results[$c] = & $snapshot }
    } finally { $thread.CurrentCulture = $oldCulture }
    Assert-WtTest '일정: 문화권(en-US · ko-KR · th-TH 불기 · ar-SA 회교력)이 달라도 가져오기 · 회차가 같다' (@($results.Values | Sort-Object -Unique).Count -eq 1)


    # ---- 2026-10-26 검토 반례 (고치기 전에는 모두 틀렸다) ----
    # 1 · 2: 다시 가져오기는 바뀐 예전 칸이 정하는 경로만 옮기고(중첩 칸 · 앱 고유 칸 보존), 같은 초에 고친 것도 rev로 알아본다
    $test = New-WtTestData 'schedule-merge'; $tests.Add($test)
    [void][System.IO.Directory]::CreateDirectory($test.Legacy)
    [System.IO.File]::Copy((Join-Path $fixtures 'legacy.csv'), (Join-Path $test.Legacy 'schedule.csv'))
    [void](Import-WtLegacyData)
    $doc = Read-WtTestDoc
    foreach ($i in $doc.items) {
        if ($i.id -eq 's2') { $i.start | Add-Member -NotePropertyName zone -NotePropertyValue 'Asia/Seoul'; $i.origin | Add-Member -NotePropertyName line -NotePropertyValue 3
            $i | Add-Member -NotePropertyName color -NotePropertyValue 'blue'; $i.repeat | Add-Member -NotePropertyName byHour -NotePropertyValue @(9) }
    }
    [System.IO.File]::WriteAllText((Get-WtStorePath 'schedule'), (ConvertTo-Json $doc -Depth 20), [System.Text.UTF8Encoding]::new($false))
    $data = Get-WtScheduleData
    $items = @($data.Items)
    $s1 = @($items | Where-Object { $_ -and $_.id -ceq 's1' })[0]
    $s1.title = '같은 초에 고친 제목'; Set-WtItemEdited $s1 $s1.origin.at   # 가져온 시각과 같은 초
    Save-WtScheduleItems $data.Store $items
    $csv = [System.IO.File]::ReadAllText((Join-Path $fixtures 'legacy.csv'))
    $csv = $csv.Replace('"쉼표, 따옴표 ""확인"""', '"예전 앱에서 고친 메모"').Replace('"09:30","주간 회의"', '"09:30","예전 앱에서 고친 회의"')
    Write-WtTestLegacyCsv $test 'schedule' $csv
    [void](Import-WtLegacyData -Force)
    $m = Get-WtScheduleLastImport
    $s2 = @((Read-WtTestDoc).items | Where-Object { $_ -and $_.id -ceq 's2' })[0]
    $s1 = @((Read-WtTestDoc).items | Where-Object { $_ -and $_.id -ceq 's1' })[0]
    Assert-WtTest '일정 합치기: 예전 앱에서 바뀐 칸(Note)만 옮기고, 중첩 칸 · 앱 고유 칸(start.zone · origin.line · color · repeat.byHour)은 그대로' (
        $s2.note -eq '예전 앱에서 고친 메모' -and $s2.start.zone -eq 'Asia/Seoul' -and $s2.origin.line -eq 3 -and $s2.color -eq 'blue' -and ($s2.repeat.byHour -join ',') -eq '9' -and
        $s2.start.time -eq '09:30' -and $s2.origin.row.Note -eq '예전 앱에서 고친 메모' -and $s2.rev -eq 0)
    Assert-WtTest '일정 합치기: 가져온 같은 초에 고쳐도 rev로 「이 앱에서 고침」을 알아보고 덮지 않는다' ($s1.title -eq '같은 초에 고친 제목' -and $s1.rev -eq 1 -and ($m.Conflicts -join ',') -eq 's1')
    # 3: id는 대소문자를 가려 비교하고, 같은 id의 둘째 줄은 버리지 않고 고칠 항목으로 남긴다 (legacy-dup.csv)
    $test = New-WtTestData 'schedule-dup'; $tests.Add($test)
    [void][System.IO.Directory]::CreateDirectory($test.Legacy)
    [System.IO.File]::Copy((Join-Path $fixtures 'legacy-dup.csv'), (Join-Path $test.Legacy 'schedule.csv'))
    $r = Import-WtLegacyData
    $data = Get-WtScheduleData
    $dup = @($data.Entries | Where-Object { $_.Id -like 'dup-*' })
    Assert-WtTest '일정 id: s1 · S1은 다른 항목, 같은 id 둘째 줄은 고칠 항목(원래 id 적음), 완전히 같은 줄은 하나' ($r.Count -eq 4 -and @($data.Entries).Count -eq 4 -and
        @($data.Entries | Where-Object { $_.Id -ceq 's1' -and $_.Title -eq '소문자 s1' }).Count -eq 1 -and @($data.Entries | Where-Object { $_.Id -ceq 'S1' -and $_.State -eq 'ok' }).Count -eq 1 -and
        $dup.Count -eq 1 -and $dup[0].State -eq 'broken' -and $dup[0].Problem -like "*원래 id 's1'*" -and $dup[0].Item.origin.dupOf -ceq 's1') "($($r.Count) · $(@($data.Entries | ForEach-Object { "$($_.Id)=$($_.State)" }) -join ','))"
    [void](Import-WtLegacyData -Force)
    $m = Get-WtScheduleLastImport
    Assert-WtTest '일정 id: 다시 가져와도 겹친 줄을 또 만들지 않는다' ($m.Added -eq 0 -and $m.Unchanged -eq 4 -and @((Get-WtScheduleData).Entries).Count -eq 4) "(더함 $($m.Added) · 그대로 $($m.Unchanged))"
    # 4 · 6: schema 1의 읽지 못한 끝 값은 원래 글 그대로 고칠 항목, 이전 전 항목 전체는 origin.prev, null 항목은 같은 자리에 (v1-bad-end.json)
    $test = New-WtTestData 'schedule-v1-bad'; $tests.Add($test)
    Copy-WtTestFixture 'v1-bad-end.json'
    $data = Get-WtScheduleData
    $doc = Read-WtTestDoc
    $b1 = @($data.Entries)[0]
    Assert-WtTest '일정 이전: 못 읽는 끝 값은 원래 글로 남아 고칠 항목, 이전 전 항목(1단계에만 있던 칸 포함)은 origin.prev' (
        $b1.State -eq 'broken' -and $doc.items[0].end.date -eq '내일' -and $doc.items[0].end.time -eq '25:00' -and $doc.items[0].origin.prev.endDate -eq '내일' -and
        $doc.items[0].origin.prev.endTime -eq '25:00' -and $doc.items[0].pinned -eq $true -and $doc.items[0].origin.prev.pinned -eq $true)
    Assert-WtTest '일정 이전: null 항목은 같은 자리에 남고 고칠 항목, Int32보다 큰 알람은 그 항목만 고칠 항목' (@($doc.items).Count -eq 3 -and $null -eq $doc.items[1] -and
        @($data.Entries)[1].State -eq 'broken' -and @($data.Entries)[2].State -eq 'broken' -and $doc.items[2].origin.prev.alarm -eq 2147483648) "$(@($data.Entries | ForEach-Object State) -join ',')"
    # 6 · 7: null 항목과 범위를 넘는 숫자 · 날짜는 그 항목만 고칠 항목이고, 저장해도 같은 자리 · 같은 값으로 남는다 (v2-edge.json)
    $test = New-WtTestData 'schedule-edge'; $tests.Add($test)
    Copy-WtTestFixture 'v2-edge.json'
    $before = [System.IO.File]::ReadAllText((Get-WtStorePath 'schedule')) | ConvertFrom-Json -Depth 20 -DateKind String
    $data = Get-WtScheduleData
    $states = (@($data.Entries) | ForEach-Object { $_.State }) -join ','
    Assert-WtTest '일정 경계 값: Int32 · Int64 · BigInteger를 넘는 수, 소수, 1년 넘는 알람, 1900년 앞 날짜는 그 항목만 고칠 항목 (예외 없음)' (
        -not $data.Error -and $states -eq 'ok,broken,broken,broken,broken,broken,broken,broken' -and ($data.Entries[0].Alarms -join ',') -eq '527040') $states
    $items = @($data.Items)
    $items[0].title = '고친 제목'; Set-WtItemEdited $items[0]
    Save-WtScheduleItems $data.Store $items
    $saved = Read-WtTestDoc
    $same = $true
    for ($i = 1; $i -lt $before.items.Count; $i++) { if ((Get-WtTestJson $before.items[$i]) -cne (Get-WtTestJson $saved.items[$i])) { $same = $false } }
    Assert-WtTest '일정 경계 값: 한 항목을 고쳐 저장해도 null · 깨진 항목이 같은 자리에 같은 값, rev는 1 오른다' ($same -and @($saved.items).Count -eq 8 -and $null -eq $saved.items[1] -and
        $saved.items[0].rev -eq 4 -and $saved.items[0].title -eq '고친 제목')
    # 5 · 6: 빈 파일은 「없음」이 아니라 깨진 파일. 읽기를 거부한 파일 · 읽은 뒤 바뀐 파일에는 저장하지 않는다
    $test = New-WtTestData 'schedule-refuse'; $tests.Add($test)
    foreach ($text in '', '   ', '{ "schema": 3, "items": [] }', '{ "schema": 2, "items": { "id": "x" } }') {
        [System.IO.File]::WriteAllText((Get-WtStorePath 'schedule'), $text, [System.Text.UTF8Encoding]::new($false))
        $data = Get-WtScheduleData
        $saveError = $null; try { Save-WtScheduleItems $data.Store @() } catch { $saveError = $_.Exception.Message }
        $writeError = $null; try { Write-WtStore -Name 'schedule' -Schema 2 -Items @() } catch { $writeError = $_.Exception.Message }
        Assert-WtTest "일정 저장 거부: '$text' → 읽기 오류, 핸들 저장 · 낮은 단계 저장 모두 거부, 파일 그대로" ($data.Error -and $data.Store.State -eq 'error' -and $saveError -and $writeError -and
            [System.IO.File]::ReadAllText((Get-WtStorePath 'schedule')) -ceq $text) "$($data.Error) / $saveError / $writeError"
    }
    Copy-WtTestFixture 'v2.json'
    $data = Get-WtScheduleData
    $stale = $data.Store
    Copy-WtTestFixture 'v2-future.json'
    $null = Get-WtScheduleData
    $staleError = $null; try { Save-WtScheduleItems $stale @($data.Items) } catch { $staleError = $_.Exception.Message }
    Assert-WtTest '일정 저장 거부: 읽은 뒤 파일이 바뀌어 다시 읽었으면 옛 핸들로는 저장하지 않는다' ($staleError -like '*다시 읽은 뒤*' -and (Read-WtTestDoc).sync.device -eq 'PC-02') $staleError
    $test = New-WtTestData 'schedule-new'; $tests.Add($test)
    $data = Get-WtScheduleData
    $wasMissing = $data.Store.State -eq 'missing'
    Save-WtScheduleItems $data.Store @()
    $againError = $null; try { Save-WtScheduleItems $data.Store @() } catch { $againError = $_.Exception.Message }
    Assert-WtTest '일정 저장: 파일이 없으면(없음) 핸들로 새로 만들고, 저장에 쓴 핸들은 다시 쓰지 못한다(다시 읽어야 함)' ($wasMissing -and (Read-WtTestDoc).schema -eq 2 -and
        $data.Store.State -eq 'missing' -and $againError -like '*바뀌었습니다*')

    # ---- 2026-10-26 재확인 반례 (고치기 전에는 모두 틀렸다) ----
    # 1: 알람 목록은 첫 알람의 before만 예전 앱 소유. 다른 원소 · 첫 알람의 다른 칸은 그대로, 예전 앱에서 끄면 before = null(꺼진 알람)
    $test = New-WtTestData 'schedule-alarm'; $tests.Add($test)
    [void][System.IO.Directory]::CreateDirectory($test.Legacy)
    [System.IO.File]::Copy((Join-Path $fixtures 'legacy.csv'), (Join-Path $test.Legacy 'schedule.csv'))
    [void](Import-WtLegacyData)
    $doc = Read-WtTestDoc
    foreach ($i in $doc.items) { if ($i.id -eq 's1') { $i.alarms = @([pscustomobject]@{ before = 10; sound = 'keep' }, [pscustomobject]@{ channel = 'future' }) } }
    [System.IO.File]::WriteAllText((Get-WtStorePath 'schedule'), (ConvertTo-Json $doc -Depth 20), [System.Text.UTF8Encoding]::new($false))
    $csv = [System.IO.File]::ReadAllText((Join-Path $fixtures 'legacy.csv'))
    Write-WtTestLegacyCsv $test 'schedule' $csv.Replace('"주간 회의","","10"', '"주간 회의","","20"')
    [void](Import-WtLegacyData -Force)
    $al = @(@((Read-WtTestDoc).items | Where-Object { (Test-WtRecordObject $_) -and $_.id -ceq 's1' })[0].alarms)
    Write-WtTestLegacyCsv $test 'schedule' $csv.Replace('"주간 회의","","10"', '"주간 회의","",""')
    [void](Import-WtLegacyData -Force)
    $off = @(@((Read-WtTestDoc).items | Where-Object { (Test-WtRecordObject $_) -and $_.id -ceq 's1' })[0].alarms)
    $s1 = @((Get-WtScheduleData).Entries | Where-Object Id -ceq 's1')[0]
    Assert-WtTest '일정 합치기: 알람은 첫 알람의 before만 바꾸고 다른 원소 · 확장 칸은 그대로, 예전 앱에서 끄면 before = null(꺼진 알람)' (
        $al.Count -eq 2 -and $al[0].before -eq 20 -and $al[0].sound -eq 'keep' -and $al[1].channel -eq 'future' -and
        $off.Count -eq 2 -and $null -eq $off[0].before -and $off[0].sound -eq 'keep' -and $s1.State -eq 'ok' -and $s1.Alarms.Count -eq 0) "$(ConvertTo-Json $al -Compress) / $(ConvertTo-Json $off -Compress)"
    # 2: rev · origin.rev 중 하나라도 잘못된 값이면(둘 다 잘못돼도) 고쳤음으로 보고 덮지 않는다
    $doc = Read-WtTestDoc
    foreach ($i in $doc.items) { if ($i.id -eq 's2') { $i.title = '이 앱 값'; $i.rev = -1; $i.origin.rev = -2 } }
    [System.IO.File]::WriteAllText((Get-WtStorePath 'schedule'), (ConvertTo-Json $doc -Depth 20), [System.Text.UTF8Encoding]::new($false))
    Write-WtTestLegacyCsv $test 'schedule' $csv.Replace('"백업 확인"', '"예전 앱 값"')
    [void](Import-WtLegacyData -Force)
    Assert-WtTest '일정 합치기: rev · origin.rev가 둘 다 잘못된 값이어도 고쳤음으로 보고 덮지 않는다' (
        @((Read-WtTestDoc).items | Where-Object { (Test-WtRecordObject $_) -and $_.id -ceq 's2' })[0].title -eq '이 앱 값' -and @((Get-WtScheduleLastImport).Conflicts) -contains 's2')
    # 12: id와 내용까지 같은 줄은 하나 (legacy-same.csv)
    $test = New-WtTestData 'schedule-same'; $tests.Add($test)
    [void][System.IO.Directory]::CreateDirectory($test.Legacy)
    [System.IO.File]::Copy((Join-Path $fixtures 'legacy-same.csv'), (Join-Path $test.Legacy 'schedule.csv'))
    $r = Import-WtLegacyData
    $data = Get-WtScheduleData
    Assert-WtTest '일정 id: id와 내용까지 같은 두 줄은 하나로 (겹친 줄 · 고칠 항목을 만들지 않는다)' ($r.Count -eq 2 -and @($data.Entries).Count -eq 2 -and
        -not @($data.Entries | Where-Object { $_.State -ne 'ok' }).Count -and -not @((Get-WtScheduleLastImport).Duplicates).Count)
    # 6: 목록 · 빈 목록 · null · 글 항목은 이전하고 저장해도 같은 자리에 그대로 (v1-raw-items.json)
    $test = New-WtTestData 'schedule-raw-items'; $tests.Add($test)
    Copy-WtTestFixture 'v1-raw-items.json'
    $data = Get-WtScheduleData
    $items = @(Copy-WtItem @($data.Items))
    $items[0].title = '고친 제목'; Set-WtItemEdited $items[0]
    Save-WtScheduleItems $data.Store $items
    $saved = (Read-WtTestDoc).items
    Assert-WtTest '일정: 목록 · 빈 목록 · null · 글 항목은 이전 · 저장 뒤에도 같은 자리에 그대로 (펴지거나 빠지지 않음)' (@($saved).Count -eq 5 -and $saved[0].title -eq '고친 제목' -and
        ($saved[1] -join ',') -eq 'raw1,raw2' -and $saved[2] -is [array] -and @($saved[2]).Count -eq 0 -and $null -eq $saved[3] -and $saved[4] -ceq '글 하나' -and
        ((@($data.Entries) | ForEach-Object State) -join ',') -eq 'ok,broken,broken,broken,broken') "$(@($saved).Count) · $((@($data.Entries) | ForEach-Object State) -join ',')"
    # 7: 정수 판정은 변환 전에 (v2-edge-float.json)
    $test = New-WtTestData 'schedule-float'; $tests.Add($test)
    Copy-WtTestFixture 'v2-edge-float.json'
    $data = Get-WtScheduleData
    Assert-WtTest '일정 경계 값: 1e-30 · 1.0000000000000002는 정수가 아니라 고칠 항목, 10.0은 정수, before null은 꺼진 알람' (
        ((@($data.Entries) | ForEach-Object State) -join ',') -eq 'broken,broken,broken,ok,ok' -and ($data.Entries[3].Alarms -join ',') -eq '10' -and $data.Entries[4].Alarms.Count -eq 0) ((@($data.Entries) | ForEach-Object State) -join ',')
    # 5: 같은 핸들을 여러 곳이 나눠 가져도, 한 곳이 저장하면 다른 곳의 옛 목록 저장은 거부한다(낙관적 잠금)
    $data = Get-WtScheduleData
    $other = Get-WtScheduleData
    $a = @(Copy-WtItem @($data.Items)); $a[3].title = 'A가 고침'
    $b = @(Copy-WtItem @($data.Items)); $b[3].note = 'B가 고친 옛 목록'
    Save-WtScheduleItems $data.Store $a
    $bError = $null; try { Save-WtScheduleItems $other.Store $b } catch { $bError = $_.Exception.Message }
    Assert-WtTest '일정 저장 거부: 같은 핸들로 먼저 저장한 곳이 있으면 뒤의 옛 목록은 저장하지 않는다 (앞 저장이 남음)' ([object]::ReferenceEquals($data.Store, $other.Store) -and $bError -like '*바뀌었습니다*' -and
        (Read-WtTestDoc).items[3].title -eq 'A가 고침' -and (Read-WtTestDoc).items[3].note -eq '') $bError

    # ---- 읽을 수 없는 파일: 화면은 열리고 파일은 그대로 ----
    $test = New-WtTestData 'schedule-bad'; $tests.Add($test)
    $bad = [ordered]@{ '더 새 schema' = '{ "schema": 3, "items": [] }'; '깨진 JSON' = '{ "schema": 2, "items": [ { "id": '; 'schema 없음' = '{ "items": [] }' }
    foreach ($k in $bad.Keys) {
        [System.IO.File]::WriteAllText((Get-WtStorePath 'schedule'), $bad[$k], [System.Text.UTF8Encoding]::new($false))
        $data = Get-WtScheduleData
        $importError = $null
        [void][System.IO.Directory]::CreateDirectory($test.Legacy)
        [System.IO.File]::Copy((Join-Path $fixtures 'legacy.csv'), (Join-Path $test.Legacy 'schedule.csv'), $true)
        try { [void](Import-WtLegacyData -Force) } catch { $importError = $_.Exception.Message }
        Assert-WtTest "일정 못 읽는 파일($k): 오류로 알리고, 다시 가져오기도 덮어쓰지 않는다" ($data.Error -and -not $data.Entries.Count -and $importError -and
            [System.IO.File]::ReadAllText((Get-WtStorePath 'schedule')) -ceq $bad[$k]) "$($data.Error) / $importError"
    }

    if (Test-WtTestWpf) {
        $test = New-WtTestData 'schedule-view'; $tests.Add($test)
        [void][System.IO.Directory]::CreateDirectory($test.Legacy)
        [System.IO.File]::Copy((Join-Path $fixtures 'legacy.csv'), (Join-Path $test.Legacy 'schedule.csv'))
        [void](Import-WtLegacyData)
        $module = Get-Module Schedule
        $view = New-WtTestView 'schedule'
        & $module { Update-WtScheduleView; $script:testFirst = $script:body.Children[0]; Update-WtScheduleView }
        Assert-WtTest '일정 화면: 같은 데이터는 다시 만들지 않는다' (& $module { [object]::ReferenceEquals($script:testFirst, $script:body.Children[0]) })
        $texts = @(Get-WtTestTexts $view)
        Assert-WtTest '일정 화면: 매일 반복 · 고칠 항목 · 새 버전 항목을 보여 준다' ($texts -contains '매일 점검' -and @($texts | Where-Object { $_ -like '고칠 항목*' }).Count -eq 1 -and
            @($texts | Where-Object { $_ -like '새 버전에서 만든 항목*' }).Count -eq 1 -and $texts -contains '날짜가 깨진 줄')
        $data = Get-WtScheduleData
        $items = @($data.Items)
        foreach ($i in $items) { if ($i.id -eq 's4') { $i.title = '바뀐 매일 점검'; Set-WtItemEdited $i } }
        Save-WtScheduleItems $data.Store $items
        & $module { Update-WtScheduleView }
        Assert-WtTest '일정 화면: 저장이 바뀌면 다시 들어올 때 반영한다' ((Get-WtTestTexts $view) -contains '바뀐 매일 점검')
        & $module { $script:testFirst = $script:body.Children[0]; $script:viewKey = '어제'; Update-WtScheduleView }
        Assert-WtTest '일정 화면: 날짜 키가 바뀌면 다시 만든다' (& $module { -not [object]::ReferenceEquals($script:testFirst, $script:body.Children[0]) })
        $cards = @(& $module { New-WtScheduleHomeCards })
        Assert-WtTest '일정 화면: 홈 카드 둘' ($cards.Count -eq 2 -and @(Get-WtTestTexts $cards[0] | Where-Object { $_ -like '오늘 일정*' }).Count -eq 1)
        [System.IO.File]::WriteAllText((Get-WtStorePath 'schedule'), '{ "schema": 3, "items": [] }', [System.Text.UTF8Encoding]::new($false))
        & $module { Update-WtScheduleView }
        $texts = @(Get-WtTestTexts $view)
        Assert-WtTest '일정 화면: 못 읽는 파일이면 화면은 열고 이유를 보여 준다' ($texts -contains '일정 파일을 읽지 못했습니다' -and @($texts | Where-Object { $_ -like '*더 새 버전*' }).Count -eq 1)
    }
} finally {
    foreach ($t in $tests) { Remove-WtTestData $t }
}

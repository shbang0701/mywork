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
      v2-routine.json weekly · hourly · workdaysOnly · 모르는 freq (schedule schema 2 그대로)
      routine-log-v1.json 체크 원자료 · 푼 표시 · 오래된 증적 (별도 schema 1)
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
function Read-WtTestDoc { Wait-WtTestWrites; [System.IO.File]::ReadAllText((Get-WtStorePath 'schedule')) | ConvertFrom-Json -Depth 20 -DateKind String }
function Read-WtTestDocNamed([string]$Name) { Wait-WtTestWrites; [System.IO.File]::ReadAllText((Get-WtStorePath $Name)) | ConvertFrom-Json -Depth 20 -DateKind String }
function Get-WtTestKeys($Occurrences) { (@($Occurrences) | ForEach-Object { $_.Key }) -join ',' }
function Get-WtTestJson($Value) { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }
function Get-WtTestById($Entries) { $m = @{}; foreach ($e in @($Entries)) { if ($e.Id -and -not $m.ContainsKey($e.Id)) { $m[$e.Id] = $e } }; $m }
# 논리 트리의 요소를 모두 (폼 안 단추 · 글 찾기)
function Get-WtTestLogical($Root) { if ($null -eq $Root) { return }; $Root; if ($Root -is [Windows.DependencyObject]) { foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($Root)) { Get-WtTestLogical $c } } }
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
    $sharedOccurrences = Invoke-WtReadAction {
        $from = [datetime]'2026-10-25'; $to = $from.AddDays(41)
        $first = @(Get-WtScheduleOccurrences $data.Entries $from $to)
        $same = @(Get-WtScheduleOccurrences $data.Entries $from $to)
        $entry = $first[0].Entry.PSObject.Copy(); $entry.Title = '별도 배열'; $entry.Repeat = $null
        $entry.Start = $first[0].Start; $entry.End = $first[0].End; $entry.LastDay = $first[0].LastDay
        $other = @(Get-WtScheduleOccurrences @($entry) $from $to)
        $first.Count -gt 0 -and [object]::ReferenceEquals($first[0],$same[0]) -and
            -not [object]::ReferenceEquals($first[0],$other[0]) -and $other[0].Title -ceq '별도 배열'
    }
    Assert-WtTest '동작 회차: 같은 배열·범위는 한 번 전개, 같은 ID의 별도 배열은 독립 계산' $sharedOccurrences
    foreach ($count in 35,42) {
        $from = [datetime]'2026-10-25'
        $occ = @(Get-WtScheduleOccurrences $data.Entries $from $from.AddDays(41))
        $expected = Get-WtScheduleDays $data.Entries $from 42
        $shared = Get-WtScheduleDays $data.Entries $from 42 -Occurrences $occ
        $last = @(Get-WtScheduleOccurrences $data.Entries $from $from.AddDays($count - 1))
        Assert-WtTest "달력 회차 공유: $count 칸의 날짜 묶음·막대·끝날·옮긴 회차 순서 유지" (
            (Get-WtTestJson $shared) -ceq (Get-WtTestJson $expected) -and
            (Get-WtTestJson @(Get-WtScheduleLanes $occ $from ($count / 7))) -ceq (Get-WtTestJson @(Get-WtScheduleLanes $last $from ($count / 7))))
    }
    $emptyDays = Get-WtScheduleDays $data.Entries ([datetime]'2026-10-25') 42 -Occurrences @()
    Assert-WtTest '달력 회차 공유: 빈 전개 결과도 다시 전개하지 않는다' (@($emptyDays | ForEach-Object { $_ }).Count -eq 0 -and $emptyDays.Count -eq 42)
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

    # ---- 2a 편집 · 반복 예외 · 알람 (화면 없이) ----
    $test = New-WtTestData 'schedule-edit'; $tests.Add($test)
    $at = '2026-11-02T08:00:00+09:00'
    $store = Open-WtScheduleStore
    $r = Save-WtScheduleItem $store @{ title = '주간 점검'; start = @{ date = '2026-11-02'; time = '09:00'; zone = '남길 칸' }
        repeat = @{ freq = 'weekly'; days = @('mon'); count = 5; skip = @(); changes = @{}; future = '남길 규칙' }; alarms = @(@{ before = 10 }, @{ before = 0 }) } -At $at
    $id = $r.Id
    Assert-WtTest '일정 편집: 새 항목 · rev 0 · 다음 핸들, 원래 핸들 목록은 그대로' ($r.Success -and $id -cmatch '^[a-f0-9]{12}$' -and $r.Store.Items[0].rev -eq 0 -and $store.Items.Count -eq 0) $r.Reason
    $r = Save-WtScheduleItem $r.Store @{ title = '바꾼 점검'; start = @{ time = '09:00' }; repeat = @{ count = 6 } } -Id $id -At $at
    Assert-WtTest '일정 편집: 제목 · count 변경은 같은 계열, 깊은 칸 보존 · rev 증가' ($r.Success -and $r.Id -ceq $id -and $r.Store.Items[0].rev -eq 1 -and
        $r.Store.Items[0].start.zone -eq '남길 칸' -and $r.Store.Items[0].repeat.future -eq '남길 규칙') $r.Reason
    $r = Set-WtScheduleOccurrence $r.Store $id '2026-11-09' -Skip -At $at
    $r = Set-WtScheduleOccurrence $r.Store $id '2026-11-16' -Patch @{ start = @{ date = '2026-11-17'; time = '10:00' }; note = '이 회차만' } -At $at
    $entry = ConvertFrom-WtScheduleItem $r.Store.Items[0]
    $keys = Get-WtTestKeys (Get-WtScheduleOccurrences @($entry) (& $d '2026-11-01') (& $d '2026-12-31'))
    Assert-WtTest '일정 편집: 회차만 빼기 · 다른 날로 옮기기, count는 skip도 센다' ($r.Success -and $keys -ceq "$id@2026-11-02,$id@2026-11-16,$id@2026-11-23,$id@2026-11-30,$id@2026-12-07") "$($r.Reason) $keys"
    $bad = Set-WtScheduleOccurrence $r.Store $id '2026-11-10' -Skip -At $at
    $night = Save-WtScheduleItem $r.Store @{ start = @{ date = '2026-11-02'; time = '23:00' }; end = @{ date = '2026-11-03'; time = '01:00' } } -At $at
    $wrong = Save-WtScheduleItem $r.Store @{ start = @{ date = '2026-02-30'; time = $null } } -At $at
    Assert-WtTest '일정 입력 거부: 없는 회차 · 밤샘 새 일정 · 없는 날짜는 예외 대신 이유' (-not $bad.Success -and $bad.Reason -and -not $night.Success -and $night.Reason -and -not $wrong.Success -and $wrong.Reason)

    $state = Open-WtScheduleAlarmStore
    $alarms = Get-WtScheduleAlarms -Now '2026-11-17T10:00:00+09:00' -Previous '2026-11-17T09:49:59+09:00' -Entries @($entry) -StateStore $state
    Assert-WtTest '알람: 옮긴 회차 · 여러 알람 · 끝 시각 포함 (원래 회차 키 유지)' ($alarms.Success -and ($alarms.Alarms.Before -join ',') -ceq '10,0' -and
        ($alarms.Alarms.OccurrenceKey -join ',') -ceq "$id@2026-11-16,$id@2026-11-16") $alarms.Reason
    $sourceBytes = [IO.File]::ReadAllText((Get-WtStorePath 'schedule'))
    $fired = Save-WtScheduleAlarms $state $alarms.Alarms -At '2026-11-17T10:00:00+09:00'
    $again = Get-WtScheduleAlarms -Now '2026-11-17T10:00:00+09:00' -Previous '2026-11-17T09:49:59+09:00' -Entries @($entry) -StateStore $fired.Store
    Assert-WtTest '알람 상태: 별도 파일에 저장 · 중복 방지 · 원자료 바이트 그대로' ($fired.Success -and -not $again.Alarms.Count -and
        [IO.File]::ReadAllText((Get-WtStorePath 'schedule')) -ceq $sourceBytes -and (Test-Path (Get-WtStorePath 'schedule-state')))
    $a = Get-WtScheduleAlarms -Now '2026-11-17T10:00:00+09:00' -Previous '2026-11-17T09:50:00+09:00' -Entries @($entry)
    $first = Get-WtScheduleAlarms -Now '2026-11-17T10:00:00+09:00' -Entries @($entry)
    $back = Get-WtScheduleAlarms -Now '2026-11-17T09:00:00+09:00' -Previous '2026-11-17T10:00:00+09:00' -Entries @($entry)
    $skipAlarm = Get-WtScheduleAlarms -Now '2026-11-09T09:00:00+09:00' -Previous '2026-11-09T08:00:00+09:00' -Entries @($entry)
    Assert-WtTest '알람 구간: 앞 시각 제외 · 첫 실행 지난 것 없음 · 시계 역행 이유 · skip 안 울림' (($a.Alarms.Before -join ',') -ceq '0' -and
        -not $first.Alarms.Count -and -not $back.Success -and $back.Reason -and -not $skipAlarm.Alarms.Count)
    $off = Set-WtHolidayDate (Get-WtHolidayData).Store '2026-11-17' 'personal' -At $at
    $a = Get-WtScheduleAlarms -Now '2026-11-17T10:00:00+09:00' -Previous '2026-11-17T09:49:59+09:00' -Entries @($entry)
    Assert-WtTest '알람: 휴무일이어도 그대로 울림' ($off.Success -and $a.Alarms.Count -eq 2)
    $state = Save-WtStore $fired.Store @($fired.Store.Items + @([pscustomobject]@{ key = 'old'; at = '2026-11-01T10:00:00+09:00' }))
    $pruned = Save-WtScheduleAlarms $state @() -At '2026-11-17T10:01:00+09:00'
    Assert-WtTest '알람 상태: 7일 지난 기록만 정리하고 최근 두 알람은 보존' ($pruned.Success -and $pruned.Store.Items.Count -eq 2)

    $priorStore = $r.Store
    $r = Save-WtScheduleItem $r.Store @{ repeat = @{ interval = 2 } } -Id $id -FromDate '2026-11-23' -At $at
    $oldSeries = @($r.Store.Items | Where-Object id -ceq $id)[0]
    $newSeries = @($r.Store.Items | Where-Object id -ceq $r.Id)[0]
    Assert-WtTest '일정 계열 나누기: 옛 계열 앞날 종료 · 예외 보존, 새 id · 출처 · 남은 횟수 · 새 예외 비움' ($r.Success -and $r.Id -cne $id -and
        $oldSeries.repeat.until -ceq '2026-11-22' -and $null -eq $oldSeries.repeat.count -and ($oldSeries.repeat.skip -join ',') -ceq '2026-11-09' -and
        $oldSeries.repeat.changes.'2026-11-16'.note -eq '이 회차만' -and $newSeries.origin.id -ceq $id -and $newSeries.origin.from -ceq 'split' -and
        $newSeries.start.date -ceq '2026-11-23' -and $newSeries.repeat.count -eq 3 -and @($newSeries.repeat.skip).Count -eq 0 -and @($newSeries.repeat.changes.PSObject.Properties).Count -eq 0) $r.Reason
    $staleError = $null
    try { [void](Save-WtScheduleItem $priorStore @{ title = '옛 목록' } -Id $id -At $at) } catch { $staleError = $_.Exception.Message }
    Assert-WtTest '일정 편집: 낡은 핸들의 예외는 그대로 (새 결과를 덮지 않음)' ($staleError -like '*바뀌었습니다*') $staleError
    $newId = $r.Id
    $r = Save-WtScheduleItem $r.Store @{ start = @{ time = '10:00' } } -Id $newId -At $at
    Assert-WtTest '일정 계열 나누기: 첫 회차 규칙 변경도 새 id, 옛 계열은 지운 표시' ($r.Success -and $r.Id -cne $newId -and
        (Test-WtDeleted @($r.Store.Items | Where-Object id -ceq $newId)[0])) $r.Reason
    $r = Set-WtScheduleDeleted $r.Store $r.Id -At $at
    $deletedId = $r.Id
    $expired = Set-WtScheduleDeleted $r.Store $deletedId -Deleted $false -At '2027-01-31T08:00:00+09:00'
    $restored = Set-WtScheduleDeleted $r.Store $deletedId -Deleted $false -At '2027-01-30T08:00:00+09:00'
    Assert-WtTest '일정 되살리기: 89일은 가능 · 90일은 이유로 거부' (-not $expired.Success -and $expired.Reason -and $restored.Success) "$($expired.Reason) $($restored.Reason)"

    # 다섯째 요일 없는 달 · 윤년 말일 · 하루 종일 알람 · 지운 항목/모르는 값 제외를 문화권 다섯 개에서 고정한다.
    # 하루 종일 알람의 기준은 그날 업무 시작(기본 09:00, 2026-11-22 설계 16장)이라 before 360은 그날 03:00이다(전에는 0시 기준이라 전날 18:00)
    $fifth = ConvertTo-WtTestItem '{ "id":"fifth", "kind":"event", "start":{"date":"2026-01-01","time":null}, "repeat":{"freq":"monthly","days":["mon"],"nth":5,"count":3}, "alarms":[{"before":360}] }'
    $lastDay = ConvertTo-WtTestItem '{ "id":"last", "kind":"event", "start":{"date":"2028-01-31","time":null}, "repeat":{"freq":"monthly","monthDay":-1,"count":3}, "alarms":[] }'
    $thread = [Threading.Thread]::CurrentThread; $oldCulture = $thread.CurrentCulture
    $snapshots = @()
    try {
        foreach ($culture in 'ko-KR', 'en-US', 'th-TH', 'ar-SA', 'ja-JP') {
            $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
            $f = ConvertFrom-WtScheduleItem $fifth; $l = ConvertFrom-WtScheduleItem $lastDay
            $fk = Get-WtTestKeys (Get-WtScheduleOccurrences @($f) (& $d '2026-01-01') (& $d '2026-12-31'))
            $lk = Get-WtTestKeys (Get-WtScheduleOccurrences @($l) (& $d '2028-01-01') (& $d '2028-03-31'))
            $al = Get-WtScheduleAlarms -Now '2026-03-30T03:00:00+09:00' -Previous '2026-03-30T02:59:59+09:00' -Entries @($f)
            $snapshots += "$fk|$lk|$($al.Alarms.Key -join ',')"
        }
    } finally { $thread.CurrentCulture = $oldCulture }
    $expected2a = 'fifth@2026-03-30,fifth@2026-06-29,fifth@2026-08-31|last@2028-01-31,last@2028-02-29,last@2028-03-31|fifth@2026-03-30/360'
    Assert-WtTest '일정 2a 문화권 5개: 다섯째 요일 · 윤년 말일 · 하루 종일 알람(업무 시작 기준) 기대값 동일' (@($snapshots | Where-Object { $_ -cne $expected2a }).Count -eq 0) ($snapshots -join "`n")
    $hidden = Copy-WtItem $fifth; Set-WtField $hidden 'deleted' $at
    $future = Copy-WtItem $fifth; $future.kind = 'future'
    $a = Get-WtScheduleAlarms -Now '2026-03-30T03:00:00+09:00' -Previous '2026-03-30T02:59:59+09:00' -Entries @((ConvertFrom-WtScheduleItem $hidden), (ConvertFrom-WtScheduleItem $future))
    Assert-WtTest '알람: 지운 항목 · 읽기 전용 항목 제외' (-not $a.Alarms.Count)

    # ---- 알람 연속 틱 (2026-11-22 점검) ----
    # 앱에는 아직 판정을 부르는 타이머와 알리는 방식이 없다(설계 9.1의 2b). 붙일 타이머가 지킬 약속을 가짜 알리기로 고정한다.
    # 틱마다 (앞 틱, 지금] 판정 → 알리기 → 받아들인 것만 기록. 창 · 소리 · 트레이 풍선은 쓰지 않는다.
    $test = New-WtTestData 'schedule-alarm-ticks'; $tests.Add($test)
    $alarmAt = '2026-11-20T08:00:00+09:00'
    $store = Open-WtScheduleStore; $k = @{}
    foreach ($pair in @(
            @('once', @{ title = '한 번'; start = @{ date = '2026-11-23'; time = '14:00' }; alarms = @(@{ before = 10 }) }),
            @('daily', @{ title = '매일'; start = @{ date = '2026-11-22'; time = '09:00' }; repeat = @{ freq = 'daily' }; alarms = @(@{ before = 5 }) }),
            @('allDay', @{ title = '하루 종일'; start = @{ date = '2026-11-24'; time = $null }; alarms = @(@{ before = 360 }) }),
            @('multi', @{ title = '여러 날'; start = @{ date = '2026-11-25'; time = $null }; end = @{ date = '2026-11-26'; time = $null }; alarms = @(@{ before = 60 }) }),
            @('done', @{ title = '체크함'; start = @{ date = '2026-11-23'; time = '15:00' }; alarms = @(@{ before = 10 }) }),
            @('far', @{ title = '366일 전'; start = @{ date = '2027-11-25'; time = '10:00' }; alarms = @(@{ before = 527040 }) }))) {
        $r = Save-WtScheduleItem $store $pair[1] -At $alarmAt
        if (-not $r.Success) { throw "알람 틱 준비 $($pair[0]): $($r.Reason)" }
        $k[$pair[0]] = $r.Id; $store = $r.Store
    }
    Wait-WtTestWrites
    $checked = Set-WtEventCheck -Event $k.done -Date '2026-11-23' -Done $true -At $alarmAt
    Wait-WtTestWrites
    $alarmEntries = (Get-WtScheduleData).Entries
    $notified = [System.Collections.Generic.List[string]]::new()
    # 틱 하나 = 붙일 타이머가 할 일. 가짜 알리기는 키만 적는다. 기록한 뒤의 상태 핸들을 돌려준다
    function Invoke-WtTestAlarmTick([string]$Now, [string]$Previous, $State) {
        $result = Get-WtScheduleAlarms -Now $Now -Previous $Previous -Entries $alarmEntries -StateStore $State -Done (Get-WtEventDone)
        if (-not $result.Success) { throw "알람 틱 $Now : $($result.Reason)" }
        foreach ($alarm in $result.Alarms) { $notified.Add($alarm.Key) }
        if ($result.Alarms.Count) { (Save-WtScheduleAlarms $State $result.Alarms -At $Now).Store } else { $State }
    }
    $alarmState = Open-WtScheduleAlarmStore
    $steps = @(7, 15, 60, 1020, 10800); $tickCount = 0
    $clock = [DateTimeOffset]::new(2026, 11, 22, 8, 0, 0, [timespan]::FromHours(9)); $previous = Get-WtStamp $clock
    while ($clock -lt [DateTimeOffset]::new(2026, 11, 27, 0, 0, 0, [timespan]::FromHours(9))) {
        $clock = $clock.AddSeconds($steps[$tickCount % $steps.Count]); $tickCount++
        $nowText = Get-WtStamp $clock
        $alarmState = Invoke-WtTestAlarmTick $nowText $previous $alarmState; $previous = $nowText
    }
    $expected = @("$($k.daily)@2026-11-22/5", "$($k.daily)@2026-11-23/5", "$($k.once)@2026-11-23/10", "$($k.allDay)@2026-11-24/360",
        "$($k.daily)@2026-11-24/5", "$($k.far)@2027-11-25/527040", "$($k.multi)@2026-11-25/60", "$($k.daily)@2026-11-25/5", "$($k.daily)@2026-11-26/5") -join ','
    Assert-WtTest '알람 틱: 한 번 · 매일 · 하루 종일(업무 시작 기준) · 여러 날 · 366일 전이 회차마다 정확히 한 번 (7초 ~ 3시간 틱)' (
        $checked.Success -and ($notified -join ',') -ceq $expected) "$($notified -join ',') / 틱 $tickCount"
    Assert-WtTest '알람 틱: 체크한 회차는 울리지 않는다' ($notified -cnotcontains "$($k.done)@2026-11-23/10") ($notified -join ',')
    $count = $notified.Count
    $alarmState = Invoke-WtTestAlarmTick '2026-11-23T14:00:00+09:00' '2026-11-23T08:00:00+09:00' $alarmState
    Assert-WtTest '알람 틱: 울린 구간을 다시 봐도(겹친 틱) 또 울리지 않는다' ($notified.Count -eq $count) ($notified -join ',')
    $unchecked = Set-WtEventCheck -Event $k.done -Date '2026-11-23' -Done $false -At $alarmAt
    Wait-WtTestWrites
    $alarmState = Invoke-WtTestAlarmTick '2026-11-23T14:50:00+09:00' '2026-11-23T14:49:00+09:00' $alarmState
    Assert-WtTest '알람 틱: 체크를 풀면 그 회차는 울린다' ($unchecked.Success -and $notified.Count -eq $count + 1 -and
        $notified[$notified.Count - 1] -ceq "$($k.done)@2026-11-23/10") ($notified -join ',')
    $moved = Save-WtScheduleItem (Get-WtScheduleData).Store @{ start = @{ date = '2026-11-23'; time = '15:30' } } -Id $k.once -At '2026-11-23T14:05:00+09:00'
    Wait-WtTestWrites
    $alarmEntries = (Get-WtScheduleData).Entries
    $count = $notified.Count
    $alarmState = Invoke-WtTestAlarmTick '2026-11-23T15:21:00+09:00' '2026-11-23T15:19:00+09:00' $alarmState
    $alarmState = Invoke-WtTestAlarmTick '2026-11-23T15:22:00+09:00' '2026-11-23T15:00:00+09:00' $alarmState
    Assert-WtTest '알람 틱: 울린 뒤 같은 날 늦춘 일정(14:00 → 15:30)은 새 시각에 한 번 더' ($moved.Success -and $moved.Id -ceq $k.once -and
        $notified.Count -eq $count + 1 -and $notified[$notified.Count - 1] -ceq "$($k.once)@2026-11-23/10") "$($moved.Reason) $($notified -join ',')"
    # 판정 비용: 일정 300개(매일 30 · 매주 30 · 한 번 240)에 판정 한 번. 바쁜 PC에서도 흔들리지 않게 이 프로세스의 CPU 시간으로 잰다
    $bigEntries = @(for ($n = 0; $n -lt 300; $n++) {
            $freq = if ($n -lt 30) { 'daily' } elseif ($n -lt 60) { 'weekly' } else { $null }
            ConvertFrom-WtScheduleItem ([pscustomobject][ordered]@{ id = ('{0:x12}' -f (0xb00000000000 + $n)); kind = 'event'; title = "가짜 $n"; note = ''
                    start = [ordered]@{ date = [datetime]::new(2026, 1, 1).AddDays($n).ToString('yyyy-MM-dd', $inv); time = '10:00' }; end = $null
                    repeat = $(if ($freq) { [ordered]@{ freq = $freq } } else { $null }); alarms = @([ordered]@{ before = 10 }); tags = @(); rev = 0
                    created = $alarmAt; updated = $alarmAt; deleted = $null; origin = $null })
        })
    $dayCount = @(Get-WtScheduleOccurrences $bigEntries (& $d '2026-11-24') (& $d '2026-11-24')).Count
    # 처음 틱(목록이 바뀐 뒤): 매번 새 배열이라 색인 · 펼친 결과를 새로 만든다. 다음 틱(같은 목록): 펼친 결과를 다시 쓴다
    $cpu = @(foreach ($round in 1..3) {
            $t0 = [Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime
            $big = Get-WtScheduleAlarms -Now '2026-11-24T09:50:05+09:00' -Previous '2026-11-24T09:49:50+09:00' -Entries @($bigEntries)
            ([Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime - $t0).TotalMilliseconds
        }) | Sort-Object
    [void](Get-WtScheduleAlarms -Now '2026-11-24T09:50:05+09:00' -Previous '2026-11-24T09:49:50+09:00' -Entries $bigEntries -Late 30)
    $steady = @(foreach ($round in 1..3) {
            $t0 = [Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime
            $bigTimer = Get-WtScheduleAlarms -Now '2026-11-24T09:50:05+09:00' -Previous '2026-11-24T09:49:50+09:00' -Entries $bigEntries -Late 30
            ([Diagnostics.Process]::GetCurrentProcess().TotalProcessorTime - $t0).TotalMilliseconds
        }) | Sort-Object
    Assert-WtTest '알람 판정 비용: 일정 300개(매일 반복 30개)에 처음 틱 CPU 0.5초 미만(예전 366일 펼치기는 약 2.3초) · 같은 목록 다음 틱은 0.1초 미만' (
        $big.Success -and $dayCount -gt 30 -and $big.Alarms.Count -eq $dayCount -and $cpu[0] -lt 500 -and $bigTimer.Alarms.Count -eq $dayCount -and $steady[0] -lt 100) (
        "처음 CPU $([int]$cpu[0])ms · 다음 CPU $([int]$steady[0])ms · 알람 $($big.Alarms.Count)/$($bigTimer.Alarms.Count)/$dayCount")

    # ---- 알람 2b (설계 16장): 앱 타이머 모드(-Late) · 늦은 알람 · 하루 종일 기준 · 덮어쓰기 우선순위 · 예전 파일 (화면 없이) ----
    $test = New-WtTestData 'schedule-alarm-timer'; $tests.Add($test)
    Assert-WtTest '알람 기본값: 새 일정 10분 전 · 하루 종일은 업무 시작 · 늦게 켰을 때 시작 뒤 30분 · 다시 알림 5분 · 소리 켬 70%' (
        [int](Get-WtSetting 'schedule.alarmDefault') -eq 10 -and [string](Get-WtSetting 'schedule.alarmAllDay') -ceq '' -and [int](Get-WtSetting 'schedule.alarmLate') -eq 30 -and
        [int](Get-WtSetting 'notice.snooze') -eq 5 -and [bool](Get-WtSetting 'notice.sound') -and [int](Get-WtSetting 'notice.volume') -eq 70 -and (Get-WtWorkHours)['work.start'] -ceq '09:00')
    $store = Open-WtScheduleStore; $k = @{}
    foreach ($pair in @(
            @('meet', @{ title = '회의'; start = @{ date = '2026-11-23'; time = '14:00' }; alarms = @(@{ before = 10 }) }),
            @('loud', @{ title = '덮어쓴 회의'; start = @{ date = '2026-11-23'; time = '14:00' }; alarms = @(@{ before = 10; sound = $false; snooze = 10; late = 60 }) }),
            @('quiet', @{ title = '끈 동안'; start = @{ date = '2026-11-23'; time = '14:30' }; alarms = @(@{ before = 10 }) }),
            @('day', @{ title = '하루 종일'; start = @{ date = '2026-11-24'; time = $null }; alarms = @(@{ before = 10 }) }),
            @('dayAt', @{ title = '하루 종일 7시'; start = @{ date = '2026-11-24'; time = $null }; alarms = @(@{ before = 0; allDayAt = '07:00' }) }),
            @('daily', @{ title = '매일 9시'; start = @{ date = '2026-11-23'; time = '09:00' }; repeat = @{ freq = 'daily' }; alarms = @(@{ before = 5; snooze = 15 }) }))) {
        $r = Save-WtScheduleItem $store $pair[1] -At $alarmAt
        if (-not $r.Success) { throw "알람 2b 준비 $($pair[0]): $($r.Reason)" }
        $k[$pair[0]] = $r.Id; $store = $r.Store
    }
    # 회차 덮어쓰기: 매일 9시의 11-24 회차만 소리 켬 · 다시 알림 30 · 늦은 알람 0(회차 목록이 일정 목록을 대신함)
    $r = Set-WtScheduleOccurrence $store $k.daily '2026-11-24' -Patch @{ alarms = @(@{ before = 5; sound = $true; snooze = 30; late = 0 }) } -At $alarmAt
    if (-not $r.Success) { throw "알람 2b 회차: $($r.Reason)" }
    Wait-WtTestWrites
    $timerEntries = (Get-WtScheduleData).Entries
    $titles = { param($Result) (@($Result.Alarms | ForEach-Object { $_.Title }) | Sort-Object -Culture 'ko-KR') -join ',' }
    $pick = { param($Result, $Name) @($Result.Alarms | Where-Object { $_.Id -ceq $k[$Name] }) }
    $late1355 = Get-WtScheduleAlarms -Now '2026-11-23T13:55:00+09:00' -Entries $timerEntries -Late 30
    $late1431 = Get-WtScheduleAlarms -Now '2026-11-23T14:31:00+09:00' -Entries $timerEntries -Late 30
    $late1501 = Get-WtScheduleAlarms -Now '2026-11-23T15:01:00+09:00' -Entries $timerEntries -Late 30
    $drop1355 = Get-WtScheduleAlarms -Now '2026-11-23T13:55:00+09:00' -Entries $timerEntries -Late 0
    Assert-WtTest '늦은 알람(첫 틱 = 앱을 늦게 켬): 시작 뒤 30분까지만 울림 · 0이면 버림 · 일정의 late(60)가 전역보다 먼저' (
        (& $titles $late1355) -ceq '덮어쓴 회의,회의' -and (& $titles $late1431) -ceq '끈 동안,덮어쓴 회의' -and (& $titles $late1501) -ceq '' -and
        (& $titles $drop1355) -ceq '덮어쓴 회의' -and -not @($late1355.Alarms | Where-Object { -not $_.Late }).Count) (
        "$(& $titles $late1355) / $(& $titles $late1431) / $(& $titles $late1501) / $(& $titles $drop1355)")
    $fresh = Get-WtScheduleAlarms -Now '2026-11-23T13:50:05+09:00' -Previous '2026-11-23T13:49:50+09:00' -Entries $timerEntries -Late 30
    $sleep = Get-WtScheduleAlarms -Now '2026-11-23T14:35:00+09:00' -Previous '2026-11-23T13:00:00+09:00' -Entries $timerEntries -Late 30
    Assert-WtTest '제때 · 잠자기: 2분 안의 틱은 제때(늦은 알람 아님) · 2분 넘게 비면 늦은 알람 규칙(시작 뒤 30분 지난 회의는 버림)' (
        (& $titles $fresh) -ceq '덮어쓴 회의,회의' -and -not @($fresh.Alarms | Where-Object Late).Count -and
        (& $titles $sleep) -ceq '끈 동안,덮어쓴 회의' -and @($sleep.Alarms | Where-Object Late).Count -eq 2) "$(& $titles $fresh) / $(& $titles $sleep)"
    $dayFresh = Get-WtScheduleAlarms -Now '2026-11-24T08:50:05+09:00' -Previous '2026-11-24T08:49:50+09:00' -Entries $timerEntries -Late 30
    $dayNight = Get-WtScheduleAlarms -Now '2026-11-23T23:50:05+09:00' -Previous '2026-11-23T23:49:50+09:00' -Entries $timerEntries -Late 30
    $daySeven = Get-WtScheduleAlarms -Now '2026-11-24T07:00:05+09:00' -Previous '2026-11-24T06:59:50+09:00' -Entries $timerEntries -Late 30
    $dayDirect = Get-WtScheduleAlarms -Now '2026-11-24T07:50:05+09:00' -Previous '2026-11-24T07:49:50+09:00' -Entries $timerEntries -Late 30 -AllDayAt '08:00'
    Set-WtSetting 'work.start' '08:30'
    $dayWork = Get-WtScheduleAlarms -Now '2026-11-24T08:20:05+09:00' -Previous '2026-11-24T08:19:50+09:00' -Entries $timerEntries -Late 30
    Set-WtSetting 'work.start' '09:00'
    $dayItem = @(& $pick $dayFresh 'day')
    Assert-WtTest '하루 종일 기준: 그날 업무 시작(09:00 → 08:50, 08:30으로 바꾸면 08:20) · 설정 직접(08:00 → 07:50) · 일정 allDayAt(07:00)이 먼저 · 전날 23:50에 울리지 않음' (
        $dayItem.Count -eq 1 -and $dayItem[0].Base -eq [datetime]'2026-11-24 09:00' -and $dayItem[0].Due -eq [datetime]'2026-11-24 08:50' -and $dayItem[0].AllDay -and
        -not @($dayNight.Alarms).Count -and (& $titles $daySeven) -ceq '하루 종일 7시' -and (& $titles $dayDirect) -ceq '하루 종일' -and (& $titles $dayWork) -ceq '하루 종일') (
        "$(& $titles $dayFresh) / $(@($dayNight.Alarms).Count) / $(& $titles $daySeven) / $(& $titles $dayDirect) / $(& $titles $dayWork)")
    $morning = Get-WtScheduleAlarms -Now '2026-11-23T09:02:00+09:00' -Entries $timerEntries -Late 30
    $nextMorning = Get-WtScheduleAlarms -Now '2026-11-24T09:02:00+09:00' -Entries $timerEntries -Late 30
    $freshNext = Get-WtScheduleAlarms -Now '2026-11-24T08:55:05+09:00' -Previous '2026-11-24T08:54:50+09:00' -Entries $timerEntries -Late 30
    $meetOpt = @(& $pick $fresh 'meet')[0]; $loudOpt = @(& $pick $fresh 'loud')[0]
    $daily23 = @(& $pick $morning 'daily')[0]; $daily24 = @(& $pick $freshNext 'daily')[0]
    Assert-WtTest '덮어쓰기 우선순위: 회차(이 회차만) > 일정 > 전역(빈 값) — 소리 · 다시 알림 · 늦은 알람' (
        $null -eq $meetOpt.Sound -and $null -eq $meetOpt.Snooze -and $loudOpt.Sound -eq $false -and $loudOpt.Snooze -eq 10 -and
        $daily23 -and $null -eq $daily23.Sound -and $daily23.Snooze -eq 15 -and $daily23.Late -and -not @(& $pick $nextMorning 'daily').Count -and
        $daily24 -and $daily24.Sound -eq $true -and $daily24.Snooze -eq 30 -and -not $daily24.Late) "$($daily23 | ConvertTo-Json -Compress -Depth 2) / $($daily24 | ConvertTo-Json -Compress -Depth 2)"
    $test = New-WtTestData 'schedule-alarm-old'; $tests.Add($test)
    Copy-WtTestFixture 'v2-future.json'
    $oldData = Get-WtScheduleData
    $futureEntry = @($oldData.Entries | Where-Object { $_.Id -ceq 'f1f2f3f4f5f6' })[0]
    $futureAlarm = Get-WtScheduleAlarms -Now '2026-10-29T08:55:05+09:00' -Previous '2026-10-29T08:54:50+09:00' -Entries $oldData.Entries -Late 30
    Copy-WtTestFixture 'v2.json'
    $v2Data = Get-WtScheduleData
    $withAlarm = @($v2Data.Entries | Where-Object { $_.State -eq 'ok' -and @($_.Alarms).Count })
    Assert-WtTest '예전 파일: 덮어쓰기 칸이 없으면 전역 따름 · 모양이 다른 값(sound "chime")도 전역 따름으로 읽고 파일 값은 그대로' (
        $futureEntry.State -eq 'ok' -and @($futureEntry.AlarmOptions).Count -eq 1 -and $null -eq $futureEntry.AlarmOptions[0].Sound -and
        $futureEntry.Item.alarms[0].sound -ceq 'chime' -and @($futureAlarm.Alarms).Count -eq 1 -and $null -eq $futureAlarm.Alarms[0].Sound -and
        $withAlarm.Count -ge 2 -and -not @($withAlarm | ForEach-Object { $_.AlarmOptions } | Where-Object { $null -ne $_.Sound -or $null -ne $_.Snooze -or $null -ne $_.Late -or $null -ne $_.AllDayAt }).Count) (
        "$($futureEntry.State) $(@($futureEntry.AlarmOptions).Count) $(@($futureAlarm.Alarms).Count) $($withAlarm.Count)")

    $test = New-WtTestData 'schedule-preserve-edit'; $tests.Add($test)
    Copy-WtTestFixture 'v2-future.json'
    $data = Get-WtScheduleData
    $originalItems = Get-WtTestJson @($data.Items | Select-Object -Skip 1)
    $r = Save-WtScheduleItem $data.Store @{ alarms = @(@{ before = 15 }); note = '알람만 고침' } -Id $data.Items[0].id -At $at
    Assert-WtTest '일정 공개 편집: 알람 before를 바꿔도 sound · 모르는 알람 · 다른 읽기 전용 항목 보존' ($r.Success -and
        $r.Store.Items[0].alarms[0].sound -ceq 'chime' -and $r.Store.Items[0].alarms[0].before -eq 15 -and $r.Store.Items[0].alarms[1].at -ceq '2026-10-29T08:00' -and
        (Get-WtTestJson @($r.Store.Items | Select-Object -Skip 1)) -ceq $originalItems) $r.Reason
    $r = Save-WtScheduleItem $r.Store @{ alarms = @() } -Id $r.Id -At $at
    Assert-WtTest '일정 알람 끄기: before만 null, 더 새 앱의 칸은 그대로' ($r.Success -and $null -eq $r.Store.Items[0].alarms[0].before -and $r.Store.Items[0].alarms[0].sound -ceq 'chime' -and
        $r.Store.Items[0].alarms[1].at -ceq '2026-10-29T08:00')
    $r = Save-WtScheduleItem $r.Store @{ start = @{ date = '2026-11-02'; time = '09:00' }; repeat = @{ freq = 'weekly'; days = @('mon'); count = 3 } } -At $at
    $resetId = $r.Id
    $r = Set-WtScheduleOccurrence $r.Store $resetId '2026-11-09' -Patch @{ title = '임시 제목' } -At $at
    $r = Set-WtScheduleOccurrence $r.Store $resetId '2026-11-09' -Skip -At $at
    $r = Set-WtScheduleOccurrence $r.Store $resetId '2026-11-09' -Reset -At $at
    $resetItem = @($r.Store.Items | Where-Object id -ceq $resetId)[0]
    Assert-WtTest '일정 회차 Reset: skip · changes 예외를 모두 지우고 원래 회차 되돌림' ($r.Success -and @($resetItem.repeat.skip).Count -eq 0 -and
        @($resetItem.repeat.changes.PSObject.Properties).Count -eq 0 -and @(Get-WtScheduleOccurrences @((ConvertFrom-WtScheduleItem $resetItem)) (& $d '2026-11-09') (& $d '2026-11-09')).Count -eq 1) $r.Reason

    # ---- 3a 루틴: 고정 자료 · 경계 · 증적 (화면 없음) ----
    $test = New-WtTestData 'schedule-routine'; $tests.Add($test)
    Copy-WtTestFixture 'v2-routine.json'
    [IO.File]::Copy((Join-Path $fixtures 'routine-log-v1.json'), (Get-WtStorePath 'routine-log'))
    $at = '2026-10-27T12:00:00+09:00'
    $data = Get-WtScheduleData
    $oldOccurrences = @(Get-WtScheduleOccurrences $data.Entries (& $d '2026-10-27') (& $d '2026-11-03'))
    $oldAlarms = Get-WtScheduleAlarms -Entries $data.Entries -Now $at -Previous '2026-10-27T08:00:00+09:00'
    Assert-WtTest '루틴 호환: 옛 일정 해석기는 같은 schema 2의 routine을 읽기 전용 · 계산/알람 제외' ($data.Store.Schema -eq 2 -and
        ($data.Entries.State -join ',') -ceq 'readonly,readonly,readonly,readonly' -and -not $oldOccurrences.Count -and -not $oldAlarms.Alarms.Count)
    $slots = @(Get-WtRoutineSlots -Date '2026-10-27' -Now $at)
    $hourly = @($slots | Where-Object { $_.Routine.Id -ceq 'routine-hour' })
    Assert-WtTest '루틴 차례: 주중 7개 · hourly 09/11/13/15/17 · to 미포함 · 다음은 13시' ($slots.Count -eq 7 -and
        ($hourly.Slot -join ',') -ceq '2026-10-27T09:00,2026-10-27T11:00,2026-10-27T13:00,2026-10-27T15:00,2026-10-27T17:00' -and
        (@($hourly | Where-Object Next).Slot -join ',') -ceq '2026-10-27T13:00') ($hourly.Slot -join ',')
    Assert-WtTest '루틴 체크 읽기: 살아 있는 2개만 Done · 푼 기록은 미완료 · DoneAt 원문' (@($slots | Where-Object Done).Count -eq 2 -and
        @($slots | Where-Object { $_.Routine.Id -ceq 'routine-week' })[0].DoneAt -ceq '2026-10-27T09:01:00+09:00' -and
        -not @($slots | Where-Object { $_.Routine.Id -ceq 'routine-work' })[0].Done)
    $equalNow = @(Get-WtRoutineSlots -Date '2026-10-27' -Now '2026-10-27T13:00:00+09:00' | Where-Object Next)
    $endNow = @(Get-WtRoutineSlots -Date '2026-10-27' -Now '2026-10-27T18:00:00+09:00' | Where-Object Next)
    Assert-WtTest '루틴 다음 차례: 지금과 같은 차례 제외 · 구간 끝이면 없음' ($equalNow.Count -eq 1 -and $equalNow[0].Slot -ceq '2026-10-27T15:00' -and -not $endNow.Count)
    Assert-WtTest '루틴 시작 전날: 차례 없음' (@(Get-WtRoutineSlots -Date '2026-10-26' -Now $at).Count -eq 0)
    $weekend = @(Get-WtRoutineSlots -Date '2026-10-31' -Now $at)
    Assert-WtTest '루틴 주말: weekly와 workdaysOnly 제외 · 일반 hourly는 남음' ($weekend.Count -eq 5 -and @($weekend | Where-Object { $_.Routine.Id -cne 'routine-hour' }).Count -eq 0)
    foreach ($kind in 'public', 'company', 'personal') {
        $holiday = Set-WtHolidayDate (Get-WtHolidayData).Store '2026-10-28' $kind -At $at
        $offSlots = @(Get-WtRoutineSlots -Date '2026-10-28' -Now $at)
        # 2026-11-05 규칙 변경: 휴무일 · 휴가에는 어떤 루틴도 차례가 없다(workdaysOnly는 근무 요일 밖만 뺀다)
        Assert-WtTest "루틴 휴무일($kind): 모든 루틴 제외" ($holiday.Success -and $offSlots.Count -eq 0) ($offSlots.Slot -join ',')
    }
    Register-WtCalendarSource 'routine-test-leave' {
        param([datetime]$From, [datetime]$To)
        [pscustomobject]@{ Date = ConvertFrom-WtDateText '2026-10-29'; Kind = 'leave'; Style = 'Att.Leave'; Text = '휴가 시험'; AllDay = $true; Time = $null; Id = 'fake-leave' }
    }
    try {
        $leaveSlots = @(Get-WtRoutineSlots -Date '2026-10-29' -Now $at)
        $leaveCheck = Set-WtRoutineCheck -Routine 'routine-work' -Slot '2026-10-29' -Done $true -At $at
        Assert-WtTest '루틴 휴가: 코어 달력 등록 목록으로 모든 루틴 제외 · 그 차례 체크 거부' ($leaveSlots.Count -eq 0 -and -not $leaveCheck.Success -and $leaveCheck.Reason)
    } finally { Register-WtCalendarSource 'routine-test-leave' $null }
    # 4단계(설계 15.5): 반차(하루의 일부인 휴가, AllDay = $false)는 일하는 날이라 루틴을 쉬지 않는다
    Register-WtCalendarSource 'routine-test-half' {
        param([datetime]$From, [datetime]$To)
        [pscustomobject]@{ Date = ConvertFrom-WtDateText '2026-10-29'; Kind = 'leave'; Style = 'Att.Leave'; Text = '오전 반차'; AllDay = $false; Time = '09:00'; Id = 'fake-half' }
    }
    try {
        $halfSlots = @(Get-WtRoutineSlots -Date '2026-10-29' -Now $at)
        $halfMark = Get-WtCalendarMark ([datetime]::new(2026, 10, 29)) @((Get-WtCalendarItems ([datetime]::new(2026, 10, 29)) ([datetime]::new(2026, 10, 29))).Items)
        Assert-WtTest '루틴 반차 날: 쉬지 않고 평소 차례가 있다, 달력 표시는 휴가 색이지만 쉬는 날은 아님' ($halfSlots.Count -gt 0 -and $halfMark.Kind -ceq 'leave' -and -not $halfMark.DayOff) "$($halfSlots.Slot -join ',') / $($halfMark.Kind) $($halfMark.DayOff)"
    } finally { Register-WtCalendarSource 'routine-test-half' $null }
    $thread = [Threading.Thread]::CurrentThread; $oldCulture = $thread.CurrentCulture; $oldUiCulture = $thread.CurrentUICulture
    $snapshots = @()
    try {
        foreach ($culture in 'ko-KR', 'en-US', 'th-TH', 'ar-SA', 'ja-JP') {
            $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture); $thread.CurrentUICulture = $thread.CurrentCulture
            $snapshots += (@(Get-WtRoutineSlots -Date '2026-10-27' -Now $at | ForEach-Object { $_.Routine.Id + '@' + $_.Slot }) -join ',')
        }
    } finally { $thread.CurrentCulture = $oldCulture; $thread.CurrentUICulture = $oldUiCulture }
    $expectedRoutine = 'routine-week@2026-10-27,routine-hour@2026-10-27T09:00,routine-hour@2026-10-27T11:00,routine-hour@2026-10-27T13:00,routine-hour@2026-10-27T15:00,routine-hour@2026-10-27T17:00,routine-work@2026-10-27'
    Assert-WtTest '루틴 문화권 5개: 그레고리력 · 요일 · slot 키가 고정 기대값과 같음' (@($snapshots | Where-Object { $_ -cne $expectedRoutine }).Count -eq 0) ($snapshots -join "`n")
    $scheduleBefore = [IO.File]::ReadAllText((Get-WtStorePath 'schedule'))
    $r = Set-WtRoutineCheck -Routine 'routine-hour' -Slot '2026-10-27T09:00' -Done $true -At $at
    $checkId = $r.Id; $created = @($r.Store.Items | Where-Object id -ceq $checkId)[0].created; $priorLog = $r.Store
    Assert-WtTest '루틴 새 체크: id 12자리 · rev 0 · 앱 시각 +09:00 · 원래 핸들 불변' ($r.Success -and $checkId -cmatch '^[a-f0-9]{12}$' -and
        @($r.Store.Items | Where-Object id -ceq $checkId)[0].rev -eq 0 -and $created -ceq $at)
    $r = Set-WtRoutineCheck -Routine 'routine-hour' -Slot '2026-10-27T09:00' -Done $false -Store $r.Store -At '2026-10-27T12:01:00+09:00'
    $undone = @($r.Store.Items | Where-Object id -ceq $checkId)[0]
    Assert-WtTest '루틴 체크 풀기: 행 삭제 없이 deleted · at/created 보존 · rev 1 · 옛 핸들 불변' ($r.Success -and $undone.deleted -ceq '2026-10-27T12:01:00+09:00' -and
        $undone.at -ceq $at -and $undone.created -ceq $created -and $undone.rev -eq 1 -and -not (Test-WtDeleted @($priorLog.Items | Where-Object id -ceq $checkId)[0]))
    $r = Set-WtRoutineCheck -Routine 'routine-hour' -Slot '2026-10-27T09:00' -Done $true -Store $r.Store -At '2026-10-27T12:02:00+09:00'
    $checked = @($r.Store.Items | Where-Object id -ceq $checkId)[0]
    Assert-WtTest '루틴 다시 체크: 같은 행/id · deleted null · at 갱신 · created 유지 · rev 2' ($r.Success -and $r.Id -ceq $checkId -and $r.Store.Items.Count -eq 5 -and
        $null -eq $checked.deleted -and $checked.at -ceq '2026-10-27T12:02:00+09:00' -and $checked.created -ceq $created -and $checked.rev -eq 2)
    $history = @(Get-WtRoutineHistory -From '2026-01-01' -To '2026-10-27' -Store $r.Store)
    $dailyHistory = @(Get-WtRoutineHistory -From '2026-10-27' -To '2026-10-27' -Routine 'routine-work' -Store $r.Store)
    Assert-WtTest '루틴 기록: slot 날짜 양끝 포함 · 루틴별 · 지운 체크/오래된 증적도 포함 · 일정 바이트 불변' ($history.Count -eq 5 -and $dailyHistory.Count -eq 1 -and
        (Test-WtDeleted $dailyHistory[0]) -and @($history | Where-Object id -ceq 'check-evidence').Count -eq 1 -and [IO.File]::ReadAllText((Get-WtStorePath 'schedule')) -ceq $scheduleBefore)
    $history[0].at = '바깥에서 고침'
    Assert-WtTest '루틴 기록 조회: 돌려준 복사본 편집은 핸들을 바꾸지 않음' ($r.Store.Items[0].at -ceq '2026-10-27T09:01:00+09:00')
    $logBefore = [IO.File]::ReadAllText((Get-WtStorePath 'routine-log'))
    foreach ($slot in '2026-10-27T10:00', '2026-10-27T18:00', '2026-10-26T09:00', '2026-02-30T09:00', '2026-10-27') {
        $bad = Set-WtRoutineCheck -Routine 'routine-hour' -Slot $slot -Done $true -At $at
        Assert-WtTest "루틴 없는 차례 거부: $slot · 기록 그대로" (-not $bad.Success -and $bad.Reason -and [IO.File]::ReadAllText((Get-WtStorePath 'routine-log')) -ceq $logBefore)
    }
    $unknownOriginal = Get-WtTestJson (Read-WtTestDoc).items[3]
    $badEdit = Save-WtRoutine (Open-WtScheduleStore) @{ title = '고치지 못함' } -Id 'routine-future' -At $at
    $badDelete = Set-WtRoutineDeleted -Id 'routine-future' -At $at
    $badCheck = Set-WtRoutineCheck -Routine 'routine-future' -Slot '2026-10-27' -Done $true -At $at
    Assert-WtTest '루틴 모르는 freq: 편집/지우기/체크 거부 · 계산 제외 · 원문 유지' (-not $badEdit.Success -and -not $badDelete.Success -and -not $badCheck.Success -and
        $unknownOriginal -ceq (Get-WtTestJson (Read-WtTestDoc).items[3]) -and @($slots | Where-Object { $_.Routine.Id -ceq 'routine-future' }).Count -eq 0)
    $r = Save-WtRoutine (Open-WtScheduleStore) @{ title = '평일 점검 수정' } -Id 'routine-week' -At $at
    $saved = Read-WtTestDoc
    Assert-WtTest '루틴 저장 왕복: 제목은 같은 id/rev 1 · schema 2 · 맨 위/항목/start/routine/end/alarms의 모르는 칸 보존' ($r.Success -and $r.Id -ceq 'routine-week' -and
        $saved.schema -eq 2 -and $saved.items[0].rev -eq 1 -and ($saved.futureTop.keep -join ',') -ceq '원문,7' -and $saved.items[0].futureItem -ceq '보존' -and
        $saved.items[0].start.futureStart -ceq '보존' -and $saved.items[0].routine.futureRule.keep -and $saved.items[0].end.futureEnd -ceq '해석하지 않고 보존' -and $saved.items[0].alarms[0].futureAlarm)
    $priorSchedule = $r.Store
    $r = Save-WtRoutine $r.Store @{ routine = @{ days = @(2, 4) } } -Id 'routine-week' -At $at
    $newRoutineId = $r.Id
    $oldRoutine = @($r.Store.Items | Where-Object id -ceq 'routine-week')[0]; $newRoutine = @($r.Store.Items | Where-Object id -ceq $newRoutineId)[0]
    Assert-WtTest '루틴 규칙 변경: 첫 회차부터 새 id/계열 · 옛 루틴 지운 표시 · split 출처 · 옛 기록 바이트 그대로' ($r.Success -and $newRoutineId -cne 'routine-week' -and
        (Test-WtDeleted $oldRoutine) -and $newRoutine.rev -eq 0 -and $newRoutine.origin.from -ceq 'split' -and $newRoutine.origin.id -ceq 'routine-week' -and
        $newRoutine.routine.futureRule.keep -and $priorSchedule.Items.Count -eq 4 -and [IO.File]::ReadAllText((Get-WtStorePath 'routine-log')) -ceq $logBefore)
    $staleError = $null; try { [void](Save-WtRoutine $priorSchedule @{ title = '낡은 편집' } -Id 'routine-hour' -At $at) } catch { $staleError = $_.Exception.Message }
    Assert-WtTest '루틴 저장: 낡은 일정 핸들은 예외 · 앞 저장 유지' ($staleError -like '*바뀌었습니다*' -and (Read-WtTestDoc).items.Count -eq 5) $staleError
    $newSlots = @(Get-WtRoutineSlots -Date '2026-10-27' -Now $at)
    $oldHistory = @(Get-WtRoutineHistory -From '2026-10-27' -To '2026-10-27' -Routine 'routine-week')
    Assert-WtTest '루틴 새 계열: 옛 id 차례 없음 · 새 id 미체크 · 옛 기록은 옛 id로 조회' (@($newSlots | Where-Object { $_.Routine.Id -ceq 'routine-week' }).Count -eq 0 -and
        @($newSlots | Where-Object { $_.Routine.Id -ceq $newRoutineId }).Count -eq 1 -and -not @($newSlots | Where-Object { $_.Routine.Id -ceq $newRoutineId })[0].Done -and $oldHistory.Count -eq 1)
    $r = Set-WtRoutineDeleted -Id 'routine-hour' -Deleted $true -At $at
    $gone = @(Get-WtRoutineSlots -Date '2026-10-27' -Now $at | Where-Object { $_.Routine.Id -ceq 'routine-hour' })
    $hourHistory = @(Get-WtRoutineHistory -From '2026-10-27' -To '2026-10-27' -Routine 'routine-hour')
    $bad = Set-WtRoutineCheck -Routine 'routine-hour' -Slot '2026-10-27T11:00' -Done $true -At $at
    Assert-WtTest '루틴 지우기: 차례/새 체크 제외 · 과거 체크 2개 유지 · 기록 파일 불변' ($r.Success -and -not $gone.Count -and -not $bad.Success -and
        $hourHistory.Count -eq 2 -and [IO.File]::ReadAllText((Get-WtStorePath 'routine-log')) -ceq $logBefore)
    $expired = Set-WtRoutineDeleted -Id 'routine-hour' -Deleted $false -At '2027-01-25T12:00:00+09:00'
    $restore = Set-WtRoutineDeleted -Id 'routine-hour' -Deleted $false -At '2027-01-24T12:00:00+09:00'
    Assert-WtTest '루틴 보존 규칙: 89일 되살림 · 정확히 90일 거부' ($restore.Success -and -not $expired.Success -and $expired.Reason)
    $r = Set-WtRoutineCheck -Routine 'routine-work' -Slot '2026-10-27' -Done $true -At $at
    $savedLog = [IO.File]::ReadAllText((Get-WtStorePath 'routine-log')) | ConvertFrom-Json -Depth 20 -DateKind String
    Assert-WtTest '루틴 기록 저장 왕복: schema 1 · 맨 위/체크의 모르는 칸 · 오래된 살아 있는 증적 보존' ($r.Success -and $r.Id -ceq 'check-undone' -and
        $savedLog.schema -eq 1 -and $savedLog.futureTop.keep -and $savedLog.items[0].futureCheck.keep -ceq '보존' -and @($savedLog.items | Where-Object id -ceq 'check-evidence').Count -eq 1)
    $staleLog = $r.Store
    $r = Set-WtRoutineCheck -Routine 'routine-work' -Slot '2026-10-27' -Done $false -Store $r.Store -At $at
    $staleError = $null; try { [void](Set-WtRoutineCheck -Routine 'routine-work' -Slot '2026-10-27' -Done $true -Store $staleLog -At $at) } catch { $staleError = $_.Exception.Message }
    Assert-WtTest '루틴 체크: 낡은 로그 핸들은 예외 · 앞의 지운 표시 유지' ($staleError -like '*바뀌었습니다*' -and
        (Test-WtDeleted @($r.Store.Items | Where-Object id -ceq 'check-undone')[0])) $staleError

    $test = New-WtTestData 'schedule-routine-new'; $tests.Add($test)
    $r = New-WtRoutine -Title '긴 간격' -Freq hourly -Every 12 -At $at
    $id = $r.Id; $raw = $r.Store.Items[0]
    Assert-WtTest '루틴 생성: KST 오늘부터 · hourly 구간은 만들 때 설정 복사 · end/alarms/계산 값 저장 안 함' ($r.Success -and $raw.start.date -ceq '2026-10-27' -and
        $raw.routine.from -ceq '09:00' -and $raw.routine.to -ceq '18:00' -and $raw.PSObject.Properties.Name -cnotcontains 'end' -and
        $raw.PSObject.Properties.Name -cnotcontains 'alarms' -and $raw.PSObject.Properties.Name -cnotcontains 'slots')
    # 이 시험 전용 데이터 폴더의 설정만 바꾼다. 실제 설정에는 닿지 않는다.
    $hours = Get-WtWorkHours; $hours['work.start'] = '08:00'; $hours['work.end'] = '19:00'; Set-WtWorkHours $hours
    $longSlots = @(Get-WtRoutineSlots -Date '2026-10-27' -Now $at)
    Assert-WtTest '루틴 긴 간격: 구간보다 every가 크면 from 하나 · 나중 설정 변경은 기존 루틴에 영향 없음' ($longSlots.Count -eq 1 -and $longSlots[0].Slot -ceq '2026-10-27T09:00')
    $r = New-WtRoutine -Title '끝 제외' -Freq hourly -Every 1 -From '09:00' -To '11:00' -Start '2026-10-28' -At $at
    $edgeId = $r.Id
    $edges = @(Get-WtRoutineSlots -Date '2026-10-28' -Now $at | Where-Object { $_.Routine.Id -ceq $edgeId })
    Assert-WtTest '루틴 hourly: to 정각 미포함 · 시작 날짜 지정' ($r.Success -and ($edges.Slot -join ',') -ceq '2026-10-28T09:00,2026-10-28T10:00')
    $r = New-WtRoutine -Title '일요일' -Freq weekly -Days @(7) -Start '2026-10-27' -At $at
    $sundayId = $r.Id
    $sunday = @(Get-WtRoutineSlots -Date '2026-11-01' -Now $at | Where-Object { $_.Routine.Id -ceq $sundayId })
    Assert-WtTest '루틴 weekly 요일은 work.days와 독립 · 월=1/일=7 · workdaysOnly 기본 false' ($r.Success -and $sunday.Count -eq 1 -and $sunday[0].Slot -ceq '2026-11-01' -and -not $sunday[0].Next)
    foreach ($badPatch in @(@{ routine = @{ every = 0 } }, @{ routine = @{ every = 13 } }, @{ routine = @{ every = 1.5 } }, @{ routine = @{ from = '18:00'; to = '09:00' } })) {
        $bad = Save-WtRoutine (Open-WtScheduleStore) $badPatch -Id $id -At $at
        Assert-WtTest '루틴 잘못된 간격/구간은 결과로 거부' (-not $bad.Success -and $bad.Reason)
    }
    $badDays = New-WtRoutine -Title '틀린 요일' -Freq weekly -Days @(0, 8) -At $at
    Assert-WtTest '루틴 잘못된 요일 거부' (-not $badDays.Success -and $badDays.Reason)
    $r = Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ freq = 'daily' } } -Id $sundayId -At $at
    $dailyId = $r.Id; $dailyRaw = @($r.Store.Items | Where-Object id -ceq $dailyId)[0]
    Assert-WtTest '루틴 빈도 변경: 새 계열 · daily에는 days/every/from/to 없음' ($r.Success -and $dailyId -cne $sundayId -and
        @($dailyRaw.routine.PSObject.Properties.Name | Where-Object { $_ -cin 'days', 'every', 'from', 'to' }).Count -eq 0)
    $r = Set-WtRoutineCheck -Routine $dailyId -Slot '2026-10-27' -Done $true -At $at
    $r = Set-WtRoutineCheck -Routine $dailyId -Slot '2026-10-27' -Done $false -Store $r.Store -At $at
    $expiredCheck = Set-WtRoutineCheck -Routine $dailyId -Slot '2026-10-27' -Done $true -Store $r.Store -At '2027-01-25T12:00:00+09:00'
    Assert-WtTest '루틴 푼 체크도 공통 90일 되살리기 제한 적용' (-not $expiredCheck.Success -and $expiredCheck.Reason)
    $retainedId = $r.Id
    $r = Set-WtRoutineCheck -Routine $dailyId -Slot '2026-10-28' -Done $true -Store $r.Store -At '2027-01-26T12:00:00+09:00'
    $tombstone = @($r.Store.Items | Where-Object id -ceq $retainedId)[0]
    Assert-WtTest '루틴 공통 보존: 지운 지 90일 넘은 로그는 id/deleted만 · 살아 있는 체크는 남김' ($r.Success -and
        ($tombstone.PSObject.Properties.Name -join ',') -ceq 'id,deleted' -and $r.Store.Items.Count -eq 2)
    $refused = '{ "schema": 2, "items": [] }'
    [IO.File]::WriteAllText((Get-WtStorePath 'routine-log'), $refused, [Text.UTF8Encoding]::new($false))
    $refusedStore = Open-WtStore -Name 'routine-log' -Schema 1
    $refusedError = $null; try { [void](Set-WtRoutineCheck -Routine $dailyId -Slot '2026-10-27' -Done $true -Store $refusedStore -At $at) } catch { $refusedError = $_.Exception.Message }
    $historyError = $null; try { [void](Get-WtRoutineHistory -From '2026-10-27' -To '2026-10-28') } catch { $historyError = $_.Exception.Message }
    $slotsError = $null; try { [void](Get-WtRoutineSlots -Date '2026-10-27' -Now $at) } catch { $slotsError = $_.Exception.Message }
    Assert-WtTest '루틴 못 읽는 로그: 쓰기/기록/차례 조회 모두 오류 · 원본 불변' ($refusedStore.State -ceq 'error' -and $refusedError -and $historyError -and $slotsError -and
        [IO.File]::ReadAllText((Get-WtStorePath 'routine-log')) -ceq $refused)


    # -From 경계: 앞날 증적과 옛 계열을 남기고 이후 차례만 새 id로 만든다.
    $test = New-WtTestData 'routine-from'; $tests.Add($test)
    $at = '2026-10-27T12:00:00+09:00'
    $r = New-WtRoutine -Title '계열 나누기' -Freq hourly -Every 2 -From '09:00' -To '18:00' -Start '2026-10-25' -At $at
    $originalId = $r.Id
    [void](Set-WtRoutineCheck -Routine $originalId -Slot '2026-10-26T11:00' -Done $true -At $at)
    $r = Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ every = 3 } } -Id $originalId -From '2026-10-27' -At $at
    $beforeSlots = @(Get-WtRoutineSlots '2026-10-26' -Now $at)
    $afterSlots = @(Get-WtRoutineSlots '2026-10-27' -Now $at)
    $old = @($r.Store.Items | Where-Object id -ceq $originalId)[0]
    Assert-WtTest '루틴 From: 옛 계열 전날 종료 · 지우지 않음 · 새 계열 시작일/출처' ($r.Success -and $r.Id -cne $originalId -and
        -not (Test-WtDeleted $old) -and $old.routine.until -ceq '2026-10-26' -and
        @($r.Store.Items | Where-Object id -ceq $r.Id)[0].start.date -ceq '2026-10-27')
    Assert-WtTest '루틴 From: 나누기 전날은 옛 id 5차례/체크 유지 · 그날은 새 id 3차례만' (
        ($beforeSlots.Slot -join ',') -ceq '2026-10-26T09:00,2026-10-26T11:00,2026-10-26T13:00,2026-10-26T15:00,2026-10-26T17:00' -and
        @($beforeSlots | Where-Object { $_.Routine.Id -ceq $originalId }).Count -eq 5 -and $beforeSlots[1].Done -and
        ($afterSlots.Slot -join ',') -ceq '2026-10-27T09:00,2026-10-27T12:00,2026-10-27T15:00' -and
        @($afterSlots | Where-Object { $_.Routine.Id -ceq $r.Id }).Count -eq 3)
    $correction = Set-WtRoutineCheck -Routine $originalId -Slot '2026-10-26T11:00' -Done $false -At $at
    Assert-WtTest '루틴 From: 지난 계열의 전날 체크 보정 가능 · 끝 다음 날 옛 차례는 거부' (
        $correction.Success -and -not (Set-WtRoutineCheck -Routine $originalId -Slot '2026-10-27T11:00' -Done $true -At $at).Success)
    $invalidCut = Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ every = 4 } } -Id $r.Id -From '2026-10-26' -At $at
    Assert-WtTest '루틴 From: 시작 전 날짜는 저장 거부' (-not $invalidCut.Success -and $invalidCut.Reason)

    # ---- 3단계 (설계 14장): 루틴 시각 · 태그 글 · 찾기 · 표 · 할 일 ----
    $test = New-WtTestData 'schedule-phase3'; $tests.Add($test)
    $now = '2026-11-05T12:00:00+09:00'
    $morning = Save-WtRoutine (Open-WtScheduleStore) @{ title = '아침 확인'; start = @{ date = '2026-11-01' }; routine = @{ freq = 'daily'; time = '09:00' } } -At $now
    $morningSlots = @(Get-WtRoutineSlots -Date '2026-11-05' -Now $now | Where-Object { $_.Routine.Id -ceq $morning.Id })
    [void](Set-WtRoutineCheck -Routine $morning.Id -Slot '2026-11-04' -Done $true -At $now)
    $retimed = Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ time = '08:30' } } -Id $morning.Id -At $now
    $retimedSlots = @(Get-WtRoutineSlots -Date '2026-11-04' -Now $now | Where-Object { $_.Routine.Id -ceq $morning.Id })
    Assert-WtTest '루틴 시각: 매일 · 요일 루틴의 선택 칸, 시각만 바꾸면 같은 id(나누지 않음) · 체크 기록 유지' (
        $morning.Success -and $morningSlots.Count -eq 1 -and $morningSlots[0].Routine.Time -ceq '09:00' -and $morningSlots[0].Routine.Freq -ceq 'daily' -and
        $retimed.Success -and $retimed.Id -ceq $morning.Id -and $retimedSlots[0].Routine.Time -ceq '08:30' -and $retimedSlots[0].Done) "$($retimed.Id) / $($retimedSlots[0].Routine.Time)"
    $badTime = Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ time = '9시' } } -Id $morning.Id -At $now
    $cleared = Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ time = '' } } -Id $morning.Id -At $now
    $clearedRaw = @($cleared.Store.Items | Where-Object id -ceq $morning.Id)[0]
    $hourlyFromTimed = Save-WtRoutine (Open-WtScheduleStore) @{ title = '시각 루틴'; start = @{ date = '2026-11-01' }; routine = @{ freq = 'weekly'; days = @(1, 2, 3, 4, 5); time = '10:00' } } -At $now
    $toHourly = Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ freq = 'hourly'; every = 2; from = '09:00'; to = '18:00' } } -Id $hourlyFromTimed.Id -At $now
    $toHourlyRaw = @($toHourly.Store.Items | Where-Object id -ceq $toHourly.Id)[0]
    $hourlyWithTime = ConvertFrom-WtRoutineItem (ConvertTo-WtTestItem '{ "id": "h1", "kind": "routine", "title": "x", "start": { "date": "2026-11-01" }, "routine": { "freq": "hourly", "every": 2, "from": "09:00", "to": "18:00", "time": 7 } }')
    Assert-WtTest '루틴 시각: 틀린 모양은 거부, 비우면 칸을 빼고, 시간마다로 바꾸면 빼며, 시간마다의 time은 읽지 않고 둔다' (
        -not $badTime.Success -and $cleared.Success -and $clearedRaw.routine.PSObject.Properties.Name -cnotcontains 'time' -and
        $toHourly.Success -and $toHourlyRaw.routine.PSObject.Properties.Name -cnotcontains 'time' -and $hourlyWithTime.State -ceq 'ok' -and $null -eq $hourlyWithTime.Time) "$($badTime.Reason)"
    [void](Set-WtRoutineDeleted -Id $toHourly.Id -At $now)
    [void](Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ time = '09:00' } } -Id $morning.Id -At $now)
    Assert-WtTest '태그 글: 쉼표 · 공백으로 나누고 앞 #을 떼며, 빈 것 · 겹친 것(대소문자 무시)을 빼고 순서를 지킨다' (
        (@(ConvertFrom-WtScheduleTagText '#점검, 작업 점검  ,# Work work') -join '|') -ceq '점검|작업|Work')

    $mk = { param($Title, $From, $FromTime, $To, $ToTime, [string[]]$Tags) (Save-WtScheduleItem (Open-WtScheduleStore) @{ title = $Title; start = @{ date = $From; time = $FromTime }; end = $(if ($To) { @{ date = $To; time = $ToTime } } else { $null }); tags = @($Tags) }).Id }
    $past = & $mk '지난 일' '2026-11-03' '10:00' $null $null @('작업')
    [void](& $mk '오래된 일' '2026-10-20' '10:00' $null $null @())
    $pastDone = & $mk '끝낸 지난 일' '2026-11-04' '15:00' $null $null @()
    $todayOne = & $mk '오늘 일' '2026-11-05' '14:00' $null $null @('점검', '작업')
    [void](& $mk '이어진 일' '2026-11-03' $null '2026-11-06' $null @())
    [void](& $mk '곧 끝날 일' '2026-11-06' $null '2026-11-08' $null @())
    [void](& $mk '먼 일' '2026-11-06' $null '2026-11-12' $null @())
    [void](& $mk '달 넘는 일' '2026-10-30' $null '2026-11-02' $null @())
    [void](Set-WtEventCheck -Event $pastDone -Date '2026-11-04' -Done $true -At $now)
    $due = Get-WtScheduleDueRows -Now $now
    $dueShape = (@($due.Rows | ForEach-Object { "$($_.Group):$($_.Title):$((Get-WtScheduleDue $_ ([datetime]'2026-11-05')).Text)" }) -join ',')
    Assert-WtTest '할 일: 기한 지남(지난 7일 · 안 끝냄) → 오늘(이어진 것 · 시각순, 루틴 포함) → 마감 임박(3일 안 · 하루 종일 여러 날)' (
        $due.Success -and $dueShape -ceq 'overdue:달 넘는 일:3일 지남,overdue:지난 일:2일 지남,today:이어진 일:D-1,today:아침 확인:오늘,today:오늘 일:오늘,soon:곧 끝날 일:D-3') $dueShape
    $oldDue = Get-WtScheduleDue ([pscustomobject]@{ Kind = 'event'; Done = $false; DueDate = [datetime]'2026-10-28'; Date = [datetime]'2026-10-28' }) ([datetime]'2026-11-05')
    $overDue = Get-WtScheduleDue @($due.Rows)[0] ([datetime]'2026-11-05')
    Assert-WtTest '할 일 수: 안 끝낸 일정 + 오늘 차례가 남은 루틴, 기한은 8일 지나면 비우고 기한 지남에만 경고' (
        (Get-WtScheduleDueCount -Now $now) -eq 6 -and $oldDue.Text -ceq '' -and -not $oldDue.Overdue -and $overDue.Overdue) "$(Get-WtScheduleDueCount -Now $now)"
    $month = Get-WtScheduleMonthRows ([datetime]'2026-11-01') -Now $now
    $monthShape = (@($month.Rows | ForEach-Object { "$($_.Date.ToString('MM-dd', $inv)) $($_.Title)" }) -join ',')
    Assert-WtTest '표 보기(보는 달): 그 달에 걸친 회차, 달 앞에서 시작한 여러 날은 1일 자리, 오늘 루틴 포함, 날 → 하루 종일 → 시각 순' (
        $monthShape -ceq '11-01 달 넘는 일,11-03 이어진 일,11-03 지난 일,11-04 끝낸 지난 일,11-05 아침 확인,11-05 오늘 일,11-06 곧 끝날 일,11-06 먼 일') $monthShape
    $byTag = Find-WtScheduleRows '#점검' -Now $now
    $openDay = Find-WtScheduleRows 'is:open 2026-11-03' -Now $now
    $titleOr = Find-WtScheduleRows '(title:지난 OR #점검) -is:done' -Now $now
    $routineFind = Find-WtScheduleRows 'is:routine 2026-11-01..2026-11-03' -Now $now
    $badFind = Find-WtScheduleRows 'is:later' -Now $now
    $cut = Find-WtScheduleRows '일' -Now $now -Limit 2
    Assert-WtTest '일정 찾기: #태그 · 맨 날짜 · is:open/done · 괄호 OR · is:routine(기간 안 날마다), 틀린 식은 위치, 줄 수 제한' (
        (@($byTag.Rows | ForEach-Object Title) -join ',') -ceq '오늘 일' -and (@($openDay.Rows | ForEach-Object Title) -join ',') -ceq '이어진 일,지난 일' -and
        (@($titleOr.Rows | ForEach-Object Title) -join ',') -ceq '지난 일,오늘 일' -and
        (@($routineFind.Rows | ForEach-Object { "$($_.Kind):$($_.Date.ToString('MM-dd', $inv))" }) -join ',') -ceq 'routine:11-01,routine:11-02,routine:11-03' -and
        -not $badFind.Success -and $badFind.Error.Position -eq 0 -and $cut.Truncated -and $cut.Rows.Count -eq 2 -and $cut.Count -gt 2) (
        "$(@($byTag.Rows).Title -join ',') / $(@($openDay.Rows).Title -join ',') / $(@($titleOr.Rows).Title -join ',') / $(@($routineFind.Rows | ForEach-Object { $_.Date.ToString('MM-dd', $inv) }) -join ',')")
    $farFind = Find-WtScheduleRows '2024-03-01' -Now $now
    Assert-WtTest '일정 찾기: 식 속 날짜가 앞뒤 1년 밖이면 찾는 기간을 그 날짜까지 넓힌다' ($farFind.Success -and $farFind.From -le [datetime]'2024-03-01') "$($farFind.From)"

    # 집계는 행을 한 번만 전개하고, 만료·날짜·저장·외부 변경은 다음 조회에 반영한다.
    $summaryChecks = & (Get-Module ScheduleData) {
        param($Now, $Event)
        $original = ${function:Get-WtScheduleDueRows}
        $script:summaryRowsOriginal = $original; $script:summaryRowsCalls = 0; $script:dueCountCache = $null
        function script:Get-WtScheduleDueRows { param($Now) $script:summaryRowsCalls++; & $script:summaryRowsOriginal -Now $Now }
        try {
            $count = Get-WtScheduleDueCount -Now $Now
            $summary = Get-WtScheduleDueSummary -Now $Now
            $once = $script:summaryRowsCalls -eq 1 -and $summary.Count -eq $count -and $count -eq 6
            [void](Get-WtScheduleDueSummary -Now '2026-11-05T12:01:00+09:00')
            $expired = $script:summaryRowsCalls -eq 2
            [void](Get-WtScheduleDueSummary -Now '2026-11-06T00:00:00+09:00')
            $dateChanged = $script:summaryRowsCalls -eq 3
            [void](Get-WtScheduleDueSummary -Now $Now)
            [void](Set-WtEventCheck -Event $Event -Date '2026-11-05' -Done $true -At $Now)
            $saved = (Get-WtScheduleDueSummary -Now $Now).Count -eq 5 -and $script:summaryRowsCalls -eq 5
            Wait-WtTestWrites
            $path = Get-WtStorePath 'schedule'; $at = [IO.File]::GetLastWriteTimeUtc($path)
            $raw = [IO.File]::ReadAllText($path)
            [IO.File]::WriteAllText($path, $raw.Replace('오늘 일','오늘 건'), [Text.UTF8Encoding]::new($false))
            [IO.File]::SetLastWriteTimeUtc($path, $at)
            [void](Get-WtScheduleDueSummary -Now $Now)
            $external = $script:summaryRowsCalls -eq 6
            $signal = @{ Text = '가짜 휴가' }
            Register-WtCalendarSource -Id 'test-summary' -CalendarItems ({ param($From,$To)
                @{Date=$From;Kind='leave';Text=$signal.Text;Style='leave';Id='fake';AllDay=$true;Time=$null}
            }.GetNewClosure())
            [void](Get-WtScheduleDueSummary -Now $Now)
            $signal.Text = '바뀐 휴가'
            [void](Get-WtScheduleDueSummary -Now $Now)
            @{ Once=$once; Expired=$expired; Date=$dateChanged; Saved=$saved; External=$external; Calendar=$script:summaryRowsCalls -eq 8 }
        } finally {
            Set-Item Function:script:Get-WtScheduleDueRows $original
            Register-WtCalendarSource -Id 'test-summary' -CalendarItems $null
            Remove-Variable summaryRowsOriginal, summaryRowsCalls -Scope Script
        }
    } $now $todayOne
    Assert-WtTest '상태 집계: 배지·상태가 할 일 전개 한 번을 공유' $summaryChecks.Once
    Assert-WtTest '상태 집계: 1분 만료·날짜 넘김에 다시 계산' ($summaryChecks.Expired -and $summaryChecks.Date)
    Assert-WtTest '상태 집계: 체크 저장·같은 크기/시각 외부 변경·다른 달력 출처 변경 즉시 반영' ($summaryChecks.Saved -and $summaryChecks.External -and $summaryChecks.Calendar)
    # 저장소를 선언한 출처는 캐시 적중 때 표시 자료를 만들지 않는다. SHA-256은 다음 조회에도 확인한다.
    $calendarProbe = @{ Calls=0 }
    $calendarPath = Get-WtStorePath 'calendar-probe'
    [IO.File]::WriteAllText($calendarPath, '{"schema":1,"items":[{"off":1}]}', [Text.UTF8Encoding]::new($false))
    Register-WtCalendarSource -Id 'test-store-calendar' -CalendarItems ({
        param($From,$To)
        $calendarProbe.Calls++
        if ((Open-WtStore 'calendar-probe').Items[0].off -eq 1) {
            @{ Date=$From;Kind='leave';Text='가짜 휴가';Style='leave';Id='probe';AllDay=$true;Time=$null }
        }
    }.GetNewClosure())
    Register-WtCalendarStores -Id 'test-store-calendar' -Names @('calendar-probe')
    try {
        $firstCount = Get-WtScheduleDueCount -Now $now
        $againCount = Get-WtScheduleDueCount -Now $now
        Assert-WtTest '상태 키: 선언한 저장소가 같으면 달력 자료는 한 번만 조회' ($calendarProbe.Calls -eq 1 -and $firstCount -eq $againCount) $calendarProbe.Calls
        $at = [IO.File]::GetLastWriteTimeUtc($calendarPath)
        [IO.File]::WriteAllText($calendarPath, '{"schema":1,"items":[{"off":0}]}', [Text.UTF8Encoding]::new($false))
        [IO.File]::SetLastWriteTimeUtc($calendarPath,$at)
        $changedCount = Get-WtScheduleDueCount -Now $now
        Assert-WtTest '상태 키: 선언한 출처의 같은 크기·시각 외부 변경도 즉시 반영' ($calendarProbe.Calls -eq 2 -and $changedCount -eq $firstCount+1) "$firstCount/$changedCount"
        Register-WtCalendarSource -Id 'test-store-calendar' -CalendarItems { param($From,$To) }
        Assert-WtTest '상태 키: 출처를 바꿔 등록하면 옛 저장소 선언은 지워져 일반 조회로 복귀' (-not (Get-WtCalendarStores -Exclude @('schedule')).Complete)
    } finally { Register-WtCalendarSource -Id 'test-store-calendar' -CalendarItems $null }
    Register-WtCalendarSource -Id 'case-probe' -CalendarItems { }
    Register-WtCalendarStores -Id 'case-probe' -Names @('calendar-probe')
    Register-WtCalendarSource -Id 'CASE-PROBE' -CalendarItems { }
    try {
        Assert-WtTest '상태 키: 대소문자가 다른 출처의 선언을 섞지 않는다' (-not (Get-WtCalendarStores -Exclude @('schedule')).Complete)
        Register-WtCalendarStores -Id 'CASE-PROBE' -Names @('calendar-probe')
        $beforeKey = (Get-WtCalendarStores -Exclude @('schedule')).Key
        Register-WtCalendarSource -Id 'case-probe' -CalendarItems { }
        Register-WtCalendarStores -Id 'case-probe' -Names @('calendar-probe')
        $afterKey = (Get-WtCalendarStores -Exclude @('schedule')).Key
        $shape = @((Get-WtCalendarSource | Where-Object Id -ceq 'case-probe').PSObject.Properties.Name) -join ','
        Assert-WtTest '상태 키: 같은 저장소로 출처를 재등록해도 키를 바꾸며 공개 출처 모양은 유지' ($beforeKey -cne $afterKey -and $shape -ceq 'Id,Page,CalendarItems') $shape
    } finally {
        Register-WtCalendarSource -Id 'case-probe' -CalendarItems $null
        Register-WtCalendarSource -Id 'CASE-PROBE' -CalendarItems $null
    }
    $statusTextChecks = & (Get-Module Schedule) {
        $homeItemsFunction = ${function:Get-WtScheduleHomeItems}
        $dueSummaryFunction = (Get-Command Get-WtScheduleDueSummary).ScriptBlock
        try {
            $day=[datetime]::Today
            $script:statusTestDay=$day
            function script:Get-WtScheduleHomeItems {
                @(
                    [pscustomobject]@{ Title='끝낸 일정';Start=$script:statusTestDay.AddHours(13);End=$script:statusTestDay.AddHours(16);Done=$true;AllDay=$false;ToolTip='끝냄' }
                    [pscustomobject]@{ Title='종일';Start=$script:statusTestDay;End=$script:statusTestDay.AddDays(1);Done=$false;AllDay=$true;ToolTip='종일' }
                    [pscustomobject]@{ Title='지난 일정';Start=$script:statusTestDay.AddHours(9);End=$script:statusTestDay.AddHours(10);Done=$false;AllDay=$false;ToolTip='지난 일정' }
                    [pscustomobject]@{ Title='점검';Start=$script:statusTestDay.AddHours(14);End=$script:statusTestDay.AddHours(15);Done=$false;AllDay=$false;ToolTip="점검`n14:00–15:00`n매일`n10분 전" }
                )
            }
            function script:Get-WtScheduleDueSummary {
                param($Now)
                @{ Count=$script:statusTestCount; Counts=$(if ($script:statusTestCount) { @{overdue=1;today=2;soon=0} } else { @{overdue=0;today=0;soon=0} }) }
            }
            $script:statusTestCount=3
            $next=@(Get-WtScheduleStatusItems ($day.AddHours(12)))
            $running=@(Get-WtScheduleStatusItems ($day.AddHours(14.5)))
            $none=@(Get-WtScheduleStatusItems ($day.AddHours(16)))
            $script:statusTestCount=0
            $zero=@(Get-WtScheduleStatusItems ($day.AddHours(16)))
            @{ Next=$next[0].Text -ceq '다음 14:00 점검' -and $next[0].ToolTip -ceq "점검`n14:00–15:00`n매일`n10분 전" -and $next[0].Open.Args.Date -eq $day -and $next[0].Open.Args.View -ceq 'calendar'
                Icons=$next[0].Icon -eq 0xE787 -and $running[0].Icon -eq 0xE787 -and $next[1].Icon -eq 0xE73E -and $zero[0].Icon -eq 0xE73E
                Running=$running[0].Text -ceq '진행 중 14:00 점검' -and @($none | Where-Object Key -CEQ 'next').Count -eq 0
                Due=$next[1].Text -ceq '남은 일 3' -and $next[1].ToolTip -ceq '기한 지남 1 · 오늘 2 · 마감 임박 0' -and $next[1].Open.Args.View -ceq 'due' -and
                    $zero.Count -eq 1 -and $zero[0].Text -ceq '남은 일 없음' -and $zero[0].ToolTip -ceq '기한 지남 0 · 오늘 0 · 마감 임박 0' }
        } finally {
            Set-Item Function:script:Get-WtScheduleHomeItems $homeItemsFunction
            Set-Item Function:script:Get-WtScheduleDueSummary $dueSummaryFunction
        }
    }
    Assert-WtTest '일정 상태 줄: 홈과 같은 다음 일정·툴팁·오늘 달력 인자' $statusTextChecks.Next
    Assert-WtTest '일정 상태 줄: 진행 중·끝낸 일정/종일/지난 일정 제외·없으면 숨김' $statusTextChecks.Running
    Assert-WtTest '일정 상태 줄: 남은 일 0/n·세 묶음 툴팁·할 일 보기 인자' $statusTextChecks.Due
    Assert-WtTest '일정 상태 줄 아이콘: next E787 · due E73E를 탭이 등록' $statusTextChecks.Icons

    if (Test-WtTestWpf) {
        $homeProbe = @{ Occurrences=0; Routines=0 }
        & (Get-Module Schedule) {
            param($Probe)
            $script:homeProbe = $Probe; $script:homeOccOriginal = Get-Command Get-WtScheduleOccurrences
            function script:Get-WtScheduleOccurrences { param($Entries,$From,$To) $script:homeProbe.Occurrences++; & $script:homeOccOriginal $Entries $From $To }
        } $homeProbe
        $homeReads = & (Get-Module ScheduleData) {
            param($Probe)
            $routines = ${function:Get-WtRoutineEntries}; $script:homeProbe = $Probe; $script:homeRoutineOriginal = $routines
            function script:Get-WtRoutineEntries { param($Store) $script:homeProbe.Routines++; & $script:homeRoutineOriginal $Store }
            try {
                foreach ($i in 1,2) {
                    Invoke-WtReadAction {
                        & (Get-Module Schedule) { [void](New-WtNextEventHomeLine); [void](New-WtScheduleHomeCards); [void](New-WtRoutineHomeCard) }
                    }
                    if ($Probe.Occurrences -ne $i -or $Probe.Routines -ne $i) { return $false }
                }
                $true
            } finally {
                Set-Item Function:script:Get-WtRoutineEntries $routines
                Remove-Variable homeRoutineOriginal, homeProbe -Scope Script
                & (Get-Module Schedule) { Set-Item Function:script:Get-WtScheduleOccurrences $script:homeOccOriginal.ScriptBlock; Remove-Variable homeOccOriginal, homeProbe -Scope Script }
            }
        } $homeProbe
        Assert-WtTest '홈 자료: 다음 일정·시간 막대의 전개 한 번, 오늘 루틴의 변환 한 번, 다음 갱신은 다시 계산' $homeReads ($homeProbe | ConvertTo-Json -Compress)
        $test = New-WtTestData 'schedule-view'; $tests.Add($test)
        $module = Get-Module Schedule
        $dateText = '2026-10-26'
        $ids = @()
        foreach ($spec in @(@('한날 하나', '09:00'), @('한날 둘', '10:00'), @('한날 셋', '11:00'), @('한날 넷', '12:00'))) {
            $r = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = $spec[0]; start = @{ date = $dateText; time = $spec[1] } }
            $ids += $r.Id
        }
        $repeat = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '반복 시험'; start = @{ date = '2026-10-27'; time = '14:00' }; repeat = @{ freq = 'daily' }; alarms = @(@{ before = 10 }) }
        $view = New-WtTestView 'schedule'
        & $module { Set-WtScheduleDate ([datetime]::new(2026,10,26)) }
        $cells = & $module { ,$script:cells }
        $view.Measure([Windows.Size]::new(1080,744)); $view.Arrange([Windows.Rect]::new(0,0,1080,744)); $view.UpdateLayout()
        Assert-WtTest '일정 월 달력: 42칸 생성 · 일요일 시작 · 5주 · 두 일정/+2 · 나머지 툴팁' (
            $cells.Count -eq 42 -and $cells[0].Button.DataContext -eq [datetime]::new(2026,9,27) -and
            (& $module { $script:view.Days.Rows }) -eq 5 -and $cells[29].Chips[0].Child.Text -ceq '09:00 한날 하나' -and
            $cells[29].Chips[1].Child.Text -ceq '10:00 한날 둘' -and $cells[29].More.Text -ceq '+2' -and $cells[29].More.ToolTip -ceq "11:00 한날 셋$([Environment]::NewLine)12:00 한날 넷")
        & $module { $script:month = [datetime]::new(2026,8,1); Update-WtScheduleView }
        $after = & $module { ,$script:cells }
        Assert-WtTest '일정 달 이동: 6주 · 42칸/자식 요소/참조 그대로 재사용' (
            (& $module { $script:view.Days.Rows -eq 6 -and $script:view.Days.Children.Count -eq 42 }) -and
            @((0..41) | Where-Object { -not [object]::ReferenceEquals($cells[$_].Button, $after[$_].Button) -or
                -not [object]::ReferenceEquals($cells[$_].Chips[0], $after[$_].Chips[0]) }).Count -eq 0)
        Register-WtCalendarSource 'schedule-view-marks' {
            param($From, $To)
            foreach ($spec in @(@('2026-10-26','work','09:02'), @('2026-10-27','overtime','20:00'), @('2026-10-31','work','09:00'), @('2026-10-28','leave',$null))) {
                [pscustomobject]@{ Date = ConvertFrom-WtDateText $spec[0]; Kind = $spec[1]; Time = $spec[2]; AllDay = $null -eq $spec[2]; Text = $(if ($spec[1] -eq 'leave') { '휴가' } else { '근무 ' + $spec[2] + '–18:10' }); Style = 'Att.Work'; Id = $spec[0] }
            }
        }
        try {
            & $module { Set-WtScheduleDate ([datetime]::new(2026,10,26)) }
            $marks = & $module { ,$script:cells }
            $view.UpdateLayout()
            Assert-WtTest '일정 근태: 평소 근무일 · 쉬는 날은 칠하지 않고 업무외 · 휴가만 숫자 바탕, 시각 툴팁' (
                $null -eq $marks[29].Circle.Background -and $null -eq $marks[28].Circle.Background -and
                $marks[30].Circle.Background -eq $view.FindResource('B.Cal.Overtime.Bg') -and $marks[31].Circle.Background -eq $view.FindResource('B.Cal.Leave.Bg') -and
                $marks[29].Circle.ToolTip -ceq '근무 09:02–18:10' -and $marks[31].Circle.ToolTip -ceq '휴가')
            Assert-WtTest '일정 근태 칩: 휴가 · 업무외는 칸의 일정보다 앞, 평소 근무는 칩 없음' ($marks[31].Chips[0].Visibility -eq 'Visible' -and $marks[31].Chips[0].Child.Text -ceq '휴가' -and
                $marks[30].Chips[0].Child.Text -ceq '근무 20:00–18:10' -and $marks[30].Chips[1].Child.Text -ceq '14:00 반복 시험' -and $marks[29].Chips[0].Child.Text -ceq '09:00 한날 하나')
        } finally { Register-WtCalendarSource 'schedule-view-marks' $null }
        & $module { Show-WtScheduleForm -Kind event; $script:form.Fields.title.Text = '취소할 일정'; Show-WtScheduleDay }
        Assert-WtTest '일정 폼 취소: 저장소에 추가 안 함' (@((Get-WtScheduleData).Items | Where-Object title -ceq '취소할 일정').Count -eq 0)
        & $module { Show-WtScheduleForm -Kind event; $script:form.Fields.title.Text = '폼 저장'; $script:form.Fields.start.Text = '10:00'; $script:form.Fields.end.Text = '09:00'; Save-WtScheduleForm }
        Assert-WtTest '일정 폼 검사: 끝이 시작 전이면 칸 아래 오류 · 저장 안 함' ((& $module { $script:form.Errors.end.Text }) -ceq '끝 시각을 확인하세요.' -and @((Get-WtScheduleData).Items | Where-Object title -ceq '폼 저장').Count -eq 0)
        & $module { $script:form.Fields.end.Text = '11:00'; Save-WtScheduleForm }
        $saved = @((Get-WtScheduleData).Entries | Where-Object Title -ceq '폼 저장')
        Assert-WtTest '일정 폼 저장: 제목/날짜/시각 반영 · 상세 목록 복귀' ($saved.Count -eq 1 -and $saved[0].Start -eq [datetime]::new(2026,10,26,10,0,0) -and (& $module { $null -eq $script:form }))
        & (Get-WtAddon -Id schedule).OnOpen @{ Id = $saved[0].Id }
        Assert-WtTest '일정 OnOpen Id만: 원래 날짜로 이동 · 편집 폼 열림' ((& $module { $script:selected -eq [datetime]::new(2026,10,26) -and $script:form.Fields.title.Text -ceq '폼 저장' }))
        & $module { Remove-WtScheduleForm }
        Assert-WtTest '일정 폼 삭제: 지운 표시 보존 · 계산에서 제외' (@((Get-WtScheduleData).Entries | Where-Object { $_.Id -ceq $saved[0].Id -and $_.State -eq 'deleted' }).Count -eq 1)
        $spanStore = Open-WtScheduleStore
        $spanItem = Copy-WtItem $spanStore.Items[0]; $spanItem.id = 'old-span'; $spanItem.title = '예전 기간'
        $spanItem.start = [pscustomobject]@{ date = '2026-10-29'; time = '22:00' }
        $spanItem.end = [pscustomobject]@{ date = '2026-10-30'; time = '02:00' }
        Save-WtScheduleItems $spanStore (@($spanStore.Items) + @($spanItem))
        & (Get-WtAddon -Id schedule).OnOpen @{ Id = 'old-span' }
        & $module { $script:form.Fields.title.Text = '기간 제목 수정'; Save-WtScheduleForm }
        $spanSaved = @((Get-WtScheduleData).Entries | Where-Object Id -ceq 'old-span')[0]
        Assert-WtTest '일정 폼: 예전 자정 넘김의 제목만 수정해도 끝 날짜/시각 보존' ($spanSaved.Title -ceq '기간 제목 수정' -and
            $spanSaved.Start -eq [datetime]::new(2026,10,29,22,0,0) -and $spanSaved.End -eq [datetime]::new(2026,10,30,2,0,0))
        & (Get-WtAddon -Id schedule).OnOpen @{ Date = [datetime]::new(2026,10,27); Id = $repeat.Id }
        & $module { $script:form.Fields.title.Text = '한 회차 수정'; Save-WtScheduleForm -Scope '이 회차만' }
        $entries = (Get-WtScheduleData).Entries
        $changed = @(Get-WtScheduleOccurrences $entries ([datetime]::new(2026,10,27)) ([datetime]::new(2026,10,28)))
        Assert-WtTest '일정 반복 폼: 이 회차만 제목 수정 · 다음 회차와 id/규칙 유지' (
            $changed[0].Title -ceq '한 회차 수정' -and $changed[0].Changed -and $changed[1].Title -ceq '반복 시험' -and $changed[0].Entry.Id -ceq $repeat.Id)
        & (Get-WtAddon -Id schedule).OnOpen @{ Date = [datetime]::new(2026,12,9) }
        Assert-WtTest '일정 OnOpen Date만: 달/날 선택 · 상세 목록' (& $module { $script:month -eq [datetime]::new(2026,12,1) -and $script:selected.Day -eq 9 -and $null -eq $script:form })
        & $module {
            Show-WtScheduleForm -Kind routine
            $script:form.Fields.title.Text = '폼 시간 루틴'; $script:form.Fields.freq.SelectedItem = '시간마다'
            $script:form.Fields.every.Text = '2'; $script:form.Fields.start.Text = '09:00'; $script:form.Fields.end.Text = '08:00'
            Save-WtScheduleForm
        }
        Assert-WtTest '루틴 폼: 끝이 시작 전이면 해당 칸 오류 · 저장 안 함' (
            (& $module { $script:form.Errors.end.Text -ceq '끝 시각을 확인하세요.' }) -and
            @((Get-WtScheduleData).Items | Where-Object title -ceq '폼 시간 루틴').Count -eq 0)
        & $module { $script:form.Fields.end.Text = '18:00'; Save-WtScheduleForm }
        $formRoutine = @((Get-WtScheduleData).Items | Where-Object title -ceq '폼 시간 루틴')
        Assert-WtTest '루틴 폼: 시간마다 2시간/설정 구간 저장 · 상세 목록 복귀' ($formRoutine.Count -eq 1 -and
            $formRoutine[0].routine.freq -ceq 'hourly' -and $formRoutine[0].routine.every -eq 2 -and
            $formRoutine[0].routine.from -ceq '09:00' -and $formRoutine[0].routine.to -ceq '18:00' -and (& $module { $null -eq $script:form }))
        [void](Set-WtRoutineDeleted -Id $formRoutine[0].id)

        $routine = New-WtRoutine -Title '지난 날 보정' -Freq daily -Start '2026-10-01'
        & $module { Set-WtScheduleDate ([datetime]::new(2026,10,26)); $script:checkList = New-WtRoutineList ([datetime]::new(2026,10,26)); $script:check = $script:checkList.Children[0].Children[0]; $peer = [Windows.Automation.Peers.CheckBoxAutomationPeer]::new($script:check); $toggle = $peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Toggle); ([Windows.Automation.Provider.IToggleProvider]$toggle).Toggle() }
        Assert-WtTest '루틴 화면: 지난 날 체크 증적 저장' (@(Get-WtRoutineSlots '2026-10-26' | Where-Object { $_.Routine.Id -ceq $routine.Id -and $_.Done }).Count -eq 1)
        & $module { $script:check = $script:checkList.Children[0].Children[0]; $peer = [Windows.Automation.Peers.CheckBoxAutomationPeer]::new($script:check); $toggle = $peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Toggle); ([Windows.Automation.Provider.IToggleProvider]$toggle).Toggle() }
        Assert-WtTest '루틴 화면: 체크 풀기 · 지운 증적 남김' (@(Get-WtRoutineSlots '2026-10-26' | Where-Object Done).Count -eq 0 -and @(Get-WtRoutineHistory '2026-10-26' '2026-10-26' | Where-Object { Test-WtDeleted $_ }).Count -eq 1)
        $section = & $module { New-WtRoutineSection '루틴' ([datetime]::Today) }
        $headLine = { $line = @($section.Root.Children[0].Content.Children)[-1]; [Windows.Documents.TextRange]::new($line.ContentStart, $line.ContentEnd).Text }
        $before = & $headLine
        & $module { param($List) $List.Children[0].Children[0].IsChecked = $true } $section.List
        $after = & $headLine
        Assert-WtTest '루틴 제목: 완료 수를 체크할 때 바로 바꾼다' ($before -ceq '루틴  0/1' -and $after -ceq '루틴  1/1') "$before / $after"
        & $module { param($List) $List.Children[0].Children[0].IsChecked = $false } $section.List
        $cards = @(Get-WtHomeCards | Where-Object Id -ceq schedule)
        $routineCard = & $module { New-WtRoutineHomeCard }
        Assert-WtTest '일정 홈 등록: 다음 일정 head10/오늘 일정 main10/오늘 루틴 side20 · 공용 체크리스트 카드' ($cards.Count -eq 3 -and $cards[0].HomeSlot -ceq 'head' -and $cards[0].HomeOrder -eq 10 -and
            $cards[1].HomeSlot -ceq 'main' -and $cards[1].HomeOrder -eq 10 -and $cards[2].HomeSlot -ceq 'side' -and $cards[2].HomeOrder -eq 20 -and (Get-WtTestTexts $routineCard) -contains '오늘 루틴')
        [void](Set-WtRoutineDeleted -Id $routine.Id)
        Assert-WtTest '오늘 루틴: 해당 루틴 없으면 카드 없음' ($null -eq (& $module { New-WtRoutineHomeCard }))
        # 루틴 줄 우클릭 [삭제](공통 메뉴 항목): 체크로 줄을 다시 그린 뒤에도 그 루틴을 지우고, 화면에 붙은 같은 목록을 다시 그린다
        $menuRoutine = New-WtRoutine -Title '메뉴 삭제 시험' -Freq daily -Start '2026-10-01'
        $menuSection = & $module { New-WtRoutineSection '루틴' ([datetime]::Today) }
        $findCheck = { param($List) @(foreach ($row in $List.Children) { @($row.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.Content.Text -clike '*메뉴 삭제 시험' }) })[0] }
        & $module { param($c) $c.IsChecked = $true } (& $findCheck $menuSection.List)
        $rowCheck = & $findCheck $menuSection.List
        $rowMenu = @($rowCheck.ContextMenu.Items | ForEach-Object { [string]$_.Header }) -join ','
        & $module { param($c) @($c.ContextMenu.Items | Where-Object { [string]$_.Header -ceq '삭제' })[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent)) } $rowCheck
        $leftSlots = @(Get-WtRoutineSlots -Date ([datetime]::Today) | Where-Object { $_.Routine.Id -ceq $menuRoutine.Id }).Count
        $shownRows = @(Get-WtTestTexts $menuSection.List | Where-Object { $_ -clike '*메뉴 삭제 시험' }).Count
        Assert-WtTest '루틴 줄 메뉴(공통 메뉴 항목): 줄을 다시 그린 뒤에도 [삭제]가 그 루틴을 지우고 화면의 같은 목록을 다시 그린다' (
            $rowMenu -ceq '편집,삭제' -and $leftSlots -eq 0 -and $shownRows -eq 0) "메뉴 $rowMenu · 남은 회차 $leftSlots · 남은 줄 $shownRows"
        # ---- 1단계: 일정 체크 · 여러 날 막대 · 기간 폼 · 달 고르기 · 휴무일 지정 ----
        $checkOne = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '체크 하루'; start = @{ date = '2026-11-03'; time = '10:00' } }
        $checkWeekly = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '체크 반복'; start = @{ date = '2026-11-02'; time = '09:00' }; repeat = @{ freq = 'weekly' } }
        Wait-WtTestWrites
        $scheduleText = [IO.File]::ReadAllText((Get-WtStorePath 'schedule'))
        $c1 = Set-WtEventCheck -Event $checkOne.Id -Date '2026-11-03' -Done $true -At '2026-11-03T11:00:00+09:00'
        $c2 = Set-WtEventCheck -Event $checkWeekly.Id -Date '2026-11-09' -Done $true -At '2026-11-09T10:00:00+09:00'
        $cBad = Set-WtEventCheck -Event $checkWeekly.Id -Date '2026-11-10' -Done $true -At '2026-11-09T10:00:00+09:00'
        $cNone = Set-WtEventCheck -Event 'no-such-event' -Date '2026-11-10' -Done $true -At '2026-11-09T10:00:00+09:00'
        $doneKeys = Get-WtEventDone
        Wait-WtTestWrites
        Assert-WtTest '일정 체크: 회차마다 따로 남기고 없는 회차 · 없는 일정은 거부, schedule.json은 그대로' (
            $c1.Success -and $c2.Success -and -not $cBad.Success -and -not $cNone.Success -and $doneKeys.Contains("$($checkOne.Id)@2026-11-03") -and
            $doneKeys.Contains("$($checkWeekly.Id)@2026-11-09") -and -not $doneKeys.Contains("$($checkWeekly.Id)@2026-11-02") -and
            [IO.File]::ReadAllText((Get-WtStorePath 'schedule')) -ceq $scheduleText) "$($cBad.Reason) / $($cNone.Reason)"
        $cOff = Set-WtEventCheck -Event $checkOne.Id -Date '2026-11-03' -Done $false -At '2026-11-03T12:00:00+09:00'
        Wait-WtTestWrites
        $logDoc = [IO.File]::ReadAllText((Get-WtStorePath 'event-log')) | ConvertFrom-Json -Depth 20 -DateKind String
        Assert-WtTest '일정 체크 풀기: 기록은 지운 표시로 남고 끝낸 모음에서 빠진다' ($cOff.Success -and -not (Get-WtEventDone).Contains("$($checkOne.Id)@2026-11-03") -and
            @($logDoc.items | Where-Object { $_.id -ceq $c1.Id -and $_.deleted }).Count -eq 1)
        $cAgain = Set-WtEventCheck -Event $checkOne.Id -Date '2026-11-03' -Done $true -At '2026-11-03T13:00:00+09:00'
        Assert-WtTest '일정 체크 다시: 같은 기록을 되살린다(줄이 늘지 않음)' ($cAgain.Success -and $cAgain.Id -ceq $c1.Id -and (Get-WtEventDone).Contains("$($checkOne.Id)@2026-11-03"))

        # ---- 2단계: 연결(links). 다른 달(2027년 3월)에 만들고 끝나면 지워서 아래 11월 화면 검사와 섞이지 않게 한다 ----
        $linkOne = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '연결 하루'; start = @{ date = '2027-03-03'; time = '10:00' } }
        $linkWeekly = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '연결 반복'; start = @{ date = '2027-03-01'; time = '09:00' }; repeat = @{ freq = 'weekly' } }
        $l1 = Add-WtScheduleLink -Id $linkWeekly.Id -Page memo -Key 'm-all' -At '2027-03-01T09:00:00+09:00'
        $l2 = Add-WtScheduleLink -Store $l1.Store -Id $linkWeekly.Id -Page memo -Key 'm-day' -Date '2027-03-08' -At '2027-03-01T09:01:00+09:00'
        $l3 = Add-WtScheduleLink -Store $l2.Store -Id $linkWeekly.Id -Page memo -Key 'm-day' -Date '2027-03-08' -At '2027-03-01T09:02:00+09:00'
        $l4 = Add-WtScheduleLink -Id $linkWeekly.Id -Page memo -Key 'm-all' -Date '2027-03-15' -At '2027-03-01T09:03:00+09:00'
        $lBad = Add-WtScheduleLink -Id $linkWeekly.Id -Page memo -Key 'm-x' -Date '2027-03-09' -At '2027-03-01T09:04:00+09:00'
        $lNone = Add-WtScheduleLink -Id 'no-such-event' -Page memo -Key 'm-x' -At '2027-03-01T09:04:00+09:00'
        $weekly = (Get-WtTestById (Get-WtScheduleData).Entries)[$linkWeekly.Id]
        $on8 = (@(Get-WtScheduleLinks $weekly '2027-03-08' | ForEach-Object Key) -join ',')
        $on15 = (@(Get-WtScheduleLinks $weekly ([datetime]::new(2027, 3, 15)) | ForEach-Object Key) -join ',')
        Assert-WtTest '연결: 모든 회차(null) · 그 회차(날짜)로 붙고, 같은 연결 · 이미 모든 회차인 것은 바꾸지 않음, 없는 회차 · 일정은 거부' (
            $l1.Success -and $l2.Success -and $l3.Success -and [object]::ReferenceEquals($l3.Store, $l2.Store) -and $l4.Success -and
            -not $lBad.Success -and -not $lNone.Success -and $weekly.Links.Count -eq 2 -and $on8 -ceq 'm-all,m-day' -and $on15 -ceq 'm-all' -and
            [int]$weekly.Item.rev -eq 2) "$on8 / $on15 / rev $($weekly.Item.rev) / $($lBad.Reason)"
        # 모양이 틀린 원소는 화면에서 빼고 저장할 때 그대로 둔다
        $rawStore = Open-WtScheduleStore
        $rawItems = @(Copy-WtItem @($rawStore.Items))
        $target = @($rawItems | Where-Object { (Test-WtRecordObject $_) -and $_.id -ceq $linkOne.Id })[0]
        Set-WtField $target 'links' @('junk', [pscustomobject]@{ page = 'memo' }, [pscustomobject][ordered]@{ page = 'memo'; key = 'm-bad'; date = 'bad'; extra = 1 })
        Save-WtScheduleItems $rawStore $rawItems
        $l5 = Add-WtScheduleLink -Id $linkOne.Id -Page memo -Key 'm-one' -Date '2027-03-03'
        $one = (Get-WtTestById (Get-WtScheduleData).Entries)[$linkOne.Id]
        $rawLinks = @((@((Read-WtTestDoc).items) | Where-Object { $_.id -ceq $linkOne.Id }).links)
        $l6 = Remove-WtScheduleLink -Id $linkOne.Id -Page memo -Key 'm-one' -Date '2027-03-03'
        $rawLinks2 = @((@((Read-WtTestDoc).items) | Where-Object { $_.id -ceq $linkOne.Id }).links)
        Assert-WtTest '연결: 모양이 틀린 원소는 고칠 항목이 아니고 화면에서만 빠지며 저장할 때 남는다, 빼기는 그 원소만' (
            $l5.Success -and $one.State -eq 'ok' -and $one.Links.Count -eq 1 -and $one.Links[0].Key -ceq 'm-one' -and $rawLinks.Count -eq 4 -and
            $rawLinks[0] -ceq 'junk' -and $rawLinks[2].extra -eq 1 -and $l6.Success -and $rawLinks2.Count -eq 3) "$($rawLinks.Count) / $($rawLinks2.Count) / $($one.State)"
        # 반복 규칙을 나누면 옛 계열은 null + 앞 날짜, 새 계열은 null + 그날부터(설계 13.2)
        $l7 = Add-WtScheduleLink -Id $linkWeekly.Id -Page memo -Key 'm-late' -Date '2027-03-22'
        $split = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '연결 반복 뒤' } -Id $linkWeekly.Id -FromDate '2027-03-15'
        $byLink = Get-WtTestById (Get-WtScheduleData).Entries
        $oldKeys = (@($byLink[$linkWeekly.Id].Links | ForEach-Object Key) -join ','); $newKeys = (@($byLink[$split.Id].Links | ForEach-Object Key) -join ',')
        Assert-WtTest '연결: 계열을 나누면 날짜 연결은 그 날짜가 든 계열에만 남는다' ($l7.Success -and $split.Success -and $oldKeys -ceq 'm-all,m-day' -and $newKeys -ceq 'm-all,m-late') "$oldKeys / $newKeys"
        # 루틴: 모든 날만, 규칙을 바꿔 나눠도 연결이 따라간다. 폼 저장은 links를 바꾸지 않는다
        $linkRoutine = New-WtRoutine -Title '연결 루틴' -Freq daily -Start '2027-03-01'
        $r1 = Add-WtScheduleLink -Id $linkRoutine.Id -Page memo -Key 'm-r'
        $r2 = Add-WtScheduleLink -Id $linkRoutine.Id -Page memo -Key 'm-r2' -Date '2027-03-05'
        $r3 = Save-WtRoutine (Open-WtScheduleStore) @{ title = '연결 루틴 이름' } -Id $linkRoutine.Id
        $r4 = Save-WtRoutine (Open-WtScheduleStore) @{ routine = @{ freq = 'weekly'; days = @(1, 3) } } -Id $linkRoutine.Id -From '2027-03-10'
        $routineDoc = @((Read-WtTestDoc).items)
        $routineLinks = (@($routineDoc | Where-Object { $_.id -ceq $linkRoutine.Id -or $_.id -ceq $r4.Id } | ForEach-Object { "$(@($_.links).Count):$(@($_.links)[0].key)" }) -join ',')
        $itemLinks = (@(Get-WtScheduleItemLinks $r4.Id | ForEach-Object Key) -join ',')
        Assert-WtTest '연결 루틴: 날짜 연결은 거부, 이름 저장 · 규칙 나누기 뒤에도 양쪽 계열에 남음' (
            $r1.Success -and -not $r2.Success -and $r3.Success -and $r4.Success -and $r4.Id -cne $linkRoutine.Id -and $routineLinks -ceq '1:m-r,1:m-r' -and $itemLinks -ceq 'm-r') "$routineLinks / $itemLinks / $($r2.Reason)"
        foreach ($cleanId in $linkOne.Id, $linkWeekly.Id, $split.Id) { [void](Set-WtScheduleDeleted (Open-WtScheduleStore) -Id $cleanId) }
        foreach ($cleanId in $linkRoutine.Id, $r4.Id) { [void](Set-WtRoutineDeleted -Id $cleanId) }

        $spanA = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '막대 가'; start = @{ date = '2026-11-03'; time = $null }; end = @{ date = '2026-11-06'; time = $null } }
        # 밤을 넘는 시각 일정은 새로 만들지 않으므로(설계) 예전에 저장된 것처럼 저장소에 바로 넣는다
        $nightStore = Open-WtScheduleStore
        $night = [pscustomobject][ordered]@{ id = 'night-span'; kind = 'event'; title = '막대 나'; note = ''; start = [pscustomobject]@{ date = '2026-11-05'; time = '22:00' }
            end = [pscustomobject]@{ date = '2026-11-06'; time = '02:00' }; repeat = $null; alarms = @(); tags = @(); rev = 0; created = $null; updated = '2026-11-01T09:00:00+09:00'; deleted = $null; origin = $null }
        Save-WtScheduleItems $nightStore (@($nightStore.Items) + @($night))
        $spanC = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '막대 다'; start = @{ date = '2026-11-13'; time = $null }; end = @{ date = '2026-11-17'; time = $null } }
        $novStart = [datetime]::new(2026, 11, 1)
        $lanes = @(Get-WtScheduleLanes @(Get-WtScheduleOccurrences (Get-WtScheduleData).Entries $novStart $novStart.AddDays(34)) $novStart 5 | Where-Object { $_.Occ.Title -like '막대 *' })
        $laneText = (@($lanes | ForEach-Object { "$($_.Occ.Title):$($_.Row):$($_.A)-$($_.B):$($_.Lane):$([int]$_.FromPrev)$([int]$_.ToNext)" }) -join ' ')
        Assert-WtTest '여러 날 줄: 먼저 시작한 것이 아래 줄 0, 겹치면 줄 1, 주를 넘으면 앞 · 뒤 표시' (
            $laneText -ceq '막대 가:0:2-5:0:00 막대 나:0:4-5:1:00 막대 다:1:5-6:0:01 막대 다:2:0-2:0:10') $laneText
        & $module { Set-WtScheduleDate ([datetime]::new(2026, 11, 5)) }
        $view.UpdateLayout()
        $cells = & $module { ,$script:cells }
        $barTexts = @(& $module { $script:view.Bars.Children } | ForEach-Object { $_.Children } | ForEach-Object { $_.Children } | ForEach-Object { $_.Child.Text } | Where-Object { $_ -like '*막대*' })
        Assert-WtTest '여러 날 막대: 겹침 층에 주마다 이어 그리고, 그 칸의 칩 자리는 비워 둔다' (
            ($barTexts -join ',') -ceq '막대 가,22:00 막대 나,막대 다,막대 다' -and $cells[3].Chips[0].Visibility -eq 'Hidden' -and
            $cells[3].Chips[1].Visibility -eq 'Visible' -and $cells[4].Chips[0].Visibility -eq 'Hidden' -and $cells[4].Chips[1].Visibility -eq 'Hidden' -and
            $cells[4].More.Visibility -eq 'Visible') "$($barTexts -join ',') / $($cells[3].Chips[1].Child.Text) / $($cells[4].More.Text)"
        $listTexts = @(Get-WtTestTexts (& $module { $script:detail }))
        Assert-WtTest '일정 목록: 여러 날 일정은 둘째 줄에 기간 · 며칠째, 밤 넘김은 시작 · 끝 시각' (
            $listTexts -contains '11월 3일 ~ 6일 · 3일째' -and $listTexts -contains '11월 5일 22:00 ~ 6일 02:00' -and $listTexts -contains '하루 종일') ($listTexts -join ' | ')
        & $module { Set-WtScheduleDate ([datetime]::new(2026, 11, 6)) }
        Assert-WtTest '일정 목록: 밤 넘김 일정의 끝나는 날 시각 칸은 「~끝 시각」' (@(Get-WtTestTexts (& $module { $script:detail })) -contains '~02:00')
        & $module { Set-WtScheduleDate ([datetime]::new(2026, 11, 3)) }
        $key = "$($checkOne.Id)@2026-11-03"
        $rowCheck = & $module { param($k) @($script:detail.Content.Children[0].Content.Children | Where-Object { $_ -is [Windows.Controls.DockPanel] } | ForEach-Object { $_.Children[0] } | Where-Object { $_ -is [Windows.Controls.CheckBox] -and [Windows.Automation.AutomationProperties]::GetAutomationId($_) -ceq "Schedule-Check-$k" })[0] } $key
        $checkedBefore = [bool]$rowCheck.IsChecked
        $peer = [Windows.Automation.Peers.CheckBoxAutomationPeer]::new($rowCheck); ([Windows.Automation.Provider.IToggleProvider]$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Toggle)).Toggle()
        Assert-WtTest '일정 목록 체크 상자: 체크 상태를 보여 주고, 누르면 기록을 바꾼다' ($checkedBefore -and -not (Get-WtEventDone).Contains($key))
        & $module { $script:month = [datetime]::new(2026, 11, 1); Update-WtScheduleView }
        $cells = & $module { ,$script:cells }
        [void](Set-WtEventCheck -Event $checkOne.Id -Date '2026-11-03' -Done $true)   # 화면에서 푼 시각보다 뒤여야 하므로 지금 시각
        & $module { Update-WtScheduleView }
        $doneChip = @($cells[2].Chips | Where-Object { $_.Visibility -eq 'Visible' -and $_.Child.Inlines.Count -eq 2 })
        Assert-WtTest '달력 칩: 끝낸 일정은 체크 표시를 앞에 붙이고 흐린 글자' ($doneChip.Count -eq 1 -and ([Windows.Documents.Run]$doneChip[0].Child.Inlines.LastInline).Text -ceq ' 10:00 체크 하루' -and
            $doneChip[0].Child.Foreground -eq $view.FindResource('B.Text.Tertiary')) (@($cells[2].Chips | ForEach-Object { "$($_.Visibility):$($_.Child.Text):$($_.Child.Inlines.Count)" }) -join ' / ')

        & $module { Set-WtScheduleDate ([datetime]::new(2026, 11, 10)); Show-WtScheduleForm -Kind event; $f = $script:form.Fields; $f.title.Text = '폼 기간'; $f.allDay.IsChecked = $true; $f.endDate.Text = '2026-11-08'; Save-WtScheduleForm }
        $endError = & $module { $script:form.Errors.endDate.Text }
        & $module { $script:form.Fields.endDate.Text = '2026-11-12'; Save-WtScheduleForm }
        $formSpan = @((Get-WtScheduleData).Entries | Where-Object Title -ceq '폼 기간')
        Assert-WtTest '일정 폼 기간: 끝 날짜가 앞이면 오류, 맞으면 하루 종일 여러 날로 저장' ($endError -like '끝 날짜를 확인하세요*' -and $formSpan.Count -eq 1 -and
            $formSpan[0].AllDay -and $formSpan[0].Start -eq [datetime]::new(2026, 11, 10) -and $formSpan[0].LastDay -eq [datetime]::new(2026, 11, 12)) $endError
        & $module { Show-WtScheduleForm -Kind event; $f = $script:form.Fields; $f.title.Text = '폼 밤'; $f.date.Text = '2026-11-20'; $f.start.Text = '22:00'; $f.endDate.Text = '2026-11-21'; $script:forced = "$($f.allDay.IsChecked)|$($f.allDay.IsEnabled)"; Save-WtScheduleForm }
        $night2 = @((Get-WtScheduleData).Entries | Where-Object Title -ceq '폼 밤')
        Assert-WtTest '일정 폼 기간: 끝 날짜가 뒤면 하루 종일로 고정해 저장(밤 넘는 시각 일정은 만들지 않음)' ((& $module { $script:forced }) -ceq 'True|False' -and
            $night2.Count -eq 1 -and $night2[0].AllDay -and $night2[0].LastDay -eq [datetime]::new(2026, 11, 21)) (& $module { $script:forced })
        & $module { Show-WtScheduleDay }
        $formOpen = & $module { param($Id) $occ = @(Get-WtScheduleOccurrences (Get-WtScheduleData).Entries ([datetime]'2026-11-10') ([datetime]'2026-11-10') | Where-Object { $_.Entry.Id -ceq $Id })[0]; Show-WtScheduleForm -Kind event -Occurrence $occ; $script:form.Fields.endDate.Text } $formSpan[0].Id
        Assert-WtTest '일정 폼 기간: 고칠 때 끝 날짜 칸에 마지막 날을 보여 준다' ($formOpen -ceq '2026-11-12') $formOpen
        & $module { Show-WtScheduleDay }

        $picked = & $module { & $script:picker.OnPick ([datetime]::new(2027, 3, 1)); "$($script:month.ToString('yyyy-MM-dd'))|$($script:view.Month.Text)" }
        & $module { $script:picker.Current = [datetime]::new(2026, 11, 1); $script:picker.Year = 2026; Update-WtMonthPicker $script:picker }
        $pickerButtons = & $module { ,@($script:picker.Buttons) }
        $pickerButtons[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $todayLink = & $module { $script:picker.Today }
        $todayLink.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $afterToday = & $module { "$($script:month -eq [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1))|$($script:selected -eq [datetime]::Today)|$($script:view.TableNav.Visibility)" }
        & $module { $script:month = [datetime]::new(2026, 1, 1); Update-WtScheduleView }
        Assert-WtTest '달 고르기 「오늘」: 이번 달 · 오늘을 고른다, 달력 머리줄에는 ‹ 오늘 › 없음(표 보기에만)' ($afterToday -ceq 'True|True|Collapsed') $afterToday
        Assert-WtTest '달 고르기: 고른 달로 옮기고, 보고 있는 달 칸은 강조 모양' ($picked -ceq '2027-03-01|2027년 3월' -and
            $pickerButtons[10].Style -eq $view.FindResource('Picker.MonthSelected') -and $pickerButtons[9].Style -eq $view.FindResource('Picker.Month') -and
            (& $module { $script:month }) -eq [datetime]::new(2026, 1, 1)) $picked

        & $module { $script:month = [datetime]::new(2026, 11, 1); Update-WtScheduleView }
        $cells = & $module { ,$script:cells }
        $menuHeaders = & $module { param($b) Update-WtScheduleDayMenu $b; @($b.ContextMenu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] } | ForEach-Object Header) -join ',' } $cells[26].Button
        & $module { Set-WtScheduleHoliday '2026-11-27' @('company') $true '회사 휴무' }
        $cells = & $module { ,$script:cells }
        $afterSet = "$($cells[26].Holiday.Text)|$((Get-WtHolidayDates).Contains('2026-11-27'))"
        $menuAfter = & $module { param($b) Update-WtScheduleDayMenu $b; @($b.ContextMenu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] } | ForEach-Object Header) -join ',' } $cells[26].Button
        & $module { Set-WtScheduleHoliday '2026-11-27' @('company') $false }
        Assert-WtTest '날짜 우클릭 휴무일: 지정하면 칸 머리에 이름, 다시 열면 해제, 해제하면 계산에서 빠짐' (
            $menuHeaders -ceq '새 일정,새 루틴,회사 휴무로 지정' -and $afterSet -ceq '회사 휴무|True' -and $menuAfter -ceq '새 일정,새 루틴,휴무일 해제' -and
            -not (Get-WtHolidayDates).Contains('2026-11-27')) "$menuHeaders / $afterSet / $menuAfter"
        # 메뉴 항목은 공통 New-WtMenuItem(core\Ui.psm1)이다. 항목을 눌러도 전과 같다: 휴무일 지정 · 해제, 그날 새 일정 폼, + 메뉴의 새 루틴 폼
        $pressMenu = { param($Menu, [string]$Header) @($Menu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] -and [string]$_.Header -ceq $Header })[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent)) }
        $keptDay = & $module { @{ Selected = $script:selected; Month = $script:month } }
        & $module { param($b, $press) Update-WtScheduleDayMenu $b; & $press $b.ContextMenu '회사 휴무로 지정' } $cells[26].Button $pressMenu
        $pressedSet = (Get-WtHolidayDates).Contains('2026-11-27')
        $cells = & $module { ,$script:cells }
        & $module { param($b, $press) Update-WtScheduleDayMenu $b; & $press $b.ContextMenu '휴무일 해제' } $cells[26].Button $pressMenu
        $pressedClear = -not (Get-WtHolidayDates).Contains('2026-11-27')
        $cells = & $module { ,$script:cells }
        $pressedForms = & $module {
            param($b, $press, $kept)
            Update-WtScheduleDayMenu $b; & $press $b.ContextMenu '새 일정'; $event = "$($script:form.Kind) $($script:selected.ToString('yyyy-MM-dd'))"
            & $press $script:side.Add.ContextMenu '새 루틴'; $routine = $script:form.Kind
            $script:form = $null; $script:selected = $kept.Selected; $script:month = $kept.Month; Update-WtScheduleView
            "$event|$routine"
        } $cells[26].Button $pressMenu $keptDay
        $cells = & $module { ,$script:cells }
        Assert-WtTest '날짜 우클릭 · + 메뉴(공통 메뉴 항목): 눌러서 휴무일 지정 · 해제, 그날 새 일정 폼, 새 루틴 폼' ($pressedSet -and $pressedClear -and $pressedForms -ceq 'event 2026-11-27|routine') "$pressedSet / $pressedClear / $pressedForms"
        # 4단계(설계 15.6): 다른 탭이 코어에 등록한 날짜 메뉴 항목이 구분선과 휴무일 사이에 붙고, 누르면 그 탭의 동작을 부른 뒤 달력을 다시 그린다
        $global:wtTestDateMenuArg = $null
        Register-WtAddon -Id 'test-datemenu' -Title '가짜 근태' -NewView { [Windows.Controls.Border]::new() } -DateMenu {
            param([datetime]$Date)
            @{ Header = '가짜 넣기'; Items = @(@{ Header = '하나'; Action = { param($Arg) $global:wtTestDateMenuArg = $Arg }; Arg = @{ Day = $Date.ToString('yyyy-MM-dd') } }, '-', @{ Header = '꺼짐'; IsEnabled = $false; ToolTip = '이유' }) }
        }
        try {
            $menuWith = & $module { param($b) Update-WtScheduleDayMenu $b; $m = $b.ContextMenu.Items; "$(@($m | ForEach-Object { if ($_ -is [Windows.Controls.Separator]) { '-' } else { $_.Header } }) -join ',')|$(@($m[3].Items | ForEach-Object { if ($_ -is [Windows.Controls.Separator]) { '-' } else { "$($_.Header):$($_.IsEnabled)" } }) -join ',')" } $cells[26].Button
            & $module { param($b) $b.ContextMenu.Items[3].Items[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent)) } $cells[26].Button
            Assert-WtTest '날짜 우클릭: 다른 탭이 등록한 항목(하위 메뉴 · 구분선 · 끈 항목)이 붙고, 누르면 그 탭의 동작에 날짜 인자를 넘긴다' (
                $menuWith -ceq '새 일정,새 루틴,-,가짜 넣기,회사 휴무로 지정|하나:True,-,꺼짐:False' -and $global:wtTestDateMenuArg.Day -ceq '2026-11-27') "$menuWith / $($global:wtTestDateMenuArg.Day)"
        } finally { & (Get-Module Addons) { param($i) for ($n = $script:addons.Count - 1; $n -ge 0; $n--) { if ($script:addons[$n].Id -ceq $i) { $script:addons.RemoveAt($n) } } } 'test-datemenu' }
        # ---- 2단계: 폼의 관련 항목 (코어 등록 목록에 가짜 출처를 등록, 메모 탭에 기대지 않음) ----
        $fakeTitles = @{ 'f-pick' = '고른 가짜' }
        Register-WtAddon -Id 'fake-related' -Title '가짜' -Icon 0xE70B -Order 900 -NewView { [Windows.Controls.Grid]::new() } -Related @{
            Name = '가짜'; Templates = @(@{ Id = 'blank'; Name = '빈 가짜' }, @{ Id = 'call'; Name = '통화 가짜' })
            Find = { param([string[]]$Keys) foreach ($k in $Keys) { [pscustomobject]@{ Key = $k; Title = [string]$fakeTitles[$k]; Sub = ''; Missing = -not $fakeTitles.ContainsKey($k) } } }
            Pick = { param([string[]]$Exclude) $script:fakePickExclude = $Exclude -join ','; 'f-pick' }
            New = { param($Seed) $script:fakeSeed = $Seed; $fakeTitles['f-new'] = $Seed.Title; 'f-new' }
            Window = { param($Key) $script:fakeWindow = $Key }
        }
        # 셸 화면 이동은 이 검사에서 기록만 한다(모듈 안의 같은 이름 함수가 먼저 불린다)
        & $module { function script:Open-WtPage { param([string]$Id, $Args) $a = $PSBoundParameters['Args']; $script:openedPage = "$Id|$($a.Key)|$($a.Edit)" } }
        $findLinkButtons = { param($Root) @(Get-WtTestLogical $Root | Where-Object { $_ -is [Windows.Controls.Button] -and [Windows.Automation.AutomationProperties]::GetAutomationId($_) -like 'Schedule-Link*' }) }
        & $module { Set-WtScheduleDate ([datetime]::new(2027, 4, 12)); Show-WtScheduleForm -Kind event }
        $newButtons = @(& $findLinkButtons (& $module { $script:form.LinkBox }) | Where-Object { [Windows.Automation.AutomationProperties]::GetAutomationId($_) -match 'LinkNew|LinkPick' })
        Assert-WtTest '관련 항목: 저장 전 새 일정은 [새 가짜] · [기존 가짜 고르기]를 끄고 이유를 툴팁에' (
            $newButtons.Count -eq 2 -and -not @($newButtons | Where-Object IsEnabled).Count -and $newButtons[0].ToolTip -ceq '일정을 먼저 저장하세요.') "$($newButtons.Count)"
        $formEvent = Save-WtScheduleItem (Open-WtScheduleStore) @{ title = '폼 연결'; start = @{ date = '2027-04-05'; time = '10:00' }; repeat = @{ freq = 'weekly' } }
        $openForm = { param($Id) $occ = @(Get-WtScheduleOccurrences (Get-WtScheduleData).Entries ([datetime]'2027-04-12') ([datetime]'2027-04-12') | Where-Object { $_.Entry.Id -ceq $Id })[0]; Show-WtScheduleForm -Kind event -Occurrence $occ }
        & $module $openForm $formEvent.Id
        & $module { $src = @(Get-WtRelatedSource -Page 'fake-related')[0]; Invoke-WtScheduleLinkNew $src 'call' }
        & $module { $src = @(Get-WtRelatedSource -Page 'fake-related')[0]; Invoke-WtScheduleLinkPick $src }
        $afterAdd = (@(Get-WtScheduleItemLinks $formEvent.Id '2027-04-12' | ForEach-Object { "$($_.Key):$($_.Date)" }) -join ',')
        $formTexts = @(Get-WtTestLogical (& $module { $script:form.LinkBox }) | Where-Object { $_ -is [Windows.Controls.TextBlock] } | ForEach-Object Text)
        Assert-WtTest '관련 항목 [새 가짜]: 틀 · 제목(MM-dd 일정 제목)으로 만들어 이 회차에 붙이고 탭을 편집으로 연다, 고르기는 이미 붙은 것을 빼고 모든 회차' (
            $fakeSeed.Template -ceq 'call' -and $fakeSeed.Title -ceq '04-12 폼 연결' -and $fakeSeed.Subject -ceq '폼 연결' -and
            (& $module { $script:openedPage }) -ceq 'fake-related|f-new|True' -and $fakePickExclude -ceq 'f-new' -and $afterAdd -ceq 'f-new:2027-04-12,f-pick:' -and
            $formTexts -contains '04-12 폼 연결' -and $formTexts -contains '이 회차' -and $formTexts -contains '고른 가짜' -and $formTexts -contains '모든 회차') "$afterAdd / $($formTexts -join ' | ')"
        # 바로 저장한 뒤에도 폼 [저장]이 낡은 핸들로 거부되지 않고, 연결을 지우지 않는다
        & $module { $script:form.Fields.title.Text = '폼 연결 바꿈'; Save-WtScheduleForm -Scope '이 회차만' }
        $savedLinks = (@(Get-WtScheduleItemLinks $formEvent.Id '2027-04-12' | ForEach-Object Key) -join ',')
        Assert-WtTest '관련 항목: 붙인 뒤 폼 저장이 통과하고 연결은 그대로' ((& $module { $null -eq $script:form }) -and $savedLinks -ceq 'f-new,f-pick') $savedLinks
        [void](Add-WtScheduleLink -Id $formEvent.Id -Page 'fake-related' -Key 'f-gone')
        [void](Add-WtScheduleLink -Id $formEvent.Id -Page 'off-tab' -Key 'x1')
        & $module $openForm $formEvent.Id
        $rowButtons = @(& $findLinkButtons (& $module { $script:form.LinkBox }) | Where-Object { $_.Tag -and $_.Tag.Link })
        $states = (@($rowButtons | ForEach-Object { "$($_.Tag.Link.Key):$($_.Tag.State):$(@($_.ContextMenu.Items | Where-Object { $_ -is [Windows.Controls.MenuItem] }).Count)" }) -join ',')
        $formTexts = @(Get-WtTestLogical (& $module { $script:form.LinkBox }) | Where-Object { $_ -is [Windows.Controls.TextBlock] } | ForEach-Object Text)
        $rowButtons[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-WtTest '관련 항목: 지운 항목 · 꺼진 탭은 흐리게 연결 빼기만, 정상 줄을 누르면 새 창' (
            $states -ceq 'f-new:ok:3,f-pick:ok:3,f-gone:missing:1,x1:off:1' -and $formTexts -contains '지운 가짜' -and $formTexts -contains '꺼진 탭' -and
            $fakeWindow -ceq 'f-new') "$states / $fakeWindow"
        & $module { param($Row) Invoke-WtScheduleLinkAction 'remove' $Row } $rowButtons[1].Tag
        $afterRemove = (@(Get-WtScheduleItemLinks $formEvent.Id '2027-04-12' | ForEach-Object Key) -join ',')
        & $module { Show-WtScheduleDay }
        $counts = @(Get-WtTestLogical (& $module { $script:detail }) | Where-Object { $_ -is [Windows.Controls.StackPanel] -and [Windows.Automation.AutomationProperties]::GetName($_) -like '관련 항목 *' } | ForEach-Object { [Windows.Automation.AutomationProperties]::GetName($_) })
        Assert-WtTest '관련 항목: 연결 빼기는 그 원소만, 일정 줄 끝 개수는 정상 연결만 센다' ($afterRemove -ceq 'f-new,f-gone,x1' -and ($counts -join ',') -ceq '관련 항목 1개') "$afterRemove / $($counts -join ',')"
        [void](Set-WtScheduleDeleted (Open-WtScheduleStore) -Id $formEvent.Id)
        & $module { Remove-Item function:script:Open-WtPage -ErrorAction Ignore }

        # ---- 3단계 화면(설계 14장): 보기 전환 · 표 · 할 일 · 찾기 · 깔때기 · 표 체크 · 루틴 보기 · 폼 태그 · 루틴 시각 ----
        $test = New-WtTestData 'schedule-view3'; $tests.Add($test)
        $t0 = [datetime]::Today; $dt = { param([int]$Days) ConvertTo-WtDateText $t0.AddDays($Days) }
        $mk3 = { param($Title, $From, $FromTime, $To, [string[]]$Tags, $Repeat) $p = @{ title = $Title; start = @{ date = $From; time = $FromTime }; tags = @($Tags) }; if ($To) { $p.end = @{ date = $To; time = $null } }; if ($Repeat) { $p.repeat = $Repeat }; (Save-WtScheduleItem (Open-WtScheduleStore) $p).Id }
        $late3 = & $mk3 '늦은 일' (& $dt -2) '10:00' $null @('작업')
        $today3 = & $mk3 '오늘 점검' (& $dt 0) '14:00' $null @('점검', '작업')
        $soon3 = & $mk3 '곧 끝남' (& $dt 1) $null (& $dt 2) @()
        $weekly3 = & $mk3 '매주 회의' (& $dt 0) '09:30' $null @('회의') @{ freq = 'weekly' }
        $r1 = Save-WtRoutine (Open-WtScheduleStore) @{ title = '가 루틴'; start = @{ date = (& $dt -7) }; routine = @{ freq = 'daily' } }
        $r2 = Save-WtRoutine (Open-WtScheduleStore) @{ title = '나 루틴'; start = @{ date = (& $dt -7) }; routine = @{ freq = 'daily'; time = '08:00' } }
        $r3 = Save-WtRoutine (Open-WtScheduleStore) @{ title = '다 루틴'; start = @{ date = (& $dt -7) }; routine = @{ freq = 'weekly'; days = @(1, 2, 3, 4, 5, 6, 7); time = '07:00' } }
        # 오늘은 차례가 없는 요일 루틴(내일 요일). 루틴 보기의 오늘 칸이 「오늘 없음」이어야 한다(없는 키를 @()로 감싸 0/1로 보이던 실수)
        $tomorrowDay = (([int]$t0.AddDays(1).DayOfWeek + 6) % 7) + 1
        $r4 = Save-WtRoutine (Open-WtScheduleStore) @{ title = '라 루틴'; start = @{ date = (& $dt -7) }; routine = @{ freq = 'weekly'; days = @($tomorrowDay) } }
        $tomorrowName = @('', '월', '화', '수', '목', '금', '토', '일')[$tomorrowDay]
        & $module { $script:form = $null; Set-WtScheduleDate ([datetime]::Today) }
        $sideRoutines = @(Get-WtTestLogical (& $module { $script:detail }) | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.Style -eq $view.FindResource('Checklist.Row') } | ForEach-Object { [Windows.Automation.AutomationProperties]::GetName($_) })
        Assert-WtTest '루틴 목록: 시각 없는 것 → 시각순, 시각이 있으면 「07:00 제목」' (($sideRoutines -join ',') -ceq '가 루틴,07:00 다 루틴,08:00 나 루틴') ($sideRoutines -join ',')
        # 루틴 줄 끝 관련 항목 수(2단계): 차례 정보에 루틴의 연결이 실려야 보인다(전에는 빠져 늘 안 보였다)
        [void](Add-WtScheduleLink -Id $r2.Id -Page 'fake-related' -Key 'f-pick')
        & $module { Show-WtScheduleDay }
        $routineCounts = @(Get-WtTestLogical (& $module { $script:detail }) | Where-Object { $_ -is [Windows.Controls.StackPanel] -and [Windows.Automation.AutomationProperties]::GetName($_) -like '관련 항목 *' } | ForEach-Object { [Windows.Automation.AutomationProperties]::GetName($_) })
        Assert-WtTest '루틴 줄 끝: 붙은 관련 항목 수를 보여 준다' (($routineCounts -join ',') -ceq '관련 항목 1개') ($routineCounts -join ',')
        [void](Remove-WtScheduleLink -Id $r2.Id -Page 'fake-related' -Key 'f-pick')

        & $module { Set-WtScheduleViewMode 'table' }
        $tableState = & $module { "$($script:view.TableHost.Visibility)|$($script:view.CalendarHost.Visibility)|$($script:view.TableNav.Visibility)|$($script:view.MonthButton.Visibility)" }
        $tableTitles = @(& $module { $script:tableItems } | ForEach-Object Title)
        Assert-WtTest '표 보기: 달력 대신 표, ‹ 오늘 ›과 해 · 달 단추, 보는 달의 일정과 오늘 루틴, 보기는 설정에 남음' (
            $tableState -ceq 'Visible|Collapsed|Visible|Visible' -and $tableTitles -contains '오늘 점검' -and $tableTitles -contains '나 루틴' -and (Get-WtSetting 'schedule.view') -ceq 'table') "$tableState / $($tableTitles -join ',')"
        & $module { Set-WtScheduleViewMode 'due' }
        $dueItems = @(& $module { $script:tableItems })
        $dueShape3 = (@($dueItems | ForEach-Object { if ($_.IsHead) { "[$($_.HeadName) $($_.HeadCount)]" } else { $_.Title } }) -join ',')
        $dueHeader = & $module { "$([Windows.Automation.AutomationProperties]::GetName($script:view.ViewTitle))|$($script:view.DueCount.Text.Trim())" }
        Assert-WtTest '할 일 보기: 묶음 머리(기한 지남 · 오늘 · 마감 임박) + 줄, 제목과 보기 단추에 할 일 수' (
            $dueShape3 -ceq '[기한 지남 1],늦은 일,[오늘 5],가 루틴,다 루틴,나 루틴,매주 회의,오늘 점검,[마감 임박 1],곧 끝남' -and
            $dueHeader -ceq '할 일 7|7' -and (Get-WtScheduleDueCount) -eq 7) "$dueShape3 / $dueHeader"
        $filterShared = Invoke-WtReadAction {
            $before = Get-WtScheduleDueRows
            & $module { $script:search.Box.Text = 'title:오늘'; $script:searchTimer.Stop(); Update-WtScheduleTable }
            $after = Get-WtScheduleDueRows
            $filtered = @(& $module { $script:tableItems } | Where-Object { -not $_.IsHead })
            $ok = [object]::ReferenceEquals($before,$after) -and $after.Rows.Count -eq 7 -and $filtered.Count -eq 1 -and $filtered[0].Title -ceq '오늘 점검'
            & $module { $script:search.Box.Text = ''; $script:searchTimer.Stop(); Update-WtScheduleTable }
            $ok
        }
        Assert-WtTest '할 일 검색: 공유한 원래 행을 고치지 않고 화면 결과만 거른다' $filterShared
        $statusOpen = & $module {
            $script:search.Box.Text='찾지 못할 가짜 조건'
            Open-WtScheduleArgs @{ Date=[datetime]::Today; View='calendar' }
            $todayOpened=$script:viewMode -ceq 'calendar' -and $script:selected -eq [datetime]::Today -and -not (Get-WtScheduleQueryText)
            Open-WtScheduleArgs @{ Date=[datetime]::Today; View='due' }
            $todayOpened -and $script:viewMode -ceq 'due' -and -not (Get-WtScheduleQueryText)
        }
        Assert-WtTest '상태 줄 열기: 찾기 조건을 지우고 오늘 달력·할 일 보기로 이동' $statusOpen
        # 할 일 색(설계 15.10): 기한 지남 = over, 3일 안에 끝나는 여러 날 = soon 배지. 묶음 머리 배지 색은 Group(overdue · today · soon)으로 그린다
        $dueKinds = (@($dueItems | Where-Object { -not $_.IsHead -and $_.DueKind } | ForEach-Object { "$($_.Title):$($_.DueKind)" }) -join ',')
        $headGroups = (@($dueItems | Where-Object IsHead | ForEach-Object Group) -join ',')
        Assert-WtTest '할 일 색: 늦은 일 = 빨강 배지(over), 곧 끝남 = 주황 배지(soon), 묶음 머리는 overdue · today · soon' ($dueKinds -ceq '늦은 일:over,곧 끝남:soon' -and $headGroups -ceq 'overdue,today,soon') "$dueKinds / $headGroups"
        # 사이드바에서 루틴을 체크해도 보기 단추 숫자 · 할 일 줄이 바로 맞춰진다
        $sideBox = @(Get-WtTestLogical (& $module { $script:detail }) | Where-Object { $_ -is [Windows.Controls.CheckBox] -and [Windows.Automation.AutomationProperties]::GetName($_) -ceq '가 루틴' })[0]
        $sideBox.IsChecked = $true
        $afterSide = & $module { "$($script:view.DueCount.Text.Trim())|$(@($script:tableItems | Where-Object { $_.Title -ceq '가 루틴' -and $_.Done }).Count)" }
        $sideBox = @(Get-WtTestLogical (& $module { $script:detail }) | Where-Object { $_ -is [Windows.Controls.CheckBox] -and [Windows.Automation.AutomationProperties]::GetName($_) -ceq '가 루틴' })[0]
        $sideBox.IsChecked = $false
        $afterUndo = & $module { $script:view.DueCount.Text.Trim() }
        Assert-WtTest '사이드바 루틴 체크: 할 일 숫자와 할 일 줄을 바로 맞춘다' ($afterSide -ceq '6|1' -and $afterUndo -ceq '7') "$afterSide / $afterUndo"
        $dueItems = @(& $module { $script:tableItems })
        & $module { param($i) Open-WtScheduleTableItem $i } @($dueItems | Where-Object { $_.IsHead -and $_.Group -ceq 'today' })[0]
        $folded = (@(& $module { $script:tableItems } | ForEach-Object { if ($_.IsHead) { "[$($_.HeadName)]" } else { $_.Title } }) -join ',')
        & $module { param($i) Open-WtScheduleTableItem $i } @(& $module { $script:tableItems } | Where-Object { $_.IsHead -and $_.Group -ceq 'today' })[0]
        Assert-WtTest '할 일 묶음 머리를 누르면 접고, 다시 누르면 편다' ($folded -ceq '[기한 지남],늦은 일,[오늘],[마감 임박],곧 끝남' -and @(& $module { $script:tableItems }).Count -eq $dueItems.Count) $folded
        $lateItem = @(& $module { $script:tableItems } | Where-Object { $_.Title -ceq '늦은 일' })[0]
        Assert-WtTest '할 일 줄: 기한 지남은 경고 아이콘 + 「2일 지남」, 날짜 · 시각 · 태그 칸' ($lateItem.DueText -ceq '2일 지남' -and $lateItem.DueWarn -ceq 'Visible' -and $lateItem.TimeText -ceq '10:00' -and ($lateItem.Tags -join ',') -ceq '#작업' -and $lateItem.DateText)
        $checkReads = & (Get-Module ScheduleData) {
            param($Item)
            $rows = ${function:New-WtScheduleRowResult}; $routines = ${function:Get-WtRoutineEntries}
            $script:checkRowsOriginal = $rows; $script:checkRoutineOriginal = $routines
            $script:checkRowCalls = 0; $script:checkRoutineCalls = 0
            function script:New-WtScheduleRowResult { param($Rows,$Problems,$From,$To,$Limit=0) $script:checkRowCalls++; & $script:checkRowsOriginal $Rows $Problems $From $To $Limit }
            function script:Get-WtRoutineEntries { param($Store) $script:checkRoutineCalls++; & $script:checkRoutineOriginal $Store }
            try {
                & (Get-Module Schedule) { param($i) Set-WtScheduleTableCheck $i $true } $Item
                @{ Rows=$script:checkRowCalls; Routines=$script:checkRoutineCalls }
            } finally {
                Set-Item Function:script:New-WtScheduleRowResult $rows
                Set-Item Function:script:Get-WtRoutineEntries $routines
                Remove-Variable checkRowsOriginal, checkRoutineOriginal, checkRowCalls, checkRoutineCalls -Scope Script
            }
        } $lateItem
        Assert-WtTest '체크 동작: 표·사이드바·배지·상태가 할 일 결과와 오늘 루틴 계산을 한 번씩 공유' ($checkReads.Rows -eq 1 -and $checkReads.Routines -eq 1) ($checkReads | ConvertTo-Json -Compress)
        $afterCheck = @(& $module { $script:tableItems } | ForEach-Object Title)
        Assert-WtTest '표 체크: 회차 기록을 남기고 다시 그린다(끝낸 기한 지남은 할 일에서 빠짐)' ((Get-WtEventDone).Contains("$late3@$(& $dt -2)") -and $afterCheck -notcontains '늦은 일') ($afterCheck -join ',')
        # 화면 읽기 도구(UIA Toggle)로 표의 상자를 바꿔도 저장된다. 다시 그려 같은 값이 들어올 때는 저장하지 않는다
        & $module { Set-WtScheduleViewMode 'table' }
        $view.Measure([Windows.Size]::new(1080, 744)); $view.Arrange([Windows.Rect]::new(0, 0, 1080, 744)); $view.UpdateLayout()
        $tableBox = & $module { $script:view.TableList }
        $weeklyItem = @(& $module { $script:tableItems } | Where-Object { $_.Title -ceq '매주 회의' })[0]
        $tableBox.ScrollIntoView($weeklyItem); $tableBox.UpdateLayout()
        $visualBoxes = [System.Collections.Generic.List[object]]::new()
        $walkVisual = { param($n) if ($n -is [Windows.Controls.CheckBox]) { $visualBoxes.Add($n) }; for ($k = 0; $k -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($n); $k++) { & $walkVisual ([Windows.Media.VisualTreeHelper]::GetChild($n, $k)) } }
        & $walkVisual $tableBox.ItemContainerGenerator.ContainerFromItem($weeklyItem)
        $logBefore = @((Read-WtTestDocNamed 'event-log').items).Count
        $peer = [Windows.Automation.Peers.CheckBoxAutomationPeer]::new($visualBoxes[0]); ([Windows.Automation.Provider.IToggleProvider]$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Toggle)).Toggle()
        $logAfter = @((Read-WtTestDocNamed 'event-log').items).Count
        Assert-WtTest '표 체크: UIA로 상자를 바꿔도 회차 기록을 남기고, 다시 그릴 때 들어오는 값은 저장하지 않는다' (
            $visualBoxes.Count -eq 1 -and (Get-WtEventDone).Contains("$weekly3@$(& $dt 0)") -and $logAfter -eq $logBefore + 1) "$($visualBoxes.Count) · $logBefore → $logAfter"
        # 체크로 표를 다시 그리면 화면에서 떨어진 옛 줄 그릇의 DataContext가 {DisconnectedItem}이 된다. 그 그릇에서 시작한 누름 · 체크가 와도
        # 고른 날을 지킨다. 전에는 고른 날이 비어 'Date' 오류가 나고, 앱을 끌 때까지 탭을 열 때마다 같은 오류가 났다(2026-11-16)
        $staleRow = @(& $module { $script:tableItems } | Where-Object { -not $_.IsHead -and -not $_.Done -and $_.Row.Kind -ceq 'event' })[0]
        $tableBox.ScrollIntoView($staleRow); $tableBox.UpdateLayout()
        $staleBox = $tableBox.ItemContainerGenerator.ContainerFromItem($staleRow)
        $selectedBefore = & $module { $script:selected }
        & $module { param($i) Set-WtScheduleTableCheck $i $true } $staleRow
        $tableBox.UpdateLayout()
        $staleUp = [Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)
        $staleUp.RoutedEvent = [Windows.UIElement]::MouseLeftButtonUpEvent; $staleUp.Source = $staleBox
        $tableBox.RaiseEvent($staleUp)
        & $module { param($i) Open-WtScheduleTableItem $i; Set-WtScheduleTableCheck $i $true } $staleBox.DataContext
        & $module { Update-WtScheduleView }
        $staleState = "$([object]::ReferenceEquals($staleBox.DataContext, [Windows.Data.BindingOperations]::DisconnectedSource))|$((& $module { $script:selected }) -eq $selectedBefore)"
        Assert-WtTest '표 옛 줄: 다시 그린 뒤 떨어진 줄 그릇에서 누름 · 체크가 와도 고른 날을 지키고 다시 그린다' ($staleState -ceq 'True|True') $staleState
        & $module { $script:selected = $null; $script:month = $null; Update-WtScheduleView }
        $healed = & $module { "$($script:selected -eq [datetime]::Today)|$($script:month -eq [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1))" }
        Assert-WtTest '일정 화면: 고른 날 · 보는 달이 비면 오늘로 되돌려 그린다' ($healed -ceq 'True|True') $healed
        [void](Set-WtEventCheck -Event $staleRow.Row.Occurrence.Entry.Id -Date (ConvertTo-WtDateText $staleRow.Row.Occurrence.Original) -Done $false)
        & $module { $script:viewMode = 'calendar'; $script:search.Box.Text = '#점검'; $script:searchTimer.Stop(); Invoke-WtScheduleSearch }
        $found3 = & $module { "$($script:viewMode)|$([Windows.Automation.AutomationProperties]::GetName($script:view.ViewTitle))|$(@($script:tableItems | ForEach-Object Title) -join ',')" }
        & $module { $script:search.Box.Text = 'is:nope'; $script:searchTimer.Stop(); Invoke-WtScheduleSearch }
        $badSearch = & $module { "$(@($script:tableItems | ForEach-Object Title) -join ',')|$($script:search.Box.ToolTip)" }
        Assert-WtTest '찾기: 달력에서 쓰면 표 보기로 바꿔 결과, 틀린 식은 앞 결과를 두고 찾기 칸에 이유' (
            $found3 -ceq 'table|찾기 결과 1|오늘 점검' -and $badSearch -clike '오늘 점검|찾기 식을 확인하세요.*') "$found3 / $badSearch"
        & $module { $script:search.Box.Text = ''; Switch-WtScheduleQueryTerm 'is:open'; Switch-WtScheduleQueryTerm '#회의' }
        $filterOn = & $module { $script:search.Box.Text }
        $menu3 = & $module { $m = New-WtHomePinContextMenu; Update-WtScheduleFilterMenu $m; @($m.Items | ForEach-Object { [string]$_.Header }) -join ',' }
        & $module { Switch-WtScheduleQueryTerm 'is:open'; Switch-WtScheduleQueryTerm '#회의' }
        $filterOff = & $module { $script:search.Box.Text }
        Assert-WtTest '깔때기: 조건을 찾기 칸 글에 넣고 다시 고르면 빼며, 메뉴는 상태 · 종류 · 많이 쓴 태그에 지금 조건 ✓' (
            $filterOn -ceq 'is:open #회의' -and $filterOff -ceq '' -and $menu3 -ceq '상태,✓ 안 끝낸 것,끝낸 것,종류,일정만,루틴만,태그,#작업,#점검,✓ #회의') "$filterOn / $menu3 / [$filterOff]"
        $pressedFilter = & $module {
            $press = { param($m, [string]$h) @($m.Items | Where-Object { [string]$_.Header -ceq $h })[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent)) }
            $m = New-WtHomePinContextMenu
            Update-WtScheduleFilterMenu $m; & $press $m '루틴만'; $on = $script:search.Box.Text
            Update-WtScheduleFilterMenu $m; & $press $m '✓ 루틴만'; "$on|[$($script:search.Box.Text)]"
        }
        Assert-WtTest '깔때기 메뉴(공통 메뉴 항목): 항목을 누르면 찾기 칸에 조건을 넣고, ✓ 항목을 다시 누르면 뺀다' ($pressedFilter -ceq 'is:routine|[]') $pressedFilter
        & $module { Set-WtScheduleViewMode 'routines' }
        $routineItems = @(& $module { @($script:view.RoutineList.ItemsSource) })
        $routineShape = (@($routineItems | ForEach-Object { "$($_.Title):$($_.RuleText):$($_.TimeText):$($_.TodayText)" }) -join ',')
        Assert-WtTest '루틴 보기: 모든 루틴을 시각 없는 것 → 시각순, 규칙 · 시각 · 오늘 진행' (
            $routineShape -ceq "가 루틴:매일:—:0/1,라 루틴:${tomorrowName}:—:오늘 없음,다 루틴:매일:07:00:0/1,나 루틴:매일:08:00:0/1" -and (& $module { [Windows.Automation.AutomationProperties]::GetName($script:view.ViewTitle) }) -ceq '루틴 4') $routineShape
        & $module { Set-WtScheduleViewMode 'table' }
        $todayItem = @(& $module { $script:tableItems } | Where-Object { $_.Title -ceq '오늘 점검' })[0]
        & $module { param($i) Open-WtScheduleTableItem $i } $todayItem
        $tagField = & $module { $script:form.Fields.tags.Text }
        & $module { $script:form.Fields.tags.Text = '#보고,  작업'; Save-WtScheduleForm }
        $savedTags = @(@((Get-WtScheduleData).Entries | Where-Object Id -CEQ $today3)[0].Tags) -join ','
        $weeklyOcc = @(Get-WtScheduleOccurrences (Get-WtScheduleData).Entries $t0 $t0 | Where-Object { $_.Entry.Id -ceq $weekly3 })[0]
        & $module { param($o) Show-WtScheduleForm -Kind event -Occurrence $o; $script:form.Fields.tags.Text = '회의, 바뀜'; Save-WtScheduleForm -Scope '이 회차만' } $weeklyOcc
        $scopeError = & $module { $script:form.Errors.tags.Text }
        Assert-WtTest '폼 태그: 표 줄을 누르면 폼, 태그 칸은 쉼표로 보여 주고 저장, 「이 회차만」에서는 태그를 바꿀 수 없음' (
            $tagField -ceq '점검, 작업' -and $savedTags -ceq '보고,작업' -and $scopeError -clike '*이후 모두*') "$tagField / $savedTags / $scopeError"
        & $module { param($Id) Show-WtScheduleForm -Kind routine -Id $Id; $script:form.Fields.time.Text = '7:30'; Save-WtScheduleForm } $r1.Id
        $timeError = & $module { $script:form.Errors.time.Text }
        & $module { $script:form.Fields.time.Text = '07:30'; Save-WtScheduleForm }
        $savedTime = [string]@((Get-WtScheduleData).Items | Where-Object { $_.id -ceq $r1.Id })[0].routine.time
        & $module { param($Id) Show-WtScheduleForm -Kind routine -Id $Id; $script:form.Fields.freq.SelectedItem = '시간마다'; Update-WtScheduleFormFields } $r1.Id
        $timeHidden = & $module { $script:form.Rows.time.Visibility }
        & $module { Show-WtScheduleDay }
        Assert-WtTest '루틴 폼 시각: HH:mm만 받고 저장, 시간마다로 고르면 시각 칸을 숨긴다' ($timeError -clike '시각을 확인하세요*' -and $savedTime -ceq '07:30' -and $timeHidden -ceq 'Collapsed') "$timeError / $savedTime / $timeHidden"
        & $module { Set-WtScheduleViewMode 'calendar' }

        foreach ($mode in 'due', 'routines') {
            & $module { param($m) Set-WtScheduleViewMode $m } $mode
            $parts = & $module { param($m) if ($m -eq 'routines') { @($script:view.RoutineList, $script:view.RoutineHead) } else { @($script:view.TableList, $script:view.TableHead) } } $mode
            $list = $parts[0]; $head = $parts[1]; $oldItems = $list.ItemsSource
            try {
                $row = @($oldItems)[0]
                foreach ($case in @(@(2,744,$false), @(100,744,$true), @(100,4000,$false), @(100,240,$true), @(2,744,$false))) {
                    $list.ItemsSource = @(@($row) * $case[0])
                    $view.Measure([Windows.Size]::new(1080,$case[1])); $view.Arrange([Windows.Rect]::new(0,0,1080,$case[1])); $view.UpdateLayout()
                    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
                    $view.UpdateLayout()
                    $scroll = Get-WtVisualChild $list ([Windows.Controls.ScrollViewer])
                    Assert-WtTest "일정 머리 열 맞춤: $mode · $($case[0])줄/높이$($case[1]) · 막대=$($case[2])" (
                        ($scroll.ComputedVerticalScrollBarVisibility -eq 'Visible') -eq $case[2] -and $head.Padding.Right -eq $(if ($case[2]) { 12 } else { 0 })) "$($scroll.ComputedVerticalScrollBarVisibility) / $($head.Padding.Right)"
                }
            } finally { $list.ItemsSource = $oldItems }
        }
        & $module { Set-WtScheduleViewMode 'calendar' }
        [IO.File]::WriteAllText((Get-WtStorePath 'schedule'), '{ "schema": 3, "items": [] }', [Text.UTF8Encoding]::new($false))
        & $module { Update-WtScheduleView }
        Assert-WtTest '일정 화면: 못 읽는 파일은 이유 표시 · 새로 만들기 비활성' ((Get-WtTestTexts $view | Where-Object { $_ -like '*더 새 버전*' }).Count -gt 0 -and -not (& $module { $script:side.Add.IsEnabled }))

        # ---- 알람 2b 화면 (설계 16장): 앱 틱 → 알림 창 · 소리, 본문 → 그날 폼, 다시 알림, 이 일정 알람 끄기, 잠시 끄기, 폼 알람 자세히, 설정 행 ----
        # 창 · 소리는 실제로 내지 않는다. 코어 알림 부품의 OS 자리(창 보이기 · 작업 영역 · 재생기 · 기본 소리 · 앱 창 열기)만 가짜로 바꾸고 15초 타이머를 끈다
        $test = New-WtTestData 'schedule-alarm-notice'; $tests.Add($test)
        $noticeModule = Get-Module Notice
        $global:wtAlarmProbe = @{ Shown = 0; Opened = [System.Collections.Generic.List[object]]::new() }
        $noticeSeams = & $noticeModule {
            $saved = @{ Show = $script:showWindow; Area = $script:workArea; Player = $script:newPlayer; System = $script:systemSound; Open = $script:openPage; Timer = $script:useTimer }
            $script:useTimer = $false
            $script:showWindow = { param($Window) $global:wtAlarmProbe.Shown++ }
            $script:workArea = { [System.Windows.Rect]::new(0, 0, 1920, 1040) }
            $script:systemSound = { }
            $script:openPage = { param($Id, $OpenArgs) $global:wtAlarmProbe.Opened.Add(@($Id, $OpenArgs)) }
            $script:newPlayer = {
                $fake = [pscustomobject]@{ Volume = -1.0; Opened = ''; Plays = 0 }
                $fake | Add-Member ScriptMethod Open { param($Uri) $this.Opened = [string]$Uri }
                $fake | Add-Member ScriptMethod Play { $this.Plays++ }
                $fake | Add-Member ScriptMethod Stop { }
                $fake
            }
            $script:player = & $script:newPlayer
            $saved
        }
        $player = & $noticeModule { $script:player }
        $click = { param($Element) $Element.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
        $itemOf = { param($Id) @((Get-WtScheduleData).Items | Where-Object { (Test-WtRecordObject $_) -and $_.id -ceq $Id })[0] }
        try {
            $store = Open-WtScheduleStore; $k = @{}
            foreach ($pair in @(
                    @('meet', @{ title = '회의'; start = @{ date = '2026-11-23'; time = '14:00' }; alarms = @(@{ before = 10 }) }),
                    @('loud', @{ title = '덮어쓴 회의'; start = @{ date = '2026-11-23'; time = '14:00' }; alarms = @(@{ before = 10; sound = $false; snooze = 10; late = 60 }) }),
                    @('quiet', @{ title = '끈 동안'; start = @{ date = '2026-11-23'; time = '14:30' }; alarms = @(@{ before = 10 }) }),
                    @('day', @{ title = '하루 종일'; start = @{ date = '2026-11-24'; time = $null }; alarms = @(@{ before = 10 }) }),
                    @('daily', @{ title = '매일 9시'; start = @{ date = '2026-11-23'; time = '09:00' }; repeat = @{ freq = 'daily' }; alarms = @(@{ before = 5; snooze = 15 }) }))) {
                $r = Save-WtScheduleItem $store $pair[1] -At $alarmAt
                if (-not $r.Success) { throw "알람 화면 준비 $($pair[0]): $($r.Reason)" }
                $k[$pair[0]] = $r.Id; $store = $r.Store
            }
            Wait-WtTestWrites
            # 화면 · 앱 창이 없는 상태(트레이로 숨거나 다른 탭을 보는 것과 같음)에서 코어 틱 길로 부른다
            & $module { $script:alarmPrevious = $null; $script:alarmState = $null; $script:alarmSeen.Clear(); $script:view = $null; $script:form = $null }
            $addon = Get-WtAddon -Id 'schedule'
            $ran1 = Invoke-WtAddonTick 'schedule' ([datetime]'2026-11-23 13:49:50')
            $shown0 = $global:wtAlarmProbe.Shown; $plays0 = $player.Plays
            $ran2 = Invoke-WtAddonTick 'schedule' ([datetime]'2026-11-23 13:50:05')
            $open = @(Get-WtNotices)
            $meetNotice = @($open | Where-Object { $_.Spec.Data.Id -ceq $k.meet })[0]
            $loudNotice = @($open | Where-Object { $_.Spec.Data.Id -ceq $k.loud })[0]
            $ran3 = Invoke-WtAddonTick 'schedule' ([datetime]'2026-11-23 13:50:20')
            Assert-WtTest '알람 틱 → 알림 창: 코어 틱(15초)이 화면 · 앱 창 없이(트레이 상태) 판정 → 알람마다 창 하나 · 다음 틱은 그대로 · 소리는 덮어쓰기대로(끈 일정은 안 냄)' (
                $addon.Tick -and $addon.TickSeconds -eq 15 -and $ran1 -and $ran2 -and $ran3 -and $null -eq (Get-WtAddonTickError 'schedule') -and $null -eq (Get-WtWindow) -and
                $shown0 -eq 0 -and $global:wtAlarmProbe.Shown -eq 2 -and $open.Count -eq 2 -and $meetNotice -and $loudNotice -and $player.Plays -eq $plays0 + 1 -and @(Get-WtNotices).Count -eq 2) (
                "틱 $ran1 $ran2 $ran3 · 창 $($global:wtAlarmProbe.Shown) · 소리 $($player.Plays - $plays0) · 오류 $(Get-WtAddonTickError 'schedule')")
            Assert-WtTest '알림 창 내용(일정): 제목 · 「14:00 · 10분 뒤」 · 다시 알림 글(전역 5분 · 덮어쓴 일정 10분) · 소리 볼륨 70%' (
                $meetNotice.Parts.TitleText.Text -ceq '회의' -and $meetNotice.Parts.DetailText.Text -ceq '14:00 · 10분 뒤' -and [string]$meetNotice.Parts.Snooze.Content -ceq '5분 뒤' -and
                [string]$loudNotice.Parts.Snooze.Content -ceq '10분 뒤' -and $player.Volume -eq 0.7) "$($meetNotice.Parts.DetailText.Text) / $($meetNotice.Parts.Snooze.Content) / $($loudNotice.Parts.Snooze.Content) / $($player.Volume)"
            & $click $meetNotice.Parts.Body
            $opened = $global:wtAlarmProbe.Opened[$global:wtAlarmProbe.Opened.Count - 1]
            $view = New-WtTestView 'schedule'
            & $addon.OnOpen $opened[1]
            $formTitle = & $module { if ($script:form) { $script:form.Fields.title.Text } }
            Assert-WtTest '알림 본문 누름(일정): 창을 닫고 일정 탭(Id · 날짜) → 그날 · 그 일정 편집 폼' (
                $meetNotice.Closed -and $opened[0] -ceq 'schedule' -and $opened[1].Id -ceq $k.meet -and $formTitle -ceq '회의' -and (& $module { $script:selected }) -eq [datetime]'2026-11-23') "$($opened[0]) $($opened[1].Id) $formTitle"
            & $module { Show-WtScheduleDay }
            Invoke-WtNoticeSnooze $loudNotice ([datetime]'2026-11-23 13:51:00')
            Invoke-WtNoticeTick ([datetime]'2026-11-23 14:00:59')
            $early = @(Get-WtNotices).Count -eq 0
            Invoke-WtNoticeTick ([datetime]'2026-11-23 14:01:00')
            $again = @(Get-WtNotices | Where-Object { $_.Spec.Data.Id -ceq $k.loud })
            Assert-WtTest '다시 알림(일정): 덮어쓴 일정은 10분 뒤 같은 창을 다시 띄움 · 그 전 틱은 없음 · 소리는 그 일정 덮어쓰기(끔)대로' (
                $early -and $again.Count -eq 1 -and $player.Plays -eq $plays0 + 1 -and [string]$again[0].Parts.Snooze.Content -ceq '10분 뒤')
            $menu = New-WtNoticeMenu $again[0]
            $menu.Items[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
            $offAlarm = (& $itemOf $k.loud).alarms[0]; $offText = $again[0].Parts.DetailText.Text
            & $click $again[0].Parts.Undo
            $backAlarm = (& $itemOf $k.loud).alarms[0]
            Assert-WtTest '알림 창 「이 일정 알람 끄기」: before만 끄고 소리 · 다시 알림 · 늦은 알람 칸은 남김 · 실행 취소로 before 되돌림' (
                [string]$menu.Items[0].Header -ceq '이 일정 알람 끄기' -and $offText -ceq '이 일정 알람을 껐습니다.' -and $null -eq $offAlarm.before -and $offAlarm.sound -eq $false -and
                $offAlarm.snooze -eq 10 -and $offAlarm.late -eq 60 -and $backAlarm.before -eq 10 -and $again[0].Parts.DetailText.Text -ceq '알람을 다시 켰습니다.') "$($offAlarm | ConvertTo-Json -Compress) / $($backAlarm | ConvertTo-Json -Compress)"
            $dailyNotice = Show-WtNotice (& $module { param($Id) New-WtScheduleAlarmNotice ([pscustomobject]@{ Key = "$Id@2026-11-25/5"; Title = '매일 9시'; Id = $Id; OriginalDate = '2026-11-25'
                            Start = [datetime]'2026-11-25 09:00'; AllDay = $false; Sound = $null; Snooze = 15 }) } $k.daily) ([datetime]'2026-11-25 08:55')
            (New-WtNoticeMenu $dailyNotice).Items[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
            $afterOff = Get-WtScheduleAlarms -Now '2026-11-26T08:55:05+09:00' -Previous '2026-11-26T08:54:50+09:00' -Entries (Get-WtScheduleData).Entries -Late 30
            $dailyOff = -not @(& $pick $afterOff 'daily').Count -and $dailyNotice.Parts.Undo.Visibility -eq 'Visible'
            & $click $dailyNotice.Parts.Undo
            $afterUndo = Get-WtScheduleAlarms -Now '2026-11-26T08:55:05+09:00' -Previous '2026-11-26T08:54:50+09:00' -Entries (Get-WtScheduleData).Entries -Late 30
            Assert-WtTest '알림 창 「이 일정 알람 끄기」(반복): 계열 전체를 꺼서 다음 회차부터 안 울림 · 실행 취소하면 다시 울림' ($dailyOff -and @(& $pick $afterUndo 'daily').Count -eq 1)
            Clear-WtNotices
            $shownBefore = $global:wtAlarmProbe.Shown
            [void](Set-WtNoticePause hour ([datetime]'2026-11-23 14:15:00'))
            $pausedTick = @(Invoke-WtScheduleAlarmTick ([datetime]'2026-11-23 14:20:05'))
            [void](Set-WtNoticePause off ([datetime]'2026-11-23 14:25:00'))
            $resumedTick = @(Invoke-WtScheduleAlarmTick ([datetime]'2026-11-23 14:25:10'))
            $nextDay = @(Invoke-WtScheduleAlarmTick ([datetime]'2026-11-24 08:50:05'))
            Assert-WtTest '잠시 끄기 중 알람: 창 · 소리 없이 기록만 남겨 버림 · 다시 켜도 몰아서 울리지 않음 · 그 뒤 새 알람은 울림' (
                $pausedTick.Count -eq 1 -and $pausedTick[0].Title -ceq '끈 동안' -and $resumedTick.Count -eq 0 -and $nextDay.Count -eq 1 -and $nextDay[0].Title -ceq '하루 종일' -and
                $global:wtAlarmProbe.Shown -eq $shownBefore + 1 -and @(Get-WtNotices).Count -eq 1) "$(@($pausedTick).Count) $(@($resumedTick).Count) $(@($nextDay | ForEach-Object Title) -join ',') 창 $($global:wtAlarmProbe.Shown - $shownBefore)"
            Clear-WtNotices

            # 폼: 새 일정 기본 알람 · 알람 자세히 저장 · 불러오기 · 기준 시각 · 이 회차만
            & $module { Set-WtScheduleDate ([datetime]::new(2026, 11, 23)); Show-WtScheduleForm -Kind event }
            $newDefault = & $module { @([string]$script:form.Fields.alarm.SelectedItem, (@($script:form.Fields.alarm.Items) -join ',')) }
            Set-WtSetting 'schedule.alarmDefault' 30
            & $module { Show-WtScheduleForm -Kind event }
            $default30 = & $module { [string]$script:form.Fields.alarm.SelectedItem }
            Set-WtSetting 'schedule.alarmDefault' -1
            & $module { Show-WtScheduleForm -Kind event }
            $defaultNone = & $module { @([string]$script:form.Fields.alarm.SelectedItem, $script:form.AlarmMore.Toggle.IsEnabled, [string]$script:form.AlarmMore.Toggle.ToolTip) }
            Set-WtSetting 'schedule.alarmDefault' 10
            & $module { Show-WtScheduleDay }
            Assert-WtTest '폼 기본 알람: 새 일정은 설정값(기본 10분 전 · 30분 전 · 없음) · 선택지 없음 ~ 1시간 전 · 없음이면 알람 자세히 끔 + 이유' (
                $newDefault[0] -ceq '10분 전' -and $newDefault[1] -ceq '없음,정시,5분 전,10분 전,15분 전,30분 전,1시간 전' -and $default30 -ceq '30분 전' -and
                $defaultNone[0] -ceq '없음' -and -not $defaultNone[1] -and $defaultNone[2] -ceq '알람을 고르면 바꿀 수 있습니다.') "$($newDefault -join ' / ') / $default30 / $($defaultNone -join ',')"
            & $addon.OnOpen @{ Id = $k.meet; Date = [datetime]'2026-11-23' }
            $loaded = & $module { @($script:form.AlarmMore.Open, [string]$script:form.AlarmMore.Panel.Visibility, [string]$script:form.Fields.alarmSound.SelectedItem, [string]$script:form.Rows.alarmDayAt.Visibility, $script:form.AlarmMore.Toggle.IsEnabled) }
            # 실제 배치 좌표 경로(보이지 않는 HwndSource에 배치, 창 표시 · OS 입력 아님): 접힌 줄 → 펼친 뒤 소리 칸
            $alarmHost = [Windows.Controls.Border]::new()
            $hostParameters = [Windows.Interop.HwndSourceParameters]::new('Schedule alarm test')
            $hostParameters.WindowStyle = 0; $hostParameters.Width = 1280; $hostParameters.Height = 744
            $alarmSource = [Windows.Interop.HwndSource]::new($hostParameters); $alarmSource.RootVisual = $alarmHost
            try {
                $alarmHost.Child = $view
                $alarmHost.Measure([Windows.Size]::new(1280, 744)); $alarmHost.Arrange([Windows.Rect]::new(0, 0, 1280, 744)); $alarmHost.UpdateLayout()
                $toggle = & $module { $script:form.AlarmMore.Toggle }
                $togglePath = Test-WtTestInputPath -View $alarmHost -Element $toggle -Target $toggle -BringIntoView
                & $click $toggle
                $soundBox = & $module { $script:form.Fields.alarmSound }
                $soundPath = Test-WtTestInputPath -View $alarmHost -Element $soundBox -Target $soundBox -BringIntoView
            } finally { $alarmHost.Child = $null; $alarmSource.Dispose() }
            Assert-WtTest '폼 알람 자세히 좌표 경로: 접힌 줄과 펼친 소리 칸이 실제 배치 좌표에서 닿음' ($togglePath.Ok -and $soundPath.Ok) "$($togglePath.Path) / $($soundPath.Path)"
            $opened = & $module { @($script:form.AlarmMore.Open, [string]$script:form.AlarmMore.Panel.Visibility, $script:form.AlarmMore.Chevron.Text) }
            & $module { $f = $script:form.Fields; $f.alarmSound.SelectedItem = '끔'; $f.alarmSnooze.SelectedItem = '10분'; $f.alarmLate.SelectedItem = '울리지 않음' }
            $summary = & $module { $script:form.AlarmMore.Summary.Text }
            & $module { Save-WtScheduleForm }
            $saved = (& $itemOf $k.meet).alarms[0]
            Assert-WtTest '폼 알람 자세히: 처음엔 접힘(전역 따름 · 시각 일정은 기준 시각 숨김) → 펼침 → 소리 끔 · 다시 알림 10분 · 늦게 켰을 때 울리지 않음 저장(바뀐 칸만) · 요약 줄' (
                -not $loaded[0] -and $loaded[1] -ceq 'Collapsed' -and $loaded[2] -ceq '전역 따름 (켬)' -and $loaded[3] -ceq 'Collapsed' -and $loaded[4] -and
                $opened[0] -and $opened[1] -ceq 'Visible' -and $opened[2] -ceq ([string][char]0xE70D) -and $summary -ceq ' · 소리 끔 · 다시 알림 10분 · 늦게 켰을 때 울리지 않음' -and
                $saved.before -eq 10 -and $saved.sound -eq $false -and $saved.snooze -eq 10 -and $saved.late -eq 0 -and $saved.PSObject.Properties.Name -cnotcontains 'allDayAt') (
                "$($loaded -join ',') / $($opened -join ',') / $summary / $($saved | ConvertTo-Json -Compress)")
            & $addon.OnOpen @{ Id = $k.meet; Date = [datetime]'2026-11-23' }
            $reloaded = & $module { @([string]$script:form.Fields.alarmSound.SelectedItem, [string]$script:form.Fields.alarmSnooze.SelectedItem, [string]$script:form.Fields.alarmLate.SelectedItem, $script:form.AlarmMore.Summary.Text) }
            & $module { $script:form.Fields.alarmSound.SelectedItem = $script:form.Fields.alarmSound.Items[0]; Save-WtScheduleForm }
            $cleared = (& $itemOf $k.meet).alarms[0]
            Assert-WtTest '폼 알람 자세히 불러오기: 저장한 값 그대로 · 전역 따름으로 되돌리면 그 칸만 null(나머지 유지)' (
                $reloaded[0] -ceq '끔' -and $reloaded[1] -ceq '10분' -and $reloaded[2] -ceq '울리지 않음' -and $reloaded[3] -ceq ' · 소리 끔 · 다시 알림 10분 · 늦게 켰을 때 울리지 않음' -and
                $cleared.PSObject.Properties.Name -ccontains 'sound' -and $null -eq $cleared.sound -and $cleared.snooze -eq 10 -and $cleared.late -eq 0) "$($reloaded -join ' / ') / $($cleared | ConvertTo-Json -Compress)"
            & $addon.OnOpen @{ Id = $k.day; Date = [datetime]'2026-11-24' }
            $dayVisible = & $module { [string]$script:form.Rows.alarmDayAt.Visibility }
            & $module { $script:form.Fields.alarmDayAt.Text = '8:3'; Save-WtScheduleForm }
            $dayError = & $module { @([string]$script:form.Errors.alarmDayAt.Text, $script:form.AlarmMore.Open) }
            & $module { $script:form.Fields.alarmDayAt.Text = '08:30'; Save-WtScheduleForm }
            $daySaved = (& $itemOf $k.day).alarms[0]
            Assert-WtTest '폼 기준 시각(하루 종일): 하루 종일 일정만 보임 · 틀린 시각은 칸 아래 오류(펼쳐서 보임) · 08:30 저장' (
                $dayVisible -ceq 'Visible' -and $dayError[0] -ceq '기준 시각은 HH:mm 형식으로 입력하세요.' -and $dayError[1] -and $daySaved.allDayAt -ceq '08:30' -and $daySaved.before -eq 10) "$dayVisible / $($dayError -join ',') / $($daySaved | ConvertTo-Json -Compress)"
            & $addon.OnOpen @{ Id = $k.daily; Date = [datetime]'2026-11-25' }
            & $module { $script:form.Fields.alarmSound.SelectedItem = '끔'; Save-WtScheduleForm -Scope '이 회차만' }
            $dailyItem = & $itemOf $k.daily
            $change = $dailyItem.repeat.changes.'2026-11-25'.alarms[0]
            $occAlarm = @(& $pick (Get-WtScheduleAlarms -Now '2026-11-25T08:55:05+09:00' -Previous '2026-11-25T08:54:50+09:00' -Entries (Get-WtScheduleData).Entries -Late 30) 'daily')
            Assert-WtTest '폼 이 회차만: 회차 알람 목록에 보이는 네 칸 모두(소리 끔 · 일정의 다시 알림 15 · 빈 칸 null) · 일정 알람은 그대로 · 그 회차 판정에 반영' (
                $change.before -eq 5 -and $change.sound -eq $false -and $change.snooze -eq 15 -and $change.PSObject.Properties.Name -ccontains 'late' -and $null -eq $change.late -and
                $dailyItem.alarms[0].PSObject.Properties.Name -cnotcontains 'sound' -and $dailyItem.alarms[0].snooze -eq 15 -and $occAlarm.Count -eq 1 -and $occAlarm[0].Sound -eq $false -and $occAlarm[0].Snooze -eq 15) (
                "$($change | ConvertTo-Json -Compress) / $($dailyItem.alarms[0] | ConvertTo-Json -Compress)")

            # 설정 → 일반 → 알림의 일정 행
            $rows = @(& $module { New-WtScheduleAlarmSettingRows })
            $rowLabels = @($rows | ForEach-Object { $_.Label }) -join ','
            $rows[0].Control.SelectedItem = '30분 전'; $defaultSet = [int](Get-WtSetting 'schedule.alarmDefault')
            $rows[2].Control.SelectedItem = '울리지 않음'; $lateOff = [int](Get-WtSetting 'schedule.alarmLate')
            $rows[2].Control.SelectedItem = '시작 뒤 1시간까지 울림'; $lateHour = [int](Get-WtSetting 'schedule.alarmLate')
            $dayLine = $rows[1].Control.Children[0]; $mode = $dayLine.Children[0]; $timeBox = $dayLine.Children[1]; $dayErr = $rows[1].Control.Children[1]
            $mode.SelectedItem = '직접'; $direct = [string](Get-WtSetting 'schedule.alarmAllDay')
            $timeBox.Text = '25:00'; $timeBox.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.UIElement]::LostFocusEvent))
            $bad = @([string]$dayErr.Visibility, [string](Get-WtSetting 'schedule.alarmAllDay'))
            $timeBox.Text = '08:15'; $timeBox.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.UIElement]::LostFocusEvent))
            $direct2 = [string](Get-WtSetting 'schedule.alarmAllDay')
            $mode.SelectedItem = '업무 시작 시각'
            $back = @([string](Get-WtSetting 'schedule.alarmAllDay'), $timeBox.IsEnabled, $timeBox.Text)
            Set-WtSetting 'schedule.alarmDefault' 10; Set-WtSetting 'schedule.alarmLate' 30
            Assert-WtTest '설정 행(일정): 새 일정 기본 알람 · 하루 종일 알람 기준 · 늦게 켰을 때 — 고르면 바로 저장 · 직접 시각은 HH:mm만(틀리면 칸 아래 오류) · 업무 시작으로 되돌림' (
                $rowLabels -ceq '새 일정 기본 알람,하루 종일 알람 기준,늦게 켰을 때' -and $defaultSet -eq 30 -and $lateOff -eq 0 -and $lateHour -eq 60 -and
                $direct -ceq '09:00' -and $bad[0] -ceq 'Visible' -and $bad[1] -ceq '09:00' -and $direct2 -ceq '08:15' -and $back[0] -ceq '' -and -not $back[1] -and $back[2] -ceq '09:00') (
                "$rowLabels / $defaultSet $lateOff $lateHour / $direct $($bad -join ',') $direct2 / $($back -join ',')")
        } finally {
            try { Clear-WtNotices } catch { }
            try { [void](Set-WtNoticePause off) } catch { }
            & $noticeModule { param($saved) $script:showWindow = $saved.Show; $script:workArea = $saved.Area; $script:newPlayer = $saved.Player; $script:systemSound = $saved.System
                $script:openPage = $saved.Open; $script:useTimer = $saved.Timer; $script:player = $null } $noticeSeams
            Remove-Variable wtAlarmProbe -Scope Global -ErrorAction SilentlyContinue
        }
    }

} finally {
    foreach ($t in $tests) { Remove-WtTestData $t }
}

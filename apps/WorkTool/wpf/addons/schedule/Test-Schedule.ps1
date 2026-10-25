<#
.SYNOPSIS
    일정 탭을 임시 데이터로 검사한다: 예전 데이터 가져오기 · 반복 · 하루 일정 순서 · 알람 표시.

.DESCRIPTION
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.

.EXAMPLE
    pwsh -NoProfile -File apps/WorkTool/wpf/addons/schedule/Test-Schedule.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'Schedule.psm1') -Force -DisableNameChecking
$test = New-WtTestData 'schedule'

try {
    Write-WtTestLegacyCsv $test 'schedule' @'
"Id","Date","Time","Title","Note","Alarm","Repeat","LastAlarm","Updated"
"s1","2026-10-01","09:30","주간 회의","","10","weekly","",""
"s2","2026-10-01","14:00","백업 확인","","","weekdays","",""
"s3","2026-10-23","","보안 교육","","","","",""
"s4","2026-10-20","08:00","매일 점검","","0","daily","",""
'@
    $r = Import-WtLegacyData
    Assert-WtTest '일정: 예전 데이터를 가져온다' ($r.Count -eq 4 -and $r.Tabs.Count -eq 1) "($($r.Count) / $($r.Tabs -join ', '))"

    $s = Get-WtScheduleItems
    $byId = @{}; foreach ($i in $s) { $byId[$i.id] = $i }
    $d = { param($t) [datetime]::ParseExact($t, 'yyyy-MM-dd', $null) }
    Assert-WtTest '일정: 매주(목) 반복' ((Test-WtScheduleOn $byId.s1 (& $d '2026-10-22')) -and -not (Test-WtScheduleOn $byId.s1 (& $d '2026-10-21')))
    Assert-WtTest '일정: 평일 반복' (-not (Test-WtScheduleOn $byId.s2 (& $d '2026-10-24')) -and (Test-WtScheduleOn $byId.s2 (& $d '2026-10-26')))
    Assert-WtTest '일정: 반복 없음' ((Test-WtScheduleOn $byId.s3 (& $d '2026-10-23')) -and -not (Test-WtScheduleOn $byId.s3 (& $d '2026-10-24')))
    Assert-WtTest '일정: 매일 반복은 시작일부터' (-not (Test-WtScheduleOn $byId.s4 (& $d '2026-10-19')) -and (Test-WtScheduleOn $byId.s4 (& $d '2026-10-22')))
    $order = (@(Get-WtScheduleOn (& $d '2026-10-22') $s) | ForEach-Object id) -join ','
    Assert-WtTest '일정: 하루 일정은 시각 순서' ($order -eq 's4,s1,s2') $order
    Assert-WtTest '일정: 알람 표시' ((Format-WtAlarm 0) -eq '정시' -and (Format-WtAlarm 10) -eq '10분 전' -and (Format-WtAlarm 60) -eq '1시간 전' -and (Format-WtAlarm 1440) -eq '하루 전' -and $null -eq (Format-WtAlarm ''))
    Assert-WtTest '일정: 기간 일정 칸이 있다' ($byId.s1.endDate -eq '2026-10-01' -and $byId.s1.PSObject.Properties.Name -contains 'tags')
    $range = & (Get-Module Schedule) { param($items) Get-WtScheduleRange ([datetime]'2026-10-20') 20 $items } $s
    $sameRange = $true
    for ($i = 0; $i -lt 20; $i++) {
        $expected = @(Get-WtScheduleOn ([datetime]'2026-10-20').AddDays($i) $s).id -join ','
        if ((@($range[$i]).id -join ',') -cne $expected) { $sameRange = $false }
    }
    Assert-WtTest '일정: 여러 날 조회도 반복·기간·정렬이 하루 조회와 같다' ($range.Count -eq 20 -and $sameRange)
    if (Test-WtTestWpf) {
        $module = Get-Module Schedule
        $view = New-WtTestView 'schedule'
        & $module { Update-WtScheduleView; $script:testFirst = $script:list.Children[0]; Update-WtScheduleView }
        Assert-WtTest '일정: 같은 데이터는 화면을 다시 만들지 않는다' (& $module { [object]::ReferenceEquals($script:testFirst, $script:list.Children[0]) })
        $byId.s4.title = '바뀐 매일 점검'
        Write-WtStore schedule -Items $s
        & $module { Update-WtScheduleView }
        Assert-WtTest '일정: 외부 저장 변경을 재진입 때 반영한다' ((Get-WtTestTexts $view) -contains '바뀐 매일 점검')
        & $module { $script:testFirst = $script:list.Children[0]; $script:viewKey = '어제'; Update-WtScheduleView }
        Assert-WtTest '일정: 날짜 키가 바뀌면 다시 만든다' (& $module { -not [object]::ReferenceEquals($script:testFirst, $script:list.Children[0]) })
    }
} finally {
    Remove-WtTestData $test
}

<#
.SYNOPSIS
    메모 탭을 임시 데이터로 검사한다: 예전 데이터 가져오기 · 검색 · 쓰기 · 화면(탭 · 칸 나누기 · 빠른 이동 · 링크) · 저장 실패.

.DESCRIPTION
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.
    화면 · 저장 실패 검사는 Windows STA에서만 한다. 키 입력을 흉내 내려고 화면 밖에 시험 창을 잠깐 띄운다(활성화하지 않음).

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/memo/Test-Memo.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'fixtures/new-memo-perf-fixture.ps1')
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'MemoEditor.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Memo.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MemoData.psm1') -Force -DisableNameChecking
$memoModule = Get-Module Memo; $shellModule = Get-Module Shell
$test = New-WtTestData 'memo'
$held = $null
$win = $null

try {
    # ---- 예전 데이터 ----
    Write-WtTestLegacyCsv $test 'memo' @'
"Id","Title","Body","Created","Updated"
"a1","점검","첫 줄
둘째 줄","2026-10-01 09:00:00","2026-10-21 11:20:00"
"a2","회의 메모","장비 목록 정리","2026-10-02 10:00:00","2026-10-22 08:00:00"
'@
    $r = Import-WtLegacyData
    Assert-WtTest '메모: 예전 데이터를 가져온다' ($r.Count -eq 2 -and $r.Tabs.Count -eq 1) "($($r.Count) / $($r.Tabs -join ', '))"
    Assert-WtTest '메모: 예전 CSV는 그대로 둔다' ((Get-Content (Join-Path $test.Legacy 'memo.csv') -Raw) -match '"a1","점검"')
    $memos = Get-WtMemoItems
    $a1 = $memos | Where-Object id -eq 'a1'
    Assert-WtTest '메모: 여러 줄 본문 유지' ($a1.body -eq "첫 줄`n둘째 줄" -or $a1.body -eq "첫 줄`r`n둘째 줄")
    Assert-WtTest '메모: 최근 고친 순서' ((@(Get-WtMemoSorted $memos)[0]).id -eq 'a2')

    # ---- 쓰기 ----
    $when = [datetime]'2026-10-22 11:20:05'
    $nm = New-WtMemo $when
    $expectedStamp = Get-WtStamp ([DateTimeOffset]::new($when).ToOffset([timespan]::FromHours(9)))
    Assert-WtTest '메모: 새 메모' ($nm.id.Length -eq 12 -and $nm.created -eq $expectedStamp -and $nm.body -eq '')
    [void](Set-WtMemoContent $nm '  ' @'
점검 #서버 #서버
```
#코드안
```
- 할 일 #주간
'@ $when)
    Assert-WtTest '메모: 빈 제목은 저장 시각' ($nm.title -eq '2026-10-22 11:20')
    Assert-WtTest '메모: 본문 #태그를 모은다 (코드 안 · 중복 제외)' ((@($nm.tags) -join ',') -eq '서버,주간') (@($nm.tags) -join ',')
    $legacyMemo = $memos | Where-Object id -eq 'a2'
    $legacyMemo.PSObject.Properties.Remove('tags')
    [void](Set-WtMemoContent $legacyMemo '회의 메모' '고침 #회의' $when)
    Save-WtMemoItems @($memos + $nm)
    $re = Get-WtMemoItems
    Assert-WtTest '메모: 고친 것 저장 · 다시 읽기 (tags 없던 예전 항목 포함)' ($re.Count -eq 3 -and ($re | Where-Object id -eq 'a2').body -eq '고침 #회의' -and @(($re | Where-Object id -eq 'a2').tags)[0] -eq '회의')

    # ---- 설정 · 빠른 이동 찾기 (WPF 없이) ----
    $modes = foreach ($v in 'edit', 'preview', 'source', 'read', 'live', 'nope') { Set-WtSetting 'memo.mode' $v; & $memoModule { Get-WtMemoModeSetting } }
    Assert-WtTest '메모 설정: 예전 memo.mode(edit · preview)도 읽는다' (($modes -join ',') -eq 'live,read,source,read,live,live') ($modes -join ',')
    $qa = [pscustomobject]@{ id = 'q1'; title = '서버 점검'; body = '디스크' }
    $qb = [pscustomobject]@{ id = 'q2'; title = '회의'; body = '서버 점검 결과' }
    $qc = [pscustomobject]@{ id = 'q3'; title = '점심'; body = '없음' }
    $quick = @(& $memoModule { param($all) Find-WtMemoQuick $all '점검 서버' } @($qb, $qa, $qc))
    Assert-WtTest '메모 빠른 이동: 제목에 든 것을 위에, 본문에만 든 것을 아래에' ((@($quick | ForEach-Object id) -join ',') -eq 'q1,q2') (@($quick | ForEach-Object id) -join ',')

    # ---- 메모 5a: 고정 자료 · 저장 계약 · 검색(창 없이) ----
    function Get-MemoTestJson($Value) { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }
    function Read-MemoTestText([string]$Path) { & (Get-Module Storage) { param($p) Read-WtJsonText $p } $Path }
    function Read-MemoFixture([string]$Name, [string]$StoreName = 'memo') {
        $doc = Get-Content -LiteralPath (Join-Path $PSScriptRoot "fixtures/$Name.json") -Raw | ConvertFrom-Json -Depth 20 -DateKind String
        Write-WtJsonFile (Get-WtStorePath $StoreName) $doc
        $doc
    }
    function Assert-MemoThrows([string]$Name, [scriptblock]$Action) {
        $thrown = $false
        try { & $Action | Out-Null } catch { $thrown = $true }
        Assert-WtTest $Name $thrown
    }
    function Get-MemoResultIds($Result) {
        if (-not $Result.Success) { throw $Result.Error.Reason }
        $ids = [string[]]@($Result.Items | ForEach-Object Id); [Array]::Sort($ids, [StringComparer]::Ordinal)
        $ids -join ','
    }
    $oldDoc = Read-MemoFixture 'memo-main'
    Assert-WtTest '5a 보기: 처음에는 비어 있고 기본 보기를 저장하지 않음' (@(Get-WtMemoViews).Count -eq 0 -and -not (Test-Path -LiteralPath (Get-WtStorePath memo-views)))
    $oldItems = @(Get-WtMemoItems)
    Save-WtMemoItems $oldItems
    $raw = Read-WtStore -Name memo -Schema 1
    Assert-WtTest '5a 옛 파일: 제목 · 본문 · 옛 시각 · 가져온 위치 그대로 왕복' (
        (Get-MemoTestJson $raw.items) -ceq (Get-MemoTestJson $oldDoc.items) -and $raw.importedFrom -ceq $oldDoc.importedFrom -and $raw.schema -eq 1)
    $before = Read-MemoTestText (Get-WtStorePath memo)
    $store = Open-WtMemoStore; $virtual = @(Get-WtMemoFolders $store)
    Assert-WtTest '5a 폴더: 기본 넷은 가상, 읽어도 파일에 쓰지 않음' (
        ($virtual.id -join ',') -ceq 'work,procedure,incident,personal' -and ($virtual.name -join ',') -ceq '업무,절차,장애,개인' -and
        ($virtual.order -join ',') -eq '10,20,30,40' -and $before -ceq (Read-MemoTestText (Get-WtStorePath memo)) -and -not $store.Doc.PSObject.Properties['folders'])
    $store = Set-WtMemoFolder -Store $store -Id old1 -Folder work
    Assert-WtTest '5a 폴더: 메모 폴더 지정은 가상 폴더 목록을 쓰지 않음' (-not (Read-WtJsonFile (Get-WtStorePath memo)).PSObject.Properties['folders'])
    $store = Open-WtMemoStore; $virtual[0].name = '업무 변경'
    $store = Save-WtMemoFolders -Store $store -Folders $virtual
    Assert-WtTest '5a 폴더: 바꿀 때만 쓰고 id 유지, 반환 핸들로 이어서 읽기' (
        (Get-WtMemoFolders $store)[0].name -ceq '업무 변경' -and $store.Items[0].folder -ceq 'work' -and
        (Read-WtJsonFile (Get-WtStorePath memo)).folders.Count -eq 4)
    $store = Save-WtMemoFolders -Store $store -Folders @($virtual | Where-Object id -cne work)
    Assert-WtTest '5a 폴더: 폴더만 지워 메모 유지, folder는 없음' ($store.Items.Count -eq 1 -and $null -eq $store.Items[0].folder -and $store.Items[0].body -ceq $oldItems[0].body)
    $store = Save-WtMemoFolders -Store $store -Folders @(@(Get-WtMemoFolders $store) + [pscustomobject]@{ id = 'added'; name = '추가'; order = 5 })
    $added = @(Get-WtMemoFolders $store | Where-Object id -ceq added)[0]
    Assert-WtTest '5a 폴더: 추가 · 순서 · 실제 생성 시각' ($added.name -ceq '추가' -and $added.order -eq 5 -and $added.created -match '\+09:00$')
    $newDoc = Read-MemoFixture 'memo-v-new'
    $newItems = @(Get-WtMemoItems); $m1 = $newItems | Where-Object id -ceq m1
    [void](Set-WtMemoContent $m1 $m1.title ($m1.body + "`n추가 #새태그") $when)
    Save-WtMemoItems $newItems
    $raw = Read-WtStore -Name memo -Schema 1; $m1 = $raw.items[0]
    Assert-WtTest '5a 새 파일: 새 칸 · 중첩 모르는 칸 · 맨 위 키 보존' (
        $m1.folder -ceq 'procedure' -and $m1.pinned -and $m1.pinOrder -eq 20 -and -not $m1.archived -and $null -eq $m1.archivedAt -and
        (Get-MemoTestJson $m1.future) -ceq (Get-MemoTestJson $newDoc.items[0].future) -and
        (Get-MemoTestJson $raw.futureTop) -ceq (Get-MemoTestJson $newDoc.futureTop) -and
        (Get-MemoTestJson $raw.folders) -ceq (Get-MemoTestJson $newDoc.folders))
    Assert-WtTest '5a 새 파일: 지운 줄 · null · 깨진 배열 줄 같은 자리에 보존' (
        $raw.items.Count -eq 8 -and $raw.items[5].futureGone -ceq '남김' -and $null -eq $raw.items[6] -and $raw.items[7] -is [array] -and $raw.items[7][0] -ceq '깨진 줄')
    Assert-WtTest '5a 태그: 기존 해석기 그대로, 코드 안 태그 제외' (($m1.tags -join ',') -ceq '백업,운영,새태그')
    $bodyBefore = $m1.body; $titleBefore = $m1.title
    # 옛 판이 선택 칸을 없앤 상황도 본문/제목은 그대로 읽는다.
    foreach ($name in 'folder', 'pinned', 'pinOrder', 'archived', 'archivedAt') { $m1.PSObject.Properties.Remove($name) }
    Write-WtJsonFile (Get-WtStorePath memo) $raw
    $compat = @(Get-WtMemoItems); Save-WtMemoItems $compat
    Assert-WtTest '5a 호환: 옛 판이 새 칸을 없애도 제목 · 본문 유지' ($compat[0].body -ceq $bodyBefore -and $compat[0].title -ceq $titleBefore)
    $null = Read-MemoFixture 'memo-v-new'; $store = Open-WtMemoStore
    $stale = $store; $store = Set-WtMemoPinned -Store $store -Id m3 -Pinned $true -Order 5
    Assert-MemoThrows '5a 저장: 낡은 핸들은 거부' { Set-WtMemoArchived -Store $stale -Id m3 -Archived $true }
    $store = Set-WtMemoArchived -Store $store -Id m3 -Archived $true
    Assert-WtTest '5a 정리: 고정 순서 · 보관 · KST 시각 · rev' ($store.Items[2].pinned -and $store.Items[2].pinOrder -eq 5 -and $store.Items[2].archived -and $store.Items[2].archivedAt -match '\+09:00$' -and $store.Items[2].rev -eq 2)
    $store = Set-WtMemoArchived -Store $store -Id m3 -Archived $false
    Assert-WtTest '5a 정리: 보관 해제' (-not $store.Items[2].archived -and $null -eq $store.Items[2].archivedAt)
    $null = Read-MemoFixture 'memo-v-new'; $store = Open-WtMemoStore
    $index = New-WtMemoIndex $store.Items -Folders @(Get-WtMemoFolders $store)
    $unknown = (Find-WtMemo -Index $index -Query 'title:"일상 기록"').Items[0]
    Assert-WtTest '5a 폴더: 없는 id는 폴더 없음으로 표시, 원자료 칸 보존' ($null -eq $unknown.Folder -and $unknown.FolderName -ceq '폴더 없음' -and $store.Items[2].folder -ceq 'unknown-folder')
    $null = Read-MemoFixture 'memo-state-v1' 'memo-state'
    $memoBefore = Read-MemoTestText (Get-WtStorePath memo)
    $memoVersion = & (Get-Module Storage) { (Get-WtDataFileRecord (Get-WtStorePath memo)).Version }
    $state = Open-WtStore -Name memo-state -Schema 1
    $stateBefore = Read-MemoTestText (Get-WtStorePath memo-state)
    $state = Set-WtMemoOpened -Store $state -MemoStore $store -Id m1 -At '2026-10-26T09:00:59+09:00'
    Assert-WtTest '5a 최근: 1분 안 다시 열기는 쓰지 않음' ($stateBefore -ceq (Read-MemoTestText (Get-WtStorePath memo-state)))
    $state = Set-WtMemoOpened -Store $state -MemoStore $store -Id m1 -At '2026-10-26T09:01:00+09:00'
    Assert-WtTest '5a 최근: 60초 뒤 기록, 모르는 칸/없어진 id 유지, memo.json 안 씀' (
        $state.Items[0].opened -ceq '2026-10-26T09:01:00+09:00' -and $state.Items[0].future -ceq '남김' -and $state.Items[2].id -ceq 'missing' -and
        $memoBefore -ceq (Read-MemoTestText (Get-WtStorePath memo)) -and $memoVersion -eq (& (Get-Module Storage) { (Get-WtDataFileRecord (Get-WtStorePath memo)).Version }))
    Assert-WtTest '5a 최근: 맨 위 모르는 키 보존' ((Read-WtJsonFile (Get-WtStorePath memo-state)).futureState -ceq '남김')
    # 메모를 열 때마다 화면 스레드에서 돈다. 메모 전체를 JSON으로 복사하면 메모 3,000개에서 몇 초씩 멈춘다
    $refuseOpen = { param($items, $id) try { [void](Set-WtMemoOpened -Store $state -MemoStore ([pscustomobject]@{ Name = 'memo'; State = 'ok'; Items = $items }) -Id $id -At '2026-10-26T09:02:00+09:00'); '' } catch { $_.Exception.Message } }
    $openChecks = @((& $refuseOpen @() 'x'), (& $refuseOpen @([pscustomobject]@{ id = 'x'; deleted = '2026-10-26T09:00:00+09:00' }) 'x'), (& $refuseOpen @([pscustomobject]@{ id = 'x' }, [pscustomobject]@{ id = 'x' }) 'x'))
    Assert-WtTest '5a 최근: 메모를 복사하지 않고 확인만 한다 · 없는 · 지운 · 겹친 메모는 거절' ((Get-Command Set-WtMemoOpened).ScriptBlock.ToString() -notmatch 'Get-WtMemoEditable' -and $openChecks[0] -ceq '항목을 찾지 못했습니다' -and $openChecks[1] -like '지운 메모*' -and $openChecks[2] -like 'id가 겹쳐*') ($openChecks -join ' / ')
    $recent = Find-WtMemo -Index $index -View recent -OpenedMap $state
    Assert-WtTest '5a 최근: 없는 메모 무시, 열람 시각 내림차순' (($recent.Items.Id -join ',') -ceq 'm1,m2')
    $openedMap = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in $state.Items) { $openedMap[$entry.id] = $entry.opened }
    Assert-WtTest '5a 최근: ordinal 사전도 같은 결과' (((Find-WtMemo -Index $index -View recent -OpenedMap $openedMap).Items.Id -join ',') -ceq 'm1,m2')
    $null = Read-MemoFixture 'memo-views-v1' 'memo-views'
    $viewsStore = Open-WtStore -Name memo-views -Schema 1
    Assert-WtTest '5a 보기: 지운 보기 숨김' (@(Get-WtMemoViews $viewsStore).Count -eq 1)
    $queryText = '  (folder:장애 OR tag:운영)   -tag:초안  '
    $viewsStore = Save-WtMemoView -Store $viewsStore -Id v1 -Name '장애 대응 변경' -Query $queryText -Sort @{ by = 'backlinks'; dir = 'desc' }
    $viewItem = $viewsStore.Items[0]
    Assert-WtTest '5a 보기: 검색식 원문 · 중첩 모르는 칸 유지, rev 올림' (
        $viewItem.query -ceq $queryText -and $viewItem.futureView -ceq '남김' -and $viewItem.sort.futureSort -ceq '남김' -and $viewItem.rev -eq 2 -and
        (Read-WtJsonFile (Get-WtStorePath memo-views)).futureViews -ceq '남김')
    $viewsStore = Save-WtMemoView -Store $viewsStore -Name '태그 정리' -Query 'no:tag' -Scope all -Sort @{ by = 'title'; dir = 'asc' }
    Assert-WtTest '5a 보기: 새 id · 원자료만 저장' ($viewsStore.Items[-1].id -match '^[0-9a-f]{12}$' -and $viewsStore.Items[-1].rev -eq 0 -and $null -eq $viewsStore.Items[-1].deleted -and -not $viewsStore.Items[-1].PSObject.Properties['results'])
    $viewsStore = Set-WtMemoViewDeleted -Store $viewsStore -Id v1
    Assert-WtTest '5a 보기: 지운 표시 · 되살리기' ((Test-WtDeleted $viewsStore.Items[0]) -and @(Get-WtMemoViews $viewsStore).Count -eq 1)
    $viewsStore = Set-WtMemoViewDeleted -Store $viewsStore -Id v1 -Deleted $false
    Assert-WtTest '5a 보기: 되살린 보기의 검색식 유지' ($viewsStore.Items[0].query -ceq $queryText -and $viewsStore.Items[0].rev -eq 4)

    # 조사 보고서 표의 모든 행 + 경계/우선순위. 상대 날짜는 실행 PC의 오늘로 별도 검사한다.
    $cases = @(
        @('복구 절차', 'm1,m2,m5'), @('"권한 오류"', 'm1,m2'), @('title:복구', 'm1'), @('body:오류', 'm1'),
        @('#백업', 'm1'), @('tag:백업', 'm1'), @('folder:절차', 'm1'), @('folder:procedure', 'm1'), @('is:pinned', 'm1,m2'),
        @('scope:archived', 'm4'), @('scope:all', 'm1,m2,m3,m4,m5'), @('updated:2026-10-01..2026-10-31', 'm1,m2,m3,m5'),
        @('updated:<2026-10-04', 'm3'), @('updated:>2026-10-25', 'm1'), @('updated:2026-10-25..2026-10-26', 'm1,m2'),
        @('-tag:초안', 'm1,m3,m5'), @('-"권한 오류"', 'm3,m5'), @('has:link', 'm1,m2,m5'), @('has:backlink', 'm1,m5'),
        @('no:tag', 'm3'), @('linksto:"복구 절차"', 'm2,m5'), @('tag:운영 OR tag:초안 AND title:권한', 'm1,m2,m5'),
        @('(tag:운영 OR tag:초안) AND title:권한', 'm2'), @('-(tag:운영 OR tag:초안)', 'm3'), @('--tag:초안', 'm2'),
        @('folder:절차 (tag:백업 OR tag:복구) -tag:초안', 'm1'), @('"*" "?" "[]"', 'm1'), @('tag:백', ''), @('tag:코드안', ''),
        @('linksto:"일상 기록"', ''), @('title:"복구 절차" scope:all', 'm1')
    )
    foreach ($case in $cases) {
        $result = Find-WtMemo -Index $index -Query $case[0]
        Assert-WtTest "5a 검색: $($case[0])" ((Get-MemoResultIds $result) -ceq $case[1]) (Get-MemoResultIds $result)
        $parsed = ConvertFrom-WtMemoQuery $case[0]; $round = ConvertFrom-WtMemoQuery (ConvertTo-WtMemoQuery $parsed)
        Assert-WtTest "5a 왕복: $($case[0])" ((Get-MemoTestJson $parsed) -ceq (Get-MemoTestJson $round))
    }
    $errors = @(@('"닫지 않음', 0), @('title:', 0), @('x:값', 0), @('a OR', 4), @('a AND )', 6), @('(a', 2), @('a)', 1),
        @('()', 1), @('-', 1), @('updated:2026-02-30', 0), @('updated:0d', 0), @('scope:all scope:archived', 10), @('-scope:all', 0))
    foreach ($case in $errors) {
        $parsed = ConvertFrom-WtMemoQuery $case[0]; $result = Find-WtMemo -Index $index -Query $case[0]
        Assert-WtTest "5a 오류 위치: $($case[0])" (-not $parsed.Success -and $parsed.Error.Position -eq $case[1] -and $parsed.Error.Reason -and -not $result.Success -and $result.Count -eq 0)
    }
    $chips = [pscustomobject]@{ Scope = 'all'; Root = [pscustomobject]@{ Kind = 'and'; Children = @(
        [pscustomobject]@{ Kind = 'term'; Field = 'folder'; Value = 'procedure' },
        [pscustomobject]@{ Kind = 'not'; Child = [pscustomobject]@{ Kind = 'term'; Field = 'tag'; Value = '초안' } }) } }
    $chipRound = ConvertFrom-WtMemoQuery (ConvertTo-WtMemoQuery $chips)
    Assert-WtTest '5a 칩: 직접 만든 조건 → 글 → 같은 구조/결과' ((Get-MemoTestJson $chips.Root) -ceq (Get-MemoTestJson $chipRound.Root) -and (Get-MemoResultIds (Find-WtMemo -Index $index -Query $chips)) -ceq 'm1')
    Assert-WtTest '5a 정렬: 일반은 고정 순서 → 수정일' (((Find-WtMemo -Index $index).Items.Id -join ',') -ceq 'm2,m1,m5,m3')
    Assert-WtTest '5a 정렬: 제목 완전 일치 → 제목 포함 → 본문 포함' (((Find-WtMemo -Index $index -Query '복구 절차').Items.Id -join ',') -ceq 'm1,m2,m5')
    Assert-WtTest '5a 정렬: 태그 조건만이면 일반 목록 순' (((Find-WtMemo -Index $index -Query 'tag:운영').Items.Id -join ',') -ceq 'm1,m5')
    foreach ($sort in 'updated', 'created', 'title', 'opened', 'backlinks') {
        $asc = Find-WtMemo -Index $index -Sort $sort -Dir asc -OpenedMap $state
        $desc = Find-WtMemo -Index $index -Sort $sort -Dir desc -OpenedMap $state
        Assert-WtTest "5a 선택 정렬: $sort 양방향" ($asc.Success -and $desc.Success -and $asc.Count -eq 4 -and $desc.Count -eq 4 -and $asc.Items[0].Id -cne $desc.Items[0].Id)
    }
    $matchRow = (Find-WtMemo -Index $index -Query 'body:오류').Items[0]
    Assert-WtTest '5a 결과: 본문 일치 위치 · 80자 이내 문맥' ($matchRow.Matches[0].Field -ceq 'body' -and $matchRow.Matches[0].Start -eq 3 -and $matchRow.Snippet.Length -le 80 -and $matchRow.Snippet.Contains('오류'))
    Assert-WtTest '5a 연결: 반복 링크는 1개, 코드 안 연결 제외' ($index.Entries['m1'].BacklinkCount -eq 2 -and $index.Entries['m3'].BacklinkCount -eq 0)
    $changed = Copy-WtItem $store.Items[1]; $changed.body = '연결 지움'; $changed.tags = @()
    Update-WtMemoIndex -Index $index -Memo $changed
    Assert-WtTest '5a 증분: 본문/태그/연결 하나 갱신' ($index.Entries['m1'].BacklinkCount -eq 1 -and (Get-MemoResultIds (Find-WtMemo -Index $index -Query 'tag:초안')) -ceq '')
    Update-WtMemoIndex -Index $index -Remove m5
    Assert-WtTest '5a 증분: 삭제하면 나가는/받는 연결 갱신' ($index.Entries['m1'].BacklinkCount -eq 0 -and (Get-MemoResultIds (Find-WtMemo -Index $index -Query 'has:backlink')) -ceq '')
    $rename = Copy-WtItem $store.Items[0]; $rename.title = '새 제목'
    Update-WtMemoIndex -Index $index -Memo $rename
    Assert-WtTest '5a 증분: 제목 사본 · 제목 역색인 갱신' (-not $index.Titles.ContainsKey('복구 절차') -and (Get-MemoResultIds (Find-WtMemo -Index $index -Query 'title:"새 제목"')) -ceq 'm1')
    $rankMemos = @(
        [pscustomobject]@{ id = 'r1'; title = '대상'; body = ''; pinned = $false; updated = '2026-10-01T00:00:00+09:00' },
        [pscustomobject]@{ id = 'r2'; title = '대상 포함'; body = ''; pinned = $false; updated = '2026-10-01T00:00:00+09:00' },
        [pscustomobject]@{ id = 'r3'; title = '다른 제목'; body = ('가' * 140) + '대상' + ('나' * 140); pinned = $true; updated = '2026-10-26T00:00:00+09:00' })
    $ranked = Find-WtMemo -Index (New-WtMemoIndex $rankMemos) -Query '대상'
    Assert-WtTest '5a 정렬/문맥: 세 단계가 고정보다 우선, 긴 본문은 일치 앞뒤 80자' (($ranked.Items.Id -join ',') -ceq 'r1,r2,r3' -and $ranked.Items[2].Snippet.Length -eq 80 -and $ranked.Items[2].Snippet.Contains('대상') -and $ranked.Items[2].SnippetStart -gt 0)
    $caseIndex = New-WtMemoIndex @([pscustomobject]@{ id = 'a'; title = '한글 I'; body = '#표시' }, [pscustomobject]@{ id = 'A'; title = '한글 i'; body = '' })
    Assert-WtTest '5a id: 대소문자 별개, 텍스트 대소문자 무시, 제목 동률은 id ordinal' (((Find-WtMemo -Index $caseIndex -Query 'title:I').Items.Id -join ',') -ceq 'A,a')
    # 보기를 바꿔도 원래 색인은 그대로이며, 명시한 검색 범위와 보기의 추가 조건을 함께 지킨다.
    $viewIndex = New-WtMemoIndex @(
        [pscustomobject]@{ id = 'a'; title = '일반 열람'; body = ''; pinned = $false },
        [pscustomobject]@{ id = 'A'; title = '고정 미열람'; body = ''; pinned = $true },
        [pscustomobject]@{ id = 'b'; title = '보관 열람'; body = ''; archived = $true },
        [pscustomobject]@{ id = 'c'; title = '보관 고정'; body = ''; pinned = $true; archived = $true },
        [pscustomobject]@{ id = 'd'; title = '삭제'; body = ''; pinned = $true; deleted = $true },
        [pscustomobject]@{ id = 'e'; title = '일반 미열람'; body = '' })
    $viewOpened = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($id in 'a', 'b', 'c', 'd', 'f', 'missing') { $viewOpened[$id] = '2026-10-01T10:00:00+09:00' }
    foreach ($case in @(
        @('normal', '', 'A,a,e'), @('pinned', '', 'A'), @('archived', '', 'b,c'), @('all', '', 'A,a,b,c,e'),
        @('recent', '', 'a'), @('recent', 'scope:all', 'a,b,c'), @('pinned', 'scope:archived', 'c'), @('pinned', 'scope:all', 'A,c'),
        @('일반', '', 'A,a,e'), @('고정', '', 'A'), @('보관', '', 'b,c'), @('모두', '', 'A,a,b,c,e'), @('최근 열기', '', 'a'))) {
        $selectedIds = Get-MemoResultIds (Find-WtMemo -Index $viewIndex -View $case[0] -Query $case[1] -OpenedMap $viewOpened -SkipBacklinks)
        Assert-WtTest "5a 보기 교차: $($case[0]) / $($case[1])" ($selectedIds -ceq $case[2]) $selectedIds
    }
    Assert-WtTest '5a 보기: 열람 기록이 없으면 최근은 비고, 일반은 바뀌지 않는다' (
        (Find-WtMemo -Index $viewIndex -View recent -SkipBacklinks).Count -eq 0 -and
        (Get-MemoResultIds (Find-WtMemo -Index $viewIndex -SkipBacklinks)) -ceq 'A,a,e')
    Update-WtMemoIndex -Index $viewIndex -Remove a
    Update-WtMemoIndex -Index $viewIndex -Memo ([pscustomobject]@{ id = 'f'; title = '새로 연 메모'; body = ''; pinned = $true })
    Assert-WtTest '5a 보기: 삭제된 색인 칸 제외 · 새 칸의 최근/고정 반영 · id 대소문자 구분' (
        (Get-MemoResultIds (Find-WtMemo -Index $viewIndex -View recent -OpenedMap $viewOpened -SkipBacklinks)) -ceq 'f' -and
        (Get-MemoResultIds (Find-WtMemo -Index $viewIndex -View pinned -SkipBacklinks)) -ceq 'A,f' -and
        (Get-MemoResultIds (Find-WtMemo -Index $viewIndex -View recent -Query 'scope:all' -OpenedMap $viewOpened -SkipBacklinks)) -ceq 'b,c,f')
    $emptyViews = @(foreach ($view in 'normal', 'pinned', 'recent', 'archived', 'all') {
        $emptyResult = Find-WtMemo -Index (New-WtMemoIndex @()) -View $view -OpenedMap $viewOpened -First 0 -SkipBacklinks
        $emptyResult.Success -and $emptyResult.Count -eq 0 -and $emptyResult.Items.Count -eq 0
    })
    Assert-WtTest '5a 보기: 빈 색인의 모든 보기에서 빈 결과' ($emptyViews.Count -eq 5 -and -not ($emptyViews -contains $false))
    $quoted = ConvertFrom-WtMemoQuery '"#표시"'
    Assert-WtTest '5a 글자: 따옴표 속 #은 태그 조건이 아닌 본문 검색' ($quoted.Root.Field -ceq 'text' -and (Get-MemoResultIds (Find-WtMemo -Index $caseIndex -Query $quoted)) -ceq 'a')

    # PC 현지 날짜, 오늘 포함 7일. 문화를 바꿔도 모든 식/정렬/새 시각이 같다.
    $today = [datetime]::Today
    $dateMemos = @(for ($day = 0; $day -lt 9; $day++) {
        $stamp = Get-WtStamp ([DateTimeOffset]::new($today.AddDays(-$day).AddHours(12)))
        [pscustomobject]@{ id = "d$day"; title = "Date $day"; body = ''; tags = @(); created = $stamp; updated = $stamp }
    })
    $dateIndex = New-WtMemoIndex $dateMemos
    $cultureBefore = [Globalization.CultureInfo]::CurrentCulture; $uiCultureBefore = [Globalization.CultureInfo]::CurrentUICulture
    try {
        $baseline = $null
        foreach ($cultureName in 'ko-KR', 'en-US', 'th-TH', 'ar-SA', 'ja-JP') {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::new($cultureName)
            [Globalization.CultureInfo]::CurrentUICulture = [Globalization.CultureInfo]::new($cultureName)
            $cultureIndex = New-WtMemoIndex $store.Items -Folders @(Get-WtMemoFolders $store)
            $cultureResults = @(foreach ($case in $cases) { Get-MemoResultIds (Find-WtMemo -Index $cultureIndex -Query $case[0]) })
            foreach ($sort in 'updated', 'created', 'title', 'opened', 'backlinks') { $cultureResults += (Find-WtMemo -Index $cultureIndex -Sort $sort -OpenedMap $state).Items.Id -join ',' }
            $current = $cultureResults -join ';'
            if ($null -eq $baseline) { $baseline = $current }
            Assert-WtTest "5a 문화권: $cultureName 모든 검색/정렬 동일" ($current -ceq $baseline)
            foreach ($field in 'updated', 'created') {
                Assert-WtTest "5a 문화권: $cultureName ${field}:7d 오늘 포함 7일" ((Get-MemoResultIds (Find-WtMemo -Index $dateIndex -Query "${field}:7d")) -ceq 'd0,d1,d2,d3,d4,d5,d6')
            }
            $cultureMemo = New-WtMemo $when
            Assert-WtTest "5a 문화권: $cultureName 앱 시각/제목 그레고리력" ($cultureMemo.created -ceq $expectedStamp -and (Set-WtMemoContent $cultureMemo '' '' $when).title -ceq '2026-10-22 11:20')
        }
    } finally { [Globalization.CultureInfo]::CurrentCulture = $cultureBefore; [Globalization.CultureInfo]::CurrentUICulture = $uiCultureBefore }

    # 함수 단위 Stopwatch, 창 없음. GC는 측정 밖에서만 한다. 실행 환경 차이가 있어 시간은 실패 조건으로 삼지 않는다.
    function Write-MemoPerf([string]$Label, [double[]]$Samples, [string]$Unit = 'ms') {
        $firstSample = $Samples[0]; $orderedSamples = [double[]]$Samples.Clone(); [Array]::Sort($orderedSamples)
        $medianSample = ($orderedSamples[4] + $orderedSamples[5]) / 2
        Write-Host ('PERF {0} 10회 중앙값 {1:F1}{4} 최댓값 {2:F1}{4} 첫 회 {3:F1}{4}' -f $Label, $medianSample, $orderedSamples[-1], $firstSample, $Unit)
    }
    $perfSeed = 5061581; $perfRandom = [Random]::new($perfSeed)
    $realFixture = New-WtMemoPerfFixture -Count 3000 -Seed $perfSeed
    $uniqueBodies = [Collections.Generic.HashSet[string]]::new([Collections.Generic.IEnumerable[string]][string[]]$realFixture.Document.items.body, [StringComparer]::Ordinal)
    Assert-WtTest '성능 자료: 서로 다른 본문 3000개 · 2048 낱말 · 평균 1.2KB · 20KB 1%' (
        $uniqueBodies.Count -eq 3000 -and $realFixture.Vocabulary -ge 2000 -and $realFixture.AverageBodyBytes -ge 1150 -and $realFixture.AverageBodyBytes -le 1300 -and
        @($realFixture.Document.items | Where-Object { [Text.Encoding]::UTF8.GetByteCount($_.body) -ge 20KB }).Count -eq 30)
    Assert-WtTest '성능 자료: 연결 절반 · 같은 제목 20쌍 · 고정20 · 보관5% · 삭제1% · 폴더4 · 열람1000' (
        @($realFixture.Document.items | Where-Object { $_.body.Contains('[[') }).Count -eq 1500 -and
        @($realFixture.Document.items | Group-Object title | Where-Object Count -eq 2).Count -eq 20 -and
        @($realFixture.Document.items | Where-Object pinned -eq $true).Count -eq 20 -and @($realFixture.Document.items | Where-Object archived -eq $true).Count -eq 150 -and
        @($realFixture.Document.items | Where-Object deleted).Count -eq 30 -and $realFixture.Document.folders.Count -eq 4 -and $realFixture.State.items.Count -eq 1000)
    # 아래 기존 검색 기대값(3000건/고정 제외2970건)은 유지하고, 본문만 모두 다른 실제 크기로 만든다.
    $perfBodies = [string[]]::new(3000)
    for ($variant = 0; $variant -lt $perfBodies.Length; $variant++) {
        $perfBodies[$variant] = '권한 오류 복구 절차 #백업 [[대상]] ' + $realFixture.Document.items[$variant].body
    }
    $perfMemos = @(for ($i = 0; $i -lt 3000; $i++) { [pscustomobject]@{
        id = "perf$i"; title = "메모 $i"; body = $perfBodies[$i]; tags = @('백업'); folder = 'work'; pinned = ($i % 100 -eq 0)
        created = '2026-10-01T09:00:00+09:00'; updated = '2026-10-26T09:00:00+09:00'
    } })
    $watch = [Diagnostics.Stopwatch]::new()
    $indexTimes = [double[]]::new(10); $firstTimes = [double[]]::new(10); $indexMemory = [double[]]::new(10)
    $validFirst = $true
    for ($repeat = 0; $repeat -lt $indexTimes.Length; $repeat++) {
        $perfIndex = $null; $perfResult = $null
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); $memoryBefore = [GC]::GetTotalMemory($true)
        $watch.Restart(); $perfIndex = New-WtMemoIndex $perfMemos; $watch.Stop(); $indexTimes[$repeat] = $watch.Elapsed.TotalMilliseconds
        # 매번 새 색인에서 검색한다. 정렬/연결 준비를 이전 검색에서 빌려 오지 않는다.
        $watch.Restart(); $perfResult = Find-WtMemo -Index $perfIndex -Query '권한 오류'; $watch.Stop(); $firstTimes[$repeat] = $watch.Elapsed.TotalMilliseconds
        $validFirst = $validFirst -and $perfResult.Success -and $perfResult.Count -eq 3000
        $perfResult = $null; $indexMemory[$repeat] = ([GC]::GetTotalMemory($true) - $memoryBefore) / 1MB
    }
    Assert-WtTest '5a 속도 자료: 새 색인 10개 첫 검색 결과 개수' $validFirst
    Write-Host "PERF 씨앗 $perfSeed 메모 3000개 본문 모두 다름 · 평균 약1.2KB + 검색 검사용 접두어 · 1%는20KB (메모리는 입력 자료를 제외한 GC 후 색인 보유량)"
    Write-MemoPerf '색인 (연결은 첫 검색에 포함)' $indexTimes
    Write-MemoPerf '새 색인의 첫 검색 [권한 오류]' $firstTimes
    Write-MemoPerf '색인 관리 힙' $indexMemory 'MiB'
    foreach ($perfQuery in '권한 오류', 'title:메모', '#백업', 'folder:업무 updated:2026-10-01..2026-10-31', 'has:link -is:pinned') {
        $times = [double[]]::new(10); $validPerf = $true
        for ($repeat = 0; $repeat -lt $times.Length; $repeat++) {
            $watch.Restart(); $perfResult = Find-WtMemo -Index $perfIndex -Query $perfQuery; $watch.Stop()
            $times[$repeat] = $watch.Elapsed.TotalMilliseconds
            $validPerf = $validPerf -and $perfResult.Success -and $perfResult.Count -eq $(if ($perfQuery -eq 'has:link -is:pinned') { 2970 } else { 3000 })
        }
        Assert-WtTest "5a 속도 자료: [$perfQuery] 10회 결과 개수" $validPerf
        Write-MemoPerf "검색 [$perfQuery]" $times
    }
    $full = Find-WtMemo -Index $perfIndex -Query 'body:오류' -SnippetLimit ([int]::MaxValue)
    $limited = Find-WtMemo -Index $perfIndex -Query 'body:오류'
    $without = Find-WtMemo -Index $perfIndex -Query 'body:오류' -SnippetLimit 0
    $same = $full.Success -and $limited.Success -and $without.Success -and $full.Count -eq 3000 -and $limited.Count -eq $full.Count -and $without.Count -eq $full.Count
    for ($i = 0; $same -and $i -lt $full.Count; $i++) {
        $same = $full.Items[$i].Id -ceq $limited.Items[$i].Id -and $full.Items[$i].Id -ceq $without.Items[$i].Id -and
            $full.Items[$i].SnippetStart -eq $limited.Items[$i].SnippetStart -and
            $full.Items[$i].Matches[0].Start -eq $limited.Items[$i].Matches[0].Start -and
            $without.Items[$i].Snippet -ceq ''
        if ($i -lt 200) { $same = $same -and $full.Items[$i].Snippet -ceq $limited.Items[$i].Snippet }
        else { $same = $same -and $limited.Items[$i].Snippet -ceq '' }
    }
    Assert-WtTest '5a 일부 한도: 정렬/개수/일치 위치 유지, 앞 200개만 원문, 0/전체 선택 가능' $same
    $perfChanged = Copy-WtItem $perfMemos[0]; $times = [double[]]::new(10)
    for ($repeat = 0; $repeat -lt $times.Length; $repeat++) {
        $perfChanged.body = $perfBodies[0] + " 수정 $repeat"
        $watch.Restart(); Update-WtMemoIndex -Index $perfIndex -Memo $perfChanged; $watch.Stop()
        $times[$repeat] = $watch.Elapsed.TotalMilliseconds
    }
    Write-MemoPerf '메모 하나 본문/연결 갱신' $times

    # 연결 해석은 메모 하나에 약 12ms다. 한꺼번에 하면 메모 3,000개의 첫 찾기가 36초 걸렸다
    $linkMemos = @(foreach ($i in 1..6) { [pscustomobject]@{ id = "l$i"; title = "연결 $i"; body = $(if ($i % 2) { "[[연결 $($i + 1)]]" } else { '연결 없음' }); tags = @() } })
    $stepped = New-WtMemoIndex $linkMemos
    $skipped = (Find-WtMemo -Index $stepped -Query '연결' -SkipBacklinks).Count -eq 6 -and -not $stepped.LinksReady
    $steps = 0; while (-not (Step-WtMemoLinks $stepped 0)) { $steps++ }
    $whole = New-WtMemoIndex $linkMemos
    Assert-WtTest '메모 연결: 목록 찾기는 해석을 기다리지 않고, 나눠 해석해도 한꺼번에 한 결과와 같다' ($skipped -and $steps -ge 5 -and $stepped.LinksReady -and -not $stepped.LinkCache.Count -and
        (Get-MemoResultIds (Find-WtMemo -Index $stepped -Query 'has:backlink')) -ceq (Get-MemoResultIds (Find-WtMemo -Index $whole -Query 'has:backlink'))) "$skipped/$steps"
    $editing = New-WtMemoIndex $linkMemos
    [void](Step-WtMemoLinks $editing 0)
    Update-WtMemoIndex -Index $editing -Memo ([pscustomobject]@{ id = 'l1'; title = '연결 1'; body = '[[연결 3]]'; tags = @() })
    while (-not (Step-WtMemoLinks $editing 0)) { }
    Assert-WtTest '메모 연결: 해석하는 사이 고친 본문이 결과에 들어간다' ((Get-MemoResultIds (Find-WtMemo -Index $editing -Query 'linksto:"연결 3"')) -ceq 'l1' -and -not (Get-MemoResultIds (Find-WtMemo -Index $editing -Query 'linksto:"연결 2"')))
    $hints = & (Get-Module MemoData) {
        $samples = '그냥 글 #태그', '[[메모]]', '[글](x)', '![그림](a.png)', 'https://a.example', 'HTTP://A.EXAMPLE', 'ftp://a.example', 'www.a.example', 'WWW.A.EXAMPLE', '<mailto:a@a.example>', 'mailto:a@a.example', 'MAILTO:a@a.example', 'tel:010', '<a href="x">y</a>', 'a@a.example', '[^1]', '`[[코드]]`'
        $fast = foreach ($b in $samples) { (Get-WtMemoLinkInfo $b).HasLink }
        $keep = $script:memoLinkHint; $script:memoLinkHint = [regex]::new('')   # 모든 본문을 해석기로 보낸다
        $full = foreach ($b in $samples) { (Get-WtMemoLinkInfo $b).HasLink }
        $script:memoLinkHint = $keep
        @{ Fast = $fast -join ','; Full = $full -join ','; Some = ($full -contains $true) -and ($full -contains $false) }
    }
    Assert-WtTest '메모 연결: 연결이 될 글자가 없으면 해석을 건너뛰어도 해석기 결과와 같다' ($hints.Some -and $hints.Fast -ceq $hints.Full) "$($hints.Fast) / $($hints.Full)"
    $linkQuery = { param($q) Test-WtMemoQueryLinks (ConvertFrom-WtMemoQuery $q).Root }
    Assert-WtTest '메모 연결: 연결을 쓰는 검색식을 빼는 조건까지 알아본다' ((& $linkQuery 'has:link') -and (& $linkQuery '-has:backlink') -and (& $linkQuery 'title:가 linksto:나') -and -not (& $linkQuery 'title:가') -and -not (& $linkQuery '오류 #태그'))

    # 저장: 안 고친 메모는 복사하지 않는다. 메모마다 복사 · 병합하면 메모 3,000개에서 저장 한 번에 화면이 20초 멈췄다
    $keepItems = @([pscustomobject]@{ id = 'k1'; title = '하나'; body = '가'; rev = 1; updated = '2026-10-01T09:00:00+09:00'; future = '남김' }
        [pscustomobject]@{ id = 'k2'; title = '둘'; body = '나'; rev = 1; updated = '2026-10-01T09:00:00+09:00' }
        [pscustomobject]@{ id = 'k3'; title = '셋'; body = '다'; rev = 1; updated = '2026-10-01T09:00:00+09:00' })
    $null = Get-WtMemoItems
    $null = Save-WtMemoDataItems -Store (Open-WtMemoStore) -Items $keepItems
    $keepStore = Open-WtMemoStore
    $keepOf = { param($items, $id) @($items | Where-Object { [string]$_.id -ceq $id })[0] }   # 앞 검사의 메모가 지운 표시로 앞자리에 남아 있어 id로 찾는다
    $reread = @(Copy-WtItem @($keepStore.Items))   # 다시 읽은 것처럼 객체만 다르고 내용이 같다
    $sameSecond = Copy-WtItem (& $keepOf $reread 'k2'); $sameSecond.body = '나나'   # 같은 초 · 같은 rev로 본문만 다르다
    $saved = Save-WtMemoDataItems -Store $keepStore -Items @((& $keepOf $keepStore.Items 'k1'), $sameSecond, (& $keepOf $reread 'k3'))
    Wait-WtTestWrites
    $savedBack = @((Read-WtJsonFile (Get-WtStorePath memo)).items)
    $keptSame = @([object]::ReferenceEquals((& $keepOf $saved.Items 'k1'), (& $keepOf $keepStore.Items 'k1')), [object]::ReferenceEquals((& $keepOf $saved.Items 'k3'), (& $keepOf $keepStore.Items 'k3')),
        -not [object]::ReferenceEquals((& $keepOf $saved.Items 'k2'), (& $keepOf $keepStore.Items 'k2')), ((& $keepOf $saved.Items 'k2').body -ceq '나나'),
        ((& $keepOf $savedBack 'k1').future -ceq '남김'), ((& $keepOf $savedBack 'k2').body -ceq '나나'))
    Assert-WtTest '메모 저장: 안 고친 메모는 원자료 그대로, 고친 메모만 새 객체, 같은 초에 고쳐도 반영, 모르는 칸 유지' ($keptSame -notcontains $false) ($keptSame -join ',')

    # 아래 기존 화면 검사는 새 목록을 저장하며 시작한다. 데이터 검사에서 직접 연 핸들 대신 지금 원자료를 읽어 준비한다.
    $null = Get-WtMemoItems

    if (-not (Test-WtTestWpf)) { Write-Host 'SKIP 메모 화면 · 저장 실패 (Windows STA에서만)'; return }
    $addon = Get-WtAddon -Id 'memo'
    $lazyMemo = New-WtMemo; $lazyMemo.title = '가짜 요약 검사'; $lazyMemo.body = '# 제목' + "`n**본문**"
    $lazyRow = & $memoModule { param($m) New-WtMemoListItem $m } $lazyMemo
    $lazyBefore = $null -eq $lazyRow.SnippetValue
    $lazyText = [Windows.Controls.TextBlock]::new(); $lazyText.DataContext = $lazyRow
    [void][Windows.Data.BindingOperations]::SetBinding($lazyText, [Windows.Controls.TextBlock]::TextProperty, [Windows.Data.Binding]::new('Snippet'))
    $lazyText.GetBindingExpression([Windows.Controls.TextBlock]::TextProperty).UpdateTarget()
    Assert-WtTest 'WPF 메모: 보이는 행이 요약을 읽을 때 원래 문자열로 한 번 만든다' ($lazyBefore -and $lazyText.Text -eq '제목 · 본문' -and $lazyRow.SnippetValue -eq $lazyText.Text)

    # ---- 화면 준비: 가짜 메모 셋 · 키 흉내 ----
    # 키 이벤트(KeyEventArgs)는 창의 PresentationSource가 있어야 만든다. 화면 밖에 활성화하지 않고 띄운다.
    # 보조 키(Ctrl · Shift · Alt)는 실제 키보드 상태 대신 $script:testMods를 읽게 바꾼다
    & $memoModule { $script:testMods = [System.Windows.Input.ModifierKeys]::None; function script:Get-WtMemoModifiers { $script:testMods } }
    $win = [System.Windows.Window]::new()
    $win.Width = 1280; $win.Height = 720; $win.Left = -4000; $win.Top = 0
    $win.WindowStartupLocation = 'Manual'; $win.ShowActivated = $false; $win.ShowInTaskbar = $false
    function Show-TestView {
        $script:view = New-WtTestView 'memo'
        $win.Content = $script:view
        if (-not $win.IsVisible) { $win.Show() }
        [void](& $addon.Refresh $script:view)
        $win.UpdateLayout()
    }
    function Send-TestKey([string]$Key, [string]$Mods = 'None') {
        & $memoModule { param($m) $script:testMods = [System.Enum]::Parse([System.Windows.Input.ModifierKeys], $m) } $Mods
        $src = [System.Windows.PresentationSource]::FromVisual($win)
        $a = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]$Key)
        $a.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
        $script:view.RaiseEvent($a)
        & $memoModule { $script:testMods = [System.Windows.Input.ModifierKeys]::None }
        $a.Handled
    }
    function Send-TestListClick([string]$Id, [string]$Button = 'Left', [string]$Mods = 'None') {
        & $memoModule { param($m) $script:testMods = [System.Enum]::Parse([System.Windows.Input.ModifierKeys], $m) } $Mods
        $list = & $memoModule { $script:ui.List }
        $list.UpdateLayout()
        $row = $list.Items | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
        $c = $list.ItemContainerGenerator.ContainerFromItem($row)
        if (-not $c) { throw "목록 행을 찾지 못했습니다: $Id" }
        $a = [System.Windows.Input.MouseButtonEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0, [System.Windows.Input.MouseButton]$Button)
        $a.RoutedEvent = [System.Windows.UIElement]::PreviewMouseDownEvent
        $c.RaiseEvent($a)
        & $memoModule { $script:testMods = [System.Windows.Input.ModifierKeys]::None }
    }
    # 사용자가 본문을 고친 것처럼: 편집기 인터페이스로 글을 바꾸고 OnChanged를 부른다
    function Set-TestBody([int]$Pane, [string]$Text) {
        & $memoModule { param($i, $t) $p = $script:panes[$i]; $null = Set-WtMemoEditorText $p.Editor $t; & $p.Editor.OnChanged $p.Editor } $Pane $Text
    }
    function Get-TestTabs {
        & $memoModule {
            [pscustomobject]@{
                Panes   = $script:panes.Count
                Active  = $script:active
                Tabs    = @($script:panes | ForEach-Object { (@($_.Tabs | ForEach-Object { $_.Id }) -join ',') })
                Current = @($script:panes | ForEach-Object { if ($_.Current) { [string]$_.Current.Id } else { '' } })
            }
        }
    }
    function Get-TestBody([int]$Pane) { & $memoModule { param($i) Get-WtMemoEditorText $script:panes[$i].Editor } $Pane }

    $mA = New-WtMemo; $mA.id = 'ma'; $mA.title = 'Alpha'; $mA.body = 'alpha body [[Beta]]'; $mA.updated = '2026-10-24 10:00:00'
    $mB = New-WtMemo; $mB.id = 'mb'; $mB.title = 'Beta'; $mB.body = 'beta body'; $mB.updated = '2026-10-23 10:00:00'
    $mC = New-WtMemo; $mC.id = 'mc'; $mC.title = 'Gamma'; $mC.body = 'has keyword zeta'; $mC.updated = '2026-10-22 10:00:00'
    Save-WtMemoItems @($mA, $mB, $mC)
    Set-WtSetting 'memo.tabs' $null
    Set-WtSetting 'memo.mode' 'edit'
    Show-TestView
    Assert-WtTest 'WPF 메모: 예전 memo.mode=edit는 편집(live)으로 연다' (& $memoModule { $script:mode -eq 'live' -and $script:panes[0].ViewButton.ToolTip -ceq '편집 보기 (Ctrl+E)' })
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 탭: 처음에는 최근 메모 하나를 탭으로 연다' ($s.Panes -eq 1 -and $s.Tabs[0] -eq 'ma' -and $s.Current[0] -eq 'ma')

    # ---- 목록 클릭 · Ctrl+클릭 · 가운데 클릭 ----
    & $memoModule { Select-WtMemoItem 'mb' }
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 탭: 목록 클릭은 지금 탭에서 연다' ($s.Tabs[0] -eq 'mb' -and $s.Current[0] -eq 'mb' -and (Get-TestBody 0) -eq 'beta body')
    Send-TestListClick 'mc' Left Control
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 탭: Ctrl+클릭은 새 탭에서 연다' ($s.Tabs[0] -eq 'mb,mc' -and $s.Current[0] -eq 'mc') "$($s.Tabs[0])"
    Send-TestListClick 'ma' Middle
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 탭: 가운데 클릭도 새 탭 · 목록 선택은 지금 탭을 따라간다' ($s.Tabs[0] -eq 'mb,mc,ma' -and $s.Current[0] -eq 'ma' -and (& $memoModule { $script:ui.List.SelectedItem.Id }) -eq 'ma')
    & $memoModule { Select-WtMemoItem 'mc' }
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 탭: 이미 열린 메모를 목록에서 고르면 그 탭으로 간다' ($s.Tabs[0] -eq 'mb,mc,ma' -and $s.Current[0] -eq 'mc')
    & $memoModule { Select-WtMemoItem 'ma' }

    # ---- 닫기 · 다시 열기 · 탭 돌기 ----
    Assert-WtTest 'WPF 메모 키: Ctrl+W 처리' (Send-TestKey W Control)
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 탭: Ctrl+W로 지금 탭을 닫으면 옆 탭으로' ($s.Tabs[0] -eq 'mb,mc' -and $s.Current[0] -eq 'mc')
    [void](Send-TestKey T 'Control, Shift')
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 탭: Ctrl+Shift+T로 닫은 탭을 다시 연다' ($s.Tabs[0] -eq 'mb,mc,ma' -and $s.Current[0] -eq 'ma')
    [void](Send-TestKey Tab Control)
    $first = (Get-TestTabs).Current[0]
    [void](Send-TestKey Tab 'Control, Shift')
    Assert-WtTest 'WPF 메모 탭: Ctrl+Tab은 끝에서 처음으로 돌고, Ctrl+Shift+Tab은 거꾸로' ($first -eq 'mb' -and (Get-TestTabs).Current[0] -eq 'ma')
    $kept = & $memoModule {
        $p = $script:panes[0]
        $null = Set-WtMemoEditorState $p.Editor @{ Line = 0; Col = 2; Scroll = 0 }
        $before = Get-WtMemoEditorState $p.Editor
        [void](Select-WtMemoTab $p $p.Tabs[0]); [void](Select-WtMemoTab $p $p.Tabs[2])
        $after = Get-WtMemoEditorState $p.Editor
        @($before.Line, $before.Col, $after.Line, $after.Col)
    }
    Assert-WtTest 'WPF 메모 탭: 탭을 오가도 편집기 커서(줄 · 칸)를 돌려놓는다' ($kept[1] -gt 0 -and $kept[0] -eq $kept[2] -and $kept[1] -eq $kept[3]) "$($kept -join ',')"
    $menuItems = & $memoModule { @($script:panes[0].Current.Button.ContextMenu.Items | ForEach-Object { "$($_.Header)|$($_.InputGestureText)" }) }
    Assert-WtTest 'WPF 메모 탭: 우클릭 메뉴(닫기 · 다른 탭 닫기 · 오른쪽에 나눠 열기)와 단축키 표시' (($menuItems -join ';') -eq '닫기|Ctrl+W;다른 탭 닫기|;오른쪽에 나눠 열기|Ctrl+\') ($menuItems -join ';')

    # ---- 나누기 · 같은 메모 두 칸 · 설정 복원 ----
    [void](Send-TestKey Oem5 Control)
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 칸: Ctrl+\로 지금 메모를 오른쪽 칸에 나눠 연다' ($s.Panes -eq 2 -and $s.Tabs[1] -eq 'ma' -and $s.Active -eq 1 -and (& $memoModule { $script:ui.Splitter.Visibility }) -eq 'Visible')
    $styles = & $memoModule { @($script:panes[0].Current.Style, $script:panes[1].Current.Style) -join ',' }
    Assert-WtTest 'WPF 메모 칸: 포커스가 있는 칸의 탭만 강조, 다른 칸은 덜 강조' ($styles -eq 'Memo.Tab.Selected,Memo.Tab.Current') $styles
    Set-TestBody 1 'synced text'
    $st0 = & $memoModule { $script:panes[0].Status }; $st1 = & $memoModule { $script:panes[1].Status }
    Assert-WtTest 'WPF 메모 칸: 저장 상태는 칸마다 (고친 칸만 저장 안 됨)' ((@(Get-WtTestTexts $st1) -contains '저장 안 됨') -and -not (@(Get-WtTestTexts $st0) -contains '저장 안 됨'))
    [void](Send-TestKey S Control)
    Assert-WtTest 'WPF 메모 칸: 같은 메모를 연 다른 칸은 저장한 글을 다시 불러온다' ((Get-TestBody 0) -eq 'synced text' -and ((Get-WtMemoItems) | Where-Object id -eq 'ma').body -eq 'synced text')
    & $memoModule { $script:ratio = 0.6; Save-WtMemoTabs }
    $saved = Get-WtSetting 'memo.tabs'
    Assert-WtTest 'WPF 메모 설정: 열린 탭 · 칸 · 지금 탭 · 비율을 남긴다' ((@($saved.panes[0].tabs) -join ',') -eq 'mb,mc,ma' -and (@($saved.panes[1].tabs) -join ',') -eq 'ma' -and $saved.active -eq 1 -and $saved.ratio -eq 0.6)
    Set-WtSetting 'memo.tabs' ([ordered]@{ panes = @([ordered]@{ tabs = @('mb', 'gone', 'mc'); current = 2 }, [ordered]@{ tabs = @('ma'); current = 0 }); active = 1; ratio = 0.6 })
    Initialize-WtSettings   # 파일에서 다시 읽는다 (앱을 다시 켠 것처럼)
    Show-TestView
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 설정: 다시 켜도 탭 · 칸 · 지금 탭이 그대로, 지워진 메모는 뺀다' ($s.Panes -eq 2 -and $s.Tabs[0] -eq 'mb,mc' -and $s.Current[0] -eq 'mc' -and $s.Tabs[1] -eq 'ma' -and $s.Active -eq 1 -and (& $memoModule { $script:ratio }) -eq 0.6) "$($s.Tabs -join ' | ') / $($s.Current -join ',') / $($s.Active)"

    # ---- 나눔 풀기 · 합치기 ----
    [void](Send-TestKey W Control)
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 칸: 둘째 칸의 마지막 탭을 닫으면 나눔을 푼다' ($s.Panes -eq 1 -and $s.Tabs[0] -eq 'mb,mc' -and $s.Active -eq 0 -and (& $memoModule { $script:ui.Splitter.Visibility }) -eq 'Collapsed')
    [void](Send-TestKey Oem5 Control)
    & $memoModule { $p = $script:panes[0]; foreach ($t in @($p.Tabs)) { [void](Close-WtMemoTab $p $t) } }
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 칸: 첫 칸이 비고 둘째 칸에 탭이 있으면 하나로 합친다' ($s.Panes -eq 1 -and $s.Tabs[0] -eq 'mc' -and $s.Current[0] -eq 'mc')
    & $memoModule { $p = $script:panes[0]; [void](Close-WtMemoTab $p $p.Current) }
    $empty = & $memoModule { $p = $script:panes[0]; $p.Empty.Visibility -eq 'Visible' -and $p.Head.Visibility -eq 'Collapsed' -and -not $p.More.IsEnabled }
    Assert-WtTest 'WPF 메모 칸: 탭이 없으면 빈 상태 안내 + 행동 버튼' $empty

    # ---- 지운 메모의 탭은 모든 칸에서 닫힌다 ----
    & $memoModule { [void](Open-WtMemo 'ma' 'tab'); [void](Open-WtMemo 'mb' 'tab') }
    $beforeUse = (@(Get-WtShortcuts -Max 200) | Where-Object { $_.Page -ceq 'memo' -and $_.Key -ceq 'ma' }).Count
    & (Get-WtAddon -Id memo).OnOpen @{ Key = 'ma' }
    Assert-WtTest '메모: 바로 가기 인자로 열기 · 연 횟수 한 번 · 옛 홈 카드 제거' ((& $memoModule { Get-WtMemoCurrentId }) -ceq 'ma' -and
        (@(Get-WtShortcuts -Max 200) | Where-Object { $_.Page -ceq 'memo' -and $_.Key -ceq 'ma' }).Count -eq $beforeUse + 1 -and -not (Get-WtAddon -Id memo).HomeCard)
    # 홈은 바로 가기 줄마다 부른다. memo.json이 그대로면 다시 읽지 않고, 다시 읽어도 저장 핸들이 낡지 않는다
    $shortcutCheck = & $memoModule {
        $a = @{ Have = Test-WtMemoShortcut 'ma'; None = Test-WtMemoShortcut '없는 메모' }
        $ids = $script:shortcutIds; [void](Test-WtMemoShortcut 'mb'); $a.Reused = [object]::ReferenceEquals($ids, $script:shortcutIds)
        $script:shortcutStamp = ''; [void](Test-WtMemoShortcut 'ma'); $a.Fresh = -not [object]::ReferenceEquals($ids, $script:shortcutIds)
        try { Save-WtMemoItems @($script:items); $a.Saved = $true } catch { $a.Saved = $false }
        $a
    }
    Assert-WtTest '메모 바로 가기: memo.json이 그대로면 다시 읽지 않고, 다시 읽어도 저장은 된다' ($shortcutCheck.Have -and -not $shortcutCheck.None -and $shortcutCheck.Reused -and $shortcutCheck.Fresh -and $shortcutCheck.Saved) "$($shortcutCheck.Have)/$($shortcutCheck.None)/$($shortcutCheck.Reused)/$($shortcutCheck.Fresh)/$($shortcutCheck.Saved)"
    & $memoModule {
        $m = $script:ui.List.ContextMenu; Set-WtMemoListMenu $m 'ma'
        @($m.Items | Where-Object { $_.Header -ceq '홈에 고정' })[0].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
        [void](Open-WtMemo 'mb')
    }
    Assert-WtTest '메모: 목록 홈 고정 메뉴' (Test-WtHomePin -Page memo -Key ma)
    Send-TestListClick 'mc' Right
    $menuState = & $memoModule { [pscustomobject]@{ MenuId = $script:listMenuId; Current = $script:panes[0].Current.Id } }
    & $memoModule { $script:listMenuId = ''; $m = $script:ui.List.ContextMenu; Set-WtMemoListMenu $m 'mb'; $m.Items[1].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent)) }
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 칸: 목록 우클릭은 선택을 바꾸지 않고, 메뉴 [오른쪽에 열기]는 오른쪽 칸에 연다' ($menuState.MenuId -eq 'mc' -and $menuState.Current -eq 'mb' -and $s.Panes -eq 2 -and $s.Tabs[1] -eq 'mb' -and $s.Tabs[0] -eq 'ma,mb') "$($menuState.MenuId) $($s.Tabs -join ' | ')"
    & $memoModule { Remove-WtMemoCurrent }
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 칸: 메모를 지우면 그 탭을 모든 칸에서 닫는다' ($s.Panes -eq 1 -and $s.Tabs[0] -eq 'ma' -and -not ((Get-WtMemoItems) | Where-Object id -eq 'mb') -and (& $memoModule { $script:ui.UndoBar.Visibility }) -eq 'Visible')
    Wait-WtTestWrites
    Assert-WtTest '메모 바로 가기: 지운 메모는 곧바로 없는 것으로 본다' (-not (& $memoModule { Test-WtMemoShortcut 'mb' }))
    & $memoModule { Restore-WtMemoDeleted }
    Wait-WtTestWrites
    Assert-WtTest '메모 바로 가기: 되살린 메모는 다시 있는 것으로 본다' (& $memoModule { Test-WtMemoShortcut 'mb' })
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모: 삭제 실행 취소는 메모를 되살려 새 탭으로 연다' ($s.Tabs[0] -eq 'ma,mb' -and $s.Current[0] -eq 'mb' -and ((Get-WtMemoItems) | Where-Object id -eq 'mb'))

    # ---- 빠른 이동 · 뒤로/앞으로 ----
    & $memoModule { $p = $script:panes[0]; [void](Select-WtMemoTab $p $p.Tabs[0]) }   # ma
    [void](Send-TestKey O Control)
    $quickBox = & $memoModule { $script:ui.Quick.Box }
    Assert-WtTest 'WPF 메모 빠른 이동: Ctrl+O로 연다' (& $memoModule { $script:quickOpen -and $script:ui.Quick.Host.Visibility -eq 'Visible' })
    $quickBox.Text = 'ta'
    $rows = & $memoModule { @($script:ui.Quick.List.Items | ForEach-Object { if ($_.Create) { '+' } else { $_.Id } }) }
    Assert-WtTest 'WPF 메모 빠른 이동: 제목이 맞는 메모가 위, 본문만 맞는 메모가 아래, 마지막 줄은 새 메모 만들기' (($rows -join ',') -eq 'mb,mc,+') ($rows -join ',')
    [void](Send-TestKey Enter)
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 빠른 이동: Enter는 지금 탭에서 연다' (-not (& $memoModule { $script:quickOpen }) -and $s.Current[0] -eq 'mb' -and $s.Tabs[0] -eq 'ma,mb')
    [void](Send-TestKey O Control); $quickBox.Text = 'gamma'
    $rows = & $memoModule { @($script:ui.Quick.List.Items | ForEach-Object { if ($_.Create) { '+' } else { $_.Id } }) }
    Assert-WtTest 'WPF 메모 빠른 이동: 같은 제목이 있으면 새 메모 줄은 없다' (($rows -join ',') -eq 'mc') ($rows -join ',')
    [void](Send-TestKey Enter Control)
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 빠른 이동: Ctrl+Enter는 새 탭' ($s.Tabs[0] -eq 'ma,mb,mc' -and $s.Current[0] -eq 'mc')
    [void](Send-TestKey O Control); [void](Send-TestKey Escape)
    Assert-WtTest 'WPF 메모 빠른 이동: Esc로 닫는다' (-not (& $memoModule { $script:quickOpen }) -and (& $memoModule { $script:ui.Quick.Host.Visibility }) -eq 'Collapsed')
    [void](Send-TestKey O Control); $quickBox.Text = '퀵으로 만든 메모'; [void](Send-TestKey Enter)
    $made = (Get-WtMemoItems) | Where-Object title -eq '퀵으로 만든 메모'
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 빠른 이동: 맞는 메모가 없으면 그 이름으로 새 메모를 만들어 연다' ($made -and $s.Current[0] -eq $made.id -and $s.Tabs[0] -eq "ma,mb,$($made.id)")
    Assert-WtTest 'WPF 메모 키: Alt+← 처리' (Send-TestKey Left Alt)
    Assert-WtTest 'WPF 메모 뒤로: Alt+←로 빠른 이동 전 메모로 돌아간다' ((Get-TestTabs).Current[0] -eq 'mc')
    [void](Send-TestKey Right Alt)
    Assert-WtTest 'WPF 메모 앞으로: Alt+→' ((Get-TestTabs).Current[0] -eq $made.id)
    & $memoModule { $p = $script:panes[0]; [void](Select-WtMemoTab $p $p.Tabs[1]) }   # mb
    & $memoModule { Select-WtMemoItem 'mc' }   # 목록 클릭은 기록에 쌓지 않는다
    [void](Send-TestKey Left Alt)
    Assert-WtTest 'WPF 메모 뒤로: 목록 클릭은 뒤로 기록에 쌓지 않는다' ((Get-TestTabs).Current[0] -eq 'mc')

    # ---- 링크 ----
    $handled = & $memoModule { $p = $script:panes[0]; Invoke-WtMemoLink $p.Editor @{ Kind = 'wiki'; Target = '위키로 만든 메모'; Text = '' } 'here' }
    $wikiMade = (Get-WtMemoItems) | Where-Object title -eq '위키로 만든 메모'
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 링크: 같은 제목이 없는 [[위키 링크]]는 그 제목으로 새 메모를 만들어 지금 탭에서 연다' ($handled -eq $true -and $wikiMade -and $s.Current[0] -eq $wikiMade.id)
    [void](Send-TestKey Left Alt)
    Assert-WtTest 'WPF 메모 링크: 링크로 간 뒤 Alt+←로 돌아온다' ((Get-TestTabs).Current[0] -eq 'mc')
    [void](& $memoModule { $p = $script:panes[0]; Invoke-WtMemoLink $p.Editor @{ Kind = 'wiki'; Target = 'alpha#소제목'; Text = '' } 'side' })
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 링크: Ctrl+Alt 클릭(side)은 다른 칸에 연다 (#제목은 떼고 제목 대소문자 무시)' ($s.Panes -eq 2 -and $s.Tabs[1] -eq 'ma' -and $s.Active -eq 1)
    [void](& $memoModule { Invoke-WtMemoLink $null @{ Kind = 'tag'; Target = '서버'; Text = '' } 'here' })
    Assert-WtTest 'WPF 메모 링크: #태그는 목록 검색으로' ((& $memoModule { $script:ui.Search.Text }) -eq '#서버')
    $titles = @(& $memoModule { $p = $script:panes[0]; & $p.Editor.OnTitles $p.Editor '' })
    Assert-WtTest 'WPF 메모 링크: [[ 자동 완성 후보는 메모 제목 (최근 고친 순)' ($titles.Count -eq (Get-WtMemoItems).Count -and $titles[0] -eq (@(Get-WtMemoSorted (Get-WtMemoItems))[0]).title)
    & $memoModule { $script:ui.Search.Text = '' }

    # ---- 모드 ----
    [void](Send-TestKey E Control)
    $srcOk = & $memoModule { $script:mode -eq 'source' -and (Get-WtMemoActivePane).ViewButton.ToolTip -ceq '원문 보기 (Ctrl+E)' }
    [void](Send-TestKey E Control)
    $readOk = & $memoModule { $p = Get-WtMemoActivePane; $script:mode -eq 'read' -and $p.TitleText.Visibility -eq 'Visible' -and $p.TitleBox.Visibility -eq 'Collapsed' -and $p.ViewButton.ToolTip -ceq '읽기 보기 (Ctrl+E)' }
    [void](Send-TestKey E Control)
    $srcOk = $srcOk -and (& $memoModule { $script:mode -eq 'live' })
    [void](Send-TestKey Oem2 Control)
    Assert-WtTest 'WPF 메모 보기: Ctrl+E 편집 → 원문 → 읽기 → 편집, Ctrl+/ 원문, 설정에 live · source · read로 남긴다' ($readOk -and $srcOk -and (& $memoModule { $script:mode }) -eq 'source' -and (Get-WtSetting 'memo.mode') -eq 'source')
    [void](Send-TestKey Oem2 Control)

    # ---- 새 메모 → 입력 → 저장 → 삭제 → 실행 취소 · 끝낼 때 저장 ----
    & $memoModule { $p = $script:panes[1]; foreach ($t in @($p.Tabs)) { [void](Close-WtMemoTab $p $t) } }   # 둘째 칸을 닫아 첫 칸만 쓴다
    $before = (Get-WtMemoItems).Count
    [void](Send-TestKey N Control)
    & $memoModule { $script:panes[0].TitleBox.Text = '새 제목' }
    Set-TestBody 0 '본문 #새태그'
    Start-Sleep -Milliseconds 1100   # 수정일은 초 단위다. 앞 메모와 같은 초면 제목 순서가 된다
    [void](& $memoModule { Save-WtMemoNow })
    $saved = Get-WtMemoItems
    $new = $saved | Where-Object title -eq '새 제목'
    Assert-WtTest 'WPF 메모: Ctrl+N 새 메모(새 탭)를 쓰고 저장' ($saved.Count -eq $before + 1 -and $new.body -eq '본문 #새태그' -and @($new.tags)[0] -eq '새태그' -and (Get-TestTabs).Current[0] -eq $new.id)
    Wait-WtTestWrites
    $st0 = & $memoModule { $script:panes[0].Status }
    Assert-WtTest 'WPF 메모: 저장 상태 표시 · 탭 제목 · 목록 맨 위' (@(Get-WtTestTexts $st0 | Where-Object { $_ -like '저장됨*' }).Count -eq 1 -and (& $memoModule { $script:panes[0].Current.Text.Text }) -eq '새 제목' -and (& $memoModule { [string]$script:ui.List.Items[0].Id }) -eq $new.id)
    Set-TestBody 0 '고치는 중'
    & $memoModule { $script:testStatus = $script:panes[0].Status.Content }
    Set-TestBody 0 '고치는 중 2'
    Assert-WtTest 'WPF 메모: 연속 입력은 상태 요소 재사용 · 자동 저장 예약 유지' (& $memoModule { [object]::ReferenceEquals($script:testStatus, $script:panes[0].Status.Content) -and $script:saveTimer.IsEnabled })
    & $addon.OnExit
    Assert-WtTest 'WPF 메모: 끝내기 전에 저장' (((Get-WtMemoItems) | Where-Object id -eq $new.id).body -eq '고치는 중 2')

    # ---- 저장 실패: 작성 중인 글을 버리지 않는다 ----
    $one = New-WtMemo; $one.title = 'A'; $one.body = 'saved A'
    $two = New-WtMemo; $two.title = 'B'; $two.body = 'saved B'
    Save-WtMemoItems @($one, $two)
    Set-WtSetting 'memo.tabs' $null
    Show-TestView
    & $memoModule { param($id) Select-WtMemoItem $id } $one.id
    & $memoModule { param($id) [void](Open-WtMemo $id 'tab') } $two.id
    & $memoModule { param($id) $p = $script:panes[0]; [void](Select-WtMemoTab $p $p.Tabs[0]) } $one.id
    Set-TestBody 0 'unsaved draft'
    # UI 오류창 · 확인창만 바꾼다. 저장 · 전환 로직은 실제 함수를 실행한다. 확인창의 대답은 차례로 정해 두고, 없으면 [취소]
    & $memoModule { function script:Show-WtError { param($ErrorRecord, $Action) $script:lastTestError = $Action } }
    & $shellModule {
        function script:Show-WtMessage { param($Text, $Title, $Kind) }
        function script:Show-WtError { param($ErrorRecord, $Action) }
        $script:testChoices = [System.Collections.Generic.Queue[string]]::new(); $script:testAsked = @()
        function script:Show-WtPendingChoice { param($Purpose, $Title) $script:testAsked += $Purpose; if ($script:testChoices.Count) { $script:testChoices.Dequeue() } else { 'cancel' } }
    }
    $memoPath = Get-WtStorePath 'memo'
    $original = [System.IO.File]::ReadAllText($memoPath)
    # 저장 모듈의 알림 창만 바꾼다 (몇 번 알렸는지 센다). 저장 통로 · 버전은 그대로 돈다
    $storage = Get-Module Storage
    & $storage { $script:testTold = [System.Collections.Generic.List[string]]::new(); function script:Show-WtMessage { param($Text, $Title, $Icon) $script:testTold.Add($Text) } }
    $pump = { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) }
    $settle = { param($ms) $w = [System.Diagnostics.Stopwatch]::StartNew(); while ($w.ElapsedMilliseconds -lt $ms) { Update-WtWork; & $pump; Start-Sleep -Milliseconds 20 } }
    $held = [System.IO.File]::Open($memoPath, 'Open', 'Read', 'Read')
    $savedNow = & $memoModule { Save-WtMemoNow }
    & $pump
    $st0 = & $memoModule { $script:panes[0].Status }
    Assert-WtTest '메모 안정성: 잠긴 파일에 저장하지 못해도 그 내용은 앱이 가지고 있고(다시 읽어도 보임), 그 칸에 실패가 보이고 한 번 알린다' (
        $savedNow -and -not (& $memoModule { $script:panes[0].Dirty }) -and @(Get-WtTestTexts $st0 | Where-Object { $_ -like '저장하지 못했습니다*' }).Count -eq 1 -and
        ((Get-WtMemoItems) | Where-Object id -eq $one.id).body -eq 'unsaved draft' -and (& $storage { $script:testTold.Count }) -eq 1) "($(@(Get-WtTestTexts $st0) -join ' '))"
    Set-TestBody 0 'unsaved draft 2'
    Assert-WtTest '메모 안정성: 저장 오류 뒤 다시 입력하면 저장 안 됨 표시' (@(Get-WtTestTexts $st0) -contains '저장 안 됨')
    [void](& $memoModule { Save-WtMemoNow })
    & $pump
    & $memoModule { Update-WtMemoView }
    Assert-WtTest '메모 안정성: 또 실패해도 다시 알리지 않고, 새로 고쳐도 고친 본문이 그대로 보인다' ((Get-TestBody 0) -eq 'unsaved draft 2' -and (& $storage { $script:testTold.Count }) -eq 1)
    & $memoModule { param($id) Select-WtMemoItem $id } $two.id
    $moved = (Get-TestTabs).Current[0] -eq $two.id
    & $memoModule { param($id) Select-WtMemoItem $id } $one.id
    Assert-WtTest '메모 안정성: 저장하지 못해도 다른 메모로 옮길 수 있고, 돌아오면 고친 본문이 그대로다' ($moved -and (Get-TestBody 0) -eq 'unsaved draft 2')

    # 셸과 맞물리는 곳: 저장하지 못한 내용이 있으면 셸이 끝내기 전에 묻는다 (묻는 흐름 자체는 tests\Test-Reliability.ps1)
    $asked = & $shellModule { $script:testAsked = @(); $script:writingDropped = $false; [void](Save-WtPendingChanges -Purpose exit); [void](Confirm-WtDataWrites); $script:testAsked -join ',' }
    Assert-WtTest '메모 안정성: 저장하지 못한 내용이 있으면 셸이 끝내기 전에 묻는다' ($asked -eq 'exit') $asked
    Assert-WtTest '메모 안정성: 저장 실패로 원본 파일을 바꾸지 않는다' ([System.IO.File]::ReadAllText($memoPath) -ceq $original)

    $held.Dispose(); $held = $null
    [void](Send-TestKey S Control)
    & $settle 600
    Assert-WtTest '메모 안정성: 잠금이 풀린 뒤 Ctrl+S가 가지고 있던 내용을 다시 써서 저장한다' (
        ([System.IO.File]::ReadAllText($memoPath) -match 'unsaved draft 2') -and @(Get-WtTestTexts $st0 | Where-Object { $_ -like '저장됨*' }).Count -eq 1 -and -not @(Get-WtDataUnsaved).Count)
    Assert-WtTest '메모 안정성: 재시도한 본문을 다시 읽을 수 있다' (((Get-WtMemoItems) | Where-Object id -eq $one.id).body -eq 'unsaved draft 2')
    & $memoModule { $script:ui.Search.Text = '' }
    Set-TestBody 0 'next draft'
    & $memoModule { param($id) Select-WtMemoItem $id } $two.id
    Assert-WtTest '메모 안정성: 자동 저장 뒤 목록 선택과 편집기 메모가 일치한다' ((Get-TestTabs).Current[0] -eq $two.id -and (& $memoModule { $script:ui.List.SelectedItem.Id }) -eq $two.id -and ((Get-WtMemoItems) | Where-Object id -eq $one.id).body -eq 'next draft')
    & $memoModule { param($id) Select-WtMemoItem $id } $one.id

    # 데이터 폴더가 늦게 답하는 저장. 실제 쓰기(Write-WtDataFile) 앞에 기다림만 끼운다. 저장 통로 · 버전 · 칸 표시는 그대로 돈다
    # 저장 표시는 시간이 아니라 「받아들인 내용이 파일에 쓰였는지」로 정한다: 쓰는 중이면 「저장하는 중」, 쓰이면 「저장됨」
    $storage = Get-Module Storage
    $pump = { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle) }
    $settle = { param($ms) $w = [System.Diagnostics.Stopwatch]::StartNew(); while ($w.ElapsedMilliseconds -lt $ms) { Update-WtWork; & $pump; Start-Sleep -Milliseconds 20 } }
    & $storage { $script:testJob = $script:writeJob }
    $gate = New-WtTestGate
    try {
        & $storage { $script:writeJob = { param($p, $json) [void][AppDomain]::CurrentDomain.GetData('WtTestGate').Gate.WaitOne(); Write-WtDataFile $p $json } }
        Set-TestBody 0 'slow draft'
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $saveProcess = [Diagnostics.Process]::GetCurrentProcess(); $saveCpu = $saveProcess.TotalProcessorTime
        $savedNow = & $memoModule { Save-WtMemoNow }
        $saveWallMs = $watch.ElapsedMilliseconds
        $saveProcess.Refresh(); $saveMs = ($saveProcess.TotalProcessorTime - $saveCpu).TotalMilliseconds
        $writingTexts = @(Get-WtTestTexts $st0)
        $dirtyAfter = & $memoModule { $script:panes[0].Dirty }
        [void]$gate.Gate.Set()
        & $settle 1000
        Assert-WtTest "메모 안정성: 저장이 늦으면 잠깐만 기다리고(벽 ${saveWallMs}ms / CPU ${saveMs}ms) 「저장하는 중」, 파일에 쓰이면 「저장됨」 (다시 저장하지 않는다)" (
            $savedNow -and $saveMs -lt 1500 -and -not $dirtyAfter -and @($writingTexts | Where-Object { $_ -like '저장하는 중*' }).Count -eq 1 -and
            @(Get-WtTestTexts $st0 | Where-Object { $_ -like '저장됨*' }).Count -eq 1 -and ([System.IO.File]::ReadAllText($memoPath) -match 'slow draft')) ($writingTexts -join ' / ')
    } finally {
        & $storage { $script:writeJob = $script:testJob }
        Remove-WtTestGate $gate
    }
    # 모든 쓰기가 0.6초씩 걸리고 성공하는 폴더: 화면이 기다리는 시간(0.4초)보다 길어도 한 번 쓰면 「저장됨」이고, 같은 내용을 되풀이해 쓰지 않는다
    $slowWrites = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
    [AppDomain]::CurrentDomain.SetData('WtTestWrites', $slowWrites)
    try {
        & $storage { $script:writeJob = { param($p, $json) [System.Threading.Thread]::Sleep(600); [void][AppDomain]::CurrentDomain.GetData('WtTestWrites').Add($p); Write-WtDataFile $p $json } }
        Set-TestBody 0 'slow draft 2'
        [void](& $memoModule { Save-WtMemoNow })
        & $settle 2500
        $memoWrites = @($slowWrites | Where-Object { $_ -ieq $memoPath }).Count
        Assert-WtTest '메모 안정성: 모든 쓰기가 0.6초씩 걸려도 한 번 쓰면 「저장됨」이고 되풀이해 쓰지 않는다' (
            $memoWrites -eq 1 -and -not (& $memoModule { $script:panes[0].Dirty }) -and @(Get-WtTestTexts $st0 | Where-Object { $_ -like '저장됨*' }).Count -eq 1 -and
            ([System.IO.File]::ReadAllText($memoPath) -match 'slow draft 2')) "(memo 쓰기 ${memoWrites}번 · $(@(Get-WtTestTexts $st0) -join ' '))"
    } finally {
        & $storage { $script:writeJob = $script:testJob }
        [AppDomain]::CurrentDomain.SetData('WtTestWrites', $null)
    }
    # 고친 칸이 없을 때 메모 추가 → 저장이 늦어 화면은 넘어감 → 나중에 실패. 그 내용은 앱이 가지고 있다:
    # 다시 읽어도 보이고, 칸에 실패가 보이며, 끝내기 전에 묻고, Ctrl+S가 다시 쓴다
    $gate = New-WtTestGate
    try {
        & $storage {
            function script:Show-WtMessage { param($Text, $Title, $Icon) }
            $script:writeJob = { param($p, $json) [void][AppDomain]::CurrentDomain.GetData('WtTestGate').Gate.WaitOne(); throw [System.IO.IOException]::new('검사용 늦은 실패') }
        }
        $added = & $memoModule { Add-WtMemo '늦게 실패할 메모' }
        [void]$gate.Gate.Set()
        & $settle 800
        & $storage { $script:writeJob = $script:testJob }
        $readBack = @(Get-WtMemoItems | Where-Object { $_.title -eq '늦게 실패할 메모' }).Count
        $failText = @(& $memoModule { Get-WtTestTexts $script:panes[0].Status }) -join ' '
        Assert-WtTest '메모 안정성: 고친 칸 없이 추가한 메모가 늦게 실패해도 앱이 가지고 있고(다시 읽어도 보임) 실패가 보인다' (
            [bool]$added -and $readBack -eq 1 -and $failText -like '*저장하지 못했습니다*' -and -not ([System.IO.File]::ReadAllText($memoPath) -match '늦게 실패할 메모')) $failText
        $stay = & $shellModule { $script:writingDropped = $false; $script:testAsked = @(); -not (Confirm-WtDataWrites) -and ($script:testAsked -join ',') -eq 'exit' }
        Assert-WtTest '메모 안정성: 그 내용이 있으면 끝내기 전에 묻는다 ([취소]면 머문다)' $stay
        [void](Send-TestKey S Control)
        & $settle 800
        Assert-WtTest '메모 안정성: Ctrl+S가 가지고 있던 내용을 다시 써서 파일에 남기고 「저장됨」이 된다' (
            ([System.IO.File]::ReadAllText($memoPath) -match '늦게 실패할 메모') -and @(& $memoModule { Get-WtTestTexts $script:panes[0].Status } | Where-Object { $_ -like '저장됨*' }).Count -eq 1)
        & $memoModule { Remove-WtMemoCurrent }   # 아래 검사가 메모 두 개로 시작하게
    } finally {
        & $storage { $script:writeJob = $script:testJob }
        Remove-WtTestGate $gate
    }
    # 저장하지 못해도 삭제 · 실행 취소는 화면과 앱이 가진 내용이 같다. 실행 취소를 두 번 해도 중복 항목을 만들지 않는다
    $before = & $memoModule { $script:items.Count }
    $held = [System.IO.File]::Open($memoPath, 'Open', 'Read', 'Read')
    & $memoModule { Remove-WtMemoCurrent; Restore-WtMemoDeleted; Restore-WtMemoDeleted }
    $mem = @(& $memoModule { $script:items | ForEach-Object { [string]$_.id } })
    $read = @((Get-WtMemoItems).id | ForEach-Object { [string]$_ })
    Assert-WtTest '메모 안정성: 저장하지 못해도 삭제 · 실행 취소 결과가 다시 읽은 내용과 같고, 실행 취소를 두 번 해도 중복 항목을 만들지 않는다' (
        $mem.Count -eq $before -and (($mem | Sort-Object) -join ',') -eq (($read | Sort-Object) -join ',') -and @($mem | Sort-Object -Unique).Count -eq $before) "($($mem -join ',') / $($read -join ','))"
    $held.Dispose(); $held = $null
    [void](Send-TestKey S Control)
    & $settle 600
    Assert-WtTest '메모 안정성: 다시 쓴 뒤 파일도 같고 ID가 모두 고유하다' ((Get-WtMemoItems).Count -eq $before -and @((Get-WtMemoItems).id | Sort-Object -Unique).Count -eq $before -and -not @(Get-WtDataUnsaved).Count) "($((Get-WtMemoItems).Count)/$before · 못 쓴 내용 $(@(Get-WtDataUnsaved).Count) $(@(Get-WtDataUnsaved) | ConvertTo-Json -Compress -Depth 2))"

    # ---- 목록 · 조건 · 보기 · 목차 ----
    Assert-WtTest '메모 화면: 목록 카드 280 · 목차 카드 220 · 보기 단추 하나' (& $memoModule { $script:ui.ListPanel.Width -eq 280 -and $script:ui.TocPanel.Width -eq 220 -and $script:panes[0].ViewButton -and -not $script:ui.ContainsKey('ModeButtons') })
    $side = & $memoModule { $p = $script:panes[0]; foreach ($w in 1000, 500, 300) { Update-WtMemoPaneSide $p $w; $p.Head.Margin.Left } }
    Assert-WtTest '메모 화면: 글 폭 680 가운데 · 좁으면 여백 44 · 아주 좁으면 20' (($side -join ',') -ceq '160,44,20') ($side -join ',')
    $listMemos = @(foreach ($i in 1..95) { $m = New-WtMemo; [void](Set-WtMemoContent $m "목록 $i" "본문 $i" ([datetime]'2026-10-01').AddMinutes($i)); $m.id = "list$i"; $m })
    $tocMemo = New-WtMemo; [void](Set-WtMemoContent $tocMemo '복구 절차' "# 복구 절차`n`n## 준비`n`n내용`n`n### 세부`n`n## 실행`n`n내용 #장애" ([datetime]'2026-10-20')); $tocMemo.id = 'toc'
    Save-WtMemoItems (@($tocMemo) + $listMemos)
    & $memoModule { $script:viewStamp = $null; $script:listRows = $null; Update-WtMemoView }
    $paged = & $memoModule { Clear-WtMemoFilter; $a = @{ Count = $script:listResult.Count; Rows = $script:listRows.Count }; Add-WtMemoListPage; $a.More = $script:listRows.Count; Select-WtMemoItem 'list1'; $a.Until = @($script:listRows | Where-Object Id -ceq 'list1').Count; $a }
    Assert-WtTest '메모 목록: 40줄씩 만들고 스크롤 · 고르기로 이어 만든다' ($paged.Count -eq 96 -and $paged.Rows -eq 40 -and $paged.More -eq 80 -and $paged.Until -eq 1) "$($paged.Count)/$($paged.Rows)/$($paged.More)/$($paged.Until)"
    $first = & $memoModule { $i = Get-WtMemoIndex; $all = @((Find-WtMemo -Index $i).Items.Id); $part = Find-WtMemo -Index $i -First 3; $next = @(Get-WtMemoResultRows -Result $part -Skip 3 -First 3); @{ Same = ((@($part.Items.Id) + @($next.Id)) -join ',') -ceq (@($all[0..5]) -join ','); Count = $part.Count; Snippet = [bool]$next[0].Snippet } }
    Assert-WtTest '메모 검색: 앞줄만 만들어도 뒤를 같은 순서 · 미리보기로 이어 받는다' ($first.Same -and $first.Count -eq 96 -and $first.Snippet)
    $fresh = & $memoModule { $script:memoIndex = $null; Start-WtMemoIndexBuild; $script:indexTimer.Stop(); Update-WtMemoList; $a = @{ NoIndex = $null -eq $script:memoIndex -and $null -eq $script:listResult.Find; Rows = $script:listRows.Count }; Set-WtMemoSearch '복구'; $a.Built = $null -ne $script:memoIndex -and $null -eq $script:indexBuild; $a.Found = @($script:listRows.Id) -join ','; $a }
    Assert-WtTest '메모 색인: 첫 목록은 색인을 기다리지 않고, 찾으면 남은 색인을 끝낸다' ($fresh.NoIndex -and $fresh.Rows -gt 0 -and $fresh.Built -and $fresh.Found -ceq 'toc') "$($fresh.Found)"
    # 연결 조건은 해석이 끝나야 답한다. 끝나지 않았으면 화면을 세우지 않고 앞 결과를 둔 뒤, 끝나면 다시 그린다
    $wait = & $memoModule {
        $script:memoIndex = $null; Start-WtMemoIndexBuild; $script:indexTimer.Stop(); [void](Get-WtMemoIndex); $script:linkTimer.Stop()
        $keep = $script:linkWaitMs; $script:linkWaitMs = 0
        Set-WtMemoSearch '복구'
        $before = @($script:listRows.Id) -join ','
        Set-WtMemoSearch 'has:backlink'
        $a = @{ Waiting = $script:listWaitLinks; Note = [string]$script:ui.ListNote.Text; Tip = [string]$script:ui.ListNote.ToolTip; Same = (@($script:listRows.Id) -join ',') -ceq $before; Ready = $script:memoIndex.LinksReady }
        $script:linkWaitMs = $keep
        $script:linkTimer.Start()
        $timer = $script:linkTimer
        $guard = [Diagnostics.Stopwatch]::StartNew()
        # 타이머가 가장 낮은 우선순위라 같은 우선순위로 기다려야 돌 틈이 생긴다
        while ($timer.IsEnabled -and $guard.Elapsed.TotalSeconds -lt 20) { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] { }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle); Start-Sleep -Milliseconds 5 }
        $a.After = $script:memoIndex.LinksReady -and -not $script:listWaitLinks -and $script:ui.ListNote.Visibility -eq 'Collapsed'
        Clear-WtMemoFilter
        $a
    }
    Assert-WtTest '메모 연결: 연결 조건은 화면을 세우지 않고 기다렸다가, 해석이 끝나면 결과를 그린다' ($wait.Waiting -and $wait.Same -and -not $wait.Ready -and $wait.Note -ceq '이전 조건 결과' -and $wait.Tip -like '연결을 정리하는 중*' -and $wait.After) "$($wait.Waiting)/$($wait.Same)/$($wait.Ready)/$($wait.Note)/$($wait.After)"
    $kept = & $memoModule { Set-WtMemoSearch '목록'; $a = @{ Find = $null -ne $script:listResult.Find }; Add-WtMemoListPage; $a.Before = $script:listRows.Count; $rows = $script:listRows; Update-WtMemoList; $a.After = $script:listRows.Count; $a.Same = [object]::ReferenceEquals($rows, $script:listRows); Clear-WtMemoFilter; $a }
    Assert-WtTest '메모 목록: 스크롤로 만든 줄은 저장 뒤 다시 그려도 그대로다 (찾기 결과)' ($kept.Find -and $kept.Before -eq 80 -and $kept.After -eq 80 -and $kept.Same) "$($kept.Before)/$($kept.After)/$($kept.Same)"
    $chips = & $memoModule { Set-WtMemoSearch '#장애 복구'; Move-WtMemoQueryToChips; $a = @{ Labels = @($script:listChips.Label) -join ','; Box = [string]$script:ui.Search.Text; Count = $script:listResult.Count; Shown = $script:ui.Chips.Children.Count }; $script:listChips.RemoveAt(0); Update-WtMemoList; $a.After = $script:ui.Chips.Visibility; Clear-WtMemoFilter; $a }
    Assert-WtTest '메모 조건: Enter는 조건을 칩으로 옮기고 낱말은 검색창에 남긴다 · 칩을 지우면 빠진다' ($chips.Labels -ceq '#장애' -and $chips.Box -ceq '복구' -and $chips.Count -eq 1 -and $chips.Shown -eq 1 -and $chips.After -eq 'Collapsed') "$($chips.Labels) / $($chips.Box)"
    $labels = & $memoModule {
        foreach ($q in '-tag:"초안"', 'folder:"절차"', 'updated:7d', 'is:pinned', 'no:tag', 'has:backlink') { Add-WtMemoChip $q '' }
        @($script:listChips.Label) -join ','; $script:listChips.Clear()
    }
    Assert-WtTest '메모 조건: 칩은 읽기 쉬운 이름으로 보인다' ($labels -ceq '제외: #초안,폴더: 절차,수정일: 최근 7일,고정,태그 없음,받은 연결 있음') $labels
    $broken = & $memoModule { Set-WtMemoSearch '복구'; $before = @($script:listRows.Id) -join ','; Set-WtMemoSearch 'title:'; $a = @{ Note = $script:ui.ListNote.Text; Shown = $script:ui.ListNote.Visibility; Same = (@($script:listRows.Id) -join ',') -ceq $before; Tip = [string]$script:ui.ListNote.ToolTip }; Set-WtMemoSearch '없는낱말'; $a.Empty = $script:ui.ListEmpty.Visibility; Clear-WtMemoFilter; $a.Back = $script:ui.ListEmpty.Visibility; $a.Count = $script:listResult.Count; $a }
    Assert-WtTest '메모 조건: 쓰는 중인 틀린 식은 앞 결과를 두고 알린다 · 0건은 조건 지우기' ($broken.Note -ceq '이전 조건 결과' -and $broken.Shown -eq 'Visible' -and $broken.Same -and $broken.Tip -and $broken.Empty -eq 'Visible' -and $broken.Back -eq 'Collapsed' -and $broken.Count -eq 96)
    $actions = & $memoModule {
        Invoke-WtMemoAction archive 'toc' $true
        $a = @{ Normal = $script:listResult.Count }
        $script:listView = 'archived'; Update-WtMemoList
        $a.Archived = @($script:listRows.Id) -join ','
        Clear-WtMemoFilter; Invoke-WtMemoAction archive 'toc' $false
        Invoke-WtMemoAction pin 'list1' $true
        $a.Pinned = $script:listRows[0].Id; $a.Pin = $script:listRows[0].PinShown
        Invoke-WtMemoAction pin 'list1' $false
        Invoke-WtMemoAction folder 'list2' 'work'
        Set-WtMemoSearch 'folder:업무'
        $a.Folder = @($script:listRows.Id) -join ','
        Clear-WtMemoFilter; $script:listSort = 'title'; $script:listDir = 'desc'; Update-WtMemoList
        $a.Sorted = $script:listRows[0].Title
        Clear-WtMemoFilter; $a
    }
    Assert-WtTest '메모 정리: 보관 · 고정 · 폴더 · 정렬이 목록에 바로 보인다' ($actions.Normal -eq 95 -and $actions.Archived -ceq 'toc' -and $actions.Pinned -ceq 'list1' -and $actions.Pin -eq 'Visible' -and $actions.Folder -ceq 'list2' -and $actions.Sorted -ceq '복구 절차') ($actions | ConvertTo-Json -Compress)
    $saved = & $memoModule {
        Set-WtMemoSearch '#장애'; Move-WtMemoQueryToChips; Save-WtMemoCurrentView '장애 보기'
        $a = @{ Label = $script:ui.ViewLabel.Text }
        Set-WtMemoSearch '복구'
        $a.Changed = $script:ui.ViewLabel.Text
        Clear-WtMemoFilter; $a.Plain = $script:ui.ViewLabel.Text
        Use-WtMemoSavedView @(Get-WtMemoViews | Where-Object name -ceq '장애 보기')[0]
        $a.Chips = @($script:listChips.Label) -join ','; $a.Count = $script:listResult.Count; $a.Back = $script:ui.ViewLabel.Text
        Set-WtMemoViewMenu $script:ui.ViewPick.ContextMenu
        $a.Menu = @($script:ui.ViewPick.ContextMenu.Items | ForEach-Object Header) -join '|'
        Clear-WtMemoFilter; $a
    }
    Assert-WtTest '메모 보기: 저장한 보기 · 변경됨 표시 · 다시 불러오기 · 메뉴' ($saved.Label -ceq '장애 보기' -and $saved.Changed -ceq '장애 보기 · 변경됨' -and $saved.Plain -ceq '일반' -and $saved.Chips -ceq '#장애' -and $saved.Count -eq 1 -and $saved.Back -ceq '장애 보기' -and
        $saved.Menu -like '*✓ 장애 보기*보기 업데이트*이 보기 삭제*새 보기로 저장...') ($saved | ConvertTo-Json -Compress)
    $menus = & $memoModule {
        Set-WtMemoFilterMenu $script:ui.FilterButton.ContextMenu; Set-WtMemoSortMenu $script:ui.SortButton.ContextMenu
        Set-WtMemoListMenu $script:ui.List.ContextMenu 'toc'
        @{ Filter = @($script:ui.FilterButton.ContextMenu.Items | ForEach-Object Header) -join '|'; Sort = @($script:ui.SortButton.ContextMenu.Items | ForEach-Object Header) -join '|'; List = @($script:ui.List.ContextMenu.Items | ForEach-Object Header) -join '|' }
    }
    Assert-WtTest '메모 메뉴: 조건 · 정렬 · 목록 우클릭 항목' ($menus.Filter -like '수정일|오늘|최근 7일|최근 30일|상태|고정|*#장애*' -and $menus.Sort -ceq '✓ 기본|수정일|생성일|제목|최근 열기|받은 연결 수' -and
        $menus.List -like '새 탭에서 열기|오른쪽에 열기|홈에 고정|고정|보관|폴더로 옮기기|*삭제') ($menus | ConvertTo-Json -Compress)
    $toc = & $memoModule {
        [void](Open-WtMemo 'toc' 'tab')
        $p = Get-WtMemoActivePane
        Set-WtMemoMode 'live'
        $a = @{ Rows = @($script:ui.Toc.Items | ForEach-Object Text) -join ','; Lines = @($script:ui.Toc.Items | ForEach-Object Line) -join ',' }
        $null = Show-WtMemoEditorLine $p.Editor 8
        $a.Live = $p.Editor.Caret.Line
        Set-WtMemoMode 'read'; $null = Show-WtMemoEditorLine $p.Editor 8; $a.Read = $p.Editor.Caret.Line; $a.Block = $null -ne $p.Editor.View.Tag.HeadingBlocks[9]
        Set-WtMemoMode 'source'; $null = Show-WtMemoEditorLine $p.Editor 8
        $a.Source = $p.Editor.Source.CaretIndex -gt 0
        Set-WtMemoMode 'live'; $a
    }
    Assert-WtTest '메모 목차: 제목 + 소제목(같은 제목 H1은 뺀다) · 세 보기 모두 그 줄로 간다' ($toc.Rows -ceq '복구 절차,준비,세부,실행' -and $toc.Lines -ceq '-1,2,6,8' -and $toc.Live -eq 8 -and $toc.Read -eq 8 -and $toc.Source -and $toc.Block) "$($toc.Rows) / $($toc.Lines)"
    $modes = & $memoModule {
        $p = Get-WtMemoActivePane
        Set-WtMemoMode 'read'
        $reading = $p.Current
        [void](Open-WtMemo 'list3' 'tab')
        Set-WtMemoMode 'source'
        [void](Select-WtMemoTab $p $reading)
        $a = @{ Back = $script:mode; Tip = $p.ViewButton.ToolTip }
        Save-WtMemoTabs
        $a.Saved = @((Get-WtSetting 'memo.tabs').panes[0].modes) -join ','
        Set-WtMemoMode 'live'; $a
    }
    Assert-WtTest '메모 보기: 탭마다 기억하고 설정에 남긴다' ($modes.Back -ceq 'read' -and $modes.Tip -ceq '읽기 보기 (Ctrl+E)' -and $modes.Saved -like '*read,source*') ($modes | ConvertTo-Json -Compress)

    $caseUpper = New-WtMemo; $caseUpper.id = 'CaseA'; [void](Set-WtMemoContent $caseUpper '대문자 항목' '위 본문')
    $caseLower = New-WtMemo; $caseLower.id = 'casea'; [void](Set-WtMemoContent $caseLower '소문자 항목' '아래 본문')
    Save-WtMemoItems @($caseUpper, $caseLower)
    $caseAction = & $memoModule {
        $script:viewStamp = $null; Update-WtMemoView
        Invoke-WtMemoAction 'pin' 'casea' $true
        @{ Ids = @($script:items.id); Upper = @($script:items | Where-Object id -CEQ 'CaseA')[0]; Lower = @($script:items | Where-Object id -CEQ 'casea')[0] }
    }
    Assert-WtTest '메모 정리: 대소문자만 다른 id를 구분하고 다른 행을 덮지 않는다' (
        $caseAction.Ids.Count -eq 2 -and $caseAction.Upper.title -ceq '대문자 항목' -and -not $caseAction.Upper.pinned -and $caseAction.Lower.pinned -and $caseAction.Lower.body -ceq '아래 본문')

    # ---- 큰 저장소: 직렬화 전부터 보유 · 연속 저장 · 실패 · 종료 확인 · 캐시 ----
    Wait-WtTestWrites 30000
    & $memoModule { foreach ($timer in $script:saveTimer, $script:undoTimer, $script:indexTimer, $script:linkTimer, $script:searchTimer) { if ($timer) { $timer.Stop() } }; $script:ui = @{}; $script:panes.Clear() }
    if ($win) { $win.Close(); $win = $null }
    Stop-WtAllWork
    $backgroundTest = New-WtTestData 'memo-background'
    $backgroundFixture = New-WtMemoPerfFixture -Count 320
    $originalWriter = & $storage { , $script:writeJob }
    $originalWritingChoice = & $shellModule { , ${function:Show-WtWritingChoice} }
    $originalWindow = & $shellModule { $script:window }
    $backgroundGate = $null
    try {
        Write-WtJsonFile (Get-WtStorePath memo) $backgroundFixture.Document
        Wait-WtTestWrites 30000
        Set-WtAppRoot $backgroundTest.App
        [void](Wait-WtWork -All -Milliseconds 30000)
        $backgroundStore = Open-WtMemoStore
        $backgroundPath = Get-WtStorePath memo
        $backgroundGate = New-WtTestGate
        & $storage {
            $script:writeJob = { param($p, $json) $g = [AppDomain]::CurrentDomain.GetData('WtTestGate'); [void]$g.Entered.Set(); [void]$g.Gate.WaitOne(); Write-WtDataFile $p $json }
        }
        & $shellModule {
            $script:window = $null; $script:testWritingAsked = 0
            function script:Show-WtWritingChoice { param($Purpose, [switch]$NoCancel) $script:testWritingAsked++; 'cancel' }
        }
        $nextItems = Get-WtMemoLiveItems $backgroundStore.Items
        $firstCopy = Copy-WtItem $nextItems[0]; $firstCopy.title = '화면 밖 첫 저장'; Set-WtItemEdited $firstCopy; $nextItems[0] = $firstCopy
        $firstSave = Save-WtMemoDataItems $backgroundStore $nextItems
        $entered = $backgroundGate.Entered.WaitOne(10000)
        $writingLook = & $memoModule { Get-WtMemoSaveLook }
        $closeCancelled = & $shellModule { $script:writingDropped = $false; -not (Confirm-WtDataWrites) -and $script:testWritingAsked -eq 1 }
        Assert-WtTest '화면 밖 저장: 쓰기 전부터 보유 · 저장하는 중 · 종료 취소 때 내용 유지' (
            $entered -and (Get-WtDataWriteStatus $backgroundPath).State -eq 'writing' -and $writingLook[0] -eq 'writing' -and $closeCancelled -and
            (Read-WtStore memo).items[0].title -ceq '화면 밖 첫 저장' -and [IO.File]::ReadAllText($backgroundPath) -notmatch '화면 밖 첫 저장')
        # 다시 읽은 핸들로 저장해 낡은 핸들 거부 규칙도 그대로 지킨다.
        $secondBase = Open-WtMemoStore
        $nextItems = Get-WtMemoLiveItems $secondBase.Items
        $secondCopy = Copy-WtItem $nextItems[0]; $secondCopy.title = '화면 밖 두 번째 저장'; Set-WtItemEdited $secondCopy; $nextItems[0] = $secondCopy
        $secondSave = Save-WtMemoDataItems $secondBase $nextItems
        Assert-WtTest '화면 밖 저장: 쓰는 중 다시 저장해도 앞 스냅샷은 불변이고 최신 내용을 보유한다' (
            $firstSave.Items[0].title -ceq '화면 밖 첫 저장' -and (Read-WtStore memo).items[0].title -ceq '화면 밖 두 번째 저장')
        [void]$backgroundGate.Gate.Set(); Wait-WtTestWrites 30000
        $disk = [IO.File]::ReadAllText($backgroundPath) | ConvertFrom-Json -DateKind String
        $backup = [IO.File]::ReadAllText("$backgroundPath.bak") | ConvertFrom-Json -DateKind String
        Assert-WtTest '화면 밖 저장: 저장됨은 파일에 쓴 최신 버전 · bak은 직전 버전' (
            (Get-WtDataWriteStatus $backgroundPath).State -eq 'saved' -and $disk.items[0].title -ceq '화면 밖 두 번째 저장' -and $backup.items[0].title -ceq '화면 밖 첫 저장')
        Remove-WtTestGate $backgroundGate; $backgroundGate = $null
        & $storage { $script:writeJob = { param($p, $json) throw [IO.IOException]::new('큰 저장소 검사 실패') } }
        $failedBase = Open-WtMemoStore
        $failedSave = Set-WtMemoArchived -Store $failedBase -Id memo-0 -Archived $true
        Wait-WtTestWrites 30000
        $failedLook = & $memoModule { Get-WtMemoSaveLook }
        $failureAsked = & $shellModule { $script:testAsked = @(); $script:testChoices.Clear(); $script:writingDropped = $false; -not (Confirm-WtDataWrites) -and ($script:testAsked -join ',') -eq 'exit' }
        Assert-WtTest '화면 밖 저장: 실패 내용 보유 · 실패 표시 · 종료 전에 묻기 · 원본 유지' (
            (Get-WtDataWriteStatus $backgroundPath).State -eq 'failed' -and $failedLook[0] -eq 'error' -and $failureAsked -and
            (Read-WtStore memo).items[0].archived -eq $true -and ([IO.File]::ReadAllText($backgroundPath) | ConvertFrom-Json).items[0].archived -eq $false)
        & $storage { param($writer) $script:writeJob = $writer } $originalWriter
        [void](& $memoModule { Save-WtMemoNow -Retry }); Wait-WtTestWrites 30000
        Assert-WtTest '화면 밖 저장: Ctrl+S 재시도로 보유 내용을 파일에 쓰고 실패를 해제한다' (
            (Get-WtDataWriteStatus $backgroundPath).State -eq 'saved' -and ([IO.File]::ReadAllText($backgroundPath) | ConvertFrom-Json).items[0].archived -eq $true)

        $backgroundGate = New-WtTestGate
        & $storage { $script:writeJob = { param($p, $json) $g = [AppDomain]::CurrentDomain.GetData('WtTestGate'); [void]$g.Entered.Set(); [void]$g.Gate.WaitOne(); Write-WtDataFile $p $json } }
        Invoke-WtQueuedStoreWrite -Action { Write-WtJsonFile (Get-WtStorePath 'edit-gate') @{ items = @() } }
        [void]$backgroundGate.Entered.WaitOne(10000)
        $editable = @(Get-WtMemoItems)
        [void](Set-WtMemoContent $editable[0] '편집용 항목' '받아들인 본문 #태그')
        Save-WtMemoItems $editable
        $editable[0].body = '아직 저장하지 않은 다음 본문'
        $acceptedBody = (Read-WtStore memo).items[0].body
        [void]$backgroundGate.Gate.Set(); Wait-WtTestWrites 30000
        Assert-WtTest '화면 밖 저장: 편집용 항목을 직접 고쳐도 JSON 캐시가 낡지 않고 받아들인 스냅샷은 이후 편집과 분리된다' (
            $acceptedBody -ceq '받아들인 본문 #태그' -and ([IO.File]::ReadAllText($backgroundPath) | ConvertFrom-Json).items[0].body -ceq '받아들인 본문 #태그')
        Remove-WtTestGate $backgroundGate; $backgroundGate = $null
        & $storage { param($writer) $script:writeJob = $writer } $originalWriter

        $cacheItems = @($backgroundFixture.Document.items[0..63]) + @($backgroundFixture.Document.items[100])
        $cachePath = Get-WtStorePath memo-index-cache
        $cacheReference = New-WtMemoIndex $cacheItems -Folders $backgroundFixture.Document.folders
        $expectedLinks = (Find-WtMemo -Index $cacheReference -Query 'has:link').Items.Id -join ','
        foreach ($cacheCase in 'missing', 'valid', 'stale', 'broken') {
            switch ($cacheCase) {
                'missing' { & $storage { param($p) [IO.File]::Delete($p) } $cachePath }
                'stale' { $staleCache = Read-WtCacheFile $cachePath; $staleCache.Version = 99; Write-WtCacheFile $cachePath $staleCache }
                'broken' { & $storage { param($p) [IO.File]::WriteAllText($p, '{broken') } $cachePath }
            }
            $cacheWork = Start-WtMemoBackgroundIndex -Items $cacheItems -Folders $backgroundFixture.Document.folders
            $cacheFinished = Wait-WtWork $cacheWork -Milliseconds 30000
            if ($cacheFinished -and $cacheWork.State -eq 'done') { Set-WtMemoIndexProperties $cacheWork.Result }
            Assert-WtTest "연결 캐시: $cacheCase 상태에서도 같은 연결 결과를 다시 만든다" (
                $cacheFinished -and $cacheWork.State -eq 'done' -and $cacheWork.Result.LinksReady -and
                ((Find-WtMemo -Index $cacheWork.Result -Query 'has:link').Items.Id -join ',') -ceq $expectedLinks -and (Read-WtCacheFile $cachePath).Version -eq 1) $cacheWork.Error
        }
        Write-WtJsonFile $backgroundPath ([pscustomobject]@{ schema = 1; saved = '2026-11-01T09:30:00+09:00'; items = $cacheItems; folders = $backgroundFixture.Document.folders })
        Wait-WtTestWrites 30000
        Set-WtAppRoot $backgroundTest.App; [void](Wait-WtWork -All -Milliseconds 30000)
        $loadedBefore = @(Get-WtMemoItems); $stampBefore = Get-WtStoreStamp memo
        & $storage {
            param($p)
            $at = [IO.File]::GetLastWriteTimeUtc($p)
            $text = [IO.File]::ReadAllText($p).Replace('[[시험 메모 0100]]', '[[시험 메모 0101]]')
            [IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($false)); [IO.File]::SetLastWriteTimeUtc($p, $at)
        } $backgroundPath
        $loadedAfter = @(Get-WtMemoItems); $stampAfter = Get-WtStoreStamp memo
        $externalWork = Start-WtMemoBackgroundIndex -Items $loadedAfter -Folders $backgroundFixture.Document.folders
        $externalFinished = Wait-WtWork $externalWork -Milliseconds 30000
        if ($externalFinished -and $externalWork.State -eq 'done') { Set-WtMemoIndexProperties $externalWork.Result }
        Assert-WtTest '연결 캐시: 같은 크기·시각의 외부 memo.json 변경도 다시 읽고 낡은 연결을 버린다' (
            $stampBefore -cne $stampAfter -and $loadedBefore[0].body.Contains('[[시험 메모 0100]]') -and $loadedAfter[0].body.Contains('[[시험 메모 0101]]') -and
            $externalFinished -and $externalWork.State -eq 'done' -and (Find-WtMemo -Index $externalWork.Result -Query 'linksto:memo-100').Count -eq 0)
    } finally {
        if ($backgroundGate) { Remove-WtTestGate $backgroundGate }
        & $storage { param($writer) $script:writeJob = $writer } $originalWriter
        & $shellModule { param($choice, $window) Set-Item Function:script:Show-WtWritingChoice $choice; $script:window = $window } $originalWritingChoice $originalWindow
        Wait-WtTestWrites 30000; Stop-WtAllWork
        Set-WtAppRoot $test.App
        Remove-WtTestData $backgroundTest
    }
} finally {
    if ($held) { $held.Dispose() }
    if ($win) { try { $win.Close() } catch { } }
    & $memoModule { foreach ($timer in $script:saveTimer, $script:undoTimer, $script:indexTimer, $script:searchTimer) { if ($timer) { $timer.Stop() } } }
    Remove-WtTestData $test
}

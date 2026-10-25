<#
.SYNOPSIS
    문서 탭을 임시 폴더로 검사한다: 목록 · 경로 · 즐겨찾기 · 화면 · 조회 취소 · 목록 가상화.

.DESCRIPTION
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.
    조회 순서 · 취소 검사는 가짜 조회 작업을 넣어서 하고, 실제 공유 폴더에는 접속하지 않는다. 화면 검사는 Windows STA에서만 한다.

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/docs/Test-Docs.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'Docs.psm1') -Force -DisableNameChecking
$docsModule = Get-Module Docs
$test = New-WtTestData 'docs'

# 조회 작업이 모두 끝나고 결과가 화면에 반영될 때까지 돌린다
function Wait-WtDocJobs {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (& $docsModule { $script:jobs.Count -or $script:pending.Count -or $script:treeBatches.Count }) {
        & $docsModule { Complete-WtDocJobs; Complete-WtDocTreeBatch }
        if ($watch.Elapsed.TotalSeconds -gt 15) { throw '문서 검사 조회 시간 초과' }
        Start-Sleep -Milliseconds 10
    }
}

try {
    # ---- 목록 · 경로 ----
    $docRoot = (New-Item -ItemType Directory -Path (Join-Path $test.Root '문서 루트')).FullName
    New-Item -ItemType Directory -Path (Join-Path $docRoot '운영\점검') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $docRoot '가나다') | Out-Null
    Set-Content -LiteralPath (Join-Path $docRoot '계정 목록.xlsx') -Value 'x'
    Set-Content -LiteralPath (Join-Path $docRoot 'readme.md') -Value ('a' * 3000)
    $hid = New-Item -ItemType File -Path (Join-Path $docRoot 'secret.tmp')
    $hid.Attributes = 'Hidden'
    $de = Get-WtDocEntries $docRoot
    Assert-WtTest '문서: 폴더 먼저 · 이름 순 · 숨김 빼기' ((($de | ForEach-Object Name) -join ',') -eq '가나다,운영,계정 목록.xlsx,readme.md') (($de | ForEach-Object Name) -join ',')
    Assert-WtTest '문서: 종류 · 크기' (($de | Where-Object Name -eq '계정 목록.xlsx').Kind -eq 'Excel' -and (Format-WtDocSize 3002) -eq '3 KB' -and (Format-WtDocSize 5MB) -eq '5.0 MB' -and (Get-WtDocKind 'a.abc' $false) -eq 'ABC')
    Assert-WtTest '문서: 하위 폴더' ((@(Get-WtDocSubfolders $docRoot) | ForEach-Object { Split-Path $_ -Leaf }) -join ',' -eq '가나다,운영')
    $chain = Get-WtDocChain @('D:\x', $docRoot) (Join-Path $docRoot '운영\점검')
    Assert-WtTest '문서: 맨 위 폴더부터 경로 차례' ($chain.Count -eq 3 -and $chain[0] -eq $docRoot -and $chain[2] -like '*\운영\점검') ($chain -join ' > ')
    Assert-WtTest '문서: 맨 위 폴더 밖은 빈 차례' ((Get-WtDocChain @($docRoot) 'Z:\other').Count -eq 0)
    Assert-WtTest '문서: 경로 표시' ((Format-WtDocPathLabel @($docRoot) (Join-Path $docRoot '운영\점검')) -eq '문서 루트 › 운영 › 점검' -and (Format-WtDocPathLabel @($docRoot) 'Z:\a') -eq 'Z:\a')
    Assert-WtTest '문서: 이름 거르기' (@(Find-WtDocEntry $de '계정 목록').Count -eq 1 -and @(Find-WtDocEntry $de '').Count -eq 4)
    $xl = Join-Path $docRoot '계정 목록.xlsx'
    Assert-WtTest '문서: 즐겨찾기 넣기 · 빼기' ((Switch-WtDocPin $xl) -and (Test-WtDocPinned $xl) -and -not (Switch-WtDocPin $xl) -and -not (Test-WtDocPinned $xl))
    [void](Switch-WtDocPin 'Z:\없는\파일.xlsx')
    Assert-WtTest '문서: 없어진 즐겨찾기도 보여 준다' (@(Get-WtDocPinEntries | Where-Object Missing).Count -eq 1)
    Set-WtSetting 'docs.pins' @()

    if (-not (Test-WtTestWpf)) { Write-Host 'SKIP 문서 화면 · 조회 (Windows STA에서만)'; return }
    $addon = Get-WtAddon -Id 'docs'

    # ---- 화면: 맨 위 폴더 → 하위 폴더로 들어가기 → 즐겨찾기 ----
    Set-WtSetting 'docs.roots' @($docRoot)
    Set-WtSetting 'docs.last' ''
    $view = New-WtTestView 'docs'
    [void](& $addon.Refresh $view)
    Wait-WtDocJobs
    Assert-WtTest 'WPF 문서: 맨 위 폴더를 연다' ((& $docsModule { $script:current }) -eq $docRoot -and (& $docsModule { $script:ui.List.Items.Count }) -eq 4) "(cur=$(& $docsModule { $script:current }) err=$(& $docsModule { $script:ui.Error }))"
    & $docsModule { Open-WtDocEntry ($script:entries | Where-Object Name -eq '운영') }
    Wait-WtDocJobs
    Assert-WtTest 'WPF 문서: 폴더로 들어가면 트리도 따라간다' ((& $docsModule { $script:current }) -like '*\운영' -and (& $docsModule { $script:ui.Tree.SelectedItem.Tag.Path }) -like '*\운영' -and (& $docsModule { $script:ui.PathText.Text }) -eq '문서 루트 › 운영')
    & $docsModule { $script:ui.List.SelectedIndex = 0; $script:ui.Pin.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
    Assert-WtTest 'WPF 문서: 즐겨찾기 버튼' (@(Get-WtSetting 'docs.pins').Count -eq 1 -and @(Get-WtSetting 'docs.pins')[0] -like '*\운영\점검')
    Set-WtSetting 'docs.pins' @(); Set-WtSetting 'docs.roots' @()

    # ---- 목록 가상화: 데이터 5천 개여도 보이는 행만 만든다 ----
    $view = New-WtTestView 'docs'
    $docList = & $docsModule { $script:ui.List }
    $rows = @(for ($i=0; $i -lt 5000; $i++) { [pscustomobject]@{ Name="sample-$i.txt"; Path="X:\synthetic\sample-$i.txt"; IsDir=$false; Kind='텍스트'; SizeText='1 KB'; ModifiedText='2026-01-01'; IconText=[string][char]0xE8A5; Missing=$false } })
    & $docsModule { param($items) $script:entries = $items; Update-WtDocList } $rows
    $docList.Measure([Windows.Size]::new(900,500)); $docList.Arrange([Windows.Rect]::new(0,0,900,500)); $docList.UpdateLayout()
    $realized = 0
    for ($i=0; $i -lt 5000; $i++) { if ($docList.ItemContainerGenerator.ContainerFromIndex($i)) { $realized++ } }
    Assert-WtTest '문서 안정성: 5천 항목을 모두 보관하고 화면 행은 100개 미만으로 만든다' ($docList.Items.Count -eq 5000 -and $realized -gt 0 -and $realized -lt 100)

    # ---- 조회 순서 · 취소: 예측 가능한 느린 작업을 넣어서 본다 ----
    $originalWorker = & $docsModule { $script:worker }
    & $docsModule {
        $script:worker = { param($request, $kinds, $icons) if ($request.Path -eq 'slow') { Start-Sleep -Milliseconds 300 }; @{ Items = @([pscustomobject]@{ Name=$request.Path; Path=$request.Path; IsDir=$false; Missing=$false }); Error=$null } }
        Show-WtDocFolder 'slow'
        Show-WtDocFolder 'latest'
    }
    Wait-WtDocJobs
    Assert-WtTest '문서 안정성: 늦은 이전 조회가 새 폴더 결과를 덮지 않는다' ((& $docsModule { $script:entries[0].Name }) -eq 'latest')
    & $docsModule { for ($i=0; $i -lt 20; $i++) { Show-WtDocFolder 'slow' }; Cancel-WtDocFolder }
    Assert-WtTest '문서 안정성: 빠른 연속 탐색도 실행 중 조회는 8개 이하이고 취소 뒤 살아 있는 조회가 없다' ((& $docsModule { $script:jobs.Count }) -le 8 -and -not (& $docsModule { @($script:jobs | Where-Object { -not $_.Request.Cancel.Value }).Count }))
    Wait-WtDocJobs
    Assert-WtTest '문서 안정성: 취소된 조회가 나중에 목록을 채우지 않는다' ((& $docsModule { $script:entries.Count }) -eq 0 -and -not (& $docsModule { $script:ui.Loading }))
    # 많은 하위 폴더도 한 차례에 모두 만들지 않는다
    $batchState = & $docsModule {
        $node = New-WtDocTreeItem 'synthetic' 'X:\synthetic' 0xE8B7
        $paths = @(for ($i=0; $i -lt 200; $i++) { "X:\synthetic\folder-$i" })
        $script:treeTarget = $null; $script:treeWaitNode = $null
        Set-WtDocResult @{ Key='tree:test'; Generation=$script:treeGeneration; Context=$node } @{ Items=$paths; Error=$null }
        Complete-WtDocTreeBatch
        @{ Node=$node; FirstCount=@($node.Items | Where-Object { $_ -is [Windows.Controls.TreeViewItem] }).Count; Remaining=$script:treeBatches.Count }
    }
    Assert-WtTest '문서 안정성: 하위 폴더 트리를 작은 묶음으로 나눠 반영한다' ($batchState.FirstCount -gt 0 -and $batchState.FirstCount -le 32 -and $batchState.Remaining -eq 1)
    Wait-WtDocJobs
    Assert-WtTest '문서 안정성: 나눠 반영한 하위 폴더를 빠짐없이 보여 준다' ($batchState.Node.Items.Count -eq 200 -and $batchState.Node.Tag.Loaded)
    Set-WtSetting 'docs.roots' @('X:\tree-a', 'X:\tree-b')
    & $docsModule {
        Update-WtDocTree
        Show-WtDocFolder 'X:\tree-a' -SelectTree
        $script:ui.Tree.Items[2].IsSelected = $true
        Set-WtDocResult @{Key='tree:old'; Generation=$script:treeGeneration; Context=$script:ui.Tree.Items[1]} @{Items=@(); Error=$null}
        Complete-WtDocTreeBatch
    }
    Assert-WtTest '문서 안정성: 늦은 트리 결과가 새로 고른 폴더 선택을 되돌리지 않는다' ((& $docsModule { $script:current }) -eq 'X:\tree-b' -and (& $docsModule { $script:ui.Tree.SelectedItem.Tag.Path }) -eq 'X:\tree-b')
    Wait-WtDocJobs
    # 트리 대기열이 많아도 현재 폴더 요청의 자리를 남긴다
    & $docsModule {
        $script:worker = { param($request, $kinds, $icons) Start-Sleep -Milliseconds 200; @{ Items=@(); Error=$null } }
        [void](Start-WtDocRequest 'home' 'pins')
        [void](Start-WtDocRequest 'folder' 'folder' 'busy')
        for ($i=0; $i -lt 32; $i++) { $script:pending["tree:queued-$i"] = @{ Key="tree:queued-$i"; Request=@{ Action='tree'; Path="X:\queued-$i"; Cancel=[hashtable]::Synchronized(@{ Value = $false }) }; Generation=-1 } }
        $script:current = 'new'
        [void](Start-WtDocRequest 'folder' 'folder' 'new')
    }
    Assert-WtTest '문서 안정성: 트리 대기열이 꽉 차도 새 폴더 조회는 바로 시작한다' (& $docsModule { @($script:jobs | Where-Object { $_.Key -eq 'folder' -and $_.Request.Path -eq 'new' -and -not $_.Request.Cancel.Value }).Count -eq 1 })
    & $docsModule { Stop-WtDocs }
    Wait-WtDocJobs
    # 응답 없는 폴더 조회를 취소하면 그 조회가 끝나기를 기다리지 않고 새 폴더를 연다
    & $docsModule {
        $script:worker = { param($request, $kinds, $icons) if ($request.Path -like 'stuck*') { Start-Sleep -Milliseconds 1500 }; @{ Items = @([pscustomobject]@{ Name=$request.Path; Path=$request.Path; IsDir=$false; Missing=$false }); Error=$null } }
        Show-WtDocFolder 'stuck-1'; Show-WtDocFolder 'stuck-2'; Cancel-WtDocFolder
        Show-WtDocFolder 'fresh'
    }
    # 바로 끝나는 조회는 폴더를 여는 짧은 기다림 안에 결과까지 들어온다
    Assert-WtTest '문서 안정성: 응답 없는 조회 두 개를 취소해도 새 폴더 조회가 바로 시작한다' (& $docsModule {
            @($script:jobs | Where-Object { $_.Key -eq 'folder' -and $_.Request.Path -eq 'fresh' }).Count -eq 1 -or ($script:entries.Count -and $script:entries[0].Name -eq 'fresh') })
    Wait-WtDocJobs
    Assert-WtTest '문서 안정성: 늦게 끝난 취소 조회는 새 폴더 목록을 덮지 않는다' ((& $docsModule { $script:entries[0].Name }) -eq 'fresh')
    # 다른 폴더를 펼쳐도 지금 폴더 쪽으로 펼침 · 스크롤을 되돌리지 않는다
    & $docsModule {
        $script:worker = {
            param($request, $kinds, $icons)
            $tree = @{ 'X:\jump' = @('X:\jump\a', 'X:\jump\b'); 'X:\jump\a' = @('X:\jump\a\deep'); 'X:\jump\b' = @('X:\jump\b\x') }
            if ($request.Action -eq 'tree') { return @{ Items = @($tree[$request.Path] | Where-Object { $_ }); Error = $null } }
            @{ Items = @(); Error = $null }
        }
    }
    Set-WtSetting 'docs.roots' @('X:\jump')
    & $docsModule { Update-WtDocTree; Show-WtDocFolder 'X:\jump\a\deep' -SelectTree }
    Wait-WtDocJobs
    $jump = & $docsModule { $rootNode = $script:ui.Tree.Items[1]; @{ A = $rootNode.Items[0]; B = $rootNode.Items[1]; Selected = $script:ui.Tree.SelectedItem } }
    Assert-WtTest '문서 안정성: 깊은 폴더를 열면 트리를 차례로 펼쳐 찾아간다' ($jump.Selected.Tag.Path -eq 'X:\jump\a\deep' -and $jump.A.IsExpanded)
    # 다시 찾아가기(선택 · 스크롤 이동)가 불리는지 센다. 화면 없이 스크롤 위치를 볼 수 없어서다
    & $docsModule {
        $script:testSelectCalls = 0
        $script:originalSelect = (Get-Command Select-WtDocTreePath).ScriptBlock
        Set-Item Function:script:Select-WtDocTreePath -Value { param($Path) $script:testSelectCalls++; & $script:originalSelect $Path }
    }
    $jump.A.IsExpanded = $false
    $jump.B.IsExpanded = $true
    Wait-WtDocJobs
    $jumpCalls = & $docsModule { $script:testSelectCalls; Set-Item Function:script:Select-WtDocTreePath -Value $script:originalSelect }
    Assert-WtTest '문서 안정성: 다른 폴더를 펼쳐도 지금 폴더로 되돌아가거나 접어 둔 폴더를 펼치지 않는다' (-not $jump.A.IsExpanded -and $jump.B.Tag.Loaded -and $jumpCalls -eq 0)
    # 마지막으로 본 폴더가 없어졌으면 첫 폴더를 연다
    & $docsModule {
        $script:worker = {
            param($request, $kinds, $icons)
            if ($request.Action -eq 'tree') { return @{ Items = @(); Error = $null } }
            if ($request.Path -eq 'X:\fb\gone') { return @{ Items = @(); Error = '경로를 찾을 수 없습니다.' } }
            @{ Items = @([pscustomobject]@{ Name='ok.txt'; Path="$($request.Path)\ok.txt"; IsDir=$false; Missing=$false }); Error = $null }
        }
    }
    Set-WtSetting 'docs.roots' @('X:\fb'); Set-WtSetting 'docs.last' 'X:\fb\gone'
    & $docsModule { Update-WtDocsView }
    Wait-WtDocJobs
    Assert-WtTest '문서 안정성: 마지막 폴더를 못 열면 오류 대신 첫 폴더를 연다' ((& $docsModule { $script:current }) -eq 'X:\fb' -and -not (& $docsModule { $script:ui.Error }) -and (& $docsModule { $script:entries.Count }) -eq 1)
    # 응답 없는 공유 폴더: 조회가 OS 요청에서 돌아오지 않아도 폴더 열기는 짧게만 기다리고, 끝낼 때는 기다리지 않고 버린다
    $gate = New-WtTestGate
    try {
        & $docsModule { param($hang) $script:worker = $hang } $wtTestHang
        $watch = [Diagnostics.Stopwatch]::StartNew()
        & $docsModule { Show-WtDocFolder '\\srv\hang\폴더' }
        $openMs = $watch.ElapsedMilliseconds
        $entered = $gate.Entered.WaitOne(5000)
        $loading = & $docsModule { $script:ui.Loading }
        $watch.Restart(); & $docsModule { Stop-WtDocs }; $stopMs = $watch.ElapsedMilliseconds
        Assert-WtTest '문서 안정성: 응답 없는 폴더도 화면은 잠깐만 기다리고(불러오는 중), 끝낼 때는 바로 버린다' (
            $entered -and $loading -and $openMs -lt 1000 -and $stopMs -lt 200 -and (Get-WtWorkInfo).Running -eq 0 -and (Get-WtWorkInfo).Abandoned -ge 1) "(열기 ${openMs}ms · 끝내기 ${stopMs}ms)"
    } finally { Remove-WtTestGate $gate }
    Set-WtSetting 'docs.roots' @(); Set-WtSetting 'docs.last' ''
    & $docsModule { param($worker) $script:worker = $worker; Stop-WtDocs } $originalWorker
    Assert-WtTest '문서 안정성: 끝낸 뒤 남은 조회 · 화면 밖 작업이 없다' ((& $docsModule { $script:jobs.Count }) -eq 0 -and (Get-WtWorkInfo).Running -eq 0 -and (Get-WtWorkInfo).Abandoned -eq 0)
} finally {
    & $docsModule { Stop-WtDocs }
    Remove-WtTestData $test
}

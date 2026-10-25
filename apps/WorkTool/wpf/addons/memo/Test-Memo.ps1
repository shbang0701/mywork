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
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'MemoEditor.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Memo.psm1') -Force -DisableNameChecking
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
    Assert-WtTest '메모 검색: 낱말 모두 포함' (@(Find-WtMemo $memos '장비 정리').Count -eq 1 -and @(Find-WtMemo $memos '').Count -eq 2)

    # ---- 쓰기 ----
    $when = [datetime]'2026-10-22 11:20:05'
    $nm = New-WtMemo $when
    Assert-WtTest '메모: 새 메모' ($nm.id.Length -eq 12 -and $nm.created -eq '2026-10-22 11:20:05' -and $nm.body -eq '')
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
    Assert-WtTest 'WPF 메모: 예전 memo.mode=edit는 편집(live)으로 연다' (& $memoModule { $script:mode -eq 'live' -and @($script:ui.ModeButtons | Where-Object IsChecked)[0].Tag.Value -eq 'live' })
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
    $empty = & $memoModule { $p = $script:panes[0]; $p.Empty.Visibility -eq 'Visible' -and $p.Head.Visibility -eq 'Collapsed' -and -not $p.Delete.IsEnabled }
    Assert-WtTest 'WPF 메모 칸: 탭이 없으면 빈 상태 안내 + 행동 버튼' $empty

    # ---- 지운 메모의 탭은 모든 칸에서 닫힌다 ----
    & $memoModule { [void](Open-WtMemo 'ma' 'tab'); [void](Open-WtMemo 'mb' 'tab') }
    Send-TestListClick 'mc' Right
    $menuState = & $memoModule { [pscustomobject]@{ MenuId = $script:listMenuId; Current = $script:panes[0].Current.Id } }
    & $memoModule { $script:listMenuId = ''; $m = $script:ui.List.ContextMenu; $m.Tag = 'mb'; $m.Items[1].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent)) }
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 칸: 목록 우클릭은 선택을 바꾸지 않고, 메뉴 [오른쪽에 열기]는 오른쪽 칸에 연다' ($menuState.MenuId -eq 'mc' -and $menuState.Current -eq 'mb' -and $s.Panes -eq 2 -and $s.Tabs[1] -eq 'mb' -and $s.Tabs[0] -eq 'ma,mb') "$($menuState.MenuId) $($s.Tabs -join ' | ')"
    & $memoModule { Remove-WtMemoCurrent }
    $s = Get-TestTabs
    Assert-WtTest 'WPF 메모 칸: 메모를 지우면 그 탭을 모든 칸에서 닫는다' ($s.Panes -eq 1 -and $s.Tabs[0] -eq 'ma' -and -not ((Get-WtMemoItems) | Where-Object id -eq 'mb') -and (& $memoModule { $script:ui.UndoBar.Visibility }) -eq 'Visible')
    & $memoModule { Restore-WtMemoDeleted }
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
    $readOk = & $memoModule { $script:mode -eq 'read' -and $script:panes[0].TitleText.Visibility -eq 'Visible' -and $script:panes[0].TitleBox.Visibility -eq 'Collapsed' }
    [void](Send-TestKey Oem2 Control)
    $srcOk = & $memoModule { $script:mode -eq 'source' }
    [void](Send-TestKey E Control); [void](Send-TestKey E Control)
    Assert-WtTest 'WPF 메모 모드: Ctrl+E 읽기 ↔ 편집(돌아갈 모드 기억), Ctrl+/ 원문, 설정에 live · source · read로 남긴다' ($readOk -and $srcOk -and (& $memoModule { $script:mode }) -eq 'source' -and (Get-WtSetting 'memo.mode') -eq 'source')
    [void](Send-TestKey Oem2 Control)

    # ---- 새 메모 → 입력 → 저장 → 삭제 → 실행 취소 · 끝낼 때 저장 ----
    & $memoModule { $p = $script:panes[1]; foreach ($t in @($p.Tabs)) { [void](Close-WtMemoTab $p $t) } }   # 둘째 칸을 닫아 첫 칸만 쓴다
    $before = (Get-WtMemoItems).Count
    [void](Send-TestKey N Control)
    & $memoModule { $script:panes[0].TitleBox.Text = '새 제목' }
    Set-TestBody 0 '본문 #새태그'
    [void](& $memoModule { Save-WtMemoNow })
    $saved = Get-WtMemoItems
    $new = $saved | Where-Object title -eq '새 제목'
    Assert-WtTest 'WPF 메모: Ctrl+N 새 메모(새 탭)를 쓰고 저장' ($saved.Count -eq $before + 1 -and $new.body -eq '본문 #새태그' -and @($new.tags)[0] -eq '새태그' -and (Get-TestTabs).Current[0] -eq $new.id)
    $st0 = & $memoModule { $script:panes[0].Status }
    Assert-WtTest 'WPF 메모: 저장 상태 표시 · 탭 제목 · 목록 맨 위' (@(Get-WtTestTexts $st0 | Where-Object { $_ -like '자동 저장됨*' }).Count -eq 1 -and (& $memoModule { $script:panes[0].Current.Text.Text }) -eq '새 제목' -and (& $memoModule { [string]$script:ui.List.Items[0].Id }) -eq $new.id)
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
    $held = [System.IO.File]::Open($memoPath, 'Open', 'Read', 'Read')
    Assert-WtTest '메모 안정성: 잠긴 파일 저장은 실패를 돌려준다' (-not (& $memoModule { Save-WtMemoNow }))
    $st0 = & $memoModule { $script:panes[0].Status }
    Assert-WtTest '메모 안정성: 저장 실패는 그 칸에 오류로 보인다' (@(Get-WtTestTexts $st0 | Where-Object { $_ -like '저장하지 못했습니다*' }).Count -eq 1)
    Set-TestBody 0 'unsaved draft'
    Assert-WtTest '메모 안정성: 저장 오류 뒤 다시 입력하면 저장 안 됨 표시' (@(Get-WtTestTexts $st0) -contains '저장 안 됨')
    & $memoModule { Update-WtMemoView }
    Assert-WtTest '메모 안정성: 실패 후 새로 고침해도 작성 중인 본문·dirty를 유지한다' ((Get-TestBody 0) -eq 'unsaved draft' -and (& $memoModule { $script:panes[0].Dirty }))
    & $memoModule { param($id) Select-WtMemoItem $id } $two.id
    Assert-WtTest '메모 안정성: 실패 후 다른 메모 선택을 취소한다' ((Get-TestTabs).Current[0] -eq $one.id -and (& $memoModule { $script:ui.List.SelectedItem.Id }) -eq $one.id)
    [void](Send-TestKey Tab Control); [void](Send-TestKey W Control); [void](Send-TestKey Oem5 Control)
    $s = Get-TestTabs
    Assert-WtTest '메모 안정성: 실패 후 탭 바꾸기 · 닫기 · 나누기를 하지 않는다' ($s.Panes -eq 1 -and $s.Current[0] -eq $one.id -and $s.Tabs[0] -eq "$($one.id),$($two.id)" -and (Get-TestBody 0) -eq 'unsaved draft')
    & $memoModule { $script:ui.Search.Text = 'B'; [void](Add-WtMemo -Edit); Remove-WtMemoCurrent }
    Assert-WtTest '메모 안정성: 실패 후 검색·추가·삭제가 초안을 버리지 않는다' ((Get-TestBody 0) -eq 'unsaved draft' -and (Get-WtMemoItems).Count -eq 2)

    # 셸과 맞물리는 곳: 저장 실패를 셸이 알아듣고 묻는다 (묻는 흐름 자체는 tests\Test-Reliability.ps1)
    $asked = & $shellModule { $script:testAsked = @(); [void](Save-WtPendingChanges -Purpose exit); $script:testAsked -join ',' }
    Assert-WtTest '메모 안정성: 저장 실패를 셸이 끝내기 전에 묻는다' ($asked -eq 'exit')
    $moved = & $shellModule { $script:testChoices.Enqueue('proceed'); Save-WtPendingChanges -Purpose switch -Only 'memo' }
    Assert-WtTest '메모 안정성: [이동]을 골라도 저장하지 못한 초안을 메모 화면에 둔다' ($moved -and (Get-TestBody 0) -eq 'unsaved draft' -and (& $memoModule { $script:panes[0].Dirty }))
    Assert-WtTest '메모 안정성: 저장 실패로 원본 파일을 바꾸지 않는다' ([System.IO.File]::ReadAllText($memoPath) -ceq $original)

    $held.Dispose(); $held = $null
    Assert-WtTest '메모 안정성: 잠금 해제 후 같은 초안을 저장할 수 있다' (& $memoModule { Save-WtMemoNow })
    Assert-WtTest '메모 안정성: 재시도한 본문을 다시 읽을 수 있다' (((Get-WtMemoItems) | Where-Object id -eq $one.id).body -eq 'unsaved draft')
    & $memoModule { $script:ui.Search.Text = '' }
    Set-TestBody 0 'next draft'
    & $memoModule { param($id) Select-WtMemoItem $id } $two.id
    Assert-WtTest '메모 안정성: 자동 저장 뒤 목록 선택과 편집기 메모가 일치한다' ((Get-TestTabs).Current[0] -eq $two.id -and (& $memoModule { $script:ui.List.SelectedItem.Id }) -eq $two.id -and ((Get-WtMemoItems) | Where-Object id -eq $one.id).body -eq 'next draft')
    & $memoModule { param($id) Select-WtMemoItem $id } $one.id

    # 실패한 삭제 · 실행 취소를 여러 번 해도 배열이 먼저 바뀌지 않는다
    $held = [System.IO.File]::Open($memoPath, 'Open', 'Read', 'Read')
    & $memoModule { Remove-WtMemoCurrent; Remove-WtMemoCurrent; [void](Add-WtMemo) }
    Assert-WtTest '메모 안정성: 삭제·추가 실패 시 메모리 배열을 유지한다' ((& $memoModule { $script:items.Count }) -eq 2)
    $held.Dispose(); $held = $null
    & $memoModule { Remove-WtMemoCurrent }
    $held = [System.IO.File]::Open($memoPath, 'Open', 'Read', 'Read')
    & $memoModule { Restore-WtMemoDeleted; Restore-WtMemoDeleted }
    Assert-WtTest '메모 안정성: 실행 취소 실패를 재시도해도 중복 항목을 만들지 않는다' ((& $memoModule { $script:items.Count }) -eq 1)
    $held.Dispose(); $held = $null
    & $memoModule { Restore-WtMemoDeleted }
    Assert-WtTest '메모 안정성: 실행 취소 성공 뒤 ID가 모두 고유하다' ((Get-WtMemoItems).Count -eq 2 -and @((Get-WtMemoItems).id | Sort-Object -Unique).Count -eq 2)
} finally {
    if ($held) { $held.Dispose() }
    if ($win) { try { $win.Close() } catch { } }
    & $memoModule { if ($script:saveTimer) { $script:saveTimer.Stop() }; if ($script:undoTimer) { $script:undoTimer.Stop() } }
    Remove-WtTestData $test
}

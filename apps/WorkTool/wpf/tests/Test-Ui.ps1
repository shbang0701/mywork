<#
.SYNOPSIS
    공통 화면 부품을 숨김 호스트로 검사한다: 체크 줄 콜백·좌표 경로 · 표 낱말 폭·실제 경계.
.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/tests/Test-Ui.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-WtTestCore
if (-not (Test-WtTestWpf)) { Write-Host 'SKIP 공통 화면 (Windows STA에서만)'; return }
$test = New-WtTestData 'ui'
$hostSource = $null
try {
    $root = [Windows.Controls.Border]::new()
    $root.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
    $root.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $parameters = [Windows.Interop.HwndSourceParameters]::new('UI test')
    $parameters.WindowStyle = 0; $parameters.Width = 680; $parameters.Height = 600
    $hostSource = [Windows.Interop.HwndSource]::new($parameters); $hostSource.RootVisual = $root
    function Set-UiLayout([double]$Width = 544, [double]$Height = 500) {
        $root.Width = $Width; $root.Height = $Height
        for ($pass = 0; $pass -lt 3; $pass++) {
            $root.Measure([Windows.Size]::new($Width, $Height)); $root.Arrange([Windows.Rect]::new(0,0,$Width,$Height)); $root.UpdateLayout()
            [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        }
    }
    function Test-UiTableBounds($View, $Table) {
        $route = Test-WtTestInputPath -View $View -Element $Table -Target $Table
        $presenter = Get-WtVisualChild $View ([Windows.Controls.ScrollContentPresenter])
        $padding = $View.Document.PagePadding
        $left = $presenter.TranslatePoint([Windows.Point]::new(0,0),$View).X + $padding.Left
        $right = $presenter.TranslatePoint([Windows.Point]::new($presenter.ActualWidth,0),$View).X - $padding.Right
        [pscustomobject]@{ LaidOut = -not $route.Bounds.IsEmpty; Ok = -not $route.Bounds.IsEmpty -and $route.Bounds.Left -ge $left - 1 -and $route.Bounds.Right -le $right + 1;
            Detail = "표=$($route.Bounds.Left)..$($route.Bounds.Right), 내용=$left..$right" }
    }
    # 읽기 전체 문서와 편집 단위 문서가 같은 상자와 완료 글 스타일을 쓴다.
    foreach ($unitView in $false, $true) {
        $view = New-WtMarkdownView -OnTask { param($line, $element) $global:uiTaskLine = $line }
        $root.Child = $view
        $body = "- [x] 완료 항목`n- [ ] 다음 항목"
        if ($unitView) {
            $doc = [Windows.Documents.FlowDocument]::new(); $doc.Style = (Get-WtStyleDictionary)['Md.Doc']; $view.Document = $doc
            foreach ($unit in (Get-WtMarkdownUnits $body)) { $doc.Blocks.Add((New-WtMarkdownUnitSection $view $unit)) }
        } else { Set-WtMarkdownText $view $body }
        Set-UiLayout
        $boxes = [Collections.Generic.List[object]]::new(); $links = [Collections.Generic.List[object]]::new(); $texts = [Collections.Generic.List[object]]::new()
        $pointer = $view.Document.ContentStart
        while ($pointer) {
            if ($pointer.GetPointerContext('Forward') -eq 'ElementStart') {
                $element = $pointer.GetAdjacentElement('Forward')
                if ($element -is [Windows.Documents.Run] -and $element.Style -in (Get-WtStyleDictionary)['Md.TaskBox'], (Get-WtStyleDictionary)['Md.TaskBox.Done']) { $boxes.Add($element) }
                if ($element -is [Windows.Documents.Hyperlink] -and $element.ToolTip -ceq '완료 표시 / 해제') { $links.Add($element) }
                if ($element -is [Windows.Documents.Span] -and $element.Style -eq (Get-WtStyleDictionary)['Md.TaskDone']) { $texts.Add($element) }
            }
            $pointer = $pointer.GetNextContextPosition('Forward')
        }
        Assert-WtTest "체크리스트 공통 모양: 편집 단위=$unitView · 완료 글자 3차 · 취소선 없음" (
            $boxes.Count -eq 2 -and $texts.Count -eq 1 -and $texts[0].Foreground.Color -eq $root.FindResource('B.Text.Tertiary').Color -and $texts[0].TextDecorations.Count -eq 0)
        # 상자는 아이콘 글자: 완료 = 채운 상자(체크는 바탕색으로 비어 보임) E73D Accent, 미완료 = 빈 상자 E739 Border.Control, 16
        Assert-WtTest "체크리스트 상자: 편집 단위=$unitView · 완료 E73D Accent · 미완료 E739 Border.Control · 16 · 링크 안" (
            $boxes[0].Text -ceq [string][char]0xE73D -and $boxes[0].Foreground.Color -eq $root.FindResource('B.Accent').Color -and
            $boxes[1].Text -ceq [string][char]0xE739 -and $boxes[1].Foreground.Color -eq $root.FindResource('B.Border.Control').Color -and
            $boxes[0].FontSize -eq 16 -and $boxes[0].Parent -is [Windows.Documents.Hyperlink] -and $boxes[1].Parent -is [Windows.Documents.Hyperlink])
        $global:uiTaskLine = 0
        $links[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
        Assert-WtTest "체크리스트 콜백: 편집 단위=$unitView · 줄 번호 유지" ($global:uiTaskLine -eq 1)
        foreach ($link in $links) {
            $route = Test-WtTestInputPath -View $view -Element $link.Inlines.FirstInline -Target $link
            Assert-WtTest "체크리스트 숨김 좌표 경로: 편집 단위=$unitView · Run 통과" $route.Ok $route.Path
        }
        $badBox = [Windows.Controls.CheckBox]::new(); $badBox.Style = (Get-WtStyleDictionary)['Check']
        $badBox.Width = 16; $badBox.Height = 16; $badBox.MinHeight = 16; $badBox.IsHitTestVisible = $false; $badBox.Focusable = $false
        $links[0].Inlines.Clear(); $links[0].Inlines.Add([Windows.Documents.InlineUIContainer]::new($badBox))
        Set-UiLayout
        $badRoute = Test-WtTestInputPath -View $view -Element $badBox -Target $links[0]
        Assert-WtTest "체크리스트 고장 대조군: 편집 단위=$unitView · CheckBox 경로=False" ($badRoute.Point -and $badRoute.Hit -and -not $badRoute.Ok -and -not $badRoute.Reached) $badRoute.Path
        Write-Host "대조군 CheckBox : 좌표=$($badRoute.Point) 경로=$($badRoute.Ok) 맞은 요소=$($badRoute.Hit.GetType().Name)"
        $global:uiTaskLine = 0; $links[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
        Assert-WtTest "체크리스트 고장 대조군 콜백: 편집 단위=$unitView · 경로 실패와 별개로 호출됨" ($global:uiTaskLine -eq 1)
    }
    $plain = New-WtMarkdownView; Set-WtMarkdownText $plain '- [ ] 표시만'
    $plainBox = $plain.Document.Blocks.FirstBlock.ListItems.FirstListItem.Blocks.FirstBlock.Inlines.FirstInline
    Assert-WtTest '체크리스트 OnTask 없음: 부착 전 링크·포커스 없음' ($plainBox -is [Windows.Documents.Run] -and $plainBox.Parent -isnot [Windows.Documents.Hyperlink] -and -not $plainBox.Focusable)
    $root.Child = $plain; Set-UiLayout
    $plainRoute = Test-WtTestInputPath -View $plain -Element $plainBox -Target $plainBox
    Assert-WtTest '체크리스트 OnTask 없음: 부착 뒤 표시 Run 도달 · 링크·포커스 없음' ($plainRoute.Ok -and $plainBox.Parent -isnot [Windows.Documents.Hyperlink] -and -not $plainBox.Focusable) $plainRoute.Path
    # 남는 열에서 폭을 가져오고, 화면이 정말 부족할 때만 최소 낱말 폭보다 작게 만든다.
    foreach ($unitView in $false, $true) {
        $view = New-WtMarkdownView -Scroll; $root.Child = $view
        $body = "| 호스트 | 구간 | 확인 포트 | 담당 역할 |`n| --- | --- | --- | --- |`n| SRV-01 | 내부망 | 443, 5985 | 웹 앞단 |`n| SRV-02 | 내부망 | 5432 | 데이터베이스 |`n| NAS-01 | 백업망 | 445, 2049 | 소산 스토리지 |"
        if ($unitView) {
            $doc = [Windows.Documents.FlowDocument]::new(); $doc.Style = (Get-WtStyleDictionary)['Md.Doc']; $view.Document = $doc
            foreach ($unit in (Get-WtMarkdownUnits $body)) { $doc.Blocks.Add((New-WtMarkdownUnitSection $view $unit)) }
            $table = $doc.Blocks.FirstBlock.Blocks.FirstBlock
        } else { Set-WtMarkdownText $view $body; $table = $view.Document.Blocks.FirstBlock }
        Set-UiLayout
        $word = New-WtText '내부망' 'T.Body'; $word.FontSize = $view.Document.FontSize
        $word.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
        $minWord = [Math]::Ceiling($word.DesiredSize.Width) + 24
        # 열 폭은 값이 아니라 실제로 놓인 칸 글 시작 x로 잰다(값만 보면 표가 깨져도 통과했다, 11-17)
        $cellX = { @(foreach ($c in $table.RowGroups[0].Rows[1].Cells) { $c.ContentStart.GetCharacterRect('Forward').X }) }
        $laidOut = { param($x) $ok = $x.Count -eq 4; for ($k = 1; $k -lt $x.Count; $k++) { $ok = $ok -and $x[$k] -gt $x[$k - 1] + 8 }; $ok -and $x[3] -lt $view.ViewportWidth - 20 }
        $x = & $cellX; $wide = $x[2] - $x[1]; $wideOk = & $laidOut $x
        $bounds = Test-UiTableBounds $view $table
        Assert-WtTest "표 실제 경계: 편집 단위=$unitView · 폭 544 내용 안" $bounds.Ok $bounds.Detail
        Set-UiLayout 400
        $x = & $cellX; $narrow = $x[2] - $x[1]; $narrowOk = & $laidOut $x
        $bounds = Test-UiTableBounds $view $table
        Assert-WtTest "표 실제 경계: 편집 단위=$unitView · 폭 400 내용 안" $bounds.Ok $bounds.Detail
        Assert-WtTest "표 낱말 최소 폭: 편집 단위=$unitView · 544/400 폭에서 내부망 한 덩어리 · 네 칸이 폭 안에 차례로" ($wideOk -and $narrowOk -and $wide -ge $minWord -and $narrow -ge $minWord) "wide=$wide narrow=$narrow min=$minWord"
        # 고정 폭(px)이면 문서 안쪽 폭 오차만큼 넘쳐 오른쪽 테두리가 잘리고, Star 값이 크면 첫 열이 다 가져간다 → 합 10의 비율
        Assert-WtTest "표 낱말 최소 폭: 편집 단위=$unitView · 열 폭은 합 10의 비율(Star)" (@($table.Columns | Where-Object { -not $_.Width.IsStar }).Count -eq 0 -and [Math]::Abs(($table.Columns | Measure-Object -Property { $_.Width.Value } -Sum).Sum - 10) -lt 0.01)
        Set-UiLayout 180
        $x = & $cellX
        Assert-WtTest "표 낱말 최소 폭: 편집 단위=$unitView · 전체 폭 부족하면 줄바꿈 허용" (($x[2] - $x[1]) -lt $minWord)
        Set-UiLayout
        $x = & $cellX
        Assert-WtTest "표 낱말 최소 폭: 편집 단위=$unitView · 다시 넓히면 복원" ((& $laidOut $x) -and ($x[2] - $x[1]) -ge $minWord)
        $tag = $table.Tag; $ratios = @($table.Columns | ForEach-Object { $_.Width.Value })
        try {
            $table.Tag = $null   # 고장 대조군의 폭을 정상 배치 함수가 고치지 않게 한다.
            foreach ($unit in 'Pixel','Star') {
                $budget = if ($unit -eq 'Pixel') { $view.ViewportWidth - 2 } else { 1000 }
                for ($i=0; $i -lt $table.Columns.Count; $i++) { $table.Columns[$i].Width = [Windows.GridLength]::new($ratios[$i] / 10 * $budget,$unit) }
                Set-UiLayout
                $bounds = Test-UiTableBounds $view $table
                Assert-WtTest "표 고장 대조군: 편집 단위=$unitView · $unit 실제 경계=False" ($bounds.LaidOut -and -not $bounds.Ok) $bounds.Detail
                Write-Host "대조군 $unit : 경계=$($bounds.Ok) $($bounds.Detail)"
            }
        } finally { $table.Tag = $tag; Set-WtDocumentTableWidths $table }
    }
    Write-Host '공통 화면 검사 PASS · FAIL 0'
} finally {
    if ($hostSource) { $hostSource.Dispose() }
    Stop-WtDataWrites -Milliseconds 3000; Stop-WtAllWork; Remove-WtTestData $test
}

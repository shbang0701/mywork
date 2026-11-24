<#
.SYNOPSIS
    공통 화면 부품을 숨김 호스트로 검사한다: 체크 줄 콜백·좌표 경로 · 표 낱말 폭·실제 경계·좁은 칸 가로 스크롤(좌표 경로 · 휠 · 복사 글) · 이름 묻는 창 · 저장 묻는 창(겹쳐 묻지 않음) · 폼 칸 값 · 입력칸 오류 · 단추 메뉴 자리 · 메뉴 항목(아이콘 자리 · 위험 항목) · 빈 화면 안내 · 설정 · 도움말 하위 탭의 첫 포커스.
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
    # 표는 가로 스크롤 칸 안의 문서다(값 문서 8절 메모 「표」). 칸이 넉넉하면 남는 열에서 폭을 가져와 글 폭을 채우고,
    # 모자라면 열을 낱말 최소 폭까지만 줄이고 표만 가로로 스크롤한다(11-24 승호: 좁은 칸에서 내/부/망처럼 한 자씩 쪼개지던 것)
    foreach ($unitView in $false, $true) {
        $view = New-WtMarkdownView -Scroll; $root.Child = $view
        $body = "| 호스트 | 구간 | 확인 포트 | 담당 역할 |`n| --- | --- | --- | --- |`n| SRV-01 | 내부망 | 443, 5985 | 웹 앞단 |`n| SRV-02 | 내부망 | 5432 | 데이터베이스 |`n| NAS-01 | 백업망 | 445, 2049 | 소산 스토리지 |" +
            ((1..30 | ForEach-Object { "`n`n뒤 문단 $_" }) -join '')
        if ($unitView) {
            $doc = [Windows.Documents.FlowDocument]::new(); $doc.Style = (Get-WtStyleDictionary)['Md.Doc']; $view.Document = $doc
            foreach ($unit in (Get-WtMarkdownUnits $body)) { $doc.Blocks.Add((New-WtMarkdownUnitSection $view $unit)) }
            $holder = $doc.Blocks.FirstBlock.Blocks.FirstBlock
        } else { Set-WtMarkdownText $view $body; $holder = $view.Document.Blocks.FirstBlock }
        Assert-WtTest "표 칸: 편집 단위=$unitView · 블록 > 가로 스크롤 > 읽기 전용 상자 > 표" (
            $holder -is [Windows.Documents.BlockUIContainer] -and $holder.Child -is [Windows.Controls.ScrollViewer] -and $holder.Child.Content -is [Windows.Controls.RichTextBox] -and
            $holder.Child.Content.IsReadOnly -and $holder.Child.Content.Document.Blocks.FirstBlock -is [Windows.Documents.Table]) "맨 앞 블록=$($holder.GetType().Name)"
        $scroll = $holder.Child; $box = Get-WtMarkdownTableView $holder; $table = $box.Document.Blocks.FirstBlock
        Set-UiLayout
        $word = New-WtText '내부망' 'T.Body'; $word.FontSize = $view.Document.FontSize
        $word.Measure([Windows.Size]::new([double]::PositiveInfinity,[double]::PositiveInfinity))
        $minWord = [Math]::Ceiling($word.DesiredSize.Width) + 24
        # 열 폭은 값이 아니라 실제로 놓인 칸 글 시작 x(보기 좌표)로 잰다(값만 보면 표가 깨져도 통과했다, 11-17)
        $cellX = { @(foreach ($c in $table.RowGroups[0].Rows[1].Cells) { $box.TranslatePoint([Windows.Point]::new($c.ContentStart.GetCharacterRect('Forward').X, 0), $view).X }) }
        $laidOut = { param($x) $ok = $x.Count -eq 4; for ($k = 1; $k -lt $x.Count; $k++) { $ok = $ok -and $x[$k] -gt $x[$k - 1] + 8 }; $ok -and $x[3] -lt $view.ViewportWidth - 20 }
        # 한 칸 글이 한 줄인가: 처음 글자와 끝 글자의 줄(y)이 같다
        $oneLine = { param($cell) [Math]::Abs($cell.ContentStart.GetCharacterRect('Forward').Y - $cell.ContentEnd.GetCharacterRect('Backward').Y) -lt 1 }
        $starOk = { @($table.Columns | Where-Object { -not $_.Width.IsStar }).Count -eq 0 -and [Math]::Abs(($table.Columns | Measure-Object -Property { $_.Width.Value } -Sum).Sum - 10) -lt 0.01 }
        $x = & $cellX; $wide = $x[2] - $x[1]; $wideOk = & $laidOut $x
        $bounds = Test-UiTableBounds $view $table
        Assert-WtTest "표 실제 경계: 편집 단위=$unitView · 폭 544 내용 안" $bounds.Ok $bounds.Detail
        Set-UiLayout 400
        $x = & $cellX; $narrow = $x[2] - $x[1]; $narrowOk = & $laidOut $x
        $bounds = Test-UiTableBounds $view $table
        Assert-WtTest "표 실제 경계: 편집 단위=$unitView · 폭 400 내용 안" $bounds.Ok $bounds.Detail
        Assert-WtTest "표 낱말 최소 폭: 편집 단위=$unitView · 544/400 폭에서 내부망 한 덩어리 · 네 칸이 폭 안에 차례로" ($wideOk -and $narrowOk -and $wide -ge $minWord -and $narrow -ge $minWord) "wide=$wide narrow=$narrow min=$minWord"
        # 고정 폭(px)이면 문서 안쪽 폭 오차만큼 넘쳐 오른쪽 테두리가 잘리고, Star 값이 크면 첫 열이 다 가져간다 → 합 10의 비율
        Assert-WtTest "표 낱말 최소 폭: 편집 단위=$unitView · 열 폭은 합 10의 비율(Star)" (& $starOk)
        Assert-WtTest "표 칸: 편집 단위=$unitView · 넉넉하면 가로 스크롤 없음 · 상자 폭은 칸에 맞춤" ($scroll.ComputedHorizontalScrollBarVisibility -ne 'Visible' -and $scroll.ScrollableWidth -lt 1 -and [double]::IsNaN($box.Width)) "막대=$($scroll.ComputedHorizontalScrollBarVisibility) 넘침=$($scroll.ScrollableWidth) 폭=$($box.Width)"
        Set-UiLayout 180
        $x = & $cellX; $cells = $table.RowGroups[0].Rows[1].Cells
        Assert-WtTest "표 좁은 칸: 편집 단위=$unitView · 열은 최소 폭 그대로(내부망 한 줄) · 표만 가로 스크롤" (
            ($x[2] - $x[1]) -ge $minWord -and (& $oneLine $cells[1]) -and $scroll.ComputedHorizontalScrollBarVisibility -eq 'Visible' -and $scroll.ScrollableWidth -gt 0 -and (& $starOk)) "열=$($x[2] - $x[1]) 최소=$minWord 한 줄=$(& $oneLine $cells[1]) 막대=$($scroll.ComputedHorizontalScrollBarVisibility) 넘침=$($scroll.ScrollableWidth)"
        $scrollBounds = Test-WtTestInputPath -View $view -Element $scroll -Target $scroll
        $presenter = Get-WtVisualChild $view ([Windows.Controls.ScrollContentPresenter])
        $contentRight = $presenter.TranslatePoint([Windows.Point]::new($presenter.ActualWidth, 0), $view).X
        $outerScroll = Get-WtVisualChild $view ([Windows.Controls.ScrollViewer])
        Assert-WtTest "표 좁은 칸: 편집 단위=$unitView · 스크롤 칸은 글 폭 안(본문은 가로로 넘치지 않음)" ($scrollBounds.Bounds.Right -le $contentRight + 1 -and $outerScroll.ScrollableWidth -lt 1) "칸 오른쪽=$($scrollBounds.Bounds.Right) 내용 오른쪽=$contentRight 본문 넘침=$($outerScroll.ScrollableWidth)"
        # 실제 좌표 경로: 스크롤 전에는 마지막 열 글이 칸 밖(대조군), 끝까지 옮기면 그 글에 닿는다
        $lastRun = $cells[3].Blocks.FirstBlock.Inlines.FirstInline
        $before = Test-WtTestInputPath -View $view -Element $lastRun -Target $lastRun
        $scroll.ScrollToRightEnd(); Set-UiLayout 180
        $after = Test-WtTestInputPath -View $view -Element $lastRun -Target $lastRun
        Assert-WtTest "표 좁은 칸 숨김 좌표 경로: 편집 단위=$unitView · 가로로 옮긴 뒤 마지막 열 글 도달(옮기기 전 대조군=False)" (-not $before.Ok -and $after.Ok -and $scroll.HorizontalOffset -gt 0) "전=$($before.Path) / 뒤=$($after.Path)"
        $hit = Get-WtMarkdownPositionFromPoint $view $after.Point
        Assert-WtTest "표 좁은 칸: 편집 단위=$unitView · 보기 좌표 → 표 안 글 자리(옮긴 만큼 따라감)" ($hit -and [object]::ReferenceEquals($hit.Parent, $lastRun) -and [object]::ReferenceEquals((Get-WtMarkdownTableBlock $hit), $holder)) "자리=$($hit.Parent)"
        # 휠: 표 위에서 굴려도 본문이 세로로 스크롤한다(안쪽 상자가 먹지 않게 바깥으로 넘김). 실제 입력 순서대로 미리 보기 → 보통 이벤트
        $outerScroll.ScrollToTop(); Set-UiLayout 180
        $sendWheel = { param($target, [switch]$NoPreview)
            $events = if ($NoPreview) { @([Windows.UIElement]::MouseWheelEvent) } else { @([Windows.UIElement]::PreviewMouseWheelEvent, [Windows.UIElement]::MouseWheelEvent) }
            foreach ($ev in $events) { $a = [Windows.Input.MouseWheelEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, -120); $a.RoutedEvent = $ev; $target.RaiseEvent($a); if ($a.Handled) { break } }
            Set-UiLayout 180 }
        & $sendWheel $lastRun -NoPreview
        $swallowed = $outerScroll.VerticalOffset
        & $sendWheel $lastRun
        Assert-WtTest "표 좁은 칸 휠: 편집 단위=$unitView · 표 위 세로 휠은 본문 스크롤(대조군: 바깥으로 넘기지 않으면 안쪽 상자가 먹음)" ($swallowed -eq 0 -and $outerScroll.VerticalOffset -gt 0) "넘기기 전=$swallowed 뒤=$($outerScroll.VerticalOffset)"
        # Shift+휠은 실제 키 상태를 읽어 시험 호스트에서 누를 수 없다: 같은 처리 함수를 Shift로 부른다(콜백 검사)
        $scroll.ScrollToLeftEnd(); Set-UiLayout 180
        $shiftWheel = [Windows.Input.MouseWheelEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, -120); $shiftWheel.RoutedEvent = [Windows.UIElement]::PreviewMouseWheelEvent
        & (Get-Module Markdown) { param($s, $e) Invoke-WtMdTableWheel $s $e $true } $scroll $shiftWheel; Set-UiLayout 180
        Assert-WtTest "표 좁은 칸 Shift+휠(콜백): 편집 단위=$unitView · 한 칸에 48씩 가로로" ($shiftWheel.Handled -and [Math]::Abs($scroll.HorizontalOffset - 48) -lt 0.5) "가로=$($scroll.HorizontalOffset)"
        $all = $view.Selection; $all.Select($view.Document.ContentStart, $view.Document.ContentEnd)
        $copied = Get-WtMarkdownSelectedText $view
        Assert-WtTest "표 칸: 편집 단위=$unitView · 바깥에서 고른 글(복사)에 표 글이 칸은 탭 · 행은 줄로 들어감" ($copied.Contains("SRV-01`t내부망`t443, 5985`t웹 앞단") -and $copied.Contains('뒤 문단 1')) $copied.Substring(0, [Math]::Min(80, $copied.Length))
        $view.Selection.Select($view.Document.ContentStart, $view.Document.ContentStart)
        Set-UiLayout
        $x = & $cellX
        Assert-WtTest "표 낱말 최소 폭: 편집 단위=$unitView · 다시 넓히면 복원(가로 스크롤 끔)" ((& $laidOut $x) -and ($x[2] - $x[1]) -ge $minWord -and $scroll.ComputedHorizontalScrollBarVisibility -ne 'Visible' -and [double]::IsNaN($box.Width)) "막대=$($scroll.ComputedHorizontalScrollBarVisibility)"
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
    # 표 칸 안 문서도 둘레 글자색을 따른다(인용 안 표는 인용 색)
    $quoteView = New-WtMarkdownView; $root.Child = $quoteView
    Set-WtMarkdownText $quoteView "> 인용 글`n>`n> | 가 | 나 |`n> |---|---|`n> | 1 | 2 |"
    Set-UiLayout
    $quoteHolder = $quoteView.Document.Blocks.FirstBlock.Blocks.LastBlock
    $quoteBox = Get-WtMarkdownTableView $quoteHolder
    Assert-WtTest '표 칸: 인용 안 표 글자색 = 인용 글자색' ($quoteBox -and $quoteBox.Document.Foreground.Color -eq $quoteView.Document.Blocks.FirstBlock.Foreground.Color -and
        $quoteBox.Document.Foreground.Color -ne $quoteView.Document.Foreground.Color) "표=$($quoteBox.Document.Foreground) 인용=$($quoteView.Document.Blocks.FirstBlock.Foreground) 문서=$($quoteView.Document.Foreground)"
    $styles = Get-WtStyleDictionary
    function Get-UiBounds($Element) { $Element.TransformToAncestor($root).TransformBounds([Windows.Rect]::new(0, 0, $Element.ActualWidth, $Element.ActualHeight)) }
    # 이름 묻는 창(Read-WtName): 창은 띄우지 않고 만든 내용(New-WtNameDialog)을 숨김 호스트에 붙여 모양 · 결과 · 좌표 경로를 본다.
    # 결과는 누름 이벤트 콜백까지다. 실제 창 · OS 입력 · Enter/Esc(IsDefault · IsCancel)는 WPF 기본 동작이라 여기서 보지 않는다
    $render = [Windows.Window].GetMethod('OnContentRendered', [Reflection.BindingFlags]'Instance,NonPublic')
    $press = { param($Button) $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)) }
    foreach ($case in @(
            @{ Name = '설명 · 처음 글'; Title = '업무로 저장'; Label = '업무 이름'; Note = '왼쪽 목록에 보일 이름을 정하세요. 예: PM 점검 · 서버실'; Text = '서버 점검' },
            @{ Name = '빈 칸만'; Title = '보기 저장'; Label = '보기 이름'; Note = ''; Text = '' })) {
        $dialog = & (Get-Module Ui) { param($c) New-WtNameDialog $c.Title $c.Label $c.Note $c.Text } $case
        $window = $dialog.Window; $content = $window.Content; $window.Content = $null; $root.Child = $content; Set-UiLayout 480 400
        $heading = Get-UiBounds $content.Children[0]; $box = Get-UiBounds $dialog.Box; $save = Get-UiBounds $dialog.Save; $cancel = Get-UiBounds $dialog.Cancel
        $above = if ($case.Note) { (Get-UiBounds $dialog.Body.Children[0]).Bottom + 8 } else { $heading.Bottom + 12 }
        # 창 제목줄은 Windows 메시지 상자처럼 앱 이름만, 본문 큰 제목이 질문 · 할 일이다(같은 글이 두 번 보이지 않게, 11-24 실사용)
        Assert-WtTest "이름 묻는 창 ($($case.Name)): 창 제목줄 WorkTool · 본문 제목 · 설명 한 줄 · 칸 이름 · 처음 글 · [저장] 주 버튼(Enter) · [취소](Esc) · 오류 줄 숨김" (
            $window.Title -ceq 'WorkTool' -and $window.Width -eq 480 -and $content.Children[0].Text -ceq $case.Title -and
            $dialog.Body.Children.Count -eq $(if ($case.Note) { 2 } else { 1 }) -and
            (-not $case.Note -or ($dialog.Body.Children[0].Text -ceq $case.Note -and $dialog.Body.Children[0].Style -eq $styles['T.Sub'])) -and
            $dialog.Box.Style -eq $styles['Input'] -and [Windows.Automation.AutomationProperties]::GetName($dialog.Box) -ceq $case.Label -and $dialog.Box.Text -ceq $case.Text -and
            @($dialog.Buttons.Children).Count -eq 2 -and [object]::ReferenceEquals($dialog.Buttons.Children[0], $dialog.Save) -and $dialog.Save.Style -eq $styles['Btn.Primary'] -and
            $dialog.Save.IsDefault -and -not $dialog.Save.IsCancel -and $dialog.Cancel.IsCancel -and -not $dialog.Cancel.IsDefault -and $dialog.Error.Visibility -eq 'Collapsed') (@(Get-WtTestTexts $content) -join ' | ')
        Assert-WtTest "이름 묻는 창 ($($case.Name)): 칸은 설명 아래 8(설명 없으면 제목 아래 12) · 폭 가득 · 높이 32, 단추는 오른쪽 끝에 사이 8 · 칸 아래 24" (
            $box.Top -eq $above -and $box.Width -eq $heading.Width -and $box.Height -eq 32 -and
            $save.Right + 8 -eq $cancel.Left -and $cancel.Right -eq $heading.Right -and $save.Top - $box.Bottom -eq 24) "칸=$box 저장=$save 취소=$cancel 제목=$heading"
        [void]$render.Invoke($window, @([EventArgs]::Empty))
        Assert-WtTest "이름 묻는 창 ($($case.Name)): 열리면 칸에 포커스 · 처음 글을 모두 골라 둠" ($dialog.Box.IsFocused -and $dialog.Box.SelectionLength -eq $case.Text.Length) "포커스=$($dialog.Box.IsFocused) 고름=$($dialog.Box.SelectionLength)"
        foreach ($target in $dialog.Box, $dialog.Save, $dialog.Cancel) {
            $route = Test-WtTestInputPath -View $root -Element $target -Target $target
            Assert-WtTest "이름 묻는 창 ($($case.Name)) 숨김 좌표 경로: $(if ($target -is [Windows.Controls.TextBox]) { '칸' } else { $target.Content })" $route.Ok $route.Path
        }
        $dialog.Box.Text = '   '; & $press $dialog.Save; Set-UiLayout 480 400
        $blank = $dialog.Error.Visibility -eq 'Visible' -and $dialog.Error.Text -ceq '이름을 넣으세요.' -and $window.Tag.Result -ceq ''
        # 띄우지 않은 창이라 닫기(DialogResult)에서 멈춘다. 그 앞에서 결과를 남겼는지 본다
        $dialog.Box.Text = ' PM 점검 '; $closing = $false
        try { & $press $dialog.Save } catch { $closing = $_.Exception.Message -match 'DialogResult' }
        Assert-WtTest "이름 묻는 창 ($($case.Name)): 비우고 저장하면 오류 줄 · 결과 없음, 이름은 앞뒤 공백을 빼고 돌려준 뒤 닫는다" ($blank -and $window.Tag.Result -ceq 'PM 점검' -and $closing) "오류=$($dialog.Error.Text) 결과=[$($window.Tag.Result)] 닫기=$closing"
        $root.Child = $null
    }
    $dialog.Save.IsHitTestVisible = $false; $root.Child = $content; Set-UiLayout 480 400
    $badRoute = Test-WtTestInputPath -View $root -Element $dialog.Save -Target $dialog.Save
    Assert-WtTest '이름 묻는 창 고장 대조군: 누름을 받지 않는 [저장]은 좌표 경로=False' ($badRoute.Point -and -not $badRoute.Ok) $badRoute.Path
    $root.Child = $null
    # 저장 묻는 창(Read-WtSaveChoice, 고친 폼을 떠날 때): 띄우지 않고 만든 내용을 숨김 호스트에 붙여 모양 · 단추 순서 · 결과 · 좌표 경로를 본다
    # 제목 = 질문 「변경 내용을 저장할까요?」, [저장](주 · Enter) [저장 안 함] [취소](Esc), 주 버튼이 왼쪽(apps/design.md 13장). 실제 창 · OS 입력은 보지 않는다
    foreach ($case in @(@{ Pick = 'save'; Button = 'Save' }, @{ Pick = 'discard'; Button = 'Discard' })) {
        $choice = & (Get-Module Ui) { New-WtSaveChoiceDialog '「점검」 일정에서 고친 내용이 저장되지 않았습니다.' }
        $window = $choice.Window; $content = $window.Content; $window.Content = $null; $root.Child = $content; Set-UiLayout 480 300
        $buttons = @($choice.Buttons.Children)
        $save = Get-UiBounds $choice.Save; $discard = Get-UiBounds $choice.Discard; $cancel = Get-UiBounds $choice.Cancel; $heading = Get-UiBounds $content.Children[0]
        Assert-WtTest "저장 묻는 창: 창 제목줄 WorkTool · 본문 제목 질문 · 한 문장 · [저장] 주 버튼(Enter) · [저장 안 함] · [취소](Esc) 순서로 오른쪽 끝에 사이 8 · 처음 답은 취소" (
            $window.Title -ceq 'WorkTool' -and $content.Children[0].Text -ceq '변경 내용을 저장할까요?' -and
            (@(Get-WtTestTexts $choice.Body) -join '|') -ceq '「점검」 일정에서 고친 내용이 저장되지 않았습니다.' -and
            $buttons.Count -eq 3 -and (@($buttons | ForEach-Object { [string]$_.Content }) -join ',') -ceq '저장,저장 안 함,취소' -and
            $choice.Save.Style -eq $styles['Btn.Primary'] -and $choice.Discard.Style -eq $styles['Btn'] -and $choice.Cancel.Style -eq $styles['Btn'] -and
            $choice.Save.IsDefault -and -not $choice.Save.IsCancel -and $choice.Cancel.IsCancel -and -not $choice.Discard.IsDefault -and -not $choice.Discard.IsCancel -and
            $save.Right + 8 -eq $discard.Left -and $discard.Right + 8 -eq $cancel.Left -and $cancel.Right -eq $heading.Right -and $window.Tag.Choice -ceq 'cancel') "저장=$save 안 함=$discard 취소=$cancel"
        foreach ($target in $choice.Save, $choice.Discard, $choice.Cancel) {
            $route = Test-WtTestInputPath -View $root -Element $target -Target $target
            Assert-WtTest "저장 묻는 창 숨김 좌표 경로: $($target.Content)" $route.Ok $route.Path
        }
        [void]$render.Invoke($window, @([EventArgs]::Empty))
        $focused = $choice.Save.IsFocused
        # 띄우지 않은 창이라 닫기(DialogResult)에서 멈춘다. 그 앞에서 답을 남겼는지 본다
        $closing = $false
        try { & $press $choice[$case.Button] } catch { $closing = $_.Exception.Message -match 'DialogResult' }
        Assert-WtTest "저장 묻는 창: 열리면 [저장]에 포커스 · [$($choice[$case.Button].Content)] 누르면 답 $($case.Pick) · 닫기" ($focused -and $window.Tag.Choice -ceq $case.Pick -and $closing) "포커스=$focused 답=$($window.Tag.Choice) 닫기=$closing"
        $root.Child = $null
    }
    # 저장 묻는 창이 떠 있는 동안 또 물으면(트레이 → 종료 · 창이 뜨기 전에 온 클릭) 겹쳐 띄우지 않고 취소로 답한다.
    # 창은 띄우지 않는 가짜로 바꾼다: 가짜 창이 떠 있는 동안 한 번 더 묻고, 닫힌 뒤 다시 물으면 평소대로 창을 만든다
    $overlap = & (Get-Module Ui) {
        $realDialog = (Get-Item function:New-WtSaveChoiceDialog).ScriptBlock
        $script:fakeMade = 0; $script:fakeDepth = 0; $script:fakeNested = @()
        function script:New-WtSaveChoiceDialog([string]$Text) {
            $script:fakeMade++
            $fakeWindow = [pscustomobject]@{ Tag = @{ Choice = 'save' } }
            $fakeWindow | Add-Member ScriptMethod ShowDialog { $script:fakeDepth++; if ($script:fakeDepth -le 1) { $script:fakeNested += Read-WtSaveChoice '또 묻기' } }
            [pscustomobject]@{ Window = $fakeWindow }
        }
        try { $first = Read-WtSaveChoice '처음'; $later = Read-WtSaveChoice '닫힌 뒤'; "$first|$($script:fakeNested -join ',')|$later|$script:fakeMade" }
        finally { Set-Item function:script:New-WtSaveChoiceDialog $realDialog; $script:saveChoiceOpen = $false }
    }
    Assert-WtTest '저장 묻는 창: 떠 있는 동안 또 물으면 겹쳐 띄우지 않고 취소, 닫힌 뒤에는 다시 묻는다' ($overlap -ceq 'save|cancel|save|2') $overlap
    # 편집 폼 칸 값(Get-WtFormState, 고친 폼인지 볼 때): 이름 순 「이름=값」 줄. 고르기 칸은 고른 항목, 체크 상자 묶음은 고른 Tag
    $stateText = [Windows.Controls.TextBox]::new(); $stateText.Text = '점검'
    $stateCombo = [Windows.Controls.ComboBox]::new(); [void]$stateCombo.Items.Add('근무'); [void]$stateCombo.Items.Add('휴가'); $stateCombo.SelectedIndex = 1
    $stateCheck = [Windows.Controls.CheckBox]::new(); $stateCheck.IsChecked = $true
    $stateDays = [Windows.Controls.WrapPanel]::new()
    foreach ($tag in 'mon', 'tue', 'wed') { $dayCheck = [Windows.Controls.CheckBox]::new(); $dayCheck.Tag = $tag; $dayCheck.IsChecked = $tag -cne 'tue'; [void]$stateDays.Children.Add($dayCheck) }
    $stateFields = @{ title = $stateText; kind = $stateCombo; allDay = $stateCheck; days = $stateDays }
    $stateBefore = Get-WtFormState $stateFields
    $stateDays.Children[1].IsChecked = $true; $stateAfter = Get-WtFormState $stateFields
    Assert-WtTest '편집 폼 칸 값(Get-WtFormState): 이름 순 · 글 칸 · 고른 항목 · 체크 · 묶음의 고른 Tag, 체크 하나만 바꿔도 달라진다' (
        $stateBefore -ceq "allDay=True`ndays=mon,wed`nkind=휴가`ntitle=점검" -and $stateAfter -ceq "allDay=True`ndays=mon,tue,wed`nkind=휴가`ntitle=점검") "$stateBefore / $stateAfter"
    # 입력칸 오류(Set-WtInputError): 글 바인딩이 없는 칸도 빨간 선 · 칸 안 오른쪽 오류 아이콘 · 이유 툴팁, 빈 문구로 지운다. 글 칸이 아니면 그대로
    $errorBox = [Windows.Controls.TextBox]::new(); Set-WtStyle $errorBox 'Input'; $errorBox.Width = 240
    $plainCombo = [Windows.Controls.ComboBox]::new()
    $errorPanel = New-WtStack; [void](Add-WtChild $errorPanel $errorBox); [void](Add-WtChild $errorPanel $plainCombo)
    $root.Child = $errorPanel; Set-UiLayout 480 200
    Set-WtInputError $errorBox '시각을 확인하세요. 예: 09:00'; Set-WtInputError $plainCombo '고르세요.'; Set-UiLayout 480 200
    $icon = $errorBox.Template.FindName('ErrorIcon', $errorBox); $boxRect = Get-UiBounds $errorBox; $iconRect = Get-UiBounds $icon
    $marked = [Windows.Controls.Validation]::GetHasError($errorBox) -and $icon.Visibility -eq 'Visible' -and $errorBox.BorderBrush.Color -eq $root.FindResource('B.Status.Error.Icon').Color -and
        [string]$errorBox.ToolTip -ceq '시각을 확인하세요. 예: 09:00' -and $iconRect.Left -gt $boxRect.Left + $boxRect.Width / 2 -and $iconRect.Right -le $boxRect.Right -and -not [Windows.Controls.Validation]::GetHasError($plainCombo)
    Set-WtInputError $errorBox ''; Set-UiLayout 480 200
    Assert-WtTest '입력칸 오류: 빨간 선 · 칸 안 오른쪽 오류 아이콘 · 이유 툴팁, 빈 문구로 지움, 글 칸이 아니면 그대로' (
        $marked -and -not [Windows.Controls.Validation]::GetHasError($errorBox) -and $icon.Visibility -eq 'Collapsed' -and $errorBox.BorderBrush.Color -eq $root.FindResource('B.Border.Control').Color) "선=$($errorBox.BorderBrush) 아이콘=$($icon.Visibility) 칸=$boxRect 아이콘자리=$iconRect"
    $root.Child = $null

    # ---- 11-24 실사용 보고: 입력 칸 공통 동작 ----
    # 시각 칸 글(ConvertFrom-WtTimeInput): 0900 · 900 · 9:00 · 9도 09:00으로 받고, 틀린 글은 $null. 틀렸을 때 문구는 사람 말(HH:mm 같은 형식 기호 없음)
    $timeCases = [ordered]@{ '09:00' = '09:00'; '9:00' = '09:00'; '0900' = '09:00'; '900' = '09:00'; '9' = '09:00'; ' 22 ' = '22:00'; '2200' = '22:00'; '0' = '00:00'; '23:59' = '23:59'
        '2400' = $null; '9:60' = $null; '25' = $null; '09:0' = $null; '12345' = $null; 'abc' = $null; '' = $null; '9시' = $null; '9.00' = $null; '１２' = $null; '-9' = $null }
    $timeBad = @(foreach ($k in $timeCases.Keys) { $got = ConvertFrom-WtTimeInput $k; if ($got -cne $timeCases[$k]) { "[$k]→[$got]" } })
    Assert-WtTest '시각 칸 글: 0900 · 900 · 9:00 · 9 → 09:00, 틀린 글은 못 읽음, 문구는 「시각은 09:00처럼 입력하세요.」' (
        -not $timeBad.Count -and (Get-WtTimeInputHint) -ceq '시각은 09:00처럼 입력하세요.') ($timeBad -join ' ')
    # 한 줄 입력 칸에 Tab · Shift+Tab으로 들어가면 글 전체를 고른다(그림 01: Tab으로 들어간 시각 칸에 22:00을 쳐서 22:0009:00).
    # 실제 키 경로: Tab 키를 입력 관리자에 넣으면 WPF 키보드 이동이 포커스를 옮긴다. 키보드 상태(Tab이 눌려 있는지)만 검사용 값으로 바꾼다.
    # Shift+Tab은 WPF가 하는 대로 앞 칸으로 이동(MoveFocus Previous). 마우스 · 코드 포커스는 커서 그대로, 여러 줄 칸은 고르지 않는다
    $uiModule = Get-Module Ui
    & $uiModule { $script:testTab = $false; $script:testMods = [Windows.Input.ModifierKeys]::None
        $script:realTab = (Get-Item function:Test-WtTabNavigation).ScriptBlock; $script:realMods = (Get-Item function:Get-WtKeyModifiers).ScriptBlock
        function script:Test-WtTabNavigation { $script:testTab }
        function script:Get-WtKeyModifiers { $script:testMods } }
    $sendKey = { param([string]$Key) $a = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $hostSource, 0, [Windows.Input.Key]$Key); $a.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent; [void][Windows.Input.InputManager]::Current.ProcessInput($a) }
    $keyForm = New-WtStack Vertical 8
    $titleBox = [Windows.Controls.TextBox]::new(); Set-WtStyle $titleBox 'Input'; $titleBox.Text = '점검'
    $allDayCheck = [Windows.Controls.CheckBox]::new(); Set-WtStyle $allDayCheck 'Check'; $allDayCheck.Content = '하루 종일'
    $timeBox = [Windows.Controls.TextBox]::new(); Set-WtStyle $timeBox 'Setting.Time'; $timeBox.Text = '09:00'
    $kindCombo = [Windows.Controls.ComboBox]::new(); Set-WtStyle $kindCombo 'Combo'; foreach ($v in '근무', '휴가') { [void]$kindCombo.Items.Add($v) }; $kindCombo.SelectedIndex = 0
    $noteBox = [Windows.Controls.TextBox]::new(); Set-WtStyle $noteBox 'Attendance.Note'; $noteBox.Text = '메모'
    foreach ($c in $titleBox, $allDayCheck, $timeBox, $kindCombo, $noteBox) { [void](Add-WtChild $keyForm $c) }
    $root.Child = $keyForm; Set-UiLayout 480 400
    try {
        & $uiModule { $script:testTab = $true }
        [void]$allDayCheck.Focus(); & $sendKey Tab
        $tabIn = "$($timeBox.IsKeyboardFocused)|$($timeBox.SelectedText)"
        [void]$allDayCheck.MoveFocus([Windows.Input.TraversalRequest]::new([Windows.Input.FocusNavigationDirection]::Previous))
        $shiftTabIn = "$($titleBox.IsKeyboardFocused)|$($titleBox.SelectedText)"
        [void]$kindCombo.Focus(); & $sendKey Tab
        $multiIn = "$($noteBox.IsKeyboardFocused)|$($noteBox.SelectionLength)"
        & $uiModule { $script:testTab = $false }
        $timeBox.CaretIndex = 2; [void]$titleBox.Focus(); [void]$timeBox.Focus()
        $codeIn = "$($timeBox.IsKeyboardFocused)|$($timeBox.SelectionLength)|$($timeBox.CaretIndex)"
        Assert-WtTest '한 줄 입력 칸 Tab(실제 키 경로) · Shift+Tab은 글 전체 선택(Input 바탕 스타일도), 여러 줄 칸 · 코드(마우스) 포커스는 커서 그대로' (
            $tabIn -ceq 'True|09:00' -and $shiftTabIn -ceq 'True|점검' -and $multiIn -ceq 'True|0' -and $codeIn -ceq 'True|0|2') "Tab $tabIn · Shift+Tab $shiftTabIn · 여러 줄 $multiIn · 코드 $codeIn"
        # 시각 칸(Register-WtTimeInput): 칸을 떠나면 0900 → 09:00, 못 읽는 글은 그대로(오류 표시는 저장하는 쪽)
        Register-WtTimeInput $timeBox
        $timeBox.Text = '0900'; [void]$timeBox.Focus(); [void]$titleBox.Focus(); $leftGood = $timeBox.Text
        $timeBox.Text = '9시'; [void]$timeBox.Focus(); [void]$titleBox.Focus(); $leftBad = $timeBox.Text
        $timeBox.Text = '930'; Update-WtTimeInput $timeBox; $direct = $timeBox.Text
        Assert-WtTest '시각 칸: 떠날 때 0900 → 09:00, 못 읽는 글은 그대로, 저장 전 Update-WtTimeInput도 같은 모양(930 → 09:30)' ($leftGood -ceq '09:00' -and $leftBad -ceq '9시' -and $direct -ceq '09:30') "$leftGood / $leftBad / $direct"
        # 폼 저장 키(Register-WtFormSaveKeys): 한 줄 칸 Enter · 어디서든 Ctrl+S는 저장, 여러 줄 칸 Enter는 줄 바꿈, 고르기 칸 · 체크 상자의 Enter는 저장 아님
        $global:uiSaves = 0
        Register-WtFormSaveKeys $keyForm { $global:uiSaves++ }
        [void]$titleBox.Focus(); & $sendKey Return; $enterSingle = $global:uiSaves
        $noteBox.CaretIndex = $noteBox.Text.Length; [void]$noteBox.Focus(); & $sendKey Return; $enterMulti = "$global:uiSaves|$($noteBox.Text -match "`n")"
        [void]$kindCombo.Focus(); & $sendKey Return; [void]$allDayCheck.Focus(); & $sendKey Return; $enterOther = $global:uiSaves
        & $uiModule { $script:testMods = [Windows.Input.ModifierKeys]::Control }
        [void]$allDayCheck.Focus(); & $sendKey S; [void]$noteBox.Focus(); & $sendKey S; $ctrlS = $global:uiSaves
        & $uiModule { $script:testMods = [Windows.Input.ModifierKeys]::Shift }
        [void]$titleBox.Focus(); & $sendKey Return; $shiftEnter = $global:uiSaves
        & $uiModule { $script:testMods = [Windows.Input.ModifierKeys]::None }
        Assert-WtTest '폼 저장 키(실제 키 경로): 한 줄 칸 Enter · 체크 상자 · 여러 줄 칸에서도 Ctrl+S는 저장, 여러 줄 칸 Enter는 줄 바꿈, 고르기 칸 · 체크 상자 Enter · Shift+Enter는 저장 아님' (
            $enterSingle -eq 1 -and $enterMulti -ceq '1|True' -and $enterOther -eq 1 -and $ctrlS -eq 3 -and $shiftEnter -eq 3) "$enterSingle / $enterMulti / $enterOther / $ctrlS / $shiftEnter"
        # 틀린 칸 포커스(Set-WtInputFocus): 글 칸은 글 전체 선택, 칸 묶음은 첫 칸, 끈 칸은 옮기지 않음
        $days = [Windows.Controls.Primitives.UniformGrid]::new(); $days.Columns = 2
        foreach ($n in '월', '화') { $d = [Windows.Controls.CheckBox]::new(); $d.Content = $n; [void]$days.Children.Add($d) }
        [void](Add-WtChild $keyForm $days); Set-UiLayout 480 400
        $timeBox.Text = '25:00'; [void]$titleBox.Focus()
        $focusText = "$(Set-WtInputFocus $timeBox)|$($timeBox.IsKeyboardFocused)|$($timeBox.SelectedText)"
        $focusGroup = "$(Set-WtInputFocus $days)|$($days.Children[0].IsKeyboardFocused)"
        $titleBox.IsEnabled = $false; $focusOff = "$(Set-WtInputFocus $titleBox)|$($days.Children[0].IsKeyboardFocused)"; $titleBox.IsEnabled = $true
        Assert-WtTest '틀린 칸 포커스: 글 칸은 포커스 + 글 전체 선택, 칸 묶음은 첫 칸, 끈 칸은 옮기지 않음' (
            $focusText -ceq 'True|True|25:00' -and $focusGroup -ceq 'True|True' -and $focusOff -ceq 'False|True') "$focusText / $focusGroup / $focusOff"
        # 설정 → 업무시간 시각 칸(그림 02와 같은 규칙): 830은 칸을 떠날 때, 1730은 Enter(실제 키 경로)로 저장하며 칸 글도 바뀐다. 못 읽는 글은 사람 말 오류 · 저장 안 함
        $root.Child = $null
        $workForm = & (Get-Module Pages) { New-WtWorkHoursForm }
        $root.Child = $workForm.Root; Set-UiLayout 680 600
        $startBox = $workForm.Boxes['work.start']; $endBox = $workForm.Boxes['work.end']
        $startBox.Text = '830'; [void]$startBox.Focus(); [void]$endBox.Focus()
        $leaveSave = "$($startBox.Text)|$((Get-WtWorkHours)['work.start'])"
        $endBox.Text = '1730'; [void]$endBox.Focus(); & $sendKey Return
        $enterSave = "$($endBox.Text)|$((Get-WtWorkHours)['work.end'])"
        $startBox.Text = '8시'; [void]$startBox.Focus(); [void]$endBox.Focus()
        $badSave = "$($workForm.Errors['work.start'].Text)|$((Get-WtWorkHours)['work.start'])|$([Windows.Controls.Validation]::GetHasError($startBox))"
        Set-WtWorkHours @{ 'work.days' = @(1, 2, 3, 4, 5); 'work.start' = '09:00'; 'work.end' = '18:00'; 'work.lunchStart' = '12:00'; 'work.lunchEnd' = '13:00'; 'work.halfDay' = '' }
        Assert-WtTest '설정 업무시간 시각 칸: 830 → 08:30(떠날 때) · 1730 → 17:30(Enter)으로 저장 · 칸 글도 바뀜, 못 읽는 글은 「시각은 09:00처럼 입력하세요.」 · 저장 안 함' (
            $leaveSave -ceq '08:30|08:30' -and $enterSave -ceq '17:30|17:30' -and $badSave -ceq '시각은 09:00처럼 입력하세요.|08:30|True') "$leaveSave / $enterSave / $badSave"
    } finally {
        $root.Child = $null
        & $uiModule { Set-Item function:script:Test-WtTabNavigation $script:realTab; Set-Item function:script:Get-WtKeyModifiers $script:realMods }
    }
    # 단추 펼침 메뉴 자리(Set-WtButtonMenuPlacement): 오른쪽 끝 단추는 메뉴 오른쪽 끝을 단추 오른쪽 끝에 맞춰 단추 바로 아래. 팝업은 띄우지 않고 WPF가 쓰는 배치 함수로 계산한다
    $edgeButton = New-WtButton '' -Kind Icon -Icon 0xE710; $edgeButton.HorizontalAlignment = 'Right'; $edgeButton.VerticalAlignment = 'Top'
    $edgeButton.ContextMenu = New-WtHomePinContextMenu
    foreach ($name in '새 일정', '새 루틴') { [void]$edgeButton.ContextMenu.Items.Add((New-WtMenuItem $name { })) }
    $edgeHost = [Windows.Controls.Grid]::new(); [void]$edgeHost.Children.Add($edgeButton)
    $root.Child = $edgeHost; Set-UiLayout 400 300
    $edgeMenu = $edgeButton.ContextMenu
    $edgeMenu.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $edgeMenu.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $sizeParameters = [Windows.Interop.HwndSourceParameters]::new('UI menu size'); $sizeParameters.WindowStyle = 0; $sizeParameters.Width = 300; $sizeParameters.Height = 300
    $sizeSource = [Windows.Interop.HwndSource]::new($sizeParameters)
    try { $sizeSource.RootVisual = $edgeMenu; $edgeMenu.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity)); $edgeSize = $edgeMenu.DesiredSize }
    finally { $sizeSource.RootVisual = $null; $sizeSource.Dispose() }
    $edge = Get-UiBounds $edgeButton
    Set-WtButtonMenuPlacement $edgeButton -Right
    $placedRight = @($edgeMenu.CustomPopupPlacementCallback.Invoke($edgeSize, [Windows.Size]::new($edgeButton.ActualWidth, $edgeButton.ActualHeight), [Windows.Point]::new(0, 0)))[0].Point
    $rightOk = $edgeMenu.Placement -eq 'Custom' -and [object]::ReferenceEquals($edgeMenu.PlacementTarget, $edgeButton) -and
        [Math]::Abs($edge.Left + $placedRight.X + $edgeSize.Width - $edge.Right) -lt 0.5 -and [Math]::Abs($placedRight.Y - $edgeButton.ActualHeight) -lt 0.5 -and $edge.Left + $placedRight.X + $edgeSize.Width -le 400
    Set-WtButtonMenuPlacement $edgeButton
    Assert-WtTest '단추 펼침 메뉴 자리: -Right면 메뉴 오른쪽 끝을 단추 오른쪽 끝에 맞춰 바로 아래(창 안), 없으면 단추 아래(Bottom)' (
        $rightOk -and $edgeMenu.Placement -eq 'Bottom' -and $edge.Left + $edgeSize.Width -gt 400) "단추=$edge 메뉴=$edgeSize 자리=$placedRight"
    $root.Child = $null
    # 메뉴 항목(New-WtMenuItem · New-WtMenuCaption): 메뉴는 부모를 가질 수 없어서 공통 메뉴를 숨김 호스트의 맨 위 요소로 두고 연 것처럼 배치한다.
    # 누름은 UIA 누르기라 클릭과 같은 MenuItem 경로를 탄다. 팝업 창 · OS 입력은 보지 않는다
    $menu = New-WtHomePinContextMenu
    $menu.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $menu.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $global:uiMenuPicked = [Collections.Generic.List[object]]::new()
    $menuItems = @((New-WtMenuCaption '정렬'), (New-WtMenuItem '제목' { param($v) $global:uiMenuPicked.Add($v) } 'title' -Checked),
        (New-WtMenuItem '수정일' { param($v) $global:uiMenuPicked.Add($v.By) } @{ By = 'updated' }), (New-WtMenuItem '수동' { $global:uiMenuPicked.Add('값 없음') }))
    foreach ($item in $menuItems) { [void]$menu.Items.Add($item) }
    $invokeItem = { param($Item) ([Windows.Automation.Provider.IInvokeProvider]([Windows.Automation.Peers.MenuItemAutomationPeer]::new($Item).GetPattern([Windows.Automation.Peers.PatternInterface]::Invoke))).Invoke() }
    $menuParameters = [Windows.Interop.HwndSourceParameters]::new('UI menu test'); $menuParameters.WindowStyle = 0; $menuParameters.Width = 300; $menuParameters.Height = 300
    $menuSource = [Windows.Interop.HwndSource]::new($menuParameters)
    try {
        $menuSource.RootVisual = $menu
        [void]$menu.ApplyTemplate(); $menu.Measure([Windows.Size]::new(300, 300)); $menu.Arrange([Windows.Rect]::new(0, 0, 300, 300)); $menu.UpdateLayout()
        $headers = @($menuItems | ForEach-Object { [string]$_.Header }) -join ','
        Assert-WtTest '공통 메뉴 항목: 묶음 이름은 누를 수 없는 흐린 줄, 고른 항목은 앞에 ✓, 줄 높이 32' (
            $headers -ceq '정렬,✓ 제목,수정일,수동' -and -not $menuItems[0].IsEnabled -and @($menuItems[1..3] | Where-Object IsEnabled).Count -eq 3 -and
            $menuItems[0].Foreground.Color -eq $menu.FindResource('B.Text.Disabled').Color -and -not @($menuItems | Where-Object { $_.ActualHeight -ne 32 }).Count) "$headers / 높이 $(@($menuItems | ForEach-Object ActualHeight) -join ',')"
        foreach ($item in $menuItems[1..3]) {
            $route = Test-WtTestInputPath -View $menu -Element $item -Target $item
            Assert-WtTest "공통 메뉴 항목 숨김 좌표 경로: $($item.Header)" $route.Ok $route.Path
        }
        $captionRoute = Test-WtTestInputPath -View $menu -Element $menuItems[0] -Target $menuItems[0]
        Assert-WtTest '공통 메뉴 항목: 묶음 이름 자리를 눌러도 그 줄에 닿지 않는다 (좌표 경로=False)' ($captionRoute.Point -and -not $captionRoute.Ok) $captionRoute.Path
        foreach ($item in $menuItems[1..3]) { & $invokeItem $item }
        [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $captionBlocked = $false
        try { & $invokeItem $menuItems[0] } catch { $captionBlocked = $true }
        Assert-WtTest '공통 메뉴 항목: 누르면 그 항목의 값으로 한 번씩 부르고(값 없는 항목도), 묶음 이름은 누를 수 없다' (($global:uiMenuPicked -join ',') -ceq 'title,updated,값 없음' -and $captionBlocked) ($global:uiMenuPicked -join ',')
    } finally { $menuSource.Dispose() }
    # 11-24 둘째 판 그룹 D: 메뉴 항목 왼쪽 아이콘(Font.Icon 16 · B.Text.Secondary, 글자와 사이 12) · 위험 항목(글자 · 아이콘 Btn.Danger 빨강) · 하위 메뉴 머리 아이콘.
    # 아이콘 없는 항목은 자리를 잡지 않아 다른 탭 메뉴 모양(글자 왼쪽 12) 그대로다. 숨김 호스트에 배치해 실제 좌표를 잰다
    $findText = {
        param($Root, [string]$Text)
        $queue = [Collections.Generic.Queue[Windows.DependencyObject]]::new(); $queue.Enqueue($Root)
        while ($queue.Count) {
            $node = $queue.Dequeue()
            if ($node -is [Windows.Controls.TextBlock] -and $node.Text -ceq $Text) { return $node }
            for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $i++) { $queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($node, $i)) }
        }
    }
    $dangerProbe = New-WtButton '삭제' -Kind Danger
    $root.Child = $dangerProbe; Set-UiLayout
    $dangerColor = $dangerProbe.Foreground.Color
    $root.Child = $null
    $iconMenu = New-WtHomePinContextMenu
    $iconMenu.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $iconMenu.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $global:uiIconPicked = [Collections.Generic.List[object]]::new()
    $iconItems = @((New-WtMenuItem '새 탭에서 열기' { param($v) $global:uiIconPicked.Add($v) } 'open' -Icon 0xE8A7), (New-WtMenuItem '꺼진 항목' { } -Icon 0xE7B8),
        (New-WtSubmenuItem '폴더로 옮기기' -Icon 0xE8DE), (New-WtMenuItem '삭제' { param($v) $global:uiIconPicked.Add($v) } 'delete' -Icon 0xE74D -Danger),
        (New-WtMenuItem '꺼진 위험' { } -Icon 0xE74D -Danger), (New-WtMenuItem '아이콘 없음' { }))
    [void]$iconItems[2].Items.Add((New-WtMenuItem '폴더 없음' { }))
    $iconItems[1].IsEnabled = $false; $iconItems[4].IsEnabled = $false
    foreach ($item in $iconItems[0..2]) { [void]$iconMenu.Items.Add($item) }
    [void]$iconMenu.Items.Add([Windows.Controls.Separator]::new())
    foreach ($item in $iconItems[3..5]) { [void]$iconMenu.Items.Add($item) }
    $iconParameters = [Windows.Interop.HwndSourceParameters]::new('UI menu icon test'); $iconParameters.WindowStyle = 0; $iconParameters.Width = 320; $iconParameters.Height = 400
    $iconSource = [Windows.Interop.HwndSource]::new($iconParameters)
    try {
        $iconSource.RootVisual = $iconMenu
        [void]$iconMenu.ApplyTemplate(); $iconMenu.Measure([Windows.Size]::new(320, 400)); $iconMenu.Arrange([Windows.Rect]::new(0, 0, 320, 400)); $iconMenu.UpdateLayout()
        [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $color = { param($Key) $iconMenu.FindResource($Key).Color }
        $rows = foreach ($item in $iconItems) {
            $text = & $findText $item ([string]$item.Header)
            $icon = $item.Icon
            [pscustomobject]@{ Name = [string]$item.Header; TextX = $text.TranslatePoint([Windows.Point]::new(0, 0), $item).X; Height = $item.ActualHeight; Text = $item.Foreground.Color
                IconX = if ($icon) { $icon.TranslatePoint([Windows.Point]::new(0, 0), $item).X } else { $null }; IconW = if ($icon) { $icon.ActualWidth } else { $null }
                IconColor = if ($icon) { $icon.Foreground.Color } else { $null }; IconFont = if ($icon) { "$($icon.FontFamily.Source)|$($icon.FontSize)" } else { '' } }
        }
        $detail = ($rows | ForEach-Object { "$($_.Name): 글자x=$($_.TextX) 아이콘x=$($_.IconX) 폭=$($_.IconW) 높이=$($_.Height)" }) -join ' / '
        $font = "$($iconMenu.FindResource('Font.Icon').Source)|$($iconMenu.FindResource('F.Icon'))"
        $withIcon = @($rows[0..4])
        Assert-WtTest '메뉴 아이콘 자리: 아이콘 왼쪽 12 · 폭 16 · 글자는 아이콘 뒤 12(40), 아이콘 없는 항목은 글자 왼쪽 12 그대로, 줄 높이 32' (
            -not @($withIcon | Where-Object { $_.IconX -ne 12 -or $_.IconW -ne 16 -or $_.TextX -ne 40 -or $_.IconFont -cne $font }).Count -and
            $rows[5].IconX -eq $null -and $rows[5].TextX -eq 12 -and -not @($rows | Where-Object { $_.Height -ne 32 }).Count) $detail
        Assert-WtTest '메뉴 아이콘 색: 보통 B.Text.Secondary, 위험은 글자 · 아이콘 모두 Btn.Danger 빨강, 꺼지면 둘 다 B.Text.Disabled' (
            $rows[0].IconColor -eq (& $color 'B.Text.Secondary') -and $rows[0].Text -eq (& $color 'B.Text.Primary') -and $rows[2].IconColor -eq (& $color 'B.Text.Secondary') -and
            $rows[1].IconColor -eq (& $color 'B.Text.Disabled') -and $rows[1].Text -eq (& $color 'B.Text.Disabled') -and
            $rows[3].Text -eq $dangerColor -and $rows[3].IconColor -eq $dangerColor -and $dangerColor -eq (& $color 'B.Status.Error.Text') -and
            $rows[4].Text -eq (& $color 'B.Text.Disabled') -and $rows[4].IconColor -eq (& $color 'B.Text.Disabled')) (($rows | ForEach-Object { "$($_.Name) 글자=$($_.Text) 아이콘=$($_.IconColor)" }) -join ' / ')
        $chevron = $iconItems[2].Template.FindName('SubmenuChevron', $iconItems[2])
        Assert-WtTest '메뉴 아이콘: 하위 메뉴 머리도 같은 자리 · 오른쪽 › 그대로' ($chevron -and $chevron.Text -ceq [string][char]0xE76C -and $chevron.IsVisible -and
            [object]::ReferenceEquals($iconItems[2].Style, $iconMenu.FindResource('Home.PinSubmenuItem')))
        foreach ($item in $iconItems[0], $iconItems[3]) {
            $route = Test-WtTestInputPath -View $iconMenu -Element $item.Icon -Target $item
            Assert-WtTest "메뉴 아이콘 숨김 좌표 경로: $($item.Header)의 아이콘 자리를 누르면 그 항목" $route.Ok $route.Path
        }
        foreach ($item in $iconItems[0], $iconItems[3]) { & $invokeItem $item }
        [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        Assert-WtTest '메뉴 아이콘: 아이콘 · 위험 항목도 누르면 값으로 한 번씩 부른다' (($global:uiIconPicked -join ',') -ceq 'open,delete') ($global:uiIconPicked -join ',')
    } finally { $iconSource.Dispose() }
    # 빈 화면 안내(New-WtEmptyState): 가운데에 한 줄 + 버튼. 버튼 하나는 글 아래 12, 여럿이면 한 줄에 사이 8. 숨긴 버튼은 그 간격도 빠진다
    $middle = { param($r) ($r.Left + $r.Right) / 2 }
    $folderAdd = New-WtButton '폴더 추가' -Icon 0xE710
    $single = New-WtEmptyState '스크립트 폴더가 없습니다.' $folderAdd
    $root.Child = $single.Root; Set-UiLayout
    $line = Get-UiBounds $single.Text; $button = Get-UiBounds $folderAdd
    Assert-WtTest '빈 화면 안내: 한 줄(T.Sub)과 버튼이 가로 · 세로 가운데, 버튼은 글 아래 12' (
        $single.Text.Style -eq $styles['T.Sub'] -and $single.Text.Text -ceq '스크립트 폴더가 없습니다.' -and $single.Root.Children.Count -eq 2 -and
        [Math]::Abs((& $middle $line) - $root.Width / 2) -le 1 -and [Math]::Abs((& $middle $button) - $root.Width / 2) -le 1 -and
        $button.Top - $line.Bottom -eq 12 -and [Math]::Abs(($line.Top + $button.Bottom) / 2 - $root.Height / 2) -le 1) "글=$line 버튼=$button"
    $route = Test-WtTestInputPath -View $root -Element $folderAdd -Target $folderAdd
    Assert-WtTest '빈 화면 안내 숨김 좌표 경로: 폴더 추가' $route.Ok $route.Path
    $folderAdd.Visibility = 'Collapsed'; Set-UiLayout
    $alone = Get-UiBounds $single.Text
    Assert-WtTest '빈 화면 안내: 버튼을 숨기면 그 위 간격도 빠져 글만 가운데' ([Math]::Abs(($alone.Top + $alone.Bottom) / 2 - $root.Height / 2) -le 1) "글=$alone"
    $pair = @((New-WtButton '새 메모' -Icon 0xE710), (New-WtButton '빠른 이동' -Icon 0xE721))
    $double = New-WtEmptyState -Buttons $pair
    $double.Text.Text = '메모가 없습니다.'
    $root.Child = $double.Root; Set-UiLayout
    $first = Get-UiBounds $pair[0]; $second = Get-UiBounds $pair[1]; $line = Get-UiBounds $double.Text
    Assert-WtTest '빈 화면 안내: 버튼이 여럿이면 한 줄에 사이 8로 가운데, 글 아래 12 (글은 나중에 바꿔도 됨)' (
        $first.Top -eq $second.Top -and $second.Left - $first.Right -eq 8 -and [Math]::Abs(($first.Left + $second.Right) / 2 - $root.Width / 2) -le 1 -and
        $first.Top - $line.Bottom -eq 12 -and [Math]::Abs((& $middle $line) - $root.Width / 2) -le 1) "글=$line 버튼=$first $second"
    foreach ($target in $pair) {
        $route = Test-WtTestInputPath -View $root -Element $target -Target $target
        Assert-WtTest "빈 화면 안내 숨김 좌표 경로: $(@(Get-WtTestTexts $target)[-1])" $route.Ok $route.Path
    }
    $root.Child = $null
    # 설정 · 도움말 하위 탭(New-WtTabbedPage): 다른 탭 머리를 누르면 WPF가 그 탭 내용의 첫 포커스 자리로 포커스를 옮긴다. 그 자리가 탭 맨 위의
    # 스크롤 면이라 중간의 단추가 포커스를 받아 스크롤이 내려가지 않는다(11-22 실사용 보고 12: 도움말 → 탭이 「근태」 부근부터 보였음).
    # 가짜 탭을 등록해 도움말 「탭」 페이지 중간(설명 40줄 아래)에 누를 수 있는 단추를 두고, 머리 누름은 실제 처리(OnMouseLeftButtonDown → 포커스)를 탄다
    $savedAddons = & (Get-Module Addons) { , $script:addons.ToArray() }
    try {
        & (Get-Module Addons) { $script:addons.Clear() }
        Register-WtAddon -Id 'ui-help' -Title '가짜 탭' -Order 10 -NewView { } -Help @(1..40 | ForEach-Object { "가짜 설명 줄 $_" }) -HelpCard { New-WtButton '중간 단추' }
        $helpPage = New-WtHelpPage
        $root.Child = $helpPage; Set-UiLayout 944 640
        $tabs = $helpPage.Tag.Tabs
        $tabItem = @($tabs.Items | Where-Object { [string]$_.Header -ceq '탭' })[0]
        [Windows.Input.Keyboard]::ClearFocus()
        $press = [Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)
        $press.RoutedEvent = [Windows.UIElement]::MouseLeftButtonDownEvent
        $tabItem.RaiseEvent($press); Set-UiLayout 944 640
        $scroll = $tabItem.Content
        $middle = @(foreach ($b in @(Get-WtVisualChild $scroll ([Windows.Controls.Button]))) { $b })[0]
        $focused = [Windows.Input.Keyboard]::FocusedElement
        Assert-WtTest '설정 · 도움말 하위 탭 숨김 배치: 다른 탭 머리를 누르면 그 탭 맨 위(스크롤 0)부터 보이고, 첫 포커스는 탭의 스크롤 면(중간 단추 아님)' (
            [object]::ReferenceEquals($tabs.SelectedItem, $tabItem) -and $scroll.ScrollableHeight -gt 0 -and $scroll.VerticalOffset -eq 0 -and
            [object]::ReferenceEquals($focused, $scroll) -and $null -ne $middle -and -not $middle.IsKeyboardFocused -and
            $scroll.FocusVisualStyle -eq $styles['Focus.Inside']) "선택 $($tabs.SelectedItem.Header) · 스크롤 $($scroll.VerticalOffset)/$($scroll.ScrollableHeight) · 포커스 $(if ($focused) { $focused.GetType().Name })"
    } finally {
        $root.Child = $null
        & (Get-Module Addons) { param($items) $script:addons.Clear(); foreach ($item in $items) { $script:addons.Add($item) } } $savedAddons
    }
    Write-Host '공통 화면 검사 PASS · FAIL 0'
} finally {
    if ($hostSource) { $hostSource.Dispose() }
    Stop-WtDataWrites -Milliseconds 3000; Stop-WtAllWork; Remove-WtTestData $test
}

<#
.SYNOPSIS
    메모 탭의 빠른 메모 창(코어 빠른 적기 등록 -QuickCapture)을 임시 데이터로 검사한다.

.DESCRIPTION
    창을 띄우지 않는다. 창 보이기 · 닫기 · 작업 영역 · 메모 탭 열기만 가짜로 바꿔 끼우고, 창 안 내용은 숨김 호스트(WindowStyle 0인 HwndSource)에
    옮겨 실제 배치 좌표 · 키 경로를 본다. 보조 키(Ctrl)는 Get-WtMemoModifiers를 바꿔 흉내 낸다.
    새 메모 · 제목 규칙 · 이어 고치기 · 비우면 지우기 · 빈 채로 닫기 · 저장 실패 때 창 남기기 · 메모 화면 목록 · 홈 바로 가기 · 끝낼 때 저장을 본다.
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/memo/Test-MemoQuick.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
if (-not (Test-WtTestWpf)) { Write-Host 'SKIP 빠른 메모 (Windows STA에서만)'; return }
Import-Module (Join-Path $PSScriptRoot 'MemoEditor.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Memo.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MemoData.psm1') -Force -DisableNameChecking
$memoModule = Get-Module Memo
$test = New-WtTestData 'memo-quick'
$global:wtQuickProbe = @{ Shown = 0; Closed = 0; Opened = [System.Collections.Generic.List[string]]::new() }
& $memoModule {
    $script:testMods = [System.Windows.Input.ModifierKeys]::None
    function script:Get-WtMemoModifiers { $script:testMods }
    $script:captureShow = { param($Window) $global:wtQuickProbe.Shown++ }
    $script:captureClose = { param($Window) $global:wtQuickProbe.Closed++ }
    $script:captureArea = { [System.Windows.Rect]::new(0, 0, 1920, 1040) }
    $script:captureOpenPage = { param($Id) $global:wtQuickProbe.Opened.Add($Id) }
}
$hostSource = $null; $viewSource = $null

function Get-TestQuick { & $memoModule { $script:capture } }
function Save-TestQuick { & $memoModule { Save-WtMemoCapture } }
function Get-TestLive { @(Get-WtMemoItems) }
# 창 안 내용을 숨김 호스트로 옮겨 배치한다(창은 보이지 않는다)
function Set-TestHosted($Q) {
    $Q.Window.Content = $null
    $script:hostRoot.Child = $Q.Frame
    $script:hostRoot.Measure([System.Windows.Size]::new(440, 280)); $script:hostRoot.Arrange([System.Windows.Rect]::new(0, 0, 440, 280)); $script:hostRoot.UpdateLayout()
}
function Send-TestKey($Target, [string]$Key, [string]$Mods = 'None') {
    & $memoModule { param($m) $script:testMods = [System.Enum]::Parse([System.Windows.Input.ModifierKeys], $m) } $Mods
    $a = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $script:hostSource, 0, [System.Windows.Input.Key]$Key)
    $a.RoutedEvent = [System.Windows.Input.Keyboard]::PreviewKeyDownEvent
    $Target.RaiseEvent($a)
    & $memoModule { $script:testMods = [System.Windows.Input.ModifierKeys]::None }
    $a.Handled
}
function Get-TestRect($Element) { $Element.TransformToAncestor($script:hostRoot).TransformBounds([System.Windows.Rect]::new(0, 0, $Element.ActualWidth, $Element.ActualHeight)) }

try {
    $script:hostRoot = [System.Windows.Controls.Border]::new()
    $script:hostRoot.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $script:hostRoot.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $parameters = [System.Windows.Interop.HwndSourceParameters]::new('Memo quick test'); $parameters.WindowStyle = 0; $parameters.Width = 440; $parameters.Height = 280
    $script:hostSource = [System.Windows.Interop.HwndSource]::new($parameters); $script:hostSource.RootVisual = $script:hostRoot

    # ---- 등록 · 띄우기 ----
    $cap = Get-WtQuickCapture
    Assert-WtTest '빠른 메모 등록: 메모 탭이 코어 빠른 적기 자리에 이름 · 권하는 키 · 여는 함수를 등록한다' (
        $cap.Id -ceq 'memo' -and $cap.QuickCapture.Name -ceq '빠른 메모' -and $cap.QuickCapture.Key -ceq 'Ctrl + Alt + M' -and $cap.QuickCapture.Open -is [scriptblock])
    $before = (Get-TestLive).Count
    [void](& $cap.QuickCapture.Open)
    $q = Get-TestQuick
    $w = $q.Window
    $focused = [System.Windows.Input.FocusManager]::GetFocusedElement($w)
    Assert-WtTest '빠른 메모 창: 440 × 280 · 맨 위 · 작업 표시줄 단추 · 작업 영역 가로 가운데 위 96 · 본문 칸에 포커스 · 아직 메모 없음' (
        $q -and $global:wtQuickProbe.Shown -eq 1 -and $w.Width -eq 440 -and $w.Height -eq 280 -and $w.Topmost -and $w.ShowInTaskbar -and $w.ShowActivated -and
        $null -eq $w.Owner -and $w.Left -eq 740 -and $w.Top -eq 96 -and $w.Title -ceq 'WorkTool · 빠른 메모' -and [object]::ReferenceEquals($focused, $q.Box) -and
        $q.Box.AcceptsReturn -and -not $q.Box.AcceptsTab -and $q.Box.TextWrapping -eq 'Wrap' -and $q.Hint.Visibility -eq 'Visible' -and -not $q.Status.Text -and
        -not $q.Open.IsEnabled -and [string]$q.Open.ToolTip -ceq '글을 쓰면 열 수 있습니다.' -and (Get-TestLive).Count -eq $before) "($($w.Width)x$($w.Height) @ $($w.Left),$($w.Top) · 포커스 $($focused.GetType().Name))"
    $again = & $cap.QuickCapture.Open
    Assert-WtTest '빠른 메모 창: 떠 있는데 또 부르면 새 창 없이 그 창을 앞으로 가져온다' ([object]::ReferenceEquals((Get-TestQuick), $q) -and [object]::ReferenceEquals((Get-TestQuick).Window, $w))

    # ---- 배치 · 좌표 경로 (숨김 호스트) ----
    Set-TestHosted $q
    $q.Box.Text = "회의 메모`r`n내용 한 줄"
    $script:hostRoot.UpdateLayout()
    $boxRect = Get-TestRect $q.Box; $openRect = Get-TestRect $q.Open; $closeRect = Get-TestRect $q.CloseButton
    $routes = foreach ($pair in @(@('본문 칸', $q.Box), @('메모에서 열기', $q.Open), @('닫기', $q.CloseButton))) {
        $r = Test-WtTestInputPath -View $script:hostRoot -Element $pair[1] -Target $pair[1]
        [pscustomobject]@{ Name = $pair[0]; Ok = $r.Ok; Path = $r.Path }
    }
    $chromeRect = Get-TestRect $q.ChromeClose
    $routes += [pscustomobject]@{ Name = '제목 줄 닫기'; Ok = (Test-WtTestInputPath -View $script:hostRoot -Element $q.ChromeClose -Target $q.ChromeClose).Ok; Path = "$chromeRect" }
    Assert-WtTest '빠른 메모 배치: 제목 줄 32 · 흰 카드 좌우 8 · 아래 줄 48(단추 32, 오른쪽 끝 8) · 닫기가 맨 오른쪽' (
        $boxRect.X -eq 8 -and $boxRect.Y -eq 32 -and $boxRect.Width -eq 424 -and $boxRect.Height -eq 200 -and $openRect.Height -eq 32 -and $closeRect.Bottom -eq 272 -and
        $closeRect.Right -eq 432 -and $openRect.Right + 8 -eq $closeRect.Left -and $chromeRect.Right -eq 440 -and $chromeRect.Top -eq 0 -and $chromeRect.Height -eq 32) "(본문 $boxRect · 열기 $openRect · 닫기 $closeRect · 제목 줄 닫기 $chromeRect)"
    Assert-WtTest '빠른 메모 좌표 경로: 본문 칸 · 메모에서 열기 · 닫기 · 제목 줄 닫기가 실제 배치 좌표에서 닿는다' (-not @($routes | Where-Object { -not $_.Ok }).Count) (($routes | ForEach-Object { "$($_.Name)=$($_.Ok) $($_.Path)" }) -join ' / ')

    # ---- 쓰기: 쉬면 저장 · 첫 줄이 제목 · 홈 바로 가기 ----
    Assert-WtTest '빠른 메모 쓰기: 치면 「저장 중…」 · 1초 쉬면 저장하는 타이머 · 예시 글자 숨김 · 메모에서 열기 켜짐' (
        $q.Status.Text -ceq '저장 중…' -and $q.Timer.IsEnabled -and $q.Timer.Interval.TotalSeconds -eq 1 -and $q.Hint.Visibility -eq 'Collapsed' -and $q.Open.IsEnabled)
    $saved = Save-TestQuick
    Wait-WtTestWrites
    & $memoModule { Update-WtMemoCaptureStatus $script:capture }
    $live = Get-TestLive
    $made = @($live | Where-Object { [string]$_.id -ceq $q.Id })
    $shortcut = @(Get-WtShortcuts | Where-Object { $_.Page -ceq 'memo' -and $_.Key -ceq $q.Id })
    Assert-WtTest '빠른 메모 저장: 새 메모 하나(첫 줄 = 제목, 나머지 = 본문) · 「저장됨」 · 홈 바로 가기에 쓴 기록' (
        $saved -and $live.Count -eq $before + 1 -and $made.Count -eq 1 -and $made[0].title -ceq '회의 메모' -and $made[0].body -ceq '내용 한 줄' -and
        $q.Status.Text -ceq '저장됨' -and -not $q.Timer.IsEnabled -and $shortcut.Count -eq 1 -and $shortcut[0].Title -ceq '회의 메모') "($($live.Count) · $($made.title) · $($q.Status.Text) · 바로 가기 $($shortcut.Count))"
    $firstId = $q.Id
    $q.Box.Text = "회의 메모 고침`r`n둘째 줄`r`n셋째 줄"
    $handled = Send-TestKey $q.Box 'S' 'Control'
    $live = Get-TestLive
    $made = @($live | Where-Object { [string]$_.id -ceq $firstId })
    Assert-WtTest '빠른 메모 Ctrl+S: 같은 메모의 제목 · 본문만 바꾸고 창은 그대로' (
        $handled -and $q.Id -ceq $firstId -and $live.Count -eq $before + 1 -and $made[0].title -ceq '회의 메모 고침' -and $made[0].body -ceq "둘째 줄`r`n셋째 줄" -and
        $global:wtQuickProbe.Closed -eq 0 -and [object]::ReferenceEquals((Get-TestQuick), $q)) "(처리 $handled · $($q.Id -ceq $firstId) · $($live.Count) · $($made.title) · $($made.body -replace "`r`n", '⏎') · 닫힘 $($global:wtQuickProbe.Closed) · 상태 $($q.Status.Text) · 오류 $($q.Error))"
    $enter = Send-TestKey $q.Box 'Return'
    $ime = Send-TestKey $q.Box 'ImeProcessed'
    Assert-WtTest '빠른 메모 키: Enter는 본문 칸이 받고(줄 바꿈), 한글 조합 중 키는 건드리지 않는다' (-not $enter -and -not $ime -and $global:wtQuickProbe.Closed -eq 0)

    # 저장하지 못하면 닫지 않고 글을 남긴다(이유는 툴팁)
    & $memoModule { $script:realSave = ${function:Save-WtMemoItems}; function script:Save-WtMemoItems { param([object[]]$Items) throw '파일이 잠겨 있습니다.' } }
    $q.Box.Text = "회의 메모 고침`r`n저장 실패 중에 쓴 줄"
    $escFail = Send-TestKey $q.Box 'Escape'
    Assert-WtTest '빠른 메모 저장 실패: Esc를 눌러도 창을 닫지 않고 글을 남기며 「저장하지 못했습니다」 + 이유 툴팁' (
        $escFail -and $global:wtQuickProbe.Closed -eq 0 -and [object]::ReferenceEquals((Get-TestQuick), $q) -and $q.Status.Text -ceq '저장하지 못했습니다' -and
        [string]$q.Status.ToolTip -like '*파일이 잠겨 있습니다.*' -and $q.Box.Text -like '*저장 실패 중에 쓴 줄')
    & $memoModule { Set-Item function:script:Save-WtMemoItems $script:realSave }
    $closed = Send-TestKey $q.Box 'Return' 'Control'
    $made = @(Get-TestLive | Where-Object { [string]$_.id -ceq $firstId })
    Assert-WtTest '빠른 메모 Ctrl+Enter: 다시 저장하고 닫는다' ($closed -and $global:wtQuickProbe.Closed -eq 1 -and $null -eq (Get-TestQuick) -and $made[0].body -ceq '저장 실패 중에 쓴 줄')

    # ---- 첫 줄이 빈 메모 · 비우면 지우기 · 빈 채로 닫기 ----
    [void](& $cap.QuickCapture.Open)
    $q = Get-TestQuick
    Set-TestHosted $q
    Assert-WtTest '빠른 메모: 닫은 뒤 다시 부르면 새 창 · 새 글(매번 새 메모)' ($q -and $global:wtQuickProbe.Shown -ge 3 -and -not $q.Id -and -not $q.Box.Text)
    $q.Box.Text = "`r`n본문만 적음"
    [void](Save-TestQuick)
    $made = @(Get-TestLive | Where-Object { [string]$_.id -ceq $q.Id })
    $wantTitle = '빠른 메모 ' + $q.Started.ToString('M/d HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    Assert-WtTest "빠른 메모 제목: 첫 줄이 비면 「$wantTitle」(창을 연 시각)" ($made.Count -eq 1 -and $made[0].title -ceq $wantTitle -and $made[0].body -ceq '본문만 적음' -and (Get-TestLive).Count -eq $before + 2)
    $secondId = $q.Id
    $q.Box.Text = "  `r`n "
    [void](Save-TestQuick)
    Assert-WtTest '빠른 메모 비우기: 만든 메모를 비우면 지운다(빈 메모 규칙)' (-not @(Get-TestLive | Where-Object { [string]$_.id -ceq $secondId }).Count -and (Get-TestLive).Count -eq $before + 1 -and -not $q.Id)
    $esc = Send-TestKey $q.Box 'Escape'
    Assert-WtTest '빠른 메모 Esc: 빈 채로 닫으면 메모를 만들지 않는다' ($esc -and $global:wtQuickProbe.Closed -eq 2 -and $null -eq (Get-TestQuick) -and (Get-TestLive).Count -eq $before + 1)
    [void](& $cap.QuickCapture.Open)
    $q = Get-TestQuick
    $q.CloseButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    Assert-WtTest '빠른 메모 [닫기]: 한 자도 안 쓰고 닫으면 메모 수는 그대로' ($global:wtQuickProbe.Closed -eq 3 -and $null -eq (Get-TestQuick) -and (Get-TestLive).Count -eq $before + 1)

    # ---- 메모에서 열기 ----
    [void](& $cap.QuickCapture.Open)
    $q = Get-TestQuick
    $q.Box.Text = '전화: SRV-01 재부팅 요청'
    $q.Open.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $made = @(Get-TestLive | Where-Object { [string]$_.id -ceq $q.Id })
    Assert-WtTest '빠른 메모 [메모에서 열기]: 저장하고 닫은 뒤 메모 탭에서 그 메모를 연다' (
        $made.Count -eq 1 -and $made[0].title -ceq '전화: SRV-01 재부팅 요청' -and $global:wtQuickProbe.Closed -eq 4 -and $null -eq (Get-TestQuick) -and
        $global:wtQuickProbe.Opened.Count -eq 1 -and $global:wtQuickProbe.Opened[0] -ceq $q.Id)

    # ---- 메모 화면이 떠 있을 때: 목록에 바로 보이고, 끝낼 때 저장 · 닫기 ----
    $addon = Get-WtAddon -Id 'memo'
    $viewRoot = [System.Windows.Controls.Border]::new(); $viewRoot.Width = 1280; $viewRoot.Height = 720
    $viewParams = [System.Windows.Interop.HwndSourceParameters]::new('Memo quick view test'); $viewParams.WindowStyle = 0; $viewParams.Width = 1280; $viewParams.Height = 720
    $viewSource = [System.Windows.Interop.HwndSource]::new($viewParams); $viewSource.RootVisual = $viewRoot
    $view = New-WtTestView 'memo'
    $viewRoot.Child = $view
    $viewRoot.Measure([System.Windows.Size]::new(1280, 720)); $viewRoot.Arrange([System.Windows.Rect]::new(0, 0, 1280, 720))
    [void](& $addon.Refresh $view)
    $viewRoot.UpdateLayout()
    [void](& $cap.QuickCapture.Open)
    $q = Get-TestQuick
    $q.Box.Text = "목록에 보일 메모`r`n본문"
    [void](Save-TestQuick)
    $rows = & $memoModule { @($script:ui.List.Items) }
    $top = & $memoModule { [string]$script:items[0].id }
    Assert-WtTest '빠른 메모 + 메모 화면: 저장하면 메모 목록 맨 위에 바로 보인다' ($top -ceq $q.Id -and @($rows | Where-Object { $_.Id -ceq $q.Id }).Count -eq 1) "(맨 위 $top · 줄 $($rows.Count))"
    $q.Box.Text = "목록에 보일 메모`r`n끝내기 직전에 쓴 줄"
    $pending = @(& $addon.SavePending)[-1]
    [void](& $addon.OnExit)
    $made = @(Get-TestLive | Where-Object { [string]$_.id -ceq $q.Id })
    Assert-WtTest '빠른 메모 끝내기: 저장 확인(SavePending)이 창의 글을 저장하고, 정리(OnExit)가 창을 닫는다' (
        $pending -eq $true -and $made[0].body -ceq '끝내기 직전에 쓴 줄' -and $null -eq (Get-TestQuick) -and $global:wtQuickProbe.Closed -eq 5)

    # ---- 도움말 → 단축키 ----
    $keys = @($addon.Shortcuts | Where-Object { @($_).Count -gt 2 -and $_[2] -ceq '빠른 메모' } | ForEach-Object { $_[0] })
    Assert-WtTest '빠른 메모 도움말: 단축키 목록의 메모 쪽에 「빠른 메모」 주제(여는 키 · Esc / Ctrl+Enter · Ctrl+S)' (($keys -join ',') -ceq 'Ctrl + Alt + M,Esc / Ctrl + Enter,Ctrl + S') ($keys -join ',')
} finally {
    $quick = Get-TestQuick
    if ($quick) { & $memoModule { $script:capture = $null } }
    if ($viewSource) { $viewSource.RootVisual = $null; $viewSource.Dispose() }
    if ($script:hostSource) { $script:hostRoot.Child = $null; $script:hostSource.RootVisual = $null; $script:hostSource.Dispose() }
    Wait-WtTestWrites
    Remove-WtTestData $test
}

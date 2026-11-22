<#
.SYNOPSIS
    메모 편집기(MemoEditor.psm1)를 표시하지 않는 시험 호스트에서 검사한다: 불러오기 · 섬 · 이동 · 잇기 · 실행 취소 · 모드 · 할 일 · 클릭 위치 · 나눠 그리기 · 편집 명령 · 섬 나누기(Enter).

.DESCRIPTION
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.
    Windows STA에서만 돌린다(그 밖에는 건너뛴다). 보이지 않는 HwndSource에 배치하며 창을 표시하거나 활성화하지 않는다.
    오류 창(MessageBox)이 뜨지 않게 Show-WtError · Show-WtMessage를 콘솔 출력으로 바꿔 끼우고, 찍힌 오류가 있으면 실패로 본다.

    키는 KeyEventArgs를 PreviewKeyDown → (처리 안 됐으면) KeyDown 순서로 흉내 낸다.
    편집기는 수정키를 실제 키보드 상태(Keyboard.Modifiers)로 읽어서, Ctrl · Shift · Alt가 붙은 키는
    키 처리기가 부르는 편집기 내부 함수를 모듈 범위에서 직접 부른다(Invoke-EdCommand).

    매 단계 끝에 「문서 약속」을 본다(Test-EdContract):
      - Live.Document.Blocks = Sections[0..Rendered-1] 차례, 섬이 열려 있으면 그 자리(First..Last)에 섬 하나
      - Sections[i].Tag = Units[i], $ed.Lines를 다시 나눈 결과 = $ed.Units (Start · End · Kind · Depth · Text)
      - 섬의 Original = 그 줄들, First · Last = 섬이 덮는 단위

    알려진 버그: 지금은 없다. 새로 찾으면 그 검사에 -Bug '이름'을 달고 아래와 $bugList에 적는다(기본은 건너뜀, -KnownBugs로 돌림).
      처음 찾은 14건(섬 읽기 전용 · PageDown 키 · 울타리 · HTML 주석 · 목록 이어 쓰기 · 빈 항목 · 닫히지 않은 울타리 · 클릭 위치 ·
      실행 취소 3건 · 줄바꿈 섞임 · 끝 PageDown · 포커스 -End)은 편집기에서 고쳤다(2026-10-25)

.PARAMETER KnownBugs
    알려진 버그 검사도 돌린다(기본은 건너뜀). 편집기를 고친 뒤 확인할 때 쓴다.

.PARAMETER Seeds
    무작위 편집의 시드 목록. 더 많이 돌려 볼 때: -Seeds (1..30)

.PARAMETER Steps
    무작위 편집 한 번의 단계 수

.PARAMETER Cases
    지정한 이름의 검사만 실행한다. 생략하면 기존 검사와 회귀 검사를 모두 실행한다.

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/memo/Test-MemoEditor.ps1

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/memo/Test-MemoEditor.ps1 -KnownBugs
#>
#Requires -Version 7.0
[CmdletBinding()]
param([switch]$KnownBugs, [int[]]$Seeds = @(20261025, 7, 4242), [int]$Steps = 150, [string[]]$Cases = @())

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'MemoText.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'MemoEditor.psm1') -Force -DisableNameChecking
$em = Get-Module MemoEditor
$test = New-WtTestData 'memo-editor'

if (-not (Test-WtTestWpf)) {
    Write-Host 'SKIP 메모 편집기 (Windows STA에서만)'
    Remove-WtTestData $test
    return
}

# ---- 알려진 버그 · 결과 세기 ---------------------------------------------------------------------

$bugList = @()

$script:edPass = 0
$script:edContract = 0
$script:edSkip = [System.Collections.Generic.List[string]]::new()
$script:edFail = [System.Collections.Generic.List[string]]::new()
$script:edErrors = [System.Collections.Generic.List[string]]::new()

function Assert-Ed([string]$Name, [bool]$Ok, $Detail = '') {
    if ($script:edErrors.Count) {
        $Ok = $false
        $Detail = "$Detail / 오류 창: $($script:edErrors -join ' | ')"
        $script:edErrors.Clear()
    }
    if ($Ok) { $script:edPass++; Write-Host "PASS $Name"; return }
    $script:edFail.Add("$Name $Detail")
    Write-Host "FAIL $Name $Detail" -ForegroundColor Red
}

# 검사 하나. 예외가 나도 실패로 적고 다음 검사로 간다. -Bug는 알려진 버그 검사(기본은 건너뜀)
function Invoke-EdCase([string]$Name, [scriptblock]$Body, [string]$Bug = '') {
    if ($Cases.Count -and $Name -notin $Cases) { return }
    if ($Bug -and -not $KnownBugs -and $bugList -contains $Bug) {
        $script:edSkip.Add("$Bug ($Name)")
        Write-Host "SKIP 알려진 버그 $Bug : $Name" -ForegroundColor Yellow
        return
    }
    try { & $Body }
    catch { Assert-Ed $Name $false "예외: $($_.Exception.Message) @ $($_.InvocationInfo.PositionMessage)" }
}

# ---- 문서 약속 -----------------------------------------------------------------------------------

function Get-EdUnitSig($Unit) { '{0}-{1} {2} d{3} [{4}]' -f $Unit.Start, $Unit.End, $Unit.Kind, $Unit.Depth, $Unit.Text }

function Get-EdContractProblems($Ed) {
    $bad = [System.Collections.Generic.List[string]]::new()
    if ($Ed.Mode -ne 'live') { return , $bad }
    $units = $Ed.Units
    $secs = $Ed.Sections
    $isl = $Ed.Island
    if ($units.Count -ne $secs.Count) { $bad.Add("Units $($units.Count) ≠ Sections $($secs.Count)") }
    if ($Ed.Rendered -lt 0 -or $Ed.Rendered -gt $units.Count) { $bad.Add("Rendered $($Ed.Rendered) (Units $($units.Count))") }
    $want = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt [Math]::Min($Ed.Rendered, $secs.Count); $i++) {
        if ($isl -and $i -eq $isl.First) { $want.Add($isl.Holder) }
        if ($isl -and $i -ge $isl.First -and $i -le $isl.Last) { continue }
        $want.Add($secs[$i])
    }
    if ($isl -and $isl.First -ge $Ed.Rendered) { $want.Add($isl.Holder) }
    $blocks = @($Ed.Live.Document.Blocks)
    if ($blocks.Count -ne $want.Count) { $bad.Add("Blocks $($blocks.Count)개, 기대 $($want.Count)개") }
    else {
        for ($i = 0; $i -lt $blocks.Count; $i++) {
            if (-not [object]::ReferenceEquals($blocks[$i], $want[$i])) { $bad.Add("Blocks[$i] 차례가 다름"); break }
        }
    }
    for ($i = 0; $i -lt [Math]::Min($Ed.Rendered, $secs.Count); $i++) {
        if (-not $secs[$i] -or -not [object]::ReferenceEquals($secs[$i].Tag, $units[$i])) { $bad.Add("Sections[$i].Tag ≠ Units[$i]"); break }
    }
    $fresh = Get-WtMarkdownUnits (@($Ed.Lines) -join "`n")   # 배열 하나로 돌려준다 (@()로 감싸지 않는다)
    if ($null -eq $fresh) { $fresh = @() }
    $a = @($fresh | ForEach-Object { Get-EdUnitSig $_ })
    $b = @($units | ForEach-Object { Get-EdUnitSig $_ })
    if (($a -join "`n") -cne ($b -join "`n")) {
        $k = 0
        while ($k -lt $a.Count -and $k -lt $b.Count -and $a[$k] -ceq $b[$k]) { $k++ }
        $bad.Add("다시 나눈 단위와 다름(#$k): 다시 나눔 $(if ($k -lt $a.Count) { $a[$k] } else { '(없음)' }) / 편집기 $(if ($k -lt $b.Count) { $b[$k] } else { '(없음)' }) (개수 $($a.Count)/$($b.Count))")
    }
    if ($isl) {
        if (-not [object]::ReferenceEquals($isl.Holder.Child, $Ed.IslandBox)) { $bad.Add('섬 자리에 섬 상자가 없음') }
        if ($isl.Start -lt 0 -or $isl.End -gt $Ed.Lines.Count -or $isl.Start -ge $isl.End) { $bad.Add("섬 범위 $($isl.Start)..$($isl.End) (줄 $($Ed.Lines.Count))") }
        else {
            $orig = @($Ed.Lines.GetRange($isl.Start, $isl.End - $isl.Start)) -join "`r`n"
            if ($orig -cne $isl.Original) { $bad.Add('섬 Original ≠ 그 줄들') }
        }
        $first = 0
        while ($first -lt $units.Count -and $units[$first].End -le $isl.Start) { $first++ }
        $last = $first - 1
        while ($last + 1 -lt $units.Count -and $units[$last + 1].Start -lt $isl.End) { $last++ }
        if ($first -ne $isl.First -or $last -ne $isl.Last) { $bad.Add("섬 First..Last $($isl.First)..$($isl.Last), 기대 $first..$last") }
    }
    , $bad
}

# 문서 약속 검사. 통과는 세기만 하고(줄이 너무 많아져서) 실패만 찍는다
function Test-EdContract($Ed, [string]$Where) {
    $bad = Get-EdContractProblems $Ed
    $script:edContract++
    if ($bad.Count) { Assert-Ed "문서 약속: $Where" $false ($bad -join '; ') }
    $bad.Count -eq 0
}

# 문서 약속 자체가 검사 대상일 때 (PASS · FAIL을 찍는다)
function Assert-EdContract($Ed, [string]$Name) {
    $bad = Get-EdContractProblems $Ed
    $script:edContract++
    Assert-Ed $Name ($bad.Count -eq 0) ($bad -join '; ')
}

# ---- 시험 창 · 편집기 ------------------------------------------------------------------------------

# 오류 창 대신 콘솔에 찍고 모은다. 편집기 · 마크다운 · 공통 UI 모듈 안에서 부르는 이름을 모두 바꿔 끼운다
$errSink = $script:edErrors
$patched = @('MemoEditor', 'Markdown', 'Ui')
$origUi = & (Get-Module Ui) { @{ Error = ${function:Show-WtError}; Message = ${function:Show-WtMessage} } }
foreach ($name in $patched) {
    & (Get-Module $name) {
        param($sink)
        $script:testErrSink = $sink
        function script:Show-WtError { param($ErrorRecord, $Where) $m = "[$Where] $ErrorRecord"; $script:testErrSink.Add($m); Write-Host "오류(검사): $m" -ForegroundColor Red }
        function script:Show-WtMessage { param($Text, $Title, $Icon) $script:testErrSink.Add("메시지: $Text"); Write-Host "메시지(검사): $Text" -ForegroundColor Red }
    } $errSink
}
$dispatcher = [System.Windows.Threading.Dispatcher]::CurrentDispatcher
$onUnhandled = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler] {
    param($s, $e)
    $errSink.Add("처리 안 된 예외: $($e.Exception.Message)")
    Write-Host "처리 안 된 예외(검사): $($e.Exception.Message)" -ForegroundColor Red
    $e.Handled = $true
}
$dispatcher.add_UnhandledException($onUnhandled)

$win = [System.Windows.Controls.Border]::new()
$win.Width = 900; $win.Height = 700
$sourceParams = [System.Windows.Interop.HwndSourceParameters]::new('MemoEditor test')
$sourceParams.Width = 900; $sourceParams.Height = 700; $sourceParams.WindowStyle = 0
$testSource = [System.Windows.Interop.HwndSource]::new($sourceParams)
$testSource.RootVisual = $win
$edHost = [System.Windows.Controls.Grid]::new()
$edHost.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
$edHost.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
$win.Child = $edHost

function New-EdEditor([switch]$AsIs) {
    $x = New-WtMemoEditor -OnChanged { param($one) $one.TestChanged++ } -OnLeave { param($one) $one.TestLeft++ }
    $x.TestChanged = 0
    $x.TestLeft = 0
    $script:edHost.Children.Clear()
    [void]$script:edHost.Children.Add($x.Root)
    $script:win.UpdateLayout()
    $x
}

# 디스패처를 잠깐 돌린다 (나눠 그리기 타이머가 돌 수 있게)
function Wait-EdUi([int]$Ms = 10) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $t = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Normal)
    $t.Interval = [TimeSpan]::FromMilliseconds($Ms)
    $t.Tag = $frame
    $t.Add_Tick({ param($s, $e) $s.Stop(); $s.Tag.Continue = $false })
    $t.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

# 나눠 그리기가 끝날 때까지 돌린다. -Check면 사이사이 문서 약속을 본다
function Complete-EdRender($Ed, [switch]$Check, [string]$Where = '나눠 그리는 중') {
    # 확인하는 것은 「멈추지 않고 끝까지 그린다」다. 걸린 시간은 PC · 프로세스 상태(전체 검사 안에서는 두 배 가까이)에 따라 달라
    # 벽시계 한도 대신 15초 동안 한 단위도 더 못 그리면 멈춘 것으로 본다(11-17: 혼자 30초 · 전체 검사 안 60초 넘나듦). 5분은 무한 루프 막이
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    $last = $Ed.Rendered; $lastAt = 0
    while ($Ed.Rendered -lt $Ed.Units.Count -and $sw.ElapsedMilliseconds - $lastAt -lt 15000 -and $sw.ElapsedMilliseconds -lt 300000) {
        Wait-EdUi 10
        if ($Check -and $ok) { $ok = Test-EdContract $Ed $Where }
        if ($Ed.Rendered -ne $last) { $last = $Ed.Rendered; $lastAt = $sw.ElapsedMilliseconds }
    }
    $Ed.Live.UpdateLayout()
    $Ed.Rendered -ge $Ed.Units.Count
}

function Set-EdText($Ed, [string]$Text) {
    $null = Set-WtMemoEditorText $Ed $Text
    [void](Complete-EdRender $Ed)
}

function Get-EdText($Ed) { ([string](Get-WtMemoEditorText $Ed)).Replace("`r`n", "`n") }
function Get-EdLines($Ed) { @((Get-EdText $Ed) -split "`n") }
function Join-EdLines([string[]]$Lines) { $Lines -join "`n" }

# 키 하나: PreviewKeyDown → 처리 안 됐으면 KeyDown. 받는 곳은 지금 고치는 칸(섬 · 원문 칸)
function Get-EdBox($Ed) { if ($Ed.Mode -eq 'source') { $Ed.Source } else { $Ed.IslandBox } }
function Send-EdKey($Ed, [string]$Key, [int]$Times = 1) {
    $src = [System.Windows.PresentationSource]::FromVisual($script:win)
    for ($n = 0; $n -lt $Times; $n++) {
        Wait-EdModifiers
        $target = Get-EdBox $Ed
        $handled = $false
        $enter = $Key -in 'Return', 'Enter'
        # Enter는 PreviewKeyDown만 올린다. 시험 창에서 TextBox의 KeyDown은 Enter를 처리됨으로만 표시하고 줄을 바로 바꾸지 않아서
        $events = if ($enter) { @([System.Windows.Input.Keyboard]::PreviewKeyDownEvent) } else { @([System.Windows.Input.Keyboard]::PreviewKeyDownEvent, [System.Windows.Input.Keyboard]::KeyDownEvent) }
        foreach ($ev in $events) {
            $a = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]$Key)
            $a.RoutedEvent = $ev
            $target.RaiseEvent($a)
            if ($a.Handled) { $handled = $true; break }
        }
        # 편집기가 처리하지 않은 Enter는 TextBox가 줄을 바꾼다. 그 일을 직접 한다
        if (-not $handled -and $enter) {
            $i = $target.SelectionStart
            $target.SelectedText = "`r`n"
            $target.Select($i + 2, 0)
        }
        Sync-EdUi
    }
}

# 편집기는 수정키를 실제 키보드(Keyboard.Modifiers)에서 읽는다. 검사 중에 누가 Ctrl · Alt · Shift를 누르고 있으면 뗄 때까지 기다린다
function Wait-EdModifiers {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ([int][System.Windows.Input.Keyboard]::Modifiers -ne 0 -and $sw.ElapsedMilliseconds -lt 3000) { Wait-EdUi 50 }
    if ($sw.ElapsedMilliseconds -ge 3000) { Write-Host "  (수정키가 눌린 채로 보임: $([System.Windows.Input.Keyboard]::Modifiers))" -ForegroundColor Yellow }
}

# 쌓인 일(스크롤 맞추기 BringIntoView 등)을 처리한다. 실제로는 키와 키 사이에 디스패처가 돈다
function Sync-EdUi {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
}

# 실제 순서: PreviewTextInputStart → PreviewTextInput → 처리 안 됐으면 TextInput (TextBox가 넣는다)
function Send-EdText($Ed, [string]$Text) {
    $target = Get-EdBox $Ed
    $tc = [System.Windows.Input.TextComposition]::new([System.Windows.Input.InputManager]::Current, $target, $Text)
    $start = [System.Windows.Input.TextCompositionEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $tc)
    $start.RoutedEvent = [System.Windows.Input.TextCompositionManager]::PreviewTextInputStartEvent
    $target.RaiseEvent($start)
    foreach ($ev in [System.Windows.Input.TextCompositionManager]::PreviewTextInputEvent, [System.Windows.Input.TextCompositionManager]::TextInputEvent) {
        $tc = [System.Windows.Input.TextComposition]::new([System.Windows.Input.InputManager]::Current, $target, $Text)
        $a = [System.Windows.Input.TextCompositionEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $tc)
        $a.RoutedEvent = $ev
        $target.RaiseEvent($a)
        if ($a.Handled) { break }
    }
}

# 수정키가 붙은 키: 키 처리기(Invoke-WtMemoIslandKey · Invoke-WtMemoBoxKey)가 그 키에서 부르는 것을 그대로 부른다
function Invoke-EdCommand($Ed, [string]$Name) {
    & $script:em {
        param($x, $cmd, $box)
        switch ($cmd) {
            'Ctrl+B' { [void](Invoke-WtMemoBoxEdit $box (Get-WtMemoWrapEdit (Get-WtMemoBoxState $box) '**')) }
            'Ctrl+I' { [void](Invoke-WtMemoBoxEdit $box (Get-WtMemoWrapEdit (Get-WtMemoBoxState $box) '*')) }
            'Ctrl+L' { [void](Invoke-WtMemoBoxEdit $box (Get-WtMemoTaskEdit (Get-WtMemoBoxState $box))) }
            'Shift+Tab' { $b2 = Expand-WtMemoIslandFor $box 'List'; [void](Invoke-WtMemoBoxEdit $b2 (Get-WtMemoIndentEdit (Get-WtMemoBoxState $b2) -Outdent)) }
            'Alt+Up' { $b2 = Expand-WtMemoIslandFor $box 'Up'; [void](Invoke-WtMemoBoxEdit $b2 (Get-WtMemoMoveLinesEdit (Get-WtMemoBoxState $b2) -Up)) }
            'Alt+Down' { $b2 = Expand-WtMemoIslandFor $box 'Down'; [void](Invoke-WtMemoBoxEdit $b2 (Get-WtMemoMoveLinesEdit (Get-WtMemoBoxState $b2))) }
            'Ctrl+A' {
                # Invoke-WtMemoIslandKey의 'A' 그대로
                $x.Busy++
                try { Close-WtMemoIsland $x } finally { $x.Busy-- }
                $l = $x.Lines.Count - 1
                Open-WtMemoIsland $x 0 $x.Lines.Count 0 0 $l $x.Lines[$l].Length
            }
            'Ctrl+Z' { Invoke-WtMemoUndo $x }
            'Ctrl+Y' { Invoke-WtMemoRedo $x }
            'Ctrl+Home' { [void](Move-WtMemoIsland $x Home) }
            'Ctrl+End' { [void](Move-WtMemoIsland $x End) }
            'Shift+Up' { [void](Move-WtMemoIsland $x Up -Extend) }
            'Shift+Down' { [void](Move-WtMemoIsland $x Down -Extend) }
            'PageDown*' { [void](Move-WtMemoIslandPage $x 1) }   # PageDown 키 대신 (알려진 버그 pagedown-key)
            default { throw "모르는 명령: $cmd" }
        }
    } $Ed $Name (Get-EdBox $Ed)
    Sync-EdUi
}

function Open-EdAt($Ed, [int]$Line, [int]$Col) { & $script:em { param($x, $l, $c) Open-WtMemoIslandAt $x $l $c } $Ed $Line $Col }
function Close-Ed($Ed) { & $script:em { param($x) Close-WtMemoIsland $x } $Ed }
function Get-EdCaret($Ed) {
    $c = & $script:em { param($x) if ($x.Island) { Get-WtMemoIslandCaret $x } else { $x.Caret } } $Ed
    '{0}:{1}' -f $c.Line, $c.Col
}
# 섬 안 커서를 줄 · 칸으로 옮긴다
function Set-EdCaret($Ed, [int]$Line, [int]$Col) {
    $i = & $script:em { param($x, $l, $c) Get-WtMemoIslandIndex $x $l $c } $Ed $Line $Col
    $Ed.IslandBox.Select($i, 0)
}
# 섬 글꼴(스타일) 이름: Memo.Island · Memo.IslandH1..H6 · Memo.IslandCode
function Get-EdIslandStyle($Ed) {
    foreach ($n in @('Memo.Island', 'Memo.IslandCode') + @(1..6 | ForEach-Object { "Memo.IslandH$_" })) {
        if ([object]::ReferenceEquals($Ed.IslandBox.Style, $script:edHost.FindResource($n))) { return $n }
    }
    '(모름)'
}
# 섬에서 한글 조합이 시작 · 끝난 것처럼 알린다 (입력기 없이 TextCompositionManager 이벤트만 올린다)
function Send-EdComposition($Ed, [ValidateSet('Start', 'End')][string]$Stage, [string]$Text = '') {
    $box = $Ed.IslandBox
    $ev = if ($Stage -eq 'Start') { [System.Windows.Input.TextCompositionManager]::PreviewTextInputStartEvent } else { [System.Windows.Input.TextCompositionManager]::PreviewTextInputEvent }
    $tc = [System.Windows.Input.TextComposition]::new([System.Windows.Input.InputManager]::Current, $box, $Text)
    $a = [System.Windows.Input.TextCompositionEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $tc)
    $a.RoutedEvent = $ev
    $box.RaiseEvent($a)
}
# 실행 취소 단위를 끊는다 (사용자가 쉬었다 치는 것처럼)
function Suspend-EdTyping($Ed) { $Ed.LastEdit = [datetime]::MinValue }
# 왼쪽 단추를 누른 채 움직인 MouseEventArgs 흉내. GetPosition은 묻는 요소와 상관없이 $X, $Y를 돌려준다
function New-EdMouseMove([double]$X, [double]$Y) {
    $o = [pscustomobject]@{ LeftButton = 'Pressed'; Point = [System.Windows.Point]::new($X, $Y) }
    $o | Add-Member ScriptMethod GetPosition { param($el) $this.Point }
    $o
}
function Send-EdMouseMove($Ed, [double]$X, [double]$Y) { & $script:em { param($s, $e) Invoke-WtMemoLiveMouseMove $s $e } $Ed.Live (New-EdMouseMove $X $Y) }

# 그린 글에서 $Needle의 $Index번째 글자 왼쪽 끝 + 1px (보기 좌표)
function Get-EdPoint($View, [string]$Needle, [int]$Index = 0) {
    $View.UpdateLayout()
    $tp = $View.Document.ContentStart
    while ($tp) {
        if ($tp.GetPointerContext('Forward') -eq 'Text') {
            $run = $tp.GetTextInRun('Forward')
            $k = $run.IndexOf($Needle, [StringComparison]::Ordinal)
            if ($k -ge 0) {
                $r = $tp.GetPositionAtOffset($k + $Index).GetCharacterRect('Forward')
                return [System.Windows.Point]::new($r.X + 1, $r.Y + $r.Height / 2)
            }
        }
        $tp = $tp.GetNextContextPosition('Forward')
    }
    throw "그린 글에서 '$Needle'을 찾지 못했습니다"
}
function Find-EdHit($Ed, [string]$Needle, [int]$Index = 0) {
    $pt = Get-EdPoint $Ed.Live $Needle $Index
    $h = & $script:em { param($x, $p) Find-WtMemoLiveHit $x $p } $Ed $pt
    if (-not $h) { return '(없음)' }
    '{0}:{1}' -f $h.Line, $h.Col
}

# 보기 문서에서 할 일 체크 표시(Hyperlink, Tag.State)를 찾는다. $Line은 그릴 때 줄 번호(1부터)
function Find-EdTaskLink($View, [int]$Line) {
    $tp = $View.Document.ContentStart
    while ($tp) {
        if ($tp.GetPointerContext('Forward') -eq 'ElementStart') {
            $el = $tp.GetAdjacentElement('Forward')
            if ($el -is [System.Windows.Documents.Hyperlink] -and $el.Tag -is [hashtable] -and $el.Tag.ContainsKey('State') -and $el.Tag.Line -eq $Line) { return $el }
        }
        $tp = $tp.GetNextContextPosition('Forward')
    }
    $null
}
function Invoke-EdTaskClick($View, [int]$Line) {
    $h = Find-EdTaskLink $View $Line
    if (-not $h) { throw "할 일 체크 표시를 찾지 못했습니다 (줄 $Line)" }
    Assert-EdInputPath $View $h.Inlines.FirstInline $h "체크 줄 $Line"
    $h.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent, $h))
}
# 실시간 보기에서 원문이 $UnitText인 단위의 할 일 체크 표시를 누른다 (그릴 때 줄 번호와 상관없이)
function Invoke-EdTaskClickOf($Ed, [string]$UnitText) {
    $sec = @($Ed.Sections | Where-Object { $_ -and $_.Tag.Text -ceq $UnitText })[0]
    if (-not $sec) { throw "단위를 찾지 못했습니다 ($UnitText)" }
    $tp = $sec.ContentStart
    while ($tp -and $tp.CompareTo($sec.ContentEnd) -lt 0) {
        if ($tp.GetPointerContext('Forward') -eq 'ElementStart') {
            $el = $tp.GetAdjacentElement('Forward')
            if ($el -is [System.Windows.Documents.Hyperlink] -and $el.Tag -is [hashtable] -and $el.Tag.ContainsKey('State')) {
                Assert-EdInputPath $Ed.Live $el.Inlines.FirstInline $el '다시 그린 체크 줄'
                $el.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent, $el))
                return
            }
        }
        $tp = $tp.GetNextContextPosition('Forward')
    }
    throw "할 일 체크 표시를 찾지 못했습니다 ($UnitText)"
}

function Assert-EdInputPath($View, $Element, $Target, [string]$Name) {
    $route = Test-WtTestInputPath -View $View -Element $Element -Target $Target -BringIntoView -ClickThrough {
        param($hit, $view)
        & $script:em { param($el, $stop) Test-WtMemoClickThrough $el $stop } $hit $view
    }
    Assert-Ed "숨김 좌표 경로: $Name" $route.Ok $route.Path
}

# ---- 검사 글 ---------------------------------------------------------------------------------------

$sample = @(
    '# 제목 하나'                                       # 0  heading
    ''
    '첫 문단 **굵게** 와 [링크](https://example.com) 글.'  # 2  para (2..3)
    '둘째 줄'
    ''
    '- 항목 1'                                          # 5  list-item
    '- 항목 2'                                          # 6
    '  - 안쪽 2-1'                                      # 7  depth 1
    '  - 안쪽 2-2'                                      # 8  depth 1
    '- 항목 3'                                          # 9
    ''
    '```powershell'                                     # 11 code (11..13)
    'Get-Date'
    '```'
    ''
    '| 이름 | 값 |'                                     # 15 table (15..17)
    '|---|---|'
    '| 1 | 2 |'
    ''
    '> [!note] 콜아웃'                                  # 19 callout (19..20)
    '> 안의 글'
    ''
    '- [ ] 할 일'                                       # 22 list-item (task)
    '- [x] 끝난 일'                                     # 23
    ''
    '끝 문단'                                           # 25 para
)
$sampleText = Join-EdLines $sample

# 긴 글: 마디 하나에 단위 7개(제목 · 문단 · 목록 3 · 코드 · 할 일)
$long = [System.Collections.Generic.List[string]]::new()
for ($k = 1; $k -le 80; $k++) {
    $long.AddRange([string[]]@("## 마디 $k", '', "문단 $k 첫 줄", '둘째 줄', '', "- 가 $k", "- 나 $k", "  - 안 $k", '', '```', "code $k", '```', '', "- [ ] 할 일 $k", ''))
}
$longText = Join-EdLines $long

try {
    $win.Measure([System.Windows.Size]::new(900, 700))
    $win.Arrange([System.Windows.Rect]::new(0, 0, 900, 700))

    Invoke-EdCase '인라인 코드 바탕' {
        $beforeColor = Get-WtSetting 'theme.color'
        try {
            $ed = New-EdEditor
            Set-EdText $ed '본문 `config.json`

> [!note] 안내
> 콜아웃 `config.json`'
            $findCode = {
                param($Blocks)
                foreach ($block in $Blocks) {
                    if ($block -is [System.Windows.Documents.Section]) { & $findCode $block.Blocks }
                    elseif ($block -is [System.Windows.Documents.Paragraph]) {
                        foreach ($inline in $block.Inlines) {
                            if ($inline -is [System.Windows.Documents.Run] -and $inline.Text -ceq 'config.json') { $inline }
                        }
                    }
                }
            }
            $codeRuns = @(& $findCode $ed.Live.Document.Blocks)
            $problems = @(foreach ($name in (Get-WtPalette).Keys) {
                Set-WtSetting 'theme.color' $name
                Sync-EdUi
                $colors = Get-WtThemeColors $name
                $tint = (Get-WtPalette)[$name].Tint
                if ($codeRuns.Count -ne 2 -or $colors['Code.InlineBg'] -cne $tint -or
                    (Get-WtContrast $colors['Text.Primary'] $colors['Code.InlineBg']) -lt 4.5 -or
                    @($codeRuns | Where-Object { $_.Background.Color.ToString() -cne ('#FF' + $tint.TrimStart('#')) }).Count -or
                    $colors['Code.Bg'] -cne $colors['Bg.Subtle']) { $name }
            })
            Assert-Ed '인라인 코드 바탕: 7색 T · 본문/콜아웃 반영 · 대비 4.5:1 · 블록 바탕 유지' (-not $problems) ($problems -join ', ')
        } finally { Set-WtSetting 'theme.color' $beforeColor }
    }

    # ---- 불러오기 · 돌려받기 ----
    Invoke-EdCase '불러오기' {
        $ed = New-EdEditor
        foreach ($nl in "`r`n", "`n") {
            $t = $sample -join $nl
            Set-EdText $ed $t
            $name = if ($nl -eq "`n") { '\n' } else { '\r\n' }
            Assert-Ed "편집기 불러오기($name): 글을 그대로 돌려준다" ((Get-WtMemoEditorText $ed) -ceq $t)
            Assert-Ed "편집기 불러오기($name): 단위 13개 · Section 13개 · 모두 그림" ($ed.Units.Count -eq 13 -and $ed.Sections.Count -eq 13 -and $ed.Rendered -eq 13 -and @($ed.Live.Document.Blocks).Count -eq 13) "($($ed.Units.Count)/$($ed.Rendered)/$(@($ed.Live.Document.Blocks).Count))"
            [void](Test-EdContract $ed "불러오기($name)")
        }
        $kinds = @($ed.Units | ForEach-Object { '{0}{1}' -f $_.Kind, $(if ($_.Depth) { $_.Depth } else { '' }) }) -join ','
        Assert-Ed '편집기 불러오기: 단위 종류 · 깊이' ($kinds -eq 'heading,para,list-item,list-item,list-item1,list-item1,list-item,code,table,callout,list-item,list-item,para') $kinds
        foreach ($t in '', 'a', "a`n", "`n`nb`n", "a`r`n`r`n") {
            Set-EdText $ed $t
            Assert-Ed "편집기 불러오기: 짧은 글 [$($t.Replace("`r", '\r').Replace("`n", '\n'))] 그대로" ((Get-WtMemoEditorText $ed) -ceq $t)
            [void](Test-EdContract $ed '짧은 글')
        }
        Assert-Ed '편집기 불러오기: OnChanged를 부르지 않는다' ($ed.TestChanged -eq 0) "$($ed.TestChanged)"
    }

    Invoke-EdCase '섬 읽기 전용' {
        $ed = New-EdEditor -AsIs
        Set-EdText $ed $sampleText
        Open-EdAt $ed 3 $sample[3].Length
        Send-EdText $ed 'X'
        Send-EdKey $ed Up
        Assert-Ed '편집기 섬: 섬에 글자가 들어가고 섬 안에서 커서가 움직인다 (보기의 읽기 전용을 물려받지 않는다)' (-not $ed.IslandBox.IsReadOnly -and (Get-EdLines $ed)[3] -ceq ($sample[3] + 'X') -and (Get-EdCaret $ed).StartsWith('2:')) "IsReadOnly=$($ed.IslandBox.IsReadOnly) 줄=[$((Get-EdLines $ed)[3])] 커서=$(Get-EdCaret $ed)"
    } -Bug 'island-readonly'

    # ---- 섬 열기 · 고치기 · 닫기 ----
    Invoke-EdCase '섬' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        $sec1 = $ed.Sections[1]
        Open-EdAt $ed 3 2
        [void](Test-EdContract $ed '섬 열기')
        Assert-Ed '편집기 섬: 줄이 든 단위 전체를 연다 (문단 2..3)' ($ed.Island.Start -eq 2 -and $ed.Island.End -eq 4 -and $ed.IslandBox.Text -ceq ($sample[2] + "`r`n" + $sample[3]) -and (Get-EdCaret $ed) -eq '3:2') "$($ed.Island.Start)..$($ed.Island.End) $(Get-EdCaret $ed)"
        Close-Ed $ed
        [void](Test-EdContract $ed '안 고치고 닫기')
        Assert-Ed '편집기 섬: 안 고치고 닫으면 그려 둔 Section을 그대로 돌려놓는다' ([object]::ReferenceEquals($ed.Sections[1], $sec1) -and (Get-EdText $ed) -ceq $sampleText -and $ed.TestChanged -eq 0)

        Open-EdAt $ed 3 $sample[3].Length
        Send-EdText $ed 'X'
        $want = $sample.Clone(); $want[3] += 'X'
        Assert-Ed '편집기 섬: 섬을 연 채로도 글 전체에 고친 것이 보인다' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and $ed.TestChanged -eq 1) "$($ed.TestChanged)"
        [void](Test-EdContract $ed '섬에서 고침')
        Close-Ed $ed
        [void](Test-EdContract $ed '고치고 닫기')
        Assert-Ed '편집기 섬: 고치고 닫으면 줄 목록 · 단위가 바뀐다' ((Join-EdLines @($ed.Lines)) -ceq (Join-EdLines $want) -and $ed.Units[1].Text -ceq ($want[2] + "`n" + $want[3]))

        # 빈 줄에 서면 그 빈 줄만 (앞 단위는 그린 그대로)
        Open-EdAt $ed 4 0
        Assert-Ed '편집기 섬: 빈 줄에서 열면 그 빈 줄만 연다' ($ed.Island.Start -eq 4 -and $ed.Island.End -eq 5 -and $ed.Island.First -eq 2 -and $ed.Island.Last -eq 1) "$($ed.Island.Start)..$($ed.Island.End) First $($ed.Island.First) Last $($ed.Island.Last)"
        [void](Test-EdContract $ed '빈 줄에서 섬')
        Close-Ed $ed

        # \r\n 글을 고쳐도 줄바꿈이 섞이지 않는다
        Set-EdText $ed ($sample -join "`r`n")
        Open-EdAt $ed 5 $sample[5].Length
        Send-EdKey $ed Return
        Send-EdText $ed '새 항목'
        Close-Ed $ed
        $raw = Get-WtMemoEditorText $ed
        Assert-Ed '편집기 섬: \r\n 글에서 고쳐도 줄바꿈은 \r\n 하나로' (-not $raw.Replace("`r`n", '').Contains("`n") -and $raw.Contains("- 항목 1`r`n- 새 항목`r`n- 항목 2"))
        [void](Test-EdContract $ed '\r\n 글 고침')
    }

    # ---- 위아래 · 좌우 이동 ----
    Invoke-EdCase '이동' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 0 0
        $seen = [System.Collections.Generic.List[string]]::new()
        $ok = $true
        for ($n = 0; $n -lt $sample.Count; $n++) {
            Send-EdKey $ed Down
            $seen.Add((Get-EdCaret $ed).Split(':')[0])
            if ($ok) { $ok = Test-EdContract $ed "아래로 $n" }
        }
        Assert-Ed '편집기 ↓: 제목 · 문단 · 목록 · 안쪽 목록 · 코드 · 표 · 콜아웃 · 할 일 · 빈 줄을 차례로 한 줄씩' (($seen -join ',') -eq ((@(1..25) + 25) -join ',')) ($seen -join ',')
        $seen.Clear()
        for ($n = 0; $n -lt $sample.Count; $n++) {
            Send-EdKey $ed Up
            $seen.Add((Get-EdCaret $ed).Split(':')[0])
            if ($ok) { $ok = Test-EdContract $ed "위로 $n" }
        }
        Assert-Ed '편집기 ↑: 빈 줄 포함 거꾸로 한 줄씩, 맨 위에서는 멈춘다' (($seen -join ',') -eq ((@(24..0) + 0) -join ',')) ($seen -join ',')
        Assert-Ed '편집기 이동: 옮겨 다니기만 하면 글 · OnChanged 그대로' ((Get-EdText $ed) -ceq $sampleText -and $ed.TestChanged -eq 0) "$($ed.TestChanged)"

        Set-EdCaret $ed 0 4
        Send-EdKey $ed Down
        Assert-Ed '편집기 ↓: 바로 아래 빈 줄은 0칸' ((Get-EdCaret $ed) -eq '1:0') (Get-EdCaret $ed)
        Open-EdAt $ed 5 4; Send-EdKey $ed Down
        Assert-Ed '편집기 ↓: 빈 줄 없는 이웃 단위에서는 칸을 지킨다' ((Get-EdCaret $ed) -eq '6:4') (Get-EdCaret $ed)
        $style = $null
        Open-EdAt $ed 12 0
        $style = $ed.IslandBox.Style
        Assert-Ed '편집기 섬: 코드 블록은 코드 글꼴 섬, 단위 전체(울타리 포함)' ($ed.Island.Start -eq 11 -and $ed.Island.End -eq 14 -and [object]::ReferenceEquals($style, $edHost.FindResource('Memo.IslandCode')))
        Open-EdAt $ed 0 3
        Assert-Ed '편집기 섬: 제목 하나는 그 단계 글꼴 섬' ([object]::ReferenceEquals($ed.IslandBox.Style, $edHost.FindResource('Memo.IslandH1')))

        Open-EdAt $ed 5 0
        Send-EdKey $ed Left
        Assert-Ed '편집기 ←: 단위 처음에서 바로 앞 빈 줄로' ((Get-EdCaret $ed) -eq '4:0') (Get-EdCaret $ed)
        Send-EdKey $ed Left
        Assert-Ed '편집기 ←: 빈 줄에서 앞 단위의 끝으로' ((Get-EdCaret $ed) -eq "3:$($sample[3].Length)") (Get-EdCaret $ed)
        Send-EdKey $ed Right
        Assert-Ed '편집기 →: 단위 끝에서 바로 뒤 빈 줄로' ((Get-EdCaret $ed) -eq '4:0') (Get-EdCaret $ed)
        Send-EdKey $ed Right
        Assert-Ed '편집기 →: 단위 끝에서 다음 단위의 처음으로' ((Get-EdCaret $ed) -eq '5:0') (Get-EdCaret $ed)
        Invoke-EdCommand $ed 'Ctrl+End'
        Assert-Ed '편집기 Ctrl+End: 마지막 단위의 끝' ((Get-EdCaret $ed) -eq "25:$($sample[25].Length)") (Get-EdCaret $ed)
        Invoke-EdCommand $ed 'Ctrl+Home'
        Assert-Ed '편집기 Ctrl+Home: 첫 단위의 처음' ((Get-EdCaret $ed) -eq '0:0') (Get-EdCaret $ed)
        [void](Test-EdContract $ed 'Ctrl+Home')

        # Shift+↓: 섬을 다음 단위까지 넓혀 고른다
        Set-EdCaret $ed 0 2
        Invoke-EdCommand $ed 'Shift+Down'
        $sel = $ed.IslandBox.SelectedText.Replace("`r`n", "`n")
        Assert-Ed '편집기 Shift+↓: 다음 단위의 같은 칸까지 고른다' ($ed.Island.Start -eq 0 -and $ed.Island.End -ge 4 -and $sel -ceq ($sample[0].Substring(2) + "`n`n" + $sample[2].Substring(0, 2))) "[$sel]"
        [void](Test-EdContract $ed 'Shift+↓')
        Invoke-EdCommand $ed 'Shift+Down'
        $sel = $ed.IslandBox.SelectedText.Replace("`r`n", "`n")
        Assert-Ed '편집기 Shift+↓ 두 번: 그다음 단위까지' ($sel -ceq ($sample[0].Substring(2) + "`n`n" + $sample[2] + "`n" + $sample[3] + "`n`n" + $sample[5].Substring(0, 2))) "[$sel]"
        [void](Test-EdContract $ed 'Shift+↓ 두 번')

        # 빈 글
        Set-EdText $ed ''
        Open-EdAt $ed 0 0
        Send-EdKey $ed Down; Send-EdKey $ed Up; Send-EdKey $ed Left; Send-EdKey $ed Right
        Assert-Ed '편집기 빈 글: 화살표를 눌러도 오류 없이 그대로' ((Get-WtMemoEditorText $ed) -ceq '' -and $ed.Island)
        [void](Test-EdContract $ed '빈 글 이동')
        Send-EdText $ed 'abc'
        Close-Ed $ed
        Assert-Ed '편집기 빈 글: 쓰고 닫으면 단위가 생긴다' ((Get-WtMemoEditorText $ed) -ceq 'abc' -and $ed.Units.Count -eq 1)
        [void](Test-EdContract $ed '빈 글에 쓰기')
    }

    # ---- 지우기로 잇기 ----
    Invoke-EdCase '잇기' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 6 0
        Send-EdKey $ed Back
        $want = [System.Collections.Generic.List[string]]$sample
        $want[5] = '- 항목 1- 항목 2'; $want.RemoveAt(6)
        Assert-Ed '편집기 Backspace: 단위 처음에서 앞 목록 항목과 잇는다' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and (Get-EdCaret $ed) -eq '5:6') (Get-EdCaret $ed)
        [void](Test-EdContract $ed 'Backspace 잇기')
        Close-Ed $ed
        [void](Test-EdContract $ed 'Backspace 잇기 후 닫기')
        Invoke-EdCommand $ed 'Ctrl+Z'
        Assert-Ed '편집기 Backspace 잇기: 실행 취소 한 번에 되돌린다' ((Get-EdText $ed) -ceq $sampleText)
        [void](Test-EdContract $ed 'Backspace 실행 취소')

        Open-EdAt $ed 2 0
        Send-EdKey $ed Back
        $want = [System.Collections.Generic.List[string]]$sample; $want.RemoveAt(1)
        Assert-Ed '편집기 Backspace: 빈 줄 뒤 문단 처음에서는 빈 줄을 지운다' ((Get-EdText $ed) -ceq (Join-EdLines $want))
        Close-Ed $ed
        [void](Test-EdContract $ed 'Backspace 빈 줄')

        Set-EdText $ed $sampleText
        Open-EdAt $ed 0 $sample[0].Length
        Send-EdKey $ed Delete
        Send-EdKey $ed Delete
        $want = [System.Collections.Generic.List[string]]$sample; $want[0] = $sample[0] + $sample[2]; $want.RemoveAt(2); $want.RemoveAt(1)
        Assert-Ed '편집기 Delete: 단위 끝에서 다음 단위와 잇는다 (빈 줄 → 문단 순서로)' ((Get-EdText $ed) -ceq (Join-EdLines $want)) ((Get-EdLines $ed)[0..2] -join ' / ')
        Close-Ed $ed
        [void](Test-EdContract $ed 'Delete 잇기')

        Set-EdText $ed "# H`nP"
        Open-EdAt $ed 0 3
        Send-EdKey $ed Delete
        Assert-Ed '편집기 Delete: 빈 줄 없이 붙은 다음 단위와 잇는다' ((Get-EdText $ed) -ceq '# HP')
        Close-Ed $ed
        [void](Test-EdContract $ed 'Delete 붙은 단위')
        # 섬이 닫혀 있으면 키는 보기(포커스가 있는 곳)로 간다. 보기는 커서 자리에 섬을 열 뿐 글은 바꾸지 않는다
        Sync-EdUi
        $src = [System.Windows.PresentationSource]::FromVisual($script:win)
        foreach ($ev in [System.Windows.Input.Keyboard]::PreviewKeyDownEvent, [System.Windows.Input.Keyboard]::KeyDownEvent) {
            $a = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $src, 0, [System.Windows.Input.Key]::Back)
            $a.RoutedEvent = $ev
            $ed.Live.RaiseEvent($a)
        }
        Sync-EdUi
        Assert-Ed '편집기: 섬이 닫혀 있을 때 키는 글을 바꾸지 않는다' ((Get-EdText $ed) -ceq '# HP') "$((Get-EdText $ed).Replace("`n", '\n'))"
    }
    Invoke-EdCase 'Delete: 섬에서 줄을 늘린 뒤 끝에서 Delete' {
        $ed = New-EdEditor
        Set-EdText $ed "# H`nP"
        Open-EdAt $ed 0 3
        Send-EdKey $ed Return
        Send-EdKey $ed Return
        Send-EdKey $ed Delete
        Assert-Ed '편집기 Delete: 섬에서 줄을 늘린 뒤에도 끝에서 다음 단위와 잇는다' ((Get-EdText $ed) -ceq "# H`n`nP") ((Get-EdText $ed).Replace("`n", '\n'))
        Close-Ed $ed
        [void](Test-EdContract $ed '줄 늘린 뒤 Delete')
    } -Bug 'delete-after-new-lines'

    # ---- 모두 선택 ----
    Invoke-EdCase 'Ctrl+A' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 9 2
        Invoke-EdCommand $ed 'Ctrl+A'
        Assert-Ed '편집기 Ctrl+A: 섬을 글 전체로 넓혀 모두 고른다' ($ed.Island.Start -eq 0 -and $ed.Island.End -eq $sample.Count -and $ed.IslandBox.SelectedText.Replace("`r`n", "`n") -ceq $sampleText)
        [void](Test-EdContract $ed 'Ctrl+A')
        Suspend-EdTyping $ed
        Send-EdText $ed 'z'
        Assert-Ed '편집기 Ctrl+A: 치면 글 전체가 바뀐다' ((Get-EdText $ed) -ceq 'z')
        Close-Ed $ed
        [void](Test-EdContract $ed 'Ctrl+A 후 치기')
        Invoke-EdCommand $ed 'Ctrl+Z'
        Assert-Ed '편집기 Ctrl+A: 실행 취소로 돌아온다' ((Get-EdText $ed) -ceq $sampleText)
        [void](Test-EdContract $ed 'Ctrl+A 실행 취소')
    }

    # ---- 실행 취소 · 다시 실행 ----
    Invoke-EdCase '실행 취소' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        $states = [System.Collections.Generic.List[string]]::new()
        $states.Add((Get-EdText $ed))
        Open-EdAt $ed 3 $sample[3].Length
        Suspend-EdTyping $ed; Send-EdText $ed 'A'; $states.Add((Get-EdText $ed))
        Suspend-EdTyping $ed; Send-EdText $ed 'B'; $states.Add((Get-EdText $ed))
        Send-EdKey $ed Down
        Send-EdKey $ed Down   # 항목 2
        Suspend-EdTyping $ed; Send-EdText $ed 'C'; $states.Add((Get-EdText $ed))
        Open-EdAt $ed 25 0
        Suspend-EdTyping $ed; Send-EdText $ed 'D'; Send-EdText $ed 'E'; $states.Add((Get-EdText $ed))   # 쉬지 않고 친 둘은 한 단위
        $okU = $true
        for ($i = $states.Count - 2; $i -ge 0; $i--) {
            Invoke-EdCommand $ed 'Ctrl+Z'
            if ((Get-EdText $ed) -cne $states[$i]) { $okU = $false; Write-Host "  실행 취소 $i 번째가 다름" }
            [void](Test-EdContract $ed "실행 취소 $i")
        }
        Assert-Ed '편집기 실행 취소: 여러 번 (단위를 옮겨 다닌 편집 포함, 쉬지 않고 친 글은 한 번에)' $okU
        Invoke-EdCommand $ed 'Ctrl+Z'
        Assert-Ed '편집기 실행 취소: 더 없으면 그대로' ((Get-EdText $ed) -ceq $sampleText)
        $okR = $true
        for ($i = 1; $i -lt $states.Count; $i++) {
            Invoke-EdCommand $ed 'Ctrl+Y'
            if ((Get-EdText $ed) -cne $states[$i]) { $okR = $false; Write-Host "  다시 실행 $i 번째가 다름" }
            [void](Test-EdContract $ed "다시 실행 $i")
        }
        Assert-Ed '편집기 다시 실행: 여러 번 (끝까지 왕복)' $okR
        Invoke-EdCommand $ed 'Ctrl+Z'; Invoke-EdCommand $ed 'Ctrl+Z'
        Suspend-EdTyping $ed; Send-EdText $ed 'Q'
        $afterNew = Get-EdText $ed
        Invoke-EdCommand $ed 'Ctrl+Y'
        Assert-Ed '편집기 다시 실행: 새로 고치면 다시 실행 기록을 비운다' ((Get-EdText $ed) -ceq $afterNew -and $ed.Redo.Count -eq 0)
        $caretAfter = Get-EdCaret $ed
        Invoke-EdCommand $ed 'Ctrl+Z'
        Assert-Ed '편집기 실행 취소: 고친 자리로 섬을 연다' ($ed.Island -and (Get-EdCaret $ed) -ne '' ) $caretAfter
        Assert-Ed '편집기 실행 취소: OnChanged를 부른다' ($ed.TestChanged -gt 0)
    }

    # ---- 모드 ----
    Invoke-EdCase '모드' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 3 $sample[3].Length
        Send-EdText $ed 'X'
        $want = $sample.Clone(); $want[3] += 'X'
        $changed = $ed.TestChanged
        $null = Set-WtMemoEditorMode $ed 'source'
        Assert-Ed '편집기 모드 live → source: 섬에서 고친 글 그대로, 섬은 닫힘' ($ed.Source.Text.Replace("`r`n", "`n") -ceq (Join-EdLines $want) -and -not $ed.Island -and (Get-EdText $ed) -ceq (Join-EdLines $want) -and $ed.Source.Visibility -eq 'Visible' -and $ed.Live.Visibility -eq 'Collapsed')
        $ed.Source.CaretIndex = $ed.Source.Text.Length
        Send-EdText $ed 'Y'
        $want[25] += 'Y'
        Assert-Ed '편집기 원문 칸: 치면 글이 바뀌고 OnChanged' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and $ed.TestChanged -eq $changed + 1)
        $changed = $ed.TestChanged
        $null = Set-WtMemoEditorMode $ed 'read'
        Assert-Ed '편집기 모드 source → read: 글 그대로 · 읽기 보기' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and $ed.View.Visibility -eq 'Visible' -and $ed.View.Tag.Text.Replace("`r`n", "`n") -ceq (Join-EdLines $want))
        $null = Set-WtMemoEditorMode $ed 'live'
        [void](Complete-EdRender $ed)
        Assert-Ed '편집기 모드 read → live: 글 그대로' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and $ed.Live.Visibility -eq 'Visible')
        [void](Test-EdContract $ed 'read → live')
        $null = Set-WtMemoEditorMode $ed 'read'
        $null = Set-WtMemoEditorMode $ed 'source'
        $null = Set-WtMemoEditorMode $ed 'live'
        [void](Complete-EdRender $ed)
        [void](Test-EdContract $ed 'live → read → source → live')
        Assert-Ed '편집기 모드: 바꾸기만 하면 OnChanged를 부르지 않는다' ($ed.TestChanged -eq $changed) "$changed → $($ed.TestChanged)"

        # \n 글을 원문 칸에서 고칠 때
        Set-EdText $ed "a`nb"
        $null = Set-WtMemoEditorMode $ed 'source'
        Assert-Ed '편집기 원문 칸: \n 글 그대로' ((Get-WtMemoEditorText $ed) -ceq "a`nb")
        Set-EdText $ed "x`r`ny"
        $null = Set-WtMemoEditorMode $ed 'live'
        [void](Complete-EdRender $ed)
        Assert-Ed '편집기 모드: 원문 모드에서 불러온 글을 실시간에서 그대로' ((Get-WtMemoEditorText $ed) -ceq "x`r`ny" -and $ed.Units.Count -eq 1)
        [void](Test-EdContract $ed '원문에서 불러온 뒤 live')
    }

    Invoke-EdCase '원문 칸 Enter: \n 글' {
        $ed = New-EdEditor
        $null = Set-WtMemoEditorMode $ed 'source'
        Set-EdText $ed "a`nb"
        $null = Set-WtMemoEditorFocus $ed   # TextBox 기본 Enter는 포커스가 있어야 들어간다
        $ed.Source.Select(1, 0)
        Send-EdKey $ed Return
        $raw = Get-WtMemoEditorText $ed
        Assert-Ed '편집기 원문 칸: \n 글에서 Enter를 쳐도 줄바꿈이 섞이지 않는다' ($raw -ceq "a`n`nb") $raw.Replace("`r", '\r').Replace("`n", '\n')
    } -Bug 'source-newline-mix'
    Invoke-EdCase '불러온 직후 실행 취소' {
        $ed = New-EdEditor
        Set-EdText $ed 'first'
        Open-EdAt $ed 0 5
        Send-EdText $ed 'X'            # 다른 메모에서 치다가
        Set-EdText $ed 'second'        # 1.2초 안에 다른 메모를 불러와서
        Open-EdAt $ed 0 6
        Send-EdText $ed 'Y'            # 바로 치면
        Invoke-EdCommand $ed 'Ctrl+Z'
        Assert-Ed '편집기 실행 취소: 불러온 직후 친 글도 실행 취소로 불러온 글로 돌아간다' ((Get-EdText $ed) -ceq 'second') (Get-EdText $ed)
    } -Bug 'undo-after-load'
    Invoke-EdCase '원문 모드에서 고친 뒤 실시간 실행 취소' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 25 $sample[25].Length
        Suspend-EdTyping $ed
        Send-EdText $ed 'A'
        $afterA = Get-EdText $ed
        $null = Set-WtMemoEditorMode $ed 'source'
        $ed.Source.CaretIndex = 0
        Send-EdText $ed 'B'
        $null = Set-WtMemoEditorMode $ed 'live'
        [void](Complete-EdRender $ed)
        Open-EdAt $ed 0 0
        Invoke-EdCommand $ed 'Ctrl+Z'
        Assert-Ed '편집기 실행 취소: 원문 모드에서 고친 것(B)만 먼저 되돌리고 실시간에서 고친 것(A)은 남긴다' ((Get-EdText $ed) -ceq $afterA) "첫 줄 [$((Get-EdLines $ed)[0])] 끝 줄 [$((Get-EdLines $ed)[-1])] (기대: 첫 줄에 B 없음, 끝 줄에 A 있음)"
    } -Bug 'undo-after-source-edit'
    Invoke-EdCase '글자 크기 바꾸기' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        $old = Get-WtSetting 'ui.fontScale'
        try {
            Set-WtSetting 'ui.fontScale' 'l'
            [void](Complete-EdRender $ed)
            [void](Test-EdContract $ed '글자 크기 (섬 없음)')
            Open-EdAt $ed 6 0
            Set-WtSetting 'ui.fontScale' 's'
            [void](Test-EdContract $ed '글자 크기 (섬 열림)')
            Close-Ed $ed
            [void](Complete-EdRender $ed)
            [void](Test-EdContract $ed '글자 크기 뒤 섬 닫기')
            Assert-Ed '편집기 글자 크기: 바꿔도 글 · 문서 약속 그대로' ((Get-EdText $ed) -ceq $sampleText -and $ed.TestChanged -eq 0)
        } finally { Set-WtSetting 'ui.fontScale' $old }
    }

    # ---- 편집 명령: 섬과 원문 칸이 같은 글을 만들고, 실시간에서는 실행 취소 한 번에 ----
    $cmdCases = @(
        @{ Name = 'Ctrl+B (고른 글 굵게)'; Line = 3; Col = 0; Sel = 2; Do = { param($x) Invoke-EdCommand $x 'Ctrl+B' }; Want = { param($w) $w[3] = '**둘째** 줄' } }
        @{ Name = 'Enter (목록 이어 쓰기)'; Line = 5; Col = 6; Sel = 0; Do = { param($x) Send-EdKey $x Return }; Want = { param($w) $w[5] = "- 항목 1`n- " } }
        @{ Name = 'Tab (목록 들여쓰기)'; Line = 9; Col = 4; Sel = 0; Do = { param($x) Send-EdKey $x Tab }; Want = { param($w) $w[9] = '  - 항목 3' }; Depth = @(9, 1) }
        @{ Name = 'Shift+Tab (안쪽 목록 내어쓰기)'; Line = 8; Col = 4; Sel = 0; Do = { param($x) Invoke-EdCommand $x 'Shift+Tab' }; Want = { param($w) $w[8] = '- 안쪽 2-2' } }
        @{ Name = 'Alt+↑ (줄 옮기기)'; Line = 9; Col = 2; Sel = 0; Do = { param($x) Invoke-EdCommand $x 'Alt+Up' }; Want = { param($w) $w[8] = '- 항목 3'; $w[9] = '  - 안쪽 2-2' } }
        @{ Name = 'Ctrl+L (할 일)'; Line = 25; Col = 0; Sel = 0; Do = { param($x) Invoke-EdCommand $x 'Ctrl+L' }; Want = { param($w) $w[25] = '- [ ] 끝 문단' } }
    )
    foreach ($c in $cmdCases) {
        Invoke-EdCase "편집 명령 $($c.Name)" {
            $want = $sample.Clone()
            & $c.Want $want
            $wantText = Join-EdLines $want
            # 실시간 (섬)
            $ed = New-EdEditor
            Set-EdText $ed $sampleText
            Open-EdAt $ed $c.Line $c.Col
            if ($c.Sel) { $b = $ed.IslandBox; $b.Select($b.SelectionStart, $c.Sel) }
            & $c.Do $ed
            $liveText = Get-EdText $ed
            [void](Test-EdContract $ed "$($c.Name) 섬")
            Close-Ed $ed
            [void](Test-EdContract $ed "$($c.Name) 닫기")
            Assert-Ed "편집기 $($c.Name): 섬에서 글을 바르게 바꾼다" ($liveText -ceq $wantText) ($liveText.Replace("`n", '¶'))
            if ($c.Depth) {
                $u = @($ed.Units | Where-Object { $_.Start -eq $c.Depth[0] })[0]
                Assert-Ed "편집기 $($c.Name): 그 항목이 안쪽 목록 깊이 $($c.Depth[1])" ($u -and $u.Kind -eq 'list-item' -and $u.Depth -eq $c.Depth[1]) "$($u.Kind) d$($u.Depth)"
            }
            Invoke-EdCommand $ed 'Ctrl+Z'
            Assert-Ed "편집기 $($c.Name): 실시간에서 실행 취소 한 번에 되돌린다" ((Get-EdText $ed) -ceq $sampleText) ((Get-EdText $ed).Replace("`n", '¶'))
            [void](Test-EdContract $ed "$($c.Name) 실행 취소")
            # 원문 칸
            $null = Set-WtMemoEditorMode $ed 'source'
            Set-EdText $ed $sampleText
            $idx = 0
            for ($i = 0; $i -lt $c.Line; $i++) { $idx += $sample[$i].Length + 1 }
            $ed.Source.Select($idx + $c.Col, $c.Sel)
            & $c.Do $ed
            Assert-Ed "편집기 $($c.Name): 원문 칸에서 글을 바르게 바꾼다" ((Get-EdText $ed) -ceq $wantText) ((Get-EdText $ed).Replace("`n", '¶'))
        }
    }

    Invoke-EdCase '입력경로' {
        $picturePath = Join-Path $test.Root 'input-path.png'
        $pixels = [byte[]]::new(32 * 16 * 4)
        for ($i=3; $i -lt $pixels.Length; $i+=4) { $pixels[$i] = 255 }
        $bitmap = [Windows.Media.Imaging.BitmapSource]::Create(32,16,96,96,[Windows.Media.PixelFormats]::Bgra32,$null,$pixels,32*4)
        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream = [IO.File]::Create($picturePath); try { $encoder.Save($stream) } finally { $stream.Dispose() }
        $picture = $picturePath.Replace('\','/'); $missing = (Join-Path $test.Root 'missing-input.png').Replace('\','/')
        $body = @('[일반 링크](https://example.invalid/plain)', '', '[[시험 문서]]', '',
            "[![성공 그림](<$picture>)](https://example.invalid/image)", '',
            "[![실패 그림](<$missing>)](https://example.invalid/missing)", '',
            '| 열 | 그림 |', '|---|---|', "| 예 | [![표 그림](<$picture>)](https://example.invalid/table) |", '',
            '```text', 'callback sample', '```', '', '> [!note]+ 접기 제목', '> 접는 본문', '', '일반 본문') -join "`n"
        foreach ($mode in 'live','read') {
            $ed = New-EdEditor; $ed.TestLinks = [Collections.Generic.List[string]]::new()
            $ed.OnLink = { param($editor,$link,$how) $editor.TestLinks.Add($link.Kind); $true }
            Set-EdText $ed $body; $null = Set-WtMemoEditorMode $ed $mode
            $view = if ($mode -eq 'live') { $ed.Live } else { $ed.View }
            $links = [Collections.Generic.List[object]]::new(); $plain = $null
            $pointer = $view.Document.ContentStart
            while ($pointer) {
                if ($pointer.GetPointerContext('Forward') -eq 'ElementStart') {
                    $element = $pointer.GetAdjacentElement('Forward')
                    if ($element -is [Windows.Documents.Hyperlink]) { $links.Add($element) }
                    if ($element -is [Windows.Documents.Run] -and $element.Text -ceq '일반 본문') { $plain = $element }
                }
                $pointer = $pointer.GetNextContextPosition('Forward')
            }
            Assert-Ed "숨김 입력 경로 준비: $mode · 링크 6개" ($links.Count -eq 6)
            foreach ($link in $links) {
                $inline = $link.Inlines.FirstInline
                $element = if ($inline -is [Windows.Documents.InlineUIContainer]) { $inline.Child } else { $inline }
                if ($inline -is [Windows.Documents.InlineUIContainer]) {
                    $wait = [Diagnostics.Stopwatch]::StartNew()
                    while ($element.Tag.Work -and -not $element.Tag.Work.Finished -and $wait.ElapsedMilliseconds -lt 2000) { Update-WtWork; Wait-EdUi 10 }
                    $wanted = if ($link.Tag.Link.Target -like '*/missing') { [Windows.Controls.TextBlock] } else { [Windows.Controls.Image] }
                    Assert-Ed "이미지 링크 상태: $mode · $($link.Tag.Link.Target)" ($element.Child -is $wanted)
                    if ($mode -eq 'live') {
                        # 수정 전 판정 그대로: 시각 부모를 먼저 택해 논리 Hyperlink를 잃는다.
                        $old = Test-WtTestInputPath -View $view -Element $element -Target $link -BringIntoView -ClickThrough {
                            param($hit,$stop)
                            & $script:em {
                                param($node,$end)
                                while ($node -and $node -ne $end) {
                                    if ($node -is [Windows.Controls.Primitives.ButtonBase] -or $node -is [Windows.Documents.Hyperlink] -or $node -is [Windows.Controls.Primitives.ScrollBar] -or $node -is [Windows.Controls.TextBox]) { return $true }
                                    $node = Get-WtMemoParent $node
                                }
                                $false
                            } $hit $stop
                        }
                        Assert-Ed "이미지 링크 고장 대조군: $($link.Tag.Link.Target) · 이전 click-through=False" ($old.Reached -and $old.ClickThrough -eq $false -and -not $old.Ok) $old.Path
                    }
                }
                Assert-EdInputPath $view $element $link "$mode · $($link.ToolTip)"
                if ($link.ToolTip -ceq '접기 / 펼치기') {
                    $open = $link.Tag.Open; $link.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
                    Assert-Ed "콜아웃 콜백: $mode · 접기" ($link.Tag.Open -ne $open)
                } else {
                    $count = $ed.TestLinks.Count; $link.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Documents.Hyperlink]::ClickEvent))
                    Assert-Ed "링크 콜백: $mode · $($link.Tag.Link.Kind)" ($ed.TestLinks.Count -eq $count + 1)
                }
            }
            $copy = Get-WtVisualChild $view ([Windows.Controls.Button])
            Assert-Ed "코드 복사 단추 준비: $mode" ($copy -and $copy.ToolTip -ceq '코드 복사')
            Assert-EdInputPath $view $copy $copy "$mode · 코드 복사"
            $markdown = Get-Module Markdown
            $originalCopy = & $markdown { (Get-Command Copy-WtMdCode).ScriptBlock }
            try {
                & $markdown { $script:inputTestCopied = ''; function script:Copy-WtMdCode($button) { $script:inputTestCopied = [string]$button.Tag } }
                $copy.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
                Assert-Ed "코드 복사 콜백: $mode · 클립보드 통로는 대역" ((& $markdown { $script:inputTestCopied }) -clike '*callback sample*')
            } finally { & $markdown { param($original) Set-Item function:script:Copy-WtMdCode $original } $originalCopy }
            if ($mode -eq 'live') {
                $route = Test-WtTestInputPath -View $view -Element $plain -Target $plain -BringIntoView -ClickThrough { param($hit,$stop) & $script:em { param($el,$end) Test-WtMemoClickThrough $el $end } $hit $stop }
                Assert-Ed '일반 본문: 좌표 도달 · click-through=False 유지' ($route.Reached -and $route.ClickThrough -eq $false) $route.Path
            }
            Assert-Ed "입력 경로 확인: $mode · 본문·섬 그대로" ((Get-EdText $ed) -ceq $body -and -not $ed.Island)
        }
    }

    # ---- 할 일 콜백 + 숨김 좌표 경로 ----
    Invoke-EdCase '할 일' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Invoke-EdTaskClick $ed.Live 23
        $want = $sample.Clone(); $want[22] = '- [x] 할 일'
        Assert-Ed '편집기 할 일 콜백(실시간): [ ] → [x], 섬은 닫힘, OnChanged' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and -not $ed.Island -and $ed.TestChanged -eq 1) "$($ed.TestChanged)"
        [void](Test-EdContract $ed '할 일 누름')
        Invoke-EdTaskClick $ed.Live 24
        $want[23] = '- [ ] 끝난 일'
        Assert-Ed '편집기 할 일 콜백(실시간): [x] → [ ]' ((Get-EdText $ed) -ceq (Join-EdLines $want))
        [void](Test-EdContract $ed '할 일 해제')
        Invoke-EdCommand $ed 'Ctrl+Z'
        $want[23] = '- [x] 끝난 일'
        Assert-Ed '편집기 할 일(실시간): 실행 취소 한 번에 하나씩' ((Get-EdText $ed) -ceq (Join-EdLines $want))
        [void](Test-EdContract $ed '할 일 실행 취소')

        # 섬에서 위쪽 줄 수를 바꾼 채로 누르면 바뀐 줄 번호로
        Set-EdText $ed $sampleText
        Open-EdAt $ed 3 $sample[3].Length
        Send-EdKey $ed Return
        Send-EdText $ed '덧줄'
        Invoke-EdTaskClick $ed.Live 23
        $want = [System.Collections.Generic.List[string]]$sample; $want[22] = '- [x] 할 일'; $want.Insert(4, '덧줄')
        Assert-Ed '편집기 할 일 콜백(실시간): 위쪽 섬에서 줄을 늘려도 같은 항목' ((Get-EdText $ed) -ceq (Join-EdLines $want)) (((Get-EdLines $ed)[22..24]) -join ' / ')
        [void](Test-EdContract $ed '섬 연 채로 할 일')

        # 읽기 모드
        Set-EdText $ed $sampleText
        $null = Set-WtMemoEditorMode $ed 'read'
        $changed = $ed.TestChanged
        Invoke-EdTaskClick $ed.View 23
        $want = $sample.Clone(); $want[22] = '- [x] 할 일'
        Assert-Ed '편집기 할 일 콜백(읽기): [x], 보기를 다시 그리고 OnChanged' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and $ed.TestChanged -eq $changed + 1 -and $ed.View.Tag.Text -ceq (Join-EdLines $want))
        Invoke-EdTaskClick $ed.View 23
        Assert-Ed '편집기 할 일 콜백(읽기): 다시 호출하면 [ ]' ((Get-EdText $ed) -ceq $sampleText)
        $null = Set-WtMemoEditorMode $ed 'live'
    }

    Invoke-EdCase '할 일: 위쪽에 항목을 더한 뒤' {
        $ed = New-EdEditor
        Set-EdText $ed "- [ ] a`n- [ ] b`n- [ ] c"
        Open-EdAt $ed 0 7
        Send-EdKey $ed Return
        Send-EdText $ed 'n'
        Close-Ed $ed
        Invoke-EdTaskClickOf $ed '- [ ] c'
        Assert-Ed '편집기 할 일 콜백(실시간): 위쪽 항목 추가 뒤에도 같은 항목 (다시 쓴 Section의 줄 번호)' ((Get-EdText $ed) -ceq "- [ ] a`n- [ ] n`n- [ ] b`n- [x] c") ((Get-EdText $ed).Replace("`n", '¶'))
        [void](Test-EdContract $ed '위쪽에 항목 더한 뒤 할 일')
    }

    # ---- 누른 자리 → 줄 · 칸 ----
    Invoke-EdCase '클릭 위치' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        $cases = @(
            @('제목', '제목 하나', 1, '0:3'), @('문단 첫 글자', '첫 문단', 0, '2:0'), @('굵게', '굵게', 1, '2:8'),
            @('링크', '링크', 1, "2:$($sample[2].IndexOf('크'))"), @('둘째 줄', '둘째', 1, '3:1'), @('목록', '항목 2', 1, '6:3'),
            @('안쪽 목록', '안쪽 2-1', 1, '7:5'), @('코드', 'Get-Date', 4, '12:4'),
            @('콜아웃', '안의 글', 1, '20:3'), @('할 일', '끝난 일', 1, '23:7')
        )
        foreach ($cs in $cases) {
            $got = Find-EdHit $ed $cs[1] $cs[2]
            Assert-Ed "편집기 클릭 위치($($cs[0])): 원문 줄 · 칸" ($got -eq $cs[3]) "기대 $($cs[3]) 결과 $got"
        }
        Open-EdAt $ed 3 $sample[3].Length
        Send-EdKey $ed Return
        Send-EdText $ed '덧줄'
        $got = Find-EdHit $ed '항목 2' 1
        Assert-Ed '편집기 클릭 위치: 위쪽 섬에서 줄이 늘었으면 그만큼 아래로' ($got -eq '7:3') $got
        $hit = & $em { param($x, $p) Find-WtMemoLiveHit $x $p } $ed (Get-EdPoint $ed.Live '항목 2' 1)
        Open-EdAt $ed $hit.Line $hit.Col
        Assert-Ed '편집기 클릭: 그 자리로 섬을 연다 (섬을 닫은 뒤 기준)' ((Get-EdCaret $ed) -eq '7:3' -and (Get-EdLines $ed)[7] -ceq '- 항목 2') (Get-EdCaret $ed)
        [void](Test-EdContract $ed '클릭으로 섬 옮김')
    }
    Invoke-EdCase '끌어 고르기' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 3 0
        $ed.Live.UpdateLayout()
        # 다른 단위를 누르면 섬을 그리로 옮기고 마우스를 잡는다. 잡는 순간 이동이 바로 온다(섬은 아직 배치 전)
        Open-EdAt $ed 6 2
        $ed.Drag = @{ Line = 6; Col = 2 }
        $err = $null
        try { Send-EdMouseMove $ed 5 5 } catch { $err = $_.Exception.Message }
        Assert-Ed '편집기 끌기: 섬을 옮긴 직후의 이동에 오류가 나지 않는다' (-not $err -and (Get-EdCaret $ed) -eq '6:2') "$err / 커서 $(Get-EdCaret $ed)"
        # 배치가 끝난 뒤 섬 안에서 끌면 누른 자리부터 고른다
        $ed.Live.UpdateLayout()
        $box = $ed.IslandBox
        $r = $box.GetRectFromCharacterIndex($box.Text.Length - 1)
        Send-EdMouseMove $ed ($r.X + 1) ($r.Y + $r.Height / 2)
        Assert-Ed '편집기 끌기: 섬 안에서 끌면 누른 자리부터 고른다' ($box.SelectionStart -eq 2 -and $box.SelectionLength -gt 0) "Start $($box.SelectionStart) Length $($box.SelectionLength)"
        $ed.Drag = $null
        [void](Test-EdContract $ed '끌어 고르기')
    }
    Invoke-EdCase '클릭 위치: 공백 뒤 · 기호 뒤' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        # 그린 글자 바로 앞을 누르면 원문에서도 그 글자 바로 앞 (공백 · 표 칸 구분 앞이 아니라)
        $cases = @(@('공백 뒤 글자', '끝 문단', 2, '25:2'), @('표 둘째 칸', '값', 0, "15:$($sample[15].IndexOf('값'))"), @('제목 첫 글자 (# 뒤)', '제목 하나', 0, '0:2'), @('목록 첫 글자 (- 뒤)', '항목 3', 0, '9:2'))
        foreach ($cs in $cases) {
            $got = Find-EdHit $ed $cs[1] $cs[2]
            Assert-Ed "편집기 클릭 위치($($cs[0])): 원문 줄 · 칸" ($got -eq $cs[3]) "기대 $($cs[3]) 결과 $got"
        }
    } -Bug 'hit-offset'

    # ---- 상태 · 포커스 ----
    Invoke-EdCase '상태' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 6 3
        $st = Get-WtMemoEditorState $ed
        Assert-Ed '편집기 상태(실시간): 섬 커서의 줄 · 칸' ($st.Line -eq 6 -and $st.Col -eq 3) "$($st.Line):$($st.Col)"
        Set-EdText $ed $sampleText
        $null = Set-WtMemoEditorState $ed @{ Line = 9; Col = 2; Scroll = 0; Caret = $null }
        $null = Set-WtMemoEditorFocus $ed
        Assert-Ed '편집기 상태(실시간): 돌려놓고 포커스하면 그 자리에 섬' ((Get-EdCaret $ed) -eq '9:2') (Get-EdCaret $ed)
        Set-EdText $ed $sampleText
        $null = Set-WtMemoEditorState $ed @{ Line = 999; Col = 999; Scroll = 0 }
        Assert-Ed '편집기 상태: 범위 밖 줄 · 칸은 끝으로 줄인다' ($ed.Caret.Line -eq 25 -and $ed.Caret.Col -eq $sample[25].Length) "$($ed.Caret.Line):$($ed.Caret.Col)"
        $null = Set-WtMemoEditorMode $ed 'source'
        # 상태는 모드와 상관없이 줄 · 칸 (원문 칸에서는 그 자리의 글자 위치로 바꿔 넣는다)
        $null = Set-WtMemoEditorState $ed @{ Line = 2; Col = 3; Scroll = 0 }
        $st = Get-WtMemoEditorState $ed
        $want = (($ed.Source.Text -split "`r?`n")[0..1] | ForEach-Object { $_.Length + $(if ($ed.Source.Text.Contains("`r`n")) { 2 } else { 1 }) } | Measure-Object -Sum).Sum + 3
        Assert-Ed '편집기 상태(원문): 커서 줄 · 칸' ($st.Line -eq 2 -and $st.Col -eq 3 -and $ed.Source.CaretIndex -eq $want) "$($st.Line):$($st.Col) 커서 $($ed.Source.CaretIndex) 기대 $want"
        $null = Set-WtMemoEditorMode $ed 'live'
        [void](Complete-EdRender $ed)
        Assert-Ed '편집기 상태: OnChanged를 부르지 않는다' ($ed.TestChanged -eq 0)
    }
    Invoke-EdCase '포커스 -End (섬이 열려 있을 때)' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 0 0
        $null = Set-WtMemoEditorFocus $ed -End
        Assert-Ed '편집기 포커스 -End: 섬이 열려 있어도 글 끝으로' ((Get-EdCaret $ed) -eq "25:$($sample[25].Length)") (Get-EdCaret $ed)
    } -Bug 'focus-end-with-island'

    # ---- 코드 울타리 ----
    Invoke-EdCase '코드 울타리 열기' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 3 $sample[3].Length
        Send-EdKey $ed Return
        Send-EdText $ed '```'
        Close-Ed $ed
        [void](Complete-EdRender $ed)
        [void](Test-EdContract $ed '울타리 열기')
        $kinds = @($ed.Units | ForEach-Object Kind) -join ','
        Assert-Ed '편집기 울타리: ``` 하나를 새로 열면 전체를 다시 나눈다 (아래가 코드로)' ($ed.Units[1].Kind -eq 'para' -and $ed.Units[2].Kind -eq 'code' -and $ed.Units[2].Start -eq 4) $kinds
        Invoke-EdCommand $ed 'Ctrl+Z'
        [void](Complete-EdRender $ed)
        Assert-Ed '편집기 울타리: 실행 취소로 원래대로' ((Get-EdText $ed) -ceq $sampleText -and $ed.Units.Count -eq 13)
        [void](Test-EdContract $ed '울타리 실행 취소')
        Open-EdAt $ed 13 3
        Send-EdKey $ed Back
        Close-Ed $ed
        [void](Complete-EdRender $ed)
        [void](Test-EdContract $ed '닫는 울타리 지우기')
    }
    Invoke-EdCase '코드 울타리 종류 바꾸기' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 11 0
        $b = $ed.IslandBox
        $b.Select(0, 3); $b.SelectedText = '~~~'
        Close-Ed $ed
        [void](Complete-EdRender $ed)
        Assert-EdContract $ed '편집기 울타리: ``` → ~~~ 로 바꾸면 아래도 다시 나눈다'
        Set-EdText $ed $sampleText
        Open-EdAt $ed 11 0
        $b = $ed.IslandBox
        $b.Select(0, 0); $b.SelectedText = '`'
        Close-Ed $ed
        [void](Complete-EdRender $ed)
        Assert-EdContract $ed '편집기 울타리: ``` → ```` 로 늘리면 아래도 다시 나눈다'
    } -Bug 'fence-kind-change'
    Invoke-EdCase '목록 아래 들여쓴 줄' {
        $ed = New-EdEditor
        Set-EdText $ed "- a`n`nb`n`nc"
        Open-EdAt $ed 2 0
        Send-EdText $ed '  '
        Close-Ed $ed
        Assert-EdContract $ed '편집기: 목록 아래 빈 줄 다음 줄을 들여쓰면(목록 항목에 이어지는 문단) 그 목록과 같이 다시 나눈다'
    } -Bug 'list-continuation'
    Invoke-EdCase '빈 목록 항목 옆 고치기' {
        $ed = New-EdEditor
        Set-EdText $ed "x`n`n1. `n> q"
        Open-EdAt $ed 3 3
        Send-EdText $ed 'a'
        Close-Ed $ed
        Assert-EdContract $ed '편집기: 빈 목록 항목(1. ) 바로 아래를 고쳐도 글 전체로 나눈 것과 같다'
    } -Bug 'empty-list-item'
    Invoke-EdCase 'HTML 주석 열기' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Open-EdAt $ed 3 $sample[3].Length
        Send-EdKey $ed Return
        Send-EdText $ed '<!--'
        Close-Ed $ed
        [void](Complete-EdRender $ed)
        Assert-EdContract $ed '편집기: <!-- 를 열면 아래(닫는 --> 까지)도 다시 나눈다'
    } -Bug 'html-comment-open'

    # ---- Enter로 블록이 나뉠 때: 커서가 있는 블록만 원문, 나머지는 바로 그린다 ----
    Invoke-EdCase 'Enter: 제목 뒤 · 코드 블록 쓰기' {
        $ed = New-EdEditor
        Set-EdText $ed '# 임'
        Open-EdAt $ed 0 3
        Send-EdKey $ed Return
        [void](Test-EdContract $ed '제목 뒤 Enter')
        Assert-Ed '편집기 Enter: 제목 끝에서 Enter를 치면 제목은 바로 그리고 섬은 새 줄만 (본문 글꼴)' ((Get-EdText $ed) -ceq "# 임`n" -and $ed.Island.Start -eq 1 -and $ed.Island.First -eq 1 -and (Get-EdCaret $ed) -eq '1:0' -and (Get-EdIslandStyle $ed) -eq 'Memo.Island') "섬 $($ed.Island.Start)..$($ed.Island.End) First $($ed.Island.First) 커서 $(Get-EdCaret $ed) $(Get-EdIslandStyle $ed)"
        # ``` 자동 닫기 → 언어 → Enter → 코드 (실제 입력처럼 ` 를 하나씩)
        foreach ($ch in '`', '`', '`') { Send-EdText $ed $ch }
        Send-EdText $ed 'python'
        Send-EdKey $ed Return
        Send-EdText $ed 'print(1)'
        [void](Test-EdContract $ed '코드 블록 쓰는 중')
        Assert-Ed '편집기 Enter: 코드 블록을 쓰는 동안 제목은 그린 그대로, 섬은 코드 블록만 (코드 글꼴)' ((Get-EdText $ed) -ceq "# 임`n``````python`nprint(1)`n``````" -and $ed.Island.Start -eq 1 -and @($ed.IslandBox.Text -split "\r?\n").Count -eq 3 -and (Get-EdIslandStyle $ed) -eq 'Memo.IslandCode') "글 [$((Get-EdText $ed).Replace("`n", '¶'))] 섬 $($ed.Island.Start)..$($ed.Island.End) $(Get-EdIslandStyle $ed)"
        # 닫는 울타리 뒤에서 Enter → 코드 블록 밖 글
        Set-EdCaret $ed 3 3
        Send-EdKey $ed Return
        Send-EdText $ed '뒤 글'
        [void](Test-EdContract $ed '닫는 울타리 뒤 Enter')
        $code = @($ed.Units | Where-Object { $_.Kind -eq 'code' })
        Assert-Ed '편집기 Enter: 닫는 ``` 뒤에서 Enter를 치면 코드 블록은 바로 그리고, 새 줄은 코드 바탕 없이 본문 글꼴' ((Get-EdText $ed) -ceq "# 임`n``````python`nprint(1)`n```````n뒤 글" -and $code.Count -eq 1 -and $ed.Island.Start -eq 4 -and $ed.Island.First -eq 2 -and (Get-EdIslandStyle $ed) -eq 'Memo.Island') "섬 $($ed.Island.Start)..$($ed.Island.End) First $($ed.Island.First) $(Get-EdIslandStyle $ed)"
        # 둘째 백틱은 커서만 옮기므로 변경 알림을 만들지 않는다.
        Assert-Ed '편집기 Enter: 블록을 나눠도 OnChanged는 고칠 때마다 한 번씩' ($ed.TestChanged -eq 8) "$($ed.TestChanged)"
        Close-Ed $ed
        [void](Test-EdContract $ed '코드 블록 쓰고 닫기')
        $guard = 0
        while ($ed.Undo.Count -and $guard -lt 50) { Invoke-EdCommand $ed 'Ctrl+Z'; $guard++ }
        Assert-Ed '편집기 Enter: 블록을 나눈 뒤에도 실행 취소를 끝까지 하면 처음 글' ((Get-EdText $ed) -ceq '# 임') "($guard 번) [$((Get-EdText $ed).Replace("`n", '¶'))]"
        [void](Test-EdContract $ed '코드 블록 실행 취소 끝')
    }
    Invoke-EdCase 'Enter: 코드 블록 섬에서 닫는 울타리 뒤' {
        $ed = New-EdEditor
        Set-EdText $ed "``````ps`nGet-Date`n``````"
        Open-EdAt $ed 2 3
        $before = Get-EdIslandStyle $ed
        Send-EdKey $ed Return
        Send-EdText $ed 'abc'
        [void](Test-EdContract $ed '코드 섬 닫는 울타리 뒤')
        Assert-Ed '편집기 Enter: 코드 블록 섬의 닫는 ``` 뒤 Enter → 그 줄은 코드 섬 밖 (코드 바탕 없음)' ($before -eq 'Memo.IslandCode' -and $ed.Island.Start -eq 3 -and $ed.Island.First -eq 1 -and (Get-EdIslandStyle $ed) -eq 'Memo.Island') "처음 $before → 섬 $($ed.Island.Start)..$($ed.Island.End) First $($ed.Island.First) $(Get-EdIslandStyle $ed)"
        Close-Ed $ed
        Assert-Ed '편집기 Enter: 닫는 ``` 뒤 글은 코드 블록 밖 문단' ((Get-EdText $ed) -ceq "``````ps`nGet-Date`n```````nabc" -and (@($ed.Units | ForEach-Object Kind) -join ',') -eq 'code,para') (@($ed.Units | ForEach-Object Kind) -join ',')
        [void](Test-EdContract $ed '코드 섬 닫기')
    }
    Invoke-EdCase '코드 블록 아래 빈 줄 누르기' {
        $ed = New-EdEditor
        Set-EdText $ed "``````ps`nGet-Date`n```````n"
        Open-EdAt $ed 3 0
        [void](Test-EdContract $ed '코드 아래 빈 줄 섬')
        Assert-Ed '편집기 섬: 코드 블록 아래 빈 줄에서 열면 그 빈 줄만 (코드 블록은 그린 그대로, 본문 글꼴)' ($ed.Island.Start -eq 3 -and $ed.Island.End -eq 4 -and $ed.Island.First -eq 1 -and (Get-EdIslandStyle $ed) -eq 'Memo.Island') "섬 $($ed.Island.Start)..$($ed.Island.End) First $($ed.Island.First) $(Get-EdIslandStyle $ed)"
        Send-EdText $ed 'abc'
        Close-Ed $ed
        Assert-Ed '편집기 섬: 코드 블록 아래 빈 줄에 쓴 글은 문단' ((Get-EdText $ed) -ceq "``````ps`nGet-Date`n```````nabc" -and $ed.Units.Count -eq 2 -and $ed.Units[1].Kind -eq 'para')
        [void](Test-EdContract $ed '코드 아래 빈 줄에 쓰기')
    }
    Invoke-EdCase 'Enter: 목록 · 문단' {
        $ed = New-EdEditor
        Set-EdText $ed '- a'
        Open-EdAt $ed 0 3
        Send-EdKey $ed Return
        [void](Test-EdContract $ed '목록 Enter')
        Assert-Ed '편집기 Enter: 목록 이어 쓰기 뒤 앞 항목은 바로 그리고 섬은 새 항목만' ((Get-EdText $ed) -ceq "- a`n- " -and $ed.Island.Start -eq 1 -and $ed.Island.First -eq 1 -and (Get-EdCaret $ed) -eq '1:2') "섬 $($ed.Island.Start)..$($ed.Island.End) 커서 $(Get-EdCaret $ed)"
        Send-EdText $ed 'b'
        Invoke-EdCommand $ed 'Ctrl+Z'
        Invoke-EdCommand $ed 'Ctrl+Z'
        Assert-Ed '편집기 Enter: 목록 이어 쓰기를 나눈 뒤에도 실행 취소로 처음 글' ((Get-EdText $ed) -ceq '- a') (Get-EdText $ed)
        [void](Test-EdContract $ed '목록 Enter 실행 취소')
        Set-EdText $ed 'abc'
        Open-EdAt $ed 0 1
        Send-EdKey $ed Return
        Assert-Ed '편집기 Enter: 문단 가운데 Enter(같은 문단)는 섬 그대로' ((Get-EdText $ed) -ceq "a`nbc" -and $ed.Island.Start -eq 0 -and $ed.Island.End -eq 1 -and (Get-EdCaret $ed) -eq '1:0') "섬 $($ed.Island.Start)..$($ed.Island.End) 커서 $(Get-EdCaret $ed)"
        [void](Test-EdContract $ed '문단 가운데 Enter')
    }
    Invoke-EdCase 'Enter: 한글 조합 중' {
        $ed = New-EdEditor
        Set-EdText $ed '# 임'
        Open-EdAt $ed 0 3
        # 조합이 이어지는 동안 줄이 바뀌어도(입력기가 넣은 줄바꿈) 섬을 옮기지 않는다
        Send-EdComposition $ed Start
        $b = $ed.IslandBox
        $b.SelectedText = "`r`n"; $b.Select($b.Text.Length, 0)
        Sync-EdUi
        Assert-Ed '편집기 한글 조합: 조합 중에는 줄이 바뀌어도 섬을 나누지 않는다' ($ed.Island.Start -eq 0 -and [object]::ReferenceEquals($ed.IslandBox.Parent, $ed.Island.Holder)) "섬 $($ed.Island.Start)..$($ed.Island.End)"
        Send-EdComposition $ed End '임'
        Sync-EdUi
        Assert-Ed '편집기 한글 조합: 조합이 끝나면 섬을 나눈다 (제목을 그림)' ($ed.Island.Start -eq 1 -and (Get-EdCaret $ed) -eq '1:0') "섬 $($ed.Island.Start)..$($ed.Island.End) 커서 $(Get-EdCaret $ed)"
        [void](Test-EdContract $ed '조합 끝난 뒤')
        # 조합 중 Enter(목록): 입력기가 줄을 바꾼 뒤의 목록 이어 쓰기가 먼저, 섬 나누기는 그 뒤
        Set-EdText $ed '- 가'
        Open-EdAt $ed 0 3
        & $em { param($x) Add-WtMemoImePending $x 'enter' } $ed.IslandBox
        $b = $ed.IslandBox
        $b.SelectedText = "`r`n"; $b.Select($b.Text.Length, 0)
        Sync-EdUi
        Assert-Ed '편집기 한글 조합 Enter(목록): 목록 이어 쓰기를 한 뒤 새 항목만 섬' ((Get-EdText $ed) -ceq "- 가`n- " -and $ed.Island.Start -eq 1 -and (Get-EdCaret $ed) -eq '1:2') "글 [$((Get-EdText $ed).Replace("`n", '¶'))] 섬 $($ed.Island.Start)..$($ed.Island.End) 커서 $(Get-EdCaret $ed)"
        [void](Test-EdContract $ed '조합 중 Enter 목록')
    }

    # ---- 긴 글: 나눠 그리기 ----
    Invoke-EdCase '긴 글' {
        $ed = New-EdEditor
        $null = Set-WtMemoEditorText $ed $longText
        $partial = $ed.Rendered -lt $ed.Units.Count
        [void](Test-EdContract $ed '긴 글 처음')
        Assert-Ed '편집기 긴 글: 처음에는 앞쪽만 그린다' $partial "($($ed.Rendered)/$($ed.Units.Count))"
        Assert-Ed '편집기 긴 글: 나눠 그리기가 끝나고 사이사이 문서 약속이 지켜진다' (Complete-EdRender $ed -Check) "($($ed.Rendered)/$($ed.Units.Count))"
        Assert-Ed '편집기 긴 글: 단위 560개 · 글 그대로' ($ed.Units.Count -eq 560 -and @($ed.Live.Document.Blocks).Count -eq 560 -and (Get-EdText $ed) -ceq $longText) "($($ed.Units.Count))"
        [void](Test-EdContract $ed '긴 글 다 그림')

        # 섬을 연 채로 나눠 그리기
        $null = Set-WtMemoEditorText $ed $longText
        Open-EdAt $ed 2 0
        Send-EdText $ed '앞'
        [void](Test-EdContract $ed '긴 글 위쪽 섬')
        Assert-Ed '편집기 긴 글: 위쪽 섬을 연 채로 나눠 그리기' (Complete-EdRender $ed -Check -Where '섬 연 채로 나눠 그리기')
        Close-Ed $ed
        [void](Test-EdContract $ed '긴 글 위쪽 섬 닫기')

        # 아직 안 그린 곳에 섬 열기 · 줄 늘리기 · 닫기
        $null = Set-WtMemoEditorText $ed $longText
        $target = $ed.Units[[Math]::Min($ed.Units.Count - 1, $ed.Rendered + 20)]
        Open-EdAt $ed $target.Start 0
        [void](Test-EdContract $ed '안 그린 곳에 섬')
        Send-EdText $ed '- 새 항목'
        Send-EdKey $ed Return
        Close-Ed $ed
        [void](Test-EdContract $ed '안 그린 곳 섬 닫기')
        Assert-Ed '편집기 긴 글: 안 그린 곳을 고쳐도 끝까지 그린다' (Complete-EdRender $ed -Check -Where '안 그린 곳 고친 뒤')
        $lineAt = $target.Start
        Assert-Ed '편집기 긴 글: 고친 줄이 그 자리에' ((Get-EdLines $ed)[$lineAt].StartsWith('- 새 항목'))

        # 그린 끝 바로 앞 단위에서 줄을 늘려 닫기 (이웃이 아직 안 그린 단위)
        $null = Set-WtMemoEditorText $ed $longText
        $u = $ed.Units[$ed.Rendered - 1]
        Open-EdAt $ed ($u.End - 1) 0
        Send-EdKey $ed Return
        Send-EdKey $ed Return
        Close-Ed $ed
        [void](Test-EdContract $ed '그린 끝에서 줄 늘림')
        [void](Complete-EdRender $ed -Check -Where '그린 끝 고친 뒤')

        # Ctrl+End · PageUp/PageDown
        $null = Set-WtMemoEditorText $ed $longText
        Open-EdAt $ed 0 0
        Invoke-EdCommand $ed 'Ctrl+End'
        [void](Test-EdContract $ed '긴 글 Ctrl+End')
        Assert-Ed '편집기 긴 글: Ctrl+End는 끝까지 그리고 마지막 단위로' ($ed.Island.Start -eq ($long.Count - 2)) "$($ed.Island.Start)"
        Open-EdAt $ed 0 0
        $ed.Live.UpdateLayout()
        $seen = [System.Collections.Generic.List[int]]::new()
        $seen.Add($ed.Island.Start)
        # PageDown 키는 알려진 버그 pagedown-key로 처리되지 않아서, 키 처리기가 부를 함수를 직접 부른다
        foreach ($k in 'PageDown*', 'PageDown*', 'PageUp') {
            if ($k -eq 'PageUp') { Send-EdKey $ed PageUp } else { Invoke-EdCommand $ed $k }
            [void](Test-EdContract $ed $k)
            $seen.Add($(if ($ed.Island) { $ed.Island.Start } else { -1 }))
        }
        Assert-Ed '편집기 PageDown · PageUp: 한 화면씩 아래 · 위 단위로 섬을 옮긴다' ($seen[1] -gt $seen[0] -and $seen[2] -gt $seen[1] -and $seen[3] -lt $seen[2] -and $seen[3] -gt $seen[0]) ($seen -join ' → ')
        Assert-Ed '편집기 긴 글: 옮겨 다니기만 하면 글 그대로' ((Get-EdText $ed) -ceq $longText)
    }
    Invoke-EdCase 'PageDown 키' {
        $ed = New-EdEditor
        Set-EdText $ed $longText
        Open-EdAt $ed 0 0
        Sync-EdUi
        Send-EdKey $ed PageDown
        Assert-Ed '편집기 PageDown 키: 한 화면 아래 단위로 섬을 옮긴다' ($ed.Island.Start -gt 0) "섬 $($ed.Island.Start)"
    } -Bug 'pagedown-key'
    Invoke-EdCase 'PageDown: 끝에서 한 화면이 안 남았을 때' {
        $ed = New-EdEditor
        Set-EdText $ed $longText
        Open-EdAt $ed 0 0
        Invoke-EdCommand $ed 'Ctrl+End'
        Send-EdKey $ed PageUp
        $mid = $ed.Island.Start
        Invoke-EdCommand $ed 'PageDown*'
        Assert-Ed '편집기 PageDown: 마지막 화면에서는 마지막 단위로 간다' ($ed.Island.Start -eq ($long.Count - 2)) "PageUp 뒤 $mid → PageDown 뒤 $($ed.Island.Start) (마지막 단위 $($long.Count - 2))"
    } -Bug 'pagedown-near-end'

    Invoke-EdCase '닫히지 않은 코드 울타리' {
        $ed = New-EdEditor
        Set-EdText $ed "``````ps`ncode`n`npara"
        $kinds = @($ed.Units | ForEach-Object { '{0}-{1} {2}' -f $_.Start, $_.End, $_.Kind }) -join ', '
        Assert-Ed '편집기 단위: 닫히지 않은 ``` 는 글 끝까지 코드 한 단위 (읽기 모드와 같게)' ($kinds -eq '0-4 code') $kinds
    } -Bug 'unclosed-fence'

    Invoke-EdCase 'Callout-NewMemoKeepsFocus' {
        $ed = New-EdEditor
        Set-EdText $ed ''
        Open-EdAt $ed 0 0
        Sync-EdUi
        Send-EdText $ed '> [!note] Fresh Callout'
        Send-EdKey $ed Return
        Assert-Ed 'Callout-NewMemoKeepsFocus: 첫 Enter 뒤 인용 섬 · 커서 · 키보드 포커스 유지' (
            $ed.Island -and $ed.IslandBox.IsKeyboardFocused -and (Get-EdCaret $ed) -ceq '1:2' -and
            $ed.IslandBox.Text -ceq "> [!note] Fresh Callout`r`n> ") "섬=$([bool]$ed.Island) 포커스=$($ed.IslandBox.IsKeyboardFocused)"
        if (-not $ed.IslandBox.IsKeyboardFocused) { throw '둘째 줄을 받을 키보드 포커스가 없습니다.' }
        Send-EdText $ed 'Callout line content'
        Send-EdKey $ed Return 2
        # 인용 탈출은 빈 줄을 남긴다: 바로 아래 줄에 쓰면 콜아웃 문단에 이어지는 줄(lazy)이 되어 콜아웃 안에 그려진다(11-22 실사용 13)
        $exitFocus = $ed.Island -and $ed.IslandBox.IsKeyboardFocused -and (Get-EdCaret $ed) -ceq '3:0'
        if (-not $ed.IslandBox.IsKeyboardFocused) { throw '다음 문단을 받을 키보드 포커스가 없습니다.' }
        Send-EdText $ed 'Next paragraph text'
        Sync-EdUi
        Assert-Ed 'Callout-NewMemoKeepsFocus: 인용 탈출 뒤 다음 문단까지 입력 보존 · 포커스 유지' (
            $exitFocus -and $ed.Island -and $ed.IslandBox.IsKeyboardFocused -and
            (Get-EdText $ed) -ceq "> [!note] Fresh Callout`n> Callout line content`n`nNext paragraph text") "글=$((Get-EdText $ed).Replace("`n", '¶')) 커서=$(Get-EdCaret $ed)"
        Assert-EdContract $ed 'Callout-NewMemoKeepsFocus: 문서 약속'
        Close-Ed $ed
        $kinds = @($ed.Units | ForEach-Object { '{0}-{1} {2}' -f $_.Start, $_.End, $_.Kind }) -join ', '
        Assert-Ed 'QuoteExit-NextBlockOutside: 탈출 뒤 쓴 문단은 콜아웃 밖 단위' ($kinds -ceq '0-2 callout, 3-4 para') $kinds
    }
    # 11-22 재확인: 편집 보기에서 빈 목록 항목 Enter가 빈 줄을 안 남겨 다음 줄이 앞 항목 안으로 들어갔다(원문 보기는 됨).
    # 새 메모처럼 한 줄씩 쳐서 섬이 목록 항목 하나일 때도 원문 보기와 같은 글이 되어야 한다
    Invoke-EdCase 'ListExit-NewMemoBlankLine' {
        foreach ($item in '- 슬롯 확인', '- [ ] 슬롯 확인', '1. 슬롯 확인') {
            $ed = New-EdEditor
            Set-EdText $ed ''
            Open-EdAt $ed 0 0
            Sync-EdUi
            Send-EdText $ed '목록 시험'
            Send-EdKey $ed Return
            Send-EdText $ed $item
            Send-EdKey $ed Return 2
            $exitFocus = $ed.Island -and $ed.IslandBox.IsKeyboardFocused -and (Get-EdCaret $ed) -ceq '3:0'
            if (-not $ed.IslandBox.IsKeyboardFocused) { throw '다음 문단을 받을 키보드 포커스가 없습니다.' }
            Send-EdText $ed '문단 줄'
            Sync-EdUi
            Assert-Ed "ListExit-NewMemoBlankLine: $item 빈 항목 Enter = 빈 줄 · 다음 줄은 문단 · 포커스 유지" (
                $exitFocus -and $ed.IslandBox.IsKeyboardFocused -and (Get-EdText $ed) -ceq "목록 시험`n$item`n`n문단 줄") "글=$((Get-EdText $ed).Replace("`n", '¶')) 커서=$(Get-EdCaret $ed)"
            Assert-EdContract $ed "ListExit-NewMemoBlankLine: $item 문서 약속"
            Close-Ed $ed
            $kinds = @($ed.Units | ForEach-Object { '{0}-{1} {2}' -f $_.Start, $_.End, $_.Kind }) -join ', '
            Assert-Ed "ListExit-NewMemoBlankLine: $item 뒤 문단은 목록 밖 단위" ($kinds -match ', 3-4 para$') $kinds
        }
        # 위가 빈 줄이면 빈 줄을 더하지 않고 표지만 지운다(원문 보기 규칙과 같게)
        $ed = New-EdEditor
        Set-EdText $ed "메모`n`n- "
        Open-EdAt $ed 2 2
        Sync-EdUi
        Send-EdKey $ed Return
        Assert-Ed 'ListExit-NewMemoBlankLine: 빈 줄 아래 빈 항목은 표지만 지운다' ((Get-EdText $ed) -ceq "메모`n`n" -and (Get-EdCaret $ed) -ceq '2:0') "글=$((Get-EdText $ed).Replace("`n", '¶')) 커서=$(Get-EdCaret $ed)"
        Close-Ed $ed
    }
    Invoke-EdCase 'BlankCaret-EnterUpType' {
        foreach ($block in @(@('```ps', 'Get-Service', 'Get-Process', '```'), @('middle line'), @('## Heading'))) {
            $ed = New-EdEditor
            $initial = (@('intro line', '') + $block + @('', 'after line')) -join "`n"
            Set-EdText $ed $initial
            Open-EdAt $ed 2 0
            Send-EdKey $ed Return
            $afterEnter = (@('intro line', '', '') + $block + @('', 'after line')) -join "`n"
            Assert-Ed "BlankCaret-EnterUpType: $($block[0]) Enter는 블록 앞에 빈 줄 · 블록 커서 유지" (
                (Get-EdText $ed) -ceq $afterEnter -and (Get-EdCaret $ed) -ceq '3:0')
            Send-EdKey $ed Up
            Assert-Ed "BlankCaret-EnterUpType: $($block[0]) 바로 위 빈 줄 섬" (
                (Get-EdCaret $ed) -ceq '2:0' -and $ed.IslandBox.Text -ceq '' -and $ed.Island.Last -lt $ed.Island.First)
            Send-EdText $ed 'new text'
            $expected = (@('intro line', '', 'new text') + $block + @('', 'after line')) -join "`n"
            Assert-Ed "BlankCaret-EnterUpType: $($block[0]) 사이에 입력 · 원문 일치" ((Get-EdText $ed) -ceq $expected)
            Invoke-EdCommand $ed 'Ctrl+Z'
            Assert-Ed "BlankCaret-EnterUpType: $($block[0]) 입력 한 번 실행 취소" ((Get-EdText $ed) -ceq $afterEnter)
            Invoke-EdCommand $ed 'Ctrl+Z'
            Assert-Ed "BlankCaret-EnterUpType: $($block[0]) Enter 한 번 실행 취소" ((Get-EdText $ed) -ceq $initial)
            Invoke-EdCommand $ed 'Ctrl+Y'; Invoke-EdCommand $ed 'Ctrl+Y'
            Set-WtMemoEditorMode $ed source
            Assert-Ed "BlankCaret-EnterUpType: $($block[0]) 다시 실행 · 저장용 본문 · 원문 보기 일치" (
                (Get-EdText $ed) -ceq $expected -and $ed.Source.Text.Replace("`r`n", "`n") -ceq $expected)
            Set-WtMemoEditorMode $ed live
            Assert-EdContract $ed "BlankCaret-EnterUpType: $($block[0]) 문서 약속"
        }
    }
    Invoke-EdCase 'BlankCaret-Arrows' {
        $ed = New-EdEditor
        Set-EdText $ed (@('intro line', '', '', '```ps', 'Get-Service', 'Get-Process', '```', '', '', 'after line') -join "`n")
        Open-EdAt $ed 0 10
        foreach ($line in 1, 2, 3) {
            Send-EdKey $ed Down
            Assert-Ed "BlankCaret-Arrows: 아래로 $line 줄" ((Get-EdCaret $ed) -ceq "${line}:0")
        }
        Set-EdCaret $ed 6 3
        foreach ($line in 7, 8, 9) {
            Send-EdKey $ed Down
            Assert-Ed "BlankCaret-Arrows: 코드 아래 $line 줄" ((Get-EdCaret $ed) -ceq "${line}:0")
        }
        foreach ($line in 8, 7, 6) {
            Send-EdKey $ed Up
            Assert-Ed "BlankCaret-Arrows: 위로 $line 줄" ((Get-EdCaret $ed) -ceq "${line}:0")
        }
        Open-EdAt $ed 3 0
        foreach ($line in 2, 1) { Send-EdKey $ed Left; Assert-Ed "BlankCaret-Arrows: 왼쪽 빈 줄 $line" ((Get-EdCaret $ed) -ceq "${line}:0") }
        Send-EdKey $ed Left
        Assert-Ed 'BlankCaret-Arrows: 왼쪽 앞 블록 줄 끝' ((Get-EdCaret $ed) -ceq '0:10')
        foreach ($line in 1, 2, 3) { Send-EdKey $ed Right; Assert-Ed "BlankCaret-Arrows: 오른쪽 $line" ((Get-EdCaret $ed) -ceq "${line}:0") }
        foreach ($key in 'Up', 'Left', 'Down', 'Right') {
            $line = if ($key -in 'Up', 'Left') { 3 } else { 0 }
            $col = if ($key -eq 'Right') { 10 } else { 0 }
            Open-EdAt $ed $line $col; Close-Ed $ed
            [void]$ed.Live.Focus(); Sync-EdUi; Wait-EdModifiers
            $a = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $testSource, 0, [Windows.Input.Key]$key)
            $a.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
            $ed.Live.RaiseEvent($a); Sync-EdUi
            $want = if ($line) { '2:0' } else { '1:0' }
            Assert-Ed "BlankCaret-Arrows: 그린 보기 $key 빈 줄" ((Get-EdCaret $ed) -ceq $want -and $ed.IslandBox.Text -ceq '')
        }
        Assert-EdContract $ed 'BlankCaret-Arrows: 문서 약속'
    }
    Invoke-EdCase 'BlankCaret-ClickHeight' {
        foreach ($block in @(@('```ps', 'Get-Service', 'Get-Process', '```'), @('middle line'), @('## Heading'))) {
            $ed = New-EdEditor
            Set-EdText $ed ((@('intro line', '', '', '') + $block + @('', 'after line')) -join "`n")
            $h = [double]$ed.Live.FindResource('F.Memo.Body.LineHeight')
            $top = (Get-EdPoint $ed.Live 'intro line').Y + $h / 2
            $sec = $ed.Sections[1]
            $bottom = $sec.ContentStart.GetCharacterRect('Forward').Top
            if ($sec.Tag.Kind -eq 'code') { $bottom -= $sec.Blocks.FirstBlock.BorderThickness.Top }
            foreach ($line in 1..3) {
                $y = if ($line -eq 1) { ($top + $bottom - 2 * $h) / 2 } else { $bottom - (3.5 - $line) * $h }
                $p = [Windows.Point]::new(4, $y)
                $mouse = [pscustomobject]@{ OriginalSource = $ed.Live; Point = $p; Handled = $false }
                $mouse | Add-Member ScriptMethod GetPosition { param($el) $this.Point }
                & $em { param($s, $e) Invoke-WtMemoLiveMouseDown $s $e } $ed.Live $mouse
                & $em { param($s, $e) Invoke-WtMemoLiveMouseUp $s $e } $ed.Live $mouse
                Sync-EdUi
                Assert-Ed "BlankCaret-ClickHeight: $($block[0]) 높이별 빈 줄 $line" (
                    $mouse.Handled -and (Get-EdCaret $ed) -ceq "${line}:0" -and $ed.IslandBox.Text -ceq '' -and $ed.Island.Last -lt $ed.Island.First)
                Close-Ed $ed; $ed.Live.UpdateLayout()
            }
            # 섬을 열어 둔 상태에서도 남은 여백을 다른 빈 줄로 고른다.
            Open-EdAt $ed 1 0; $ed.Live.UpdateLayout()
            $p = [Windows.Point]::new(4, $bottom - $h / 2)
            $hit = & $em { param($x, $p) Find-WtMemoLiveHit $x $p } $ed $p
            Assert-Ed "BlankCaret-ClickHeight: $($block[0]) 빈 섬 뒤 남은 간격" ($hit.Line -eq 3 -and $hit.Col -eq 0)
            Close-Ed $ed
            Assert-EdContract $ed "BlankCaret-ClickHeight: $($block[0]) 문서 약속"
        }
    }
    Invoke-EdCase 'BlankCaret-DeleteLine' {
        foreach ($key in 'Back', 'Delete') {
            foreach ($line in 1..3) {
                $ed = New-EdEditor
                $initial = "intro line`n`n`n`n## Heading`n`nafter line"
                Set-EdText $ed $initial; Open-EdAt $ed $line 0
                Send-EdKey $ed $key
                Assert-Ed "BlankCaret-DeleteLine: $key 빈 줄 $line 한 줄만 삭제" (
                    (Get-EdText $ed) -ceq "intro line`n`n`n## Heading`n`nafter line")
                Assert-EdContract $ed "BlankCaret-DeleteLine: $key $line 문서 약속"
                Invoke-EdCommand $ed 'Ctrl+Z'
                Assert-Ed "BlankCaret-DeleteLine: $key $line 한 번 실행 취소" ((Get-EdText $ed) -ceq $initial -and (Get-EdCaret $ed) -ceq "${line}:0")
            }
        }
        foreach ($block in @(@('```ps', 'Get-Service', 'Get-Process', '```'), @('middle line'), @('## Heading'))) {
            $ed = New-EdEditor
            $initial = (@('intro line', '') + $block + @('', 'after line')) -join "`n"
            Set-EdText $ed $initial; Open-EdAt $ed 2 0
            Send-EdKey $ed Back
            Assert-Ed "BlankCaret-DeleteLine: $($block[0]) 앞 빈 줄만 삭제 · 블록 커서 유지" (
                (Get-EdText $ed) -ceq ((@('intro line') + $block + @('', 'after line')) -join "`n") -and (Get-EdCaret $ed) -ceq '1:0')
            Assert-EdContract $ed "BlankCaret-DeleteLine: $($block[0]) 문서 약속"
            Invoke-EdCommand $ed 'Ctrl+Z'
            Assert-Ed "BlankCaret-DeleteLine: $($block[0]) 블록 지우기 한 번 실행 취소" ((Get-EdText $ed) -ceq $initial)
        }
    }
    Invoke-EdCase 'BlankCaret-StableHeight' {
        foreach ($block in @(@('```ps', 'Get-Service', 'Get-Process', '```'), @('middle line'), @('## Heading'))) {
            foreach ($count in 1..3) {
                $ed = New-EdEditor
                Set-EdText $ed ((@('intro line') + @('') * $count + $block + @('', 'after line')) -join "`n")
                $y = (Get-EdPoint $ed.Live 'after line').Y
                foreach ($line in 1..$count) {
                    Open-EdAt $ed $line 0
                    $openY = (Get-EdPoint $ed.Live 'after line').Y
                    Close-Ed $ed
                    $closeY = (Get-EdPoint $ed.Live 'after line').Y
                    Assert-Ed "BlankCaret-StableHeight: $($block[0]) 빈 줄 $line/$count 열고 닫기" (
                        [Math]::Abs($openY - $y) -lt 2 -and [Math]::Abs($closeY - $y) -lt 2) "닫힘=$y 열림=$openY 다시닫힘=$closeY"
                }
            }
        }
    }
    Invoke-EdCase 'BlankCaret-RemainingLines' {
        foreach ($insert in 'new text', '## New heading', '- new item') {
            $ed = New-EdEditor
            Set-EdText $ed "intro line`r`n`r`n`r`n`r`n`r`n## Heading`r`n`r`nafter line"
            Open-EdAt $ed 2 0; Send-EdText $ed $insert; Close-Ed $ed
            $expected = "intro line`r`n`r`n$insert`r`n`r`n`r`n## Heading`r`n`r`nafter line"
            Assert-Ed "BlankCaret-RemainingLines: $insert 입력한 블록 · 위아래 남은 빈 줄 · 줄바꿈 유지" (
                (Get-WtMemoEditorText $ed) -ceq $expected -and $ed.Units.Count -eq 4 -and $ed.Units[1].Text -ceq $insert -and
                $ed.Units[1].Start -eq 2 -and $ed.Units[2].Start -eq 5)
            Assert-EdContract $ed "BlankCaret-RemainingLines: $insert 문서 약속"
        }
        foreach ($initial in "`n`n", "`n## Heading", "## Heading`n", '') {
            foreach ($key in 'Back', 'Delete') {
                $ed = New-EdEditor; Set-EdText $ed $initial
                $line = if ($initial.StartsWith('##')) { 1 } else { 0 }
                Open-EdAt $ed $line 0; Send-EdKey $ed $key
                $expected = if ($initial.Contains("`n")) { $initial.Remove($initial.IndexOf("`n"), 1) } else { '' }
                Assert-Ed "BlankCaret-RemainingLines: $key 처음 · 끝 · 빈 글에서 한 줄 삭제" ((Get-EdText $ed) -ceq $expected)
                Assert-EdContract $ed "BlankCaret-RemainingLines: $key 가장자리 문서 약속"
            }
        }
        $ed = New-EdEditor; Set-EdText $ed "`n`n"
        Open-EdAt $ed 2 0; Send-EdKey $ed Down; Send-EdKey $ed Right
        Assert-Ed 'BlankCaret-RemainingLines: 빈 글 끝에서 이동해도 같은 줄' ((Get-EdCaret $ed) -ceq '2:0')
    }
    Invoke-EdCase 'BlankSpacing-DefaultSeparator' {
        foreach ($blank in 0, 1, 3) {
            $ed = New-EdEditor
            $text = 'first paragraph' + ("`n" * ($blank + 1)) + "## Next`n`nafter"
            Set-EdText $ed $text
            $liveY = (Get-EdPoint $ed.Live 'Next').Y
            Set-WtMemoEditorMode $ed 'read'
            $readY = (Get-EdPoint $ed.View 'Next').Y
            Set-WtMemoEditorMode $ed 'live'
            [void](Complete-EdRender $ed)
            Open-EdAt $ed 0 0
            $openY = (Get-EdPoint $ed.Live 'Next').Y
            Close-Ed $ed
            $closeY = (Get-EdPoint $ed.Live 'Next').Y
            $h = [double]$ed.Live.FindResource('F.Memo.Body.LineHeight')
            $ok = [Math]::Abs($liveY - $readY - [Math]::Max(0, $blank - 1) * $h) -lt 2 -and
                [Math]::Abs($openY - $liveY) -lt 2 -and [Math]::Abs($closeY - $liveY) -lt 2
            $afterY = (Get-EdPoint $ed.Live 'after').Y
            Open-EdAt $ed ($blank + 1) 0
            $headingY = (Get-EdPoint $ed.Live 'after').Y
            Close-Ed $ed
            $ok = $ok -and [Math]::Abs($headingY - $afterY) -lt 2 -and [Math]::Abs((Get-EdPoint $ed.Live 'after').Y - $afterY) -lt 2
            if ($blank) {
                Open-EdAt $ed 1 0
                $blankY = (Get-EdPoint $ed.Live 'Next').Y
                Close-Ed $ed
                $ok = $ok -and [Math]::Abs($blankY - $liveY) -lt 2 -and [Math]::Abs((Get-EdPoint $ed.Live 'Next').Y - $liveY) -lt 2
            }
            Assert-Ed "BlankSpacing-DefaultSeparator: 빈 줄 $blank · 읽기 대비 추가 높이 · 섬 열고 닫기" $ok "읽기=$readY 편집=$liveY 열림=$openY 닫힘=$closeY 빈섬=$blankY 제목섬=$headingY/$afterY"
        }
    }
    Invoke-EdCase 'IslandContextMenu-KeepsEditing' {
        $ed = New-EdEditor
        Set-EdText $ed '본문'
        Open-EdAt $ed 0 1
        $ed.IslandBox.Select(0, 2)
        $island = $ed.Island
        $menu = $ed.IslandBox.ContextMenu
        # 팝업을 띄우지 않고 메뉴로의 LostKeyboardFocus 이벤트를 실제 입력칸에서 올린다.
        $menu.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $menu.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
        $outside = [System.Windows.Controls.Button]::new()
        [void]$edHost.Children.Add($outside)
        $ed.Busy++
        try { [void]$outside.Focus() } finally { $ed.Busy-- }
        $focusArgs = [System.Windows.Input.KeyboardFocusChangedEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, 0, $ed.IslandBox, $menu.Items[1])
        $focusArgs.RoutedEvent = [System.Windows.Input.Keyboard]::LostKeyboardFocusEvent
        $ed.IslandBox.RaiseEvent($focusArgs)
        Assert-Ed 'IslandContextMenu-KeepsEditing: 메뉴 포커스가 섬을 닫지 않고 선택 · 한글 메뉴 유지' (
            [object]::ReferenceEquals($ed.Island, $island) -and $ed.IslandBox.SelectedText -ceq '본문' -and
            ($menu.Items.Header -join ',') -ceq '잘라내기,복사,붙여넣기,모두 선택' -and $ed.TestLeft -eq 0) "섬=$([bool]$ed.Island) 저장이탈=$($ed.TestLeft)"
        [void]$edHost.Children.Remove($outside)
        [void]$ed.IslandBox.Focus()
        $menu.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.ContextMenu]::ClosedEvent))
        Sync-EdUi
        Assert-Ed 'IslandContextMenu-KeepsEditing: 메뉴 닫은 뒤에도 섬 포커스 · 선택 유지' (
            [object]::ReferenceEquals($ed.Island, $island) -and $ed.IslandBox.IsKeyboardFocused -and $ed.IslandBox.SelectedText -ceq '본문')
    }

    Invoke-EdCase 'ListEnter-BeforeCallout' {
        $ed = New-EdEditor
        $initial = "- first`n- second`n`n> [!note] Notice`n> detail"
        Set-EdText $ed $initial
        $y = (Get-EdPoint $ed.Live 'Notice').Y
        Open-EdAt $ed 1 8
        Send-EdKey $ed Return 3
        Assert-Ed 'ListEnter-BeforeCallout: 원문 · 빈 줄 섬 · 블록 순서' (
            (Get-EdText $ed) -ceq "- first`n- second`n`n`n`n> [!note] Notice`n> detail" -and
            $ed.Island.Start -eq 2 -and @($ed.IslandBox.Text -split "\r?\n").Count -eq 2 -and $ed.Island.Last -lt $ed.Island.First -and
            ($ed.Units.Kind -join ',') -ceq 'list-item,list-item,callout') "글=$((Get-EdText $ed).Replace("`n", '¶')) 섬=$($ed.Island.Start)..$($ed.Island.End) 섬줄=$(@($ed.IslandBox.Text -split "\r?\n").Count)"
        $openY = (Get-EdPoint $ed.Live 'Notice').Y
        $boxHeight = $ed.IslandBox.ActualHeight; $holderPadding = $ed.Island.Holder.Padding
        Close-Ed $ed
        $closedY = (Get-EdPoint $ed.Live 'Notice').Y
        $h = [double]$ed.Live.FindResource('F.Memo.Body.LineHeight')
        Assert-Ed 'ListEnter-BeforeCallout: 빈 줄 높이 · 섬 닫아도 같은 간격' (
            [Math]::Abs($closedY - $y - 2 * $h) -lt 2 -and [Math]::Abs($openY - $closedY) -lt 2) "처음=$y 열림=$openY 닫힘=$closedY 줄=$h 상자=$boxHeight 여백=$holderPadding"
        Assert-EdContract $ed 'ListEnter-BeforeCallout: 문서 약속'
    }
    Invoke-EdCase 'HeadingEnter-BeforeCallout' {
        $ed = New-EdEditor
        Set-EdText $ed "# Section`r`n> [!note] Header Note`r`n> detail"
        $y = (Get-EdPoint $ed.Live 'Header Note').Y
        Open-EdAt $ed 0 9
        Send-EdKey $ed Return 3
        $openY = (Get-EdPoint $ed.Live 'Header Note').Y
        Assert-Ed 'HeadingEnter-BeforeCallout: 빈 줄 세 개 · 섬 범위 · 블록 순서' (
            (Get-EdText $ed) -ceq "# Section`n`n`n`n> [!note] Header Note`n> detail" -and
            $ed.Island.Start -eq 1 -and @($ed.IslandBox.Text -split "\r?\n").Count -eq 3 -and ($ed.Units.Kind -join ',') -ceq 'heading,callout') "글=$((Get-EdText $ed).Replace("`n", '¶')) 섬=$($ed.Island.Start)..$($ed.Island.End)"
        Close-Ed $ed
        $closedY = (Get-EdPoint $ed.Live 'Header Note').Y
        $h = [double]$ed.Live.FindResource('F.Memo.Body.LineHeight')
        Assert-Ed 'HeadingEnter-BeforeCallout: 기본 빈 줄을 뺀 두 줄 높이 · 섬 닫아도 같은 간격' (
            [Math]::Abs($closedY - $y - 2 * $h) -lt 2 -and [Math]::Abs($openY - $closedY) -lt 2) "처음=$y 열림=$openY 닫힘=$closedY"
        Assert-EdContract $ed 'HeadingEnter-BeforeCallout: 문서 약속'
    }
    Invoke-EdCase 'HeadingStartEnter-PreservesBlank' {
        $ed = New-EdEditor
        $initial = "## 제목`n`n본문"
        Set-EdText $ed $initial
        $y = (Get-EdPoint $ed.Live '본문').Y
        Open-EdAt $ed 0 0
        Send-EdKey $ed Return
        $openY = (Get-EdPoint $ed.Live '본문').Y
        Assert-Ed 'HeadingStartEnter-PreservesBlank: 앞 빈 줄 · 제목 섬 · 커서' (
            (Get-EdText $ed) -ceq "`n## 제목`n`n본문" -and $ed.Island.Start -eq 1 -and $ed.Island.End -eq 2 -and (Get-EdCaret $ed) -ceq '1:0')
        Close-Ed $ed
        $closedY = (Get-EdPoint $ed.Live '본문').Y
        $h = [double]$ed.Live.FindResource('F.Memo.Body.LineHeight')
        Assert-Ed 'HeadingStartEnter-PreservesBlank: 앞 빈 줄 높이 유지' (
            [Math]::Abs($closedY - $y - $h) -lt 2 -and [Math]::Abs($openY - $closedY) -lt 2) "처음=$y 열림=$openY 닫힘=$closedY"
        Invoke-EdCommand $ed 'Ctrl+Z'
        Close-Ed $ed
        Assert-Ed 'HeadingStartEnter-PreservesBlank: 실행 취소로 원문과 간격 복원' (
            (Get-EdText $ed) -ceq $initial -and [Math]::Abs((Get-EdPoint $ed.Live '본문').Y - $y) -lt 2)
        Assert-EdContract $ed 'HeadingStartEnter-PreservesBlank: 문서 약속'
    }
    Invoke-EdCase 'Callout-RenderOnExit' {
        $ed = New-EdEditor
        Set-EdText $ed "> [!note] Notice`n> detail"
        Open-EdAt $ed 1 8
        Send-EdKey $ed Return
        Assert-Ed 'Callout-RenderOnExit: 인용 안 작성 중에는 원문' ($ed.Island.Start -eq 0 -and $ed.IslandBox.Text.EndsWith('> '))
        Send-EdKey $ed Return
        Assert-Ed 'Callout-RenderOnExit: 두 번째 Enter 즉시 콜아웃을 그리고 빈 줄만 섬' (
            (Get-EdText $ed) -ceq "> [!note] Notice`n> detail`n`n" -and $ed.Island.Start -eq 2 -and $ed.Island.End -eq 4 -and (Get-EdCaret $ed) -ceq '3:0' -and
            $ed.Units[0].Kind -ceq 'callout' -and [object]::ReferenceEquals($ed.Live.Document.Blocks.FirstBlock, $ed.Sections[0]) -and
            (Get-EdPoint $ed.Live 'Notice').Y -ge 0) "글=$((Get-EdText $ed).Replace("`n", '¶')) 섬=$($ed.Island.Start)..$($ed.Island.End) 커서=$(Get-EdCaret $ed)"
        Assert-EdContract $ed 'Callout-RenderOnExit: 문서 약속'
        Set-EdText $ed '> plain'
        Open-EdAt $ed 0 7
        Send-EdKey $ed Return 2
        Assert-Ed 'Callout-RenderOnExit: 일반 인용도 탈출 즉시 그리고 빈 줄만 섬' (
            (Get-EdText $ed) -ceq "> plain`n`n" -and $ed.Island.Start -eq 1 -and $ed.Units[0].Kind -ceq 'quote' -and
            [object]::ReferenceEquals($ed.Live.Document.Blocks.FirstBlock, $ed.Sections[0])) "글=$((Get-EdText $ed).Replace("`n", '¶')) 섬=$($ed.Island.Start)..$($ed.Island.End)"
        # 탈출 뒤 바로 표를 쓰면 콜아웃 밖의 표다 (11-22 실사용 13: 표가 콜아웃 안으로 흡수됨). 편집 단위 · 읽기 보기가 같은 규칙
        Set-EdText $ed "> [!note] 주의사항`n> SRV-03 확인"
        Open-EdAt $ed 1 11
        Send-EdKey $ed Return 2
        foreach ($row in '| 서버 | 상태 |', '| --- | --- |', '| SRV-03 | 교체 |') { Send-EdText $ed $row; if ($row -notlike '*교체*') { Send-EdKey $ed Return } }
        Close-Ed $ed
        $kinds = @($ed.Units | ForEach-Object { '{0}-{1} {2}' -f $_.Start, $_.End, $_.Kind }) -join ', '
        $model = (ConvertTo-WtMarkdownModel (Get-EdText $ed)).Blocks
        Set-WtMemoEditorMode $ed 'read'
        $readTable = $null
        foreach ($b in $ed.View.Document.Blocks) { if ($b -is [System.Windows.Documents.Table] -or ($b -is [System.Windows.Documents.Section] -and $b.Blocks.FirstBlock -is [System.Windows.Documents.Table])) { $readTable = $b } }
        Assert-Ed 'QuoteExit-TableOutsideCallout: 콜아웃 → Enter 두 번 → 표는 콜아웃 밖 (편집 단위 · 모델 · 읽기 보기 맨 위 블록)' (
            $kinds -ceq '0-2 callout, 3-6 table' -and $model.Count -eq 2 -and $model[0].T -ceq 'callout' -and $model[1].T -ceq 'table' -and
            @($model[0].Blocks | Where-Object { $_.T -ceq 'table' }).Count -eq 0 -and $null -ne $readTable) "단위=$kinds 모델=$(@($model | ForEach-Object T) -join ',') 글=$((Get-EdText $ed).Replace("`n", '¶'))"
        Set-WtMemoEditorMode $ed 'live'
    }
    Invoke-EdCase 'BlankSpacing-LiveOnly' {
        $ed = New-EdEditor
        Set-EdText $ed "# Section`n`n`n`n> [!note] Notice`n> detail"
        $y = (Get-EdPoint $ed.Live 'Notice').Y
        Open-EdAt $ed 2 0
        $openY = (Get-EdPoint $ed.Live 'Notice').Y
        Close-Ed $ed
        Assert-Ed 'BlankSpacing-LiveOnly: 빈 간격 가운데 한 줄을 열고 닫아도 같은 높이' (
            [Math]::Abs($openY - $y) -lt 2 -and [Math]::Abs((Get-EdPoint $ed.Live 'Notice').Y - $y) -lt 2) "처음=$y 열림=$openY"
        Set-WtMemoEditorMode $ed 'read'
        $readY = (Get-EdPoint $ed.View 'Notice').Y
        Set-WtMemoEditorText $ed "# Section`n`n> [!note] Notice`n> detail"
        Assert-Ed 'BlankSpacing-LiveOnly: 읽기 보기의 복수 빈 줄 접기는 그대로' ([Math]::Abs((Get-EdPoint $ed.View 'Notice').Y - $readY) -lt 2)
    }
    Invoke-EdCase 'Backtick-Selection' {
        foreach ($mode in 'live', 'source') {
            $ed = New-EdEditor
            Set-WtMemoEditorMode $ed $mode
            Set-EdText $ed ' a '
            if ($mode -eq 'live') { Open-EdAt $ed 0 0 }
            $box = Get-EdBox $ed; $box.SelectAll()
            Send-EdText $ed '`'
            $wrapped = (Get-EdText $ed) -ceq ' `a` ' -and $box.SelectedText -ceq 'a'
            if ($mode -eq 'live') { Invoke-EdCommand $ed 'Ctrl+Z' } else { $box.Undo() }
            Assert-Ed "Backtick-Selection: $mode 앞뒤 공백은 밖에 · 안쪽 선택 · 한 번 취소" ($wrapped -and (Get-EdText $ed) -ceq ' a ')
            Set-EdText $ed "a`nb"
            if ($mode -eq 'live') { & $em { param($x) Open-WtMemoIsland $x 0 2 0 0 1 1 } $ed }
            $box = Get-EdBox $ed; $box.SelectAll()
            Send-EdText $ed '`'
            $wrapped = (Get-EdText $ed) -ceq ('```' + "`na`nb`n" + '```') -and $box.SelectedText.Replace("`r`n", "`n") -ceq "a`nb"
            if ($mode -eq 'live') { Invoke-EdCommand $ed 'Ctrl+Z' } else { $box.Undo() }
            Assert-Ed "Backtick-Selection: $mode 여러 줄 코드 블록 · 안쪽 선택 · 한 번 취소" ($wrapped -and (Get-EdText $ed) -ceq "a`nb")
        }
    }
    Invoke-EdCase 'Backtick-Pair' {
        foreach ($mode in 'live', 'source') {
            $ed = New-EdEditor
            Set-WtMemoEditorMode $ed $mode
            Set-EdText $ed ''
            if ($mode -eq 'live') { Open-EdAt $ed 0 0 }
            Send-EdText $ed '`'
            $box = Get-EdBox $ed
            $pair = $box.Text -ceq '``' -and $box.SelectionStart -eq 1
            Send-EdText $ed '`'
            $skip = $box.Text -ceq '``' -and $box.SelectionStart -eq 2
            Send-EdText $ed '`'
            $fence = (Get-EdText $ed) -ceq ('```' + "`n" + '```') -and $box.SelectionStart -eq 3
            if ($mode -eq 'live') { Invoke-EdCommand $ed 'Ctrl+Z' } else { $box.Undo() }
            Assert-Ed "Backtick-Pair: $mode 빈 짝 · 넘기기 · 세 번으로 여닫는 울타리 · 입력 한 번 취소" ($pair -and $skip -and $fence -and (Get-EdText $ed) -ceq '``')
            Set-EdText $ed ''
            if ($mode -eq 'live') { Open-EdAt $ed 0 0 }
            Send-EdText $ed '`'
            Send-EdKey $ed Back
            $deleted = (Get-EdText $ed) -ceq ''
            if ($mode -eq 'live') { Invoke-EdCommand $ed 'Ctrl+Z' } else { $box.Undo() }
            Assert-Ed "Backtick-Pair: $mode 직후 Backspace로 짝 삭제 · 삭제 한 번 취소" ($deleted -and (Get-EdText $ed) -ceq '``')
        }
    }
    # 실제 타자에서는 보통 글자도 PreviewTextInputStart → PreviewTextInput 순서로 온다. 시작 이벤트가 온 뒤에도 입력 보조는 돌아야 하고
    # (11-17 실제 화면에서 「조합 중」 검사 때문에 입력 보조가 모두 꺼졌던 회귀), 한글 확정 글에는 반응하지 않는다
    Invoke-EdCase 'Backtick-Ime' {
        foreach ($mode in 'live', 'source') {
            foreach ($typed in '`', '가') {
                $ed = New-EdEditor
                Set-WtMemoEditorMode $ed $mode
                Set-EdText $ed ''
                if ($mode -eq 'live') { Open-EdAt $ed 0 0 }
                $box = Get-EdBox $ed
                $tc = [System.Windows.Input.TextComposition]::new([System.Windows.Input.InputManager]::Current, $box, $typed)
                $start = [System.Windows.Input.TextCompositionEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $tc)
                $start.RoutedEvent = [System.Windows.Input.TextCompositionManager]::PreviewTextInputStartEvent
                $box.RaiseEvent($start)
                $probe = @{ Handled = $false; Text = $typed }
                & $em { param($b, $e) Invoke-WtMemoBoxText $b $e } $box $probe
                if ($typed -ceq '`') { Assert-Ed "Backtick-Ime: $mode 시작 이벤트 뒤에도 백틱은 짝" ($probe.Handled -and $box.Text -ceq '``') "[$($box.Text)]" }
                else { Assert-Ed "Backtick-Ime: $mode 한글 확정 글에는 입력 보조 없음" (-not $probe.Handled -and $box.Text -ceq '') "[$($box.Text)]" }
            }
        }
    }
    Invoke-EdCase 'Ime-InputStartKeepsCommands' {
        foreach ($mode in 'live', 'source') {
            $ed = New-EdEditor; Set-WtMemoEditorMode $ed $mode
            Set-EdText $ed '- a'
            if ($mode -eq 'live') { Open-EdAt $ed 0 3 }
            $box = Get-EdBox $ed; $box.Select($box.Text.Length, 0)
            $tc = [Windows.Input.TextComposition]::new([Windows.Input.InputManager]::Current, $box, '')
            $args = [Windows.Input.TextCompositionEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $tc)
            $args.RoutedEvent = [Windows.Input.TextCompositionManager]::PreviewTextInputStartEvent
            $box.RaiseEvent($args)
            Send-EdKey $ed Return
            $changed = (Get-EdText $ed) -ceq "- a`n- "
            $args = [Windows.Input.TextCompositionEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $tc)
            $args.RoutedEvent = [Windows.Input.TextCompositionManager]::PreviewTextInputEvent
            $box.RaiseEvent($args); Sync-EdUi
            Assert-Ed "Ime-InputStartKeepsCommands: $mode 일반 Enter는 시작 표시만으로 막지 않음 · 섬 나누기 정상" (
                $changed -and -not $ed.Composing -and (Get-EdText $ed) -ceq "- a`n- ")
        }
    }
    Invoke-EdCase 'FindRegex-Replacements' {
        $variants = @(
            @('(a)(b)', '\2-\1', 'b-a'), @('(a)(b)', '$2-$1', 'b-a'),
            @('(?<part>a)b', '${part}$$', 'a$'), @('(a)b', '\\1|\1|\n|\t|$$|\q', "\1|a|`n|`t|`$|\q")
        )
        foreach ($mode in 'live', 'source') {
            $ed = New-EdEditor; Set-WtMemoEditorMode $ed $mode
            Open-WtMemoFind $ed -Replace
            $ed.Find.Regex.IsChecked = $true; $ed.Find.Case.IsChecked = $false
            foreach ($variant in $variants) {
                Set-EdText $ed 'ab ab'
                $ed.Find.Query.Text = $variant[0]; $ed.Find.Replace.Text = $variant[1]
                & $em { param($x) Invoke-WtMemoReplace $x -All } $ed
                $changed = (Get-EdText $ed) -ceq ($variant[2] + ' ' + $variant[2]) -and $ed.Find.Count.Text -ceq '2개 바꿈'
                if ($mode -eq 'live') { Invoke-EdCommand $ed 'Ctrl+Z' } else { $ed.Source.Undo() }
                Assert-Ed "FindRegex-Replacements: $mode [$($variant[1])] · 모두 바꾸기 한 번 취소" ($changed -and (Get-EdText $ed) -ceq 'ab ab')
            }
            $ed.Find.Regex.IsChecked = $false
            Set-EdText $ed 'ab AB'; $ed.Find.Query.Text = 'ab'; $ed.Find.Replace.Text = '\1$n\n'
            & $em { param($x) Invoke-WtMemoReplace $x -All } $ed
            Assert-Ed "FindRegex-Replacements: $mode 일반 모드는 대소문자 무시 · 바꾸기 글 그대로" ((Get-EdText $ed) -ceq '\1$n\n \1$n\n')
        }
        Set-WtSetting 'memo.find.regex' $false
    }
    Invoke-EdCase 'FindRegex-Matches' {
        $ed = New-EdEditor; Set-WtMemoEditorMode $ed source
        Open-WtMemoFind $ed -Replace
        $ed.Find.Case.IsChecked = $false; $ed.Find.Regex.IsChecked = $false
        Set-EdText $ed 'a.b A.B axb'; $ed.Find.Query.Text = 'a.b'
        $literal = $ed.Find.Count.Text -match '(?:2개|/2)$'
        $ed.Find.Case.IsChecked = $true; $exact = $ed.Find.Count.Text -match '(?:1개|/1)$'
        $ed.Find.Regex.IsChecked = $true
        Assert-Ed 'FindRegex-Matches: 기본 글자 찾기 · 대소문자 · 정규식 토글' ($literal -and $exact -and $ed.Find.Count.Text -match '(?:2개|/2)$') "기본=$literal 구분=$exact 개수=$($ed.Find.Count.Text)"
        foreach ($nl in "`n", "`r`n") {
            Set-EdText $ed ("row1${nl}ROW2${nl}row3")
            $ed.Find.Case.IsChecked = $false; $ed.Find.Query.Text = '^row\d$'
            & $em { param($x) Invoke-WtMemoFind $x -Here } $ed
            $anchors = $ed.Find.Count.Text -match '/3$' -and $ed.Source.SelectedText -ceq 'row1'
            & $em { param($x) Invoke-WtMemoFind $x -Back } $ed
            $prev = $ed.Source.SelectedText -ceq 'row3'
            & $em { param($x) Invoke-WtMemoFind $x } $ed
            $next = $ed.Source.SelectedText -ceq 'row1'
            $ed.Find.Replace.Text = 'x'
            & $em { param($x) Invoke-WtMemoReplace $x } $ed
            Assert-Ed 'FindRegex-Matches: ^ $ 줄마다 · 이전/다음 순환 · 하나 바꾸기 실제 길이' ($anchors -and $prev -and $next -and (Get-EdText $ed) -ceq "x`nROW2`nrow3" -and $ed.Source.SelectedText -ceq 'ROW2')
        }
        Set-EdText $ed "a`nb"; $ed.Find.Query.Text = '^'; $ed.Find.Replace.Text = '>'
        & $em { param($x) Invoke-WtMemoFind $x } $ed
        $zeroNext = $ed.Source.SelectionStart -eq 2
        & $em { param($x) Invoke-WtMemoReplace $x -All } $ed
        Assert-Ed 'FindRegex-Matches: 길이 0인 일치도 다음으로 이동 · 모두 바꾸기 종료' ($zeroNext -and (Get-EdText $ed) -ceq ">a`n>b")
        Set-WtSetting 'memo.find.regex' $false; Set-WtSetting 'memo.find.case' $false
    }
    Invoke-EdCase 'FindRegex-Errors' {
        $ed = New-EdEditor; Set-WtMemoEditorMode $ed source; Set-EdText $ed 'ab'
        Open-WtMemoFind $ed -Replace; $ed.Find.Regex.IsChecked = $true
        foreach ($bad in '(', '[') {
            $ed.Find.Query.Text = $bad
            & $em { param($x) Invoke-WtMemoReplace $x -All } $ed
            Assert-Ed 'FindRegex-Errors: 틀린 식은 칸 오류 · 이유 툴팁 · 두 바꾸기 비활성 · 본문 보존' (
                $ed.Find.Count.Text -ceq '식 오류' -and $ed.Find.Count.ToolTip -and
                [Windows.Controls.Validation]::GetHasError($ed.Find.Query) -and $ed.Find.Query.ToolTip -and
                -not $ed.Find.One.IsEnabled -and -not $ed.Find.All.IsEnabled -and (Get-EdText $ed) -ceq 'ab')
        }
        $ed.Find.Query.Text = 'z'
        Assert-Ed 'FindRegex-Errors: 올바른 식으로 복구하면 0개 · 오류 지움 · 바꾸기 비활성 이유' (
            $ed.Find.Count.Text -ceq '0개' -and -not [Windows.Controls.Validation]::GetHasError($ed.Find.Query) -and
            -not $ed.Find.One.IsEnabled -and -not $ed.Find.All.IsEnabled -and
            $ed.Find.One.ToolTip -ceq '찾은 것이 없습니다.' -and $ed.Find.All.ToolTip -ceq '찾은 것이 없습니다.')
        $ed.Find.Query.Text = 'ab'
        Assert-Ed 'FindReplace-DisabledTips: 일치하면 활성 · 정상 툴팁 복원 · 꺼진 단추도 툴팁 표시' (
            $ed.Find.One.IsEnabled -and $ed.Find.All.IsEnabled -and $ed.Find.One.ToolTip -ceq '고른 곳을 바꾸고 다음을 찾습니다 (Enter)' -and
            $ed.Find.All.ToolTip -ceq '찾은 것을 모두 바꿉니다' -and
            [Windows.Controls.ToolTipService]::GetShowOnDisabled($ed.Find.One) -and [Windows.Controls.ToolTipService]::GetShowOnDisabled($ed.Find.All))
        Set-EdText $ed (('a' * 50000) + '!')
        foreach ($slow in '(a+)+$', '^(a|aa)+$') {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $ed.Find.Query.Text = $slow
            Assert-Ed 'FindRegex-Errors: 500ms 시간 한도 · 시간 초과 이유 · 바꾸기 비활성' (
                $ed.Find.Count.Text -ceq '식 오류' -and $ed.Find.Query.ToolTip -ceq '식이 너무 오래 걸립니다. 식을 좁히세요.' -and
                -not $ed.Find.One.IsEnabled -and -not $ed.Find.All.IsEnabled -and $watch.ElapsedMilliseconds -lt 3000) $watch.ElapsedMilliseconds
        }
        $ed.Find.Query.Clear(); Set-WtSetting 'memo.find.regex' $false
    }
    Invoke-EdCase 'FindRegex-KoreanReasons' {
        $ed = New-EdEditor; Set-EdText $ed 'SRV-01'
        Open-WtMemoFind $ed -Replace; $ed.Find.Regex.IsChecked = $true
        $cases = @(
            @('SRV-(', '닫는 괄호 )가 모자랍니다.'), @(')', '여는 괄호 (가 모자랍니다.'),
            @('[', '[ ]의 닫는 ]가 없습니다.'), @('*', '반복(* + ? {})할 글자가 앞에 없습니다.'),
            @('\', '끝의 \가 혼자 있습니다.'), @('\q', '정규식을 확인하세요. (2번째 글자 근처)')
        )
        $ok = $true; $details = [Collections.Generic.List[string]]::new()
        foreach ($case in $cases) {
            $ed.Find.Query.Text = $case[0]
            $ok = $ok -and $ed.Find.Query.ToolTip -ceq $case[1] -and $ed.Find.Count.ToolTip -ceq $case[1] -and
                $ed.Find.Count.Text -ceq '식 오류' -and $ed.Find.Count.Foreground.Color -eq $ed.Root.FindResource('B.Status.Error.Text').Color -and
                -not $ed.Find.One.IsEnabled -and -not $ed.Find.All.IsEnabled -and
                $ed.Find.One.ToolTip -ceq '찾기 식을 고치면 바꿀 수 있습니다.' -and $ed.Find.All.ToolTip -ceq '찾기 식을 고치면 바꿀 수 있습니다.'
            $details.Add("$($case[0])=$($ed.Find.Query.ToolTip)")
        }
        Assert-Ed 'FindRegex-KoreanReasons: Error별 한국어 · Offset 대체 문구 · 오류 글자색 · 비활성 이유' $ok ($details -join ' | ')
        $ed.Find.Query.Clear(); Set-WtSetting 'memo.find.regex' $false
    }
    Invoke-EdCase 'FindRegex-Read' {
        $ed = New-EdEditor; Set-EdText $ed "one **Target** end`nTarget"
        Set-WtMemoEditorMode $ed read; Open-WtMemoFind $ed
        $ed.Find.Case.IsChecked = $false; $ed.Find.Regex.IsChecked = $true
        $ed.Find.Query.Text = '^target$'
        Assert-Ed 'FindRegex-Read: 줄 단위 앵커 · 굵게 Run 경계는 줄 시작 아님' ($ed.Find.Count.Text -ceq '1/1' -and $ed.View.Selection.Text -ceq 'Target')
        $ed.Find.Query.Text = 'one Target'; $across = $ed.Find.Count.Text -ceq '1/1'
        $ed.Find.Case.IsChecked = $true; $ed.Find.Query.Text = 'target'
        Assert-Ed 'FindRegex-Read: Run 사이 일치 · 대소문자 옵션' ($across -and $ed.Find.Count.Text -ceq '0개')
        Set-EdText $ed ''; $ed.Find.Query.Text = '('
        Assert-Ed 'FindRegex-Read: 빈 문서도 틀린 식 표시' ($ed.Find.Count.Text -ceq '식 오류')
        $ed.Find.Query.Clear(); Set-WtSetting 'memo.find.case' $false; Set-WtSetting 'memo.find.regex' $false
    }
    Invoke-EdCase 'FindOptions-Remember' {
        Set-WtSetting 'memo.find.case' $false; Set-WtSetting 'memo.find.regex' $false
        $ed = New-EdEditor; Set-EdText $ed 'ab'; Open-WtMemoFind $ed -Replace
        $original = & $em { ${function:Get-WtMemoEditorModifiers} }
        try {
            & $em { function script:Get-WtMemoEditorModifiers { [Windows.Input.ModifierKeys]::Alt } }
            foreach ($key in 'C', 'R') {
                $args = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $testSource, 0, [Windows.Input.Key]$key)
                $args.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
                $ed.Find.Query.RaiseEvent($args)
                Assert-Ed "FindOptions-Remember: Alt+$key 찾기 막대 키 경로로 토글" ($args.Handled -and (Get-WtSetting $(if ($key -ceq 'C') { 'memo.find.case' } else { 'memo.find.regex' })))
            }
            Wait-WtTestWrites; Initialize-WtSettings
            $restored = New-EdEditor
            Set-WtMemoEditorMode $restored source
            [void]$restored.Source.Focus(); Sync-EdUi
            $outside = & $em { param($x) Invoke-WtMemoFindOptionKey $x 'C' ([Windows.Input.ModifierKeys]::Alt) } $restored
            Assert-Ed 'FindOptions-Remember: 다시 읽은 설정 · 새 편집기 기억 · 막대 밖 키 무시 · 접근성 이름' (
                $restored.Find.Case.IsChecked -and $restored.Find.Regex.IsChecked -and -not $outside -and
                [Windows.Automation.AutomationProperties]::GetAutomationId($restored.Find.Case) -ceq 'Memo-Find-Case' -and
                [Windows.Automation.AutomationProperties]::GetAutomationId($restored.Find.Regex) -ceq 'Memo-Find-Regex' -and
                [Windows.Automation.AutomationProperties]::GetName($restored.Find.Case) -ceq '대소문자 구분' -and
                [Windows.Automation.AutomationProperties]::GetName($restored.Find.Regex) -ceq '정규식')
        } finally {
            & $em { param($fn) Set-Item function:script:Get-WtMemoEditorModifiers $fn } $original
            Set-WtSetting 'memo.find.case' $false; Set-WtSetting 'memo.find.regex' $false
        }
    }
    Invoke-EdCase 'FindOptions-KeepsFocus' {
        $original = & $em { ${function:Get-WtMemoEditorModifiers} }
        function Send-FindKey([string]$Key, [Windows.Input.ModifierKeys]$Mods) {
            & $em { param($m) $script:findTestMods = $m } $Mods
            try {
                $target = [Windows.Input.Keyboard]::FocusedElement
                $args = [Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $testSource, 0, [Windows.Input.Key]$Key)
                if ($Mods -eq [Windows.Input.ModifierKeys]::Alt) {
                    [void][Windows.Input.KeyEventArgs].GetMethod('MarkSystem', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($args, $null)
                }
                $args.RoutedEvent = [Windows.Input.Keyboard]::PreviewKeyDownEvent
                $target.RaiseEvent($args)
                $args.Handled
            } finally { & $em { $script:findTestMods = [Windows.Input.ModifierKeys]::None } }
        }
        function Drain-FindUi {
            $win.UpdateLayout()
            [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
            Wait-EdUi 20
            [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
        }
        function Type-FindText([string]$Text) {
            foreach ($letter in $Text.ToCharArray()) {
                $target = [Windows.Input.Keyboard]::FocusedElement
                $tc = [Windows.Input.TextComposition]::new([Windows.Input.InputManager]::Current, $target, [string]$letter)
                foreach ($ev in [Windows.Input.TextCompositionManager]::PreviewTextInputStartEvent,
                    [Windows.Input.TextCompositionManager]::PreviewTextInputEvent, [Windows.Input.TextCompositionManager]::TextInputEvent) {
                    $args = [Windows.Input.TextCompositionEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice, $tc)
                    $args.RoutedEvent = $ev; $target.RaiseEvent($args)
                    if ($ev -ne [Windows.Input.TextCompositionManager]::PreviewTextInputStartEvent -and $args.Handled) { break }
                }
                Drain-FindUi
            }
        }
        try {
            & $em {
                $script:findTestMods = [Windows.Input.ModifierKeys]::None
                function script:Get-WtMemoEditorModifiers { $script:findTestMods }
            }
            foreach ($mode in 'live', 'source') {
                Set-WtSetting 'memo.find.case' $false; Set-WtSetting 'memo.find.regex' $false
                $ed = New-EdEditor; Set-WtMemoEditorMode $ed $mode
                $body = "# 서버`n`nSRV-01`n`nsrv-02`n`nSRV-03"
                Set-EdText $ed $body
                if ($mode -eq 'live') { Open-EdAt $ed 2 0 } else { [void]$ed.Source.Focus() }
                Drain-FindUi
                [void](Get-EdBox $ed).Focus()
                $opened = Send-FindKey H Control
                Drain-FindUi
                foreach ($option in $ed.Find.Case, $ed.Find.Regex) {
                    [void]$option.Focus(); $option.IsChecked = $true; Drain-FindUi
                }
                [void]$ed.Find.Query.Focus(); Type-FindText '^SRV'
                $typed = $opened -and $ed.Find.Bar.IsKeyboardFocusWithin -and $ed.Find.Query.Text -ceq '^SRV' -and
                    $ed.Find.Count.Text -match '(?:2개|/2)$' -and (Get-EdText $ed) -ceq $body
                $holder = if ($ed.Island) { $ed.Island.Holder } else { $null }
                # 글이 있는 상태의 옵션 클릭과 뒤따르는 입력도 실제 포커스를 받는 곳으로 보낸다.
                [void]$ed.Find.Case.Focus(); $ed.Find.Case.IsChecked = $false; Drain-FindUi
                Type-FindText '-'
                Assert-Ed "FindOptions-KeepsFocus: $mode 옵션 클릭 · 글자마다 Dispatcher 뒤에도 막대 포커스 · 본문 보존" (
                    $typed -and $ed.Find.Bar.IsKeyboardFocusWithin -and $ed.Find.Query.Text -ceq '^SRV-' -and
                    (Get-EdText $ed) -ceq $body -and ($mode -eq 'source' -or [object]::ReferenceEquals($holder, $ed.Island.Holder))) "찾기=[$($ed.Find.Query.Text)] 포커스=$([Windows.Input.Keyboard]::FocusedElement.GetType().Name) 막대=$($ed.Find.Bar.IsKeyboardFocusWithin)"
                [void]$ed.Find.Query.Focus(); $ed.Find.Query.Text = '^SRV'; $ed.Find.Case.IsChecked = $true; Drain-FindUi
                $steps = [Collections.Generic.List[string]]::new(); $kept = $true
                foreach ($step in @(@('C', 3), @('C', 2), @('R', 0), @('R', 2))) {
                    # 중간에 포커스를 다시 주지 않는다. 다음 키도 그때 실제 포커스가 있는 요소에서 출발한다.
                    # 섬 재부착 때 WPF가 남기는 늦은 본문 포커스 요청을 같은 Dispatcher 경로로 재현한다.
                    $lateTarget = Get-EdBox $ed
                    [void]$lateTarget.Dispatcher.BeginInvoke([Action[object]] { param($b) [void]$b.Focus() },
                        [Windows.Threading.DispatcherPriority]::Input, [object[]]@($lateTarget))
                    $handled = Send-FindKey $step[0] Alt; Drain-FindUi
                    $total = $step[1]; $count = $ed.Find.Count.Text
                    $ok = $handled -and $ed.Find.Bar.IsKeyboardFocusWithin -and $count -match "(?:${total}개|/$total)$"
                    $kept = $kept -and $ok
                    $steps.Add("$($step[0]):$handled/$($ed.Find.Bar.IsKeyboardFocusWithin)/$count")
                }
                Assert-Ed "FindOptions-KeepsFocus: $mode Alt+C → Alt+C → Alt+R → Alt+R 실제 System 키 경로 · 포커스 유지" (
                    $kept -and $ed.Find.Case.IsChecked -and $ed.Find.Regex.IsChecked -and (Get-EdText $ed) -ceq $body) ($steps -join ' | ')
                $box = Get-EdBox $ed
                $mouse = [Windows.Input.MouseButtonEventArgs]::new([Windows.Input.Mouse]::PrimaryDevice, 0, [Windows.Input.MouseButton]::Left)
                $mouse.RoutedEvent = [Windows.Input.Mouse]::PreviewMouseDownEvent
                $box.RaiseEvent($mouse); [void]$box.Focus(); Drain-FindUi
                Assert-Ed "FindOptions-KeepsFocus: $mode 본문을 직접 클릭하면 본문으로 이동 가능" ($box.IsKeyboardFocused -and -not $ed.Find.Bar.IsKeyboardFocusWithin)
            }
        } finally {
            & $em { param($fn) Set-Item function:script:Get-WtMemoEditorModifiers $fn } $original
            Set-WtSetting 'memo.find.case' $false; Set-WtSetting 'memo.find.regex' $false
        }
    }
    Invoke-EdCase 'FindLayout-OptionGap' {
        $ed = New-EdEditor; Set-EdText $ed '본문'; Open-WtMemoFind $ed -Replace
        $win.UpdateLayout(); Sync-EdUi; $win.UpdateLayout()
        $caseX = $ed.Find.Case.TranslatePoint([Windows.Point]::new(0, 0), $ed.Find.Query).X
        $regexX = $ed.Find.Regex.TranslatePoint([Windows.Point]::new(0, 0), $ed.Find.Case).X
        Assert-Ed 'FindLayout-OptionGap: 찾기 칸 → Aa 4 · Aa → .* 4 · 두 입력칸 같은 폭' (
            [Math]::Abs($caseX - $ed.Find.Query.ActualWidth - 4) -lt 0.5 -and
            [Math]::Abs($regexX - $ed.Find.Case.ActualWidth - 4) -lt 0.5 -and
            [Math]::Abs($ed.Find.Query.ActualWidth - $ed.Find.Replace.ActualWidth) -lt 0.5)
    }
    Invoke-EdCase 'FindOptions-VisibleBorder' {
        $ed = New-EdEditor; Set-EdText $ed '본문'; Open-WtMemoFind $ed
        foreach ($checked in $false, $true) {
            $ok = $true
            foreach ($button in $ed.Find.Case, $ed.Find.Regex) {
                $button.IsChecked = $checked; $button.ApplyTemplate() | Out-Null
                $border = [Windows.Media.VisualTreeHelper]::GetChild($button, 0)
                $brush = if ($checked) { 'B.Accent' } else { 'B.Border.Default' }
                $text = if ($checked) { 'B.Accent.Text' } else { 'B.Text.Secondary' }
                $ok = $ok -and $button.BorderThickness.Equals([Windows.Thickness]::new(1)) -and
                    $button.BorderBrush.Color -eq $ed.Root.FindResource($brush).Color -and
                    $button.Foreground.Color -eq $ed.Root.FindResource($text).Color -and $border.CornerRadius.TopLeft -eq 4 -and
                    $border.BorderThickness.Equals([Windows.Thickness]::new(1))
                $ok = $ok -and $(if ($checked) { $button.Background.Color -eq $ed.Root.FindResource('B.Bg.Selected').Color } else { $button.Background.Color.A -eq 0 })
            }
            Assert-Ed "FindOptions-VisibleBorder: 켜짐=$checked · 선 1 · 모서리 4 · 지정한 바탕/선/글자색" $ok
        }
        Set-WtSetting 'memo.find.case' $false; Set-WtSetting 'memo.find.regex' $false
    }
    Invoke-EdCase 'FindSelection-Inactive' {
        foreach ($mode in 'live', 'source') {
            $ed = New-EdEditor; Set-WtMemoEditorMode $ed $mode
            Set-EdText $ed "# 제목`n`n선택 needle 본문"; Open-WtMemoFind $ed
            $ed.Find.Query.Text = 'needle'; Sync-EdUi; $win.UpdateLayout()
            $box = Get-EdBox $ed
            Assert-Ed "FindSelection-Inactive: $mode 그린 블록을 선택 · 비활성 선택 표시 · 찾기 포커스 범위 분리" (
                $box.IsInactiveSelectionHighlightEnabled -and $box.SelectedText -ceq 'needle' -and -not $box.IsKeyboardFocusWithin -and
                $ed.Find.Query.IsKeyboardFocusWithin -and [Windows.Input.FocusManager]::GetIsFocusScope($ed.Find.Bar) -and
                ($mode -eq 'source' -or ($ed.Island -and $ed.Island.Start -eq 2)))
        }
    }
    Invoke-EdCase 'InputFocus-SingleOutline' {
        $ed = New-EdEditor; Set-EdText $ed '본문'; Open-WtMemoFind $ed -Replace
        $win.UpdateLayout(); Sync-EdUi
        $ok = $null -eq $ed.Find.Query.FocusVisualStyle -and $null -eq $ed.Find.Replace.FocusVisualStyle -and
            $ed.Find.Query.BorderThickness.Equals([Windows.Thickness]::new(2)) -and
            $ed.Find.Query.BorderBrush.Color -eq $ed.Root.FindResource('B.Accent').Color
        foreach ($mode in 'source', 'live') {
            & $em { param($x) Close-WtMemoFind $x } $ed
            Set-WtMemoEditorMode $ed $mode
            if ($mode -eq 'live') { Open-EdAt $ed 0 0 }
            $win.UpdateLayout(); $box = Get-EdBox $ed; [void]$box.Focus(); Sync-EdUi
            # 메모 원문 · 섬은 문서 면이라 포커스가 있어도 테두리 · 강조선이 없다(11-17 승호: 줄 둘레 파란 네모가 어색)
            $ok = $ok -and $null -eq $box.FocusVisualStyle -and $null -eq $box.Template.FindName('FocusBorder', $box) -and
                $box.BorderThickness.Equals([Windows.Thickness]::new(0))
        }
        foreach ($key in 'Btn', 'Row', 'Check') {
            $focus = @((Get-WtStyleDictionary)[$key].Setters | Where-Object { $_.Property.Name -ceq 'FocusVisualStyle' })
            $ok = $ok -and $focus.Count -eq 1 -and $null -ne $focus[0].Value
        }
        Assert-Ed 'InputFocus-SingleOutline: Input은 2 Accent 하나 · 원문 · 섬은 테두리 없음 · 단추/행/체크 포커스 유지' $ok
    }
    Invoke-EdCase 'FindHint-HidesWhileTyping' {
        $ed = New-EdEditor
        Set-EdText $ed 'target'
        Open-WtMemoFind $ed -Replace
        $ed.Find.Query.Text = 'target'
        $ed.Find.Replace.Text = 'next'
        $win.UpdateLayout()
        Assert-Ed 'FindHint-HidesWhileTyping: 입력 즉시 두 안내 글자 숨김 · 같은 폭' (
            $ed.Find.Query.Tag.Text -ceq '찾기' -and $ed.Find.Query.Tag.Visibility -eq 'Collapsed' -and
            $ed.Find.Replace.Tag.Text -ceq '바꿀 글' -and $ed.Find.Replace.Tag.Visibility -eq 'Collapsed' -and
            [Math]::Abs($ed.Find.Query.ActualWidth - $ed.Find.Replace.ActualWidth) -lt 1 -and
            $ed.Find.Replace.Parent.Children.Count -eq 2 -and $ed.Find.Replace.Padding.Left -eq 10 -and
            [object]::ReferenceEquals($ed.Find.Replace.Style, $ed.Root.FindResource('Input'))) "찾기=$($ed.Find.Query.ActualWidth) 바꾸기=$($ed.Find.Replace.ActualWidth)"
        $ed.Find.Query.Clear(); $ed.Find.Replace.Clear()
        Assert-Ed 'FindHint-HidesWhileTyping: 비우면 두 안내 글자 복원' ($ed.Find.Query.Tag.Visibility -eq 'Visible' -and $ed.Find.Replace.Tag.Visibility -eq 'Visible')
    }
    Invoke-EdCase 'FindReplace-ModeVisibility' {
        $ed = New-EdEditor
        Set-EdText $ed 'target'
        foreach ($mode in 'live', 'source', 'read') {
            Set-WtMemoEditorMode $ed $mode
            Open-WtMemoFind $ed
            $findOnly = $ed.Find.ReplaceRow.Visibility -eq 'Collapsed' -and $ed.Mode -eq $mode
            Open-WtMemoFind $ed -Replace
            Assert-Ed "FindReplace-ModeVisibility: $mode 찾기 · 바꾸기" (
                $findOnly -and $ed.Find.ReplaceRow.Visibility -eq 'Visible' -and $ed.Mode -eq $(if ($mode -eq 'read') { 'live' } else { $mode }))
        }
    }
    Invoke-EdCase 'BodyContextMenu-KoreanCommands' {
        $ed = New-EdEditor
        Set-EdText $ed '본문'
        foreach ($target in $ed.Live, $ed.IslandBox, $ed.Source) {
            $target.ContextMenu.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
            $target.ContextMenu.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
            & $em { param($m) Update-WtMemoContextMenu $m } $target.ContextMenu
            Assert-Ed 'BodyContextMenu-KoreanCommands: 한글 · 단축키 · 공통 스타일 · 선택 전 비활성' (
                ($target.ContextMenu.Items.Header -join ',') -ceq '잘라내기,복사,붙여넣기,모두 선택' -and
                ($target.ContextMenu.Items.InputGestureText -join ',') -ceq 'Ctrl+X,Ctrl+C,Ctrl+V,Ctrl+A' -and
                -not $target.ContextMenu.Items[0].IsEnabled -and -not $target.ContextMenu.Items[1].IsEnabled -and
                [object]::ReferenceEquals($target.ContextMenu.Style, $edHost.FindResource('Home.PinMenu')))
        }
        & $em { param($x) Invoke-WtMemoContextAction $x 'SelectAll'; Update-WtMemoContextMenu $x.IslandBox.ContextMenu } $ed
        Assert-Ed 'BodyContextMenu-KoreanCommands: 모두 선택은 본문 전체 섬 · 잘라내기와 복사 가능' (
            $ed.IslandBox.SelectedText -ceq '본문' -and $ed.IslandBox.ContextMenu.Items[0].IsEnabled -and $ed.IslandBox.ContextMenu.Items[1].IsEnabled)
        $ed.IslandBox.SelectedText = "본문`r`n둘째"
        & $em { param($x) Invoke-WtMemoContextAction $x 'SelectAll' } $ed
        Assert-Ed 'BodyContextMenu-KoreanCommands: 아직 저장하지 않은 새 줄도 모두 선택' ($ed.IslandBox.SelectedText -ceq "본문`r`n둘째")
    }

    # ---- 11-22 실사용 보고 회귀 (번호 = 보고서 번호) ----
    Invoke-EdCase 'MemoView-NoFocusOutline' {
        $ed = New-EdEditor
        Set-EdText $ed "# 제목`n`n본문"
        $ok = $true; $detail = @()
        foreach ($mode in 'live', 'read') {
            Set-WtMemoEditorMode $ed $mode
            $surface = if ($mode -eq 'live') { $ed.Live } else { $ed.View }
            [void]$surface.Focus(); Sync-EdUi
            $ok = $ok -and $surface.IsKeyboardFocused -and $null -eq $surface.FocusVisualStyle
            $detail += "$mode 포커스=$($surface.IsKeyboardFocused) 포커스모양=$($surface.FocusVisualStyle)"
        }
        Assert-Ed 'MemoView-NoFocusOutline: 편집 · 읽기 보기 문서 면은 포커스가 있어도 바깥 포커스 네모 없음 (16)' $ok ($detail -join ' / ')
        Set-WtMemoEditorMode $ed 'live'
    }
    Invoke-EdCase 'ReadTask-KeepsFocus' {
        $ed = New-EdEditor
        Set-EdText $ed "# 할 일`n`n- [ ] 하나`n- [ ] 둘"
        Set-WtMemoEditorMode $ed 'read'
        $win.UpdateLayout()
        $link = Find-EdTaskLink $ed.View 3
        if (-not $link) { throw '읽기 보기 체크 표시를 찾지 못했습니다' }
        Assert-EdInputPath $ed.View $link.Inlines.FirstInline $link '읽기 보기 체크 줄 3'
        [void]$link.Focus()   # 실제로 누르면 체크 표시(링크)가 포커스를 받는다
        $linkFocused = $link.IsKeyboardFocused
        $link.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent, $link))
        Sync-EdUi
        $focused = [System.Windows.Input.Keyboard]::FocusedElement
        Assert-Ed 'ReadTask-KeepsFocus: 읽기 보기 체크를 누른 뒤에도 키보드 포커스가 보기에 남는다 (5②)' (
            $linkFocused -and $ed.Lines[2] -ceq '- [x] 하나' -and $ed.View.IsKeyboardFocusWithin) "링크포커스=$linkFocused 줄=[$($ed.Lines[2])] 포커스=$(if ($focused) { $focused.GetType().Name } else { '없음' })"
        Set-WtMemoEditorMode $ed 'live'
    }
    Invoke-EdCase 'FindBar-SideMargin' {
        $ed = New-EdEditor; Set-EdText $ed '본문 target'
        Set-WtMemoEditorSide $ed 44
        Open-WtMemoFind $ed -Replace
        $win.UpdateLayout(); Sync-EdUi; $win.UpdateLayout()
        $rectOf = { param($el) $el.TransformToAncestor($ed.Root).TransformBounds([Windows.Rect]::new([Windows.Point]::new(0, 0), $el.RenderSize)) }
        $actions = $ed.Find.Count.Parent
        $close = $actions.Children[$actions.Children.Count - 1]
        $q = & $rectOf $ed.Find.Query; $r = & $rectOf $ed.Find.Replace; $c = & $rectOf $close; $a = & $rectOf $ed.Find.All
        $width = $ed.Root.ActualWidth
        Assert-Ed 'FindBar-SideMargin: 찾기 막대는 글과 같은 좌우 44 · 닫기와 모두 바꾸기 오른쪽 끝 같음 · 두 칸 같은 폭 · 아래 선은 칸 끝까지 (18)' (
            [Math]::Abs($q.Left - 44) -lt 0.5 -and [Math]::Abs($r.Left - 44) -lt 0.5 -and
            [Math]::Abs($c.Right - ($width - 44)) -lt 0.5 -and [Math]::Abs($a.Right - ($width - 44)) -lt 0.5 -and
            [Math]::Abs($q.Width - $r.Width) -lt 0.5 -and [Math]::Abs($ed.Find.Bar.ActualWidth - $width) -lt 0.5) "찾기 왼쪽=$($q.Left) 바꾸기 왼쪽=$($r.Left) 닫기 오른쪽=$($c.Right) 모두 오른쪽=$($a.Right) 폭=$width"
        & $em { param($x) Close-WtMemoFind $x } $ed
    }
    Invoke-EdCase 'FindReplace-AfterIslandClosed' {
        $ed = New-EdEditor
        Set-EdText $ed "# SRV-03 작업`n`n대상 서버 ``SRV-03`` 점검`n`n| 서버 | 상태 |`n| --- | --- |`n| SRV-03 | 교체 |`n| SRV-01 | 정상 |"
        try {
            Open-EdAt $ed 2 6
            Open-WtMemoFind $ed -Replace
            $ed.Find.Regex.IsChecked = $true
            $ed.Find.Query.Text = 'SRV-0[0-9]'   # 찾기 칸에 치면 커서부터 첫 일치를 고른다
            Sync-EdUi
            $ed.Find.Replace.Text = 'SRV-99'
            $before = "$($ed.Find.Count.Text)|$($ed.IslandBox.SelectedText)"
            [System.Windows.Input.Keyboard]::ClearFocus(); Sync-EdUi   # 창 전환 등으로 포커스가 편집기 밖으로 나가 섬이 닫힌다
            $closed = -not $ed.Island
            Assert-EdInputPath $ed.Root $ed.Find.One $ed.Find.One '바꾸기 단추'
            [void]$ed.Find.One.Focus()
            $ed.Find.One.GetType().GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($ed.Find.One, @())
            Sync-EdUi
            $text = Get-EdText $ed
            Assert-Ed 'FindReplace-AfterIslandClosed: 섬이 닫혀도 첫 바꾸기가 찾아 둔 SRV-03을 바로 바꾸고 다음 일치로 (6)' (
                $before -ceq '4개|SRV-03' -and $closed -and $text.Contains('대상 서버 `SRV-99` 점검') -and ([regex]::Matches($text, 'SRV-99')).Count -eq 1 -and
                $ed.Find.Count.Text -ceq '2/3' -and $ed.IslandBox.SelectedText -ceq 'SRV-03') "전=$before 닫힘=$closed 개수=$($ed.Find.Count.Text) 선택=[$($ed.IslandBox.SelectedText)] 글=$($text.Replace("`n", '¶'))"
            # 본문을 눌러 커서를 옮겼으면 찾아 둔 곳은 버린다: 바꾸지 않고 커서부터 다음을 찾는다
            Open-EdAt $ed 0 0
            & $em { param($x) $x.Find.LastMatch = $null } $ed   # 본문 누름(PreviewMouseDown)이 하는 일
            [System.Windows.Input.Keyboard]::ClearFocus(); Sync-EdUi
            & $em { param($x) Invoke-WtMemoReplace $x } $ed
            Assert-Ed 'FindReplace-AfterIslandClosed: 커서를 옮긴 뒤 닫힌 섬에서는 바꾸지 않고 다음을 찾는다' (([regex]::Matches((Get-EdText $ed), 'SRV-99')).Count -eq 1) (Get-EdText $ed)
        } finally {
            & $em { param($x) Close-WtMemoFind $x } $ed
            Set-WtSetting 'memo.find.regex' $false
        }
    }
    Invoke-EdCase 'FindCount-RefreshOnChange' {
        $ed = New-EdEditor
        Set-EdText $ed 'SRV-01 SRV-02 SRV-03'
        Open-EdAt $ed 0 0
        Open-WtMemoFind $ed -Replace
        $ed.Find.Query.Text = 'SRV'; Sync-EdUi
        $ed.Find.Replace.Text = 'HOST'
        & $em { param($x) Invoke-WtMemoReplace $x -All } $ed
        Sync-EdUi
        $afterAll = "$($ed.Find.Count.Text)|$($ed.Find.One.IsEnabled)|$($ed.Find.All.IsEnabled)|$($ed.Find.One.ToolTip)"
        Set-EdText $ed '외부 구간 10.0.0.20:8443 허용 규칙'   # 다른 메모를 연 것처럼 글을 불러온다
        Sync-EdUi
        $other = "$($ed.Find.Count.Text)|$($ed.Find.One.IsEnabled)|$($ed.Find.All.IsEnabled)"
        Set-EdText $ed 'SRV-07 하나'
        Sync-EdUi
        $again = "$($ed.Find.Count.Text)|$($ed.Find.One.IsEnabled)"
        Assert-Ed 'FindCount-RefreshOnChange: 모두 바꾸기 뒤 남은 0개로 단추 꺼짐 · 다른 메모로 바꾸면 다시 센다 (7)' (
            $afterAll -ceq '3개 바꿈|False|False|찾은 것이 없습니다.' -and $other -ceq '0개|False|False' -and $again -ceq '1개|True') "모두 뒤=$afterAll 다른 메모=$other 다시=$again"
        Open-EdAt $ed 0 0
        Send-EdText $ed 'SRV-08 '
        Wait-EdUi 30; Sync-EdUi
        Assert-Ed 'FindCount-RefreshOnChange: 막대가 열린 채 글을 고치면 한가할 때 다시 센다' ($ed.Find.Count.Text -ceq '2개') $ed.Find.Count.Text
        & $em { param($x) Close-WtMemoFind $x } $ed
    }
    Invoke-EdCase 'BodyHint-EmptyMemo' {
        $ed = New-EdEditor
        Set-WtMemoEditorSide $ed 44
        $ok = $true; $detail = @()
        foreach ($mode in 'live', 'source') {
            Set-WtMemoEditorMode $ed $mode
            Set-EdText $ed ''
            if ($mode -eq 'live') { Open-EdAt $ed 0 0 }
            $win.UpdateLayout(); Sync-EdUi
            $box = Get-EdBox $ed
            $caret = $box.GetRectFromCharacterIndex(0); $cp = $box.TranslatePoint($caret.TopLeft, $ed.Body)
            $glyph = $ed.Hint.ContentStart.GetNextInsertionPosition('Forward').GetCharacterRect('Backward'); $hp = $ed.Hint.TranslatePoint($glyph.TopLeft, $ed.Body)
            $shown = $ed.Hint.Visibility -eq 'Visible' -and $ed.Hint.Text -ceq '내용을 입력하세요' -and
                $ed.Hint.Foreground.Color -eq $ed.Root.FindResource('B.Text.Tertiary').Color -and $ed.Hint.FontSize -eq $ed.Root.FindResource('F.Memo.Body')
            $aligned = [Math]::Abs($cp.X - $hp.X) -lt 0.5 -and [Math]::Abs($cp.Y - $hp.Y) -lt 0.5
            $surface = if ($mode -eq 'live') { $ed.Live } else { $ed.Source }
            $route = Test-WtTestInputPath -View $ed.Root -Element $ed.Hint -Target $surface
            Send-EdText $ed '가'; Sync-EdUi
            $hidden = $ed.Hint.Visibility -eq 'Collapsed'
            $ok = $ok -and $shown -and $aligned -and $route.Reached -and $hidden
            $detail += "$mode 보임=$shown 맞춤=$aligned(커서 $($cp.X),$($cp.Y) 글자 $($hp.X),$($hp.Y)) 누름=$($route.Reached) 숨김=$hidden"
        }
        Set-EdText $ed ''; Set-WtMemoEditorMode $ed 'read'
        $ok = $ok -and $ed.Hint.Visibility -eq 'Collapsed'
        Assert-Ed 'BodyHint-EmptyMemo: 빈 본문은 첫 글자 자리에 예시 글자 · 누름은 본문으로 · 쓰면 숨김 · 읽기 보기 없음 (헤맨 곳)' $ok ($detail -join ' / ')
        Set-WtMemoEditorMode $ed 'live'
    }

    # ---- 무작위 편집 (고정 시드) ----
    # 코드 블록 없는 글로 돌린다 (울타리 짝이 깨지면 알려진 버그 fence-kind-change에 걸려 그 뒤를 못 봐서)
    $randSample = @($sample[0..10]) + @($sample[15..25])
    $randText = Join-EdLines $randSample
    foreach ($seed in $Seeds) {
        Invoke-EdCase "무작위 편집 (시드 $seed)" {
            $ed = New-EdEditor
            Set-EdText $ed $randText
            $rnd = [System.Random]::new($seed)
            $snips = @('a', '가', '- ', '# ', '> ', '1. ', '**', '[[x]]', '|', '[', ' ', '    ', '- [ ] ', '---')
            $keys = @('Up', 'Down', 'Left', 'Right', 'Back', 'Delete', 'Return', 'Tab', 'Home', 'End', 'PageUp')
            $cmds = @('Ctrl+B', 'Shift+Tab', 'Alt+Up', 'Alt+Down', 'Ctrl+Home', 'Ctrl+End', 'Shift+Down', 'Shift+Up', 'Ctrl+L')
            $log = [System.Collections.Generic.List[string]]::new()
            $okAll = $true
            $lastTyped = $false
            $steps = $Steps
            for ($n = 0; $n -lt $steps -and $okAll; $n++) {
                $r = $rnd.Next(100)
                # 실행 취소 단위(쉬었다 치기)를 시각이 아니라 시드로 정한다 (같은 시드면 같은 결과).
                # 바로 앞이 글자 치기였을 때만 이어 친 것으로 본다
                if ($lastTyped -and $rnd.Next(3)) { $ed.LastEdit = [datetime]::UtcNow } else { Suspend-EdTyping $ed }
                $lastTyped = $false
                $what = ''
                $prevText = Get-EdText $ed
                $prevIsl = if ($ed.Island) { "섬 $($ed.Island.Start)..$($ed.Island.End) 커서 $(Get-EdCaret $ed) 섬 글 [$($ed.IslandBox.Text.Replace("`r`n", '¶'))]" } else { '섬 없음' }
                if (-not $ed.Island -or $r -lt 8) {
                    $l = $rnd.Next($ed.Lines.Count); $c = $rnd.Next($ed.Lines[$l].Length + 1)
                    $what = "열기 $l`:$c"; Open-EdAt $ed $l $c
                } elseif ($r -lt 40) {
                    $k = $keys[$rnd.Next($keys.Count)]; $what = "키 $k"; Send-EdKey $ed $k
                } elseif ($r -lt 62) {
                    $s = $snips[$rnd.Next($snips.Count)]; $what = "치기 [$s]"; Send-EdText $ed $s
                    $lastTyped = $true
                } elseif ($r -lt 74) {
                    $c = $cmds[$rnd.Next($cmds.Count)]
                    $b = $ed.IslandBox
                    if ($c -eq 'Ctrl+B' -and $b.Text.Length) { $p = $rnd.Next($b.Text.Length); $b.Select($p, [Math]::Min(3, $b.Text.Length - $p)) }
                    $what = "명령 $c"; Invoke-EdCommand $ed $c
                } elseif ($r -lt 82) {
                    $what = '실행 취소'; Invoke-EdCommand $ed 'Ctrl+Z'
                } elseif ($r -lt 87) {
                    $what = '다시 실행'; Invoke-EdCommand $ed 'Ctrl+Y'
                } elseif ($r -lt 92) {
                    $what = '닫기'; Close-Ed $ed
                } elseif ($r -lt 95) {
                    $what = '모드 왕복'
                    $t0 = Get-EdText $ed
                    $null = Set-WtMemoEditorMode $ed 'source'; $null = Set-WtMemoEditorMode $ed 'live'
                    [void](Complete-EdRender $ed)
                    if ((Get-EdText $ed) -cne $t0) { $okAll = $false; Write-Host '  모드 왕복에서 글이 바뀜' }
                } else {
                    $b = $ed.IslandBox
                    $p = $rnd.Next($b.Text.Length + 1)
                    $what = "커서 $p"; $b.Select($p, 0)
                }
                $log.Add($what)
                if (-not (Test-EdContract $ed "무작위 $seed/$n ($what)")) {
                    $okAll = $false
                    Write-Host "  지나온 단계: $(($log | Select-Object -Last 8) -join ' → ')"
                    Write-Host "  앞 상태: $prevIsl"
                    Write-Host "  앞 글: $($prevText.Replace("`n", '¶'))"
                    Write-Host "  뒤 글: $((Get-EdText $ed).Replace("`n", '¶'))"
                }
            }
            Assert-Ed "편집기 무작위 편집 (시드 $seed, ${steps}단계): 문서 약속이 깨지지 않는다" $okAll
            Close-Ed $ed
            # 마지막 단계가 실행 취소였으면 다시 실행할 것이 남아 있다. 끝까지 다시 실행한 글을 마지막 글로 본다
            while ($ed.Redo.Count) { Invoke-EdCommand $ed 'Ctrl+Y' }
            $final = Get-EdText $ed
            $guard = 0
            while ($ed.Undo.Count -and $guard -lt 400) { Invoke-EdCommand $ed 'Ctrl+Z'; $guard++ }
            Assert-Ed "편집기 무작위 편집 (시드 $seed): 실행 취소를 끝까지 하면 처음 글" ((Get-EdText $ed) -ceq $randText) "($guard 번)"
            [void](Test-EdContract $ed '무작위 실행 취소 끝')
            $guard = 0
            while ($ed.Redo.Count -and $guard -lt 400) { Invoke-EdCommand $ed 'Ctrl+Y'; $guard++ }
            $got = Get-EdText $ed
            Assert-Ed "편집기 무작위 편집 (시드 $seed): 다시 실행을 끝까지 하면 마지막 글" ($got -ceq $final) "($guard 번) 기대 [$($final.Replace("`n", '¶'))] 결과 [$($got.Replace("`n", '¶'))]"
            [void](Test-EdContract $ed '무작위 다시 실행 끝')
        }
    }

    Assert-Ed '편집기: 오류 창(Show-WtError · Show-WtMessage)이 뜨지 않았다' ($script:edErrors.Count -eq 0)
} finally {
    $testSource.Dispose()
    $dispatcher.remove_UnhandledException($onUnhandled)
    & (Get-Module Ui) { param($o) Set-Item function:script:Show-WtError $o.Error; Set-Item function:script:Show-WtMessage $o.Message } $origUi
    & (Get-Module Markdown) { Remove-Item function:script:Show-WtError, function:script:Show-WtMessage -ErrorAction SilentlyContinue }
    Remove-WtTestData $test
}

$skipped = if ($script:edSkip.Count) { " · 건너뜀 $($script:edSkip.Count)건 (알려진 버그: $($script:edSkip -join ', '))" } else { '' }
Write-Host "메모 편집기: 통과 $script:edPass · 실패 $($script:edFail.Count) · 문서 약속 검사 $script:edContract 번$skipped"
if ($script:edFail.Count) { throw "FAIL 메모 편집기 $($script:edFail.Count)건: $($script:edFail -join ' || ')" }

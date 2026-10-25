<#
.SYNOPSIS
    메모 편집기(MemoEditor.psm1)를 화면 밖 시험 창에서 검사한다: 불러오기 · 섬 · 이동 · 잇기 · 실행 취소 · 모드 · 할 일 · 클릭 위치 · 나눠 그리기 · 편집 명령.

.DESCRIPTION
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.
    Windows STA에서만 돌린다(그 밖에는 건너뛴다). 시험 창은 화면 밖에 활성화하지 않고 띄운다.
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

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/memo/Test-MemoEditor.ps1

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/memo/Test-MemoEditor.ps1 -KnownBugs
#>
#Requires -Version 7.0
[CmdletBinding()]
param([switch]$KnownBugs, [int[]]$Seeds = @(20261025, 7, 4242), [int]$Steps = 150)

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

$win = [System.Windows.Window]::new()
$win.Width = 900; $win.Height = 700; $win.Left = -12000; $win.Top = 0
$win.WindowStartupLocation = 'Manual'; $win.ShowActivated = $false; $win.ShowInTaskbar = $false; $win.WindowStyle = 'None'
$edHost = [System.Windows.Controls.Grid]::new()
$edHost.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
$edHost.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
$win.Content = $edHost

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
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = $true
    while ($Ed.Rendered -lt $Ed.Units.Count -and $sw.ElapsedMilliseconds -lt 60000) {
        Wait-EdUi 10
        if ($Check -and $ok) { $ok = Test-EdContract $Ed $Where }
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

# 글자 입력: PreviewTextInput → 처리 안 됐으면 TextInput (TextBox가 넣는다)
function Send-EdText($Ed, [string]$Text) {
    $target = Get-EdBox $Ed
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
    $h.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent, $h))
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
    $win.Show()

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

        # 빈 줄에 서면 앞 단위에 붙는다
        Open-EdAt $ed 4 0
        Assert-Ed '편집기 섬: 빈 줄에서 열면 앞 단위와 같이 연다' ($ed.Island.Start -eq 2 -and $ed.Island.End -eq 5) "$($ed.Island.Start)..$($ed.Island.End)"
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
        for ($n = 0; $n -lt 19; $n++) {
            Send-EdKey $ed Down
            $seen.Add((Get-EdCaret $ed).Split(':')[0])
            if ($ok) { $ok = Test-EdContract $ed "아래로 $n" }
        }
        Assert-Ed '편집기 ↓: 제목 · 문단 · 목록 · 안쪽 목록 · 코드 · 표 · 콜아웃 · 할 일을 차례로 한 줄씩' (($seen -join ',') -eq '2,3,5,6,7,8,9,11,12,13,15,16,17,19,20,22,23,25,25') ($seen -join ',')
        $seen.Clear()
        for ($n = 0; $n -lt 19; $n++) {
            Send-EdKey $ed Up
            $seen.Add((Get-EdCaret $ed).Split(':')[0])
            if ($ok) { $ok = Test-EdContract $ed "위로 $n" }
        }
        Assert-Ed '편집기 ↑: 거꾸로 한 줄씩, 맨 위에서는 멈춘다' (($seen -join ',') -eq '23,22,20,19,17,16,15,13,12,11,9,8,7,6,5,3,2,0,0') ($seen -join ',')
        Assert-Ed '편집기 이동: 옮겨 다니기만 하면 글 · OnChanged 그대로' ((Get-EdText $ed) -ceq $sampleText -and $ed.TestChanged -eq 0) "$($ed.TestChanged)"

        Set-EdCaret $ed 0 4
        Send-EdKey $ed Down
        Assert-Ed '편집기 ↓: 칸을 지킨다' ((Get-EdCaret $ed) -eq '2:4') (Get-EdCaret $ed)
        $style = $null
        Open-EdAt $ed 12 0
        $style = $ed.IslandBox.Style
        Assert-Ed '편집기 섬: 코드 블록은 코드 글꼴 섬, 단위 전체(울타리 포함)' ($ed.Island.Start -eq 11 -and $ed.Island.End -eq 14 -and [object]::ReferenceEquals($style, $edHost.FindResource('Memo.IslandCode')))
        Open-EdAt $ed 0 3
        Assert-Ed '편집기 섬: 제목 하나는 그 단계 글꼴 섬' ([object]::ReferenceEquals($ed.IslandBox.Style, $edHost.FindResource('Memo.IslandH1')))

        Open-EdAt $ed 5 0
        Send-EdKey $ed Left
        Assert-Ed '편집기 ←: 단위 처음에서 앞 단위의 끝으로' ((Get-EdCaret $ed) -eq "3:$($sample[3].Length)") (Get-EdCaret $ed)
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

    # ---- 할 일 누르기 ----
    Invoke-EdCase '할 일' {
        $ed = New-EdEditor
        Set-EdText $ed $sampleText
        Invoke-EdTaskClick $ed.Live 23
        $want = $sample.Clone(); $want[22] = '- [x] 할 일'
        Assert-Ed '편집기 할 일(실시간): 누르면 [ ] → [x], 섬은 닫힘, OnChanged' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and -not $ed.Island -and $ed.TestChanged -eq 1) "$($ed.TestChanged)"
        [void](Test-EdContract $ed '할 일 누름')
        Invoke-EdTaskClick $ed.Live 24
        $want[23] = '- [ ] 끝난 일'
        Assert-Ed '편집기 할 일(실시간): [x] → [ ]' ((Get-EdText $ed) -ceq (Join-EdLines $want))
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
        Assert-Ed '편집기 할 일(실시간): 위쪽 섬에서 줄을 늘린 채로 눌러도 그 항목' ((Get-EdText $ed) -ceq (Join-EdLines $want)) (((Get-EdLines $ed)[22..24]) -join ' / ')
        [void](Test-EdContract $ed '섬 연 채로 할 일')

        # 읽기 모드
        Set-EdText $ed $sampleText
        $null = Set-WtMemoEditorMode $ed 'read'
        $changed = $ed.TestChanged
        Invoke-EdTaskClick $ed.View 23
        $want = $sample.Clone(); $want[22] = '- [x] 할 일'
        Assert-Ed '편집기 할 일(읽기): 누르면 [x], 보기를 다시 그리고 OnChanged' ((Get-EdText $ed) -ceq (Join-EdLines $want) -and $ed.TestChanged -eq $changed + 1 -and $ed.View.Tag.Text -ceq (Join-EdLines $want))
        Invoke-EdTaskClick $ed.View 23
        Assert-Ed '편집기 할 일(읽기): 다시 누르면 [ ]' ((Get-EdText $ed) -ceq $sampleText)
        $null = Set-WtMemoEditorMode $ed 'live'
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
    try { $win.Close() } catch { }
    $dispatcher.remove_UnhandledException($onUnhandled)
    & (Get-Module Ui) { param($o) Set-Item function:script:Show-WtError $o.Error; Set-Item function:script:Show-WtMessage $o.Message } $origUi
    & (Get-Module Markdown) { Remove-Item function:script:Show-WtError, function:script:Show-WtMessage -ErrorAction SilentlyContinue }
    Remove-WtTestData $test
}

$skipped = if ($script:edSkip.Count) { " · 건너뜀 $($script:edSkip.Count)건 (알려진 버그: $($script:edSkip -join ', '))" } else { '' }
Write-Host "메모 편집기: 통과 $script:edPass · 실패 $($script:edFail.Count) · 문서 약속 검사 $script:edContract 번$skipped"
if ($script:edFail.Count) { throw "FAIL 메모 편집기 $($script:edFail.Count)건: $($script:edFail -join ' || ')" }

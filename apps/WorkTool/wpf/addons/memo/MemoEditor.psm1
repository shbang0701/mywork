# 메모 편집기. 메모 화면의 칸(pane)마다 하나씩 만든다. 화면 배치 · 탭 · 저장은 Memo.psm1이 하고, 여기는 본문 한 칸만 맡는다.
#
# 모드
#   live    Obsidian처럼 그린 글 위에서 바로 고친다. 고치는 블록만 원문으로 보인다(섬)
#   source  원문(마크다운 그대로)
#   read    읽기 전용으로 그린 글
#
# 쓰는 법 (Memo.psm1)
#   $ed = New-WtMemoEditor -OnChanged { param($ed) ... } -OnLeave { param($ed) ... } `
#           -OnLink { param($ed, $link, $how) ...; $true } -OnTitles { param($ed, $prefix) ... }
#   $ed.Root를 화면에 넣는다
#   Set-WtMemoEditorText $ed $text      불러오기 (OnChanged를 부르지 않는다. 실행 취소 기록을 비운다)
#   Get-WtMemoEditorText $ed            지금 글 전체
#   Set-WtMemoEditorMode $ed 'live'     모드 바꾸기 (글은 그대로)
#   Set-WtMemoEditorEnabled $ed $false  메모가 없을 때
#   Set-WtMemoEditorFocus $ed [-End]    포커스 (커서는 마지막 자리, -End면 글 끝)
#   Get-WtMemoEditorState $ed / Set-WtMemoEditorState $ed $state   탭을 오갈 때 커서 · 스크롤 기억
#
# 알림
#   OnChanged  사용자가 글을 고쳤을 때
#   OnLeave    편집기 밖으로 포커스가 나갈 때 (저장)
#   OnLink     링크 · [[위키 링크]] · #태그를 눌렀을 때. $how = 'here' | 'tab'(Ctrl) | 'side'(Ctrl+Alt). 처리했으면 $true
#   OnTitles   [[ 자동 완성 후보. 메모 제목 문자열 배열을 돌려준다
#
# 실시간(live) 모드의 짜임
#   - 글은 줄 목록($ed.Lines)으로 들고, Get-WtMarkdownUnits로 블록(단위)을 나눠 단위마다 Section 하나로 그린다.
#   - 커서가 있는 단위만 BlockUIContainer 안의 TextBox(섬)로 바꿔 원문을 고친다. 한글 입력 · 선택 · 붙여넣기는 TextBox 그대로다.
#   - 섬 밖으로 나가면(↑↓←→ · 클릭) 고친 줄을 되돌려 넣고 바뀐 단위만 다시 그린다(그린 Section은 원문이 같으면 다시 쓴다).
#   - 실행 취소는 편집기가 따로 든다(글 전체 + 커서 자리). 섬을 옮겨 다녀도 이어진다.
#
# 이벤트 처리기는 나중에 불리므로 보낸 요소($s)의 Tag(= $ed, 보기는 Tag.Editor)와 $script: 변수만 쓴다.

$ErrorActionPreference = 'Stop'

$script:editors = [System.Collections.Generic.List[System.WeakReference]]::new()
$script:undoPause = [TimeSpan]::FromMilliseconds(1200)   # 이만큼 쉬었다 치면 실행 취소 단위를 새로 나눈다
$script:undoLimit = 200

# ---- 만들기 -----------------------------------------------------------------------------------

function New-WtMemoEditor {
    param([scriptblock]$OnChanged, [scriptblock]$OnLeave, [scriptblock]$OnLink, [scriptblock]$OnTitles)
    $ed = @{
        Mode = 'live'; Lines = [System.Collections.Generic.List[string]]::new(); NewLine = "`r`n"
        Enabled = $true; Loading = $false; Busy = 0
        OnChanged = $OnChanged; OnLeave = $OnLeave; OnLink = $OnLink; OnTitles = $OnTitles
        Units = [System.Collections.Generic.List[object]]::new(); Sections = [System.Collections.Generic.List[object]]::new()
        Rendered = 0; RenderTimer = $null; NextListId = 1; Cache = [System.Collections.Generic.Dictionary[string, object]]::new()
        Island = $null; Caret = @{ Line = 0; Col = 0 }; Drag = $null
        Undo = [System.Collections.Generic.List[object]]::new(); Redo = [System.Collections.Generic.List[object]]::new()
        LastEdit = [datetime]::MinValue; IslandPrev = ''; ReadText = $null
    }
    $ed.Lines.Add('')
    $root = [System.Windows.Controls.Grid]::new()
    $root.Tag = $ed
    $ed.Root = $root

    # 원문 모드 칸
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Editor'
    $box.Tag = $ed
    $box.Add_TextChanged({
            param($s, $e)
            $ed = $s.Tag
            if ($ed.Loading) { return }
            Invoke-WtMemoEditorChanged $ed
        })
    Add-WtMemoBoxHandlers $box
    [void]$root.Children.Add($box)
    $ed.Source = $box

    # 실시간 모드 보기 (단위별로 그린 문서 + 섬)
    $live = New-WtMarkdownView -Scroll -OnLink { param($link, $st) Invoke-WtMemoEditorLink $link $st } -OnTask { param($line, $el) Invoke-WtMemoTaskClick $line $el }
    $live.Tag.Editor = $ed
    # 문서에서 블록을 빼고 넣을 때 RichTextBox가 실행 취소용으로 뺀 요소를 XAML로 저장하려 한다.
    # 섬(Tag에 편집기 상태)을 저장하다 끝없이 파고들어 멈추므로 끈다. 실행 취소는 편집기가 따로 든다
    $live.IsUndoEnabled = $false
    $live.Add_PreviewMouseLeftButtonDown({ param($s, $e) Invoke-WtMemoLiveMouseDown $s $e })
    $live.Add_PreviewMouseMove({ param($s, $e) Invoke-WtMemoLiveMouseMove $s $e })
    $live.Add_PreviewMouseLeftButtonUp({ param($s, $e) Invoke-WtMemoLiveMouseUp $s $e })
    $live.Cursor = [System.Windows.Input.Cursors]::IBeam
    [void]$root.Children.Add($live)
    $ed.Live = $live
    Set-WtMarkdownText $live ''

    # 읽기 모드 보기 (문서 전체를 한 번에 그림)
    $view = New-WtMarkdownView -Scroll -OnLink { param($link, $st) Invoke-WtMemoEditorLink $link $st } -OnTask { param($line, $el) Invoke-WtMemoTaskClick $line $el }
    $view.Tag.Editor = $ed
    [void]$root.Children.Add($view)
    $ed.View = $view

    # 섬: 실시간 모드에서 고치는 단위 자리에 들어가는 원문 입력칸 (하나를 옮겨 가며 쓴다)
    $island = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $island 'Memo.Island'
    $island.Tag = $ed
    $island.IsUndoEnabled = $false
    $island.Add_TextChanged({
            param($s, $e)
            $ed = $s.Tag
            if ($ed.Loading -or -not $ed.Island) { return }
            Add-WtMemoTypingUndo $ed
            $ed.IslandPrev = $s.Text
            Invoke-WtMemoEditorChanged $ed
        })
    $island.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoIslandKey $s $e })
    $island.Add_PreviewMouseWheel({ param($s, $e) Invoke-WtMemoIslandWheel $s $e })
    Add-WtMemoBoxHandlers $island
    $ed.IslandBox = $island

    $root.Add_LostKeyboardFocus({
            param($s, $e)
            $ed = $s.Tag
            # 편집기 안에서 포커스가 옮겨 다닐 때 · 섬을 옮기는 중에는 부르지 않는다
            if ($ed.Busy -or $s.IsKeyboardFocusWithin) { return }
            if ($ed.Island) { Close-WtMemoIsland $ed }
            if ($ed.OnLeave) { & $ed.OnLeave $ed }
        })
    # 글을 고치는 칸(원문 · 섬)에서는 Ctrl+B가 굵게다. 읽기 모드 등 나머지 자리에서는 셸의 메뉴 접기 그대로
    Register-WtKeyOwner $box 'Ctrl+B'
    Register-WtKeyOwner $island 'Ctrl+B'
    for ($i = $script:editors.Count - 1; $i -ge 0; $i--) { if (-not $script:editors[$i].IsAlive) { $script:editors.RemoveAt($i) } }
    $script:editors.Add([System.WeakReference]::new($ed))
    Update-WtMemoEditorMode $ed
    $ed
}

# 원문 칸 · 섬 공통: 편집 단축키 · 글자 입력 · 붙여넣기 · 끌어 놓기
function Add-WtMemoBoxHandlers($Box) {
    $Box.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoBoxKey $s $e })
    $Box.Add_PreviewTextInput({ param($s, $e) Invoke-WtMemoBoxText $s $e })
    [System.Windows.DataObject]::AddPastingHandler($Box, [System.Windows.DataObjectPastingEventHandler] { param($s, $e) Invoke-WtMemoBoxPaste $s $e })
    $Box.AllowDrop = $true
    $Box.Add_PreviewDragOver({ param($s, $e) Invoke-WtMemoBoxDragOver $s $e })
    $Box.Add_PreviewDrop({ param($s, $e) Invoke-WtMemoBoxDrop $s $e })
}

function Invoke-WtMemoEditorChanged($Ed) {
    if ($Ed.OnChanged) { & $Ed.OnChanged $Ed }
}

# 마크다운 보기의 링크 처리기. 보기 상태(Tag)의 Editor가 그 편집기다
function Invoke-WtMemoEditorLink($Link, $St) {
    $ed = if ($St -is [hashtable] -and $St.Editor) { $St.Editor } else { Find-WtMemoEditorFrom ([System.Windows.Input.Mouse]::DirectlyOver) }
    if (-not $ed -or -not $ed.OnLink) { return $false }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $how = if (($mods -band 'Control') -and ($mods -band 'Alt')) { 'side' } elseif ($mods -band 'Control') { 'tab' } else { 'here' }
    $r = & $ed.OnLink $ed $Link $how | Select-Object -Last 1
    $r -eq $true
}

# 할 일 체크 표시를 눌렀을 때: 그 줄의 [ ] ↔ [x]. 실시간 모드는 그려 둔 Section을 다시 쓰므로
# 그릴 때의 줄 번호($Line) 대신 누른 요소가 든 단위의 지금 첫 줄을 쓴다(체크 표시는 항목 첫 줄에 있다)
function Invoke-WtMemoTaskClick([int]$Line, $El) {
    $ed = Find-WtMemoEditorFrom $El
    if (-not $ed -or -not $ed.Enabled) { return }
    $target = $Line - 1
    if ($ed.Mode -eq 'live') {
        $sec = $El
        while ($sec -and -not ($sec -is [System.Windows.Documents.Section] -and $sec.Tag -is [hashtable] -and $sec.Tag.ContainsKey('Kind'))) {
            $sec = [System.Windows.LogicalTreeHelper]::GetParent($sec)
        }
        if ($sec) {
            $target = $sec.Tag.Start
            $isl = $ed.Island
            if ($isl -and $sec.Tag.Start -ge $isl.End) { $target += @($ed.IslandBox.Text -split "\r?\n").Count - ($isl.End - $isl.Start) }
        }
    }
    $ed.Busy++
    try {
        if ($ed.Island) { Close-WtMemoIsland $ed }
        if ($target -lt 0 -or $target -ge $ed.Lines.Count) { return }
        $text = $ed.Lines[$target]
        $m = [regex]::Match($text, '^(\s*(?:>\s*)*(?:[-*+]|\d{1,9}[.)])\s+\[)([ xX])\]')
        if (-not $m.Success) { return }
        $mark = if ($m.Groups[2].Value -eq ' ') { 'x' } else { ' ' }
        $next = $text.Substring(0, $m.Groups[2].Index) + $mark + $text.Substring($m.Groups[2].Index + 1)
        if ($ed.Mode -eq 'live') {
            Push-WtMemoUndo $ed
            # 섬을 거쳐 바꾸면 그 둘레만 다시 그린다
            $range = Get-WtMemoUnitRange $ed $target $target
            Open-WtMemoIsland $ed $range[0] $range[1] $target 0
            $box = $ed.IslandBox
            $i = Get-WtMemoIslandIndex $ed $target $m.Groups[2].Index
            $box.Select($i, 1)
            $box.SelectedText = $mark
            Close-WtMemoIsland $ed
            [void]$ed.Live.Focus()
        } else {
            $ed.Lines[$target] = $next
            $ed.ReadText = $null
            Update-WtMemoRead $ed
            Invoke-WtMemoEditorChanged $ed
        }
    } finally { $ed.Busy-- }
}

function Find-WtMemoEditorFrom($El) {
    while ($El) {
        if ($El -is [System.Windows.FrameworkElement] -and $El.Tag -is [hashtable]) {
            if ($El.Tag.ContainsKey('Editor') -and $El.Tag.Editor) { return $El.Tag.Editor }
            if ($El.Tag.ContainsKey('IslandBox')) { return $El.Tag }
        }
        $El = Get-WtMemoParent $El
    }
    $null
}

function Get-WtMemoParent($El) {
    if ($El -is [System.Windows.Media.Visual] -or $El -is [System.Windows.Media.Media3D.Visual3D]) {
        $p = [System.Windows.Media.VisualTreeHelper]::GetParent($El)
        if ($p) { return $p }
    }
    if ($El -is [System.Windows.DependencyObject]) { return [System.Windows.LogicalTreeHelper]::GetParent($El) }
    $null
}

# ---- 글 · 모드 ---------------------------------------------------------------------------------

function Set-WtMemoEditorText($Ed, [AllowEmptyString()][string]$Text) {
    $Text = [string]$Text
    $Ed.Loading = $true
    $Ed.Busy++
    try {
        $Ed.NewLine = if ($Text.Contains("`r`n")) { "`r`n" } elseif ($Text.Contains("`n")) { "`n" } else { "`r`n" }
        Set-WtMemoLines $Ed $Text
        $Ed.Undo.Clear()
        $Ed.Redo.Clear()
        $Ed.Island = $null
        $Ed.Caret = @{ Line = 0; Col = 0 }
        $Ed.ReadText = $null
        switch ($Ed.Mode) {
            'source' { $Ed.Source.Text = $Text; $Ed.Source.CaretIndex = 0; $Ed.Source.ScrollToHome() }
            'live' { Update-WtMemoLive $Ed; Get-WtMemoScroller $Ed.Live | ForEach-Object { $_.ScrollToHome() } }
            'read' { Update-WtMemoRead $Ed }
        }
    } finally { $Ed.Loading = $false; $Ed.Busy-- }
}

function Set-WtMemoLines($Ed, [string]$Text) {
    $Ed.Lines.Clear()
    foreach ($l in ($Text -split "\r?\n")) { $Ed.Lines.Add($l) }
}

function Get-WtMemoEditorText($Ed) {
    if ($Ed.Mode -eq 'source') { return [string]$Ed.Source.Text }
    if ($Ed.Island) {
        $isl = $Ed.Island
        $mid = @($Ed.IslandBox.Text -split "\r?\n")
        $before = if ($isl.Start -gt 0) { @($Ed.Lines.GetRange(0, $isl.Start)) } else { @() }
        $after = if ($isl.End -lt $Ed.Lines.Count) { @($Ed.Lines.GetRange($isl.End, $Ed.Lines.Count - $isl.End)) } else { @() }
        return (@($before) + @($mid) + @($after)) -join $Ed.NewLine
    }
    @($Ed.Lines) -join $Ed.NewLine
}

function Set-WtMemoEditorMode($Ed, [ValidateSet('live', 'source', 'read')][string]$Mode) {
    if ($Ed.Mode -eq $Mode) { return }
    $text = Get-WtMemoEditorText $Ed
    $hadFocus = $Ed.Root.IsKeyboardFocusWithin
    $Ed.Busy++
    try {
        if ($Ed.Island) { Close-WtMemoIsland $Ed -NoRender }
        $Ed.Mode = $Mode
        $Ed.Loading = $true
        try {
            Set-WtMemoLines $Ed $text
            if ($Mode -eq 'source') { $Ed.Source.Text = $text }
        } finally { $Ed.Loading = $false }
        Update-WtMemoEditorMode $Ed
    } finally { $Ed.Busy-- }
    if ($hadFocus) { Set-WtMemoEditorFocus $Ed }
}

function Update-WtMemoEditorMode($Ed) {
    switch ($Ed.Mode) {
        'live' { Update-WtMemoLive $Ed }
        'read' { Update-WtMemoRead $Ed }
    }
    $Ed.Source.Visibility = if ($Ed.Mode -eq 'source') { 'Visible' } else { 'Collapsed' }
    $Ed.Live.Visibility = if ($Ed.Mode -eq 'live') { 'Visible' } else { 'Collapsed' }
    $Ed.View.Visibility = if ($Ed.Mode -eq 'read') { 'Visible' } else { 'Collapsed' }
}

function Update-WtMemoRead($Ed) {
    $text = @($Ed.Lines) -join "`n"
    if ($Ed.ReadText -ceq $text -and -not $Ed.View.Tag.Error) { return }
    Set-WtMarkdownText $Ed.View $text
    $Ed.ReadText = $text
}

function Set-WtMemoEditorEnabled($Ed, [bool]$Enabled) {
    $Ed.Enabled = $Enabled
    $Ed.Root.IsEnabled = $Enabled
}

function Set-WtMemoEditorFocus($Ed, [switch]$End) {
    switch ($Ed.Mode) {
        'read' { [void]$Ed.View.Focus() }
        'source' {
            if ($End) { $Ed.Source.CaretIndex = $Ed.Source.Text.Length }
            [void]$Ed.Source.Focus()
        }
        'live' {
            if ($End) {
                $last = $Ed.Lines.Count - 1
                $Ed.Caret = @{ Line = $last; Col = $Ed.Lines[$last].Length }
            }
            if ($Ed.Island) { [void]$Ed.IslandBox.Focus(); return }
            Open-WtMemoIslandAt $Ed $Ed.Caret.Line $Ed.Caret.Col
        }
    }
}

function Get-WtMemoEditorState($Ed) {
    $sv = Get-WtMemoScroller $(if ($Ed.Mode -eq 'live') { $Ed.Live } elseif ($Ed.Mode -eq 'read') { $Ed.View } else { $Ed.Source })
    $caret = if ($Ed.Mode -eq 'source') { $Ed.Source.CaretIndex } else { $null }
    if ($Ed.Mode -eq 'live' -and $Ed.Island) { $Ed.Caret = Get-WtMemoIslandCaret $Ed }
    @{ Caret = $caret; Line = $Ed.Caret.Line; Col = $Ed.Caret.Col; Scroll = $(if ($sv) { $sv.VerticalOffset } else { 0 }) }
}

function Set-WtMemoEditorState($Ed, $State) {
    if (-not $State) { return }
    if ($null -ne $State.Line) {
        $line = [Math]::Max(0, [Math]::Min([int]$State.Line, $Ed.Lines.Count - 1))
        $Ed.Caret = @{ Line = $line; Col = [Math]::Max(0, [Math]::Min([int]$State.Col, $Ed.Lines[$line].Length)) }
    }
    if ($Ed.Mode -eq 'source' -and $null -ne $State.Caret) { $Ed.Source.CaretIndex = [Math]::Min([int]$State.Caret, $Ed.Source.Text.Length) }
    $target = if ($Ed.Mode -eq 'live') { $Ed.Live } elseif ($Ed.Mode -eq 'read') { $Ed.View } else { $Ed.Source }
    $target.UpdateLayout()
    $sv = Get-WtMemoScroller $target
    if ($sv) { $sv.ScrollToVerticalOffset([double]$State.Scroll) }
}

# 텍스트 상자 · 보기 안쪽의 ScrollViewer
function Get-WtMemoScroller($El) {
    if (-not $El) { return $null }
    $El.ApplyTemplate() | Out-Null
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($El)
    while ($queue.Count) {
        $x = $queue.Dequeue()
        if ($x -is [System.Windows.Controls.ScrollViewer]) { return $x }
        $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($x)
        for ($i = 0; $i -lt $n; $i++) { $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($x, $i)) }
    }
    $null
}

# ---- 실시간: 그리기 ----------------------------------------------------------------------------

# 문서의 약속: Blocks = Sections[0 .. Rendered-1] 차례. 단, 섬이 열려 있으면 섬이 덮은 단위(First..Last) 자리에 섬 하나.
# 긴 글은 앞쪽만 바로 그리고 나머지는 입력을 막지 않게 조금씩 뒤에 붙인다(Rendered가 Units.Count까지 자람).
$script:firstPaint = [TimeSpan]::FromMilliseconds(60)   # 처음에 바로 그릴 시간
$script:renderSlice = [TimeSpan]::FromMilliseconds(16)  # 뒤에 붙일 때 한 번에 쓸 시간

# 줄 목록 전체를 단위로 다시 나눠 문서를 새로 꾸린다 (불러오기 · 실행 취소 · 울타리가 어긋났을 때)
function Update-WtMemoLive($Ed) {
    $text = @($Ed.Lines) -join "`n"
    $units = Get-WtMarkdownUnits $text
    Set-WtMemoListIds $Ed $units 0 ($units.Count - 1)
    $Ed.Live.Document.Blocks.Clear()
    $Ed.Units = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $units) { $Ed.Units.Add($u) }
    $Ed.Sections = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $units) { $Ed.Sections.Add($null) }
    $Ed.Rendered = 0
    if ($Ed.Cache.Count -gt 4 * [Math]::Max(64, $units.Count)) { $Ed.Cache.Clear() }
    $deadline = [datetime]::UtcNow + $script:firstPaint
    while ($Ed.Rendered -lt $units.Count -and [datetime]::UtcNow -lt $deadline) { Add-WtMemoNextSection $Ed }
    Start-WtMemoRenderTimer $Ed
}

# 목록 번호(ListId)를 새로 매긴다: 차례로 이어진 목록 항목 단위는 같은 목록. 마지막 항목만 아래 여백(Last).
# From..To를 매기고, To 뒤에도 같은 목록이 이어지면 그 끝까지 번호를 잇는다
function Set-WtMemoListIds($Ed, $Units, [int]$From, [int]$To) {
    $id = 0
    if ($From -gt 0 -and $Units[$From - 1].Kind -eq 'list-item') { $id = $Units[$From - 1].ListId }
    $i = $From
    while ($i -lt $Units.Count -and ($i -le $To -or ($id -and $Units[$i].Kind -eq 'list-item' -and $Units[$i].ListId -ne $id))) {
        $u = $Units[$i]
        if ($u.Kind -ne 'list-item') { $id = 0 }
        else {
            if (-not $id) { $id = $Ed.NextListId; $Ed.NextListId++ }
            $u.ListId = $id
            $u.Last = -not ($i + 1 -lt $Units.Count -and $Units[$i + 1].Kind -eq 'list-item')
        }
        $i++
    }
}

# 단위 하나의 Section. 원문 · 깊이 · 여백이 같은 Section이 쉬고 있으면 다시 쓴다
function Get-WtMemoUnitSection($Ed, $Unit) {
    $key = '{0}|{1}|{2}|{3}' -f $Unit.Kind, $Unit.Depth, $Unit.Last, $Unit.Text
    $sec = $null
    if ($Ed.Cache.TryGetValue($key, [ref]$sec) -and -not $sec.Parent) { $sec.Tag = $Unit; return $sec }
    $sec = New-WtMarkdownUnitSection $Ed.Live $Unit
    $Ed.Cache[$key] = $sec
    # 다이어그램 크기를 다시 재는 것은 편집기가 직접 한다 (보기 공통 처리기가 문서를 통째로 바꾸지 않게)
    $Ed.Live.Tag.Remeasure = $false
    $sec
}

# 아직 안 그린 다음 단위를 문서 끝에 붙인다
function Add-WtMemoNextSection($Ed) {
    $i = $Ed.Rendered
    $sec = Get-WtMemoUnitSection $Ed $Ed.Units[$i]
    $Ed.Sections[$i] = $sec
    $Ed.Live.Document.Blocks.Add($sec)
    $Ed.Rendered = $i + 1
}

# 단위 번호 Index까지는 바로 그린다 (그 자리로 섬을 열 때)
function Complete-WtMemoRender($Ed, [int]$Index) {
    $Index = [Math]::Min($Index, $Ed.Units.Count - 1)
    while ($Ed.Rendered -le $Index) { Add-WtMemoNextSection $Ed }
}

function Start-WtMemoRenderTimer($Ed) {
    if ($Ed.Rendered -ge $Ed.Units.Count) { return }
    if (-not $Ed.RenderTimer) {
        $t = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
        $t.Interval = [TimeSpan]::Zero
        $t.Tag = $Ed
        $t.Add_Tick({
                param($s, $e)
                $ed = $s.Tag
                try {
                    $deadline = [datetime]::UtcNow + $script:renderSlice
                    while ($ed.Rendered -lt $ed.Units.Count -and [datetime]::UtcNow -lt $deadline) { Add-WtMemoNextSection $ed }
                } catch { $s.Stop(); Show-WtError $_ '메모 그리기'; return }
                if ($ed.Rendered -ge $ed.Units.Count) { $s.Stop() }
            })
        $Ed.RenderTimer = $t
    }
    $Ed.RenderTimer.Start()
}

# 줄 번호가 든 단위 번호. 없으면 바로 앞 단위(들어갈 자리), 맨 앞이면 -1
function Find-WtMemoUnitIndex($Ed, [int]$Line) {
    $units = $Ed.Units
    for ($i = 0; $i -lt $units.Count; $i++) {
        if ($Line -lt $units[$i].Start) { return $i - 1 }
        if ($Line -lt $units[$i].End) { return $i }
    }
    $units.Count - 1
}

# ---- 실시간: 섬 --------------------------------------------------------------------------------

# 줄 · 칸 자리에 섬을 연다. 그 줄이 든 단위 전체(빈 줄이면 앞 단위)를 섬으로 바꾼다
function Open-WtMemoIslandAt($Ed, [int]$Line, [int]$Col, [int]$ToLine = -1, [int]$ToCol = -1) {
    # 줄 번호는 섬을 닫은 뒤 기준이다. 먼저 닫아야 단위 목록이 맞는다
    if ($Ed.Island) {
        $Ed.Busy++
        try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    }
    $Line = [Math]::Max(0, [Math]::Min($Line, $Ed.Lines.Count - 1))
    $from = $Line; $to = $Line
    if ($ToLine -ge 0) { $from = [Math]::Min($Line, $ToLine); $to = [Math]::Max($Line, $ToLine) }
    $range = Get-WtMemoUnitRange $Ed $from $to
    Open-WtMemoIsland $Ed $range[0] $range[1] $Line $Col $ToLine $ToCol
}

# [from, to] 줄을 덮는 단위들의 줄 범위 [Start, End)
function Get-WtMemoUnitRange($Ed, [int]$From, [int]$To) {
    $units = $Ed.Units
    if (-not $units.Count) { return @(0, $Ed.Lines.Count) }
    $a = Find-WtMemoUnitIndex $Ed $From
    $b = Find-WtMemoUnitIndex $Ed $To
    if ($a -lt 0) { $a = 0 }
    if ($b -lt 0) { $b = 0 }
    $start = [Math]::Min($units[$a].Start, $From)
    $end = [Math]::Max($units[$b].End, $To + 1)
    # 빈 줄에 섰으면 앞 단위에 붙인다 (빈 줄만 따로 섬이 되지 않게)
    @($start, [Math]::Min($end, $Ed.Lines.Count))
}

function Open-WtMemoIsland($Ed, [int]$Start, [int]$End, [int]$Line, [int]$Col, [int]$ToLine = -1, [int]$ToCol = -1) {
    if ($Ed.Island) { Close-WtMemoIsland $Ed }
    $Ed.Busy++
    try {
        $doc = $Ed.Live.Document
        $units = $Ed.Units
        # 섬이 덮는 단위(First..Last)의 Section을 빼고 그 자리에 섬을 넣는다. 덮는 단위가 없으면 Last = First - 1
        $first = 0
        while ($first -lt $units.Count -and $units[$first].End -le $Start) { $first++ }
        $last = $first - 1
        while ($last + 1 -lt $units.Count -and $units[$last + 1].Start -lt $End) { $last++ }
        Complete-WtMemoRender $Ed ($last + 1)
        $covered = [System.Collections.Generic.List[object]]::new()
        for ($i = $first; $i -le $last; $i++) {
            $covered.Add($units[$i])
            [void]$doc.Blocks.Remove($Ed.Sections[$i])
        }
        $box = $Ed.IslandBox
        $holder = [System.Windows.Documents.BlockUIContainer]::new()
        Set-WtStyle $holder 'Memo.IslandBox'
        Set-WtStyle $box (Get-WtMemoIslandStyle $covered)
        if ($box.Parent) { $box.Parent.Child = $null }
        $holder.Child = $box
        if ($last + 1 -lt $Ed.Rendered) { $doc.Blocks.InsertBefore($Ed.Sections[$last + 1], $holder) } else { $doc.Blocks.Add($holder) }

        $Ed.Loading = $true
        try { $box.Text = (@($Ed.Lines.GetRange($Start, $End - $Start)) -join "`r`n") } finally { $Ed.Loading = $false }
        $Ed.IslandPrev = $box.Text
        $Ed.Island = @{ Start = $Start; End = $End; Holder = $holder; Original = $box.Text; First = $first; Last = $last }
        $Ed.Live.UpdateLayout()
        $caret = Get-WtMemoIslandIndex $Ed $Line $Col
        if ($ToLine -ge 0) {
            $to = Get-WtMemoIslandIndex $Ed $ToLine $ToCol
            Select-WtMemoIslandRange $box $caret $to
        } else {
            $box.Select($caret, 0)
        }
        [void]$box.Focus()
        Show-WtMemoIslandCaret $Ed
    } finally { $Ed.Busy-- }
}

# 선택을 anchor → active 방향으로 (이어서 Shift+화살표를 누르면 active 쪽이 움직이게).
# TextBox.Select는 늘 앞 → 뒤 방향이라, 거꾸로 고를 때는 anchor에 커서를 두고 선택 명령으로 넓힌다
function Select-WtMemoIslandRange($Box, [int]$Anchor, [int]$Active) {
    if ($Active -ge $Anchor) { $Box.Select($Anchor, $Active - $Anchor); return }
    $Box.Select($Anchor, 0)
    $cmds = [System.Windows.Documents.EditingCommands]
    for ($n = 0; $n -lt 100000 -and $Box.SelectionStart -gt $Active; $n++) {
        $was = $Box.SelectionStart
        $cmds::SelectUpByLine.Execute($null, $Box)
        if ($Box.SelectionStart -eq $was) { break }
    }
    for ($n = 0; $n -lt 100000 -and $Box.SelectionStart -gt $Active; $n++) {
        $was = $Box.SelectionStart
        $cmds::SelectLeftByCharacter.Execute($null, $Box)
        if ($Box.SelectionStart -eq $was) { break }
    }
    for ($n = 0; $n -lt 100000 -and $Box.SelectionStart -lt $Active -and $Box.SelectionLength; $n++) {
        $was = $Box.SelectionStart
        $cmds::SelectRightByCharacter.Execute($null, $Box)
        if ($Box.SelectionStart -eq $was) { break }
    }
}

# 섬 글꼴: 제목 하나면 그 단계 크기, 코드 블록 하나면 코드 글꼴, 그 밖에는 본문
function Get-WtMemoIslandStyle($Units) {
    if (@($Units).Count -eq 1) {
        $u = @($Units)[0]
        if ($u.Kind -eq 'heading') {
            $level = if ($u.Text -match '^\s{0,3}(#{1,6})(\s|$)') { $Matches[1].Length } elseif ($u.Text -match '\n\s*=+\s*$') { 1 } else { 2 }
            return "Memo.IslandH$level"
        }
        if ($u.Kind -eq 'code') { return 'Memo.IslandCode' }
    }
    'Memo.Island'
}

# 줄 · 칸 → 섬 글자 위치 (섬 글은 \r\n)
function Get-WtMemoIslandIndex($Ed, [int]$Line, [int]$Col) {
    $isl = $Ed.Island
    $lines = @($Ed.IslandBox.Text -split "\r?\n")
    $rel = [Math]::Max(0, [Math]::Min($Line - $isl.Start, $lines.Count - 1))
    $idx = 0
    for ($i = 0; $i -lt $rel; $i++) { $idx += $lines[$i].Length + 2 }
    $idx + [Math]::Max(0, [Math]::Min($Col, $lines[$rel].Length))
}

# 섬 글자 위치 → 줄 · 칸 (글 전체 기준)
function Get-WtMemoIslandCaret($Ed, [int]$Index = -1) {
    $box = $Ed.IslandBox
    if ($Index -lt 0) { $Index = $box.CaretIndex }
    $before = $box.Text.Substring(0, [Math]::Min($Index, $box.Text.Length))
    $parts = @($before -split "\r?\n")
    @{ Line = $Ed.Island.Start + $parts.Count - 1; Col = $parts[-1].Length }
}

# 섬을 닫는다: 안 고쳤으면 그려 둔 Section을 그 자리에 돌려놓고, 고쳤으면 줄을 되돌려 넣고 그 둘레만 다시 나눠 그린다
function Close-WtMemoIsland($Ed, [switch]$NoRender) {
    $isl = $Ed.Island
    if (-not $isl) { return }
    $box = $Ed.IslandBox
    $Ed.Caret = Get-WtMemoIslandCaret $Ed
    $Ed.Busy++
    try {
        $text = $box.Text
        $doc = $Ed.Live.Document
        $Ed.Island = $null
        # 섬 다음 블록을 기억해 두고 섬을 뺀다 (그 앞에 다시 넣는다)
        $after = $isl.Holder.NextBlock
        [void]$doc.Blocks.Remove($isl.Holder)
        $isl.Holder.Child = $null
        if ($text -ceq $isl.Original) {
            if ($NoRender) { return }
            for ($i = $isl.First; $i -le $isl.Last; $i++) {
                if ($after) { $doc.Blocks.InsertBefore($after, $Ed.Sections[$i]) } else { $doc.Blocks.Add($Ed.Sections[$i]) }
            }
            return
        }
        $new = @($text -split "\r?\n")
        $oldCount = $isl.End - $isl.Start
        $Ed.Lines.RemoveRange($isl.Start, $oldCount)
        $Ed.Lines.InsertRange($isl.Start, [string[]]$new)
        if ($NoRender) { return }
        Update-WtMemoRegion $Ed $isl $new.Count $after
    } finally { $Ed.Busy-- }
}

# 고친 섬 둘레만 다시 나눈다. 목록은 그 목록 전체를, 빈 줄 없이 붙은 이웃 단위도 같이 (글자 하나로 블록 모양이 바뀔 수 있어서).
# 코드 울타리 짝이 바뀌면 아래 전체가 달라지므로 전체를 다시 나눈다
function Update-WtMemoRegion($Ed, $Isl, [int]$NewCount, $After) {
    $units = $Ed.Units
    $delta = $NewCount - ($Isl.End - $Isl.Start)
    $islText = @($Ed.Lines.GetRange($Isl.Start, $NewCount))
    $oldText = $Isl.Original -split "\r?\n"
    $fence = '^\s{0,3}(```|~~~)'
    if ((@($islText | Where-Object { $_ -match $fence }).Count % 2) -ne (@($oldText | Where-Object { $_ -match $fence }).Count % 2) -or -not $units.Count) {
        # 섬 다음 블록부터 끝까지 이미 문서에 있으니 전체를 새로 꾸린다
        Update-WtMemoLive $Ed
        return
    }
    $a = $Isl.First; $b = $Isl.Last
    $rs = $Isl.Start; $re = $Isl.Start + $NewCount
    $listy = '^\s*([-*+]|\d{1,9}[.)])(\s|$)'
    $hasList = @($islText | Where-Object { $_ -match $listy }).Count -gt 0
    for ($i = $a; $i -le $b; $i++) { if ($units[$i].Kind -eq 'list-item') { $hasList = $true } }
    do {
        $grew = $false
        if ($a -gt 0) {
            $p = $units[$a - 1]
            if ($p.End -eq $rs -or ($p.Kind -eq 'list-item' -and $hasList)) {
                $a--; $rs = $p.Start; $grew = $true
                if ($p.Kind -eq 'list-item') { $hasList = $true }
            }
        }
        if ($b + 1 -lt $units.Count) {
            $n = $units[$b + 1]
            if ($n.Start + $delta -eq $re -or ($n.Kind -eq 'list-item' -and $hasList)) {
                Complete-WtMemoRender $Ed ($b + 1)
                $b++; $re = $n.End + $delta; $grew = $true
                if ($n.Kind -eq 'list-item') { $hasList = $true }
            }
        }
    } while ($grew)
    $rs = [Math]::Min($rs, $Isl.Start)
    $re = [Math]::Max($re, $Isl.Start + $NewCount)

    $doc = $Ed.Live.Document
    # 다시 나눌 단위의 Section 빼기 (섬이 덮었던 First..Last는 이미 빠져 있음)
    for ($i = $a; $i -le $b; $i++) {
        if ($i -ge $Isl.First -and $i -le $Isl.Last) { continue }
        $sec = $Ed.Sections[$i]
        if ($sec -and $sec.Parent) {
            if ($After -eq $sec) { $After = $sec.NextBlock }
            [void]$doc.Blocks.Remove($sec)
        }
    }
    for ($i = $b + 1; $i -lt $units.Count; $i++) { $units[$i].Start += $delta; $units[$i].End += $delta }
    $region = @($Ed.Lines.GetRange($rs, $re - $rs)) -join "`n"
    $fresh = Get-WtMarkdownUnits $region -LineOffset $rs   # 배열 하나로 돌려준다 (@()로 다시 감싸지 않는다)
    if ($null -eq $fresh) { $fresh = @() }
    $removed = $b - $a + 1
    $wasRendered = $b -lt $Ed.Rendered
    $units.RemoveRange($a, $removed)
    $Ed.Sections.RemoveRange($a, $removed)
    $units.InsertRange($a, [object[]]$fresh)
    $Ed.Sections.InsertRange($a, [object[]]::new($fresh.Count))
    if ($wasRendered) { $Ed.Rendered += $fresh.Count - $removed } else { $Ed.Rendered = [Math]::Min($Ed.Rendered, $a) }
    # 목록 번호 · 마지막 표시를 앞뒤 하나씩 넓혀 다시 매긴다. 이웃의 여백이 바뀌면 다시 그린다
    $from = [Math]::Max(0, $a - 1); $to = [Math]::Min($units.Count - 1, $a + $fresh.Count)
    $before = @(for ($i = $from; $i -le $to; $i++) { $units[$i].Last })
    Set-WtMemoListIds $Ed $units $from $to
    if ($wasRendered) {
        for ($k = 0; $k -lt $fresh.Count; $k++) {
            $sec = Get-WtMemoUnitSection $Ed $fresh[$k]
            $Ed.Sections[$a + $k] = $sec
            if ($After) { $doc.Blocks.InsertBefore($After, $sec) } else { $doc.Blocks.Add($sec) }
        }
        foreach ($i in @($from, $to)) {
            if ($i -ge $a -and $i -lt $a + $fresh.Count) { continue }
            if ($i -ge $Ed.Rendered -or $units[$i].Last -eq $before[$i - $from]) { continue }
            $old = $Ed.Sections[$i]
            $sec = Get-WtMemoUnitSection $Ed $units[$i]
            $doc.Blocks.InsertBefore($old, $sec)
            [void]$doc.Blocks.Remove($old)
            $Ed.Sections[$i] = $sec
        }
    }
    Start-WtMemoRenderTimer $Ed
}

function Show-WtMemoIslandCaret($Ed) {
    $box = $Ed.IslandBox
    try {
        $r = $box.GetRectFromCharacterIndex($box.CaretIndex)
        if (-not $r.IsEmpty) { $box.BringIntoView([System.Windows.Rect]::new($r.X, $r.Y - 8, [Math]::Max(1, $r.Width), $r.Height + 16)) }
    } catch { }
}

# 섬 안의 휠: TextBox가 휠을 삼키므로 바깥 보기를 직접 굴린다
function Invoke-WtMemoIslandWheel($S, $E) {
    $ed = $S.Tag
    $sv = Get-WtMemoScroller $ed.Live
    if (-not $sv) { return }
    $E.Handled = $true
    $sv.ScrollToVerticalOffset($sv.VerticalOffset - $E.Delta / 120 * 48)
}

# 섬 위아래 단위로 옮긴다. Up이면 앞 단위의 마지막 줄, 아니면 다음 단위의 첫 줄. 칸은 지금 칸을 지킨다
function Move-WtMemoIsland($Ed, [ValidateSet('Up', 'Down', 'Left', 'Right', 'Home', 'End')][string]$Dir, [switch]$Extend) {
    $box = $Ed.IslandBox
    $isl = $Ed.Island
    $caret = Get-WtMemoIslandCaret $Ed
    $islLines = @($box.Text -split "\r?\n").Count
    $start = $isl.Start
    $end = $start + $islLines
    if ($Extend) {
        # 선택을 넓힌다: 섬을 옆 단위까지 키우고, 고정된 끝(anchor)에서 옆 단위의 같은 칸까지 고른다
        $selStart = $box.SelectionStart
        $selEnd = $selStart + $box.SelectionLength
        $anchor = Get-WtMemoIslandCaret $Ed $(if ($Dir -eq 'Up') { $selEnd } else { $selStart })
        $active = Get-WtMemoIslandCaret $Ed $(if ($Dir -eq 'Up') { $selStart } else { $selEnd })
        $Ed.Busy++
        try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
        $units = $Ed.Units
        $side = if ($Dir -eq 'Up') { @($units | Where-Object { $_.End -le $start }) | Select-Object -Last 1 }
        else { @($units | Where-Object { $_.Start -ge $end }) | Select-Object -First 1 }
        if (-not $side) {
            # 더 갈 단위가 없으면 글 처음 · 끝까지
            $toLine = if ($Dir -eq 'Up') { $start } else { $end - 1 }
            $toCol = if ($Dir -eq 'Up') { 0 } else { $Ed.Lines[$toLine].Length }
            Open-WtMemoIsland $Ed $start $end $anchor.Line $anchor.Col $toLine $toCol
            return $true
        }
        $toLine = if ($Dir -eq 'Up') { $side.End - 1 } else { $side.Start }
        $range = Get-WtMemoUnitRange $Ed ([Math]::Min($start, $side.Start)) ([Math]::Max($end - 1, $side.End - 1))
        Open-WtMemoIsland $Ed $range[0] $range[1] $anchor.Line $anchor.Col $toLine $active.Col
        return $true
    }
    $Ed.Busy++
    try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    $units = $Ed.Units
    if (-not $units.Count) { Open-WtMemoIslandAt $Ed 0 0; return $true }
    switch ($Dir) {
        'Up' {
            $prev = @($units | Where-Object { $_.End -le $start }) | Select-Object -Last 1
            if (-not $prev) { Open-WtMemoIslandAt $Ed $start 0; return $true }
            Open-WtMemoIsland $Ed $prev.Start $prev.End ($prev.End - 1) $caret.Col
        }
        'Down' {
            $next = @($units | Where-Object { $_.Start -ge $end }) | Select-Object -First 1
            if (-not $next) { $l = $end - 1; Open-WtMemoIslandAt $Ed $l $Ed.Lines[$l].Length; return $true }
            Open-WtMemoIsland $Ed $next.Start $next.End $next.Start $caret.Col
        }
        'Left' {
            $prev = @($units | Where-Object { $_.End -le $start }) | Select-Object -Last 1
            if (-not $prev) { Open-WtMemoIslandAt $Ed $start 0; return $true }
            Open-WtMemoIsland $Ed $prev.Start $prev.End ($prev.End - 1) $Ed.Lines[$prev.End - 1].Length
        }
        'Right' {
            $next = @($units | Where-Object { $_.Start -ge $end }) | Select-Object -First 1
            if (-not $next) { $l = $end - 1; Open-WtMemoIslandAt $Ed $l $Ed.Lines[$l].Length; return $true }
            Open-WtMemoIsland $Ed $next.Start $next.End $next.Start 0
        }
        'Home' { $u = $units[0]; Open-WtMemoIsland $Ed $u.Start $u.End $u.Start 0 }
        'End' { $u = $units[$units.Count - 1]; Complete-WtMemoRender $Ed ($units.Count - 1); Open-WtMemoIsland $Ed $u.Start $u.End ($u.End - 1) $Ed.Lines[$u.End - 1].Length }
    }
    $true
}

# 섬을 앞(또는 뒤) 단위까지 넓히고 커서는 그대로 둔다 (지우기로 블록을 이을 때)
function Join-WtMemoIsland($Ed, [switch]$Next) {
    $isl = $Ed.Island
    $box = $Ed.IslandBox
    $caret = Get-WtMemoIslandCaret $Ed
    $islEnd = $isl.Start + @($box.Text -split "\r?\n").Count
    $Ed.Busy++
    try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    if ($Next) {
        $n = @($Ed.Units | Where-Object { $_.Start -ge $islEnd }) | Select-Object -First 1
        $endLine = if ($n) { $n.End } else { $Ed.Lines.Count }
        $range = Get-WtMemoUnitRange $Ed $caret.Line ([Math]::Max($caret.Line, $endLine - 1))
    } else {
        $p = @($Ed.Units | Where-Object { $_.End -le $caret.Line }) | Select-Object -Last 1
        $from = if ($p) { $p.Start } else { 0 }
        $range = Get-WtMemoUnitRange $Ed $from $caret.Line
    }
    Open-WtMemoIsland $Ed $range[0] $range[1] $caret.Line $caret.Col
}

# ---- 실시간: 키 -------------------------------------------------------------------------------

function Invoke-WtMemoIslandKey($S, $E) {
    $ed = $S.Tag
    if (-not $ed.Island -or $E.Handled) { return }
    $key = if ($E.Key -eq 'System') { $E.SystemKey } else { $E.Key }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band 'Control') -ne 0
    $shift = ($mods -band 'Shift') -ne 0
    $alt = ($mods -band 'Alt') -ne 0
    $box = $S
    $len = $box.Text.Length
    $caret = $box.CaretIndex
    $noSel = $box.SelectionLength -eq 0
    try {
        switch ($key) {
            'Up' {
                if ($alt -or $ctrl) { return }
                $first = $box.GetLineIndexFromCharacterIndex($caret) -le 0
                if ($first) { $E.Handled = Move-WtMemoIsland $ed Up -Extend:$shift }
            }
            'Down' {
                if ($alt -or $ctrl) { return }
                $lastLine = $box.LineCount - 1
                $last = $lastLine -lt 0 -or $box.GetLineIndexFromCharacterIndex($caret + $(if ($shift) { $box.SelectionLength } else { 0 })) -ge $lastLine
                if ($last) { $E.Handled = Move-WtMemoIsland $ed Down -Extend:$shift }
            }
            'Left' { if (-not $shift -and -not $ctrl -and $noSel -and $caret -eq 0) { $E.Handled = Move-WtMemoIsland $ed Left } }
            'Right' { if (-not $shift -and -not $ctrl -and $noSel -and $caret -eq $len) { $E.Handled = Move-WtMemoIsland $ed Right } }
            'Home' { if ($ctrl -and -not $shift) { $E.Handled = Move-WtMemoIsland $ed Home } }
            'End' { if ($ctrl -and -not $shift) { $E.Handled = Move-WtMemoIsland $ed End } }
            'PageUp' { $E.Handled = Move-WtMemoIslandPage $ed -1 }
            'PageDown' { $E.Handled = Move-WtMemoIslandPage $ed 1 }
            'Back' {
                if ($noSel -and $caret -eq 0 -and -not $ctrl -and $ed.Island.Start -gt 0) {
                    Push-WtMemoUndo $ed
                    Join-WtMemoIsland $ed
                    # 이은 자리에서 지우기를 한 번 한다
                    $b = $ed.IslandBox
                    $i = $b.CaretIndex
                    if ($i -gt 0) {
                        $cut = if ($i -ge 2 -and $b.Text.Substring($i - 2, 2) -eq "`r`n") { 2 } else { 1 }
                        $b.Select($i - $cut, $cut)
                        $b.SelectedText = ''
                        $b.Select($i - $cut, 0)
                    }
                    $E.Handled = $true
                }
            }
            'Delete' {
                $islEnd = $ed.Island.Start + @($box.Text -split "\r?\n").Count
                if ($noSel -and $caret -eq $len -and -not $ctrl -and $islEnd -lt $ed.Lines.Count) {
                    Push-WtMemoUndo $ed
                    Join-WtMemoIsland $ed -Next
                    $b = $ed.IslandBox
                    $i = $b.CaretIndex
                    if ($i -lt $b.Text.Length) {
                        $cut = if ($b.Text.Length - $i -ge 2 -and $b.Text.Substring($i, 2) -eq "`r`n") { 2 } else { 1 }
                        $b.Select($i, $cut)
                        $b.SelectedText = ''
                        $b.Select($i, 0)
                    }
                    $E.Handled = $true
                }
            }
            'A' {
                if ($ctrl -and -not $shift -and -not $alt) {
                    # 모두 선택: 섬을 글 전체로 넓힌다
                    $ed.Busy++
                    try { Close-WtMemoIsland $ed } finally { $ed.Busy-- }
                    $last = $ed.Lines.Count - 1
                    Open-WtMemoIsland $ed 0 $ed.Lines.Count 0 0 $last $ed.Lines[$last].Length
                    $E.Handled = $true
                }
            }
            'Z' { if ($ctrl -and -not $alt) { if ($shift) { Invoke-WtMemoRedo $ed } else { Invoke-WtMemoUndo $ed }; $E.Handled = $true } }
            'Y' { if ($ctrl -and -not $alt -and -not $shift) { Invoke-WtMemoRedo $ed; $E.Handled = $true } }
        }
    } catch { Show-WtError $_ '메모 편집' }
}

# PageUp/PageDown: 바깥 보기를 한 화면 굴리고 그 자리 단위로 섬을 옮긴다
function Move-WtMemoIslandPage($Ed, [int]$Dir) {
    $sv = Get-WtMemoScroller $Ed.Live
    if (-not $sv) { return $false }
    $box = $Ed.IslandBox
    $r = $box.GetRectFromCharacterIndex($box.CaretIndex)
    $pt = $box.TranslatePoint([System.Windows.Point]::new($r.X, $r.Y + $r.Height / 2), $Ed.Live)
    $sv.ScrollToVerticalOffset($sv.VerticalOffset + $Dir * $sv.ViewportHeight)
    $Ed.Live.UpdateLayout()
    $y = $pt.Y
    $Ed.Busy++
    try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    $Ed.Live.UpdateLayout()
    $hit = Find-WtMemoLiveHit $Ed ([System.Windows.Point]::new($pt.X, $y))
    if ($hit) { Open-WtMemoIslandAt $Ed $hit.Line $hit.Col }
    else { Open-WtMemoIslandAt $Ed $Ed.Caret.Line $Ed.Caret.Col }
    $true
}

# ---- 실시간: 마우스 ---------------------------------------------------------------------------

# 보기 좌표 → 원문 줄 · 칸. 그린 글자를 원문과 차례로 맞춰 본다 (기호 · 아이콘은 건너뜀)
function Find-WtMemoLiveHit($Ed, [System.Windows.Point]$Point) {
    $view = $Ed.Live
    $tp = $view.GetPositionFromPoint($Point, $true)
    if (-not $tp) { return $null }
    $sec = $tp.Parent
    while ($sec -and -not ($sec -is [System.Windows.Documents.Section] -and $sec.Tag -is [hashtable] -and $sec.Tag.ContainsKey('Kind'))) {
        $sec = [System.Windows.LogicalTreeHelper]::GetParent($sec)
    }
    if (-not $sec) { return $null }
    $u = $sec.Tag
    $rendered = ''
    try { $rendered = [System.Windows.Documents.TextRange]::new($sec.ContentStart, $tp).Text } catch { }
    $offset = Get-WtMemoSourceOffset $rendered $u.Text
    $parts = @($u.Text.Substring(0, $offset) -split "`n")
    $line = $u.Start + $parts.Count - 1
    # 섬에서 줄 수가 바뀌었으면 섬 아래 단위의 줄 번호를 그만큼 옮긴다 (섬을 닫기 전 번호라서)
    $isl = $Ed.Island
    if ($isl -and $u.Start -ge $isl.End) { $line += @($Ed.IslandBox.Text -split "\r?\n").Count - ($isl.End - $isl.Start) }
    @{ Line = $line; Col = $parts[-1].Length; Unit = $u }
}

function Get-WtMemoSourceOffset([string]$Rendered, [string]$Source) {
    $j = 0
    foreach ($c in $Rendered.ToCharArray()) {
        if ([char]::IsWhiteSpace($c) -or ([int]$c -ge 0xE000 -and [int]$c -le 0xF8FF)) { continue }
        $k = $Source.IndexOf($c, $j)
        if ($k -lt 0 -or $k - $j -gt 400) { continue }
        $j = $k + 1
    }
    # 기호 바로 뒤에서 멈췄으면(예: 제목 '# ' 뒤 · 목록 '- ' 뒤) 글자 앞에 둔다
    $j
}

function Test-WtMemoClickThrough($El, $Stop) {
    while ($El -and $El -ne $Stop) {
        if ($El -is [System.Windows.Controls.Primitives.ButtonBase] -or $El -is [System.Windows.Documents.Hyperlink] -or
            $El -is [System.Windows.Controls.Primitives.ScrollBar] -or $El -is [System.Windows.Controls.TextBox]) { return $true }
        $El = Get-WtMemoParent $El
    }
    $false
}

function Invoke-WtMemoLiveMouseDown($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or $ed.Mode -ne 'live' -or -not $ed.Enabled) { return }
    if (Test-WtMemoClickThrough $E.OriginalSource $S) { return }
    try {
        $pt = $E.GetPosition($S)
        $hit = Find-WtMemoLiveHit $ed $pt
        $shift = ([System.Windows.Input.Keyboard]::Modifiers -band 'Shift') -ne 0
        if ($shift -and $ed.Island) {
            $anchor = Get-WtMemoIslandCaret $ed $ed.IslandBox.SelectionStart
            if ($hit) { Open-WtMemoIslandAt $ed $anchor.Line $anchor.Col $hit.Line $hit.Col }
            $E.Handled = $true
            return
        }
        if (-not $hit) {
            # 글 아래 빈 곳: 끝으로
            $last = $ed.Lines.Count - 1
            $hit = @{ Line = $last; Col = $ed.Lines[$last].Length }
        }
        Open-WtMemoIslandAt $ed $hit.Line $hit.Col
        $ed.Drag = @{ Line = $hit.Line; Col = $hit.Col }
        [void]$S.CaptureMouse()
        $E.Handled = $true
    } catch { Show-WtError $_ '메모 편집' }
}

function Invoke-WtMemoLiveMouseMove($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or -not $ed.Drag -or $E.LeftButton -ne 'Pressed' -or -not $ed.Island) { return }
    $box = $ed.IslandBox
    $p = $E.GetPosition($box)
    $anchor = $ed.Drag
    if ($p.Y -ge 0 -and $p.Y -le $box.ActualHeight) {
        $i = $box.GetCharacterIndexFromPoint($p, $true)
        if ($i -ge 0) {
            $a = Get-WtMemoIslandIndex $ed $anchor.Line $anchor.Col
            Select-WtMemoIslandRange $box $a $i
        }
        return
    }
    # 섬 밖으로 끌면 그 단위까지 섬을 넓힌다
    $hit = Find-WtMemoLiveHit $ed ($E.GetPosition($S))
    if ($hit) { Open-WtMemoIslandAt $ed $anchor.Line $anchor.Col $hit.Line $hit.Col }
}

function Invoke-WtMemoLiveMouseUp($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or -not $ed.Drag) { return }
    $ed.Drag = $null
    $S.ReleaseMouseCapture()
    if ($ed.Island) { [void]$ed.IslandBox.Focus() }
}

# ---- 실행 취소 (실시간 모드) ------------------------------------------------------------------

# $IslandText: 섬 글을 이것으로 보고 찍는다(고치기 전 글). 없으면 지금 글. [string]으로 받으면 $null이 ''가 되므로 형을 두지 않는다
function Get-WtMemoSnapshot($Ed, $IslandText = $null) {
    $caret = if ($Ed.Island) { Get-WtMemoIslandCaret $Ed } else { $Ed.Caret }
    $text = if ($Ed.Island -and $null -ne $IslandText) {
        $isl = $Ed.Island
        $before = if ($isl.Start -gt 0) { @($Ed.Lines.GetRange(0, $isl.Start)) } else { @() }
        $after = if ($isl.End -lt $Ed.Lines.Count) { @($Ed.Lines.GetRange($isl.End, $Ed.Lines.Count - $isl.End)) } else { @() }
        (@($before) + @($IslandText -split "\r?\n") + @($after)) -join "`n"
    } else { (Get-WtMemoEditorText $Ed).Replace("`r`n", "`n") }
    @{ Text = $text; Line = $caret.Line; Col = $caret.Col }
}

# 명령(굵게 · 붙여넣기 · 블록 잇기 …) 전에 지금 상태를 남긴다
function Push-WtMemoUndo($Ed) {
    if ($Ed.Mode -ne 'live') { return }
    Add-WtMemoUndoEntry $Ed (Get-WtMemoSnapshot $Ed)
    $Ed.LastEdit = [datetime]::MinValue
}

# 글자를 칠 때: 쉬었다 다시 치기 시작하면 고치기 전 상태를 남긴다
function Add-WtMemoTypingUndo($Ed) {
    $now = [datetime]::UtcNow
    if ($now - $Ed.LastEdit -gt $script:undoPause) { Add-WtMemoUndoEntry $Ed (Get-WtMemoSnapshot $Ed $Ed.IslandPrev) }
    $Ed.LastEdit = $now
}

function Add-WtMemoUndoEntry($Ed, $Snap) {
    if ($Ed.Undo.Count -and $Ed.Undo[$Ed.Undo.Count - 1].Text -ceq $Snap.Text) { return }
    $Ed.Undo.Add($Snap)
    if ($Ed.Undo.Count -gt $script:undoLimit) { $Ed.Undo.RemoveAt(0) }
    $Ed.Redo.Clear()
}

function Invoke-WtMemoUndo($Ed) { Restore-WtMemoSnapshot $Ed $Ed.Undo $Ed.Redo }
function Invoke-WtMemoRedo($Ed) { Restore-WtMemoSnapshot $Ed $Ed.Redo $Ed.Undo }

function Restore-WtMemoSnapshot($Ed, $From, $To) {
    $current = Get-WtMemoSnapshot $Ed
    $snap = $null
    while ($From.Count) {
        $snap = $From[$From.Count - 1]
        $From.RemoveAt($From.Count - 1)
        if ($snap.Text -cne $current.Text) { break }
        $snap = $null
    }
    if (-not $snap) { return }
    $To.Add($current)
    $Ed.Busy++
    try {
        $Ed.Island = $null
        $Ed.Loading = $true
        try { Set-WtMemoLines $Ed $snap.Text } finally { $Ed.Loading = $false }
        Update-WtMemoLive $Ed
    } finally { $Ed.Busy-- }
    $Ed.LastEdit = [datetime]::MinValue
    Open-WtMemoIslandAt $Ed $snap.Line $snap.Col
    Invoke-WtMemoEditorChanged $Ed
}

# ---- 원문 칸 · 섬 공통: 편집 명령 ----------------------------------------------------------------

function Get-WtMemoBoxState($Box) { @{ Text = $Box.Text; Start = $Box.SelectionStart; Length = $Box.SelectionLength } }

# MemoText.psm1의 편집 하나를 상자에 넣는다. 실행 취소 한 단위가 되게 한 번에 바꾼다
function Invoke-WtMemoBoxEdit($Box, $Edit) {
    if (-not $Edit) { return $false }
    $ed = $Box.Tag
    if ($Box -eq $ed.IslandBox) { Push-WtMemoUndo $ed }
    $Box.Select($Edit.Start, $Edit.Length)
    $Box.SelectedText = [string]$Edit.Insert
    $Box.Select([int]$Edit.SelStart, [int]$Edit.SelLength)
    if ($Box -eq $ed.IslandBox) { $ed.LastEdit = [datetime]::MinValue }
    $true
}

function Invoke-WtMemoBoxKey($S, $E) {
    if ($E.Handled) { return }
    $ed = $S.Tag
    $key = if ($E.Key -eq 'System') { $E.SystemKey } else { $E.Key }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band 'Control') -ne 0
    $shift = ($mods -band 'Shift') -ne 0
    $alt = ($mods -band 'Alt') -ne 0
    $edit = $null
    $handled = $false
    try {
        $st = Get-WtMemoBoxState $S
        if ($ctrl -and -not $alt) {
            switch ($key) {
                'B' { if (-not $shift) { $edit = Get-WtMemoWrapEdit $st '**'; $handled = $true } }
                'I' { if (-not $shift) { $edit = Get-WtMemoWrapEdit $st '*'; $handled = $true } }
                'K' { if (-not $shift) { $edit = Get-WtMemoLinkEdit $st; $handled = $true } }
                'L' { if (-not $shift) { $edit = Get-WtMemoTaskEdit $st; $handled = $true } }
                'Oem3' { if ($shift) { $edit = Get-WtMemoWrapEdit $st '`'; $handled = $true } }
                'V' { if ($shift) { Invoke-WtMemoPlainPaste $S; $handled = $true } }
            }
        } elseif ($alt -and -not $ctrl) {
            switch ($key) {
                'Up' { if (-not $shift) { $S = Expand-WtMemoIslandFor $S 'Up'; $edit = Get-WtMemoMoveLinesEdit (Get-WtMemoBoxState $S) -Up; $handled = $true } }
                'Down' { if (-not $shift) { $S = Expand-WtMemoIslandFor $S 'Down'; $edit = Get-WtMemoMoveLinesEdit (Get-WtMemoBoxState $S); $handled = $true } }
                'D5' { if ($shift) { $edit = Get-WtMemoWrapEdit $st '~~'; $handled = $true } }
            }
        } elseif (-not $ctrl -and -not $alt) {
            switch ($key) {
                'Return' { if (-not $shift) { $edit = Get-WtMemoEnterEdit $st; $handled = [bool]$edit } }
                'Tab' {
                    $S = Expand-WtMemoIslandFor $S 'List'
                    $edit = Get-WtMemoIndentEdit (Get-WtMemoBoxState $S) -Outdent:$shift
                    $handled = [bool]$edit -or $shift
                }
            }
        }
        if ($handled) {
            $E.Handled = $true
            [void](Invoke-WtMemoBoxEdit $S $edit)
        }
    } catch { Show-WtError $_ '메모 편집' }
}

# 실시간 모드에서 목록 들여쓰기 · 줄 옮기기는 옆 줄이 필요하다. 섬을 그 목록(또는 옆 단위)까지 넓히고 섬 상자를 돌려준다
function Expand-WtMemoIslandFor($Box, [string]$For) {
    $ed = $Box.Tag
    if ($Box -ne $ed.IslandBox -or -not $ed.Island) { return $Box }
    $isl = $ed.Island
    $hasList = @($ed.Units | Where-Object { $_.Kind -eq 'list-item' -and $_.Start -lt $isl.End -and $_.End -gt $isl.Start }).Count
    if ($For -eq 'List' -and -not $hasList) { return $Box }
    $sel = Get-WtMemoIslandCaret $ed $Box.SelectionStart
    $selEnd = Get-WtMemoIslandCaret $ed ($Box.SelectionStart + $Box.SelectionLength)
    $islEnd = $isl.Start + @($Box.Text -split "\r?\n").Count
    $ed.Busy++
    try { Close-WtMemoIsland $ed } finally { $ed.Busy-- }
    $units = $ed.Units
    $from = $isl.Start; $to = $islEnd - 1
    switch ($For) {
        'Up' { $p = @($units | Where-Object { $_.End -le $isl.Start }) | Select-Object -Last 1; if ($p) { $from = $p.Start } }
        'Down' { $n = @($units | Where-Object { $_.Start -ge $islEnd }) | Select-Object -First 1; if ($n) { $to = $n.End - 1 } }
        'List' {
            $mine = @($units | Where-Object { $_.Start -lt $islEnd -and $_.End -gt $isl.Start -and $_.Kind -eq 'list-item' })
            if ($mine.Count) {
                $id = $mine[0].ListId
                $same = @($units | Where-Object { $_.Kind -eq 'list-item' -and $_.ListId -eq $id })
                $from = [Math]::Min($from, ($same | Measure-Object -Property Start -Minimum).Minimum)
                $to = [Math]::Max($to, ($same | Measure-Object -Property End -Maximum).Maximum - 1)
            }
        }
    }
    $range = Get-WtMemoUnitRange $ed $from $to
    Open-WtMemoIsland $ed $range[0] $range[1] $sel.Line $sel.Col $selEnd.Line $selEnd.Col
    $ed.IslandBox
}

function Invoke-WtMemoBoxText($S, $E) {
    if ($E.Handled -or -not $E.Text) { return }
    try {
        $edit = Get-WtMemoTypeEdit (Get-WtMemoBoxState $S) $E.Text
        if ($edit) {
            $E.Handled = $true
            [void](Invoke-WtMemoBoxEdit $S $edit)
        }
    } catch { Show-WtError $_ '메모 편집' }
}

function Invoke-WtMemoBoxPaste($S, $E) {
    try {
        if (-not $E.DataObject.GetDataPresent([System.Windows.DataFormats]::UnicodeText)) { return }
        $clip = [string]$E.DataObject.GetData([System.Windows.DataFormats]::UnicodeText)
        $edit = Get-WtMemoPasteEdit (Get-WtMemoBoxState $S) $clip
        if ($edit) {
            $E.CancelCommand()
            [void](Invoke-WtMemoBoxEdit $S $edit)
        }
    } catch { Show-WtError $_ '붙여넣기' }
}

# Ctrl+Shift+V: 바꾸지 않고 글 그대로 붙여넣기
function Invoke-WtMemoPlainPaste($Box) {
    $clip = $null
    try { $clip = [System.Windows.Clipboard]::GetText() } catch { return }
    if (-not $clip) { return }
    $start = $Box.SelectionStart
    [void](Invoke-WtMemoBoxEdit $Box @{ Start = $start; Length = $Box.SelectionLength; Insert = $clip; SelStart = $start + $clip.Length; SelLength = 0 })
}

function Invoke-WtMemoBoxDragOver($S, $E) {
    if ($E.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $E.Effects = [System.Windows.DragDropEffects]::Link
        $E.Handled = $true
    }
}

# 탐색기에서 끌어 놓은 파일 · 폴더 → 링크
function Invoke-WtMemoBoxDrop($S, $E) {
    if (-not $E.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
    try {
        $paths = @($E.Data.GetData([System.Windows.DataFormats]::FileDrop))
        $i = $S.GetCharacterIndexFromPoint($E.GetPosition($S), $true)
        if ($i -ge 0) { $S.Select($i, 0) }
        $edit = Get-WtMemoDropEdit (Get-WtMemoBoxState $S) ([string[]]$paths)
        [void](Invoke-WtMemoBoxEdit $S $edit)
        $E.Handled = $true
        [void]$S.Focus()
    } catch { Show-WtError $_ '끌어 놓기' }
}

# 글자 크기를 바꾸면 그려 둔 Section(다이어그램 크기 등)을 버리고 다시 그린다
Register-WtSettingHandler {
    param($key, $value)
    if ($key -ne 'ui.fontScale') { return }
    foreach ($w in @($script:editors)) {
        $ed = $w.Target
        if (-not $ed -or $ed.Mode -ne 'live') { continue }
        $ed.Cache.Clear()
        if ($ed.Island) { continue }   # 섬을 닫을 때 다시 그린다
        Update-WtMemoLive $ed
    }
}

Export-ModuleMember -Function New-WtMemoEditor, Set-WtMemoEditorText, Get-WtMemoEditorText, Set-WtMemoEditorMode,
    Set-WtMemoEditorEnabled, Set-WtMemoEditorFocus, Get-WtMemoEditorState, Set-WtMemoEditorState

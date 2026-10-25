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
    # 편집기 = 위 찾기 막대(숨김) + 본문(원문 칸 · 실시간 보기 · 읽기 보기 중 하나만 보임)
    $root = [System.Windows.Controls.DockPanel]::new()
    $root.Tag = $ed
    $ed.Root = $root
    $root.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoEditorKey $s $e })
    $find = New-WtMemoFindBar $ed
    [System.Windows.Controls.DockPanel]::SetDock($find, 'Top')
    [void]$root.Children.Add($find)
    $body = [System.Windows.Controls.Grid]::new()
    [void]$root.Children.Add($body)
    $ed.Body = $body

    # 원문 모드 칸
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Editor'
    $box.Tag = $ed
    $box.IsInactiveSelectionHighlightEnabled = $true   # 찾기 칸에 포커스가 있어도 찾은 곳이 보이게
    $box.Add_TextChanged({
            param($s, $e)
            $ed = $s.Tag
            if ($ed.Loading) { return }
            Invoke-WtMemoEditorChanged $ed
        })
    Add-WtMemoBoxHandlers $box
    [void]$body.Children.Add($box)
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
    $live.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoLiveKey $s $e })
    $live.Cursor = [System.Windows.Input.Cursors]::IBeam
    [void]$body.Children.Add($live)
    $ed.Live = $live
    Set-WtMarkdownText $live ''

    # 읽기 모드 보기 (문서 전체를 한 번에 그림)
    $view = New-WtMarkdownView -Scroll -OnLink { param($link, $st) Invoke-WtMemoEditorLink $link $st } -OnTask { param($line, $el) Invoke-WtMemoTaskClick $line $el }
    $view.Tag.Editor = $ed
    $view.IsInactiveSelectionHighlightEnabled = $true
    [void]$body.Children.Add($view)
    $ed.View = $view

    # 섬: 실시간 모드에서 고치는 단위 자리에 들어가는 원문 입력칸 (하나를 옮겨 가며 쓴다)
    $island = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $island 'Memo.Island'
    $island.Tag = $ed
    $island.IsUndoEnabled = $false
    $island.IsInactiveSelectionHighlightEnabled = $true
    # IsReadOnly는 부모에서 물려받는 속성이다. 섬은 읽기 전용 RichTextBox 안에 들어가므로 직접 끈다
    $island.IsReadOnly = $false
    $island.Add_TextChanged({
            param($s, $e)
            $ed = $s.Tag
            if ($ed.Loading -or -not $ed.Island) { return }
            Add-WtMemoTypingUndo $ed
            $ed.IslandPrev = $s.Text
            Invoke-WtMemoEditorChanged $ed
        })
    Add-WtMemoBoxHandlers $island -Island
    $island.Add_PreviewMouseWheel({ param($s, $e) Invoke-WtMemoIslandWheel $s $e })
    $ed.IslandBox = $island
    # 자동 완성 팝업은 미리 붙여 둔다 (막 붙인 팝업은 그려지기 전까지 열기가 미뤄진다)
    [void](Get-WtMemoSuggestUi $ed)

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

# 원문 칸 · 섬 공통: 편집 단축키 · 글자 입력 · 붙여넣기 · 끌어 놓기 · [[ 자동 완성.
# 키는 자동 완성 → (섬이면) 섬 이동 → 편집 명령 차례로 받는다
function Add-WtMemoBoxHandlers($Box, [switch]$Island) {
    $Box.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoSuggestKey $s $e })
    if ($Island) { $Box.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoIslandKey $s $e }) }
    $Box.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoBoxKey $s $e })
    $Box.Add_TextChanged({ param($s, $e) if (-not $s.Tag.Loading) { Update-WtMemoSuggest $s } })
    $Box.Add_SelectionChanged({ param($s, $e) if ($s.Tag.Suggest -and $s.Tag.Suggest.Popup.IsOpen) { Update-WtMemoSuggest $s } })
    $Box.Add_LostKeyboardFocus({ param($s, $e) Hide-WtMemoSuggest $s.Tag })
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
# 그릴 때의 줄 번호($Line)를 단위가 옮겨 간 만큼(Start - Base) 옮겨 쓴다
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
            $u = $sec.Tag
            $target = $u.Start + ($Line - 1 - $u.Base)
            $isl = $ed.Island
            if ($isl -and $u.Start -ge $isl.End) { $target += @($ed.IslandBox.Text -split "\r?\n").Count - ($isl.End - $isl.Start) }
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
            $ed.LastEdit = [datetime]::MinValue   # 다음에 치는 글은 따로 되돌리게
            [void]$ed.Live.Focus()
        } else {
            # 읽기 보기는 문서를 통째로 다시 그리므로 스크롤 자리를 지킨다
            $sv = Get-WtMemoScroller $ed.View
            $y = if ($sv) { $sv.VerticalOffset } else { 0 }
            $ed.Lines[$target] = $next
            $ed.ReadText = $null
            Update-WtMemoRead $ed
            if ($sv) { $ed.View.UpdateLayout(); $sv.ScrollToVerticalOffset($y) }
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
    # 고치던 칸에 포커스가 있었으면(탭을 바꾸는 단축키 등) 불러온 뒤에도 편집기 안에 둔다
    $hadFocus = $Ed.Root.IsKeyboardFocusWithin -and -not $Ed.Find.Bar.IsKeyboardFocusWithin
    $Ed.Loading = $true
    $Ed.Busy++
    try {
        Hide-WtMemoSuggest $Ed
        $Ed.NewLine = if ($Text.Contains("`r`n")) { "`r`n" } elseif ($Text.Contains("`n") -or $Text.Contains("`r")) { "`n" } else { "`r`n" }
        Set-WtMemoLines $Ed $Text
        $Ed.Undo.Clear()
        $Ed.Redo.Clear()
        $Ed.LastEdit = [datetime]::MinValue   # 불러온 뒤 처음 치는 글은 새 실행 취소 단위
        $Ed.LeftLiveText = $null
        if ($Ed.Island) { $Ed.Island.Holder.Child = $null }
        $Ed.Island = $null
        $Ed.Caret = @{ Line = 0; Col = 0 }
        $Ed.ReadText = $null
        $Ed.Cache.Clear()   # 다른 메모의 그린 블록을 붙잡고 있지 않게
        switch ($Ed.Mode) {
            'source' { $Ed.Source.Text = $Text; $Ed.Source.CaretIndex = 0; $Ed.Source.ScrollToHome() }
            'live' { Update-WtMemoLive $Ed; Get-WtMemoScroller $Ed.Live | ForEach-Object { $_.ScrollToHome() } }
            'read' { Update-WtMemoRead $Ed }
        }
        if ($hadFocus) {
            # 실시간은 보기에 포커스를 두고, 다음 키 입력 때 커서 자리에 섬을 연다 (Set-WtMemoEditorState가 커서를 옮길 수 있게)
            switch ($Ed.Mode) { 'source' { [void]$Ed.Source.Focus() } 'live' { [void]$Ed.Live.Focus() } 'read' { [void]$Ed.View.Focus() } }
        }
    } finally { $Ed.Loading = $false; $Ed.Busy-- }
}

# 줄 나누기는 마크다운 블록 나누기(Get-WtMarkdownUnits)와 같은 규칙: \r\n · \r · \n 모두 줄바꿈
function Set-WtMemoLines($Ed, [string]$Text) {
    $Ed.Lines.Clear()
    foreach ($l in ($Text -split "\r\n|\r|\n")) { $Ed.Lines.Add($l) }
}

function Get-WtMemoEditorText($Ed) {
    # 원문 칸은 Enter가 \r\n을 넣으므로 \n 글이면 줄바꿈이 섞인다. 글의 줄바꿈으로 맞춘다
    if ($Ed.Mode -eq 'source') { return [regex]::Replace([string]$Ed.Source.Text, "\r\n|\r|\n", $Ed.NewLine) }
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
        # 실시간을 떠날 때의 글. 원문 · 읽기에서 고치고 돌아오면 이 글을 실행 취소 기록에 넣는다(그 고친 것만 되돌리게)
        $norm = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        if ($Ed.Mode -eq 'live') { $Ed.LeftLiveText = $norm }
        elseif ($Mode -eq 'live' -and $null -ne $Ed.LeftLiveText -and $Ed.LeftLiveText -cne $norm) {
            Add-WtMemoUndoEntry $Ed @{ Text = $Ed.LeftLiveText; Line = $Ed.Caret.Line; Col = $Ed.Caret.Col }
            $Ed.LastEdit = [datetime]::MinValue
        }
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
                if ($Ed.Island) { $Ed.Busy++; try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- } }
                $last = $Ed.Lines.Count - 1
                $Ed.Caret = @{ Line = $last; Col = $Ed.Lines[$last].Length }
            }
            if ($Ed.Island) { [void]$Ed.IslandBox.Focus(); return }
            Open-WtMemoIslandAt $Ed $Ed.Caret.Line $Ed.Caret.Col
        }
    }
}

# 상태 = @{ Line; Col; Scroll } (커서 줄 · 칸은 0부터, 모드와 상관없이 같은 뜻)
function Get-WtMemoEditorState($Ed) {
    $sv = Get-WtMemoScroller $(if ($Ed.Mode -eq 'live') { $Ed.Live } elseif ($Ed.Mode -eq 'read') { $Ed.View } else { $Ed.Source })
    if ($Ed.Mode -eq 'live' -and $Ed.Island) { $Ed.Caret = Get-WtMemoIslandCaret $Ed }
    if ($Ed.Mode -eq 'source') {
        $b = $Ed.Source
        $parts = @($b.Text.Substring(0, $b.CaretIndex) -split "\r?\n")
        $Ed.Caret = @{ Line = $parts.Count - 1; Col = $parts[$parts.Count - 1].Length }
    }
    @{ Line = $Ed.Caret.Line; Col = $Ed.Caret.Col; Scroll = $(if ($sv) { $sv.VerticalOffset } else { 0 }) }
}

function Set-WtMemoEditorState($Ed, $State) {
    if (-not $State) { return }
    if ($null -ne $State.Line) {
        $lines = if ($Ed.Mode -eq 'source') { @($Ed.Source.Text -split "\r?\n") } else { @($Ed.Lines) }
        $line = [Math]::Max(0, [Math]::Min([int]$State.Line, $lines.Count - 1))
        $Ed.Caret = @{ Line = $line; Col = [Math]::Max(0, [Math]::Min([int]$State.Col, $lines[$line].Length)) }
        if ($Ed.Mode -eq 'source') {
            $nl = if ($Ed.Source.Text.Contains("`r`n")) { 2 } else { 1 }
            $idx = 0
            for ($i = 0; $i -lt $line; $i++) { $idx += $lines[$i].Length + $nl }
            $Ed.Source.CaretIndex = $idx + $Ed.Caret.Col
        }
    }
    $target = if ($Ed.Mode -eq 'live') { $Ed.Live } elseif ($Ed.Mode -eq 'read') { $Ed.View } else { $Ed.Source }
    $scroll = [double]$State.Scroll
    if ($Ed.Mode -eq 'live') {
        # 긴 글은 나눠 그리는 중일 수 있다. 커서 단위까지, 그리고 스크롤할 높이가 생길 때까지 먼저 그린다
        Complete-WtMemoRender $Ed (Find-WtMemoUnitIndex $Ed $Ed.Caret.Line)
        $sv = Get-WtMemoScroller $target
        $target.UpdateLayout()
        while ($sv -and $Ed.Rendered -lt $Ed.Units.Count -and $sv.ExtentHeight -lt $scroll + $sv.ViewportHeight) {
            Complete-WtMemoRender $Ed ($Ed.Rendered + 20)
            $target.UpdateLayout()
        }
        # 포커스가 보기에 있으면(탭을 바꾸며 불러옴) 커서 자리에 섬을 다시 연다
        if ($Ed.Live.IsKeyboardFocused -and -not $Ed.Island) { Open-WtMemoIslandAt $Ed $Ed.Caret.Line $Ed.Caret.Col }
    } else {
        $target.UpdateLayout()
    }
    $sv = Get-WtMemoScroller $target
    if ($sv) { $sv.ScrollToVerticalOffset($scroll) }
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

# 줄 번호가 든 단위 번호. 없으면 바로 앞 단위(들어갈 자리), 맨 앞이면 -1.
# 단위는 Start 차례이고 겹치지 않으므로 둘로 나눠 찾는다 (긴 글에서 키마다 훑지 않게)
function Find-WtMemoUnitIndex($Ed, [int]$Line) {
    Get-WtMemoUnitBefore $Ed ($Line + 1) -Start
}

# Start(-Start) 또는 End가 Line 이하인 마지막 단위 번호. 없으면 -1
function Get-WtMemoUnitBefore($Ed, [int]$Line, [switch]$Start) {
    $units = $Ed.Units
    $lo = 0; $hi = $units.Count - 1; $ans = -1
    while ($lo -le $hi) {
        $mid = [int][Math]::Floor(($lo + $hi) / 2)
        $v = if ($Start) { $units[$mid].Start } else { $units[$mid].End }
        if ($v -le $Line - $(if ($Start) { 1 } else { 0 })) { $ans = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    $ans
}

# Start가 Line 이상인 첫 단위 번호. 없으면 Units.Count
function Get-WtMemoUnitAfter($Ed, [int]$Line) {
    $units = $Ed.Units
    $lo = 0; $hi = $units.Count - 1; $ans = $units.Count
    while ($lo -le $hi) {
        $mid = [int][Math]::Floor(($lo + $hi) / 2)
        if ($units[$mid].Start -ge $Line) { $ans = $mid; $hi = $mid - 1 } else { $lo = $mid + 1 }
    }
    $ans
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
        $first = (Get-WtMemoUnitBefore $Ed $Start) + 1          # End가 Start 이하인 단위 다음
        $last = (Get-WtMemoUnitAfter $Ed $End) - 1              # Start가 End 이상인 단위 앞
        # 단위 일부만 덮으면 나머지 줄이 화면에서 사라지므로 덮는 단위 전체로 넓힌다
        if ($last -ge $first) {
            $Start = [Math]::Min($Start, $units[$first].Start)
            $End = [Math]::Max($End, $units[$last].End)
        }
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
        $caret = Get-WtMemoIslandIndex $Ed $Line $Col
        if ($ToLine -ge 0) {
            $to = Get-WtMemoIslandIndex $Ed $ToLine $ToCol
            # 거꾸로 고르기는 줄 이동 명령을 쓰므로 배치가 끝나 있어야 한다 (앞 → 뒤는 배치 없이 고른다)
            if ($to -lt $caret) { $Ed.Live.UpdateLayout() }
            Select-WtMemoIslandRange $box $caret $to
        } else {
            $box.Select($caret, 0)
        }
        [void]$box.Focus()
        # 커서를 화면 안으로: 배치가 끝난 뒤에 한다 (여기서 배치를 강제하면 블록을 옮길 때마다 느리다)
        $script:caretPending = $Ed
        [void]$box.Dispatcher.BeginInvoke([System.Action] { if ($script:caretPending) { Show-WtMemoIslandCaret $script:caretPending; $script:caretPending = $null } }, [System.Windows.Threading.DispatcherPriority]::Loaded)
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

function Get-WtMemoWideMarks([string]$Text) {
    '{0}|{1}|{2}' -f ([regex]::Matches($Text, '<!--').Count), ([regex]::Matches($Text, '-->').Count), ([regex]::Matches($Text, '(?m)^\s*\$\$').Count)
}

# 고친 섬 둘레만 다시 나눈다. 같이 다시 나누는 이웃(문맥에 따라 모양이 바뀔 수 있어서):
#   빈 줄 없이 붙은 단위, 같은 목록(ListId)의 항목, 들여 쓴 줄로 시작하는 쪽의 앞 단위
# 코드 울타리 줄이 하나라도 바뀌면(짝 · 길이 · 글자) 아래 전체가 달라질 수 있으므로 전체를 다시 나눈다
function Update-WtMemoRegion($Ed, $Isl, [int]$NewCount, $After) {
    $units = $Ed.Units
    $delta = $NewCount - ($Isl.End - $Isl.Start)
    $islText = @($Ed.Lines.GetRange($Isl.Start, $NewCount))
    $oldText = $Isl.Original -split "\r?\n"
    $fence = '^\s{0,3}(```|~~~)'
    $fenceOld = @($oldText | Where-Object { $_ -match $fence } | ForEach-Object { $_.Trim() }) -join "`n"
    $fenceNew = @($islText | Where-Object { $_ -match $fence } | ForEach-Object { $_.Trim() }) -join "`n"
    # 아래 글 전체의 뜻을 바꿀 수 있는 것: HTML 주석 열고 닫기(<!-- -->), 수식 블록($$)
    $wideOld = Get-WtMemoWideMarks ($oldText -join "`n")
    $wideNew = Get-WtMemoWideMarks ($islText -join "`n")
    if ($fenceOld -cne $fenceNew -or $wideOld -cne $wideNew -or -not $units.Count) {
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
            $cur = if ($a -le $b) { $units[$a] } else { $null }
            $sameList = $p.Kind -eq 'list-item' -and $hasList -and (-not $cur -or ($cur.Kind -eq 'list-item' -and $cur.ListId -eq $p.ListId))
            # 영역 첫 글 줄이 들여 써 있으면 앞 단위에 따라 뜻이 바뀐다(목록 이어 쓰기 · 코드)
            $firstText = $null
            for ($l = $rs; $l -lt $re; $l++) { if ($Ed.Lines[$l].Trim()) { $firstText = $Ed.Lines[$l]; break } }
            $indented = $firstText -and $firstText -match '^\s'
            # 목록 표지로 시작하면(빈 항목 '1. ' 등) 앞 글에 따라 목록 · 문단이 갈리므로 앞 단위를 하나 같이 본다
            $listStart = $firstText -and $firstText -match $listy -and $p.Kind -ne 'list-item'
            if ($p.End -eq $rs -or $sameList -or $indented -or $listStart) {
                $a--; $rs = $p.Start; $grew = $true
                if ($p.Kind -eq 'list-item') { $hasList = $true }
            }
        }
        if ($b + 1 -lt $units.Count) {
            $n = $units[$b + 1]
            $cur = if ($a -le $b) { $units[$b] } else { $null }
            $sameList = $n.Kind -eq 'list-item' -and $hasList -and (-not $cur -or ($cur.Kind -eq 'list-item' -and $cur.ListId -eq $n.ListId))
            $nStart = $n.Start + $delta
            $indented = $Ed.Lines[$nStart] -match '^\s'
            if ($nStart -eq $re -or $sameList -or $indented) {
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

# [Start, End) 줄 범위의 앞(Up) · 뒤(Down) 단위. 없으면 $null
function Get-WtMemoNeighbor($Ed, [int]$Start, [int]$End, [string]$Dir) {
    if ($Dir -eq 'Up') {
        $i = Get-WtMemoUnitBefore $Ed $Start
        if ($i -ge 0) { return $Ed.Units[$i] }
        return $null
    }
    $i = Get-WtMemoUnitAfter $Ed $End
    if ($i -lt $Ed.Units.Count) { return $Ed.Units[$i] }
    $null
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
        $side = Get-WtMemoNeighbor $Ed $start $end $Dir
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
            $prev = Get-WtMemoNeighbor $Ed $start $end 'Up'
            if (-not $prev) { Open-WtMemoIslandAt $Ed $start 0; return $true }
            Open-WtMemoIsland $Ed $prev.Start $prev.End ($prev.End - 1) $caret.Col
        }
        'Down' {
            $next = Get-WtMemoNeighbor $Ed $start $end 'Down'
            if (-not $next) { $l = $end - 1; Open-WtMemoIslandAt $Ed $l $Ed.Lines[$l].Length; return $true }
            Open-WtMemoIsland $Ed $next.Start $next.End $next.Start $caret.Col
        }
        'Left' {
            $prev = Get-WtMemoNeighbor $Ed $start $end 'Up'
            if (-not $prev) { Open-WtMemoIslandAt $Ed $start 0; return $true }
            Open-WtMemoIsland $Ed $prev.Start $prev.End ($prev.End - 1) $Ed.Lines[$prev.End - 1].Length
        }
        'Right' {
            $next = Get-WtMemoNeighbor $Ed $start $end 'Down'
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
        $n = Get-WtMemoNeighbor $Ed $isl.Start $islEnd 'Down'
        $endLine = if ($n) { $n.End } else { $Ed.Lines.Count }
        $range = Get-WtMemoUnitRange $Ed $caret.Line ([Math]::Max($caret.Line, $endLine - 1))
    } else {
        $p = Get-WtMemoNeighbor $Ed $caret.Line $caret.Line 'Up'
        $from = if ($p) { $p.Start } else { 0 }
        $range = Get-WtMemoUnitRange $Ed $from $caret.Line
    }
    Open-WtMemoIsland $Ed $range[0] $range[1] $caret.Line $caret.Col
}

# ---- 실시간: 키 -------------------------------------------------------------------------------

# 글자 위치가 든 화면 줄(줄바꿈 포함 · 접힌 줄 기준). 섬을 막 열어 배치 전이면 -1이 나오므로 그때만 배치를 맞춘다
function Get-WtMemoBoxLine($Box, [int]$Index) {
    $l = $Box.GetLineIndexFromCharacterIndex($Index)
    if ($l -lt 0 -or $Box.LineCount -lt 0) { $Box.UpdateLayout(); $l = $Box.GetLineIndexFromCharacterIndex($Index) }
    $l
}

function Invoke-WtMemoIslandKey($S, $E) {
    $ed = $S.Tag
    if (-not $ed.Island -or $E.Handled) { return }
    $key = Get-WtMemoKey $E
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band 'Control') -ne 0
    $shift = ($mods -band 'Shift') -ne 0
    $alt = ($mods -band 'Alt') -ne 0
    $box = $S
    $len = $box.Text.Length
    $caret = $box.CaretIndex
    $noSel = $box.SelectionLength -eq 0
    try {
        # 한글 조합 중에 누른 ↑↓: 입력기가 글자를 확정한 뒤에, 커서가 그대로면(블록 끝이면) 옆 블록으로 간다
        if ($E.Key -eq 'ImeProcessed') {
            if ($key -in 'Up', 'Down' -and -not $ctrl -and -not $alt -and -not $shift) { Add-WtMemoImePending $box $(if ($key -eq 'Up') { 'up' } else { 'down' }) }
            return
        }
        switch ($key) {
            'Up' {
                if ($alt -or $ctrl) { return }
                $first = (Get-WtMemoBoxLine $box $caret) -le 0
                if ($first) { $E.Handled = Move-WtMemoIsland $ed Up -Extend:$shift }
            }
            'Down' {
                if ($alt -or $ctrl) { return }
                $at = Get-WtMemoBoxLine $box ($caret + $(if ($shift) { $box.SelectionLength } else { 0 }))
                $last = $at -ge $box.LineCount - 1
                if ($last) { $E.Handled = Move-WtMemoIsland $ed Down -Extend:$shift }
            }
            'Left' { if (-not $shift -and -not $ctrl -and $noSel -and $caret -eq 0) { $E.Handled = Move-WtMemoIsland $ed Left } }
            'Right' { if (-not $shift -and -not $ctrl -and $noSel -and $caret -eq $len) { $E.Handled = Move-WtMemoIsland $ed Right } }
            'Home' { if ($ctrl -and -not $shift) { $E.Handled = Move-WtMemoIsland $ed Home } }
            'End' { if ($ctrl -and -not $shift) { $E.Handled = Move-WtMemoIsland $ed End } }
            # Key.PageUp · PageDown은 Prior · Next와 같은 값이라 글자로는 Prior · Next로 나온다
            { $_ -in 'Prior', 'PageUp' } { $E.Handled = Move-WtMemoIslandPage $ed -1 }
            { $_ -in 'Next', 'PageDown' } { $E.Handled = Move-WtMemoIslandPage $ed 1 }
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
                # 섬 뒤에 줄이 남아 있을 때만 잇는다 (섬을 닫기 전 번호끼리 비교)
                if ($noSel -and $caret -eq $len -and -not $ctrl -and $ed.Island.End -lt $ed.Lines.Count) {
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
    # 섬을 연 뒤 미뤄 둔 '커서를 화면 안으로'가 아직이면 먼저 한다 (스크롤 자리가 커서 기준이어야 한 화면씩 간다)
    if ($script:caretPending) {
        $Ed.Live.UpdateLayout()
        Show-WtMemoIslandCaret $script:caretPending
        $script:caretPending = $null
        $Ed.Live.UpdateLayout()
    }
    $r = $box.GetRectFromCharacterIndex($box.CaretIndex)
    $pt = $box.TranslatePoint([System.Windows.Point]::new($r.X, $r.Y + $r.Height / 2), $Ed.Live)
    # 아래로 갈 때 아직 안 그린 단위가 있으면 한 화면 넘게 먼저 그린다
    if ($Dir -gt 0) {
        $Ed.Live.UpdateLayout()
        while ($Ed.Rendered -lt $Ed.Units.Count -and $sv.ExtentHeight -lt $sv.VerticalOffset + 2 * $sv.ViewportHeight) {
            Complete-WtMemoRender $Ed ($Ed.Rendered + 20)
            $Ed.Live.UpdateLayout()
        }
    }
    $was = $sv.VerticalOffset
    $sv.ScrollToVerticalOffset($was + $Dir * $sv.ViewportHeight)
    $Ed.Live.UpdateLayout()
    # 한 화면만큼 다 못 갔으면(글 처음 · 끝에 닿음) 처음 · 끝 단위로 간다
    $edge = [Math]::Abs($sv.VerticalOffset - $was) -lt $sv.ViewportHeight - 1
    $Ed.Busy++
    try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    if ($edge -and $Ed.Units.Count) {
        if ($Dir -gt 0) {
            Complete-WtMemoRender $Ed ($Ed.Units.Count - 1)
            $u = $Ed.Units[$Ed.Units.Count - 1]
            Open-WtMemoIsland $Ed $u.Start $u.End ($u.End - 1) $Ed.Lines[$u.End - 1].Length
        } else {
            $u = $Ed.Units[0]
            Open-WtMemoIsland $Ed $u.Start $u.End $u.Start 0
        }
        return $true
    }
    $Ed.Live.UpdateLayout()
    $hit = Find-WtMemoLiveHit $Ed $pt
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
    try { $rendered = Get-WtMemoRenderedPrefix $sec.ContentStart $tp } catch { }
    $offset = Get-WtMemoSourceOffset $rendered $u.Text
    $parts = @($u.Text.Substring(0, $offset) -split "`n")
    $line = $u.Start + $parts.Count - 1
    # 섬에서 줄 수가 바뀌었으면 섬 아래 단위의 줄 번호를 그만큼 옮긴다 (섬을 닫기 전 번호라서)
    $isl = $Ed.Island
    if ($isl -and $u.Start -ge $isl.End) { $line += @($Ed.IslandBox.Text -split "\r?\n").Count - ($isl.End - $isl.Start) }
    @{ Line = $line; Col = $parts[-1].Length; Unit = $u }
}

# 그린 글의 [Start, End) 글자. TextRange.Text는 표 칸에 걸치면 칸 · 행 전체로 넓혀 버려서 직접 따라가며 모은다.
# 문단 · 줄바꿈 · 칸 경계는 공백 문자로 둔다 (원문과 맞출 때 건너뛴다)
function Get-WtMemoRenderedPrefix($Start, $End) {
    $sb = [System.Text.StringBuilder]::new()
    $tp = $Start
    $guard = 0
    while ($tp -and $tp.CompareTo($End) -lt 0 -and $guard -lt 100000) {
        $guard++
        $ctx = $tp.GetPointerContext('Forward')
        if ($ctx -eq 'Text') {
            $run = $tp.GetTextInRun('Forward')
            $left = $tp.GetOffsetToPosition($End)
            if ($left -lt $run.Length) { [void]$sb.Append($run.Substring(0, [Math]::Max(0, $left))); break }
            [void]$sb.Append($run)
            $tp = $tp.GetPositionAtOffset($run.Length)
            continue
        }
        if ($ctx -eq 'ElementEnd' -or $ctx -eq 'EmbeddedElement') { [void]$sb.Append("`n") }
        $tp = $tp.GetNextContextPosition('Forward')
    }
    $sb.ToString()
}

function Get-WtMemoSourceOffset([string]$Rendered, [string]$Source) {
    $j = 0
    foreach ($c in $Rendered.ToCharArray()) {
        if ([char]::IsWhiteSpace($c) -or ([int]$c -ge 0xE000 -and [int]$c -le 0xF8FF)) { continue }
        $k = $Source.IndexOf($c, $j)
        if ($k -lt 0 -or $k - $j -gt 400) { continue }
        $j = $k + 1
    }
    # 그린 글이 공백 · 줄바꿈으로 끝났으면(낱말 사이 · 표 칸 · 다음 줄) 원문의 공백 · 표 칸 기호를 건너 다음 글자 앞에 둔다
    if ($Rendered.Length -and [char]::IsWhiteSpace($Rendered[$Rendered.Length - 1])) {
        while ($j -lt $Source.Length -and $Source[$j] -in ' ', "`t", '|', "`n") { $j++ }
    }
    # 줄 맨 앞이면 제목 · 목록 · 할 일 · 인용 기호 뒤(글자 앞)에 둔다
    if ($j -lt $Source.Length -and ($j -eq 0 -or $Source[$j - 1] -eq "`n")) {
        $m = [regex]::Match($Source.Substring($j), '^\s*(?:>\s?)*(?:#{1,6}\s+|[-*+]\s+(?:\[[ xX]\]\s+)?|\d{1,9}[.)]\s+(?:\[[ xX]\]\s+)?)?')
        $j += $m.Length
    }
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

# 보기 자체에 포커스가 있을 때(섬 없음, 탭을 바꾼 직후 등) 키를 누르면 커서 자리에 섬을 연다.
# 글자 키는 섬이 포커스를 받은 뒤 입력되므로 그대로 들어간다. 이동 키는 섬만 열고 끝낸다
function Invoke-WtMemoLiveKey($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or $ed.Island -or $ed.Mode -ne 'live' -or -not $ed.Enabled -or $E.Handled) { return }
    if (-not $S.IsKeyboardFocused) { return }   # 섬 · 단추 등 안쪽 요소의 키는 그쪽이 처리한다
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    if ($mods -band ([System.Windows.Input.ModifierKeys]::Control -bor [System.Windows.Input.ModifierKeys]::Alt)) { return }
    $key = Get-WtMemoKey $E
    $skip = 'LeftShift', 'RightShift', 'LeftCtrl', 'RightCtrl', 'LeftAlt', 'RightAlt', 'LWin', 'RWin', 'Escape', 'Tab', 'Apps', 'CapsLock', 'HangulMode', 'HanjaMode'
    if ($key -in $skip -or ($key -ge [System.Windows.Input.Key]::F1 -and $key -le [System.Windows.Input.Key]::F24)) { return }
    try {
        Open-WtMemoIslandAt $ed $ed.Caret.Line $ed.Caret.Col
        if ($key -in 'Up', 'Down', 'Left', 'Right', 'Home', 'End', 'PageUp', 'PageDown') { $E.Handled = $true }
    } catch { Show-WtError $_ '메모 편집' }
}

function Invoke-WtMemoLiveMouseMove($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or -not $ed.Drag -or $E.LeftButton -ne 'Pressed' -or -not $ed.Island) { return }
    $box = $ed.IslandBox
    # 막 옮긴 섬은 배치 전이라 글자 위치를 물으면 예외가 난다. 누르면서 마우스를 잡을 때(CaptureMouse) 이동이 바로 오므로
    # 이번 것은 건너뛴다. 다음 이동 전에는 배치가 끝나 있다
    if (-not $box.IsArrangeValid) { return }
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

# 누른 키. Alt 조합은 SystemKey, 한글 조합 중이면(ImeProcessed) 입력기가 받은 원래 키
function Get-WtMemoKey($E) {
    if ($E.Key -eq 'System') { return $E.SystemKey }
    if ($E.Key -eq 'ImeProcessed') { return $E.ImeProcessedKey }
    $E.Key
}

# 커서 줄이 내용 없는 들여 쓴 목록 항목인지 (예: '  - ')
function Test-WtMemoEmptyItem($State) {
    if ($State.Length) { return $false }
    $t = $State.Text
    $i = $State.Start
    $ls = if ($i -gt 0) { $t.LastIndexOf("`n", $i - 1) + 1 } else { 0 }
    $le = $t.IndexOf("`n", $i)
    if ($le -lt 0) { $le = $t.Length }
    $line = $t.Substring($ls, $le - $ls).TrimEnd("`r")
    $line -match '^\s+([-*+]|\d{1,9}[.)])\s*(\[[ xX]\]\s*)?$'
}

# 한글 조합 중에 누른 키는 입력기가 먼저 처리한다. 확정이 끝난 뒤(Background)에 할 일을 남긴다
$script:imePending = $null
function Add-WtMemoImePending($Box, [string]$Kind, $Extra = $null) {
    $script:imePending = @{ Box = $Box; Kind = $Kind; Text = $Box.Text; Caret = $Box.CaretIndex; Extra = $Extra }
    [void]$Box.Dispatcher.BeginInvoke([System.Action] { Complete-WtMemoImePending }, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Complete-WtMemoImePending {
    $p = $script:imePending
    $script:imePending = $null
    if (-not $p) { return }
    $box = $p.Box
    $ed = $box.Tag
    try {
        switch ($p.Kind) {
            'enter' {
                # 입력기가 줄을 바꿨으면(커서 앞이 새 줄바꿈) 그 줄바꿈을 되돌리고 목록 이어 쓰기를 한다. 안 바꿨으면 그대로 둔다
                $i = $box.CaretIndex
                if ($box.SelectionLength -or $i -lt 2 -or $box.Text.Length -le $p.Text.Length -or $box.Text.Substring($i - 2, 2) -ne "`r`n") { return }
                $state = @{ Text = $box.Text.Remove($i - 2, 2); Start = $i - 2; Length = 0 }
                $edit = Get-WtMemoEnterEdit $state
                if (-not $edit) { return }
                $box.Select($i - 2, 2)
                $box.SelectedText = ''
                $box.Select($i - 2, 0)
                [void](Invoke-WtMemoBoxEdit $box $edit)
            }
            { $_ -in 'up', 'down' } {
                # 커서가 그대로 블록 끝에 있으면 옆 블록으로
                if (-not $ed.Island -or $box -ne $ed.IslandBox -or $box.CaretIndex -ne $p.Caret) { return }
                $line = Get-WtMemoBoxLine $box $box.CaretIndex
                if ($p.Kind -eq 'up' -and $line -le 0) { [void](Move-WtMemoIsland $ed Up) }
                if ($p.Kind -eq 'down' -and $line -ge $box.LineCount - 1) { [void](Move-WtMemoIsland $ed Down) }
            }
            'suggest' {
                # 입력기가 넣은 줄바꿈 · 탭을 빼고 고른 제목으로 완성
                $i = $box.CaretIndex
                $cut = 0
                if ($i -ge 2 -and $box.Text.Substring($i - 2, 2) -eq "`r`n") { $cut = 2 } elseif ($i -ge 1 -and $box.Text[$i - 1] -eq "`t") { $cut = 1 }
                if ($cut -and $box.Text.Length -gt $p.Text.Length) { $box.Select($i - $cut, $cut); $box.SelectedText = ''; $box.Select($i - $cut, 0) }
                Complete-WtMemoSuggest $ed ([string]$p.Extra) -Target $box
            }
        }
    } catch { Show-WtError $_ '메모 편집' }
}

function Invoke-WtMemoBoxKey($S, $E) {
    if ($E.Handled) { return }
    $ed = $S.Tag
    $key = Get-WtMemoKey $E
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band 'Control') -ne 0
    $shift = ($mods -band 'Shift') -ne 0
    $alt = ($mods -band 'Alt') -ne 0
    $edit = $null
    $handled = $false
    try {
        # 한글 조합 중 Enter: 입력기가 글자를 확정하고 줄을 바꾼 뒤에 목록 이어 쓰기를 한다 (조합 중에는 글을 건드리지 않는다)
        if ($E.Key -eq 'ImeProcessed') {
            if ($key -eq 'Return' -and -not $ctrl -and -not $alt -and -not $shift) { Add-WtMemoImePending $S 'enter' }
            return
        }
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
                'Return' {
                    if (-not $shift) {
                        # 빈 안쪽 항목에서 Enter(내어쓰기)는 부모 표지를 봐야 하므로 섬을 목록 전체로 넓힌다
                        if (Test-WtMemoEmptyItem $st) { $S = Expand-WtMemoIslandFor $S 'List'; $st = Get-WtMemoBoxState $S }
                        $edit = Get-WtMemoEnterEdit $st
                        $handled = [bool]$edit
                    }
                }
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

# ---- [[ 자동 완성 ------------------------------------------------------------------------------

$script:suggestMax = 30

# 커서 앞이 같은 줄의 닫히지 않은 [[ 이면 @{ Start = 찾는 글 시작; Query; Closed = 커서 뒤가 ]] }
function Get-WtMemoSuggestContext($Box) {
    if ($Box.SelectionLength) { return $null }
    $text = $Box.Text
    $i = $Box.CaretIndex
    $ls = if ($i -gt 0) { $text.LastIndexOf("`n", $i - 1) + 1 } else { 0 }
    $m = [regex]::Match($text.Substring($ls, $i - $ls), '\[\[([^\[\]\|#\r\n]*)$')
    if (-not $m.Success) { return $null }
    @{ Start = $ls + $m.Groups[1].Index; Query = $m.Groups[1].Value; Closed = $text.Substring($i).StartsWith(']]') }
}

function Update-WtMemoSuggest($Box) {
    $ed = $Box.Tag
    if (-not $ed.OnTitles -or $ed.Mode -eq 'read') { return }
    $ctx = Get-WtMemoSuggestContext $Box
    if (-not $ctx) { Hide-WtMemoSuggest $ed; return }
    $titles = @(& $ed.OnTitles $ed $ctx.Query | Where-Object { $_ })
    $q = $ctx.Query.Trim()
    $words = @($q -split '\s+' | Where-Object { $_ })
    $cmp = [StringComparison]::OrdinalIgnoreCase
    $hits = @($titles | Where-Object { $t = [string]$_; -not @($words | Where-Object { $t.IndexOf($_, $cmp) -lt 0 }).Count })
    # 앞이 맞는 제목을 먼저
    $hits = @(@($hits | Where-Object { ([string]$_).StartsWith($q, $cmp) }) + @($hits | Where-Object { -not ([string]$_).StartsWith($q, $cmp) })) |
        Select-Object -First $script:suggestMax
    if (-not @($hits).Count) { Hide-WtMemoSuggest $ed; return }
    $s = Get-WtMemoSuggestUi $ed
    $s.Box = $Box
    $s.List.ItemsSource = @($hits)
    $s.List.SelectedIndex = 0
    $r = $Box.GetRectFromCharacterIndex($ctx.Start)
    $s.Popup.PlacementTarget = $Box
    $s.Popup.HorizontalOffset = if ($r.IsEmpty) { 0 } else { $r.X }
    $s.Popup.VerticalOffset = if ($r.IsEmpty) { $Box.ActualHeight } else { $r.Bottom + 4 }
    $s.Popup.IsOpen = $true
}

function Hide-WtMemoSuggest($Ed) {
    if ($Ed.Suggest -and $Ed.Suggest.Popup.IsOpen) { $Ed.Suggest.Popup.IsOpen = $false }
}

# 자동 완성 팝업. 포커스는 입력칸에 두고(목록은 포커스를 받지 않음) ↑↓ · Enter · Tab · Esc는 입력칸이 받아 넘긴다
function Get-WtMemoSuggestUi($Ed) {
    if ($Ed.Suggest) { return $Ed.Suggest }
    $pop = [System.Windows.Controls.Primitives.Popup]::new()
    $pop.StaysOpen = $true
    $pop.Placement = 'Relative'
    $border = [System.Windows.Controls.Border]::new()
    Set-WtStyle $border 'Memo.Suggest'
    $list = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $list 'Memo.SuggestList'
    $list.Focusable = $false
    $list.Tag = $Ed
    $list.Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $item = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource)
            if (-not $item) { return }
            $e.Handled = $true
            try { Complete-WtMemoSuggest $s.Tag ([string]$item.DataContext) } catch { Show-WtError $_ '메모 링크' }
        })
    $border.Child = $list
    $pop.Child = $border
    # 팝업도 편집기 안에 두어야 테마 리소스(색 · 글꼴)를 찾는다
    [void]$Ed.Body.Children.Add($pop)
    $Ed.Suggest = @{ Popup = $pop; List = $list; Box = $null }
    $Ed.Suggest
}

function Complete-WtMemoSuggest($Ed, [string]$Title, $Target = $null) {
    $s = $Ed.Suggest
    $box = if ($Target) { $Target } else { $s.Box }
    Hide-WtMemoSuggest $Ed
    if (-not $box -or -not $Title) { return }
    $ctx = Get-WtMemoSuggestContext $box
    if (-not $ctx) { return }
    $caret = $box.CaretIndex
    $insert = if ($ctx.Closed) { $Title } else { "$Title]]" }
    [void](Invoke-WtMemoBoxEdit $box @{ Start = $ctx.Start; Length = $caret - $ctx.Start; Insert = $insert; SelStart = $ctx.Start + $Title.Length + 2; SelLength = 0 })
    [void]$box.Focus()
}

function Invoke-WtMemoSuggestKey($S, $E) {
    $ed = $S.Tag
    $sg = $ed.Suggest   # $s로 쓰면 매개변수 $S(입력칸)와 같은 변수가 된다
    if (-not $sg -or -not $sg.Popup.IsOpen -or $sg.Box -ne $S) { return }
    $list = $sg.List
    $n = $list.Items.Count
    # 한글 조합 중 Enter · Tab: 입력기가 글자를 확정한 뒤에 고른 제목으로 완성한다
    if ($E.Key -eq 'ImeProcessed') {
        if ((Get-WtMemoKey $E) -in 'Return', 'Tab' -and $list.SelectedItem) { Add-WtMemoImePending $S 'suggest' ([string]$list.SelectedItem) }
        return
    }
    switch ($E.Key) {
        'Down' { $list.SelectedIndex = ($list.SelectedIndex + 1) % $n; $list.ScrollIntoView($list.SelectedItem); $E.Handled = $true }
        'Up' { $list.SelectedIndex = ($list.SelectedIndex - 1 + $n) % $n; $list.ScrollIntoView($list.SelectedItem); $E.Handled = $true }
        { $_ -in 'Return', 'Tab' } {
            $E.Handled = $true
            try { Complete-WtMemoSuggest $ed ([string]$list.SelectedItem) } catch { Show-WtError $_ '메모 링크' }
        }
        'Escape' { Hide-WtMemoSuggest $ed; $E.Handled = $true }
    }
}

# ---- 찾기 · 바꾸기 ----------------------------------------------------------------------------

function New-WtMemoFindBar($Ed) {
    $bar = [System.Windows.Controls.Border]::new()
    Set-WtStyle $bar 'Memo.FindBar'
    $bar.Visibility = 'Collapsed'
    $rows = New-WtStack Vertical 8

    $top = [System.Windows.Controls.DockPanel]::new()
    $close = New-WtButton '' -Kind Icon -Icon 0xE711 -ToolTip '닫기 (Esc)'
    $close.Tag = $Ed
    $close.Add_Click({ param($s, $e) Close-WtMemoFind $s.Tag })
    $next = New-WtButton '' -Kind Icon -Icon 0xE74B -ToolTip '다음 찾기 (Enter · F3)'
    $next.Tag = $Ed
    $next.Add_Click({ param($s, $e) Invoke-WtMemoFind $s.Tag })
    $prev = New-WtButton '' -Kind Icon -Icon 0xE74A -ToolTip '이전 찾기 (Shift+Enter · Shift+F3)'
    $prev.Tag = $Ed
    $prev.Add_Click({ param($s, $e) Invoke-WtMemoFind $s.Tag -Back })
    $count = New-WtText '' 'T.Sub'
    $count.VerticalAlignment = 'Center'
    $count.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
    foreach ($c in $close, $next, $prev, $count) { [System.Windows.Controls.DockPanel]::SetDock($c, 'Right'); [void]$top.Children.Add($c) }
    $sb = New-WtSearchBox '찾기'
    $sb.Box.Tag = $Ed
    $sb.Box.Add_TextChanged({ param($s, $e) Invoke-WtMemoFind $s.Tag -Here })
    $sb.Box.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -ne 'Return') { return }
            $e.Handled = $true
            $back = ([System.Windows.Input.Keyboard]::Modifiers -band 'Shift') -ne 0
            Invoke-WtMemoFind $s.Tag -Back:$back
        })
    [void]$top.Children.Add($sb.Root)
    [void](Add-WtChild $rows $top)

    $low = [System.Windows.Controls.DockPanel]::new()
    $all = New-WtButton '모두 바꾸기' -ToolTip '찾은 것을 모두 바꿉니다'
    $all.Tag = $Ed
    $all.Add_Click({ param($s, $e) Invoke-WtMemoReplace $s.Tag -All })
    $one = New-WtButton '바꾸기' -ToolTip '고른 곳을 바꾸고 다음을 찾습니다 (Enter)'
    $one.Tag = $Ed
    $one.Add_Click({ param($s, $e) Invoke-WtMemoReplace $s.Tag })
    $one.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $all.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    foreach ($c in $all, $one) { [System.Windows.Controls.DockPanel]::SetDock($c, 'Right'); [void]$low.Children.Add($c) }
    $rep = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $rep 'Input'
    $rep.ToolTip = '바꿀 글'
    $rep.Tag = $Ed
    $rep.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; Invoke-WtMemoReplace $s.Tag } })
    [void]$low.Children.Add($rep)
    [void](Add-WtChild $rows $low)
    $bar.Child = $rows
    $Ed.Find = @{ Bar = $bar; Query = $sb.Box; Count = $count; ReplaceRow = $low; Replace = $rep; ReadIndex = -1 }
    $bar
}

function Open-WtMemoFind($Ed, [switch]$Replace) {
    $f = $Ed.Find
    $sel = Get-WtMemoSelectedText $Ed
    $f.Bar.Visibility = 'Visible'
    $f.ReplaceRow.Visibility = if ($Replace -and $Ed.Mode -ne 'read') { 'Visible' } else { 'Collapsed' }
    if ($sel -and -not $sel.Contains("`n")) { $f.Query.Text = $sel }
    else { Update-WtMemoFindCount $Ed }
    [void]$f.Query.Focus()
    $f.Query.SelectAll()
}

function Close-WtMemoFind($Ed) {
    $Ed.Find.Bar.Visibility = 'Collapsed'
    Set-WtMemoEditorFocus $Ed
}

function Get-WtMemoSelectedText($Ed) {
    switch ($Ed.Mode) {
        'source' { return $Ed.Source.SelectedText }
        'live' { if ($Ed.Island) { return $Ed.IslandBox.SelectedText } }
        'read' { return $Ed.View.Selection.Text }
    }
    ''
}

# 글 전체(줄바꿈 \n)에서 찾은 자리들
function Get-WtMemoMatches([string]$Text, [string]$Query) {
    $out = [System.Collections.Generic.List[int]]::new()
    if (-not $Query) { return , $out }
    $i = 0
    while (($i = $Text.IndexOf($Query, $i, [StringComparison]::OrdinalIgnoreCase)) -ge 0) { $out.Add($i); $i += [Math]::Max(1, $Query.Length) }
    , $out
}

# 줄바꿈 \n 글의 위치 ↔ 줄 · 칸
function Get-WtMemoLineCol([string]$Text, [int]$Offset) {
    $before = $Text.Substring(0, [Math]::Min($Offset, $Text.Length))
    $parts = @($before -split "`n")
    @{ Line = $parts.Count - 1; Col = $parts[$parts.Count - 1].Length }
}

function Get-WtMemoOffset([string]$Text, [int]$Line, [int]$Col) {
    $off = 0
    $lines = $Text -split "`n"
    for ($i = 0; $i -lt [Math]::Min($Line, $lines.Count); $i++) { $off += $lines[$i].Length + 1 }
    $off + $Col
}

# 지금 고른 곳(또는 커서)의 시작 · 끝 위치 (줄바꿈 \n 글 기준)
function Get-WtMemoSelectionOffsets($Ed, [string]$Text) {
    switch ($Ed.Mode) {
        'source' {
            $b = $Ed.Source
            $cr = { param($i) $i - ($b.Text.Substring(0, $i).Split("`r").Count - 1) }
            return @((& $cr $b.SelectionStart), (& $cr ($b.SelectionStart + $b.SelectionLength)))
        }
        'live' {
            if ($Ed.Island) {
                $box = $Ed.IslandBox
                $a = Get-WtMemoIslandCaret $Ed $box.SelectionStart
                $z = Get-WtMemoIslandCaret $Ed ($box.SelectionStart + $box.SelectionLength)
                return @((Get-WtMemoOffset $Text $a.Line $a.Col), (Get-WtMemoOffset $Text $z.Line $z.Col))
            }
            $o = Get-WtMemoOffset $Text $Ed.Caret.Line $Ed.Caret.Col
            return @($o, $o)
        }
    }
    @(0, 0)
}

function Select-WtMemoTextRange($Ed, [string]$Text, [int]$Offset, [int]$Length) {
    switch ($Ed.Mode) {
        'source' {
            $b = $Ed.Source
            $crlf = $b.Text.Contains("`r`n")
            $toBox = { param($o) if ($crlf) { $o + ($Text.Substring(0, $o).Split("`n").Count - 1) } else { $o } }
            $s = & $toBox $Offset
            $e = & $toBox ($Offset + $Length)
            $b.Select($s, $e - $s)
            $b.ScrollToLine([Math]::Max(0, $b.GetLineIndexFromCharacterIndex($s)))
        }
        'live' {
            $a = Get-WtMemoLineCol $Text $Offset
            $z = Get-WtMemoLineCol $Text ($Offset + $Length)
            Open-WtMemoIslandAt $Ed $a.Line $a.Col $z.Line $z.Col
        }
    }
}

function Update-WtMemoFindCount($Ed, [int]$Current = -1, [int]$Total = -1) {
    $f = $Ed.Find
    if (-not $f.Query.Text) { $f.Count.Text = ''; return }
    if ($Total -lt 0) {
        $Total = if ($Ed.Mode -eq 'read') { @(Get-WtMemoReadMatches $Ed $f.Query.Text).Count } else { (Get-WtMemoMatches ((Get-WtMemoEditorText $Ed).Replace("`r`n", "`n")) $f.Query.Text).Count }
    }
    $f.Count.Text = if (-not $Total) { '없음' } elseif ($Current -ge 0) { "$($Current + 1)/$Total" } else { "${Total}개" }
}

# 다음(-Back이면 이전) 찾기. -Here: 고른 곳 시작부터 다시 찾기(찾는 글을 칠 때)
function Invoke-WtMemoFind($Ed, [switch]$Back, [switch]$Here) {
    $f = $Ed.Find
    $q = $f.Query.Text
    if (-not $q) { Update-WtMemoFindCount $Ed; return }
    # 실시간 보기에서 찾는 글을 치는 중에는 개수만 센다. 찾은 곳으로 가려면 섬에 포커스를 줬다 돌려받아야 해서
    # 한글 조합이 끊긴다. 이동은 Enter · F3에서
    if ($Here -and $Ed.Mode -eq 'live') { Update-WtMemoFindCount $Ed; return }
    $focusFind = $f.Query.IsKeyboardFocusWithin -or $f.Bar.IsKeyboardFocusWithin
    try {
        if ($Ed.Mode -eq 'read') { Invoke-WtMemoFindRead $Ed $q -Back:$Back -Here:$Here; return }
        $text = (Get-WtMemoEditorText $Ed).Replace("`r`n", "`n")
        $hits = Get-WtMemoMatches $text $q
        if (-not $hits.Count) { Update-WtMemoFindCount $Ed -1 0; return }
        $sel = Get-WtMemoSelectionOffsets $Ed $text
        $k = -1
        if ($Back) {
            for ($i = $hits.Count - 1; $i -ge 0; $i--) { if ($hits[$i] -lt $sel[0]) { $k = $i; break } }
            if ($k -lt 0) { $k = $hits.Count - 1 }
        } else {
            $from = if ($Here) { $sel[0] } else { $sel[1] }
            for ($i = 0; $i -lt $hits.Count; $i++) { if ($hits[$i] -ge $from) { $k = $i; break } }
            if ($k -lt 0) { $k = 0 }
        }
        Select-WtMemoTextRange $Ed $text $hits[$k] $q.Length
        Update-WtMemoFindCount $Ed $k $hits.Count
    } finally {
        if ($focusFind) { [void]$f.Query.Focus() }
    }
}

# 읽기 모드: 그린 글(Run)에서 찾는다. 여러 Run에 걸친 글은 찾지 않는다
function Get-WtMemoReadMatches($Ed, [string]$Query) {
    $out = [System.Collections.Generic.List[object]]::new()
    $tp = $Ed.View.Document.ContentStart
    while ($tp) {
        if ($tp.GetPointerContext('Forward') -eq 'Text') {
            $run = $tp.GetTextInRun('Forward')
            $i = 0
            while (($i = $run.IndexOf($Query, $i, [StringComparison]::OrdinalIgnoreCase)) -ge 0) {
                $out.Add(@{ Start = $tp.GetPositionAtOffset($i); End = $tp.GetPositionAtOffset($i + $Query.Length) })
                $i += [Math]::Max(1, $Query.Length)
            }
        }
        $tp = $tp.GetNextContextPosition('Forward')
    }
    , $out
}

function Invoke-WtMemoFindRead($Ed, [string]$Query, [switch]$Back, [switch]$Here) {
    $f = $Ed.Find
    $hits = Get-WtMemoReadMatches $Ed $Query
    if (-not $hits.Count) { $f.ReadIndex = -1; Update-WtMemoFindCount $Ed -1 0; return }
    $k = if ($Here) { [Math]::Max(0, $f.ReadIndex) } elseif ($Back) { $f.ReadIndex - 1 } else { $f.ReadIndex + 1 }
    if ($k -lt 0) { $k = $hits.Count - 1 }
    if ($k -ge $hits.Count) { $k = 0 }
    $f.ReadIndex = $k
    $Ed.View.Selection.Select($hits[$k].Start, $hits[$k].End)
    $p = $hits[$k].Start.Parent
    if ($p -is [System.Windows.FrameworkContentElement]) { $p.BringIntoView() }
    Update-WtMemoFindCount $Ed $k $hits.Count
}

# 바꾸기: 고른 곳이 찾는 글이면 바꾸고 다음을 찾는다. -All: 모두 바꾸기
function Invoke-WtMemoReplace($Ed, [switch]$All) {
    $f = $Ed.Find
    $q = $f.Query.Text
    if (-not $q -or $Ed.Mode -eq 'read') { return }
    $rep = [string]$f.Replace.Text
    try {
        if ($All) {
            $text = (Get-WtMemoEditorText $Ed).Replace("`r`n", "`n")
            $n = (Get-WtMemoMatches $text $q).Count
            if (-not $n) { Update-WtMemoFindCount $Ed -1 0; return }
            $new = [regex]::Replace($text, [regex]::Escape($q), $rep.Replace('$', '$$'), 'IgnoreCase')
            if ($Ed.Mode -eq 'source') {
                $b = $Ed.Source
                if ($b.Text.Contains("`r`n")) { $new = $new.Replace("`n", "`r`n") }
                $b.SelectAll()
                $b.SelectedText = $new
                $b.Select(0, 0)
            } else {
                Push-WtMemoUndo $Ed
                $Ed.Busy++
                try {
                    if ($Ed.Island) { Close-WtMemoIsland $Ed -NoRender }
                    $Ed.Loading = $true
                    try { Set-WtMemoLines $Ed $new } finally { $Ed.Loading = $false }
                    Update-WtMemoLive $Ed
                } finally { $Ed.Busy-- }
                Invoke-WtMemoEditorChanged $Ed
            }
            $f.Count.Text = "${n}개 바꿈"
            return
        }
        $box = if ($Ed.Mode -eq 'source') { $Ed.Source } elseif ($Ed.Island) { $Ed.IslandBox } else { $null }
        if ($box -and $box.SelectionLength -and [string]::Equals($box.SelectedText, $q, [StringComparison]::OrdinalIgnoreCase)) {
            $start = $box.SelectionStart
            [void](Invoke-WtMemoBoxEdit $box @{ Start = $start; Length = $box.SelectionLength; Insert = $rep; SelStart = $start + $rep.Length; SelLength = 0 })
        }
        Invoke-WtMemoFind $Ed
    } catch { Show-WtError $_ '바꾸기' }
}

# 편집기 전체 단축키: 찾기 · 바꾸기
function Invoke-WtMemoEditorKey($S, $E) {
    if ($E.Handled) { return }
    $ed = $S.Tag
    $key = if ($E.Key -eq 'System') { $E.SystemKey } else { $E.Key }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band 'Control') -ne 0
    $shift = ($mods -band 'Shift') -ne 0
    $alt = ($mods -band 'Alt') -ne 0
    try {
        if ($ctrl -and -not $alt -and -not $shift -and $key -eq 'F') { Open-WtMemoFind $ed; $E.Handled = $true; return }
        if ($ctrl -and -not $alt -and -not $shift -and $key -eq 'H') { Open-WtMemoFind $ed -Replace; $E.Handled = $true; return }
        if ($key -eq 'F3' -and -not $ctrl -and -not $alt) {
            if ($ed.Find.Query.Text) { Invoke-WtMemoFind $ed -Back:$shift } else { Open-WtMemoFind $ed }
            $E.Handled = $true
            return
        }
        if ($key -eq 'Escape' -and $ed.Find.Bar.Visibility -eq 'Visible' -and -not ($ed.Suggest -and $ed.Suggest.Popup.IsOpen)) {
            Close-WtMemoFind $ed
            $E.Handled = $true
        }
    } catch { Show-WtError $_ '찾기' }
}

# 글자 크기를 바꾸면 그려 둔 Section(다이어그램 크기 등)을 버리고 다시 그린다
Register-WtSettingHandler {
    param($key, $value)
    if ($key -ne 'ui.fontScale') { return }
    foreach ($w in @($script:editors)) {
        $ed = $w.Target
        if (-not $ed -or $ed.Mode -ne 'live') { continue }
        $ed.Cache.Clear()
        # 섬이 열려 있으면 닫고 전체를 다시 그린 뒤 같은 자리에 다시 연다 (안 고친 섬을 닫으면 예전 Section을 돌려놓기 때문)
        $caret = $null
        if ($ed.Island) {
            $caret = if ($ed.IslandBox.IsKeyboardFocused) { Get-WtMemoIslandCaret $ed } else { $null }
            $ed.Busy++
            try { Close-WtMemoIsland $ed -NoRender } finally { $ed.Busy-- }
        }
        Update-WtMemoLive $ed
        if ($caret) { Open-WtMemoIslandAt $ed $caret.Line $caret.Col }
    }
}

Export-ModuleMember -Function New-WtMemoEditor, Set-WtMemoEditorText, Get-WtMemoEditorText, Set-WtMemoEditorMode,
    Set-WtMemoEditorEnabled, Set-WtMemoEditorFocus, Get-WtMemoEditorState, Set-WtMemoEditorState

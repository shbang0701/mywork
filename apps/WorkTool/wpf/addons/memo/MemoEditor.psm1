# 메모 편집기. 메모 화면의 칸(pane)마다 하나씩 만든다. 화면 배치 · 탭 · 저장은 Memo.psm1이 하고, 여기는 본문 한 칸만 맡는다.
#
# 모드
#   live    Obsidian처럼 그린 글 위에서 바로 고친다. 고치는 블록만 원문으로 보인다
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
# 이벤트 처리기는 나중에 불리므로 보낸 요소($s)의 Tag(= $ed)와 $script: 변수만 쓴다.

$ErrorActionPreference = 'Stop'

function New-WtMemoEditor {
    param([scriptblock]$OnChanged, [scriptblock]$OnLeave, [scriptblock]$OnLink, [scriptblock]$OnTitles)
    $ed = @{
        Mode = 'live'; Text = ''; Enabled = $true; Loading = $false
        OnChanged = $OnChanged; OnLeave = $OnLeave; OnLink = $OnLink; OnTitles = $OnTitles
    }
    $root = [System.Windows.Controls.Grid]::new()
    $root.Tag = $ed
    $ed.Root = $root

    # 원문 칸
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Editor'
    $box.Tag = $ed
    $box.Add_TextChanged({
            param($s, $e)
            $ed = $s.Tag
            if ($ed.Loading) { return }
            $ed.Text = $s.Text
            Invoke-WtMemoEditorChanged $ed
        })
    [void]$root.Children.Add($box)
    $ed.Source = $box

    # 읽기 보기
    $view = New-WtMarkdownView -Scroll -OnLink { param($link) Invoke-WtMemoEditorLink $link }
    $view.Visibility = 'Collapsed'
    [void]$root.Children.Add($view)
    $ed.View = $view
    # 링크 처리기는 보기 하나에 묶여 있어서, 보기 → 편집기를 찾을 수 있게 둔다
    $view.Tag.Editor = $ed

    $root.Add_LostKeyboardFocus({
            param($s, $e)
            $ed = $s.Tag
            # 편집기 안에서 포커스가 옮겨 다닐 때는 부르지 않는다
            if ($s.IsKeyboardFocusWithin) { return }
            if ($ed.OnLeave) { & $ed.OnLeave $ed }
        })
    Update-WtMemoEditorMode $ed
    $ed
}

function Invoke-WtMemoEditorChanged($Ed) {
    if ($Ed.OnChanged) { & $Ed.OnChanged $Ed }
}

# 마크다운 보기의 링크 처리기. 어느 보기에서 눌렸는지는 $script:linkView로 받지 않고, 마우스 아래 보기를 찾는다
function Invoke-WtMemoEditorLink($Link) {
    $view = [System.Windows.Input.Mouse]::DirectlyOver
    while ($view -and -not ($view -is [System.Windows.Controls.RichTextBox] -and $view.Tag -is [hashtable] -and $view.Tag.Editor)) {
        $view = if ($view -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($view) }
        else { [System.Windows.LogicalTreeHelper]::GetParent($view) }
    }
    if (-not $view) { return $false }
    $ed = $view.Tag.Editor
    if (-not $ed.OnLink) { return $false }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $how = if (($mods -band 'Control') -and ($mods -band 'Alt')) { 'side' } elseif ($mods -band 'Control') { 'tab' } else { 'here' }
    $r = & $ed.OnLink $ed $Link $how | Select-Object -Last 1
    $r -eq $true
}

function Set-WtMemoEditorText($Ed, [AllowEmptyString()][string]$Text) {
    $Ed.Loading = $true
    try {
        $Ed.Text = [string]$Text
        $Ed.Source.Text = $Ed.Text
        $Ed.Source.CaretIndex = 0
        $Ed.Source.ScrollToHome()
        if ($Ed.Mode -ne 'source') { Set-WtMarkdownText $Ed.View $Ed.Text }
    } finally { $Ed.Loading = $false }
}

function Get-WtMemoEditorText($Ed) {
    if ($Ed.Mode -eq 'source') { return [string]$Ed.Source.Text }
    [string]$Ed.Text
}

function Set-WtMemoEditorMode($Ed, [ValidateSet('live', 'source', 'read')][string]$Mode) {
    if ($Ed.Mode -eq $Mode) { return }
    $Ed.Text = Get-WtMemoEditorText $Ed
    $Ed.Mode = $Mode
    Update-WtMemoEditorMode $Ed
}

function Update-WtMemoEditorMode($Ed) {
    # live는 아직 원문 칸으로 대신한다
    $useSource = $Ed.Mode -ne 'read'
    if ($useSource) {
        if ($Ed.Source.Text -cne $Ed.Text) {
            $Ed.Loading = $true
            try { $Ed.Source.Text = $Ed.Text } finally { $Ed.Loading = $false }
        }
    } elseif ($Ed.View.Tag.Text -cne $Ed.Text -or $Ed.View.Tag.Error) {
        Set-WtMarkdownText $Ed.View $Ed.Text
    }
    $Ed.Source.Visibility = if ($useSource) { 'Visible' } else { 'Collapsed' }
    $Ed.View.Visibility = if ($useSource) { 'Collapsed' } else { 'Visible' }
}

function Set-WtMemoEditorEnabled($Ed, [bool]$Enabled) {
    $Ed.Enabled = $Enabled
    $Ed.Root.IsEnabled = $Enabled
}

function Set-WtMemoEditorFocus($Ed, [switch]$End) {
    if ($Ed.Mode -eq 'read') { [void]$Ed.View.Focus(); return }
    if ($End) { $Ed.Source.CaretIndex = $Ed.Source.Text.Length }
    [void]$Ed.Source.Focus()
}

function Get-WtMemoEditorState($Ed) {
    @{ Caret = $Ed.Source.CaretIndex; Scroll = $Ed.Source.VerticalOffset }
}

function Set-WtMemoEditorState($Ed, $State) {
    if (-not $State) { return }
    $Ed.Source.CaretIndex = [Math]::Min([int]$State.Caret, $Ed.Source.Text.Length)
    $Ed.Source.ScrollToVerticalOffset([double]$State.Scroll)
}

Export-ModuleMember -Function New-WtMemoEditor, Set-WtMemoEditorText, Get-WtMemoEditorText, Set-WtMemoEditorMode,
    Set-WtMemoEditorEnabled, Set-WtMemoEditorFocus, Get-WtMemoEditorState, Set-WtMemoEditorState

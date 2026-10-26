# 메모 탭: 목록 · 검색 · 열어 둔 메모 탭 · 창 나누기(칸 2개) · 빠른 이동 · 자동 저장 · 새 메모 · 삭제(실행 취소). 메모별 잠금은 다음에 옮긴다.
# 저장소 memo.json (schema 1). 항목:
#   id, title, body, tags[], lock($null=잠기지 않음. 나중에 'dpapi' | 'password'), created, updated
#   tags는 본문의 #태그를 저장할 때 모은 것이다.
# 화면: 왼쪽 목록, 오른쪽 칸(pane) 1~2개. 칸마다 탭 줄 · 제목 · 편집기(MemoEditor.psm1). 탭 하나 = 메모 하나.
#   목록 클릭은 지금 탭에서, Ctrl+클릭 · 가운데 클릭은 새 탭에서 연다. [[메모 제목]]은 그 메모로(없으면 만든다), #태그는 그 태그 검색으로 간다.
# 설정: memo.mode (live 편집 · source 원문 · read 읽기. 예전 값 edit → live, preview → read)
#       memo.tabs (열린 탭 · 칸 · 지금 탭 · 나눔 비율)
# 단축키(메모 화면 안)는 맨 아래 Register-WtAddon -Shortcuts. 편집 단축키(Ctrl+B · I · K · F 등)는 편집기가 처리한다.

$ErrorActionPreference = 'Stop'

$script:schema = 1
$script:items = @()
$script:panes = [System.Collections.Generic.List[hashtable]]::new()   # 칸. 칸 = @{ Tabs; Current; Dirty; Loading; Editor; 화면 요소 … }
$script:active = 0           # 포커스가 있는 칸 번호
$script:ratio = 0.5          # 두 칸일 때 왼쪽 칸 비율
$script:closed = [System.Collections.Generic.List[hashtable]]::new()  # 닫은 탭 (Ctrl+Shift+T)
$script:mode = 'live'        # live · source · read (모든 칸에 같이)
$script:editMode = 'live'    # 읽기에서 Ctrl+E로 돌아갈 편집 모드
$script:modeUpdating = $false
$script:restored = $false    # 설정에 남은 탭을 불러왔는지
$script:lastDeleted = $null  # 실행 취소용
$script:ui = @{}
$script:saveTimer = $null
$script:undoTimer = $null
$script:listUpdating = $false
$script:listMenuId = ''
$script:rowCache = @{}
$script:quickOpen = $false

Register-WtSettingDefault 'memo.mode' 'live'
Register-WtSettingDefault 'memo.tabs' $null

# ---- 데이터 (WPF 없이) -------------------------------------------------------------------------

function Get-WtMemoItems { Get-WtStoreItems -Name 'memo' -Schema $script:schema }

function Save-WtMemoItems([object[]]$Items) { Write-WtStore -Name 'memo' -Schema $script:schema -Items @($Items) }

# 최근 고친 순서
function Get-WtMemoSorted([object[]]$Items) {
    @($Items | Sort-Object -Property @{ Expression = { [string]$_.updated }; Descending = $true })
}

# 제목 · 본문에 검색어가 모두 들어 있는 메모 (띄어 쓴 낱말마다 AND)
function Find-WtMemo([object[]]$Items, [string]$Query) {
    $words = @($Query -split '\s+' | Where-Object { $_ })
    if (-not $words.Count) { return $Items }
    $Items | Where-Object {
        $text = "$($_.title)`n$($_.body)"
        -not ($words | Where-Object { $text -notlike "*$_*" })
    }
}

function Format-WtMemoTime([string]$Stamp) {
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse($Stamp, [ref]$t)) { return $Stamp }
    if ($t.Date -eq [datetime]::Today) { return Format-WtDate $t "'오늘' HH:mm" }
    if ($t.Date -eq [datetime]::Today.AddDays(-1)) { return '어제' }
    Format-WtDate $t "M'/'d"
}

function Get-WtMemoStamp([datetime]$When) { $When.ToString('yyyy-MM-dd HH:mm:ss') }

function New-WtMemo([datetime]$When = (Get-Date)) {
    $now = Get-WtMemoStamp $When
    [pscustomobject]@{ id = New-WtId; title = ''; body = ''; tags = @(); lock = $null; created = $now; updated = $now }
}

# 본문의 #태그 (중복 없이, 처음 나온 순서)
function Get-WtMemoTags([string]$Body) {
    $seen = [System.Collections.Generic.List[string]]::new()
    $walk = {
        param($list)
        foreach ($x in @($list)) {
            if ($null -eq $x) { continue }
            if ($x.T -eq 'tag' -and -not $seen.Contains($x.Text)) { $seen.Add($x.Text) }
            foreach ($k in 'Inl', 'Title', 'Blocks', 'Items') { if ($x.$k) { & $walk $x.$k } }
            if ($x.Cells) { foreach ($c in $x.Cells) { & $walk $c } }
        }
    }
    & $walk (ConvertTo-WtMarkdownModel $Body).Blocks
    $seen.ToArray()
}

# 메모 하나의 제목 · 본문을 바꾼다. 제목이 비면 저장 시각을 제목으로 쓴다 (예전 WorkTool과 같음)
function Set-WtMemoContent($Memo, [string]$Title, [string]$Body, [datetime]$When = (Get-Date)) {
    $t = $Title.Trim()
    if (-not $t) { $t = $When.ToString('yyyy-MM-dd HH:mm') }
    $Memo.title = $t
    $Memo.body = $Body
    $Memo | Add-Member -NotePropertyName tags -NotePropertyValue @(Get-WtMemoTags $Body) -Force   # 예전 데이터엔 tags가 없을 수 있다
    $Memo.updated = Get-WtMemoStamp $When
    $Memo
}

# 빠른 이동 결과. 띄어 쓴 낱말이 제목에 모두 들어 있으면 위에, 본문까지 합쳐야 들어 있으면 아래에 (각각 최근 고친 순)
function Find-WtMemoQuick([object[]]$Items, [string]$Query, [int]$Limit = 50) {
    $words = @($Query -split '\s+' | Where-Object { $_ })
    $inTitle = [System.Collections.Generic.List[object]]::new()
    $inBody = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $Items) {
        $title = [string]$m.title
        if (-not ($words | Where-Object { $title -notlike "*$_*" })) { $inTitle.Add($m); continue }
        $text = "$title`n$($m.body)"
        if (-not ($words | Where-Object { $text -notlike "*$_*" })) { $inBody.Add($m) }
    }
    @(@($inTitle) + @($inBody) | Select-Object -First $Limit)
}

# 예전 memo.csv → memo.json. 가져온 개수를 돌려준다.
function Import-WtMemoLegacy([string]$Folder) {
    $rows = Import-WtLegacyCsv $Folder 'memo'
    if ($null -eq $rows) { return $null }
    $items = foreach ($r in $rows) {
        [ordered]@{
            id      = [string]$r.Id
            title   = [string]$r.Title
            body    = [string]$r.Body
            tags    = @()
            lock    = $null
            created = [string]$r.Created
            updated = [string]$r.Updated
        }
    }
    Write-WtStore -Name 'memo' -Schema $script:schema -Items @($items) -Extra @{ importedFrom = $Folder }
    @($items).Count
}

# 설정의 모드 값. 예전 값(edit · preview)도 읽는다
function Get-WtMemoModeSetting {
    switch ([string](Get-WtSetting 'memo.mode')) {
        'source' { return 'source' }
        'read' { return 'read' }
        'preview' { return 'read' }
    }
    'live'
}

# ---- 화면: 칸 · 탭 상태 ------------------------------------------------------------------------

function Get-WtMemoById([string]$Id) { $script:items | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }

function Get-WtMemoModifiers { [System.Windows.Input.Keyboard]::Modifiers }

function Get-WtMemoActivePane {
    if (-not $script:panes.Count) { return $null }
    $script:panes[[Math]::Max(0, [Math]::Min($script:active, $script:panes.Count - 1))]
}

function Get-WtMemoPaneOf($Ed) {
    foreach ($p in $script:panes) { if ([object]::ReferenceEquals($p.Editor, $Ed)) { return $p } }
    $null
}

function Get-WtMemoCurrentId {
    $p = Get-WtMemoActivePane
    if ($p -and $p.Current) { [string]$p.Current.Id } else { '' }
}

function Get-WtMemoTitle([string]$Id) {
    $m = Get-WtMemoById $Id
    if (-not $m) { return '(없는 메모)' }
    if ([string]$m.title) { [string]$m.title } else { '제목 없음' }
}

function New-WtMemoTab([string]$Id) {
    @{ Id = $Id; Back = [System.Collections.Generic.List[string]]::new(); Forward = [System.Collections.Generic.List[string]]::new(); State = $null; Button = $null; Text = $null; Style = $null }
}

# 칸의 지금 탭에 편집기 커서 · 스크롤을 기억해 둔다 (탭을 바꾸기 전)
function Save-WtMemoPaneState($Pane) {
    if ($Pane.Current -and (Get-WtMemoById $Pane.Current.Id)) { $Pane.Current.State = @(Get-WtMemoEditorState $Pane.Editor)[-1] }
}

# 열린 탭 · 칸 · 지금 탭 · 나눔 비율을 설정에 남긴다
function Save-WtMemoTabs {
    if (-not $script:restored) { return }
    $value = [ordered]@{
        panes  = @(foreach ($p in $script:panes) {
                [ordered]@{ tabs = @(foreach ($t in $p.Tabs) { [string]$t.Id }); current = [int]$p.Tabs.IndexOf($p.Current) }
            })
        active = [int]$script:active
        ratio  = [Math]::Round([double]$script:ratio, 3)
    }
    try { $null = Set-WtSetting 'memo.tabs' $value } catch { }   # 설정을 못 남겨도 메모 쓰기는 막지 않는다
}

# 저장 상태 표시 (칸마다): saved · dirty · writing · error · ''(숨김)
function Set-WtMemoStatus($Pane, [string]$State, [string]$Detail = '') {
    $s = $Pane.Status
    $m = if ($Pane.Current) { Get-WtMemoById $Pane.Current.Id } else { $null }
    $stamp = if ($State -eq 'saved' -and $m) { [string]$m.updated } else { '' }
    $key = @($State, $Detail, $stamp) -join "`n"
    if ($s.Tag -ceq $key) { return }
    switch ($State) {
        'saved' {
            $at = if ($m) { ([string]$m.updated -split ' ')[-1] -replace ':\d\d$', '' } else { '' }
            $s.Content = New-WtButtonContent "자동 저장됨 · $at" 0xE73E
            Set-WtResource $s 'Foreground' 'B.Success'
            $s.Visibility = 'Visible'
        }
        'dirty' {
            $s.Content = New-WtButtonContent '저장 안 됨' 0xE70F
            Set-WtResource $s 'Foreground' 'B.SubText'
            $s.Visibility = 'Visible'
        }
        'error' {
            $s.Content = New-WtButtonContent "저장하지 못했습니다. $Detail" 0xE783
            Set-WtResource $s 'Foreground' 'B.Danger'
            $s.Visibility = 'Visible'
        }
        'writing' {
            # 실패가 아니다: 데이터 폴더가 늦게 답해 저장 통로가 이어서 쓰는 중. 파일에 쓰이면 「자동 저장됨」이 된다 (Update-WtMemoSaveStatus)
            $s.Content = New-WtButtonContent '저장하는 중 · 데이터 폴더가 늦게 답합니다' 0xE895
            Set-WtResource $s 'Foreground' 'B.Warn'
            $s.Visibility = 'Visible'
        }
        default { $s.Visibility = 'Collapsed' }
    }
    $s.Tag = $key
}

# 칸에 지금 탭의 메모를 채운다 (없으면 빈 칸 안내). 고친 표시는 지운다: 부르기 전에 저장한다
function Show-WtMemoPane($Pane) {
    $m = if ($Pane.Current) { Get-WtMemoById $Pane.Current.Id } else { $null }
    $Pane.Loading = $true
    try {
        if ($m) {
            $Pane.TitleText.Text = $m.title
            $Pane.TitleBox.Text = $m.title
            Set-WtMemoMeta $Pane $m
            $null = Set-WtMemoEditorText $Pane.Editor ([string]$m.body)
            $null = Set-WtMemoEditorState $Pane.Editor $Pane.Current.State
        } else {
            $Pane.TitleText.Text = ''
            $Pane.TitleBox.Text = ''
            Set-WtMemoMeta $Pane $null
            $null = Set-WtMemoEditorText $Pane.Editor ''
        }
    } finally { $Pane.Loading = $false }
    $Pane.Dirty = $false
    $vis = if ($m) { 'Visible' } else { 'Collapsed' }
    $Pane.Head.Visibility = $vis
    $Pane.Editor.Root.Visibility = $vis
    $Pane.Empty.Visibility = if ($m) { 'Collapsed' } else { 'Visible' }
    $null = Set-WtMemoEditorEnabled $Pane.Editor ([bool]$m)
    $Pane.Delete.IsEnabled = [bool]$m
    $Pane.Delete.ToolTip = if ($m) { '이 메모 삭제' } else { '메모를 먼저 여세요' }
    $Pane.EmptyText.Text = if ($script:items.Count) { '열린 메모가 없습니다. 목록에서 고르거나 새로 만드세요.' } else { '메모가 없습니다.' }
    $Pane.EmptyQuick.IsEnabled = [bool]$script:items.Count
    $Pane.EmptyQuick.ToolTip = if ($script:items.Count) { '빠른 이동 (Ctrl+O)' } else { '메모가 없습니다' }
    Update-WtMemoPaneMode $Pane
    if ($m) { $look = Get-WtMemoSaveLook; Set-WtMemoStatus $Pane $look[0] $look[1] } else { Set-WtMemoStatus $Pane '' }
}

# 저장한 뒤 칸의 제목 · 날짜를 고치고, 다른 칸에서 저장해 글이 달라졌으면 다시 불러온다 (커서 · 스크롤 유지)
function Update-WtMemoPaneContent($Pane) {
    $m = Get-WtMemoById $Pane.Current.Id
    if (-not $m) { return }
    $Pane.Loading = $true
    try {
        $Pane.TitleText.Text = $m.title
        if (-not $Pane.TitleBox.IsKeyboardFocused -and $Pane.TitleBox.Text -cne $m.title) { $Pane.TitleBox.Text = $m.title }
        Set-WtMemoMeta $Pane $m
        if ((Get-WtMemoEditorText $Pane.Editor) -cne [string]$m.body) {
            $state = Get-WtMemoEditorState $Pane.Editor
            $null = Set-WtMemoEditorText $Pane.Editor ([string]$m.body)
            $null = Set-WtMemoEditorState $Pane.Editor $state
        }
    } finally { $Pane.Loading = $false }
}

# 만든 날 · 고친 날. 칸이 좁으면 …로 줄이고 마우스를 올리면 전체
function Set-WtMemoMeta($Pane, $Memo) {
    $text = if ($Memo) { '만든 날 {0} · 고친 날 {1}' -f $Memo.created, $Memo.updated } else { '' }
    $Pane.Meta.Text = $text
    $Pane.Meta.ToolTip = if ($text) { $text } else { $null }
}

function Update-WtMemoPaneMode($Pane) {
    $null = Set-WtMemoEditorMode $Pane.Editor $script:mode
    $read = $script:mode -eq 'read'
    $Pane.TitleBox.Visibility = if ($read) { 'Collapsed' } else { 'Visible' }
    $Pane.TitleText.Visibility = if ($read) { 'Visible' } else { 'Collapsed' }
}

# ---- 탭 줄 ------------------------------------------------------------------------------------

function New-WtMemoTabButton($Pane, $Tab) {
    $b = [System.Windows.Controls.Button]::new()
    Set-WtStyle $b 'Memo.Tab'
    $b.Tag = @{ Pane = $Pane; Tab = $Tab }
    $row = [System.Windows.Controls.DockPanel]::new()
    $x = [System.Windows.Controls.Button]::new()
    Set-WtStyle $x 'Memo.TabClose'
    $glyph = New-WtIcon 0xE711
    Set-WtResource $glyph 'FontSize' 'F.Small'
    $x.Content = $glyph
    $x.ToolTip = '닫기 (Ctrl+W)'
    $x.Tag = $b.Tag
    $x.Add_Click({ param($s, $e) [void](Close-WtMemoTab $s.Tag.Pane $s.Tag.Tab); $e.Handled = $true })
    [System.Windows.Controls.DockPanel]::SetDock($x, 'Right')
    [void]$row.Children.Add($x)
    $text = [System.Windows.Controls.TextBlock]::new()
    Set-WtStyle $text 'Memo.TabText'
    [void]$row.Children.Add($text)
    $b.Content = $row
    $b.Add_Click({ param($s, $e) [void](Select-WtMemoTab $s.Tag.Pane $s.Tag.Tab) })
    # 가운데 클릭으로 닫기
    $b.Add_PreviewMouseDown({
            param($s, $e)
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Middle) { [void](Close-WtMemoTab $s.Tag.Pane $s.Tag.Tab); $e.Handled = $true }
        })
    # 우클릭 메뉴: 닫기 · 다른 탭 닫기 · 오른쪽에 나눠 열기(나눴으면 다른 칸으로 옮기기)
    $menu = New-WtContextMenu
    $menu.Tag = $b.Tag
    foreach ($spec in @(@('close', '닫기', 'Ctrl+W'), @('others', '다른 탭 닫기', ''), @('side', '오른쪽에 나눠 열기', 'Ctrl+\'))) {
        $mi = [System.Windows.Controls.MenuItem]::new()
        $mi.Header = $spec[1]
        $mi.InputGestureText = $spec[2]
        $mi.Tag = $spec[0]
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($mi, $true)
        $mi.Add_Click({ param($s, $e) Invoke-WtMemoTabMenu $s.Parent.Tag.Pane $s.Parent.Tag.Tab ([string]$s.Tag) })
        [void]$menu.Items.Add($mi)
    }
    $b.ContextMenu = $menu
    $b.Add_ContextMenuOpening({
            param($s, $e)
            $items = $s.ContextMenu.Items
            $items[1].IsEnabled = $s.Tag.Pane.Tabs.Count -gt 1
            $items[1].ToolTip = if ($items[1].IsEnabled) { $null } else { '다른 탭이 없습니다' }
            $items[2].Header = if ($script:panes.Count -gt 1) { '다른 칸으로 옮기기' } else { '오른쪽에 나눠 열기' }
            $items[2].InputGestureText = if ($script:panes.Count -gt 1) { '' } else { 'Ctrl+\' }
        })
    $Tab.Button = $b
    $Tab.Text = $text
    $Tab.Style = 'Memo.Tab'
    $b
}

function Invoke-WtMemoTabMenu($Pane, $Tab, [string]$Action) {
    switch ($Action) {
        'close' { [void](Close-WtMemoTab $Pane $Tab) }
        'others' {
            if (-not (Select-WtMemoTab $Pane $Tab)) { return }
            foreach ($t in @($Pane.Tabs)) { if (-not [object]::ReferenceEquals($t, $Tab)) { [void](Close-WtMemoTab $Pane $t) } }
        }
        'side' {
            if ($script:panes.Count -gt 1) { [void](Move-WtMemoTab $Pane $Tab) }
            else { [void](Open-WtMemo $Tab.Id 'side' $Pane) }
        }
    }
}

# 칸의 탭 줄을 탭 목록대로 다시 만든다 (탭을 열고 닫을 때)
function Update-WtMemoTabStrip($Pane) {
    $Pane.Strip.Children.Clear()
    foreach ($t in $Pane.Tabs) { [void]$Pane.Strip.Children.Add((New-WtMemoTabButton $Pane $t)) }
    Update-WtMemoTabTexts
    Update-WtMemoTabStyles
}

function Update-WtMemoTabTexts {
    foreach ($p in $script:panes) {
        foreach ($t in $p.Tabs) {
            if (-not $t.Text) { continue }
            $title = Get-WtMemoTitle $t.Id
            if ($t.Text.Text -cne $title) { $t.Text.Text = $title; $t.Button.ToolTip = $title }
        }
    }
}

# 선택된 탭 표시: 포커스가 있는 칸의 지금 탭만 강조색, 다른 칸의 지금 탭은 덜 강조
function Update-WtMemoTabStyles {
    for ($i = 0; $i -lt $script:panes.Count; $i++) {
        $p = $script:panes[$i]
        foreach ($t in $p.Tabs) {
            if (-not $t.Button) { continue }
            $style = if (-not [object]::ReferenceEquals($t, $p.Current)) { 'Memo.Tab' } elseif ($i -eq $script:active) { 'Memo.Tab.Current' } else { 'Memo.Tab.Selected' }
            if ($t.Style -cne $style) { Set-WtStyle $t.Button $style; $t.Style = $style }
        }
        if ($p.Current -and $p.Current.Button) { $p.Current.Button.BringIntoView() }
    }
}

# ---- 칸 만들기 · 나누기 -----------------------------------------------------------------------

function New-WtMemoPane {
    $pane = @{ Tabs = [System.Collections.Generic.List[hashtable]]::new(); Current = $null; Dirty = $false; Loading = $false }
    $card = [System.Windows.Controls.Border]::new()
    Set-WtStyle $card 'Memo.Pane'
    $card.Tag = $pane
    $card.Add_PreviewMouseDown({ param($s, $e) Set-WtMemoActivePane $s.Tag })
    $card.Add_GotKeyboardFocus({ param($s, $e) Set-WtMemoActivePane $s.Tag })
    $dock = [System.Windows.Controls.DockPanel]::new()

    # 탭 줄: 넘치면 가로로 스크롤(마우스 휠로도), 오른쪽 끝에 +
    $bar = [System.Windows.Controls.Border]::new()
    Set-WtStyle $bar 'Memo.TabBar'
    $barGrid = [System.Windows.Controls.Grid]::new()
    $bc1 = [System.Windows.Controls.ColumnDefinition]::new()
    $bc1.Width = [System.Windows.GridLength]::new(1, 'Star')
    $bc2 = [System.Windows.Controls.ColumnDefinition]::new()
    $bc2.Width = [System.Windows.GridLength]::Auto
    $barGrid.ColumnDefinitions.Add($bc1)
    $barGrid.ColumnDefinitions.Add($bc2)
    $scroll = [System.Windows.Controls.ScrollViewer]::new()
    $scroll.HorizontalScrollBarVisibility = 'Hidden'
    $scroll.VerticalScrollBarVisibility = 'Disabled'
    $scroll.Focusable = $false
    $scroll.Add_PreviewMouseWheel({ param($s, $e) $s.ScrollToHorizontalOffset($s.HorizontalOffset - $e.Delta); $e.Handled = $true })
    $strip = New-WtStack Horizontal
    $scroll.Content = $strip
    [void]$barGrid.Children.Add($scroll)
    $add = New-WtButton '' -Kind Icon -Icon 0xE710 -ToolTip '새 메모 (Ctrl+N)'
    $add.Tag = $pane
    $add.Add_Click({ param($s, $e) Set-WtMemoActivePane $s.Tag; [void](Add-WtMemo -Edit) })
    [System.Windows.Controls.Grid]::SetColumn($add, 1)
    [void]$barGrid.Children.Add($add)
    $bar.Child = $barGrid
    [System.Windows.Controls.DockPanel]::SetDock($bar, 'Top')
    [void]$dock.Children.Add($bar)

    # 아래: 삭제 + 실행 취소 자리
    $bottom = [System.Windows.Controls.DockPanel]::new()
    $bottom.Margin = [System.Windows.Thickness]::new(20, 12, 20, 12)
    $del = New-WtButton '삭제' -Kind Danger -Icon 0xE74D
    $del.Tag = $pane
    $del.Add_Click({ param($s, $e) Set-WtMemoActivePane $s.Tag; Remove-WtMemoCurrent $s.Tag })
    [System.Windows.Controls.DockPanel]::SetDock($del, 'Left')
    [void]$bottom.Children.Add($del)
    $undoHost = [System.Windows.Controls.ContentControl]::new()
    $undoHost.Focusable = $false
    $undoHost.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    [void]$bottom.Children.Add($undoHost)
    $sep = [System.Windows.Controls.Border]::new()
    Set-WtStyle $sep 'Divider'
    $sep.Margin = [System.Windows.Thickness]::new(20, 0, 20, 0)
    $bwrap = New-WtStack Vertical
    [void]$bwrap.Children.Add($sep)
    [void]$bwrap.Children.Add($bottom)
    [System.Windows.Controls.DockPanel]::SetDock($bwrap, 'Bottom')
    [void]$dock.Children.Add($bwrap)

    # 머리: 제목(편집이면 입력칸, 읽기면 글자) · 만든 날/고친 날 · 저장 상태
    $head = New-WtStack Vertical 4
    $head.Margin = [System.Windows.Thickness]::new(20, 16, 20, 0)
    $titleText = New-WtText '' 'T.H2'
    Set-WtResource $titleText 'FontSize' 'F.Number'
    $titleBox = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $titleBox 'Input.Title'
    $titleBox.ToolTip = '제목 (비우면 저장 시각)'
    $titleBox.Tag = $pane
    $titleBox.Add_TextChanged({ param($s, $e) Set-WtMemoDirty $s.Tag })
    $titleBox.Add_LostKeyboardFocus({ [void](Save-WtMemoNow) })
    $metaRow = [System.Windows.Controls.DockPanel]::new()
    $status = [System.Windows.Controls.Label]::new()
    Set-WtResource $status 'FontFamily' 'Font.UI'
    Set-WtResource $status 'FontSize' 'F.Small'
    $status.Padding = [System.Windows.Thickness]::new(0)
    $status.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $status.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($status, 'Right')
    [void]$metaRow.Children.Add($status)
    $meta = New-WtText '' 'T.Sub'
    $meta.VerticalAlignment = 'Center'
    $meta.TextWrapping = 'NoWrap'
    $meta.TextTrimming = 'CharacterEllipsis'
    [void]$metaRow.Children.Add($meta)
    [void](Add-WtChild $head $titleText)
    [void](Add-WtChild $head $titleBox)
    [void](Add-WtChild $head $metaRow)
    $line = [System.Windows.Controls.Border]::new()
    Set-WtStyle $line 'Divider'
    $line.Margin = [System.Windows.Thickness]::new(0, 12, 0, 12)
    [void]$head.Children.Add($line)
    [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
    [void]$dock.Children.Add($head)

    # 본문: 편집기 + 탭이 없을 때 안내
    $body = [System.Windows.Controls.Grid]::new()
    $body.Margin = [System.Windows.Thickness]::new(20, 0, 20, 0)
    $ed = New-WtMemoEditor -OnChanged { param($ed) $p = Get-WtMemoPaneOf $ed; if ($p) { Set-WtMemoDirty $p } } `
        -OnLeave { param($ed) [void](Save-WtMemoNow) } `
        -OnLink { param($ed, $link, $how) Invoke-WtMemoLink $ed $link $how } `
        -OnTitles { param($ed, $prefix) Get-WtMemoTitles }
    [void]$body.Children.Add($ed.Root)
    $empty = New-WtStack Vertical 12
    $empty.HorizontalAlignment = 'Center'
    $empty.VerticalAlignment = 'Center'
    $emptyText = New-WtText '' 'T.Sub'
    $emptyText.HorizontalAlignment = 'Center'
    [void](Add-WtChild $empty $emptyText)
    $emptyButtons = New-WtStack Horizontal 8
    $emptyButtons.HorizontalAlignment = 'Center'
    $emptyAdd = New-WtButton '새 메모' -Icon 0xE710 -ToolTip '새 메모 (Ctrl+N)'
    $emptyAdd.Tag = $pane
    $emptyAdd.Add_Click({ param($s, $e) Set-WtMemoActivePane $s.Tag; [void](Add-WtMemo -Edit) })
    $emptyQuick = New-WtButton '빠른 이동' -Icon 0xE721
    $emptyQuick.Tag = $pane
    $emptyQuick.Add_Click({ param($s, $e) Set-WtMemoActivePane $s.Tag; Open-WtMemoQuick })
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($emptyQuick, $true)
    [void](Add-WtChild $emptyButtons $emptyAdd)
    [void](Add-WtChild $emptyButtons $emptyQuick)
    [void](Add-WtChild $empty $emptyButtons)
    [void]$body.Children.Add($empty)
    [void]$dock.Children.Add($body)
    $card.Child = $dock

    $pane.Root = $card; $pane.Strip = $strip; $pane.Scroll = $scroll; $pane.Head = $head
    $pane.TitleText = $titleText; $pane.TitleBox = $titleBox; $pane.Meta = $meta; $pane.Status = $status
    $pane.Editor = $ed; $pane.Empty = $empty; $pane.EmptyText = $emptyText; $pane.EmptyQuick = $emptyQuick
    $pane.Delete = $del; $pane.UndoHost = $undoHost
    $pane
}

# 칸을 하나 더한다 (오른쪽). 더한 칸은 $script:panes의 마지막
function Add-WtMemoPane {
    $pane = @(New-WtMemoPane | Where-Object { $_ -is [hashtable] })[-1]
    $script:panes.Add($pane)
    [void]$script:ui.PaneGrid.Children.Add($pane.Root)
    $null = Update-WtMemoSplit
    $null = Show-WtMemoPane $pane
}

function Get-WtMemoLastPane { $script:panes[$script:panes.Count - 1] }

# 칸을 뺀다 (탭이 없어진 칸). 실행 취소 막대가 거기 있었으면 남은 칸으로 옮긴다
function Remove-WtMemoPaneAt([int]$Index) {
    $pane = $script:panes[$Index]
    $script:panes.RemoveAt($Index)
    $script:ui.PaneGrid.Children.Remove($pane.Root)
    if ($pane.UndoHost.Content) {
        $bar = $pane.UndoHost.Content
        $pane.UndoHost.Content = $null
        $script:panes[0].UndoHost.Content = $bar
    }
    if ($script:active -ge $Index -and $script:active -gt 0) { $script:active-- }
    Update-WtMemoSplit
}

# 두 칸 중 빈 칸을 정리한다: 둘째 칸이 비면 나눔을 풀고, 첫 칸이 비고 둘째 칸에 탭이 있으면 하나로 합친다
function Update-WtMemoPaneLayout {
    if ($script:panes.Count -lt 2) { return }
    if (-not $script:panes[1].Tabs.Count) { Remove-WtMemoPaneAt 1 }
    elseif (-not $script:panes[0].Tabs.Count) { Remove-WtMemoPaneAt 0 }
}

function Update-WtMemoSplit {
    $u = $script:ui
    $split = $script:panes.Count -gt 1
    $r = [Math]::Max(0.2, [Math]::Min(0.8, [double]$script:ratio))
    $u.PaneCol0.Width = [System.Windows.GridLength]::new($(if ($split) { $r } else { 1 }), 'Star')
    $u.PaneCol1.Width = [System.Windows.GridLength]::new($(if ($split) { 16 } else { 0 }))
    $u.PaneCol2.Width = if ($split) { [System.Windows.GridLength]::new(1 - $r, 'Star') } else { [System.Windows.GridLength]::new(0) }
    $u.PaneCol0.MinWidth = if ($split) { 280 } else { 0 }
    $u.PaneCol2.MinWidth = if ($split) { 280 } else { 0 }
    $u.Splitter.Visibility = if ($split) { 'Visible' } else { 'Collapsed' }
    for ($i = 0; $i -lt $script:panes.Count; $i++) { [System.Windows.Controls.Grid]::SetColumn($script:panes[$i].Root, $i * 2) }
    Update-WtMemoTabStyles
}

function Set-WtMemoActivePane($Pane) {
    $i = $script:panes.IndexOf($Pane)
    if ($i -lt 0 -or $i -eq $script:active) { return }
    $script:active = $i
    Update-WtMemoTabStyles
    Sync-WtMemoListSelection
    Save-WtMemoTabs
}

# 다른 칸. 나누지 않았으면 -Create일 때 오른쪽 칸을 만든다
function Get-WtMemoOtherPane($Pane, [switch]$Create) {
    if ($script:panes.Count -lt 2) {
        if (-not $Create) { return $null }
        Add-WtMemoPane
        return Get-WtMemoLastPane
    }
    if ([object]::ReferenceEquals($script:panes[0], $Pane)) { $script:panes[1] } else { $script:panes[0] }
}

# ---- 탭 열기 · 닫기 · 옮기기 ------------------------------------------------------------------

# 메모를 연다. $How: here(지금 탭 · 그 칸에 이미 열려 있으면 그 탭) · tab(새 탭) · side(다른 칸, 나누지 않았으면 나눔)
# -History: 링크 · 빠른 이동으로 갈 때만. 지금 탭의 뒤로 기록에 쌓는다 (목록 클릭은 쌓지 않음)
function Open-WtMemo([string]$Id, [string]$How = 'here', $Pane, [switch]$History) {
    if (-not (Get-WtMemoById $Id)) { return $false }
    if (-not $Pane) { $Pane = Get-WtMemoActivePane }
    if (-not (Save-WtMemoNow)) { return $false }
    if ($How -eq 'side') { $Pane = Get-WtMemoOtherPane $Pane -Create }
    $existing = $Pane.Tabs | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($existing) { return Select-WtMemoTab $Pane $existing }
    Save-WtMemoPaneState $Pane
    if ($How -eq 'here' -and $Pane.Current) {
        $tab = $Pane.Current
        if ($History) { $tab.Back.Add($tab.Id); $tab.Forward.Clear() }
        $tab.Id = $Id
        $tab.State = $null
    } else {
        $tab = New-WtMemoTab $Id
        $at = if ($Pane.Current) { $Pane.Tabs.IndexOf($Pane.Current) + 1 } else { $Pane.Tabs.Count }
        $Pane.Tabs.Insert($at, $tab)
        $Pane.Current = $tab
        Update-WtMemoTabStrip $Pane
    }
    $script:active = $script:panes.IndexOf($Pane)
    Show-WtMemoPane $Pane
    Update-WtMemoTabTexts
    Update-WtMemoTabStyles
    Sync-WtMemoListSelection
    Save-WtMemoTabs
    $true
}

function Select-WtMemoTab($Pane, $Tab) {
    if ([object]::ReferenceEquals($Pane.Current, $Tab)) { Set-WtMemoActivePane $Pane; return $true }
    if (-not (Save-WtMemoNow)) { return $false }
    Save-WtMemoPaneState $Pane
    $Pane.Current = $Tab
    $script:active = $script:panes.IndexOf($Pane)
    Show-WtMemoPane $Pane
    Update-WtMemoTabStyles
    Sync-WtMemoListSelection
    Save-WtMemoTabs
    $true
}

# 탭을 닫는다. 고친 내용이 있으면 먼저 저장하고, 못 하면 닫지 않는다
function Close-WtMemoTab($Pane, $Tab, [switch]$NoHistory) {
    $wasCurrent = [object]::ReferenceEquals($Pane.Current, $Tab)
    if ($wasCurrent -and -not (Save-WtMemoNow)) { return $false }
    $i = $Pane.Tabs.IndexOf($Tab)
    if ($i -lt 0) { return $false }
    if (-not $NoHistory) {
        $script:closed.Add(@{ Id = $Tab.Id; Pane = $script:panes.IndexOf($Pane) })
        while ($script:closed.Count -gt 20) { $script:closed.RemoveAt(0) }
    }
    $Pane.Tabs.RemoveAt($i)
    if ($wasCurrent) {
        $Pane.Current = if ($Pane.Tabs.Count) { $Pane.Tabs[[Math]::Min($i, $Pane.Tabs.Count - 1)] } else { $null }
    }
    Update-WtMemoTabStrip $Pane
    Update-WtMemoPaneLayout
    if ($wasCurrent -and $script:panes.Contains($Pane)) { Show-WtMemoPane $Pane }
    Update-WtMemoTabStyles
    Sync-WtMemoListSelection
    Save-WtMemoTabs
    $true
}

function Close-WtMemoCurrentTab {
    $p = Get-WtMemoActivePane
    if ($p -and $p.Current) { [void](Close-WtMemoTab $p $p.Current) }
}

# 닫은 탭 다시 열기 (지워진 메모는 건너뜀)
function Restore-WtMemoClosedTab {
    while ($script:closed.Count) {
        $c = $script:closed[$script:closed.Count - 1]
        $script:closed.RemoveAt($script:closed.Count - 1)
        if (-not (Get-WtMemoById $c.Id)) { continue }
        $pane = if ($c.Pane -lt $script:panes.Count) { $script:panes[$c.Pane] } else { Get-WtMemoActivePane }
        [void](Open-WtMemo $c.Id 'tab' $pane)
        return
    }
}

# 탭을 다른 칸으로 옮긴다 (나눠 있을 때)
function Move-WtMemoTab($Pane, $Tab) {
    $other = Get-WtMemoOtherPane $Pane
    if (-not $other) { return $false }
    if ([object]::ReferenceEquals($Pane.Current, $Tab) -and -not (Save-WtMemoNow)) { return $false }
    $memoId = $Tab.Id
    $state = if ([object]::ReferenceEquals($Pane.Current, $Tab)) { Get-WtMemoEditorState $Pane.Editor } else { $Tab.State }
    if (-not (Close-WtMemoTab $Pane $Tab -NoHistory)) { return $false }
    # 닫으면서 칸이 합쳐졌을 수 있다
    if (-not $script:panes.Contains($other)) { $other = $script:panes[0] }
    $ok = Open-WtMemo $memoId 'tab' $other
    if ($ok -and $other.Current -and $other.Current.Id -eq $memoId -and $state) { $null = Set-WtMemoEditorState $other.Editor $state }
    $ok
}

# 칸의 지금 탭을 다음/이전 탭으로 (끝에서 처음으로 돈다)
function Select-WtMemoNextTab([int]$Step) {
    $p = Get-WtMemoActivePane
    if (-not $p -or $p.Tabs.Count -lt 2) { return }
    $i = $p.Tabs.IndexOf($p.Current)
    $n = $p.Tabs.Count
    [void](Select-WtMemoTab $p $p.Tabs[(($i + $Step) % $n + $n) % $n])
}

# Ctrl+\: 나누지 않았으면 지금 메모를 오른쪽 칸에 열고, 나눴으면 다른 칸으로 포커스
function Split-WtMemoRight {
    $p = Get-WtMemoActivePane
    if (-not $p) { return }
    if ($script:panes.Count -gt 1) {
        $other = Get-WtMemoOtherPane $p
        Set-WtMemoActivePane $other
        if ($other.Current) { $null = Set-WtMemoEditorFocus $other.Editor }
        return
    }
    if ($p.Current) { [void](Open-WtMemo $p.Current.Id 'side' $p) }
}

# 뒤로(-1) · 앞으로(1). 탭마다 기록이 따로 있다
function Move-WtMemoHistory([int]$Step) {
    $p = Get-WtMemoActivePane
    if (-not $p -or -not $p.Current) { return }
    $tab = $p.Current
    # if 식으로 받으면 목록이 풀려 나오므로 그대로 대입한다
    if ($Step -lt 0) { $from = $tab.Back; $to = $tab.Forward } else { $from = $tab.Forward; $to = $tab.Back }
    while ($from.Count -and -not (Get-WtMemoById $from[$from.Count - 1])) { $from.RemoveAt($from.Count - 1) }
    if (-not $from.Count) { return }
    if (-not (Save-WtMemoNow)) { return }
    Save-WtMemoPaneState $p
    $target = $from[$from.Count - 1]
    $from.RemoveAt($from.Count - 1)
    $to.Add($tab.Id)
    $tab.Id = $target
    $tab.State = $null
    Show-WtMemoPane $p
    Update-WtMemoTabTexts
    Sync-WtMemoListSelection
    Save-WtMemoTabs
}

# 지운 메모의 탭을 모든 칸에서 닫는다 (저장은 이미 한 뒤). 지금 탭이 바뀐 칸만 다시 채운다
function Close-WtMemoTabsFor([string]$Id) {
    $changed = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($p in @($script:panes)) {
        $hits = @($p.Tabs | Where-Object { $_.Id -eq $Id })
        if (-not $hits.Count) { continue }
        foreach ($t in $hits) {
            $wasCurrent = [object]::ReferenceEquals($p.Current, $t)
            $i = $p.Tabs.IndexOf($t)
            $p.Tabs.RemoveAt($i)
            if ($wasCurrent) {
                $p.Dirty = $false
                $p.Current = if ($p.Tabs.Count) { $p.Tabs[[Math]::Min($i, $p.Tabs.Count - 1)] } else { $null }
                $changed.Add($p)
            }
        }
        Update-WtMemoTabStrip $p
    }
    Update-WtMemoPaneLayout
    foreach ($p in $changed) { if ($script:panes.Contains($p)) { Show-WtMemoPane $p } }
    Update-WtMemoTabStyles
}

# 설정에 남은 탭을 불러온다. 지워진 메모 id는 뺀다. 남은 것이 없으면 최근 메모 하나를 연다
function Restore-WtMemoTabs {
    $present = @{}
    foreach ($m in $script:items) { $present[[string]$m.id] = $true }
    $v = Get-WtSetting 'memo.tabs'
    $specs = @()
    $activeIndex = 0
    try {
        if ($v) {
            $specs = @(@($v.panes) | Where-Object { $_ } | Select-Object -First 2)
            if ($null -ne $v.ratio) { $script:ratio = [Math]::Max(0.2, [Math]::Min(0.8, [double]$v.ratio)) }
            if ($null -ne $v.active) { $activeIndex = [int]$v.active }
        }
    } catch { $specs = @() }
    $built = 0
    foreach ($spec in $specs) {
        $ids = [System.Collections.Generic.List[string]]::new()
        foreach ($x in @($spec.tabs)) { $s = [string]$x; if ($present.ContainsKey($s) -and -not $ids.Contains($s)) { $ids.Add($s) } }
        if (-not $ids.Count) { continue }
        if ($built -gt 0) { Add-WtMemoPane }
        $pane = Get-WtMemoLastPane
        foreach ($s in $ids) { $pane.Tabs.Add((New-WtMemoTab $s)) }
        $cur = 0
        try { $cur = [int]$spec.current } catch { $cur = 0 }
        $pane.Current = $pane.Tabs[[Math]::Max(0, [Math]::Min($cur, $pane.Tabs.Count - 1))]
        $built++
    }
    if (-not $built -and $script:items.Count) {
        $t = New-WtMemoTab ([string]$script:items[0].id)
        $script:panes[0].Tabs.Add($t)
        $script:panes[0].Current = $t
    }
    $script:active = [Math]::Max(0, [Math]::Min($activeIndex, $script:panes.Count - 1))
    foreach ($p in $script:panes) { Update-WtMemoTabStrip $p; Show-WtMemoPane $p }
    Update-WtMemoSplit
    $script:restored = $true
    Save-WtMemoTabs
}

# ---- 저장 -------------------------------------------------------------------------------------

# 저장 표시: 시간이 아니라 저장 통로의 memo.json 상태(받아들인 내용이 파일에 쓰였는지)로 정한다. @(상태, 설명)
function Get-WtMemoSaveLook {
    $st = Get-WtDataWriteStatus (Get-WtStorePath 'memo')
    switch ($st.State) {
        'writing' { @('writing', '') }
        'failed' { @('error', "$($st.Message) Ctrl+S로 다시 저장합니다.") }
        default { @('saved', '') }
    }
}

# 고친 칸이 없는 칸의 저장 표시를 저장 통로 상태에 맞춘다
function Update-WtMemoSaveStatus {
    if (-not $script:ui.Count) { return }
    $look = Get-WtMemoSaveLook
    foreach ($p in $script:panes) { if ($p.Current -and -not $p.Dirty) { Set-WtMemoStatus $p $look[0] $look[1] } }
}

# 고친 칸을 모두 바로 저장한다. 저장 시각 · 탭 제목 · 목록도 고친다. 편집 중인 메모를 찾지 못하면 $false (고친 표시는 남긴다).
# 쓰는 중이거나 쓰지 못해도 저장 통로가 이 내용을 가지고 있으므로 $true다 (표시: 「저장하는 중」 → 「자동 저장됨」, 또는 「저장하지 못했습니다」).
# -Retry(Ctrl+S): 고친 칸이 없어도, 늦게 실패해 앱이 가지고 있는 메모 내용이 있으면 다시 써 본다
function Save-WtMemoNow([switch]$Retry) {
    if ($script:saveTimer) { $script:saveTimer.Stop() }
    $dirty = @($script:panes | Where-Object { $_.Dirty })
    if (-not $dirty.Count) {
        if ($Retry -and (Get-WtDataWriteStatus (Get-WtStorePath 'memo')).State -eq 'failed') {
            try { Resume-WtDataWrites (Get-WtStorePath 'memo') } catch { }
            Update-WtMemoSaveStatus
        }
        return $true
    }
    # 같은 메모를 두 칸에서 고쳤으면 포커스가 있는 칸의 글을 마지막에 써서 그 글이 남게 한다
    $activePane = Get-WtMemoActivePane
    $ordered = @($dirty | Where-Object { -not [object]::ReferenceEquals($_, $activePane) }) + @($dirty | Where-Object { [object]::ReferenceEquals($_, $activePane) })
    $byId = [ordered]@{}
    foreach ($p in $ordered) {
        $m = if ($p.Current) { Get-WtMemoById $p.Current.Id } else { $null }
        if (-not $m) { Set-WtMemoStatus $p 'error' '편집 중인 메모를 찾을 수 없습니다.'; return $false }
        $candidate = if ($byId.Contains([string]$m.id)) { $byId[[string]$m.id] } else { $m.PSObject.Copy() }
        [void](Set-WtMemoContent $candidate $p.TitleBox.Text (Get-WtMemoEditorText $p.Editor))
        $byId[[string]$m.id] = $candidate
    }
    $next = @(foreach ($item in $script:items) { if ($byId.Contains([string]$item.id)) { $byId[[string]$item.id] } else { $item } })
    try { Save-WtMemoItems $next }
    catch {
        $msg = $_.Exception.Message
        foreach ($p in $dirty) { Set-WtMemoStatus $p 'error' $msg }
        return $false
    }
    foreach ($p in $dirty) { $p.Dirty = $false }
    $script:items = @(Get-WtMemoSorted $next)
    $script:viewStamp = Get-WtMemoViewStamp
    # 같은 메모를 연 다른 칸은 글을 다시 불러온다 (그 칸은 포커스가 없어 고치는 중이 아님)
    $look = Get-WtMemoSaveLook
    foreach ($p in $script:panes) {
        if (-not $p.Current -or -not $byId.Contains([string]$p.Current.Id)) { continue }
        Update-WtMemoPaneContent $p
        Set-WtMemoStatus $p $look[0] $look[1]
    }
    Update-WtMemoTabTexts
    Update-WtMemoList -KeepCurrent
    $true
}

function Set-WtMemoDirty($Pane) {
    if (-not $Pane -or $Pane.Loading -or -not $Pane.Current) { return }
    $Pane.Dirty = $true
    Set-WtMemoStatus $Pane 'dirty'
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
}

# ---- 메모 만들기 · 지우기 ---------------------------------------------------------------------

# 새 메모를 만들어 연다. -Edit: 새 메모 버튼 · Ctrl+N (읽기 모드면 편집으로 바꾸고 제목칸으로)
function Add-WtMemo([string]$Title = '', [string]$How = 'tab', $Pane, [switch]$History, [switch]$Edit) {
    if (-not (Save-WtMemoNow)) { return $null }
    $m = New-WtMemo
    if ($Title) { $m.title = $Title }
    $next = @($m) + @($script:items)
    try { Save-WtMemoItems $next } catch { Show-WtError $_ '새 메모 저장'; return $null }
    $script:items = $next
    $script:viewStamp = Get-WtMemoViewStamp
    if ($script:ui.Search.Text) { $script:ui.Search.Text = '' } else { Update-WtMemoList }
    [void](Open-WtMemo $m.id $How $Pane -History:$History)
    if ($Edit) {
        if ($script:mode -eq 'read') { Set-WtMemoMode $script:editMode }
        $p = Get-WtMemoActivePane
        if ($p) { [void]$p.TitleBox.Focus() }
    }
    $m
}

function Remove-WtMemoCurrent($Pane) {
    if (-not $Pane) { $Pane = Get-WtMemoActivePane }
    if (-not (Save-WtMemoNow)) { return }
    if (-not $Pane -or -not $Pane.Current) { return }
    $m = Get-WtMemoById $Pane.Current.Id
    if (-not $m) { return }
    $index = [array]::IndexOf(@($script:items), $m)
    $next = @($script:items | Where-Object { $_.id -ne $m.id })
    try { Save-WtMemoItems $next } catch { Show-WtError $_ '메모 삭제'; return }
    $script:items = $next
    $script:viewStamp = Get-WtMemoViewStamp
    $script:rowCache.Remove($m.id)
    $script:lastDeleted = @{ Memo = $m; Index = $index }
    $paneIndex = $script:panes.IndexOf($Pane)
    Close-WtMemoTabsFor $m.id
    Update-WtMemoList
    Save-WtMemoTabs
    # 되돌리기: 10초 동안 실행 취소 버튼 (지운 칸 아래에, 그 칸이 없어졌으면 첫 칸 아래에)
    $bar = $script:ui.UndoBar
    if ($bar.Parent) { $bar.Parent.Content = $null }
    $script:panes[[Math]::Max(0, [Math]::Min($paneIndex, $script:panes.Count - 1))].UndoHost.Content = $bar
    $script:ui.UndoText.Text = "'$($m.title)' 삭제함"
    $bar.Visibility = 'Visible'
    $script:undoTimer.Stop()
    $script:undoTimer.Start()
}

function Restore-WtMemoDeleted {
    if (-not (Save-WtMemoNow)) { return }
    $d = $script:lastDeleted
    if (-not $d) { return }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($x in $script:items) { $list.Add($x) }
    $list.Insert([Math]::Min([Math]::Max(0, $d.Index), $list.Count), $d.Memo)
    $next = @(Get-WtMemoSorted $list.ToArray())
    try { Save-WtMemoItems $next } catch { Show-WtError $_ '삭제 실행 취소'; return }
    $script:items = $next
    $script:viewStamp = Get-WtMemoViewStamp
    $script:lastDeleted = $null
    $script:ui.UndoBar.Visibility = 'Collapsed'
    Update-WtMemoList
    [void](Open-WtMemo $d.Memo.id 'tab')
}

# ---- 모드 (편집 · 원문 · 읽기) ----------------------------------------------------------------

function Set-WtMemoMode([string]$Mode) {
    if ($script:modeUpdating) { return }
    if ($Mode -notin 'live', 'source', 'read') { $Mode = 'live' }
    if ($Mode -ne $script:mode -and -not (Save-WtMemoNow)) { Update-WtMemoModeButtons; return }
    if ($Mode -ne 'read') { $script:editMode = $Mode }
    $script:mode = $Mode
    if ([string](Get-WtSetting 'memo.mode') -cne $Mode) { try { $null = Set-WtSetting 'memo.mode' $Mode } catch { } }
    foreach ($p in $script:panes) { Update-WtMemoPaneMode $p }
    Update-WtMemoModeButtons
}

function Update-WtMemoModeButtons {
    $script:modeUpdating = $true
    try { foreach ($rb in $script:ui.ModeButtons) { $rb.IsChecked = ([string]$rb.Tag.Value -eq $script:mode) } }
    finally { $script:modeUpdating = $false }
}

# Ctrl+E: 편집(편집 · 원문) ↔ 읽기
function Switch-WtMemoRead { Set-WtMemoMode $(if ($script:mode -eq 'read') { $script:editMode } else { 'read' }) }

# Ctrl+/: 원문 ↔ 편집
function Switch-WtMemoSource { Set-WtMemoMode $(if ($script:mode -eq 'source') { 'live' } else { 'source' }) }

# ---- 링크 · 빠른 이동 --------------------------------------------------------------------------

function Get-WtMemoTitles { @($script:items | ForEach-Object { [string]$_.title } | Where-Object { $_ }) }

# 본문의 링크를 눌렀을 때. [[제목]]은 제목이 같은 메모를 열고(없으면 그 제목으로 만든다), #태그는 그 태그로 찾는다. 처리했으면 $true
function Invoke-WtMemoLink($Ed, $Link, [string]$How = 'here') {
    $pane = if ($Ed) { Get-WtMemoPaneOf $Ed } else { $null }
    if (-not $pane) { $pane = Get-WtMemoActivePane }
    if ($How -notin 'here', 'tab', 'side') { $How = 'here' }
    switch ($Link.Kind) {
        'wiki' {
            $name = ([string]$Link.Target -split '#')[0].Trim()
            if (-not $name) { return $false }   # [[#제목]]: 같은 글 안 이동은 보기가 한다
            $m = $script:items | Where-Object { ([string]$_.title).Trim() -eq $name } | Select-Object -First 1
            if ($m) { [void](Open-WtMemo $m.id $How $pane -History) }
            else { [void](Add-WtMemo -Title $name -How $How -Pane $pane -History) }
            return $true
        }
        'tag' {
            $script:ui.Search.Text = "#$($Link.Target)"
            return $true
        }
    }
    $false
}

function Open-WtMemoQuick {
    $q = $script:ui.Quick
    $script:quickOpen = $true
    $q.Host.Visibility = 'Visible'
    if ($q.Box.Text) { $q.Box.Text = '' } else { Update-WtMemoQuickResults }
    [void]$q.Box.Focus()
}

function Close-WtMemoQuick([switch]$Refocus) {
    if (-not $script:quickOpen) { return }
    $script:quickOpen = $false
    $script:ui.Quick.Host.Visibility = 'Collapsed'
    if ($Refocus) {
        $p = Get-WtMemoActivePane
        if ($p -and $p.Current) { $null = Set-WtMemoEditorFocus $p.Editor }
    }
}

function Update-WtMemoQuickResults {
    $q = $script:ui.Quick
    $query = ([string]$q.Box.Text).Trim()
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($m in @(Find-WtMemoQuick $script:items $query)) {
        $sub = Format-WtMemoTime ([string]$m.updated)
        $snip = Get-WtMarkdownSnippet ([string]$m.body) 80
        if ($snip) { $sub = "$sub · $snip" }
        $rows.Add([pscustomobject]@{ Id = [string]$m.id; Title = (Get-WtMemoTitle $m.id); Sub = $sub; Create = $false })
    }
    $exact = $script:items | Where-Object { ([string]$_.title).Trim() -eq $query } | Select-Object -First 1
    if ($query -and -not $exact) { $rows.Add([pscustomobject]@{ Id = ''; Title = "새 메모 만들기: $query"; Sub = ''; Create = $true; Query = $query }) }
    $q.List.ItemsSource = $rows.ToArray()
    if ($rows.Count) { $q.List.SelectedIndex = 0 }
}

function Move-WtMemoQuickSelection([int]$Step) {
    $l = $script:ui.Quick.List
    if (-not $l.Items.Count) { return }
    $l.SelectedIndex = [Math]::Max(0, [Math]::Min($l.Items.Count - 1, $l.SelectedIndex + $Step))
    $l.ScrollIntoView($l.SelectedItem)
}

# 빠른 이동에서 고른 것을 연다. Enter 지금 탭 · Ctrl+Enter 새 탭
function Invoke-WtMemoQuickPick([switch]$NewTab) {
    $row = $script:ui.Quick.List.SelectedItem
    if (-not $row) { return }
    $how = if ($NewTab) { 'tab' } else { 'here' }
    Close-WtMemoQuick
    if ($row.Create) { [void](Add-WtMemo -Title $row.Query -How $how -History) }
    else { [void](Open-WtMemo $row.Id $how -History) }
    $p = Get-WtMemoActivePane
    if ($p -and $p.Current) { $null = Set-WtMemoEditorFocus $p.Editor }
}

# ---- 목록 -------------------------------------------------------------------------------------

function New-WtMemoListItem($Memo) {
    $cached = $script:rowCache[$Memo.id]
    if ($cached -and $cached.Day -eq [datetime]::Today -and $cached.Body -ceq $Memo.body -and $cached.Title -ceq $Memo.title -and $cached.Updated -eq $Memo.updated) { return $cached.Row }
    $snippet = if ($cached -and $cached.Body -ceq $Memo.body) { $cached.Row.SnippetValue } else { $null }
    $row = [pscustomobject]@{ Id = $Memo.id; Title = $Memo.title; Stamp = Format-WtMemoTime $Memo.updated; SnippetSource = [string]$Memo.body; SnippetValue = $snippet }
    # 가상 목록에서 보이는 행이 값을 읽을 때만 요약한다. 지역 변수는 캡처하지 않고 행 자체에 둔다.
    $row | Add-Member -MemberType ScriptProperty -Name Snippet -Value {
        if ($null -eq $this.SnippetValue) { $this.SnippetValue = Get-WtMarkdownSnippet $this.SnippetSource }
        $this.SnippetValue
    }
    $script:rowCache[$Memo.id] = @{ Body = $Memo.body; Title = $Memo.title; Updated = $Memo.updated; Day = [datetime]::Today; Row = $row }
    $row
}

# 목록 선택은 포커스가 있는 칸의 지금 탭 메모를 따라간다
function Sync-WtMemoListSelection {
    $list = $script:ui.List
    if (-not $list) { return }
    $keep = Get-WtMemoCurrentId
    $script:listUpdating = $true
    try { $list.SelectedItem = $list.Items | Where-Object { [string]$_.Id -eq $keep } | Select-Object -First 1 }
    finally { $script:listUpdating = $false }
}

# 목록에서 메모 하나를 고른다(클릭과 같음: 지금 탭에서 연다). 검색에 걸러져 안 보이면 검색을 비운다
function Select-WtMemoItem([string]$Id) {
    $list = $script:ui.List
    $li = $list.Items | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1
    if (-not $li) {
        $script:ui.Search.Text = ''
        $li = $list.Items | Where-Object { [string]$_.Id -eq $Id } | Select-Object -First 1
    }
    if ($li) {
        $list.SelectedItem = $li
        $list.ScrollIntoView($li)
    }
}

# 목록을 다시 그린다. 열린 메모는 다시 채우지 않는다 (편집 중 글자 위치 유지)
function Update-WtMemoList([switch]$KeepCurrent) {
    if ($script:listUpdating) { return }
    $list = $script:ui.List
    $keep = Get-WtMemoCurrentId
    # 저장한 뒤 다시 그릴 때는 열려 있는 메모가 검색어에서 빠져도 남긴다 (고치는 중에 사라지지 않게)
    $shown = @(Find-WtMemo $script:items $script:ui.Search.Text)
    if ($KeepCurrent -and $keep -and -not ($shown | Where-Object { $_.id -eq $keep })) {
        $shown = @($script:items | Where-Object { $_.id -eq $keep -or $shown -contains $_ })
    }
    $script:listUpdating = $true
    try {
        $rows = @(foreach ($m in $shown) { New-WtMemoListItem $m })
        $same = $list.Items.Count -eq $rows.Count
        for ($i = 0; $same -and $i -lt $rows.Count; $i++) { $same = [object]::ReferenceEquals($list.Items[$i], $rows[$i]) }
        if (-not $same) { $list.ItemsSource = $rows }
    } finally { $script:listUpdating = $false }
    Sync-WtMemoListSelection
    $script:listQuery = [string]$script:ui.Search.Text
}

function Get-WtMemoViewStamp { @((Get-WtStoreStamp 'memo'), [datetime]::Today.Ticks) -join '|' }

# ---- 단축키 -----------------------------------------------------------------------------------

# 메모 화면의 단축키. 처리했으면 $true. 편집기 단축키(Ctrl+B · I · K · L · F, Alt+↑↓ 등)와 겹치지 않는다
function Invoke-WtMemoKey([System.Windows.Input.Key]$Key, [System.Windows.Input.ModifierKeys]$Mods) {
    $ctrl = ($Mods -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
    $shift = ($Mods -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0
    $alt = ($Mods -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0
    # 같은 값에 이름이 여럿인 키(Enter = Return, \ = Oem5 = OemPipe …)는 이름 하나로 맞춘다
    $name = switch ([int]$Key) {
        ([int][System.Windows.Input.Key]::Enter) { 'Enter' }
        ([int][System.Windows.Input.Key]::Oem5) { 'Backslash' }          # \ (한국어 키보드의 ₩)
        ([int][System.Windows.Input.Key]::OemBackslash) { 'Backslash' }
        ([int][System.Windows.Input.Key]::Oem2) { 'Slash' }              # /
        ([int][System.Windows.Input.Key]::Divide) { 'Slash' }
        default { [string]$Key }
    }
    if ($script:quickOpen) {
        switch ($name) {
            'Escape' { Close-WtMemoQuick -Refocus; return $true }
            'Up' { Move-WtMemoQuickSelection -1; return $true }
            'Down' { Move-WtMemoQuickSelection 1; return $true }
            'Enter' { Invoke-WtMemoQuickPick -NewTab:$ctrl; return $true }
        }
    }
    if ($alt -and -not $ctrl -and -not $shift) {
        if ($name -eq 'Left') { Move-WtMemoHistory -1; return $true }
        if ($name -eq 'Right') { Move-WtMemoHistory 1; return $true }
        return $false
    }
    if (-not $ctrl -or $alt) { return $false }
    switch ($name) {
        'N' { if ($shift) { return $false }; [void](Add-WtMemo -Edit); return $true }
        'S' { [void](Save-WtMemoNow -Retry); return $true }
        'W' { Close-WtMemoCurrentTab; return $true }
        'Tab' { Select-WtMemoNextTab $(if ($shift) { -1 } else { 1 }); return $true }
        'T' { if (-not $shift) { return $false }; Restore-WtMemoClosedTab; return $true }
        'O' { if ($script:quickOpen) { Close-WtMemoQuick -Refocus } else { Open-WtMemoQuick }; return $true }
        'F' {
            if (-not $shift) { return $false }   # Ctrl+F는 편집기 찾기
            Close-WtMemoQuick
            [void]$script:ui.Search.Focus(); $script:ui.Search.SelectAll()
            return $true
        }
        'E' { Switch-WtMemoRead; return $true }
        'Backslash' { Split-WtMemoRight; return $true }
        'Slash' { Switch-WtMemoSource; return $true }
    }
    $false
}

# ---- 화면 만들기 ------------------------------------------------------------------------------

function New-WtMemoView {
    $script:viewStamp = $null
    $script:listQuery = $null
    $script:restored = $false
    $script:quickOpen = $false
    $script:active = 0
    $script:panes = [System.Collections.Generic.List[hashtable]]::new()
    $script:closed = [System.Collections.Generic.List[hashtable]]::new()
    $script:mode = Get-WtMemoModeSetting
    if ($script:mode -ne 'read') { $script:editMode = $script:mode }
    $script:ui = @{}
    if (-not $script:saveTimer) {
        $script:saveTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:saveTimer.Interval = [TimeSpan]::FromMilliseconds(800)
        $script:saveTimer.Add_Tick({ [void](Save-WtMemoNow) })
        $script:undoTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:undoTimer.Interval = [TimeSpan]::FromSeconds(10)
        $script:undoTimer.Add_Tick({ param($s, $e) $s.Stop(); $script:ui.UndoBar.Visibility = 'Collapsed'; $script:lastDeleted = $null })
    }

    $page = New-WtPage -Fill
    # 오른쪽 위: 모드(모든 칸에 같이) + 새 메모
    $tools = New-WtStack Horizontal 12
    $mode = New-WtSegmented @(@('live', '편집'), @('source', '원문'), @('read', '읽기')) $script:mode 'WtMemoMode' {
        param($value)
        Set-WtMemoMode $value
    }
    $modeTips = @{ live = '편집 (Ctrl+E)'; source = '원문 (Ctrl+/)'; read = '읽기 (Ctrl+E)' }
    foreach ($rb in @($mode.Child.Children)) { $rb.ToolTip = $modeTips[[string]$rb.Tag.Value] }
    $mode.VerticalAlignment = 'Center'
    [void](Add-WtChild $tools $mode)
    $add = New-WtButton '새 메모' -Kind Primary -Icon 0xE710 -ToolTip '새 메모 (Ctrl+N)'
    $add.Add_Click({ [void](Add-WtMemo -Edit) })
    [void](Add-WtChild $tools $add)
    $header = New-WtPageHeader '메모' '' $tools
    [System.Windows.Controls.DockPanel]::SetDock($header, 'Top')
    [void]$page.Panel.Children.Add($header)

    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new()
    $c1.Width = [System.Windows.GridLength]::new(320)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new()
    $c2.Width = [System.Windows.GridLength]::new(1, 'Star')
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)

    # 왼쪽: 검색 + 목록
    $left = New-WtCard
    $left.Padding = [System.Windows.Thickness]::new(12)
    $left.Margin = [System.Windows.Thickness]::new(0, 0, 16, 0)
    $ldock = [System.Windows.Controls.DockPanel]::new()
    $sb = New-WtSearchBox '검색 (제목 · 본문)'
    $search = $sb.Box
    $search.ToolTip = '띄어 쓰면 낱말이 모두 들어간 메모만 (#태그도 찾음) (Ctrl+Shift+F)'
    $search.Add_TextChanged({ Update-WtMemoList })
    $sb.Root.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [System.Windows.Controls.DockPanel]::SetDock($sb.Root, 'Top')
    [void]$ldock.Children.Add($sb.Root)
    $list = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $list 'Memo.List'
    # 클릭 · 방향키: 지금 탭에서 연다
    $list.Add_SelectionChanged({
            param($s, $e)
            if ($script:listUpdating -or -not $s.SelectedItem) { return }
            $memoId = [string]$s.SelectedItem.Id
            if ($memoId -eq (Get-WtMemoCurrentId)) { return }
            if (@(Open-WtMemo $memoId 'here')[-1] -ne $true) { Sync-WtMemoListSelection }
        })
    # Ctrl+클릭 · 가운데 클릭: 새 탭. 우클릭: 메뉴 (선택은 바꾸지 않는다)
    $list.Add_PreviewMouseDown({
            param($s, $e)
            $c = $null
            try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource) } catch { }
            if (-not $c -or -not $c.DataContext) { return }
            $memoId = [string]$c.DataContext.Id
            $ctrlDown = ((Get-WtMemoModifiers) -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
            if ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Middle -or ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Left -and $ctrlDown)) {
                [void](Open-WtMemo $memoId 'tab')
                $e.Handled = $true
            } elseif ($e.ChangedButton -eq [System.Windows.Input.MouseButton]::Right) {
                $script:listMenuId = $memoId
                $e.Handled = $true
            }
        })
    $listMenu = New-WtContextMenu
    foreach ($spec in @(@('tab', '새 탭에서 열기', 'Ctrl+클릭'), @('side', '오른쪽에 열기', ''))) {
        $mi = [System.Windows.Controls.MenuItem]::new()
        $mi.Header = $spec[1]
        $mi.InputGestureText = $spec[2]
        $mi.Tag = $spec[0]
        $mi.Add_Click({ param($s, $e) if ($s.Parent.Tag) { [void](Open-WtMemo ([string]$s.Parent.Tag) ([string]$s.Tag)) } })
        [void]$listMenu.Items.Add($mi)
    }
    $list.ContextMenu = $listMenu
    $list.Add_ContextMenuOpening({
            param($s, $e)
            $memoId = if ($script:listMenuId) { $script:listMenuId } elseif ($s.SelectedItem) { [string]$s.SelectedItem.Id } else { '' }
            $script:listMenuId = ''
            if (-not $memoId) { $e.Handled = $true; return }
            $s.ContextMenu.Tag = $memoId
        })
    [void]$ldock.Children.Add($list)
    $left.Child = $ldock
    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$grid.Children.Add($left)

    # 오른쪽: 칸 1~2개 + 사이 경계
    $paneGrid = [System.Windows.Controls.Grid]::new()
    $pc0 = [System.Windows.Controls.ColumnDefinition]::new()
    $pc1 = [System.Windows.Controls.ColumnDefinition]::new()
    $pc2 = [System.Windows.Controls.ColumnDefinition]::new()
    $paneGrid.ColumnDefinitions.Add($pc0)
    $paneGrid.ColumnDefinitions.Add($pc1)
    $paneGrid.ColumnDefinitions.Add($pc2)
    $splitter = [System.Windows.Controls.GridSplitter]::new()
    Set-WtStyle $splitter 'Memo.Splitter'
    $splitter.ToolTip = '끌어서 두 칸의 폭을 바꿉니다'
    $splitter.Add_DragCompleted({
            $w0 = $script:ui.PaneCol0.ActualWidth; $w2 = $script:ui.PaneCol2.ActualWidth
            if ($w0 + $w2 -gt 0) { $script:ratio = $w0 / ($w0 + $w2) }
            Update-WtMemoSplit
            Save-WtMemoTabs
        })
    [System.Windows.Controls.Grid]::SetColumn($splitter, 1)
    [void]$paneGrid.Children.Add($splitter)
    [System.Windows.Controls.Grid]::SetColumn($paneGrid, 1)
    [void]$grid.Children.Add($paneGrid)

    # 실행 취소 막대: 지운 칸 아래에 붙인다
    $undoBar = New-WtStack Horizontal 8
    $undoBar.Visibility = 'Collapsed'
    $undoText = New-WtText '' 'T.Sub'
    $undoText.VerticalAlignment = 'Center'
    $undo = New-WtButton '실행 취소' -Kind Link -Icon 0xE7A7 -ToolTip '삭제 되돌리기'
    $undo.Add_Click({ Restore-WtMemoDeleted })
    [void](Add-WtChild $undoBar $undoText)
    [void](Add-WtChild $undoBar $undo)

    # 빠른 이동 (Ctrl+O): 화면 위에 겹쳐 뜬다
    $qHost = [System.Windows.Controls.Grid]::new()
    Set-WtStyle $qHost 'Memo.QuickHost'
    $qHost.Visibility = 'Collapsed'
    [System.Windows.Controls.Grid]::SetColumnSpan($qHost, 2)
    [System.Windows.Controls.Panel]::SetZIndex($qHost, 1)
    $qShadow = [System.Windows.Controls.Border]::new()
    Set-WtStyle $qShadow 'Overlay.Shadow'
    $qPanel = [System.Windows.Controls.Border]::new()
    Set-WtStyle $qPanel 'Memo.QuickPanel'
    $qDock = [System.Windows.Controls.DockPanel]::new()
    $qsb = New-WtSearchBox '메모 이름으로 이동'
    $qsb.Box.ToolTip = 'Enter 열기 · Ctrl+Enter 새 탭 · Esc 닫기'
    $qsb.Box.Add_TextChanged({ Update-WtMemoQuickResults })
    [System.Windows.Controls.DockPanel]::SetDock($qsb.Root, 'Top')
    [void]$qDock.Children.Add($qsb.Root)
    $qList = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $qList 'Memo.QuickList'
    $qList.Focusable = $false
    $qList.Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $c = $null
            try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource) } catch { }
            if (-not $c) { return }
            $s.SelectedItem = $c.DataContext
            Invoke-WtMemoQuickPick -NewTab:(((Get-WtMemoModifiers) -band [System.Windows.Input.ModifierKeys]::Control) -ne 0)
            $e.Handled = $true
        })
    [void]$qDock.Children.Add($qList)
    $qPanel.Child = $qDock
    [void]$qHost.Children.Add($qShadow)
    [void]$qHost.Children.Add($qPanel)
    $qHost.Add_IsKeyboardFocusWithinChanged({ param($s, $e) if (-not $e.NewValue -and $script:quickOpen) { Close-WtMemoQuick } })
    [void]$grid.Children.Add($qHost)
    [void]$page.Panel.Children.Add($grid)

    # 빠른 이동 밖을 누르면 닫는다
    $page.Root.Add_PreviewMouseDown({ if ($script:quickOpen -and -not $script:ui.Quick.Host.IsMouseOver) { Close-WtMemoQuick } })
    # 메모 화면 안 단축키
    $page.Root.Add_PreviewKeyDown({
            param($s, $e)
            $key = if ($e.Key -eq [System.Windows.Input.Key]::System) { $e.SystemKey } else { $e.Key }
            $r = Invoke-WtMemoKey $key (Get-WtMemoModifiers)
            if (@($r)[-1] -eq $true) { $e.Handled = $true }
        })

    $script:ui = @{
        Search = $search; List = $list; PaneGrid = $paneGrid; PaneCol0 = $pc0; PaneCol1 = $pc1; PaneCol2 = $pc2; Splitter = $splitter
        UndoBar = $undoBar; UndoText = $undoText; Add = $add
        ModeButtons = @($mode.Child.Children)
        Quick = @{ Host = $qHost; Box = $qsb.Box; List = $qList }
    }
    [void](Add-WtMemoPane)
    $page.Root
}

function Update-WtMemoView {
    if (-not (Save-WtMemoNow)) { return }
    $stamp = Get-WtMemoViewStamp
    if ($script:viewStamp -cne $stamp) {
        $script:items = @(Get-WtMemoSorted (Get-WtMemoItems))
        $present = @{}
        foreach ($item in $script:items) { $present[$item.id] = $true }
        foreach ($k in @($script:rowCache.Keys)) { if (-not $present.ContainsKey($k)) { $script:rowCache.Remove($k) } }
        $script:viewStamp = $stamp
        if ($script:restored) {
            # 밖에서 바뀌었다 (예전 데이터 다시 가져오기 등): 없어진 메모의 탭을 닫고 열린 칸을 다시 채운다
            foreach ($p in @($script:panes)) {
                foreach ($t in @($p.Tabs)) { if (-not $present.ContainsKey([string]$t.Id)) { Close-WtMemoTabsFor $t.Id } }
            }
            foreach ($p in $script:panes) { Save-WtMemoPaneState $p; Show-WtMemoPane $p }
            Update-WtMemoTabTexts
            Save-WtMemoTabs
        }
    }
    if (-not $script:restored) { Restore-WtMemoTabs }
    Update-WtMemoList
}

function New-WtMemoHomeCard {
    $key = @((Get-WtStoreStamp 'memo'), [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:homeKey -ceq $key -and $script:homeCard -and -not $script:homeCard.Parent) { return $script:homeCard }
    $items = @(Get-WtMemoSorted (Get-WtMemoItems))
    $recent = @($items | Select-Object -First 3)
    $card = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '최근 메모' '' '메모 열기' 'memo'))
    foreach ($m in $recent) {
        $t = New-WtStack Vertical 2
        $name = New-WtText $m.title 'T.Strong'
        $name.TextTrimming = 'CharacterEllipsis'
        $name.TextWrapping = 'NoWrap'
        [void](Add-WtChild $t $name)
        $snip = New-WtText (Get-WtMarkdownSnippet ([string]$m.body)) 'T.Sub'
        $snip.TextTrimming = 'CharacterEllipsis'
        $snip.TextWrapping = 'NoWrap'
        [void](Add-WtChild $t $snip)
        $when = New-WtText (Format-WtMemoTime $m.updated) 'T.Sub'
        [void](Add-WtChild $col (New-WtListRow @($when, $t)))
    }
    if (-not $items.Count) { [void](Add-WtChild $col (New-WtText '메모가 없습니다.' 'T.Sub')) }
    $card.Child = $col
    $script:homeCard = $card; $script:homeKey = $key
    $card
}

# ---- 도움말 -----------------------------------------------------------------------------------

$script:helpMd = $null
$script:helpRaw = $null

# 도움말의 마크다운 예시. 원문 · 보기를 바꿔 가며 문법을 본다
$script:markdownSample = @'
# 제목은 `#`, 소제목은 `##`

**굵게**, *기울임*, ~~취소선~~, ==형광펜==, `코드`, [링크](https://github.com)
[[메모 제목]]을 누르면 그 메모로, #태그 를 누르면 그 태그로 찾습니다.
줄을 한 번만 바꿔도 줄이 바뀝니다 (Obsidian과 같음).

- [x] 끝낸 일
- [ ] 할 일
- 목록
    1. 안쪽 번호 목록

> [!tip] 콜아웃
> `> [!종류] 제목`으로 씁니다. 종류: note · info · tip · success · question · warning · danger · bug · example · quote

> [!warning]- 접는 콜아웃 (눌러서 펼치기)
> `-`는 접힌 채로, `+`는 펼친 채로 시작합니다.

| 서버 | IP | 상태 |
|:--|:--|:-:|
| SRV-01 | 10.0.0.10 | 정상 |
| SRV-02 | 10.0.0.11 | 점검 |

```powershell
Get-Service | Where-Object Status -eq 'Running'   # 코드 블록은 [복사]로 한 번에 복사
```

```mermaid
flowchart LR
    A[요청] --> B{승인?}
    B -->|예| C[작업]
    B -->|아니오| D([반려])
```
'@

function New-WtMemoMarkdownHelpCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 8
    [void](Add-WtChild $col (New-WtCardHeader '마크다운'))
    [void](Add-WtChild $col (New-WtText '메모 본문은 마크다운으로 보입니다. 원문을 누르면 아래 보기를 만든 글이 나옵니다.' 'T.Sub'))
    $mode = New-WtSegmented @(@('preview', '보기'), @('raw', '원문')) 'preview' 'WtHelpMd' {
        param($value)
        $script:helpMd.Visibility = if ($value -eq 'raw') { 'Collapsed' } else { 'Visible' }
        $script:helpRaw.Visibility = if ($value -eq 'raw') { 'Visible' } else { 'Collapsed' }
    }
    [void](Add-WtChild $col $mode)
    # 도움말에서는 [[링크]] · #태그가 갈 곳이 없으므로 무엇을 하는지만 알려 준다
    $script:helpMd = New-WtMarkdownView -OnLink {
        param($link)
        if ($link.Kind -eq 'wiki') { Show-WtMessage '메모에서 누르면 제목이 같은 메모를 엽니다.'; return $true }
        if ($link.Kind -eq 'tag') { Show-WtMessage '메모에서 누르면 이 태그로 찾습니다.'; return $true }
        $false
    }
    $script:helpMd.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    Set-WtMarkdownText $script:helpMd $script:markdownSample
    $script:helpRaw = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $script:helpRaw 'Reader'
    Set-WtResource $script:helpRaw 'FontFamily' 'Font.Mono'
    $script:helpRaw.Text = $script:markdownSample
    $script:helpRaw.Visibility = 'Collapsed'
    $script:helpRaw.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    [void](Add-WtChild $col $script:helpMd)
    [void](Add-WtChild $col $script:helpRaw)
    $card.Child = $col
    $card
}

# memo.json의 저장 상태가 바뀌면(쓰임 · 실패로 남음) 칸의 표시만 고친다. 다시 저장하지 않는다 (내용은 저장 통로가 가지고 있다)
Register-WtDataWriteHandler {
    param($path, $state)
    if ($script:ui.Count -and $path -ieq (Get-WtStorePath 'memo')) { Update-WtMemoSaveStatus }
}

Register-WtAddon -Id 'memo' -Title '메모' -Icon 0xE70B -Group '작업' -Order 40 -WarmUp Full `
    -NewView { New-WtMemoView } `
    -Refresh { param($view) Update-WtMemoView } `
    -HomeCard { New-WtMemoHomeCard } `
    -ImportLegacy { param($folder) Import-WtMemoLegacy $folder } `
    -SavePending { if ($script:ui.Count) { Save-WtMemoNow } else { $true } } `
    -OnExit { if ($script:ui.Count) { [void](Save-WtMemoNow) }; if ($script:saveTimer) { $script:saveTimer.Stop() }; if ($script:undoTimer) { $script:undoTimer.Stop() } } `
    -Help '메모는 쓰고 고칠 수 있습니다. 여러 메모를 탭으로 열어 두고, 오른쪽에 나눠 두 칸으로 볼 수 있습니다.' `
    -Shortcuts @(
        @('Ctrl + N', '새 메모 (새 탭)'), @('Ctrl + S', '바로 저장 (보통은 자동 저장)'), @('Ctrl + O', '빠른 이동 (메모 이름으로 찾아 열기)'),
        @('Ctrl + W', '탭 닫기'), @('Ctrl + Shift + T', '닫은 탭 다시 열기'), @('Ctrl + Tab / Ctrl + Shift + Tab', '다음 / 이전 탭'),
        @('Ctrl + \', '오른쪽에 나눠 열기 (나눴으면 다른 칸으로)'), @('Alt + ← / Alt + →', '뒤로 / 앞으로 (링크 · 빠른 이동으로 간 메모)'),
        @('Ctrl + E', '편집 / 읽기'), @('Ctrl + /', '편집 / 원문'), @('Ctrl + Shift + F', '목록 검색칸으로'),
        @('Ctrl + 클릭 · 가운데 클릭', '목록 · 링크를 새 탭에서 열기'),
        @('Ctrl + B / Ctrl + I', '굵게 / 기울임 (다시 누르면 풀기)'), @('Ctrl + K', '링크 만들기'), @('Alt + Shift + 5', '취소선'),
        @('` (글을 고르고)', '코드로 감싸기 (여러 줄이면 코드 블록)'), @('```', '줄 맨 앞에 치면 닫는 ``` 를 자동으로'),
        @('[[', '메모 링크 자동 완성 (↑↓ 고르기 · Enter)'), @('Enter', '목록 · 할 일 이어 쓰기 (빈 항목에서 Enter = 목록 끝)'),
        @('Tab / Shift + Tab', '목록 들여쓰기 / 내어쓰기'), @('Ctrl + L', '할 일 체크박스 넣기 · 완료 / 해제'),
        @('Alt + ↑ / Alt + ↓', '줄 옮기기'), @('Ctrl + F / Ctrl + H / F3', '찾기 / 바꾸기 / 다음 찾기'),
        @('Ctrl + Z / Ctrl + Y', '실행 취소 / 다시 실행'), @('Ctrl + Shift + V', '바꾸지 않고 붙여넣기'),
        @('붙여넣기', '글을 고르고 URL을 붙이면 링크, 파일 경로는 경로 링크로'), @('끌어 놓기', '탐색기의 파일 · 폴더를 놓으면 링크')) `
    -HelpCard { New-WtMemoMarkdownHelpCard }

Export-ModuleMember -Function Get-WtMemoItems, Get-WtMemoSorted, Find-WtMemo, Format-WtMemoTime, Import-WtMemoLegacy,
    New-WtMemo, Get-WtMemoTags, Set-WtMemoContent, Save-WtMemoItems

# 메모 탭: 목록 · 검색 · 열어 둔 메모 탭 · 창 나누기(칸 2개) · 빠른 이동 · 자동 저장 · 새 메모 · 삭제(실행 취소). 메모별 잠금은 다음에 옮긴다.
# 저장소 memo.json (schema 1). 항목:
#   id, title, body, tags[], lock($null=잠기지 않음. 나중에 'dpapi' | 'password'), created, updated
#   tags는 본문의 #태그를 저장할 때 모은 것이다.
# 화면: 왼쪽 목록 카드, 가운데 칸(pane) 1~2개, 오른쪽 목차 카드. 칸마다 탭 줄 · 제목 · 편집기(MemoEditor.psm1). 탭 하나 = 메모 하나.
#   목록은 검색창 + 조건 칩 + 보기 고르기 + 정렬이다. 칩과 검색창의 글을 합친 글 하나를 MemoData.psm1의 Find-WtMemo로 찾는다.
#   목록 클릭은 지금 탭에서, Ctrl+클릭 · 가운데 클릭은 새 탭에서 연다. [[메모 제목]]은 그 메모로(없으면 만든다), #태그는 그 태그 검색으로 간다.
# 설정: memo.mode (새 탭의 보기. live 편집 · source 원문 · read 읽기. 예전 값 edit → live, preview → read)
#       memo.tabs (열린 탭 · 탭마다 보기 · 칸 · 지금 탭 · 나눔 비율)
# 단축키(메모 화면 안)는 맨 아래 Register-WtAddon -Shortcuts. 편집 단축키(Ctrl+B · I · K · F 등)는 편집기가 처리한다.

$ErrorActionPreference = 'Stop'

$script:schema = 1
$script:memoStore = $null   # 읽은 원자료/버전. 저장 뒤에는 새 핸들로 바꾼다 (MemoData.psm1).
$script:items = @()
$script:panes = [System.Collections.Generic.List[hashtable]]::new()   # 칸. 칸 = @{ Tabs; Current; Dirty; Loading; Editor; 화면 요소 … }
$script:active = 0           # 포커스가 있는 칸 번호
$script:ratio = 0.5          # 두 칸일 때 왼쪽 칸 비율
$script:closed = [System.Collections.Generic.List[hashtable]]::new()  # 닫은 탭 (Ctrl+Shift+T)
$script:mode = 'live'        # 포커스가 있는 칸의 보기: live · source · read. 보기는 탭마다 기억한다
$script:editMode = 'live'    # 읽기에서 새 메모로 돌아갈 편집 보기
$script:restored = $false    # 설정에 남은 탭을 불러왔는지
$script:lastDeleted = $null  # 실행 취소용
$script:ui = @{}
$script:saveTimer = $null
$script:undoTimer = $null
$script:listUpdating = $false
$script:listMenuId = ''
$script:rowCache = @{}
$script:rowGetters = [scriptblock[]]@(
    { if ($null -eq $this.StampValue) { $this.StampValue = Format-WtMemoTime $this.Updated }; $this.StampValue },
    { if ($null -eq $this.SnippetValue) { $this.SnippetValue = Get-WtMarkdownSnippet $this.SnippetSource }; $this.SnippetValue },
    { if ($this.Snippet) { "$($this.Stamp) · $($this.Snippet)" } else { $this.Stamp } }
)
$script:quickOpen = $false
$script:memoIndex = $null    # 검색 색인. 다 만들어지기 전에는 $script:indexBuild가 들고 있다
$script:indexBuild = $null
$script:indexTimer = $null
$script:linkTimer = $null    # 연결 해석을 뒤에서 조금씩 한다
$script:linkFailed = $false
$script:linkWaitMs = 50      # 연결 조건으로 찾을 때 그 자리에서 기다리는 시간. 메모가 적으면 이 안에 끝난다
$script:listWaitLinks = $false   # 연결 해석이 끝나면 목록을 다시 그린다
$script:searchTimer = $null
$script:listChips = [System.Collections.Generic.List[hashtable]]::new()   # 조건 칩 @{ Query; Label }
$script:listView = 'normal'  # normal · pinned · recent · archived · all
$script:listSaved = $null    # 지금 쓰는 저장한 보기
$script:listSavedText = ''   # 그 보기를 불러온 때의 조건 글
$script:listSort = ''        # 비면 기본 정렬
$script:listDir = ''
$script:listResult = $null   # 지금 목록의 결과: @{ Count; Items | Find }
$script:listRows = $null     # 화면에 만든 줄
$script:tocKey = ''
$script:tocJump = $false
$script:openedStore = $null
$script:openedAt = @{}
$script:shortcutIds = $null   # 바로 가기 확인용 메모 id. memo.json 표식이 같으면 다시 읽지 않는다
$script:shortcutStamp = ''
$script:listPage = 40        # 한 번에 만드는 목록 줄 수

Register-WtSettingDefault 'memo.mode' 'live'
Register-WtSettingDefault 'memo.tabs' $null

# ---- 데이터 (WPF 없이) -------------------------------------------------------------------------

function Get-WtMemoItems {
    $script:memoStore = Open-WtMemoStore
    if ($script:memoStore.State -notin 'ok', 'missing') { throw $script:memoStore.Error }
    $prepared = Get-WtStorePreparation 'memo'
    $script:preparedMemo = if ($prepared -and $prepared.Value -and [object]::ReferenceEquals($script:memoStore.Doc, $prepared.Value.Document)) { $prepared.Value } else { $null }
    if ($script:preparedMemo) { $script:preparedMemo.Live; return }
    # 편집용 스칼라 칸을 저장 통로가 보유한 항목과 분리한다. 알려지지 않은 중첩 칸은 수정하지 않는다.
    (Get-WtMemoDetachedItems (Get-WtMemoLiveItems $script:memoStore.Items))
}

function Save-WtMemoItems([object[]]$Items) {
    if (-not $script:memoStore) { $script:memoStore = Open-WtMemoStore }
    $script:memoStore = Save-WtMemoDataItems -Store $script:memoStore -Items @($Items)
}

# 최근 고친 순서
function Get-WtMemoSorted([object[]]$Items) {
    (Get-WtMemoUpdatedOrder $Items)
}

function Format-WtMemoTime([string]$Stamp) {
    $t = [datetime]::MinValue
    if (-not [datetime]::TryParse($Stamp, [ref]$t)) { return $Stamp }
    if ($t.Date -eq [datetime]::Today) { return Format-WtDate $t "'오늘' HH:mm" }
    if ($t.Date -eq [datetime]::Today.AddDays(-1)) { return '어제' }
    Format-WtDate $t "M'/'d"
}

function Get-WtMemoStamp([datetime]$When) {
    Get-WtStamp ([DateTimeOffset]::new($When).ToOffset([timespan]::FromHours(9)))
}

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
    if (-not $t) { $t = $When.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
    $Memo.title = $t
    $Memo.body = $Body
    $Memo | Add-Member -NotePropertyName tags -NotePropertyValue @(Get-WtMemoTags $Body) -Force   # 예전 데이터엔 tags가 없을 수 있다
    Set-WtItemEdited $Memo (Get-WtMemoStamp $When)
    $Memo
}

# 빠른 이동 결과. 띄어 쓴 낱말이 제목에 모두 들어 있으면 위에, 본문까지 합쳐야 들어 있으면 아래에 (각각 최근 고친 순)
function Find-WtMemoQuick([object[]]$Items, [string]$Query, [int]$Limit = 50) {
    (Find-WtMemoQuickData $Items $Query $Limit)
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
    $script:memoStore = Save-WtMemoDataItems -Store (Open-WtMemoStore) -Items @($items) -Extra @{ importedFrom = $Folder }
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

function Initialize-WtMemoLookup {
    if ([object]::ReferenceEquals($script:lookupItems, $script:items)) { return }
    $script:lookupItems = $script:items
    $lookup = Get-WtMemoLookupData $script:items
    $script:itemsById = $lookup[0]
    $script:itemsByTitle = $lookup[1]
    $script:memoTitles = $lookup[2]
}

function Get-WtMemoById([string]$Id) { Initialize-WtMemoLookup; $script:itemsById[$Id] }

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
    @{ Id = $Id; Mode = $script:mode; Back = [System.Collections.Generic.List[string]]::new(); Forward = [System.Collections.Generic.List[string]]::new(); State = $null; Button = $null; Text = $null; Style = $null }
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
                [ordered]@{ tabs = @(foreach ($t in $p.Tabs) { [string]$t.Id }); modes = @(foreach ($t in $p.Tabs) { [string]$t.Mode }); current = [int]$p.Tabs.IndexOf($p.Current) }
            })
        active = [int]$script:active
        ratio  = [Math]::Round([double]$script:ratio, 3)
    }
    try {
        if ($script:items.Count -ge 256) { $null = Invoke-WtQueuedStoreWrite -Action { param($v) Set-WtSetting 'memo.tabs' $v } -ArgumentList (, $value) }
        else { $null = Set-WtSetting 'memo.tabs' $value }
    } catch { }   # 설정을 못 남겨도 메모 쓰기는 막지 않는다
}

function Add-WtMemoUse([string]$Id) {
    $title = Get-WtMemoTitle $Id
    if ($script:items.Count -ge 256) {
        Invoke-WtQueuedStoreWrite -Action { param($id, $name) Add-WtUse -Page 'memo' -Key $id -Title $name -Sub '메모' -Icon 0xE70B } -ArgumentList $Id, $title
    } else { Add-WtUse -Page 'memo' -Key $Id -Title $title -Sub '메모' -Icon 0xE70B }
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
            $s.Content = New-WtButtonContent '저장됨' 0xE73E
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
            # 실패가 아니다: 데이터 폴더가 늦게 답해 저장 통로가 이어서 쓰는 중. 파일에 쓰이면 「저장됨」이 된다 (Update-WtMemoSaveStatus)
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
    $Pane.More.IsEnabled = [bool]$m
    $Pane.More.ToolTip = if ($m) { '메모 정리' } else { '메모를 먼저 여세요' }
    $Pane.EmptyText.Text = if ($script:items.Count) { '열린 메모가 없습니다. 목록에서 고르거나 새로 만드세요.' } else { '메모가 없습니다.' }
    $Pane.EmptyQuick.IsEnabled = [bool]$script:items.Count
    $Pane.EmptyQuick.ToolTip = if ($script:items.Count) { '빠른 이동 (Ctrl+O)' } else { '메모가 없습니다' }
    Update-WtMemoPaneMode $Pane
    if ($m) { $look = Get-WtMemoSaveLook; Set-WtMemoStatus $Pane $look[0] $look[1] } else { Set-WtMemoStatus $Pane '' }
    if ([object]::ReferenceEquals($Pane, (Get-WtMemoActivePane))) { Update-WtMemoToc }
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

# 태그 · 수정일. 칸이 좁으면 …로 줄이고, 생성일은 툴팁에 둔다
function Set-WtMemoMeta($Pane, $Memo) {
    $Pane.Meta.Text = if ($Memo) { "수정일 $(Format-WtMemoTime $Memo.updated)" } else { '' }
    $Pane.Meta.ToolTip = if ($Memo) { "생성일 $($Memo.created)`n수정일 $($Memo.updated)" } else { $null }
    $Pane.Tags.Children.Clear()
    foreach ($tag in @(if ($Memo) { $Memo.tags })) {
        if (-not $tag) { continue }
        $b = [System.Windows.Controls.Button]::new()
        Set-WtStyle $b 'Memo.Tag'
        $b.Content = "#$tag"; $b.Tag = [string]$tag; $b.ToolTip = '이 태그로 찾기'
        $b.Add_Click({ param($s, $e) Set-WtMemoSearch "#$($s.Tag)" })
        [void]$Pane.Tags.Children.Add($b)
    }
}

function Update-WtMemoPaneMode($Pane) {
    $mode = if ($Pane.Current -and $Pane.Current.Mode) { [string]$Pane.Current.Mode } else { $script:mode }
    $null = Set-WtMemoEditorMode $Pane.Editor $mode
    $read = $mode -eq 'read'
    $Pane.TitleBox.Visibility = if ($read) { 'Collapsed' } else { 'Visible' }
    $Pane.TitleText.Visibility = if ($read) { 'Visible' } else { 'Collapsed' }
    $look = @{ live = @(0xE70F, '편집 보기 (Ctrl+E)'); source = @(0xE943, '원문 보기 (Ctrl+E)'); read = @(0xE736, '읽기 보기 (Ctrl+E)') }[$mode]
    $Pane.ViewButton.Content = New-WtIcon $look[0]
    $Pane.ViewButton.ToolTip = $look[1]
    [System.Windows.Automation.AutomationProperties]::SetName($Pane.ViewButton, $look[1])
    if ([object]::ReferenceEquals($Pane, (Get-WtMemoActivePane))) { $script:mode = $mode }
}

# 칸 폭에 맞춰 글 좌우 여백을 정한다. 글은 가운데 최대 680, 좁으면 44, 두 칸으로 아주 좁으면 20
function Update-WtMemoPaneSide($Pane, [double]$Width) {
    $side = if ($Width -lt 480) { 20 } else { [Math]::Floor([Math]::Max(44, ($Width - 680) / 2)) }
    $Pane.Head.Margin = [System.Windows.Thickness]::new($side, 16, $side, 8)
    $null = Set-WtMemoEditorSide $Pane.Editor $side
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
    $viewButton = New-WtButton '' -Kind Icon -Icon 0xE70F -ToolTip '편집 보기 (Ctrl+E)'
    $viewButton.Tag = $pane
    $viewButton.Add_Click({ param($s, $e) Set-WtMemoActivePane $s.Tag; Switch-WtMemoView })
    $more = New-WtButton '' -Kind Icon -Icon 0xE712 -ToolTip '메모 정리'
    $more.Tag = $pane
    $more.ContextMenu = New-WtHomePinContextMenu
    $more.Add_Click({
            param($s, $e)
            $p = $s.Tag
            Set-WtMemoActivePane $p
            if (-not $p.Current) { return }
            Set-WtMemoActionItems $s.ContextMenu $p.Current.Id $p
            $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.Placement = 'Bottom'; $s.ContextMenu.IsOpen = $true
        })
    $barTools = New-WtStack Horizontal 4
    [void]$barTools.Children.Add($viewButton)
    [void]$barTools.Children.Add($more)
    [System.Windows.Controls.Grid]::SetColumn($barTools, 1)
    [void]$barGrid.Children.Add($barTools)
    $bar.Child = $barGrid
    [System.Windows.Controls.DockPanel]::SetDock($bar, 'Top')
    [void]$dock.Children.Add($bar)

    # 아래: 실행 취소 자리. 지운 뒤에만 보인다
    $undoHost = [System.Windows.Controls.ContentControl]::new()
    $undoHost.Focusable = $false
    $undoHost.Margin = [System.Windows.Thickness]::new(20, 8, 20, 8)
    [System.Windows.Controls.DockPanel]::SetDock($undoHost, 'Bottom')
    [void]$dock.Children.Add($undoHost)

    # 머리: 제목(편집이면 입력칸, 읽기면 글자) · 태그 · 수정일 · 저장 상태
    $head = New-WtStack Vertical 4
    $titleText = New-WtText '' 'T.H2'
    Set-WtResource $titleText 'FontSize' 'F.Memo.H1'
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
    $tags = New-WtStack Horizontal
    $tags.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($tags, 'Left')
    [void]$metaRow.Children.Add($tags)
    $meta = New-WtText '' 'T.Sub'
    $meta.VerticalAlignment = 'Center'
    $meta.TextWrapping = 'NoWrap'
    $meta.TextTrimming = 'CharacterEllipsis'
    [void]$metaRow.Children.Add($meta)
    [void](Add-WtChild $head $titleText)
    [void](Add-WtChild $head $titleBox)
    [void](Add-WtChild $head $metaRow)
    [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')

    # 본문: 편집기 + 탭이 없을 때 안내. 머리와 함께 칸 폭을 따라 여백을 맞춘다
    $center = [System.Windows.Controls.DockPanel]::new()
    $center.Tag = $pane
    $center.Add_SizeChanged({ param($s, $e) Update-WtMemoPaneSide $s.Tag $e.NewSize.Width })
    [void]$center.Children.Add($head)
    $body = [System.Windows.Controls.Grid]::new()
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
    [void]$center.Children.Add($body)
    [void]$dock.Children.Add($center)
    $card.Child = $dock

    $pane.Root = $card; $pane.Strip = $strip; $pane.Scroll = $scroll; $pane.Head = $head
    $pane.TitleText = $titleText; $pane.TitleBox = $titleBox; $pane.Meta = $meta; $pane.Tags = $tags; $pane.Status = $status
    $pane.Editor = $ed; $pane.Empty = $empty; $pane.EmptyText = $emptyText; $pane.EmptyQuick = $emptyQuick
    $pane.ViewButton = $viewButton; $pane.More = $more; $pane.UndoHost = $undoHost
    Update-WtMemoPaneSide $pane 0
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
    $u.PaneCol1.Width = [System.Windows.GridLength]::new($(if ($split) { 8 } else { 0 }))
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
    if ($Pane.Current -and $Pane.Current.Mode) { $script:mode = [string]$Pane.Current.Mode }
    Update-WtMemoTabStyles
    Sync-WtMemoListSelection
    Update-WtMemoToc
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
    Add-WtMemoUse $Id
    Add-WtMemoOpened $Id
    $true
}

function Select-WtMemoTab($Pane, $Tab) {
    if ([object]::ReferenceEquals($Pane.Current, $Tab)) {
        Set-WtMemoActivePane $Pane
        Add-WtMemoUse $Tab.Id
        return $true
    }
    if (-not (Save-WtMemoNow)) { return $false }
    Save-WtMemoPaneState $Pane
    $Pane.Current = $Tab
    $script:active = $script:panes.IndexOf($Pane)
    Show-WtMemoPane $Pane
    Update-WtMemoTabStyles
    Sync-WtMemoListSelection
    Save-WtMemoTabs
    Add-WtMemoUse $Tab.Id
    Add-WtMemoOpened $Tab.Id
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
        $modes = @{}
        $savedIds = @($spec.tabs); $savedModes = @($spec.modes)
        for ($n = 0; $n -lt $savedIds.Count -and $n -lt $savedModes.Count; $n++) { if ([string]$savedModes[$n] -cin 'live', 'source', 'read') { $modes[[string]$savedIds[$n]] = [string]$savedModes[$n] } }
        foreach ($s in $ids) {
            $tab = New-WtMemoTab $s
            if ($modes.ContainsKey($s)) { $tab.Mode = $modes[$s] }
            $pane.Tabs.Add($tab)
        }
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
# 쓰는 중이거나 쓰지 못해도 저장 통로가 이 내용을 가지고 있으므로 $true다 (표시: 「저장하는 중」 → 「저장됨」, 또는 「저장하지 못했습니다」).
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
        $candidate = if ($byId.Contains([string]$m.id)) { $byId[[string]$m.id] } else { Copy-WtItem $m }
        [void](Set-WtMemoContent $candidate $p.TitleBox.Text (Get-WtMemoEditorText $p.Editor))
        $byId[[string]$m.id] = $candidate
    }
    if ($script:itemsById.Count -eq $script:items.Count) {
        $next = $script:items.Clone()
        foreach ($id in $byId.Keys) { $next[[array]::IndexOf($script:items, $script:itemsById[$id])] = $byId[$id] }
    } else {
        $next = @(foreach ($item in $script:items) { if ($byId.Contains([string]$item.id)) { $byId[[string]$item.id] } else { $item } })
    }
    try { Save-WtMemoItems $next }
    catch {
        $msg = $_.Exception.Message
        foreach ($p in $dirty) { Set-WtMemoStatus $p 'error' $msg }
        return $false
    }
    foreach ($p in $dirty) { $p.Dirty = $false }
    $script:items = @(Get-WtMemoSorted $next)
    $script:viewStamp = Get-WtMemoViewStamp
    foreach ($id in $byId.Keys) { Update-WtMemoIndexItem $byId[$id] }
    # 같은 메모를 연 다른 칸은 글을 다시 불러온다 (그 칸은 포커스가 없어 고치는 중이 아님)
    $look = Get-WtMemoSaveLook
    foreach ($p in $script:panes) {
        if (-not $p.Current -or -not $byId.Contains([string]$p.Current.Id)) { continue }
        Update-WtMemoPaneContent $p
        Set-WtMemoStatus $p $look[0] $look[1]
    }
    Update-WtMemoTabTexts
    Update-WtMemoList
    Update-WtMemoToc
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
    Update-WtMemoIndexItem $m
    Clear-WtMemoFilter
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
    Remove-WtMemoItem ([string]$Pane.Current.Id) $Pane
}

function Remove-WtMemoItem([string]$Id, $Pane) {
    if (-not (Save-WtMemoNow)) { return }
    if (-not $Pane) { $Pane = Get-WtMemoActivePane }
    $m = Get-WtMemoById $Id
    if (-not $m) { return }
    $index = [array]::IndexOf(@($script:items), $m)
    $next = @($script:items | Where-Object { $_.id -ne $m.id })
    try { Save-WtMemoItems $next } catch { Show-WtError $_ '메모 삭제'; return }
    $script:items = $next
    $script:viewStamp = Get-WtMemoViewStamp
    Update-WtMemoIndexItem $m -Removed
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
    Update-WtMemoIndexItem $d.Memo
    $script:lastDeleted = $null
    $script:ui.UndoBar.Visibility = 'Collapsed'
    Update-WtMemoList
    [void](Open-WtMemo $d.Memo.id 'tab')
}

# ---- 모드 (편집 · 원문 · 읽기) ----------------------------------------------------------------

# 포커스가 있는 칸의 지금 탭 보기를 바꾼다. 새 탭은 마지막으로 쓴 보기로 연다
function Set-WtMemoMode([string]$Mode) {
    if ($Mode -notin 'live', 'source', 'read') { $Mode = 'live' }
    $pane = Get-WtMemoActivePane
    if ($Mode -ne $script:mode -and -not (Save-WtMemoNow)) { return }
    if ($Mode -ne 'read') { $script:editMode = $Mode }
    $script:mode = $Mode
    if ([string](Get-WtSetting 'memo.mode') -cne $Mode) { try { $null = Set-WtSetting 'memo.mode' $Mode } catch { } }
    if ($pane) {
        if ($pane.Current) { $pane.Current.Mode = $Mode }
        Update-WtMemoPaneMode $pane
    }
    Save-WtMemoTabs
}

# Ctrl+E · 보기 단추: 편집 → 원문 → 읽기 → 편집
function Switch-WtMemoView { Set-WtMemoMode $(@{ live = 'source'; source = 'read'; read = 'live' }[$script:mode]) }

# Ctrl+/: 원문 ↔ 편집
function Switch-WtMemoSource { Set-WtMemoMode $(if ($script:mode -eq 'source') { 'live' } else { 'source' }) }

# ---- 링크 · 빠른 이동 --------------------------------------------------------------------------

function Get-WtMemoTitles { Initialize-WtMemoLookup; $script:memoTitles }

# 본문의 링크를 눌렀을 때. [[제목]]은 제목이 같은 메모를 열고(없으면 그 제목으로 만든다), #태그는 그 태그로 찾는다. 처리했으면 $true
function Invoke-WtMemoLink($Ed, $Link, [string]$How = 'here') {
    $pane = if ($Ed) { Get-WtMemoPaneOf $Ed } else { $null }
    if (-not $pane) { $pane = Get-WtMemoActivePane }
    if ($How -notin 'here', 'tab', 'side') { $How = 'here' }
    switch ($Link.Kind) {
        'wiki' {
            $name = ([string]$Link.Target -split '#')[0].Trim()
            if (-not $name) { return $false }   # [[#제목]]: 같은 글 안 이동은 보기가 한다
            Initialize-WtMemoLookup
            $m = $script:itemsByTitle[$name]
            if ($m) { [void](Open-WtMemo $m.id $How $pane -History) }
            else { [void](Add-WtMemo -Title $name -How $How -Pane $pane -History) }
            return $true
        }
        'tag' {
            Set-WtMemoSearch "#$($Link.Target)"
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
    Initialize-WtMemoLookup
    $exact = $script:itemsByTitle[$query]
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
    (New-WtMemoViewRows -Items @($Memo) -Getters $script:rowGetters -Cache $script:rowCache)[0]
}

# 목록 선택은 포커스가 있는 칸의 지금 탭 메모를 따라간다
function Sync-WtMemoListSelection {
    $list = $script:ui.List
    if (-not $list) { return }
    $keep = Get-WtMemoCurrentId
    $script:listUpdating = $true
    try {
        $selected = $null
        foreach ($row in $script:listRows) { if ([string]$row.Id -eq $keep) { $selected = $row; break } }
        $list.SelectedItem = $selected
    }
    finally { $script:listUpdating = $false }
}

# 목록에서 메모 하나를 고른다(클릭과 같음: 지금 탭에서 연다). 조건에 걸러져 안 보이면 조건을 지운다
function Select-WtMemoItem([string]$Id) {
    $list = $script:ui.List
    $find = { foreach ($row in $script:listRows) { if ([string]$row.Id -eq $Id) { return $row } } }
    Add-WtMemoListPageUntil $Id
    $li = & $find
    if (-not $li) {
        Clear-WtMemoFilter
        Add-WtMemoListPageUntil $Id
        $li = & $find
    }
    if ($li) {
        $list.SelectedItem = $li
        $list.ScrollIntoView($li)
    }
}

# ---- 목록: 검색 색인 ---------------------------------------------------------------------------

# 처음 열 때 화면을 막지 않게 색인은 뒤에서 조금씩 만든다. 그동안 조건 없는 목록은 읽어 둔 메모로 보여 준다
function Start-WtMemoIndexBuild {
    if ($script:preparedMemo -and [object]::ReferenceEquals($script:preparedMemo.Document, $script:memoStore.Doc)) {
        $script:memoIndex = $script:preparedMemo.Index
        Set-WtMemoIndexProperties $script:memoIndex
        $script:indexBuild = $null
        $script:preparedMemo = $null
        Start-WtMemoLinkBuild
        return
    }
    $script:memoIndex = $null
    $folders = try { @(Get-WtMemoFolders $script:memoStore) } catch { @() }
    $script:indexBuild = @{ Index = (New-WtMemoIndex @() -Folders $folders); Items = @($script:items); At = 0 }
    if (-not $script:indexTimer) {
        $script:indexTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
        $script:indexTimer.Interval = [TimeSpan]::Zero
        # 간격이 0이라 실패한 채 돌면 화면 스레드를 계속 깨운다. 실패하면 멈추고, 찾을 때 Get-WtMemoIndex가 다시 만든다
        $script:indexTimer.Add_Tick({ param($s, $e) try { Step-WtMemoIndexBuild 64 } catch { $s.Stop() } })
    }
    $script:indexTimer.Start()
}

function Step-WtMemoIndexBuild([int]$Count) {
    $b = $script:indexBuild
    if (-not $b) { $script:indexTimer.Stop(); return }
    $take = [Math]::Min($Count, $b.Items.Count - $b.At)
    if ($take -gt 0) { Add-WtMemoIndexEntries -Index $b.Index -Memos @($b.Items[$b.At..($b.At + $take - 1)]); $b.At += $take }
    if ($b.At -lt $b.Items.Count) { return }
    $script:indexTimer.Stop()
    $script:memoIndex = $b.Index
    $script:indexBuild = $null
    Start-WtMemoLinkBuild
}

# 받는 연결 수와 연결 조건에 쓰는 해석. 메모마다 마크다운을 읽으므로 화면이 쉴 때만 조금씩 한다
function Start-WtMemoLinkBuild {
    $script:linkFailed = $false
    if ($script:items.Count -lt 256) {
        if (-not $script:linkTimer) {
            $script:linkTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
            $script:linkTimer.Interval = [TimeSpan]::FromMilliseconds(30)
            $script:linkTimer.Add_Tick({
                param($s, $e)
                try {
                    if ($script:memoIndex -and -not (Step-WtMemoLinks $script:memoIndex)) { return }
                    $s.Stop()
                    if ($script:listWaitLinks) { Update-WtMemoList }
                } catch { $s.Stop(); $script:linkFailed = $true }
            })
        }
        $script:linkTimer.Start()
        return
    }
    if ($script:memoIndex -and $script:memoIndex.LinksReady) { return }
    if ($script:linkWork -and -not $script:linkWork.Finished) { return }
    $script:linkWork = Start-WtMemoBackgroundIndex -Items $script:items -Folders @(Get-WtMemoFolders $script:memoStore) -Context $script:items -OnDone {
        param($w)
        $script:linkWork = $null
        if ($w.State -ne 'done') { $script:linkFailed = $true; return }
        if (-not [object]::ReferenceEquals($w.Context, $script:items)) { Start-WtMemoLinkBuild; return }
        $script:memoIndex = $w.Result
        Set-WtMemoIndexProperties $script:memoIndex
        if ($script:listWaitLinks) { Update-WtMemoList }
    }
}

# 찾을 때는 남은 색인을 바로 끝낸다
function Get-WtMemoIndex {
    if ($script:indexBuild) { Step-WtMemoIndexBuild ([int]::MaxValue) }
    if (-not $script:memoIndex) { Start-WtMemoIndexBuild; Step-WtMemoIndexBuild ([int]::MaxValue) }
    $script:memoIndex
}

function Update-WtMemoIndexItem($Memo, [switch]$Removed) {
    $script:rowCache.Remove([string]$Memo.id)
    if ($script:indexBuild) { Start-WtMemoIndexBuild; return }
    if (-not $script:memoIndex) { return }
    if ($Removed) { Update-WtMemoIndex -Index $script:memoIndex -Remove ([string]$Memo.id) }
    else { Update-WtMemoIndex -Index $script:memoIndex -Memo $Memo }
}

# 최근 열기 보기 · 정렬에 쓴다. 열람 기록은 화면이 한가할 때 남긴다 (수정일은 바꾸지 않는다)
function Add-WtMemoOpened([string]$Id) {
    $now = [datetime]::UtcNow
    if ($script:openedAt.ContainsKey($Id) -and ($now - $script:openedAt[$Id]).TotalSeconds -lt 60) { return }
    $script:openedAt[$Id] = $now
    $script:openedPending = $Id
    $target = $script:ui.List
    if (-not $target) { return }
    [void]$target.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action] {
            try {
                # 메모를 쓰지 못하는 동안에는 열람 기록을 더하지 않는다. 다음에 열 때 남는다
                if ((Get-WtDataWriteStatus (Get-WtStorePath 'memo')).State -in 'writing', 'failed') { return }
                if (-not $script:openedStore) { $script:openedStore = Open-WtStore -Name 'memo-state' -Schema 1 }
                $saved = Set-WtMemoOpened -Id ([string]$script:openedPending) -Store $script:openedStore -MemoStore $script:memoStore
                if ($saved) { $script:openedStore = $saved }
            } catch { $script:openedStore = $null }
        })
}

# ---- 목록: 조건 ---------------------------------------------------------------------------------

function Get-WtMemoFilterText { (@($script:listChips | ForEach-Object { $_.Query }) + @([string]$script:ui.Search.Text)) -join ' ' }

function Test-WtMemoFiltered { [bool](Get-WtMemoFilterText).Trim() -or $script:listView -ne 'normal' -or $script:listSort -or $script:listSaved }

function Get-WtMemoChipLabel($Node, [string]$Text) {
    if ($Node.Kind -eq 'not') { return "제외: $(Get-WtMemoChipLabel $Node.Child $Text)" }
    if ($Node.Kind -ne 'term') { return $Text }
    $when = { param($v) if ($v -match '^(\d+)d$') { "최근 $($Matches[1])일" } else { [string]$v } }
    switch ($Node.Field) {
        'tag' { "#$($Node.Value)" }
        'folder' { "폴더: $($Node.Value)" }
        'is' { '고정' }
        'no' { '태그 없음' }
        'has' { if ($Node.Value -ceq 'backlink') { '받은 연결 있음' } else { '연결 있음' } }
        'updated' { "수정일: $(& $when $Node.Value)" }
        'created' { "생성일: $(& $when $Node.Value)" }
        'linksto' { "연결: $($Node.Value)" }
        'title' { "제목: $($Node.Value)" }
        'body' { "본문: $($Node.Value)" }
        default { $Text }
    }
}

function Add-WtMemoChip([string]$Query, [string]$Label) {
    if (@($script:listChips | Where-Object { $_.Query -ceq $Query }).Count) { return }
    if (-not $Label) {
        $tree = ConvertFrom-WtMemoQuery $Query
        $Label = if ($tree.Success) { Get-WtMemoChipLabel $tree.Root $Query } else { $Query }
    }
    $script:listChips.Add(@{ Query = $Query; Label = $Label })
}

function Update-WtMemoChips {
    $host_ = $script:ui.Chips
    $host_.Children.Clear()
    foreach ($chip in $script:listChips) {
        $c = New-WtFilterChip $chip.Label
        $c.Remove.Tag = $chip
        $c.Remove.ToolTip = '조건 지우기'
        $c.Remove.Add_Click({ param($s, $e) [void]$script:listChips.Remove($s.Tag); Update-WtMemoList })
        $c.Root.Margin = [System.Windows.Thickness]::new(0, 0, 4, 4)
        [void]$host_.Children.Add($c.Root)
    }
    $host_.Visibility = if ($script:listChips.Count) { 'Visible' } else { 'Collapsed' }
}

# Enter: 검색창의 조건(#태그 · folder: · updated: 등)을 칩으로 옮긴다. 낱말과 괄호 묶음 밖의 것은 그대로 둔다
function Move-WtMemoQueryToChips {
    $box = $script:ui.Search
    $tree = ConvertFrom-WtMemoQuery ([string]$box.Text)
    if (-not $tree.Success) { return }
    if ($tree.Scope -ne 'active') { $script:listView = $tree.Scope }
    $nodes = if ($tree.Root.Kind -eq 'and') { @($tree.Root.Children) } elseif ($tree.Root.Kind -eq 'all') { @() } else { @($tree.Root) }
    $rest = [System.Collections.Generic.List[string]]::new()
    foreach ($node in $nodes) {
        $text = ConvertTo-WtMemoQuery ([pscustomobject]@{ Success = $true; Scope = 'active'; Root = $node })
        if ($node.Kind -eq 'term' -and $node.Field -ceq 'text') { $rest.Add($(if ([string]$node.Value -match '[\s"]') { $text } else { [string]$node.Value })); continue }
        Add-WtMemoChip $text (Get-WtMemoChipLabel $node $text)
    }
    $script:listUpdating = $true
    try { $box.Text = $rest -join ' ' } finally { $script:listUpdating = $false }
    Update-WtMemoList
}

function Set-WtMemoSearch([string]$Text) {
    $script:searchTimer.Stop()
    if ($script:ui.Search.Text -ceq $Text) { Update-WtMemoList } else { $script:ui.Search.Text = $Text }
}

function Clear-WtMemoFilter {
    $script:listChips.Clear()
    $script:listView = 'normal'; $script:listSaved = $null; $script:listSort = ''; $script:listDir = ''
    $script:listUpdating = $true
    try { $script:ui.Search.Text = '' } finally { $script:listUpdating = $false }
    Update-WtMemoList
}

function Get-WtMemoViewLabel {
    if ($script:listSaved) {
        $same = (Get-WtMemoFilterText).Trim() -ceq $script:listSavedText
        return $(if ($same) { [string]$script:listSaved.name } else { "$($script:listSaved.name) · 변경됨" })
    }
    @{ normal = '일반'; pinned = '고정'; recent = '최근 열기'; archived = '보관'; all = '모두' }[$script:listView]
}

function Get-WtMemoScope { @{ archived = 'archived'; all = 'all' }[$script:listView] ?? 'active' }

function Use-WtMemoSavedView($View) {
    $script:listChips.Clear()
    $script:listView = @{ archived = 'archived'; all = 'all' }[[string]$View.scope] ?? 'normal'
    $script:listSaved = $View
    $script:listSort = [string]$View.sort.by; $script:listDir = [string]$View.sort.dir
    $script:listUpdating = $true
    try { $script:ui.Search.Text = [string]$View.query } finally { $script:listUpdating = $false }
    Move-WtMemoQueryToChips
    # 칩으로 옮기면 글 모양이 바뀌므로 변경 여부는 옮긴 뒤의 글과 견준다
    $script:listSavedText = (Get-WtMemoFilterText).Trim()
    Update-WtMemoList
}

# 지금 조건을 저장한다. -Update면 지금 쓰는 보기를 고친다
function Save-WtMemoCurrentView([string]$Name, [switch]$Update) {
    $sort = @{ by = $(if ($script:listSort) { $script:listSort } else { 'updated' }); dir = $(if ($script:listDir) { $script:listDir } else { 'desc' }) }
    $id = if ($Update -and $script:listSaved) { [string]$script:listSaved.id } else { '' }
    $query = (Get-WtMemoFilterText).Trim()
    try { [void](Save-WtMemoView -Name $Name -Query $query -Sort $sort -Scope (Get-WtMemoScope) -Id $id) }
    catch { Show-WtError $_ '보기 저장'; return }
    $script:listSaved = @(Get-WtMemoViews | Where-Object { $(if ($id) { $_.id -ceq $id } else { $_.name -ceq $Name }) } | Select-Object -Last 1)[0]
    $script:listSavedText = $query
    Update-WtMemoList
}

function Read-WtMemoViewName {
    $dialog = New-WtModal '보기 저장'
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Input'
    [System.Windows.Automation.AutomationProperties]::SetName($box, '보기 이름')
    [void](Add-WtChild $dialog.Body $box)
    $save = New-WtButton '저장' -Kind Primary; $save.IsDefault = $true
    $cancel = New-WtButton '취소'; $cancel.IsCancel = $true
    $dialog.Window.Tag = @{ Box = $box; Error = $dialog.Error; Result = '' }
    $save.Tag = $dialog.Window
    $save.Add_Click({
            param($s, $e)
            $state = $s.Tag.Tag
            $name = $state.Box.Text.Trim()
            if (-not $name) { $state.Error.Text = '이름을 넣으세요.'; $state.Error.Visibility = 'Visible'; return }
            $state.Result = $name
            $s.Tag.DialogResult = $true
        })
    [void](Add-WtChild $dialog.Buttons $save)
    [void](Add-WtChild $dialog.Buttons $cancel)
    $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Box.Focus() })
    [void]$dialog.Window.ShowDialog()
    [string]$dialog.Window.Tag.Result
}

# ---- 목록: 메뉴 ---------------------------------------------------------------------------------

function New-WtMemoMenuCaption([string]$Text) {
    $item = [System.Windows.Controls.MenuItem]::new()
    $item.Header = $Text; $item.IsEnabled = $false
    $item
}

function New-WtMemoMenuItem([string]$Text, [scriptblock]$OnClick, $Value, [switch]$Checked) {
    $item = [System.Windows.Controls.MenuItem]::new()
    $item.Header = if ($Checked) { "✓ $Text" } else { $Text }
    $item.Tag = @{ OnClick = $OnClick; Value = $Value }
    $item.Add_Click({ param($s, $e) & $s.Tag.OnClick $s.Tag.Value })
    $item
}

function Set-WtMemoViewMenu($Menu) {
    $Menu.Items.Clear()
    foreach ($spec in @(@('normal', '일반'), @('pinned', '고정'), @('recent', '최근 열기'), @('archived', '보관'), @('all', '모두'))) {
        $on = $script:listView -ceq $spec[0] -and -not $script:listSaved
        [void]$Menu.Items.Add((New-WtMemoMenuItem $spec[1] { param($v) $script:listSaved = $null; $script:listView = $v; Update-WtMemoList } $spec[0] -Checked:$on))
    }
    $views = @(try { Get-WtMemoViews } catch { })
    if ($views.Count) {
        [void]$Menu.Items.Add((New-WtMemoMenuCaption '저장한 보기'))
        foreach ($view in $views) {
            $on = $script:listSaved -and [string]$script:listSaved.id -ceq [string]$view.id
            [void]$Menu.Items.Add((New-WtMemoMenuItem ([string]$view.name) { param($v) Use-WtMemoSavedView $v } $view -Checked:$on))
        }
    }
    $folders = @(try { Get-WtMemoFolders $script:memoStore } catch { })
    if ($folders.Count) {
        [void]$Menu.Items.Add((New-WtMemoMenuCaption '폴더'))
        foreach ($folder in $folders) {
            [void]$Menu.Items.Add((New-WtMemoMenuItem ([string]$folder.name) { param($v) Add-WtMemoChip "folder:`"$v`"" "폴더: $v"; Update-WtMemoList } ([string]$folder.name)))
        }
    }
    [void]$Menu.Items.Add((New-WtMemoMenuCaption '보기 저장'))
    if ($script:listSaved) {
        [void]$Menu.Items.Add((New-WtMemoMenuItem '보기 업데이트' { Save-WtMemoCurrentView ([string]$script:listSaved.name) -Update }))
        [void]$Menu.Items.Add((New-WtMemoMenuItem '이 보기 삭제' { try { [void](Set-WtMemoViewDeleted -Id ([string]$script:listSaved.id)) } catch { Show-WtError $_ '보기 삭제'; return }; $script:listSaved = $null; Update-WtMemoList }))
    }
    [void]$Menu.Items.Add((New-WtMemoMenuItem '새 보기로 저장...' { $name = Read-WtMemoViewName; if ($name) { Save-WtMemoCurrentView $name } }))
}

function Set-WtMemoFilterMenu($Menu) {
    $Menu.Items.Clear()
    $add = { param($v) Add-WtMemoChip $v ''; Update-WtMemoList }
    [void]$Menu.Items.Add((New-WtMemoMenuCaption '수정일'))
    foreach ($days in 1, 7, 30) { [void]$Menu.Items.Add((New-WtMemoMenuItem $(if ($days -eq 1) { '오늘' } else { "최근 ${days}일" }) $add "updated:${days}d")) }
    [void]$Menu.Items.Add((New-WtMemoMenuCaption '상태'))
    foreach ($spec in @(@('고정', 'is:pinned'), @('연결 있음', 'has:link'), @('받은 연결 있음', 'has:backlink'), @('태그 없음', 'no:tag'))) {
        [void]$Menu.Items.Add((New-WtMemoMenuItem $spec[0] $add $spec[1]))
    }
    $tags = @($script:items | ForEach-Object { @($_.tags) } | Where-Object { $_ } | Group-Object | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, Name | Select-Object -First 8)
    if ($tags.Count) {
        [void]$Menu.Items.Add((New-WtMemoMenuCaption '태그'))
        foreach ($tag in $tags) { [void]$Menu.Items.Add((New-WtMemoMenuItem "#$($tag.Name)" $add "tag:`"$($tag.Name)`"")) }
    }
}

function Set-WtMemoSortMenu($Menu) {
    $Menu.Items.Clear()
    $use = { param($v) $script:listSort = $v; $script:listDir = ''; Update-WtMemoList }
    foreach ($spec in @(@('', '기본'), @('updated', '수정일'), @('created', '생성일'), @('title', '제목'), @('opened', '최근 열기'), @('backlinks', '받은 연결 수'))) {
        [void]$Menu.Items.Add((New-WtMemoMenuItem $spec[1] $use $spec[0] -Checked:($script:listSort -ceq $spec[0])))
    }
    if ($script:listSort) {
        $dir = if ($script:listDir) { $script:listDir } elseif ($script:listSort -ceq 'title') { 'asc' } else { 'desc' }
        [void]$Menu.Items.Add((New-WtMemoMenuCaption '방향'))
        foreach ($spec in @(@('desc', '내림차순'), @('asc', '오름차순'))) {
            [void]$Menu.Items.Add((New-WtMemoMenuItem $spec[1] { param($v) $script:listDir = $v; Update-WtMemoList } $spec[0] -Checked:($dir -ceq $spec[0])))
        }
    }
}

# 메모 하나를 정리하는 메뉴 항목: 고정 · 보관 · 폴더 · 삭제. 칸의 ⋯ 단추와 목록 우클릭이 같이 쓴다
function Set-WtMemoActionItems($Menu, [string]$Id, $Pane) {
    $Menu.Items.Clear()
    $m = Get-WtMemoById $Id
    if (-not $m) { return }
    $pinned = $m.pinned -eq $true; $archived = $m.archived -eq $true
    [void]$Menu.Items.Add((New-WtMemoMenuItem $(if ($pinned) { '고정 해제' } else { '고정' }) { param($v) Invoke-WtMemoAction pin $v.Id $v.Value } @{ Id = $Id; Value = -not $pinned }))
    [void]$Menu.Items.Add((New-WtMemoMenuItem $(if ($archived) { '보관 해제' } else { '보관' }) { param($v) Invoke-WtMemoAction archive $v.Id $v.Value } @{ Id = $Id; Value = -not $archived }))
    $folders = @(try { Get-WtMemoFolders $script:memoStore } catch { })
    if ($folders.Count) {
        [void]$Menu.Items.Add((New-WtMemoMenuCaption '폴더로 옮기기'))
        foreach ($folder in @($folders) + @([pscustomobject]@{ id = ''; name = '폴더 없음' })) {
            $on = [string]$m.folder -ceq [string]$folder.id
            [void]$Menu.Items.Add((New-WtMemoMenuItem ([string]$folder.name) { param($v) Invoke-WtMemoAction folder $v.Id $v.Value } @{ Id = $Id; Value = [string]$folder.id } -Checked:$on))
        }
    }
    [void]$Menu.Items.Add((New-WtMemoMenuItem '삭제' { param($v) Remove-WtMemoItem $v.Id $v.Pane } @{ Id = $Id; Pane = $Pane }))
}

# 목록 우클릭: 열기 · 홈 고정 + 정리 항목
function Set-WtMemoListMenu($Menu, [string]$Id) {
    Set-WtMemoActionItems $Menu $Id $null
    $Menu.Tag = $Id
    $open = @(
        (New-WtMemoMenuItem '새 탭에서 열기' { param($v) [void](Open-WtMemo $v 'tab') } $Id),
        (New-WtMemoMenuItem '오른쪽에 열기' { param($v) [void](Open-WtMemo $v 'side') } $Id),
        (New-WtMemoMenuItem $(if (Test-WtHomePin -Page 'memo' -Key $Id) { '홈 고정 해제' } else { '홈에 고정' }) {
            param($v) Set-WtHomePin -Page 'memo' -Key $v -Title (Get-WtMemoTitle $v) -Sub '메모' -Icon 0xE70B -Pinned:(-not (Test-WtHomePin -Page 'memo' -Key $v))
        } $Id))
    $open[0].InputGestureText = 'Ctrl+클릭'
    for ($i = $open.Count - 1; $i -ge 0; $i--) { $Menu.Items.Insert(0, $open[$i]) }
}

function Invoke-WtMemoAction([string]$Action, [string]$Id, $Value) {
    if (-not (Save-WtMemoNow)) { return }
    try {
        $script:memoStore = switch ($Action) {
            'pin' { Set-WtMemoPinned -Id $Id -Pinned ([bool]$Value) -Store $script:memoStore }
            'archive' { Set-WtMemoArchived -Id $Id -Archived ([bool]$Value) -Store $script:memoStore }
            'folder' { Set-WtMemoFolder -Id $Id -Folder ([string]$Value) -Store $script:memoStore }
        }
    } catch { Show-WtError $_ '메모 정리'; return }
    $item = $null
    foreach ($m in $script:memoStore.Items) { if ($m.id -ceq $Id) { $item = $m; break } }
    $next = $script:items.Clone()
    # 정리의 id는 ordinal이다. 화면 열기의 대소문자 무시 조회로 바꾸면 A/a 중 다른 행을 덮을 수 있다.
    $position = [array]::IndexOf([string[]](Get-WtMemoIdArray $script:items), $Id)
    if ($position -ge 0) { $next[$position] = $item }
    $script:items = $next
    $script:viewStamp = Get-WtMemoViewStamp
    Update-WtMemoIndexItem $item
    Update-WtMemoList
}

# ---- 목록: 그리기 -------------------------------------------------------------------------------

# 줄 하나를 Find-WtMemo 결과 줄에서 만든다. 행 캐시는 메모 객체와 같은 이름을 쓴다
function ConvertTo-WtMemoListItem($Row) {
    New-WtMemoListItem ([pscustomobject]@{ id = $Row.Id; title = $Row.Title; body = [string]$Row.Snippet; updated = $Row.Updated; pinned = $Row.Pinned })
}

function Get-WtMemoListResult {
    $query = Get-WtMemoFilterText
    $firstList = $script:firstMemoList
    $script:firstMemoList = $false
    # 조건 없는 처음 목록은 색인을 기다리지 않는다
    if (-not (Test-WtMemoFiltered) -and ($firstList -or -not $script:memoIndex)) {
        $ordered = Get-WtMemoInitialOrder $script:items
        return @{ Count = $ordered.Count; Items = $ordered; Find = $null; Query = $query }
    }
    $index = Get-WtMemoIndex
    # 연결 조건은 해석이 끝나야 답할 수 있다. 화면을 세우지 않고 앞 결과를 둔 채 뒤에서 끝낸 다음 다시 그린다
    $script:listWaitLinks = $false
    if (-not $index.LinksReady -and -not $script:linkFailed) {
        $tree = ConvertFrom-WtMemoQuery $query
        if (($script:listSort -ceq 'backlinks' -or ($tree.Success -and (Test-WtMemoQueryLinks $tree.Root))) -and
            ($script:items.Count -ge 256 -or -not (Step-WtMemoLinks $index $script:linkWaitMs))) {
            Start-WtMemoLinkBuild
            $script:listWaitLinks = $true
            return @{ Error = [pscustomobject]@{ Reason = '연결을 정리하는 중입니다. 끝나면 결과를 보여 줍니다.' } }
        }
    }
    $params = @{ Index = $index; Query = $query; View = $script:listView; First = $script:listPage; SnippetLimit = $script:listPage; SkipBacklinks = $true }
    if ($script:listSort) { $params.Sort = $script:listSort; if ($script:listDir) { $params.Dir = $script:listDir } }
    if ($script:listView -ceq 'recent' -or $script:listSort -ceq 'opened') {
        try { $params.OpenedMap = Open-WtStore -Name 'memo-state' -Schema 1 } catch { }
    }
    $found = Find-WtMemo @params
    if (-not $found.Success) { return @{ Error = $found.Error } }
    @{ Count = $found.Count; Items = @($found.Items); Find = $found; Query = $query }
}

function Get-WtMemoListPage($Result, [int]$Skip, [int]$Take) {
    $context = "$([bool]$Result.Find)|$($Result.Query)|$([datetime]::Today.Ticks)"
    if ($script:rowContext -cne $context) { $script:rowCache.Clear(); $script:rowContext = $context }
    if ($Result.Find) {
        # 찾기 결과는 앞 $script:listPage줄만 들고 있다. 스크롤로 더 만든 뒤 다시 그릴 때는 그만큼 새로 만든다
        $have = @($Result.Items)
        $rows = if ($Skip -eq 0 -and ($Take -le $have.Count -or $have.Count -ge $Result.Count)) { $have } else { @(Get-WtMemoResultRows -Result $Result.Find -Skip $Skip -First $Take) }
        $viewRows = New-WtMemoViewRows -Items $rows -Getters $script:rowGetters -Cache $script:rowCache -Search -Reuse
        Complete-WtMemoRowText $viewRows
        $viewRows
        return
    }
    $last = [Math]::Min($Skip + $Take, $Result.Count) - 1
    if ($last -ge $Skip) {
        $viewRows = New-WtMemoViewRows -Items @($Result.Items[$Skip..$last]) -Getters $script:rowGetters -Cache $script:rowCache -Reuse
        Complete-WtMemoRowText $viewRows
        $viewRows
    }
}

# 바인딩이 같은 ScriptProperty를 여러 번 평가하지 않게 앞/뒤 한 페이지의 표시 문자열을 한 번 완성한다.
# 먼 위치 사이의 아직 표시되지 않은 행은 같은 getter를 남겨 처음 보일 때 원문으로 완성한다.
function Complete-WtMemoRowText([object[]]$Rows) {
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        if ($i -ge $script:listPage -and $i -lt $Rows.Count - $script:listPage) { $i = $Rows.Count - $script:listPage - 1; continue }
        $row = $Rows[$i]
        if ($row.PSObject.Properties['Sub'] -isnot [Management.Automation.PSScriptProperty]) { continue }
        $stamp = Format-WtMemoTime $row.Updated
        $snippet = Get-WtMarkdownSnippet $row.SnippetSource
        $row.StampValue = $stamp; $row.SnippetValue = $snippet
        $sub = if ($snippet) { "$stamp · $snippet" } else { $stamp }
        foreach ($pair in @(@('Stamp', $stamp), @('Snippet', $snippet), @('Sub', $sub))) {
            $row.PSObject.Properties.Remove($pair[0])
            $row.PSObject.Properties.Add([Management.Automation.PSNoteProperty]::new($pair[0], $pair[1]))
        }
    }
}

# 목록을 다시 그린다. 열린 메모는 다시 채우지 않는다 (편집 중 글자 위치 유지). 편집 중인 메모가 조건에서 빠져도 편집기는 그대로 둔다
function Update-WtMemoList {
    if ($script:listUpdating) { return }
    if ($script:searchTimer) { $script:searchTimer.Stop() }
    $list = $script:ui.List
    $result = Get-WtMemoListResult
    Update-WtMemoChips
    $script:ui.ViewLabel.Text = Get-WtMemoViewLabel
    # 쓰는 중인 검색식이 틀리면 앞의 결과를 그대로 둔다
    if ($result.Error) {
        $script:ui.ListNote.Text = '이전 조건 결과'
        $script:ui.ListNote.ToolTip = [string]$result.Error.Reason
        $script:ui.ListNote.Visibility = 'Visible'
        return
    }
    $script:ui.ListNote.Visibility = 'Collapsed'
    $script:listResult = $result
    $script:ui.ListCount.Text = "  $($result.Count)"
    # 이미 보던 먼 위치를 유지한다. 앞 200줄로 줄이면 레이아웃 도중 ScrollChanged가 끝까지 다시 붙인다.
    $take = [Math]::Max($script:listPage, $(if ($script:listRows) { $script:listRows.Count } else { 0 }))
    $rows = @(Get-WtMemoListPage $result 0 $take)
    $script:listUpdating = $true
    try {
        $same = $script:listRows -and $script:listRows.Count -eq $rows.Count
        for ($i = 0; $same -and $i -lt $rows.Count; $i++) { $same = [object]::ReferenceEquals($script:listRows[$i], $rows[$i]) }
        if (-not $same) {
            $script:listRows = [System.Collections.ObjectModel.ObservableCollection[object]]::new([Collections.Generic.IEnumerable[object]]$rows)
            $list.ItemsSource = $script:listRows
        }
    } finally { $script:listUpdating = $false }
    $script:ui.ListEmpty.Visibility = if ($result.Count) { 'Collapsed' } elseif (Test-WtMemoFiltered) { 'Visible' } else { 'Collapsed' }
    Sync-WtMemoListSelection
}

# 스크롤이 끝에 가까워지면 다음 줄을 만든다
function Add-WtMemoListPage {
    $r = $script:listResult
    if (-not $r -or -not $script:listRows -or $script:listRows.Count -ge $r.Count) { return }
    foreach ($row in @(Get-WtMemoListPage $r $script:listRows.Count $script:listPage)) { $script:listRows.Add($row) }
}

function Add-WtMemoListPageUntil([string]$Id) {
    if (-not $script:listRows) { return }
    foreach ($row in $script:listRows) { if ([string]$row.Id -ceq $Id) { return } }
    $r = $script:listResult
    $position = -1
    if ($r.Find) {
        $slot = [array]::IndexOf([string[]]$r.Find.Columns[0], $Id)
        if ($slot -ge 0) { $position = [array]::IndexOf([int[]]$r.Find.Order, $slot) }
    } else {
        for ($i = 0; $i -lt $r.Items.Count; $i++) { if ([string]$r.Items[$i].id -ceq $Id) { $position = $i; break } }
    }
    if ($position -lt 0) { return }
    $take = [Math]::Min($r.Count, [int]([Math]::Ceiling(($position + 1) / [double]$script:listPage) * $script:listPage))
    $more = @(Get-WtMemoListPage $r $script:listRows.Count ($take - $script:listRows.Count))
    $all = [object[]]::new($script:listRows.Count + $more.Count)
    $script:listRows.CopyTo($all, 0)
    [array]::Copy($more, 0, $all, $script:listRows.Count, $more.Count)
    $script:listUpdating = $true
    try {
        $script:listRows = [Collections.ObjectModel.ObservableCollection[object]]::new([Collections.Generic.IEnumerable[object]]$all)
        $script:ui.List.ItemsSource = $script:listRows
    } finally { $script:listUpdating = $false }
}

# ---- 목차 ---------------------------------------------------------------------------------------

function Get-WtMemoTocRows($Memo) {
    $title = [string]$Memo.title
    [pscustomobject]@{ Text = $(if ($title) { $title } else { '제목 없음' }); Line = -1; Indent = [System.Windows.Thickness]::new(0) }
    foreach ($h in @(Get-WtMarkdownHeadings ([string]$Memo.body))) {
        if ([int]$h.Level -eq 1 -and $h.Text -ceq $title) { continue }
        [pscustomobject]@{ Text = [string]$h.Text; Line = [int]$h.Line - 1; Indent = [System.Windows.Thickness]::new(([Math]::Min([int]$h.Level, 4) - 1) * 12 + 8, 0, 0, 0) }
    }
}

function Update-WtMemoToc {
    $list = $script:ui.Toc
    if (-not $list) { return }
    $p = Get-WtMemoActivePane
    $m = if ($p -and $p.Current) { Get-WtMemoById $p.Current.Id } else { $null }
    $key = if ($m) { "$($m.id)|$($m.updated)|$($m.title)" } else { '' }
    if ($script:tocKey -ceq $key) { return }
    $script:tocKey = $key
    $list.ItemsSource = @(if ($m) { Get-WtMemoTocRows $m })
}

function Invoke-WtMemoTocPick($Row) {
    $p = Get-WtMemoActivePane
    if ($p -and $p.Current -and $Row) { $null = Show-WtMemoEditorLine $p.Editor ([int]$Row.Line) }
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
        'E' { Switch-WtMemoView; return $true }
        'Backslash' { Split-WtMemoRight; return $true }
        'Slash' { Switch-WtMemoSource; return $true }
    }
    $false
}

# ---- 화면 만들기 ------------------------------------------------------------------------------

function New-WtMemoView {
    $script:viewStamp = $null
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

    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new()
    $c1.Width = [System.Windows.GridLength]::Auto
    $c2 = [System.Windows.Controls.ColumnDefinition]::new()
    $c2.Width = [System.Windows.GridLength]::new(1, 'Star')
    $c3 = [System.Windows.Controls.ColumnDefinition]::new()
    $c3.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1)
    $grid.ColumnDefinitions.Add($c2)
    $grid.ColumnDefinitions.Add($c3)

    # 왼쪽: 검색 줄 → 조건 칩 → 보기 고르기 → 목록
    if (-not $script:searchTimer) {
        # 입력이 멈춘 뒤에 찾는다. 마지막 글만 찾으므로 빠르게 쳐도 입력이 멈칫하지 않는다
        $script:searchTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:searchTimer.Interval = [TimeSpan]::FromMilliseconds(120)
        $script:searchTimer.Add_Tick({ param($s, $e) $s.Stop(); Update-WtMemoList })
    }
    $script:listChips.Clear(); $script:listView = 'normal'; $script:listSaved = $null; $script:listSort = ''; $script:listDir = ''
    $script:listRows = $null; $script:listResult = $null; $script:tocKey = ''
    $ldock = [System.Windows.Controls.DockPanel]::new()
    Set-WtStyle $ldock 'Memo.ListBody'
    $searchRow = [System.Windows.Controls.DockPanel]::new()
    Set-WtStyle $searchRow 'Memo.SearchRow'
    $sortButton = New-WtButton '' -Kind Icon -Icon 0xE8CB -ToolTip '정렬'
    $filterButton = New-WtButton '' -Kind Icon -Icon 0xE71C -ToolTip '조건 더하기'
    foreach ($spec in @(@($sortButton, 'sort'), @($filterButton, 'filter'))) {
        $button = $spec[0]
        $button.Tag = $spec[1]
        $button.Margin = [System.Windows.Thickness]::new(4, 0, 0, 0)
        $button.ContextMenu = New-WtHomePinContextMenu
        $button.Add_Click({
                param($s, $e)
                if ($s.Tag -ceq 'sort') { Set-WtMemoSortMenu $s.ContextMenu } else { Set-WtMemoFilterMenu $s.ContextMenu }
                $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.Placement = 'Bottom'; $s.ContextMenu.IsOpen = $true
            })
        [System.Windows.Controls.DockPanel]::SetDock($button, 'Right')
        [void]$searchRow.Children.Add($button)
    }
    $sb = New-WtSearchBox '찾기'
    $search = $sb.Box
    $search.ToolTip = '제목 · 본문을 찾습니다. #태그 folder:업무 updated:7d 도 씁니다. Enter는 조건을 칩으로 옮깁니다 (Ctrl+Shift+F)'
    $search.Add_TextChanged({
            param($s, $e)
            if ($script:listUpdating) { return }
            if ($s.IsKeyboardFocused) { $script:searchTimer.Stop(); $script:searchTimer.Start() } else { Update-WtMemoList }
        })
    $search.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $s.Text) { Move-WtMemoQueryToChips; $e.Handled = $true }
            elseif ($e.Key -eq [System.Windows.Input.Key]::Down -and $script:ui.List.Items.Count) {
                $script:ui.List.SelectedIndex = [Math]::Max(0, $script:ui.List.SelectedIndex)
                $item = $script:ui.List.ItemContainerGenerator.ContainerFromIndex($script:ui.List.SelectedIndex)
                if ($item) { [void]$item.Focus() }
                $e.Handled = $true
            }
        })
    [void]$searchRow.Children.Add($sb.Root)
    [System.Windows.Controls.DockPanel]::SetDock($searchRow, 'Top')
    [void]$ldock.Children.Add($searchRow)
    $chips = [System.Windows.Controls.WrapPanel]::new()
    Set-WtStyle $chips 'Memo.Chips'
    $chips.Visibility = 'Collapsed'
    [System.Windows.Controls.DockPanel]::SetDock($chips, 'Top')
    [void]$ldock.Children.Add($chips)
    $viewRow = [System.Windows.Controls.DockPanel]::new()
    Set-WtStyle $viewRow 'Memo.ViewRow'
    $note = New-WtText '' 'T.CaptionMuted'
    $note.Visibility = 'Collapsed'
    $note.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($note, 'Right')
    [void]$viewRow.Children.Add($note)
    $viewPick = [System.Windows.Controls.Button]::new()
    Set-WtStyle $viewPick 'Memo.ViewPick'
    $viewRowInner = New-WtStack Horizontal 4
    $viewLabel = New-WtText '일반' 'T.Sub'
    $viewLabel.VerticalAlignment = 'Center'
    Set-WtResource $viewLabel 'Foreground' 'B.Text.Secondary'
    $viewChevron = New-WtIcon 0xE70D
    $viewChevron.FontSize = 10
    $viewChevron.VerticalAlignment = 'Center'
    [void]$viewRowInner.Children.Add($viewLabel)
    [void]$viewRowInner.Children.Add($viewChevron)
    $viewPick.Content = $viewRowInner
    $viewPick.ToolTip = '보기 고르기'
    $viewPick.ContextMenu = New-WtHomePinContextMenu
    $viewPick.Add_Click({
            param($s, $e)
            Set-WtMemoViewMenu $s.ContextMenu
            $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.Placement = 'Bottom'; $s.ContextMenu.IsOpen = $true
        })
    [void]$viewRow.Children.Add($viewPick)
    [System.Windows.Controls.DockPanel]::SetDock($viewRow, 'Top')
    [void]$ldock.Children.Add($viewRow)
    $listArea = [System.Windows.Controls.Grid]::new()
    $listEmpty = New-WtStack Vertical 8
    $listEmpty.HorizontalAlignment = 'Center'; $listEmpty.VerticalAlignment = 'Center'; $listEmpty.Visibility = 'Collapsed'
    [void](Add-WtChild $listEmpty (New-WtText '찾은 메모가 없습니다.' 'T.Sub'))
    $listClear = New-WtButton '조건 지우기' -Kind Link
    $listClear.Add_Click({ Clear-WtMemoFilter })
    [void](Add-WtChild $listEmpty $listClear)
    $list = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $list 'Memo.List'
    $list.AddHandler([System.Windows.Controls.ScrollViewer]::ScrollChangedEvent, [System.Windows.Controls.ScrollChangedEventHandler] {
            param($s, $e)
            if ($e.ExtentHeight -gt 0 -and $e.VerticalOffset + $e.ViewportHeight -ge $e.ExtentHeight - 8) { Add-WtMemoListPage }
        })
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
    $list.ContextMenu = New-WtHomePinContextMenu
    $list.Add_ContextMenuOpening({
            param($s, $e)
            $memoId = if ($script:listMenuId) { $script:listMenuId } elseif ($s.SelectedItem) { [string]$s.SelectedItem.Id } else { '' }
            $script:listMenuId = ''
            if (-not $memoId) { $e.Handled = $true; return }
            Set-WtMemoListMenu $s.ContextMenu $memoId
        })
    [void]$listArea.Children.Add($list)
    [void]$listArea.Children.Add($listEmpty)
    [void]$ldock.Children.Add($listArea)
    $left = New-WtSidePanel -Content $ldock -Side Left -Key 'memo.listCollapsed' -Title '메모' -Width 280
    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$grid.Children.Add($left)
    $listTitle = $left.FindName('Title')
    $listCount = [System.Windows.Documents.Run]::new('')
    $listCount.FontWeight = 'Normal'
    $listCount.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'B.Text.Tertiary')
    $listTitle.Inlines.Add($listCount)
    $add = New-WtButton '' -Kind Icon -Icon 0xE710 -ToolTip '새로 만들기 (Ctrl+N)'
    $add.Add_Click({ [void](Add-WtMemo -Edit) })
    [System.Windows.Controls.DockPanel]::SetDock($add, 'Right')
    $listHeader = $left.FindName('Header')
    $listHeader.Children.Insert(1, $add)

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

    # 오른쪽: 목차. 제목을 누르면 그 자리로 간다
    $toc = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $toc 'Memo.Toc'
    $toc.Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $c = $null
            try { $c = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource) } catch { }
            if ($c) { Invoke-WtMemoTocPick $c.DataContext }
        })
    $toc.Add_KeyDown({ param($s, $e) if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $s.SelectedItem) { Invoke-WtMemoTocPick $s.SelectedItem; $e.Handled = $true } })
    $right = New-WtSidePanel -Content $toc -Side Right -Key 'memo.tocCollapsed' -Title '목차' -Width 220 -Independent
    [System.Windows.Controls.Grid]::SetColumn($right, 2)
    [void]$grid.Children.Add($right)

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
    [System.Windows.Controls.Grid]::SetColumnSpan($qHost, 3)
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
        UndoBar = $undoBar; UndoText = $undoText; Add = $add; Chips = $chips; ViewLabel = $viewLabel; ListNote = $note; ListCount = $listCount
        ListEmpty = $listEmpty; Toc = $toc; ListPanel = $left; TocPanel = $right; FilterButton = $filterButton; SortButton = $sortButton; ViewPick = $viewPick
        Quick = @{ Host = $qHost; Box = $qsb.Box; List = $qList }
    }
    [void](Add-WtMemoPane)
    $page.Root
}

function Update-WtMemoView {
    if (-not (Save-WtMemoNow)) { return }
    $stamp = Get-WtMemoViewStamp
    if ($script:viewStamp -cne $stamp) {
        $script:rowCache.Clear()
        $script:firstMemoList = $true
        $reusePrepared = $script:preparedMemo -and [object]::ReferenceEquals($script:preparedMemo.Document, $script:memoStore.Doc) -and
            $stamp -ceq "$($script:shortcutStamp)|$([datetime]::Today.Ticks)"
        if (-not $reusePrepared) { $loaded = @(Get-WtMemoItems) }
        $script:items = if ($script:preparedMemo) { $script:preparedMemo.Items } else { @(Get-WtMemoSorted $loaded) }
        Start-WtMemoIndexBuild
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
    Start-WtMemoQueryWarmUp
}

# 첫 찾기가 느리지 않게 메모 화면이 뜬 뒤 쉬는 틈에 한 번 돌려 둔다. 앱을 켤 때 돌리면 창이 약 0.9초 늦게 뜬다
function Start-WtMemoQueryWarmUp {
    if ($script:queryWarmAsked -or -not $script:ui.List) { return }
    $script:queryWarmAsked = $true
    [void]$script:ui.List.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action] { try { Initialize-WtMemoQueryRuntime } catch { } })
}

# 바로 가기의 메모가 남아 있는지. 홈을 그릴 때 줄마다 불리므로 memo.json이 바뀌었을 때만 다시 읽고,
# 메모 화면이 같은 내용을 들고 있으면 파일을 읽지 않는다.
# 저장소를 직접 열지 않는다: 읽으면 들고 있던 저장 핸들이 낡으므로 Get-WtMemoItems가 핸들을 함께 바꾼다
function Test-WtMemoShortcut([string]$Key) {
    $stamp = Get-WtStoreStamp 'memo'
    if (-not $script:shortcutIds -or $script:shortcutStamp -cne $stamp) {
        $fresh = $script:viewStamp -ceq "$stamp|$([datetime]::Today.Ticks)"
        $items = if ($fresh) { $script:items } else { @(Get-WtMemoItems) }
        $script:shortcutIds = [Collections.Generic.HashSet[string]]::new([Collections.Generic.IEnumerable[string]](Get-WtMemoIdArray $items), [StringComparer]::Ordinal)
        $script:shortcutStamp = $stamp
    }
    $script:shortcutIds.Contains($Key)
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
    -OnOpen { param($OpenArgs) if ($OpenArgs.Key -and (Get-WtMemoById ([string]$OpenArgs.Key))) { Clear-WtMemoFilter; [void](Open-WtMemo ([string]$OpenArgs.Key)) } } `
    -ShortcutExists { param($Key) Test-WtMemoShortcut $Key } `
    -ImportLegacy { param($folder) Import-WtMemoLegacy $folder } `
    -SavePending { if ($script:ui.Count) { Save-WtMemoNow } else { $true } } `
    -OnExit { if ($script:ui.Count) { [void](Save-WtMemoNow) }; foreach ($timer in $script:saveTimer, $script:undoTimer, $script:indexTimer, $script:linkTimer, $script:searchTimer) { if ($timer) { $timer.Stop() } } } `
    -Help @('마크다운 메모를 탭과 두 칸으로 엽니다.', 'Ctrl+E로 편집 · 원문 · 읽기를 차례로 바꿉니다.', '찾기 칸에 #태그 · folder:업무 · updated:7d 같은 조건을 쓸 수 있습니다.') `
    -Shortcuts @(
        @('Ctrl + N', '새로 만들기 (새 탭)'), @('Ctrl + S', '바로 저장'), @('Ctrl + O', '메모 이름으로 찾아 열기'),
        @('Ctrl + W', '탭 닫기'), @('Ctrl + Shift + T', '닫은 탭 다시 열기'), @('Ctrl + Tab / Ctrl + Shift + Tab', '다음 / 이전 탭'),
        @('Ctrl + \', '오른쪽에 나눠 열기 (나눴으면 다른 칸으로)'), @('Alt + ← / Alt + →', '뒤로 / 앞으로 (링크 · 빠른 이동으로 간 메모)'),
        @('Ctrl + E', '편집 → 원문 → 읽기'), @('Ctrl + /', '편집 / 원문'), @('Ctrl + Shift + F', '목록 찾기 칸으로'),
        @('Ctrl + 클릭 · 가운데 클릭', '목록 · 링크를 새 탭에서 열기'),
        @('Ctrl + B / Ctrl + I', '굵게 / 기울임 (다시 누르면 풀기)'), @('Ctrl + K', '링크 만들기'), @('Alt + Shift + 5', '취소선'),
        @('` (글을 고르고)', '코드로 감싸기 (여러 줄이면 코드 블록)'), @('```', '줄 맨 앞에 치면 닫는 ``` 를 자동으로'),
        @('[[', '메모 링크 자동 완성 (↑↓ 고르기 · Enter)'), @('Enter', '목록 · 할 일 이어 쓰기 (빈 항목에서 Enter = 목록 끝)'),
        @('Tab / Shift + Tab', '목록 들여쓰기 / 내어쓰기'), @('Ctrl + L', '할 일 체크박스 넣기 · 완료 / 해제'),
        @('Alt + ↑ / Alt + ↓', '줄 옮기기'), @('Ctrl + F / Ctrl + H / F3', '찾기 / 바꾸기 / 다음 찾기'),
        @('Ctrl + Z / Ctrl + Y', '실행 취소 / 다시 실행'), @('Ctrl + Shift + V', '바꾸지 않고 붙여넣기'),
        @('붙여넣기', '글을 고르고 URL을 붙이면 링크, 파일 경로는 경로 링크로'), @('끌어 놓기', '탐색기의 파일 · 폴더를 놓으면 링크')) `
    -HelpCard { New-WtMemoMarkdownHelpCard }

Export-ModuleMember -Function Get-WtMemoItems, Get-WtMemoSorted, Format-WtMemoTime, Import-WtMemoLegacy,
    New-WtMemo, Get-WtMemoTags, Set-WtMemoContent, Save-WtMemoItems

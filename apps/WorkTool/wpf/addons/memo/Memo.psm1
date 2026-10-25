# 메모 탭: 목록 · 검색 · 편집 | 미리보기(마크다운) · 자동 저장 · 새 메모 · 삭제(실행 취소). 메모별 잠금은 다음에 옮긴다.
# 저장소 memo.json (schema 1). 항목:
#   id, title, body, tags[], lock($null=잠기지 않음. 나중에 'dpapi' | 'password'), created, updated
#   tags는 본문의 #태그를 저장할 때 모은 것이다.
# 본문은 마크다운으로 보여 준다 (core/Markdown.psm1). [[메모 제목]]은 그 메모로, #태그는 그 태그 검색으로 간다.
# 단축키(메모 화면 안): Ctrl+N 새 메모 · Ctrl+S 바로 저장 · Ctrl+E 편집 / 미리보기

$ErrorActionPreference = 'Stop'

$script:schema = 1
$script:items = @()
$script:currentId = $null    # 오른쪽에 열려 있는 메모
$script:dirty = $false       # 저장하지 않은 고친 내용이 있음
$script:loading = $false     # 코드로 칸을 채우는 중 (고친 것으로 치지 않음)
$script:lastDeleted = $null  # 실행 취소용
$script:ui = @{}
$script:saveTimer = $null
$script:undoTimer = $null
$script:listUpdating = $false
$script:rowCache = @{}

Register-WtSettingDefault 'memo.mode' 'preview'   # 오른쪽 칸: preview(미리보기) | edit(편집)

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

# ---- 화면 -------------------------------------------------------------------------------------

function Get-WtMemoById([string]$Id) { $script:items | Where-Object { $_.id -eq $Id } | Select-Object -First 1 }

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

# 오른쪽 칸에 메모 하나를 연다 (없으면 빈 화면 안내)
function Show-WtMemo([string]$Id) {
    if (-not (Save-WtMemoNow)) { return }
    $m = if ($Id) { Get-WtMemoById $Id } else { $null }
    $script:currentId = if ($m) { $m.id } else { $null }
    $script:loading = $true
    try {
        if (-not $m) {
            $script:ui.TitleText.Text = ''
            $script:ui.TitleBox.Text = ''
            $script:ui.Meta.Text = ''
            $script:ui.BodyBox.Text = ''
            $msg = if ($script:items.Count) { '왼쪽에서 메모를 고르세요.' } else { '메모가 없습니다. [새 메모]를 누르세요.' }
            Set-WtMarkdownText $script:ui.MdView $msg
        } else {
            $script:ui.TitleText.Text = $m.title
            $script:ui.TitleBox.Text = $m.title
            $script:ui.Meta.Text = '만든 날 {0} · 고친 날 {1}' -f $m.created, $m.updated
            $script:ui.BodyBox.Text = [string]$m.body
            if ([string](Get-WtSetting 'memo.mode') -ne 'edit' -and ($script:ui.MdView.Tag.Text -cne [string]$m.body -or $script:ui.MdView.Tag.Error)) { Set-WtMarkdownText $script:ui.MdView ([string]$m.body) }
        }
    } finally { $script:loading = $false }
    $script:ui.Editor.IsEnabled = [bool]$m
    $script:ui.Delete.IsEnabled = [bool]$m
    $script:ui.Delete.ToolTip = if ($m) { '이 메모 삭제' } else { '메모를 먼저 고르세요' }
    $script:listUpdating = $true
    try { $script:ui.List.SelectedItem = $script:ui.List.Items | Where-Object Id -eq $script:currentId | Select-Object -First 1 }
    finally { $script:listUpdating = $false }
    Set-WtMemoStatus $(if ($m) { 'saved' } else { '' })
}

# 편집 | 미리보기
function Update-WtMemoMode {
    $edit = [string](Get-WtSetting 'memo.mode') -eq 'edit'
    if (-not $edit) {
        if (-not (Save-WtMemoNow)) { return }
        $m = Get-WtMemoById $script:currentId
        if ($m) {
            $script:ui.TitleText.Text = $m.title
            if ($script:ui.MdView.Tag.Text -cne [string]$m.body -or $script:ui.MdView.Tag.Error) { Set-WtMarkdownText $script:ui.MdView ([string]$m.body) }
        }
    }
    $script:ui.Editor.Visibility = if ($edit) { 'Visible' } else { 'Collapsed' }
    $script:ui.Preview.Visibility = if ($edit) { 'Collapsed' } else { 'Visible' }
    $script:ui.TitleBox.Visibility = $script:ui.Editor.Visibility
    $script:ui.TitleText.Visibility = $script:ui.Preview.Visibility
    foreach ($rb in $script:ui.ModeButtons) { $rb.IsChecked = ([string]$rb.Tag.Value -eq $(if ($edit) { 'edit' } else { 'preview' })) }
}

function Switch-WtMemoMode {
    if (-not (Save-WtMemoNow)) { return }
    Set-WtSetting 'memo.mode' $(if ([string](Get-WtSetting 'memo.mode') -eq 'edit') { 'preview' } else { 'edit' })
    Update-WtMemoMode
}

# 저장 상태 표시: saved · dirty · error · ''(숨김)
function Set-WtMemoStatus([string]$State, [string]$Detail = '') {
    $s = $script:ui.Status
    $stamp = if ($State -eq 'saved') { [string](Get-WtMemoById $script:currentId).updated } else { '' }
    $key = @($State, $Detail, $stamp) -join "`n"
    if ($s.Tag -ceq $key) { return }
    switch ($State) {
        'saved' {
            $m = Get-WtMemoById $script:currentId
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
        default { $s.Visibility = 'Collapsed' }
    }
    $s.Tag = $key
}

# 고친 내용이 있으면 바로 저장한다. 저장 시각 · 목록도 고친다
function Save-WtMemoNow {
    if ($script:saveTimer) { $script:saveTimer.Stop() }
    if (-not $script:dirty) { return $true }
    $m = Get-WtMemoById $script:currentId
    if (-not $m) { Set-WtMemoStatus 'error' '편집 중인 메모를 찾을 수 없습니다.'; return $false }
    try {
        $candidate = $m.PSObject.Copy()
        [void](Set-WtMemoContent $candidate $script:ui.TitleBox.Text $script:ui.BodyBox.Text)
        $next = @(foreach ($item in $script:items) { if ($item.id -eq $m.id) { $candidate } else { $item } })
        Save-WtMemoItems $next
        $script:dirty = $false
        $script:items = @(Get-WtMemoSorted $next)
        $script:ui.Meta.Text = '만든 날 {0} · 고친 날 {1}' -f $candidate.created, $candidate.updated
        Update-WtMemoList -KeepCurrent
        Set-WtMemoStatus 'saved'
        return $true
    } catch {
        Set-WtMemoStatus 'error' $_.Exception.Message
        return $false
    }
}

function Set-WtMemoDirty {
    if ($script:loading -or -not $script:currentId) { return }
    $script:dirty = $true
    Set-WtMemoStatus 'dirty'
    $script:saveTimer.Stop()
    $script:saveTimer.Start()
}

function Add-WtMemo {
    if (-not (Save-WtMemoNow)) { return }
    $m = New-WtMemo
    $next = @($m) + @($script:items)
    try { Save-WtMemoItems $next } catch { Show-WtError $_ '새 메모 저장'; return }
    $script:items = $next
    if ($script:ui.Search.Text) { $script:ui.Search.Text = '' }
    $script:currentId = $null
    Update-WtMemoList
    Select-WtMemoItem $m.id
    if ([string](Get-WtSetting 'memo.mode') -ne 'edit') { Set-WtSetting 'memo.mode' 'edit'; Update-WtMemoMode }
    [void]$script:ui.TitleBox.Focus()
}

function Remove-WtMemoCurrent {
    if (-not (Save-WtMemoNow)) { return }
    $m = Get-WtMemoById $script:currentId
    if (-not $m) { return }
    $script:dirty = $false
    $script:saveTimer.Stop()
    $index = [array]::IndexOf(@($script:items), $m)
    $next = @($script:items | Where-Object { $_.id -ne $m.id })
    try { Save-WtMemoItems $next } catch { Show-WtError $_ '메모 삭제'; return }
    $script:items = $next
    $script:rowCache.Remove($m.id)
    $script:lastDeleted = @{ Memo = $m; Index = $index }
    $script:currentId = $null
    Update-WtMemoList
    # 되돌리기: 10초 동안 실행 취소 버튼
    $script:ui.UndoText.Text = "'$($m.title)' 삭제함"
    $script:ui.UndoBar.Visibility = 'Visible'
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
    $script:lastDeleted = $null
    $script:ui.UndoBar.Visibility = 'Collapsed'
    Update-WtMemoList
    Select-WtMemoItem $d.Memo.id
}

# 본문의 링크를 눌렀을 때. [[제목]]은 제목이 같은 메모를 열고, #태그는 그 태그로 찾는다. 처리했으면 $true
function Invoke-WtMemoLink($Link) {
    switch ($Link.Kind) {
        'wiki' {
            $name = ([string]$Link.Target -split '#')[0].Trim()
            $m = $script:items | Where-Object { ([string]$_.title).Trim() -eq $name } | Select-Object -First 1
            if (-not $m) { return $false }
            Select-WtMemoItem $m.id
            return $true
        }
        'tag' {
            $script:ui.Search.Text = "#$($Link.Target)"
            return $true
        }
    }
    $false
}

# 목록에서 메모 하나를 고른다. 검색에 걸러져 안 보이면 검색을 비운다
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

# 목록을 다시 그린다. 열려 있는 메모는 그대로 골라 두고 오른쪽 칸은 다시 채우지 않는다 (편집 중 글자 위치 유지)
function Update-WtMemoList([switch]$KeepCurrent) {
    if ($script:listUpdating) { return }
    if (-not $KeepCurrent -and -not (Save-WtMemoNow)) { return }
    $list = $script:ui.List
    $keep = $script:currentId
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
        $list.SelectedItem = $list.Items | Where-Object Id -eq $keep | Select-Object -First 1
        if (-not $list.SelectedItem -and $list.Items.Count) { $list.SelectedIndex = 0 }
    } finally { $script:listUpdating = $false }
    $selectedId = if ($list.SelectedItem) { $list.SelectedItem.Id } else { '' }
    if ($selectedId -ne $script:currentId) { Show-WtMemo $selectedId }
    $script:listQuery = [string]$script:ui.Search.Text
}

function New-WtMemoView {
    $script:viewStamp = $null
    $script:listQuery = $null
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
    $add = New-WtButton '새 메모' -Kind Primary -Icon 0xE710 -ToolTip '새 메모 (Ctrl+N)'
    $add.Add_Click({ Add-WtMemo })
    $header = New-WtPageHeader '메모' '' $add
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
    $search.ToolTip = '띄어 쓰면 낱말이 모두 들어간 메모만 (#태그도 찾음)'
    $search.Add_TextChanged({ Update-WtMemoList })
    $sb.Root.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    [System.Windows.Controls.DockPanel]::SetDock($sb.Root, 'Top')
    [void]$ldock.Children.Add($sb.Root)
    $list = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $list 'Memo.List'
    $list.Add_SelectionChanged({
            param($s, $e)
            if ($script:listUpdating -or -not $s.SelectedItem) { return }
            $id = [string]$s.SelectedItem.Id
            if ($id -ne $script:currentId) {
                if (Save-WtMemoNow) { Show-WtMemo $id }
                else { $script:listUpdating = $true; try { Select-WtMemoItem $script:currentId } finally { $script:listUpdating = $false } }
            }
        })
    [void]$ldock.Children.Add($list)
    $left.Child = $ldock
    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$grid.Children.Add($left)

    # 오른쪽: 편집 | 미리보기
    $right = New-WtCard
    $rdock = [System.Windows.Controls.DockPanel]::new()

    $top = [System.Windows.Controls.DockPanel]::new()
    $top.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $status = [System.Windows.Controls.Label]::new()
    Set-WtResource $status 'FontFamily' 'Font.UI'
    Set-WtResource $status 'FontSize' 'F.Small'
    $status.Padding = [System.Windows.Thickness]::new(0)
    $status.VerticalAlignment = 'Center'
    [System.Windows.Controls.DockPanel]::SetDock($status, 'Right')
    [void]$top.Children.Add($status)
    $mode = New-WtSegmented @(@('edit', '편집'), @('preview', '미리보기')) ([string](Get-WtSetting 'memo.mode')) 'WtMemoMode' {
        param($value)
        if (-not (Save-WtMemoNow)) { Update-WtMemoMode; return }
        Set-WtSetting 'memo.mode' $value
        Update-WtMemoMode
    }
    $mode.ToolTip = '편집 / 미리보기 (Ctrl+E)'
    [void]$top.Children.Add($mode)
    [System.Windows.Controls.DockPanel]::SetDock($top, 'Top')
    [void]$rdock.Children.Add($top)

    $head = New-WtStack Vertical 4
    $titleText = New-WtText '' 'T.H2'
    Set-WtResource $titleText 'FontSize' 'F.Number'
    $titleBox = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $titleBox 'Input.Title'
    $titleBox.ToolTip = '제목 (비우면 저장 시각)'
    $titleBox.Add_TextChanged({ Set-WtMemoDirty })
    $meta = New-WtText '' 'T.Sub'
    [void](Add-WtChild $head $titleText)
    [void](Add-WtChild $head $titleBox)
    [void](Add-WtChild $head $meta)
    $line = [System.Windows.Controls.Border]::new()
    Set-WtStyle $line 'Divider'
    $line.Margin = [System.Windows.Thickness]::new(0, 12, 0, 12)
    [void]$head.Children.Add($line)
    [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
    [void]$rdock.Children.Add($head)

    # 아래: 삭제 + 실행 취소 막대
    $bottom = [System.Windows.Controls.DockPanel]::new()
    $bottom.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    $del = New-WtButton '삭제' -Kind Danger -Icon 0xE74D
    $del.Add_Click({ Remove-WtMemoCurrent })
    [System.Windows.Controls.DockPanel]::SetDock($del, 'Left')
    [void]$bottom.Children.Add($del)
    $undoBar = New-WtStack Horizontal 8
    $undoBar.Visibility = 'Collapsed'
    $undoBar.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $undoText = New-WtText '' 'T.Sub'
    $undoText.VerticalAlignment = 'Center'
    $undo = New-WtButton '실행 취소' -Kind Link -Icon 0xE7A7 -ToolTip '삭제 되돌리기'
    $undo.Add_Click({ Restore-WtMemoDeleted })
    [void](Add-WtChild $undoBar $undoText)
    [void](Add-WtChild $undoBar $undo)
    [void]$bottom.Children.Add($undoBar)
    $sep = [System.Windows.Controls.Border]::new()
    Set-WtStyle $sep 'Divider'
    $bwrap = New-WtStack Vertical
    [void]$bwrap.Children.Add($sep)
    [void]$bwrap.Children.Add($bottom)
    [System.Windows.Controls.DockPanel]::SetDock($bwrap, 'Bottom')
    [void]$rdock.Children.Add($bwrap)

    $body = [System.Windows.Controls.Grid]::new()
    $mdView = New-WtMarkdownView -Scroll -OnLink { param($link) Invoke-WtMemoLink $link }
    $bodyBox = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $bodyBox 'Editor'
    $bodyBox.ToolTip = $null
    $bodyBox.Add_TextChanged({ Set-WtMemoDirty })
    $bodyBox.Add_LostKeyboardFocus({ [void](Save-WtMemoNow) })
    $titleBox.Add_LostKeyboardFocus({ [void](Save-WtMemoNow) })
    [void]$body.Children.Add($mdView)
    [void]$body.Children.Add($bodyBox)
    [void]$rdock.Children.Add($body)
    $right.Child = $rdock
    [System.Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$grid.Children.Add($right)
    [void]$page.Panel.Children.Add($grid)

    # 메모 화면 안 단축키
    $page.Root.Add_PreviewKeyDown({
            param($s, $e)
            $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
            if (-not $ctrl) { return }
            switch ($e.Key) {
                'N' { Add-WtMemo; $e.Handled = $true }
                'S' { [void](Save-WtMemoNow); $e.Handled = $true }
                'E' { Switch-WtMemoMode; $e.Handled = $true }
            }
        })

    $script:ui = @{
        Search = $search; List = $list; Status = $status; TitleText = $titleText; TitleBox = $titleBox; Meta = $meta
        MdView = $mdView; BodyBox = $bodyBox; Editor = $bodyBox; Preview = $mdView; Delete = $del
        UndoBar = $undoBar; UndoText = $undoText
        ModeButtons = @($mode.Child.Children)
    }
    Update-WtMemoMode
    $page.Root
}

function Update-WtMemoView {
    if (-not (Save-WtMemoNow)) { return }
    $stamp = @((Get-WtStoreStamp 'memo'), [datetime]::Today.Ticks) -join '|'
    if ($script:viewStamp -ceq $stamp -and $script:listQuery -ceq [string]$script:ui.Search.Text) {
        # 원래 재진입처럼 첫 항목을 다시 고른다. 바뀌지 않은 전체 행을 다시 순회하지 않는다.
        $script:currentId = $null
        $id = if ($script:ui.List.Items.Count) { [string]$script:ui.List.Items[0].Id } else { '' }
        Show-WtMemo $id
        return
    }
    if ($script:viewStamp -cne $stamp) {
        $script:items = @(Get-WtMemoSorted (Get-WtMemoItems))
        $present = @{}
        foreach ($item in $script:items) { $present[$item.id] = $true }
        foreach ($id in @($script:rowCache.Keys)) { if (-not $present.ContainsKey($id)) { $script:rowCache.Remove($id) } }
        $script:viewStamp = $stamp
    }
    $script:currentId = $null
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

Register-WtAddon -Id 'memo' -Title '메모' -Icon 0xE70B -Order 40 -WarmUp Full `
    -NewView { New-WtMemoView } `
    -Refresh { param($view) Update-WtMemoView } `
    -HomeCard { New-WtMemoHomeCard } `
    -ImportLegacy { param($folder) Import-WtMemoLegacy $folder } `
    -SavePending { if ($script:ui.Count) { Save-WtMemoNow } else { $true } } `
    -OnExit { if ($script:ui.Count) { [void](Save-WtMemoNow) }; if ($script:saveTimer) { $script:saveTimer.Stop() }; if ($script:undoTimer) { $script:undoTimer.Stop() } } `
    -Help '메모는 쓰고 고칠 수 있습니다.' `
    -Shortcuts @(@('Ctrl + N', '새 메모'), @('Ctrl + S', '바로 저장 (보통은 자동 저장)'), @('Ctrl + E', '편집 / 미리보기')) `
    -HelpCard { New-WtMemoMarkdownHelpCard }

Export-ModuleMember -Function Get-WtMemoItems, Get-WtMemoSorted, Find-WtMemo, Format-WtMemoTime, Import-WtMemoLegacy,
    New-WtMemo, Get-WtMemoTags, Set-WtMemoContent, Save-WtMemoItems

# 메모 데이터 · 검색. 화면과 파일 I/O 없이 core/Storage.psm1의 핸들만 쓴다.
$ErrorActionPreference = 'Stop'
$script:memoInv = [Globalization.CultureInfo]::InvariantCulture

# ---- 검색식: Scope(검색 전체) + Root(칩과 공유하는 조건 트리) ---------------------------------
# 노드: all / term(Field, Value) / not(Child) / and|or(Children).
# 성공: { Success, Scope(active|archived|all), Root, Error=$null }
# 실패: Error = { Position(0부터, UTF-16), Length, Reason }. 저장하는 트리에는 위치를 넣지 않는다.
function Stop-WtMemoQuery($Reader, [int]$Position, [int]$Length, [string]$Reason) {
    $Reader.Error = [pscustomobject]@{ Position = $Position; Length = $Length; Reason = $Reason }
    throw [FormatException]::new($Reason)
}

function Read-WtMemoQueryTokens([string]$Text, $Reader) {
    $tokens = [Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $Text.Length) {
        if ([char]::IsWhiteSpace($Text[$i])) { $i++; continue }
        $start = $i; $c = $Text[$i]
        if ($c -in '(', ')', '-') {
            $tokens.Add(@{ Type = [string]$c; Position = $i; Length = 1 }); $i++; continue
        }
        $buf = [Text.StringBuilder]::new(); $quoted = $false; $prefix = ''
        while ($i -lt $Text.Length -and -not [char]::IsWhiteSpace($Text[$i]) -and $Text[$i] -notin '(', ')') {
            if ($Text[$i] -eq '"') {
                $quoted = $true; $quoteAt = $i; $i++; $closed = $false
                while ($i -lt $Text.Length) {
                    if ($Text[$i] -eq '"') { $i++; $closed = $true; break }
                    if ($Text[$i] -eq '\' -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -in '"', '\') { $i++ }
                    [void]$buf.Append($Text[$i]); $i++
                }
                if (-not $closed) { Stop-WtMemoQuery $Reader $quoteAt ($Text.Length - $quoteAt) '닫는 따옴표가 없습니다.' }
            } else {
                if ($Text[$i] -eq ':' -and -not $quoted -and -not $prefix) { $prefix = $buf.ToString().ToLowerInvariant() }
                [void]$buf.Append($Text[$i]); $i++
            }
        }
        $value = $buf.ToString(); $type = 'atom'
        if (-not $quoted -and $value.ToUpperInvariant() -in 'AND', 'OR') { $type = $value.ToLowerInvariant() }
        $tokens.Add(@{ Type = $type; Text = $value; Prefix = $prefix; Quoted = $quoted; Position = $start; Length = $i - $start })
    }
    $tokens.Add(@{ Type = 'end'; Position = $Text.Length; Length = 0 })
    $tokens.ToArray()
}

function New-WtMemoQueryGroup([string]$Kind, [object[]]$Children) {
    $flat = [Collections.Generic.List[object]]::new()
    foreach ($child in $Children) {
        if ($null -eq $child) { continue }
        $flat.Add($child)
    }
    if ($flat.Count -eq 0) { return $null }
    if ($flat.Count -eq 1) { return $flat[0] }
    [pscustomobject]@{ Kind = $Kind; Children = $flat.ToArray() }
}

function Read-WtMemoQueryTerm($Reader) {
    $token = $Reader.Tokens[$Reader.At]; $Reader.At++
    $field = 'text'; $value = [string]$token.Text
    if ($token.Prefix) { $field = $token.Prefix; $value = $value.Substring($field.Length + 1) }
    elseif (-not $token.Quoted -and $value.StartsWith('#')) { $field = 'tag'; $value = $value.Substring(1) }
    if (-not $value) { Stop-WtMemoQuery $Reader $token.Position $token.Length '조건 값이 비었습니다.' }
    if ($field -notin 'text', 'title', 'body', 'tag', 'folder', 'is', 'scope', 'updated', 'created', 'has', 'no', 'linksto') {
        Stop-WtMemoQuery $Reader $token.Position $token.Length "모르는 조건입니다: $field"
    }
    switch ($field) {
        'is' { if ($value -ine 'pinned') { Stop-WtMemoQuery $Reader $token.Position $token.Length 'is:에는 pinned를 씁니다.' }; $value = 'pinned' }
        'has' { if ($value.ToLowerInvariant() -notin 'link', 'backlink') { Stop-WtMemoQuery $Reader $token.Position $token.Length 'has:에는 link 또는 backlink를 씁니다.' }; $value = $value.ToLowerInvariant() }
        'no' { if ($value -ine 'tag') { Stop-WtMemoQuery $Reader $token.Position $token.Length 'no:에는 tag를 씁니다.' }; $value = 'tag' }
        'scope' {
            $value = $value.ToLowerInvariant()
            if ($value -notin 'archived', 'all') { Stop-WtMemoQuery $Reader $token.Position $token.Length 'scope:에는 archived 또는 all을 씁니다.' }
            if ($Reader.Scope -and $Reader.Scope -ne $value) { Stop-WtMemoQuery $Reader $token.Position $token.Length '검색 전체 범위는 하나만 정합니다.' }
            $Reader.Scope = $value
            return [pscustomobject]@{ Kind = 'scope'; Position = $token.Position; Length = $token.Length }
        }
        { $_ -in 'updated', 'created' } {
            if ($value -match '^([1-9][0-9]*)[dD]$') {
                $days = 0
                if (-not [int]::TryParse($Matches[1], [Globalization.NumberStyles]::None, $script:memoInv, [ref]$days) -or $days -gt 109573) {
                    Stop-WtMemoQuery $Reader $token.Position $token.Length '최근 날짜 수가 너무 큽니다.'
                }
                $value = $days.ToString($script:memoInv) + 'd'
            } else {
                $parts = $value.TrimStart('<', '>') -split '\.\.'
                if ($parts.Count -gt 2 -or ($value.StartsWith('<') -or $value.StartsWith('>')) -and $parts.Count -ne 1) {
                    Stop-WtMemoQuery $Reader $token.Position $token.Length '날짜 조건은 날짜, 시작..끝, <날짜, >날짜로 씁니다.'
                }
                foreach ($dateText in $parts) {
                    if ($null -eq (ConvertFrom-WtDateText $dateText)) { Stop-WtMemoQuery $Reader $token.Position $token.Length '날짜는 1900~2199년의 yyyy-MM-dd로 씁니다.' }
                }
                if ($parts.Count -eq 2 -and [string]::CompareOrdinal($parts[0], $parts[1]) -gt 0) {
                    Stop-WtMemoQuery $Reader $token.Position $token.Length '시작 날짜가 끝 날짜보다 늦습니다.'
                }
            }
        }
    }
    [pscustomobject]@{ Kind = 'term'; Field = $field; Value = $value }
}

function Read-WtMemoQueryUnary($Reader) {
    $token = $Reader.Tokens[$Reader.At]
    if ($token.Type -eq '-') {
        $Reader.At++; $child = Read-WtMemoQueryUnary $Reader
        if (Test-WtMemoQueryScopeNode $child) { Stop-WtMemoQuery $Reader $token.Position 1 'scope:는 검색 전체 범위라 부정할 수 없습니다.' }
        return [pscustomobject]@{ Kind = 'not'; Child = $child }
    }
    if ($token.Type -eq '(') {
        $Reader.At++; $child = Read-WtMemoQueryOr $Reader
        $next = $Reader.Tokens[$Reader.At]
        if ($next.Type -ne ')') { Stop-WtMemoQuery $Reader $next.Position $next.Length '닫는 괄호가 필요합니다.' }
        $Reader.At++; return $child
    }
    if ($token.Type -ne 'atom') { Stop-WtMemoQuery $Reader $token.Position $token.Length '검색 조건이 필요합니다.' }
    Read-WtMemoQueryTerm $Reader
}

function Test-WtMemoQueryScopeNode($Node) {
    if ($Node.Kind -eq 'scope') { return $true }
    foreach ($child in @($Node.Children)) { if ($null -ne $child -and (Test-WtMemoQueryScopeNode $child)) { return $true } }
    $false
}

function Read-WtMemoQueryAnd($Reader) {
    $children = [Collections.Generic.List[object]]::new(); $children.Add((Read-WtMemoQueryUnary $Reader))
    while ($true) {
        $next = $Reader.Tokens[$Reader.At]
        if ($next.Type -in 'end', ')', 'or') { break }
        if ($next.Type -eq 'and') { $Reader.At++ }
        $children.Add((Read-WtMemoQueryUnary $Reader))
    }
    New-WtMemoQueryGroup 'and' $children.ToArray()
}

function Read-WtMemoQueryOr($Reader) {
    $children = [Collections.Generic.List[object]]::new(); $children.Add((Read-WtMemoQueryAnd $Reader))
    while ($Reader.Tokens[$Reader.At].Type -eq 'or') { $Reader.At++; $children.Add((Read-WtMemoQueryAnd $Reader)) }
    New-WtMemoQueryGroup 'or' $children.ToArray()
}

function Remove-WtMemoScopeNode($Node) {
    if ($Node.Kind -eq 'scope') { return $null }
    if ($Node.Kind -in 'and', 'or') {
        $children = @(foreach ($child in $Node.Children) { Remove-WtMemoScopeNode $child })
        return New-WtMemoQueryGroup $Node.Kind $children
    }
    $Node
}

function ConvertFrom-WtMemoQuery {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Text = '')
    $reader = @{ At = 0; Tokens = @(); Scope = ''; Error = $null }
    try {
        $reader.Tokens = @(Read-WtMemoQueryTokens $Text $reader)
        $root = $null
        if ($reader.Tokens[0].Type -ne 'end') {
            $root = Read-WtMemoQueryOr $reader
            $next = $reader.Tokens[$reader.At]
            if ($next.Type -ne 'end') { Stop-WtMemoQuery $reader $next.Position $next.Length '괄호 또는 연산자 위치가 잘못됐습니다.' }
            $root = Remove-WtMemoScopeNode $root
        }
        if ($null -eq $root) { $root = [pscustomobject]@{ Kind = 'all' } }
        [pscustomobject]@{ Success = $true; Scope = $(if ($reader.Scope) { $reader.Scope } else { 'active' }); Root = $root; Error = $null }
    } catch [FormatException] {
        [pscustomobject]@{ Success = $false; Scope = 'active'; Root = $null; Error = $reader.Error }
    }
}

function ConvertTo-WtMemoQueryNode($Node) {
    switch ($Node.Kind) {
        'all' { return '' }
        'term' {
            $value = ([string]$Node.Value).Replace('\', '\\').Replace('"', '\"')
            if ($Node.Field -in 'updated', 'created', 'is', 'has', 'no') { return "$($Node.Field):$value" }
            $prefix = if ($Node.Field -eq 'text') { '' } else { "$($Node.Field):" }
            return $prefix + '"' + $value + '"'
        }
        'not' { return '-(' + (ConvertTo-WtMemoQueryNode $Node.Child) + ')' }
        { $_ -in 'and', 'or' } {
            $parts = @(foreach ($child in $Node.Children) { '(' + (ConvertTo-WtMemoQueryNode $child) + ')' })
            return $parts -join $(if ($Node.Kind -eq 'and') { ' AND ' } else { ' OR ' })
        }
        default { throw '모르는 메모 검색 노드입니다.' }
    }
}

function ConvertTo-WtMemoQuery {
    param([Parameter(Mandatory, Position = 0)]$Query)
    if ($Query.Success -eq $false) { throw '오류가 있는 검색식은 글로 만들 수 없습니다.' }
    if ($Query.Scope -notin 'active', 'all', 'archived') { throw '모르는 검색 범위입니다.' }
    $text = ConvertTo-WtMemoQueryNode $Query.Root
    if ($Query.Scope -ne 'active') { $text = ("scope:$($Query.Scope) " + $text).TrimEnd() }
    $check = ConvertFrom-WtMemoQuery $text
    if (-not $check.Success) { throw $check.Error.Reason }
    $text
}

# ---- 색인: 사본만 보관, 제목/연결 역목록으로 한 메모 갱신 --------------------------------------
function New-WtMemoStringSet { , [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }

function Get-WtMemoLinkInfo([string]$Body) {
    $info = @{ Outgoing = (New-WtMemoStringSet); HasLink = $false }
    $walk = {
        param($nodes)
        foreach ($node in @($nodes)) {
            if ($null -eq $node) { continue }
            if ($node.T -eq 'link') {
                $info.HasLink = $true
                if ($node.Kind -eq 'wiki') {
                    $name = (([string]$node.Target) -split '#', 2)[0].Trim().ToLowerInvariant()
                    if ($name) { [void]$info.Outgoing.Add($name) }
                }
            }
            foreach ($key in 'Inl', 'Title', 'Blocks', 'Items') { if ($node.$key -is [array]) { & $walk $node.$key } }
            foreach ($cell in @($node.Cells)) { if ($cell) { & $walk $cell } }
        }
    }
    & $walk (ConvertTo-WtMarkdownModel $Body).Blocks
    $info
}

# 옛 memo.json의 시간대 없는 앱 시각도 읽되 글 자체는 바꾸지 않는다.
function Get-WtMemoIndexedTime([string]$Text) {
    $at = ConvertFrom-WtStamp $Text
    if ($null -ne $at) { return $at }
    $old = ConvertFrom-WtLegacyStamp $Text
    if ($old) { return ConvertFrom-WtStamp $old }
    $null
}

function Add-WtMemoIndexMap($Map, [string]$Key, [string]$Id) {
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = New-WtMemoStringSet }
    [void]$Map[$Key].Add($Id)
}

function Remove-WtMemoIndexMap($Map, [string]$Key, [string]$Id) {
    if ($Map.ContainsKey($Key)) { [void]$Map[$Key].Remove($Id); if ($Map[$Key].Count -eq 0) { [void]$Map.Remove($Key) } }
}

function Set-WtMemoIndexEntry($Index, $Memo) {
    $id = Get-WtField $Memo 'id'
    if ($id -isnot [string] -or -not $id -or (Test-WtDeleted $Memo)) { return }
    $title = [string](Get-WtField $Memo 'title'); $body = [string](Get-WtField $Memo 'body')
    $tags = New-WtMemoStringSet
    $rawTags = Get-WtField $Memo 'tags'
    foreach ($tag in $rawTags) { if ($tag -is [string]) { [void]$tags.Add($tag.ToLowerInvariant()) } }
    $links = Get-WtMemoLinkInfo $body
    $created = Get-WtMemoIndexedTime ([string](Get-WtField $Memo 'created'))
    $updated = Get-WtMemoIndexedTime ([string](Get-WtField $Memo 'updated'))
    $order = ConvertFrom-WtWhole (Get-WtField $Memo 'pinOrder') ([long]::MinValue) ([long]::MaxValue)
    $entry = [pscustomobject]@{
        Id = $id; Title = $title; Body = $body; TitleLower = $title.ToLowerInvariant(); BodyLower = $body.ToLowerInvariant()
        Tags = $tags; Folder = [string](Get-WtField $Memo 'folder'); Pinned = ((Get-WtField $Memo 'pinned') -eq $true)
        PinOrder = $(if ($null -eq $order) { [long]::MaxValue } else { $order }); Archived = ((Get-WtField $Memo 'archived') -eq $true)
        Created = $created; Updated = $updated; Outgoing = $links.Outgoing; HasLink = $links.HasLink; BacklinkCount = 0
        TitleOrdinal = 0; IdOrdinal = 0
    }
    $Index.Entries[$id] = $entry
    Add-WtMemoIndexMap $Index.Titles $entry.TitleLower $id
    foreach ($target in $entry.Outgoing) { Add-WtMemoIndexMap $Index.Sources $target $id }
}

function Update-WtMemoBacklinks($Index, [string]$TitleLower) {
    if (-not $Index.Titles.ContainsKey($TitleLower)) { return }
    # 제목이 겹치면 임의로 한 메모로 확정하지 않는다. 검색은 후보 id를 담은 오류로 돌려준다.
    $count = if ($Index.Titles[$TitleLower].Count -eq 1 -and $Index.Sources.ContainsKey($TitleLower)) { $Index.Sources[$TitleLower].Count } else { 0 }
    foreach ($id in $Index.Titles[$TitleLower]) { $Index.Entries[$id].BacklinkCount = $count }
}

# 제목/id는 .NET ordinal로 순서를 매긴다. 검색마다 PowerShell 비교 함수를 수만 번 부르지 않는다.
function Update-WtMemoIndexOrder($Index) {
    $titles = [string[]]@($Index.Titles.Keys); [Array]::Sort($titles, [StringComparer]::Ordinal)
    for ($i = 0; $i -lt $titles.Count; $i++) { foreach ($id in $Index.Titles[$titles[$i]]) { $Index.Entries[$id].TitleOrdinal = $i } }
    $ids = [string[]]@($Index.Entries.Keys); [Array]::Sort($ids, [StringComparer]::Ordinal)
    for ($i = 0; $i -lt $ids.Count; $i++) { $Index.Entries[$ids[$i]].IdOrdinal = $i }
}

function New-WtMemoIndex {
    param([Parameter(Position = 0)][AllowEmptyCollection()][object[]]$Memos = @(), [object[]]$Folders)
    if (-not $PSBoundParameters.ContainsKey('Folders')) { $Folders = @(Get-WtMemoDefaultFolders) }
    $index = [pscustomobject]@{
        Entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        Titles = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        Sources = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        Folders = @($Folders)
    }
    $seen = New-WtMemoStringSet
    foreach ($memo in $Memos) {
        $id = Get-WtField $memo 'id'
        if ($id -is [string] -and $seen.Add($id)) { Set-WtMemoIndexEntry $index $memo }
    }
    foreach ($titleLower in $index.Titles.Keys) { Update-WtMemoBacklinks $index $titleLower }
    Update-WtMemoIndexOrder $index
    $index
}

function Update-WtMemoIndex {
    [CmdletBinding(DefaultParameterSetName = 'memo')]
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory, ParameterSetName = 'memo')]$Memo,
        [Parameter(Mandatory, ParameterSetName = 'remove')][string]$Remove)
    $id = if ($PSCmdlet.ParameterSetName -eq 'remove') { $Remove } else { [string](Get-WtField $Memo 'id') }
    $affected = New-WtMemoStringSet
    if ($Index.Entries.ContainsKey($id)) {
        $old = $Index.Entries[$id]; [void]$affected.Add($old.TitleLower)
        Remove-WtMemoIndexMap $Index.Titles $old.TitleLower $id
        foreach ($target in $old.Outgoing) { [void]$affected.Add($target); Remove-WtMemoIndexMap $Index.Sources $target $id }
        [void]$Index.Entries.Remove($id)
    }
    if ($PSCmdlet.ParameterSetName -eq 'memo') {
        Set-WtMemoIndexEntry $Index $Memo
        if ($Index.Entries.ContainsKey($id)) {
            $entry = $Index.Entries[$id]; [void]$affected.Add($entry.TitleLower)
            foreach ($target in $entry.Outgoing) { [void]$affected.Add($target) }
        }
    }
    foreach ($titleLower in $affected) { Update-WtMemoBacklinks $Index $titleLower }
    Update-WtMemoIndexOrder $Index
}

function Get-WtMemoQueryTerms($Node, [switch]$Negated) {
    if ($Node.Kind -eq 'term') { if (-not $Negated) { $Node }; return }
    if ($Node.Kind -eq 'not') { Get-WtMemoQueryTerms $Node.Child -Negated:(-not $Negated); return }
    foreach ($child in @($Node.Children)) { if ($child) { Get-WtMemoQueryTerms $child -Negated:$Negated } }
}

function Get-WtMemoMatchSet($Index, $Node, [datetime]$Today) {
    $set = New-WtMemoStringSet
    switch ($Node.Kind) {
        'all' { $set.UnionWith([string[]]@($Index.Entries.Keys)); return , $set }
        'not' {
            $set.UnionWith([string[]]@($Index.Entries.Keys)); $set.ExceptWith((Get-WtMemoMatchSet $Index $Node.Child $Today)); return , $set
        }
        { $_ -in 'and', 'or' } {
            $first = $true
            foreach ($child in $Node.Children) {
                $part = Get-WtMemoMatchSet $Index $child $Today
                if ($first -or $Node.Kind -eq 'or') { $set.UnionWith($part) } else { $set.IntersectWith($part) }
                $first = $false
            }
            return , $set
        }
    }
    $value = ([string]$Node.Value).ToLowerInvariant(); $field = [string]$Node.Field
    $from = $null; $to = $null; $compare = ''; $folderIds = New-WtMemoStringSet
    if ($field -in 'updated', 'created') {
        if ($value -match '^([0-9]+)d$') { $from = $Today.AddDays(1 - [int]$Matches[1]); $to = $Today }
        elseif ($value.StartsWith('<') -or $value.StartsWith('>')) { $compare = $value.Substring(0, 1); $from = ConvertFrom-WtDateText $value.Substring(1) }
        else { $parts = $value -split '\.\.'; $from = ConvertFrom-WtDateText $parts[0]; $to = if ($parts.Count -eq 2) { ConvertFrom-WtDateText $parts[1] } else { $from } }
    }
    if ($field -eq 'folder') {
        foreach ($folder in $Index.Folders) {
            if ([string]::Equals([string]$folder.id, [string]$Node.Value, [StringComparison]::Ordinal) -or [string]::Equals([string]$folder.name, $value, [StringComparison]::OrdinalIgnoreCase)) {
                [void]$folderIds.Add([string]$folder.id)
            }
        }
    }
    if ($field -eq 'linksto') {
        $targetTitle = $value
        if ($Index.Entries.ContainsKey([string]$Node.Value)) { $targetTitle = $Index.Entries[[string]$Node.Value].TitleLower }
        if ($Index.Titles.ContainsKey($targetTitle)) {
            if ($Index.Titles[$targetTitle].Count -gt 1) { throw [ArgumentException]::new("같은 제목이 여럿입니다. 메모 id로 대상을 골라 주세요: $($Node.Value)") }
            if ($Index.Sources.ContainsKey($targetTitle)) { $set.UnionWith($Index.Sources[$targetTitle]) }
        }
        return , $set
    }
    foreach ($entry in $Index.Entries.Values) {
        $match = switch ($field) {
            'text' { $entry.TitleLower.Contains($value) -or $entry.BodyLower.Contains($value) }
            'title' { $entry.TitleLower.Contains($value) }
            'body' { $entry.BodyLower.Contains($value) }
            'tag' { $entry.Tags.Contains($value) }
            'folder' { $folderIds.Contains($entry.Folder) }
            'is' { $entry.Pinned }
            'has' { if ($value -eq 'link') { $entry.HasLink } else { $entry.BacklinkCount -gt 0 } }
            'no' { $entry.Tags.Count -eq 0 }
            { $_ -in 'updated', 'created' } {
                $stamp = if ($field -eq 'updated') { $entry.Updated } else { $entry.Created }
                if ($null -eq $stamp) { $false }
                else {
                    $day = $stamp.LocalDateTime.Date
                    if ($compare -eq '<') { $day -lt $from } elseif ($compare -eq '>') { $day -gt $from } else { $day -ge $from -and $day -le $to }
                }
            }
            default { $false }
        }
        if ($match) { [void]$set.Add($entry.Id) }
    }
    , $set
}

function Get-WtMemoOpenedMap($State, $Index) {
    $map = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($null -eq $State) { return , $map }
    $isMap = $State -is [Collections.IDictionary]
    $hasItems = $isMap -and (@($State.Keys) -ccontains 'items') -and $State['items'] -is [array]
    $items = if ($hasItems) { $State['items'] } elseif ($State.PSObject.Properties['Items']) { $State.Items } else { $State }
    if ($isMap -and -not $hasItems) {
        foreach ($key in $State.Keys) { if ($Index.Entries.ContainsKey([string]$key)) { $map[[string]$key] = $State[$key] } }
    } else {
        foreach ($item in @($items)) { if ($item.id -and $Index.Entries.ContainsKey([string]$item.id) -and -not $map.ContainsKey([string]$item.id)) { $map[[string]$item.id] = $item.opened } }
    }
    , $map
}

function Find-WtMemo {
    param([Parameter(Mandatory)]$Index, $Query = '', [ValidateSet('updated', 'created', 'title', 'opened', 'backlinks')][string]$Sort,
        [ValidateSet('asc', 'desc')][string]$Dir, [ValidateSet('normal', 'pinned', 'recent', 'archived', 'all', '일반', '고정', '최근 열기', '보관', '모두')][string]$View = 'normal', $OpenedMap)
    $tree = if ($Query -is [string]) { ConvertFrom-WtMemoQuery $Query } else { $Query }
    if ($tree.Success -eq $false) { return [pscustomobject]@{ Success = $false; Items = @(); Count = 0; Error = $tree.Error } }
    try {
        # 칩이 넘긴 구조도 문법 검사를 거쳐 동일한 해석을 사용한다.
        if ($Query -isnot [string]) { $tree = ConvertFrom-WtMemoQuery (ConvertTo-WtMemoQuery $tree) }
        $scope = $tree.Scope
        if ($scope -eq 'active') {
            if ($View -in 'archived', '보관') { $scope = 'archived' } elseif ($View -in 'all', '모두') { $scope = 'all' }
        }
        $set = Get-WtMemoMatchSet $Index $tree.Root ([datetime]::Today)
        $opened = Get-WtMemoOpenedMap $OpenedMap $Index
        $terms = @(Get-WtMemoQueryTerms $tree.Root | Where-Object { $_.Field -in 'text', 'title', 'body' })
        $joined = @($terms | ForEach-Object { [string]$_.Value }) -join ' '
        if (-not $Sort -and $View -in 'recent', '최근 열기') { $Sort = 'opened' }
        if ($Sort -and -not $Dir) { $Dir = if ($Sort -eq 'title') { 'asc' } else { 'desc' } }
        $rows = [Collections.Generic.List[object]]::new()
        $keys = [Collections.Generic.List[Tuple[long,int,long,long,int,int,object]]]::new()
        foreach ($id in $set) {
            $entry = $Index.Entries[$id]
            if (($scope -eq 'active' -and $entry.Archived) -or ($scope -eq 'archived' -and -not $entry.Archived)) { continue }
            if ($View -in 'pinned', '고정' -and -not $entry.Pinned) { continue }
            if ($View -in 'recent', '최근 열기' -and -not $opened.ContainsKey($id)) { continue }
            $locations = [Collections.Generic.List[object]]::new(); $rank = 3; $bodyAt = -1; $titleHits = 0; $matchedTerms = 0
            foreach ($term in $terms) {
                $needle = ([string]$term.Value).ToLowerInvariant()
                $ti = if ($term.Field -eq 'body') { -1 } else { $entry.TitleLower.IndexOf($needle, [StringComparison]::Ordinal) }
                $bi = if ($term.Field -eq 'title') { -1 } else { $entry.BodyLower.IndexOf($needle, [StringComparison]::Ordinal) }
                if ($ti -ge 0 -or $bi -ge 0) { $matchedTerms++ }
                if ($ti -ge 0) {
                    $titleHits++; $locations.Add([pscustomobject]@{ Field = 'title'; Start = $ti; Length = $needle.Length })
                    if ($entry.TitleLower -eq $needle) { $rank = 0 }
                }
                if ($bi -ge 0) {
                    $locations.Add([pscustomobject]@{ Field = 'body'; Start = $bi; Length = $needle.Length })
                    if ($bodyAt -lt 0 -or $bi -lt $bodyAt) { $bodyAt = $bi }
                }
            }
            if ($terms.Count) {
                if ([string]::Equals($entry.Title, $joined, [StringComparison]::OrdinalIgnoreCase) -and $titleHits -eq $terms.Count) { $rank = 0 }
                elseif ($rank -ne 0) { $rank = if ($titleHits -gt 0 -and $titleHits -eq $matchedTerms) { 1 } else { 2 } }
            }
            $start = if ($bodyAt -ge 0) { [Math]::Max(0, $bodyAt - 24) } else { 0 }
            $snippet = $entry.Body.Substring($start, [Math]::Min(80, $entry.Body.Length - $start))
            $folder = $null
            foreach ($candidate in $Index.Folders) { if ([string]::Equals([string]$candidate.id, $entry.Folder, [StringComparison]::Ordinal)) { $folder = $candidate; break } }
            $openedAt = if ($opened.ContainsKey($id)) { Get-WtMemoIndexedTime ([string]$opened[$id]) } else { $null }
            $rows.Add([pscustomobject]@{
                Id = $id; Title = $entry.Title; Matches = $locations.ToArray(); Snippet = $snippet; SnippetStart = $start
                Folder = $(if ($folder) { [string]$folder.id } else { $null }); FolderName = $(if ($folder) { [string]$folder.name } else { '폴더 없음' })
                Tags = [string[]]@($entry.Tags); Pinned = $entry.Pinned; PinOrder = $entry.PinOrder; Archived = $entry.Archived
                Rank = $rank; Updated = $entry.Updated; Created = $entry.Created; Opened = $openedAt; Backlinks = $entry.BacklinkCount
            })
            [long]$primary = if ($terms.Count) { $rank } else { 0 }
            if ($Sort) {
                $stamp = switch ($Sort) { 'updated' { $entry.Updated } 'created' { $entry.Created } 'opened' { $openedAt } }
                $primary = switch ($Sort) {
                    'title' { [long]$entry.TitleOrdinal }
                    'backlinks' { [long]$entry.BacklinkCount }
                    default { if ($null -eq $stamp) { -1L } else { $stamp.UtcTicks } }
                }
                if ($Dir -eq 'desc') { $primary = -$primary }
            }
            [long]$modified = if ($entry.Updated) { -$entry.Updated.UtcTicks } else { [long]::MaxValue }
            [long]$pinOrder = if ($entry.Pinned) { $entry.PinOrder } else { 0 }
            $keys.Add([Tuple[long,int,long,long,int,int,object]]::new($primary, [int](-not $entry.Pinned), $pinOrder, $modified, $entry.TitleOrdinal, $entry.IdOrdinal, $rows[$rows.Count - 1]))
        }
        $sortedKeys = $keys.ToArray()
        if ($rows.Count -gt 1) { [Array]::Sort($sortedKeys) }
        $resultRows = @(foreach ($key in $sortedKeys) { $key.Item7 })
        [pscustomobject]@{ Success = $true; Items = $resultRows; Count = $rows.Count; Error = $null }
    } catch {
        [pscustomobject]@{ Success = $false; Items = @(); Count = 0; Error = [pscustomobject]@{ Position = 0; Length = 0; Reason = $_.Exception.Message } }
    }
}

# ---- 저장: 공통 핸들 · 깊은 복사 · 모르는 칸/키/깨진 줄 보존 ---------------------------------
function Open-WtMemoStore { Open-WtStore -Name 'memo' -Schema 1 }

function Save-WtMemoStoreItems($Store, [object[]]$Items, [hashtable]$Extra) {
    if ($Store.Name -cne 'memo') { throw '메모 저장소 핸들이 아닙니다.' }
    Save-WtStore $Store @(Compress-WtDeletedItems $Items) -Extra $Extra
}

function Get-WtMemoDataStamp($At) {
    $when = if ($null -eq $At) { [DateTimeOffset]::Now } else { [DateTimeOffset]$At }
    Get-WtStamp ($when.ToOffset([timespan]::FromHours(9)))
}

function Get-WtMemoDefaultFolders {
    $names = '업무', '절차', '장애', '개인'; $ids = 'work', 'procedure', 'incident', 'personal'
    for ($i = 0; $i -lt 4; $i++) { [pscustomobject]@{ id = $ids[$i]; name = $names[$i]; order = ($i + 1) * 10; created = $null } }
}

function Get-WtMemoFolders {
    param($Store = (Open-WtMemoStore))
    if ($Store.State -notin 'ok', 'missing') { throw $Store.Error }
    $folders = Get-WtField $Store.Doc 'folders'
    if ($null -eq $folders) { return @(Get-WtMemoDefaultFolders) }
    if ($folders -isnot [array]) { throw 'folders가 목록이 아닙니다. 원문을 보존합니다.' }
    foreach ($folder in $folders) { , $folder }
}

function Get-WtMemoEditable($Store, [string]$Id) {
    $edit = Get-WtRecordEdit $Store $Id
    if (-not $edit.Success) { throw $edit.Reason }
    if (Test-WtDeleted $edit.Item) { throw '지운 메모는 정리할 수 없습니다.' }
    $edit
}

function Set-WtMemoFolder {
    param([Parameter(Mandatory)][string]$Id, [AllowNull()][string]$Folder, $Store = (Open-WtMemoStore))
    $edit = Get-WtMemoEditable $Store $Id
    if ($Folder -and -not @(Get-WtMemoFolders $Store | Where-Object { [string]::Equals([string]$_.id, $Folder, [StringComparison]::Ordinal) }).Count) { throw '없는 폴더입니다.' }
    Set-WtField $edit.Item 'folder' $(if ($Folder) { $Folder } else { $null })
    Set-WtItemEdited $edit.Item (Get-WtMemoDataStamp)
    Save-WtMemoStoreItems $Store $edit.Items
}

function Set-WtMemoPinned {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][bool]$Pinned, $Order, $Store = (Open-WtMemoStore))
    $edit = Get-WtMemoEditable $Store $Id
    if ($PSBoundParameters.ContainsKey('Order')) {
        $number = ConvertFrom-WtWhole $Order ([long]::MinValue) ([long]::MaxValue)
        if ($null -eq $number) { throw '고정 순서는 정수여야 합니다.' }
        Set-WtField $edit.Item 'pinOrder' $number
    }
    Set-WtField $edit.Item 'pinned' $Pinned
    Set-WtItemEdited $edit.Item (Get-WtMemoDataStamp)
    Save-WtMemoStoreItems $Store $edit.Items
}

function Set-WtMemoArchived {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][bool]$Archived, $Store = (Open-WtMemoStore))
    $edit = Get-WtMemoEditable $Store $Id; $now = Get-WtMemoDataStamp
    Set-WtField $edit.Item 'archived' $Archived
    Set-WtField $edit.Item 'archivedAt' $(if ($Archived) { $now } else { $null })
    Set-WtItemEdited $edit.Item $now
    Save-WtMemoStoreItems $Store $edit.Items
}

function Save-WtMemoFolders {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Folders, $Store = (Open-WtMemoStore))
    if ($Store.State -notin 'ok', 'missing') { throw $Store.Error }
    $ids = New-WtMemoStringSet; $list = [Collections.Generic.List[object]]::new(); $oldFolders = @(Get-WtMemoFolders $Store)
    foreach ($folder in $Folders) {
        $id = Get-WtField $folder 'id'; $name = Get-WtField $folder 'name'
        $order = ConvertFrom-WtWhole (Get-WtField $folder 'order') ([long]::MinValue) ([long]::MaxValue)
        if ($id -isnot [string] -or -not $id -or -not $ids.Add($id) -or $name -isnot [string] -or -not $name.Trim() -or $null -eq $order) { throw '폴더 id · 이름 · 순서를 확인하세요(id는 중복할 수 없습니다).' }
        $existing = @($oldFolders | Where-Object { [string]::Equals([string]$_.id, $id, [StringComparison]::Ordinal) })
        $copy = if ($existing.Count) { Copy-WtItem $existing[0] } else { Copy-WtItem $folder }
        Set-WtField $copy 'name' $name; Set-WtField $copy 'order' $order
        if (-not (Get-WtField $copy 'created')) { Set-WtField $copy 'created' (Get-WtMemoDataStamp) }
        $list.Add($copy)
    }
    $removed = New-WtMemoStringSet
    foreach ($folder in $oldFolders) { if (-not $ids.Contains([string]$folder.id)) { [void]$removed.Add([string]$folder.id) } }
    $items = @(Copy-WtItem @($Store.Items))
    foreach ($item in $items) {
        if ((Test-WtRecordObject $item) -and $removed.Contains([string](Get-WtField $item 'folder'))) {
            Set-WtField $item 'folder' $null; Set-WtItemEdited $item (Get-WtMemoDataStamp)
        }
    }
    $saved = Save-WtMemoStoreItems $Store $items -Extra @{ folders = $list.ToArray() }
    # Save-WtStore의 Doc는 열 때의 문서다. 새 핸들에만 Extra를 반영한다(옛 핸들은 그대로).
    $saved.Doc = if ($Store.Doc) { Copy-WtItem $Store.Doc } else { [pscustomobject]@{} }
    Set-WtField $saved.Doc 'folders' $list.ToArray()
    $saved
}

# 기존 화면이 넘기는 활성 목록을 원자료에 맞춘다. 화면 밖의 깨진 줄/지운 줄은 유지한다.
function Save-WtMemoDataItems {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [hashtable]$Extra)
    if ($Store.State -notin 'ok', 'missing') { throw $Store.Error }
    $incoming = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in $Items) {
        $id = Get-WtField $item 'id'
        if ($id -isnot [string] -or -not $id -or $incoming.ContainsKey($id)) { throw '저장할 메모 id가 없거나 겹칩니다.' }
        $incoming[$id] = $item
    }
    $original = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($old in $Store.Items) {
        $id = Get-WtField $old 'id'
        if ($id -is [string] -and $id -and -not $original.ContainsKey($id)) { $original[$id] = $old }
    }
    $active = [Collections.Generic.List[object]]::new()
    foreach ($item in $Items) {
        $id = [string]$item.id
        if ($original.ContainsKey($id)) {
            $copy = Copy-WtItem $original[$id]; Merge-WtRecordPatch $copy $item
            if (Test-WtDeleted $original[$id]) { Set-WtField $copy 'deleted' $null; Set-WtItemEdited $copy (Get-WtMemoDataStamp) }
            $active.Add($copy)
        } else { $active.Add((Copy-WtItem $item)) }
    }
    # 활성 목록은 부르는 쪽 순서를 따른다(옛 화면의 같은 초 정렬도 유지).
    # 숨긴 줄은 원래 자리에 두고 활성 자리만 채운다. 늘어난 분량은 뒤에 더한다.
    $next = [Collections.Generic.List[object]]::new(); $seen = New-WtMemoStringSet; $at = 0
    foreach ($old in $Store.Items) {
        $id = Get-WtField $old 'id'
        if ($id -isnot [string] -or -not $id -or -not $seen.Add($id)) { $next.Add($old); continue }
        if ($incoming.ContainsKey($id)) {
            $next.Add($active[$at]); $at++
        } elseif (Test-WtDeleted $old) { $next.Add($old) }
        else {
            $copy = Copy-WtItem $old; $now = Get-WtMemoDataStamp
            Set-WtField $copy 'deleted' $now; Set-WtItemEdited $copy $now; $next.Add($copy)
        }
    }
    while ($at -lt $active.Count) { $next.Add($active[$at]); $at++ }
    Save-WtMemoStoreItems $Store $next.ToArray() -Extra $Extra
}

function Set-WtMemoOpened {
    param([Parameter(Mandatory)][string]$Id, $Store = (Open-WtStore -Name 'memo-state' -Schema 1),
        $MemoStore = (Open-WtMemoStore), [string]$At = (Get-WtMemoDataStamp))
    [void](Get-WtMemoEditable $MemoStore $Id)
    $now = ConvertFrom-WtStamp $At
    if (-not $now) { throw '열람 시각이 앱 시각 모양이 아닙니다.' }
    if ($Store.State -notin 'ok', 'missing') { throw $Store.Error }
    $edit = Get-WtRecordEdit $Store $Id
    if (-not $edit.Success -and $edit.Reason -ne '항목을 찾지 못했습니다') { throw $edit.Reason }
    if ($edit.Success) {
        $before = ConvertFrom-WtStamp ([string](Get-WtField $edit.Item 'opened'))
        if ($before -and ($now - $before).TotalSeconds -ge 0 -and ($now - $before).TotalSeconds -lt 60) { return $Store }
        Set-WtField $edit.Item 'opened' ($now.ToOffset([timespan]::FromHours(9)).ToString("yyyy-MM-dd'T'HH:mm:sszzz", $script:memoInv))
    } else { $edit.Items += [pscustomobject]@{ id = $Id; opened = (Get-WtMemoDataStamp $now) } }
    Save-WtStore $Store $edit.Items
}

function Get-WtMemoViews {
    param($Store = (Open-WtStore -Name 'memo-views' -Schema 1))
    if ($Store.State -notin 'ok', 'missing') { throw $Store.Error }
    $seen = New-WtMemoStringSet
    foreach ($item in $Store.Items) {
        $id = Get-WtField $item 'id'
        if ($id -is [string] -and $id -and $seen.Add($id) -and -not (Test-WtDeleted $item)) { $item }
    }
}

function Save-WtMemoView {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowEmptyString()][string]$Query,
        [Parameter(Mandatory)]$Sort, [ValidateSet('active', 'archived', 'all')][string]$Scope = 'active', [string]$Id,
        $Store = (Open-WtStore -Name 'memo-views' -Schema 1))
    if (-not $Name.Trim()) { throw '보기 이름이 비었습니다.' }
    $parsed = ConvertFrom-WtMemoQuery $Query
    if (-not $parsed.Success) { throw $parsed.Error.Reason }
    if ($parsed.Scope -ne 'active' -and $parsed.Scope -ne $Scope) { throw '검색식과 저장한 보기의 범위가 다릅니다.' }
    if ($Sort.by -notin 'updated', 'created', 'title', 'opened', 'backlinks' -or $Sort.dir -notin 'asc', 'desc') { throw '보기 정렬을 확인하세요.' }
    $edit = Get-WtRecordEdit $Store $Id
    if (-not $edit.Success) { throw $edit.Reason }
    $now = Get-WtMemoDataStamp
    if (-not $Id) {
        $edit.Item = [pscustomobject]@{ id = (New-WtId); name = ''; query = ''; sort = [pscustomobject]@{}; scope = $Scope; created = $now; updated = $now; rev = 0; deleted = $null }
        $edit.Items += $edit.Item
    } else {
        if (Test-WtDeleted $edit.Item) { throw '지운 보기는 고칠 수 없습니다.' }
        Set-WtItemEdited $edit.Item $now
    }
    Set-WtField $edit.Item 'name' $Name; Set-WtField $edit.Item 'query' $Query; Set-WtField $edit.Item 'scope' $Scope
    Merge-WtRecordPatch $edit.Item @{ sort = $Sort }
    Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items)
}

function Set-WtMemoViewDeleted {
    param([Parameter(Mandatory)][string]$Id, [bool]$Deleted = $true, $Store = (Open-WtStore -Name 'memo-views' -Schema 1))
    $edit = Get-WtRecordEdit $Store $Id
    if (-not $edit.Success) { throw $edit.Reason }
    $reason = Set-WtRecordDeleted $edit.Item $Deleted (Get-WtMemoDataStamp)
    if ($reason) { throw $reason }
    Save-WtStore $Store @(Compress-WtDeletedItems $edit.Items)
}

Export-ModuleMember -Function ConvertFrom-WtMemoQuery, ConvertTo-WtMemoQuery, New-WtMemoIndex, Update-WtMemoIndex, Find-WtMemo,
    Set-WtMemoFolder, Set-WtMemoPinned, Set-WtMemoArchived, Get-WtMemoFolders, Save-WtMemoFolders, Set-WtMemoOpened,
    Get-WtMemoViews, Save-WtMemoView, Set-WtMemoViewDeleted, Open-WtMemoStore, Save-WtMemoDataItems

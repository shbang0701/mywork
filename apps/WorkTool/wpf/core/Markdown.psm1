# 마크다운 보기. 메모 · 문서 등 여러 화면이 같이 쓴다. 이 파일에는 특정 화면(메모 등)을 위한 코드를 넣지 않는다.
#
# 1) ConvertTo-WtMarkdownModel: 글 → 블록 · 인라인 목록(해시테이블). WPF 없이 동작한다 (tests/Test-Core.ps1이 검사).
#    PowerShell 7에 들어 있는 Markdig로 읽고, Markdig가 모르는 Obsidian 문법(콜아웃, [[위키 링크]], #태그, %%주석%%)은 여기서 더 읽는다.
# 2) New-WtMarkdownView + Set-WtMarkdownText: 모델 → WPF 문서(읽기 전용 RichTextBox).
#    모양은 Ui.psm1의 Md.* 스타일과 Theme.psm1의 색 · 크기 리소스만 쓴다.
#
# 화면마다 다른 것은 매개변수 · 등록으로 받는다
# - 링크 · [[위키 링크]] · #태그를 눌렀을 때: New-WtMarkdownView -OnLink { param($link) ...; $true }
#   $link = @{ Kind = 'url' | 'file' | 'wiki' | 'tag'; Target; Text }. $true를 돌려주면 처리한 것, 아니면 기본 동작(Invoke-WtMarkdownLink).
# - 상대 경로(그림 · 파일 링크)의 기준 폴더: -BaseDir (메모처럼 파일이 아닌 글은 비워 둔다)
# - 코드 블록을 언어별로 따로 그리기: Register-WtMarkdownCodeRenderer (예: Mermaid.psm1이 mermaid를 등록)
# - 콜아웃 종류 더하기: Register-WtMarkdownCallout
#
# 이벤트 처리기는 나중에 불리므로 보낸 요소($s)의 Tag와 $script: 변수만 쓴다.

$ErrorActionPreference = 'Stop'

$script:pipeline = $null
$script:codeRenderers = @{}   # 언어 이름(소문자) → @{ Label; Render; Remeasure }
$script:callouts = @{}        # 종류(소문자) → @{ Kind; Color; Icon }
$script:views = [System.Collections.Generic.List[System.WeakReference]]::new()

# 링크로 바로 여는 파일 종류. 실행 파일 · 스크립트는 열지 않고 폴더에서 보여 준다.
$script:openable = @('.md', '.txt', '.log', '.csv', '.tsv', '.json', '.xml', '.yaml', '.yml', '.ini', '.conf', '.cfg',
    '.pdf', '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.svg',
    '.xlsx', '.xls', '.xlsm', '.docx', '.doc', '.pptx', '.ppt', '.vsdx', '.vsd', '.htm', '.html', '.zip')
$script:imageExt = @('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tif', '.tiff', '.ico', '.webp')

# ---- 등록 -------------------------------------------------------------------------------------

<#
코드 블록 그리기 등록
  Language   ```뒤에 쓰는 이름 (여러 개 가능)
  Label      코드 블록 머리에 보일 이름
  Render     { param($code) ... } → 화면 요소 하나. 못 그리면 throw → 원문을 코드 블록으로 보여 준다
  Remeasure  글자 크기를 바꾸면 다시 그린다 (글자 크기를 재서 배치하는 그림)
#>
function Register-WtMarkdownCodeRenderer {
    param(
        [Parameter(Mandatory)][string[]]$Language,
        [Parameter(Mandatory)][scriptblock]$Render,
        [string]$Label = '',
        [switch]$Remeasure
    )
    foreach ($l in $Language) {
        $script:codeRenderers[$l.ToLowerInvariant()] = @{ Label = $(if ($Label) { $Label } else { $l }); Render = $Render; Remeasure = [bool]$Remeasure }
    }
}

<#
콜아웃 종류 등록. > [!종류] 제목
  Color  Theme.psm1의 Callout.<Color> · Callout.<Color>Bg (Blue · Teal · Green · Orange · Red · Purple · Gray)
  Icon   Segoe 아이콘 글꼴 글자 코드
#>
function Register-WtMarkdownCallout {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Color,
        [Parameter(Mandatory)][int]$Icon,
        [string[]]$Aliases = @()
    )
    $c = @{ Kind = $Kind; Color = $Color; Icon = $Icon }
    foreach ($k in @($Kind) + $Aliases) { $script:callouts[$k.ToLowerInvariant()] = $c }
}

# Obsidian 기본 콜아웃 (GitHub의 > [!NOTE] · [!TIP] · [!IMPORTANT] · [!WARNING] · [!CAUTION]도 여기에 들어 있다)
Register-WtMarkdownCallout -Kind 'note' -Color 'Blue' -Icon 0xE70F
Register-WtMarkdownCallout -Kind 'abstract' -Color 'Teal' -Icon 0xE8A5 -Aliases 'summary', 'tldr'
Register-WtMarkdownCallout -Kind 'info' -Color 'Blue' -Icon 0xE946
Register-WtMarkdownCallout -Kind 'todo' -Color 'Blue' -Icon 0xE73A
Register-WtMarkdownCallout -Kind 'tip' -Color 'Teal' -Icon 0xEA80 -Aliases 'hint', 'important'
Register-WtMarkdownCallout -Kind 'success' -Color 'Green' -Icon 0xE73E -Aliases 'check', 'done'
Register-WtMarkdownCallout -Kind 'question' -Color 'Orange' -Icon 0xE9CE -Aliases 'help', 'faq'
Register-WtMarkdownCallout -Kind 'warning' -Color 'Orange' -Icon 0xE7BA -Aliases 'caution', 'attention'
Register-WtMarkdownCallout -Kind 'failure' -Color 'Red' -Icon 0xE711 -Aliases 'fail', 'missing'
Register-WtMarkdownCallout -Kind 'danger' -Color 'Red' -Icon 0xEA39 -Aliases 'error'
Register-WtMarkdownCallout -Kind 'bug' -Color 'Red' -Icon 0xEBE8
Register-WtMarkdownCallout -Kind 'example' -Color 'Purple' -Icon 0xE8FD
Register-WtMarkdownCallout -Kind 'quote' -Color 'Gray' -Icon 0xE8BD -Aliases 'cite'

# ---- 글 → 모델 (WPF 없이) ---------------------------------------------------------------------

<#
모델
  블록: @{ T = 'heading' (Level, Inl, Text) | 'para' (Inl) | 'list' (Ordered, Start, Loose, Items[@{ Task; Blocks; Line }])
             | 'quote' (Blocks) | 'callout' (Kind, Color, Icon, Title[인라인], Fold '' · '+' · '-', Blocks)
             | 'code' (Lang, Text) | 'math' (Text) | 'hr' | 'html' (Text) | 'table' (Align[], Rows[@{ Header; Cells[블록[]] }])
             | 'props' (Items[@{ Key; Value }]) | 'footnotes' (Items[@{ Order; Blocks }]); Line = 원문 줄 번호(1부터) }
  인라인: @{ T = 'text' (Text) | 'soft'(줄바꿈 한 번) | 'br' | 'em' · 'strong' · 'del' · 'mark' · 'sup' · 'sub' · 'ins' · 'span' (Inl)
             | 'code' (Text) | 'math' (Text) | 'link' (Kind, Target, Url, Title, Inl) | 'image' (Url, Alt, Width)
             | 'tag' (Text) | 'fn' · 'fnback' (Order) | 'task' (Checked) }
  링크 Kind: url · file · wiki · anchor(같은 문서 안 제목 · 각주)
#>
function ConvertTo-WtMarkdownModel([AllowEmptyString()][string]$Text) {
    $src = ([string]$Text).Replace("`r`n", "`n").Replace("`r", "`n")
    $doc = [Markdig.Markdown]::Parse($src, (Get-WtMarkdownPipeline))
    $ctx = @{ Src = $src; Headings = [System.Collections.Generic.List[object]]::new() }
    $blocks = ConvertFrom-WtMdBlocks $doc $ctx
    @{ Blocks = $blocks; Headings = $ctx.Headings.ToArray() }
}

# Markdig는 PowerShell 7에 들어 있다 (ConvertFrom-Markdown이 쓰는 것). 처음 한 번 불러와서 쓸 확장만 켠다.
function Get-WtMarkdownPipeline {
    if (-not $script:pipeline) {
        if (-not ('Markdig.Markdown' -as [type])) { [void](ConvertFrom-Markdown -InputObject ' ') }
        $ext = [Markdig.MarkdownExtensions]
        $b = [Markdig.MarkdownPipelineBuilder]::new()
        $b = $ext::UseYamlFrontMatter($b)
        $b = $ext::UsePipeTables($b)
        $b = $ext::UseTaskLists($b)
        $b = $ext::UseEmphasisExtras($b, [Markdig.Extensions.EmphasisExtras.EmphasisExtraOptions]'Strikethrough, Marked')
        $b = $ext::UseAutoLinks($b)
        $b = $ext::UseFootnotes($b)
        $b = $ext::UseMathematics($b)
        $script:pipeline = $b.Build()
    }
    $script:pipeline
}

function ConvertFrom-WtMdBlocks($Container, $Ctx) {
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $Container) {
        $m = ConvertFrom-WtMdBlock $b $Ctx
        if ($m) { $out.Add($m) }
    }
    , $out.ToArray()
}

function Get-WtMdLines($Block) { ([string]$Block.Lines.ToString()).Replace("`r", '').TrimEnd("`n") }

function ConvertFrom-WtMdBlock($B, $Ctx) {
    $line = $B.Line + 1
    switch ($B.GetType().Name) {
        'HeadingBlock' {
            $inl = ConvertFrom-WtMdInlines $B.Inline $Ctx
            $text = Get-WtMdInlineText $inl
            $Ctx.Headings.Add(@{ Level = $B.Level; Text = $text; Line = $line })
            return @{ T = 'heading'; Level = $B.Level; Inl = $inl; Text = $text; Line = $line }
        }
        'ParagraphBlock' { return @{ T = 'para'; Inl = (ConvertFrom-WtMdInlines $B.Inline $Ctx); Line = $line } }
        'ListBlock' { return ConvertFrom-WtMdList $B $Ctx }
        'QuoteBlock' { return ConvertFrom-WtMdQuote $B $Ctx }
        'MathBlock' { return @{ T = 'math'; Text = (Get-WtMdLines $B); Line = $line } }
        'FencedCodeBlock' { return @{ T = 'code'; Lang = ([string]$B.Info).Trim(); Text = (Get-WtMdLines $B); Line = $line } }
        'CodeBlock' { return @{ T = 'code'; Lang = ''; Text = (Get-WtMdLines $B); Line = $line } }
        'ThematicBreakBlock' { return @{ T = 'hr'; Line = $line } }
        'HtmlBlock' {
            $raw = Get-WtMdLines $B
            if ($raw.TrimStart().StartsWith('<!--')) { return $null }
            # HTML은 그리지 않는다. <br>은 줄바꿈으로, 나머지 태그는 빼고 글자만 보인다
            $text = [System.Net.WebUtility]::HtmlDecode(($raw -replace '<br\s*/?>', "`n" -replace '<[^>]+>', '')).Trim()
            if (-not $text) { return $null }
            return @{ T = 'html'; Text = $text; Line = $line }
        }
        'Table' { return ConvertFrom-WtMdTable $B $Ctx }
        'YamlFrontMatterBlock' { return ConvertFrom-WtMdFrontMatter (Get-WtMdLines $B) }
        'FootnoteGroup' {
            $items = foreach ($fn in $B) { @{ Order = $fn.Order; Blocks = (ConvertFrom-WtMdBlocks $fn $Ctx) } }
            return @{ T = 'footnotes'; Items = @($items); Line = $line }
        }
    }
    $null   # 링크 정의 등 보이지 않는 블록
}

function ConvertFrom-WtMdList($B, $Ctx) {
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($li in $B) {
        $blocks = ConvertFrom-WtMdBlocks $li $Ctx
        $task = $null
        if ($blocks.Count -and $blocks[0].T -eq 'para' -and $blocks[0].Inl.Count -and $blocks[0].Inl[0].T -eq 'task') {
            $task = [bool]$blocks[0].Inl[0].Checked
            $rest = @($blocks[0].Inl | Select-Object -Skip 1)
            if ($rest.Count -and $rest[0].T -eq 'text') { $rest[0].Text = $rest[0].Text.TrimStart() }
            $blocks[0].Inl = $rest
        }
        $items.Add(@{ Task = $task; Blocks = $blocks; Line = $li.Line + 1 })
    }
    $start = 1
    if ($B.IsOrdered) { [void][int]::TryParse([string]$B.OrderedStart, [ref]$start) }
    @{ T = 'list'; Ordered = [bool]$B.IsOrdered; Start = $start; Loose = [bool]$B.IsLoose; Items = $items.ToArray(); Line = $B.Line + 1 }
}

# 인용 블록. 첫 줄이 [!종류]이면 콜아웃 (Obsidian · GitHub)
function ConvertFrom-WtMdQuote($B, $Ctx) {
    $blocks = ConvertFrom-WtMdBlocks $B $Ctx
    $first = $null
    foreach ($c in $B) { $first = $c; break }
    if (-not $first -or $first.GetType().Name -ne 'ParagraphBlock' -or -not $blocks.Count) {
        return @{ T = 'quote'; Blocks = $blocks; Line = $B.Line + 1 }
    }
    $start = $first.Span.Start
    $end = $Ctx.Src.IndexOf("`n", $start)
    $head = if ($end -lt 0) { $Ctx.Src.Substring($start) } else { $Ctx.Src.Substring($start, $end - $start) }
    $m = [regex]::Match($head, '^\[!([A-Za-z][\w-]*)\]([+-]?)')
    if (-not $m.Success) { return @{ T = 'quote'; Blocks = $blocks; Line = $B.Line + 1 } }

    # 첫 문단을 첫 줄(제목)과 나머지(본문)로 나눈다
    $title = [System.Collections.Generic.List[object]]::new()
    $body = [System.Collections.Generic.List[object]]::new()
    $inBody = $false
    foreach ($x in $blocks[0].Inl) {
        if (-not $inBody -and $x.T -in 'soft', 'br') { $inBody = $true; continue }
        if ($inBody) { $body.Add($x) } else { $title.Add($x) }
    }
    if ($title.Count -and $title[0].T -eq 'text') { $title[0].Text = $title[0].Text -replace '^\s*\[![^\]]*\][+-]?\s*', '' }
    if ($title.Count -and $title[$title.Count - 1].T -eq 'text') { $title[$title.Count - 1].Text = $title[$title.Count - 1].Text.TrimEnd() }
    $title = @($title | Where-Object { -not ($_.T -eq 'text' -and -not $_.Text) })

    $raw = $m.Groups[1].Value.ToLowerInvariant()
    $info = $script:callouts[$raw]
    if (-not $info) { $info = $script:callouts['note'] }
    if (-not $title.Count) {
        $name = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($raw)
        $title = @(@{ T = 'text'; Text = $name })
    }
    $rest = [System.Collections.Generic.List[object]]::new()
    if ($body.Count) { $rest.Add(@{ T = 'para'; Inl = $body.ToArray(); Line = $blocks[0].Line + 1 }) }
    for ($i = 1; $i -lt $blocks.Count; $i++) { $rest.Add($blocks[$i]) }
    @{
        T = 'callout'; Kind = $info.Kind; Raw = $raw; Color = $info.Color; Icon = $info.Icon
        Title = $title; Fold = $m.Groups[2].Value; Blocks = $rest.ToArray(); Line = $B.Line + 1
    }
}

function ConvertFrom-WtMdTable($B, $Ctx) {
    $align = @(foreach ($cd in $B.ColumnDefinitions) {
            switch ([string]$cd.Alignment) { 'Left' { 'left' } 'Center' { 'center' } 'Right' { 'right' } default { '' } }
        })
    $rows = [System.Collections.Generic.List[object]]::new()
    $n = 0
    foreach ($row in $B) {
        $cells = [System.Collections.Generic.List[object]]::new()
        foreach ($cell in $row) { $cells.Add((ConvertFrom-WtMdBlocks $cell $Ctx)) }
        $rows.Add(@{ Header = [bool]$row.IsHeader; Cells = $cells.ToArray() })
        $n = [Math]::Max($n, $cells.Count)
    }
    # Markdig는 끝의 | 뒤에 빈 열 정의를 하나 더 둔다
    if ($align.Count -gt $n) { $align = @($align | Select-Object -First $n) }
    @{ T = 'table'; Align = $align; Rows = $rows.ToArray(); Line = $B.Line + 1 }
}

# 맨 앞 --- 사이의 속성(YAML). 'key: 값', 'key: [a, b]', 그리고 아래에 '- 값'을 늘어놓은 목록만 읽는다.
function ConvertFrom-WtMdFrontMatter([string]$Raw) {
    $items = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($l in ($Raw -split "`n")) {
        if ($l -match '^\s*(---|\.\.\.)\s*$' -or -not $l.Trim() -or $l.TrimStart().StartsWith('#')) { continue }
        if ($l -match '^([^\s:#-][^:]*):\s*(.*)$') {
            $key = $Matches[1].Trim()
            $v = $Matches[2].Trim()
            if ($v -match '^\[(.*)\]$') { $v = (($Matches[1] -split ',') | ForEach-Object { $_.Trim().Trim('"', "'") }) -join ', ' }
            $cur = @{ Key = $key; Value = $v.Trim('"', "'") }
            $items.Add($cur)
        } elseif ($cur -and $l -match '^\s+-\s*(.*)$') {
            $v = $Matches[1].Trim().Trim('"', "'")
            $cur.Value = if ($cur.Value) { "$($cur.Value), $v" } else { $v }
        }
    }
    if (-not $items.Count) { return $null }
    @{ T = 'props'; Items = $items.ToArray(); Line = 1 }
}

# 이어진 글자 조각을 모았다가 Obsidian 문법을 읽는다. 줄바꿈 한 번(soft)도 글자 안에 넣어서 %%여러 줄 주석%%도 읽는다.
$script:obsidianRe = [regex]::new(
    '%%[\s\S]*?%%|(?<embed>!)?\[\[(?<target>[^\[\]|\n]+?)(?:\|(?<alias>[^\[\]\n]*))?\]\]|(?<=^|[\s(\[])#(?<tag>[\p{L}\p{N}_/-]*[\p{L}_/-][\p{L}\p{N}_/-]*)',
    'Multiline')

function ConvertFrom-WtMdInlines($Container, $Ctx) {
    $out = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Container) { return , $out.ToArray() }
    $buf = [System.Text.StringBuilder]::new()
    foreach ($i in $Container) {
        $name = $i.GetType().Name
        if ($name -eq 'LiteralInline') { [void]$buf.Append($i.Content.ToString()); continue }
        if ($name -eq 'HtmlEntityInline') { [void]$buf.Append($i.Transcoded.ToString()); continue }
        if ($name -eq 'LineBreakInline' -and -not $i.IsHard) { [void]$buf.Append("`n"); continue }
        if ($name -eq 'HtmlInline') {
            # <br>만 줄바꿈으로 쓰고, 다른 태그는 빼고 안의 글자만 보인다
            if ([string]$i.Tag -match '^<br\s*/?>$') {
                Add-WtMdText $out $buf
                $out.Add(@{ T = 'br' })
            }
            continue
        }
        Add-WtMdText $out $buf
        $m = ConvertFrom-WtMdInline $i $Ctx
        if ($m) { $out.Add($m) }
    }
    Add-WtMdText $out $buf
    , $out.ToArray()
}

function ConvertFrom-WtMdInline($I, $Ctx) {
    switch ($I.GetType().Name) {
        'EmphasisInline' {
            $kind = switch ("$($I.DelimiterChar)$($I.DelimiterCount)") {
                { $_ -in '*1', '_1' } { 'em' }
                { $_ -in '*2', '_2' } { 'strong' }
                '~2' { 'del' }
                '~1' { 'sub' }
                '=2' { 'mark' }
                '^1' { 'sup' }
                '+2' { 'ins' }
                default { 'span' }
            }
            return @{ T = $kind; Inl = (ConvertFrom-WtMdInlines $I $Ctx) }
        }
        'CodeInline' { return @{ T = 'code'; Text = [string]$I.Content } }
        'LinkInline' {
            $inl = ConvertFrom-WtMdInlines $I $Ctx
            if ($I.IsImage) { return New-WtMdImageModel ([string]$I.Url) (Get-WtMdInlineText $inl) }
            return New-WtMdLinkModel ([string]$I.Url) $inl ([string]$I.Title)
        }
        'AutolinkInline' {
            $url = if ($I.IsEmail) { "mailto:$($I.Url)" } else { [string]$I.Url }
            return New-WtMdLinkModel $url @(@{ T = 'text'; Text = [string]$I.Url })
        }
        'LineBreakInline' { return @{ T = 'br' } }
        'FootnoteLink' { return @{ T = $(if ($I.IsBackLink) { 'fnback' } else { 'fn' }); Order = $I.Footnote.Order } }
        'MathInline' { return @{ T = 'math'; Text = $I.Content.ToString() } }
        'TaskList' { return @{ T = 'task'; Checked = [bool]$I.Checked } }
    }
    if ($I -is [Markdig.Syntax.Inlines.ContainerInline]) { return @{ T = 'span'; Inl = (ConvertFrom-WtMdInlines $I $Ctx) } }
    @{ T = 'text'; Text = $I.ToString() }
}

# 모은 글자를 Obsidian 문법(위키 링크 · 태그 · 주석)과 줄바꿈으로 나눠 넣는다
function Add-WtMdText($Out, [System.Text.StringBuilder]$Buf) {
    if (-not $Buf.Length) { return }
    $text = $Buf.ToString()
    [void]$Buf.Clear()
    $pos = 0
    foreach ($m in $script:obsidianRe.Matches($text)) {
        if ($m.Index -gt $pos) { Add-WtMdPlain $Out $text.Substring($pos, $m.Index - $pos) }
        $pos = $m.Index + $m.Length
        if ($m.Groups['tag'].Success) {
            $Out.Add(@{ T = 'tag'; Text = $m.Groups['tag'].Value })
        } elseif ($m.Groups['target'].Success) {
            $target = $m.Groups['target'].Value.Trim()
            $alias = if ($m.Groups['alias'].Success) { $m.Groups['alias'].Value.Trim() } else { '' }
            $isImage = $script:imageExt -contains [System.IO.Path]::GetExtension($target).ToLowerInvariant()
            if ($m.Groups['embed'].Success -and $isImage) {
                $Out.Add((New-WtMdImageModel $target $(if ($alias) { "$target|$alias" } else { $target })))
                continue
            }
            $show = if ($alias) { $alias } elseif ($target.StartsWith('#')) { $target.Substring(1) } else { $target -replace '#', ' › ' }
            $kind = if ($target.StartsWith('#')) { 'anchor' } else { 'wiki' }
            $Out.Add(@{ T = 'link'; Kind = $kind; Target = $target.TrimStart('#'); Url = $target; Title = ''; Inl = @(@{ T = 'text'; Text = $show }) })
        }
        # %%주석%%은 보이지 않는다
    }
    if ($pos -lt $text.Length) { Add-WtMdPlain $Out $text.Substring($pos) }
}

function Add-WtMdPlain($Out, [string]$Text) {
    $parts = $Text -split "`n"
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($i -gt 0) { $Out.Add(@{ T = 'soft' }) }
        if ($parts[$i]) { $Out.Add(@{ T = 'text'; Text = $parts[$i] }) }
    }
}

function Get-WtMdLinkKind([string]$Url) {
    if ($Url.StartsWith('#')) { return 'anchor' }
    if ($Url -match '^[A-Za-z]:[\\/]|^\\\\|^file:') { return 'file' }
    if ($Url -match '^[A-Za-z][A-Za-z0-9+.-]+:') { return 'url' }
    if ($Url -match '^www\.') { return 'url' }
    'file'
}

function New-WtMdLinkModel([string]$Url, $Inl, [string]$Title = '') {
    $kind = Get-WtMdLinkKind $Url
    $target = switch ($kind) {
        'anchor' { [uri]::UnescapeDataString($Url.Substring(1)) }
        'file' { [uri]::UnescapeDataString($Url) }
        default { if ($Url -match '^www\.') { "https://$Url" } else { $Url } }
    }
    if (-not @($Inl).Count) { $Inl = @(@{ T = 'text'; Text = $Url }) }
    @{ T = 'link'; Kind = $kind; Target = $target; Url = $Url; Title = $Title; Inl = @($Inl) }
}

# 그림. Obsidian처럼 대체 글 끝의 |300 또는 |300x200은 너비로 쓴다
function New-WtMdImageModel([string]$Url, [string]$Alt) {
    $width = 0
    if ($Alt -match '^(.*?)\|(\d+)(?:x\d+)?$') { $Alt = $Matches[1]; $width = [int]$Matches[2] }
    @{ T = 'image'; Url = $Url; Alt = $Alt; Width = $width }
}

# 인라인 목록의 글자만 (제목 이름표 · 대체 글 · 표 열 너비 계산용)
function Get-WtMdInlineText($Inl) {
    $sb = [System.Text.StringBuilder]::new()
    foreach ($x in @($Inl)) {
        if ($null -eq $x) { continue }
        switch ($x.T) {
            { $_ -in 'text', 'code', 'math' } { [void]$sb.Append($x.Text) }
            'tag' { [void]$sb.Append('#' + $x.Text) }
            { $_ -in 'soft', 'br' } { [void]$sb.Append(' ') }
            'image' { [void]$sb.Append($x.Alt) }
            default { if ($x.Inl) { [void]$sb.Append((Get-WtMdInlineText $x.Inl)) } }
        }
    }
    $sb.ToString()
}

function Get-WtMdBlocksText($Blocks) {
    (@($Blocks) | ForEach-Object { if ($_.Inl) { Get-WtMdInlineText $_.Inl } elseif ($_.Text) { $_.Text } }) -join ' '
}

# 제목 · 각주를 찾는 열쇠. 대소문자 · 띄어쓰기 · 기호를 무시한다 ([[#제목 이름]], (#제목-이름) 모두 같은 곳)
function Get-WtMdAnchorKey([string]$Text) { ($Text.ToLowerInvariant() -replace '[^\p{L}\p{N}]', '') }

<#
목록 한 줄 요약용: 마크다운 기호를 떼고 줄을 ' · '로 잇는다. 전체를 읽지 않고 줄 단위로 빠르게 처리한다.
#>
function Get-WtMarkdownSnippet([AllowEmptyString()][string]$Text, [int]$MaxLength = 300) {
    if (-not $Text) { return '' }
    $t = $Text.Replace("`r", '')
    $t = $t -replace '\A---\n[\s\S]*?\n---(\n|\z)', ''
    $t = $t -replace '%%[\s\S]*?%%', ''
    $length = 0
    $lines = foreach ($line in ($t -split "`n")) {
        $l = $line.Trim()
        if (-not $l) { continue }
        if ($l -match '^(```|~~~)') { continue }
        if ($l -match '^\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?$' -and $l.Contains('-')) { continue }   # 표 구분 줄 · 가로줄
        if ($l -match '^([*_]\s*){3,}$') { continue }
        $l = $l -replace '^(>\s*)+', ''
        $l = $l -replace '^\[![\w-]+\][+-]?\s*', ''
        $l = $l -replace '^#{1,6}\s+', ''
        $l = $l -replace '^\[\^[^\]]+\]:\s*', ''
        $l = $l -replace '^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?', ''
        $l = $l -replace '!\[\[[^\]]*\]\]', '' -replace '\[\[([^\]|]+)\|([^\]]+)\]\]', '$2' -replace '\[\[#?([^\]]+)\]\]', '$1'
        $l = $l -replace '!\[([^\]]*)\]\([^)]*\)', '' -replace '\[([^\]]*)\]\([^)]*\)', '$1' -replace '\[\^[^\]]+\]', ''
        $l = $l -replace '(\*\*|__|~~|==)(.+?)\1', '$2' -replace '(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', '$1' -replace '`([^`]*)`', '$1'
        $l = [System.Net.WebUtility]::HtmlDecode(($l -replace '<[^>]+>', ' '))
        if ($l.StartsWith('|')) { $l = $l.Trim('|') -replace '\s*\|\s*', '  ' }
        $l = ($l -replace '\s{3,}', '  ').Trim()
        if ($l) {
            $l
            $length += $l.Length + 3   # 줄 사이의 ' · '까지 센다
            if ($MaxLength -ge 0 -and $length - 3 -ge $MaxLength) { break }
        }
    }
    $s = @($lines) -join ' · '
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength) }
    $s
}

# ---- 모델 → WPF ------------------------------------------------------------------------------

<#
마크다운 보기 요소(읽기 전용 RichTextBox)를 만든다. 글은 Set-WtMarkdownText로 넣는다.
  -Scroll            스스로 스크롤한다 (남는 높이를 채우는 자리). 없으면 글 높이만큼 커진다 (바깥이 스크롤하는 자리)
  -OnLink            { param($link) ... $true } 링크 · 위키 링크 · 태그를 눌렀을 때. 이게 있으면 #태그도 누를 수 있게 그린다
  -BaseDir           상대 경로의 기준 폴더
  -StrictLineBreaks  줄바꿈 한 번은 이어 붙인다 (표준 마크다운). 없으면 Obsidian 기본값처럼 줄을 바꾼다
#>
function New-WtMarkdownView {
    param([switch]$Scroll, [scriptblock]$OnLink, [string]$BaseDir = '', [switch]$StrictLineBreaks)
    $v = [System.Windows.Controls.RichTextBox]::new()
    Set-WtMdStyle $v 'Md.View'
    $v.IsReadOnly = $true
    $v.IsDocumentEnabled = $true
    $v.VerticalScrollBarVisibility = if ($Scroll) { 'Auto' } else { 'Disabled' }
    $v.Tag = @{
        Text = ''; BaseDir = $BaseDir; OnLink = $OnLink; Strict = [bool]$StrictLineBreaks
        Anchors = @{}; Remeasure = $false; Error = $null; ListDepth = 0
    }
    for ($i = $script:views.Count - 1; $i -ge 0; $i--) { if (-not $script:views[$i].IsAlive) { $script:views.RemoveAt($i) } }
    $script:views.Add([System.WeakReference]::new($v))
    $v
}

function Set-WtMarkdownText {
    param([Parameter(Mandatory)]$View, [AllowEmptyString()][string]$Text, [string]$BaseDir)
    $st = $View.Tag
    $st.Text = [string]$Text
    if ($PSBoundParameters.ContainsKey('BaseDir')) { $st.BaseDir = $BaseDir }
    $st.Anchors = @{}
    $st.Remeasure = $false
    $st.Error = $null
    $st.ListDepth = 0
    $doc = [System.Windows.Documents.FlowDocument]::new()
    Set-WtMdStyle $doc 'Md.Doc'
    try {
        $model = ConvertTo-WtMarkdownModel $st.Text
        foreach ($b in $model.Blocks) { Add-WtMdBlock $doc.Blocks $b $st }
        Set-WtMdEdgeMargins $doc.Blocks
    } catch {
        # 그리지 못하면 원문을 그대로 보여 준다. 오류 문구는 복사해서 알려 줄 수 있게 글로 둔다
        $st.Error = $_
        $doc.Blocks.Clear()
        $p = New-WtMdPara 'Md.P'
        $warn = New-WtMdRun "마크다운을 그리지 못해 원문을 보여 줍니다. $($_.Exception.Message)"
        Set-WtResource $warn 'Foreground' 'B.Danger'
        $p.Inlines.Add($warn)
        $doc.Blocks.Add($p)
        $raw = New-WtMdPara 'Md.CodeText'
        $raw.Inlines.Add((New-WtMdRun $st.Text))
        $doc.Blocks.Add($raw)
    }
    $View.Document = $doc
}

# 모델의 제목 목록 (목차 등). @{ Level; Text; Line }
function Get-WtMarkdownHeadings([AllowEmptyString()][string]$Text) { (ConvertTo-WtMarkdownModel $Text).Headings }

# 문서 요소에는 스타일을 바로 넣는다. 리소스 참조로 걸면 문서에 붙기 전에는 스타일이 풀리지 않아서
# 여백을 읽고 고치는 Set-WtMdEdgeMargins가 자동 여백(한 줄 높이)을 읽어 버린다.
function Set-WtMdStyle($Element, [string]$Key) {
    $style = (Get-WtStyleDictionary)[$Key]
    if (-not $style) { throw "Ui.psm1에 스타일 '$Key'가 없습니다." }
    $Element.Style = $style
}

function New-WtMdRun([string]$Text) { [System.Windows.Documents.Run]::new($Text) }

function New-WtMdPara([string]$Style) {
    $p = [System.Windows.Documents.Paragraph]::new()
    Set-WtMdStyle $p $Style
    $p
}

function New-WtMdIconRun([int]$Code) {
    $r = New-WtMdRun ([string][char]$Code)
    Set-WtResource $r 'FontFamily' 'Font.Icon'
    $r
}

# 상자(인용 · 콜아웃 · 목록 항목) 안 맨 위 · 맨 아래 블록의 바깥 여백을 없앤다
function Set-WtMdEdgeMargins($Blocks) {
    $first = $Blocks.FirstBlock
    $last = $Blocks.LastBlock
    if ($first) { $m = $first.Margin; $first.Margin = [System.Windows.Thickness]::new($m.Left, 0, $m.Right, $m.Bottom) }
    if ($last) { $m = $last.Margin; $last.Margin = [System.Windows.Thickness]::new($m.Left, $m.Top, $m.Right, 0) }
}

function Add-WtMdBlock($Blocks, $B, $St, [bool]$Tight = $false) {
    switch ($B.T) {
        'heading' {
            $p = New-WtMdPara "Md.H$([Math]::Min([int]$B.Level, 6))"
            Add-WtMdInlines $p.Inlines $B.Inl $St
            $key = Get-WtMdAnchorKey $B.Text
            if ($key -and -not $St.Anchors.ContainsKey($key)) { $St.Anchors[$key] = $p }
            $Blocks.Add($p)
        }
        'para' {
            $style = if ($Tight) { 'Md.PTight' } else { 'Md.P' }
            # 그림 하나만 있는 문단은 폭에 맞춘 블록 그림으로
            if (@($B.Inl).Count -eq 1 -and $B.Inl[0].T -eq 'image') {
                $img = New-WtMdImage $B.Inl[0] $St
                if ($img) {
                    $c = [System.Windows.Documents.BlockUIContainer]::new($img)
                    Set-WtMdStyle $c $(if ($Tight) { 'Md.FigureTight' } else { 'Md.Figure' })
                    $Blocks.Add($c)
                    return
                }
            }
            $p = New-WtMdPara $style
            Add-WtMdInlines $p.Inlines $B.Inl $St
            $Blocks.Add($p)
        }
        'html' {
            $p = New-WtMdPara $(if ($Tight) { 'Md.PTight' } else { 'Md.P' })
            Add-WtMdInlines $p.Inlines @(Get-WtMdPlainInlines $B.Text) $St
            $Blocks.Add($p)
        }
        'list' { $Blocks.Add((New-WtMdList $B $St $Tight)) }
        'quote' {
            $s = [System.Windows.Documents.Section]::new()
            Set-WtMdStyle $s 'Md.Quote'
            foreach ($c in $B.Blocks) { Add-WtMdBlock $s.Blocks $c $St }
            Set-WtMdEdgeMargins $s.Blocks
            $Blocks.Add($s)
        }
        'callout' { $Blocks.Add((New-WtMdCallout $B $St)) }
        'code' { $Blocks.Add((New-WtMdCode $B $St)) }
        'math' {
            $p = New-WtMdPara 'Md.Math'
            $p.Inlines.Add((New-WtMdRun $B.Text))
            $Blocks.Add($p)
        }
        'hr' {
            $line = [System.Windows.Controls.Border]::new()
            Set-WtMdStyle $line 'Divider'
            $c = [System.Windows.Documents.BlockUIContainer]::new($line)
            Set-WtMdStyle $c 'Md.Hr'
            $Blocks.Add($c)
        }
        'table' { $Blocks.Add((New-WtMdTable $B $St)) }
        'props' { $Blocks.Add((New-WtMdProps $B $St)) }
        'footnotes' {
            $s = [System.Windows.Documents.Section]::new()
            Set-WtMdStyle $s 'Md.Footnotes'
            foreach ($it in $B.Items) {
                $before = $s.Blocks.Count
                foreach ($c in $it.Blocks) { Add-WtMdBlock $s.Blocks $c $St $true }
                $p = $s.Blocks | Select-Object -Skip $before -First 1
                if ($p -is [System.Windows.Documents.Paragraph]) {
                    $n = New-WtMdRun "$($it.Order). "
                    if ($p.Inlines.FirstInline) { $p.Inlines.InsertBefore($p.Inlines.FirstInline, $n) } else { $p.Inlines.Add($n) }
                    $St.Anchors[(Get-WtMdAnchorKey "fn:$($it.Order)")] = $p
                }
            }
            $Blocks.Add($s)
        }
    }
}

function Get-WtMdPlainInlines([string]$Text) {
    $out = [System.Collections.Generic.List[object]]::new()
    Add-WtMdPlain $out $Text
    $out.ToArray()
}

function Add-WtMdInlines($Inlines, $Items, $St) {
    foreach ($x in @($Items)) {
        if ($null -eq $x) { continue }
        $el = New-WtMdInline $x $St
        foreach ($e in @($el)) { if ($e) { $Inlines.Add($e) } }
    }
}

function New-WtMdSpan($Items, $St) {
    $s = [System.Windows.Documents.Span]::new()
    Add-WtMdInlines $s.Inlines $Items $St
    $s
}

function New-WtMdInline($X, $St) {
    switch ($X.T) {
        'text' { return New-WtMdRun $X.Text }
        'soft' { if ($St.Strict) { return New-WtMdRun ' ' } else { return [System.Windows.Documents.LineBreak]::new() } }
        'br' { return [System.Windows.Documents.LineBreak]::new() }
        'em' { $s = New-WtMdSpan $X.Inl $St; $s.FontStyle = 'Italic'; return $s }
        'strong' { $s = New-WtMdSpan $X.Inl $St; $s.FontWeight = 'Bold'; return $s }
        'del' { $s = New-WtMdSpan $X.Inl $St; $s.TextDecorations = [System.Windows.TextDecorations]::Strikethrough; return $s }
        'ins' { $s = New-WtMdSpan $X.Inl $St; $s.TextDecorations = [System.Windows.TextDecorations]::Underline; return $s }
        'mark' { $s = New-WtMdSpan $X.Inl $St; Set-WtMdStyle $s 'Md.Mark'; return $s }
        'sup' { $s = New-WtMdSpan $X.Inl $St; Set-WtMdStyle $s 'Md.Sup'; return $s }
        'sub' { $s = New-WtMdSpan $X.Inl $St; Set-WtMdStyle $s 'Md.Sub'; return $s }
        'span' { return New-WtMdSpan $X.Inl $St }
        'code' { $r = New-WtMdRun $X.Text; Set-WtMdStyle $r 'Md.InlineCode'; return $r }
        'math' { $r = New-WtMdRun $X.Text; Set-WtMdStyle $r 'Md.InlineCode'; return $r }
        'task' { return New-WtMdTaskBox $X.Checked }
        'link' {
            if ($X.Kind -eq 'anchor' -and $X.Target -match '^\^') { return New-WtMdSpan $X.Inl $St }   # 블록 참조는 아직 없음
            $h = New-WtMdHyperlink @{ Kind = $X.Kind; Target = $X.Target; Text = (Get-WtMdInlineText $X.Inl) } $St
            Add-WtMdInlines $h.Inlines $X.Inl $St
            $tip = if ($X.Title) { "$($X.Title)`n$($X.Target)" } else { $X.Target }
            if ($X.Kind -eq 'wiki') { $tip = "문서: $($X.Target)" }
            $h.ToolTip = $tip
            return $h
        }
        'tag' {
            if ($St.OnLink) {
                $h = New-WtMdHyperlink @{ Kind = 'tag'; Target = $X.Text; Text = "#$($X.Text)" } $St
                Set-WtMdStyle $h 'Md.TagLink'
                $h.Inlines.Add((New-WtMdRun "#$($X.Text)"))
                $h.ToolTip = "#$($X.Text) 찾기"
                return $h
            }
            $s = [System.Windows.Documents.Span]::new()
            Set-WtMdStyle $s 'Md.Tag'
            $s.Inlines.Add((New-WtMdRun "#$($X.Text)"))
            return $s
        }
        'image' {
            $img = New-WtMdImage $X $St -Inline
            if ($img) { return [System.Windows.Documents.InlineUIContainer]::new($img) }
            # 불러올 수 없는 그림(웹 주소 · 없는 파일 · SVG)은 이름과 링크로 보여 준다
            $label = if ($X.Alt) { $X.Alt } else { $X.Url }
            $kind = Get-WtMdLinkKind $X.Url
            $h = New-WtMdHyperlink @{ Kind = $(if ($kind -eq 'anchor') { 'wiki' } else { $kind }); Target = $X.Url; Text = $label } $St
            $icon = New-WtMdIconRun 0xE91B
            $h.Inlines.Add($icon)
            $h.Inlines.Add((New-WtMdRun " $label"))
            $h.ToolTip = "그림: $($X.Url)"
            return $h
        }
        'fn' {
            $h = New-WtMdHyperlink @{ Kind = 'anchor'; Target = "fn:$($X.Order)"; Text = "$($X.Order)" } $St
            Set-WtMdStyle $h 'Md.FnRef'
            $h.Inlines.Add((New-WtMdRun "[$($X.Order)]"))
            $key = Get-WtMdAnchorKey "fnref:$($X.Order)"
            if (-not $St.Anchors.ContainsKey($key)) { $St.Anchors[$key] = $h }
            return $h
        }
        'fnback' {
            $h = New-WtMdHyperlink @{ Kind = 'anchor'; Target = "fnref:$($X.Order)"; Text = '↩' } $St
            $h.Inlines.Add((New-WtMdRun ' ↩'))
            $h.ToolTip = '본문으로'
            return $h
        }
    }
    $null
}

function New-WtMdTaskBox([bool]$Checked) {
    $r = New-WtMdIconRun $(if ($Checked) { 0xE73A } else { 0xE739 })
    Set-WtResource $r 'Foreground' $(if ($Checked) { 'B.Accent' } else { 'B.SubText' })
    $r
}

function New-WtMdHyperlink($Link, $St) {
    $h = [System.Windows.Documents.Hyperlink]::new()
    Set-WtMdStyle $h 'Md.Link'
    $h.Tag = @{ Link = $Link; State = $St }
    $h.Add_Click({
            param($s, $e)
            try { Invoke-WtMarkdownLink $s.Tag.State $s.Tag.Link } catch { Show-WtError $_ '링크 열기' }
        })
    $h
}

<#
링크를 눌렀을 때. 같은 문서 안(제목 · 각주)은 그 자리로 스크롤한다.
그 밖에는 -OnLink를 먼저 부르고, 처리하지 않았으면 기본 동작:
  url  http · https · mailto만 기본 브라우저 · 메일 프로그램으로 연다
  file 폴더는 탐색기로, 문서 · 그림은 기본 프로그램으로 연다. 실행 파일 · 스크립트는 열지 않고 탐색기에서 그 파일을 보여 준다
  wiki 연결할 곳을 모른다고 알린다 (메모 · 문서 화면이 -OnLink로 처리한다)
#>
function Invoke-WtMarkdownLink($St, $Link) {
    if ($Link.Kind -eq 'anchor') {
        $el = $St.Anchors[(Get-WtMdAnchorKey $Link.Target)]
        if ($el) { $el.BringIntoView() }
        return
    }
    if ($St.OnLink) {
        $handled = & $St.OnLink $Link | Select-Object -Last 1
        if ($handled -eq $true) { return }
    }
    switch ($Link.Kind) {
        'url' {
            if ($Link.Target -match '^(?i)(https?|mailto):') { Start-Process $Link.Target }
            else { Show-WtMessage "이 주소는 열지 않습니다.`n$($Link.Target)" }
        }
        'file' {
            $path = Resolve-WtMdPath $Link.Target $St.BaseDir
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { Show-WtMessage "파일을 찾지 못했습니다.`n$($Link.Target)"; return }
            if (Test-Path -LiteralPath $path -PathType Container) { Invoke-Item -LiteralPath $path; return }
            if ($script:openable -contains [System.IO.Path]::GetExtension($path).ToLowerInvariant()) { Invoke-Item -LiteralPath $path; return }
            Start-Process explorer.exe -ArgumentList "/select,`"$path`""
        }
        'wiki' { Show-WtMessage "연결된 문서를 찾지 못했습니다: $($Link.Target)" }
    }
}

# 링크 · 그림 경로 → 전체 경로. 상대 경로인데 기준 폴더가 없으면 $null
function Resolve-WtMdPath([string]$Target, [string]$BaseDir) {
    $t = $Target
    if ($t -match '^file:') {
        try { $t = ([uri]$t).LocalPath } catch { return $null }
    }
    $t = $t -replace '#.*$', ''
    if (-not $t) { return $null }
    try {
        if ([System.IO.Path]::IsPathRooted($t)) { return [System.IO.Path]::GetFullPath($t) }
        if ($BaseDir) { return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $t)) }
    } catch { }
    $null
}

# 로컬 그림 파일이면 Image 요소, 아니면 $null (웹 주소의 그림은 내려받지 않는다)
function New-WtMdImage($X, $St, [switch]$Inline) {
    if ((Get-WtMdLinkKind $X.Url) -ne 'file') { return $null }
    $path = Resolve-WtMdPath ([uri]::UnescapeDataString($X.Url)) $St.BaseDir
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    if ($script:imageExt -notcontains [System.IO.Path]::GetExtension($path).ToLowerInvariant()) { return $null }
    try {
        $bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
        $bmp.BeginInit()
        $bmp.CacheOption = 'OnLoad'   # 파일을 잡고 있지 않게 바로 읽는다
        $bmp.UriSource = [uri]$path
        $bmp.EndInit()
        $bmp.Freeze()
    } catch { return $null }
    $img = [System.Windows.Controls.Image]::new()
    $img.Source = $bmp
    $img.Stretch = 'Uniform'
    $img.StretchDirection = 'DownOnly'
    $img.HorizontalAlignment = 'Left'
    $img.MaxWidth = if ($X.Width) { $X.Width } else { $bmp.PixelWidth }
    if ($Inline -and -not $X.Width) { $img.MaxHeight = 240 }
    if ($X.Alt) { $img.ToolTip = $X.Alt }
    $img
}

function New-WtMdList($B, $St, [bool]$Nested) {
    $list = [System.Windows.Documents.List]::new()
    Set-WtMdStyle $list $(if ($Nested) { 'Md.ListNested' } else { 'Md.List' })
    $hasTask = @($B.Items | Where-Object { $null -ne $_.Task }).Count -gt 0
    if ($B.Ordered) {
        $list.MarkerStyle = 'Decimal'
        $list.StartIndex = [Math]::Max(1, $B.Start)
    } elseif ($hasTask) {
        $list.MarkerStyle = 'None'
    } else {
        $list.MarkerStyle = @('Disc', 'Circle', 'Square')[$St.ListDepth % 3]
    }
    $St.ListDepth++
    try {
        foreach ($it in $B.Items) {
            $li = [System.Windows.Documents.ListItem]::new()
            Set-WtMdStyle $li 'Md.ListItem'
            foreach ($c in $it.Blocks) { Add-WtMdBlock $li.Blocks $c $St (-not $B.Loose) }
            if (-not $li.Blocks.Count) { $li.Blocks.Add((New-WtMdPara 'Md.PTight')) }
            $p = $li.Blocks.FirstBlock
            if ($null -ne $it.Task -and $p -is [System.Windows.Documents.Paragraph]) {
                # 할 일: 앞에 체크 표시. 끝낸 일은 글만 흐리게 + 취소선 (Obsidian과 같음)
                $text = [System.Windows.Documents.Span]::new()
                foreach ($x in @($p.Inlines)) { [void]$p.Inlines.Remove($x); $text.Inlines.Add($x) }
                if ($it.Task) {
                    Set-WtResource $text 'Foreground' 'B.SubText'
                    $text.TextDecorations = [System.Windows.TextDecorations]::Strikethrough
                }
                $p.Inlines.Add((New-WtMdTaskBox $it.Task))
                $p.Inlines.Add((New-WtMdRun '  '))
                $p.Inlines.Add($text)
            } elseif ($hasTask -and -not $B.Ordered -and $p -is [System.Windows.Documents.Paragraph]) {
                $dot = New-WtMdRun '•   '
                if ($p.Inlines.FirstInline) { $p.Inlines.InsertBefore($p.Inlines.FirstInline, $dot) } else { $p.Inlines.Add($dot) }
            }
            Set-WtMdEdgeMargins $li.Blocks
            $list.ListItems.Add($li)
        }
    } finally { $St.ListDepth-- }
    $list
}

function New-WtMdCallout($B, $St) {
    $sec = [System.Windows.Documents.Section]::new()
    Set-WtMdStyle $sec 'Md.Callout'
    Set-WtResource $sec 'Background' "B.Callout.$($B.Color)Bg"
    Set-WtResource $sec 'BorderBrush' "B.Callout.$($B.Color)"

    $title = New-WtMdPara 'Md.CalloutTitle'
    Set-WtResource $title 'Foreground' "B.Callout.$($B.Color)"
    $body = [System.Windows.Documents.Section]::new()
    foreach ($c in $B.Blocks) { Add-WtMdBlock $body.Blocks $c $St }
    Set-WtMdEdgeMargins $body.Blocks
    $hasBody = $body.Blocks.Count -gt 0

    if ($B.Fold -and $hasBody) {
        # 접는 콜아웃: 제목을 누르면 본문을 넣었다 뺐다 한다
        $open = $B.Fold -eq '+'
        $link = [System.Windows.Documents.Hyperlink]::new()
        Set-WtMdStyle $link 'Md.FoldLink'
        Set-WtResource $link 'Foreground' "B.Callout.$($B.Color)"
        $chev = New-WtMdIconRun $(if ($open) { 0xE70D } else { 0xE76C })
        $link.Inlines.Add((New-WtMdIconRun $B.Icon))
        $link.Inlines.Add((New-WtMdRun "  $(Get-WtMdInlineText $B.Title)  "))
        $link.Inlines.Add($chev)
        $link.ToolTip = '접기 / 펼치기'
        $link.Tag = @{ Section = $sec; Title = $title; Body = $body; Chevron = $chev; Open = $open }
        $link.Add_Click({ param($s, $e) Switch-WtMdFold $s.Tag })
        $title.Inlines.Add($link)
        $sec.Blocks.Add($title)
        if ($open) { $sec.Blocks.Add($body) } else { $title.Margin = [System.Windows.Thickness]::new(0) }
    } else {
        $title.Inlines.Add((New-WtMdIconRun $B.Icon))
        $title.Inlines.Add((New-WtMdRun '  '))
        Add-WtMdInlines $title.Inlines $B.Title $St
        $sec.Blocks.Add($title)
        if ($hasBody) { $sec.Blocks.Add($body) } else { $title.Margin = [System.Windows.Thickness]::new(0) }
    }
    $sec
}

function Switch-WtMdFold($F) {
    $F.Open = -not $F.Open
    $F.Chevron.Text = [string][char]$(if ($F.Open) { 0xE70D } else { 0xE76C })
    if ($F.Open) {
        $F.Section.Blocks.Add($F.Body)
        $F.Title.ClearValue([System.Windows.Documents.Block]::MarginProperty)
    } else {
        [void]$F.Section.Blocks.Remove($F.Body)
        $F.Title.Margin = [System.Windows.Thickness]::new(0)
    }
}

# 코드 블록 머리: 언어 이름(왼쪽) + 복사 버튼(오른쪽)
function New-WtMdCodeHeader([string]$Label, [string]$Code) {
    $d = [System.Windows.Controls.DockPanel]::new()
    $copy = New-WtButton '복사' -Kind Link -Icon 0xE8C8 -ToolTip '코드 복사'
    $copy.Tag = $Code
    $copy.Add_Click({ param($s, $e) Copy-WtMdCode $s })
    [System.Windows.Controls.DockPanel]::SetDock($copy, 'Right')
    [void]$d.Children.Add($copy)
    $name = New-WtText $Label 'T.Sub'
    $name.VerticalAlignment = 'Center'
    [void]$d.Children.Add($name)
    $d
}

function Copy-WtMdCode($Button) {
    $text = [string]$Button.Tag
    $ok = $false
    for ($i = 0; $i -lt 3 -and -not $ok; $i++) {
        try { [System.Windows.Clipboard]::SetText($text); $ok = $true } catch { Start-Sleep -Milliseconds 50 }
    }
    if (-not $ok) { Show-WtMessage '클립보드를 다른 프로그램이 쓰고 있어서 복사하지 못했습니다. 다시 누르세요.' 'WorkTool' 'Warning'; return }
    $Button.Content = New-WtButtonContent '복사됨' 0xE73E
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromMilliseconds(1500)
    $t.Tag = $Button
    $t.Add_Tick({
            param($s, $e)
            $s.Stop()
            $s.Tag.Content = New-WtButtonContent '복사' 0xE8C8
        })
    $t.Start()
}

function New-WtMdCode($B, $St) {
    $lang = (([string]$B.Lang) -split '\s+')[0].ToLowerInvariant()
    $note = $null
    $r = $script:codeRenderers[$lang]
    if ($r) {
        try {
            $el = @(& $r.Render $B.Text | Where-Object { $_ -is [System.Windows.UIElement] }) | Select-Object -Last 1
            if (-not $el) { throw '그림을 만들지 못했습니다.' }
            if ($r.Remeasure) { $St.Remeasure = $true }
            $box = [System.Windows.Controls.Border]::new()
            Set-WtMdStyle $box 'Md.FigureBox'
            $dock = [System.Windows.Controls.DockPanel]::new()
            $head = New-WtMdCodeHeader $r.Label $B.Text
            [System.Windows.Controls.DockPanel]::SetDock($head, 'Top')
            [void]$dock.Children.Add($head)
            [void]$dock.Children.Add($el)
            $box.Child = $dock
            $c = [System.Windows.Documents.BlockUIContainer]::new($box)
            Set-WtMdStyle $c 'Md.Figure'
            return $c
        } catch {
            $note = "그리지 못해 원문을 보여 줍니다. $($_.Exception.Message)"
        }
    }

    $sec = [System.Windows.Documents.Section]::new()
    Set-WtMdStyle $sec 'Md.CodeBlock'
    $label = if ($lang) { $lang } else { '코드' }
    $headC = [System.Windows.Documents.BlockUIContainer]::new((New-WtMdCodeHeader $label $B.Text))
    Set-WtMdStyle $headC 'Md.CodeHead'
    $sec.Blocks.Add($headC)
    if ($note) {
        $np = New-WtMdPara 'Md.CodeNote'
        $np.Inlines.Add((New-WtMdIconRun 0xE7BA))
        $np.Inlines.Add((New-WtMdRun "  $note"))
        $sec.Blocks.Add($np)
    }
    $p = New-WtMdPara 'Md.CodeText'
    foreach ($tok in (Get-WtCodeTokens $B.Text $lang)) {
        $parts = $tok.Text -split "`n"
        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($i -gt 0) { $p.Inlines.Add([System.Windows.Documents.LineBreak]::new()) }
            if (-not $parts[$i]) { continue }
            $run = New-WtMdRun $parts[$i]
            if ($tok.Kind) { Set-WtResource $run 'Foreground' "B.Code.$($tok.Kind)" }
            $p.Inlines.Add($run)
        }
    }
    $sec.Blocks.Add($p)
    $sec
}

function New-WtMdTable($B, $St) {
    $t = [System.Windows.Documents.Table]::new()
    Set-WtMdStyle $t 'Md.Table'
    $n = @($B.Align).Count
    foreach ($row in $B.Rows) { $n = [Math]::Max($n, @($row.Cells).Count) }
    # 열 너비: FlowDocument 표에는 자동 너비가 없어서 글자 수에 맞춰 비율을 준다
    for ($i = 0; $i -lt $n; $i++) {
        $w = 3
        foreach ($row in $B.Rows) {
            if ($i -lt @($row.Cells).Count) { $w = [Math]::Max($w, (Get-WtMdBlocksText $row.Cells[$i]).Length) }
        }
        $col = [System.Windows.Documents.TableColumn]::new()
        $col.Width = [System.Windows.GridLength]::new([Math]::Min($w, 40), 'Star')
        $t.Columns.Add($col)
    }
    $g = [System.Windows.Documents.TableRowGroup]::new()
    foreach ($row in $B.Rows) {
        $tr = [System.Windows.Documents.TableRow]::new()
        for ($i = 0; $i -lt $n; $i++) {
            $cell = [System.Windows.Documents.TableCell]::new()
            Set-WtMdStyle $cell $(if ($row.Header) { 'Md.Th' } else { 'Md.Td' })
            $a = if ($i -lt @($B.Align).Count) { $B.Align[$i] } else { '' }
            if ($a) { $cell.TextAlignment = switch ($a) { 'center' { 'Center' } 'right' { 'Right' } default { 'Left' } } }
            if ($i -lt @($row.Cells).Count) { foreach ($c in $row.Cells[$i]) { Add-WtMdBlock $cell.Blocks $c $St $true } }
            if (-not $cell.Blocks.Count) { $cell.Blocks.Add((New-WtMdPara 'Md.PTight')) }
            $tr.Cells.Add($cell)
        }
        $g.Rows.Add($tr)
    }
    $t.RowGroups.Add($g)
    $t
}

# 맨 앞 속성(--- 사이): 이름 · 값 두 열 표
function New-WtMdProps($B, $St) {
    $t = [System.Windows.Documents.Table]::new()
    Set-WtMdStyle $t 'Md.Props'
    foreach ($w in 1, 3) {
        $col = [System.Windows.Documents.TableColumn]::new()
        $col.Width = [System.Windows.GridLength]::new($w, 'Star')
        $t.Columns.Add($col)
    }
    $g = [System.Windows.Documents.TableRowGroup]::new()
    foreach ($it in $B.Items) {
        $tr = [System.Windows.Documents.TableRow]::new()
        foreach ($pair in @(@('Md.PropKey', $it.Key), @('Md.PropValue', $it.Value))) {
            $cell = [System.Windows.Documents.TableCell]::new()
            Set-WtMdStyle $cell $pair[0]
            $p = New-WtMdPara 'Md.PTight'
            $p.Inlines.Add((New-WtMdRun $pair[1]))
            $cell.Blocks.Add($p)
            $tr.Cells.Add($cell)
        }
        $g.Rows.Add($tr)
    }
    $t.RowGroups.Add($g)
    $t
}

# 글자 크기를 바꾸면, 크기를 재서 배치한 그림(다이어그램)이 있는 보기를 다시 그린다.
# 크기는 설정에서 바로 읽으므로(Get-WtFontSize) 셸의 테마 갱신 순서와 상관없다.
Register-WtSettingHandler {
    param($key, $value)
    if ($key -ne 'ui.fontScale') { return }
    foreach ($w in @($script:views)) {
        $v = $w.Target
        if ($v -and $v.Tag.Remeasure) { Set-WtMarkdownText $v $v.Tag.Text }
    }
}

Export-ModuleMember -Function Register-WtMarkdownCodeRenderer, Register-WtMarkdownCallout, ConvertTo-WtMarkdownModel,
    Get-WtMarkdownSnippet, Get-WtMarkdownHeadings, New-WtMarkdownView, Set-WtMarkdownText, Invoke-WtMarkdownLink

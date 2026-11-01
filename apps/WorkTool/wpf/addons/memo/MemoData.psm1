# 메모 데이터 · 검색. 화면과 파일 I/O 없이 core/Storage.psm1의 핸들만 쓴다.
$ErrorActionPreference = 'Stop'
$script:memoInv = [Globalization.CultureInfo]::InvariantCulture
$script:memoQueryDays = [regex]::new('^([1-9][0-9]*)[dD]$', 'Compiled, CultureInvariant')
$script:memoRelativeDays = [regex]::new('^([0-9]+)d$', 'Compiled, CultureInvariant')
$script:memoDateRange = [regex]::new('\.\.', 'Compiled, CultureInvariant')

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
            $relative = $script:memoQueryDays.Match($value)
            if ($relative.Success) {
                $days = 0
                if (-not [int]::TryParse($relative.Groups[1].Value, [Globalization.NumberStyles]::None, $script:memoInv, [ref]$days) -or $days -gt 109573) {
                    Stop-WtMemoQuery $Reader $token.Position $token.Length '최근 날짜 수가 너무 큽니다.'
                }
                $value = $days.ToString($script:memoInv) + 'd'
            } else {
                $parts = $script:memoDateRange.Split($value.TrimStart('<', '>'))
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

# .NET 식 트리는 아래에 적힌 배열 반복/객체 생성만 실행한다. 문자열 코드를 해석하거나 형식을 정의하지 않는다.
# 공개 결과는 여전히 독립된 PSObject + NoteProperty다. 속성 용량을 미리 잡고 Properties를 한 번만 얻는다.
function New-WtMemoObjectExpression([string[]]$Names, [Linq.Expressions.Expression[]]$Values) {
    $expr = [Linq.Expressions.Expression]
    $rowVar = $expr::Variable([Management.Automation.PSObject], 'row')
    $propertiesVar = $expr::Variable([Management.Automation.PSMemberInfoCollection[Management.Automation.PSPropertyInfo]], 'properties')
    $steps = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
    $constructor = [Management.Automation.PSObject].GetConstructor([type[]]@([int]))
    $steps.Add($expr::Assign($rowVar, $script:memoNewExpression.Invoke($constructor, [Linq.Expressions.Expression[]]@($expr::Constant($Names.Length)))))
    $steps.Add($expr::Assign($propertiesVar, $expr::Property($rowVar, 'Properties')))
    $noteConstructor = [Management.Automation.PSNoteProperty].GetConstructor([type[]]@([string], [object]))
    $addProperty = [Management.Automation.PSMemberInfoCollection[Management.Automation.PSPropertyInfo]].GetMethod('Add', [type[]]@([Management.Automation.PSPropertyInfo], [bool]))
    for ($property = 0; $property -lt $Names.Length; $property++) {
        $note = $script:memoNewExpression.Invoke($noteConstructor, [Linq.Expressions.Expression[]]@($expr::Constant($Names[$property]), $expr::Convert($Values[$property], [object])))
        # 속성 이름은 위에서 정한 서로 다른 상수다. preValidated는 이름 검사를 되풀이하지 않게 한다.
        $steps.Add($expr::Call($propertiesVar, $addProperty, [Linq.Expressions.Expression[]]@($note, $expr::Constant($true))))
    }
    $steps.Add($expr::Convert($rowVar, [object]))
    $expr::Block([Linq.Expressions.ParameterExpression[]]@($rowVar, $propertiesVar), $steps)
}

function New-WtMemoLoopExpression($Iterator, $Length, $Body) {
    $expr = [Linq.Expressions.Expression]; $finish = $expr::Label()
    $step = $expr::Block([Linq.Expressions.Expression[]]@($Body, $expr::PostIncrementAssign($Iterator), $expr::Empty()))
    $expr::Loop($expr::IfThenElse($expr::LessThan($Iterator, $Length), $step, $expr::Break($finish)), $finish)
}

function New-WtMemoArrayFactory([type]$ElementType, $Arguments, $Number, $Length, $Element) {
    $expr = [Linq.Expressions.Expression]; $arrayType = $ElementType.MakeArrayType()
    $arrayVar = $expr::Variable($arrayType, 'result')
    $body = $expr::Block([Linq.Expressions.ParameterExpression[]]@($arrayVar, $Number), [Linq.Expressions.Expression[]]@(
        $expr::Assign($arrayVar, $expr::NewArrayBounds($ElementType, [Linq.Expressions.Expression[]]@($Length))),
        (New-WtMemoLoopExpression $Number $Length ($expr::Assign($expr::ArrayAccess($arrayVar, [Linq.Expressions.Expression[]]@($Number)), $Element))), $arrayVar))
    $delegateType = [Func``2].MakeGenericType([type[]]@([object[]], $arrayType))
    $expr::Lambda($delegateType, $body, [Linq.Expressions.ParameterExpression[]]@($Arguments)).Compile()
}

function Initialize-WtMemoSearchEngine {
    if ($script:memoRowsFactory) { return }
    $expr = [Linq.Expressions.Expression]
    # Expression.New는 PowerShell의 ::new 생성자 표기와 겹치므로 공개 메서드의 대리자를 한 번 얻는다.
    $script:memoNewExpression = $expr.GetMethod('New', [type[]]@([Reflection.ConstructorInfo], [Collections.Generic.IEnumerable[Linq.Expressions.Expression]])).CreateDelegate(
        [Func[Reflection.ConstructorInfo, Collections.Generic.IEnumerable[Linq.Expressions.Expression], Linq.Expressions.NewExpression]])

    $textsArg = $expr::Parameter([string[]], 'texts'); $needleArg = $expr::Parameter([string], 'needle')
    $foundVar = $expr::Variable([int[]], 'found'); $numberVar = $expr::Variable([int], 'number')
    $textAt = $expr::ArrayIndex($textsArg, $numberVar)
    $indexOf = [string].GetMethod('IndexOf', [type[]]@([string], [StringComparison]))
    $position = $expr::Condition($expr::Equal($textAt, $expr::Constant($null, [string])), $expr::Constant(-1),
        $expr::Call($textAt, $indexOf, [Linq.Expressions.Expression[]]@($needleArg, $expr::Constant([StringComparison]::Ordinal))))
    $body = $expr::Block([Linq.Expressions.ParameterExpression[]]@($foundVar, $numberVar), [Linq.Expressions.Expression[]]@(
        $expr::Assign($foundVar, $expr::NewArrayBounds([int], [Linq.Expressions.Expression[]]@($expr::ArrayLength($textsArg)))),
        (New-WtMemoLoopExpression $numberVar ($expr::ArrayLength($textsArg)) ($expr::Assign($expr::ArrayAccess($foundVar, [Linq.Expressions.Expression[]]@($numberVar)), $position))), $foundVar))
    $script:memoPositionsFactory = $expr::Lambda([Func[string[], string, int[]]], $body, [Linq.Expressions.ParameterExpression[]]@($textsArg, $needleArg)).Compile()

    # 조건 잎의 배열 판정. 해석/날짜 검증/연결 대상 오류는 PowerShell 경로에 그대로 둔다.
    $maskInput = $expr::Parameter([object[]], 'input')
    $candidateColumn = $expr::Convert($expr::ArrayIndex($maskInput, $expr::Constant(0)), [bool[]])
    $candidateAt = $expr::ArrayIndex($candidateColumn, $numberVar)
    $secondArg = $expr::ArrayIndex($maskInput, $expr::Constant(1)); $thirdArg = $expr::ArrayIndex($maskInput, $expr::Constant(2))
    $boolAt = $expr::ArrayIndex($expr::Convert($secondArg, [bool[]]), $numberVar)
    $intAt = $expr::ArrayIndex($expr::Convert($secondArg, [int[]]), $numberVar)
    $dayAt = $expr::ArrayIndex($expr::Convert($secondArg, [long[]]), $numberVar)
    $tagsAt = $expr::ArrayIndex($expr::Convert($secondArg, [Collections.Generic.HashSet[string][]]), $numberVar)
    $fromValue = $expr::Convert($thirdArg, [long])
    $positiveInt = $expr::GreaterThanOrEqual($intAt, $expr::Constant(0))
    $predicates = @{
        position = $positiveInt
        text = $expr::OrElse($positiveInt, $expr::GreaterThanOrEqual($expr::ArrayIndex($expr::Convert($thirdArg, [int[]]), $numberVar), $expr::Constant(0)))
        tag = $expr::Call($tagsAt, [Collections.Generic.HashSet[string]].GetMethod('Contains'), [Linq.Expressions.Expression[]]@($expr::Convert($thirdArg, [string])))
        no = $expr::Equal($expr::Property($tagsAt, 'Count'), $expr::Constant(0))
        flag = $boolAt
        backlink = $expr::GreaterThan($intAt, $expr::Constant(0))
        folder = $expr::Call($expr::Convert($thirdArg, [Collections.Generic.HashSet[string]]), [Collections.Generic.HashSet[string]].GetMethod('Contains'), [Linq.Expressions.Expression[]]@($expr::ArrayIndex($expr::Convert($secondArg, [string[]]), $numberVar)))
        before = $expr::AndAlso($expr::GreaterThanOrEqual($dayAt, $expr::Constant(0L)), $expr::LessThan($dayAt, $fromValue))
        after = $expr::GreaterThan($dayAt, $fromValue)
        range = $expr::AndAlso($expr::GreaterThanOrEqual($dayAt, $fromValue), $expr::LessThanOrEqual($dayAt, $expr::Convert($expr::ArrayIndex($maskInput, $expr::Constant(3)), [long])))
        not = $expr::Not($boolAt)
    }
    $script:memoMaskFactories = @{}
    foreach ($name in $predicates.Keys) {
        $script:memoMaskFactories[$name] = New-WtMemoArrayFactory ([bool]) $maskInput $numberVar ($expr::ArrayLength($candidateColumn)) ($expr::AndAlso($candidateAt, $predicates[$name]))
    }
    $script:memoMaskFactories.or = New-WtMemoArrayFactory ([bool]) $maskInput $numberVar ($expr::ArrayLength($candidateColumn)) ($expr::OrElse($candidateAt, $boolAt))

    # 순위/일치 위치: 행마다 PowerShell 객체 변환을 반복하지 않고 같은 규칙을 배열에 적용한다.
    $rankArg = $expr::Parameter([object[]], 'input')
    $rankTypes = [type[]]@([string[]], [string[]], [string[]], [int[][]], [int[][]], [bool[]], [string])
    $rankColumns = @(for ($column = 0; $column -lt $rankTypes.Length; $column++) {
        $expr::Convert($expr::ArrayIndex($rankArg, $expr::Constant($column)), $rankTypes[$column])
    })
    $ranksVar = $expr::Variable([int[]], 'ranks'); $startsVar = $expr::Variable([int[]], 'starts'); $locationsVar = $expr::Variable([object[]], 'locations')
    $termVar = $expr::Variable([int], 'term'); $titleAtVar = $expr::Variable([int], 'titleAt'); $bodyAtVar = $expr::Variable([int], 'bodyAt')
    $rankVar = $expr::Variable([int], 'rank'); $bodyStartVar = $expr::Variable([int], 'bodyStart')
    $titleHitsVar = $expr::Variable([int], 'titleHits'); $matchedVar = $expr::Variable([int], 'matched')
    $hitsVar = $expr::Variable([Collections.Generic.List[object]], 'hits')
    $needleAt = $expr::ArrayIndex($rankColumns[2], $termVar)
    $termLength = $expr::Property($needleAt, 'Length'); $termCount = $expr::ArrayLength($rankColumns[2])
    $titleLocations = $expr::ArrayIndex($rankColumns[3], $termVar); $bodyLocations = $expr::ArrayIndex($rankColumns[4], $termVar)
    $titleFound = $expr::GreaterThanOrEqual($titleAtVar, $expr::Constant(0)); $bodyFound = $expr::GreaterThanOrEqual($bodyAtVar, $expr::Constant(0))
    $equalText = [string].GetMethod('Equals', [type[]]@([string], [string], [StringComparison]))
    $addHit = [Collections.Generic.List[object]].GetMethod('Add')
    $termStep = $expr::Block([Linq.Expressions.Expression[]]@(
        $expr::Assign($titleAtVar, $expr::Condition($expr::Equal($titleLocations, $expr::Constant($null, [int[]])), $expr::Constant(-1), $expr::ArrayIndex($titleLocations, $numberVar))),
        $expr::Assign($bodyAtVar, $expr::Condition($expr::Equal($bodyLocations, $expr::Constant($null, [int[]])), $expr::Constant(-1), $expr::ArrayIndex($bodyLocations, $numberVar))),
        $expr::IfThen($expr::OrElse($titleFound, $bodyFound), $expr::PostIncrementAssign($matchedVar)),
        $expr::IfThen($titleFound, $expr::Block([Linq.Expressions.Expression[]]@(
            $expr::PostIncrementAssign($titleHitsVar),
            $expr::Call($hitsVar, $addHit, [Linq.Expressions.Expression[]]@((New-WtMemoObjectExpression @('Field', 'Start', 'Length') @($expr::Constant('title'), $titleAtVar, $termLength)))),
            $expr::IfThen($expr::Call($equalText, [Linq.Expressions.Expression[]]@($expr::ArrayIndex($rankColumns[0], $numberVar), $needleAt, $expr::Constant([StringComparison]::InvariantCultureIgnoreCase))), $expr::Assign($rankVar, $expr::Constant(0)))))),
        $expr::IfThen($bodyFound, $expr::Block([Linq.Expressions.Expression[]]@(
            $expr::Call($hitsVar, $addHit, [Linq.Expressions.Expression[]]@((New-WtMemoObjectExpression @('Field', 'Start', 'Length') @($expr::Constant('body'), $bodyAtVar, $termLength)))),
            $expr::IfThen($expr::OrElse($expr::LessThan($bodyStartVar, $expr::Constant(0)), $expr::LessThan($bodyAtVar, $bodyStartVar)), $expr::Assign($bodyStartVar, $bodyAtVar)))))))
    $exactTitle = $expr::AndAlso($expr::Equal($titleHitsVar, $termCount), $expr::Call($equalText, [Linq.Expressions.Expression[]]@(
        $expr::ArrayIndex($rankColumns[1], $numberVar), $rankColumns[6], $expr::Constant([StringComparison]::OrdinalIgnoreCase))))
    $rankStep = $expr::Block([Linq.Expressions.Expression[]]@(
        $expr::Assign($rankVar, $expr::Constant(3)), $expr::Assign($bodyStartVar, $expr::Constant(-1)),
        $expr::Assign($titleHitsVar, $expr::Constant(0)), $expr::Assign($matchedVar, $expr::Constant(0)), $expr::Assign($termVar, $expr::Constant(0)),
        $expr::Assign($hitsVar, $script:memoNewExpression.Invoke([Collections.Generic.List[object]].GetConstructor([type[]]@([int])), [Linq.Expressions.Expression[]]@($expr::Multiply($termCount, $expr::Constant(2))))),
        (New-WtMemoLoopExpression $termVar $termCount $termStep),
        $expr::IfThenElse($exactTitle, $expr::Assign($rankVar, $expr::Constant(0)),
            $expr::IfThen($expr::NotEqual($rankVar, $expr::Constant(0)), $expr::Assign($rankVar, $expr::Condition(
                $expr::AndAlso($expr::GreaterThan($titleHitsVar, $expr::Constant(0)), $expr::Equal($titleHitsVar, $matchedVar)), $expr::Constant(1), $expr::Constant(2))))),
        $expr::Assign($expr::ArrayAccess($ranksVar, [Linq.Expressions.Expression[]]@($numberVar)), $rankVar),
        $expr::Assign($expr::ArrayAccess($locationsVar, [Linq.Expressions.Expression[]]@($numberVar)), $expr::Call($hitsVar, [Collections.Generic.List[object]].GetMethod('ToArray'))),
        $expr::Assign($expr::ArrayAccess($startsVar, [Linq.Expressions.Expression[]]@($numberVar)),
            $expr::Call([Math].GetMethod('Max', [type[]]@([int], [int])), [Linq.Expressions.Expression[]]@($expr::Constant(0), $expr::Subtract($bodyStartVar, $expr::Constant(24)))))))
    $rankCount = $expr::ArrayLength($rankColumns[5])
    $rankBody = $expr::Block([Linq.Expressions.ParameterExpression[]]@($ranksVar, $startsVar, $locationsVar, $numberVar, $termVar, $titleAtVar, $bodyAtVar, $rankVar, $bodyStartVar, $titleHitsVar, $matchedVar, $hitsVar), [Linq.Expressions.Expression[]]@(
        $expr::Assign($ranksVar, $expr::NewArrayBounds([int], [Linq.Expressions.Expression[]]@($rankCount))),
        $expr::Assign($startsVar, $expr::NewArrayBounds([int], [Linq.Expressions.Expression[]]@($rankCount))),
        $expr::Assign($locationsVar, $expr::NewArrayBounds([object], [Linq.Expressions.Expression[]]@($rankCount))),
        (New-WtMemoLoopExpression $numberVar $rankCount ($expr::IfThen($expr::ArrayIndex($rankColumns[5], $numberVar), $rankStep))),
        $expr::NewArrayInit([object], [Linq.Expressions.Expression[]]@($expr::Convert($ranksVar, [object]), $expr::Convert($startsVar, [object]), $expr::Convert($locationsVar, [object])))))
    $script:memoRanksFactory = $expr::Lambda([Func[object[], object[]]], $rankBody, [Linq.Expressions.ParameterExpression[]]@($rankArg)).Compile()

    # 기본 순서를 유지하면서 일치 번호만 모은다. 검색어 순위가 있으면 0~3 네 번의 짧은 배열 순회다.
    $orderArg = $expr::Parameter([int[]], 'order'); $maskArg = $expr::Parameter([bool[]], 'mask'); $ranksArg = $expr::Parameter([int[]], 'ranks'); $rankedArg = $expr::Parameter([bool], 'ranked')
    $selectedVar = $expr::Variable([Collections.Generic.List[int]], 'selected'); $passVar = $expr::Variable([int], 'pass')
    $orderAt = $expr::ArrayIndex($orderArg, $numberVar)
    $selectedStep = $expr::IfThen($expr::AndAlso($expr::ArrayIndex($maskArg, $orderAt),
        $expr::OrElse($expr::Not($rankedArg), $expr::Equal($expr::ArrayIndex($ranksArg, $orderAt), $passVar))),
        $expr::Call($selectedVar, [Collections.Generic.List[int]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($orderAt)))
    $selectBody = $expr::Block([Linq.Expressions.ParameterExpression[]]@($selectedVar, $numberVar, $passVar), [Linq.Expressions.Expression[]]@(
        $expr::Assign($selectedVar, $script:memoNewExpression.Invoke([Collections.Generic.List[int]].GetConstructor([type[]]@([int])), [Linq.Expressions.Expression[]]@($expr::ArrayLength($orderArg)))),
        (New-WtMemoLoopExpression $passVar ($expr::Condition($rankedArg, $expr::Constant(4), $expr::Constant(1))) ($expr::Block([Linq.Expressions.Expression[]]@(
            $expr::Assign($numberVar, $expr::Constant(0)), (New-WtMemoLoopExpression $numberVar ($expr::ArrayLength($orderArg)) $selectedStep))))),
        $expr::Call($selectedVar, [Collections.Generic.List[int]].GetMethod('ToArray'))))
    $script:memoSelectFactory = $expr::Lambda([Func[int[], bool[], int[], bool, int[]]], $selectBody, [Linq.Expressions.ParameterExpression[]]@($orderArg, $maskArg, $ranksArg, $rankedArg)).Compile()

    # 정렬 키는 원래의 여섯 칸 Tuple이며 비교도 .NET 기본 비교기를 그대로 사용한다.
    $sortInput = $expr::Parameter([object[]], 'input')
    $sortTypes = [type[]]@([bool[]], [long[]], [long[]], [int[]], [int[]], [long[]], [bool], [int[]])
    $sortColumns = @(for ($column = 0; $column -lt $sortTypes.Length; $column++) {
        $expr::Convert($expr::ArrayIndex($sortInput, $expr::Constant($column)), $sortTypes[$column])
    })
    $sortSlot = $expr::ArrayIndex($sortColumns[7], $numberVar)
    $pinAt = $expr::ArrayIndex($sortColumns[0], $sortSlot); $updatedAt = $expr::ArrayIndex($sortColumns[2], $sortSlot)
    $primaryAt = $expr::ArrayIndex($sortColumns[5], $sortSlot)
    $keyType = [Tuple[long, int, long, long, int, int]]
    $sortKey = $script:memoNewExpression.Invoke($keyType.GetConstructors()[0], [Linq.Expressions.Expression[]]@(
        $expr::Condition($sortColumns[6], $expr::Negate($primaryAt), $primaryAt),
        $expr::Condition($pinAt, $expr::Constant(0), $expr::Constant(1)),
        $expr::Condition($pinAt, $expr::ArrayIndex($sortColumns[1], $sortSlot), $expr::Constant(0L)),
        $expr::Condition($expr::GreaterThanOrEqual($updatedAt, $expr::Constant(0L)), $expr::Negate($updatedAt), $expr::Constant([long]::MaxValue)),
        $expr::ArrayIndex($sortColumns[3], $sortSlot), $expr::ArrayIndex($sortColumns[4], $sortSlot)))
    $script:memoSortFactory = New-WtMemoArrayFactory $keyType $sortInput $numberVar ($expr::ArrayLength($sortColumns[7])) $sortKey

    # 칸 순서는 Find-WtMemo의 rowColumns와 같다. 원문/태그/일치 위치도 결과끼리 공유하지 않는다.
    $columnsArg = $expr::Parameter([object[]], 'columns'); $itemsArg = $expr::Parameter([int[]], 'items'); $limitArg = $expr::Parameter([int], 'limit')
    $rowsVar = $expr::Variable([object[]], 'rows'); $atVar = $expr::Variable([int], 'at'); $slotVar = $expr::Variable([int], 'slot')
    $folderVar = $expr::Variable([string[]], 'folder')
    $types = [type[]]@([string[]], [string[]], [object[]], [string[]], [int[]], [string[]], [object[]], [Collections.Generic.HashSet[string][]], [bool[]], [long[]], [bool[]], [int[]], [object[]], [object[]], [object[]], [int[]])
    $values = [Linq.Expressions.Expression[]]::new($types.Length)
    for ($column = 0; $column -lt $types.Length; $column++) {
        $values[$column] = $expr::ArrayIndex($expr::Convert($expr::ArrayIndex($columnsArg, $expr::Constant($column)), $types[$column]), $slotVar)
    }
    $bodyText = $values[3]; $start = $values[4]
    $snippetLength = $expr::Call([Math].GetMethod('Min', [type[]]@([int], [int])), [Linq.Expressions.Expression[]]@(
        $expr::Constant(80), $expr::Subtract($expr::Property($bodyText, 'Length'), $start)))
    $values[3] = $expr::Condition($expr::LessThan($atVar, $limitArg),
        $expr::Call($bodyText, [string].GetMethod('Substring', [type[]]@([int], [int])), [Linq.Expressions.Expression[]]@($start, $snippetLength)), $expr::Constant(''))
    $values[7] = $expr::Call([Linq.Enumerable].GetMethod('ToArray').MakeGenericMethod([string]), [Linq.Expressions.Expression[]]@($values[7]))
    $folderMapType = [Collections.Generic.Dictionary[string, string[]]]
    $folderMap = $expr::Convert($expr::ArrayIndex($columnsArg, $expr::Constant(6)), $folderMapType)
    $missingFolder = [string[]]::new(2); $missingFolder[1] = '폴더 없음'
    $folderStep = $expr::IfThen($expr::Not($expr::Call($folderMap, $folderMapType.GetMethod('TryGetValue'), [Linq.Expressions.Expression[]]@($values[5], $folderVar))),
        $expr::Assign($folderVar, $expr::Constant($missingFolder)))
    $values[5] = $expr::ArrayIndex($folderVar, $expr::Constant(0)); $values[6] = $expr::ArrayIndex($folderVar, $expr::Constant(1))
    $rowExpression = New-WtMemoObjectExpression @('Id', 'Title', 'Matches', 'Snippet', 'SnippetStart', 'Folder', 'FolderName', 'Tags', 'Pinned', 'PinOrder', 'Archived', 'Rank', 'Updated', 'Created', 'Opened', 'Backlinks') $values
    $rowStep = $expr::Block([Linq.Expressions.Expression[]]@(
        $expr::Assign($slotVar, $expr::ArrayIndex($itemsArg, $atVar)), $folderStep, $expr::Assign($expr::ArrayAccess($rowsVar, [Linq.Expressions.Expression[]]@($atVar)), $rowExpression)))
    $body = $expr::Block([Linq.Expressions.ParameterExpression[]]@($rowsVar, $atVar, $slotVar, $folderVar), [Linq.Expressions.Expression[]]@(
        $expr::Assign($rowsVar, $expr::NewArrayBounds([object], [Linq.Expressions.Expression[]]@($expr::ArrayLength($itemsArg)))),
        (New-WtMemoLoopExpression $atVar ($expr::ArrayLength($itemsArg)) $rowStep), $rowsVar))
    $script:memoRowsFactory = $expr::Lambda([Func[object[], int[], int, object[]]], $body, [Linq.Expressions.ParameterExpression[]]@($columnsArg, $itemsArg, $limitArg)).Compile()
}

# ---- 색인: 나란한 칸 목록. 메모 번호는 갱신/삭제 후에도 바꾸지 않는다. -------------------------
function New-WtMemoStringSet { , [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }

# 연결이 될 수 있는 글자가 하나도 없으면 마크다운을 읽지 않는다. 아래 해석은 메모 하나에 약 12ms다
$script:memoLinkHint = [regex]::new('[\[<]|://|www\.|mailto:|tel:', [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)

function Get-WtMemoLinkInfo([string]$Body) {
    $outgoing = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $hasLink = $false
    if (-not $script:memoLinkHint.IsMatch($Body)) { return @{ Outgoing = $outgoing; HasLink = $false } }
    $stack = [Collections.Generic.Stack[object]]::new()
    $stack.Push((ConvertTo-WtMarkdownModel $Body).Blocks)
    while ($stack.Count) {
        $nodes = $stack.Pop()
        foreach ($node in $nodes) {
            if ($null -eq $node) { continue }
            if ($node.T -eq 'link') {
                $hasLink = $true
                if ($node.Kind -eq 'wiki') {
                    $target = [string]$node.Target; $hashAt = $target.IndexOf('#', [StringComparison]::Ordinal)
                    if ($hashAt -ge 0) { $target = $target.Substring(0, $hashAt) }
                    $target = $target.Trim().ToLowerInvariant()
                    if ($target) { [void]$outgoing.Add($target) }
                }
            }
            foreach ($key in 'Inl', 'Title', 'Blocks', 'Items') { if ($node.$key -is [array]) { $stack.Push($node.$key) } }
            foreach ($cell in $node.Cells) { if ($cell) { $stack.Push($cell) } }
        }
    }
    @{ Outgoing = $outgoing; HasLink = $hasLink }
}

# 옛 memo.json의 시간대 없는 앱 시각도 읽되 글 자체는 바꾸지 않는다.
function Get-WtMemoIndexedTime([string]$Text) {
    $at = ConvertFrom-WtStamp $Text
    if ($null -ne $at) { return $at }
    $old = ConvertFrom-WtLegacyStamp $Text
    if ($old) { return ConvertFrom-WtStamp $old }
    $null
}

# 공개 색인의 옛 Entries/Sources는 요청할 때만 만든다. 검색은 이 사본을 사용하지 않는다.
function Get-WtMemoIndexEntries($Index) {
    Initialize-WtMemoLinks $Index
    if ($Index.OrderDirty) { Update-WtMemoIndexOrder $Index }
    $c = $Index.Columns
    $entries = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    for ($n = 0; $n -lt $c.Id.Count; $n++) {
        if (-not $c.Alive[$n]) { continue }
        $entries[$c.Id[$n]] = [pscustomobject]@{
            Id = $c.Id[$n]; Title = $c.Title[$n]; Body = $c.Body[$n]; TitleLower = $c.TitleLower[$n]; BodyLower = $c.BodyLower[$n]
            Tags = $c.Tags[$n]; Folder = $c.Folder[$n]; Pinned = $c.Pinned[$n]; PinOrder = $c.PinOrder[$n]; Archived = $c.Archived[$n]
            Created = $c.Created[$n]; Updated = $c.Updated[$n]; Outgoing = $c.Outgoing[$n]; HasLink = $c.HasLink[$n]
            BacklinkCount = $c.BacklinkCount[$n]; TitleOrdinal = $c.TitleOrdinal[$n]; IdOrdinal = $c.IdOrdinal[$n]
        }
    }
    , $entries
}

function Update-WtMemoBacklinks($Index, [string]$TitleLower) {
    if (-not $Index.Titles.ContainsKey($TitleLower)) { return }
    $count = if ($Index.Titles[$TitleLower].Count -eq 1 -and $Index.LinkSources.ContainsKey($TitleLower)) { $Index.LinkSources[$TitleLower].Count } else { 0 }
    foreach ($id in $Index.Titles[$TitleLower]) { $Index.Columns.BacklinkCount[$Index.Slots[$id]] = $count }
}

function Initialize-WtMemoLinks($Index) {
    if ($Index.LinksReady) { return }
    $c = $Index.Columns
    # 같은 본문은 한 번만 해석한다. Markdown의 코드/위키 연결 규칙은 기존 해석기를 그대로 쓴다.
    $cache = $Index.LinkCache
    for ($n = 0; $n -lt $c.Id.Count; $n++) {
        if (-not $c.Alive[$n]) { continue }
        $body = $c.Body[$n]
        if (-not $cache.ContainsKey($body)) { $cache[$body] = Get-WtMemoLinkInfo $body }
        $info = $cache[$body]; $c.Outgoing[$n] = $info.Outgoing; $c.HasLink[$n] = $info.HasLink
        foreach ($target in $info.Outgoing) {
            if (-not $Index.LinkSources.ContainsKey($target)) { $Index.LinkSources[$target] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
            [void]$Index.LinkSources[$target].Add($c.Id[$n])
        }
    }
    $Index.LinksReady = $true
    $cache.Clear()
    # 처음의 받는 연결 수는 모두 0이다. 실제로 연결을 받는 제목만 갱신하면 된다.
    foreach ($target in $Index.LinkSources.Keys) { Update-WtMemoBacklinks $Index $target }
}

# 연결 해석을 정한 시간만큼만 한다. 화면을 세우지 않으려고 화면이 쉴 때 나눠서 부른다.
# 결과는 본문별로 남고 Initialize-WtMemoLinks가 그대로 쓴다. 그사이 고친 본문은 그때 해석한다. 다 끝나면 $true
function Step-WtMemoLinks {
    param([Parameter(Mandatory)]$Index, [int]$Milliseconds = 8)
    if ($Index.LinksReady) { return $true }
    $c = $Index.Columns; $cache = $Index.LinkCache
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($Index.LinkCursor -lt $c.Id.Count) {
        $n = $Index.LinkCursor; $Index.LinkCursor = $n + 1
        if ($c.Alive[$n] -and -not $cache.ContainsKey($c.Body[$n])) { $cache[$c.Body[$n]] = Get-WtMemoLinkInfo $c.Body[$n] }
        if ($watch.ElapsedMilliseconds -ge $Milliseconds) { return $false }
    }
    Initialize-WtMemoLinks $Index
    $true
}

# 이 검색이 연결 정보를 쓰는지 (빼는 조건 포함)
function Test-WtMemoQueryLinks($Node) {
    if ($Node.Kind -eq 'term') { return $Node.Field -in 'has', 'linksto' }
    if ($Node.Kind -eq 'not') { return Test-WtMemoQueryLinks $Node.Child }
    foreach ($child in @($Node.Children)) { if ($child -and (Test-WtMemoQueryLinks $child)) { return $true } }
    $false
}

# 정렬용 ordinal은 제목/id가 바뀐 다음 검색에서만 다시 만든다. 갱신 자체는 한 칸만 고친다.
function Update-WtMemoIndexOrder($Index) {
    $c = $Index.Columns
    $titles = [string[]]@($Index.Titles.Keys); [Array]::Sort($titles, [StringComparer]::Ordinal)
    $ids = [string[]]@($Index.Slots.Keys); [Array]::Sort($ids, [StringComparer]::Ordinal)
    $script:memoIndexOrderFactory.Invoke($titles, $ids, $Index.Slots, $c.TitleLower, $c.TitleOrdinal, $c.IdOrdinal)
    $Index.OrderDirty = $false
}

# 처음에는 전체 목록을 한 번에 넘기고, 증분 갱신은 한 항목만 넘긴다.
function Set-WtMemoIndexEntry($Index, [object[]]$Memos) {
    $c = $Index.Columns; $slots = $Index.Slots; $titles = $Index.Titles; $sources = $Index.LinkSources
    $Index.SortOrders.Clear()
    $affected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $bodyLowers = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $timeParts = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($memo in $Memos) {
        if ($null -eq $memo -or $memo -is [string] -or $memo -is [ValueType] -or $memo -is [array]) { continue }
        $id = $memo.id
        if ($id -isnot [string] -or -not $id) { continue }
        $deleted = $memo.deleted
        $isDeleted = $null -ne $deleted -and -not ($deleted -is [bool] -and -not $deleted) -and "$deleted" -ne ''
        if ($slots.ContainsKey($id)) {
            $n = $slots[$id]; $oldTitle = $c.TitleLower[$n]; $oldBody = $c.Body[$n]
            [void]$affected.Add($oldTitle)
            [void]$titles[$oldTitle].Remove($id)
            if (-not $titles[$oldTitle].Count) { [void]$titles.Remove($oldTitle) }
            if ($Index.LinksReady) {
                foreach ($target in $c.Outgoing[$n]) {
                    [void]$affected.Add($target); [void]$sources[$target].Remove($id)
                    if (-not $sources[$target].Count) { [void]$sources.Remove($target) }
                }
            }
            if ($isDeleted) {
                $c.Alive[$n] = $false; [void]$slots.Remove($id); $Index.OrderDirty = $true
                continue
            }
        } else {
            if ($isDeleted) { continue }
            if ($Index.NextSlot -eq $c.Id.Count) {
                # 묶음 전체의 빈 칸을 .NET으로 한 번에 확보한다. 갱신 때는 기존 칸만 쓴다.
                foreach ($name in 'Id', 'Title', 'Body', 'TitleLower', 'BodyLower', 'Folder') { $c[$name].AddRange([string[]]::new($Memos.Count)) }
                foreach ($name in 'Pinned', 'Archived', 'Alive', 'HasLink') { $c[$name].AddRange([bool[]]::new($Memos.Count)) }
                foreach ($name in 'PinOrder', 'CreatedTicks', 'UpdatedTicks', 'CreatedDay', 'UpdatedDay') { $c[$name].AddRange([long[]]::new($Memos.Count)) }
                foreach ($name in 'BacklinkCount', 'TitleOrdinal', 'IdOrdinal') { $c[$name].AddRange([int[]]::new($Memos.Count)) }
                foreach ($name in 'Created', 'Updated', 'Outgoing', 'Tags') { $c[$name].AddRange([object[]]::new($Memos.Count)) }
            }
            $n = $Index.NextSlot; $Index.NextSlot++; $slots[$id] = $n; $oldTitle = $null; $oldBody = $null
            $Index.OrderDirty = $true
        }
        $title = [string]$memo.title; $body = [string]$memo.body; $titleLower = $title.ToLowerInvariant()
        $c.Id[$n] = $id; $c.Title[$n] = $title; $c.Body[$n] = $body
        if (-not $bodyLowers.ContainsKey($body)) { $bodyLowers[$body] = $body.ToLowerInvariant() }
        $c.TitleLower[$n] = $titleLower; $c.BodyLower[$n] = $bodyLowers[$body]
        $tags = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($tag in $memo.tags) { if ($tag -is [string]) { [void]$tags.Add($tag.ToLowerInvariant()) } }
        $c.Tags[$n] = $tags; $c.Folder[$n] = [string]$memo.folder; $c.Pinned[$n] = ($memo.pinned -eq $true)
        $c.Archived[$n] = ($memo.archived -eq $true); $c.Alive[$n] = $true
        $order = $memo.pinOrder
        if ($order -isnot [long] -and $order -isnot [int] -and $null -ne $order) { $order = ConvertFrom-WtWhole $order ([long]::MinValue) ([long]::MaxValue) }
        $c.PinOrder[$n] = if ($null -eq $order) { [long]::MaxValue } else { [long]$order }
        foreach ($name in 'Created', 'Updated') {
            $text = [string]$memo.$name
            if (-not $timeParts.ContainsKey($text)) {
                if (-not $Index.TimeCache.ContainsKey($text)) {
                    $stamp = [DateTimeOffset]::MinValue
                    $valid = [DateTimeOffset]::TryParseExact($text, "yyyy-MM-dd'T'HH:mm:sszzz", $script:memoInv, [Globalization.DateTimeStyles]::None, [ref]$stamp)
                    $Index.TimeCache[$text] = if ($valid) { $stamp } elseif ($text) { Get-WtMemoIndexedTime $text } else { $null }
                }
                $stamp = $Index.TimeCache[$text]
                $timeParts[$text] = if ($null -eq $stamp) { [object[]]@($null, -1L, -1L) } else { [object[]]@($stamp, $stamp.UtcTicks, $stamp.LocalDateTime.Date.Ticks) }
            }
            $parts = $timeParts[$text]; $c[$name][$n] = $parts[0]
            $c[$name + 'Ticks'][$n] = $parts[1]; $c[$name + 'Day'][$n] = $parts[2]
        }
        if (-not $titles.ContainsKey($titleLower)) { $titles[$titleLower] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
        [void]$titles[$titleLower].Add($id); [void]$affected.Add($titleLower)
        if ($null -eq $oldTitle -or -not [string]::Equals($oldTitle, $titleLower, [StringComparison]::Ordinal)) { $Index.OrderDirty = $true }
        if ($Index.LinksReady) {
            if ($null -eq $c.Outgoing[$n] -or -not [string]::Equals($oldBody, $body, [StringComparison]::Ordinal)) {
                $info = Get-WtMemoLinkInfo $body; $c.Outgoing[$n] = $info.Outgoing; $c.HasLink[$n] = $info.HasLink
            }
            foreach ($target in $c.Outgoing[$n]) {
                [void]$affected.Add($target)
                if (-not $sources.ContainsKey($target)) { $sources[$target] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal) }
                [void]$sources[$target].Add($id)
            }
        }
    }
    if ($Index.LinksReady) { foreach ($target in $affected) { Update-WtMemoBacklinks $Index $target } }
}

function New-WtMemoIndex {
    param([Parameter(Position = 0)][AllowEmptyCollection()][object[]]$Memos = @(), [object[]]$Folders)
    if (-not $PSBoundParameters.ContainsKey('Folders')) { $Folders = @(Get-WtMemoDefaultFolders) }
    $c = @{}
    foreach ($name in 'Id', 'Title', 'Body', 'TitleLower', 'BodyLower', 'Folder') { $c[$name] = [Collections.Generic.List[string]]::new($Memos.Count) }
    foreach ($name in 'Pinned', 'Archived', 'Alive', 'HasLink') { $c[$name] = [Collections.Generic.List[bool]]::new($Memos.Count) }
    foreach ($name in 'PinOrder', 'CreatedTicks', 'UpdatedTicks', 'CreatedDay', 'UpdatedDay') { $c[$name] = [Collections.Generic.List[long]]::new($Memos.Count) }
    foreach ($name in 'BacklinkCount', 'TitleOrdinal', 'IdOrdinal') { $c[$name] = [Collections.Generic.List[int]]::new($Memos.Count) }
    foreach ($name in 'Created', 'Updated', 'Outgoing', 'Tags') { $c[$name] = [Collections.Generic.List[object]]::new($Memos.Count) }
    $index = [pscustomobject]@{
        Columns = $c; Slots = [Collections.Generic.Dictionary[string, int]]::new([StringComparer]::Ordinal)
        Titles = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        LinkSources = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        Folders = @($Folders); LinksReady = $false; OrderDirty = $true; NextSlot = 0
        LinkCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal); LinkCursor = 0
        SortOrders = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        TimeCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    }
    Set-WtMemoIndexProperties $index
    # 처음 나온 id가 지운 줄/빈 id여도 뒤의 중복 줄을 채택하지 않는 옛 규칙을 유지한다.
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $unique = [Collections.Generic.List[object]]::new($Memos.Count)
    foreach ($memo in $Memos) {
        $id = if ($memo -is [Collections.IDictionary]) { $memo['id'] } elseif ($memo -is [pscustomobject]) { $memo.id } elseif ($null -ne $memo) { $memo.PSObject.Properties['id'].Value } else { $null }
        if ($id -is [string] -and $seen.Add($id)) { $unique.Add($memo) }
    }
    Set-WtMemoIndexEntry $index $unique.ToArray()
    Update-WtMemoIndexOrder $index
    $index
}

# 화면 밖 결과의 속성은 받는 모듈에서 다시 묶는다. 끝난 작업의 실행 공간/지역 변수를 붙잡지 않는다.
function Set-WtMemoIndexProperties($Index) {
    $Index.PSObject.Properties.Remove('Entries')
    $Index.PSObject.Properties.Remove('Sources')
    $Index.PSObject.Properties.Add([Management.Automation.PSScriptProperty]::new('Entries', { Get-WtMemoIndexEntries $this }))
    $Index.PSObject.Properties.Add([Management.Automation.PSScriptProperty]::new('Sources', { Initialize-WtMemoLinks $this; , $this.LinkSources }))
}

function Update-WtMemoIndex {
    [CmdletBinding(DefaultParameterSetName = 'memo')]
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory, ParameterSetName = 'memo')]$Memo,
        [Parameter(Mandatory, ParameterSetName = 'remove')][string]$Remove)
    if ($PSCmdlet.ParameterSetName -eq 'remove') {
        if (-not $Index.Slots.ContainsKey($Remove)) { return }
        # 삭제도 같은 한 칸 갱신 경로를 거친다. 실제 원자료는 바꾸지 않는다.
        Set-WtMemoIndexEntry $Index @([pscustomobject]@{ id = $Remove; deleted = $true })
    } else {
        # 옛 판은 id를 글로 읽어 기존 칸을 먼저 빼고, 문자열 id가 아닌 새 줄은 넣지 않는다.
        $rawId = Get-WtField $Memo 'id'
        if ($rawId -isnot [string]) {
            $id = [string]$rawId
            if ($Index.Slots.ContainsKey($id)) { Set-WtMemoIndexEntry $Index @([pscustomobject]@{ id = $id; deleted = $true }) }
            return
        }
        Set-WtMemoIndexEntry $Index @($Memo)
    }
}

function Get-WtMemoQueryTerms($Node, [switch]$Negated) {
    if ($Node.Kind -eq 'term') { if (-not $Negated) { $Node }; return }
    if ($Node.Kind -eq 'not') { Get-WtMemoQueryTerms $Node.Child -Negated:(-not $Negated); return }
    foreach ($child in @($Node.Children)) { if ($child) { Get-WtMemoQueryTerms $child -Negated:$Negated } }
}

# 한 검색 안에서 조건 판정과 순위/문맥 계산이 같은 위치 배열을 쓴다.
function Get-WtMemoTextPositions($Index, [string]$Field, [string]$Needle, $Positions) {
    $key = $Field + ':' + $Needle
    if ($Positions.ContainsKey($key)) { return , $Positions[$key] }
    [string[]]$texts = if ($Field -eq 'title') { $Index.Columns.TitleLower.ToArray() } else { $Index.Columns.BodyLower.ToArray() }
    $found = $script:memoPositionsFactory.Invoke($texts, $Needle)
    $Positions[$key] = $found
    , $found
}

# 재귀는 조건 트리의 노드마다 한 번. 메모 반복문에는 함수/파이프라인/스크립트 블록이 없다.
# Candidate는 상위 AND에서 살아 있는 번호만 담는다. NOT도 그 범위 안에서 뒤집는다.
function Get-WtMemoMatchSet($Index, $Node, [datetime]$Today, [bool[]]$Candidate, $Positions) {
    $c = $Index.Columns; $count = $c.Id.Count
    $mask = [bool[]]::new($count)
    switch ($Node.Kind) {
        'all' { return , $Candidate.Clone() }
        'not' {
            $part = Get-WtMemoMatchSet $Index $Node.Child $Today $Candidate $Positions
            return , $script:memoMaskFactories.not.Invoke([object[]]@($Candidate, $part))
        }
        'and' {
            $mask = $Candidate.Clone()
            # 싼 잎을 먼저 평가한다. 예외가 날 수 있는 linksto끼리의 원래 순서는 보존한다.
            foreach ($pass in 0, 1) {
                foreach ($child in $Node.Children) {
                    $cheap = $child.Kind -eq 'term' -and $child.Field -in 'folder', 'is', 'tag', 'no', 'created', 'updated'
                    if (($pass -eq 0) -ne $cheap) { continue }
                    $mask = Get-WtMemoMatchSet $Index $child $Today $mask $Positions
                }
            }
            return , $mask
        }
        'or' {
            foreach ($child in $Node.Children) {
                $part = Get-WtMemoMatchSet $Index $child $Today $Candidate $Positions
                $mask = $script:memoMaskFactories.or.Invoke([object[]]@($mask, $part))
            }
            return , $mask
        }
    }
    $value = ([string]$Node.Value).ToLowerInvariant(); $field = [string]$Node.Field
    switch ($field) {
        'text' {
            [int[]]$titleAt = Get-WtMemoTextPositions $Index 'title' $value $Positions
            [int[]]$bodyAt = Get-WtMemoTextPositions $Index 'body' $value $Positions
            $mask = $script:memoMaskFactories.text.Invoke([object[]]@($Candidate, $titleAt, $bodyAt))
        }
        'title' {
            [int[]]$titleAt = Get-WtMemoTextPositions $Index 'title' $value $Positions
            $mask = $script:memoMaskFactories.position.Invoke([object[]]@($Candidate, $titleAt))
        }
        'body' {
            [int[]]$bodyAt = Get-WtMemoTextPositions $Index 'body' $value $Positions
            $mask = $script:memoMaskFactories.position.Invoke([object[]]@($Candidate, $bodyAt))
        }
        'tag' {
            [Collections.Generic.HashSet[string][]]$tags = $c.Tags.ToArray()
            $mask = $script:memoMaskFactories.tag.Invoke([object[]]@($Candidate, $tags, $value))
        }
        'no' {
            [Collections.Generic.HashSet[string][]]$tags = $c.Tags.ToArray()
            $mask = $script:memoMaskFactories.no.Invoke([object[]]@($Candidate, $tags))
        }
        'is' {
            [bool[]]$pins = $c.Pinned.ToArray()
            $mask = $script:memoMaskFactories.flag.Invoke([object[]]@($Candidate, $pins))
        }
        'folder' {
            $folderIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($folder in $Index.Folders) {
                if ([string]::Equals([string]$folder.id, [string]$Node.Value, [StringComparison]::Ordinal) -or [string]::Equals([string]$folder.name, $value, [StringComparison]::OrdinalIgnoreCase)) { [void]$folderIds.Add([string]$folder.id) }
            }
            [string[]]$folders = $c.Folder.ToArray()
            $mask = $script:memoMaskFactories.folder.Invoke([object[]]@($Candidate, $folders, $folderIds))
        }
        'has' {
            Initialize-WtMemoLinks $Index
            if ($value -eq 'link') {
                [bool[]]$links = $c.HasLink.ToArray()
                $mask = $script:memoMaskFactories.flag.Invoke([object[]]@($Candidate, $links))
            } else {
                [int[]]$backlinks = $c.BacklinkCount.ToArray()
                $mask = $script:memoMaskFactories.backlink.Invoke([object[]]@($Candidate, $backlinks))
            }
        }
        'linksto' {
            Initialize-WtMemoLinks $Index
            $targetTitle = $value
            if ($Index.Slots.ContainsKey([string]$Node.Value)) { $targetTitle = $c.TitleLower[$Index.Slots[[string]$Node.Value]] }
            if ($Index.Titles.ContainsKey($targetTitle)) {
                if ($Index.Titles[$targetTitle].Count -gt 1) { throw [ArgumentException]::new("같은 제목이 여럿입니다. 메모 id로 대상을 골라 주세요: $($Node.Value)") }
                if ($Index.LinkSources.ContainsKey($targetTitle)) {
                    foreach ($id in $Index.LinkSources[$targetTitle]) { $n = $Index.Slots[$id]; $mask[$n] = $Candidate[$n] }
                }
            }
        }
        { $_ -in 'updated', 'created' } {
            $from = $null; $to = $null; $compare = ''
            $relative = $script:memoRelativeDays.Match($value)
            if ($relative.Success) { $from = $Today.AddDays(1 - [int]$relative.Groups[1].Value); $to = $Today }
            elseif ($value.StartsWith('<') -or $value.StartsWith('>')) { $compare = $value.Substring(0, 1); $from = ConvertFrom-WtDateText $value.Substring(1) }
            else {
                $parts = $script:memoDateRange.Split($value); $from = ConvertFrom-WtDateText $parts[0]
                $to = if ($parts.Count -eq 2) { ConvertFrom-WtDateText $parts[1] } else { $from }
            }
            $fromTicks = $from.Ticks; $toTicks = if ($null -ne $to) { $to.Ticks } else { 0L }
            [long[]]$days = if ($field -eq 'updated') { $c.UpdatedDay.ToArray() } else { $c.CreatedDay.ToArray() }
            if ($compare -eq '<') {
                $mask = $script:memoMaskFactories.before.Invoke([object[]]@($Candidate, $days, $fromTicks))
            } elseif ($compare -eq '>') {
                $mask = $script:memoMaskFactories.after.Invoke([object[]]@($Candidate, $days, $fromTicks))
            } else {
                $mask = $script:memoMaskFactories.range.Invoke([object[]]@($Candidate, $days, $fromTicks, $toTicks))
            }
        }
    }
    , $mask
}

function Get-WtMemoOpenedMap($State, $Index) {
    $map = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    if ($null -eq $State) { return , $map }
    $isMap = $State -is [Collections.IDictionary]
    $hasItems = $isMap -and (@($State.Keys) -ccontains 'items') -and $State['items'] -is [array]
    $items = if ($hasItems) { $State['items'] } elseif ($State.PSObject.Properties['Items']) { $State.Items } else { $State }
    if ($isMap -and -not $hasItems) {
        foreach ($key in $State.Keys) { if ($Index.Slots.ContainsKey([string]$key)) { $map[[string]$key] = $State[$key] } }
    } else {
        foreach ($item in @($items)) { if ($item.id -and $Index.Slots.ContainsKey([string]$item.id) -and -not $map.ContainsKey([string]$item.id)) { $map[[string]$item.id] = $item.opened } }
    }
    , $map
}

# 같은 색인의 기본 정렬은 메모 번호 배열만 재사용한다. 결과 객체나 본문 일부는 캐시하지 않는다.
function Get-WtMemoSortOrder($Index, [string]$Sort, [string]$Dir, [long[]]$OpenedTicks) {
    $key = $Sort + '/' + $Dir
    if ($Sort -ne 'opened' -and $Index.SortOrders.ContainsKey($key)) { return , $Index.SortOrders[$key] }
    $c = $Index.Columns
    [bool[]]$alive = $c.Alive.ToArray()
    $allSlots = [Linq.Enumerable]::ToArray[int]([Linq.Enumerable]::Range(0, $alive.Length))
    $items = $script:memoSelectFactory.Invoke($allSlots, $alive, [int[]]::new(0), $false)
    [long[]]$primaryValues = $null
    switch ($Sort) {
        'title' { $primaryValues = $c.TitleOrdinal.ToArray() }
        'backlinks' { $primaryValues = $c.BacklinkCount.ToArray() }
        'updated' { $primaryValues = $c.UpdatedTicks.ToArray() }
        'created' { $primaryValues = $c.CreatedTicks.ToArray() }
        'opened' { $primaryValues = $OpenedTicks }
        default { $primaryValues = [long[]]::new($alive.Length) }
    }
    $sortColumns = [object[]]@($c.Pinned.ToArray(), $c.PinOrder.ToArray(), $c.UpdatedTicks.ToArray(),
        $c.TitleOrdinal.ToArray(), $c.IdOrdinal.ToArray(), $primaryValues, ($Dir -eq 'desc'), $items)
    $keys = $script:memoSortFactory.Invoke($sortColumns)
    if ($items.Length -gt 1) { [Array]::Sort($keys, $items) }
    if ($Sort -ne 'opened') { $Index.SortOrders[$key] = $items }
    , $items
}

function Get-WtMemoOrderPage([int[]]$Order, [int]$Skip, [int]$Take) {
    $count = [Math]::Max(0, [Math]::Min($Take, $Order.Length - $Skip))
    $page = [int[]]::new($count)
    if ($count) { [Array]::Copy($Order, $Skip, $page, 0, $count) }
    , $page
}

# -First로 앞만 만든 결과의 다음 줄을 만든다. 화면에 보일 줄만 만들어 긴 목록에서도 입력이 멈칫하지 않는다.
function Get-WtMemoResultRows {
    param([Parameter(Mandatory)]$Result, [int]$Skip = 0, [int]$First = 40)
    $script:memoRowsFactory.Invoke($Result.Columns, (Get-WtMemoOrderPage $Result.Order $Skip $First), [int]::MaxValue)
}

# 빈 색인에 메모를 조금씩 넣는다. 처음 열 때 화면을 막지 않으려고 쓴다.
function Add-WtMemoIndexEntries {
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Memos)
    Set-WtMemoIndexEntry $Index $Memos
    $Index.OrderDirty = $true
}

function Find-WtMemo {
    param([Parameter(Mandatory)]$Index, $Query = '', [ValidateSet('updated', 'created', 'title', 'opened', 'backlinks')][string]$Sort,
        [ValidateSet('asc', 'desc')][string]$Dir, [ValidateSet('normal', 'pinned', 'recent', 'archived', 'all', '일반', '고정', '최근 열기', '보관', '모두')][string]$View = 'normal', $OpenedMap,
        [ValidateRange(0, [int]::MaxValue)][int]$SnippetLimit = 200, [ValidateRange(0, [int]::MaxValue)][int]$First = [int]::MaxValue,
        [switch]$SkipBacklinks)
    $tree = if ($Query -is [string]) { ConvertFrom-WtMemoQuery $Query } else { $Query }
    if ($tree.Success -eq $false) { return [pscustomobject]@{ Success = $false; Items = @(); Count = 0; Error = $tree.Error } }
    try {
        if ($Query -isnot [string]) { $tree = ConvertFrom-WtMemoQuery (ConvertTo-WtMemoQuery $tree) }
        $scope = $tree.Scope
        if ($scope -eq 'active') {
            if ($View -in 'archived', '보관') { $scope = 'archived' } elseif ($View -in 'all', '모두') { $scope = 'all' }
        }
        $c = $Index.Columns; $count = $c.Id.Count
        $opened = Get-WtMemoOpenedMap $OpenedMap $Index
        $candidate = [bool[]]::new($count)
        [bool[]]$pins = $c.Pinned.ToArray(); [bool[]]$archives = $c.Archived.ToArray(); [bool[]]$alive = $c.Alive.ToArray(); [string[]]$ids = $c.Id.ToArray()
        $pinnedOnly = $View -in 'pinned', '고정'; $recentOnly = $View -in 'recent', '최근 열기'
        for ($n = 0; $n -lt $count; $n++) {
            $candidate[$n] = $alive[$n] -and ($scope -ne 'active' -or -not $archives[$n]) -and ($scope -ne 'archived' -or $archives[$n]) -and
                (-not $pinnedOnly -or $pins[$n]) -and (-not $recentOnly -or $opened.ContainsKey($ids[$n]))
        }
        $positions = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $mask = Get-WtMemoMatchSet $Index $tree.Root ([datetime]::Today) $candidate $positions
        if ($Index.OrderDirty) { Update-WtMemoIndexOrder $Index }
        # Backlinks는 기존 결과의 공개 칸이다. 연결 조건이 없어도 실제 값을 반환해야 하므로 첫 결과 때 준비한다.
        # 화면 목록은 이 칸을 쓰지 않으므로 -SkipBacklinks로 기다리지 않는다. 메모 3,000개면 준비에 36초가 걸린다
        if (-not $SkipBacklinks -or $Sort -ceq 'backlinks') { Initialize-WtMemoLinks $Index }
        $needles = [Collections.Generic.List[string]]::new(); $termFields = [Collections.Generic.List[string]]::new(); $words = [Collections.Generic.List[string]]::new()
        foreach ($term in (Get-WtMemoQueryTerms $tree.Root)) {
            if ($term.Field -in 'text', 'title', 'body') {
                $needles.Add(([string]$term.Value).ToLowerInvariant()); $words.Add([string]$term.Value); $termFields.Add([string]$term.Field)
            }
        }
        $joined = [string]::Join(' ', $words); $termCount = $needles.Count
        if (-not $Sort -and $recentOnly) { $Sort = 'opened' }
        if ($Sort -and -not $Dir) { $Dir = if ($Sort -eq 'title') { 'asc' } else { 'desc' } }
        $openedTimes = [object[]]::new($count); $openedTicks = [long[]]::new($count)
        [Array]::Fill[long]($openedTicks, -1L)
        foreach ($id in $opened.Keys) {
            $text = [string]$opened[$id]
            if (-not $Index.TimeCache.ContainsKey($text)) {
                $at = [DateTimeOffset]::MinValue
                $valid = [DateTimeOffset]::TryParseExact($text, "yyyy-MM-dd'T'HH:mm:sszzz", $script:memoInv, [Globalization.DateTimeStyles]::None, [ref]$at)
                $Index.TimeCache[$text] = if ($valid) { $at } else { Get-WtMemoIndexedTime $text }
            }
            $stamp = $Index.TimeCache[$text]; $n = $Index.Slots[$id]; $openedTimes[$n] = $stamp
            if ($null -ne $stamp) { $openedTicks[$n] = $stamp.UtcTicks }
        }
        $baseOrder = Get-WtMemoSortOrder $Index $Sort $Dir $openedTicks
        $ranks = [int[]]::new($count); $starts = [int[]]::new($count); $locations = [object[]]::new($count)
        [string[]]$tl = $c.TitleLower.ToArray(); [string[]]$bl = $c.BodyLower.ToArray(); [string[]]$titleText = $c.Title.ToArray()
        if ($termCount) {
            [string[]]$needleArray = $needles.ToArray(); [string[]]$fieldArray = $termFields.ToArray()
            $titlePositions = [int[][]]::new($termCount); $bodyPositions = [int[][]]::new($termCount)
            for ($t = 0; $t -lt $termCount; $t++) {
                if ($fieldArray[$t] -ne 'body') { $titlePositions[$t] = Get-WtMemoTextPositions $Index 'title' $needleArray[$t] $positions }
                if ($fieldArray[$t] -ne 'title') { $bodyPositions[$t] = Get-WtMemoTextPositions $Index 'body' $needleArray[$t] $positions }
            }
            $rankColumns = [object[]]@($tl, $titleText, $needleArray, $titlePositions, $bodyPositions, $mask, $joined)
            $rankResult = $script:memoRanksFactory.Invoke($rankColumns)
            $ranks = $rankResult[0]; $starts = $rankResult[1]; $locations = $rankResult[2]
        } else {
            [Array]::Fill[int]($ranks, 3); [Array]::Fill[object]($locations, [object[]]::new(0))
        }
        $items = $script:memoSelectFactory.Invoke($baseOrder, $mask, $ranks, ($termCount -gt 0 -and -not $Sort)); $length = $items.Length
        $folderMap = [Collections.Generic.Dictionary[string, string[]]]::new([StringComparer]::Ordinal)
        foreach ($folder in $Index.Folders) {
            if (-not $folderMap.ContainsKey([string]$folder.id)) {
                $folderValue = [string[]]::new(2); $folderValue[1] = '폴더 없음'
                if ($folder) { $folderValue[0] = [string]$folder.id; $folderValue[1] = [string]$folder.name }
                $folderMap[[string]$folder.id] = $folderValue
            }
        }
        $rowColumns = [object[]]@($ids, $titleText, $locations, $c.Body.ToArray(), $starts, $c.Folder.ToArray(), $folderMap,
            [Collections.Generic.HashSet[string][]]$c.Tags.ToArray(), $pins, $c.PinOrder.ToArray(), $archives, $ranks, $c.Updated.ToArray(), $c.Created.ToArray(), $openedTimes, $c.BacklinkCount.ToArray())
        $page = $items   # if 식으로 받으면 빈 배열이 $null로 풀린다
        if ($First -lt $length) { $page = Get-WtMemoOrderPage $items 0 $First }
        $rows = $script:memoRowsFactory.Invoke($rowColumns, $page, $SnippetLimit)
        [pscustomobject]@{ Success = $true; Items = $rows; Count = $length; Error = $null; Order = $items; Columns = $rowColumns }
    } catch {
        [pscustomobject]@{ Success = $false; Items = @(); Count = 0; Error = [pscustomobject]@{ Position = 0; Length = 0; Reason = $_.Exception.Message } }
    }
}

# ---- 저장: 공통 핸들 · 깊은 복사 · 모르는 칸/키/깨진 줄 보존 ---------------------------------
function Open-WtMemoStore { Open-WtStore -Name 'memo' -Schema 1 }

function Save-WtMemoStoreItems($Store, [object[]]$Items, [hashtable]$Extra) {
    if ($Store.Name -cne 'memo') { throw '메모 저장소 핸들이 아닙니다.' }
    $compact = $Items.Clone()
    foreach ($i in $script:memoDeletedSlotsFactory.Invoke($Items)) { $compact[$i] = @(Compress-WtDeletedItems (, $Items[$i]))[0] }
    Save-WtStore $Store $compact -Extra $Extra -Background:($compact.Count -ge 256)
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
    $edit = Get-WtMemoRecordEdit $Store $Id
    if (-not $edit.Success) { throw $edit.Reason }
    if (Test-WtDeleted $edit.Item) { throw '지운 메모는 정리할 수 없습니다.' }
    $edit
}

# 정리 기능은 스칼라 칸만 바꾼다. 중첩된 모르는 칸은 공유하되 절대 고치지 않는다.
function Copy-WtMemoFields($Item) {
    if ($Item -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($name in $Item.Keys) { $copy[$name] = $Item[$name] }
        return [pscustomobject]$copy
    }
    $Item.PSObject.Copy()
}

# 목록의 참조와 실제로 고칠 한 항목의 속성만 복사한다.
function Get-WtMemoRecordEdit($Store, [string]$Id) {
    if ($Store.State -notin 'ok', 'missing') { throw "$($Store.Name).json은 읽지 못해서 저장하지 않습니다. ($($Store.Error))" }
    $r = [pscustomobject]@{ Success = $false; Reason = ''; Items = $Store.Items.Clone(); Index = -1; Item = $null }
    if (-not $Id) { $r.Success = $true; return $r }
    for ($i = 0; $i -lt $r.Items.Count; $i++) {
        $item = $r.Items[$i]
        if ($null -ne $item -and $item -isnot [string] -and $item -isnot [ValueType] -and $item -isnot [array] -and [string]$item.id -ceq $Id) {
            if ($r.Index -ge 0) { $r.Reason = 'id가 겹쳐 편집할 줄을 정할 수 없습니다'; return $r }
            $r.Index = $i
        }
    }
    if ($r.Index -lt 0) { $r.Reason = '항목을 찾지 못했습니다'; return $r }
    $r.Item = Copy-WtMemoFields $r.Items[$r.Index]
    $r.Items[$r.Index] = $r.Item
    $r.Success = $true
    $r
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
    $items = $Store.Items.Clone()
    for ($i = 0; $i -lt $items.Count; $i++) {
        $item = $items[$i]
        if ($null -ne $item -and $item -isnot [array] -and $item -isnot [string] -and $item -isnot [ValueType] -and $removed.Contains([string]$item.folder)) {
            $item = Copy-WtMemoFields $item; $items[$i] = $item
            Set-WtField $item 'folder' $null; Set-WtItemEdited $item (Get-WtMemoDataStamp)
        }
    }
    $saved = Save-WtMemoStoreItems $Store $items -Extra @{ folders = $list.ToArray() }
    # Save-WtStore의 Doc는 열 때의 문서다. 새 핸들에만 Extra를 반영한다(옛 핸들은 그대로).
    $saved.Doc = if ($Store.Doc) { $Store.Doc.PSObject.Copy() } else { [pscustomobject]@{} }
    Set-WtField $saved.Doc 'folders' $list.ToArray()
    $saved
}

# 기존 화면이 넘기는 활성 목록을 원자료에 맞춘다. 화면 밖의 깨진 줄/지운 줄은 유지한다.
function Save-WtMemoDataItems {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items, [hashtable]$Extra)
    if ($Store.State -notin 'ok', 'missing') { throw $Store.Error }
    $plan = $script:memoSaveFactory.Invoke($Store.Items, $Items)
    foreach ($i in $plan.Changed) {
        $old = $plan.Olds[$i]
        if ($null -ne $old) {
            $item = $Items[$i]
            # 형식이 깨진 rev도 기존 PowerShell 비교 규칙을 그대로 따른다.
            $same = $old.rev -eq $item.rev -and [string]$old.updated -ceq [string]$item.updated -and
                [string]$old.title -ceq [string]$item.title -and [string]$old.body -ceq [string]$item.body
            if ($same -and -not (Test-WtDeleted $old)) { $copy = $old }
            else {
                $copy = Copy-WtItem $old
                Merge-WtRecordPatch $copy $item
                if (Test-WtDeleted $old) { Set-WtField $copy 'deleted' $null; Set-WtItemEdited $copy (Get-WtMemoDataStamp) }
            }
        } else { $copy = Copy-WtItem $Items[$i] }
        $plan.Next[$plan.Targets[$i]] = $copy
    }
    foreach ($i in $plan.Deleted) {
        $copy = Copy-WtMemoFields $plan.Next[$i]; $now = Get-WtMemoDataStamp
        Set-WtField $copy 'deleted' $now; Set-WtItemEdited $copy $now
        $plan.Next[$i] = $copy
    }
    Save-WtMemoStoreItems $Store $plan.Next -Extra $Extra
}

# 열람 기록은 메모를 고치지 않는다. Get-WtMemoEditable은 메모 전체를 JSON으로 복사하므로 여기서 쓰면 메모를 열 때마다 화면이 멈춘다
function Assert-WtMemoOpenable($Store, [string]$Id) {
    if ($Store.State -notin 'ok', 'missing') { throw $Store.Error }
    $found = $null
    foreach ($item in $Store.Items) {
        if ([string]$item.id -cne $Id -or -not (Test-WtRecordObject $item)) { continue }
        if ($null -ne $found) { throw 'id가 겹쳐 편집할 줄을 정할 수 없습니다' }
        $found = $item
    }
    if ($null -eq $found) { throw '항목을 찾지 못했습니다' }
    if (Test-WtDeleted $found) { throw '지운 메모는 정리할 수 없습니다.' }
}

function Set-WtMemoOpened {
    param([Parameter(Mandatory)][string]$Id, $Store = (Open-WtStore -Name 'memo-state' -Schema 1),
        $MemoStore = (Open-WtMemoStore), [string]$At = (Get-WtMemoDataStamp))
    Assert-WtMemoOpenable $MemoStore $Id
    $now = ConvertFrom-WtStamp $At
    if (-not $now) { throw '열람 시각이 앱 시각 모양이 아닙니다.' }
    if ($Store.State -notin 'ok', 'missing') { throw $Store.Error }
    $edit = Get-WtMemoRecordEdit $Store $Id
    if (-not $edit.Success -and $edit.Reason -ne '항목을 찾지 못했습니다') { throw $edit.Reason }
    if ($edit.Success) {
        $before = ConvertFrom-WtStamp ([string](Get-WtField $edit.Item 'opened'))
        if ($before -and ($now - $before).TotalSeconds -ge 0 -and ($now - $before).TotalSeconds -lt 60) { return $Store }
        Set-WtField $edit.Item 'opened' ($now.ToOffset([timespan]::FromHours(9)).ToString("yyyy-MM-dd'T'HH:mm:sszzz", $script:memoInv))
    } else { $edit.Items += [pscustomobject]@{ id = $Id; opened = (Get-WtMemoDataStamp $now) } }
    Save-WtStore $Store $edit.Items -Background:($edit.Items.Count -ge 256)
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

function Initialize-WtMemoWorker($Context) {
    foreach ($name in $Context.Keys) { $ExecutionContext.SessionState.PSVariable.Set("script:$name", $Context[$name]) }
}

# 화면에서 메모 수만큼 반복하는 속성 조회/행 생성은 기존 검색 엔진과 같은 기본 .NET 식 트리로 묶는다.
function New-WtMemoFieldExpression($Object, [string]$Name, [switch]$String) {
    $e = [Linq.Expressions.Expression]
    $ps = $e::Call([Management.Automation.PSObject].GetMethod('AsPSObject', [type[]]@([object])), [Linq.Expressions.Expression[]]@($Object))
    $base = $e::Property($ps, 'BaseObject')
    $properties = $e::Property($ps, 'Properties')
    $property = $e::Call($properties, [Management.Automation.PSMemberInfoCollection[Management.Automation.PSPropertyInfo]].GetMethod('get_Item', [type[]]@([string])), [Linq.Expressions.Expression[]]@($e::Constant($Name)))
    $none = $e::Constant($null, [object])
    $value = $e::Condition($e::Equal($property, $e::Constant($null, [Management.Automation.PSPropertyInfo])), $none, $e::Property($property, 'Value'))
    $value = $e::Condition($e::TypeIs($base, [Collections.IDictionary]),
        $e::Call($e::Convert($base, [Collections.IDictionary]), [Collections.IDictionary].GetMethod('get_Item'), [Linq.Expressions.Expression[]]@($e::Constant($Name, [object]))), $value)
    $value = $e::Condition($e::Equal($Object, $none), $none, $value)
    if ($String) {
        return $e::Coalesce($e::Convert($e::Call([Management.Automation.LanguagePrimitives].GetMethod('ConvertTo', [type[]]@([object], [type])),
            [Linq.Expressions.Expression[]]@($value, $e::Constant([string], [type]))), [string]), $e::Constant(''))
    }
    $value
}

function Initialize-WtMemoViewFactories {
    $e = [Linq.Expressions.Expression]
    $memoArg = $e::Parameter([object], 'memo')
    $script:memoUpdatedKeyFactory = $e::Lambda([Func[object, string]], (New-WtMemoFieldExpression $memoArg 'updated' -String), [Linq.Expressions.ParameterExpression[]]@($memoArg)).Compile()
    $flagEquals = [Management.Automation.LanguagePrimitives].GetMethod('Equals', [type[]]@([object], [object], [bool]))
    $pinFlag = $e::Call($flagEquals, [Linq.Expressions.Expression[]]@((New-WtMemoFieldExpression $memoArg 'pinned'), $e::Constant($true, [object]), $e::Constant($true)))
    $archiveFlag = $e::Call($flagEquals, [Linq.Expressions.Expression[]]@((New-WtMemoFieldExpression $memoArg 'archived'), $e::Constant($true, [object]), $e::Constant($true)))
    $script:memoPinnedFactory = $e::Lambda([Func[object, bool]], $pinFlag, [Linq.Expressions.ParameterExpression[]]@($memoArg)).Compile()
    $script:memoActiveFactory = $e::Lambda([Func[object, bool]], $e::Not($archiveFlag), [Linq.Expressions.ParameterExpression[]]@($memoArg)).Compile()
    $inputArg = $e::Parameter([object[]], 'items'); $i = $e::Variable([int], 'i')
    $item = $e::ArrayIndex($inputArg, $i)
    $script:memoIdFactory = New-WtMemoArrayFactory ([string]) $inputArg $i ($e::ArrayLength($inputArg)) (New-WtMemoFieldExpression $item 'id' -String)
    $asObject = $e::Call([Management.Automation.PSObject].GetMethod('AsPSObject', [type[]]@([object])), [Linq.Expressions.Expression[]]@($item))
    $script:memoDetachedFactory = New-WtMemoArrayFactory ([object]) $inputArg $i ($e::ArrayLength($inputArg)) ($e::Convert($e::Call($asObject, [Management.Automation.PSObject].GetMethod('Copy', [type[]]@())), [object]))
    $dictType = [Collections.Generic.Dictionary[string, object]]
    $byId = $e::Variable($dictType, 'ids'); $byTitle = $e::Variable($dictType, 'titles')
    $titleList = $e::Variable([Collections.Generic.List[string]], 'names')
    $id = $e::Variable([string], 'id'); $title = $e::Variable([string], 'title'); $trimmed = $e::Variable([string], 'trimmed')
    $dictNew = $script:memoNewExpression.Invoke($dictType.GetConstructor([type[]]@([Collections.Generic.IEqualityComparer[string]])),
        [Linq.Expressions.Expression[]]@($e::Constant([StringComparer]::InvariantCultureIgnoreCase, [Collections.Generic.IEqualityComparer[string]])))
    $step = $e::Block([Linq.Expressions.Expression[]]@(
        $e::Assign($id, (New-WtMemoFieldExpression $item 'id' -String)),
        $e::Assign($title, (New-WtMemoFieldExpression $item 'title' -String)),
        $e::Assign($trimmed, $e::Call($title, [string].GetMethod('Trim', [type[]]@()))),
        $e::IfThen($e::Not($e::Call($byId, $dictType.GetMethod('ContainsKey'), [Linq.Expressions.Expression[]]@($id))),
            $e::Call($byId, $dictType.GetMethod('Add'), [Linq.Expressions.Expression[]]@($id, $item))),
        $e::IfThen($e::Not($e::Call($byTitle, $dictType.GetMethod('ContainsKey'), [Linq.Expressions.Expression[]]@($trimmed))),
            $e::Call($byTitle, $dictType.GetMethod('Add'), [Linq.Expressions.Expression[]]@($trimmed, $item))),
        $e::IfThen($e::GreaterThan($e::Property($title, 'Length'), $e::Constant(0)),
            $e::Call($titleList, [Collections.Generic.List[string]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($title)))))
    $body = $e::Block([Linq.Expressions.ParameterExpression[]]@($i, $id, $title, $trimmed, $byId, $byTitle, $titleList), [Linq.Expressions.Expression[]]@(
        $e::Assign($byId, $dictNew), $e::Assign($byTitle, $dictNew),
        $e::Assign($titleList, $script:memoNewExpression.Invoke([Collections.Generic.List[string]].GetConstructor([type[]]@()), [Linq.Expressions.Expression[]]@())),
        (New-WtMemoLoopExpression $i ($e::ArrayLength($inputArg)) $step),
        $e::NewArrayInit([object], [Linq.Expressions.Expression[]]@($byId, $byTitle, $e::Call($titleList, [Collections.Generic.List[string]].GetMethod('ToArray'))))))
    $script:memoLookupFactory = $e::Lambda([Func[object[], object[]]], $body, [Linq.Expressions.ParameterExpression[]]@($inputArg)).Compile()

    $seen = $e::Variable([Collections.Generic.HashSet[string]], 'seen'); $live = $e::Variable([Collections.Generic.List[object]], 'live')
    $rawId = $e::Variable([object], 'rawId')
    $validId = $e::AndAlso($e::TypeIs($rawId, [string]), $e::GreaterThan($e::Property($e::Convert($rawId, [string]), 'Length'), $e::Constant(0)))
    $take = $e::AndAlso($validId, $e::AndAlso($e::Call($seen, [Collections.Generic.HashSet[string]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($e::Convert($rawId, [string]))), $e::Not((New-WtMemoDeletedExpression $item))))
    $body = $e::Block([Linq.Expressions.ParameterExpression[]]@($i, $seen, $live, $rawId), [Linq.Expressions.Expression[]]@(
        $e::Assign($seen, $script:memoNewExpression.Invoke([Collections.Generic.HashSet[string]].GetConstructor([type[]]@([Collections.Generic.IEqualityComparer[string]])), [Linq.Expressions.Expression[]]@($e::Constant([StringComparer]::Ordinal, [Collections.Generic.IEqualityComparer[string]])))),
        $e::Assign($live, $script:memoNewExpression.Invoke([Collections.Generic.List[object]].GetConstructor([type[]]@()), [Linq.Expressions.Expression[]]@())),
        (New-WtMemoLoopExpression $i ($e::ArrayLength($inputArg)) ($e::Block([Linq.Expressions.Expression[]]@(
            $e::Assign($rawId, (New-WtMemoFieldExpression $item 'id')),
            $e::IfThen($take, $e::Call($live, [Collections.Generic.List[object]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($item))))))),
        $e::Call($live, [Collections.Generic.List[object]].GetMethod('ToArray'))))
    $script:memoLiveFactory = $e::Lambda([Func[object[], object[]]], $body, [Linq.Expressions.ParameterExpression[]]@($inputArg)).Compile()
    $slots = $e::Variable([Collections.Generic.List[int]], 'slots')
    $body = $e::Block([Linq.Expressions.ParameterExpression[]]@($i, $slots), [Linq.Expressions.Expression[]]@(
        $e::Assign($slots, $script:memoNewExpression.Invoke([Collections.Generic.List[int]].GetConstructor([type[]]@()), [Linq.Expressions.Expression[]]@())),
        (New-WtMemoLoopExpression $i ($e::ArrayLength($inputArg)) ($e::IfThen((New-WtMemoDeletedExpression $item), $e::Call($slots, [Collections.Generic.List[int]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($i))))),
        $e::Call($slots, [Collections.Generic.List[int]].GetMethod('ToArray'))))
    $script:memoDeletedSlotsFactory = $e::Lambda([Func[object[], int[]]], $body, [Linq.Expressions.ParameterExpression[]]@($inputArg)).Compile()

    # 행의 날짜와 미리보기는 표시될 때 기존 함수를 그대로 부른다. 먼 메모까지의 행은 컨트롤 없이 한 번에 만든다.
    $cache = $e::Parameter([Collections.IDictionary], 'cache'); $getters = $e::Parameter([Management.Automation.ScriptBlock[]], 'getters')
    $reuse = $e::Parameter([bool], 'reuse')
    $row = $e::Variable([Management.Automation.PSObject], 'row')
    $rows = $e::Variable([object[]], 'rows')
    $cached = $e::Variable([object], 'cached')
    # 원자료와 검색 결과의 본문 칸 이름만 다르다. 두 대리자로 만들어 행 안에서는 분기하지 않는다.
    $script:memoViewRowFactories = @{}
    foreach ($bodyField in 'body', 'Snippet') {
        $pin = New-WtMemoFieldExpression $item 'pinned'
        $pinned = $e::Call([Management.Automation.LanguagePrimitives].GetMethod('Equals', [type[]]@([object], [object], [bool])),
            [Linq.Expressions.Expression[]]@($pin, $e::Constant($true, [object]), $e::Constant($true)))
        $values = @((New-WtMemoFieldExpression $item 'id' -String), (New-WtMemoFieldExpression $item 'title' -String),
            (New-WtMemoFieldExpression $item 'updated' -String), $e::Constant($null, [object]),
            (New-WtMemoFieldExpression $item $bodyField -String), $e::Constant($null, [object]),
            $e::Condition($pinned, $e::Constant('Visible'), $e::Constant('Collapsed')), $e::Property($null, [datetime].GetProperty('Today')))
        $newRow = New-WtMemoObjectExpression @('Id', 'Title', 'Updated', 'StampValue', 'SnippetSource', 'SnippetValue', 'PinShown', 'Day') $values
        $steps = [Collections.Generic.List[Linq.Expressions.Expression]]::new()
        $steps.Add($e::Assign($row, $e::Convert($newRow, [Management.Automation.PSObject])))
        $propCtor = [Management.Automation.PSScriptProperty].GetConstructor([type[]]@([string], [Management.Automation.ScriptBlock]))
        $add = [Management.Automation.PSMemberInfoCollection[Management.Automation.PSPropertyInfo]].GetMethod('Add', [type[]]@([Management.Automation.PSPropertyInfo], [bool]))
        $j = 0
        foreach ($name in 'Stamp', 'Snippet', 'Sub') {
            $prop = $script:memoNewExpression.Invoke($propCtor, [Linq.Expressions.Expression[]]@($e::Constant($name), $e::ArrayIndex($getters, $e::Constant($j))))
            $steps.Add($e::Call($e::Property($row, 'Properties'), $add, [Linq.Expressions.Expression[]]@($prop, $e::Constant($true))))
            $j++
        }
        $rowObject = $e::Convert($row, [object])
        $key = $e::Convert($values[0], [object])
        $same = $e::NotEqual($cached, $e::Constant($null, [object]))
        foreach ($pair in @(@('Title', 1), @('Updated', 2), @('SnippetSource', 4), @('PinShown', 6))) {
            $same = $e::AndAlso($same, $e::Call([string].GetMethod('Equals', [type[]]@([string], [string], [StringComparison])),
                [Linq.Expressions.Expression[]]@((New-WtMemoFieldExpression $cached $pair[0] -String), $values[$pair[1]], $e::Constant([StringComparison]::Ordinal))))
        }
        $same = $e::AndAlso($same, $e::Call([Management.Automation.LanguagePrimitives].GetMethod('Equals', [type[]]@([object], [object])),
            [Linq.Expressions.Expression[]]@((New-WtMemoFieldExpression $cached 'Day'), $e::Convert($values[7], [object]))))
        $same = $e::AndAlso($e::NotEqual($cached, $e::Constant($null, [object])), $e::OrElse($reuse, $same))
        $steps.Add($e::Call($cache, [Collections.IDictionary].GetMethod('set_Item'), [Linq.Expressions.Expression[]]@($key, $rowObject)))
        $steps.Add($e::Assign($e::ArrayAccess($rows, [Linq.Expressions.Expression[]]@($i)), $rowObject))
        $rowStep = $e::Block([Linq.Expressions.Expression[]]@(
            $e::Assign($cached, $e::Call($cache, [Collections.IDictionary].GetMethod('get_Item'), [Linq.Expressions.Expression[]]@($key))),
            $e::IfThenElse($same, $e::Assign($e::ArrayAccess($rows, [Linq.Expressions.Expression[]]@($i)), $cached), $e::Block($steps))))
        $body = $e::Block([Linq.Expressions.ParameterExpression[]]@($i, $row, $rows, $cached), [Linq.Expressions.Expression[]]@(
            $e::Assign($rows, $e::NewArrayBounds([object], [Linq.Expressions.Expression[]]@($e::ArrayLength($inputArg)))),
            (New-WtMemoLoopExpression $i ($e::ArrayLength($inputArg)) $rowStep), $rows))
        $script:memoViewRowFactories[$bodyField] = $e::Lambda([Func[object[], Management.Automation.ScriptBlock[], Collections.IDictionary, bool, object[]]], $body, [Linq.Expressions.ParameterExpression[]]@($inputArg, $getters, $cache, $reuse)).Compile()
    }
}

function New-WtMemoDeletedExpression($Object) {
    $e = [Linq.Expressions.Expression]
    $value = New-WtMemoFieldExpression $Object 'deleted'
    $falseBool = $e::AndAlso($e::TypeIs($value, [bool]), $e::Not($e::Convert($value, [bool])))
    $text = New-WtMemoFieldExpression $Object 'deleted' -String
    $e::AndAlso($e::NotEqual($value, $e::Constant($null, [object])), $e::AndAlso($e::Not($falseBool), $e::NotEqual($text, $e::Constant(''))))
}

# 전체 항목은 참조/위치만 .NET에서 맞춘다. 복사·병합·지운 표시는 바뀐 항목에만 기존 함수로 적용한다.
function Initialize-WtMemoSaveFactory {
    $e = [Linq.Expressions.Expression]
    $source = $e::Parameter([object[]], 'source'); $inputArg = $e::Parameter([object[]], 'incomingItems')
    $i = $e::Variable([int], 'i'); $at = $e::Variable([int], 'at')
    $item = $e::Variable([object], 'item'); $old = $e::Variable([object], 'old'); $rawId = $e::Variable([object], 'rawId'); $id = $e::Variable([string], 'id')
    $dictType = [Collections.Generic.Dictionary[string, object]]
    $original = $e::Variable($dictType, 'original'); $incoming = $e::Variable([Collections.Generic.HashSet[string]], 'incoming'); $seen = $e::Variable([Collections.Generic.HashSet[string]], 'seen')
    $active = $e::Variable([object[]], 'active'); $olds = $e::Variable([object[]], 'olds'); $targets = $e::Variable([int[]], 'targets')
    $next = $e::Variable([Collections.Generic.List[object]], 'next'); $changed = $e::Variable([Collections.Generic.List[int]], 'changed'); $deleted = $e::Variable([Collections.Generic.List[int]], 'deleted')
    $comparer = $e::Constant([StringComparer]::Ordinal, [Collections.Generic.IEqualityComparer[string]])
    $newDict = $script:memoNewExpression.Invoke($dictType.GetConstructor([type[]]@([Collections.Generic.IEqualityComparer[string]])), [Linq.Expressions.Expression[]]@($comparer))
    $newSet = $script:memoNewExpression.Invoke([Collections.Generic.HashSet[string]].GetConstructor([type[]]@([Collections.Generic.IEqualityComparer[string]])), [Linq.Expressions.Expression[]]@($comparer))
    $newObjectList = $script:memoNewExpression.Invoke([Collections.Generic.List[object]].GetConstructor([type[]]@()), [Linq.Expressions.Expression[]]@())
    $newIntList = $script:memoNewExpression.Invoke([Collections.Generic.List[int]].GetConstructor([type[]]@()), [Linq.Expressions.Expression[]]@())
    $valid = $e::AndAlso($e::TypeIs($rawId, [string]), $e::GreaterThan($e::Property($e::Convert($rawId, [string]), 'Length'), $e::Constant(0)))
    $readId = $e::Assign($rawId, (New-WtMemoFieldExpression $item 'id'))
    $setId = $e::Assign($id, $e::Convert($rawId, [string]))
    $sourceStep = $e::Block([Linq.Expressions.Expression[]]@(
        $e::Assign($item, $e::ArrayIndex($source, $i)), $readId,
        $e::IfThen($valid, $e::Block([Linq.Expressions.Expression[]]@($setId,
            $e::IfThen($e::Not($e::Call($original, $dictType.GetMethod('ContainsKey'), [Linq.Expressions.Expression[]]@($id))),
                $e::Call($original, $dictType.GetMethod('Add'), [Linq.Expressions.Expression[]]@($id, $item))))))))
    $oldRevision = New-WtMemoFieldExpression $old 'rev'; $newRevision = New-WtMemoFieldExpression $item 'rev'
    $sameFields = $e::AndAlso($e::Not($e::OrElse($e::TypeIs($oldRevision, [array]), $e::TypeIs($newRevision, [array]))),
        $e::Call([Management.Automation.LanguagePrimitives].GetMethod('Equals', [type[]]@([object], [object], [bool])), [Linq.Expressions.Expression[]]@($oldRevision, $newRevision, $e::Constant($true))))
    foreach ($name in 'updated', 'title', 'body') {
        $sameFields = $e::AndAlso($sameFields, $e::Call([string].GetMethod('Equals', [type[]]@([string], [string], [StringComparison])),
            [Linq.Expressions.Expression[]]@((New-WtMemoFieldExpression $old $name -String), (New-WtMemoFieldExpression $item $name -String), $e::Constant([StringComparison]::Ordinal))))
    }
    $same = $e::AndAlso($e::NotEqual($old, $e::Constant($null, [object])), $e::AndAlso(
        $e::OrElse($e::Call([object].GetMethod('ReferenceEquals'), [Linq.Expressions.Expression[]]@($old, $item)), $sameFields),
        $e::Not((New-WtMemoDeletedExpression $old))))
    $bad = $script:memoNewExpression.Invoke([ArgumentException].GetConstructor([type[]]@([string])), [Linq.Expressions.Expression[]]@($e::Constant('저장할 메모 id가 없거나 겹칩니다.')))
    $incomingStep = $e::Block([Linq.Expressions.Expression[]]@(
        $e::Assign($item, $e::ArrayIndex($inputArg, $i)), $readId,
        $e::IfThen($e::Not($valid), $e::Throw($bad)), $setId,
        $e::IfThen($e::Not($e::Call($incoming, [Collections.Generic.HashSet[string]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($id))), $e::Throw($bad)),
        $e::Assign($old, $e::Constant($null, [object])),
        $e::Call($original, $dictType.GetMethod('TryGetValue'), [Linq.Expressions.Expression[]]@($id, $old)),
        $e::Assign($e::ArrayAccess($olds, [Linq.Expressions.Expression[]]@($i)), $old),
        $e::IfThenElse($same,
            $e::Block([Linq.Expressions.Expression[]]@($e::Assign($e::ArrayAccess($active, [Linq.Expressions.Expression[]]@($i)), $old), $e::Empty())),
            $e::Call($changed, [Collections.Generic.List[int]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($i)))))
    $addOld = $e::Call($next, [Collections.Generic.List[object]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($item))
    $addActive = $e::Block([Linq.Expressions.Expression[]]@(
        $e::Assign($e::ArrayAccess($targets, [Linq.Expressions.Expression[]]@($at)), $e::Property($next, 'Count')),
        $e::Call($next, [Collections.Generic.List[object]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($e::ArrayIndex($active, $at))),
        $e::PostIncrementAssign($at), $e::Empty()))
    $nextStep = $e::Block([Linq.Expressions.Expression[]]@(
        $e::Assign($item, $e::ArrayIndex($source, $i)), $readId,
        $e::IfThenElse($valid,
            $e::Block([Linq.Expressions.Expression[]]@($setId,
                $e::IfThenElse($e::Call($seen, [Collections.Generic.HashSet[string]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($id)),
                    $e::IfThenElse($e::Call($incoming, [Collections.Generic.HashSet[string]].GetMethod('Contains'), [Linq.Expressions.Expression[]]@($id)), $addActive,
                        $e::Block([Linq.Expressions.Expression[]]@(
                            $e::IfThen($e::Not((New-WtMemoDeletedExpression $item)), $e::Call($deleted, [Collections.Generic.List[int]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($e::Property($next, 'Count')))), $addOld))), $addOld))), $addOld)))
    $finish = $e::Label()
    $tail = $e::Loop($e::IfThenElse($e::LessThan($at, $e::ArrayLength($inputArg)), $addActive, $e::Break($finish)), $finish)
    $body = $e::Block([Linq.Expressions.ParameterExpression[]]@($i, $at, $item, $old, $rawId, $id, $original, $incoming, $seen, $active, $olds, $targets, $next, $changed, $deleted), [Linq.Expressions.Expression[]]@(
        $e::Assign($original, $newDict), $e::Assign($incoming, $newSet), $e::Assign($seen, $newSet),
        $e::Assign($active, $e::Convert($e::Call($inputArg, [array].GetMethod('Clone')), [object[]])),
        $e::Assign($olds, $e::NewArrayBounds([object], [Linq.Expressions.Expression[]]@($e::ArrayLength($inputArg)))),
        $e::Assign($targets, $e::NewArrayBounds([int], [Linq.Expressions.Expression[]]@($e::ArrayLength($inputArg)))),
        $e::Assign($next, $newObjectList), $e::Assign($changed, $newIntList), $e::Assign($deleted, $newIntList),
        (New-WtMemoLoopExpression $i ($e::ArrayLength($source)) $sourceStep), $e::Assign($i, $e::Constant(0)),
        (New-WtMemoLoopExpression $i ($e::ArrayLength($inputArg)) $incomingStep), $e::Assign($i, $e::Constant(0)),
        (New-WtMemoLoopExpression $i ($e::ArrayLength($source)) $nextStep), $tail,
        (New-WtMemoObjectExpression @('Olds', 'Targets', 'Next', 'Changed', 'Deleted') @($olds, $targets,
            $e::Call($next, [Collections.Generic.List[object]].GetMethod('ToArray')), $e::Call($changed, [Collections.Generic.List[int]].GetMethod('ToArray')), $e::Call($deleted, [Collections.Generic.List[int]].GetMethod('ToArray'))))))
    $script:memoSaveFactory = $e::Lambda([Func[object[], object[], object]], $body, [Linq.Expressions.ParameterExpression[]]@($source, $inputArg)).Compile()
}

function Get-WtMemoLookupData([object[]]$Items) { if ($null -eq $Items) { $Items = [object[]]::new(0) }; , $script:memoLookupFactory.Invoke($Items) }
function Get-WtMemoIdArray([object[]]$Items) { if ($null -eq $Items) { $Items = [object[]]::new(0) }; , $script:memoIdFactory.Invoke($Items) }
function Get-WtMemoDetachedItems([object[]]$Items) { if ($null -eq $Items) { $Items = [object[]]::new(0) }; , $script:memoDetachedFactory.Invoke($Items) }
function Get-WtMemoLiveItems([object[]]$Items) { if ($null -eq $Items) { $Items = [object[]]::new(0) }; , $script:memoLiveFactory.Invoke($Items) }
function Get-WtMemoUpdatedOrder([object[]]$Items) {
    if ($null -eq $Items) { return , [object[]]::new(0) }
    , [Linq.Enumerable]::ToArray[object]([Linq.Enumerable]::OrderByDescending[object, string]($Items, $script:memoUpdatedKeyFactory, [StringComparer]::CurrentCultureIgnoreCase))
}
function Get-WtMemoInitialOrder([object[]]$Items) {
    if ($null -eq $Items) { return , [object[]]::new(0) }
    , [Linq.Enumerable]::ToArray[object]([Linq.Enumerable]::OrderByDescending[object, bool]([Linq.Enumerable]::Where[object]($Items, $script:memoActiveFactory), $script:memoPinnedFactory))
}

function Initialize-WtMemoQuickFactory {
    $e = [Linq.Expressions.Expression]
    $items = $e::Parameter([object[]], 'items'); $patterns = $e::Parameter([Management.Automation.WildcardPattern[]], 'patterns'); $limit = $e::Parameter([int], 'limit')
    $i = $e::Variable([int], 'i'); $j = $e::Variable([int], 'j'); $match = $e::Variable([bool], 'match'); $title = $e::Variable([string], 'title'); $text = $e::Variable([string], 'text')
    $titles = $e::Variable([Collections.Generic.List[object]], 'titles'); $bodies = $e::Variable([Collections.Generic.List[object]], 'bodies')
    $item = $e::ArrayIndex($items, $i)
    $test = $e::Call($e::ArrayIndex($patterns, $j), [Management.Automation.WildcardPattern].GetMethod('IsMatch'), [Linq.Expressions.Expression[]]@($text))
    $check = $e::Block([Linq.Expressions.Expression[]]@(
        $e::Assign($j, $e::Constant(0)), $e::Assign($match, $e::Constant($true)),
        (New-WtMemoLoopExpression $j ($e::ArrayLength($patterns)) ($e::Assign($match, $e::AndAlso($match, $test))))))
    $step = $e::Block([Linq.Expressions.Expression[]]@(
        $e::Assign($title, (New-WtMemoFieldExpression $item 'title' -String)), $e::Assign($text, $title), $check,
        $e::IfThenElse($match,
            $e::Call($titles, [Collections.Generic.List[object]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($item)),
            $e::IfThen($e::LessThan($e::Property($bodies, 'Count'), $limit), $e::Block([Linq.Expressions.Expression[]]@(
                $e::Assign($text, $e::Call([string].GetMethod('Concat', [type[]]@([string], [string], [string])), [Linq.Expressions.Expression[]]@($title, $e::Constant("`n"), (New-WtMemoFieldExpression $item 'body' -String)))),
                $check, $e::IfThen($match, $e::Call($bodies, [Collections.Generic.List[object]].GetMethod('Add'), [Linq.Expressions.Expression[]]@($item))))))),
        $e::PostIncrementAssign($i), $e::Empty()))
    $done = $e::Label()
    $loop = $e::Loop($e::IfThenElse($e::AndAlso($e::LessThan($i, $e::ArrayLength($items)), $e::LessThan($e::Property($titles, 'Count'), $limit)), $step, $e::Break($done)), $done)
    $newList = $script:memoNewExpression.Invoke([Collections.Generic.List[object]].GetConstructor([type[]]@()), [Linq.Expressions.Expression[]]@())
    $body = $e::Block([Linq.Expressions.ParameterExpression[]]@($i, $j, $match, $title, $text, $titles, $bodies), [Linq.Expressions.Expression[]]@(
        $e::Assign($titles, $newList), $e::Assign($bodies, $newList), $loop,
        $e::Call($titles, [Collections.Generic.List[object]].GetMethod('AddRange'), [Linq.Expressions.Expression[]]@($bodies)),
        $e::IfThen($e::GreaterThan($e::Property($titles, 'Count'), $limit),
            $e::Call($titles, [Collections.Generic.List[object]].GetMethod('RemoveRange'), [Linq.Expressions.Expression[]]@($limit, $e::Subtract($e::Property($titles, 'Count'), $limit)))),
        $e::Call($titles, [Collections.Generic.List[object]].GetMethod('ToArray'))))
    $script:memoQuickFactory = $e::Lambda([Func[object[], Management.Automation.WildcardPattern[], int, object[]]], $body, [Linq.Expressions.ParameterExpression[]]@($items, $patterns, $limit)).Compile()
}

function Find-WtMemoQuickData([object[]]$Items, [string]$Query, [int]$Limit = 50) {
    if ($null -eq $Items -or $Limit -eq 0) { return , [object[]]::new(0) }
    $patterns = [Management.Automation.WildcardPattern[]]@(foreach ($word in ($Query -split '\s+')) {
        if ($word) { [Management.Automation.WildcardPattern]::new("*$word*", [Management.Automation.WildcardOptions]::IgnoreCase) }
    })
    , $script:memoQuickFactory.Invoke($Items, $patterns, $Limit)
}

function Initialize-WtMemoIndexOrderFactory {
    $e = [Linq.Expressions.Expression]
    $titles = $e::Parameter([string[]], 'titles'); $ids = $e::Parameter([string[]], 'ids')
    $slots = $e::Parameter([Collections.Generic.Dictionary[string, int]], 'slots'); $lower = $e::Parameter([Collections.Generic.List[string]], 'lower')
    $titleRanks = $e::Parameter([Collections.Generic.List[int]], 'titleRanks'); $idRanks = $e::Parameter([Collections.Generic.List[int]], 'idRanks')
    $map = $e::Variable([Collections.Generic.Dictionary[string, int]], 'ranks'); $i = $e::Variable([int], 'i'); $slot = $e::Variable([int], 'slot')
    $dictType = [Collections.Generic.Dictionary[string, int]]
    $newMap = $script:memoNewExpression.Invoke($dictType.GetConstructor([type[]]@([Collections.Generic.IEqualityComparer[string]])), [Linq.Expressions.Expression[]]@($e::Constant([StringComparer]::Ordinal, [Collections.Generic.IEqualityComparer[string]])))
    $get = $dictType.GetMethod('get_Item'); $set = [Collections.Generic.List[int]].GetMethod('set_Item')
    $rank = $e::Call($map, $get, [Linq.Expressions.Expression[]]@($e::Call($lower, [Collections.Generic.List[string]].GetMethod('get_Item'), [Linq.Expressions.Expression[]]@($slot))))
    $body = $e::Block([Linq.Expressions.ParameterExpression[]]@($map, $i, $slot), [Linq.Expressions.Expression[]]@(
        $e::Assign($map, $newMap),
        (New-WtMemoLoopExpression $i ($e::ArrayLength($titles)) ($e::Call($map, $dictType.GetMethod('Add'), [Linq.Expressions.Expression[]]@($e::ArrayIndex($titles, $i), $i)))),
        $e::Assign($i, $e::Constant(0)),
        (New-WtMemoLoopExpression $i ($e::ArrayLength($ids)) ($e::Block([Linq.Expressions.Expression[]]@(
            $e::Assign($slot, $e::Call($slots, $get, [Linq.Expressions.Expression[]]@($e::ArrayIndex($ids, $i)))),
            $e::Call($titleRanks, $set, [Linq.Expressions.Expression[]]@($slot, $rank)),
            $e::Call($idRanks, $set, [Linq.Expressions.Expression[]]@($slot, $i))))))))
    $script:memoIndexOrderFactory = $e::Lambda([Action[string[], string[], Collections.Generic.Dictionary[string, int], Collections.Generic.List[string], Collections.Generic.List[int], Collections.Generic.List[int]]], $body,
        [Linq.Expressions.ParameterExpression[]]@($titles, $ids, $slots, $lower, $titleRanks, $idRanks)).Compile()
}
function New-WtMemoViewRows([object[]]$Items, [Management.Automation.ScriptBlock[]]$Getters, [Collections.IDictionary]$Cache, [switch]$Search, [switch]$Reuse) {
    if ($null -eq $Items) { return , [object[]]::new(0) }
    , $script:memoViewRowFactories[$(if ($Search) { 'Snippet' } else { 'body' })].Invoke($Items, $Getters, $Cache, [bool]$Reuse)
}

function Get-WtMemoCachedLinks($Index, $Cache) {
    if (-not $Cache -or $Cache.Version -ne 1 -or $Cache.Entries -isnot [Collections.IDictionary]) { return }
    $c = $Index.Columns
    for ($i = 0; $i -lt $c.Id.Count; $i++) {
        if (-not $c.Alive[$i]) { continue }
        $entry = $Cache.Entries[$c.Id[$i]]
        if (-not $entry -or $entry.Body -isnot [string] -or $entry.Body -cne $c.Body[$i] -or $entry.Outgoing -isnot [array] -or $entry.HasLink -isnot [bool]) { continue }
        $outgoing = New-WtMemoStringSet
        $valid = $true
        foreach ($target in $entry.Outgoing) { if ($target -isnot [string]) { $valid = $false; break }; [void]$outgoing.Add($target) }
        if ($valid) { $Index.LinkCache[$c.Body[$i]] = @{ Outgoing = $outgoing; HasLink = $entry.HasLink } }
    }
}

function New-WtMemoPreparedData($Doc, $Cache, $Context) {
    Initialize-WtMemoWorker $Context
    if ($null -ne $Doc -and ($Doc -isnot [pscustomobject] -or $Doc.schema -ne 1 -or $Doc.items -isnot [array])) { return $null }
    $seen = New-WtMemoStringSet
    $live = @(foreach ($item in $Doc.items) {
        $id = Get-WtField $item 'id'
        if ($id -is [string] -and $id -and $seen.Add($id) -and -not (Test-WtDeleted $item)) { $item }
    })
    $live = Get-WtMemoDetachedItems $live
    $items = @($live | Sort-Object -Property @{ Expression = { [string]$_.updated }; Descending = $true })
    $folders = if ($null -ne $Doc.folders -and $Doc.folders -is [array]) { $Doc.folders } else { @(Get-WtMemoDefaultFolders) }
    $index = New-WtMemoIndex $items -Folders $folders
    Get-WtMemoCachedLinks $index $Cache
    $allCached = $true
    for ($i = 0; $i -lt $index.Columns.Id.Count; $i++) { if ($index.Columns.Alive[$i] -and -not $index.LinkCache.ContainsKey($index.Columns.Body[$i])) { $allCached = $false; break } }
    if ($allCached) { Initialize-WtMemoLinks $index }
    @{ Items = $items; Live = $live; Index = $index; Document = $Doc }
}

function Complete-WtMemoBackgroundIndex($Items, $Folders, $CachePath, $Context) {
    Initialize-WtMemoWorker $Context
    $index = New-WtMemoIndex $Items -Folders $Folders
    Get-WtMemoCachedLinks $index (Read-WtCacheFile $CachePath)
    Initialize-WtMemoLinks $index
    $entries = @{}
    $c = $index.Columns
    for ($i = 0; $i -lt $c.Id.Count; $i++) {
        if ($c.Alive[$i]) { $entries[$c.Id[$i]] = @{ Body = $c.Body[$i]; HasLink = $c.HasLink[$i]; Outgoing = @($c.Outgoing[$i]) } }
    }
    Write-WtCacheFile $CachePath @{ Version = 1; Entries = $entries }
    $index
}

function Start-WtMemoBackgroundIndex {
    param([object[]]$Items, [object[]]$Folders, [scriptblock]$OnDone, $Context)
    Start-WtWork -Script { param($items, $folders, $cachePath, $context) Complete-WtMemoBackgroundIndex $items $folders $cachePath $context } `
        -ArgumentList $Items, $Folders, (Get-WtStorePath 'memo-index-cache'), $script:memoWorkerContext `
        -Functions $script:memoWorkerFunctions -Session Default -OnDone $OnDone -Context $Context
}

# 같은 함수 정의를 Work에 넘긴다. 묶음(New-Module)에서도 파일 경로나 다시 Import-Module할 모듈이 필요 없다.
function Register-WtMemoPreparation {
    $recordModule = (Get-Command ConvertFrom-WtStamp).Module
    $markdownModule = (Get-Command ConvertTo-WtMarkdownModel).Module
    $recordFunctions = & $recordModule { Get-Command Get-WtField, Test-WtRecordObject, Test-WtDeleted, ConvertFrom-WtWhole, ConvertFrom-WtStamp, ConvertFrom-WtLegacyStamp, ConvertFrom-WtLegacyDate, ConvertFrom-WtLegacyTime, Get-WtStamp }
    $markdownFunctions = & $markdownModule { Get-Command ConvertTo-WtMarkdownModel, Get-WtMarkdownPipeline, ConvertFrom-WtMd*, Get-WtMdLines, Add-WtMdText, Add-WtMdPlain, Get-WtMdLinkKind, New-WtMdLinkModel, New-WtMdImageModel, Get-WtMdInlineText, Get-WtMdBlocksText, Get-WtMdAnchorKey }
    $script:memoWorkerContext = & $recordModule {
        $values = @{}
        foreach ($name in 'inv', 'ko', 'stampFormat', 'minYear', 'maxYear', 'legacyDates', 'legacyTimes', 'legacyTimesKo', 'legacyStamps', 'legacyStampsKo') { $values[$name] = $ExecutionContext.SessionState.PSVariable.GetValue("script:$name") }
        $values
    }
    $markdownContext = & $markdownModule { @{ callouts = $script:callouts; obsidianRe = $script:obsidianRe } }
    foreach ($name in $markdownContext.Keys) { $script:memoWorkerContext[$name] = $markdownContext[$name] }
    $script:memoWorkerContext.memoInv = $script:memoInv
    $script:memoWorkerContext.memoLinkHint = $script:memoLinkHint
    $script:memoWorkerContext.memoIndexOrderFactory = $script:memoIndexOrderFactory
    $script:memoWorkerContext.memoDetachedFactory = $script:memoDetachedFactory
    $script:memoWorkerFunctions = @(Get-Command New-WtMemoIndex, Set-WtMemoIndexEntry, Update-WtMemoIndexOrder, Get-WtMemoIndexedTime, Get-WtMemoDefaultFolders,
        New-WtMemoStringSet, Get-WtMemoLinkInfo, Initialize-WtMemoLinks, Update-WtMemoBacklinks, Get-WtMemoIndexEntries, Set-WtMemoIndexProperties,
        Initialize-WtMemoWorker, Get-WtMemoCachedLinks, Complete-WtMemoBackgroundIndex, Get-WtMemoDetachedItems, Read-WtCacheFile, Write-WtCacheFile) + @($recordFunctions) + @($markdownFunctions)
    Register-WtStorePreparation -Name 'memo' -Prepare (Get-Command New-WtMemoPreparedData) -Functions $script:memoWorkerFunctions -Context $script:memoWorkerContext -CacheName 'memo-index-cache'
    Register-WtStorePreparation -Name 'memo-state' -Prepare (Get-Command New-WtMemoStatePreparation) -Functions @() -Context $null
}

function New-WtMemoStatePreparation($Doc, $Cache, $Context) { $null }

# 첫 입력 때 .NET 대리자/문자열 변환의 첫 실행 비용을 내지 않게 한다. 파일·사용자 자료에는 닿지 않는다.
function Initialize-WtMemoQueryRuntime {
    $stamp = [DateTimeOffset]::Now.ToString("yyyy-MM-dd'T'HH:mm:sszzz", $script:memoInv)
    $sample = @(for ($i = 0; $i -lt 4; $i++) {
        [pscustomobject]@{ id = "warm-$i"; title = "warm $i"; body = "word #tag [[warm 1]]`n`n- [ ] 항목"; tags = @('tag'); folder = 'work'; pinned = ($i -eq 0); created = $stamp; updated = $stamp }
    })
    $index = New-WtMemoIndex $sample
    $opened = @{ 'warm-0' = $stamp }
    foreach ($query in 'word', '#tag updated:30d', 'absent', 'has:link') {
        foreach ($sort in '', 'updated', 'created', 'title', 'opened', 'backlinks') {
            $parameters = @{ Index = $index; Query = $query; First = 4; OpenedMap = $opened; SkipBacklinks = $true }
            if ($sort) { $parameters.Sort = $sort }
            $result = Find-WtMemo @parameters
            if (-not $result.Success) { throw $result.Error.Reason }
        }
    }
    $getters = [scriptblock[]]@({ $this.Updated }, { $this.SnippetSource }, { $this.Title })
    [void](New-WtMemoViewRows $sample $getters @{})
    [void](New-WtMemoViewRows $result.Items $getters @{} -Search)
    [void](Get-WtMemoLookupData $sample)
    [void](Get-WtMemoUpdatedOrder $sample)
    [void](Find-WtMemoQuickData $sample 'word')
    [void](Find-WtMemoQuickData $sample 'absent')
    [void]$script:memoSaveFactory.Invoke($sample, $sample)
    [void](Get-WtMarkdownSnippet "# 제목`n`n[[warm 1]] #tag`n`n- [ ] 항목" 80)
    if (Get-Command Format-WtMemoTime -ErrorAction SilentlyContinue) { [void](Format-WtMemoTime $stamp) }
}

# 입력 자료와 무관한 대리자는 모듈을 읽을 때 한 번 준비한다(검색 중 컴파일하지 않는다).
Initialize-WtMemoSearchEngine
Initialize-WtMemoViewFactories
Initialize-WtMemoSaveFactory
Initialize-WtMemoQuickFactory
Initialize-WtMemoIndexOrderFactory
Register-WtMemoPreparation
Initialize-WtMemoQueryRuntime

Export-ModuleMember -Function ConvertFrom-WtMemoQuery, ConvertTo-WtMemoQuery, New-WtMemoIndex, Update-WtMemoIndex, Add-WtMemoIndexEntries, Find-WtMemo, Get-WtMemoResultRows, Step-WtMemoLinks, Test-WtMemoQueryLinks,
    Set-WtMemoFolder, Set-WtMemoPinned, Set-WtMemoArchived, Get-WtMemoFolders, Save-WtMemoFolders, Set-WtMemoOpened,
    Get-WtMemoViews, Save-WtMemoView, Set-WtMemoViewDeleted, Open-WtMemoStore, Save-WtMemoDataItems, Start-WtMemoBackgroundIndex, Get-WtMemoLookupData, New-WtMemoViewRows, Get-WtMemoUpdatedOrder, Get-WtMemoLiveItems, Get-WtMemoInitialOrder, Set-WtMemoIndexProperties, Find-WtMemoQuickData, Get-WtMemoIdArray, Get-WtMemoDetachedItems

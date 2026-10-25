# 메모 편집 명령: 키 하나로 마크다운 글을 고치는 순수 함수 (WPF 없음). 편집기(TextBox)가 부른다.
# 입력 $s = @{ Text; Start; Length } = 글 전체 · 선택(문자 위치). 줄바꿈은 `r`n · `n 모두 받는다.
#   새로 넣는 줄바꿈은 글에서 쓰는 것을 따른다(`r`n이 있으면 `r`n, `n만 있으면 `n, 없으면 `r`n).
# 출력: 할 일이 없으면 $null(편집기 기본 동작). 고치면 편집 하나
#   @{ Start; Length; Insert; SelStart; SelLength } = 원래 글 [Start, Start+Length)를 Insert로 바꾸고, 바뀐 글 기준으로 선택.
#   여러 곳을 고쳐도 그것들을 덮는 범위 하나로 돌려준다(실행 취소 한 단위). Insert가 ''이고 Length가 0이면 커서만 옮긴다.
#   Suggest = 'wiki'가 있으면 [[ ]] 안이므로 메모 제목 자동 완성을 연다.
# 단축키: Ctrl+B 굵게 · Ctrl+I 기울임 · Alt+Shift+5 취소선 · Ctrl+Shift+` 코드 (Get-WtMemoWrapEdit)
#         글자 입력 ` [ ] (Get-WtMemoTypeEdit) · Enter (Get-WtMemoEnterEdit) · Tab / Shift+Tab (Get-WtMemoIndentEdit)
#         Ctrl+L 할 일 (Get-WtMemoTaskEdit) · Ctrl+K 링크 (Get-WtMemoLinkEdit) · Alt+↑/↓ 줄 옮기기 (Get-WtMemoMoveLinesEdit)
#         붙여넣기 (Get-WtMemoPasteEdit) · 탐색기에서 끌어 놓기 (Get-WtMemoDropEdit)

$ErrorActionPreference = 'Stop'

# 목록 줄: 인용 접두어 · 들여쓰기 · 표지 · 표지 뒤 공백 · 체크박스 · 내용
$script:mtList = [regex]'^((?:[ \t]*>[ \t]?)*)([ \t]*)([-*+]|\d{1,9}[.)])([ \t]+)(\[[ xX]\](?:[ \t]+|$))?(.*)$'
$script:mtQuote = [regex]'^((?:[ \t]*>[ \t]?)+)(.*)$'
$script:mtLead = [regex]'^((?:[ \t]*>[ \t]?)*)([ \t]*)'
# 줄의 내용 앞부분(감싸기에서 건너뜀): 인용 · 들여쓰기 · 제목 # · 목록 표지 · 체크박스
$script:mtContent = [regex]'^(?:[ \t]*>[ \t]?)*[ \t]*(?:#{1,6}(?:[ \t]+|$)|(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\](?:[ \t]+|$))?)?'
$script:mtFence = [regex]'(?m)^[ \t]{0,3}(?:```|~~~)'
$script:mtUrl = [regex]'^(?:(?:https?|mailto|file):\S+|www\.\S+)$'
$script:mtPath = [regex]'^(?:[A-Za-z]:\\|[A-Za-z]:$|\\\\[^\\]+\\[^\\]+)'

# ---- 공통 -------------------------------------------------------------------------------------

function Get-WtMemoTextNewline([string]$Text) {
    if ($Text.Contains("`r`n")) { return "`r`n" }
    if ($Text.Contains("`n")) { return "`n" }
    "`r`n"
}

# 위치가 든 줄: Start · End(줄바꿈 앞) · Next(다음 줄 시작, 없으면 -1) · Text
function Get-WtMemoTextLine([string]$Text, [int]$Pos) {
    $start = if ($Pos -le 0) { 0 } else { $Text.LastIndexOf([char]10, $Pos - 1) + 1 }
    $nx = $Text.IndexOf([char]10, $Pos)
    if ($nx -lt 0) { $end = $Text.Length; $next = -1 }
    else {
        $end = $nx; $next = $nx + 1
        if ($end -gt $start -and $Text[$end - 1] -eq [char]13) { $end-- }
    }
    @{ Start = $start; End = $end; Next = $next; Text = $Text.Substring($start, $end - $start) }
}

function Get-WtMemoTextPrevLine([string]$Text, $Line) {
    if ($Line.Start -le 0) { return $null }
    Get-WtMemoTextLine $Text ($Line.Start - 1)
}

function Get-WtMemoTextNextLine([string]$Text, $Line) {
    if ($Line.Next -lt 0) { return $null }
    Get-WtMemoTextLine $Text $Line.Next
}

# 선택이 걸친 줄들. 여러 줄 선택의 끝이 다음 줄 0칸이면 그 줄은 뺀다
function Get-WtMemoTextSelLines([string]$Text, [int]$Start, [int]$Length) {
    $end = $Start + $Length
    $lines = [System.Collections.Generic.List[object]]::new()
    $line = Get-WtMemoTextLine $Text $Start
    $lines.Add($line)
    # 다음 줄들은 함수 호출 없이 읽는다 (긴 글 전체 선택도 빠르게)
    while ($line.End -lt $end -and $line.Next -ge 0) {
        $s = $line.Next
        $nx = $Text.IndexOf([char]10, $s)
        if ($nx -lt 0) { $e = $Text.Length; $next = -1 }
        else { $e = $nx; $next = $nx + 1; if ($e -gt $s -and $Text[$e - 1] -eq [char]13) { $e-- } }
        $line = @{ Start = $s; End = $e; Next = $next; Text = $Text.Substring($s, $e - $s) }
        $lines.Add($line)
    }
    if ($Length -gt 0 -and $lines.Count -gt 1 -and $end -eq $lines[$lines.Count - 1].Start) { $lines.RemoveAt($lines.Count - 1) }
    , $lines.ToArray()
}

# 들여쓰기 너비 (탭은 4칸 단위)
function Get-WtMemoTextWidth([string]$Ws) {
    $w = 0
    foreach ($c in $Ws.ToCharArray()) { if ($c -eq "`t") { $w += 4 - ($w % 4) } else { $w++ } }
    $w
}

# 줄 하나를 읽는다: 목록이면 표지 · 내용 시작, 아니면 인용 · 들여쓰기 · 빈 줄 여부
function Get-WtMemoTextLineInfo([string]$Text) {
    $m = $script:mtList.Match($Text)
    if ($m.Success) {
        $sp = $m.Groups[4].Value
        $spW = if ($sp.Length -gt 4) { 1 } else { $sp.Length }   # 공백 5칸 이상이면 내용은 표지+1칸 (CommonMark)
        return @{
            List = $true; Blank = $false; Q = $m.Groups[1].Value; Ind = $m.Groups[2].Value; W = (Get-WtMemoTextWidth $m.Groups[2].Value)
            Mk = $m.Groups[3].Value; Sp = $sp; Cb = $m.Groups[5].Value; Body = $m.Groups[6].Value; MW = $m.Groups[3].Value.Length + $spW
        }
    }
    $m = $script:mtLead.Match($Text)
    @{
        List = $false; Q = $m.Groups[1].Value; Ind = $m.Groups[2].Value; W = (Get-WtMemoTextWidth $m.Groups[2].Value)
        Blank = ($Text.Substring($m.Length).Trim() -eq '')
    }
}

# 줄이 닫히지 않은 코드 울타리 안인가 (위쪽 울타리 줄 수가 홀수, 이 줄은 울타리가 아님)
function Test-WtMemoTextInFence([string]$Text, $Line) {
    if ($script:mtFence.Match($Line.Text).Success) { return $false }
    ($script:mtFence.Matches($Text.Substring(0, $Line.Start)).Count % 2) -eq 1
}

function New-WtMemoTextResult([int]$Start, [int]$Length, [string]$Insert, [int]$SelStart, [int]$SelLength = 0) {
    @{ Start = $Start; Length = $Length; Insert = $Insert; SelStart = $SelStart; SelLength = $SelLength }
}

# 고칠 곳 여러 개(@{ Pos; Del; Ins }, 겹치지 않음)의 위치 옮김. $Right면 같은 자리에 넣은 글 뒤로
function Get-WtMemoTextMapPos([object[]]$Ops, [int]$P, [bool]$Right) {
    $shift = 0
    foreach ($op in $Ops) {
        if ($P -lt $op.Pos) { break }
        $end = $op.Pos + $op.Del
        if ($P -lt $end -or ($P -eq $op.Pos -and $op.Del -eq 0)) {
            return $op.Pos + $shift + $(if ($Right) { $op.Ins.Length } else { 0 })
        }
        $shift += $op.Ins.Length - $op.Del
    }
    $P + $shift
}

# 고칠 곳 여러 개 → 그것들을 덮는 편집 하나. 선택 시작은 넣은 글 뒤로, 끝은 앞으로 옮긴다(접힌 선택은 둘 다 뒤로)
function New-WtMemoTextOpsEdit([string]$Text, [object[]]$Ops, [int]$SelA, [int]$SelB) {
    $Ops = @($Ops | Where-Object { $_ } | Sort-Object { $_.Pos })
    if (-not $Ops.Count) { return $null }
    $first = $Ops[0].Pos; $last = $Ops[-1].Pos + $Ops[-1].Del
    $sb = [System.Text.StringBuilder]::new()
    $at = $first
    foreach ($op in $Ops) {
        [void]$sb.Append($Text.Substring($at, $op.Pos - $at)).Append($op.Ins)   # Append(string, int, int)는 긴 글에서 느리다
        $at = $op.Pos + $op.Del
    }
    $a = Get-WtMemoTextMapPos $Ops $SelA $true
    $b = if ($SelB -eq $SelA) { $a } else { Get-WtMemoTextMapPos $Ops $SelB $false }
    if ($b -lt $a) { $b = $a }
    New-WtMemoTextResult $first ($last - $first) $sb.ToString() $a ($b - $a)
}

function New-WtMemoTextOp([int]$Pos, [int]$Del, [string]$Ins = '') { @{ Pos = $Pos; Del = $Del; Ins = $Ins } }

function Get-WtMemoTextRunAfter([string]$Text, [int]$I, [char]$C, [int]$Stop = -1) {
    if ($Stop -lt 0) { $Stop = $Text.Length }
    $n = 0
    while ($I + $n -lt $Stop -and $Text[$I + $n] -eq $C) { $n++ }
    $n
}

function Get-WtMemoTextRunBefore([string]$Text, [int]$I, [char]$C, [int]$Stop = 0) {
    $n = 0
    while ($I - $n - 1 -ge $Stop -and $Text[$I - $n - 1] -eq $C) { $n++ }
    $n
}

# 같은 글자 n개가 이 표지인가. * 하나는 1 · 3(***), ** 는 2 · 3 으로 굵게 · 기울임을 가른다
function Test-WtMemoTextRun([string]$Marker, [int]$Run) {
    if ($Run -le 0) { return $false }
    if ($Marker -eq '*' -or $Marker -eq '_') { return $Run -eq 1 -or $Run -eq 3 }
    if ($Marker -eq '**' -or $Marker -eq '__') { return $Run -eq 2 -or $Run -eq 3 }
    $Run -eq $Marker.Length
}

function Test-WtMemoTextWordChar([char]$C) {
    if ([char]::IsLetterOrDigit($C) -or $C -eq '_') { return $true }
    $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($C)
    $cat -eq 'NonSpacingMark' -or $cat -eq 'SpacingCombiningMark'
}

# 인라인 코드 표지: 글에 `가 있으면 더 긴 백틱 + 공백 (CommonMark)
function Get-WtMemoTextCodeFence([string]$Core) {
    if (-not $Core.Contains('`')) { return @('`', '`') }
    $max = 0
    foreach ($m in [regex]::Matches($Core, '`+')) { if ($m.Length -gt $max) { $max = $m.Length } }
    $f = '`' * ($max + 1)
    @("$f ", " $f")
}

# 글 [A, B)가 표지로 감싸져 있는가. 표지는 안쪽(글 처음 · 끝)이나 바로 바깥에 있을 수 있다
# 돌려주는 것: @{ Wrapped; Ops(벗기기); InA; InB(벗긴 뒤 안쪽 글 범위, 원래 글 기준) }
function Get-WtMemoTextWrapState([string]$Text, [int]$A, [int]$B, [string]$Marker) {
    $len = $B - $A
    if ($Marker -eq '`') { return Get-WtMemoTextCodeState $Text $A $B }
    $m = $Marker.Length; $c = $Marker[0]
    if ($Text[$A] -ne $c -and ($A -eq 0 -or $Text[$A - 1] -ne $c)) { return @{ Wrapped = $false } }   # 빠른 길: 왼쪽에 표지 글자가 없음
    $inL =Get-WtMemoTextRunAfter $Text $A $c $B
    $inR = Get-WtMemoTextRunBefore $Text $B $c $A
    $left = $null; $right = $null
    if ((Test-WtMemoTextRun $Marker $inL) -and $inL -lt $len) { $left = @{ Pos = $A; In = $true } }
    elseif (Test-WtMemoTextRun $Marker (Get-WtMemoTextRunBefore $Text $A $c)) { $left = @{ Pos = $A - $m; In = $false } }
    if ((Test-WtMemoTextRun $Marker $inR) -and $inR -lt $len) { $right = @{ Pos = $B - $m; In = $true } }
    elseif (Test-WtMemoTextRun $Marker (Get-WtMemoTextRunAfter $Text $B $c)) { $right = @{ Pos = $B; In = $false } }
    if (-not $left -or -not $right -or ($left.In -and $right.In -and $len -le 2 * $m)) { return @{ Wrapped = $false } }
    @{
        Wrapped = $true
        Ops = @((New-WtMemoTextOp $left.Pos $m), (New-WtMemoTextOp $right.Pos $m))
        InA = $(if ($left.In) { $A + $m } else { $A }); InB = $(if ($right.In) { $B - $m } else { $B })
    }
}

# 인라인 코드: 양쪽 백틱 개수가 같아야 한다. 바깥 공백 패딩은 백틱 2개 이상일 때만 본다(`a` b `c`의 b를 코드로 오해하지 않게)
function Get-WtMemoTextCodeState([string]$Text, [int]$A, [int]$B) {
    $len = $B - $A
    $inL = Get-WtMemoTextRunAfter $Text $A '`' $B
    $inR = Get-WtMemoTextRunBefore $Text $B '`' $A
    $left = $null; $right = $null
    if ($inL -gt 0 -and $inL -lt $len) { $left = @{ N = $inL; In = $true; Pad = ($A + $inL -lt $B -and $Text[$A + $inL] -eq ' ') } }
    else {
        $n = Get-WtMemoTextRunBefore $Text $A '`'
        if ($n -gt 0) { $left = @{ N = $n; In = $false; Pad = $false } }
        elseif ($A -ge 1 -and $Text[$A - 1] -eq ' ') {
            $n = Get-WtMemoTextRunBefore $Text ($A - 1) '`'
            if ($n -ge 2) { $left = @{ N = $n; In = $false; Pad = $true } }
        }
    }
    if ($inR -gt 0 -and $inR -lt $len) { $right = @{ N = $inR; In = $true; Pad = ($B - $inR - 1 -ge $A -and $Text[$B - $inR - 1] -eq ' ') } }
    else {
        $n = Get-WtMemoTextRunAfter $Text $B '`'
        if ($n -gt 0) { $right = @{ N = $n; In = $false; Pad = $false } }
        elseif ($B -lt $Text.Length -and $Text[$B] -eq ' ') {
            $n = Get-WtMemoTextRunAfter $Text ($B + 1) '`'
            if ($n -ge 2) { $right = @{ N = $n; In = $false; Pad = $true } }
        }
    }
    if (-not $left -or -not $right -or $left.N -ne $right.N -or ($left.In -and $right.In -and $len -le $inL + $inR)) { return @{ Wrapped = $false } }
    $pad = [int]($left.Pad -and $right.Pad)
    $n = $left.N
    if ($left.In) { $lOp = New-WtMemoTextOp $A ($n + $pad); $inA = $A + $n + $pad }
    elseif ($left.Pad) { $lOp = New-WtMemoTextOp ($A - 1 - $n) ($n + $pad); $inA = $A }
    else { $lOp = New-WtMemoTextOp ($A - $n) $n; $inA = $A }
    if ($right.In) { $rOp = New-WtMemoTextOp ($B - $n - $pad) ($n + $pad); $inB = $B - $n - $pad }
    elseif ($right.Pad) { $rOp = New-WtMemoTextOp ($B + 1 - $pad) ($n + $pad); $inB = $B }
    else { $rOp = New-WtMemoTextOp $B $n; $inB = $B }
    @{ Wrapped = $true; Ops = @($lOp, $rOp); InA = $inA; InB = $inB }
}

# 감싸기 고칠 곳: [A, B) 앞뒤에 표지를 넣는다
function Get-WtMemoTextWrapOps([string]$Text, [int]$A, [int]$B, [string]$Marker) {
    $pair = if ($Marker -eq '`') { Get-WtMemoTextCodeFence $Text.Substring($A, $B - $A) } else { @($Marker, $Marker) }
    @((New-WtMemoTextOp $A 0 $pair[0]), (New-WtMemoTextOp $B 0 $pair[1]))
}

# 선택을 줄마다 내용 부분으로 나눈다(앞 공백 · 목록 표지 · 인용 · 제목 # 뒤, 앞뒤 공백 뺌). 빈 조각은 뺀다
function Get-WtMemoTextSegments([string]$Text, [int]$Start, [int]$Length) {
    $end = $Start + $Length
    foreach ($line in (Get-WtMemoTextSelLines $Text $Start $Length)) {
        $a = [Math]::Max($line.Start, $Start); $b = [Math]::Min($line.End, $end)
        $a = [Math]::Max($a, $line.Start + $script:mtContent.Match($line.Text).Length)
        while ($a -lt $b -and ($Text[$a] -eq ' ' -or $Text[$a] -eq "`t")) { $a++ }
        while ($b -gt $a -and ($Text[$b - 1] -eq ' ' -or $Text[$b - 1] -eq "`t")) { $b-- }
        if ($a -lt $b) { @{ A = $a; B = $b } }
    }
}

# ---- 감싸기 (굵게 · 기울임 · 취소선 · 코드) -----------------------------------------------------

# Ctrl+B(**) · Ctrl+I(*) · Alt+Shift+5(~~) · Ctrl+Shift+`(`) 켜기/끄기
function Get-WtMemoWrapEdit($s, [string]$Marker) {
    $t = [string]$s.Text; $pos = [int]$s.Start; $n = [int]$s.Length
    if (-not $Marker) { return $null }
    if ($n -gt 0) {
        $segs = @(Get-WtMemoTextSegments $t $pos $n)
        if (-not $segs.Count) { return $null }
        $states = @(foreach ($g in $segs) { Get-WtMemoTextWrapState $t $g.A $g.B $Marker })
        $all = -not @($states | Where-Object { -not $_.Wrapped }).Count
        $ops = [System.Collections.Generic.List[object]]::new()
        $inA = $segs[0].A; $inB = $segs[-1].B
        for ($i = 0; $i -lt $segs.Count; $i++) {
            if ($all) {
                $ops.AddRange([object[]]$states[$i].Ops)
                if ($i -eq 0) { $inA = $states[$i].InA }
                if ($i -eq $segs.Count - 1) { $inB = $states[$i].InB }
            } elseif (-not $states[$i].Wrapped) {
                $ops.AddRange([object[]](Get-WtMemoTextWrapOps $t $segs[$i].A $segs[$i].B $Marker))
            }
        }
        return New-WtMemoTextOpsEdit $t $ops.ToArray() $inA $inB
    }

    # 선택 없음 1) 빈 짝 사이면 짝을 지운다
    $c = $Marker[0]
    $before = Get-WtMemoTextRunBefore $t $pos $c; $after = Get-WtMemoTextRunAfter $t $pos $c
    if ($Marker -eq '`') {
        if ($before -gt 0 -and $before -eq $after) { return New-WtMemoTextResult ($pos - $before) (2 * $before) '' ($pos - $before) }
    } elseif ((Test-WtMemoTextRun $Marker $before) -and (Test-WtMemoTextRun $Marker $after)) {
        $m = $Marker.Length
        return New-WtMemoTextResult ($pos - $m) (2 * $m) '' ($pos - $m)
    }
    # 2) 낱말 안 · 끝이면 낱말을 감싸거나 벗긴다
    if ($pos -gt 0 -and (Test-WtMemoTextWordChar $t[$pos - 1])) {
        $wa = $pos; $wb = $pos
        while ($wa -gt 0 -and (Test-WtMemoTextWordChar $t[$wa - 1])) { $wa-- }
        while ($wb -lt $t.Length -and (Test-WtMemoTextWordChar $t[$wb])) { $wb++ }
        $state = Get-WtMemoTextWrapState $t $wa $wb $Marker
        $ops = if ($state.Wrapped) { $state.Ops } else { Get-WtMemoTextWrapOps $t $wa $wb $Marker }
        $e = New-WtMemoTextOpsEdit $t $ops $pos $pos
        $e.SelStart = Get-WtMemoTextMapPos @($ops) $pos ($pos -lt $wb)   # 낱말 끝 커서는 닫는 표지 앞(안쪽)에
        return $e
    }
    # 3) 짝을 넣고 커서를 가운데에
    New-WtMemoTextResult $pos 0 ($Marker + $Marker) ($pos + $Marker.Length)
}

# ---- 글자 입력 ( ` [ ] ) ------------------------------------------------------------------------

# 글자를 넣기 전에 부른다(PreviewTextInput). 해당 없으면 $null
function Get-WtMemoTypeEdit($s, [string]$Char) {
    $t = [string]$s.Text; $pos = [int]$s.Start; $n = [int]$s.Length
    switch -CaseSensitive ($Char) {
        '`' {
            if ($n -gt 0) {
                $sel = $t.Substring($pos, $n)
                if (-not $sel.Contains("`n")) {
                    # 한 줄: 인라인 코드로 감싼다 (앞뒤 공백은 밖에)
                    $a = $pos; $b = $pos + $n
                    while ($a -lt $b -and $t[$a] -eq ' ') { $a++ }
                    while ($b -gt $a -and $t[$b - 1] -eq ' ') { $b-- }
                    if ($a -ge $b) { return $null }
                    return New-WtMemoTextOpsEdit $t (Get-WtMemoTextWrapOps $t $a $b '`') $a $b
                }
                # 여러 줄: 줄 단위로 넓혀 코드 블록으로
                $lines = Get-WtMemoTextSelLines $t $pos $n
                $first = $lines[0]; $last = $lines[-1]
                $body = $t.Substring($first.Start, $last.End - $first.Start)
                $nl = Get-WtMemoTextNewline $t
                $max = 2
                foreach ($m in [regex]::Matches($body, '(?m)^[ \t]*(`{3,})')) { if ($m.Groups[1].Length -gt $max) { $max = $m.Groups[1].Length } }
                $fence = '`' * ($max + 1)
                $ind = $null
                foreach ($l in $lines) {
                    if (-not $l.Text.Trim()) { continue }
                    $w = $script:mtLead.Match($l.Text).Groups[2].Value
                    $q = $script:mtLead.Match($l.Text).Groups[1].Value
                    $lead = $q + $w
                    if ($null -eq $ind) { $ind = $lead } else {
                        $k = 0
                        while ($k -lt $ind.Length -and $k -lt $lead.Length -and $ind[$k] -eq $lead[$k]) { $k++ }
                        $ind = $ind.Substring(0, $k)
                    }
                }
                if ($null -eq $ind) { $ind = '' }
                $open = "$ind$fence$nl"
                return New-WtMemoTextResult $first.Start $body.Length "$open$body$nl$ind$fence" ($first.Start + $open.Length) $body.Length
            }
            # 줄 맨 앞 ``` → 닫는 울타리를 아래 줄에
            $line = Get-WtMemoTextLine $t $pos
            $head = $t.Substring($line.Start, $pos - $line.Start) + '`'
            if ($head -notmatch '^[ \t]{0,3}```$') { return $null }
            if ($t.Substring($pos, $line.End - $pos).Trim()) { return $null }
            $above = $script:mtFence.Matches($t.Substring(0, $line.Start)).Count
            $below = if ($line.Next -ge 0) { $script:mtFence.Matches($t.Substring($line.Next)).Count } else { 0 }
            if ($above % 2 -or $below % 2) { return $null }
            $ind = [regex]::Match($line.Text, '^[ \t]*').Value
            return New-WtMemoTextResult $pos ($line.End - $pos) ('`' + (Get-WtMemoTextNewline $t) + $ind + '```') ($pos + 1)
        }
        '[' {
            if ($n -gt 0 -or $pos -lt 1 -or $t[$pos - 1] -ne '[') { return $null }
            if ($pos -ge 2 -and $t[$pos - 2] -eq '[') { return $null }
            if ($pos -lt $t.Length -and $t[$pos] -eq ']') { return $null }
            $e = New-WtMemoTextResult $pos 0 '[]]' ($pos + 1)
            $e.Suggest = 'wiki'
            return $e
        }
        ']' {
            if ($n -gt 0 -or $pos -ge $t.Length -or $t[$pos] -ne ']') { return $null }
            $line = Get-WtMemoTextLine $t $pos
            $head = $t.Substring($line.Start, $pos - $line.Start)
            $k = $head.LastIndexOf('[[')
            if ($k -lt 0 -or $head.IndexOf(']]', $k) -ge 0) { return $null }
            return New-WtMemoTextResult $pos 0 '' ($pos + 1)
        }
    }
    $null
}

# ---- Enter -----------------------------------------------------------------------------------

# 다음 번호 표지 (9. → 10.), 글머리표는 그대로
function Get-WtMemoTextNextMarker([string]$Mk) {
    if ($Mk -match '^(\d+)([.)])$') { return "$([int64]$Matches[1] + 1)$($Matches[2])" }
    $Mk
}

function Get-WtMemoEnterEdit($s) {
    $t = [string]$s.Text; $pos = [int]$s.Start
    if ([int]$s.Length -gt 0) { return $null }
    $line = Get-WtMemoTextLine $t $pos
    $col = $pos - $line.Start
    $nl = Get-WtMemoTextNewline $t
    # 커서 뒤 공백은 다음 줄로 넘기지 않는다
    $gap = 0
    while ($pos + $gap -lt $line.End -and ($t[$pos + $gap] -eq ' ' -or $t[$pos + $gap] -eq "`t")) { $gap++ }

    # 코드 울타리 안: 줄바꿈 + 앞 공백 유지
    if (Test-WtMemoTextInFence $t $line) {
        $ws = [regex]::Match($line.Text, '^[ \t]*').Value
        if ($ws.Length -gt $col) { $ws = $ws.Substring(0, $col) }
        return New-WtMemoTextResult $pos 0 "$nl$ws" ($pos + $nl.Length + $ws.Length)
    }

    $info = Get-WtMemoTextLineInfo $line.Text
    if ($info.List) {
        $cs = $line.Text.Length - $info.Body.Length
        if ($col -lt $cs) { return $null }
        if ($info.Body.Trim()) {
            $ins = $nl + $info.Q + $info.Ind + (Get-WtMemoTextNextMarker $info.Mk) + $info.Sp + $(if ($info.Cb) { '[ ] ' } else { '' })
            return New-WtMemoTextResult $pos $gap $ins ($pos + $ins.Length)
        }
        $from = $line.Start + $info.Q.Length
        if (-not $info.Ind) {
            # 들여쓰기 없는 빈 항목: 표지를 지워 목록을 끝낸다
            return New-WtMemoTextResult $from ($line.End - $from) '' $from
        }
        # 들여쓴 빈 항목: 한 단계 내어쓰기. 부모(더 얕은 목록 줄)의 다음 형제가 된다
        $ind = ' ' * [Math]::Max(0, $info.W - 4); $mk = $info.Mk; $sp = $info.Sp
        $p = Get-WtMemoTextPrevLine $t $line
        while ($p) {
            $pi = Get-WtMemoTextLineInfo $p.Text
            if (-not $pi.Blank -and $pi.W -lt $info.W) {
                if ($pi.List) {
                    $ind = $pi.Ind; $sp = $pi.Sp
                    $mk = if ($pi.Mk -match '^\d') { Get-WtMemoTextNextMarker $pi.Mk } else { $pi.Mk }
                }
                break
            }
            $p = Get-WtMemoTextPrevLine $t $p
        }
        $new = $ind + $mk + $sp + $(if ($info.Cb) { '[ ] ' } else { '' })
        return New-WtMemoTextResult $from ($line.End - $from) $new ($from + $new.Length)
    }

    $m = $script:mtQuote.Match($line.Text)
    if ($m.Success) {
        $q = $m.Groups[1].Value
        if ($col -lt $q.Length) { return $null }
        if ($m.Groups[2].Value.Trim()) { return New-WtMemoTextResult $pos $gap "$nl$q" ($pos + $nl.Length + $q.Length) }
        return New-WtMemoTextResult $line.Start $line.Text.Length '' $line.Start
    }
    $null
}

# ---- Tab / Shift+Tab -------------------------------------------------------------------------

# 들여쓰기 고칠 곳: 너비 $Delta만큼 넣거나(+) 뺀다(-). 들여쓰기에 탭이 있으면 공백으로 다시 쓴다
function Get-WtMemoTextIndentOp($Line, $Info, [int]$Delta) {
    $at = $Line.Start + $Info.Q.Length
    if ($Delta -gt 0) {
        if ($Info.Ind.Contains("`t")) { return New-WtMemoTextOp $at $Info.Ind.Length (' ' * ($Info.W + $Delta)) }
        return New-WtMemoTextOp $at 0 (' ' * $Delta)
    }
    $d = [Math]::Min(-$Delta, $Info.W)
    if ($d -le 0) { return $null }
    if ($Info.Ind.Contains("`t")) { return New-WtMemoTextOp $at $Info.Ind.Length (' ' * ($Info.W - $d)) }
    New-WtMemoTextOp $at $d
}

function Get-WtMemoIndentEdit($s, [switch]$Outdent) {
    $t = [string]$s.Text; $pos = [int]$s.Start; $n = [int]$s.Length
    $lines = Get-WtMemoTextSelLines $t $pos $n
    $group = $lines
    $head = $null; $headLine = $null
    foreach ($l in $lines) { $i = Get-WtMemoTextLineInfo $l.Text; if (-not $i.Blank) { $head = $i; $headLine = $l; break } }
    if (-not $head) { return $null }
    $isList = $head.List -and -not (Test-WtMemoTextInFence $t $headLine)

    if ($lines.Count -eq 1) {
        if ($isList) {
            if ($Outdent -and $head.W -eq 0) { return $null }
            # 항목과 바로 아래 자식 줄들(더 깊게 들여쓴 이어진 줄)을 같이 옮긴다
            $list = [System.Collections.Generic.List[object]]::new(); $list.Add($headLine)
            $nx = Get-WtMemoTextNextLine $t $headLine
            while ($nx) {
                $ni = Get-WtMemoTextLineInfo $nx.Text
                if ($ni.Blank -or $ni.W -le $head.W) { break }
                $list.Add($nx); $nx = Get-WtMemoTextNextLine $t $nx
            }
            $group = $list.ToArray()
        } else {
            if (-not $Outdent -and $n -eq 0) { return $null }
            if ($Outdent -and $head.W -eq 0) { return $null }
        }
    }

    # 옮길 너비
    if ($isList) {
        $p = Get-WtMemoTextPrevLine $t $headLine
        if (-not $Outdent) {
            # 바로 위의 같은 깊이 목록 줄(새 부모)의 내용 시작 위치로. 없으면 들여쓰지 않는다(코드 블록이 됨)
            $delta = 0
            while ($p) {
                $pi = Get-WtMemoTextLineInfo $p.Text
                if (-not $pi.Blank -and $pi.W -le $head.W) {
                    if ($pi.W -eq $head.W -and $pi.List) { $delta = $pi.MW }
                    break
                }
                $p = Get-WtMemoTextPrevLine $t $p
            }
            if ($delta -le 0) { return $null }
        } else {
            # 위쪽의 더 얕은 목록 줄(부모)의 들여쓰기로
            $to = [Math]::Max(0, $head.W - 4)
            while ($p) {
                $pi = Get-WtMemoTextLineInfo $p.Text
                if (-not $pi.Blank -and $pi.W -lt $head.W) { if ($pi.List) { $to = $pi.W }; break }
                $p = Get-WtMemoTextPrevLine $t $p
            }
            $delta = - ($head.W - $to)
            if ($delta -eq 0) { $delta = -4 }
        }
    } else {
        $delta = if ($Outdent) { -4 } else { 4 }
    }

    $ops = @(foreach ($l in $group) {
            $i = Get-WtMemoTextLineInfo $l.Text
            if ($i.Blank) { continue }
            Get-WtMemoTextIndentOp $l $i $delta
        })
    if (-not $ops.Count) { return $null }
    New-WtMemoTextOpsEdit $t $ops $pos ($pos + $n)
}

# ---- Ctrl+L 할 일 ----------------------------------------------------------------------------

# 줄마다: 목록 아님 → - [ ] 붙임(빈 줄도) · 체크박스 없음 → [ ] · [ ] → [x] · [x] → [ ]
function Get-WtMemoTaskEdit($s) {
    $t = [string]$s.Text; $pos = [int]$s.Start; $n = [int]$s.Length
    $ops = @(foreach ($l in (Get-WtMemoTextSelLines $t $pos $n)) {
            $m = $script:mtList.Match($l.Text)
            if ($m.Success) {
                $at = $l.Start + $m.Groups[1].Length + $m.Groups[2].Length + $m.Groups[3].Length + $m.Groups[4].Length
                if ($m.Groups[5].Success) {
                    $mark = if ($t[$at + 1] -eq ' ') { 'x' } else { ' ' }
                    New-WtMemoTextOp ($at + 1) 1 $mark
                } else { New-WtMemoTextOp $at 0 '[ ] ' }
            } else {
                New-WtMemoTextOp ($l.Start + $script:mtLead.Match($l.Text).Length) 0 '- [ ] '
            }
        })
    New-WtMemoTextOpsEdit $t $ops $pos ($pos + $n)
}

# ---- Ctrl+K 링크 -----------------------------------------------------------------------------

function Test-WtMemoTextUrl([string]$Text) { $script:mtUrl.IsMatch($Text.Trim()) }

function Get-WtMemoLinkEdit($s) {
    $t = [string]$s.Text; $pos = [int]$s.Start; $n = [int]$s.Length
    $sel = $t.Substring($pos, $n)
    if ($sel.Contains("`n") -or $sel.Contains("`r")) { return $null }
    if (-not $n) { return New-WtMemoTextResult $pos 0 '[]()' ($pos + 1) }
    if (Test-WtMemoTextUrl $sel) { return New-WtMemoTextResult $pos $n "[]($sel)" ($pos + 1) }
    New-WtMemoTextResult $pos $n "[$sel]()" ($pos + $n + 3)
}

# ---- Alt+↑/↓ 줄 옮기기 -----------------------------------------------------------------------

function Get-WtMemoMoveLinesEdit($s, [switch]$Up) {
    $t = [string]$s.Text; $pos = [int]$s.Start; $n = [int]$s.Length
    $block = Get-WtMemoTextSelLines $t $pos $n
    if ($Up) {
        $nb = Get-WtMemoTextPrevLine $t $block[0]
        if (-not $nb) { return $null }
        $old = @($nb) + $block
        $order = @(1..$block.Count) + 0
    } else {
        $nb = Get-WtMemoTextNextLine $t $block[-1]
        if (-not $nb) { return $null }
        $old = $block + @($nb)
        $order = @($block.Count) + @(0..($block.Count - 1))
    }
    # 줄바꿈은 자리마다 그대로 두고 줄만 바꾼다. 마지막 줄 뒤 줄바꿈은 범위 밖이라 그대로 남는다
    $k = $old.Count
    $breaks = @(for ($i = 0; $i -lt $k - 1; $i++) { $t.Substring($old[$i].End, $old[$i].Next - $old[$i].End) })
    $regionStart = $old[0].Start; $regionEnd = $old[-1].End
    $newIndex = @{}
    $sb = [System.Text.StringBuilder]::new()
    $starts = @()
    for ($j = 0; $j -lt $k; $j++) {
        $newIndex[$order[$j]] = $j
        $starts += $regionStart + $sb.Length
        [void]$sb.Append($old[$order[$j]].Text)
        if ($j -lt $k - 1) { [void]$sb.Append($breaks[$j]) }
    }
    $blockIdx = @(for ($i = 0; $i -lt $block.Count; $i++) { if ($Up) { $i + 1 } else { $i } })
    $after = { param($j) if ($j -lt $k - 1) { $starts[$j + 1] } else { $old[-1].Next } }
    $map = {
        param($p)
        foreach ($i in $blockIdx) {
            if ($p -ge $old[$i].Start -and $p -le $old[$i].End) { return $starts[$newIndex[$i]] + ($p - $old[$i].Start) }
        }
        # 여러 줄 선택 끝이 다음 줄 0칸: 옮긴 묶음 바로 뒤
        & $after $newIndex[$blockIdx[-1]]
    }
    $a = & $map $pos
    $b = if ($n) { & $map ($pos + $n) } else { $a }
    New-WtMemoTextResult $regionStart ($regionEnd - $regionStart) $sb.ToString() $a ($b - $a)
}

# ---- 붙여넣기 · 끌어 놓기 --------------------------------------------------------------------

# 파일 · 폴더 경로 → [이름](<C:/경로>). 역슬래시는 / 로 (CommonMark에서 \는 이스케이프라 사라진다)
function ConvertTo-WtMemoPathLink([string]$Path, [string]$Label = '') {
    $p = $Path.Trim().Trim('"').Trim()
    $target = $p.Replace('\', '/')
    if ($target -match '^[A-Za-z]:$') { $target += '/' }
    while ($target.Length -gt 1 -and $target.EndsWith('/') -and $target -notmatch '^[A-Za-z]:/$') { $target = $target.Substring(0, $target.Length - 1) }
    if (-not $Label) {
        $parts = @($target.Split('/') | Where-Object { $_ })
        $Label = if ($target -match '^[A-Za-z]:/$') { $target.Substring(0, 2) } elseif ($parts.Count) { $parts[-1] } else { $p }
    }
    $Label = [regex]::Replace($Label, '([\\\[\]`])', '\$1')
    # 미리보기가 %xx를 풀어 읽으므로 이름에 든 %xx는 %25xx로
    $target = [regex]::Replace($target, '%(?=[0-9A-Fa-f]{2})', '%25')
    "[$Label](<$target>)"
}

function Get-WtMemoPasteEdit($s, [string]$Clip) {
    $t = [string]$s.Text; $pos = [int]$s.Start; $n = [int]$s.Length
    if (-not $Clip -or -not $Clip.Trim()) { return $null }
    $sel = $t.Substring($pos, $n)
    $oneLine = $n -gt 0 -and $sel.Trim() -and -not $sel.Contains("`n") -and -not $sel.Contains("`r")
    # 한 줄 선택 + URL 하나 → [선택](url)
    if ($oneLine -and (Test-WtMemoTextUrl $Clip) -and -not (Test-WtMemoTextUrl $sel)) {
        $ins = "[$sel]($($Clip.Trim()))"
        return New-WtMemoTextResult $pos $n $ins ($pos + $ins.Length)
    }
    # 모두 Windows 절대 경로 → 경로 링크
    $paths = @($Clip -split "`r?`n" | ForEach-Object { $_.Trim().Trim('"').Trim() } | Where-Object { $_ })
    if (-not $paths.Count -or @($paths | Where-Object { -not $script:mtPath.IsMatch($_) }).Count) { return $null }
    $label = if ($paths.Count -eq 1 -and $oneLine) { $sel.Trim() } else { '' }
    $ins = (@($paths | ForEach-Object { ConvertTo-WtMemoPathLink $_ $label }) -join (Get-WtMemoTextNewline $t))
    New-WtMemoTextResult $pos $n $ins ($pos + $ins.Length)
}

# 탐색기에서 끌어 놓은 파일 · 폴더. 여러 개이고 커서가 줄 중간이면 앞에 줄바꿈 하나
function Get-WtMemoDropEdit($s, [string[]]$Paths) {
    $t = [string]$s.Text; $pos = [int]$s.Start; $n = [int]$s.Length
    $list = @($Paths | Where-Object { $_ -and $_.Trim() })
    if (-not $list.Count) { return $null }
    $nl = Get-WtMemoTextNewline $t
    $ins = (@($list | ForEach-Object { ConvertTo-WtMemoPathLink $_ }) -join $nl)
    if ($list.Count -gt 1 -and $pos -gt (Get-WtMemoTextLine $t $pos).Start) { $ins = $nl + $ins }
    New-WtMemoTextResult $pos $n $ins ($pos + $ins.Length)
}

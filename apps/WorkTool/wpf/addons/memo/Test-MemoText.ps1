<#
.SYNOPSIS
    메모 편집 명령(MemoText.psm1)을 검사한다: 감싸기 · 글자 입력 · Enter · Tab · 할 일 · 링크 · 줄 옮기기 · 붙여넣기 · 끌어 놓기.

.DESCRIPTION
    tests\Test-Core.ps1이 찾아서 돌린다. 혼자 돌려도 된다. WPF 없이 돌아간다.
    검사 글 표기: ¶ = 줄바꿈, | = 커서, «…» = 선택. 줄바꿈은 `n 글과 `r`n 글 두 가지로 돌린다.
    편집을 글에 적용한 결과(글 · 선택)를 같은 표기로 바꿔 기대 문자열과 비교한다.

.EXAMPLE
    pwsh -NoProfile -File apps/WorkTool/wpf/addons/memo/Test-MemoText.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'MemoText.psm1') -Force -DisableNameChecking

# ---- 검사 도우미 --------------------------------------------------------------------------------

$both = @("`n", "`r`n")
$crlf = @("`r`n")

function ConvertFrom-MtCase([string]$Marked, [string]$Nl) {
    $x = $Marked.Replace('¶', $Nl)
    $i = $x.IndexOf('«')
    if ($i -ge 0) {
        $j = $x.IndexOf('»')
        return @{ Text = $x.Remove($j, 1).Remove($i, 1); Start = $i; Length = $j - $i - 1 }
    }
    $i = $x.IndexOf('|')
    if ($i -lt 0) { throw "검사 글에 커서(|)가 없습니다: $Marked" }
    @{ Text = $x.Remove($i, 1); Start = $i; Length = 0 }
}

function ConvertTo-MtCase([string]$Text, [int]$Start, [int]$Length, [string]$Nl) {
    $x = if ($Length -gt 0) { $Text.Insert($Start + $Length, '»').Insert($Start, '«') } else { $Text.Insert($Start, '|') }
    $x.Replace($Nl, '¶')
}

function Show-MtText([string]$Text) { $Text.Replace("`r", '\r').Replace("`n", '\n') }

# 편집 하나를 글에 적용한다. 모양이 틀리면(배열 · 범위 밖 · `r`n 가르기 · 줄바꿈 섞임) 멈춘다
function Invoke-MtEdit($S, $E, [string]$Nl) {
    if ($E -isnot [hashtable]) { throw "편집이 하나(hashtable)가 아닙니다: $($E.GetType().Name)" }
    foreach ($k in 'Start', 'Length', 'Insert', 'SelStart', 'SelLength') { if (-not $E.ContainsKey($k)) { throw "편집에 $k 가 없습니다" } }
    $t = [string]$S.Text
    if ($E.Start -lt 0 -or $E.Length -lt 0 -or $E.Start + $E.Length -gt $t.Length) { throw "편집 범위가 글 밖입니다 ($($E.Start), $($E.Length))" }
    foreach ($p in $E.Start, ($E.Start + $E.Length)) {
        if ($p -gt 0 -and $p -lt $t.Length -and $t[$p - 1] -eq "`r" -and $t[$p] -eq "`n") { throw "편집이 \r\n 사이를 가릅니다 ($p)" }
    }
    $new = $t.Remove($E.Start, $E.Length).Insert($E.Start, [string]$E.Insert)
    if ($E.SelStart -lt 0 -or $E.SelLength -lt 0 -or $E.SelStart + $E.SelLength -gt $new.Length) { throw "선택이 글 밖입니다 ($($E.SelStart), $($E.SelLength))" }
    $rest = if ($Nl -eq "`r`n") { $new.Replace("`r`n", '') } else { $new }
    if ($rest.Contains("`r") -or ($Nl -eq "`r`n" -and $rest.Contains("`n"))) { throw "줄바꿈이 섞였습니다: $(Show-MtText $new)" }
    @{ Text = $new; Start = [int]$E.SelStart; Length = [int]$E.SelLength }
}

$script:mtCount = 0

# 검사 하나: $Case에 $Do를 하고 결과가 $Expect인지. $Expect가 '<null>'이면 할 일 없음($null)
function Test-MtCase([string]$Name, [string]$Case, [scriptblock]$Do, [string]$Expect, [string[]]$Nls = $both) {
    foreach ($nl in $Nls) {
        $s = ConvertFrom-MtCase $Case $nl
        $e = & $Do $s
        if ($Expect -ceq '<null>') {
            if ($null -ne $e) { throw "FAIL $Name ($(Show-MtText $nl)): `$null이어야 하는데 편집이 나왔습니다" }
            continue
        }
        if ($null -eq $e) { throw "FAIL $Name ($(Show-MtText $nl)): 편집이 없습니다" }
        $r = Invoke-MtEdit $s $e $nl
        $got = ConvertTo-MtCase $r.Text $r.Start $r.Length $nl
        if ($got -cne $Expect) { throw "FAIL $Name ($(Show-MtText $nl)): 기대 [$Expect] 결과 [$got]" }
    }
    $script:mtCount++
    Assert-WtTest $Name $true
}

# 같은 명령을 두 번 하면 처음 글로 돌아오는지 (토글 왕복)
function Test-MtRoundTrip([string]$Name, [string]$Case, [scriptblock]$Do) {
    foreach ($nl in $both) {
        $s = ConvertFrom-MtCase $Case $nl
        $r1 = Invoke-MtEdit $s (& $Do $s) $nl
        $r2 = Invoke-MtEdit $r1 (& $Do $r1) $nl
        $got = ConvertTo-MtCase $r2.Text $r2.Start $r2.Length $nl
        if ($got -cne $Case) { throw "FAIL $Name ($(Show-MtText $nl)): 기대 [$Case] 결과 [$got]" }
    }
    $script:mtCount++
    Assert-WtTest $Name $true
}

function Assert-MtTest([string]$Name, [bool]$Ok, $Detail = '') { $script:mtCount++; Assert-WtTest $Name $Ok $Detail }

$bold = { param($s) Get-WtMemoWrapEdit $s '**' }
$ital = { param($s) Get-WtMemoWrapEdit $s '*' }
$strike = { param($s) Get-WtMemoWrapEdit $s '~~' }
$code = { param($s) Get-WtMemoWrapEdit $s '`' }
$tick = { param($s) Get-WtMemoTypeEdit $s '`' }
$open = { param($s) Get-WtMemoTypeEdit $s '[' }
$close = { param($s) Get-WtMemoTypeEdit $s ']' }
$enter = { param($s) Get-WtMemoEnterEdit $s }
$tab = { param($s) Get-WtMemoIndentEdit $s }
$untab = { param($s) Get-WtMemoIndentEdit $s -Outdent }
$task = { param($s) Get-WtMemoTaskEdit $s }
$link = { param($s) Get-WtMemoLinkEdit $s }
$up = { param($s) Get-WtMemoMoveLinesEdit $s -Up }
$down = { param($s) Get-WtMemoMoveLinesEdit $s }

# ---- 감싸기: 선택 있음 ---------------------------------------------------------------------------

Test-MtCase '굵게: 선택을 감싼다 (한글)' '가 «나다» 라' $bold '가 **«나다»** 라'
Test-MtCase '굵게: 선택 앞뒤 공백은 표지 밖에 둔다' '가« 나다 »라' $bold '가 **«나다»** 라'
Test-MtCase '굵게: 선택 안쪽 표지를 벗긴다' '«**나다**»' $bold '«나다»'
Test-MtCase '굵게: 선택 바로 바깥 표지를 벗긴다' '**«나다»**' $bold '«나다»'
Test-MtCase '기울임: 굵게 위에 더한다' '**«나다»**' $ital '***«나다»***'
Test-MtCase '기울임: 선택 안의 굵게는 그대로 두고 감싼다' '«**나다**»' $ital '*«**나다**»*'
Test-MtCase '기울임: ***에서 기울임만 끈다' '***«나다»***' $ital '**«나다»**'
Test-MtCase '굵게: ***에서 굵게만 끈다' '***«나다»***' $bold '*«나다»*'
Test-MtCase '기울임: 선택 안쪽 기울임을 끈다' '«*나다*»' $ital '«나다»'
Test-MtCase '취소선: 감싼다' 'a «b» c' $strike 'a ~~«b»~~ c'
Test-MtCase '여러 줄: 줄마다 내용만 감싸고 빈 줄은 둔다' '- «사과¶- [ ] 배¶¶> 감»' $bold '- **«사과**¶- [ ] **배**¶¶> **감»**'
Test-MtCase '여러 줄: 들여쓴 번호 목록 · 제목 뒤를 감싼다' '«  1. 하나¶# 제목»' $bold '  1. **«하나**¶# **제목»**'
Test-MtCase '여러 줄: 일부만 굵으면 나머지만 감싼다' '«**a**¶b»' $bold '«**a**¶**b»**'
Test-MtCase '감싸기: 공백만 선택하면 할 일 없음' 'a« »b' $bold '<null>'
Test-MtRoundTrip '굵게 왕복: 한 줄' '가 «나다» 라' $bold
Test-MtRoundTrip '기울임 왕복: 굵게 위' '**«나다»**' $ital
Test-MtRoundTrip '취소선 왕복' 'a «b c» d' $strike
Test-MtRoundTrip '굵게 왕복: 여러 줄' '- «사과¶- [ ] 배¶¶> 감»' $bold

# ---- 감싸기: 선택 없음 ---------------------------------------------------------------------------

Test-MtCase '굵게 · 선택 없음: 빈 짝 사이면 짝을 지운다' 'a **|** b' $bold 'a | b'
Test-MtCase '기울임 · 선택 없음: ***|***에서 기울임 짝만 지운다' 'a ***|***' $ital 'a **|**'
Test-MtCase '굵게 · 선택 없음: 낱말 안이면 낱말을 감싼다' '가나|다 라' $bold '**가나|다** 라'
Test-MtCase '굵게 · 선택 없음: 낱말 끝' '가나다| 라' $bold '**가나다|** 라'
Test-MtCase '굵게 · 선택 없음: 감싼 낱말이면 벗긴다' '**가나|다** 라' $bold '가나|다 라'
Test-MtCase '기울임 · 선택 없음: 굵은 낱말은 *** 로' '**가|나**' $ital '***가|나***'
Test-MtCase '굵게 · 선택 없음: 문장부호 뒤는 짝을 넣는다' '가, |' $bold '가, **|**'
Test-MtCase '굵게 · 선택 없음: 빈 글' '|' $bold '**|**'
Test-MtCase '굵게 · 선택 없음: 글 처음(낱말 앞)은 짝을 넣는다' '|abc' $bold '**|**abc'
Test-MtCase '굵게 · 선택 없음: 글 끝 낱말' 'abc|' $bold '**abc|**'
Test-MtCase '코드 · 선택 없음: 낱말 감싸기' 'ls|' $code '`ls|`'
Test-MtCase '코드 · 선택 없음: 낱말 벗기기' '`ls|`' $code 'ls|'
Test-MtCase '코드 · 선택 없음: 빈 짝 지우기' '`|`' $code '|'
Test-MtRoundTrip '굵게 왕복: 선택 없음 · 낱말' '가나|다 라' $bold

# ---- 인라인 코드 ---------------------------------------------------------------------------------

Test-MtCase '코드: 선택을 감싼다' '«ls -al»' $code '`«ls -al»`'
Test-MtCase '코드: 글에 `가 있으면 더 긴 백틱 + 공백' '«a`b»' $code '`` «a`b» ``'
Test-MtCase '코드: 안쪽 표지를 벗긴다' '«`a`»' $code '«a»'
Test-MtCase '코드: 공백 패딩 바깥 표지를 벗긴다' '`` «a`b» ``' $code '«a`b»'
Test-MtCase '코드: 이웃한 코드 사이 낱말은 코드로 오해하지 않는다' '`a` «b» `c`' $code '`a` `«b»` `c`'
Test-MtRoundTrip '코드 왕복: `가 든 글' '«a`b»' $code

# ---- 글자 입력 ---------------------------------------------------------------------------------

Test-MtCase '` 입력: 한 줄 선택은 인라인 코드' '가 «ls» 나' $tick '가 `«ls»` 나'
Test-MtCase '` 입력: 여러 줄 선택은 코드 블록' 'a¶«b¶c»¶d' $tick 'a¶```¶«b¶c»¶```¶d'
Test-MtCase '` 입력: 여러 줄 선택 끝이 다음 줄 0칸이면 그 줄은 뺀다' '«b¶c¶»d' $tick '```¶«b¶c»¶```¶d'
Test-MtCase '` 입력: 안에 ```가 있으면 더 긴 울타리' '«```¶x¶```»' $tick '````¶«```¶x¶```»¶````'
Test-MtCase '` 입력: 줄 앞 ```이면 닫는 울타리를 넣는다' 'a¶``|' $tick 'a¶```|¶```'
Test-MtCase '` 입력: 닫는 울타리도 같은 들여쓰기' '- a¶  ``|' $tick '- a¶  ```|¶  ```'
Test-MtCase '` 입력: 줄바꿈 없는 글은 \r\n' '``|' $tick '```|¶```' $crlf
Test-MtCase '` 입력: 열린 울타리 안(위쪽 홀수)이면 그대로' '```¶x¶``|' $tick '<null>'
Test-MtCase '` 입력: 아래에 짝 없는 울타리가 있으면 그대로' '``|¶x¶```' $tick '<null>'
Test-MtCase '` 입력: 커서 뒤에 글이 있으면 그대로' '``|a' $tick '<null>'
Test-MtCase '` 입력: 앞 공백 4칸이면 그대로' '    ``|' $tick '<null>'
Test-MtCase '` 입력: 그 밖에는 그대로' 'a|' $tick '<null>'
Test-MtCase '[ 입력: [[ ]] 짝을 넣는다' 'a [|' $open 'a [[|]]'
$wiki = Get-WtMemoTypeEdit @{ Text = 'a ['; Start = 3; Length = 0 } '['
Assert-MtTest '[ 입력: 자동 완성 표시(Suggest = wiki)' ($wiki.Suggest -eq 'wiki')
Test-MtCase '[ 입력: 세 번째 [는 그대로' '[[|' $open '<null>'
Test-MtCase '[ 입력: 커서 뒤가 ]면 그대로' '[|]' $open '<null>'
Test-MtCase '] 입력: 닫는 ]를 넘긴다' '[[abc|]]' $close '[[abc]|]'
Test-MtCase '] 입력: 두 번째 ]도 넘긴다' '[[abc]|]' $close '[[abc]]|'
Test-MtCase '] 입력: [[가 없으면 그대로' 'a|]' $close '<null>'
Test-MtCase '] 입력: 이미 닫힌 [[ ]] 뒤면 그대로' '[[a]] b|]' $close '<null>'
Test-MtCase '다른 글자는 그대로' 'a|' { param($s) Get-WtMemoTypeEdit $s 'x' } '<null>'

# ---- Enter -----------------------------------------------------------------------------------

Test-MtCase 'Enter: 목록을 잇는다 (한글)' '메모¶- 사과|' $enter '메모¶- 사과¶- |'
Test-MtCase 'Enter: 줄바꿈 없는 글은 \r\n' '- a|' $enter '- a¶- |' $crlf
Test-MtCase 'Enter: 커서 자리에서 나누고 뒤 공백은 뗀다' '메모¶- 사과| 배' $enter '메모¶- 사과¶- |배'
Test-MtCase 'Enter: 번호 +1 (자릿수 늘어남)' '메모¶9. a|' $enter '메모¶9. a¶10. |'
Test-MtCase 'Enter: 번호 구분자 ) 유지' '메모¶1) a|' $enter '메모¶1) a¶2) |'
Test-MtCase 'Enter: 체크박스는 [ ]로' '메모¶  - [x] a|' $enter '메모¶  - [x] a¶  - [ ] |'
Test-MtCase 'Enter: * 표지 유지' '메모¶* a|' $enter '메모¶* a¶* |'
Test-MtCase 'Enter: 커서가 표지 안쪽이면 그대로' '메모¶-| a' $enter '<null>'
Test-MtCase 'Enter: 들여쓰기 없는 빈 항목은 목록 끝' '- a¶- |' $enter '- a¶|'
Test-MtCase 'Enter: 빈 체크박스 항목도 목록 끝' '- [ ] a¶- [ ] |' $enter '- [ ] a¶|'
Test-MtCase 'Enter: 들여쓴 빈 항목은 한 단계 내어쓰기' '- a¶  - |' $enter '- a¶- |'
Test-MtCase 'Enter: 번호 목록 내어쓰기는 부모 다음 번호' '1. a¶   1. |' $enter '1. a¶2. |'
Test-MtCase 'Enter: 세 단계에서 한 단계만' '- a¶    - b¶      - |' $enter '- a¶    - b¶    - |'
Test-MtCase 'Enter: 인용을 잇는다' '메모¶> 인용|' $enter '메모¶> 인용¶> |'
Test-MtCase 'Enter: 빈 인용은 접두어를 지운다' '> 가¶> |' $enter '> 가¶|'
Test-MtCase 'Enter: 인용 안 목록' '메모¶> - a|' $enter '메모¶> - a¶> - |'
Test-MtCase 'Enter: 인용 안 빈 항목은 표지만 지운다' '메모¶> - |' $enter '메모¶> |'
Test-MtCase 'Enter: 커서가 인용 접두어 안이면 그대로' '메모¶>| a' $enter '<null>'
Test-MtCase 'Enter: 코드 울타리 안은 앞 공백 유지' '```¶  code|' $enter '```¶  code¶  |'
Test-MtCase 'Enter: 코드 울타리 안 목록 모양 줄은 잇지 않는다' '```¶- a|' $enter '```¶- a¶|'
Test-MtCase 'Enter: 닫힌 울타리 뒤는 그대로' '```¶a¶```|' $enter '<null>'
Test-MtCase 'Enter: 보통 줄은 그대로' '메모¶abc|' $enter '<null>'
Test-MtCase 'Enter: 선택이 있으면 그대로' '- «a»' $enter '<null>'

# ---- Tab / Shift+Tab -------------------------------------------------------------------------

Test-MtCase 'Tab: 같은 깊이 위 항목 아래로 (- 는 2칸)' '- a¶- |b' $tab '- a¶  - |b'
Test-MtCase 'Tab: 번호 부모 아래는 3칸' '1. a¶1. |b' $tab '1. a¶   1. |b'
Test-MtCase 'Tab: 체크박스 부모도 표지 너비만큼' '- [ ] a¶- [ ] |b' $tab '- [ ] a¶  - [ ] |b'
Test-MtCase 'Tab: 자식 줄을 같이 옮긴다' '- a¶- |b¶  - c¶- d' $tab '- a¶  - |b¶    - c¶- d'
Test-MtCase 'Tab: 위 형제의 자식을 건너 형제를 부모로' '- a¶  - b¶- |c' $tab '- a¶  - b¶  - |c'
Test-MtCase 'Tab: 부모가 없으면 그대로' '- |a' $tab '<null>'
Test-MtCase 'Shift+Tab: 부모 들여쓰기로 · 자식도 같이' '- a¶  - |b¶    - c' $untab '- a¶- |b¶  - c'
Test-MtCase 'Shift+Tab: 번호 목록' '1. a¶   1. |b' $untab '1. a¶1. |b'
Test-MtCase 'Shift+Tab: 맨 바깥 항목은 그대로' '- |a¶  - b' $untab '<null>'
Test-MtCase 'Shift+Tab: 탭 들여쓰기도 내어쓴다' ("- a¶`t- |b") $untab '- a¶- |b'
Test-MtCase 'Tab: 목록 아닌 한 줄 · 선택 없음은 그대로' 'a|b' $tab '<null>'
Test-MtCase 'Shift+Tab: 목록 아닌 줄은 4칸 내어쓰기' '      a|' $untab '  a|'
Test-MtCase 'Shift+Tab: 앞 공백이 4칸보다 적으면 모두' '  |a' $untab '|a'
Test-MtCase 'Shift+Tab: 앞 공백이 없으면 그대로' '|a' $untab '<null>'
Test-MtCase 'Tab: 여러 줄은 4칸씩' '«a¶b»' $tab '    «a¶    b»'
Test-MtCase 'Shift+Tab: 여러 줄' '«    a¶  b»' $untab '«a¶b»'
Test-MtCase 'Tab: 여러 줄 선택 끝이 다음 줄 0칸이면 그 줄은 뺀다' '«a¶»b' $tab '    «a¶»b'
Test-MtCase 'Tab: 여러 줄 목록은 부모 기준' '- a¶«- b¶- c»' $tab '- a¶  «- b¶  - c»'
Test-MtCase 'Tab: 한 줄 안 선택은 그 줄을 들여쓴다' 'x «a» y' $tab '    x «a» y'
Test-MtCase 'Tab: 코드 울타리 안 목록 모양 줄은 그대로' '```¶- a¶- |b' $tab '<null>'
foreach ($nl in $both) {
    $s = ConvertFrom-MtCase '- a¶- |b¶  - c' $nl
    $r = Invoke-MtEdit $s (Get-WtMemoIndentEdit $s) $nl
    $r = Invoke-MtEdit $r (Get-WtMemoIndentEdit $r -Outdent) $nl
    if ((ConvertTo-MtCase $r.Text $r.Start $r.Length $nl) -cne '- a¶- |b¶  - c') { throw "FAIL Tab → Shift+Tab 왕복 ($(Show-MtText $nl))" }
}
Assert-MtTest 'Tab → Shift+Tab 왕복: 목록 · 자식' $true

# ---- Ctrl+L 할 일 ----------------------------------------------------------------------------

Test-MtCase '할 일: 보통 줄에 - [ ] 붙임' 'x¶|a' $task 'x¶- [ ] |a'
Test-MtCase '할 일: 목록에 [ ] 붙임' 'x¶- |a' $task 'x¶- [ ] |a'
Test-MtCase '할 일: [ ] → [x]' 'x¶- [ ] |a' $task 'x¶- [x] |a'
Test-MtCase '할 일: [X] → [ ]' 'x¶- [X] |a' $task 'x¶- [ ] |a'
Test-MtCase '할 일: 빈 글' '|' $task '- [ ] |'
Test-MtCase '할 일: 들여쓰기 유지' '  |a' $task '  - [ ] |a'
Test-MtCase '할 일: 인용 안' '> |a' $task '> - [ ] |a'
Test-MtCase '할 일: 번호 목록' '1. |a' $task '1. [ ] |a'
Test-MtCase '할 일: 여러 줄은 줄마다' '«a¶- b¶- [ ] c¶- [x] d»' $task '- [ ] «a¶- [ ] b¶- [x] c¶- [ ] d»'
Test-MtCase '할 일: 여러 줄의 빈 줄도' '«a¶¶b»' $task '- [ ] «a¶- [ ] ¶- [ ] b»'

# ---- Ctrl+K 링크 -----------------------------------------------------------------------------

Test-MtCase '링크: URL 선택 → [](url), 커서는 [] 안' 'a «https://x.com/p?q=1» b' $link 'a [|](https://x.com/p?q=1) b'
Test-MtCase '링크: www. 도 URL' '«www.x.com»' $link '[|](www.x.com)'
Test-MtCase '링크: 글 선택 → [글](), 커서는 () 안' '«이름»' $link '[이름](|)'
Test-MtCase '링크: 선택 없음 → []()' 'a | b' $link 'a [|]() b'
Test-MtCase '링크: 여러 줄 선택은 그대로' '«a¶b»' $link '<null>'

# ---- Alt+↑/↓ 줄 옮기기 -----------------------------------------------------------------------

Test-MtCase '줄 옮기기: 위로' 'a¶|b¶c' $up '|b¶a¶c'
Test-MtCase '줄 옮기기: 아래로' 'a¶|b¶c' $down 'a¶c¶|b'
Test-MtCase '줄 옮기기: 맨 위는 그대로' '|a¶b' $up '<null>'
Test-MtCase '줄 옮기기: 맨 아래는 그대로' 'a¶|b' $down '<null>'
Test-MtCase '줄 옮기기: 줄바꿈 없는 마지막 줄을 위로' 'a¶b|' $up 'b|¶a'
Test-MtCase '줄 옮기기: 줄바꿈 없는 마지막 줄 자리로' 'a|¶b' $down 'b¶a|'
Test-MtCase '줄 옮기기: 여러 줄 위로' 'a¶«b¶c»¶d' $up '«b¶c»¶a¶d'
Test-MtCase '줄 옮기기: 여러 줄 아래로' 'a¶«b¶c»¶d' $down 'a¶d¶«b¶c»'
Test-MtCase '줄 옮기기: 선택 끝이 다음 줄 0칸 (아래로)' '«a¶»b¶c' $down 'b¶«a¶»c'
Test-MtCase '줄 옮기기: 선택 끝이 다음 줄 0칸 (위로)' 'a¶«b¶»c' $up '«b¶»a¶c'
Test-MtCase '줄 옮기기: 한글 · 커서 칸 유지' '가나¶다|라' $up '다|라¶가나'
Test-MtCase '줄 옮기기: 한 줄뿐이면 그대로' '|a' $down '<null>'
Test-MtCase '줄 옮기기: 빈 글' '|' $up '<null>'

# ---- 붙여넣기 · 경로 링크 · 끌어 놓기 --------------------------------------------------------

$url = { param($s) Get-WtMemoPasteEdit $s '  https://x.com ' }
Test-MtCase '붙여넣기: 한 줄 선택 + URL → [선택](url)' '가 «이름» 나' $url '가 [이름](https://x.com)| 나'
Test-MtCase '붙여넣기: 선택이 URL이면 그대로' '«https://a.com»' $url '<null>'
Test-MtCase '붙여넣기: 선택 없이 URL은 그대로' '가 | 나' $url '<null>'
Test-MtCase '붙여넣기: 여러 줄 선택 + URL은 그대로' '«a¶b»' $url '<null>'
Test-MtCase '붙여넣기: 경로 → 링크 (공백 · / 바꿈)' '|' { param($s) Get-WtMemoPasteEdit $s 'C:\a b\c.txt' } '[c.txt](<C:/a b/c.txt>)|'
Test-MtCase '붙여넣기: 여러 경로 (따옴표 · UNC · 빈 줄)' 'x¶|' { param($s) Get-WtMemoPasteEdit $s "`"C:\x\y.txt`"`r`n\\srv\share\z`r`n" } 'x¶[y.txt](<C:/x/y.txt>)¶[z](<//srv/share/z>)|'
Test-MtCase '붙여넣기: 경로 하나 + 한 줄 선택 → 선택이 이름표' '«보고서»' { param($s) Get-WtMemoPasteEdit $s 'D:\docs\r.xlsx' } '[보고서](<D:/docs/r.xlsx>)|'
Test-MtCase '붙여넣기: 경로가 아닌 줄이 섞이면 그대로' '|' { param($s) Get-WtMemoPasteEdit $s "C:\a`nhello" } '<null>'
Test-MtCase '붙여넣기: 드라이브만' '|' { param($s) Get-WtMemoPasteEdit $s 'C:' } '[C:](<C:/>)|'

Assert-MtTest '경로 링크: 드라이브 루트' ((ConvertTo-WtMemoPathLink 'C:\') -ceq '[C:](<C:/>)')
Assert-MtTest '경로 링크: UNC 공유 루트 (끝 \ 뗌)' ((ConvertTo-WtMemoPathLink '\\srv\share\') -ceq '[share](<//srv/share>)')
Assert-MtTest '경로 링크: 폴더 끝 \ 뗌' ((ConvertTo-WtMemoPathLink 'C:\dir\') -ceq '[dir](<C:/dir>)')
Assert-MtTest '경로 링크: 이름표 [ ] ` \ 이스케이프' ((ConvertTo-WtMemoPathLink 'C:\a[1]`b.txt') -ceq '[a\[1\]\`b.txt](<C:/a[1]`b.txt>)') (ConvertTo-WtMemoPathLink 'C:\a[1]`b.txt')
Assert-MtTest '경로 링크: 이름표를 받는다' ((ConvertTo-WtMemoPathLink 'C:\a' 'x\y') -ceq '[x\\y](<C:/a>)')
Assert-MtTest '경로 링크: %xx는 %25xx' ((ConvertTo-WtMemoPathLink 'C:\100%41.txt') -ceq '[100%41.txt](<C:/100%2541.txt>)')

# 미리보기(Markdig)가 의도대로 읽는지: 파일 링크 · 원래 경로 · 이름표
$checks = @(
    @{ Path = 'C:\a b\c.txt'; Label = 'c.txt' }
    @{ Path = '\\srv\share\x y\z.docx'; Label = 'z.docx' }
    @{ Path = 'C:\a[1]`b_c.txt'; Label = 'a[1]`b_c.txt' }
    @{ Path = 'C:\100%41.txt'; Label = '100%41.txt' }
)
foreach ($c in $checks) {
    $model = ConvertTo-WtMarkdownModel (ConvertTo-WtMemoPathLink $c.Path)
    $l = @($model.Blocks[0].Inl | Where-Object { $_.T -eq 'link' })[0]
    $text = (@($l.Inl | ForEach-Object { $_.Text }) -join '')
    $full = [System.IO.Path]::GetFullPath($l.Target)
    Assert-MtTest "경로 링크 미리보기: $($c.Path)" ($l.Kind -eq 'file' -and $full -ceq $c.Path -and $text -ceq $c.Label) "($($l.Kind) / $($l.Target) / $text)"
}

$drop1 = { param($s) Get-WtMemoDropEdit $s @('C:\x') }
$drop2 = { param($s) Get-WtMemoDropEdit $s @('C:\a', 'C:\b') }
Test-MtCase '끌어 놓기: 하나는 커서 자리에' '가 |나' $drop1 '가 [x](<C:/x>)|나'
Test-MtCase '끌어 놓기: 여러 개 · 줄 중간이면 앞에 줄바꿈' 'm¶가 |나' $drop2 'm¶가 ¶[a](<C:/a>)¶[b](<C:/b>)|나'
Test-MtCase '끌어 놓기: 여러 개 · 줄 처음' 'm¶|' $drop2 'm¶[a](<C:/a>)¶[b](<C:/b>)|'
Test-MtCase '끌어 놓기: 선택을 바꾼다' '«old»' $drop1 '[x](<C:/x>)|'
Test-MtCase '끌어 놓기: 경로 없음' '|' { param($s) Get-WtMemoDropEdit $s @() } '<null>'

Write-Host "메모 편집 명령 검사 $($script:mtCount)개 통과"

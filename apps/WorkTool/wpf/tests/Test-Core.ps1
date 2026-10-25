<#
.SYNOPSIS
    WorkTool 새 버전 검사를 모두 돌린다: 코어 검사 → 탭 모아 보기 → 탭 폴더의 검사 → 안정성 · 실행 파일 검사.

.DESCRIPTION
    - 코어: 코드 검사 · 저장 · 설정 · 탭 목록 · 예전 데이터 가져오기 흐름 · 도움말 · 테마 색 대비 · 마크다운 · 코드 색칠 · Mermaid.
      탭이 필요한 곳은 가짜 탭을 등록해서 본다. 진짜 탭의 동작은 그 탭 폴더의 검사가 맡는다.
    - 탭 모아 보기: 앱처럼 모든 탭을 함께 불러와서 ID · 함수 이름이 겹치지 않는지, 도움말이 모든 탭을 싣는지 본다.
    - 탭 폴더의 검사(addons\<이름>\Test-*.ps1)는 찾아서 돌린다. 탭을 더하거나 빼도 이 파일은 고치지 않는다.
    임시 폴더만 쓰고, 문서\WorkTool 같은 실제 데이터 폴더는 건드리지 않는다. 화면 검사는 Windows STA에서만 한다.

.EXAMPLE
    pwsh ./apps/WorkTool/wpf/tests/Test-Core.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-WtTestCore

$script:failed = 0
function Assert-Wt([string]$Name, [bool]$Ok, $Detail = '') {
    if ($Ok) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name $Detail" -ForegroundColor Red; $script:failed++ }
}

$test = New-WtTestData 'core'
$wpf = Test-WtTestWpf

try {
    # ---- 코드 검사 ----
    # PowerShell 변수는 대소문자를 가리지 않는다. 함수 안에서 $title과 [string]$Title처럼 대소문자만 다른 이름을 쓰면 같은 변수가 된다
    $clash = foreach ($f in (Get-ChildItem $root -Recurse -Include *.psm1, *.ps1)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $names = @($fn.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $false) |
                    ForEach-Object { $_.VariablePath.UserPath } | Where-Object { $_ -notmatch ':' })
            $plist = if ($fn.Parameters) { $fn.Parameters } elseif ($fn.Body.ParamBlock) { $fn.Body.ParamBlock.Parameters } else { @() }
            $names += @($plist | ForEach-Object { $_.Name.VariablePath.UserPath })
            $names | Group-Object { $_.ToLowerInvariant() } | Where-Object { @($_.Group | Sort-Object -Unique -CaseSensitive).Count -gt 1 } |
                ForEach-Object { "$($f.Name) $($fn.Name): $(@($_.Group | Sort-Object -Unique -CaseSensitive) -join '/')" }
        }
    }
    Assert-Wt '코드 검사: 함수 안에 대소문자만 다른 변수 이름 없음' (-not $clash) ($clash -join '; ')

    # ---- 저장 ----
    Assert-Wt '데이터 폴더는 datapath.txt를 따른다' ((Get-WtDataRoot) -eq (Resolve-Path $test.Data).ProviderPath)

    Write-WtStore -Name 'sample' -Items @([ordered]@{ id = 'x1'; title = '한글 제목'; tags = @() })
    $one = Get-WtStoreItems -Name 'sample'
    Assert-Wt '항목 하나도 배열로 읽힌다' ($one -is [array] -and $one.Count -eq 1 -and $one[0].title -eq '한글 제목')
    Assert-Wt 'JSON에 한글이 그대로 저장된다' ((Get-Content (Get-WtStorePath 'sample') -Raw -Encoding utf8) -match '한글 제목')
    Write-WtStore -Name 'sample' -Items @()
    Assert-Wt '빈 목록 저장 · 읽기' ((Get-WtStoreItems -Name 'sample').Count -eq 0)
    Assert-Wt '덮어쓸 때 .bak을 남긴다' (Test-Path ((Get-WtStorePath 'sample') + '.bak'))
    Assert-Wt '없는 저장소는 빈 배열' ((Get-WtStoreItems -Name 'nothing').Count -eq 0)
    $missingStamp = Get-WtStoreStamp 'cache-sample'
    Write-WtStore cache-sample -Items @([ordered]@{ id = 'c1'; title = '캐시-A' })
    $cacheStamp = Get-WtStoreStamp 'cache-sample'
    Assert-Wt '저장 표식: 생성·같은 파일 반복 조회' ($missingStamp -cne $cacheStamp -and $cacheStamp -ceq (Get-WtStoreStamp 'cache-sample'))
    $cachePath = Get-WtStorePath 'cache-sample'
    $cacheTime = [IO.File]::GetLastWriteTimeUtc($cachePath)
    [IO.File]::WriteAllText($cachePath, [IO.File]::ReadAllText($cachePath).Replace('캐시-A','캐시-B'), [Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($cachePath, $cacheTime)
    Assert-Wt '저장 표식: 크기·시각이 같아도 본문 변경을 알아본다' ($cacheStamp -cne (Get-WtStoreStamp 'cache-sample') -and (Get-WtStoreItems 'cache-sample')[0].title -eq '캐시-B')
    $cacheLock = [IO.File]::Open($cachePath, 'Open', 'ReadWrite', 'None')
    try { $locked1 = Get-WtStoreStamp 'cache-sample'; $locked2 = Get-WtStoreStamp 'cache-sample' } finally { $cacheLock.Dispose() }
    Assert-Wt '저장 표식: 다른 프로그램이 파일을 잡고 있어도 멈추지 않고, 매번 다시 읽게 한다' ($locked1 -cne $locked2)

    Write-WtStore -Name 'mig' -Schema 1 -Items @([ordered]@{ id = 'm1' })
    $doc = Read-WtStore -Name 'mig' -Schema 2 -Migrate {
        param($d, $from)
        foreach ($i in $d.items) { $i | Add-Member -NotePropertyName extra -NotePropertyValue "from$from" -Force }
        $d
    }
    Assert-Wt '형식 변환: schema 1 → 2' ($doc.schema -eq 2 -and $doc.items[0].extra -eq 'from1')
    Assert-Wt '형식 변환 전 원본을 남긴다' (Test-Path ((Get-WtStorePath 'mig') + '.schema1.bak'))
    $threw = $false
    try { [void](Read-WtStore -Name 'mig' -Schema 1) } catch { $threw = $true }
    Assert-Wt '더 새 형식 파일은 읽지 않고 멈춘다' $threw

    # ---- 설정 ----
    Initialize-WtSettings
    Assert-Wt '설정 기본값' ((Get-WtSetting 'theme.color') -eq 'sky' -and (Get-WtSetting 'ui.opacity') -eq 100)
    Register-WtSettingHandler { param($k, $v) $script:seenKey = $k }
    Set-WtSetting 'theme.color' 'pink'
    Set-WtSetting 'addons.disabled' @('test-b')
    Assert-Wt '설정이 바뀌면 처리기를 부른다' ($script:seenKey -eq 'addons.disabled')
    $saved = Get-Content (Get-WtSettingsPath) -Raw | ConvertFrom-Json
    Assert-Wt '바꾼 값만 저장한다' (@($saved.values.PSObject.Properties.Name).Count -eq 2 -and $saved.values.'theme.color' -eq 'pink')
    Set-WtSetting 'theme.color' 'sky'
    $saved = Get-Content (Get-WtSettingsPath) -Raw | ConvertFrom-Json
    Assert-Wt '기본값으로 돌리면 파일에서 빠진다' (-not ($saved.values.PSObject.Properties.Name -contains 'theme.color'))
    Initialize-WtSettings
    Assert-Wt '배열 설정을 다시 읽는다' (@(Get-WtSetting 'addons.disabled') -contains 'test-b')

    # ---- 탭 목록 (가짜 탭) ----
    Register-WtAddon -Id 'test-b' -Title '나' -Order 20 -NewView { }
    Register-WtAddon -Id 'test-a' -Title '가' -Order 10 -NewView { }
    Register-WtAddon -Id 'test-c' -Title '다' -Order 10 -NewView { } -Required
    Assert-Wt '끈 탭은 메뉴 목록에서 빠진다' (-not (@(Get-WtAddon | ForEach-Object Id) -contains 'test-b') -and (@(Get-WtAddon -All | ForEach-Object Id) -contains 'test-b'))
    Set-WtSetting 'addons.disabled' @('test-c')
    Assert-Wt '꼭 있어야 하는 탭은 꺼도 메뉴에 남는다' (@(Get-WtAddon | ForEach-Object Id) -contains 'test-c')
    Set-WtSetting 'addons.disabled' @()
    Assert-Wt '메뉴 순서: Order가 같으면 ID 순서' ((@(Get-WtAddon | ForEach-Object Id) -join ',') -eq 'test-a,test-c,test-b') (@(Get-WtAddon | ForEach-Object Id) -join ',')
    Register-WtAddon -Id 'test-a' -Title '가2' -Order 10 -NewView { }
    Assert-Wt '같은 ID로 다시 등록하면 바꾼다' (@(Get-WtAddon -All | Where-Object Id -eq 'test-a').Count -eq 1 -and (Get-WtAddon -Id 'test-a').Title -eq '가2')

    # ---- 도움말 단축키 (가짜 탭) ----
    Register-WtAddon -Id 'test-x' -Title '엑스' -Order 30 -NewView { } -Shortcuts @(@('F5', '새로 고침'), @('Enter', '열기'))
    Register-WtAddon -Id 'test-y' -Title '와이' -Order 40 -NewView { } -Shortcuts (, @('F5', '새로 고침'))
    Register-WtAddon -Id 'test-one' -Title '하나' -Order 90 -NewView { } -Shortcuts @('F9', '혼자')
    Assert-Wt '단축키 한 쌍은 쉼표 없이 줘도 한 쌍' (@((Get-WtAddon -Id 'test-one').Shortcuts).Count -eq 1 -and (Get-WtAddon -Id 'test-one').Shortcuts[0][1] -eq '혼자')
    $threw = $false
    try { Register-WtAddon -Id 'test-bad' -Title '잘못' -NewView { } -Shortcuts @(@('F5', '새로 고침', '남는 값')) } catch { $threw = $true }
    Assert-Wt '모양이 틀린 단축키는 등록할 때 알린다' ($threw -and -not (Get-WtAddon -Id 'test-bad'))
    $keyRows = (@(& (Get-Module Pages) { Get-WtShortcutRows }) | ForEach-Object { "$($_.Key)=$($_.Text)" }) -join '|'
    Assert-Wt '도움말 단축키: 메뉴 순서로 모으고, 키 · 설명이 같으면 탭 이름을 묶는다' ($keyRows -eq 'F5=엑스 · 와이: 새로 고침|Enter=엑스: 열기|F9=하나: 혼자') $keyRows
    Set-WtSetting 'addons.disabled' @('test-y')
    $keyRows = (@(& (Get-Module Pages) { Get-WtShortcutRows }) | ForEach-Object { "$($_.Key)=$($_.Text)" }) -join '|'
    Assert-Wt '도움말 단축키: 끈 탭은 뺀다' ($keyRows -eq 'F5=엑스: 새로 고침|Enter=엑스: 열기|F9=하나: 혼자') $keyRows
    Set-WtSetting 'addons.disabled' @()

    # ---- 예전 데이터 가져오기 흐름 (가짜 탭) ----
    # 예전 WorkTool(WinForms)의 data 폴더는 정해진 CSV 이름으로 알아본다
    Write-WtTestLegacyCsv $test 'memo' "`"Id`"`n"
    Assert-Wt '예전 data 폴더를 찾는다' ((Find-WtLegacyFolder) -eq $test.Legacy) (Find-WtLegacyFolder)
    $legacyCalls = [pscustomobject]@{ Count = 0 }
    Register-WtAddon -Id 'test-legacy' -Title '가짜' -NewView { } -ImportLegacy {
        param($folder)
        $legacyCalls.Count++
        Write-WtStore -Name 'test-legacy' -Items @([ordered]@{ id = "n$($legacyCalls.Count)" })
        3
    }.GetNewClosure()
    $r = Import-WtLegacyData
    Assert-Wt '처음 실행: 저장소가 없는 탭만 가져온다' ($r.Count -eq 3 -and $r.Tabs -contains '가짜 3' -and $r.Folder -eq $test.Legacy) "($($r.Count) / $($r.Tabs -join ', '))"
    $r2 = Import-WtLegacyData
    Assert-Wt '두 번째 실행: 이미 가져온 탭은 건너뛴다' ($r2.Count -eq 0 -and $legacyCalls.Count -eq 1)
    $r3 = Import-WtLegacyData -Force
    Assert-Wt '다시 가져오기는 덮어쓰고 .bak을 남긴다' ($r3.Count -eq 3 -and $legacyCalls.Count -eq 2 -and (Test-Path ((Get-WtStorePath 'test-legacy') + '.bak')))

    # ---- 테마 색 대비 ----
    $pairs = @(
        @('OnAccent', 'Accent', 4.5), @('AccentStrong', 'AccentSoft', 4.5),
        @('Text', 'WindowBg', 4.5), @('Text', 'Sidebar', 4.5), @('Text', 'AccentSoft', 4.5), @('Text', 'Hover', 4.5),
        @('SubText', 'WindowBg', 4.5), @('SubText', 'Sidebar', 4.5), @('SubText', 'Card', 4.5),
        @('NavText', 'Sidebar', 4.5), @('NavText', 'Hover', 4.5),
        @('InputBorder', 'Card', 3.0), @('Accent', 'Card', 3.0))
    foreach ($name in (Get-WtPalette).Keys) {
        $c = Get-WtThemeColors $name
        $bad = foreach ($p in $pairs) {
            $ratio = Get-WtContrast $c[$p[0]] $c[$p[1]]
            if ($ratio -lt $p[2]) { '{0}/{1} {2:N2}' -f $p[0], $p[1], $ratio }
        }
        Assert-Wt "테마 '$name' 색 대비" (-not $bad) ($bad -join ', ')
    }
    foreach ($k in 'Work', 'Over', 'Trip', 'Leave') {
        $c = Get-WtThemeColors 'sky'
        Assert-Wt "근태 표시 '$k' 색 대비" ((Get-WtContrast $c["Att.$k"] $c["Att.${k}Bg"]) -ge 4.5)
    }
    $c = Get-WtThemeColors 'sky'
    $bad = foreach ($k in 'Blue', 'Teal', 'Green', 'Orange', 'Red', 'Purple', 'Gray') {
        foreach ($fg in "Callout.$k", 'Text') {
            $ratio = Get-WtContrast $c[$fg] $c["Callout.${k}Bg"]
            if ($ratio -lt 4.5) { '{0}/{1} {2:N2}' -f $fg, $k, $ratio }
        }
    }
    Assert-Wt '콜아웃 색 대비' (-not $bad) ($bad -join ', ')
    $bad = foreach ($k in 'Comment', 'String', 'Keyword', 'Number', 'Command', 'Variable', 'Type', 'Attr', 'Inserted', 'Deleted', 'Text') {
        $fg = if ($k -eq 'Text') { 'Text' } else { "Code.$k" }
        $ratio = Get-WtContrast $c[$fg] $c['Code.Bg']
        if ($ratio -lt 4.5) { '{0} {1:N2}' -f $fg, $ratio }
    }
    Assert-Wt '코드 색 대비 (코드 바탕 위)' (-not $bad) ($bad -join ', ')
    Assert-Wt '마크다운 · 다이어그램 색 대비' ((Get-WtContrast $c.Text $c['Md.Mark']) -ge 4.5 -and (Get-WtContrast $c.Text $c['Dia.NodeBg']) -ge 4.5 -and
        (Get-WtContrast $c.Text $c['Dia.NoteBg']) -ge 4.5 -and (Get-WtContrast $c.SubText $c['Dia.GroupBg']) -ge 4.5 -and
        (Get-WtContrast $c['Dia.Line'] $c.Card) -ge 3 -and (Get-WtContrast $c['Dia.NodeLine'] $c.Card) -ge 3)

    # ---- 마크다운 ----
    $md = @'
---
tags: [a, b]
---
# 제목 **굵게**

본문 [[다른 메모|별칭]] #태그 #123 %%숨김%% [링크](https://example.com) [파일](docs/a%20b.md)
둘째 줄

> [!warning]- 조심 **해**
> 본문

> [!NOTE]
> 깃허브 알림

> 그냥 인용

- [x] 끝남
- [ ] 할 일

| a | b |
|:--|--:|
| 1 | 2 |

```ps1
Get-Item C:\
```

각주[^1]

[^1]: 내용
'@
    $mm = ConvertTo-WtMarkdownModel $md
    $types = (@($mm.Blocks) | ForEach-Object T) -join ','
    Assert-Wt '마크다운: 블록 종류' ($types -eq 'props,heading,para,callout,callout,quote,list,table,code,para,footnotes') $types
    Assert-Wt '마크다운: 속성(--- 사이)' ($mm.Blocks[0].Items[0].Key -eq 'tags' -and $mm.Blocks[0].Items[0].Value -eq 'a, b')
    $p = $mm.Blocks[2].Inl
    $wiki = $p | Where-Object { $_.T -eq 'link' -and $_.Kind -eq 'wiki' }
    Assert-Wt '마크다운: 위키 링크' ($wiki.Target -eq '다른 메모' -and $wiki.Inl[0].Text -eq '별칭')
    Assert-Wt '마크다운: 태그 (숫자만은 태그 아님)' (@($p | Where-Object T -eq 'tag').Count -eq 1 -and ($p | Where-Object T -eq 'tag').Text -eq '태그')
    Assert-Wt '마크다운: %%주석%%은 빠진다' (-not ((Get-WtMarkdownSnippet '가 %%숨김%% 나') -match '숨김') -and -not (@($p | Where-Object { $_.T -eq 'text' -and $_.Text -match '숨김' }).Count))
    $links = @($p | Where-Object { $_.T -eq 'link' -and $_.Kind -ne 'wiki' })
    Assert-Wt '마크다운: 링크 종류 (주소 · 파일)' ($links[0].Kind -eq 'url' -and $links[1].Kind -eq 'file' -and $links[1].Target -eq 'docs/a b.md')
    Assert-Wt '마크다운: 줄바꿈 한 번' (@($p | Where-Object T -eq 'soft').Count -eq 1)
    $co = $mm.Blocks[3]
    Assert-Wt '마크다운: 콜아웃 종류 · 접기 · 제목' ($co.Kind -eq 'warning' -and $co.Fold -eq '-' -and (@($co.Title | ForEach-Object { if ($_.Inl) { $_.Inl[0].Text } else { $_.Text } }) -join '') -eq '조심 해' -and $co.Blocks.Count -eq 1)
    Assert-Wt '마크다운: 제목 없는 콜아웃은 종류 이름' ($mm.Blocks[4].Kind -eq 'note' -and $mm.Blocks[4].Title[0].Text -eq 'Note')
    Assert-Wt '마크다운: 할 일 목록' ($mm.Blocks[6].Items[0].Task -eq $true -and $mm.Blocks[6].Items[1].Task -eq $false -and $mm.Blocks[6].Items[0].Blocks[0].Inl[0].Text -eq '끝남')
    Assert-Wt '마크다운: 표 정렬' (($mm.Blocks[7].Align -join ',') -eq 'left,right' -and $mm.Blocks[7].Rows[0].Header)
    Assert-Wt '마크다운: 코드 블록' ($mm.Blocks[8].Lang -eq 'ps1' -and $mm.Blocks[8].Text -eq 'Get-Item C:\')
    Assert-Wt '마크다운: 각주' ($mm.Blocks[9].Inl[1].T -eq 'fn' -and $mm.Blocks[10].Items[0].Order -eq 1)
    Assert-Wt '마크다운: 제목 목록' ($mm.Headings.Count -eq 1 -and $mm.Headings[0].Text -eq '제목 굵게')
    $snip = Get-WtMarkdownSnippet "# 점검`n- [ ] 디스크`n- **로그** 확인`n| a | b |`n|--|--|`n[[메모|별칭]]"
    Assert-Wt '마크다운: 목록용 한 줄 요약' ($snip -eq '점검 · 디스크 · 로그 확인 · a  b · 별칭') $snip
    $longSnippet = "---`ntitle: 숨긴 제목`n---`n%%숨김%%`n# **첫 줄** &amp; [링크](https://example.com)`n| 항목 | 값 |`n|---|---|`n" + ("`n- [ ] [[메모|별칭]] <b>확인</b>" * 100)
    $wholeSnippet = Get-WtMarkdownSnippet $longSnippet 100000
    $prefixOk = $true
    foreach ($limit in 0,1,5,12,300) { if ((Get-WtMarkdownSnippet $longSnippet $limit) -cne $wholeSnippet.Substring(0, [Math]::Min($limit, $wholeSnippet.Length))) { $prefixOk = $false } }
    Assert-Wt '마크다운: 긴 글 요약도 속성·주석·줄 구분을 처리한 접두사와 같다' $prefixOk
    Assert-Wt '마크다운: 빈 글' ((ConvertTo-WtMarkdownModel '').Blocks.Count -eq 0 -and (Get-WtMarkdownSnippet '') -eq '')
    # 파일 링크: 메모 편집기는 경로를 <C:/a b/c.txt> · <//서버/공유/x>처럼 슬래시로 쓴다. 역슬래시 경로 · file: 주소도 그대로 된다
    $mdModule = Get-Module Markdown
    $fileLinks = @((ConvertTo-WtMarkdownModel '[a](<C:/a b/c.txt>) [b](<//srv/share/x>) [c](C:\x\y.log) [d](file:///C:/a%20b/c.txt) [e](file://srv/share/f.md)').Blocks[0].Inl | Where-Object T -eq 'link')
    $resolved = @($fileLinks | ForEach-Object { & $mdModule { param($t) Resolve-WtMdPath $t '' } $_.Target }) -join '|'
    Assert-Wt '마크다운: 파일 링크 종류 · 경로 풀기 (슬래시 · UNC · 역슬래시 · file:)' ((@($fileLinks | ForEach-Object Kind) -join ',') -eq 'file,file,file,file,file' -and
        $resolved -eq 'C:\a b\c.txt|\\srv\share\x|C:\x\y.log|C:\a b\c.txt|\\srv\share\f.md') $resolved
    $guess = @('C:\a\', 'D:/x/', 'C:', 'C:\', '\\srv\share', '//srv/share', '\\srv', 'C:\a\b', '\\srv\share\x', 'C:\a\b.txt', '\\srv\share\x.xlsx', 'C:\a.b\c.md') |
        ForEach-Object { if (& $mdModule { param($p) Test-WtMdFolderLike $p } $_) { 'D' } else { 'F' } }
    Assert-Wt '마크다운: 폴더 추측 (끝 \ · 드라이브 루트 · 공유 루트 · 확장자 없음)' (($guess -join '') -eq 'DDDDDDDDDFFF') ($guess -join '')

    # ---- 코드 색칠 ----
    $tok = Get-WtCodeTokens 'Get-ChildItem -Path $env:TEMP | Where-Object { $_.Length -gt 1KB } # 주석' 'powershell'
    $kinds = (@($tok) | Where-Object Kind | ForEach-Object { "$($_.Kind):$($_.Text)" }) -join ' '
    Assert-Wt '코드 색칠: PowerShell' ($kinds -eq 'Command:Get-ChildItem Attr:-Path Variable:$env:TEMP Command:Where-Object Variable:$_ Keyword:-gt Number:1KB Comment:# 주석') $kinds
    Assert-Wt '코드 색칠: 조각을 이으면 원래 글' ((@($tok) | ForEach-Object Text) -join '' -eq 'Get-ChildItem -Path $env:TEMP | Where-Object { $_.Length -gt 1KB } # 주석')
    Assert-Wt '코드 색칠: 별칭 · 모르는 언어' ((Get-WtCodeLanguage 'PS1') -eq 'powershell' -and (Get-WtCodeLanguage 'sh') -eq 'bash' -and $null -eq (Get-WtCodeLanguage 'nope') -and @(Get-WtCodeTokens 'x' 'nope')[0].Kind -eq '')
    $str = @(Get-WtCodeTokens 'echo "a # b" # c' 'bash') | Where-Object Kind
    Assert-Wt '코드 색칠: 문자열 안의 #은 주석이 아님' (($str | ForEach-Object Kind) -join ',' -eq 'Command,String,Comment')

    # ---- Mermaid ----
    $fc = ConvertFrom-WtMermaid @'
flowchart LR
    A[시작] --> B{확인?}
    B -->|예| C[(DB)]
    B -- 아니오 --> D([끝])
    C -.-> D & A
    subgraph g1 [묶음]
      C
    end
'@
    Assert-Wt 'Mermaid: flowchart 노드 · 모양' ($fc.Dir -eq 'LR' -and (($fc.Nodes.Values | ForEach-Object Shape) -join ',') -eq 'rect,diamond,cylinder,stadium' -and $fc.Nodes['C'].Group -eq 'g1')
    $el = ($fc.Edges | ForEach-Object { "$($_.From)$($_.To):$($_.Style):$($_.Text)" }) -join ' '
    Assert-Wt 'Mermaid: flowchart 선 · 라벨 · & 묶음' ($el -eq 'AB:normal: BC:normal:예 BD:normal:아니오 CD:dotted: CA:dotted:') $el
    $lay = Get-WtMermaidLayout $fc
    $nodes = @($lay.Items | Where-Object K -eq 'node')
    $overlap = $false
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        for ($j = $i + 1; $j -lt $nodes.Count; $j++) {
            $a = $nodes[$i]; $b = $nodes[$j]
            if ($a.X -lt $b.X + $b.W -and $b.X -lt $a.X + $a.W -and $a.Y -lt $b.Y + $b.H -and $b.Y -lt $a.Y + $a.H) { $overlap = $true }
        }
    }
    Assert-Wt 'Mermaid: 배치 (노드 4개, 겹치지 않음, 그림 안)' ($nodes.Count -eq 4 -and -not $overlap -and -not @($nodes | Where-Object { $_.X -lt 0 -or $_.Y -lt 0 -or $_.X + $_.W -gt $lay.Width -or $_.Y + $_.H -gt $lay.Height }).Count)
    $ax = ($nodes | Where-Object Text -eq '시작').X; $bx = ($nodes | Where-Object Text -eq '확인?').X
    Assert-Wt 'Mermaid: LR은 왼쪽에서 오른쪽' ($ax -lt $bx)
    $sq = ConvertFrom-WtMermaid "sequenceDiagram`n participant A as 서버`n actor U`n U->>A: 요청`n A-->>U: 응답`n loop 매일`n A->>A: 점검`n end`n Note right of A: 메모"
    Assert-Wt 'Mermaid: sequence' ((($sq.Participants.Values | ForEach-Object Label) -join ',') -eq '서버,U' -and $sq.Participants['U'].Actor -and
        (($sq.Items | ForEach-Object K) -join ',') -eq 'msg,msg,start,msg,end,note' -and $sq.Items[1].Line -eq 'dashed')
    Assert-Wt 'Mermaid: sequence 배치' (@((Get-WtMermaidLayout $sq).Items | Where-Object K -eq 'line').Count -ge 5)
    $stm = ConvertFrom-WtMermaid "stateDiagram-v2`n [*] --> 대기`n 대기 --> 실행 : 시작`n 실행 --> [*]"
    Assert-Wt 'Mermaid: state ([*] · 라벨)' ($stm.Nodes.Count -eq 4 -and (($stm.Edges | ForEach-Object Text) -join ',') -eq ',시작,')
    $threw = $null
    try { [void](ConvertFrom-WtMermaid "gantt`n title x") } catch { $threw = $_.Exception }
    Assert-Wt 'Mermaid: 모르는 종류는 NotSupported' ($threw -is [System.NotSupportedException])

    # ---- WPF로 그리기 (Windows · STA에서만) ----
    if ($wpf) {
        $sample = $md + @'


```mermaid
flowchart TD
    A --> B{x}
    B -->|y| C
```

```mermaid
sequenceDiagram
    A->>B: hi
```

```mermaid
pie
```
'@
        $view = New-WtMarkdownView -Scroll -OnLink { param($l) $true }
        Set-WtMarkdownText $view $sample
        Assert-Wt 'WPF: 마크다운을 오류 없이 그린다' (-not $view.Tag.Error -and $view.Document.Blocks.Count -ge 12) "$($view.Tag.Error)"
        $figs = @($view.Document.Blocks | Where-Object { $_ -is [System.Windows.Documents.BlockUIContainer] -and $_.Child -is [System.Windows.Controls.Border] })
        Assert-Wt 'WPF: Mermaid 2개는 그림, 모르는 종류는 코드 블록' ($figs.Count -eq 2 -and $view.Tag.Remeasure)
        Assert-Wt 'WPF: 제목 · 각주 자리' ($view.Tag.Anchors.ContainsKey('제목굵게') -and $view.Tag.Anchors.ContainsKey('fn1'))

        # 파일 링크 아이콘: 폴더처럼 보이면 폴더, 아니면 문서. 툴팁은 Windows 모양 전체 경로. 웹 · 위키 링크에는 붙이지 않는다
        $linkView = New-WtMarkdownView
        Set-WtMarkdownText $linkView '[문서](<C:/a b/c.txt>) [공유](<//srv/share/x>) [웹](https://example.com) [[위키]]'
        $hl = @($linkView.Document.Blocks.FirstBlock.Inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] })
        $firstText = @($hl | ForEach-Object { $_.Inlines.FirstInline.Text })
        Assert-Wt 'WPF: 파일 링크 앞 아이콘 (문서 · 폴더) · 툴팁 경로, 웹 · 위키 링크는 아이콘 없음' ($hl.Count -eq 4 -and
            $firstText[0] -eq [string][char]0xE8A5 -and $firstText[1] -eq [string][char]0xE8B7 -and $firstText[2] -eq '웹' -and $firstText[3] -eq '위키' -and
            $hl[0].ToolTip -eq 'C:\a b\c.txt' -and $hl[1].ToolTip -eq '\\srv\share\x') ($firstText -join ',')

        # 할 일 누르기: -OnTask가 있으면 체크 표시를 Hyperlink로 감싸고, 누르면 그 항목의 원문 줄 번호로 부른다
        $global:taskLines = [System.Collections.Generic.List[int]]::new()
        $taskView = New-WtMarkdownView -OnTask { param($line) $global:taskLines.Add($line) }
        Set-WtMarkdownText $taskView "# 할 일`n`n- [ ] 첫째`n- [x] 둘째`n  - [ ] 안쪽`n- 그냥 항목"
        $taskLinks = [System.Collections.Generic.List[object]]::new()
        $walkDoc = {
            param($blocks)
            foreach ($b in $blocks) {
                if ($b -is [System.Windows.Documents.List]) { foreach ($li in $b.ListItems) { & $walkDoc $li.Blocks } }
                elseif ($b -is [System.Windows.Documents.Section]) { & $walkDoc $b.Blocks }
                elseif ($b -is [System.Windows.Documents.Paragraph]) { foreach ($i in $b.Inlines) { if ($i -is [System.Windows.Documents.Hyperlink] -and $i.ToolTip -eq '완료 표시 / 해제') { $taskLinks.Add($i) } } }
            }
        }
        & $walkDoc $taskView.Document.Blocks
        foreach ($h in $taskLinks) { $h.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent)) }
        Assert-Wt 'WPF: 할 일 체크 표시를 누르면 원문 줄 번호로 부른다 (손 모양 커서)' (($global:taskLines -join ',') -eq '3,4,5' -and $taskLinks[0].Cursor -eq [System.Windows.Input.Cursors]::Hand) ($global:taskLines -join ',')
        $plainTask = New-WtMarkdownView
        Set-WtMarkdownText $plainTask '- [ ] 하나'
        $firstInline = $plainTask.Document.Blocks.FirstBlock.ListItems.FirstListItem.Blocks.FirstBlock.Inlines.FirstInline
        Assert-Wt 'WPF: -OnTask가 없으면 체크 표시는 누를 수 없다' ($firstInline -is [System.Windows.Documents.Run] -and $firstInline.Text -eq [string][char]0xE739)

        # 파일 링크 열기: 있는지 · 폴더인지는 화면 밖 작업으로 확인한다. 느린 경로 · 시간 초과는 확인 작업을 바꿔 끼워 흉내 낸다
        # 알림 · 열기 · 탐색기는 기록만 하고 실제로 열지 않는다
        & $mdModule {
            $script:testSaid = [System.Collections.Generic.List[string]]::new()
            function script:Show-WtMessage { param($Text, $Title, $Icon) $script:testSaid.Add("msg:$(($Text -split "`n")[0])") }
            function script:Invoke-Item { param($LiteralPath) $script:testSaid.Add("open:$LiteralPath") }
            function script:Start-Process { param($FilePath, $ArgumentList) $script:testSaid.Add("select:$ArgumentList") }
            $script:testSources = @{}
            $script:testRealProbe = $script:pathProbe
            $script:pathProbe = { param($path) $src = [System.Threading.Tasks.TaskCompletionSource[System.IO.FileAttributes]]::new(); $script:testSources[$path] = $src; $src.Task }
        }
        $fakeState = @{ BaseDir = ''; OnLink = $null; Anchors = @{} }
        $openLink = { param($target) Invoke-WtMarkdownLink $fakeState @{ Kind = 'file'; Target = $target; Text = 'x' } }
        try {
            & $openLink 'C:/wt/a.txt'; & $openLink 'C:/wt/a.txt'
            & $openLink 'C:/wt/dir'; & $openLink 'C:/wt/run.exe'; & $openLink 'C:/wt/none.txt'
            $pending = & $mdModule { @{ Jobs = $script:pathJobs.Count; Probes = $script:testSources.Count; Timer = $script:pathTimer.IsEnabled } }
            $waitCursor = [System.Windows.Input.Mouse]::OverrideCursor
            & $mdModule {
                $script:testSources['C:\wt\a.txt'].SetResult([System.IO.FileAttributes]::Archive)
                $script:testSources['C:\wt\dir'].SetResult([System.IO.FileAttributes]::Directory)
                $script:testSources['C:\wt\run.exe'].SetResult([System.IO.FileAttributes]::Archive)
                $script:testSources['C:\wt\none.txt'].SetResult([Enum]::ToObject([System.IO.FileAttributes], -1))   # 없는 경로는 -1
                Complete-WtMdPathChecks
            }
            $said = @(& $mdModule { $script:testSaid })
            $after = & $mdModule { @{ Jobs = $script:pathJobs.Count; Timer = $script:pathTimer.IsEnabled } }
            Assert-Wt 'WPF 파일 링크: 같은 링크는 겹쳐 확인하지 않고, 확인 중에는 AppStarting 커서' ($pending.Jobs -eq 4 -and $pending.Probes -eq 4 -and $pending.Timer -and
                $waitCursor -eq [System.Windows.Input.Cursors]::AppStarting) "(작업 $($pending.Jobs) · 커서 $waitCursor)"
            Assert-Wt 'WPF 파일 링크: 확인 결과대로 열기 (파일 · 폴더 · 실행 파일은 탐색기에서 선택 · 없음)' (($said -join '|') -eq 'open:C:\wt\a.txt|open:C:\wt\dir|select:/select,"C:\wt\run.exe"|msg:파일을 찾지 못했습니다.') ($said -join '|')
            Assert-Wt 'WPF 파일 링크: 끝나면 작업 목록 · 타이머 · 커서를 정리한다' ($after.Jobs -eq 0 -and -not $after.Timer -and $null -eq [System.Windows.Input.Mouse]::OverrideCursor)

            # 시간 초과: 기다리지 않고 알리고, 커서는 돌려놓는다. 답이 없는 동안 또 누르면 새로 확인하지 않고 바로 알린다
            & $mdModule { $script:testSaid.Clear(); $script:pathTimeoutMs = 50 }
            & $openLink '//srv/share/slow.xlsx'
            Start-Sleep -Milliseconds 120
            & $mdModule { Complete-WtMdPathChecks }
            & $openLink '//srv/share/slow.xlsx'
            $slow = & $mdModule { @{ Said = @($script:testSaid); Jobs = $script:pathJobs.Count; Probes = $script:testSources.Count; Timer = $script:pathTimer.IsEnabled } }
            $slowCursor = [System.Windows.Input.Mouse]::OverrideCursor
            & $mdModule { $script:testSources['\\srv\share\slow.xlsx'].SetResult([System.IO.FileAttributes]::Archive); Complete-WtMdPathChecks }
            $late = & $mdModule { @{ Said = @($script:testSaid); Jobs = $script:pathJobs.Count; Timer = $script:pathTimer.IsEnabled } }
            Assert-Wt 'WPF 파일 링크: 시간 초과면 알리고 커서를 돌려놓으며, 답을 기다리는 경로를 또 누르면 바로 알린다' (
                ($slow.Said -join '|') -eq 'msg:경로가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인한 뒤 다시 누르세요.|msg:경로가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인한 뒤 다시 누르세요.' -and
                $slow.Jobs -eq 1 -and $slow.Probes -eq 5 -and $slow.Timer -and $null -eq $slowCursor) ($slow.Said -join '|')
            Assert-Wt 'WPF 파일 링크: 늦게 온 답은 열지 않고 작업만 정리한다' ($late.Said.Count -eq 2 -and $late.Jobs -eq 0 -and -not $late.Timer)

            # 실제 확인 작업: 임시 폴더 · 없는 파일
            & $mdModule { $script:testSaid.Clear(); $script:pathTimeoutMs = 5000; $script:pathProbe = $script:testRealProbe }
            $realDir = (New-Item -ItemType Directory -Path (Join-Path $test.Root '링크 폴더')).FullName
            & $openLink ($realDir.Replace('\', '/')); & $openLink (Join-Path $realDir '없는 파일.txt')
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while ((& $mdModule { $script:pathJobs.Count }) -and $watch.Elapsed.TotalSeconds -lt 5) { & $mdModule { Complete-WtMdPathChecks }; Start-Sleep -Milliseconds 10 }
            $real = @(& $mdModule { $script:testSaid })
            Assert-Wt 'WPF 파일 링크: 실제 확인 작업 (폴더는 열고, 없는 파일은 알린다)' (($real | Sort-Object) -join '|' -eq "msg:파일을 찾지 못했습니다.|open:$realDir") ($real -join '|')
        } finally {
            & $mdModule {
                $script:pathTimeoutMs = 5000; $script:pathProbe = $script:testRealProbe
                foreach ($n in 'Show-WtMessage', 'Invoke-Item', 'Start-Process') { Remove-Item -LiteralPath "Function:\$n" -ErrorAction SilentlyContinue }
            }
        }

        # 앱이 끝날 때 답이 없는 확인 작업이 남아도 프로세스를 붙잡지 않는다 (응답 없는 공유 폴더를 끝나지 않는 작업으로 흉내 냄)
        $exitScript = Join-Path $test.Root 'path-exit.ps1'
        Set-Content -LiteralPath $exitScript -Encoding utf8 -Value @"
. '$(Join-Path $PSScriptRoot 'TestKit.ps1')'
Import-WtTestCore
[void](Test-WtTestWpf)
& (Get-Module Markdown) { `$script:pathProbe = { param(`$p) `$ev = [System.Threading.ManualResetEvent]::new(`$false); [System.Threading.Tasks.Task[bool]]::Run([Func[bool]]`$ev.WaitOne) } }
Invoke-WtMarkdownLink @{ BaseDir = '' } @{ Kind = 'file'; Target = '//srv/share/hang.txt'; Text = 'x' }
if (-not (& (Get-Module Markdown) { `$script:pathJobs.Count })) { exit 2 }
"@
        $child = Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList '-NoProfile', '-STA', '-File', "`"$exitScript`"" -PassThru -WindowStyle Hidden
        $exited = $child.WaitForExit(30000)
        if (-not $exited) { $child.Kill() }
        Assert-Wt 'WPF 파일 링크: 답이 없는 확인이 남아도 앱 프로세스는 끝난다' ($exited -and $child.ExitCode -eq 0) "(끝남 $exited · 코드 $(if ($exited) { $child.ExitCode }))"

        # 도움말: 탭이 등록한 설명 · 카드를 모은다. 카드 하나가 실패해도 도움말은 연다
        Register-WtAddon -Id 'test-help' -Title '도움' -Order 50 -NewView { } -Help '가짜 탭 설명' -HelpCard { New-WtText '가짜 카드' 'T.Body' }
        Register-WtAddon -Id 'test-broken' -Title '고장' -Order 60 -NewView { } -HelpCard { throw '일부러 낸 오류' }
        $texts = @(Get-WtTestTexts (New-WtHelpPage))
        Assert-Wt 'WPF 도움말: 탭 설명 · 단축키 · 카드를 싣는다' ($texts -contains '가짜 탭 설명' -and $texts -contains '가짜 카드' -and $texts -contains '엑스 · 와이: 새로 고침')
        Assert-Wt 'WPF 도움말: 실패한 탭 카드는 알리고 나머지는 연다' (@($texts | Where-Object { $_ -like '고장 도움말을 만들지 못했습니다*' }).Count -eq 1)

        $shell = Get-Module Shell
        $help1 = & $shell { Get-WtPageView '_help' }
        $help2 = & $shell { Get-WtPageView '_help' }
        Assert-Wt 'WPF 도움말: 같은 조건이면 화면 재사용' ([object]::ReferenceEquals($help1.View, $help2.View))
        Register-WtAddon -Id 'test-help' -Title '도움' -Order 50 -NewView { } -Help '바뀐 가짜 설명'
        $help3 = & $shell { Get-WtPageView '_help' }
        Assert-Wt 'WPF 도움말: 같은 ID 재등록도 새 설명 반영' (-not [object]::ReferenceEquals($help2.View, $help3.View) -and (Get-WtTestTexts $help3.View) -contains '바뀐 가짜 설명')
        Set-WtSetting 'addons.disabled' @('test-help')
        $hiddenHelp = & $shell { Get-WtPageView '_help' }
        Assert-Wt 'WPF 도움말: 숨긴 탭 설명은 재진입 때 빠진다' ((Get-WtTestTexts $hiddenHelp.View) -notcontains '바뀐 가짜 설명')
        Set-WtSetting 'addons.disabled' @()
        $font = Get-WtSetting 'ui.fontScale'; Set-WtSetting 'ui.fontScale' 'l'
        $largeHelp = & $shell { Get-WtPageView '_help' }
        Assert-Wt 'WPF 도움말: 글자 크기 변경 시 다시 만든다' (-not [object]::ReferenceEquals($hiddenHelp.View, $largeHelp.View))
        Set-WtSetting 'ui.fontScale' $font
        $settings1 = & $shell { Get-WtPageView '_settings' }
        $settings2 = & $shell { Get-WtPageView '_settings' }
        Assert-Wt 'WPF 설정: 같은 조건이면 화면 재사용' ([object]::ReferenceEquals($settings1.View, $settings2.View))
        $close = Get-WtSetting 'window.closeToTray'; Set-WtSetting 'window.closeToTray' (-not $close)
        $settings3 = & $shell { Get-WtPageView '_settings' }
        Assert-Wt 'WPF 설정: 바뀐 설정은 재진입 때 다시 읽는다' (-not [object]::ReferenceEquals($settings2.View, $settings3.View))
        Set-WtSetting 'window.closeToTray' $close

        # 미리 만들기: WarmUp을 준 탭만 만든다. Full은 새로 고침까지, View는 화면만. 설정 · 도움말도 만들고, 이미 연 화면은 건너뛴다
        $global:warmCalls = @{ FullNew = 0; FullRefresh = 0; ViewNew = 0; ViewRefresh = 0; NoneNew = 0 }
        Register-WtAddon -Id 'test-warm-full' -Title '미리1' -Order 70 -WarmUp Full -NewView { $global:warmCalls.FullNew++; New-WtText '미리 만든 화면' } -Refresh { param($v) $global:warmCalls.FullRefresh++ }
        Register-WtAddon -Id 'test-warm-view' -Title '미리2' -Order 71 -WarmUp View -NewView { $global:warmCalls.ViewNew++; New-WtText '틀만' } -Refresh { param($v) $global:warmCalls.ViewRefresh++ }
        Register-WtAddon -Id 'test-warm-none' -Title '미리3' -Order 72 -NewView { $global:warmCalls.NoneNew++; New-WtText '안 함' }
        $warmOff = & (Get-Module Shell) {
            $script:warmEnabled = $false; $script:warmStarted = $false; $script:warmQueue = $null
            Start-WtWarmUp
            -not $script:warmStarted -and $null -eq $script:warmQueue
        }
        Assert-Wt '미리 만들기: 기본 실행은 예약하지 않는다' $warmOff
        $warm = & (Get-Module Shell) {
            $script:ui = @{ WarmHost = [System.Windows.Controls.ContentControl]::new() }
            $script:ui.WarmHost.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $script:ui.WarmHost.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
            $script:views = @{}; $script:current = 'test-a'
            $script:warmEnabled = $true; $script:warmStarted = $false; $script:exiting = $false
            $run = { Start-WtWarmUp; $script:warmTimer.Stop(); $n = 0; while ((Invoke-WtWarmUpStep) -and $n -lt 30) { $n++ } }
            & $run
            $first = @{ Views = @($script:views.Keys | Sort-Object); HostEmpty = $null -eq $script:ui.WarmHost.Content }
            $queue = $script:warmQueue
            & $run
            $first.Once = [object]::ReferenceEquals($queue, $script:warmQueue)
            $first
        }
        Assert-Wt '미리 만들기: WarmUp을 준 탭만 만들고(Full은 새로 고침까지), 설정 · 도움말도 만든다' (
            ($warm.Views -join ',') -eq '_help,_settings,test-warm-full,test-warm-view' -and $warm.HostEmpty -and
            $global:warmCalls.FullNew -eq 1 -and $global:warmCalls.FullRefresh -eq 1 -and $global:warmCalls.ViewNew -eq 1 -and $global:warmCalls.ViewRefresh -eq 0 -and $global:warmCalls.NoneNew -eq 0) (
            "($($warm.Views -join ',') · $(($global:warmCalls.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '))")
        Assert-Wt '미리 만들기: 같은 세션에서 다시 예약하지 않는다' $warm.Once
        $warmGates = & (Get-Module Shell) {
            $oldWindow = $script:window
            $oldSelecting = $script:selecting
            try {
                $script:selecting = $false
                $script:window = [pscustomobject]@{ IsVisible = $true; IsEnabled = $true; IsActive = $false; WindowState = [System.Windows.WindowState]::Normal }
                $idle = Test-WtCanWarmUp
                $script:window.IsActive = $true; $active = Test-WtCanWarmUp
                $script:window.IsActive = $false; $script:window.IsEnabled = $false; $disabled = Test-WtCanWarmUp
                $script:window.IsEnabled = $true
                [System.Windows.Interop.ComponentDispatcher]::PushModal()
                try { $modal = Test-WtCanWarmUp } finally { [System.Windows.Interop.ComponentDispatcher]::PopModal() }
                $script:window.IsEnabled = $true; $script:window.WindowState = [System.Windows.WindowState]::Minimized; $minimized = Test-WtCanWarmUp
                $script:window.WindowState = [System.Windows.WindowState]::Normal; $script:window.IsVisible = $false; $hidden = Test-WtCanWarmUp
                $script:window.IsVisible = $true; $script:exiting = $true; $exiting = Test-WtCanWarmUp
                $idle -and -not $active -and -not $disabled -and -not $modal -and -not $minimized -and -not $hidden -and -not $exiting
            } finally {
                $script:window = $oldWindow; $script:selecting = $oldSelecting
                $script:exiting = $false; $script:warmEnabled = $false
            }
        }
        Assert-Wt '미리 만들기: 활성·모달·최소화·숨김·종료 상태에서는 대기한다' $warmGates
        Register-WtAddon -Id 'test-warm-failure' -Title '미리 실패' -WarmUp Full -NewView { New-WtText '실패할 화면' } -Refresh { throw '가짜 갱신 실패' }
        $warmFailure = & (Get-Module Shell) {
            $script:warmEnabled = $true
            try {
                $script:warmQueue = [System.Collections.Generic.Queue[string]]::new([string[]]@('test-warm-failure'))
                [void](Invoke-WtWarmUpStep)
                -not $script:views.ContainsKey('test-warm-failure') -and $null -eq $script:ui.WarmHost.Content
            } finally { $script:warmEnabled = $false; $script:warmQueue = $null }
        }
        Assert-Wt '미리 만들기: 갱신 실패 화면은 캐시에 남기지 않는다' $warmFailure
        $opaqueSetting = Get-WtSetting 'ui.opacity'
        $opaqueSession = & (Get-Module Shell) {
            $oldWindow = $script:window
            $oldForceOpaque = $script:forceOpaque
            try {
                $script:window = [System.Windows.Window]::new()
                $script:forceOpaque = $true
                Set-WtOpacity 65
                $script:window.Opacity -eq 1.0
            } finally { $script:window = $oldWindow; $script:forceOpaque = $oldForceOpaque }
        }
        Assert-Wt '불투명 진단: 세션 투명도만 고정하고 저장 설정은 유지한다' ($opaqueSession -and (Get-WtSetting 'ui.opacity') -eq $opaqueSetting)

        # 공통 모양: 스크롤 막대는 화살표 없이 손잡이만 두고, 가로 · 세로 막대가 만나는 모서리에 회색 칸이 없다. 막대를 누르면 한 화면씩 움직인다
        $box = [System.Windows.Controls.Border]::new()
        $box.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $box.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
        $sv = [System.Windows.Controls.ScrollViewer]::new(); $sv.HorizontalScrollBarVisibility = 'Auto'
        $lines = New-WtStack Vertical; $lines.Width = 400
        foreach ($i in 1..30) { [void](Add-WtChild $lines (New-WtText "줄 $i")) }
        $sv.Content = $lines; $box.Child = $sv
        $box.Measure([System.Windows.Size]::new(200, 100)); $box.Arrange([System.Windows.Rect]::new(0, 0, 200, 100)); $box.UpdateLayout()
        $parts = [System.Collections.Generic.List[object]]::new()
        $walk = { param($n) $parts.Add($n); for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($n); $i++) { & $walk ([System.Windows.Media.VisualTreeHelper]::GetChild($n, $i)) } }
        & $walk $box
        $bars = @($parts | Where-Object { $_ -is [System.Windows.Controls.Primitives.ScrollBar] })
        $pages = @($parts | Where-Object { $_ -is [System.Windows.Controls.Primitives.RepeatButton] } | ForEach-Object { $_.Command.Name })
        $pageDown = @($parts | Where-Object { $_ -is [System.Windows.Controls.Primitives.RepeatButton] -and $_.Command.Name -eq 'PageDown' })[0]
        $pageDown.Command.Execute($null, $pageDown); $box.UpdateLayout()
        Assert-Wt 'WPF 공통 모양: 스크롤 막대는 화살표 · 모서리 칸 없이 그리고, 막대를 누르면 한 화면씩 움직인다' (
            $bars.Count -eq 2 -and $bars[0].ActualWidth -eq 12 -and $bars[1].ActualHeight -eq 12 -and ($pages -join ',') -eq 'PageUp,PageDown,PageLeft,PageRight' -and
            -not @($parts | Where-Object { $_ -is [System.Windows.Shapes.Rectangle] }).Count -and $sv.VerticalOffset -gt 0) "(막대 $($bars.Count) · 버튼 $($pages -join ',') · 위치 $($sv.VerticalOffset))"
    } else {
        Write-Host 'SKIP WPF로 그리기 (Windows STA에서만)'
    }

    # ---- 탭 모아 보기: 앱처럼 모든 탭을 함께 불러온다 ----
    Import-WtTestCore
    Set-WtAppRoot $test.App
    Initialize-WtSettings
    $addonFiles = @(Get-ChildItem (Join-Path $root 'addons') -Filter '*.psm1' -Recurse | Sort-Object FullName)
    $addonModules = @(foreach ($f in $addonFiles) { Import-Module $f.FullName -Force -DisableNameChecking -PassThru })
    $ids = @(Get-WtAddon -All | ForEach-Object Id)
    Assert-Wt '탭 모아 보기: 탭 폴더마다 ID 하나씩 등록한다 (겹치는 ID 없음)' ($ids.Count -eq $addonFiles.Count) "(모듈 $($addonFiles.Count)개 · 등록 $($ids -join ', '))"
    $owners = @{}
    $dupes = foreach ($m in @(Get-Module | Where-Object { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })) {
        foreach ($fn in $m.ExportedFunctions.Keys) {
            if ($owners.ContainsKey($fn)) { "$fn ($($owners[$fn]) · $($m.Name))" } else { $owners[$fn] = $m.Name }
        }
    }
    Assert-Wt '탭 모아 보기: 모듈끼리 내보낸 함수 이름이 겹치지 않는다' (-not $dupes) ($dupes -join ', ')
    # ReuseThread 실행 공간은 버리기(Dispose) 전까지 스레드가 남는다. 끝낼 때 응답 없는 작업이라 못 버리면 창을 닫아도 앱 프로세스가 끝나지 않는다
    $reuse = @(Get-ChildItem $root -Filter '*.psm1' -Recurse | Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'ThreadOptions\s*=\s*\S*ReuseThread' } | ForEach-Object Name)
    Assert-Wt '탭 모아 보기: 실행 공간을 ReuseThread로 만들지 않는다 (앱 프로세스가 끝나지 않는다)' (-not $reuse.Count) ($reuse -join ', ')
    # 글을 코드로 바꿔 실행하는 동작(AGENTS.md 「코드 규칙」 4번)은 앱 코드에도 쓰지 않는다. 주석 · 도움말 글은 빼고 구문으로 찾는다
    $dynamic = @(foreach ($f in Get-ChildItem $root -Recurse -Include '*.psm1', '*.ps1' | Where-Object { $_.Name -notlike 'Test-*' -and $_.FullName -notlike '*\tests\*' }) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $hits = $ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
                        $n.Expression.TypeName.Name -match '(?i)^(System\.Management\.Automation\.)?scriptblock$' -and $n.Member.Value -eq 'Create') -or
                    ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Invoke-Expression', 'iex')
                }, $true)
            if (@($hits).Count) { $f.Name }
        })
    Assert-Wt '탭 모아 보기: 글을 코드로 바꿔 실행하지 않는다 ([scriptblock]::Create · Invoke-Expression)' (-not $dynamic.Count) ($dynamic -join ', ')
    if ($wpf) {
        $texts = @(Get-WtTestTexts (New-WtHelpPage))
        $missing = @(foreach ($a in @(Get-WtAddon)) { foreach ($line in @($a.Help)) { if ($texts -notcontains $line) { "$($a.Id): $line" } } })
        $broken = @($texts | Where-Object { $_ -like '* 도움말을 만들지 못했습니다*' })
        Assert-Wt '탭 모아 보기: 도움말이 모든 탭의 설명을 싣고, 탭 카드도 오류 없이 만든다' (-not $missing.Count -and -not $broken.Count) (($missing + $broken) -join '; ')
    }
    $addonModules | Remove-Module -Force
} finally {
    Remove-WtTestData $test
}

if ($script:failed) { Write-Host "실패 $script:failed 건" -ForegroundColor Red; exit 1 }
# 탭 폴더의 검사를 모두 찾아서 돌린다. 하나라도 틀리면 그 자리에서 멈춘다
foreach ($t in (Get-ChildItem (Join-Path $root 'addons') -Filter 'Test-*.ps1' -Recurse | Sort-Object FullName)) { & $t.FullName }
& (Join-Path $PSScriptRoot 'Test-Reliability.ps1')
& (Join-Path $PSScriptRoot 'Test-Launcher.ps1')
Write-Host '모두 통과' -ForegroundColor Green

# 업무 탭: 스크립트 폴더의 PowerShell 스크립트를 폼으로 실행하고 기록한다. 설계는 docs/plans/workflows-design.md
# - 스크립트는 실행하지 않고 구문만 읽어서 목록 · 폼을 만든다 (Read-WtFlowScript). param 하나 = 폼 칸 하나.
# - 실행은 별도 pwsh 프로세스로 한다. 앱 안: 창 없이 출력을 받아 보여 줌 · 콘솔 창: 보이는 창에서 -NoExit.
#   출력은 화면 밖 작업이 퍼 와서 큐에 넣고, UI 타이머는 큐에 쌓인 것만 꺼낸다.
# - 스크립트 폴더 · 파일은 공유 폴더일 수 있어서 찾기 · 읽기 · 프로세스 시작은 화면 밖(core\Work.psm1)에서 하고 잠깐만 기다린다.
# - 저장소 workflows.json(저장한 업무) · workflow-runs.json(실행 기록, 최근 100건). 설정 workflows.roots(더한 스크립트 폴더)
#   · workflows.hiddenRoots(목록에서 뺀 기본 폴더). 기본 폴더는 데이터 폴더의 scripts와 앱 옆 scripts (Get-WtFlowDefaultRoots)
# 단축키(업무 화면 안): F5 스크립트 목록 새로 고침

$ErrorActionPreference = 'Stop'

$script:schema = 1
$script:maxRuns = 100        # 실행 기록은 모든 스크립트를 합쳐 이만큼만 둔다
$script:tailLines = 40       # 기록에 남기는 출력 줄 수
$script:maxLines = 2000      # 화면에 두는 출력 줄 수 (오래된 줄부터 버림)
$script:maxScripts = 1000    # 스크립트 폴더 하나에서 찾는 파일 수
$script:ui = @{}
$script:info = $null         # 고른 스크립트를 읽은 것
$script:flow = $null         # 고른 업무 (스크립트를 고른 것이면 $null)
$script:fields = @()         # 폼 칸: @{ Field; Input; Error }
$script:run = $null          # 앱 안에서 실행 중인 것
$script:consoles = [System.Collections.Generic.List[object]]::new()   # 띄운 콘솔 창: @{ Process; Record }
$script:timer = $null
$script:pendingFlow = $null  # 홈 카드에서 고른 업무 (화면을 열 때 고른다)
$script:lastDeleted = $null  # 지운 업무 (실행 취소용)
$script:filling = $false     # 코드로 트리를 고르는 중
$script:outputKey = $null    # 출력 칸에 보이는 것이 어느 스크립트 · 업무의 것인지 ('script:경로' | 'flow:id')
$script:shown = 0            # 출력 칸에 붙인 줄 수 (화면에 안 보여도 직접 센다)
$script:encoding = $null     # 출력 문자 코드 (Get-WtFlowEncoding)
$script:threeColumns = 912   # 세 칸이 다 들어가는 폭: 목록 240 + 가운데 최소 360 + 설명 280 + 사이 16 × 2
$script:helpNarrow = $false  # 창이 좁아 설명을 가운데 위에 겹쳐 여는 중인지 (Update-WtFlowHelp)
$script:helpOverlay = $false # 좁을 때 겹쳐 연 설명이 열려 있는지

Register-WtSettingDefault 'workflows.roots' @()   # 사용자가 [폴더 추가]한 스크립트 폴더 목록
Register-WtSettingDefault 'workflows.hiddenRoots' @()   # 사용자가 목록에서 뺀 기본 스크립트 폴더 (다시 넣지 않는다)
Register-WtSettingDefault 'workflows.help' $true  # 오른쪽 설명 패널을 펼침
$script:defaultRoots = $null # 기본 스크립트 폴더 (Get-WtFlowDefaultRoots, 앱 · 데이터 폴더가 같으면 다시 찾지 않음)
$script:madeRoot = $null     # 이번에 만든(있는지 본) 데이터 폴더의 scripts
# 스크립트 폴더 · 파일은 공유 폴더일 수 있어서 화면 밖(core\Work.psm1)에서 읽는다. 로컬 폴더는 기다리는 시간 안에 끝나 바로 보인다
$script:scans = @{}          # 스크립트 폴더(비교용 키) → 마지막 찾기 결과 @{ Root; Missing; Scripts; State = ok · loading · slow · error; Error }
$script:flowFiles = @{}      # 저장한 업무의 스크립트 경로 → 있는지 ($null = 확인 중)
$script:scanWaitMs = 300     # 목록을 그리기 전에 기다리는 시간
$script:scanTimeoutMs = 10000   # 이 시간 안에 답이 없는 폴더는 「응답 없음」
$script:readWaitMs = 500     # 스크립트를 고를 때 읽기를 기다리는 시간
$script:readTimeoutMs = 10000
$script:startWaitMs = 1000   # [실행]할 때 프로세스 시작을 기다리는 시간 (작업 폴더가 공유 폴더일 수 있다)
$script:startTimeoutMs = 15000
$script:startFunctions = $null   # 시작 작업에 넣을 함수 (처음 쓸 때 한 번 찾는다)
$script:defaultsWaitMs = 1000   # 앱 옆 예제 스크립트 폴더 찾기
$script:scanWaiting = $false # 목록을 그리기 전 기다리는 중 (그사이 끝난 찾기는 따로 다시 그리지 않는다)
$script:scanFunctions = $null   # 찾기 작업에 넣을 함수 (처음 쓸 때 한 번 찾는다)
$script:redrawQueued = $false
$script:rescanQueued = $false
$script:readSeq = 0          # 고른 스크립트 읽기 차례 (늦게 온 읽기 결과를 버린다)
$script:selection = $null    # 지금 고른 것의 수명 @{ Key = 'script:경로' | 'flow:id'; Edits = 고치던 칸 값; Mode = 사용자가 고른 실행 방식 } (Enter-WtFlowSelection)
$script:starting = $null     # 화면 밖에서 시작 중인 실행 @{ Work; Cancelled; ... }
# 화면 밖에서 돌리는 코드 (검사가 응답 없는 폴더를 흉내 내려고 바꿔 끼운다)
$script:scanWork = { param($root, $max) @(Find-WtFlowScripts @($root) $max)[0] }   # 스크립트 폴더 하나 찾기
$script:defaultsWork = {                                                             # 앱 옆 예제 스크립트 폴더 찾기 (Get-WtFlowDefaultRoots)
    param($app)
    $dir = $app
    for ($i = 0; $i -le 3 -and $dir; $i++) {
        $candidate = [System.IO.Path]::Combine($dir, 'scripts')
        if ([System.IO.Directory]::Exists($candidate) -and ($i -eq 0 -or [System.IO.File]::Exists([System.IO.Path]::Combine($candidate, '_template.ps1')))) { return $candidate }
        $dir = [System.IO.Path]::GetDirectoryName($dir)
    }
    $null
}
$script:readCall = { param($path) New-WtCall ([System.IO.File]) ReadAllText $path }  # 스크립트 글 읽기 (.NET 호출 하나 → New-WtCall)
$script:startWork = { param($start, $owner) Start-WtFlowChild $start $owner }       # 프로세스 시작 (작업 폴더 = 스크립트 폴더)
$script:reapWork = {                                                                # 끝난 스크립트가 남긴 자식 찾아 끝내기 (Stop-WtFlowProcess)
    param($parentId, $since)
    foreach ($c in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $parentId" -ErrorAction Stop)) {
        if ($c.CreationDate -lt $since) { continue }
        try { $child = [System.Diagnostics.Process]::GetProcessById([int]$c.ProcessId); $child.Kill($true); $child.Dispose() } catch { }
    }
}

# ---- 스크립트 읽기 (WPF 없이) -------------------------------------------------------------------

# 도움말 글 정리. 도움말 블록 바로 아래의 #Requires 줄은 마지막 절에 붙어 읽히므로 뺀다
function Format-WtFlowHelpText([string]$Text) {
    if (-not $Text) { return '' }
    (@($Text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*Requires\s+-' }) -join "`n").Trim()
}

# 속성의 이름 있는 인수 값. [Parameter(Mandatory)]처럼 값을 생략하면 $true
function Get-WtFlowNamedArg($Attribute, [string]$Name) {
    foreach ($a in $Attribute.NamedArguments) {
        if ($a.ArgumentName -ne $Name) { continue }
        if ($a.ExpressionOmitted) { return $true }
        if ($a.Argument -is [System.Management.Automation.Language.ConstantExpressionAst]) { return [bool]$a.Argument.Value }
        if ($a.Argument -is [System.Management.Automation.Language.VariableExpressionAst]) { return $a.Argument.VariablePath.UserPath -ne 'false' }
        return $true
    }
    $false
}

# param 하나 → 폼 칸 정보. 폼에 넣을 수 없는 종류면 Kind가 비어 있다
function ConvertTo-WtFlowField($Param, $HelpInfo, $Tokens) {
    $name = $Param.Name.VariablePath.UserPath
    $field = [ordered]@{
        Name = $name; Kind = ''; TypeName = 'object'; Mandatory = $false; Choices = @()
        Min = $null; Max = $null; Integer = $false; Default = $null; Help = ''; Secret = $false
    }
    foreach ($attr in $Param.Attributes) {
        if ($attr -is [System.Management.Automation.Language.TypeConstraintAst]) { $field.TypeName = $attr.TypeName.FullName; continue }
        switch ($attr.TypeName.Name) {
            'Parameter' { if (Get-WtFlowNamedArg $attr 'Mandatory') { $field.Mandatory = $true } }
            'ValidateSet' {
                $field.Choices = @($attr.PositionalArguments | Where-Object { $_ -is [System.Management.Automation.Language.ConstantExpressionAst] } |
                        ForEach-Object { [string]$_.Value })
            }
            'ValidateRange' {
                $range = @($attr.PositionalArguments | Where-Object { $_ -is [System.Management.Automation.Language.ConstantExpressionAst] })
                if ($range.Count -eq 2) { $field.Min = [double]$range[0].Value; $field.Max = [double]$range[1].Value }
            }
        }
    }
    $type = $Param.StaticType
    if ($type -eq [System.Management.Automation.SwitchParameter]) { $field.Kind = 'switch' }
    elseif ($type -eq [string] -or $type -eq [object]) {
        # 이름 끝은 대소문자까지 본다 ($Profile 같은 이름에 [찾아보기]가 붙지 않게)
        $field.Kind = if ($field.Choices.Count) { 'choice' } elseif ($name -cmatch 'Folder$') { 'folder' } elseif ($name -cmatch 'File$') { 'file' } else { 'text' }
    } elseif ($type -in [int], [long], [int16], [byte]) { $field.Kind = 'number'; $field.Integer = $true }
    elseif ($type -in [double], [single], [decimal]) { $field.Kind = 'number' }
    # 비밀 값은 폼에 넣지 않는다. 저장한 업무 · 실행 기록 · 명령줄에 남지 않게 하려는 것이다
    if ($type -eq [securestring] -or $type -eq [pscredential] -or $name -match 'password|passwd|pwd|secret|token|apikey|credential') {
        $field.Kind = ''; $field.Secret = $true
    }
    # 기본값은 글자 · 숫자 · $true/$false 그대로일 때만 칸에 채운다
    if ($Param.DefaultValue -is [System.Management.Automation.Language.ConstantExpressionAst]) { $field.Default = $Param.DefaultValue.Value }
    elseif ($Param.DefaultValue -is [System.Management.Automation.Language.VariableExpressionAst] -and $Param.DefaultValue.VariablePath.UserPath -in 'true', 'false') {
        $field.Default = $Param.DefaultValue.VariablePath.UserPath -eq 'true'
    }
    # 칸 설명: .PARAMETER → 없으면 param 줄 끝 주석
    $text = $null
    if ($HelpInfo -and $HelpInfo.Parameters) {
        foreach ($k in $HelpInfo.Parameters.Keys) { if ($k -ieq $name) { $text = $HelpInfo.Parameters[$k] } }
    }
    if (-not $text) {
        $comment = $Tokens | Where-Object {
            $_.Kind -eq 'Comment' -and $_.Extent.StartLineNumber -eq $Param.Extent.EndLineNumber -and $_.Extent.StartOffset -ge $Param.Extent.EndOffset
        } | Select-Object -First 1
        if ($comment) { $text = $comment.Text.TrimStart('#') }
    }
    $field.Help = Format-WtFlowHelpText $text
    [pscustomobject]$field
}

# 스크립트 하나를 읽는다. 실행하지 않고 구문만 본다. 못 읽거나 실행할 수 없으면 Error에 이유.
# 화면에서는 파일 읽기만 화면 밖에서 하고(Request-WtFlowScript) 구문은 ConvertTo-WtFlowInfo로 본다. 스크립트 폴더가 응답 없는 공유 폴더일 수 있다
function Read-WtFlowScript([string]$Path) {
    try { $text = [System.IO.File]::ReadAllText($Path) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return New-WtFlowMissingInfo $Path }
    catch { return New-WtFlowInfo $Path "스크립트를 읽지 못했습니다: $($_.Exception.Message)" }
    ConvertTo-WtFlowInfo $Path $text
}

function New-WtFlowMissingInfo([string]$Path) {
    $info = New-WtFlowInfo $Path '스크립트 파일이 없습니다.'
    $info.Missing = $true
    $info
}

# 스크립트 글 → 스크립트 정보 (디스크를 보지 않는다)
function ConvertTo-WtFlowInfo([string]$Path, [string]$Text) {
    $info = New-WtFlowInfo $Path
    $tokens = $null; $parseErrors = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, $Path, [ref]$tokens, [ref]$parseErrors) }
    catch { $info.Error = "스크립트를 읽지 못했습니다: $($_.Exception.Message)"; return $info }
    if ($parseErrors.Count) {
        $info.Error = "구문 오류 ($($parseErrors[0].Extent.StartLineNumber)번째 줄): $($parseErrors[0].Message)"
        return $info
    }
    $helpInfo = $ast.GetHelpContent()
    if ($helpInfo) {
        $info.Synopsis = Format-WtFlowHelpText $helpInfo.Synopsis
        $info.Description = Format-WtFlowHelpText $helpInfo.Description
        $info.Examples = @($helpInfo.Examples | ForEach-Object { Format-WtFlowHelpText $_ } | Where-Object { $_ })
        $info.Notes = Format-WtFlowHelpText $helpInfo.Notes
    }
    if (-not $info.Synopsis) { $info.Warning = '도움말(.SYNOPSIS)이 없습니다.' }
    $info.Console = $info.Notes -match '(?m)^\s*WorkTool:\s*콘솔\s*$'
    if ($ast.ParamBlock) {
        foreach ($attr in $ast.ParamBlock.Attributes) {
            if ($attr.TypeName.Name -eq 'CmdletBinding' -and (Get-WtFlowNamedArg $attr 'SupportsShouldProcess')) { $info.WhatIf = $true }
        }
        $all = @(foreach ($p in $ast.ParamBlock.Parameters) { ConvertTo-WtFlowField $p $helpInfo $tokens })
        $info.Fields = @($all | Where-Object Kind)
        $info.Skipped = @($all | Where-Object { -not $_.Kind })
        # 폼에 넣을 수 없는 필수 값은 콘솔 창에서 PowerShell이 직접 묻는다. 그래서 그 스크립트는 콘솔 창에서만 실행한다
        $info.NeedsConsole = @($info.Skipped | Where-Object Mandatory | ForEach-Object Name)
    }
    $info
}

# 스크립트 정보의 빈 틀. Loading: 화면 밖에서 읽는 중 · Missing: 파일이 없음
function New-WtFlowInfo([string]$Path, [string]$Why = '', [switch]$Loading) {
    [pscustomobject]@{
        Path = $Path; Name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        Synopsis = ''; Description = ''; Examples = @(); Notes = ''
        Fields = @(); Skipped = @(); WhatIf = $false; Console = $false; NeedsConsole = @(); Error = $Why; Warning = ''
        Missing = $false; Loading = [bool]$Loading
    }
}

# 스크립트 폴더에서 .ps1을 찾는다 (하위 폴더 3단계까지, 이름이 _로 시작하면 뺀다). 없는 폴더도 표시하려고 돌려준다.
# Get-ChildItem -Recurse -Depth 3과 같게 찾되 .NET만 써서 빠르다 (명령 없는 화면 밖 세션에서도 돈다):
# 숨김 항목은 빼고, 열 수 없는 폴더는 건너뛰며, 정션 · 링크 폴더 안으로는 들어가지 않는다(돌고 도는 폴더를 막는다). 경로 순으로 정렬한다.
# 화면에서는 폴더마다 화면 밖 작업으로 부른다 (Start-WtFlowScans)
function Find-WtFlowScripts([string[]]$Roots, [int]$Max = 1000) {
    foreach ($root in $Roots) {
        if (-not [System.IO.Directory]::Exists($root)) { [pscustomobject]@{ Root = $root; Missing = $true; Scripts = @() }; continue }
        $options = [System.IO.EnumerationOptions]::new()
        $options.IgnoreInaccessible = $true
        $options.AttributesToSkip = [System.IO.FileAttributes]::Hidden
        $paths = [System.Collections.Generic.List[string]]::new()
        $level = [System.Collections.Generic.List[string]]::new()
        $level.Add($root)
        for ($depth = 0; $depth -le 3 -and $level.Count; $depth++) {
            $next = [System.Collections.Generic.List[string]]::new()
            foreach ($dir in $level) {
                try {
                    foreach ($e in [System.IO.DirectoryInfo]::new($dir).EnumerateFileSystemInfos('*', $options)) {
                        if ($e -is [System.IO.DirectoryInfo]) {
                            if (-not ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $next.Add($e.FullName) }
                        } elseif ($e.Extension -eq '.ps1' -and -not $e.Name.StartsWith('_')) { $paths.Add($e.FullName) }
                    }
                } catch { }
            }
            $level = $next
        }
        $paths.Sort([System.StringComparer]::CurrentCultureIgnoreCase)
        $found = [System.Collections.Generic.List[object]]::new()
        foreach ($p in $paths) {
            if ($found.Count -ge $Max) { break }
            $rel = [System.IO.Path]::GetRelativePath($root, [System.IO.Path]::GetDirectoryName($p))
            $found.Add([pscustomobject]@{ Path = $p; Name = [System.IO.Path]::GetFileNameWithoutExtension($p); Folder = $(if ($rel -eq '.') { '' } else { $rel }) })
        }
        [pscustomobject]@{ Root = $root; Missing = $false; Scripts = $found.ToArray() }
    }
}

# ---- 값 검사 · 인수 (WPF 없이) ------------------------------------------------------------------

# 저장한 값(JSON에서 읽으면 PSCustomObject)을 해시 테이블로
function ConvertTo-WtFlowValues($Values) {
    $table = @{}
    # .Keys 대신 get_Keys(): param 이름이 Keys인 값이 있으면 .Keys가 그 값을 돌려준다
    if ($Values -is [System.Collections.IDictionary]) { foreach ($k in $Values.get_Keys()) { $table[[string]$k] = $Values[$k] } }
    elseif ($Values) { foreach ($p in $Values.PSObject.Properties) { $table[$p.Name] = $p.Value } }
    $table
}

# 칸 값 검사. 틀린 칸만 @{ 이름 = '고칠 방법' }으로 돌려준다
function Test-WtFlowValues($Info, [hashtable]$Values) {
    $problems = [ordered]@{}
    foreach ($f in $Info.Fields) {
        if ($f.Kind -eq 'switch') { continue }
        $text = ([string]$Values[$f.Name]).Trim()
        if (-not $text) {
            if ($f.Mandatory) { $problems[$f.Name] = '값을 넣으세요.' }
            continue
        }
        if ($f.Kind -eq 'number') {
            $n = 0.0
            $ok = [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)
            if (-not $ok -or ($f.Integer -and $n -ne [Math]::Truncate($n))) {
                $problems[$f.Name] = $(if ($f.Integer) { '정수를 넣으세요. 예: 3' } else { '숫자를 넣으세요. 예: 1.5' })
                continue
            }
            if ($null -ne $f.Min -and ($n -lt $f.Min -or $n -gt $f.Max)) { $problems[$f.Name] = "$($f.Min) ~ $($f.Max) 사이로 넣으세요." }
        }
        if ($f.Kind -eq 'choice' -and $f.Choices -notcontains $text) { $problems[$f.Name] = "고를 수 있는 값: $($f.Choices -join ', ')" }
    }
    $problems
}

# 넘길 인수. 비운 칸은 넘기지 않고, 값은 -이름:값 하나로 넘긴다 (띄어쓰기 · 따옴표 · -로 시작하는 값도 그대로)
function Get-WtFlowArgs($Info, [hashtable]$Values, [switch]$WhatIf) {
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $Info.Fields) {
        if ($f.Kind -eq 'switch') {
            # 기본값이 켜짐인 스위치는 끌 때만 -이름:$false로 넘긴다
            if (-not $Values.ContainsKey($f.Name)) { continue }
            $on = $Values[$f.Name] -eq $true
            if ($on -and $f.Default -ne $true) { $list.Add("-$($f.Name)") }
            elseif (-not $on -and $f.Default -eq $true) { $list.Add("-$($f.Name):`$false") }
            continue
        }
        $text = ([string]$Values[$f.Name]).Trim()
        if ($text) { $list.Add("-$($f.Name):$text") }
    }
    if ($WhatIf) { $list.Add('-WhatIf') }
    $list.ToArray()
}

# 저장한 업무의 값 중 지금 스크립트에 없는 칸 이름
function Get-WtFlowStaleNames($Info, [hashtable]$Values) {
    $names = @($Info.Fields | ForEach-Object Name)
    @($Values.get_Keys() | Where-Object { $names -notcontains $_ } | Sort-Object)
}

# 명령줄 인수 하나를 Windows 규칙대로 감싼다. 콘솔 창 실행은 인수를 글자 한 줄로 넘겨야 해서 쓴다
function ConvertTo-WtFlowCommandArg([string]$Arg) {
    if ($Arg -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = [System.Text.StringBuilder]::new('"')
    $slashes = 0
    foreach ($c in $Arg.ToCharArray()) {
        if ($c -eq '\') { $slashes++; continue }
        if ($c -eq '"') { [void]$sb.Append('\', $slashes * 2 + 1).Append('"'); $slashes = 0; continue }
        if ($slashes) { [void]$sb.Append('\', $slashes); $slashes = 0 }
        [void]$sb.Append($c)
    }
    [void]$sb.Append('\', $slashes * 2).Append('"')
    $sb.ToString()
}

# 출력은 콘솔의 문자 코드로 나온다. 창 없는 콘솔은 사용자 형식(문화권)이 아니라 시스템의 OEM 코드 페이지를 쓴다
# (한국어 Windows는 949, 「UTF-8 사용」을 켜면 65001). 레지스트리에서 읽기만 하고, 못 읽으면 문화권 값을 쓴다
function Get-WtFlowEncoding {
    if (-not $script:encoding) {
        $cp = 0
        try { $cp = [int](Get-ItemPropertyValue -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'OEMCP') } catch { }
        if (-not $cp) { $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage }
        $script:encoding = [System.Text.Encoding]::GetEncoding($cp)
    }
    $script:encoding
}

# 실행할 프로세스 정보. 실행 정책은 바꾸지 않고, 입력값으로 명령 문자열을 조립하지 않는다
function New-WtFlowStartInfo($Info, [hashtable]$Values, [ValidateSet('app', 'console')][string]$Mode = 'app', [switch]$WhatIf) {
    $start = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $start.WorkingDirectory = Split-Path $Info.Path -Parent
    $scriptArgs = @(Get-WtFlowArgs $Info $Values -WhatIf:$WhatIf)
    if ($Mode -eq 'console') {
        # 보이는 새 창에서 연다. 끝나도 창을 남겨 출력을 읽게 하고, 창은 사용자가 닫는다
        $start.UseShellExecute = $true
        $start.Arguments = (@('-NoLogo', '-NoProfile', '-NoExit', '-File', $Info.Path) + $scriptArgs | ForEach-Object { ConvertTo-WtFlowCommandArg $_ }) -join ' '
        return $start
    }
    foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Info.Path) + $scriptArgs) { $start.ArgumentList.Add($a) }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = Get-WtFlowEncoding
    $start.StandardErrorEncoding = Get-WtFlowEncoding
    $start.Environment['NO_COLOR'] = '1'   # 오류 글자에 색 코드가 섞이지 않게
    $start
}

# ---- 실행 상태 (WPF 없이) -----------------------------------------------------------------------

# 출력 퍼 오기: 화면 밖 작업(core\Work.psm1)에서 표준 출력 · 오류 통로를 쉬지 않고 읽어 큐에 넣는다.
# 화면 타이머가 읽으면 그 사이 통로(4KB)가 차서 스크립트가 기다리므로, 읽기는 화면과 떼어 둔다 (문서 탭의 조회와 같은 방식).
# 큐에는 @(통로 번호, 글자 덩어리)를 넣고, 통로가 끝나면 @(번호, $null)을 넣는다. 읽기를 오래 기다리지 않고 0.2초마다 그만둘지 본다
$script:pumpWork = {
    param($Readers, $Queue, $Stop)
    $buffers = @([char[]]::new(65536), [char[]]::new(65536))
    $tasks = @($Readers[0].ReadAsync($buffers[0], 0, 65536), $Readers[1].ReadAsync($buffers[1], 0, 65536))
    $open = @($true, $true)
    while (($open[0] -or $open[1]) -and -not $Stop.Value) {
        $any = $false
        for ($k = 0; $k -lt 2; $k++) {
            if (-not $open[$k] -or -not $tasks[$k].IsCompleted) { continue }
            $any = $true
            $n = if ($tasks[$k].IsFaulted -or $tasks[$k].IsCanceled) { 0 } else { $tasks[$k].Result }
            if ($n -le 0) { $open[$k] = $false; $Queue.Enqueue(@($k, $null)); continue }
            $Queue.Enqueue(@($k, [string]::new($buffers[$k], 0, $n)))
            $tasks[$k] = $Readers[$k].ReadAsync($buffers[$k], 0, 65536)
        }
        if (-not $any) {
            $pending = [System.Threading.Tasks.Task[]]@(for ($k = 0; $k -lt 2; $k++) { if ($open[$k]) { $tasks[$k] } })
            if ($pending.Count) { [void][System.Threading.Tasks.Task]::WaitAny($pending, 200) }
        }
    }
}

<#
프로세스를 만든다 (화면 밖에서 부른다). 만든 프로세스는 화면이 넘겨받을 때까지 $Owner가 가지고 있다.
만들자마자 잠금 안에서 $Owner에 넣고 멈춤 표시를 본다: 이미 멈췄으면(취소 · 앱 종료) 만든 쪽이 바로 끝낸다.
화면 쪽은 같은 잠금 안에서 멈춤 표시를 하고 $Owner의 프로세스를 끝내므로, 어느 순서로 일어나도 넘겨받지 않은 자식이 남지 않는다 (Stop-WtFlowStarting)
#>
function Start-WtFlowChild($Start, $Owner) {
    $p = [System.Diagnostics.Process]::Start($Start)
    if (-not $p) { return $null }
    [System.Threading.Monitor]::Enter($Owner.SyncRoot)
    try { $Owner.Process = $p; $stopped = [bool]$Owner.Stopped } finally { [System.Threading.Monitor]::Exit($Owner.SyncRoot) }
    if ($stopped) { try { $p.Kill($true) } catch { }; return $null }
    $p
}

# 시작 중인 실행을 멈춘다 (화면 스레드): 멈춤 표시를 하고, 이미 만들어졌는데 아직 넘겨받지 않은 자식은 끝낸다
function Stop-WtFlowStarting($Ctx) {
    $owner = $Ctx.Owner
    [System.Threading.Monitor]::Enter($owner.SyncRoot)
    try { $owner.Stopped = $true; $p = $owner.Process; $taken = [bool]$owner.Taken } finally { [System.Threading.Monitor]::Exit($owner.SyncRoot) }
    $Ctx.Cancelled = $true
    if ($p -and -not $taken) { try { $p.Kill($true) } catch { } }
}

# 앱 안 실행을 시작한다. 입력은 바로 닫아서, 입력을 기다리는 스크립트도 멈추지 않고 오류로 끝나게 한다.
# -Process: 화면 밖에서 이미 시작한 프로세스 (Invoke-WtFlowRun). 없으면 여기서 시작한다
function Start-WtFlowProcess($StartInfo, $Record, [System.Diagnostics.Process]$Process) {
    $p = if ($Process) { $Process } else { [System.Diagnostics.Process]::Start($StartInfo) }
    $p.StandardInput.Close()
    $enc = Get-WtFlowEncoding
    $readers = @(foreach ($stream in @($p.StandardOutput.BaseStream, $p.StandardError.BaseStream)) { [System.IO.StreamReader]::new($stream, $enc, $false, 65536) })
    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $stop = [hashtable]::Synchronized(@{ Value = $false })
    $pump = Start-WtWork -Script $script:pumpWork -ArgumentList @($readers, $queue, $stop)
    [pscustomobject]@{
        Process = $p; Id = $p.Id; Record = $Record; Started = Get-Date; ExitedAt = $null; Cancelled = $false; Stopped = $false
        Readers = $readers; Queue = $queue; Stop = $stop; Pump = $pump
        Partial = @('', ''); Open = @($true, $true)
        Lines = [System.Collections.Generic.List[string]]::new()
    }
}

# 큐에 쌓인 출력을 줄로 꺼낸다. UI 타이머에서 부르며, 기다리지 않는다. 한 번에 $Max줄까지
function Read-WtFlowOutput($Run, [int]$Max = 5000) {
    $fresh = [System.Collections.Generic.List[string]]::new()
    $item = $null
    while ($fresh.Count -lt $Max -and $Run.Queue.TryDequeue([ref]$item)) {
        $k = [int]$item[0]
        if ($null -eq $item[1]) {
            # 통로 끝: 줄바꿈 없이 남은 마지막 조각도 한 줄로 낸다
            if ($Run.Partial[$k]) { $fresh.Add($Run.Partial[$k]); $Run.Lines.Add($Run.Partial[$k]); $Run.Partial[$k] = '' }
            $Run.Open[$k] = $false
            continue
        }
        $text = $Run.Partial[$k] + [string]$item[1]
        if ($text.IndexOf([char]27) -ge 0) { $text = [regex]::Replace($text, "`e\[[0-9;?]*[ -/]*[@-~]", '') }   # 남은 색 코드 정리
        $parts = $text.Replace("`r", '').Split("`n")
        $Run.Partial[$k] = $parts[-1]
        if ($parts.Count -gt 1) {
            $whole = [string[]]$parts[0..($parts.Count - 2)]
            $fresh.AddRange($whole)
            $Run.Lines.AddRange($whole)
        }
    }
    if ($Run.Lines.Count -gt $script:maxLines + 500) { $Run.Lines.RemoveRange(0, $Run.Lines.Count - $script:maxLines) }
    $fresh.ToArray()
}

# 프로세스가 끝나고 출력도 다 읽었으면 $true.
# 이미 읽어 둔 출력은 화면이 밀려 있어도 다 꺼낸 뒤에 끝낸다 (마지막 줄이 보통 결과다).
# 끝난 프로세스가 남긴 자식이 출력 통로를 붙잡고 있으면, 2초 뒤에는 끝으로 본다 (자식은 끄지 않는다)
function Test-WtFlowRunDone($Run) {
    if (-not $Run.Process.HasExited) { return $false }
    if (-not $Run.ExitedAt) { $Run.ExitedAt = Get-Date }
    if (-not $Run.Queue.IsEmpty) { return $false }
    $Run.Open -notcontains $true -or ((Get-Date) - $Run.ExitedAt).TotalSeconds -gt 2
}

# 실행을 끝내고 기록을 저장한다. 결과(success · failed · cancelled · stopped)를 돌려준다.
# 기록을 저장하지 못해도 결과는 그대로 돌려주고, 그 이유는 실행 정보의 SaveError에 둔다
function Complete-WtFlowRun($Run) {
    $code = $null
    try { $code = $Run.Process.ExitCode } catch { }
    $status = if ($Run.Stopped) { 'stopped' } elseif ($Run.Cancelled) { 'cancelled' } elseif ($code -eq 0) { 'success' } else { 'failed' }
    $rec = $Run.Record
    $rec.ended = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $rec.status = $status
    $rec.exitCode = $code
    $rec.tail = @($Run.Lines | Select-Object -Last $script:tailLines)
    # 퍼 오기를 멈춘 뒤 읽기 통로를 닫는다. 퍼 오기는 0.2초마다 그만둘지 보므로 오래 기다리지 않는다.
    # 그래도 끝나지 않으면 기다리지 않고 버린다. 남은 자식이 통로를 붙잡고 있어도 통로가 끝나기를 기다리지는 않는다
    $Run.Stop.Value = $true
    try { [void](Wait-WtWork $Run.Pump -Milliseconds 2000) } catch { }
    Stop-WtWork $Run.Pump
    foreach ($r in $Run.Readers) { try { $r.Dispose() } catch { } }
    try { $Run.Process.Dispose() } catch { }
    try { Save-WtFlowRun $rec } catch { $Run | Add-Member -NotePropertyName SaveError -NotePropertyValue $_.Exception.Message -Force }
    $status
}

# 실행 중인 것을 끝낸다 (자식 프로세스까지). 이때 스크립트의 finally는 돌지 않을 수 있다.
# 스크립트는 이미 끝났는데 남은 자식이 출력을 붙잡고 있으면, 그 자식을 찾아 끝낸다 (이 실행이 시작한 뒤에 생긴 것만).
# 자식 찾기(WMI)는 화면 밖에서 한다: 화면 · 종료가 그 호출에 막히지 않게. 끝낼 때는 Stop-WtFlows가 정한 시간만 기다린다 ($Run.Reaper)
function Stop-WtFlowProcess($Run) {
    $exited = $true
    try { $exited = $Run.Process.HasExited } catch { }
    if (-not $exited) {
        try { $Run.Process.Kill($true) } catch { }
        return
    }
    if ($Run.PSObject.Properties['Reaper'] -and $Run.Reaper -and -not $Run.Reaper.Finished) { return }   # 이미 찾는 중
    try {
        # 정리 작업은 끝나지 않은 작업 수 한도와 따로 둔다 (-Reserved): 응답 없는 조회가 한도를 채워도 남은 자식은 끝낸다
        $reaper = Start-WtWork -Script $script:reapWork -ArgumentList $Run.Id, $Run.Started.AddSeconds(-1) -Session Default -TimeoutMs 10000 -Reserved
        $Run | Add-Member -NotePropertyName Reaper -NotePropertyValue $reaper -Force
    } catch { }
}

# ---- 저장 (WPF 없이) ----------------------------------------------------------------------------

# 저장한 업무 · 실행 기록은 하나씩 내보낸다. Get-WtStoreItems는 목록을 한 덩어리로 돌려주므로 받아서 푼다
# (덩어리째 파이프에 넣으면 Where-Object · Sort-Object가 목록 전체를 항목 하나로 본다)
function Get-WtFlows {
    $items = Get-WtStoreItems -Name 'workflows' -Schema $script:schema
    $items | Sort-Object { [string]$_.title }
}

# 데이터 폴더가 늦게 답하면 저장 통로가 끝까지 쓴다 (그동안 읽으면 저장한 내용이 나온다)
function Save-WtFlows([object[]]$Items) { Write-WtStore -Name 'workflows' -Schema $script:schema -Items @($Items) }

function New-WtFlow([string]$Title, [string]$ScriptPath, [hashtable]$Values, [string]$Mode) {
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    [ordered]@{ id = New-WtId; title = $Title; script = $ScriptPath; values = $Values; mode = $Mode; created = $now; updated = $now }
}

function Get-WtFlowRuns {
    $items = Get-WtStoreItems -Name 'workflow-runs' -Schema $script:schema
    $items
}

# 실행 기록 하나를 넣거나 바꾼다(같은 id면 바꿈). 시작 시각이 최근인 것부터 100건만 둔다
function Save-WtFlowRun($Record) {
    $rest = @(Get-WtFlowRuns | Where-Object { $_.id -ne $Record.id })
    $all = @(@($Record) + $rest | Sort-Object { [string]$_.started } -Descending | Select-Object -First $script:maxRuns)
    Write-WtStore -Name 'workflow-runs' -Schema $script:schema -Items $all
}

# 실행 기록 하나. 넘긴 값만 남긴다 (스위치는 기본값과 다를 때만). 업무는 이름이 아니라 id로 가리킨다
function New-WtFlowRecord($Info, [hashtable]$Values, [string]$Mode, [bool]$WhatIf, [string]$FlowTitle, [string]$FlowId = '') {
    $kept = [ordered]@{}
    foreach ($f in $Info.Fields) {
        $v = $Values[$f.Name]
        if ($f.Kind -eq 'switch') { if ($Values.ContainsKey($f.Name) -and ($v -eq $true) -ne ($f.Default -eq $true)) { $kept[$f.Name] = ($v -eq $true) } }
        elseif (([string]$v).Trim()) { $kept[$f.Name] = ([string]$v).Trim() }
    }
    [ordered]@{
        id = New-WtId; script = $Info.Path; name = $Info.Name; flow = $FlowTitle; flowId = $FlowId; mode = $Mode; whatIf = $WhatIf; values = $kept
        started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); ended = ''; status = $(if ($Mode -eq 'console') { 'console' } else { 'running' })
        exitCode = $null; tail = @()
    }
}

# 결과 표시: 글자 · 아이콘 · 색(테마 리소스 이름). 색만으로 구분하지 않는다
function Get-WtFlowStatusLook([string]$Status, [bool]$WhatIf) {
    $look = switch ($Status) {
        'success' { @{ Text = '성공'; Icon = 0xE73E; Bg = 'SuccessBg'; Fg = 'Success' } }
        'failed' { @{ Text = '실패'; Icon = 0xE783; Bg = 'DangerBg'; Fg = 'Danger' } }
        'cancelled' { @{ Text = '취소'; Icon = 0xE711; Bg = 'Chip'; Fg = 'ChipText' } }
        'stopped' { @{ Text = '멈춤'; Icon = 0xE71A; Bg = 'WarnBg'; Fg = 'Warn' } }
        'console' { @{ Text = '콘솔 창'; Icon = 0xE756; Bg = 'Chip'; Fg = 'ChipText' } }
        default { @{ Text = '실행 중'; Icon = 0xE768; Bg = 'Chip'; Fg = 'ChipText' } }
    }
    if ($WhatIf) { $look.Text = "미리보기 · $($look.Text)" }
    $look
}

# 걸린 시간을 짧게: 12초 · 3분 5초 · 1시간 2분
function Format-WtFlowSpan([timespan]$Span) {
    if ($Span.TotalHours -ge 1) { return '{0}시간 {1}분' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes }
    if ($Span.TotalMinutes -ge 1) { return '{0}분 {1}초' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds }
    '{0}초' -f [int][Math]::Floor($Span.TotalSeconds)
}

# 기록의 시각 → [datetime]. 비었거나 읽을 수 없으면 $null (손으로 고친 기록이 있어도 화면을 막지 않게)
function ConvertTo-WtFlowTime($Value) {
    if ($Value -is [datetime]) { return $Value }
    $t = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$t)) { return $t }
    $null
}

function Get-WtFlowRunSpan($Record) {
    $started = ConvertTo-WtFlowTime $Record.started
    $ended = ConvertTo-WtFlowTime $Record.ended
    if (-not $started -or -not $ended) { return '' }
    Format-WtFlowSpan ($ended - $started)
}

# ---- 화면: 목록 ---------------------------------------------------------------------------------

# 같은 폴더인지 견줄 때 쓰는 모양 (끝의 \ · 대소문자 · 상대 경로 차이를 없앤다)
function ConvertTo-WtFlowPathKey([string]$Path) {
    if (-not $Path) { return '' }
    try { [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/').ToLowerInvariant() } catch { $Path.TrimEnd('\', '/').ToLowerInvariant() }
}

function Test-WtFlowPathIn([string]$Path, $List) {
    $key = ConvertTo-WtFlowPathKey $Path
    foreach ($p in @($List)) { if ($p -and (ConvertTo-WtFlowPathKey ([string]$p)) -eq $key) { return $true } }
    $false
}

# 처음부터 목록에 있는 스크립트 폴더: @{ Path; Label; Data }
# - 내 스크립트: 데이터 폴더의 scripts (기본 문서\WorkTool\scripts). 여기에 .ps1을 복사해 넣으면 바로 보인다
# - 예제 스크립트: 앱 파일 옆 scripts (개인 PC zip을 푼 곳). 저장소 원본으로 띄우면 앱 폴더 위로 3단계 안의
#   scripts 중 _template.ps1이 있는 것 (저장소 맨 위 scripts/). 엉뚱한 scripts 폴더를 잡지 않게 표식 파일을 본다
# 앱 폴더를 보는 일은 화면 밖에서 하고 잠깐만 기다린다. 답이 없으면(앱을 응답 없는 공유 폴더에 둔 경우) 예제 스크립트는 빼고 다음에 다시 찾는다
function Get-WtFlowDefaultRoots {
    $app = Get-WtAppRoot
    $data = Get-WtDataFolder 'scripts'
    $key = "$app|$data"
    if ($script:defaultRoots -and $script:defaultRoots.Key -ceq $key) { return $script:defaultRoots.Items }
    $found = $null; $known = $true
    if ($app) {
        try { $found = Invoke-WtWork -Script $script:defaultsWork -Key (Get-WtPathKey $app) -TimeoutMs $script:defaultsWaitMs -ArgumentList $app }
        catch { $known = $false }
    }
    $items = @(New-WtFlowDefaultItems $data $found)
    if ($known) { $script:defaultRoots = @{ Key = $key; Items = $items; Found = [string]$found } }
    $items
}

function New-WtFlowDefaultItems([string]$Data, [string]$Found) {
    [pscustomobject]@{ Path = $Data; Label = '내 스크립트'; Data = $true }
    if ($Found -and -not (Test-WtFlowPathIn $Found $Data)) { [pscustomobject]@{ Path = $Found; Label = '예제 스크립트'; Data = $false } }
}

# 앞서 찾은 기본 폴더가 있으면 그것으로 바로 그리고, 화면 밖에서 다시 찾아 달라졌을 때만 목록을 다시 만든다
# (탭에 들어올 때마다 다시 찾는다: 앱 옆에 scripts를 나중에 넣어도 보이게)
function Start-WtFlowDefaultsCheck {
    $cached = $script:defaultRoots
    $app = Get-WtAppRoot
    if (-not $cached -or -not $app) { return }   # 처음에는 Get-WtFlowDefaultRoots가 바로 찾는다
    try {
        [void](Start-WtWork -Script $script:defaultsWork -ArgumentList $app -Key (Get-WtPathKey $app) -TimeoutMs $script:defaultsWaitMs -Context $cached `
                -OnDone { param($w) if ($w.State -eq 'done' -and [object]::ReferenceEquals($script:defaultRoots, $w.Context) -and [string]$w.Result -ne $w.Context.Found) { Request-WtFlowTreeRedraw -Rescan } })
    } catch { }
}

# 목록에 보이는 스크립트 폴더: 기본 폴더(뺀 것 제외) → [폴더 추가]한 폴더. 같은 폴더는 한 번만
function Get-WtFlowRoots {
    $hidden = @(Get-WtSetting 'workflows.hiddenRoots' | Where-Object { $_ })
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($d in @(Get-WtFlowDefaultRoots)) {
        if (Test-WtFlowPathIn $d.Path $hidden) { continue }
        # 데이터 폴더의 scripts는 없으면 만든다. 사용자가 그 폴더를 찾아 파일만 넣으면 되게 (못 만들면 목록에 「폴더 없음」으로 보인다)
        if ($d.Data -and $script:madeRoot -cne $d.Path) {
            try { [void](Get-WtDataFolder 'scripts' -Create); $script:madeRoot = $d.Path } catch { }
        }
        $list.Add($d.Path)
    }
    foreach ($r in @(Get-WtSetting 'workflows.roots' | Where-Object { $_ })) {
        if (-not (Test-WtFlowPathIn $r $list)) { $list.Add([string]$r) }
    }
    $list.ToArray()
}

# 기본 폴더의 이름 (트리에 보이는 것). 기본 폴더가 아니면 $null
function Get-WtFlowRootLabel([string]$Path) {
    foreach ($d in @(Get-WtFlowDefaultRoots)) { if (Test-WtFlowPathIn $Path $d.Path) { return $d.Label } }
    $null
}

# 폴더를 목록에 넣는다. 뺐던 기본 폴더면 다시 보이게만 한다. 이미 있으면 $false
function Add-WtFlowRootPath([string]$Path) {
    $hidden = @(Get-WtSetting 'workflows.hiddenRoots' | Where-Object { $_ })
    if (@(Get-WtFlowDefaultRoots | Where-Object { Test-WtFlowPathIn $_.Path $Path }).Count -and (Test-WtFlowPathIn $Path $hidden)) {
        Set-WtSetting 'workflows.hiddenRoots' @($hidden | Where-Object { -not (Test-WtFlowPathIn ([string]$_) $Path) })
        return $true
    }
    if (Test-WtFlowPathIn $Path (Get-WtFlowRoots)) { return $false }
    Set-WtSetting 'workflows.roots' @(@(Get-WtSetting 'workflows.roots' | Where-Object { $_ }) + $Path)
    $true
}

# 폴더를 목록에서 뺀다. 기본 폴더는 뺀 것을 기억해서 다시 생기지 않는다 (폴더와 파일은 그대로)
function Remove-WtFlowRootPath([string]$Path) {
    $roots = @(Get-WtSetting 'workflows.roots' | Where-Object { $_ })
    $rest = @($roots | Where-Object { -not (Test-WtFlowPathIn ([string]$_) $Path) })
    if ($rest.Count -ne $roots.Count) { Set-WtSetting 'workflows.roots' $rest }
    $hidden = @(Get-WtSetting 'workflows.hiddenRoots' | Where-Object { $_ })
    if (@(Get-WtFlowDefaultRoots | Where-Object { Test-WtFlowPathIn $_.Path $Path }).Count -and -not (Test-WtFlowPathIn $Path $hidden)) {
        Set-WtSetting 'workflows.hiddenRoots' @($hidden + $Path)
    }
}

function New-WtFlowTreeItem([string]$Label, [int]$Icon, $Tag, [string]$ToolTip, [switch]$Muted) {
    $item = [System.Windows.Controls.TreeViewItem]::new()
    Set-WtStyle $item 'TreeItem'   # 트리의 항목 스타일은 맨 위 항목에만 붙어서, 안쪽 항목에도 직접 붙인다
    # 이름이 길면 칸 끝에서 …로 줄인다 (전체 경로는 마우스를 올리면 보인다)
    $row = [System.Windows.Controls.DockPanel]::new()
    $i = New-WtIcon $Icon
    Set-WtResource $i 'Foreground' 'B.SubText'
    $i.VerticalAlignment = 'Center'
    $i.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [System.Windows.Controls.DockPanel]::SetDock($i, 'Left')
    [void]$row.Children.Add($i)
    $t = New-WtText $Label $(if ($Muted) { 'T.Sub' } else { 'T.Body' })
    $t.TextWrapping = 'NoWrap'
    $t.TextTrimming = 'CharacterEllipsis'
    $t.VerticalAlignment = 'Center'
    [void]$row.Children.Add($t)
    $item.Header = $row
    $item.Tag = $Tag
    $item.IsExpanded = $true
    [System.Windows.Automation.AutomationProperties]::SetName($item, $Label)
    if ($ToolTip) { $item.ToolTip = $ToolTip }
    $item
}

# 왼쪽 목록: 저장한 업무 + 스크립트 폴더별 스크립트. 들어올 때 · F5마다 디스크를 다시 본다.
# 디스크는 화면 밖에서 폴더마다 보고 잠깐만 기다린 뒤 그린다. 늦게 끝난 폴더는 끝날 때 다시 그린다 (응답 없는 공유 폴더여도 화면이 멈추지 않는다)
function Update-WtFlowTree {
    Start-WtFlowDefaultsCheck   # 들어올 때 · F5마다 기본 폴더를 다시 찾는다 (앱 옆에 scripts를 나중에 넣어도 보이게)
    $flows = @(Get-WtFlows)
    $works = @(Start-WtFlowScans @(Get-WtFlowRoots) $flows)
    if ($works.Count) {
        # 로컬 폴더는 이 안에 끝나서 바로 그린다. 그사이 끝난 찾기는 따로 다시 그리지 않는다
        $script:scanWaiting = $true
        try { [void](Wait-WtWork $works -Milliseconds $script:scanWaitMs) } finally { $script:scanWaiting = $false }
    }
    Show-WtFlowTree $flows
}

# 스크립트 폴더 하나의 찾기 상태. 다시 찾는 동안(loading)에도 앞서 찾은 스크립트는 그대로 보인다(Prev)
function New-WtFlowScan([string]$Root, [string]$State, $Prev) {
    @{ Root = $Root; State = $State; Missing = $false; Scripts = $(if ($Prev) { @($Prev.Scripts) } else { @() }); Prev = [bool]$Prev; Error = $null; Work = $null }
}

# 폴더마다 화면 밖에서 스크립트를 찾고, 저장한 업무의 스크립트가 있는지 본다. 기다릴 작업들을 돌려준다.
# 이미 찾는 중인 폴더는 다시 시작하지 않고, 답 없는 곳(같은 드라이브 · 공유)에는 새로 묻지 않는다 (「응답 없음」)
function Start-WtFlowScans([string[]]$Roots, [object[]]$Flows) {
    foreach ($root in $Roots) {
        $k = ConvertTo-WtFlowPathKey $root
        $old = $script:scans[$k]
        if ($old -and $old.State -eq 'loading') { if ($old.Work) { $old.Work }; continue }
        $prev = if ($old -and ($old.State -eq 'ok' -or $old.Prev)) { $old } else { $null }
        $ioKey = Get-WtPathKey $root
        if (Test-WtWorkStuck $ioKey) { $script:scans[$k] = New-WtFlowScan $root 'slow' $prev; continue }
        $scan = New-WtFlowScan $root 'loading' $prev
        $script:scans[$k] = $scan
        if (-not $script:scanFunctions) { $script:scanFunctions = @(Get-Command Find-WtFlowScripts) }
        try {
            $scan.Work = Start-WtWork -Functions $script:scanFunctions -ArgumentList $root, $script:maxScripts `
                -Key $ioKey -TimeoutMs $script:scanTimeoutMs -Context $k -OnDone { param($w) Set-WtFlowScan $w } -Script $script:scanWork
            $scan.Work
        } catch { $scan.State = 'error'; $scan.Error = $_.Exception.Message }
    }
    $paths = @($Flows | ForEach-Object { [string]$_.script } | Where-Object { $_ } | Sort-Object -Unique)
    if ($paths.Count -and -not (Test-WtWorkStuck 'flow-files')) {
        try {
            $script:flowFilesWork = Start-WtWork -ArgumentList (, [string[]]$paths) -Key 'flow-files' -TimeoutMs $script:scanTimeoutMs `
                -OnDone { param($w) Set-WtFlowFiles $w } -Script {
                param($paths)
                $found = @{}
                foreach ($p in $paths) { $found[$p] = [System.IO.File]::Exists($p) }
                $found
            }
            $script:flowFilesWork
        } catch { }
    }
}

# 폴더 하나를 다 찾았을 때 (화면 스레드). 더 새 찾기가 있으면 버린다
function Set-WtFlowScan($Work) {
    $scan = $script:scans[[string]$Work.Context]
    if (-not $scan -or -not [object]::ReferenceEquals($scan.Work, $Work)) { return }
    if ($Work.State -eq 'done' -and $Work.Result) {
        $scan.State = 'ok'; $scan.Missing = [bool]$Work.Result.Missing; $scan.Scripts = @($Work.Result.Scripts); $scan.Prev = $false
    } elseif ($Work.TimedOut) { $scan.State = 'slow' }
    else { $scan.State = 'error'; $scan.Error = $Work.Error }
    Request-WtFlowTreeRedraw
}

function Set-WtFlowFiles($Work) {
    if (-not [object]::ReferenceEquals($script:flowFilesWork, $Work) -or $Work.State -ne 'done' -or $Work.Result -isnot [hashtable]) { return }
    foreach ($p in $Work.Result.Keys) { $script:flowFiles[$p] = [bool]$Work.Result[$p] }
    Request-WtFlowTreeRedraw
}

# 늦게 끝난 찾기를 목록에 넣는다. 여러 개가 끝나도 한 번만 다시 그린다.
# -Rescan: 기본 폴더가 바뀌었으니 다시 찾아서 그린다
function Request-WtFlowTreeRedraw([switch]$Rescan) {
    if ($Rescan) { $script:defaultRoots = $null; $script:rescanQueued = $true }
    if (($script:scanWaiting -and -not $Rescan) -or $script:redrawQueued -or -not $script:ui.Count) { return }
    $script:redrawQueued = $true
    [void]$script:ui.Tree.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{
            $script:redrawQueued = $false
            $rescan = $script:rescanQueued; $script:rescanQueued = $false
            try { if ($rescan) { Update-WtFlowTree } else { Show-WtFlowTree } } catch { Show-WtError $_ '업무 목록' }
        })
}

# 왼쪽 목록을 지금 찾은 결과로 그린다 (디스크는 보지 않는다). 지금 고른 것을 다시 고른다
function Show-WtFlowTree([object[]]$Items = @(Get-WtFlows)) {
    if (-not $script:ui.Count) { return }
    $tree = $script:ui.Tree
    $keep = if ($script:flow) { "flow:$($script:flow.id)" } elseif ($script:info) { "script:$($script:info.Path)" } else { '' }
    if ($script:pendingFlow) { $keep = "flow:$($script:pendingFlow)"; $script:pendingFlow = $null }
    $flows = @($Items)
    $groups = @(foreach ($root in @(Get-WtFlowRoots)) {
            $s = $script:scans[(ConvertTo-WtFlowPathKey $root)]
            if (-not $s) { $s = New-WtFlowScan $root 'loading' $null }
            $state = if ($s.State -eq 'loading' -and $s.Prev) { 'ok' } else { $s.State }
            [pscustomobject]@{ Root = $root; Missing = [bool]$s.Missing; Scripts = @($s.Scripts); State = $state; Error = $s.Error }
        })
    $missingPaths = @{}
    foreach ($f in $flows) { $missingPaths[[string]$f.script] = $script:flowFiles[[string]$f.script] -eq $false }
    $key = ConvertTo-Json -Compress -Depth 10 -InputObject @($flows, $groups, $missingPaths, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale'))
    $script:filling = $true
    try {
        $found = $null
        if ($script:treeKey -ceq $key) {
            # 진입 때마다 펼침·선택을 초기화하는 동작은 유지하고, 같은 노드의 생성만 생략한다.
            $queue = [Collections.Generic.Queue[object]]::new()
            foreach ($node in $tree.Items) { $queue.Enqueue($node) }
            while ($queue.Count) {
                $node = $queue.Dequeue(); $node.IsExpanded = $true; $node.IsSelected = $false
                if (($node.Tag.Kind -eq 'flow' -and $keep -eq "flow:$($node.Tag.Id)") -or
                    ($node.Tag.Kind -eq 'script' -and $keep -eq "script:$($node.Tag.Path)")) { $found = $node }
                foreach ($child in $node.Items) { $queue.Enqueue($child) }
            }
        } else {
            $tree.Items.Clear()
            $saved = New-WtFlowTreeItem '저장한 업무' 0xE734 @{ Kind = 'group' }
            foreach ($f in $flows) {
                $missing = $missingPaths[[string]$f.script]
                $label = if ($missing) { "$($f.title) · 스크립트 없음" } else { [string]$f.title }
                $node = New-WtFlowTreeItem $label 0xE768 @{ Kind = 'flow'; Id = [string]$f.id } ([string]$f.script)
                [void]$saved.Items.Add($node)
                if ($keep -eq "flow:$($f.id)") { $found = $node }
            }
            if (-not $flows.Count) {
                $hint = New-WtFlowTreeItem '아직 없습니다' 0xE946 @{ Kind = 'hint' } '스크립트를 고르고 [업무로 저장]하면 여기에 생깁니다' -Muted
                $hint.Focusable = $false
                [void]$saved.Items.Add($hint)
            }
            [void]$tree.Items.Add($saved)
            # 이름이 같은 스크립트 폴더가 둘 이상이면 위 폴더 이름을 붙여 구분한다 (예: mywork\scripts)
            # 기본 폴더(내 스크립트 · 예제 스크립트)는 정해 둔 이름으로 보인다
            $leafCount = @{}
            foreach ($g in $groups) { $leaf = Split-Path $g.Root -Leaf; $leafCount[$leaf] = 1 + [int]$leafCount[$leaf] }
            foreach ($group in $groups) {
                $rootName = Split-Path $group.Root -Leaf
                $fixedName = Get-WtFlowRootLabel $group.Root
                if ($fixedName) { $rootName = $fixedName }
                elseif (-not $rootName) { $rootName = $group.Root }
                elseif ($leafCount[$rootName] -gt 1) {
                    $parentName = Split-Path (Split-Path $group.Root -Parent) -Leaf
                    if ($parentName) { $rootName = "$parentName\$rootName" }
                }
                $label = switch ($group.State) {
                    'loading' { "$rootName · 읽는 중…" }
                    'slow' { "$rootName · 응답 없음" }
                    'error' { "$rootName · 읽지 못함" }
                    default { if ($group.Missing) { "$rootName · 폴더 없음" } else { $rootName } }
                }
                $rootNode = New-WtFlowTreeItem $label 0xE8B7 @{ Kind = 'root'; Path = $group.Root } $group.Root
                if ($group.State -in 'slow', 'error') {
                    $why = if ($group.State -eq 'slow') { "폴더가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인한 뒤 F5를 누르세요: $($group.Root)" }
                    else { "폴더를 읽지 못했습니다: $($group.Error)" }
                    $hint = New-WtFlowTreeItem $(if ($group.State -eq 'slow') { '응답하지 않는 폴더' } else { '읽지 못한 폴더' }) 0xE946 @{ Kind = 'hint' } $why -Muted
                    $hint.Focusable = $false
                    [void]$rootNode.Items.Add($hint)
                }
                $folders = @{}
                foreach ($s in $group.Scripts) {
                    $parent = $rootNode
                    if ($s.Folder) {
                        if (-not $folders.ContainsKey($s.Folder)) {
                            $folders[$s.Folder] = New-WtFlowTreeItem $s.Folder 0xE8B7 @{ Kind = 'folder' } (Join-Path $group.Root $s.Folder)
                            [void]$rootNode.Items.Add($folders[$s.Folder])
                        }
                        $parent = $folders[$s.Folder]
                    }
                    $node = New-WtFlowTreeItem $s.Name 0xE756 @{ Kind = 'script'; Path = $s.Path } $s.Path
                    [void]$parent.Items.Add($node)
                    if ($keep -eq "script:$($s.Path)") { $found = $node }
                }
                if ($group.State -eq 'ok' -and -not $group.Missing -and -not $group.Scripts.Count) {
                    $hint = New-WtFlowTreeItem '.ps1 파일 없음' 0xE946 @{ Kind = 'hint' } "이 폴더에 .ps1 파일을 넣고 F5를 누르면 여기에 보입니다: $($group.Root)" -Muted
                    $hint.Focusable = $false
                    [void]$rootNode.Items.Add($hint)
                }
                [void]$tree.Items.Add($rootNode)
            }
        }
        if ($found) { $found.IsSelected = $true; $found.BringIntoView() }
        $script:ui.RemoveRoot.IsEnabled = $false   # 다시 만든 목록에서는 고른 폴더가 없다
    } finally { $script:filling = $false }
    $script:treeKey = $key
    # 다시 고르면 같은 수명이라 고치던 칸 값과 실행 방식은 그대로 둔다 (다른 탭에 다녀오거나 늦게 끝난 폴더 찾기로 다시 그려도)
    if ($found) { Select-WtFlowNode $found.Tag -Reuse }
    elseif ($keep) { Clear-WtFlowSelection }
    else { Update-WtFlowCenter -Reuse }
}

function Add-WtFlowRoot {
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = '업무 탭에서 실행할 스크립트(.ps1)가 있는 폴더를 고르세요'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $path = $dlg.SelectedPath
    $added = Add-WtFlowRootPath $path
    Update-WtFlowTree
    Set-WtFlowNote $(if ($added) { "스크립트 폴더를 더했습니다: $path" } else { "이미 목록에 있는 폴더입니다: $path" })
}

function Remove-WtFlowRoot {
    $node = $script:ui.Tree.SelectedItem
    if (-not $node -or $node.Tag.Kind -ne 'root') { return }
    $path = $node.Tag.Path
    Remove-WtFlowRootPath $path
    Clear-WtFlowSelection
    Update-WtFlowTree
    Set-WtFlowNote "목록에서 뺐습니다: $path (폴더와 파일은 그대로)"
}

# ---- 화면: 고른 것 · 폼 -------------------------------------------------------------------------

function Clear-WtFlowSelection {
    $script:selection = $null   # 고른 것의 수명을 끝낸다: 아직 오는 중인 읽기 결과는 넣지 않는다
    $script:readSeq++
    $script:info = $null
    $script:flow = $null
    $script:fields = @()
    if ($script:ui.Count) { $script:ui.RemoveRoot.IsEnabled = $false }
    Update-WtFlowCenter
}

# 출력 칸 · 결과를 비운다. 다른 스크립트를 고르면 앞 실행의 출력을 남기지 않는다 (실행 중이면 그대로 둔다)
function Reset-WtFlowOutput([string]$Key) {
    if ($script:run -or $Key -eq $script:outputKey) { return }
    $u = $script:ui
    $u.Output.Clear()
    $u.OutputHint.Visibility = 'Visible'
    $u.Status.Visibility = 'Collapsed'
    $u.RunStatus.Child = $null
    $script:outputKey = $null
}

<#
고른 것의 수명. 사용자가 다른 것을 고르거나, 선택을 비우거나(업무 삭제 포함), 화면을 새로 만들면 수명이 끝난다.
늦게 온 읽기 결과는 같은 수명일 때만 넣는다. 고치던 칸 값은 일회성 요청이 아니라 이 수명(Edits)에 둔다.
  -Keep: 같은 것을 다시 고른 것(목록을 다시 그림 · 탭에 다시 들어옴)이면 수명을 이어 가고 지금 칸 값을 남긴다
#>
function Enter-WtFlowSelection([string]$Key, [bool]$Keep) {
    if ($Keep -and $script:selection -and $script:selection.Key -ceq $Key) { Save-WtFlowEdits; return }
    $script:selection = @{ Key = $Key; Edits = $null; Mode = $null }
}

# 지금 폼의 칸 값을 고른 것의 수명에 남긴다. 폼이 「읽는 중」이거나 칸이 없으면 앞서 남긴 값을 그대로 둔다.
# 실행 방식은 사용자가 바꾸는 순간 수명에 남는다 (Set-WtFlowModeChoice). 칸 수 · 읽는 중과 상관없다
function Save-WtFlowEdits {
    $sel = $script:selection
    if (-not $sel -or -not $script:fields.Count -or -not $script:info -or $script:info.Loading) { return }
    $sel.Edits = @{ Values = (Get-WtFlowFormValues) }
}

# 사용자가 실행 방식을 바꿨을 때: 고른 것의 수명에 바로 남긴다 (화면이 단추를 맞추는 중이면 사용자가 고른 것이 아니다)
function Set-WtFlowModeChoice([string]$Value) {
    if (-not $script:modeSync -and $script:selection) { $script:selection.Mode = $Value }
}

# 실행 방식 단추를 맞춘다 (사용자가 고른 것으로 남기지 않는다)
function Set-WtFlowModeButtons([string]$Mode) {
    $script:modeSync = $true
    try { foreach ($rb in $script:ui.ModeButtons) { $rb.IsChecked = ($rb.Tag.Value -eq $Mode) } } finally { $script:modeSync = $false }
}

function Select-WtFlowNode($Tag, [switch]$Reuse) {
    $script:ui.RemoveRoot.IsEnabled = ($Tag.Kind -eq 'root')
    if ($Tag.Kind -eq 'script') { Reset-WtFlowOutput "script:$($Tag.Path)" }
    elseif ($Tag.Kind -eq 'flow') { Reset-WtFlowOutput "flow:$($Tag.Id)" }
    switch ($Tag.Kind) {
        'script' {
            Enter-WtFlowSelection "script:$($Tag.Path)" ([bool]$Reuse)
            $script:flow = $null
            Request-WtFlowScript $Tag.Path -Reuse:$Reuse
        }
        'flow' {
            $f = Get-WtFlows | Where-Object { $_.id -eq $Tag.Id } | Select-Object -First 1
            if (-not $f) { Clear-WtFlowSelection; return }
            Enter-WtFlowSelection "flow:$($Tag.Id)" ([bool]$Reuse)
            $script:flow = $f
            Request-WtFlowScript ([string]$f.script) -Reuse:$Reuse
        }
    }
}

# 고른 스크립트를 화면 밖에서 읽는다 (구문만, 실행하지 않음). 잠깐 기다려 그 안에 읽히면 바로 폼을 그리고,
# 아니면 「읽는 중」을 보였다가 읽히면 그린다. 그사이 다른 것을 고르면 늦게 온 결과는 버린다
function Request-WtFlowScript([string]$Path, [switch]$Reuse) {
    $script:readSeq++
    $ctx = @{ Seq = $script:readSeq; Path = $Path; Reuse = [bool]$Reuse; Life = $script:selection }
    $ioKey = Get-WtPathKey $Path
    if (Test-WtWorkStuck $ioKey) { Set-WtFlowScriptInfo $ctx (New-WtFlowInfo $Path (Get-WtFlowSlowText)); return }
    try {
        $w = Start-WtWork -Call (& $script:readCall $Path) -Key $ioKey -TimeoutMs $script:readTimeoutMs -Context $ctx -OnDone { param($w) Complete-WtFlowScriptRead $w }
    } catch { Set-WtFlowScriptInfo $ctx (New-WtFlowInfo $Path "스크립트를 읽지 못했습니다: $($_.Exception.Message)"); return }
    if (-not (Wait-WtWork $w -Milliseconds $script:readWaitMs)) { Set-WtFlowScriptInfo $ctx (New-WtFlowInfo $Path '스크립트를 읽는 중입니다…' -Loading) -Waiting }
}

function Get-WtFlowSlowText { '스크립트 폴더가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인한 뒤 F5를 누르세요.' }

function Complete-WtFlowScriptRead($Work) {
    $ctx = $Work.Context
    $info = if ($Work.State -eq 'done') { ConvertTo-WtFlowInfo $ctx.Path ([string]$Work.Result) }
    elseif ($Work.TimedOut) { New-WtFlowInfo $ctx.Path (Get-WtFlowSlowText) }
    elseif ($Work.Exception -is [System.IO.FileNotFoundException] -or $Work.Exception -is [System.IO.DirectoryNotFoundException]) { New-WtFlowMissingInfo $ctx.Path }
    else { New-WtFlowInfo $ctx.Path "스크립트를 읽지 못했습니다: $($Work.Error)" }
    Set-WtFlowScriptInfo $ctx $info
}

# 읽은 스크립트를 가운데에 그린다. 그사이 다른 것을 골랐거나 선택을 비웠으면(수명이 끝남) 버린다.
# -Waiting: 읽는 중 표시. 고치던 칸 값(수명의 Edits)은 읽힌 뒤 폼에 다시 넣는다
function Set-WtFlowScriptInfo($Ctx, $Info, [switch]$Waiting) {
    if ($Ctx.Seq -ne $script:readSeq -or -not $Ctx.Life -or -not [object]::ReferenceEquals($Ctx.Life, $script:selection)) { return }
    $script:info = $Info
    Update-WtFlowCenter -Reuse:$Ctx.Reuse
    $edits = $Ctx.Life.Edits
    if ($Waiting -or -not $edits -or $Info.Error) { return }
    Set-WtFlowFormValues $edits.Values
}

# 가운데 · 오른쪽을 고른 것에 맞춘다
function Update-WtFlowCenter([switch]$Reuse) {
    $u = $script:ui
    if (-not $u.Count) { return }
    $hasFlows = @(Get-WtFlows).Count -gt 0
    $key = ConvertTo-Json -Compress -Depth 10 -InputObject @($script:info, $script:flow, @(Get-WtFlowRoots), $hasFlows, (Test-WtFlowBusy), (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale'))
    if ($Reuse -and $script:centerKey -ceq $key) {
        foreach ($entry in $script:fields) { Set-WtFlowFieldError $entry '' }
        Update-WtFlowCommands; Update-WtFlowHelp; return
    }
    $u.Form.Children.Clear()
    $script:fields = @()
    $hasRoots = (Get-WtFlowRoots).Count -gt 0
    if (-not $script:info) {
        $u.Title.Text = '업무'
        $u.Sub.Text = if ($hasRoots -or $hasFlows) { '왼쪽에서 스크립트나 저장한 업무를 고르세요.' } else { '스크립트 폴더를 더하면 그 안의 스크립트를 폼으로 실행합니다.' }
        Set-WtResource $u.Sub 'Foreground' 'B.SubText'
        $u.Title.ToolTip = $null
        $u.Empty.Visibility = if ($hasRoots -or (Test-WtFlowBusy)) { 'Collapsed' } else { 'Visible' }
        foreach ($x in @($u.SaveFlow, $u.DeleteFlow, $u.Repick)) { $x.Visibility = 'Collapsed' }
        # 실행 중에는 고른 것이 없어져도 [취소]와 출력은 계속 보인다
        $keep = if (Test-WtFlowBusy) { 'Visible' } else { 'Collapsed' }
        $u.Commands.Visibility = $keep
        $u.OutArea.Visibility = $keep
        Update-WtFlowCommands
        Update-WtFlowHelp
        $script:centerKey = $key
        return
    }
    $u.Empty.Visibility = 'Collapsed'
    $u.Commands.Visibility = 'Visible'
    $u.SaveFlow.Visibility = 'Visible'
    $u.OutArea.Visibility = 'Visible'
    $info = $script:info
    $u.Title.Text = if ($script:flow) { [string]$script:flow.title } else { $info.Name }
    $u.Title.ToolTip = $info.Path
    $u.Sub.Text = if ($info.Error) { $info.Error } elseif ($info.Synopsis) { $info.Synopsis } else { $info.Warning }
    if ($info.Error -and -not $info.Loading) { Set-WtResource $u.Sub 'Foreground' 'B.Danger' } else { Set-WtResource $u.Sub 'Foreground' 'B.SubText' }
    $values = if ($script:flow) { ConvertTo-WtFlowValues $script:flow.values } else { @{} }
    if ($script:flow -and -not $info.Loading) {
        $stale = @(Get-WtFlowStaleNames $info $values)
        if ($stale.Count) {
            $note = New-WtText "스크립트에 없는 값 $($stale.Count)개는 넘기지 않습니다: $($stale -join ', ')" 'T.Sub'
            Set-WtResource $note 'Foreground' 'B.Warn'
            $note.TextWrapping = 'Wrap'
            [void](Add-WtChild $u.Form $note)
        }
    }
    # 폼에 넣을 수 없는 필수 값은 [앱 안에서]를 막는 이유라서 칸보다 먼저 보인다
    if ($info.NeedsConsole.Count) {
        $need = New-WtText "필수 값 $($info.NeedsConsole -join ', ')은(는) 폼에 넣을 수 없어서 콘솔 창에서만 실행합니다. 창에서 PowerShell이 직접 묻습니다." 'T.Sub'
        Set-WtResource $need 'Foreground' 'B.Warn'
        $need.TextWrapping = 'Wrap'
        [void](Add-WtChild $u.Form $need)
    }
    foreach ($f in $info.Fields) { New-WtFlowField $f $values }
    if (-not $info.Fields.Count -and -not $info.Error) { [void](Add-WtChild $u.Form (New-WtText '넣을 값이 없는 스크립트입니다. [실행]을 누르면 바로 실행합니다.' 'T.Sub')) }
    # 여기서는 비워 두면 스크립트 기본값을 쓰는 값만 알린다 (필수 값은 위에서 알렸다)
    $plain = @($info.Skipped | Where-Object { -not $_.Secret -and -not $_.Mandatory })
    $secret = @($info.Skipped | Where-Object { $_.Secret -and -not $_.Mandatory })
    if ($plain.Count) {
        $names = ($plain | ForEach-Object { "$($_.Name)($($_.TypeName))" }) -join ', '
        $skip = New-WtText "폼에서 넣을 수 없는 값 $($plain.Count)개는 스크립트 기본값을 씁니다: $names" 'T.Sub'
        $skip.TextWrapping = 'Wrap'
        [void](Add-WtChild $u.Form $skip)
    }
    if ($secret.Count) {
        $skip = New-WtText "비밀 값 $($secret.Count)개는 폼에 넣지 않고(저장한 업무 · 기록에 남지 않게) 스크립트 기본값을 씁니다: $(($secret | ForEach-Object Name) -join ', ')" 'T.Sub'
        $skip.TextWrapping = 'Wrap'
        [void](Add-WtChild $u.Form $skip)
    }
    # 실행 방식: 이번에 고른 것에서 사용자가 바꾼 것 → 업무에 저장한 것 → 스크립트가 정한 것(.NOTES의 WorkTool: 콘솔, 폼에 못 넣는 필수 값) → 앱 안
    $mode = if ($script:selection -and $script:selection.Mode) { [string]$script:selection.Mode }
    elseif ($script:flow -and $script:flow.mode) { [string]$script:flow.mode } elseif ($info.Console -or $info.NeedsConsole.Count) { 'console' } else { 'app' }
    Set-WtFlowModeButtons $mode
    $u.SaveFlow.Content = New-WtButtonContent $(if ($script:flow) { '업무 저장' } else { '업무로 저장' }) 0xE74E
    $u.SaveFlow.ToolTip = if ($script:flow) { '지금 값과 실행 방식을 이 업무에 저장합니다' } else { '지금 값과 실행 방식을 업무로 저장해 왼쪽 목록에 둡니다' }
    $u.DeleteFlow.Visibility = if ($script:flow) { 'Visible' } else { 'Collapsed' }
    $u.Repick.Visibility = if ($script:flow -and $info.Missing) { 'Visible' } else { 'Collapsed' }
    Update-WtFlowCommands
    Update-WtFlowHelp
    $script:centerKey = $key
}

# 칸 하나: 라벨(필수) · 설명 · 입력 · 오류
function New-WtFlowField($Field, [hashtable]$Values) {
    $box = New-WtStack Vertical 8
    $value = if ($Values.ContainsKey($Field.Name)) { $Values[$Field.Name] } else { $Field.Default }
    $control = $null
    if ($Field.Kind -eq 'switch') {
        $control = [System.Windows.Controls.CheckBox]::new()
        Set-WtStyle $control 'Check'
        $control.Content = $Field.Name
        $control.IsChecked = ($value -eq $true)
        [void](Add-WtChild $box $control)
        if ($Field.Help) { $h = New-WtText $Field.Help 'T.Sub'; $h.TextWrapping = 'Wrap'; [void](Add-WtChild $box $h) }
    } else {
        $label = New-WtText $(if ($Field.Mandatory) { "$($Field.Name) (필수)" } else { $Field.Name }) 'T.Strong'
        [void](Add-WtChild $box $label)
        $helpText = $Field.Help
        if (-not $Field.Mandatory -and $null -eq $Field.Default) { $helpText = (@($helpText, '비우면 스크립트 기본값') | Where-Object { $_ }) -join ' · ' }
        if ($helpText) { $h = New-WtText $helpText 'T.Sub'; $h.TextWrapping = 'Wrap'; [void](Add-WtChild $box $h) }
        if ($Field.Kind -eq 'choice') {
            $control = [System.Windows.Controls.ComboBox]::new()
            Set-WtStyle $control 'Combo'
            if (-not $Field.Mandatory) { [void]$control.Items.Add('(기본값)') }
            foreach ($c in $Field.Choices) { [void]$control.Items.Add($c) }
            $pick = if ($null -ne $value -and $Field.Choices -contains [string]$value) { [string]$value } elseif (-not $Field.Mandatory) { '(기본값)' } else { $null }
            if ($pick) { $control.SelectedItem = ($control.Items | Where-Object { $_ -eq $pick } | Select-Object -First 1) }
            $control.HorizontalAlignment = 'Left'
            $control.MinWidth = 200
            [System.Windows.Automation.AutomationProperties]::SetName($control, $Field.Name)
            [void](Add-WtChild $box $control)
        } else {
            $control = [System.Windows.Controls.TextBox]::new()
            Set-WtStyle $control 'Input'
            if ($null -ne $value) { $control.Text = [string]$value }
            [System.Windows.Automation.AutomationProperties]::SetName($control, $Field.Name)
            if ($Field.Kind -eq 'number') {
                $control.Width = 160
                $control.HorizontalAlignment = 'Left'
                [void](Add-WtChild $box $control)
            } elseif ($Field.Kind -in 'file', 'folder') {
                $row = [System.Windows.Controls.DockPanel]::new()
                $browse = New-WtButton '찾아보기' -Icon 0xE838
                $browse.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
                $browse.Tag = @{ Input = $control; Kind = $Field.Kind }
                $browse.Add_Click({ param($s, $e) Select-WtFlowPath $s.Tag.Input $s.Tag.Kind })
                [System.Windows.Controls.DockPanel]::SetDock($browse, 'Right')
                [void]$row.Children.Add($browse)
                [void]$row.Children.Add($control)
                [void](Add-WtChild $box $row)
            } else {
                [void](Add-WtChild $box $control)
            }
        }
    }
    $err = New-WtText '' 'T.Sub'
    Set-WtResource $err 'Foreground' 'B.Danger'
    $err.Visibility = 'Collapsed'
    [void](Add-WtChild $box $err)
    [void](Add-WtChild $script:ui.Form $box)
    $entry = @{ Field = $Field; Input = $control; Error = $err }
    if ($Field.Kind -eq 'number') {
        # 숫자 칸은 칸을 떠날 때 형식 · 범위를 바로 알린다. 비운 필수 칸은 [실행]할 때 알린다
        $control.Tag = $entry
        $control.Add_LostKeyboardFocus({ param($s, $e) if ($s.Text.Trim()) { Set-WtFlowFieldError $s.Tag } else { Set-WtFlowFieldError $s.Tag '' } })
    }
    $script:fields += $entry
}

# 칸 아래 오류 한 줄. 화면 읽기 프로그램도 읽게 칸의 도움말에 같은 글을 둔다. $Message를 안 주면 그 칸만 검사한다
function Set-WtFlowFieldError($Entry, $Message) {
    if ($null -eq $Message) {
        $Message = (Test-WtFlowValues ([pscustomobject]@{ Fields = @($Entry.Field) }) @{ $Entry.Field.Name = $Entry.Input.Text })[$Entry.Field.Name]
    }
    $Entry.Error.Text = [string]$Message
    $Entry.Error.Visibility = if ($Message) { 'Visible' } else { 'Collapsed' }
    [System.Windows.Automation.AutomationProperties]::SetHelpText($Entry.Input, [string]$Message)
}

# 선택 창의 처음 폴더가 있는지 화면 밖에서 잠깐만 본다. 답이 없으면(응답 없는 공유 폴더) 처음 폴더를 넘기지 않는다.
# 넘기면 선택 창이 열리면서 그 폴더를 기다리느라 멈춘다. 창 안에서 사용자가 공유 폴더로 옮겨 가는 것은 Windows 선택 창이 처리한다
function Test-WtFlowFolder([string]$Path) {
    if (-not $Path) { return $false }
    try { [bool](Invoke-WtWork -Key (Get-WtPathKey $Path) -TimeoutMs 1500 -ArgumentList $Path -Script { param($p) [System.IO.Directory]::Exists($p) }) }
    catch { $false }
}

function Select-WtFlowPath($TextBox, [string]$Kind) {
    if ($Kind -eq 'folder') {
        $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
        if (Test-WtFlowFolder $TextBox.Text) { $dlg.SelectedPath = $TextBox.Text }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $TextBox.Text = $dlg.SelectedPath }
        return
    }
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dir = ''
    try { $dir = if ($TextBox.Text) { Split-Path $TextBox.Text -Parent } elseif ($script:info) { Split-Path $script:info.Path -Parent } } catch { }
    if (Test-WtFlowFolder $dir) { $dlg.InitialDirectory = $dir }
    if ($dlg.ShowDialog()) { $TextBox.Text = $dlg.FileName }
}

# 폼의 값: @{ 이름 = 글자 | $true/$false }. (기본값)을 고른 칸은 넘기지 않게 비운다
function Get-WtFlowFormValues {
    $values = @{}
    foreach ($x in $script:fields) {
        $values[$x.Field.Name] = switch ($x.Field.Kind) {
            'switch' { [bool]$x.Input.IsChecked }
            'choice' { if ($x.Input.SelectedItem -and $x.Input.SelectedItem -ne '(기본값)') { [string]$x.Input.SelectedItem } else { '' } }
            default { $x.Input.Text }
        }
    }
    $values
}

function Get-WtFlowMode { $rb = $script:ui.ModeButtons | Where-Object { $_.IsChecked } | Select-Object -First 1; if ($rb) { $rb.Tag.Value } else { 'app' } }

# 폼에 값을 다시 채운다 (화면을 다시 열 때 고치던 값을 지키려고)
function Set-WtFlowFormValues([hashtable]$Values) {
    foreach ($x in $script:fields) {
        if (-not $Values.ContainsKey($x.Field.Name)) { continue }
        $v = $Values[$x.Field.Name]
        switch ($x.Field.Kind) {
            'switch' { $x.Input.IsChecked = [bool]$v }
            'choice' {
                $pick = if ([string]$v) { [string]$v } else { '(기본값)' }
                $item = $x.Input.Items | Where-Object { $_ -eq $pick } | Select-Object -First 1
                if ($item) { $x.Input.SelectedItem = $item }
            }
            default { $x.Input.Text = [string]$v }
        }
    }
}

# 명령 버튼: 못 쓸 때는 숨기지 않고 비활성 + 이유
function Update-WtFlowCommands {
    $u = $script:ui
    if (-not $u.Count) { return }
    $running = Test-WtFlowBusy
    $app = (Get-WtFlowMode) -eq 'app'
    # 앱 안 실행은 한 번에 하나. 콘솔 창은 따로 도는 창이라 앱 안 실행 중에도 띄울 수 있다
    $why = if (-not $script:info) { '스크립트를 먼저 고르세요' }
    elseif ($script:info.Error) { $script:info.Error }
    elseif ($app -and $script:info.NeedsConsole.Count) { "필수 값 $($script:info.NeedsConsole -join ', ')은(는) 폼에 넣을 수 없어서 콘솔 창에서만 실행할 수 있습니다" }
    elseif ($app -and $running) { '다른 스크립트가 앱 안에서 실행 중입니다. 끝나거나 [취소]한 뒤에 실행하세요 (콘솔 창 실행은 됩니다)' }
    else { '' }
    $u.RunButton.IsEnabled = -not $why
    $u.RunButton.ToolTip = if ($why) { $why } else { '이 값으로 실행합니다' }
    $previewWhy = if ($why) { $why } elseif (-not $script:info.WhatIf) { '이 스크립트는 미리보기(-WhatIf)를 지원하지 않습니다' } else { '' }
    $u.Preview.IsEnabled = -not $previewWhy
    $u.Preview.ToolTip = if ($previewWhy) { $previewWhy } else { '-WhatIf로 할 일만 보여 줍니다. 바꾸는 것은 없습니다' }
    $u.Cancel.IsEnabled = $running
    $u.Cancel.ToolTip = if ($running) { '실행 중인 스크립트를 끝냅니다 (자식 프로세스까지)' } else { '앱 안에서 실행 중일 때만 쓸 수 있습니다' }
    # 스크립트를 읽지 못하면 칸이 없어서, 저장하면 업무의 값이 비워진다 → 저장을 막는다
    $saveWhy = if (-not $script:info) { '스크립트를 먼저 고르세요' } elseif ($script:info.Error) { "스크립트를 읽지 못해서 저장할 수 없습니다: $($script:info.Error)" } else { '' }
    $u.SaveFlow.IsEnabled = -not $saveWhy
    if ($saveWhy) { $u.SaveFlow.ToolTip = $saveWhy }
}

function Set-WtFlowNote([string]$Text, [switch]$Undo) {
    if (-not $script:ui.Count) { return }
    $script:ui.Note.Text = $Text
    $script:ui.Undo.Visibility = if ($Undo) { 'Visible' } else { 'Collapsed' }
    $script:ui.NoteRow.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
}

# ---- 실행 ---------------------------------------------------------------------------------------

function Invoke-WtFlowRun([switch]$WhatIf) {
    if (-not $script:info -or $script:info.Error) { return }
    $mode = Get-WtFlowMode
    if ($mode -eq 'app' -and ((Test-WtFlowBusy) -or $script:info.NeedsConsole.Count)) { return }
    $values = Get-WtFlowFormValues
    $problems = Test-WtFlowValues $script:info $values
    $first = $null
    foreach ($x in $script:fields) {
        $msg = [string]$problems[$x.Field.Name]
        Set-WtFlowFieldError $x $msg
        if ($msg -and -not $first) { $first = $x.Input }
    }
    if ($first) { [void]$first.Focus(); Set-WtFlowNote '칸을 고친 뒤 다시 실행하세요.'; return }
    $title = if ($script:flow) { [string]$script:flow.title } else { '' }
    $flowId = if ($script:flow) { [string]$script:flow.id } else { '' }
    $record = New-WtFlowRecord $script:info $values $mode ([bool]$WhatIf) $title $flowId
    # 프로세스는 화면 밖에서 시작한다. 작업 폴더(스크립트 폴더)가 응답 없는 공유 폴더면 시작 자체가 기다린다.
    # 시작을 기다리는 사이 [취소] · 앱 종료로 취소 표시가 붙으면, 늦게 시작된 프로세스는 그 자리에서 끝낸다
    $ctx = @{
        Mode = $mode; Record = $record; Name = $script:info.Name; WhatIf = [bool]$WhatIf; Cancelled = $false; Work = $null
        OutputKey = $(if ($script:flow) { "flow:$($script:flow.id)" } else { "script:$($script:info.Path)" })
        Owner = [hashtable]::Synchronized(@{ Process = $null; Stopped = $false; Taken = $false })   # 화면이 넘겨받기 전까지 만든 프로세스를 가진다
    }
    if (-not $script:startFunctions) { $script:startFunctions = @(Get-Command Start-WtFlowChild) }
    try {
        $start = New-WtFlowStartInfo $script:info $values $mode -WhatIf:$WhatIf
        $ctx.Work = Start-WtWork -ArgumentList @($start, $ctx.Owner) -Functions $script:startFunctions -Sta:($mode -eq 'console') -Key (Get-WtPathKey $start.WorkingDirectory) `
            -TimeoutMs $script:startTimeoutMs -Context $ctx -OnDone { param($w) Complete-WtFlowStart $w } -Script $script:startWork
    } catch {
        Set-WtFlowNote "실행하지 못했습니다: $($_.Exception.Message)"
        return
    }
    if ($mode -eq 'app') { $script:starting = $ctx }
    if (-not (Wait-WtWork $ctx.Work -Milliseconds $script:startWaitMs)) {
        Set-WtFlowNote '스크립트를 시작하는 중입니다… (스크립트 폴더의 응답을 기다립니다)'
        Update-WtFlowCommands
    }
}

# 프로세스 시작이 끝났을 때 (화면 스레드). 앱 안 실행이면 출력 받기를 시작하고, 콘솔 창이면 기록만 한다
function Complete-WtFlowStart($Work) {
    $ctx = $Work.Context
    if ([object]::ReferenceEquals($script:starting, $ctx)) { $script:starting = $null }
    $p = if ($Work.State -eq 'done') { $Work.Result } else { $null }
    if ($Work.State -ne 'done') {
        # 시간 초과 · 실패: 취소와 같은 길로 멈춘다. 그 뒤 늦게 만들어지는 프로세스는 만든 쪽이 끝내고, 이미 만들어진 것은 여기서 끝낸다
        $wasCancelled = [bool]$ctx.Cancelled
        Stop-WtFlowStarting $ctx
        $ctx.Cancelled = $wasCancelled   # 사용자가 먼저 취소했으면 취소로 알린다
    } else {
        # 넘겨받는다. 그 사이 멈췄으면(같은 잠금 안에서 확인) 넘겨받지 않고 끝낸다
        $owner = $ctx.Owner
        [System.Threading.Monitor]::Enter($owner.SyncRoot)
        try { if (-not $owner.Stopped) { $owner.Taken = $true } else { $ctx.Cancelled = $true } } finally { [System.Threading.Monitor]::Exit($owner.SyncRoot) }
    }
    if ($ctx.Cancelled) {
        if ($p) { try { $p.Kill($true) } catch { }; $p.Dispose() }
        Set-WtFlowNote '실행을 취소했습니다.'
        Update-WtFlowCommands
        return
    }
    if ($Work.State -ne 'done' -or (-not $p -and $ctx.Mode -eq 'app')) {
        $why = if ($Work.TimedOut) { Get-WtFlowSlowText } elseif ($Work.Error) { $Work.Error } else { '프로세스를 시작하지 못했습니다.' }
        Set-WtFlowNote "실행하지 못했습니다: $why"
        Update-WtFlowCommands
        return
    }
    if ($ctx.Mode -eq 'console') {
        if ($p) { $script:consoles.Add(@{ Process = $p; Record = $ctx.Record }) }
        $note = "콘솔 창을 띄웠습니다: $($ctx.Name). 그 창에서 끝내고 닫으세요."
        try { Save-WtFlowRun $ctx.Record } catch { $note += " (실행 기록은 저장하지 못했습니다: $($_.Exception.Message))" }
        Set-WtFlowNote $note
        Start-WtFlowTimer
        Update-WtFlowHelp
        return
    }
    try { $script:run = Start-WtFlowProcess $null $ctx.Record -Process $p }
    catch {
        try { $p.Kill($true) } catch { }
        Set-WtFlowNote "실행하지 못했습니다: $($_.Exception.Message)"
        Update-WtFlowCommands
        return
    }
    $u = $script:ui
    $script:outputKey = $ctx.OutputKey
    $script:shown = 1
    if ($u.Count) {
        $u.Output.Clear()
        $head = "▶ $($ctx.Name)$(if ($ctx.WhatIf) { ' (미리보기)' }) · $((Get-Date).ToString('HH:mm:ss')) 시작"
        $u.Output.AppendText($head)
        $u.OutputHint.Visibility = 'Collapsed'
        $u.Status.Visibility = 'Visible'
        $u.Busy.Visibility = 'Visible'
        $u.RunStatus.Child = $null
        $u.Elapsed.Text = '실행 중 · 0초'
    }
    Set-WtFlowNote ''
    Update-WtFlowCommands
    Start-WtFlowTimer
}

# 앱 안 실행이 돌거나 시작하는 중인지 (앱 안 실행은 한 번에 하나)
function Test-WtFlowBusy { [bool]$script:run -or [bool]$script:starting }

function Stop-WtFlowRun {
    if ($script:starting) {
        # 아직 시작 중: 기다리지 않는다. 이미 만들어졌으면 지금 끝내고, 늦게 만들어지면 만든 쪽이 끝낸다 (Start-WtFlowChild)
        Stop-WtFlowStarting $script:starting
        $script:starting = $null
        Set-WtFlowNote '실행을 취소했습니다.'
        Update-WtFlowCommands
        return
    }
    if (-not $script:run) { return }
    $script:run.Cancelled = $true
    Stop-WtFlowProcess $script:run
    Set-WtFlowNote '실행을 멈추는 중입니다…'
}

function Start-WtFlowTimer {
    if (-not $script:timer) {
        $script:timer = New-WtPollTimer { Update-WtFlowRunState }
        $script:timer.Interval = [timespan]::FromMilliseconds(100)
    }
    $script:timer.Start()
}

# 타이머: 새 출력을 붙이고, 끝났으면 결과를 보이고 기록한다. 콘솔 창이 닫혔는지도 본다
function Update-WtFlowRunState {
    try {
        $u = $script:ui
        if ($script:run) {
            $fresh = Read-WtFlowOutput $script:run
            # 출력이 들어오는 동안은 자주 비운다 (통로가 차서 스크립트가 기다리지 않게)
            $script:timer.Interval = [timespan]::FromMilliseconds($(if ($fresh.Count) { 20 } else { 100 }))
            if ($fresh.Count -and $u.Count) {
                # 맨 아래를 보고 있을 때만 따라 내려간다 (위로 올려 읽거나 고르는 중이면 그대로 둔다)
                $o = $u.Output
                $atBottom = $o.VerticalOffset + $o.ViewportHeight -ge $o.ExtentHeight - 2
                $script:shown += $fresh.Count
                if ($script:shown -gt $script:maxLines + 500) {
                    # 화면 칸이 끝없이 커지지 않게 가끔 최근 줄만 남긴다 (탭이 안 보여도 줄 수는 직접 센다)
                    $o.Text = (@($script:run.Lines) | Select-Object -Last $script:maxLines) -join "`n"
                    $script:shown = $script:maxLines
                } else {
                    $o.AppendText("`n" + ($fresh -join "`n"))
                }
                if ($atBottom) { $o.ScrollToEnd() }
            }
            if ($u.Count) { $u.Elapsed.Text = "실행 중 · $(Format-WtFlowSpan ((Get-Date) - $script:run.Started))" }
            if (Test-WtFlowRunDone $script:run) {
                $done = $script:run
                $script:run = $null
                $status = Complete-WtFlowRun $done
                if ($u.Count) {
                    Show-WtFlowResult $done.Record $status
                    if ($done.PSObject.Properties['SaveError']) { Set-WtFlowNote "실행 기록을 저장하지 못했습니다: $($done.SaveError)" }
                }
            }
        }
        foreach ($c in @($script:consoles)) {
            $exited = $true
            try { $exited = $c.Process.HasExited } catch { }
            if (-not $exited) { continue }
            $c.Record.ended = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            try { Save-WtFlowRun $c.Record } catch { }
            try { $c.Process.Dispose() } catch { }
            [void]$script:consoles.Remove($c)
            if ($u.Count) { Update-WtFlowHelp }
        }
        if (-not $script:run -and -not $script:consoles.Count) { $script:timer.Stop() }
    } catch { $script:timer.Stop(); Show-WtError $_ '업무 실행' }
}

function Show-WtFlowResult($Record, [string]$Status) {
    $u = $script:ui
    $u.Busy.Visibility = 'Collapsed'
    $look = Get-WtFlowStatusLook $Status ([bool]$Record.whatIf)
    $u.RunStatus.Child = New-WtTag $look.Text $look.Bg $look.Fg $look.Icon
    $span = Get-WtFlowRunSpan $Record
    $u.Elapsed.Text = switch ($Status) {
        'success' { "$span · 종료 코드 0" }
        'failed' { "$span · 종료 코드 $($Record.exitCode)" }
        'cancelled' { "$span · 취소해서 멈췄습니다. 스크립트의 마무리 처리는 돌지 않았을 수 있습니다" }
        default { $span }
    }
    $u.Output.AppendText("`n■ $((Get-Date).ToString('HH:mm:ss')) 끝 · $($look.Text)")
    $u.Output.ScrollToEnd()
    Set-WtFlowNote ''   # 「멈추는 중」 같은 알림은 결과가 대신한다
    Update-WtFlowCommands
    Update-WtFlowHelp
}

# ---- 화면: 업무 저장 · 삭제 ---------------------------------------------------------------------

function Save-WtFlowFromForm {
    if (-not $script:info -or $script:info.Error) { return }
    $form = Get-WtFlowFormValues
    # 저장한 값 위에 지금 칸 값만 덮어쓴다. 지금 스크립트에 없는 칸의 값은 그대로 둔다 (param 이름이 잠깐 바뀌어도 잃지 않게)
    $kept = if ($script:flow) { ConvertTo-WtFlowValues $script:flow.values } else { @{} }
    foreach ($f in $script:info.Fields) {
        $v = $form[$f.Name]
        if ($f.Kind -eq 'switch') {
            # 스위치는 기본값과 다를 때만 남긴다
            if (($v -eq $true) -ne ($f.Default -eq $true)) { $kept[$f.Name] = ($v -eq $true) } else { [void]$kept.Remove($f.Name) }
        } elseif (([string]$v).Trim()) { $kept[$f.Name] = ([string]$v).Trim() }
        else { [void]$kept.Remove($f.Name) }
    }
    $mode = Get-WtFlowMode
    $items = @(Get-WtFlows)
    if ($script:flow) {
        foreach ($f in $items) {
            if ($f.id -ne $script:flow.id) { continue }
            $f.values = $kept; $f.mode = $mode; $f.updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        try { Save-WtFlows $items } catch { Show-WtError $_ '업무 저장'; return }
        $script:flow = $items | Where-Object { $_.id -eq $script:flow.id } | Select-Object -First 1
        Set-WtFlowNote "업무를 저장했습니다: $($script:flow.title)"
        return
    }
    $title = Read-WtFlowTitle $script:info.Name
    if (-not $title) { return }
    $new = New-WtFlow $title $script:info.Path $kept $mode
    try { Save-WtFlows (@($items) + [pscustomobject]$new) } catch { Show-WtError $_ '업무 저장'; return }
    # 방금 실행한 출력은 새 업무를 고른 뒤에도 남긴다
    if ($script:outputKey -eq "script:$($script:info.Path)") { $script:outputKey = "flow:$($new.id)" }
    $script:pendingFlow = $new.id
    Update-WtFlowTree
    Set-WtFlowNote "업무로 저장했습니다: $title"
}

# 업무 이름을 묻는 창. 취소하면 빈 글자
function Read-WtFlowTitle([string]$Suggest) {
    $dialog = New-WtModal '업무로 저장'
    [void](Add-WtChild $dialog.Body (New-WtText '왼쪽 목록에 보일 이름을 정하세요. 예: PM 점검 · 서버실' 'T.Sub'))
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Input'
    $box.Text = $Suggest
    [System.Windows.Automation.AutomationProperties]::SetName($box, '업무 이름')
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
    $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Box.Focus(); $s.Tag.Box.SelectAll() })
    [void]$dialog.Window.ShowDialog()
    [string]$dialog.Window.Tag.Result
}

function Remove-WtFlowCurrent {
    if (-not $script:flow) { return }
    $items = @(Get-WtFlows)
    $gone = $items | Where-Object { $_.id -eq $script:flow.id } | Select-Object -First 1
    try { Save-WtFlows @($items | Where-Object { $_.id -ne $script:flow.id }) } catch { Show-WtError $_ '업무 삭제'; return }
    $script:lastDeleted = $gone
    Clear-WtFlowSelection
    Update-WtFlowTree
    Set-WtFlowNote "업무를 지웠습니다: $($gone.title)" -Undo
}

function Restore-WtFlowDeleted {
    if (-not $script:lastDeleted) { return }
    $items = @(Get-WtFlows | Where-Object { $_.id -ne $script:lastDeleted.id })
    try { Save-WtFlows (@($items) + $script:lastDeleted) } catch { Show-WtError $_ '업무 되살리기'; return }
    $script:pendingFlow = $script:lastDeleted.id
    $script:lastDeleted = $null
    Update-WtFlowTree
    Set-WtFlowNote '지운 업무를 되살렸습니다.'
}

# 저장한 업무의 스크립트가 옮겨졌을 때 다시 고른다
function Select-WtFlowScriptAgain {
    if (-not $script:flow) { return }
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Filter = 'PowerShell 스크립트 (*.ps1)|*.ps1'
    if (-not $dlg.ShowDialog()) { return }
    $items = @(Get-WtFlows)
    foreach ($f in $items) { if ($f.id -eq $script:flow.id) { $f.script = $dlg.FileName; $f.updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } }
    try { Save-WtFlows $items } catch { Show-WtError $_ '스크립트 다시 고르기'; return }
    $script:pendingFlow = $script:flow.id
    Update-WtFlowTree
}

# ---- 화면: 설명 · 기록 --------------------------------------------------------------------------

function Update-WtFlowHelp {
    $u = $script:ui
    if (-not $u.Count) { return }
    # 세 칸이 다 안 들어가면 설명은 접어 두고, 펼치면 가운데 위에 겹쳐 연다.
    # 이때 펼치고 접는 것은 설정에 남기지 않는다 (창을 넓히면 설정대로 돌아간다)
    $script:helpNarrow = Test-WtFlowNarrow $u.PageGrid.ActualWidth
    if (-not $script:helpNarrow) { $script:helpOverlay = $false }
    $show = if ($script:helpNarrow) { $script:helpOverlay } else { [bool](Get-WtSetting 'workflows.help') }
    $u.HelpColumn.Width = [System.Windows.GridLength]::new($(if ($show -and -not $script:helpNarrow) { 280 } else { 0 }))
    $box = $u.HelpHost
    if ($script:helpNarrow) {
        [System.Windows.Controls.Grid]::SetColumn($box, 1)
        $box.HorizontalAlignment = 'Right'
        $box.Width = 280
        $box.Margin = [System.Windows.Thickness]::new(0)
        [System.Windows.Controls.Panel]::SetZIndex($box, 1)
    } else {
        [System.Windows.Controls.Grid]::SetColumn($box, 2)
        $box.HorizontalAlignment = 'Stretch'
        $box.Width = [double]::NaN
        $box.Margin = [System.Windows.Thickness]::new(16, 0, 0, 0)
        [System.Windows.Controls.Panel]::SetZIndex($box, 0)
    }
    $u.HelpShadow.Visibility = if ($script:helpNarrow) { 'Visible' } else { 'Collapsed' }
    $box.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
    $u.HelpOpen.Visibility = if ($show) { 'Collapsed' } else { 'Visible' }
    $panel = $u.HelpPanel
    if (-not $show) { $panel.Children.Clear(); $script:helpKey = $null; $script:helpList = $null; return }
    $key = ConvertTo-Json -Compress -Depth 10 -InputObject @((Get-WtStoreStamp 'workflow-runs'), $script:info, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale'))
    if ($script:helpKey -ceq $key) {
        if ($script:helpList) { $script:helpList.SelectedItem = $null }
        return
    }
    $panel.Children.Clear()
    $script:helpKey = $null; $script:helpList = $null
    $info = $script:info
    if (-not $info) {
        $t = New-WtText '스크립트를 고르면 그 스크립트의 도움말과 최근 실행 기록이 여기에 보입니다.' 'T.Sub'
        $t.TextWrapping = 'Wrap'
        [void](Add-WtChild $panel $t)
    } else {
        $file = New-WtText $info.Path 'T.Sub'
        Set-WtResource $file 'FontFamily' 'Font.Mono'
        $file.TextWrapping = 'Wrap'
        [void](Add-WtChild $panel $file)
        foreach ($text in @($info.Description)) {
            if (-not $text) { continue }
            $t = New-WtText $text 'T.Body'; $t.TextWrapping = 'Wrap'
            [void](Add-WtChild $panel $t)
        }
        foreach ($ex in $info.Examples) {
            $b = [System.Windows.Controls.Border]::new()
            Set-WtResource $b 'Background' 'B.Code.Bg'
            $b.CornerRadius = [System.Windows.CornerRadius]::new(8)
            $b.Padding = [System.Windows.Thickness]::new(12, 8, 12, 8)
            $t = New-WtText $ex 'T.Sub'
            Set-WtResource $t 'FontFamily' 'Font.Mono'
            $t.TextWrapping = 'Wrap'
            $b.Child = $t
            [void](Add-WtChild $panel $b)
        }
        # .NOTES의 「WorkTool: 콘솔」 줄은 앱이 읽는 표시라서 설명에서는 뺀다
        $notes = (@($info.Notes -split "`r?`n" | Where-Object { $_ -notmatch '^\s*WorkTool:\s*콘솔\s*$' }) -join "`n").Trim()
        if ($notes) { $n = New-WtText $notes 'T.Sub'; $n.TextWrapping = 'Wrap'; [void](Add-WtChild $panel $n) }
        if (-not $info.Description -and -not $info.Examples.Count -and -not $notes) { [void](Add-WtChild $panel (New-WtText '이 스크립트에는 설명(.DESCRIPTION · .EXAMPLE)이 없습니다.' 'T.Sub')) }
    }
    $head = New-WtText '최근 실행' 'T.H2'
    $head.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    [void](Add-WtChild $panel $head)
    $runs = @(Get-WtFlowRuns | Where-Object { -not $info -or $_.script -eq $info.Path } | Select-Object -First 10)
    if (-not $runs.Count) { [void](Add-WtChild $panel (New-WtText '아직 실행 기록이 없습니다.' 'T.Sub')); $script:helpKey = $key; return }
    $list = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $list 'List'
    [System.Windows.Controls.ScrollViewer]::SetVerticalScrollBarVisibility($list, 'Disabled')
    foreach ($r in $runs) {
        $look = Get-WtFlowStatusLook ([string]$r.status) ([bool]$r.whatIf)
        $row = New-WtStack Vertical 4
        [void](Add-WtChild $row (New-WtTag $look.Text $look.Bg $look.Fg $look.Icon))
        $at = ConvertTo-WtFlowTime $r.started
        $when = if ($at) { $at.ToString('M/d HH:mm') } else { '' }
        $span = Get-WtFlowRunSpan $r
        $line = (@($when, $(if (-not $info) { [string]$r.name }), $span, $(if ($r.flow) { [string]$r.flow })) | Where-Object { $_ }) -join ' · '
        [void](Add-WtChild $row (New-WtText $line 'T.Sub'))
        $item = [System.Windows.Controls.ListBoxItem]::new()
        $item.Content = $row
        $item.Tag = $r
        $item.ToolTip = '누르면 이 실행의 출력 마지막 줄을 아래 출력 칸에 보여 줍니다'
        [void]$list.Items.Add($item)
    }
    $list.Add_SelectionChanged({ param($s, $e) if ($s.SelectedItem) { Show-WtFlowRecordTail $s.SelectedItem.Tag } })
    [void](Add-WtChild $panel $list)
    $script:helpList = $list; $script:helpKey = $key
}

# 가운데 · 양옆 패널이 놓일 폭이 세 칸에 모자라는지 (아직 배치 전이라 폭이 0이면 모자라지 않은 것으로 본다)
function Test-WtFlowNarrow([double]$Width) { $Width -gt 0 -and $Width -lt $script:threeColumns }

# [설명 펼치기] · [접기]. 넓으면 설정을 바꾸고, 좁으면 겹쳐 연 것만 열고 닫는다
function Open-WtFlowHelp {
    if ($script:helpNarrow) { $script:helpOverlay = $true } else { Set-WtSetting 'workflows.help' $true }
    Update-WtFlowHelp
}

function Close-WtFlowHelp {
    if ($script:helpNarrow) { $script:helpOverlay = $false } else { Set-WtSetting 'workflows.help' $false }
    Update-WtFlowHelp
}

# 폼 높이: 남는 높이(제목 · 명령 · 결과 · 알림을 뺀 것)의 60%나 출력 칸에 240을 남긴 높이 중 큰 쪽까지 쓰고,
# 출력 칸에는 적어도 120을 남긴다. 넘으면 폼만 스크롤한다. 칸이 적으면 폼은 칸 높이만큼만 쓰고, 실행 명령은 폼 바로 아래에 붙는다
function Update-WtFlowFormHeight {
    $u = $script:ui
    if (-not $u.Count) { return }
    $g = $u.CenterGrid
    if ($g.ActualHeight -le 0) { return }
    $fixed = 0
    foreach ($i in 0, 2, 3, 4) { $fixed += $g.RowDefinitions[$i].ActualHeight }
    $avail = $g.ActualHeight - $fixed
    $u.FormScroll.MaxHeight = [Math]::Max(80, [Math]::Floor([Math]::Min([Math]::Max($avail * 0.6, $avail - 240), $avail - 120)))
}

# 기록을 고르면 그때의 출력 마지막 줄을 출력 칸에 보여 준다 (실행 중이면 바꾸지 않는다)
function Show-WtFlowRecordTail($Record) {
    if ($script:run) { Set-WtFlowNote '실행 중에는 출력 칸을 바꾸지 않습니다.'; return }
    $u = $script:ui
    $u.OutArea.Visibility = 'Visible'   # 아무것도 고르지 않은 상태에서 눌러도 보이게
    $u.OutputHint.Visibility = 'Collapsed'
    $script:outputKey = if ($script:flow) { "flow:$($script:flow.id)" } elseif ($script:info) { "script:$($script:info.Path)" } else { $null }
    $look = Get-WtFlowStatusLook ([string]$Record.status) ([bool]$Record.whatIf)
    $lines = @("── $($Record.name) · $($Record.started) · $($look.Text) (기록: 출력 마지막 $($script:tailLines)줄) ──")
    if ($Record.status -eq 'console') { $lines += '콘솔 창 실행은 출력을 남기지 않습니다. 그 창에서 확인하세요.' }
    $lines += @($Record.tail)
    $u.Output.Text = $lines -join "`n"
    $u.Output.ScrollToEnd()
}

# ---- 화면 만들기 --------------------------------------------------------------------------------

function New-WtFlowsView {
    $script:treeKey = $null; $script:centerKey = $null
    $script:helpKey = $null; $script:helpList = $null
    if ($script:timer) { $script:timer.Stop() }
    $script:ui = @{}
    $page = New-WtPage -Fill
    $add = New-WtButton '폴더 추가' -Icon 0xE710 -ToolTip '실행할 스크립트가 있는 폴더 추가'
    $add.Add_Click({ Add-WtFlowRoot })
    $header = New-WtPageHeader '업무' '' $add
    [System.Windows.Controls.DockPanel]::SetDock($header, 'Top')
    [void]$page.Panel.Children.Add($header)

    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(240)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::new(1, 'Star'); $c2.MinWidth = 360
    $c3 = [System.Windows.Controls.ColumnDefinition]::new(); $c3.Width = [System.Windows.GridLength]::new(280)
    foreach ($c in @($c1, $c2, $c3)) { $grid.ColumnDefinitions.Add($c) }

    # 왼쪽: 저장한 업무 + 스크립트 폴더
    $left = New-WtCard
    $left.Padding = [System.Windows.Thickness]::new(12)
    $left.Margin = [System.Windows.Thickness]::new(0, 0, 16, 0)
    $ldock = [System.Windows.Controls.DockPanel]::new()
    $remove = New-WtButton '목록에서 빼기' -Kind Link -Icon 0xE738
    $remove.ToolTip = '고른 스크립트 폴더를 목록에서 뺍니다 (폴더와 파일은 그대로)'
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($remove, $true)
    $remove.HorizontalAlignment = 'Left'
    $remove.IsEnabled = $false
    $remove.Add_Click({ Remove-WtFlowRoot })
    [System.Windows.Controls.DockPanel]::SetDock($remove, 'Bottom')
    [void]$ldock.Children.Add($remove)
    $tree = [System.Windows.Controls.TreeView]::new()
    Set-WtStyle $tree 'Tree'
    $tree.Add_SelectedItemChanged({
            param($s, $e)
            $node = $s.SelectedItem
            if ($script:filling -or -not $node -or $node -isnot [System.Windows.Controls.TreeViewItem]) { return }
            try { Select-WtFlowNode $node.Tag } catch { Show-WtError $_ '업무 고르기' }
        })
    [void]$ldock.Children.Add($tree)
    $left.Child = $ldock
    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$grid.Children.Add($left)

    # 가운데: 제목 · 업무 저장 / 폼 / 실행 명령 / 결과 / 알림 / 출력
    $center = New-WtCard
    $center.Padding = [System.Windows.Thickness]::new(16, 12, 16, 16)
    $cgrid = [System.Windows.Controls.Grid]::new()
    # 폼은 칸 높이만큼(최대 높이는 Update-WtFlowFormHeight), 실행 명령은 폼 바로 아래, 출력은 남는 높이를 다 쓴다.
    # 칸이 많으면 폼만 스크롤하고, 명령은 늘 보인다
    foreach ($h in @('Auto', 'Auto', 'Auto', 'Auto', 'Auto', 'Star')) {
        $rd = [System.Windows.Controls.RowDefinition]::new()
        $rd.Height = if ($h -eq 'Auto') { [System.Windows.GridLength]::Auto } else { [System.Windows.GridLength]::new(1, 'Star') }
        $cgrid.RowDefinitions.Add($rd)
    }
    $head = [System.Windows.Controls.DockPanel]::new()
    $head.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $headActions = New-WtStack Horizontal 8
    $headActions.VerticalAlignment = 'Top'
    $saveFlow = New-WtButton '업무로 저장' -Icon 0xE74E
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($saveFlow, $true)
    $saveFlow.Add_Click({ Save-WtFlowFromForm })
    $deleteFlow = New-WtButton '업무 삭제' -Kind Link -Icon 0xE74D
    $deleteFlow.ToolTip = '저장한 업무를 지웁니다 (스크립트 파일은 그대로)'
    $deleteFlow.Add_Click({ Remove-WtFlowCurrent })
    $helpOpen = New-WtButton '설명 펼치기' -Kind Link -Icon 0xE946
    $helpOpen.ToolTip = '오른쪽에 스크립트 도움말과 최근 실행을 보여 줍니다'
    $helpOpen.Add_Click({ Open-WtFlowHelp })
    foreach ($b in @($deleteFlow, $saveFlow, $helpOpen)) { [void](Add-WtChild $headActions $b) }
    [System.Windows.Controls.DockPanel]::SetDock($headActions, 'Right')
    [void]$head.Children.Add($headActions)
    $titleStack = New-WtStack Vertical 4
    $titleStack.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $title = New-WtText '업무' 'T.H2'
    $title.TextWrapping = 'NoWrap'   # 길면 줄을 바꾸지 않고 …로 줄인다 (전체 경로는 마우스를 올리면 보인다)
    $title.TextTrimming = 'CharacterEllipsis'
    $sub = New-WtText '' 'T.Sub'
    $sub.TextWrapping = 'Wrap'
    $repick = New-WtButton '스크립트 다시 고르기' -Icon 0xE8E5
    $repick.HorizontalAlignment = 'Left'
    $repick.Visibility = 'Collapsed'
    $repick.Add_Click({ Select-WtFlowScriptAgain })
    foreach ($x in @($title, $sub, $repick)) { [void](Add-WtChild $titleStack $x) }
    [void]$head.Children.Add($titleStack)
    [System.Windows.Controls.Grid]::SetRow($head, 0)
    [void]$cgrid.Children.Add($head)

    $formScroll = [System.Windows.Controls.ScrollViewer]::new()
    $formScroll.VerticalScrollBarVisibility = 'Auto'
    $formScroll.HorizontalScrollBarVisibility = 'Disabled'
    $formScroll.Focusable = $false
    $form = New-WtStack Vertical 16
    $form.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    $formScroll.Content = $form
    [System.Windows.Controls.Grid]::SetRow($formScroll, 1)
    [void]$cgrid.Children.Add($formScroll)
    # 스크립트 폴더가 없을 때: 폼부터 출력까지의 자리 한가운데에 한 줄 + [폴더 추가]
    $empty = New-WtStack Vertical 12
    $empty.HorizontalAlignment = 'Center'
    $empty.VerticalAlignment = 'Center'
    $emptyText = New-WtText '스크립트 폴더가 없습니다.' 'T.Sub'
    $emptyText.HorizontalAlignment = 'Center'
    $emptyAdd = New-WtButton '폴더 추가' -Icon 0xE710
    $emptyAdd.HorizontalAlignment = 'Center'
    $emptyAdd.Add_Click({ Add-WtFlowRoot })
    [void](Add-WtChild $empty $emptyText)
    [void](Add-WtChild $empty $emptyAdd)
    [System.Windows.Controls.Grid]::SetRow($empty, 1)
    [System.Windows.Controls.Grid]::SetRowSpan($empty, 5)
    [void]$cgrid.Children.Add($empty)

    # 실행 명령: [실행] [미리보기] [취소] 실행 방식. 좁으면 실행 방식이 다음 줄로 내려간다
    $commands = [System.Windows.Controls.WrapPanel]::new()
    $commands.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    $runButton = New-WtButton '실행' -Kind Primary -Icon 0xE768
    $runButton.Add_Click({ Invoke-WtFlowRun })
    $preview = New-WtButton '미리보기' -Icon 0xE7B3
    $preview.Add_Click({ Invoke-WtFlowRun -WhatIf })
    $cancel = New-WtButton '취소' -Icon 0xE711
    $cancel.Add_Click({ Stop-WtFlowRun })
    $mode = New-WtSegmented @(@('app', '앱 안에서'), @('console', '콘솔 창에서')) 'app' 'WtFlowMode' { param($value) Set-WtFlowModeChoice $value; Update-WtFlowCommands }
    $mode.ToolTip = '앱 안: 출력을 아래 칸에 보여 줍니다 · 콘솔 창: 자기 화면이 있거나 키 입력을 받는 스크립트'
    foreach ($b in @($runButton, $preview, $cancel, $mode)) {
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($b, $true)
        $b.Margin = [System.Windows.Thickness]::new(0, 0, 8, 8)
        [void]$commands.Children.Add($b)
    }
    [System.Windows.Controls.Grid]::SetRow($commands, 2)
    [void]$cgrid.Children.Add($commands)

    # 결과: 상태(글자 · 아이콘 · 색) + 걸린 시간 · 종료 코드, 실행 중이면 진행 막대
    $statusStack = New-WtStack Vertical 4
    $statusStack.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $statusStack.Visibility = 'Collapsed'
    $statusRow = [System.Windows.Controls.DockPanel]::new()
    $runStatus = [System.Windows.Controls.Border]::new()
    $runStatus.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
    [System.Windows.Controls.DockPanel]::SetDock($runStatus, 'Left')
    $elapsed = New-WtText '' 'T.Sub'
    $elapsed.VerticalAlignment = 'Center'
    $elapsed.TextWrapping = 'Wrap'
    [void]$statusRow.Children.Add($runStatus)
    [void]$statusRow.Children.Add($elapsed)
    $busy = [System.Windows.Controls.ProgressBar]::new()
    Set-WtStyle $busy 'Busy'
    $busy.Visibility = 'Collapsed'
    [void](Add-WtChild $statusStack $statusRow)
    [void](Add-WtChild $statusStack $busy)
    [System.Windows.Controls.Grid]::SetRow($statusStack, 3)
    [void]$cgrid.Children.Add($statusStack)

    # 알림 한 줄 (+ 업무 삭제의 실행 취소)
    $noteRow = [System.Windows.Controls.DockPanel]::new()
    $noteRow.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $noteRow.Visibility = 'Collapsed'
    $undo = New-WtButton '실행 취소' -Kind Link -Icon 0xE7A7
    $undo.Visibility = 'Collapsed'
    $undo.Add_Click({ Restore-WtFlowDeleted })
    [System.Windows.Controls.DockPanel]::SetDock($undo, 'Right')
    [void]$noteRow.Children.Add($undo)
    $note = New-WtText '' 'T.Sub'
    $note.TextWrapping = 'Wrap'
    $note.VerticalAlignment = 'Center'
    [void]$noteRow.Children.Add($note)
    [System.Windows.Controls.Grid]::SetRow($noteRow, 4)
    [void]$cgrid.Children.Add($noteRow)

    $outArea = [System.Windows.Controls.Grid]::new()
    $outArea.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $output = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $output 'Output'
    [System.Windows.Automation.AutomationProperties]::SetName($output, '실행 출력')
    [void]$outArea.Children.Add($output)
    $outHint = New-WtText '실행하면 출력이 여기에 보입니다.' 'T.Sub'
    $outHint.HorizontalAlignment = 'Center'
    $outHint.VerticalAlignment = 'Center'
    $outHint.IsHitTestVisible = $false
    [void]$outArea.Children.Add($outHint)
    [System.Windows.Controls.Grid]::SetRow($outArea, 5)
    [void]$cgrid.Children.Add($outArea)
    # 폼 최대 높이는 가운데 높이나 다른 줄(제목 · 명령 · 결과 · 알림)의 높이가 바뀔 때마다 다시 잰다
    foreach ($x in @($cgrid, $head, $commands, $statusStack, $noteRow)) { $x.Add_SizeChanged({ Update-WtFlowFormHeight }) }
    $center.Child = $cgrid
    [System.Windows.Controls.Grid]::SetColumn($center, 1)
    [void]$grid.Children.Add($center)

    # 오른쪽: 설명 · 최근 실행. 머리글의 [접기]는 늘 같은 자리에 둔다.
    # 창이 좁으면 가운데 위에 겹쳐 연다 (Update-WtFlowHelp). 그때만 뒤에 그림자를 깐다
    $right = New-WtCard
    $right.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
    $rdock = [System.Windows.Controls.DockPanel]::new()
    $rhead = [System.Windows.Controls.DockPanel]::new()
    $rhead.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $helpClose = New-WtButton '접기' -Kind Link -Icon 0xE76C
    $helpClose.ToolTip = '설명을 접어 폼을 넓게 씁니다'
    $helpClose.Add_Click({ Close-WtFlowHelp })
    [System.Windows.Controls.DockPanel]::SetDock($helpClose, 'Right')
    [void]$rhead.Children.Add($helpClose)
    $rtitle = New-WtText '설명' 'T.H2'
    $rtitle.VerticalAlignment = 'Center'
    [void]$rhead.Children.Add($rtitle)
    [System.Windows.Controls.DockPanel]::SetDock($rhead, 'Top')
    [void]$rdock.Children.Add($rhead)
    $helpScroll = [System.Windows.Controls.ScrollViewer]::new()
    $helpScroll.VerticalScrollBarVisibility = 'Auto'
    $helpScroll.HorizontalScrollBarVisibility = 'Disabled'
    $helpScroll.Focusable = $false
    $helpPanel = New-WtStack Vertical 12
    $helpScroll.Content = $helpPanel
    [void]$rdock.Children.Add($helpScroll)
    $right.Child = $rdock
    $helpShadow = [System.Windows.Controls.Border]::new()
    Set-WtStyle $helpShadow 'Overlay.Shadow'
    $helpShadow.Visibility = 'Collapsed'
    $helpHost = [System.Windows.Controls.Grid]::new()
    $helpHost.Margin = [System.Windows.Thickness]::new(16, 0, 0, 0)
    [void]$helpHost.Children.Add($helpShadow)
    [void]$helpHost.Children.Add($right)
    [System.Windows.Controls.Grid]::SetColumn($helpHost, 2)
    [void]$grid.Children.Add($helpHost)
    # 좁고 넓음이 바뀔 때만 설명 자리를 다시 정한다
    $grid.Add_SizeChanged({ param($s, $e) if ((Test-WtFlowNarrow $s.ActualWidth) -ne $script:helpNarrow) { Update-WtFlowHelp } })
    [void]$page.Panel.Children.Add($grid)

    # 업무 화면 안 단축키
    $page.Root.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq 'F5') { Update-WtFlowTree; Set-WtFlowNote '스크립트 목록을 새로 읽었습니다.'; $e.Handled = $true }
            elseif ($e.Key -eq 'Escape' -and $script:helpOverlay) { Close-WtFlowHelp; $e.Handled = $true }
        })

    $script:ui = @{
        Tree = $tree; RemoveRoot = $remove; Title = $title; Sub = $sub; Repick = $repick
        Form = $form; FormScroll = $formScroll; CenterGrid = $cgrid; Empty = $empty; Commands = $commands; ModeButtons = @($mode.Child.Children)
        SaveFlow = $saveFlow; DeleteFlow = $deleteFlow; RunButton = $runButton; Preview = $preview; Cancel = $cancel
        Status = $statusStack; RunStatus = $runStatus; Elapsed = $elapsed; Busy = $busy; NoteRow = $noteRow; Note = $note; Undo = $undo
        Output = $output; OutputHint = $outHint; OutArea = $outArea
        PageGrid = $grid; HelpColumn = $c3; HelpHost = $helpHost; HelpShadow = $helpShadow; HelpPanel = $helpPanel; HelpOpen = $helpOpen
    }
    $script:helpNarrow = $false
    $script:helpOverlay = $false
    # 화면을 새로 만들면 고른 것의 수명도 끝난다 (오는 중인 읽기 결과는 새 화면에 넣지 않는다)
    $script:selection = $null
    $script:readSeq++
    $page.Root
}

function Update-WtFlowsView {
    Update-WtFlowTree
    Update-WtFlowCommands
}

# 홈: 저장한 업무와 그 업무의 마지막 결과
function New-WtFlowsHomeCard {
    $flows = @(Get-WtFlows | Select-Object -First 4)
    if (-not $flows.Count) { return }
    $runs = @(Get-WtFlowRuns)
    $card = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '업무' '' '업무 열기' 'workflows'))
    foreach ($f in $flows) {
        $last = $runs | Where-Object { $_.flowId -eq $f.id } | Select-Object -First 1
        $name = New-WtButton ([string]$f.title) -Kind Link
        $name.Tag = [string]$f.id
        $name.HorizontalAlignment = 'Left'
        $name.Add_Click({ param($s, $e) $script:pendingFlow = [string]$s.Tag; Select-WtPage 'workflows' })
        $state = if ($last) {
            $look = Get-WtFlowStatusLook ([string]$last.status) ([bool]$last.whatIf)
            New-WtTag $look.Text $look.Bg $look.Fg $look.Icon
        } else { New-WtText '아직 실행 안 함' 'T.Sub' }
        [void](Add-WtChild $col (New-WtListRow @($state, $name)))
    }
    $card.Child = $col
    $card
}

# 앱을 끄면 앱 안 실행은 멈춘다 (창 없는 프로세스를 남기지 않는다). 콘솔 창은 따로 도는 창이라 그대로 둔다
function Stop-WtFlows {
    if ($script:timer) { $script:timer.Stop() }
    if ($script:starting) {
        # 아직 시작 중인 실행: 기다리지 않고 버린다. 이미 만들어진 자식은 지금 끝내고, 늦게 만들어지면 만든 쪽이 끝낸다
        Stop-WtFlowStarting $script:starting
        Stop-WtWork $script:starting.Work
        $script:starting = $null
    }
    if ($script:run) {
        $done = $script:run
        $script:run = $null
        $done.Stopped = $true
        Stop-WtFlowProcess $done
        try { [void]$done.Process.WaitForExit(2000) } catch { }
        if ($done.PSObject.Properties['Reaper'] -and $done.Reaper) { [void](Wait-WtWork $done.Reaper -Milliseconds 2000) }   # 남은 자식 끝내기를 잠깐만 기다린다
        try { [void](Read-WtFlowOutput $done) } catch { }
        try { [void](Complete-WtFlowRun $done) } catch { }
    }
    foreach ($c in @($script:consoles)) { try { $c.Process.Dispose() } catch { } }
    $script:consoles.Clear()
}

Register-WtAddon -Id 'workflows' -Title '업무' -Icon 0xE756 -Group '작업' -Order 60 -WarmUp View `
    -NewView { New-WtFlowsView } `
    -Refresh { param($view) Update-WtFlowsView } `
    -HomeCard { New-WtFlowsHomeCard } `
    -OnExit { Stop-WtFlows } `
    -Help @('PowerShell 스크립트를 입력 폼으로 실행합니다.', '입력값을 업무로 저장해 다시 씁니다.') `
    -Shortcuts (, @('F5', '스크립트 목록 새로 고침'))

Export-ModuleMember -Function Read-WtFlowScript, Find-WtFlowScripts, Test-WtFlowValues, Get-WtFlowArgs, Get-WtFlowStaleNames,
    ConvertTo-WtFlowValues, ConvertTo-WtFlowCommandArg, New-WtFlowStartInfo, Start-WtFlowProcess, Read-WtFlowOutput, Test-WtFlowRunDone,
    Complete-WtFlowRun, Stop-WtFlowProcess, Get-WtFlows, Save-WtFlows, New-WtFlow, Get-WtFlowRuns, Save-WtFlowRun, New-WtFlowRecord,
    Get-WtFlowStatusLook, Format-WtFlowSpan, Get-WtFlowEncoding

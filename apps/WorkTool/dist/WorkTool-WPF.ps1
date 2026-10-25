<#
.SYNOPSIS
    WorkTool 새 버전(WPF) 1단계 미리보기를 띄운다.

.DESCRIPTION
    - 창 틀 · 왼쪽 메뉴(애드온) · 테마(파스텔 7색 · 투명도 · 글자 크기) · 설정 · 도움말이 들어 있다.
    - 처음 실행하면 예전 WorkTool(WinForms)의 data 폴더를 찾아 메모 · 일정 · 근태를 읽어 와서 보여 준다.
      예전 데이터는 바꾸지 않는다. 새 버전 데이터는 문서\WorkTool 에 저장된다.
    - 편집 · 알람은 2단계에서 옮긴다. 그때까지는 예전 WorkTool을 계속 쓴다.

.EXAMPLE
    .\Start-WorkTool.ps1
    새 버전을 띄운다. 창의 X를 누르면 끝난다 (설정에서 트레이로 숨기기를 고를 수 있다).
#>
# WorkTool 새 버전(WPF) — 파일 하나로 묶은 버전 (자동 생성)
# 이 파일은 직접 고치지 않는다. apps/WorkTool/wpf의 원본을 고친 뒤 wpf/build/Build-Bundle.ps1로 다시 만든다.
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# WPF 창은 STA 스레드에서만 띄울 수 있다
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'WorkTool은 STA 모드에서 실행해야 합니다. 다음처럼 실행하세요:' -ForegroundColor Yellow
    Write-Host "  pwsh -STA -File `"$PSCommandPath`""
    return
}

# 계층 컴파일의 백그라운드 처리가 화면 조작과 경합하므로 이 앱의 프로세스에서만 끈다.
if ($env:DOTNET_TieredCompilation -ne '0') {
    $previousTiered = [Environment]::GetEnvironmentVariable('DOTNET_TieredCompilation', 'Process')
    $env:DOTNET_TieredCompilation = '0'
    try {
        & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -STA -File $PSCommandPath @PSBoundParameters @args
        $childExit = $LASTEXITCODE
    } finally {
        # 같은 콘솔에서 다음에 켤 때도 실제 런타임 설정과 환경 변수 표식이 어긋나지 않게 되돌린다.
        [Environment]::SetEnvironmentVariable('DOTNET_TieredCompilation', $previousTiered, 'Process')
    }
    exit $childExit
}

$previousRenderMode = $null
$renderModeChanged = $false
try {
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# 화면은 기본으로 소프트웨어 렌더링으로 그린다. GPU 렌더링에서는 창이 앞에 있거나 탭 위에 마우스만 올려도
# PC 전체가 버벅이는 PC가 있었고, 이 앱은 화면이 단순해서 소프트웨어로 그려도 속도 차이가 거의 없다.
# 진단할 때만 WORKTOOL_HARDWARE_RENDER=1로 GPU 렌더링을 쓴다. 이 프로세스에만 적용되고 사용자 설정 · 레지스트리는 바꾸지 않는다.
# 반드시 첫 창을 만들기 전에 적용한다.
if ($env:WORKTOOL_HARDWARE_RENDER -ne '1') {
    $previousRenderMode = [System.Windows.Media.RenderOptions]::ProcessRenderMode
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
    $renderModeChanged = $true
}

#region 모듈 (묶음 파일: build\Build-Bundle.ps1이 넣음)
# ---- core\Storage.psm1 ----
New-Module -Name 'WorkTool.Storage' -ScriptBlock {
# 저장 담당. 기능 모듈은 파일을 직접 읽고 쓰지 않고 이 모듈만 거친다.
# - 데이터는 앱 폴더 밖(기본: 문서\WorkTool)에 둔다. 앱을 새 버전으로 덮어써도 데이터는 그대로다.
# - 저장소(store) 하나 = JSON 파일 하나. 파일마다 schema 번호를 붙여, 형식이 바뀌면 읽을 때 한 단계씩 변환한다.
# - 쓸 때는 임시 파일에 먼저 쓰고 바꿔치기한다. 직전 파일은 .bak으로 하나 남긴다.
# - 읽기 실패는 항상 예외로 올린다. 빈 결과로 넘기면 다음 저장에서 기존 데이터를 덮어쓰기 때문이다.

$ErrorActionPreference = 'Stop'

$script:appRoot = $null
$script:dataRoot = $null
$script:utf8 = [System.Text.UTF8Encoding]::new($false)

# 진입 스크립트가 자기 위치를 알려 준다. 묶음 파일이든 원본 폴더든 같은 방식으로 쓴다.
function Set-WtAppRoot([string]$Path) {
    $script:appRoot = $Path
    $script:dataRoot = $null
}

function Get-WtAppRoot { $script:appRoot }

# 데이터 폴더마다 하나의 앱만 쓴다. 빈 잠금 파일은 남겨 두고 핸들만 해제한다.
function Open-WtDataLock {
    try {
        [System.IO.File]::Open((Join-Path (Get-WtDataRoot) '.worktool.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch {
        throw '같은 데이터 폴더를 사용하는 WorkTool이 실행 중이거나 폴더를 잠글 수 없습니다. 기존 창·트레이를 확인하세요.'
    }
}

# 데이터 폴더. 앱 폴더에 datapath.txt가 있으면 그 첫 줄의 경로, 없으면 문서\WorkTool
function Get-WtDataRoot {
    if ($script:dataRoot) { return $script:dataRoot }
    $path = $null
    if ($script:appRoot) {
        $override = Join-Path $script:appRoot 'datapath.txt'
        if (Test-Path -LiteralPath $override) {
            $line = Get-Content -LiteralPath $override -TotalCount 1 -Encoding utf8
            if ($line -and $line.Trim()) { $path = [Environment]::ExpandEnvironmentVariables($line.Trim()) }
        }
    }
    if (-not $path) {
        $docs = [Environment]::GetFolderPath('MyDocuments')
        if (-not $docs) { $docs = $HOME }
        $path = Join-Path $docs 'WorkTool'
    }
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $script:dataRoot = (Resolve-Path -LiteralPath $path).ProviderPath
    $script:dataRoot
}

# JSON 파일 하나를 읽는다. 없으면 $null
function Read-WtJsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    [System.IO.File]::ReadAllText($Path, $script:utf8) | ConvertFrom-Json -Depth 20
}

# JSON 파일 하나를 바꿔치기로 쓴다. 직전 파일은 <파일>.bak
function Write-WtJsonFile([string]$Path, $Data) {
    $json = ConvertTo-Json -InputObject $Data -Depth 20
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $json, $script:utf8)
    if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::Replace($tmp, $Path, "$Path.bak")
    } else {
        Move-Item -LiteralPath $tmp -Destination $Path
    }
}

function Get-WtStorePath {
    param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name)
    Join-Path (Get-WtDataRoot) "$Name.json"
}

function Test-WtStore([string]$Name) { Test-Path -LiteralPath (Get-WtStorePath $Name) }

# 화면에서 변경 여부를 판단하는 표식. 파일 조회와 읽고 쓰기는 이 모듈로 모은다.
function Get-WtStoreStamp([string]$Name) {
    $path = Get-WtStorePath $Name
    $info = [System.IO.FileInfo]::new($path)
    $info.Refresh()
    if (-not $info.Exists) { return "$path|missing" }
    # 같은 크기·시각으로 덮어쓴 외부 변경도 놓치지 않는다. JSON 해석 없이 작은 버퍼로 읽는다.
    # 다른 프로그램(동기화 · 백신 등)이 잠깐 잡고 있어 못 읽으면 매번 다른 표식을 돌려줘, 화면이 그냥 다시 읽게 한다
    try {
        $stream = [System.IO.File]::OpenRead($path)
        try { $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)) }
        finally { $stream.Dispose() }
    } catch [System.IO.IOException], [System.UnauthorizedAccessException] { $hash = "unread-$([guid]::NewGuid().ToString('N'))" }
    "$path|$($info.LastWriteTimeUtc.Ticks)|$($info.CreationTimeUtc.Ticks)|$($info.Length)|$hash"
}

# 저장소 하나를 읽는다. 파일이 없으면 $null.
# $Migrate는 { param($doc, $from) ... $doc } 형태로, schema $from 문서를 $from+1 형식으로 바꿔 돌려준다.
# 변환하기 전 원본은 <이름>.json.schema<번호>.bak으로 남긴다.
function Read-WtStore {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Schema = 1,
        [scriptblock]$Migrate
    )
    $path = Get-WtStorePath $Name
    $doc = Read-WtJsonFile $path
    if ($null -eq $doc) { return $null }
    $from = [int]$doc.schema
    if ($from -gt $Schema) {
        throw "$Name.json은 더 새 버전(schema $from)에서 저장됐습니다. WorkTool을 최신으로 바꿔 주세요."
    }
    if ($from -lt $Schema) {
        if (-not $Migrate) { throw "$Name.json을 schema $from에서 $Schema(으)로 바꾸는 방법이 없습니다." }
        Copy-Item -LiteralPath $path -Destination "$path.schema$from.bak" -Force
        while ($from -lt $Schema) {
            $doc = & $Migrate $doc $from
            $from++
            $doc.schema = $from
        }
        Write-WtStore -Name $Name -Schema $Schema -Items @($doc.items)
    }
    $doc
}

# 저장소의 항목만 배열로 돌려준다. 파일이 없으면 빈 배열
function Get-WtStoreItems {
    param([Parameter(Mandatory)][string]$Name, [int]$Schema = 1, [scriptblock]$Migrate)
    $doc = Read-WtStore -Name $Name -Schema $Schema -Migrate $Migrate
    if ($null -eq $doc) { return , @() }
    , @($doc.items | Where-Object { $null -ne $_ })
}

# 저장소 하나를 통째로 쓴다. $Extra의 키는 문서 맨 위에 함께 저장된다 (예: 가져온 위치)
function Write-WtStore {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Schema = 1,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [hashtable]$Extra
    )
    $doc = [ordered]@{ schema = $Schema; saved = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
    if ($Extra) { foreach ($k in $Extra.Keys) { $doc[$k] = $Extra[$k] } }
    $doc['items'] = @($Items | Where-Object { $null -ne $_ })
    Write-WtJsonFile (Get-WtStorePath $Name) $doc
}

# 새 항목 ID
function New-WtId { [guid]::NewGuid().ToString('N').Substring(0, 12) }

# ---- 예전(WinForms) WorkTool 데이터 ----------------------------------------------------------

# 예전 데이터 폴더를 찾는다. 설정에 적은 위치 → 이 파일 옆 data → 한 단계 위 data 순서
function Find-WtLegacyFolder {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $custom = Get-WtSetting 'legacy.path'
    if ($custom) { $candidates.Add([string]$custom) }
    if ($script:appRoot) {
        $candidates.Add((Join-Path $script:appRoot 'data'))
        $candidates.Add((Join-Path (Split-Path $script:appRoot -Parent) 'data'))
    }
    foreach ($c in $candidates) {
        foreach ($f in 'memo.csv', 'schedule.csv', 'attendance.csv') {
            if (Test-Path -LiteralPath (Join-Path $c $f)) { return (Resolve-Path -LiteralPath $c).ProviderPath }
        }
    }
    $null
}

# 예전 CSV 하나를 읽는다. 파일이 없으면 $null (빈 파일이면 빈 배열)
function Import-WtLegacyCsv([string]$Folder, [string]$Name) {
    $path = Join-Path $Folder "$Name.csv"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    , @(Import-Csv -LiteralPath $path -Encoding utf8)
}

Export-ModuleMember -Function Set-WtAppRoot, Get-WtAppRoot, Get-WtDataRoot, Open-WtDataLock, Read-WtJsonFile, Write-WtJsonFile,
    Get-WtStorePath, Test-WtStore, Get-WtStoreStamp, Read-WtStore, Get-WtStoreItems, Write-WtStore, New-WtId,
    Find-WtLegacyFolder, Import-WtLegacyCsv
} | Import-Module -Force -DisableNameChecking
# ---- core\Storage.psm1 끝 ----

# ---- core\Settings.psm1 ----
New-Module -Name 'WorkTool.Settings' -ScriptBlock {
# 설정 담당. 기본값은 코드에 두고, 사용자가 바꾼 값만 데이터 폴더의 settings.json에 저장한다.
# 그래서 새 설정 항목이 생겨도 예전 settings.json이 그대로 동작하고, 기본값과 같아지면 파일에서 빠진다.

$ErrorActionPreference = 'Stop'

$script:defaults = @{
    'theme.color'     = 'sky'    # Theme.psm1의 팔레트 이름
    'ui.opacity'      = 100      # 창 불투명도(%) 60~100
    'ui.fontScale'    = 'm'      # 글자 크기 s · m · l
    'nav.collapsed'   = $false   # 왼쪽 메뉴 접힘
    'window.closeToTray' = $false   # 창의 X를 누르면 끝내지 않고 트레이로 숨김
    'addons.disabled' = @()      # 메뉴에서 숨긴 애드온 ID
    'legacy.path'     = ''       # 예전 WorkTool data 폴더 (비우면 자동으로 찾음)
}
$script:values = $null
$script:handlers = [System.Collections.Generic.List[scriptblock]]::new()

function Get-WtSettingsPath { Join-Path (Get-WtDataRoot) 'settings.json' }

function Initialize-WtSettings {
    $script:values = @{}
    $doc = Read-WtJsonFile (Get-WtSettingsPath)
    if ($doc -and $doc.values) {
        foreach ($p in $doc.values.PSObject.Properties) { $script:values[$p.Name] = $p.Value }
    }
}

# 애드온이 자기 설정의 기본값을 등록한다
function Register-WtSettingDefault([string]$Key, $Value) { $script:defaults[$Key] = $Value }

function Get-WtSetting([string]$Key) {
    if ($null -eq $script:values) { Initialize-WtSettings }
    if ($script:values.ContainsKey($Key)) { return $script:values[$Key] }
    $script:defaults[$Key]
}

function Test-WtSameValue($A, $B) {
    (ConvertTo-Json -InputObject $A -Compress -Depth 5) -eq (ConvertTo-Json -InputObject $B -Compress -Depth 5)
}

# 값을 바꾸고 저장한 뒤, 등록된 처리기에 알린다
function Set-WtSetting([string]$Key, $Value) {
    if ($null -eq $script:values) { Initialize-WtSettings }
    $next = $script:values.Clone()
    if ($script:defaults.ContainsKey($Key) -and (Test-WtSameValue $script:defaults[$Key] $Value)) {
        [void]$next.Remove($Key)
    } else {
        $next[$Key] = $Value
    }
    $sorted = [ordered]@{}
    foreach ($k in ($next.Keys | Sort-Object)) { $sorted[$k] = $next[$k] }
    Write-WtJsonFile (Get-WtSettingsPath) ([ordered]@{ schema = 1; values = $sorted })
    $script:values = $next
    foreach ($h in @($script:handlers)) { & $h $Key $Value }
}

# 설정이 바뀔 때 부를 처리기. { param($key, $value) ... }
function Register-WtSettingHandler([scriptblock]$Handler) { $script:handlers.Add($Handler) }

Export-ModuleMember -Function Get-WtSettingsPath, Initialize-WtSettings, Register-WtSettingDefault, Get-WtSetting,
    Set-WtSetting, Register-WtSettingHandler
} | Import-Module -Force -DisableNameChecking
# ---- core\Settings.psm1 끝 ----

# ---- core\Theme.psm1 ----
New-Module -Name 'WorkTool.Theme' -ScriptBlock {
# 테마 담당. 색 · 글자 크기 · 글꼴은 여기서만 정하고, 화면은 리소스 이름(B.Accent, F.Body …)으로만 쓴다.
# 값의 기준은 apps/WorkTool/design/README.md다. 팔레트를 바꾸거나 더할 때는 그 문서도 같이 고친다.
#
# 팔레트 하나 = 연한 바탕색(Tint) + 강조색(Accent).
# - Tint: 선택된 메뉴 바탕. 메뉴 · 창 바탕은 Tint를 흰색과 섞어 더 연하게 쓴다.
# - Accent: 주 버튼 · 선택 표시. 흰 글자와 4.5:1 이상이어야 한다 (tests/Test-Core.ps1이 검사).

$ErrorActionPreference = 'Stop'

$script:palettes = [ordered]@{
    sky    = @{ Label = '하늘'; Tint = '#DCEBFA'; Accent = '#2370C2' }
    pink   = @{ Label = '분홍'; Tint = '#FADDE8'; Accent = '#B83D69' }
    green  = @{ Label = '연두'; Tint = '#E1F1CF'; Accent = '#3F7D20' }
    yellow = @{ Label = '노랑'; Tint = '#FBEDBF'; Accent = '#856000' }
    purple = @{ Label = '보라'; Tint = '#E9E0F8'; Accent = '#7048B8' }
    gray   = @{ Label = '회색'; Tint = '#E3E7EC'; Accent = '#56606D' }
    black  = @{ Label = '검정'; Tint = '#DEDFE2'; Accent = '#2B2F36' }
}

# 테마와 상관없이 같은 색 (글자, 선, 상태, 근태 종류)
$script:fixed = @{
    Card         = '#FFFFFF'
    OnAccent     = '#FFFFFF'
    Text         = '#1D2B3A'
    SubText      = '#56667A'
    NavText      = '#2E3E50'
    Border       = '#DCE3EC'
    Divider      = '#EEF2F7'
    InputBorder  = '#7F8C9C'
    ButtonBorder = '#C4CEDA'
    Chip         = '#EEF2F7'
    ChipText     = '#4A5A6C'
    Danger       = '#B83227'
    DangerBg     = '#FBE7E4'
    Success      = '#1E7F4F'
    SuccessBg    = '#E3F4EB'
    Warn         = '#8A5A08'
    WarnBg       = '#FDF1DC'
    CloseHover   = '#C42B1C'
    'Att.Work'   = '#1C5A9B'; 'Att.WorkBg'  = '#E0EBF7'
    'Att.Over'   = '#5A42AE'; 'Att.OverBg'  = '#EEEAFB'
    'Att.Trip'   = '#0B6E6D'; 'Att.TripBg'  = '#DDF2F1'
    'Att.Leave'  = '#9C4E0F'; 'Att.LeaveBg' = '#FCEBDC'

    # 마크다운 보기 (Markdown.psm1)
    'Md.QuoteBar' = '#C4CEDA'   # 인용 왼쪽 막대 (장식)
    'Md.Mark'     = '#FFF0A8'   # ==형광펜== 바탕
    # 콜아웃 (> [!note] …): 제목 · 막대 글자색 / 바탕
    'Callout.Blue'   = '#1C5A9B'; 'Callout.BlueBg'   = '#E0EBF7'
    'Callout.Teal'   = '#0B6E6D'; 'Callout.TealBg'   = '#DDF2F1'
    'Callout.Green'  = '#1A6E44'; 'Callout.GreenBg'  = '#E3F4EB'
    'Callout.Orange' = '#8A5A08'; 'Callout.OrangeBg' = '#FDF1DC'
    'Callout.Red'    = '#B83227'; 'Callout.RedBg'    = '#FBE7E4'
    'Callout.Purple' = '#5A42AE'; 'Callout.PurpleBg' = '#EEEAFB'
    'Callout.Gray'   = '#4A5A6C'; 'Callout.GrayBg'   = '#EEF2F7'
    # 코드 블록 바탕과 색칠 (Highlight.psm1의 Kind 이름). 모두 Code.Bg 위에서 4.5:1 이상
    'Code.Bg'       = '#F3F6F9'
    'Code.Comment'  = '#56667A'
    'Code.String'   = '#0A3069'
    'Code.Keyword'  = '#C4243B'
    'Code.Number'   = '#0550AE'
    'Code.Command'  = '#6639BA'
    'Code.Variable' = '#953800'
    'Code.Type'     = '#116329'
    'Code.Attr'     = '#0B6E6D'
    'Code.Inserted' = '#1A6E44'
    'Code.Deleted'  = '#B83227'
    # 다이어그램 (Mermaid.psm1)
    'Dia.NodeBg'    = '#EEF2F7'
    'Dia.NodeLine'  = '#7F8C9C'   # 흰 바탕과 3:1 이상
    'Dia.Line'      = '#56667A'   # 연결선 · 화살표
    'Dia.GroupBg'   = '#F7F9FB'
    'Dia.GroupLine' = '#C4CEDA'
    'Dia.NoteBg'    = '#FDF1DC'
    'Dia.NoteLine'  = '#D9B66A'
}

$script:fontScales = @{ s = 0.93; m = 1.0; l = 1.12 }
# MdH1~3 · Code · BodyLine(본문 줄 높이 1.5배)은 마크다운 보기용
$script:fontSizes = @{ Title = 26; Number = 22; H2 = 16; Dialog = 20; Body = 14; Small = 12.5; Icon = 16; MdH1 = 24; MdH2 = 20; MdH3 = 17; Code = 13; BodyLine = 21 }
$script:fonts = @{
    # 앞 글꼴에 없는 글자는 다음 글꼴로 그린다. UI는 Windows 기본 글꼴만 쓴다: 영문 · 숫자는 Segoe UI Variable(Windows 11)
    # → Segoe UI(Windows 10), 한글은 맑은 고딕. 따로 설치하는 글꼴(Noto Sans KR 등)은 PC마다 있고 없고가 달라 쓰지 않는다
    UI   = 'Segoe UI Variable Text, Segoe UI, Malgun Gothic'
    Icon = 'Segoe Fluent Icons, Segoe MDL2 Assets'
    Mono = 'Consolas, Malgun Gothic'   # 코드 · 출력 칸. 영문은 Consolas, 한글은 맑은 고딕 (둘 다 Windows 기본)
}

# ---- 색 계산 (WPF 없이도 동작: 테스트용) ------------------------------------------------------

function ConvertFrom-WtHex([string]$Hex) {
    $h = $Hex.TrimStart('#')
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

# $A를 $B 쪽으로 $T(0~1)만큼 섞는다
function Get-WtMixedColor([string]$A, [string]$B, [double]$T) {
    $x = ConvertFrom-WtHex $A
    $y = ConvertFrom-WtHex $B
    $c = for ($i = 0; $i -lt 3; $i++) { [int][Math]::Round($x[$i] * (1 - $T) + $y[$i] * $T) }
    '#{0:X2}{1:X2}{2:X2}' -f $c[0], $c[1], $c[2]
}

function Get-WtLuminance([string]$Hex) {
    $lin = foreach ($v in (ConvertFrom-WtHex $Hex)) {
        $s = $v / 255
        if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $lin[0] + 0.7152 * $lin[1] + 0.0722 * $lin[2]
}

function Get-WtContrast([string]$A, [string]$B) {
    $la = Get-WtLuminance $A
    $lb = Get-WtLuminance $B
    ([Math]::Max($la, $lb) + 0.05) / ([Math]::Min($la, $lb) + 0.05)
}

function Get-WtPalette { $script:palettes }

# 팔레트 이름 → 색 이름별 #RRGGBB
function Get-WtThemeColors([string]$Name) {
    $p = $script:palettes[$Name]
    if (-not $p) { $p = $script:palettes['sky'] }
    $c = @{}
    foreach ($k in $script:fixed.Keys) { $c[$k] = $script:fixed[$k] }
    $c.Accent       = $p.Accent
    $c.AccentHover  = Get-WtMixedColor $p.Accent '#000000' 0.12
    $c.AccentStrong = Get-WtMixedColor $p.Accent '#000000' 0.18
    $c.AccentSoft   = $p.Tint
    $c.Hover        = Get-WtMixedColor $p.Tint '#FFFFFF' 0.25
    $c.Sidebar      = Get-WtMixedColor $p.Tint '#FFFFFF' 0.45
    $c.WindowBg     = Get-WtMixedColor $p.Tint '#FFFFFF' 0.75
    $c.FrameBorder  = Get-WtMixedColor $p.Tint '#8C99A8' 0.55
    $c
}

# ---- WPF 리소스 ------------------------------------------------------------------------------

# 테마 리소스를 담은 사전을 채운다. 같은 사전의 값을 바꾸면 DynamicResource로 쓴 화면이 바로 바뀐다.
function Update-WtThemeDictionary([System.Windows.ResourceDictionary]$Dictionary) {
    $colors = Get-WtThemeColors ([string](Get-WtSetting 'theme.color'))
    foreach ($k in $colors.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($colors[$k])
        $brush = [System.Windows.Media.SolidColorBrush]::new($color)
        $brush.Freeze()
        $Dictionary["B.$k"] = $brush
    }
    foreach ($k in $script:fontSizes.Keys) { $Dictionary["F.$k"] = Get-WtFontSize $k }
    foreach ($k in $script:fonts.Keys) { $Dictionary["Font.$k"] = [System.Windows.Media.FontFamily]::new($script:fonts[$k]) }
}

# 지금 설정의 글자 크기 (F.* 리소스와 같은 값). 화면에 붙기 전에 크기를 재야 할 때 쓴다 (다이어그램 배치 등).
function Get-WtFontSize([string]$Name) {
    $scale = $script:fontScales[[string](Get-WtSetting 'ui.fontScale')]
    if (-not $scale) { $scale = 1.0 }
    [double][Math]::Round($script:fontSizes[$Name] * $scale, 1)
}

# 글꼴 이름 목록 (Font.* 리소스와 같은 값). $Name: UI · Icon · Mono
function Get-WtFontName([string]$Name) { $script:fonts[$Name] }

function New-WtThemeDictionary {
    $d = [System.Windows.ResourceDictionary]::new()
    Update-WtThemeDictionary $d
    $d
}

Export-ModuleMember -Function ConvertFrom-WtHex, Get-WtMixedColor, Get-WtLuminance, Get-WtContrast, Get-WtPalette,
    Get-WtThemeColors, Update-WtThemeDictionary, New-WtThemeDictionary, Get-WtFontSize, Get-WtFontName
} | Import-Module -Force -DisableNameChecking
# ---- core\Theme.psm1 끝 ----

# ---- core\Ui.psm1 ----
New-Module -Name 'WorkTool.Ui' -ScriptBlock {
# 공통 부품. 버튼 · 입력 칸 · 카드 · 메뉴 항목 같은 모양은 여기서만 정한다.
# 기능(애드온) 모듈은 아래 New-Wt* 함수와 스타일 이름만 쓰고, 색 값이나 글꼴 이름을 직접 쓰지 않는다.
# 색 · 크기는 Theme.psm1의 리소스(B.* · F.* · Font.*)를 DynamicResource로 참조해서, 테마를 바꾸면 바로 반영된다.

$ErrorActionPreference = 'Stop'

$script:ns = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

# 스타일 모음. 색은 Style.Triggers에서 바꾼다 (템플릿 트리거로 바꾸면 BasedOn 스타일에서 덮어쓸 수 없어서).
$script:stylesXaml = @'
<ResourceDictionary {NS}>

  <Style x:Key="T.Body" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
  </Style>
  <Style x:Key="T.Sub" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="T.Title" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Title}"/>
    <Setter Property="FontWeight" Value="Bold"/>
  </Style>
  <Style x:Key="T.H2" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.H2}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="T.Number" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontSize" Value="{DynamicResource F.Number}"/>
    <Setter Property="FontWeight" Value="Bold"/>
  </Style>
  <Style x:Key="T.Dialog" TargetType="TextBlock" BasedOn="{StaticResource T.H2}">
    <Setter Property="FontSize" Value="{DynamicResource F.Dialog}"/>
  </Style>
  <Style x:Key="T.Strong" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="T.Icon" TargetType="TextBlock">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Icon}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Icon}"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="HorizontalAlignment" Value="Center"/>
  </Style>

  <Style x:Key="Card" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="12"/>
    <Setter Property="Padding" Value="20,16"/>
  </Style>
  <Style x:Key="Tile" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.WindowBg}"/>
    <Setter Property="CornerRadius" Value="10"/>
    <Setter Property="Padding" Value="14,10"/>
  </Style>
  <Style x:Key="Divider" TargetType="Border">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Divider}"/>
    <Setter Property="BorderThickness" Value="0,1,0,0"/>
  </Style>

  <Style x:Key="Btn" TargetType="Button">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.ButtonBorder}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="16,0"/>
    <Setter Property="MinHeight" Value="40"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
      <Trigger Property="IsKeyboardFocused" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
      </Trigger>
      <Trigger Property="IsEnabled" Value="False">
        <Setter Property="Opacity" Value="0.5"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Primary" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="{DynamicResource B.Accent}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.OnAccent}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentHover}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource B.AccentHover}"/>
      </Trigger>
      <Trigger Property="IsKeyboardFocused" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.Text}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Danger" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Danger}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.DangerBg}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Btn.Link" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.AccentStrong}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Padding" Value="10,0"/>
  </Style>
  <Style x:Key="Btn.Icon" TargetType="Button" BasedOn="{StaticResource Btn}">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.NavText}"/>
    <Setter Property="Width" Value="40"/>
    <Setter Property="Height" Value="40"/>
    <Setter Property="MinHeight" Value="0"/>
    <Setter Property="Padding" Value="0"/>
  </Style>
  <Style x:Key="Btn.Chrome" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">
    <Setter Property="Width" Value="46"/>
    <Setter Property="Height" Value="40"/>
  </Style>
  <Style x:Key="Btn.Close" TargetType="Button" BasedOn="{StaticResource Btn.Chrome}">
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.CloseHover}"/>
        <Setter Property="Foreground" Value="#FFFFFF"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Nav" TargetType="RadioButton">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.NavText}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Height" Value="40"/>
    <Setter Property="Margin" Value="0,2"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="12,0">
            <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="False"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
      <Trigger Property="IsChecked" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
        <Setter Property="Foreground" Value="{DynamicResource B.AccentStrong}"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Seg" TargetType="RadioButton">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.ChipText}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="MinHeight" Value="34"/>
    <Setter Property="Padding" Value="14,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" RecognizesAccessKey="False"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsChecked" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Card}"/>
        <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
        <Setter Property="FontWeight" Value="SemiBold"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Swatch" TargetType="RadioButton">
    <Setter Property="Width" Value="40"/>
    <Setter Property="Height" Value="40"/>
    <Setter Property="Margin" Value="0,0,6,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Grid Background="Transparent">
            <Ellipse x:Name="Ring" Stroke="{DynamicResource B.Text}" StrokeThickness="2" Visibility="Hidden"/>
            <Ellipse Margin="6" Fill="{TemplateBinding Background}" Stroke="{TemplateBinding BorderBrush}" StrokeThickness="1"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Ring" Property="Visibility" Value="Visible"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <Style x:Key="Input" TargetType="TextBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="10,8"/>
    <Setter Property="MinHeight" Value="40"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                  BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
            <!-- 안쪽 여백(Padding)은 TextBox가 글자 둘레에 스스로 넣는다. 여기서 또 넣으면 두 배가 된다 -->
            <ScrollViewer x:Name="PART_ContentHost" Focusable="False"
                          VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsKeyboardFocused" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Reader" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="IsReadOnly" Value="True"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="VerticalContentAlignment" Value="Top"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
  </Style>
  <!-- 실행 출력: 코드 바탕의 읽기 전용 여러 줄. 줄을 바꾸지 않고 가로로 스크롤한다 (스크립트 출력 등) -->
  <Style x:Key="Output" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="IsReadOnly" Value="True"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Code}"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="TextWrapping" Value="NoWrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="VerticalContentAlignment" Value="Top"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
  </Style>

  <!-- 고르기 칸(ComboBox): 입력칸과 같은 테두리 · 높이 · 모서리. 펼친 목록은 카드 모양 -->
  <Style x:Key="Combo.Item" TargetType="ComboBoxItem">
    <Setter Property="Padding" Value="10,8"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBoxItem">
          <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}" Margin="4,1">
            <ContentPresenter/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.AccentSoft}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Combo" TargetType="ComboBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
    <Setter Property="MinHeight" Value="40"/>
    <Setter Property="Padding" Value="10,8,32,8"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource Combo.Item}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ComboBox">
          <Grid>
            <ToggleButton Focusable="False" ClickMode="Press"
                          IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <ToggleButton.Template>
                <ControlTemplate TargetType="ToggleButton">
                  <Border x:Name="Bd" CornerRadius="8" BorderThickness="1"
                          Background="{Binding Background, RelativeSource={RelativeSource AncestorType=ComboBox}}"
                          BorderBrush="{Binding BorderBrush, RelativeSource={RelativeSource AncestorType=ComboBox}}">
                    <TextBlock Text="&#xE70D;" FontFamily="{DynamicResource Font.Icon}" FontSize="12" Foreground="{DynamicResource B.SubText}"
                               HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,12,0"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsMouseOver" Value="True">
                      <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Hover}"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </ToggleButton.Template>
            </ToggleButton>
            <ContentPresenter IsHitTestVisible="False" Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left"
                              Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"/>
            <Popup x:Name="PART_Popup" Placement="Bottom" AllowsTransparency="True" Focusable="False" PopupAnimation="None"
                   IsOpen="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
              <Border Background="{DynamicResource B.Card}" BorderBrush="{DynamicResource B.Border}" BorderThickness="1" CornerRadius="8"
                      Padding="0,4" Margin="0,4,0,0" MaxHeight="{TemplateBinding MaxDropDownHeight}"
                      MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource TemplatedParent}}">
                <ScrollViewer><ItemsPresenter/></ScrollViewer>
              </Border>
            </Popup>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocusWithin" Value="True">
              <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False">
              <Setter Property="Opacity" Value="0.5"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 끝을 알 수 없는 진행 표시: 얇은 막대 -->
  <Style x:Key="Busy" TargetType="ProgressBar">
    <Setter Property="Height" Value="4"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Accent}"/>
    <Setter Property="Background" Value="{DynamicResource B.Chip}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="IsIndeterminate" Value="True"/>
  </Style>

  <!-- 편집 칸: 카드 안을 채우는 테두리 없는 여러 줄 입력 (메모 본문 등) -->
  <Style x:Key="Editor" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="AcceptsTab" Value="True"/>
    <Setter Property="VerticalContentAlignment" Value="Top"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
  </Style>
  <!-- 제목 입력: 글자처럼 보이는 한 줄 입력 (포커스가 가면 아래 선이 강조색) -->
  <Style x:Key="Input.Title" TargetType="TextBox" BasedOn="{StaticResource Input}">
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="0,2"/>
    <Setter Property="MinHeight" Value="0"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Number}"/>
    <Setter Property="FontWeight" Value="Bold"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
      </Trigger>
      <Trigger Property="IsKeyboardFocused" Value="True">
        <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
      </Trigger>
    </Style.Triggers>
  </Style>

  <Style x:Key="Row" TargetType="ListBoxItem">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="12,10"/>
    <Setter Property="Margin" Value="0,1"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ListBoxItem">
          <Border Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
      <Trigger Property="IsSelected" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="List" TargetType="ListBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource Row}"/>
    <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
    <Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/>
    <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>
    <Setter Property="ItemsPanel"><Setter.Value><ItemsPanelTemplate><VirtualizingStackPanel/></ItemsPanelTemplate></Setter.Value></Setter>
  </Style>

  <DataTemplate x:Key="Memo.Item">
    <StackPanel>
      <DockPanel>
        <TextBlock DockPanel.Dock="Right" Text="{Binding Stamp}" Style="{DynamicResource T.Sub}" Margin="8,0,0,0"/>
        <TextBlock Text="{Binding Title}" Style="{DynamicResource T.Strong}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      </DockPanel>
      <TextBlock Text="{Binding Snippet}" Style="{DynamicResource T.Sub}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
    </StackPanel>
  </DataTemplate>
  <Style x:Key="Memo.List" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.Item}"/>
  </Style>

  <!-- 메모 칸(pane): 맨 위 탭 줄이 카드 가장자리에 붙도록 안쪽 여백 없는 카드 -->
  <Style x:Key="Memo.Pane" TargetType="Border" BasedOn="{StaticResource Card}">
    <Setter Property="Padding" Value="0"/>
  </Style>
  <Style x:Key="Memo.TabBar" TargetType="Border">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
    <Setter Property="Padding" Value="8,4,8,0"/>
  </Style>
  <!-- 메모 탭 하나. 선택 표시는 바탕 + 아래 가운데 막대(3 × 16). 막대 색은 BorderBrush로 받는다
       Memo.Tab: 선택 안 됨 · Memo.Tab.Current: 포커스가 있는 칸의 지금 탭 · Memo.Tab.Selected: 다른 칸의 지금 탭(덜 강조) -->
  <Style x:Key="Memo.Tab" TargetType="Button">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="MinHeight" Value="40"/>
    <Setter Property="Padding" Value="12,0,4,0"/>
    <Setter Property="Margin" Value="0,0,4,0"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Button">
          <Grid>
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="Transparent" BorderThickness="1"
                    CornerRadius="8,8,0,0" Padding="{TemplateBinding Padding}">
              <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </Border>
            <Border Width="16" Height="3" CornerRadius="1" HorizontalAlignment="Center" VerticalAlignment="Bottom"
                    Background="{TemplateBinding BorderBrush}"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource B.Text}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Memo.Tab.Selected" TargetType="Button" BasedOn="{StaticResource Memo.Tab}">
    <Setter Property="Background" Value="{DynamicResource B.Chip}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
  </Style>
  <Style x:Key="Memo.Tab.Current" TargetType="Button" BasedOn="{StaticResource Memo.Tab}">
    <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Memo.TabText" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="TextWrapping" Value="NoWrap"/>
    <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    <Setter Property="MaxWidth" Value="160"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
  </Style>
  <!-- 탭의 닫기(X). 탭 바탕(마우스 올림 · 선택)과 겹치지 않게 마우스 올림은 테두리 색 -->
  <Style x:Key="Memo.TabClose" TargetType="Button" BasedOn="{StaticResource Btn.Icon}">
    <Setter Property="Width" Value="24"/>
    <Setter Property="Height" Value="24"/>
    <Setter Property="Margin" Value="4,0,0,0"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Border}"/>
        <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <!-- 두 칸 사이 경계: 폭 16(칸 사이 간격)을 끌어 폭을 바꾼다. 마우스를 올리거나 끌 때만 가운데 선이 보인다 -->
  <Style x:Key="Memo.Splitter" TargetType="GridSplitter">
    <Setter Property="Width" Value="16"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/>
    <Setter Property="VerticalAlignment" Value="Stretch"/>
    <Setter Property="ResizeDirection" Value="Columns"/>
    <Setter Property="ResizeBehavior" Value="PreviousAndNext"/>
    <Setter Property="Cursor" Value="SizeWE"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="GridSplitter">
          <Grid Background="Transparent">
            <Border x:Name="Line" Width="2" CornerRadius="1" Margin="0,16" Background="Transparent"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Line" Property="Background" Value="{DynamicResource B.InputBorder}"/>
            </Trigger>
            <Trigger Property="IsKeyboardFocused" Value="True">
              <Setter TargetName="Line" Property="Background" Value="{DynamicResource B.Text}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="Line" Property="Background" Value="{DynamicResource B.Accent}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <!-- 빠른 이동(Ctrl+O): 메모 화면 위 가운데에 겹쳐 뜨는 검색 상자 + 결과 목록. 그림자는 Overlay.Shadow를 뒤에 깐다 -->
  <Style x:Key="Memo.QuickHost" TargetType="Grid">
    <Setter Property="Width" Value="560"/>
    <Setter Property="HorizontalAlignment" Value="Center"/>
    <Setter Property="VerticalAlignment" Value="Top"/>
    <Setter Property="Margin" Value="0,24,0,0"/>
  </Style>
  <Style x:Key="Memo.QuickPanel" TargetType="Border" BasedOn="{StaticResource Card}">
    <Setter Property="Padding" Value="12"/>
  </Style>
  <DataTemplate x:Key="Memo.QuickItem">
    <StackPanel>
      <TextBlock Text="{Binding Title}" Style="{DynamicResource T.Strong}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="Sub" Text="{Binding Sub}" Style="{DynamicResource T.Sub}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="0,2,0,0"/>
    </StackPanel>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding Sub}" Value="">
        <Setter TargetName="Sub" Property="Visibility" Value="Collapsed"/>
      </DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>
  <Style x:Key="Memo.QuickList" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.QuickItem}"/>
    <Setter Property="MaxHeight" Value="400"/>
    <Setter Property="Margin" Value="0,8,0,0"/>
  </Style>
  <Style x:Key="Doc.Row" TargetType="ListBoxItem" BasedOn="{StaticResource Row}">
    <Setter Property="Padding" Value="12,6"/>
    <Setter Property="Tag" Value="{Binding}"/>
    <Setter Property="ToolTip" Value="{Binding Path}"/>
  </Style>
  <DataTemplate x:Key="Doc.Item">
    <DockPanel>
      <TextBlock DockPanel.Dock="Right" Text="{Binding SizeText}" Style="{DynamicResource T.Sub}" Width="80" TextAlignment="Right" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <TextBlock DockPanel.Dock="Right" Text="{Binding ModifiedText}" Style="{DynamicResource T.Sub}" Width="130" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <TextBlock DockPanel.Dock="Right" Text="{Binding Kind}" Style="{DynamicResource T.Sub}" Width="90" Margin="12,0,0,0" VerticalAlignment="Center"/>
      <TextBlock x:Name="DocIcon" DockPanel.Dock="Left" Text="{Binding IconText}" Style="{DynamicResource T.Icon}" Foreground="{DynamicResource B.SubText}" Width="20"/>
      <TextBlock x:Name="DocName" Text="{Binding Name}" Style="{DynamicResource T.Body}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis" Margin="8,0,0,0" VerticalAlignment="Center"/>
    </DockPanel>
    <DataTemplate.Triggers>
      <DataTrigger Binding="{Binding Missing}" Value="True">
        <Setter TargetName="DocIcon" Property="Foreground" Value="{DynamicResource B.Warn}"/>
        <Setter TargetName="DocName" Property="Foreground" Value="{DynamicResource B.SubText}"/>
      </DataTrigger>
    </DataTemplate.Triggers>
  </DataTemplate>
  <Style x:Key="Doc.List" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemContainerStyle" Value="{StaticResource Doc.Row}"/>
    <Setter Property="ItemTemplate" Value="{StaticResource Doc.Item}"/>
  </Style>

  <!-- 트리 (문서 탭 폴더 등): 펼침 화살표 + 목록 행과 같은 둥근 바탕 -->
  <Style x:Key="TreeExpander" TargetType="ToggleButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Width" Value="20"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border Background="Transparent">
            <TextBlock x:Name="Glyph" Text="&#xE76C;" FontFamily="{DynamicResource Font.Icon}" FontSize="10"
                       Foreground="{DynamicResource B.SubText}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="Glyph" Property="Text" Value="&#xE70D;"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="TreeItem" TargetType="TreeViewItem">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Padding" Value="4,6,10,6"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="TreeViewItem">
          <StackPanel>
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}" Margin="0,1"
                    BorderBrush="Transparent" BorderThickness="1">
              <DockPanel>
                <ToggleButton x:Name="Expander" DockPanel.Dock="Left" Style="{StaticResource TreeExpander}" ClickMode="Press"
                              IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}}"/>
                <ContentPresenter ContentSource="Header" VerticalAlignment="Center" Margin="4,0,0,0" RecognizesAccessKey="False"/>
              </DockPanel>
            </Border>
            <ItemsPresenter x:Name="ItemsHost" Margin="16,0,0,0" Visibility="Collapsed"/>
          </StackPanel>
          <ControlTemplate.Triggers>
            <Trigger Property="IsExpanded" Value="True">
              <Setter TargetName="ItemsHost" Property="Visibility" Value="Visible"/>
            </Trigger>
            <Trigger Property="HasItems" Value="False">
              <Setter TargetName="Expander" Property="Visibility" Value="Hidden"/>
            </Trigger>
            <Trigger SourceName="Bd" Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Hover}"/>
            </Trigger>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.AccentSoft}"/>
            </Trigger>
            <MultiTrigger>
              <MultiTrigger.Conditions>
                <Condition Property="IsSelected" Value="True"/>
                <Condition Property="IsKeyboardFocusWithin" Value="True"/>
              </MultiTrigger.Conditions>
              <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
            </MultiTrigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Tree" TargetType="TreeView">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="ItemContainerStyle" Value="{StaticResource TreeItem}"/>
    <Setter Property="ScrollViewer.HorizontalScrollBarVisibility" Value="Disabled"/>
  </Style>

  <!-- 체크 상자: 표의 선택 상자(Task.Check)와 같은 16 상자 + 오른쪽 글자. 글자를 눌러도 바뀐다 -->
  <Style x:Key="Check" TargetType="CheckBox">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="VerticalContentAlignment" Value="Center"/>
    <Setter Property="Margin" Value="0,4"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
      <DockPanel Background="Transparent">
        <Border x:Name="Box" DockPanel.Dock="Left" Width="16" Height="16" VerticalAlignment="Center"
          CornerRadius="4" Background="{DynamicResource B.Card}" BorderBrush="{DynamicResource B.InputBorder}" BorderThickness="1">
          <Grid>
            <Path x:Name="Mark" Data="M 2,7 L 6,11 L 12,3" Stroke="{DynamicResource B.OnAccent}" StrokeThickness="2" Visibility="Collapsed"/>
            <Border x:Name="Dash" Width="8" Height="2" Background="{DynamicResource B.OnAccent}" Visibility="Collapsed"/>
          </Grid>
        </Border>
        <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
      </DockPanel>
      <ControlTemplate.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.SubText}"/></Trigger>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter TargetName="Mark" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsChecked" Value="{x:Null}"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Accent}"/><Setter TargetName="Dash" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Text}"/><Setter TargetName="Box" Property="BorderThickness" Value="2"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>

  <!-- 스크롤 막대: 화살표 없이 둥근 손잡이만 (막대 폭 12 · 손잡이 8). 키 없는 스타일이라 창 안의 모든 스크롤에 쓰인다 -->
  <Style x:Key="Scroll.Thumb" TargetType="Thumb">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Border x:Name="Bd" Background="{DynamicResource B.InputBorder}" CornerRadius="4"/>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.SubText}"/>
            </Trigger>
            <Trigger Property="IsDragging" Value="True">
              <Setter TargetName="Bd" Property="Background" Value="{DynamicResource B.Text}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Scroll.Page" TargetType="RepeatButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="IsTabStop" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="ScrollBar">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="Width" Value="12"/>
    <Setter Property="MinWidth" Value="12"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Border Background="{TemplateBinding Background}">
            <Track x:Name="PART_Track" IsDirectionReversed="True" Margin="2">
              <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Scroll.Page}" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Scroll.Page}" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb Style="{StaticResource Scroll.Thumb}"/></Track.Thumb>
            </Track>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
    <Style.Triggers>
      <Trigger Property="Orientation" Value="Horizontal">
        <Setter Property="Width" Value="Auto"/>
        <Setter Property="MinWidth" Value="0"/>
        <Setter Property="Height" Value="12"/>
        <Setter Property="MinHeight" Value="12"/>
        <Setter Property="Template">
          <Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Border Background="{TemplateBinding Background}">
                <Track x:Name="PART_Track" Margin="2">
                  <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Scroll.Page}" Command="ScrollBar.PageLeftCommand"/></Track.DecreaseRepeatButton>
                  <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Scroll.Page}" Command="ScrollBar.PageRightCommand"/></Track.IncreaseRepeatButton>
                  <Track.Thumb><Thumb Style="{StaticResource Scroll.Thumb}"/></Track.Thumb>
                </Track>
              </Border>
            </ControlTemplate>
          </Setter.Value>
        </Setter>
      </Trigger>
    </Style.Triggers>
  </Style>
  <!-- 기본 모양과 같고, 가로 · 세로 막대가 만나는 모서리만 회색 칸 대신 비워 둔다 -->
  <Style TargetType="ScrollViewer">
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ScrollViewer">
          <Grid Background="{TemplateBinding Background}">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <ScrollContentPresenter x:Name="PART_ScrollContentPresenter" Margin="{TemplateBinding Padding}"
                                    CanContentScroll="{TemplateBinding CanContentScroll}" CanHorizontallyScroll="False" CanVerticallyScroll="False"
                                    Content="{TemplateBinding Content}" ContentTemplate="{TemplateBinding ContentTemplate}"/>
            <ScrollBar x:Name="PART_VerticalScrollBar" Grid.Column="1" AutomationProperties.AutomationId="VerticalScrollBar" Cursor="Arrow"
                       Minimum="0" Maximum="{TemplateBinding ScrollableHeight}" ViewportSize="{TemplateBinding ViewportHeight}"
                       Value="{Binding VerticalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"
                       Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
            <ScrollBar x:Name="PART_HorizontalScrollBar" Grid.Row="1" Orientation="Horizontal" AutomationProperties.AutomationId="HorizontalScrollBar" Cursor="Arrow"
                       Minimum="0" Maximum="{TemplateBinding ScrollableWidth}" ViewportSize="{TemplateBinding ViewportWidth}"
                       Value="{Binding HorizontalOffset, Mode=OneWay, RelativeSource={RelativeSource TemplatedParent}}"
                       Visibility="{TemplateBinding ComputedHorizontalScrollBarVisibility}"/>
          </Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 값 고르기 막대(Slider, 가로): 높이 4 막대 + 지름 20 손잡이. 고른 쪽은 강조색 -->
  <Style x:Key="Range.Fill" TargetType="RepeatButton">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="IsTabStop" Value="False"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="RepeatButton">
          <Grid Background="Transparent"><Border Height="4" CornerRadius="2" Background="{TemplateBinding Background}" VerticalAlignment="Center"/></Grid>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Range.Thumb" TargetType="Thumb">
    <Setter Property="Focusable" Value="False"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.InputBorder}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Thumb">
          <Grid Width="20" Height="20">
            <Ellipse x:Name="Ring" Fill="{DynamicResource B.Card}" Stroke="{TemplateBinding BorderBrush}" StrokeThickness="1"/>
            <Ellipse x:Name="Dot" Width="12" Height="12" Fill="{DynamicResource B.Accent}"/>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Dot" Property="Width" Value="14"/><Setter TargetName="Dot" Property="Height" Value="14"/></Trigger>
            <Trigger Property="IsDragging" Value="True"><Setter TargetName="Dot" Property="Width" Value="10"/><Setter TargetName="Dot" Property="Height" Value="10"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="Range" TargetType="Slider">
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Slider">
          <Grid Background="Transparent">
            <Track x:Name="PART_Track">
              <Track.DecreaseRepeatButton><RepeatButton Style="{StaticResource Range.Fill}" Background="{DynamicResource B.Accent}" Command="Slider.DecreaseLarge"/></Track.DecreaseRepeatButton>
              <Track.IncreaseRepeatButton><RepeatButton Style="{StaticResource Range.Fill}" Background="{DynamicResource B.InputBorder}" Command="Slider.IncreaseLarge"/></Track.IncreaseRepeatButton>
              <Track.Thumb><Thumb x:Name="Thumb" Style="{StaticResource Range.Thumb}"/></Track.Thumb>
            </Track>
          </Grid>
          <ControlTemplate.Triggers>
            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Thumb" Property="BorderBrush" Value="{DynamicResource B.Text}"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 겹쳐 뜨는 패널(좁은 창에서 내용 위에 여는 설명 패널 등)의 그림자. 패널에 바로 걸면 패널 글자까지 그림 한 장으로 다시 그려져서, 패널 뒤에 따로 깐다 -->
  <Style x:Key="Overlay.Shadow" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="CornerRadius" Value="12"/>
    <Setter Property="Effect">
      <Setter.Value>
        <DropShadowEffect BlurRadius="16" ShadowDepth="8" Direction="270" Opacity="0.14" Color="#000000"/>
      </Setter.Value>
    </Setter>
  </Style>

  <!-- 마크다운 보기 (Markdown.psm1). 문서 요소(Paragraph · Section · Run …)의 모양 -->
  <!-- RichTextBox는 배치할 때 문서 좌우에 5씩 여백을 넣는다(PagePadding 5,0). 안쪽 여백 -5로 없애서 옆 글과 줄을 맞춘다 -->
  <Style x:Key="Md.View" TargetType="RichTextBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="-5,0,-5,0"/>
    <Setter Property="AcceptsTab" Value="False"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
  </Style>
  <Style x:Key="Md.Doc" TargetType="FlowDocument">
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="LineHeight" Value="{DynamicResource F.BodyLine}"/>
    <Setter Property="PagePadding" Value="0"/>
    <Setter Property="TextAlignment" Value="Left"/>
  </Style>
  <Style x:Key="Md.P" TargetType="Paragraph">
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.PTight" TargetType="Paragraph">
    <Setter Property="Margin" Value="0"/>
  </Style>
  <Style x:Key="Md.H1" TargetType="Paragraph">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH1}"/>
    <Setter Property="FontWeight" Value="Bold"/>
    <Setter Property="LineHeight" Value="Auto"/>
    <Setter Property="Margin" Value="0,24,0,12"/>
  </Style>
  <Style x:Key="Md.H2" TargetType="Paragraph" BasedOn="{StaticResource Md.H1}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH2}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,24,0,8"/>
  </Style>
  <Style x:Key="Md.H3" TargetType="Paragraph" BasedOn="{StaticResource Md.H2}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH3}"/>
    <Setter Property="Margin" Value="0,16,0,8"/>
  </Style>
  <Style x:Key="Md.H4" TargetType="Paragraph" BasedOn="{StaticResource Md.H2}">
    <Setter Property="FontSize" Value="{DynamicResource F.H2}"/>
    <Setter Property="Margin" Value="0,16,0,4"/>
  </Style>
  <Style x:Key="Md.H5" TargetType="Paragraph" BasedOn="{StaticResource Md.H4}">
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
  </Style>
  <Style x:Key="Md.H6" TargetType="Paragraph" BasedOn="{StaticResource Md.H5}">
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Md.List" TargetType="List">
    <Setter Property="Margin" Value="0,0,0,12"/>
    <Setter Property="Padding" Value="24,0,0,0"/>
  </Style>
  <Style x:Key="Md.ListNested" TargetType="List" BasedOn="{StaticResource Md.List}">
    <Setter Property="Margin" Value="0,4,0,0"/>
  </Style>
  <Style x:Key="Md.ListItem" TargetType="ListItem">
    <Setter Property="Margin" Value="0,0,0,4"/>
  </Style>
  <Style x:Key="Md.Quote" TargetType="Section">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Md.QuoteBar}"/>
    <Setter Property="BorderThickness" Value="3,0,0,0"/>
    <Setter Property="Padding" Value="16,4,0,4"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Md.Callout" TargetType="Section">
    <Setter Property="BorderThickness" Value="3,0,0,0"/>
    <Setter Property="Padding" Value="16,12,16,12"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.CalloutTitle" TargetType="Paragraph">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Margin" Value="0,0,0,8"/>
  </Style>
  <Style x:Key="Md.FoldLink" TargetType="Hyperlink">
    <Setter Property="TextDecorations" Value="{x:Null}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="TextDecorations" Value="Underline"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Md.CodeBlock" TargetType="Section">
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Padding" Value="12,0,8,12"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.CodeHead" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0"/>
  </Style>
  <Style x:Key="Md.CodeText" TargetType="Paragraph">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Code}"/>
    <Setter Property="LineHeight" Value="Auto"/>
    <Setter Property="Margin" Value="0"/>
  </Style>
  <Style x:Key="Md.CodeNote" TargetType="Paragraph">
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Warn}"/>
    <Setter Property="Margin" Value="0,0,0,8"/>
  </Style>
  <Style x:Key="Md.InlineCode" TargetType="Run">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Code}"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
  </Style>
  <Style x:Key="Md.Math" TargetType="Paragraph">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
    <Setter Property="TextAlignment" Value="Center"/>
  </Style>
  <Style x:Key="Md.Mark" TargetType="Span">
    <Setter Property="Background" Value="{DynamicResource B.Md.Mark}"/>
  </Style>
  <Style x:Key="Md.Sup" TargetType="Span">
    <Setter Property="BaselineAlignment" Value="Superscript"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
  </Style>
  <Style x:Key="Md.Sub" TargetType="Span">
    <Setter Property="BaselineAlignment" Value="Subscript"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
  </Style>
  <Style x:Key="Md.Tag" TargetType="Span">
    <Setter Property="Background" Value="{DynamicResource B.Chip}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.ChipText}"/>
  </Style>
  <Style x:Key="Md.Link" TargetType="Hyperlink">
    <Setter Property="Foreground" Value="{DynamicResource B.AccentStrong}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Foreground" Value="{DynamicResource B.AccentHover}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Md.TagLink" TargetType="Hyperlink" BasedOn="{StaticResource Md.Link}">
    <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
    <Setter Property="TextDecorations" Value="{x:Null}"/>
  </Style>
  <Style x:Key="Md.FnRef" TargetType="Hyperlink" BasedOn="{StaticResource Md.Link}">
    <Setter Property="BaselineAlignment" Value="Superscript"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="TextDecorations" Value="{x:Null}"/>
  </Style>
  <Style x:Key="Md.TaskLink" TargetType="Hyperlink">
    <Setter Property="TextDecorations" Value="{x:Null}"/>
    <Setter Property="Cursor" Value="Hand"/>
    <Style.Triggers>
      <Trigger Property="IsMouseOver" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.Hover}"/>
      </Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Md.Hr" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0,8,0,20"/>
  </Style>
  <Style x:Key="Md.Figure" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.FigureTight" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0"/>
  </Style>
  <Style x:Key="Md.FigureBox" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="8"/>
    <Setter Property="Padding" Value="12,0,8,16"/>
  </Style>
  <Style x:Key="Md.Table" TargetType="Table">
    <Setter Property="CellSpacing" Value="0"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <Style x:Key="Md.Td" TargetType="TableCell">
    <Setter Property="Padding" Value="12,6"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
  </Style>
  <Style x:Key="Md.Th" TargetType="TableCell" BasedOn="{StaticResource Md.Td}">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
  </Style>
  <Style x:Key="Md.Props" TargetType="Table" BasedOn="{StaticResource Md.Table}">
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="Margin" Value="0,0,0,16"/>
  </Style>
  <Style x:Key="Md.PropKey" TargetType="TableCell">
    <Setter Property="Padding" Value="12,4"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Md.PropValue" TargetType="TableCell">
    <Setter Property="Padding" Value="12,4"/>
  </Style>
  <Style x:Key="Md.Footnotes" TargetType="Section">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,1,0,0"/>
    <Setter Property="Padding" Value="0,12,0,0"/>
    <Setter Property="Margin" Value="0,12,0,0"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Small}"/>
    <Setter Property="LineHeight" Value="Auto"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <!-- 그리면 보이지 않는 줄(링크 정의 · 주석)을 편집 화면에서 원문 그대로 흐리게 -->
  <Style x:Key="Md.Raw" TargetType="Paragraph">
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>

  <!-- 메모 실시간 편집: 고치는 블록 자리에 들어가는 원문 입력칸(섬). 그린 글과 같은 글꼴 · 줄 높이 -->
  <Style x:Key="Memo.Island" TargetType="TextBox">
    <Setter Property="Background" Value="Transparent"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="0"/>
    <Setter Property="Margin" Value="0"/>
    <Setter Property="FontFamily" Value="{DynamicResource Font.UI}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="CaretBrush" Value="{DynamicResource B.Text}"/>
    <Setter Property="TextBlock.LineHeight" Value="{DynamicResource F.BodyLine}"/>
    <Setter Property="TextBlock.LineStackingStrategy" Value="BlockLineHeight"/>
    <Setter Property="TextWrapping" Value="Wrap"/>
    <Setter Property="AcceptsReturn" Value="True"/>
    <Setter Property="AcceptsTab" Value="True"/>
    <Setter Property="VerticalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/>
  </Style>
  <Style x:Key="Memo.IslandH1" TargetType="TextBox" BasedOn="{StaticResource Memo.Island}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH1}"/>
    <Setter Property="FontWeight" Value="Bold"/>
    <Setter Property="TextBlock.LineHeight" Value="Auto"/>
  </Style>
  <Style x:Key="Memo.IslandH2" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH1}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH2}"/>
    <Setter Property="FontWeight" Value="SemiBold"/>
  </Style>
  <Style x:Key="Memo.IslandH3" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH2}">
    <Setter Property="FontSize" Value="{DynamicResource F.MdH3}"/>
  </Style>
  <Style x:Key="Memo.IslandH4" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH2}">
    <Setter Property="FontSize" Value="{DynamicResource F.H2}"/>
  </Style>
  <Style x:Key="Memo.IslandH5" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH4}">
    <Setter Property="FontSize" Value="{DynamicResource F.Body}"/>
  </Style>
  <Style x:Key="Memo.IslandH6" TargetType="TextBox" BasedOn="{StaticResource Memo.IslandH5}">
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
  </Style>
  <Style x:Key="Memo.IslandCode" TargetType="TextBox" BasedOn="{StaticResource Memo.Island}">
    <Setter Property="FontFamily" Value="{DynamicResource Font.Mono}"/>
    <Setter Property="FontSize" Value="{DynamicResource F.Code}"/>
    <Setter Property="TextBlock.LineHeight" Value="Auto"/>
    <Setter Property="Background" Value="{DynamicResource B.Code.Bg}"/>
    <Setter Property="Padding" Value="12,8"/>
  </Style>
  <!-- 섬을 담는 블록: 그린 문단과 같은 아래 여백 -->
  <Style x:Key="Memo.IslandBox" TargetType="BlockUIContainer">
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>
  <!-- [[ 자동 완성 팝업: 떠 있는 패널(모서리 8 · 테두리). 항목은 포커스를 받지 않는다(입력칸에 커서를 둔 채 고름) -->
  <Style x:Key="Memo.Suggest" TargetType="Border">
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="CornerRadius" Value="8"/>
    <Setter Property="Padding" Value="4"/>
    <Setter Property="MinWidth" Value="240"/>
    <Setter Property="MaxWidth" Value="400"/>
  </Style>
  <Style x:Key="Memo.SuggestRow" TargetType="ListBoxItem" BasedOn="{StaticResource Row}">
    <Setter Property="Padding" Value="8,6"/>
    <Setter Property="Margin" Value="0"/>
    <Setter Property="Focusable" Value="False"/>
  </Style>
  <DataTemplate x:Key="Memo.SuggestItem">
    <TextBlock Text="{Binding}" Style="{DynamicResource T.Body}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
  </DataTemplate>
  <Style x:Key="Memo.SuggestList" TargetType="ListBox" BasedOn="{StaticResource List}">
    <Setter Property="ItemContainerStyle" Value="{StaticResource Memo.SuggestRow}"/>
    <Setter Property="ItemTemplate" Value="{StaticResource Memo.SuggestItem}"/>
    <Setter Property="MaxHeight" Value="240"/>
  </Style>
  <!-- 편집기 위 찾기 · 바꾸기 막대 -->
  <Style x:Key="Memo.FindBar" TargetType="Border">
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
    <Setter Property="Padding" Value="0,0,0,8"/>
    <Setter Property="Margin" Value="0,0,0,12"/>
  </Style>

  <Style x:Key="Task.Check" TargetType="CheckBox">
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="HorizontalAlignment" Value="Stretch"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
      <Border x:Name="HitArea" Padding="{TemplateBinding Padding}" Background="Transparent">
        <Border x:Name="Box" Width="16" Height="16" HorizontalAlignment="Left" VerticalAlignment="Center"
          CornerRadius="4" Background="{DynamicResource B.Card}" BorderBrush="{DynamicResource B.InputBorder}" BorderThickness="1">
          <Grid>
            <Path x:Name="Mark" Data="M 2,7 L 6,11 L 12,3" Stroke="{DynamicResource B.OnAccent}" StrokeThickness="2" Visibility="Collapsed"/>
            <Border x:Name="Dash" Width="8" Height="2" Background="{DynamicResource B.OnAccent}" Visibility="Collapsed"/>
          </Grid>
        </Border>
      </Border>
      <ControlTemplate.Triggers>
        <Trigger Property="IsChecked" Value="True"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Mark" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsChecked" Value="{x:Null}"><Setter TargetName="Box" Property="Background" Value="{DynamicResource B.Accent}"/><Setter TargetName="Dash" Property="Visibility" Value="Visible"/></Trigger>
        <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="HitArea" Property="Background" Value="{DynamicResource B.Hover}"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter TargetName="HitArea" Property="Background" Value="{DynamicResource B.AccentSoft}"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Box" Property="BorderBrush" Value="{DynamicResource B.Text}"/><Setter TargetName="Box" Property="BorderThickness" Value="2"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
      </ControlTemplate.Triggers>
    </ControlTemplate></Setter.Value></Setter>
  </Style>
  <Style x:Key="Task.Row" TargetType="DataGridRow">
    <Setter Property="MinHeight" Value="32"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="BorderThickness" Value="3,0,0,0"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Style.Triggers>
      <DataTrigger Binding="{Binding Selected}" Value="True">
        <Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/>
      </DataTrigger>
      <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="{DynamicResource B.Hover}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Task.Cell" TargetType="DataGridCell">
    <Setter Property="Padding" Value="12,4"/>
    <Setter Property="BorderThickness" Value="1"/>
    <Setter Property="BorderBrush" Value="Transparent"/>
    <Setter Property="Foreground" Value="{DynamicResource B.Text}"/>
    <Setter Property="Background" Value="Transparent"/>
    <Style.Triggers>
      <Trigger Property="IsKeyboardFocusWithin" Value="True"><Setter Property="BorderBrush" Value="{DynamicResource B.Accent}"/></Trigger>
      <Trigger Property="IsSelected" Value="True"><Setter Property="Background" Value="{DynamicResource B.AccentSoft}"/></Trigger>
    </Style.Triggers>
  </Style>
  <Style x:Key="Task.Header" TargetType="DataGridColumnHeader">
    <Setter Property="FontWeight" Value="SemiBold"/>
    <Setter Property="Padding" Value="12,8"/>
    <Setter Property="Background" Value="{DynamicResource B.Card}"/>
    <Setter Property="Foreground" Value="{DynamicResource B.SubText}"/>
    <Setter Property="BorderBrush" Value="{DynamicResource B.Border}"/>
    <Setter Property="BorderThickness" Value="0,0,0,1"/>
  </Style>
  <Style x:Key="Task.Text" TargetType="TextBlock" BasedOn="{StaticResource T.Body}">
    <Setter Property="TextWrapping" Value="NoWrap"/>
    <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    <Setter Property="VerticalAlignment" Value="Center"/>
    <Setter Property="ToolTip" Value="{Binding RelativeSource={RelativeSource Self}, Path=Text}"/>
  </Style>
</ResourceDictionary>
'@

$script:styles = $null

# 스타일 사전 (처음 부를 때 한 번 만든다)
function Get-WtStyleDictionary {
    if (-not $script:styles) {
        $script:styles = [System.Windows.Markup.XamlReader]::Parse($script:stylesXaml.Replace('{NS}', $script:ns))
    }
    $script:styles
}

# XAML 문자열을 요소로 만든다. 맨 앞 태그에 {NS}를 쓰면 기본 이름공간으로 바뀐다.
function ConvertFrom-WtXaml([string]$Xaml) {
    [System.Windows.Markup.XamlReader]::Parse($Xaml.Replace('{NS}', $script:ns))
}

# x:Name을 붙인 요소들을 이름 → 요소 사전으로 돌려준다
function Get-WtNamedElements($Root, [string]$Xaml) {
    $map = @{}
    foreach ($m in [regex]::Matches($Xaml, 'x:Name="([A-Za-z0-9_]+)"')) {
        $name = $m.Groups[1].Value
        $map[$name] = $Root.FindName($name)
    }
    $map
}

function Set-WtStyle($Element, [string]$Key) {
    $Element.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, $Key)
}

# 의존 속성에 테마 리소스를 건다. 예: Set-WtBrush $tb 'Foreground' 'B.SubText'
function Set-WtResource($Element, [string]$Property, [string]$Key) {
    $field = $Element.GetType().GetField("${Property}Property",
        [System.Reflection.BindingFlags]'Public, Static, FlattenHierarchy')
    if (-not $field) { throw "$($Element.GetType().Name)에 $Property 속성이 없습니다." }
    $Element.SetResourceReference($field.GetValue($null), $Key)
}

function New-WtText([string]$Text, [string]$Style = 'T.Body') {
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text
    Set-WtStyle $t $Style
    $t
}

# 아이콘 글꼴(Segoe Fluent Icons / MDL2)의 글자 하나
function New-WtIcon([int]$Code) {
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = [string][char]$Code
    Set-WtStyle $t 'T.Icon'
    $t
}

function New-WtStack([ValidateSet('Vertical', 'Horizontal')][string]$Orientation = 'Vertical', [double]$Gap = 0) {
    $p = [System.Windows.Controls.StackPanel]::new()
    $p.Orientation = $Orientation
    $p.Tag = $Gap
    $p
}

# 쌓기 패널에 요소를 넣는다. 패널 Tag의 간격만큼 앞에 여백을 둔다.
function Add-WtChild($Panel, $Child) {
    $gap = if ($Panel.Tag -is [double]) { [double]$Panel.Tag } else { 0 }
    if ($Panel.Children.Count -gt 0 -and $gap -gt 0 -and $Child -is [System.Windows.FrameworkElement]) {
        $m = $Child.Margin
        if ($Panel.Orientation -eq 'Horizontal') {
            $Child.Margin = [System.Windows.Thickness]::new($m.Left + $gap, $m.Top, $m.Right, $m.Bottom)
        } else {
            $Child.Margin = [System.Windows.Thickness]::new($m.Left, $m.Top + $gap, $m.Right, $m.Bottom)
        }
    }
    [void]$Panel.Children.Add($Child)
    $Child
}

function New-WtCard {
    $b = [System.Windows.Controls.Border]::new()
    Set-WtStyle $b 'Card'
    $b
}

# 카드 머리: 제목(+ 개수) 왼쪽, 오른쪽에 링크 버튼 하나 (선택)
function New-WtCardHeader([string]$Title, [string]$Count, [string]$LinkText, [string]$LinkPage) {
    $g = [System.Windows.Controls.DockPanel]::new()
    $g.LastChildFill = $true
    $g.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    if ($LinkText) {
        $b = New-WtButton $LinkText -Kind Link
        $b.Tag = $LinkPage
        $b.Add_Click({ param($s, $e) Select-WtPage $s.Tag })
        [System.Windows.Controls.DockPanel]::SetDock($b, 'Right')
        [void]$g.Children.Add($b)
    }
    # PowerShell 변수는 대소문자를 가리지 않는다: $title로 쓰면 [string]$Title에 들어가 글자로 바뀐다
    $head = New-WtText $Title 'T.H2'
    if ($Count) {
        $run = [System.Windows.Documents.Run]::new("  $Count")
        $run.FontWeight = 'Normal'
        $run.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'B.SubText')
        $head.Inlines.Add($run)
    }
    $head.VerticalAlignment = 'Center'
    [void]$g.Children.Add($head)
    $g
}

# 버튼. $Kind: Default · Primary · Danger · Icon · Link
function New-WtButton([string]$Text, [string]$Kind = 'Default', [int]$Icon = 0, [string]$ToolTip) {
    $b = [System.Windows.Controls.Button]::new()
    switch ($Kind) {
        'Primary' { Set-WtStyle $b 'Btn.Primary' }
        'Danger' { Set-WtStyle $b 'Btn.Danger' }
        'Icon' { Set-WtStyle $b 'Btn.Icon' }
        'Link' { Set-WtStyle $b 'Btn.Link' }
        default { Set-WtStyle $b 'Btn' }
    }
    $b.Content = New-WtButtonContent $Text $Icon
    if ($ToolTip) { $b.ToolTip = $ToolTip }
    $b
}

# 버튼 안 내용: 아이콘 + 글자 (둘 중 하나만 있어도 됨). 누른 뒤 글자를 바꿀 때도 쓴다 (예: 복사 → 복사됨)
function New-WtButtonContent([string]$Text, [int]$Icon = 0) {
    if ($Icon -and $Text) {
        $row = New-WtStack Horizontal 8
        [void](Add-WtChild $row (New-WtIcon $Icon))
        $label = [System.Windows.Controls.TextBlock]::new()
        $label.Text = $Text
        $label.VerticalAlignment = 'Center'
        [void](Add-WtChild $row $label)
        return $row
    }
    if ($Icon) { return New-WtIcon $Icon }
    $Text
}

# 나눔 버튼: 여러 개 중 하나를 고르는 버튼 묶음 (예: 미리보기 | 원문, 작게 | 보통 | 크게)
# $Options: @(@('값', '글'), ...). 고르면 & $OnChange '값'. $Group은 화면 안에서 겹치지 않는 이름
function New-WtSegmented([object[]]$Options, [string]$Selected, [string]$Group, [scriptblock]$OnChange) {
    $box = [System.Windows.Controls.Border]::new()
    Set-WtResource $box 'Background' 'B.Chip'
    $box.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $box.Padding = [System.Windows.Thickness]::new(4)
    $box.HorizontalAlignment = 'Left'
    $row = New-WtStack Horizontal 4
    foreach ($o in $Options) {
        $rb = [System.Windows.Controls.RadioButton]::new()
        Set-WtStyle $rb 'Seg'
        $rb.GroupName = $Group
        $rb.Content = $o[1]
        $rb.Tag = @{ Value = $o[0]; OnChange = $OnChange }
        $rb.IsChecked = ($o[0] -eq $Selected)
        $rb.Add_Checked({ param($s, $e) & $s.Tag.OnChange $s.Tag.Value })
        [void](Add-WtChild $row $rb)
    }
    $box.Child = $row
    $box
}

# 검색 칸: 돋보기 + 비어 있을 때 안내 글. @{ Root = 화면에 넣을 요소; Box = TextBox } 를 돌려준다
function New-WtSearchBox([string]$Hint = '검색') {
    $g = [System.Windows.Controls.Grid]::new()
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Input'
    $box.Padding = [System.Windows.Thickness]::new(36, 8, 10, 8)
    $icon = New-WtIcon 0xE721
    Set-WtResource $icon 'Foreground' 'B.SubText'
    $icon.HorizontalAlignment = 'Left'
    $icon.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $icon.IsHitTestVisible = $false
    $hintText = New-WtText $Hint 'T.Sub'   # $hint로 쓰면 [string]$Hint와 같은 변수가 된다
    $hintText.VerticalAlignment = 'Center'
    $hintText.Margin = [System.Windows.Thickness]::new(38, 0, 0, 0)
    $hintText.IsHitTestVisible = $false
    $box.Tag = $hintText
    $box.Add_TextChanged({ param($s, $e) $s.Tag.Visibility = if ($s.Text) { 'Collapsed' } else { 'Visible' } })
    [void]$g.Children.Add($box)
    [void]$g.Children.Add($icon)
    [void]$g.Children.Add($hintText)
    @{ Root = $g; Box = $box }
}

# 작은 알약 모양 표시. $Bg/$Fg는 테마 리소스 이름 (예: 'Att.WorkBg', 'Att.Work')
function New-WtTag([string]$Text, [string]$Bg = 'Chip', [string]$Fg = 'ChipText', [int]$Icon = 0) {
    $b = [System.Windows.Controls.Border]::new()
    $b.CornerRadius = [System.Windows.CornerRadius]::new(12)
    $b.Padding = [System.Windows.Thickness]::new(9, 2, 9, 3)
    $b.VerticalAlignment = 'Center'
    $b.HorizontalAlignment = 'Left'
    Set-WtResource $b 'Background' "B.$Bg"
    $row = New-WtStack Horizontal 4
    if ($Icon) {
        $i = New-WtIcon $Icon
        Set-WtResource $i 'FontSize' 'F.Small'
        Set-WtResource $i 'Foreground' "B.$Fg"
        [void](Add-WtChild $row $i)
    }
    $t = New-WtText $Text 'T.Sub'
    Set-WtResource $t 'Foreground' "B.$Fg"
    $t.FontWeight = 'SemiBold'
    $t.TextWrapping = 'NoWrap'
    [void](Add-WtChild $row $t)
    $b.Child = $row
    $b
}

# 숫자 칸: 이름(점 색) + 큰 숫자 + 단위
function New-WtStatTile([string]$Label, [string]$Value, [string]$Unit, [string]$DotKey = 'Accent') {
    $tile = [System.Windows.Controls.Border]::new()
    Set-WtStyle $tile 'Tile'
    $col = New-WtStack Vertical 2
    $head = New-WtStack Horizontal 6
    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8; $dot.Height = 8
    $dot.VerticalAlignment = 'Center'
    Set-WtResource $dot 'Fill' "B.$DotKey"
    [void](Add-WtChild $head $dot)
    [void](Add-WtChild $head (New-WtText $Label 'T.Sub'))
    [void](Add-WtChild $col $head)
    $num = New-WtText $Value 'T.Number'
    $run = [System.Windows.Documents.Run]::new(" $Unit")
    $run.SetResourceReference([System.Windows.Documents.TextElement]::FontSizeProperty, 'F.Small')
    $run.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, 'B.SubText')
    $run.FontWeight = 'Normal'
    $num.Inlines.Add($run)
    [void](Add-WtChild $col $num)
    $tile.Child = $col
    $tile
}

# 화면 맨 위: 작은 설명(선택) + 큰 제목 + 오른쪽 요소(선택)
function New-WtPageHeader([string]$Title, [string]$Sub, $Right) {
    $d = [System.Windows.Controls.DockPanel]::new()
    $d.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)
    if ($Right) {
        [System.Windows.Controls.DockPanel]::SetDock($Right, 'Right')
        $Right.VerticalAlignment = 'Bottom'
        [void]$d.Children.Add($Right)
    }
    $col = New-WtStack Vertical 4
    if ($Sub) { [void](Add-WtChild $col (New-WtText $Sub 'T.Sub')) }
    [void](Add-WtChild $col (New-WtText $Title 'T.Title'))
    [void]$d.Children.Add($col)
    $d
}

# 화면 하나의 바깥 틀: 스크롤 + 안쪽 여백. 돌려준 패널에 내용을 넣는다.
# -Fill: 바깥 스크롤 없이 창 높이를 채운다. 목록 · 본문처럼 스스로 스크롤하는 요소가 있는 화면에 쓴다.
#        돌려준 DockPanel에 머리글을 Top으로 붙이고, 마지막에 넣은 요소가 남는 공간을 채운다.
function New-WtPage([switch]$Fill) {
    if ($Fill) {
        $dock = [System.Windows.Controls.DockPanel]::new()
        $dock.LastChildFill = $true
        $dock.Margin = [System.Windows.Thickness]::new(36, 8, 36, 32)
        return @{ Root = $dock; Panel = $dock }
    }
    $sv = [System.Windows.Controls.ScrollViewer]::new()
    $sv.VerticalScrollBarVisibility = 'Auto'
    $sv.HorizontalScrollBarVisibility = 'Disabled'
    $sv.Focusable = $false
    $panel = New-WtStack Vertical 16
    $panel.Margin = [System.Windows.Thickness]::new(36, 8, 36, 32)
    $sv.Content = $panel
    @{ Root = $sv; Panel = $panel }
}

# 카드 안 한 줄: 구분선 위에 왼쪽부터 요소들을 차례로 놓는다. 마지막 요소가 남는 폭을 채운다.
function New-WtListRow([object[]]$Parts, [double]$Gap = 14) {
    $b = [System.Windows.Controls.Border]::new()
    Set-WtStyle $b 'Divider'
    $b.Padding = [System.Windows.Thickness]::new(0, 10, 0, 10)
    $d = [System.Windows.Controls.DockPanel]::new()
    $d.LastChildFill = $true
    for ($i = 0; $i -lt $Parts.Count; $i++) {
        $p = $Parts[$i]
        if ($null -eq $p) { continue }
        if ($i -lt $Parts.Count - 1) {
            [System.Windows.Controls.DockPanel]::SetDock($p, 'Left')
            $p.Margin = [System.Windows.Thickness]::new(0, 0, $Gap, 0)
        }
        $p.VerticalAlignment = 'Center'
        [void]$d.Children.Add($p)
    }
    $b.Child = $d
    $b
}

$script:ko = [System.Globalization.CultureInfo]::GetCultureInfo('ko-KR')

# 날짜를 한국어로. 예: Format-WtDate (Get-Date) 'M월 d일 dddd' → 10월 22일 목요일
function Format-WtDate([datetime]$Date, [string]$Format) { $Date.ToString($Format, $script:ko) }

function Show-WtMessage([string]$Text, [string]$Title = 'WorkTool', [string]$Icon = 'Information') {
    [void][System.Windows.MessageBox]::Show($Text, $Title, 'OK', $Icon)
}

function Confirm-WtYesNo([string]$Text, [string]$Title = 'WorkTool') {
    [System.Windows.MessageBox]::Show($Text, $Title, 'YesNo', 'Question') -eq 'Yes'
}

# 오류를 사용자에게 보여 준다. 문구는 그대로 복사해서 알려 줄 수 있게 한다.
function Show-WtError($ErrorRecord, [string]$Where = '') {
    $msg = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $pos = if ($ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.PositionMessage } else { '' }
        "$($ErrorRecord.Exception.Message)`n`n위치: $pos"
    } elseif ($ErrorRecord -is [System.Exception]) {
        "$($ErrorRecord.Message)`n`n$($ErrorRecord.StackTrace)"
    } else { [string]$ErrorRecord }
    if ($Where) { $msg = "[$Where]`n$msg" }
    try { Show-WtMessage $msg 'WorkTool 오류' 'Error' } catch { Write-Host $msg }
}

function New-WtTaskGrid {
    $grid = ConvertFrom-WtXaml @'
<DataGrid {NS} AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False" CanUserDeleteRows="False"
  HeadersVisibility="Column" SelectionMode="Single" SelectionUnit="FullRow" BorderThickness="0"
  Background="{DynamicResource B.Card}" Foreground="{DynamicResource B.Text}"
  FontFamily="{DynamicResource Font.UI}" FontSize="{DynamicResource F.Body}"
  RowStyle="{DynamicResource Task.Row}" CellStyle="{DynamicResource Task.Cell}" ColumnHeaderStyle="{DynamicResource Task.Header}"
  GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="{DynamicResource B.Divider}"
  EnableRowVirtualization="True" EnableColumnVirtualization="True"
  VirtualizingPanel.IsVirtualizingWhenGrouping="True" VirtualizingPanel.VirtualizationMode="Recycling" ScrollViewer.CanContentScroll="True">
  <DataGrid.Columns>
    <DataGridTemplateColumn Header="선택" Width="48" CanUserSort="False">
      <DataGridTemplateColumn.CellTemplate><DataTemplate>
        <CheckBox Tag="task" Style="{DynamicResource Task.Check}" IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
          IsEnabled="{Binding CanClose}" ToolTip="{Binding CloseHint}" AutomationProperties.Name="{Binding DisplayTitle}"/>
      </DataTemplate></DataGridTemplateColumn.CellTemplate>
    </DataGridTemplateColumn>
    <DataGridTextColumn Header="이름" Binding="{Binding DisplayTitle}" SortMemberPath="DisplayTitle" Width="*" MinWidth="200" ElementStyle="{DynamicResource Task.Text}"/>
    <DataGridTextColumn Header="종류" Binding="{Binding KindLabel}" SortMemberPath="KindLabel" Width="80" ElementStyle="{DynamicResource Task.Text}"/>
    <DataGridTextColumn Header="창" Binding="{Binding WindowLabel}" SortMemberPath="WindowNumber" Width="96" ElementStyle="{DynamicResource Task.Text}"/>
    <DataGridTextColumn Header="상태" Binding="{Binding Status}" SortMemberPath="Status" Width="240" ElementStyle="{DynamicResource Task.Text}"/>
  </DataGrid.Columns>
  <DataGrid.GroupStyle><GroupStyle>
    <GroupStyle.ContainerStyle><Style TargetType="GroupItem"><Setter Property="Template"><Setter.Value>
      <ControlTemplate TargetType="GroupItem">
        <Expander Tag="task-group" IsExpanded="True" Background="{DynamicResource B.Sidebar}" Foreground="{DynamicResource B.Text}">
          <Expander.Header><StackPanel Orientation="Horizontal">
            <CheckBox Tag="group" IsThreeState="True" Style="{DynamicResource Task.Check}" AutomationProperties.Name="{Binding Name}"/>
            <TextBlock Text="{Binding Name}" Style="{DynamicResource T.Strong}" VerticalAlignment="Center"/>
            <TextBlock Text="{Binding ItemCount}" Style="{DynamicResource T.Sub}" Margin="16,0,4,0" VerticalAlignment="Center"/>
            <TextBlock Text="개 표시" Style="{DynamicResource T.Sub}" VerticalAlignment="Center"/>
          </StackPanel></Expander.Header>
          <ItemsPresenter/>
        </Expander>
      </ControlTemplate>
    </Setter.Value></Setter></Style></GroupStyle.ContainerStyle>
  </GroupStyle></DataGrid.GroupStyle>
</DataGrid>
'@
    # 그룹 행의 ItemsPresenter가 무한 폭으로 측정돼도 이름 열이 남는 폭을 채운다.
    $grid.Add_SizeChanged({ param($s, $e) $s.Columns[1].Width = [System.Windows.Controls.DataGridLength]::new([Math]::Max(200, $s.ActualWidth - 48 - 80 - 96 - 240 - 24)) })
    $grid
}

function New-WtTaskPage {
    $page = New-WtPage -Fill
    $page.Root.Margin = [System.Windows.Thickness]::new(24, 8, 24, 24)
    $page
}

# 대화상자 모양은 여기에서만 정한다. 호출자는 본문/버튼과 처리기만 붙인다.
function New-WtModal([string]$Title) {
    $w = [System.Windows.Window]::new()
    $w.Title = $Title; $w.Width = 480; $w.SizeToContent = 'Height'; $w.ResizeMode = 'NoResize'
    $w.WindowStyle = 'ToolWindow'; $w.ShowInTaskbar = $false; $w.WindowStartupLocation = 'CenterOwner'
    $owner = Get-WtWindow
    if ($owner -and $owner.IsVisible) { $w.Owner = $owner; $w.Resources.MergedDictionaries.Add($owner.Resources) }
    else { $w.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $w.Resources.MergedDictionaries.Add((Get-WtStyleDictionary)) }
    Set-WtResource $w Background 'B.Card'; Set-WtResource $w Foreground 'B.Text'; Set-WtResource $w FontFamily 'Font.UI'
    $body = New-WtStack Vertical 12; $body.Margin = [System.Windows.Thickness]::new(24)
    $heading = New-WtText $Title 'T.Dialog'
    [void](Add-WtChild $body $heading)
    $content = New-WtStack Vertical 8; [void](Add-WtChild $body $content)
    $errorText = New-WtText '' 'T.Sub'; Set-WtResource $errorText Foreground 'B.Danger'
    $errorText.Visibility = 'Collapsed'; [void](Add-WtChild $body $errorText)
    $buttons = New-WtStack Horizontal 8; $buttons.HorizontalAlignment = 'Right'
    $buttons.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0); [void](Add-WtChild $body $buttons)
    $w.Content = $body
    @{ Window = $w; Body = $content; Error = $errorText; Buttons = $buttons }
}

function New-WtMinuteInput([int]$Value) {
    $row = New-WtStack Horizontal 12
    $box = [System.Windows.Controls.TextBox]::new(); Set-WtStyle $box 'Input'
    $box.Width = 160; $box.Text = [string]$Value
    [System.Windows.Automation.AutomationProperties]::SetName($box, '새로 고침 간격 (분)')
    [void](Add-WtChild $row $box)
    $unit = New-WtText '분'; $unit.VerticalAlignment = 'Center'; [void](Add-WtChild $row $unit)
    @{ Root = $row; Box = $box }
}

function New-WtPollTimer([scriptblock]$Tick) {
    $timer = [System.Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick($Tick)
    $timer
}

function Get-WtUiWorkBudget { @{ Milliseconds = 16; Items = 32 } }

function New-WtContextMenu {
    $menu = [System.Windows.Controls.ContextMenu]::new()
    Set-WtResource $menu Background 'B.Card'; Set-WtResource $menu Foreground 'B.Text'
    Set-WtResource $menu FontFamily 'Font.UI'; Set-WtResource $menu FontSize 'F.Body'
    $menu
}

function Get-WtVisualChild($Root, [type]$Type) {
    if ($Root -is $Type) { return $Root }
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root); $i++) {
        $found = Get-WtVisualChild ([System.Windows.Media.VisualTreeHelper]::GetChild($Root, $i)) $Type
        if ($found) { return $found }
    }
    $null
}

Export-ModuleMember -Function Get-WtUiWorkBudget, New-WtPollTimer, New-WtTaskGrid, New-WtTaskPage, New-WtModal, New-WtMinuteInput, New-WtContextMenu, Get-WtVisualChild,
    Get-WtStyleDictionary, ConvertFrom-WtXaml, Get-WtNamedElements, Set-WtStyle, Set-WtResource,
    New-WtText, New-WtIcon, New-WtStack, Add-WtChild, New-WtCard, New-WtCardHeader, New-WtButton, New-WtButtonContent, New-WtSegmented, New-WtSearchBox, New-WtTag,
    New-WtStatTile, New-WtPageHeader, New-WtPage, New-WtListRow, Format-WtDate, Show-WtMessage, Confirm-WtYesNo, Show-WtError
} | Import-Module -Force -DisableNameChecking
# ---- core\Ui.psm1 끝 ----

# ---- core\Highlight.psm1 ----
New-Module -Name 'WorkTool.Highlight' -ScriptBlock {
# 코드 색칠. 마크다운 코드 블록 등에서 쓴다. WPF 없이 동작한다 (글을 조각 목록으로 나누기만 한다).
# 언어 하나 = 규칙 목록 하나 (Register-WtCodeLanguage). 새 언어는 이 파일 아래쪽 목록에 하나 더 등록하면 된다.
#
# 규칙: @{ Kind = '색 이름'; Pattern = '정규식' } 또는 @{ Kind = …; Words = '낱말 낱말 …' }
# - 같은 자리에서는 위에 있는 규칙이 먼저다. 주석 · 문자열을 맨 위에 둔다.
# - Kind는 Theme.psm1의 Code.* 색 이름이다: Comment · String · Keyword · Number · Command · Variable · Type · Attr · Inserted · Deleted
# - 정규식은 여러 줄 모드(^ $가 줄 단위)다. 규칙 안에서는 이름 붙은 그룹을 쓰지 않는다.

$ErrorActionPreference = 'Stop'

$script:languages = @{}   # 이름 → @{ Name; Regex; Kinds }
$script:aliases = @{}     # 별칭 → 이름

function Register-WtCodeLanguage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Aliases = @(),
        [Parameter(Mandatory)][object[]]$Rules,
        [switch]$IgnoreCase
    )
    $parts = for ($i = 0; $i -lt $Rules.Count; $i++) {
        $r = $Rules[$i]
        $pattern = if ($r.Words) {
            $words = @($r.Words -split '\s+' | Where-Object { $_ } | ForEach-Object { [regex]::Escape($_) })
            '(?<![\w$-])(?:' + ($words -join '|') + ')(?![\w-])'
        } else { $r.Pattern }
        "(?<k$i>$pattern)"
    }
    $options = [System.Text.RegularExpressions.RegexOptions]'Multiline, CultureInvariant'
    if ($IgnoreCase) { $options = $options -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    $script:languages[$Name] = @{
        Name  = $Name
        Regex = [regex]::new(($parts -join '|'), $options)
        Kinds = @($Rules | ForEach-Object { $_.Kind })
    }
    foreach ($a in @($Name) + $Aliases) { $script:aliases[$a.ToLowerInvariant()] = $Name }
}

# 코드 블록 이름표(```powershell 의 powershell)로 언어를 찾는다. 없으면 $null
function Get-WtCodeLanguage([string]$Name) {
    if (-not $Name) { return $null }
    $key = $Name.Trim().ToLowerInvariant()
    if ($script:aliases.ContainsKey($key)) { return $script:aliases[$key] }
    $null
}

function Get-WtCodeLanguageNames { @($script:languages.Keys | Sort-Object) }

# 글을 @{ Kind; Text } 조각들로 나눈다. 색칠하지 않는 부분은 Kind가 ''다. 조각을 이으면 원래 글이 된다.
function Get-WtCodeTokens([string]$Code, [string]$Language) {
    $out = [System.Collections.Generic.List[object]]::new()
    if (-not $Code) { return }
    $name = Get-WtCodeLanguage $Language
    if (-not $name) { return @{ Kind = ''; Text = $Code } }
    $lang = $script:languages[$name]
    $pos = 0
    foreach ($m in $lang.Regex.Matches($Code)) {
        if ($m.Length -eq 0) { continue }
        if ($m.Index -gt $pos) { $out.Add(@{ Kind = ''; Text = $Code.Substring($pos, $m.Index - $pos) }) }
        $kind = ''
        for ($i = 0; $i -lt $lang.Kinds.Count; $i++) {
            if ($m.Groups["k$i"].Success) { $kind = $lang.Kinds[$i]; break }
        }
        $out.Add(@{ Kind = $kind; Text = $m.Value })
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Code.Length) { $out.Add(@{ Kind = ''; Text = $Code.Substring($pos) }) }
    $out.ToArray()
}

# ---- 언어 목록 ---------------------------------------------------------------------------------

$num = '\b(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\b'
$dq = '"(?:\\.|[^"\\\n])*"'
$sq = '''(?:\\.|[^''\\\n])*'''
$cBlock = '/\*[\s\S]*?(?:\*/|\z)'

Register-WtCodeLanguage -Name 'powershell' -Aliases 'ps1', 'ps', 'pwsh', 'posh', 'psm1' -IgnoreCase -Rules @(
    @{ Kind = 'Comment'; Pattern = '<#[\s\S]*?(?:#>|\z)|(?<![\w`])#.*' }
    @{ Kind = 'String'; Pattern = '@"[\s\S]*?^"@|@''[\s\S]*?^''@|"(?:`[\s\S]|""|[^"`])*"|''(?:''''|[^''])*''' }
    @{ Kind = 'Variable'; Pattern = '\$(?:\{[^}\n]*\}|(?:[A-Za-z]+:)?[\w?]+|\$|\^)' }
    @{ Kind = 'Type'; Pattern = '\[[A-Za-z][\w.]*(?:\[\])?(?:,\s*[\w.]+)*\](?!\s*\()' }
    @{ Kind = 'Command'; Pattern = '\b[A-Za-z]+-[A-Za-z][A-Za-z0-9]*\b' }
    @{ Kind = 'Keyword'; Pattern = '(?<![\w-])-(?:c|i)?(?:eq|ne|gt|ge|lt|le|like|notlike|match|notmatch|contains|notcontains|in|notin|replace|split)\b|(?<![\w-])-(?:and|or|not|xor|band|bor|bxor|bnot|shl|shr|is|isnot|as|join|f)\b' }
    @{ Kind = 'Keyword'; Words = 'begin break catch class clean continue data default do dynamicparam else elseif end enum exit filter finally for foreach function hidden if in param process return static switch throw trap try until using while' }
    @{ Kind = 'Attr'; Pattern = '(?<![\w-])-[A-Za-z][\w]*' }
    @{ Kind = 'Number'; Pattern = '\b\d+(?:\.\d+)?(?:[kmgtp]b)?\b|\b0x[0-9a-f]+\b' }
)

Register-WtCodeLanguage -Name 'bash' -Aliases 'sh', 'shell', 'zsh', 'console', 'shellscript' -Rules @(
    @{ Kind = 'Comment'; Pattern = '(?<=^|[ \t;])#.*' }
    @{ Kind = 'String'; Pattern = "$dq|'[^']*'" }
    @{ Kind = 'Variable'; Pattern = '\$(?:\{[^}\n]*\}|\w+|[@*#?$!0-9-])' }
    @{ Kind = 'Keyword'; Words = 'if then else elif fi for while until do done case esac function in return break continue local export readonly declare select time' }
    @{ Kind = 'Command'; Words = 'echo printf cd ls cat grep egrep sed awk find xargs sort uniq head tail wc cut tr tee sudo su chmod chown chgrp cp mv rm mkdir rmdir ln touch tar gzip gunzip zip unzip curl wget ssh scp rsync systemctl journalctl service kill killall ps top htop df du free mount umount lsblk blkid fdisk parted mkfs ip ifconfig ping traceroute ss netstat nmcli firewall-cmd iptables yum dnf apt apt-get rpm dpkg pip source set unset exit test read sleep date hostname uname whoami id useradd usermod passwd crontab nohup git docker kubectl podman vi vim nano less more which env alias' }
    @{ Kind = 'Attr'; Pattern = '(?<=\s)--?[A-Za-z][\w-]*' }
    @{ Kind = 'Number'; Pattern = '\b\d+(?:\.\d+)?\b' }
)

Register-WtCodeLanguage -Name 'python' -Aliases 'py', 'python3' -Rules @(
    @{ Kind = 'Comment'; Pattern = '#.*' }
    @{ Kind = 'String'; Pattern = '(?i:[rbfu]{0,2})(?:"""[\s\S]*?(?:"""|\z)|''''''[\s\S]*?(?:''''''|\z)|' + $dq + '|' + $sq + ')' }
    @{ Kind = 'Attr'; Pattern = '^[ \t]*@[\w.]+' }
    @{ Kind = 'Keyword'; Words = 'False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case' }
    @{ Kind = 'Command'; Pattern = '(?<=\b(?:def|class)\s+)\w+|\b(?:print|len|range|open|str|int|float|bool|list|dict|set|tuple|type|isinstance|enumerate|zip|map|filter|sorted|sum|min|max|abs|any|all|super|input|format|round|repr|getattr|setattr|hasattr)\b(?=\s*\()' }
    @{ Kind = 'Variable'; Words = 'self cls' }
    @{ Kind = 'Number'; Pattern = $num }
)

Register-WtCodeLanguage -Name 'javascript' -Aliases 'js', 'jsx', 'mjs', 'cjs', 'typescript', 'ts', 'tsx' -Rules @(
    @{ Kind = 'Comment'; Pattern = "//.*|$cBlock" }
    @{ Kind = 'String'; Pattern = "$dq|$sq|``(?:\\[\s\S]|[^``\\])*``" }
    @{ Kind = 'Keyword'; Words = 'break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new return super switch this throw try typeof var void while with yield async await of static get set interface type enum implements private public protected readonly as from null undefined true false' }
    @{ Kind = 'Type'; Pattern = '\b[A-Z][A-Za-z0-9_]*\b' }
    @{ Kind = 'Command'; Pattern = '\b[A-Za-z_$][\w$]*(?=\s*\()' }
    @{ Kind = 'Number'; Pattern = $num }
)

Register-WtCodeLanguage -Name 'json' -Aliases 'jsonc', 'json5' -Rules @(
    @{ Kind = 'Comment'; Pattern = "//.*|$cBlock" }
    @{ Kind = 'Attr'; Pattern = '"(?:\\.|[^"\\\n])*"(?=\s*:)' }
    @{ Kind = 'String'; Pattern = $dq }
    @{ Kind = 'Keyword'; Words = 'true false null' }
    @{ Kind = 'Number'; Pattern = '-?\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b' }
)

Register-WtCodeLanguage -Name 'yaml' -Aliases 'yml' -Rules @(
    @{ Kind = 'Comment'; Pattern = '(?<=^|\s)#.*' }
    @{ Kind = 'Attr'; Pattern = '(?<=^[ \t]*(?:-[ \t]+)?)[^\s#:''"\-][^:#\n]*?(?=[ \t]*:(?:[ \t]|$))' }
    @{ Kind = 'String'; Pattern = "$dq|'(?:''|[^'\n])*'" }
    @{ Kind = 'Type'; Pattern = '^(?:---|\.\.\.)[ \t]*$|!!?[\w/]+' }
    @{ Kind = 'Variable'; Pattern = '[&*][\w-]+' }
    @{ Kind = 'Keyword'; Pattern = '(?i)(?<=:[ \t]+|-[ \t]+|^)(?:true|false|null|yes|no|on|off|~)(?=[ \t]*(?:#|$))' }
    @{ Kind = 'Number'; Pattern = '(?<=:[ \t]+|-[ \t]+)-?\d+(?:\.\d+)?(?=[ \t]*(?:#|$))' }
)

Register-WtCodeLanguage -Name 'xml' -Aliases 'html', 'htm', 'xaml', 'svg', 'xhtml', 'plist' -IgnoreCase -Rules @(
    @{ Kind = 'Comment'; Pattern = '<!--[\s\S]*?(?:-->|\z)' }
    @{ Kind = 'Keyword'; Pattern = '<!\[CDATA\[|\]\]>|<!DOCTYPE[^>]*>|<\?[\s\S]*?\?>' }
    @{ Kind = 'Type'; Pattern = '(?<=</?)[\w:.-]+' }
    @{ Kind = 'String'; Pattern = '(?<==\s*)(?:"[^"]*"|''[^'']*'')' }
    @{ Kind = 'Attr'; Pattern = '(?<=<[^<>]*\s)[\w:.-]+(?=\s*=)' }
    @{ Kind = 'Variable'; Pattern = '&[#\w]+;' }
)

Register-WtCodeLanguage -Name 'sql' -Aliases 'mysql', 'tsql', 'plsql', 'postgresql', 'psql', 'sqlite' -IgnoreCase -Rules @(
    @{ Kind = 'Comment'; Pattern = "--.*|$cBlock" }
    @{ Kind = 'String'; Pattern = "'(?:''|[^'])*'" }
    @{ Kind = 'Type'; Words = 'int integer bigint smallint tinyint varchar nvarchar char nchar text ntext date datetime datetime2 time timestamp decimal numeric float real bit boolean money uniqueidentifier blob clob' }
    @{ Kind = 'Keyword'; Words = 'select from where and or not insert into values update set delete create alter drop truncate table index view database schema join left right inner outer full cross on group by order having limit offset top distinct as is null like in between exists case when then else end union all primary key foreign references default constraint unique check begin commit rollback transaction declare exec execute procedure function returns return if while grant revoke with desc asc use go' }
    @{ Kind = 'Command'; Pattern = '\b(?:count|sum|avg|min|max|coalesce|isnull|ifnull|nullif|cast|convert|concat|substring|len|length|upper|lower|trim|getdate|now|row_number|rank|dense_rank)\b(?=\s*\()' }
    @{ Kind = 'Variable'; Pattern = '@@?\w+' }
    @{ Kind = 'Number'; Pattern = '\b\d+(?:\.\d+)?\b' }
)

Register-WtCodeLanguage -Name 'csharp' -Aliases 'cs', 'c#' -Rules @(
    @{ Kind = 'Comment'; Pattern = "//.*|$cBlock" }
    @{ Kind = 'String'; Pattern = '@"(?:""|[^"])*"|\$?' + $dq + "|'(?:\\.|[^'\\\n])'" }
    @{ Kind = 'Keyword'; Words = 'abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while var async await get set value record init' }
    @{ Kind = 'Type'; Pattern = '\b[A-Z]\w*\b' }
    @{ Kind = 'Command'; Pattern = '\b[a-z_]\w*(?=\s*\()' }
    @{ Kind = 'Number'; Pattern = $num }
)

Register-WtCodeLanguage -Name 'ini' -Aliases 'toml', 'conf', 'cfg', 'properties', 'env', 'dotenv', 'editorconfig' -Rules @(
    @{ Kind = 'Comment'; Pattern = '^[ \t]*[;#].*' }
    @{ Kind = 'Type'; Pattern = '^[ \t]*\[[^\]\n]*\]' }
    @{ Kind = 'Attr'; Pattern = '^[ \t]*[^=:\s\[;#][^=:\n]*?(?=[ \t]*[=:])' }
    @{ Kind = 'String'; Pattern = "$dq|'[^'\n]*'" }
    @{ Kind = 'Keyword'; Pattern = '(?i)(?<=[=:][ \t]*)(?:true|false|yes|no|on|off)\b' }
    @{ Kind = 'Number'; Pattern = '(?<=[=:][ \t]*)-?\d+(?:\.\d+)?\b' }
)

Register-WtCodeLanguage -Name 'diff' -Aliases 'patch', 'udiff' -Rules @(
    @{ Kind = 'Type'; Pattern = '^(?:@@.*|diff .*|index .*|---(?: .*)?|\+\+\+(?: .*)?)$' }
    @{ Kind = 'Inserted'; Pattern = '^[+>].*' }
    @{ Kind = 'Deleted'; Pattern = '^[-<].*' }
)

Register-WtCodeLanguage -Name 'css' -Aliases 'scss', 'less' -Rules @(
    @{ Kind = 'Comment'; Pattern = "$cBlock|(?<=^|\s)//.*" }
    @{ Kind = 'String'; Pattern = "$dq|$sq" }
    @{ Kind = 'Keyword'; Pattern = '@[\w-]+|!important' }
    @{ Kind = 'Attr'; Pattern = '(?<=[{;\s])[\w-]+(?=\s*:[^{}\n]*[;}\n])' }
    @{ Kind = 'Number'; Pattern = '#[0-9a-fA-F]{3,8}\b|-?\b\d+(?:\.\d+)?(?:px|em|rem|%|vh|vw|s|ms|pt|deg)?' }
    @{ Kind = 'Type'; Pattern = '[.#][A-Za-z_][\w-]*' }
)

Register-WtCodeLanguage -Name 'dockerfile' -Aliases 'docker', 'containerfile' -IgnoreCase -Rules @(
    @{ Kind = 'Comment'; Pattern = '^[ \t]*#.*' }
    @{ Kind = 'Keyword'; Pattern = '^[ \t]*(?:FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b|\bAS\b' }
    @{ Kind = 'String'; Pattern = "$dq|'[^'\n]*'" }
    @{ Kind = 'Variable'; Pattern = '\$(?:\{[^}\n]*\}|\w+)' }
    @{ Kind = 'Attr'; Pattern = '(?<=\s)--?[A-Za-z][\w-]*' }
)

Register-WtCodeLanguage -Name 'batch' -Aliases 'bat', 'cmd' -IgnoreCase -Rules @(
    @{ Kind = 'Comment'; Pattern = '^[ \t@]*(?:rem(?:\s.*)?|::.*)$' }
    @{ Kind = 'String'; Pattern = '"[^"\n]*"' }
    @{ Kind = 'Variable'; Pattern = '%~?[\w]*%|%%~?\w|%~?\d|![\w]+!' }
    @{ Kind = 'Type'; Pattern = '^[ \t]*:\w+' }
    @{ Kind = 'Keyword'; Words = 'if else for in do goto call set setlocal endlocal echo exit not exist defined errorlevel equ neq lss leq gtr geq pause shift start cd pushd popd title' }
    @{ Kind = 'Attr'; Pattern = '(?<=\s)/[\w?]+' }
    @{ Kind = 'Number'; Pattern = '\b\d+\b' }
)

Export-ModuleMember -Function Register-WtCodeLanguage, Get-WtCodeLanguage, Get-WtCodeLanguageNames, Get-WtCodeTokens
} | Import-Module -Force -DisableNameChecking
# ---- core\Highlight.psm1 끝 ----

# ---- core\Markdown.psm1 ----
New-Module -Name 'WorkTool.Markdown' -ScriptBlock {
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
# - 할 일 체크 표시를 눌렀을 때: New-WtMarkdownView -OnTask { param($line) ... } ($line = 그 항목의 원문 줄 번호, 1부터)
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

# 파일 링크를 열기 전 경로 확인 (있는지 · 폴더인지). 화면 밖(.NET 작업)에서 하고 타이머로 결과를 받는다
$script:pathJobs = [System.Collections.Generic.List[object]]::new()
$script:pathTimer = $null
$script:pathTimeoutMs = 5000   # 이 시간 안에 답이 없으면 기다리지 않고 알린다
$script:pathMaxJobs = 8        # 답이 없는 확인이 이만큼 남아 있으면 새로 시작하지 않는다
$script:pathCursor = $null     # 확인 중 커서를 바꾸기 전 값 (@{ Old })
# 확인 작업 만들기: 경로 → 끝나면 파일 속성(없으면 -1)을 주는 Task. 검사가 느린 경로를 흉내 내려고 바꿔 끼운다
$script:pathProbe = {
    param($path)
    $info = [System.IO.FileInfo]::new($path)
    [System.Threading.Tasks.Task[System.IO.FileAttributes]]::Run([Func[System.IO.FileAttributes]]$info.get_Attributes)
}

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

<#
블록 단위 (글을 고치면서 블록 하나씩 바꿔 그리는 화면용. 메모 편집기가 쓴다)
  Get-WtMarkdownUnits $text [-LineOffset n] → 단위 배열. 단위 = @{ Start; End; Kind; Depth; Last; Text; ListId }
    Start · End  원문 줄 번호(0부터, End는 들지 않음). 블록 사이의 빈 줄은 어느 단위에도 들지 않는다.
                 -LineOffset을 주면 그만큼 더한다(글 일부만 다시 나눌 때)
    Kind         heading · para · list-item · quote · callout · code · math · hr · html · table · props · raw
                 raw = 그리면 보이지 않는 줄(링크 정의 · 주석 · 각주 정의 등). 원문을 흐리게 보여 준다
    Depth        목록 항목의 깊이. 목록 항목은 항목 하나씩 단위가 되고, 안쪽 목록도 따로 단위가 된다
    Last         목록 항목: 목록의 마지막 줄인지 (아래 여백)
    Text         단위의 원문 (줄바꿈은 \n). 그린 것을 다시 쓸지 비교할 때 쓴다
  그릴 모델은 나눌 때 만들지 않고 New-WtMarkdownUnitSection이 그릴 때 만든다 (긴 글을 빨리 나누려고).
#>
function Get-WtMarkdownUnits([AllowEmptyString()][string]$Text, [int]$LineOffset = 0) {
    $src = ([string]$Text).Replace("`r`n", "`n").Replace("`r", "`n")
    # 글 일부(가운데)를 나눌 때는 앞에 빈 줄을 하나 붙인다. 맨 앞 ---를 머리말(속성)로 읽지 않게
    $pad = 0
    if ($LineOffset -gt 0) { $src = "`n" + $src; $pad = 1 }
    $lines = $src -split "`n"
    $starts = [int[]]::new($lines.Count)
    $pos = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { $starts[$i] = $pos; $pos += $lines[$i].Length + 1 }
    $doc = [Markdig.Markdown]::Parse($src, (Get-WtMarkdownPipeline))
    $LineOffset -= $pad
    $ctx = @{ Src = $src; Headings = [System.Collections.Generic.List[object]]::new(); Starts = $starts; Lines = $lines; Offset = $LineOffset }
    $units = [System.Collections.Generic.List[object]]::new()
    foreach ($b in $doc) { Add-WtMdUnitsOf $units $b $ctx 0 }

    # 어느 단위에도 들지 않은 글 줄(링크 정의 · HTML 주석 등)은 raw 단위로 채운다. 그래야 모든 줄을 고칠 수 있다
    $covered = [bool[]]::new($lines.Count)
    foreach ($u in $units) { for ($l = $u.Start; $l -lt $u.End; $l++) { $covered[$l] = $true } }
    $l = 0
    while ($l -lt $lines.Count) {
        if ($covered[$l] -or -not $lines[$l].Trim()) { $l++; continue }
        $s = $l
        while ($l -lt $lines.Count -and -not $covered[$l] -and $lines[$l].Trim()) { $l++ }
        $units.Add((New-WtMdUnit 'raw' $s $l $null $ctx))
    }
    $sorted = @($units | Sort-Object { $_.Start })
    # 겹치는 단위는 앞 단위를 뒤 단위 시작에서 자른다 (예: 바로 아래 표가 붙은 문단 — Markdig이 문단 범위를 표까지 잡는다)
    for ($i = 0; $i + 1 -lt $sorted.Count; $i++) {
        $u = $sorted[$i]; $n = $sorted[$i + 1]
        if ($u.End -gt $n.Start -and $n.Start -gt $u.Start) {
            $u.End = $n.Start
            $u.Text = ($lines[$u.Start..($u.End - 1)]) -join "`n"
        }
    }
    # 목록 항목의 아래 여백: 다음 단위가 이어지는 목록 항목이 아니면 목록 끝
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $u = $sorted[$i]
        if ($u.Kind -ne 'list-item') { continue }
        $next = if ($i + 1 -lt $sorted.Count) { $sorted[$i + 1] } else { $null }
        $u.Last = -not ($next -and $next.Kind -eq 'list-item' -and $next.ListId -eq $u.ListId)
    }
    if ($LineOffset) { foreach ($u in $sorted) { $u.Start += $LineOffset; $u.End += $LineOffset } }
    # Base = 나눌 때의 첫 줄. 모델의 줄 번호(Line)는 이 기준이라, 단위가 나중에 아래로 밀려도 Start - Base로 옮겨 쓴다
    foreach ($u in $sorted) { $u.Base = $u.Start }
    , $sorted
}

# 단위. Md = Markdig 블록(그릴 때 모델로 바꿈), Own = 목록 항목에서 안쪽 목록을 뺀 자식들
function New-WtMdUnit([string]$Kind, [int]$Start, [int]$End, $Md, $Ctx, [int]$Depth = 0) {
    $text = ($Ctx.Lines[$Start..($End - 1)]) -join "`n"
    @{ Kind = $Kind; Start = $Start; End = $End; Md = $Md; Ctx = $Ctx; Depth = $Depth; Last = $true; Text = $text; ListId = 0; Block = $null }
}

# 단위의 그릴 모델 (처음 부를 때 만든다). 줄 번호(모델의 Line)는 나눈 글 기준에 LineOffset을 더한 것
function Get-WtMdUnitModel($Unit) {
    if ($Unit.Block -or $Unit.Kind -eq 'raw' -or -not $Unit.Md) { return $Unit.Block }
    $ctx = $Unit.Ctx
    if ($Unit.Kind -eq 'list-item') {
        $li = $Unit.Md
        $blocks = ConvertFrom-WtMdBlocks $Unit.Own $ctx
        $task = $null
        if ($blocks.Count -and $blocks[0].T -eq 'para' -and $blocks[0].Inl.Count -and $blocks[0].Inl[0].T -eq 'task') {
            $task = [bool]$blocks[0].Inl[0].Checked
            $rest = @($blocks[0].Inl | Select-Object -Skip 1)
            if ($rest.Count -and $rest[0].T -eq 'text') { $rest[0].Text = $rest[0].Text.TrimStart() }
            $blocks[0].Inl = $rest
        }
        $list = $Unit.List
        $start = 1
        if ($list.IsOrdered) {
            if ($li.Order) { $start = [int]$li.Order } else { [void][int]::TryParse([string]$list.OrderedStart, [ref]$start) }
        }
        $line = $li.Line + 1 + [int]$ctx.Offset
        $Unit.Block = @{ T = 'list'; Ordered = [bool]$list.IsOrdered; Start = $start; Loose = [bool]$list.IsLoose; Items = @(@{ Task = $task; Blocks = $blocks; Line = $line }); Line = $line }
    } else {
        $Unit.Block = ConvertFrom-WtMdBlock $Unit.Md $ctx
    }
    # 모델을 만들었으면 글 전체 · 구문 트리를 놓아준다 (그린 Section이 단위를 오래 붙잡는다)
    $Unit.Md = $null; $Unit.Ctx = $null; $Unit.Own = $null; $Unit.List = $null
    $Unit.Block
}

# Markdig 블록이 차지하는 줄 범위 (끝 줄 포함 안 함)
function Get-WtMdBlockLines($B, $Ctx) {
    $start = [Math]::Max(0, [int]$B.Line)
    $endChar = [Math]::Max($B.Span.Start, $B.Span.End)
    $i = [array]::BinarySearch($Ctx.Starts, [int]$endChar)
    if ($i -lt 0) { $i = (-bnot $i) - 1 }
    $end = [Math]::Max($start + 1, $i + 1)
    # 닫히지 않은 코드 블록은 Span이 여는 줄에서 끝난다. 내용 줄의 마지막 줄까지 넓힌다
    if ($B -is [Markdig.Syntax.LeafBlock] -and $B.Lines.Count -gt 0) {
        $end = [Math]::Max($end, [int]$B.Lines.Lines[$B.Lines.Count - 1].Line + 1)
    }
    @($start, [Math]::Min($end, $Ctx.Lines.Count))
}

function Add-WtMdUnitsOf($Units, $B, $Ctx, [int]$Depth, [int]$ListId = 0) {
    $type = $B.GetType().Name
    if ($type -in 'LinkReferenceDefinitionGroup', 'FootnoteGroup', 'BlankLineBlock') { return }   # 원문 위치가 흩어져 있어 raw로 채운다
    if ($B.Span.End -lt $B.Span.Start) { return }
    $range = Get-WtMdBlockLines $B $Ctx
    if ($type -eq 'ListBlock') {
        $id = [int]$B.Span.Start + 1
        if ($Depth -gt 0) { $id = $ListId }
        foreach ($li in $B) { Add-WtMdListItemUnits $Units $B $li $Ctx $Depth $id }
        return
    }
    # 종류는 Markdig 블록 종류와 원문만 보고 정한다 (모델은 그릴 때)
    $text = ($Ctx.Lines[$range[0]..($range[1] - 1)]) -join "`n"
    $kind = switch ($type) {
        'HeadingBlock' { 'heading' }
        'ParagraphBlock' {
            # 보이는 글이 없는 문단(%%주석%%만 있는 줄 등)은 raw로 보여 준다
            if (-not ($text -replace '%%[\s\S]*?%%', '').Trim()) { 'raw' } else { 'para' }
        }
        'QuoteBlock' { if ($text -match '^\s*>\s*\[![A-Za-z][\w-]*\]') { 'callout' } else { 'quote' } }
        'FencedCodeBlock' { 'code' }
        'CodeBlock' { 'code' }
        'MathBlock' { 'math' }
        'ThematicBreakBlock' { 'hr' }
        'HtmlBlock' {
            $plain = ($text -replace '<br\s*/?>', ' ' -replace '<[^>]+>', '').Trim()
            if ($text.TrimStart().StartsWith('<!--') -or -not $plain) { 'raw' } else { 'html' }
        }
        'Table' { 'table' }
        'YamlFrontMatterBlock' { 'props' }
        default { 'raw' }
    }
    # $(if …) · $x = if …로 넘기면 Markdig 블록(자식 목록)이 펼쳐진다. 변수에 바로 넣는다
    $md = $null
    if ($kind -ne 'raw') { $md = $B }
    $Units.Add((New-WtMdUnit $kind $range[0] $range[1] $md $Ctx $Depth))
}

# 목록 항목 하나 = 단위 하나. 안쪽 목록이 항목 끝에만 있으면 따로 나눠 Depth+1로, 아니면 항목 통째로
function Add-WtMdListItemUnits($Units, $List, $Li, $Ctx, [int]$Depth, [int]$ListId) {
    $children = @($Li)
    $firstNested = -1
    for ($i = 0; $i -lt $children.Count; $i++) { if ($children[$i].GetType().Name -eq 'ListBlock') { $firstNested = $i; break } }
    $split = $firstNested -ge 1
    if ($split) { for ($i = $firstNested; $i -lt $children.Count; $i++) { if ($children[$i].GetType().Name -ne 'ListBlock') { $split = $false } } }
    $own = if ($split) { @($children[0..($firstNested - 1)]) } else { $children }
    $range = Get-WtMdBlockLines $Li $Ctx
    $end = if ($split) { (Get-WtMdBlockLines $children[$firstNested] $Ctx)[0] } else { $range[1] }
    # 항목 안 빈 줄은 단위에 넣지 않는다 (뒤쪽 빈 줄 떼기)
    while ($end - 1 -gt $range[0] -and -not $Ctx.Lines[$end - 1].Trim()) { $end-- }
    $u = New-WtMdUnit 'list-item' $range[0] $end $Li $Ctx $Depth
    $u.ListId = $ListId
    $u.List = $List
    $u.Own = $own
    $Units.Add($u)
    if ($split) {
        for ($i = $firstNested; $i -lt $children.Count; $i++) { Add-WtMdUnitsOf $Units $children[$i] $Ctx ($Depth + 1) $ListId }
    }
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
    if ($Url -match '^[A-Za-z]:[\\/]|^\\\\|^//|^file:') { return 'file' }   # //서버/공유: 메모 편집기가 UNC를 슬래시로 쓴다
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
  -OnTask            { param($line) ... } 할 일 체크 표시를 눌렀을 때 (그 항목의 원문 줄 번호). 없으면 체크 표시는 누를 수 없다
  -BaseDir           상대 경로의 기준 폴더
  -StrictLineBreaks  줄바꿈 한 번은 이어 붙인다 (표준 마크다운). 없으면 Obsidian 기본값처럼 줄을 바꾼다
#>
function New-WtMarkdownView {
    param([switch]$Scroll, [scriptblock]$OnLink, [scriptblock]$OnTask, [string]$BaseDir = '', [switch]$StrictLineBreaks)
    $v = [System.Windows.Controls.RichTextBox]::new()
    Set-WtMdStyle $v 'Md.View'
    $v.IsReadOnly = $true
    $v.IsDocumentEnabled = $true
    $v.VerticalScrollBarVisibility = if ($Scroll) { 'Auto' } else { 'Disabled' }
    $v.Tag = @{
        Text = ''; BaseDir = $BaseDir; OnLink = $OnLink; OnTask = $OnTask; Strict = [bool]$StrictLineBreaks
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

# 단위 하나를 Section 하나로 그린다 (Section.Tag = 단위). 보기의 상태(링크 처리 등)를 같이 쓴다.
# 보기의 문서를 직접 꾸리는 화면(메모 편집기)이 Get-WtMarkdownUnits와 함께 쓴다.
function New-WtMarkdownUnitSection {
    param([Parameter(Mandatory)]$View, [Parameter(Mandatory)]$Unit)
    $st = $View.Tag
    $sec = [System.Windows.Documents.Section]::new()
    $sec.Tag = $Unit
    try {
        $model = Get-WtMdUnitModel $Unit
        if ($Unit.Kind -eq 'raw' -or -not $model) {
            $p = New-WtMdPara 'Md.Raw'
            $parts = $Unit.Text -split "`n"
            for ($i = 0; $i -lt $parts.Count; $i++) {
                if ($i) { $p.Inlines.Add([System.Windows.Documents.LineBreak]::new()) }
                if ($parts[$i]) { $p.Inlines.Add((New-WtMdRun $parts[$i])) }
            }
            $sec.Blocks.Add($p)
            return $sec
        }
        $st.ListDepth = [int]$Unit.Depth
        try { Add-WtMdBlock $sec.Blocks $model $st } finally { $st.ListDepth = 0 }
        if ($Unit.Kind -eq 'list-item') {
            # 항목마다 따로 그린 목록을 이어 붙여 하나처럼 보이게: 들여쓰기 = 목록 안쪽 여백 × 깊이, 항목 사이 = 항목 아래 여백
            $list = $sec.Blocks.FirstBlock
            if ($list -is [System.Windows.Documents.List]) {
                $li = $list.ListItems.FirstListItem
                $gap = if ($li) { $li.Margin.Bottom } else { 0 }
                $bottom = if ($Unit.Last) { $list.Margin.Bottom } else { $gap }
                $list.Margin = [System.Windows.Thickness]::new($list.Padding.Left * $Unit.Depth, 0, 0, $bottom)
                if ($li) { $li.Margin = [System.Windows.Thickness]::new(0) }
            }
        }
    } catch {
        $sec.Blocks.Clear()
        $p = New-WtMdPara 'Md.Raw'
        $p.Inlines.Add((New-WtMdRun $Unit.Text))
        $sec.Blocks.Add($p)
    }
    $sec
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
            $where = $X.Target
            if ($X.Kind -eq 'file') {
                # 로컬 파일 · 폴더: 앞에 아이콘, 툴팁은 Windows 모양 전체 경로. 폴더인지는 디스크를 보지 않고 이름으로 추측한다
                $where = Resolve-WtMdPath $X.Target $St.BaseDir
                if (-not $where) { $where = $X.Target.Replace('/', '\') }
                $h.Inlines.Add((New-WtMdIconRun $(if (Test-WtMdFolderLike $where) { 0xE8B7 } else { 0xE8A5 })))
                $h.Inlines.Add((New-WtMdRun ' '))
            }
            Add-WtMdInlines $h.Inlines $X.Inl $St
            $tip = if ($X.Title) { "$($X.Title)`n$where" } else { $where }
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

# 할 일 체크 표시를 누를 수 있게 감싼다 (-OnTask가 있을 때만). Run보다 밑줄 없는 Hyperlink가 RichTextBox 안에서 확실히 눌린다
function New-WtMdTaskLink($Box, [int]$Line, $St) {
    $h = [System.Windows.Documents.Hyperlink]::new($Box)
    Set-WtMdStyle $h 'Md.TaskLink'
    $h.ToolTip = '완료 표시 / 해제'
    $h.Tag = @{ Line = $Line; State = $St }
    $h.Add_Click({
            param($s, $e)
            # 둘째 값은 누른 요소. 문서를 블록 단위로 다시 쓰는 화면(메모 편집기)이 지금 줄 번호를 찾을 때 쓴다
            try { [void](& $s.Tag.State.OnTask $s.Tag.Line $s) } catch { Show-WtError $_ '할 일 표시' }
        })
    $h
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
       있는지 · 폴더인지는 화면 밖에서 확인한다 (Start-WtMdPathCheck). 응답 없는 공유 폴더에서도 화면이 멈추지 않는다
  wiki 연결할 곳을 모른다고 알린다 (메모 · 문서 화면이 -OnLink로 처리한다)
#>
function Invoke-WtMarkdownLink($St, $Link) {
    if ($Link.Kind -eq 'anchor') {
        $el = $St.Anchors[(Get-WtMdAnchorKey $Link.Target)]
        if ($el) { $el.BringIntoView() }
        return
    }
    if ($St.OnLink) {
        # 둘째 값은 보기의 상태(Tag). 보기를 여럿 둔 화면이 어느 보기에서 눌렸는지 알 때 쓴다
        $handled = & $St.OnLink $Link $St | Select-Object -Last 1
        if ($handled -eq $true) { return }
    }
    switch ($Link.Kind) {
        'url' {
            if ($Link.Target -match '^(?i)(https?|mailto):') { Start-Process $Link.Target }
            else { Show-WtMessage "이 주소는 열지 않습니다.`n$($Link.Target)" }
        }
        'file' {
            $path = Resolve-WtMdPath $Link.Target $St.BaseDir
            if (-not $path) { Show-WtMessage "파일을 찾지 못했습니다.`n$($Link.Target)"; return }
            Start-WtMdPathCheck $path $Link.Target
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
    # 상대 경로의 #제목은 문서 안 자리라서 뗀다. 드라이브 · UNC 경로의 #은 이름의 일부다(예: C:\C# 공부)
    if ($t -notmatch '^([A-Za-z]:[\\/]|[\\/]{2})') { $t = $t -replace '#.*$', '' }
    if (-not $t) { return $null }
    try {
        if ([System.IO.Path]::IsPathRooted($t)) { return [System.IO.Path]::GetFullPath($t) }
        if ($BaseDir) { return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $t)) }
    } catch { }
    $null
}

# 이름만 보고 폴더인지 추측한다 (그리는 중에 디스크 · 네트워크를 건드리지 않는다).
# 끝이 \ · /, 드라이브 루트(C:), UNC 서버 · 공유 루트(\\서버\공유), 마지막 이름에 확장자가 없으면 폴더
function Test-WtMdFolderLike([string]$Path) {
    $p = $Path.Replace('/', '\')
    if (-not $p) { return $false }
    if ($p.EndsWith('\') -or $p -match '^[A-Za-z]:$' -or $p -match '^\\\\[^\\]+(\\[^\\]+)?$') { return $true }
    -not [System.IO.Path]::GetExtension($p)
}

<#
파일 링크의 경로(있는지 · 폴더인지)를 화면 밖에서 확인하고, 끝나면 Invoke-WtMdPathResult로 연다.
응답 없는 공유 폴더 · 끊긴 네트워크 드라이브에서도 화면이 멈추지 않는다. 로컬 드라이브도 끊긴 네트워크 드라이브일 수 있어서 모두 이 길로 간다.
- 실행 공간 대신 .NET 작업(Task)으로 확인한다. 실행 공간은 응답 없는 OS 호출 중이면 Close · Dispose를 해도 앱 프로세스가 끝나지 않는다.
  작업은 PowerShell 없이 스레드 풀(백그라운드 스레드)에서 돌아서, 끝나지 않은 채 남아도 프로세스를 붙잡지 않는다.
- 확인하는 동안 커서는 AppStarting(화살표 + 모래시계). 기다리는 동안에도 앱은 쓸 수 있다.
- 같은 경로를 확인 중에 또 누르면 겹쳐 시작하지 않는다. $script:pathTimeoutMs 안에 답이 없으면 기다리지 않고 알린다.
#>
function Start-WtMdPathCheck([string]$Path, [string]$Target) {
    $key = $Path.ToLowerInvariant()
    # 시간이 지난 뒤에 끝난 확인은 여기서 치운다 (타이머는 기다리는 확인이 없으면 멈춰 있다)
    foreach ($job in @($script:pathJobs.ToArray())) { if ($job.TimedOut -and $job.Task.IsCompleted) { [void]$script:pathJobs.Remove($job) } }
    $same = @($script:pathJobs | Where-Object { $_.Key -eq $key })
    if (@($same | Where-Object { -not $_.TimedOut }).Count) { return }
    # 앞서 시간이 지난 확인이 아직 답을 기다리면, 또 기다리지 않고 바로 알린다
    if ($same.Count) { Show-WtMessage (Get-WtMdPathTimeoutText $Path) 'WorkTool' 'Warning'; return }
    if ($script:pathJobs.Count -ge $script:pathMaxJobs) {
        Show-WtMessage "응답하지 않는 경로가 많아 지금은 열지 않습니다. 네트워크 연결을 확인하고 잠시 뒤 다시 누르세요.`n$Path" 'WorkTool' 'Warning'
        return
    }
    try { $task = & $script:pathProbe $Path | Select-Object -Last 1 }
    catch { Show-WtMessage "경로를 확인하지 못했습니다. 경로가 맞는지 확인하세요.`n$Path`n$($_.Exception.Message)" 'WorkTool' 'Warning'; return }
    $script:pathJobs.Add(@{ Key = $key; Path = $Path; Target = $Target; Task = $task; Watch = [System.Diagnostics.Stopwatch]::StartNew(); TimedOut = $false })
    Update-WtMdPathCursor
    if (-not $script:pathTimer) { $script:pathTimer = New-WtPollTimer { Complete-WtMdPathChecks } }
    $script:pathTimer.Start()
}

function Get-WtMdPathTimeoutText([string]$Path) {
    "경로가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인한 뒤 다시 누르세요.`n$Path"
}

# 타이머가 부른다: 끝난 확인은 목록에서 빼고 열고, 시간이 지난 확인은 알린다 (작업은 끝날 때까지 목록에 남아 겹쳐 시작하지 않게 한다)
function Complete-WtMdPathChecks {
    $done = [System.Collections.Generic.List[object]]::new()
    foreach ($job in @($script:pathJobs.ToArray())) {
        if ($job.Task.IsCompleted) {
            [void]$script:pathJobs.Remove($job)
            if (-not $job.TimedOut) { $done.Add($job) }   # 시간이 지난 확인은 이미 알렸으므로 결과를 버린다
        } elseif (-not $job.TimedOut -and $job.Watch.ElapsedMilliseconds -ge $script:pathTimeoutMs) {
            $job.TimedOut = $true
            $done.Add($job)
        }
    }
    Update-WtMdPathCursor
    # 기다리는 확인이 없으면 멈춘다. 시간이 지난 확인이 끝내 답하지 않아도 타이머가 계속 돌지 않게
    if (-not @($script:pathJobs | Where-Object { -not $_.TimedOut }).Count -and $script:pathTimer) { $script:pathTimer.Stop() }
    # 알림 창이 떠 있는 동안에도 타이머가 돌 수 있으므로, 목록을 다 정리한 뒤에 연다
    foreach ($job in $done) {
        try { Invoke-WtMdPathResult $job } catch { Show-WtError $_ '링크 열기' }
    }
}

# 확인 결과대로 연다: 폴더 → 탐색기, 열 수 있는 종류 → 기본 프로그램, 그 밖 → 탐색기에서 선택, 없음 → 알림
function Invoke-WtMdPathResult($Job) {
    $path = $Job.Path
    if ($Job.TimedOut) { Show-WtMessage (Get-WtMdPathTimeoutText $path) 'WorkTool' 'Warning'; return }
    if ($Job.Task.IsFaulted -or $Job.Task.IsCanceled) {
        $why = if ($Job.Task.Exception) { $Job.Task.Exception.GetBaseException().Message } else { '' }
        Show-WtMessage "경로를 확인하지 못했습니다. 접근 권한과 경로를 확인하세요.`n$path`n$why" 'WorkTool' 'Warning'
        return
    }
    $attr = [int]$Job.Task.Result
    if ($attr -eq -1) { Show-WtMessage "파일을 찾지 못했습니다.`n$($Job.Target)"; return }
    if ($attr -band [int][System.IO.FileAttributes]::Directory) { Invoke-Item -LiteralPath $path; return }
    if ($script:openable -contains [System.IO.Path]::GetExtension($path).ToLowerInvariant()) { Invoke-Item -LiteralPath $path; return }
    Start-Process explorer.exe -ArgumentList "/select,`"$path`""
}

# 확인 중이면 커서를 AppStarting으로, 기다리는 확인이 없으면 원래대로
function Update-WtMdPathCursor {
    $waiting = @($script:pathJobs | Where-Object { -not $_.TimedOut }).Count -gt 0
    $busy = [System.Windows.Input.Cursors]::AppStarting
    if ($waiting -and -not $script:pathCursor) {
        $script:pathCursor = @{ Old = [System.Windows.Input.Mouse]::OverrideCursor }
        [System.Windows.Input.Mouse]::OverrideCursor = $busy
    } elseif (-not $waiting -and $script:pathCursor) {
        if ([object]::ReferenceEquals([System.Windows.Input.Mouse]::OverrideCursor, $busy)) { [System.Windows.Input.Mouse]::OverrideCursor = $script:pathCursor.Old }
        $script:pathCursor = $null
    }
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
                $box = New-WtMdTaskBox $it.Task
                if ($St.OnTask) { $box = New-WtMdTaskLink $box $it.Line $St }
                $p.Inlines.Add($box)
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
    Get-WtMarkdownSnippet, Get-WtMarkdownHeadings, New-WtMarkdownView, Set-WtMarkdownText, Invoke-WtMarkdownLink,
    Get-WtMarkdownUnits, New-WtMarkdownUnitSection
} | Import-Module -Force -DisableNameChecking
# ---- core\Markdown.psm1 끝 ----

# ---- core\Mermaid.psm1 ----
New-Module -Name 'WorkTool.Mermaid' -ScriptBlock {
# Mermaid 다이어그램. 마크다운의 ```mermaid 코드 블록을 그린다 (Markdown.psm1에 코드 블록 그리기로 등록).
# 이 창에는 브라우저(WebBrowser)를 넣을 수 없어서, 자주 쓰는 문법을 직접 읽고 배치해서 WPF 도형으로 그린다.
#
# 지원
# - flowchart · graph: 방향 TB TD BT LR RL, 노드 모양 14종, 선(실선 · 점선 · 굵은 선 · 안 보이는 선), 끝(화살표 · 원 · X),
#   라벨(-->|글| 와 -- 글 -->), A & B 묶음, subgraph(중첩 포함)
# - sequenceDiagram: participant · actor(as 별칭), 메시지 화살표 10종, Note(left of · right of · over),
#   loop · alt/else · opt · par/and · critical/option · break · rect, autonumber
# - stateDiagram · stateDiagram-v2: 상태, [*] 시작 · 끝, 전이 라벨, state "설명" as X, X : 설명, 복합 상태 { }, choice · fork · join
# 그 밖의 종류(gantt · classDiagram · pie …)는 NotSupportedException을 던진다 → 마크다운 쪽이 원문을 코드 블록으로 보여 준다.
# 색 · 모양 꾸미기(style · classDef · class · linkStyle)와 click은 읽고 무시한다. 색은 Theme.psm1의 Dia.* 만 쓴다.
#
# 1) ConvertFrom-WtMermaid: 글 → 모델                              (WPF 없이 동작)
# 2) Get-WtMermaidLayout: 모델 → 도형 목록(좌표). 글자 크기 재는 함수를 받는다  (WPF 없이 동작)
# 3) New-WtMermaidView: 글 → 그림 요소(Viewbox + Canvas)             (WPF)

$ErrorActionPreference = 'Stop'

# 배치 간격 (epx)
$script:gap = @{
    Margin   = 8    # 그림 가장자리
    PadX     = 16   # 노드 안 글자 좌우 여백
    PadY     = 10   # 노드 안 글자 위아래 여백
    NodeSep  = 32   # 같은 층 노드 사이
    DummySep = 16   # 같은 층에서 선이 지나가는 점 · 라벨 사이
    RankGap  = 24   # 층 사이. 선 하나는 두 층을 건너므로 노드 사이는 48 + 라벨 높이
    GroupPad = 12   # subgraph 상자 안 여백
    Arrow    = 9    # 화살표 길이
}

# ---- 글 → 모델 -------------------------------------------------------------------------------

function New-WtMmdMap { [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal) }

function ConvertFrom-WtMermaid([string]$Text) {
    $lines = @(([string]$Text).Replace("`r", '') -split "`n")
    $title = ''
    $i = 0
    while ($i -lt $lines.Count -and -not $lines[$i].Trim()) { $i++ }
    # 맨 앞 --- title: … --- 머리말
    if ($i -lt $lines.Count -and $lines[$i].Trim() -eq '---') {
        $i++
        while ($i -lt $lines.Count -and $lines[$i].Trim() -ne '---') {
            if ($lines[$i] -match '^\s*title:\s*(.+)$') { $title = $Matches[1].Trim().Trim('"', "'") }
            $i++
        }
        $i++
    }
    $stmts = Split-WtMmdStatements @($lines | Select-Object -Skip $i)
    if (-not $stmts.Count) { throw '다이어그램 내용이 없습니다.' }
    $kind = ($stmts[0] -split '\s+')[0].ToLowerInvariant()
    $m = switch -Regex ($kind) {
        '^(graph|flowchart)(-elk)?$' { ConvertFrom-WtMmdFlowchart $stmts }
        '^sequencediagram$' { ConvertFrom-WtMmdSequence $stmts }
        '^statediagram(-v2)?$' { ConvertFrom-WtMmdState $stmts }
        default { throw [System.NotSupportedException]::new("'$kind' 종류는 아직 지원하지 않습니다 (flowchart · sequenceDiagram · stateDiagram만 그립니다).") }
    }
    if ($title -and -not $m.Title) { $m.Title = $title }
    $m
}

# 줄과 ;로 문장을 나눈다. %% 주석 줄은 뺀다. 따옴표 · 괄호 안의 ;는 나누지 않는다.
function Split-WtMmdStatements([string[]]$Lines) {
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($raw in $Lines) {
        $line = ([string]$raw).Trim()
        if (-not $line -or $line.StartsWith('%%')) { continue }
        $buf = [System.Text.StringBuilder]::new()
        $quote = $false
        $depth = 0
        foreach ($ch in $line.ToCharArray()) {
            if ($ch -eq '"') { $quote = -not $quote }
            elseif (-not $quote) {
                if ('[({'.IndexOf($ch) -ge 0) { $depth++ }
                elseif (')]}'.IndexOf($ch) -ge 0) { if ($depth -gt 0) { $depth-- } }
                elseif ($ch -eq ';' -and $depth -eq 0) {
                    $s = $buf.ToString().Trim()
                    if ($s) { $out.Add($s) }
                    [void]$buf.Clear()
                    continue
                }
            }
            [void]$buf.Append($ch)
        }
        $s = $buf.ToString().Trim()
        if ($s) { $out.Add($s) }
    }
    , $out.ToArray()
}

# 라벨 글: 감싼 따옴표 · `마크다운 글` 기호를 떼고, <br>은 줄바꿈, #quot; 같은 Mermaid 글자 표기를 바꾼다
function ConvertTo-WtMmdText([string]$Text) {
    $t = ([string]$Text).Trim()
    if ($t.Length -ge 2 -and $t.StartsWith('"') -and $t.EndsWith('"')) { $t = $t.Substring(1, $t.Length - 2) }
    if ($t.Length -ge 2 -and $t.StartsWith('`') -and $t.EndsWith('`')) { $t = $t.Substring(1, $t.Length - 2) -replace '\*\*|__', '' }
    $t = $t -replace '<br\s*/?>', "`n"
    $t = $t -replace '#quot;', '"' -replace '#amp;', '&' -replace '#lt;', '<' -replace '#gt;', '>' -replace '#35;', '#' -replace '#59;', ';'
    $t = $t -replace '<[^>]+>', ''
    (@($t -split "`n") | ForEach-Object { $_.Trim() }) -join "`n"
}

function New-WtMmdFlowModel([string]$Dir) {
    @{ Type = 'flowchart'; Dir = $Dir; Nodes = (New-WtMmdMap); Edges = [System.Collections.Generic.List[object]]::new(); Groups = (New-WtMmdMap); Title = '' }
}

# 노드를 더하거나 고친다. 글을 주면 글 · 모양을 바꾸고, subgraph 안에서 나오면 그 subgraph로 옮긴다 (Mermaid와 같음)
function Add-WtMmdNode($M, [string]$Id, $Text, [string]$Shape, $Group, [string]$DefaultShape = 'rect') {
    if (-not $M.Nodes.Contains($Id)) { $M.Nodes[$Id] = @{ Id = $Id; Text = $Id; Shape = $DefaultShape; Group = $null } }
    $n = $M.Nodes[$Id]
    if ($null -ne $Text) { $n.Text = ConvertTo-WtMmdText $Text }
    if ($Shape) { $n.Shape = $Shape }
    if ($Group) { $n.Group = $Group }
    $Id
}

function ConvertFrom-WtMmdFlowchart([string[]]$Stmts) {
    $dir = 'TB'
    if ($Stmts[0] -match '^\S+\s+(TB|TD|BT|LR|RL)\b') { $dir = $Matches[1].ToUpperInvariant() }
    if ($dir -eq 'TD') { $dir = 'TB' }
    $m = New-WtMmdFlowModel $dir
    $stack = [System.Collections.Generic.List[string]]::new()
    for ($i = 1; $i -lt $Stmts.Count; $i++) {
        $s = $Stmts[$i]
        $group = if ($stack.Count) { $stack[$stack.Count - 1] } else { $null }
        if ($s -match '^subgraph\b\s*(.*)$') {
            $g = Read-WtMmdSubgraphHead $Matches[1] $m.Groups.Count
            $g.Parent = $group
            $m.Groups[$g.Id] = $g
            $stack.Add($g.Id)
            continue
        }
        if ($s -match '^end\s*$') { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }; continue }
        if ($s -match '^(direction|classDef|class|style|linkStyle|click|accTitle|accDescr)\b') { continue }
        Read-WtMmdChain $m $s $group
    }
    $m
}

function Read-WtMmdSubgraphHead([string]$Rest, [int]$N) {
    $r = $Rest.Trim()
    if ($r -match '^([^\s\[\]"]+)\s*\[(.*)\]$') { return @{ Id = $Matches[1]; Title = (ConvertTo-WtMmdText $Matches[2]) } }
    if ($r -match '^"(.*)"$') { return @{ Id = "subgraph$N"; Title = $Matches[1] } }
    if (-not $r) { return @{ Id = "subgraph$N"; Title = '' } }
    @{ Id = $r; Title = $r }
}

# 노드 모양: 여는 기호, 닫는 기호, 이름. 여는 기호가 긴 것부터 (같은 여는 기호끼리는 붙여 둔다)
$script:shapes = @(
    @('(((', ')))', 'dcircle'), @('([', '])', 'stadium'), @('[[', ']]', 'subroutine'), @('[(', ')]', 'cylinder'),
    @('((', '))', 'circle'), @('{{', '}}', 'hexagon'), @('[/', '/]', 'para'), @('[/', '\]', 'trap'),
    @('[\', '\]', 'paraAlt'), @('[\', '/]', 'trapAlt'), @('>', ']', 'asym'), @('[', ']', 'rect'),
    @('(', ')', 'round'), @('{', '}', 'diamond')
)
$script:idRe = [regex]::new('\G\s*([\p{L}\p{N}_]+(?:[-.][\p{L}\p{N}_]+)*)')
$script:classRe = [regex]::new('\G:::[\w-]+')
$endPat = '(?<h>>|[ox](?![\p{L}\p{N}_]))?'
$script:edgeRes = @(
    [regex]::new('\G\s*(?<s>[<ox])?==\s+(?<t>[^=|>][^=|]*?)\s*(?<e>={2,})' + $endPat)   # == 글 ==>
    [regex]::new('\G\s*(?<s>[<ox])?-\.\s+(?<t>[^|.>-][^|]*?)\s*(?<e>\.-+)' + $endPat)   # -. 글 .->
    [regex]::new('\G\s*(?<s>[<ox])?--\s+(?<t>[^|>-][^|]*?)\s+(?<e>-{2,})' + $endPat)    # -- 글 -->
    [regex]::new('\G\s*(?<s>[<ox])?(?<e>-{2,}|={2,}|-\.+-|~{3,})' + $endPat)            # --> --- -.-> ==> ~~~
)
$script:pipeRe = [regex]::new('\G\s*\|(?<p>[^|]*)\|')

# 한 문장: 노드묶음 (선 노드묶음)*
function Read-WtMmdChain($M, [string]$S, $Group) {
    $pos = [ref]0
    $left = Read-WtMmdNodeGroup $M $S $pos $Group
    if (-not $left) { return }   # 읽지 못하는 문장은 건너뛴다
    while ($pos.Value -lt $S.Length) {
        $edge = Read-WtMmdEdge $S $pos
        if (-not $edge) { return }
        $right = Read-WtMmdNodeGroup $M $S $pos $Group
        if (-not $right) { return }
        foreach ($a in $left) {
            foreach ($b in $right) {
                $M.Edges.Add(@{ From = $a; To = $b; Text = $edge.Text; Style = $edge.Style; Start = $edge.Start; End = $edge.End; Len = $edge.Len })
            }
        }
        $left = $right
    }
}

function Read-WtMmdNodeGroup($M, [string]$S, [ref]$Pos, $Group) {
    $ids = [System.Collections.Generic.List[string]]::new()
    while ($true) {
        $id = Read-WtMmdNode $M $S $Pos $Group
        if (-not $id) { break }
        $ids.Add($id)
        $mm = [regex]::Match($S.Substring($Pos.Value), '^\s*&\s*')
        if (-not $mm.Success) { break }
        $Pos.Value += $mm.Length
    }
    , $ids.ToArray()
}

function Find-WtMmdClose([string]$S, [int]$Start, [string]$Close) {
    $i = $Start
    if ($i -lt $S.Length -and $S[$i] -eq '"') {
        $q = $S.IndexOf('"', $i + 1)
        if ($q -lt 0) { return -1 }
        $i = $q + 1
    }
    $S.IndexOf($Close, $i, [System.StringComparison]::Ordinal)
}

function Read-WtMmdNode($M, [string]$S, [ref]$Pos, $Group) {
    $mm = $script:idRe.Match($S, $Pos.Value)
    if (-not $mm.Success) { return $null }
    $id = $mm.Groups[1].Value
    if ($id -eq 'end') { return $null }
    $p = $mm.Index + $mm.Length
    $rest = $S.Substring($p)
    $best = $null
    foreach ($sh in $script:shapes) {
        if ($best -and $best.Open -ne $sh[0]) { break }
        if (-not $rest.StartsWith($sh[0], [System.StringComparison]::Ordinal)) { continue }
        $start = $p + $sh[0].Length
        $close = Find-WtMmdClose $S $start $sh[1]
        if ($close -lt 0) { continue }
        if (-not $best -or $close -lt $best.At) { $best = @{ Open = $sh[0]; At = $close; Len = $sh[1].Length; Shape = $sh[2]; Start = $start } }
    }
    $text = $null
    $shape = $null
    if ($best) {
        $text = $S.Substring($best.Start, $best.At - $best.Start)
        $shape = $best.Shape
        $p = $best.At + $best.Len
    }
    $cm = $script:classRe.Match($S, $p)
    if ($cm.Success) { $p += $cm.Length }
    $Pos.Value = $p
    Add-WtMmdNode $M $id $text $shape $Group
}

function Get-WtMmdEnd([string]$C) {
    switch -CaseSensitive ($C) { '>' { 'arrow' } '<' { 'arrow' } 'o' { 'circle' } 'x' { 'cross' } default { 'none' } }
}

function Read-WtMmdEdge([string]$S, [ref]$Pos) {
    for ($k = 0; $k -lt $script:edgeRes.Count; $k++) {
        $mm = $script:edgeRes[$k].Match($S, $Pos.Value)
        if (-not $mm.Success) { continue }
        $Pos.Value = $mm.Index + $mm.Length
        $body = $mm.Groups['e'].Value
        $text = if ($mm.Groups['t'].Success) { $mm.Groups['t'].Value } else { '' }
        $pm = $script:pipeRe.Match($S, $Pos.Value)
        if ($pm.Success) { $text = $pm.Groups['p'].Value; $Pos.Value = $pm.Index + $pm.Length }
        $head = $mm.Groups['h'].Value
        $style = if ($k -eq 0 -or $body.Contains('=')) { 'thick' }
        elseif ($k -eq 1 -or $body.Contains('.')) { 'dotted' }
        elseif ($body.StartsWith('~')) { 'invisible' }
        else { 'normal' }
        # 선 길이(-- 개수)는 건너뛰는 층 수
        $len = if ($style -eq 'dotted') { @($body.ToCharArray() | Where-Object { $_ -eq '.' }).Count }
        else { $body.Length - $(if ($head) { 1 } else { 2 }) }
        return @{
            Text = (ConvertTo-WtMmdText $text); Style = $style; Len = [Math]::Max(1, $len)
            Start = (Get-WtMmdEnd $mm.Groups['s'].Value); End = (Get-WtMmdEnd $head)
        }
    }
    $null
}

# 상태 다이어그램 → flowchart 모델 (상태 = 둥근 사각형, [*] = 시작 · 끝 점, 복합 상태 = subgraph)
function ConvertFrom-WtMmdState([string[]]$Stmts) {
    $m = New-WtMmdFlowModel 'TB'
    $m.Kind = 'state'
    $stack = [System.Collections.Generic.List[string]]::new()
    $inNote = $false
    $idp = '[\p{L}\p{N}_.-]+'
    for ($i = 1; $i -lt $Stmts.Count; $i++) {
        $s = $Stmts[$i]
        if ($inNote) { if ($s -match '^end\s+note$') { $inNote = $false }; continue }
        $group = if ($stack.Count) { $stack[$stack.Count - 1] } else { $null }
        $scope = if ($group) { $group } else { 'root' }
        if ($s -match '^direction\s+(TB|TD|BT|LR|RL)$') {
            if (-not $stack.Count) { $m.Dir = $Matches[1].ToUpperInvariant() -replace 'TD', 'TB' }
            continue
        }
        if ($s -match '^note\s') { if (-not $s.Contains(':')) { $inNote = $true }; continue }
        if ($s -eq '}') { if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }; continue }
        if ($s -eq '--' -or $s -match '^(classDef|class|style|accTitle|accDescr|scale|hide)\b') { continue }
        if ($s -match "^state\s+(?:`"([^`"]*)`"\s+as\s+)?($idp)\s*\{$") {
            $gid = $Matches[2]
            $title = if ($Matches[1]) { $Matches[1] } elseif ($m.Nodes.Contains($gid)) { $m.Nodes[$gid].Text } else { $gid }
            $m.Groups[$gid] = @{ Id = $gid; Title = $title; Parent = $group }
            $stack.Add($gid)
            continue
        }
        if ($s -match "^state\s+($idp)\s*<<(choice|fork|join)>>$") {
            [void](Add-WtMmdNode $m $Matches[1] '' $(if ($Matches[2] -eq 'choice') { 'choice' } else { 'fork' }) $group 'round')
            continue
        }
        if ($s -match "^state\s+`"([^`"]*)`"\s+as\s+($idp)$") { [void](Add-WtMmdNode $m $Matches[2] $Matches[1] $null $group 'round'); continue }
        if ($s -match "^state\s+($idp)$") { [void](Add-WtMmdNode $m $Matches[1] $null $null $group 'round'); continue }
        if ($s -match "^($idp|\[\*\])\s*-->\s*($idp|\[\*\])\s*(?::\s*(.*))?$") {
            $a = $Matches[1]; $b = $Matches[2]; $label = [string]$Matches[3]
            $a = if ($a -eq '[*]') { Add-WtMmdNode $m "[*]start.$scope" '' 'start' $group } else { Add-WtMmdNode $m $a $null $null $group 'round' }
            $b = if ($b -eq '[*]') { Add-WtMmdNode $m "[*]end.$scope" '' 'end' $group } else { Add-WtMmdNode $m $b $null $null $group 'round' }
            $m.Edges.Add(@{ From = $a; To = $b; Text = (ConvertTo-WtMmdText $label); Style = 'normal'; Start = 'none'; End = 'arrow'; Len = 1 })
            continue
        }
        if ($s -match "^($idp)\s*:\s*(.+)$") {
            $id = Add-WtMmdNode $m $Matches[1] $null $null $group 'round'
            $n = $m.Nodes[$id]
            $n.Text = "$($n.Text)`n$(ConvertTo-WtMmdText $Matches[2])"
            continue
        }
        if ($s -match "^($idp)$") { [void](Add-WtMmdNode $m $Matches[1] $null $null $group 'round') }
    }
    # 복합 상태로 가는 선은 그 안의 시작점(없으면 첫 상태)으로, 나오는 선은 끝점(없으면 마지막 상태)에서
    foreach ($gid in @($m.Groups.Keys)) {
        $members = @($m.Nodes.Values | Where-Object { $_.Group -ceq $gid } | ForEach-Object { $_.Id })
        if (-not $members.Count) { continue }
        if ($m.Nodes.Contains($gid)) { $m.Nodes.Remove($gid) }
        $in = if ($m.Nodes.Contains("[*]start.$gid")) { "[*]start.$gid" } else { $members[0] }
        $out = if ($m.Nodes.Contains("[*]end.$gid")) { "[*]end.$gid" } else { $members[$members.Count - 1] }
        foreach ($e in $m.Edges) {
            if ($e.To -ceq $gid) { $e.To = $in }
            if ($e.From -ceq $gid) { $e.From = $out }
        }
    }
    $m
}

$script:msgRe = [regex]::new('^(?<from>[^\s>:+-](?:[^>:]*?[^\s>:-])?)\s*(?<arrow><<-->>|<<->>|-->>|->>|--x|-x|--\)|-\)|-->|->)\s*(?<act>[+-])?\s*(?<to>[^\s:+-][^:]*?)\s*(?::\s*(?<text>.*))?$')

function Add-WtMmdParticipant($M, [string]$Id, [string]$Label, [bool]$Actor) {
    if (-not $M.Participants.Contains($Id)) { $M.Participants[$Id] = @{ Id = $Id; Label = $Id; Actor = $false } }
    $p = $M.Participants[$Id]
    if ($Label) { $p.Label = ConvertTo-WtMmdText $Label }
    if ($Actor) { $p.Actor = $true }
}

function ConvertFrom-WtMmdSequence([string[]]$Stmts) {
    $m = @{ Type = 'sequence'; Participants = (New-WtMmdMap); Items = [System.Collections.Generic.List[object]]::new(); AutoNumber = $false; Title = '' }
    $open = [System.Collections.Generic.List[string]]::new()   # 열린 블록 (box는 그리지 않는다)
    for ($i = 1; $i -lt $Stmts.Count; $i++) {
        $s = $Stmts[$i] -replace '^create\s+', ''
        if ($s -match '^(participant|actor)\s+(.+?)(?:\s+as\s+(.+))?$') {
            Add-WtMmdParticipant $m $Matches[2].Trim() ([string]$Matches[3]) ($Matches[1] -eq 'actor')
            continue
        }
        if ($s -match '^autonumber\b') { $m.AutoNumber = $true; continue }
        if ($s -match '^title\s*:?\s*(.*)$') { $m.Title = $Matches[1]; continue }
        if ($s -match '^(activate|deactivate|destroy|links?|properties|details)\b') { continue }
        if ($s -match '^box\b') { $open.Add('box'); continue }
        if ($s -match '^(loop|alt|opt|par_over|par|critical|break|rect)\b\s*(.*)$') {
            $kind = $Matches[1]
            $open.Add($kind)
            $m.Items.Add(@{ K = 'start'; Kind = $kind; Text = $(if ($kind -eq 'rect') { '' } else { ConvertTo-WtMmdText $Matches[2] }) })
            continue
        }
        if ($s -match '^(else|and|option)\b\s*(.*)$') { $m.Items.Add(@{ K = 'else'; Text = (ConvertTo-WtMmdText $Matches[2]) }); continue }
        if ($s -match '^end$') {
            if ($open.Count) {
                $k = $open[$open.Count - 1]
                $open.RemoveAt($open.Count - 1)
                if ($k -ne 'box') { $m.Items.Add(@{ K = 'end' }) }
            }
            continue
        }
        if ($s -match '^note\s+(left of|right of|over)\s+([^:]+?)\s*:\s*(.*)$') {
            $pos = ($Matches[1] -split ' ')[0]
            $text = ConvertTo-WtMmdText $Matches[3]
            $ids = @($Matches[2] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            foreach ($id in $ids) { Add-WtMmdParticipant $m $id '' $false }
            $m.Items.Add(@{ K = 'note'; Pos = $pos; Ids = $ids; Text = $text })
            continue
        }
        $mm = $script:msgRe.Match($s)
        if ($mm.Success) {
            $from = $mm.Groups['from'].Value.Trim()
            $to = $mm.Groups['to'].Value.Trim()
            Add-WtMmdParticipant $m $from '' $false
            Add-WtMmdParticipant $m $to '' $false
            $a = $mm.Groups['arrow'].Value
            $head = if ($a.EndsWith('>>')) { 'arrow' } elseif ($a.EndsWith('x')) { 'cross' } elseif ($a.EndsWith(')')) { 'async' } else { 'none' }
            $m.Items.Add(@{
                    K = 'msg'; From = $from; To = $to; Text = (ConvertTo-WtMmdText $mm.Groups['text'].Value)
                    Line = $(if ($a.Contains('--')) { 'dashed' } else { 'normal' }); Head = $head; Both = $a.StartsWith('<<')
                })
        }
    }
    if (-not $m.Participants.Count) { throw '참여자(participant)나 메시지가 없습니다.' }
    $m
}

# ---- 모델 → 도형 목록 (WPF 없이) ---------------------------------------------------------------

<#
도형 목록 (좌표는 epx, 왼쪽 위가 0,0)
  node   Shape X Y W H Text TH [Fill Line]   노드 · 참여자 · 노트 (글은 가운데)
  rect   X Y W H Fill Line Dash Radius       subgraph · 블록 틀
  text   X Y W Text Size Align Bold Color Bg  라벨 · 제목
  line   Pts(x,y,x,y…) Style Start End Smooth 선 (끝: arrow · circle · cross · async · none)
  actor  X Y W H                             사람 모양
#>
function Get-WtMermaidLayout($Model, [scriptblock]$Measure) {
    if (-not $Measure) { $Measure = { param($t, $s) Measure-WtMmdTextEstimate $t $s } }
    switch ($Model.Type) {
        'flowchart' { return Get-WtMmdFlowLayout $Model $Measure }
        'sequence' { return Get-WtMmdSeqLayout $Model $Measure }
    }
    throw "알 수 없는 다이어그램: $($Model.Type)"
}

# 글자 크기 어림 (WPF가 없을 때: 테스트용). 한글 1em, 영문 약 0.58em
function Measure-WtMmdTextEstimate([string]$Text, [string]$Size) {
    $em = Get-WtFontSize $Size
    $w = 0.0
    $lines = @(([string]$Text) -split "`n")
    foreach ($l in $lines) {
        $lw = 0.0
        foreach ($ch in $l.ToCharArray()) {
            $lw += if ([int]$ch -ge 0x1100) { $em } elseif ('iljtf.,:;|!''I '.IndexOf($ch) -ge 0) { $em * 0.32 } elseif ('mwMW@'.IndexOf($ch) -ge 0) { $em * 0.85 } else { $em * 0.58 }
        }
        $w = [Math]::Max($w, $lw)
    }
    @{ W = [Math]::Ceiling($w); H = [Math]::Ceiling($lines.Count * $em * 1.35) }
}

function Get-WtMmdNodeSize($N, $Measure) {
    $g = $script:gap
    switch ($N.Shape) {
        'start' { return @{ W = 16; H = 16; TH = 0 } }
        'end' { return @{ W = 20; H = 20; TH = 0 } }
        'fork' { return @{ W = 72; H = 8; TH = 0 } }
        'choice' { return @{ W = 28; H = 28; TH = 0 } }
    }
    $t = & $Measure $N.Text 'Body'
    $tw = $t.W
    $th = $t.H
    $w = $tw + 2 * $g.PadX
    $h = $th + 2 * $g.PadY
    switch ($N.Shape) {
        'diamond' { $w = $tw * 1.6 + 24; $h = $th * 2.4 + 12 }
        'circle' { $w = [Math]::Sqrt($tw * $tw + $th * $th) + 16; $h = $w }
        'dcircle' { $w = [Math]::Sqrt($tw * $tw + $th * $th) + 28; $h = $w }
        'hexagon' { $w += $h * 0.5 }
        { $_ -in 'para', 'paraAlt', 'trap', 'trapAlt' } { $w += $h * 0.8 }
        'asym' { $w += $h * 0.4 }
        'stadium' { $w += $h * 0.3 }
        'cylinder' { $h += 16 }
        'subroutine' { $w += 16 }
    }
    @{ W = [Math]::Max([Math]::Ceiling($w), 40); H = [Math]::Ceiling($h); TH = $th }
}

# 노드 가장자리와 (중심 → 목표점) 선이 만나는 점
function Get-WtMmdClip($Vx, [double]$Cx, [double]$Cy, [double]$Tx, [double]$Ty) {
    if ($Vx.Dummy) { return @($Cx, $Cy) }
    $dx = $Tx - $Cx
    $dy = $Ty - $Cy
    if ([Math]::Abs($dx) -lt 0.01 -and [Math]::Abs($dy) -lt 0.01) { return @($Cx, $Cy) }
    $hw = $Vx.W / 2
    $hh = $Vx.H / 2
    $t = switch ($Vx.Shape) {
        { $_ -in 'circle', 'dcircle', 'start', 'end' } { $hw / [Math]::Sqrt($dx * $dx + $dy * $dy) }
        { $_ -in 'diamond', 'choice' } { 1 / ([Math]::Abs($dx) / $hw + [Math]::Abs($dy) / $hh) }
        default {
            $fx = if ([Math]::Abs($dx) -gt 0.001) { $hw / [Math]::Abs($dx) } else { [double]::MaxValue }
            $fy = if ([Math]::Abs($dy) -gt 0.001) { $hh / [Math]::Abs($dy) } else { [double]::MaxValue }
            [Math]::Min($fx, $fy)
        }
    }
    if ($t -gt 1) { $t = 1 }
    @(($Cx + $dx * $t), ($Cy + $dy * $t))
}

<#
flowchart 배치 (층 나누기 방식)
1. 순환을 끊는다: 깊이 우선으로 돌며 거꾸로 가는 선은 배치할 때만 뒤집는다
2. 층: 가장 긴 경로. 선 하나는 두 층 이상 건너고, 가운데 층에 라벨 자리를 둔다
3. 두 층 넘게 건너는 선은 층마다 지나가는 점을 둔다
4. 층 안 순서: 이웃의 평균 위치로 위아래 번갈아 정렬. 같은 subgraph는 붙여 둔다
5. 좌표: 이웃 평균 쪽으로 당기면서 간격을 지킨다
#>
function Get-WtMmdFlowLayout($M, $Measure) {
    $g = $script:gap
    $horiz = $M.Dir -in 'LR', 'RL'
    $verts = [System.Collections.Generic.List[hashtable]]::new()
    $index = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    foreach ($id in $M.Nodes.Keys) {
        $n = $M.Nodes[$id]
        $sz = Get-WtMmdNodeSize $n $Measure
        if ($horiz -and $n.Shape -eq 'fork') { $sz = @{ W = $sz.H; H = $sz.W; TH = 0 } }
        $index[$id] = $verts.Count
        $verts.Add(@{ Id = $id; Text = $n.Text; Shape = $n.Shape; W = $sz.W; H = $sz.H; TH = $sz.TH; Dummy = $false; Group = $n.Group; Rank = 0; Extra = 0.0; Self = $null })
    }
    $real = $verts.Count
    if (-not $real) { throw '노드가 없습니다.' }

    $edges = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($e in $M.Edges) {
        if (-not $index.ContainsKey($e.From) -or -not $index.ContainsKey($e.To)) { continue }
        $a = $index[$e.From]
        $b = $index[$e.To]
        if ($a -eq $b) {
            # 자기 자신으로 가는 선: 노드 옆에 고리로 그린다
            $lw = if ($e.Text) { (& $Measure $e.Text 'Small').W + 8 } else { 0 }
            $verts[$a].Self = $e
            $verts[$a].Extra = [Math]::Max($verts[$a].Extra, 30 + $lw)
            continue
        }
        $edges.Add(@{ A = $a; B = $b; E = $e; Rev = $false })
    }

    # 1. 순환 끊기
    $outE = @(for ($i = 0; $i -lt $real; $i++) { , [System.Collections.Generic.List[int]]::new() })
    for ($k = 0; $k -lt $edges.Count; $k++) { $outE[$edges[$k].A].Add($k) }
    $state = [int[]]::new($real)
    for ($r = 0; $r -lt $real; $r++) {
        if ($state[$r]) { continue }
        $st = [System.Collections.Generic.Stack[int[]]]::new()
        $st.Push([int[]]@($r, 0))
        $state[$r] = 1
        while ($st.Count) {
            $top = $st.Peek()
            $v = $top[0]
            if ($top[1] -lt $outE[$v].Count) {
                $ei = $outE[$v][$top[1]]
                $top[1]++
                $w = $edges[$ei].B
                if ($state[$w] -eq 1) { $edges[$ei].Rev = $true }
                elseif ($state[$w] -eq 0) { $state[$w] = 1; $st.Push([int[]]@($w, 0)) }
            } else {
                $state[$v] = 2
                [void]$st.Pop()
            }
        }
    }
    foreach ($e in $edges) { if ($e.Rev) { $t = $e.A; $e.A = $e.B; $e.B = $t } }

    # 2. 층 (가장 긴 경로, 선 길이 x2)
    $outE = @(for ($i = 0; $i -lt $real; $i++) { , [System.Collections.Generic.List[int]]::new() })
    $inCount = [int[]]::new($real)
    for ($k = 0; $k -lt $edges.Count; $k++) { $outE[$edges[$k].A].Add($k); $inCount[$edges[$k].B]++ }
    $rank = [int[]]::new($real)
    $deg = [int[]]$inCount.Clone()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    for ($i = 0; $i -lt $real; $i++) { if (-not $deg[$i]) { $queue.Enqueue($i) } }
    $topo = [System.Collections.Generic.List[int]]::new()
    while ($queue.Count) {
        $v = $queue.Dequeue()
        $topo.Add($v)
        foreach ($k in $outE[$v]) {
            $w = $edges[$k].B
            $rank[$w] = [Math]::Max($rank[$w], $rank[$v] + 2 * $edges[$k].E.Len)
            $deg[$w]--
            if (-not $deg[$w]) { $queue.Enqueue($w) }
        }
    }
    # 들어오는 선이 없는 노드는 나가는 선 쪽으로 붙인다 (맨 위에 혼자 떨어져 있지 않게)
    for ($j = $topo.Count - 1; $j -ge 0; $j--) {
        $v = $topo[$j]
        if ($inCount[$v] -or -not $outE[$v].Count) { continue }
        $best = [int]::MaxValue
        foreach ($k in $outE[$v]) { $best = [Math]::Min($best, $rank[$edges[$k].B] - 2 * $edges[$k].E.Len) }
        if ($best -gt $rank[$v]) { $rank[$v] = $best }
    }
    for ($i = 0; $i -lt $real; $i++) { $verts[$i].Rank = $rank[$i] }

    # 3. 지나가는 점 · 라벨 점
    $chains = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($e in $edges) {
        $ra = $verts[$e.A].Rank
        $rb = $verts[$e.B].Rank
        $mid = $ra + [int][Math]::Floor(($rb - $ra) / 2)
        $grp = if ($verts[$e.A].Group -and $verts[$e.A].Group -ceq $verts[$e.B].Group) { $verts[$e.A].Group } else { $null }
        $chain = [System.Collections.Generic.List[int]]::new()
        $chain.Add($e.A)
        $labelAt = -1
        for ($r = $ra + 1; $r -lt $rb; $r++) {
            $d = @{ Id = ''; Dummy = $true; W = 0.0; H = 0.0; Group = $grp; Rank = $r; Extra = 0.0; Shape = '' }
            if ($r -eq $mid -and $e.E.Text) {
                $t = & $Measure $e.E.Text 'Small'
                $d.W = $t.W + 8
                $d.H = $t.H + 4
                $d.Label = $e.E.Text
                $labelAt = $chain.Count
            }
            $chain.Add($verts.Count)
            $verts.Add($d)
        }
        $chain.Add($e.B)
        $chains.Add(@{ Chain = $chain.ToArray(); E = $e.E; Rev = $e.Rev; LabelAt = $labelAt })
    }

    # 4. 층 안 순서
    $rankCount = 0
    foreach ($x in $verts) { $rankCount = [Math]::Max($rankCount, $x.Rank + 1) }
    $layers = @(for ($r = 0; $r -lt $rankCount; $r++) { , [System.Collections.Generic.List[int]]::new() })
    for ($i = 0; $i -lt $verts.Count; $i++) { $layers[$verts[$i].Rank].Add($i) }
    $up = @(for ($i = 0; $i -lt $verts.Count; $i++) { , [System.Collections.Generic.List[int]]::new() })
    $down = @(for ($i = 0; $i -lt $verts.Count; $i++) { , [System.Collections.Generic.List[int]]::new() })
    foreach ($c in $chains) {
        for ($k = 0; $k -lt $c.Chain.Count - 1; $k++) { $down[$c.Chain[$k]].Add($c.Chain[$k + 1]); $up[$c.Chain[$k + 1]].Add($c.Chain[$k]) }
    }
    $order = [double[]]::new($verts.Count)
    foreach ($l in $layers) { for ($i = 0; $i -lt $l.Count; $i++) { $order[$l[$i]] = $i } }
    for ($iter = 0; $iter -lt 6; $iter++) {
        for ($r = 1; $r -lt $rankCount; $r++) { Sort-WtMmdLayer $layers[$r] $up $order $verts $M }
        for ($r = $rankCount - 2; $r -ge 0; $r--) { Sort-WtMmdLayer $layers[$r] $down $order $verts $M }
    }

    # 5. 좌표 (cs: 층 안 방향 크기, ms: 층 방향 크기)
    $cs = [double[]]::new($verts.Count)
    $ms = [double[]]::new($verts.Count)
    for ($i = 0; $i -lt $verts.Count; $i++) {
        $cs[$i] = if ($horiz) { $verts[$i].H } else { $verts[$i].W }
        $ms[$i] = if ($horiz) { $verts[$i].W } else { $verts[$i].H }
    }
    $titleH = (& $Measure 'Ag' 'Small').H + 6
    $gaps = @(foreach ($l in $layers) {
            $arr = [double[]]::new([Math]::Max(0, $l.Count - 1))
            for ($i = 0; $i -lt $l.Count - 1; $i++) {
                $a = $verts[$l[$i]]
                $b = $verts[$l[$i + 1]]
                $sep = if ($a.Dummy -or $b.Dummy) { $g.DummySep } else { $g.NodeSep }
                if (($a.Group -or $b.Group) -and -not ($a.Group -ceq $b.Group)) { $sep += 2 * $g.GroupPad + $(if ($horiz) { $titleH } else { 0 }) }
                $extra = if ($horiz) { 0 } else { $a.Extra }
                $arr[$i] = ($cs[$l[$i]] + $cs[$l[$i + 1]]) / 2 + $sep + $extra
            }
            , $arr
        })
    $x = [double[]]::new($verts.Count)
    for ($r = 0; $r -lt $rankCount; $r++) {
        $l = $layers[$r]
        if (-not $l.Count) { continue }
        $x[$l[0]] = 0
        for ($i = 1; $i -lt $l.Count; $i++) { $x[$l[$i]] = $x[$l[$i - 1]] + $gaps[$r][$i - 1] }
        $shift = ($x[$l[0]] + $x[$l[$l.Count - 1]]) / 2
        foreach ($v in $l) { $x[$v] -= $shift }
    }
    for ($iter = 0; $iter -lt 8; $iter++) {
        for ($r = 1; $r -lt $rankCount; $r++) { Set-WtMmdLayerX $layers[$r] $gaps[$r] $up $x }
        for ($r = $rankCount - 2; $r -ge 0; $r--) { Set-WtMmdLayerX $layers[$r] $gaps[$r] $down $x }
    }

    # 층 위치
    $band = [double[]]::new($rankCount)
    for ($i = 0; $i -lt $verts.Count; $i++) { $band[$verts[$i].Rank] = [Math]::Max($band[$verts[$i].Rank], $ms[$i]) }
    $mainPos = [double[]]::new($rankCount)
    $cursor = 0.0
    for ($r = 0; $r -lt $rankCount; $r++) { $mainPos[$r] = $cursor + $band[$r] / 2; $cursor += $band[$r] + $g.RankGap }
    $total = $cursor - $g.RankGap
    $cx = [double[]]::new($verts.Count)
    $cy = [double[]]::new($verts.Count)
    for ($i = 0; $i -lt $verts.Count; $i++) {
        $mp = $mainPos[$verts[$i].Rank]
        if ($M.Dir -in 'BT', 'RL') { $mp = $total - $mp }
        if ($horiz) { $cx[$i] = $mp; $cy[$i] = $x[$i] } else { $cx[$i] = $x[$i]; $cy[$i] = $mp }
    }

    # subgraph 상자 (안쪽 것부터)
    $depth = @{}
    foreach ($gid in $M.Groups.Keys) {
        $d = 0; $p = $M.Groups[$gid].Parent
        while ($p -and $d -lt 50) { $d++; $p = $M.Groups[$p].Parent }
        $depth[$gid] = $d
    }
    $boxes = New-WtMmdMap
    foreach ($gid in @($M.Groups.Keys | Sort-Object { - $depth[$_] })) {
        $l = [double]::MaxValue; $t = [double]::MaxValue; $rr = [double]::MinValue; $b = [double]::MinValue
        for ($i = 0; $i -lt $real; $i++) {
            if (-not ($verts[$i].Group -ceq $gid)) { continue }
            $l = [Math]::Min($l, $cx[$i] - $verts[$i].W / 2); $rr = [Math]::Max($rr, $cx[$i] + $verts[$i].W / 2 + $(if ($horiz) { 0 } else { $verts[$i].Extra }))
            $t = [Math]::Min($t, $cy[$i] - $verts[$i].H / 2); $b = [Math]::Max($b, $cy[$i] + $verts[$i].H / 2 + $(if ($horiz) { $verts[$i].Extra } else { 0 }))
        }
        foreach ($cid in $boxes.Keys) {
            if (-not ($M.Groups[$cid].Parent -ceq $gid)) { continue }
            $cb = $boxes[$cid]
            $l = [Math]::Min($l, $cb.X); $t = [Math]::Min($t, $cb.Y); $rr = [Math]::Max($rr, $cb.X + $cb.W); $b = [Math]::Max($b, $cb.Y + $cb.H)
        }
        if ($l -eq [double]::MaxValue) { continue }
        $title = [string]$M.Groups[$gid].Title
        $tsz = if ($title) { & $Measure $title 'Small' } else { @{ W = 0; H = 0 } }
        $l -= $g.GroupPad; $rr += $g.GroupPad; $b += $g.GroupPad
        $t -= $g.GroupPad + $(if ($title) { $tsz.H + 4 } else { 0 })
        if ($rr - $l -lt $tsz.W + 2 * $g.GroupPad) { $rr = $l + $tsz.W + 2 * $g.GroupPad }
        $boxes[$gid] = @{ X = $l; Y = $t; W = $rr - $l; H = $b - $t; Title = $title }
    }

    # 선 점
    $lines = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($c in $chains) {
        $ids = $c.Chain
        $pts = [System.Collections.Generic.List[double]]::new()
        foreach ($v in $ids) { $pts.Add($cx[$v]); $pts.Add($cy[$v]) }
        $n = $ids.Count
        $p0 = Get-WtMmdClip $verts[$ids[0]] $pts[0] $pts[1] $pts[2] $pts[3]
        $pn = Get-WtMmdClip $verts[$ids[$n - 1]] $pts[2 * $n - 2] $pts[2 * $n - 1] $pts[2 * $n - 4] $pts[2 * $n - 3]
        $pts[0] = $p0[0]; $pts[1] = $p0[1]; $pts[2 * $n - 2] = $pn[0]; $pts[2 * $n - 1] = $pn[1]
        $arr = $pts.ToArray()
        if ($c.Rev) {
            $rev = [double[]]::new($arr.Length)
            for ($k = 0; $k -lt $n; $k++) { $rev[2 * $k] = $arr[2 * ($n - 1 - $k)]; $rev[2 * $k + 1] = $arr[2 * ($n - 1 - $k) + 1] }
            $arr = $rev
        }
        $lbl = $null
        if ($c.LabelAt -ge 0) {
            $d = $verts[$ids[$c.LabelAt]]
            $lbl = @{ X = $cx[$ids[$c.LabelAt]] - $d.W / 2; Y = $cy[$ids[$c.LabelAt]] - $d.H / 2; W = $d.W; H = $d.H; Text = $d.Label }
        }
        $lines.Add(@{ Pts = $arr; E = $c.E; Label = $lbl })
    }
    # 자기 자신으로 가는 고리
    for ($i = 0; $i -lt $real; $i++) {
        $se = $verts[$i].Self
        if (-not $se) { continue }
        $hw = $verts[$i].W / 2; $hh = $verts[$i].H / 2
        if ($horiz) {
            $pts = [double[]]@(($cx[$i] - 8), ($cy[$i] + $hh), ($cx[$i] - 12), ($cy[$i] + $hh + 24), ($cx[$i] + 12), ($cy[$i] + $hh + 24), ($cx[$i] + 8), ($cy[$i] + $hh))
            $lpos = @(($cx[$i] + 16), ($cy[$i] + $hh + 14))
        } else {
            $pts = [double[]]@(($cx[$i] + $hw), ($cy[$i] - 8), ($cx[$i] + $hw + 24), ($cy[$i] - 12), ($cx[$i] + $hw + 24), ($cy[$i] + 12), ($cx[$i] + $hw), ($cy[$i] + 8))
            $lpos = @(($cx[$i] + $hw + 30), $cy[$i])
        }
        $lbl = $null
        if ($se.Text) {
            $t = & $Measure $se.Text 'Small'
            $lbl = @{ X = $lpos[0]; Y = $lpos[1] - ($t.H + 4) / 2; W = $t.W + 8; H = $t.H + 4; Text = $se.Text }
        }
        $lines.Add(@{ Pts = $pts; E = $se; Label = $lbl })
    }

    # 왼쪽 위를 여백에 맞춘다
    $minX = [double]::MaxValue; $minY = [double]::MaxValue; $maxX = [double]::MinValue; $maxY = [double]::MinValue
    for ($i = 0; $i -lt $verts.Count; $i++) {
        $minX = [Math]::Min($minX, $cx[$i] - $verts[$i].W / 2); $maxX = [Math]::Max($maxX, $cx[$i] + $verts[$i].W / 2)
        $minY = [Math]::Min($minY, $cy[$i] - $verts[$i].H / 2); $maxY = [Math]::Max($maxY, $cy[$i] + $verts[$i].H / 2)
    }
    foreach ($bx in $boxes.Values) {
        $minX = [Math]::Min($minX, $bx.X); $maxX = [Math]::Max($maxX, $bx.X + $bx.W)
        $minY = [Math]::Min($minY, $bx.Y); $maxY = [Math]::Max($maxY, $bx.Y + $bx.H)
    }
    foreach ($ln in $lines) {
        for ($k = 0; $k -lt $ln.Pts.Length; $k += 2) {
            $minX = [Math]::Min($minX, $ln.Pts[$k]); $maxX = [Math]::Max($maxX, $ln.Pts[$k])
            $minY = [Math]::Min($minY, $ln.Pts[$k + 1]); $maxY = [Math]::Max($maxY, $ln.Pts[$k + 1])
        }
        if ($ln.Label) { $maxX = [Math]::Max($maxX, $ln.Label.X + $ln.Label.W); $maxY = [Math]::Max($maxY, $ln.Label.Y + $ln.Label.H) }
    }
    $items = [System.Collections.Generic.List[hashtable]]::new()
    $top = $g.Margin
    if ($M.Title) {
        $ts = & $Measure $M.Title 'Body'
        $items.Add(@{ K = 'text'; X = $g.Margin; Y = $g.Margin; W = [Math]::Max($ts.W, $maxX - $minX); Text = $M.Title; Size = 'Body'; Align = 'Center'; Bold = $true; Color = 'Text' })
        $top += $ts.H + 12
    }
    $ox = $g.Margin - $minX
    $oy = $top - $minY

    foreach ($gid in @($boxes.Keys | Sort-Object { $depth[$_] })) {
        $bx = $boxes[$gid]
        $items.Add(@{ K = 'rect'; X = $bx.X + $ox; Y = $bx.Y + $oy; W = $bx.W; H = $bx.H; Fill = 'Dia.GroupBg'; Line = 'Dia.GroupLine'; Radius = 6 })
        if ($bx.Title) {
            $items.Add(@{ K = 'text'; X = $bx.X + $ox + $g.GroupPad; Y = $bx.Y + $oy + 4; W = $bx.W - 2 * $g.GroupPad; Text = $bx.Title; Size = 'Small'; Align = 'Left'; Color = 'SubText' })
        }
    }
    foreach ($ln in $lines) {
        if ($ln.E.Style -eq 'invisible') { continue }
        $pts = [double[]]::new($ln.Pts.Length)
        for ($k = 0; $k -lt $pts.Length; $k += 2) { $pts[$k] = $ln.Pts[$k] + $ox; $pts[$k + 1] = $ln.Pts[$k + 1] + $oy }
        $items.Add(@{ K = 'line'; Pts = $pts; Style = $ln.E.Style; Start = $ln.E.Start; End = $ln.E.End; Smooth = $true })
    }
    for ($i = 0; $i -lt $real; $i++) {
        $v = $verts[$i]
        $items.Add(@{ K = 'node'; Shape = $v.Shape; X = $cx[$i] - $v.W / 2 + $ox; Y = $cy[$i] - $v.H / 2 + $oy; W = $v.W; H = $v.H; Text = $v.Text; TH = $v.TH })
    }
    foreach ($ln in $lines) {
        if (-not $ln.Label) { continue }
        $lb = $ln.Label
        $items.Add(@{ K = 'text'; X = $lb.X + $ox; Y = $lb.Y + $oy; W = $lb.W; H = $lb.H; Text = $lb.Text; Size = 'Small'; Align = 'Center'; Color = 'Text'; Bg = 'Card' })
    }
    @{ Width = [Math]::Ceiling($maxX - $minX + 2 * $g.Margin); Height = [Math]::Ceiling($maxY - $minY + $top + $g.Margin); Items = $items.ToArray() }
}

# 층 하나를 이웃(위 또는 아래 층)의 평균 순번으로 정렬한다. 같은 subgraph는 그 평균으로 묶는다
function Sort-WtMmdLayer($Layer, $Nbr, [double[]]$Order, $verts, $M) {
    if ($Layer.Count -lt 2) { return }
    $key = @{}
    foreach ($v in $Layer) {
        $ns = $Nbr[$v]
        if ($ns.Count) {
            $sum = 0.0
            foreach ($u in $ns) { $sum += $Order[$u] }
            $key[$v] = $sum / $ns.Count
        } else { $key[$v] = $Order[$v] }
    }
    # 가장 바깥 subgraph와 자기 subgraph의 평균
    $outer = @{}
    $groupSum = @{}
    $groupCnt = @{}
    foreach ($v in $Layer) {
        $gname = $verts[$v].Group
        $top = $gname
        $guard = 0
        while ($top -and $M.Groups -and $M.Groups.Contains($top) -and $M.Groups[$top].Parent -and $guard -lt 50) { $top = $M.Groups[$top].Parent; $guard++ }
        $outer[$v] = $top
        foreach ($k in @($gname, "^$top")) {
            if (-not $k -or $k -eq '^') { continue }
            $groupSum[$k] = [double]$groupSum[$k] + $key[$v]
            $groupCnt[$k] = [int]$groupCnt[$k] + 1
        }
    }
    $rows = foreach ($v in $Layer) {
        $k1 = if ($outer[$v]) { $groupSum["^$($outer[$v])"] / $groupCnt["^$($outer[$v])"] } else { $key[$v] }
        $k2 = if ($verts[$v].Group) { $groupSum[$verts[$v].Group] / $groupCnt[$verts[$v].Group] } else { $key[$v] }
        [pscustomobject]@{ V = $v; K1 = $k1; K2 = $k2; K3 = $key[$v]; K4 = $Order[$v] }
    }
    $sorted = @($rows | Sort-Object K1, K2, K3, K4)
    $Layer.Clear()
    for ($i = 0; $i -lt $sorted.Count; $i++) { $Layer.Add($sorted[$i].V); $Order[$sorted[$i].V] = $i }
}

# 층 하나의 좌표: 이웃 평균 위치로 당기되 순서와 간격은 지킨다 (왼쪽에서 · 오른쪽에서 한 번씩 놓고 평균)
function Set-WtMmdLayerX($Layer, [double[]]$Gaps, $Nbr, [double[]]$X) {
    $n = $Layer.Count
    if (-not $n) { return }
    $d = [double[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) {
        $v = $Layer[$i]
        $ns = $Nbr[$v]
        if ($ns.Count) {
            $sum = 0.0
            foreach ($u in $ns) { $sum += $X[$u] }
            $d[$i] = $sum / $ns.Count
        } else { $d[$i] = $X[$v] }
    }
    $a = [double[]]::new($n)
    $b = [double[]]::new($n)
    $a[0] = $d[0]
    for ($i = 1; $i -lt $n; $i++) { $a[$i] = [Math]::Max($d[$i], $a[$i - 1] + $Gaps[$i - 1]) }
    $b[$n - 1] = $d[$n - 1]
    for ($i = $n - 2; $i -ge 0; $i--) { $b[$i] = [Math]::Min($d[$i], $b[$i + 1] - $Gaps[$i]) }
    $prev = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $val = ($a[$i] + $b[$i]) / 2
        if ($i -gt 0) { $val = [Math]::Max($val, $prev + $Gaps[$i - 1]) }
        $X[$Layer[$i]] = $val
        $prev = $val
    }
}

function Get-WtMmdSeqLayout($M, $Measure) {
    $g = $script:gap
    $items = [System.Collections.Generic.List[hashtable]]::new()
    $parts = @($M.Participants.Values)
    $n = $parts.Count
    $idx = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    for ($i = 0; $i -lt $n; $i++) { $idx[$parts[$i].Id] = $i }
    $boxW = [double[]]::new($n)
    $boxTH = [double[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) {
        $t = & $Measure $parts[$i].Label 'Body'
        $boxW[$i] = [Math]::Max($t.W + 2 * $g.PadX, 72)
        $boxTH[$i] = $t.H
    }
    $maxTH = ($boxTH | Measure-Object -Maximum).Maximum
    $boxH = $maxTH + 2 * $g.PadY
    $hasActor = @($parts | Where-Object { $_.Actor }).Count -gt 0
    $headH = if ($hasActor) { [Math]::Max($boxH, 36 + $maxTH) } else { $boxH }
    $gapX = [double[]]::new([Math]::Max(0, $n - 1))
    for ($i = 0; $i -lt $n - 1; $i++) { $gapX[$i] = ($boxW[$i] + $boxW[$i + 1]) / 2 + 28 }
    $leftExtra = 0.0
    $rightExtra = 0.0

    # 글 크기를 먼저 재서 가로 간격을 넓힌다
    $info = [System.Collections.Generic.List[hashtable]]::new()
    $num = 0
    foreach ($it in $M.Items) {
        $x = @{ It = $it }
        if ($it.K -eq 'msg') {
            $text = $it.Text
            if ($M.AutoNumber) { $num++; $text = if ($text) { "$num. $text" } else { "$num." } }
            $x.Text = $text
            $t = if ($text) { & $Measure $text 'Small' } else { @{ W = 0; H = 0 } }
            $x.TW = $t.W; $x.TH = $t.H
            $a = $idx[$it.From]; $b = $idx[$it.To]
            if ($a -eq $b) {
                $need = 40 + $t.W + 12
                if ($a -lt $n - 1) { $gapX[$a] = [Math]::Max($gapX[$a], $need) } else { $rightExtra = [Math]::Max($rightExtra, $need - $boxW[$a] / 2) }
            } else {
                $lo = [Math]::Min($a, $b); $hi = [Math]::Max($a, $b)
                $need = $t.W + 24
                $sum = 0.0
                for ($k = $lo; $k -lt $hi; $k++) { $sum += $gapX[$k] }
                if ($sum -lt $need) { for ($k = $lo; $k -lt $hi; $k++) { $gapX[$k] += ($need - $sum) / ($hi - $lo) } }
            }
        } elseif ($it.K -eq 'note') {
            $t = & $Measure $it.Text 'Small'
            $x.TW = $t.W; $x.TH = $t.H
            $nw = $t.W + 20
            $ids = @($it.Ids | ForEach-Object { $idx[$_] })
            $i0 = ($ids | Measure-Object -Minimum).Minimum
            $i1 = ($ids | Measure-Object -Maximum).Maximum
            switch ($it.Pos) {
                'left' { if ($i0 -eq 0) { $leftExtra = [Math]::Max($leftExtra, $nw + 10 - $boxW[0] / 2) } else { $gapX[$i0 - 1] = [Math]::Max($gapX[$i0 - 1], $nw + 20) } }
                'right' { if ($i1 -eq $n - 1) { $rightExtra = [Math]::Max($rightExtra, $nw + 10 - $boxW[$i1] / 2) } else { $gapX[$i1] = [Math]::Max($gapX[$i1], $nw + 20) } }
                default {
                    if ($i0 -eq 0) { $leftExtra = [Math]::Max($leftExtra, $nw / 2 - $boxW[0] / 2) }
                    if ($i1 -eq $n - 1) { $rightExtra = [Math]::Max($rightExtra, $nw / 2 - $boxW[$i1] / 2) }
                }
            }
        } elseif ($it.K -in 'start', 'else') {
            $t = & $Measure $(if ($it.Text) { "[$($it.Text)]" } else { 'Ag' }) 'Small'
            $x.TW = $t.W; $x.TH = $t.H
        }
        $info.Add($x)
    }
    $cx = [double[]]::new($n)
    $cx[0] = $g.Margin + [Math]::Max(0, $leftExtra) + $boxW[0] / 2
    for ($i = 1; $i -lt $n; $i++) { $cx[$i] = $cx[$i - 1] + $gapX[$i - 1] }

    $top = $g.Margin
    if ($M.Title) {
        $ts = & $Measure $M.Title 'Body'
        $items.Add(@{ K = 'text'; X = $g.Margin; Y = $top; W = [Math]::Max($ts.W, $cx[$n - 1] + $boxW[$n - 1] / 2 - $g.Margin); Text = $M.Title; Size = 'Body'; Align = 'Center'; Bold = $true; Color = 'Text' })
        $top += $ts.H + 12
    }
    $y = $top + $headH + 20
    $frames = [System.Collections.Generic.List[hashtable]]::new()
    $frameItems = [System.Collections.Generic.List[hashtable]]::new()
    $body = [System.Collections.Generic.List[hashtable]]::new()
    $maxRight = $cx[$n - 1] + $boxW[$n - 1] / 2 + [Math]::Max(0, $rightExtra)
    foreach ($x in $info) {
        $it = $x.It
        switch ($it.K) {
            'msg' {
                $a = $idx[$it.From]; $b = $idx[$it.To]
                if ($a -eq $b) {
                    $loopH = [Math]::Max(22, $x.TH)
                    $pts = [double[]]@($cx[$a], $y, ($cx[$a] + 30), $y, ($cx[$a] + 30), ($y + $loopH), $cx[$a], ($y + $loopH))
                    $body.Add(@{ K = 'line'; Pts = $pts; Style = $it.Line; Start = 'none'; End = $it.Head; Smooth = $false })
                    if ($x.Text) { $body.Add(@{ K = 'text'; X = $cx[$a] + 38; Y = $y + $loopH / 2 - $x.TH / 2; W = $x.TW; Text = $x.Text; Size = 'Small'; Align = 'Left'; Color = 'Text' }) }
                    Add-WtMmdFrameSpan $frames $a $a ($cx[$a] + 38 + $x.TW)
                    $y += $loopH + 18
                } else {
                    if ($x.Text) {
                        $mid = ($cx[$a] + $cx[$b]) / 2
                        $body.Add(@{ K = 'text'; X = $mid - $x.TW / 2; Y = $y; W = $x.TW; Text = $x.Text; Size = 'Small'; Align = 'Center'; Color = 'Text' })
                    }
                    $ly = $y + $x.TH + 4
                    $body.Add(@{ K = 'line'; Pts = [double[]]@($cx[$a], $ly, $cx[$b], $ly); Style = $it.Line; Start = $(if ($it.Both) { $it.Head } else { 'none' }); End = $it.Head; Smooth = $false })
                    Add-WtMmdFrameSpan $frames ([Math]::Min($a, $b)) ([Math]::Max($a, $b)) 0
                    $y = $ly + 18
                }
            }
            'note' {
                $ids = @($it.Ids | ForEach-Object { $idx[$_] })
                $i0 = ($ids | Measure-Object -Minimum).Minimum
                $i1 = ($ids | Measure-Object -Maximum).Maximum
                $nw = $x.TW + 20
                $nh = $x.TH + 12
                switch ($it.Pos) {
                    'left' { $nx = $cx[$i0] - 10 - $nw }
                    'right' { $nx = $cx[$i1] + 10 }
                    default {
                        if ($i0 -ne $i1) { $nw = [Math]::Max($nw, $cx[$i1] - $cx[$i0] + 40) }
                        $nx = ($cx[$i0] + $cx[$i1]) / 2 - $nw / 2
                    }
                }
                $body.Add(@{ K = 'node'; Shape = 'rect'; X = $nx; Y = $y; W = $nw; H = $nh; Text = $it.Text; TH = $x.TH; Size = 'Small'; Fill = 'Dia.NoteBg'; Line = 'Dia.NoteLine' })
                Add-WtMmdFrameSpan $frames $i0 $i1 ($nx + $nw)
                $maxRight = [Math]::Max($maxRight, $nx + $nw)
                $y += $nh + 14
            }
            'start' {
                $frames.Add(@{ Kind = $it.Kind; Text = $it.Text; Y = $y; Lo = -1; Hi = -1; MaxX = 0.0; Inner = 0; Elses = [System.Collections.Generic.List[hashtable]]::new(); TH = $x.TH })
                $y += $x.TH + 6 + 12
            }
            'else' {
                if ($frames.Count) { $frames[$frames.Count - 1].Elses.Add(@{ Y = $y; Text = $it.Text; TW = $x.TW }) }
                $y += $x.TH + 14
            }
            'end' {
                if (-not $frames.Count) { break }
                $f = $frames[$frames.Count - 1]
                $frames.RemoveAt($frames.Count - 1)
                $lo = if ($f.Lo -ge 0) { $f.Lo } else { 0 }
                $hi = if ($f.Hi -ge 0) { $f.Hi } else { $n - 1 }
                $left = $cx[$lo] - $boxW[$lo] / 2 - 6 - $f.Inner * 6
                $right = [Math]::Max($cx[$hi] + $boxW[$hi] / 2 + 6 + $f.Inner * 6, $f.MaxX + 10)
                $bottom = $y + 2
                $frameItems.Add(@{ K = 'rect'; X = $left; Y = $f.Y; W = $right - $left; H = $bottom - $f.Y; Fill = $null; Line = 'Dia.GroupLine'; Radius = 2 })
                $kt = & $Measure $f.Kind 'Small'
                $tabW = $kt.W + 16
                $frameItems.Add(@{ K = 'rect'; X = $left; Y = $f.Y; W = $tabW; H = $f.TH + 6; Fill = 'Dia.GroupBg'; Line = 'Dia.GroupLine'; Radius = 2 })
                $frameItems.Add(@{ K = 'text'; X = $left; Y = $f.Y + 3; W = $tabW; Text = $f.Kind; Size = 'Small'; Align = 'Center'; Bold = $true; Color = 'Text' })
                if ($f.Text) { $frameItems.Add(@{ K = 'text'; X = $left + $tabW + 8; Y = $f.Y + 3; W = [Math]::Max(10, $right - $left - $tabW - 12); Text = "[$($f.Text)]"; Size = 'Small'; Align = 'Left'; Color = 'SubText' }) }
                foreach ($el in $f.Elses) {
                    $frameItems.Add(@{ K = 'line'; Pts = [double[]]@($left, $el.Y, $right, $el.Y); Style = 'dashed'; Start = 'none'; End = 'none'; Smooth = $false; Color = 'Dia.GroupLine' })
                    if ($el.Text) { $frameItems.Add(@{ K = 'text'; X = $left + 8; Y = $el.Y + 3; W = $el.TW + 4; Text = "[$($el.Text)]"; Size = 'Small'; Align = 'Left'; Color = 'SubText' }) }
                }
                if ($frames.Count) {
                    $p = $frames[$frames.Count - 1]
                    $p.Inner = [Math]::Max($p.Inner, $f.Inner + 1)
                    $p.MaxX = [Math]::Max($p.MaxX, $right)
                    if ($p.Lo -lt 0 -or $lo -lt $p.Lo) { $p.Lo = $lo }
                    if ($hi -gt $p.Hi) { $p.Hi = $hi }
                }
                $maxRight = [Math]::Max($maxRight, $right)
                $y += 14
            }
        }
    }
    $bottomY = $y + 4
    $boxTop = $top
    foreach ($row in @($boxTop, $bottomY)) {
        for ($i = 0; $i -lt $n; $i++) {
            $p = $parts[$i]
            if ($p.Actor) {
                $items.Add(@{ K = 'actor'; X = $cx[$i] - 12; Y = $row; W = 24; H = 30 })
                $items.Add(@{ K = 'text'; X = $cx[$i] - $boxW[$i] / 2; Y = $row + 34; W = $boxW[$i]; Text = $p.Label; Size = 'Body'; Align = 'Center'; Color = 'Text' })
            } else {
                $items.Add(@{ K = 'node'; Shape = 'rect'; X = $cx[$i] - $boxW[$i] / 2; Y = $row + ($headH - $boxH); W = $boxW[$i]; H = $boxH; Text = $p.Label; TH = $boxTH[$i] })
            }
        }
    }
    $lifelines = for ($i = 0; $i -lt $n; $i++) {
        @{ K = 'line'; Pts = [double[]]@($cx[$i], ($boxTop + $headH), $cx[$i], $bottomY); Style = 'dashed'; Start = 'none'; End = 'none'; Smooth = $false; Color = 'Dia.GroupLine' }
    }
    $all = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($x in $frameItems) { if ($x.K -eq 'rect' -and -not $x.Fill) { $all.Add($x) } }
    foreach ($x in @($lifelines)) { $all.Add($x) }
    foreach ($x in $frameItems) { if (-not ($x.K -eq 'rect' -and -not $x.Fill)) { $all.Add($x) } }
    foreach ($x in $items) { $all.Add($x) }
    foreach ($x in $body) { $all.Add($x) }
    @{ Width = [Math]::Ceiling($maxRight + $g.Margin); Height = [Math]::Ceiling($bottomY + $headH + $g.Margin); Items = $all.ToArray() }
}

# 열린 블록 틀(loop 등) 모두에 이 메시지 · 노트가 걸친 참여자 범위를 넣는다
function Add-WtMmdFrameSpan($Frames, [int]$Lo, [int]$Hi, [double]$Right) {
    foreach ($f in $Frames) {
        if ($f.Lo -lt 0 -or $Lo -lt $f.Lo) { $f.Lo = $Lo }
        if ($Hi -gt $f.Hi) { $f.Hi = $Hi }
        if ($Right -gt $f.MaxX) { $f.MaxX = $Right }
    }
}

# ---- 도형 목록 → WPF -------------------------------------------------------------------------

$script:typeface = $null

# 지금 글자 크기 설정으로 글 크기를 잰다 (Get-WtFontSize: 설정에서 바로 읽음)
function Measure-WtMmdText([string]$Text, [string]$Size) {
    if (-not $script:typeface) {
        $script:typeface = [System.Windows.Media.Typeface]::new([System.Windows.Media.FontFamily]::new((Get-WtFontName 'UI')),
            [System.Windows.FontStyles]::Normal, [System.Windows.FontWeights]::Normal, [System.Windows.FontStretches]::Normal)
    }
    $em = Get-WtFontSize $Size
    $w = 0.0
    $h = 0.0
    foreach ($l in (([string]$Text) -split "`n")) {
        $ft = [System.Windows.Media.FormattedText]::new($(if ($l) { $l } else { ' ' }), [System.Globalization.CultureInfo]::CurrentUICulture,
            [System.Windows.FlowDirection]::LeftToRight, $script:typeface, $em, [System.Windows.Media.Brushes]::Black, 1.0)
        $w = [Math]::Max($w, $ft.WidthIncludingTrailingWhitespace)
        $h += $ft.Height
    }
    @{ W = [Math]::Ceiling($w) + 4; H = [Math]::Ceiling($h) }
}

# Mermaid 글 → 그림 요소. 폭이 모자라면 줄여서 보여 준다 (Viewbox, 키우지는 않음)
function New-WtMermaidView([string]$Code) {
    $model = ConvertFrom-WtMermaid $Code
    $layout = Get-WtMermaidLayout $model { param($t, $s) Measure-WtMmdText $t $s }
    $canvas = [System.Windows.Controls.Canvas]::new()
    $canvas.Width = $layout.Width
    $canvas.Height = $layout.Height
    $canvas.SnapsToDevicePixels = $true
    foreach ($it in $layout.Items) {
        foreach ($el in @(New-WtMmdElement $it)) { if ($el) { [void]$canvas.Children.Add($el) } }
    }
    $vb = [System.Windows.Controls.Viewbox]::new()
    $vb.Stretch = 'Uniform'
    $vb.StretchDirection = 'DownOnly'
    $vb.HorizontalAlignment = 'Center'
    $vb.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $vb.Child = $canvas
    $vb
}

function Set-WtMmdPos($El, [double]$X, [double]$Y) {
    [System.Windows.Controls.Canvas]::SetLeft($El, $X)
    [System.Windows.Controls.Canvas]::SetTop($El, $Y)
    $El
}

function New-WtMmdPoints([double[]]$P) {
    $c = [System.Windows.Media.PointCollection]::new()
    for ($i = 0; $i -lt $P.Length; $i += 2) { $c.Add([System.Windows.Point]::new($P[$i], $P[$i + 1])) }
    , $c   # 모음 그대로 돌려준다 (그냥 돌려주면 PowerShell이 낱개로 풀어 버린다)
}

function New-WtMmdTextBlock([string]$Text, [string]$Size, [string]$Align, [double]$boxW, [bool]$Bold, [string]$Color) {
    $t = [System.Windows.Controls.TextBlock]::new()
    $t.Text = $Text
    Set-WtResource $t 'FontFamily' 'Font.UI'
    Set-WtResource $t 'FontSize' "F.$Size"
    Set-WtResource $t 'Foreground' "B.$Color"
    $t.TextAlignment = $Align
    $t.Width = $boxW
    if ($Bold) { $t.FontWeight = 'SemiBold' }
    $t
}

function New-WtMmdElement($It) {
    switch ($It.K) {
        'rect' {
            $r = [System.Windows.Shapes.Rectangle]::new()
            $r.Width = $It.W; $r.Height = $It.H
            $r.RadiusX = [double]$It.Radius; $r.RadiusY = [double]$It.Radius
            if ($It.Fill) { Set-WtResource $r 'Fill' "B.$($It.Fill)" }
            Set-WtResource $r 'Stroke' "B.$($It.Line)"
            $r.StrokeThickness = 1
            return Set-WtMmdPos $r $It.X $It.Y
        }
        'text' {
            $size = if ($It.Size) { $It.Size } else { 'Body' }
            $t = New-WtMmdTextBlock $It.Text $size $It.Align $It.W ([bool]$It.Bold) $(if ($It.Color) { $It.Color } else { 'Text' })
            if ($It.Bg) {
                $b = [System.Windows.Controls.Border]::new()
                Set-WtResource $b 'Background' "B.$($It.Bg)"
                $b.CornerRadius = [System.Windows.CornerRadius]::new(3)
                $b.Width = $It.W
                $b.Height = $It.H
                $t.Width = [double]::NaN
                $t.VerticalAlignment = 'Center'
                $t.HorizontalAlignment = 'Center'
                $b.Child = $t
                return Set-WtMmdPos $b $It.X $It.Y
            }
            return Set-WtMmdPos $t $It.X $It.Y
        }
        'node' { return New-WtMmdNode $It }
        'line' { return New-WtMmdLine $It }
        'actor' {
            $p = [System.Windows.Shapes.Path]::new()
            $w = $It.W; $hh = $It.H
            $geo = "M $($w/2),11 L $($w/2),$($hh*0.68) M 1,$($hh*0.45) L $($w-1),$($hh*0.45) M $($w/2),$($hh*0.68) L 2,$hh M $($w/2),$($hh*0.68) L $($w-2),$hh"
            $p.Data = [System.Windows.Media.Geometry]::Parse($geo)
            Set-WtResource $p 'Stroke' 'B.Dia.Line'
            $p.StrokeThickness = 1.5
            $head = [System.Windows.Shapes.Ellipse]::new()
            $head.Width = 11; $head.Height = 11
            Set-WtResource $head 'Fill' 'B.Dia.NodeBg'
            Set-WtResource $head 'Stroke' 'B.Dia.Line'
            $head.StrokeThickness = 1.5
            return @((Set-WtMmdPos $p $It.X $It.Y), (Set-WtMmdPos $head ($It.X + $w / 2 - 5.5) $It.Y))
        }
    }
    $null
}

function New-WtMmdNode($It) {
    $w = [double]$It.W
    $hh = [double]$It.H
    $fill = if ($It.Fill) { "B.$($It.Fill)" } else { 'B.Dia.NodeBg' }
    $line = if ($It.Line) { "B.$($It.Line)" } else { 'B.Dia.NodeLine' }
    $shapes = [System.Collections.Generic.List[object]]::new()
    $k = [Math]::Min($hh / 2, $w / 4)
    switch ($It.Shape) {
        { $_ -in 'rect', 'round', 'stadium', 'subroutine' } {
            $r = [System.Windows.Shapes.Rectangle]::new()
            $rad = switch ($It.Shape) { 'round' { 10 } 'stadium' { $hh / 2 } default { 3 } }
            $r.RadiusX = $rad; $r.RadiusY = $rad
            $shapes.Add($r)
            if ($It.Shape -eq 'subroutine') {
                foreach ($lx in 8, ($w - 8)) {
                    $l = [System.Windows.Shapes.Line]::new()
                    $l.X1 = $lx; $l.X2 = $lx; $l.Y1 = 0; $l.Y2 = $hh
                    $shapes.Add($l)
                }
            }
        }
        { $_ -in 'circle', 'dcircle', 'start', 'end' } {
            $e = [System.Windows.Shapes.Ellipse]::new()
            $shapes.Add($e)
            if ($It.Shape -in 'dcircle', 'end') {
                $in = [System.Windows.Shapes.Ellipse]::new()
                $inset = if ($It.Shape -eq 'end') { 4 } else { 5 }
                $in.Width = $w - 2 * $inset; $in.Height = $hh - 2 * $inset
                $in.Margin = [System.Windows.Thickness]::new($inset)
                $shapes.Add($in)
            }
        }
        'fork' { $shapes.Add([System.Windows.Shapes.Rectangle]::new()) }
        'cylinder' {
            $ry = 7
            $p = [System.Windows.Shapes.Path]::new()
            $ci = [System.Globalization.CultureInfo]::InvariantCulture
            $data = [string]::Format($ci, 'M0,{0} A{1},{0} 0 0 1 {2},{0} L{2},{3} A{1},{0} 0 0 1 0,{3} Z M0,{0} A{1},{0} 0 0 0 {2},{0}', $ry, ($w / 2), $w, ($hh - $ry))
            $p.Data = [System.Windows.Media.Geometry]::Parse($data)
            $shapes.Add($p)
        }
        default {
            $pts = switch ($It.Shape) {
                { $_ -in 'diamond', 'choice' } { @(($w / 2), 0, $w, ($hh / 2), ($w / 2), $hh, 0, ($hh / 2)) }
                'hexagon' { @($k, 0, ($w - $k), 0, $w, ($hh / 2), ($w - $k), $hh, $k, $hh, 0, ($hh / 2)) }
                'para' { $s = $hh * 0.4; @($s, 0, $w, 0, ($w - $s), $hh, 0, $hh) }
                'paraAlt' { $s = $hh * 0.4; @(0, 0, ($w - $s), 0, $w, $hh, $s, $hh) }
                'trap' { $s = $hh * 0.4; @($s, 0, ($w - $s), 0, $w, $hh, 0, $hh) }
                'trapAlt' { $s = $hh * 0.4; @(0, 0, $w, 0, ($w - $s), $hh, $s, $hh) }
                'asym' { @(0, 0, $w, 0, $w, $hh, 0, $hh, ($hh / 2), ($hh / 2)) }
                default { @(0, 0, $w, 0, $w, $hh, 0, $hh) }
            }
            $pg = [System.Windows.Shapes.Polygon]::new()
            $pg.Points = New-WtMmdPoints ([double[]]$pts)
            $shapes.Add($pg)
        }
    }
    $out = [System.Collections.Generic.List[object]]::new()
    $solid = $It.Shape -in 'start', 'fork'
    for ($i = 0; $i -lt $shapes.Count; $i++) {
        $s = $shapes[$i]
        if ($s -is [System.Windows.Shapes.Rectangle] -or $s -is [System.Windows.Shapes.Ellipse]) {
            if ([double]::IsNaN($s.Width)) { $s.Width = $w; $s.Height = $hh }
        }
        if ($s -isnot [System.Windows.Shapes.Line]) {
            $f = if ($solid -or ($It.Shape -eq 'end' -and $i -eq 1)) { 'B.Dia.Line' } elseif ($It.Shape -eq 'end') { 'B.Card' } else { $fill }
            Set-WtResource $s 'Fill' $f
        }
        Set-WtResource $s 'Stroke' $(if ($solid) { 'B.Dia.Line' } else { $line })
        $s.StrokeThickness = 1
        $out.Add((Set-WtMmdPos $s $It.X $It.Y))
    }
    if ($It.Text -and $It.Shape -notin 'start', 'end', 'fork', 'choice') {
        $size = if ($It.Size) { $It.Size } else { 'Body' }
        $t = New-WtMmdTextBlock $It.Text $size 'Center' $w $false 'Text'
        $out.Add((Set-WtMmdPos $t $It.X ($It.Y + ($hh - [double]$It.TH) / 2)))
    }
    $out.ToArray()
}

function New-WtMmdLine($It) {
    $p = [double[]]$It.Pts.Clone()
    $n = $p.Length / 2
    if ($n -lt 2) { return $null }
    $g = $script:gap
    $color = if ($It.Color) { "B.$($It.Color)" } else { 'B.Dia.Line' }
    $thick = switch ($It.Style) { 'thick' { 3.0 } default { 1.5 } }
    $out = [System.Collections.Generic.List[object]]::new()
    # 끝 모양 자리만큼 선을 줄이고 끝 모양을 그린다
    foreach ($end in @(@{ Kind = $It.End; I = $n - 1; J = $n - 2 }, @{ Kind = $It.Start; I = 0; J = 1 })) {
        if (-not $end.Kind -or $end.Kind -eq 'none') { continue }
        $tx = $p[2 * $end.I]; $ty = $p[2 * $end.I + 1]
        $dx = $tx - $p[2 * $end.J]; $dy = $ty - $p[2 * $end.J + 1]
        $len = [Math]::Sqrt($dx * $dx + $dy * $dy)
        if ($len -lt 0.01) { continue }
        $ux = $dx / $len; $uy = $dy / $len
        $back = switch ($end.Kind) { 'arrow' { $g.Arrow } 'circle' { 8 } default { 0 } }
        $back = [Math]::Min($back, $len - 1)
        $p[2 * $end.I] = $tx - $ux * $back
        $p[2 * $end.I + 1] = $ty - $uy * $back
        $out.Add((New-WtMmdMarker $end.Kind $tx $ty $ux $uy $color))
    }
    $path = [System.Windows.Shapes.Path]::new()
    $path.Data = New-WtMmdGeometry $p ([bool]$It.Smooth)
    Set-WtResource $path 'Stroke' $color
    $path.StrokeThickness = $thick
    switch ($It.Style) {
        'dotted' { $path.StrokeDashArray = [System.Windows.Media.DoubleCollection]::new([double[]]@(2, 2)) }
        'dashed' { $path.StrokeDashArray = [System.Windows.Media.DoubleCollection]::new([double[]]@(4, 3)) }
    }
    $out.Insert(0, $path)
    $out.ToArray()
}

# 점들을 잇는 선. 부드럽게(Catmull-Rom → 베지어) 또는 꺾은선
function New-WtMmdGeometry([double[]]$P, [bool]$Smooth) {
    $n = $P.Length / 2
    $fig = [System.Windows.Media.PathFigure]::new()
    $fig.StartPoint = [System.Windows.Point]::new($P[0], $P[1])
    $fig.IsFilled = $false
    if ($Smooth -and $n -gt 2) {
        for ($i = 0; $i -lt $n - 1; $i++) {
            $i0 = [Math]::Max($i - 1, 0); $i3 = [Math]::Min($i + 2, $n - 1)
            $c1 = [System.Windows.Point]::new($P[2 * $i] + ($P[2 * ($i + 1)] - $P[2 * $i0]) / 6, $P[2 * $i + 1] + ($P[2 * ($i + 1) + 1] - $P[2 * $i0 + 1]) / 6)
            $c2 = [System.Windows.Point]::new($P[2 * ($i + 1)] - ($P[2 * $i3] - $P[2 * $i]) / 6, $P[2 * ($i + 1) + 1] - ($P[2 * $i3 + 1] - $P[2 * $i + 1]) / 6)
            $fig.Segments.Add([System.Windows.Media.BezierSegment]::new($c1, $c2, [System.Windows.Point]::new($P[2 * ($i + 1)], $P[2 * ($i + 1) + 1]), $true))
        }
    } else {
        for ($i = 1; $i -lt $n; $i++) { $fig.Segments.Add([System.Windows.Media.LineSegment]::new([System.Windows.Point]::new($P[2 * $i], $P[2 * $i + 1]), $true)) }
    }
    $geo = [System.Windows.Media.PathGeometry]::new()
    $geo.Figures.Add($fig)
    $geo
}

function New-WtMmdMarker([string]$Kind, [double]$Tx, [double]$Ty, [double]$Ux, [double]$Uy, [string]$Color) {
    $arrowLen = $script:gap.Arrow
    $px = -$Uy; $py = $Ux   # 선에 수직
    switch ($Kind) {
        'arrow' {
            $pg = [System.Windows.Shapes.Polygon]::new()
            $bx = $Tx - $Ux * $arrowLen; $by = $Ty - $Uy * $arrowLen
            $pg.Points = New-WtMmdPoints ([double[]]@($Tx, $Ty, ($bx + $px * 4.5), ($by + $py * 4.5), ($bx - $px * 4.5), ($by - $py * 4.5)))
            Set-WtResource $pg 'Fill' $Color
            return $pg
        }
        'async' {
            $pl = [System.Windows.Shapes.Polyline]::new()
            $bx = $Tx - $Ux * $arrowLen; $by = $Ty - $Uy * $arrowLen
            $pl.Points = New-WtMmdPoints ([double[]]@(($bx + $px * 4.5), ($by + $py * 4.5), $Tx, $Ty, ($bx - $px * 4.5), ($by - $py * 4.5)))
            Set-WtResource $pl 'Stroke' $Color
            $pl.StrokeThickness = 1.5
            return $pl
        }
        'circle' {
            $e = [System.Windows.Shapes.Ellipse]::new()
            $e.Width = 8; $e.Height = 8
            Set-WtResource $e 'Fill' 'B.Card'
            Set-WtResource $e 'Stroke' $Color
            $e.StrokeThickness = 1.5
            return Set-WtMmdPos $e ($Tx - $Ux * 4 - 4) ($Ty - $Uy * 4 - 4)
        }
        'cross' {
            $cx = $Tx - $Ux * 5; $cy = $Ty - $Uy * 5
            $pth = [System.Windows.Shapes.Path]::new()
            $ci = [System.Globalization.CultureInfo]::InvariantCulture
            $d = [string]::Format($ci, 'M{0},{1} L{2},{3} M{4},{5} L{6},{7}',
                ($cx + ($Ux + $px) * 4), ($cy + ($Uy + $py) * 4), ($cx - ($Ux + $px) * 4), ($cy - ($Uy + $py) * 4),
                ($cx + ($Ux - $px) * 4), ($cy + ($Uy - $py) * 4), ($cx - ($Ux - $px) * 4), ($cy - ($Uy - $py) * 4))
            $pth.Data = [System.Windows.Media.Geometry]::Parse($d)
            Set-WtResource $pth 'Stroke' $Color
            $pth.StrokeThickness = 1.5
            return $pth
        }
    }
    $null
}

Register-WtMarkdownCodeRenderer -Language 'mermaid' -Label 'mermaid' -Remeasure -Render { param($code) New-WtMermaidView $code }

Export-ModuleMember -Function ConvertFrom-WtMermaid, Get-WtMermaidLayout, New-WtMermaidView
} | Import-Module -Force -DisableNameChecking
# ---- core\Mermaid.psm1 끝 ----

# ---- core\Addons.psm1 ----
New-Module -Name 'WorkTool.Addons' -ScriptBlock {
# 애드온(탭) 목록. 탭 하나 = addons\<이름>\ 폴더 하나이고, 그 모듈이 불러와질 때 Register-WtAddon으로 자기를 등록한다.
# 셸 · 홈 · 도움말은 이 목록만 보고 메뉴 · 카드 · 설명을 만든다. 탭을 더하거나 빼도 코어 코드는 고치지 않는다.
# 탭의 검사는 같은 폴더의 Test-<이름>.ps1에 두면 tests\Test-Core.ps1이 찾아서 돌린다.

$ErrorActionPreference = 'Stop'

$script:addons = [System.Collections.Generic.List[hashtable]]::new()

<#
등록 항목
  Id           영문 소문자 ID (저장소 이름에도 씀)
  Title        메뉴에 보이는 이름
  Icon         Segoe 아이콘 글꼴 글자 코드 (예: 0xE70B)
  Order        메뉴 순서 (작을수록 위)
  Required     $true면 설정에서 끌 수 없음 (홈)
  NewView      { } → 화면 요소를 돌려준다. 처음 열 때 한 번 부른다.
  Refresh      { param($view) } → 화면을 열 때마다 부른다 (선택)
  HomeCard     { } → 홈에 놓을 카드 요소(여러 개 가능)를 돌려준다 (선택)
  ImportLegacy { param($folder) } → 예전 WorkTool data 폴더에서 이 탭 데이터를 가져와 저장한다. 가져온 개수를 돌려준다 (선택)
  OnExit       { } → 끝내기 직전(SavePending 확인 뒤) 타이머·조회 등 실행 자원을 정리한다 (선택)
  SavePending  { } → 이 화면을 떠날 때 · 끝낼 때 저장. 실패하면 $false를 돌려준다.
                     그러면 셸이 다시 시도 · 저장하지 않고 이동(끝내기) · 취소를 묻는다 (선택)
  Help         도움말 「이 버전」에 넣을 설명 문단들 (선택)
  Shortcuts    도움말 「단축키」에 넣을 @('키', '설명') 목록. 키 처리는 탭 화면이 직접 한다 (선택)
               하나만 줄 때는 앞에 쉼표를 붙인다: -Shortcuts (, @('F5', '새로 고침'))
  HelpCard     { } → 도움말에 따로 놓을 카드 요소를 돌려준다 (선택)
  WarmUp       켠 뒤 한가할 때 화면을 미리 만들어 둘지 (선택). 처음 누를 때도 빨리 뜨게 하려는 것이다
               'Full' → NewView · Refresh를 미리 부른다. 이 탭의 데이터 파일만 읽고 밖에 영향이 없을 때만 쓴다
               'View' → NewView만 미리 부른다. Refresh가 폴더 조회 · 다른 창 수집처럼 느리거나 밖에 닿을 때 쓴다
#>
function Register-WtAddon {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [int]$Icon = 0xE10C,
        [int]$Order = 100,
        [switch]$Required,
        [Parameter(Mandatory)][scriptblock]$NewView,
        [scriptblock]$Refresh,
        [scriptblock]$HomeCard,
        [scriptblock]$ImportLegacy,
        [scriptblock]$OnExit,
        [scriptblock]$SavePending,
        [ValidateSet('', 'View', 'Full')][string]$WarmUp = '',
        [string]$Description = '',
        [string[]]$Help = @(),
        [object[]]$Shortcuts = @(),
        [scriptblock]$HelpCard
    )
    # 쉼표 없이 한 쌍만 주면 배열이 펴져서 들어온다 → 한 쌍으로 되돌린다
    if ($Shortcuts.Count -and $Shortcuts[0] -is [string]) { $Shortcuts = @(, $Shortcuts) }
    foreach ($s in $Shortcuts) {
        if (@($s).Count -ne 2) { throw "애드온 '$Id'의 단축키는 @('키', '설명') 모양이어야 합니다." }
    }
    for ($i = $script:addons.Count - 1; $i -ge 0; $i--) {
        if ($script:addons[$i].Id -eq $Id) { $script:addons.RemoveAt($i) }
    }
    $script:addons.Add(@{
            Id = $Id; Title = $Title; Icon = $Icon; Order = $Order; Required = [bool]$Required
            NewView = $NewView; Refresh = $Refresh; HomeCard = $HomeCard; ImportLegacy = $ImportLegacy; OnExit = $OnExit
            Description = $Description
            SavePending = $SavePending; WarmUp = $WarmUp
            Help = @($Help); Shortcuts = @($Shortcuts); HelpCard = $HelpCard
        })
}

# 순서대로 돌려준다. -All이 없으면 설정에서 끈 탭은 뺀다.
function Get-WtAddon {
    param([switch]$All, [string]$Id)
    $disabled = @(Get-WtSetting 'addons.disabled')
    $list = $script:addons | Sort-Object { $_.Order }, { $_.Id }
    if ($Id) { return $list | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
    if ($All) { return $list }
    $list | Where-Object { $_.Required -or $disabled -notcontains $_.Id }
}

Export-ModuleMember -Function Register-WtAddon, Get-WtAddon
} | Import-Module -Force -DisableNameChecking
# ---- core\Addons.psm1 끝 ----

# ---- core\Pages.psm1 ----
New-Module -Name 'WorkTool.Pages' -ScriptBlock {
# 셸에 붙은 기본 화면: 설정, 도움말. 메뉴 아래 톱니바퀴 · 물음표 버튼으로 연다.
# 이벤트 처리기는 $script: 변수와 보낸 요소의 Tag만 쓴다 (Shell.psm1 머리말 참고).

$ErrorActionPreference = 'Stop'

$script:addonChecks = @()
$script:opacityLabel = $null
$script:opacityTimer = $null
$script:pendingOpacity = 100
$script:opacityNote = $null

# ---- 설정 -------------------------------------------------------------------------------------

# 100%는 글자를 또렷하게 그리는 보통 창, 그 아래는 투명 창이다. 둘 사이를 오가면 다시 시작해야 적용된다
function Update-WtOpacityNote([double]$Percent) {
    $note = if (-not (Test-WtOpacityNeedsRestart $Percent)) { '' } elseif ($Percent -lt 100) { 'WorkTool을 다시 시작하면 적용됩니다.' } else { '다시 시작하면 글자가 더 또렷해집니다.' }
    $script:opacityNote.Text = $note
    $script:opacityNote.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
}

function New-WtSettingRow([string]$Label, $Control, [string]$Note) {
    $row = [System.Windows.Controls.DockPanel]::new()
    $row.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    $left = New-WtStack Vertical 2
    $left.Width = 180
    $left.VerticalAlignment = 'Center'
    [void](Add-WtChild $left (New-WtText $Label 'T.Strong'))
    if ($Note) { [void](Add-WtChild $left (New-WtText $Note 'T.Sub')) }
    [System.Windows.Controls.DockPanel]::SetDock($left, 'Left')
    [void]$row.Children.Add($left)
    $Control.VerticalAlignment = 'Center'
    $Control.HorizontalAlignment = 'Left'
    [void]$row.Children.Add($Control)
    $row
}

function New-WtThemeCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 4
    [void](Add-WtChild $col (New-WtCardHeader '화면'))

    # 색: 팔레트마다 동그라미 하나
    $swatches = New-WtStack Horizontal
    $current = [string](Get-WtSetting 'theme.color')
    $palettes = Get-WtPalette
    foreach ($key in $palettes.Keys) {
        $p = $palettes[$key]
        $rb = [System.Windows.Controls.RadioButton]::new()
        Set-WtStyle $rb 'Swatch'
        $rb.GroupName = 'WtTheme'
        $rb.Tag = $key
        $rb.ToolTip = $p.Label
        $rb.Background = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($p.Accent))
        $rb.BorderBrush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($p.Tint))
        $rb.IsChecked = ($key -eq $current)
        $rb.Add_Checked({ param($s, $e) Set-WtSetting 'theme.color' ([string]$s.Tag) })
        [void]$swatches.Children.Add($rb)
    }
    $labels = ($palettes.Values | ForEach-Object { $_.Label }) -join ' · '
    [void](Add-WtChild $col (New-WtSettingRow '색' $swatches $labels))

    # 창 투명도: 끌면 바로 보이고, 손을 떼고 잠시 뒤 저장한다
    $op = New-WtStack Horizontal 12
    $slider = [System.Windows.Controls.Slider]::new()
    Set-WtStyle $slider 'Range'
    [System.Windows.Automation.AutomationProperties]::SetName($slider, '창 투명도')
    $slider.Minimum = 60
    $slider.Maximum = 100
    $slider.TickFrequency = 5
    $slider.IsSnapToTickEnabled = $true
    $slider.Width = 240
    $slider.Value = [double](Get-WtSetting 'ui.opacity')
    $slider.VerticalAlignment = 'Center'
    $script:opacityLabel = New-WtText ('{0}%' -f [int]$slider.Value) 'T.Strong'
    $script:opacityLabel.VerticalAlignment = 'Center'
    if (-not $script:opacityTimer) {
        $script:opacityTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:opacityTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:opacityTimer.Add_Tick({
                param($s, $e)
                $s.Stop()
                Set-WtSetting 'ui.opacity' ([int]$script:pendingOpacity)
            })
    }
    $slider.Add_ValueChanged({
            param($s, $e)
            $script:pendingOpacity = [int]$e.NewValue
            $script:opacityLabel.Text = '{0}%' -f $script:pendingOpacity
            Set-WtOpacity $script:pendingOpacity
            Update-WtOpacityNote $script:pendingOpacity
            $script:opacityTimer.Stop()
            $script:opacityTimer.Start()
        })
    [void](Add-WtChild $op $slider)
    [void](Add-WtChild $op $script:opacityLabel)
    $opCol = New-WtStack Vertical 4
    [void](Add-WtChild $opCol $op)
    $script:opacityNote = New-WtText '' 'T.Sub'
    [void](Add-WtChild $opCol $script:opacityNote)
    Update-WtOpacityNote $slider.Value
    [void](Add-WtChild $col (New-WtSettingRow '창 투명도' $opCol '60% ~ 100%'))

    # 글자 크기
    $seg = New-WtSegmented @(@('s', '작게'), @('m', '보통'), @('l', '크게')) ([string](Get-WtSetting 'ui.fontScale')) 'WtFont' {
        param($value) Set-WtSetting 'ui.fontScale' $value
    }
    [void](Add-WtChild $col (New-WtSettingRow '글자 크기' $seg))

    # 닫기 버튼(X)
    $close = New-WtSegmented @(@('exit', '끝내기'), @('tray', '트레이로 숨기기')) $(if (Get-WtSetting 'window.closeToTray') { 'tray' } else { 'exit' }) 'WtClose' {
        param($value) Set-WtSetting 'window.closeToTray' ($value -eq 'tray')
    }
    [void](Add-WtChild $col (New-WtSettingRow '닫기 버튼 (X)' $close '숨기면 트레이 아이콘 우클릭 → 종료로 끕니다'))

    $card.Child = $col
    $card
}

function New-WtMenuCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 4
    [void](Add-WtChild $col (New-WtCardHeader '메뉴'))
    [void](Add-WtChild $col (New-WtText '끄면 메뉴에서만 사라지고 데이터는 그대로입니다.' 'T.Sub'))
    $disabled = @(Get-WtSetting 'addons.disabled')
    $script:addonChecks = @()
    foreach ($a in @(Get-WtAddon -All)) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        Set-WtStyle $cb 'Check'
        $cb.Content = if ($a.Description) { "$($a.Title) — $($a.Description)" } else { $a.Title }
        $cb.Tag = $a.Id
        $cb.IsChecked = $a.Required -or ($disabled -notcontains $a.Id)
        $cb.IsEnabled = -not $a.Required
        $cb.Add_Click({
                $off = @($script:addonChecks | Where-Object { $_.IsEnabled -and -not $_.IsChecked } | ForEach-Object { [string]$_.Tag })
                Set-WtSetting 'addons.disabled' $off
            })
        $script:addonChecks += $cb
        [void](Add-WtChild $col $cb)
    }
    $card.Child = $col
    $card
}

function New-WtDataCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 6
    [void](Add-WtChild $col (New-WtCardHeader '데이터'))

    $root = Get-WtDataRoot
    $path = New-WtText $root 'T.Body'
    Set-WtResource $path 'FontFamily' 'Font.Mono'
    $open = New-WtButton '폴더 열기' -Icon 0xE8B7
    $open.Tag = $root
    $open.Add_Click({ param($s, $e) Invoke-Item -LiteralPath ([string]$s.Tag) })
    $box = New-WtStack Vertical 6
    [void](Add-WtChild $box $path)
    [void](Add-WtChild $box $open)
    [void](Add-WtChild $col (New-WtSettingRow '저장 위치' $box '바꾸려면 앱 폴더에 datapath.txt를 만들고 첫 줄에 경로를 적습니다'))

    $legacy = Find-WtLegacyFolder
    $lbox = New-WtStack Vertical 6
    $ltext = New-WtText $(if ($legacy) { $legacy } else { '찾지 못함' }) 'T.Body'
    Set-WtResource $ltext 'FontFamily' 'Font.Mono'
    [void](Add-WtChild $lbox $ltext)
    $btns = New-WtStack Horizontal 8
    $pick = New-WtButton '위치 고르기'
    $pick.Add_Click({
            $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
            $dlg.Description = '예전 WorkTool의 data 폴더를 고르세요 (memo.csv · schedule.csv · attendance.csv가 있는 폴더)'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-WtSetting 'legacy.path' $dlg.SelectedPath
                Select-WtPage '_settings'
            }
        })
    $again = New-WtButton '다시 가져오기' -Kind Primary
    $again.IsEnabled = [bool]$legacy
    $again.Add_Click({
            $tabs = @(Get-WtAddon -All | Where-Object { $_.ImportLegacy } | ForEach-Object { $_.Title }) -join ' · '
            if (-not (Confirm-WtYesNo "예전 WorkTool 데이터로 새 버전의 데이터($tabs)를 다시 채웁니다.`n새 버전에서 쓰거나 고친 내용은 사라집니다 (지금 파일은 .bak으로 하나 남음). 계속할까요?")) { return }
            try {
                $r = Import-WtLegacyData -Force
                Reset-WtViews
                Show-WtMessage ("가져왔습니다: {0}" -f ($r.Tabs -join ', '))
            } catch { Show-WtError $_ '다시 가져오기' }
        })
    [void](Add-WtChild $btns $pick)
    [void](Add-WtChild $btns $again)
    [void](Add-WtChild $lbox $btns)
    [void](Add-WtChild $col (New-WtSettingRow '예전 WorkTool 데이터' $lbox '1단계에서는 여기서 읽어 와서 보여 주기만 합니다'))

    $card.Child = $col
    $card
}

function New-WtSettingsPage {
    $page = New-WtPage
    [void](Add-WtChild $page.Panel (New-WtPageHeader '설정'))
    [void](Add-WtChild $page.Panel (New-WtThemeCard))
    [void](Add-WtChild $page.Panel (New-WtMenuCard))
    [void](Add-WtChild $page.Panel (New-WtDataCard))
    $page.Root
}

# ---- 도움말 -----------------------------------------------------------------------------------

function New-WtKeyRow([string]$Keys, [string]$What) {
    $k = New-WtTag $Keys
    $k.MinWidth = 120
    New-WtListRow @($k, (New-WtText $What 'T.Body'))
}

# 탭이 등록한 단축키를 메뉴 순서대로 모은다. 키와 설명이 같으면 한 줄로 묶는다 (예: 문서 · 활성 작업: 새로 고침)
function Get-WtShortcutRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @(Get-WtAddon)) {
        foreach ($s in @($a.Shortcuts)) {
            $same = $rows | Where-Object { $_.Key -ceq $s[0] -and $_.What -ceq $s[1] } | Select-Object -First 1
            if ($same) { $same.Titles.Add($a.Title); continue }
            $titles = [System.Collections.Generic.List[string]]::new()
            $titles.Add($a.Title)
            $rows.Add([pscustomobject]@{ Key = [string]$s[0]; What = [string]$s[1]; Titles = $titles })
        }
    }
    foreach ($r in $rows) { [pscustomobject]@{ Key = $r.Key; Text = '{0}: {1}' -f ($r.Titles -join ' · '), $r.What } }
}

function New-WtHelpPage {
    $page = New-WtPage
    [void](Add-WtChild $page.Panel (New-WtPageHeader '도움말'))

    $about = New-WtCard
    $col = New-WtStack Vertical 6
    [void](Add-WtChild $col (New-WtCardHeader '이 버전 (1단계 미리보기)'))
    [void](Add-WtChild $col (New-WtText '창 틀 · 메뉴 · 테마 · 설정, 그리고 예전 WorkTool 데이터를 읽어서 보여 주는 기능까지 들어 있습니다.' 'T.Body'))
    foreach ($a in @(Get-WtAddon)) {
        foreach ($line in @($a.Help)) { [void](Add-WtChild $col (New-WtText $line 'T.Body')) }
    }
    $about.Child = $col
    [void](Add-WtChild $page.Panel $about)

    $keys = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '단축키'))
    foreach ($r in @(
            @('Ctrl + 1 ~ 9', '메뉴 순서대로 화면 이동'),
            @('Ctrl + B', '메뉴 접기 / 펼치기'),
            @('F11', '전체 화면 (Esc로 나가기)'),
            @('Ctrl + ,', '설정'),
            @('F1', '도움말'))) {
        [void](Add-WtChild $col (New-WtKeyRow $r[0] $r[1]))
    }
    foreach ($r in @(Get-WtShortcutRows)) { [void](Add-WtChild $col (New-WtKeyRow $r.Key $r.Text)) }
    $keys.Child = $col
    [void](Add-WtChild $page.Panel $keys)

    # 탭이 따로 둔 도움말 카드 (메모의 마크다운 예시 등). 하나가 실패해도 도움말은 연다
    foreach ($a in @(Get-WtAddon)) {
        if (-not $a.HelpCard) { continue }
        try {
            foreach ($el in @(& $a.HelpCard)) { if ($el -is [System.Windows.UIElement]) { [void](Add-WtChild $page.Panel $el) } }
        } catch {
            [void](Add-WtChild $page.Panel (New-WtText "$($a.Title) 도움말을 만들지 못했습니다: $($_.Exception.Message)" 'T.Sub'))
        }
    }

    $win = New-WtCard
    $col = New-WtStack Vertical 6
    [void](Add-WtChild $col (New-WtCardHeader '창 · 데이터'))
    [void](Add-WtChild $col (New-WtText '창의 X는 앱을 끝냅니다. 설정 → 닫기 버튼에서 트레이로 숨기기를 고르면, 끌 때 트레이 아이콘을 우클릭 → 종료.' 'T.Body'))
    [void](Add-WtChild $col (New-WtText "데이터 위치: $(Get-WtDataRoot)" 'T.Body'))
    $last = Get-WtLastImport
    if ($last) {
        $when = Format-WtDate $last.At 'M월 d일 HH:mm'
        [void](Add-WtChild $col (New-WtText "예전 데이터를 가져옴: $($last.Folder) ($when · $($last.Tabs -join ', '))" 'T.Sub'))
    }
    $win.Child = $col
    [void](Add-WtChild $page.Panel $win)

    $page.Root
}

Export-ModuleMember -Function New-WtSettingsPage, New-WtHelpPage
} | Import-Module -Force -DisableNameChecking
# ---- core\Pages.psm1 끝 ----

# ---- core\Shell.psm1 ----
New-Module -Name 'WorkTool.Shell' -ScriptBlock {
# 셸: 메인 창 틀, 왼쪽 메뉴, 제목 줄 버튼, 트레이, 단축키, 화면 전환.
# 메뉴는 Addons.psm1에 등록된 애드온 목록으로 만든다. 탭을 더하거나 빼도 이 파일은 고치지 않는다.
#
# 창은 WindowStyle=None으로 만들고 제목 줄은 직접 그린다. 투명도를 100%보다 낮게 고르면 투명 창(AllowsTransparency)으로 띄운다.
# 그래서 이 창 안에는 WindowsFormsHost · WebBrowser를 넣지 않는다 (투명 창에서는 그려지지 않는다).
# 투명 창은 ClearType을 못 쓰고 회색조로 글자를 그려서, 100%면 보통 창으로 띄운다 (Start-WtApp). 글자는 Ideal 모드로 그린다.
#
# 이벤트 처리기는 나중에 디스패처가 부르므로, 만든 함수의 지역 변수를 볼 수 없다.
# 처리기 안에서는 $script: 변수와 $s(보낸 요소)의 Tag만 쓴다.

$ErrorActionPreference = 'Stop'

$script:window = $null
$script:ui = $null
$script:frame = $null
$script:themeDict = $null
$script:notify = $null
$script:views = @{}
$script:navButtons = @{}
$script:current = $null
$script:selecting = $false
$script:exiting = $false
$script:trayTipShown = $false
$script:maxed = $false
$script:fullscreen = $false
$script:restoreBounds = $null
$script:fullFromMax = $false   # 최대화 상태에서 전체 화면으로 갔는지
$script:settingBounds = $false # 코드로 창 위치 · 크기를 바꾸는 중
$script:icon = $null
$script:lastImport = $null
$script:warmQueue = $null      # 켠 뒤 미리 만들 화면 ID (Start-WtWarmUp)
$script:warmTimer = $null
$script:warmEnabled = $false  # WORKTOOL_WARMUP=1인 진단 세션에서만 켠다
$script:warmStarted = $false  # ContentRendered가 다시 와도 세션당 한 번만 예약
$script:forceOpaque = $false  # WORKTOOL_FORCE_OPAQUE=1: 설정을 저장하지 않는 불투명 창

$script:shellXaml = @'
<Window {NS}
    Title="WorkTool" Width="1200" Height="780" MinWidth="760" MinHeight="520"
    WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True" ResizeMode="CanResize"
    Background="Transparent" UseLayoutRounding="True" SnapsToDevicePixels="True"
    TextOptions.TextFormattingMode="Ideal"
    FontFamily="{DynamicResource Font.UI}" FontSize="{DynamicResource F.Body}" Foreground="{DynamicResource B.Text}">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="40" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Border x:Name="Frame" Background="{DynamicResource B.WindowBg}" BorderBrush="{DynamicResource B.FrameBorder}" BorderThickness="1">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition x:Name="NavColumn" Width="232"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="{DynamicResource B.Sidebar}" BorderBrush="{DynamicResource B.Border}" BorderThickness="0,0,1,0">
        <DockPanel Margin="12,0,12,12">
          <StackPanel DockPanel.Dock="Top">
            <DockPanel Height="40" Margin="-2,0,0,0">
              <Button x:Name="CollapseButton" DockPanel.Dock="Left" Style="{DynamicResource Btn.Icon}"
                      WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="메뉴 접기/펼치기 (Ctrl+B)">
                <TextBlock Text="&#xE700;" Style="{DynamicResource T.Icon}"/>
              </Button>
              <Border x:Name="BrandLogo" DockPanel.Dock="Left" Width="22" Height="22" CornerRadius="5" Margin="6,0,0,0"
                      Background="{DynamicResource B.Accent}" VerticalAlignment="Center">
                <TextBlock Text="W" FontFamily="Segoe UI" FontWeight="Bold" FontSize="14" Foreground="{DynamicResource B.OnAccent}"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <TextBlock x:Name="BrandText" Text="WorkTool" Margin="8,0,0,0" FontWeight="Bold"
                         FontSize="{DynamicResource F.H2}" VerticalAlignment="Center"/>
            </DockPanel>
            <TextBlock x:Name="TodayText" Style="{DynamicResource T.Sub}" Margin="12,6,0,14"/>
          </StackPanel>
          <StackPanel x:Name="FooterPanel" DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="-2,8,0,0">
            <Button x:Name="SettingsButton" Style="{DynamicResource Btn.Icon}" ToolTip="설정 (Ctrl+,)">
              <TextBlock Text="&#xE713;" Style="{DynamicResource T.Icon}"/>
            </Button>
            <Button x:Name="HelpButton" Style="{DynamicResource Btn.Icon}" ToolTip="도움말 (F1)">
              <TextBlock Text="&#xE9CE;" Style="{DynamicResource T.Icon}"/>
            </Button>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
            <StackPanel x:Name="NavPanel"/>
          </ScrollViewer>
        </DockPanel>
      </Border>

      <DockPanel Grid.Column="1">
        <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" HorizontalAlignment="Right" Height="40">
          <Button x:Name="MinButton" Style="{DynamicResource Btn.Chrome}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="최소화">
            <TextBlock Text="&#xE921;" Style="{DynamicResource T.Icon}" FontSize="10"/>
          </Button>
          <Button x:Name="MaxButton" Style="{DynamicResource Btn.Chrome}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="최대화">
            <TextBlock x:Name="MaxGlyph" Text="&#xE922;" Style="{DynamicResource T.Icon}" FontSize="10"/>
          </Button>
          <Button x:Name="CloseButton" Style="{DynamicResource Btn.Close}" WindowChrome.IsHitTestVisibleInChrome="True" ToolTip="닫기">
            <TextBlock Text="&#xE8BB;" Style="{DynamicResource T.Icon}" FontSize="10"/>
          </Button>
        </StackPanel>
        <Grid>
          <!-- 미리 만든 화면을 잠깐 붙여 배치만 해 보는 자리 (Invoke-WtWarmUpStep). 보이지 않고 누를 수도 없다 -->
          <ContentControl x:Name="WarmHost" Focusable="False" Visibility="Hidden" IsHitTestVisible="False"/>
          <ContentControl x:Name="PageHost" Focusable="False"/>
        </Grid>
      </DockPanel>
    </Grid>
  </Border>
</Window>
'@

function Get-WtWindow { $script:window }

# ---- 화면 전환 --------------------------------------------------------------------------------

# 스크립트 블록의 출력 중 화면 요소만 고른다 (실수로 섞여 나온 숫자 등은 버린다)
function Get-WtElements($Output) {
    @($Output | Where-Object { $_ -is [System.Windows.UIElement] })
}

function Get-WtPageView([string]$Id) {
    if ($Id -in '_settings', '_help') {
        # 등록 객체도 비교하므로 같은 ID의 탭을 다시 등록한 경우까지 반영한다.
        $registrations = @(foreach ($a in @(Get-WtAddon -All)) {
            [ordered]@{ Identity = [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($a); Id = $a.Id; Title = $a.Title
                Description = $a.Description; Required = $a.Required; Order = $a.Order; Help = $a.Help; Shortcuts = $a.Shortcuts }
        })
        $settings = @(foreach ($name in 'theme.color','ui.opacity','ui.fontScale','window.closeToTray','addons.disabled','legacy.path') {
            [ordered]@{ Key = $name; Value = (Get-WtSetting $name) }
        })
        $key = ConvertTo-Json -Compress -Depth 8 -InputObject @(
            (Get-WtDataRoot), $settings, $registrations, (Find-WtLegacyFolder), (Get-WtLastImport))
        if (-not $script:views.ContainsKey($Id) -or $script:views[$Id].Key -cne $key) {
            $view = if ($Id -eq '_settings') { New-WtSettingsPage } else { New-WtHelpPage }
            $script:views[$Id] = @{ View = $view; Addon = $null; Key = $key }
        }
        return $script:views[$Id]
    }
    if (-not $script:views.ContainsKey($Id)) {
        $a = Get-WtAddon -Id $Id
        if (-not $a) { return $null }
        $view = Get-WtElements (& $a.NewView) | Select-Object -Last 1
        if (-not $view) { throw "애드온 '$Id'가 화면을 돌려주지 않았습니다." }
        $script:views[$Id] = @{ View = $view; Addon = $a }
    }
    $script:views[$Id]
}

function Select-WtPage([string]$Id) {
    if ($script:selecting -or -not $Id) { return }
    $script:selecting = $true
    try {
        # 떠나는 화면에 저장하지 못한 내용이 있으면 묻는다 (다른 화면의 저장 상태는 그 화면을 떠날 때 묻는다)
        if ($script:current -and $Id -ne $script:current -and -not (Save-WtPendingChanges -Purpose switch -Only $script:current)) { return }
        $page = Get-WtPageView $Id
        if (-not $page) { return }
        if ($page.Addon -and $page.Addon.Refresh) { [void](& $page.Addon.Refresh $page.View) }
        $script:ui.PageHost.Content = $page.View
        foreach ($k in @($script:navButtons.Keys)) { $script:navButtons[$k].Button.IsChecked = ($k -eq $Id) }
        $script:current = $Id
    } catch {
        foreach ($k in @($script:navButtons.Keys)) { $script:navButtons[$k].Button.IsChecked = ($k -eq $script:current) }
        Show-WtError $_ "화면 열기: $Id"
    } finally {
        foreach ($k in @($script:navButtons.Keys)) { $script:navButtons[$k].Button.IsChecked = ($k -eq $script:current) }
        $script:selecting = $false
    }
}

# 데이터를 다시 가져온 뒤 현재 화면을 갱신한다. 숨긴 화면도 재진입할 때 갱신한다.
function Reset-WtViews {
    if (-not (Save-WtPendingChanges)) { return }
    if ($script:current) {
        $id = $script:current
        $script:current = $null
        Select-WtPage $id
    }
}

# ---- 미리 만들기 ------------------------------------------------------------------------------

# 켠 뒤 한가할 때 아직 안 연 화면을 하나씩 미리 만들어 둔다. 처음 누를 때도 다시 누를 때처럼 빨리 뜨게 하려는 것이다.
# 탭은 등록할 때 WarmUp을 준 것만(Addons.psm1 참고), 그다음 설정 · 도움말 차례다.
# 화면 하나를 만드는 동안은 화면 스레드를 쓰므로, 하나 끝날 때마다 쉬어서 그사이 들어온 입력을 먼저 처리한다
function Start-WtWarmUp {
    if (-not $script:warmEnabled -or $script:warmStarted -or $script:exiting) { return }
    $script:warmStarted = $true
    $ids = @(Get-WtAddon | Where-Object { $_.WarmUp } | ForEach-Object { $_.Id }) + @('_settings', '_help')
    $script:warmQueue = [System.Collections.Generic.Queue[string]]::new([string[]]$ids)
    if (-not $script:warmTimer) {
        $script:warmTimer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
        $script:warmTimer.Interval = [TimeSpan]::FromMilliseconds(300)
        $script:warmTimer.Add_Tick({
            if ($script:exiting) { $script:warmTimer.Stop(); return }
            # ApplicationIdle도 실행을 시작하면 UI를 점유한다. 사용 중이거나 숨긴 창에서는 만들지 않는다.
            if (-not (Test-WtCanWarmUp)) { return }
            if (-not (Invoke-WtWarmUpStep)) { $script:warmTimer.Stop() }
        })
    }
    $script:warmTimer.Start()
}

function Test-WtCanWarmUp {
    $w = $script:window
    $script:warmEnabled -and -not $script:exiting -and $w -and
        -not [System.Windows.Interop.ComponentDispatcher]::IsThreadModal -and
        $w.IsVisible -and $w.IsEnabled -and -not $w.IsActive -and
        $w.WindowState -ne [System.Windows.WindowState]::Minimized -and -not $script:selecting
}

# 미리 만들기 한 단계. 아직 남은 것이 있으면 $true
function Invoke-WtWarmUpStep {
    if ($script:exiting -or -not $script:warmEnabled) { return $false }
    while ($script:warmQueue -and $script:warmQueue.Count) {
        $id = $script:warmQueue.Dequeue()
        if ($id -eq $script:current -or ($id -notlike '_*' -and $script:views.ContainsKey($id))) { continue }   # 이미 열었다
        try {
            $page = Get-WtPageView $id
            if (-not $page) { continue }
            if ($page.Addon -and $page.Addon.WarmUp -eq 'Full' -and $page.Addon.Refresh) { [void](& $page.Addon.Refresh $page.View) }
            # 안 보이는 자리에 잠깐 붙여 틀 적용 · 글자 배치까지 해 두고, 바로 떼어 실제 자리로 옮길 수 있게 한다
            $script:ui.WarmHost.Content = $page.View
            $script:ui.WarmHost.UpdateLayout()
        } catch {
            # 미리 만들기는 덤이다. 실패하면 그 화면을 열 때 원래대로 만들고, 오류도 그때 알린다
            if ($id -ne $script:current) { [void]$script:views.Remove($id) }
        } finally { $script:ui.WarmHost.Content = $null }
        return [bool]$script:warmQueue.Count
    }
    $false
}

# ---- 왼쪽 메뉴 --------------------------------------------------------------------------------

function Update-WtNav {
    $panel = $script:ui.NavPanel
    $panel.Children.Clear()
    $script:navButtons = @{}
    $i = 0
    foreach ($a in @(Get-WtAddon)) {
        $i++
        $rb = [System.Windows.Controls.RadioButton]::new()
        Set-WtStyle $rb 'Nav'
        $rb.GroupName = 'WtNav'
        $rb.Tag = $a.Id
        $rb.ToolTip = if ($i -le 9) { "$($a.Title) (Ctrl+$i)" } else { $a.Title }
        $row = [System.Windows.Controls.StackPanel]::new()
        $row.Orientation = 'Horizontal'
        $icon = New-WtIcon $a.Icon
        $icon.Width = 20
        $label = [System.Windows.Controls.TextBlock]::new()
        $label.Text = $a.Title
        $label.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
        $label.VerticalAlignment = 'Center'
        [void]$row.Children.Add($icon)
        [void]$row.Children.Add($label)
        $rb.Content = $row
        $rb.IsChecked = ($a.Id -eq $script:current)
        $rb.Add_Checked({ param($s, $e) Select-WtPage ([string]$s.Tag) })
        [void]$panel.Children.Add($rb)
        $script:navButtons[$a.Id] = @{ Button = $rb; Label = $label }
    }
    Update-WtCollapsed
}

function Update-WtCollapsed {
    $c = [bool](Get-WtSetting 'nav.collapsed')
    $script:ui.NavColumn.Width = [System.Windows.GridLength]::new($(if ($c) { 68 } else { 232 }))
    $vis = if ($c) { 'Collapsed' } else { 'Visible' }
    $script:ui.BrandText.Visibility = $vis
    $script:ui.BrandLogo.Visibility = $vis
    $script:ui.TodayText.Visibility = $vis
    foreach ($n in $script:navButtons.Values) { $n.Label.Visibility = $vis }
    $script:ui.FooterPanel.Orientation = if ($c) { 'Vertical' } else { 'Horizontal' }
}

function Switch-WtCollapsed { Set-WtSetting 'nav.collapsed' (-not [bool](Get-WtSetting 'nav.collapsed')) }

<#
창 단축키를 화면 안 요소가 대신 쓰게 넘긴다. 그 요소(또는 그 안)에 포커스가 있으면 셸은 그 키를 처리하지 않는다.
  Register-WtKeyOwner $element 'Ctrl+B'     예: 메모 편집기는 Ctrl+B를 굵게로 쓴다. 다른 곳에서는 그대로 메뉴 접기
요소가 사라지면 등록도 같이 사라진다(약한 참조).
#>
$script:keyOwners = [System.Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Register-WtKeyOwner([Parameter(Mandatory)][System.Windows.DependencyObject]$Element, [Parameter(Mandatory)][string[]]$Keys) {
    $script:keyOwners.AddOrUpdate($Element, [string[]]$Keys)
}

# $From: 찾기 시작할 요소 (기본은 키보드 포커스가 있는 요소)
function Test-WtKeyOwned([string]$Key, $From = [System.Windows.Input.Keyboard]::FocusedElement) {
    $el = $From
    while ($el) {
        $keys = $null
        if ($script:keyOwners.TryGetValue($el, [ref]$keys) -and $keys -contains $Key) { return $true }
        $parent = $null
        if ($el -is [System.Windows.Media.Visual]) { $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($el) }
        if (-not $parent -and $el -is [System.Windows.DependencyObject]) { $parent = [System.Windows.LogicalTreeHelper]::GetParent($el) }
        $el = $parent
    }
    $false
}

# ---- 창 크기 · 투명도 -------------------------------------------------------------------------

function Set-WtOpacity([double]$Percent = -1) {
    if ($script:forceOpaque) { $script:window.Opacity = 1.0; return }
    if ($Percent -lt 0) { $Percent = [double](Get-WtSetting 'ui.opacity') }
    if (-not $script:window.AllowsTransparency) { return }   # 보통 창으로 띄웠으면 다시 시작해야 투명도가 바뀐다 (Test-WtOpacityNeedsRestart)
    $script:window.Opacity = [Math]::Max(0.6, [Math]::Min(1.0, $Percent / 100))
}

# 투명도를 이 값으로 바꾸면 다시 시작해야 하는지. 투명 창 여부는 창을 보이기 전에만 정할 수 있다 (Start-WtApp)
function Test-WtOpacityNeedsRestart([double]$Percent) {
    $script:window -and $script:window.AllowsTransparency -ne ($Percent -lt 100)
}

# 창이 있는 화면의 작업 영역(또는 전체) 크기를 WPF 단위로
function Get-WtScreenRect([switch]$Full) {
    $hwnd = [System.Windows.Interop.WindowInteropHelper]::new($script:window).Handle
    $screen = [System.Windows.Forms.Screen]::FromHandle($hwnd)
    $r = if ($Full) { $screen.Bounds } else { $screen.WorkingArea }
    $m = [System.Windows.PresentationSource]::FromVisual($script:window).CompositionTarget.TransformFromDevice
    $tl = $m.Transform([System.Windows.Point]::new($r.Left, $r.Top))
    $br = $m.Transform([System.Windows.Point]::new($r.Right, $r.Bottom))
    [System.Windows.Rect]::new($tl, $br)
}

function Get-WtBounds { [System.Windows.Rect]::new($script:window.Left, $script:window.Top, $script:window.Width, $script:window.Height) }

function Set-WtBounds([System.Windows.Rect]$R) {
    $script:settingBounds = $true
    try {
        $script:window.Left = $R.Left
        $script:window.Top = $R.Top
        $script:window.Width = $R.Width
        $script:window.Height = $R.Height
    } finally {
        $script:settingBounds = $false
    }
}

function Update-WtMaxGlyph {
    $script:ui.MaxGlyph.Text = [string][char]$(if ($script:maxed -or $script:fullscreen) { 0xE923 } else { 0xE922 })
    $script:ui.MaxButton.ToolTip = if ($script:maxed -or $script:fullscreen) { '이전 크기로' } else { '최대화' }
    $script:ui.Frame.BorderThickness = [System.Windows.Thickness]::new($(if ($script:maxed -or $script:fullscreen) { 0 } else { 1 }))
}

# 최대화는 WindowState 대신 작업 영역 크기로 맞춘다 (테두리 없는 창을 Maximized로 두면 작업 표시줄을 덮는다)
function Switch-WtMaximize {
    if ($script:fullscreen) { Switch-WtFullScreen; return }
    if ($script:maxed) {
        Set-WtBounds $script:restoreBounds
        $script:maxed = $false
    } else {
        $script:restoreBounds = Get-WtBounds
        Set-WtBounds (Get-WtScreenRect)
        $script:maxed = $true
    }
    Update-WtMaxGlyph
}

function Switch-WtFullScreen {
    if ($script:fullscreen) {
        $script:fullscreen = $false
        if ($script:fullFromMax) {
            Set-WtBounds (Get-WtScreenRect)
            $script:maxed = $true
        } else {
            Set-WtBounds $script:restoreBounds
            $script:maxed = $false
        }
    } else {
        $script:fullFromMax = $script:maxed
        if (-not $script:maxed) { $script:restoreBounds = Get-WtBounds }
        Set-WtBounds (Get-WtScreenRect -Full)
        $script:fullscreen = $true
    }
    Update-WtMaxGlyph
}

# ---- 트레이 · 종료 ----------------------------------------------------------------------------

# 앱 아이콘 그림 하나(PNG): 강조색 둥근 사각형에 흰 W. 파일 없이 그린다
function New-WtAppIconPng([int]$Size, [string]$Hex) {
    $dv = [System.Windows.Media.DrawingVisual]::new()
    $dc = $dv.RenderOpen()
    $bg = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $r = [Math]::Max(2, $Size * 0.22)
    $dc.DrawRoundedRectangle($bg, $null, [System.Windows.Rect]::new(0, 0, $Size, $Size), $r, $r)
    $tf = [System.Windows.Media.Typeface]::new([System.Windows.Media.FontFamily]::new('Segoe UI'), [System.Windows.FontStyles]::Normal,
        [System.Windows.FontWeights]::Bold, [System.Windows.FontStretches]::Normal)
    $ft = [System.Windows.Media.FormattedText]::new('W', [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Windows.FlowDirection]::LeftToRight, $tf, $Size * 0.62, [System.Windows.Media.Brushes]::White, 1.0)
    $geo = $ft.BuildGeometry([System.Windows.Point]::new(0, 0))
    $b = $geo.Bounds
    # 글자 모양(잉크)의 가운데를 그림 가운데에 맞춘다. 작은 크기에서 흐리지 않게 정수 위치로
    $dc.PushTransform([System.Windows.Media.TranslateTransform]::new([Math]::Round(($Size - $b.Width) / 2 - $b.X), [Math]::Round(($Size - $b.Height) / 2 - $b.Y)))
    $dc.DrawGeometry([System.Windows.Media.Brushes]::White, $null, $geo)
    $dc.Pop()
    $dc.Close()
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($Size, $Size, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($dv)
    $enc = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $ms = [System.IO.MemoryStream]::new()
    $enc.Save($ms)
    , $ms.ToArray()
}

# 앱 아이콘(.ico 내용): 크기별 그림을 하나로 묶는다. 트레이(16~24) · 제목 줄 · 작업 표시줄(24~48) · 큰 아이콘(256)에서
# Windows가 화면 배율에 맞는 크기를 고르므로 늘리거나 줄여서 흐려지지 않는다.
function New-WtAppIconBytes {
    $hex = (Get-WtThemeColors ([string](Get-WtSetting 'theme.color'))).Accent
    $sizes = @(16, 20, 24, 32, 40, 48, 64, 256)
    $pngs = @(foreach ($s in $sizes) { , (New-WtAppIconPng $s $hex) })
    $ms = [System.IO.MemoryStream]::new()
    $w = [System.IO.BinaryWriter]::new($ms)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)   # ICO 머리: 예약 · 종류(1=아이콘) · 개수
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $s = $sizes[$i]
        $w.Write([byte]($s % 256)); $w.Write([byte]($s % 256))   # 너비 · 높이 (256은 0)
        $w.Write([byte]0); $w.Write([byte]0)                     # 색 수 · 예약
        $w.Write([uint16]1); $w.Write([uint16]32)                # 면 · 색 깊이
        $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write([byte[]]$p) }
    $w.Flush()
    , $ms.ToArray()
}

# 창 · 트레이 아이콘을 지금 테마 색으로 (다시) 만든다
function Update-WtAppIcon {
    $bytes = New-WtAppIconBytes
    $old = $script:icon
    $script:icon = [System.Drawing.Icon]::new([System.IO.MemoryStream]::new($bytes), [System.Windows.Forms.SystemInformation]::SmallIconSize)
    # 아이콘 해석기로 읽은 그림을 주면 WPF가 그 안에서 제목 줄 · 작업 표시줄에 맞는 크기를 고른다
    $dec = [System.Windows.Media.Imaging.IconBitmapDecoder]::new([System.IO.MemoryStream]::new($bytes),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    # 창이 생성된 뒤에도 다시 설정해 Windows가 창의 정식 아이콘을 갱신하게 한다.
    $script:window.Icon = $null
    $script:window.Icon = ($dec.Frames | Where-Object PixelWidth -eq 32 | Select-Object -First 1)
    if (-not $script:window.TaskbarItemInfo) { $script:window.TaskbarItemInfo = [System.Windows.Shell.TaskbarItemInfo]::new() }
    $script:window.TaskbarItemInfo.Description = 'WorkTool'
    $script:window.TaskbarItemInfo.Overlay = $null
    if ($script:notify) { $script:notify.Icon = $script:icon }
    if ($old) { $old.Dispose() }
}

function Show-WtMainWindow {
    $script:window.Show()
    if ($script:window.WindowState -eq 'Minimized') { $script:window.WindowState = 'Normal' }
    [void]$script:window.Activate()
}

# 저장하지 못한 내용이 있을 때 묻는다. 'retry'(다시 시도) · 'proceed'(그대로 끝내기 · 이동) · 'cancel' 중 하나를 돌려준다.
function Show-WtPendingChoice([string]$Purpose, [string]$Title) {
    $exit = $Purpose -eq 'exit'
    $dialog = New-WtModal $(if ($exit) { '저장하지 않고 끝낼까요?' } else { '저장하지 않고 이동할까요?' })
    $text = if ($exit) { "$Title 화면에서 저장하지 못한 내용은 끝내면 사라집니다." }
    else { "$Title 화면에서 저장하지 못한 내용은 그 화면에 그대로 남습니다." }
    [void](Add-WtChild $dialog.Body (New-WtText $text))
    $retry = New-WtButton '다시 시도' -Kind Primary; $retry.IsDefault = $true
    $go = if ($exit) { New-WtButton '끝내기' -Kind Danger } else { New-WtButton '이동' }
    $cancel = New-WtButton '취소'; $cancel.IsCancel = $true
    $dialog.Window.Tag = @{ Choice = 'cancel'; Focus = $retry }
    foreach ($pair in @(@($retry, 'retry'), @($go, 'proceed'))) {
        $pair[0].Tag = @{ Window = $dialog.Window; Choice = $pair[1] }
        $pair[0].Add_Click({ param($s, $e) $s.Tag.Window.Tag.Choice = $s.Tag.Choice; $s.Tag.Window.DialogResult = $true })
        [void](Add-WtChild $dialog.Buttons $pair[0])
    }
    [void](Add-WtChild $dialog.Buttons $cancel)
    $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Focus.Focus() })
    [void]$dialog.Window.ShowDialog()
    [string]$dialog.Window.Tag.Choice
}

# 저장하지 않은 내용을 저장한다. 계속해도 되면 $true.
# -Purpose exit · switch: 저장하지 못하면 다시 시도 · 그대로 진행 · 취소를 묻는다. 막기만 하면 끄거나 옮길 방법이 없어진다.
#          check: 묻지 않고 알린 뒤 $false (예전 데이터 가져오기처럼 덮어쓰는 작업 전)
# -Only: 그 애드온만 확인한다 (화면을 떠날 때는 떠나는 화면만)
function Save-WtPendingChanges([ValidateSet('check', 'switch', 'exit')][string]$Purpose = 'check', [string]$Only = '') {
    foreach ($a in @(Get-WtAddon -All)) {
        if (-not $a.SavePending -or ($Only -and $a.Id -ne $Only)) { continue }
        while ($true) {
            $saved = $false
            try { $saved = (@(& $a.SavePending) | Select-Object -Last 1) -ne $false }
            catch { Show-WtError $_ "저장 확인: $($a.Title)" }
            if ($saved) { break }
            if ($Purpose -eq 'check') {
                Show-WtMessage "$($a.Title) 화면에 저장하지 못한 내용이 있습니다. 저장 오류를 해결한 뒤 다시 시도하세요." '저장 확인' 'Warning'
                return $false
            }
            # 트레이에 숨어 있으면 창을 띄워서 무엇을 저장하지 못했는지 볼 수 있게 한다
            if ($script:window -and -not $script:window.IsVisible) { Show-WtMainWindow }
            $choice = Show-WtPendingChoice $Purpose $a.Title
            if ($choice -eq 'retry') { continue }
            if ($choice -eq 'proceed') { break }
            return $false
        }
    }
    $true
}

# 저장을 확인한 뒤에만(또는 저장하지 않고 끝내기를 고른 뒤에만) 트레이·타이머를 정리하고 메시지 돌리기를 멈춘다.
function Stop-WtApp {
    if (-not $script:exiting) {
        if (-not (Save-WtPendingChanges -Purpose exit)) { return $false }
        foreach ($a in @(Get-WtAddon -All)) {
            if ($a.OnExit) { try { [void](& $a.OnExit) } catch { Show-WtError $_ "끝내기 전 저장: $($a.Title)" } }
        }
    }
    $script:exiting = $true
    if ($script:warmTimer) { $script:warmTimer.Stop() }
    try { $script:notify.Visible = $false; $script:notify.Dispose() } catch { }
    try { if ($script:icon) { $script:icon.Dispose() } } catch { }
    if ($script:frame) { $script:frame.Continue = $false }
    $true
}

function Exit-WtApp {
    if (-not (Stop-WtApp)) { return }
    try { $script:window.Close() } catch { }
}

function Update-WtCloseTip {
    $script:ui.CloseButton.ToolTip = if ([bool](Get-WtSetting 'window.closeToTray')) { '닫기 (트레이에서 계속 실행)' } else { '닫기' }
}

function New-WtTrayIcon([System.Drawing.Icon]$Icon) {
    $n = [System.Windows.Forms.NotifyIcon]::new()
    $n.Icon = $Icon
    $n.Text = 'WorkTool'
    $menu = [System.Windows.Forms.ContextMenuStrip]::new()
    [void]$menu.Items.Add('열기', $null, { Show-WtMainWindow })
    [void]$menu.Items.Add('종료', $null, { Exit-WtApp })
    $n.ContextMenuStrip = $menu
    $n.Add_MouseDoubleClick({ Show-WtMainWindow })
    $n.Visible = $true
    $n
}

# ---- 예전 데이터 가져오기 ----------------------------------------------------------------------

# 예전 WorkTool(WinForms) data 폴더에서 탭마다 데이터를 가져온다.
# -Force가 없으면 아직 저장소가 없는 탭만 가져온다 (처음 실행할 때).
function Import-WtLegacyData([switch]$Force) {
    if ($Force -and -not (Save-WtPendingChanges)) { throw '저장하지 못한 내용이 있어 가져오기를 취소했습니다.' }
    $folder = Find-WtLegacyFolder
    $result = @{ Folder = $folder; Count = 0; Tabs = @(); At = $null }
    if (-not $folder) { return $result }
    foreach ($a in @(Get-WtAddon -All)) {
        if (-not $a.ImportLegacy) { continue }
        if (-not $Force -and (Test-WtStore $a.Id)) { continue }
        $n = & $a.ImportLegacy $folder | Select-Object -Last 1
        if ($null -ne $n) {
            $result.Count += [int]$n
            $result.Tabs += "$($a.Title) $n"
        }
    }
    if ($result.Tabs.Count) {
        $result.At = Get-Date
        $script:lastImport = $result
    }
    $result
}

function Get-WtLastImport { $script:lastImport }

# ---- 시작 -------------------------------------------------------------------------------------

function Start-WtApp {
    param([Parameter(Mandatory)][string]$AppRoot)

    $script:exiting = $false
    $script:notify = $null
    $script:views = @{}
    $script:current = $null
    $script:maxed = $false
    $script:fullscreen = $false
    $script:warmEnabled = $env:WORKTOOL_WARMUP -eq '1'
    $script:warmStarted = $false
    $script:warmQueue = $null
    if ($script:warmTimer) { $script:warmTimer.Stop() }
    $script:forceOpaque = $env:WORKTOOL_FORCE_OPAQUE -eq '1'
    Set-WtAppRoot $AppRoot
    $dataLock = Open-WtDataLock
    try {
    Initialize-WtSettings
    $script:themeDict = New-WtThemeDictionary

    $w = ConvertFrom-WtXaml $script:shellXaml
    $script:window = $w
    $script:ui = Get-WtNamedElements $w $script:shellXaml
    $w.Resources.MergedDictionaries.Add($script:themeDict)
    $w.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    # 투명 창은 ClearType이 꺼져 글자가 흐리게(회색조로) 그려진다. 불투명도 100%로 시작하면 보통 창으로 만들어 또렷하게 그린다
    if ($script:forceOpaque -or [double](Get-WtSetting 'ui.opacity') -ge 100) {
        $w.AllowsTransparency = $false
        $w.Opacity = 1.0
        $w.SetResourceReference([System.Windows.Window]::BackgroundProperty, 'B.WindowBg')
    }

    Update-WtAppIcon
    $w.Add_ContentRendered({ Update-WtAppIcon; Start-WtWarmUp })
    $script:ui.TodayText.Text = Format-WtDate (Get-Date) 'yyyy년 M월 d일 dddd'

    # 제목 줄 · 메뉴 아래 버튼
    $script:ui.CollapseButton.Add_Click({ Switch-WtCollapsed })
    $script:ui.MinButton.Add_Click({ $script:window.WindowState = 'Minimized' })
    $script:ui.MaxButton.Add_Click({ Switch-WtMaximize })
    $script:ui.CloseButton.Add_Click({ $script:window.Close() })
    $script:ui.SettingsButton.Add_Click({ Select-WtPage '_settings' })
    $script:ui.HelpButton.Add_Click({ Select-WtPage '_help' })

    # 제목 줄을 두 번 누르면 Windows가 Maximized로 바꾼다 → 작업 영역 최대화로 바꿔 준다
    $w.Add_StateChanged({
            if ($script:window.WindowState -eq 'Maximized') {
                $script:window.WindowState = 'Normal'
                Switch-WtMaximize
            }
        })

    # 최대화 · 전체 화면 상태에서 제목 줄을 끌어 옮기면 그 표시를 푼다 (다음 최대화 버튼이 바로 최대화하도록)
    $w.Add_LocationChanged({
            if ($script:settingBounds -or -not ($script:maxed -or $script:fullscreen)) { return }
            $script:maxed = $false
            $script:fullscreen = $false
            Update-WtMaxGlyph
        })

    # X(닫기)는 앱을 끝낸다. 설정에서 '트레이로 숨기기'를 켜면 트레이로 숨기고, 끄는 건 트레이 아이콘 우클릭 → 종료
    $w.Add_Closing({
            param($s, $e)
            if ($script:exiting) { return }
            if (-not [bool](Get-WtSetting 'window.closeToTray')) { $e.Cancel = -not (Stop-WtApp); return }
            $e.Cancel = $true
            $s.Hide()
            if (-not $script:trayTipShown) {
                $script:notify.ShowBalloonTip(3000, 'WorkTool', '트레이에서 계속 실행 중입니다. 끄려면 트레이 아이콘 우클릭 → 종료.',
                    [System.Windows.Forms.ToolTipIcon]::Info)
                $script:trayTipShown = $true
            }
        })

    $w.Add_PreviewKeyDown({
            param($s, $e)
            try {
                $ctrl = ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
                $key = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
                if ($ctrl -and $key -eq 'B' -and -not (Test-WtKeyOwned 'Ctrl+B')) { Switch-WtCollapsed; $e.Handled = $true; return }
                if ($key -eq 'F11') { Switch-WtFullScreen; $e.Handled = $true; return }
                if ($key -eq 'Escape' -and $script:fullscreen) { Switch-WtFullScreen; $e.Handled = $true; return }
                if ($key -eq 'F1') { Select-WtPage '_help'; $e.Handled = $true; return }
                if ($ctrl -and $key -eq 'OemComma') { Select-WtPage '_settings'; $e.Handled = $true; return }
                if ($ctrl -and [int]$key -ge [int][System.Windows.Input.Key]::D1 -and [int]$key -le [int][System.Windows.Input.Key]::D9) {
                    $ids = @(Get-WtAddon | ForEach-Object { $_.Id })
                    $idx = [int]$key - [int][System.Windows.Input.Key]::D1
                    if ($idx -lt $ids.Count) { Select-WtPage $ids[$idx] }
                    $e.Handled = $true
                }
            } catch { Show-WtError $_ '단축키' }
        })

    if ($global:WorkToolUnhandledHandler) {
        try { $w.Dispatcher.remove_UnhandledException($global:WorkToolUnhandledHandler) } catch { }
    }
    $global:WorkToolUnhandledHandler = [System.Windows.Threading.DispatcherUnhandledExceptionEventHandler] {
        param($s, $e)
        Show-WtError $e.Exception '처리되지 않은 오류'
        $e.Handled = $true
    }
    $w.Dispatcher.add_UnhandledException($global:WorkToolUnhandledHandler)

    # 설정이 바뀌면 바로 반영한다
    Register-WtSettingHandler {
        param($key, $value)
        switch -Wildcard ($key) {
            'theme.color' { Update-WtThemeDictionary $script:themeDict; Update-WtAppIcon }
            'ui.fontScale' { Update-WtThemeDictionary $script:themeDict }
            'ui.opacity' { Set-WtOpacity }
            'nav.collapsed' { Update-WtCollapsed }
            'window.closeToTray' { Update-WtCloseTip }
            'addons.disabled' { Update-WtNav }
        }
    }

    # 처음 실행이면 예전 WorkTool 데이터를 가져온다 (이미 가져온 탭은 건너뜀)
    try { [void](Import-WtLegacyData) } catch { Show-WtError $_ '예전 데이터 가져오기' }

    Update-WtNav
    Update-WtCloseTip
    Set-WtOpacity
    $script:notify = New-WtTrayIcon $script:icon

    # 창이 닫힐 때까지 메시지를 돌린다. Dispatcher를 끄지 않으므로 같은 창에서 다시 실행해도 된다.
    $script:frame = [System.Windows.Threading.DispatcherFrame]::new()
    $w.Show()
    # 실행 파일이 콘솔을 최소화해서 띄우면(start /min) 첫 창도 최소화돼서 뜬다 → 원래 크기로 앞에 띄운다
    if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
    [void]$w.Activate()
    $first = @(Get-WtAddon)[0]
    if ($first) { Select-WtPage $first.Id } else { Select-WtPage '_settings' }
    if (-not $script:exiting) { [System.Windows.Threading.Dispatcher]::PushFrame($script:frame) }
    } finally {
        if ($script:warmTimer) { $script:warmTimer.Stop() }
        $script:warmQueue = $null
        try {
            if ($script:notify) { $script:notify.Visible = $false; $script:notify.Dispose() }
            if ($script:icon) { $script:icon.Dispose() }
        } finally { $dataLock.Dispose() }
    }
}

Export-ModuleMember -Function Get-WtWindow, Select-WtPage, Reset-WtViews, Update-WtNav, Switch-WtCollapsed, Register-WtKeyOwner, Test-WtKeyOwned,
    Set-WtOpacity, Test-WtOpacityNeedsRestart,
    Switch-WtMaximize, Switch-WtFullScreen, Show-WtMainWindow, Exit-WtApp, Import-WtLegacyData, Get-WtLastImport, Start-WtApp
} | Import-Module -Force -DisableNameChecking
# ---- core\Shell.psm1 끝 ----

# ---- addons\active-tasks\ActiveTasks.psm1 ----
New-Module -Name 'WorkTool.addon.active-tasks' -ScriptBlock {
# 활성 작업. 창/탭 제목은 메모리에만 두고, 새로 고침 설정만 Settings를 통해 저장한다.
# 수집/닫기는 별도 MTA runspace에서 Windows 기본 UI Automation으로 처리한다.
$ErrorActionPreference = 'Stop'
$script:ui = @{}
$script:items = @()
$script:snapshotKey = $null
$script:snapshotVersion = 0
$script:listKey = $null
$script:visible = @()
$script:expanded = @{}
$script:job = $null
$script:workerRunspace = $null
$script:timer = $null
$script:paused = $false
$script:next = [datetime]::MaxValue
$script:lastScan = $null
$script:resultText = ''
$script:lastError = ''
$script:appFilter = '*'
$script:sortColumn = 'DisplayTitle'
$script:sortDirection = 'Ascending'
$script:focusTarget = $null   # 표를 다시 만든 뒤 포커스를 돌려줄 체크박스 @{ Id } 또는 @{ Group }
Register-WtSettingDefault 'tasks.refresh' @{ mode = 'manual'; minutes = 5 }

function ConvertTo-WtTaskMinutes([string]$Text) {
    $value = 0
    if ($Text.Trim() -notmatch '^[0-9]+$' -or -not [int]::TryParse($Text.Trim(), [ref]$value) -or $value -lt 1 -or $value -gt 1440) {
        throw '1~1,440분 사이의 정수를 입력하세요.'
    }
    $value
}

function Get-WtTaskRefresh {
    $option = Get-WtSetting 'tasks.refresh'
    try {
        $minutes = ConvertTo-WtTaskMinutes ([string]$option.minutes)
        $mode = if ($option.mode -eq 'auto') { 'auto' } else { 'manual' }
        @{ mode = $mode; minutes = $minutes }
    } catch { @{ mode = 'manual'; minutes = 5 } }
}

function Set-WtTaskRefresh([string]$Mode, [string]$Minutes) {
    if ($Mode -notin @('manual', 'auto')) { throw '새로 고침 모드를 확인하세요.' }
    $value = ConvertTo-WtTaskMinutes $Minutes
    $previous = Get-WtTaskRefresh
    try { Set-WtSetting 'tasks.refresh' @{ mode = $Mode; minutes = $value } }
    catch {
        # Settings가 파일 쓰기 전에 메모리를 바꾸므로, 쓰기 실패 시 메모리도 되돌린다.
        try { Set-WtSetting 'tasks.refresh' $previous } catch { }
        throw
    }
    $script:next = [datetime]::UtcNow.AddMinutes($value)
    Update-WtTaskStatus
}

function Test-WtTaskAutoDue([string]$Mode, [datetime]$Now, [datetime]$Due, [bool]$Visible, [bool]$Paused, [bool]$Busy) {
    $Mode -eq 'auto' -and $Visible -and -not $Paused -and -not $Busy -and $Now -ge $Due
}

function Find-WtTaskItems([object[]]$Items, [string]$Query, [string]$App = '*') {
    $words = @($Query.Trim() -split '\s+' | Where-Object { $_ })
    @($Items | Where-Object {
        $row = $_
        $ok = $App -eq '*' -or $row.AppKey -eq $App
        foreach ($word in $words) { if ($row.DisplayTitle.IndexOf($word, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false } }
        $ok
    })
}

function Get-WtTaskCheckState([object[]]$Items) {
    $available = @($Items | Where-Object CanClose)
    $picked = @($available | Where-Object Selected).Count
    if (-not $picked) { return $false }
    if ($picked -eq $available.Count) { return $true }
    $null
}

# WorkTool을 띄운 터미널 · 편집기 같은 조상 프로세스. 그 창을 닫으면 WorkTool도 꺼지므로 표에는 보여 주되 닫지 않는다.
# 탐색기 · 시스템 프로세스에서 멈춘다(그 창들은 그대로 닫을 수 있게). 이미 끝난 부모의 PID를 다른 프로그램이 받았으면 시작 시각으로 걸러 낸다.
function Get-WtTaskHostIds {
    $ids = [System.Collections.Generic.List[int]]::new()
    $stop = @('explorer', 'svchost', 'sihost', 'services', 'wininit', 'winlogon', 'userinit', 'RuntimeBroker', 'csrss', 'smss')
    try {
        $child = Get-Process -Id $PID
        for ($depth = 0; $depth -lt 8; $depth++) {
            $parent = $child.Parent
            if (-not $parent -or $parent.ProcessName -in $stop -or $parent.StartTime -gt $child.StartTime) { break }
            $ids.Add($parent.Id)
            $child = $parent
        }
    } catch { }
    $ids.ToArray()
}

function Set-WtTaskSnapshot([object[]]$Items) {
    $key = ConvertTo-Json -Compress -Depth 5 -InputObject @($Items | Select-Object -Property * -ExcludeProperty Selected)
    $picked = @{}
    foreach ($row in $script:items) { if ($row.Selected) { $picked[$row.Id] = $true } }
    foreach ($row in $Items) { $row.Selected = $row.CanClose -and $picked.ContainsKey($row.Id) }
    if ($script:snapshotKey -cne $key) {
        $script:items = @($Items); $script:snapshotKey = $key; $script:snapshotVersion++
    }
    $script:lastScan = Get-Date
}

# 이 스크립트 블록은 같은 모듈의 소스다. 묶음 배포에서도 외부 파일/모듈이 필요 없다.
# Handles/BrowserNames는 격리된 검사에서만 주입한다. 실제 화면에서는 지정하지 않는다.
$script:worker = {
    param($request)
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $A = [System.Windows.Automation.AutomationElement]
    $T = [System.Windows.Automation.TreeScope]
    $C = [System.Windows.Automation.ControlType]
    $all = [System.Windows.Automation.Condition]::TrueCondition

    function Get-Pattern($element, $pattern) {
        $value = $null
        if ($element.TryGetCurrentPattern($pattern, [ref]$value)) { return $value }
        $null
    }
    function Get-Identity($element) { $element.GetRuntimeId() -join '.' }
    function Get-TabTitle([string]$text) {
        # Edge가 탭 접근성 이름 끝에 늦게 덧붙이는 메모리 안내는 페이지 제목이 아니다.
        $text -replace '\s+-\s+(?:메모리 사용량|Memory usage)\s+-\s+[\d.,]+\s*(?:KB|MB|GB|TB)\s*$', ''
    }
    function Get-ProcessInfo([int]$number) {
        $p = Get-Process -Id $number -ErrorAction Stop
        try { @{ Name = $p.ProcessName; Start = $p.StartTime.ToUniversalTime().Ticks } } finally { $p.Dispose() }
    }
    function Get-TabClose($tab) {
        $condition = [System.Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $C::Button)
        foreach ($button in $tab.FindAll($T::Descendants, $condition)) {
            $info = $button.Current
            if (($info.Name -match '^(Close tab|Close|탭 닫기|닫기)(\s|$)' -or $info.AutomationId -match '^(TabCloseButton|CloseTabButton)$') -and $info.IsEnabled) {
                $invoke = Get-Pattern $button ([System.Windows.Automation.InvokePattern]::Pattern)
                if ($invoke) { return $button }
            }
        }
        $null
    }
    function Get-Tabs($window) {
        $queue = [Collections.Generic.Queue[object]]::new()
        $queue.Enqueue(@{ Element = $window; Depth = 0 })
        $tabs = [Collections.Generic.List[object]]::new()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $seen = 0; $partial = $false
        while ($queue.Count) {
            if ($request.Cancel.Value -or $seen -ge 600 -or $watch.Elapsed.TotalSeconds -gt 4) { $partial = $true; break }
            $node = $queue.Dequeue(); $seen++
            $element = $node.Element
            try {
                $type = $element.Current.ControlType
                # 웹 페이지 본문으로 내려가지 않는다. 페이지 안 ARIA 탭을 브라우저 탭으로 오인하지 않는다.
                if ($type -eq $C::Document) { continue }
                if ($type -eq $C::TabItem) { $tabs.Add($element); continue }
                if ($node.Depth -ge 10) { $partial = $true; continue }
                foreach ($child in $element.FindAll($T::Children, $all)) {
                    $queue.Enqueue(@{ Element = $child; Depth = $node.Depth + 1 })
                }
            } catch { $partial = $true }
        }
        @{ Tabs = @($tabs.ToArray()); Partial = $partial }
    }
    function New-Row($windowInfo, $processInfo, [string]$windowId, [int]$ordinal, [string]$kind, [string]$title, [string]$runtime, [int]$tabIndex, [bool]$canClose, [string]$status) {
        $labels = @{ chrome = 'Google Chrome'; msedge = 'Microsoft Edge'; whale = '네이버 웨일'; EXCEL = 'Microsoft Excel'; WINWORD = 'Microsoft Word'; POWERPNT = 'Microsoft PowerPoint'; explorer = '파일 탐색기'; notepad = '메모장' }
        $appLabel = $processInfo.Name
        if ($labels.ContainsKey($appLabel)) { $appLabel = $labels[$appLabel] }
        [pscustomobject]@{
            Id = "${windowId}/${kind}/${runtime}"; AppKey = $processInfo.Name; AppLabel = $appLabel
            Title = $title; DisplayTitle = $title; Kind = $kind; KindLabel = $(if ($kind -eq 'tab') { '탭' } else { '창' })
            WindowKey = $windowId; WindowNumber = $ordinal; WindowLabel = "창 $ordinal"; TabIndex = $tabIndex
            ProcessId = $windowInfo.ProcessId; ProcessStart = $processInfo.Start; Handle = $windowInfo.NativeWindowHandle
            WindowRuntime = $windowInfo.Runtime; Runtime = $runtime; Status = $status; Selected = $false
            CanClose = $canClose; CloseHint = $(if ($canClose) { '닫을 항목 선택' } else { '이 항목은 여기서 닫을 수 없습니다. 원래 프로그램에서 확인하세요.' })
        }
    }
    function Read-Snapshot {
        $windows = @()
        if ($request.ContainsKey('Handles')) {
            if (-not @($request.Handles).Count -or @($request.Handles | Where-Object { -not $_ -or [long]$_ -le 0 }).Count) { throw '지정한 창 식별자가 없습니다. 전체 창 조회로 전환하지 않습니다.' }
            foreach ($handle in $request.Handles) { $windows += $A::FromHandle([intptr]$handle) }
        }
        else {
            $condition = [System.Windows.Automation.PropertyCondition]::new($A::ControlTypeProperty, $C::Window)
            $windows = @($A::RootElement.FindAll($T::Children, $condition))
        }
        $rows = [Collections.Generic.List[object]]::new()
        $ordinals = @{}; $failed = 0
        # 탭 단위로 다루는 Chromium 계열 브라우저. 탭을 못 읽으면 창 전체를 닫는 대신 '탭 확인 불가'로 둔다
        $browsers = if ($request.BrowserNames) { $request.BrowserNames } else { @('chrome', 'msedge', 'whale') }
        $hosts = @($request.HostProcessIds)
        foreach ($window in $windows) {
            if ($request.Cancel.Value) { break }
            try {
                $info = $window.Current
                if (-not $info.NativeWindowHandle -or $info.ProcessId -eq $request.SelfProcessId -or -not $info.Name) { continue }
                $wp = Get-Pattern $window ([System.Windows.Automation.WindowPattern]::Pattern)
                if ($wp -and $wp.Current.IsModal) { continue }
                if ($info.ClassName -in @('Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Progman', 'WorkerW')) { continue }
                $processInfo = Get-ProcessInfo $info.ProcessId
                $windowRuntime = Get-Identity $window
                $wi = @{ ProcessId = $info.ProcessId; NativeWindowHandle = $info.NativeWindowHandle; Runtime = $windowRuntime }
                $windowId = '{0}:{1}:{2}:{3}' -f $info.ProcessId, $processInfo.Start, $info.NativeWindowHandle, $windowRuntime
                if (-not $ordinals.ContainsKey($processInfo.Name)) { $ordinals[$processInfo.Name] = 0 }
                $ordinals[$processInfo.Name]++
                $ordinal = $ordinals[$processInfo.Name]
                $minimized = $wp -and $wp.Current.WindowVisualState -eq 'Minimized'
                if ($info.ProcessId -in $hosts) {
                    $row = New-Row $wi $processInfo $windowId $ordinal 'window' $info.Name $windowRuntime 0 $false 'WorkTool 실행 중'
                    $row.CloseHint = 'WorkTool이 이 프로그램에서 실행 중입니다. 닫으면 WorkTool도 꺼지므로 여기서는 닫지 않습니다.'
                    $rows.Add($row)
                    continue
                }
                if ($processInfo.Name -notin $browsers) {
                    $status = if ($minimized) { '최소화' } elseif (-not $wp) { '닫기 지원 안 됨' } else { '' }
                    $rows.Add((New-Row $wi $processInfo $windowId $ordinal 'window' $info.Name $windowRuntime 0 ([bool]$wp) $status))
                    continue
                }
                $read = Get-Tabs $window
                $index = 0
                foreach ($tab in $read.Tabs) {
                    $index++
                    try {
                        $tabInfo = $tab.Current
                        $selection = Get-Pattern $tab ([System.Windows.Automation.SelectionItemPattern]::Pattern)
                        $states = @()
                        if ($selection -and $selection.Current.IsSelected) { $states += '현재 탭' }
                        if ($minimized) { $states += '최소화된 창' }
                        $close = Get-TabClose $tab
                        if (-not $close) { $states += '닫기 지원 안 됨' }
                        $title = if ($tabInfo.Name) { Get-TabTitle $tabInfo.Name } else { "제목 없는 탭 $index" }
                        $rows.Add((New-Row $wi $processInfo $windowId $ordinal 'tab' $title (Get-Identity $tab) $index ([bool]$close) ($states -join ' · ')))
                    } catch { $read.Partial = $true }
                }
                if (-not $read.Tabs.Count -or $read.Partial) {
                    $status = if ($read.Tabs.Count) { '일부 탭 확인 불가' } else { '탭 확인 불가' }
                    $rows.Add((New-Row $wi $processInfo $windowId $ordinal 'unavailable' $info.Name $windowRuntime 0 $false $status))
                }
            } catch { $failed++ }
        }
        foreach ($duplicates in @($rows | Where-Object Kind -eq 'tab' | Group-Object WindowKey, Title | Where-Object Count -gt 1)) {
            foreach ($row in $duplicates.Group) { $row.DisplayTitle = '{0} (탭 {1})' -f $row.Title, $row.TabIndex }
        }
        @{ Items = @($rows.ToArray()); FailedWindows = $failed; Canceled = [bool]$request.Cancel.Value }
    }
    function Find-Target($target) {
        $processInfo = Get-ProcessInfo $target.ProcessId
        if ($processInfo.Start -ne $target.ProcessStart) { throw '프로그램이 다시 시작되었습니다. 새로 고침하세요.' }
        $window = $A::FromHandle([intptr]$target.Handle)
        if ($window.Current.ProcessId -ne $target.ProcessId -or (Get-Identity $window) -ne $target.WindowRuntime) { throw '창이 바뀌었습니다. 새로 고침하세요.' }
        $wp = Get-Pattern $window ([System.Windows.Automation.WindowPattern]::Pattern)
        if ($wp -and $wp.Current.WindowInteractionState -eq 'BlockedByModalWindow') { throw '원래 프로그램의 확인창을 처리하세요.' }
        if ($target.Kind -eq 'window') { return $window }
        if ($target.Kind -ne 'tab') { throw '닫기를 지원하지 않는 항목입니다.' }
        $read = Get-Tabs $window
        foreach ($tab in $read.Tabs) { if ((Get-Identity $tab) -eq $target.Runtime) { return $tab } }
        if ($read.Partial) { throw '탭을 다시 확인하지 못했습니다.' }
        $null
    }
    if ($request.Action -eq 'scan') { Read-Snapshot; return }
    $results = [Collections.Generic.List[object]]::new()
    foreach ($target in $request.Targets) {
        $state = 'failed'; $message = ''
        try {
            if ($request.Cancel.Value) { $state = 'canceled'; $message = '취소됨' }
            elseif ($target.ProcessId -in @($request.HostProcessIds)) { throw 'WorkTool이 실행 중인 프로그램이라 닫지 않습니다.' }
            else {
                $element = Find-Target $target
                if (-not $element) { $state = 'gone'; $message = '이미 없음' }
                else {
                    $currentTitle = if ($target.Kind -eq 'tab') { Get-TabTitle $element.Current.Name } else { $element.Current.Name }
                    if ($currentTitle -ne $target.Title) { throw '제목이 바뀌었습니다. 새로 고침 후 다시 선택하세요.' }
                    if ($target.Kind -eq 'window') {
                        $pattern = Get-Pattern $element ([System.Windows.Automation.WindowPattern]::Pattern)
                        if (-not $pattern) { throw '이 창은 여기서 닫을 수 없습니다.' }
                        $pattern.Close()
                    } else {
                        $button = Get-TabClose $element
                        if (-not $button) { throw '이 탭은 여기서 닫을 수 없습니다.' }
                        $pattern = Get-Pattern $button ([System.Windows.Automation.InvokePattern]::Pattern)
                        $pattern.Invoke()
                    }
                    $state = 'confirmation'; $message = '확인 필요'
                    for ($attempt = 0; $attempt -lt 10; $attempt++) {
                        if ($request.Cancel.Value) { break }
                        [Threading.Thread]::Sleep(150)
                        try {
                            # 닫힌 탭의 원래 UIA 요소를 먼저 확인한다. 다른 UI 영역을 못 읽어도 이 요소의 소멸은 확인할 수 있다.
                            [void]$element.GetCurrentPropertyValue($A::NameProperty, $true)
                            if (-not (Find-Target $target)) { $state = 'closed'; $message = '닫힘'; break }
                        } catch [System.Windows.Automation.ElementNotAvailableException] { $state = 'closed'; $message = '닫힘'; break }
                        catch {
                            $message = '확인 필요: ' + $_.Exception.Message
                            if ($_.Exception.Message -eq '원래 프로그램의 확인창을 처리하세요.') { break }
                        }
                    }
                }
            }
        } catch { $message = $_.Exception.Message }
        $results.Add([pscustomobject]@{ Id = $target.Id; Title = $target.DisplayTitle; State = $state; Message = $message })
    }
    @{ Results = @($results.ToArray()) }
}

function Get-WtTaskWorker { $script:worker }

function Start-WtTaskJob([string]$Action, [object[]]$Targets = @()) {
    if ($script:job) { return }
    $cancel = [hashtable]::Synchronized(@{ Value = $false })
    $ps = $null
    try {
        if (-not $script:workerRunspace -or $script:workerRunspace.RunspaceStateInfo.State -ne 'Opened') {
            if ($script:workerRunspace) { $script:workerRunspace.Dispose(); $script:workerRunspace = $null }
            $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            # 실행 공간은 재사용하되 호출마다 새 스레드다. ReuseThread로 남는 실행 스레드를 만들지 않는다.
            $runspace.ApartmentState = 'MTA'; $runspace.ThreadOptions = 'UseNewThread'
            try { $runspace.Open(); $script:workerRunspace = $runspace } catch { $runspace.Dispose(); throw }
        }
        $runspace = $script:workerRunspace
        $ps = [powershell]::Create(); $ps.Runspace = $runspace
        # 부모 조회도 배경에서 한다. 함수와 작업 본문을 스크립트 하나에 그대로 넣어 지역 범위로 돌린다(실행 공간에 남기지 않는다).
        # 글을 코드로 바꾸는 [scriptblock]::Create는 쓰지 않는다 (AGENTS.md 「코드 규칙」 4번)
        $runner = "param(`$request)`ntry {`nfunction Get-WtTaskHostIds {`n$((Get-Command Get-WtTaskHostIds).Definition)`n}`n" +
            "`$request.HostProcessIds = @(Get-WtTaskHostIds)`n& {`n$($script:worker.ToString())`n} `$request`n} finally { `$Error.Clear() }"
        [void]$ps.AddScript($runner, $true).AddArgument(@{ Action = $Action; Targets = $Targets; SelfProcessId = $PID; Cancel = $cancel })
        $handle = $ps.BeginInvoke()
        $script:job = @{ PowerShell = $ps; Runspace = $runspace; Handle = $handle; Cancel = $cancel; Action = $Action; Started = [datetime]::UtcNow }
        $script:timer.Start()
        Update-WtTaskStatus
    } catch { if ($ps) { $ps.Dispose() }; throw }
}

function Complete-WtTaskJob {
    if (-not $script:job -or -not $script:job.Handle.IsCompleted) { return }
    $job = $script:job; $script:job = $null
    $scanNext = $false
    try {
        $output = @($job.PowerShell.EndInvoke($job.Handle))
        if (-not $output.Count -or $output[-1] -isnot [System.Collections.IDictionary]) { throw ($job.PowerShell.Streams.Error | Select-Object -First 1) }
        $result = $output[-1]
        if ($job.Action -eq 'scan') {
            if (-not $result.Canceled) {
                Set-WtTaskSnapshot @($result.Items)
                $script:lastError = if ($result.FailedWindows) { "창 $($result.FailedWindows)개를 읽지 못했습니다. 해당 프로그램을 확인한 뒤 새로 고침하세요." } else { '' }
                Update-WtTaskList -KeepSelection
            }
        } else {
            $counts = @{}
            foreach ($state in 'closed', 'gone', 'confirmation', 'failed', 'canceled') { $counts[$state] = @($result.Results | Where-Object State -eq $state).Count }
            $script:resultText = '{0:HH:mm:ss} 처리: 닫힘 {1} · 이미 없음 {2} · 확인 필요 {3} · 실패 {4} · 취소 {5}' -f (Get-Date), $counts.closed, $counts.gone, $counts.confirmation, $counts.failed, $counts.canceled
            $script:ui.Result.ToolTip = ($result.Results | ForEach-Object { "$($_.Title): $($_.Message)" }) -join "`n"
            $script:lastError = if ($counts.confirmation -or $counts.failed) { '원래 프로그램에서 저장 확인이나 닫기 결과를 확인하세요. 처리 결과에 마우스를 올리면 항목별 결과가 보입니다.' } else { '' }
            $scanNext = $true
        }
    } catch { $script:lastError = '작업을 완료하지 못했습니다. 다시 시도하세요.'; $script:ui.Status.ToolTip = $_.Exception.Message }
    finally { $job.PowerShell.Dispose() }
    $option = Get-WtTaskRefresh; $script:next = [datetime]::UtcNow.AddMinutes($option.minutes)
    Update-WtTaskStatus
    if ($scanNext) { Start-WtTaskJob 'scan' }
}

function Invoke-WtTaskTick {
    Complete-WtTaskJob
    if (-not $script:ui.Count) { return }
    # 숨겨진 화면에서도 실행 중인 결과는 회수한다. 완료 뒤에는 다음에 보일 때까지 멈춘다.
    if (-not $script:ui.Root.IsVisible -and -not $script:job) { $script:timer.Stop(); return }
    $window = Get-WtWindow
    $visible = $script:ui.Root.IsVisible -and $window -and $window.IsVisible -and $window.WindowState -ne 'Minimized'
    $option = Get-WtTaskRefresh
    if (Test-WtTaskAutoDue $option.mode ([datetime]::UtcNow) $script:next ([bool]$visible) $script:paused ([bool]$script:job)) { Start-WtTaskJob 'scan' }
    if ($script:job -and ([datetime]::UtcNow - $script:job.Started).TotalSeconds -gt 10) { $script:ui.Status.Text = '응답을 기다리는 중입니다. 취소하면 다음 항목부터 중단합니다.' }
}

function Stop-WtTasks {
    if ($script:timer) { $script:timer.Stop(); $script:timer = $null }
    $runspace = $script:workerRunspace; $script:workerRunspace = $null
    if ($script:job) {
        $job = $script:job; $script:job = $null; $job.Cancel.Value = $true
        if ($job.Handle.IsCompleted) { $job.PowerShell.Dispose(); $job.Runspace.Dispose() }
        else { [void]$job.PowerShell.BeginStop($null, $null); $job.Runspace.CloseAsync() }
        $runspace = $null
    }
    if ($runspace) { $runspace.Dispose() }
}

function Update-WtTaskStatus {
    if (-not $script:ui.Count) { return }
    $option = Get-WtTaskRefresh
    $script:ui.Mode.Text = if ($option.mode -eq 'auto') { "자동 · $($option.minutes)분" } else { '수동' }
    $script:ui.Manual.IsChecked = $option.mode -eq 'manual'; $script:ui.Auto.IsChecked = $option.mode -eq 'auto'
    $picked = @($script:items | Where-Object { $_.Selected -and $_.CanClose })
    $script:ui.Close.Content = "선택 닫기 $($picked.Count)"
    $script:ui.Close.IsEnabled = $picked.Count -gt 0 -and -not $script:job
    $script:ui.Refresh.IsEnabled = -not $script:job
    $script:ui.Cancel.IsEnabled = [bool]$script:job
    $script:ui.Status.Text = if ($script:job) { if ($script:job.Cancel.Value) { '취소 요청됨 · 현재 항목의 응답을 기다립니다' } else { '처리 중…' } }
        elseif ($script:lastError) { $script:lastError }
        elseif ($script:lastScan) { '{0}개 선택 · {1}개 표시 · 마지막 수집 {2:HH:mm:ss}' -f $picked.Count, $script:visible.Count, $script:lastScan }
        else { '새로 고침하면 실행 중인 창과 탭을 표시합니다.' }
    $script:ui.Result.Text = $script:resultText
    $script:ui.Result.Visibility = if ($script:resultText) { 'Visible' } else { 'Collapsed' }
    $script:ui.Empty.Text = if ($script:items.Count) { '검색 결과가 없습니다.' } else { '표시할 창이나 탭이 없습니다.' }
    $script:ui.Empty.Visibility = if ($script:visible.Count -or $script:job) { 'Collapsed' } else { 'Visible' }
    foreach ($key in @($script:ui.GroupChecks.Keys)) {
        $check = $script:ui.GroupChecks[$key]
        $groupRows = @($script:visible | Where-Object AppLabel -eq $key)
        $check.IsChecked = Get-WtTaskCheckState $groupRows
        $check.IsEnabled = @($groupRows | Where-Object CanClose).Count -gt 0
    }
}

function Update-WtTaskList([switch]$KeepSelection) {
    if (-not $script:ui.Count) { return }
    if (-not $KeepSelection) { foreach ($row in $script:items) { $row.Selected = $false } }
    $key = ConvertTo-Json -Compress -Depth 4 -InputObject @($script:snapshotVersion, $script:ui.Search.Text, $script:appFilter, $script:sortColumn, $script:sortDirection, @($script:items | Where-Object Selected | ForEach-Object Id))
    if ($script:listKey -ceq $key) { Update-WtTaskStatus; return }
    $scroll = Get-WtVisualChild $script:ui.Grid ([System.Windows.Controls.ScrollViewer])
    $offset = if ($scroll) { $scroll.VerticalOffset } else { 0 }
    $script:visible = @(Find-WtTaskItems $script:items $script:ui.Search.Text $script:appFilter)
    $list = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($row in $script:visible) { $list.Add($row) }
    $view = [System.Windows.Data.ListCollectionView]::new($list)
    $view.GroupDescriptions.Add([System.Windows.Data.PropertyGroupDescription]::new('AppLabel'))
    $view.SortDescriptions.Add([System.ComponentModel.SortDescription]::new('AppLabel', 'Ascending'))
    $view.SortDescriptions.Add([System.ComponentModel.SortDescription]::new($script:sortColumn, $script:sortDirection))
    $script:ui.GroupChecks = @{}
    $script:ui.Grid.ItemsSource = $view
    $script:ui.Grid.UpdateLayout()
    if ($scroll) { $scroll.ScrollToVerticalOffset($offset) }
    Update-WtTaskStatus
    $script:listKey = $key
}

# 표를 다시 만들면 방금 누른 체크박스가 새것으로 바뀐다. 같은 항목 · 같은 그룹의 체크박스로 포커스를 돌려줘
# Space · Tab으로 이어서 고를 수 있게 한다.
function Restore-WtTaskFocus {
    $target = $script:focusTarget; $script:focusTarget = $null
    if (-not $target -or -not $script:ui.Count) { return }
    $check = $null
    if ($target.Group) { $check = $script:ui.GroupChecks[$target.Group] }
    else {
        $item = $script:visible | Where-Object Id -eq $target.Id | Select-Object -First 1
        if ($item) {
            $script:ui.Grid.ScrollIntoView($item)
            $row = Find-WtTaskRow $script:ui.Grid $target.Id
            if ($row) { $check = Get-WtVisualChild $row ([System.Windows.Controls.CheckBox]) }
        }
    }
    if ($check) { [void]$check.Focus() }
}

function Find-WtTaskRow($Root, [string]$Id) {
    if ($Root -is [System.Windows.Controls.DataGridRow]) { if ([string]$Root.Item.Id -eq $Id) { return $Root }; return $null }
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Root); $i++) {
        $found = Find-WtTaskRow ([System.Windows.Media.VisualTreeHelper]::GetChild($Root, $i)) $Id
        if ($found) { return $found }
    }
    $null
}

function Show-WtTaskRefreshDialog {
    if ($script:paused) { return }
    $script:paused = $true
    try {
        $option = Get-WtTaskRefresh
        $dialog = New-WtModal '자동 새로 고침'
        [void](Add-WtChild $dialog.Body (New-WtText '새로 고침 간격'))
        $input = New-WtMinuteInput $option.minutes; [void](Add-WtChild $dialog.Body $input.Root)
        [void](Add-WtChild $dialog.Body (New-WtText '1~1,440분 사이의 정수를 입력하세요.' 'T.Sub'))
        [void](Add-WtChild $dialog.Body (New-WtText '활성 작업 탭을 보는 동안 자동으로 갱신합니다.' 'T.Sub'))
        $apply = New-WtButton '적용' -Kind Primary; $apply.IsDefault = $true
        $cancel = New-WtButton '취소'; $cancel.IsCancel = $true
        $dialog.Window.Tag = @{ Box = $input.Box; Error = $dialog.Error }
        $apply.Tag = $dialog.Window
        $apply.Add_Click({
            param($s, $e)
            $w = $s.Tag
            try { Set-WtTaskRefresh 'auto' $w.Tag.Box.Text; $w.DialogResult = $true }
            catch { $w.Tag.Error.Text = $_.Exception.Message; $w.Tag.Error.Visibility = 'Visible'; [void]$w.Tag.Box.Focus() }
        })
        [void](Add-WtChild $dialog.Buttons $apply); [void](Add-WtChild $dialog.Buttons $cancel)
        $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Box.Focus(); $s.Tag.Box.SelectAll() })
        [void]$dialog.Window.ShowDialog()
    } finally { $script:paused = $false }
}

function Close-WtSelectedTasks {
    if ($script:job -or $script:paused) { return }
    $targets = @($script:items | Where-Object { $_.Selected -and $_.CanClose } | ForEach-Object { $_.PSObject.Copy() })
    if (-not $targets.Count) { return }
    $script:paused = $true
    $accepted = $false
    try {
        $dialog = New-WtModal "선택한 $($targets.Count)개 항목을 닫을까요?"
        $summary = '창 {0}개 · 탭 {1}개' -f @($targets | Where-Object Kind -eq 'window').Count, @($targets | Where-Object Kind -eq 'tab').Count
        [void](Add-WtChild $dialog.Body (New-WtText $summary 'T.Sub'))
        $scroll = [System.Windows.Controls.ScrollViewer]::new(); $scroll.MaxHeight = 320; $scroll.VerticalScrollBarVisibility = 'Auto'
        $list = New-WtStack Vertical 8
        foreach ($target in $targets) {
            [void](Add-WtChild $list (New-WtText $target.DisplayTitle))
            [void](Add-WtChild $list (New-WtText "$($target.AppLabel) · $($target.WindowLabel) · $($target.KindLabel)" 'T.Sub'))
        }
        $scroll.Content = $list; [void](Add-WtChild $dialog.Body $scroll)
        [void](Add-WtChild $dialog.Body (New-WtText '저장 확인은 원래 프로그램에서 처리하세요.' 'T.Sub'))
        $close = New-WtButton '닫기' -Kind Danger; $close.Tag = $dialog.Window
        $close.Add_Click({ param($s, $e) $s.Tag.DialogResult = $true })
        $cancel = New-WtButton '취소'; $cancel.IsCancel = $true; $dialog.Window.Tag = $cancel
        [void](Add-WtChild $dialog.Buttons $close); [void](Add-WtChild $dialog.Buttons $cancel)
        $dialog.Window.Add_ContentRendered({ param($s, $e) [void]$s.Tag.Focus() })
        $accepted = $dialog.Window.ShowDialog() -eq $true
    } finally { $script:paused = $false }
    if ($accepted) { Start-WtTaskJob 'close' $targets }
}

function New-WtActiveTasksView {
    Stop-WtTasks
    $script:listKey = $null
    $script:ui = @{}
    $page = New-WtTaskPage
    $header = New-WtPageHeader '활성 작업' '' $null
    [System.Windows.Controls.DockPanel]::SetDock($header, 'Top'); [void]$page.Panel.Children.Add($header)
    $tools = [System.Windows.Controls.WrapPanel]::new(); $tools.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    $search = New-WtSearchBox '이름으로 찾기'; $search.Root.Width = 280; $search.Root.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    $search.Box.Add_TextChanged({ Update-WtTaskList })
    [void]$tools.Children.Add($search.Root)
    $filter = New-WtButton '모든 프로그램'; $filter.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    $filter.Add_Click({
        param($s, $e)
        $menu = New-WtContextMenu
        $options = @([pscustomobject]@{ AppKey = '*'; AppLabel = '모든 프로그램' }) + @($script:items | Sort-Object AppLabel -Unique)
        foreach ($option in $options) {
            $mi = [System.Windows.Controls.MenuItem]::new(); $mi.Header = $option.AppLabel; $mi.Tag = $option.AppKey
            $mi.IsChecked = $script:appFilter -eq $option.AppKey
            $mi.Add_Click({ param($sender, $event) $script:appFilter = $sender.Tag; $script:ui.Filter.Content = $sender.Header; Update-WtTaskList })
            [void]$menu.Items.Add($mi)
        }
        $s.ContextMenu = $menu; $menu.PlacementTarget = $s; $menu.IsOpen = $true
    })
    [void]$tools.Children.Add($filter)
    $mode = New-WtText '' 'T.Sub'; $mode.VerticalAlignment = 'Center'; $mode.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    [void]$tools.Children.Add($mode)
    $refresh = New-WtButton '새로 고침' -Kind Primary -Icon 0xE72C -ToolTip "새로 고침 (F5)`n우클릭: 수동 / 자동"
    $refresh.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    $refresh.Add_Click({ Start-WtTaskJob 'scan' })
    $menu = New-WtContextMenu
    $manual = [System.Windows.Controls.MenuItem]::new(); $manual.Header = '수동'
    $manual.Add_Click({ try { $option = Get-WtTaskRefresh; Set-WtTaskRefresh 'manual' $option.minutes } catch { Show-WtError $_ '새로 고침 설정' } })
    $auto = [System.Windows.Controls.MenuItem]::new(); $auto.Header = '자동…'; $auto.Add_Click({ Show-WtTaskRefreshDialog })
    [void]$menu.Items.Add($manual); [void]$menu.Items.Add($auto); $refresh.ContextMenu = $menu
    $menu.Add_Opened({ Update-WtTaskStatus })
    [System.Windows.Controls.ContextMenuService]::SetShowOnDisabled($refresh, $true)
    [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($refresh, $true)
    [void]$tools.Children.Add($refresh)
    $close = New-WtButton '선택 닫기' -Kind Danger; $close.Margin = [System.Windows.Thickness]::new(0, 0, 12, 8)
    $close.Add_Click({ Close-WtSelectedTasks }); [void]$tools.Children.Add($close)
    $cancel = New-WtButton '취소'; $cancel.Margin = [System.Windows.Thickness]::new(0, 0, 0, 8)
    $cancel.Add_Click({ if ($script:job) { $script:job.Cancel.Value = $true; Update-WtTaskStatus } }); [void]$tools.Children.Add($cancel)
    [System.Windows.Controls.DockPanel]::SetDock($tools, 'Top'); [void]$page.Panel.Children.Add($tools)
    $bottom = New-WtStack Vertical 4; $bottom.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
    $status = New-WtText '' 'T.Sub'; $result = New-WtText '' 'T.Sub'
    [void](Add-WtChild $bottom $status); [void](Add-WtChild $bottom $result)
    [System.Windows.Controls.DockPanel]::SetDock($bottom, 'Bottom'); [void]$page.Panel.Children.Add($bottom)
    $area = [System.Windows.Controls.Grid]::new()
    $grid = New-WtTaskGrid; [void]$area.Children.Add($grid)
    $empty = New-WtText '' 'T.Sub'; $empty.HorizontalAlignment = 'Center'; $empty.VerticalAlignment = 'Center'; $empty.IsHitTestVisible = $false
    [void]$area.Children.Add($empty); [void]$page.Panel.Children.Add($area)
    $script:ui = @{ Root = $page.Root; Grid = $grid; Empty = $empty; Search = $search.Box; Filter = $filter; Mode = $mode; Refresh = $refresh; Manual = $manual; Auto = $auto; Close = $close; Cancel = $cancel; Status = $status; Result = $result; GroupChecks = @{} }
    $grid.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $check = $e.OriginalSource
        if ($check -isnot [System.Windows.Controls.CheckBox]) { return }
        if ($check.Tag -eq 'group') {
            foreach ($row in @($check.DataContext.Items)) { if ($row.CanClose) { $row.Selected = $check.IsChecked -eq $true } }
            $script:focusTarget = @{ Group = [string]$check.DataContext.Name }
        } elseif ($check.Tag -eq 'task') {
            $check.DataContext.Selected = $check.IsChecked -eq $true
            $script:focusTarget = @{ Id = [string]$check.DataContext.Id }
        }
        else { return }
        Update-WtTaskList -KeepSelection
        # 그룹 체크박스는 그룹 머리글이 다시 만들어진 뒤(Loaded) 등록되므로 그보다 늦은 순서로 돌려준다
        [void]$s.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ Restore-WtTaskFocus })
    })
    # Loaded는 자식에서 버블링하지 않으므로 GroupItem 스타일에서 직접 받는다.
    $groupStyle = [System.Windows.Style]::new([System.Windows.Controls.GroupItem], $grid.GroupStyle[0].ContainerStyle)
    $groupStyle.Setters.Add([System.Windows.EventSetter]::new([System.Windows.FrameworkElement]::LoadedEvent, [System.Windows.RoutedEventHandler]{
        param($s, $e)
        $check = Get-WtVisualChild $s ([System.Windows.Controls.CheckBox])
        if ($check -and $check.Tag -eq 'group') {
            $script:ui.GroupChecks[$check.DataContext.Name] = $check; Update-WtTaskStatus
        }
        $element = Get-WtVisualChild $s ([System.Windows.Controls.Expander])
        if ($element -and $element.Tag -eq 'task-group') {
            if ($script:expanded.ContainsKey($element.DataContext.Name)) { $element.IsExpanded = $script:expanded[$element.DataContext.Name] }
        }
    }))
    $grid.GroupStyle[0].ContainerStyle = $groupStyle
    $groupHandler = [System.Windows.RoutedEventHandler]{ param($s, $e) if ($e.OriginalSource -is [System.Windows.Controls.Expander] -and $e.OriginalSource.IsLoaded) { $script:expanded[$e.OriginalSource.DataContext.Name] = $e.OriginalSource.IsExpanded } }
    $grid.AddHandler([System.Windows.Controls.Expander]::ExpandedEvent, $groupHandler)
    $grid.AddHandler([System.Windows.Controls.Expander]::CollapsedEvent, $groupHandler)
    $grid.Add_Sorting({
        param($s, $e)
        $e.Handled = $true
        if ($script:sortColumn -eq $e.Column.SortMemberPath) { $script:sortDirection = if ($script:sortDirection -eq 'Ascending') { 'Descending' } else { 'Ascending' } }
        else { $script:sortColumn = $e.Column.SortMemberPath; $script:sortDirection = 'Ascending' }
        foreach ($column in $s.Columns) { $column.SortDirection = $null }
        $e.Column.SortDirection = $script:sortDirection
        Update-WtTaskList -KeepSelection
    })
    $page.Root.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'F5') { Start-WtTaskJob 'scan'; $e.Handled = $true }
        if ($e.Key -eq 'F' -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) { [void]$script:ui.Search.Focus(); $e.Handled = $true }
    })
    $script:timer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:timer.Interval = [timespan]::FromMilliseconds(250); $script:timer.Add_Tick({ Invoke-WtTaskTick })
    $page.Root.Add_Loaded({ if ($script:timer) { $script:timer.Start() } })
    $page.Root.Add_Unloaded({ if ($script:timer -and -not $script:job) { $script:timer.Stop() } })
    $page.Root.Add_IsVisibleChanged({
        param($s, $e)
        if (-not $script:timer) { return }
        if ($s.IsVisible -or $script:job) { $script:timer.Start() } else { $script:timer.Stop() }
    })
    Update-WtTaskList -KeepSelection
    $page.Root
}

Register-WtAddon -Id 'active-tasks' -Title '활성 작업' -Icon 0xE7C4 -Order 60 -WarmUp View `
    -NewView { New-WtActiveTasksView } -Refresh { param($view) Start-WtTaskJob 'scan' } -OnExit { Stop-WtTasks } `
    -Help @(
        '활성 작업은 열린 창과 Chrome·Edge·웨일 탭을 모아 보고 선택한 항목을 닫습니다. 새로 고침 버튼을 우클릭하면 수동·자동을 고를 수 있고, 자동은 분 단위 간격을 설정합니다.'
        '자동 갱신은 활성 작업 탭을 보는 동안만 동작합니다. 읽기 제한 항목은 원래 프로그램에서 확인하세요. 닫을 때 저장 확인도 원래 프로그램에서 처리합니다.') `
    -Shortcuts @(@('F5', '새로 고침'), @('Ctrl + F', '이름으로 거르기'), @('Shift + F10', '새로 고침 버튼의 수동/자동 메뉴'))

Export-ModuleMember -Function ConvertTo-WtTaskMinutes, Get-WtTaskRefresh, Set-WtTaskRefresh, Test-WtTaskAutoDue,
    Find-WtTaskItems, Get-WtTaskCheckState, Get-WtTaskWorker, Get-WtTaskHostIds
} | Import-Module -Force -DisableNameChecking
# ---- addons\active-tasks\ActiveTasks.psm1 끝 ----

# ---- addons\attendance\Attendance.psm1 ----
New-Module -Name 'WorkTool.addon.attendance' -ScriptBlock {
# 근태 탭 (1단계: 보기 전용). 기록 · 지금 출근은 2단계에서 옮긴다.
# 저장소 attendance.json (schema 1). 항목:
#   id, type(출근 | 업무외시간 근무 | 출장 | 휴가), startDate, endDate, startTime, endTime, place, detail, updated

$ErrorActionPreference = 'Stop'

$script:schema = 1
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
$script:body = $null
$script:monthLabel = $null

# 종류 → 표시 색 (Theme.psm1의 Att.*)
$script:typeColor = @{ '출근' = 'Att.Work'; '업무외시간 근무' = 'Att.Over'; '출장' = 'Att.Trip'; '휴가' = 'Att.Leave' }

function ConvertTo-AttDate([string]$Text) { [datetime]::ParseExact($Text, 'yyyy-MM-dd', $script:inv) }

function Get-WtAttendanceItems { Get-WtStoreItems -Name 'attendance' -Schema $script:schema }

# 기록이 그 달과 겹치는지
function Test-WtAttInMonth($Item, [datetime]$Month) {
    $first = $Month.Date
    $last = $first.AddMonths(1).AddDays(-1)
    $s = ConvertTo-AttDate $Item.startDate
    $e = if ($Item.endDate) { ConvertTo-AttDate $Item.endDate } else { $s }
    $s -le $last -and $e -ge $first
}

# 업무외시간 근무 분. 끝 시각이 시작보다 이르면 다음 날로 본다.
function Get-WtAttMinutes($Item) {
    if (-not $Item.startTime -or -not $Item.endTime) { return 0 }
    $a = [timespan]::ParseExact($Item.startTime, 'hh\:mm', $script:inv)
    $b = [timespan]::ParseExact($Item.endTime, 'hh\:mm', $script:inv)
    $m = ($b - $a).TotalMinutes
    if ($m -le 0) { $m += 1440 }
    [int]$m
}

# 그 달 요약: 출근 일수, 업무외 시간, 출장 건수, 휴가 일수(반차 0.5)
function Get-WtAttendanceSummary([datetime]$Month, [object[]]$Items) {
    if ($null -eq $Items) { $Items = Get-WtAttendanceItems }
    $first = $Month.Date
    $last = $first.AddMonths(1).AddDays(-1)
    $inMonth = @($Items | Where-Object { Test-WtAttInMonth $_ $first })
    $work = @($inMonth | Where-Object { $_.type -eq '출근' } | ForEach-Object { $_.startDate } | Sort-Object -Unique).Count
    $over = ($inMonth | Where-Object { $_.type -eq '업무외시간 근무' } | ForEach-Object { Get-WtAttMinutes $_ } | Measure-Object -Sum).Sum
    $trip = @($inMonth | Where-Object { $_.type -eq '출장' }).Count
    $leave = 0.0
    foreach ($r in ($inMonth | Where-Object { $_.type -eq '휴가' })) {
        if ($r.detail -like '*반차*') { $leave += 0.5; continue }
        $s = ConvertTo-AttDate $r.startDate
        $e = if ($r.endDate) { ConvertTo-AttDate $r.endDate } else { $s }
        if ($s -lt $first) { $s = $first }
        if ($e -gt $last) { $e = $last }
        $leave += ($e - $s).Days + 1
    }
    [pscustomobject]@{ Work = $work; OverMinutes = [int]$over; Trip = $trip; Leave = $leave }
}

function Format-WtHours([int]$Minutes) {
    $h = [Math]::Round($Minutes / 60, 1)
    if ($h -eq [Math]::Floor($h)) { '{0:0}' -f $h } else { '{0:0.0}' -f $h }
}

# 예전 attendance.csv → attendance.json. 가져온 개수를 돌려준다.
function Import-WtAttendanceLegacy([string]$Folder) {
    $rows = Import-WtLegacyCsv $Folder 'attendance'
    if ($null -eq $rows) { return $null }
    $items = foreach ($r in $rows) {
        [ordered]@{
            id        = [string]$r.Id
            type      = [string]$r.Type
            startDate = [string]$r.StartDate
            endDate   = if ($r.EndDate) { [string]$r.EndDate } else { [string]$r.StartDate }
            startTime = [string]$r.StartTime
            endTime   = [string]$r.EndTime
            place     = [string]$r.Place
            detail    = [string]$r.Detail
            updated   = [string]$r.Updated
        }
    }
    Write-WtStore -Name 'attendance' -Schema $script:schema -Items @($items) -Extra @{ importedFrom = $Folder }
    @($items).Count
}

function New-WtAttTiles($Summary, [int]$Columns) {
    $g = [System.Windows.Controls.Primitives.UniformGrid]::new()
    $g.Columns = $Columns
    foreach ($t in @(
            @('출근', "$($Summary.Work)", '일', 'Att.Work'),
            @('업무외시간', (Format-WtHours $Summary.OverMinutes), '시간', 'Att.Over'),
            @('출장', "$($Summary.Trip)", '건', 'Att.Trip'),
            @('휴가', ('{0:0.#}' -f $Summary.Leave), '일', 'Att.Leave'))) {
        $tile = New-WtStatTile $t[0] $t[1] $t[2] $t[3]
        $tile.Margin = [System.Windows.Thickness]::new(0, 0, 10, 10)
        [void]$g.Children.Add($tile)
    }
    $g
}

function New-WtAttRow($Item) {
    $s = ConvertTo-AttDate $Item.startDate
    $e = if ($Item.endDate) { ConvertTo-AttDate $Item.endDate } else { $s }
    $dateText = if ($e -gt $s) { '{0} ~ {1}' -f (Format-WtDate $s "M'/'d"), (Format-WtDate $e "M'/'d") } else { Format-WtDate $s "M'/'d (ddd)" }
    $date = New-WtText $dateText 'T.Body'
    $date.Width = 110
    $color = $script:typeColor[[string]$Item.type]
    if (-not $color) { $color = 'Chip' }
    $tagBox = [System.Windows.Controls.Border]::new()
    $tagBox.Width = 130
    $tagBox.Child = New-WtTag $Item.type "${color}Bg" $color
    if (-not $script:typeColor[[string]$Item.type]) { $tagBox.Child = New-WtTag $Item.type }
    $time = switch ([string]$Item.type) {
        '출근' { $Item.startTime }
        '업무외시간 근무' { '{0}–{1} ({2}시간)' -f $Item.startTime, $Item.endTime, (Format-WtHours (Get-WtAttMinutes $Item)) }
        '휴가' { if ($Item.detail) { $Item.detail } else { '휴가' } }
        default { if ($e -gt $s) { '{0}일' -f (($e - $s).Days + 1) } else { '하루' } }
    }
    $timeText = New-WtText ([string]$time) 'T.Body'
    $timeText.Width = 170
    $noteParts = @($Item.place, $(if ($Item.type -ne '휴가') { $Item.detail })) | Where-Object { $_ }
    $note = New-WtText ($noteParts -join ' · ') 'T.Sub'
    New-WtListRow @($date, $tagBox, $timeText, $note)
}

function New-WtAttendanceView {
    $script:viewKey = $null
    $page = New-WtPage
    $nav = New-WtStack Horizontal 6
    $prev = New-WtButton '' -Icon 0xE76B -ToolTip '이전 달'
    $prev.Tag = -1
    $next = New-WtButton '' -Icon 0xE76C -ToolTip '다음 달'
    $next.Tag = 1
    $thisMonth = New-WtButton '이번 달'
    $thisMonth.Tag = 0
    foreach ($b in $prev, $next, $thisMonth) {
        $b.Add_Click({
                param($s, $e)
                $step = [int]$s.Tag
                $script:month = if ($step -eq 0) { [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1) } else { $script:month.AddMonths($step) }
                Update-WtAttendanceView
            })
    }
    $script:monthLabel = New-WtText '' 'T.H2'
    $script:monthLabel.VerticalAlignment = 'Center'
    $script:monthLabel.Margin = [System.Windows.Thickness]::new(6, 0, 6, 0)
    [void](Add-WtChild $nav $prev)
    [void](Add-WtChild $nav $script:monthLabel)
    [void](Add-WtChild $nav $next)
    [void](Add-WtChild $nav $thisMonth)
    [void](Add-WtChild $page.Panel (New-WtPageHeader '근태' '보기 전용 · 기록과 「지금 출근」은 2단계에서 옮깁니다' $nav))
    $script:body = New-WtStack Vertical 16
    [void](Add-WtChild $page.Panel $script:body)
    $page.Root
}

function Update-WtAttendanceView {
    $key = @((Get-WtStoreStamp 'attendance'), $script:month.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:viewKey -ceq $key) { return }
    $items = Get-WtAttendanceItems
    $script:monthLabel.Text = Format-WtDate $script:month 'yyyy년 M월'
    $script:body.Children.Clear()
    [void](Add-WtChild $script:body (New-WtAttTiles (Get-WtAttendanceSummary $script:month $items) 4))
    $card = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader ('{0} 기록' -f (Format-WtDate $script:month 'M월'))))
    $rows = @($items | Where-Object { Test-WtAttInMonth $_ $script:month } |
        Sort-Object -Property @{ Expression = { $_.startDate }; Descending = $true }, @{ Expression = { $_.startTime }; Descending = $true })
    foreach ($r in $rows) { [void](Add-WtChild $col (New-WtAttRow $r)) }
    if (-not $rows.Count) { [void](Add-WtChild $col (New-WtText '이 달에는 기록이 없습니다.' 'T.Sub')) }
    $card.Child = $col
    [void](Add-WtChild $script:body $card)
    $script:viewKey = $key
}

function New-WtAttendanceHomeCard {
    $key = @((Get-WtStoreStamp 'attendance'), [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:homeKey -ceq $key -and $script:homeCard -and -not $script:homeCard.Parent) { return $script:homeCard }
    $items = Get-WtAttendanceItems
    $month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)
    $card = New-WtCard
    $col = New-WtStack Vertical 8
    [void](Add-WtChild $col (New-WtCardHeader ('근태 · {0}' -f (Format-WtDate $month 'M월')) '' '근태 열기' 'attendance'))
    $today = [datetime]::Today.ToString('yyyy-MM-dd', $script:inv)
    $in = $items | Where-Object { $_.type -eq '출근' -and $_.startDate -eq $today } | Select-Object -First 1
    $status = if ($in) { New-WtTag "오늘 출근 $($in.startTime)" 'SuccessBg' 'Success' } else { New-WtTag '아직 출근 기록 없음' 'WarnBg' 'Warn' }
    [void](Add-WtChild $col $status)
    [void](Add-WtChild $col (New-WtAttTiles (Get-WtAttendanceSummary $month $items) 2))
    $card.Child = $col
    $script:homeCard = $card; $script:homeKey = $key
    $card
}

Register-WtAddon -Id 'attendance' -Title '근태' -Icon 0xE823 -Order 30 -WarmUp Full `
    -NewView { New-WtAttendanceView } `
    -Refresh { param($view) Update-WtAttendanceView } `
    -HomeCard { New-WtAttendanceHomeCard } `
    -ImportLegacy { param($folder) Import-WtAttendanceLegacy $folder } `
    -Help '근태는 보기만 합니다. 기록 · 지금 출근은 2단계에서 옮깁니다.'

Export-ModuleMember -Function Get-WtAttendanceItems, Test-WtAttInMonth, Get-WtAttMinutes, Get-WtAttendanceSummary,
    Format-WtHours, Import-WtAttendanceLegacy
} | Import-Module -Force -DisableNameChecking
# ---- addons\attendance\Attendance.psm1 끝 ----

# ---- addons\docs\Docs.psm1 ----
New-Module -Name 'WorkTool.addon.docs' -ScriptBlock {
# 문서 탭: 고른 폴더를 트리로 보고, 파일은 원래 프로그램(Excel · Word · PDF …)으로 연다.
# 보안 문서 · 계정 엑셀처럼 툴에 옮기면 안 되는 파일도 여기서 원본을 바로 연다. 파일 내용은 읽거나 저장하지 않는다.
# 설정(데이터 폴더의 settings.json, 저장소에 올라가지 않음):
#   docs.roots  트리 맨 위 폴더들 · docs.pins  즐겨찾기(파일 · 폴더 경로) · docs.last  마지막으로 본 폴더
# 단축키(문서 화면 안): Enter 열기 · Alt+↑ 위 폴더 · F5 새로 고침 · Ctrl+F 이름으로 거르기

$ErrorActionPreference = 'Stop'

$script:ui = @{}
$script:current = $null      # 오른쪽에 보이는 폴더 경로. '*' = 즐겨찾기
$script:entries = @()
$script:selecting = $false   # 코드로 트리를 고르는 중
$script:jobs = [System.Collections.Generic.List[object]]::new()
$script:pending = [ordered]@{}
$script:pollTimer = $null
$script:filterTimer = $null
$script:stopping = $false
$script:treeGeneration = 0
$script:treeTarget = $null       # 트리에서 찾아가는 중인 경로. 하위 폴더를 다 읽으면 이어서 찾는다
$script:treeWaitNode = $null     # 그 경로로 가려고 하위 폴더를 읽는 중인 항목
$script:folderFallback = $null   # 마지막으로 본 폴더를 못 열면 대신 열 폴더 @{ From; To }
$script:treeBatches = [System.Collections.Generic.List[object]]::new()
$script:treeBatchScheduled = $false

Register-WtSettingDefault 'docs.roots' @()
Register-WtSettingDefault 'docs.pins' @()
Register-WtSettingDefault 'docs.last' ''

# 확장자 → 종류 이름 · 아이콘
$script:kinds = @{
    '.xlsx' = 'Excel'; '.xlsm' = 'Excel'; '.xls' = 'Excel'; '.xlsb' = 'Excel'; '.csv' = 'CSV'
    '.docx' = 'Word'; '.doc' = 'Word'; '.rtf' = 'Word'
    '.pptx' = 'PowerPoint'; '.ppt' = 'PowerPoint'
    '.pdf' = 'PDF'; '.hwp' = '한글'; '.hwpx' = '한글'; '.vsdx' = 'Visio'; '.vsd' = 'Visio'
    '.txt' = '텍스트'; '.md' = '마크다운'; '.log' = '로그'; '.json' = 'JSON'; '.xml' = 'XML'; '.yaml' = 'YAML'; '.yml' = 'YAML'; '.ini' = '설정'; '.conf' = '설정'; '.cfg' = '설정'
    '.png' = '그림'; '.jpg' = '그림'; '.jpeg' = '그림'; '.gif' = '그림'; '.bmp' = '그림'; '.svg' = '그림'; '.webp' = '그림'
    '.zip' = '압축'; '.7z' = '압축'; '.rar' = '압축'; '.tar' = '압축'; '.gz' = '압축'
    '.msg' = '메일'; '.eml' = '메일'; '.lnk' = '바로가기'; '.url' = '바로가기'
    '.ps1' = 'PowerShell'; '.psm1' = 'PowerShell'; '.bat' = '배치'; '.cmd' = '배치'; '.exe' = '프로그램'; '.msi' = '설치'
}
$script:kindIcons = @{
    '폴더' = 0xE8B7; 'Excel' = 0xE80A; 'CSV' = 0xE80A; 'PowerPoint' = 0xE786; '그림' = 0xE91B; '압축' = 0xE7B8
    '메일' = 0xE715; 'PowerShell' = 0xE943; '배치' = 0xE943; '프로그램' = 0xE7AC; '설치' = 0xE7AC; '없음' = 0xE7BA
}
# 열기 전에 한 번 묻는 실행 파일
$script:runnable = @('.exe', '.msi', '.bat', '.cmd', '.ps1', '.psm1', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.hta', '.scr', '.com', '.reg', '.cpl')

# ---- 파일 목록 (WPF 없이) ---------------------------------------------------------------------

function Get-WtDocKind([string]$Name, [bool]$IsDir) {
    if ($IsDir) { return '폴더' }
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    if ($script:kinds.ContainsKey($ext)) { return $script:kinds[$ext] }
    if ($ext) { return $ext.TrimStart('.').ToUpperInvariant() }
    '파일'
}

function Get-WtDocIcon([string]$Kind) { if ($script:kindIcons.ContainsKey($Kind)) { $script:kindIcons[$Kind] } else { 0xE8A5 } }

# Explorer처럼: 1 KB 단위 올림, 1024 KB부터 MB, 1024 MB부터 GB
function Format-WtDocSize($Bytes) {
    if ($null -eq $Bytes) { return '' }
    $b = [double]$Bytes
    if ($b -lt 1024 * 1024) { return '{0:N0} KB' -f [Math]::Ceiling($b / 1024) }
    if ($b -lt 1024 * 1024 * 1024) { return '{0:N1} MB' -f ($b / 1MB) }
    '{0:N1} GB' -f ($b / 1GB)
}

function New-WtDocEntry([System.IO.FileSystemInfo]$Info) {
    $isDir = $Info -is [System.IO.DirectoryInfo]
    $kind = Get-WtDocKind $Info.Name $isDir
    [pscustomobject]@{
        Name = $Info.Name; Path = $Info.FullName; IsDir = $isDir; Kind = $kind
        Size = $(if ($isDir) { $null } else { $Info.Length }); Modified = $Info.LastWriteTime; Missing = $false
        SizeText = $(if ($isDir) { '' } else { Format-WtDocSize $Info.Length })
        ModifiedText = $Info.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); IconText = [string][char](Get-WtDocIcon $kind)
    }
}

# 폴더 안 항목: 숨김 · 시스템은 빼고, 폴더 먼저 · 이름 순. 열 수 없으면 예외
function Get-WtDocEntries([string]$Path, $Cancel = $null) {
    $dir = [System.IO.DirectoryInfo]::new($Path)
    $hidden = [System.IO.FileAttributes]'Hidden, System'
    $list = foreach ($fsi in $dir.EnumerateFileSystemInfos()) {
        if ($Cancel -and $Cancel.Value) { return @() }
        if ($fsi.Attributes -band $hidden) { continue }
        New-WtDocEntry $fsi
    }
    @($list | Sort-Object -Property @{ Expression = { -not $_.IsDir } }, @{ Expression = { $_.Name }; Descending = $false } -Culture 'ko-KR')
}

# 하위 폴더 경로들 (트리 펼치기용). 열 수 없으면 빈 목록
function Get-WtDocSubfolders([string]$Path, [switch]$Strict) {
    try {
        $hidden = [System.IO.FileAttributes]'Hidden, System'
        @([System.IO.DirectoryInfo]::new($Path).EnumerateDirectories() | Where-Object { -not ($_.Attributes -band $hidden) } |
                Sort-Object Name -Culture 'ko-KR' | ForEach-Object { $_.FullName })
    } catch { if ($Strict) { throw }; @() }
}

# 즐겨찾기 항목. 없어진 경로도 보여 줘서 뺄 수 있게 한다
function Get-WtDocPinEntries([string[]]$Paths = @(Get-WtSetting 'docs.pins'), $Cancel = $null) {
    foreach ($p in $Paths) {
        if ($Cancel -and $Cancel.Value) { return }
        $p = [string]$p
        if (-not $p) { continue }
        if (Test-Path -LiteralPath $p) { New-WtDocEntry (Get-Item -LiteralPath $p -Force) }
        else { [pscustomobject]@{ Name = (Split-Path $p -Leaf); Path = $p; IsDir = $false; Kind = '없음'; Size = $null; Modified = $null; Missing = $true; SizeText = ''; ModifiedText = ''; IconText = [string][char]0xE7BA } }
    }
}

function Test-WtDocPinned([string]$Path) { @(Get-WtSetting 'docs.pins') -contains $Path }

# 즐겨찾기에 넣거나 뺀다. 넣었으면 $true
function Switch-WtDocPin([string]$Path) {
    $pins = @(@(Get-WtSetting 'docs.pins') | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($pins -contains $Path) { Set-WtSetting 'docs.pins' @($pins | Where-Object { $_ -ne $Path }); return $false }
    Set-WtSetting 'docs.pins' @($pins + $Path)
    $true
}

function Get-WtDocRoots { @(@(Get-WtSetting 'docs.roots') | ForEach-Object { [string]$_ } | Where-Object { $_ }) }

# 경로가 들어 있는 맨 위 폴더부터 그 경로까지 차례로 (트리를 펼쳐 찾아가기용). 맨 위 폴더 밖이면 빈 목록
function Get-WtDocChain([string[]]$Roots, [string]$Path) {
    $norm = { param($p) $p.TrimEnd('\', '/') }
    $target = & $norm $Path
    foreach ($r in $Roots) {
        $root = & $norm $r
        if ($target -ieq $root -or $target.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase)) {
            $chain = [System.Collections.Generic.List[string]]::new()
            $chain.Add($r)
            $cur = $root
            foreach ($part in ($target.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
                $cur = "$cur\$part"
                $chain.Add($cur)
            }
            return $chain.ToArray()
        }
    }
}

# 경로 표시: 맨 위 폴더 이름부터 › 로 잇는다 (예: 업무 문서 › 운영 › 점검 기록). 맨 위 폴더 밖이면 전체 경로
function Format-WtDocPathLabel([string[]]$Roots, [string]$Path) {
    $chain = @(Get-WtDocChain $Roots $Path)
    if (-not $chain.Count) { return $Path }
    $first = Split-Path $chain[0].TrimEnd('\') -Leaf
    if (-not $first) { $first = $chain[0] }
    (@($first) + @($chain | Select-Object -Skip 1 | ForEach-Object { Split-Path $_ -Leaf })) -join ' › '
}

# 이름에 낱말이 모두 들어 있는 항목 (띄어 쓰면 AND)
function Find-WtDocEntry([object[]]$Entries, [string]$Query) {
    $words = @($Query -split '\s+' | Where-Object { $_ })
    if (-not $words.Count) { return $Entries }
    $Entries | Where-Object { $n = $_.Name; -not ($words | Where-Object { $n -notlike "*$_*" }) }
}

# ---- 열기 ------------------------------------------------------------------------------------

function Open-WtDocEntry($Entry) {
    if (-not $Entry) { return }
    if ($Entry.Missing) { Show-WtMessage "찾을 수 없습니다. 옮기거나 지웠으면 즐겨찾기에서 빼세요.`n$($Entry.Path)"; return }
    if ($Entry.IsDir) { Show-WtDocFolder $Entry.Path -SelectTree; return }
    $ext = [System.IO.Path]::GetExtension($Entry.Path).ToLowerInvariant()
    if ($script:runnable -contains $ext) {
        if (-not (Confirm-WtYesNo "'$($Entry.Name)'은(는) 실행되는 파일입니다. 실행할까요?")) { return }
    }
    try { Invoke-Item -LiteralPath $Entry.Path } catch { Show-WtError $_ '파일 열기' }
}

function Show-WtDocInExplorer([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { Show-WtMessage "찾을 수 없습니다.`n$Path"; return }
    Start-Process explorer.exe -ArgumentList "/select,`"$Path`""
}

function Copy-WtDocPath([string]$Path) {
    try { [System.Windows.Clipboard]::SetText($Path) } catch { Show-WtMessage '클립보드를 다른 프로그램이 쓰고 있어서 복사하지 못했습니다. 다시 누르세요.' 'WorkTool' 'Warning'; return }
    Set-WtDocStatus "경로를 복사했습니다: $Path"
}

# ---- 화면 -------------------------------------------------------------------------------------

# 조회 하나를 실행하는 코드. 취소는 다음 파일부터 적용되며, 진행 중인 OS 호출은 끝날 때까지 기다릴 수 있다.
$script:worker = {
    param($request, $kinds, $icons)
    $ErrorActionPreference = 'Stop'
    $script:kinds = $kinds; $script:kindIcons = $icons
    try {
        $items = switch ($request.Action) {
            'folder' { @(Get-WtDocEntries $request.Path $request.Cancel) }
            'tree' { @(Get-WtDocSubfolders $request.Path -Strict) }
            'pins' { @(Get-WtDocPinEntries -Paths $request.Pins -Cancel $request.Cancel) }
        }
        @{ Items = @($items); Error = $null }
    } catch { @{ Items = @(); Error = $_.Exception.InnerException.Message ?? $_.Exception.Message } }
}

function Start-WtDocRequest([string]$Key, [string]$Action, [string]$Path = '', $Context = $null) {
    $script:stopping = $false
    foreach ($job in $script:jobs) { if ($job.Key -eq $Key) { $job.Request.Cancel.Value = $true } }
    if ($Key -notin 'folder', 'home' -and -not $script:pending.Contains($Key) -and $script:pending.Count -ge 32) { return $false }
    $request = @{ Action = $Action; Path = $Path; Pins = @(Get-WtSetting 'docs.pins'); Cancel = [hashtable]::Synchronized(@{ Value = $false }) }
    if ($Key -eq 'home') { $request.Pins = @($request.Pins | Select-Object -First 6) }
    $script:pending[$Key] = @{ Key = $Key; Request = $request; Context = $Context; Generation = $script:treeGeneration }
    if (-not $script:pollTimer) { $script:pollTimer = New-WtPollTimer { Complete-WtDocJobs } }
    $script:pollTimer.Start()
    Start-WtDocJobs
    $true
}

# 응답 없는 공유 폴더를 기다리느라 다른 조회가 막히지 않게, 취소했거나 새 요청으로 바뀐 조회는 자리를 차지하지 않는다.
# 폴더 · 홈 즐겨찾기는 하나씩, 트리는 둘까지 실행한다. 취소한 것까지 합쳐 8개가 돌고 있으면 끝나기를 기다린다.
function Test-WtDocJobSlot([string]$Key) {
    if ($script:jobs.Count -ge 8) { return $false }
    $active = @($script:jobs | Where-Object { -not $_.Request.Cancel.Value })
    if ($Key -in 'folder', 'home') { return -not @($active | Where-Object Key -eq $Key).Count }
    @($active | Where-Object { $_.Key -notin 'folder', 'home' }).Count -lt 2
}

function Start-WtDocJobs {
    if ($script:stopping) { return }
    $keys = @(@('folder', 'home') | Where-Object { $script:pending.Contains($_) }) + @($script:pending.Keys | Where-Object { $_ -notin 'folder', 'home' })
    foreach ($key in $keys) {
        if (-not $script:pending.Contains($key) -or -not (Test-WtDocJobSlot $key)) { continue }
        $job = $script:pending[$key]; $script:pending.Remove($key)
        $state = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($name in 'Get-WtDocKind', 'Get-WtDocIcon', 'Format-WtDocSize', 'New-WtDocEntry', 'Get-WtDocEntries', 'Get-WtDocSubfolders', 'Get-WtDocPinEntries') {
            $state.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($name, (Get-Command $name).Definition))
        }
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($state)
        # 작업마다 새 스레드. ReuseThread는 실행 공간을 버리기 전까지 스레드가 남아, 끝낼 때 응답 없는 조회가 있으면 앱 프로세스가 끝나지 않는다
        $runspace.ApartmentState = 'MTA'; $runspace.ThreadOptions = 'UseNewThread'
        $ps = [powershell]::Create()
        try {
            $runspace.Open(); $ps.Runspace = $runspace
            [void]$ps.AddScript($script:worker.ToString()).AddArgument($job.Request).AddArgument($script:kinds).AddArgument($script:kindIcons)
            $job.PowerShell = $ps; $job.Runspace = $runspace; $job.Handle = $ps.BeginInvoke()
            $script:jobs.Add($job)
        } catch {
            $ps.Dispose(); $runspace.Dispose()
            Set-WtDocResult $job @{ Items = @(); Error = $_.Exception.Message }
        }
    }
}

function Complete-WtDocJobs {
    foreach ($job in @($script:jobs.ToArray())) {
        if (-not $job.Handle.IsCompleted) { continue }
        try {
            $output = @($job.PowerShell.EndInvoke($job.Handle))
            $result = if ($output.Count) { $output[-1] } else { @{ Items = @(); Error = '조회가 취소되었거나 완료되지 않았습니다.' } }
        } catch { $result = @{ Items = @(); Error = $_.Exception.Message } }
        finally { $job.PowerShell.Dispose(); $job.Runspace.Dispose(); [void]$script:jobs.Remove($job) }
        if (-not $script:stopping -and -not $job.Request.Cancel.Value) { Set-WtDocResult $job $result }
    }
    Start-WtDocJobs
    if (-not $script:jobs.Count -and -not $script:pending.Count -and $script:pollTimer) { $script:pollTimer.Stop() }
}

function Set-WtDocResult($Job, $Result) {
    switch ($Job.Key) {
        'folder' {
            if (-not $script:ui.Count -or $Job.Request.Path -ne $script:current) { return }
            $fallback = $script:folderFallback; $script:folderFallback = $null
            if ($Result.Error -and $fallback -and $fallback.From -eq $Job.Request.Path) {
                # 마지막으로 본 폴더가 없어졌거나 연결되지 않으면 첫 폴더를 연다 (화면을 멈추는 존재 확인 없이)
                Show-WtDocFolder $fallback.To -SelectTree
                return
            }
            $script:entries = @($Result.Items)
            $script:ui.Loading = $false
            $script:ui.Error = if ($Result.Error) { "폴더를 열지 못했습니다. $($Result.Error)" } else { $null }
            if (-not $Result.Error -and $script:current -ne '*') {
                try { Set-WtSetting 'docs.last' $script:current } catch { $script:ui.Error = '마지막 위치를 저장하지 못했습니다. 폴더 쓰기 권한을 확인하세요.' }
            }
            Update-WtDocList
        }
        'home' {
            $col = $Job.Context
            $col.Children.Clear()
            [void](Add-WtChild $col (New-WtCardHeader '즐겨찾기 문서' '' '문서 열기' 'docs'))
            if ($Result.Error) { [void](Add-WtChild $col (New-WtText '즐겨찾기를 읽지 못했습니다. 문서 탭에서 다시 시도하세요.' 'T.Sub')); return }
            foreach ($p in $Result.Items) {
                $b = New-WtButton $p.Name -Kind Link -Icon (Get-WtDocIcon $p.Kind) -ToolTip $p.Path
                $b.HorizontalAlignment = 'Left'; $b.Tag = $p
                $b.Add_Click({ param($s, $e) if ($s.Tag.IsDir) { Select-WtPage 'docs'; Show-WtDocFolder $s.Tag.Path -SelectTree } else { Open-WtDocEntry $s.Tag } })
                [void](Add-WtChild $col $b)
            }
        }
        default {
            if ($Job.Generation -ne $script:treeGeneration) { return }
            $node = $Job.Context
            $node.Items.Clear()
            if ($Result.Error) {
                $node.Tag.Loading = $false; [void]$node.Items.Add('읽지 못했습니다. 접었다 다시 펼치세요.'); $node.ToolTip = $Result.Error
                if ([object]::ReferenceEquals($node, $script:treeWaitNode)) { $script:treeWaitNode = $null; $script:treeTarget = $null }
                return
            }
            $node.Tag.Loading = $true
            [void]$node.Items.Add('불러오는 중…')
            $script:treeBatches.Add(@{ Node = $node; Paths = @($Result.Items); Index = 0; Generation = $Job.Generation })
            Request-WtDocTreeBatch
        }
    }
}

function Request-WtDocTreeBatch {
    if ($script:treeBatchScheduled -or $script:stopping -or -not $script:treeBatches.Count) { return }
    $script:treeBatchScheduled = $true
    [void]$script:ui.Tree.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ Complete-WtDocTreeBatch })
}

function Complete-WtDocTreeBatch {
    $script:treeBatchScheduled = $false
    if ($script:stopping -or -not $script:treeBatches.Count) { return }
    $batch = $script:treeBatches[0]
    if ($batch.Generation -ne $script:treeGeneration) { $script:treeBatches.RemoveAt(0); Request-WtDocTreeBatch; return }
    $node = $batch.Node
    if ($node.Items.Count -and $node.Items[$node.Items.Count - 1] -is [string]) { $node.Items.RemoveAt($node.Items.Count - 1) }
    $budget = Get-WtUiWorkBudget
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $added = 0
    while ($batch.Index -lt $batch.Paths.Count -and $added -lt $budget.Items) {
        $path = $batch.Paths[$batch.Index]
        [void]$node.Items.Add((New-WtDocTreeItem (Split-Path $path -Leaf) $path 0xE8B7))
        $batch.Index++; $added++
        if ($watch.ElapsedMilliseconds -ge $budget.Milliseconds) { break }
    }
    if ($batch.Index -eq $batch.Paths.Count) {
        $node.Tag.Loaded = $true; $node.Tag.Loading = $false
        $script:treeBatches.RemoveAt(0)
        # 찾아가던 길의 폴더를 다 읽었을 때만 이어서 찾는다. 다른 폴더를 펼쳐도 선택 · 스크롤 · 접어 둔 폴더를 건드리지 않는다
        if ($script:treeTarget -and [object]::ReferenceEquals($node, $script:treeWaitNode)) { Select-WtDocTreePath $script:treeTarget }
    } else { [void]$node.Items.Add('불러오는 중…') }
    Request-WtDocTreeBatch
}

function Stop-WtDocs {
    $script:stopping = $true
    $script:pending.Clear()
    $script:treeBatches.Clear()
    foreach ($job in $script:jobs) {
        $job.Request.Cancel.Value = $true
        $job.Context = $null
        if (-not $job.Handle.IsCompleted) {
            # 응답 없는 OS 호출 중에는 멈추기 · 닫기가 실패할 수 있다. 끝낼 때 오류 창을 띄우지 않는다
            try { [void]$job.PowerShell.BeginStop($null, $null) } catch { }
            try { $job.Runspace.CloseAsync() } catch { }
        }
    }
    if ($script:filterTimer) { $script:filterTimer.Stop() }
    Complete-WtDocJobs
}

function Cancel-WtDocFolder {
    $script:pending.Remove('folder')
    foreach ($job in $script:jobs) { if ($job.Key -eq 'folder') { $job.Request.Cancel.Value = $true } }
    $script:ui.Loading = $false; $script:ui.Error = '조회를 취소했습니다. 새로 고침으로 다시 시도하세요.'
    Update-WtDocList
}

function Get-WtDocSelected { $script:ui.List.SelectedItem }

function Set-WtDocStatus([string]$Text) { $script:ui.Status.Text = $Text }

function New-WtDocTreeItem([string]$Label, [string]$Path, [int]$Icon, [switch]$Leaf) {
    $ti = [System.Windows.Controls.TreeViewItem]::new()
    Set-WtStyle $ti 'TreeItem'
    $row = New-WtStack Horizontal 8
    $ic = New-WtIcon $Icon
    Set-WtResource $ic 'Foreground' 'B.SubText'
    [void](Add-WtChild $row $ic)
    $name = [System.Windows.Controls.TextBlock]::new()
    $name.Text = $Label
    $name.TextTrimming = 'CharacterEllipsis'
    $name.VerticalAlignment = 'Center'
    [void](Add-WtChild $row $name)
    $ti.Header = $row
    $ti.ToolTip = $Path
    $ti.Tag = @{ Path = $Path; Loaded = [bool]$Leaf; Loading = $false }
    if (-not $Leaf) { [void]$ti.Items.Add('…') }   # 펼칠 때 하위 폴더를 읽는다
    $ti.Add_Expanded({
            param($s, $e)
            if ($e.OriginalSource -eq $s) { Expand-WtDocNode $s }
        })
    $ti
}

function Expand-WtDocNode($Node) {
    if ($Node.Tag.Loaded -or $Node.Tag.Loading) { return }
    $Node.Tag.Loading = Start-WtDocRequest "tree:$($Node.Tag.Path)" 'tree' $Node.Tag.Path $Node
}

function Get-WtDocRootLabel([string]$Path) {
    $leaf = Split-Path $Path.TrimEnd('\') -Leaf
    if ($leaf) { $leaf } else { $Path }
}

function Update-WtDocTree {
    $script:treeGeneration++
    $script:treeTarget = $null; $script:treeWaitNode = $null
    $script:treeBatches.Clear()
    foreach ($key in @($script:pending.Keys)) { if ($key.StartsWith('tree:')) { $script:pending.Remove($key) } }
    foreach ($job in $script:jobs) { if ($job.Request.Action -eq 'tree') { $job.Request.Cancel.Value = $true; $job.Context = $null } }
    $tree = $script:ui.Tree
    $tree.Items.Clear()
    [void]$tree.Items.Add((New-WtDocTreeItem '즐겨찾기' '*' 0xE734 -Leaf))
    foreach ($r in (Get-WtDocRoots)) { [void]$tree.Items.Add((New-WtDocTreeItem (Get-WtDocRootLabel $r) $r 0xE8B7)) }
    $script:ui.RemoveRoot.IsEnabled = $false
}

# 트리에서 경로에 맞는 항목을 펼쳐 찾아 고른다. 아직 읽지 않은 폴더를 만나면 읽은 뒤 이어서 찾는다
function Select-WtDocTreePath([string]$Path) {
    $script:treeTarget = $Path
    $script:treeWaitNode = $null
    $items = $script:ui.Tree.Items
    $found = $null
    if ($Path -eq '*') { $found = $items[0] }
    else {
        foreach ($step in (Get-WtDocChain (Get-WtDocRoots) $Path)) {
            $next = $items | Where-Object { $_ -is [System.Windows.Controls.TreeViewItem] -and $_.Tag.Path.TrimEnd('\') -ieq $step.TrimEnd('\') } | Select-Object -First 1
            if (-not $next) { break }
            $found = $next
            if ($step.TrimEnd('\') -ine $Path.TrimEnd('\')) {
                Expand-WtDocNode $next; $next.IsExpanded = $true
                if (-not $next.Tag.Loaded) { $script:treeWaitNode = $next; break }
            }
            $items = $next.Items
        }
    }
    if (-not $script:treeWaitNode) { $script:treeTarget = $null }
    if ($found) {
        $script:selecting = $true
        try { $found.IsSelected = $true; $found.BringIntoView() } finally { $script:selecting = $false }
    }
}

# 오른쪽에 폴더(또는 즐겨찾기 '*')를 보여 준다. -Fallback: 이 폴더를 못 열면 대신 열 폴더
function Show-WtDocFolder([string]$Path, [switch]$SelectTree, [string]$Fallback = '') {
    $script:current = $Path
    $script:folderFallback = if ($Fallback) { @{ From = $Path; To = $Fallback } } else { $null }
    # 트리를 직접 고른 경우 등: 찾아가던 길이 있으면 그만둔다
    if (-not $SelectTree) { $script:treeTarget = $null; $script:treeWaitNode = $null }
    $script:entries = @()
    $script:ui.Loading = [bool]$Path
    $script:ui.Filter.Text = ''
    $script:ui.Error = $null
    if ($Path -eq '*') {
        $script:ui.PathText.Text = '즐겨찾기'
        [void](Start-WtDocRequest 'folder' 'pins' $Path)
    } elseif (-not $Path) {
        $script:ui.PathText.Text = ''
        $script:entries = @()
    } else {
        $script:ui.PathText.Text = Format-WtDocPathLabel (Get-WtDocRoots) $Path
        [void](Start-WtDocRequest 'folder' 'folder' $Path)
    }
    $script:ui.PathText.ToolTip = if ($Path -and $Path -ne '*') { $Path } else { $null }
    $script:ui.OpenFolder.IsEnabled = $Path -and $Path -ne '*'
    $script:ui.Up.IsEnabled = $Path -and $Path -ne '*' -and -not (@(Get-WtDocRoots) | Where-Object { $_.TrimEnd('\') -ieq $Path.TrimEnd('\') })
    Update-WtDocList
    if ($SelectTree) { Select-WtDocTreePath $Path }
}

function Update-WtDocList {
    $list = $script:ui.List
    $selected = $list.SelectedItem
    $shown = @(Find-WtDocEntry $script:entries $script:ui.Filter.Text)
    $list.ItemsSource = $shown
    if ($selected) { $list.SelectedItem = $shown | Where-Object Path -eq $selected.Path | Select-Object -First 1 }
    # 비어 있을 때 · 오류일 때 안내
    $msg = $null
    $action = $false
    if ($script:ui.Loading) { $msg = '불러오는 중…' }
    elseif ($script:ui.Error) { $msg = $script:ui.Error }
    elseif (-not @(Get-WtDocRoots).Count -and $script:current -ne '*') { $msg = '볼 폴더를 추가하세요.'; $action = $true }
    elseif ($script:current -eq '*' -and -not $script:entries.Count) { $msg = '즐겨찾기가 없습니다. 파일을 고르고 [즐겨찾기]를 누르세요.' }
    elseif (-not $script:current) { $msg = '왼쪽에서 폴더를 고르세요.' }
    elseif (-not $script:entries.Count) { $msg = '빈 폴더입니다.' }
    elseif (-not $shown.Count) { $msg = '이름이 맞는 항목이 없습니다.' }
    $script:ui.EmptyText.Text = [string]$msg
    Set-WtResource $script:ui.EmptyText 'Foreground' $(if ($script:ui.Error) { 'B.Danger' } else { 'B.SubText' })
    $script:ui.EmptyAdd.Visibility = if ($action) { 'Visible' } else { 'Collapsed' }
    $script:ui.Empty.Visibility = if ($msg) { 'Visible' } else { 'Collapsed' }
    $script:ui.Cancel.Visibility = if ($script:ui.Loading) { 'Visible' } else { 'Collapsed' }
    $dirs = @($shown | Where-Object IsDir).Count
    Set-WtDocStatus $(if ($script:current) { "폴더 $dirs · 파일 $($shown.Count - $dirs)" } else { '' })
    Update-WtDocCommands
}

# 아래 명령: 고른 항목이 있을 때만 쓸 수 있다
function Update-WtDocCommands {
    $e = Get-WtDocSelected
    $has = [bool]$e
    foreach ($b in $script:ui.ItemButtons) {
        $b.IsEnabled = $has -and -not ($e.Missing -and $b -ne $script:ui.Pin)
        $b.ToolTip = if ($has) { $b.Tag } else { '파일이나 폴더를 먼저 고르세요' }
    }
    $pinned = $has -and (Test-WtDocPinned $e.Path)
    $script:ui.Pin.Content = New-WtButtonContent $(if ($pinned) { '즐겨찾기에서 빼기' } else { '즐겨찾기' }) $(if ($pinned) { 0xE735 } else { 0xE734 })
    $script:ui.Open.Content = New-WtButtonContent $(if ($has -and $e.IsDir) { '들어가기' } else { '열기' }) 0xE8E5
}

function Add-WtDocRoot {
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = '문서 탭에서 볼 폴더를 고르세요 (공유 폴더도 됩니다)'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $path = $dlg.SelectedPath
    $roots = @(Get-WtDocRoots)
    if (-not ($roots | Where-Object { $_ -ieq $path })) { Set-WtSetting 'docs.roots' @($roots + $path) }
    Update-WtDocTree
    Show-WtDocFolder $path -SelectTree
}

function Remove-WtDocRoot {
    $node = $script:ui.Tree.SelectedItem
    if (-not $node -or -not ($node.Parent -is [System.Windows.Controls.TreeView]) -or $node.Tag.Path -eq '*') { return }
    $path = $node.Tag.Path
    Set-WtSetting 'docs.roots' @(Get-WtDocRoots | Where-Object { $_ -ine $path })
    Update-WtDocTree
    Show-WtDocFolder '*' -SelectTree
    Set-WtDocStatus "목록에서 뺐습니다: $path (폴더와 파일은 그대로)"
}

function New-WtDocsView {
    if ($script:filterTimer) { $script:filterTimer.Stop() }
    $script:ui = @{}
    $page = New-WtPage -Fill
    $add = New-WtButton '폴더 추가' -Icon 0xE710 -ToolTip '볼 폴더 추가'
    $add.Add_Click({ Add-WtDocRoot })
    $header = New-WtPageHeader '문서' '' $add
    [System.Windows.Controls.DockPanel]::SetDock($header, 'Top')
    [void]$page.Panel.Children.Add($header)

    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(280)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::new(1, 'Star')
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    # 왼쪽: 즐겨찾기 + 폴더 트리
    $left = New-WtCard
    $left.Padding = [System.Windows.Thickness]::new(12)
    $left.Margin = [System.Windows.Thickness]::new(0, 0, 16, 0)
    $ldock = [System.Windows.Controls.DockPanel]::new()
    $remove = New-WtButton '목록에서 빼기' -Kind Link -Icon 0xE738
    $remove.ToolTip = '고른 맨 위 폴더를 목록에서 뺍니다 (폴더는 그대로)'
    $remove.HorizontalAlignment = 'Left'
    $remove.Add_Click({ Remove-WtDocRoot })
    [System.Windows.Controls.DockPanel]::SetDock($remove, 'Bottom')
    [void]$ldock.Children.Add($remove)
    $tree = [System.Windows.Controls.TreeView]::new()
    Set-WtStyle $tree 'Tree'
    $tree.Add_SelectedItemChanged({
            param($s, $e)
            $node = $s.SelectedItem
            $script:ui.RemoveRoot.IsEnabled = [bool]($node -and $node.Parent -is [System.Windows.Controls.TreeView] -and $node.Tag.Path -ne '*')
            if ($script:selecting -or -not $node -or $node -isnot [System.Windows.Controls.TreeViewItem]) { return }
            if ($node.Tag.Path -ne $script:current) { Show-WtDocFolder $node.Tag.Path }
        })
    [void]$ldock.Children.Add($tree)
    $left.Child = $ldock
    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$grid.Children.Add($left)

    # 오른쪽: 경로 · 거르기 · 목록 · 명령
    $right = New-WtCard
    $right.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
    $rdock = [System.Windows.Controls.DockPanel]::new()

    $top = [System.Windows.Controls.DockPanel]::new()
    $up = New-WtButton '' -Kind Icon -Icon 0xE74A -ToolTip '위 폴더 (Alt+↑)'
    $up.Add_Click({ Show-WtDocFolder (Split-Path $script:current -Parent) -SelectTree })
    [System.Windows.Controls.DockPanel]::SetDock($up, 'Left')
    [void]$top.Children.Add($up)
    $refresh = New-WtButton '' -Kind Icon -Icon 0xE72C -ToolTip '새로 고침 (F5)'
    $refresh.Add_Click({ Show-WtDocFolder $script:current })
    $openFolder = New-WtButton '탐색기에서 열기' -Kind Link -Icon 0xE838
    $openFolder.Add_Click({ if ($script:current -and $script:current -ne '*') { Invoke-Item -LiteralPath $script:current } })
    foreach ($b in @($openFolder, $refresh)) { [System.Windows.Controls.DockPanel]::SetDock($b, 'Right'); [void]$top.Children.Add($b) }
    $pathText = New-WtText '' 'T.Strong'
    $pathText.TextWrapping = 'NoWrap'
    $pathText.TextTrimming = 'CharacterEllipsis'
    $pathText.VerticalAlignment = 'Center'
    $pathText.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
    [void]$top.Children.Add($pathText)
    $sb = New-WtSearchBox '이 폴더에서 이름으로 찾기'
    $filter = $sb.Box
    $filter.ToolTip = '띄어 쓰면 낱말이 모두 들어간 이름만 (Ctrl+F)'
    $script:filterTimer = New-WtPollTimer { $script:filterTimer.Stop(); Update-WtDocList }
    $filter.Add_TextChanged({ $script:filterTimer.Stop(); $script:filterTimer.Start() })
    $sb.Root.Margin = [System.Windows.Thickness]::new(0, 8, 0, 8)
    $cols = [System.Windows.Controls.DockPanel]::new()
    $cols.Margin = [System.Windows.Thickness]::new(12, 0, 12, 4)
    foreach ($h in @(@('크기', 80, 'Right'), @('고친 날짜', 130, 'Left'), @('종류', 90, 'Left'))) {
        $t = New-WtText $h[0] 'T.Sub'
        $t.FontWeight = 'SemiBold'
        $t.Width = $h[1]; $t.TextAlignment = $h[2]
        $t.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($t, 'Right')
        [void]$cols.Children.Add($t)
    }
    $nameHead = New-WtText '이름' 'T.Sub'
    $nameHead.FontWeight = 'SemiBold'
    $nameHead.Margin = [System.Windows.Thickness]::new(28, 0, 0, 0)
    [void]$cols.Children.Add($nameHead)
    $headStack = New-WtStack Vertical
    foreach ($x in @($top, $sb.Root, $cols)) { [void]$headStack.Children.Add($x) }
    $line = [System.Windows.Controls.Border]::new()
    Set-WtStyle $line 'Divider'
    [void]$headStack.Children.Add($line)
    [System.Windows.Controls.DockPanel]::SetDock($headStack, 'Top')
    [void]$rdock.Children.Add($headStack)

    # 아래 명령
    $cmd = [System.Windows.Controls.DockPanel]::new()
    $cmd.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    $status = New-WtText '' 'T.Sub'
    $status.VerticalAlignment = 'Center'
    $status.TextTrimming = 'CharacterEllipsis'
    $status.TextWrapping = 'NoWrap'
    $btns = New-WtStack Horizontal 8
    $open = New-WtButton '열기' -Kind Primary -Icon 0xE8E5
    $open.Tag = '원래 프로그램으로 열기 (Enter · 두 번 클릭)'
    $open.Add_Click({ Open-WtDocEntry (Get-WtDocSelected) })
    $reveal = New-WtButton '폴더에서 보기' -Icon 0xE838
    $reveal.Tag = '탐색기에서 이 파일을 골라 보여 줍니다'
    $reveal.Add_Click({ $x = Get-WtDocSelected; if ($x) { Show-WtDocInExplorer $x.Path } })
    $copy = New-WtButton '경로 복사' -Icon 0xE8C8
    $copy.Tag = '전체 경로를 클립보드에 복사'
    $copy.Add_Click({ $x = Get-WtDocSelected; if ($x) { Copy-WtDocPath $x.Path } })
    $pin = New-WtButton '즐겨찾기' -Icon 0xE734
    $pin.Tag = '즐겨찾기에 넣거나 뺍니다 (홈에도 보임)'
    $pin.Add_Click({
            $x = Get-WtDocSelected
            if (-not $x) { return }
            $on = Switch-WtDocPin $x.Path
            if ($script:current -eq '*') { Show-WtDocFolder '*' } else { Update-WtDocCommands }
            Set-WtDocStatus $(if ($on) { "즐겨찾기에 넣었습니다: $($x.Name)" } else { "즐겨찾기에서 뺐습니다: $($x.Name)" })
        })
    foreach ($b in @($open, $reveal, $copy, $pin)) {
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($b, $true)   # 못 쓸 때 이유를 보여 준다
        [void](Add-WtChild $btns $b)
    }
    [System.Windows.Controls.DockPanel]::SetDock($btns, 'Left')
    [void]$cmd.Children.Add($btns)
    $status.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $status.TextAlignment = 'Right'
    [void]$cmd.Children.Add($status)
    $cwrap = New-WtStack Vertical
    $line2 = [System.Windows.Controls.Border]::new()
    Set-WtStyle $line2 'Divider'
    [void]$cwrap.Children.Add($line2)
    [void]$cwrap.Children.Add($cmd)
    [System.Windows.Controls.DockPanel]::SetDock($cwrap, 'Bottom')
    [void]$rdock.Children.Add($cwrap)

    # 목록 + 비었을 때 안내
    $area = [System.Windows.Controls.Grid]::new()
    $list = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $list 'Doc.List'
    $list.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $list.Add_SelectionChanged({ Update-WtDocCommands })
    $list.Add_MouseDoubleClick({
            param($s, $e)
            # 행 위에서 두 번 눌렀을 때만 (빈 곳 · 스크롤 막대는 무시)
            $d = $e.OriginalSource
            while ($d -and $d -isnot [System.Windows.Controls.ListBoxItem] -and $d -is [System.Windows.Media.Visual]) { $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d) }
            if ($d -is [System.Windows.Controls.ListBoxItem]) { Open-WtDocEntry $d.Tag }
        })
    $list.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Enter' -and $s.SelectedItem) { Open-WtDocEntry $s.SelectedItem; $e.Handled = $true } })
    [void]$area.Children.Add($list)
    $empty = New-WtStack Vertical 12
    $empty.HorizontalAlignment = 'Center'
    $empty.VerticalAlignment = 'Center'
    $emptyText = New-WtText '' 'T.Sub'
    $emptyText.TextAlignment = 'Center'
    $emptyAdd = New-WtButton '폴더 추가' -Icon 0xE710
    $emptyAdd.HorizontalAlignment = 'Center'
    $emptyAdd.Add_Click({ Add-WtDocRoot })
    [void](Add-WtChild $empty $emptyText)
    [void](Add-WtChild $empty $emptyAdd)
    $cancel = New-WtButton '취소' -Kind Link
    $cancel.Add_Click({ Cancel-WtDocFolder })
    $cancel.Visibility = 'Collapsed'
    [void](Add-WtChild $empty $cancel)
    [void]$area.Children.Add($empty)
    [void]$rdock.Children.Add($area)
    $right.Child = $rdock
    [System.Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$grid.Children.Add($right)
    [void]$page.Panel.Children.Add($grid)

    # 문서 화면 안 단축키
    $page.Root.Add_PreviewKeyDown({
            param($s, $e)
            $mods = [System.Windows.Input.Keyboard]::Modifiers
            $key = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
            if ($key -eq 'F5') { Show-WtDocFolder $script:current; $e.Handled = $true; return }
            if ($key -eq 'Up' -and ($mods -band [System.Windows.Input.ModifierKeys]::Alt) -and $script:ui.Up.IsEnabled) {
                Show-WtDocFolder (Split-Path $script:current -Parent) -SelectTree; $e.Handled = $true; return
            }
            if ($key -eq 'F' -and ($mods -band [System.Windows.Input.ModifierKeys]::Control)) { [void]$script:ui.Filter.Focus(); $e.Handled = $true }
        })

    $script:ui = @{
        Tree = $tree; RemoveRoot = $remove; List = $list; Filter = $filter; PathText = $pathText; Status = $status
        Up = $up; OpenFolder = $openFolder; Open = $open; Pin = $pin; ItemButtons = @($open, $reveal, $copy, $pin)
        Empty = $empty; EmptyText = $emptyText; EmptyAdd = $emptyAdd; Cancel = $cancel; Error = $null; Loading = $false
    }
    $page.Root
}

function Update-WtDocsView {
    Update-WtDocTree
    $roots = @(Get-WtDocRoots)
    $first = if ($roots.Count) { $roots[0] } else { '*' }
    $last = [string](Get-WtSetting 'docs.last')
    if ($last -and $last -ne $first -and (Get-WtDocChain $roots $last).Count) { Show-WtDocFolder $last -SelectTree -Fallback $first }
    else { Show-WtDocFolder $first -SelectTree }
}

# 홈: 즐겨찾기 바로 열기
function New-WtDocsHomeCard {
    $pins = @(Get-WtSetting 'docs.pins')
    if (-not $pins.Count) { return }
    $card = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '즐겨찾기 문서' "$($pins.Count)" '문서 열기' 'docs'))
    [void](Add-WtChild $col (New-WtText '불러오는 중…' 'T.Sub'))
    $card.Child = $col
    [void](Start-WtDocRequest 'home' 'pins' '' $col)
    $card
}

Register-WtAddon -Id 'docs' -Title '문서' -Icon 0xE8B7 -Order 50 -WarmUp View `
    -NewView { New-WtDocsView } `
    -Refresh { param($view) Update-WtDocsView } `
    -HomeCard { New-WtDocsHomeCard } `
    -OnExit { Stop-WtDocs } `
    -Help '문서는 고른 폴더의 파일을 보고 원래 프로그램으로 엽니다. 파일 내용은 읽거나 옮기지 않습니다.' `
    -Shortcuts @(@('Enter', '고른 파일 열기 · 폴더 들어가기'), @('Alt + ↑', '위 폴더'), @('F5', '새로 고침'), @('Ctrl + F', '이름으로 거르기'))

Export-ModuleMember -Function Get-WtDocKind, Format-WtDocSize, Get-WtDocEntries, Get-WtDocSubfolders, Get-WtDocPinEntries,
    Test-WtDocPinned, Switch-WtDocPin, Get-WtDocRoots, Get-WtDocChain, Find-WtDocEntry, Format-WtDocPathLabel
} | Import-Module -Force -DisableNameChecking
# ---- addons\docs\Docs.psm1 끝 ----

# ---- addons\home\Home.psm1 ----
New-Module -Name 'WorkTool.addon.home' -ScriptBlock {
# 홈 탭. 다른 탭이 등록한 홈 카드(HomeCard)를 모아서 두 줄로 보여 준다.
# 탭을 더하면 그 탭의 카드도 여기에 저절로 나온다. 홈은 다른 탭의 데이터를 직접 읽지 않는다.

$ErrorActionPreference = 'Stop'

$script:dateText = $null
$script:columns = $null

function New-WtHomeView {
    $page = New-WtPage
    # 머리글: 날짜(열 때마다 새로 씀) + 제목
    $header = New-WtStack Vertical 4
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $script:dateText = New-WtText '' 'T.Sub'
    [void](Add-WtChild $header $script:dateText)
    [void](Add-WtChild $header (New-WtText '오늘' 'T.Title'))
    [void](Add-WtChild $page.Panel $header)

    $grid = [System.Windows.Controls.Grid]::new()
    $script:columns = @()
    for ($i = 0; $i -lt 2; $i++) {
        $cd = [System.Windows.Controls.ColumnDefinition]::new()
        $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
        $grid.ColumnDefinitions.Add($cd)
        $col = New-WtStack Vertical 16
        $col.Margin = [System.Windows.Thickness]::new($(if ($i -eq 0) { 0 } else { 8 }), 0, $(if ($i -eq 0) { 8 } else { 0 }), 0)
        [System.Windows.Controls.Grid]::SetColumn($col, $i)
        [void]$grid.Children.Add($col)
        $script:columns += $col
    }
    [void](Add-WtChild $page.Panel $grid)
    $page.Root
}

function Update-WtHomeView {
    $script:dateText.Text = Format-WtDate (Get-Date) 'yyyy년 M월 d일 dddd'
    foreach ($c in $script:columns) { $c.Children.Clear() }
    $cards = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @(Get-WtAddon)) {
        if (-not $a.HomeCard -or $a.Id -eq 'home') { continue }
        try {
            foreach ($el in @(& $a.HomeCard)) { if ($el -is [System.Windows.UIElement]) { $cards.Add($el) } }
        } catch {
            $cards.Add((New-WtText "$($a.Title) 카드를 만들지 못했습니다: $($_.Exception.Message)" 'T.Sub'))
        }
    }
    # 왼쪽 · 오른쪽에 번갈아 놓는다
    for ($i = 0; $i -lt $cards.Count; $i++) {
        [void](Add-WtChild $script:columns[$i % 2] $cards[$i])
    }
    if (-not $cards.Count) {
        [void](Add-WtChild $script:columns[0] (New-WtText '홈에 보여 줄 카드가 없습니다.' 'T.Sub'))
    }
}

Register-WtAddon -Id 'home' -Title '홈' -Icon 0xE80F -Order 0 -Required `
    -NewView { New-WtHomeView } `
    -Refresh { param($view) Update-WtHomeView }

Export-ModuleMember -Function @()
} | Import-Module -Force -DisableNameChecking
# ---- addons\home\Home.psm1 끝 ----

# ---- addons\memo\Memo.psm1 ----
New-Module -Name 'WorkTool.addon.memo.Memo' -ScriptBlock {
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

# 저장 상태 표시 (칸마다): saved · dirty · error · ''(숨김)
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
    Set-WtMemoStatus $Pane $(if ($m) { 'saved' } else { '' })
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

# 고친 칸을 모두 바로 저장한다. 저장 시각 · 탭 제목 · 목록도 고친다. 실패하면 $false (고친 표시는 남긴다)
function Save-WtMemoNow {
    if ($script:saveTimer) { $script:saveTimer.Stop() }
    $dirty = @($script:panes | Where-Object { $_.Dirty })
    if (-not $dirty.Count) { return $true }
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
    foreach ($p in $script:panes) {
        if (-not $p.Current -or -not $byId.Contains([string]$p.Current.Id)) { continue }
        Update-WtMemoPaneContent $p
        Set-WtMemoStatus $p 'saved'
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
        'S' { [void](Save-WtMemoNow); return $true }
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

Register-WtAddon -Id 'memo' -Title '메모' -Icon 0xE70B -Order 40 -WarmUp Full `
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
} | Import-Module -Force -DisableNameChecking
# ---- addons\memo\Memo.psm1 끝 ----

# ---- addons\memo\MemoEditor.psm1 ----
New-Module -Name 'WorkTool.addon.memo.MemoEditor' -ScriptBlock {
# 메모 편집기. 메모 화면의 칸(pane)마다 하나씩 만든다. 화면 배치 · 탭 · 저장은 Memo.psm1이 하고, 여기는 본문 한 칸만 맡는다.
#
# 모드
#   live    Obsidian처럼 그린 글 위에서 바로 고친다. 고치는 블록만 원문으로 보인다(섬)
#   source  원문(마크다운 그대로)
#   read    읽기 전용으로 그린 글
#
# 쓰는 법 (Memo.psm1)
#   $ed = New-WtMemoEditor -OnChanged { param($ed) ... } -OnLeave { param($ed) ... } `
#           -OnLink { param($ed, $link, $how) ...; $true } -OnTitles { param($ed, $prefix) ... }
#   $ed.Root를 화면에 넣는다
#   Set-WtMemoEditorText $ed $text      불러오기 (OnChanged를 부르지 않는다. 실행 취소 기록을 비운다)
#   Get-WtMemoEditorText $ed            지금 글 전체
#   Set-WtMemoEditorMode $ed 'live'     모드 바꾸기 (글은 그대로)
#   Set-WtMemoEditorEnabled $ed $false  메모가 없을 때
#   Set-WtMemoEditorFocus $ed [-End]    포커스 (커서는 마지막 자리, -End면 글 끝)
#   Get-WtMemoEditorState $ed / Set-WtMemoEditorState $ed $state   탭을 오갈 때 커서 · 스크롤 기억
#
# 알림
#   OnChanged  사용자가 글을 고쳤을 때
#   OnLeave    편집기 밖으로 포커스가 나갈 때 (저장)
#   OnLink     링크 · [[위키 링크]] · #태그를 눌렀을 때. $how = 'here' | 'tab'(Ctrl) | 'side'(Ctrl+Alt). 처리했으면 $true
#   OnTitles   [[ 자동 완성 후보. 메모 제목 문자열 배열을 돌려준다
#
# 실시간(live) 모드의 짜임
#   - 글은 줄 목록($ed.Lines)으로 들고, Get-WtMarkdownUnits로 블록(단위)을 나눠 단위마다 Section 하나로 그린다.
#   - 커서가 있는 단위만 BlockUIContainer 안의 TextBox(섬)로 바꿔 원문을 고친다. 한글 입력 · 선택 · 붙여넣기는 TextBox 그대로다.
#   - 섬 밖으로 나가면(↑↓←→ · 클릭) 고친 줄을 되돌려 넣고 바뀐 단위만 다시 그린다(그린 Section은 원문이 같으면 다시 쓴다).
#   - 실행 취소는 편집기가 따로 든다(글 전체 + 커서 자리). 섬을 옮겨 다녀도 이어진다.
#
# 이벤트 처리기는 나중에 불리므로 보낸 요소($s)의 Tag(= $ed, 보기는 Tag.Editor)와 $script: 변수만 쓴다.

$ErrorActionPreference = 'Stop'

$script:editors = [System.Collections.Generic.List[System.WeakReference]]::new()
$script:undoPause = [TimeSpan]::FromMilliseconds(1200)   # 이만큼 쉬었다 치면 실행 취소 단위를 새로 나눈다
$script:undoLimit = 200

# ---- 만들기 -----------------------------------------------------------------------------------

function New-WtMemoEditor {
    param([scriptblock]$OnChanged, [scriptblock]$OnLeave, [scriptblock]$OnLink, [scriptblock]$OnTitles)
    $ed = @{
        Mode = 'live'; Lines = [System.Collections.Generic.List[string]]::new(); NewLine = "`r`n"
        Enabled = $true; Loading = $false; Busy = 0
        OnChanged = $OnChanged; OnLeave = $OnLeave; OnLink = $OnLink; OnTitles = $OnTitles
        Units = [System.Collections.Generic.List[object]]::new(); Sections = [System.Collections.Generic.List[object]]::new()
        Rendered = 0; RenderTimer = $null; NextListId = 1; Cache = [System.Collections.Generic.Dictionary[string, object]]::new()
        Island = $null; Caret = @{ Line = 0; Col = 0 }; Drag = $null
        Undo = [System.Collections.Generic.List[object]]::new(); Redo = [System.Collections.Generic.List[object]]::new()
        LastEdit = [datetime]::MinValue; IslandPrev = ''; ReadText = $null
    }
    $ed.Lines.Add('')
    # 편집기 = 위 찾기 막대(숨김) + 본문(원문 칸 · 실시간 보기 · 읽기 보기 중 하나만 보임)
    $root = [System.Windows.Controls.DockPanel]::new()
    $root.Tag = $ed
    $ed.Root = $root
    $root.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoEditorKey $s $e })
    $find = New-WtMemoFindBar $ed
    [System.Windows.Controls.DockPanel]::SetDock($find, 'Top')
    [void]$root.Children.Add($find)
    $body = [System.Windows.Controls.Grid]::new()
    [void]$root.Children.Add($body)
    $ed.Body = $body

    # 원문 모드 칸
    $box = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $box 'Editor'
    $box.Tag = $ed
    $box.IsInactiveSelectionHighlightEnabled = $true   # 찾기 칸에 포커스가 있어도 찾은 곳이 보이게
    $box.Add_TextChanged({
            param($s, $e)
            $ed = $s.Tag
            if ($ed.Loading) { return }
            Invoke-WtMemoEditorChanged $ed
        })
    Add-WtMemoBoxHandlers $box
    [void]$body.Children.Add($box)
    $ed.Source = $box

    # 실시간 모드 보기 (단위별로 그린 문서 + 섬)
    $live = New-WtMarkdownView -Scroll -OnLink { param($link, $st) Invoke-WtMemoEditorLink $link $st } -OnTask { param($line, $el) Invoke-WtMemoTaskClick $line $el }
    $live.Tag.Editor = $ed
    # 문서에서 블록을 빼고 넣을 때 RichTextBox가 실행 취소용으로 뺀 요소를 XAML로 저장하려 한다.
    # 섬(Tag에 편집기 상태)을 저장하다 끝없이 파고들어 멈추므로 끈다. 실행 취소는 편집기가 따로 든다
    $live.IsUndoEnabled = $false
    $live.Add_PreviewMouseLeftButtonDown({ param($s, $e) Invoke-WtMemoLiveMouseDown $s $e })
    $live.Add_PreviewMouseMove({ param($s, $e) Invoke-WtMemoLiveMouseMove $s $e })
    $live.Add_PreviewMouseLeftButtonUp({ param($s, $e) Invoke-WtMemoLiveMouseUp $s $e })
    $live.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoLiveKey $s $e })
    $live.Cursor = [System.Windows.Input.Cursors]::IBeam
    [void]$body.Children.Add($live)
    $ed.Live = $live
    Set-WtMarkdownText $live ''

    # 읽기 모드 보기 (문서 전체를 한 번에 그림)
    $view = New-WtMarkdownView -Scroll -OnLink { param($link, $st) Invoke-WtMemoEditorLink $link $st } -OnTask { param($line, $el) Invoke-WtMemoTaskClick $line $el }
    $view.Tag.Editor = $ed
    $view.IsInactiveSelectionHighlightEnabled = $true
    [void]$body.Children.Add($view)
    $ed.View = $view

    # 섬: 실시간 모드에서 고치는 단위 자리에 들어가는 원문 입력칸 (하나를 옮겨 가며 쓴다)
    $island = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $island 'Memo.Island'
    $island.Tag = $ed
    $island.IsUndoEnabled = $false
    $island.IsInactiveSelectionHighlightEnabled = $true
    # IsReadOnly는 부모에서 물려받는 속성이다. 섬은 읽기 전용 RichTextBox 안에 들어가므로 직접 끈다
    $island.IsReadOnly = $false
    $island.Add_TextChanged({
            param($s, $e)
            $ed = $s.Tag
            if ($ed.Loading -or -not $ed.Island) { return }
            Add-WtMemoTypingUndo $ed
            $ed.IslandPrev = $s.Text
            Invoke-WtMemoEditorChanged $ed
        })
    Add-WtMemoBoxHandlers $island -Island
    $island.Add_PreviewMouseWheel({ param($s, $e) Invoke-WtMemoIslandWheel $s $e })
    $ed.IslandBox = $island
    # 자동 완성 팝업은 미리 붙여 둔다 (막 붙인 팝업은 그려지기 전까지 열기가 미뤄진다)
    [void](Get-WtMemoSuggestUi $ed)

    $root.Add_LostKeyboardFocus({
            param($s, $e)
            $ed = $s.Tag
            # 편집기 안에서 포커스가 옮겨 다닐 때 · 섬을 옮기는 중에는 부르지 않는다
            if ($ed.Busy -or $s.IsKeyboardFocusWithin) { return }
            if ($ed.Island) { Close-WtMemoIsland $ed }
            if ($ed.OnLeave) { & $ed.OnLeave $ed }
        })
    # 글을 고치는 칸(원문 · 섬)에서는 Ctrl+B가 굵게다. 읽기 모드 등 나머지 자리에서는 셸의 메뉴 접기 그대로
    Register-WtKeyOwner $box 'Ctrl+B'
    Register-WtKeyOwner $island 'Ctrl+B'
    for ($i = $script:editors.Count - 1; $i -ge 0; $i--) { if (-not $script:editors[$i].IsAlive) { $script:editors.RemoveAt($i) } }
    $script:editors.Add([System.WeakReference]::new($ed))
    Update-WtMemoEditorMode $ed
    $ed
}

# 원문 칸 · 섬 공통: 편집 단축키 · 글자 입력 · 붙여넣기 · 끌어 놓기 · [[ 자동 완성.
# 키는 자동 완성 → (섬이면) 섬 이동 → 편집 명령 차례로 받는다
function Add-WtMemoBoxHandlers($Box, [switch]$Island) {
    $Box.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoSuggestKey $s $e })
    if ($Island) { $Box.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoIslandKey $s $e }) }
    $Box.Add_PreviewKeyDown({ param($s, $e) Invoke-WtMemoBoxKey $s $e })
    $Box.Add_TextChanged({ param($s, $e) if (-not $s.Tag.Loading) { Update-WtMemoSuggest $s } })
    $Box.Add_SelectionChanged({ param($s, $e) if ($s.Tag.Suggest -and $s.Tag.Suggest.Popup.IsOpen) { Update-WtMemoSuggest $s } })
    $Box.Add_LostKeyboardFocus({ param($s, $e) Hide-WtMemoSuggest $s.Tag })
    $Box.Add_PreviewTextInput({ param($s, $e) Invoke-WtMemoBoxText $s $e })
    [System.Windows.DataObject]::AddPastingHandler($Box, [System.Windows.DataObjectPastingEventHandler] { param($s, $e) Invoke-WtMemoBoxPaste $s $e })
    $Box.AllowDrop = $true
    $Box.Add_PreviewDragOver({ param($s, $e) Invoke-WtMemoBoxDragOver $s $e })
    $Box.Add_PreviewDrop({ param($s, $e) Invoke-WtMemoBoxDrop $s $e })
}

function Invoke-WtMemoEditorChanged($Ed) {
    if ($Ed.OnChanged) { & $Ed.OnChanged $Ed }
}

# 마크다운 보기의 링크 처리기. 보기 상태(Tag)의 Editor가 그 편집기다
function Invoke-WtMemoEditorLink($Link, $St) {
    $ed = if ($St -is [hashtable] -and $St.Editor) { $St.Editor } else { Find-WtMemoEditorFrom ([System.Windows.Input.Mouse]::DirectlyOver) }
    if (-not $ed -or -not $ed.OnLink) { return $false }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $how = if (($mods -band 'Control') -and ($mods -band 'Alt')) { 'side' } elseif ($mods -band 'Control') { 'tab' } else { 'here' }
    $r = & $ed.OnLink $ed $Link $how | Select-Object -Last 1
    $r -eq $true
}

# 할 일 체크 표시를 눌렀을 때: 그 줄의 [ ] ↔ [x]. 실시간 모드는 그려 둔 Section을 다시 쓰므로
# 그릴 때의 줄 번호($Line)를 단위가 옮겨 간 만큼(Start - Base) 옮겨 쓴다
function Invoke-WtMemoTaskClick([int]$Line, $El) {
    $ed = Find-WtMemoEditorFrom $El
    if (-not $ed -or -not $ed.Enabled) { return }
    $target = $Line - 1
    if ($ed.Mode -eq 'live') {
        $sec = $El
        while ($sec -and -not ($sec -is [System.Windows.Documents.Section] -and $sec.Tag -is [hashtable] -and $sec.Tag.ContainsKey('Kind'))) {
            $sec = [System.Windows.LogicalTreeHelper]::GetParent($sec)
        }
        if ($sec) {
            $u = $sec.Tag
            $target = $u.Start + ($Line - 1 - $u.Base)
            $isl = $ed.Island
            if ($isl -and $u.Start -ge $isl.End) { $target += @($ed.IslandBox.Text -split "\r?\n").Count - ($isl.End - $isl.Start) }
        }
    }
    $ed.Busy++
    try {
        if ($ed.Island) { Close-WtMemoIsland $ed }
        if ($target -lt 0 -or $target -ge $ed.Lines.Count) { return }
        $text = $ed.Lines[$target]
        $m = [regex]::Match($text, '^(\s*(?:>\s*)*(?:[-*+]|\d{1,9}[.)])\s+\[)([ xX])\]')
        if (-not $m.Success) { return }
        $mark = if ($m.Groups[2].Value -eq ' ') { 'x' } else { ' ' }
        $next = $text.Substring(0, $m.Groups[2].Index) + $mark + $text.Substring($m.Groups[2].Index + 1)
        if ($ed.Mode -eq 'live') {
            Push-WtMemoUndo $ed
            # 섬을 거쳐 바꾸면 그 둘레만 다시 그린다
            $range = Get-WtMemoUnitRange $ed $target $target
            Open-WtMemoIsland $ed $range[0] $range[1] $target 0
            $box = $ed.IslandBox
            $i = Get-WtMemoIslandIndex $ed $target $m.Groups[2].Index
            $box.Select($i, 1)
            $box.SelectedText = $mark
            Close-WtMemoIsland $ed
            $ed.LastEdit = [datetime]::MinValue   # 다음에 치는 글은 따로 되돌리게
            [void]$ed.Live.Focus()
        } else {
            # 읽기 보기는 문서를 통째로 다시 그리므로 스크롤 자리를 지킨다
            $sv = Get-WtMemoScroller $ed.View
            $y = if ($sv) { $sv.VerticalOffset } else { 0 }
            $ed.Lines[$target] = $next
            $ed.ReadText = $null
            Update-WtMemoRead $ed
            if ($sv) { $ed.View.UpdateLayout(); $sv.ScrollToVerticalOffset($y) }
            Invoke-WtMemoEditorChanged $ed
        }
    } finally { $ed.Busy-- }
}

function Find-WtMemoEditorFrom($El) {
    while ($El) {
        if ($El -is [System.Windows.FrameworkElement] -and $El.Tag -is [hashtable]) {
            if ($El.Tag.ContainsKey('Editor') -and $El.Tag.Editor) { return $El.Tag.Editor }
            if ($El.Tag.ContainsKey('IslandBox')) { return $El.Tag }
        }
        $El = Get-WtMemoParent $El
    }
    $null
}

function Get-WtMemoParent($El) {
    if ($El -is [System.Windows.Media.Visual] -or $El -is [System.Windows.Media.Media3D.Visual3D]) {
        $p = [System.Windows.Media.VisualTreeHelper]::GetParent($El)
        if ($p) { return $p }
    }
    if ($El -is [System.Windows.DependencyObject]) { return [System.Windows.LogicalTreeHelper]::GetParent($El) }
    $null
}

# ---- 글 · 모드 ---------------------------------------------------------------------------------

function Set-WtMemoEditorText($Ed, [AllowEmptyString()][string]$Text) {
    $Text = [string]$Text
    # 고치던 칸에 포커스가 있었으면(탭을 바꾸는 단축키 등) 불러온 뒤에도 편집기 안에 둔다
    $hadFocus = $Ed.Root.IsKeyboardFocusWithin -and -not $Ed.Find.Bar.IsKeyboardFocusWithin
    $Ed.Loading = $true
    $Ed.Busy++
    try {
        Hide-WtMemoSuggest $Ed
        $Ed.NewLine = if ($Text.Contains("`r`n")) { "`r`n" } elseif ($Text.Contains("`n") -or $Text.Contains("`r")) { "`n" } else { "`r`n" }
        Set-WtMemoLines $Ed $Text
        $Ed.Undo.Clear()
        $Ed.Redo.Clear()
        $Ed.LastEdit = [datetime]::MinValue   # 불러온 뒤 처음 치는 글은 새 실행 취소 단위
        $Ed.LeftLiveText = $null
        if ($Ed.Island) { $Ed.Island.Holder.Child = $null }
        $Ed.Island = $null
        $Ed.Caret = @{ Line = 0; Col = 0 }
        $Ed.ReadText = $null
        $Ed.Cache.Clear()   # 다른 메모의 그린 블록을 붙잡고 있지 않게
        switch ($Ed.Mode) {
            'source' { $Ed.Source.Text = $Text; $Ed.Source.CaretIndex = 0; $Ed.Source.ScrollToHome() }
            'live' { Update-WtMemoLive $Ed; Get-WtMemoScroller $Ed.Live | ForEach-Object { $_.ScrollToHome() } }
            'read' { Update-WtMemoRead $Ed }
        }
        if ($hadFocus) {
            # 실시간은 보기에 포커스를 두고, 다음 키 입력 때 커서 자리에 섬을 연다 (Set-WtMemoEditorState가 커서를 옮길 수 있게)
            switch ($Ed.Mode) { 'source' { [void]$Ed.Source.Focus() } 'live' { [void]$Ed.Live.Focus() } 'read' { [void]$Ed.View.Focus() } }
        }
    } finally { $Ed.Loading = $false; $Ed.Busy-- }
}

# 줄 나누기는 마크다운 블록 나누기(Get-WtMarkdownUnits)와 같은 규칙: \r\n · \r · \n 모두 줄바꿈
function Set-WtMemoLines($Ed, [string]$Text) {
    $Ed.Lines.Clear()
    foreach ($l in ($Text -split "\r\n|\r|\n")) { $Ed.Lines.Add($l) }
}

function Get-WtMemoEditorText($Ed) {
    # 원문 칸은 Enter가 \r\n을 넣으므로 \n 글이면 줄바꿈이 섞인다. 글의 줄바꿈으로 맞춘다
    if ($Ed.Mode -eq 'source') { return [regex]::Replace([string]$Ed.Source.Text, "\r\n|\r|\n", $Ed.NewLine) }
    if ($Ed.Island) {
        $isl = $Ed.Island
        $mid = @($Ed.IslandBox.Text -split "\r?\n")
        $before = if ($isl.Start -gt 0) { @($Ed.Lines.GetRange(0, $isl.Start)) } else { @() }
        $after = if ($isl.End -lt $Ed.Lines.Count) { @($Ed.Lines.GetRange($isl.End, $Ed.Lines.Count - $isl.End)) } else { @() }
        return (@($before) + @($mid) + @($after)) -join $Ed.NewLine
    }
    @($Ed.Lines) -join $Ed.NewLine
}

function Set-WtMemoEditorMode($Ed, [ValidateSet('live', 'source', 'read')][string]$Mode) {
    if ($Ed.Mode -eq $Mode) { return }
    $text = Get-WtMemoEditorText $Ed
    $hadFocus = $Ed.Root.IsKeyboardFocusWithin
    $Ed.Busy++
    try {
        if ($Ed.Island) { Close-WtMemoIsland $Ed -NoRender }
        # 실시간을 떠날 때의 글. 원문 · 읽기에서 고치고 돌아오면 이 글을 실행 취소 기록에 넣는다(그 고친 것만 되돌리게)
        $norm = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        if ($Ed.Mode -eq 'live') { $Ed.LeftLiveText = $norm }
        elseif ($Mode -eq 'live' -and $null -ne $Ed.LeftLiveText -and $Ed.LeftLiveText -cne $norm) {
            Add-WtMemoUndoEntry $Ed @{ Text = $Ed.LeftLiveText; Line = $Ed.Caret.Line; Col = $Ed.Caret.Col }
            $Ed.LastEdit = [datetime]::MinValue
        }
        $Ed.Mode = $Mode
        $Ed.Loading = $true
        try {
            Set-WtMemoLines $Ed $text
            if ($Mode -eq 'source') { $Ed.Source.Text = $text }
        } finally { $Ed.Loading = $false }
        Update-WtMemoEditorMode $Ed
    } finally { $Ed.Busy-- }
    if ($hadFocus) { Set-WtMemoEditorFocus $Ed }
}

function Update-WtMemoEditorMode($Ed) {
    switch ($Ed.Mode) {
        'live' { Update-WtMemoLive $Ed }
        'read' { Update-WtMemoRead $Ed }
    }
    $Ed.Source.Visibility = if ($Ed.Mode -eq 'source') { 'Visible' } else { 'Collapsed' }
    $Ed.Live.Visibility = if ($Ed.Mode -eq 'live') { 'Visible' } else { 'Collapsed' }
    $Ed.View.Visibility = if ($Ed.Mode -eq 'read') { 'Visible' } else { 'Collapsed' }
}

function Update-WtMemoRead($Ed) {
    $text = @($Ed.Lines) -join "`n"
    if ($Ed.ReadText -ceq $text -and -not $Ed.View.Tag.Error) { return }
    Set-WtMarkdownText $Ed.View $text
    $Ed.ReadText = $text
}

function Set-WtMemoEditorEnabled($Ed, [bool]$Enabled) {
    $Ed.Enabled = $Enabled
    $Ed.Root.IsEnabled = $Enabled
}

function Set-WtMemoEditorFocus($Ed, [switch]$End) {
    switch ($Ed.Mode) {
        'read' { [void]$Ed.View.Focus() }
        'source' {
            if ($End) { $Ed.Source.CaretIndex = $Ed.Source.Text.Length }
            [void]$Ed.Source.Focus()
        }
        'live' {
            if ($End) {
                if ($Ed.Island) { $Ed.Busy++; try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- } }
                $last = $Ed.Lines.Count - 1
                $Ed.Caret = @{ Line = $last; Col = $Ed.Lines[$last].Length }
            }
            if ($Ed.Island) { [void]$Ed.IslandBox.Focus(); return }
            Open-WtMemoIslandAt $Ed $Ed.Caret.Line $Ed.Caret.Col
        }
    }
}

# 상태 = @{ Line; Col; Scroll } (커서 줄 · 칸은 0부터, 모드와 상관없이 같은 뜻)
function Get-WtMemoEditorState($Ed) {
    $sv = Get-WtMemoScroller $(if ($Ed.Mode -eq 'live') { $Ed.Live } elseif ($Ed.Mode -eq 'read') { $Ed.View } else { $Ed.Source })
    if ($Ed.Mode -eq 'live' -and $Ed.Island) { $Ed.Caret = Get-WtMemoIslandCaret $Ed }
    if ($Ed.Mode -eq 'source') {
        $b = $Ed.Source
        $parts = @($b.Text.Substring(0, $b.CaretIndex) -split "\r?\n")
        $Ed.Caret = @{ Line = $parts.Count - 1; Col = $parts[$parts.Count - 1].Length }
    }
    @{ Line = $Ed.Caret.Line; Col = $Ed.Caret.Col; Scroll = $(if ($sv) { $sv.VerticalOffset } else { 0 }) }
}

function Set-WtMemoEditorState($Ed, $State) {
    if (-not $State) { return }
    if ($null -ne $State.Line) {
        $lines = if ($Ed.Mode -eq 'source') { @($Ed.Source.Text -split "\r?\n") } else { @($Ed.Lines) }
        $line = [Math]::Max(0, [Math]::Min([int]$State.Line, $lines.Count - 1))
        $Ed.Caret = @{ Line = $line; Col = [Math]::Max(0, [Math]::Min([int]$State.Col, $lines[$line].Length)) }
        if ($Ed.Mode -eq 'source') {
            $nl = if ($Ed.Source.Text.Contains("`r`n")) { 2 } else { 1 }
            $idx = 0
            for ($i = 0; $i -lt $line; $i++) { $idx += $lines[$i].Length + $nl }
            $Ed.Source.CaretIndex = $idx + $Ed.Caret.Col
        }
    }
    $target = if ($Ed.Mode -eq 'live') { $Ed.Live } elseif ($Ed.Mode -eq 'read') { $Ed.View } else { $Ed.Source }
    $scroll = [double]$State.Scroll
    if ($Ed.Mode -eq 'live') {
        # 긴 글은 나눠 그리는 중일 수 있다. 커서 단위까지, 그리고 스크롤할 높이가 생길 때까지 먼저 그린다
        Complete-WtMemoRender $Ed (Find-WtMemoUnitIndex $Ed $Ed.Caret.Line)
        $sv = Get-WtMemoScroller $target
        $target.UpdateLayout()
        while ($sv -and $Ed.Rendered -lt $Ed.Units.Count -and $sv.ExtentHeight -lt $scroll + $sv.ViewportHeight) {
            Complete-WtMemoRender $Ed ($Ed.Rendered + 20)
            $target.UpdateLayout()
        }
        # 포커스가 보기에 있으면(탭을 바꾸며 불러옴) 커서 자리에 섬을 다시 연다
        if ($Ed.Live.IsKeyboardFocused -and -not $Ed.Island) { Open-WtMemoIslandAt $Ed $Ed.Caret.Line $Ed.Caret.Col }
    } else {
        $target.UpdateLayout()
    }
    $sv = Get-WtMemoScroller $target
    if ($sv) { $sv.ScrollToVerticalOffset($scroll) }
}

# 텍스트 상자 · 보기 안쪽의 ScrollViewer
function Get-WtMemoScroller($El) {
    if (-not $El) { return $null }
    $El.ApplyTemplate() | Out-Null
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue($El)
    while ($queue.Count) {
        $x = $queue.Dequeue()
        if ($x -is [System.Windows.Controls.ScrollViewer]) { return $x }
        $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($x)
        for ($i = 0; $i -lt $n; $i++) { $queue.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($x, $i)) }
    }
    $null
}

# ---- 실시간: 그리기 ----------------------------------------------------------------------------

# 문서의 약속: Blocks = Sections[0 .. Rendered-1] 차례. 단, 섬이 열려 있으면 섬이 덮은 단위(First..Last) 자리에 섬 하나.
# 긴 글은 앞쪽만 바로 그리고 나머지는 입력을 막지 않게 조금씩 뒤에 붙인다(Rendered가 Units.Count까지 자람).
$script:firstPaint = [TimeSpan]::FromMilliseconds(60)   # 처음에 바로 그릴 시간
$script:renderSlice = [TimeSpan]::FromMilliseconds(16)  # 뒤에 붙일 때 한 번에 쓸 시간

# 줄 목록 전체를 단위로 다시 나눠 문서를 새로 꾸린다 (불러오기 · 실행 취소 · 울타리가 어긋났을 때)
function Update-WtMemoLive($Ed) {
    $text = @($Ed.Lines) -join "`n"
    $units = Get-WtMarkdownUnits $text
    Set-WtMemoListIds $Ed $units 0 ($units.Count - 1)
    $Ed.Live.Document.Blocks.Clear()
    $Ed.Units = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $units) { $Ed.Units.Add($u) }
    $Ed.Sections = [System.Collections.Generic.List[object]]::new()
    foreach ($u in $units) { $Ed.Sections.Add($null) }
    $Ed.Rendered = 0
    if ($Ed.Cache.Count -gt 4 * [Math]::Max(64, $units.Count)) { $Ed.Cache.Clear() }
    $deadline = [datetime]::UtcNow + $script:firstPaint
    while ($Ed.Rendered -lt $units.Count -and [datetime]::UtcNow -lt $deadline) { Add-WtMemoNextSection $Ed }
    Start-WtMemoRenderTimer $Ed
}

# 목록 번호(ListId)를 새로 매긴다: 차례로 이어진 목록 항목 단위는 같은 목록. 마지막 항목만 아래 여백(Last).
# From..To를 매기고, To 뒤에도 같은 목록이 이어지면 그 끝까지 번호를 잇는다
function Set-WtMemoListIds($Ed, $Units, [int]$From, [int]$To) {
    $id = 0
    if ($From -gt 0 -and $Units[$From - 1].Kind -eq 'list-item') { $id = $Units[$From - 1].ListId }
    $i = $From
    while ($i -lt $Units.Count -and ($i -le $To -or ($id -and $Units[$i].Kind -eq 'list-item' -and $Units[$i].ListId -ne $id))) {
        $u = $Units[$i]
        if ($u.Kind -ne 'list-item') { $id = 0 }
        else {
            if (-not $id) { $id = $Ed.NextListId; $Ed.NextListId++ }
            $u.ListId = $id
            $u.Last = -not ($i + 1 -lt $Units.Count -and $Units[$i + 1].Kind -eq 'list-item')
        }
        $i++
    }
}

# 단위 하나의 Section. 원문 · 깊이 · 여백이 같은 Section이 쉬고 있으면 다시 쓴다
function Get-WtMemoUnitSection($Ed, $Unit) {
    $key = '{0}|{1}|{2}|{3}' -f $Unit.Kind, $Unit.Depth, $Unit.Last, $Unit.Text
    $sec = $null
    if ($Ed.Cache.TryGetValue($key, [ref]$sec) -and -not $sec.Parent) { $sec.Tag = $Unit; return $sec }
    $sec = New-WtMarkdownUnitSection $Ed.Live $Unit
    $Ed.Cache[$key] = $sec
    # 다이어그램 크기를 다시 재는 것은 편집기가 직접 한다 (보기 공통 처리기가 문서를 통째로 바꾸지 않게)
    $Ed.Live.Tag.Remeasure = $false
    $sec
}

# 아직 안 그린 다음 단위를 문서 끝에 붙인다
function Add-WtMemoNextSection($Ed) {
    $i = $Ed.Rendered
    $sec = Get-WtMemoUnitSection $Ed $Ed.Units[$i]
    $Ed.Sections[$i] = $sec
    $Ed.Live.Document.Blocks.Add($sec)
    $Ed.Rendered = $i + 1
}

# 단위 번호 Index까지는 바로 그린다 (그 자리로 섬을 열 때)
function Complete-WtMemoRender($Ed, [int]$Index) {
    $Index = [Math]::Min($Index, $Ed.Units.Count - 1)
    while ($Ed.Rendered -le $Index) { Add-WtMemoNextSection $Ed }
}

function Start-WtMemoRenderTimer($Ed) {
    if ($Ed.Rendered -ge $Ed.Units.Count) { return }
    if (-not $Ed.RenderTimer) {
        $t = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Background)
        $t.Interval = [TimeSpan]::Zero
        $t.Tag = $Ed
        $t.Add_Tick({
                param($s, $e)
                $ed = $s.Tag
                try {
                    $deadline = [datetime]::UtcNow + $script:renderSlice
                    while ($ed.Rendered -lt $ed.Units.Count -and [datetime]::UtcNow -lt $deadline) { Add-WtMemoNextSection $ed }
                } catch { $s.Stop(); Show-WtError $_ '메모 그리기'; return }
                if ($ed.Rendered -ge $ed.Units.Count) { $s.Stop() }
            })
        $Ed.RenderTimer = $t
    }
    $Ed.RenderTimer.Start()
}

# 줄 번호가 든 단위 번호. 없으면 바로 앞 단위(들어갈 자리), 맨 앞이면 -1.
# 단위는 Start 차례이고 겹치지 않으므로 둘로 나눠 찾는다 (긴 글에서 키마다 훑지 않게)
function Find-WtMemoUnitIndex($Ed, [int]$Line) {
    Get-WtMemoUnitBefore $Ed ($Line + 1) -Start
}

# Start(-Start) 또는 End가 Line 이하인 마지막 단위 번호. 없으면 -1
function Get-WtMemoUnitBefore($Ed, [int]$Line, [switch]$Start) {
    $units = $Ed.Units
    $lo = 0; $hi = $units.Count - 1; $ans = -1
    while ($lo -le $hi) {
        $mid = [int][Math]::Floor(($lo + $hi) / 2)
        $v = if ($Start) { $units[$mid].Start } else { $units[$mid].End }
        if ($v -le $Line - $(if ($Start) { 1 } else { 0 })) { $ans = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    $ans
}

# Start가 Line 이상인 첫 단위 번호. 없으면 Units.Count
function Get-WtMemoUnitAfter($Ed, [int]$Line) {
    $units = $Ed.Units
    $lo = 0; $hi = $units.Count - 1; $ans = $units.Count
    while ($lo -le $hi) {
        $mid = [int][Math]::Floor(($lo + $hi) / 2)
        if ($units[$mid].Start -ge $Line) { $ans = $mid; $hi = $mid - 1 } else { $lo = $mid + 1 }
    }
    $ans
}

# ---- 실시간: 섬 --------------------------------------------------------------------------------

# 줄 · 칸 자리에 섬을 연다. 그 줄이 든 단위 전체(빈 줄이면 앞 단위)를 섬으로 바꾼다
function Open-WtMemoIslandAt($Ed, [int]$Line, [int]$Col, [int]$ToLine = -1, [int]$ToCol = -1) {
    # 줄 번호는 섬을 닫은 뒤 기준이다. 먼저 닫아야 단위 목록이 맞는다
    if ($Ed.Island) {
        $Ed.Busy++
        try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    }
    $Line = [Math]::Max(0, [Math]::Min($Line, $Ed.Lines.Count - 1))
    $from = $Line; $to = $Line
    if ($ToLine -ge 0) { $from = [Math]::Min($Line, $ToLine); $to = [Math]::Max($Line, $ToLine) }
    $range = Get-WtMemoUnitRange $Ed $from $to
    Open-WtMemoIsland $Ed $range[0] $range[1] $Line $Col $ToLine $ToCol
}

# [from, to] 줄을 덮는 단위들의 줄 범위 [Start, End)
function Get-WtMemoUnitRange($Ed, [int]$From, [int]$To) {
    $units = $Ed.Units
    if (-not $units.Count) { return @(0, $Ed.Lines.Count) }
    $a = Find-WtMemoUnitIndex $Ed $From
    $b = Find-WtMemoUnitIndex $Ed $To
    if ($a -lt 0) { $a = 0 }
    if ($b -lt 0) { $b = 0 }
    $start = [Math]::Min($units[$a].Start, $From)
    $end = [Math]::Max($units[$b].End, $To + 1)
    # 빈 줄에 섰으면 앞 단위에 붙인다 (빈 줄만 따로 섬이 되지 않게)
    @($start, [Math]::Min($end, $Ed.Lines.Count))
}

function Open-WtMemoIsland($Ed, [int]$Start, [int]$End, [int]$Line, [int]$Col, [int]$ToLine = -1, [int]$ToCol = -1) {
    if ($Ed.Island) { Close-WtMemoIsland $Ed }
    $Ed.Busy++
    try {
        $doc = $Ed.Live.Document
        $units = $Ed.Units
        # 섬이 덮는 단위(First..Last)의 Section을 빼고 그 자리에 섬을 넣는다. 덮는 단위가 없으면 Last = First - 1
        $first = (Get-WtMemoUnitBefore $Ed $Start) + 1          # End가 Start 이하인 단위 다음
        $last = (Get-WtMemoUnitAfter $Ed $End) - 1              # Start가 End 이상인 단위 앞
        # 단위 일부만 덮으면 나머지 줄이 화면에서 사라지므로 덮는 단위 전체로 넓힌다
        if ($last -ge $first) {
            $Start = [Math]::Min($Start, $units[$first].Start)
            $End = [Math]::Max($End, $units[$last].End)
        }
        Complete-WtMemoRender $Ed ($last + 1)
        $covered = [System.Collections.Generic.List[object]]::new()
        for ($i = $first; $i -le $last; $i++) {
            $covered.Add($units[$i])
            [void]$doc.Blocks.Remove($Ed.Sections[$i])
        }
        $box = $Ed.IslandBox
        $holder = [System.Windows.Documents.BlockUIContainer]::new()
        Set-WtStyle $holder 'Memo.IslandBox'
        Set-WtStyle $box (Get-WtMemoIslandStyle $covered)
        if ($box.Parent) { $box.Parent.Child = $null }
        $holder.Child = $box
        if ($last + 1 -lt $Ed.Rendered) { $doc.Blocks.InsertBefore($Ed.Sections[$last + 1], $holder) } else { $doc.Blocks.Add($holder) }

        $Ed.Loading = $true
        try { $box.Text = (@($Ed.Lines.GetRange($Start, $End - $Start)) -join "`r`n") } finally { $Ed.Loading = $false }
        $Ed.IslandPrev = $box.Text
        $Ed.Island = @{ Start = $Start; End = $End; Holder = $holder; Original = $box.Text; First = $first; Last = $last }
        $caret = Get-WtMemoIslandIndex $Ed $Line $Col
        if ($ToLine -ge 0) {
            $to = Get-WtMemoIslandIndex $Ed $ToLine $ToCol
            # 거꾸로 고르기는 줄 이동 명령을 쓰므로 배치가 끝나 있어야 한다 (앞 → 뒤는 배치 없이 고른다)
            if ($to -lt $caret) { $Ed.Live.UpdateLayout() }
            Select-WtMemoIslandRange $box $caret $to
        } else {
            $box.Select($caret, 0)
        }
        [void]$box.Focus()
        # 커서를 화면 안으로: 배치가 끝난 뒤에 한다 (여기서 배치를 강제하면 블록을 옮길 때마다 느리다)
        $script:caretPending = $Ed
        [void]$box.Dispatcher.BeginInvoke([System.Action] { if ($script:caretPending) { Show-WtMemoIslandCaret $script:caretPending; $script:caretPending = $null } }, [System.Windows.Threading.DispatcherPriority]::Loaded)
    } finally { $Ed.Busy-- }
}

# 선택을 anchor → active 방향으로 (이어서 Shift+화살표를 누르면 active 쪽이 움직이게).
# TextBox.Select는 늘 앞 → 뒤 방향이라, 거꾸로 고를 때는 anchor에 커서를 두고 선택 명령으로 넓힌다
function Select-WtMemoIslandRange($Box, [int]$Anchor, [int]$Active) {
    if ($Active -ge $Anchor) { $Box.Select($Anchor, $Active - $Anchor); return }
    $Box.Select($Anchor, 0)
    $cmds = [System.Windows.Documents.EditingCommands]
    for ($n = 0; $n -lt 100000 -and $Box.SelectionStart -gt $Active; $n++) {
        $was = $Box.SelectionStart
        $cmds::SelectUpByLine.Execute($null, $Box)
        if ($Box.SelectionStart -eq $was) { break }
    }
    for ($n = 0; $n -lt 100000 -and $Box.SelectionStart -gt $Active; $n++) {
        $was = $Box.SelectionStart
        $cmds::SelectLeftByCharacter.Execute($null, $Box)
        if ($Box.SelectionStart -eq $was) { break }
    }
    for ($n = 0; $n -lt 100000 -and $Box.SelectionStart -lt $Active -and $Box.SelectionLength; $n++) {
        $was = $Box.SelectionStart
        $cmds::SelectRightByCharacter.Execute($null, $Box)
        if ($Box.SelectionStart -eq $was) { break }
    }
}

# 섬 글꼴: 제목 하나면 그 단계 크기, 코드 블록 하나면 코드 글꼴, 그 밖에는 본문
function Get-WtMemoIslandStyle($Units) {
    if (@($Units).Count -eq 1) {
        $u = @($Units)[0]
        if ($u.Kind -eq 'heading') {
            $level = if ($u.Text -match '^\s{0,3}(#{1,6})(\s|$)') { $Matches[1].Length } elseif ($u.Text -match '\n\s*=+\s*$') { 1 } else { 2 }
            return "Memo.IslandH$level"
        }
        if ($u.Kind -eq 'code') { return 'Memo.IslandCode' }
    }
    'Memo.Island'
}

# 줄 · 칸 → 섬 글자 위치 (섬 글은 \r\n)
function Get-WtMemoIslandIndex($Ed, [int]$Line, [int]$Col) {
    $isl = $Ed.Island
    $lines = @($Ed.IslandBox.Text -split "\r?\n")
    $rel = [Math]::Max(0, [Math]::Min($Line - $isl.Start, $lines.Count - 1))
    $idx = 0
    for ($i = 0; $i -lt $rel; $i++) { $idx += $lines[$i].Length + 2 }
    $idx + [Math]::Max(0, [Math]::Min($Col, $lines[$rel].Length))
}

# 섬 글자 위치 → 줄 · 칸 (글 전체 기준)
function Get-WtMemoIslandCaret($Ed, [int]$Index = -1) {
    $box = $Ed.IslandBox
    if ($Index -lt 0) { $Index = $box.CaretIndex }
    $before = $box.Text.Substring(0, [Math]::Min($Index, $box.Text.Length))
    $parts = @($before -split "\r?\n")
    @{ Line = $Ed.Island.Start + $parts.Count - 1; Col = $parts[-1].Length }
}

# 섬을 닫는다: 안 고쳤으면 그려 둔 Section을 그 자리에 돌려놓고, 고쳤으면 줄을 되돌려 넣고 그 둘레만 다시 나눠 그린다
function Close-WtMemoIsland($Ed, [switch]$NoRender) {
    $isl = $Ed.Island
    if (-not $isl) { return }
    $box = $Ed.IslandBox
    $Ed.Caret = Get-WtMemoIslandCaret $Ed
    $Ed.Busy++
    try {
        $text = $box.Text
        $doc = $Ed.Live.Document
        $Ed.Island = $null
        # 섬 다음 블록을 기억해 두고 섬을 뺀다 (그 앞에 다시 넣는다)
        $after = $isl.Holder.NextBlock
        [void]$doc.Blocks.Remove($isl.Holder)
        $isl.Holder.Child = $null
        if ($text -ceq $isl.Original) {
            if ($NoRender) { return }
            for ($i = $isl.First; $i -le $isl.Last; $i++) {
                if ($after) { $doc.Blocks.InsertBefore($after, $Ed.Sections[$i]) } else { $doc.Blocks.Add($Ed.Sections[$i]) }
            }
            return
        }
        $new = @($text -split "\r?\n")
        $oldCount = $isl.End - $isl.Start
        $Ed.Lines.RemoveRange($isl.Start, $oldCount)
        $Ed.Lines.InsertRange($isl.Start, [string[]]$new)
        if ($NoRender) { return }
        Update-WtMemoRegion $Ed $isl $new.Count $after
    } finally { $Ed.Busy-- }
}

function Get-WtMemoWideMarks([string]$Text) {
    '{0}|{1}|{2}' -f ([regex]::Matches($Text, '<!--').Count), ([regex]::Matches($Text, '-->').Count), ([regex]::Matches($Text, '(?m)^\s*\$\$').Count)
}

# 고친 섬 둘레만 다시 나눈다. 같이 다시 나누는 이웃(문맥에 따라 모양이 바뀔 수 있어서):
#   빈 줄 없이 붙은 단위, 같은 목록(ListId)의 항목, 들여 쓴 줄로 시작하는 쪽의 앞 단위
# 코드 울타리 줄이 하나라도 바뀌면(짝 · 길이 · 글자) 아래 전체가 달라질 수 있으므로 전체를 다시 나눈다
function Update-WtMemoRegion($Ed, $Isl, [int]$NewCount, $After) {
    $units = $Ed.Units
    $delta = $NewCount - ($Isl.End - $Isl.Start)
    $islText = @($Ed.Lines.GetRange($Isl.Start, $NewCount))
    $oldText = $Isl.Original -split "\r?\n"
    $fence = '^\s{0,3}(```|~~~)'
    $fenceOld = @($oldText | Where-Object { $_ -match $fence } | ForEach-Object { $_.Trim() }) -join "`n"
    $fenceNew = @($islText | Where-Object { $_ -match $fence } | ForEach-Object { $_.Trim() }) -join "`n"
    # 아래 글 전체의 뜻을 바꿀 수 있는 것: HTML 주석 열고 닫기(<!-- -->), 수식 블록($$)
    $wideOld = Get-WtMemoWideMarks ($oldText -join "`n")
    $wideNew = Get-WtMemoWideMarks ($islText -join "`n")
    if ($fenceOld -cne $fenceNew -or $wideOld -cne $wideNew -or -not $units.Count) {
        # 섬 다음 블록부터 끝까지 이미 문서에 있으니 전체를 새로 꾸린다
        Update-WtMemoLive $Ed
        return
    }
    $a = $Isl.First; $b = $Isl.Last
    $rs = $Isl.Start; $re = $Isl.Start + $NewCount
    $listy = '^\s*([-*+]|\d{1,9}[.)])(\s|$)'
    $hasList = @($islText | Where-Object { $_ -match $listy }).Count -gt 0
    for ($i = $a; $i -le $b; $i++) { if ($units[$i].Kind -eq 'list-item') { $hasList = $true } }
    do {
        $grew = $false
        if ($a -gt 0) {
            $p = $units[$a - 1]
            $cur = if ($a -le $b) { $units[$a] } else { $null }
            $sameList = $p.Kind -eq 'list-item' -and $hasList -and (-not $cur -or ($cur.Kind -eq 'list-item' -and $cur.ListId -eq $p.ListId))
            # 영역 첫 글 줄이 들여 써 있으면 앞 단위에 따라 뜻이 바뀐다(목록 이어 쓰기 · 코드)
            $firstText = $null
            for ($l = $rs; $l -lt $re; $l++) { if ($Ed.Lines[$l].Trim()) { $firstText = $Ed.Lines[$l]; break } }
            $indented = $firstText -and $firstText -match '^\s'
            # 목록 표지로 시작하면(빈 항목 '1. ' 등) 앞 글에 따라 목록 · 문단이 갈리므로 앞 단위를 하나 같이 본다
            $listStart = $firstText -and $firstText -match $listy -and $p.Kind -ne 'list-item'
            if ($p.End -eq $rs -or $sameList -or $indented -or $listStart) {
                $a--; $rs = $p.Start; $grew = $true
                if ($p.Kind -eq 'list-item') { $hasList = $true }
            }
        }
        if ($b + 1 -lt $units.Count) {
            $n = $units[$b + 1]
            $cur = if ($a -le $b) { $units[$b] } else { $null }
            $sameList = $n.Kind -eq 'list-item' -and $hasList -and (-not $cur -or ($cur.Kind -eq 'list-item' -and $cur.ListId -eq $n.ListId))
            $nStart = $n.Start + $delta
            $indented = $Ed.Lines[$nStart] -match '^\s'
            if ($nStart -eq $re -or $sameList -or $indented) {
                Complete-WtMemoRender $Ed ($b + 1)
                $b++; $re = $n.End + $delta; $grew = $true
                if ($n.Kind -eq 'list-item') { $hasList = $true }
            }
        }
    } while ($grew)
    $rs = [Math]::Min($rs, $Isl.Start)
    $re = [Math]::Max($re, $Isl.Start + $NewCount)

    $doc = $Ed.Live.Document
    # 다시 나눌 단위의 Section 빼기 (섬이 덮었던 First..Last는 이미 빠져 있음)
    for ($i = $a; $i -le $b; $i++) {
        if ($i -ge $Isl.First -and $i -le $Isl.Last) { continue }
        $sec = $Ed.Sections[$i]
        if ($sec -and $sec.Parent) {
            if ($After -eq $sec) { $After = $sec.NextBlock }
            [void]$doc.Blocks.Remove($sec)
        }
    }
    for ($i = $b + 1; $i -lt $units.Count; $i++) { $units[$i].Start += $delta; $units[$i].End += $delta }
    $region = @($Ed.Lines.GetRange($rs, $re - $rs)) -join "`n"
    $fresh = Get-WtMarkdownUnits $region -LineOffset $rs   # 배열 하나로 돌려준다 (@()로 다시 감싸지 않는다)
    if ($null -eq $fresh) { $fresh = @() }
    $removed = $b - $a + 1
    $wasRendered = $b -lt $Ed.Rendered
    $units.RemoveRange($a, $removed)
    $Ed.Sections.RemoveRange($a, $removed)
    $units.InsertRange($a, [object[]]$fresh)
    $Ed.Sections.InsertRange($a, [object[]]::new($fresh.Count))
    if ($wasRendered) { $Ed.Rendered += $fresh.Count - $removed } else { $Ed.Rendered = [Math]::Min($Ed.Rendered, $a) }
    # 목록 번호 · 마지막 표시를 앞뒤 하나씩 넓혀 다시 매긴다. 이웃의 여백이 바뀌면 다시 그린다
    $from = [Math]::Max(0, $a - 1); $to = [Math]::Min($units.Count - 1, $a + $fresh.Count)
    $before = @(for ($i = $from; $i -le $to; $i++) { $units[$i].Last })
    Set-WtMemoListIds $Ed $units $from $to
    if ($wasRendered) {
        for ($k = 0; $k -lt $fresh.Count; $k++) {
            $sec = Get-WtMemoUnitSection $Ed $fresh[$k]
            $Ed.Sections[$a + $k] = $sec
            if ($After) { $doc.Blocks.InsertBefore($After, $sec) } else { $doc.Blocks.Add($sec) }
        }
        foreach ($i in @($from, $to)) {
            if ($i -ge $a -and $i -lt $a + $fresh.Count) { continue }
            if ($i -ge $Ed.Rendered -or $units[$i].Last -eq $before[$i - $from]) { continue }
            $old = $Ed.Sections[$i]
            $sec = Get-WtMemoUnitSection $Ed $units[$i]
            $doc.Blocks.InsertBefore($old, $sec)
            [void]$doc.Blocks.Remove($old)
            $Ed.Sections[$i] = $sec
        }
    }
    Start-WtMemoRenderTimer $Ed
}

function Show-WtMemoIslandCaret($Ed) {
    $box = $Ed.IslandBox
    try {
        $r = $box.GetRectFromCharacterIndex($box.CaretIndex)
        if (-not $r.IsEmpty) { $box.BringIntoView([System.Windows.Rect]::new($r.X, $r.Y - 8, [Math]::Max(1, $r.Width), $r.Height + 16)) }
    } catch { }
}

# 섬 안의 휠: TextBox가 휠을 삼키므로 바깥 보기를 직접 굴린다
function Invoke-WtMemoIslandWheel($S, $E) {
    $ed = $S.Tag
    $sv = Get-WtMemoScroller $ed.Live
    if (-not $sv) { return }
    $E.Handled = $true
    $sv.ScrollToVerticalOffset($sv.VerticalOffset - $E.Delta / 120 * 48)
}

# [Start, End) 줄 범위의 앞(Up) · 뒤(Down) 단위. 없으면 $null
function Get-WtMemoNeighbor($Ed, [int]$Start, [int]$End, [string]$Dir) {
    if ($Dir -eq 'Up') {
        $i = Get-WtMemoUnitBefore $Ed $Start
        if ($i -ge 0) { return $Ed.Units[$i] }
        return $null
    }
    $i = Get-WtMemoUnitAfter $Ed $End
    if ($i -lt $Ed.Units.Count) { return $Ed.Units[$i] }
    $null
}

# 섬 위아래 단위로 옮긴다. Up이면 앞 단위의 마지막 줄, 아니면 다음 단위의 첫 줄. 칸은 지금 칸을 지킨다
function Move-WtMemoIsland($Ed, [ValidateSet('Up', 'Down', 'Left', 'Right', 'Home', 'End')][string]$Dir, [switch]$Extend) {
    $box = $Ed.IslandBox
    $isl = $Ed.Island
    $caret = Get-WtMemoIslandCaret $Ed
    $islLines = @($box.Text -split "\r?\n").Count
    $start = $isl.Start
    $end = $start + $islLines
    if ($Extend) {
        # 선택을 넓힌다: 섬을 옆 단위까지 키우고, 고정된 끝(anchor)에서 옆 단위의 같은 칸까지 고른다
        $selStart = $box.SelectionStart
        $selEnd = $selStart + $box.SelectionLength
        $anchor = Get-WtMemoIslandCaret $Ed $(if ($Dir -eq 'Up') { $selEnd } else { $selStart })
        $active = Get-WtMemoIslandCaret $Ed $(if ($Dir -eq 'Up') { $selStart } else { $selEnd })
        $Ed.Busy++
        try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
        $side = Get-WtMemoNeighbor $Ed $start $end $Dir
        if (-not $side) {
            # 더 갈 단위가 없으면 글 처음 · 끝까지
            $toLine = if ($Dir -eq 'Up') { $start } else { $end - 1 }
            $toCol = if ($Dir -eq 'Up') { 0 } else { $Ed.Lines[$toLine].Length }
            Open-WtMemoIsland $Ed $start $end $anchor.Line $anchor.Col $toLine $toCol
            return $true
        }
        $toLine = if ($Dir -eq 'Up') { $side.End - 1 } else { $side.Start }
        $range = Get-WtMemoUnitRange $Ed ([Math]::Min($start, $side.Start)) ([Math]::Max($end - 1, $side.End - 1))
        Open-WtMemoIsland $Ed $range[0] $range[1] $anchor.Line $anchor.Col $toLine $active.Col
        return $true
    }
    $Ed.Busy++
    try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    $units = $Ed.Units
    if (-not $units.Count) { Open-WtMemoIslandAt $Ed 0 0; return $true }
    switch ($Dir) {
        'Up' {
            $prev = Get-WtMemoNeighbor $Ed $start $end 'Up'
            if (-not $prev) { Open-WtMemoIslandAt $Ed $start 0; return $true }
            Open-WtMemoIsland $Ed $prev.Start $prev.End ($prev.End - 1) $caret.Col
        }
        'Down' {
            $next = Get-WtMemoNeighbor $Ed $start $end 'Down'
            if (-not $next) { $l = $end - 1; Open-WtMemoIslandAt $Ed $l $Ed.Lines[$l].Length; return $true }
            Open-WtMemoIsland $Ed $next.Start $next.End $next.Start $caret.Col
        }
        'Left' {
            $prev = Get-WtMemoNeighbor $Ed $start $end 'Up'
            if (-not $prev) { Open-WtMemoIslandAt $Ed $start 0; return $true }
            Open-WtMemoIsland $Ed $prev.Start $prev.End ($prev.End - 1) $Ed.Lines[$prev.End - 1].Length
        }
        'Right' {
            $next = Get-WtMemoNeighbor $Ed $start $end 'Down'
            if (-not $next) { $l = $end - 1; Open-WtMemoIslandAt $Ed $l $Ed.Lines[$l].Length; return $true }
            Open-WtMemoIsland $Ed $next.Start $next.End $next.Start 0
        }
        'Home' { $u = $units[0]; Open-WtMemoIsland $Ed $u.Start $u.End $u.Start 0 }
        'End' { $u = $units[$units.Count - 1]; Complete-WtMemoRender $Ed ($units.Count - 1); Open-WtMemoIsland $Ed $u.Start $u.End ($u.End - 1) $Ed.Lines[$u.End - 1].Length }
    }
    $true
}

# 섬을 앞(또는 뒤) 단위까지 넓히고 커서는 그대로 둔다 (지우기로 블록을 이을 때)
function Join-WtMemoIsland($Ed, [switch]$Next) {
    $isl = $Ed.Island
    $box = $Ed.IslandBox
    $caret = Get-WtMemoIslandCaret $Ed
    $islEnd = $isl.Start + @($box.Text -split "\r?\n").Count
    $Ed.Busy++
    try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    if ($Next) {
        $n = Get-WtMemoNeighbor $Ed $isl.Start $islEnd 'Down'
        $endLine = if ($n) { $n.End } else { $Ed.Lines.Count }
        $range = Get-WtMemoUnitRange $Ed $caret.Line ([Math]::Max($caret.Line, $endLine - 1))
    } else {
        $p = Get-WtMemoNeighbor $Ed $caret.Line $caret.Line 'Up'
        $from = if ($p) { $p.Start } else { 0 }
        $range = Get-WtMemoUnitRange $Ed $from $caret.Line
    }
    Open-WtMemoIsland $Ed $range[0] $range[1] $caret.Line $caret.Col
}

# ---- 실시간: 키 -------------------------------------------------------------------------------

# 글자 위치가 든 화면 줄(줄바꿈 포함 · 접힌 줄 기준). 섬을 막 열어 배치 전이면 -1이 나오므로 그때만 배치를 맞춘다
function Get-WtMemoBoxLine($Box, [int]$Index) {
    $l = $Box.GetLineIndexFromCharacterIndex($Index)
    if ($l -lt 0 -or $Box.LineCount -lt 0) { $Box.UpdateLayout(); $l = $Box.GetLineIndexFromCharacterIndex($Index) }
    $l
}

function Invoke-WtMemoIslandKey($S, $E) {
    $ed = $S.Tag
    if (-not $ed.Island -or $E.Handled) { return }
    $key = Get-WtMemoKey $E
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band 'Control') -ne 0
    $shift = ($mods -band 'Shift') -ne 0
    $alt = ($mods -band 'Alt') -ne 0
    $box = $S
    $len = $box.Text.Length
    $caret = $box.CaretIndex
    $noSel = $box.SelectionLength -eq 0
    try {
        # 한글 조합 중에 누른 ↑↓: 입력기가 글자를 확정한 뒤에, 커서가 그대로면(블록 끝이면) 옆 블록으로 간다
        if ($E.Key -eq 'ImeProcessed') {
            if ($key -in 'Up', 'Down' -and -not $ctrl -and -not $alt -and -not $shift) { Add-WtMemoImePending $box $(if ($key -eq 'Up') { 'up' } else { 'down' }) }
            return
        }
        switch ($key) {
            'Up' {
                if ($alt -or $ctrl) { return }
                $first = (Get-WtMemoBoxLine $box $caret) -le 0
                if ($first) { $E.Handled = Move-WtMemoIsland $ed Up -Extend:$shift }
            }
            'Down' {
                if ($alt -or $ctrl) { return }
                $at = Get-WtMemoBoxLine $box ($caret + $(if ($shift) { $box.SelectionLength } else { 0 }))
                $last = $at -ge $box.LineCount - 1
                if ($last) { $E.Handled = Move-WtMemoIsland $ed Down -Extend:$shift }
            }
            'Left' { if (-not $shift -and -not $ctrl -and $noSel -and $caret -eq 0) { $E.Handled = Move-WtMemoIsland $ed Left } }
            'Right' { if (-not $shift -and -not $ctrl -and $noSel -and $caret -eq $len) { $E.Handled = Move-WtMemoIsland $ed Right } }
            'Home' { if ($ctrl -and -not $shift) { $E.Handled = Move-WtMemoIsland $ed Home } }
            'End' { if ($ctrl -and -not $shift) { $E.Handled = Move-WtMemoIsland $ed End } }
            # Key.PageUp · PageDown은 Prior · Next와 같은 값이라 글자로는 Prior · Next로 나온다
            { $_ -in 'Prior', 'PageUp' } { $E.Handled = Move-WtMemoIslandPage $ed -1 }
            { $_ -in 'Next', 'PageDown' } { $E.Handled = Move-WtMemoIslandPage $ed 1 }
            'Back' {
                if ($noSel -and $caret -eq 0 -and -not $ctrl -and $ed.Island.Start -gt 0) {
                    Push-WtMemoUndo $ed
                    Join-WtMemoIsland $ed
                    # 이은 자리에서 지우기를 한 번 한다
                    $b = $ed.IslandBox
                    $i = $b.CaretIndex
                    if ($i -gt 0) {
                        $cut = if ($i -ge 2 -and $b.Text.Substring($i - 2, 2) -eq "`r`n") { 2 } else { 1 }
                        $b.Select($i - $cut, $cut)
                        $b.SelectedText = ''
                        $b.Select($i - $cut, 0)
                    }
                    $E.Handled = $true
                }
            }
            'Delete' {
                # 섬 뒤에 줄이 남아 있을 때만 잇는다 (섬을 닫기 전 번호끼리 비교)
                if ($noSel -and $caret -eq $len -and -not $ctrl -and $ed.Island.End -lt $ed.Lines.Count) {
                    Push-WtMemoUndo $ed
                    Join-WtMemoIsland $ed -Next
                    $b = $ed.IslandBox
                    $i = $b.CaretIndex
                    if ($i -lt $b.Text.Length) {
                        $cut = if ($b.Text.Length - $i -ge 2 -and $b.Text.Substring($i, 2) -eq "`r`n") { 2 } else { 1 }
                        $b.Select($i, $cut)
                        $b.SelectedText = ''
                        $b.Select($i, 0)
                    }
                    $E.Handled = $true
                }
            }
            'A' {
                if ($ctrl -and -not $shift -and -not $alt) {
                    # 모두 선택: 섬을 글 전체로 넓힌다
                    $ed.Busy++
                    try { Close-WtMemoIsland $ed } finally { $ed.Busy-- }
                    $last = $ed.Lines.Count - 1
                    Open-WtMemoIsland $ed 0 $ed.Lines.Count 0 0 $last $ed.Lines[$last].Length
                    $E.Handled = $true
                }
            }
            'Z' { if ($ctrl -and -not $alt) { if ($shift) { Invoke-WtMemoRedo $ed } else { Invoke-WtMemoUndo $ed }; $E.Handled = $true } }
            'Y' { if ($ctrl -and -not $alt -and -not $shift) { Invoke-WtMemoRedo $ed; $E.Handled = $true } }
        }
    } catch { Show-WtError $_ '메모 편집' }
}

# PageUp/PageDown: 바깥 보기를 한 화면 굴리고 그 자리 단위로 섬을 옮긴다
function Move-WtMemoIslandPage($Ed, [int]$Dir) {
    $sv = Get-WtMemoScroller $Ed.Live
    if (-not $sv) { return $false }
    $box = $Ed.IslandBox
    # 섬을 연 뒤 미뤄 둔 '커서를 화면 안으로'가 아직이면 먼저 한다 (스크롤 자리가 커서 기준이어야 한 화면씩 간다)
    if ($script:caretPending) {
        $Ed.Live.UpdateLayout()
        Show-WtMemoIslandCaret $script:caretPending
        $script:caretPending = $null
        $Ed.Live.UpdateLayout()
    }
    $r = $box.GetRectFromCharacterIndex($box.CaretIndex)
    $pt = $box.TranslatePoint([System.Windows.Point]::new($r.X, $r.Y + $r.Height / 2), $Ed.Live)
    # 아래로 갈 때 아직 안 그린 단위가 있으면 한 화면 넘게 먼저 그린다
    if ($Dir -gt 0) {
        $Ed.Live.UpdateLayout()
        while ($Ed.Rendered -lt $Ed.Units.Count -and $sv.ExtentHeight -lt $sv.VerticalOffset + 2 * $sv.ViewportHeight) {
            Complete-WtMemoRender $Ed ($Ed.Rendered + 20)
            $Ed.Live.UpdateLayout()
        }
    }
    $was = $sv.VerticalOffset
    $sv.ScrollToVerticalOffset($was + $Dir * $sv.ViewportHeight)
    $Ed.Live.UpdateLayout()
    # 한 화면만큼 다 못 갔으면(글 처음 · 끝에 닿음) 처음 · 끝 단위로 간다
    $edge = [Math]::Abs($sv.VerticalOffset - $was) -lt $sv.ViewportHeight - 1
    $Ed.Busy++
    try { Close-WtMemoIsland $Ed } finally { $Ed.Busy-- }
    if ($edge -and $Ed.Units.Count) {
        if ($Dir -gt 0) {
            Complete-WtMemoRender $Ed ($Ed.Units.Count - 1)
            $u = $Ed.Units[$Ed.Units.Count - 1]
            Open-WtMemoIsland $Ed $u.Start $u.End ($u.End - 1) $Ed.Lines[$u.End - 1].Length
        } else {
            $u = $Ed.Units[0]
            Open-WtMemoIsland $Ed $u.Start $u.End $u.Start 0
        }
        return $true
    }
    $Ed.Live.UpdateLayout()
    $hit = Find-WtMemoLiveHit $Ed $pt
    if ($hit) { Open-WtMemoIslandAt $Ed $hit.Line $hit.Col }
    else { Open-WtMemoIslandAt $Ed $Ed.Caret.Line $Ed.Caret.Col }
    $true
}

# ---- 실시간: 마우스 ---------------------------------------------------------------------------

# 보기 좌표 → 원문 줄 · 칸. 그린 글자를 원문과 차례로 맞춰 본다 (기호 · 아이콘은 건너뜀)
function Find-WtMemoLiveHit($Ed, [System.Windows.Point]$Point) {
    $view = $Ed.Live
    $tp = $view.GetPositionFromPoint($Point, $true)
    if (-not $tp) { return $null }
    $sec = $tp.Parent
    while ($sec -and -not ($sec -is [System.Windows.Documents.Section] -and $sec.Tag -is [hashtable] -and $sec.Tag.ContainsKey('Kind'))) {
        $sec = [System.Windows.LogicalTreeHelper]::GetParent($sec)
    }
    if (-not $sec) { return $null }
    $u = $sec.Tag
    $rendered = ''
    try { $rendered = Get-WtMemoRenderedPrefix $sec.ContentStart $tp } catch { }
    $offset = Get-WtMemoSourceOffset $rendered $u.Text
    $parts = @($u.Text.Substring(0, $offset) -split "`n")
    $line = $u.Start + $parts.Count - 1
    # 섬에서 줄 수가 바뀌었으면 섬 아래 단위의 줄 번호를 그만큼 옮긴다 (섬을 닫기 전 번호라서)
    $isl = $Ed.Island
    if ($isl -and $u.Start -ge $isl.End) { $line += @($Ed.IslandBox.Text -split "\r?\n").Count - ($isl.End - $isl.Start) }
    @{ Line = $line; Col = $parts[-1].Length; Unit = $u }
}

# 그린 글의 [Start, End) 글자. TextRange.Text는 표 칸에 걸치면 칸 · 행 전체로 넓혀 버려서 직접 따라가며 모은다.
# 문단 · 줄바꿈 · 칸 경계는 공백 문자로 둔다 (원문과 맞출 때 건너뛴다)
function Get-WtMemoRenderedPrefix($Start, $End) {
    $sb = [System.Text.StringBuilder]::new()
    $tp = $Start
    $guard = 0
    while ($tp -and $tp.CompareTo($End) -lt 0 -and $guard -lt 100000) {
        $guard++
        $ctx = $tp.GetPointerContext('Forward')
        if ($ctx -eq 'Text') {
            $run = $tp.GetTextInRun('Forward')
            $left = $tp.GetOffsetToPosition($End)
            if ($left -lt $run.Length) { [void]$sb.Append($run.Substring(0, [Math]::Max(0, $left))); break }
            [void]$sb.Append($run)
            $tp = $tp.GetPositionAtOffset($run.Length)
            continue
        }
        if ($ctx -eq 'ElementEnd' -or $ctx -eq 'EmbeddedElement') { [void]$sb.Append("`n") }
        $tp = $tp.GetNextContextPosition('Forward')
    }
    $sb.ToString()
}

function Get-WtMemoSourceOffset([string]$Rendered, [string]$Source) {
    $j = 0
    foreach ($c in $Rendered.ToCharArray()) {
        if ([char]::IsWhiteSpace($c) -or ([int]$c -ge 0xE000 -and [int]$c -le 0xF8FF)) { continue }
        $k = $Source.IndexOf($c, $j)
        if ($k -lt 0 -or $k - $j -gt 400) { continue }
        $j = $k + 1
    }
    # 그린 글이 공백 · 줄바꿈으로 끝났으면(낱말 사이 · 표 칸 · 다음 줄) 원문의 공백 · 표 칸 기호를 건너 다음 글자 앞에 둔다
    if ($Rendered.Length -and [char]::IsWhiteSpace($Rendered[$Rendered.Length - 1])) {
        while ($j -lt $Source.Length -and $Source[$j] -in ' ', "`t", '|', "`n") { $j++ }
    }
    # 줄 맨 앞이면 제목 · 목록 · 할 일 · 인용 기호 뒤(글자 앞)에 둔다
    if ($j -lt $Source.Length -and ($j -eq 0 -or $Source[$j - 1] -eq "`n")) {
        $m = [regex]::Match($Source.Substring($j), '^\s*(?:>\s?)*(?:#{1,6}\s+|[-*+]\s+(?:\[[ xX]\]\s+)?|\d{1,9}[.)]\s+(?:\[[ xX]\]\s+)?)?')
        $j += $m.Length
    }
    $j
}

function Test-WtMemoClickThrough($El, $Stop) {
    while ($El -and $El -ne $Stop) {
        if ($El -is [System.Windows.Controls.Primitives.ButtonBase] -or $El -is [System.Windows.Documents.Hyperlink] -or
            $El -is [System.Windows.Controls.Primitives.ScrollBar] -or $El -is [System.Windows.Controls.TextBox]) { return $true }
        $El = Get-WtMemoParent $El
    }
    $false
}

function Invoke-WtMemoLiveMouseDown($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or $ed.Mode -ne 'live' -or -not $ed.Enabled) { return }
    if (Test-WtMemoClickThrough $E.OriginalSource $S) { return }
    try {
        $pt = $E.GetPosition($S)
        $hit = Find-WtMemoLiveHit $ed $pt
        $shift = ([System.Windows.Input.Keyboard]::Modifiers -band 'Shift') -ne 0
        if ($shift -and $ed.Island) {
            $anchor = Get-WtMemoIslandCaret $ed $ed.IslandBox.SelectionStart
            if ($hit) { Open-WtMemoIslandAt $ed $anchor.Line $anchor.Col $hit.Line $hit.Col }
            $E.Handled = $true
            return
        }
        if (-not $hit) {
            # 글 아래 빈 곳: 끝으로
            $last = $ed.Lines.Count - 1
            $hit = @{ Line = $last; Col = $ed.Lines[$last].Length }
        }
        Open-WtMemoIslandAt $ed $hit.Line $hit.Col
        $ed.Drag = @{ Line = $hit.Line; Col = $hit.Col }
        [void]$S.CaptureMouse()
        $E.Handled = $true
    } catch { Show-WtError $_ '메모 편집' }
}

# 보기 자체에 포커스가 있을 때(섬 없음, 탭을 바꾼 직후 등) 키를 누르면 커서 자리에 섬을 연다.
# 글자 키는 섬이 포커스를 받은 뒤 입력되므로 그대로 들어간다. 이동 키는 섬만 열고 끝낸다
function Invoke-WtMemoLiveKey($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or $ed.Island -or $ed.Mode -ne 'live' -or -not $ed.Enabled -or $E.Handled) { return }
    if (-not $S.IsKeyboardFocused) { return }   # 섬 · 단추 등 안쪽 요소의 키는 그쪽이 처리한다
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    if ($mods -band ([System.Windows.Input.ModifierKeys]::Control -bor [System.Windows.Input.ModifierKeys]::Alt)) { return }
    $key = Get-WtMemoKey $E
    $skip = 'LeftShift', 'RightShift', 'LeftCtrl', 'RightCtrl', 'LeftAlt', 'RightAlt', 'LWin', 'RWin', 'Escape', 'Tab', 'Apps', 'CapsLock', 'HangulMode', 'HanjaMode'
    if ($key -in $skip -or ($key -ge [System.Windows.Input.Key]::F1 -and $key -le [System.Windows.Input.Key]::F24)) { return }
    try {
        Open-WtMemoIslandAt $ed $ed.Caret.Line $ed.Caret.Col
        if ($key -in 'Up', 'Down', 'Left', 'Right', 'Home', 'End', 'PageUp', 'PageDown') { $E.Handled = $true }
    } catch { Show-WtError $_ '메모 편집' }
}

function Invoke-WtMemoLiveMouseMove($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or -not $ed.Drag -or $E.LeftButton -ne 'Pressed' -or -not $ed.Island) { return }
    $box = $ed.IslandBox
    # 막 옮긴 섬은 배치 전이라 글자 위치를 물으면 예외가 난다. 누르면서 마우스를 잡을 때(CaptureMouse) 이동이 바로 오므로
    # 이번 것은 건너뛴다. 다음 이동 전에는 배치가 끝나 있다
    if (-not $box.IsArrangeValid) { return }
    $p = $E.GetPosition($box)
    $anchor = $ed.Drag
    if ($p.Y -ge 0 -and $p.Y -le $box.ActualHeight) {
        $i = $box.GetCharacterIndexFromPoint($p, $true)
        if ($i -ge 0) {
            $a = Get-WtMemoIslandIndex $ed $anchor.Line $anchor.Col
            Select-WtMemoIslandRange $box $a $i
        }
        return
    }
    # 섬 밖으로 끌면 그 단위까지 섬을 넓힌다
    $hit = Find-WtMemoLiveHit $ed ($E.GetPosition($S))
    if ($hit) { Open-WtMemoIslandAt $ed $anchor.Line $anchor.Col $hit.Line $hit.Col }
}

function Invoke-WtMemoLiveMouseUp($S, $E) {
    $ed = $S.Tag.Editor
    if (-not $ed -or -not $ed.Drag) { return }
    $ed.Drag = $null
    $S.ReleaseMouseCapture()
    if ($ed.Island) { [void]$ed.IslandBox.Focus() }
}

# ---- 실행 취소 (실시간 모드) ------------------------------------------------------------------

# $IslandText: 섬 글을 이것으로 보고 찍는다(고치기 전 글). 없으면 지금 글. [string]으로 받으면 $null이 ''가 되므로 형을 두지 않는다
function Get-WtMemoSnapshot($Ed, $IslandText = $null) {
    $caret = if ($Ed.Island) { Get-WtMemoIslandCaret $Ed } else { $Ed.Caret }
    $text = if ($Ed.Island -and $null -ne $IslandText) {
        $isl = $Ed.Island
        $before = if ($isl.Start -gt 0) { @($Ed.Lines.GetRange(0, $isl.Start)) } else { @() }
        $after = if ($isl.End -lt $Ed.Lines.Count) { @($Ed.Lines.GetRange($isl.End, $Ed.Lines.Count - $isl.End)) } else { @() }
        (@($before) + @($IslandText -split "\r?\n") + @($after)) -join "`n"
    } else { (Get-WtMemoEditorText $Ed).Replace("`r`n", "`n") }
    @{ Text = $text; Line = $caret.Line; Col = $caret.Col }
}

# 명령(굵게 · 붙여넣기 · 블록 잇기 …) 전에 지금 상태를 남긴다
function Push-WtMemoUndo($Ed) {
    if ($Ed.Mode -ne 'live') { return }
    Add-WtMemoUndoEntry $Ed (Get-WtMemoSnapshot $Ed)
    $Ed.LastEdit = [datetime]::MinValue
}

# 글자를 칠 때: 쉬었다 다시 치기 시작하면 고치기 전 상태를 남긴다
function Add-WtMemoTypingUndo($Ed) {
    $now = [datetime]::UtcNow
    if ($now - $Ed.LastEdit -gt $script:undoPause) { Add-WtMemoUndoEntry $Ed (Get-WtMemoSnapshot $Ed $Ed.IslandPrev) }
    $Ed.LastEdit = $now
}

function Add-WtMemoUndoEntry($Ed, $Snap) {
    if ($Ed.Undo.Count -and $Ed.Undo[$Ed.Undo.Count - 1].Text -ceq $Snap.Text) { return }
    $Ed.Undo.Add($Snap)
    if ($Ed.Undo.Count -gt $script:undoLimit) { $Ed.Undo.RemoveAt(0) }
    $Ed.Redo.Clear()
}

function Invoke-WtMemoUndo($Ed) { Restore-WtMemoSnapshot $Ed $Ed.Undo $Ed.Redo }
function Invoke-WtMemoRedo($Ed) { Restore-WtMemoSnapshot $Ed $Ed.Redo $Ed.Undo }

function Restore-WtMemoSnapshot($Ed, $From, $To) {
    $current = Get-WtMemoSnapshot $Ed
    $snap = $null
    while ($From.Count) {
        $snap = $From[$From.Count - 1]
        $From.RemoveAt($From.Count - 1)
        if ($snap.Text -cne $current.Text) { break }
        $snap = $null
    }
    if (-not $snap) { return }
    $To.Add($current)
    $Ed.Busy++
    try {
        $Ed.Island = $null
        $Ed.Loading = $true
        try { Set-WtMemoLines $Ed $snap.Text } finally { $Ed.Loading = $false }
        Update-WtMemoLive $Ed
    } finally { $Ed.Busy-- }
    $Ed.LastEdit = [datetime]::MinValue
    Open-WtMemoIslandAt $Ed $snap.Line $snap.Col
    Invoke-WtMemoEditorChanged $Ed
}

# ---- 원문 칸 · 섬 공통: 편집 명령 ----------------------------------------------------------------

function Get-WtMemoBoxState($Box) { @{ Text = $Box.Text; Start = $Box.SelectionStart; Length = $Box.SelectionLength } }

# MemoText.psm1의 편집 하나를 상자에 넣는다. 실행 취소 한 단위가 되게 한 번에 바꾼다
function Invoke-WtMemoBoxEdit($Box, $Edit) {
    if (-not $Edit) { return $false }
    $ed = $Box.Tag
    if ($Box -eq $ed.IslandBox) { Push-WtMemoUndo $ed }
    $Box.Select($Edit.Start, $Edit.Length)
    $Box.SelectedText = [string]$Edit.Insert
    $Box.Select([int]$Edit.SelStart, [int]$Edit.SelLength)
    if ($Box -eq $ed.IslandBox) { $ed.LastEdit = [datetime]::MinValue }
    $true
}

# 누른 키. Alt 조합은 SystemKey, 한글 조합 중이면(ImeProcessed) 입력기가 받은 원래 키
function Get-WtMemoKey($E) {
    if ($E.Key -eq 'System') { return $E.SystemKey }
    if ($E.Key -eq 'ImeProcessed') { return $E.ImeProcessedKey }
    $E.Key
}

# 커서 줄이 내용 없는 들여 쓴 목록 항목인지 (예: '  - ')
function Test-WtMemoEmptyItem($State) {
    if ($State.Length) { return $false }
    $t = $State.Text
    $i = $State.Start
    $ls = if ($i -gt 0) { $t.LastIndexOf("`n", $i - 1) + 1 } else { 0 }
    $le = $t.IndexOf("`n", $i)
    if ($le -lt 0) { $le = $t.Length }
    $line = $t.Substring($ls, $le - $ls).TrimEnd("`r")
    $line -match '^\s+([-*+]|\d{1,9}[.)])\s*(\[[ xX]\]\s*)?$'
}

# 한글 조합 중에 누른 키는 입력기가 먼저 처리한다. 확정이 끝난 뒤(Background)에 할 일을 남긴다
$script:imePending = $null
function Add-WtMemoImePending($Box, [string]$Kind, $Extra = $null) {
    $script:imePending = @{ Box = $Box; Kind = $Kind; Text = $Box.Text; Caret = $Box.CaretIndex; Extra = $Extra }
    [void]$Box.Dispatcher.BeginInvoke([System.Action] { Complete-WtMemoImePending }, [System.Windows.Threading.DispatcherPriority]::Background)
}

function Complete-WtMemoImePending {
    $p = $script:imePending
    $script:imePending = $null
    if (-not $p) { return }
    $box = $p.Box
    $ed = $box.Tag
    try {
        switch ($p.Kind) {
            'enter' {
                # 입력기가 줄을 바꿨으면(커서 앞이 새 줄바꿈) 그 줄바꿈을 되돌리고 목록 이어 쓰기를 한다. 안 바꿨으면 그대로 둔다
                $i = $box.CaretIndex
                if ($box.SelectionLength -or $i -lt 2 -or $box.Text.Length -le $p.Text.Length -or $box.Text.Substring($i - 2, 2) -ne "`r`n") { return }
                $state = @{ Text = $box.Text.Remove($i - 2, 2); Start = $i - 2; Length = 0 }
                $edit = Get-WtMemoEnterEdit $state
                if (-not $edit) { return }
                $box.Select($i - 2, 2)
                $box.SelectedText = ''
                $box.Select($i - 2, 0)
                [void](Invoke-WtMemoBoxEdit $box $edit)
            }
            { $_ -in 'up', 'down' } {
                # 커서가 그대로 블록 끝에 있으면 옆 블록으로
                if (-not $ed.Island -or $box -ne $ed.IslandBox -or $box.CaretIndex -ne $p.Caret) { return }
                $line = Get-WtMemoBoxLine $box $box.CaretIndex
                if ($p.Kind -eq 'up' -and $line -le 0) { [void](Move-WtMemoIsland $ed Up) }
                if ($p.Kind -eq 'down' -and $line -ge $box.LineCount - 1) { [void](Move-WtMemoIsland $ed Down) }
            }
            'suggest' {
                # 입력기가 넣은 줄바꿈 · 탭을 빼고 고른 제목으로 완성
                $i = $box.CaretIndex
                $cut = 0
                if ($i -ge 2 -and $box.Text.Substring($i - 2, 2) -eq "`r`n") { $cut = 2 } elseif ($i -ge 1 -and $box.Text[$i - 1] -eq "`t") { $cut = 1 }
                if ($cut -and $box.Text.Length -gt $p.Text.Length) { $box.Select($i - $cut, $cut); $box.SelectedText = ''; $box.Select($i - $cut, 0) }
                Complete-WtMemoSuggest $ed ([string]$p.Extra) -Target $box
            }
        }
    } catch { Show-WtError $_ '메모 편집' }
}

function Invoke-WtMemoBoxKey($S, $E) {
    if ($E.Handled) { return }
    $ed = $S.Tag
    $key = Get-WtMemoKey $E
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band 'Control') -ne 0
    $shift = ($mods -band 'Shift') -ne 0
    $alt = ($mods -band 'Alt') -ne 0
    $edit = $null
    $handled = $false
    try {
        # 한글 조합 중 Enter: 입력기가 글자를 확정하고 줄을 바꾼 뒤에 목록 이어 쓰기를 한다 (조합 중에는 글을 건드리지 않는다)
        if ($E.Key -eq 'ImeProcessed') {
            if ($key -eq 'Return' -and -not $ctrl -and -not $alt -and -not $shift) { Add-WtMemoImePending $S 'enter' }
            return
        }
        $st = Get-WtMemoBoxState $S
        if ($ctrl -and -not $alt) {
            switch ($key) {
                'B' { if (-not $shift) { $edit = Get-WtMemoWrapEdit $st '**'; $handled = $true } }
                'I' { if (-not $shift) { $edit = Get-WtMemoWrapEdit $st '*'; $handled = $true } }
                'K' { if (-not $shift) { $edit = Get-WtMemoLinkEdit $st; $handled = $true } }
                'L' { if (-not $shift) { $edit = Get-WtMemoTaskEdit $st; $handled = $true } }
                'Oem3' { if ($shift) { $edit = Get-WtMemoWrapEdit $st '`'; $handled = $true } }
                'V' { if ($shift) { Invoke-WtMemoPlainPaste $S; $handled = $true } }
            }
        } elseif ($alt -and -not $ctrl) {
            switch ($key) {
                'Up' { if (-not $shift) { $S = Expand-WtMemoIslandFor $S 'Up'; $edit = Get-WtMemoMoveLinesEdit (Get-WtMemoBoxState $S) -Up; $handled = $true } }
                'Down' { if (-not $shift) { $S = Expand-WtMemoIslandFor $S 'Down'; $edit = Get-WtMemoMoveLinesEdit (Get-WtMemoBoxState $S); $handled = $true } }
                'D5' { if ($shift) { $edit = Get-WtMemoWrapEdit $st '~~'; $handled = $true } }
            }
        } elseif (-not $ctrl -and -not $alt) {
            switch ($key) {
                'Return' {
                    if (-not $shift) {
                        # 빈 안쪽 항목에서 Enter(내어쓰기)는 부모 표지를 봐야 하므로 섬을 목록 전체로 넓힌다
                        if (Test-WtMemoEmptyItem $st) { $S = Expand-WtMemoIslandFor $S 'List'; $st = Get-WtMemoBoxState $S }
                        $edit = Get-WtMemoEnterEdit $st
                        $handled = [bool]$edit
                    }
                }
                'Tab' {
                    $S = Expand-WtMemoIslandFor $S 'List'
                    $edit = Get-WtMemoIndentEdit (Get-WtMemoBoxState $S) -Outdent:$shift
                    $handled = [bool]$edit -or $shift
                }
            }
        }
        if ($handled) {
            $E.Handled = $true
            [void](Invoke-WtMemoBoxEdit $S $edit)
        }
    } catch { Show-WtError $_ '메모 편집' }
}

# 실시간 모드에서 목록 들여쓰기 · 줄 옮기기는 옆 줄이 필요하다. 섬을 그 목록(또는 옆 단위)까지 넓히고 섬 상자를 돌려준다
function Expand-WtMemoIslandFor($Box, [string]$For) {
    $ed = $Box.Tag
    if ($Box -ne $ed.IslandBox -or -not $ed.Island) { return $Box }
    $isl = $ed.Island
    $hasList = @($ed.Units | Where-Object { $_.Kind -eq 'list-item' -and $_.Start -lt $isl.End -and $_.End -gt $isl.Start }).Count
    if ($For -eq 'List' -and -not $hasList) { return $Box }
    $sel = Get-WtMemoIslandCaret $ed $Box.SelectionStart
    $selEnd = Get-WtMemoIslandCaret $ed ($Box.SelectionStart + $Box.SelectionLength)
    $islEnd = $isl.Start + @($Box.Text -split "\r?\n").Count
    $ed.Busy++
    try { Close-WtMemoIsland $ed } finally { $ed.Busy-- }
    $units = $ed.Units
    $from = $isl.Start; $to = $islEnd - 1
    switch ($For) {
        'Up' { $p = @($units | Where-Object { $_.End -le $isl.Start }) | Select-Object -Last 1; if ($p) { $from = $p.Start } }
        'Down' { $n = @($units | Where-Object { $_.Start -ge $islEnd }) | Select-Object -First 1; if ($n) { $to = $n.End - 1 } }
        'List' {
            $mine = @($units | Where-Object { $_.Start -lt $islEnd -and $_.End -gt $isl.Start -and $_.Kind -eq 'list-item' })
            if ($mine.Count) {
                $id = $mine[0].ListId
                $same = @($units | Where-Object { $_.Kind -eq 'list-item' -and $_.ListId -eq $id })
                $from = [Math]::Min($from, ($same | Measure-Object -Property Start -Minimum).Minimum)
                $to = [Math]::Max($to, ($same | Measure-Object -Property End -Maximum).Maximum - 1)
            }
        }
    }
    $range = Get-WtMemoUnitRange $ed $from $to
    Open-WtMemoIsland $ed $range[0] $range[1] $sel.Line $sel.Col $selEnd.Line $selEnd.Col
    $ed.IslandBox
}

function Invoke-WtMemoBoxText($S, $E) {
    if ($E.Handled -or -not $E.Text) { return }
    try {
        $edit = Get-WtMemoTypeEdit (Get-WtMemoBoxState $S) $E.Text
        if ($edit) {
            $E.Handled = $true
            [void](Invoke-WtMemoBoxEdit $S $edit)
        }
    } catch { Show-WtError $_ '메모 편집' }
}

function Invoke-WtMemoBoxPaste($S, $E) {
    try {
        if (-not $E.DataObject.GetDataPresent([System.Windows.DataFormats]::UnicodeText)) { return }
        $clip = [string]$E.DataObject.GetData([System.Windows.DataFormats]::UnicodeText)
        $edit = Get-WtMemoPasteEdit (Get-WtMemoBoxState $S) $clip
        if ($edit) {
            $E.CancelCommand()
            [void](Invoke-WtMemoBoxEdit $S $edit)
        }
    } catch { Show-WtError $_ '붙여넣기' }
}

# Ctrl+Shift+V: 바꾸지 않고 글 그대로 붙여넣기
function Invoke-WtMemoPlainPaste($Box) {
    $clip = $null
    try { $clip = [System.Windows.Clipboard]::GetText() } catch { return }
    if (-not $clip) { return }
    $start = $Box.SelectionStart
    [void](Invoke-WtMemoBoxEdit $Box @{ Start = $start; Length = $Box.SelectionLength; Insert = $clip; SelStart = $start + $clip.Length; SelLength = 0 })
}

function Invoke-WtMemoBoxDragOver($S, $E) {
    if ($E.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $E.Effects = [System.Windows.DragDropEffects]::Link
        $E.Handled = $true
    }
}

# 탐색기에서 끌어 놓은 파일 · 폴더 → 링크
function Invoke-WtMemoBoxDrop($S, $E) {
    if (-not $E.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) { return }
    try {
        $paths = @($E.Data.GetData([System.Windows.DataFormats]::FileDrop))
        $i = $S.GetCharacterIndexFromPoint($E.GetPosition($S), $true)
        if ($i -ge 0) { $S.Select($i, 0) }
        $edit = Get-WtMemoDropEdit (Get-WtMemoBoxState $S) ([string[]]$paths)
        [void](Invoke-WtMemoBoxEdit $S $edit)
        $E.Handled = $true
        [void]$S.Focus()
    } catch { Show-WtError $_ '끌어 놓기' }
}

# ---- [[ 자동 완성 ------------------------------------------------------------------------------

$script:suggestMax = 30

# 커서 앞이 같은 줄의 닫히지 않은 [[ 이면 @{ Start = 찾는 글 시작; Query; Closed = 커서 뒤가 ]] }
function Get-WtMemoSuggestContext($Box) {
    if ($Box.SelectionLength) { return $null }
    $text = $Box.Text
    $i = $Box.CaretIndex
    $ls = if ($i -gt 0) { $text.LastIndexOf("`n", $i - 1) + 1 } else { 0 }
    $m = [regex]::Match($text.Substring($ls, $i - $ls), '\[\[([^\[\]\|#\r\n]*)$')
    if (-not $m.Success) { return $null }
    @{ Start = $ls + $m.Groups[1].Index; Query = $m.Groups[1].Value; Closed = $text.Substring($i).StartsWith(']]') }
}

function Update-WtMemoSuggest($Box) {
    $ed = $Box.Tag
    if (-not $ed.OnTitles -or $ed.Mode -eq 'read') { return }
    $ctx = Get-WtMemoSuggestContext $Box
    if (-not $ctx) { Hide-WtMemoSuggest $ed; return }
    $titles = @(& $ed.OnTitles $ed $ctx.Query | Where-Object { $_ })
    $q = $ctx.Query.Trim()
    $words = @($q -split '\s+' | Where-Object { $_ })
    $cmp = [StringComparison]::OrdinalIgnoreCase
    $hits = @($titles | Where-Object { $t = [string]$_; -not @($words | Where-Object { $t.IndexOf($_, $cmp) -lt 0 }).Count })
    # 앞이 맞는 제목을 먼저
    $hits = @(@($hits | Where-Object { ([string]$_).StartsWith($q, $cmp) }) + @($hits | Where-Object { -not ([string]$_).StartsWith($q, $cmp) })) |
        Select-Object -First $script:suggestMax
    if (-not @($hits).Count) { Hide-WtMemoSuggest $ed; return }
    $s = Get-WtMemoSuggestUi $ed
    $s.Box = $Box
    $s.List.ItemsSource = @($hits)
    $s.List.SelectedIndex = 0
    $r = $Box.GetRectFromCharacterIndex($ctx.Start)
    $s.Popup.PlacementTarget = $Box
    $s.Popup.HorizontalOffset = if ($r.IsEmpty) { 0 } else { $r.X }
    $s.Popup.VerticalOffset = if ($r.IsEmpty) { $Box.ActualHeight } else { $r.Bottom + 4 }
    $s.Popup.IsOpen = $true
}

function Hide-WtMemoSuggest($Ed) {
    if ($Ed.Suggest -and $Ed.Suggest.Popup.IsOpen) { $Ed.Suggest.Popup.IsOpen = $false }
}

# 자동 완성 팝업. 포커스는 입력칸에 두고(목록은 포커스를 받지 않음) ↑↓ · Enter · Tab · Esc는 입력칸이 받아 넘긴다
function Get-WtMemoSuggestUi($Ed) {
    if ($Ed.Suggest) { return $Ed.Suggest }
    $pop = [System.Windows.Controls.Primitives.Popup]::new()
    $pop.StaysOpen = $true
    $pop.Placement = 'Relative'
    $border = [System.Windows.Controls.Border]::new()
    Set-WtStyle $border 'Memo.Suggest'
    $list = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $list 'Memo.SuggestList'
    $list.Focusable = $false
    $list.Tag = $Ed
    $list.Add_PreviewMouseLeftButtonUp({
            param($s, $e)
            $item = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource)
            if (-not $item) { return }
            $e.Handled = $true
            try { Complete-WtMemoSuggest $s.Tag ([string]$item.DataContext) } catch { Show-WtError $_ '메모 링크' }
        })
    $border.Child = $list
    $pop.Child = $border
    # 팝업도 편집기 안에 두어야 테마 리소스(색 · 글꼴)를 찾는다
    [void]$Ed.Body.Children.Add($pop)
    $Ed.Suggest = @{ Popup = $pop; List = $list; Box = $null }
    $Ed.Suggest
}

function Complete-WtMemoSuggest($Ed, [string]$Title, $Target = $null) {
    $s = $Ed.Suggest
    $box = if ($Target) { $Target } else { $s.Box }
    Hide-WtMemoSuggest $Ed
    if (-not $box -or -not $Title) { return }
    $ctx = Get-WtMemoSuggestContext $box
    if (-not $ctx) { return }
    $caret = $box.CaretIndex
    $insert = if ($ctx.Closed) { $Title } else { "$Title]]" }
    [void](Invoke-WtMemoBoxEdit $box @{ Start = $ctx.Start; Length = $caret - $ctx.Start; Insert = $insert; SelStart = $ctx.Start + $Title.Length + 2; SelLength = 0 })
    [void]$box.Focus()
}

function Invoke-WtMemoSuggestKey($S, $E) {
    $ed = $S.Tag
    $sg = $ed.Suggest   # $s로 쓰면 매개변수 $S(입력칸)와 같은 변수가 된다
    if (-not $sg -or -not $sg.Popup.IsOpen -or $sg.Box -ne $S) { return }
    $list = $sg.List
    $n = $list.Items.Count
    # 한글 조합 중 Enter · Tab: 입력기가 글자를 확정한 뒤에 고른 제목으로 완성한다
    if ($E.Key -eq 'ImeProcessed') {
        if ((Get-WtMemoKey $E) -in 'Return', 'Tab' -and $list.SelectedItem) { Add-WtMemoImePending $S 'suggest' ([string]$list.SelectedItem) }
        return
    }
    switch ($E.Key) {
        'Down' { $list.SelectedIndex = ($list.SelectedIndex + 1) % $n; $list.ScrollIntoView($list.SelectedItem); $E.Handled = $true }
        'Up' { $list.SelectedIndex = ($list.SelectedIndex - 1 + $n) % $n; $list.ScrollIntoView($list.SelectedItem); $E.Handled = $true }
        { $_ -in 'Return', 'Tab' } {
            $E.Handled = $true
            try { Complete-WtMemoSuggest $ed ([string]$list.SelectedItem) } catch { Show-WtError $_ '메모 링크' }
        }
        'Escape' { Hide-WtMemoSuggest $ed; $E.Handled = $true }
    }
}

# ---- 찾기 · 바꾸기 ----------------------------------------------------------------------------

function New-WtMemoFindBar($Ed) {
    $bar = [System.Windows.Controls.Border]::new()
    Set-WtStyle $bar 'Memo.FindBar'
    $bar.Visibility = 'Collapsed'
    $rows = New-WtStack Vertical 8

    $top = [System.Windows.Controls.DockPanel]::new()
    $close = New-WtButton '' -Kind Icon -Icon 0xE711 -ToolTip '닫기 (Esc)'
    $close.Tag = $Ed
    $close.Add_Click({ param($s, $e) Close-WtMemoFind $s.Tag })
    $next = New-WtButton '' -Kind Icon -Icon 0xE74B -ToolTip '다음 찾기 (Enter · F3)'
    $next.Tag = $Ed
    $next.Add_Click({ param($s, $e) Invoke-WtMemoFind $s.Tag })
    $prev = New-WtButton '' -Kind Icon -Icon 0xE74A -ToolTip '이전 찾기 (Shift+Enter · Shift+F3)'
    $prev.Tag = $Ed
    $prev.Add_Click({ param($s, $e) Invoke-WtMemoFind $s.Tag -Back })
    $count = New-WtText '' 'T.Sub'
    $count.VerticalAlignment = 'Center'
    $count.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
    foreach ($c in $close, $next, $prev, $count) { [System.Windows.Controls.DockPanel]::SetDock($c, 'Right'); [void]$top.Children.Add($c) }
    $sb = New-WtSearchBox '찾기'
    $sb.Box.Tag = $Ed
    $sb.Box.Add_TextChanged({ param($s, $e) Invoke-WtMemoFind $s.Tag -Here })
    $sb.Box.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -ne 'Return') { return }
            $e.Handled = $true
            $back = ([System.Windows.Input.Keyboard]::Modifiers -band 'Shift') -ne 0
            Invoke-WtMemoFind $s.Tag -Back:$back
        })
    [void]$top.Children.Add($sb.Root)
    [void](Add-WtChild $rows $top)

    $low = [System.Windows.Controls.DockPanel]::new()
    $all = New-WtButton '모두 바꾸기' -ToolTip '찾은 것을 모두 바꿉니다'
    $all.Tag = $Ed
    $all.Add_Click({ param($s, $e) Invoke-WtMemoReplace $s.Tag -All })
    $one = New-WtButton '바꾸기' -ToolTip '고른 곳을 바꾸고 다음을 찾습니다 (Enter)'
    $one.Tag = $Ed
    $one.Add_Click({ param($s, $e) Invoke-WtMemoReplace $s.Tag })
    $one.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    $all.Margin = [System.Windows.Thickness]::new(8, 0, 0, 0)
    foreach ($c in $all, $one) { [System.Windows.Controls.DockPanel]::SetDock($c, 'Right'); [void]$low.Children.Add($c) }
    $rep = [System.Windows.Controls.TextBox]::new()
    Set-WtStyle $rep 'Input'
    $rep.ToolTip = '바꿀 글'
    $rep.Tag = $Ed
    $rep.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; Invoke-WtMemoReplace $s.Tag } })
    [void]$low.Children.Add($rep)
    [void](Add-WtChild $rows $low)
    $bar.Child = $rows
    $Ed.Find = @{ Bar = $bar; Query = $sb.Box; Count = $count; ReplaceRow = $low; Replace = $rep; ReadIndex = -1 }
    $bar
}

function Open-WtMemoFind($Ed, [switch]$Replace) {
    $f = $Ed.Find
    $sel = Get-WtMemoSelectedText $Ed
    $f.Bar.Visibility = 'Visible'
    $f.ReplaceRow.Visibility = if ($Replace -and $Ed.Mode -ne 'read') { 'Visible' } else { 'Collapsed' }
    if ($sel -and -not $sel.Contains("`n")) { $f.Query.Text = $sel }
    else { Update-WtMemoFindCount $Ed }
    [void]$f.Query.Focus()
    $f.Query.SelectAll()
}

function Close-WtMemoFind($Ed) {
    $Ed.Find.Bar.Visibility = 'Collapsed'
    Set-WtMemoEditorFocus $Ed
}

function Get-WtMemoSelectedText($Ed) {
    switch ($Ed.Mode) {
        'source' { return $Ed.Source.SelectedText }
        'live' { if ($Ed.Island) { return $Ed.IslandBox.SelectedText } }
        'read' { return $Ed.View.Selection.Text }
    }
    ''
}

# 글 전체(줄바꿈 \n)에서 찾은 자리들
function Get-WtMemoMatches([string]$Text, [string]$Query) {
    $out = [System.Collections.Generic.List[int]]::new()
    if (-not $Query) { return , $out }
    $i = 0
    while (($i = $Text.IndexOf($Query, $i, [StringComparison]::OrdinalIgnoreCase)) -ge 0) { $out.Add($i); $i += [Math]::Max(1, $Query.Length) }
    , $out
}

# 줄바꿈 \n 글의 위치 ↔ 줄 · 칸
function Get-WtMemoLineCol([string]$Text, [int]$Offset) {
    $before = $Text.Substring(0, [Math]::Min($Offset, $Text.Length))
    $parts = @($before -split "`n")
    @{ Line = $parts.Count - 1; Col = $parts[$parts.Count - 1].Length }
}

function Get-WtMemoOffset([string]$Text, [int]$Line, [int]$Col) {
    $off = 0
    $lines = $Text -split "`n"
    for ($i = 0; $i -lt [Math]::Min($Line, $lines.Count); $i++) { $off += $lines[$i].Length + 1 }
    $off + $Col
}

# 지금 고른 곳(또는 커서)의 시작 · 끝 위치 (줄바꿈 \n 글 기준)
function Get-WtMemoSelectionOffsets($Ed, [string]$Text) {
    switch ($Ed.Mode) {
        'source' {
            $b = $Ed.Source
            $cr = { param($i) $i - ($b.Text.Substring(0, $i).Split("`r").Count - 1) }
            return @((& $cr $b.SelectionStart), (& $cr ($b.SelectionStart + $b.SelectionLength)))
        }
        'live' {
            if ($Ed.Island) {
                $box = $Ed.IslandBox
                $a = Get-WtMemoIslandCaret $Ed $box.SelectionStart
                $z = Get-WtMemoIslandCaret $Ed ($box.SelectionStart + $box.SelectionLength)
                return @((Get-WtMemoOffset $Text $a.Line $a.Col), (Get-WtMemoOffset $Text $z.Line $z.Col))
            }
            $o = Get-WtMemoOffset $Text $Ed.Caret.Line $Ed.Caret.Col
            return @($o, $o)
        }
    }
    @(0, 0)
}

function Select-WtMemoTextRange($Ed, [string]$Text, [int]$Offset, [int]$Length) {
    switch ($Ed.Mode) {
        'source' {
            $b = $Ed.Source
            $crlf = $b.Text.Contains("`r`n")
            $toBox = { param($o) if ($crlf) { $o + ($Text.Substring(0, $o).Split("`n").Count - 1) } else { $o } }
            $s = & $toBox $Offset
            $e = & $toBox ($Offset + $Length)
            $b.Select($s, $e - $s)
            $b.ScrollToLine([Math]::Max(0, $b.GetLineIndexFromCharacterIndex($s)))
        }
        'live' {
            $a = Get-WtMemoLineCol $Text $Offset
            $z = Get-WtMemoLineCol $Text ($Offset + $Length)
            Open-WtMemoIslandAt $Ed $a.Line $a.Col $z.Line $z.Col
        }
    }
}

function Update-WtMemoFindCount($Ed, [int]$Current = -1, [int]$Total = -1) {
    $f = $Ed.Find
    if (-not $f.Query.Text) { $f.Count.Text = ''; return }
    if ($Total -lt 0) {
        $Total = if ($Ed.Mode -eq 'read') { @(Get-WtMemoReadMatches $Ed $f.Query.Text).Count } else { (Get-WtMemoMatches ((Get-WtMemoEditorText $Ed).Replace("`r`n", "`n")) $f.Query.Text).Count }
    }
    $f.Count.Text = if (-not $Total) { '없음' } elseif ($Current -ge 0) { "$($Current + 1)/$Total" } else { "${Total}개" }
}

# 다음(-Back이면 이전) 찾기. -Here: 고른 곳 시작부터 다시 찾기(찾는 글을 칠 때)
function Invoke-WtMemoFind($Ed, [switch]$Back, [switch]$Here) {
    $f = $Ed.Find
    $q = $f.Query.Text
    if (-not $q) { Update-WtMemoFindCount $Ed; return }
    # 실시간 보기에서 찾는 글을 치는 중에는 개수만 센다. 찾은 곳으로 가려면 섬에 포커스를 줬다 돌려받아야 해서
    # 한글 조합이 끊긴다. 이동은 Enter · F3에서
    if ($Here -and $Ed.Mode -eq 'live') { Update-WtMemoFindCount $Ed; return }
    $focusFind = $f.Query.IsKeyboardFocusWithin -or $f.Bar.IsKeyboardFocusWithin
    try {
        if ($Ed.Mode -eq 'read') { Invoke-WtMemoFindRead $Ed $q -Back:$Back -Here:$Here; return }
        $text = (Get-WtMemoEditorText $Ed).Replace("`r`n", "`n")
        $hits = Get-WtMemoMatches $text $q
        if (-not $hits.Count) { Update-WtMemoFindCount $Ed -1 0; return }
        $sel = Get-WtMemoSelectionOffsets $Ed $text
        $k = -1
        if ($Back) {
            for ($i = $hits.Count - 1; $i -ge 0; $i--) { if ($hits[$i] -lt $sel[0]) { $k = $i; break } }
            if ($k -lt 0) { $k = $hits.Count - 1 }
        } else {
            $from = if ($Here) { $sel[0] } else { $sel[1] }
            for ($i = 0; $i -lt $hits.Count; $i++) { if ($hits[$i] -ge $from) { $k = $i; break } }
            if ($k -lt 0) { $k = 0 }
        }
        Select-WtMemoTextRange $Ed $text $hits[$k] $q.Length
        Update-WtMemoFindCount $Ed $k $hits.Count
    } finally {
        if ($focusFind) { [void]$f.Query.Focus() }
    }
}

# 읽기 모드: 그린 글(Run)에서 찾는다. 여러 Run에 걸친 글은 찾지 않는다
function Get-WtMemoReadMatches($Ed, [string]$Query) {
    $out = [System.Collections.Generic.List[object]]::new()
    $tp = $Ed.View.Document.ContentStart
    while ($tp) {
        if ($tp.GetPointerContext('Forward') -eq 'Text') {
            $run = $tp.GetTextInRun('Forward')
            $i = 0
            while (($i = $run.IndexOf($Query, $i, [StringComparison]::OrdinalIgnoreCase)) -ge 0) {
                $out.Add(@{ Start = $tp.GetPositionAtOffset($i); End = $tp.GetPositionAtOffset($i + $Query.Length) })
                $i += [Math]::Max(1, $Query.Length)
            }
        }
        $tp = $tp.GetNextContextPosition('Forward')
    }
    , $out
}

function Invoke-WtMemoFindRead($Ed, [string]$Query, [switch]$Back, [switch]$Here) {
    $f = $Ed.Find
    $hits = Get-WtMemoReadMatches $Ed $Query
    if (-not $hits.Count) { $f.ReadIndex = -1; Update-WtMemoFindCount $Ed -1 0; return }
    $k = if ($Here) { [Math]::Max(0, $f.ReadIndex) } elseif ($Back) { $f.ReadIndex - 1 } else { $f.ReadIndex + 1 }
    if ($k -lt 0) { $k = $hits.Count - 1 }
    if ($k -ge $hits.Count) { $k = 0 }
    $f.ReadIndex = $k
    $Ed.View.Selection.Select($hits[$k].Start, $hits[$k].End)
    $p = $hits[$k].Start.Parent
    if ($p -is [System.Windows.FrameworkContentElement]) { $p.BringIntoView() }
    Update-WtMemoFindCount $Ed $k $hits.Count
}

# 바꾸기: 고른 곳이 찾는 글이면 바꾸고 다음을 찾는다. -All: 모두 바꾸기
function Invoke-WtMemoReplace($Ed, [switch]$All) {
    $f = $Ed.Find
    $q = $f.Query.Text
    if (-not $q -or $Ed.Mode -eq 'read') { return }
    $rep = [string]$f.Replace.Text
    try {
        if ($All) {
            $text = (Get-WtMemoEditorText $Ed).Replace("`r`n", "`n")
            $n = (Get-WtMemoMatches $text $q).Count
            if (-not $n) { Update-WtMemoFindCount $Ed -1 0; return }
            $new = [regex]::Replace($text, [regex]::Escape($q), $rep.Replace('$', '$$'), 'IgnoreCase')
            if ($Ed.Mode -eq 'source') {
                $b = $Ed.Source
                if ($b.Text.Contains("`r`n")) { $new = $new.Replace("`n", "`r`n") }
                $b.SelectAll()
                $b.SelectedText = $new
                $b.Select(0, 0)
            } else {
                Push-WtMemoUndo $Ed
                $Ed.Busy++
                try {
                    if ($Ed.Island) { Close-WtMemoIsland $Ed -NoRender }
                    $Ed.Loading = $true
                    try { Set-WtMemoLines $Ed $new } finally { $Ed.Loading = $false }
                    Update-WtMemoLive $Ed
                } finally { $Ed.Busy-- }
                Invoke-WtMemoEditorChanged $Ed
            }
            $f.Count.Text = "${n}개 바꿈"
            return
        }
        $box = if ($Ed.Mode -eq 'source') { $Ed.Source } elseif ($Ed.Island) { $Ed.IslandBox } else { $null }
        if ($box -and $box.SelectionLength -and [string]::Equals($box.SelectedText, $q, [StringComparison]::OrdinalIgnoreCase)) {
            $start = $box.SelectionStart
            [void](Invoke-WtMemoBoxEdit $box @{ Start = $start; Length = $box.SelectionLength; Insert = $rep; SelStart = $start + $rep.Length; SelLength = 0 })
        }
        Invoke-WtMemoFind $Ed
    } catch { Show-WtError $_ '바꾸기' }
}

# 편집기 전체 단축키: 찾기 · 바꾸기
function Invoke-WtMemoEditorKey($S, $E) {
    if ($E.Handled) { return }
    $ed = $S.Tag
    $key = if ($E.Key -eq 'System') { $E.SystemKey } else { $E.Key }
    $mods = [System.Windows.Input.Keyboard]::Modifiers
    $ctrl = ($mods -band 'Control') -ne 0
    $shift = ($mods -band 'Shift') -ne 0
    $alt = ($mods -band 'Alt') -ne 0
    try {
        if ($ctrl -and -not $alt -and -not $shift -and $key -eq 'F') { Open-WtMemoFind $ed; $E.Handled = $true; return }
        if ($ctrl -and -not $alt -and -not $shift -and $key -eq 'H') { Open-WtMemoFind $ed -Replace; $E.Handled = $true; return }
        if ($key -eq 'F3' -and -not $ctrl -and -not $alt) {
            if ($ed.Find.Query.Text) { Invoke-WtMemoFind $ed -Back:$shift } else { Open-WtMemoFind $ed }
            $E.Handled = $true
            return
        }
        if ($key -eq 'Escape' -and $ed.Find.Bar.Visibility -eq 'Visible' -and -not ($ed.Suggest -and $ed.Suggest.Popup.IsOpen)) {
            Close-WtMemoFind $ed
            $E.Handled = $true
        }
    } catch { Show-WtError $_ '찾기' }
}

# 글자 크기를 바꾸면 그려 둔 Section(다이어그램 크기 등)을 버리고 다시 그린다
Register-WtSettingHandler {
    param($key, $value)
    if ($key -ne 'ui.fontScale') { return }
    foreach ($w in @($script:editors)) {
        $ed = $w.Target
        if (-not $ed -or $ed.Mode -ne 'live') { continue }
        $ed.Cache.Clear()
        # 섬이 열려 있으면 닫고 전체를 다시 그린 뒤 같은 자리에 다시 연다 (안 고친 섬을 닫으면 예전 Section을 돌려놓기 때문)
        $caret = $null
        if ($ed.Island) {
            $caret = if ($ed.IslandBox.IsKeyboardFocused) { Get-WtMemoIslandCaret $ed } else { $null }
            $ed.Busy++
            try { Close-WtMemoIsland $ed -NoRender } finally { $ed.Busy-- }
        }
        Update-WtMemoLive $ed
        if ($caret) { Open-WtMemoIslandAt $ed $caret.Line $caret.Col }
    }
}

Export-ModuleMember -Function New-WtMemoEditor, Set-WtMemoEditorText, Get-WtMemoEditorText, Set-WtMemoEditorMode,
    Set-WtMemoEditorEnabled, Set-WtMemoEditorFocus, Get-WtMemoEditorState, Set-WtMemoEditorState
} | Import-Module -Force -DisableNameChecking
# ---- addons\memo\MemoEditor.psm1 끝 ----

# ---- addons\memo\MemoText.psm1 ----
New-Module -Name 'WorkTool.addon.memo.MemoText' -ScriptBlock {
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
} | Import-Module -Force -DisableNameChecking
# ---- addons\memo\MemoText.psm1 끝 ----

# ---- addons\schedule\Schedule.psm1 ----
New-Module -Name 'WorkTool.addon.schedule' -ScriptBlock {
# 일정 탭 (1단계: 보기 전용). 편집 · 알람은 2단계에서 옮긴다.
# 저장소 schedule.json (schema 1). 항목:
#   id, title, startDate, endDate(기간 일정. 하루짜리는 startDate와 같음), time(''=하루 종일), endTime,
#   note, alarm(분 전, $null=없음), repeat(''|daily|weekdays|weekly), tags[], lastAlarm, updated

$ErrorActionPreference = 'Stop'

$script:schema = 1
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:repeatNames = @{ daily = '매일'; weekdays = '평일'; weekly = '매주' }
$script:list = $null

function ConvertTo-SchDate([string]$Text) { [datetime]::ParseExact($Text, 'yyyy-MM-dd', $script:inv) }

function Get-WtScheduleItems { Get-WtStoreItems -Name 'schedule' -Schema $script:schema }

# $Item이 $Day에 있는지 (반복 포함)
function Test-WtScheduleOn($Item, [datetime]$Day) {
    $d = $Day.Date
    $start = ConvertTo-SchDate $Item.startDate
    $end = if ($Item.endDate) { ConvertTo-SchDate $Item.endDate } else { $start }
    if ($d -lt $start) { return $false }
    switch ([string]$Item.repeat) {
        'daily' { return $true }
        'weekdays' { return [int]$d.DayOfWeek -ge 1 -and [int]$d.DayOfWeek -le 5 }
        'weekly' { return $d.DayOfWeek -eq $start.DayOfWeek }
        default { return $d -le $end }
    }
}

# 그날 일정을 시간 순서로 (하루 종일이 먼저)
function Get-WtScheduleOn([datetime]$Day, [object[]]$Items) {
    if ($null -eq $Items) { $Items = Get-WtScheduleItems }
    @($Items | Where-Object { Test-WtScheduleOn $_ $Day } | Sort-Object { if ($_.time) { $_.time } else { '' } }, { $_.title })
}

# 여러 날을 그릴 때 항목의 날짜를 한 번만 읽는다. 반복 판단과 날짜별 정렬은 하루 조회와 같다.
function Get-WtScheduleRange([datetime]$From, [int]$Count, [object[]]$Items) {
    $dates = @(); $buckets = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $dates += $From.Date.AddDays($i)
        $buckets += , [Collections.Generic.List[object]]::new()
    }
    foreach ($item in $Items) {
        $start = [datetime]::ParseExact($item.startDate, 'yyyy-MM-dd', $script:inv)
        $end = if ($item.endDate) { [datetime]::ParseExact($item.endDate, 'yyyy-MM-dd', $script:inv) } else { $start }
        for ($i = 0; $i -lt $Count; $i++) {
            $day = $dates[$i]
            if ($day -lt $start) { continue }
            $on = switch ([string]$item.repeat) {
                'daily' { $true }
                'weekdays' { [int]$day.DayOfWeek -ge 1 -and [int]$day.DayOfWeek -le 5 }
                'weekly' { $day.DayOfWeek -eq $start.DayOfWeek }
                default { $day -le $end }
            }
            if ($on) { $buckets[$i].Add($item) }
        }
    }
    $result = @()
    foreach ($bucket in $buckets) {
        $result += , @($bucket | Sort-Object { if ($_.time) { $_.time } else { '' } }, { $_.title })
    }
    , $result
}

function Format-WtAlarm($Alarm) {
    if ($null -eq $Alarm -or "$Alarm" -eq '') { return $null }
    $m = [int]$Alarm
    if ($m -eq 0) { '정시' } elseif ($m -eq 1440) { '하루 전' } elseif ($m % 60 -eq 0) { "$($m / 60)시간 전" } else { "${m}분 전" }
}

# 예전 schedule.csv → schedule.json. 가져온 개수를 돌려준다.
function Import-WtScheduleLegacy([string]$Folder) {
    $rows = Import-WtLegacyCsv $Folder 'schedule'
    if ($null -eq $rows) { return $null }
    $items = foreach ($r in $rows) {
        [ordered]@{
            id        = [string]$r.Id
            title     = [string]$r.Title
            startDate = [string]$r.Date
            endDate   = [string]$r.Date
            time      = [string]$r.Time
            endTime   = ''
            note      = [string]$r.Note
            alarm     = if ("$($r.Alarm)" -eq '') { $null } else { [int]$r.Alarm }
            repeat    = [string]$r.Repeat
            tags      = @()
            lastAlarm = [string]$r.LastAlarm
            updated   = [string]$r.Updated
        }
    }
    Write-WtStore -Name 'schedule' -Schema $script:schema -Items @($items) -Extra @{ importedFrom = $Folder }
    @($items).Count
}

# 한 줄: 시각 · 제목 · 표시(반복 · 알람)
function New-WtScheduleRow($Item, [string]$DayLabel) {
    $parts = [System.Collections.Generic.List[object]]::new()
    if ($DayLabel) {
        $d = New-WtText $DayLabel 'T.Sub'
        $d.Width = 84
        $parts.Add($d)
    }
    $t = New-WtText $(if ($Item.time) { $Item.time } else { '하루 종일' }) 'T.Strong'
    $t.Width = 72
    $parts.Add($t)
    $tags = New-WtStack Horizontal 6
    $rep = $script:repeatNames[[string]$Item.repeat]
    if ($rep) { [void](Add-WtChild $tags (New-WtTag $rep -Icon 0xE8EE)) }
    $al = Format-WtAlarm $Item.alarm
    if ($al) { [void](Add-WtChild $tags (New-WtTag $al -Icon 0xEA8F)) }
    foreach ($tag in @($Item.tags)) { if ($tag) { [void](Add-WtChild $tags (New-WtTag "#$tag")) } }
    if ($tags.Children.Count) { $parts.Add($tags) }
    $title = New-WtText $Item.title 'T.Body'
    $title.TextTrimming = 'CharacterEllipsis'
    $title.TextWrapping = 'NoWrap'
    $parts.Add($title)
    # 제목이 남는 폭을 채우도록 맨 끝에 둔다 (표시는 제목 앞)
    New-WtListRow $parts.ToArray()
}

function New-WtScheduleView {
    $script:viewKey = $null
    $page = New-WtPage
    [void](Add-WtChild $page.Panel (New-WtPageHeader '일정' '보기 전용 · 편집과 알람은 2단계에서 옮깁니다'))
    $card = New-WtCard
    $script:list = New-WtStack Vertical
    $card.Child = $script:list
    [void](Add-WtChild $page.Panel $card)
    $page.Root
}

function Update-WtScheduleView {
    $key = @((Get-WtStoreStamp 'schedule'), [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:viewKey -ceq $key) { return }
    $items = Get-WtScheduleItems
    $days = Get-WtScheduleRange ([datetime]::Today) 14 $items
    $script:list.Children.Clear()
    [void](Add-WtChild $script:list (New-WtCardHeader '다가오는 14일'))
    $any = $false
    for ($i = 0; $i -lt 14; $i++) {
        $day = [datetime]::Today.AddDays($i)
        $label = if ($i -eq 0) { '오늘' } elseif ($i -eq 1) { '내일' } else { Format-WtDate $day "M'/'d (ddd)" }
        foreach ($it in $days[$i]) {
            [void](Add-WtChild $script:list (New-WtScheduleRow $it $label))
            $label = ''
            $any = $true
        }
    }
    if (-not $any) { [void](Add-WtChild $script:list (New-WtText '다가오는 일정이 없습니다.' 'T.Sub')) }
    $script:viewKey = $key
}

function New-WtScheduleHomeCards {
    $key = @((Get-WtStoreStamp 'schedule'), [datetime]::Today.Ticks, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale')) -join '|'
    if ($script:homeKey -ceq $key -and $script:homeCards -and -not @($script:homeCards | Where-Object Parent).Count) { return $script:homeCards }
    $items = Get-WtScheduleItems
    $days = Get-WtScheduleRange ([datetime]::Today) 8 $items
    $today = @($days[0])

    $c1 = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '오늘 일정' "$($today.Count)" '일정 열기' 'schedule'))
    foreach ($it in $today) { [void](Add-WtChild $col (New-WtScheduleRow $it)) }
    if (-not $today.Count) { [void](Add-WtChild $col (New-WtText '오늘은 일정이 없습니다.' 'T.Sub')) }
    $c1.Child = $col

    $c2 = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '다가오는 7일'))
    $n = 0
    for ($i = 1; $i -le 7; $i++) {
        $day = [datetime]::Today.AddDays($i)
        foreach ($it in $days[$i]) {
            if ($it.repeat -eq 'daily' -or $it.repeat -eq 'weekdays') { continue }   # 매일 반복은 오늘 카드에서만
            [void](Add-WtChild $col (New-WtScheduleRow $it (Format-WtDate $day "M'/'d (ddd)")))
            $n++
        }
    }
    if (-not $n) { [void](Add-WtChild $col (New-WtText '다가오는 일정이 없습니다.' 'T.Sub')) }
    $c2.Child = $col

    $script:homeCards = @($c1, $c2); $script:homeKey = $key
    $script:homeCards
}

Register-WtAddon -Id 'schedule' -Title '일정' -Icon 0xE787 -Order 20 -WarmUp Full `
    -NewView { New-WtScheduleView } `
    -Refresh { param($view) Update-WtScheduleView } `
    -HomeCard { New-WtScheduleHomeCards } `
    -ImportLegacy { param($folder) Import-WtScheduleLegacy $folder } `
    -Help '일정은 보기만 합니다. 편집과 알람은 2단계에서 옮깁니다.'

Export-ModuleMember -Function Get-WtScheduleItems, Test-WtScheduleOn, Get-WtScheduleOn, Format-WtAlarm, Import-WtScheduleLegacy
} | Import-Module -Force -DisableNameChecking
# ---- addons\schedule\Schedule.psm1 끝 ----

# ---- addons\workflows\Workflows.psm1 ----
New-Module -Name 'WorkTool.addon.workflows' -ScriptBlock {
# 업무 탭: 스크립트 폴더의 PowerShell 스크립트를 폼으로 실행하고 기록한다. 설계는 docs/plans/workflows-design.md
# - 스크립트는 실행하지 않고 구문만 읽어서 목록 · 폼을 만든다 (Read-WtFlowScript). param 하나 = 폼 칸 하나.
# - 실행은 별도 pwsh 프로세스로 한다. 앱 안: 창 없이 출력을 받아 보여 줌 · 콘솔 창: 보이는 창에서 -NoExit.
#   출력은 UI 타이머에서 완료된 읽기만 꺼낸다 (다른 스레드에서 PowerShell 코드를 돌리지 않는다).
# - 저장소 workflows.json(저장한 업무) · workflow-runs.json(실행 기록, 최근 100건). 설정 workflows.roots(스크립트 폴더)
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

Register-WtSettingDefault 'workflows.roots' @()   # 스크립트 폴더 목록
Register-WtSettingDefault 'workflows.help' $true  # 오른쪽 설명 패널을 펼침

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

# 스크립트 하나를 읽는다. 실행하지 않고 구문만 본다. 못 읽거나 실행할 수 없으면 Error에 이유
function Read-WtFlowScript([string]$Path) {
    $info = [pscustomobject]@{
        Path = $Path; Name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        Synopsis = ''; Description = ''; Examples = @(); Notes = ''
        Fields = @(); Skipped = @(); WhatIf = $false; Console = $false; NeedsConsole = @(); Error = ''; Warning = ''
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { $info.Error = '스크립트 파일이 없습니다.'; return $info }
    $tokens = $null; $parseErrors = $null
    try { $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors) }
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

# 스크립트 폴더에서 .ps1을 찾는다 (하위 폴더 3단계까지, 이름이 _로 시작하면 뺀다). 없는 폴더도 표시하려고 돌려준다
function Find-WtFlowScripts([string[]]$Roots) {
    foreach ($root in $Roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { [pscustomobject]@{ Root = $root; Missing = $true; Scripts = @() }; continue }
        $files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -eq '.ps1' -and $_.Name -notlike '_*' } | Sort-Object FullName | Select-Object -First $script:maxScripts)
        $found = foreach ($f in $files) {
            $rel = [System.IO.Path]::GetRelativePath($root, $f.DirectoryName)
            [pscustomobject]@{ Path = $f.FullName; Name = $f.BaseName; Folder = $(if ($rel -eq '.') { '' } else { $rel }) }
        }
        [pscustomobject]@{ Root = $root; Missing = $false; Scripts = @($found) }
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

# 출력 퍼 오기: 별도 실행 공간(MTA)에서 표준 출력 · 오류 통로를 쉬지 않고 읽어 큐에 넣는다.
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

# 앱 안 실행을 시작한다. 입력은 바로 닫아서, 입력을 기다리는 스크립트도 멈추지 않고 오류로 끝나게 한다
function Start-WtFlowProcess($StartInfo, $Record) {
    $p = [System.Diagnostics.Process]::Start($StartInfo)
    $p.StandardInput.Close()
    $enc = Get-WtFlowEncoding
    $readers = @(foreach ($stream in @($p.StandardOutput.BaseStream, $p.StandardError.BaseStream)) { [System.IO.StreamReader]::new($stream, $enc, $false, 65536) })
    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
    $stop = [hashtable]::Synchronized(@{ Value = $false })
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'UseNewThread'   # ReuseThread는 실행 공간을 버리기 전까지 스레드가 남아 앱 프로세스가 끝나지 않는다
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:pumpWork.ToString()).AddArgument($readers).AddArgument($queue).AddArgument($stop)
    [pscustomobject]@{
        Process = $p; Id = $p.Id; Record = $Record; Started = Get-Date; ExitedAt = $null; Cancelled = $false; Stopped = $false
        Readers = $readers; Queue = $queue; Stop = $stop; Shell = $ps; Runspace = $rs; Async = $ps.BeginInvoke()
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
    # 퍼 오기를 멈추고 실행 공간을 버린 뒤 읽기 통로를 닫는다. 퍼 오기는 0.2초마다 그만둘지 보므로 오래 기다리지 않는다.
    # 남은 자식이 통로를 붙잡고 있어도 통로가 끝나기를 기다리지는 않는다
    $Run.Stop.Value = $true
    try { [void]$Run.Async.AsyncWaitHandle.WaitOne(2000) } catch { }
    try { $Run.Shell.Dispose() } catch { }
    try { $Run.Runspace.Dispose() } catch { }
    foreach ($r in $Run.Readers) { try { $r.Dispose() } catch { } }
    try { $Run.Process.Dispose() } catch { }
    try { Save-WtFlowRun $rec } catch { $Run | Add-Member -NotePropertyName SaveError -NotePropertyValue $_.Exception.Message -Force }
    $status
}

# 실행 중인 것을 끝낸다 (자식 프로세스까지). 이때 스크립트의 finally는 돌지 않을 수 있다.
# 스크립트는 이미 끝났는데 남은 자식이 출력을 붙잡고 있으면, 그 자식을 찾아 끝낸다 (이 실행이 시작한 뒤에 생긴 것만)
function Stop-WtFlowProcess($Run) {
    $exited = $true
    try { $exited = $Run.Process.HasExited } catch { }
    if (-not $exited) {
        try { $Run.Process.Kill($true) } catch { }
        return
    }
    try {
        foreach ($c in @(Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId = $($Run.Id)" -ErrorAction Stop)) {
            if ($c.CreationDate -lt $Run.Started.AddSeconds(-1)) { continue }
            try { $child = [System.Diagnostics.Process]::GetProcessById([int]$c.ProcessId); $child.Kill($true); $child.Dispose() } catch { }
        }
    } catch { }
}

# ---- 저장 (WPF 없이) ----------------------------------------------------------------------------

# 저장한 업무 · 실행 기록은 하나씩 내보낸다. Get-WtStoreItems는 목록을 한 덩어리로 돌려주므로 받아서 푼다
# (덩어리째 파이프에 넣으면 Where-Object · Sort-Object가 목록 전체를 항목 하나로 본다)
function Get-WtFlows {
    $items = Get-WtStoreItems -Name 'workflows' -Schema $script:schema
    $items | Sort-Object { [string]$_.title }
}

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

function Get-WtFlowRoots { @(Get-WtSetting 'workflows.roots' | Where-Object { $_ }) }

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

# 왼쪽 목록: 저장한 업무 + 스크립트 폴더별 스크립트. 지금 고른 것을 다시 고른다
function Update-WtFlowTree {
    $tree = $script:ui.Tree
    $keep = if ($script:flow) { "flow:$($script:flow.id)" } elseif ($script:info) { "script:$($script:info.Path)" } else { '' }
    # 다른 탭에 다녀와도 고치던 칸 값과 실행 방식은 그대로 둔다
    $carry = if ($keep -and $script:fields.Count) { @{ Key = $keep; Values = (Get-WtFlowFormValues); Mode = (Get-WtFlowMode) } } else { $null }
    if ($script:pendingFlow) { $keep = "flow:$($script:pendingFlow)"; $script:pendingFlow = $null }
    $flows = @(Get-WtFlows)
    $groups = @(Find-WtFlowScripts (Get-WtFlowRoots))
    $missingPaths = @{}
    foreach ($f in $flows) { $missingPaths[[string]$f.script] = -not (Test-Path -LiteralPath ([string]$f.script) -PathType Leaf) }
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
            $leafCount = @{}
            foreach ($g in $groups) { $leaf = Split-Path $g.Root -Leaf; $leafCount[$leaf] = 1 + [int]$leafCount[$leaf] }
            foreach ($group in $groups) {
                $rootName = Split-Path $group.Root -Leaf
                if (-not $rootName) { $rootName = $group.Root }
                elseif ($leafCount[$rootName] -gt 1) {
                    $parentName = Split-Path (Split-Path $group.Root -Parent) -Leaf
                    if ($parentName) { $rootName = "$parentName\$rootName" }
                }
                $label = if ($group.Missing) { "$rootName · 폴더 없음" } else { $rootName }
                $rootNode = New-WtFlowTreeItem $label 0xE8B7 @{ Kind = 'root'; Path = $group.Root } $group.Root
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
                if (-not $group.Missing -and -not $group.Scripts.Count) {
                    $hint = New-WtFlowTreeItem '.ps1 파일 없음' 0xE946 @{ Kind = 'hint' } -Muted
                    $hint.Focusable = $false
                    [void]$rootNode.Items.Add($hint)
                }
                [void]$tree.Items.Add($rootNode)
            }
        }
        if ($found) { $found.IsSelected = $true; $found.BringIntoView() }
        $script:ui.RemoveRoot.IsEnabled = $false   # 다시 만든 목록에서는 고른 폴더가 없다
    } finally { $script:filling = $false }
    if ($found) {
        Select-WtFlowNode $found.Tag -Reuse
        if ($carry -and $carry.Key -eq $keep) {
            Set-WtFlowFormValues $carry.Values
            foreach ($rb in $script:ui.ModeButtons) { $rb.IsChecked = ($rb.Tag.Value -eq $carry.Mode) }
        }
    } elseif ($keep) { Clear-WtFlowSelection }
    else { Update-WtFlowCenter -Reuse }
    $script:treeKey = $key
}

function Add-WtFlowRoot {
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = '업무 탭에서 실행할 스크립트(.ps1)가 있는 폴더를 고르세요'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $path = $dlg.SelectedPath
    $roots = @(Get-WtFlowRoots)
    if (-not ($roots | Where-Object { $_ -ieq $path })) { Set-WtSetting 'workflows.roots' @($roots + $path) }
    Update-WtFlowTree
    Set-WtFlowNote "스크립트 폴더를 더했습니다: $path"
}

function Remove-WtFlowRoot {
    $node = $script:ui.Tree.SelectedItem
    if (-not $node -or $node.Tag.Kind -ne 'root') { return }
    $path = $node.Tag.Path
    Set-WtSetting 'workflows.roots' @(Get-WtFlowRoots | Where-Object { $_ -ine $path })
    Clear-WtFlowSelection
    Update-WtFlowTree
    Set-WtFlowNote "목록에서 뺐습니다: $path (폴더와 파일은 그대로)"
}

# ---- 화면: 고른 것 · 폼 -------------------------------------------------------------------------

function Clear-WtFlowSelection {
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

function Select-WtFlowNode($Tag, [switch]$Reuse) {
    $script:ui.RemoveRoot.IsEnabled = ($Tag.Kind -eq 'root')
    if ($Tag.Kind -eq 'script') { Reset-WtFlowOutput "script:$($Tag.Path)" }
    elseif ($Tag.Kind -eq 'flow') { Reset-WtFlowOutput "flow:$($Tag.Id)" }
    switch ($Tag.Kind) {
        'script' {
            $script:flow = $null
            $script:info = Read-WtFlowScript $Tag.Path
            Update-WtFlowCenter -Reuse:$Reuse
        }
        'flow' {
            $f = Get-WtFlows | Where-Object { $_.id -eq $Tag.Id } | Select-Object -First 1
            if (-not $f) { Clear-WtFlowSelection; return }
            $script:flow = $f
            $script:info = Read-WtFlowScript ([string]$f.script)
            Update-WtFlowCenter -Reuse:$Reuse
        }
    }
}

# 가운데 · 오른쪽을 고른 것에 맞춘다
function Update-WtFlowCenter([switch]$Reuse) {
    $u = $script:ui
    if (-not $u.Count) { return }
    $hasFlows = @(Get-WtFlows).Count -gt 0
    $key = ConvertTo-Json -Compress -Depth 10 -InputObject @($script:info, $script:flow, @(Get-WtFlowRoots), $hasFlows, [bool]$script:run, (Get-WtSetting 'theme.color'), (Get-WtSetting 'ui.fontScale'))
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
        $u.Empty.Visibility = if ($hasRoots -or $script:run) { 'Collapsed' } else { 'Visible' }
        foreach ($x in @($u.SaveFlow, $u.DeleteFlow, $u.Repick)) { $x.Visibility = 'Collapsed' }
        # 실행 중에는 고른 것이 없어져도 [취소]와 출력은 계속 보인다
        $keep = if ($script:run) { 'Visible' } else { 'Collapsed' }
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
    if ($info.Error) { Set-WtResource $u.Sub 'Foreground' 'B.Danger' } else { Set-WtResource $u.Sub 'Foreground' 'B.SubText' }
    $values = if ($script:flow) { ConvertTo-WtFlowValues $script:flow.values } else { @{} }
    if ($script:flow) {
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
    # 실행 방식: 업무에 저장한 것 → 스크립트가 정한 것(.NOTES의 WorkTool: 콘솔, 폼에 못 넣는 필수 값) → 앱 안
    $mode = if ($script:flow -and $script:flow.mode) { [string]$script:flow.mode } elseif ($info.Console -or $info.NeedsConsole.Count) { 'console' } else { 'app' }
    foreach ($rb in $u.ModeButtons) { $rb.IsChecked = ($rb.Tag.Value -eq $mode) }
    $u.SaveFlow.Content = New-WtButtonContent $(if ($script:flow) { '업무 저장' } else { '업무로 저장' }) 0xE74E
    $u.SaveFlow.ToolTip = if ($script:flow) { '지금 값과 실행 방식을 이 업무에 저장합니다' } else { '지금 값과 실행 방식을 업무로 저장해 왼쪽 목록에 둡니다' }
    $u.DeleteFlow.Visibility = if ($script:flow) { 'Visible' } else { 'Collapsed' }
    $u.Repick.Visibility = if ($script:flow -and -not (Test-Path -LiteralPath $info.Path -PathType Leaf)) { 'Visible' } else { 'Collapsed' }
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

function Select-WtFlowPath($TextBox, [string]$Kind) {
    if ($Kind -eq 'folder') {
        $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
        if ($TextBox.Text -and (Test-Path -LiteralPath $TextBox.Text -PathType Container)) { $dlg.SelectedPath = $TextBox.Text }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $TextBox.Text = $dlg.SelectedPath }
        return
    }
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    if ($TextBox.Text) {
        $dir = Split-Path $TextBox.Text -Parent
        if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) { $dlg.InitialDirectory = $dir }
    } elseif ($script:info) { $dlg.InitialDirectory = Split-Path $script:info.Path -Parent }
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
    $running = [bool]$script:run
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
    if ($mode -eq 'app' -and ($script:run -or $script:info.NeedsConsole.Count)) { return }
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
    try {
        $start = New-WtFlowStartInfo $script:info $values $mode -WhatIf:$WhatIf
        if ($mode -eq 'console') {
            $p = [System.Diagnostics.Process]::Start($start)
            if ($p) { $script:consoles.Add(@{ Process = $p; Record = $record }) }
            $note = "콘솔 창을 띄웠습니다: $($script:info.Name). 그 창에서 끝내고 닫으세요."
            try { Save-WtFlowRun $record } catch { $note += " (실행 기록은 저장하지 못했습니다: $($_.Exception.Message))" }
            Set-WtFlowNote $note
            Start-WtFlowTimer
            Update-WtFlowHelp
            return
        }
        $script:run = Start-WtFlowProcess $start $record
    } catch {
        Set-WtFlowNote "실행하지 못했습니다: $($_.Exception.Message)"
        return
    }
    $u = $script:ui
    $script:outputKey = if ($script:flow) { "flow:$($script:flow.id)" } else { "script:$($script:info.Path)" }
    $script:shown = 1
    $u.Output.Clear()
    $head = "▶ $($script:info.Name)$(if ($WhatIf) { ' (미리보기)' }) · $((Get-Date).ToString('HH:mm:ss')) 시작"
    $u.Output.AppendText($head)
    $u.OutputHint.Visibility = 'Collapsed'
    $u.Status.Visibility = 'Visible'
    $u.Busy.Visibility = 'Visible'
    $u.RunStatus.Child = $null
    $u.Elapsed.Text = '실행 중 · 0초'
    Set-WtFlowNote ''
    Update-WtFlowCommands
    Start-WtFlowTimer
}

function Stop-WtFlowRun {
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
    $mode = New-WtSegmented @(@('app', '앱 안에서'), @('console', '콘솔 창에서')) 'app' 'WtFlowMode' { param($value) Update-WtFlowCommands }
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
    if ($script:run) {
        $done = $script:run
        $script:run = $null
        $done.Stopped = $true
        Stop-WtFlowProcess $done
        try { [void]$done.Process.WaitForExit(2000) } catch { }
        try { [void](Read-WtFlowOutput $done) } catch { }
        try { [void](Complete-WtFlowRun $done) } catch { }
    }
    foreach ($c in @($script:consoles)) { try { $c.Process.Dispose() } catch { } }
    $script:consoles.Clear()
}

Register-WtAddon -Id 'workflows' -Title '업무' -Icon 0xE756 -Order 70 -WarmUp View `
    -NewView { New-WtFlowsView } `
    -Refresh { param($view) Update-WtFlowsView } `
    -HomeCard { New-WtFlowsHomeCard } `
    -OnExit { Stop-WtFlows } `
    -Help '업무는 스크립트 폴더의 PowerShell 스크립트를 폼으로 실행합니다. 스크립트의 param이 입력 칸이 되고, 자주 쓰는 값은 [업무로 저장]해 두고 다시 씁니다.' `
    -Shortcuts (, @('F5', '스크립트 목록 새로 고침'))

Export-ModuleMember -Function Read-WtFlowScript, Find-WtFlowScripts, Test-WtFlowValues, Get-WtFlowArgs, Get-WtFlowStaleNames,
    ConvertTo-WtFlowValues, ConvertTo-WtFlowCommandArg, New-WtFlowStartInfo, Start-WtFlowProcess, Read-WtFlowOutput, Test-WtFlowRunDone,
    Complete-WtFlowRun, Stop-WtFlowProcess, Get-WtFlows, Save-WtFlows, New-WtFlow, Get-WtFlowRuns, Save-WtFlowRun, New-WtFlowRecord,
    Get-WtFlowStatusLook, Format-WtFlowSpan, Get-WtFlowEncoding
} | Import-Module -Force -DisableNameChecking
# ---- addons\workflows\Workflows.psm1 끝 ----
#endregion

    Start-WtApp -AppRoot $PSScriptRoot
} catch {
    $msg = "$($_.Exception.Message)`n`n위치: $($_.InvocationInfo.PositionMessage)"
    Write-Host $msg -ForegroundColor Red
    try { [void][System.Windows.MessageBox]::Show($msg, 'WorkTool 시작 오류', 'OK', 'Error') } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'WorkTool 시작 오류', 'OK', 'Error')
        } catch { }
    }
} finally {
    if ($renderModeChanged) {
        [System.Windows.Media.RenderOptions]::ProcessRenderMode = $previousRenderMode
    }
}

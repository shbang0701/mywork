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

# 데이터 폴더 안의 하위 폴더(예: 사용자가 파일을 넣어 두는 곳). -Create면 없을 때 만든다
function Get-WtDataFolder {
    param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name, [switch]$Create)
    $path = Join-Path (Get-WtDataRoot) $Name
    if ($Create -and -not (Test-Path -LiteralPath $path -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($path) }
    $path
}

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
    Get-WtStorePath, Test-WtStore, Get-WtDataFolder, Get-WtStoreStamp, Read-WtStore, Get-WtStoreItems, Write-WtStore, New-WtId,
    Find-WtLegacyFolder, Import-WtLegacyCsv

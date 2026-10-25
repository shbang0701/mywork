# 저장 담당. 기능 모듈은 파일을 직접 읽고 쓰지 않고 이 모듈만 거친다.
# - 데이터는 앱 폴더 밖(기본: 문서\WorkTool)에 둔다. 앱을 새 버전으로 덮어써도 데이터는 그대로다.
# - 저장소(store) 하나 = JSON 파일 하나. 파일마다 schema 번호를 붙여, 형식이 바뀌면 읽을 때 한 단계씩 변환한다.
# - 쓸 때는 임시 파일에 먼저 쓰고 바꿔치기한다. 직전 파일은 .bak으로 하나 남긴다.
# - 읽기 실패는 항상 예외로 올린다. 빈 결과로 넘기면 다음 저장에서 기존 데이터를 덮어쓰기 때문이다.
# - 디스크에 닿는 일($script:io)은 화면 밖(core\Work.psm1)에서 하고 $script:ioTimeoutMs까지만 기다린다. 데이터 폴더가 응답 없는
#   공유 폴더여도 화면이 멈추지 않고 저장 실패(IOException)로 올라간다. 그 폴더에 답 없는 작업이 남아 있으면 기다리지 않고 바로 실패한다.

$ErrorActionPreference = 'Stop'

$script:appRoot = $null
$script:dataRoot = $null
$script:ioTimeoutMs = 5000       # 데이터 폴더가 이 시간 안에 답하지 않으면 기다리지 않고 오류로 올린다
$script:legacyTimeoutMs = 3000   # 예전 데이터 위치 찾기

# 여러 단계인 디스크 작업 (화면 밖 실행 공간에서 돈다. 명령 없이 .NET만 쓴다. 예전 CSV만 Import-Csv). 검사가 응답 없는 폴더를 흉내 내려고 바꿔 끼운다.
# 메서드 하나로 끝나는 읽기 · 있는지 보기 · 폴더 만들기는 Invoke-WtDataCall로 스레드 풀에서 바로 부른다 (가장 빠르다)
$script:io = @{
    Lock = { param($p) [System.IO.File]::Open($p, 'OpenOrCreate', 'ReadWrite', 'None') }
    Unlock = { param($l) $l.Dispose() }
    Write = {
        param($p, $json)
        $tmp = "$p.tmp"
        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.Path]::Exists($p)) { [System.IO.File]::Replace($tmp, $p, "$p.bak") }
        else { [System.IO.File]::Move($tmp, $p) }
    }
    Copy = { param($a, $b) [System.IO.File]::Copy($a, $b, $true) }
    FindLegacy = {
        param($folders)
        foreach ($c in $folders) {
            foreach ($f in 'memo.csv', 'schedule.csv', 'attendance.csv') {
                if ([System.IO.Path]::Exists([System.IO.Path]::Combine($c, $f))) { return $c }
            }
        }
        $null
    }
    ReadCsv = {
        param($p)
        if (-not [System.IO.Path]::Exists($p)) { return $null }
        , @(Import-Csv -LiteralPath $p -Encoding utf8)
    }
}

# 디스크 작업 하나($script:io의 이름)를 화면 밖에서 하고 정한 시간까지만 기다린다. 응답이 없으면 IOException.
# $Key: 같은 곳(데이터 폴더 · 예전 데이터 위치 · 앱 폴더)끼리 묶는다. 답 없는 작업이 남은 곳은 바로 실패한다
function Invoke-WtDataIo {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Op,
        [object[]]$Arguments = @(),
        [string]$Key = 'data',
        [int]$TimeoutMs = $script:ioTimeoutMs,
        [ValidateSet('Empty', 'Default')][string]$Session = 'Empty',
        [string]$Where = '데이터 폴더'
    )
    try { Invoke-WtWork -Script $script:io[$Op] -ArgumentList $Arguments -Key $Key -TimeoutMs $TimeoutMs -Session $Session }
    catch [System.TimeoutException] {
        throw [System.IO.IOException]::new("${Where}가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인하세요.", $_.Exception)
    }
}

# .NET 메서드 하나를 화면 밖(스레드 풀)에서 부르고 정한 시간까지만 기다린다. 응답이 없으면 IOException. 예: (New-WtCall ([System.IO.File]) ReadAllText $p)
function Invoke-WtDataCall {
    param([Parameter(Mandatory, Position = 0)][Delegate]$Call, [string]$Key = 'data', [int]$TimeoutMs = $script:ioTimeoutMs, [string]$Where = '데이터 폴더')
    try { Invoke-WtWork -Call $Call -Key $Key -TimeoutMs $TimeoutMs }
    catch [System.TimeoutException] {
        throw [System.IO.IOException]::new("${Where}가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인하세요.", $_.Exception)
    }
}

# 진입 스크립트가 자기 위치를 알려 준다. 묶음 파일이든 원본 폴더든 같은 방식으로 쓴다.
function Set-WtAppRoot([string]$Path) {
    $script:appRoot = $Path
    $script:dataRoot = $null
}

function Get-WtAppRoot { $script:appRoot }

# 데이터 폴더마다 하나의 앱만 쓴다. 빈 잠금 파일은 남겨 두고 핸들만 해제한다 (Close-WtDataLock).
function Open-WtDataLock {
    $path = Join-Path (Get-WtDataRoot) '.worktool.lock'
    try { Invoke-WtDataIo Lock -Arguments $path }
    catch {
        if ($_.Exception.InnerException -is [System.TimeoutException]) { throw }
        throw '같은 데이터 폴더를 사용하는 WorkTool이 실행 중이거나 폴더를 잠글 수 없습니다. 기존 창·트레이를 확인하세요.'
    }
}

# 잠금을 푼다. 응답 없는 공유 폴더여도 오래 기다리지 않는다 (못 풀면 앱 프로세스가 끝날 때 풀린다)
function Close-WtDataLock($Lock) {
    if (-not $Lock) { return }
    try { [void](Invoke-WtDataIo Unlock -Arguments (, $Lock) -TimeoutMs 2000) } catch { }
}

# 데이터 폴더. 앱 폴더에 datapath.txt가 있으면 그 첫 줄의 경로, 없으면 문서\WorkTool
function Get-WtDataRoot {
    if ($script:dataRoot) { return $script:dataRoot }
    $line = $null
    if ($script:appRoot) {
        $override = Join-Path $script:appRoot 'datapath.txt'
        try { $line = @((Invoke-WtDataCall (New-WtCall ([System.IO.File]) ReadAllText $override) -Key (Get-WtPathKey $override) -Where '앱 폴더') -split "\r?\n", 2)[0] }
        catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { $line = $null }
    }
    $path = if ($line -and $line.Trim()) { [Environment]::ExpandEnvironmentVariables($line.Trim()) } else { $null }
    if (-not $path) {
        # 문서 폴더가 서버로 옮겨져 있어도 여기서 확인하러 가지 않는다 (확인 · 만들기는 아래 화면 밖 작업에서)
        $docs = [Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')
        if (-not $docs) { $docs = $HOME }
        $path = Join-Path $docs 'WorkTool'
    }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    [void](Invoke-WtDataCall (New-WtCall ([System.IO.Directory]) CreateDirectory $full))
    $script:dataRoot = $full
    $script:dataRoot
}

# JSON 파일 하나를 읽는다. 없으면 $null
function Read-WtJsonFile([string]$Path) {
    try { $text = Invoke-WtDataCall (New-WtCall ([System.IO.File]) ReadAllText $Path) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return $null }
    $text | ConvertFrom-Json -Depth 20
}

# JSON 파일 하나를 바꿔치기로 쓴다. 직전 파일은 <파일>.bak
function Write-WtJsonFile([string]$Path, $Data) {
    $json = ConvertTo-Json -InputObject $Data -Depth 20
    [void](Invoke-WtDataIo Write -Arguments $Path, $json)
}

function Get-WtStorePath {
    param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name)
    Join-Path (Get-WtDataRoot) "$Name.json"
}

function Test-WtStore([string]$Name) { Invoke-WtDataCall (New-WtCall ([System.IO.Path]) Exists (Get-WtStorePath $Name)) }

# 데이터 폴더 안의 하위 폴더(예: 사용자가 파일을 넣어 두는 곳). -Create면 없을 때 만든다
function Get-WtDataFolder {
    param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name, [switch]$Create)
    $path = Join-Path (Get-WtDataRoot) $Name
    if ($Create) { [void](Invoke-WtDataCall (New-WtCall ([System.IO.Directory]) CreateDirectory $path)) }
    $path
}

# 화면에서 변경 여부를 판단하는 표식: 내용의 크기 · 해시. 같은 크기 · 시각으로 덮어쓴 외부 변경도 놓치지 않는다.
# 다른 프로그램(동기화 · 백신 등)이 잡고 있어 못 읽거나 데이터 폴더가 답하지 않으면 매번 다른 표식을 돌려줘, 화면이 그냥 다시 읽게 한다
# (읽기 실패는 다시 읽을 때 알린다)
function Get-WtStoreStamp([string]$Name) {
    $path = Get-WtStorePath $Name
    try { $bytes = Invoke-WtDataCall (New-WtCall ([System.IO.File]) ReadAllBytes $path) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return "$path|missing" }
    catch { return "$path|unread-$([guid]::NewGuid().ToString('N'))" }
    "$path|$($bytes.Length)|$([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([byte[]]$bytes)))"
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
        [void](Invoke-WtDataIo Copy -Arguments $path, "$path.schema$from.bak")
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

# 예전 데이터 폴더를 찾는다. 설정에 적은 위치 → 이 파일 옆 data → 한 단계 위 data 순서.
# 설정한 위치가 응답하지 않으면 못 찾은 것으로 본다 (화면이 기다리지 않게)
function Find-WtLegacyFolder {
    $candidates = [System.Collections.Generic.List[string]]::new()
    $custom = Get-WtSetting 'legacy.path'
    if ($custom) { $candidates.Add([string]$custom) }
    if ($script:appRoot) {
        $candidates.Add((Join-Path $script:appRoot 'data'))
        $candidates.Add((Join-Path (Split-Path $script:appRoot -Parent) 'data'))
    }
    $full = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $candidates) { try { $full.Add($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($c)) } catch { } }
    if (-not $full.Count) { return $null }
    try { Invoke-WtDataIo FindLegacy -Arguments (, $full.ToArray()) -Key 'legacy' -TimeoutMs $script:legacyTimeoutMs -Where '예전 데이터 위치' }
    catch { $null }
}

# 예전 CSV 하나를 읽는다. 파일이 없으면 $null (빈 파일이면 빈 배열)
function Import-WtLegacyCsv([string]$Folder, [string]$Name) {
    Invoke-WtDataIo ReadCsv -Arguments (Join-Path $Folder "$Name.csv") -Key 'legacy' -Where '예전 데이터 위치' -Session Default
}

Export-ModuleMember -Function Set-WtAppRoot, Get-WtAppRoot, Get-WtDataRoot, Open-WtDataLock, Close-WtDataLock, Read-WtJsonFile, Write-WtJsonFile,
    Get-WtStorePath, Test-WtStore, Get-WtDataFolder, Get-WtStoreStamp, Read-WtStore, Get-WtStoreItems, Write-WtStore, New-WtId,
    Find-WtLegacyFolder, Import-WtLegacyCsv

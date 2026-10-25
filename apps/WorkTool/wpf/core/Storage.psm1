# 저장 담당. 기능 모듈은 파일을 직접 읽고 쓰지 않고 이 모듈만 거친다.
# - 데이터는 앱 폴더 밖(기본: 문서\WorkTool)에 둔다. 앱을 새 버전으로 덮어써도 데이터는 그대로다.
# - 저장소(store) 하나 = JSON 파일 하나. 파일마다 schema 번호를 붙여, 형식이 바뀌면 읽을 때 한 단계씩 변환한다.
# - 쓸 때는 임시 파일에 먼저 쓰고 바꿔치기한다. 직전 파일은 .bak으로 하나 남긴다.
# - 읽기 실패는 항상 예외로 올린다. 빈 결과로 넘기면 다음 저장에서 기존 데이터를 덮어쓰기 때문이다.
# - 읽기는 화면 밖(core\Work.psm1)에서 하고 $script:ioTimeoutMs까지만 기다린다. 데이터 폴더가 응답 없는 공유 폴더여도 화면이 멈추지 않고
#   읽기 실패(IOException)로 올라간다. 그 폴더에 답 없는 읽기가 남아 있으면 기다리지 않고 바로 실패한다.
# - 쓰기는 저장 통로(Submit-WtDataWrite)가 한 번에 하나씩 들어온 차례대로 한다. 읽기 작업과 따로라 읽기가 많이 남아도 막히지 않는다.
#   쓰기는 끝나거나 실패가 정해질 때까지 통로가 맡는다(시간이 지나도 버리지 않는다). 화면은 $script:writeWaitMs까지만 기다리고,
#   그 안에 끝나지 않으면 「저장 중」이다(실패로 정하지 않는다). 그동안 그 파일을 읽으면 저장 중인 내용을 돌려준다.
#   셸은 끝내기 · 화면 이동 전에 저장 중인 것이 있으면 끝날 때까지 기다리거나(창이 멈추지 않게) 사용자에게 묻는다.

$ErrorActionPreference = 'Stop'

$script:appRoot = $null
$script:dataRoot = $null
$script:ioTimeoutMs = 5000       # 데이터 폴더가 이 시간 안에 답하지 않으면 기다리지 않고 오류로 올린다
$script:legacyTimeoutMs = 3000   # 예전 데이터 위치 찾기
$script:writeWaitMs = 400        # 저장할 때 화면이 기다리는 시간. 로컬 저장은 이 안에 끝난다. 넘으면 저장 통로가 끝까지 맡는다
$script:writeSlowMs = 5000       # 이보다 오래 걸리는 저장은 「응답 없음」으로 보인다 (실패로 정하지는 않는다)
$script:writeQueue = [System.Collections.Generic.List[object]]::new()   # 차례를 기다리는 쓰기 (파일마다 마지막 내용 하나)
$script:writeCurrent = $null     # 지금 쓰는 것
$script:writeHandlers = [System.Collections.Generic.List[scriptblock]]::new()

# 여러 단계인 디스크 작업 (화면 밖 실행 공간에서 돈다. 명령 없이 .NET만 쓴다. 예전 CSV만 Import-Csv). 검사가 응답 없는 폴더를 흉내 내려고 바꿔 끼운다.
# 메서드 하나로 끝나는 읽기 · 있는지 보기 · 폴더 만들기는 Invoke-WtDataCall로 스레드 풀에서 바로 부른다 (가장 빠르다)
$script:io = @{
    Lock = { param($p) [System.IO.File]::Open($p, 'OpenOrCreate', 'ReadWrite', 'None') }
    Unlock = { param($l) $l.Dispose() }
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
        [string]$Where = '데이터 폴더',
        [switch]$Reserved
    )
    try { Invoke-WtWork -Script $script:io[$Op] -ArgumentList $Arguments -Key $Key -TimeoutMs $TimeoutMs -Session $Session -Reserved:$Reserved }
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
    try { Invoke-WtDataIo Lock -Arguments $path -Reserved }
    catch {
        if ($_.Exception.InnerException -is [System.TimeoutException]) { throw }
        throw '같은 데이터 폴더를 사용하는 WorkTool이 실행 중이거나 폴더를 잠글 수 없습니다. 기존 창·트레이를 확인하세요.'
    }
}

# 잠금을 푼다. 응답 없는 공유 폴더여도 오래 기다리지 않는다 (못 풀면 앱 프로세스가 끝날 때 풀린다)
function Close-WtDataLock($Lock) {
    if (-not $Lock) { return }
    try { [void](Invoke-WtDataIo Unlock -Arguments (, $Lock) -TimeoutMs 2000 -Reserved) } catch { }
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

# JSON 파일 하나를 읽는다. 없으면 $null. 저장 중인 내용이 있으면 디스크 대신 그것을 돌려준다 (방금 저장한 것을 바로 읽을 수 있게)
function Read-WtJsonFile([string]$Path) {
    $pending = Get-WtDataWritePending $Path
    if ($pending) { return $pending.Json | ConvertFrom-Json -Depth 20 }
    try { $text = Invoke-WtDataCall (New-WtCall ([System.IO.File]) ReadAllText $Path) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { return $null }
    $text | ConvertFrom-Json -Depth 20
}

<#
JSON 파일 하나를 바꿔치기로 쓴다. 직전 파일은 <파일>.bak. 저장 통로에 넣고 $script:writeWaitMs까지만 기다린다.
  끝났으면 돌아오고, 실패했으면 그 예외를 올린다.
  아직 쓰는 중이면 IOException(Data['WtSavePending'])을 올린다. 실패가 아니다: 통로가 끝까지 쓰고, 그동안 읽으면 이 내용이 나온다.
  -AllowPending: 쓰는 중이어도 그냥 돌아온다 (설정 · 실행 기록처럼 통로에 맡기면 되는 것)
#>
function Write-WtJsonFile([string]$Path, $Data, [switch]$AllowPending) {
    $json = ConvertTo-Json -InputObject $Data -Depth 20
    $entry = Submit-WtDataWrite $Path $json
    Wait-WtDataWrite $entry $script:writeWaitMs
    if ($entry.State -eq 'done' -or $entry.State -eq 'superseded') { return }
    if ($entry.State -eq 'failed') { throw $entry.Exception }
    $entry.Released = $true   # 부른 쪽은 결과를 받지 못했다. 나중에 실패로 정해지면 통로가 알린다 (Complete-WtDataWrite)
    if ($AllowPending) { return }
    $e = [System.IO.IOException]::new('저장하는 중입니다. 데이터 폴더가 늦게 답하고 있어, 답이 오면 이어서 저장합니다.')
    $e.Data['WtSavePending'] = $true
    throw $e
}

# 저장 중이라서 올린 예외인지 (실패가 아니다)
function Test-WtSavePending($Exception) { $Exception -is [Exception] -and $Exception.Data.Contains('WtSavePending') }

# ---- 저장 통로 --------------------------------------------------------------------------------

# 실제로 쓰기 (화면 밖에서 돈다): 임시 파일에 쓰고 바꿔치기
function Write-WtDataFile([string]$Path, [string]$Json) {
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Json, [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.Path]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, "$Path.bak") }
    else { [System.IO.File]::Move($tmp, $Path) }
}

# 통로가 돌리는 코드. 검사는 쓰기 앞에 기다림만 끼워 넣는다 (Write-WtDataFile은 그대로 돈다)
$script:writeJob = { param($p, $json) Write-WtDataFile $p $json }

# 쓰기 하나를 통로에 넣는다. 같은 파일의 아직 시작하지 않은 쓰기는 새 내용으로 바꾼다 (마지막 내용만 쓰면 된다)
function Submit-WtDataWrite([string]$Path, [string]$Json) {
    for ($i = $script:writeQueue.Count - 1; $i -ge 0; $i--) {
        if ($script:writeQueue[$i].Path -ieq $Path) { $script:writeQueue[$i].State = 'superseded'; $script:writeQueue.RemoveAt($i) }
    }
    $entry = @{ Path = $Path; Json = $Json; State = 'queued'; Work = $null; Exception = $null; Released = $false; Watch = [System.Diagnostics.Stopwatch]::StartNew() }
    $script:writeQueue.Add($entry)
    Start-WtDataWriteNext
    $entry
}

# 쓰는 것이 없으면 다음 차례를 시작한다. 한 번에 하나만 쓴다 (같은 임시 파일 · 바꿔치기가 겹치지 않게)
function Start-WtDataWriteNext {
    while (-not $script:writeCurrent -and $script:writeQueue.Count) {
        $entry = $script:writeQueue[0]
        $script:writeQueue.RemoveAt(0)
        $entry.State = 'writing'
        try {
            $script:writeCurrent = $entry
            if (-not $script:writeFunctions) { $script:writeFunctions = @(Get-Command Write-WtDataFile) }
            $entry.Work = Start-WtWork -Script $script:writeJob -ArgumentList $entry.Path, $entry.Json -Functions $script:writeFunctions -Reserved `
                -Context $entry -OnDone { param($w) Complete-WtDataWrite $w }
        } catch {
            $script:writeCurrent = $null
            $entry.State = 'failed'; $entry.Exception = $_.Exception
        }
    }
}
$script:writeFunctions = $null

# 쓰기 하나가 끝났을 때 (화면 스레드): 결과를 적고 다음 차례를 시작한 뒤, 기다리는 화면에 알린다.
# 부른 쪽이 결과를 받지 못한 쓰기가 실패로 정해졌고 같은 파일에 뒤따르는 쓰기도 없으면, 사용자에게도 알린다 (조용히 잃지 않게)
function Complete-WtDataWrite($Work) {
    $entry = $Work.Context
    if ($Work.State -eq 'done') { $entry.State = 'done' }
    else {
        $entry.State = 'failed'
        $entry.Exception = if ($Work.Exception) { $Work.Exception } else { [System.IO.IOException]::new("저장하지 못했습니다. $($Work.Error)") }
    }
    if ([object]::ReferenceEquals($script:writeCurrent, $entry)) { $script:writeCurrent = $null }
    $tell = $entry.State -eq 'failed' -and $entry.Released -and -not (Get-WtDataWritePending $entry.Path)
    Start-WtDataWriteNext
    Invoke-WtDataWriteHandlers $entry $tell
}

# 이 쓰기가 끝날 때까지 정한 시간만 기다린다. 앞 차례가 이미 오래 걸리면(응답 없는 폴더) 기다리지 않는다
function Wait-WtDataWrite($Entry, [int]$Milliseconds) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Entry.State -eq 'queued' -or $Entry.State -eq 'writing') {
        $left = $Milliseconds - $watch.ElapsedMilliseconds
        if ($left -le 0) { break }
        $current = $script:writeCurrent
        if (-not $current) { break }
        if (-not [object]::ReferenceEquals($current, $Entry) -and $current.Watch.ElapsedMilliseconds -ge $Milliseconds) { break }
        [void](Wait-WtWork $current.Work -Milliseconds $left)
        if (-not $current.Work.Finished) { break }
    }
}

# 이 파일에 아직 끝나지 않은 쓰기 (가장 나중 것)
function Get-WtDataWritePending([string]$Path) {
    for ($i = $script:writeQueue.Count - 1; $i -ge 0; $i--) { if ($script:writeQueue[$i].Path -ieq $Path) { return $script:writeQueue[$i] } }
    if ($script:writeCurrent -and $script:writeCurrent.Path -ieq $Path) { return $script:writeCurrent }
    $null
}

# 저장 중인 것이 있는지
function Test-WtDataWriting { [bool]($script:writeCurrent -or $script:writeQueue.Count) }

# 사용자가 「저장을 기다리지 않고 끝내기」를 골랐을 때만 셸이 부른다. 남은 쓰기를 버린다 (임시 파일에 쓰는 중이면 원래 파일은 그대로다)
function Stop-WtDataWrites {
    foreach ($e in $script:writeQueue) { $e.State = 'dropped' }
    $script:writeQueue.Clear()
    if ($script:writeCurrent) {
        $script:writeCurrent.State = 'dropped'
        Stop-WtWork $script:writeCurrent.Work
        $script:writeCurrent = $null
    }
}

# 저장 통로 상태: 남은 수 · 「응답 없음」(지금 쓰는 것이 $script:writeSlowMs를 넘김) · 걸린 초
function Get-WtDataWriteState {
    $current = $script:writeCurrent
    $ms = if ($current) { $current.Watch.ElapsedMilliseconds } else { 0 }
    [pscustomobject]@{ Count = $script:writeQueue.Count + [int][bool]$current; Slow = $ms -ge $script:writeSlowMs; Seconds = [int][Math]::Floor($ms / 1000) }
}

# 쓰기가 끝날 때(성공 · 실패) 부를 처리기 { param($path, $state) }. 나중에(화면 스레드가 한가할 때) 부른다
function Register-WtDataWriteHandler([scriptblock]$Handler) { $script:writeHandlers.Add($Handler) }

# 끝난 쓰기를 차례대로 모아 두고, 화면 스레드가 한가할 때 한 번에 알린다 (처리기 안에서 다시 저장해도 이 함수 안에서 겹치지 않게)
function Invoke-WtDataWriteHandlers($Entry, [bool]$Tell) {
    if (-not $script:writeHandlers.Count -and -not $Tell) { return }
    $type = 'System.Windows.Threading.Dispatcher' -as [type]
    $dispatcher = if ($type) { [System.Windows.Threading.Dispatcher]::FromThread([System.Threading.Thread]::CurrentThread) } else { $null }
    if (-not $dispatcher) { return }
    $script:writeNotices.Add(@{ Path = $Entry.Path; State = $Entry.State; Tell = $Tell; Message = if ($Entry.Exception) { $Entry.Exception.Message } else { '' } })
    if ($script:writeNoticeQueued) { return }
    $script:writeNoticeQueued = $true
    [void]$dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ Send-WtDataWriteNotices })
}

function Send-WtDataWriteNotices {
    $script:writeNoticeQueued = $false
    $list = @($script:writeNotices.ToArray()); $script:writeNotices.Clear()
    foreach ($n in $list) {
        if ($n.Tell) {
            $name = [System.IO.Path]::GetFileName($n.Path)
            try { Show-WtMessage "데이터 폴더에 저장하지 못했습니다 ($name).`n$($n.Message)`n`n다음에 저장할 때 다시 씁니다." 'WorkTool' 'Warning' } catch { }
        }
        foreach ($h in @($script:writeHandlers)) { try { [void](& $h $n.Path $n.State) } catch { } }
    }
}
$script:writeNotices = [System.Collections.Generic.List[object]]::new()
$script:writeNoticeQueued = $false

function Get-WtStorePath {
    param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name)
    Join-Path (Get-WtDataRoot) "$Name.json"
}

function Test-WtStore([string]$Name) {
    $path = Get-WtStorePath $Name
    if (Get-WtDataWritePending $path) { return $true }
    Invoke-WtDataCall (New-WtCall ([System.IO.Path]) Exists $path)
}

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
    # 저장 중인 내용은 다 쓴 뒤의 파일과 같은 표식이 되게 같은 바이트(UTF-8, BOM 없음)로 잰다
    $pending = Get-WtDataWritePending $path
    if ($pending) {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($pending.Json)
        return "$path|$($bytes.Length)|$([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)))"
    }
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
        Write-WtStore -Name $Name -Schema $Schema -Items @($doc.items) -AllowPending
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
        [hashtable]$Extra,
        [switch]$AllowPending   # 쓰는 중이어도 그냥 돌아온다 (Write-WtJsonFile 참고)
    )
    $doc = [ordered]@{ schema = $Schema; saved = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }
    if ($Extra) { foreach ($k in $Extra.Keys) { $doc[$k] = $Extra[$k] } }
    $doc['items'] = @($Items | Where-Object { $null -ne $_ })
    Write-WtJsonFile (Get-WtStorePath $Name) $doc -AllowPending:$AllowPending
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
    Test-WtSavePending, Test-WtDataWriting, Get-WtDataWriteState, Register-WtDataWriteHandler, Stop-WtDataWrites,
    Get-WtStorePath, Test-WtStore, Get-WtDataFolder, Get-WtStoreStamp, Read-WtStore, Get-WtStoreItems, Write-WtStore, New-WtId,
    Find-WtLegacyFolder, Import-WtLegacyCsv

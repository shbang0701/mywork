# 저장 담당. 기능 모듈은 파일을 직접 읽고 쓰지 않고 이 모듈만 거친다.
# - 데이터는 앱 폴더 밖(기본: 문서\WorkTool)에 둔다. 앱을 새 버전으로 덮어써도 데이터는 그대로다.
# - 저장소(store) 하나 = JSON 파일 하나. 파일마다 schema 번호를 붙여, 형식이 바뀌면 읽을 때 한 단계씩 변환한다.
#   schema는 옛 앱이 잘못 읽게 되는 변경에만 올린다(칸 · 값을 더하는 것은 올리지 않는다). 더 새 schema 파일은 읽지 않는다.
#   변환하기 전 원본은 날짜 붙은 백업(<이름>.json.schema1.20261025-215429.bak)으로 남기고 덮어쓰지 않는다. 변환에 실패하면 원본을 건드리지 않는다.
# - 읽을 때 날짜처럼 보이는 글을 [datetime]으로 바꾸지 않는다(-DateKind String). 글은 쓴 그대로 돌아온다.
# - 맨 위의 모르는 키(importedFrom · 더 새 앱이 더한 키)는 기억해 두었다가 쓸 때 같이 쓴다. 변환할 때도 잃지 않는다.
# - 쓸 때는 임시 파일에 먼저 쓰고 바꿔치기한다. 직전 파일은 .bak으로 하나 남긴다.
# - 날짜 모양 · 지운 표시 · 예전 데이터 합치기 같은 형식 규칙은 Records.psm1, 칸의 뜻은 탭이 정한다.
# - 읽기 실패는 항상 예외로 올린다. 빈 결과로 넘기면 다음 저장에서 기존 데이터를 덮어쓰기 때문이다.
# - 읽기는 화면 밖(core\Work.psm1)에서 하고 $script:ioTimeoutMs까지만 기다린다. 데이터 폴더가 응답 없는 공유 폴더여도 화면이 멈추지 않고
#   읽기 실패(IOException)로 올라간다. 그 폴더에 답 없는 읽기가 남아 있으면 기다리지 않고 바로 실패한다.
# - 쓰기는 저장 통로(Submit-WtDataWrite)가 한 번에 하나씩 들어온 차례대로 한다. 읽기 작업과 따로라 읽기가 많이 남아도 막히지 않는다.
#   화면은 $script:writeWaitMs까지만 기다린다. 넣은 쓰기는 넣는 순간 받아들인 것이다: 통로가 파일에 쓰였다고 확인될 때까지 가지고 있고,
#   실패하면(바로 · 시작에서 · 늦게, 모두 같은 길) 다시 시도하거나 사용자가 버리기를 고를 때까지 둔다. 그동안 그 파일을 읽으면 그 내용을 돌려준다.
#   저장 상태는 시간이 아니라 파일마다의 버전으로 정한다(받아들인 버전 = 확인된 버전이면 저장됨, Get-WtDataWriteStatus).
#   셸은 끝내기 전에 쓰는 중이면 끝날 때까지 기다리고(창이 멈추지 않게), 쓰지 못한 내용이 있으면 사용자에게 묻는다.

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
    # 변환 전 백업: 이미 있는 파일은 덮어쓰지 않고 -2 · -3 …을 붙인다. $text가 있으면(아직 파일에 쓰이지 않은 내용) 그 글을 쓴다
    Backup = {
        param($p, $stem, $text)
        for ($n = 1; $n -lt 1000; $n++) {
            $b = if ($n -eq 1) { "$stem.bak" } else { "$stem-$n.bak" }
            if ([System.IO.Path]::Exists($b)) { continue }
            if ($null -ne $text) {
                $s = [System.IO.FileStream]::new($b, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
                try { $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$text); $s.Write($bytes, 0, $bytes.Length) } finally { $s.Dispose() }
            } else { [System.IO.File]::Copy($p, $b, $false) }
            return $b
        }
        throw [System.IO.IOException]::new("백업 파일 이름을 정하지 못했습니다: $stem")
    }
    FindLegacy = {
        param($folders)
        foreach ($c in $folders) {
            foreach ($f in 'memo.csv', 'schedule.csv', 'attendance.csv') {
                if ([System.IO.Path]::Exists([System.IO.Path]::Combine($c, $f))) { return $c }
            }
        }
        $null
    }
    # 예전 CSV: WinForms는 BOM 붙은 UTF-8로 쓴다. Excel에서 「CSV(쉼표로 분리)」로 다시 저장하면 BOM 없는 CP949가 될 수 있어서,
    # UTF-8로 읽히지 않으면 CP949로 읽는다(한글이 깨진 채로 가져오지 않게). 내용의 해시도 같이 돌려준다(바뀌었는지 알아보는 데 쓴다)
    ReadCsv = {
        param($p)
        if (-not [System.IO.Path]::Exists($p)) { return $null }
        $bytes = [System.IO.File]::ReadAllBytes($p)
        $enc = 'utf-8'
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes, 3, $bytes.Length - 3)
        } else {
            try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
            catch { $text = [System.Text.Encoding]::GetEncoding(949).GetString($bytes); $enc = 'cp949' }
        }
        $rows = if ($text.Trim()) { @(ConvertFrom-Csv -InputObject $text) } else { @() }
        @{ Rows = $rows; Sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)); Encoding = $enc }
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
    $script:storeTops = @{}
    $script:storeRead = @{}
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

# JSON 파일 하나를 읽는다. 없으면 $null. 아직 파일에 쓰이지 않은 내용(쓰는 중 · 늦게 실패해 앱이 가진 것)이 있으면
# 디스크 대신 그것을 돌려준다. 앱이 가진 내용과 화면이 늘 같게.
# 날짜처럼 보이는 글("2026-10-25T21:54:29")도 글 그대로 둔다. 기본값이면 [datetime]으로 바뀌고, 다시 글로 쓰면 문화권 모양이 된다
function Read-WtJsonFile([string]$Path) {
    $text = Read-WtJsonText $Path
    if ($null -eq $text) { return $null }
    $text | ConvertFrom-Json -Depth 20 -DateKind String
}

# JSON 파일의 글. 파일이 없으면 $null (빈 파일이면 ''). 아직 파일에 쓰이지 않은 내용이 있으면 그 글
function Read-WtJsonText([string]$Path) {
    $pending = Get-WtDataWritePending $Path
    if ($pending) { return [string]$pending.Json }
    try { Invoke-WtDataCall (New-WtCall ([System.IO.File]) ReadAllText $Path) }
    catch [System.IO.FileNotFoundException], [System.IO.DirectoryNotFoundException] { $null }
}

<#
JSON 파일 하나를 바꿔치기로 쓴다. 직전 파일은 <파일>.bak. 저장 통로에 넣고 $script:writeWaitMs까지만 기다린다.
들어온 순간 받아들인 내용이다(버전을 받는다). 그 버전은 파일에 쓰였다고 확인되거나(저장됨), 실패하면 앱이 가지고 있다가
다시 시도하거나 사용자가 버리기를 고를 때까지 둔다 — 둘 중 하나로만 끝난다. 그래서 쓰기 실패로는 예외를 올리지 않는다.
  바로 실패 · 쓰기 시작 실패 · 늦은 실패 모두 같은 길(Set-WtDataWriteFailed)로 남는다. 실패는 한 번 알리고, 셸이 끝내기 전에 묻는다.
  기다리는 시간은 화면이 얼마나 기다릴지만 정한다. 저장 상태(저장됨 · 쓰는 중 · 실패)는 Get-WtDataWriteStatus가 버전으로 정한다
#>
function Write-WtJsonFile([string]$Path, $Data) {
    $json = ConvertTo-Json -InputObject $Data -Depth 20
    $entry = Submit-WtDataWrite $Path $json
    Wait-WtDataWrite $entry $script:writeWaitMs
}

# ---- 저장 통로 --------------------------------------------------------------------------------
# 파일마다 버전을 센다: 넣은 쓰기마다 버전이 하나씩 오르고, 넣은 순간 받아들인 버전(Accepted)이 된다.
#   확인된 버전(Confirmed): 파일에 쓰였다고 확인된 가장 새 버전
# 받아들인 버전 > 확인된 버전인데 쓰는 중인 것이 없으면, 그 내용을 실패로 남겨 둔다(Failed). 버전이 같아져야 「저장됨」이다

# 실제로 쓰기 (화면 밖에서 돈다): 임시 파일에 쓰고 바꿔치기
function Write-WtDataFile([string]$Path, [string]$Json) {
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Json, [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.Path]::Exists($Path)) { [System.IO.File]::Replace($tmp, $Path, "$Path.bak") }
    else { [System.IO.File]::Move($tmp, $Path) }
}

# 통로가 돌리는 코드. 검사는 쓰기 앞에 기다림만 끼워 넣는다 (Write-WtDataFile은 그대로 돈다)
$script:writeJob = { param($p, $json) Write-WtDataFile $p $json }

# 파일 하나의 기록 (버전 · 받아들인 것 · 실패로 남은 것)
function Get-WtDataFileRecord([string]$Path) {
    $k = $Path.ToLowerInvariant()
    if (-not $script:writeFiles.ContainsKey($k)) {
        $script:writeFiles[$k] = @{ Path = $Path; Version = 0; Accepted = $null; Confirmed = 0; Failed = $null; LastError = $null; Told = $false }
    }
    $script:writeFiles[$k]
}

# 쓰기 하나를 통로에 넣는다. 넣는 순간 받아들인 버전이 된다.
# 같은 파일의 아직 시작하지 않은 쓰기는 새 내용으로 바꾼다 (새 내용이 앞 내용을 담고 있다)
function Submit-WtDataWrite([string]$Path, [string]$Json) {
    $rec = Get-WtDataFileRecord $Path
    for ($i = $script:writeQueue.Count - 1; $i -ge 0; $i--) {
        if ($script:writeQueue[$i].Path -ieq $Path) { $script:writeQueue[$i].State = 'superseded'; $script:writeQueue.RemoveAt($i) }
    }
    $rec.Version++
    $entry = @{ Path = $Path; Json = $Json; Version = $rec.Version; State = 'queued'; Work = $null; Exception = $null; Watch = [System.Diagnostics.Stopwatch]::StartNew() }
    $rec.Accepted = $entry
    $rec.Failed = $null   # 실패로 남아 있던 앞 내용은 이 내용이 담고 있다. 이 쓰기도 실패하면 이 내용이 남는다
    $script:writeQueue.Add($entry)
    Start-WtDataWriteNext
    $entry
}

# 쓰는 것이 없으면 다음 차례를 시작한다. 한 번에 하나만 쓴다 (같은 임시 파일 · 바꿔치기가 겹치지 않게).
# 시작 자체가 실패해도 늦은 실패와 같은 길로 남기고 다음 차례로 간다
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
            Set-WtDataWriteFailed $entry $_.Exception
        }
    }
}
$script:writeFunctions = $null

# 쓰기 하나가 끝났을 때 (화면 스레드): 성공이면 확인된 버전을 올리고, 실패면 실패로 남긴다. 그 뒤 다음 차례를 시작한다
function Complete-WtDataWrite($Work) {
    $entry = $Work.Context
    if ([object]::ReferenceEquals($script:writeCurrent, $entry)) { $script:writeCurrent = $null }
    if ($Work.State -eq 'done') {
        $entry.State = 'done'
        $rec = Get-WtDataFileRecord $entry.Path
        if ($entry.Version -gt $rec.Confirmed) { $rec.Confirmed = $entry.Version }
        Update-WtDataFileState $rec
    } else {
        Set-WtDataWriteFailed $entry $(if ($Work.Exception) { $Work.Exception } else { [System.IO.IOException]::new("저장하지 못했습니다. $($Work.Error)") })
    }
    Start-WtDataWriteNext
}

# 쓰기 실패가 지나는 단 하나의 길 (바로 실패 · 시작 실패 · 늦은 실패): 이유를 적고, 받아들인 내용을 실패로 남기고, 알린다
function Set-WtDataWriteFailed($Entry, [Exception]$Exception) {
    $Entry.State = 'failed'
    $Entry.Exception = $Exception
    $rec = Get-WtDataFileRecord $Entry.Path
    $rec.LastError = $Exception
    Update-WtDataFileState $rec
}

# 버전을 맞추고(실패로 남기기 · 지우기) 화면에 알린다. 실패로 남으면 저장될 때까지 한 번만 알린다
function Update-WtDataFileState($Rec) {
    $acc = $Rec.Accepted
    $flying = Get-WtDataWriteFlying $Rec.Path
    if (-not $acc -or $acc.Version -le $Rec.Confirmed) { $Rec.Failed = $null }
    elseif ($flying -and $flying.Version -ge $acc.Version) { $Rec.Failed = $null }   # 그 내용(이나 더 새 내용)을 쓰는 중이다
    elseif (-not $Rec.Failed -or $Rec.Failed.Version -lt $acc.Version) {
        $Rec.Failed = @{ Path = $acc.Path; Json = $acc.Json; Version = $acc.Version
            Exception = if ($acc.Exception) { $acc.Exception } elseif ($Rec.LastError) { $Rec.LastError } else { [System.IO.IOException]::new('저장하지 못했습니다.') } }
    }
    $tell = $false
    if ($Rec.Failed) { if (-not $Rec.Told) { $tell = $true; $Rec.Told = $true } }
    elseif (-not $flying) { $Rec.Told = $false }
    Invoke-WtDataWriteHandlers $Rec $tell
}
# 이 파일을 쓰는 중이거나 차례를 기다리는 것 중 가장 새 것
function Get-WtDataWriteFlying([string]$Path) {
    for ($i = $script:writeQueue.Count - 1; $i -ge 0; $i--) { if ($script:writeQueue[$i].Path -ieq $Path) { return $script:writeQueue[$i] } }
    if ($script:writeCurrent -and $script:writeCurrent.Path -ieq $Path) { return $script:writeCurrent }
    $null
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

# 이 파일에 아직 파일에 쓰이지 않은 내용: 쓰는 중인 가장 새 것, 없으면 실패로 남은 것
function Get-WtDataWritePending([string]$Path) {
    $flying = Get-WtDataWriteFlying $Path
    if ($flying) { return $flying }
    $k = $Path.ToLowerInvariant()
    if ($script:writeFiles.ContainsKey($k)) { return $script:writeFiles[$k].Failed }
    $null
}

<#
파일 하나의 저장 상태. 시간이 아니라 버전으로 정한다.
  State: saved(받아들인 내용이 파일에 쓰였다) · writing(쓰는 중이거나 차례를 기다림) · failed(쓰지 못한 내용을 앱이 가지고 있음)
  Message: failed일 때 이유
#>
function Get-WtDataWriteStatus([string]$Path) {
    if (Get-WtDataWriteFlying $Path) { return [pscustomobject]@{ State = 'writing'; Message = '' } }
    $k = $Path.ToLowerInvariant()
    $failed = if ($script:writeFiles.ContainsKey($k)) { $script:writeFiles[$k].Failed } else { $null }
    if ($failed) { return [pscustomobject]@{ State = 'failed'; Message = [string]$failed.Exception.Message } }
    [pscustomobject]@{ State = 'saved'; Message = '' }
}

# 쓰지 못한 내용을 앱이 가지고 있는 파일들 @{ Path; Name; Message }
function Get-WtDataUnsaved {
    foreach ($rec in @($script:writeFiles.Values)) {
        if ($rec.Failed -and -not (Get-WtDataWriteFlying $rec.Path)) {
            [pscustomobject]@{ Path = $rec.Path; Name = [System.IO.Path]::GetFileName($rec.Path); Message = [string]$rec.Failed.Exception.Message }
        }
    }
}

# 쓰지 못한 내용을 다시 쓴다 (사용자가 [다시 시도] · Ctrl+S를 눌렀을 때). -Path가 없으면 모두. 화면은 정한 시간만 기다린다
function Resume-WtDataWrites([string]$Path = '') {
    $entries = foreach ($rec in @($script:writeFiles.Values)) {
        if (-not $rec.Failed -or ($Path -and $rec.Path -ine $Path) -or (Get-WtDataWriteFlying $rec.Path)) { continue }
        Submit-WtDataWrite $rec.Path $rec.Failed.Json
    }
    foreach ($e in @($entries)) { Wait-WtDataWrite $e $script:writeWaitMs }
}

# 저장 중이거나 쓰지 못한 내용이 있는지
function Test-WtDataWriting { [bool]($script:writeCurrent -or $script:writeQueue.Count) }

# 사용자가 「저장하지 않고 끝내기」를 골랐을 때만 셸이 부른다. 남은 쓰기와 쓰지 못한 내용을 버린다
# (임시 파일에 쓰는 중이면 원래 파일은 그대로다)
function Stop-WtDataWrites {
    foreach ($e in $script:writeQueue) { $e.State = 'dropped' }
    $script:writeQueue.Clear()
    if ($script:writeCurrent) {
        $script:writeCurrent.State = 'dropped'
        Stop-WtWork $script:writeCurrent.Work
        $script:writeCurrent = $null
    }
    foreach ($rec in @($script:writeFiles.Values)) { $rec.Failed = $null; $rec.Accepted = $null }
}

# 저장 통로 상태: 남은 수 · 「응답 없음」(지금 쓰는 것이 $script:writeSlowMs를 넘김) · 걸린 초
function Get-WtDataWriteState {
    $current = $script:writeCurrent
    $ms = if ($current) { $current.Watch.ElapsedMilliseconds } else { 0 }
    [pscustomobject]@{ Count = $script:writeQueue.Count + [int][bool]$current; Slow = $ms -ge $script:writeSlowMs; Seconds = [int][Math]::Floor($ms / 1000) }
}

# 파일 저장 상태가 바뀔 때(쓰기가 끝남 · 실패로 남음 · 다시 써서 저장됨) 부를 처리기 { param($path, $state) }.
# $state는 Get-WtDataWriteStatus의 State. 나중에(화면 스레드가 한가할 때) 부른다
function Register-WtDataWriteHandler([scriptblock]$Handler) { $script:writeHandlers.Add($Handler) }

# 알릴 것을 모아 두고, 화면 스레드가 한가할 때 한 번에 알린다 (처리기 안에서 다시 저장해도 이 함수 안에서 겹치지 않게)
function Invoke-WtDataWriteHandlers($Rec, [bool]$Tell) {
    if (-not $script:writeHandlers.Count -and -not $Tell) { return }
    $type = 'System.Windows.Threading.Dispatcher' -as [type]
    $dispatcher = if ($type) { [System.Windows.Threading.Dispatcher]::FromThread([System.Threading.Thread]::CurrentThread) } else { $null }
    if (-not $dispatcher) { return }
    $script:writeNotices.Add(@{ Path = $Rec.Path; Tell = $Tell; Message = if ($Rec.Failed) { [string]$Rec.Failed.Exception.Message } else { '' } })
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
            try { Show-WtMessage "데이터 폴더에 저장하지 못했습니다 ($name).`n$($n.Message)`n`n그 내용은 앱이 가지고 있습니다. 다시 저장하거나(메모는 Ctrl+S), 끝낼 때 다시 시도할지 묻습니다." 'WorkTool' 'Warning' } catch { }
        }
        $state = (Get-WtDataWriteStatus $n.Path).State
        foreach ($h in @($script:writeHandlers)) { try { [void](& $h $n.Path $state) } catch { } }
    }
}
$script:writeNotices = [System.Collections.Generic.List[object]]::new()
$script:writeNoticeQueued = $false
$script:writeFiles = @{}
$script:storeTops = @{}          # 저장소 파일마다 마지막으로 읽은(쓴) 맨 위 키. Write-WtStore가 같이 쓴다
$script:storeRead = @{}          # 저장소 파일마다 읽은 결과 (Set-WtStoreRead)
$script:storeGeneration = 0

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

# 문서 맨 위의 키 중 schema · saved · items가 아닌 것 (importedFrom · 더 새 앱이 더한 키 등)
function Get-WtStoreTops($Doc) {
    $tops = [ordered]@{}
    foreach ($p in @($Doc.PSObject.Properties)) {
        if ($p.Name -notin 'schema', 'saved', 'items') { $tops[$p.Name] = $p.Value }
    }
    $tops
}

<#
저장소 파일마다 읽은 결과를 적어 둔다 (쓰기를 막는 데 쓴다). 키는 파일 경로(소문자)
  State   ok(읽음) · missing(파일 없음) · refused(내용 때문에 읽지 않음: 빈 파일 · JSON 아님 · schema 없음 · 더 새 schema · 변환 실패)
          · unread(디스크 · 네트워크 때문에 못 읽음)
  Schema  파일의 schema (ok · missing이면 이 앱이 쓸 schema)
  Reason  refused · unread일 때 이유
  Generation  그 파일의 버전 번호. 읽거나 쓸 때마다 오른다. 핸들(Open-WtStore)은 열 때의 번호를 자기 것으로 들고, 저장할 때 지금 번호와 같아야 쓴다
  거부(refused) 뒤 못 읽거나 파일이 없어져도 거부로 남는다. 다시 읽어 정상 schema(ok)를 확인해야만 풀린다
#>
function Set-WtStoreRead([string]$Path, [string]$State, [int]$Schema = 0, [string]$Reason = '') {
    $key = $Path.ToLowerInvariant()
    $script:storeGeneration++
    $old = $script:storeRead[$key]
    if ($State -in 'unread', 'missing' -and $old -and $old.State -eq 'refused') { $State = 'refused'; $Schema = $old.Schema; $Reason = $old.Reason }
    $script:storeRead[$key] = @{ State = $State; Schema = $Schema; Reason = $Reason; Generation = $script:storeGeneration }
}

# 읽기를 거부한다: 거부했다고 적고 예외를 올린다. 파일은 바꾸지 않는다
function Stop-WtStoreRead([string]$Path, [string]$Message) {
    Set-WtStoreRead $Path 'refused' -Reason $Message
    throw $Message
}

<#
저장소 하나를 읽는다. 파일이 없으면 $null. 내용 때문에 읽을 수 없으면 거부하고(예외) 그 파일에 쓰지 못하게 적어 둔다:
  빈 파일 · JSON이 아님 · 맨 위가 객체가 아님 · schema가 1~999 정수가 아님 · items가 목록이 아님 · 앱보다 높은 schema · 변환 실패.
  「파일 없음」과 「빈 파일」은 다르다. 빈 파일은 깨진 파일이다.
$Migrate는 { param($doc, $from) ... $doc } 형태로, schema $from 문서를 $from+1 형식으로 바꿔 돌려준다. 읽은 칸을 버리지 말고 아는 칸만 바꾼다.
  변환은 메모리에서 먼저 끝까지 한다. 실패하면 원본 파일은 건드리지 않고 예외를 올린다(탭은 그 오류를 화면에 보여 준다).
  성공하면 원본을 날짜 붙은 백업 <이름>.json.schema<번호>.<날짜-시각>.bak으로 남기고(덮어쓰지 않음) 새 형식으로 다시 쓴다.
맨 위의 모르는 키는 기억해 두었다가 Write-WtStore가 같이 쓴다. items 안의 null · 깨진 항목도 그대로 둔다.
#>
function Read-WtStore {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Schema = 1,
        [scriptblock]$Migrate
    )
    $path = Get-WtStorePath $Name
    $key = $path.ToLowerInvariant()
    try { $text = Read-WtJsonText $path }
    catch { Set-WtStoreRead $path 'unread' -Reason $_.Exception.Message; throw }
    if ($null -eq $text) {
        Set-WtStoreRead $path 'missing' $Schema
        if ($script:storeRead[$key].State -eq 'refused') { throw "$Name.json은 전에 읽기를 거부한 파일입니다. 정상 schema를 다시 읽기 전에는 새로 만들지 않습니다. ($($script:storeRead[$key].Reason))" }
        [void]$script:storeTops.Remove($key)
        return $null
    }
    if (-not $text.Trim()) { Stop-WtStoreRead $path "$Name.json이 비어 있습니다. 파일은 바꾸지 않았습니다." }
    try { $doc = $text | ConvertFrom-Json -Depth 20 -DateKind String }
    catch { Stop-WtStoreRead $path "$Name.json을 JSON으로 읽지 못했습니다. 파일은 바꾸지 않았습니다. ($($_.Exception.Message))" }
    if ($doc -isnot [System.Management.Automation.PSCustomObject]) { Stop-WtStoreRead $path "$Name.json의 맨 위가 객체가 아닙니다. 파일은 바꾸지 않았습니다." }
    $num = ConvertFrom-WtWhole (Get-WtField $doc 'schema') 1 999
    if ($null -eq $num) { Stop-WtStoreRead $path "$Name.json에 형식 번호(schema)가 없거나 잘못됐습니다. 파일은 바꾸지 않았습니다." }
    # items는 꼭 목록이다. 없거나 null이면 빈 목록이 아니라 깨진 파일로 본다(빈 목록으로 저장하면 원래 내용을 모른 채 덮게 된다)
    $list = Get-WtField $doc 'items'
    if ($null -eq $list -or $list -isnot [array]) { Stop-WtStoreRead $path "$Name.json의 items가 없거나 목록이 아닙니다. 파일은 바꾸지 않았습니다." }
    $from = [int]$num
    if ($from -gt $Schema) {
        Stop-WtStoreRead $path "$Name.json은 더 새 버전(schema $from)에서 저장됐습니다. WorkTool을 최신으로 바꿔 주세요. 파일은 바꾸지 않았습니다."
    }
    if ($from -lt $Schema) {
        if (-not $Migrate) { Stop-WtStoreRead $path "$Name.json을 schema $from에서 $Schema(으)로 바꾸는 방법이 없습니다. 파일은 바꾸지 않았습니다." }
        $first = $from
        try {
            while ($from -lt $Schema) {
                $doc = & $Migrate $doc $from
                $from++
                $doc.schema = $from
            }
        } catch {
            Stop-WtStoreRead $path "$Name.json을 schema $first에서 $Schema(으)로 바꾸지 못했습니다. 원본 파일은 그대로 둡니다. ($($_.Exception.Message))"
        }
        $pending = Get-WtDataWritePending $path
        $stem = "$path.schema$first.$((Get-Date).ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture))"
        try { [void](Invoke-WtDataIo Backup -Arguments $path, $stem, $(if ($pending) { $pending.Json } else { $null })) }
        catch { Set-WtStoreRead $path 'unread' -Reason $_.Exception.Message; throw }
        $script:storeTops[$key] = Get-WtStoreTops $doc
        Set-WtStoreRead $path 'ok' $first
        Write-WtStore -Name $Name -Schema $Schema -Items @($doc.items) -KeepNull
        # 변환 코드가 만든 객체(해시 테이블 등) 대신, 다음에 읽을 때와 같은 모양(저장한 JSON을 다시 읽은 것)으로 돌려준다
        $doc = Read-WtJsonFile $path
    } else {
        $script:storeTops[$key] = Get-WtStoreTops $doc
    }
    Set-WtStoreRead $path 'ok' $Schema
    $doc
}

# 저장소의 항목만 배열로 돌려준다. 파일이 없으면 빈 배열. null 항목은 뺀다(예전부터 쓰던 탭용).
# 항목을 고쳐 저장하는 새 코드는 null · 깨진 항목까지 그대로 다루는 Open-WtStore · Save-WtStore를 쓴다
function Get-WtStoreItems {
    param([Parameter(Mandatory)][string]$Name, [int]$Schema = 1, [scriptblock]$Migrate)
    $doc = Read-WtStore -Name $Name -Schema $Schema -Migrate $Migrate
    if ($null -eq $doc) { return , @() }
    , @($doc.items | Where-Object { $null -ne $_ })
}

<#
저장소 하나를 통째로 쓴다(낮은 단계). 마지막으로 읽은(또는 쓴) 맨 위 키를 같이 쓰고, $Extra의 키는 그 위에 덮어 쓴다 (예: 가져온 위치).
saved는 앱이 찍는 시각(시간대 포함)이다. -KeepNull이 없으면 items의 null은 뺀다.
쓰기를 거부하는 경우(예외, 쓰기 실패와 다르다): 이 파일을 내용 때문에 읽지 않았거나(refused), 파일의 schema가 쓰려는 schema보다 높을 때.
  그런 파일을 덮어쓰면 더 새 버전의 데이터나 고칠 수 있는 파일을 잃기 때문이다. 다시 읽어 ok가 되면 풀린다
#>
function Write-WtStore {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$Schema = 1,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Items,
        [hashtable]$Extra,
        [switch]$KeepNull
    )
    $path = Get-WtStorePath $Name
    $key = $path.ToLowerInvariant()
    $read = $script:storeRead[$key]
    if ($read -and $read.State -eq 'refused') { throw "$Name.json은 읽지 못한 파일이라 저장하지 않습니다. ($($read.Reason))" }
    if ($read -and $read.Schema -gt $Schema) { throw "$Name.json은 schema $($read.Schema) 파일이라 schema $Schema(으)로 저장하지 않습니다." }
    $doc = [ordered]@{ schema = $Schema; saved = (Get-WtStamp) }
    if ($script:storeTops.ContainsKey($key)) { foreach ($k in $script:storeTops[$key].Keys) { $doc[$k] = $script:storeTops[$key][$k] } }
    if ($Extra) { foreach ($k in $Extra.Keys) { $doc[$k] = $Extra[$k] } }
    $tops = [ordered]@{}
    foreach ($k in $doc.Keys) { if ($k -notin 'schema', 'saved') { $tops[$k] = $doc[$k] } }
    $script:storeTops[$key] = $tops
    # if 식으로 받으면 항목 하나짜리 목록이 펴져서 목록이 아니게 되므로 나눠서 넣는다
    if ($KeepNull) { $doc['items'] = @($Items) } else { $doc['items'] = @($Items | Where-Object { $null -ne $_ }) }
    Write-WtJsonFile $path $doc
    Set-WtStoreRead $path 'ok' $Schema
}

<#
저장소 핸들: 읽은 결과와 「이 결과로 저장해도 되는지」를 함께 가진다. 항목을 고쳐 저장하는 코드는 이 길만 쓴다.
읽기 문제로 예외를 올리지 않고 State에 담는다(화면이 오류를 보여 주게).
  Name · Path · Schema(쓸 schema) · State(ok · missing · error) · Error(이유) · Doc(읽은 문서 | $null)
  Items: 저장된 항목 그대로 (null · 깨진 항목 포함, 같은 순서). 저장할 때 이것을 고쳐서 넘긴다
  Version: 열 때 그 파일의 버전 번호. 핸들 자기 것이고 바뀌지 않는다 (같은 핸들을 여러 곳이 나눠 가져도 저장 판정이 같이 바뀌지 않게)
핸들의 Items 객체는 여럿이 같이 볼 수 있으므로, 고칠 때는 Copy-WtItem으로 복사해서 고친 목록을 넘긴다
#>
function Open-WtStore {
    param([Parameter(Mandatory)][string]$Name, [int]$Schema = 1, [scriptblock]$Migrate)
    $path = Get-WtStorePath $Name
    $state = 'ok'; $err = $null; $doc = $null; $list = @()
    try {
        $doc = Read-WtStore -Name $Name -Schema $Schema -Migrate $Migrate
        if ($null -eq $doc) { $state = 'missing' } else { $list = @($doc.items) }
    } catch { $state = 'error'; $err = $_.Exception.Message }
    $read = $script:storeRead[$path.ToLowerInvariant()]
    New-WtStoreHandle $Name $path $Schema $state $err $doc $list $(if ($read) { $read.Generation } else { 0 })
}

# 핸들 하나. 저장 모듈은 만든 핸들을 다시 고치지 않는다(저장하면 새 핸들을 만든다). 부르는 쪽도 고치지 않는다
function New-WtStoreHandle([string]$Name, [string]$Path, [int]$Schema, [string]$State, $ErrorText, $Doc, [AllowNull()][object[]]$List, [long]$Version) {
    [pscustomobject][ordered]@{ Name = $Name; Path = $Path; Schema = $Schema; State = $State; Error = $ErrorText; Doc = $Doc; Items = $List; Version = $Version }
}

<#
핸들로 저장한다(낙관적 잠금). 다음 경우에는 쓰지 않고 예외를 올린다(쓰기 실패와 다르다. 쓰기 실패는 저장 통로가 보유한다):
  - 핸들이 읽기에 실패했다(error): 더 새 버전 · 깨진 파일 · 응답 없는 폴더
  - 핸들의 Version이 그 파일의 지금 버전과 다르다: 핸들로 읽은 뒤 다시 읽었거나, 누가(같은 핸들을 가진 다른 곳 포함) 저장했다.
    다시 Open-WtStore로 읽고 바꾼 내용을 그 위에 다시 맞춘 뒤 저장한다
$Items의 null · 깨진 항목은 그대로 쓴다. 저장하면 새 버전의 핸들을 돌려준다(이어서 저장하려면 그것을 쓴다). 넘긴 핸들은 더 쓸 수 없다
#>
function Save-WtStore {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Items, [hashtable]$Extra)
    if ($Store.State -notin 'ok', 'missing') { throw "$($Store.Name).json은 읽지 못해서 저장하지 않습니다. ($($Store.Error))" }
    $key = ([string]$Store.Path).ToLowerInvariant()
    $read = $script:storeRead[$key]
    if (-not $read -or $read.Generation -ne $Store.Version) { throw "$($Store.Name).json이 이 핸들로 읽은 뒤에 바뀌었습니다(다시 읽음 · 다른 저장). 다시 읽은 뒤 저장하세요." }
    Write-WtStore -Name $Store.Name -Schema $Store.Schema -Items @($Items) -Extra $Extra -KeepNull
    New-WtStoreHandle $Store.Name $Store.Path $Store.Schema 'ok' $null $Store.Doc @($Items) $script:storeRead[$key].Generation
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

# 예전 CSV 하나를 읽는다. 파일이 없으면 $null. 있으면 @{ Rows(줄 목록, 빈 파일이면 빈 배열); Sha256(내용 해시); Encoding('utf-8' | 'cp949'); File }
function Read-WtLegacyCsv([string]$Folder, [string]$Name) {
    $r = Invoke-WtDataIo ReadCsv -Arguments (Join-Path $Folder "$Name.csv") -Key 'legacy' -Where '예전 데이터 위치' -Session Default
    if ($null -eq $r) { return $null }
    [pscustomobject]@{ Rows = @($r.Rows); Sha256 = $r.Sha256; Encoding = $r.Encoding; File = "$Name.csv" }
}

# 예전 CSV 하나의 줄만 읽는다. 파일이 없으면 $null (빈 파일이면 빈 배열)
function Import-WtLegacyCsv([string]$Folder, [string]$Name) {
    $r = Read-WtLegacyCsv $Folder $Name
    if ($null -eq $r) { return $null }
    , $r.Rows
}

Export-ModuleMember -Function Set-WtAppRoot, Get-WtAppRoot, Get-WtDataRoot, Open-WtDataLock, Close-WtDataLock, Read-WtJsonFile, Write-WtJsonFile,
    Test-WtDataWriting, Get-WtDataWriteState, Get-WtDataWriteStatus, Get-WtDataUnsaved, Resume-WtDataWrites, Register-WtDataWriteHandler, Stop-WtDataWrites,
    Get-WtStorePath, Test-WtStore, Get-WtDataFolder, Get-WtStoreStamp, Read-WtStore, Get-WtStoreItems, Write-WtStore, Open-WtStore, Save-WtStore, New-WtId,
    Find-WtLegacyFolder, Read-WtLegacyCsv, Import-WtLegacyCsv

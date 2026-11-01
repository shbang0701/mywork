<#
.SYNOPSIS
    이 PC에서 메모용 .md 파일을 쓰고 읽을 수 있는지 시험하고 걸린 시간을 보여 준다.

.DESCRIPTION
    WorkTool 메모를 .md 파일로 옮기기 전에, 이 PC의 보안 프로그램과 DRM이 그 동작을 허용하는지 확인한다.

    - 새 시험 폴더를 하나 만들고 그 안에서만 작업한다. 기존 파일은 건드리지 않는다.
    - 짧은 시험 글로 WorkTool 메모가 할 동작을 차례로 한다:
      새로 쓰기 → 읽어서 대조 → 고쳐 쓰기(임시 파일로 바꿔치기) → 고친 글 대조 → 목록 읽기 → 이름 바꾸기 → 휴지통 폴더로 옮기기 → 지우기
    - 끝나면 시험 폴더를 지운다. 중간에 실패해도 지운다.
    - 결과는 화면에만 보여 준다. 경로와 사용자 이름은 보여 주지 않는다.
    - 네트워크를 쓰지 않고 관리자 권한이 필요 없다. 외부 프로그램을 부르지 않는다.
    - 실패하면 그 단계에서 멈추고 어느 단계인지 알려 준다. 보안 프로그램이 막으면 여기서 드러난다.

    짧은 시간에 파일을 많이 고치는 동작이라 보안 프로그램이 경고할 수 있다. 처음에는 기본값으로 실행하고,
    문제가 없을 때만 -Count를 늘린다.

.PARAMETER Count
    시험할 파일 수. 10~2000. 비우면 설정 블록의 값을 쓴다.

.PARAMETER Folder
    시험 폴더를 만들 위치. 비우면 문서 폴더(WorkTool 데이터가 놓일 곳)에 만든다.

.PARAMETER KeepFiles
    끝난 뒤 시험 폴더를 지우지 않는다. 메모장으로 직접 열어 보고 싶을 때 쓴다.

.EXAMPLE
    .\Test-MemoFileAccess.ps1
    문서 폴더에 시험 폴더를 만들어 파일 200개로 시험하고 지운다.

.EXAMPLE
    .\Test-MemoFileAccess.ps1 -Count 20 -KeepFiles
    파일 20개로 시험하고 폴더를 남긴다. 메모장으로 열어 글자가 보이는지 확인한다.

.EXAMPLE
    .\Test-MemoFileAccess.ps1 -WhatIf
    파일을 만들지 않고 할 일만 보여 준다.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateRange(10, 2000)][int]$Count,   # 시험할 파일 수 10~2000 (비우면 설정 블록의 값)
    [string]$Folder,                        # 시험 폴더를 만들 위치 (비우면 문서 폴더)
    [switch]$KeepFiles                      # 끝난 뒤 시험 폴더를 지우지 않는다
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    Count        = 200                # 시험할 파일 수
    FolderPrefix = 'memo-file-test'   # 시험 폴더 이름 앞부분 (뒤에 날짜가 붙는다)
    PlanCount    = 30000              # 이 개수로 늘렸을 때의 예상 시간을 보여 준다
}
# =================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($PSBoundParameters.ContainsKey('Count')) { $Config.Count = $Count }
$parent = if ($Folder) { $Folder } else { [Environment]::GetFolderPath('MyDocuments', 'DoNotVerify') }
if (-not $parent) { throw '문서 폴더를 찾지 못했습니다. -Folder로 위치를 정하세요.' }
$root = Join-Path $parent ('{0}-{1:yyyyMMdd-HHmmss}' -f $Config.FolderPrefix, (Get-Date))
$utf8 = [Text.UTF8Encoding]::new($false)

# 파일마다 내용이 다른 시험 글. 메모 파일과 같은 모양(머리 정보 + 본문), 약 1.2KB
function New-TestText([int]$Number, [int]$Revision) {
    $line = '서버 점검 결과를 기록합니다. 백업 상태와 서비스 상태를 확인하고 후속 작업을 남깁니다.'
    $body = (1..9 | ForEach-Object { "$_. $line 번호 $Number" }) -join "`n"
    "---`nid: test$Number`nrev: $Revision`nfolder: work`n---`n# 시험 메모 $Number`n`n$body`n"
}

function Test-SameBytes([byte[]]$Left, [byte[]]$Right) {
    [Linq.Enumerable]::SequenceEqual($Left, $Right)
}

# 단계 하나: 파일마다 시간을 재서 결과 표에 더한다. 실패하면 예외가 그대로 올라간다
$script:report = [Collections.Generic.List[object]]::new()
$script:stepName = ''
function Invoke-TestStep([string]$Name, [object[]]$Files, [scriptblock]$Action) {
    $script:stepName = $Name
    $times = [double[]]::new($Files.Count)
    $watch = [Diagnostics.Stopwatch]::new()
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $watch.Restart()
        & $Action $Files[$i]
        $times[$i] = $watch.Elapsed.TotalMilliseconds
    }
    $stats = $times | Measure-Object -Average -Maximum
    $script:report.Add([pscustomobject]@{ Name = $Name; Average = $stats.Average; Maximum = $stats.Maximum })
}

function Get-StepAverage([string]$Name) {
    @($script:report | Where-Object { $_.Name -eq $Name })[0].Average
}

# 오류 글에서 경로를 뺀다. 결과를 옮겨 적어도 사용자 이름이 나가지 않게
function Get-SafeMessage([Exception]$Exception) {
    "$($Exception.GetType().Name): $($Exception.Message.Replace($root, '<시험 폴더>').Replace($parent, '<위치>'))"
}

function Get-LocationKind {
    if ($parent.StartsWith('\\')) { return '네트워크' }
    try {
        switch ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($parent)).DriveType) {
            'Fixed' { '로컬 디스크' }
            'Network' { '네트워크' }
            default { [string]$_ }
        }
    } catch { '알 수 없음' }
}

# ===== 본문 =====
if (-not $PSCmdlet.ShouldProcess('문서 폴더 또는 -Folder 위치의 새 시험 폴더', "시험 파일 $($Config.Count)개 만들기 · 고치기 · 지우기")) { return }
if (-not [IO.Directory]::Exists($parent)) { throw '시험 폴더를 만들 위치가 없습니다.' }

$failure = $null
$different = 0
$firstBytes = ''
$listMs = 0.0
try {
    $trash = Join-Path $root '.trash'
    $backup = Join-Path $root '.bak'
    [void][IO.Directory]::CreateDirectory($trash)
    [void][IO.Directory]::CreateDirectory($backup)

    $files = @(for ($n = 1; $n -le $Config.Count; $n++) {
            [pscustomobject]@{
                Number = $n
                Path   = Join-Path $root "시험 메모 $n.md"
                Moved  = Join-Path $root "이름 바꾼 메모 $n.md"
                Trash  = Join-Path $trash "시험 메모 $n.md"
                Bak    = Join-Path $backup "시험 메모 $n.md"
                Bytes  = $utf8.GetBytes((New-TestText $n 1))
            }
        })

    $compare = {
        param($f)
        $read = [IO.File]::ReadAllBytes($f.Path)
        if (-not (Test-SameBytes $read $f.Bytes)) {
            $script:different++
            if (-not $firstBytes) { $script:firstBytes = [Convert]::ToHexString($read, 0, [Math]::Min(8, $read.Length)) }
        }
    }

    Invoke-TestStep '새로 쓰기' $files { param($f) [IO.File]::WriteAllBytes($f.Path, $f.Bytes) }
    Invoke-TestStep '읽어서 대조' $files $compare

    # 앱의 저장과 같은 길: 임시 파일에 쓰고 바꿔치기한다. 직전 판은 .bak 폴더에 남는다
    Invoke-TestStep '고쳐 쓰기(바꿔치기)' $files {
        param($f)
        $f.Bytes = $utf8.GetBytes((New-TestText $f.Number 2))
        $tmp = "$($f.Path).tmp"
        [IO.File]::WriteAllBytes($tmp, $f.Bytes)
        [IO.File]::Replace($tmp, $f.Path, $f.Bak)
    }
    Invoke-TestStep '고친 글 대조' $files $compare

    # 앱이 시작할 때 바깥에서 고친 파일을 찾는 길: 파일을 열지 않고 크기와 시각만 본다
    $script:stepName = '목록 읽기'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $seen = 0
    foreach ($info in [IO.DirectoryInfo]::new($root).EnumerateFiles('*.md')) {
        if ($info.Length -gt 0 -and $info.LastWriteTimeUtc.Ticks -gt 0) { $seen++ }
    }
    $listMs = $watch.Elapsed.TotalMilliseconds
    if ($seen -ne $files.Count) { throw "목록의 파일 수가 다릅니다: $seen / $($files.Count)" }

    Invoke-TestStep '이름 바꾸기' $files { param($f) [IO.File]::Move($f.Path, $f.Moved) }
    Invoke-TestStep '휴지통 폴더로 옮기기' $files { param($f) [IO.File]::Move($f.Moved, $f.Trash) }
    Invoke-TestStep '지우기' $files { param($f) [IO.File]::Delete($f.Trash) }
} catch {
    $failure = $_.Exception
} finally {
    if (-not $KeepFiles -and [IO.Directory]::Exists($root)) {
        try { [IO.Directory]::Delete($root, $true) } catch { Write-Warning "시험 폴더를 지우지 못했습니다: $(Get-SafeMessage $_.Exception)" }
    }
}

Write-Host "메모 파일 시험: 파일 $($Config.Count)개 · 위치 $(Get-LocationKind)"
foreach ($row in $script:report) {
    Write-Host ('  {0}  평균 {1:N1}ms  최대 {2:N1}ms' -f $row.Name, $row.Average, $row.Maximum)
}
if ($listMs) { Write-Host ('  목록 읽기  전체 {0:N1}ms' -f $listMs) }
if ($script:different) { Write-Host "  내용이 다른 경우 $($script:different)건 (첫 8바이트 $($script:firstBytes))" -ForegroundColor Red }
if ($KeepFiles -and [IO.Directory]::Exists($root)) { Write-Host "  시험 폴더를 남겼습니다: $(Split-Path $root -Leaf)" }

if ($failure) {
    throw "「$($script:stepName)」에서 멈췄습니다. $(Get-SafeMessage $failure)"
}
if ($script:different) {
    throw '쓴 내용과 읽은 내용이 다릅니다. DRM이나 보안 프로그램이 파일 내용을 바꾸는 것으로 보입니다.'
}

$plan = $Config.PlanCount
$scale = $plan / $Config.Count
Write-Host ('  메모 {0:N0}개 예상: 본문 전부 읽기 약 {1:N0}초 · 목록 읽기 약 {2:N1}초' -f $plan, ((Get-StepAverage '읽어서 대조') * $plan / 1000), ($listMs * $scale / 1000))
Write-Host '판정: 문제 없음. 위 결과를 그대로 옮겨 주세요.' -ForegroundColor Green

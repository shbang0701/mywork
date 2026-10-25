<#
.SYNOPSIS
    이 PC에서 어떤 프로그램이 어느 포트를 쓰는지 보여 준다 ("포트가 이미 사용 중" 오류 확인용).

.DESCRIPTION
    - 기본은 대기 중(LISTEN)인 TCP 포트와 그 프로그램(PID · 이름 · 경로)이다. svchost처럼 서비스가 도는 프로그램은 서비스 이름도 적는다.
    - Ports에 포트를 적으면 그 포트만 대기 · 연결 모두 본다 (로컬 · 원격 포트 둘 다).
      Ports 없이 IncludeConnections를 켜면 연결된(ESTABLISHED 등) 것도 모두, IncludeUdp를 켜면 UDP도 본다.
    - Windows 기본 명령(Get-NetTCPConnection · Get-NetUDPEndpoint)만 쓴다. 관리자 권한이 필요 없다.
      권한이 없으면 다른 사용자 · 시스템 프로그램의 경로가 비어 보일 수 있다.
    - 보기만 한다. 프로그램을 끄지 않는다.
    - SaveCsv를 켜면 결과를 output 폴더에 날짜가 붙은 CSV로 저장한다.

.PARAMETER Ports
    찾을 포트. 쉼표로 여러 개 (예: 8080,3306). 비우면 대기 중인 포트 전체

.PARAMETER IncludeConnections
    대기 중인 것뿐 아니라 연결된 것도 본다 (Ports를 적으면 늘 본다)

.PARAMETER IncludeUdp
    UDP 포트도 본다

.PARAMETER SaveCsv
    결과를 CSV로 저장한다

.EXAMPLE
    .\Get-PortProcess.ps1 -Ports 8080
    8080 포트를 누가 쓰는지 본다.

.EXAMPLE
    .\Get-PortProcess.ps1 -Ports '1433,3306,5432' -IncludeConnections
    DB 포트로 대기 · 연결 중인 프로그램을 본다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Ports,
    [switch]$IncludeConnections,
    [switch]$IncludeUdp,
    [switch]$SaveCsv
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    OutputFolder = Join-Path $PSScriptRoot 'output'    # 결과(CSV)를 저장할 폴더
}
# =================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-OutputPath([string]$BaseName, [string]$Extension) {
    if (-not (Test-Path -LiteralPath $Config.OutputFolder)) { [void](New-Item -ItemType Directory -Path $Config.OutputFolder) }
    $stem = Join-Path $Config.OutputFolder ('{0}_{1:yyyyMMdd_HHmmss}' -f $BaseName, (Get-Date))
    $path = "$stem$Extension"; $n = 2
    while (Test-Path -LiteralPath $path) { $path = "${stem}_$n$Extension"; $n++ }
    $path
}

function Show-Table($Rows, [object[]]$Property) {
    $text = ($Rows | Format-Table -Property $Property -AutoSize | Out-String -Width 250).Trim("`r", "`n")
    if ($text) { Write-Host $text }
}

$script:stateText = @{
    Listen = '대기'; Established = '연결됨'; TimeWait = '끊는 중(TIME_WAIT)'; CloseWait = '끊는 중(CLOSE_WAIT)'
    SynSent = '연결 시도'; SynReceived = '연결 받는 중'; FinWait1 = '끊는 중'; FinWait2 = '끊는 중'; LastAck = '끊는 중'; Closing = '끊는 중'; Bound = '묶임'
}

# ===== 본문 =====
$want = @()
if ($Ports) {
    $want = @(foreach ($p in ($Ports -split '[,;/\s]+' | Where-Object { $_ })) {
            $n = 0
            if (-not [int]::TryParse($p, [ref]$n) -or $n -lt 1 -or $n -gt 65535) { throw "포트는 1~65535 숫자입니다: $p" }
            $n
        })
}

$tcp = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
if (-not $IncludeConnections -and -not $want.Count) { $tcp = @($tcp | Where-Object State -eq 'Listen') }
$udp = @(if ($IncludeUdp) { Get-NetUDPEndpoint -ErrorAction SilentlyContinue })
if ($want.Count) {
    $tcp = @($tcp | Where-Object { $_.LocalPort -in $want -or $_.RemotePort -in $want })
    $udp = @($udp | Where-Object { $_.LocalPort -in $want })
}

# 프로세스 · 서비스 이름은 한 번에 모아 둔다
$procs = @{}
foreach ($p in Get-Process) { $procs[$p.Id] = $p }
$services = @{}
try {
    foreach ($s in Get-CimInstance Win32_Service -Filter 'ProcessId > 0' -ErrorAction Stop) {
        $services[[int]$s.ProcessId] = @($services[[int]$s.ProcessId] | Where-Object { $_ }) + $s.Name
    }
} catch { Write-Host '서비스 목록을 읽지 못해 서비스 이름은 비워 둡니다.' }

function New-Row([string]$Protocol, $Entry, [string]$State, [string]$Remote, $RemotePort) {
    $id = [int]$Entry.OwningProcess
    $p = $procs[$id]
    $path = ''
    if ($p) { try { $path = [string]$p.Path } catch { } }
    [pscustomobject][ordered]@{
        프로토콜      = $Protocol
        '로컬 주소'   = $Entry.LocalAddress
        '로컬 포트'   = [int]$Entry.LocalPort
        '원격 주소'   = $Remote
        '원격 포트'   = $RemotePort
        상태          = $State
        PID           = $id
        프로그램      = $(if ($id -eq 0) { 'System Idle' } elseif ($id -eq 4) { 'System' } elseif ($p) { $p.ProcessName } else { '(끝남)' })
        서비스        = (@($services[$id] | Where-Object { $_ }) -join ', ')
        경로          = $path
    }
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($c in $tcp) {
    $state = if ($script:stateText.ContainsKey([string]$c.State)) { $script:stateText[[string]$c.State] } else { [string]$c.State }
    $listen = [string]$c.State -eq 'Listen'
    $rows.Add((New-Row 'TCP' $c $state $(if ($listen) { '' } else { $c.RemoteAddress }) $(if ($listen) { '' } else { [int]$c.RemotePort })))
}
foreach ($u in $udp) { $rows.Add((New-Row 'UDP' $u '' '' '')) }
$sorted = @($rows | Sort-Object 프로토콜, '로컬 포트', 상태, '로컬 주소', '원격 주소', '원격 포트')

if (-not $sorted.Count) {
    Write-Host $(if ($want.Count) { "포트 $($want -join ', ')을(를) 쓰는 프로그램이 없습니다." } else { '대기 중인 포트가 없습니다.' })
    return
}
Show-Table $sorted @('프로토콜', '로컬 주소', '로컬 포트', '원격 주소', '원격 포트', '상태', 'PID', '프로그램', '서비스')
$names = @($sorted | Group-Object 프로그램 | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { "$($_.Name) $($_.Count)" })
Write-Host "$($sorted.Count)줄 · 프로그램별: $($names -join ' · ')"
if ($SaveCsv) {
    $out = Get-OutputPath '포트사용' '.csv'
    $sorted | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
    Write-Host "저장: $out"
}

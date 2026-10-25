<#
.SYNOPSIS
    여러 서버 · 포트에 TCP로 연결되는지 한 번에 확인한다 (방화벽 · 서비스 기동 확인용).

.DESCRIPTION
    - 모든 대상에 동시에 연결해 보고, TimeoutMs 안에 연결되면 「열림」이다.
      거부되면 「닫힘」(호스트는 응답함), 응답이 없으면 「시간 초과」(방화벽에서 막힘 · 꺼짐)다.
    - 대상: Targets에 쉼표로 적거나, 목록 파일(스크립트 옆 tcp-targets.txt)에 한 줄에 하나씩 적는다.
      둘 다 없으면 설정 블록의 Targets를 쓴다.
      한 줄은 "이름 주소:포트" · "주소:포트" · "주소"이고, 포트가 여럿이면 /로 잇는다 (예: SRV-01 10.0.0.10:22/3389).
      포트를 안 적으면 Ports(없으면 설정 블록의 DefaultPorts)를 쓴다. # 뒤는 메모로 본다.
      Excel에서 이름 · 주소 · 포트 열을 복사해 붙여 넣어도 된다 (탭으로 나뉜다).
    - 연결만 해 보고 바로 끊는다. 데이터를 보내지 않는다. 관리자 권한이 필요 없다.
    - SaveCsv를 켜면 결과를 output 폴더에 날짜가 붙은 CSV로 저장한다.

.PARAMETER Targets
    확인할 대상. 쉼표로 여러 개 (예: SRV-01:22, 10.0.0.10:443/3389)

.PARAMETER TargetFile
    대상 목록 파일 (비우면 스크립트 옆 tcp-targets.txt)

.PARAMETER Ports
    포트를 안 적은 대상에 쓸 포트. 쉼표로 여러 개 (예: 22,3389)

.PARAMETER TimeoutMs
    연결을 기다리는 시간(ms). Windows는 거부(닫힘)를 알기까지 2초쯤 걸리므로 3000 이상을 권한다

.PARAMETER SaveCsv
    결과를 CSV로 저장한다

.EXAMPLE
    .\Test-TcpPort.ps1 -Targets 'SRV-01:22, SRV-02:22, 10.0.0.10:443'
    세 곳을 확인한다.

.EXAMPLE
    .\Test-TcpPort.ps1 -Targets '10.0.0.10, 10.0.0.11' -Ports '22,3389,5985'
    두 서버의 SSH · 원격 데스크톱 · WinRM 포트를 확인한다.

.EXAMPLE
    .\Test-TcpPort.ps1 -TargetFile .\점검대상.txt -SaveCsv
    목록 파일의 대상을 확인하고 CSV로 남긴다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Targets,
    [string]$TargetFile,
    [string]$Ports,
    [ValidateRange(100, 60000)][int]$TimeoutMs = 3000,
    [switch]$SaveCsv
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    TargetFile   = Join-Path $PSScriptRoot 'tcp-targets.txt'   # 대상 목록 파일. 없으면 아래 Targets를 쓴다
    Targets      = @(                                           # 예시는 가짜 값이다. 목록 파일을 만들거나 실제 값으로 바꾼다
        'SRV-01   10.0.0.10:22/3389'
        'SRV-02   10.0.0.11:443'
        'WEB-01   portal.example.com:443'
    )
    DefaultPorts = '22,3389'                                    # 포트를 안 적은 대상에 쓸 포트
    OutputFolder = Join-Path $PSScriptRoot 'output'             # 결과(CSV)를 저장할 폴더
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

# 목록 파일은 UTF-8로 읽고, 메모장 ANSI(CP949)로 저장해 깨지면 그 인코딩으로 다시 읽는다
function Read-ListFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { $text = [System.Text.Encoding]::GetEncoding(949).GetString($bytes) }
    $text.TrimStart([char]0xFEFF) -split '\r?\n'
}

function ConvertTo-PortList([string]$Text, [string]$Where) {
    @(foreach ($p in ($Text -split '[,/;\s]+' | Where-Object { $_ })) {
            $n = 0
            if (-not [int]::TryParse($p, [ref]$n) -or $n -lt 1 -or $n -gt 65535) { throw "포트는 1~65535 숫자입니다: $p ($Where)" }
            $n
        })
}

# 한 줄 → 대상 여럿 (포트마다 하나)
function ConvertTo-Target([string]$Line, [int[]]$DefaultPorts) {
    $text = ($Line -replace '#.*$', '').Trim()
    if (-not $text) { return }
    $tokens = @($text -split '\s+' | Where-Object { $_ })
    $ports = [System.Collections.Generic.List[int]]::new()
    $words = [System.Collections.Generic.List[string]]::new()
    foreach ($t in $tokens) { if ($t -match '^\d+([,/]\d+)*$') { $ports.AddRange([int[]](ConvertTo-PortList $t $Line)) } else { $words.Add($t) } }
    if (-not $words.Count) { throw "주소가 없습니다: $Line" }
    # 주소는 :포트가 붙은 칸, 없으면 IP로 읽히는 칸, 그것도 없으면 마지막 칸
    $at = $words.Count - 1
    for ($i = $words.Count - 1; $i -ge 0; $i--) { if ($words[$i] -match '^\[.+\]:|^[^:]+:\d') { $at = $i; break } }
    if ($at -eq $words.Count - 1) { for ($i = 0; $i -lt $words.Count; $i++) { if ($words[$i] -match '^\d{1,3}(\.\d{1,3}){3}$') { $at = $i; break } } }
    $address = $words[$at]
    $name = (@(for ($i = 0; $i -lt $words.Count; $i++) { if ($i -ne $at) { $words[$i] } }) -join ' ')
    $hostName = $address
    if ($address -match '^\[(.+)\]:(.+)$' -or $address -match '^([^:]+):([\d,/]+)$') {
        $hostName = $Matches[1]; $ports.AddRange([int[]](ConvertTo-PortList $Matches[2] $Line))
    }
    $hostName = $hostName.Trim('[', ']')
    if (-not $ports.Count) { $ports.AddRange($DefaultPorts) }
    foreach ($p in ($ports | Select-Object -Unique)) {
        [pscustomobject]@{ Name = $(if ($name) { $name } else { $hostName }); Host = $hostName; Port = $p; Client = $null; Task = $null; Ms = $null }
    }
}

function Get-ConnectError([System.Exception]$Exception) {
    $e = $Exception
    while ($e) {
        if ($e -is [System.Net.Sockets.SocketException]) {
            switch ([string]$e.SocketErrorCode) {
                'ConnectionRefused' { return '닫힘 (거부)' }
                'TimedOut' { return '시간 초과' }
                'HostNotFound' { return '이름을 찾지 못함' }
                'NoData' { return '이름을 찾지 못함' }
                'TryAgain' { return '이름을 찾지 못함' }
                'HostUnreachable' { return '호스트에 닿지 않음' }
                'NetworkUnreachable' { return '네트워크에 닿지 않음' }
                'AddressNotAvailable' { return '쓸 수 없는 주소' }
            }
        }
        if (-not $e.InnerException) { break }
        $e = $e.InnerException
    }
    $e.Message
}

# ===== 본문 =====
$default = ConvertTo-PortList $(if ($Ports) { $Ports } else { $Config.DefaultPorts }) 'Ports'
if ($TargetFile) { $Config.TargetFile = $TargetFile.Trim().Trim('"') }
if ($Targets) { $lines = @($Targets -split '[,;\r\n]+'); $source = '입력한 Targets' }
elseif (Test-Path -LiteralPath $Config.TargetFile -PathType Leaf) { $lines = @(Read-ListFile $Config.TargetFile); $source = $Config.TargetFile }
elseif ($TargetFile) { throw "목록 파일이 없습니다: $($Config.TargetFile)" }
else { $lines = @($Config.Targets); $source = '설정 블록의 Targets (목록 파일 없음)' }
$list = @(foreach ($line in $lines) { ConvertTo-Target $line $default })
if (-not $list.Count) { throw '확인할 대상이 없습니다. Targets에 적거나 목록 파일을 만드세요.' }
Write-Host "대상: $source · $($list.Count)곳 · 기다리는 시간 ${TimeoutMs}ms"

$watch = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($t in $list) {
    $t.Client = [System.Net.Sockets.TcpClient]::new()
    try { $t.Task = $t.Client.ConnectAsync($t.Host, $t.Port) }
    catch { $t.Task = [System.Threading.Tasks.Task]::FromException($_.Exception) }
}
while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
    $pending = 0
    foreach ($t in $list) {
        if ($null -eq $t.Ms -and $t.Task.IsCompleted) { $t.Ms = $watch.ElapsedMilliseconds }
        if ($null -eq $t.Ms) { $pending++ }
    }
    if (-not $pending) { break }
    Start-Sleep -Milliseconds 10
}

$rows = foreach ($t in $list) {
    $result = if ($null -eq $t.Ms) { '시간 초과' }
    elseif ($t.Task.IsFaulted) { Get-ConnectError $t.Task.Exception }
    elseif ($t.Client.Connected) { '열림' }
    else { '연결 안 됨' }
    $t.Client.Dispose()   # 연결했으면 바로 끊고, 아직 시도 중이면 멈춘다
    [pscustomobject][ordered]@{
        이름 = $t.Name; 주소 = $t.Host; 포트 = $t.Port; 결과 = $result
        '응답(ms)' = $(if ($result -eq '열림') { $t.Ms } else { '' })
        확인 = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
}
$rows = @($rows)
Show-Table $rows @('이름', '주소', '포트', '결과', '응답(ms)')
$open = @($rows | Where-Object 결과 -eq '열림').Count
Write-Host "열림 ${open}곳 · 안 열림 $($rows.Count - $open)곳"
if ($SaveCsv) {
    $out = Get-OutputPath 'TCP포트확인' '.csv'
    $rows | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
    Write-Host "저장: $out"
}

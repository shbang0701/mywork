<#
.SYNOPSIS
    여러 서버에 ping을 계속 보내 응답 · 끊김을 한 화면에 보여 주고, 상태가 바뀐 시각을 CSV로 남긴다.

.DESCRIPTION
    - 대상 목록: 스크립트 옆 ping-hosts.txt (없으면 설정 블록의 Hosts).
      한 줄에 하나씩 "이름 주소" 또는 "주소"로 적고, # 뒤는 메모로 본다.
      Excel에서 이름 · 주소 두 열을 복사해 붙여 넣어도 된다 (탭으로 나뉜다).
      ping이 막힌 서버는 "이름 주소:포트"로 적으면 그 TCP 포트에 연결되는지로 확인한다 (예: SRV-01 10.0.0.10:22).
    - 한꺼번에 쏘지 않는다. 대상을 GapMs(기본 0.25초) 간격으로 하나씩 차례로 확인한다.
      1초에 최대 4번이라 cmd 창 네 개에서 ping -t를 돌리는 정도다. 대상이 늘어도 초당 횟수는 늘지 않고 한 바퀴가 길어진다.
      한 바퀴를 다 돌면 IntervalSeconds(기본 5초)가 될 때까지 쉬었다가 되풀이한다. 연속 DownAfter번 응답이 없으면 끊김으로 본다.
    - 목록에 적은 대상만 확인한다. IP 대역을 훑는 기능은 없다.
    - 상태가 바뀔 때마다 ping-logs 폴더의 CSV에 바로 한 줄씩 남긴다. 끝내면 대상별 요약 CSV도 만든다.
      파일 이름에 시작 시각이 붙어 이전 기록을 덮어쓰지 않는다. Excel 2016에서 한글이 깨지지 않게 UTF-8(BOM)로 저장한다.
    - Q 또는 Esc로 끝낸다 (Ctrl+C도 된다). 끝내면 요약을 화면에 보여 준다.
    - Windows 기본 .NET(Ping · TcpClient)만 쓴다. 설치할 것이 없고 관리자 권한이 필요 없다.

.EXAMPLE
    .\Watch-MultiPing.ps1
    목록의 대상을 5초마다 한 바퀴씩 확인한다.

.EXAMPLE
    .\Watch-MultiPing.ps1 -HostFile .\pm-list.txt -IntervalSeconds 10
    다른 목록 파일을 10초마다 한 바퀴씩 확인한다.

.EXAMPLE
    .\Watch-MultiPing.ps1 -Rounds 3
    세 번만 확인하고 끝낸다 (목록이 맞는지 먼저 볼 때).

.NOTES
    WorkTool: 콘솔
    WorkTool 업무 탭에서는 콘솔 창으로 띄운다. 그 창에서 Q로 끝내야 요약 CSV가 남는다.
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$HostFile,                              # 대상 목록 파일 (설정 블록의 HostFile 대신)
    [ValidateRange(1, 3600)][int]$IntervalSeconds,  # 한 바퀴 간격(초) (설정 블록의 IntervalSeconds 대신)
    [ValidateRange(0, 1000000)][int]$Rounds = 0     # 이만큼 확인하고 끝낸다. 0이면 끝낼 때까지
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    HostFile        = Join-Path $PSScriptRoot 'ping-hosts.txt'   # 대상 목록 파일. 없으면 아래 Hosts를 쓴다
    Hosts           = @(                                          # 예시는 가짜 값이다. 목록 파일을 만들거나 실제 값으로 바꾼다
        'SRV-01      10.0.0.10'
        'SRV-02      10.0.0.11'
        'SRV-01-iLO  10.0.1.10'
    )
    IntervalSeconds = 5                                           # 한 바퀴 간격(초). 한 바퀴가 이보다 오래 걸리면 다 돌고 바로 다음 바퀴를 돈다
    GapMs           = 250                                         # 대상 하나를 확인하고 다음 대상까지 띄우는 시간(ms). 250이면 1초에 최대 4번. 0이면 한꺼번에 보낸다
    TimeoutMs       = 1000                                        # 응답을 기다리는 시간(ms)
    DownAfter       = 2                                           # 연속 이만큼 응답이 없으면 끊김으로 본다 (패킷 하나 놓친 것에 흔들리지 않게)
    LogFolder       = Join-Path $PSScriptRoot 'ping-logs'         # 기록(CSV)을 저장할 폴더
    Beep            = $false                                      # $true면 상태가 바뀔 때 소리를 낸다
}
# =================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---- 목록 읽기 --------------------------------------------------------------------------------

# 목록 파일은 UTF-8로 읽는다. 메모장의 ANSI(CP949)로 저장해 한글이 깨지는 파일이면 그 인코딩으로 다시 읽는다.
function Read-HostLine {
    if (-not (Test-Path -LiteralPath $Config.HostFile -PathType Leaf)) { return $Config.Hosts }
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Config.HostFile).ProviderPath)
    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { $text = [System.Text.Encoding]::GetEncoding(949).GetString($bytes) }
    $text.TrimStart([char]0xFEFF) -split '\r?\n'
}

# "주소:포트" · "[IPv6]:포트"를 나눈다. 포트를 안 적었으면 Port 0 (ping으로 확인)
function Split-Endpoint([string]$Text) {
    if ($Text -match '^\[(.+)\]:(\d{1,5})$') { return @{ Host = $Matches[1]; Port = [int]$Matches[2]; HasPort = $true } }
    if ($Text -match '^([^:]+):(\d{1,5})$') { return @{ Host = $Matches[1]; Port = [int]$Matches[2]; HasPort = $true } }
    @{ Host = $Text.Trim('[', ']'); Port = 0; HasPort = $false }
}

function Test-IpText([string]$Text) {
    $h = (Split-Endpoint $Text).Host
    $h -match '^\d{1,3}(\.\d{1,3}){3}$' -or ($h -match ':' -and [System.Net.IPAddress]::TryParse($h, [ref]$null))
}

# 한 줄 → 대상. 주소는 IP로 읽히는 칸, 없으면 마지막 칸이다 (이름 · 주소 순서가 바뀌어도 된다)
function ConvertTo-Target([string]$Line) {
    $text = ($Line -replace '#.*$', '').Trim()
    if (-not $text) { return }
    $parts = @($text -split '[\t,; ]+' | Where-Object { $_ })
    $at = $parts.Count - 1
    for ($i = 0; $i -lt $parts.Count; $i++) { if (Test-IpText $parts[$i]) { $at = $i; break } }
    $address = $parts[$at]
    $rest = @(for ($i = 0; $i -lt $parts.Count; $i++) { if ($i -ne $at) { $parts[$i] } })
    $endpoint = Split-Endpoint $address
    [pscustomobject]@{
        Name = $(if ($rest.Count) { $rest -join ' ' } else { $address }); Address = $address
        Host = $endpoint.Host; Port = $endpoint.Port
        Error = $(if ($endpoint.HasPort -and ($endpoint.Port -lt 1 -or $endpoint.Port -gt 65535)) { "포트는 1~65535입니다: $Line" } else { '' })
        Status = 'WAIT'; Since = $null; Misses = 0; FirstMiss = $null; DownSince = $null; Note = ''
        Sent = 0; Received = 0; LastRtt = $null; RttSum = 0.0; RttMax = 0.0; LastReply = $null
        Outages = 0; DownTotal = [TimeSpan]::Zero
        Task = $null; Pinger = $null; Client = $null; Watch = $null; Done = $false; Elapsed = 0.0
        Busy = $false; At = $null
    }
}

# ---- 확인 -------------------------------------------------------------------------------------

$script:pingText = @{
    TimedOut = '시간 초과'; DestinationHostUnreachable = '호스트에 닿지 않음'; DestinationNetworkUnreachable = '네트워크에 닿지 않음'
    DestinationUnreachable = '대상에 닿지 않음'; DestinationPortUnreachable = '포트에 닿지 않음'; TtlExpired = 'TTL 만료'; BadDestination = '잘못된 주소'
}

# 마지막으로 확인을 보낸 뒤 흐른 시간. 바퀴가 바뀌어도 GapMs 간격을 지키려고 스크립트 전체에서 하나만 둔다
$script:sendWatch = $null

# 대상 하나의 확인을 시작한다. 결과는 Read-ProbeResult에서 읽는다.
function Start-Probe($Target) {
    $Target.Done = $false; $Target.Elapsed = 0.0; $Target.Busy = $true; $Target.At = Get-Date
    $Target.Watch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Target.Port) {
            $Target.Client = [System.Net.Sockets.TcpClient]::new()
            $Target.Task = $Target.Client.ConnectAsync($Target.Host, $Target.Port)
        } else {
            $Target.Pinger = [System.Net.NetworkInformation.Ping]::new()
            $Target.Task = $Target.Pinger.SendPingAsync($Target.Host, $Config.TimeoutMs)
        }
    } catch {
        $Target.Task = [System.Threading.Tasks.Task]::FromException($_.Exception)
    }
}

# 한 바퀴를 돈다. 대상을 GapMs 간격으로 하나씩 확인하기 시작하고(한꺼번에 쏘지 않는다), 결과가 오는 대로 상태를 고친다.
# 도는 동안 끝내기 키를 받으면 더 보내지 않고, 이미 보낸 것의 결과만 받은 뒤 $true를 돌려준다
function Invoke-Round($Targets, [datetime]$Start, [int]$Round, [bool]$Live) {
    $quit = $false; $next = 0; $dirty = $false
    $draw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        while (-not $quit -and $next -lt $Targets.Count -and (-not $script:sendWatch -or $script:sendWatch.ElapsedMilliseconds -ge $Config.GapMs)) {
            Start-Probe $Targets[$next]; $next++
            $script:sendWatch = [System.Diagnostics.Stopwatch]::StartNew()
        }
        $pending = if ($quit) { 0 } else { $Targets.Count - $next }
        foreach ($t in $Targets) {
            if (-not $t.Busy) { continue }
            if ($t.Task.IsCompleted) { $t.Done = $true }
            elseif ($t.Watch.ElapsedMilliseconds -lt $Config.TimeoutMs + 200) { $pending++; continue }
            $t.Elapsed = $t.Watch.Elapsed.TotalMilliseconds
            Update-TargetState $t (Read-ProbeResult $t) $t.At
            $t.Busy = $false; $dirty = $true
        }
        # 한 바퀴가 길어도 화면이 멈춘 것처럼 보이지 않게, 결과가 오면 도는 중에도 다시 그린다 (시계 때문에 적어도 1초마다)
        if ($Live -and (($dirty -and $draw.ElapsedMilliseconds -ge 250) -or $draw.ElapsedMilliseconds -ge 1000)) { Show-Board $Targets $Start $Round $Live; $dirty = $false; $draw.Restart() }
        if (-not $pending) { break }
        if (Test-QuitKey) { $quit = $true }
        Start-Sleep -Milliseconds 10
    }
    $quit
}

# 예외에서 사용자가 알아볼 이유를 고른다
function Get-ProbeError([System.Exception]$Exception) {
    $e = $Exception
    while ($e) {
        if ($e -is [System.Net.Sockets.SocketException]) {
            switch ($e.SocketErrorCode) {
                'HostNotFound' { return '이름을 찾지 못함' }
                'NoData' { return '이름을 찾지 못함' }
                'TryAgain' { return '이름을 찾지 못함' }
                'ConnectionRefused' { return '포트 닫힘 (호스트는 응답)' }
                'TimedOut' { return '시간 초과' }
                'HostUnreachable' { return '호스트에 닿지 않음' }
                'NetworkUnreachable' { return '네트워크에 닿지 않음' }
            }
        }
        if (-not $e.InnerException) { break }
        $e = $e.InnerException
    }
    $e.Message
}

function Read-ProbeResult($Target) {
    $ok = $false; $rtt = $null; $note = ''
    $task = $Target.Task
    if (-not $Target.Done) { $note = '시간 초과' }
    elseif ($task.IsFaulted) { $note = Get-ProbeError $task.Exception }
    elseif ($Target.Port) {
        $ok = $Target.Client.Connected; $rtt = [Math]::Round($Target.Elapsed)
        if (-not $ok) { $note = '연결 안 됨' }
    } else {
        $reply = $task.Result
        if ($reply.Status -eq 'Success') { $ok = $true; $rtt = $reply.RoundtripTime }
        else { $note = if ($script:pingText.ContainsKey([string]$reply.Status)) { $script:pingText[[string]$reply.Status] } else { [string]$reply.Status } }
    }
    # 끝난 Ping만 정리한다 (진행 중인 Ping을 정리하면 예외가 난다). TCP는 닫으면 연결 시도도 멈춘다
    if ($Target.Pinger -and $Target.Done) { $Target.Pinger.Dispose() }
    if ($Target.Client) { $Target.Client.Dispose() }
    $Target.Pinger = $null; $Target.Client = $null
    @{ Ok = $ok; Rtt = $rtt; Note = $note }
}

# ---- 상태 · 기록 ------------------------------------------------------------------------------

function Format-Span([TimeSpan]$Span) { '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds }

function ConvertTo-CsvLine([object[]]$Values) {
    @($Values | ForEach-Object {
            $s = [string]$_
            if ($s -match '[",\r\n]') { '"' + $s.Replace('"', '""') + '"' } else { $s }
        }) -join ','
}

function Get-StatusText([string]$Status) { switch ($Status) { 'UP' { '응답' } 'DOWN' { '끊김' } default { '확인 중' } } }

function Set-TargetStatus($Target, [string]$Status, [datetime]$At, $Rtt, [string]$DownFor, [string]$Note) {
    $Target.Status = $Status; $Target.Since = $At
    $script:log.WriteLine((ConvertTo-CsvLine @($At.ToString('yyyy-MM-dd HH:mm:ss'), $Target.Name, $Target.Address, (Get-StatusText $Status), $Rtt, $DownFor, $Note)))
    if ($Config.Beep) { try { if ($Status -eq 'UP') { [Console]::Beep(1200, 120) } else { [Console]::Beep(500, 250) } } catch { } }
}

# 한 번 확인한 결과로 상태를 고친다. 바뀌었으면 기록에 남긴다
function Update-TargetState($Target, $Result, [datetime]$Now) {
    $Target.Sent++
    if ($Result.Ok) {
        $Target.Received++; $Target.RttSum += $Result.Rtt; $Target.RttMax = [Math]::Max($Target.RttMax, $Result.Rtt)
        $Target.LastRtt = $Result.Rtt; $Target.LastReply = $Now; $Target.Misses = 0; $Target.Note = ''
        if ($Target.Status -ne 'UP') {
            $downFor = ''
            if ($Target.Status -eq 'DOWN') { $span = $Now - $Target.DownSince; $Target.DownTotal += $span; $downFor = Format-Span $span }
            Set-TargetStatus $Target 'UP' $Now $Result.Rtt $downFor $(if ($Target.Status -eq 'WAIT') { '시작' } else { '' })
        }
        return
    }
    $Target.LastRtt = $null; $Target.Note = $Result.Note
    $Target.Misses++
    if ($Target.Misses -eq 1) { $Target.FirstMiss = $Now }
    if ($Target.Status -ne 'DOWN' -and $Target.Misses -ge $Config.DownAfter) {
        $note = if ($Target.Status -eq 'WAIT') { "시작 · $($Result.Note)" } else { $Result.Note }
        $Target.Outages++
        # 끊긴 시각은 처음 응답이 없던 때다
        $Target.DownSince = $Target.FirstMiss
        Set-TargetStatus $Target 'DOWN' $Target.FirstMiss $null '' $note
    }
}

# ---- 화면 -------------------------------------------------------------------------------------

# 콘솔에서 한글 · 전각 문자는 두 칸을 차지한다. 표가 어긋나지 않게 칸 수로 맞춘다
$script:wideChars = [regex]'[ᄀ-ᅟ⺀-꓏가-힣豈-﫿︰-﹏＀-｠￠-￦]'
function Get-CellWidth([string]$Text) { $Text.Length + $script:wideChars.Matches($Text).Count }

function Format-Cell([string]$Text, [int]$Width, [switch]$Right) {
    if ((Get-CellWidth $Text) -gt $Width) {
        $cut = ''
        foreach ($ch in $Text.ToCharArray()) { if ((Get-CellWidth "$cut$ch") -gt $Width - 1) { break }; $cut += $ch }
        $Text = "$cut~"
    }
    $pad = ' ' * [Math]::Max(0, $Width - (Get-CellWidth $Text))
    if ($Right) { "$pad$Text" } else { "$Text$pad" }
}

function Get-ConsoleSize {
    $w = 120; $h = 40
    try { if ([Console]::WindowWidth -gt 0) { $w = [Console]::WindowWidth }; if ([Console]::WindowHeight -gt 0) { $h = [Console]::WindowHeight } } catch { }
    @{ Width = $w; Height = $h }
}

# 열 너비(칸). 이름 · 주소 열은 목록에서 가장 긴 것에 맞춘다 (Get-BoardLine)
$script:cols = @{ Status = 9; Rtt = 9; Since = 9; Outages = 4; Loss = 6 }
# 꾸밈(SGR 번호). 밝은 배경 · 어두운 배경 어디서나 읽히게 기본 색(초록 · 빨강 · 노랑)과 굵게 · 밑줄만 쓴다.
# 흐리게(2) · 밝은 검정(90)은 배경에 따라 거꾸로 진해지거나 안 보여서 쓰지 않는다
$script:style = @{ Title = '1'; Head = '4'; Up = '32'; Shaky = '33'; Down = '1;97;41'; Strong = '1'; Good = '1;32'; Bad = '1;31' }

# 조각 (글자, 꾸밈)들을 이어 한 줄을 만든다. 창 너비를 넘는 부분은 잘라서 줄이 다음 줄로 넘어가지 않게 한다
function Join-Segment([object[]]$Segments, [int]$Width, [bool]$Color) {
    $sb = [System.Text.StringBuilder]::new()
    $used = 0
    foreach ($x in $Segments) {
        $text = [string]$x[0]
        $room = $Width - $used
        if ($room -le 0) { break }
        if ((Get-CellWidth $text) -gt $room) { $text = Format-Cell $text $room }
        $used += Get-CellWidth $text
        [void]$sb.Append($(if ($Color -and $x[1]) { "`e[$($x[1])m$text`e[0m" } else { $text }))
    }
    $sb.ToString().TrimEnd()
}

# 긴 경로는 앞을 줄인다 (파일 이름이 있는 뒤쪽이 남게)
function Format-PathTail([string]$Path, [int]$Width) {
    if ((Get-CellWidth $Path) -le $Width -or $Width -lt 8) { return $Path }
    $tail = $Path
    while ((Get-CellWidth $tail) -gt $Width - 3) { $tail = $tail.Substring(1) }
    "...$tail"
}

# 대상 한 줄의 조각들. 끊긴 대상만 빨간 딱지와 굵은 이름으로 눈에 띄게 하고, 나머지는 조용하게 둔다.
# 0인 값(끊김 횟수 · 손실률)은 비워서 문제가 있는 줄만 숫자가 보이게 한다
function Get-RowSegment($Target, $Layout, [datetime]$Now) {
    $c = $script:cols; $s = $script:style
    $rtt = if ($null -eq $Target.LastRtt) { '-' } elseif ($Target.LastRtt -lt 1) { '<1 ms' } else { "$($Target.LastRtt) ms" }
    $since = if ($Target.Since) { $Target.Since.ToString('HH:mm:ss') } else { '' }
    $lost = $Target.Sent - $Target.Received
    $loss = if ($lost -gt 0) { '{0:0.0}%' -f (100.0 * $lost / $Target.Sent) } else { '' }
    $outages = if ($Target.Outages) { [string]$Target.Outages } else { '' }
    $note = $Target.Note
    if ($Target.Status -eq 'DOWN') { $note = "$(Format-Span ($Now - $Target.DownSince))째" + $(if ($note) { ", $note" }) }
    $label = " $(Get-StatusText $Target.Status) "
    $labelStyle = switch ($Target.Status) { 'DOWN' { $s.Down } 'UP' { if ($Target.Misses) { $s.Shaky } else { $s.Up } } default { '' } }
    $seg = [System.Collections.Generic.List[object[]]]::new()
    $seg.Add(@('  ', ''))
    $seg.Add(@($label, $labelStyle))
    $seg.Add(@((' ' * [Math]::Max(1, $c.Status + 1 - (Get-CellWidth $label))), ''))
    $seg.Add(@((Format-Cell $Target.Name $Layout.Name), $(if ($Target.Status -eq 'DOWN') { $s.Strong } else { '' })))
    $seg.Add(@(('  {0}  {1}  {2}  ' -f (Format-Cell $Target.Address $Layout.Address), (Format-Cell $rtt $c.Rtt -Right), (Format-Cell $since $c.Since)), ''))
    $seg.Add(@((Format-Cell $outages $c.Outages -Right), ''))
    $seg.Add(@(('  ' + (Format-Cell $loss $c.Loss -Right)), ''))
    if ($Layout.Note -gt 4 -and $note) { $seg.Add(@(('  ' + (Format-Cell $note $Layout.Note)), '')) }
    $seg
}

# 화면 한 장을 줄 목록으로 만든다. 위: 제목 · 개수 · 지금 시각, 가운데: 표, 아래: 속도 · 파일 · 끝내는 키.
# 창보다 대상이 많으면 끊김 · 확인 중을 먼저 보여 주고 나머지는 개수만 적는다
function Get-BoardLine($Targets, [datetime]$Start, [int]$Round, [bool]$Live, $Size) {
    $c = $script:cols; $s = $script:style
    $now = Get-Date
    $width = [Math]::Max(20, $Size.Width - 1)   # 마지막 칸까지 채우면 줄이 넘어가는 콘솔이 있어 한 칸 남긴다
    $layout = @{
        Name    = [Math]::Min(28, [Math]::Max(4, [int]($Targets | ForEach-Object { Get-CellWidth $_.Name } | Measure-Object -Maximum).Maximum))
        Address = [Math]::Min(30, [Math]::Max(4, [int]($Targets | ForEach-Object { Get-CellWidth $_.Address } | Measure-Object -Maximum).Maximum))
    }
    $fixed = 2 + $c.Status + 1 + $layout.Name + 2 + $layout.Address + 2 + $c.Rtt + 2 + $c.Since + 2 + $c.Outages + 2 + $c.Loss
    # 창이 좁으면 이름 열부터 줄여서 뒤쪽 열(바뀐 시각 · 손실률)이 잘리지 않게 한다
    $shrink = [Math]::Min([Math]::Max(0, $fixed - $width), [Math]::Max(0, $layout.Name - 10))
    $layout.Name -= $shrink; $fixed -= $shrink
    $layout.Note = [Math]::Max(0, $width - $fixed - 2)
    $up = @($Targets | Where-Object Status -eq 'UP').Count
    $down = @($Targets | Where-Object Status -eq 'DOWN').Count
    $wait = $Targets.Count - $up - $down
    $lines = [System.Collections.Generic.List[string]]::new()

    # 맨 윗줄: 제목과 개수, 오른쪽 끝에 지금 시각 (1초마다 바뀌어 화면이 살아 있는지 알 수 있다)
    $seg = [System.Collections.Generic.List[object[]]]::new()
    $seg.Add(@('  Multi Ping', $s.Title))
    $seg.Add(@("     대상 $($Targets.Count)    응답 ", ''))
    $seg.Add(@("$up", $s.Good))
    $seg.Add(@('    끊김 ', ''))
    $seg.Add(@("$down", $(if ($down) { $s.Bad } else { '' })))
    if ($wait) { $seg.Add(@("    확인 중 $wait", '')) }
    $used = 0
    foreach ($x in $seg) { $used += Get-CellWidth $x[0] }
    $clock = $now.ToString('HH:mm:ss')
    if ($width - $used - $clock.Length -ge 2) { $seg.Add(@((' ' * ($width - $used - $clock.Length) + $clock), '')) }
    $lines.Add((Join-Segment $seg $width $Live))
    $lines.Add('')

    # 표 머리: 밑줄로 표와 나눈다 (선 문자는 글꼴에 따라 두 칸이 되어 줄이 어긋날 수 있어 쓰지 않는다)
    $head = '{0} {1}  {2}  {3}  {4}  {5}  {6}' -f (Format-Cell ' 상태' $c.Status), (Format-Cell '이름' $layout.Name), (Format-Cell '주소' $layout.Address),
        (Format-Cell '응답 시간' $c.Rtt -Right), (Format-Cell '바뀐 시각' $c.Since), (Format-Cell '끊김' $c.Outages -Right), (Format-Cell '손실률' $c.Loss -Right)
    if ($layout.Note -gt 4) { $head += '  ' + (Format-Cell '메모' $layout.Note) }
    $seg = [System.Collections.Generic.List[object[]]]::new()
    $seg.Add(@('  ', ''))
    $seg.Add(@((Format-Cell $head ([Math]::Min((Get-CellWidth $head), $width - 2))), $s.Head))
    $lines.Add((Join-Segment $seg $width $Live))

    $footCount = if ($Live) { 3 } else { 2 }
    $rows = @($Targets)
    $hidden = 0
    # 화면에서는 창 높이에 딱 맞춘다: 위 3줄 + 표 + 빈 줄 + 아래 줄들, 맨 아랫줄 하나는 비워 둔다
    $room = if ($Live) { [Math]::Max(2, $Size.Height - 1 - $lines.Count - 1 - $footCount) } else { [int]::MaxValue }
    if ($rows.Count -gt $room) {
        $rows = @($Targets | Sort-Object -Stable { switch ($_.Status) { 'DOWN' { 0 } 'WAIT' { 1 } default { 2 } } } | Select-Object -First ($room - 1))
        $hidden = $Targets.Count - $rows.Count
    }
    foreach ($t in $rows) { $lines.Add((Join-Segment (Get-RowSegment $t $layout $now) $width $Live)) }
    if ($hidden) { $lines.Add((Join-Segment @(, @("  그 밖에 ${hidden}개는 창이 작아 생략했습니다(끊김부터 보여 줍니다). 창을 키우면 모두 보입니다.", '')) $width $false)) }

    # 아래 줄들은 창 바닥에 붙인다. 얼마나 자주 보내는지도 여기에 적어 둔다 (한 바퀴 = 간격과 '대상 수 x 띄우는 시간' 중 긴 쪽)
    $lines.Add('')
    if ($Live) { while ($lines.Count -lt $Size.Height - 1 - $footCount) { $lines.Add('') } }
    $cycle = [Math]::Max($Config.IntervalSeconds, [int][Math]::Ceiling($Targets.Count * $Config.GapMs / 1000.0))
    $pace = if ($Config.GapMs -gt 0) { '{0:0.##}초에 하나씩 (1초에 최대 {1:0.#}번)' -f ($Config.GapMs / 1000.0), (1000.0 / $Config.GapMs) } else { '한꺼번에 보냄' }
    $info = '  시작 {0:HH:mm:ss}   경과 {1}   {2}바퀴째   한 바퀴 약 {3}초, {4}' -f $Start, (Format-Span ($now - $Start)), $Round, $cycle, $pace
    $lines.Add((Join-Segment @(, @($info, '')) $width $false))
    $prefix = "  목록 $($script:hostSource)   기록 "
    $lines.Add((Join-Segment @(, @(($prefix + (Format-PathTail $script:logPath ($width - (Get-CellWidth $prefix)))), '')) $width $false))
    if ($Live) { $lines.Add('  Q 또는 Esc: 끝내기') }
    # 창이 아주 낮으면 아래 줄들을 버린다 (창 높이를 넘겨 그리면 화면이 밀려 올라간다)
    if ($Live -and $lines.Count -gt $Size.Height - 1) { $lines.RemoveRange([Math]::Max(1, $Size.Height - 1), $lines.Count - [Math]::Max(1, $Size.Height - 1)) }
    $lines
}

# 화면 전체를 다시 그린다. 화면이 아니면(파일로 돌린 출력) 꾸밈 없이 한 장씩 이어서 적는다
function Show-Board($Targets, [datetime]$Start, [int]$Round, [bool]$Live) {
    $lines = @(Get-BoardLine $Targets $Start $Round $Live (Get-ConsoleSize))
    if ($Live) { [Console]::Write("`e[H" + (($lines | ForEach-Object { "$_`e[K" }) -join "`n") + "`e[J") }
    else { [Console]::Out.Write(($lines -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine) }
}

function Test-QuitKey {
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            # 한글 입력 상태에서 Q는 'ㅂ'으로 들어온다
            if ($key.Key -eq [ConsoleKey]::Escape -or $key.KeyChar -in 'q', 'Q', 'ㅂ') { return $true }
        }
    } catch { }
    $false
}

# ---- 실행 -------------------------------------------------------------------------------------

function Invoke-MultiPing {
    if ($HostFile) { $Config.HostFile = $HostFile }
    if ($IntervalSeconds) { $Config.IntervalSeconds = $IntervalSeconds }
    $script:hostSource = if (Test-Path -LiteralPath $Config.HostFile -PathType Leaf) { Split-Path -Leaf $Config.HostFile } else { '설정 블록의 Hosts (목록 파일 없음)' }
    $targets = @(Read-HostLine | ForEach-Object { ConvertTo-Target $_ })
    $bad = @($targets | Where-Object Error)
    if ($bad.Count) { throw ($bad.Error -join "`n") }
    if (-not $targets.Count) { throw "확인할 대상이 없습니다. 목록 파일($($Config.HostFile))에 대상을 적거나 설정 블록의 Hosts를 채우세요." }

    $start = Get-Date
    if (-not (Test-Path -LiteralPath $Config.LogFolder)) { [void](New-Item -ItemType Directory -Path $Config.LogFolder) }
    $script:logPath = Join-Path $Config.LogFolder ('ping_{0:yyyyMMdd_HHmmss}.csv' -f $start)
    $summaryPath = Join-Path $Config.LogFolder ('ping_{0:yyyyMMdd_HHmmss}_요약.csv' -f $start)
    try { $script:log = [System.IO.StreamWriter]::new($script:logPath, $false, [System.Text.UTF8Encoding]::new($true)) }
    catch { throw "기록 파일을 만들지 못했습니다: $($script:logPath). 설정 블록의 LogFolder를 쓸 수 있는 폴더로 바꾸세요." }
    $script:log.AutoFlush = $true   # 창이 갑자기 닫혀도 그때까지의 기록은 남는다
    $script:log.WriteLine((ConvertTo-CsvLine @('시각', '이름', '주소', '상태', '응답(ms)', '끊김 시간', '메모')))

    $live = -not [Console]::IsOutputRedirected
    $round = 0
    try {
        if ($live) {
            [Console]::Write("`e[?1049h`e[?25l")   # 따로 쓰는 화면으로 바꾸고 커서를 숨긴다
            Show-Board $targets $start 0 $live      # 첫 바퀴가 도는 동안 빈 화면이 아니게 목록부터 보여 준다
        }
        while ($true) {
            $round++
            $roundWatch = [System.Diagnostics.Stopwatch]::StartNew()
            $quit = Invoke-Round $targets $start $round $live
            Show-Board $targets $start $round $live
            if ($quit -or ($Rounds -and $round -ge $Rounds)) { break }
            $tick = [System.Diagnostics.Stopwatch]::StartNew()
            while ($roundWatch.Elapsed.TotalSeconds -lt $Config.IntervalSeconds) {
                if (Test-QuitKey) { $quit = $true; break }
                # 쉬는 동안에도 시계 · 끊긴 시간이 흐르게 1초마다 다시 그린다
                if ($live -and $tick.ElapsedMilliseconds -ge 1000) { Show-Board $targets $start $round $live; $tick.Restart() }
                Start-Sleep -Milliseconds 50
            }
            if ($quit) { break }
        }
    } finally {
        if ($live) { [Console]::Write("`e[?25h`e[?1049l") }
        $script:log.Dispose()
        $end = Get-Date
        $summary = foreach ($t in $targets) {
            $downTotal = $t.DownTotal
            if ($t.Status -eq 'DOWN') { $downTotal += $end - $t.DownSince }
            [pscustomobject][ordered]@{
                이름 = $t.Name; 주소 = $t.Address; '마지막 상태' = (Get-StatusText $t.Status); 보냄 = $t.Sent; 받음 = $t.Received
                '손실률(%)' = $(if ($t.Sent) { [Math]::Round(100.0 * ($t.Sent - $t.Received) / $t.Sent, 1) } else { '' })
                '끊김 횟수' = $t.Outages; '끊김 합계' = (Format-Span $downTotal)
                '평균 응답(ms)' = $(if ($t.Received) { [Math]::Round($t.RttSum / $t.Received, 1) } else { '' })
                '최대 응답(ms)' = $(if ($t.Received) { $t.RttMax } else { '' })
                '마지막 응답' = $(if ($t.LastReply) { $t.LastReply.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            }
        }
        $summary | Export-Csv -LiteralPath $summaryPath -Encoding utf8BOM -NoTypeInformation
        Write-Host ('Multi Ping 끝: {0:yyyy-MM-dd HH:mm:ss} ~ {1:HH:mm:ss} ({2}), {3}회 확인' -f $start, $end, (Format-Span ($end - $start)), $round)
        $summary | Format-Table 이름, 주소, '마지막 상태', '손실률(%)', '끊김 횟수', '끊김 합계', '평균 응답(ms)' -AutoSize | Out-Host
        Write-Host "기록: $($script:logPath)"
        Write-Host "요약: $summaryPath"
    }
}

# 점검 스크립트에서 함수만 불러올 때(. .\Watch-MultiPing.ps1)는 실행하지 않는다.
if ($MyInvocation.InvocationName -ne '.') { Invoke-MultiPing }

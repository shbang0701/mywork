<#
.SYNOPSIS
    폴더의 로그 파일들에서 글자 · 정규식을 찾아 파일별 · 찾은 글자별 개수를 세고, 찾은 줄을 CSV로 저장한다.

.DESCRIPTION
    - 대상 폴더에서 Filter에 맞는 파일(기본 *.log)을 읽는다. 하위 폴더는 Recurse를 켤 때만 본다.
    - Pattern은 정규식이다. 여러 개는 |로 잇는다 (예: ERROR|Exception|timeout). 글자 그대로 찾으려면 SimpleMatch를 켠다.
    - 화면: 파일별 개수, 찾은 글자별 개수(예: 오류 코드별), 처음 몇 줄.
      찾은 줄은 output 폴더에 날짜가 붙은 CSV로 저장한다: 파일 · 줄 번호 · 고친 시각 · 찾은 글자 · 줄 내용.
    - 인코딩은 기본(자동)이면 파일마다 UTF-8인지 ANSI(CP949)인지 읽어 보고 고른다. 한글 로그가 깨지지 않게 하려는 것이다.
      잘못 고르면(화면의 「인코딩」 칸) Encoding으로 직접 정한다.
    - 읽지 못한 폴더 · 파일(권한 · 잠금)이 있으면 그 자리를 보이고 실패로 끝난다 (업무 탭에 「실패」). 찾은 것이 있으면 결과는 보이고 「부분 완료」로 알린다.
    - 로그를 읽기만 한다. 쓰는 중인 로그도 읽을 수 있다.

.PARAMETER TargetFolder
    로그 파일이 있는 폴더

.PARAMETER Pattern
    찾을 것 (정규식, 여러 개는 |로: ERROR|timeout)

.PARAMETER Filter
    대상 파일 (예: *.log, app*.txt)

.PARAMETER LastDays
    이 일수 안에 고친 파일만 본다. 0이면 모두

.PARAMETER Recurse
    하위 폴더의 파일도 본다

.PARAMETER SimpleMatch
    Pattern을 정규식이 아닌 글자 그대로 찾는다

.PARAMETER CaseSensitive
    대소문자를 가린다 (찾은 글자별 개수도 ERROR · error를 따로 센다)

.PARAMETER Encoding
    파일 인코딩: 자동 · UTF-8 · CP949 · UTF-16

.EXAMPLE
    .\Find-LogPattern.ps1 -TargetFolder D:\app\logs -Pattern 'ERROR|FATAL' -LastDays 1
    어제부터 고친 로그에서 ERROR · FATAL 줄을 찾는다.

.EXAMPLE
    .\Find-LogPattern.ps1 -TargetFolder \\SRV-01\logs -Filter *.txt -Pattern 'ORA-\d{5}' -Recurse
    Oracle 오류 코드(ORA-00001 등)를 코드별로 센다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetFolder,
    [Parameter(Mandatory)][string]$Pattern,
    [string]$Filter = '*.log',
    [ValidateRange(0, 3650)][int]$LastDays = 0,
    [switch]$Recurse,
    [switch]$SimpleMatch,
    [switch]$CaseSensitive,
    [ValidateSet('자동', 'UTF-8', 'CP949', 'UTF-16')][string]$Encoding = '자동'
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    MaxLines     = 100000                              # CSV에 남길 최대 줄 수 (넘으면 개수만 센다. 메모리에도 이만큼만 둔다)
    LineLength   = 1000                                # CSV에 남길 줄 길이 (넘으면 자른다)
    ShowLines    = 15                                  # 화면에 보일 찾은 줄 수
    ShowMax      = 20                                  # 화면에 보일 파일 · 글자 수
    OutputFolder = Join-Path $PSScriptRoot 'output'    # 결과(CSV)를 저장할 폴더
    OutputName   = '로그찾기'                           # 결과 파일 이름 (뒤에 날짜가 붙는다)
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


# 인코딩 고르기 (Encoding이 「자동」일 때): BOM이 있으면 그대로. 없으면 UTF-8 해독기로 앞에서부터 64KB씩 읽어 본다.
# - 해독기는 덩어리 끝에서 잘린 글자를 다음 덩어리와 이어 보므로(flush 없음) 경계에서 틀리지 않는다
# - 앞부분이 영문뿐이면 한글(0x80 이상 바이트)이 4KB 나올 때까지 더 읽는다 (최대 32MB). 끝까지 영문뿐이면 어느 쪽이든 같다
# - UTF-8로 읽을 수 없는 바이트가 나오면 CP949 (메모장 ANSI · 예전 프로그램 로그)
function Get-FileEncoding([string]$Path) {
    switch ($Encoding) {
        'UTF-8' { return [System.Text.UTF8Encoding]::new($false) }
        'CP949' { return [System.Text.Encoding]::GetEncoding(949) }
        'UTF-16' { return [System.Text.Encoding]::Unicode }
    }
    $buffer = [byte[]]::new(65536)
    $chars = [char[]]::new(65536 + 8)
    $decoder = [System.Text.UTF8Encoding]::new($false, $true).GetDecoder()
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) { return [System.Text.UTF8Encoding]::new($false) }
        if ($read -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
        if ($read -ge 2 -and $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode }
        $nonAscii = 0
        $scanned = 0L
        while ($read -gt 0) {
            try { [void]$decoder.GetChars($buffer, 0, $read, $chars, 0, $false) }
            catch { return [System.Text.Encoding]::GetEncoding(949) }   # UTF-8로 읽을 수 없는 바이트
            for ($i = 0; $i -lt $read; $i++) { if ($buffer[$i] -ge 0x80) { $nonAscii++ } }
            $scanned += $read
            if ($nonAscii -ge 4096 -or $scanned -ge 32MB) { break }
            $read = $stream.Read($buffer, 0, $buffer.Length)
        }
        # 파일 끝에서 잘린 글자(쓰는 중인 로그)는 오류로 보지 않는다
        [System.Text.UTF8Encoding]::new($false)
    } finally { $stream.Dispose() }
}

function Format-Line([string]$Text) {
    $t = $Text.TrimEnd()
    if ($t.Length -gt $Config.LineLength) { $t.Substring(0, $Config.LineLength) + '…' } else { $t }
}

function Get-EncodingName($Enc) {
    switch ($Enc.CodePage) { 949 { 'CP949' } 65001 { 'UTF-8' } 1200 { 'UTF-16' } default { $Enc.WebName } }
}

# ===== 본문 =====
$folder = $TargetFolder.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "폴더가 없거나 열 수 없습니다: $folder" }
$folder = (Resolve-Path -LiteralPath $folder).ProviderPath
if (-not $Filter) { $Filter = '*' }
if (-not $SimpleMatch) {
    try { [void][regex]::new($Pattern) } catch { throw "Pattern이 올바른 정규식이 아닙니다: $Pattern ($($_.Exception.InnerException.Message)) — 글자 그대로 찾으려면 SimpleMatch를 켜세요." }
}

# 읽지 못한 폴더 · 파일은 모아 두었다가 끝에 알린다. 하나라도 있으면 결론(없음)을 내지 않고 실패로 끝낸다
$failures = [System.Collections.Generic.List[object]]::new()
$listErrors = $null
$files = @(Get-ChildItem -LiteralPath $folder -Filter $Filter -File -Recurse:$Recurse -ErrorAction SilentlyContinue -ErrorVariable listErrors)
foreach ($e in @($listErrors)) { $failures.Add([pscustomobject]@{ 자리 = [string]$e.TargetObject; 이유 = $e.Exception.Message }) }
if ($LastDays) { $after = (Get-Date).AddDays(-$LastDays); $files = @($files | Where-Object LastWriteTime -ge $after) }
$files = @($files | Sort-Object FullName)
Write-Host "파일 $($files.Count)개에서 찾는 중: $Pattern$(if ($SimpleMatch) { ' (글자 그대로)' })$(if ($CaseSensitive) { ' (대소문자 가림)' })$(if ($Encoding -ne '자동') { " ($Encoding)" })"

$lines = [System.Collections.Generic.List[object]]::new()   # CSV에 남길 줄 (MaxLines까지만 보관)
$perFile = [System.Collections.Generic.List[object]]::new()
# 찾은 글자별 개수. 대소문자를 가리는지에 맞춰 같은 글자로 볼지 정한다
$comparer = if ($CaseSensitive) { [System.StringComparer]::Ordinal } else { [System.StringComparer]::OrdinalIgnoreCase }
$perValue = [System.Collections.Generic.Dictionary[string, object]]::new($comparer)
$total = 0L
$totalLines = 0L
foreach ($f in $files) {
    $count = 0L; $hitLines = 0L
    try {
        $enc = Get-FileEncoding $f.FullName
        # 일치한 줄을 받는 즉시 세고, CSV에 남길 줄만 상한까지 보관한다 (일치가 아주 많은 로그도 메모리를 다 쓰지 않게)
        # . { process { } }는 ForEach-Object보다 빠르고, 이 범위의 변수(개수)를 그대로 고친다
        Select-String -LiteralPath $f.FullName -Pattern $Pattern -Encoding $enc -SimpleMatch:$SimpleMatch -CaseSensitive:$CaseSensitive -AllMatches | . {
            process {
                $h = $_
                $hitLines++
                # SimpleMatch는 Matches가 비어 있을 수 있어서, 그때는 줄 하나를 찾은 것 하나로 센다
                $found = @(if ($h.Matches.Count) { foreach ($m in $h.Matches) { $m.Value } } else { $Pattern })
                foreach ($value in $found) {
                    $count++
                    $slot = $null
                    if ($perValue.TryGetValue($value, [ref]$slot)) { $slot.N++ } else { $perValue[$value] = [pscustomobject]@{ Text = $value; N = 1L } }
                }
                if ($lines.Count -lt $Config.MaxLines) {
                    $lines.Add([pscustomobject][ordered]@{
                            파일             = $f.FullName
                            줄               = $h.LineNumber
                            '파일 고친 시각' = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                            '찾은 글자'      = (@($found | Select-Object -Unique) -join ', ')
                            내용             = Format-Line $h.Line
                        })
                }
            }
        }
    } catch {
        $failures.Add([pscustomobject]@{ 자리 = $f.FullName; 이유 = $_.Exception.Message })
        Write-Host "  읽지 못함: $($f.FullName) ($($_.Exception.Message))"
    }
    $total += $count; $totalLines += $hitLines
    if ($count) {
        $perFile.Add([pscustomobject][ordered]@{
                개수 = $count; 줄 = $hitLines; 파일 = [System.IO.Path]::GetRelativePath($folder, $f.FullName)
                '고친 시각' = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); 인코딩 = (Get-EncodingName $enc)
            })
    }
}

function Show-Failures {
    Write-Host ''
    Write-Host "[읽지 못한 곳 $($failures.Count)곳]"
    Show-Table @($failures | Select-Object -First $Config.ShowMax) @('자리', '이유')
    if ($failures.Count -gt $Config.ShowMax) { Write-Host "… 그 밖에 $($failures.Count - $Config.ShowMax)곳" }
}

if (-not $total) {
    if ($failures.Count) {
        Show-Failures
        Write-Host "읽은 파일에서는 찾은 것이 없지만, 읽지 못한 곳이 $($failures.Count)곳 있어 「없음」으로 볼 수 없습니다. 권한 · 잠금을 확인하고 다시 실행하세요."
        exit 1
    }
    Write-Host $(if ($files.Count) { '찾은 것이 없습니다.' } else { "볼 파일이 없습니다: $folder ($Filter$(if ($LastDays) { ", 최근 ${LastDays}일" }))" })
    return
}
Write-Host "찾은 것 ${total}개 · 줄 ${totalLines}개 · 파일 $($perFile.Count)개"
Write-Host ''
Write-Host '[파일별]'
Show-Table @($perFile | Sort-Object 개수 -Descending | Select-Object -First $Config.ShowMax) @('개수', '줄', '파일', '고친 시각', '인코딩')
Write-Host ''
Write-Host '[찾은 글자별]'
$values = @($perValue.Values | ForEach-Object { [pscustomobject]@{ 개수 = $_.N; '찾은 글자' = $_.Text } } | Sort-Object 개수 -Descending)
Show-Table @($values | Select-Object -First $Config.ShowMax) @('개수', '찾은 글자')
if ($values.Count -gt $Config.ShowMax) { Write-Host "… 그 밖에 $($values.Count - $Config.ShowMax)가지" }
Write-Host ''
Write-Host "[처음 $([Math]::Min($Config.ShowLines, $lines.Count))줄]"
foreach ($l in ($lines | Select-Object -First $Config.ShowLines)) {
    $short = if ($l.내용.Length -gt 160) { $l.내용.Substring(0, 160) + '…' } else { $l.내용 }
    Write-Host "$([System.IO.Path]::GetFileName($l.파일)):$($l.줄): $short"
}
if ($totalLines -gt $lines.Count) { Write-Host "CSV에는 처음 $($lines.Count)줄만 남깁니다 (설정 블록의 MaxLines). 개수는 모두 셌습니다." }
$out = Get-OutputPath $Config.OutputName '.csv'
$lines | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
Write-Host "저장: $out"
if ($failures.Count) {
    Show-Failures
    Write-Host "부분 완료: 읽지 못한 곳이 $($failures.Count)곳 있습니다. 위 결과는 읽은 파일만 센 것입니다."
    exit 1
}

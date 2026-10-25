<#
.SYNOPSIS
    폴더의 로그 파일들에서 글자 · 정규식을 찾아 파일별 · 찾은 글자별 개수를 세고, 찾은 줄을 CSV로 저장한다.

.DESCRIPTION
    - 대상 폴더에서 Filter에 맞는 파일(기본 *.log)을 읽는다. 하위 폴더는 Recurse를 켤 때만 본다.
    - Pattern은 정규식이다. 여러 개는 |로 잇는다 (예: ERROR|Exception|timeout). 글자 그대로 찾으려면 SimpleMatch를 켠다.
    - 화면: 파일별 개수, 찾은 글자별 개수(예: 오류 코드별), 처음 몇 줄.
      찾은 줄은 output 폴더에 날짜가 붙은 CSV로 저장한다: 파일 · 줄 번호 · 고친 시각 · 찾은 글자 · 줄 내용.
    - 파일마다 UTF-8인지 ANSI(CP949)인지 앞부분을 보고 골라 읽는다. 한글 로그가 깨지지 않게 하려는 것이다.
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
    대소문자를 가린다

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
    [switch]$CaseSensitive
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    MaxLines     = 100000                              # CSV에 남길 최대 줄 수 (넘으면 개수만 센다)
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

# 파일 앞부분(64KB)으로 인코딩을 고른다: BOM → 그대로, UTF-8로 읽히면 UTF-8, 아니면 CP949
function Get-FileEncoding([string]$Path) {
    $buffer = [byte[]]::new(65536)
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { $read = $stream.Read($buffer, 0, $buffer.Length) } finally { $stream.Dispose() }
    if ($read -ge 3 -and $buffer[0] -eq 0xEF -and $buffer[1] -eq 0xBB -and $buffer[2] -eq 0xBF) { return [System.Text.UTF8Encoding]::new($false) }
    if ($read -ge 2 -and $buffer[0] -eq 0xFF -and $buffer[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
    if ($read -ge 2 -and $buffer[0] -eq 0xFE -and $buffer[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode }
    # 끝에서 잘린 글자 하나 때문에 틀리지 않게 마지막 3바이트는 빼고 본다
    $check = if ($read -eq $buffer.Length) { $read - 3 } else { $read }
    try { [void][System.Text.UTF8Encoding]::new($false, $true).GetString($buffer, 0, [Math]::Max(0, $check)); [System.Text.UTF8Encoding]::new($false) }
    catch { [System.Text.Encoding]::GetEncoding(949) }
}

function Format-Line([string]$Text) {
    $t = $Text.TrimEnd()
    if ($t.Length -gt $Config.LineLength) { $t.Substring(0, $Config.LineLength) + '…' } else { $t }
}

# ===== 본문 =====
$folder = $TargetFolder.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "폴더가 없거나 열 수 없습니다: $folder" }
$folder = (Resolve-Path -LiteralPath $folder).ProviderPath
if (-not $Filter) { $Filter = '*' }
if (-not $SimpleMatch) {
    try { [void][regex]::new($Pattern) } catch { throw "Pattern이 올바른 정규식이 아닙니다: $Pattern ($($_.Exception.InnerException.Message)) — 글자 그대로 찾으려면 SimpleMatch를 켜세요." }
}

$files = @(Get-ChildItem -LiteralPath $folder -Filter $Filter -File -Recurse:$Recurse -ErrorAction SilentlyContinue)
if ($LastDays) { $after = (Get-Date).AddDays(-$LastDays); $files = @($files | Where-Object LastWriteTime -ge $after) }
$files = @($files | Sort-Object FullName)
if (-not $files.Count) { Write-Host "볼 파일이 없습니다: $folder ($Filter$(if ($LastDays) { ", 최근 ${LastDays}일" }))"; return }
Write-Host "파일 $($files.Count)개에서 찾는 중: $Pattern$(if ($SimpleMatch) { ' (글자 그대로)' })$(if ($CaseSensitive) { ' (대소문자 가림)' })"

$lines = [System.Collections.Generic.List[object]]::new()
$perFile = [System.Collections.Generic.List[object]]::new()
$perValue = @{}
$total = 0
$unread = 0
foreach ($f in $files) {
    try {
        $enc = Get-FileEncoding $f.FullName
        $hits = @(Select-String -LiteralPath $f.FullName -Pattern $Pattern -Encoding $enc -SimpleMatch:$SimpleMatch -CaseSensitive:$CaseSensitive -AllMatches)
    } catch { $unread++; Write-Host "  읽지 못함: $($f.FullName) ($($_.Exception.Message))"; continue }
    if (-not $hits.Count) { continue }
    $count = 0
    foreach ($h in $hits) {
        # SimpleMatch는 Matches가 비어 있을 수 있어서, 그때는 줄 하나를 찾은 것 하나로 센다
        $found = @(if ($h.Matches.Count) { $h.Matches | ForEach-Object Value } else { $Pattern })
        foreach ($value in $found) {
            $count++
            $key = if ($CaseSensitive) { $value } else { $value.ToUpperInvariant() }
            if (-not $perValue.ContainsKey($key)) { $perValue[$key] = @{ Text = $value; Count = 0 } }
            $perValue[$key].Count++
        }
        if ($lines.Count -lt $Config.MaxLines) {
            $lines.Add([pscustomobject][ordered]@{
                    파일          = $f.FullName
                    줄            = $h.LineNumber
                    '파일 고친 시각' = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                    '찾은 글자'   = (@($found | Select-Object -Unique) -join ', ')
                    내용          = Format-Line $h.Line
                })
        }
    }
    $total += $count
    $perFile.Add([pscustomobject][ordered]@{
            개수 = $count; 줄 = $hits.Count; 파일 = [System.IO.Path]::GetRelativePath($folder, $f.FullName)
            '고친 시각' = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); 인코딩 = $(switch ($enc.CodePage) { 949 { 'CP949' } 65001 { 'UTF-8' } default { $enc.WebName } })
        })
}

if ($unread) { Write-Host "읽지 못한 파일: ${unread}개" }
if (-not $total) { Write-Host '찾은 것이 없습니다.'; return }
Write-Host "찾은 것 ${total}개 · 줄 $(($perFile | Measure-Object 줄 -Sum).Sum)개 · 파일 $($perFile.Count)개"
Write-Host ''
Write-Host '[파일별]'
Show-Table @($perFile | Sort-Object 개수 -Descending | Select-Object -First $Config.ShowMax) @('개수', '줄', '파일', '고친 시각', '인코딩')
Write-Host ''
Write-Host '[찾은 글자별]'
$values = @($perValue.Values | ForEach-Object { [pscustomobject]@{ 개수 = $_.Count; '찾은 글자' = $_.Text } } | Sort-Object 개수 -Descending)
Show-Table @($values | Select-Object -First $Config.ShowMax) @('개수', '찾은 글자')
if ($values.Count -gt $Config.ShowMax) { Write-Host "… 그 밖에 $($values.Count - $Config.ShowMax)가지" }
Write-Host ''
Write-Host "[처음 $([Math]::Min($Config.ShowLines, $lines.Count))줄]"
foreach ($l in ($lines | Select-Object -First $Config.ShowLines)) {
    $short = if ($l.내용.Length -gt 160) { $l.내용.Substring(0, 160) + '…' } else { $l.내용 }
    Write-Host "$([System.IO.Path]::GetFileName($l.파일)):$($l.줄): $short"
}
if ($lines.Count -ge $Config.MaxLines) { Write-Host "CSV에는 처음 $($Config.MaxLines)줄만 남깁니다 (설정 블록의 MaxLines)." }
$out = Get-OutputPath $Config.OutputName '.csv'
$lines | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
Write-Host "저장: $out"

<#
.SYNOPSIS
    최근 N시간 동안 Windows 이벤트 로그(System · Application)의 오류 · 경고를 모아 많이 난 순으로 보여 주고 CSV로 저장한다.

.DESCRIPTION
    - 기본은 이 PC의 System · Application 로그에서 위험 · 오류 · 경고 수준만 읽는다.
    - 화면에는 같은 원본 · 이벤트 ID끼리 묶어 횟수 · 마지막 시각 · 메시지 한 줄을 많은 순으로 보인다 (장애 시각 전후 확인용).
    - 이벤트 하나하나는 output 폴더에 날짜가 붙은 CSV로 저장한다 (Excel 2016에서 한글이 깨지지 않게 UTF-8 BOM).
    - 관리자 권한 없이 읽을 수 있는 로그만 본다. Security 로그처럼 권한이 필요한 로그는 「읽지 못함」으로 알리고 넘어간다.
    - 로그를 지우거나 설정을 바꾸지 않는다.

.PARAMETER Hours
    지금부터 몇 시간 전까지 볼지

.PARAMETER Level
    볼 수준: 오류만(위험 · 오류) · 오류와 경고

.PARAMETER LogNames
    볼 로그. 쉼표로 여러 개 (예: System, Application, Microsoft-Windows-PowerShell/Operational). 비우면 설정 블록의 LogNames

.EXAMPLE
    .\Get-EventLogError.ps1
    최근 24시간의 System · Application 오류 · 경고를 본다.

.EXAMPLE
    .\Get-EventLogError.ps1 -Hours 2 -Level 오류만
    방금 장애 전후 2시간의 오류만 본다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateRange(1, 8760)][int]$Hours = 24,
    [ValidateSet('오류만', '오류와 경고')][string]$Level = '오류와 경고',
    [string]$LogNames
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    LogNames     = @('System', 'Application')          # 기본으로 볼 로그
    MaxEvents    = 20000                                # 로그 하나에서 읽을 최대 개수 (너무 많으면 느려진다)
    ShowMax      = 30                                   # 화면에 보일 묶음 수
    OutputFolder = Join-Path $PSScriptRoot 'output'     # 결과(CSV)를 저장할 폴더
    OutputName   = '이벤트로그'                          # 결과 파일 이름 (뒤에 날짜가 붙는다)
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

$script:levelText = @{ 1 = '위험'; 2 = '오류'; 3 = '경고' }

# 메시지를 한 줄로 (줄바꿈 · 여러 칸 공백을 하나로)
function Format-OneLine([string]$Text, [int]$Max) {
    if (-not $Text) { return '' }
    $one = ($Text -replace '\s+', ' ').Trim()
    if ($one.Length -gt $Max) { $one.Substring(0, $Max) + '…' } else { $one }
}

# ===== 본문 =====
$logs = @(if ($LogNames) { $LogNames -split '[,;\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $Config.LogNames })
$levels = if ($Level -eq '오류만') { @(1, 2) } else { @(1, 2, 3) }
$since = (Get-Date).AddHours(-$Hours)
Write-Host "로그: $($logs -join ', ') · $($since.ToString('yyyy-MM-dd HH:mm')) 이후 · $Level"

$events = [System.Collections.Generic.List[object]]::new()
foreach ($log in $logs) {
    try {
        $found = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Level = $levels; StartTime = $since } -MaxEvents $Config.MaxEvents -ErrorAction Stop)
        if ($found.Count -ge $Config.MaxEvents) { Write-Host "  $log`: $($Config.MaxEvents)개까지만 읽었습니다 (설정 블록의 MaxEvents). 시간을 줄여 보세요." }
        else { Write-Host "  $log`: $($found.Count)개" }
        foreach ($e in $found) { $events.Add($e) }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { Write-Host "  $log`: 0개" }
        else { Write-Host "  $log`: 읽지 못함 ($($_.Exception.Message))" }
    }
}
if (-not $events.Count) { Write-Host '해당하는 이벤트가 없습니다.'; return }

$rows = @(foreach ($e in ($events | Sort-Object TimeCreated -Descending)) {
        $message = $null
        try { $message = $e.Message } catch { }
        [pscustomobject][ordered]@{
            시각       = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
            로그       = $e.LogName
            수준       = $(if ($script:levelText.ContainsKey([int]$e.Level)) { $script:levelText[[int]$e.Level] } else { [string]$e.Level })
            원본       = $e.ProviderName
            '이벤트 ID' = $e.Id
            메시지     = $(if ($message) { Format-OneLine $message 2000 } else { '(메시지 없음: 원본의 설명 파일을 찾지 못함)' })
        }
    })

# 같은 로그 · 원본 · ID끼리 묶는다
$groups = @($rows | Group-Object 로그, 원본, '이벤트 ID' | Sort-Object Count -Descending | ForEach-Object {
        $first = $_.Group[0]   # 시각 내림차순이라 첫 줄이 가장 최근이다
        [pscustomobject][ordered]@{
            횟수          = $_.Count
            수준          = $first.수준
            로그          = $first.로그
            원본          = $first.원본
            ID            = $first.'이벤트 ID'
            '마지막 시각' = $first.시각
            메시지        = Format-OneLine $first.메시지 90
        }
    })
$byLevel = @($rows | Group-Object 수준 | ForEach-Object { "$($_.Name) $($_.Count)" })
Write-Host "모두 $($rows.Count)개 ($($byLevel -join ' · ')) · 종류 $($groups.Count)가지"
Show-Table @($groups | Select-Object -First $Config.ShowMax) @('횟수', '수준', '로그', '원본', 'ID', '마지막 시각', '메시지')
if ($groups.Count -gt $Config.ShowMax) { Write-Host "… 그 밖에 $($groups.Count - $Config.ShowMax)가지는 CSV에 있습니다." }
$out = Get-OutputPath $Config.OutputName '.csv'
$rows | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
Write-Host "저장: $out"

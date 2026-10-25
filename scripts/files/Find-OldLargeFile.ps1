<#
.SYNOPSIS
    폴더에서 큰 파일 · 오래된 파일을 찾아 크기 순으로 보여 주고 CSV로 저장한다 (공유 폴더 정리용).

.DESCRIPTION
    - 대상 폴더와 하위 폴더 전체에서 MinSizeMB 이상이고 OlderThanDays일 넘게 고치지 않은 파일을 찾는다.
      둘 다 넣으면 두 조건을 모두 맞는 파일만, 0으로 두면 그 조건은 보지 않는다.
    - 결과는 output 폴더에 날짜가 붙은 CSV로 저장한다 (Excel 2016에서 한글이 깨지지 않게 UTF-8 BOM).
      화면에는 큰 것부터 설정 블록의 ShowMax개만 보인다.
    - 파일을 지우거나 옮기지 않는다.
    - 읽지 못한 폴더(권한 등)가 있으면 그 자리를 보이고 실패로 끝난다 (업무 탭에 「실패」). 찾은 파일은 「부분 완료」로 보인다.
    - 바로 가기 폴더(정션 · 심볼릭 링크)와 시스템 파일은 보지 않는다.

.PARAMETER TargetFolder
    찾을 폴더 (예: D:\공유, \\fileserver\share\팀)

.PARAMETER MinSizeMB
    이 크기(MB) 이상인 파일만. 0이면 크기는 보지 않는다

.PARAMETER OlderThanDays
    이 일수보다 오래 고치지 않은 파일만. 0이면 날짜는 보지 않는다

.PARAMETER Filter
    대상 파일 (예: *.zip, *.iso). 비우면 모든 파일

.EXAMPLE
    .\Find-OldLargeFile.ps1 -TargetFolder \\fileserver\share\팀 -MinSizeMB 500
    500MB 이상인 파일을 찾는다.

.EXAMPLE
    .\Find-OldLargeFile.ps1 -TargetFolder D:\백업 -MinSizeMB 0 -OlderThanDays 365 -Filter *.bak
    1년 넘게 고치지 않은 .bak 파일을 찾는다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetFolder,
    [ValidateRange(0, 10485760)][int]$MinSizeMB = 100,
    [ValidateRange(0, 36500)][int]$OlderThanDays = 0,
    [string]$Filter = '*'
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    ShowMax      = 30                                  # 화면에 보일 줄 수 (CSV에는 모두 남는다)
    OutputFolder = Join-Path $PSScriptRoot 'output'    # 결과를 저장할 폴더
    OutputName   = '큰파일_오래된파일'                   # 결과 파일 이름 (뒤에 날짜가 붙는다)
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

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1TB) { '{0:N2} TB' -f ($Bytes / 1TB) } elseif ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) } else { '{0:N1} MB' -f ($Bytes / 1MB) }
}

# 폴더 아래 파일을 모두 찾는다. 읽지 못한 폴더는 건너뛰어 숨기지 않고 $Failures에 모은다.
# 바로 가기 폴더(정션 · 심볼릭 링크)와 시스템 파일은 보지 않는다
function Get-AllFiles([string]$Root, [string]$Pattern, $Failures) {
    $options = [System.IO.EnumerationOptions]::new()
    $options.IgnoreInaccessible = $false
    $options.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint -bor [System.IO.FileAttributes]::System
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        $info = [System.IO.DirectoryInfo]::new($dir)
        try {
            foreach ($f in $info.EnumerateFiles($Pattern, $options)) { $f }
            foreach ($d in $info.EnumerateDirectories('*', $options)) { $stack.Push($d.FullName) }
        } catch {
            $Failures.Add([pscustomobject]@{ 자리 = $dir; 이유 = $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }) })
        }
    }
}

function Show-Failures($Failures) {
    Write-Host "읽지 못한 곳 $($Failures.Count)곳:"
    foreach ($f in ($Failures | Select-Object -First 10)) { Write-Host "  $($f.자리) ($($f.이유))" }
    if ($Failures.Count -gt 10) { Write-Host "  … 그 밖에 $($Failures.Count - 10)곳" }
}

# ===== 본문 =====
$folder = $TargetFolder.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "폴더가 없거나 열 수 없습니다: $folder" }
$folder = (Resolve-Path -LiteralPath $folder).ProviderPath
if (-not $Filter) { $Filter = '*' }
if (-not $MinSizeMB -and -not $OlderThanDays) { Write-Host '크기 · 날짜 조건이 모두 0이라 모든 파일을 보입니다.' }

$minBytes = [long]$MinSizeMB * 1MB
$before = (Get-Date).AddDays(-$OlderThanDays)
$now = Get-Date
# 읽을 수 없는 폴더는 건너뛰고, 바로 가기 폴더를 따라가 같은 파일을 두 번 세거나 끝없이 도는 일을 막는다
$failures = [System.Collections.Generic.List[object]]::new()


Write-Host "찾는 중: $folder ($Filter, $(if ($MinSizeMB) { "${MinSizeMB}MB 이상" } else { '크기 상관없음' }), $(if ($OlderThanDays) { "${OlderThanDays}일 넘게 안 고침" } else { '날짜 상관없음' }))"
$scanned = 0
$found = [System.Collections.Generic.List[object]]::new()
foreach ($f in Get-AllFiles $folder $Filter $failures) {
    $scanned++
    if ($f.Length -lt $minBytes) { continue }
    if ($OlderThanDays -and $f.LastWriteTime -gt $before) { continue }
    $found.Add([pscustomobject][ordered]@{
            '크기(MB)'  = [Math]::Round($f.Length / 1MB, 1)
            '고친 날짜' = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            '지난 일수' = [int][Math]::Floor(($now - $f.LastWriteTime).TotalDays)
            이름        = $f.Name
            폴더        = $f.DirectoryName
            경로        = $f.FullName
            Bytes       = $f.Length
        })
}

$rows = @($found | Sort-Object Bytes -Descending)
$total = 0L; foreach ($r in $rows) { $total += $r.Bytes }
Write-Host "본 파일 ${scanned}개 중 $($rows.Count)개, 합계 $(Format-Size ([double]$total))"
if (-not $rows.Count) {
    if ($failures.Count) {
        Show-Failures $failures
        Write-Host '읽은 폴더에서는 해당하는 파일이 없지만, 읽지 못한 곳이 있어 「없음」으로 볼 수 없습니다. 권한을 확인하고 다시 실행하세요.'
        exit 1
    }
    return
}
Show-Table @($rows | Select-Object -First $Config.ShowMax) @('크기(MB)', '고친 날짜', '지난 일수', '이름', '폴더')
if ($rows.Count -gt $Config.ShowMax) { Write-Host "… 그 밖에 $($rows.Count - $Config.ShowMax)개는 CSV에 있습니다." }
$out = Get-OutputPath $Config.OutputName '.csv'
$rows | Select-Object -ExcludeProperty Bytes | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
Write-Host "저장: $out"
if ($failures.Count) {
    Show-Failures $failures
    Write-Host '부분 완료: 위 결과는 읽은 폴더만 찾은 것입니다.'
    exit 1
}

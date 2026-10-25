<#
.SYNOPSIS
    두 폴더를 견줘 한쪽에만 있는 파일과 내용이 다른 파일을 보여 주고 CSV로 저장한다 (백업 · 배포 확인용).

.DESCRIPTION
    - 하위 폴더까지 같은 상대 경로의 파일끼리 견준다. 결과는 「왼쪽에만」 · 「오른쪽에만」 · 「다름」 · 「같음」이다.
    - 기본은 크기와 고친 시각으로 견준다 (빠름). 크기가 같고 시각만 다르면 「시각만 다름」이다.
      CompareHash를 켜면 크기가 같은 파일의 내용을 해시(SHA-256)로 견준다 (정확하지만 느림).
    - 결과는 output 폴더에 날짜가 붙은 CSV로 저장한다. 「같음」은 IncludeSame을 켤 때만 CSV에 넣는다.
    - 읽지 못한 폴더(권한 등)가 있으면 그 아래 파일은 「확인 못 함」으로 두고, 「모두 같습니다」라고 결론 내지 않는다.
      실패한 자리를 보이고 「부분 완료」로 실패 종료한다 (업무 탭에 「실패」).
    - 두 폴더 모두 읽기만 한다. 복사 · 삭제는 하지 않는다.

.PARAMETER LeftFolder
    기준 폴더 (예: 원본)

.PARAMETER RightFolder
    견줄 폴더 (예: 백업, \\fileserver\share\백업)

.PARAMETER Filter
    대상 파일 (예: *.xlsx). 비우면 모든 파일

.PARAMETER CompareHash
    크기가 같은 파일은 내용(해시)까지 견준다. 고친 시각은 보지 않는다

.PARAMETER IncludeSame
    같은 파일도 CSV에 넣는다

.EXAMPLE
    .\Compare-Folder.ps1 -LeftFolder D:\배포\v2 -RightFolder \\fileserver\share\배포\v2
    배포 폴더가 원본과 같은지 크기 · 시각으로 견준다.

.EXAMPLE
    .\Compare-Folder.ps1 -LeftFolder D:\원본 -RightFolder E:\백업 -CompareHash
    내용까지 견준다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LeftFolder,
    [Parameter(Mandatory)][string]$RightFolder,
    [string]$Filter = '*',
    [switch]$CompareHash,
    [switch]$IncludeSame
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    TimeToleranceSeconds = 2                                   # 고친 시각이 이만큼 안에서 다르면 같은 것으로 본다 (FAT · NAS는 2초 단위)
    ShowMax              = 40                                  # 화면에 보일 줄 수 (CSV에는 모두 남는다)
    OutputFolder         = Join-Path $PSScriptRoot 'output'    # 결과를 저장할 폴더
    OutputName           = '폴더비교'                           # 결과 파일 이름 (뒤에 날짜가 붙는다)
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

function Resolve-Folder([string]$Path, [string]$Label) {
    $p = $Path.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw "$Label 폴더가 없거나 열 수 없습니다: $p" }
    (Resolve-Path -LiteralPath $p).ProviderPath
}


# 폴더 아래 파일을 모두 찾는다. 읽지 못한 폴더는 건너뛰어 숨기지 않고 $Failures에 모은다.
# 바로 가기 폴더(정션 · 심볼릭 링크)는 따라가지 않는다
function Get-AllFiles([string]$Root, [string]$Pattern, $Failures, [string]$Side) {
    $fileOptions = [System.IO.EnumerationOptions]::new()
    $fileOptions.IgnoreInaccessible = $false
    $fileOptions.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
    $dirOptions = [System.IO.EnumerationOptions]::new()
    $dirOptions.IgnoreInaccessible = $false
    $dirOptions.AttributesToSkip = [System.IO.FileAttributes]::ReparsePoint
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count) {
        $dir = $stack.Pop()
        $info = [System.IO.DirectoryInfo]::new($dir)
        try {
            foreach ($f in $info.EnumerateFiles($Pattern, $fileOptions)) { $f }
            foreach ($d in $info.EnumerateDirectories('*', $dirOptions)) { $stack.Push($d.FullName) }
        } catch {
            $Failures.Add([pscustomobject]@{ 쪽 = $Side; 자리 = $dir; 상대 = [System.IO.Path]::GetRelativePath($Root, $dir); 이유 = $(if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }) })
        }
    }
}

# 폴더의 파일: 상대 경로(소문자) → FileInfo
function Get-FileMap([string]$Root, $Failures, [string]$Side) {
    $map = @{}
    foreach ($f in Get-AllFiles $Root $Filter $Failures $Side) {
        $map[[System.IO.Path]::GetRelativePath($Root, $f.FullName).ToLowerInvariant()] = $f
    }
    $map
}

function Get-ContentHash([string]$Path) {
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
    } catch { $null }
}

# ===== 본문 =====
$left = Resolve-Folder $LeftFolder '왼쪽(기준)'
$right = Resolve-Folder $RightFolder '오른쪽'
if (-not $Filter) { $Filter = '*' }
Write-Host "왼쪽: $left"
Write-Host "오른쪽: $right"
Write-Host "견주는 방법: $(if ($CompareHash) { '크기 + 내용(해시)' } else { '크기 + 고친 시각' })"

$failures = [System.Collections.Generic.List[object]]::new()
$l = Get-FileMap $left $failures '왼쪽'
$r = Get-FileMap $right $failures '오른쪽'
# 한쪽이라도 읽지 못한 폴더 아래의 파일은 견줄 수 없다 (「한쪽에만」 · 「같음」으로 잘못 보이지 않게)
$blind = @($failures | ForEach-Object { if ($_.상대 -eq '.') { '' } else { $_.상대.ToLowerInvariant() + '\' } } | Select-Object -Unique)
function Test-Blind([string]$Key) { foreach ($b in $blind) { if ($Key.StartsWith($b, [StringComparison]::Ordinal)) { return $true } }; $false }

$keys = @(@($l.Keys) + @($r.Keys) | Sort-Object -Unique)
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($k in $keys) {
    $a = $l[$k]; $b = $r[$k]
    $state = if (Test-Blind $k) { '확인 못 함 (폴더를 읽지 못함)' }
    elseif (-not $b) { '왼쪽에만' }
    elseif (-not $a) { '오른쪽에만' }
    elseif ($a.Length -ne $b.Length) { '다름 (크기)' }
    elseif ($CompareHash) {
        $ha = Get-ContentHash $a.FullName; $hb = Get-ContentHash $b.FullName
        if (-not $ha -or -not $hb) { '확인 못 함 (파일을 읽지 못함)' } elseif ($ha -eq $hb) { '같음' } else { '다름 (내용)' }
    }
    elseif ([Math]::Abs(($a.LastWriteTimeUtc - $b.LastWriteTimeUtc).TotalSeconds) -gt $Config.TimeToleranceSeconds) { '시각만 다름' }
    else { '같음' }
    $rows.Add([pscustomobject][ordered]@{
            상태              = $state
            '상대 경로'       = $(if ($a) { [System.IO.Path]::GetRelativePath($left, $a.FullName) } else { [System.IO.Path]::GetRelativePath($right, $b.FullName) })
            '왼쪽 크기(KB)'   = $(if ($a) { [long][Math]::Ceiling($a.Length / 1KB) } else { '' })
            '오른쪽 크기(KB)' = $(if ($b) { [long][Math]::Ceiling($b.Length / 1KB) } else { '' })
            '왼쪽 고친 시각'  = $(if ($a) { $a.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
            '오른쪽 고친 시각' = $(if ($b) { $b.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } else { '' })
        })
}
# 읽지 못한 폴더 자체도 결과에 한 줄씩 남긴다
foreach ($f in $failures) {
    $rows.Add([pscustomobject][ordered]@{
            상태 = "확인 못 함 ($($f.쪽) 폴더를 읽지 못함)"; '상대 경로' = $(if ($f.상대 -eq '.') { '(맨 위 폴더)' } else { "$($f.상대)\" })
            '왼쪽 크기(KB)' = ''; '오른쪽 크기(KB)' = ''; '왼쪽 고친 시각' = ''; '오른쪽 고친 시각' = ''
        })
}

$unknown = @($rows | Where-Object { $_.상태 -like '확인 못 함*' })
$summary = @($rows | Group-Object { if ($_.상태 -like '확인 못 함*') { '확인 못 함' } else { $_.상태 } } | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" })
Write-Host "결과 $($rows.Count)줄: $($summary -join ' · ')"
$diff = @($rows | Where-Object 상태 -ne '같음')
if (-not $diff.Count) { Write-Host '두 폴더의 파일이 모두 같습니다.' }
else {
    Show-Table @($diff | Select-Object -First $Config.ShowMax) @('상태', '상대 경로', '왼쪽 크기(KB)', '오른쪽 크기(KB)', '왼쪽 고친 시각', '오른쪽 고친 시각')
    if ($diff.Count -gt $Config.ShowMax) { Write-Host "… 그 밖에 $($diff.Count - $Config.ShowMax)개는 CSV에 있습니다." }
}
$save = @(if ($IncludeSame) { $rows } else { $diff })
if ($save.Count) {
    $out = Get-OutputPath $Config.OutputName '.csv'
    $save | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
    Write-Host "저장: $out"
}
if ($unknown.Count) {
    Write-Host "부분 완료: 읽지 못한 폴더 $($failures.Count)곳 · 확인 못 한 줄 $($unknown.Count)개. 그 부분은 같은지 알 수 없습니다. 권한 · 잠금을 확인하고 다시 실행하세요."
    foreach ($f in ($failures | Select-Object -First 10)) { Write-Host "  $($f.쪽): $($f.자리) ($($f.이유))" }
    exit 1
}
<#
.SYNOPSIS
    폴더에서 내용이 똑같은 파일(중복)을 찾아 묶음별로 보여 주고 CSV로 저장한다.

.DESCRIPTION
    - 먼저 크기가 같은 파일끼리 모으고, 그 파일만 해시(SHA-256)로 내용을 견준다. 이름이 달라도 내용이 같으면 중복이다.
    - 결과는 output 폴더에 날짜가 붙은 CSV로 저장한다: 묶음 번호 · 크기 · 경로 · 고친 날짜.
      Excel에서 묶음 번호로 정렬해 남길 파일을 고르면 된다.
    - 파일을 지우거나 옮기지 않는다.
    - 읽지 못한 폴더 · 파일(권한 · 잠금)이 있으면 그 자리를 보이고 실패로 끝난다 (업무 탭에 「실패」). 그때는 「중복 없음」으로 결론 내지 않고, 찾은 중복은 「부분 완료」로 보인다.
    - 큰 폴더는 해시를 구하는 데 시간이 걸린다. 진행 상황을 1,000개마다 보여 준다.

.PARAMETER TargetFolder
    찾을 폴더 (하위 폴더 포함)

.PARAMETER MinSizeKB
    이 크기(KB) 이상인 파일만 본다. 작은 파일을 빼면 빨라진다

.PARAMETER Filter
    대상 파일 (예: *.pdf). 비우면 모든 파일

.EXAMPLE
    .\Find-DuplicateFile.ps1 -TargetFolder \\fileserver\share\팀 -MinSizeKB 1024
    1MB 이상인 파일 중 중복을 찾는다.

.EXAMPLE
    .\Find-DuplicateFile.ps1 -TargetFolder D:\사진 -Filter *.jpg
    같은 사진이 여러 곳에 있는지 찾는다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetFolder,
    [ValidateRange(0, 10485760)][int]$MinSizeKB = 1,
    [string]$Filter = '*'
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    ShowMax      = 20                                  # 화면에 보일 묶음 수 (CSV에는 모두 남는다)
    OutputFolder = Join-Path $PSScriptRoot 'output'    # 결과를 저장할 폴더
    OutputName   = '중복파일'                           # 결과 파일 이름 (뒤에 날짜가 붙는다)
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
    if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) } elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) } else { '{0:N0} KB' -f [Math]::Ceiling($Bytes / 1KB) }
}

# 파일 내용의 SHA-256. 다른 프로그램이 잠갔거나 권한이 없으면 $null
function Get-ContentHash([string]$Path) {
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try { [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)) } finally { $stream.Dispose() }
    } catch { $null }
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
$minBytes = [Math]::Max(1, [long]$MinSizeKB * 1KB)   # 빈 파일(0바이트)은 모두 같아 보이므로 뺀다

$failures = [System.Collections.Generic.List[object]]::new()


Write-Host "파일 목록을 모으는 중: $folder"
$bySize = @{}
$count = 0
foreach ($f in Get-AllFiles $folder $Filter $failures) {
    if ($f.Length -lt $minBytes) { continue }
    $count++
    if (-not $bySize.ContainsKey($f.Length)) { $bySize[$f.Length] = [System.Collections.Generic.List[object]]::new() }
    $bySize[$f.Length].Add($f)
}
$candidates = @($bySize.Values | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_ })
Write-Host "본 파일 ${count}개 · 크기가 같은 파일 $($candidates.Count)개의 내용을 견주는 중"

$byHash = @{}
$done = 0
foreach ($f in $candidates) {
    $done++
    if ($done % 1000 -eq 0) { Write-Host "  … $done / $($candidates.Count)" }
    $hash = Get-ContentHash $f.FullName
    if (-not $hash) { $failures.Add([pscustomobject]@{ 자리 = $f.FullName; 이유 = '파일을 읽지 못함 (쓰는 중이거나 권한 없음)' }); continue }
    $key = "$($f.Length)|$hash"
    if (-not $byHash.ContainsKey($key)) { $byHash[$key] = [System.Collections.Generic.List[object]]::new() }
    $byHash[$key].Add($f)
}

# 낭비가 큰 묶음부터 (크기 × (개수 - 1))
$groups = @(@(foreach ($list in $byHash.Values) { if ($list.Count -gt 1) { [pscustomobject]@{ Files = $list.ToArray(); Waste = $list[0].Length * ($list.Count - 1) } } }) | Sort-Object Waste -Descending)
if (-not $groups.Count) {
    if ($failures.Count) {
        Show-Failures $failures
        Write-Host '읽은 파일에서는 중복이 없지만, 읽지 못한 곳이 있어 「중복 없음」으로 볼 수 없습니다. 권한 · 잠금을 확인하고 다시 실행하세요.'
        exit 1
    }
    Write-Host '중복 파일이 없습니다.'; return
}

$rows = [System.Collections.Generic.List[object]]::new()
$wasted = 0
for ($i = 0; $i -lt $groups.Count; $i++) {
    $g = $groups[$i].Files
    $wasted += $groups[$i].Waste
    foreach ($f in ($g | Sort-Object LastWriteTime)) {
        $rows.Add([pscustomobject][ordered]@{
                묶음        = $i + 1
                개수        = $g.Count
                '크기(KB)'  = [long][Math]::Ceiling($f.Length / 1KB)
                '고친 날짜' = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
                이름        = $f.Name
                폴더        = $f.DirectoryName
                경로        = $f.FullName
            })
    }
}
Write-Host "중복 묶음 $($groups.Count)개 · 파일 $($rows.Count)개 · 하나씩만 남기면 줄어드는 크기 $(Format-Size $wasted)"
Show-Table @($rows | Where-Object 묶음 -le $Config.ShowMax) @('묶음', '크기(KB)', '고친 날짜', '이름', '폴더')
if ($groups.Count -gt $Config.ShowMax) { Write-Host "… 그 밖에 $($groups.Count - $Config.ShowMax)묶음은 CSV에 있습니다." }
$out = Get-OutputPath $Config.OutputName '.csv'
$rows | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
Write-Host "저장: $out"
if ($failures.Count) {
    Show-Failures $failures
    Write-Host '부분 완료: 위 결과는 읽은 파일만 견준 것입니다.'
    exit 1
}

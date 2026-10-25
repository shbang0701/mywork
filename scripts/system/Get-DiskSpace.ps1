<#
.SYNOPSIS
    이 PC의 드라이브와 공유 폴더(\\서버\공유)의 전체 · 남은 용량을 한 표로 보여 주고, 모자라는 곳을 알려 준다.

.DESCRIPTION
    - 로컬 드라이브 · 연결된 네트워크 드라이브 · 이동식 드라이브를 모두 본다 (CD처럼 준비되지 않은 드라이브는 뺀다).
    - SharePaths(또는 설정 블록의 SharePaths)에 적은 공유 폴더도 같이 본다. 남은 용량은 내 계정이 쓸 수 있는 만큼이다 (할당량 반영).
    - 남은 공간이 WarnPercent % 아래면 「부족」이다.
    - Windows 기본 .NET과 Scripting.FileSystemObject(공유 폴더 용량 읽기)만 쓴다. 관리자 권한이 필요 없다.
    - 보기만 한다. SaveCsv를 켜면 결과를 output 폴더에 날짜가 붙은 CSV로 저장한다.

.PARAMETER SharePaths
    함께 볼 공유 폴더. 쉼표로 여러 개 (예: \\fileserver\share, \\SRV-01\backup). 비우면 설정 블록의 SharePaths

.PARAMETER WarnPercent
    남은 공간이 이 % 아래면 「부족」으로 알린다

.PARAMETER SaveCsv
    결과를 CSV로 저장한다

.EXAMPLE
    .\Get-DiskSpace.ps1
    이 PC의 드라이브 용량을 본다.

.EXAMPLE
    .\Get-DiskSpace.ps1 -SharePaths '\\fileserver\share, \\SRV-01\backup' -WarnPercent 15
    공유 폴더 두 곳도 같이 보고, 15% 아래면 알린다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$SharePaths,
    [ValidateRange(1, 99)][int]$WarnPercent = 10,
    [switch]$SaveCsv
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    SharePaths   = @(                                  # 늘 같이 볼 공유 폴더. 예시는 가짜 값이라 주석으로 둔다
        # '\\fileserver\share'
        # '\\SRV-01\backup'
    )
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

function New-Row([string]$Where, [string]$Label, [string]$Kind, [double]$Total, [double]$Free, [string]$Note) {
    $pct = if ($Total -gt 0) { [Math]::Round(100 * $Free / $Total, 1) } else { 0 }
    if ($Note) {
        return [pscustomobject][ordered]@{ 위치 = $Where; 이름 = $Label; 종류 = $Kind; '전체(GB)' = ''; '사용(GB)' = ''; '남음(GB)' = ''; '남음(%)' = ''; 상태 = '확인 못 함'; 메모 = $Note }
    }
    [pscustomobject][ordered]@{
        위치          = $Where
        이름          = $Label
        종류          = $Kind
        '전체(GB)'    = [Math]::Round($Total / 1GB, 1)
        '사용(GB)'    = [Math]::Round(($Total - $Free) / 1GB, 1)
        '남음(GB)'    = [Math]::Round($Free / 1GB, 1)
        '남음(%)'     = $pct
        상태          = $(if ($pct -lt $WarnPercent) { '부족' } else { '정상' })
        메모          = $Note
    }
}

$script:kindText = @{ Fixed = '로컬'; Network = '네트워크'; Removable = '이동식'; Ram = '램 디스크' }

# ===== 본문 =====
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
    $kind = [string]$d.DriveType
    if (-not $script:kindText.ContainsKey($kind)) { continue }   # CD-ROM · 알 수 없는 드라이브는 뺀다
    try {
        if (-not $d.IsReady) { continue }
        $rows.Add((New-Row $d.Name.TrimEnd('\') $d.VolumeLabel $script:kindText[$kind] $d.TotalSize $d.AvailableFreeSpace ''))
    } catch { $rows.Add((New-Row $d.Name.TrimEnd('\') '' $script:kindText[$kind] 0 0 $_.Exception.Message)) }
}

$shares = @(if ($SharePaths) { $SharePaths -split '[,;\r\n]+' } else { $Config.SharePaths })
$shares = @($shares | Where-Object { $_ } | ForEach-Object { $_.Trim().Trim('"').TrimEnd('\') } | Where-Object { $_ })
if ($shares.Count) {
    $fso = New-Object -ComObject Scripting.FileSystemObject
    try {
        foreach ($s in $shares) {
            if ($s -notmatch '^\\\\[^\\]+\\[^\\]+') { $rows.Add((New-Row $s '' '공유 폴더' 0 0 '\\서버\공유 모양으로 적으세요')); continue }
            try {
                # 공유 폴더의 하위 폴더를 적어도 그 공유 전체의 용량을 본다
                $drive = $fso.GetDrive($Matches[0])
                $rows.Add((New-Row $s $drive.ShareName '공유 폴더' $drive.TotalSize $drive.AvailableSpace ''))
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($drive)
            } catch { $rows.Add((New-Row $s '' '공유 폴더' 0 0 "열 수 없음 (없는 공유이거나 권한 없음): $($_.Exception.Message)")) }
        }
    } finally { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($fso) }
}

if (-not $rows.Count) { Write-Host '볼 드라이브가 없습니다.'; return }
Show-Table $rows @('위치', '이름', '종류', '전체(GB)', '사용(GB)', '남음(GB)', '남음(%)', '상태', '메모')
$low = @($rows | Where-Object 상태 -eq '부족')
$bad = @($rows | Where-Object 상태 -eq '확인 못 함')
Write-Host "$($rows.Count)곳 · 부족(${WarnPercent}% 아래) $($low.Count)곳$(if ($low.Count) { ': ' + (($low | ForEach-Object 위치) -join ', ') })$(if ($bad.Count) { " · 확인 못 함 $($bad.Count)곳" })"
if ($SaveCsv) {
    $out = Get-OutputPath '디스크용량' '.csv'
    $rows | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
    Write-Host "저장: $out"
}

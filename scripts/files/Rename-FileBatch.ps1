<#
.SYNOPSIS
    폴더 안 파일 이름을 한꺼번에 바꾼다: 앞 · 뒤에 날짜 붙이기, 글자 찾아 바꾸기, 번호 매기기.

.DESCRIPTION
    - 대상 폴더에서 Filter에 맞는 파일만 바꾼다. 하위 폴더는 Recurse를 켤 때만 본다.
    - 먼저 -WhatIf(업무 탭의 [미리보기])로 바뀔 이름을 표로 보고, 맞으면 그대로 실행한다.
    - 바꿀 이름에 이미 파일이 있거나, 두 파일이 같은 이름이 되면 그 파일은 건너뛴다. 덮어쓰거나 지우지 않는다.
    - 바꾸기 전에 할 일(원래 이름 · 새 이름)을 output 폴더의 CSV에 「예정」으로 먼저 적고, 하나 바꿀 때마다 결과 줄을 바로 이어 적는다.
      도중에 끝나도(업무 탭 [취소] 포함) 「바꿈」 줄로 어디까지 바뀌었는지 알 수 있다. 되돌릴 때 이 표를 본다.
      기록 파일을 만들 수 없으면 아무것도 바꾸지 않고 끝낸다.
    - Office가 만드는 임시 파일(~$로 시작)은 건너뛴다.
    - 방식
      앞에 날짜: 20261025_보고서.xlsx · 뒤에 날짜: 보고서_20261025.xlsx
      찾아 바꾸기: 이름(확장자 빼고)에서 Find를 ReplaceWith로 바꾼다. 대소문자는 가리지 않는다
      번호 매기기: <NewName>_001.xlsx. NewName을 비우면 원래 이름 뒤에 번호를 붙인다

.PARAMETER TargetFolder
    이름을 바꿀 파일이 있는 폴더

.PARAMETER Mode
    바꾸는 방식: 앞에 날짜 · 뒤에 날짜 · 찾아 바꾸기 · 번호 매기기

.PARAMETER Filter
    대상 파일 (예: *.pdf, 보고서*.xlsx). 비우면 모든 파일

.PARAMETER Find
    찾아 바꾸기: 찾을 글자

.PARAMETER ReplaceWith
    찾아 바꾸기: 바꿀 글자 (비우면 찾은 글자를 지운다)

.PARAMETER NewName
    번호 매기기: 번호 앞에 둘 이름 (비우면 원래 이름 뒤에 번호)

.PARAMETER DateFrom
    날짜 붙이기: 오늘 날짜 · 파일을 고친 날짜

.PARAMETER SortBy
    번호 매기기: 번호를 매길 순서 (이름 · 고친 날짜)

.PARAMETER Recurse
    하위 폴더의 파일도 바꾼다

.EXAMPLE
    .\Rename-FileBatch.ps1 -TargetFolder D:\스캔 -Filter *.pdf -Mode '앞에 날짜' -WhatIf
    PDF 이름 앞에 오늘 날짜를 붙이면 어떻게 되는지 미리 본다.

.EXAMPLE
    .\Rename-FileBatch.ps1 -TargetFolder D:\사진 -Mode '번호 매기기' -NewName 현장사진 -SortBy '고친 날짜'
    고친 날짜 순으로 현장사진_001.jpg, 현장사진_002.jpg …로 바꾼다.

.EXAMPLE
    .\Rename-FileBatch.ps1 -TargetFolder D:\문서 -Mode '찾아 바꾸기' -Find '(최종)' -ReplaceWith ''
    이름에서 "(최종)"을 지운다.
#>
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$TargetFolder,
    [ValidateSet('앞에 날짜', '뒤에 날짜', '찾아 바꾸기', '번호 매기기')][string]$Mode = '앞에 날짜',
    [string]$Filter = '*',
    [string]$Find,
    [string]$ReplaceWith,
    [string]$NewName,
    [ValidateSet('오늘', '고친 날짜')][string]$DateFrom = '오늘',
    [ValidateSet('이름', '고친 날짜')][string]$SortBy = '이름',
    [switch]$Recurse
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    DateFormat   = 'yyyyMMdd'                          # 붙일 날짜 모양 (예: yyyy-MM-dd)
    Separator    = '_'                                 # 날짜 · 번호와 이름 사이 글자
    NumberDigits = 3                                   # 번호 자릿수 (3이면 001)
    NumberStart  = 1                                   # 첫 번호
    OutputFolder = Join-Path $PSScriptRoot 'output'    # 바꾼 기록(CSV)을 저장할 폴더
}
# =================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 결과 파일 경로: <이름>_yyyyMMdd_HHmmss.csv. 같은 이름이 있으면 번호를 붙여 덮어쓰지 않는다
function Get-OutputPath([string]$BaseName, [string]$Extension) {
    if (-not (Test-Path -LiteralPath $Config.OutputFolder)) { [void](New-Item -ItemType Directory -Path $Config.OutputFolder) }
    $stem = Join-Path $Config.OutputFolder ('{0}_{1:yyyyMMdd_HHmmss}' -f $BaseName, (Get-Date))
    $path = "$stem$Extension"; $n = 2
    while (Test-Path -LiteralPath $path) { $path = "${stem}_$n$Extension"; $n++ }
    $path
}

function ConvertTo-CsvLine([object[]]$Values) {
    @($Values | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ','
}

function Show-Table($Rows, [object[]]$Property) {
    $text = ($Rows | Format-Table -Property $Property -AutoSize | Out-String -Width 250).Trim("`r", "`n")
    if ($text) { Write-Host $text }
}

$script:badChars = [System.IO.Path]::GetInvalidFileNameChars()

# 새 이름을 쓸 수 없으면 이유, 쓸 수 있으면 빈 글자
function Test-NewName([string]$Name) {
    if (-not $Name.Trim()) { return '새 이름이 비었습니다' }
    if ($Name.IndexOfAny($script:badChars) -ge 0) { return '이름에 쓸 수 없는 글자가 있습니다 (\ / : * ? " < > |)' }
    if ($Name -match '[ .]$') { return '이름이 공백이나 마침표로 끝납니다' }
    ''
}

function Get-NewName($File, [int]$Index) {
    $base = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    $ext = $File.Extension
    $sep = $Config.Separator
    $date = if ($DateFrom -eq '고친 날짜') { $File.LastWriteTime.ToString($Config.DateFormat) } else { (Get-Date).ToString($Config.DateFormat) }
    switch ($Mode) {
        '앞에 날짜' { if ($File.Name.StartsWith("$date$sep")) { return $null }; "$date$sep$($File.Name)" }
        '뒤에 날짜' { if ($base.EndsWith("$sep$date")) { return $null }; "$base$sep$date$ext" }
        '찾아 바꾸기' {
            $replace = if ($ReplaceWith) { $ReplaceWith.Replace('$', '$$') } else { '' }
            ([regex]::Replace($base, [regex]::Escape($Find), $replace, 'IgnoreCase')) + $ext
        }
        '번호 매기기' {
            $number = ($Config.NumberStart + $Index).ToString().PadLeft($Config.NumberDigits, '0')
            $head = if ($NewName) { $NewName.Trim() } else { $base }
            "$head$sep$number$ext"
        }
    }
}

# ===== 본문 =====
$folder = $TargetFolder.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw "폴더가 없습니다: $folder" }
$folder = (Resolve-Path -LiteralPath $folder).ProviderPath
if ($Mode -eq '찾아 바꾸기' -and -not $Find) { throw '찾아 바꾸기는 Find(찾을 글자)를 넣어야 합니다.' }
if (-not $Filter) { $Filter = '*' }

$files = @(Get-ChildItem -LiteralPath $folder -Filter $Filter -File -Recurse:$Recurse | Where-Object { $_.Name -notlike '~$*' })
$files = @(if ($SortBy -eq '고친 날짜') { $files | Sort-Object LastWriteTime, FullName } else { $files | Sort-Object FullName })
if (-not $files.Count) { Write-Host "바꿀 파일이 없습니다: $folder ($Filter)"; return }

# 할 일을 먼저 모두 정한다. 같은 폴더에서 같은 이름이 되는 것 · 이미 있는 이름은 건너뛴다
$plan = [System.Collections.Generic.List[object]]::new()
$taken = @{}   # 폴더|새 이름(소문자) → 이번에 쓸 파일
$index = @{}   # 폴더별 번호
foreach ($f in $files) {
    $dir = $f.DirectoryName
    if (-not $index.ContainsKey($dir)) { $index[$dir] = 0 }
    $new = Get-NewName $f $index[$dir]
    if ($Mode -eq '번호 매기기') { $index[$dir]++ }
    $row = [pscustomobject][ordered]@{ 폴더 = $dir; '원래 이름' = $f.Name; '새 이름' = $new; 결과 = '' }
    if ($null -eq $new) { $row.'새 이름' = $f.Name; $row.결과 = '건너뜀: 이미 붙어 있음' }
    elseif ($new -ceq $f.Name) { $row.결과 = '건너뜀: 바뀌는 것 없음' }
    else {
        $why = Test-NewName $new
        $key = "$dir|$($new.ToLowerInvariant())"
        if ($why) { $row.결과 = "건너뜀: $why" }
        elseif ($taken.ContainsKey($key)) { $row.결과 = '건너뜀: 다른 파일과 같은 이름이 됨' }
        elseif ((Test-Path -LiteralPath (Join-Path $dir $new)) -and $new -ine $f.Name) { $row.결과 = '건너뜀: 같은 이름의 파일이 이미 있음' }
        else { $taken[$key] = $f; $row.결과 = '바꿀 것' }
    }
    $plan.Add([pscustomobject]@{ File = $f; Row = $row })
}

$todo = @($plan | Where-Object { $_.Row.결과 -eq '바꿀 것' })
$log = $null
$writer = $null
try {
    if ($todo.Count -and -not $WhatIfPreference) {
        # 바꾸기 전에 할 일 전체를 기록에 먼저 적는다. 기록을 못 만들면 아무것도 바꾸지 않는다.
        # 그 뒤 하나 바꿀 때마다 결과 줄을 바로 이어 적어서, 도중에 끝나도(업무 탭 [취소] 포함) 어디까지 바뀌었는지 남는다
        try {
            $log = Get-OutputPath '이름바꾸기' '.csv'
            $writer = [System.IO.StreamWriter]::new($log, $false, [System.Text.UTF8Encoding]::new($true))
            $writer.AutoFlush = $true
            $writer.WriteLine((ConvertTo-CsvLine @('순서', '시각', '폴더', '원래 이름', '새 이름', '결과')))
            $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            for ($i = 0; $i -lt $todo.Count; $i++) {
                $r = $todo[$i].Row
                $writer.WriteLine((ConvertTo-CsvLine @(($i + 1), $now, $r.폴더, $r.'원래 이름', $r.'새 이름', '예정')))
            }
        } catch {
            throw "기록 파일을 만들지 못해 아무것도 바꾸지 않았습니다: $($_.Exception.Message) — 설정 블록의 OutputFolder를 쓸 수 있는 폴더로 바꾸세요."
        }
        Write-Host "기록: $log"
    }
    for ($i = 0; $i -lt $todo.Count; $i++) {
        $p = $todo[$i]
        if ($WhatIfPreference) { $p.Row.결과 = '미리보기'; continue }
        if (-not $PSCmdlet.ShouldProcess((Join-Path $p.Row.폴더 $p.Row.'원래 이름'), "이름 바꾸기 → $($p.Row.'새 이름')")) { $p.Row.결과 = '건너뜀: 취소' }
        else {
            try {
                Rename-Item -LiteralPath $p.File.FullName -NewName $p.Row.'새 이름'
                $p.Row.결과 = '바꿈'
            } catch { $p.Row.결과 = "실패: $($_.Exception.Message)" }
        }
        $writer.WriteLine((ConvertTo-CsvLine @(($i + 1), (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $p.Row.폴더, $p.Row.'원래 이름', $p.Row.'새 이름', $p.Row.결과)))
    }
} finally {
    if ($writer) { $writer.Dispose() }
}

$rows = @($plan | ForEach-Object { $_.Row })
$showFolder = $Recurse.IsPresent
$columns = @(if ($showFolder) { '폴더' }) + @('원래 이름', '새 이름', '결과')
Show-Table $rows $columns
$done = @($rows | Where-Object 결과 -eq '바꿈').Count
$skipped = @($rows | Where-Object { $_.결과 -like '건너뜀*' }).Count
$failed = @($rows | Where-Object { $_.결과 -like '실패*' }).Count
if ($WhatIfPreference) {
    Write-Host "미리보기: $($todo.Count)개를 바꿀 수 있고 ${skipped}개는 건너뜁니다. 실제로는 아무것도 바꾸지 않았습니다."
    return
}
Write-Host "바꿈 ${done}개 · 건너뜀 ${skipped}개 · 실패 ${failed}개"
if ($log) { Write-Host "기록: $log" }
if ($failed) { throw "${failed}개 파일의 이름을 바꾸지 못했습니다. 위 표의 「실패」 줄을 보세요." }

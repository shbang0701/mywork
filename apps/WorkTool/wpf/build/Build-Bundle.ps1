<#
.SYNOPSIS
    WorkTool 새 버전(WPF)을 파일 하나(apps/WorkTool/dist/WorkTool-WPF.ps1)로 묶는다. 업무 PC에 복사 한 번으로 가져가기 위한 것이다.

.DESCRIPTION
    - Start-WorkTool.ps1의 「#region 모듈 불러오기 ~ #endregion」 구역을 core · addons 모듈 소스를 담은 New-Module 블록으로 바꾼다.
      모듈 코드는 문자열로 실행하지 않고 스크립트 블록 안에 그대로 들어간다 (Invoke-Expression 없음).
    - core 순서는 Start-WorkTool.ps1의 $coreModules를 따르고, addons는 Start-WorkTool.ps1과 같은 순서(전체 경로 순)로 넣는다.
    - 결과는 원본이 같으면 항상 같다 (날짜 · 커밋을 넣지 않음). 다시 만들어서 차이가 없으면 최신이다.
    - 저장소 맨 위에 worktool.zip(묶음 파일 + Start-WorkTool.cmd + 콘솔 없는 실행 보조 스크립트 + 예제 scripts\)도 같이 만든다.
      zip 안의 scripts\는 저장소 scripts/의 .ps1을 그대로 담는다. 풀고 켜면 업무 탭에 「예제 스크립트」로 보인다.

.EXAMPLE
    pwsh ./apps/WorkTool/wpf/build/Build-Bundle.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$src = Split-Path $PSScriptRoot -Parent
$outPath = Join-Path (Split-Path $src -Parent) 'dist' 'WorkTool-WPF.ps1'

function Get-SourceText([string]$Path) {
    [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n").TrimEnd("`n")
}

function Get-ModuleBlock([string]$Name, [string]$Path, [string]$Label) {
    $code = Get-SourceText $Path
    "# ---- $Label ----`nNew-Module -Name '$Name' -ScriptBlock {`n$code`n} | Import-Module -Force -DisableNameChecking`n# ---- $Label 끝 ----"
}

$entry = Get-SourceText (Join-Path $src 'Start-WorkTool.ps1')

# 모듈 불러오기 구역
$m = [regex]::Matches($entry, '(?ms)^#region 모듈 불러오기[^\n]*\n(.*?)^#endregion[^\n]*$')
if ($m.Count -ne 1) { throw "Start-WorkTool.ps1에서 「#region 모듈 불러오기 ~ #endregion」 구역을 정확히 한 번 찾지 못했습니다." }
$region = $m[0]

$coreLine = [regex]::Match($region.Groups[1].Value, "(?m)^\`$coreModules = (.+)$")
if (-not $coreLine.Success) { throw '구역 안에서 $coreModules 줄을 찾지 못했습니다.' }
$core = @($coreLine.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ })

$blocks = [System.Collections.Generic.List[string]]::new()
foreach ($name in $core) {
    $blocks.Add((Get-ModuleBlock "WorkTool.$name" (Join-Path $src 'core' "$name.psm1") "core\$name.psm1"))
}
$addonFiles = @(Get-ChildItem (Join-Path $src 'addons') -Filter '*.psm1' -Recurse | Sort-Object FullName)
foreach ($file in $addonFiles) {
    $rel = [System.IO.Path]::GetRelativePath($src, $file.FullName).Replace('/', '\')
    # 탭 폴더에 모듈이 여럿이면(메모: Memo · MemoEditor · MemoText) 이름이 겹치지 않게 파일 이름을 붙인다.
    # 같은 이름으로 Import-Module -Force를 하면 앞 모듈이 빠질 수 있다
    $siblings = @($addonFiles | Where-Object { $_.DirectoryName -eq $file.DirectoryName }).Count
    $name = if ($siblings -gt 1) { "WorkTool.addon.$($file.Directory.Name).$($file.BaseName)" } else { "WorkTool.addon.$($file.Directory.Name)" }
    $blocks.Add((Get-ModuleBlock $name $file.FullName $rel))
}
$bundled = "#region 모듈 (묶음 파일: build\Build-Bundle.ps1이 넣음)`n" + ($blocks -join "`n`n") + "`n#endregion"
$text = $entry.Substring(0, $region.Index) + $bundled + $entry.Substring($region.Index + $region.Length)

# 도움말 블록 바로 아래에 안내를 넣는다 (도움말보다 위에 두면 Get-Help가 도움말을 못 읽는다)
$note = @(
    '# WorkTool 새 버전(WPF) — 파일 하나로 묶은 버전 (자동 생성)'
    '# 이 파일은 직접 고치지 않는다. apps/WorkTool/wpf의 원본을 고친 뒤 wpf/build/Build-Bundle.ps1로 다시 만든다.'
) -join "`n"
$end = $text.IndexOf("`n#>")
if ($end -lt 0) { throw '도움말 블록 끝(#>)을 찾지 못했습니다.' }
$end += 3
$text = $text.Substring(0, $end) + "`n" + $note + $text.Substring($end)

New-Item -ItemType Directory -Path (Split-Path $outPath) -Force | Out-Null
[System.IO.File]::WriteAllText($outPath, $text + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Host "만듦: $outPath (core $($core.Count)개 · addons $($blocks.Count - $core.Count)개)"

# 저장소 맨 위 worktool.zip: 묶음 파일 + 더블클릭 실행 파일. 날짜를 고정해서 원본이 같으면 zip도 같다
$launcher = (Get-SourceText (Join-Path $PSScriptRoot 'start-worktool.cmd')).Replace("`n", "`r`n") + "`r`n"
$launchScript = Get-SourceText (Join-Path $PSScriptRoot 'start-launcher.ps1')
$repoRoot = Split-Path (Split-Path (Split-Path $src -Parent) -Parent) -Parent
$zipPath = Join-Path $repoRoot 'worktool.zip'
$stamp = [DateTimeOffset]::new(2026, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$fs = [System.IO.File]::Create($zipPath)
try {
    $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    $items = [System.Collections.Generic.List[object]]::new()
    $items.Add(@('WorkTool-WPF.ps1', [System.IO.File]::ReadAllBytes($outPath)))
    $items.Add(@('Start-WorkTool.cmd', [System.Text.UTF8Encoding]::new($false).GetBytes($launcher)))
    $items.Add(@('Start-WorkTool-Launcher.ps1', [System.Text.UTF8Encoding]::new($false).GetBytes($launchScript + "`n")))
    # 예제 스크립트: 저장소 맨 위 scripts/의 .ps1을 같은 폴더 구조로 넣는다. 풀고 켜면 업무 탭의 「예제 스크립트」에 보인다.
    # 순서는 경로 순(대소문자 구분 없이 고정), 줄 끝은 CRLF로 맞춰 PC마다 git 줄 끝 설정이 달라도 zip이 같게 한다
    $scriptRoot = Join-Path $repoRoot 'scripts'
    if (Test-Path -LiteralPath $scriptRoot -PathType Container) {
        $scriptFiles = @(Get-ChildItem -LiteralPath $scriptRoot -Filter '*.ps1' -File -Recurse | Where-Object Extension -eq '.ps1' |
                ForEach-Object { [pscustomobject]@{ File = $_; Rel = [System.IO.Path]::GetRelativePath($scriptRoot, $_.FullName).Replace('\', '/') } } |
                Sort-Object { $_.Rel.ToLowerInvariant() } -Culture ([System.Globalization.CultureInfo]::InvariantCulture))
        foreach ($s in $scriptFiles) {
            $body = (Get-SourceText $s.File.FullName).Replace("`n", "`r`n") + "`r`n"
            $items.Add(@("scripts/$($s.Rel)", [System.Text.UTF8Encoding]::new($false).GetBytes($body)))
        }
    }
    foreach ($item in $items) {
        $entry = $zip.CreateEntry($item[0], [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $stamp
        $es = $entry.Open()
        $es.Write($item[1], 0, $item[1].Length)
        $es.Dispose()
    }
    $zip.Dispose()
} finally { $fs.Dispose() }
Write-Host "만듦: $zipPath"

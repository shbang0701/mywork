<#
.SYNOPSIS
    검사 파일들이 같이 쓰는 준비 함수. 검사 파일 맨 위에서 점 소싱한다.

.DESCRIPTION
    - Import-WtTestCore: core 모듈을 앱과 같은 순서로 불러온다. 순서는 Start-WorkTool.ps1의 $coreModules 한 곳에서 읽는다.
    - New-WtTestData · Remove-WtTestData: 임시 앱 폴더와 데이터 폴더를 만들고 지운다. 실제 데이터 폴더(문서\WorkTool)는 쓰지 않는다.
    - Write-WtTestLegacyCsv: 예전 WorkTool(WinForms) CSV를 임시 앱 폴더 옆 data에 쓴다.
    - Assert-WtTest: 맞으면 PASS를 찍고, 틀리면 그 자리에서 멈춘다.
    - New-WtTestGate · Remove-WtTestGate · $wtTestHang: 응답 없는 공유 폴더를 흉내 낸다 (돌아오지 않는 화면 밖 작업).
    - Test-WtTestWpf · New-WtTestView · Get-WtTestTexts: WPF 화면 검사(Windows · STA에서만)를 준비하고, 탭 화면을 창 없이 만들고, 화면에 실린 글을 모은다.

.EXAMPLE
    . (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
    탭 폴더(addons\<이름>\)의 검사 파일에서 불러온다.
#>

$wtTestWpfRoot = Split-Path $PSScriptRoot -Parent

function Import-WtTestCore {
    $entry = [System.IO.File]::ReadAllText((Join-Path $wtTestWpfRoot 'Start-WorkTool.ps1'))
    $line = [regex]::Match($entry, '(?m)^\$coreModules = (.+)$')
    if (-not $line.Success) { throw 'Start-WorkTool.ps1에서 $coreModules 줄을 찾지 못했습니다.' }
    foreach ($name in @($line.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ })) {
        Import-Module (Join-Path $wtTestWpfRoot "core/$name.psm1") -Force -DisableNameChecking -Global
    }
}

# 임시 폴더: <Root>\app(앱 폴더, datapath.txt) · <Root>\data(데이터) · <Root>\app\data(예전 WorkTool 데이터 자리)
function New-WtTestData([ValidatePattern('^[a-z0-9-]+$')][string]$Name) {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("wt-$Name-" + [guid]::NewGuid().ToString('N'))
    $test = [pscustomobject]@{
        Root = $root; App = (Join-Path $root 'app'); Data = (Join-Path $root 'data'); Legacy = (Join-Path $root 'app' 'data')
    }
    [void][System.IO.Directory]::CreateDirectory($test.App)
    Set-Content -LiteralPath (Join-Path $test.App 'datapath.txt') -Value $test.Data -Encoding utf8
    Set-WtAppRoot $test.App
    Initialize-WtSettings
    $test
}

# 예전 CSV는 Excel에서 저장한 것처럼 BOM 붙은 UTF-8로 쓴다
function Write-WtTestLegacyCsv($Test, [string]$Name, [string]$Text) {
    [void][System.IO.Directory]::CreateDirectory($Test.Legacy)
    [System.IO.File]::WriteAllText((Join-Path $Test.Legacy "$Name.csv"), $Text, [System.Text.UTF8Encoding]::new($true))
}

# New-WtTestData가 만든 임시 폴더만 지운다. 지우지 못해도 검사 결과는 바꾸지 않고 알리기만 한다
function Remove-WtTestData($Test) {
    if (-not $Test) { return }
    $safe = [System.IO.Path]::GetFullPath($Test.Root)
    if ((Split-Path $safe -Leaf) -notmatch '^wt-[a-z0-9-]+-[a-f0-9]{32}$' -or
        -not $safe.StartsWith([System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw '임시 경로 검증 실패'
    }
    try { if (Test-Path -LiteralPath $safe) { Remove-Item -LiteralPath $safe -Recurse -Force } }
    catch { Write-Warning "검사 임시 폴더를 지우지 못했습니다: $safe" }
}

# 화면 요소 아래의 글(TextBlock)을 모두 모은다. 화면에 무엇이 실렸는지 볼 때 쓴다
function Get-WtTestTexts($Element) {
    if ($Element -is [System.Windows.Controls.TextBlock]) { $Element.Text }
    foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Element)) {
        if ($child -is [System.Windows.DependencyObject]) { Get-WtTestTexts $child }
    }
}

<#
응답 없는 공유 폴더 흉내 (외부 프로그램 · 관리자 권한 · 실제 서버 없이). 화면 밖 작업이 이 문을 기다리면 열어 줄 때까지 돌아오지 않는다.
PowerShell 중지(Stop)에도 반응하지 않는 .NET 대기라서, OS 요청에서 돌아오지 않는 작업과 같다.
작업 코드(다른 실행 공간)는 같은 프로세스의 [AppDomain]::CurrentDomain.GetData('WtTestGate')로 같은 문을 찾는다: $wtTestHang 참고
#>
function New-WtTestGate {
    $g = @{ Gate = [System.Threading.ManualResetEvent]::new($false); Entered = [System.Threading.ManualResetEvent]::new($false) }
    [AppDomain]::CurrentDomain.SetData('WtTestGate', $g)
    $g
}

# 문을 열어 기다리던 작업을 돌려보내고, 그 작업들이 끝나 치워지기를 잠깐 기다린다 (검사 프로세스가 끝날 때 붙잡히지 않게)
function Remove-WtTestGate($Gate) {
    if (-not $Gate) { return }
    [void]$Gate.Gate.Set()
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt 5000) {
        Update-WtWork
        $info = Get-WtWorkInfo
        if (-not $info.Running -and -not $info.Abandoned) { break }
        Start-Sleep -Milliseconds 20
    }
    [AppDomain]::CurrentDomain.SetData('WtTestGate', $null)
}

# 문 앞에서 멈추는 작업 코드 (들어왔다고 알린 뒤 문이 열릴 때까지 기다린다)
$wtTestHang = { $g = [AppDomain]::CurrentDomain.GetData('WtTestGate'); [void]$g.Entered.Set(); [void]$g.Gate.WaitOne() }

function Assert-WtTest([string]$Name, [bool]$Ok, $Detail = '') {
    if (-not $Ok) { throw ("FAIL $Name $Detail").TrimEnd() }
    Write-Host "PASS $Name"
}

# WPF 화면 검사는 Windows · STA에서만 한다. 할 수 있으면 WPF 어셈블리를 불러오고 $true
function Test-WtTestWpf {
    if (Get-Variable wtTestNoDesktop -Scope Global -ValueOnly -ErrorAction SilentlyContinue) { return $false }
    if (-not $IsWindows -or [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return $false }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
    $true
}

# 탭 화면을 창 없이 만들고, 앱 창에 들어갈 때와 같은 테마 · 스타일을 붙인다
function New-WtTestView([string]$Id) {
    $addon = Get-WtAddon -Id $Id
    if (-not $addon) { throw "탭 '$Id'가 등록되지 않았습니다." }
    $view = @(& $addon.NewView | Where-Object { $_ -is [System.Windows.UIElement] })[-1]
    $view.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
    $view.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $view
}

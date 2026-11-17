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
    - Test-WtTestInputPath: 숨김 호스트의 실제 배치 좌표에서 입력 대상과 논리/시각 부모 경로를 확인한다. OS 입력·누름/뗌·캡처·DPI 검사는 아니다.

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

# 저장 통로가 빌 때까지 기다린다. PC가 바쁘면 쓰기가 화면이 기다리는 시간을 넘길 수 있어, 파일을 바로 읽는 검사 앞에서 부른다
function Wait-WtTestWrites([int]$Milliseconds = 5000) {
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-WtDataWriting) -and $watch.ElapsedMilliseconds -lt $Milliseconds) { Update-WtWork; Start-Sleep -Milliseconds 10 }
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

# WPF 화면 검사는 Windows · STA에서만 한다. 앱과 같은 렌더링으로 준비하고 $true
function Test-WtTestWpf {
    if (Get-Variable wtTestNoDesktop -Scope Global -ValueOnly -ErrorAction SilentlyContinue) { return $false }
    if (-not $IsWindows -or [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return $false }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing
    # Start-WorkTool.ps1의 기본값과 맞춘다. 검사 프로세스에만 적용하며 사용자 설정은 바꾸지 않는다.
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
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

<#
.SYNOPSIS
    배치된 요소의 중심 좌표에서 목표까지 입력 경로가 이어지는지 확인한다.
.DESCRIPTION
    호출자가 WindowStyle=0인 숨김 호스트에 보기를 붙이고 배치한다. ContentElement는
    IContentHost의 실제 사각형을 보기 좌표로 옮기며, UIElement는 RenderSize를 쓴다.
    InputHitTest 결과의 논리/시각 부모를 모두 확인한다. ClickThrough는 선택적인
    편집기 판정 { param($Hit, $View) ... }이다. Ok·Reached·ClickThrough·Path·Bounds를 돌려준다.
    이 검사는 OS 입력, 누름/뗌, 마우스 캡처, 실제 화면, DPI/IME를 보증하지 않는다.
    BringIntoView는 숨김 보기 안에서 스크롤만 조정하며 창 표시나 입력을 만들지 않는다.
#>
function Test-WtTestInputPath {
    param([Parameter(Mandatory)]$View, [Parameter(Mandatory)]$Element,
        [Parameter(Mandatory)]$Target, [scriptblock]$ClickThrough, [switch]$BringIntoView)
    if ($BringIntoView -and $Element -is [Windows.FrameworkContentElement]) { $Element.BringIntoView() }
    elseif ($BringIntoView -and $Element -is [Windows.FrameworkElement]) { $Element.BringIntoView() }
    $View.UpdateLayout()
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $View.UpdateLayout()
    $rectangles = [Collections.Generic.List[Windows.Rect]]::new()
    if ($Element -is [Windows.UIElement]) {
        try { $rectangles.Add($Element.TransformToAncestor($View).TransformBounds([Windows.Rect]::new([Windows.Point]::new(0,0), $Element.RenderSize))) } catch { }
    } elseif ($Element -is [Windows.ContentElement]) {
        # Get-WtVisualChild는 첫 형식 일치만 돌려주므로, 여러 문서 페이지/조각을 여기서 모은다.
        $visuals = [Collections.Generic.Queue[Windows.Media.Visual]]::new(); $visuals.Enqueue($View)
        while ($visuals.Count) {
            $visual = $visuals.Dequeue()
            if ($visual -is [Windows.IContentHost]) {
                try {
                    $found = [Windows.IContentHost].GetMethod('GetRectangles').Invoke($visual, @($Element))
                    foreach ($rect in $found) { if (-not $rect.IsEmpty) { $rectangles.Add($visual.TransformToAncestor($View).TransformBounds($rect)) } }
                } catch { }
            }
            for ($i = 0; $i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($visual); $i++) {
                $child = [Windows.Media.VisualTreeHelper]::GetChild($visual, $i)
                if ($child -is [Windows.Media.Visual]) { $visuals.Enqueue($child) }
            }
        }
    }
    $bounds = [Windows.Rect]::Empty
    foreach ($rect in $rectangles) { $bounds.Union($rect) }
    $point = $null; $hit = $null; $reached = $false; $path = '배치 전이거나 실제 사각형이 없음'
    $walk = [Collections.Generic.Queue[object]]::new(); $seen = [Collections.Generic.HashSet[Windows.DependencyObject]]::new()
    $visited = [Collections.Generic.List[string]]::new()
    $rect = @($rectangles | Where-Object { $_.Width -gt 0 -and $_.Height -gt 0 }) | Select-Object -First 1
    if ($rect) {
        $point = [Windows.Point]::new($rect.X + $rect.Width / 2, $rect.Y + $rect.Height / 2)
        $hit = $View.InputHitTest($point)
        if ($hit) { $walk.Enqueue(@{ Node = $hit; Path = $hit.GetType().Name }) }
        while ($walk.Count) {
            $item = $walk.Dequeue(); $node = $item.Node
            if (-not $seen.Add($node)) { continue }
            $visited.Add($item.Path)
            if ([object]::ReferenceEquals($node, $Target)) { $reached = $true; $path = $item.Path; break }
            if ([object]::ReferenceEquals($node, $View)) { continue }
            $parents = @([Windows.LogicalTreeHelper]::GetParent($node))
            if ($node -is [Windows.Media.Visual] -or $node -is [Windows.Media.Media3D.Visual3D]) { $parents += [Windows.Media.VisualTreeHelper]::GetParent($node) }
            foreach ($parent in $parents) { if ($parent) { $walk.Enqueue(@{ Node = $parent; Path = "$($item.Path) > $($parent.GetType().Name)" }) } }
        }
        if (-not $reached) { $path = "목표 $($Target.GetType().Name) 없음: $($visited -join ' | ')" }
    }
    $through = $null
    if ($ClickThrough -and $hit) { $through = [bool](& $ClickThrough $hit $View) }
    [pscustomobject]@{ Ok = $reached -and ($null -eq $through -or $through); Reached = $reached; ClickThrough = $through;
        Path = $path; Bounds = $bounds; Rectangles = $rectangles.ToArray(); Point = $point; Hit = $hit }
}

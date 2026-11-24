<#
.SYNOPSIS
    WorkTool 새 버전(WPF) 1단계 미리보기를 띄운다.

.DESCRIPTION
    - 창 틀 · 왼쪽 메뉴(애드온) · 테마(파스텔 7색 · 투명도 · 글자 크기) · 설정 · 도움말이 들어 있다.
    - 처음 실행하면 예전 WorkTool(WinForms)의 data 폴더를 찾아 메모 · 일정 · 근태를 읽어 와서 보여 준다.
      예전 데이터는 바꾸지 않는다. 새 버전 데이터는 문서\WorkTool 에 저장된다.
    - 일정 알람은 앱이 떠 있는 동안(트레이로 숨었을 때도) 화면 오른쪽 아래 작은 창과 소리로 알린다.

    - 같은 데이터 폴더를 쓰는 앱은 하나만 뜬다. 이미 떠 있으면 새로 켠 쪽은 그 앱에 알리고(창을 앞으로 · 빠른 메모) 바로 끝난다.

.PARAMETER QuickMemo
    빠른 메모 창을 연다. 앱이 떠 있으면 그 앱이 열고, 없으면 앱을 켠 뒤 연다. 바탕 화면 바로 가기의 「바로 가기 키」용이다.

.EXAMPLE
    .\Start-WorkTool.ps1
    새 버전을 띄운다. 창의 X를 누르면 끝난다 (설정에서 트레이로 숨기기를 고를 수 있다). 이미 떠 있으면 그 창을 앞으로 가져온다.

.EXAMPLE
    .\Start-WorkTool.ps1 -QuickMemo
    빠른 메모 창을 연다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [switch]$QuickMemo, # 빠른 메모 창을 연다 (이미 떠 있으면 그 앱이 연다)
    [Parameter(DontShow)][switch]$AppProcess # 실행 보조가 콘솔 없는 앱 프로세스에만 전달한다
)

$ErrorActionPreference = 'Stop'

#region 한 번만 뜨기
# 같은 데이터 폴더를 쓰는 WorkTool은 하나만 띄운다. 이미 떠 있으면 새로 켠 쪽은 그 앱에 신호(보이기 · 빠른 적기)만 보내고 끝난다.
# .NET 기본 이름 있는 객체만 쓴다: Mutex(앱이 살아 있음) · EventWaitHandle(신호 · 다 했음) · MemoryMappedFile(앱 프로세스 번호).
# 이름은 데이터 폴더 경로로 정한다(core\Storage.psm1 Get-WtDataRoot와 같은 규칙: 앱 폴더 datapath.txt 첫 줄, 없으면 문서\WorkTool).
# Get-WtInstanceName · Send-WtInstanceSignal은 build\start-launcher.ps1에도 똑같이 있다. 고치면 둘 다 고친다(tests\Test-Instance.ps1이 같은지 본다)
function Get-WtInstanceName([string]$AppRoot) {
    $line = $null
    try { $line = @([System.IO.File]::ReadAllText((Join-Path $AppRoot 'datapath.txt')) -split "\r?\n", 2)[0] } catch { }
    $path = if ($line -and $line.Trim()) { [Environment]::ExpandEnvironmentVariables($line.Trim()) } else { $null }
    if (-not $path) {
        $docs = [Environment]::GetFolderPath('MyDocuments', 'DoNotVerify')
        if (-not $docs) { $docs = $HOME }
        $path = Join-Path $docs 'WorkTool'
    }
    $full = [System.IO.Path]::GetFullPath($path, $AppRoot).TrimEnd('\', '/').ToUpperInvariant()
    'Local\WorkTool.' + [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($full))).Substring(0, 32)
}

# 떠 있는 앱에 신호를 보낸다. 신호를 받는 앱이 없으면(안 떴거나 끝나는 중) $false.
# 앱이 창을 보인 뒤 「다 했음」을 받으면 그 창을 앞으로 가져온다. 단축키로 켠 이 프로세스에는 Windows가 그 권한을 주지만,
# 트레이에 있던 앱 프로세스에는 없다. 못 가져오면 앱 창은 잠깐 맨 위에 떠 있고 Windows가 작업 표시줄 단추를 깜빡인다
function Send-WtInstanceSignal([string]$Name, [switch]$QuickCapture) {
    $signal = $null
    $kind = if ($QuickCapture) { 'Capture' } else { 'Show' }
    if (-not [System.Threading.EventWaitHandle]::TryOpenExisting("$Name.$kind", [ref]$signal)) { return $false }
    $ready = $null
    try {
        $appId = 0
        try {
            $info = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting("$Name.Info", [System.IO.MemoryMappedFiles.MemoryMappedFileRights]::Read)
            try {
                $view = $info.CreateViewAccessor(0, 4, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
                try { $appId = $view.ReadInt32(0) } finally { $view.Dispose() }
            } finally { $info.Dispose() }
        } catch { $appId = 0 }
        if ([System.Threading.EventWaitHandle]::TryOpenExisting("$Name.Ready", [ref]$ready)) { [void]$ready.Reset() }
        [void]$signal.Set()
        if ($ready -and $appId -gt 0 -and $ready.WaitOne(3000)) {
            try {
                Add-Type -AssemblyName Microsoft.VisualBasic
                [Microsoft.VisualBasic.Interaction]::AppActivate($appId)
            } catch { }
        }
    } finally {
        $signal.Dispose()
        if ($ready) { $ready.Dispose() }
    }
    $true
}

# 앱 프로세스: 이 데이터 폴더의 앱이 되면 신호 손잡이를 돌려준다. 이미 떠 있는 앱이 신호를 받으면 알리고 $null(이 프로세스는 끝난다).
# 떠 있는 앱이 끝나는 중이면(신호를 닫음) 끝날 때까지 기다렸다가 이어서 뜬다. 오래 안 끝나면 신호 없이 이어 가고,
# 그 앱이 데이터 폴더를 아직 잡고 있으면 시작 오류(중복 실행)로 알린다(core\Storage.psm1 Open-WtDataLock)
function Enter-WtInstance([string]$Name, [switch]$QuickCapture, [int]$WaitMs = 15000) {
    $mutex = [System.Threading.Mutex]::new($false, $Name)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $owned = $false
        try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { break }
        if (Send-WtInstanceSignal $Name -QuickCapture:$QuickCapture) { $mutex.Dispose(); return $null }
        if ($watch.ElapsedMilliseconds -ge $WaitMs) { $mutex.Dispose(); return @{ Name = $Name } }
        Start-Sleep -Milliseconds 100
    }
    $info = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen("$Name.Info", 4)
    $view = $info.CreateViewAccessor(0, 4)
    try { $view.Write(0, [int]$PID) } finally { $view.Dispose() }
    $reset = [System.Threading.EventResetMode]::AutoReset
    @{
        Name = $Name; Mutex = $mutex; Info = $info
        Show = [System.Threading.EventWaitHandle]::new($false, $reset, "$Name.Show")
        Capture = [System.Threading.EventWaitHandle]::new($false, $reset, "$Name.Capture")
        Ready = [System.Threading.EventWaitHandle]::new($false, $reset, "$Name.Ready")
    }
}

# 앱이 끝날 때. 셸이 끝내기를 시작하면서 신호는 먼저 닫았고(core\Shell.psm1 Stop-WtInstanceSignals), 여기서 나머지를 놓는다
function Close-WtInstance($Instance) {
    if (-not $Instance) { return }
    foreach ($key in 'Show', 'Capture', 'Ready', 'Info') { if ($Instance[$key]) { try { $Instance[$key].Dispose() } catch { } } }
    if ($Instance.Mutex) {
        try { $Instance.Mutex.ReleaseMutex() } catch { }
        $Instance.Mutex.Dispose()
    }
}
#endregion

# 단일 파일로 실행해도 개인 PC 실행 보조와 같이 GUI만 남긴다.
# 사용자가 열어 둔 터미널은 건드리지 않고 즉시 돌려주며, -File 전용 실행 프로세스는 여기서 끝난다.
# 같은 데이터 폴더의 앱이 이미 떠 있으면 앱 프로세스를 새로 띄우지 않고 그 앱에 알린다(바로 가기 키로 누를 때 빠르게)
if (-not $AppProcess) {
    if (Send-WtInstanceSignal (Get-WtInstanceName $PSScriptRoot) -QuickCapture:$QuickMemo) { return }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.Environment['DOTNET_TieredCompilation'] = '0'
    foreach ($launchArg in @('-NoLogo', '-NoProfile', '-STA', '-File', $PSCommandPath, '-AppProcess')) {
        $startInfo.ArgumentList.Add($launchArg)
    }
    foreach ($boundName in $PSBoundParameters.Keys) {
        if ($boundName -eq 'AppProcess') { continue }
        $boundValue = $PSBoundParameters[$boundName]
        if ($boundValue -is [System.Management.Automation.SwitchParameter]) {
            $startInfo.ArgumentList.Add("-${boundName}:$([bool]$boundValue)")
        } else {
            $startInfo.ArgumentList.Add("-$boundName")
            $startInfo.ArgumentList.Add([string]$boundValue)
        }
    }
    foreach ($launchArg in $args) { $startInfo.ArgumentList.Add([string]$launchArg) }
    $appChild = [System.Diagnostics.Process]::Start($startInfo)
    $appChild.Dispose()
    return
}

# WPF 창은 STA 스레드에서만 띄울 수 있다
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'WorkTool은 STA 모드에서 실행해야 합니다. 다음처럼 실행하세요:' -ForegroundColor Yellow
    Write-Host "  pwsh -STA -File `"$PSCommandPath`""
    return
}

# 같은 데이터 폴더의 앱이 이미 떠 있으면 그 앱에 알리고 이 프로세스는 창 없이 끝난다(개인 PC 실행 보조 · 동시에 두 번 켬).
# 모듈을 불러오기 전이라 빠르고, 두 앱이 같은 데이터를 같이 만지지 않는다
$instance = Enter-WtInstance (Get-WtInstanceName $PSScriptRoot) -QuickCapture:$QuickMemo
if (-not $instance) { return }
# 이 프로세스가 앱이 됐다: -QuickMemo면 다 뜬 뒤 빠른 적기 창을 연다(셸이 다른 실행 보조의 신호와 같은 길로 받는다)
if ($QuickMemo -and $instance.Capture) { [void]$instance.Capture.Set() }

$previousRenderMode = $null
$renderModeChanged = $false
try {
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# 화면은 기본으로 소프트웨어 렌더링으로 그린다. GPU 렌더링에서는 창이 앞에 있거나 탭 위에 마우스만 올려도
# PC 전체가 버벅이는 PC가 있었고, 이 앱은 화면이 단순해서 소프트웨어로 그려도 속도 차이가 거의 없다.
# 진단할 때만 WORKTOOL_HARDWARE_RENDER=1로 GPU 렌더링을 쓴다. 이 프로세스에만 적용되고 사용자 설정 · 레지스트리는 바꾸지 않는다.
# 반드시 첫 창을 만들기 전에 적용한다.
if ($env:WORKTOOL_HARDWARE_RENDER -ne '1') {
    $previousRenderMode = [System.Windows.Media.RenderOptions]::ProcessRenderMode
    [System.Windows.Media.RenderOptions]::ProcessRenderMode = [System.Windows.Interop.RenderMode]::SoftwareOnly
    $renderModeChanged = $true
}

#region 모듈 불러오기 (묶음 파일에서는 이 구역이 모듈 소스로 바뀐다)
$coreModules = 'Work', 'Records', 'Storage', 'Settings', 'Calendar', 'Theme', 'Ui', 'Notice', 'Highlight', 'Markdown', 'Mermaid', 'Addons', 'Shortcuts', 'Pages', 'Shell'
foreach ($name in $coreModules) {
    Import-Module (Join-Path $PSScriptRoot "core\$name.psm1") -Force -DisableNameChecking
}
foreach ($file in (Get-ChildItem (Join-Path $PSScriptRoot 'addons') -Filter '*.psm1' -Recurse | Sort-Object FullName)) {
    Import-Module $file.FullName -Force -DisableNameChecking
}
#endregion

    Start-WtApp -AppRoot $PSScriptRoot -ScriptPath $PSCommandPath -Instance $instance
} catch {
    $msg = "$($_.Exception.Message)`n`n위치: $($_.InvocationInfo.PositionMessage)"
    Write-Host $msg -ForegroundColor Red
    try { [void][System.Windows.MessageBox]::Show($msg, 'WorkTool 시작 오류', 'OK', 'Error') } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'WorkTool 시작 오류', 'OK', 'Error')
        } catch { }
    }
} finally {
    if ($renderModeChanged) {
        [System.Windows.Media.RenderOptions]::ProcessRenderMode = $previousRenderMode
    }
    Close-WtInstance $instance
}

# 이 앱만을 위해 띄운 프로세스(-File로 이 파일을 실행)면 여기서 프로세스를 끝낸다. 응답 없는 공유 폴더를 기다리다
# 버린 작업이 남아도 창을 닫으면 프로세스가 끝나게 하려는 것이다 (core\Work.psm1의 Exit-WtOwnProcess). 정리는 위에서 모두 끝났다
if (Get-Command Exit-WtOwnProcess -ErrorAction SilentlyContinue) { Exit-WtOwnProcess -ScriptPath $PSCommandPath }

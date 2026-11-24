<#
.SYNOPSIS
    개인 PC용 WorkTool을 콘솔 창 없는 별도 PowerShell 프로세스로 시작한다.
.DESCRIPTION
    zip의 Start-WorkTool.cmd와 저장소의 wpf\start-dev.cmd가 호출한다. 실행 정책을 바꾸지 않고, 시작 검사에 실패하면 호출한 창에 오류를 표시한다.
    같은 데이터 폴더의 WorkTool이 이미 떠 있으면 새로 띄우지 않고 그 앱에 알린다(창을 앞으로 · -QuickMemo면 빠른 메모).
    작은 파일이라 바탕 화면 바로 가기의 「바로 가기 키」로 부를 때 묶음 파일을 부르는 것보다 빨리 알린다.
.PARAMETER ScriptPath
    띄울 스크립트. 비우면 이 파일 옆의 WorkTool-WPF.ps1(zip 구성)을 띄운다.
.PARAMETER QuickMemo
    빠른 메모 창을 연다. 앱이 떠 있으면 그 앱이 열고, 없으면 앱 창은 트레이에 숨긴 채 켜고 빠른 메모 창만 띄운다.
.EXAMPLE
    .\Start-WorkTool-Launcher.ps1
.EXAMPLE
    .\Start-WorkTool-Launcher.ps1 -QuickMemo
    빠른 메모 창을 연다. 도움말 → 정보 → 바로 가기 키의 대상이 이렇게 부른다.
.EXAMPLE
    .\build\start-launcher.ps1 -ScriptPath .\Start-WorkTool.ps1
    저장소 원본을 띄운다. start-dev.cmd가 이렇게 부른다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [switch]$QuickMemo # 빠른 메모 창을 연다
)

# ===== 설정 =====
$Config = @{ ScriptName = 'WorkTool-WPF.ps1' }
# ================
$ErrorActionPreference = 'Stop'

function New-WtLaunchStartInfo([string]$ScriptPath, [switch]$QuickMemo) {
    if (-not $IsWindows) { throw 'Windows에서 실행하세요.' }
    # 새 프로세스는 스크립트 폴더에서 시작하므로, 상대 경로는 지금 위치 기준 전체 경로로 바꿔 넘긴다
    $ScriptPath = [System.IO.Path]::GetFullPath($ScriptPath, (Get-Location).ProviderPath)
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) { throw "실행 파일을 찾지 못했습니다: $ScriptPath" }
    if (Get-Item -LiteralPath $ScriptPath -Stream Zone.Identifier -ErrorAction SilentlyContinue) {
        throw '받은 worktool.zip의 속성에서 차단 해제에 체크한 뒤 다시 압축을 푸세요.'
    }
    $tokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "스크립트 문법 오류: $($parseErrors[0].Message)" }
    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'pwsh.exe'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = [System.IO.Path]::GetDirectoryName($ScriptPath)
    $info.Environment['DOTNET_TieredCompilation'] = '0'
    foreach ($arg in @('-NoLogo', '-NoProfile', '-STA', '-File', $ScriptPath, '-AppProcess')) { $info.ArgumentList.Add($arg) }
    if ($QuickMemo) { $info.ArgumentList.Add('-QuickMemo') }
    $info
}

#region 한 번만 뜨기 (Start-WorkTool.ps1의 같은 구역에서 옮긴 것. 고치면 둘 다 똑같이 고친다: tests\Test-Instance.ps1이 같은지 본다)
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
#endregion

# 점검 스크립트에서 함수를 불러올 때는 실행하지 않는다.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot $Config.ScriptName }
        # 이미 떠 있으면 묶음 파일을 읽지 않고 신호만 보낸다(바로 가기 키가 빨리 듣게)
        $appRoot = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ScriptPath, (Get-Location).ProviderPath))
        if (Send-WtInstanceSignal (Get-WtInstanceName $appRoot) -QuickCapture:$QuickMemo) { exit 0 }
        $startInfo = New-WtLaunchStartInfo $ScriptPath -QuickMemo:$QuickMemo
        $child = [System.Diagnostics.Process]::Start($startInfo)
        $child.Dispose()
    } catch {
        Write-Host "WorkTool을 시작하지 못했습니다. $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

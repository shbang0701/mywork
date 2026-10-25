<#
.SYNOPSIS
    개인 PC용 WorkTool을 콘솔 창 없는 별도 PowerShell 프로세스로 시작한다.
.DESCRIPTION
    zip의 Start-WorkTool.cmd와 저장소의 wpf\start-dev.cmd가 호출한다. 실행 정책을 바꾸지 않고, 시작 검사에 실패하면 호출한 창에 오류를 표시한다.
.PARAMETER ScriptPath
    띄울 스크립트. 비우면 이 파일 옆의 WorkTool-WPF.ps1(zip 구성)을 띄운다.
.EXAMPLE
    .\Start-WorkTool-Launcher.ps1
.EXAMPLE
    .\build\start-launcher.ps1 -ScriptPath .\Start-WorkTool.ps1
    저장소 원본을 띄운다. start-dev.cmd가 이렇게 부른다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ScriptPath
)

# ===== 설정 =====
$Config = @{ ScriptName = 'WorkTool-WPF.ps1' }
# ================
$ErrorActionPreference = 'Stop'

function New-WtLaunchStartInfo([string]$ScriptPath) {
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
    foreach ($arg in @('-NoLogo', '-NoProfile', '-STA', '-File', $ScriptPath)) { $info.ArgumentList.Add($arg) }
    $info
}

# 점검 스크립트에서 함수를 불러올 때는 실행하지 않는다.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (-not $ScriptPath) { $ScriptPath = Join-Path $PSScriptRoot $Config.ScriptName }
        $startInfo = New-WtLaunchStartInfo $ScriptPath
        $child = [System.Diagnostics.Process]::Start($startInfo)
        $child.Dispose()
    } catch {
        Write-Host "WorkTool을 시작하지 못했습니다. $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

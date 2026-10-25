<#
.SYNOPSIS
    WorkTool 새 버전(WPF) 1단계 미리보기를 띄운다.

.DESCRIPTION
    - 창 틀 · 왼쪽 메뉴(애드온) · 테마(파스텔 7색 · 투명도 · 글자 크기) · 설정 · 도움말이 들어 있다.
    - 처음 실행하면 예전 WorkTool(WinForms)의 data 폴더를 찾아 메모 · 일정 · 근태를 읽어 와서 보여 준다.
      예전 데이터는 바꾸지 않는다. 새 버전 데이터는 문서\WorkTool 에 저장된다.
    - 편집 · 알람은 2단계에서 옮긴다. 그때까지는 예전 WorkTool을 계속 쓴다.

.EXAMPLE
    .\Start-WorkTool.ps1
    새 버전을 띄운다. 창의 X를 누르면 끝난다 (설정에서 트레이로 숨기기를 고를 수 있다).
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# WPF 창은 STA 스레드에서만 띄울 수 있다
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'WorkTool은 STA 모드에서 실행해야 합니다. 다음처럼 실행하세요:' -ForegroundColor Yellow
    Write-Host "  pwsh -STA -File `"$PSCommandPath`""
    return
}

# 계층 컴파일의 백그라운드 처리가 화면 조작과 경합하므로 이 앱의 프로세스에서만 끈다.
if ($env:DOTNET_TieredCompilation -ne '0') {
    $previousTiered = [Environment]::GetEnvironmentVariable('DOTNET_TieredCompilation', 'Process')
    $env:DOTNET_TieredCompilation = '0'
    try {
        & (Join-Path $PSHOME 'pwsh.exe') -NoLogo -NoProfile -STA -File $PSCommandPath @PSBoundParameters @args
        $childExit = $LASTEXITCODE
    } finally {
        # 같은 콘솔에서 다음에 켤 때도 실제 런타임 설정과 환경 변수 표식이 어긋나지 않게 되돌린다.
        [Environment]::SetEnvironmentVariable('DOTNET_TieredCompilation', $previousTiered, 'Process')
    }
    exit $childExit
}

try {
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

#region 모듈 불러오기 (묶음 파일에서는 이 구역이 모듈 소스로 바뀐다)
$coreModules = 'Storage', 'Settings', 'Theme', 'Ui', 'Highlight', 'Markdown', 'Mermaid', 'Addons', 'Pages', 'Shell'
foreach ($name in $coreModules) {
    Import-Module (Join-Path $PSScriptRoot "core\$name.psm1") -Force -DisableNameChecking
}
foreach ($file in (Get-ChildItem (Join-Path $PSScriptRoot 'addons') -Filter '*.psm1' -Recurse | Sort-Object FullName)) {
    Import-Module $file.FullName -Force -DisableNameChecking
}
#endregion

    Start-WtApp -AppRoot $PSScriptRoot
} catch {
    $msg = "$($_.Exception.Message)`n`n위치: $($_.InvocationInfo.PositionMessage)"
    Write-Host $msg -ForegroundColor Red
    try { [void][System.Windows.MessageBox]::Show($msg, 'WorkTool 시작 오류', 'OK', 'Error') } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show($msg, 'WorkTool 시작 오류', 'OK', 'Error')
        } catch { }
    }
}

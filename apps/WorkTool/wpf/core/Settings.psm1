# 설정 담당. 기본값은 코드에 두고, 사용자가 바꾼 값만 데이터 폴더의 settings.json에 저장한다.
# 그래서 새 설정 항목이 생겨도 예전 settings.json이 그대로 동작하고, 기본값과 같아지면 파일에서 빠진다.

$ErrorActionPreference = 'Stop'

$script:defaults = @{
    'theme.accent'    = 'blue'   # 강조색: blue · pink · teal · purple · gray (옛 theme.color는 읽어도 쓰지 않음)
    'ui.opacity'      = 100      # 창 불투명도(%) 60~100
    'ui.fontScale'    = 'm'      # 글자 크기 s · m · l
    'nav.collapsed'   = $false   # 왼쪽 메뉴 접힘
    'window.closeToTray' = $false   # 창의 X를 누르면 끝내지 않고 트레이로 숨김
    'addons.disabled' = @()      # 메뉴에서 숨긴 애드온 ID
    'legacy.path'     = ''       # 예전 WorkTool data 폴더 (비우면 자동으로 찾음)
}
$script:values = $null
$script:handlers = [System.Collections.Generic.List[scriptblock]]::new()

function Get-WtSettingsPath { Join-Path (Get-WtDataRoot) 'settings.json' }

function Initialize-WtSettings {
    $script:values = @{}
    $doc = Read-WtJsonFile (Get-WtSettingsPath)
    if ($doc -and $doc.values) {
        foreach ($p in $doc.values.PSObject.Properties) { $script:values[$p.Name] = $p.Value }
    }
}

# 애드온이 자기 설정의 기본값을 등록한다
function Register-WtSettingDefault([string]$Key, $Value) { $script:defaults[$Key] = $Value }

function Get-WtSetting([string]$Key) {
    if ($null -eq $script:values) { Initialize-WtSettings }
    if ($script:values.ContainsKey($Key)) { return $script:values[$Key] }
    $script:defaults[$Key]
}

function Test-WtSameValue($A, $B) {
    (ConvertTo-Json -InputObject $A -Compress -Depth 5) -eq (ConvertTo-Json -InputObject $B -Compress -Depth 5)
}

# 값을 바꾸고 저장한 뒤, 등록된 처리기에 알린다
function Set-WtSetting([string]$Key, $Value) {
    if ($null -eq $script:values) { Initialize-WtSettings }
    $next = $script:values.Clone()
    if ($script:defaults.ContainsKey($Key) -and (Test-WtSameValue $script:defaults[$Key] $Value)) {
        [void]$next.Remove($Key)
    } else {
        $next[$Key] = $Value
    }
    $sorted = [ordered]@{}
    foreach ($k in ($next.Keys | Sort-Object)) { $sorted[$k] = $next[$k] }
    # 저장 통로가 이 내용을 맡는다. 쓰지 못해도 버리지 않고 가지고 있다가(다시 읽어도 나온다) 끝내기 전에 셸이 묻는다
    Write-WtJsonFile (Get-WtSettingsPath) ([ordered]@{ schema = 1; values = $sorted })
    $script:values = $next
    foreach ($h in @($script:handlers)) { & $h $Key $Value }
}

# 설정이 바뀔 때 부를 처리기. { param($key, $value) ... }
function Register-WtSettingHandler([scriptblock]$Handler) { $script:handlers.Add($Handler) }

Export-ModuleMember -Function Get-WtSettingsPath, Initialize-WtSettings, Register-WtSettingDefault, Get-WtSetting,
    Set-WtSetting, Register-WtSettingHandler

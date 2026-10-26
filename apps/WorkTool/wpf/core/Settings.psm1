# 설정 담당. 기본값은 코드에 두고, 사용자 설정은 데이터 폴더의 settings.json에 저장한다.
# 업무시간은 첫 설정 완료를 구분하도록 기본값도 저장한다. 나머지는 기본값과 같아지면 파일에서 빠진다.

$ErrorActionPreference = 'Stop'

$script:defaults = @{
    'theme.accent'    = 'blue'   # 강조색: blue · pink · teal · purple · gray (옛 theme.color는 읽어도 쓰지 않음)
    'ui.opacity'      = 100      # 창 불투명도(%) 60~100
    'ui.fontScale'    = 'm'      # 글자 크기 s · m · l
    'nav.collapsed'   = $false   # 왼쪽 메뉴 접힘
    'window.closeToTray' = $false   # 창의 X를 누르면 끝내지 않고 트레이로 숨김
    'addons.disabled' = @()      # 메뉴에서 숨긴 애드온 ID
    'legacy.path'     = ''       # 예전 WorkTool data 폴더 (비우면 자동으로 찾음)
    'work.days'       = @(1, 2, 3, 4, 5)
    'work.start'      = '09:00'
    'work.end'        = '18:00'
    'work.lunchStart' = '12:00'
    'work.lunchEnd'   = '13:00'
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

function Get-WtWorkHours([switch]$Defaults) {
    $hours = @{}
    foreach ($k in 'work.days', 'work.start', 'work.end', 'work.lunchStart', 'work.lunchEnd') {
        $hours[$k] = if ($Defaults) { $script:defaults[$k] } else { Get-WtSetting $k }
    }
    $hours['work.days'] = @($hours['work.days'])
    $hours
}

function Test-WtWorkSetupRequired {
    if ($null -eq $script:values) { Initialize-WtSettings }
    -not $script:values.ContainsKey('work.start')
}

# UI도 같은 검사를 사용한다. 오류는 해당 설정 키에 연결한다.
function Get-WtWorkHoursErrors([hashtable]$Hours) {
    $errors = [ordered]@{}
    $days = $Hours['work.days']
    if ($days -isnot [array] -or -not $days.Count -or @($days | Where-Object {
                ($_ -isnot [int] -and $_ -isnot [long]) -or $_ -lt 1 -or $_ -gt 7
            }).Count) { $errors['work.days'] = '일하는 요일을 하나 이상 선택하세요.' }
    foreach ($k in 'work.start', 'work.end', 'work.lunchStart', 'work.lunchEnd') {
        if ($Hours[$k] -isnot [string] -or $Hours[$k] -cnotmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') {
            $errors[$k] = '시각은 HH:mm 형식으로 입력하세요.'
        }
    }
    if (-not $errors.Contains('work.start') -and -not $errors.Contains('work.end') -and $Hours['work.start'] -ge $Hours['work.end']) {
        $errors['work.end'] = '끝 시각은 시작 시각보다 늦어야 합니다.'
    }
    if (-not $errors.Contains('work.lunchStart') -and -not $errors.Contains('work.lunchEnd') -and $Hours['work.lunchStart'] -ge $Hours['work.lunchEnd']) {
        $errors['work.lunchEnd'] = '점심 끝 시각은 점심 시작보다 늦어야 합니다.'
    }
    if (-not $errors.Contains('work.start') -and -not $errors.Contains('work.lunchStart') -and $Hours['work.lunchStart'] -lt $Hours['work.start']) {
        $errors['work.lunchStart'] = '점심 시작 시각은 업무시간 안이어야 합니다.'
    }
    if (-not $errors.Contains('work.end') -and -not $errors.Contains('work.lunchEnd') -and $Hours['work.lunchEnd'] -gt $Hours['work.end']) {
        $errors['work.lunchEnd'] = '점심 끝 시각은 업무시간 안이어야 합니다.'
    }
    $errors
}

# 다섯 값을 한 번에 검사하고 저장해, 업무시간을 옮길 때 중간 값이 저장되지 않게 한다.
function Set-WtWorkHours([hashtable]$Hours) {
    $errors = Get-WtWorkHoursErrors $Hours
    if ($errors.Count) { throw [System.ArgumentException]::new(($errors.Values -join ' ')) }
    if ($null -eq $script:values) { Initialize-WtSettings }
    $next = $script:values.Clone()
    $changes = @{}
    foreach ($k in 'work.days', 'work.start', 'work.end', 'work.lunchStart', 'work.lunchEnd') {
        $changes[$k] = $Hours[$k]
        $next[$k] = $Hours[$k]
    }
    Save-WtSettings $next $changes
}

# 값을 바꾸고 저장한 뒤, 등록된 처리기에 알린다
function Set-WtSetting([string]$Key, $Value) {
    if ($null -eq $script:values) { Initialize-WtSettings }
    if ($Key -in 'work.days', 'work.start', 'work.end', 'work.lunchStart', 'work.lunchEnd') {
        $hours = Get-WtWorkHours
        $hours[$Key] = $Value
        Set-WtWorkHours $hours
        return
    }
    $next = $script:values.Clone()
    if ($script:defaults.ContainsKey($Key) -and (Test-WtSameValue $script:defaults[$Key] $Value)) {
        [void]$next.Remove($Key)
    } else {
        $next[$Key] = $Value
    }
    Save-WtSettings $next @{ $Key = $Value }
}

function Save-WtSettings([hashtable]$Next, [hashtable]$Changes) {
    $sorted = [ordered]@{}
    foreach ($k in ($Next.Keys | Sort-Object)) { $sorted[$k] = $Next[$k] }
    # 저장 통로가 이 내용을 맡는다. 쓰지 못해도 버리지 않고 가지고 있다가(다시 읽어도 나온다) 끝내기 전에 셸이 묻는다
    Write-WtJsonFile (Get-WtSettingsPath) ([ordered]@{ schema = 1; values = $sorted })
    $script:values = $Next
    foreach ($k in $Changes.Keys) { foreach ($h in @($script:handlers)) { & $h $k $Changes[$k] } }
}

# 설정이 바뀔 때 부를 처리기. { param($key, $value) ... }
function Register-WtSettingHandler([scriptblock]$Handler) { $script:handlers.Add($Handler) }

Export-ModuleMember -Function Get-WtSettingsPath, Initialize-WtSettings, Register-WtSettingDefault, Get-WtSetting,
    Set-WtSetting, Register-WtSettingHandler, Get-WtWorkHours, Get-WtWorkHoursErrors, Set-WtWorkHours, Test-WtWorkSetupRequired

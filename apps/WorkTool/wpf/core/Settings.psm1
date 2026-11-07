# 설정 담당. 기본값은 코드에 두고, 사용자 설정은 데이터 폴더의 settings.json에 저장한다.
# 업무시간은 첫 설정 완료를 구분하도록 기본값도 저장한다. 나머지는 기본값과 같아지면 파일에서 빠진다.
# 업무시간은 기간별 규칙이다(설계 15.1): work.* 키 = 「처음부터」 규칙, work.periods = 적용 시작일(from)이 있는 뒤 규칙들.
# 날짜마다 계산하는 곳(근태 초과근무 · 달력 쉬는 날 · 루틴 근무 요일만)은 Get-WtWorkHours -Date로 그날 규칙을 받는다.

$ErrorActionPreference = 'Stop'

$script:defaults = @{
    'theme.color'     = 'sky'    # 파스텔: sky · pink · green · yellow · purple · gray · black
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
    'work.halfDay'    = ''       # 반차 나누는 시각 HH:mm. 비면 정규 시간(점심 뺌)의 절반 지점
    'work.periods'    = @()      # 뒤 규칙들 @{ from = 'yyyy-MM-dd'; days; start; end; lunchStart; lunchEnd; halfDay }
}
# 규칙 하나를 이루는 키. 기간 원소의 칸 이름은 앞의 'work.'을 뗀 것이다
$script:workKeys = @('work.days', 'work.start', 'work.end', 'work.lunchStart', 'work.lunchEnd', 'work.halfDay')
$script:values = $null
$script:periodCache = $null
$script:handlers = [System.Collections.Generic.List[scriptblock]]::new()
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture

function Get-WtSettingsPath { Join-Path (Get-WtDataRoot) 'settings.json' }

function Initialize-WtSettings {
    $script:values = @{}
    $script:periodCache = $null
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
    (ConvertTo-Json -InputObject $A -Compress -Depth 5) -ceq (ConvertTo-Json -InputObject $B -Compress -Depth 5)
}

# 기간 원소의 칸을 읽는다. 앱이 만든 해시 테이블과 settings.json에서 읽은 객체를 같게 다룬다
function Get-WtSettingsField($Object, [string]$Name) {
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}
function Test-WtSettingsObject($Value) { $null -ne $Value -and $Value -isnot [string] -and $Value -isnot [ValueType] -and $Value -isnot [array] }

# 규칙 하나 = work.* 키의 해시 테이블. 요일은 늘 배열, 반차 시각은 비면 ''. -Period면 기간 원소(칸 이름에 'work.' 없음)에서 읽는다
function ConvertTo-WtWorkRule($Source, [switch]$Period) {
    $hours = @{}
    foreach ($k in $script:workKeys) { $hours[$k] = if ($Period) { Get-WtSettingsField $Source $k.Substring(5) } else { $Source[$k] } }
    if ($null -eq $hours['work.halfDay']) { $hours['work.halfDay'] = '' }
    $hours['work.days'] = @($hours['work.days'])
    $hours
}

# 뒤 규칙 원소(저장 모양). 옛 원소의 모르는 칸(더 새 앱이 더한 것)은 남긴다
function ConvertTo-WtWorkPeriodItem($Old, [string]$From, [hashtable]$Rule) {
    $item = [ordered]@{}
    if (Test-WtSettingsObject $Old) {
        $names = if ($Old -is [System.Collections.IDictionary]) { @($Old.Keys) } else { @($Old.PSObject.Properties.Name) }
        foreach ($n in $names) { $item[$n] = Get-WtSettingsField $Old $n }
    }
    $item['from'] = $From
    foreach ($k in $script:workKeys) { $item[$k.Substring(5)] = $Rule[$k] }
    $item['days'] = @($Rule['work.days'])
    $item
}

<#
뒤 규칙들: 올바른 것만 적용 시작일 순으로 @{ From = 'yyyy-MM-dd'; Hours = 규칙 }.
날짜를 못 읽거나 규칙이 틀렸거나 앞 원소와 날짜가 겹치는 원소는 계산에서 뺀다(파일에서는 지우지 않는다).
#>
function Get-WtWorkPeriods {
    if ($null -eq $script:values) { Initialize-WtSettings }
    if ($null -ne $script:periodCache) { return $script:periodCache }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $list = @(foreach ($p in @(Get-WtSetting 'work.periods')) {
            if (-not (Test-WtSettingsObject $p)) { continue }
            $from = [string](Get-WtSettingsField $p 'from')
            $day = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($from, 'yyyy-MM-dd', $script:inv, [System.Globalization.DateTimeStyles]::None, [ref]$day) -or $day.Year -lt 1900 -or $day.Year -gt 2199) { continue }
            $hours = ConvertTo-WtWorkRule $p -Period
            if ((Get-WtWorkHoursErrors $hours).Count -or -not $seen.Add($from)) { continue }
            [pscustomobject]@{ From = $from; Hours = $hours }
        })
    $script:periodCache = @($list | Sort-Object { $_.From })
    $script:periodCache
}

<#
업무시간 규칙(work.* 키의 해시 테이블 + 'work.from' = 규칙의 적용 시작일, 처음부터는 '').
  -Defaults    코드 기본값(첫 설정 화면)
  -From ''     「처음부터」 규칙. -From 'yyyy-MM-dd'는 그날 시작하는 뒤 규칙(설정 화면이 고치는 대상), 없으면 $null
  -Date d      d(날짜 또는 yyyy-MM-dd)에 적용되는 규칙. 아무것도 주지 않으면 오늘. 적용 시작일이 d 이하인 마지막 뒤 규칙, 없으면 처음부터 규칙
#>
function Get-WtWorkHours([switch]$Defaults, [string]$From, $Date) {
    if ($Defaults) { $hours = ConvertTo-WtWorkRule $script:defaults; $hours['work.from'] = ''; return $hours }
    if ($From) {
        $period = @(Get-WtWorkPeriods) | Where-Object { $_.From -ceq $From } | Select-Object -First 1
        if (-not $period) { return $null }
        $hours = $period.Hours.Clone(); $hours['work.days'] = @($period.Hours['work.days']); $hours['work.from'] = $From
        return $hours
    }
    $base = @{}
    foreach ($k in $script:workKeys) { $base[$k] = Get-WtSetting $k }
    $hours = ConvertTo-WtWorkRule $base
    $hours['work.from'] = ''
    if ($PSBoundParameters.ContainsKey('From')) { return $hours }
    $dayText = if ($null -eq $Date) { [datetime]::Today.ToString('yyyy-MM-dd', $script:inv) } elseif ($Date -is [datetime]) { $Date.ToString('yyyy-MM-dd', $script:inv) } else { [string]$Date }
    foreach ($period in @(Get-WtWorkPeriods)) {
        if ([string]::CompareOrdinal($period.From, $dayText) -gt 0) { break }
        $hours = $period.Hours.Clone(); $hours['work.days'] = @($period.Hours['work.days']); $hours['work.from'] = $period.From
    }
    $hours
}

# 반차 나누는 시각 HH:mm. 규칙에 값이 있으면 그 값, 비면 정규 시간(점심 뺌)의 절반 지점(09:00~18:00 · 점심 12:00~13:00 → 14:00).
# 오전 반차 = 시작 ~ 이 시각, 오후 반차 = 이 시각 ~ 끝(설계 15.1)
function Get-WtHalfDaySplit([hashtable]$Hours) {
    if ($Hours['work.halfDay']) { return [string]$Hours['work.halfDay'] }
    $start = [timespan]::ParseExact([string]$Hours['work.start'], 'hh\:mm', $script:inv).TotalMinutes
    $end = [timespan]::ParseExact([string]$Hours['work.end'], 'hh\:mm', $script:inv).TotalMinutes
    $lunchStart = [timespan]::ParseExact([string]$Hours['work.lunchStart'], 'hh\:mm', $script:inv).TotalMinutes
    $lunchEnd = [timespan]::ParseExact([string]$Hours['work.lunchEnd'], 'hh\:mm', $script:inv).TotalMinutes
    $lunch = [math]::Max(0, [math]::Min($lunchEnd, $end) - [math]::Max($lunchStart, $start))
    $half = ($end - $start - $lunch) / 2
    $before = [math]::Max(0, $lunchStart - $start)
    $minutes = if ($lunch -gt 0 -and $half -gt $before) { $lunchEnd + $half - $before } else { $start + $half }
    [timespan]::FromMinutes([math]::Floor($minutes)).ToString('hh\:mm', $script:inv)
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
    # 반차 나누는 시각은 비울 수 있다(자동). 적으면 시작과 끝 사이
    $half = $Hours['work.halfDay']
    if ($null -ne $half -and '' -cne $half) {
        if ($half -isnot [string] -or $half -cnotmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') { $errors['work.halfDay'] = '시각은 HH:mm 형식으로 입력하세요.' }
        elseif (-not $errors.Contains('work.start') -and -not $errors.Contains('work.end') -and ($half -le $Hours['work.start'] -or $half -ge $Hours['work.end'])) {
            $errors['work.halfDay'] = '반차 나누는 시각은 시작 시각과 끝 시각 사이여야 합니다.'
        }
    }
    $errors
}

# 규칙 하나를 한 번에 검사하고 저장해, 업무시간을 옮길 때 중간 값이 저장되지 않게 한다.
# From = ''(처음부터) 또는 뒤 규칙의 적용 시작일. Hours에 없는 키(예: 첫 설정 화면의 반차 시각)는 그 규칙의 값을 그대로 둔다
function Set-WtWorkHours([hashtable]$Hours, [string]$From = '') {
    if ($null -eq $script:values) { Initialize-WtSettings }
    $current = Get-WtWorkHours -From $From
    if ($null -eq $current) { throw [System.ArgumentException]::new("없는 업무시간 기간입니다: $From") }
    $rule = @{}
    # if 식으로 넣으면 원소 하나인 요일 목록(@(7))이 숫자로 풀린다. 문장으로 넣어 받은 값 그대로 검사한다
    foreach ($k in $script:workKeys) {
        $rule[$k] = $current[$k]
        if ($Hours.ContainsKey($k)) { $rule[$k] = $Hours[$k] }
    }
    if ($null -eq $rule['work.halfDay']) { $rule['work.halfDay'] = '' }
    $errors = Get-WtWorkHoursErrors $rule
    if ($errors.Count) { throw [System.ArgumentException]::new(($errors.Values -join ' ')) }
    $next = $script:values.Clone()
    $changes = @{}
    if (-not $From) {
        foreach ($k in $script:workKeys) {
            $changes[$k] = $rule[$k]
            $next[$k] = $rule[$k]
        }
    } else {
        $list = @(foreach ($p in @(Get-WtSetting 'work.periods')) {
                if ((Test-WtSettingsObject $p) -and [string](Get-WtSettingsField $p 'from') -ceq $From) { ConvertTo-WtWorkPeriodItem $p $From $rule } else { $p }
            })
        $next['work.periods'] = $list; $changes['work.periods'] = $list
    }
    Save-WtSettings $next $changes
}

# 적용 시작일 From부터의 뒤 규칙을 더한다. 값은 그날 적용되던 규칙을 복사한다(설정 화면에서 고친다)
function Add-WtWorkPeriod([string]$From) {
    $day = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($From, 'yyyy-MM-dd', $script:inv, [System.Globalization.DateTimeStyles]::None, [ref]$day) -or $day.Year -lt 1900 -or $day.Year -gt 2199) {
        throw [System.ArgumentException]::new('적용 시작일은 yyyy-MM-dd 형식으로 입력하세요.')
    }
    if (@(Get-WtWorkPeriods | Where-Object { $_.From -ceq $From }).Count) { throw [System.ArgumentException]::new('같은 적용 시작일의 기간이 이미 있습니다.') }
    $rule = Get-WtWorkHours -Date $From
    $next = $script:values.Clone()
    $list = @(@(Get-WtSetting 'work.periods') | Where-Object { $null -ne $_ }) + @(ConvertTo-WtWorkPeriodItem $null $From $rule)
    $next['work.periods'] = $list
    Save-WtSettings $next @{ 'work.periods' = $list }
}

# 뒤 규칙을 지운다. 그 기간의 날은 앞 규칙을 따른다. 처음부터 규칙은 지우지 않는다
function Remove-WtWorkPeriod([string]$From) {
    if (-not $From) { throw [System.ArgumentException]::new('처음부터 규칙은 지울 수 없습니다.') }
    if ($null -eq $script:values) { Initialize-WtSettings }
    $raw = @(Get-WtSetting 'work.periods')
    $list = @($raw | Where-Object { -not ((Test-WtSettingsObject $_) -and [string](Get-WtSettingsField $_ 'from') -ceq $From) })
    if ($list.Count -eq $raw.Count) { throw [System.ArgumentException]::new("없는 업무시간 기간입니다: $From") }
    $next = $script:values.Clone()
    $next['work.periods'] = $list
    Save-WtSettings $next @{ 'work.periods' = $list }
}

# 값을 바꾸고 저장한 뒤, 등록된 처리기에 알린다
function Set-WtSetting([string]$Key, $Value) {
    if ($null -eq $script:values) { Initialize-WtSettings }
    if ($Key -in $script:workKeys) {
        $hours = Get-WtWorkHours -From ''
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
    $script:periodCache = $null
    $firstError = $null
    foreach ($k in $Changes.Keys) {
        foreach ($h in @($script:handlers)) {
            try { & $h $k $Changes[$k] }
            catch { if ($null -eq $firstError) { $firstError = $_ } }
        }
    }
    # 값은 이미 저장됐다. 한 기능의 오류가 다른 화면의 반영을 막지 않게 모두 알린 뒤 오류를 전달한다.
    if ($null -ne $firstError) { throw $firstError }
}

# 설정이 바뀔 때 부를 처리기. { param($key, $value) ... }
function Register-WtSettingHandler([scriptblock]$Handler) { $script:handlers.Add($Handler) }

Export-ModuleMember -Function Get-WtSettingsPath, Initialize-WtSettings, Register-WtSettingDefault, Get-WtSetting,
    Set-WtSetting, Register-WtSettingHandler, Get-WtWorkHours, Get-WtWorkHoursErrors, Set-WtWorkHours, Test-WtWorkSetupRequired,
    Get-WtWorkPeriods, Add-WtWorkPeriod, Remove-WtWorkPeriod, Get-WtHalfDaySplit

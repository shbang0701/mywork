# 애드온(탭) 목록. 탭 하나 = addons\<이름>\ 폴더 하나이고, 그 모듈이 불러와질 때 Register-WtAddon으로 자기를 등록한다.
# 셸 · 홈 · 도움말은 이 목록만 보고 메뉴 · 카드 · 설명을 만든다. 탭을 더하거나 빼도 코어 코드는 고치지 않는다.
# 탭의 검사는 같은 폴더의 Test-<이름>.ps1에 두면 tests\Test-Core.ps1이 찾아서 돌린다.

$ErrorActionPreference = 'Stop'

$script:addons = [System.Collections.Generic.List[hashtable]]::new()

<#
등록 항목
  Id           영문 소문자 ID (저장소 이름에도 씀)
  Title        메뉴에 보이는 이름
  Icon         Segoe 아이콘 글꼴 글자 코드 (예: 0xE70B)
  Order        메뉴 순서 (작을수록 위)
  Required     $true면 설정에서 끌 수 없음 (홈)
  NewView      { } → 화면 요소를 돌려준다. 처음 열 때 한 번 부른다.
  Refresh      { param($view) } → 화면을 열 때마다 부른다 (선택)
  HomeCard     { } → 홈에 놓을 카드 요소(여러 개 가능)를 돌려준다 (선택)
  ImportLegacy { param($folder) } → 예전 WorkTool data 폴더에서 이 탭 데이터를 가져와 저장한다. 가져온 개수를 돌려준다 (선택)
  OnExit       { } → 끝내기 직전(SavePending 확인 뒤) 타이머·조회 등 실행 자원을 정리한다 (선택)
  SavePending  { } → 이 화면을 떠날 때 · 끝낼 때 저장. 실패하면 $false를 돌려준다.
                     그러면 셸이 다시 시도 · 저장하지 않고 이동(끝내기) · 취소를 묻는다 (선택)
  Help         도움말 「이 버전」에 넣을 설명 문단들 (선택)
  Shortcuts    도움말 「단축키」에 넣을 @('키', '설명') 목록. 키 처리는 탭 화면이 직접 한다 (선택)
               하나만 줄 때는 앞에 쉼표를 붙인다: -Shortcuts (, @('F5', '새로 고침'))
  HelpCard     { } → 도움말에 따로 놓을 카드 요소를 돌려준다 (선택)
  WarmUp       켠 뒤 한가할 때 화면을 미리 만들어 둘지 (선택). 처음 누를 때도 빨리 뜨게 하려는 것이다
               'Full' → NewView · Refresh를 미리 부른다. 이 탭의 데이터 파일만 읽고 밖에 영향이 없을 때만 쓴다
               'View' → NewView만 미리 부른다. Refresh가 폴더 조회 · 다른 창 수집처럼 느리거나 밖에 닿을 때 쓴다
#>
function Register-WtAddon {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [int]$Icon = 0xE10C,
        [int]$Order = 100,
        [switch]$Required,
        [Parameter(Mandatory)][scriptblock]$NewView,
        [scriptblock]$Refresh,
        [scriptblock]$HomeCard,
        [scriptblock]$CalendarItems,
        [scriptblock]$ImportLegacy,
        [scriptblock]$OnExit,
        [scriptblock]$SavePending,
        [ValidateSet('', 'View', 'Full')][string]$WarmUp = '',
        [string]$Description = '',
        [string[]]$Help = @(),
        [object[]]$Shortcuts = @(),
        [scriptblock]$HelpCard
    )
    # 쉼표 없이 한 쌍만 주면 배열이 펴져서 들어온다 → 한 쌍으로 되돌린다
    if ($Shortcuts.Count -and $Shortcuts[0] -is [string]) { $Shortcuts = @(, $Shortcuts) }
    foreach ($s in $Shortcuts) {
        if (@($s).Count -ne 2) { throw "애드온 '$Id'의 단축키는 @('키', '설명') 모양이어야 합니다." }
    }
    for ($i = $script:addons.Count - 1; $i -ge 0; $i--) {
        if ($script:addons[$i].Id -eq $Id) { $script:addons.RemoveAt($i) }
    }
    $script:addons.Add(@{
            Id = $Id; Title = $Title; Icon = $Icon; Order = $Order; Required = [bool]$Required
            NewView = $NewView; Refresh = $Refresh; HomeCard = $HomeCard; CalendarItems = $CalendarItems; ImportLegacy = $ImportLegacy; OnExit = $OnExit
            Description = $Description
            SavePending = $SavePending; WarmUp = $WarmUp
            Help = @($Help); Shortcuts = @($Shortcuts); HelpCard = $HelpCard
        })
    # 같은 탭을 다시 등록하면서 표시 함수를 뺐으면 옛 등록도 없앤다.
    Register-WtCalendarSource -Id "addon:$Id" -Page $Id -CalendarItems $CalendarItems
}

# 순서대로 돌려준다. -All이 없으면 설정에서 끈 탭은 뺀다.
function Get-WtAddon {
    param([switch]$All, [string]$Id)
    $disabled = @(Get-WtSetting 'addons.disabled')
    $list = $script:addons | Sort-Object { $_.Order }, { $_.Id }
    if ($Id) { return $list | Where-Object { $_.Id -eq $Id } | Select-Object -First 1 }
    if ($All) { return $list }
    $list | Where-Object { $_.Required -or $disabled -notcontains $_.Id }
}

# From ~ To(그날 포함). 한 출처의 실패는 Errors에 남기고 나머지는 계속 모은다.
function Get-WtCalendarItems([datetime]$From, [datetime]$To, [string[]]$Exclude = @()) {
    $items = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $days = [System.Collections.Generic.List[object]]::new()
    if ($From.Date -gt $To.Date -or -not (ConvertFrom-WtDateText (ConvertTo-WtDateText $From)) -or -not (ConvertFrom-WtDateText (ConvertTo-WtDateText $To))) {
        return [pscustomobject]@{ Success = $false; Reason = '날짜 범위를 확인하세요'; Items = @(); Days = @(); Errors = @() }
    }
    $enabled = @(Get-WtAddon | ForEach-Object Id)
    foreach ($source in @(Get-WtCalendarSource)) {
        if ($source.Page -and ($source.Page -cnotin $enabled -or $source.Page -cin $Exclude)) { continue }
        if ($source.Id -cin $Exclude) { continue }
        try {
            $batch = @(& $source.CalendarItems $From.Date $To.Date)
            $accepted = [System.Collections.Generic.List[object]]::new()
            foreach ($entry in $batch) {
                if (-not (Test-WtRecordObject $entry) -or $entry.Date -isnot [datetime] -or -not $entry.Kind -or -not $entry.Style -or -not $entry.Id -or
                    $entry.AllDay -isnot [bool] -or (-not $entry.AllDay -and $null -eq (ConvertFrom-WtTimeText ([string]$entry.Time)))) {
                    throw '달력 표시 항목의 모양이 틀렸습니다.'
                }
                if ($entry.Date.Date -lt $From.Date -or $entry.Date.Date -gt $To.Date) { continue }
                $accepted.Add([pscustomobject]@{ Date = $entry.Date.Date; Kind = [string]$entry.Kind; Text = [string]$entry.Text; Style = [string]$entry.Style
                    AllDay = $entry.AllDay; Time = $entry.Time; Id = [string]$entry.Id; Page = $source.Page; Source = $source.Id })
            }
            $items.AddRange($accepted)
        } catch { $errors.Add([pscustomobject]@{ Source = $source.Id; Page = $source.Page; Reason = $_.Exception.Message }) }
    }
    $sorted = @($items | Sort-Object Date, @{ Expression = { -not $_.AllDay } }, Time, Source, Id -Culture 'ko-KR')
    $byDate = @{}
    foreach ($entry in $sorted) {
        $key = ConvertTo-WtDateText $entry.Date
        if (-not $byDate.ContainsKey($key)) { $byDate[$key] = [System.Collections.Generic.List[object]]::new() }
        $byDate[$key].Add($entry)
    }
    for ($day = $From.Date; $day -le $To.Date; $day = $day.AddDays(1)) {
        $key = ConvertTo-WtDateText $day
        $dayItems = @()
        if ($byDate.ContainsKey($key)) { $dayItems = $byDate[$key].ToArray() }
        $days.Add([pscustomobject]@{ Date = $day; Items = $dayItems })
    }
    [pscustomobject]@{ Success = $errors.Count -eq 0; Reason = $(if ($errors.Count) { '일부 출처를 읽지 못했습니다' } else { '' })
        Items = $sorted; Days = $days.ToArray(); Errors = $errors.ToArray() }
}

Export-ModuleMember -Function Register-WtAddon, Get-WtAddon, Get-WtCalendarItems

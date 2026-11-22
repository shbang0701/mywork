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
  Group        메뉴 묶음 이름. 순서대로 처음 만난 묶음부터 그린다 (선택)
  Badge        { } → 숫자(개수), 'dot'(점), $null(없음). 실패하면 배지만 숨긴다 (선택)
  BadgeToolTip 상태 글. 숫자는 {0} 자리에 넣는다. 0·없음이면 이름만 보인다 (선택)
  BadgeKind    count(기본: 툴팁만) · dot(주의 점) · active(1 이상이면 강조 점)
  StatusItems  { } → @{ Key; Text; ToolTip; Icon = Segoe 글자 코드(선택); Side = 'left'|'right'; Open = @{ Id; Args = @{} } } 목록.
               켜진 탭만 탭 순서·등록 순서로 그린다. 실패한 탭·잘못된 항목은 뺀다 (선택)
  Required     $true면 설정에서 끌 수 없음 (홈)
  NewView      { } → 화면 요소를 돌려준다. 처음 열 때 한 번 부른다.
  Refresh      { param($view) } → 화면을 열 때마다 부른다 (선택)
  OnOpen       { param($OpenArgs) } → Open-WtPage로 옮긴 뒤 인자를 받는다 (선택)
  ShortcutExists { param($Key) } → 바로 가기 대상이 남아 있으면 $true (선택)
  HomeCard     { } → 홈에 놓을 카드 요소(여러 개 가능)를 돌려준다 (선택)
  HomeSlot     main(기본) · side · head(제목 아래 줄). HomeOrder가 작을수록 먼저 놓는다
  HomeCards    @(@{ Slot = 'head'|'main'|'side'; Order = 숫자; Card = { } }, ...). 한 탭의 여러 자리 카드 (선택)
  CalendarHost 작은 달력 날짜를 열 탭 표시 (선택)
  ImportLegacy { param($folder) } → 예전 WorkTool data 폴더에서 이 탭 데이터를 가져와 저장한다. 가져온 개수를 돌려준다 (선택)
  OnExit       { } → 끝내기 직전(SavePending 확인 뒤) 타이머·조회 등 실행 자원을 정리한다 (선택)
  SavePending  { } → 이 화면을 떠날 때 · 끝낼 때 저장. 실패하면 $false를 돌려준다.
                     그러면 셸이 다시 시도 · 저장하지 않고 이동(끝내기) · 취소를 묻는다 (선택)
  ConfirmExit  끝내면 사라질 내용(저장하지 않은 편집 폼 등)이 있을 때 끝내기 전에 사용자에게 묻는 자리 (선택)
               @{ Pending = { } → 물을 것이 있으면 $true. 묻지 않고 빨리 판단만 한다
                  Confirm = { } → 묻고, 끝내도 되면 $true · 취소(또는 저장 실패)면 $false. Pending이 $true일 때만 부른다 }
               셸은 끝낼 때(트레이 종료 · 닫기 = 끝내기 · Alt+F4) 맨 먼저, 저장 통로 마무리(SavePending) · 쓰지 못한 내용 확인보다 앞에
               탭 순서대로 부른다. Confirm 앞에 창을 띄우고 그 탭 화면을 보인다. 하나라도 $false면 끝내지 않고 뒤 단계도 묻지 않는다
  Help         도움말 「이 버전」에 넣을 설명 문단들 (선택)
  Shortcuts    도움말 「단축키」에 넣을 @('키', '설명') 목록. 키 처리는 탭 화면이 직접 한다 (선택)
               하나만 줄 때는 앞에 쉼표를 붙인다: -Shortcuts (, @('F5', '새로 고침'))
  HelpCard     { } → 도움말에 따로 놓을 카드 요소를 돌려준다 (선택)
  WarmUp       켠 뒤 한가할 때 화면을 미리 만들어 둘지 (선택). 처음 누를 때도 빨리 뜨게 하려는 것이다
               'Full' → NewView · Refresh를 미리 부른다. 이 탭의 데이터 파일만 읽고 밖에 영향이 없을 때만 쓴다
               'View' → NewView만 미리 부른다. Refresh가 폴더 조회 · 다른 창 수집처럼 느리거나 밖에 닿을 때 쓴다
  Related      다른 탭(일정 등)이 이 탭의 항목을 연결할 수 있게 하는 등록 (선택). 설계 13.4
               @{ Name = '메모'; Templates = @(@{ Id; Name }, ...)
                  Find = { param([string[]]$Keys) } → 키마다 @{ Key; Title; Sub; Missing }
                  Pick = { param([string[]]$Exclude) } → 고른 key 또는 $null
                  New = { param($Seed) } → 새 key. Seed = @{ Template; Title; Subject }
                  Window = { param($Key) } → 새 창으로 보기 }
               연결하는 탭은 Get-WtRelatedSource로 받는다. 탭끼리 서로 부르지 않는다
  DateMenu     { param([datetime]$Date) } → 다른 탭(일정 등)의 날짜 칸 우클릭에 붙일 항목들 (선택). 설계 15.6
               항목 = @{ Header = '글'; Action = { param($Arg) }; Arg = 넘길 값; ToolTip; IsEnabled = $false(끔); Items = @(항목 | '-') }
               Items가 있으면 하위 메뉴다. 메뉴를 그리는 탭은 Get-WtDateMenuItems로 받는다. 탭끼리 서로 부르지 않는다
  Tick         { param([datetime]$Now) } → 앱이 떠 있는 동안 TickSeconds(기본 60, 5~3600)마다 부른다 (선택). 설계 16
               화면에 묶지 않아서 트레이로 숨거나 최소화하거나 다른 탭을 볼 때도 돈다. 꺼진 탭은 부르지 않는다.
               실패는 그 탭 기록(Get-WtAddonTickError)에만 남기고 다음 틱을 막지 않는다(대화상자를 띄우지 않는다)
  SettingRows  { } → 설정 화면에 넣을 행 @(@{ Group = '알림'; Label = '라벨'; Control = 화면 요소; Note = '툴팁' }) (선택)
               지금 받는 묶음은 일반 탭의 '알림'뿐이다. 켜진 탭만, 탭 순서대로 코어 행 앞에 놓는다
#>
function Register-WtAddon {
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [int]$Icon = 0xE10C,
        [int]$Order = 100,
        [string]$Group = '',
        [scriptblock]$Badge,
        [string]$BadgeToolTip = '',
        [ValidateSet('count', 'dot', 'active')][string]$BadgeKind = 'count',
        [scriptblock]$StatusItems,
        [switch]$Required,
        [Parameter(Mandatory)][scriptblock]$NewView,
        [scriptblock]$Refresh,
        [scriptblock]$OnOpen,
        [scriptblock]$ShortcutExists,
        [scriptblock]$HomeCard,
        [ValidateSet('head', 'main', 'side')][string]$HomeSlot = 'main',
        [int]$HomeOrder = 100,
        [switch]$CalendarHost,
        [scriptblock]$CalendarItems,
        [scriptblock]$ImportLegacy,
        [scriptblock]$OnExit,
        [scriptblock]$SavePending,
        [hashtable]$ConfirmExit,
        [ValidateSet('', 'View', 'Full')][string]$WarmUp = '',
        [string]$Description = '',
        [string[]]$Help = @(),
        [object[]]$Shortcuts = @(),
        [scriptblock]$HelpCard,
        [object[]]$HomeCards = @(),
        [hashtable]$Related,
        [scriptblock]$DateMenu,
        [scriptblock]$Tick,
        [ValidateRange(5, 3600)][int]$TickSeconds = 60,
        [scriptblock]$SettingRows
    )
    # 쉼표 없이 한 쌍만 주면 배열이 펴져서 들어온다 → 한 쌍으로 되돌린다
    if ($Shortcuts.Count -and $Shortcuts[0] -is [string]) { $Shortcuts = @(, $Shortcuts) }
    foreach ($s in $Shortcuts) {
        if (@($s).Count -ne 2) { throw "애드온 '$Id'의 단축키는 @('키', '설명') 모양이어야 합니다." }
    }
    $relatedEntry = $null
    if ($Related) {
        if (-not ($Related.Name -is [string] -and $Related.Name.Trim())) { throw "애드온 '$Id'의 Related에는 Name(글)이 필요합니다." }
        foreach ($key in 'Find', 'Pick', 'New', 'Window') {
            if ($Related[$key] -isnot [scriptblock]) { throw "애드온 '$Id'의 Related에는 $key(함수)가 필요합니다." }
        }
        $templates = @(foreach ($t in @($Related.Templates)) {
                if ($null -eq $t) { continue }
                if (-not ($t.Id -is [string] -and $t.Id -and $t.Name -is [string] -and $t.Name)) { throw "애드온 '$Id'의 Related 틀은 @{ Id; Name } 모양이어야 합니다." }
                [pscustomobject]@{ Id = $t.Id; Name = $t.Name }
            })
        if (-not $templates.Count) { $templates = @([pscustomobject]@{ Id = 'blank'; Name = "새 $($Related.Name)" }) }
        $relatedEntry = [pscustomobject]@{ Name = $Related.Name.Trim(); Templates = $templates
            Find = $Related.Find; Pick = $Related.Pick; New = $Related.New; Window = $Related.Window }
    }
    $exitEntry = $null
    if ($ConfirmExit) {
        foreach ($key in 'Pending', 'Confirm') {
            if ($ConfirmExit[$key] -isnot [scriptblock]) { throw "애드온 '$Id'의 ConfirmExit에는 $key(함수)가 필요합니다." }
        }
        $exitEntry = [pscustomobject]@{ Pending = $ConfirmExit.Pending; Confirm = $ConfirmExit.Confirm }
    }
    $cards = @($HomeCards)
    if (-not $PSBoundParameters.ContainsKey('HomeCards') -and $HomeCard) {
        $cards = @(@{ Slot = $HomeSlot; Order = $HomeOrder; Card = $HomeCard })
    }
    foreach ($card in $cards) {
        if ($card.Slot -cnotin @('head', 'main', 'side') -or $card.Card -isnot [scriptblock] -or $card.Order -isnot [int]) {
            throw "애드온 '$Id'의 홈 카드는 Slot(head/main/side) · Order(정수) · Card(함수)가 필요합니다."
        }
    }
    for ($i = $script:addons.Count - 1; $i -ge 0; $i--) {
        if ($script:addons[$i].Id -eq $Id) { $script:addons.RemoveAt($i) }
    }
    $script:addons.Add(@{
            Id = $Id; Title = $Title; Icon = $Icon; Order = $Order; Group = $Group; Badge = $Badge; BadgeToolTip = $BadgeToolTip; BadgeKind = $BadgeKind; StatusItems = $StatusItems; Required = [bool]$Required
            NewView = $NewView; Refresh = $Refresh; OnOpen = $OnOpen; ShortcutExists = $ShortcutExists
            HomeCard = $HomeCard; HomeSlot = $HomeSlot; HomeOrder = $HomeOrder; CalendarHost = [bool]$CalendarHost
            HomeCards = $cards
            CalendarItems = $CalendarItems; ImportLegacy = $ImportLegacy; OnExit = $OnExit
            Description = $Description
            SavePending = $SavePending; ConfirmExit = $exitEntry; WarmUp = $WarmUp
            Help = @($Help); Shortcuts = @($Shortcuts); HelpCard = $HelpCard
            Related = $relatedEntry; DateMenu = $DateMenu
            Tick = $Tick; TickSeconds = $TickSeconds; SettingRows = $SettingRows
        })
    # 같은 탭을 다시 등록하면서 표시 함수를 뺐으면 옛 등록도 없앤다.
    Register-WtCalendarSource -Id "addon:$Id" -Page $Id -CalendarItems $CalendarItems
}

function Get-WtHomeCards {
    @(foreach ($addon in @(Get-WtAddon)) {
        foreach ($card in @($addon.HomeCards)) {
            $entry = $addon.Clone()
            $entry.HomeCard = $card.Card; $entry.HomeSlot = $card.Slot; $entry.HomeOrder = $card.Order
            $entry
        }
    }) | Sort-Object HomeSlot, HomeOrder, Id
}

function Get-WtCalendarHost {
    Get-WtAddon | Where-Object CalendarHost | Select-Object -First 1
}

# 연결할 수 있는 항목을 등록한 켜진 탭들(설계 13.4). -Page를 주면 그 탭 하나(꺼졌거나 등록이 없으면 없음)
function Get-WtRelatedSource([string]$Page) {
    foreach ($addon in @(Get-WtAddon)) {
        if (-not $addon.Related) { continue }
        if ($Page -and $addon.Id -cne $Page) { continue }
        $r = $addon.Related
        [pscustomobject]@{ Page = $addon.Id; Name = $r.Name; Icon = $addon.Icon; Templates = @($r.Templates); Find = $r.Find; Pick = $r.Pick; New = $r.New; Window = $r.Window }
    }
}

# 날짜 칸 우클릭에 붙일 다른 탭의 항목(설계 15.6). Exclude = 메뉴를 그리는 탭 자신.
# @{ Page; Title; Item = 탭이 준 항목; Error = 만들지 못한 이유 } 목록. 한 탭이 실패해도 다른 탭 항목은 그대로 준다
function Get-WtDateMenuItems([datetime]$Date, [string]$Exclude = '') {
    foreach ($addon in @(Get-WtAddon)) {
        if (-not $addon.DateMenu -or $addon.Id -ceq $Exclude) { continue }
        try {
            foreach ($item in @(& $addon.DateMenu $Date.Date)) {
                if ($null -ne $item) { [pscustomobject]@{ Page = $addon.Id; Title = $addon.Title; Item = $item; Error = '' } }
            }
        } catch { [pscustomobject]@{ Page = $addon.Id; Title = $addon.Title; Item = $null; Error = $_.Exception.Message } }
    }
}

# ---- 앱이 떠 있는 동안 도는 작업(Tick, 설계 16) ---------------------------------------------------
$script:tickTimers = [System.Collections.Generic.List[object]]::new()
$script:tickErrors = @{}

# 한 탭의 Tick을 부른다. 꺼졌거나 Tick이 없으면 $false. 실패는 그 탭 기록에만 남긴다
function Invoke-WtAddonTick([string]$Id, [datetime]$Now = (Get-Date)) {
    $addon = Get-WtAddon -Id $Id
    if (-not $addon -or -not $addon.Tick) { return $false }
    try { [void](& $addon.Tick $Now); [void]$script:tickErrors.Remove($Id); $true }
    catch { $script:tickErrors[$Id] = $_.Exception.Message; $false }
}
function Get-WtAddonTickError([string]$Id) { $script:tickErrors[$Id] }

# 셸이 앱을 띄울 때 부른다. Tick을 등록한 탭마다 타이머 하나(꺼진 탭은 틱마다 건너뜀). 만든 타이머 수를 돌려준다
function Start-WtAddonTicks {
    Stop-WtAddonTicks
    foreach ($addon in @(Get-WtAddon -All)) {
        if (-not $addon.Tick) { continue }
        $timer = [System.Windows.Threading.DispatcherTimer]::new()
        $timer.Interval = [TimeSpan]::FromSeconds($addon.TickSeconds)
        $timer.Tag = $addon.Id
        $timer.Add_Tick({ param($s, $e) [void](Invoke-WtAddonTick ([string]$s.Tag)) })
        $timer.Start()
        $script:tickTimers.Add($timer)
    }
    $script:tickTimers.Count
}
function Stop-WtAddonTicks {
    foreach ($timer in $script:tickTimers) { $timer.Stop() }
    $script:tickTimers.Clear()
}

# 설정 화면 묶음(Group)에 넣을 탭의 행. 켜진 탭만 탭 순서대로. 한 탭이 실패하면 그 탭의 오류 줄 하나(Error)로 바꾼다
function Get-WtAddonSettingRows([string]$Group) {
    foreach ($addon in @(Get-WtAddon)) {
        if (-not $addon.SettingRows) { continue }
        try {
            $rows = @(foreach ($row in @(& $addon.SettingRows)) {
                    if ($null -eq $row -or [string]$row.Group -cne $Group) { continue }
                    if (-not ($row.Label -is [string] -and $row.Label) -or $row.Control -isnot [System.Windows.UIElement]) { throw '설정 행은 Label(글) · Control(화면 요소)이 필요합니다.' }
                    [pscustomobject]@{ Page = $addon.Id; Label = $row.Label; Control = $row.Control; Note = [string]$row.Note; Error = '' }
                })
            $rows
        } catch { [pscustomobject]@{ Page = $addon.Id; Label = $addon.Title; Control = $null; Note = ''; Error = $_.Exception.Message } }
    }
}

# 반차처럼 하루의 일부만인 달력 항목(AllDay = $false). 칸이 없으면 하루 종일로 본다
function Test-WtCalendarPartDay($Item) {
    $value = if ($Item -is [System.Collections.IDictionary]) { $Item['AllDay'] } else { $p = $Item.PSObject.Properties['AllDay']; if ($p) { $p.Value } else { $null } }
    $value -is [bool] -and -not $value
}

# 달력 출처의 의미(탭 이름 아님)와 업무시간으로 표시만 계산한다. 근무 기록은 쉬는 날보다 우선한다.
# 달력 표시. 평소 근무일 · 주말은 Kind가 비고, 업무외 → 휴가 → 휴무일 순서로 하나만 고른다.
# 쉬는 날 = 그날 업무시간 규칙(설계 15.1)의 근무 요일이 아님 · 휴무일 · 하루 종일 휴가. 반차(AllDay = $false인 휴가)는 숫자 바탕만 휴가 색이다
function Get-WtCalendarMark([datetime]$Date, [object[]]$Items) {
    $dayItems = @($Items | Where-Object { $_.Date.Date -eq $Date.Date })
    $holiday = @($dayItems | Where-Object { $_.Kind -cin @('public', 'company', 'personal') }).Count -gt 0
    $leaveItems = @($dayItems | Where-Object { $_.Kind -ceq 'leave' })
    $leave = @($leaveItems | Where-Object { -not (Test-WtCalendarPartDay $_) }).Count -gt 0
    $weekday = (([int]$Date.DayOfWeek + 6) % 7) + 1
    $off = $weekday -notin @((Get-WtWorkHours -Date $Date)['work.days']) -or $holiday -or $leave
    $work = @($dayItems | Where-Object { $_.Kind -cin @('work', 'trip') }).Count -gt 0
    $over = @($dayItems | Where-Object { $_.Kind -ceq 'overtime' }).Count -gt 0
    $kind = if ($over -or ($work -and $off)) { 'over' } elseif ($leaveItems.Count) { 'leave' } elseif ($holiday) { 'off' } else { '' }
    $look = switch ($kind) {
        'over' { @('B.Cal.Overtime.Bg', 'B.Cal.Overtime.Text') }
        'leave' { @('B.Cal.Leave.Bg', 'B.Cal.Leave.Text') }
        'off' { @('B.Status.Error.Bg', 'B.Status.Error.Text') }
        default { @('', '') }
    }
    [pscustomobject]@{ DayOff = $off; Kind = $kind; Back = $look[0]; Fore = $look[1]
        ToolTip = (@($dayItems | ForEach-Object Text | Where-Object { $_ }) -join "`n") }
}

# 순서대로 돌려준다. -All이 없으면 설정에서 끈 탭은 뺀다.
function Get-WtAddon {
    param([switch]$All, [string]$Id)
    $disabled = @(Get-WtSetting 'addons.disabled')
    # ID 하나를 찾을 때는 전체 정렬을 하지 않는다. 목록과 같은 활성 규칙을 적용한다.
    if ($Id) {
        foreach ($addon in $script:addons) {
            if ($addon.Id -ne $Id) { continue }
            if ($All -or $addon.Required -or $disabled -notcontains $addon.Id) { return $addon }
            return
        }
        return
    }
    $list = $script:addons | Sort-Object { $_.Order }, { $_.Id }
    if ($All) { return $list }
    $list | Where-Object { $_.Required -or $disabled -notcontains $_.Id }
}

# 표시 자료와 변경 확인은 같은 활성 출처 목록을 쓴다.
function Get-WtActiveCalendarSources([string[]]$Exclude = @()) {
    foreach ($source in @(Get-WtCalendarSource)) {
        if ($source.Id -cin $Exclude -or ($source.Page -and $source.Page -cin $Exclude)) { continue }
        if ($source.Page) {
            $addon = Get-WtAddon -Id $source.Page
            if (-not $addon -or $addon.Id -cne $source.Page) { continue }
        }
        $source
    }
}
function Get-WtCalendarStores([string[]]$Exclude = @()) {
    $names = [Collections.Generic.List[string]]::new()
    $keys = [Collections.Generic.List[string]]::new()
    foreach ($source in @(Get-WtActiveCalendarSources $Exclude)) {
        $declared = Get-WtCalendarStoreRegistration $source.Id
        if ($null -eq $declared) { return @{ Complete = $false } }
        foreach ($name in $declared.Names) { $names.Add($name) }
        $keys.Add($declared.Version.ToString([Globalization.CultureInfo]::InvariantCulture))
    }
    @{ Complete = $true; Names = $names.ToArray(); Key = ($keys -join '|') }
}
# From ~ To(그날 포함). 한 출처의 실패는 Errors에 남기고 나머지는 계속 모은다.
function Get-WtCalendarItems([datetime]$From, [datetime]$To, [string[]]$Exclude = @()) {
    $items = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[object]]::new()
    $days = [System.Collections.Generic.List[object]]::new()
    if ($From.Date -gt $To.Date -or -not (ConvertFrom-WtDateText (ConvertTo-WtDateText $From)) -or -not (ConvertFrom-WtDateText (ConvertTo-WtDateText $To))) {
        return [pscustomobject]@{ Success = $false; Reason = '날짜 범위를 확인하세요'; Items = @(); Days = @(); Errors = @() }
    }
    foreach ($source in @(Get-WtActiveCalendarSources $Exclude)) {
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

Export-ModuleMember -Function Get-WtCalendarStores, Register-WtAddon, Get-WtAddon, Get-WtCalendarItems, Get-WtHomeCards, Get-WtCalendarHost, Get-WtCalendarMark, Get-WtRelatedSource,
    Get-WtDateMenuItems, Test-WtCalendarPartDay, Invoke-WtAddonTick, Get-WtAddonTickError, Start-WtAddonTicks, Stop-WtAddonTicks, Get-WtAddonSettingRows

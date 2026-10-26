# 연 기록 · 홈 고정. shortcuts.json schema 1. 탭 연결은 Addons의 등록 목록만 거친다.
# items: id, page, key, title, sub, icon, uses(앱 시각 배열), pinned, pinOrder, created, updated.
# 모르는 칸 · 깨진 항목도 그대로 남긴다. 디스크 실패 보유 · 재시도는 저장 모듈이 맡는다.
$ErrorActionPreference = 'Stop'

function Test-WtShortcutItem($Item) {
    (Test-WtRecordObject $Item) -and $Item.page -is [string] -and $Item.page -and
        $Item.key -is [string] -and $Item.key -and $Item.title -is [string] -and
        $Item.pinned -is [bool] -and (Get-WtField $Item 'uses') -is [array] -and
        (-not $Item.pinned -or $null -ne (ConvertFrom-WtWhole $Item.pinOrder 1 ([long]::MaxValue)))
}

function Get-WtShortcutUses($Item, [DateTimeOffset]$Now) {
    foreach ($stamp in @($Item.uses)) {
        $time = ConvertFrom-WtStamp ([string]$stamp)
        if ($null -ne $time -and $time -ge $Now.AddDays(-30) -and $time -le $Now) { [string]$stamp }
    }
}

function Edit-WtShortcut {
    param([string]$Page, [string]$Key, [string]$Title, [string]$Sub, [int]$Icon, [switch]$Use, [bool]$Pinned)
    if (-not $Page -or -not $Key) { return $false }
    $store = Open-WtStore -Name 'shortcuts' -Schema 1
    if ($store.State -notin 'ok', 'missing') { return $false }
    $items = @(Copy-WtItem @($store.Items))
    $item = $items | Where-Object { (Test-WtShortcutItem $_) -and $_.page -ceq $Page -and $_.key -ceq $Key } | Select-Object -First 1
    $now = [DateTimeOffset]::Now
    $at = Get-WtStamp $now
    if (-not $item) {
        # 같은 키의 읽을 수 없는 항목은 덮어쓰지 않는다.
        if (@($items | Where-Object { (Get-WtField $_ 'page') -ceq $Page -and (Get-WtField $_ 'key') -ceq $Key }).Count) { return $false }
        $item = [pscustomobject]@{ id = New-WtId; page = $Page; key = $Key; title = $Title; sub = $Sub; icon = $Icon
            uses = @(); pinned = $false; pinOrder = $null; created = $at; updated = $at }
        $items += ,$item
    }
    Set-WtField $item 'title' $Title
    Set-WtField $item 'sub' $Sub
    Set-WtField $item 'icon' $Icon
    Set-WtField $item 'updated' $at
    # 저장할 때 모든 아는 항목의 오래된 기록을 버린다. 미래 버전/깨진 항목은 건드리지 않는다.
    foreach ($entry in $items) {
        if (Test-WtShortcutItem $entry) { Set-WtField $entry 'uses' @(Get-WtShortcutUses $entry $now | Sort-Object { (ConvertFrom-WtStamp $_).UtcTicks } | Select-Object -Last 200) }
    }
    if ($Use) { Set-WtField $item 'uses' @(@($item.uses) + $at | Select-Object -Last 200) }
    else {
        if ($Pinned -and -not $item.pinned) {
            $last = [long]0
            foreach ($entry in $items) {
                $order = ConvertFrom-WtWhole (Get-WtField $entry 'pinOrder') 1 ([long]::MaxValue)
                if ($null -ne $order -and $order -gt $last) { $last = $order }
            }
            Set-WtField $item 'pinOrder' ($last + 1)
        }
        Set-WtField $item 'pinned' $Pinned
    }
    try { [void](Save-WtStore -Store $store -Items $items); return $true }
    catch { Write-Warning "바로 가기 저장: $($_.Exception.Message)"; return $false }
}

function Add-WtUse {
    param([Parameter(Mandatory)][string]$Page, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Title,
        [string]$Sub = '', [int]$Icon = 0xE8A5)
    [void](Edit-WtShortcut -Page $Page -Key $Key -Title $Title -Sub $Sub -Icon $Icon -Use)
}

function Set-WtHomePin {
    param([Parameter(Mandatory)][string]$Page, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Title,
        [string]$Sub = '', [int]$Icon = 0xE8A5, [Parameter(Mandatory)][bool]$Pinned)
    [void](Edit-WtShortcut -Page $Page -Key $Key -Title $Title -Sub $Sub -Icon $Icon -Pinned $Pinned)
}

function Test-WtHomePin {
    param([Parameter(Mandatory)][string]$Page, [Parameter(Mandatory)][string]$Key)
    $store = Open-WtStore -Name 'shortcuts' -Schema 1
    @($store.Items | Where-Object { (Test-WtShortcutItem $_) -and $_.page -ceq $Page -and $_.key -ceq $Key -and $_.pinned }).Count -gt 0
}

function Get-WtShortcuts {
    param([ValidateRange(1, 200)][int]$Max = 8)
    $store = Open-WtStore -Name 'shortcuts' -Schema 1
    $now = [DateTimeOffset]::Now
    $enabled = [System.Collections.Generic.Dictionary[string, hashtable]]::new([StringComparer]::Ordinal)
    foreach ($addon in @(Get-WtAddon)) { $enabled[$addon.Id] = $addon }
    $results = foreach ($item in $store.Items) {
        if (-not (Test-WtShortcutItem $item) -or -not $enabled.ContainsKey($item.page)) { continue }
        $addon = $enabled[$item.page]
        try { if ($addon.ShortcutExists -and -not (& $addon.ShortcutExists $item.key)) { continue } } catch { continue }
        $uses = @(Get-WtShortcutUses $item $now | Sort-Object { (ConvertFrom-WtStamp $_).UtcTicks })
        if (-not $item.pinned -and -not $uses.Count) { continue }
        [pscustomobject]@{ Page = $item.page; Key = $item.key; Title = $item.title; Sub = [string]$item.sub; Icon = $item.icon
            Pinned = $item.pinned; Count = $uses.Count; PinOrder = $item.pinOrder
            Last = $(if ($uses.Count) { (ConvertFrom-WtStamp $uses[-1]).UtcTicks } else { 0 }) }
    }
    $results | Sort-Object @{ Expression = { -not $_.Pinned } }, @{ Expression = { if ($_.Pinned) { $_.PinOrder } else { 0 } } },
        @{ Expression = { $_.Count }; Descending = $true }, @{ Expression = { $_.Last }; Descending = $true }, Title, Page, Key -Culture 'ko-KR' |
        Select-Object -First $Max -Property Page, Key, Title, Sub, Icon, Pinned, Count
}

Export-ModuleMember -Function Add-WtUse, Set-WtHomePin, Test-WtHomePin, Get-WtShortcuts

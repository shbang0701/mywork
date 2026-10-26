# 홈은 등록 목록만 모은다. 다른 탭 함수나 저장소를 직접 부르지 않는다.
$ErrorActionPreference = 'Stop'
$script:layout = $null
$script:month = [datetime]::new([datetime]::Today.Year, [datetime]::Today.Month, 1)

function New-WtHomeView {
    $script:layout = New-WtHomeLayout
    $script:layout.Root
}

function New-WtHomeCalendar {
    $first = [datetime]::new($script:month.Year, $script:month.Month, 1)
    $start = $first.AddDays(-[int]$first.DayOfWeek)
    $calendar = Get-WtCalendarItems -From $start -To $start.AddDays(41)
    New-WtMiniCalendar -Month $first -Calendar $calendar -OnMonth {
        param($Month)
        $script:month = $Month
        Update-WtHomeView
    }
}

function Update-WtHomeView {
    $script:layout.Main.Children.Clear(); $script:layout.Side.Children.Clear()
    $cards = @(
        [pscustomobject]@{ Id = 'home-shortcuts'; HomeSlot = 'main'; HomeOrder = 20; HomeCard = { New-WtShortcutCard @(Get-WtShortcuts) -OnChange { Update-WtHomeView } } }
        [pscustomobject]@{ Id = 'home-calendar'; HomeSlot = 'side'; HomeOrder = 10; HomeCard = { New-WtHomeCalendar } }
    ) + @(Get-WtHomeCards)
    foreach ($card in @($cards | Sort-Object HomeSlot, HomeOrder, Id)) {
        $column = if ($card.HomeSlot -eq 'side') { $script:layout.Side } else { $script:layout.Main }
        try {
            foreach ($element in @(& $card.HomeCard)) {
                if ($element -is [System.Windows.UIElement]) { [void](Add-WtChild $column $element) }
            }
        } catch { Write-Warning "홈 카드: $($_.Exception.Message)" }
    }
}

Register-WtAddon -Id 'home' -Title '홈' -Icon 0xE80F -Group '일과' -Order 0 -Required `
    -NewView { New-WtHomeView } `
    -Refresh { param($view) Update-WtHomeView } -Help '오늘 일정과 바로 가기, 작은 달력을 보여 줍니다.'

Export-ModuleMember -Function @()

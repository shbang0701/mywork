<#
.SYNOPSIS
    가짜 카드·달력 출처와 시험 저장소로 홈 배치·달 이동·바로 가기 상태를 확인한다.
.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/addons/home/Test-Home.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tests/TestKit.ps1')
Import-WtTestCore
Import-Module (Join-Path $PSScriptRoot 'Home.psm1') -Force -DisableNameChecking
$test = New-WtTestData 'home'
$module = Get-Module Home
try {
    if (-not (Test-WtTestWpf)) { Write-Host 'SKIP 홈 화면 (Windows STA에서만)'; return }
    Register-WtAddon -Id 'test-before' -Title '앞' -NewView { New-WtText '가짜' } -HomeCard { New-WtText '앞 카드' } -HomeSlot main -HomeOrder 10
    Register-WtAddon -Id 'test-after' -Title '뒤' -NewView { New-WtText '가짜' } -HomeCard { New-WtText '뒤 카드' } -HomeSlot main -HomeOrder 30
    Register-WtAddon -Id 'test-side' -Title '옆' -NewView { New-WtText '가짜' } -CalendarHost -HomeCard { New-WtText '옆 카드' } -HomeSlot side -HomeOrder 20
    Register-WtAddon -Id 'test-head' -Title '머리' -NewView { New-WtText '가짜' } -HomeCard { New-WtText '머리 줄' } -HomeSlot head -HomeOrder 10
    $view = New-WtTestView home
    & $module { Update-WtHomeView }
    $layout = & $module { $script:layout }
    $view.Measure([Windows.Size]::new(1080,744)); $view.Arrange([Windows.Rect]::new(0,0,1080,744)); $view.UpdateLayout()
    Assert-WtTest '홈: 카드 사이 8 · 오른쪽 320 · 머리 · main · side 자리와 순서' ($layout.Main.Parent.ColumnDefinitions[1].Width.Value -eq 8 -and $layout.Main.Parent.ColumnDefinitions[2].Width.Value -eq 320 -and $layout.Main.Children.Count -eq 3 -and
        (Get-WtTestTexts $layout.Main.Children[0]) -ceq '앞 카드' -and (Get-WtTestTexts $layout.Main.Children[2]) -ceq '뒤 카드' -and (Get-WtTestTexts $layout.Side.Children[1]) -ceq '옆 카드' -and
        $layout.Title.Text -and (Get-WtTestTexts $layout.Head.Children[0]) -ceq '머리 줄')
    Assert-WtTest '홈: 바로 가기 비어 있음은 한 줄' ((Get-WtTestTexts $layout.Main.Children[1]) -contains '자주 연 항목이 여기에 표시됩니다')
    $calendar = $layout.Side.Children[0]
    Assert-WtTest '홈: 작은 달력 7열 6주 · 40×32 42칸 · 색 설명' ($calendar.Child.Children[2].Columns -eq 7 -and $calendar.Child.Children[2].Rows -eq 6 -and
        $calendar.Child.Children[2].Children.Count -eq 42 -and $calendar.Child.Children[2].ActualWidth -eq 280 -and $calendar.Child.Children[2].ActualHeight -eq 192 -and
        (@(Get-WtTestTexts $calendar.Child.Children[3]) -join ',') -ceq '업무외,휴가,휴무일')
    $oldMonth = & $module { $script:month }
    $previous = $calendar.Child.Children[0].Children[1].Children[0]
    $previous.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
    Assert-WtTest '홈: 이전 달 단추가 달력만 이동' ((& $module { $script:month }) -eq $oldMonth.AddMonths(-1))
    # 사용한 항목 10개 중 최대 8개를 2열로 놓고, 고정하면 즉시 순서가 바뀐다.
    for ($i = 0; $i -lt 10; $i++) { Add-WtUse -Page test-before -Key ([string]$i) -Title ("항목 $i") -Sub '시험' }
    & $module { Update-WtHomeView }
    $grid = $layout.Main.Children[1].Child.Children[1]
    Assert-WtTest '홈: 바로 가기 2열 · 최대 8개 · 폭에 맞춘 높이 48' ($grid.Children.Count -eq 8 -and [Windows.Controls.Grid]::GetColumn($grid.Children[1]) -eq 2 -and $grid.ColumnDefinitions[0].Width.IsStar -and $grid.Children[0].Height -eq 48)
    $last = $grid.Children[7].Tag
    $menuItem = New-WtHomePinMenuItem $last -OnChange { & (Get-Module Home) { Update-WtHomeView } }
    $menuItem.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.MenuItem]::ClickEvent))
    Assert-WtTest '홈: 고정 메뉴는 저장하고 바로 다시 그린다' ((Test-WtHomePin $last.Page $last.Key) -and $layout.Main.Children[1].Child.Children[1].Children[0].Tag.Key -ceq $last.Key)
    # 빈 시간 막대 · 지금 선 · 두 겹/넘침은 가짜 대상으로만 본다.
    $date = [datetime]::Today
    $timeline = New-WtTimeline @() $date test-before
    Update-WtTimelineNow $timeline.Timeline $date.AddHours(12)
    Assert-WtTest '시간 막대: 빈 상태에도 막대 · 지금 선 2×28 · 업무시간 기준 범위' ((Get-WtTestTexts $timeline.Card) -contains '오늘 일정 없음' -and
        $timeline.Timeline.Tag.Line.Width -eq 2 -and $timeline.Timeline.Tag.Line.Height -eq 28 -and $timeline.Timeline.Tag.Line.Visibility -eq 'Visible' -and
        $timeline.Timeline.Tag.Start -eq 480 -and $timeline.Timeline.Tag.End -eq 1200)
    $events = @(1..3 | ForEach-Object { [pscustomobject]@{ Id = [string]$_; Title = "겹침 $_"; Start = $date.AddHours(10); End = $date.AddHours(11); AllDay = $false; Alarm = $false; ToolTip = "상세 $_" } })
    $timeline = New-WtTimeline $events $date test-before
    $bars = @($timeline.Timeline.Children | Where-Object { $_ -is [Windows.Controls.Button] -and $_.Visibility -eq 'Visible' })
    Assert-WtTest '시간 막대: 겹침은 두 줄 · 그 이상 +n · 상세 툴팁' ($bars.Count -eq 2 -and $bars[0].ToolTip -ceq '상세 1' -and (Get-WtTestTexts $timeline.Card) -contains '+1')
    $outside = [pscustomobject]@{ Id = 'outside'; Title = '양 끝 밖'; Start = $date.AddHours(7); End = $date.AddHours(21); AllDay = $false; Alarm = $false; ToolTip = '양 끝 밖 상세' }
    $timeline = New-WtTimeline @($outside) $date test-before
    $bar = @($timeline.Timeline.Children | Where-Object { $_ -is [Windows.Controls.Button] })[0]
    Assert-WtTest '시간 막대: 범위 양 끝 밖 일정은 양쪽 끝 표시' ($bar.Width -eq 584 -and $bar.Content.Width -eq 584 -and $bar.Content.Children.Count -eq 2 -and $bar.Content.Children[0].HorizontalAlignment -eq 'Left' -and $bar.Content.Children[1].HorizontalAlignment -eq 'Right')
    $timeline.Timeline.Measure([Windows.Size]::new(400, 116)); $timeline.Timeline.Arrange([Windows.Rect]::new(0, 0, 400, 116)); $timeline.Timeline.UpdateLayout()
    Assert-WtTest '시간 막대: 카드 폭이 바뀌면 막대도 그 폭에 맞춘다' ($bar.Width -eq 400 -and $bar.Content.Width -eq 400)
    # 지난 일정 · 다음 일정 · 뒤 일정을 지금 시각으로 나눈다.
    $day = @(9, 13, 15 | ForEach-Object { [pscustomobject]@{ Id = [string]$_; Title = "일정 $_"; Start = $date.AddHours($_); End = $date.AddHours($_ + 1); AllDay = $false; Alarm = $false; ToolTip = "상세 $_" } })
    $timeline = New-WtTimeline $day $date test-before
    Update-WtTimelineNow $timeline.Timeline $date.AddHours(12).AddMinutes(20)
    $weights = @($timeline.Timeline.Tag.Events | ForEach-Object { [string]$_.Caption.FontWeight }) -join ','
    Assert-WtTest '시간 막대: 다음 일정 하나만 굵게' ($weights -ceq 'Normal,SemiBold,Normal') $weights
    $next = New-WtNextEventLine $day
    Update-WtNextEventLine $next $date.AddHours(12).AddMinutes(20)
    $soon = "$($next.Tag.Pill.Child.Text)|$($next.Tag.Title.Text)"
    Update-WtNextEventLine $next $date.AddHours(12).AddMinutes(50)
    $minutes = $next.Tag.Pill.Child.Text
    Update-WtNextEventLine $next $date.AddHours(13).AddMinutes(30)
    $running = $next.Tag.Pill.Child.Text
    Update-WtNextEventLine $next $date.AddHours(17)
    Assert-WtTest '다음 일정 줄: 남은 시간 · 진행 중 · 다 끝나면 숨김' ($soon -ceq '40분 후|13:00 일정 13' -and $minutes -ceq '10분 후' -and $running -ceq '진행 중' -and $next.Visibility -eq 'Collapsed') "$soon / $minutes / $running"
} finally { Stop-WtDataWrites -Milliseconds 3000; Stop-WtAllWork; Remove-WtTestData $test }

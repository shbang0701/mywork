<#
.SYNOPSIS
    알림 부품(core\Notice.psm1)과 코어의 틱 · 설정 행 등록을 검사한다: 잠시 끄기 · 소리 · 쌓기 자리 · 창 내용 · 입력 경로 · 단추 · 다시 알림 · 메뉴 · 트레이 · 상태 줄 · 설정 화면.
.DESCRIPTION
    실제 창을 띄우거나 소리를 내지 않는다. OS에 닿는 곳(창 보이기 · 작업 영역 · 소리 재생기 · Windows 기본 소리 · 앱 창 열기)만
    가짜로 바꿔 끼우고, 15초 타이머는 끈다. 창 내용은 숨김 호스트(WindowStyle 0인 HwndSource)에 붙여 배치 · 좌표 경로만 본다.
    탭이 필요한 곳은 가짜 탭을 등록한다. tests\Test-Core.ps1이 부르고, 혼자 돌려도 된다.
.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/tests/Test-Notice.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-WtTestCore
# 쌓기 자리(Rect · Point) · 트레이 메뉴(WinForms 객체)는 화면 없이도 형식만 쓴다
Add-Type -AssemblyName WindowsBase, PresentationCore, PresentationFramework, System.Windows.Forms
$test = New-WtTestData 'notice'
$notice = Get-Module Notice
$global:wtNoticeProbe = @{ Shown = 0; System = 0; Opened = [System.Collections.Generic.List[object]]::new(); Ticks = [System.Collections.Generic.List[object]]::new(); MenuHit = ''; Undone = '' }
$seams = & $notice {
    $saved = @{ Show = $script:showWindow; Area = $script:workArea; Player = $script:newPlayer; System = $script:systemSound; Open = $script:openPage; Timer = $script:useTimer }
    $script:useTimer = $false
    $script:player = $null
    $script:showWindow = { param($Window) $global:wtNoticeProbe.Shown++ }
    $script:workArea = { [System.Windows.Rect]::new(0, 0, 1920, 1040) }
    $script:systemSound = { $global:wtNoticeProbe.System++ }
    $script:openPage = { param($Id, $OpenArgs) $global:wtNoticeProbe.Opened.Add(@($Id, $OpenArgs)) }
    $script:newPlayer = {
        $fake = [pscustomobject]@{ Volume = -1.0; Opened = ''; Plays = 0 }
        $fake | Add-Member ScriptMethod Open { param($Uri) $this.Opened = [string]$Uri }
        $fake | Add-Member ScriptMethod Play { $this.Plays++ }
        $fake | Add-Member ScriptMethod Stop { }
        $fake
    }
    $saved
}
$hostSource = $null
$addonsBefore = & (Get-Module Addons) { , $script:addons.ToArray() }
function Find-WtTestNamed($Root, [string]$Name) {
    if ($Root -is [System.Windows.DependencyObject] -and [System.Windows.Automation.AutomationProperties]::GetName($Root) -ceq $Name) { return $Root }
    if ($Root -is [System.Windows.DependencyObject]) {
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Root)) { $found = Find-WtTestNamed $child $Name; if ($found) { return $found } }
    }
}
function Wait-WtTestDispatcher([int]$Milliseconds) {
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $timer = [System.Windows.Threading.DispatcherTimer]::new(); $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds); $timer.Tag = $frame
    $timer.Add_Tick({ param($s, $e) $s.Stop(); $s.Tag.Continue = $false })
    $timer.Start(); [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
try {
    # ---- 알람 잠시 끄기 (화면 없음) ----
    $t0 = [datetime]'2026-11-23 14:30:00'
    $off = Get-WtNoticePause $t0
    $hour = Set-WtNoticePause hour $t0
    $stillOn = (Get-WtNoticePause $t0.AddMinutes(59)).Paused; $ended = (Get-WtNoticePause $t0.AddMinutes(61)).Paused
    $late = Set-WtNoticePause hour ([datetime]'2026-11-23 23:30:00')
    $today = Set-WtNoticePause today $t0
    $manual = Set-WtNoticePause manual $t0
    $manualLater = (Get-WtNoticePause $t0.AddDays(30)).Paused
    $back = Set-WtNoticePause off $t0
    Assert-WtTest '알람 잠시 끄기: 1시간(~ 15:30, 끝나면 저절로 켬) · 날을 넘김 · 오늘 하루(내일 0시) · 다시 켤 때까지 · 다시 켜기' (
        -not $off.Paused -and $hour.Paused -and $hour.Text -ceq '알람 꺼짐 ~ 15:30' -and $stillOn -and -not $ended -and
        $late.Text -ceq '알람 꺼짐 ~ 11월 24일 00:30' -and $today.Text -ceq '알람 꺼짐 · 오늘' -and $today.Until -eq [datetime]'2026-11-24' -and
        $manual.Text -ceq '알람 꺼짐' -and $manual.Manual -and $manualLater -and -not $back.Paused -and [string](Get-WtSetting 'notice.pausedUntil') -ceq '') (
        "$($hour.Text) / $($late.Text) / $($today.Text) / $($manual.Text)")

    # ---- 알림 소리 (가짜 재생기: 실제 소리 없음) ----
    $name = Get-WtNoticeSoundName
    $r1 = Invoke-WtNoticeSound -Now $t0
    $player = & $notice { $script:player }
    $first = @{ Result = $r1; Volume = $player.Volume; Opened = $player.Opened; Plays = $player.Plays }
    Set-WtSetting 'notice.volume' 35
    $r2 = Invoke-WtNoticeSound -Now $t0; $volume2 = $player.Volume
    $systemBefore = $global:wtNoticeProbe.System
    $r3 = Invoke-WtNoticeSound -File 'wt-test-missing.wav' -Now $t0
    $r4 = Invoke-WtNoticeSound -File '..\wt-test.wav' -Now $t0
    Set-WtSetting 'notice.sound' $false
    $r5 = Invoke-WtNoticeSound -Now $t0
    $r6 = Invoke-WtNoticeSound -Volume 80 -Force -Now $t0; $volume6 = $player.Volume
    Set-WtSetting 'notice.sound' $true
    [void](Set-WtNoticePause manual $t0); $r7 = Invoke-WtNoticeSound -Now $t0; [void](Set-WtNoticePause off $t0)
    $expectFile = if ($name) { 'file' } else { 'system' }
    Assert-WtTest '알림 소리: 파일 재생 · 볼륨 70%=0.7 · 35%=0.35 · 들어 보기 80%=0.8(소리 끔이어도) · 없는 파일 · 경로 글은 기본 소리 · 끔 · 잠시 끄기는 안 냄' (
        $first.Result -ceq $expectFile -and (-not $name -or ($first.Volume -eq 0.7 -and $first.Opened -like "*Media*$name" -and $first.Plays -eq 1)) -and
        $r2 -ceq $expectFile -and (-not $name -or $volume2 -eq 0.35) -and $r3 -ceq 'system' -and $r4 -ceq 'system' -and
        $global:wtNoticeProbe.System -eq $systemBefore + 2 -and $r5 -ceq 'off' -and $r6 -ceq $expectFile -and (-not $name -or $volume6 -eq 0.8) -and $r7 -ceq 'off') (
        "$name : $($first.Result) $($first.Volume) $($first.Opened) / $r2 $volume2 / $r3 $r4 / $r5 $r6 $volume6 $r7")
    Set-WtSetting 'notice.volume' 70

    # ---- 쌓기 자리 (작업 영역을 넣는다) ----
    $points = @(Get-WtNoticePlacement ([System.Windows.Rect]::new(0, 0, 1920, 1040)) @(149, 149, 200) 360)
    $tight = @(Get-WtNoticePlacement ([System.Windows.Rect]::new(100, 50, 800, 300)) @(149, 149) 360)
    Assert-WtTest '알림 창 자리: 작업 영역 오른쪽 · 아래 16, 위로 쌓고 사이 8, 위를 넘으면 맨 위 자리에 겹침' (
        $points[0].X -eq 1544 -and $points[0].Y -eq 875 -and $points[1].Y -eq 718 -and $points[2].Y -eq 510 -and
        $tight[0].X -eq 524 -and $tight[0].Y -eq 185 -and $tight[1].Y -eq 66) (($points + $tight) -join ' ')

    # ---- 가짜 탭: 틱 · 설정 행 등록 ----
    Register-WtAddon -Id 'test-tick' -Title '가짜 틱' -Order 900 -NewView { New-WtText '가짜' } -TickSeconds 15 `
        -Tick { param($Now) $global:wtNoticeProbe.Ticks.Add($Now) } -SettingRows { @(@{ Group = '알림'; Label = '가짜 알림 행'; Control = (New-WtText '가짜 값'); Note = '가짜 툴팁' }, @{ Group = '다른 묶음'; Label = '빠질 행'; Control = (New-WtText 'x') }) }
    Register-WtAddon -Id 'test-tick-fail' -Title '가짜 실패' -Order 901 -NewView { New-WtText '가짜' } -Tick { throw '틱 실패' } -SettingRows { throw '행 실패' }
    $ran = Invoke-WtAddonTick 'test-tick' $t0
    $failed = Invoke-WtAddonTick 'test-tick-fail' $t0
    Set-WtSetting 'addons.disabled' @('test-tick')
    $skipped = Invoke-WtAddonTick 'test-tick' $t0.AddSeconds(15)
    Set-WtSetting 'addons.disabled' @()
    Assert-WtTest '앱 틱 등록: 시각을 넘겨 부름 · 실패는 그 탭 기록에만 · 꺼진 탭은 부르지 않음' (
        $ran -and $global:wtNoticeProbe.Ticks.Count -eq 1 -and $global:wtNoticeProbe.Ticks[0] -eq $t0 -and -not $failed -and
        (Get-WtAddonTickError 'test-tick-fail') -like '*틱 실패*' -and -not $skipped -and $global:wtNoticeProbe.Ticks.Count -eq 1 -and $null -eq (Get-WtAddonTickError 'test-tick'))
    $count = Start-WtAddonTicks
    $timers = & (Get-Module Addons) { @($script:tickTimers | ForEach-Object { @{ Id = $_.Tag; Seconds = $_.Interval.TotalSeconds; On = $_.IsEnabled } }) }
    Stop-WtAddonTicks
    $cleared = & (Get-Module Addons) { $script:tickTimers.Count }
    Assert-WtTest '앱 틱 타이머: 화면과 상관없이 등록한 탭마다 하나(주기 15 · 기본 60초), 끝낼 때 모두 멈춤' (
        $count -eq 2 -and @($timers | Where-Object { $_.Id -ceq 'test-tick' -and $_.Seconds -eq 15 -and $_.On }).Count -eq 1 -and
        @($timers | Where-Object { $_.Id -ceq 'test-tick-fail' -and $_.Seconds -eq 60 }).Count -eq 1 -and $cleared -eq 0) ($timers | ConvertTo-Json -Compress)
    $rows = @(Get-WtAddonSettingRows '알림')
    Assert-WtTest '설정 행 등록: 묶음이 같은 행만 탭 순서대로 · 실패한 탭은 오류 줄 하나' (
        $rows.Count -eq 2 -and $rows[0].Label -ceq '가짜 알림 행' -and $rows[0].Note -ceq '가짜 툴팁' -and -not $rows[0].Error -and
        $rows[1].Page -ceq 'test-tick-fail' -and $rows[1].Error -like '*행 실패*') (($rows | ForEach-Object { "$($_.Label)/$($_.Error)" }) -join ', ')

    # ---- 트레이 메뉴 (보이지 않는 WinForms 메뉴 객체) ----
    $tray = New-WtTrayMenu
    $trayText = @($tray.Items | ForEach-Object { if ($_ -is [System.Windows.Forms.ToolStripSeparator]) { '-' } else { $_.Text } }) -join ' | '
    $subText = @($tray.Tag.Pause.DropDownItems | ForEach-Object Text) -join ' | '
    $trayOn = $tray.Tag.Pause.Available -and -not $tray.Tag.Resume.Available
    [void](Set-WtNoticePause hour $t0)
    Update-WtTrayMenu $tray $t0
    $trayOff = -not $tray.Tag.Pause.Available -and $tray.Tag.Resume.Available -and $tray.Tag.Resume.Text -ceq '알람 다시 켜기 (꺼짐 ~ 15:30)'
    $tray.Tag.Resume.PerformClick()
    $resumed = -not (Get-WtNoticePause $t0).Paused
    $tray.Dispose()
    Assert-WtTest '트레이 메뉴: 열기 · 알람 잠시 끄기 ›(1시간 · 오늘 하루 · 다시 켤 때까지) · 종료, 끈 동안은 「알람 다시 켜기 (꺼짐 ~ 15:30)」로 바로 켬' (
        $trayText -ceq '열기 | 알람 잠시 끄기 | 알람 다시 켜기 | - | 종료' -and $subText -ceq '1시간 | 오늘 하루 | 다시 켤 때까지' -and $trayOn -and $trayOff -and $resumed) "$trayText / $subText / $trayOn $trayOff $resumed"

    if (-not (Test-WtTestWpf)) { Write-Host 'SKIP 알림 창 화면 (Windows STA에서만)'; return }

    # ---- 알림 창 내용: 숨김 호스트에서 배치 · 좌표 경로 (창을 띄우지 않음) ----
    $root = [System.Windows.Controls.Border]::new()
    $root.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $root.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $parameters = [System.Windows.Interop.HwndSourceParameters]::new('Notice test')
    $parameters.WindowStyle = 0; $parameters.Width = 400; $parameters.Height = 240
    $hostSource = [System.Windows.Interop.HwndSource]::new($parameters); $hostSource.RootVisual = $root
    $longTitle = '분기 점검 회의 — SRV-01 · SRV-02 펌웨어 업데이트와 백업 확인까지 한 번에 보는 아주 긴 제목'
    $content = New-WtNoticeContent @{ Key = 'view'; Title = $longTitle; Refresh = { param($Data, $When) "14:00 · $([int]($Data.Start - $When).TotalMinutes)분 뒤" }; Data = @{ Start = $t0.AddMinutes(10) }; Snooze = 10 }
    Update-WtNoticeDetail $content $t0
    $content.Frame.VerticalAlignment = 'Top'
    $root.Child = $content.Frame
    $root.Measure([System.Windows.Size]::new(400, 240)); $root.Arrange([System.Windows.Rect]::new(0, 0, 400, 240)); $root.UpdateLayout()
    $parts = $content.Parts
    $headIcon = @(Get-WtTestTexts $content.Frame) -contains ([string][char]0xEA8F)
    Assert-WtTest '알림 창 내용: 폭 360 · 기본 높이 149 · 알람 아이콘 · 제목 한 줄 말줄임 + 툴팁 · 시각 줄(Refresh) · 「10분 뒤」 · 실행 취소 숨김' (
        $content.Frame.ActualWidth -eq 360 -and $content.Frame.ActualHeight -eq 149 -and $headIcon -and $parts.TitleText.Text -ceq $longTitle -and
        $parts.TitleText.ActualWidth -le 328 -and $parts.Body.ToolTip -ceq $longTitle -and $parts.DetailText.Text -ceq '14:00 · 10분 뒤' -and
        [string]$parts.Snooze.Content -ceq '10분 뒤' -and [string]$parts.Confirm.Content -ceq '확인' -and $parts.Confirm.IsDefault -and $parts.Undo.Visibility -eq 'Collapsed') (
        "$($content.Frame.ActualWidth)x$($content.Frame.ActualHeight) / $($parts.TitleText.ActualWidth) / $($parts.DetailText.Text) / $($parts.Snooze.Content)")
    $routes = foreach ($pair in @(@('본문(제목)', $parts.TitleText, $parts.Body), @('확인', $parts.Confirm, $parts.Confirm), @('다시 알림', $parts.Snooze, $parts.Snooze),
            @('더 보기', $parts.More, $parts.More), @('닫기', $parts.Close, $parts.Close))) {
        $route = Test-WtTestInputPath -View $root -Element $pair[1] -Target $pair[2]
        [pscustomobject]@{ Name = $pair[0]; Ok = $route.Ok; Path = $route.Path }
    }
    Assert-WtTest '알림 창 좌표 경로: 본문(제목 글자) → 본문 단추 · 확인 · 다시 알림 · 더 보기 · 닫기가 실제 배치 좌표에서 닿음' (-not @($routes | Where-Object { -not $_.Ok }).Count) (($routes | ForEach-Object { "$($_.Name)=$($_.Ok) $($_.Path)" }) -join ' / ')
    $source = [System.Windows.PresentationSource]::FromVisual($root)
    $esc = [System.Windows.Input.KeyEventArgs]::new([System.Windows.Input.Keyboard]::PrimaryDevice, $source, 0, [System.Windows.Input.Key]::Escape)
    $esc.RoutedEvent = [System.Windows.UIElement]::PreviewKeyDownEvent
    $content.Frame.RaiseEvent($esc)
    Assert-WtTest '알림 창 키: Esc는 닫기(확인과 같음)' ($content.Closed -and $content.Reason -ceq 'confirm' -and $esc.Handled)
    $root.Child = $null
    $default = New-WtNoticeContent @{ Key = 'default'; Title = '기본' }
    Assert-WtTest '알림 창 다시 알림 글: 탭이 간격을 주지 않으면 설정 notice.snooze(기본 5분)' ([string]$default.Parts.Snooze.Content -ceq '5분 뒤')

    # ---- 띄우기 · 쌓기 · 확인 · 다시 알림 · 본문 · 메뉴 · 알림 글 (창은 가짜로 보이기, 소리는 가짜 재생기) ----
    $shownBefore = $global:wtNoticeProbe.Shown; $playsBefore = $player.Plays
    $a = Show-WtNotice @{ Key = 'a'; Title = '첫 알람'; Detail = '14:00 · 10분 뒤'; Sound = $true } $t0
    $again = Show-WtNotice @{ Key = 'a'; Title = '첫 알람 바뀜'; Detail = '14:00 · 9분 뒤' } $t0
    $b = Show-WtNotice @{ Key = 'b'; Title = '둘째 알람'; Detail = '하루 종일'; Snooze = 15 } $t0
    # 높이는 화면 픽셀 반올림(배율)에 따라 1~2 차이가 난다(11-22 노트북 150%: 874 · 716). 위치 식은 ±2로 본다
    $near = { param($v, $want) [Math]::Abs($v - $want) -le 2 }
    $placed = (& $near $a.Place.X 1544) -and (& $near $a.Place.Y 875) -and (& $near $b.Place.Y 718) -and ($a.Place.Y - $b.Place.Y) -gt 100 -and $a.Window.Topmost -and -not $a.Window.ShowActivated -and -not $a.Window.ShowInTaskbar -and $null -eq $a.Window.Owner
    Assert-WtTest '알림 띄우기: 창 하나씩(같은 키는 글만 바꿈) · 소리는 Sound일 때만 · 맨 위 · 포커스 안 뺏음 · 작업 표시줄 없음 · 앱 창에 안 붙음 · 위로 쌓기' (
        [object]::ReferenceEquals($a, $again) -and $a.Parts.TitleText.Text -ceq '첫 알람 바뀜' -and $global:wtNoticeProbe.Shown -eq $shownBefore + 2 -and
        $player.Plays -eq $playsBefore + 1 -and @(Get-WtNotices).Count -eq 2 -and $placed) "$($a.Place) / $($b.Place) / $($global:wtNoticeProbe.Shown - $shownBefore) / $($player.Plays - $playsBefore)"
    $a.Parts.Confirm.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    Assert-WtTest '알림 확인: 닫고 남은 창은 아래로 내려옴' ($a.Closed -and $a.Reason -ceq 'confirm' -and @(Get-WtNotices).Count -eq 1 -and $b.Place.Y -eq 875) "$($b.Place)"
    Invoke-WtNoticeSnooze $b $t0
    $snoozed = @(Get-WtNoticeSnoozes)
    $shownBefore = $global:wtNoticeProbe.Shown
    Invoke-WtNoticeTick $t0.AddMinutes(14)
    $early = $global:wtNoticeProbe.Shown -eq $shownBefore
    Invoke-WtNoticeTick $t0.AddMinutes(15)
    $reshown = @(Get-WtNotices | Where-Object { $_.Key -ceq 'b' -and -not $_.Closed })
    Assert-WtTest '다시 알림: 닫고 간격(15분) 뒤 같은 내용으로 다시 띄움, 그 전 틱은 그대로' (
        $b.Closed -and $b.Reason -ceq 'snooze' -and $snoozed.Count -eq 1 -and $snoozed[0].Due -eq $t0.AddMinutes(15) -and $early -and
        $global:wtNoticeProbe.Shown -eq $shownBefore + 1 -and $reshown.Count -eq 1 -and @(Get-WtNoticeSnoozes).Count -eq 0)
    Invoke-WtNoticeSnooze $reshown[0] $t0.AddMinutes(15)
    [void](Set-WtNoticePause manual $t0)
    $shownBefore = $global:wtNoticeProbe.Shown
    Invoke-WtNoticeTick $t0.AddMinutes(31)
    $pausedShow = Show-WtNotice @{ Key = 'p'; Title = '꺼진 동안'; Detail = '지금'; Sound = $true } $t0.AddMinutes(31)
    [void](Set-WtNoticePause off $t0)
    Assert-WtTest '잠시 끄기 중: 다시 알림 · 새 알림 모두 버림(창 · 소리 없음)' (
        $global:wtNoticeProbe.Shown -eq $shownBefore -and $null -eq $pausedShow -and @(Get-WtNoticeSnoozes).Count -eq 0 -and @(Get-WtNotices).Count -eq 0)
    $c = Show-WtNotice @{ Key = 'c'; Title = '본문 시험'; Detail = '지금'; Open = @{ Id = 'test-tick'; Args = @{ Date = $t0.Date; Id = 'x1' } } } $t0
    $c.Parts.Body.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $opened = $global:wtNoticeProbe.Opened[$global:wtNoticeProbe.Opened.Count - 1]
    Assert-WtTest '알림 본문 누름: 닫고 앱 창을 앞으로 + 부른 탭 화면(Id · Args) 열기' ($c.Closed -and $c.Reason -ceq 'open' -and $opened[0] -ceq 'test-tick' -and $opened[1].Id -ceq 'x1' -and $opened[1].Date -eq $t0.Date)
    $d = Show-WtNotice @{ Key = 'd'; Title = '메뉴 시험'; Detail = '지금'; Menu = @(@{ Header = '가짜 항목'; Action = { param($Target) $global:wtNoticeProbe.MenuHit = $Target.Key } }) } $t0
    $e2 = Show-WtNotice @{ Key = 'e'; Title = '같이 닫힘'; Detail = '지금' } $t0
    $menu = New-WtNoticeMenu $d
    $menuText = @($menu.Items | ForEach-Object { if ($_ -is [System.Windows.Controls.Separator]) { '-' } else { [string]$_.Header } }) -join ' | '
    $pauseItem = $menu.Items[$menu.Items.Count - 1]
    $subText = @($pauseItem.Items | ForEach-Object { [string]$_.Header }) -join ' | '
    $menu.Items[0].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
    $pauseItem.Items[0].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.MenuItem]::ClickEvent))
    $pausedByMenu = (Get-WtNoticePause).Paused
    [void](Set-WtNoticePause off)
    Assert-WtTest '알림 더 보기: 탭 항목 · 구분선 · 알람 잠시 끄기 ›(1시간 · 오늘 하루), 잠시 끄면 떠 있는 창을 모두 닫음' (
        $menuText -ceq '가짜 항목 | - | 알람 잠시 끄기' -and $subText -ceq '1시간 | 오늘 하루' -and $global:wtNoticeProbe.MenuHit -ceq 'd' -and $pausedByMenu -and
        $d.Closed -and $e2.Closed -and $d.Reason -ceq 'pause' -and @(Get-WtNotices).Count -eq 0) "$menuText / $subText / $($global:wtNoticeProbe.MenuHit)"
    $f = Show-WtNotice @{ Key = 'f'; Title = '알림 글'; Detail = '14:00 · 10분 뒤' } $t0
    Set-WtNoticeMessage $f '이 일정 알람을 껐습니다.' -Undo { param($Target) $global:wtNoticeProbe.Undone = $Target.Key; '' }
    $messaged = $f.Parts.DetailText.Text -ceq '이 일정 알람을 껐습니다.' -and $f.Parts.Snooze.Visibility -eq 'Collapsed' -and $f.Parts.Undo.Visibility -eq 'Visible'
    Invoke-WtNoticeTick $t0.AddMinutes(1)
    $kept = $f.Parts.DetailText.Text -ceq '이 일정 알람을 껐습니다.'
    $f.Parts.Undo.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    Assert-WtTest '알림 글 · 실행 취소: 시각 줄 자리에 글, 다시 알림 숨김 · 실행 취소 보임, 틱이 글을 덮지 않음, 실행 취소 뒤 「알람을 다시 켰습니다.」' (
        $messaged -and $kept -and $global:wtNoticeProbe.Undone -ceq 'f' -and $f.Parts.DetailText.Text -ceq '알람을 다시 켰습니다.' -and $f.Parts.Undo.Visibility -eq 'Collapsed' -and -not $f.Closed)
    Clear-WtNotices

    # ---- 상태 줄의 「알람 꺼짐」 (셸 XAML을 창 없이 만든다, Test-Core 상태 줄 검사와 같은 방법) ----
    $status = & (Get-Module Shell) {
        $before = @{ Ui = $script:ui; Window = $script:window }
        try {
            $script:window = ConvertFrom-WtXaml $script:shellXaml
            $script:window.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $script:window.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
            $script:ui = Get-WtNamedElements $script:window $script:shellXaml
            Update-WtStatusBar
            $noneBefore = @($script:ui.StatusRight.Children | Where-Object { [System.Windows.Automation.AutomationProperties]::GetAutomationId($_) -ceq 'Status-core-pause' }).Count
            [void](Set-WtNoticePause manual)
            Update-WtStatusBar
            $item = @($script:ui.StatusRight.Children)[-1]
            $shown = [System.Windows.Automation.AutomationProperties]::GetAutomationId($item) -ceq 'Status-core-pause' -and $item.Content.FindName('Text').Text -ceq '알람 꺼짐' -and
                $item.Content.FindName('Icon').Text -ceq ([string][char]0xE708) -and $item.ToolTip -ceq '누르면 알람을 다시 켭니다.'
            $item.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
            $resumed = -not (Get-WtNoticePause).Paused
            Update-WtStatusBar
            $gone = @($script:ui.StatusRight.Children | Where-Object { [System.Windows.Automation.AutomationProperties]::GetAutomationId($_) -ceq 'Status-core-pause' }).Count -eq 0
            @{ Ok = $noneBefore -eq 0 -and $shown -and $resumed -and $gone; Detail = "$noneBefore $shown $resumed $gone" }
        } finally { [void](Set-WtNoticePause off); $script:ui = $before.Ui; $script:window = $before.Window }
    }
    Assert-WtTest '상태 줄: 잠시 끈 동안만 오른쪽 맨 앞에 「알람 꺼짐」(QuietHours · 툴팁), 누르면 바로 다시 켬' $status.Ok $status.Detail

    # ---- 설정 → 일반 → 알림 (창 없이 만든 설정 화면) ----
    $page = New-WtSettingsPage
    $page.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $page.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $texts = @(Get-WtTestTexts $page)
    $labels = @('알림', '가짜 알림 행', '다시 알림', '알람 소리', '소리', '볼륨', '알람 잠시 끄기')
    $missing = @($labels | Where-Object { $texts -notcontains $_ })
    $order = @($texts | Where-Object { $_ -in $labels })
    Assert-WtTest '설정 알림 묶음: 묶음 이름 → 탭 행 → 다시 알림 · 알람 소리 · 소리 · 볼륨 · 알람 잠시 끄기, 실패한 탭은 오류 줄' (
        -not $missing.Count -and ($order -join ',') -ceq ($labels -join ',') -and @($texts | Where-Object { $_ -like '가짜 실패 설정 행을 만들지 못했습니다*' }).Count -eq 1 -and $texts -notcontains '빠질 행') (
        "빠짐: $($missing -join ',') / 순서: $($order -join ',')")
    $ui = & (Get-Module Pages) { $script:noticeUi }
    $snoozeBox = Find-WtTestNamed $page '다시 알림'
    $snoozeBox.SelectedItem = '15분 뒤'
    $ui.SoundOn.IsChecked = $false; $ui.SoundOn.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    $offState = [bool](Get-WtSetting 'notice.sound') -eq $false -and -not $ui.File.IsEnabled -and -not $ui.Volume.IsEnabled -and -not $ui.Preview.IsEnabled -and $ui.Preview.ToolTip -ceq '알람 소리를 켜면 바꿀 수 있습니다.'
    $ui.SoundOn.IsChecked = $true; $ui.SoundOn.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    $other = @($ui.File.Items | Where-Object { $_ -cne $ui.File.SelectedItem }) | Select-Object -First 1
    if ($other) { $ui.File.SelectedItem = $other }
    $ui.Volume.Value = 40
    Wait-WtTestDispatcher 800
    $player.Volume = -1
    $ui.Preview.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    Assert-WtTest '설정 알림 값: 다시 알림 15분 · 소리 끄면 소리 · 볼륨 · 들어 보기 비활성 + 이유 · 소리 파일 · 볼륨 40%(손 뗀 뒤 저장) · 들어 보기는 고른 파일 · 볼륨' (
        [int](Get-WtSetting 'notice.snooze') -eq 15 -and $offState -and [bool](Get-WtSetting 'notice.sound') -and $ui.File.IsEnabled -and
        (-not $other -or [string](Get-WtSetting 'notice.soundFile') -ceq "$other.wav") -and [int](Get-WtSetting 'notice.volume') -eq 40 -and $ui.VolumeText.Text -ceq '40%' -and
        (-not $other -or ($player.Volume -eq 0.4 -and $player.Opened -like "*$other.wav"))) "$(Get-WtSetting 'notice.snooze') / $offState / $(Get-WtSetting 'notice.soundFile') / $(Get-WtSetting 'notice.volume') / $($player.Volume) $($player.Opened)"
    $hourButton = @($ui.Pause.Children)[0]
    $hourButton.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $pausedRow = @($ui.Pause.Children | ForEach-Object { if ($_ -is [System.Windows.Controls.TextBlock]) { $_.Text } else { [string]$_.Content } })
    @($ui.Pause.Children)[1].RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
    $resumedRow = @($ui.Pause.Children | ForEach-Object { [string]$_.Content }) -join ' | '
    Assert-WtTest '설정 알람 잠시 끄기: 1시간 · 오늘 하루 · 다시 켤 때까지 → 끈 동안 「알람 꺼짐 ~ HH:mm」 + 다시 켜기 → 다시 세 단추' (
        $pausedRow.Count -eq 2 -and $pausedRow[0] -like '알람 꺼짐 ~ *' -and $pausedRow[1] -ceq '다시 켜기' -and -not (Get-WtNoticePause).Paused -and
        $resumedRow -ceq '1시간 | 오늘 하루 | 다시 켤 때까지') "$($pausedRow -join ' | ') / $resumedRow"
    Write-Host '알림 부품 검사 PASS · FAIL 0'
} finally {
    try { Clear-WtNotices } catch { }
    try { [void](Set-WtNoticePause off) } catch { }
    & $notice { param($saved) $script:showWindow = $saved.Show; $script:workArea = $saved.Area; $script:newPlayer = $saved.Player; $script:systemSound = $saved.System
        $script:openPage = $saved.Open; $script:useTimer = $saved.Timer; $script:player = $null } $seams
    & (Get-Module Addons) { param($items) $script:addons.Clear(); foreach ($item in $items) { $script:addons.Add($item) } } $addonsBefore
    if ($hostSource) { $hostSource.Dispose() }
    Remove-Variable wtNoticeProbe -Scope Global -ErrorAction SilentlyContinue
    Stop-WtDataWrites -Milliseconds 3000; Stop-WtAllWork; Remove-WtTestData $test
}

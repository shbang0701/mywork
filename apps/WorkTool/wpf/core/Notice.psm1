# 알림 창 · 알림 소리 · 알람 잠시 끄기 (디자인 3판 7절 「알람 창」 · 8절 「설정·도움말」의 알림 묶음, 일정 설계 16장).
# 탭이 부르는 공용 부품이다. 코어는 탭 이름을 모르고, 부른 탭이 준 글 · 열 화면 · 메뉴 항목만 쓴다.
# 알림 창은 앱 창에 붙이지 않는다(Owner 없음). 그래서 앱 창이 트레이로 숨거나 최소화돼도 뜨고, 맨 위에 있되 포커스는 가져가지 않는다.
# 이벤트 처리기는 $script: 변수와 보낸 요소의 Tag만 쓴다(Shell.psm1 머리말).
# 검사가 바꿔 끼우는 곳은 OS에 닿는 곳뿐이다: 창 보이기 · 작업 영역 · 소리 재생기 · Windows 기본 소리 · 앱 창 열기. 15초 타이머는 검사에서 끈다.

$ErrorActionPreference = 'Stop'

$script:notices = [System.Collections.Generic.List[object]]::new()   # 떠 있는 알림(아래에서 위 순서)
$script:snoozed = [System.Collections.Generic.List[object]]::new()   # 다시 알림 @{ Due; Spec }
$script:noticeTimer = $null
$script:player = $null
$script:inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:ko = [System.Globalization.CultureInfo]::GetCultureInfo('ko-KR')
$script:noticeWidth = 360
$script:noticeEdge = 16   # 작업 영역 오른쪽 · 아래와 띄움
$script:noticeGap = 8     # 쌓을 때 창 사이

$script:showWindow = { param($Window) $Window.Show() }
$script:workArea = { [System.Windows.SystemParameters]::WorkArea }
$script:newPlayer = { [System.Windows.Media.MediaPlayer]::new() }
$script:systemSound = { [System.Media.SystemSounds]::Exclamation.Play() }
$script:openPage = { param($Id, $OpenArgs) if (Get-WtWindow) { Show-WtMainWindow }; Open-WtPage -Id $Id -Args $OpenArgs }
$script:useTimer = $true

# ---- 알람 잠시 끄기 ---------------------------------------------------------------------------
# 설정 notice.pausedUntil: '' 켬 · 'manual' 다시 켤 때까지 · 앱 시각(그때까지). 끈 동안 울릴 알림은 버린다(켤 때 몰아서 울리지 않게)

function Get-WtNoticePause([datetime]$Now = (Get-Date)) {
    $value = [string](Get-WtSetting 'notice.pausedUntil')
    $off = [pscustomobject]@{ Paused = $false; Until = $null; Manual = $false; Text = '' }
    if (-not $value) { return $off }
    if ($value -ceq 'manual') { return [pscustomobject]@{ Paused = $true; Until = $null; Manual = $true; Text = '알람 꺼짐' } }
    $stamp = ConvertFrom-WtStamp $value
    if (-not $stamp -or $stamp.DateTime -le $Now) { return $off }
    $until = $stamp.DateTime
    $text = if ($until -eq $Now.Date.AddDays(1)) { '알람 꺼짐 · 오늘' }
        elseif ($until.Date -eq $Now.Date) { '알람 꺼짐 ~ ' + $until.ToString('HH:mm', $script:inv) }
        else { '알람 꺼짐 ~ ' + $until.ToString('M월 d일 HH:mm', $script:ko) }
    [pscustomobject]@{ Paused = $true; Until = $until; Manual = $false; Text = $text }
}

# hour = 1시간 · today = 오늘 하루(내일 0시까지) · manual = 다시 켤 때까지 · off = 다시 켜기. 끄면 떠 있는 알림 창을 모두 닫는다
function Set-WtNoticePause([ValidateSet('hour', 'today', 'manual', 'off')][string]$Mode, [datetime]$Now = (Get-Date)) {
    $value = switch ($Mode) {
        'hour' { Get-WtStamp $Now.AddHours(1) }
        'today' { Get-WtStamp $Now.Date.AddDays(1) }
        'manual' { 'manual' }
        default { '' }
    }
    Set-WtSetting 'notice.pausedUntil' $value
    if ($Mode -ne 'off') { Close-WtNotices 'pause' }
    Get-WtNoticePause $Now
}

# ---- 알림 소리 --------------------------------------------------------------------------------
# Windows에 들어 있는 소리 파일만 쓴다(C:\Windows\Media). 로컬 시스템 폴더라 화면 스레드에서 읽는다

function Get-WtNoticeSoundFolder { Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'Media' }

function Get-WtNoticeSounds {
    $folder = Get-WtNoticeSoundFolder
    if (-not [System.IO.Directory]::Exists($folder)) { return @() }
    @([System.IO.Directory]::GetFiles($folder, '*.wav') | ForEach-Object { [System.IO.Path]::GetFileName($_) } | Sort-Object -Culture 'ko-KR')
}

# 지금 쓸 소리 파일 이름: 설정 값, 비면 알림다운 기본 후보(Windows Notify Calendar → Alarm01 → 첫 파일)
function Get-WtNoticeSoundName {
    $name = [string](Get-WtSetting 'notice.soundFile')
    if ($name) { return $name }
    $list = @(Get-WtNoticeSounds)
    foreach ($candidate in 'Windows Notify Calendar.wav', 'Alarm01.wav') { if ($list -contains $candidate) { return $candidate } }
    if ($list.Count) { $list[0] } else { '' }
}

<#
알림 소리를 낸다. -File(파일 이름) · -Volume(0~100)을 주지 않으면 설정을 쓴다. -Force는 설정의 「들어 보기」(소리 끔 · 잠시 끄기와 상관없음).
MediaPlayer는 볼륨을 정할 수 있다. 파일이 없거나 재생하지 못하면 Windows 기본 경고음(볼륨 못 바꿈)으로 대신한다.
돌려주는 값: 'file'(파일 재생) · 'system'(기본 경고음) · 'off'(내지 않음)
#>
function Invoke-WtNoticeSound([string]$File, $Volume, [switch]$Force, [datetime]$Now = (Get-Date)) {
    if (-not $Force -and (-not [bool](Get-WtSetting 'notice.sound') -or (Get-WtNoticePause $Now).Paused)) { return 'off' }
    if (-not $File) { $File = Get-WtNoticeSoundName }
    $level = if ($null -ne $Volume) { [double]$Volume } else { [double](Get-WtSetting 'notice.volume') }
    $level = [Math]::Max(0, [Math]::Min(100, $level))
    # 파일 이름만 받는다(경로 구분자가 든 값은 쓰지 않음)
    $path = if ($File -and $File.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -lt 0) { Join-Path (Get-WtNoticeSoundFolder) $File } else { '' }
    if (-not $path -or -not [System.IO.File]::Exists($path)) { & $script:systemSound; return 'system' }
    try {
        if (-not $script:player) {
            $script:player = & $script:newPlayer
            # 형식 이름은 글자로 본다(WPF 어셈블리를 아직 안 불렀어도 예외 없이)
            if ($script:player.GetType().FullName -ceq 'System.Windows.Media.MediaPlayer') { $script:player.add_MediaFailed({ & $script:systemSound }) }
        }
        $script:player.Stop()
        $script:player.Open([uri]::new($path))
        $script:player.Volume = $level / 100
        $script:player.Play()
        'file'
    } catch { & $script:systemSound; 'system' }
}

# ---- 알림 창 ----------------------------------------------------------------------------------

function Get-WtNoticeXaml {
@'
<Border {NS} x:Name="Frame" Style="{DynamicResource Notice.Frame}" Width="360">
  <StackPanel>
    <DockPanel Style="{DynamicResource Notice.Head}">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center">
        <Button x:Name="More" Style="{DynamicResource Btn.Icon}" ToolTip="더 보기" AutomationProperties.Name="더 보기"><TextBlock Text="&#xE712;" Style="{DynamicResource T.Icon}"/></Button>
        <Button x:Name="Close" Style="{DynamicResource Notice.HeadButton}" ToolTip="닫기 (Esc)" AutomationProperties.Name="닫기"><TextBlock Text="&#xE711;" Style="{DynamicResource T.Icon}"/></Button>
      </StackPanel>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="&#xEA8F;" Style="{DynamicResource Notice.HeadIcon}"/>
        <TextBlock Text="알람" Style="{DynamicResource Notice.HeadText}"/>
      </StackPanel>
    </DockPanel>
    <Button x:Name="Body" Style="{DynamicResource Notice.Body}">
      <StackPanel>
        <TextBlock x:Name="TitleText" Style="{DynamicResource Notice.Title}"/>
        <TextBlock x:Name="DetailText" Style="{DynamicResource Notice.Detail}"/>
      </StackPanel>
    </Button>
    <StackPanel Style="{DynamicResource Notice.Buttons}">
      <Button x:Name="Confirm" Style="{DynamicResource Btn.Primary}" Content="확인" IsDefault="True" AutomationProperties.Name="확인"/>
      <Button x:Name="Snooze" Style="{DynamicResource Notice.Button}"/>
      <Button x:Name="Undo" Style="{DynamicResource Notice.Button}" Content="실행 취소" Visibility="Collapsed" AutomationProperties.Name="실행 취소"/>
    </StackPanel>
  </StackPanel>
</Border>
'@
}

function Get-WtNoticeWindowXaml {
@'
<Window {NS} Title="WorkTool 알람" WindowStyle="None" ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True" ShowActivated="False"
    SizeToContent="WidthAndHeight" WindowStartupLocation="Manual" UseLayoutRounding="True" SnapsToDevicePixels="True" TextOptions.TextFormattingMode="Ideal"
    FontFamily="{DynamicResource Font.UI}" FontSize="{DynamicResource F.Body}" Foreground="{DynamicResource B.Text.Primary}" Background="{DynamicResource B.Bg.Raised}"/>
'@
}

function Get-WtNoticeSnoozeMinutes($Spec) {
    $minutes = 0
    if ($Spec -and $null -ne $Spec.Snooze) { $minutes = [int]$Spec.Snooze }
    if ($minutes -le 0) { $minutes = [int](Get-WtSetting 'notice.snooze') }
    if ($minutes -le 0) { $minutes = 5 }
    $minutes
}

<#
알림 창 하나의 내용(창 없이). 검사는 이것을 숨김 호스트에 붙여 배치 · 입력 경로를 본다. Spec(해시 테이블):
  Key      같은 키의 창이 떠 있으면 새로 띄우지 않고 글만 바꾼다
  Title    제목(한 줄, 넘치면 말줄임 · 툴팁에 전체)
  Detail   시각 줄 글. Refresh { param($Data, [datetime]$Now) } → 글 을 주면 띄울 때와 15초마다 다시 쓴다
  Data     Refresh · Menu 처리기가 쓰는 값
  Open     @{ Id = 탭 id; Args = @{} }: 본문을 누르면 앱 창을 앞으로 가져와 Open-WtPage. 없으면 닫기만 한다
  Snooze   다시 알림 간격(분). 없거나 0이면 설정 notice.snooze
  Sound    $true면 뜰 때 소리(설정 notice.sound를 부른 탭이 반영한 값)
  Menu     더 보기 메뉴 앞쪽 항목 @(@{ Header = '글'; Action = { param($Notice) } }). 뒤에 구분선 · 알람 잠시 끄기 ›를 붙인다
돌려주는 값(알림 기록): @{ Key; Spec; Frame; Parts; Window; Closed; Reason; Message; Undo; Place }
#>
function New-WtNoticeContent([hashtable]$Spec) {
    $xaml = Get-WtNoticeXaml
    $frame = ConvertFrom-WtXaml $xaml
    $parts = Get-WtNamedElements $frame $xaml
    $record = @{ Key = [string]$Spec.Key; Spec = $Spec; Frame = $frame; Parts = $parts; Window = $null
        Closed = $false; Reason = ''; Message = ''; Undo = $null; Place = $null }
    $parts.TitleText.Text = [string]$Spec.Title
    $parts.Body.ToolTip = [string]$Spec.Title
    [System.Windows.Automation.AutomationProperties]::SetName($parts.Body, [string]$Spec.Title)
    $parts.Snooze.Content = '{0}분 뒤' -f (Get-WtNoticeSnoozeMinutes $Spec)
    [System.Windows.Automation.AutomationProperties]::SetName($parts.Snooze, [string]$parts.Snooze.Content)
    foreach ($name in 'More', 'Close', 'Body', 'Confirm', 'Snooze', 'Undo') { $parts[$name].Tag = $record }
    $parts.More.Add_Click({ param($s, $e) [void](Open-WtNoticeMenu $s.Tag) })
    $parts.Close.Add_Click({ param($s, $e) Close-WtNotice $s.Tag 'confirm' })
    $parts.Confirm.Add_Click({ param($s, $e) Close-WtNotice $s.Tag 'confirm' })
    $parts.Snooze.Add_Click({ param($s, $e) Invoke-WtNoticeSnooze $s.Tag })
    $parts.Undo.Add_Click({ param($s, $e) Invoke-WtNoticeUndo $s.Tag })
    $parts.Body.Add_Click({ param($s, $e) Open-WtNoticeTarget $s.Tag })
    $frame.Tag = $record
    $frame.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq [System.Windows.Input.Key]::Escape) { $e.Handled = $true; Close-WtNotice $s.Tag 'confirm' }
        })
    $record
}

function Update-WtNoticeDetail($Notice, [datetime]$Now = (Get-Date)) {
    if (-not $Notice -or $Notice.Closed -or $Notice.Message) { return }
    $text = [string]$Notice.Spec.Detail
    if ($Notice.Spec.Refresh -is [scriptblock]) {
        try { $text = [string](& $Notice.Spec.Refresh $Notice.Spec.Data $Now) } catch { }
    }
    $Notice.Parts.DetailText.Text = $text
}

function New-WtNoticeWindow($Notice) {
    $w = ConvertFrom-WtXaml (Get-WtNoticeWindowXaml)
    $w.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
    $w.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
    $w.Content = $Notice.Frame
    $w.Tag = $Notice
    # 창을 다른 길로 닫아도(작업 끝내기 등) 목록에서 빼고 남은 창을 내린다
    $w.Add_Closed({ param($s, $e) if (-not $s.Tag.Closed) { Close-WtNotice $s.Tag 'closed' } })
    $Notice.Window = $w
    $w
}

# 쌓기 자리: 아래(0번)부터 위로. 창 높이 목록 → 왼쪽 위 점 목록. 작업 영역 위를 넘으면 맨 위 자리에 겹친다
function Get-WtNoticePlacement([System.Windows.Rect]$WorkArea, [double[]]$Heights, [double]$Width = 360) {
    $left = $WorkArea.Right - $script:noticeEdge - $Width
    $bottom = $WorkArea.Bottom - $script:noticeEdge
    $topLimit = $WorkArea.Top + $script:noticeEdge
    foreach ($h in @($Heights)) {
        $top = [Math]::Max($topLimit, $bottom - $h)
        [System.Windows.Point]::new($left, $top)
        $bottom = $top - $script:noticeGap
    }
}

function Get-WtNoticeHeight($Notice) {
    if ($Notice.Window -and $Notice.Window.ActualHeight -gt 0) { return [double]$Notice.Window.ActualHeight }
    $Notice.Frame.Measure([System.Windows.Size]::new($script:noticeWidth, [double]::PositiveInfinity))
    [Math]::Ceiling($Notice.Frame.DesiredSize.Height)
}

function Update-WtNoticeLayout {
    $open = @($script:notices | Where-Object { -not $_.Closed })
    if (-not $open.Count) { return }
    $heights = [double[]]@($open | ForEach-Object { Get-WtNoticeHeight $_ })
    $points = @(Get-WtNoticePlacement (& $script:workArea) $heights $script:noticeWidth)
    for ($i = 0; $i -lt $open.Count; $i++) {
        $open[$i].Place = $points[$i]
        if ($open[$i].Window) { $open[$i].Window.Left = $points[$i].X; $open[$i].Window.Top = $points[$i].Y }
    }
}

# 알림 창을 띄운다. 알람을 잠시 끈 동안이면 띄우지 않고 $null(부른 탭은 그 알림을 받아들인 것으로 본다)
function Show-WtNotice([hashtable]$Spec, [datetime]$Now = (Get-Date)) {
    if ((Get-WtNoticePause $Now).Paused) { return $null }
    if ($Spec.Key) {
        foreach ($open in @($script:notices)) {
            if ($open.Closed -or $open.Key -cne [string]$Spec.Key) { continue }
            $open.Spec = $Spec; $open.Parts.TitleText.Text = [string]$Spec.Title; Update-WtNoticeDetail $open $Now
            return $open
        }
    }
    $record = New-WtNoticeContent $Spec
    Update-WtNoticeDetail $record $Now
    [void](New-WtNoticeWindow $record)
    $script:notices.Add($record)
    Update-WtNoticeLayout
    & $script:showWindow $record.Window
    Update-WtNoticeLayout
    if ($Spec.Sound) { [void](Invoke-WtNoticeSound -Now $Now) }
    Start-WtNoticeTimer
    $record
}

function Get-WtNotices { @($script:notices) }
function Get-WtNoticeSnoozes { @($script:snoozed) }

function Close-WtNotice($Notice, [string]$Reason = 'confirm') {
    if (-not $Notice -or $Notice.Closed) { return }
    $Notice.Closed = $true; $Notice.Reason = $Reason
    [void]$script:notices.Remove($Notice)
    if ($Notice.Window) { try { $Notice.Window.Close() } catch { } }
    Update-WtNoticeLayout
    if (-not $script:notices.Count -and -not $script:snoozed.Count) { Stop-WtNoticeTimer }
}

function Close-WtNotices([string]$Reason = 'confirm') { foreach ($n in @($script:notices)) { Close-WtNotice $n $Reason } }

# 끝낼 때: 떠 있는 창을 닫고 다시 알림도 버린다
function Clear-WtNotices { Close-WtNotices 'exit'; $script:snoozed.Clear(); Stop-WtNoticeTimer }

# 「5분 뒤」: 창을 닫고 다시 알림 간격 뒤에 같은 내용으로 다시 띄운다(앱을 끄면 사라짐)
function Invoke-WtNoticeSnooze($Notice, [datetime]$Now = (Get-Date)) {
    if (-not $Notice -or $Notice.Closed) { return }
    $minutes = Get-WtNoticeSnoozeMinutes $Notice.Spec
    Close-WtNotice $Notice 'snooze'
    $script:snoozed.Add(@{ Due = $Now.AddMinutes($minutes); Spec = $Notice.Spec })
    Start-WtNoticeTimer
}

# 15초마다: 다시 알림 시각이 된 것을 다시 띄우고(잠시 끈 동안이면 버림), 떠 있는 창의 시각 줄을 다시 쓴다
function Invoke-WtNoticeTick([datetime]$Now = (Get-Date)) {
    $paused = (Get-WtNoticePause $Now).Paused
    foreach ($waiting in @($script:snoozed)) {
        if ($waiting.Due -gt $Now) { continue }
        [void]$script:snoozed.Remove($waiting)
        if (-not $paused) { [void](Show-WtNotice $waiting.Spec $Now) }
    }
    foreach ($n in @($script:notices)) { Update-WtNoticeDetail $n $Now }
    if (-not $script:notices.Count -and -not $script:snoozed.Count) { Stop-WtNoticeTimer }
}

function Start-WtNoticeTimer {
    if (-not $script:useTimer) { return }
    if (-not $script:noticeTimer) {
        $script:noticeTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:noticeTimer.Interval = [TimeSpan]::FromSeconds(15)
        $script:noticeTimer.Add_Tick({ try { Invoke-WtNoticeTick } catch { } })
    }
    if (-not $script:noticeTimer.IsEnabled) { $script:noticeTimer.Start() }
}
function Stop-WtNoticeTimer { if ($script:noticeTimer) { $script:noticeTimer.Stop() } }

# 더 보기 메뉴: 부른 탭의 항목 · 구분선 · 알람 잠시 끄기 ›(1시간 · 오늘 하루)
function New-WtNoticeMenu($Notice) {
    $menu = New-WtHomePinContextMenu
    foreach ($entry in @($Notice.Spec.Menu)) {
        if (-not $entry -or -not $entry.Header -or $entry.Action -isnot [scriptblock]) { continue }
        $item = [System.Windows.Controls.MenuItem]::new()
        $item.Header = [string]$entry.Header
        $item.Tag = @{ Notice = $Notice; Action = $entry.Action }
        $item.Add_Click({ param($s, $e) if (-not $s.Tag.Notice.Closed) { & $s.Tag.Action $s.Tag.Notice } })
        [void]$menu.Items.Add($item)
    }
    if ($menu.Items.Count) { [void]$menu.Items.Add([System.Windows.Controls.Separator]::new()) }
    $pause = [System.Windows.Controls.MenuItem]::new()
    $pause.Header = '알람 잠시 끄기'
    Set-WtStyle $pause 'Home.PinSubmenuItem'
    foreach ($mode in @(@('hour', '1시간'), @('today', '오늘 하루'))) {
        $sub = [System.Windows.Controls.MenuItem]::new()
        $sub.Header = $mode[1]; $sub.Tag = $mode[0]
        $sub.Add_Click({ param($s, $e) [void](Set-WtNoticePause ([string]$s.Tag)) })
        [void]$pause.Items.Add($sub)
    }
    [void]$menu.Items.Add($pause)
    $menu
}

function Open-WtNoticeMenu($Notice) {
    if (-not $Notice -or $Notice.Closed) { return }
    $menu = New-WtNoticeMenu $Notice
    $menu.PlacementTarget = $Notice.Parts.More
    $menu.Placement = 'Bottom'
    $Notice.Parts.More.ContextMenu = $menu
    $menu.IsOpen = $true
    $menu
}

# 부른 탭의 메뉴 처리기가 일을 마친 뒤 부른다: 시각 줄 자리에 알림 글, 단추는 확인 · 실행 취소(-Undo를 주면)
function Set-WtNoticeMessage($Notice, [string]$Text, [scriptblock]$Undo) {
    if (-not $Notice -or $Notice.Closed) { return }
    $Notice.Message = $Text; $Notice.Undo = $Undo
    $Notice.Parts.DetailText.Text = $Text
    $Notice.Parts.Snooze.Visibility = 'Collapsed'
    $Notice.Parts.Undo.Visibility = if ($Undo) { 'Visible' } else { 'Collapsed' }
}

# 실행 취소: 처리기 { param($Notice) } → 알릴 글(비우면 「알람을 다시 켰습니다.」)
function Invoke-WtNoticeUndo($Notice) {
    if (-not $Notice -or $Notice.Closed -or $Notice.Undo -isnot [scriptblock]) { return }
    $handler = $Notice.Undo
    $text = ''
    try { $text = [string](& $handler $Notice) } catch { $text = $_.Exception.Message }
    Set-WtNoticeMessage $Notice $(if ($text) { $text } else { '알람을 다시 켰습니다.' }) $null
}

# 본문을 누름: 창을 닫고 앱 창을 앞으로 가져와 부른 탭의 화면을 연다
function Open-WtNoticeTarget($Notice) {
    if (-not $Notice -or $Notice.Closed) { return }
    $target = $Notice.Spec.Open
    Close-WtNotice $Notice 'open'
    if ($target -and $target.Id) {
        $pageArgs = if ($target.Args -is [hashtable]) { $target.Args } else { @{} }
        & $script:openPage ([string]$target.Id) $pageArgs
    }
}

Export-ModuleMember -Function Get-WtNoticePause, Set-WtNoticePause, Get-WtNoticeSoundFolder, Get-WtNoticeSounds, Get-WtNoticeSoundName, Invoke-WtNoticeSound,
    Get-WtNoticeSnoozeMinutes, New-WtNoticeContent, Update-WtNoticeDetail, Get-WtNoticePlacement, Update-WtNoticeLayout, Show-WtNotice, Get-WtNotices,
    Get-WtNoticeSnoozes, Close-WtNotice, Close-WtNotices, Clear-WtNotices, Invoke-WtNoticeSnooze, Invoke-WtNoticeTick, New-WtNoticeMenu, Open-WtNoticeMenu,
    Set-WtNoticeMessage, Invoke-WtNoticeUndo, Open-WtNoticeTarget

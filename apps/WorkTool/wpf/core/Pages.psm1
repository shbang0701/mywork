# 셸에 붙은 기본 화면: 설정, 도움말. 메뉴 아래 톱니바퀴 · 물음표 버튼으로 연다.
# 이벤트 처리기는 $script: 변수와 보낸 요소의 Tag만 쓴다 (Shell.psm1 머리말 참고).

$ErrorActionPreference = 'Stop'

$script:addonChecks = @()
$script:opacityLabel = $null
$script:opacityTimer = $null
$script:pendingOpacity = 100
$script:opacityNote = $null

# ---- 설정 -------------------------------------------------------------------------------------

# 100%는 글자를 또렷하게 그리는 보통 창, 그 아래는 투명 창이다. 둘 사이를 오가면 다시 시작해야 적용된다
function Update-WtOpacityNote([double]$Percent) {
    $note = if (-not (Test-WtOpacityNeedsRestart $Percent)) { '' } elseif ($Percent -lt 100) { 'WorkTool을 다시 시작하면 적용됩니다.' } else { '다시 시작하면 글자가 더 또렷해집니다.' }
    $script:opacityNote.Text = $note
    $script:opacityNote.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
}

function New-WtSettingRow([string]$Label, $Control, [string]$Note) {
    $row = [System.Windows.Controls.DockPanel]::new()
    $row.Margin = [System.Windows.Thickness]::new(0, 6, 0, 6)
    $left = New-WtStack Vertical 2
    $left.Width = 180
    $left.VerticalAlignment = 'Center'
    [void](Add-WtChild $left (New-WtText $Label 'T.Strong'))
    if ($Note) { [void](Add-WtChild $left (New-WtText $Note 'T.Sub')) }
    [System.Windows.Controls.DockPanel]::SetDock($left, 'Left')
    [void]$row.Children.Add($left)
    $Control.VerticalAlignment = 'Center'
    $Control.HorizontalAlignment = 'Left'
    [void]$row.Children.Add($Control)
    $row
}

function New-WtThemeCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 4
    [void](Add-WtChild $col (New-WtCardHeader '화면'))

    # 강조색: 이름과 견본. 색·모양은 공통 자원만 참조한다.
    $swatches = New-WtStack Horizontal
    $current = [string](Get-WtSetting 'theme.accent')
    $palettes = Get-WtPalette
    if (-not $palettes.Contains($current)) { $current = 'blue' }
    foreach ($key in $palettes.Keys) {
        $p = $palettes[$key]
        $rb = [System.Windows.Controls.RadioButton]::new()
        Set-WtStyle $rb 'Swatch'
        $rb.GroupName = 'WtTheme'
        $rb.Tag = $key
        $rb.Content = $p.Label
        $rb.ToolTip = $p.Label
        Set-WtResource $rb 'Background' ("B.Accent." + (Get-Culture).TextInfo.ToTitleCase($key))
        $rb.IsChecked = ($key -eq $current)
        $rb.Add_Checked({
            param($s, $e)
            Set-WtSetting 'theme.accent' ([string]$s.Tag)
            # 셸 파일은 건드리지 않고 기존 아이콘 그리기만 같은 선택색으로 다시 부른다.
            if (Get-WtWindow) { & (Get-Module Shell) { Update-WtAppIcon } }
        })
        [void]$swatches.Children.Add($rb)
    }
    [void](Add-WtChild $col (New-WtSettingRow '강조색' $swatches))

    # 창 투명도: 끌면 바로 보이고, 손을 떼고 잠시 뒤 저장한다
    $op = New-WtStack Horizontal 12
    $slider = [System.Windows.Controls.Slider]::new()
    Set-WtStyle $slider 'Range'
    [System.Windows.Automation.AutomationProperties]::SetName($slider, '창 투명도')
    $slider.Minimum = 60
    $slider.Maximum = 100
    $slider.TickFrequency = 5
    $slider.IsSnapToTickEnabled = $true
    $slider.Width = 240
    $slider.Value = [double](Get-WtSetting 'ui.opacity')
    $slider.VerticalAlignment = 'Center'
    $script:opacityLabel = New-WtText ('{0}%' -f [int]$slider.Value) 'T.Strong'
    $script:opacityLabel.VerticalAlignment = 'Center'
    if (-not $script:opacityTimer) {
        $script:opacityTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:opacityTimer.Interval = [TimeSpan]::FromMilliseconds(500)
        $script:opacityTimer.Add_Tick({
                param($s, $e)
                $s.Stop()
                Set-WtSetting 'ui.opacity' ([int]$script:pendingOpacity)
            })
    }
    $slider.Add_ValueChanged({
            param($s, $e)
            $script:pendingOpacity = [int]$e.NewValue
            $script:opacityLabel.Text = '{0}%' -f $script:pendingOpacity
            Set-WtOpacity $script:pendingOpacity
            Update-WtOpacityNote $script:pendingOpacity
            $script:opacityTimer.Stop()
            $script:opacityTimer.Start()
        })
    [void](Add-WtChild $op $slider)
    [void](Add-WtChild $op $script:opacityLabel)
    $opCol = New-WtStack Vertical 4
    [void](Add-WtChild $opCol $op)
    $script:opacityNote = New-WtText '' 'T.Sub'
    [void](Add-WtChild $opCol $script:opacityNote)
    Update-WtOpacityNote $slider.Value
    [void](Add-WtChild $col (New-WtSettingRow '창 투명도' $opCol '60% ~ 100%'))

    # 글자 크기
    $seg = New-WtSegmented @(@('s', '작게'), @('m', '보통'), @('l', '크게')) ([string](Get-WtSetting 'ui.fontScale')) 'WtFont' {
        param($value) Set-WtSetting 'ui.fontScale' $value
    }
    [void](Add-WtChild $col (New-WtSettingRow '글자 크기' $seg))

    # 닫기 버튼(X)
    $close = New-WtSegmented @(@('exit', '끝내기'), @('tray', '트레이로 숨기기')) $(if (Get-WtSetting 'window.closeToTray') { 'tray' } else { 'exit' }) 'WtClose' {
        param($value) Set-WtSetting 'window.closeToTray' ($value -eq 'tray')
    }
    [void](Add-WtChild $col (New-WtSettingRow '닫기 버튼 (X)' $close '숨기면 트레이 아이콘 우클릭 → 종료로 끕니다'))

    $card.Child = $col
    $card
}

function New-WtMenuCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 4
    [void](Add-WtChild $col (New-WtCardHeader '메뉴'))
    [void](Add-WtChild $col (New-WtText '끄면 메뉴에서만 사라지고 데이터는 그대로입니다.' 'T.Sub'))
    $disabled = @(Get-WtSetting 'addons.disabled')
    $script:addonChecks = @()
    foreach ($a in @(Get-WtAddon -All)) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        Set-WtStyle $cb 'Check'
        $cb.Content = if ($a.Description) { "$($a.Title) — $($a.Description)" } else { $a.Title }
        $cb.Tag = $a.Id
        $cb.IsChecked = $a.Required -or ($disabled -notcontains $a.Id)
        $cb.IsEnabled = -not $a.Required
        $cb.Add_Click({
                $off = @($script:addonChecks | Where-Object { $_.IsEnabled -and -not $_.IsChecked } | ForEach-Object { [string]$_.Tag })
                Set-WtSetting 'addons.disabled' $off
            })
        $script:addonChecks += $cb
        [void](Add-WtChild $col $cb)
    }
    $card.Child = $col
    $card
}

function New-WtDataCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 6
    [void](Add-WtChild $col (New-WtCardHeader '데이터'))

    $root = Get-WtDataRoot
    $path = New-WtText $root 'T.Body'
    Set-WtResource $path 'FontFamily' 'Font.Mono'
    $open = New-WtButton '폴더 열기' -Icon 0xE8B7
    $open.Tag = $root
    $open.Add_Click({ param($s, $e) Open-WtPath ([string]$s.Tag) })
    $box = New-WtStack Vertical 6
    [void](Add-WtChild $box $path)
    [void](Add-WtChild $box $open)
    [void](Add-WtChild $col (New-WtSettingRow '저장 위치' $box '바꾸려면 앱 폴더에 datapath.txt를 만들고 첫 줄에 경로를 적습니다'))

    $legacy = Find-WtLegacyFolder
    $lbox = New-WtStack Vertical 6
    $ltext = New-WtText $(if ($legacy) { $legacy } else { '찾지 못함' }) 'T.Body'
    Set-WtResource $ltext 'FontFamily' 'Font.Mono'
    [void](Add-WtChild $lbox $ltext)
    $btns = New-WtStack Horizontal 8
    $pick = New-WtButton '위치 고르기'
    $pick.Add_Click({
            $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
            $dlg.Description = '예전 WorkTool의 data 폴더를 고르세요 (memo.csv · schedule.csv · attendance.csv가 있는 폴더)'
            if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                Set-WtSetting 'legacy.path' $dlg.SelectedPath
                Select-WtPage '_settings'
            }
        })
    $again = New-WtButton '다시 가져오기' -Kind Primary
    $again.IsEnabled = [bool]$legacy
    $again.Add_Click({
            $tabs = @(Get-WtAddon -All | Where-Object { $_.ImportLegacy } | ForEach-Object { $_.Title }) -join ' · '
            if (-not (Confirm-WtYesNo "예전 WorkTool 데이터로 새 버전의 데이터($tabs)를 다시 채웁니다.`n새 버전에서 쓰거나 고친 내용은 사라집니다 (지금 파일은 .bak으로 하나 남음). 계속할까요?")) { return }
            try {
                $r = Import-WtLegacyData -Force
                Reset-WtViews
                Show-WtMessage ("가져왔습니다: {0}" -f ($r.Tabs -join ', '))
            } catch { Show-WtError $_ '다시 가져오기' }
        })
    [void](Add-WtChild $btns $pick)
    [void](Add-WtChild $btns $again)
    [void](Add-WtChild $lbox $btns)
    [void](Add-WtChild $col (New-WtSettingRow '예전 WorkTool 데이터' $lbox '1단계에서는 여기서 읽어 와서 보여 주기만 합니다'))

    $card.Child = $col
    $card
}

function New-WtSettingsPage {
    $page = New-WtPage
    [void](Add-WtChild $page.Panel (New-WtPageHeader '설정'))
    [void](Add-WtChild $page.Panel (New-WtThemeCard))
    [void](Add-WtChild $page.Panel (New-WtMenuCard))
    [void](Add-WtChild $page.Panel (New-WtDataCard))
    $page.Root
}

# ---- 도움말 -----------------------------------------------------------------------------------

function New-WtKeyRow([string]$Keys, [string]$What) {
    $k = New-WtTag $Keys
    $k.MinWidth = 120
    New-WtListRow @($k, (New-WtText $What 'T.Body'))
}

# 탭이 등록한 단축키를 메뉴 순서대로 모은다. 키와 설명이 같으면 한 줄로 묶는다 (예: 문서 · 활성 작업: 새로 고침)
function Get-WtShortcutRows {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @(Get-WtAddon)) {
        foreach ($s in @($a.Shortcuts)) {
            $same = $rows | Where-Object { $_.Key -ceq $s[0] -and $_.What -ceq $s[1] } | Select-Object -First 1
            if ($same) { $same.Titles.Add($a.Title); continue }
            $titles = [System.Collections.Generic.List[string]]::new()
            $titles.Add($a.Title)
            $rows.Add([pscustomobject]@{ Key = [string]$s[0]; What = [string]$s[1]; Titles = $titles })
        }
    }
    foreach ($r in $rows) { [pscustomobject]@{ Key = $r.Key; Text = '{0}: {1}' -f ($r.Titles -join ' · '), $r.What } }
}

function New-WtHelpPage {
    $page = New-WtPage
    [void](Add-WtChild $page.Panel (New-WtPageHeader '도움말'))

    $about = New-WtCard
    $col = New-WtStack Vertical 6
    [void](Add-WtChild $col (New-WtCardHeader '이 버전 (1단계 미리보기)'))
    [void](Add-WtChild $col (New-WtText '창 틀 · 메뉴 · 테마 · 설정, 그리고 예전 WorkTool 데이터를 읽어서 보여 주는 기능까지 들어 있습니다.' 'T.Body'))
    foreach ($a in @(Get-WtAddon)) {
        foreach ($line in @($a.Help)) { [void](Add-WtChild $col (New-WtText $line 'T.Body')) }
    }
    $about.Child = $col
    [void](Add-WtChild $page.Panel $about)

    $keys = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '단축키'))
    foreach ($r in @(
            @('Ctrl + 1 ~ 9', '메뉴 순서대로 화면 이동'),
            @('Ctrl + B', '메뉴 접기 / 펼치기'),
            @('F11', '전체 화면 (Esc로 나가기)'),
            @('Ctrl + ,', '설정'),
            @('F1', '도움말'))) {
        [void](Add-WtChild $col (New-WtKeyRow $r[0] $r[1]))
    }
    foreach ($r in @(Get-WtShortcutRows)) { [void](Add-WtChild $col (New-WtKeyRow $r.Key $r.Text)) }
    $keys.Child = $col
    [void](Add-WtChild $page.Panel $keys)

    # 탭이 따로 둔 도움말 카드 (메모의 마크다운 예시 등). 하나가 실패해도 도움말은 연다
    foreach ($a in @(Get-WtAddon)) {
        if (-not $a.HelpCard) { continue }
        try {
            foreach ($el in @(& $a.HelpCard)) { if ($el -is [System.Windows.UIElement]) { [void](Add-WtChild $page.Panel $el) } }
        } catch {
            [void](Add-WtChild $page.Panel (New-WtText "$($a.Title) 도움말을 만들지 못했습니다: $($_.Exception.Message)" 'T.Sub'))
        }
    }

    $win = New-WtCard
    $col = New-WtStack Vertical 6
    [void](Add-WtChild $col (New-WtCardHeader '창 · 데이터'))
    [void](Add-WtChild $col (New-WtText '창의 X는 앱을 끝냅니다. 설정 → 닫기 버튼에서 트레이로 숨기기를 고르면, 끌 때 트레이 아이콘을 우클릭 → 종료.' 'T.Body'))
    [void](Add-WtChild $col (New-WtText "데이터 위치: $(Get-WtDataRoot)" 'T.Body'))
    $last = Get-WtLastImport
    if ($last) {
        $when = Format-WtDate $last.At 'M월 d일 HH:mm'
        [void](Add-WtChild $col (New-WtText "예전 데이터를 가져옴: $($last.Folder) ($when · $($last.Tabs -join ', '))" 'T.Sub'))
    }
    $win.Child = $col
    [void](Add-WtChild $page.Panel $win)

    $page.Root
}

Export-ModuleMember -Function New-WtSettingsPage, New-WtHelpPage

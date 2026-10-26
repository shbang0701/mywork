# 셸에 붙은 기본 화면: 설정, 도움말. 메뉴 아래 톱니바퀴 · 물음표 버튼으로 연다.
# 이벤트 처리기는 $script: 변수와 보낸 요소의 Tag만 쓴다 (Shell.psm1 머리말 참고).

$ErrorActionPreference = 'Stop'

$script:addonChecks = @()
$script:opacityLabel = $null
$script:opacityTimer = $null
$script:pendingOpacity = 100
$script:opacityNote = $null
$script:firstWorkSetup = $null

# ---- 설정 -------------------------------------------------------------------------------------

# 100%는 글자를 또렷하게 그리는 보통 창, 그 아래는 투명 창이다. 둘 사이를 오가면 다시 시작해야 적용된다
function Update-WtOpacityNote([double]$Percent) {
    $note = if (-not (Test-WtOpacityNeedsRestart $Percent)) { '' } elseif ($Percent -lt 100) { 'WorkTool을 다시 시작하면 적용됩니다.' } else { '다시 시작하면 글자가 더 또렷해집니다.' }
    $script:opacityNote.Text = $note
    $script:opacityNote.Visibility = if ($note) { 'Visible' } else { 'Collapsed' }
}

function New-WtSettingRow([string]$Label, $Control, [string]$Note) {
    $row = [System.Windows.Controls.Grid]::new()
    $row.Margin = [System.Windows.Thickness]::new(0, 8, 0, 8)
    $labelColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $labelColumn.Width = [System.Windows.GridLength]::Auto
    $labelColumn.SharedSizeGroup = 'WtSettingLabels'
    $row.ColumnDefinitions.Add($labelColumn)
    $row.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
    $left = New-WtStack Vertical 4
    $left.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $left.VerticalAlignment = 'Center'
    [void](Add-WtChild $left (New-WtText $Label 'T.Strong'))
    if ($Note) { $Control.ToolTip = $Note }
    [void]$row.Children.Add($left)
    $Control.VerticalAlignment = 'Center'
    $Control.HorizontalAlignment = 'Left'
    [System.Windows.Controls.Grid]::SetColumn($Control, 1)
    [void]$row.Children.Add($Control)
    $row
}

function New-WtThemeCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 4
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)
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
    [System.Windows.Automation.AutomationProperties]::SetName($slider, '불투명도')
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
    [void](Add-WtChild $col (New-WtSettingRow '불투명도' $opCol '60% ~ 100%'))

    # 글자 크기
    $seg = New-WtSegmented @(@('s', '작게'), @('m', '보통'), @('l', '크게')) ([string](Get-WtSetting 'ui.fontScale')) 'WtFont' {
        param($value) Set-WtSetting 'ui.fontScale' $value
    }
    [void](Add-WtChild $col (New-WtSettingRow '글자 크기' $seg))

    # 닫기 버튼(X)
    $close = New-WtSegmented @(@('exit', '끝내기'), @('tray', '트레이로 숨기기')) $(if (Get-WtSetting 'window.closeToTray') { 'tray' } else { 'exit' }) 'WtClose' {
        param($value) Set-WtSetting 'window.closeToTray' ($value -eq 'tray')
    }
    [void](Add-WtChild $col (New-WtSettingRow '닫기 버튼 (X)' $close '트레이 아이콘을 우클릭한 뒤 종료를 누르세요.'))

    $card.Child = $col
    $card
}

function New-WtMenuCard {
    $card = New-WtCard
    $col = New-WtStack Vertical 4
    [void](Add-WtChild $col (New-WtCardHeader '탭'))
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
    $col = New-WtStack Vertical 8
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)
    [void](Add-WtChild $col (New-WtCardHeader '데이터'))

    $root = Get-WtDataRoot
    $path = New-WtText $root 'T.Body'
    Set-WtResource $path 'FontFamily' 'Font.Mono'
    $open = New-WtButton '폴더 열기' -Icon 0xE8B7
    $open.Tag = $root
    $open.Add_Click({ param($s, $e) Open-WtPath ([string]$s.Tag) })
    $box = New-WtStack Vertical 8
    [void](Add-WtChild $box $path)
    [void](Add-WtChild $box $open)
    [void](Add-WtChild $col (New-WtSettingRow '데이터 폴더' $box '앱 폴더의 datapath.txt 첫 줄에 데이터 경로를 적으세요.'))

    $legacy = Find-WtLegacyFolder
    $lbox = New-WtStack Vertical 8
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
    [void](Add-WtChild $col (New-WtSettingRow '예전 데이터 가져오기' $lbox))

    $card.Child = $col
    $card
}

function New-WtTabbedPage([string]$Title, [object[]]$Sections) {
    $page = New-WtPage -Fill
    $page.Panel.Margin = [System.Windows.Thickness]::new(16)
    $heading = New-WtPageHeader $Title
    $heading.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [System.Windows.Controls.DockPanel]::SetDock($heading, 'Top')
    [void](Add-WtChild $page.Panel $heading)
    $tabs = [System.Windows.Controls.TabControl]::new()
    $tabs.BorderThickness = [System.Windows.Thickness]::new(0)
    $tabs.Padding = [System.Windows.Thickness]::new(0)
    Set-WtResource $tabs Background 'B.Bg.Surface'
    [System.Windows.Automation.AutomationProperties]::SetName($tabs, "$Title 하위 탭")
    foreach ($section in $Sections) {
        $item = [System.Windows.Controls.TabItem]::new()
        Set-WtStyle $item 'Tab'
        $item.Header = $section[0]
        $scroll = [System.Windows.Controls.ScrollViewer]::new()
        $scroll.VerticalScrollBarVisibility = 'Auto'
        $scroll.HorizontalScrollBarVisibility = 'Disabled'
        $scroll.Focusable = $false
        $scroll.Content = $section[1]
        $item.Content = $scroll
        [void]$tabs.Items.Add($item)
    }
    $tabs.SelectedIndex = 0
    [void](Add-WtChild $page.Panel $tabs)
    $page.Root
}

function New-WtSettingsPage {
    $work = New-WtWorkHoursForm
    New-WtTabbedPage '설정' @(
        @('일반', (New-WtThemeCard)), @('업무시간', $work.Root),
        @('탭', (New-WtMenuCard)), @('데이터', (New-WtDataCard)))
}

# ---- 업무시간: 첫 설정과 일반 설정이 같은 입력 · 검사를 사용한다. ------------------------------

function Get-WtWorkFormHours($Form) {
    $hours = @{ 'work.days' = @($Form.Days | Where-Object IsChecked | ForEach-Object { [int]$_.Tag.Day }) }
    foreach ($k in $Form.Boxes.Keys) { $hours[$k] = $Form.Boxes[$k].Text }
    $hours
}

function Update-WtWorkForm($Form, [switch]$Save) {
    if ($Form.Loading) { return $false }
    $hours = Get-WtWorkFormHours $Form
    $errors = Get-WtWorkHoursErrors $hours
    foreach ($k in $Form.Errors.Keys) {
        $message = if ($errors.Contains($k)) { [string]$errors[$k] } else { '' }
        $Form.Errors[$k].Text = $message
        $Form.Errors[$k].Visibility = if ($message) { 'Visible' } else { 'Collapsed' }
        if ($Form.Boxes.ContainsKey($k)) {
            $box = $Form.Boxes[$k]
            $binding = $box.GetBindingExpression([System.Windows.FrameworkElement]::DataContextProperty)
            if ($message) {
                $errorInfo = [System.Windows.Controls.ValidationError]::new([System.Windows.Controls.ExceptionValidationRule]::new(), $binding, $message, $null)
                [System.Windows.Controls.Validation]::MarkInvalid($binding, $errorInfo)
            } else { [System.Windows.Controls.Validation]::ClearInvalid($binding) }
        }
    }
    if ($errors.Count) { return $false }
    if ($Save) { Set-WtWorkHours $hours }
    $true
}

function Reset-WtWorkForm($Form) {
    $Form.Loading = $true
    try {
        $hours = Get-WtWorkHours -Defaults:$Form.FirstSetup
        foreach ($cb in $Form.Days) { $cb.IsChecked = $hours['work.days'] -contains $cb.Tag.Day }
        foreach ($k in $Form.Boxes.Keys) { $Form.Boxes[$k].Text = $hours[$k] }
    } finally { $Form.Loading = $false }
    [void](Update-WtWorkForm $Form)
}

function New-WtWorkHoursForm([switch]$FirstSetup) {
    $col = New-WtStack Vertical 12
    $col.Margin = [System.Windows.Thickness]::new(12)
    $form = @{ Root = $col; Boxes = @{}; Errors = @{}; Days = @(); FirstSetup = [bool]$FirstSetup; Loading = $true; Start = $null }
    $daysCol = New-WtStack Vertical 8
    [void](Add-WtChild $daysCol (New-WtText '일하는 요일' 'T.Strong'))
    $daysRow = [System.Windows.Controls.WrapPanel]::new()
    $dayNames = @('월', '화', '수', '목', '금', '토', '일')
    for ($n = 1; $n -le 7; $n++) {
        $cb = [System.Windows.Controls.CheckBox]::new()
        Set-WtStyle $cb 'Check'
        $cb.Content = $dayNames[$n - 1]
        $cb.Margin = [System.Windows.Thickness]::new(0, 0, 8, 0)
        $cb.Tag = @{ Form = $form; Day = $n }
        $cb.Add_Click({ param($s, $e) [void](Update-WtWorkForm $s.Tag.Form -Save:(-not $s.Tag.Form.FirstSetup)) })
        $form.Days += $cb
        [void]$daysRow.Children.Add($cb)
    }
    [void](Add-WtChild $daysCol $daysRow)
    $dayError = New-WtText '' 'T.Sub'
    Set-WtResource $dayError Foreground 'B.Status.Error.Text'
    $form.Errors['work.days'] = $dayError
    [void](Add-WtChild $daysCol $dayError)
    [void](Add-WtChild $col $daysCol)
    foreach ($field in @(@('work.start', '시작 시각'), @('work.end', '끝 시각'), @('work.lunchStart', '점심 시작 시각'), @('work.lunchEnd', '점심 끝 시각'))) {
        $group = New-WtStack Vertical 8
        $label = New-WtText $field[1] 'T.Strong'
        [void](Add-WtChild $group $label)
        $box = [System.Windows.Controls.TextBox]::new()
        Set-WtStyle $box 'Input'
        Set-WtResource $box FontFamily 'Font.Mono'
        [System.Windows.Automation.AutomationProperties]::SetName($box, $field[1])
        [System.Windows.Automation.AutomationProperties]::SetLabeledBy($box, $label)
        $box.Tag = $form
        # 별도 바인딩에 오류를 연결한다. Text를 직접 바꾸는 UIA 입력도 바인딩을 끊지 않는다.
        $binding = [System.Windows.Data.Binding]::new()
        $binding.Source = [pscustomobject]@{ Field = $field[0] }
        [void]$box.SetBinding([System.Windows.FrameworkElement]::DataContextProperty, $binding)
        $box.Add_TextChanged({ param($s, $e) [void](Update-WtWorkForm $s.Tag) })
        $box.Add_LostKeyboardFocus({ param($s, $e) if (-not $s.Tag.FirstSetup) { [void](Update-WtWorkForm $s.Tag -Save) } })
        $box.Add_KeyDown({
            param($s, $e)
            if ($e.Key -eq 'Return' -and -not $s.Tag.FirstSetup) { [void](Update-WtWorkForm $s.Tag -Save); $e.Handled = $true }
        })
        $form.Boxes[$field[0]] = $box
        [void](Add-WtChild $group $box)
        $errorText = New-WtText '' 'T.Sub'
        Set-WtResource $errorText Foreground 'B.Status.Error.Text'
        [System.Windows.Automation.AutomationProperties]::SetLiveSetting($errorText, 'Polite')
        $form.Errors[$field[0]] = $errorText
        [void](Add-WtChild $group $errorText)
        [void](Add-WtChild $col $group)
    }
    if ($FirstSetup) {
        $start = New-WtButton '시작' -Kind Primary
        $start.HorizontalAlignment = 'Left'
        $start.Tag = $form
        $start.Add_Click({ param($s, $e) if (Update-WtWorkForm $s.Tag -Save) { [void](Close-WtFirstWorkSetup) } })
        $form.Start = $start
        [void](Add-WtChild $col $start)
    }
    $col.Tag = $form
    $col.Add_Loaded({ param($s, $e) Reset-WtWorkForm $s.Tag })
    Reset-WtWorkForm $form
    $form
}

# 창 안의 본문을 덮는다. 제목 줄은 남기며 메뉴 · 단축키로 설정을 건너뛰지 못한다.
function Show-WtFirstWorkSetup($Window, [string]$HomePage) {
    if ($script:firstWorkSetup -or -not (Test-WtWorkSetupRequired)) { return }
    $page = New-WtPage
    $page.Panel.Margin = [System.Windows.Thickness]::new(16)
    $close = New-WtButton -Kind Icon -Icon 0xE711 -ToolTip '닫기 (Esc)'
    [System.Windows.Automation.AutomationProperties]::SetName($close, '업무시간 닫기')
    $close.Add_Click({ [void](Close-WtFirstWorkSetup -UseDefaults) })
    $heading = New-WtPageHeader '업무시간' -Right $close
    $heading.Margin = [System.Windows.Thickness]::new(0, 0, 0, 16)
    [void](Add-WtChild $page.Panel $heading)
    $form = New-WtWorkHoursForm -FirstSetup
    [void](Add-WtChild $page.Panel $form.Root)
    $overlay = [System.Windows.Controls.Border]::new()
    Set-WtResource $overlay Background 'B.Bg.Surface'
    $overlay.Child = $page.Root
    [System.Windows.Controls.Grid]::SetRow($overlay, 1)
    $grid = $Window.Content.Child
    $script:firstWorkSetup = @{ Window = $Window; Grid = $grid; Overlay = $overlay; Form = $form; Home = $HomePage }
    [void]$grid.Children.Add($overlay)
    [System.Windows.Input.KeyboardNavigation]::SetTabNavigation($overlay, 'Cycle')
    [void]$form.Boxes['work.start'].Focus()
}

# 닫기 · Esc는 편집 중인 값 대신 기본값을 저장한다. 셸의 X도 같은 통로를 사용한다.
function Close-WtFirstWorkSetup([switch]$UseDefaults) {
    if (-not $script:firstWorkSetup) { return $false }
    if ($UseDefaults) {
        Set-WtWorkHours (Get-WtWorkHours -Defaults)
    }
    $setup = $script:firstWorkSetup
    [void]$setup.Grid.Children.Remove($setup.Overlay)
    $script:firstWorkSetup = $null
    Select-WtPage $setup.Home
    $true
}

function Invoke-WtWorkSetupKey($Event) {
    if (-not $script:firstWorkSetup) { return $false }
    if ($Event.Key -eq 'Escape') { [void](Close-WtFirstWorkSetup -UseDefaults); $Event.Handled = $true; return $true }
    # 첫 설정 중에는 셸의 화면 전환 단축키만 막는다. 입력칸의 Ctrl+A · C · V는 유지한다.
    $ctrl = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control
    if ($Event.Key -in 'F1', 'F11' -or ($ctrl -and ($Event.Key -in 'B', 'OemComma' -or ($Event.Key -ge 'D1' -and $Event.Key -le 'D9')))) {
        $Event.Handled = $true
        return $true
    }
    $false
}

# ---- 도움말 -----------------------------------------------------------------------------------

function New-WtKeyRow([string]$Keys, [string]$What, [switch]$Header) {
    $row = [System.Windows.Controls.Border]::new()
    Set-WtResource $row BorderBrush 'B.Border.Muted'
    $row.BorderThickness = [System.Windows.Thickness]::new(0, 0, 0, 1)
    $row.Padding = [System.Windows.Thickness]::new(0, 8, 0, 8)
    $grid = [System.Windows.Controls.Grid]::new()
    $keyColumn = [System.Windows.Controls.ColumnDefinition]::new()
    $keyColumn.Width = [System.Windows.GridLength]::Auto
    $keyColumn.SharedSizeGroup = 'WtHelpKeys'
    $grid.ColumnDefinitions.Add($keyColumn)
    $grid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
    $k = if ($Header) { New-WtText $Keys 'T.Strong' } else { New-WtTag $Keys }
    $k.MinWidth = 120
    $k.Margin = [System.Windows.Thickness]::new(0, 0, 12, 0)
    $whatText = New-WtText $What $(if ($Header) { 'T.Strong' } else { 'T.Body' })
    [System.Windows.Controls.Grid]::SetColumn($whatText, 1)
    [void]$grid.Children.Add($k)
    [void]$grid.Children.Add($whatText)
    $row.Child = $grid
    $row
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
    $keys = New-WtCard
    $col = New-WtStack Vertical
    [System.Windows.Controls.Grid]::SetIsSharedSizeScope($col, $true)
    [void](Add-WtChild $col (New-WtKeyRow '키' '하는 일' -Header))
    foreach ($r in @(
            @('Ctrl + 1 ~ 9', '메뉴 순서대로 화면 이동'),
            @('Ctrl + B', '메뉴 접기 / 펼치기'),
            @('Ctrl + Shift + B', '사이드바 접기 순서 전환'),
            @('F11', '전체 화면 (Esc로 나가기)'),
            @('Ctrl + ,', '설정'),
            @('F1', '도움말'))) {
        [void](Add-WtChild $col (New-WtKeyRow $r[0] $r[1]))
    }
    foreach ($r in @(Get-WtShortcutRows)) { [void](Add-WtChild $col (New-WtKeyRow $r.Key $r.Text)) }
    $keys.Child = $col

    $tabs = New-WtStack Vertical 12
    $tabs.Margin = [System.Windows.Thickness]::new(12)
    foreach ($a in @(Get-WtAddon)) {
        $section = New-WtStack Vertical 8
        [void](Add-WtChild $section (New-WtCardHeader $a.Title))
        foreach ($line in @($a.Help)) { [void](Add-WtChild $section (New-WtText $line 'T.Body')) }
        if ($a.HelpCard) {
            try {
                foreach ($el in @(& $a.HelpCard)) { if ($el -is [System.Windows.UIElement]) { [void](Add-WtChild $section $el) } }
            } catch {
                [void](Add-WtChild $section (New-WtText "$($a.Title) 도움말을 만들지 못했습니다: $($_.Exception.Message)" 'T.Sub'))
            }
        }
        [void](Add-WtChild $tabs $section)
    }

    $win = New-WtCard
    $col = New-WtStack Vertical 8
    [void](Add-WtChild $col (New-WtCardHeader 'WorkTool'))
    [void](Add-WtChild $col (New-WtText '1단계 미리보기' 'T.Body'))
    [void](Add-WtChild $col (New-WtText '데이터 폴더' 'T.Strong'))
    [void](Add-WtChild $col (New-WtText (Get-WtDataRoot) 'T.Body'))
    $win.Child = $col
    New-WtTabbedPage '도움말' @(@('단축키', $keys), @('탭', $tabs), @('정보', $win))
}

Export-ModuleMember -Function New-WtSettingsPage, New-WtHelpPage, Show-WtFirstWorkSetup, Close-WtFirstWorkSetup, Invoke-WtWorkSetupKey

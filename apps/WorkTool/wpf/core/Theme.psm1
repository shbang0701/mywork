# 밝은 테마의 값. 기준: apps/WorkTool/design/README.md 2판 2~5절.
# 기존 B.* · F.* 키는 호환 별칭으로 남긴다. 바탕은 중성색이며 강조색만 고른다.
$ErrorActionPreference = 'Stop'

$script:palettes = [ordered]@{
    blue   = @{ Label = '파랑'; Accent = '#1A5BBE'; Hover = '#174FA6'; Pressed = '#144690' }
    pink   = @{ Label = '분홍'; Accent = '#B83D69'; Hover = '#A1355C'; Pressed = '#8C2E50' }
    teal   = @{ Label = '청록'; Accent = '#0B6B69'; Hover = '#0A5D5C'; Pressed = '#085150' }
    purple = @{ Label = '보라'; Accent = '#7048B8'; Hover = '#623FA1'; Pressed = '#55378C' }
    gray   = @{ Label = '회색'; Accent = '#56606D'; Hover = '#4B545F'; Pressed = '#414953' }
}
$script:fixed = @{
    'Bg.Canvas' = '#F3F4F6'; 'Bg.Surface' = '#FFFFFF'; 'Bg.Subtle' = '#F7F8FA'; 'Bg.Raised' = '#FFFFFF'
    'Border.Default' = '#DDE0E5'; 'Border.Muted' = '#ECEEF1'; 'Border.Strong' = '#C6CBD2'; 'Border.Control' = '#7A828D'
    'Text.Primary' = '#16191E'; 'Text.Secondary' = '#424A55'; 'Text.Tertiary' = '#5C6470'; 'Text.Disabled' = '#A3AAB4'
    OnAccent = '#FFFFFF'; 'Bg.Selected' = '#E8F0FC'; 'Overlay.Ink' = '#000000'
    'Fill.Hover.Surface' = '#F5F5F5'; 'Fill.Pressed.Surface' = '#EDEDED'
    'Fill.Hover.Canvas' = '#E9EAEC'; 'Fill.Pressed.Canvas' = '#E2E3E5'; 'Fill.Selected.Nav' = '#E4E5E7'
    'Fill.Hover.Subtle' = '#EDEEF0'; 'Fill.Pressed.Subtle' = '#E6E7E8'
    'Status.Success.Icon' = '#1E7F47'; 'Status.Success.Text' = '#1A6E3E'; 'Status.Success.Bg' = '#E6F4EC'
    'Status.Warning.Icon' = '#A86500'; 'Status.Warning.Text' = '#8A5300'; 'Status.Warning.Bg' = '#FCF2DE'
    'Status.Error.Icon' = '#C42F29'; 'Status.Error.Text' = '#B42820'; 'Status.Error.Bg' = '#FBE9E7'
    'Status.Neutral.Icon' = '#6B7380'; 'Status.Neutral.Bg' = '#EEF0F3'
    'Cal.Leave.Text' = '#0B6B69'; 'Cal.Leave.Bg' = '#E2F1F0'
    'Cal.Overtime.Text' = '#6A44B5'; 'Cal.Overtime.Bg' = '#F0ECFA'
    'Cal.Saturday' = '#2457B0'; 'Cal.DayOff' = '#F1F2F5'
    'Code.Command' = '#6639BA'; 'Code.String' = '#0A3069'; 'Code.Keyword' = '#C4243B'; 'Code.Variable' = '#953800'
}
# 옛 이름 → 2판 쓰임새. 별도 종류색이 없는 Work/Trip, 콜아웃·다이어그램은 가장 가까운 쓰임새(애매).
$script:colorAliases = @{
    Card = 'Bg.Surface'; Text = 'Text.Primary'; SubText = 'Text.Secondary'; NavText = 'Text.Primary'
    Border = 'Border.Default'; Divider = 'Border.Muted'; InputBorder = 'Border.Control'; ButtonBorder = 'Border.Strong'
    Chip = 'Bg.Subtle'; ChipText = 'Text.Secondary'; Danger = 'Status.Error.Text'; DangerBg = 'Status.Error.Bg'
    Success = 'Status.Success.Text'; SuccessBg = 'Status.Success.Bg'; Warn = 'Status.Warning.Text'; WarnBg = 'Status.Warning.Bg'
    CloseHover = 'Fill.Hover.Canvas'
    AccentHover = 'Accent.Hover'; AccentStrong = 'Accent.Text'; AccentSoft = 'Bg.Selected'
    Hover = 'Fill.Hover.Surface'; Sidebar = 'Bg.Canvas'; WindowBg = 'Bg.Canvas'; FrameBorder = 'Border.Default'
    'Status.Info.Icon' = 'Accent'; 'Status.Info.Text' = 'Text.Primary'; 'Status.Info.Bg' = 'Bg.Selected'
    'Status.Neutral.Text' = 'Text.Secondary'; 'Cal.Work' = 'Border.Default'; 'Cal.Holiday' = 'Status.Error.Text'
    'Att.Work' = 'Status.Neutral.Text'; 'Att.WorkBg' = 'Status.Neutral.Bg'
    'Att.Trip' = 'Status.Neutral.Text'; 'Att.TripBg' = 'Status.Neutral.Bg'
    'Att.Over' = 'Cal.Overtime.Text'; 'Att.OverBg' = 'Cal.Overtime.Bg'
    'Att.Leave' = 'Cal.Leave.Text'; 'Att.LeaveBg' = 'Cal.Leave.Bg'
    'Md.QuoteBar' = 'Border.Strong'; 'Md.Mark' = 'Bg.Selected'
    'Callout.Blue' = 'Status.Info.Text'; 'Callout.BlueBg' = 'Status.Info.Bg'
    'Callout.Teal' = 'Cal.Leave.Text'; 'Callout.TealBg' = 'Cal.Leave.Bg'
    'Callout.Green' = 'Status.Success.Text'; 'Callout.GreenBg' = 'Status.Success.Bg'
    'Callout.Orange' = 'Status.Warning.Text'; 'Callout.OrangeBg' = 'Status.Warning.Bg'
    'Callout.Red' = 'Status.Error.Text'; 'Callout.RedBg' = 'Status.Error.Bg'
    'Callout.Purple' = 'Cal.Overtime.Text'; 'Callout.PurpleBg' = 'Cal.Overtime.Bg'
    'Callout.Gray' = 'Status.Neutral.Text'; 'Callout.GrayBg' = 'Status.Neutral.Bg'
    'Code.Bg' = 'Bg.Subtle'; 'Code.Comment' = 'Text.Tertiary'
    'Code.Number' = 'Text.Primary'; 'Code.Type' = 'Text.Primary'; 'Code.Attr' = 'Text.Primary'
    'Code.Inserted' = 'Text.Primary'; 'Code.Deleted' = 'Text.Primary'
    'Dia.NodeBg' = 'Bg.Subtle'; 'Dia.NodeLine' = 'Border.Control'; 'Dia.Line' = 'Text.Secondary'
    'Dia.GroupBg' = 'Bg.Subtle'; 'Dia.GroupLine' = 'Border.Strong'
    'Dia.NoteBg' = 'Status.Warning.Bg'; 'Dia.NoteLine' = 'Status.Warning.Icon'
}
$script:fontScales = @{ s = 0.93; m = 1.0; l = 1.12 }
# 크기 / 굵기 / 줄 높이. F.<이름>은 크기, F.<이름>.Weight · .LineHeight는 짝 자원이다.
$script:typeRamp = @{
    Caption = @(12, 400, 16); Body = @(14, 400, 20); BodyStrong = @(14, 600, 20)
    Subtitle = @(16, 600, 24); Title = @(20, 600, 28); Code = @(14, 400, 20); 'Code.Dense' = @(12, 400, 18)
    'Memo.Body' = @(15, 400, 24); 'Memo.H1' = @(24, 600, 32); 'Memo.H2' = @(18, 600, 26)
    'Memo.H3' = @(16, 600, 24); 'Memo.H4' = @(15, 600, 24); 'Memo.H5' = @(14, 600, 22)
    'Memo.H6' = @(14, 600, 22); 'Memo.Code' = @(14, 400, 20)
}
$script:fontAliases = @{ Number = 'Title'; H2 = 'BodyStrong'; Dialog = 'Subtitle'; Small = 'Caption'; MdH1 = 'Memo.H1'; MdH2 = 'Memo.H2'; MdH3 = 'Memo.H3' }
$script:fonts = @{
    UI = 'Segoe UI Variable Text, Segoe UI, Malgun Gothic'
    Icon = 'Segoe Fluent Icons, Segoe MDL2 Assets'
    Mono = 'Consolas, Malgun Gothic'
}
$script:dimensions = @{
    'Space.1' = 4; 'Space.2' = 8; 'Space.3' = 12; 'Space.4' = 16; 'Space.6' = 24; 'Space.8' = 32
    'Gap.InGroup' = 8; 'Padding.Panel' = 12; 'Padding.Screen' = 16
    'Radius.Joined' = 0; 'Radius.Small' = 2; 'Radius.Control' = 4; 'Radius.Overlay' = 8; 'Radius.SelectionBar' = 1.5
    'Line.Border' = 1; 'Line.Focus' = 2; 'Line.FocusInner' = 1; 'Line.Selection' = 3; 'Line.TabActive' = 2
    'Height.Control' = 32; 'Height.Compact' = 28; 'Height.Row2' = 48; 'Height.MemoRow' = 52
    'Height.PanelHeader' = 40; 'Height.StatusBar' = 24; 'Height.Tab' = 36; 'Height.MemoTabBar' = 40; 'Height.MemoTab' = 28
    'Height.Chip' = 20; 'Height.FilterChip' = 24; 'Height.Checklist' = 28
    'ToolTip.MaxWidth' = 320; 'ToolTip.InitialShowDelay' = 400; 'ToolTip.BetweenShowDelay' = 100
}
$script:dictionaries = [System.Collections.Generic.List[System.WeakReference]]::new()
$script:themeHandlerRegistered = $false

function ConvertFrom-WtHex([string]$Hex) {
    $h = $Hex.TrimStart('#')
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}
function Get-WtMixedColor([string]$A, [string]$B, [double]$T) {
    $x = ConvertFrom-WtHex $A
    $y = ConvertFrom-WtHex $B
    $c = for ($i = 0; $i -lt 3; $i++) { [int][Math]::Round($x[$i] * (1 - $T) + $y[$i] * $T) }
    '#{0:X2}{1:X2}{2:X2}' -f $c[0], $c[1], $c[2]
}
function Get-WtLuminance([string]$Hex) {
    $lin = foreach ($v in (ConvertFrom-WtHex $Hex)) {
        $s = $v / 255
        if ($s -le 0.04045) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $lin[0] + 0.7152 * $lin[1] + 0.0722 * $lin[2]
}
function Get-WtContrast([string]$A, [string]$B) {
    $la = Get-WtLuminance $A
    $lb = Get-WtLuminance $B
    ([Math]::Max($la, $lb) + 0.05) / ([Math]::Min($la, $lb) + 0.05)
}
function Get-WtPalette { $script:palettes }

# 옛 위치 인수 Name(theme.color)은 무시한다. 명시한 Accent 또는 theme.accent만 쓴다.
# 셸이 옛 설정을 넘겨도 색을 되살리지 않는다. 비교 검사는 -Accent로 지정한다.
function Get-WtThemeColors([string]$Name, [string]$Accent = [string](Get-WtSetting 'theme.accent')) {
    $p = $script:palettes[$Accent]
    if (-not $p) { $p = $script:palettes['blue'] }
    $c = $script:fixed.Clone()
    $c.Accent = $p.Accent; $c['Accent.Text'] = $p.Accent; $c['Accent.Hover'] = $p.Hover; $c['Accent.Pressed'] = $p.Pressed
    foreach ($key in $script:palettes.Keys) {
        $suffix = (Get-Culture).TextInfo.ToTitleCase($key)
        $c["Accent.$suffix"] = $script:palettes[$key].Accent
        $c["Accent.$suffix.Hover"] = $script:palettes[$key].Hover
        $c["Accent.$suffix.Pressed"] = $script:palettes[$key].Pressed
    }
    # 별칭 사이 참조도 순서에 상관없이 해석한다.
    foreach ($key in $script:colorAliases.Keys) {
        $target = $script:colorAliases[$key]
        while ($script:colorAliases.ContainsKey($target)) { $target = $script:colorAliases[$target] }
        $c[$key] = $c[$target]
    }
    $c
}
function Get-WtFontScale {
    $scale = $script:fontScales[[string](Get-WtSetting 'ui.fontScale')]
    if ($scale) { [double]$scale } else { 1.0 }
}
function Get-WtFontSize([string]$Name) {
    if ($script:fontAliases.ContainsKey($Name)) { $Name = $script:fontAliases[$Name] }
    $size = if ($Name -eq 'Icon') { 16 } elseif ($Name -eq 'BodyLine') { 24 } else { $script:typeRamp[$Name][0] }
    [double][Math]::Round($size * (Get-WtFontScale), 1)
}
function Get-WtFontName([string]$Name) { $script:fonts[$Name] }
function Update-WtThemeDictionary([System.Windows.ResourceDictionary]$Dictionary) {
    $colors = Get-WtThemeColors
    foreach ($key in $colors.Keys) {
        $brush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($colors[$key]))
        $brush.Freeze()
        $Dictionary["B.$key"] = $brush
    }
    foreach ($key in $script:typeRamp.Keys) {
        $ramp = $script:typeRamp[$key]
        $Dictionary["F.$key"] = Get-WtFontSize $key
        $Dictionary["F.$key.Weight"] = [System.Windows.FontWeight]::FromOpenTypeWeight($ramp[1])
        $Dictionary["F.$key.LineHeight"] = [double][Math]::Round($ramp[2] * (Get-WtFontScale), 1)
    }
    foreach ($key in @($script:fontAliases.Keys) + @('Icon', 'BodyLine')) { $Dictionary["F.$key"] = Get-WtFontSize $key }
    foreach ($key in $script:fonts.Keys) { $Dictionary["Font.$key"] = [System.Windows.Media.FontFamily]::new($script:fonts[$key]) }
    foreach ($key in $script:dimensions.Keys) {
        $value = [double]$script:dimensions[$key]
        $Dictionary["F.$key"] = if ($key.StartsWith('Radius.')) { [System.Windows.CornerRadius]::new($value) }
            elseif ($key.StartsWith('Padding.')) { [System.Windows.Thickness]::new($value) }
            elseif ($key.StartsWith('Height.')) { [double][Math]::Round($value * (Get-WtFontScale), 1) }
            elseif ($key.EndsWith('Delay')) { [int]$value } else { $value }
    }
}
function New-WtThemeDictionary {
    $d = [System.Windows.ResourceDictionary]::new()
    Update-WtThemeDictionary $d
    $script:dictionaries.Add([System.WeakReference]::new($d))
    if (-not $script:themeHandlerRegistered) {
        # 셸의 옛 theme.color 처리와 무관하게 새 강조색·글자 자원을 즉시 갱신한다.
        Register-WtSettingHandler {
            param($key, $value)
            if ($key -notin @('theme.accent', 'ui.fontScale')) { return }
            for ($i = $script:dictionaries.Count - 1; $i -ge 0; $i--) {
                $live = $script:dictionaries[$i].Target
                if ($live) { Update-WtThemeDictionary $live } else { $script:dictionaries.RemoveAt($i) }
            }
        }
        $script:themeHandlerRegistered = $true
    }
    $d
}
Export-ModuleMember -Function ConvertFrom-WtHex, Get-WtMixedColor, Get-WtLuminance, Get-WtContrast, Get-WtPalette,
    Get-WtThemeColors, Update-WtThemeDictionary, New-WtThemeDictionary, Get-WtFontSize, Get-WtFontName

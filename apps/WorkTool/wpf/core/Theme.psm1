# 밝은 테마의 값. 기준: apps/WorkTool/design/README.md 3판 2~5절.
# 기존 B.* · F.* 키는 호환 별칭으로 남긴다. 파스텔 하나 = 옅은 색(Tint) + 강조색(Accent)이고, 면 · 선은 $script:tinted로 계산한다.
$ErrorActionPreference = 'Stop'
$script:themeBrushes = @{} # 고정된 브러시만 공유한다. 사전과 DynamicResource 연결은 각각 유지한다.
$script:themeMetrics = @{} # 글자 배율별 불변 값. 정의는 아래 typeRamp · fonts · dimensions 한 곳을 따른다.

$script:defaultPalette = 'sky'
$script:palettes = [ordered]@{
    sky    = @{ Label = '하늘'; Tint = '#DCEBFA'; Accent = '#226EBE' }
    pink   = @{ Label = '분홍'; Tint = '#FADDE8'; Accent = '#B83D69' }
    green  = @{ Label = '연두'; Tint = '#E1F1CF'; Accent = '#3F7D20' }
    yellow = @{ Label = '노랑'; Tint = '#FBEDBF'; Accent = '#856000' }
    purple = @{ Label = '보라'; Tint = '#E9E0F8'; Accent = '#7048B8' }
    gray   = @{ Label = '회색'; Tint = '#E3E7EC'; Accent = '#56606D' }
    black  = @{ Label = '검정'; Tint = '#DEDFE2'; Accent = '#2B2F36' }
}
# Tint에 섞을 색과 비율. 대비는 Test-Core.ps1이 일곱 색 모두 확인한다.
$script:tinted = @{
    'Bg.Canvas' = @('#FFFFFF', 0.55); 'Bg.Subtle' = @('#FFFFFF', 0.72); 'Bg.Selected' = @('#FFFFFF', 0.35)
    'Fill.Hover.Surface' = @('#FFFFFF', 0.65); 'Fill.Pressed.Surface' = @('#FFFFFF', 0.45)
    'Fill.Hover.Canvas' = @('#FFFFFF', 0.3); 'Fill.Pressed.Canvas' = @('#FFFFFF', 0.12); 'Fill.Selected.Nav' = @('#FFFFFF', 0)
    'Fill.Hover.Subtle' = @('#FFFFFF', 0.5); 'Fill.Pressed.Subtle' = @('#FFFFFF', 0.3)
    'Border.Muted' = @('#EFEFEF', 0.55); 'Border.Default' = @('#D8D8D8', 0.6); 'Border.Strong' = @('#C2C2C2', 0.6)
}
$script:fixed = @{
    'Bg.Surface' = '#FFFFFF'; 'Bg.Raised' = '#FFFFFF'; 'Border.Control' = '#74808F'
    'Text.Primary' = '#1D2B3A'; 'Text.Secondary' = '#465668'; 'Text.Tertiary' = '#526172'; 'Text.Disabled' = '#A3AAB4'
    OnAccent = '#FFFFFF'; 'Overlay.Ink' = '#000000'
    'Status.Success.Icon' = '#1E7F47'; 'Status.Success.Text' = '#1A6E3E'; 'Status.Success.Bg' = '#E6F4EC'
    'Status.Warning.Icon' = '#A86500'; 'Status.Warning.Text' = '#8A5300'; 'Status.Warning.Bg' = '#FCF2DE'
    'Status.Error.Icon' = '#C42F29'; 'Status.Error.Text' = '#B42820'; 'Status.Error.Bg' = '#FBE9E7'
    'Status.Neutral.Icon' = '#6B7380'; 'Status.Neutral.Bg' = '#EEF0F3'
    'Cal.Leave.Text' = '#0B6B69'; 'Cal.Leave.Bg' = '#E2F1F0'
    'Cal.Overtime.Text' = '#6A44B5'; 'Cal.Overtime.Bg' = '#F0ECFA'
    'Cal.Saturday' = '#2457B0'
    'Code.Command' = '#6639BA'; 'Code.String' = '#0A3069'; 'Code.Keyword' = '#C4243B'; 'Code.Variable' = '#953800'
}
# 옛 이름 → 쓰임새. 별도 종류색이 없는 Work/Trip, 콜아웃·다이어그램은 가장 가까운 쓰임새(애매).
$script:colorAliases = @{
    Card = 'Bg.Surface'; Text = 'Text.Primary'; SubText = 'Text.Secondary'; NavText = 'Text.Primary'
    Border = 'Border.Default'; Divider = 'Border.Muted'; InputBorder = 'Border.Control'; ButtonBorder = 'Border.Strong'
    Chip = 'Bg.Subtle'; ChipText = 'Text.Secondary'; Danger = 'Status.Error.Text'; DangerBg = 'Status.Error.Bg'
    Success = 'Status.Success.Text'; SuccessBg = 'Status.Success.Bg'; Warn = 'Status.Warning.Text'; WarnBg = 'Status.Warning.Bg'
    CloseHover = 'Fill.Hover.Canvas'
    AccentHover = 'Accent.Hover'; AccentStrong = 'Accent.Text'; AccentSoft = 'Bg.Selected'
    Hover = 'Fill.Hover.Surface'; Sidebar = 'Bg.Canvas'; WindowBg = 'Bg.Canvas'; FrameBorder = 'Border.Default'
    'Status.Info.Icon' = 'Accent'; 'Status.Info.Text' = 'Text.Primary'; 'Status.Info.Bg' = 'Bg.Selected'
    'Status.Neutral.Text' = 'Text.Secondary'; 'Cal.Work' = 'Fill.Hover.Canvas'; 'Cal.Holiday' = 'Status.Error.Text'; 'Cal.DayOff' = 'Bg.Subtle'
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
    'Code.Inserted' = 'Status.Success.Text'; 'Code.Deleted' = 'Status.Error.Text'
    'Dia.NodeBg' = 'Bg.Subtle'; 'Dia.NodeLine' = 'Border.Control'; 'Dia.Line' = 'Text.Secondary'
    'Dia.GroupBg' = 'Bg.Subtle'; 'Dia.GroupLine' = 'Border.Strong'
    'Dia.NoteBg' = 'Status.Warning.Bg'; 'Dia.NoteLine' = 'Status.Warning.Icon'
}
$script:fontScales = @{ s = 0.93; m = 1.0; l = 1.12 }
# 크기 / 굵기 / 줄 높이. F.<이름>은 크기, F.<이름>.Weight · .LineHeight는 짝 자원이다.
$script:typeRamp = @{
    Caption = @(12, 400, 16); Body = @(14, 400, 20); BodyStrong = @(14, 600, 20)
    Subtitle = @(16, 600, 24); Title = @(20, 400, 28); Display = @(24, 400, 32); Code = @(14, 400, 20); 'Code.Dense' = @(12, 400, 18)
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
    'Gap.InGroup' = 8; 'Gap.Panel' = 8; 'Padding.Panel' = 12; 'Padding.Screen' = 16
    'Radius.Joined' = 0; 'Radius.Small' = 2; 'Radius.Control' = 4; 'Radius.Card' = 8; 'Radius.Overlay' = 8; 'Radius.SelectionBar' = 1.5
    'Line.Border' = 1; 'Line.Focus' = 2; 'Line.FocusInner' = 1; 'Line.Selection' = 3; 'Line.TabActive' = 2
    'Height.Control' = 32; 'Height.Compact' = 28; 'Height.Row2' = 48; 'Height.MemoRow' = 52
    'Height.PanelHeader' = 40; 'Height.Header' = 56; 'Height.Tab' = 36; 'Height.MemoTabBar' = 40; 'Height.MemoTab' = 28
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

# 모르는 값이면 기본 파스텔로 표시한다. 저장된 값은 바꾸지 않는다.
function Get-WtThemeColors([string]$Name = [string](Get-WtSetting 'theme.color')) {
    $p = $script:palettes[$Name]
    if (-not $p) { $p = $script:palettes[$script:defaultPalette] }
    $c = $script:fixed.Clone()
    foreach ($key in $script:tinted.Keys) { $c[$key] = Get-WtMixedColor $p.Tint $script:tinted[$key][0] $script:tinted[$key][1] }
    $c.Accent = $p.Accent; $c['Accent.Text'] = $p.Accent
    $c['Accent.Hover'] = Get-WtMixedColor $p.Accent '#000000' 0.1272
    $c['Accent.Pressed'] = Get-WtMixedColor $p.Accent '#000000' 0.2399
    $c['Accent.Later'] = Get-WtMixedColor $p.Accent '#FFFFFF' 0.6
    $textInfo = (Get-Culture).TextInfo
    foreach ($key in $script:palettes.Keys) {
        $c["Accent.$($textInfo.ToTitleCase($key))"] = $script:palettes[$key].Accent
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
function Get-WtThemeMetrics {
    $scale = Get-WtFontScale
    if ($script:themeMetrics.ContainsKey($scale)) { return $script:themeMetrics[$scale] }
    $resources = @{}
    foreach ($key in $script:typeRamp.Keys) {
        $ramp = $script:typeRamp[$key]
        $resources["F.$key"] = [double][Math]::Round($ramp[0] * $scale, 1)
        $resources["F.$key.Weight"] = [System.Windows.FontWeight]::FromOpenTypeWeight($ramp[1])
        $resources["F.$key.LineHeight"] = [double][Math]::Round($ramp[2] * $scale, 1)
    }
    foreach ($key in $script:fontAliases.Keys) { $resources["F.$key"] = $resources["F.$($script:fontAliases[$key])"] }
    foreach ($key in 'Icon', 'BodyLine') { $resources["F.$key"] = Get-WtFontSize $key }
    foreach ($key in $script:fonts.Keys) {
        $resources["Font.$key"] = [System.Windows.Media.FontFamily]::new($script:fonts[$key])
    }
    $resources['F.Padding.Card'] = [System.Windows.Thickness]::new(20, 16, 20, 16)
    foreach ($key in $script:dimensions.Keys) {
        $value = [double]$script:dimensions[$key]
        $resources["F.$key"] = if ($key.StartsWith('Radius.')) { [System.Windows.CornerRadius]::new($value) }
            elseif ($key.StartsWith('Padding.')) { [System.Windows.Thickness]::new($value) }
            elseif ($key.StartsWith('Height.')) { [double][Math]::Round($value * $scale, 1) }
            elseif ($key.EndsWith('Delay')) { [int]$value } else { $value }
    }
    $script:themeMetrics[$scale] = $resources
    $resources
}
function Update-WtThemeDictionary([System.Windows.ResourceDictionary]$Dictionary) {
    # 같은 값을 다시 넣으면 연결된 컨트롤도 다시 갱신된다. 바뀐 자원만 교체한다.
    # 병합된 사전에서 찾은 값은 대상 사전의 값이 아니다. 로컬 키는 종전처럼 모두 채운다.
    $localKeys = $null
    if ($Dictionary.MergedDictionaries.Count) {
        $localKeys = [System.Collections.Generic.HashSet[object]]::new()
        foreach ($key in $Dictionary.Keys) { [void]$localKeys.Add($key) }
    }
    $colors = Get-WtThemeColors
    foreach ($key in $colors.Keys) {
        $hex = $colors[$key]
        if (-not $script:themeBrushes.ContainsKey($hex)) {
            $brush = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString($hex))
            $brush.Freeze()
            $script:themeBrushes[$hex] = $brush
        }
        $resourceKey = "B.$key"
        $brush = $script:themeBrushes[$hex]
        if (($null -ne $localKeys -and -not $localKeys.Contains($resourceKey)) -or -not [object]::ReferenceEquals($Dictionary[$resourceKey], $brush)) {
            $Dictionary[$resourceKey] = $brush
        }
    }
    $resources = Get-WtThemeMetrics
    foreach ($key in $resources.Keys) {
        if (($null -ne $localKeys -and -not $localKeys.Contains($key)) -or -not [object]::Equals($Dictionary[$key], $resources[$key])) {
            $Dictionary[$key] = $resources[$key]
        }
    }
}
function New-WtThemeDictionary {
    $d = [System.Windows.ResourceDictionary]::new()
    Update-WtThemeDictionary $d
    $script:dictionaries.Add([System.WeakReference]::new($d))
    if (-not $script:themeHandlerRegistered) {
        # 색 · 글자 자원은 살아 있는 사전마다 즉시 갱신한다.
        Register-WtSettingHandler {
            param($key, $value)
            if ($key -notin @('theme.color', 'ui.fontScale')) { return }
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

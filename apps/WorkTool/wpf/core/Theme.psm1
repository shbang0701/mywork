# 테마 담당. 색 · 글자 크기 · 글꼴은 여기서만 정하고, 화면은 리소스 이름(B.Accent, F.Body …)으로만 쓴다.
# 값의 기준은 apps/WorkTool/design/README.md다. 팔레트를 바꾸거나 더할 때는 그 문서도 같이 고친다.
#
# 팔레트 하나 = 연한 바탕색(Tint) + 강조색(Accent).
# - Tint: 선택된 메뉴 바탕. 메뉴 · 창 바탕은 Tint를 흰색과 섞어 더 연하게 쓴다.
# - Accent: 주 버튼 · 선택 표시. 흰 글자와 4.5:1 이상이어야 한다 (tests/Test-Core.ps1이 검사).

$ErrorActionPreference = 'Stop'

$script:palettes = [ordered]@{
    sky    = @{ Label = '하늘'; Tint = '#DCEBFA'; Accent = '#2370C2' }
    pink   = @{ Label = '분홍'; Tint = '#FADDE8'; Accent = '#B83D69' }
    green  = @{ Label = '연두'; Tint = '#E1F1CF'; Accent = '#3F7D20' }
    yellow = @{ Label = '노랑'; Tint = '#FBEDBF'; Accent = '#856000' }
    purple = @{ Label = '보라'; Tint = '#E9E0F8'; Accent = '#7048B8' }
    gray   = @{ Label = '회색'; Tint = '#E3E7EC'; Accent = '#56606D' }
    black  = @{ Label = '검정'; Tint = '#DEDFE2'; Accent = '#2B2F36' }
}

# 테마와 상관없이 같은 색 (글자, 선, 상태, 근태 종류)
$script:fixed = @{
    Card         = '#FFFFFF'
    OnAccent     = '#FFFFFF'
    Text         = '#1D2B3A'
    SubText      = '#56667A'
    NavText      = '#2E3E50'
    Border       = '#DCE3EC'
    Divider      = '#EEF2F7'
    InputBorder  = '#7F8C9C'
    ButtonBorder = '#C4CEDA'
    Chip         = '#EEF2F7'
    ChipText     = '#4A5A6C'
    Danger       = '#B83227'
    DangerBg     = '#FBE7E4'
    Success      = '#1E7F4F'
    SuccessBg    = '#E3F4EB'
    Warn         = '#8A5A08'
    WarnBg       = '#FDF1DC'
    CloseHover   = '#C42B1C'
    'Att.Work'   = '#1C5A9B'; 'Att.WorkBg'  = '#E0EBF7'
    'Att.Over'   = '#5A42AE'; 'Att.OverBg'  = '#EEEAFB'
    'Att.Trip'   = '#0B6E6D'; 'Att.TripBg'  = '#DDF2F1'
    'Att.Leave'  = '#9C4E0F'; 'Att.LeaveBg' = '#FCEBDC'

    # 마크다운 보기 (Markdown.psm1)
    'Md.QuoteBar' = '#C4CEDA'   # 인용 왼쪽 막대 (장식)
    'Md.Mark'     = '#FFF0A8'   # ==형광펜== 바탕
    # 콜아웃 (> [!note] …): 제목 · 막대 글자색 / 바탕
    'Callout.Blue'   = '#1C5A9B'; 'Callout.BlueBg'   = '#E0EBF7'
    'Callout.Teal'   = '#0B6E6D'; 'Callout.TealBg'   = '#DDF2F1'
    'Callout.Green'  = '#1A6E44'; 'Callout.GreenBg'  = '#E3F4EB'
    'Callout.Orange' = '#8A5A08'; 'Callout.OrangeBg' = '#FDF1DC'
    'Callout.Red'    = '#B83227'; 'Callout.RedBg'    = '#FBE7E4'
    'Callout.Purple' = '#5A42AE'; 'Callout.PurpleBg' = '#EEEAFB'
    'Callout.Gray'   = '#4A5A6C'; 'Callout.GrayBg'   = '#EEF2F7'
    # 코드 블록 바탕과 색칠 (Highlight.psm1의 Kind 이름). 모두 Code.Bg 위에서 4.5:1 이상
    'Code.Bg'       = '#F3F6F9'
    'Code.Comment'  = '#56667A'
    'Code.String'   = '#0A3069'
    'Code.Keyword'  = '#C4243B'
    'Code.Number'   = '#0550AE'
    'Code.Command'  = '#6639BA'
    'Code.Variable' = '#953800'
    'Code.Type'     = '#116329'
    'Code.Attr'     = '#0B6E6D'
    'Code.Inserted' = '#1A6E44'
    'Code.Deleted'  = '#B83227'
    # 다이어그램 (Mermaid.psm1)
    'Dia.NodeBg'    = '#EEF2F7'
    'Dia.NodeLine'  = '#7F8C9C'   # 흰 바탕과 3:1 이상
    'Dia.Line'      = '#56667A'   # 연결선 · 화살표
    'Dia.GroupBg'   = '#F7F9FB'
    'Dia.GroupLine' = '#C4CEDA'
    'Dia.NoteBg'    = '#FDF1DC'
    'Dia.NoteLine'  = '#D9B66A'
}

$script:fontScales = @{ s = 0.93; m = 1.0; l = 1.12 }
# MdH1~3 · Code · BodyLine(본문 줄 높이 1.5배)은 마크다운 보기용
$script:fontSizes = @{ Title = 26; Number = 22; H2 = 16; Dialog = 20; Body = 14; Small = 12.5; Icon = 16; MdH1 = 24; MdH2 = 20; MdH3 = 17; Code = 13; BodyLine = 21 }
$script:fonts = @{
    # 앞 글꼴에 없는 글자는 다음 글꼴로 그린다. UI는 Windows 기본 글꼴만 쓴다: 영문 · 숫자는 Segoe UI Variable(Windows 11)
    # → Segoe UI(Windows 10), 한글은 맑은 고딕. 따로 설치하는 글꼴(Noto Sans KR 등)은 PC마다 있고 없고가 달라 쓰지 않는다
    UI   = 'Segoe UI Variable Text, Segoe UI, Malgun Gothic'
    Icon = 'Segoe Fluent Icons, Segoe MDL2 Assets'
    Mono = 'Consolas, D2Coding, Malgun Gothic'
}

# ---- 색 계산 (WPF 없이도 동작: 테스트용) ------------------------------------------------------

function ConvertFrom-WtHex([string]$Hex) {
    $h = $Hex.TrimStart('#')
    @([Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

# $A를 $B 쪽으로 $T(0~1)만큼 섞는다
function Get-WtMixedColor([string]$A, [string]$B, [double]$T) {
    $x = ConvertFrom-WtHex $A
    $y = ConvertFrom-WtHex $B
    $c = for ($i = 0; $i -lt 3; $i++) { [int][Math]::Round($x[$i] * (1 - $T) + $y[$i] * $T) }
    '#{0:X2}{1:X2}{2:X2}' -f $c[0], $c[1], $c[2]
}

function Get-WtLuminance([string]$Hex) {
    $lin = foreach ($v in (ConvertFrom-WtHex $Hex)) {
        $s = $v / 255
        if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) }
    }
    0.2126 * $lin[0] + 0.7152 * $lin[1] + 0.0722 * $lin[2]
}

function Get-WtContrast([string]$A, [string]$B) {
    $la = Get-WtLuminance $A
    $lb = Get-WtLuminance $B
    ([Math]::Max($la, $lb) + 0.05) / ([Math]::Min($la, $lb) + 0.05)
}

function Get-WtPalette { $script:palettes }

# 팔레트 이름 → 색 이름별 #RRGGBB
function Get-WtThemeColors([string]$Name) {
    $p = $script:palettes[$Name]
    if (-not $p) { $p = $script:palettes['sky'] }
    $c = @{}
    foreach ($k in $script:fixed.Keys) { $c[$k] = $script:fixed[$k] }
    $c.Accent       = $p.Accent
    $c.AccentHover  = Get-WtMixedColor $p.Accent '#000000' 0.12
    $c.AccentStrong = Get-WtMixedColor $p.Accent '#000000' 0.18
    $c.AccentSoft   = $p.Tint
    $c.Hover        = Get-WtMixedColor $p.Tint '#FFFFFF' 0.25
    $c.Sidebar      = Get-WtMixedColor $p.Tint '#FFFFFF' 0.45
    $c.WindowBg     = Get-WtMixedColor $p.Tint '#FFFFFF' 0.75
    $c.FrameBorder  = Get-WtMixedColor $p.Tint '#8C99A8' 0.55
    $c
}

# ---- WPF 리소스 ------------------------------------------------------------------------------

# 테마 리소스를 담은 사전을 채운다. 같은 사전의 값을 바꾸면 DynamicResource로 쓴 화면이 바로 바뀐다.
function Update-WtThemeDictionary([System.Windows.ResourceDictionary]$Dictionary) {
    $colors = Get-WtThemeColors ([string](Get-WtSetting 'theme.color'))
    foreach ($k in $colors.Keys) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($colors[$k])
        $brush = [System.Windows.Media.SolidColorBrush]::new($color)
        $brush.Freeze()
        $Dictionary["B.$k"] = $brush
    }
    foreach ($k in $script:fontSizes.Keys) { $Dictionary["F.$k"] = Get-WtFontSize $k }
    foreach ($k in $script:fonts.Keys) { $Dictionary["Font.$k"] = [System.Windows.Media.FontFamily]::new($script:fonts[$k]) }
}

# 지금 설정의 글자 크기 (F.* 리소스와 같은 값). 화면에 붙기 전에 크기를 재야 할 때 쓴다 (다이어그램 배치 등).
function Get-WtFontSize([string]$Name) {
    $scale = $script:fontScales[[string](Get-WtSetting 'ui.fontScale')]
    if (-not $scale) { $scale = 1.0 }
    [double][Math]::Round($script:fontSizes[$Name] * $scale, 1)
}

# 글꼴 이름 목록 (Font.* 리소스와 같은 값). $Name: UI · Icon · Mono
function Get-WtFontName([string]$Name) { $script:fonts[$Name] }

function New-WtThemeDictionary {
    $d = [System.Windows.ResourceDictionary]::new()
    Update-WtThemeDictionary $d
    $d
}

Export-ModuleMember -Function ConvertFrom-WtHex, Get-WtMixedColor, Get-WtLuminance, Get-WtContrast, Get-WtPalette,
    Get-WtThemeColors, Update-WtThemeDictionary, New-WtThemeDictionary, Get-WtFontSize, Get-WtFontName

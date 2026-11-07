<#
.SYNOPSIS
    일정 탭 단계별 시안(1단계: 체크 · 여러 날 막대 · 휴무일, 2단계: 일정 ↔ 메모 연결 · 메모 새 창, 3단계: 찾기 · 표 · 루틴 보기) SVG와 PNG를 만든다.
.DESCRIPTION
    PowerShell 7과 Windows 기본 WPF 어셈블리만 쓴다. 데이터 폴더를 읽지 않고, 아래 가짜 일정으로 그림만 그린다.
    색 · 글자 · 치수는 디자인 README 3판(하늘)의 값이다. 앱은 Theme · Ui 리소스를 쓰므로 이 파일의 값은 그림용이다.
.PARAMETER Part
    만들 시안 묶음. all(기본) · phase1(schedule-plan-list 등 1단계) · memo(schedule-plan-memo* 2단계) · views(schedule-plan-views* 3단계)
.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/design/build-schedule-mockups.ps1
.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/design/build-schedule-mockups.ps1 -Part memo
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('all', 'phase1', 'memo', 'views')][string]$Part = 'all'
)

# ===== 설정 (목업 생성용, 앱 설정이 아님) =====
$Config = @{
    OutputFolder = $PSScriptRoot
    Name = 'schedule-plan'
    PngScale = 2
}
# ===========================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase

$inv = [Globalization.CultureInfo]::InvariantCulture
$culture = [Globalization.CultureInfo]::GetCultureInfo('ko-KR')

# 디자인 README 2절: 섞기(T, 색, 비율) = 채널마다 round(T × (1−비율) + 색 × 비율)
function Get-Mix([string]$From, [string]$To, [double]$Ratio) {
    $a = [Windows.Media.ColorConverter]::ConvertFromString($From)
    $b = [Windows.Media.ColorConverter]::ConvertFromString($To)
    $ch = foreach ($p in 'R', 'G', 'B') { [int][math]::Round($a.$p * (1 - $Ratio) + $b.$p * $Ratio, [MidpointRounding]::AwayFromZero) }
    '#{0:X2}{1:X2}{2:X2}' -f $ch[0], $ch[1], $ch[2]
}
$T = '#DCEBFA'; $A = '#226EBE'   # 3절 하늘
# 색 표. 이름을 $C로 하면 PowerShell은 대소문자를 가리지 않아 반복문의 $c와 겹친다
$Ink = @{
    Canvas = Get-Mix $T '#FFFFFF' 0.55; Surface = '#FFFFFF'; Subtle = Get-Mix $T '#FFFFFF' 0.72
    Border = Get-Mix $T '#D8D8D8' 0.6; Muted = Get-Mix $T '#EFEFEF' 0.55; Strong = Get-Mix $T '#C2C2C2' 0.6; Control = '#74808F'
    Text = '#1D2B3A'; Text2 = '#465668'; Text3 = '#526172'; Off = '#A3AAB4'
    Accent = $A; OnAccent = '#FFFFFF'; Selected = Get-Mix $T '#FFFFFF' 0.35; Nav = $T; Hover = Get-Mix $T '#FFFFFF' 0.65
    LeaveText = '#0B6B69'; LeaveBg = '#E2F1F0'; OverText = '#6A44B5'; OverBg = '#F0ECFA'
    Sunday = '#B42820'; Saturday = '#2457B0'; Danger = '#B42820'; Warn = '#A86500'; OffBg = '#FBE9E7'
}

$installed = @([Windows.Media.Fonts]::SystemFontFamilies | ForEach-Object Source)
$uiFamily = 'Segoe UI Variable Text, Segoe UI, Malgun Gothic'
$iconFamily = if ($installed -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' } else { 'Segoe MDL2 Assets' }
$script:brushes = @{}
$script:faces = @{}
$script:shapes = $null

function Use-Scene { $script:shapes = [Collections.Generic.List[object]]::new(); , $script:shapes }

function Get-Brush([string]$Color) {
    if (-not $script:brushes.ContainsKey($Color)) {
        $b = [Windows.Media.BrushConverter]::new().ConvertFromInvariantString($Color)
        $b.Freeze()
        $script:brushes[$Color] = $b
    }
    $script:brushes[$Color]
}
function New-TextLayout([string]$Value, [double]$Size, [bool]$Bold = $false, [string]$Family = $uiFamily, [string]$Color = '#000000') {
    $key = "$Family|$Bold"
    if (-not $script:faces.ContainsKey($key)) {
        $weight = if ($Bold) { [Windows.FontWeights]::SemiBold } else { [Windows.FontWeights]::Normal }
        $script:faces[$key] = [Windows.Media.Typeface]::new([Windows.Media.FontFamily]::new($Family), [Windows.FontStyles]::Normal, $weight, [Windows.FontStretches]::Normal)
    }
    [Windows.Media.FormattedText]::new($Value, $culture, [Windows.FlowDirection]::LeftToRight, $script:faces[$key], $Size, (Get-Brush $Color), 1.0)
}
function Measure-Text([string]$Value, [double]$Size = 14, [bool]$Bold = $false) { (New-TextLayout $Value $Size $Bold).WidthIncludingTrailingWhitespace }
function Get-Fit([string]$Value, [double]$Size, [bool]$Bold, [double]$Max) {
    if ((Measure-Text $Value $Size $Bold) -le $Max) { return $Value }
    for ($n = $Value.Length - 1; $n -gt 0; $n--) {
        $t = $Value.Substring(0, $n).TrimEnd() + '…'
        if ((Measure-Text $t $Size $Bold) -le $Max) { return $t }
    }
    '…'
}

# ---- 도형 ------------------------------------------------------------------------------------

function Add-Box([double]$X, [double]$Y, [double]$W, [double]$H, [string]$Fill, [string]$Stroke = '', [double]$Radius = 0, [double]$Thickness = 1) {
    $script:shapes.Add(@{ Kind = 'rect'; X = $X; Y = $Y; W = $W; H = $H; Fill = $Fill; Stroke = $Stroke; Radius = $Radius; Thickness = $Thickness })
}
# 바깥 크기 기준 1px 테두리 상자 (선 중심을 0.5 안으로)
function Add-Frame([double]$X, [double]$Y, [double]$W, [double]$H, [string]$Fill, [string]$Stroke, [double]$Radius = 0) {
    Add-Box ($X + 0.5) ($Y + 0.5) ($W - 1) ($H - 1) $Fill $Stroke $Radius 1
}
function Add-Path([string]$Data, [string]$Fill, [string]$Stroke = '', [double]$Thickness = 1) {
    $script:shapes.Add(@{ Kind = 'path'; Data = $Data; Fill = $Fill; Stroke = $Stroke; Thickness = $Thickness })
}
# 글자 하나. Y는 글자 상자의 위. 너비를 돌려준다
function Add-Text([double]$X, [double]$Y, [string]$Value, [double]$Size = 14, [string]$Color = $Ink.Text, [bool]$Bold = $false) {
    $layout = New-TextLayout $Value $Size $Bold
    $script:shapes.Add(@{ Kind = 'text'; X = $X; Y = $Y; Value = $Value; Size = $Size; Color = $Color; Bold = $Bold; Baseline = $layout.Baseline })
    $layout.WidthIncludingTrailingWhitespace
}
# 높이 H인 줄의 세로 가운데에 쓴다. Max를 넘으면 말줄임, Right면 X가 오른쪽 끝. 너비를 돌려준다
function Add-Line([double]$X, [double]$Top, [double]$H, [string]$Value, [double]$Size = 14, [string]$Color = $Ink.Text, [bool]$Bold = $false, [double]$Max = 0, [switch]$Right) {
    $v = if ($Max -gt 0) { Get-Fit $Value $Size $Bold $Max } else { $Value }
    $layout = New-TextLayout $v $Size $Bold
    $w = $layout.WidthIncludingTrailingWhitespace
    $x = if ($Right) { $X - $w } else { $X }
    [void](Add-Text $x ($Top + ($H - $layout.Height) / 2) $v $Size $Color $Bold)
    $w
}
function Add-Center([double]$X, [double]$Y, [double]$W, [double]$H, [string]$Value, [double]$Size, [string]$Color, [bool]$Bold = $false) {
    $layout = New-TextLayout $Value $Size $Bold
    [void](Add-Text ($X + ($W - $layout.WidthIncludingTrailingWhitespace) / 2) ($Y + ($H - $layout.Height) / 2) $Value $Size $Color $Bold)
}
# Windows 기본 아이콘 글자를 경로로 바꿔 상자 가운데에 둔다. 폰에 Segoe 글꼴이 없어도 같은 모양으로 보인다
function Add-Glyph([double]$X, [double]$Y, [double]$W, [double]$H, [int]$Code, [double]$Size, [string]$Color) {
    $layout = New-TextLayout ([string][char]$Code) $Size $false $iconFamily
    $b = $layout.BuildGeometry([Windows.Point]::new(0, 0)).Bounds
    if ($b.IsEmpty) { return }
    $origin = [Windows.Point]::new($X + ($W - $b.Width) / 2 - $b.X, $Y + ($H - $b.Height) / 2 - $b.Y)
    $data = $layout.BuildGeometry($origin).GetOutlinedPathGeometry().ToString($inv) -replace '^F[01]\s*', ''
    Add-Path $data $Color
}
function Add-Crop([double]$X, [double]$Y, [double]$W, [double]$H, [double]$SourceX, [double]$SourceY, [double]$SourceW, [double]$SourceH, $Shapes) {
    $script:shapes.Add(@{ Kind = 'crop'; X = $X; Y = $Y; W = $W; H = $H; SX = $SourceX; SY = $SourceY; SW = $SourceW; SH = $SourceH; Shapes = $Shapes })
}

# ---- 공통 부품 (README 7절) ------------------------------------------------------------------

function Add-Check([double]$X, [double]$Y, [bool]$On) {
    if ($On) { Add-Box $X $Y 16 16 $Ink.Accent '' 2; Add-Glyph $X $Y 16 16 0xE73E 12 $Ink.OnAccent }
    else { Add-Frame $X $Y 16 16 $Ink.Surface $Ink.Control 2 }
}
function Add-Btn([double]$X, [double]$Y, [string]$Text, [string]$Kind = 'default', [switch]$Right) {
    $w = (Measure-Text $Text 14) + 24
    if ($Right) { $X -= $w }
    switch ($Kind) {
        'primary' { Add-Box $X $Y $w 32 $Ink.Accent '' 4; [void](Add-Line ($X + 12) $Y 32 $Text 14 $Ink.OnAccent) }
        'danger' { [void](Add-Line ($X + 12) $Y 32 $Text 14 $Ink.Danger) }
        default { Add-Frame $X $Y $w 32 $Ink.Surface $Ink.Strong 4; [void](Add-Line ($X + 12) $Y 32 $Text 14 $Ink.Text) }
    }
    $w
}
function Add-Input([double]$X, [double]$Y, [double]$W, [string]$Text, [string]$Prefix = '', [switch]$Combo) {
    Add-Frame $X $Y $W 32 $Ink.Surface $Ink.Control 4
    $tx = $X + 10
    if ($Prefix) { $tx += (Add-Line $tx $Y 32 $Prefix 14 $Ink.Text3) + 2 }
    $end = if ($Combo) { 32 } else { 10 }
    [void](Add-Line $tx $Y 32 $Text 14 $Ink.Text -Max ($X + $W - $tx - $end))
    if ($Combo) { Add-Glyph ($X + $W - 30) $Y 20 32 0xE70D 10 $Ink.Text2 }
}
function Add-TitleBar([double]$X, [double]$Y, [double]$W, [string]$Title) {
    Add-Box ($X + 12) ($Y + 8) 16 16 $Ink.Accent '' 4
    Add-Center ($X + 12) ($Y + 8) 16 16 'W' 10 $Ink.OnAccent $true
    [void](Add-Line ($X + 36) $Y 32 $Title 12 $Ink.Text2)
    $i = 0
    foreach ($code in 0xE921, 0xE922, 0xE8BB) { Add-Glyph ($X + $W - 138 + 46 * $i) $Y 46 32 $code 10 $Ink.Text2; $i++ }
}
function Add-Nav([switch]$NoSelect) {
    Add-Glyph 12 37 28 28 0xE700 16 $Ink.Text2
    [void](Add-Line 20 68 24 '일과' 12 $Ink.Text3)
    [void](Add-Line 20 199 24 '작업' 12 $Ink.Text3)
    $rows = @(
        @{ T = '홈'; I = 0xE80F; Y = 95 }, @{ T = '일정'; I = 0xE787; Y = 127; Sel = -not $NoSelect; N = '5' }, @{ T = '근태'; I = 0xE823; Y = 159; Dot = $true }
        @{ T = '메모'; I = 0xE70B; Y = 227 }, @{ T = '문서'; I = 0xE8B7; Y = 259 }, @{ T = '업무'; I = 0xE756; Y = 291 }, @{ T = '활성 작업'; I = 0xE7C4; Y = 323; N = '0' }
    )
    foreach ($r in $rows) {
        if ($r['Sel']) { Add-Box 8 $r.Y 184 32 $Ink.Nav '' 4; Add-Box 8 ($r.Y + 8) 3 16 $Ink.Accent '' 1.5 }
        Add-Glyph 20 $r.Y 16 32 $r.I 16 $Ink.Text2
        [void](Add-Line 48 $r.Y 32 $r.T 14 $Ink.Text ([bool]$r['Sel']))
        if ($r['N']) { [void](Add-Line 184 $r.Y 32 $r['N'] 12 $Ink.Text3 -Right) }
        if ($r['Dot']) { Add-Box 178 ($r.Y + 13) 6 6 $Ink.Warn '' 3 }
    }
    Add-Glyph 12 756 32 32 0xE897 16 $Ink.Text2
    Add-Glyph 52 756 32 32 0xE713 16 $Ink.Text2
}
# 떠 있는 면(메뉴 · 펼침): B.Bg.Raised, 선 1 B.Border.Default, 모서리 8, 그림자 없음
function Add-Raised([double]$X, [double]$Y, [double]$W, [double]$H) { Add-Frame $X $Y $W $H $Ink.Surface $Ink.Border 8 }
# 메뉴. 항목 높이 32, 위아래 4. 항목은 글자 · '-'(구분선) · @{ T; Hover; Sub }. 높이를 돌려준다
function Add-Menu([double]$X, [double]$Y, [double]$W, [object[]]$Items) {
    $h = 8 + @($Items | ForEach-Object { if ($_ -is [string] -and $_ -eq '-') { 9 } else { 32 } } | Measure-Object -Sum).Sum
    Add-Raised $X $Y $W $h
    $iy = $Y + 4
    foreach ($item in $Items) {
        if ($item -is [string] -and $item -eq '-') { Add-Box ($X + 8) ($iy + 4) ($W - 16) 1 $Ink.Muted; $iy += 9; continue }
        $t = if ($item -is [string]) { $item } else { $item.T }
        if ($item -isnot [string] -and $item['Hover']) { Add-Box ($X + 4) $iy ($W - 8) 32 $Ink.Hover '' 4 }
        [void](Add-Line ($X + 12) $iy 32 $t 14 $Ink.Text)
        if ($item -isnot [string] -and $item['Sub']) { Add-Glyph ($X + $W - 28) $iy 16 32 0xE76C 10 $Ink.Text2 }
        $iy += 32
    }
    $h
}

# ---- 가짜 일정 (2026년 11월, 오늘 11월 5일 목요일) --------------------------------------------

function D([string]$Text) { [datetime]::ParseExact($Text, 'yyyy-MM-dd', $inv) }
$month = D '2026-11-01'
$today = D '2026-11-05'
$gridStart = $month.AddDays(-[int]$month.DayOfWeek)
$events = @(
    @{ Title = '서버 이전 작업'; Start = (D '2026-11-03'); Last = (D '2026-11-06'); Memo = 3 }
    @{ Title = 'DR 훈련'; Start = (D '2026-11-13'); Last = (D '2026-11-17') }
    @{ Title = '야간 패치'; Start = (D '2026-11-05'); Last = (D '2026-11-06'); Time = '22:00' }
    @{ Title = '정기 회의'; Start = (D '2026-11-02'); Time = '09:30'; Done = $true }
    @{ Title = '백업 점검'; Start = (D '2026-11-04'); Time = '15:00'; Done = $true }
    @{ Title = '주간 점검'; Start = (D '2026-11-05'); Time = '10:00'; Done = $true }
    @{ Title = 'SRV-01 펌웨어 업데이트'; Start = (D '2026-11-05'); Time = '14:00'; Memo = 2 }
    @{ Title = '월간 보고 준비'; Start = (D '2026-11-05'); Time = '16:00' }
    @{ Title = '스토리지 교체'; Start = (D '2026-11-10'); Time = '14:00' }
    @{ Title = '주간 점검'; Start = (D '2026-11-12'); Time = '10:00' }
    @{ Title = '주간 점검'; Start = (D '2026-11-19'); Time = '10:00' }
    @{ Title = '보안 교육'; Start = (D '2026-11-20'); Time = '10:00' }
    @{ Title = '장애 보고서'; Start = (D '2026-11-24'); Time = '16:00' }
    @{ Title = '주간 점검'; Start = (D '2026-11-26'); Time = '10:00' }
)
foreach ($e in $events) {
    if (-not $e.ContainsKey('Last')) { $e.Last = $e.Start }
    if (-not $e.ContainsKey('Time')) { $e.Time = '' }
    if (-not $e.ContainsKey('Done')) { $e.Done = $false }
    if (-not $e.ContainsKey('Memo')) { $e.Memo = 0 }
}
$records = @(
    @{ Date = (D '2026-11-07'); Kind = 'over'; Text = '업무외 09:00' }
    @{ Date = (D '2026-11-19'); Kind = 'leave'; Text = '휴가' }
)
# 직접 지정한 휴무일. 휴무일 지정 장면(우클릭 전)은 이것을 끈다
$holidays = @(@{ Date = (D '2026-11-27'); Name = '회사 휴무' })
$script:showHolidays = $true

# ---- 일정 달력 카드 (README 8절 일정) ---------------------------------------------------------

$grid = @{ X = 216; Y = 116; W = 744; Rows = 5; RowH = 132 }
$cw = $grid.W / 7
function Get-CellX([int]$Col) { $grid.X + $Col * $cw }
function Get-Holiday([datetime]$Date) { if ($script:showHolidays) { $holidays | Where-Object { $_.Date -eq $Date } | Select-Object -First 1 } }

function Add-Chip([double]$X, [double]$Y, $Item, [bool]$Plain) {
    $w = $cw - 8
    if ($Item.ContainsKey('Kind')) {
        $bg = if ($Item.Kind -eq 'leave') { $Ink.LeaveBg } else { $Ink.OverBg }
        $fg = if ($Item.Kind -eq 'leave') { $Ink.LeaveText } else { $Ink.OverText }
        Add-Box ($X + 4) $Y $w 20 $bg '' 2
        [void](Add-Line ($X + 8) $Y 20 $Item.Text 12 $fg -Max ($w - 8))
        return
    }
    Add-Box ($X + 4) $Y $w 20 $(if ($Plain) { $Ink.Surface } else { $Ink.Subtle }) '' 2
    $tx = $X + 8; $fg = $Ink.Text
    if ($Item.Done) { Add-Glyph $tx $Y 10 20 0xE73E 10 $Ink.Text3; $tx += 14; $fg = $Ink.Text3 }
    $label = if ($Item.Time) { "$($Item.Time) $($Item.Title)" } else { $Item.Title }
    [void](Add-Line $tx $Y 20 $label 12 $fg -Max ($X + $w - $tx))
}
# 여러 날 막대: 흰 바탕 + 1 B.Border.Default. 주를 넘는 쪽은 열어 두고, 새 주의 첫 칸에 제목을 다시 쓴다
function Add-Bar($Seg, [double]$RowY) {
    $x1 = (Get-CellX $Seg.A) + $(if ($Seg.FromPrev) { 0 } else { 4 })
    $x2 = (Get-CellX ($Seg.B + 1)) - $(if ($Seg.ToNext) { 0 } else { 4 })
    $y = $RowY + 30 + $Seg.Lane * 22
    if (-not $Seg.FromPrev -and -not $Seg.ToNext) { Add-Frame $x1 $y ($x2 - $x1) 20 $Ink.Surface $Ink.Border 2 }
    else {
        Add-Box $x1 $y ($x2 - $x1) 20 $Ink.Surface
        Add-Box $x1 $y ($x2 - $x1) 1 $Ink.Border; Add-Box $x1 ($y + 19) ($x2 - $x1) 1 $Ink.Border
        if (-not $Seg.FromPrev) { Add-Box $x1 $y 1 20 $Ink.Border }
        if (-not $Seg.ToNext) { Add-Box ($x2 - 1) $y 1 20 $Ink.Border }
    }
    $e = $Seg.E; $tx = $x1 + 4; $fg = $Ink.Text
    if ($e.Done) { Add-Glyph $tx $y 10 20 0xE73E 10 $Ink.Text3; $tx += 14; $fg = $Ink.Text3 }
    $label = if ($e.Time -and -not $Seg.FromPrev) { "$($e.Time) $($e.Title)" } else { $e.Title }
    [void](Add-Line $tx $y 20 $label 12 $fg -Max ($x2 - 4 - $tx))
}

# 머리줄: 「2026년 11월 ⌄」(누르면 달 고르기, 그 안에 「오늘」). ‹ 오늘 ›는 3단계 표 보기에 둔다
function Add-MonthHeader([switch]$Open) {
    $tw = Measure-Text '2026년 11월' 20
    $bw = 8 + $tw + 4 + 16 + 8
    if ($Open) { Add-Box 216 44 $bw 32 $Ink.Hover '' 4 }
    [void](Add-Line 224 32 56 '2026년 11월' 20 $Ink.Text)
    Add-Glyph (224 + $tw + 4) 44 16 32 0xE70D 12 $Ink.Text2
}

function Add-MonthCard([switch]$TitleOpen) {
    Add-Box 200 32 776 760 $Ink.Surface '' 8
    Add-MonthHeader -Open:$TitleOpen
    $names = '일', '월', '화', '수', '목', '금', '토'
    for ($c = 0; $c -lt 7; $c++) {
        $color = if ($c -eq 0) { $Ink.Sunday } elseif ($c -eq 6) { $Ink.Saturday } else { $Ink.Text3 }
        [void](Add-Text ((Get-CellX $c) + 8) 94 $names[$c] 12 $color)
    }
    $bottom = $grid.Y + $grid.Rows * $grid.RowH
    $plain = @{}
    for ($i = 0; $i -lt $grid.Rows * 7; $i++) {
        $date = $gridStart.AddDays($i); $col = $i % 7; $row = [math]::Floor($i / 7)
        $leave = @($records | Where-Object { $_.Date -eq $date -and $_.Kind -eq 'leave' }).Count
        $dayOff = $col -eq 0 -or $col -eq 6 -or $leave -or (Get-Holiday $date)
        $plain[$i] = [bool]($dayOff -or $date -eq $today)
        $bg = if ($date -eq $today) { $Ink.Selected } elseif ($dayOff) { $Ink.Subtle } else { $Ink.Surface }
        Add-Box (Get-CellX $col) ($grid.Y + $row * $grid.RowH) $cw $grid.RowH $bg
    }
    Add-Box $grid.X $grid.Y $grid.W 1 $Ink.Muted
    for ($r = 1; $r -lt $grid.Rows; $r++) { Add-Box $grid.X ($grid.Y + $r * $grid.RowH) $grid.W 1 $Ink.Muted }
    for ($c = 1; $c -lt 7; $c++) { Add-Box ([math]::Floor((Get-CellX $c))) $grid.Y 1 ($bottom - $grid.Y) $Ink.Muted }
    for ($i = 0; $i -lt $grid.Rows * 7; $i++) {
        $date = $gridStart.AddDays($i); $col = $i % 7; $row = [math]::Floor($i / 7)
        $x = Get-CellX $col; $y = $grid.Y + $row * $grid.RowH
        $isToday = $date -eq $today; $inMonth = $date.Month -eq $month.Month
        $kinds = @($records | Where-Object { $_.Date -eq $date } | ForEach-Object Kind)
        $holiday = Get-Holiday $date
        $kind = if ($kinds -contains 'over') { 'over' } elseif ($kinds -contains 'leave') { 'leave' } elseif ($holiday) { 'off' } else { '' }
        $circle = if ($isToday) { $Ink.Accent } elseif (-not $inMonth) { '' } else { switch ($kind) { 'over' { $Ink.OverBg }; 'leave' { $Ink.LeaveBg }; 'off' { $Ink.OffBg }; default { '' } } }
        if ($circle) { Add-Box ($x + 4) ($y + 6) 24 24 $circle '' 12 }
        $num = if ($isToday) { $Ink.OnAccent } elseif (-not $inMonth) { $Ink.Off } elseif ($kind -eq 'over') { $Ink.OverText } elseif ($kind -eq 'leave') { $Ink.LeaveText } elseif ($kind -eq 'off') { $Ink.Sunday } elseif ($col -eq 0) { $Ink.Sunday } elseif ($col -eq 6) { $Ink.Saturday } else { $Ink.Text }
        Add-Center ($x + 4) ($y + 6) 24 24 ([string]$date.Day) 14 $num $isToday
        # 휴무일 이름은 날짜 오른쪽(머리 줄 안)에 둔다. 날짜 아래에 두면 그 칸만 칩이 내려가 여러 날 막대가 어긋난다
        if ($holiday) { [void](Add-Line ($x + 34) ($y + 6) 24 $holiday.Name 12 $Ink.Sunday -Max ($cw - 38)) }
    }
    # 주마다 여러 날 일정의 줄(lane)을 정하고, 남은 자리에 근태 기록 → 하루 일정 순으로 칩을 놓는다
    $multi = @($events | Where-Object { $_.Last -gt $_.Start } | Sort-Object { $_.Start }, { -(($_.Last - $_.Start).Days) })
    for ($row = 0; $row -lt $grid.Rows; $row++) {
        $ws = $gridStart.AddDays($row * 7); $we = $ws.AddDays(6); $rowY = $grid.Y + $row * $grid.RowH
        $taken = @{}
        $segments = @(foreach ($e in $multi) {
                if ($e.Last -lt $ws -or $e.Start -gt $we) { continue }
                $a = [math]::Max(0, ($e.Start - $ws).Days); $b = [math]::Min(6, ($e.Last - $ws).Days)
                $lane = 0
                while ($true) {
                    $free = $true
                    for ($c = $a; $c -le $b; $c++) { if ($taken.ContainsKey("$c|$lane")) { $free = $false } }
                    if ($free) { break }
                    $lane++
                }
                for ($c = $a; $c -le $b; $c++) { $taken["$c|$lane"] = $true }
                @{ E = $e; A = $a; B = $b; Lane = $lane; FromPrev = $e.Start -lt $ws; ToNext = $e.Last -gt $we }
            })
        for ($c = 0; $c -lt 7; $c++) {
            $date = $ws.AddDays($c); $x = Get-CellX $c
            $free = @(0, 1 | Where-Object { -not $taken.ContainsKey("$c|$_") })
            $hidden = @($segments | Where-Object { $_.A -le $c -and $_.B -ge $c -and $_.Lane -ge 2 }).Count
            $items = @(@($records | Where-Object { $_.Date -eq $date }) + @($events | Where-Object { $_.Last -eq $_.Start -and $_.Start -eq $date } | Sort-Object { $_.Time }))
            $shown = [math]::Min($free.Count, $items.Count)
            for ($k = 0; $k -lt $shown; $k++) { Add-Chip $x ($rowY + 30 + $free[$k] * 22) $items[$k] $plain[$row * 7 + $c] }
            $more = $items.Count - $shown + $hidden
            if ($more -gt 0) { [void](Add-Line ($x + 8) ($rowY + 74) 16 "+$more" 12 $Ink.Text3) }
        }
        foreach ($s in @($segments | Where-Object { $_.Lane -lt 2 })) { Add-Bar $s $rowY }
    }
    $sel = ($today - $gridStart).Days
    Add-Frame (Get-CellX ($sel % 7)) ($grid.Y + [math]::Floor($sel / 7) * $grid.RowH) ($cw + 1) ($grid.RowH + 1) '' $Ink.Accent
}

# 달 고르기: 제목 아래에 뜨는 펼침 면. 위 줄 ‹ 2026년 ›, 아래 4 × 3 달 칸(60 × 44, 사이 4). 보고 있는 달은 강조색
function Add-MonthPicker([double]$X, [double]$Y) {
    $w = 12 + 4 * 60 + 3 * 4 + 12; $h = 44 + 3 * 44 + 2 * 4 + 12 + 32
    Add-Raised $X $Y $w $h
    Add-Glyph ($X + 8) ($Y + 8) 28 28 0xE76B 16 $Ink.Text2
    Add-Center $X ($Y + 8) $w 28 '2026년' 14 $Ink.Text $true
    Add-Glyph ($X + $w - 36) ($Y + 8) 28 28 0xE76C 16 $Ink.Text2
    for ($m = 1; $m -le 12; $m++) {
        $cx = $X + 12 + (($m - 1) % 4) * 64; $cy = $Y + 44 + [math]::Floor(($m - 1) / 4) * 48
        if ($m -eq 11) { Add-Box $cx $cy 60 44 $Ink.Accent '' 4; Add-Center $cx $cy 60 44 "${m}월" 14 $Ink.OnAccent $true }
        else { Add-Center $cx $cy 60 44 "${m}월" 14 $Ink.Text }
    }
    [void](Add-Line ($X + 12) ($Y + $h - 38) 28 '오늘' 12 $Ink.Accent)
}

# ---- 오른쪽 사이드바 -------------------------------------------------------------------------

function Add-SideCard([string]$Title = '11월 5일 목요일') {
    Add-Box 984 32 288 760 $Ink.Surface '' 8
    Add-Glyph 992 46 28 28 0xE76C 16 $Ink.Text2
    [void](Add-Line 1023 32 56 $Title 16 $Ink.Text $true)
    Add-Glyph 1236 46 28 28 0xE710 16 $Ink.Text2
}
# 일정 줄: 체크 상자 16 · 간격 10 · 시각 칸 64 · 제목. 여러 날 일정은 둘째 줄에 기간을 쓴다. 다음 줄의 Y를 돌려준다
function Add-EventRow([double]$Y, [string]$When, [string]$Title, [bool]$Done, [int]$Memo = 0, [string]$Sub = '') {
    $line = if ($Sub) { $Y + 4 } else { $Y + 6 }
    Add-Check 1000 ($line + 2) $Done
    [void](Add-Line 1026 $line 20 $When 12 $Ink.Text3)
    $right = 1256
    if ($Memo) {
        $nw = Add-Line $right $line 20 ([string]$Memo) 12 $Ink.Text3 -Right
        Add-Glyph ($right - $nw - 16) $line 12 20 0xE70B 12 $Ink.Text3
        $right -= $nw + 24
    }
    [void](Add-Line 1090 $line 20 $Title 14 $(if ($Done) { $Ink.Text3 } else { $Ink.Text }) -Max ($right - 1090))
    if ($Sub) { [void](Add-Line 1090 ($Y + 26) 16 $Sub 12 $Ink.Text3 -Max (1256 - 1090)) }
    $Y + $(if ($Sub) { 48 } else { 32 })
}
function Add-DayList([switch]$Memo) {
    # -Memo: 2단계 시안. 줄 끝에 관련 메모 수(메모 아이콘 12 + 숫자)
    $y = 88
    $y = Add-EventRow $y '하루 종일' '서버 이전 작업' $false 0 '11월 3일 ~ 6일 · 3일째'
    $y = Add-EventRow $y '10:00' '주간 점검' $true $(if ($Memo) { 2 } else { 0 })
    $y = Add-EventRow $y '14:00' 'SRV-01 펌웨어 업데이트' $false $(if ($Memo) { 1 } else { 0 })
    $y = Add-EventRow $y '16:00' '월간 보고 준비' $false
    $y = Add-EventRow $y '22:00' '야간 패치' $false 0 '~ 11월 6일 02:00'
    $y += 16
    $tw = Add-Line 1000 $y 32 '루틴' 14 $Ink.Text $true
    [void](Add-Line (1000 + $tw + 8) $y 32 '0/1' 14 $Ink.Text3)
    $y += 32
    Add-Check 1000 ($y + 6) $false
    [void](Add-Line 1026 $y 28 '17:00 장비실 온도 확인' 14 $Ink.Text)
    $pw = Add-Line 1256 $y 28 '0/5' 12 $Ink.Text3 -Right
    if ($Memo) {
        $nx = 1256 - $pw - 12
        $nw = Add-Line $nx $y 28 '1' 12 $Ink.Text3 -Right
        Add-Glyph ($nx - $nw - 16) $y 12 28 0xE70B 12 $Ink.Text3
    }
}

# ---- 설정 → 휴무일 ---------------------------------------------------------------------------

function Add-SettingsHolidays {
    Add-Box 0 0 1280 800 $Ink.Canvas
    Add-TitleBar 0 0 1280 'WorkTool'
    Add-Nav -NoSelect
    [void](Add-Line 208 40 36 '설정' 20 $Ink.Text)
    $tx = 208
    foreach ($tab in '일반', '업무시간', '휴무일', '탭', '데이터') {
        $w = (Measure-Text $tab 14) + 24
        if ($tab -eq '휴무일') { Add-Box $tx 84 $w 36 $Ink.Surface; Add-Box $tx 84 $w 2 $Ink.Accent }
        [void](Add-Line ($tx + 12) 84 36 $tab 14 $(if ($tab -eq '휴무일') { $Ink.Text } else { $Ink.Text2 }))
        $tx += $w
    }
    Add-Box 200 120 1072 672 $Ink.Surface '' 8
    # 공휴일 자동 계산
    [void](Add-Line 220 136 32 '공휴일' 14 $Ink.Text2)
    Add-Check 300 144 $true
    $lw = Add-Line 326 136 32 '자동으로 넣기' 14 $Ink.Text
    [void](Add-Line (326 + $lw + 12) 136 32 '설 · 추석 · 대체공휴일 포함' 12 $Ink.Text3)
    # 해 이동 + 추가
    Add-Glyph 220 182 28 28 0xE76B 16 $Ink.Text2
    $yw = Add-Line 252 180 32 '2026년' 14 $Ink.Text $true
    Add-Glyph (252 + $yw + 4) 182 28 28 0xE76C 16 $Ink.Text2
    [void](Add-Btn 820 180 '휴무일 추가' -Right)
    # 표 (README 7절): 머리 32 · 행 32, 셀 좌우 12
    $cols = @(@{ T = '날짜'; X = 220 }, @{ T = '요일'; X = 330 }, @{ T = '이름'; X = 380 }, @{ T = '종류'; X = 590 }, @{ T = '넣은 곳'; X = 710 })
    foreach ($col in $cols) { [void](Add-Line ($col.X + 12) 228 32 $col.T 12 $Ink.Text3) }
    Add-Box 220 259 600 1 $Ink.Border
    $rows = @(
        @('1월 1일', '목', '신정', '공휴일', '자동'), @('2월 16일', '월', '설날 연휴', '공휴일', '자동'), @('2월 17일', '화', '설날', '공휴일', '자동'),
        @('2월 18일', '수', '설날 연휴', '공휴일', '자동'), @('3월 1일', '일', '삼일절', '공휴일', '자동'), @('3월 2일', '월', '대체공휴일 (삼일절)', '공휴일', '자동'),
        @('5월 5일', '화', '어린이날', '공휴일', '자동'), @('5월 24일', '일', '부처님오신날', '공휴일', '자동'), @('5월 25일', '월', '대체공휴일 (부처님오신날)', '공휴일', '자동'),
        @('6월 3일', '수', '지방선거', '공휴일', '직접'), @('6월 6일', '토', '현충일', '공휴일', '자동'), @('8월 15일', '토', '광복절', '공휴일', '자동'),
        @('8월 17일', '월', '대체공휴일 (광복절)', '공휴일', '자동'), @('9월 24일', '목', '추석 연휴', '공휴일', '자동'), @('9월 25일', '금', '추석', '공휴일', '자동'),
        @('9월 26일', '토', '추석 연휴', '공휴일', '자동')
    )
    $ry = 260
    foreach ($r in $rows) {
        for ($k = 0; $k -lt 5; $k++) {
            $color = if ($k -eq 1 -or $k -ge 3) { $Ink.Text2 } else { $Ink.Text }
            $size = if ($k -eq 1 -or $k -ge 3) { 12 } else { 14 }
            [void](Add-Line ($cols[$k].X + 12) $ry 32 $r[$k] $size $color)
        }
        Add-Box 220 ($ry + 31) 600 1 $Ink.Muted
        $ry += 32
    }
}

# ---- 2단계: 일정 ↔ 메모 연결 -----------------------------------------------------------------

# 편집 폼 칸: 라벨 F.Body · B.Text.Secondary, 아래 8, 칸 32, 필드 사이 12. 다음 필드 Y를 돌려준다
function Add-FormField([double]$Y, [string]$Label, [string]$Value, [switch]$Combo) {
    [void](Add-Line 1000 $Y 20 $Label 14 $Ink.Text2)
    Add-Input 1000 ($Y + 28) 256 $Value -Combo:$Combo
    $Y + 72
}
# 「시작 ~ 끝」 두 칸 한 줄. ~는 좌우 8
function Add-FormRange([double]$Y, [string]$Label, [string]$From, [string]$To) {
    [void](Add-Line 1000 $Y 20 $Label 14 $Ink.Text2)
    $dw = Measure-Text '~' 14
    $iw = (256 - 16 - $dw) / 2
    Add-Input 1000 ($Y + 28) $iw $From
    [void](Add-Line (1000 + $iw + 8) ($Y + 28) 32 '~' 14 $Ink.Text2)
    Add-Input (1000 + $iw + 16 + $dw) ($Y + 28) $iw $To
    $Y + 72
}
# 기본 버튼 + 펼침 표시(ChevronDown 10). 폭을 돌려준다. -Open이면 누른 상태(메뉴가 열림)
function Add-DropBtn([double]$X, [double]$Y, [string]$Text, [switch]$Open) {
    $tw = Measure-Text $Text 14
    $w = 12 + $tw + 8 + 10 + 12
    Add-Frame $X $Y $w 32 $(if ($Open) { $Ink.Hover } else { $Ink.Surface }) $Ink.Strong 4
    [void](Add-Line ($X + 12) $Y 32 $Text 14 $Ink.Text)
    Add-Glyph ($X + 12 + $tw + 8) $Y 10 32 0xE70D 10 $Ink.Text2
    $w
}
# 관련 메모 줄(32): 메모 아이콘 16 · 제목 F.Body · 오른쪽 끝 붙은 범위 F.Caption · B.Text.Tertiary. 지운 메모는 흐리게
function Add-MemoLinkRow([double]$Y, [string]$Title, [string]$Scope, [switch]$Missing, [switch]$Hover) {
    if ($Hover) { Add-Box 1000 $Y 256 32 $Ink.Hover '' 4 }
    $fg = if ($Missing) { $Ink.Off } else { $Ink.Text }
    Add-Glyph 1008 $Y 16 32 0xE70B 16 $(if ($Missing) { $Ink.Off } else { $Ink.Text2 })
    $sw = Add-Line 1248 $Y 32 $Scope 12 $Ink.Text3 -Right
    [void](Add-Line 1032 $Y 32 $Title 14 $fg -Max (1248 - $sw - 8 - 1032))
}
# 일정 편집 폼(반복 일정 「주간 점검」 11월 5일 회차) + 맨 아래 관련 메모. [새 메모] 단추의 Y를 돌려준다
function Add-EventForm([switch]$NewOpen, [switch]$RowHover) {
    $y = 88
    $y = Add-FormField $y '제목' '주간 점검'
    $y = Add-FormRange $y '날짜' '2026-11-05' '2026-11-05'
    Add-Check 1000 ($y + 2) $false
    [void](Add-Line 1026 $y 20 '하루 종일' 14 $Ink.Text)
    $y += 32
    $y = Add-FormRange $y '시각' '10:00' '10:30'
    $y = Add-FormField $y '반복' '매주' -Combo
    $y = Add-FormField $y '끝나는 날' ''
    $y = Add-FormField $y '알람' '10분 전' -Combo
    $lw = Add-Line 1000 $y 20 '관련 메모' 14 $Ink.Text2
    [void](Add-Line (1000 + $lw + 8) $y 20 '2' 14 $Ink.Text3)
    $y += 28
    Add-MemoLinkRow $y '11-05 주간 점검' '이 회차'; $y += 32
    Add-MemoLinkRow $y '주간 점검 절차' '모든 회차' -Hover:$RowHover; $y += 32
    Add-MemoLinkRow $y '옛 점검 메모' '지운 메모' -Missing; $y += 32
    $y += 8
    $nw = Add-DropBtn 1000 $y '새 메모' -Open:$NewOpen
    [void](Add-Btn (1000 + $nw + 8) $y '기존 메모 고르기')
    # 아래 단추 줄: 삭제 | 저장(주) · 취소 (지금 폼과 같음)
    [void](Add-Btn 1000 744 '삭제')
    $cancelW = Add-Btn 1256 744 '취소' -Right
    [void](Add-Btn (1256 - $cancelW - 8) 744 '저장' 'primary' -Right)
    $y
}
# 루틴 편집 폼(시간마다) + 맨 아래 관련 메모. 루틴은 날짜마다 따로 붙이지 않고 늘 모든 날이라 범위 글자가 없다
function Add-RoutineForm {
    $y = 88
    $y = Add-FormField $y '제목' '장비실 온도 확인'
    $y = Add-FormField $y '주기' '시간마다' -Combo
    $y = Add-FormField $y '간격 시간' '2'
    $y = Add-FormField $y '시작' '09:00'
    $y = Add-FormField $y '끝 시각' '17:00'
    Add-Check 1000 ($y + 2) $true
    [void](Add-Line 1026 $y 20 '근무 요일만' 14 $Ink.Text)
    $y += 32
    $lw = Add-Line 1000 $y 20 '관련 메모' 14 $Ink.Text2
    [void](Add-Line (1000 + $lw + 8) $y 20 '1' 14 $Ink.Text3)
    $y += 28
    Add-MemoLinkRow $y '장비실 온도 기록 방법' ''; $y += 32
    $y += 8
    $nw = Add-DropBtn 1000 $y '새 메모'
    [void](Add-Btn (1000 + $nw + 8) $y '기존 메모 고르기')
    [void](Add-Btn 1000 744 '삭제')
    $cancelW = Add-Btn 1256 744 '취소' -Right
    [void](Add-Btn (1256 - $cancelW - 8) 744 '저장' 'primary' -Right)
}
# 기존 메모 고르기: New-WtModal(폭 480, 안쪽 24, 제목 F.Subtitle) 위에 찾기 칸 + 두 줄 목록(48) + [붙이기] [취소]
function Add-PickDialog([double]$X, [double]$Y) {
    $w = 480; $listH = 5 * 48 + 2
    $h = 24 + 24 + 12 + 32 + 8 + $listH + 24 + 32 + 24
    Add-Raised $X $Y $w $h
    [void](Add-Line ($X + 24) ($Y + 24) 24 '메모 고르기' 16 $Ink.Text $true)
    # 찾기 칸(포커스: 2 B.Accent), 찾기 아이콘 14 왼쪽 10, 글자 왼쪽 32
    $sy = $Y + 60
    Add-Box ($X + 25) ($sy + 1) 430 30 $Ink.Surface $Ink.Accent 4 2
    Add-Glyph ($X + 34) $sy 14 32 0xE721 14 $Ink.Text2
    [void](Add-Line ($X + 56) $sy 32 '점검' 14 $Ink.Text)
    # 목록: 1 B.Border.Default 테두리, 줄 48(제목 F.Body + 수정일 · 미리보기 F.Caption), 줄 사이 1 B.Border.Muted
    $ly = $sy + 40
    Add-Frame ($X + 24) $ly 432 $listH $Ink.Surface $Ink.Border 4
    $rows = @(
        @{ T = '주간 점검 절차'; S = '10월 28일 · 백업 작업 결과 확인, 디스크 사용량 확인'; Linked = $true }
        @{ T = '스토리지 점검 절차'; S = '10월 2일 · 1. 관리 콘솔에 접속한다'; Sel = $true }
        @{ T = '분기 점검 결과'; S = '9월 30일 · 요약: 디스크 교체 2건' }
        @{ T = '장비실 점검 기록'; S = '9월 12일 · 온도 · 습도 · 누수 감지기' }
        @{ T = '점검 일정 메모'; S = '8월 20일 · 다음 분기 점검 날짜 후보' }
    )
    $ry = $ly + 1
    foreach ($r in $rows) {
        if ($r['Sel']) { Add-Box ($X + 25) $ry 430 48 $Ink.Selected; Add-Box ($X + 25) ($ry + 16) 3 16 $Ink.Accent '' 1.5 }
        $right = $X + 444
        if ($r['Linked']) { $right -= (Add-Line $right ($ry + 6) 20 '붙어 있음' 12 $Ink.Text3 -Right) + 8 }
        [void](Add-Line ($X + 37) ($ry + 6) 20 $r.T 14 $(if ($r['Linked']) { $Ink.Text3 } else { $Ink.Text }) -Max ($right - $X - 37))
        [void](Add-Line ($X + 37) ($ry + 26) 16 $r.S 12 $Ink.Text3 -Max (444 - 37))
        if ($r -ne $rows[-1]) { Add-Box ($X + 25) ($ry + 47) 430 1 $Ink.Muted }
        $ry += 48
    }
    $by = $Y + $h - 24 - 32
    $cancelW = Add-Btn ($X + 456) $by '취소' -Right
    [void](Add-Btn ($X + 456 - $cancelW - 8) $by '붙이기' 'primary' -Right)
}
# 메모 새 창(읽기 보기). 창 틀은 앱 창과 같은 32 제목 줄, 도구 줄 40(왼쪽 보기 표시, 오른쪽 [메모 탭에서 열기]),
# 본문은 창 바탕 위 흰 카드(가장자리 8, 글 왼쪽 44). 블록: @{ K = 'h1'|'h2'|'meta'|'task'|'p'; T; Done; Tag }
function Add-ReadWindow([double]$X, [double]$Y, [double]$W, [double]$H, [string]$Title, [object[]]$Blocks) {
    Add-Frame $X $Y $W $H $Ink.Canvas $Ink.Border 8
    Add-Box ($X + 12) ($Y + 8) 16 16 $Ink.Accent '' 4
    Add-Center ($X + 12) ($Y + 8) 16 16 'W' 10 $Ink.OnAccent $true
    [void](Add-Line ($X + 36) $Y 32 $Title 12 $Ink.Text2 -Max ($W - 36 - 92 - 8))
    Add-Glyph ($X + $W - 92) $Y 46 32 0xE922 10 $Ink.Text2
    Add-Glyph ($X + $W - 46) $Y 46 32 0xE8BB 10 $Ink.Text2
    Add-Glyph ($X + 16) ($Y + 32) 16 40 0xE736 16 $Ink.Text2
    [void](Add-Line ($X + 40) ($Y + 32) 40 '읽기 보기' 12 $Ink.Text3)
    [void](Add-Btn ($X + $W - 8) ($Y + 36) '메모 탭에서 열기' -Right)
    Add-Box ($X + 8) ($Y + 76) ($W - 16) ($H - 84) $Ink.Surface '' 8
    $bx = $X + 8 + 44; $by = $Y + 76 + 24
    foreach ($b in $Blocks) {
        switch ($b.K) {
            'h1' { [void](Add-Line $bx $by 32 $b.T 24 $Ink.Text $true); $by += 36 }
            'meta' {
                $mw = Add-Line $bx $by 20 $b.T 12 $Ink.Text3
                if ($b['Tag']) {
                    $tw = (Measure-Text $b.Tag 12) + 16
                    Add-Box ($bx + $mw + 12) $by $tw 20 $Ink.Selected '' 4
                    [void](Add-Line ($bx + $mw + 20) $by 20 $b.Tag 12 $Ink.Accent)
                }
                $by += 36
            }
            'h2' { $by += 8; [void](Add-Line $bx $by 26 $b.T 18 $Ink.Text $true); $by += 34 }
            'task' {
                Add-Check $bx ($by + 6) ([bool]$b['Done'])
                [void](Add-Line ($bx + 26) $by 28 $b.T 15 $(if ($b['Done']) { $Ink.Text3 } else { $Ink.Text }))
                $by += 28
            }
            'p' { $by += 8; [void](Add-Line $bx $by 24 $b.T 15 $Ink.Text); $by += 24 }
        }
    }
}

# ---- 화면 짜기 -------------------------------------------------------------------------------

function Add-MainWindow([switch]$TitleOpen) {
    Add-Box 0 0 1280 800 $Ink.Canvas
    Add-TitleBar 0 0 1280 'WorkTool'
    Add-Nav
    Add-MonthCard -TitleOpen:$TitleOpen
    Add-SideCard
}

$list = Use-Scene
Add-MainWindow
Add-DayList

$picker = Use-Scene
Add-MainWindow -TitleOpen
Add-DayList
Add-MonthPicker 216 80

# 우클릭 직전: 11월 27일은 아직 휴무일이 아니다
$script:showHolidays = $false
$menu = Use-Scene
Add-MainWindow
Add-DayList
[void](Add-Menu 792 560 200 @('새 일정', '새 루틴', '-', @{ T = '휴무일로 지정'; Hover = $true; Sub = $true }))
[void](Add-Menu 988 633 160 @('회사 휴무', '개인 휴무'))
$script:showHolidays = $true

$settings = Use-Scene
Add-SettingsHolidays

# ---- 2단계 장면: 일정 ↔ 메모 연결 ---------------------------------------------------------------

$memoList = Use-Scene
Add-MainWindow
Add-DayList -Memo

$memoForm = Use-Scene
Add-MainWindow
[void](Add-EventForm)

$memoNew = Use-Scene
Add-MainWindow
$newY = Add-EventForm -NewOpen
[void](Add-Menu 1000 ($newY + 36) 160 @(@{ T = '빈 메모'; Hover = $true }, '통화 메모'))

$memoRow = Use-Scene
Add-MainWindow
[void](Add-EventForm -RowHover)
[void](Add-Menu 1064 640 184 @('새 창으로 보기', '메모 탭에서 열기', '-', '연결 빼기'))

$memoRoutine = Use-Scene
Add-MainWindow
Add-RoutineForm

$memoPick = Use-Scene
Add-MainWindow
[void](Add-EventForm)
Add-PickDialog 400 180

$memoWindow = Use-Scene
Add-MainWindow
[void](Add-EventForm)
Add-ReadWindow 232 96 640 560 '주간 점검 절차' @(
    @{ K = 'h1'; T = '주간 점검 절차' }, @{ K = 'meta'; T = '수정일 10월 28일'; Tag = '#점검' }
    @{ K = 'task'; T = '백업 작업 결과 확인'; Done = $true }, @{ K = 'task'; T = '디스크 사용량 확인 (SRV-01 · SRV-02)'; Done = $true }
    @{ K = 'task'; T = '장비실 온도 기록' }, @{ K = 'task'; T = '보안 패치 목록 확인' }
    @{ K = 'h2'; T = '참고' }, @{ K = 'p'; T = '결과는 \\NAS-01\점검 폴더에 저장합니다.' }
)

$memoCall = Use-Scene
Add-MainWindow
Add-DayList -Memo
Add-ReadWindow 232 120 640 440 '11-05 SRV-01 펌웨어 업데이트' @(
    @{ K = 'h1'; T = '11-05 SRV-01 펌웨어 업데이트' }, @{ K = 'meta'; T = '수정일 오늘 13:52' }
    @{ K = 'h2'; T = '통화: <상대> · SRV-01 펌웨어 업데이트' }
    @{ K = 'task'; T = '할 말 1' }, @{ K = 'task'; T = '할 말 2' }
    @{ K = 'p'; T = '들은 것:' }, @{ K = 'p'; T = '다음 할 일:' }
)

# ---- 3단계: 찾기 · 표 · 루틴 보기 ---------------------------------------------------------------

# 머리줄 오른쪽(카드 안 오른쪽 끝 960): 찾기 칸(높이 28, 폭 200) · 간격 4 · 깔때기(28) · 간격 8 · 보기 전환.
# 보기 전환 [할 일 n | 달력 | 표 | 루틴]은 메모 탭 모양: 높이 28 · 모서리 4 · 사이 4, 고른 것 = B.Fill.Hover.Surface + 아래 2 B.Accent(좌우 8을 뺀 폭).
# 아이콘 칸은 28 × 28(툴팁 「달력 보기」 · 「표 보기」 · 「루틴 보기」), 숫자는 안 끝낸 「할 일」 수(F.Caption · B.Text.Tertiary)
function Add-ViewSwitch([string]$View, [string]$Query = '', [switch]$FilterOpen) {
    $y = 46
    $items = @(
        @{ Id = 'due'; Text = '할 일'; Count = '9' }
        @{ Id = 'calendar'; Icon = 0xE787 }
        @{ Id = 'table'; Icon = 0xE8FD }
        @{ Id = 'routines'; Icon = 0xE8EE }
    )
    foreach ($it in $items) { $it.W = if ($it['Icon']) { 28 } else { 12 + (Measure-Text $it.Text 14) + 6 + (Measure-Text $it.Count 12) + 12 } }
    $total = (@($items | ForEach-Object { $_.W }) | Measure-Object -Sum).Sum + 4 * ($items.Count - 1)
    $x = 960 - $total; $left = $x
    foreach ($it in $items) {
        $on = $it.Id -eq $View
        if ($on) { Add-Box $x $y $it.W 28 $Ink.Hover '' 4; Add-Box ($x + 8) ($y + 26) ($it.W - 16) 2 $Ink.Accent }
        $fg = if ($on) { $Ink.Text } else { $Ink.Text2 }
        if ($it['Icon']) { Add-Glyph $x $y 28 28 $it.Icon 16 $fg }
        else {
            $tw = Add-Line ($x + 12) $y 28 $it.Text 14 $fg
            [void](Add-Line ($x + 12 + $tw + 6) $y 28 $it.Count 12 $Ink.Text3)
        }
        $x += $it.W + 4
    }
    $fx = $left - 8 - 28
    if ($FilterOpen) { Add-Box $fx $y 28 28 $Ink.Hover '' 4 }
    Add-Glyph $fx $y 28 28 0xE71C 16 $Ink.Text2
    $sw = 200; $sx = $fx - 4 - $sw
    if ($Query) { Add-Box ($sx + 1) ($y + 1) ($sw - 2) 26 $Ink.Surface $Ink.Accent 4 2 } else { Add-Frame $sx $y $sw 28 $Ink.Surface $Ink.Control 4 }
    Add-Glyph ($sx + 10) $y 14 28 0xE721 14 $Ink.Text3
    if ($Query) { [void](Add-Line ($sx + 32) $y 28 $Query 14 $Ink.Text -Max ($sw - 42)) } else { [void](Add-Line ($sx + 32) $y 28 '찾기' 14 $Ink.Text3) }
    $fx
}
# 머리줄 왼쪽. -Month: 「2026년 11월 ⌄」(달력 · 표), -Nav: 그 뒤 간격 12에 ‹ 오늘 ›(표 보기에만, 아이콘 28 · 오늘 Btn 높이 28 · 사이 4).
# 그 밖의 보기는 제목 F.Title + 간격 8 + 개수(같은 크기, B.Text.Tertiary)
function Add-ViewTitle([string]$Title, [string]$Count = '', [switch]$Month, [switch]$Nav) {
    if ($Month) {
        Add-MonthHeader
        if ($Nav) {
            $x = 224 + (Measure-Text '2026년 11월' 20) + 28 + 12
            Add-Glyph $x 46 28 28 0xE76B 16 $Ink.Text2
            $bw = (Measure-Text '오늘' 14) + 24
            Add-Frame ($x + 32) 46 $bw 28 $Ink.Surface $Ink.Strong 4
            [void](Add-Line ($x + 44) 46 28 '오늘' 14 $Ink.Text)
            Add-Glyph ($x + 36 + $bw) 46 28 28 0xE76C 16 $Ink.Text2
        }
        return
    }
    $tw = Add-Line 224 32 56 $Title 20 $Ink.Text
    if ($Count) { [void](Add-Line (224 + $tw + 8) 32 56 $Count 20 $Ink.Text3) }
}
function Add-ViewWindow {
    Add-Box 0 0 1280 800 $Ink.Canvas
    Add-TitleBar 0 0 1280 'WorkTool'
    Add-Nav
    Add-Box 200 32 776 760 $Ink.Surface '' 8
    Add-SideCard
}
# 3단계 사이드바: 고른 날 일정 + 루틴. 루틴은 시각이 생겨 「09:00 메일 확인」처럼 쓰고 시각순으로 놓는다(시간마다 루틴은 다음 차례)
function Add-DayListV3 {
    $y = 88
    $y = Add-EventRow $y '하루 종일' '서버 이전 작업' $false 3 '11월 3일 ~ 6일 · 3일째'
    $y = Add-EventRow $y '10:00' '주간 점검' $true 2
    $y = Add-EventRow $y '14:00' 'SRV-01 펌웨어 업데이트' $false 1
    $y = Add-EventRow $y '16:00' '월간 보고 준비' $false
    $y = Add-EventRow $y '22:00' '야간 패치' $false 0 '~ 11월 6일 02:00'
    $y += 16
    $tw = Add-Line 1000 $y 32 '루틴' 14 $Ink.Text $true
    [void](Add-Line (1000 + $tw + 8) $y 32 '1/3' 14 $Ink.Text3)
    $y += 32
    foreach ($r in @(@('09:00 메일 확인', $true, ''), @('15:00 장비실 온도 확인', $false, '2/5'), @('17:30 일일 점검표', $false, ''))) {
        Add-Check 1000 ($y + 6) $r[1]
        [void](Add-Line 1026 $y 28 $r[0] 14 $(if ($r[1]) { $Ink.Text3 } else { $Ink.Text }))
        if ($r[2]) { [void](Add-Line 1256 $y 28 $r[2] 12 $Ink.Text3 -Right) }
        $y += 28
    }
}

# 표(README 7절): 카드 안쪽 좌우 16, 머리 32(F.Caption · B.Text.Tertiary, 아래 1 B.Border.Default), 행 32(아래 1 B.Border.Muted), 셀 좌우 12.
# 일정 표 열: 체크 40 · 날짜 120 · 시각 80 · 제목(나머지) · 태그 140 · 기한 88
$tableX = 216; $tableW = 744
$scheduleCols = @{ Date = 40; Time = 160; Title = 240; Tag = 516; Due = 656 }
function Add-TableHead([double]$Y, [object[]]$Heads) {
    foreach ($h in $Heads) { [void](Add-Line ($tableX + $h[0] + 12) $Y 32 $h[1] 12 $Ink.Text3) }
    Add-Box $tableX ($Y + 31) $tableW 1 $Ink.Border
    $Y + 32
}
function Add-ScheduleHead([double]$Y) {
    Add-TableHead $Y @(@($scheduleCols.Date, '날짜'), @($scheduleCols.Time, '시각'), @($scheduleCols.Title, '제목'), @($scheduleCols.Tag, '태그'), @($scheduleCols.Due, '기한'))
}
# 일정 · 루틴 행. R = @{ Date; Time; Title; Tags; Due; Over; Done; Routine; Memo; Count; Sel }
#   날짜 · 시각은 F.Caption · B.Text.Secondary. 루틴은 제목 앞 RepeatAll E8EE 12. 끝낸 것은 제목만 B.Text.Tertiary(체크리스트와 같음)
#   태그는 C 메모 태그 칩(높이 20 · 좌우 8 · 모서리 4 · B.Bg.Selected · B.Accent.Text), 기한은 F.Caption, 기한이 지난 것은 앞에 Warning E814 12(B.Status.Warning.Icon)
function Add-ScheduleRow([double]$Y, $R) {
    if ($R['Sel']) { Add-Box $tableX $Y $tableW 32 $Ink.Selected; Add-Box $tableX ($Y + 8) 3 16 $Ink.Accent '' 1.5 }
    Add-Check ($tableX + 12) ($Y + 8) ([bool]$R['Done'])
    if ($R['Date']) { [void](Add-Line ($tableX + $scheduleCols.Date + 12) $Y 32 $R.Date 12 $Ink.Text2 -Max 96) }
    if ($R['Time']) { [void](Add-Line ($tableX + $scheduleCols.Time + 12) $Y 32 $R.Time 12 $Ink.Text2) }
    $tx = $tableX + $scheduleCols.Title + 12; $right = $tableX + $scheduleCols.Tag - 12
    if ($R['Routine']) { Add-Glyph $tx $Y 12 32 0xE8EE 12 $Ink.Text3; $tx += 18 }
    if ($R['Count']) { $right -= (Add-Line $right $Y 32 $R.Count 12 $Ink.Text3 -Right) + 8 }
    if ($R['Memo']) {
        $nw = Add-Line $right $Y 32 ([string]$R.Memo) 12 $Ink.Text3 -Right
        Add-Glyph ($right - $nw - 16) $Y 12 32 0xE70B 12 $Ink.Text3
        $right -= $nw + 24
    }
    [void](Add-Line $tx $Y 32 $R.Title 14 $(if ($R['Done']) { $Ink.Text3 } else { $Ink.Text }) -Max ($right - $tx))
    $gx = $tableX + $scheduleCols.Tag + 12
    foreach ($tag in @($R['Tags'])) {
        if (-not $tag) { continue }
        $w = (Measure-Text $tag 12) + 16
        Add-Box $gx ($Y + 6) $w 20 $Ink.Selected '' 4
        [void](Add-Line ($gx + 8) ($Y + 6) 20 $tag 12 $Ink.Accent)
        $gx += $w + 4
    }
    if ($R['Due']) {
        $dx = $tableX + $scheduleCols.Due + 12
        if ($R['Over']) { Add-Glyph $dx $Y 12 32 0xE814 12 $Ink.Warn; $dx += 16 }
        [void](Add-Line $dx $Y 32 $R.Due 12 $(if ($R['Over'] -or $R.Due -eq '오늘') { $Ink.Text } else { $Ink.Text2 }))
    }
    Add-Box $tableX ($Y + 31) $tableW 1 $Ink.Muted
    $Y + 32
}
# 묶음 머리(README 7절 표): 높이 32, 펼침 단추 28(ChevronDown E70D 10), 이름 F.BodyStrong, 개수 F.Caption · B.Text.Tertiary, 아래 1 B.Border.Muted
function Add-GroupHead([double]$Y, [string]$Name, [string]$Count) {
    Add-Glyph ($tableX + 6) ($Y + 2) 28 28 0xE70D 10 $Ink.Text2
    $nw = Add-Line ($tableX + 40) $Y 32 $Name 14 $Ink.Text $true
    [void](Add-Line ($tableX + 40 + $nw + 8) $Y 32 $Count 12 $Ink.Text3)
    Add-Box $tableX ($Y + 31) $tableW 1 $Ink.Muted
    $Y + 32
}
# 깔때기 메뉴: 묶음 이름(F.Caption · B.Text.Tertiary, 높이 28) + 항목 32. 고른 조건은 앞에 체크(CheckMark E73E 12)
function Add-FilterMenu([double]$X, [double]$Y, [double]$W, [object[]]$Items) {
    $h = 8 + (@($Items | ForEach-Object { if ($_['Cap']) { 28 } else { 32 } }) | Measure-Object -Sum).Sum
    Add-Raised $X $Y $W $h
    $iy = $Y + 4
    foreach ($it in $Items) {
        if ($it['Cap']) { [void](Add-Line ($X + 12) $iy 28 $it.Cap 12 $Ink.Text3); $iy += 28; continue }
        if ($it['Hover']) { Add-Box ($X + 4) $iy ($W - 8) 32 $Ink.Hover '' 4 }
        if ($it['On']) { Add-Glyph ($X + 12) $iy 16 32 0xE73E 12 $Ink.Text }
        [void](Add-Line ($X + 36) $iy 32 $it.T 14 $Ink.Text)
        $iy += 32
    }
    $h
}

# 보는 달(11월)의 일정 + 오늘 루틴. 같은 날 둘째 줄부터 날짜를 비우고, 여러 날 일정은 기간을 쓴다
$monthRows = @(
    @{ Date = '11월 2일 월'; Time = '09:30'; Title = '정기 회의'; Tags = @('#회의'); Done = $true }
    @{ Date = '11월 3일 ~ 6일'; Time = '하루 종일'; Title = '서버 이전 작업'; Tags = @('#작업'); Due = 'D-1'; Memo = 3 }
    @{ Date = '11월 3일 화'; Time = '15:00'; Title = '방화벽 정책 정리'; Tags = @('#작업'); Due = '2일 지남'; Over = $true }
    @{ Date = '11월 4일 수'; Time = '15:00'; Title = '백업 점검'; Tags = @('#점검'); Done = $true }
    @{ Date = '11월 5일 목'; Time = '09:00'; Title = '메일 확인'; Routine = $true; Done = $true }
    @{ Time = '10:00'; Title = '주간 점검'; Tags = @('#점검'); Done = $true; Memo = 2 }
    @{ Time = '14:00'; Title = 'SRV-01 펌웨어 업데이트'; Tags = @('#작업'); Due = '오늘'; Memo = 1; Sel = $true }
    @{ Time = '15:00'; Title = '장비실 온도 확인'; Routine = $true; Count = '2/5'; Due = '오늘' }
    @{ Time = '16:00'; Title = '월간 보고 준비'; Tags = @('#보고'); Due = '오늘' }
    @{ Time = '17:30'; Title = '일일 점검표'; Routine = $true; Due = '오늘' }
    @{ Time = '22:00'; Title = '야간 패치'; Tags = @('#작업'); Due = '오늘' }
    @{ Date = '11월 6일 ~ 8일'; Time = '하루 종일'; Title = '인증서 갱신'; Tags = @('#작업'); Due = 'D-3' }
    @{ Date = '11월 10일 화'; Time = '14:00'; Title = '스토리지 교체'; Tags = @('#작업'); Due = 'D-5' }
    @{ Date = '11월 12일 목'; Time = '10:00'; Title = '주간 점검'; Tags = @('#점검'); Due = 'D-7' }
    @{ Date = '11월 13일 ~ 17일'; Time = '하루 종일'; Title = 'DR 훈련'; Tags = @('#훈련'); Due = 'D-12' }
    @{ Date = '11월 19일 목'; Time = '10:00'; Title = '주간 점검'; Tags = @('#점검'); Due = 'D-14' }
    @{ Date = '11월 20일 금'; Time = '10:00'; Title = '보안 교육'; Tags = @('#교육'); Due = 'D-15' }
    @{ Date = '11월 24일 화'; Time = '16:00'; Title = '장애 보고서'; Tags = @('#보고'); Due = 'D-19' }
    @{ Date = '11월 26일 목'; Time = '10:00'; Title = '주간 점검'; Tags = @('#점검'); Due = 'D-21' }
)
$tableView = Use-Scene
Add-ViewWindow
Add-ViewTitle -Month -Nav
[void](Add-ViewSwitch 'table')
$ty = Add-ScheduleHead 88
foreach ($r in $monthRows) { $ty = Add-ScheduleRow $ty $r }
Add-DayListV3

# 할 일: 기한 지남(지난 7일 안, 안 끝낸 것) → 오늘 → 마감 임박(3일 안에 끝나는 하루 종일 여러 날). 묶음 머리 개수는 줄 수
$dueView = Use-Scene
Add-ViewWindow
Add-ViewTitle '할 일' '9'
[void](Add-ViewSwitch 'due')
$ty = Add-ScheduleHead 88
$ty = Add-GroupHead $ty '기한 지남' '2'
$ty = Add-ScheduleRow $ty @{ Date = '10월 30일 금'; Time = '하루 종일'; Title = '케이블 라벨 정리'; Tags = @('#작업'); Due = '6일 지남'; Over = $true }
$ty = Add-ScheduleRow $ty @{ Date = '11월 3일 화'; Time = '15:00'; Title = '방화벽 정책 정리'; Tags = @('#작업'); Due = '2일 지남'; Over = $true }
$ty = Add-GroupHead $ty '오늘' '8'
$ty = Add-ScheduleRow $ty @{ Date = '11월 3일 ~ 6일'; Time = '하루 종일'; Title = '서버 이전 작업'; Tags = @('#작업'); Due = 'D-1'; Memo = 3 }
$ty = Add-ScheduleRow $ty @{ Time = '09:00'; Title = '메일 확인'; Routine = $true; Done = $true }
$ty = Add-ScheduleRow $ty @{ Time = '10:00'; Title = '주간 점검'; Tags = @('#점검'); Done = $true; Memo = 2 }
$ty = Add-ScheduleRow $ty @{ Time = '14:00'; Title = 'SRV-01 펌웨어 업데이트'; Tags = @('#작업'); Due = '오늘'; Memo = 1; Sel = $true }
$ty = Add-ScheduleRow $ty @{ Time = '15:00'; Title = '장비실 온도 확인'; Routine = $true; Count = '2/5'; Due = '오늘' }
$ty = Add-ScheduleRow $ty @{ Time = '16:00'; Title = '월간 보고 준비'; Tags = @('#보고'); Due = '오늘' }
$ty = Add-ScheduleRow $ty @{ Time = '17:30'; Title = '일일 점검표'; Routine = $true; Due = '오늘' }
$ty = Add-ScheduleRow $ty @{ Time = '22:00'; Title = '야간 패치'; Tags = @('#작업'); Due = '오늘' }
$ty = Add-GroupHead $ty '마감 임박' '1'
$ty = Add-ScheduleRow $ty @{ Date = '11월 6일 ~ 8일'; Time = '하루 종일'; Title = '인증서 갱신'; Tags = @('#작업'); Due = 'D-3' }
Add-DayListV3

# 찾기: 찾기 칸에 쓰면 표 보기로 바뀌고 앞뒤 1년에서 찾는다. 깔때기 = 상태 · 종류 · 태그(자주 쓴 순), 고르면 찾기 칸에 글로 들어간다
$findView = Use-Scene
Add-ViewWindow
Add-ViewTitle '찾기 결과' '7'
$filterX = Add-ViewSwitch 'table' '#작업 is:open' -FilterOpen
$ty = Add-ScheduleHead 88
foreach ($r in @(
        @{ Date = '10월 30일 금'; Time = '하루 종일'; Title = '케이블 라벨 정리'; Tags = @('#작업'); Due = '6일 지남'; Over = $true }
        @{ Date = '11월 3일 ~ 6일'; Time = '하루 종일'; Title = '서버 이전 작업'; Tags = @('#작업'); Due = 'D-1'; Memo = 3 }
        @{ Date = '11월 3일 화'; Time = '15:00'; Title = '방화벽 정책 정리'; Tags = @('#작업'); Due = '2일 지남'; Over = $true }
        @{ Date = '11월 5일 목'; Time = '14:00'; Title = 'SRV-01 펌웨어 업데이트'; Tags = @('#작업'); Due = '오늘'; Memo = 1 }
        @{ Time = '22:00'; Title = '야간 패치'; Tags = @('#작업'); Due = '오늘' }
        @{ Date = '11월 6일 ~ 8일'; Time = '하루 종일'; Title = '인증서 갱신'; Tags = @('#작업'); Due = 'D-3' }
        @{ Date = '11월 10일 화'; Time = '14:00'; Title = '스토리지 교체'; Tags = @('#작업'); Due = 'D-5' }
    )) { $ty = Add-ScheduleRow $ty $r }
Add-DayListV3
[void](Add-FilterMenu ($filterX + 28 - 200) 78 200 @(
        @{ Cap = '상태' }, @{ T = '안 끝낸 것'; On = $true }, @{ T = '끝낸 것' }
        @{ Cap = '종류' }, @{ T = '일정만' }, @{ T = '루틴만' }
        @{ Cap = '태그' }, @{ T = '#작업'; On = $true }, @{ T = '#점검'; Hover = $true }, @{ T = '#보고' }, @{ T = '#회의' }, @{ T = '#교육' }, @{ T = '#훈련' }
    ))

# 루틴 보기: 전체 루틴, 시각순(시각 없는 것 먼저). 열: 이름(나머지) · 규칙 220 · 시각 72 · 오늘 72 · 메모 60. 줄을 누르면 오른쪽에 편집 폼
$routineCols = @{ Rule = 320; Time = 540; Today = 612; Memo = 684 }
function Add-RoutineRow([double]$Y, $R) {
    if ($R['Sel']) { Add-Box $tableX $Y $tableW 32 $Ink.Selected; Add-Box $tableX ($Y + 8) 3 16 $Ink.Accent '' 1.5 }
    Add-Glyph ($tableX + 12) $Y 12 32 0xE8EE 12 $Ink.Text3
    [void](Add-Line ($tableX + 30) $Y 32 $R.Title 14 $Ink.Text -Max ($routineCols.Rule - 42))
    [void](Add-Line ($tableX + $routineCols.Rule + 12) $Y 32 $R.Rule 12 $Ink.Text2 -Max 196)
    [void](Add-Line ($tableX + $routineCols.Time + 12) $Y 32 $R.Time 12 $Ink.Text2)
    [void](Add-Line ($tableX + $routineCols.Today + 12) $Y 32 $R.Today 12 $(if ($R.Today -like '*/*') { $Ink.Text } else { $Ink.Text3 }))
    if ($R['Memo']) {
        Add-Glyph ($tableX + $routineCols.Memo + 12) $Y 12 32 0xE70B 12 $Ink.Text3
        [void](Add-Line ($tableX + $routineCols.Memo + 28) $Y 32 ([string]$R.Memo) 12 $Ink.Text3)
    }
    Add-Box $tableX ($Y + 31) $tableW 1 $Ink.Muted
    $Y + 32
}
# 루틴 편집 폼(매일) + 새 칸 「시각」(선택, 비우면 시각 없음). 시간마다 루틴은 지금처럼 간격 · 시작 · 끝
function Add-RoutineTimeForm {
    $y = 88
    $y = Add-FormField $y '제목' '메일 확인'
    $y = Add-FormField $y '주기' '매일' -Combo
    $y = Add-FormField $y '시각' '09:00'
    Add-Check 1000 ($y + 2) $true
    [void](Add-Line 1026 $y 20 '근무 요일만' 14 $Ink.Text)
    $y += 32
    $lw = Add-Line 1000 $y 20 '관련 메모' 14 $Ink.Text2
    [void](Add-Line (1000 + $lw + 8) $y 20 '0' 14 $Ink.Text3)
    $y += 28
    $nw = Add-DropBtn 1000 $y '새 메모'
    [void](Add-Btn (1000 + $nw + 8) $y '기존 메모 고르기')
    [void](Add-Btn 1000 744 '삭제')
    $cancelW = Add-Btn 1256 744 '취소' -Right
    [void](Add-Btn (1256 - $cancelW - 8) 744 '저장' 'primary' -Right)
}
$routineView = Use-Scene
Add-ViewWindow
Add-ViewTitle '루틴' '5'
[void](Add-ViewSwitch 'routines')
$ty = Add-TableHead 88 @(@(18, '이름'), @($routineCols.Rule, '규칙'), @($routineCols.Time, '시각'), @($routineCols.Today, '오늘'), @($routineCols.Memo, '메모'))
foreach ($r in @(
        @{ Title = '서버실 출입 기록 확인'; Rule = '월 · 수 · 금'; Time = '—'; Today = '오늘 없음' }
        @{ Title = '메일 확인'; Rule = '매일 · 근무 요일만'; Time = '09:00'; Today = '1/1'; Sel = $true }
        @{ Title = '장비실 온도 확인'; Rule = '2시간마다 · 09:00 ~ 17:00'; Time = '—'; Today = '2/5'; Memo = 1 }
        @{ Title = '주간 보고 작성'; Rule = '금'; Time = '16:00'; Today = '오늘 없음' }
        @{ Title = '일일 점검표'; Rule = '평일'; Time = '17:30'; Today = '0/1' }
    )) { $ty = Add-RoutineRow $ty $r }
Add-RoutineTimeForm

# 일정 편집 폼 + 새 칸 「태그」(알람 다음, 쉼표로 나눔, # 없이 써도 됨). 태그는 계열 전체라 「이 회차만」 저장에서는 바꾸지 않는다
function Add-EventTagForm {
    $y = 88
    $y = Add-FormField $y '제목' 'SRV-01 펌웨어 업데이트'
    $y = Add-FormRange $y '날짜' '2026-11-05' '2026-11-05'
    Add-Check 1000 ($y + 2) $false
    [void](Add-Line 1026 $y 20 '하루 종일' 14 $Ink.Text)
    $y += 32
    $y = Add-FormRange $y '시각' '14:00' '15:00'
    $y = Add-FormField $y '반복' '없음' -Combo
    $y = Add-FormField $y '알람' '30분 전' -Combo
    $y = Add-FormField $y '태그' '작업, 펌웨어'
    $lw = Add-Line 1000 $y 20 '관련 메모' 14 $Ink.Text2
    [void](Add-Line (1000 + $lw + 8) $y 20 '1' 14 $Ink.Text3)
    $y += 28
    Add-MemoLinkRow $y '11-05 SRV-01 펌웨어 업데이트' ''; $y += 32
    $y += 8
    $nw = Add-DropBtn 1000 $y '새 메모'
    [void](Add-Btn (1000 + $nw + 8) $y '기존 메모 고르기')
    [void](Add-Btn 1000 744 '삭제')
    $cancelW = Add-Btn 1256 744 '취소' -Right
    [void](Add-Btn (1256 - $cancelW - 8) 744 '저장' 'primary' -Right)
}
$tagForm = Use-Scene
Add-ViewWindow
Add-ViewTitle -Month -Nav
[void](Add-ViewSwitch 'table')
$ty = Add-ScheduleHead 88
foreach ($r in $monthRows) { $ty = Add-ScheduleRow $ty $r }
Add-EventTagForm

# 폰에서 읽는 확대본: 바뀌는 곳만 잘라 키운다
$phoneH = 6000   # 넉넉히 칠하고, 내보낼 때 실제 높이로 자른다
# 폰 폭(720)에서 읽히게 설명은 18, 넘치면 낱말 단위로 줄을 바꾼다
function Add-Wrapped([double]$X, [string]$Value, [double]$Size, [string]$Color, [double]$Max, [double]$LineH) {
    $line = ''
    foreach ($word in $Value -split ' ') {
        $try = if ($line) { "$line $word" } else { $word }
        if ($line -and (Measure-Text $try $Size) -gt $Max) { [void](Add-Text $X $script:y $line $Size $Color); $script:y += $LineH; $line = $word }
        else { $line = $try }
    }
    if ($line) { [void](Add-Text $X $script:y $line $Size $Color); $script:y += $LineH }
}
# 자르기 하나 = @(원본 X, Y, 폭, 높이, 장면). 여러 개면 위에서 아래로 놓는다
function Add-Section([string]$Title, [string[]]$Notes, [object[]]$Crops) {
    [void](Add-Text 24 $script:y $Title 22 $Ink.Text $true)
    $script:y += 44
    foreach ($crop in $Crops) {
        $h = 672 * $crop[3] / $crop[2]
        Add-Crop 24 $script:y 672 $h $crop[0] $crop[1] $crop[2] $crop[3] $crop[4]
        Add-Frame 24 $script:y 672 $h '' $Ink.Border 0
        $script:y += $h + 12
    }
    $script:y += 4
    foreach ($n in $Notes) { Add-Wrapped 24 $n 18 $Ink.Text2 672 28 }
    $script:y += 40
}
# 자르기 두 개를 나란히(각 폭 330, 사이 12). 좁은 사이드바 폼 둘을 너무 키우지 않고 같이 보여 줄 때 쓴다
function Add-SectionPair([string]$Title, [string[]]$Notes, [object[]]$Left, [object[]]$Right) {
    [void](Add-Text 24 $script:y $Title 22 $Ink.Text $true)
    $script:y += 44
    $tallest = 0; $x = 24
    foreach ($crop in $Left, $Right) {
        $h = 330 * $crop[3] / $crop[2]
        Add-Crop $x $script:y 330 $h $crop[0] $crop[1] $crop[2] $crop[3] $crop[4]
        Add-Frame $x $script:y 330 $h '' $Ink.Border 0
        $tallest = [math]::Max($tallest, $h); $x += 342
    }
    $script:y += $tallest + 16
    foreach ($n in $Notes) { Add-Wrapped 24 $n 18 $Ink.Text2 672 28 }
    $script:y += 40
}
# 폰 장면 머리. 장면을 돌려주고 $y를 첫 절 자리로 둔다
function New-PhoneScene([string]$Title) {
    $scene = Use-Scene
    Add-Box 0 0 720 $phoneH $Ink.Canvas
    [void](Add-Text 24 24 $Title 30 $Ink.Text $true)
    [void](Add-Text 24 72 '가짜 데이터 · 색 하늘 · 오늘 11월 5일 목요일' 18 $Ink.Text3)
    $script:y = 128
    , $scene
}

$phone = New-PhoneScene '일정 탭 1단계 — 시안'
Add-Section '① 머리줄: 달 고르기' @('「2026년 11월」을 누르면 해와 달을 골라 바로 갑니다. 아래 「오늘」은 이번 달 · 오늘로 갑니다.', '달력 칸에서는 PageUp · PageDown으로 달을 옮깁니다. ‹ 오늘 ›는 3단계 표 보기에 둡니다.') @(, @(200, 32, 420, 300, $picker))
Add-Section '② 일정 줄 = 체크 상자 + 시각 + 제목' @('체크는 회차마다 따로 남고, 체크하면 루틴처럼 흐려집니다.', '여러 날 일정은 둘째 줄에 기간과 며칠째인지 씁니다.') @(, @(984, 32, 288, 328, $list))
Add-Section '③ 여러 날 일정 = 이어진 막대' @('같은 주 안에서는 막대 하나로 잇고 제목은 한 번만 씁니다.', '주를 넘기면 다음 줄 첫 칸에 제목을 다시 씁니다. (전체 그림의 DR 훈련)', '체크한 일정은 칩 앞에 ✓를 붙이고 흐리게 둡니다.') @(, @((Get-CellX 2), 88, (4 * $cw), 160, $list))
Add-Section '④ 휴무일 지정: 날짜 우클릭' @('우클릭 → 휴무일로 지정 → 회사 휴무 · 개인 휴무를 고르면 바로 칠해집니다.', '휴무일 이름은 날짜 옆에 써서 여러 날 막대가 어긋나지 않게 했습니다.') @(@(700, 500, 520, 220, $menu), @((Get-CellX 4), 500, (3 * $cw), 156, $list))
Add-Section '⑤ 설정 → 휴무일' @('공휴일은 해마다 자동으로 계산합니다. 설 · 추석 · 부처님오신날 · 대체공휴일까지, 인터넷은 쓰지 않습니다.', '선거일 · 임시공휴일 · 회사 휴무만 [휴무일 추가]로 넣고, 이름과 종류는 여기서 고칩니다.') @(, @(200, 32, 640, 600, $settings))
$phoneEnd = $y

$memoPhone = New-PhoneScene '일정 탭 2단계 — 일정 ↔ 메모 연결 시안'
Add-Section '① 일정 · 루틴 줄 끝 = 관련 메모 수' @('메모가 붙은 일정 · 루틴은 줄 끝에 메모 아이콘과 개수가 보입니다.', '줄을 누르면 지금처럼 편집 폼이 열립니다.') @(, @(984, 32, 288, 340, $memoList))
Add-Section '② 편집 폼 맨 아래 「관련 메모」' @('오른쪽 글자는 붙은 범위입니다. [새 메모]로 만든 것은 「이 회차」, [기존 메모 고르기]로 붙인 것은 「모든 회차」입니다. 반복이 없는 일정은 범위를 쓰지 않습니다.', '지운 메모는 흐리게 남고 연결 빼기만 됩니다.', '메모 줄을 누르면 새 창(⑥)이 열립니다.') @(, @(984, 540, 288, 252, $memoForm))
Add-Section '③ [새 메모 ⌄] → 빈 메모 · 통화 메모' @('만들면 바로 이 일정(이 회차)에 붙습니다. 제목은 「11-05 주간 점검」처럼 날짜 + 일정 제목입니다.') @(, @(984, 640, 288, 160, $memoNew))
Add-Section '④ [기존 메모 고르기]' @('메모 찾기와 같은 문법(#태그 · title: 등)으로 찾습니다. 이미 붙은 메모는 「붙어 있음」으로 흐리게 보입니다.', '[붙이기] · 두 번 클릭 · Enter로 붙입니다. 절차서처럼 매번 쓰는 메모용입니다.') @(, @(392, 172, 496, 438, $memoPick))
Add-Section '⑤ 메모 줄 우클릭' @('새 창으로 보기 · 메모 탭에서 열기 · 연결 빼기. 지운 메모는 연결 빼기만 있습니다.') @(, @(984, 540, 288, 230, $memoRow))
Add-Section '⑥ 메모 새 창 = 읽기 보기' @('고칠 수는 없고 할 일 체크만 됩니다. 고치려면 [메모 탭에서 열기]를 누릅니다.', '앱 창과 따로 움직이는 창이라 일정을 보면서 옆에 띄워 둘 수 있습니다.') @(, @(224, 88, 656, 576, $memoWindow))
Add-Section '⑦ 통화 메모 틀' @('전화하기 전에 할 말을 적어 두고, 통화하면서 체크합니다. 「<상대>」만 바꿔 씁니다.') @(, @(224, 112, 656, 456, $memoCall))
Add-Section '⑧ 루틴도 같은 자리' @('루틴 편집 폼 맨 아래에도 「관련 메모」가 있습니다. 루틴은 날마다 같은 일이라 새 메모 · 고른 메모 모두 모든 날에 붙고, 범위 글자는 쓰지 않습니다.', '규칙을 바꿔 루틴이 새 계열로 나뉘어도 연결은 따라갑니다.') @(, @(984, 460, 288, 332, $memoRoutine))
$memoPhoneEnd = $y

$viewsPhone = New-PhoneScene '일정 탭 3단계 — 찾기 · 표 · 루틴 보기 시안'
Add-Section '① 머리줄 오른쪽 = 찾기 · 깔때기 · 보기 4개' @('보기는 「할 일」 · 달력 · 표 · 루틴입니다. 아이콘에는 이름 툴팁이 붙습니다.', '「할 일」 옆 숫자는 아직 안 끝낸 것의 수라서, 달력을 보고 있어도 늘 보입니다.', '찾기 칸에 쓰거나 깔때기에서 고르면 표 보기로 바뀌어 결과를 보여 줍니다.') @(, @(496, 36, 480, 48, $tableView))
Add-Section '② 할 일' @('기한 지남(지난 7일 안에 지났는데 체크 안 한 것) → 오늘 → 마감 임박(3일 안에 끝나는 여러 날 일정) 순서입니다.', '기한 지남은 경고 아이콘과 「2일 지남」 글자로 알립니다(색만으로 알리지 않음).', '오늘 줄은 시각순이고 루틴(↻)도 섞여 있습니다. 끝낸 것은 체크하면 흐려집니다.') @(, @(200, 32, 776, 520, $dueView))
Add-Section '③ 표 보기 = 보는 달' @('열은 체크 · 날짜 · 시각 · 제목 · 태그 · 기한입니다. 같은 날 둘째 줄부터는 날짜를 비웁니다.', '‹ 오늘 ›은 표에만 있습니다. 달력처럼 PageUp · PageDown으로도 달을 옮깁니다.', '루틴은 오늘 것만 넣었습니다(정할 것 ①). 줄을 누르면 오른쪽에 편집 폼이 열립니다.') @(, @(200, 32, 776, 680, $tableView))
Add-Section '④ 찾기 + 깔때기' @('메모와 같은 문법입니다: #태그 · title: · 2026-11-05 · 2026-10-01..2026-10-31 · 빼기 - · OR · ( ) · is:done · is:open · is:routine', '깔때기에서 고르면 찾기 칸에 글로 들어가고, 다시 고르면 빠집니다. 태그는 많이 쓴 순입니다.', '찾는 기간은 오늘 앞뒤 1년이고, 날짜를 쓰면 그 기간까지 넓힙니다(정할 것 ③).') @(, @(200, 32, 776, 500, $findView))
Add-Section '⑤ 루틴 보기' @('루틴 전체를 시각순으로 봅니다. 규칙 · 시각 · 오늘 진행(끝낸 수/전체) · 관련 메모 수가 한눈에 보입니다.', '줄을 누르면 오른쪽에서 고치고, 우클릭으로 편집 · 삭제합니다.') @(, @(200, 32, 776, 300, $routineView))
Add-SectionPair '⑥ 루틴 시각 · 일정 태그' @('왼쪽: 매일 · 요일 루틴에 「시각」 칸이 생깁니다(선택). 넣으면 「09:00 메일 확인」처럼 보이고 시각순으로 놓입니다.', '오른쪽: 일정 폼 알람 아래에 「태그」 칸이 생깁니다. 쉼표로 나눠 쓰고 #은 없어도 됩니다. 표 · 찾기 · 깔때기에서 씁니다.') @(984, 32, 288, 380, $routineView) @(984, 400, 288, 260, $tagForm)
$viewsPhoneEnd = $y

# ---- 내보내기 --------------------------------------------------------------------------------

function Write-SvgShapes($Writer, $Shapes) {
    foreach ($s in $Shapes) {
        $tag = switch ($s.Kind) { rect { 'rect' } text { 'text' } path { 'path' } crop { 'svg' } }
        $Writer.WriteStartElement($tag, 'http://www.w3.org/2000/svg')
        $attrs = switch ($s.Kind) {
            rect { @{ x = $s.X; y = $s.Y; width = $s.W; height = $s.H; rx = $s.Radius; fill = $s.Fill; stroke = $s.Stroke; 'stroke-width' = $s.Thickness } }
            text { @{ x = $s.X; y = $s.Y + $s.Baseline; fill = $s.Color; 'font-size' = $s.Size; 'font-weight' = $(if ($s.Bold) { '600' } else { '400' }) } }
            path { @{ d = $s.Data; fill = $s.Fill; stroke = $s.Stroke; 'stroke-width' = $s.Thickness } }
            crop { @{ x = $s.X; y = $s.Y; width = $s.W; height = $s.H; viewBox = ($s.SX, $s.SY, $s.SW, $s.SH | ForEach-Object { ([double]$_).ToString($inv) }) -join ' '; overflow = 'hidden' } }
        }
        foreach ($name in @($attrs.Keys | Sort-Object)) {
            $value = $attrs[$name]
            if ($value -is [double] -or $value -is [int]) { $value = ([double]$value).ToString('0.###', $inv) }
            if (($name -eq 'fill' -or $name -eq 'stroke') -and -not $value) { $value = 'none' }
            $Writer.WriteAttributeString($name, [string]$value)
        }
        if ($s.Kind -eq 'text') { $Writer.WriteString($s.Value) }
        if ($s.Kind -eq 'crop') { Write-SvgShapes $Writer $s.Shapes }
        $Writer.WriteEndElement()
    }
}
function Draw-Shapes($Context, $Shapes) {
    foreach ($s in $Shapes) {
        switch ($s.Kind) {
            rect {
                $fill = if ($s.Fill) { Get-Brush $s.Fill } else { $null }
                $pen = if ($s.Stroke) { [Windows.Media.Pen]::new((Get-Brush $s.Stroke), $s.Thickness) } else { $null }
                $Context.DrawRoundedRectangle($fill, $pen, [Windows.Rect]::new($s.X, $s.Y, $s.W, $s.H), $s.Radius, $s.Radius)
            }
            text { $Context.DrawText((New-TextLayout $s.Value $s.Size $s.Bold $uiFamily $s.Color), [Windows.Point]::new($s.X, $s.Y)) }
            path {
                $fill = if ($s.Fill) { Get-Brush $s.Fill } else { $null }
                $pen = if ($s.Stroke) { [Windows.Media.Pen]::new((Get-Brush $s.Stroke), $s.Thickness) } else { $null }
                $Context.DrawGeometry($fill, $pen, [Windows.Media.Geometry]::Parse($s.Data))
            }
            crop {
                $scale = $s.W / $s.SW
                $Context.PushClip([Windows.Media.RectangleGeometry]::new([Windows.Rect]::new($s.X, $s.Y, $s.W, $s.H)))
                $Context.PushTransform([Windows.Media.MatrixTransform]::new([Windows.Media.Matrix]::new($scale, 0, 0, $scale, $s.X - $s.SX * $scale, $s.Y - $s.SY * $scale)))
                Draw-Shapes $Context $s.Shapes
                $Context.Pop(); $Context.Pop()
            }
        }
    }
}
function Export-Scene([string]$Name, [int]$Width, [int]$Height, $Shapes, [string]$Title, [string]$Desc) {
    $svg = Join-Path $Config.OutputFolder "$Name.svg"
    $png = Join-Path $Config.OutputFolder "$Name.png"
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Encoding = [Text.UTF8Encoding]::new($false)
    $settings.Indent = $true
    $settings.NewLineChars = "`n"
    $writer = [Xml.XmlWriter]::Create($svg, $settings)
    try {
        $writer.WriteStartElement('svg', 'http://www.w3.org/2000/svg')
        $writer.WriteAttributeString('width', [string]$Width)
        $writer.WriteAttributeString('height', [string]$Height)
        $writer.WriteAttributeString('viewBox', "0 0 $Width $Height")
        $writer.WriteAttributeString('role', 'img')
        $writer.WriteAttributeString('aria-labelledby', 'title desc')
        $writer.WriteAttributeString('font-family', "'Segoe UI Variable Text', 'Segoe UI', 'Malgun Gothic', sans-serif")
        $writer.WriteStartElement('title'); $writer.WriteAttributeString('id', 'title'); $writer.WriteString($Title); $writer.WriteEndElement()
        $writer.WriteStartElement('desc'); $writer.WriteAttributeString('id', 'desc'); $writer.WriteString($Desc); $writer.WriteEndElement()
        Write-SvgShapes $writer $Shapes
        $writer.WriteEndElement()
    } finally { $writer.Dispose() }
    $visual = [Windows.Media.DrawingVisual]::new()
    $context = $visual.RenderOpen()
    try { Draw-Shapes $context $Shapes } finally { $context.Close() }
    $scale = $Config.PngScale
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($Width * $scale, $Height * $scale, 96 * $scale, 96 * $scale, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create($png)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Host "만듦: $svg"
    Write-Host "만듦: $png"
}

if ($Part -in 'all', 'phase1') {
    $desc = '가짜 데이터 시안. 2026년 11월, 오늘 11월 5일. 머리줄 달 고르기 · 오늘, 일정 줄 체크 상자, 여러 날 막대, 우클릭 휴무일 지정, 설정의 휴무일 목록.'
    Export-Scene "$($Config.Name)-list" 1280 800 $list 'WorkTool 일정 1단계 — 체크 상자와 여러 날 막대 시안' $desc
    Export-Scene "$($Config.Name)-picker" 1280 800 $picker 'WorkTool 일정 1단계 — 달 고르기 시안' $desc
    Export-Scene "$($Config.Name)-holiday" 1280 800 $menu 'WorkTool 일정 1단계 — 우클릭 휴무일 지정 시안' $desc
    Export-Scene "$($Config.Name)-settings" 1280 800 $settings 'WorkTool 설정 → 휴무일 시안' $desc
    Export-Scene "$($Config.Name)-phone" 720 ([int][math]::Ceiling($phoneEnd + 8)) $phone 'WorkTool 일정 1단계 — 폰 열람용 확대본' $desc
}
if ($Part -in 'all', 'memo') {
    $desc = '가짜 데이터 시안. 2026년 11월, 오늘 11월 5일. 일정 편집 폼 아래 관련 메모 목록, 새 메모 · 기존 메모 고르기, 메모 줄 우클릭, 메모 새 창(읽기 보기), 통화 메모 틀.'
    Export-Scene "$($Config.Name)-memo" 1280 800 $memoForm 'WorkTool 일정 2단계 — 편집 폼의 관련 메모 시안' $desc
    Export-Scene "$($Config.Name)-memo-pick" 1280 800 $memoPick 'WorkTool 일정 2단계 — 기존 메모 고르기 시안' $desc
    Export-Scene "$($Config.Name)-memo-window" 1280 800 $memoWindow 'WorkTool 일정 2단계 — 메모 새 창 시안' $desc
    Export-Scene "$($Config.Name)-memo-phone" 720 ([int][math]::Ceiling($memoPhoneEnd + 8)) $memoPhone 'WorkTool 일정 2단계 — 폰 열람용 확대본' $desc
}
if ($Part -in 'all', 'views') {
    $desc = '가짜 데이터 시안. 2026년 11월, 오늘 11월 5일. 머리줄 오른쪽 찾기 · 깔때기 · 보기 전환, 할 일, 표 보기, 찾기 결과와 깔때기 메뉴, 루틴 보기, 루틴 시각 · 일정 태그 칸.'
    Export-Scene "$($Config.Name)-views" 1280 800 $tableView 'WorkTool 일정 3단계 — 표 보기 시안' $desc
    Export-Scene "$($Config.Name)-views-due" 1280 800 $dueView 'WorkTool 일정 3단계 — 할 일 시안' $desc
    Export-Scene "$($Config.Name)-views-find" 1280 800 $findView 'WorkTool 일정 3단계 — 찾기와 깔때기 시안' $desc
    Export-Scene "$($Config.Name)-views-routines" 1280 800 $routineView 'WorkTool 일정 3단계 — 루틴 보기 시안' $desc
    Export-Scene "$($Config.Name)-views-form" 1280 800 $tagForm 'WorkTool 일정 3단계 — 일정 태그 칸 시안' $desc
    Export-Scene "$($Config.Name)-views-phone" 720 ([int][math]::Ceiling($viewsPhoneEnd + 8)) $viewsPhone 'WorkTool 일정 3단계 — 폰 열람용 확대본' $desc
}

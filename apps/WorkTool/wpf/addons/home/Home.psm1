# 홈 탭. 다른 탭이 등록한 홈 카드(HomeCard)를 모아서 두 줄로 보여 준다.
# 탭을 더하면 그 탭의 카드도 여기에 저절로 나온다. 홈은 다른 탭의 데이터를 직접 읽지 않는다.

$ErrorActionPreference = 'Stop'

$script:dateText = $null
$script:columns = $null

function New-WtHomeView {
    $page = New-WtPage
    # 머리글: 날짜(열 때마다 새로 씀) + 제목
    $header = New-WtStack Vertical 4
    $header.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
    $script:dateText = New-WtText '' 'T.Sub'
    [void](Add-WtChild $header $script:dateText)
    [void](Add-WtChild $header (New-WtText '오늘' 'T.Title'))
    [void](Add-WtChild $page.Panel $header)

    $grid = [System.Windows.Controls.Grid]::new()
    $script:columns = @()
    for ($i = 0; $i -lt 2; $i++) {
        $cd = [System.Windows.Controls.ColumnDefinition]::new()
        $cd.Width = [System.Windows.GridLength]::new(1, 'Star')
        $grid.ColumnDefinitions.Add($cd)
        $col = New-WtStack Vertical 16
        $col.Margin = [System.Windows.Thickness]::new($(if ($i -eq 0) { 0 } else { 8 }), 0, $(if ($i -eq 0) { 8 } else { 0 }), 0)
        [System.Windows.Controls.Grid]::SetColumn($col, $i)
        [void]$grid.Children.Add($col)
        $script:columns += $col
    }
    [void](Add-WtChild $page.Panel $grid)
    $page.Root
}

function Update-WtHomeView {
    $script:dateText.Text = Format-WtDate (Get-Date) 'yyyy년 M월 d일 dddd'
    foreach ($c in $script:columns) { $c.Children.Clear() }
    $cards = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @(Get-WtAddon)) {
        if (-not $a.HomeCard -or $a.Id -eq 'home') { continue }
        try {
            foreach ($el in @(& $a.HomeCard)) { if ($el -is [System.Windows.UIElement]) { $cards.Add($el) } }
        } catch {
            $cards.Add((New-WtText "$($a.Title) 카드를 만들지 못했습니다: $($_.Exception.Message)" 'T.Sub'))
        }
    }
    # 왼쪽 · 오른쪽에 번갈아 놓는다
    for ($i = 0; $i -lt $cards.Count; $i++) {
        [void](Add-WtChild $script:columns[$i % 2] $cards[$i])
    }
    if (-not $cards.Count) {
        [void](Add-WtChild $script:columns[0] (New-WtText '홈에 보여 줄 카드가 없습니다.' 'T.Sub'))
    }
}

Register-WtAddon -Id 'home' -Title '홈' -Icon 0xE80F -Group '일과' -Order 0 -Required `
    -NewView { New-WtHomeView } `
    -Refresh { param($view) Update-WtHomeView }

Export-ModuleMember -Function @()

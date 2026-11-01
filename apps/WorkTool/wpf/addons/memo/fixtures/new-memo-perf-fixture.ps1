<#
.SYNOPSIS
    메모 성능·회귀 검사에 쓰는 서로 다른 본문을 고정 씨앗으로 만듭니다. 파일을 읽거나 쓰지 않습니다.
.EXAMPLE
    $fixture = New-WtMemoPerfFixture -Count 3000 -Seed 20261101
#>
#Requires -Version 7.0
function New-WtMemoPerfFixture {
    param([int]$Count = 3000, [int]$Seed = 20261101)
    $random = [Random]::new($Seed)
    $vocabulary = @(for ($n = 0; $n -lt 2048; $n++) { 'word{0:d4}' -f $n })
    $items = [Collections.Generic.List[object]]::new($Count)
    $folders = @('work', 'procedure', 'incident', 'personal')
    $at = [DateTimeOffset]'2026-11-01T09:30:00+09:00'
    $bytes = 0L
    for ($i = 0; $i -lt $Count; $i++) {
        $title = if ($i -lt 40) { '같은 제목 {0:d2}' -f [int][Math]::Floor($i / 2) } else { '시험 메모 {0:d4}' -f $i }
        $body = [Text.StringBuilder]::new()
        [void]$body.Append("# $title`n`n")
        if ($i % 2 -eq 0) { [void]$body.Append("[[시험 메모 $((100 + $i % 2800).ToString('d4'))]]`n`n") }
        if ($i % 3 -ne 2) { [void]$body.Append('점검 ') }
        if ($i -lt 7) { [void]$body.Append('희귀일곱 ') }
        [void]$body.Append("#태그`n`n## 확인`n`n- [ ] 확인 항목`n`n")
        $target = if ($i % 100 -eq 50) { 20480 } else { 1030 }
        $words = [int][Math]::Ceiling(($target - [Text.Encoding]::UTF8.GetByteCount($body.ToString())) / 9)
        for ($j = 0; $j -lt $words; $j++) { [void]$body.Append($vocabulary[$random.Next($vocabulary.Count)]).Append(' ') }
        $text = $body.ToString(); $bytes += [Text.Encoding]::UTF8.GetByteCount($text)
        $stamp = $at.AddMinutes(-$i * 11).ToString("yyyy-MM-dd'T'HH:mm:sszzz")
        $items.Add([pscustomobject][ordered]@{
            id = "memo-$i"; title = $title; body = $text; tags = @('태그')
            folder = $(if ($i -lt 1000) { 'work' } else { $folders[1 + $i % 3] })
            pinned = ($i -lt 20); archived = ($i % 20 -eq 19); lock = $null
            created = $stamp; updated = $stamp
            deleted = $(if ($i % 100 -eq 99) { $at.AddDays(-2).ToString("yyyy-MM-dd'T'HH:mm:sszzz") } else { $null })
        })
    }
    $folderRows = @(for ($i = 0; $i -lt 4; $i++) { [pscustomobject]@{ id = $folders[$i]; name = @('업무', '절차', '장애', '개인')[$i]; order = ($i + 1) * 10; created = $at.ToString("yyyy-MM-dd'T'HH:mm:sszzz") } })
    $opened = @(for ($i = 0; $i -lt [Math]::Min(1000, $Count); $i++) { [pscustomobject]@{ id = "memo-$i"; opened = $at.AddMinutes(-$i * 3).ToString("yyyy-MM-dd'T'HH:mm:sszzz") } })
    [pscustomobject]@{
        Document = [pscustomobject]@{ schema = 1; saved = $at.ToString('o'); items = $items.ToArray(); folders = $folderRows; sampleMarker = "seed-$Seed" }
        State = [pscustomobject]@{ schema = 1; saved = $at.ToString('o'); items = $opened }
        Seed = $Seed; Vocabulary = $vocabulary.Count; AverageBodyBytes = $(if ($Count) { $bytes / $Count } else { 0 })
    }
}

# 문서 탭: 고른 폴더를 트리로 보고, 파일은 원래 프로그램(Excel · Word · PDF …)으로 연다.
# 보안 문서 · 계정 엑셀처럼 툴에 옮기면 안 되는 파일도 여기서 원본을 바로 연다. 파일 내용은 읽거나 저장하지 않는다.
# 설정(데이터 폴더의 settings.json, 저장소에 올라가지 않음):
#   docs.roots  트리 맨 위 폴더들 · docs.pins  즐겨찾기(파일 · 폴더 경로) · docs.last  마지막으로 본 폴더
# 단축키(문서 화면 안): Enter 열기 · Alt+↑ 위 폴더 · F5 새로 고침 · Ctrl+F 이름으로 거르기

$ErrorActionPreference = 'Stop'

$script:ui = @{}
$script:current = $null      # 오른쪽에 보이는 폴더 경로. '*' = 즐겨찾기
$script:entries = @()
$script:selecting = $false   # 코드로 트리를 고르는 중
$script:jobs = [System.Collections.Generic.List[object]]::new()
$script:pending = [ordered]@{}
$script:folderWaitMs = 80    # 폴더를 열 때 결과를 기다리는 시간. 로컬 폴더는 이 안에 끝나서 「불러오는 중」이 깜빡이지 않는다
$script:workerFunctions = $null   # 조회 작업에 넣을 함수 (처음 쓸 때 한 번 찾는다)
$script:filterTimer = $null
$script:stopping = $false
$script:treeGeneration = 0
$script:treeTarget = $null       # 트리에서 찾아가는 중인 경로. 하위 폴더를 다 읽으면 이어서 찾는다
$script:treeWaitNode = $null     # 그 경로로 가려고 하위 폴더를 읽는 중인 항목
$script:folderFallback = $null   # 마지막으로 본 폴더를 못 열면 대신 열 폴더 @{ From; To }
$script:treeBatches = [System.Collections.Generic.List[object]]::new()
$script:treeBatchScheduled = $false
$script:shortcutEntry = $null

Register-WtSettingDefault 'docs.roots' @()
Register-WtSettingDefault 'docs.pins' @()
Register-WtSettingDefault 'docs.last' ''

# 확장자 → 종류 이름 · 아이콘
$script:kinds = @{
    '.xlsx' = 'Excel'; '.xlsm' = 'Excel'; '.xls' = 'Excel'; '.xlsb' = 'Excel'; '.csv' = 'CSV'
    '.docx' = 'Word'; '.doc' = 'Word'; '.rtf' = 'Word'
    '.pptx' = 'PowerPoint'; '.ppt' = 'PowerPoint'
    '.pdf' = 'PDF'; '.hwp' = '한글'; '.hwpx' = '한글'; '.vsdx' = 'Visio'; '.vsd' = 'Visio'
    '.txt' = '텍스트'; '.md' = '마크다운'; '.log' = '로그'; '.json' = 'JSON'; '.xml' = 'XML'; '.yaml' = 'YAML'; '.yml' = 'YAML'; '.ini' = '설정'; '.conf' = '설정'; '.cfg' = '설정'
    '.png' = '그림'; '.jpg' = '그림'; '.jpeg' = '그림'; '.gif' = '그림'; '.bmp' = '그림'; '.svg' = '그림'; '.webp' = '그림'
    '.zip' = '압축'; '.7z' = '압축'; '.rar' = '압축'; '.tar' = '압축'; '.gz' = '압축'
    '.msg' = '메일'; '.eml' = '메일'; '.lnk' = '바로가기'; '.url' = '바로가기'
    '.ps1' = 'PowerShell'; '.psm1' = 'PowerShell'; '.bat' = '배치'; '.cmd' = '배치'; '.exe' = '프로그램'; '.msi' = '설치'
}
$script:kindIcons = @{
    '폴더' = 0xE8B7; 'Excel' = 0xE80A; 'CSV' = 0xE80A; 'PowerPoint' = 0xE786; '그림' = 0xE91B; '압축' = 0xE7B8
    '메일' = 0xE715; 'PowerShell' = 0xE943; '배치' = 0xE943; '프로그램' = 0xE7AC; '설치' = 0xE7AC; '없음' = 0xE7BA
}
# 열기 전에 한 번 묻는 실행 파일
$script:runnable = @('.exe', '.msi', '.bat', '.cmd', '.ps1', '.psm1', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.hta', '.scr', '.com', '.reg', '.cpl')

# ---- 파일 목록 (WPF 없이) ---------------------------------------------------------------------

function Get-WtDocKind([string]$Name, [bool]$IsDir) {
    if ($IsDir) { return '폴더' }
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
    if ($script:kinds.ContainsKey($ext)) { return $script:kinds[$ext] }
    if ($ext) { return $ext.TrimStart('.').ToUpperInvariant() }
    '파일'
}

function Get-WtDocIcon([string]$Kind) { if ($script:kindIcons.ContainsKey($Kind)) { $script:kindIcons[$Kind] } else { 0xE8A5 } }

# Explorer처럼: 1 KB 단위 올림, 1024 KB부터 MB, 1024 MB부터 GB
function Format-WtDocSize($Bytes) {
    if ($null -eq $Bytes) { return '' }
    $b = [double]$Bytes
    if ($b -lt 1024 * 1024) { return '{0:N0} KB' -f [Math]::Ceiling($b / 1024) }
    if ($b -lt 1024 * 1024 * 1024) { return '{0:N1} MB' -f ($b / 1MB) }
    '{0:N1} GB' -f ($b / 1GB)
}

function New-WtDocEntry([System.IO.FileSystemInfo]$Info) {
    $isDir = $Info -is [System.IO.DirectoryInfo]
    $kind = Get-WtDocKind $Info.Name $isDir
    [pscustomobject]@{
        Name = $Info.Name; Path = $Info.FullName; IsDir = $isDir; Kind = $kind
        Size = $(if ($isDir) { $null } else { $Info.Length }); Modified = $Info.LastWriteTime; Missing = $false
        SizeText = $(if ($isDir) { '' } else { Format-WtDocSize $Info.Length })
        ModifiedText = $Info.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); IconText = [string][char](Get-WtDocIcon $kind)
    }
}

# 폴더 안 항목: 숨김 · 시스템은 빼고, 폴더 먼저 · 이름 순. 열 수 없으면 예외
function Get-WtDocEntries([string]$Path, $Cancel = $null) {
    $dir = [System.IO.DirectoryInfo]::new($Path)
    $hidden = [System.IO.FileAttributes]'Hidden, System'
    $list = foreach ($fsi in $dir.EnumerateFileSystemInfos()) {
        if ($Cancel -and $Cancel.Value) { return @() }
        if ($fsi.Attributes -band $hidden) { continue }
        New-WtDocEntry $fsi
    }
    @($list | Sort-Object -Property @{ Expression = { -not $_.IsDir } }, @{ Expression = { $_.Name }; Descending = $false } -Culture 'ko-KR')
}

# 하위 폴더 경로들 (트리 펼치기용). 열 수 없으면 빈 목록
function Get-WtDocSubfolders([string]$Path, [switch]$Strict) {
    try {
        $hidden = [System.IO.FileAttributes]'Hidden, System'
        @([System.IO.DirectoryInfo]::new($Path).EnumerateDirectories() | Where-Object { -not ($_.Attributes -band $hidden) } |
                Sort-Object Name -Culture 'ko-KR' | ForEach-Object { $_.FullName })
    } catch { if ($Strict) { throw }; @() }
}

# 즐겨찾기 항목. 없어진 경로도 보여 줘서 뺄 수 있게 한다
function Get-WtDocPinEntries([string[]]$Paths = @(Get-WtSetting 'docs.pins'), $Cancel = $null) {
    foreach ($p in $Paths) {
        if ($Cancel -and $Cancel.Value) { return }
        $p = [string]$p
        if (-not $p) { continue }
        if (Test-Path -LiteralPath $p) { New-WtDocEntry (Get-Item -LiteralPath $p -Force) }
        else { [pscustomobject]@{ Name = (Split-Path $p -Leaf); Path = $p; IsDir = $false; Kind = '없음'; Size = $null; Modified = $null; Missing = $true; SizeText = ''; ModifiedText = ''; IconText = [string][char]0xE7BA } }
    }
}

function Test-WtDocPinned([string]$Path) { @(Get-WtSetting 'docs.pins') -contains $Path }

# 즐겨찾기에 넣거나 뺀다. 넣었으면 $true
function Switch-WtDocPin([string]$Path) {
    $pins = @(@(Get-WtSetting 'docs.pins') | ForEach-Object { [string]$_ } | Where-Object { $_ })
    if ($pins -contains $Path) { Set-WtSetting 'docs.pins' @($pins | Where-Object { $_ -ne $Path }); return $false }
    Set-WtSetting 'docs.pins' @($pins + $Path)
    $true
}

function Get-WtDocRoots { @(@(Get-WtSetting 'docs.roots') | ForEach-Object { [string]$_ } | Where-Object { $_ }) }

# 경로가 들어 있는 맨 위 폴더부터 그 경로까지 차례로 (트리를 펼쳐 찾아가기용). 맨 위 폴더 밖이면 빈 목록
function Get-WtDocChain([string[]]$Roots, [string]$Path) {
    $norm = { param($p) $p.TrimEnd('\', '/') }
    $target = & $norm $Path
    foreach ($r in $Roots) {
        $root = & $norm $r
        if ($target -ieq $root -or $target.StartsWith("$root\", [System.StringComparison]::OrdinalIgnoreCase)) {
            $chain = [System.Collections.Generic.List[string]]::new()
            $chain.Add($r)
            $cur = $root
            foreach ($part in ($target.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
                $cur = "$cur\$part"
                $chain.Add($cur)
            }
            return $chain.ToArray()
        }
    }
}

# 경로 표시: 맨 위 폴더 이름부터 › 로 잇는다 (예: 업무 문서 › 운영 › 점검 기록). 맨 위 폴더 밖이면 전체 경로
function Format-WtDocPathLabel([string[]]$Roots, [string]$Path) {
    $chain = @(Get-WtDocChain $Roots $Path)
    if (-not $chain.Count) { return $Path }
    $first = Split-Path $chain[0].TrimEnd('\') -Leaf
    if (-not $first) { $first = $chain[0] }
    (@($first) + @($chain | Select-Object -Skip 1 | ForEach-Object { Split-Path $_ -Leaf })) -join ' › '
}

# 이름에 낱말이 모두 들어 있는 항목 (띄어 쓰면 AND)
function Find-WtDocEntry([object[]]$Entries, [string]$Query) {
    $words = @($Query -split '\s+' | Where-Object { $_ })
    if (-not $words.Count) { return $Entries }
    $Entries | Where-Object { $n = $_.Name; -not ($words | Where-Object { $n -notlike "*$_*" }) }
}

# ---- 열기 ------------------------------------------------------------------------------------

# 여는 것 · 탐색기에서 보여 주는 것은 확인까지 화면 밖에서 한다 (core\Work.psm1 Open-WtPath). 응답 없는 공유 폴더여도 화면이 멈추지 않는다
function Open-WtDocEntry($Entry) {
    if (-not $Entry) { return }
    if ($Entry.Missing) { Show-WtMessage "찾을 수 없습니다. 옮기거나 지웠으면 즐겨찾기에서 빼세요.`n$($Entry.Path)"; return }
    if ($Entry.IsDir) {
        Add-WtUse -Page 'docs' -Key $Entry.Path -Title $Entry.Name -Sub '문서' -Icon 0xE8B7
        Show-WtDocFolder $Entry.Path -SelectTree; return
    }
    $ext = [System.IO.Path]::GetExtension($Entry.Path).ToLowerInvariant()
    if ($script:runnable -contains $ext) {
        if (-not (Confirm-WtYesNo "'$($Entry.Name)'은(는) 실행되는 파일입니다. 실행할까요?")) { return }
    }
    Add-WtUse -Page 'docs' -Key $Entry.Path -Title $Entry.Name -Sub '문서' -Icon 0xE8A5
    Open-WtPath $Entry.Path -NotFound "찾을 수 없습니다. 옮기거나 지웠으면 새로 고침하세요.`n$($Entry.Path)"
}

function Test-WtDocShortcut([string]$Key) {
    try { [bool](Invoke-WtWork { param($path) Test-Path -LiteralPath $path } -Session Default -ArgumentList $Key -Key (Get-WtPathKey $Key) -TimeoutMs $script:folderWaitMs) }
    catch { $false }
}

function Open-WtDocArgs($OpenArgs) {
    if (-not $OpenArgs.Key) { return }
    [void](Start-WtWork -Script { param($path) if (Test-Path -LiteralPath $path) { Get-Item -LiteralPath $path } } -Session Default -ArgumentList ([string]$OpenArgs.Key) `
        -Key (Get-WtPathKey ([string]$OpenArgs.Key)) -TimeoutMs 10000 -OnDone {
            param($work)
            if ($work.State -ne 'done' -or -not $work.Result) { return }
            $script:shortcutEntry = New-WtDocEntry $work.Result
            Show-WtDocFolder (Split-Path $script:shortcutEntry.Path -Parent) -SelectTree
            Complete-WtDocShortcutSelection
        })
}

function Complete-WtDocShortcutSelection {
    if (-not $script:shortcutEntry -or $script:ui.Loading) { return }
    $entry = $script:entries | Where-Object Path -eq $script:shortcutEntry.Path | Select-Object -First 1
    $script:shortcutEntry = $null
    if ($entry) {
        $script:ui.List.SelectedItem = $entry; $script:ui.List.ScrollIntoView($entry)
        Open-WtDocEntry $entry
    }
}

function Show-WtDocInExplorer([string]$Path) { Open-WtPath $Path -Reveal }

function Copy-WtDocPath([string]$Path) {
    try { [System.Windows.Clipboard]::SetText($Path) } catch { Show-WtMessage '클립보드를 다른 프로그램이 쓰고 있어서 복사하지 못했습니다. 다시 누르세요.' 'WorkTool' 'Warning'; return }
    Set-WtDocStatus "경로를 복사했습니다: $Path"
}

# ---- 화면 -------------------------------------------------------------------------------------

# 조회 하나를 실행하는 코드. 취소는 다음 파일부터 적용되며, 진행 중인 OS 호출은 끝날 때까지 기다릴 수 있다.
$script:worker = {
    param($request, $kinds, $icons)
    $ErrorActionPreference = 'Stop'
    $script:kinds = $kinds; $script:kindIcons = $icons
    try {
        $items = switch ($request.Action) {
            'folder' { @(Get-WtDocEntries $request.Path $request.Cancel) }
            'tree' { @(Get-WtDocSubfolders $request.Path -Strict) }
            'pins' { @(Get-WtDocPinEntries -Paths $request.Pins -Cancel $request.Cancel) }
        }
        @{ Items = @($items); Error = $null }
    } catch { @{ Items = @(); Error = $_.Exception.InnerException.Message ?? $_.Exception.Message } }
}

function Start-WtDocRequest([string]$Key, [string]$Action, [string]$Path = '', $Context = $null) {
    $script:stopping = $false
    foreach ($job in $script:jobs) { if ($job.Key -eq $Key) { $job.Request.Cancel.Value = $true } }
    if ($Key -notin 'folder', 'home' -and -not $script:pending.Contains($Key) -and $script:pending.Count -ge 32) { return $false }
    $request = @{ Action = $Action; Path = $Path; Pins = @(Get-WtSetting 'docs.pins'); Cancel = [hashtable]::Synchronized(@{ Value = $false }) }
    if ($Key -eq 'home') { $request.Pins = @($request.Pins | Select-Object -First 6) }
    $script:pending[$Key] = @{ Key = $Key; Request = $request; Context = $Context; Generation = $script:treeGeneration }
    Start-WtDocJobs
    $true
}

# 응답 없는 공유 폴더를 기다리느라 다른 조회가 막히지 않게, 취소했거나 새 요청으로 바뀐 조회는 자리를 차지하지 않는다.
# 폴더 · 홈 즐겨찾기는 하나씩, 트리는 둘까지 실행한다. 취소한 것까지 합쳐 8개가 돌고 있으면 끝나기를 기다린다.
function Test-WtDocJobSlot([string]$Key) {
    if ($script:jobs.Count -ge 8) { return $false }
    $active = @($script:jobs | Where-Object { -not $_.Request.Cancel.Value })
    if ($Key -in 'folder', 'home') { return -not @($active | Where-Object Key -eq $Key).Count }
    @($active | Where-Object { $_.Key -notin 'folder', 'home' }).Count -lt 2
}

# 조회 하나는 화면 밖 작업 하나(core\Work.psm1)다. 끝나면 Complete-WtDocJob이 화면 스레드에서 결과를 넣는다
function Start-WtDocJobs {
    if ($script:stopping) { return }
    $keys = @(@('folder', 'home') | Where-Object { $script:pending.Contains($_) }) + @($script:pending.Keys | Where-Object { $_ -notin 'folder', 'home' })
    foreach ($key in $keys) {
        if (-not $script:pending.Contains($key) -or -not (Test-WtDocJobSlot $key)) { continue }
        $job = $script:pending[$key]; $script:pending.Remove($key)
        $script:jobs.Add($job)
        if (-not $script:workerFunctions) {
            $script:workerFunctions = @(Get-Command Get-WtDocKind, Get-WtDocIcon, Format-WtDocSize, New-WtDocEntry, Get-WtDocEntries, Get-WtDocSubfolders, Get-WtDocPinEntries)
        }
        try {
            $job.Work = Start-WtWork -Script $script:worker -ArgumentList $job.Request, $script:kinds, $script:kindIcons -Session Default -Context $job `
                -Functions $script:workerFunctions -OnDone { param($w) Complete-WtDocJob $w }
        } catch {
            [void]$script:jobs.Remove($job)
            Set-WtDocResult $job @{ Items = @(); Error = $_.Exception.Message }
        }
    }
}

function Complete-WtDocJob($Work) {
    $job = $Work.Context
    [void]$script:jobs.Remove($job)
    $result = if ($Work.State -eq 'done' -and $Work.Result) { $Work.Result }
    else { @{ Items = @(); Error = $(if ($Work.Error) { $Work.Error } else { '조회가 취소되었거나 완료되지 않았습니다.' }) } }
    try { if (-not $script:stopping -and -not $job.Request.Cancel.Value) { Set-WtDocResult $job $result } }
    finally { Start-WtDocJobs }
}

# 끝난 조회를 지금 거둔다 (검사에서 부른다. 앱에서는 core\Work.psm1의 타이머가 거둔다)
function Complete-WtDocJobs {
    Update-WtWork
    Start-WtDocJobs
}

# 지금 폴더 조회를 잠깐 기다린다. 화면을 다 꾸린 뒤에 부른다 (결과를 넣는 처리기가 화면을 바꾸므로)
function Wait-WtDocJob([string]$Key) {
    $job = $null
    foreach ($j in $script:jobs) { if ($j.Key -eq $Key -and $j.Work -and -not $j.Request.Cancel.Value) { $job = $j } }
    if ($job) { [void](Wait-WtWork $job.Work -Milliseconds $script:folderWaitMs) }
}

function Set-WtDocResult($Job, $Result) {
    switch ($Job.Key) {
        'folder' {
            if (-not $script:ui.Count -or $Job.Request.Path -ne $script:current) { return }
            $fallback = $script:folderFallback; $script:folderFallback = $null
            if ($Result.Error -and $fallback -and $fallback.From -eq $Job.Request.Path) {
                # 마지막으로 본 폴더가 없어졌거나 연결되지 않으면 첫 폴더를 연다 (화면을 멈추는 존재 확인 없이)
                Show-WtDocFolder $fallback.To -SelectTree
                return
            }
            $script:entries = @($Result.Items)
            $script:ui.Loading = $false
            $script:ui.Error = if ($Result.Error) { "폴더를 열지 못했습니다. $($Result.Error)" } else { $null }
            if (-not $Result.Error -and $script:current -ne '*') {
                try { Set-WtSetting 'docs.last' $script:current } catch { $script:ui.Error = '마지막 위치를 저장하지 못했습니다. 폴더 쓰기 권한을 확인하세요.' }
            }
            Update-WtDocList
            Complete-WtDocShortcutSelection
        }
        'home' {
            $col = $Job.Context
            $col.Children.Clear()
            [void](Add-WtChild $col (New-WtCardHeader '즐겨찾기 문서' '' '문서 열기' 'docs'))
            if ($Result.Error) { [void](Add-WtChild $col (New-WtText '즐겨찾기를 읽지 못했습니다. 문서 탭에서 다시 시도하세요.' 'T.Sub')); return }
            foreach ($p in $Result.Items) {
                $b = New-WtButton $p.Name -Kind Link -Icon (Get-WtDocIcon $p.Kind) -ToolTip $p.Path
                $b.HorizontalAlignment = 'Left'; $b.Tag = $p
                $b.Add_Click({ param($s, $e) if ($s.Tag.IsDir) { Select-WtPage 'docs'; Show-WtDocFolder $s.Tag.Path -SelectTree } else { Open-WtDocEntry $s.Tag } })
                [void](Add-WtChild $col $b)
            }
        }
        default {
            if ($Job.Generation -ne $script:treeGeneration) { return }
            $node = $Job.Context
            $node.Items.Clear()
            if ($Result.Error) {
                $node.Tag.Loading = $false; [void]$node.Items.Add('읽지 못했습니다. 접었다 다시 펼치세요.'); $node.ToolTip = $Result.Error
                if ([object]::ReferenceEquals($node, $script:treeWaitNode)) { $script:treeWaitNode = $null; $script:treeTarget = $null }
                return
            }
            $node.Tag.Loading = $true
            [void]$node.Items.Add('불러오는 중…')
            $script:treeBatches.Add(@{ Node = $node; Paths = @($Result.Items); Index = 0; Generation = $Job.Generation })
            Request-WtDocTreeBatch
        }
    }
}

function Request-WtDocTreeBatch {
    if ($script:treeBatchScheduled -or $script:stopping -or -not $script:treeBatches.Count) { return }
    $script:treeBatchScheduled = $true
    [void]$script:ui.Tree.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [Action]{ Complete-WtDocTreeBatch })
}

function Complete-WtDocTreeBatch {
    $script:treeBatchScheduled = $false
    if ($script:stopping -or -not $script:treeBatches.Count) { return }
    $batch = $script:treeBatches[0]
    if ($batch.Generation -ne $script:treeGeneration) { $script:treeBatches.RemoveAt(0); Request-WtDocTreeBatch; return }
    $node = $batch.Node
    if ($node.Items.Count -and $node.Items[$node.Items.Count - 1] -is [string]) { $node.Items.RemoveAt($node.Items.Count - 1) }
    $budget = Get-WtUiWorkBudget
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $added = 0
    while ($batch.Index -lt $batch.Paths.Count -and $added -lt $budget.Items) {
        $path = $batch.Paths[$batch.Index]
        [void]$node.Items.Add((New-WtDocTreeItem (Split-Path $path -Leaf) $path 0xE8B7))
        $batch.Index++; $added++
        if ($watch.ElapsedMilliseconds -ge $budget.Milliseconds) { break }
    }
    if ($batch.Index -eq $batch.Paths.Count) {
        $node.Tag.Loaded = $true; $node.Tag.Loading = $false
        $script:treeBatches.RemoveAt(0)
        # 찾아가던 길의 폴더를 다 읽었을 때만 이어서 찾는다. 다른 폴더를 펼쳐도 선택 · 스크롤 · 접어 둔 폴더를 건드리지 않는다
        if ($script:treeTarget -and [object]::ReferenceEquals($node, $script:treeWaitNode)) { Select-WtDocTreePath $script:treeTarget }
    } else { [void]$node.Items.Add('불러오는 중…') }
    Request-WtDocTreeBatch
}

# 끝낼 때: 남은 조회는 기다리지 않고 버린다. 응답 없는 공유 폴더의 OS 요청은 돌아오지 않을 수 있기 때문이다
function Stop-WtDocs {
    $script:stopping = $true
    $script:pending.Clear()
    $script:treeBatches.Clear()
    foreach ($job in @($script:jobs)) {
        $job.Request.Cancel.Value = $true
        $job.Context = $null
        Stop-WtWork $job.Work
    }
    $script:jobs.Clear()
    if ($script:filterTimer) { $script:filterTimer.Stop() }
}

function Cancel-WtDocFolder {
    $script:pending.Remove('folder')
    foreach ($job in $script:jobs) { if ($job.Key -eq 'folder') { $job.Request.Cancel.Value = $true } }
    $script:ui.Loading = $false; $script:ui.Error = '조회를 취소했습니다. 새로 고침으로 다시 시도하세요.'
    Update-WtDocList
}

function Get-WtDocSelected { $script:ui.List.SelectedItem }

function Set-WtDocStatus([string]$Text) { $script:ui.Status.Text = $Text }

function New-WtDocTreeItem([string]$Label, [string]$Path, [int]$Icon, [switch]$Leaf) {
    $ti = [System.Windows.Controls.TreeViewItem]::new()
    Set-WtStyle $ti 'TreeItem'
    $row = New-WtStack Horizontal 8
    $ic = New-WtIcon $Icon
    Set-WtResource $ic 'Foreground' 'B.SubText'
    [void](Add-WtChild $row $ic)
    $name = [System.Windows.Controls.TextBlock]::new()
    $name.Text = $Label
    $name.TextTrimming = 'CharacterEllipsis'
    $name.VerticalAlignment = 'Center'
    [void](Add-WtChild $row $name)
    $ti.Header = $row
    $ti.ToolTip = $Path
    $ti.Tag = @{ Path = $Path; Loaded = [bool]$Leaf; Loading = $false }
    if (-not $Leaf) { [void]$ti.Items.Add('…') }   # 펼칠 때 하위 폴더를 읽는다
    $ti.Add_Expanded({
            param($s, $e)
            if ($e.OriginalSource -eq $s) { Expand-WtDocNode $s }
        })
    $ti
}

function Expand-WtDocNode($Node) {
    if ($Node.Tag.Loaded -or $Node.Tag.Loading) { return }
    $Node.Tag.Loading = Start-WtDocRequest "tree:$($Node.Tag.Path)" 'tree' $Node.Tag.Path $Node
}

function Get-WtDocRootLabel([string]$Path) {
    $leaf = Split-Path $Path.TrimEnd('\') -Leaf
    if ($leaf) { $leaf } else { $Path }
}

function Update-WtDocTree {
    $script:treeGeneration++
    $script:treeTarget = $null; $script:treeWaitNode = $null
    $script:treeBatches.Clear()
    foreach ($key in @($script:pending.Keys)) { if ($key.StartsWith('tree:')) { $script:pending.Remove($key) } }
    foreach ($job in $script:jobs) { if ($job.Request.Action -eq 'tree') { $job.Request.Cancel.Value = $true; $job.Context = $null } }
    $tree = $script:ui.Tree
    $tree.Items.Clear()
    [void]$tree.Items.Add((New-WtDocTreeItem '즐겨찾기' '*' 0xE734 -Leaf))
    foreach ($r in (Get-WtDocRoots)) { [void]$tree.Items.Add((New-WtDocTreeItem (Get-WtDocRootLabel $r) $r 0xE8B7)) }
    $script:ui.RemoveRoot.IsEnabled = $false
}

# 트리에서 경로에 맞는 항목을 펼쳐 찾아 고른다. 아직 읽지 않은 폴더를 만나면 읽은 뒤 이어서 찾는다
function Select-WtDocTreePath([string]$Path) {
    $script:treeTarget = $Path
    $script:treeWaitNode = $null
    $items = $script:ui.Tree.Items
    $found = $null
    if ($Path -eq '*') { $found = $items[0] }
    else {
        foreach ($step in (Get-WtDocChain (Get-WtDocRoots) $Path)) {
            $next = $items | Where-Object { $_ -is [System.Windows.Controls.TreeViewItem] -and $_.Tag.Path.TrimEnd('\') -ieq $step.TrimEnd('\') } | Select-Object -First 1
            if (-not $next) { break }
            $found = $next
            if ($step.TrimEnd('\') -ine $Path.TrimEnd('\')) {
                Expand-WtDocNode $next; $next.IsExpanded = $true
                if (-not $next.Tag.Loaded) { $script:treeWaitNode = $next; break }
            }
            $items = $next.Items
        }
    }
    if (-not $script:treeWaitNode) { $script:treeTarget = $null }
    if ($found) {
        $script:selecting = $true
        try { $found.IsSelected = $true; $found.BringIntoView() } finally { $script:selecting = $false }
    }
}

# 오른쪽에 폴더(또는 즐겨찾기 '*')를 보여 준다. -Fallback: 이 폴더를 못 열면 대신 열 폴더
function Show-WtDocFolder([string]$Path, [switch]$SelectTree, [string]$Fallback = '') {
    $script:current = $Path
    $script:folderFallback = if ($Fallback) { @{ From = $Path; To = $Fallback } } else { $null }
    # 트리를 직접 고른 경우 등: 찾아가던 길이 있으면 그만둔다
    if (-not $SelectTree) { $script:treeTarget = $null; $script:treeWaitNode = $null }
    $script:entries = @()
    $script:ui.Loading = [bool]$Path
    $script:ui.Filter.Text = ''
    $script:ui.Error = $null
    if ($Path -eq '*') {
        $script:ui.PathText.Text = '즐겨찾기'
        [void](Start-WtDocRequest 'folder' 'pins' $Path)
    } elseif (-not $Path) {
        $script:ui.PathText.Text = ''
        $script:entries = @()
    } else {
        $script:ui.PathText.Text = Format-WtDocPathLabel (Get-WtDocRoots) $Path
        [void](Start-WtDocRequest 'folder' 'folder' $Path)
    }
    $script:ui.PathText.ToolTip = if ($Path -and $Path -ne '*') { $Path } else { $null }
    $script:ui.OpenFolder.IsEnabled = $Path -and $Path -ne '*'
    $script:ui.Up.IsEnabled = $Path -and $Path -ne '*' -and -not (@(Get-WtDocRoots) | Where-Object { $_.TrimEnd('\') -ieq $Path.TrimEnd('\') })
    Update-WtDocList
    if ($SelectTree) { Select-WtDocTreePath $Path }
    Wait-WtDocJob 'folder'
}

function Update-WtDocList {
    $list = $script:ui.List
    $selected = $list.SelectedItem
    $shown = @(Find-WtDocEntry $script:entries $script:ui.Filter.Text)
    $list.ItemsSource = $shown
    if ($selected) { $list.SelectedItem = $shown | Where-Object Path -eq $selected.Path | Select-Object -First 1 }
    # 비어 있을 때 · 오류일 때 안내
    $msg = $null
    $action = $false
    if ($script:ui.Loading) { $msg = '불러오는 중…' }
    elseif ($script:ui.Error) { $msg = $script:ui.Error }
    elseif (-not @(Get-WtDocRoots).Count -and $script:current -ne '*') { $msg = '볼 폴더를 추가하세요.'; $action = $true }
    elseif ($script:current -eq '*' -and -not $script:entries.Count) { $msg = '즐겨찾기가 없습니다. 파일을 고르고 [즐겨찾기]를 누르세요.' }
    elseif (-not $script:current) { $msg = '왼쪽에서 폴더를 고르세요.' }
    elseif (-not $script:entries.Count) { $msg = '빈 폴더입니다.' }
    elseif (-not $shown.Count) { $msg = '이름이 맞는 항목이 없습니다.' }
    $script:ui.EmptyText.Text = [string]$msg
    Set-WtResource $script:ui.EmptyText 'Foreground' $(if ($script:ui.Error) { 'B.Danger' } else { 'B.SubText' })
    $script:ui.EmptyAdd.Visibility = if ($action) { 'Visible' } else { 'Collapsed' }
    $script:ui.Empty.Visibility = if ($msg) { 'Visible' } else { 'Collapsed' }
    $script:ui.Cancel.Visibility = if ($script:ui.Loading) { 'Visible' } else { 'Collapsed' }
    $dirs = @($shown | Where-Object IsDir).Count
    Set-WtDocStatus $(if ($script:current) { "폴더 $dirs · 파일 $($shown.Count - $dirs)" } else { '' })
    Update-WtDocCommands
}

# 아래 명령: 고른 항목이 있을 때만 쓸 수 있다
function Update-WtDocCommands {
    $e = Get-WtDocSelected
    $has = [bool]$e
    foreach ($b in $script:ui.ItemButtons) {
        $b.IsEnabled = $has -and -not ($e.Missing -and $b -ne $script:ui.Pin)
        $b.ToolTip = if ($has) { $b.Tag } else { '파일이나 폴더를 먼저 고르세요' }
    }
    $pinned = $has -and (Test-WtDocPinned $e.Path)
    $script:ui.Pin.Content = New-WtButtonContent $(if ($pinned) { '즐겨찾기에서 빼기' } else { '즐겨찾기' }) $(if ($pinned) { 0xE735 } else { 0xE734 })
    $script:ui.Open.Content = New-WtButtonContent $(if ($has -and $e.IsDir) { '들어가기' } else { '열기' }) 0xE8E5
}

function Add-WtDocRoot {
    $dlg = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dlg.Description = '문서 탭에서 볼 폴더를 고르세요 (공유 폴더도 됩니다)'
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $path = $dlg.SelectedPath
    $roots = @(Get-WtDocRoots)
    if (-not ($roots | Where-Object { $_ -ieq $path })) { Set-WtSetting 'docs.roots' @($roots + $path) }
    Update-WtDocTree
    Show-WtDocFolder $path -SelectTree
}

function Remove-WtDocRoot {
    $node = $script:ui.Tree.SelectedItem
    if (-not $node -or -not ($node.Parent -is [System.Windows.Controls.TreeView]) -or $node.Tag.Path -eq '*') { return }
    $path = $node.Tag.Path
    Set-WtSetting 'docs.roots' @(Get-WtDocRoots | Where-Object { $_ -ine $path })
    Update-WtDocTree
    Show-WtDocFolder '*' -SelectTree
    Set-WtDocStatus "목록에서 뺐습니다: $path (폴더와 파일은 그대로)"
}

function New-WtDocsView {
    if ($script:filterTimer) { $script:filterTimer.Stop() }
    $script:ui = @{}
    $page = New-WtPage -Fill
    $add = New-WtButton '폴더 추가' -Icon 0xE710 -ToolTip '볼 폴더 추가'
    $add.Add_Click({ Add-WtDocRoot })
    $header = New-WtPageHeader '문서' '' $add
    [System.Windows.Controls.DockPanel]::SetDock($header, 'Top')
    [void]$page.Panel.Children.Add($header)

    $grid = [System.Windows.Controls.Grid]::new()
    $c1 = [System.Windows.Controls.ColumnDefinition]::new(); $c1.Width = [System.Windows.GridLength]::new(280)
    $c2 = [System.Windows.Controls.ColumnDefinition]::new(); $c2.Width = [System.Windows.GridLength]::new(1, 'Star')
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    # 왼쪽: 즐겨찾기 + 폴더 트리
    $left = New-WtCard
    $left.Padding = [System.Windows.Thickness]::new(12)
    $left.Margin = [System.Windows.Thickness]::new(0, 0, 16, 0)
    $ldock = [System.Windows.Controls.DockPanel]::new()
    $remove = New-WtButton '목록에서 빼기' -Kind Link -Icon 0xE738
    $remove.ToolTip = '고른 맨 위 폴더를 목록에서 뺍니다 (폴더는 그대로)'
    $remove.HorizontalAlignment = 'Left'
    $remove.Add_Click({ Remove-WtDocRoot })
    [System.Windows.Controls.DockPanel]::SetDock($remove, 'Bottom')
    [void]$ldock.Children.Add($remove)
    $tree = [System.Windows.Controls.TreeView]::new()
    Set-WtStyle $tree 'Tree'
    $tree.Add_SelectedItemChanged({
            param($s, $e)
            $node = $s.SelectedItem
            $script:ui.RemoveRoot.IsEnabled = [bool]($node -and $node.Parent -is [System.Windows.Controls.TreeView] -and $node.Tag.Path -ne '*')
            if ($script:selecting -or -not $node -or $node -isnot [System.Windows.Controls.TreeViewItem]) { return }
            if ($node.Tag.Path -ne $script:current) { Show-WtDocFolder $node.Tag.Path }
        })
    [void]$ldock.Children.Add($tree)
    $left.Child = $ldock
    [System.Windows.Controls.Grid]::SetColumn($left, 0)
    [void]$grid.Children.Add($left)

    # 오른쪽: 경로 · 거르기 · 목록 · 명령
    $right = New-WtCard
    $right.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
    $rdock = [System.Windows.Controls.DockPanel]::new()

    $top = [System.Windows.Controls.DockPanel]::new()
    $up = New-WtButton '' -Kind Icon -Icon 0xE74A -ToolTip '위 폴더 (Alt+↑)'
    $up.Add_Click({ Show-WtDocFolder (Split-Path $script:current -Parent) -SelectTree })
    [System.Windows.Controls.DockPanel]::SetDock($up, 'Left')
    [void]$top.Children.Add($up)
    $refresh = New-WtButton '' -Kind Icon -Icon 0xE72C -ToolTip '새로 고침 (F5)'
    $refresh.Add_Click({ Show-WtDocFolder $script:current })
    $openFolder = New-WtButton '탐색기에서 열기' -Kind Link -Icon 0xE838
    $openFolder.Add_Click({ if ($script:current -and $script:current -ne '*') { Open-WtPath $script:current } })
    foreach ($b in @($openFolder, $refresh)) { [System.Windows.Controls.DockPanel]::SetDock($b, 'Right'); [void]$top.Children.Add($b) }
    $pathText = New-WtText '' 'T.Strong'
    $pathText.TextWrapping = 'NoWrap'
    $pathText.TextTrimming = 'CharacterEllipsis'
    $pathText.VerticalAlignment = 'Center'
    $pathText.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
    [void]$top.Children.Add($pathText)
    $sb = New-WtSearchBox '이 폴더에서 이름으로 찾기'
    $filter = $sb.Box
    $filter.ToolTip = '띄어 쓰면 낱말이 모두 들어간 이름만 (Ctrl+F)'
    $script:filterTimer = New-WtPollTimer { $script:filterTimer.Stop(); Update-WtDocList }
    $filter.Add_TextChanged({ $script:filterTimer.Stop(); $script:filterTimer.Start() })
    $sb.Root.Margin = [System.Windows.Thickness]::new(0, 8, 0, 8)
    $cols = [System.Windows.Controls.DockPanel]::new()
    $cols.Margin = [System.Windows.Thickness]::new(12, 0, 12, 4)
    foreach ($h in @(@('크기', 80, 'Right'), @('고친 날짜', 130, 'Left'), @('종류', 90, 'Left'))) {
        $t = New-WtText $h[0] 'T.Sub'
        $t.FontWeight = 'SemiBold'
        $t.Width = $h[1]; $t.TextAlignment = $h[2]
        $t.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
        [System.Windows.Controls.DockPanel]::SetDock($t, 'Right')
        [void]$cols.Children.Add($t)
    }
    $nameHead = New-WtText '이름' 'T.Sub'
    $nameHead.FontWeight = 'SemiBold'
    $nameHead.Margin = [System.Windows.Thickness]::new(28, 0, 0, 0)
    [void]$cols.Children.Add($nameHead)
    $headStack = New-WtStack Vertical
    foreach ($x in @($top, $sb.Root, $cols)) { [void]$headStack.Children.Add($x) }
    $line = [System.Windows.Controls.Border]::new()
    Set-WtStyle $line 'Divider'
    [void]$headStack.Children.Add($line)
    [System.Windows.Controls.DockPanel]::SetDock($headStack, 'Top')
    [void]$rdock.Children.Add($headStack)

    # 아래 명령
    $cmd = [System.Windows.Controls.DockPanel]::new()
    $cmd.Margin = [System.Windows.Thickness]::new(0, 12, 0, 0)
    $status = New-WtText '' 'T.Sub'
    $status.VerticalAlignment = 'Center'
    $status.TextTrimming = 'CharacterEllipsis'
    $status.TextWrapping = 'NoWrap'
    $btns = New-WtStack Horizontal 8
    $open = New-WtButton '열기' -Kind Primary -Icon 0xE8E5
    $open.Tag = '원래 프로그램으로 열기 (Enter · 두 번 클릭)'
    $open.Add_Click({ Open-WtDocEntry (Get-WtDocSelected) })
    $reveal = New-WtButton '폴더에서 보기' -Icon 0xE838
    $reveal.Tag = '탐색기에서 이 파일을 골라 보여 줍니다'
    $reveal.Add_Click({ $x = Get-WtDocSelected; if ($x) { Show-WtDocInExplorer $x.Path } })
    $copy = New-WtButton '경로 복사' -Icon 0xE8C8
    $copy.Tag = '전체 경로를 클립보드에 복사'
    $copy.Add_Click({ $x = Get-WtDocSelected; if ($x) { Copy-WtDocPath $x.Path } })
    $pin = New-WtButton '즐겨찾기' -Icon 0xE734
    $pin.Tag = '즐겨찾기에 넣거나 뺍니다 (홈에도 보임)'
    $pin.Add_Click({
            $x = Get-WtDocSelected
            if (-not $x) { return }
            $on = Switch-WtDocPin $x.Path
            if ($script:current -eq '*') { Show-WtDocFolder '*' } else { Update-WtDocCommands }
            Set-WtDocStatus $(if ($on) { "즐겨찾기에 넣었습니다: $($x.Name)" } else { "즐겨찾기에서 뺐습니다: $($x.Name)" })
        })
    foreach ($b in @($open, $reveal, $copy, $pin)) {
        [System.Windows.Controls.ToolTipService]::SetShowOnDisabled($b, $true)   # 못 쓸 때 이유를 보여 준다
        [void](Add-WtChild $btns $b)
    }
    [System.Windows.Controls.DockPanel]::SetDock($btns, 'Left')
    [void]$cmd.Children.Add($btns)
    $status.Margin = [System.Windows.Thickness]::new(12, 0, 0, 0)
    $status.TextAlignment = 'Right'
    [void]$cmd.Children.Add($status)
    $cwrap = New-WtStack Vertical
    $line2 = [System.Windows.Controls.Border]::new()
    Set-WtStyle $line2 'Divider'
    [void]$cwrap.Children.Add($line2)
    [void]$cwrap.Children.Add($cmd)
    [System.Windows.Controls.DockPanel]::SetDock($cwrap, 'Bottom')
    [void]$rdock.Children.Add($cwrap)

    # 목록 + 비었을 때 안내
    $area = [System.Windows.Controls.Grid]::new()
    $list = [System.Windows.Controls.ListBox]::new()
    Set-WtStyle $list 'Doc.List'
    $list.Margin = [System.Windows.Thickness]::new(0, 4, 0, 0)
    $list.Add_SelectionChanged({ Update-WtDocCommands })
    $list.Add_MouseDoubleClick({
            param($s, $e)
            # 행 위에서 두 번 눌렀을 때만 (빈 곳 · 스크롤 막대는 무시)
            $d = $e.OriginalSource
            while ($d -and $d -isnot [System.Windows.Controls.ListBoxItem] -and $d -is [System.Windows.Media.Visual]) { $d = [System.Windows.Media.VisualTreeHelper]::GetParent($d) }
            if ($d -is [System.Windows.Controls.ListBoxItem]) { Open-WtDocEntry $d.Tag }
        })
    $list.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Enter' -and $s.SelectedItem) { Open-WtDocEntry $s.SelectedItem; $e.Handled = $true } })
    $list.ContextMenu = New-WtHomePinContextMenu
    $homePin = [System.Windows.Controls.MenuItem]::new(); $homePin.Header = '홈에 고정'
    [void]$list.ContextMenu.Items.Add($homePin)
    $list.Add_PreviewMouseRightButtonDown({
            param($s, $e)
            $container = [System.Windows.Controls.ItemsControl]::ContainerFromElement($s, $e.OriginalSource)
            $s.ContextMenu.Tag = if ($container) { $container.DataContext } else { $null }
        })
    $list.Add_ContextMenuOpening({
            param($s, $e)
            $entry = if ($s.ContextMenu.Tag) { $s.ContextMenu.Tag } else { $s.SelectedItem }
            if (-not $entry -or $entry.Missing) { $e.Handled = $true; return }
            $s.ContextMenu.Items.Clear()
            [void]$s.ContextMenu.Items.Add((New-WtHomePinMenuItem ([pscustomobject]@{ Page = 'docs'; Key = $entry.Path; Title = $entry.Name; Sub = '문서'; Icon = 0xE8A5 })))
        })
    [void]$area.Children.Add($list)
    $empty = New-WtStack Vertical 12
    $empty.HorizontalAlignment = 'Center'
    $empty.VerticalAlignment = 'Center'
    $emptyText = New-WtText '' 'T.Sub'
    $emptyText.TextAlignment = 'Center'
    $emptyAdd = New-WtButton '폴더 추가' -Icon 0xE710
    $emptyAdd.HorizontalAlignment = 'Center'
    $emptyAdd.Add_Click({ Add-WtDocRoot })
    [void](Add-WtChild $empty $emptyText)
    [void](Add-WtChild $empty $emptyAdd)
    $cancel = New-WtButton '취소' -Kind Link
    $cancel.Add_Click({ Cancel-WtDocFolder })
    $cancel.Visibility = 'Collapsed'
    [void](Add-WtChild $empty $cancel)
    [void]$area.Children.Add($empty)
    [void]$rdock.Children.Add($area)
    $right.Child = $rdock
    [System.Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$grid.Children.Add($right)
    [void]$page.Panel.Children.Add($grid)

    # 문서 화면 안 단축키
    $page.Root.Add_PreviewKeyDown({
            param($s, $e)
            $mods = [System.Windows.Input.Keyboard]::Modifiers
            $key = if ($e.Key -eq 'System') { $e.SystemKey } else { $e.Key }
            if ($key -eq 'F5') { Show-WtDocFolder $script:current; $e.Handled = $true; return }
            if ($key -eq 'Up' -and ($mods -band [System.Windows.Input.ModifierKeys]::Alt) -and $script:ui.Up.IsEnabled) {
                Show-WtDocFolder (Split-Path $script:current -Parent) -SelectTree; $e.Handled = $true; return
            }
            if ($key -eq 'F' -and ($mods -band [System.Windows.Input.ModifierKeys]::Control)) { [void]$script:ui.Filter.Focus(); $e.Handled = $true }
        })

    $script:ui = @{
        Tree = $tree; RemoveRoot = $remove; List = $list; Filter = $filter; PathText = $pathText; Status = $status
        Up = $up; OpenFolder = $openFolder; Open = $open; Pin = $pin; ItemButtons = @($open, $reveal, $copy, $pin)
        Empty = $empty; EmptyText = $emptyText; EmptyAdd = $emptyAdd; Cancel = $cancel; Error = $null; Loading = $false
    }
    $page.Root
}

function Update-WtDocsView {
    Update-WtDocTree
    $roots = @(Get-WtDocRoots)
    $first = if ($roots.Count) { $roots[0] } else { '*' }
    $last = [string](Get-WtSetting 'docs.last')
    if ($last -and $last -ne $first -and (Get-WtDocChain $roots $last).Count) { Show-WtDocFolder $last -SelectTree -Fallback $first }
    else { Show-WtDocFolder $first -SelectTree }
}

# 홈: 즐겨찾기 바로 열기
function New-WtDocsHomeCard {
    $pins = @(Get-WtSetting 'docs.pins')
    if (-not $pins.Count) { return }
    $card = New-WtCard
    $col = New-WtStack Vertical
    [void](Add-WtChild $col (New-WtCardHeader '즐겨찾기 문서' "$($pins.Count)" '문서 열기' 'docs'))
    [void](Add-WtChild $col (New-WtText '불러오는 중…' 'T.Sub'))
    $card.Child = $col
    [void](Start-WtDocRequest 'home' 'pins' '' $col)
    Wait-WtDocJob 'home'
    $card
}

Register-WtAddon -Id 'docs' -Title '문서' -Icon 0xE8B7 -Group '작업' -Order 50 -WarmUp View `
    -NewView { New-WtDocsView } `
    -Refresh { param($view) Update-WtDocsView } `
    -OnOpen { param($OpenArgs) Open-WtDocArgs $OpenArgs } `
    -ShortcutExists { param($Key) Test-WtDocShortcut $Key } `
    -OnExit { Stop-WtDocs } `
    -Help '폴더의 파일을 원래 프로그램으로 엽니다.' `
    -Shortcuts @(@('Enter', '고른 파일 열기 · 폴더 들어가기'), @('Alt + ↑', '위 폴더'), @('F5', '새로 고침'), @('Ctrl + F', '이름으로 필터링'))

Export-ModuleMember -Function Get-WtDocKind, Format-WtDocSize, Get-WtDocEntries, Get-WtDocSubfolders, Get-WtDocPinEntries,
    Test-WtDocPinned, Switch-WtDocPin, Get-WtDocRoots, Get-WtDocChain, Find-WtDocEntry, Format-WtDocPathLabel

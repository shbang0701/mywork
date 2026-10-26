<#
.SYNOPSIS
    WorkTool 새 버전 검사를 모두 돌린다: 코어 검사 → 탭 모아 보기 → 탭 폴더의 검사 → 안정성 · 실행 파일 검사.

.DESCRIPTION
    - 코어: 코드 검사 · 저장 · 설정 · 탭 목록 · 예전 데이터 가져오기 흐름 · 도움말 · 테마 색 대비 · 마크다운 · 코드 색칠 · Mermaid.
      탭이 필요한 곳은 가짜 탭을 등록해서 본다. 진짜 탭의 동작은 그 탭 폴더의 검사가 맡는다.
    - 탭 모아 보기: 앱처럼 모든 탭을 함께 불러와서 ID · 함수 이름이 겹치지 않는지, 도움말이 모든 탭을 싣는지 본다.
    - 탭 폴더의 검사(addons\<이름>\Test-*.ps1)는 찾아서 돌린다. 탭을 더하거나 빼도 이 파일은 고치지 않는다.
    임시 폴더만 쓰고, 문서\WorkTool 같은 실제 데이터 폴더는 건드리지 않는다. 화면 검사는 Windows STA에서만 한다.

.EXAMPLE
    pwsh ./apps/WorkTool/wpf/tests/Test-Core.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param([switch]$NoDesktop)

$ErrorActionPreference = 'Stop'
$global:wtTestNoDesktop = [bool]$NoDesktop   # 이번 검사 프로세스에서만. 창 · 입력 · 전용 프로세스 종료 검사를 뺀다.
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-WtTestCore

$script:failed = 0
function Assert-Wt([string]$Name, [bool]$Ok, $Detail = '') {
    if ($Ok) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name $Detail" -ForegroundColor Red; $script:failed++ }
}
function Get-WtTestJsonCore($Value) { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }

$test = New-WtTestData 'core'
$wpf = Test-WtTestWpf

try {
    # ---- 코드 검사 ----
    # PowerShell 변수는 대소문자를 가리지 않는다. 함수 안에서 $title과 [string]$Title처럼 대소문자만 다른 이름을 쓰면 같은 변수가 된다
    $clash = foreach ($f in (Get-ChildItem $root -Recurse -Include *.psm1, *.ps1)) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
            $names = @($fn.Body.FindAll({ $args[0] -is [System.Management.Automation.Language.VariableExpressionAst] }, $false) |
                    ForEach-Object { $_.VariablePath.UserPath } | Where-Object { $_ -notmatch ':' })
            $plist = if ($fn.Parameters) { $fn.Parameters } elseif ($fn.Body.ParamBlock) { $fn.Body.ParamBlock.Parameters } else { @() }
            $names += @($plist | ForEach-Object { $_.Name.VariablePath.UserPath })
            $names | Group-Object { $_.ToLowerInvariant() } | Where-Object { @($_.Group | Sort-Object -Unique -CaseSensitive).Count -gt 1 } |
                ForEach-Object { "$($f.Name) $($fn.Name): $(@($_.Group | Sort-Object -Unique -CaseSensitive) -join '/')" }
        }
    }
    Assert-Wt '코드 검사: 함수 안에 대소문자만 다른 변수 이름 없음' (-not $clash) ($clash -join '; ')

    # ---- 화면 밖 작업 (core\Work.psm1) ----
    $sum = Invoke-WtWork { param($a, $b) $a + $b } -ArgumentList 2, 3 -TimeoutMs 5000
    $arr = Invoke-WtWork { param($n) , @(1..$n) } -ArgumentList 3 -TimeoutMs 5000
    $ioError = $null
    try { [void](Invoke-WtWork { param($p) [System.IO.File]::ReadAllText($p) } -ArgumentList (Join-Path $test.Root '없음.txt') -TimeoutMs 5000) } catch { $ioError = $_.Exception }
    Assert-Wt '화면 밖 작업: 결과 · 배열 결과 · 작업 안의 예외를 그대로 올린다' ($sum -eq 5 -and $arr.Count -eq 3 -and $ioError -is [System.IO.FileNotFoundException]) "($sum · $($arr.Count) · $($ioError.GetType().Name))"
    $sta = Invoke-WtWork { [string][System.Threading.Thread]::CurrentThread.GetApartmentState() } -Sta -TimeoutMs 5000
    $listed = Invoke-WtWork { param($p) @(Get-ChildItem -LiteralPath $p).Count } -Session Default -ArgumentList $test.Root -TimeoutMs 5000
    Assert-Wt '화면 밖 작업: STA 스레드 · 기본 명령 세션' ($sta -eq 'STA' -and $listed -ge 1)
    # 응답 없는 공유 폴더 흉내(돌아오지 않는 .NET 대기): 화면 쪽은 정한 시간만 기다리고, 같은 곳은 다시 기다리지 않으며, 끝낼 때는 버린다
    $gate = New-WtTestGate
    try {
        $global:wtTestDone = $null
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $hung = Start-WtWork $wtTestHang -Key 'path:\\wt-test\hang' -TimeoutMs 300 -OnDone { param($w) $global:wtTestDone = $w.State }
        $startMs = $watch.ElapsedMilliseconds
        $entered = $gate.Entered.WaitOne(5000)
        $waited = Wait-WtWork $hung -Milliseconds 100
        Start-Sleep -Milliseconds 300
        Update-WtWork
        $watch.Restart(); $again = $null
        try { [void](Invoke-WtWork { 1 } -Key 'path:\\wt-test\hang' -TimeoutMs 5000) } catch { $again = $_.Exception }
        $againMs = $watch.ElapsedMilliseconds
        $watch.Restart(); $slow = $null
        try { [void](Invoke-WtWork $wtTestHang -Key 'path:\\wt-test\other' -TimeoutMs 200) } catch { $slow = $_.Exception }
        $slowMs = $watch.ElapsedMilliseconds
        $watch.Restart(); Stop-WtAllWork; $stopMs = $watch.ElapsedMilliseconds
        Assert-Wt "화면 밖 작업: 돌아오지 않는 작업도 시작 · 기다림 · 끝내기는 정한 시간만 쓴다 (시작 ${startMs} · 시간 초과 ${slowMs} · 다시 ${againMs} · 끝내기 ${stopMs}ms)" (
            $entered -and -not $waited -and $startMs -lt 500 -and $global:wtTestDone -eq 'timedout' -and (Test-WtWorkStuck 'path:\\wt-test\hang') -and
            $again -is [System.TimeoutException] -and $againMs -lt 100 -and $slow -is [System.TimeoutException] -and $slowMs -lt 1000 -and $stopMs -lt 100 -and
            (Get-WtWorkInfo).Running -eq 0)
    } finally { Remove-WtTestGate $gate }
    Assert-Wt '화면 밖 작업: 문을 열면 버린 작업도 끝나 치워진다' ((Get-WtWorkInfo).Abandoned -eq 0 -and -not (Test-WtWorkStuck 'path:\\wt-test\hang'))
    # 앱 전용 프로세스: 돌아오지 않는 작업이 남아도 Exit-WtOwnProcess로 끝난다. 부르지 않으면 PowerShell이 그 작업을 기다리느라 끝나지 않는다
    if (-not $NoDesktop) {
    $exitChild = Join-Path $test.Root 'work-exit.ps1'
    Set-Content -LiteralPath $exitChild -Encoding utf8 -Value @"
param([string]`$Mode)
. '$(Join-Path $PSScriptRoot 'TestKit.ps1')'
Import-WtTestCore
`$gate = New-WtTestGate
[void](Start-WtWork `$wtTestHang -OnDone { })
if (-not `$gate.Entered.WaitOne(10000)) { exit 3 }
Stop-WtAllWork
if (`$Mode -eq 'own') { Exit-WtOwnProcess -ScriptPath `$PSCommandPath -ExitCode 7 }
"@
    $exitRuns = @{}
    foreach ($mode in 'own', 'none') {
        $info = [System.Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        foreach ($a in '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $exitChild, '-Mode', $mode) { $info.ArgumentList.Add($a) }
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($info)
        $exitRuns[$mode] = @{ Process = $p; Watch = [System.Diagnostics.Stopwatch]::StartNew() }
    }
    $ownExited = $exitRuns.own.Process.WaitForExit(30000)
    $ownMs = $exitRuns.own.Watch.ElapsedMilliseconds
    # 대조: 같은 상황에서 Exit-WtOwnProcess를 부르지 않으면 (시작 시간까지 넉넉히 기다려도) 끝나지 않는다
    $noneExited = $exitRuns.none.Process.WaitForExit([int][Math]::Max(3000, $ownMs + 3000))
    foreach ($r in $exitRuns.Values) { if (-not $r.Process.HasExited) { $r.Process.Kill(); [void]$r.Process.WaitForExit(5000) } }
    Assert-Wt "앱 프로세스: 돌아오지 않는 작업이 남아도 Exit-WtOwnProcess로 끝난다 (${ownMs}ms) · 부르지 않으면 끝나지 않는다 (대조)" (
        $ownExited -and $exitRuns.own.Process.ExitCode -eq 7 -and -not $noneExited) "(끝남 $ownExited · 코드 $(if ($ownExited) { $exitRuns.own.Process.ExitCode }) · 대조 끝남 $noneExited)"
    foreach ($r in $exitRuns.Values) { $r.Process.Dispose() }
    } else { Write-Host 'SKIP 앱 프로세스 강제 종료 검사 (-NoDesktop)' }
    Assert-Wt '앱 프로세스: 이 검사 프로세스(-File Test-Core.ps1)는 앱 전용이 아니라고 본다' (-not (Test-WtOwnProcess (Join-Path $root 'Start-WorkTool.ps1')))

    # ---- 저장 ----
    Assert-Wt '데이터 폴더는 datapath.txt를 따른다' ((Get-WtDataRoot) -eq (Resolve-Path $test.Data).ProviderPath)

    Write-WtStore -Name 'sample' -Items @([ordered]@{ id = 'x1'; title = '한글 제목'; tags = @() })
    $one = Get-WtStoreItems -Name 'sample'
    Assert-Wt '항목 하나도 배열로 읽힌다' ($one -is [array] -and $one.Count -eq 1 -and $one[0].title -eq '한글 제목')
    Assert-Wt 'JSON에 한글이 그대로 저장된다' ((Get-Content (Get-WtStorePath 'sample') -Raw -Encoding utf8) -match '한글 제목')
    Write-WtStore -Name 'sample' -Items @()
    Assert-Wt '빈 목록 저장 · 읽기' ((Get-WtStoreItems -Name 'sample').Count -eq 0)
    Assert-Wt '덮어쓸 때 .bak을 남긴다' (Test-Path ((Get-WtStorePath 'sample') + '.bak'))
    Assert-Wt '없는 저장소는 빈 배열' ((Get-WtStoreItems -Name 'nothing').Count -eq 0)
    $missingStamp = Get-WtStoreStamp 'cache-sample'
    Write-WtStore cache-sample -Items @([ordered]@{ id = 'c1'; title = '캐시-A' })
    $cacheStamp = Get-WtStoreStamp 'cache-sample'
    Assert-Wt '저장 표식: 생성·같은 파일 반복 조회' ($missingStamp -cne $cacheStamp -and $cacheStamp -ceq (Get-WtStoreStamp 'cache-sample'))
    $cachePath = Get-WtStorePath 'cache-sample'
    $cacheTime = [IO.File]::GetLastWriteTimeUtc($cachePath)
    [IO.File]::WriteAllText($cachePath, [IO.File]::ReadAllText($cachePath).Replace('캐시-A','캐시-B'), [Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($cachePath, $cacheTime)
    Assert-Wt '저장 표식: 크기·시각이 같아도 본문 변경을 알아본다' ($cacheStamp -cne (Get-WtStoreStamp 'cache-sample') -and (Get-WtStoreItems 'cache-sample')[0].title -eq '캐시-B')
    $cacheLock = [IO.File]::Open($cachePath, 'Open', 'ReadWrite', 'None')
    try { $locked1 = Get-WtStoreStamp 'cache-sample'; $locked2 = Get-WtStoreStamp 'cache-sample' } finally { $cacheLock.Dispose() }
    Assert-Wt '저장 표식: 다른 프로그램이 파일을 잡고 있어도 멈추지 않고, 매번 다시 읽게 한다' ($locked1 -cne $locked2)

    Write-WtStore -Name 'mig' -Schema 1 -Items @([ordered]@{ id = 'm1' })
    $doc = Read-WtStore -Name 'mig' -Schema 2 -Migrate {
        param($d, $from)
        foreach ($i in $d.items) { $i | Add-Member -NotePropertyName extra -NotePropertyValue "from$from" -Force }
        $d
    }
    Assert-Wt '형식 변환: schema 1 → 2' ($doc.schema -eq 2 -and $doc.items[0].extra -eq 'from1')
    $migBackups = @(Get-ChildItem -LiteralPath $test.Data -Filter 'mig.json.schema1.*.bak' | ForEach-Object Name)
    Assert-Wt '형식 변환 전 원본을 날짜 붙은 백업으로 남긴다' ($migBackups.Count -eq 1 -and $migBackups[0] -match '^mig\.json\.schema1\.\d{8}-\d{6}\.bak$') ($migBackups -join ', ')
    $threw = $false
    try { [void](Read-WtStore -Name 'mig' -Schema 1) } catch { $threw = $true }
    Assert-Wt '더 새 형식 파일은 읽지 않고 멈춘다' $threw

    # 형식 규칙 (core\Records.psm1 · 저장 모듈): 가짜 저장소로 본다. 칸의 뜻은 탭이 정하고, 여기서는 모양만 본다
    $raw = { param($name, $json) [System.IO.File]::WriteAllText((Get-WtStorePath $name), $json, [System.Text.UTF8Encoding]::new($false)) }
    & $raw 'kind-text' '{ "schema": 1, "saved": "2026-10-25T21:54:29", "future": { "a": 1 }, "items": [ { "id": "k1", "at": "2026-10-25T21:54:29", "when": "2026-10-25T21:54:29+09:00", "n": 3 } ] }'
    $kt = Get-WtStoreItems 'kind-text'
    Assert-Wt '저장: 날짜처럼 보이는 글을 [datetime]으로 바꾸지 않는다 (-DateKind String)' ($kt[0].at -is [string] -and $kt[0].at -ceq '2026-10-25T21:54:29' -and $kt[0].when -ceq '2026-10-25T21:54:29+09:00')
    Write-WtStore 'kind-text' -Items @($kt)
    $ktDoc = [System.IO.File]::ReadAllText((Get-WtStorePath 'kind-text')) | ConvertFrom-Json -DateKind String
    Assert-Wt '저장: 맨 위의 모르는 키는 다시 써도 남고, saved는 시간대 붙은 시각' ($ktDoc.future.a -eq 1 -and $ktDoc.items[0].at -ceq '2026-10-25T21:54:29' -and
        $ktDoc.saved -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{2}:\d{2}$') $ktDoc.saved
    & $raw 'mig-top' '{ "schema": 1, "saved": "x", "importedFrom": "C:\\old", "future": [ 1, 2 ], "items": [ { "id": "t1" } ] }'
    $mt = Read-WtStore -Name 'mig-top' -Schema 2 -Migrate { param($doc, $from) foreach ($i in $doc.items) { $i | Add-Member -NotePropertyName v -NotePropertyValue $from -Force }; $doc }
    $mtDoc = [System.IO.File]::ReadAllText((Get-WtStorePath 'mig-top')) | ConvertFrom-Json -DateKind String
    Assert-Wt '형식 변환: 맨 위의 모르는 키를 잃지 않고, 저장한 모양 그대로 돌려준다' ($mtDoc.schema -eq 2 -and $mtDoc.importedFrom -eq 'C:\old' -and ($mtDoc.future -join ',') -eq '1,2' -and
        $mt.items[0].v -eq 1 -and $mt.importedFrom -eq 'C:\old')
    $failText = '{ "schema": 1, "items": [ { "id": "f1" } ] }'
    & $raw 'mig-fail' $failText
    $failError = $null
    try { [void](Read-WtStore -Name 'mig-fail' -Schema 2 -Migrate { param($doc, $from) throw '일부러 낸 변환 오류' }) } catch { $failError = $_.Exception.Message }
    Assert-Wt '형식 변환: 실패하면 원본 파일 · 백업을 건드리지 않고 이유를 알린다' ($failError -like '*원본 파일은 그대로*일부러 낸 변환 오류*' -and
        [System.IO.File]::ReadAllText((Get-WtStorePath 'mig-fail')) -ceq $failText -and -not @(Get-ChildItem -LiteralPath $test.Data -Filter 'mig-fail.json.*.bak').Count) $failError
    $badSchema = foreach ($j in '{ "items": [] }', '{ "schema": "2", "items": [] }', '{ "schema": 1.5, "items": [] }', '[ 1, 2 ]') {
        & $raw 'bad-schema' $j
        $e = $null; try { [void](Get-WtStoreItems 'bad-schema') } catch { $e = $_.Exception.Message }
        if ($e -notlike '*파일은 바꾸지 않았습니다*' -or ($j -ne '[ 1, 2 ]' -and $e -notlike '*형식 번호*') -or [System.IO.File]::ReadAllText((Get-WtStorePath 'bad-schema')) -cne $j) { $j }
    }
    Assert-Wt '저장: schema가 없거나 숫자가 아니거나 맨 위가 객체가 아니면 읽지 않고 파일도 그대로' (-not @($badSchema).Count) (@($badSchema) -join ' | ')
    $storageModule = Get-Module Storage
    $stem = Join-Path $test.Data 'backup-test.json.schema1.20261026-090000'
    & $raw 'backup-test' '{ "schema": 1, "items": [] }'
    $b1 = & $storageModule { param($p, $s) Invoke-WtDataIo Backup -Arguments $p, $s, $null } (Get-WtStorePath 'backup-test') $stem
    $b2 = & $storageModule { param($p, $s) Invoke-WtDataIo Backup -Arguments $p, $s, '보류된 내용' } (Get-WtStorePath 'backup-test') $stem
    Assert-Wt '저장: 변환 전 백업은 덮어쓰지 않고 -2를 붙이며, 아직 파일에 쓰이지 않은 내용은 그 글로 남긴다' ($b1 -eq "$stem.bak" -and $b2 -eq "$stem-2.bak" -and
        [System.IO.File]::ReadAllText($b1) -ceq '{ "schema": 1, "items": [] }' -and [System.IO.File]::ReadAllText($b2) -ceq '보류된 내용')

    # 저장소 읽기 결과 · 쓰기 거부 · 핸들 (2026-10-26 검토 반례: 빈 파일 · 목록 아닌 items · 거부 뒤 쓰기 · null 항목)
    [System.IO.File]::Copy((Join-Path $PSScriptRoot 'fixtures\store-empty.json'), (Get-WtStorePath 'empty-store'), $true)
    $emptyError = $null; try { [void](Read-WtStore 'empty-store') } catch { $emptyError = $_.Exception.Message }
    $h = Open-WtStore 'empty-store'
    $hError = $null; try { Save-WtStore $h @() } catch { $hError = $_.Exception.Message }
    $wError = $null; try { Write-WtStore 'empty-store' -Items @() } catch { $wError = $_.Exception.Message }
    Assert-Wt '저장: 빈 파일은 「없음」이 아니라 깨진 파일 (읽기 거부, 핸들 · 낮은 단계 저장 모두 거부, 파일 그대로)' ($emptyError -like '*비어 있습니다*' -and $h.State -eq 'error' -and
        $hError -and $wError -and [System.IO.File]::ReadAllBytes((Get-WtStorePath 'empty-store')).Length -eq 0) "$emptyError / $hError / $wError"
    & $raw 'newer-store' '{ "schema": 5, "items": [] }'
    $nError = $null; try { [void](Get-WtStoreItems 'newer-store' -Schema 2) } catch { $nError = $_.Exception.Message }
    $wError = $null; try { Write-WtStore 'newer-store' -Schema 2 -Items @() } catch { $wError = $_.Exception.Message }
    & $raw 'list-store' '{ "schema": 1, "items": "글" }'
    $lError = $null; try { [void](Read-WtStore 'list-store') } catch { $lError = $_.Exception.Message }
    Assert-Wt '저장: 더 새 schema · items가 목록이 아닌 파일은 읽지 않고, 그 뒤 낮은 단계 저장도 거부' ($nError -like '*더 새 버전*' -and $wError -like '*읽지 못한 파일*' -and $lError -like '*목록이 아닙니다*' -and
        [System.IO.File]::ReadAllText((Get-WtStorePath 'newer-store')) -ceq '{ "schema": 5, "items": [] }')
    & $raw 'null-store' '{ "schema": 1, "items": [ { "id": "a" }, null, [ "raw1", "raw2" ], [], { "id": "b" } ] }'
    $h = Open-WtStore 'null-store'
    $h2 = Save-WtStore $h @(Compress-WtDeletedItems @($h.Items))
    $nullDoc = [System.IO.File]::ReadAllText((Get-WtStorePath 'null-store')) | ConvertFrom-Json
    $oldError = $null; try { [void](Save-WtStore $h @()) } catch { $oldError = $_.Exception.Message }
    [void](Save-WtStore $h2 @($h2.Items[0]))
    Assert-Wt '저장: 핸들은 null · 목록 · 빈 목록 항목도 같은 자리에 그대로 읽고 쓰고, 저장하면 새 핸들을 돌려준다(쓴 핸들은 다시 못 씀)' (@($h.Items).Count -eq 5 -and @($nullDoc.items).Count -eq 5 -and
        $null -eq $nullDoc.items[1] -and ($nullDoc.items[2] -join ',') -eq 'raw1,raw2' -and $nullDoc.items[3] -is [array] -and @($nullDoc.items[3]).Count -eq 0 -and
        $oldError -like '*바뀌었습니다*' -and @(([System.IO.File]::ReadAllText((Get-WtStorePath 'null-store')) | ConvertFrom-Json).items).Count -eq 1 -and (Get-WtStoreItems 'null-store').Count -eq 1) $oldError
    $h1 = Open-WtStore 'null-store'
    & $raw 'null-store' '{ "schema": 1, "items": [ { "id": "밖에서 바꿈" } ] }'
    $h2 = Open-WtStore 'null-store'
    $sError = $null; try { [void](Save-WtStore $h1 @()) } catch { $sError = $_.Exception.Message }
    [void](Save-WtStore $h2 @($h2.Items))
    $hm = Open-WtStore 'never-store'
    $hmNew = Save-WtStore $hm @([pscustomobject]@{ id = 'n1' })
    Assert-Wt '저장: 핸들로 읽은 뒤 다시 읽은 저장소에는 옛 핸들로 쓰지 않고(새 핸들은 됨), 없는 저장소는 핸들로 새로 만든다' ($sError -like '*바뀌었습니다*' -and
        (Get-WtStoreItems 'null-store')[0].id -eq '밖에서 바꿈' -and $hm.State -eq 'missing' -and $hmNew.State -eq 'ok' -and (Get-WtStoreItems 'never-store')[0].id -eq 'n1') $sError
    # 같은 핸들을 둘이 나눠 가져도(화면 · 홈 카드가 캐시를 같이 봄) 핸들은 열 때의 버전을 자기 것으로 든다: 먼저 저장한 쪽만 쓰이고 뒤의 옛 목록은 거부
    $shared = Open-WtStore 'never-store'
    [void](Save-WtStore $shared @([pscustomobject]@{ id = 'A' }))
    $lateError = $null; try { [void](Save-WtStore $shared @([pscustomobject]@{ id = 'B' })) } catch { $lateError = $_.Exception.Message }
    Assert-Wt '저장: 같은 핸들로 두 번째 저장(나눠 가진 옛 목록)은 거부하고 앞 저장이 남는다 (낙관적 잠금)' ($lateError -like '*바뀌었습니다*' -and (Get-WtStoreItems 'never-store')[0].id -eq 'A') $lateError
    # 거부는 끈질기다: schema 3을 거부한 뒤 디스크 때문에 못 읽어도(잠긴 파일) 낮은 schema 저장은 여전히 거부
    & $raw 'sticky-store' '{ "schema": 3, "items": [] }'
    try { [void](Get-WtStoreItems 'sticky-store' -Schema 2) } catch { }
    $lockFile = [System.IO.File]::Open((Get-WtStorePath 'sticky-store'), 'Open', 'ReadWrite', 'None')
    $lockedError = $null
    try { try { [void](Get-WtStoreItems 'sticky-store' -Schema 2) } catch { $lockedError = $_.Exception.Message } } finally { $lockFile.Dispose() }
    $stickyError = $null; try { Write-WtStore 'sticky-store' -Schema 2 -Items @() } catch { $stickyError = $_.Exception.Message }
    Assert-Wt '저장: 거부한 파일은 그 뒤 못 읽어도(잠김) 거부로 남아 낮은 schema로 쓰지 않는다 (다시 읽어 정상일 때만 풀림)' ($lockedError -and $stickyError -like '*읽지 못한 파일*' -and
        [System.IO.File]::ReadAllText((Get-WtStorePath 'sticky-store')) -ceq '{ "schema": 3, "items": [] }') "$lockedError / $stickyError"
    # 파일 교체 중 잠시 없어져도 정상 schema를 확인한 것이 아니다. 정상 파일을 읽은 뒤에만 저장을 허용한다
    $stickyPath = Get-WtStorePath 'sticky-store'
    [System.IO.File]::Move($stickyPath, "$stickyPath.hold")
    try {
        $missingHandle = Open-WtStore 'sticky-store' -Schema 2
        $missingError = $null; try { Write-WtStore 'sticky-store' -Schema 2 -Items @() } catch { $missingError = $_.Exception.Message }
        Assert-Wt '저장: 거부 뒤 파일이 없어져도 거부 유지 (정상 schema를 확인하기 전에는 새 파일도 만들지 않음)' (
            $missingHandle.State -eq 'error' -and $missingError -like '*읽지 못한 파일*' -and -not [System.IO.File]::Exists($stickyPath)) $missingError
    } finally { [System.IO.File]::Move("$stickyPath.hold", $stickyPath) }
    & $raw 'sticky-store' '{ "schema": 2, "items": [ { "id": "정상" } ] }'
    $normalHandle = Open-WtStore 'sticky-store' -Schema 2
    [void](Save-WtStore $normalHandle @($normalHandle.Items))
    Assert-Wt '저장: 거부는 정상 schema를 다시 읽으면 풀리고 그 핸들로 저장할 수 있다' (
        $normalHandle.State -eq 'ok' -and (Get-WtStoreItems 'sticky-store' -Schema 2)[0].id -eq '정상')
    $itemsBad = foreach ($f in 'store-items-null.json', 'store-no-items.json') {
        [System.IO.File]::Copy((Join-Path $PSScriptRoot "fixtures\$f"), (Get-WtStorePath 'items-store'), $true)
        $h = Open-WtStore 'items-store'
        $e = $null; try { [void](Save-WtStore $h @()) } catch { $e = $_.Exception.Message }
        if ($h.State -ne 'error' -or $h.Error -notlike '*items가 없거나*' -or -not $e) { "$f=$($h.State)" }
    }
    Assert-Wt '저장: items가 null이거나 없으면 빈 목록이 아니라 깨진 파일 (저장 거부)' (-not @($itemsBad).Count) (@($itemsBad) -join ', ')

    Assert-Wt '형식: 앱이 찍는 시각은 시간대 포함 · 날짜 · 시각 글은 정한 모양만' (
        (Get-WtStamp ([datetime]'2026-10-25 21:54:29')) -match '^2026-10-25T21:54:29[+-]\d{2}:\d{2}$' -and (ConvertFrom-WtStamp '2026-10-25T21:54:29+09:00').Offset.TotalHours -eq 9 -and
        $null -eq (ConvertFrom-WtStamp '2026-10-25 21:54:29') -and (ConvertFrom-WtDateText '2026-02-28') -eq [datetime]'2026-02-28' -and $null -eq (ConvertFrom-WtDateText '2026-02-30') -and
        $null -eq (ConvertFrom-WtDateText '2026-1-5') -and (ConvertFrom-WtTimeText '09:30') -eq [timespan]'09:30' -and $null -eq (ConvertFrom-WtTimeText '9:30') -and $null -eq (ConvertFrom-WtTimeText '24:00'))
    $looseDates = @('2026-10-01', '2026-10-1', '2026/10/1', '2026.10.01', '2026. 10. 1.', '20261001', '10/1/2026', ' 2026-10-01 ') | ForEach-Object { ConvertFrom-WtLegacyDate $_ }
    $looseTimes = @('9:30', '09:30', '09:30:00', '오전 9:30', '오후 2:30', '2:30 PM', '오후 2:30:00') | ForEach-Object { ConvertFrom-WtLegacyTime $_ }
    Assert-Wt '형식: 예전 CSV 값은 Excel이 바꾼 모양도 읽고, 못 읽으면 $null' (
        (@($looseDates | Sort-Object -Unique) -join ',') -eq '2026-10-01' -and @($looseDates).Count -eq 8 -and (($looseTimes | Select-Object -Unique) -join ',') -eq '09:30,14:30' -and
        $null -eq (ConvertFrom-WtLegacyDate '내일') -and $null -eq (ConvertFrom-WtLegacyDate '2026-13-01') -and $null -eq (ConvertFrom-WtLegacyTime '25:00') -and
        (ConvertFrom-WtLegacyStamp '2026-10-25 21:54:29') -match '^2026-10-25T21:54:29[+-]\d{2}:\d{2}$' -and (ConvertFrom-WtLegacyStamp '2026-10-25T21:54:29+09:00') -ceq '2026-10-25T21:54:29+09:00' -and
        $null -eq (ConvertFrom-WtLegacyStamp '모름')) "$($looseDates -join ',') / $($looseTimes -join ',')"
    $thread = [System.Threading.Thread]::CurrentThread; $oldCulture = $thread.CurrentCulture
    try {
        $thread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('th-TH')
        $thai = @((ConvertTo-WtDateText ([datetime]'2026-10-25')), (Get-WtStamp ([datetime]'2026-10-25 09:00')).Substring(0, 19), (ConvertFrom-WtLegacyDate '2026/10/25'))
    } finally { $thread.CurrentCulture = $oldCulture }
    Assert-Wt '형식: 불기 · 회교력 문화권에서도 그레고리력 글 (th-TH)' (($thai -join '|') -eq '2026-10-25|2026-10-25T09:00:00|2026-10-25') ($thai -join '|')
    $fieldObj = [pscustomobject]@{ a = 1 }
    Set-WtField $fieldObj 'b' @('x'); Set-WtField $fieldObj 'a' 2
    $one = Get-WtField ([pscustomobject]@{ l = @('x') }) 'l'; $none = Get-WtField ([pscustomobject]@{ l = @() }) 'l'
    Assert-Wt '형식: 칸 읽기 · 넣기 (없는 count는 PowerShell의 Count(1)가 아니라 $null, 목록은 하나짜리 · 빈 목록도 목록)' ($null -eq (Get-WtField $fieldObj 'count') -and $fieldObj.count -eq 1 -and $fieldObj.a -eq 2 -and
        $fieldObj.b -is [array] -and (Get-WtField ([ordered]@{ count = 3 }) 'count') -eq 3 -and @(Copy-WtItem @($fieldObj, $fieldObj)).Count -eq 2 -and (Copy-WtItem $fieldObj).a -eq 2 -and
        $one -is [array] -and $one.Count -eq 1 -and $none -is [array] -and $none.Count -eq 0 -and $null -eq (Get-WtField 'glue' 'Length'))
    $nums = '{ "a": 2147483648, "b": 99999999999999999999, "c": 10.5, "d": 1e300, "e": "10", "f": true, "g": -1, "h": 5, "i": 1.0 }' | ConvertFrom-Json
    $w = @('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i') | ForEach-Object { $v = ConvertFrom-WtWhole $nums.$_ 0 2147483647; if ($null -eq $v) { 'x' } else { "$v" } }
    $n2 = @('c', 'd', 'e', 'g', 'h') | ForEach-Object { $v = ConvertFrom-WtNumber $nums.$_ 0 366; if ($null -eq $v) { 'x' } else { "$v" } }
    Assert-Wt '형식: 숫자 칸은 정한 범위의 정수만 (Int32 · Int64 · BigInteger를 넘는 수 · 소수 · 글 · 참거짓은 $null, 예외 없음)' (($w -join ',') -eq 'x,x,x,x,x,x,x,5,1' -and ($n2 -join ',') -eq '10.5,x,x,x,5' -and
        $null -eq (ConvertFrom-WtWhole 2147483648 0 2147483647) -and (ConvertFrom-WtWhole 2147483648 0 9999999999) -eq 2147483648) "$($w -join ',') / $($n2 -join ',')"
    $tiny = '{ "a": 1e-30, "b": -1e-30, "c": 1.0000000000000002, "d": 0.9999999999999999, "e": 10.0 }' | ConvertFrom-Json
    $tw = @('a', 'b', 'c', 'd', 'e') | ForEach-Object { $v = ConvertFrom-WtWhole $tiny.$_ -5 100; if ($null -eq $v) { 'x' } else { "$v" } }
    Assert-Wt '형식: 정수 판정은 Decimal로 바꾸기 전에 (1e-30 · 1.0000000000000002 · 0.9999999999999999는 정수가 아님, 10.0은 정수)' (($tw -join ',') -eq 'x,x,x,x,10' -and
        $null -eq (ConvertFrom-WtWhole ([decimal]'1.5') 0 9) -and (ConvertFrom-WtWhole ([decimal]'3') 0 9) -eq 3) ($tw -join ',')
    Assert-Wt '형식: 정수의 범위는 호출자가 정한다 (큰 Double 정수도 정확히 변환, Int64 밖이면 예외 없이 거부)' (
        (ConvertFrom-WtWhole ([double]9007199254740992) 0 ([long]::MaxValue)) -eq 9007199254740992 -and
        $null -eq (ConvertFrom-WtWhole ([double]::MaxValue) 0 ([long]::MaxValue)) -and
        $null -eq (ConvertFrom-WtWhole ([double][long]::MaxValue) 0 ([long]::MaxValue)))
    Assert-Wt '형식: 날짜는 1900 ~ 2199년만' ((ConvertFrom-WtDateText '1900-01-01') -eq [datetime]'1900-01-01' -and (ConvertFrom-WtDateText '2199-12-31') -eq [datetime]'2199-12-31' -and
        $null -eq (ConvertFrom-WtDateText '1899-12-31') -and $null -eq (ConvertFrom-WtDateText '2200-01-01'))
    $now = [DateTimeOffset]::new(2026, 10, 26, 9, 0, 0, [timespan]::FromHours(9))
    $del = @(Compress-WtDeletedItems @(
            [pscustomobject]@{ id = 'old'; title = '지운 지 오래'; deleted = '2026-07-01T09:00:00+09:00' },
            [pscustomobject]@{ id = 'new'; title = '최근에 지움'; deleted = '2026-10-01T09:00:00+09:00' },
            [pscustomobject]@{ id = 'bad'; title = '시각 모름'; deleted = '언젠가' },
            [pscustomobject]@{ id = 'live'; title = '살아 있음'; deleted = $null },
            [pscustomobject]@{ id = 'no'; title = 'false'; deleted = $false }) -Days 90 -Now $now)
    Assert-Wt '형식: 지운 지 90일 지난 기록은 { id, deleted }만 남기고, 나머지는 그대로' ((Get-WtTestJsonCore $del[0]) -ceq '{"id":"old","deleted":"2026-07-01T09:00:00+09:00"}' -and
        $del[1].title -eq '최근에 지움' -and $del[2].title -eq '시각 모름' -and -not (Test-WtDeleted $del[3]) -and -not (Test-WtDeleted $del[4]) -and (Test-WtDeleted $del[2]) -and $del.Count -eq 5)
    # 예전 데이터 합치기: id는 대소문자를 가린다. 「이 앱에서 고쳤는지」는 rev(사람이 고친 횟수)와 origin.rev로, 바뀐 예전 칸이 정하는 경로만 옮긴다
    $row = { param($id, $t, $n) [pscustomobject][ordered]@{ Id = $id; T = $t; N = $n } }
    $item = { param($id, $title, $note, $rev, $orow) [pscustomobject][ordered]@{ id = $id; title = $title; note = $note; deep = [pscustomobject]@{ keep = '앱 칸'; n = $note }; rev = $rev; updated = 't0'
        origin = [pscustomobject][ordered]@{ from = 'winforms-csv'; at = 't0'; rev = 0; row = $orow; line = 7 } } }
    $mOld = @(
        (& $item 'same' 'A' 'a' 0 (& $row 'same' 'A' 'a')),
        (& $item 'theirs' 'B' 'b' 0 (& $row 'theirs' 'B' 'b')),
        (& $item 'both' '고침' 'c' 1 (& $row 'both' 'C' 'c')),
        [pscustomobject]@{ id = 'gone'; deleted = 't9' },
        [pscustomobject]@{ id = 'mine'; title = '이 앱에서 만듦'; rev = 0; origin = $null },
        (& $item 'left' 'L' 'l' 0 (& $row 'left' 'L' 'l')),
        $null,
        'garbage')
    $mOld[1] | Add-Member -NotePropertyName extra -NotePropertyValue '남길 칸'
    $mNew = @(foreach ($p in @(@('same', 'A', 'a'), @('theirs', 'B', 'b2'), @('both', 'C2', 'c'), @('gone', 'G', 'g'), @('mine', 'M', 'm'), @('add', 'N', 'n'), @('ADD', '대문자', 'n'), @('add', '겹친 줄', 'x'), @('add', '겹친 줄', 'x'))) {
            [pscustomobject][ordered]@{ id = $p[0]; title = $p[1]; note = $p[2]; deep = [pscustomobject]@{ n = $p[2] }; rev = 0; updated = 't1'
                origin = [pscustomobject][ordered]@{ from = 'winforms-csv'; at = 't1'; rev = 0; row = (& $row $p[0] $p[1] $p[2]) } }
        })
    $owned = @{ T = @('title'); N = @('note', 'deep.n') }
    $mr = Merge-WtLegacyItems -Items $mOld -Incoming $mNew -Owned $owned
    $get = { param($id) @($mr.Items | Where-Object { (Test-WtRecordObject $_) -and $_.id -ceq $id })[0] }
    $theirs = & $get 'theirs'
    Assert-Wt '형식: 예전 데이터 합치기 (그대로 · 예전 쪽만 바뀜 · 양쪽 다 고침 · 지운 것 · 이 앱에서 만든 것 · 새 줄 · 대소문자 · 겹친 줄 · 없어진 줄 · null · 모양이 틀린 항목)' (
        $mr.Unchanged -eq 1 -and $mr.Updated -eq 1 -and $mr.Added -eq 3 -and $mr.KeptDeleted -eq 1 -and ($mr.Conflicts -join ',') -eq 'both,mine' -and ($mr.Missing -join ',') -eq 'left' -and
        $theirs.note -eq 'b2' -and $theirs.deep.n -eq 'b2' -and $theirs.deep.keep -eq '앱 칸' -and $theirs.extra -eq '남길 칸' -and $theirs.title -eq 'B' -and $theirs.origin.line -eq 7 -and
        $theirs.origin.row.N -eq 'b2' -and $theirs.origin.at -eq 't1' -and $theirs.updated -eq 't1' -and $theirs.rev -eq 0 -and
        (& $get 'both').title -eq '고침' -and $null -eq (& $get 'gone').title -and (& $get 'add').title -eq 'N' -and (& $get 'ADD').title -eq '대문자' -and
        @($mr.Duplicates).Count -eq 1 -and (& $get $mr.Duplicates[0]).origin.dupOf -ceq 'add' -and (Get-WtRecordProblem (& $get $mr.Duplicates[0])) -like "*원래 id 'add'*" -and
        $mr.Items.Count -eq 11 -and $null -eq $mr.Items[6] -and $mr.Items[7] -ceq 'garbage' -and
        (Get-WtRowKey ([pscustomobject]@{ a = 1; b = 2 })) -ceq (Get-WtRowKey ([ordered]@{ b = 2; a = 1 }))) "(그대로 $($mr.Unchanged) · 바꿈 $($mr.Updated) · 더함 $($mr.Added) · 충돌 $($mr.Conflicts -join ',') · 항목 $($mr.Items.Count))"
    $threw = $null; try { [void](Merge-WtLegacyItems -Items @() -Incoming @()) } catch { $threw = $_.Exception.Message }
    Assert-Wt '형식: 합치기는 예전 칸 → 항목 칸 지도(-Owned) 없이 하지 않는다' ($threw -like '*-Owned*')
    $edit = [pscustomobject]@{ id = 'e'; updated = 'x' }
    Set-WtItemEdited $edit '2026-10-26T09:00:00+09:00'; Set-WtItemEdited $edit '2026-10-26T09:00:00+09:00'
    Assert-Wt '형식: 사람이 고치면 rev가 1씩 오른다 (같은 초여도), 이상한 rev는 -1(고쳤음으로 봄)' ($edit.rev -eq 2 -and $edit.updated -eq '2026-10-26T09:00:00+09:00' -and
        (Get-WtItemRevision ([pscustomobject]@{ rev = 'x' })) -eq -1 -and (Get-WtItemRevision ([pscustomobject]@{ id = 'n' })) -eq 0)
    $pt = [pscustomobject]@{ a = [pscustomobject]@{ x = 1; keep = 'k' }; r = $null; l = @(1) }
    Copy-WtPathValue $pt ([pscustomobject]@{ a = [pscustomobject]@{ x = 2 }; r = [pscustomobject]@{ f = 'w' }; l = @(5) }) 'a.x'
    Copy-WtPathValue $pt ([pscustomobject]@{ r = [pscustomobject]@{ f = 'w' } }) 'r.f'
    Copy-WtPathValue $pt ([pscustomobject]@{ l = @(5) }) 'l'
    $pt2 = [pscustomobject]@{ r = [pscustomobject]@{ f = 'w'; extra = 1 } }
    Copy-WtPathValue $pt2 ([pscustomobject]@{ r = $null }) 'r.f'
    Assert-Wt '형식: 칸 경로 옮기기 (그 칸만 · 한쪽이 null이면 앞부분 통째로 · 목록은 목록으로)' ($pt.a.x -eq 2 -and $pt.a.keep -eq 'k' -and $pt.r.f -eq 'w' -and $pt.l -is [array] -and
        $pt.l.Count -eq 1 -and $pt.l[0] -eq 5 -and $null -eq $pt2.r -and ((Get-WtChangedColumns ([pscustomobject]@{ a = 1; b = 2 }) ([pscustomobject]@{ a = 1; b = 3; c = 4 })) -join ',') -eq 'b,c')
    # 목록 원소 경로: 첫 원소의 그 칸만 옮기고 다른 원소 · 다른 칸은 그대로. 원소가 없으면 끼워 넣고, 원본에서 없어지면 그 칸만 null
    $al1 = [pscustomobject]@{ alarms = @([pscustomobject]@{ before = 10; sound = 'keep' }, [pscustomobject]@{ channel = 'future' }) }
    Copy-WtPathValue $al1 ([pscustomobject]@{ alarms = @([pscustomobject]@{ before = 20 }) }) 'alarms[0].before'
    $al2 = [pscustomobject]@{ alarms = @() }
    Copy-WtPathValue $al2 ([pscustomobject]@{ alarms = @([pscustomobject]@{ before = 5 }) }) 'alarms[0].before'
    $al3 = [pscustomobject]@{ alarms = @([pscustomobject]@{ before = 10; sound = 'keep' }) }
    Copy-WtPathValue $al3 ([pscustomobject]@{ alarms = @() }) 'alarms[0].before'
    $al4 = [pscustomobject]@{ alarms = @() }
    Copy-WtPathValue $al4 ([pscustomobject]@{ alarms = @() }) 'alarms[0].before'
    Assert-Wt '형식: 목록 원소 경로(alarms[0].before)는 그 원소의 그 칸만 (다른 원소 · 확장 칸 보존, 없으면 끼움, 원본에서 없어지면 그 칸만 null)' (
        $al1.alarms.Count -eq 2 -and $al1.alarms[0].before -eq 20 -and $al1.alarms[0].sound -eq 'keep' -and $al1.alarms[1].channel -eq 'future' -and
        @($al2.alarms).Count -eq 1 -and $al2.alarms[0].before -eq 5 -and @($al3.alarms).Count -eq 1 -and $null -eq $al3.alarms[0].before -and $al3.alarms[0].sound -eq 'keep' -and
        @($al4.alarms).Count -eq 0)
    $packed = @(Compress-WtDeletedItems @([pscustomobject]@{ id = 'a' }, @('r1', 'r2'), @(), $null, 'g'))
    $same = @(foreach ($p in @(@('s', 'X'), @('s', 'X'), @('s', 'Y'))) { [pscustomobject]@{ id = $p[0]; title = $p[1]; rev = 0; origin = [pscustomobject]@{ from = 'winforms-csv'; at = 't'; rev = 0; row = [pscustomobject]@{ Id = $p[0]; T = $p[1] } } } })
    $sr = Merge-WtLegacyItems -Items @() -Incoming $same -Owned @{ T = @('title') }
    Assert-Wt '형식: 정리는 목록 · 빈 목록 · null 항목을 같은 자리에 보존한다' (
        $packed.Count -eq 5 -and ($packed[1] -join ',') -eq 'r1,r2' -and $packed[2] -is [array] -and $packed[2].Count -eq 0 -and $null -eq $packed[3])
    Assert-Wt '형식: 합치기는 id와 내용까지 같은 줄을 하나로 (내용이 다를 때만 dup)' (
        $sr.Added -eq 2 -and @($sr.Duplicates).Count -eq 1 -and $sr.Items.Count -eq 2)
    $badRevs = @(foreach ($pair in @(@(-1, -2), @(-1, 0), @(0, -1), @($null, 0), @(0, $null), @('0', 0), @(0, 1.5))) {
        $bad = @([pscustomobject]@{ id = 'r'; title = '이 앱'; rev = $pair[0]; origin = [pscustomobject]@{ from = 'winforms-csv'; at = 't'; rev = $pair[1]; row = [pscustomobject]@{ Id = 'r'; T = '옛' } } })
        $br = Merge-WtLegacyItems -Items $bad -Incoming @([pscustomobject]@{ id = 'r'; title = '새'; rev = 0; origin = [pscustomobject]@{ from = 'winforms-csv'; at = 't2'; rev = 0; row = [pscustomobject]@{ Id = 'r'; T = '새' } } }) -Owned @{ T = @('title') }
        if ($br.Items[0].title -ne '이 앱' -or ($br.Conflicts -join ',') -ne 'r') { "$($pair -join ',')" }
    })
    Assert-Wt '형식: rev · origin.rev 중 하나라도 잘못되면 고쳤음으로 보고 보존 (둘 다 잘못됨 · null · 글 · 소수 포함)' (-not $badRevs.Count) ($badRevs -join '; ')
    # 예전 CSV 인코딩: WinForms는 BOM 붙은 UTF-8, Excel로 다시 저장하면 BOM 없는 CP949가 될 수 있다. 어느 쪽이든 한글이 그대로 읽힌다
    $csvText = "`"Id`",`"Title`"`r`n`"e1`",`"한글 제목, 쉼표`"`r`n"
    $encDir = Join-Path $test.Root 'legacy-enc'
    [void][System.IO.Directory]::CreateDirectory($encDir)
    $encResults = foreach ($enc in @(@('bom', [System.Text.UTF8Encoding]::new($true)), @('utf8', [System.Text.UTF8Encoding]::new($false)), @('cp949', [System.Text.Encoding]::GetEncoding(949)))) {
        [System.IO.File]::WriteAllBytes((Join-Path $encDir "$($enc[0]).csv"), [byte[]]@($enc[1].GetPreamble()) + $enc[1].GetBytes($csvText))
        $rc = Read-WtLegacyCsv $encDir $enc[0]
        "$($enc[0])=$($rc.Encoding):$($rc.Rows[0].Title):$($rc.Sha256.Length)"
    }
    Assert-Wt '예전 CSV: BOM UTF-8 · BOM 없는 UTF-8 · CP949 모두 한글이 그대로 읽힌다' (($encResults -join '|') -eq 'bom=utf-8:한글 제목, 쉼표:64|utf8=utf-8:한글 제목, 쉼표:64|cp949=cp949:한글 제목, 쉼표:64') ($encResults -join '|')
    Assert-Wt '예전 CSV: 없으면 $null, 빈 파일이면 빈 줄 목록' ($null -eq (Read-WtLegacyCsv $encDir 'none') -and $(
            [System.IO.File]::WriteAllText((Join-Path $encDir 'empty.csv'), ''); $e = Read-WtLegacyCsv $encDir 'empty'; $e.Rows.Count -eq 0 -and (Import-WtLegacyCsv $encDir 'empty').Count -eq 0))

    # ---- 휴무일 (core\Calendar.psm1, 고정 시험 자료 tests\fixtures\holidays*.json: 더하기만 하고 고치지 않는다) ----
    [System.IO.File]::Copy((Join-Path $PSScriptRoot 'fixtures\holidays.json'), (Get-WtStorePath 'holidays'), $true)
    $hd = Get-WtHolidayData
    $hStates = (@($hd.Entries) | ForEach-Object { "$($_.Id.Substring(0, 2))=$($_.State)" }) -join ','
    $hSet = Get-WtHolidayDates   # 날짜 모음(HashSet) 하나를 돌려준다. 변수에 받은 뒤 펼친다
    $hDates = @($hSet) | Sort-Object
    $hOct = Get-WtHolidayDates ([datetime]'2026-10-05') ([datetime]'2026-10-31')
    Assert-Wt '휴무일: 공휴일 · 개인 · 회사 휴무를 읽고, 지운 것 · 날짜가 깨진 것은 계산에서 뺀다' (-not $hd.Error -and $hStates -eq 'h2=ok,h2=ok,p1=ok,c1=ok,x1=deleted,b1=broken' -and
        ($hDates -join ',') -eq '2026-10-03,2026-10-08,2026-10-09,2026-11-20' -and ((@($hOct) | Sort-Object) -join ',') -eq '2026-10-08,2026-10-09') "$hStates / $($hDates -join ',')"
    [System.IO.File]::Copy((Join-Path $PSScriptRoot 'fixtures\holidays-future.json'), (Get-WtStorePath 'holidays'), $true)
    $hBefore = [System.IO.File]::ReadAllText((Get-WtStorePath 'holidays')) | ConvertFrom-Json -Depth 20 -DateKind String
    $hd = Get-WtHolidayData
    $hSet = Get-WtHolidayDates
    Assert-Wt '휴무일 새 버전: 모르는 종류는 읽기 전용(계산에서 뺌)' (((@($hd.Entries) | ForEach-Object State) -join ',') -eq 'ok,readonly' -and (@($hSet) -join ',') -eq '2026-12-25')
    $hItems = @($hd.Items); $hItems[0].name = '고친 이름'; Set-WtItemEdited $hItems[0]
    Save-WtHolidayItems $hd.Store $hItems
    $hAfter = [System.IO.File]::ReadAllText((Get-WtStorePath 'holidays')) | ConvertFrom-Json -Depth 20 -DateKind String
    Assert-Wt '휴무일 새 버전: 고쳐 저장해도 모르는 맨 위 키 · 칸 · 항목이 그대로' ((Get-WtTestJsonCore $hAfter.region) -ceq (Get-WtTestJsonCore $hBefore.region) -and $hAfter.items[0].name -eq '고친 이름' -and
        $hAfter.items[0].observed -eq $true -and $hAfter.items[0].origin.line -eq 12 -and (Get-WtTestJsonCore $hAfter.items[1]) -ceq (Get-WtTestJsonCore $hBefore.items[1]))
    $hd = Get-WtHolidayData; $otherHoliday = Get-WtHolidayData
    $holidayA = @(Copy-WtItem @($hd.Items)); $holidayA[0].name = '먼저 고친 이름'
    $holidayB = @(Copy-WtItem @($otherHoliday.Items)); $holidayB[0].note = '뒤의 옛 목록'
    Save-WtHolidayItems $hd.Store $holidayA
    $holidayError = $null; try { Save-WtHolidayItems $otherHoliday.Store $holidayB } catch { $holidayError = $_.Exception.Message }
    Assert-Wt '휴무일 저장 거부: 공유 캐시의 옛 핸들은 먼저 저장한 내용을 덮지 않는다' (
        [object]::ReferenceEquals($hd.Store, $otherHoliday.Store) -and $holidayError -like '*바뀌었습니다*' -and
        ([System.IO.File]::ReadAllText((Get-WtStorePath 'holidays')) | ConvertFrom-Json).items[0].name -eq '먼저 고친 이름') $holidayError
    & $raw 'holidays' '{ "schema": 2, "items": [] }'
    $hd = Get-WtHolidayData
    $hSet = Get-WtHolidayDates
    Assert-Wt '휴무일: 못 읽으면 예외 없이 오류만 알리고 계산에는 휴무일이 없다' ($hd.Error -like '*더 새 버전*' -and $hSet.Count -eq 0)

    # ---- 2a 휴무일 편집 · 연간 붙여 넣기 ----
    & $raw 'holidays' '{"schema":1,"future":"남길 맨 위 칸","items":[{"id":"pub","date":"2026-11-03","kind":"public","name":"옛 이름","note":"남길 메모","extra":7},{"id":"gone","date":"2026-11-04","kind":"public","name":"빠질 날"},{"id":"co","date":"2026-11-03","kind":"company","name":"회사 휴무"},{"id":"pe","date":"2026-11-03","kind":"personal","name":"개인 휴무"},{"id":"future","date":"2026-11-03","kind":"future","name":"새 값"},null]}'
    $hd = Get-WtHolidayData
    $pasteText = "2026-11-03 새 공휴일`r`n2026-11-03 새 공휴일`r`n2026-12-25 공휴일"
    $parsed = ConvertFrom-WtHolidayPaste $pasteText 2026
    $badPaste = ConvertFrom-WtHolidayPaste "2026-11-03 A`n2026-11-03 B`n2026-02-29 없음`n2027-01-01 다른 해`n틀린 줄" 2026
    Assert-Wt '공휴일 해석: 같은 날짜 · 이름은 하나, 틀린 줄은 줄 번호 · 원문 · 이유' ($parsed.Success -and $parsed.Items.Count -eq 2 -and
        -not $badPaste.Success -and ($badPaste.Errors.Line -join ',') -ceq '2,3,4,5' -and @($badPaste.Errors | Where-Object { -not $_.Reason -or -not $_.Text }).Count -eq 0)
    $beforePaste = [IO.File]::ReadAllText((Get-WtStorePath 'holidays'))
    $refusedPaste = Import-WtHolidayPaste $hd.Store '2026-02-29 없음' 2026
    $emptyPaste = Import-WtHolidayPaste $hd.Store '' 2026
    Assert-Wt '공휴일 붙여 넣기: 잘못된 줄 · 빈 목록은 저장하지 않음' (-not $refusedPaste.Success -and -not $emptyPaste.Success -and
        [IO.File]::ReadAllText((Get-WtStorePath 'holidays')) -ceq $beforePaste)
    $hr = Import-WtHolidayPaste $hd.Store $pasteText 2026 -At '2026-11-01T09:00:00+09:00'
    $hdoc = [IO.File]::ReadAllText((Get-WtStorePath 'holidays')) | ConvertFrom-Json -Depth 20 -DateKind String
    $pub = @($hr.Store.Items | Where-Object id -ceq 'pub')[0]
    Assert-Wt '공휴일 붙여 넣기: 그해 public만 맞춤 · 기존 id/모르는 칸/메모 보존 · 빠진 날은 지운 표시' ($hr.Success -and $hdoc.future -ceq '남길 맨 위 칸' -and
        $pub.name -ceq '새 공휴일' -and $pub.extra -eq 7 -and $pub.note -ceq '남길 메모' -and (Test-WtDeleted @($hr.Store.Items | Where-Object id -ceq 'gone')[0]) -and
        @($hr.Store.Items | Where-Object { $_.kind -in 'company', 'personal', 'future' -and -not (Test-WtDeleted $_) }).Count -eq 3 -and $null -eq $hr.Store.Items[5]) $hr.Reason
    $hr = Set-WtHolidayDate $hr.Store '2026-11-03' 'public' -Enabled $false -At '2026-11-01T09:00:00+09:00'
    Assert-Wt '휴무일 해제: 같은 날의 다른 종류는 그대로, 계산에는 하루' ($hr.Success -and (Get-WtHolidayDates).Contains('2026-11-03')) $hr.Reason
    $hd = Get-WtHolidayData
    $hr = Set-WtHolidayDate $hd.Store '2026-11-03' 'company' -Enabled $false -At '2026-11-01T09:00:00+09:00'
    $hr = Set-WtHolidayDate $hr.Store '2026-11-03' 'personal' -Enabled $false -At '2026-11-01T09:00:00+09:00'
    Assert-Wt '휴무일 해제: 아는 종류를 모두 해제하면 모르는 종류는 날짜 계산에서 제외' ($hr.Success -and -not (Get-WtHolidayDates).Contains('2026-11-03')) $hr.Reason
    $hr = Set-WtHolidayDate (Get-WtHolidayData).Store '2026-11-03' 'personal' -Name '개인 휴무' -At '2026-11-01T09:00:00+09:00'
    $thread = [Threading.Thread]::CurrentThread; $oldCulture = $thread.CurrentCulture
    $holidaySnapshots = @()
    try {
        foreach ($culture in 'ko-KR', 'en-US', 'th-TH', 'ar-SA', 'ja-JP') {
            $thread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
            $hp = ConvertFrom-WtHolidayPaste "2028-02-29 윤일`n2028-02-30 없는 날" 2028
            $holidaySnapshots += "$($hp.Items.Date -join ',')|$($hp.Errors.Line -join ',')|$($hp.Errors.Reason -join ',')"
        }
    } finally { $thread.CurrentCulture = $oldCulture }
    Assert-Wt '휴무일 5개 문화권: 윤일 해석 · 오류 줄 동일' (@($holidaySnapshots | Where-Object { $_ -cne '2028-02-29|2|없는 날짜입니다' }).Count -eq 0)

    # ---- 설정 ----
    Initialize-WtSettings
    Assert-Wt '설정 기본값' ((Get-WtSetting 'theme.accent') -eq 'blue' -and (Get-WtSetting 'ui.opacity') -eq 100)
    Register-WtSettingHandler { param($k, $v) $script:seenKey = $k }
    Set-WtSetting 'theme.accent' 'pink'
    Set-WtSetting 'addons.disabled' @('test-b')
    Assert-Wt '설정이 바뀌면 처리기를 부른다' ($script:seenKey -eq 'addons.disabled')
    $saved = Get-Content (Get-WtSettingsPath) -Raw | ConvertFrom-Json
    Assert-Wt '바꾼 값만 저장한다' (@($saved.values.PSObject.Properties.Name).Count -eq 2 -and $saved.values.'theme.accent' -eq 'pink')
    Set-WtSetting 'theme.accent' 'blue'
    $saved = Get-Content (Get-WtSettingsPath) -Raw | ConvertFrom-Json
    Assert-Wt '기본값으로 돌리면 파일에서 빠진다' (-not ($saved.values.PSObject.Properties.Name -contains 'theme.accent'))
    Initialize-WtSettings
    Assert-Wt '배열 설정을 다시 읽는다' (@(Get-WtSetting 'addons.disabled') -contains 'test-b')

    # 업무시간은 다섯 값을 함께 검사하고, 기본값도 명시적으로 저장한다.
    $settingsBeforeHours = Read-WtJsonFile (Get-WtSettingsPath)
    $defaultHours = Get-WtWorkHours
    Assert-Wt '업무시간 기본값: 월~금 · 09:00~18:00 · 점심 12:00~13:00' (
        ($defaultHours['work.days'] -join ',') -ceq '1,2,3,4,5' -and $defaultHours['work.start'] -ceq '09:00' -and
        $defaultHours['work.end'] -ceq '18:00' -and $defaultHours['work.lunchStart'] -ceq '12:00' -and $defaultHours['work.lunchEnd'] -ceq '13:00')
    Assert-Wt '첫 설정: 기본값을 읽기만 하면 계속 필요하다' (Test-WtWorkSetupRequired)
    foreach ($bad in @(
        @('work.start', '9:00', 'work.start'), @('work.end', '08:00', 'work.end'),
        @('work.lunchStart', '08:00', 'work.lunchStart'), @('work.lunchEnd', '19:00', 'work.lunchEnd'),
        @('work.days', @(), 'work.days'), @('work.end', '09:00', 'work.end'),
        @('work.lunchEnd', '12:00', 'work.lunchEnd'), @('work.days', @(1, 8), 'work.days'),
        @('work.days', @('1'), 'work.days'), @('work.start', '24:00', 'work.start'))) {
        $before = Get-Content -LiteralPath (Get-WtSettingsPath) -Raw
        $candidate = $defaultHours.Clone(); $candidate[$bad[0]] = $bad[1]
        $errors = Get-WtWorkHoursErrors $candidate
        $refused = $false; $singleRefused = $false
        try { Set-WtWorkHours $candidate } catch [System.ArgumentException] { $refused = $true }
        try { Set-WtSetting $bad[0] $bad[1] } catch [System.ArgumentException] { $singleRefused = $true }
        Assert-Wt "업무시간 저장 거부: $($bad[0])=$(ConvertTo-Json -InputObject $bad[1] -Compress)" (
            $refused -and $singleRefused -and $errors.Contains($bad[2]) -and
            (Get-Content -LiteralPath (Get-WtSettingsPath) -Raw) -ceq $before -and (Test-WtWorkSetupRequired))
    }
    Set-WtWorkHours $defaultHours
    Initialize-WtSettings
    $savedHours = Read-WtJsonFile (Get-WtSettingsPath)
    Assert-Wt '첫 설정: 기본값으로 저장해도 work.start가 남고 다시 묻지 않는다' (
        -not (Test-WtWorkSetupRequired) -and $savedHours.values.'work.start' -ceq '09:00' -and
        @($savedHours.values.PSObject.Properties.Name | Where-Object { $_ -like 'work.*' }).Count -eq 5)
    $shiftHours = @{ 'work.days' = @(6, 7); 'work.start' = '06:00'; 'work.end' = '14:00'; 'work.lunchStart' = '10:00'; 'work.lunchEnd' = '11:00' }
    Set-WtWorkHours $shiftHours
    Initialize-WtSettings
    Assert-Wt '업무시간: 이동한 시간대와 주말 근무를 한 번에 저장 · 다시 읽기' (
        (Get-WtSetting 'work.start') -ceq '06:00' -and ((Get-WtSetting 'work.days') -join ',') -ceq '6,7')
    Set-WtSetting 'work.days' @(7)
    Initialize-WtSettings
    Set-WtSetting 'work.end' '15:00'
    $oneDay = Get-WtWorkHours
    Assert-Wt '업무시간: 요일 하나도 배열로 다시 읽고 다른 시각을 변경한다' (
        $oneDay['work.days'] -is [array] -and $oneDay['work.days'].Count -eq 1 -and $oneDay['work.days'][0] -eq 7 -and $oneDay['work.end'] -ceq '15:00')
    Write-WtJsonFile (Get-WtSettingsPath) $settingsBeforeHours
    Initialize-WtSettings

    # ---- 탭 목록 (가짜 탭) ----
    Register-WtAddon -Id 'test-b' -Title '나' -Order 20 -NewView { }
    Register-WtAddon -Id 'test-a' -Title '가' -Order 10 -NewView { }
    Register-WtAddon -Id 'test-c' -Title '다' -Order 10 -NewView { } -Required
    Assert-Wt '끈 탭은 메뉴 목록에서 빠진다' (-not (@(Get-WtAddon | ForEach-Object Id) -contains 'test-b') -and (@(Get-WtAddon -All | ForEach-Object Id) -contains 'test-b'))
    Set-WtSetting 'addons.disabled' @('test-c')
    Assert-Wt '꼭 있어야 하는 탭은 꺼도 메뉴에 남는다' (@(Get-WtAddon | ForEach-Object Id) -contains 'test-c')
    Set-WtSetting 'addons.disabled' @()
    Assert-Wt '메뉴 순서: Order가 같으면 ID 순서' ((@(Get-WtAddon | ForEach-Object Id) -join ',') -eq 'test-a,test-c,test-b') (@(Get-WtAddon | ForEach-Object Id) -join ',')
    Register-WtAddon -Id 'test-a' -Title '가2' -Order 10 -NewView { }
    Assert-Wt '같은 ID로 다시 등록하면 바꾼다' (@(Get-WtAddon -All | Where-Object Id -eq 'test-a').Count -eq 1 -and (Get-WtAddon -Id 'test-a').Title -eq '가2')

    # ---- 달력 등록 목록 (가짜 탭) ----
    Register-WtAddon -Id 'test-calendar' -Title '가짜 달력' -NewView { } -CalendarItems {
        param([datetime]$From, [datetime]$To)
        [pscustomobject]@{ Date = $From; Kind = 'test'; Text = '가짜 표시'; Style = 'Success'; AllDay = $false; Time = '09:00'; Id = 'test-item'; Page = 'test-calendar' }
        [pscustomobject]@{ Date = $To.AddDays(1); Kind = 'test'; Text = '범위 밖'; Style = 'Success'; AllDay = $true; Time = $null; Id = 'outside' }
    }
    Register-WtAddon -Id 'test-calendar-bad' -Title '가짜 실패' -NewView { } -CalendarItems { throw '일부러 낸 달력 오류' }
    $cr = Get-WtCalendarItems ([datetime]::new(2026, 11, 3)) ([datetime]::new(2026, 11, 4))
    Assert-Wt '달력: 출처 하나 실패해도 휴무일 · 다른 탭은 날짜별로 반환, 범위 밖 제외' (-not $cr.Success -and $cr.Items.Count -eq 2 -and
        $cr.Days.Count -eq 2 -and $cr.Days[0].Items.Count -eq 2 -and $cr.Days[1].Items.Count -eq 0 -and $cr.Errors.Count -eq 1 -and
        $cr.Errors[0].Page -ceq 'test-calendar-bad' -and $cr.Errors[0].Reason -like '*일부러*') (Get-WtTestJsonCore $cr.Errors)
    $cr = Get-WtCalendarItems ([datetime]::new(2026, 11, 3)) ([datetime]::new(2026, 11, 4)) -Exclude @('test-calendar', 'test-calendar-bad')
    Assert-Wt '달력: 호출 탭 제외, 코어 공용 휴무일은 남음' ($cr.Success -and $cr.Items.Count -eq 1 -and $cr.Items[0].Source -ceq 'holidays')
    Set-WtSetting 'addons.disabled' @('test-calendar-bad')
    $cr = Get-WtCalendarItems ([datetime]::new(2026, 11, 3)) ([datetime]::new(2026, 11, 4))
    Assert-Wt '달력: 끈 탭은 호출하지 않음' ($cr.Success -and $cr.Items.Count -eq 2)
    Register-WtAddon -Id 'test-calendar' -Title '가짜 달력' -NewView { }
    $cr = Get-WtCalendarItems ([datetime]::new(2026, 11, 3)) ([datetime]::new(2026, 11, 4))
    Assert-Wt '달력: 표시 함수 없이 다시 등록하면 옛 출처 해제' ($cr.Success -and $cr.Items.Count -eq 1)
    Register-WtCalendarSource -Id 'test-malformed' -CalendarItems { [pscustomobject]@{ Date = '내일' } }
    $cr = Get-WtCalendarItems ([datetime]::new(2026, 11, 3)) ([datetime]::new(2026, 11, 4))
    Assert-Wt '달력: 잘못된 항목 모양도 출처 오류로 격리' ($cr.Items.Count -eq 1 -and $cr.Errors[0].Source -ceq 'test-malformed')
    Register-WtCalendarSource -Id 'test-malformed' -CalendarItems $null
    Set-WtSetting 'addons.disabled' @()
    Register-WtAddon -Id 'test-calendar-bad' -Title '가짜 실패' -NewView { }

    # ---- 연 기록 · 홈 자리 (가짜 탭) ----
    Register-WtAddon -Id 'test-links' -Title '출처' -NewView { } -ShortcutExists { param($Key) $Key -cne 'gone' } -HomeCard { } -HomeSlot main -HomeOrder 10
    Register-WtAddon -Id 'test-side' -Title '옆' -NewView { } -HomeCard { } -HomeSlot side -HomeOrder 20 -CalendarHost
    Register-WtAddon -Id 'test-main' -Title '뒤' -NewView { } -HomeCard { } -HomeSlot main -HomeOrder 30
    Assert-Wt '홈 카드: 자리별 순서 · 달력 주인 등록' ((@(Get-WtHomeCards).Id -join ',') -ceq 'test-links,test-main,test-side' -and (Get-WtCalendarHost).Id -ceq 'test-side')
    Register-WtAddon -Id 'test-two-cards' -Title '두 카드' -NewView { } -HomeCards @(
        @{ Slot = 'main'; Order = 15; Card = { '가짜 본문' } }, @{ Slot = 'side'; Order = 25; Card = { '가짜 옆' } })
    $twoCards = @(Get-WtHomeCards | Where-Object Id -ceq 'test-two-cards')
    Assert-Wt '홈 카드: 탭 하나의 서로 다른 자리 두 카드 · 기존 단일 카드와 정렬' ($twoCards.Count -eq 2 -and
        $twoCards[0].HomeSlot -ceq 'main' -and $twoCards[0].HomeOrder -eq 15 -and (& $twoCards[0].HomeCard) -ceq '가짜 본문' -and
        $twoCards[1].HomeSlot -ceq 'side' -and $twoCards[1].HomeOrder -eq 25 -and (& $twoCards[1].HomeCard) -ceq '가짜 옆' -and
        (@(Get-WtHomeCards).Id -join ',') -ceq 'test-links,test-two-cards,test-main,test-side,test-two-cards')
    Register-WtAddon -Id 'test-two-cards' -Title '두 카드' -NewView { }
    function New-WtTestShortcut([string]$Key, [string]$Title, [object[]]$Uses, [bool]$Pinned = $false, $Order = $null) {
        [pscustomobject]@{ id = $Key; page = 'test-links'; key = $Key; title = $Title; sub = ''; icon = 0xE8A5; uses = @($Uses); pinned = $Pinned; pinOrder = $Order; future = @{ keep = '보존' } }
    }
    $scNow = [DateTimeOffset]::Now
    $scRecent = Get-WtStamp $scNow.AddMinutes(-1); $scEarlier = Get-WtStamp $scNow.AddDays(-1); $scOld = Get-WtStamp $scNow.AddDays(-31)
    $scItems = @(
        (New-WtTestShortcut 'many' '많음' @($scRecent, $scEarlier, $scEarlier)),
        (New-WtTestShortcut 'recent' '최근' @($scRecent, $scEarlier)),
        (New-WtTestShortcut 'z' '나' @($scEarlier, $scEarlier)), (New-WtTestShortcut 'a' '가' @($scEarlier, $scEarlier)),
        (New-WtTestShortcut 'pin-second' '가 고정' @() $true 2), (New-WtTestShortcut 'pin-first' '나 고정' @() $true 1),
        (New-WtTestShortcut 'old' '지난 기록' @($scOld)), (New-WtTestShortcut 'gone' '없어진 항목' @($scRecent))
    )
    $scItems += ,$null; $scItems += ,@('모르는', '목록'); $scItems += ,@()
    [void](Save-WtStore (Open-WtStore 'shortcuts' 1) $scItems -Extra @{ futureTop = @{ keep = 7 } })
    $ranked = @(Get-WtShortcuts)
    Assert-Wt '바로 가기: 고정 → 횟수 → 최근 → 제목 · 30일 밖/없어진 항목 제외' (($ranked.Key -join ',') -ceq 'pin-first,pin-second,many,recent,a,z' -and $ranked[2].Count -eq 3) ($ranked.Key -join ',')
    Set-WtSetting 'addons.disabled' @('test-links')
    Assert-Wt '바로 가기: 꺼진 탭 제외 · 저장 유지' (@(Get-WtShortcuts).Count -eq 0 -and (Open-WtStore 'shortcuts' 1).Items.Count -eq 11)
    Set-WtSetting 'addons.disabled' @()
    Add-WtUse -Page test-links -Key many -Title '많음' -Sub '시험'
    $scRound = Open-WtStore 'shortcuts' 1
    Assert-Wt '바로 가기 왕복: 모르는 맨 위/항목 칸 · null · 목록 · 빈 목록 보존' ($scRound.Doc.futureTop.keep -eq 7 -and $scRound.Items[0].future.keep -ceq '보존' -and
        $scRound.Items.Count -eq 11 -and $null -eq $scRound.Items[8] -and $scRound.Items[9][1] -ceq '목록' -and $scRound.Items[10] -is [array] -and $scRound.Items[10].Count -eq 0)
    Set-WtHomePin -Page test-links -Key a -Title '가' -Pinned $true
    Set-WtHomePin -Page test-links -Key a -Title '가' -Pinned $true
    Assert-Wt '홈 고정: 중복 고정은 순서 유지' ((Test-WtHomePin test-links a) -and (@(Get-WtShortcuts).Key -join ',') -ceq 'pin-first,pin-second,a,many,recent,z')
    Set-WtHomePin -Page test-links -Key a -Title '가' -Pinned $false
    Assert-Wt '홈 고정 해제' (-not (Test-WtHomePin test-links a))
    $scStore = Open-WtStore 'shortcuts' 1; $scCopy = @(Copy-WtItem $scStore.Items)
    $scCopy[0].uses = @($scOld) + @(1..205 | ForEach-Object { Get-WtStamp $scNow.AddSeconds(-$_) })
    [void](Save-WtStore $scStore $scCopy)
    Add-WtUse -Page test-links -Key many -Title '많음'
    $scSaved = (Open-WtStore 'shortcuts' 1).Items[0]
    Assert-Wt '연 기록: 30일 밖 버림 · 최근 200회 제한' ($scSaved.uses.Count -eq 200 -and $scSaved.uses -cnotcontains $scOld -and @($scSaved.uses | Where-Object { (ConvertFrom-WtStamp $_) -lt (ConvertFrom-WtStamp (Get-WtStamp $scNow.AddSeconds(-199))) }).Count -eq 0)
    foreach ($id in 'test-links', 'test-side', 'test-main') { Register-WtAddon -Id $id -Title '검사 끝' -NewView { } }

    $scHours = Get-WtWorkHours
    Set-WtWorkHours @{ 'work.days' = @(1, 2, 3, 4, 5); 'work.start' = '10:00'; 'work.end' = '19:00'; 'work.lunchStart' = '12:00'; 'work.lunchEnd' = '13:00' }
    Register-WtCalendarSource -Id 'test-marks' -CalendarItems {
        foreach ($spec in @(@('2026-11-02', 'work', '10:00'), @('2026-11-03', 'work', '09:30'), @('2026-11-04', 'leave', ''), @('2026-11-07', 'work', '11:00'))) {
            [pscustomobject]@{ Date = ConvertFrom-WtDateText $spec[0]; Kind = $spec[1]; Text = $spec[1]; Style = 'Sub'; AllDay = -not [bool]$spec[2]; Time = $spec[2]; Id = $spec[0] }
        }
    }
    $marksData = Get-WtCalendarItems ([datetime]'2026-11-02') ([datetime]'2026-11-08')
    $marks = @(2, 3, 4, 7, 8 | ForEach-Object { Get-WtCalendarMark ([datetime]::new(2026, 11, $_)) $marksData.Items })
    Assert-Wt '작은 달력: 업무시간 설정 · 안/밖 ✔ 색 · 휴가 X · 쉬는 날 출근 ✔ 우선' ($marks[0].Glyph -eq 0xE73E -and $marks[0].Brush -ceq 'B.Status.Success.Icon' -and
        $marks[1].Glyph -eq 0xE73E -and $marks[1].Brush -ceq 'B.Text.Tertiary' -and $marks[2].Glyph -eq 0xE711 -and $marks[2].DayOff -and $marks[3].Glyph -eq 0xE73E -and $marks[3].DayOff -and $marks[4].Glyph -eq 0xE711)
    Register-WtCalendarSource -Id 'test-marks' -CalendarItems $null
    Set-WtWorkHours $scHours

    # ---- 도움말 단축키 (가짜 탭) ----
    Register-WtAddon -Id 'test-x' -Title '엑스' -Order 30 -NewView { } -Shortcuts @(@('F5', '새로 고침'), @('Enter', '열기'))
    Register-WtAddon -Id 'test-y' -Title '와이' -Order 40 -NewView { } -Shortcuts (, @('F5', '새로 고침'))
    Register-WtAddon -Id 'test-one' -Title '하나' -Order 90 -NewView { } -Shortcuts @('F9', '혼자')
    Assert-Wt '단축키 한 쌍은 쉼표 없이 줘도 한 쌍' (@((Get-WtAddon -Id 'test-one').Shortcuts).Count -eq 1 -and (Get-WtAddon -Id 'test-one').Shortcuts[0][1] -eq '혼자')
    $threw = $false
    try { Register-WtAddon -Id 'test-bad' -Title '잘못' -NewView { } -Shortcuts @(@('F5', '새로 고침', '남는 값')) } catch { $threw = $true }
    Assert-Wt '모양이 틀린 단축키는 등록할 때 알린다' ($threw -and -not (Get-WtAddon -Id 'test-bad'))
    $keyRows = (@(& (Get-Module Pages) { Get-WtShortcutRows }) | ForEach-Object { "$($_.Key)=$($_.Text)" }) -join '|'
    Assert-Wt '도움말 단축키: 메뉴 순서로 모으고, 키 · 설명이 같으면 탭 이름을 묶는다' ($keyRows -eq 'F5=엑스 · 와이: 새로 고침|Enter=엑스: 열기|F9=하나: 혼자') $keyRows
    Set-WtSetting 'addons.disabled' @('test-y')
    $keyRows = (@(& (Get-Module Pages) { Get-WtShortcutRows }) | ForEach-Object { "$($_.Key)=$($_.Text)" }) -join '|'
    Assert-Wt '도움말 단축키: 끈 탭은 뺀다' ($keyRows -eq 'F5=엑스: 새로 고침|Enter=엑스: 열기|F9=하나: 혼자') $keyRows
    Set-WtSetting 'addons.disabled' @()

    # ---- 예전 데이터 가져오기 흐름 (가짜 탭) ----
    # 예전 WorkTool(WinForms)의 data 폴더는 정해진 CSV 이름으로 알아본다
    Write-WtTestLegacyCsv $test 'memo' "`"Id`"`n"
    Assert-Wt '예전 data 폴더를 찾는다' ((Find-WtLegacyFolder) -eq $test.Legacy) (Find-WtLegacyFolder)
    $legacyCalls = [pscustomobject]@{ Count = 0 }
    Register-WtAddon -Id 'test-legacy' -Title '가짜' -NewView { } -ImportLegacy {
        param($folder)
        $legacyCalls.Count++
        Write-WtStore -Name 'test-legacy' -Items @([ordered]@{ id = "n$($legacyCalls.Count)" })
        3
    }.GetNewClosure()
    $r = Import-WtLegacyData
    Assert-Wt '처음 실행: 저장소가 없는 탭만 가져온다' ($r.Count -eq 3 -and $r.Tabs -contains '가짜 3' -and $r.Folder -eq $test.Legacy) "($($r.Count) / $($r.Tabs -join ', '))"
    $r2 = Import-WtLegacyData
    Assert-Wt '두 번째 실행: 이미 가져온 탭은 건너뛴다' ($r2.Count -eq 0 -and $legacyCalls.Count -eq 1)
    $r3 = Import-WtLegacyData -Force
    Assert-Wt '다시 가져오기는 덮어쓰고 .bak을 남긴다' ($r3.Count -eq 3 -and $legacyCalls.Count -eq 2 -and (Test-Path ((Get-WtStorePath 'test-legacy') + '.bak')))

    # ---- 테마 색 대비 ----
    $pairs = @(
        @('OnAccent', 'Accent', 4.5), @('OnAccent', 'Accent.Hover', 4.5), @('OnAccent', 'Accent.Pressed', 4.5), @('AccentStrong', 'AccentSoft', 4.5),
        @('Text', 'WindowBg', 4.5), @('Text', 'Sidebar', 4.5), @('Text', 'AccentSoft', 4.5), @('Text', 'Hover', 4.5),
        @('SubText', 'WindowBg', 4.5), @('SubText', 'Sidebar', 4.5), @('SubText', 'Card', 4.5),
        @('NavText', 'Sidebar', 4.5), @('NavText', 'Hover', 4.5),
        @('InputBorder', 'Card', 3.0), @('Accent', 'Card', 3.0))
    Assert-Wt '테마 2판: 강조색은 파랑 기본 · 분홍 · 청록 · 보라 · 회색만' (((Get-WtPalette).Keys -join ',') -ceq 'blue,pink,teal,purple,gray')
    $expectedAccents = @{
        blue = @('#1A5BBE', '#174FA6', '#144690'); pink = @('#B83D69', '#A1355C', '#8C2E50')
        teal = @('#0B6B69', '#0A5D5C', '#085150'); purple = @('#7048B8', '#623FA1', '#55378C'); gray = @('#56606D', '#4B545F', '#414953')
    }
    foreach ($name in (Get-WtPalette).Keys) {
        $c = Get-WtThemeColors -Accent $name
        $bad = foreach ($p in $pairs) {
            $ratio = Get-WtContrast $c[$p[0]] $c[$p[1]]
            if ($ratio -lt $p[2]) { '{0}/{1} {2:N2}' -f $p[0], $p[1], $ratio }
        }
        Assert-Wt "테마 '$name' 색 대비" (-not $bad) ($bad -join ', ')
        Assert-Wt "테마 '$name' 2판 강조 상태와 중성 면" (($c.Accent, $c['Accent.Hover'], $c['Accent.Pressed'] -join ',') -ceq ($expectedAccents[$name] -join ',') -and
            $c.WindowBg -ceq '#F3F4F6' -and $c.Sidebar -ceq '#F3F4F6' -and $c.Card -ceq '#FFFFFF' -and $c['Bg.Subtle'] -ceq '#F7F8FA' -and $c.AccentSoft -ceq '#E8F0FC')
        $bad = foreach ($fg in 'Text.Primary', 'Text.Secondary', 'Text.Tertiary') {
            foreach ($bg in 'Bg.Canvas', 'Bg.Surface', 'Bg.Subtle', 'Bg.Raised', 'Bg.Selected', 'Fill.Hover.Surface', 'Fill.Pressed.Surface', 'Fill.Hover.Canvas', 'Fill.Pressed.Canvas', 'Fill.Selected.Nav', 'Fill.Hover.Subtle', 'Fill.Pressed.Subtle') {
                $ratio = Get-WtContrast $c[$fg] $c[$bg]
                if ($ratio -lt 4.5) { '{0}/{1} {2:N2}' -f $fg, $bg, $ratio }
            }
        }
        foreach ($bg in 'Bg.Canvas', 'Bg.Surface', 'Bg.Subtle', 'Bg.Selected', 'Fill.Hover.Surface', 'Fill.Pressed.Surface') {
            $ratio = Get-WtContrast $c['Accent.Text'] $c[$bg]
            if ($ratio -lt 4.5) { 'Accent.Text/{0} {1:N2}' -f $bg, $ratio }
        }
        Assert-Wt "테마 '$name' 2판 본문·보조·3차·강조 글자 AA 4.5:1" (-not $bad) ($bad -join ', ')
        $bad = foreach ($state in 'Success', 'Warning', 'Error', 'Info', 'Neutral') {
            if ((Get-WtContrast $c["Status.$state.Text"] $c["Status.$state.Bg"]) -lt 4.5 -or
                (Get-WtContrast $c["Status.$state.Text"] $c['Bg.Surface']) -lt 4.5 -or
                (Get-WtContrast $c["Status.$state.Icon"] $c['Bg.Surface']) -lt 3) { $state }
        }
        Assert-Wt "테마 '$name' 2판 상태 글자 AA·아이콘 대비" (-not $bad) ($bad -join ', ')
    }
    foreach ($k in 'Work', 'Over', 'Trip', 'Leave') {
        $c = Get-WtThemeColors -Accent 'blue'
        Assert-Wt "근태 표시 '$k' 색 대비" ((Get-WtContrast $c["Att.$k"] $c["Att.${k}Bg"]) -ge 4.5)
    }
    $c = Get-WtThemeColors -Accent 'blue'
    $bad = foreach ($k in 'Blue', 'Teal', 'Green', 'Orange', 'Red', 'Purple', 'Gray') {
        foreach ($fg in "Callout.$k", 'Text') {
            $ratio = Get-WtContrast $c[$fg] $c["Callout.${k}Bg"]
            if ($ratio -lt 4.5) { '{0}/{1} {2:N2}' -f $fg, $k, $ratio }
        }
    }
    Assert-Wt '콜아웃 색 대비' (-not $bad) ($bad -join ', ')
    $bad = foreach ($k in 'Comment', 'String', 'Keyword', 'Number', 'Command', 'Variable', 'Type', 'Attr', 'Inserted', 'Deleted', 'Text') {
        $fg = if ($k -eq 'Text') { 'Text' } else { "Code.$k" }
        $ratio = Get-WtContrast $c[$fg] $c['Code.Bg']
        if ($ratio -lt 4.5) { '{0} {1:N2}' -f $fg, $ratio }
    }
    Assert-Wt '코드 색 대비 (코드 바탕 위)' (-not $bad) ($bad -join ', ')
    Assert-Wt '마크다운 · 다이어그램 색 대비' ((Get-WtContrast $c.Text $c['Md.Mark']) -ge 4.5 -and (Get-WtContrast $c.Text $c['Dia.NodeBg']) -ge 4.5 -and
        (Get-WtContrast $c.Text $c['Dia.NoteBg']) -ge 4.5 -and (Get-WtContrast $c.SubText $c['Dia.GroupBg']) -ge 4.5 -and
        (Get-WtContrast $c['Dia.Line'] $c.Card) -ge 3 -and (Get-WtContrast $c['Dia.NodeLine'] $c.Card) -ge 3)

    # 옛 값은 보존하되 강조색 결정에는 쓰지 않는다. 새 값이 없거나 모르는 값이면 파랑.
    foreach ($legacyName in 'sky', 'pink', 'green', 'yellow', 'purple', 'gray', 'black', 'unknown') {
        Set-WtSetting 'theme.color' $legacyName
        Assert-Wt "테마: 옛 theme.color '$legacyName'은 무시" ((Get-WtThemeColors $legacyName).Accent -ceq '#1A5BBE' -and (Get-WtSetting 'theme.accent') -ceq 'blue')
    }
    Set-WtSetting 'theme.accent' 'pink'
    $savedTheme = Get-Content (Get-WtSettingsPath) -Raw | ConvertFrom-Json
    Assert-Wt '테마: 강조색을 바꿔도 파일의 옛 키는 남는다' ($savedTheme.values.'theme.color' -ceq 'unknown' -and $savedTheme.values.'theme.accent' -ceq 'pink' -and (Get-WtThemeColors 'gray').Accent -ceq '#B83D69')
    Set-WtSetting 'theme.accent' 'unknown'
    Assert-Wt '테마: 모르는 새 강조색도 파랑으로 안전하게 표시' ((Get-WtThemeColors).Accent -ceq '#1A5BBE')
    Set-WtSetting 'theme.accent' 'blue'
    Assert-Wt '테마: 글자 2판 단계와 옛 크기 별칭' ((Get-WtFontSize 'Body') -eq 14 -and (Get-WtFontSize 'Small') -eq 12 -and
        (Get-WtFontSize 'Title') -eq 20 -and (Get-WtFontSize 'Memo.Body') -eq 15 -and (Get-WtFontSize 'BodyLine') -eq 24 -and
        (Get-WtFontSize 'MdH2') -eq 18 -and (Get-WtFontSize 'MdH3') -eq 16 -and (Get-WtFontSize 'Code') -eq 14)

    # ---- 마크다운 ----
    $md = @'
---
tags: [a, b]
---
# 제목 **굵게**

본문 [[다른 메모|별칭]] #태그 #123 %%숨김%% [링크](https://example.com) [파일](docs/a%20b.md)
둘째 줄

> [!warning]- 조심 **해**
> 본문

> [!NOTE]
> 깃허브 알림

> 그냥 인용

- [x] 끝남
- [ ] 할 일

| a | b |
|:--|--:|
| 1 | 2 |

```ps1
Get-Item C:\
```

각주[^1]

[^1]: 내용
'@
    $mm = ConvertTo-WtMarkdownModel $md
    $types = (@($mm.Blocks) | ForEach-Object T) -join ','
    Assert-Wt '마크다운: 블록 종류' ($types -eq 'props,heading,para,callout,callout,quote,list,table,code,para,footnotes') $types
    Assert-Wt '마크다운: 속성(--- 사이)' ($mm.Blocks[0].Items[0].Key -eq 'tags' -and $mm.Blocks[0].Items[0].Value -eq 'a, b')
    $p = $mm.Blocks[2].Inl
    $wiki = $p | Where-Object { $_.T -eq 'link' -and $_.Kind -eq 'wiki' }
    Assert-Wt '마크다운: 위키 링크' ($wiki.Target -eq '다른 메모' -and $wiki.Inl[0].Text -eq '별칭')
    Assert-Wt '마크다운: 태그 (숫자만은 태그 아님)' (@($p | Where-Object T -eq 'tag').Count -eq 1 -and ($p | Where-Object T -eq 'tag').Text -eq '태그')
    Assert-Wt '마크다운: %%주석%%은 빠진다' (-not ((Get-WtMarkdownSnippet '가 %%숨김%% 나') -match '숨김') -and -not (@($p | Where-Object { $_.T -eq 'text' -and $_.Text -match '숨김' }).Count))
    $links = @($p | Where-Object { $_.T -eq 'link' -and $_.Kind -ne 'wiki' })
    Assert-Wt '마크다운: 링크 종류 (주소 · 파일)' ($links[0].Kind -eq 'url' -and $links[1].Kind -eq 'file' -and $links[1].Target -eq 'docs/a b.md')
    Assert-Wt '마크다운: 줄바꿈 한 번' (@($p | Where-Object T -eq 'soft').Count -eq 1)
    $co = $mm.Blocks[3]
    Assert-Wt '마크다운: 콜아웃 종류 · 접기 · 제목' ($co.Kind -eq 'warning' -and $co.Fold -eq '-' -and (@($co.Title | ForEach-Object { if ($_.Inl) { $_.Inl[0].Text } else { $_.Text } }) -join '') -eq '조심 해' -and $co.Blocks.Count -eq 1)
    Assert-Wt '마크다운: 제목 없는 콜아웃은 종류 이름' ($mm.Blocks[4].Kind -eq 'note' -and $mm.Blocks[4].Title[0].Text -eq 'Note')
    Assert-Wt '마크다운: 할 일 목록' ($mm.Blocks[6].Items[0].Task -eq $true -and $mm.Blocks[6].Items[1].Task -eq $false -and $mm.Blocks[6].Items[0].Blocks[0].Inl[0].Text -eq '끝남')
    Assert-Wt '마크다운: 표 정렬' (($mm.Blocks[7].Align -join ',') -eq 'left,right' -and $mm.Blocks[7].Rows[0].Header)
    Assert-Wt '마크다운: 코드 블록' ($mm.Blocks[8].Lang -eq 'ps1' -and $mm.Blocks[8].Text -eq 'Get-Item C:\')
    Assert-Wt '마크다운: 각주' ($mm.Blocks[9].Inl[1].T -eq 'fn' -and $mm.Blocks[10].Items[0].Order -eq 1)
    Assert-Wt '마크다운: 제목 목록' ($mm.Headings.Count -eq 1 -and $mm.Headings[0].Text -eq '제목 굵게')
    $snip = Get-WtMarkdownSnippet "# 점검`n- [ ] 디스크`n- **로그** 확인`n| a | b |`n|--|--|`n[[메모|별칭]]"
    Assert-Wt '마크다운: 목록용 한 줄 요약' ($snip -eq '점검 · 디스크 · 로그 확인 · a  b · 별칭') $snip
    $longSnippet = "---`ntitle: 숨긴 제목`n---`n%%숨김%%`n# **첫 줄** &amp; [링크](https://example.com)`n| 항목 | 값 |`n|---|---|`n" + ("`n- [ ] [[메모|별칭]] <b>확인</b>" * 100)
    $wholeSnippet = Get-WtMarkdownSnippet $longSnippet 100000
    $prefixOk = $true
    foreach ($limit in 0,1,5,12,300) { if ((Get-WtMarkdownSnippet $longSnippet $limit) -cne $wholeSnippet.Substring(0, [Math]::Min($limit, $wholeSnippet.Length))) { $prefixOk = $false } }
    Assert-Wt '마크다운: 긴 글 요약도 속성·주석·줄 구분을 처리한 접두사와 같다' $prefixOk
    Assert-Wt '마크다운: 빈 글' ((ConvertTo-WtMarkdownModel '').Blocks.Count -eq 0 -and (Get-WtMarkdownSnippet '') -eq '')
    # 파일 링크: 메모 편집기는 경로를 <C:/a b/c.txt> · <//서버/공유/x>처럼 슬래시로 쓴다. 역슬래시 경로 · file: 주소도 그대로 된다
    $mdModule = Get-Module Markdown
    $fileLinks = @((ConvertTo-WtMarkdownModel '[a](<C:/a b/c.txt>) [b](<//srv/share/x>) [c](C:\x\y.log) [d](file:///C:/a%20b/c.txt) [e](file://srv/share/f.md)').Blocks[0].Inl | Where-Object T -eq 'link')
    $resolved = @($fileLinks | ForEach-Object { & $mdModule { param($t) Resolve-WtMdPath $t '' } $_.Target }) -join '|'
    Assert-Wt '마크다운: 파일 링크 종류 · 경로 풀기 (슬래시 · UNC · 역슬래시 · file:)' ((@($fileLinks | ForEach-Object Kind) -join ',') -eq 'file,file,file,file,file' -and
        $resolved -eq 'C:\a b\c.txt|\\srv\share\x|C:\x\y.log|C:\a b\c.txt|\\srv\share\f.md') $resolved
    $guess = @('C:\a\', 'D:/x/', 'C:', 'C:\', '\\srv\share', '//srv/share', '\\srv', 'C:\a\b', '\\srv\share\x', 'C:\a\b.txt', '\\srv\share\x.xlsx', 'C:\a.b\c.md') |
        ForEach-Object { if (& $mdModule { param($p) Test-WtMdFolderLike $p } $_) { 'D' } else { 'F' } }
    Assert-Wt '마크다운: 폴더 추측 (끝 \ · 드라이브 루트 · 공유 루트 · 확장자 없음)' (($guess -join '') -eq 'DDDDDDDDDFFF') ($guess -join '')

    # ---- 코드 색칠 ----
    $tok = Get-WtCodeTokens 'Get-ChildItem -Path $env:TEMP | Where-Object { $_.Length -gt 1KB } # 주석' 'powershell'
    $kinds = (@($tok) | Where-Object Kind | ForEach-Object { "$($_.Kind):$($_.Text)" }) -join ' '
    Assert-Wt '코드 색칠: PowerShell' ($kinds -eq 'Command:Get-ChildItem Attr:-Path Variable:$env:TEMP Command:Where-Object Variable:$_ Keyword:-gt Number:1KB Comment:# 주석') $kinds
    Assert-Wt '코드 색칠: 조각을 이으면 원래 글' ((@($tok) | ForEach-Object Text) -join '' -eq 'Get-ChildItem -Path $env:TEMP | Where-Object { $_.Length -gt 1KB } # 주석')
    Assert-Wt '코드 색칠: 별칭 · 모르는 언어' ((Get-WtCodeLanguage 'PS1') -eq 'powershell' -and (Get-WtCodeLanguage 'sh') -eq 'bash' -and $null -eq (Get-WtCodeLanguage 'nope') -and @(Get-WtCodeTokens 'x' 'nope')[0].Kind -eq '')
    $str = @(Get-WtCodeTokens 'echo "a # b" # c' 'bash') | Where-Object Kind
    Assert-Wt '코드 색칠: 문자열 안의 #은 주석이 아님' (($str | ForEach-Object Kind) -join ',' -eq 'Command,String,Comment')

    # ---- Mermaid ----
    $fc = ConvertFrom-WtMermaid @'
flowchart LR
    A[시작] --> B{확인?}
    B -->|예| C[(DB)]
    B -- 아니오 --> D([끝])
    C -.-> D & A
    subgraph g1 [묶음]
      C
    end
'@
    Assert-Wt 'Mermaid: flowchart 노드 · 모양' ($fc.Dir -eq 'LR' -and (($fc.Nodes.Values | ForEach-Object Shape) -join ',') -eq 'rect,diamond,cylinder,stadium' -and $fc.Nodes['C'].Group -eq 'g1')
    $el = ($fc.Edges | ForEach-Object { "$($_.From)$($_.To):$($_.Style):$($_.Text)" }) -join ' '
    Assert-Wt 'Mermaid: flowchart 선 · 라벨 · & 묶음' ($el -eq 'AB:normal: BC:normal:예 BD:normal:아니오 CD:dotted: CA:dotted:') $el
    $lay = Get-WtMermaidLayout $fc
    $nodes = @($lay.Items | Where-Object K -eq 'node')
    $overlap = $false
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        for ($j = $i + 1; $j -lt $nodes.Count; $j++) {
            $a = $nodes[$i]; $b = $nodes[$j]
            if ($a.X -lt $b.X + $b.W -and $b.X -lt $a.X + $a.W -and $a.Y -lt $b.Y + $b.H -and $b.Y -lt $a.Y + $a.H) { $overlap = $true }
        }
    }
    Assert-Wt 'Mermaid: 배치 (노드 4개, 겹치지 않음, 그림 안)' ($nodes.Count -eq 4 -and -not $overlap -and -not @($nodes | Where-Object { $_.X -lt 0 -or $_.Y -lt 0 -or $_.X + $_.W -gt $lay.Width -or $_.Y + $_.H -gt $lay.Height }).Count)
    $ax = ($nodes | Where-Object Text -eq '시작').X; $bx = ($nodes | Where-Object Text -eq '확인?').X
    Assert-Wt 'Mermaid: LR은 왼쪽에서 오른쪽' ($ax -lt $bx)
    $sq = ConvertFrom-WtMermaid "sequenceDiagram`n participant A as 서버`n actor U`n U->>A: 요청`n A-->>U: 응답`n loop 매일`n A->>A: 점검`n end`n Note right of A: 메모"
    Assert-Wt 'Mermaid: sequence' ((($sq.Participants.Values | ForEach-Object Label) -join ',') -eq '서버,U' -and $sq.Participants['U'].Actor -and
        (($sq.Items | ForEach-Object K) -join ',') -eq 'msg,msg,start,msg,end,note' -and $sq.Items[1].Line -eq 'dashed')
    Assert-Wt 'Mermaid: sequence 배치' (@((Get-WtMermaidLayout $sq).Items | Where-Object K -eq 'line').Count -ge 5)
    $stm = ConvertFrom-WtMermaid "stateDiagram-v2`n [*] --> 대기`n 대기 --> 실행 : 시작`n 실행 --> [*]"
    Assert-Wt 'Mermaid: state ([*] · 라벨)' ($stm.Nodes.Count -eq 4 -and (($stm.Edges | ForEach-Object Text) -join ',') -eq ',시작,')
    $threw = $null
    try { [void](ConvertFrom-WtMermaid "gantt`n title x") } catch { $threw = $_.Exception }
    Assert-Wt 'Mermaid: 모르는 종류는 NotSupported' ($threw -is [System.NotSupportedException])

    # ---- WPF로 그리기 (Windows · STA에서만) ----
    if ($wpf) {
        # 공통 부품만 검사한다. 실제 탭의 배치·문구 기대는 바꾸지 않는다.
        $v2Theme = New-WtThemeDictionary
        $v2Styles = Get-WtStyleDictionary
        $styleErrors = foreach ($styleKey in @($v2Styles.Keys)) {
            $itemStyle = $v2Styles[$styleKey]
            if ($itemStyle -isnot [System.Windows.Style] -or -not [System.Windows.FrameworkElement].IsAssignableFrom($itemStyle.TargetType)) { continue }
            try {
                $control = [Activator]::CreateInstance($itemStyle.TargetType)
                $control.Resources.MergedDictionaries.Add($v2Theme); $control.Resources.MergedDictionaries.Add($v2Styles)
                $control.Style = $itemStyle
                if ($control -is [System.Windows.Controls.Control]) { [void]$control.ApplyTemplate() }
                $control.Measure([System.Windows.Size]::new(800, 800))
            } catch { "$styleKey : $($_.Exception.Message)" }
        }
        Assert-Wt 'WPF 2판: 모든 공통 스타일 템플릿을 실제로 만든다' (-not $styleErrors) ($styleErrors -join '; ')
        $styleHost = [System.Windows.Controls.StackPanel]::new()
        $styleHost.Resources.MergedDictionaries.Add($v2Theme); $styleHost.Resources.MergedDictionaries.Add($v2Styles)
        $v2Button = New-WtButton '검사' -Kind Primary
        $v2Icon = New-WtButton '' -Kind Icon -Icon 0xE710
        $v2Input = [System.Windows.Controls.TextBox]::new(); Set-WtStyle $v2Input 'Input'
        $v2Row = [System.Windows.Controls.ListBoxItem]::new(); Set-WtStyle $v2Row 'Row'; $v2Row.Content = '행'; $v2Row.IsSelected = $true
        $v2Check = [System.Windows.Controls.CheckBox]::new(); Set-WtStyle $v2Check 'Checklist.Row'; $v2Check.Content = '완료'; $v2Check.IsChecked = $true
        foreach ($element in $v2Button, $v2Icon, $v2Input, $v2Row, $v2Check) { [void]$styleHost.Children.Add($element); [void]$element.ApplyTemplate() }
        $styleHost.Measure([System.Windows.Size]::new(800, 800)); $styleHost.Arrange([System.Windows.Rect]::new(0, 0, 800, 800))
        Assert-Wt 'WPF 2판: 버튼·입력·목록 32, 아이콘·체크리스트 28' ($v2Button.MinHeight -eq 32 -and $v2Input.MinHeight -eq 32 -and $v2Row.MinHeight -eq 32 -and $v2Icon.Width -eq 28 -and $v2Icon.Height -eq 28 -and $v2Check.MinHeight -eq 28)
        $v2Filter = New-WtFilterChip '조건'
        [void]$styleHost.Children.Add($v2Filter.Root)
        $styleHost.Measure([System.Windows.Size]::new(800, 800)); $styleHost.Arrange([System.Windows.Rect]::new(0, 0, 800, 800))
        $global:wtTestChipRemoved = 0
        $v2Filter.Remove.Add_Click({ $global:wtTestChipRemoved++ })
        $v2Filter.Remove.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
        Assert-Wt 'WPF 2판: 조건 칩 높이 24·삭제 영역 20×24·삭제 이벤트 하나' ($v2Filter.Root.ActualHeight -eq 24 -and $v2Filter.Remove.Width -eq 20 -and $v2Filter.Remove.Height -eq 24 -and $global:wtTestChipRemoved -eq 1)
        $v2Binding = [System.Windows.Data.Binding]::new('Value')
        $v2Binding.Source = [pscustomobject]@{ Value = '검사' }
        $v2Expression = $v2Input.SetBinding([System.Windows.Controls.TextBox]::TextProperty, $v2Binding)
        $v2Error = [System.Windows.Controls.ValidationError]::new([System.Windows.Controls.ExceptionValidationRule]::new(), $v2Expression, '검사 오류', $null)
        [System.Windows.Controls.Validation]::MarkInvalid($v2Expression, $v2Error)
        $errorIcon = $v2Input.Template.FindName('ErrorIcon', $v2Input)
        Assert-Wt 'WPF 2판: 입력 오류는 오류색 선·아이콘과 이유 툴팁' ($v2Input.BorderBrush.Color.ToString() -ceq '#FFC42F29' -and $errorIcon.Visibility -eq 'Visible' -and $v2Input.ToolTip -ceq '검사 오류')
        [System.Windows.Controls.Validation]::ClearInvalid($v2Expression)
        $selectedBar = $v2Row.Template.FindName('SelectedBar', $v2Row)
        Assert-Wt 'WPF 2판: 선택 행은 선택 면 + 3×16 강조 막대' ($v2Row.Background.Color.ToString() -ceq '#FFE8F0FC' -and $selectedBar.Visibility -eq 'Visible' -and $selectedBar.Width -eq 3 -and $selectedBar.Height -eq 16)
        $checkLabel = Get-WtVisualChild $v2Check ([System.Windows.Controls.ContentPresenter])
        $checkText = Get-WtVisualChild $checkLabel ([System.Windows.Controls.TextBlock])
        Assert-Wt 'WPF 2판: 완료 체크리스트는 3차 글자색만, 취소선·추가 투명도 없음' ($v2Check.Foreground.Color.ToString() -ceq '#FF5C6470' -and $v2Check.Opacity -eq 1 -and $checkText.TextDecorations.Count -eq 0)
        $v2Button.IsEnabled = $false
        Assert-Wt 'WPF 2판: 비활성은 정해진 면·선·글자, 불투명도 1' ($v2Button.Background.Color.ToString() -ceq '#FFF3F4F6' -and $v2Button.Foreground.Color.ToString() -ceq '#FFA3AAB4' -and $v2Button.Opacity -eq 1)
        $v2Tip = [System.Windows.Controls.ToolTip]::new()
        $v2Tip.Resources.MergedDictionaries.Add($v2Theme); $v2Tip.Resources.MergedDictionaries.Add($v2Styles)
        $v2Tip.Content = '긴 안내 글 ' * 80
        [void]$v2Tip.ApplyTemplate(); $v2Tip.Measure([System.Windows.Size]::new(800, 800))
        Assert-Wt 'WPF 2판: 앱 기본 툴팁은 12/16·여백 8/6·최대 320·400/100ms, 그림자 없음' ($v2Tip.Style -eq $v2Styles[[System.Windows.Controls.ToolTip]] -and
            $v2Tip.FontSize -eq 12 -and $v2Tip.Padding -eq [System.Windows.Thickness]::new(8, 6, 8, 6) -and $v2Tip.MaxWidth -eq 320 -and $v2Tip.DesiredSize.Width -le 320 -and
            -not $v2Tip.HasDropShadow -and $null -eq $v2Tip.Effect -and [System.Windows.Controls.ToolTipService]::GetInitialShowDelay($v2Input) -eq 400 -and [System.Windows.Controls.ToolTipService]::GetBetweenShowDelay($v2Input) -eq 100 -and
            [System.Windows.Controls.ToolTipService]::GetInitialShowDelay([System.Windows.Documents.Hyperlink]::new()) -eq 400)
        Assert-Wt 'WPF 2판: 메모 본문·제목 줄 높이와 치수 자원' ($v2Theme['F.Memo.Body'] -eq 15 -and $v2Theme['F.Memo.Body.LineHeight'] -eq 24 -and $v2Theme['F.Memo.H2.LineHeight'] -eq 26 -and $v2Theme['F.Memo.H6.LineHeight'] -eq 22 -and
            $v2Theme['F.Radius.Control'].TopLeft -eq 4 -and $v2Theme['F.Radius.Overlay'].TopLeft -eq 8 -and $v2Theme['F.Line.Focus'] -eq 2)
        Set-WtSetting 'theme.accent' 'teal'
        Assert-Wt 'WPF 2판: 강조색 변경을 기존 사전에 즉시 반영하고 면은 유지' ($v2Theme['B.Accent'].Color.ToString() -ceq '#FF0B6B69' -and $v2Theme['B.Bg.Canvas'].Color.ToString() -ceq '#FFF3F4F6')
        Set-WtSetting 'theme.accent' 'blue'
        $v2ThemeCard = & (Get-Module Pages) { New-WtThemeCard }
        function Get-WtTestThemeChoices($Element) {
            if ($Element -is [System.Windows.Controls.RadioButton] -and $Element.GroupName -ceq 'WtTheme') { $Element }
            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($Element)) {
                if ($child -is [System.Windows.DependencyObject]) { Get-WtTestThemeChoices $child }
            }
        }
        $themeChoices = @(Get-WtTestThemeChoices $v2ThemeCard)
        Assert-Wt 'WPF 2판: 설정은 강조색 제목·이름과 견본 5개, 설명 줄 없음' ($themeChoices.Count -eq 5 -and ($themeChoices.Content -join ',') -ceq '파랑,분홍,청록,보라,회색' -and
            @(Get-WtTestTexts $v2ThemeCard) -contains '강조색' -and $v2ThemeCard.Child.Children[1].Children[0].Children.Count -eq 1)
        foreach ($choice in $themeChoices) { $choice.IsChecked = $true }
        Assert-Wt 'WPF 2판: 설정의 강조색 선택이 새 키·현재 사전에 반영' ((Get-WtSetting 'theme.accent') -ceq 'gray' -and $v2Theme['B.Accent'].Color.ToString() -ceq '#FF56606D')
        Set-WtSetting 'theme.accent' 'blue'
        $settingsView = New-WtSettingsPage
        $helpView = New-WtHelpPage
        $settingsTabs = $settingsView.Children[1]
        $helpTabs = $helpView.Children[1]
        Assert-Wt '설정 하위 탭 넷: 일반 · 업무시간 · 탭 · 데이터' (
            $settingsTabs -is [System.Windows.Controls.TabControl] -and ($settingsTabs.Items.Header -join ',') -ceq '일반,업무시간,탭,데이터')
        Assert-Wt '도움말 하위 탭 셋: 단축키 · 탭 · 정보' (
            $helpTabs -is [System.Windows.Controls.TabControl] -and ($helpTabs.Items.Header -join ',') -ceq '단축키,탭,정보')
        $settingsView.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
        $settingsView.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
        $settingsView.Measure([System.Windows.Size]::new(1048, 600))
        $settingsView.Arrange([System.Windows.Rect]::new(0, 0, 1048, 600))
        Assert-Wt '설정 하위 탭: 공통 Tab 스타일 · 높이 36 · 선택 위 선 2' (
            $settingsTabs.Items[0].MinHeight -eq 36 -and $settingsTabs.Items[0].Template -eq (Get-WtStyleDictionary)['Tab'].Setters.Where({ $_.Property.Name -eq 'Template' })[0].Value)
        $helpTexts = @(Get-WtTestTexts $helpView)
        Assert-Wt '도움말: 키 · 하는 일 두 열 · Ctrl+Shift+B · 앱 이름과 데이터 폴더' (
            $helpTexts -contains '키' -and $helpTexts -contains '하는 일' -and $helpTexts -contains 'Ctrl + Shift + B' -and
            $helpTexts -contains 'WorkTool' -and $helpTexts -contains (Get-WtDataRoot))
        $v2Source = [System.IO.File]::ReadAllText((Join-Path $root 'core/Ui.psm1')) + [System.IO.File]::ReadAllText((Join-Path $root 'core/Theme.psm1'))
        Assert-Wt 'WPF 2판: 효과·그라데이션·애니메이션·둥근 안쪽 Clip 없음' ($v2Source -notmatch 'DropShadowEffect|BlurEffect|(?:Linear|Radial)GradientBrush|<Storyboard|<(?:Double|Color|Thickness|Object)Animation[ >]|ClipToBounds="True"|<[^>]*\.Clip>')

        $sample = $md + @'


```mermaid
flowchart TD
    A --> B{x}
    B -->|y| C
```

```mermaid
sequenceDiagram
    A->>B: hi
```

```mermaid
pie
```
'@
        $view = New-WtMarkdownView -Scroll -OnLink { param($l) $true }
        Set-WtMarkdownText $view $sample
        Assert-Wt 'WPF: 마크다운을 오류 없이 그린다' (-not $view.Tag.Error -and $view.Document.Blocks.Count -ge 12) "$($view.Tag.Error)"
        $figs = @($view.Document.Blocks | Where-Object { $_ -is [System.Windows.Documents.BlockUIContainer] -and $_.Child -is [System.Windows.Controls.Border] })
        Assert-Wt 'WPF: Mermaid 2개는 그림, 모르는 종류는 코드 블록' ($figs.Count -eq 2 -and $view.Tag.Remeasure)
        Assert-Wt 'WPF: 제목 · 각주 자리' ($view.Tag.Anchors.ContainsKey('제목굵게') -and $view.Tag.Anchors.ContainsKey('fn1'))

        # 파일 링크 아이콘: 폴더처럼 보이면 폴더, 아니면 문서. 툴팁은 Windows 모양 전체 경로. 웹 · 위키 링크에는 붙이지 않는다
        $linkView = New-WtMarkdownView
        Set-WtMarkdownText $linkView '[문서](<C:/a b/c.txt>) [공유](<//srv/share/x>) [웹](https://example.com) [[위키]]'
        $hl = @($linkView.Document.Blocks.FirstBlock.Inlines | Where-Object { $_ -is [System.Windows.Documents.Hyperlink] })
        $firstText = @($hl | ForEach-Object { $_.Inlines.FirstInline.Text })
        Assert-Wt 'WPF: 파일 링크 앞 아이콘 (문서 · 폴더) · 툴팁 경로, 웹 · 위키 링크는 아이콘 없음' ($hl.Count -eq 4 -and
            $firstText[0] -eq [string][char]0xE8A5 -and $firstText[1] -eq [string][char]0xE8B7 -and $firstText[2] -eq '웹' -and $firstText[3] -eq '위키' -and
            $hl[0].ToolTip -eq 'C:\a b\c.txt' -and $hl[1].ToolTip -eq '\\srv\share\x') ($firstText -join ',')

        # 할 일 누르기: -OnTask가 있으면 체크 표시를 Hyperlink로 감싸고, 누르면 그 항목의 원문 줄 번호로 부른다
        $global:taskLines = [System.Collections.Generic.List[int]]::new()
        $taskView = New-WtMarkdownView -OnTask { param($line) $global:taskLines.Add($line) }
        Set-WtMarkdownText $taskView "# 할 일`n`n- [ ] 첫째`n- [x] 둘째`n  - [ ] 안쪽`n- 그냥 항목"
        $taskLinks = [System.Collections.Generic.List[object]]::new()
        $walkDoc = {
            param($blocks)
            foreach ($b in $blocks) {
                if ($b -is [System.Windows.Documents.List]) { foreach ($li in $b.ListItems) { & $walkDoc $li.Blocks } }
                elseif ($b -is [System.Windows.Documents.Section]) { & $walkDoc $b.Blocks }
                elseif ($b -is [System.Windows.Documents.Paragraph]) { foreach ($i in $b.Inlines) { if ($i -is [System.Windows.Documents.Hyperlink] -and $i.ToolTip -eq '완료 표시 / 해제') { $taskLinks.Add($i) } } }
            }
        }
        & $walkDoc $taskView.Document.Blocks
        foreach ($h in $taskLinks) { $h.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Documents.Hyperlink]::ClickEvent)) }
        Assert-Wt 'WPF: 할 일 체크 표시를 누르면 원문 줄 번호로 부른다 (손 모양 커서)' (($global:taskLines -join ',') -eq '3,4,5' -and $taskLinks[0].Cursor -eq [System.Windows.Input.Cursors]::Hand) ($global:taskLines -join ',')
        $plainTask = New-WtMarkdownView
        Set-WtMarkdownText $plainTask '- [ ] 하나'
        $firstInline = $plainTask.Document.Blocks.FirstBlock.ListItems.FirstListItem.Blocks.FirstBlock.Inlines.FirstInline
        Assert-Wt 'WPF: -OnTask가 없으면 체크 표시는 누를 수 없다' ($firstInline -is [System.Windows.Documents.Run] -and $firstInline.Text -eq [string][char]0xE739)

        # 파일 · 폴더 열기 (core\Work.psm1 Open-WtPath): 있는지 · 폴더인지 확인과 셸 열기 모두 화면 밖에서 한다.
        # 속성 읽기와 셸 호출 두 곳만 가짜로 바꾼다 (실제로 열지 않고 할 일만 기록). 여는 작업 · 취소 확인 · 넘김 표시는 그대로 돈다.
        # 느린 경로는 \\srv\ 경로의 속성 읽기를 문 앞에서 멈춰 흉내 낸다
        Assert-Wt 'Open-WtPath: 여는 방법 (폴더 · 열 수 있는 종류는 열고, 그 밖은 탐색기에서 선택 · 없음)' (
            (Get-WtPathOpenAction 16 'C:\d' $false @('.txt')) -eq 'open' -and (Get-WtPathOpenAction 32 'C:\a.txt' $false @('.txt')) -eq 'open' -and
            (Get-WtPathOpenAction 32 'C:\run.exe' $false @('.txt')) -eq 'reveal' -and (Get-WtPathOpenAction -1 'C:\x' $false @()) -eq 'missing' -and
            (Get-WtPathOpenAction 32 'C:\run.exe' $false @()) -eq 'open' -and (Get-WtPathOpenAction 32 'C:\a.txt' $true @()) -eq 'reveal')
        $workModule = Get-Module Work
        $openLog = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
        [AppDomain]::CurrentDomain.SetData('WtTestOpen', @{ Log = $openLog; Attr = @{ 'C:\wt\a.txt' = 32; 'C:\wt\dir' = 16; 'C:\wt\run.exe' = 32; 'C:\wt\none.txt' = -1; '\\srv\share\slow.xlsx' = 32 } })
        & $workModule {
            $script:testSaid = [System.Collections.Generic.List[string]]::new()
            function script:Show-WtMessage { param($Text, $Title, $Icon) $script:testSaid.Add("msg:$(($Text -split "`n")[0])") }
            $script:testRealAttr = ${function:Get-WtPathAttributes}; $script:testRealShell = ${function:Invoke-WtShellStart}
            function script:Get-WtPathAttributes([string]$Path) {
                $t = [AppDomain]::CurrentDomain.GetData('WtTestOpen')
                if ($Path -like '\\srv\*') { $g = [AppDomain]::CurrentDomain.GetData('WtTestGate'); [void]$g.Entered.Set(); [void]$g.Gate.WaitOne() }
                if ($t.Attr.ContainsKey($Path)) { [int]$t.Attr[$Path] } else { -1 }
            }
            function script:Invoke-WtShellStart($Start, [string]$Action) {
                $t = [AppDomain]::CurrentDomain.GetData('WtTestOpen')
                $target = if ($Action -eq 'reveal') { $Start.Arguments -replace '^/select,"(.*)"$', '$1' } else { $Start.FileName }
                # 셸이 늦게 여는 경우: late가 들어간 경로는 문 앞에서 기다린 뒤에 「연다」
                if ($target -like '*late*') { $g = [AppDomain]::CurrentDomain.GetData('WtTestGate'); [void]$g.Entered.Set(); [void]$g.Gate.WaitOne() }
                [void]$t.Log.Add("${Action}:$target")
            }
        }
        $fakeState = @{ BaseDir = ''; OnLink = $null; Anchors = @{} }
        $openLink = { param($target) Invoke-WtMarkdownLink $fakeState @{ Kind = 'file'; Target = $target; Text = 'x' } }
        $gate = New-WtTestGate
        try {
            & $openLink 'C:/wt/a.txt'; & $openLink 'C:/wt/dir'; & $openLink 'C:/wt/run.exe'; & $openLink 'C:/wt/none.txt'
            [void](Wait-WtWork -All -Milliseconds 10000)
            $said = @(& $workModule { $script:testSaid })
            Assert-Wt 'WPF 파일 링크: 확인 결과대로 열기 (파일 · 폴더 · 실행 파일은 탐색기에서 선택 · 없음은 알림)' (
                (@($openLog | Sort-Object) -join '|') -eq 'open:C:\wt\a.txt|open:C:\wt\dir|reveal:C:\wt\run.exe' -and ($said -join '|') -eq 'msg:파일을 찾지 못했습니다.') "$(@($openLog) -join '|') / $($said -join '|')"
            Assert-Wt 'WPF 파일 링크: 끝나면 작업 · 커서를 정리한다' ((Get-WtWorkInfo).Running -eq 0 -and $null -eq [System.Windows.Input.Mouse]::OverrideCursor) (
                & $workModule { ($script:jobs | ForEach-Object { "작업 $($_.Id): $($_.Key) / $($_.State) / $($_.Context.Path) / 완료=$($_.Handle.IsCompleted)" }) -join '; ' })

            # 응답 없는 공유: 같은 경로는 겹쳐 확인하지 않고, 확인 중에는 AppStarting 커서. 시간이 지나면 알리고 커서를 돌려놓으며,
            # 같은 공유를 또 누르면 새로 묻지 않고 바로 알린다. 늦게 온 답으로는 열지 않는다
            & $workModule { $script:testSaid.Clear(); $script:openTimeoutMs = 300 }
            $openLog.Clear()
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            & $openLink '//srv/share/slow.xlsx'; & $openLink '//srv/share/slow.xlsx'
            $clickMs = $watch.ElapsedMilliseconds
            $pending = (Get-WtWorkInfo).Running
            $waitCursor = [System.Windows.Input.Mouse]::OverrideCursor
            Start-Sleep -Milliseconds 400
            Update-WtWork
            $afterTimeout = @{ Said = @(& $workModule { $script:testSaid }); Cursor = [System.Windows.Input.Mouse]::OverrideCursor }
            & $openLink '//srv/share/other.txt'
            $quick = @(& $workModule { $script:testSaid })
            Remove-WtTestGate $gate; $gate = $null
            $timeoutText = 'msg:경로가 응답하지 않습니다. 네트워크 연결이나 공유 폴더를 확인한 뒤 다시 누르세요. 늦게 답이 와도 열지 않습니다.'
            Assert-Wt "WPF 파일 링크: 응답 없는 공유도 누르면 바로 돌아오고(${clickMs}ms), 같은 링크는 겹쳐 확인하지 않으며 확인 중에는 AppStarting 커서" (
                $clickMs -lt 500 -and $pending -eq 1 -and $waitCursor -eq [System.Windows.Input.Cursors]::AppStarting) "(작업 $pending · 커서 $waitCursor)"
            Assert-Wt 'WPF 파일 링크: 시간 초과면 알리고 커서를 돌려놓으며, 같은 공유를 또 누르면 바로 알리고, 늦게 온 답으로는 열지 않는다' (
                ($afterTimeout.Said -join '|') -eq $timeoutText -and $null -eq $afterTimeout.Cursor -and ($quick -join '|') -eq "$timeoutText|$timeoutText" -and
                $openLog.Count -eq 0 -and (Get-WtWorkInfo).Abandoned -eq 0) "$($quick -join ' / ') · 열기 $($openLog.Count)"

            # 확인은 끝나 셸에 넘겼는데 셸이 늦게 여는 경우: 「열지 않는다」고 하지 않고, 늦게 열릴 수 있다고 사실대로 알린다
            & $workModule { $script:testSaid.Clear() }
            $openLog.Clear()
            $gate = New-WtTestGate
            $lateFile = 'C:\wt\late.txt'
            ([AppDomain]::CurrentDomain.GetData('WtTestOpen')).Attr[$lateFile] = 32
            Open-WtPath $lateFile
            $handed = $gate.Entered.WaitOne(5000)
            Start-Sleep -Milliseconds 400
            Update-WtWork
            $lateSaid = @(& $workModule { $script:testSaid })
            Remove-WtTestGate $gate; $gate = $null
            Assert-Wt '열기: 셸에 넘긴 뒤 시간이 지나면 늦게 열릴 수 있다고 알리고, 실제로 늦게 열린다 (넘기기 전이면 위처럼 열지 않는다)' (
                $handed -and ($lateSaid -join '|') -eq 'msg:열기를 프로그램에 넘겼지만 응답이 늦습니다. 응답이 오면 늦게 열릴 수 있습니다.' -and
                (@($openLog) -join '|') -eq "open:$lateFile" -and (Get-WtWorkInfo).Abandoned -eq 0) "$($lateSaid -join ' / ') · 열기 $(@($openLog) -join '|')"

            # 실제 여는 작업: 없는 파일은 열지 않고 알린다 (있는 파일은 실제로 열려서 검사하지 않는다)
            . $workModule { $script:testSaid.Clear(); $script:openTimeoutMs = 5000; ${function:Get-WtPathAttributes} = $script:testRealAttr; ${function:Invoke-WtShellStart} = $script:testRealShell }   # 점 소싱: 모듈 범위에 되돌린다
            Open-WtPath (Join-Path $test.Root '없는 파일.txt') -NotFound '없는 파일'
            [void](Wait-WtWork -All -Milliseconds 10000)
            Assert-Wt 'WPF 파일 링크: 실제 확인 작업도 없는 파일은 알린다' ((@(& $workModule { $script:testSaid }) -join '|') -eq 'msg:없는 파일')
        } finally {
            if ($gate) { Remove-WtTestGate $gate }
            [AppDomain]::CurrentDomain.SetData('WtTestOpen', $null)
            . $workModule {
                $script:openTimeoutMs = 5000; ${function:Get-WtPathAttributes} = $script:testRealAttr; ${function:Invoke-WtShellStart} = $script:testRealShell
                Remove-Item -LiteralPath 'Function:\Show-WtMessage' -ErrorAction SilentlyContinue
            }
        }

        # 그림: 화면 밖에서 읽는다. 로컬 그림은 그리기 안에서 들어가고, 없는 그림은 이름만, 응답 없는 경로는 기다리지 않고 「읽는 중」
        $png = Join-Path $test.Root '작은 그림.png'
        $pixels = [System.Windows.Media.Imaging.BitmapSource]::Create(2, 2, 96, 96, [System.Windows.Media.PixelFormats]::Bgra32, $null, [byte[]]::new(16), 8)
        $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
        $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($pixels))
        $stream = [System.IO.File]::Create($png); try { $encoder.Save($stream) } finally { $stream.Dispose() }
        $imgView = New-WtMarkdownView
        Set-WtMarkdownText $imgView "![작은 그림](<$($png.Replace('\', '/'))>)`n`n![없는 그림](<$((Join-Path $test.Root '없음.png').Replace('\', '/'))>)"
        $imgBoxes = @($imgView.Document.Blocks | Where-Object { $_ -is [System.Windows.Documents.BlockUIContainer] } | ForEach-Object { $_.Child })
        Assert-Wt 'WPF 그림: 로컬 그림은 그리기 안에서 들어가고, 없는 그림은 이름과 이유를 둔다' (
            $imgBoxes.Count -eq 2 -and $imgBoxes[0].Child -is [System.Windows.Controls.Image] -and $imgBoxes[0].Child.Source.PixelWidth -eq 2 -and $imgBoxes[0].Child.ToolTip -eq '작은 그림' -and
            $imgBoxes[1].Child -is [System.Windows.Controls.TextBlock] -and [string]$imgBoxes[1].ToolTip -like '그림 파일을 찾지 못했습니다*') "($(@($imgBoxes | ForEach-Object { $_.Child.GetType().Name }) -join ','))"
        $mdModule2 = Get-Module Markdown
        # 그림이 많아도 한 번에 읽는 수를 묶고(차례 대기), 차례대로 모두 들어온다
        $manyView = New-WtMarkdownView
        Set-WtMarkdownText $manyView ((1..20 | ForEach-Object { "![그림 $_](<$($png.Replace('\', '/'))>)" }) -join "`n`n")
        $peak = & $mdModule2 { $script:imageActive.Count }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ((& $mdModule2 { $script:imageQueue.Count + $script:imageActive.Count }) -and $watch.ElapsedMilliseconds -lt 10000) { [void](Wait-WtWork -All -Milliseconds 200) }
        $manyBoxes = @($manyView.Document.Blocks | Where-Object { $_ -is [System.Windows.Documents.BlockUIContainer] } | ForEach-Object { $_.Child })
        Assert-Wt "WPF 그림: 그림이 많아도 한 번에 6개까지만 읽고 차례대로 모두 들어온다 (그린 직후 읽는 중 $peak)" (
            $manyBoxes.Count -eq 20 -and -not @($manyBoxes | Where-Object { $_.Child -isnot [System.Windows.Controls.Image] }).Count -and $peak -le 6)
        $gate = New-WtTestGate
        try {
            # 그림 읽기가 문 앞에서 멈춘다 (문이 열려도 디스크 · 네트워크에는 가지 않는다)
            & $mdModule2 {
                $script:testRealImage = $script:imageCall
                $script:imageCall = { param($path) New-WtCall ([AppDomain]::CurrentDomain.GetData('WtTestGate').Gate) WaitOne }
            }
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            Set-WtMarkdownText $imgView '![느린 그림](<//srv/img/slow.png>)'
            $drawMs = $watch.ElapsedMilliseconds
            $slowBox = @($imgView.Document.Blocks | Where-Object { $_ -is [System.Windows.Documents.BlockUIContainer] } | ForEach-Object { $_.Child })[0]
            Assert-Wt "WPF 그림: 응답 없는 경로의 그림도 그리기는 잠깐만 기다리고 「읽는 중」으로 둔다 (${drawMs}ms)" (
                $drawMs -lt 1000 -and $slowBox.Child -is [System.Windows.Controls.TextBlock] -and [string]$slowBox.ToolTip -like '그림을 읽는 중입니다*')
        } finally {
            & $mdModule2 { $script:imageCall = $script:testRealImage }
            Remove-WtTestGate $gate
        }

        # 창 단축키 넘기기: 등록한 요소(또는 그 안)에 포커스가 있을 때만 그 키를 셸이 처리하지 않는다
        $kp = [System.Windows.Controls.StackPanel]::new()
        $owned = [System.Windows.Controls.TextBox]::new()
        $plain = [System.Windows.Controls.TextBox]::new()
        $inner = [System.Windows.Controls.Border]::new()
        $deep = [System.Windows.Controls.TextBox]::new()
        $inner.Child = $deep
        foreach ($c in $owned, $plain, $inner) { [void]$kp.Children.Add($c) }
        Register-WtKeyOwner $owned 'Ctrl+B'
        Register-WtKeyOwner $inner 'Ctrl+B', 'Ctrl+I'
        $k1 = (Test-WtKeyOwned 'Ctrl+B' $owned) -and -not (Test-WtKeyOwned 'Ctrl+I' $owned)
        $k2 = -not (Test-WtKeyOwned 'Ctrl+B' $plain)
        $k3 = (Test-WtKeyOwned 'Ctrl+B' $deep) -and (Test-WtKeyOwned 'Ctrl+I' $deep) -and -not (Test-WtKeyOwned 'Ctrl+B' $null)
        Assert-Wt 'WPF 단축키 넘기기: 등록한 칸 · 그 안에서만 셸이 키를 넘긴다' ($k1 -and $k2 -and $k3) "($k1 · $k2 · $k3)"

        # 창 짜임은 가짜 등록·가짜 보조 칸으로만 본다. 실제 탭은 아래 탭 모아 보기/각 탭 검사에서 맡는다.
        $shellChecks = & (Get-Module Shell) {
            $saved = @{ Window = $script:window; Ui = $script:ui; Current = $script:current; Views = $script:views
                Buttons = $script:navButtons; Groups = $script:navGroups; Collapsed = Get-WtSetting 'nav.collapsed' }
            $savedAddons = & (Get-Module Addons) { ,$script:addons.ToArray() }
            try {
                & (Get-Module Addons) { $script:addons.Clear() }
                Register-WtAddon -Id 'shell-late' -Title '뒤' -Group '첫 묶음' -Order 30 -Badge { $null } -NewView { New-WtText '빈 화면' } -OnOpen { param($OpenArgs) $script:testOpenArgs = $OpenArgs }
                Register-WtAddon -Id 'shell-dot' -Title '점' -Group '다음 묶음' -Order 20 -Badge { 'dot' } -BadgeToolTip '가짜 점' -NewView { New-WtText '점 화면' }
                Register-WtAddon -Id 'shell-count' -Title '수' -Group '첫 묶음' -Order 10 -Badge { 7 } -NewView {
                    New-WtSidePanel -Content (New-WtText '보조 내용') -Key 'test.shell.side' -Title '보조' -Width 308
                }
                Register-WtAddon -Id 'shell-error' -Title '실패' -Group '다음 묶음' -Order 40 -Badge { throw '배지 실패' } -NewView { New-WtText '계속 열림' }
                $script:window = ConvertFrom-WtXaml $script:shellXaml
                $script:window.Resources.MergedDictionaries.Add((New-WtThemeDictionary))
                $script:window.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
                $script:ui = Get-WtNamedElements $script:window $script:shellXaml
                $script:current = $null; $script:views = @{}
                $script:testOpenArgs = $null
                Open-WtPage -Id 'shell-late' -Args @{ Key = '받은 키'; Date = [datetime]'2026-11-03'; Id = '선택 줄' }
                $openArgsOk = $script:current -ceq 'shell-late' -and $script:testOpenArgs.Key -ceq '받은 키' -and $script:testOpenArgs.Id -ceq '선택 줄' -and $script:testOpenArgs.Date -eq [datetime]'2026-11-03'
                $script:testOpenArgs = $null
                Set-WtSetting 'addons.disabled' @('shell-late')
                Open-WtPage -Id 'shell-late' -Args @{ Key = '무시' }
                Open-WtPage -Id 'shell-no-such-page' -Args @{ Key = '무시' }
                $openArgsOk = $openArgsOk -and $null -eq $script:testOpenArgs
                Set-WtSetting 'addons.disabled' @()
                Set-WtSetting 'nav.collapsed' $false
                Update-WtNav
                $groups = (@(Get-WtNavGroups) | ForEach-Object { "$($_.Name):$($_.Items.Id -join ',')" }) -join ';'
                $badge = $script:navButtons
                $badgeOk = $badge['shell-count'].Value -ceq '7' -and $badge['shell-dot'].Value -ceq 'dot' -and
                    $null -eq $badge['shell-late'].Value -and $null -eq $badge['shell-error'].Value -and $badge['shell-count'].Count.Visibility -eq 'Visible' -and
                    $badge['shell-dot'].Dot.Visibility -eq 'Visible' -and $badge['shell-dot'].Dot.ToolTip -eq '가짜 점'
                Select-WtPage 'shell-error'
                $failureIsolated = $script:current -eq 'shell-error' -and $badge['shell-count'].Value -eq '7'
                Start-WtNavBadgeTimer
                $minute = $script:badgeTimer.IsEnabled -and $script:badgeTimer.Interval.TotalSeconds -eq 60
                $script:badgeTimer.Stop()
                Switch-WtCollapsed
                $collapsedNav = $script:ui.NavBorder.Width -eq 48 -and $script:ui.FooterPanel.Orientation -eq 'Vertical' -and
                    $badge['shell-dot'].IconDot.Visibility -eq 'Visible' -and $badge['shell-count'].Count.Visibility -eq 'Collapsed' -and
                    $badge['shell-count'].Button.ToolTip -eq '수' -and @($script:navGroups | Where-Object Visibility -ne 'Collapsed').Count -eq 0
                Switch-WtCollapsed
                $expandedNav = $script:ui.NavBorder.Width -eq 200 -and $script:ui.FooterPanel.Orientation -eq 'Horizontal' -and
                    $script:ui.HelpButton.Width -eq 32 -and $script:ui.HelpButton.Margin.Right -eq 8
                Select-WtPage 'shell-count'
                $panel = @(Get-WtSidePanels $script:ui.PageHost.Content)[0]
                $cycle = @(foreach ($n in 1..4) { Switch-WtPanelCycle; "$([bool](Get-WtSetting 'nav.collapsed'))/$($panel.Collapsed)" }) -join ','
                # 실제 접기 단추·열기 단추도 같은 저장 통로를 쓴다.
                $panel.Collapse.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
                $savedClosed = [bool](Get-WtSetting 'test.shell.side') -and $panel.Root.Width -eq 28 -and $panel.Rail.Visibility -eq 'Visible'
                $copy = New-WtSidePanel -Content (New-WtText '다시 만듦') -Key 'test.shell.side' -Title '복원'
                $restored = $copy.Width -eq 28
                $panel.Open.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
                $opened = -not [bool](Get-WtSetting 'test.shell.side') -and $panel.Root.Width -eq 308
                Select-WtPage 'shell-late'
                $onlyNav = @(foreach ($n in 1..2) { Switch-WtPanelCycle; [bool](Get-WtSetting 'nav.collapsed') }) -join ','
                $script:window.Width = 1100
                $small = New-WtSidePanel -Content (New-WtText '좁은 창') -Key 'test.shell.narrow' -Title '좁은 보조' -Width 280
                $smallPanel = @(Get-WtSidePanels $small)[0]
                $narrowStart = $small.Width -eq 28 -and $smallPanel.Collapsed -and -not [bool](Get-WtSetting 'test.shell.narrow')
                Set-WtSidePanelCollapsed $smallPanel $false
                $hostGrid = [System.Windows.Controls.Grid]::new()
                $hostGrid.ColumnDefinitions.Add([System.Windows.Controls.ColumnDefinition]::new())
                $auto = [System.Windows.Controls.ColumnDefinition]::new(); $auto.Width = [System.Windows.GridLength]::Auto
                $hostGrid.ColumnDefinitions.Add($auto)
                $main = [System.Windows.Controls.Border]::new()
                [void]$hostGrid.Children.Add($main)
                [System.Windows.Controls.Grid]::SetColumn($small, 1); [void]$hostGrid.Children.Add($small)
                $hostGrid.Measure([System.Windows.Size]::new(600,300)); $hostGrid.Arrange([System.Windows.Rect]::new(0,0,600,300))
                $overlay = $small.Width -eq 28 -and $smallPanel.Expanded.ActualWidth -eq 280 -and $main.ActualWidth -eq 572 -and
                    $smallPanel.Expanded.TranslatePoint([System.Windows.Point]::new(0,0), $small).X -eq -252 -and $null -eq $smallPanel.Expanded.Effect
                Set-WtSidePanelCollapsed $smallPanel $true
                $script:window.Width = 1280; Update-WtSidePanel $smallPanel
                $wideRestore = $small.Width -eq 28 -and $smallPanel.Collapsed
                Set-WtSidePanelCollapsed $smallPanel $false
                $script:window.Width = 1100; Update-WtSidePanel $smallPanel
                $script:window.Width = 1280; Update-WtSidePanel $smallPanel
                $wideRestore = $wideRestore -and -not $smallPanel.Collapsed -and $small.Width -eq 280
                $left = New-WtSidePanel -Content (New-WtText '목록') -Side Left -Key 'test.shell.left' -Title '목록' -Width 220 -Independent
                $leftPanel = @(Get-WtSidePanels $left)[0]
                $leftOk = $left.Width -eq 220 -and $leftPanel.CollapseGlyph.Text -eq [string][char]0xE76B -and
                    [System.Windows.Controls.DockPanel]::GetDock($leftPanel.Collapse) -eq 'Right' -and $leftPanel.Independent
                # 화면을 바꾼 직후에도 배지를 다시 평가한다.
                $badge['shell-count'].Addon.Badge = { 0 }
                Select-WtPage 'shell-dot'
                $refresh = $badge['shell-count'].Value -ceq '0'
                $reserved = [System.Windows.Controls.TextBox]::new()
                Register-WtKeyOwner $reserved 'Ctrl+B','Ctrl+Shift+B'
                $hoursSnapshot = Read-WtJsonFile (Get-WtSettingsPath)
                try {
                    $missingWorkStart = [ordered]@{ schema = 1; values = @{ 'work.end' = '18:00' } }
                    Write-WtJsonFile (Get-WtSettingsPath) $missingWorkStart
                    Initialize-WtSettings
                    Show-WtFirstWorkSetup $script:window 'shell-late'
                    $firstSetup = & (Get-Module Pages) { $script:firstWorkSetup }
                    $shown = $null -ne $firstSetup -and $firstSetup.Grid.Children.Contains($firstSetup.Overlay) -and
                        $firstSetup.Form.Boxes['work.start'].Text -ceq '09:00'
                    $firstSetup.Form.Boxes['work.end'].Text = '08:00'
                    $firstSetup.Form.Start.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
                    $invalid = (Test-WtWorkSetupRequired) -and $firstSetup.Form.Errors['work.end'].Text -ceq '끝 시각은 시작 시각보다 늦어야 합니다.' -and
                        [System.Windows.Controls.Validation]::GetHasError($firstSetup.Form.Boxes['work.end'])
                    $firstSetup.Form.Boxes['work.end'].Text = '18:00'
                    $firstSetup.Form.Boxes['work.start'].Text = '08:30'
                    $firstSetup.Form.Start.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
                    Initialize-WtSettings
                    $started = -not (Test-WtWorkSetupRequired) -and (Get-WtSetting 'work.start') -ceq '08:30' -and $script:current -ceq 'shell-late' -and
                        -not $firstSetup.Grid.Children.Contains($firstSetup.Overlay)
                    Show-WtFirstWorkSetup $script:window 'shell-late'
                    $onlyMissing = $null -eq (& (Get-Module Pages) { $script:firstWorkSetup })
                    Write-WtJsonFile (Get-WtSettingsPath) $missingWorkStart
                    Initialize-WtSettings
                    Show-WtFirstWorkSetup $script:window 'shell-late'
                    $escSetup = & (Get-Module Pages) { $script:firstWorkSetup }
                    $escSetup.Form.Boxes['work.start'].Text = '07:00'
                    $escapeEvent = [pscustomobject]@{ Key = 'Escape'; Handled = $false }
                    $escaped = Invoke-WtWorkSetupKey $escapeEvent
                    Initialize-WtSettings
                    $escaped = $escaped -and $escapeEvent.Handled -and -not (Test-WtWorkSetupRequired) -and
                        (Get-WtSetting 'work.start') -ceq '09:00' -and $script:current -ceq 'shell-late'
                    Write-WtJsonFile (Get-WtSettingsPath) $missingWorkStart
                    Initialize-WtSettings
                    Show-WtFirstWorkSetup $script:window 'shell-late'
                    $closed = Close-WtFirstWorkSetup -UseDefaults
                    Initialize-WtSettings
                    $closed = $closed -and -not (Test-WtWorkSetupRequired) -and (Get-WtSetting 'work.start') -ceq '09:00'
                } finally {
                    [void](Close-WtFirstWorkSetup -UseDefaults)
                    Write-WtJsonFile (Get-WtSettingsPath) $hoursSnapshot
                    Initialize-WtSettings
                }
                [pscustomobject]@{ OpenArgs = $openArgsOk; Groups = $groups; Badge = $badgeOk; Isolated = $failureIsolated; Minute = $minute; Refresh = $refresh
                    CollapsedNav = $collapsedNav; ExpandedNav = $expandedNav; Cycle = $cycle; OnlyNav = $onlyNav
                    Saved = $savedClosed -and $restored -and $opened; Narrow = $narrowStart; Overlay = $overlay; Restore = $wideRestore; Left = $leftOk
                    Reserved = -not (Test-WtKeyOwned 'Ctrl+Shift+B' $reserved) -and (Test-WtKeyOwned 'Ctrl+B' $reserved)
                    FirstShown = $shown; FirstInvalid = $invalid; FirstStarted = $started; FirstOnlyMissing = $onlyMissing; FirstEscaped = $escaped; FirstClosed = $closed
                    Chrome = $script:window.MinWidth -eq 1024 -and $script:window.MinHeight -eq 640 -and $script:ui.TitleBar.Height -eq 32 }
            } finally {
                if ($script:badgeTimer) { $script:badgeTimer.Stop() }
                & (Get-Module Addons) { param($items) $script:addons.Clear(); foreach ($item in $items) { $script:addons.Add($item) } } $savedAddons
                $script:window = $saved.Window; $script:ui = $saved.Ui; $script:current = $saved.Current; $script:views = $saved.Views
                $script:navButtons = $saved.Buttons; $script:navGroups = $saved.Groups
                Set-WtSetting 'nav.collapsed' $saved.Collapsed
            }
        }
        Assert-Wt '창 짜임: 묶음·순서가 등록대로' ($shellChecks.Groups -eq '첫 묶음:shell-count,shell-late;다음 묶음:shell-dot,shell-error') $shellChecks.Groups
        Assert-Wt '탭 열기: 인자 전달 · 없는/꺼진 탭 무시 (가짜 탭)' $shellChecks.OpenArgs
        Assert-Wt '창 짜임: 숫자·점·없음·배지 실패 격리' ($shellChecks.Badge -and $shellChecks.Isolated)
        Assert-Wt '창 짜임: 탭 이동 때 재평가·분 타이머' ($shellChecks.Refresh -and $shellChecks.Minute)
        Assert-Wt '창 짜임: 메뉴 200/48·툴팁·아래 아이콘 가로/세로' ($shellChecks.CollapsedNav -and $shellChecks.ExpandedNav)
        Assert-Wt '창 짜임: 보조 칸 접기·설정 저장·다시 만들기' $shellChecks.Saved
        Assert-Wt '창 짜임: Ctrl+Shift+B 네 단계·없는 칸 건너뛰기' ($shellChecks.Cycle -eq 'False/True,True/True,False/True,False/False' -and $shellChecks.OnlyNav -eq 'True,False') "$($shellChecks.Cycle) / $($shellChecks.OnlyNav)"
        Assert-Wt '창 짜임: 1200 미만 레일 시작·겹쳐 열기·늘리면 저장 상태' ($shellChecks.Narrow -and $shellChecks.Overlay -and $shellChecks.Restore) "$($shellChecks.Narrow)/$($shellChecks.Overlay)/$($shellChecks.Restore)"
        Assert-Wt '창 짜임: 왼쪽 보조 칸·독립 접기' $shellChecks.Left
        Assert-Wt '창 짜임: 최소 크기·타이틀바·예약 단축키' ($shellChecks.Chrome -and $shellChecks.Reserved)
        Assert-Wt '첫 설정: work.start가 없을 때만 창 안에 기본값 입력을 연다' ($shellChecks.FirstShown -and $shellChecks.FirstOnlyMissing)
        Assert-Wt '첫 설정: 잘못된 시각은 칸 아래 오류 · 저장 거부' $shellChecks.FirstInvalid
        Assert-Wt '첫 설정: 시작은 입력값 저장 · 홈 복귀 · 다시 묻지 않음' $shellChecks.FirstStarted
        Assert-Wt '첫 설정: Esc는 기본값 저장 · 홈 복귀 · 다시 묻지 않음' $shellChecks.FirstEscaped
        Assert-Wt '첫 설정: 닫기도 기본값 저장 · 다시 묻지 않음' $shellChecks.FirstClosed

        # 도움말: 탭이 등록한 설명 · 카드를 모은다. 카드 하나가 실패해도 도움말은 연다
        Register-WtAddon -Id 'test-help' -Title '도움' -Order 50 -NewView { } -Help '가짜 탭 설명' -HelpCard { New-WtText '가짜 카드' 'T.Body' }
        Register-WtAddon -Id 'test-broken' -Title '고장' -Order 60 -NewView { } -HelpCard { throw '일부러 낸 오류' }
        $texts = @(Get-WtTestTexts (New-WtHelpPage))
        Assert-Wt 'WPF 도움말: 탭 설명 · 단축키 · 카드를 싣는다' ($texts -contains '가짜 탭 설명' -and $texts -contains '가짜 카드' -and $texts -contains '엑스 · 와이: 새로 고침')
        Assert-Wt 'WPF 도움말: 실패한 탭 카드는 알리고 나머지는 연다' (@($texts | Where-Object { $_ -like '고장 도움말을 만들지 못했습니다*' }).Count -eq 1)

        $shell = Get-Module Shell
        $help1 = & $shell { Get-WtPageView '_help' }
        $help2 = & $shell { Get-WtPageView '_help' }
        Assert-Wt 'WPF 도움말: 같은 조건이면 화면 재사용' ([object]::ReferenceEquals($help1.View, $help2.View))
        Register-WtAddon -Id 'test-help' -Title '도움' -Order 50 -NewView { } -Help '바뀐 가짜 설명'
        $help3 = & $shell { Get-WtPageView '_help' }
        Assert-Wt 'WPF 도움말: 같은 ID 재등록도 새 설명 반영' (-not [object]::ReferenceEquals($help2.View, $help3.View) -and (Get-WtTestTexts $help3.View) -contains '바뀐 가짜 설명')
        Set-WtSetting 'addons.disabled' @('test-help')
        $hiddenHelp = & $shell { Get-WtPageView '_help' }
        Assert-Wt 'WPF 도움말: 숨긴 탭 설명은 재진입 때 빠진다' ((Get-WtTestTexts $hiddenHelp.View) -notcontains '바뀐 가짜 설명')
        Set-WtSetting 'addons.disabled' @()
        $font = Get-WtSetting 'ui.fontScale'; Set-WtSetting 'ui.fontScale' 'l'
        $largeHelp = & $shell { Get-WtPageView '_help' }
        Assert-Wt 'WPF 도움말: 글자 크기 변경 시 다시 만든다' (-not [object]::ReferenceEquals($hiddenHelp.View, $largeHelp.View))
        Set-WtSetting 'ui.fontScale' $font
        $settings1 = & $shell { Get-WtPageView '_settings' }
        $settings2 = & $shell { Get-WtPageView '_settings' }
        Assert-Wt 'WPF 설정: 같은 조건이면 화면 재사용' ([object]::ReferenceEquals($settings1.View, $settings2.View))
        $close = Get-WtSetting 'window.closeToTray'; Set-WtSetting 'window.closeToTray' (-not $close)
        $settings3 = & $shell { Get-WtPageView '_settings' }
        Assert-Wt 'WPF 설정: 바뀐 설정은 재진입 때 다시 읽는다' (-not [object]::ReferenceEquals($settings2.View, $settings3.View))
        Set-WtSetting 'window.closeToTray' $close

        # 미리 만들기: WarmUp을 준 탭만 만든다. Full은 새로 고침까지, View는 화면만. 설정 · 도움말도 만들고, 이미 연 화면은 건너뛴다
        $global:warmCalls = @{ FullNew = 0; FullRefresh = 0; ViewNew = 0; ViewRefresh = 0; NoneNew = 0 }
        Register-WtAddon -Id 'test-warm-full' -Title '미리1' -Order 70 -WarmUp Full -NewView { $global:warmCalls.FullNew++; New-WtText '미리 만든 화면' } -Refresh { param($v) $global:warmCalls.FullRefresh++ }
        Register-WtAddon -Id 'test-warm-view' -Title '미리2' -Order 71 -WarmUp View -NewView { $global:warmCalls.ViewNew++; New-WtText '틀만' } -Refresh { param($v) $global:warmCalls.ViewRefresh++ }
        Register-WtAddon -Id 'test-warm-none' -Title '미리3' -Order 72 -NewView { $global:warmCalls.NoneNew++; New-WtText '안 함' }
        $warmOff = & (Get-Module Shell) {
            $script:warmEnabled = $false; $script:warmStarted = $false; $script:warmQueue = $null
            Start-WtWarmUp
            -not $script:warmStarted -and $null -eq $script:warmQueue
        }
        Assert-Wt '미리 만들기: 기본 실행은 예약하지 않는다' $warmOff
        $warm = & (Get-Module Shell) {
            $script:ui = @{ WarmHost = [System.Windows.Controls.ContentControl]::new() }
            $script:ui.WarmHost.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $script:ui.WarmHost.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
            $script:views = @{}; $script:current = 'test-a'
            $script:warmEnabled = $true; $script:warmStarted = $false; $script:exiting = $false
            $run = { Start-WtWarmUp; $script:warmTimer.Stop(); $n = 0; while ((Invoke-WtWarmUpStep) -and $n -lt 30) { $n++ } }
            & $run
            $first = @{ Views = @($script:views.Keys | Sort-Object); HostEmpty = $null -eq $script:ui.WarmHost.Content }
            $queue = $script:warmQueue
            & $run
            $first.Once = [object]::ReferenceEquals($queue, $script:warmQueue)
            $first
        }
        Assert-Wt '미리 만들기: WarmUp을 준 탭만 만들고(Full은 새로 고침까지), 설정 · 도움말도 만든다' (
            ($warm.Views -join ',') -eq '_help,_settings,test-warm-full,test-warm-view' -and $warm.HostEmpty -and
            $global:warmCalls.FullNew -eq 1 -and $global:warmCalls.FullRefresh -eq 1 -and $global:warmCalls.ViewNew -eq 1 -and $global:warmCalls.ViewRefresh -eq 0 -and $global:warmCalls.NoneNew -eq 0) (
            "($($warm.Views -join ',') · $(($global:warmCalls.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' '))")
        Assert-Wt '미리 만들기: 같은 세션에서 다시 예약하지 않는다' $warm.Once
        $warmGates = & (Get-Module Shell) {
            $oldWindow = $script:window
            $oldSelecting = $script:selecting
            try {
                $script:selecting = $false
                $script:window = [pscustomobject]@{ IsVisible = $true; IsEnabled = $true; IsActive = $false; WindowState = [System.Windows.WindowState]::Normal }
                $idle = Test-WtCanWarmUp
                $script:window.IsActive = $true; $active = Test-WtCanWarmUp
                $script:window.IsActive = $false; $script:window.IsEnabled = $false; $disabled = Test-WtCanWarmUp
                $script:window.IsEnabled = $true
                [System.Windows.Interop.ComponentDispatcher]::PushModal()
                try { $modal = Test-WtCanWarmUp } finally { [System.Windows.Interop.ComponentDispatcher]::PopModal() }
                $script:window.IsEnabled = $true; $script:window.WindowState = [System.Windows.WindowState]::Minimized; $minimized = Test-WtCanWarmUp
                $script:window.WindowState = [System.Windows.WindowState]::Normal; $script:window.IsVisible = $false; $hidden = Test-WtCanWarmUp
                $script:window.IsVisible = $true; $script:exiting = $true; $exiting = Test-WtCanWarmUp
                $idle -and -not $active -and -not $disabled -and -not $modal -and -not $minimized -and -not $hidden -and -not $exiting
            } finally {
                $script:window = $oldWindow; $script:selecting = $oldSelecting
                $script:exiting = $false; $script:warmEnabled = $false
            }
        }
        Assert-Wt '미리 만들기: 활성·모달·최소화·숨김·종료 상태에서는 대기한다' $warmGates
        Register-WtAddon -Id 'test-warm-failure' -Title '미리 실패' -WarmUp Full -NewView { New-WtText '실패할 화면' } -Refresh { throw '가짜 갱신 실패' }
        $warmFailure = & (Get-Module Shell) {
            $script:warmEnabled = $true
            try {
                $script:warmQueue = [System.Collections.Generic.Queue[string]]::new([string[]]@('test-warm-failure'))
                [void](Invoke-WtWarmUpStep)
                -not $script:views.ContainsKey('test-warm-failure') -and $null -eq $script:ui.WarmHost.Content
            } finally { $script:warmEnabled = $false; $script:warmQueue = $null }
        }
        Assert-Wt '미리 만들기: 갱신 실패 화면은 캐시에 남기지 않는다' $warmFailure
        $opaqueSetting = Get-WtSetting 'ui.opacity'
        $opaqueSession = & (Get-Module Shell) {
            $oldWindow = $script:window
            $oldForceOpaque = $script:forceOpaque
            try {
                $script:window = [System.Windows.Window]::new()
                $script:forceOpaque = $true
                Set-WtOpacity 65
                $script:window.Opacity -eq 1.0
            } finally { $script:window = $oldWindow; $script:forceOpaque = $oldForceOpaque }
        }
        Assert-Wt '불투명 진단: 세션 투명도만 고정하고 저장 설정은 유지한다' ($opaqueSession -and (Get-WtSetting 'ui.opacity') -eq $opaqueSetting)

        # 공통 모양: 스크롤 막대는 화살표 없이 손잡이만 두고, 가로 · 세로 막대가 만나는 모서리에 회색 칸이 없다. 막대를 누르면 한 화면씩 움직인다
        $box = [System.Windows.Controls.Border]::new()
        $box.Resources.MergedDictionaries.Add((New-WtThemeDictionary)); $box.Resources.MergedDictionaries.Add((Get-WtStyleDictionary))
        $sv = [System.Windows.Controls.ScrollViewer]::new(); $sv.HorizontalScrollBarVisibility = 'Auto'
        $lines = New-WtStack Vertical; $lines.Width = 400
        foreach ($i in 1..30) { [void](Add-WtChild $lines (New-WtText "줄 $i")) }
        $sv.Content = $lines; $box.Child = $sv
        $box.Measure([System.Windows.Size]::new(200, 100)); $box.Arrange([System.Windows.Rect]::new(0, 0, 200, 100)); $box.UpdateLayout()
        $parts = [System.Collections.Generic.List[object]]::new()
        $walk = { param($n) $parts.Add($n); for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($n); $i++) { & $walk ([System.Windows.Media.VisualTreeHelper]::GetChild($n, $i)) } }
        & $walk $box
        $bars = @($parts | Where-Object { $_ -is [System.Windows.Controls.Primitives.ScrollBar] })
        $pages = @($parts | Where-Object { $_ -is [System.Windows.Controls.Primitives.RepeatButton] } | ForEach-Object { $_.Command.Name })
        $pageDown = @($parts | Where-Object { $_ -is [System.Windows.Controls.Primitives.RepeatButton] -and $_.Command.Name -eq 'PageDown' })[0]
        $pageDown.Command.Execute($null, $pageDown); $box.UpdateLayout()
        Assert-Wt 'WPF 공통 모양: 스크롤 막대는 화살표 · 모서리 칸 없이 그리고, 막대를 누르면 한 화면씩 움직인다' (
            $bars.Count -eq 2 -and $bars[0].ActualWidth -eq 12 -and $bars[1].ActualHeight -eq 12 -and ($pages -join ',') -eq 'PageUp,PageDown,PageLeft,PageRight' -and
            -not @($parts | Where-Object { $_ -is [System.Windows.Shapes.Rectangle] }).Count -and $sv.VerticalOffset -gt 0) "(막대 $($bars.Count) · 버튼 $($pages -join ',') · 위치 $($sv.VerticalOffset))"
    } else {
        Write-Host 'SKIP WPF로 그리기 (Windows STA에서만)'
    }

    # ---- 탭 모아 보기: 앱처럼 모든 탭을 함께 불러온다 ----
    Import-WtTestCore
    Set-WtAppRoot $test.App
    Initialize-WtSettings
    $addonFiles = @(Get-ChildItem (Join-Path $root 'addons') -Filter '*.psm1' -Recurse | Sort-Object FullName)
    $addonModules = @(foreach ($f in $addonFiles) { Import-Module $f.FullName -Force -DisableNameChecking -PassThru })
    $ids = @(Get-WtAddon -All | ForEach-Object Id)
    # 탭 폴더 하나에 모듈이 여럿일 수 있다(예: memo의 Memo.psm1 · MemoEditor.psm1 · MemoText.psm1). 등록은 폴더마다 하나
    $addonDirs = @($addonFiles | ForEach-Object { $_.Directory.FullName } | Sort-Object -Unique)
    Assert-Wt '탭 모아 보기: 탭 폴더마다 ID 하나씩 등록한다 (겹치는 ID 없음)' ($ids.Count -eq $addonDirs.Count) "(탭 폴더 $($addonDirs.Count)개 · 등록 $($ids -join ', '))"
    $owners = @{}
    $dupes = foreach ($m in @(Get-Module | Where-Object { $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) })) {
        foreach ($fn in $m.ExportedFunctions.Keys) {
            if ($owners.ContainsKey($fn)) { "$fn ($($owners[$fn]) · $($m.Name))" } else { $owners[$fn] = $m.Name }
        }
    }
    Assert-Wt '탭 모아 보기: 모듈끼리 내보낸 함수 이름이 겹치지 않는다' (-not $dupes) ($dupes -join ', ')
    # 화면 밖 작업(실행 공간 · 스레드 · .NET 작업)은 core\Work.psm1만 만든다. 끝낼 때 끝나지 않은 작업을 기다리지 않고 버리는 규칙을
    # 한 곳에서 지키려는 것이다. 실행 공간의 Stop · Close · Dispose는 응답 없는 작업이 끝나기를 기다려 앱을 멈추거나 프로세스를 남긴다
    $engine = @(Get-ChildItem $root -Filter '*.psm1' -Recurse | Where-Object {
            $_.Name -ne 'Work.psm1' -and (Get-Content -LiteralPath $_.FullName -Raw) -match 'RunspaceFactory|\[powershell\]::Create|\.BeginInvoke\(\)|CloseAsync|BeginStop|ThreadOptions|Thread\]::new|Task\[[^\]]+\]\]::Run|Tasks\.Task\]::Run'
        } | ForEach-Object Name)
    Assert-Wt '탭 모아 보기: 실행 공간 · 스레드는 core\Work.psm1만 만든다 (탭은 Start-WtWork · Invoke-WtWork)' (-not $engine.Count) ($engine -join ', ')
    # 파일 · 폴더를 원래 프로그램 · 탐색기로 여는 것은 확인까지 화면 밖에서 하는 Open-WtPath로만 한다 (응답 없는 공유 경로에서 화면이 멈추지 않게)
    $shellOpen = @(Get-ChildItem $root -Filter '*.psm1' -Recurse | Where-Object { $_.Name -ne 'Work.psm1' -and (Get-Content -LiteralPath $_.FullName -Raw) -match '(?i)Invoke-Item|explorer\.exe' } | ForEach-Object Name)
    Assert-Wt '탭 모아 보기: 파일 · 폴더 열기는 Open-WtPath로만 한다 (Invoke-Item · explorer.exe 직접 호출 없음)' (-not $shellOpen.Count) ($shellOpen -join ', ')
    # 진입 스크립트는 앱이 끝난 뒤 Exit-WtOwnProcess로 앱 전용 프로세스를 끝낸다 (버린 작업이 프로세스를 붙잡지 않게)
    $entryText = [System.IO.File]::ReadAllText((Join-Path $root 'Start-WorkTool.ps1'))
    Assert-Wt '진입 스크립트: 앱을 끝낸 뒤 Exit-WtOwnProcess로 프로세스를 끝낸다' (
        $entryText -match '(?m)^if \(Get-Command Exit-WtOwnProcess[^\r\n]*\{ Exit-WtOwnProcess -ScriptPath \$PSCommandPath \}' -and $entryText.LastIndexOf('Exit-WtOwnProcess') -gt $entryText.LastIndexOf('Start-WtApp'))
    # 글을 코드로 바꿔 실행하는 동작(AGENTS.md 「코드 규칙」 4번)은 앱 코드에도 쓰지 않는다. 주석 · 도움말 글은 빼고 구문으로 찾는다
    $dynamic = @(foreach ($f in Get-ChildItem $root -Recurse -Include '*.psm1', '*.ps1' | Where-Object { $_.Name -notlike 'Test-*' -and $_.FullName -notlike '*\tests\*' }) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $hits = $ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
                        $n.Expression.TypeName.Name -match '(?i)^(System\.Management\.Automation\.)?scriptblock$' -and $n.Member.Value -eq 'Create') -or
                    ($n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in 'Invoke-Expression', 'iex')
                }, $true)
            if (@($hits).Count) { $f.Name }
        })
    Assert-Wt '탭 모아 보기: 글을 코드로 바꿔 실행하지 않는다 ([scriptblock]::Create · Invoke-Expression)' (-not $dynamic.Count) ($dynamic -join ', ')
    if ($wpf) {
        $texts = @(Get-WtTestTexts (New-WtHelpPage))
        $missing = @(foreach ($a in @(Get-WtAddon)) { foreach ($line in @($a.Help)) { if ($texts -notcontains $line) { "$($a.Id): $line" } } })
        $broken = @($texts | Where-Object { $_ -like '* 도움말을 만들지 못했습니다*' })
        Assert-Wt '탭 모아 보기: 도움말이 모든 탭의 설명을 싣고, 탭 카드도 오류 없이 만든다' (-not $missing.Count -and -not $broken.Count) (($missing + $broken) -join '; ')
    }
    $addonModules | Remove-Module -Force
} finally {
    Remove-WtTestData $test
}

if ($script:failed) { Write-Host "실패 $script:failed 건" -ForegroundColor Red; exit 1 }
# 탭 폴더의 검사를 모두 찾아서 돌린다. 하나라도 틀리면 그 자리에서 멈춘다
foreach ($t in (Get-ChildItem (Join-Path $root 'addons') -Filter 'Test-*.ps1' -Recurse | Sort-Object FullName)) {
    if ($NoDesktop -and $t.Directory.Name -in @('active-tasks', 'workflows')) {
        Write-Host "SKIP $($t.Name) (전용 창 · 프로세스 종료 포함, -NoDesktop)"; continue
    }
    & $t.FullName
}
& (Join-Path $PSScriptRoot 'Test-Reliability.ps1')
if (-not $NoDesktop) { & (Join-Path $PSScriptRoot 'Test-Launcher.ps1') }
else { Write-Host 'SKIP 실행 파일 GUI 검사 (-NoDesktop)' }
if ($NoDesktop) { Write-Host '제외: WPF 화면 · 입력, 활성 작업 · 업무 탭, 앱 강제 종료 · GUI 실행 파일' }
Write-Host '모두 통과' -ForegroundColor Green

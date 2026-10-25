<#
.SYNOPSIS
    셸 · 저장의 안정성을 임시 데이터로 검사한다: 중복 실행 차단 · 설정 저장 실패 · 저장 실패 때 묻는 흐름 · 예전 WinForms 종료 저장.

.DESCRIPTION
    묻는 흐름은 가짜 탭을 등록해서 본다. 탭마다의 저장 실패 · 조회 취소는 그 탭 폴더의 검사(addons\<이름>\Test-*.ps1)가 맡는다.
    tests\Test-Core.ps1이 돌린다. 혼자 돌려도 된다.

.EXAMPLE
    pwsh -NoProfile -STA -File apps/WorkTool/wpf/tests/Test-Reliability.ps1
#>
#Requires -Version 7.0
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'TestKit.ps1')
Import-WtTestCore
$test = New-WtTestData 'reliability'
$held = $null; $instance = $null; $legacyForm = $null
$shellModule = Get-Module Shell

try {
    # 다른 프로세스도 같은 데이터 폴더를 열 수 없어야 한다.
    $child = Join-Path $test.Root 'lock-child.ps1'
    @'
param($Source, $App)
Import-Module (Join-Path (Split-Path $Source) 'Work.psm1') -Force -DisableNameChecking
Import-Module $Source -Force -DisableNameChecking
Set-WtAppRoot $App
try { [void](Get-WtDataRoot) } catch { exit 5 }
try { $lease = Open-WtDataLock; $lease.Dispose(); exit 0 } catch { exit 23 }
'@ | Set-Content -LiteralPath $child -Encoding utf8
    $instance = Open-WtDataLock
    & pwsh -NoProfile -NonInteractive -File $child (Join-Path $root 'core/Storage.psm1') $test.App
    Assert-WtTest '안정성: 다른 프로세스의 같은 데이터 폴더 실행을 막는다' ($LASTEXITCODE -eq 23)
    $instance.Dispose(); $instance = $null
    & pwsh -NoProfile -NonInteractive -File $child (Join-Path $root 'core/Storage.psm1') $test.App
    Assert-WtTest '안정성: 잠금 파일이 남아도 종료 뒤 다시 실행할 수 있다' ($LASTEXITCODE -eq 0)

    Set-WtSetting 'test.mode' 'edit'
    $held = [System.IO.File]::Open((Get-WtSettingsPath), 'Open', 'Read', 'Read')
    $threw = $false
    try { Set-WtSetting 'test.mode' 'preview' } catch { $threw = $true }
    Assert-WtTest '안정성: 설정 저장 실패 시 메모리 값도 유지한다' ($threw -and (Get-WtSetting 'test.mode') -eq 'edit')
    $held.Dispose(); $held = $null

    # 데이터 폴더가 늦게 답하는 저장 (응답 없는 공유 폴더): 실제 쓰기(Write-WtDataFile) 앞에 기다림만 끼운다. 통로 · 상태 바꾸기는 그대로 돈다.
    # 화면은 정한 시간만 기다리고 실패로 정하지 않는다(저장 중). 통로가 끝까지 맡고, 그동안 읽으면 저장 중인 내용이 나온다
    $storage = Get-Module Storage
    $filePath = Get-WtStorePath 'hang-test'
    Write-WtStore -Name 'hang-test' -Items @([ordered]@{ id = 'h0' })
    $gate = New-WtTestGate
    try {
        & $storage {
            $script:testJob = $script:writeJob; $script:testSlow = $script:writeSlowMs
            $script:writeJob = { param($p, $json) $g = [AppDomain]::CurrentDomain.GetData('WtTestGate'); [void]$g.Entered.Set(); [void]$g.Gate.WaitOne(); Write-WtDataFile $p $json }
        }
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $writeError = $null; try { Write-WtStore -Name 'hang-test' -Items @([ordered]@{ id = 'h1' }) } catch { $writeError = $_.Exception }
        $writeMs = $watch.ElapsedMilliseconds
        Set-WtSetting 'test.mode' 'hang'   # 설정은 통로에 맡기고 바로 돌아온다 (앞 쓰기 뒤 차례)
        $state = Get-WtDataWriteState
        Assert-WtTest "안정성: 저장이 늦으면 화면은 잠깐만 기다리고(${writeMs}ms) 실패가 아닌 「저장 중」으로 올린다" (
            $gate.Entered.WaitOne(0) -and (Test-WtSavePending $writeError) -and $writeMs -lt 1500 -and (Test-WtDataWriting) -and $state.Count -eq 2 -and -not $state.Slow)
        Assert-WtTest '안정성: 저장 중인 파일을 읽으면 저장 중인 내용이 나오고, 표식도 다 쓴 뒤와 같다' (
            (Get-WtStoreItems 'hang-test')[0].id -eq 'h1' -and (Get-WtSetting 'test.mode') -eq 'hang' -and (Test-WtStore 'hang-test') -and
            [System.IO.File]::ReadAllText($filePath) -match '"h0"')
        # 오래 걸리면(검사에서는 300ms) 「응답 없음」으로 보이지만 실패로 정하지 않는다. 같은 파일을 또 저장해도 바로 돌아온다
        & $storage { $script:writeSlowMs = 300 }
        Start-Sleep -Milliseconds 350; Update-WtWork
        $watch.Restart()
        $againError = $null; try { Write-WtStore -Name 'hang-test' -Items @([ordered]@{ id = 'h2' }) } catch { $againError = $_.Exception }
        $againMs = $watch.ElapsedMilliseconds
        $pendingStamp = Get-WtStoreStamp 'hang-test'
        $slow = Get-WtDataWriteState
        Assert-WtTest "안정성: 「응답 없음」이 돼도 실패로 정하지 않고, 그동안 저장은 기다리지 않는다 (${againMs}ms)" (
            $slow.Slow -and $slow.Count -eq 3 -and (Test-WtSavePending $againError) -and $againMs -lt 150 -and (Get-WtStoreItems 'hang-test')[0].id -eq 'h2')
        # 답이 오면 통로가 차례대로 마저 쓴다: 마지막 내용이 남고, 늦게 끝났다고 실패로 바뀌지 않는다
        [void]$gate.Gate.Set()
        $watch.Restart()
        while ((Test-WtDataWriting) -and $watch.ElapsedMilliseconds -lt 5000) { Update-WtWork; Start-Sleep -Milliseconds 20 }
        $doc = [System.IO.File]::ReadAllText($filePath) | ConvertFrom-Json
        $settings = [System.IO.File]::ReadAllText((Get-WtSettingsPath)) | ConvertFrom-Json
        Assert-WtTest '안정성: 답이 오면 저장 통로가 마저 써서 마지막 내용이 파일에 남는다' (
            -not (Test-WtDataWriting) -and $doc.items[0].id -eq 'h2' -and $settings.values.'test.mode' -eq 'hang')
        Assert-WtTest '안정성: 저장 중에 잰 표식은 다 쓴 뒤 파일에서 잰 표식과 같다 (화면이 괜히 다시 읽지 않게)' ($pendingStamp -eq (Get-WtStoreStamp 'hang-test'))
    } finally {
        & $storage { $script:writeJob = $script:testJob; $script:writeSlowMs = $script:testSlow }
        Remove-WtTestGate $gate
    }
    # 저장은 읽기와 다른 통로다: 답 없는 읽기가 작업 수 한도를 채워도 저장은 막히지 않는다
    $gate = New-WtTestGate
    try {
        $max = & (Get-Module Work) { $script:maxJobs }
        $hung = @(for ($i = 0; $i -lt $max; $i++) { Start-WtWork $wtTestHang -Key 'path:\\wt-test\read' -OnDone { } })
        $blocked = $null; try { [void](Start-WtWork { 1 } -OnDone { }) } catch { $blocked = $_.Exception }
        $writeError = $null; try { Write-WtStore -Name 'hang-test' -Items @([ordered]@{ id = 'h3' }) } catch { $writeError = $_.Exception }
        Assert-WtTest "안정성: 답 없는 읽기 ${max}개가 작업 한도를 채워도 저장은 바로 끝난다" (
            $blocked -is [System.InvalidOperationException] -and -not $writeError -and ([System.IO.File]::ReadAllText($filePath) -match '"h3"'))
        Stop-WtWork $hung
    } finally { Remove-WtTestGate $gate }

    if (-not (Test-WtTestWpf)) { Write-Host 'SKIP 안정성 WPF/WinForms (Windows STA에서만)'; return }

    # ---- 저장하지 못한 내용이 있을 때 묻는 흐름 (가짜 탭) ----
    $pending = [pscustomobject]@{ Saved = $false; Calls = 0 }
    $exitCounter = [pscustomobject]@{ Count = 0 }
    Register-WtAddon -Id 'test-pending' -Title '가짜' -Order 1 -NewView { [System.Windows.Controls.Border]::new() } `
        -SavePending { $pending.Calls++; $pending.Saved }.GetNewClosure()
    Register-WtAddon -Id 'test-other' -Title '다른' -Order 2 -NewView { [System.Windows.Controls.Border]::new() }
    Register-WtAddon -Id 'test-cleanup' -Title '정리' -Order 3 -NewView { [System.Windows.Controls.Border]::new() } `
        -OnExit { $exitCounter.Count++ }.GetNewClosure()
    # UI 알림창 · 확인창만 바꾼다. 저장 확인 · 전환 · 종료는 실제 함수를 실행한다. 확인창의 대답은 차례로 정해 두고, 없으면 [취소]
    & $shellModule {
        function script:Show-WtMessage { param($Text, $Title, $Kind) }
        function script:Show-WtError { param($ErrorRecord, $Action) }
        $script:testChoices = [System.Collections.Generic.Queue[string]]::new(); $script:testAsked = @()
        function script:Show-WtPendingChoice { param($Purpose, $Title) $script:testAsked += $Purpose; if ($script:testChoices.Count) { $script:testChoices.Dequeue() } else { 'cancel' } }
        # 저장 중 창: 무엇을 물었는지 적고, 검사가 정한 대답 코드를 돌린다 (그 안에서 문을 열어 저장을 끝낼 수 있다)
        $script:testWriting = @(); $script:testWritingAnswer = { 'cancel' }
        function script:Show-WtWritingChoice { param($Purpose, [switch]$NoCancel) $script:testWriting += "$Purpose$(if ($NoCancel) { '!' })"; & $script:testWritingAnswer }
    }
    $gatedWrite = { param($p, $json) $g = [AppDomain]::CurrentDomain.GetData('WtTestGate'); [void]$g.Entered.Set(); [void]$g.Gate.WaitOne(); Write-WtDataFile $p $json }
    # 문을 열고 저장 통로가 빌 때까지 거둔다. 그 뒤 'done'
    $finishWrites = {
        [void][AppDomain]::CurrentDomain.GetData('WtTestGate').Gate.Set()
        $w = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Test-WtDataWriting) -and $w.ElapsedMilliseconds -lt 5000) { Update-WtWork; Start-Sleep -Milliseconds 20 }
        if (Test-WtDataWriting) { 'cancel' } else { 'done' }
    }
    $savedMode = { ([System.IO.File]::ReadAllText((Get-WtSettingsPath)) | ConvertFrom-Json).values.'test.mode' }
    $allowed = & $shellModule { $script:frame = [pscustomobject]@{ Continue = $true }; Stop-WtApp }
    Assert-WtTest '안정성: 저장 실패는 끝낼지 묻고, [취소]면 정리 처리 전에 종료를 멈춘다' (-not $allowed -and $exitCounter.Count -eq 0 -and (& $shellModule { $script:frame.Continue }) -and (& $shellModule { $script:testAsked -join ',' }) -eq 'exit')
    $calls = $pending.Calls
    $allowed = & $shellModule { $script:testAsked = @(); $script:testChoices.Enqueue('retry'); $script:testChoices.Enqueue('cancel'); Stop-WtApp }
    Assert-WtTest '안정성: [다시 시도]는 다시 저장해 보고 실패하면 또 묻는다' (-not $allowed -and (& $shellModule { $script:testAsked.Count }) -eq 2 -and $pending.Calls -eq $calls + 2 -and $exitCounter.Count -eq 0)
    & $shellModule {
        $script:current = 'test-pending'; $script:testAsked = @()
        $script:navButtons = @{ 'test-pending' = @{ Button = [System.Windows.Controls.RadioButton]::new() }; 'test-other' = @{ Button = [System.Windows.Controls.RadioButton]::new() } }
        $script:navButtons['test-other'].Button.IsChecked = $true
    }
    Select-WtPage '_help'
    Assert-WtTest '안정성: 저장 실패는 이동할지 묻고, [취소]면 페이지 전환을 멈춘다' ((& $shellModule { $script:current }) -eq 'test-pending' -and (& $shellModule { $script:testAsked -join ',' }) -eq 'switch')
    Assert-WtTest '안정성: 전환을 취소하면 메뉴 선택도 원래 화면으로 돌아간다' ((& $shellModule { $script:navButtons['test-pending'].Button.IsChecked }) -and -not (& $shellModule { $script:navButtons['test-other'].Button.IsChecked }))
    & $shellModule { $script:ui = @{ PageHost = [System.Windows.Controls.ContentControl]::new() }; $script:testChoices.Enqueue('proceed') }
    Select-WtPage '_help'
    Assert-WtTest '안정성: [이동]을 고르면 저장하지 못했어도 화면을 옮긴다' ((& $shellModule { $script:current }) -eq '_help')
    $askedBefore = & $shellModule { $script:testAsked.Count }
    Assert-WtTest '안정성: 저장할 것이 없는 화면을 떠날 때는 묻지 않는다' ((& $shellModule { Save-WtPendingChanges -Purpose switch -Only '_help' }) -and (& $shellModule { $script:testAsked.Count }) -eq $askedBefore)
    & $shellModule { $script:current = 'test-pending'; $script:ui = $null }
    $pending.Saved = $true
    Assert-WtTest '안정성: 성공한 종료에서만 정리 처리를 실행한다' ((& $shellModule { Stop-WtApp }) -and $exitCounter.Count -eq 1)
    # 저장하지 못해도 [끝내기]를 고르면 끝낼 수 있다. 끌 수 없는 상태를 만들지 않는다
    $pending.Saved = $false
    $allowed = & $shellModule { $script:exiting = $false; $script:frame = [pscustomobject]@{ Continue = $true }; $script:testAsked = @(); $script:testChoices.Enqueue('proceed'); Stop-WtApp }
    Assert-WtTest '안정성: 저장하지 못해도 [끝내기]를 고르면 정리하고 끝낸다' ($allowed -and $exitCounter.Count -eq 2 -and -not (& $shellModule { $script:frame.Continue }) -and (& $shellModule { $script:testAsked -join ',' }) -eq 'exit')

    # ---- 저장 통로가 아직 쓰는 중일 때 (데이터 폴더가 늦게 답함). 실제 저장 통로 · 상태 바꾸기 · 셸 흐름을 그대로 돌리고 대답 창만 바꾼다 ----
    # 화면을 옮길 때: 「저장 중」은 실패로 묻지 않는다. 기다리는 창에서 [취소]면 머물고, 저장이 끝나면 다시 저장해 보고 옮긴다
    $gate = New-WtTestGate
    try {
        & $storage { param($j) $script:writeJob = $j } $gatedWrite
        Set-WtSetting 'test.mode' 'switch-wait'
        $pending.Saved = $false
        & $shellModule { $script:testAsked = @(); $script:testWriting = @(); $script:testWritingAnswer = { 'cancel' } }
        $stayed = -not (& $shellModule { Save-WtPendingChanges -Purpose switch -Only 'test-pending' })
        $answer = { $r = & $finishWrites; $pending.Saved = $true; $r }.GetNewClosure()
        $moved = & $shellModule { param($a) $script:testWritingAnswer = $a; Save-WtPendingChanges -Purpose switch -Only 'test-pending' } $answer
        Assert-WtTest '안정성: 화면을 옮길 때 저장 중이면 실패로 묻지 않고 기다리는 창을 띄운다 ([취소]면 머물고, 끝나면 다시 저장해 보고 옮긴다)' (
            $stayed -and $moved -and (& $shellModule { $script:testAsked.Count }) -eq 0 -and (& $shellModule { $script:testWriting -join ',' }) -eq 'switch,switch' -and (& $savedMode) -eq 'switch-wait')
    } finally {
        & $storage { $script:writeJob = $script:testJob }
        Remove-WtTestGate $gate
    }
    # 끝낼 때: 정리(OnExit) 뒤에도 저장 중인 것이 있으면 말없이 버리고 끝내지 않는다. 끝날 때까지 기다리는 창을 띄운다 (취소 없음)
    $gate = New-WtTestGate
    try {
        & $storage { param($j) $script:writeJob = $j } $gatedWrite
        Set-WtSetting 'test.mode' 'exit-wait'
        $exits = $exitCounter.Count
        $allowed = & $shellModule { param($a) $script:exiting = $false; $script:frame = [pscustomobject]@{ Continue = $true }; $script:testWriting = @(); $script:testWritingAnswer = $a; Stop-WtApp } $finishWrites
        Assert-WtTest '안정성: 끝낼 때 저장 중인 것이 있으면 기다리는 창을 띄우고, 저장이 끝난 뒤에 끝낸다' (
            $allowed -and $exitCounter.Count -eq $exits + 1 -and (& $shellModule { $script:testWriting -join ',' }) -eq 'exit!' -and (& $savedMode) -eq 'exit-wait')
        # 그 창을 그냥 닫으면(대답 없음) 다시 묻는다. [저장을 기다리지 않고 끝내기]를 고를 때만 남은 저장을 버린다
        & $storage { param($j) $script:writeJob = $j } $gatedWrite
        [void]$gate.Gate.Reset()
        Set-WtSetting 'test.mode' 'exit-drop'
        $answers = [System.Collections.Generic.Queue[string]]::new(); $answers.Enqueue('cancel'); $answers.Enqueue('proceed')
        $answer = { $answers.Dequeue() }.GetNewClosure()
        $allowed = & $shellModule { param($a) $script:exiting = $false; $script:frame = [pscustomobject]@{ Continue = $true }; $script:testWriting = @(); $script:testWritingAnswer = $a; Stop-WtApp } $answer
        Assert-WtTest '안정성: 기다리는 창을 닫으면 다시 묻고, [저장을 기다리지 않고 끝내기]를 고를 때만 남은 저장을 버리고 끝낸다' (
            $allowed -and (& $shellModule { $script:testWriting -join ',' }) -eq 'exit!,exit!' -and -not (Test-WtDataWriting) -and (& $savedMode) -eq 'exit-wait')
    } finally {
        & $storage { $script:writeJob = $script:testJob }
        Remove-WtTestGate $gate
    }
    # 부른 쪽이 결과를 받지 못한 저장(설정처럼 통로에 맡긴 것)이 나중에 실패로 정해지면, 조용히 잃지 않고 사용자에게 알린다
    $gate = New-WtTestGate
    try {
        & $storage {
            $script:testTold = [System.Collections.Generic.List[string]]::new()
            function script:Show-WtMessage { param($Text, $Title, $Icon) $script:testTold.Add($Text) }
            $script:writeJob = { param($p, $json) [void][AppDomain]::CurrentDomain.GetData('WtTestGate').Gate.WaitOne(); throw [System.IO.IOException]::new('검사용 쓰기 실패') }
        }
        Set-WtSetting 'test.mode' 'late-fail'
        [void]$gate.Gate.Set()
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        while ((Test-WtDataWriting) -and $watch.ElapsedMilliseconds -lt 5000) { Update-WtWork; Start-Sleep -Milliseconds 20 }
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{ }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)   # 미뤄 둔 알림을 돌린다
        $told = @(& $storage { $script:testTold })
        Assert-WtTest '안정성: 맡겨 둔 저장이 나중에 실패로 정해지면 사용자에게 알린다' ($told.Count -eq 1 -and $told[0] -like '*settings.json*검사용 쓰기 실패*') ($told -join ' / ')
    } finally {
        & $storage { $script:writeJob = $script:testJob }
        Remove-WtTestGate $gate
    }

    # 끝낼 때: 탭이 남긴 화면 밖 작업이 OS 요청에서 돌아오지 않아도(응답 없는 공유 폴더) 종료 처리는 기다리지 않고 버린다.
    # 그 뒤 앱 전용 프로세스가 실제로 끝나는지는 tests\Test-Core.ps1(Exit-WtOwnProcess)과 tests\Test-Launcher.ps1이 본다
    $gate = New-WtTestGate
    try {
        [void](Start-WtWork $wtTestHang -OnDone { })
        $entered = $gate.Entered.WaitOne(5000)
        $pending.Saved = $true
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $allowed = & $shellModule { $script:exiting = $false; $script:frame = [pscustomobject]@{ Continue = $true }; Stop-WtApp }
        $exitMs = $watch.ElapsedMilliseconds
        Assert-WtTest "안정성: 돌아오지 않는 화면 밖 작업이 남아도 종료 처리는 기다리지 않고 버린다 (${exitMs}ms)" (
            $entered -and $allowed -and $exitMs -lt 500 -and -not (& $shellModule { $script:frame.Continue }) -and (Get-WtWorkInfo).Running -eq 0 -and (Get-WtWorkInfo).Abandoned -ge 1)
    } finally { Remove-WtTestGate $gate }

    # ---- 기존 WinForms도 실제 FormClosing에서 저장 실패를 처리해야 한다: 끝낼지 묻고, [아니요]면 취소한다 ----
    $legacyRoot = Split-Path $root -Parent
    $legacyStorage = Import-Module (Join-Path $legacyRoot 'modules/Storage.psm1') -Force -PassThru
    & $legacyStorage { param($path) $script:dataDir = $path } (Join-Path $test.Root 'legacy-data')
    $instance = Open-WorkToolDataLock
    $blocked = $false
    try { $extra = Open-WorkToolDataLock; $extra.Dispose() } catch { $blocked = $true }
    Assert-WtTest '안정성: 기존 버전도 같은 데이터 폴더의 중복 실행을 막는다' $blocked
    Import-Module (Join-Path $legacyRoot 'modules/UiHelper.psm1') -Force
    $legacyMemo = Import-Module (Join-Path $legacyRoot 'modules/Memo.psm1') -Force -PassThru
    Save-Records memo @([pscustomobject]@{Id='old';Title='old';Body='original';Created='2026-01-01';Updated='2026-01-01'})
    $legacyForm = [System.Windows.Forms.Form]::new()
    $legacyView = New-MemoView
    $legacyForm.Controls.Add($legacyView)
    [void]$legacyForm.Handle; [void]$legacyView.Handle
    & $legacyMemo {
        function script:Show-MemoMessage { param($Text) $script:testShown++ }
        function script:Confirm-MemoDiscard { param($Reason) $script:testAsked++; $script:testAnswer }
        $script:testShown = 0; $script:testAsked = 0; $script:testAnswer = $false
        Show-Memo $script:memos[0]; $script:bodyBox.Text = 'legacy draft'
    }
    $legacyPath = Join-Path $test.Root 'legacy-data/memo.csv'
    $held = [System.IO.File]::Open($legacyPath, 'Open', 'Read', 'Read')
    $closeArgs = [System.Windows.Forms.FormClosingEventArgs]::new('UserClosing', $false)
    $closing = [System.Windows.Forms.Form].GetMethod('OnFormClosing', [Reflection.BindingFlags]'Instance,NonPublic')
    [void]$closing.Invoke($legacyForm, @($closeArgs))
    Assert-WtTest '안정성: 기존 버전 저장 실패 시 끝낼지 묻고 [아니요]면 종료를 취소한다' ($closeArgs.Cancel -and (& $legacyMemo { $script:dirty }) -and (& $legacyMemo { $script:testAsked }) -eq 1)
    & $legacyMemo { $script:testAnswer = $true }
    $closeArgs = [System.Windows.Forms.FormClosingEventArgs]::new('WindowsShutDown', $false)
    [void]$closing.Invoke($legacyForm, @($closeArgs))
    Assert-WtTest '안정성: 기존 버전도 [예]면 저장하지 못해도 끝낸다 (Windows 종료 포함)' (-not $closeArgs.Cancel -and (& $legacyMemo { $script:testAsked }) -eq 2 -and @(Get-Records memo)[0].Body -eq 'original')
    # 트레이로 숨기는 중(메인 창이 이미 취소함)에는 묻지 않고 창을 다시 띄워 알린다.
    $closeArgs = [System.Windows.Forms.FormClosingEventArgs]::new('UserClosing', $true)
    [void]$closing.Invoke($legacyForm, @($closeArgs))
    Assert-WtTest '안정성: 기존 버전 트레이 숨김 중 저장 실패는 묻지 않고 창을 다시 띄워 알린다' ($closeArgs.Cancel -and $legacyForm.Visible -and (& $legacyMemo { $script:testAsked }) -eq 2 -and (& $legacyMemo { $script:testShown }) -eq 1)
    $legacyForm.Hide()
    $held.Dispose(); $held = $null
    $closeArgs = [System.Windows.Forms.FormClosingEventArgs]::new('UserClosing', $false)
    [void]$closing.Invoke($legacyForm, @($closeArgs))
    Assert-WtTest '안정성: 기존 버전도 잠금 해제 후 종료 저장을 재시도한다' (-not $closeArgs.Cancel -and @(Get-Records memo)[0].Body -eq 'legacy draft')
} finally {
    if ($held) { $held.Dispose() }
    if ($instance) { $instance.Dispose() }
    if ($legacyForm) { $legacyForm.Dispose() }
    Remove-WtTestData $test
}

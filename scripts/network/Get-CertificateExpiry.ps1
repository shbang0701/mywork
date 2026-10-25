<#
.SYNOPSIS
    HTTPS(TLS) 서버의 인증서 만료일을 한 번에 확인하고, 곧 끝나는 것을 알려 준다.

.DESCRIPTION
    - 대상마다 TLS로 연결해 서버가 보여 주는 인증서를 읽는다: 주체(CN) · 발급자 · 시작일 · 만료일 · 남은 일수.
      남은 일수가 WarnDays 아래면 「곧 만료」, 지났으면 「만료」다.
    - 사설 인증서 · 이름이 다른 인증서도 만료일은 읽는다. 그런 경고는 「인증서 경고」 칸에 적는다.
    - 대상: Targets에 쉼표로 적거나, 목록 파일(스크립트 옆 cert-targets.txt)에 한 줄에 하나씩 적는다.
      둘 다 없으면 설정 블록의 Targets를 쓴다.
      한 줄은 "이름 주소[:포트]" 또는 "주소[:포트]"이고, 포트를 안 적으면 443이다. # 뒤는 메모로 본다.
      https://로 시작하는 주소를 붙여 넣어도 된다 (경로는 버린다).
    - 연결해서 인증서만 받고 끊는다. 웹 페이지를 요청하거나 데이터를 보내지 않는다. 관리자 권한이 필요 없다.
    - SaveCsv를 켜면 결과를 output 폴더에 날짜가 붙은 CSV로 저장한다.

.PARAMETER Targets
    확인할 대상. 쉼표로 여러 개 (예: portal.example.com, 10.0.0.10:8443)

.PARAMETER TargetFile
    대상 목록 파일 (비우면 스크립트 옆 cert-targets.txt)

.PARAMETER WarnDays
    남은 일수가 이보다 적으면 「곧 만료」로 알린다

.PARAMETER TimeoutMs
    대상 하나에 연결 · 인증서를 기다리는 시간(ms)

.PARAMETER SaveCsv
    결과를 CSV로 저장한다

.EXAMPLE
    .\Get-CertificateExpiry.ps1 -Targets 'portal.example.com, mail.example.com, 10.0.0.10:8443'
    세 곳의 인증서 만료일을 본다.

.EXAMPLE
    .\Get-CertificateExpiry.ps1 -WarnDays 60 -SaveCsv
    목록 파일의 대상을 확인하고, 60일 안에 끝나는 것을 알리고, CSV로 남긴다.
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Targets,
    [string]$TargetFile,
    [ValidateRange(1, 3650)][int]$WarnDays = 30,
    [ValidateRange(500, 60000)][int]$TimeoutMs = 5000,
    [switch]$SaveCsv
)

# ===== 설정 (여기만 고친다) =====
$Config = @{
    TargetFile   = Join-Path $PSScriptRoot 'cert-targets.txt'   # 대상 목록 파일. 없으면 아래 Targets를 쓴다
    Targets      = @(                                            # 예시는 가짜 값이다. 목록 파일을 만들거나 실제 값으로 바꾼다
        '포털     portal.example.com'
        '메일     mail.example.com'
        'SRV-01   10.0.0.10:8443'
    )
    OutputFolder = Join-Path $PSScriptRoot 'output'              # 결과(CSV)를 저장할 폴더
}
# =================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-OutputPath([string]$BaseName, [string]$Extension) {
    if (-not (Test-Path -LiteralPath $Config.OutputFolder)) { [void](New-Item -ItemType Directory -Path $Config.OutputFolder) }
    $stem = Join-Path $Config.OutputFolder ('{0}_{1:yyyyMMdd_HHmmss}' -f $BaseName, (Get-Date))
    $path = "$stem$Extension"; $n = 2
    while (Test-Path -LiteralPath $path) { $path = "${stem}_$n$Extension"; $n++ }
    $path
}

function Show-Table($Rows, [object[]]$Property) {
    $text = ($Rows | Format-Table -Property $Property -AutoSize | Out-String -Width 250).Trim("`r", "`n")
    if ($text) { Write-Host $text }
}

function Read-ListFile([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
    catch { $text = [System.Text.Encoding]::GetEncoding(949).GetString($bytes) }
    $text.TrimStart([char]0xFEFF) -split '\r?\n'
}

# 한 줄 → @{ Name; Host; Port }
function ConvertTo-Target([string]$Line) {
    $text = ($Line -replace '#.*$', '').Trim()
    if (-not $text) { return }
    $words = @($text -split '\s+' | Where-Object { $_ })
    $address = $words[-1] -replace '^https?://', '' -replace '/.*$', ''
    $name = ($words | Select-Object -SkipLast 1) -join ' '
    $port = 443
    if ($address -match '^\[(.+)\](:(\d+))?$') { $hostName = $Matches[1]; if ($Matches[3]) { $port = [int]$Matches[3] } }
    elseif ($address -match '^([^:]+):(\d+)$') { $hostName = $Matches[1]; $port = [int]$Matches[2] }
    else { $hostName = $address }
    if ($port -lt 1 -or $port -gt 65535) { throw "포트는 1~65535입니다: $Line" }
    [pscustomobject]@{ Name = $(if ($name) { $name } else { $hostName }); Host = $hostName; Port = $port }
}

function Get-ErrorText([System.Exception]$Exception) {
    $e = $Exception
    while ($e) {
        if ($e -is [System.Net.Sockets.SocketException]) {
            switch ([string]$e.SocketErrorCode) {
                'ConnectionRefused' { return '연결 거부 (포트 닫힘)' }
                'TimedOut' { return '시간 초과' }
                'HostNotFound' { return '이름을 찾지 못함' }
                'NoData' { return '이름을 찾지 못함' }
                'TryAgain' { return '이름을 찾지 못함' }
            }
        }
        if ($e -is [System.IO.IOException] -and -not $e.InnerException) { return "TLS 연결 실패: $($e.Message)" }
        if (-not $e.InnerException) { break }
        $e = $e.InnerException
    }
    $e.Message
}

$script:policy = $null
# 인증서가 사설이거나 이름이 달라도 만료일은 읽어야 하므로 연결은 받아들이고, 경고만 적어 둔다
$script:acceptAll = [System.Net.Security.RemoteCertificateValidationCallback] {
    param($s, $certificate, $chain, $errors)
    $script:policy = $errors
    $true
}

function Get-PolicyText($Errors) {
    if ($null -eq $Errors -or $Errors -eq [System.Net.Security.SslPolicyErrors]::None) { return '' }
    $list = @()
    if ($Errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNameMismatch) { $list += '이름이 다름' }
    if ($Errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateChainErrors) { $list += '신뢰할 수 없는 발급자 · 체인 오류' }
    if ($Errors -band [System.Net.Security.SslPolicyErrors]::RemoteCertificateNotAvailable) { $list += '인증서 없음' }
    $list -join ', '
}

function Get-Certificate($Target) {
    $client = [System.Net.Sockets.TcpClient]::new()
    $ssl = $null
    try {
        $connect = $client.ConnectAsync($Target.Host, $Target.Port)
        if (-not $connect.Wait($TimeoutMs)) { throw [System.TimeoutException]::new('시간 초과') }
        $client.ReceiveTimeout = $TimeoutMs
        $client.SendTimeout = $TimeoutMs
        $ssl = [System.Net.Security.SslStream]::new($client.GetStream(), $false, $script:acceptAll)
        $script:policy = $null
        # IP로 적으면 SNI 없이, 이름으로 적으면 그 이름으로 연결한다 (서버가 이름에 맞는 인증서를 고른다)
        $ssl.AuthenticateAsClient($Target.Host)
        @{ Cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate); Policy = $script:policy }
    } finally {
        if ($ssl) { $ssl.Dispose() }
        $client.Dispose()
    }
}

# ===== 본문 =====
if ($TargetFile) { $Config.TargetFile = $TargetFile.Trim().Trim('"') }
if ($Targets) { $lines = @($Targets -split '[,;\r\n]+'); $source = '입력한 Targets' }
elseif (Test-Path -LiteralPath $Config.TargetFile -PathType Leaf) { $lines = @(Read-ListFile $Config.TargetFile); $source = $Config.TargetFile }
elseif ($TargetFile) { throw "목록 파일이 없습니다: $($Config.TargetFile)" }
else { $lines = @($Config.Targets); $source = '설정 블록의 Targets (목록 파일 없음)' }
$list = @(foreach ($line in $lines) { ConvertTo-Target $line })
if (-not $list.Count) { throw '확인할 대상이 없습니다. Targets에 적거나 목록 파일을 만드세요.' }
Write-Host "대상: $source · $($list.Count)곳 · ${WarnDays}일 안에 끝나면 「곧 만료」"

$now = Get-Date
$rows = @(foreach ($t in $list) {
        $row = [ordered]@{
            이름 = $t.Name; 주소 = $t.Host; 포트 = $t.Port; 상태 = ''; '남은 일수' = ''; 만료일 = ''; 시작일 = ''
            주체 = ''; 발급자 = ''; '인증서 경고' = ''; 지문 = ''
        }
        try {
            $got = Get-Certificate $t
            $cert = $got.Cert
            $left = [int][Math]::Floor(($cert.NotAfter - $now).TotalDays)
            $row.상태 = if ($cert.NotAfter -lt $now) { '만료' } elseif ($left -lt $WarnDays) { '곧 만료' } elseif ($cert.NotBefore -gt $now) { '아직 시작 전' } else { '정상' }
            $row.'남은 일수' = $left
            $row.만료일 = $cert.NotAfter.ToString('yyyy-MM-dd HH:mm')
            $row.시작일 = $cert.NotBefore.ToString('yyyy-MM-dd')
            $row.주체 = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
            $row.발급자 = $cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true)
            $row.'인증서 경고' = Get-PolicyText $got.Policy
            $row.지문 = $cert.Thumbprint
            $cert.Dispose()
        } catch {
            $row.상태 = '확인 못 함'
            $row.'인증서 경고' = Get-ErrorText $_.Exception
        }
        [pscustomobject]$row
    })

$rows = @($rows | Sort-Object { if ($_.'남은 일수' -is [int]) { $_.'남은 일수' } else { [int]::MinValue } })
Show-Table $rows @('이름', '주소', '포트', '상태', '남은 일수', '만료일', '주체', '발급자', '인증서 경고')
$summary = @($rows | Group-Object 상태 | ForEach-Object { "$($_.Name) $($_.Count)" })
Write-Host ($summary -join ' · ')
if ($SaveCsv) {
    $out = Get-OutputPath '인증서만료' '.csv'
    $rows | Export-Csv -LiteralPath $out -Encoding utf8BOM -NoTypeInformation
    Write-Host "저장: $out"
}

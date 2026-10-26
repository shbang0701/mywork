# scripts

복사 한 번으로 끝나는 PowerShell 7 스크립트입니다. 규칙은 [AGENTS.md](../AGENTS.md)에 있습니다.

## 분류

스크립트가 생기면 그때 폴더를 만듭니다.

- `office/` — Excel·Word·PPT 만들기·채우기 (COM)
- `files/` — 파일·폴더 정리, 이름 바꾸기, 비교
- `system/` — PC·환경 확인 (디스크, 설치 프로그램, 설정)
- `network/` — 연결·포트 확인
- `text/` — 로그·텍스트 가공

## 새 스크립트 만들기

1. [_template.ps1](_template.ps1)을 복사해서 시작합니다.
2. 이름은 `동사-명사.ps1`로 짓습니다 (예: `Export-SheetList.ps1`, `Get-DiskUsage.ps1`).
   동사는 PowerShell 표준 동사를 씁니다: Get, Set, New, Export, Import, Convert, Find, Test 등.
3. 실행할 때마다 바뀌는 값은 `param`으로 받고, 줄 끝 주석으로 설명합니다. WorkTool 업무 탭이 이것으로 입력 폼을 만듭니다. 약속은 [업무 탭 설계](../docs/plans/workflows-design.md) 「스크립트 약속」에 있습니다.
4. 아래 **목록**과 루트 [README.md](../README.md)에 한 줄씩 추가합니다.

## 업무 PC에서 실행하기

1. GitHub에서 파일 전체를 복사해, 업무 PC에 같은 이름으로 저장합니다 (UTF-8).
2. 맨 위 **설정** 블록만 고칩니다.
3. `pwsh`에서 `.\스크립트이름.ps1`로 실행합니다.
   - 도움말 보기: `Get-Help .\스크립트이름.ps1 -Examples`
   - 저장하지 않고 할 일만 보기: `.\스크립트이름.ps1 -WhatIf`
4. WorkTool 새 버전이 있으면 스크립트를 `문서\WorkTool\scripts`(업무 탭의 「내 스크립트」)에 저장합니다. [폴더 추가] 없이 업무 탭에 보이고, param이 입력 칸이 되어 폼으로 실행합니다. 자주 쓰는 값은 업무로 저장합니다.

결과 파일(CSV)은 스크립트 옆 `output` 폴더에 날짜가 붙은 새 이름으로 저장합니다. Excel 2016에서 한글이 깨지지 않게 UTF-8(BOM)으로 씁니다. 실제 결과 · 대상 목록은 저장소에 올리지 않습니다(`.gitignore`).

## 바로 쓰는 예제

관리자 권한 없이 돌고, 원본을 지우거나 덮어쓰지 않습니다. 파일을 바꾸는 것은 `Rename-FileBatch.ps1` 하나이고, 업무 탭의 [미리보기] 버튼(콘솔에서는 `-WhatIf`)으로 먼저 확인합니다.
권한 · 잠금 때문에 읽지 못한 폴더 · 파일 · 로그가 있으면 「없음」 · 「모두 같음」으로 결론 내지 않습니다. 읽지 못한 자리를 보이고 실패로 끝나서(종료 코드 1) 업무 탭에 「실패」로 남습니다. 읽은 부분의 결과는 「부분 완료」로 같이 보입니다.

**사무 (`files/`)**
- [Rename-FileBatch.ps1](files/Rename-FileBatch.ps1) — 폴더 안 파일 이름을 한꺼번에 바꿉니다: 앞 · 뒤에 날짜, 찾아 바꾸기, 번호 매기기. 같은 이름이 되는 파일은 건너뜁니다. 바꾸기 전에 할 일을 기록 CSV에 「예정」으로 먼저 적고 하나 바꿀 때마다 결과를 이어 적어서, 도중에 끝나도 어디까지 바뀌었는지 남습니다. 기록을 못 만들면 아무것도 바꾸지 않습니다.
- [Find-OldLargeFile.ps1](files/Find-OldLargeFile.ps1) — 큰 파일 · 오래 안 고친 파일을 크기 순으로 보이고 CSV로 저장합니다 (공유 폴더 정리).
- [Find-DuplicateFile.ps1](files/Find-DuplicateFile.ps1) — 크기 → 해시(SHA-256) 순으로 내용이 똑같은 파일을 묶음별로 찾습니다.
- [Compare-Folder.ps1](files/Compare-Folder.ps1) — 두 폴더를 견줘 한쪽에만 있는 파일 · 다른 파일을 보입니다. 기본은 크기 · 고친 시각, `-CompareHash`면 내용까지.

**IT 운영 (`network/` · `system/`)**
- [Test-TcpPort.ps1](network/Test-TcpPort.ps1) — 여러 서버 · 포트에 동시에 TCP 연결해 열림 · 닫힘 · 시간 초과를 보입니다. 대상은 칸에 쉼표로 적거나 스크립트 옆 `tcp-targets.txt`에 `이름 주소:포트/포트`로 적습니다.
- [Get-CertificateExpiry.ps1](network/Get-CertificateExpiry.ps1) — HTTPS 서버 인증서의 만료일 · 남은 일수를 보이고 곧 끝나는 것을 알립니다. 사설 인증서도 읽습니다. 목록 파일은 `cert-targets.txt`.
- [Get-DiskSpace.ps1](system/Get-DiskSpace.ps1) — 로컬 · 네트워크 드라이브와 공유 폴더(`\\fileserver\share`)의 전체 · 남은 용량, 모자라는 곳.
- [Get-EventLogError.ps1](system/Get-EventLogError.ps1) — 최근 N시간 System · Application 로그의 오류 · 경고를 원본 · ID별로 묶어 많은 순으로 보이고, 하나하나는 CSV로 저장합니다.

**IT 개발 (`text/` · `network/`)**
- [Find-LogPattern.ps1](text/Find-LogPattern.ps1) — 로그 파일들에서 정규식을 찾아 파일별 · 찾은 글자별(예: 오류 코드) 개수를 세고 찾은 줄을 CSV로 저장합니다. UTF-8 · CP949 로그를 알아서 읽고, 잘못 고르면 `Encoding` 칸으로 직접 정합니다. `CaseSensitive`면 ERROR · error를 따로 셉니다.
- [Get-PortProcess.ps1](network/Get-PortProcess.ps1) — 어느 프로그램(PID · 서비스)이 어느 포트를 쓰는지 보입니다 ("포트가 이미 사용 중" 확인).

## 목록

- [office/New-OfficeTestFile.ps1](office/New-OfficeTestFile.ps1) — Office를 띄우지 않고 .NET만으로 xlsx · docx · pptx 시험 파일을 만듭니다. 기본은 내 문서, `-Type`으로 형식, `-OutFolder`로 기존 폴더, `-Open`으로 만든 파일 열기를 고릅니다.
- [network/Watch-MultiPing.ps1](network/Watch-MultiPing.ps1) — 여러 서버에 ping을 계속 보내 응답 · 끊김을 한 화면에 보여 주고, 상태가 바뀐 시각을 CSV로 남깁니다. ping이 막힌 서버는 `주소:포트`로 적어 TCP 연결로 확인합니다.
  - 대상 목록은 스크립트 옆 `ping-hosts.txt`에 한 줄에 하나씩 `이름 주소`로 적습니다. Excel에서 이름 · 주소 두 열을 복사해 붙여 넣어도 됩니다.

    ```text
    # 점검 대상 (# 뒤는 메모)
    SRV-01       10.0.0.10
    SRV-01-iLO   10.0.1.10
    SRV-02       10.0.0.11:22    # ping이 막혀 SSH 포트로 확인
    ```
  - 실행 기록은 `ping-logs\ping_<날짜_시각>.csv`, 끝내면 `..._요약.csv`가 생깁니다. Q 또는 Esc로 끝냅니다.
  - 실제 목록 · 기록은 저장소에 올리지 않습니다(`.gitignore`).

# 업무 작업 공간

회사 업무 PC에서 쓰는 PowerShell 스크립트, GUI 앱, 운영 문서 모음입니다.
환경·보안·코드 규칙은 [AGENTS.md](AGENTS.md)에 있습니다.

## 구성

- **[scripts/](scripts/)** — 복사 한 번으로 끝나는 단독 PowerShell 스크립트. 새로 만들 때는 [scripts/README.md](scripts/README.md)
  - [network/Watch-MultiPing.ps1](scripts/network/Watch-MultiPing.ps1) — 여러 서버에 ping(또는 TCP 포트)을 계속 보내 응답 · 끊김을 한 화면에 보고, 바뀐 시각을 CSV로 남김 (점검 · 재부팅 확인용)
  - 바로 쓰는 예제 (WorkTool 업무 탭에서 폼으로 실행, zip에도 들어 있음)
    - 사무: [files/Rename-FileBatch.ps1](scripts/files/Rename-FileBatch.ps1) 이름 한꺼번에 바꾸기 · [files/Find-OldLargeFile.ps1](scripts/files/Find-OldLargeFile.ps1) 큰 · 오래된 파일 · [files/Find-DuplicateFile.ps1](scripts/files/Find-DuplicateFile.ps1) 중복 파일 · [files/Compare-Folder.ps1](scripts/files/Compare-Folder.ps1) 두 폴더 비교
    - IT 운영: [network/Test-TcpPort.ps1](scripts/network/Test-TcpPort.ps1) TCP 포트 확인 · [network/Get-CertificateExpiry.ps1](scripts/network/Get-CertificateExpiry.ps1) 인증서 만료일 · [system/Get-DiskSpace.ps1](scripts/system/Get-DiskSpace.ps1) 디스크 · 공유 폴더 용량 · [system/Get-EventLogError.ps1](scripts/system/Get-EventLogError.ps1) 이벤트 로그 오류 · 경고
    - IT 개발: [text/Find-LogPattern.ps1](scripts/text/Find-LogPattern.ps1) 로그에서 패턴 찾기 · 세기 · [network/Get-PortProcess.ps1](scripts/network/Get-PortProcess.ps1) 포트를 쓰는 프로그램
- **[apps/design.md](apps/design.md)** — 모든 GUI 앱의 공통 디자인 원칙 (Windows 디자인 지침 기반)
- **[worktool.zip](worktool.zip)** — WorkTool 새 버전(WPF)을 바로 실행하는 묶음. 압축을 풀고 `Start-WorkTool.cmd`를 더블클릭 (개인 PC용, 아래 「업무 PC로 가져가기」 참고). 예제 `scripts\`가 같이 들어 있어 업무 탭에 바로 보입니다
  - 실행 보조 파일 원본: [start-worktool.cmd](apps/WorkTool/wpf/build/start-worktool.cmd) · [start-launcher.ps1](apps/WorkTool/wpf/build/start-launcher.ps1). 시작 뒤 콘솔 창을 남기지 않습니다.
  - 저장소를 받아 둔 PC는 zip 대신 [start-dev.cmd](apps/WorkTool/wpf/start-dev.cmd)를 더블클릭 — 원본을 바로 띄워서 고친 내용이 바로 보입니다.
  - [실행 파일 검사](apps/WorkTool/wpf/tests/Test-Launcher.ps1) — 임시 전용 GUI로 콘솔 없는 실행·아이콘·특수문자 경로·시작 오류와 `start-dev.cmd`를 검사합니다.
- **[apps/WorkTool/](apps/WorkTool/)** — 업무 통합 GUI 앱 (메모 · 근태 · 일정·알람, 트레이 상주)
  - [design/](apps/WorkTool/design/) — 새 화면 시안 (WPF 전환 기준)
    - [활성 작업 목업](apps/WorkTool/design/README.md#활성-작업-목업) — 프로그램별 창·브라우저 탭 표, 선택 닫기. 폰용 확대본·자동 새로 고침 설정·가짜 데이터·목업 생성 스크립트 포함
    - [사용자 구성 업무 목업](docs/plans/workflows-preview.md) — 요청 처리·자료 작성·서버 점검의 구성 → 사용 → 모의 결과. 설정 변경 비교, 가짜 JSON, 내부 API·알람 연동 제안 포함. 앱 기능은 미구현
    - [직접 조작하는 업무 체험 HTML](apps/WorkTool/design/workflows-playground.html) — 파일 하나로 폼·단계·값 연결을 편집하고 모의 실행·취소·알람·이력을 확인합니다. [입력 이미지](apps/WorkTool/design/workflows-playground-use.jpg) · [결과 이미지](apps/WorkTool/design/workflows-playground-result.jpg) 포함. 기존 앱과 연결하지 않습니다
  - [wpf/](apps/WorkTool/wpf/) — 새 버전(WPF): 마크다운 메모 · 문서 · **활성 작업**(창·Chrome/Edge/웨일 탭 조회, 선택 닫기, 분 단위 자동 새로 고침) · **업무**(스크립트 폴더의 스크립트를 폼으로 실행 · 기록, [설계](docs/plans/workflows-design.md)). 파일 하나 버전은 `apps/WorkTool/dist/WorkTool-WPF.ps1`
    - 탭 하나 = `addons/<이름>/` 폴더 하나입니다. 탭의 도움말 · 단축키 · 검사(`Test-*.ps1`)도 그 폴더에 있어서, 폴더를 더하거나 지우는 것으로 탭을 더하고 뺍니다. 방법은 [WPF README](apps/WorkTool/wpf/README.md#탭애드온-더하기--빼기)
    - [전체 검사](apps/WorkTool/wpf/tests/Test-Core.ps1) — 코어 검사, 모든 탭을 함께 불러 겹침 확인, 탭 폴더의 검사, [셸 · 저장 안정성 검사](apps/WorkTool/wpf/tests/Test-Reliability.ps1)(중복 실행 차단, 저장 실패 때 묻는 흐름, 응답 없는 공유 폴더를 흉내 낸 데이터 폴더 · 끝낼 때 남은 작업), 실행 파일 검사를 차례로 돌립니다.
    - [경량 성능 확인](apps/WorkTool/wpf/tests/Measure-WtPerformance.ps1) — 창 표시 없이 CPU·시간 예산 안에서 화면 구성 비용을 확인합니다. A~H 전체 판정은 하지 않습니다. [사용법](apps/WorkTool/wpf/README.md#성능-설정과-측정)
- **[docs/guides/](docs/guides/)** — 읽는 가이드
  - [productivity/](docs/guides/productivity/) — 업무 효율·작업 환경
    - [갤럭시 S26 울트라 앱별 키보드 가이드](docs/guides/productivity/galaxy-s26-ultra-app-keyboard-guide.md)
    - [PowerShell 7 · Solarized Light 다듬기 가이드](docs/guides/productivity/powershell-solarized-light-guide.md)
  - ops/ — 운영 노하우·장애 대응 (아직 없음)
- **[docs/plans/](docs/plans/)** — 설계 메모·제안서
  - [업무 탭 설계](docs/plans/workflows-design.md) — 업무 기능은 `scripts/`의 스크립트 하나로 만들고, 업무 탭은 그 스크립트를 폼으로 실행·기록하는 틀. 기능 추가·수정·삭제가 파일 하나로 끝나게 하는 규칙과 스크립트 약속
  - [업무 탭 사용법과 결과 미리보기](docs/plans/workflows-preview.md) — 관련 그림은 `apps/WorkTool/design/workflows-*.svg`·`.png`, 원본은 `workflows-sample.json`, 결과는 `workflows-results.json`, 생성기는 `build-workflows-mockups.ps1`
- **[docs/templates/](docs/templates/)** — 받아서 쓰는 Office 양식
  - [infra-kit/](docs/templates/infra-kit/) — IT 인프라 문서 세트: 장비 도면(Excel), PPT 구성 요소, 아이콘 60종
  - [rhel-config/](docs/templates/rhel-config/) — RHEL 계열 7·8·9 서버 구성표

## 업무 PC로 가져가기

흔적이 남지 않는 방법은 없습니다. 복붙해도 실행한 코드는 PowerShell 기록에 남을 수 있습니다.
그래서 **가져오는 방법보다 코드 내용이 설명되는지가 중요**하고, 그중에서 보안 장비가 덜 민감하게 보는 방법을 씁니다.

**스크립트·문서(텍스트): 복사해 붙여 넣기 (기본)**
- 파일을 열고 오른쪽 위 복사 아이콘(Copy raw file) → 업무 PC에서 같은 이름으로 저장
- 새 WorkTool의 메모·문서·활성 작업은 `apps/WorkTool/dist/WorkTool-WPF.ps1` 전체를 복사합니다.
- 기존 WinForms의 일정 편집·알람·근태 입력을 계속 쓸 때는 `apps/WorkTool/dist/WorkTool.ps1`을 복사합니다. 두 버전의 차이는 [WPF README](apps/WorkTool/wpf/README.md)에 있습니다.

**개인 PC: worktool.zip**
- 저장소를 받아 둔 PC(`git clone`)는 zip이 필요 없습니다. `apps/WorkTool/wpf/start-dev.cmd`를 더블클릭합니다.
- 받은 `worktool.zip` 우클릭 → 속성 → 「차단 해제」 체크 → 압축 풀기 → `Start-WorkTool.cmd` 더블클릭
- 차단 해제를 안 하면 인터넷에서 받은 스크립트라 실행 정책(RemoteSigned)에 막힙니다. 실행 파일이 이 경우를 알려 줍니다.
- 업무 PC에는 쓰지 않습니다. 스크립트가 든 zip은 보안 장비가 가장 민감하게 봅니다 (아래 「쓰지 않는 것」). 업무 PC는 `WorkTool-WPF.ps1`을 복사해 붙여 넣습니다.

**Excel·PPT 양식: 파일 하나씩 다운로드**
- 파일을 열고 오른쪽 위 다운로드 아이콘(Download raw file)

**쓰지 않는 것**
- ZIP 통째 다운로드: 스크립트가 든 압축 파일은 보안 장비가 가장 민감하게 보고, 풀어도 실행이 막힐 수 있습니다.
- git 새로 설치: 승인되지 않은 프로그램 설치가 됩니다. 회사에서 이미 git을 업무에 쓰고 있을 때만 `git clone` / `git pull`을 씁니다.

## 이름 규칙

- 폴더·파일 이름은 영문 소문자와 하이픈으로 짓고, 설명은 한글로 씁니다.
- 스크립트 이름은 `동사-명사.ps1` 형식입니다 (예: `Export-SheetList.ps1`).
- 양식 세트 안의 한글 파일 이름은 그대로 둡니다.
- 파일을 추가하거나 옮기면 위 **구성** 목록도 같이 고칩니다.

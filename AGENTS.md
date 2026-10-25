# AGENTS.md

회사 업무 PC에서 쓸 스크립트와 운영 문서를 모아 두는 개인 작업 공간이다.
사용자는 LLM과 **휴대폰으로** 대화하고, 코드는 업무 PC 브라우저에서 GitHub 화면을 열어 **복사해 붙여 넣어** 쓴다.

## 저장소 구조

- `scripts/<분류>/` — 단독 스크립트. 분류는 `office/` · `files/` · `system/` · `network/` · `text/`. 새 스크립트는 `scripts/_template.ps1`에서 시작한다.
- `apps/<이름>/` — 여러 파일로 된 앱. 지금은 `apps/WorkTool/`뿐이다. WinForms 버전(지금 쓰는 것)은 그 폴더 바로 아래, WPF 새 버전은 `apps/WorkTool/wpf/`에서 만드는 중이다(구조 · 탭 더하는 법은 `apps/WorkTool/wpf/README.md`).
  - `apps/design.md`: 모든 GUI 앱의 공통 디자인 원칙. 구체적인 값은 앱별 디자인 문서(`apps/<이름>/design/README.md`)가 우선한다.
- `docs/guides/<분류>/` — 읽는 문서(.md).
  - `productivity/`: 업무 효율·작업 환경
  - `ops/`: 운영 노하우·장애 대응
- `docs/plans/` — 설계 메모 · 제안서(.md).
- `docs/templates/<이름>/` — 받아서 쓰는 Office 양식.
  - `infra-kit/`: 장비 도면·PPT·아이콘. `_build/`로 생성한다.
  - `rhel-config/`: RHEL 구성표
- 폴더·파일 이름은 영문 소문자와 하이픈으로 짓는다. 스크립트는 `동사-명사.ps1`. 양식 세트 안의 기존 한글 파일 이름은 그대로 둔다.
- 파일을 추가하거나 옮기면 루트 `README.md`의 구성 목록도 같이 고친다.

## 업무 PC 환경

- Windows + **PowerShell 7.6.6** (`pwsh`). Windows PowerShell 5.1 기준으로 쓰지 않는다.
- **Office 2016** (Excel · Word · PowerPoint). Microsoft 365 / 2019 이후 기능은 쓰지 않는다.
  - 쓰지 않는 함수: XLOOKUP, FILTER, UNIQUE, SORT, LET, TEXTJOIN, CONCAT, IFS, SWITCH, MAXIFS, MINIFS
  - 쓰지 않는 기능: SVG 삽입(PPT에는 도형 아이콘), 동적 배열
- 회사 Office 파일에는 **DRM**이 걸려 있다. 암호화되어 있어서 Office 프로그램으로만 열린다.
- 보안 검사가 엄격하다. 문제가 생기면 해명할 게 많아진다. 인터넷(GitHub 열람)은 되지만 프로그램 설치나 외부 패키지는 쓰지 않는다.

## 코드 규칙

1. **기본 기능만 쓴다.** PowerShell 내장 명령 + .NET + Office COM만 쓴다. PSGallery 모듈, NuGet, Python 패키지, exe를 내려받지 않는다.
2. **스크립트 하나 = 파일 하나.** 다른 파일을 불러오지 않고, 한 번 복사로 끝나게 만든다. 여러 파일로 된 앱은 예외로 둔다.
3. **맨 위 구성:** 주석 도움말(`.SYNOPSIS`, `.EXAMPLE`)을 두고, 그 아래 **설정 블록**에 경로, 시트 이름, 열 위치를 모은다. 사용자가 고칠 곳은 설정 블록뿐이어야 한다. LLM은 실제 문서를 볼 수 없으므로, 문서 구조는 설정 값으로 빼 둔다. `#Requires`는 도움말 블록 아래에 둔다. 위에 두면 `Get-Help`가 도움말을 못 읽는다. 새 스크립트는 `scripts/_template.ps1`을 복사해서 시작한다.
   - 실행할 때마다 바뀌는 값(대상 목록 파일 · 서버 이름 · 공유 폴더 이름 등)은 `param`으로 받고, `.PARAMETER`나 param 줄 끝 주석으로 설명한다. WorkTool 업무 탭이 이것을 읽어 입력 폼을 만든다. 약속 전체는 `docs/plans/workflows-design.md` 「스크립트 약속」에 있다.
4. **해명하기 어려운 동작은 쓰지 않는다.**
   - 내려받아 바로 실행(`iwr | iex`), `Invoke-Expression`, `-EncodedCommand`, Base64로 감춘 코드
   - 실행 정책 변경이나 우회(`-ExecutionPolicy Bypass`), 백신·방화벽·UAC 설정 변경, 관리자 권한이 필요한 작업
   - 인라인 C#(`Add-Type -TypeDefinition`, P/Invoke), 키보드 후킹, 화면 캡처, 클립보드 감시. 단, `Add-Type -AssemblyName`으로 기본 어셈블리를 불러오는 것은 괜찮다.
   - 자동 실행 등록(레지스트리 Run, 작업 스케줄러, 시작프로그램). 필요하면 사용자가 직접 하도록 방법만 안내한다.
   - 외부로 데이터를 보내는 통신 일체(업로드, 웹훅, 메일 발송)
5. **Office는 COM으로 다룬다.** `try/finally`에서 `Quit()`과 `ReleaseComObject`를 호출해 EXCEL.EXE가 남지 않게 한다. 셀 값은 2차원 배열로 한 번에 읽고 쓴다.
6. **DRM 문서 내용을 평문으로 빼내는 기능**(CSV, TXT, PDF 변환 등)은 만들기 전에 사용자에게 먼저 확인한다.
7. **원본은 덮어쓰지 않는다.** 결과는 새 파일로 저장하고, 파일 이름에 날짜를 넣는다.
8. **인코딩:** `.ps1`은 UTF-8로 저장한다. Excel 2016에서 열 CSV는 `-Encoding utf8BOM`으로 저장한다(BOM이 없으면 한글이 깨진다).

## 저장소 규칙

- 이 저장소는 **공개(public)**다. 업무 PC에서는 로그인하지 않고 보기 때문에 앞으로도 공개로 둔다.
- **회사 고유 정보는 넣지 않는다.** 회사·고객 이름, 실제 호스트명·IP·계정, 내부 시스템 이름, 직원 이름, 실제 문서 내용이 해당한다. 예시에는 `SRV-01`, `10.0.0.10` 같은 가짜 값을 쓴다.
- **에이전트도 같이 확인한다.** 사용자가 보낸 내용에 회사 고유 정보로 보이는 것이 있으면, 저장소에 넣기 전에 가짜 값이나 설정 값으로 바꾸고 바꿨다는 사실을 한 줄로 알린다.
- **실제 환경은 로컬 `.work/env.md`에만 둔다.** 업무 PC · 서버 · 파일 서버 · 보고 양식처럼 작업에 필요한 실제 환경은 이 파일(`.gitignore` 대상)에 적는다. 로컬에서 작업할 때는 먼저 읽고, 저장소에는 가짜 값이나 설정 값으로 바꿔 쓴다. 파일이 없거나(클라우드 세션 등) 필요한 내용이 없으면 사용자에게 묻는다.
- **가린다고 품질을 낮추지 않는다.**
  - 기능을 빼거나 일반론으로 뭉개지 않는다. 실제 값이 필요한 자리는 설정 블록이나 로컬 설정 파일(`.gitignore` 대상)로 빼서, 값만 넣으면 그대로 동작하게 만든다.
  - 제품명과 일반 용어(RHEL, AD, Exchange, VMware, NAS, DMZ 등)는 회사 정보가 아니므로 그대로 쓴다.
- **업무 PC에서 이 저장소로는 아무것도 올리지 않는다.** 흐름은 GitHub → PC 한 방향뿐이다. PC는 로그인하지 않으므로 push도 원래 되지 않는다.
- **업무 PC로 가져가는 방법:** 텍스트(스크립트·문서)는 복사해 붙여 넣기가 기본이고, Excel·PPT 양식은 파일 하나씩 내려받는다. ZIP 통째 다운로드는 쓰지 않고, `git clone`은 회사에서 이미 git을 쓰는 경우에만 쓴다. 그래서 경로는 항상 `$PSScriptRoot` 기준 상대 경로로 쓰고, 설치 위치를 가정하지 않는다.
- `docs/templates/infra-kit/`의 결과 파일(xlsx, pptx, pdf, 아이콘)은 직접 고치지 않고 `_build/` 소스를 고친 뒤 다시 만든다. `_build/`의 Python은 클라우드에서만 돌리고, 업무 PC에서는 쓰지 않는다.

## 작업별로 먼저 읽을 것 · 쓰는 스킬

작업 주제에 맞는 항목의 문서와 스킬만 쓴다. 세션에 다른 스킬이 보여도 아래 주제에는 쓰지 않는다. 필요한 스킬이 세션에 없으면 흉내 내지 말고 작업 전에 알린다.

- **업무 PC용 스크립트**: `scripts/_template.ps1`, 위 「코드 규칙」. 업무 탭에서 실행할 스크립트면 `docs/plans/workflows-design.md` 「스크립트 약속」도 읽는다.
- **GUI 화면** (만들기 · 고치기 · 검토): `apps/design.md`를 끝까지 읽고, 앱 디자인 문서(WorkTool: `apps/WorkTool/design/README.md`)의 값만 쓴다. 새 값이 필요하면 앱 디자인 문서에 먼저 추가한다. 문서에 없는 것은 Windows 기본 컨트롤(Fluent) 동작을 따르고, 끝내기 전에 `apps/design.md` 「완료 전 점검」을 확인한다.
  - 스킬: `ui-ux-pro-max`(점검 도구로만, 쓰는 범위는 스킬 안 「이 저장소에서 쓸 때」)
  - 쓰지 않음: `dataviz` · `artifact-design` · `frontend-design` · `theme-factory` · `brand-guidelines`, 아티팩트로 만든 시안. 시안은 「목업 · 미리보기」대로 git에 올린다.
- **Excel · PPT · PDF · Word** (`docs/templates/infra-kit/`): 그 폴더의 `README.md`
  - 스킬: `infra-design`(디자인 기준 · 만들기 규칙), `xlsx` · `pptx` · `pdf` · `docx`(읽기 · 검수)
  - 쓰지 않음: 슬라이드 · 문서 아티팩트, pptxgenjs, `dataviz`(차트 색도 `P`), 결과 파일만 직접 고치기
- **아이콘 SVG**: 스킬 없이 `docs/templates/infra-kit/_build/icons.py` · `icondsl.py`. 외부 아이콘 세트 · 이미지 생성은 쓰지 않는다.
- **저장소 Markdown 문서** (README · `apps/design.md` · AGENTS.md · 설계 메모 · 제안서 · 가이드): 오타 · 한두 줄이 아니면 `doc-writing`. Claude Docs(`anthropic-skills:docs`) · 아티팩트로 만들지 않는다. 형식을 말하지 않은 저장소 관련 문서 요청도 저장소 Markdown으로 쓴다.
- **스킬 위치**: `infra-design` · `ui-ux-pro-max` · `doc-writing`은 저장소 `.claude/skills/`(로컬 · 클라우드 모두 자동). `xlsx` · `pptx` · `pdf` · `docx`는 로컬이면 `.claude/settings.json`의 `document-skills` 플러그인, 클라우드면 계정의 `anthropic-skills:*`.

## 앱(GUI) 원칙

기능을 넣고 빼거나 디자인을 바꿀 때 한 곳만 고치면 되도록 만든다.

- **WT·WorkTool 성능 측정은 실행 전에 사용자에게 묻고 명시적인 허락을 받는다.** 자동 창 전환·활성화가 사용자의 마우스 작업을 방해할 수 있으므로, 이번 실행의 범위와 횟수를 먼저 알린다.
- **탭(화면) 하나 = 폴더 하나.** 탭의 모듈 · 도움말 · 단축키 · 검사를 탭 폴더(WPF: `apps/WorkTool/wpf/addons/<이름>/`) 하나에 두고, 탭을 더하거나 빼는 코드는 그 폴더로 끝낸다. 코어 · 다른 탭 · 검사 목록 · 묶음 만들기 스크립트는 고치지 않는다(묶음 파일은 다시 만든다).
- **코어에는 탭 이름을 쓰지 않고, 탭끼리 서로 부르지 않는다.** 탭 사이 연결은 홈 카드 · 도움말처럼 코어의 등록 목록을 거친다. 탭이 필요한 코어 검사는 가짜 탭으로 한다.
- **업무 탭의 기능은 앱이 아니라 `scripts/`의 스크립트로 더한다.** 기능 하나 = 스크립트 하나다(`docs/plans/workflows-design.md`).
- **모양은 공통 UI 모듈에서만 정한다.** 색, 글꼴, 크기, 간격, 컨트롤 모양이 해당한다. 기능 모듈에 색 값이나 글꼴 이름을 직접 쓰지 않는다. 탭에 새 모양이 필요하면 공통 UI 모듈에 쓰임새 이름으로 더한다(탭 폴더 하나 규칙의 유일한 예외).
- **저장은 저장 모듈만 거친다.** 기능 모듈은 파일을 직접 읽고 쓰지 않는다.
- 사용자 데이터와 로컬 설정은 커밋하지 않는다. WinForms는 `data/` · `config.json`, WPF는 데이터 폴더(기본 `문서\WorkTool`, 저장소 밖)다.
- **여러 파일로 된 앱은 복사 한 번으로 가져가도록 파일 하나로 묶은 버전도 둔다.** 원본을 고친 뒤 묶음을 다시 만들어 같은 커밋에 넣는다. 묶음 파일은 직접 고치지 않는다.
  - WorkTool(WinForms): `pwsh apps/WorkTool/build/Build-Bundle.ps1` → `apps/WorkTool/dist/WorkTool.ps1`
  - WorkTool 새 버전(WPF): `pwsh apps/WorkTool/wpf/tests/Test-Core.ps1`이 모두 통과한 뒤 `pwsh apps/WorkTool/wpf/build/Build-Bundle.ps1` → `apps/WorkTool/dist/WorkTool-WPF.ps1` · 맨 위 `worktool.zip`(개인 PC 실행용)

## 답변 방식

- 사용자는 휴대폰으로 읽는다. 짧게 쓰고, 넓은 표 대신 목록을 쓴다.
- **위치는 글과 링크를 같이 준다.** 사용자는 폰에서는 링크를 눌러 보고, 업무 PC에서는 글로 된 위치를 보고 GitHub를 직접 찾아 들어간다. 둘 중 하나만 주지 않는다.
  - 파일: 브랜치 이름 + 저장소 루트 기준 경로, 그리고 링크. 예: 브랜치 `main` · `apps/WorkTool/design/README.md` ([열기](https://github.com/shbang0701/claude-test/blob/main/apps/WorkTool/design/README.md))
  - 이슈·PR: 저장소 → 탭 이름 → 번호와 제목, 그리고 링크. 예: `shbang0701/claude-test` → Issues 탭 → #8 「WorkTool 개편 계획 · 결정할 것」 ([열기](https://github.com/shbang0701/claude-test/issues/8))
- **커밋하고 푸시했으면** 브랜치 이름, 커밋 해시, 바뀐 파일 경로를 모두 적는다. 기본 브랜치가 아닌 곳에 올렸으면 그 사실도 알린다. GitHub 첫 화면에는 기본 브랜치만 보인다.

  ```
  브랜치: main
  커밋:   e0cbe83
  경로:   AGENTS.md
          docs/guides/productivity/powershell-solarized-light-guide.md
  ```
- 코드를 고쳤으면 **복사할 파일**을 위 형식(브랜치 이름 + 경로)으로 알려 준다. 사용자는 고친 부분만이 아니라 파일 전체를 다시 복사한다.

## 목업 · 미리보기

- 목업, 미리보기, 다이어그램, 스크린샷처럼 문서를 이해하는 데 필요한 시각 자료는 채팅으로만 보여 주지 말고 **문서와 같은 커밋에 함께** 올린다.
- 위치는 문서와 같은 폴더의 `mockups/`다. 앱 화면 시안은 `apps/<이름>/design/`에 둔다. 파일 이름만 봐도 어느 문서용인지 알 수 있게 짓는다. 예: `powershell-solarized-light-preview.svg`
- 형식은 **SVG를 우선**한다. GitHub, VS Code, 브라우저에서 바로 보인다. 필요하면 PNG를 쓴다.
- 문서(md)에는 상대 경로로 넣고, 파일 경로도 글로 한 번 적는다: `![설명](mockups/파일.svg)`
- 업무 PC에서 그대로 열리도록 **외부 리소스 없이 파일 하나로 완결**한다. CDN 스크립트, 웹 폰트, 외부 이미지 링크를 쓰지 않는다.
- 원본 자료(붙여 넣은 다른 답변 등)에 미리보기가 있었다면 지우지 말고 목업 파일로 다시 만든다.

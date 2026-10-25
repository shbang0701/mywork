# 시안 A · Windows 11 네이티브

Windows 설정 앱 · 메모장처럼 보이는 WorkTool입니다.
회사 PC의 다른 Windows 기본 앱 옆에 두어도 이질감이 없게 만듭니다.

## 그림

- 홈: `home-light.png` ([열기](home-light.png))
- 메모: `memo-light.png` ([열기](memo-light.png))
- 일정 (월 달력 + 근태 + 휴무일): `schedule-light.png` ([열기](schedule-light.png))
- 업무: `workflows-light.png` ([열기](workflows-light.png))
- 홈 · 어두운 테마: `home-dark.png` ([열기](home-dark.png))

SVG 원본은 같은 이름의 `.svg`입니다. 모두 1280 × 800, 가짜 내용입니다.

## 지금 디자인 진단

- 모든 것이 모서리 12의 카드로 떠 있고 카드 사이를 16씩 띄웁니다. 업무 도구보다 웹 대시보드처럼 보이고 자리를 버립니다.
- 크기가 Windows 체계와 어긋납니다. 제목 26 Bold · 보조 12.5 · 컨트롤 40 · 모서리 8이라 컨트롤이 뭉툭하고 화면이 성깁니다.
- 파스텔 틴트가 창 바탕 · 메뉴 · 선택에 다 스며서 층이 색으로만 나뉩니다. 강조색이 장식처럼 퍼집니다. 다크 모드는 없습니다.
- 명령의 위계가 흐립니다. 테두리 버튼이 많고, 실행 위치 고르기가 탭처럼 생겼고, 비활성 링크가 흐릿하게 남아 있습니다.

## 방향

Fluent 2 / WinUI 3의 값과 모양을 그대로 따르고, 그림자 · Mica 대신 단색 면 3단과 1px 선으로 층을 만듭니다.

## 레퍼런스

- Fluent 2 Design System — https://fluent2.microsoft.design/ — 4px 간격 단계, 색을 쓰임새 이름으로 부르는 방식
- Windows 글자 · 모양 지침 — https://learn.microsoft.com/windows/apps/design/signature-experiences/typography · https://learn.microsoft.com/windows/apps/design/signature-experiences/geometry — 형식 단계 12/14/18/20/28, 모서리 4 · 8 · 0 규칙
- WPF Fluent 테마 (.NET 9) — https://github.com/dotnet/wpf/tree/main/src/Microsoft.DotNet.Wpf/src/Themes/PresentationFramework.Fluent — 실제 색 값(`#F3F3F3` · `#202020`, 글자 알파 E4 · 9E · 72)을 가져와 단색으로 환산
- WinUI 3 Gallery · NavigationView — https://github.com/microsoft/WinUI-Gallery · https://learn.microsoft.com/windows/apps/develop/ui/controls/navigationview — 왼쪽 메뉴(항목 36, 선택 막대 3 × 16, 맨 아래 설정), 내용 층의 왼쪽 위 둥근 모서리, 1008 · 641 기준 폭
- Windows 11 설정 앱 · SettingsCard — https://learn.microsoft.com/dotnet/communitytoolkit/windows/settingscontrols/settingscard — 아이콘 · 제목 · 설명 · 오른쪽 화살표 한 줄 카드, 카드 사이 4 (홈 「바로 가기」)
- PowerToys 설정 — https://github.com/microsoft/PowerToys — 도구형 앱의 왼쪽 메뉴 + 구역 제목 + 카드 묶음
- Windows 메모장 탭 · TabView — https://learn.microsoft.com/windows/apps/develop/ui/controls/tab-view — 선택 탭이 본문 면과 이어지는 모양, 탭 높이 32 · 위 모서리 8
- Microsoft To Do — https://to-do.office.com/ — 할 일 한 줄 · 체크 상자 · 간결한 목록 (메모 할 일, 홈 일정 행)

## 디자인 값

이름은 쓰임새 이름입니다. WPF 리소스 키로 그대로 씁니다(예: `B.Bg.Card`).

### 색 · 밝은 테마

- 바탕: `Bg.Base` `#F3F3F3` (제목 줄 · 왼쪽 메뉴) · `Bg.Layer` `#F9F9F9` (내용 층 · 목록 칸 · 주말 칸) · `Bg.Card` `#FFFFFF` (카드 · 편집 면) · `Bg.Raised` `#FFFFFF` (메뉴 · 대화상자) · `Bg.Sunken` `#F5F5F5` (코드 · 출력)
- 선: `Stroke.Card` `#E5E5E5` · `Stroke.Divider` `#EBEBEB` · `Stroke.Control` `#E0E0E0` · `Stroke.ControlEdge` `#CCCCCC` (버튼 아래 1) · `Stroke.Strong` `#8A8A8A` (입력칸 바닥선 · 체크 상자, 3.1:1 이상) · `Stroke.Flyout` `#C8C8C8` (떠 있는 면, 그림자 대신)
- 채움: `Fill.Control` `#FBFBFB` · `Fill.Input` `#FFFFFF` · `Fill.Hover` 검정 4% · `Fill.Selected` 검정 6%
- 글자: `Text.Primary` `#1B1B1B` · `Text.Secondary` `#545454` · `Text.Tertiary` `#666666` · `Text.Disabled` `#A0A0A0` (비활성만)
- 강조: `Accent` `#005FB8` (Windows 기본 파랑) · 마우스 올림 `#1A6FBF` · 누름 `#2677C3` · `Accent.Text` `#005FB8` · `OnAccent` `#FFFFFF`
- 상태 (글자 · 아이콘 / 연한 바탕): 정상 `#0E6F0E` / `#DFF6DD` · 주의 `#8F5400` / `#FFF4CE` · 장애 `#B92B1C` / `#FDE7E9` · 정보 `#005FB8` / `#F2F2F2` (정보 글자는 `Text.Primary`)
- 달력 종류 (막대 / 바탕): 일정 `#005FB8` / `#E6EFF8` · 휴가 · 개인 휴무 `#00696B` / `#DDF1F0` · 업무외 `#6B3FA0` / `#EFE8F8` · 공휴일 글자 `#B92B1C`

### 색 · 어두운 테마

- 바탕: `Bg.Base` `#202020` · `Bg.Layer` `#272727` · `Bg.Card` `#2D2D2D` · `Bg.Raised` `#2C2C2C` · `Bg.Sunken` `#232323`
- 선: `Stroke.Card` `#1C1C1C` · `Stroke.Divider` `#3A3A3A` · `Stroke.Control` `#3D3D3D` · `Stroke.Strong` `#9A9A9A` · `Stroke.Flyout` `#474747`
- 채움: `Fill.Control` `#373737` · `Fill.Input` `#323232` · `Fill.Hover` 흰색 5% · `Fill.Selected` 흰색 7%
- 글자: `Text.Primary` `#F0F0F0` (순수한 흰색은 쓰지 않음) · `Text.Secondary` `#C5C5C5` · `Text.Tertiary` `#A6A6A6` · `Text.Disabled` `#787878`
- 강조: `Accent` `#60CDFF` · 마우스 올림 `#5ABCE9` · 누름 `#53AAD2` · `OnAccent` `#000000`
- 상태: 정상 `#6CCB5F` / `#393D1B` · 주의 `#FCE100` / `#433519` · 장애 `#FF99A4` / `#442726` · 정보 `#60CDFF` / `#333333`
- 달력 종류: 일정 `#60CDFF` / `#1F3748` · 휴가 `#5FD4CB` / `#1E3A39` · 업무외 `#C9A9F2` / `#33284A` · 공휴일 `#FF99A4`

대비: 모든 글자 색이 그 색이 놓이는 모든 바탕(선택 덧칠 포함)에서 4.5:1 이상입니다. 가장 낮은 값은 밝은 `Text.Tertiary` 4.52, 어두운 `Text.Tertiary` 4.53입니다. 계산은 `_src/verify.py`에 있습니다.
Fluent 원래 값 중 3단 글자(`#8A8A8A`)와 상태 글자(`#0F7B0F` 등)는 AA가 모자라서 조금 진하게 바꿨습니다.

### 글꼴 (쓰임새 이름)

- `Font.UI` `Segoe UI Variable Text, Segoe UI, Malgun Gothic` — 기본
- `Font.Display` `Segoe UI Variable Display, Segoe UI, Malgun Gothic` — 20 이상 제목. WPF에서 모양이 다르면 `Font.UI`와 같게 둡니다
- `Font.Code` `Consolas, Malgun Gothic` — 코드 · 출력 · 호스트 이름 · IP
- `Font.Icon` `Segoe Fluent Icons, Segoe MDL2 Assets`
- 나중에 글꼴 고르기 설정은 이 네 이름의 값만 바꿉니다.

### 글자 크기 단계 (크기 / 줄 높이)

- `Caption` 12/16 보통 — 날짜 · 보조 정보 · 달력 칸 · 배지
- `Body` 14/20 보통 — 기본, 컨트롤
- `BodyStrong` 14/20 강조(600) — 카드 제목 · 표 머리글 · 목록 구역 제목
- `BodyLarge` 18/24 — 메모 제목 3단계
- `Subtitle` 20/28 강조 — 칸 제목 · 메모 제목 2단계 · 대화상자 제목
- `Title` 28/36 강조 — 화면 제목(화면당 하나) · 메모 제목 1단계 · 큰 숫자(출근 시각)
- `Code` 13/20 — 코드 · 출력
- 메모 본문은 14/22. 강조 굵기는 600 하나만 씁니다. 맑은 고딕은 600이 없어 한글은 Bold로 보입니다.

### 간격

- 단계: 4 · 8 · 12 · 16 · 24 · 32 · 48 (아이콘 맞춤용 2 예외)
- 화면 가장자리 24 (창 폭 1008 미만 16) · 카드 안쪽 16 · 맞붙은 칸 안쪽 12
- 카드 사이 12 · 같은 묶음의 행 카드 사이 4 · 구역 사이 24
- 라벨 → 입력칸 8 · 입력칸 → 도움말 4 · 폼 줄 사이 16 · 버튼 사이 8

### 모서리

- 4 — 버튼 · 입력칸 · 체크 상자 · 카드 · 목록 항목 바탕 · 배지 · 툴팁
- 8 — 창 · 메뉴 · 펼침 목록 · 대화상자 · 내용 층의 왼쪽 위 · 탭 위쪽
- 0 — 맞붙는 변(목록 칸과 편집 칸, 탭과 본문, 표 행), 최대화한 창
- 달력 칸 안 항목은 2 (높이 20이라 4는 너무 둥금)

### 크기

- 컨트롤 높이 32 (버튼 · 입력칸 · 고르기 칸)
- 제목 줄 32 · 창 버튼 46 × 32 · 탭 줄 40 (탭 32) · 도구 줄 40 · 표 행 32
- 목록 한 줄 40 · 두 줄 64 · 트리 항목 32 · 달력 칸 88 × 128
- 왼쪽 메뉴: 펼침 280 · 접힘 48 · 항목 36 (간격 4) · 선택 막대 3 × 16
- 창 폭 1008 미만이면 메뉴를 접고, 641 미만이면 겹쳐 띄웁니다 (NavigationView 기준)
- 아이콘: 메뉴 · 버튼 16, 목록 안 14, 작은 표시 10 ~ 12

## 화면별 메모

- 홈: 카드 2열(620 + 320). 오른쪽 아래 「바로 가기」는 설정 앱처럼 구역 제목 + 한 줄 카드 묶음입니다. 강조 버튼은 [퇴근 기록] 하나입니다.
- 메모: 목록 칸과 편집 칸을 맞붙이고 1px 선으로 나눕니다. 탭은 메모장 모양입니다. 고치는 블록은 원문 그대로 연한 바탕으로 보입니다.
- 일정: 달 제목이 화면 제목을 대신합니다. 칸마다 출근 시각(글자), 일정 · 휴가 · 업무외 항목(막대 + 글자)이 들어갑니다. 주말 · 휴무일 칸은 `Bg.Layer`로 칠하고, 공휴일은 빨간 날짜 + 이름입니다. 색만으로 나누지 않습니다(모든 항목에 글자).
- 업무: 트리 칸 240 + 폼 칸. param 이름과 형식을 라벨 옆에 코드 글꼴로 보입니다. 실행 위치는 탭 모양 대신 고르기 칸입니다.

## WPF 구현 메모

지금 구조(`Theme.psm1`의 색 · 크기 → `Ui.psm1`의 스타일)를 그대로 쓰고 값과 템플릿만 바꿉니다.

**테마 사전**
- 밝은 · 어두운 두 사전을 두고 `Update-WtThemeDictionary`에서 통째로 바꿉니다(DynamicResource).
- Fluent의 반투명 값(`#B3FFFFFF` 등)은 모두 단색으로 환산해 둡니다. 반투명은 마우스 올림 · 선택 덧칠(작은 면)에만 씁니다.

**스타일 · 템플릿 목록**
- `Window` 틀: 제목 줄 32, 창 버튼 3개(닫기 마우스 올림 `#C42B1C` + 흰 글리프)
- `Nav` (RadioButton): 바탕 Border(모서리 4) + 선택 막대 Rectangle 3 × 16 + 글리프 + 글자
- `ContentLayer` (Border): `CornerRadius="8,0,0,0"`, `BorderThickness="1,1,0,0"`
- `Btn` · `Btn.Accent` · `Btn.Subtle` · `Btn.Link`: Border 하나 + 아래 1px 선(Grid 안 Border 하나 더)
- `Input` (TextBox): 테두리 + 바닥선 Border. 포커스면 바닥선이 강조색 2
- `Combo` (ComboBox) + 펼침 Popup: `Bg.Raised` · `Stroke.Flyout` · 모서리 8, 그림자 없음
- `Check` (CheckBox): 20 상자, 켜면 강조 채움 + 흰 체크 글리프
- `Segmented` (RadioButton 묶음): 실시간 · 원문 · 읽기
- `Row` (ListBoxItem) · `TreeRow` (TreeViewItem): 바탕 + 선택 막대
- `Tab` (메모 탭): 위 모서리 8 Path 하나, 선택이면 `Bg.Card`
- `Card` · `Card.Row` (설정 앱식 한 줄 카드) · `Badge` (상태) · `Chip` (달력 항목: 바탕 + 막대 3)
- `Cal.Day` (DataTemplate): 날짜 · 휴일 이름 · 출근 글자 · 항목 최대 3개 · 넘치면 `+1`
- `ScrollBar` (폭 6, 움직임 없음) · `ToolTip` (모서리 4) · `ContextMenu` / `MenuItem` · `ProgressBar` (높이 3)
- 글리프: 홈 E80F · 일정 E787 · 근태 E823 · 메모 E70B · 문서 E8B7 · 업무 E756 · 활성 작업 E7C4 · 도움말 E897 · 설정 E713 · 알람 EA8F · 반복 E8EE · 업무외 E708 · 공휴일 E7C1

**비용이 큰 것 · 조심할 것**
- 월 달력: 칸 35 ~ 42개 × (글자 3 + 항목 3)이라 요소가 300개 안팎입니다. 칸을 한 번 만들고 달을 바꿀 때는 값만 갈아 끼웁니다. 칸마다 ItemsControl을 두지 말고 항목 3자리를 고정해 둡니다.
- 둥근 모서리로 자식을 잘라 내는 `Clip`은 쓰지 않습니다. 모서리 근처에 여백을 두면 필요 없습니다.
- 그림자가 없어서 떠 있는 면은 `Stroke.Flyout` 테두리로만 구분합니다. 대화상자 뒤는 단색 반투명 검정(30%) 한 장으로 어둡게 합니다.
- .NET 9의 Fluent 테마(`ThemeMode`)는 쓰지 않습니다. 실험 기능(WPF0001)이고, 반투명 브러시와 움직임이 많아 소프트웨어 렌더링에서 비용을 따로 재야 합니다. 값만 가져옵니다.
- 7색 파스텔 테마는 이 방향과 맞지 않습니다. 빼거나, 강조색 몇 개 고르기로 줄여야 합니다(바탕 틴트는 없앰).

## 장점

- Windows 기본 앱과 같은 모양 · 위치 · 크기라 배울 것이 없고, 회사 PC에서 믿음직해 보입니다.
- 값의 출처가 공개된 Fluent 값이라 근거가 분명하고, 대비 계산 · 다크 모드가 쉽습니다.
- 단색 면 3단 + 1px 선 + 높이 32라 요소가 적고 같은 템플릿으로 찍어 냅니다. 한 화면에 더 많이 보입니다.

## 단점

- 개성이 약합니다. 「설정 앱 같다」는 느낌이 들 수 있고, 지금의 색 고르는 재미가 사라집니다.
- 회색 면 차이(`#F3F3F3` · `#F9F9F9` · `#FFFFFF`)가 작아, 밝은 노트북 화면에서는 층이 테두리에만 기댑니다.
- Mica · 그림자가 없어 진짜 Windows 11 앱보다 조금 평평합니다. Windows 10은 MDL2 아이콘이라 모양이 조금 다릅니다.

## 다시 만들기

- `python -I _src/make.py` → SVG 5장
- `pwsh -NoProfile -File _src/render.ps1` → Edge로 PNG 5장
- `python -I _src/verify.py` → 대비 검사

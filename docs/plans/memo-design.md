# 메모 데이터 · 검색 설계 (5a)

화면 없이 `apps/WorkTool/wpf/addons/memo/MemoData.psm1`에서 처리합니다. 저장 공통 규칙은 [일정 · 근태 데이터 설계 1장](schedule-attendance-design.md#1-공통-규칙-모든-저장소-파일)을 따릅니다. 모든 쓰기는 `Open-WtStore` · `Save-WtStore` 핸들을 거칩니다. 저장하면 새 핸들을 받고, 낡거나 읽지 못한 핸들은 거부합니다. 디스크 쓰기 실패는 기존 저장 통로가 보유합니다.

## 파일 세 개

- `memo.json`: **schema 1 유지**. 기존 제목 · 본문 · 태그 · 잠금 · 생성일 · 수정일에 선택 칸 `folder`, `pinned`, `pinOrder`, `archived`, `archivedAt`만 더합니다. 없음은 폴더 없음 · 고정 안 함 · 보관 안 함입니다. 고정 순서는 작은 정수가 위입니다. 메모를 고치면 `rev`와 수정일을 올립니다.
- 맨 위 `folders`는 `{ id, name, order, created }` 목록입니다. 없으면 업무(`work`, 10) · 절차(`procedure`, 20) · 장애(`incident`, 30) · 개인(`personal`, 40)을 가상으로 씁니다. 폴더 목록을 바꾸기 전에는 파일에 쓰지 않습니다. 이름을 바꿔도 id는 유지하며, 폴더를 지우면 메모의 `folder`만 `null`로 바꿉니다. 모르는 폴더 id는 원문에 남기고 결과에는 「폴더 없음」으로 표시합니다.
- `memo-state.json`: schema 1, 앱 상태. 항목은 `{ id, opened }`입니다. `Set-WtMemoOpened`를 부를 때만 기록하며, 60초 미만 재열람은 쓰지 않습니다. 사라진 메모의 기록은 검색에서 무시하고 원문에는 남깁니다. `memo.json`과 수정일을 바꾸지 않습니다.
- `memo-views.json`: schema 1, 사용자 데이터. 항목은 `{ id, name, query, sort: { by, dir }, scope, created, updated, rev, deleted }`입니다. `query`는 공백까지 입력 원문을 보존하며 해석 결과·검색 결과는 저장하지 않습니다. 처음에는 비어 있습니다. 일반 · 고정 · 최근 열기 · 보관 · 모두는 `Find-WtMemo -View`의 코드 기본 보기입니다.

새 앱은 옛 시각(`yyyy-MM-dd HH:mm:ss`)을 읽고 원문을 보존합니다. 새 앱이 찍는 시각은 그레고리력·InvariantCulture의 `yyyy-MM-ddTHH:mm:ss+09:00`입니다. id는 대소문자를 구분합니다. 모르는 항목 칸 · 중첩 칸 · 맨 위 키, 지운 줄 · `null` · 깨진 배열 줄도 보존합니다. 기존 화면의 삭제·실행 취소는 저장 경로에서 지운 표시·되살리기로 바꾸며, 화면 코드는 바꾸지 않습니다. 옛 판이 선택 칸을 없애더라도 제목·본문은 기존 칸에 그대로 있습니다.

## 검색 조건과 결과

`ConvertFrom-WtMemoQuery $text`는 `{ Success, Scope, Root, Error }`를 돌려줍니다. `Scope`는 `active`(기본 보관 제외) · `archived` · `all`이며 검색 전체에 적용됩니다. 서로 다른 `scope:`나 scope 부정은 오류입니다. 오류는 `{ Position, Length, Reason }`이고 위치는 원문 UTF-16의 **0부터** 셉니다.

칩과 검색식이 공유하는 `Root` 노드는 다음과 같습니다. `ConvertTo-WtMemoQuery $tree`로 글을 만든 뒤 해석하면 같은 트리가 됩니다.

- `{ Kind: 'all' }`: 조건 없음.
- `{ Kind: 'term', Field, Value }`: `text` · `title` · `body` · `tag` · `folder` · `is` · `created` · `updated` · `has` · `no` · `linksto` 조건.
- `{ Kind: 'not', Child }`: 제외.
- `{ Kind: 'and' 또는 'or', Children: [...] }`: 두 개 이상의 조건. 같은 종류의 중첩 그룹도 유지합니다.

공백은 AND입니다. 우선순위는 괄호 → `-` → AND → OR입니다. 낱말·따옴표 구문은 대소문자 무시 부분 문자열이며 `* ? []`는 일반 글자입니다. 태그는 정확히 일치하고, 폴더는 id 또는 이름으로 찾습니다. `is:pinned`, `has:link`, `has:backlink`, `no:tag`, `linksto:"제목"`을 지원합니다. 따옴표 안 `\"` · `\\`는 따옴표·역슬래시입니다.

`updated:` · `created:`는 `7d`, `yyyy-MM-dd`, `시작..끝`, `<날짜`, `>날짜`를 받습니다. 최근 7일은 PC 현지 날짜로 오늘 포함 7일이고, 범위는 양끝 포함입니다. `<` · `>`는 기준일을 제외합니다. 범위는 공통 날짜 규칙(1900~2199년)을 따릅니다.

`New-WtMemoIndex $memos -Folders $folders`는 소문자 제목·본문 사본, 저장된 태그 집합, 폴더·고정·보관·날짜, 나가는 위키 연결과 받는 연결 수를 만듭니다. 사용자 폴더가 바뀌면 `Get-WtMemoFolders`의 목록을 넘깁니다. `Update-WtMemoIndex -Index $index -Memo $memo` 또는 `-Remove $id`로 한 항목과 관련 연결을 갱신합니다. 받은 연결은 같은 출발 메모의 반복 연결을 한 번만 셉니다. 코드 안 태그·연결은 기존 Markdown 해석기로 제외합니다. 제목이 겹치는 연결 대상은 임의로 확정하지 않고 검색 오류로 돌려줍니다.

`Find-WtMemo -Index $index -Query $textOrTree`는 `{ Success, Items, Count, Error }`입니다. 결과 항목에는 id · 제목 · 일치 위치(`Field, Start, Length`) · 80자 이내 원문 문맥(`Snippet, SnippetStart`) · 폴더 · 태그 · 고정 상태가 있습니다. 오류 때는 빈 결과와 이유를 돌려주고, 이전 결과 유지 여부는 화면이 정합니다. 지운 메모는 모든 범위에서 제외합니다.

일반 정렬은 고정 → `pinOrder` → 수정일 내림차순 → 제목 → id입니다. 양의 텍스트 조건이 있으면 제목 완전 일치 → 제목 포함 → 본문 포함을 먼저 봅니다. 태그·날짜 조건만 있으면 일반 정렬입니다. `-Sort updated|created|title|opened|backlinks -Dir asc|desc`로 선택할 수 있습니다. 제목 기본 방향은 오름차순, 나머지는 내림차순입니다. 동률은 일반 정렬로 확정하며 제목/id 비교는 문화권에 의존하지 않습니다. `-OpenedMap`은 state 핸들·문서·항목 목록 또는 id → 시각 사전입니다.

## 정리 함수와 검사

`Set-WtMemoFolder -Id -Folder`, `Set-WtMemoPinned -Id -Pinned [-Order]`, `Set-WtMemoArchived -Id -Archived`, `Save-WtMemoFolders -Folders`는 새 memo 핸들을 돌려줍니다. `Get-WtMemoFolders`는 가상 또는 저장된 폴더 목록입니다. `Set-WtMemoOpened -Id`는 state 핸들, `Get-WtMemoViews`는 지우지 않은 보기 목록, `Save-WtMemoView -Name -Query -Sort [-Scope -Id]`와 `Set-WtMemoViewDeleted -Id [-Deleted]`는 views 핸들을 돌려줍니다. 모두 `-Store`로 읽은 핸들을 직접 넘길 수 있습니다. `Set-WtMemoOpened`의 `-MemoStore`는 메모 존재 확인용입니다.

`Memo.psm1`의 기존 읽기·저장은 `Open-WtMemoStore` · `Save-WtMemoDataItems`로 연결합니다. 읽을 때 숨긴 줄도 핸들에는 남고, 저장할 때 아는 칸만 깊게 합칩니다. 제목·본문을 저장할 때 태그는 기존 `Get-WtMemoTags`로 다시 해석합니다. 화면 검색은 기존 내부 함수를 유지하며, 새 공개 검색은 `MemoData.psm1`만 내보냅니다.

고정 자료는 `apps/WorkTool/wpf/addons/memo/fixtures/memo-main.json` · `memo-v-new.json` · `memo-state-v1.json` · `memo-views-v1.json`입니다. `Test-Memo.ps1`에서 호환·왕복·폴더·최근·보기·검색·정렬·문화권 5개와 기존 화면·저장 실패를 검사합니다. 3,000개 × 평균 2KB의 색인 시간과 검색식 5개의 5회 중앙값은 창 없이 Stopwatch로 보고하며 실패 조건으로 삼지 않습니다. 실제 사용자 데이터는 쓰지 않습니다.

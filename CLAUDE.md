# jejari

macOS 메뉴바 앱. 열린 창의 배치를 스냅샷으로 저장하고 한 번에 복원한다.

- `.lab/`: private 문서 (hub의 `vault/20_projects/jejari`). 기획서는 `.lab/기획서.md`, 현황·판단·회고는 `.lab/README.md`
- `.lab/work/{작업 제목}/`: 분석, 설계 초안 등 날것 작업 문서
- `docs/`: public 문서. `.lab/`의 내용을 참조하거나 옮겨 적지 않는다
  - `docs/구조.md`: 파일별 역할, 창 찾기·매칭·가상화면 이동 방법, 정한 것
  - `docs/개발.md`: 빌드, 버전, 변경 기록, 브랜치, 버전 내기, 시험(URL 명령), macOS 업데이트 뒤 확인
- 프로젝트 정보(스택, 명령): `.claude/project.yaml`

## 지킬 것

- 사용자가 알아챌 변경은 같은 커밋에서 `CHANGELOG.md`의 `[Unreleased]`에 적는다 (규칙: `docs/개발.md` 변경 기록)
- `main`에 직접 커밋하지 않는다. 작업마다 `origin/main`에서 브랜치를 만들고 PR을 Squash로 합친 뒤 지운다. 브랜치 이름, 커밋 메시지(`타입: 설명`), 순서는 hub의 `vault/30_knowledge/git-브랜치-규칙.md`(`.lab/../../30_knowledge/`)
- 동작을 바꾸면 `docs/구조.md`의 해당 절도 같이 고친다
- 화면을 볼 수 없으니 동작 확인은 `jejari://` URL 명령과 불러오기 기록으로 한다 (`docs/개발.md` 시험)
- 작업을 마치면 hub의 `vault/30_knowledge/버전-내기-기준.md`(`.lab/../../30_knowledge/`)를 보고, 맞으면 버전 내기(`/lab:release`)를 제안한다

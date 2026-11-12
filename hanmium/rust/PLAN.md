# Hanmium 크로스플랫폼판 (Rust) — 설계와 진행

맥판(Swift, `../Sources/Hanmium`)의 모든 기능을 리눅스·윈도우에서도 쓰게 한다. 2026-11-12 에 "A안: Rust 공통 코어 + 운영체제별
백엔드"로 정했고, 리눅스(GNOME Wayland)부터 한다. 맥판은 다 옮길 때까지 Swift 그대로 쓴다.

## 구조

```
rust/
  crates/hanmium-core     운영체제 API 를 쓰지 않는 공통 코어 (맥·리눅스·윈도우 같은 시험)
  crates/hanmium-linux    리눅스 백엔드 + 실행 파일 (예정)
  gnome-extension/        GNOME Shell 확장 (예정): 라벨·테두리 그리기, 창 위치, 단축키, 클릭·휠 보내기
```

### 코어 (`hanmium-core`)
| 모듈 | 내용 | 상태 |
|---|---|---|
| `keys` | Karabiner key_code 이름(`Key`), 왼쪽·오른쪽 수정키(`Mods`, option=Alt, command=Super) | 됨 |
| `rules` | Karabiner 규칙 JSON 읽기, 지원 안 하는 것 표시 | 됨 |
| `engine` | 키보드 규칙 엔진 (맥판 KeyboardEngine 과 같은 뜻) | 됨, 맥판 시험 46개 통과(맥·jkhan) |
| `modsync` | 수정키를 실제로 눌렀다 떼서 맞추기 (리눅스 uinput·윈도우 SendInput 용) | 됨 |
| `mousekeys` | mouse_key 포인터·휠 이동량 | 됨 |
| `labels` | Vimium 방식 라벨 글자 | 됨 |
| 모드 상태 기계 (라벨·검색·스크롤), 스크롤 영역 판단, WezTerm 배치, 설정 | | 할 일 |

### 리눅스 백엔드 — GNOME Wayland 에서 막히는 것과 푸는 방법
| 기능 | 방법 |
|---|---|
| 클릭 대상·스크롤 영역 | AT-SPI (`atspi` 크레이트). Wayland 에서는 화면 좌표를 주지 않으므로 창 기준 좌표 + 확장이 알려 주는 창 위치 |
| 라벨·테두리 그리기 | GNOME 은 layer-shell 이 없어서 **GNOME Shell 확장**이 모든 창 위에 그린다 (데몬이 D-Bus 로 그릴 것을 보낸다) |
| 모드 중 키 입력 | 확장이 키보드를 잡고(pushModal) 키를 데몬에 보낸다 |
| 단축키 | 확장의 키 바인딩 (또는 키 바꾸기 엔진의 `{"hanmium": …}`) |
| 클릭·휠·포인터 | 확장의 Clutter 가상 입력 장치 (포털 승인 창 없음) |
| 키 바꾸기 (Karabiner 대신) | evdev 로 키보드를 잡고(EVIOCGRAB) uinput 가상 키보드·마우스로 내보낸다. `input` 그룹 권한 필요 |
| 유리 굴절 | 확장 안에서 셰이더로 (화면 캡처 권한 문제 없음). 처음엔 흐림·단색 |
| WezTerm | `wezterm cli` 그대로 + 확장의 창 위치 |
| 시험 | jkhan 에서 사용자 세션과 따로 **headless gnome-shell** (`--headless --virtual-monitor`, XDG 폴더 따로)을 띄워 그 안에서 앱·확장·데몬을 돌리고 확장으로 화면을 찍는다 |

## 시험
- `cargo test` (rust/): 코어 단위 시험 + `tests/keyboard_fixtures.rs` (맥판 46개).
- 리눅스 실제 키 시험: `linux/live-test.sh` (jkhan 에서, 사용자 세션과 따로 띄운 headless GNOME). 시험 페이지 `linux/testpages/`.

## 진행 기록
- 2026-11-12: 작업 공간, 코어(keys·rules·engine·modsync·mousekeys·labels), 맥판 키보드 시험 46개 이식 — 맥·jkhan 통과.
- 2026-11-12: GNOME 확장(Ping·Windows·ShowOverlay·Grab·Click·Scroll·TestKey·Screenshot·Prepare)과 시험 세션
  (`linux/test-session.sh`: systemd 범위 안에 headless gnome-shell, XDG 폴더 따로). 리눅스 데몬 `hanmium`
  (`crates/hanmium-linux`): `windows`·`dump`·`labels`. 텍스트 편집기에서 AT-SPI 로 단추 5개를 20ms 에 찾고(창 기준 좌표 + 확장의
  틀 위치가 화면과 맞음), 라벨을 띄우고, 키보드를 잡아 키를 받고, `d` 로 "새 탭"을 접근성 동작으로 눌러 탭이 2개가 됨.
  동작이 없는 단추는 가상 포인터로 클릭(팝업이 뜸).

- 2026-11-12: 단축키·데몬. 확장이 GSettings 키(labels·search·scroll, 기본 Alt+Space·Alt+/·Shift+Super+J)로 키 바인딩을 잡아
  `Hotkey(name)` 신호를 보내고, `hanmium run` 데몬이 받아 라벨 모드를 연다(모드 중 키는 `Key` 신호). GNOME 의 Alt+Space(창 메뉴)는
  시험 세션에서 비움. 텍스트 편집기: 단축키 → 라벨 30ms → `d` 로 "새 탭". 확장 `Activate(id)` 추가.
- 2026-11-12: Chrome(리눅스, Wayland). 그냥 띄운 Chrome 은 AT-SPI 창 아래가 비어 있다(노드 2개). ACCESSIBILITY_ENABLED=1,
  org.a11y.Status ScreenReaderEnabled, GNOME 화면 읽기 설정 모두 효과 없음(Chrome 은 /proc 에서 orca 프로세스를 찾아 켠다).
  **앱·창 객체에 GetAttributes·GetRelationSet 을 부르면(Orca 처럼) 바로 켜진다** → `A11y::wake`. 막 띄운 Chrome 에서
  플래그 없이 첫 라벨 모드 대상 45개(페이지 링크·단추 포함) 찾기 45ms·띄움 60ms. Wayland 에서도 창 기준 좌표 + 확장의 틀 위치가 맞음(화면 확인).
- 2026-11-12: 단축키가 가끔 안 먹던 것 고침. ① 시험 환경: 시험용 Chrome 이 GNOME 키링 암호 창을 띄워 키를 모두 가져갔다 →
  `--password-store=basic`(`test-session.sh chrome`). ② 설계: 확장이 신호를 뿌리기만 해서 데몬이 아직 듣지 않으면(막 켰을 때)
  사라지고, 데몬이 죽으면 아무 반응이 없었다 → 확장이 데몬 메서드 `org.hanmium.Daemon.Hotkey/Key` 를 직접 부르고, 데몬이 없으면
  세션 버스가 D-Bus 활성화로 띄워 전달(`linux/org.hanmium.Daemon.service.in`). 실패는 셸 로그에 남김.
- 리눅스 실제 키 시험 `linux/live-test.sh`: 데몬 자동 실행, 텍스트 편집기 라벨 d → 새 탭, Chrome 페이지 대상 40개 넘음,
  창을 바꾼 직후 단축키 20번, 데몬이 죽은 직후, 라벨 띄움 100ms 안 — 6/6 통과 (띄움 중앙 46ms·최대 73ms).

## 다음
1. 라벨 모드 다듬기: 라벨 모양(맥판과 같게), 여러 창·메뉴·팝업, VS Code·Slack(Electron) 확인, 큰 트리 속도
2. 스크롤 모드: 스크롤 영역 찾기(AT-SPI ScrollPane·Viewport + 웹 단서), 휠 보내기(확장 Scroll), 테두리·번호, j/k/d/u/gg/G/H/L/J/K
3. 검색 모드
4. 키 바꾸기: evdev + uinput (사용자가 sudo 로 input 그룹 추가 한 번)
5. 설정 창, 트레이, 자동 실행, 패키지
6. 리눅스판 실제 키 시험(시험 세션에서 TestKey 로) 묶음

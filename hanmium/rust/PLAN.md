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
| `scroll_names` | 웹 클래스·id 이름으로 스크롤 상자 알아보기 (맥판 marksScroller 이식) | 됨 |
| 모드 상태 기계 (라벨·검색·스크롤), WezTerm 배치, 설정 | | 할 일 (지금은 리눅스 백엔드 안에) |

### 리눅스 백엔드 — GNOME Wayland 에서 막히는 것과 푸는 방법
| 기능 | 방법 |
|---|---|
| 클릭 대상·스크롤 영역 | AT-SPI (`atspi` 크레이트). Wayland 에서는 화면 좌표를 주지 않으므로 창 기준 좌표 + 확장이 알려 주는 창 위치 |
| 라벨·테두리 그리기 | GNOME 은 layer-shell 이 없어서 **GNOME Shell 확장**이 모든 창 위에 그린다 (데몬이 D-Bus 로 그릴 것을 보낸다) |
| 모드 중 키 입력 | 라벨: 확장이 키보드를 잡는다(pushModal). 스크롤: 키 포커스만 가져온다(KeyFocus) — pushModal 은 휠까지 잡아서 앱에 안 간다. 키는 확장의 Key 신호(순서 보장)로 데몬에 |
| 단축키 | 확장의 키 바인딩 (또는 키 바꾸기 엔진의 `{"hanmium": …}`) |
| 클릭·휠·포인터 | 확장의 Clutter 가상 입력 장치 (포털 승인 창 없음) |
| 키 바꾸기 (Karabiner 대신) | evdev 로 키보드를 잡고(EVIOCGRAB) uinput 가상 키보드·마우스로 내보낸다. `input` 그룹 권한 필요 |
| 유리 굴절 | 확장 안에서 셰이더로 (화면 캡처 권한 문제 없음). 처음엔 흐림·단색 |
| WezTerm | `wezterm cli` 그대로 + 확장의 창 위치 |
| 시험 | jkhan 에서 사용자 세션과 따로 **headless gnome-shell** (`--headless --virtual-monitor`, XDG 폴더 따로)을 띄워 그 안에서 앱·확장·데몬을 돌리고 확장으로 화면을 찍는다 |

## 시험
- `cargo test` (rust/): 코어 단위 시험 + `tests/keyboard_fixtures.rs` (맥판 46개).
- 리눅스 실제 키 시험: `linux/live-test.sh` (jkhan 에서, 사용자 세션과 따로 띄운 headless GNOME). 시험 페이지 `linux/testpages/`.
- 손으로 볼 때: `linux/scroll-probe.sh pos|state|tap|combo …` (시험 세션 안), `hanmium areas`(스크롤 영역과 위치),
  확장 `State()`(포커스 창·키 포커스·포인터 아래·현황 여부). 시험 세션에서 띄운 앱만 끄기: `test-session.sh kill 이름`.

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

- 2026-11-12: **스크롤 모드.** 단축키 Shift+Super+J, 라벨에서 j·k, 스크롤에서 f 로 서로 넘나든다. 키는 맥판과 같다:
  h j k l·화살표(누른 동안, 화살표+Shift 빠르게), d u(반 페이지, 누르고 있으면 이어서), gg G, Tab·Shift+Tab·Ctrl+n·p·1~9(영역),
  Enter(그 영역 누르고 끝), Shift+H·L(뒤로·앞으로 = Alt+←·→), Shift+J·K(앞·뒤 탭 = Ctrl+PageUp·Down), 그 밖의 Ctrl·Alt·Super 단축키는
  앱으로 넘기고 다시 연다. 라벨 모드에서도 Shift+H·J·K·L.
  - 영역: AT-SPI 역할(ScrollPane·Viewport·DocumentWeb·Terminal) + 웹 상자의 class·id 이름 단서(`scroll_names`). 거의 같은 것·
    바깥의 70% 넘게 덮는 안쪽 것은 뺌. Chrome 은 창 좌표가 버퍼 기준이라 원점을 자동으로 고름(`Origin::Auto`).
  - 움직임은 확장의 `Scroller`(화면 프레임마다, 맥판 ScrollDriver 와 같은 가속·감속·반 페이지 미끄러짐)가 Clutter 가상 포인터의
    매끈한 휠(CONTINUOUS)로 보낸다. 휠 1단위가 앱마다 달라(Wayland 10px, 실측 Chrome 12px·GTK4 2.5px) AT-SPI 툴킷 이름으로 나눈다.
  - 겪은 것: ① pushModal 은 휠도 잡아 셸로 감(작업 공간이 넘어감) → KeyFocus(1x1 반응 액터에 키 포커스, 덮개는 반응 안 함).
    ② 포인터가 그대로인 채 덮개가 생겼다 없어지면 휠이 창에 안 감 → 스크롤 시작마다 1px 갔다 옴. ③ 끝 신호(axis_stop)를 받은
    GTK 가 직전 150ms 로 관성 스크롤 → 200ms 조용한 뒤 −1·+1px 를 보내 잰 속도 0 으로 만들고 끝. ④ zbus 가 메서드 호출을 동시에
    처리해 키 누름·뗌 순서가 바뀜 → 모드 중 키는 신호로. ⑤ 누르고 있는 Shift 가 섞이면 Ctrl+PageDown 이 탭 옮기기가 되고,
    사용자가 누르고 있는 키를 가상 키보드로 누르면 mutter 가 버림 → Shift·그 키를 뗀 뒤 보냄. ⑥ 시험 세션은 포인터 장벽이 없어
    (0,0) 포인터가 덮개 변화 때 왼쪽 위 모서리에 '들어가' 현황이 열림 → `Prepare` 가 포인터를 가운데로.
  - `linux/live-test.sh` 19개 통과: 라벨 6 + 스크롤 13 (편집기 j 0.6초 725px·놓으면 바로 멈춤, d 반 페이지, G·gg, 빠른 30번,
    Chrome 두 영역 Tab·숫자, Shift+J·K 탭, Shift+H·L 뒤로·앞으로(스크롤·라벨), Ctrl+Tab 넘기기, 라벨→k, f→라벨, 다른 데 누르면 끝,
    Esc 포인터 제자리).

## 다음
1. 라벨 모드 다듬기: 라벨·테두리 모양(맥판과 같게, 다른 영역은 점선), 여러 창·메뉴·팝업, VS Code·Slack(Electron) 확인, 큰 트리 속도
2. 스크롤 모드 남은 것: 포커스된 영역에서 시작, 스크롤 안 되는 영역 겨냥 바꾸기(맥판 aim 확인), 다른 창의 영역, Firefox·Qt 단위 실측
3. 검색 모드
4. 키 바꾸기: evdev + uinput (사용자가 sudo 로 input 그룹 추가 한 번)
5. 설정 창, 트레이, 자동 실행, 패키지
6. 리눅스판 실제 키 시험(시험 세션에서 TestKey 로) 묶음

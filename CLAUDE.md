# CLAUDE.md

마우스 없이 키보드만으로 작업하기 위한 **터미널 + 키보드 설정 백업** 레포.
이 파일은 Claude Code 로 설정을 빠르게 **복원/수정/갱신**하기 위한 안내다.

## 핵심 개념
- 각 파일은 정본(canonical)이며, 해당 머신의 "원래 위치"로 복사하면 적용된다.
- 머신은 두 종류: **맥**(현재 작업 머신일 가능성 높음)과 **리눅스 박스**(SSH alias `jkhan`, `ssh jkhan` 으로 접속).

## 파일 ↔ 원래 위치
| 레포 경로 | 원래 위치 | 머신 |
|-----------|-----------|------|
| `wezterm/wezterm.lua` | `~/.wezterm.lua` | 맥 (정본, 크로스플랫폼 공용) |
| `wezterm/wezterm.linux-jkhan.lua` | `~/.wezterm.lua` | 리눅스 `jkhan` (스냅샷, 맥과 일부 다름) |
| `macos-keyboard/karabiner.json` | `~/.config/karabiner/karabiner.json` | 맥 |
| `macos-keyboard/homerow.plist` | `~/Library/Preferences/com.superultra.Homerow.plist` | 맥 (`defaults import` 로 복원) |
| `linux-keyboard/xkb/keymap/jkhan` | `~/.xkb/keymap/jkhan` | 리눅스 `jkhan` |
| `linux-keyboard/xkb/symbols/jkhan` | `~/.xkb/symbols/jkhan` | 리눅스 `jkhan` |
| `linux-keyboard/etc-default-keyboard` | `/etc/default/keyboard` | 리눅스 `jkhan` (root, `sudo` 필요) |

## 복원(적용)
```bash
# 맥 wezterm
cp wezterm/wezterm.lua ~/.wezterm.lua
# 맥 키보드 (Karabiner-Elements 가 자동 로드)
cp macos-keyboard/karabiner.json ~/.config/karabiner/karabiner.json
# 맥 Homerow (import 후 앱 재시작)
defaults import com.superultra.Homerow macos-keyboard/homerow.plist
# 리눅스 키보드 (jkhan 박스에서)
mkdir -p ~/.xkb/keymap ~/.xkb/symbols
cp linux-keyboard/xkb/keymap/jkhan  ~/.xkb/keymap/jkhan
cp linux-keyboard/xkb/symbols/jkhan ~/.xkb/symbols/jkhan
sudo cp linux-keyboard/etc-default-keyboard /etc/default/keyboard
```
원격 머신 파일은 `scp` 로 주고받는다: `scp wezterm/wezterm.lua jkhan:~/.wezterm.lua`

## WezTerm 설정 — 수정 전 알아둘 것
- **Leader = Ctrl+a**. 분할(`\` / `-`), pane 이동(`h/j/k/l`·화살표), 크기조절(Shift+H/J/K/L), 탭(c/n/p/w, 숫자 1~9) 등.
- **포커스 표시**: 활성 pane 배경 = 초록 `#16301d`, 비활성 = 검정 `#1a1b26`. OSC 11 시퀀스를 `pane:inject_output()` 로 주입해서 칠한다(`recolor_panes`).
- **0ms 반영**: pane 이동 키(Leader / ALT+↑↓ / 맥의 Ctrl+Shift+방향키)는 `nav()` 콜백이 "이동 + 즉시 색칠"을 함께 처리. `update-status`(`status_update_interval = 200`)는 마우스 클릭·탭 전환 같은 키 외 경로용 backstop.
- **크로스플랫폼**: `is_mac` 로 분기. 맥=CMD, 리눅스/윈도우=CTRL. 한 파일을 세 OS 공용으로 쓴다.
- **수정 후 검증 필수**: `wezterm --config-file ~/.wezterm.lua show-keys` — 에러가 안 나고 키 목록이 뜨면 파싱 OK. (`nav` 로 묶은 키는 `EmitEvent("user-defined-N")` 로 표시되는 게 정상.)
- 설정 저장 시 WezTerm 이 자동 리로드한다.

## Karabiner (맥 키보드 — "IDontWantMouse"의 핵심)

### 1) 넘패드를 마우스로 (`mouse_mode` 변수, `Shift+NumLock` 토글)
- `8/2/4/6` = 포인터 위/아래/왼/오 이동
- `5`·`/` = 좌클릭, `*` = 우클릭, `-` = 중간클릭
- `7` = Home, `1` = End, `9/3` = 위/아래 스크롤
- `0` = 뒤로(button4), `.` = 앞으로(button5)

### 2) `Caps Lock + h/j/k/l` = 방향키
Caps Lock 은 hidutil 로 F18 이 되어 아무 동작도 없던 죽은 키였다 → 내비게이션 레이어로 쓴다.
`optional: ["any"]` 라서 나머지 modifier 는 그대로 통과하고, 조합이 자연스럽게 합성된다:

| 누르는 키 | 나가는 키 | 결과 |
|---|---|---|
| `CapsLock+h/j/k/l` | `←/↓/↑/→` | 커서 이동 |
| `Shift+CapsLock+…` | `Shift+화살표` | 선택 확장 |
| `Ctrl+CapsLock+h`·`+l` | `Ctrl+←/→` | 왼/오른쪽 스페이스 이동 |
| `Ctrl+CapsLock+k`·`+j` | `Ctrl+↑/↓` | Mission Control / App Exposé |
| `Shift+Ctrl+CapsLock+…` | `Ctrl+Shift+화살표` | WezTerm pane 이동 (`wezterm.lua` 의 `nav`) |
| `Cmd+CapsLock+h`·`+l` | `Cmd+←/→` | 줄 맨앞/맨뒤 (WezTerm 에선 `Ctrl+A`/`Ctrl+E`) |
| `Fn+CapsLock+h`·`+l` | `Fn+←/→` | Home / End |

- 트리거를 `caps_lock` 과 `f18` **둘 다** 등록해뒀다. `~/Library/LaunchAgents/com.local.KeyRemapping.plist`
  가 로그인마다 hidutil 로 `caps_lock`(0x700000039) → `f18`(0x70000006D) 을 거는데, Karabiner 가
  변환 전/후 중 무엇을 보는지는 계층 순서에 달려 있다. 양쪽 다 잡으면 어느 쪽이든 동작한다.
  실제로 뭐가 오는지는 `open -a Karabiner-EventViewer` 로 확인.
- 짧게 톡 누르면 `to_if_alone` 으로 원래 키가 나간다.
- `Opt+b`/`Opt+w` = 단어 뒤/앞 이동(`Opt+←/→`). vim 모션, 레이어 없이 바로.

### 3) `Caps Lock + Space` 누른 채 `h/j/k/l` = 단어/단락 단위 이동
- `h`·`l` → `Opt+←/→` (단어), `k`·`j` → `Opt+↑/↓` (단락). Shift 를 더하면 선택 확장.
- 레이어 키(`spacebar`) manipulator 에 **`caps_held` 조건**을 걸어 Caps Lock 을 누른 상태의 Space
  만 잡는다. 맨 스페이스와 `Opt+Space` 는 Karabiner 를 아예 타지 않는다 — 이게 핵심이다:
  - 조건 없이 `spacebar` 를 잡으면 일반 타이핑에서 "스페이스 누른 채 다음 글자" 가 `to_if_alone` 을
    못 태워 **스페이스가 유실**되고, 길게 눌러도 반복 입력이 안 된다.
  - 한때 `Opt+Space` 를 레이어 키로 썼는데 Homerow 의 `non-search-shortcut`(`⌥Space`) 을
    가로채는 문제가 있었다. Caps Lock 게이팅으로 옮겨서 해소됨.

### 4) `Opt + h/j/k/l` = 마우스 포인터 이동 (넘패드 모드의 hjkl 판)
- 포인터 왼/아래/위/오 이동 (속도 `1536`, 넘패드와 동일)
- `Opt+CapsLock` 조합 — `h` = 좌클릭(`button1`), `l` = 우클릭(`button2`),
  `k`·`j` = 위/아래 스크롤(`vertical_wheel` ∓48, 넘패드 9/3과 동일)
- 포인터 이동 manipulator 는 `optional: ["caps_lock"]` 로 **Opt 단독만** 매칭한다. 마우스 이동에
  modifier 를 얹을 이유가 없고, 이렇게 좁혀두면 `Cmd+Opt+H`(다른 앱 가리기),
  Chrome `Cmd+Opt+J`(개발자 콘솔), `Ctrl+Opt+화살표` 가 가려지지 않는다.

### ⚠ 규칙 순서 (고장나면 여기부터 보라)
Karabiner 는 위에서부터 **첫 매칭**을 쓴다. 현재 순서:
`Caps Lock+Space`(단어) → `Caps Lock`(방향키) → `Opt`(포인터) → `Opt+b/w`
- `Caps Lock+Space` 규칙이 `Caps Lock` 방향키 규칙보다 **앞**이어야 한다.
  아니면 `CapsLock+Space+h` 가 그냥 `←` 로 먹힌다.
- `Caps Lock` 규칙이 `Opt` 규칙보다 **앞**이어야 한다. 레이어 키는 modifier 가 아니라 일반 키로
  소비되므로, `Opt+CapsLock+h` 를 Opt 규칙이 먼저 보면 클릭 대신 포인터 이동이 된다.
- 한 규칙 안에서도 `Opt` **필수** manipulator 가 `Opt` 없는 것보다 앞이어야 한다. 안 그러면
  `optional: ["any"]` 인 방향키 manipulator 가 `CapsLock+Opt+h` 를 먼저 먹어 클릭이 안 된다.

### 수정 후 검증
```bash
CLI="/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
"$CLI" --lint-complex-modifications <rules.json>   # 규칙 문법 검사
"$CLI" --show-current-profile-name
"$CLI" --select-profile main                       # 자동 리로드가 안 먹었을 때 강제
```

## Homerow (맥 — 키보드로 화면 클릭/스크롤, 마우스 대체)
화면 위 클릭 가능한 요소에 라벨을 띄워 키보드로 클릭/스크롤. 현재 단축키:
- `⌥/` (Option+/) = 검색 모드(search-shortcut)
- `⌥Space` = 비검색 모드(non-search-shortcut). (한때 Karabiner 의 `Opt+Space` 레이어와 충돌했으나, 그 레이어를 `Caps Lock+Space` 로 옮겨 해소됨)
- `⇧⌘J` = 스크롤 모드(scroll-shortcut)
- 자동 클릭 on, 로그인 시 자동 실행 on, 라벨 폰트 9pt.
- 복원: `defaults import com.superultra.Homerow macos-keyboard/homerow.plist` 후 앱 재시작. (라이선스 키는 이 plist에 없음 — 별도 입력 필요)

## Linux 키보드 (XKB)
- `~/.xkb/keymap/jkhan` + `~/.xkb/symbols/jkhan` 커스텀 키맵/심볼. `/etc/default/keyboard` 는 콘솔/X 레이아웃.

## 이 백업 갱신하기
설정을 바꿨으면 해당 파일을 이 레포로 다시 복사한 뒤:
```bash
git add -A && git commit -m "update: <무엇을>" && git push
```
- `origin` 은 **HTTPS**(`https://github.com/wjdrud2532/IDontWantMouse`). SSH 로 바꾸지 말 것.
- **맨 `git push` 는 403 이 난다.** 이 맥의 git 은 `credential.helper = osxkeychain` 이고 keychain 의
  `github.com` 항목이 회사 계정(`jkhan-enerzai`)이라, `gh auth switch` 로 gh 활성 계정을 바꿔도 git 은
  계속 회사 계정 토큰을 쓴다 → `Permission to wjdrud2532/IDontWantMouse.git denied to jkhan-enerzai`.
  소유자 토큰을 URL 에 직접 넣어 1회성으로 푸시한다 (config 에 토큰이 남지 않는다):
  ```bash
  git push "https://wjdrud2532:$(gh auth token --user wjdrud2532)@github.com/wjdrud2532/IDontWantMouse.git" main
  ```
- 매번 치기 귀찮으면 keychain 에 개인 계정을 등록해두면 그 뒤로는 `git push` 만으로 된다:
  `git remote set-url origin https://wjdrud2532@github.com/wjdrud2532/IDontWantMouse.git` 로 바꾼 뒤
  첫 푸시에서 비밀번호 자리에 `gh auth token --user wjdrud2532` 출력값을 붙여넣는다.

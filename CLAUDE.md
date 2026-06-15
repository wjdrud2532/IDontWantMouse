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
| `linux-keyboard/xkb/keymap/jkhan` | `~/.xkb/keymap/jkhan` | 리눅스 `jkhan` |
| `linux-keyboard/xkb/symbols/jkhan` | `~/.xkb/symbols/jkhan` | 리눅스 `jkhan` |
| `linux-keyboard/etc-default-keyboard` | `/etc/default/keyboard` | 리눅스 `jkhan` (root, `sudo` 필요) |

## 복원(적용)
```bash
# 맥 wezterm
cp wezterm/wezterm.lua ~/.wezterm.lua
# 맥 키보드 (Karabiner-Elements 가 자동 로드)
cp macos-keyboard/karabiner.json ~/.config/karabiner/karabiner.json
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
넘패드를 마우스로 사용:
- `8/2/4/6` = 포인터 위/아래/왼/오 이동
- `5`·`/` = 좌클릭, `*` = 우클릭, `-` = 중간클릭
- `7` = Home, `1` = End, `9/3` = 위/아래 스크롤
- `0` = 뒤로(button4), `.` = 앞으로(button5)

## Linux 키보드 (XKB)
- `~/.xkb/keymap/jkhan` + `~/.xkb/symbols/jkhan` 커스텀 키맵/심볼. `/etc/default/keyboard` 는 콘솔/X 레이아웃.

## 이 백업 갱신하기
설정을 바꿨으면 해당 파일을 이 레포로 다시 복사한 뒤:
```bash
git add -A && git commit -m "update: <무엇을>" && git push
```
- `origin` 은 **HTTPS**(`https://github.com/wjdrud2532/IDontWantMouse`). 푸시 인증은 레포 소유자의 **gh 토큰**을 쓴다 — 머신의 SSH 키와 별개이므로 origin 을 SSH 로 바꾸지 말 것.

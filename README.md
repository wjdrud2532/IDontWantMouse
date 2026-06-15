# IDontWantMouse

마우스 없이 키보드만으로 작업하기 위한 **터미널 + 키보드 설정 백업**.

## 구성

| 경로 | 설명 | 원래 위치 |
|------|------|-----------|
| `wezterm/wezterm.lua` | WezTerm 설정 (크로스플랫폼 공용, 맥 기준 최신). Leader(Ctrl+a) 기반 분할/이동, 포커스된 pane 초록 배경 표시, pane 이동 0ms 반영 등 | macOS `~/.wezterm.lua` |
| `wezterm/wezterm.linux-jkhan.lua` | Linux(jkhan) 박스의 WezTerm 설정 스냅샷 (맥 버전과 일부 다름) | Linux `~/.wezterm.lua` |
| `macos-keyboard/karabiner.json` | Karabiner-Elements 설정. 넘패드로 마우스 포인터 이동/클릭/스크롤/뒤로·앞으로 제어 | macOS `~/.config/karabiner/karabiner.json` |
| `linux-keyboard/xkb/keymap/jkhan` | 커스텀 XKB keymap | Linux `~/.xkb/keymap/jkhan` |
| `linux-keyboard/xkb/symbols/jkhan` | 커스텀 XKB symbols | Linux `~/.xkb/symbols/jkhan` |
| `linux-keyboard/etc-default-keyboard` | 콘솔/X 키보드 레이아웃 | Linux `/etc/default/keyboard` |

## 복원 방법

### macOS — WezTerm
```bash
cp wezterm/wezterm.lua ~/.wezterm.lua
```

### macOS — 키보드 (Karabiner-Elements)
```bash
cp macos-keyboard/karabiner.json ~/.config/karabiner/karabiner.json
```

### Linux — 키보드 (XKB)
```bash
mkdir -p ~/.xkb/keymap ~/.xkb/symbols
cp linux-keyboard/xkb/keymap/jkhan   ~/.xkb/keymap/jkhan
cp linux-keyboard/xkb/symbols/jkhan  ~/.xkb/symbols/jkhan
sudo cp linux-keyboard/etc-default-keyboard /etc/default/keyboard
```

> WezTerm 설정은 macOS / Linux / Windows 공용으로 작성돼 있어 Linux에도 `~/.wezterm.lua` 로 그대로 쓸 수 있다.

---
백업일: 2026-06-15

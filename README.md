# IDontWantMouse

마우스 없이 키보드만으로 작업하기 위한 **터미널 + 키보드 설정 백업**.

## 구성

| 경로 | 설명 | 원래 위치 |
|------|------|-----------|
| `wezterm/wezterm.lua` | WezTerm 설정 (크로스플랫폼 공용, 맥 기준 최신). Leader(Ctrl+a) 기반 분할/이동, 포커스된 pane 초록 배경 표시, pane 이동 0ms 반영 등 | macOS `~/.wezterm.lua` |
| `wezterm/wezterm.linux-jkhan.lua` | Linux(jkhan) 박스의 WezTerm 설정 스냅샷 (맥 버전과 일부 다름) | Linux `~/.wezterm.lua` |
| `macos-keyboard/karabiner.json` | Karabiner-Elements 설정. 넘패드로 마우스 제어 + `₩`(grave = 숫자 1 왼쪽) 레이어(방향키 / +Space 단어·단락 이동) + `Opt` 레이어(마우스 포인터 / +₩ 클릭·스크롤). 한영 전환은 Karabiner 밖(Fn 지구본 키) | macOS `~/.config/karabiner/karabiner.json` |
| [`hanmium/`](hanmium/) | **Hanmium** — 직접 만든 앱(Swift). 키보드로 화면 요소 라벨 클릭(`⌥Space`)·검색(`⌥/`)·스크롤(`⇧⌘J`), 리퀴드 글래스 라벨. 소스 전체 — 사용법·기능·설정은 [hanmium/README.md](hanmium/README.md) | 빌드해서 실행 (아래 복원 방법) |
| `macos-keyboard/hanmium-settings.json` | Hanmium 설정 (라벨·스크롤·유리 효과 등, 기본값과 다른 것만) | Hanmium 설정 › 고급 › 설정 가져오기 |
| `macos-keyboard/homerow.plist` | Homerow 설정 (참고용 — 2026-11-04 에 Homerow 를 지우고 Hanmium 으로 바꿨다) | macOS `~/Library/Preferences/com.superultra.Homerow.plist` |
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

### macOS — Hanmium
```bash
cd hanmium
./build.sh                 # build/Hanmium.app 생성 (Command Line Tools 만 있으면 된다)
open build/Hanmium.app
```
- 처음 실행하면 **손쉬운 사용** 권한(필수)과 **화면 기록** 권한(유리 라벨의 굴절용)을 허용한다.
- 설정 복원: 메뉴 막대 Hanmium 아이콘 › 설정… › 고급 › **설정 가져오기…** 에서 `macos-keyboard/hanmium-settings.json` 선택.
- 단축키: `⌥Space` 라벨 클릭, `⌥/` 검색, `⇧⌘J` 스크롤. 자세한 테스트·측정 기록은 [`hanmium/TESTING.md`](hanmium/TESTING.md).

### macOS — Homerow (예전 설정, 참고용)
```bash
defaults import com.superultra.Homerow macos-keyboard/homerow.plist
# 적용하려면 Homerow 앱 재시작
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
백업일: 2026-11-04

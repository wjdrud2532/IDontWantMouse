#!/bin/sh
# 시험용 WezTerm 창(분할 2개)을 따로 띄워 스크롤 모드를 실제 키 입력으로 돌려 보고 결과를 확인한 뒤 창을 닫는다.
# 쓰고 있는 WezTerm 창은 건드리지 않는다. 5초쯤 걸리고 그동안 키보드를 쓰지 않아야 한다.
#   1) 처음 열기 → 활성 분할 창에서 시작
#   2) Tab → Enter → 다시 열기 → Enter 로 고른 창에서 시작
#   3) Shift-Tab → Esc → 다시 열기 → 마지막으로 쓰던 창에서 시작 (포커스 그대로)
# 실행 중인 Hanmium.app 을 대상으로 하므로 먼저 build.sh 로 빌드하고 다시 띄워 둔다.
LOG="$HOME/Library/Logs/Hanmium.log"
OUT="${TMPDIR:-/tmp}/hanmium-e2e"
mkdir -p "$OUT"
: > "$LOG"
P1=$(wezterm cli spawn --new-window -- bash -c 'seq 1 3000; exec bash')
P2=$(wezterm cli split-pane --pane-id "$P1" --right --percent 30 -- bash -c 'seq 1 3000; exec bash')
wezterm cli activate-pane --pane-id "$P1"
sleep 1.2
key() { osascript -e "tell application \"System Events\" to $1"; }
front=$(osascript -e 'tell application "System Events" to tell (first process whose frontmost is true) to get {name, value of attribute "AXTitle" of front window}' 2>&1)
if ! echo "$front" | grep -q "wezterm-gui, bash"; then
    echo "앞 창이 시험 창이 아니라서 키를 보내지 않음: $front"
    wezterm cli kill-pane --pane-id "$P2"; wezterm cli kill-pane --pane-id "$P1"
    exit 2
fi
key 'key code 38 using {shift down, command down}'; sleep 1.0
key 'key code 48'; sleep 0.6
key 'key code 36'; sleep 0.8
key 'key code 38 using {shift down, command down}'; sleep 1.0
screencapture -x "$OUT/after-enter.png"
key 'key code 48 using {shift down}'; sleep 0.6
key 'key code 53'; sleep 0.5
key 'key code 38 using {shift down, command down}'; sleep 1.0
screencapture -x "$OUT/after-esc.png"
key 'key code 53'; sleep 0.3
wezterm cli kill-pane --pane-id "$P2"; wezterm cli kill-pane --pane-id "$P1"

starts=$(grep "스크롤 모드 열림" "$LOG" | sed 's/.*→ 시작 //')
first=$(echo "$starts" | sed -n 1p); second=$(echo "$starts" | sed -n 2p); third=$(echo "$starts" | sed -n 3p)
fail=0
[ -n "$first" ] || { echo "✗ 스크롤 모드가 열리지 않음"; fail=1; }
[ "$second" = "$((first + 1))" ] && echo "✓ Enter 뒤 다시 열면 고른 창에서 시작 ($second)" || { echo "✗ Enter 뒤 시작 영역: $second (기대 $((first + 1)))"; fail=1; }
[ "$third" = "$first" ] && echo "✓ Esc 뒤 다시 열면 마지막으로 쓰던 창에서 시작 ($third)" || { echo "✗ Esc 뒤 시작 영역: $third (기대 $first)"; fail=1; }
echo "화면: $OUT/after-enter.png, $OUT/after-esc.png / 로그: $LOG"
exit $fail

#!/bin/bash
# 리눅스판 실제 키 시험. 사용자 세션과 따로 띄운 headless GNOME(test-session.sh)에서 가상 키보드로 단축키·라벨을 눌러 본다.
# 데몬은 직접 띄우지 않는다: 확장이 부르면 세션 버스가 D-Bus 활성화로 띄우는지까지 본다. 끝나면 시험 세션을 끈다.
cd "$(dirname "$0")/.."
export PATH=$HOME/.cargo/bin:$PATH
cargo build -q -p hanmium-linux || exit 2
S=linux/test-session.sh
L=/tmp/hanmium-gnome/daemon.log
pass=0; fail=0
ok() { if [ "$1" = 0 ]; then pass=$((pass+1)); echo "✅ $2"; else fail=$((fail+1)); echo "❌ $2"; fi; }
k() { $S call TestKey $1 $2 >/dev/null; }
press() { k 56 true; k 57 true; k 57 false; k 56 false; }     # Alt+Space
esc() { k 1 true; k 1 false; }
count() { local n; n=$(grep -c "$1" $L 2>/dev/null); echo "${n:-0}"; }
opened() { count "라벨 모드 \["; }
last() { grep "라벨 모드 \[" $L | tail -1; }

$S start >/dev/null && $S call Prepare >/dev/null || { echo "시험 세션을 띄우지 못함"; exit 2; }
($S run gnome-text-editor --new-window >/dev/null 2>&1 &); sleep 3

# 1. 데몬이 없을 때 단축키 → 세션 버스가 데몬을 띄워 라벨이 열린다
b=$(opened); press; sleep 1.5
[ "$(opened)" -gt "$b" ]; ok $? "데몬 없이 단축키 → 데몬이 떠서 라벨 열림"
# 2. 텍스트 편집기: 라벨 d → "새 탭" (탭이 2개)
k 32 true; k 32 false; sleep 1
tabs=$($S run target/debug/hanmium dump 2>/dev/null | grep -c PageTab)
[ "$tabs" = 2 ]; ok $? "텍스트 편집기: 라벨 d → 새 탭 (탭 $tabs개)"
# 3. Chrome(그냥 띄운 것): 페이지 링크·단추까지 라벨
$S chrome "file://$PWD/linux/testpages/links.html"; sleep 6
chrome=$($S run target/debug/hanmium windows | grep Chrome | awk '{print ($1=="*")?$2:$1}')
editor=$($S run target/debug/hanmium windows | grep "편집기" | awk '{print ($1=="*")?$2:$1}')
$S call Activate "$chrome" >/dev/null; sleep 0.5
b=$(opened); press; sleep 1
n=$(last | sed -E 's/.*대상 ([0-9]+)개.*/\1/'); esc; sleep 0.4
[ "$(opened)" -gt "$b" ] && [ "${n:-0}" -ge 40 ]; ok $? "Chrome: 페이지 링크·단추까지 대상 ${n:-0}개 (40개 넘어야)"
# 4. 창을 바꾼 직후 단축키 20번
miss=0
for i in $(seq 1 20); do
    w=$chrome; [ $((i % 2)) = 0 ] && w=$editor
    $S call Activate "$w" >/dev/null; sleep 0.15
    b=$(opened); press; sleep 0.7
    if [ "$(opened)" = "$b" ]; then miss=$((miss+1)); else esc; fi
    sleep 0.3
done
[ $miss = 0 ]; ok $? "창을 바꾼 직후 단축키 20번 (안 열림 $miss)"
# 5. 데몬이 죽은 직후 단축키 → 다시 떠서 열림
$S kill hanmium >/dev/null; sleep 0.2
b=$(opened); press; sleep 1.5
[ "$(opened)" -gt "$b" ]; ok $? "데몬이 죽은 직후 단축키 → 다시 떠서 열림"; esc
# 6. 라벨이 뜨기까지 (단축키 → 화면): 중앙·최대
read med max cnt <<<"$(grep "라벨 모드 \[" $L | sed -E 's/.*띄움 ([0-9]+)ms.*/\1/' | sort -n | awk '{a[NR]=$1} END {print a[int(NR/2)+1], a[NR], NR}')"
[ "${max:-999}" -le 100 ]; ok $? "라벨 띄움 중앙 ${med}ms · 최대 ${max}ms (${cnt}번, 100ms 안)"

# ── 스크롤 모드 ── 위치는 hanmium areas 의 마지막 칸(웹: 첫 문단 y 의 음수 px, 글 상자: 왼쪽 위 글자 위치)
win() { $S run target/debug/hanmium windows | grep "$1" | head -1 | awk '{print ($1=="*")?$2:$1}'; }
pos() { $S run target/debug/hanmium areas | awk -v n="${1:-1}" '$1==n {print $NF}'; }
# 편집기 글자 위치 → px (줄 높이 25px, 각 줄 "줄 N")
epx() { python3 -c "
import sys; off=int(sys.argv[1]); n=0; i=1
while n+3+len(str(i))<=off: n+=3+len(str(i)); i+=1
print((i-1)*25)" "$(pos)"; }
title() { $S run target/debug/hanmium windows | grep '^\*' | sed 's/.*} //'; }
scroll() { k 42 true; k 125 true; k 36 true; k 36 false; k 125 false; k 42 false; }   # Shift+Super+J
tap() { k $1 true; k $1 false; }
hold() { k $1 true; sleep $2; k $1 false; }
shifted() { k 42 true; tap $1; k 42 false; }
sopened() { count "스크롤 모드 \["; }
seq 1 400 | sed 's/^/줄 /' > /tmp/hanmium-gnome/long.txt
($S run gnome-text-editor --standalone /tmp/hanmium-gnome/long.txt >/dev/null 2>&1 &); sleep 3
$S call Activate "$(win long.txt)" >/dev/null; sleep 0.5
# 7. 단축키로 열기
b=$(sopened); scroll; sleep 0.6
[ "$(sopened)" -gt "$b" ]; ok $? "스크롤 모드: Shift+Super+J 로 열림"
# 8. j 를 0.6초 누름 → 1.2px/ms 로 700px 쯤, 놓으면 바로 멈춤(GTK 관성 없음)
a=$(epx); hold 36 0.6; sleep 0.4; m=$(epx); sleep 0.5; e=$(epx)
[ $((m-a)) -ge 500 ] && [ $((m-a)) -le 900 ] && [ "$m" = "$e" ]; ok $? "편집기 j 0.6초: $((m-a))px (500~900), 놓은 뒤 0.5초 동안 $((e-m))px"
# 9. d: 반 페이지(영역 471px → 235px)
a=$(epx); tap 32; sleep 0.6; e=$(epx)
[ $((e-a)) -ge 175 ] && [ $((e-a)) -le 300 ]; ok $? "편집기 d: $((e-a))px (반 페이지 235px)"
# 10. G·gg
shifted 34; sleep 0.6; bottom=$(epx); tap 34; tap 34; sleep 0.6; top=$(epx)
[ "$bottom" -ge 9000 ] && [ "$top" = 0 ]; ok $? "편집기 G → ${bottom}px, gg → ${top}px"
# 11. 빠르게 30번 눌렀다 떼도 멈춘다(누름·뗌 순서가 바뀌지 않음)
for i in $(seq 1 30); do tap 36; done; sleep 0.5; a=$(epx); sleep 0.8; e=$(epx)
[ "$a" = "$e" ]; ok $? "j 30번 빠르게 → 멈춤 ($a → $e)"
tap 1; sleep 0.3
# 12. Chrome: 페이지와 옆 상자 두 영역, Tab·숫자로 옮겨 다니며 그 영역만 스크롤
$S chrome "file://$PWD/linux/testpages/long.html"; sleep 3
$S call Activate "$(win Chrome)" >/dev/null; sleep 0.5
n=$($S run target/debug/hanmium areas | sed -n 1p | sed -E 's/.*스크롤 영역 ([0-9]+)개.*/\1/')
scroll; sleep 1; d0=$(pos 1); s0=$(pos 2)
hold 36 0.6; sleep 0.4; d1=$(pos 1); s1=$(pos 2)
tap 15; sleep 0.2; hold 36 0.6; sleep 0.4; d2=$(pos 1); s2=$(pos 2)
tap 2; sleep 0.2; shifted 34; sleep 0.6; d3=$(pos 1)
[ "$n" = 2 ] && [ $((d1-d0)) -ge 500 ] && [ $((d1-d0)) -le 900 ] && [ "$s1" = "$s0" ] && [ $((s2-s1)) -ge 500 ] && [ "$d2" = "$d1" ] \
    && [ "$d3" -gt 5000 ]; ok $? "Chrome 영역 ${n}개: 페이지 j $((d1-d0))px · Tab → 옆 j $((s2-s1))px(페이지 그대로) · 1 → G ${d3}"
# 13. Shift+J·K 탭, Shift+H·L 뒤로·앞으로 (Shift 를 뗀 뒤 보내고 스크롤 모드를 다시 연다)
t0=$(title); b=$(sopened); shifted 36; sleep 0.6; t1=$(title); shifted 37; sleep 0.6; t2=$(title)
[ "$t1" != "$t0" ] && [ "$t2" = "$t0" ] && [ $(( $(sopened) - b )) = 2 ]; ok $? "Shift+J·K: 탭 '$t1' → '$t2', 다시 열림 $(( $(sopened) - b ))번"
tap 1; sleep 0.3
# 13b. Shift+H·L: 링크 시험 탭에서 "긴 페이지로" 링크로 넘어간 뒤 뒤로·앞으로 (스크롤 모드, 라벨 모드 둘 다)
$S run target/debug/hanmium windows >/dev/null
shifted_in_mode() { scroll; sleep 0.8; shifted $1; sleep 1; }
k 29 true; tap 104; k 29 false; sleep 0.5     # Ctrl+PageUp: 링크 시험 탭
read lx ly lw lh <<<"$($S run target/debug/hanmium dump | grep '긴 페이지로' | grep -o '([0-9]*,[0-9]* [0-9]*x[0-9]*)' | tr -d '()' | tr ',x' '  ')"
$S call Click "$((lx + lw/2)).0" "$((ly + lh/2)).0" 1 >/dev/null; sleep 1.5; h0=$(title)
shifted_in_mode 35; h1=$(title); shifted 38; sleep 1; h2=$(title); tap 1; sleep 0.3
press; sleep 0.6; shifted 35; sleep 1.2; h3=$(title); esc; sleep 0.3
[ "$h0" = "긴 페이지 - Chrome" ] && [ "$h1" = "링크 시험 - Chrome" ] && [ "$h2" = "긴 페이지 - Chrome" ] && [ "$h3" = "링크 시험 - Chrome" ]
ok $? "Shift+H·L: 스크롤 모드 뒤로 '$h1' → 앞으로 '$h2', 라벨 모드 뒤로 '$h3'"
# 13c. 모드가 쓰지 않는 Ctrl 단축키는 앱으로: 스크롤 모드에서 Ctrl+Tab → 다음 탭(긴 페이지), 모드 다시 열림
b=$(sopened); scroll; sleep 0.8; k 29 true; tap 15; k 29 false; sleep 1; h4=$(title)
[ "$h4" = "긴 페이지 - Chrome" ] && [ $(( $(sopened) - b )) = 2 ]; ok $? "스크롤 모드에서 Ctrl+Tab → 앱으로 ('$h4'), 다시 열림"
tap 1; sleep 0.3
# 14. 라벨 모드에서 k → 스크롤 모드로 넘어가 누른 동안 스크롤 (페이지가 맨 아래라 위로)
a=$(pos 1); b=$(sopened); press; sleep 0.5; hold 37 0.5; sleep 0.4; e=$(pos 1)
[ "$(sopened)" -gt "$b" ] && [ "$e" -lt "$a" ]; ok $? "라벨에서 k → 스크롤 모드 ($a → $e)"
# 15. 스크롤 모드에서 f → 라벨
b=$(opened); tap 33; sleep 0.6
[ "$(opened)" -gt "$b" ]; ok $? "스크롤 모드에서 f → 라벨"; esc; sleep 0.3
# 16. 스크롤 모드 중 다른 창을 누르면(키 포커스를 잃음) 모드가 끝나고 키가 새지 않는다
scroll; sleep 1; $S call Click 600.0 400.0 1 >/dev/null; sleep 0.4
grep -q "키 포커스를 잃어" $L; ok $? "스크롤 모드 중 창을 누르면 모드 끝남"
# 17. Esc 로 닫으면 포인터가 처음 자리로
$S call MovePointer 300.0 300.0 >/dev/null; sleep 0.2; scroll; sleep 1; tap 1; sleep 0.3
p=$($S call Pointer)
[ "$p" = "(300.0, 300.0)" ]; ok $? "Esc → 포인터 제자리 $p"

grep -E "오류|못함|못했" $L | head -3
$S stop >/dev/null
echo "통과 $pass · 실패 $fail"
[ $fail = 0 ]

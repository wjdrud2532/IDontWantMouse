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
opened() { grep -c "라벨 모드 \[" $L 2>/dev/null || echo 0; }
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
pkill -f "debug/hanmium run"; sleep 0.2
b=$(opened); press; sleep 1.5
[ "$(opened)" -gt "$b" ]; ok $? "데몬이 죽은 직후 단축키 → 다시 떠서 열림"; esc
# 6. 라벨이 뜨기까지 (단축키 → 화면): 중앙·최대
read med max cnt <<<"$(grep "라벨 모드 \[" $L | sed -E 's/.*띄움 ([0-9]+)ms.*/\1/' | sort -n | awk '{a[NR]=$1} END {print a[int(NR/2)+1], a[NR], NR}')"
[ "${max:-999}" -le 100 ]; ok $? "라벨 띄움 중앙 ${med}ms · 최대 ${max}ms (${cnt}번, 100ms 안)"

grep -E "오류|못함|못했" $L | head -3
$S stop >/dev/null
echo "통과 $pass · 실패 $fail"
[ $fail = 0 ]

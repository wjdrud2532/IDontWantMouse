#!/bin/sh
# 키보드 규칙(Karabiner 대신)을 실제 키 경로로 시험한다 (Tools/LiveKeys). 1분쯤 걸린다.
# 시험 키는 앱에 닿기 전에 버리므로 지금 쓰는 창(Claude Code 등)에는 아무것도 입력·스크롤·클릭되지 않는다.
# 포인터는 실제로 움직였다가 제자리로 돌아온다. 그동안 키보드·마우스를 쓰면 그 항목을 다시 한다.
# 실행 중인 Hanmium.app 의 키 바꾸기가 켜져 있어야 한다 (설정 › 키보드 규칙).
#   Tools/live-keys.sh               35개 전부
#   Tools/live-keys.sh 포인터 마우스  이름에 그 말이 들어간 항목만
#   HANMIUM_TEST_DEVICE=1234:ABCD Tools/live-keys.sh   시험 키를 그 키보드(제조사:제품)에서 온 것으로
set -e
cd "$(dirname "$0")/.."
pgrep -xq Hanmium || { echo "Hanmium 이 실행 중이 아님"; exit 2; }
[ "$(defaults read com.local.Hanmium keyboardEnabled 2>/dev/null)" = 1 ] || { echo "Hanmium 키 바꾸기가 꺼져 있음 (설정 › 키보드 규칙)"; exit 2; }
mkdir -p .build/tools
swiftc -O Tools/LiveKeys/main.swift -o .build/tools/LiveKeys 2> .build/tools/live-keys.log || { grep error .build/tools/live-keys.log; exit 2; }
exec .build/tools/LiveKeys "$@"

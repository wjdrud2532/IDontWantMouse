#!/bin/sh
# 실행 중인 앱(또는 인자로 준 번들 ID)에서 Hanmium 이 클릭 대상·스크롤 영역·WezTerm 분할 창을 제대로 찾는지 점검한다.
# 화면에는 아무것도 띄우지 않는다. 경고가 하나라도 있으면 종료 코드 1 — 코드를 고친 뒤 회귀 확인용.
#   Tools/check-apps.sh                     창이 있는 실행 중인 앱 전부
#   Tools/check-apps.sh com.tinyspeck.slackmacgap com.github.wez.wezterm
set -e
cd "$(dirname "$0")/.."
swift build -c release >/dev/null
status=0
if [ $# -eq 0 ]; then
    .build/release/Hanmium --check || status=1
else
    for id in "$@"; do .build/release/Hanmium --check "$id" || status=1; done
fi
[ $status -eq 0 ] && echo "모두 통과" || echo "경고 있음"
exit $status

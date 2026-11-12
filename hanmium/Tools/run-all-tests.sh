#!/bin/sh
# 모든 회귀 시험을 차례로 돌리고 끝에 결과를 모아 보여 준다. 기능을 고친 뒤 이것 하나만 돌리면 된다.
#   Tools/run-all-tests.sh          화면·키보드를 건드리지 않는 시험 (언제든, 2~3분)
#   Tools/run-all-tests.sh --live   실제 키를 보내는 시험까지 (키보드·마우스에서 손을 떼고, 2분쯤 더)
# 실제 키 시험은 실행 중인 Hanmium.app 을 시험하므로 먼저 ./build.sh 로 설치하고 다시 띄워 둔다.
cd "$(dirname "$0")/.."
live=0
[ "$1" = "--live" ] && live=1
results=""
failed=0
run() {
    name=$1; shift
    echo; echo "━━ $name"
    if "$@"; then results="$results\n✅ $name"; else results="$results\n❌ $name"; failed=1; fi
}
run "키보드 규칙 엔진 (keyboard-fixtures)" Tools/keyboard-fixtures.sh
run "WezTerm 패널 배치 (wezterm-fixtures)" Tools/wezterm-fixtures.sh
run "웹 스크롤 영역 (scroll-fixtures, 시험 창이 다른 창 뒤에 뜸)" Tools/scroll-fixtures.sh
# 앱 점검은 열려 있는 앱에 따라 결과가 바뀌므로 전에 확인한 앱 중 실행 중인 것만 본다(전부 보려면 Tools/check-apps.sh)
apps=""
for id in com.github.wez.wezterm com.microsoft.VSCode com.google.Chrome com.tinyspeck.slackmacgap com.apple.finder; do
    [ -n "$(lsappinfo find bundleid=$id 2>/dev/null)" ] && apps="$apps $id"
done
# shellcheck disable=SC2086
[ -n "$apps" ] && run "실행 중인 앱 점검 (check-apps:$apps)" Tools/check-apps.sh $apps
if [ $live = 1 ]; then
    echo; echo "실제 키 시험을 시작합니다. 키보드·마우스에서 손을 떼 주세요 (5초 뒤 시작)"; sleep 5
    run "키보드 규칙 실제 키 (live-keys)" Tools/live-keys.sh
    run "라벨·스크롤 모드 실제 키 (live-modes)" Tools/live-modes.sh
    run "라벨 뜨는 시간 (live-latency, 앱·사이트)" Tools/live-latency.sh
    run "WezTerm 스크롤 모드 Enter·Esc (e2e-wezterm)" Tools/e2e-wezterm.sh
fi
echo; echo "━━ 결과"; printf "$results\n"
[ $live = 1 ] || echo "(실제 키 시험은 --live 로)"
exit $failed

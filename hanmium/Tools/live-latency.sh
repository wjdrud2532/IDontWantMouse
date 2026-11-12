#!/bin/sh
# 라벨 모드가 뜨는 시간을 실제 앱·사이트에서 잰다 (Tools/LiveLatency). 대상마다 앞으로 가져와 라벨을 4번 열고 닫는다.
# 그동안 화면이 바뀌니 키보드·마우스에서 손을 뗀다. 사이트는 프로필을 따로 쓰는 시험용 Chrome 에서 열고 끝나면 끈다.
#   Tools/live-latency.sh                      기본 앱·사이트 묶음
#   Tools/live-latency.sh app:com.apple.finder site:https://news.ycombinator.com
set -e
cd "$(dirname "$0")/.."
pgrep -xq Hanmium || { echo "Hanmium 이 실행 중이 아님"; exit 2; }
mkdir -p .build/tools
swiftc -O Tools/LiveLatency/main.swift -o .build/tools/LiveLatency 2> .build/tools/live-latency.log || { grep error .build/tools/live-latency.log; exit 2; }
if [ $# -eq 0 ]; then
    set -- app:com.apple.finder app:com.apple.systempreferences app:com.apple.Notes app:com.apple.iCal app:com.apple.TextEdit \
        app:com.apple.Safari app:com.tinyspeck.slackmacgap app:com.microsoft.VSCode app:com.apple.iWork.Pages \
        site:https://news.hada.io site:https://news.ycombinator.com site:https://github.com/torvalds/linux \
        site:https://ko.wikipedia.org/wiki/위키백과:대문 site:https://www.naver.com site:https://www.youtube.com \
        site:https://stackoverflow.com/questions site:https://developer.mozilla.org/en-US/docs/Web/JavaScript \
        site:https://www.reddit.com/r/programming/ site:https://www.google.com/search?q=keyboard+navigation
fi
exec .build/tools/LiveLatency "$@"

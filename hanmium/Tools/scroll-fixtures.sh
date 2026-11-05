#!/bin/sh
# 스크롤 영역 회귀 테스트. Tools/ScrollFixtures/pages 의 시험 페이지마다 키 포커스를 가져가지 않는 WKWebView 창을
# 띄우고(다른 창 뒤), Hanmium 이 찾은 스크롤 영역의 DOM id 를 페이지의 <meta name="expect-areas"> 와 비교한다.
# 잘못 잡았던(또는 놓쳤던) 웹 요소를 찾으면 페이지로 남겨 두고, 영역 찾기를 고칠 때마다 돌린다.
# WebKit 으로 띄우므로 Chromium 만의 특성(화면 끝에서 잘리는 틀 등)은 여기서 확인하지 못한다.
#   Tools/scroll-fixtures.sh              모든 페이지
#   Tools/scroll-fixtures.sh --tree 페이지.html   DOM id 가 있는 요소를 역할·틀·클래스와 함께 출력
set -e
cd "$(dirname "$0")/.."
mkdir -p .build/tools
# 컴파일이 실패하면 지난번 도구로 돌지 않게 바로 끝낸다
swiftc -O $(ls Sources/Hanmium/*.swift | grep -v '/main.swift$') Tools/ScrollFixtures/Check/main.swift \
    -o .build/tools/ScrollCheck 2> .build/tools/scroll-fixtures.log || { grep error .build/tools/scroll-fixtures.log; exit 2; }
swiftc -O Tools/ScrollFixtures/Host/main.swift -o .build/tools/ScrollHost 2> .build/tools/scroll-fixtures.log \
    || { grep error .build/tools/scroll-fixtures.log; exit 2; }
port=$((20000 + $$ % 10000))
python3 -m http.server $port --bind 127.0.0.1 --directory Tools/ScrollFixtures/pages >/dev/null 2>&1 &
server=$!
trap 'kill $server 2>/dev/null' EXIT
sleep 0.7

# 페이지를 띄우고 pid 를 HOST_PID 에 둔다
open_page() {
    out=$(mktemp)
    .build/tools/ScrollHost "http://127.0.0.1:$port/$1" 10 > "$out" &
    HOST=$!
    HOST_PID=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        HOST_PID=$(awk '/^pid/{print $2}' "$out")
        [ -n "$HOST_PID" ] && break
        sleep 0.2
    done
    rm -f "$out"
    sleep 1
}

if [ "$1" = "--tree" ]; then
    open_page "$2"
    .build/tools/ScrollCheck "$HOST_PID" --tree
    kill $HOST 2>/dev/null
    exit 0
fi

fail=0
for page in Tools/ScrollFixtures/pages/*.html; do
    name=$(basename "$page")
    expect=$(sed -n 's/.*<meta name="expect-areas" content="\([^"]*\)".*/\1/p' "$page")
    open_page "$name"
    # shellcheck disable=SC2086
    if result=$(.build/tools/ScrollCheck "$HOST_PID" $expect); then
        echo "통과  $name  $result"
    else
        echo "실패  $name  $result"
        fail=1
    fi
    kill $HOST 2>/dev/null
    wait $HOST 2>/dev/null || true
done
exit $fail

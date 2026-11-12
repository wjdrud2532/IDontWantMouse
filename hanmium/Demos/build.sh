#!/bin/sh
# 예시 앱 빌드: Hanmium 소스(main.swift 제외)와 예시의 main.swift 를 함께 컴파일한다.
#   Demos/build.sh DropletDemo        스크롤 모드 물방울 이동 예시 (A 늘어나는 / B 날아가는)
#   Demos/build.sh LinkLabelsDemo     링크가 많은 페이지(HN) 라벨 방식 8가지 비교
#   Demos/build.sh GlassTransitionDemo 영역을 옮길 때 유리판 굴절: 지금(결과만) / 테두리 모양 그대로 실시간
#   Demos/build.sh SystemGlassDemo    스크롤 모드 유리: 지금(직접 굴절, 화면 기록) / 시스템 유리(NSGlassEffectView)
set -e
cd "$(dirname "$0")/.."
name="$1"
[ -d "Demos/$name" ] || { echo "사용법: Demos/build.sh DropletDemo|LinkLabelsDemo|GlassTransitionDemo|SystemGlassDemo"; exit 2; }
out=".build/demos/$name"
mkdir -p .build/demos
swiftc -O $(ls Sources/Hanmium/*.swift | grep -v '/main.swift$') Demos/"$name"/*.swift -o "$out"
echo "빌드됨: $out"

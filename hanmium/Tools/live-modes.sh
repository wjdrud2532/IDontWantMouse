#!/bin/sh
# 라벨·스크롤 모드를 실제 키로 시험한다 (Tools/LiveModes). 20초쯤 걸리고 그동안 시험 창이 앞에 뜬다.
# 키보드·마우스에서 손을 떼고 돌린다. 앞 앱이 바뀌거나 진짜 입력이 섞이면 키를 더 보내지 않고 멈춘다.
#   라벨 열기 · 라벨에서 j 꾹 → 스크롤 모드로 이어서 스크롤 · Shift+H/L 뒤로·앞으로 · Shift+J/K 앞·뒤 탭
#   Shift+G·gg 맨 아래·맨 위 · f → 라벨 · 영역 번호 1·2 → 그 영역에서 스크롤 모드 · ⌥Space·Tab·Esc 로 닫기 · 라벨에서 k 짧게
#   VS Code 처럼 한 영역이 대화+옆 창으로 나뉜 페이지에서 휠이 대화로 가는지
# 실행 중인 Hanmium.app 을 시험하므로 고친 뒤에는 build.sh 로 설치하고 다시 띄워 둔다.
set -e
cd "$(dirname "$0")/.."
pgrep -xq Hanmium || { echo "Hanmium 이 실행 중이 아님"; exit 2; }
mkdir -p .build/tools
swiftc -O Tools/LiveModes/main.swift -o .build/tools/LiveModes 2> .build/tools/live-modes.log || { grep error .build/tools/live-modes.log; exit 2; }
exec .build/tools/LiveModes

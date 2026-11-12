#!/bin/sh
# WezTerm 패널 배치 회귀 시험 (Tools/WezTermFixtures). 화면·WezTerm 을 건드리지 않고 몇 초면 끝난다.
# WezTerm.swift 의 배치 계산을 고칠 때마다 돌린다. 실제 화면과 맞는지는 `Hanmium --check com.github.wez.wezterm`.
set -e
cd "$(dirname "$0")/.."
mkdir -p .build/tools
swiftc -O $(ls Sources/Hanmium/*.swift | grep -v '/main.swift$') Tools/WezTermFixtures/main.swift \
    -o .build/tools/WezTermCheck 2> .build/tools/wezterm-fixtures.log || { grep error .build/tools/wezterm-fixtures.log; exit 2; }
.build/tools/WezTermCheck Tools/WezTermFixtures/cases

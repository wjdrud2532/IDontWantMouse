#!/bin/sh
# 키보드 규칙 엔진 회귀 시험 (Tools/KeyboardFixtures). 실제 키를 보내지 않는다. KeyboardEngine·KeyboardRules 를 고칠 때마다 돌린다.
set -e
cd "$(dirname "$0")/.."
mkdir -p .build/tools
swiftc -O $(ls Sources/Hanmium/*.swift | grep -v '/main.swift$') Tools/KeyboardFixtures/main.swift \
    -o .build/tools/KeyboardCheck 2> .build/tools/keyboard-fixtures.log || { grep error .build/tools/keyboard-fixtures.log; exit 2; }
.build/tools/KeyboardCheck Tools/KeyboardFixtures/rules.json

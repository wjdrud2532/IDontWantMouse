#!/bin/bash
# 스크롤 모드 손 시험 도우미 (jkhan 시험 세션 안). live-test.sh 로 옮기기 전 단계.
cd "$(dirname "$0")/.."
T=linux/test-session.sh; H=./target/debug/hanmium
pos() { $T run $H areas | awk -v n="${1:-1}" '$1==n {print $NF}'; }
key() { $T call TestKey "$1" "$2" >/dev/null; }
tap() { key $1 true; key $1 false; }
state() { $T call State | sed "s/^('//; s/',)\$//"; }
combo() { for k in "$@"; do key $k true; done; for ((i=$#; i>0; i--)); do key ${!i} false; done; }
"$@"

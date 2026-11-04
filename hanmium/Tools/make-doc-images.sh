#!/bin/sh
# README 이미지(docs/images/*.png, 움직이는 그림 *.gif)를 다시 만든다. 화면에는 아무것도 띄우지 않고, Hanmium 의 그리기 코드로
# 가짜 화면(링크가 많은 웹 페이지, 터미널 분할 창)과 설정 창을 그린다. 설정 창 그림은 이 Mac 의 Hanmium 설정을 쓴다.
set -e
cd "$(dirname "$0")/.."
mkdir -p .build/tools docs/images
swiftc -O $(ls Sources/Hanmium/*.swift | grep -v '/main.swift$') Demos/LinkLabelsDemo/items.swift Tools/DocImages/*.swift \
    -o .build/tools/DocImages
.build/tools/DocImages docs/images

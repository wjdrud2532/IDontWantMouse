#!/bin/sh
# 앱 아이콘(Resources/AppIcon.icns)을 다시 만든다. Tools/AppIcon 이 코드로 그린다(화면을 찍지 않는다).
set -e
cd "$(dirname "$0")/.."
mkdir -p .build/tools Resources
swiftc -O Tools/AppIcon/main.swift -o .build/tools/AppIcon
rm -rf .build/tools/AppIcon.iconset
.build/tools/AppIcon .build/tools >/dev/null
iconutil -c icns .build/tools/AppIcon.iconset -o Resources/AppIcon.icns
echo "Resources/AppIcon.icns"

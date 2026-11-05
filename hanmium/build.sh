#!/bin/sh
# release 빌드 후 build/Hanmium.app 으로 묶는다 (Dock 아이콘 없는 상주 앱).
#   ./build.sh                          build/Hanmium.app
#   ./build.sh build/test/Hanmium.app   다른 곳에 (써 보기용. 같은 번들 ID·서명이라 권한은 그대로)
set -e
cd "$(dirname "$0")"

swift build -c release

APP="${1:-build/Hanmium.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hanmium "$APP/Contents/MacOS/Hanmium"
# 앱 아이콘 (Tools/make-app-icon.sh 로 다시 만든다)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Hanmium</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.local.Hanmium</string>
    <key>CFBundleName</key><string>Hanmium</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# 키체인에 "Hanmium Local Code Signing" 인증서가 있으면 그걸로 서명한다. 서명 주체가 매번 같아서
# 다시 빌드해도 손쉬운 사용 권한이 유지된다. 없으면 임시(ad-hoc) 서명이라 빌드할 때마다 권한을 다시 줘야 한다.
IDENTITY=$(security find-identity -p codesigning 2>/dev/null | grep '"Hanmium Local Code Signing"' | head -1 | awk '{print $2}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "built $APP (signed with ${IDENTITY:-ad-hoc})"

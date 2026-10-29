#!/bin/zsh
# 늦게 뜨는 창 시험 앱(LateWin)을 build/LateWin.app으로 만든다.
# 실행하거나 다시 열기 요청을 받으면 delay초 뒤에 창 count개를 겹쳐 띄운다:
#   defaults write com.jejari.test.latewin delay -int 50
#   defaults write com.jejari.test.latewin count -int 1
# 다 쓰면: defaults delete com.jejari.test.latewin
set -euo pipefail
cd "${0:A:h}/../.."
APP=build/LateWin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/LateWin" scripts/latewin/main.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.jejari.test.latewin</string>
<key>CFBundleName</key><string>LateWin</string>
<key>CFBundleExecutable</key><string>LateWin</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign -s - --force "$APP"
echo "$APP"

#!/bin/bash
# 배포판을 만들어 GitHub Release에 올린다. 절차는 docs/개발.md "버전 내기".
#
#   scripts/release.sh            태그 v<버전>이 붙은 커밋에서 빌드하고 Release를 만든다
#   scripts/release.sh --dry-run  검사와 업로드 없이 dist/에 zip과 appcast.xml만 만든다
#
# 필요한 것: xcodegen, gh(로그인), 키체인의 Sparkle 비밀 키 (generate_keys로 만든 것)
set -euo pipefail
cd "$(dirname "$0")/.."

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

fail() { echo "❌ $*" >&2; exit 1; }

VERSION=$(sed -nE 's/^ *CFBundleShortVersionString: *"?([0-9.]+)"?.*/\1/p' project.yml)
TAG="v$VERSION"
[[ -n "$VERSION" ]] || fail "project.yml에서 버전을 찾지 못함"

# 변경 기록에서 이 버전의 내용 (다음 "## [" 전까지, 맨 아래 비교 링크 줄은 뺀다)
NOTES=$(awk -v v="$VERSION" '$0 ~ "^## \\[" v "\\]" {on=1; next} on && /^## \[/ {exit} on && !/^\[[^]]+\]: / {print}' CHANGELOG.md \
    | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')
[[ -n "$NOTES" ]] || $DRY_RUN || fail "CHANGELOG.md에 [$VERSION] 항목이 없음"

if ! $DRY_RUN; then
    [[ -z "$(git status --porcelain)" ]] || fail "커밋하지 않은 변경이 있음"
    [[ "$(git describe --exact-match --tags HEAD 2>/dev/null)" == "$TAG" ]] || fail "지금 커밋에 태그 $TAG가 없음 (main에 태그를 붙이고 checkout)"
    git ls-remote --exit-code --tags origin "$TAG" >/dev/null || fail "태그 $TAG를 아직 푸시하지 않음"
    ! gh release view "$TAG" >/dev/null 2>&1 || fail "Release $TAG가 이미 있음"
fi

echo "▶ 빌드 $VERSION"
xcodegen generate -q
xcodebuild -project Jejari.xcodeproj -scheme Jejari -configuration Release -derivedDataPath build \
    -allowProvisioningUpdates build -quiet
APP=build/Build/Products/Release/Jejari.app
# 빌드하면 macOS가 이 앱을 jejari:// 처리 앱으로 등록한다. 그대로 두면 개발 중 보낸 URL 명령이 이 앱을 하나 더 띄우므로
# 끝날 때(실패해도) 등록을 지운다. 서명 확인·압축 중에 다시 등록되므로 빌드 직후가 아니라 맨 끝에 한다
trap '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true' EXIT
PLIST="$APP/Contents/Info.plist"
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
FEED=$(/usr/libexec/PlistBuddy -c "Print SUFeedURL" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$PLIST")
[[ "$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")" == "$VERSION" ]] || fail "빌드된 앱의 버전이 $VERSION이 아님"

# 서명 확인: 같은 Team으로 서명해야 사용자의 손쉬운 사용 권한이 업데이트 뒤에도 유지된다
codesign --verify --deep --strict "$APP" || fail "서명 검증 실패"
TEAM=$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ -n "$TEAM" && "$TEAM" != "not set" ]] || fail "Team 서명이 아님 (LAB_APPLE_TEAM 환경변수와 xcodegen generate 확인)"

echo "▶ 압축, 서명"
mkdir -p dist
ZIP="dist/Jejari-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
SIGN=build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
SIGNATURE=$("$SIGN" "$ZIP")   # sparkle:edSignature="…" length="…"

# 피드 주소 …/releases/latest/download/appcast.xml → 파일 주소 …/releases/download/<태그>/<파일>
DOWNLOAD="${FEED%/latest/download/appcast.xml}/download/$TAG/$(basename "$ZIP")"

# 변경 기록(마크다운 목록·소제목)을 업데이트 창에 보일 HTML로
HTML=$(printf '%s\n' "$NOTES" | awk '
    /^### / { if (ul) { print "</ul>"; ul=0 } print "<h3>" substr($0, 5) "</h3>"; next }
    /^- /   { if (!ul) { print "<ul>"; ul=1 } print "<li>" substr($0, 3) "</li>"; next }
    /^$/    { next }
            { if (ul) { print "</ul>"; ul=0 } print "<p>" $0 "</p>" }
    END     { if (ul) print "</ul>" }' | sed -E 's#`([^`]*)`#<code>\1</code>#g')

cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>제자리</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <description><![CDATA[
$HTML
      ]]></description>
      <enclosure url="$DOWNLOAD" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF

if $DRY_RUN; then
    echo "✅ $ZIP, dist/appcast.xml (올리지 않음)"
    exit 0
fi

echo "▶ GitHub Release $TAG"
printf '%s\n' "$NOTES" > dist/notes.md
gh release create "$TAG" "$ZIP" dist/appcast.xml --title "제자리 $VERSION" --notes-file dist/notes.md --verify-tag
echo "✅ $(gh release view "$TAG" --json url -q .url)"

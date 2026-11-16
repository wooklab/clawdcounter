#!/bin/bash
# 앱을 빌드한 뒤 배포용 DMG(build/ClawdCounter-<버전>.dmg)를 만든다.
# DMG 안에는 ClawdCounter.app 과 /Applications 바로가기가 들어간다.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/ClawdCounter.app"

scripts/build_app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/ClawdCounter-$VERSION.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname ClawdCounter -srcfolder "$STAGING" -fs APFS -format UDZO "$DMG"
echo "Built $DMG"

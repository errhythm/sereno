#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Sereno"
APP_BUNDLE="$APP_NAME.app"

swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key>
	<string>Sereno</string>
	<key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.rhystart.sereno</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSRemindersFullAccessUsageDescription</key>
	<string>Sereno adds your Slack to-dos to Apple Reminders so they reach your other devices.</string>
	<key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
</dict>
</plist>
PLIST

mkdir -p "$APP_BUNDLE/Contents/Resources"
cp icon/Sereno.icns "$APP_BUNDLE/Contents/Resources/Sereno.icns"

codesign -s - --force --deep "$APP_BUNDLE"

echo "Built $(pwd)/$APP_BUNDLE"

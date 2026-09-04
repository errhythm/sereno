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

# Every resource bundle SwiftPM generated, ours and our dependencies'. They have to land
# in Contents/Resources because that is Bundle.main.resourceURL, the first place a
# generated Bundle.module accessor searches.
#
# A glob rather than naming ours alone, and that is the fix for a real crash: this line
# used to copy only ${APP_NAME}_${APP_NAME}.bundle (the Fonts directory, which carries
# OFL.txt beside the font and keeps the shipped app licence-compliant). When
# KeyboardShortcuts arrived it brought a bundle of its own, holding the strings its
# recorder localises the moment it is constructed. SwiftPM's generated accessor looks
# beside the executable and then falls back to a hardcoded absolute path inside .build —
# so on the machine that built it the app kept working, and on any other machine, or
# after rm -rf .build, opening Settings > About would fatalError. Proven, not guessed:
# a standalone build with the same dependency, its bundle moved away and the fallback
# path hidden, died with "could not load resource bundle" at exit 133.
#
# nullglob so a dependency-free build does not copy a literal asterisk.
shopt -s nullglob
for bundle in .build/release/*.bundle; do
  cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
done
shopt -u nullglob

codesign -s - --force --deep "$APP_BUNDLE"

echo "Built $(pwd)/$APP_BUNDLE"

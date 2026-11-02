#!/bin/sh
# Builds "Token Notch.app" into mac/build/, signed for this computer only.
#   ./build-app.sh && open "build/Token Notch.app"
set -eu
cd "$(dirname "$0")"

# One app for both Apple silicon and Intel Macs.
ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/TokenNotch"
APP="build/Token Notch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TokenNotch"
# The open notch shows this page, filled with the numbers at run time.
cp dashboard.html "$APP/Contents/Resources/dashboard.html"
# The icon is drawn by the app itself, at every size iconutil wants.
rm -rf build/AppIcon.iconset
"$BIN" --icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# LSUIElement keeps it out of the Dock: it lives in the notch, or the menu bar without one.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Token Notch</string>
  <key>CFBundleDisplayName</key><string>Token Notch</string>
  <!-- The identifier from when it was called Token Usage, so settings and open-at-login carry over. -->
  <key>CFBundleIdentifier</key><string>com.maskedrepo.tokenusage</string>
  <key>CFBundleExecutable</key><string>TokenNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.0</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

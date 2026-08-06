#!/bin/bash
# Builds DisplayWave.app. Run ./build.sh, then open DisplayWave.app.
set -euo pipefail
cd "$(dirname "$0")"

APP="DisplayWave.app"

swiftc -O -import-objc-header bridge.h DDC.swift main.swift -o DisplayWave \
    -framework AppKit -framework CoreGraphics -framework CoreDisplay -framework IOKit \
    -framework ServiceManagement

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp DisplayWave "$APP/Contents/MacOS/"
cp assets/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>DisplayWave</string>
	<key>CFBundleIdentifier</key>
	<string>local.wave.displaywave</string>
	<key>CFBundleName</key>
	<string>DisplayWave</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
</dict>
</plist>
PLIST

# Re-sign ad hoc after replacing the binary; without this macOS can kill the app
# at launch with "Code Signature Invalid" once the old signature is cached.
codesign --force -s - "$APP"

echo "Built $APP — run: open $APP"

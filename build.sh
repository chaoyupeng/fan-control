#!/bin/zsh
# Builds FanControl.app into ./build using only the Command Line Tools.
set -euo pipefail
cd "${0:A:h}"
APP=build/FanControl.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" build/obj

clang -O2 -mmacosx-version-min=14.0 -c Sources/smc.c -o build/obj/smc.o
clang -O2 -mmacosx-version-min=14.0 Sources/fanctl.c build/obj/smc.o -framework IOKit -o "$APP/Contents/MacOS/fanctl"
swiftc -O -parse-as-library -import-objc-header Sources/Bridging.h -I Sources \
  Sources/FanControlApp.swift build/obj/smc.o -framework IOKit \
  -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/FanControl"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>FanControl</string>
  <key>CFBundleIdentifier</key><string>au.com.haizea.FanControl</string>
  <key>CFBundleExecutable</key><string>FanControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/fanctl"
codesign --force --sign - "$APP"
echo "Built $APP"

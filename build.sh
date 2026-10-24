#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
swiftc -module-cache-path build/module-cache Sources/Detector.swift Sources/TapLab.swift Sources/Setup.swift Sources/main.swift -o build/touchwood \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
mkdir -p build/Touchwood.app/Contents/MacOS build/Touchwood.app/Contents/Resources
cp Info.plist build/Touchwood.app/Contents/Info.plist
cp Resources/*.svg build/Touchwood.app/Contents/Resources/
swiftc -parse-as-library -module-cache-path build/module-cache Sources/Detector.swift Sources/TapLab.swift Sources/Setup.swift Sources/Actions.swift \
  Sources/DeviceUI.swift Sources/DeviceView.swift Sources/TouchwoodApp.swift \
  -o build/Touchwood.app/Contents/MacOS/Touchwood
codesign --force --sign - build/Touchwood.app

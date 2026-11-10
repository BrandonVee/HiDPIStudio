#!/bin/bash
set -euo pipefail
STUDIO_ROOT="$(cd "$(dirname "$0")" && pwd)"
STUDIO_OUTPUT="${1:-$STUDIO_ROOT/../HiDPI Studio.app}"
STUDIO_BUILD="${STUDIO_BUILD_DIR:-$STUDIO_ROOT/.build}"
STUDIO_ARCH="$(uname -m)"
mkdir -p "$STUDIO_BUILD" "$STUDIO_OUTPUT/Contents/MacOS" "$STUDIO_OUTPUT/Contents/Resources"
xcrun clang -fobjc-arc -O2 -mmacosx-version-min=13.0 -arch "$STUDIO_ARCH" \
  -c "$STUDIO_ROOT/Sources/VirtualDisplay.m" -o "$STUDIO_BUILD/VirtualDisplay.o"
xcrun clang -fobjc-arc -O2 -mmacosx-version-min=13.0 -arch "$STUDIO_ARCH" \
  -c "$STUDIO_ROOT/Sources/DDCTransport.m" -o "$STUDIO_BUILD/DDCTransport.o"
xcrun clang -fobjc-arc -O2 -mmacosx-version-min=13.0 -arch "$STUDIO_ARCH" \
  -c "$STUDIO_ROOT/Sources/HiddenDisplayModes.m" -o "$STUDIO_BUILD/HiddenDisplayModes.o"
xcrun swiftc -O -swift-version 5 -target "$STUDIO_ARCH-apple-macosx13.0" \
  -module-name HiDPIStudio \
  -import-objc-header "$STUDIO_ROOT/Sources/VirtualDisplay.h" \
  "$STUDIO_ROOT"/Sources/*.swift "$STUDIO_ROOT"/Tests/*.swift "$STUDIO_BUILD/VirtualDisplay.o" "$STUDIO_BUILD/DDCTransport.o" "$STUDIO_BUILD/HiddenDisplayModes.o" \
  -framework AppKit -framework SwiftUI -framework CoreGraphics -framework ColorSync -framework Carbon -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia -framework QuartzCore -framework IOKit -framework ApplicationServices \
  -o "$STUDIO_OUTPUT/Contents/MacOS/HiDPIStudio"
cp "$STUDIO_ROOT/Resources/Info.plist" "$STUDIO_OUTPUT/Contents/Info.plist"
xcrun swift "$STUDIO_ROOT/Resources/MakeIcon.swift" "$STUDIO_BUILD/AppIcon.iconset"
STUDIO_ICON_NAME="$(/usr/bin/plutil -extract CFBundleIconFile raw -o - "$STUDIO_ROOT/Resources/Info.plist")"
/usr/bin/iconutil -c icns "$STUDIO_BUILD/AppIcon.iconset" -o "$STUDIO_OUTPUT/Contents/Resources/$STUDIO_ICON_NAME.icns"
cp "$STUDIO_BUILD/AppIcon.iconset/icon_512x512@2x.png" "$STUDIO_OUTPUT/Contents/Resources/BrandIcon.png"
/usr/bin/codesign --force --sign - "$STUDIO_OUTPUT"
printf 'Built: %s\n' "$STUDIO_OUTPUT"

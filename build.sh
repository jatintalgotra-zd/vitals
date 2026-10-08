#!/bin/bash
# Builds Vitals.app. SwiftPM is unusable with this Command Line Tools install
# (libPackageDescription does not match the compiler), so we drive the compilers directly.
#
#   ./build.sh             build into .build/
#   ./build.sh --install   build, then install to /Applications and restart the app
set -euo pipefail
cd "$(dirname "$0")"

TARGET="arm64-apple-macos13.0"
BUILD=".build"
APP="$BUILD/Vitals.app"
INSTALLED="/Applications/Vitals.app"
EXEC="Vitals.app/Contents/MacOS/Vitals"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> compiling sensor layer (C)"
clang -O2 -target "$TARGET" -c src/smc.c -o "$BUILD/smc.o"

echo "==> compiling app (Swift)"
# -swift-version 5 keeps us out of Swift 6 strict-concurrency churn for a single-delegate app.
swiftc -O -swift-version 5 -target "$TARGET" \
    -import-objc-header src/Bridging.h \
    src/Sensors.swift src/UI.swift src/Detail.swift src/main.swift \
    "$BUILD/smc.o" \
    -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement \
    -o "$APP/Contents/MacOS/Vitals"

cp Info.plist "$APP/Contents/Info.plist"
cp Vitals.icns "$APP/Contents/Resources/Vitals.icns"

echo "==> signing (ad-hoc)"
codesign --force --sign - "$APP" 2>/dev/null

if [ "${1:-}" != "--install" ]; then
    echo "==> built $APP"
    echo "    run ./build.sh --install to install it to /Applications"
    exit 0
fi

# Quit the running copy first: replacing the bundle under a live process leaves it
# running the old code until it is restarted anyway.
pkill -f "$EXEC" 2>/dev/null || true
sleep 1

rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"
echo "==> installed $INSTALLED"

open "$INSTALLED"
echo "==> started"

#!/bin/bash
# Builds Vitals.app. SwiftPM is unusable with this Command Line Tools install
# (libPackageDescription does not match the compiler), so we drive the compilers directly.
set -euo pipefail
cd "$(dirname "$0")"

APP="Vitals.app"
TARGET="arm64-apple-macos13.0"
BUILD=".build"

rm -rf "$APP" "$BUILD"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

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

echo "==> signing (ad-hoc)"
codesign --force --sign - "$APP" 2>/dev/null

echo "==> built $APP"
du -sh "$APP" | awk '{print "    bundle size: " $1}'

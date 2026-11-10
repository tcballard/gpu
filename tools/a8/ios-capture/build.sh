#!/bin/sh
# Build the iPadOS 15 tools for the J96 (iPad mini 4, A8), ad-hoc (ldid) signed; no developer
# certificate. Needs macOS with Xcode and ldid: run it on a Mac or on a CI macOS runner
# (ci/ios-capture.yml). Output: build/kprobe, build/gpu-capture, build/GPUCapture.app.
set -eu
cd "$(dirname "$0")"
command -v ldid >/dev/null || { echo 'ldid is required (brew install ldid).' >&2; exit 1; }
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
TARGET=arm64-apple-ios15.0
mkdir -p build
xcrun --sdk iphoneos clang -target "$TARGET" -isysroot "$SDK" -Os -Wall kprobe.c -o build/kprobe
xcrun --sdk iphoneos clang -target "$TARGET" -isysroot "$SDK" -Os -fobjc-arc \
    -framework Foundation -framework Metal -framework IOKit capture.m -o build/gpu-capture
APP=build/GPUCapture.app
rm -rf "$APP" && mkdir -p "$APP"
xcrun --sdk iphoneos clang -target "$TARGET" -isysroot "$SDK" -Os -fobjc-arc \
    -framework Foundation -framework Metal -framework IOKit -framework UIKit app.m -o "$APP/GPUCapture"
plutil -create xml1 "$APP/Info.plist"
for kv in CFBundleIdentifier=dev.orchard.gpu-capture-adhoc CFBundleExecutable=GPUCapture \
          CFBundleName=GPUCapture CFBundleDisplayName="GPU Capture" CFBundlePackageType=APPL \
          CFBundleVersion=1 CFBundleShortVersionString=1.0 MinimumOSVersion=15.0; do
    plutil -insert "${kv%%=*}" -string "${kv#*=}" "$APP/Info.plist"
done
plutil -insert UIDeviceFamily -json '[1,2]' "$APP/Info.plist"
plutil -insert UILaunchScreen -json '{}' "$APP/Info.plist"
plutil -insert UIRequiresFullScreen -bool YES "$APP/Info.plist"
for b in build/kprobe build/gpu-capture "$APP/GPUCapture"; do
    xcrun --sdk iphoneos strip -S "$b"
    ldid -Sentitlements.plist "$b"
done
( cd build && shasum -a 256 kprobe gpu-capture GPUCapture.app/GPUCapture > SHA256SUMS && cat SHA256SUMS )

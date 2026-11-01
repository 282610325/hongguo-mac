#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="红果"
APP="$APP_NAME.app"
BUILD=".build"
SOURCES=(Sources/*.swift)

TEST_FLAG=""
if [ "${1:-}" = "--test" ]; then
    TEST_FLAG="-D HGTEST"
    APP="红果-test.app"
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

BINARIES=()
for arch in x86_64 arm64; do
    if swiftc -O $TEST_FLAG -target "${arch}-apple-macos12.0" \
        -o "$BUILD/hongguo-$arch" "${SOURCES[@]}" 2>"$BUILD/$arch.log"; then
        BINARIES+=("$BUILD/hongguo-$arch")
    else
        echo "跳过 ${arch} 编译"
        head -20 "$BUILD/$arch.log"
    fi
done

if [ ${#BINARIES[@]} -eq 0 ]; then
    echo "编译失败"
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ${#BINARIES[@]} -eq 1 ]; then
    cp "${BINARIES[0]}" "$APP/Contents/MacOS/$APP_NAME"
else
    lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

mkdir -p "$BUILD/AppIcon.iconset"
swift tools/makeicon.swift "$BUILD/AppIcon.iconset"
iconutil -c icns "$BUILD/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

chmod +x "$APP/Contents/MacOS/$APP_NAME"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "已生成 $APP"

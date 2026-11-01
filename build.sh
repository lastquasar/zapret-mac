#!/bin/bash
# Builds the app and its .dmg into ./build.
# Needs Xcode command line tools and Go (brew install go).
# ICON=path/to/picture.png ./build.sh uses your own picture for the app icon.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"
OUT="$ROOT/build"
NAME="zapret-mac"
DMG="$OUT/zapret-mac.dmg"
APP="$OUT/$NAME.app"
TARGET="arm64-apple-macos14"
BYEDPI_COMMIT="9887576"
TUN2SOCKS_TAG="v2.7.0"

mkdir -p "$VENDOR" "$OUT"

echo "==> sources"
[ -d "$VENDOR/byedpi" ] || git clone -q https://github.com/hufrea/byedpi "$VENDOR/byedpi"
[ -d "$VENDOR/tun2socks" ] || git clone -q --depth 1 --branch "$TUN2SOCKS_TAG" https://github.com/xjasonlyu/tun2socks "$VENDOR/tun2socks"
[ -d "$VENDOR/flowseal" ] || git clone -q --depth 1 https://github.com/Flowseal/zapret-discord-youtube "$VENDOR/flowseal"

echo "==> ciadpi (ByeDPI + macOS patch)"
git -C "$VENDOR/byedpi" checkout -q -- .
git -C "$VENDOR/byedpi" checkout -q "$BYEDPI_COMMIT" 2>/dev/null || true
git -C "$VENDOR/byedpi" apply "$ROOT/patches/byedpi-macos.patch"
make -s -C "$VENDOR/byedpi" clean
make -s -C "$VENDOR/byedpi" CFLAGS="-I. -std=c99 -O2 -target $TARGET"
cp "$VENDOR/byedpi/ciadpi" "$OUT/ciadpi"

echo "==> tun2socks"
(cd "$VENDOR/tun2socks" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 \
    go build -trimpath -ldflags '-w -s -buildid=' -o "$OUT/tun2socks" .)

echo "==> helper and app"
swiftc -O -target "$TARGET" "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/Helper/*.swift -o "$OUT/zapret-helper"
swiftc -O -target "$TARGET" -parse-as-library "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/App/*.swift -o "$OUT/$NAME"

echo "==> art"
rm -rf "$OUT/art"
swift "$ROOT/Scripts/make-art.swift" "$OUT/art" "$NAME" ${ICON:+"$ICON"} >/dev/null
iconutil -c icns "$OUT/art/AppIcon.iconset" -o "$OUT/art/AppIcon.icns"

echo "==> bundle"
rm -rf "$APP"
PAYLOAD="$APP/Contents/Resources/payload"
mkdir -p "$APP/Contents/MacOS" "$PAYLOAD/data" "$PAYLOAD/lists"
cp "$OUT/$NAME" "$APP/Contents/MacOS/$NAME"
cp "$OUT/art/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$OUT/zapret-helper" "$OUT/ciadpi" "$OUT/tun2socks" "$PAYLOAD/"
cp "$ROOT/Scripts/install.sh" "$ROOT/Scripts/uninstall.sh" "$PAYLOAD/"
cp "$VENDOR/flowseal/bin/ACTIVE_DISCORD_UDP.bin" "$VENDOR/flowseal/bin/quic_initial_www_google_com.bin" "$PAYLOAD/data/"
cp "$VENDOR/flowseal/lists/list-general.txt" "$VENDOR/flowseal/lists/list-google.txt" "$PAYLOAD/lists/"
VERSION="1.0.$(date +%Y%m%d%H%M)"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.zapret.app</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHumanReadableCopyright</key><string>Built on ByeDPI, tun2socks and Flowseal lists.</string>
</dict>
</plist>
EOF

echo "==> sign (ad-hoc)"
for f in "$PAYLOAD/zapret-helper" "$PAYLOAD/ciadpi" "$PAYLOAD/tun2socks"; do
    codesign --force --sign - "$f"
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> dmg"
STAGE="$OUT/dmg"
rm -rf "$STAGE" "$OUT"/*.dmg
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Программы"
cp "$OUT/art/Как открыть.png" "$STAGE/"
hdiutil create -quiet -volname "$NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG"

echo "done: $DMG"

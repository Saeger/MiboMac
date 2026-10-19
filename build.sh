#!/bin/bash
# Builds MiboMac.app for local use. Requires Xcode Command Line Tools and Homebrew ffmpeg (brew install ffmpeg).
# For a self-contained app to run on other Macs, use package.sh.
set -euo pipefail
cd "$(dirname "$0")"
# Optional env: FF (FFmpeg prefix), ARCHS (e.g. "arm64 x86_64"), MIN_MACOS. See package.sh.
FF="${FF:-$(brew --prefix ffmpeg 2>/dev/null || echo /opt/homebrew/opt/ffmpeg)}"
ARCHS="${ARCHS:-$(uname -m)}"
MIN_MACOS="${MIN_MACOS:-14.0}"
BUILD=build
APP="$BUILD/MiboMac.app"
rm -rf "$BUILD" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# -S drops the debug map (absolute object-file paths); rpath is only needed for a shared (Homebrew) FFmpeg.
LDFLAGS=(-Xlinker -S)
compgen -G "$FF/lib/libavformat*.dylib" >/dev/null && LDFLAGS+=(-Xlinker -rpath -Xlinker "$FF/lib")

BINS=()
for ARCH in $ARCHS; do
  clang -O2 -Wall -arch "$ARCH" -mmacosx-version-min="$MIN_MACOS" -ffile-prefix-map="$PWD"=. \
    -c Sources/CPlayer/mibo_player.c \
    -I"$FF/include" -o "$BUILD/mibo_player-$ARCH.o"
  swiftc -O -swift-version 5 -parse-as-library -target "$ARCH-apple-macos$MIN_MACOS" \
    -import-objc-header Sources/App/Bridging-Header.h -Xcc -I"$FF/include" \
    Sources/App/*.swift "$BUILD/mibo_player-$ARCH.o" \
    -L"$FF/lib" -lavformat -lavcodec -lavutil -lswscale -lswresample \
    "${LDFLAGS[@]}" \
    -o "$BUILD/MiboMac-$ARCH"
  BINS+=("$BUILD/MiboMac-$ARCH")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/MiboMac"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Mibo</string>
  <key>CFBundleDisplayName</key><string>Mibo</string>
  <key>CFBundleIdentifier</key><string>io.github.saeger.mibomac</string>
  <key>CFBundleExecutable</key><string>MiboMac</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

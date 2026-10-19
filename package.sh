#!/bin/bash
# Builds a self-contained, universal (arm64 + x86_64) MiboMac.app for macOS 14+ and packages it
# as dist/MiboMac.zip and dist/MiboMac.dmg. FFmpeg is compiled from source as a minimal static
# library, so the target Mac needs nothing installed (no Homebrew).
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
FFVER=8.1.1
MIN_MACOS=14.0
VENDOR="$ROOT/vendor"
UNIVERSAL="$VENDOR/ffmpeg-universal"
LIBS="avformat avcodec avutil swscale swresample"

build_ffmpeg() {
  local arch=$1
  local prefix="$VENDOR/ffmpeg-$arch"
  [ -f "$prefix/lib/libavformat.a" ] && return
  local src="$VENDOR/build-$arch"
  rm -rf "$src" && mkdir -p "$src"
  tar xf "$VENDOR/ffmpeg-$FFVER.tar.xz" -C "$src" --strip-components 1
  local extra=()
  [ "$arch" = x86_64 ] && extra=(--enable-cross-compile --disable-x86asm)
  (cd "$src" && ./configure --prefix="$prefix" --arch="$arch" --target-os=darwin \
    --cc="clang -arch $arch" --extra-cflags="-mmacosx-version-min=$MIN_MACOS -ffile-prefix-map=$src=ffmpeg" \
    --extra-ldflags="-arch $arch -mmacosx-version-min=$MIN_MACOS" \
    --enable-static --disable-shared --disable-programs --disable-doc --disable-autodetect \
    --disable-everything --disable-avdevice --disable-avfilter --enable-pthreads --enable-network \
    --enable-protocol=tcp,udp,rtp,http \
    --enable-demuxer=rtsp,sdp,rtp \
    --enable-decoder=h264,hevc,aac,aac_latm,pcm_alaw,pcm_mulaw,mjpeg \
    --enable-parser=h264,hevc,aac,aac_latm,mjpeg \
    --enable-swscale --enable-swresample ${extra[@]+"${extra[@]}"} >/dev/null &&
    make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null)
  rm -rf "$src"
}

if [ ! -f "$UNIVERSAL/lib/libavformat.a" ]; then
  mkdir -p "$VENDOR"
  [ -f "$VENDOR/ffmpeg-$FFVER.tar.xz" ] ||
    curl -fsSL -o "$VENDOR/ffmpeg-$FFVER.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$FFVER.tar.xz"
  for a in arm64 x86_64; do echo "Building FFmpeg $FFVER ($a)…"; build_ffmpeg $a; done
  rm -rf "$UNIVERSAL" && mkdir -p "$UNIVERSAL/lib"
  cp -R "$VENDOR/ffmpeg-arm64/include" "$UNIVERSAL/"
  for l in $LIBS; do
    lipo -create "$VENDOR/ffmpeg-arm64/lib/lib$l.a" "$VENDOR/ffmpeg-x86_64/lib/lib$l.a" \
      -output "$UNIVERSAL/lib/lib$l.a"
  done
fi

FF="$UNIVERSAL" ARCHS="arm64 x86_64" MIN_MACOS="$MIN_MACOS" ./build.sh

APP=build/MiboMac.app
if otool -L "$APP/Contents/MacOS/MiboMac" | grep -qE '/opt/homebrew|/usr/local'; then
  echo "error: app still links non-system libraries" >&2; exit 1
fi
if grep -qaF "$HOME" "$APP/Contents/MacOS/MiboMac"; then
  echo "error: binary embeds local paths under $HOME (delete vendor/ffmpeg-* and rebuild)" >&2; exit 1
fi

rm -rf dist && mkdir -p dist/dmg
ditto -c -k --keepParent --norsrc --noextattr "$APP" dist/MiboMac.zip
cp -R "$APP" dist/dmg/ && ln -s /Applications dist/dmg/Applications
hdiutil create -quiet -volname Mibo -srcfolder dist/dmg -format UDZO -ov dist/MiboMac.dmg
rm -rf dist/dmg
echo "Packaged dist/MiboMac.zip and dist/MiboMac.dmg ($(lipo -archs "$APP/Contents/MacOS/MiboMac"), macOS $MIN_MACOS+)"

#!/bin/sh
# Builds a minimal FFmpeg for iOS as Vendor/ShioriFFmpeg.xcframework (static, with a CFFmpeg
# module map): the ASF demuxer and the WMV 9 (wmv3) and WMA 2 (wmav2) decoders, nothing else
# (no programs, protocols, filters, scalers, encoders, network or external libraries).
# LGPL-2.1-or-later as configured (no --enable-gpl, no --enable-nonfree).
# NEKOPARA Vol. 3's movies are read from memory through a custom AVIOContext.
# Run Scripts/catsystem/fetch-ffmpeg.sh first.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$PWD
SRC=$ROOT/Vendor/ffmpeg
WORK=$ROOT/build/ffmpeg
OUT=$ROOT/Vendor/ShioriFFmpeg.xcframework
MIN=18.0
COMMON="--disable-everything --disable-autodetect --disable-programs --disable-doc --disable-network \
  --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample --disable-pixelutils \
  --disable-debug --enable-static --disable-shared --enable-pic --enable-cross-compile \
  --target-os=darwin --arch=aarch64 \
  --enable-demuxer=asf --enable-decoder=wmv3,wmav2"

build() { # name sdk min-flag
  name=$1; sdk=$2; minflag=$3
  dir=$WORK/$name
  rm -rf "$dir"; mkdir -p "$dir"
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc="$(xcrun --sdk "$sdk" --find clang)"
  echo "==> FFmpeg $name"
  (cd "$dir" && "$SRC/configure" $COMMON --prefix="$dir/install" --sysroot="$sysroot" \
      --cc="$cc" --extra-cflags="-arch arm64 $minflag" --extra-ldflags="-arch arm64 $minflag" >/dev/null \
    && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null)
  libtool -static -o "$dir/libffmpeg.a" "$dir/install/lib/libavformat.a" "$dir/install/lib/libavcodec.a" \
    "$dir/install/lib/libavutil.a" 2>/dev/null
  cat > "$dir/install/include/CFFmpeg.h" <<'H'
#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libavutil/channel_layout.h"
#include "libavutil/mem.h"
#include "libavutil/samplefmt.h"
H
  # In a folder of its own: Xcode copies every xcframework's headers into one include folder,
  # and ShioriVPX's module map is already at its top.
  mkdir -p "$dir/install/include/CFFmpeg"
  cat > "$dir/install/include/CFFmpeg/module.modulemap" <<'MAP'
module CFFmpeg {
    header "../CFFmpeg.h"
    link "ffmpeg"
    export *
}
MAP
}

rm -rf "$WORK" "$OUT"
build device iphoneos "-miphoneos-version-min=$MIN"
build simulator iphonesimulator "-mios-simulator-version-min=$MIN"

xcodebuild -create-xcframework \
  -library "$WORK/device/libffmpeg.a" -headers "$WORK/device/install/include" \
  -library "$WORK/simulator/libffmpeg.a" -headers "$WORK/simulator/install/include" \
  -output "$OUT" >/dev/null
echo "==> $OUT"

#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.
#
# Builds a minimal FFmpeg for iOS as Vendor/ShioriFFmpeg.xcframework (static, with a CFFmpeg
# module map): the ASF and MPEG program-stream demuxers, the Windows Media video (WMV 7/8/9,
# VC-1) and audio (WMA 1/2, Pro, Lossless) decoders, and the MPEG-1/2 video and MPEG audio
# layer 2/3 decoders, nothing else (no programs, protocols, filters, scalers, encoders, network
# or external libraries). LGPL-2.1-or-later as configured (no --enable-gpl, --enable-nonfree or
# --enable-version3).
# Users: CatSystem2 (NEKOPARA Vol. 3's WMV movies, read from memory through a custom
# AVIOContext), ShioriKrkr (links this library; WORLD END ECONOMiCA's .mpg movies) and Siglus
# (siglus_rs's WMV/WMA and MPEG-1/2 video, decoded by the app through siglus_set_host_media,
# App/Sources/Engines/Siglus/SiglusMedia.swift).
# Scripts/ffmpeg/build-ffmpeg-macos.sh builds the same configuration for the ShioriKrkr harness.
# Run Scripts/ffmpeg/fetch-ffmpeg.sh first.
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
  --enable-demuxer=asf,mpegps,mpegvideo \
  --enable-decoder=wmv1,wmv2,wmv3,vc1,wmav1,wmav2,wmapro,wmalossless,mpeg1video,mpeg2video,mp2,mp3 \
  --enable-parser=mpegvideo,mpegaudio"

build() { # name sdk min-flag
  name=$1; sdk=$2; minflag=$3
  dir=$WORK/$name
  rm -rf "$dir"; mkdir -p "$dir"
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  cc="$(xcrun --sdk "$sdk" --find clang)"
  echo "==> FFmpeg $name"
  # Installed through DESTDIR, so the configuration FFmpeg embeds (avcodec_configuration()) names
  # no local folder.
  (cd "$dir" && "$SRC/configure" $COMMON --prefix=/usr/local --sysroot="$sysroot" \
      --cc="$cc" --extra-cflags="-arch arm64 $minflag" --extra-ldflags="-arch arm64 $minflag" >/dev/null \
    && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install DESTDIR="$dir/stage" >/dev/null)
  mv "$dir/stage/usr/local" "$dir/install"
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

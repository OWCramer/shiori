#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.
#
# The ShioriKrkr Mac harness's FFmpeg: the same minimal LGPL-2.1+ configuration as the app's
# Vendor/ShioriFFmpeg.xcframework (Scripts/catsystem/build-ios-ffmpeg.sh) - the ASF demuxer
# and the Windows Media video and audio decoders, the MPEG program-stream demuxer and the
# MPEG-1/2 video and MPEG audio decoders - built for macOS into build/ffmpeg-macos/install.
# Run Scripts/catsystem/fetch-ffmpeg.sh first.
set -eu
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd "$(dirname "$0")/../.."
ROOT=$PWD
SRC=$ROOT/Vendor/ffmpeg
DIR=$ROOT/build/ffmpeg-macos
rm -rf "$DIR"
mkdir -p "$DIR"
cd "$DIR"
"$SRC/configure" --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-network \
  --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample --disable-pixelutils \
  --disable-debug --enable-static --disable-shared --enable-pic \
  --arch=aarch64 --extra-cflags="-arch arm64 -mmacosx-version-min=13.0" --extra-ldflags="-arch arm64 -mmacosx-version-min=13.0" \
  --enable-demuxer=asf,mpegps,mpegvideo \
  --enable-decoder=wmv1,wmv2,wmv3,vc1,wmav1,wmav2,wmapro,wmalossless,mpeg1video,mpeg2video,mp2,mp3 \
  --enable-parser=mpegvideo,mpegaudio --prefix="$DIR/install" >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
libtool -static -o "$DIR/install/lib/libffmpeg.a" "$DIR/install/lib/libavformat.a" "$DIR/install/lib/libavcodec.a" \
  "$DIR/install/lib/libavutil.a" 2>/dev/null
echo "==> $DIR/install"

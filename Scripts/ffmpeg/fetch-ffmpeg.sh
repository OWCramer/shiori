#!/bin/sh
# Fetches FFmpeg into Vendor/ffmpeg, pinned. Built LGPL-2.1-or-later (no --enable-gpl, no
# nonfree parts), which GPL-3.0 Shiori may link. NEKOPARA Vol. 3's opening and ending movies
# are WMV 9 (WMV3, Main profile) with WMA 2 sound in ASF, which iOS's own players don't play.
# Then run Scripts/catsystem/build-ios-ffmpeg.sh.
set -eu
cd "$(dirname "$0")/../.."
TAG=n8.0.3
mkdir -p Vendor
if [ ! -d Vendor/ffmpeg ]; then
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$TAG" https://github.com/FFmpeg/FFmpeg.git Vendor/ffmpeg
fi
echo "==> Vendor/ffmpeg ($TAG)"

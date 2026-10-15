#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.
#
# Builds the Ren'Py runtimes for Apple TV (Vendor/tv/RenPy8.xcframework, RenPy7, and
# MetalANGLE; same names as iOS, so the app's code finds them the same way) from the
# same renios prebuilts as iOS (Scripts/build-renpy-runtimes.sh): the arm64 objects are
# retagged as tvOS (Scripts/tv/retarget-macho.py) and linked against the tvOS SDK, along
# with a retagged MetalANGLE. Run build-renpy-runtimes.sh first. Safe to re-run.
set -eu
cd "$(dirname "$0")/../.."
export DEVELOPER_DIR="${DEVELOPER_DIR_OVERRIDE:-/Applications/Xcode.app/Contents/Developer}"

SYSTEM_FRAMEWORKS="UIKit Foundation AVFoundation AVKit AudioToolbox CoreAudio CoreGraphics CoreServices
  CoreHaptics CoreMedia CoreVideo GameController ImageIO Metal OpenGLES QuartzCore Security StoreKit VideoToolbox MobileCoreServices"
EXPORTS="launcher_main SDL_SetMainReady SDL_OnApplicationWillResignActive SDL_OnApplicationDidEnterBackground
  SDL_OnApplicationWillEnterForeground SDL_OnApplicationDidBecomeActive SDL_GL_GetCurrentWindow
  vnhub_sdl_send_key vnhub_sdl_send_mouse_motion vnhub_sdl_send_mouse_button vnhub_sdl_watch_input vnhub_sdl_has_keyboard_focus vnhub_sdl_controller_button vnhub_sdl_controller_axis"

# Thin arm64 copies of a prebuilt folder's libraries, retagged for one tvOS slice.
retag_libs() {
  from=$1; to=$2; slice=$3
  rm -rf "$to"; mkdir -p "$to"
  for lib in "$from"/*.a; do
    lipo "$lib" -thin arm64 -output "$to/$(basename "$lib")" 2>/dev/null || cp "$lib" "$to/"
  done
  python3 Scripts/tv/retarget-macho.py "$slice" "$to"/*.a >/dev/null
}

# MetalANGLE for one slice: the iOS framework, thinned to arm64 and retagged.
ANGLE_TV=Vendor/tv/MetalANGLE.xcframework
make_angle() {
  rm -rf "$ANGLE_TV" Vendor/renios-tv/angle
  for slice in device simulator; do
    [ $slice = device ] && src=ios-arm64_armv7 || src=ios-arm64_i386_x86_64-simulator
    fw=Vendor/renios-tv/angle/$slice/MetalANGLE.framework
    mkdir -p "$(dirname "$fw")"
    cp -R "Vendor/renios/MetalANGLE.xcframework/$src/MetalANGLE.framework" "$fw"
    rm -rf "$fw/_CodeSignature"
    lipo "$fw/MetalANGLE" -thin arm64 -output "$fw/MetalANGLE.thin" 2>/dev/null && mv "$fw/MetalANGLE.thin" "$fw/MetalANGLE"
    python3 Scripts/tv/retarget-macho.py "$slice" "$fw/MetalANGLE" >/dev/null
    plutil -replace MinimumOSVersion -string 18.0 "$fw/Info.plist"
    plutil -replace CFBundleSupportedPlatforms -json "[\"$( [ $slice = device ] && echo AppleTVOS || echo AppleTVSimulator )\"]" "$fw/Info.plist"
  done
  xcodebuild -create-xcframework -framework Vendor/renios-tv/angle/device/MetalANGLE.framework \
    -framework Vendor/renios-tv/angle/simulator/MetalANGLE.framework -output "$ANGLE_TV" >/dev/null
}

build_framework() {
  name=$1; prebuilt=$2; python=$3; shift 3
  libs="$*"
  out=Vendor/build/tv/$name
  rm -rf "$out" "Vendor/tv/$name.xcframework"
  for slice in device simulator; do
    if [ $slice = device ]; then
      sdk=appletvos; target=arm64-apple-tvos18.0; dir=release
    else
      sdk=appletvsimulator; target=arm64-apple-tvos18.0-simulator; dir=debug
    fi
    libdir=Vendor/renios-tv/$name-$dir
    retag_libs "$prebuilt/$dir" "$libdir" $slice
    fw="$out/$slice/$name.framework"
    mkdir -p "$fw"
    args=""
    for lib in $libs; do args="$args -l$lib"; done
    for f in $SYSTEM_FRAMEWORKS; do args="$args -framework $f"; done
    for sym in $EXPORTS; do args="$args -Wl,-u,_$sym"; done
    echo "Linking $name ($slice)..."
    # shellcheck disable=SC2086
    xcrun -sdk $sdk clang -dynamiclib -target $target -isysroot "$(xcrun -sdk $sdk --show-sdk-path)" \
      -install_name "@rpath/$name.framework/$name" \
      App/RenPy/runtime_shim.c App/TV/RenPyTVShims.m -fobjc-arc \
      -L "$libdir" -F "Vendor/renios-tv/angle/$slice" -framework MetalANGLE \
      $args -lc++ -liconv -lsqlite3 -lz \
      -Wl,-rpath,@executable_path/Frameworks -Wl,-rpath,@loader_path/.. \
      -Wl,-dead_strip \
      -o "$fw/$name"
    cat > "$fw/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>com.owencramer.vnhub.$(echo $name | tr 'A-Z' 'a-z')</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$python</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>18.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$( [ $slice = device ] && echo AppleTVOS || echo AppleTVSimulator )</string></array>
</dict>
</plist>
PLIST
  done
  xcodebuild -create-xcframework \
    -framework "$out/device/$name.framework" -framework "$out/simulator/$name.framework" \
    -output "Vendor/tv/$name.xcframework" >/dev/null
  echo "Built Vendor/tv/$name.xcframework"
}

mkdir -p Vendor/tv
make_angle
COMMON="renpython renpy avformat avcodec swscale swresample avutil SDL2_image SDL2 avif aom turbojpeg png16 webp fribidi freetype ffi ssl crypto lzma bz2"
build_framework RenPy8 Vendor/renios/prebuilt 3.9 $COMMON python3.9
build_framework RenPy7 Vendor/renios7/prebuilt 2.7 $COMMON python2.7 harfbuzz brotlidec brotlicommon sharpyuv yuv

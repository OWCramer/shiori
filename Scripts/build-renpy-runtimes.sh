#!/bin/sh
# Builds VN Hub's Ren'Py runtimes as dynamic frameworks, from Ren'Py's prebuilt iOS
# static libraries (renios):
#
#   Vendor/RenPy8.xcframework  Ren'Py 8.1.3, CPython 3.9  (Highway Blossoms' version)
#   Vendor/RenPy7.xcframework  Ren'Py 7.8.7, CPython 2.7  (runs Ren'Py 6.99 and 7.x games)
#   Vendor/RenPy7Base/          Ren'Py 7.8.7's own engine code and Python library, bundled
#                               with the app because Ren'Py 7 games run on it
#
# Both runtimes contain CPython, SDL2 and ffmpeg with the same symbol names, so they
# can't be linked into one executable. Each becomes its own framework, and VN Hub loads
# only the one a game needs (one game per process). Vendor/ is gitignored. Safe to re-run.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR_OVERRIDE:-/Applications/Xcode.app/Contents/Developer}"

./Scripts/fetch-renios.sh

# --- Ren'Py 7.8.7 kit ---------------------------------------------------------
R7=Vendor/renios7
R7_VERSION=7.8.7
if [ ! -f "$R7/.version" ] || [ "$(cat "$R7/.version")" != "$R7_VERSION" ]; then
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading Ren'Py $R7_VERSION renios and SDK..."
  curl -fL --progress-bar -o "$tmp/renios.zip" "https://www.renpy.org/dl/$R7_VERSION/renpy-$R7_VERSION-renios.zip"
  curl -fL --progress-bar -o "$tmp/sdk.tar.bz2" "https://www.renpy.org/dl/$R7_VERSION/renpy-$R7_VERSION-sdk.tar.bz2"
  echo "faaabec4ec65efa8803a5a7222f6e40183c5fe8354c1ee4eeb78e978826cee86  $tmp/renios.zip" | shasum -a 256 -c -
  echo "65466068af7c181a143f13d84b0ddf7a6aa58dd8d26e7ccd97cdcadecabcae5a  $tmp/sdk.tar.bz2" | shasum -a 256 -c -
  unzip -q "$tmp/renios.zip" -d "$tmp"
  tar xjf "$tmp/sdk.tar.bz2" -C "$tmp"
  rm -rf "$R7" Vendor/RenPy7Base
  mkdir -p "$R7" Vendor/RenPy7Base/lib
  mv "$tmp/renios/prototype/prebuilt" "$R7/prebuilt"
  sdk="$tmp/renpy-$R7_VERSION-sdk"
  mv "$sdk/renpy" Vendor/RenPy7Base/renpy
  mv "$sdk/lib/python2.7" Vendor/RenPy7Base/lib/python2.7
  cp "$sdk/renpy.py" Vendor/RenPy7Base/renpy.py
  echo "$R7_VERSION" > "$R7/.version"
fi

# --- Frameworks -------------------------------------------------------------
MGL=Vendor/renios/MetalANGLE.xcframework
SYSTEM_FRAMEWORKS="UIKit Foundation AVFoundation AVKit AudioToolbox CoreAudio CoreGraphics CoreMotion CoreServices
  CoreHaptics CoreMedia CoreVideo GameController ImageIO Metal OpenGLES QuartzCore Security StoreKit VideoToolbox MobileCoreServices"
# Symbols VN Hub looks up with dlsym; listed so the linker keeps them.
EXPORTS="launcher_main SDL_SetMainReady SDL_OnApplicationWillResignActive SDL_OnApplicationDidEnterBackground
  SDL_OnApplicationWillEnterForeground SDL_OnApplicationDidBecomeActive SDL_GL_GetCurrentWindow
  vnhub_sdl_send_key vnhub_sdl_send_mouse_motion vnhub_sdl_send_mouse_button vnhub_sdl_watch_input"

build_framework() {
  name=$1; prebuilt=$2; python=$3; shift 3
  libs="$*"
  out=Vendor/build/$name
  rm -rf "$out" "Vendor/$name.xcframework"
  for slice in device simulator; do
    if [ $slice = device ]; then
      sdk=iphoneos; target=arm64-apple-ios26.0; dir=release; mgl=$MGL/ios-arm64_armv7
    else
      sdk=iphonesimulator; target=arm64-apple-ios26.0-simulator; dir=debug; mgl=$MGL/ios-arm64_i386_x86_64-simulator
    fi
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
      App/RenPy/runtime_shim.c \
      -L "$prebuilt/$dir" -F "$mgl" -framework MetalANGLE \
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
  <key>MinimumOSVersion</key><string>26.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$( [ $slice = device ] && echo iPhoneOS || echo iPhoneSimulator )</string></array>
</dict>
</plist>
PLIST
  done
  xcodebuild -create-xcframework \
    -framework "$out/device/$name.framework" -framework "$out/simulator/$name.framework" \
    -output "Vendor/$name.xcframework" >/dev/null
  echo "Built Vendor/$name.xcframework"
}

COMMON="renpython renpy avformat avcodec swscale swresample avutil SDL2_image SDL2 avif aom turbojpeg png16 webp fribidi freetype ffi ssl crypto lzma bz2"
build_framework RenPy8 Vendor/renios/prebuilt 3.9 $COMMON python3.9
# 7.8.7 adds harfbuzz, brotli and libyuv/sharpyuv to the mix.
build_framework RenPy7 "$R7/prebuilt" 2.7 $COMMON python2.7 harfbuzz brotlidec brotlicommon sharpyuv yuv

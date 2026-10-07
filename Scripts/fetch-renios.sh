#!/bin/sh
# Downloads Ren'Py's prebuilt iOS runtime (renios) into Vendor/renios, which the app links.
# Pinned to the Ren'Py version Highway Blossoms ships with; see spec.md, "Ren'Py engine".
# Vendor/ is gitignored (the static libraries are ~270 MB). Safe to re-run.
set -eu
cd "$(dirname "$0")/.."

VERSION=8.1.3
SHA256=27988dc672b2753683f64211dfe39cf87f90aed64948cd9ce2d9be7756fe01cc
DEST=Vendor/renios
STAMP="$DEST/.version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ]; then
  echo "renios $VERSION already in $DEST"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "Downloading renios $VERSION..."
curl -fL --progress-bar -o "$tmp/renios.zip" "https://www.renpy.org/dl/$VERSION/renpy-$VERSION-renios.zip"
echo "$SHA256  $tmp/renios.zip" | shasum -a 256 -c -
unzip -q "$tmp/renios.zip" -d "$tmp"

rm -rf "$DEST"
mkdir -p "$DEST"
# prebuilt/release is iphoneos arm64; prebuilt/debug is the simulator (arm64 + x86_64).
mv "$tmp/renios/prototype/prebuilt" "$DEST/prebuilt"
mv "$tmp/renios/prototype/Frameworks/MetalANGLE.xcframework" "$DEST/MetalANGLE.xcframework"
echo "$VERSION" > "$STAMP"
echo "renios $VERSION ready in $DEST"

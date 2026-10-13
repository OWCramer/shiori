#!/bin/bash
# Archives a Release build for TestFlight and exports the App Store Connect IPA into
# build/export (nothing is uploaded). The build number is the commit count on this branch,
# so each archive from a newer commit is higher than the last.
# Upload afterwards with Xcode's Organizer (Window › Organizer › Distribute App), or
# Transporter with build/export/Shiori.ipa.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
if [ -n "$(git status --porcelain)" ]; then echo "Commit first: the build number comes from the commit count."; exit 1; fi
BUILD=$(git rev-list --count HEAD)
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')
./Scripts/add-privacy-manifests.sh >/dev/null
xcodegen generate --quiet
rm -rf build/Shiori.xcarchive build/export
xcodebuild -project Shiori.xcodeproj -scheme Shiori -configuration Release -destination 'generic/platform=iOS' \
    -archivePath build/Shiori.xcarchive CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)"
# The engine frameworks are prebuilt (Scripts/*/build-*.sh), so the archive has no dSYMs for
# them and App Store Connect's symbol upload warns ("Upload completed with warnings"). Make
# one per framework from its binary, so the UUIDs match (symbolicated as far as the binary's
# debug info allows).
for fw in build/Shiori.xcarchive/Products/Applications/Shiori.app/Frameworks/*.framework; do
    name=$(basename "$fw" .framework)
    dsym="build/Shiori.xcarchive/dSYMs/$name.framework.dSYM"
    # ShioriKrkr keeps the real one from its build (Scripts/krkr2/build-framework.sh).
    if [ ! -d "$dsym" ] && [ -d "Vendor/$name.dSYM/device/$name.framework.dSYM" ]; then
        cp -R "Vendor/$name.dSYM/device/$name.framework.dSYM" "$dsym"
    fi
    [ -d "$dsym" ] || dsymutil "$fw/$name" -o "$dsym" 2>/dev/null || true
done
xcodebuild -exportArchive -archivePath build/Shiori.xcarchive -exportOptionsPlist Scripts/ExportOptions.plist \
    -exportPath build/export -allowProvisioningUpdates | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
echo "Shiori $VERSION ($BUILD): build/Shiori.xcarchive, build/export/Shiori.ipa"

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
xcodebuild -exportArchive -archivePath build/Shiori.xcarchive -exportOptionsPlist Scripts/ExportOptions.plist \
    -exportPath build/export -allowProvisioningUpdates | grep -E "error:|EXPORT (SUCCEEDED|FAILED)"
echo "Shiori $VERSION ($BUILD): build/Shiori.xcarchive, build/export/Shiori.ipa"

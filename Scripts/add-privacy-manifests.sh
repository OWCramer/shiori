#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.
#
# Puts a privacy manifest (Scripts/privacy/Framework.xcprivacy) into every slice of the
# engine frameworks Shiori embeds, as App Store Connect expects of bundled code that uses
# required-reason APIs. The build scripts call this; it's safe to run again.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO/Scripts/privacy/Framework.xcprivacy"
for xcf in "$REPO"/Vendor/RenPy7.xcframework "$REPO"/Vendor/RenPy8.xcframework \
           "$REPO"/Vendor/ShioriSiglus.xcframework "$REPO"/Vendor/ShioriKrkr.xcframework \
           "$REPO"/Vendor/renios/MetalANGLE.xcframework; do
    [ -d "$xcf" ] || continue
    for framework in "$xcf"/*/*.framework; do
        cp "$MANIFEST" "$framework/PrivacyInfo.xcprivacy"
        echo "==> ${framework#$REPO/}/PrivacyInfo.xcprivacy"
    done
done

#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.
#
# Fails loudly if anything of the Standard KiriKiri engine (AetherKrkr, GPL-3.0) is in an app
# bundle: its framework (ShioriKiriKiri), a link to it, or Aether's symbols or strings in any
# file. It left the app on 2026-10-15 (spec Decisions, "App Store release"); Aether stays only
# as a Mac developer tool (Scripts/kirikiri). archive-testflight.sh runs this on every archive.
#   Scripts/check-no-aether.sh path/to/Shiori.app
set -uo pipefail
APP=${1:?usage: check-no-aether.sh Shiori.app}
[ -d "$APP" ] || { echo "check-no-aether: no app at $APP"; exit 1; }
found=()
[ -e "$APP/Frameworks/ShioriKiriKiri.framework" ] && found+=("Frameworks/ShioriKiriKiri.framework is embedded")
# Names that only come from Aether: the project, its engine and runtime, its C interface and
# the setup calls Shiori exported from its framework.
pattern='aether|engine_api|engine_create|engine_open_game|engine_gpu_bridge|shiori_krkr_install_services|shiori_krkr_ensure_core|shiori_krkr_metal|ShioriKiriKiri|CKiriKiri'
files=0
while IFS= read -r -d '' file; do
    files=$((files + 1))
    name=${file#"$APP"/}
    if file -b "$file" | grep -q "Mach-O"; then
        otool -L "$file" 2>/dev/null | grep -q "ShioriKiriKiri" && found+=("$name links ShioriKiriKiri")
        count=$(nm -a "$file" 2>/dev/null | grep -Eic "$pattern")
        [ "$count" -gt 0 ] && found+=("$name has $count Aether symbols: $(nm -a "$file" 2>/dev/null | grep -Ei "$pattern" | head -3 | awk '{print $NF}' | tr '\n' ' ')")
    fi
    # Strings in every file: binaries, resources, scripts.
    hits=$(strings -a "$file" 2>/dev/null | grep -Eio "$pattern" | sort -u | tr '\n' ' ')
    [ -n "$hits" ] && found+=("$name contains: $hits")
done < <(find "$APP" -type f -print0)
if [ ${#found[@]} -gt 0 ]; then
    echo ""
    echo "error: ======================================================================"
    echo "error: AETHER IN THE APP: the Standard KiriKiri engine (AetherKrkr) must never ship."
    for line in "${found[@]}"; do echo "error:   $line"; done
    echo "error: ======================================================================"
    exit 1
fi
echo "check-no-aether: nothing of Aether in $(basename "$APP") ($files files)"

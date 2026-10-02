#!/bin/bash
# Packages an already-built app without modifying or re-signing it.
set -euo pipefail
if [[ $# -ne 2 ]]; then
    echo 'Usage: package-dmg.sh /absolute/Portmaster.app /absolute/output.dmg' >&2
    exit 2
fi
app_path="$1"
output_path="$2"
[[ "$app_path" = /* && "$output_path" = /* ]] || { echo 'Use absolute paths.' >&2; exit 2; }
[[ -d "$app_path/Contents/MacOS" && -f "$app_path/Contents/Info.plist" ]] || { echo 'Input must be a built .app bundle.' >&2; exit 2; }
[[ ! -e "$output_path" ]] || { echo 'Output already exists; choose a new filename.' >&2; exit 2; }
/usr/bin/codesign --verify --deep --strict "$app_path"
stage_path=$(/usr/bin/mktemp -d /tmp/portmaster-dmg.XXXXXX)
trap '/bin/rm -rf "$stage_path"' EXIT
/usr/bin/ditto "$app_path" "$stage_path/Portmaster.app"
/bin/ln -s /Applications "$stage_path/Applications"
if /usr/bin/codesign -dv "$app_path" 2>&1 | /usr/bin/grep -q 'Authority=Developer ID Application'; then
    cat > "$stage_path/Install.txt" <<'TXT'
Drag Portmaster.app onto Applications, then launch it from Applications.
Launching from this read-only disk image prevents installing updates.
TXT
else
    cat > "$stage_path/Install.txt" <<'TXT'
LOCAL DEVELOPMENT BUILD — not notarized for public distribution.
Drag Portmaster.app onto Applications, then launch it from Applications.
Launching from this read-only disk image prevents installing updates.
Release distribution requires Developer ID signing and notarization.
TXT
fi
/bin/mkdir -p "$(/usr/bin/dirname "$output_path")"
/usr/bin/hdiutil create -volname Portmaster -srcfolder "$stage_path" -format UDZO "$output_path"
/usr/bin/hdiutil verify "$output_path"
/usr/bin/shasum -a 256 "$output_path"

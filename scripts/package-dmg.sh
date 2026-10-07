#!/bin/bash
# Packages an already-signed app without modifying its signature.
#
# SIGNING IS NOT DONE HERE. Run `scripts/sign-and-notarize.sh` first, against a
# universal Release build, and this only turns the signed bundle into a DMG.
#
# Why the order matters: `codesign --verify --deep` below checks the app's seal, but a
# re-signed bundle is what this script refuses to accept. The nested
# `Contents/Resources/portmaster-mcp` and Sparkle.framework each need the app's own
# signature, and `scripts/sign-and-notarize.sh` is what applies it.
#
# Notarization is deliberately not attempted here. It belongs to the signing step,
# because notarization is per code object and has to happen before the bundle is
# compressed — notarizing a DMG, or a bundle whose contents were re-signed afterwards,
# produces a ticket that describes bytes that no longer exist.
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

# Universal binary check, before anything is staged.
#
# Xcode's default is `ARCHS = arm64` with `ONLY_ACTIVE_ARCH = YES`, which is
# correct for a fast local build and silently produces a Mac-only app. That
# failure is invisible: the bundle looks fine, launches fine on the build
# machine, and only reveals itself as "this app won't open" on someone else's
# Intel Mac. `project.yml` now pins both architectures; this asserts the built
# product actually carries them, so a hand-passed `-arch arm64` to xcodebuild
# fails here rather than in a user's hands.
binary="$app_path/Contents/MacOS/Portmaster"
archs=$(/usr/bin/lipo -archs "$binary" 2>/dev/null || echo "unknown")
for required in arm64 x86_64; do
    case " $archs " in
        *" $required "*) ;;
        *)
            echo "Refusing to package: $binary is missing $required." >&2
            echo "  architectures present: $archs" >&2
            echo "  Build universal (see README 'Building'), e.g.:" >&2
            echo "    xcodebuild -project Portmaster.xcodeproj -scheme Portmaster \\" >&2
            echo "      -configuration Release ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build" >&2
            exit 1
            ;;
    esac
done
echo "Architectures OK: $archs"

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

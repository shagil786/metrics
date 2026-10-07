#!/bin/bash
# Packages an already-built app without modifying or re-signing it.
#
# THE NEXT STEP FOR A RELEASE IS HERE, AND IT IS NOT DONE. This script re-signs
# nothing, so whatever signature the app arrived with is the signature it ships
# with. For a Developer ID build that is not enough: the nested
# `Contents/Resources/portmaster-mcp` is ad-hoc signed by
# `scripts/embed-mcp-cli.sh`, and a nested executable must carry the *app's* Developer
# ID signature or Gatekeeper on another Mac refuses to run it — even when the app
# itself is properly signed and notarized. The Settings page then names a binary that
# will not start, which is the exact defect the embedded CLI exists to remove.
#
# So a release build must sign the bundle once, deepest first, before this runs:
#
#   codesign --force --options runtime --timestamp \
#     --sign "Developer ID Application: …" \
#     "$app/Contents/Resources/portmaster-mcp"
#   codesign --force --options runtime --timestamp \
#     --sign "Developer ID Application: …" "$app"
#   codesign --verify --deep --strict "$app"
#   # then notarize, then package.
#
# Nothing in this repository has been run against a notarized copy, so the sequence
# above is written down rather than demonstrated. Treat it as release work, not as
# something already handled.
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

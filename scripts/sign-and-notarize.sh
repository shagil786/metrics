#!/bin/bash
# Signs an already-built Portmaster.app, and notarizes it when a real Apple-issued
# Developer ID certificate is available.
#
# WHY THIS EXISTS
#
# `package-dmg.sh` re-signs nothing: whatever signature the app arrived with is the
# signature it ships with. That is fine for a local build and fatal for a release,
# because a bundle's nested executables must carry the *app's* signature. Gatekeeper
# checks each Mach-O separately, and a nested binary signed differently from the app
# fails even when the app itself is perfectly signed and notarized. The symptom is
# specific and confusing: the app opens, and one named feature is dead — here, the
# Settings page's "Copy install command" button names a `portmaster-mcp` that will not
# start, which is the exact defect the embedded CLI exists to remove.
#
# WHAT MUST BE SIGNED
#
# Not just the app and the embedded CLI. Sparkle.framework carries its own nested
# executables — Autoupdate, Updater.app, and the Downloader/Installer XPC services —
# and each is a separate code object to Gatekeeper. Signing the app last, deepest
# first, is not an optimization: a signature covers the bytes of what it signed, so
# re-signing the app after signing its contents is correct, while signing the contents
# after the app would invalidate the app's own seal.
#
# ORDER MATTERS AND IS NOT INTERCHANGEABLE
#
#   1. every nested binary, deepest first
#   2. Sparkle.framework
#   3. the .app bundle itself
#   4. verify
#   5. notarize (submit the .app, not a DMG — notarization is per-code-object)
#   6. staple the ticket to the app
#   7. re-verify, because stapling rewrites the bundle
#
# HARDENED RUNTIME
#
# `--options runtime` is required for notarization and is not optional decoration. It
# turns off DYLD injection, unsigned-code loading and similar, which is also what makes
# the notarized build trustworthy rather than merely accepted.
#
# WHAT IS *NOT* DONE HERE, AND WHY IT MATTERS
#
# Neither signing nor notarization has ever been run against a build in this
# repository. Everything above is written from the documented requirement and the
# bundle's actual layout, not from an observed notarization. Until it is, treat a
# release as unverified at this step rather than as proven.
#
# --ad-hoc signs with a self-signed certificate instead. That produces a bundle that
# runs on this machine and on machines where the user right-clicks → Open, and is NOT
# distributable: anyone else gets a Gatekeeper refusal, and `--timestamp` is
# unavailable for a certificate Apple did not issue. It exists so the nested-binary
# defect can be closed locally without pretending that path is a release path.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage: sign-and-notarize.sh [--ad-hoc] [--identity NAME] /absolute/Portmaster.app

  --ad-hoc           Sign with a self-signed certificate. Local use only; Gatekeeper
                     will refuse the result on any other Mac, and it cannot be
                     notarized.
  --identity NAME    Sign with this certificate from the keychain. Use for the real
                     "Developer ID Application: …" identity once you have one.

With neither flag, the script refuses rather than guessing: silently signing with
the wrong identity produces a bundle that looks signed and is not trusted.

Notarization additionally needs notarytool credentials. Store them once with:

    xcrun notarytool store-credentials notarytool

Without credentials, --ad-hoc and local --identity runs sign and verify but skip
notarization, and say so.
USAGE
    exit 2
}

ad_hoc=0
identity=''
app_path=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ad-hoc) ad_hoc=1 ;;
        --identity)
            shift
            [[ $# -gt 0 ]] || { echo '--identity needs a value.' >&2; exit 2; }
            identity="$1"
            ;;
        -h|--help) usage ;;
        -*) echo "Unknown option: $1" >&2; usage ;;
        *)
            [[ -z "$app_path" ]] || { echo 'Give exactly one .app path.' >&2; exit 2; }
            app_path="$1"
            ;;
    esac
    shift
done

[[ -n "$app_path" ]] || usage
[[ "$app_path" = /* ]] || { echo 'Use an absolute path.' >&2; exit 2; }
[[ -d "$app_path/Contents/MacOS" && -f "$app_path/Contents/Info.plist" ]] \
    || { echo 'Input must be a built .app bundle.' >&2; exit 2; }

if [[ $ad_hoc -eq 1 && -n "$identity" ]]; then
    echo '--ad-hoc and --identity are different modes; pass one.' >&2
    exit 2
fi
if [[ $ad_hoc -eq 0 && -z "$identity" ]]; then
    echo 'Refusing to sign: no identity given and --ad-hoc not passed.' >&2
    echo 'See --help. Signing with the wrong certificate looks fine and is not trusted.' >&2
    exit 2
fi

# The signing flags differ by mode in more than the certificate name. `--timestamp`
# asks the timestamp authority to countersign so a signature outlives the
# certificate; that only exists for certificates Apple issued, and asking for it with
# a self-signed one fails rather than silently degrading.
hardened_runtime=1

# A self-signed certificate has no Team ID, and the hardened runtime turns on library
# validation, which requires every loaded image to carry the *same* Team ID as the main
# executable. With no Team ID the two can never match, so the hardened runtime plus a
# self-signed certificate is not a stricter build — it is a bundle that will not launch:
#
#   dyld: Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
#     Reason: … mapping process and mapped file (non-platform) have different Team IDs
#
# Measured on this repository's own Release build: signed with the self-signed
# "Sotto Dev" identity and `--options runtime`, it fails to launch; the same bundle
# signed without `--options runtime` launches. So the flag is dropped for local runs
# rather than shipping a signed bundle that dies at dyld, and it is reported, because
# silently producing a weaker signature would be the more dangerous of the two.
identity_team=$(security find-certificate -c "$identity" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([^,]*\).*/\1/p')
if [[ -n "$identity_team" ]]; then
    echo "Identity team: $identity_team"
else
    echo "Note: '$identity' carries no Team ID (OU), so the hardened runtime cannot be" >&2
    echo '      used: library validation would reject the app'"'"'s own embedded framework' >&2
    echo '      and the app would fail to launch. Signing without it. Not notarizable.' >&2
    hardened_runtime=0
    notarize_possible=0
fi

if [[ $ad_hoc -eq 1 ]]; then
    # codesign's bare "-" is a true ad-hoc signature, which carries no Team ID either,
    # so it has the same constraint as a self-signed certificate.
    signing_flags=(--force --sign -)
    notarize_possible=0
    mode_description='ad-hoc (self-signed; not distributable)'
elif [[ $hardened_runtime -eq 1 ]]; then
    signing_flags=(--force --options runtime --timestamp --sign "$identity")
    notarize_possible=1
    mode_description="$identity"
else
    signing_flags=(--force --sign "$identity")
    mode_description="$identity (no hardened runtime; not notarizable)"
fi

if [[ $hardened_runtime -eq 1 ]]; then
    signing_flags+=(--options runtime)
fi

echo "Signing: $mode_description"

# Deepest first. Collected rather than hard-coded so a dependency that later adds its
# own helper binaries gets signed without editing this script — the failure mode being
# fixed here is precisely a nested executable left with a signature that does not match
# its parent, and a hard-coded list goes stale silently.
#
# `--deep` is deliberately NOT used for signing. It signs nested code as a side effect
# but does not guarantee the order, and its ordering is not documented; this walks the
# tree explicitly instead.
nested=()
while IFS= read -r file; do
    nested+=("$file")
done < <(find "$app_path/Contents" \
    \( -type f -perm -111 -o -name '*.dylib' -o -name '*.so' \) \
    ! -path "$app_path/Contents/MacOS/Portmaster" \
    | sort -r)

for file in "${nested[@]}"; do
    echo "  signing $(basename "$file")"
    /usr/bin/codesign "${signing_flags[@]}" "$file"
done

# The framework last among the nested objects, so its own signature is not invalidated
# by the executables inside it.
for fw in "$app_path/Contents/Frameworks/"*.framework; do
    [[ -e "$fw" ]] || continue
    echo "  signing $(basename "$fw")"
    /usr/bin/codesign "${signing_flags[@]}" "$fw"
done

# The app itself last, so it seals the already-signed contents.
echo "  signing the app bundle"
/usr/bin/codesign "${signing_flags[@]}" "$app_path"

echo "Verifying"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
# `--deep --verify` can pass while an inner object is still mismatched on some
# toolchain versions, so each nested object is checked on its own as well.
for file in "${nested[@]}"; do
    /usr/bin/codesign --verify --strict "$file"
done

if [[ $notarize_possible -eq 0 ]]; then
    echo
    echo 'Signed ad-hoc. This bundle runs here and on machines that allow it,' >&2
    echo 'but Gatekeeper will refuse it elsewhere and it carries no notarization.' >&2
    exit 0
fi

if ! /usr/bin/xcrun notarytool history --keychain-profile notarytool >/dev/null 2>&1; then
    echo
    echo 'No notarytool credentials found, so notarization was skipped.' >&2
    echo 'Store them once with: xcrun notarytool store-credentials notarytool' >&2
    echo 'The bundle is signed and verified, but NOT notarized.' >&2
    exit 0
fi

work_dir=$(/usr/bin/mktemp -d /tmp/portmaster-notarize.XXXXXX)
trap '/bin/rm -rf "$work_dir"' EXIT

# Zip with ditto, preserving the bundle layout and extended attributes. `zip -r` drops
# the symlinks inside .app and produces an archive notarytool refuses.
echo 'Submitting for notarization'
if ! /usr/bin/ditto -c -k --keepParent "$app_path" "$work_dir/Portmaster.zip"; then
    echo 'Could not create the notarization archive.' >&2
    exit 1
fi
if ! /usr/bin/xcrun notarytool submit "$work_dir/Portmaster.zip" \
    --keychain-profile notarytool --wait; then
    echo 'Notarization failed. notarytool prints the rejection reason above;' >&2
    echo 'the common causes are an unsigned nested binary or a missing hardened runtime.' >&2
    exit 1
fi

echo 'Stapling the ticket'
if ! /usr/bin/xcrun stapler staple "$app_path"; then
    echo 'Notarization succeeded but stapling failed.' >&2
    echo 'A non-stapled but notarized bundle still opens after a first-launch network check;' >&2
    echo 'stapling is what lets it open offline.' >&2
    exit 1
fi

# Stapling writes into the bundle, so the verification that ran before it is no longer
# evidence about the artifact being handed over.
echo 'Verifying the stapled bundle'
/usr/bin/xcrun stapler validate "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"

echo
echo 'Signed, notarized and stapled.'
echo 'Now package it: scripts/package-dmg.sh '"$app_path"' /absolute/output.dmg'
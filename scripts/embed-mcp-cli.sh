#!/bin/bash
# embed-mcp-cli.sh: copy the built `portmaster-mcp` into the app bundle's Contents/Resources.
#
# Run as an Xcode post-build phase. Xcode has already built the executable by this point —
# the target declares `portmaster-mcp` as a package product dependency with `link: false` —
# so this only copies a file that exists. It deliberately does **not** shell out to
# `swift build`: that would take SwiftPM's build lock, make every app build depend on the
# toolchain being installed, and hang when a `swift test` run already holds the lock.
#
# Contents/Resources rather than Contents/Frameworks, because this is a server executable an
# MCP client spawns, not a library the app links. `MCPInstallCommand.binaryCandidates`
# searches the bundle's Resources directory first for exactly this path.
#
# SIGNING. The copy is signed ad-hoc here (`codesign -s -`), which is what makes it runnable
# from a locally built app. It is NOT what a distributed build needs: a nested executable
# must carry the same Developer ID signature as the app for Gatekeeper to run it on another
# Mac even when the app itself is notarized, and `scripts/package-dmg.sh` re-signs nothing.
# Task 10's release path has to sign the bundle once, deepest-first, before packaging. A
# local build cannot exercise that, so nothing here has been checked against a notarized copy.
set -euo pipefail

source_binary="${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR is not set}/portmaster-mcp"
destination_dir="${CODESIGNING_FOLDER_PATH:?CODESIGNING_FOLDER_PATH is not set}/Contents/Resources"

if [[ ! -f "$source_binary" ]]; then
  # Loud, and failing: a bundle that silently ships without its CLI is an app whose
  # "Copy install command" button has nothing to name, which is the exact defect this
  # packaging exists to remove.
  echo "error: portmaster-mcp was not built at $source_binary" >&2
  exit 1
fi

mkdir -p "$destination_dir"
cp "$source_binary" "$destination_dir/portmaster-mcp"
chmod +x "$destination_dir/portmaster-mcp"
/usr/bin/codesign --force --sign - "$destination_dir/portmaster-mcp"
echo "embedded $destination_dir/portmaster-mcp"

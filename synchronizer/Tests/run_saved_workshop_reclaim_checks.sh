#!/bin/zsh
# Compiles SavedWorkshopReclaim plus its checks into a throwaway binary and runs
# them. No Steam, no real library, no user preferences: the fixture lives in
# TMPDIR and is removed on exit.
set -euo pipefail
here="${0:A:h}"
repo="${here:h:h}"
staging=$(mktemp -d "${TMPDIR:-/tmp}/we-reclaim-checks.XXXXXX")
trap 'rm -rf "$staging"' EXIT
binary="$staging/checks"

xcrun swiftc -O -target arm64-apple-macos14.0 \
    "$repo/native/Sources/WallpaperEngineNativeHost/SavedWorkshopReclaim.swift" \
    "$here/SavedWorkshopReclaimChecks.swift" \
    -o "$binary"
"$binary"

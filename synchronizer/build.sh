#!/bin/zsh
set -euo pipefail
base=${0:A:h}
mkdir -p "$base/build"
staging_binary=$(mktemp "$base/build/.we-workshop.XXXXXX")
trap 'rm -f "$staging_binary"' EXIT
xcrun swiftc -O -target arm64-apple-macos14.0 -framework Security "$base/main.swift" "$base/SteamLibrary.swift" "$base/SteamNative.swift" "$base/SteamEvents.swift" "$base/SteamDownloadProgress.swift" "$base/WorkshopBrowse.swift" -o "$staging_binary"
mv "$staging_binary" "$base/build/we-workshop"
printf '%s\n' "$base/build/we-workshop"

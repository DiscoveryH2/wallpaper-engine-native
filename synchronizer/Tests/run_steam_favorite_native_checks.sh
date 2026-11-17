#!/bin/zsh
set -euo pipefail

# Purpose-built tiny fake dylib + isolated temporary helper. This runner never
# discovers Steam, loads Valve's library, starts the host, or reads user data.
base=${0:A:h:h}
work=$(mktemp -d /tmp/we-steam-favorite-check.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

xcrun clang -dynamiclib -arch arm64 "$base/Tests/FakeSteamFavoriteAPI.c" -o "$work/libsteam_api.dylib"
xcrun swiftc -D STEAM_NATIVE_TESTING -O -target arm64-apple-macos14.0 -framework Security \
  "$base/main.swift" "$base/SteamLibrary.swift" "$base/SteamNative.swift" "$base/SteamEvents.swift" "$base/SteamDownloadProgress.swift" "$base/WorkshopBrowse.swift" \
  -o "$work/fake-we-workshop"
xcrun swiftc -D STEAM_NATIVE_TESTING -O -target arm64-apple-macos14.0 -framework Security \
  "$base/Tests/SteamFavoriteNativeChecks.swift" "$base/SteamLibrary.swift" "$base/SteamNative.swift" "$base/SteamEvents.swift" "$base/WorkshopBrowse.swift" \
  -o "$work/SteamFavoriteNativeChecks"
"$work/SteamFavoriteNativeChecks" "$work/libsteam_api.dylib" "$work/fake-we-workshop"

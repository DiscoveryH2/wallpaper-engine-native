#!/bin/zsh
set -euo pipefail

# Purpose-built fake dylib and temporary helper only. This runner never
# discovers Steam, loads Valve's library, launches the host, or reads/writes
# user Steam data. Its HOME is set inside the test binary to a temp directory.
base=${0:A:h:h}
work=$(mktemp -d /tmp/we-steam-user-vote-check.XXXXXX)
trap 'rm -rf -- "$work"' EXIT

xcrun clang -dynamiclib -arch arm64 "$base/Tests/FakeSteamUserVoteAPI.c" -o "$work/libsteam_api.dylib"
xcrun swiftc -D STEAM_NATIVE_TESTING -O -target arm64-apple-macos14.0 -framework Security \
  "$base/main.swift" "$base/SteamLibrary.swift" "$base/SteamNative.swift" "$base/SteamEvents.swift" "$base/SteamDownloadProgress.swift" "$base/WorkshopBrowse.swift" \
  -o "$work/fake-we-workshop"
xcrun swiftc -D STEAM_NATIVE_TESTING -O -target arm64-apple-macos14.0 -framework Security \
  "$base/Tests/SteamUserVoteNativeChecks.swift" "$base/SteamLibrary.swift" "$base/SteamNative.swift" "$base/SteamEvents.swift" "$base/WorkshopBrowse.swift" \
  -o "$work/SteamUserVoteNativeChecks"
"$work/SteamUserVoteNativeChecks" "$work/libsteam_api.dylib" "$work/fake-we-workshop"

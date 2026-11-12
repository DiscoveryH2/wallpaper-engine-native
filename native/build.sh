#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
destination="$script_dir/build/WallpaperEngineNativeHost.app"
if (( $# )); then
    [[ $# == 2 && "$1" == "--output" ]] || { print -u2 'Usage: native/build.sh [--output /absolute/path/App.app]'; exit 2; }
    destination="$2"
fi
[[ "$destination" == /* && "$destination" == *.app && ! -L "$destination" ]] || { print -u2 'Build output must be an absolute .app path, not a symlink.'; exit 2; }
[[ ! -e "$destination" || -d "$destination" ]] || { print -u2 'Build output exists and is not a directory.'; exit 2; }
source_file="$script_dir/Sources/WallpaperEngineNativeHost/main.swift"
plist_file="$script_dir/Info.plist"
app_icon_source="$script_dir/Resources/AppIcon-v3.png"
app_icon_file="$script_dir/Resources/AppIcon-v3.icns"

[[ -f "$source_file" && -f "$plist_file" && -f "$app_icon_source" && -f "$app_icon_file" ]] || { print -u2 'Native host sources or approved app icon assets are incomplete.'; exit 1; }
python3 "$script_dir/../tools/bundled_wallpapers.py" --verify
"$script_dir/../synchronizer/build.sh"
mkdir -p "${destination:h}"
staging_dir=$(mktemp -d "${destination:h}/.native-build.XXXXXX")
app_dir="$staging_dir/WallpaperEngineNativeHost.app"
macos_dir="$app_dir/Contents/MacOS"
previous="$staging_dir/previous.app"
cleanup() {
    if [[ -d "$previous" && ! -e "$destination" ]]; then mv "$previous" "$destination"; fi
    rm -rf "$staging_dir"
}
trap cleanup EXIT
mkdir -p "$macos_dir"
cp "$plist_file" "$app_dir/Contents/Info.plist"
mkdir -p "$app_dir/Contents/Resources/Tools"
cp "$app_icon_file" "$app_dir/Contents/Resources/AppIcon.icns"
ditto "$script_dir/Resources/StarterWallpapers" "$app_dir/Contents/Resources/StarterWallpapers"
cp "$script_dir/../synchronizer/build/we-workshop" "$app_dir/Contents/Resources/Tools/we-workshop"
codesign --force --sign - "$app_dir/Contents/Resources/Tools/we-workshop"
xcrun swiftc -O -target arm64-apple-macos14.0 -framework JavaScriptCore "$script_dir"/SceneScriptHelper/*.swift -o "$app_dir/Contents/Resources/Tools/we-scene-script"
codesign --force --sign - "$app_dir/Contents/Resources/Tools/we-scene-script"
xcrun swiftc -O -target arm64-apple-macos14.0 -framework AppKit -framework Carbon -framework ScreenCaptureKit -framework AVFoundation -framework AudioToolbox -framework CoreGraphics -framework ColorSync -framework CoreServices -framework CoreText -framework CoreAudio -framework ImageIO -framework WebKit -framework OpenGL -framework Metal -framework MetalKit -framework ServiceManagement "$script_dir"/Sources/WallpaperEngineNativeHost/*.swift "$script_dir/SceneScriptHelper/ModuleAdapter.swift" "$script_dir/../synchronizer/WorkshopCoordinator.swift" "$script_dir/../synchronizer/WorkshopSubscriptionChange.swift" "$script_dir/../synchronizer/WorkshopUserVoteChange.swift" "$script_dir/../synchronizer/WorkshopFavoriteChange.swift" "$script_dir/../synchronizer/LibraryController.swift" "$script_dir/../synchronizer/WorkshopBrowse.swift" "$script_dir/../synchronizer/WorkshopBrowserController.swift" "$script_dir/../synchronizer/WorkshopPreviewRequest.swift" "$script_dir/../synchronizer/SteamLibrary.swift" "$script_dir/../synchronizer/SteamLibraryWatcher.swift" "$script_dir/../synchronizer/SteamEvents.swift" "$script_dir/../synchronizer/SteamDownloadProgress.swift" "$script_dir/../synchronizer/SteamEventMonitor.swift" -o "$macos_dir/WallpaperEngineNativeHost"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [[ -e "$destination" ]]; then mv "$destination" "$previous"; fi
mv "$app_dir" "$destination"
print "Built $destination"

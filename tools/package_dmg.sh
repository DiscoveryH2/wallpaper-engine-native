#!/bin/zsh
# Packages a built .app into the release dmg, with the Applications symlink the
# drag-to-install flow needs.
#
#   zsh tools/package_dmg.sh                       # native/build/...a.app -> out/
#   zsh tools/package_dmg.sh --app /path/A.app --output /path/dir
#
# Build first with `zsh native/build.sh`; this script only packages what is
# already signed, and verifies the signature before writing the dmg.
set -euo pipefail

repo="${0:A:h:h}"
app="$repo/native/build/WallpaperEngineNativeHost.app"
output_dir="$repo/out"

while (( $# )); do
    case "$1" in
        --app) app="${2:A}"; shift 2 ;;
        --output) output_dir="${2:A}"; shift 2 ;;
        -h|--help) print -u2 'Usage: tools/package_dmg.sh [--app /abs/A.app] [--output /abs/dir]'; exit 0 ;;
        *) print -u2 "Unknown argument: $1"; exit 2 ;;
    esac
done

[[ -d "$app" ]] || { print -u2 "No built app at $app"; exit 1; }
codesign --verify --deep --strict "$app"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
archs=$(lipo -archs "$app/Contents/MacOS/WallpaperEngineNativeHost")
dmg_name="Wallpaper-Engine-Native-${version}-arm64.dmg"
dmg="$output_dir/$dmg_name"

mkdir -p "$output_dir"
staging=$(mktemp -d "${TMPDIR:-/tmp}/we-dmg.XXXXXX")
trap 'hdiutil detach "/Volumes/Wallpaper Engine Native $version" >/dev/null 2>&1 || true; rm -rf "$staging"' EXIT

# Finder shows CFBundleDisplayName, but the bundle directory name is what every
# documented path ("/Applications/Wallpaper Engine Native.app") must match.
bundle_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$app/Contents/Info.plist")
[[ -n "$bundle_name" ]] || { print -u2 'App has no CFBundleName'; exit 1; }
ditto "$app" "$staging/$bundle_name.app"
ln -s /Applications "$staging/Applications"

rm -f "$dmg"
hdiutil create -quiet -volname "Wallpaper Engine Native $version" \
    -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"

# Verify the artifact the way a user meets it: mount read-only, check the app
# inside matches the version we packaged, then unmount.
hdiutil attach -quiet -readonly -nobrowse "$dmg"
mounted="/Volumes/Wallpaper Engine Native $version"
packaged_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$mounted/$bundle_name.app/Contents/Info.plist")
[[ "$packaged_version" == "$version" ]] || { print -u2 "dmg contains $packaged_version, expected $version"; exit 1; }
[[ -L "$mounted/Applications" ]] || { print -u2 'dmg is missing the Applications symlink'; exit 1; }
hdiutil detach -quiet "$mounted"

print "app:     $app (version $version, build $build, $archs)"
print "dmg:     $dmg ($(stat -f%z "$dmg") bytes)"
print "sha256:  $(shasum -a 256 "$dmg" | awk '{print $1}')"

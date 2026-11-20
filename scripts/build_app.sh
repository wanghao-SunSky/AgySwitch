#!/bin/zsh
set -euo pipefail

root="${0:A:h:h}"
cd "$root"
mode="${1:---install}"
if [[ "$mode" != --install && "$mode" != --build-only ]] || (( $# > 1 )); then
    print -u2 "Usage: $0 [--install|--build-only]"
    exit 2
fi

swift build -c release --arch arm64 --product AgySwitch
bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"
stage="$(mktemp -d "$root/.build/package.XXXXXX")"
install_stage=""
destination="/Applications/AgySwitch.app"
cleanup() {
    if [[ -n "$install_stage" ]]; then
        if [[ -e "$install_stage/previous.app" && ! -e "$destination" ]]; then
            mv "$install_stage/previous.app" "$destination" || return
        fi
        rm -rf "$install_stage"
    fi
    rm -rf "$stage"
}
trap cleanup EXIT

bundle="$stage/AgySwitch.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin_dir/AgySwitch" "$bundle/Contents/MacOS/AgySwitch"
cp "$root/Resources/Info.plist" "$bundle/Contents/Info.plist"
swift "$root/scripts/generate_icon.swift" "$stage/AppIcon.iconset"
iconutil --convert icns "$stage/AppIcon.iconset" --output "$bundle/Contents/Resources/AppIcon.icns"
plutil -lint "$bundle/Contents/Info.plist"
codesign --force --deep --sign - "$bundle"
codesign --verify --deep --strict "$bundle"

if [[ "$mode" == --build-only ]]; then
    destination="$root/.build/AgySwitch.app"
fi
if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -L "$destination" ]] ||
       [[ "$(plutil -extract CFBundleIdentifier raw "$destination/Contents/Info.plist")" != com.agyacct.agyswitch ]]; then
        print -u2 "An unrelated item already exists at $destination."
        exit 1
    fi
fi
install_stage="$(mktemp -d "${destination:h}/.AgySwitch-install.XXXXXX")"
ditto "$bundle" "$install_stage/AgySwitch.app"
if [[ -e "$destination" ]]; then
    mv "$destination" "$install_stage/previous.app"
fi
mv "$install_stage/AgySwitch.app" "$destination"
print -r -- "$destination"

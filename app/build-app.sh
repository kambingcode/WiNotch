#!/bin/zsh
# Builds app/build/WiNotch.app, signed so macOS remembers its permissions.
# With "install", also replaces the copy in /Applications.
set -euo pipefail
cd "${0:A:h}"

swift build --package-path NotchLyricsCore -c release --product NotchLyricsApp

app="build/WiNotch.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "NotchLyricsCore/.build/release/NotchLyricsApp" "$app/Contents/MacOS/"
cp Info.plist "$app/Contents/"
cp Resources/*.wav "$app/Contents/Resources/"

# Icon: put a 1024x1024 image at Resources/AppIcon.png and it becomes AppIcon.icns.
if [[ -f Resources/AppIcon.png ]]; then
    iconset=$(mktemp -d)/AppIcon.iconset
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z $size $size Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
fi

identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
if [[ -z "$identity" ]]; then
    echo "No Apple Development certificate found" >&2
    exit 1
fi
codesign --force --sign "$identity" "$app"
echo "$PWD/$app"

if [[ "${1:-}" == "install" ]]; then
    rm -rf "/Applications/Notch Lyrics.app" "/Applications/WiNotch.app"
    ditto "$app" "/Applications/WiNotch.app"
    echo "/Applications/WiNotch.app"
fi

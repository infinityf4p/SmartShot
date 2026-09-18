#!/bin/bash
set -euo pipefail

# Builds in a disposable source copy; only the four packages survive in OUTPUT.
if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 VERSION BUILD OUTPUT [SOURCE]" >&2
    exit 1
fi
script_directory="$(cd -- "$(dirname -- "$0")" && pwd -P)"
version="$1"
build="$2"
mkdir -p "$3"
output="$(cd -- "$3" && pwd -P)"
source_directory="${4:-$script_directory/..}"
if [[ -n "$(ls -A "$output")" ]]; then
    echo "Output directory must be empty: $output" >&2
    exit 1
fi
scratch="$(mktemp -d "${TMPDIR:-/private/tmp}/SmartShotPreview.XXXXXX")"
app="$scratch/DerivedData/Build/Products/Release/SmartShot.app"
cleanup() {
    if [[ -d "$app" ]]; then
        /usr/bin/pluginkit -r "$app/Contents/PlugIns/SmartShot Safari Extension.appex" >/dev/null 2>&1 || true
        /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
            -u "$app" >/dev/null 2>&1 || true
    fi
    rm -rf -- "$scratch"
}
trap cleanup EXIT

python3 "$script_directory/release_artifacts.py" stage "$source_directory" \
    --destination "$scratch/source" --version "$version" --build "$build"
(
    cd "$scratch/source"
    xcodegen generate
)
xcodebuild -project "$scratch/source/SmartShot.xcodeproj" -scheme SmartShot \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$scratch/DerivedData" build \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES AD_HOC_CODE_SIGNING_ALLOWED=YES \
    ENABLE_HARDENED_RUNTIME=YES REGISTER_WITH_LAUNCH_SERVICES=NO \
    ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64'
python3 "$script_directory/release_artifacts.py" verify "$app" --version "$version" --build "$build"

ditto -c -k --sequesterRsrc --keepParent "$app" "$output/SmartShot-$version-universal.zip"
mkdir "$scratch/dmg"
ditto "$app" "$scratch/dmg/SmartShot.app"
ln -s /Applications "$scratch/dmg/Applications"
hdiutil create -volname "SmartShot $version" -srcfolder "$scratch/dmg" \
    -format UDZO "$output/SmartShot-$version-universal.dmg"
hdiutil verify "$output/SmartShot-$version-universal.dmg"

mkdir "$scratch/extension"
for item in manifest.json background.js content.js shared icons README.md; do
    ditto "$scratch/source/BrowserExtension/$item" "$scratch/extension/$item"
done
ditto -c -k "$scratch/extension" "$output/SmartShot-Web-Selector-$version.zip"
python3 "$script_directory/release_artifacts.py" checksums "$output" --version "$version"
echo "Verified preview packages: $output"

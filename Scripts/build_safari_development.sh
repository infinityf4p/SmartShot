#!/bin/bash

set -euo pipefail

readonly script_name="$(basename "$0")"
readonly script_directory="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
readonly repository_root="$(CDPATH= cd -- "$script_directory/.." && pwd -P)"
readonly project_path="$repository_root/SmartShot.xcodeproj"
readonly app_entitlements_source="$repository_root/Resources/App/SmartShot.entitlements"
readonly extension_entitlements_source="$repository_root/Resources/SafariExtension/SmartShotSafariExtension.entitlements"
readonly lsregister_path="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

derived_data=""
verify_only_app=""
scratch_directory=""
built_app_registration=""

usage() {
    /bin/cat <<EOF
Usage:
  $script_name [--derived-data PATH]
  $script_name --verify-only /path/to/SmartShot.app

Builds an isolated universal Release-configuration app with Xcode's
"Sign to Run Locally" identity, then adds get-task-allow to the containing
app and Safari extension. The result is development-only and is not installed
or registered with LaunchServices.

Options:
  --derived-data PATH  Use an empty, non-repository DerivedData directory.
                       The default is a fresh directory under TMPDIR.
  --verify-only APP    Verify an existing development app without rebuilding.
  -h, --help           Show this help.
EOF
}

fail() {
    echo "$script_name: $*" >&2
    exit 1
}

cleanup() {
    unregister_transient_build
    if [[ -n "$scratch_directory" && -d "$scratch_directory" ]]; then
        /bin/rm -R -- "$scratch_directory"
    fi
}

unregister_transient_build() {
    if [[ -z "$built_app_registration" ]]; then
        return
    fi

    local extension_path="$built_app_registration/Contents/PlugIns/SmartShot Safari Extension.appex"
    if [[ -d "$extension_path" ]]; then
        /usr/bin/pluginkit -r "$extension_path" >/dev/null 2>&1 || true
    fi
    if [[ -d "$built_app_registration" ]]; then
        "$lsregister_path" -u "$built_app_registration" >/dev/null 2>&1 || true
    fi
    built_app_registration=""
}

trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --derived-data)
            [[ $# -ge 2 ]] || fail "--derived-data requires a path"
            [[ -z "$verify_only_app" ]] || fail "--derived-data cannot be combined with --verify-only"
            derived_data="$2"
            shift 2
            ;;
        --verify-only)
            [[ $# -ge 2 ]] || fail "--verify-only requires an app path"
            [[ -z "$derived_data" ]] || fail "--verify-only cannot be combined with --derived-data"
            verify_only_app="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown argument: $1"
            ;;
    esac
done

for tool in /usr/bin/codesign /usr/bin/file /usr/bin/lipo /usr/bin/pluginkit /usr/bin/plutil /usr/bin/xcodebuild /usr/libexec/PlistBuddy "$lsregister_path"; do
    [[ -x "$tool" ]] || fail "required tool is unavailable: $tool"
done

[[ -d "$project_path" ]] || fail "missing project: $project_path"
[[ -f "$app_entitlements_source" ]] || fail "missing app entitlements: $app_entitlements_source"
[[ -f "$extension_entitlements_source" ]] || fail "missing extension entitlements: $extension_entitlements_source"

temporary_root="${TMPDIR:-/private/tmp}"
temporary_root="${temporary_root%/}"
[[ "$temporary_root" == /* ]] || fail "TMPDIR must be an absolute path"
[[ -d "$temporary_root" ]] || fail "TMPDIR does not exist: $temporary_root"
temporary_root="$(CDPATH= cd -- "$temporary_root" && pwd -P)"
case "$temporary_root" in
    /|/Applications|/Applications/*|"$repository_root"|"$repository_root"/*)
        fail "TMPDIR must be outside /Applications and the repository"
        ;;
esac
scratch_directory="$(/usr/bin/mktemp -d "$temporary_root/SmartShotSafariSign.XXXXXX")"

add_development_entitlement() {
    local source_path="$1"
    local destination_path="$2"

    /bin/cp "$source_path" "$destination_path"
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.get-task-allow' "$destination_path" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.get-task-allow bool true' "$destination_path"
    /usr/bin/plutil -convert xml1 "$destination_path"
}

extract_entitlements() {
    local code_path="$1"
    local destination_path="$2"

    /usr/bin/codesign --display --entitlements "$destination_path" --xml "$code_path" >/dev/null 2>&1
    [[ -s "$destination_path" ]] || fail "no entitlements found in $code_path"
}

assert_boolean_entitlement() {
    local entitlements_path="$1"
    local entitlement_name="$2"
    local code_label="$3"
    local value

    value="$(/usr/libexec/PlistBuddy -c "Print :$entitlement_name" "$entitlements_path" 2>/dev/null || true)"
    [[ "$value" == "true" ]] || fail "$code_label is missing $entitlement_name=true"
}

assert_adhoc_signature() {
    local code_path="$1"
    local signature_details

    signature_details="$(/usr/bin/codesign --display --verbose=4 "$code_path" 2>&1)"
    [[ "$signature_details" == *"Signature=adhoc"* ]] || fail "$code_path is not signed with Sign to Run Locally"
}

verify_development_app() {
    local app_path="$1"
    local extension_path="$app_path/Contents/PlugIns/SmartShot Safari Extension.appex"
    local app_executable="$app_path/Contents/MacOS/SmartShot"
    local extension_executable="$extension_path/Contents/MacOS/SmartShot Safari Extension"
    local native_host="$app_path/Contents/Helpers/SmartShotNativeHost"
    local cli="$app_path/Contents/Helpers/smartshot"
    local browser_manifest="$extension_path/Contents/Resources/manifest.json"
    local app_entitlements="$scratch_directory/app-extracted.plist"
    local extension_entitlements="$scratch_directory/extension-extracted.plist"
    local app_version
    local app_build
    local extension_version
    local extension_build
    local browser_version

    [[ -d "$app_path" ]] || fail "app does not exist: $app_path"
    [[ -d "$extension_path" ]] || fail "embedded Safari extension is missing"
    [[ -x "$app_executable" ]] || fail "app executable is missing"
    [[ -x "$extension_executable" ]] || fail "Safari extension executable is missing"
    [[ -x "$native_host" ]] || fail "Chromium native host is missing"
    [[ -x "$cli" ]] || fail "CLI helper is missing"
    [[ -f "$browser_manifest" ]] || fail "browser manifest is missing"

    /usr/bin/codesign --verify --strict --deep --verbose=2 "$app_path"
    assert_adhoc_signature "$app_path"
    assert_adhoc_signature "$extension_path"

    extract_entitlements "$app_path" "$app_entitlements"
    extract_entitlements "$extension_path" "$extension_entitlements"
    assert_boolean_entitlement "$app_entitlements" "com.apple.security.device.audio-input" "containing app"
    assert_boolean_entitlement "$app_entitlements" "com.apple.security.get-task-allow" "containing app"
    assert_boolean_entitlement "$extension_entitlements" "com.apple.security.app-sandbox" "Safari extension"
    assert_boolean_entitlement "$extension_entitlements" "com.apple.security.get-task-allow" "Safari extension"

    /usr/bin/lipo "$app_executable" -verify_arch arm64 x86_64
    /usr/bin/lipo "$extension_executable" -verify_arch arm64 x86_64
    /usr/bin/lipo "$native_host" -verify_arch arm64 x86_64
    /usr/bin/lipo "$cli" -verify_arch arm64 x86_64

    app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
    app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")"
    extension_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extension_path/Contents/Info.plist")"
    extension_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extension_path/Contents/Info.plist")"
    browser_version="$(/usr/bin/plutil -extract version raw -o - "$browser_manifest")"

    [[ "$app_version" == "$extension_version" ]] || fail "app and Safari extension versions differ"
    [[ "$app_build" == "$extension_build" ]] || fail "app and Safari extension build numbers differ"
    [[ "$app_version" == "$browser_version" ]] || fail "native and browser manifest versions differ"

    echo "Verified Safari development app: $app_path"
    echo "Version: $app_version ($app_build)"
}

if [[ -n "$verify_only_app" ]]; then
    verify_development_app "$(CDPATH= cd -- "$(dirname -- "$verify_only_app")" && pwd -P)/$(basename -- "$verify_only_app")"
    exit 0
fi

if [[ -z "$derived_data" ]]; then
    derived_data="$(/usr/bin/mktemp -d "$temporary_root/SmartShotSafariDev.XXXXXX")"
else
    [[ "$derived_data" == /* ]] || fail "--derived-data must be an absolute path"
    case "$derived_data" in
        /|/Applications|/Applications/*|"$repository_root"|"$repository_root"/*)
            fail "DerivedData must be outside /Applications and the repository"
            ;;
    esac
    /bin/mkdir -p "$derived_data"
    derived_data="$(CDPATH= cd -- "$derived_data" && pwd -P)"
fi

case "$derived_data" in
    /|/Applications|/Applications/*|"$repository_root"|"$repository_root"/*)
        fail "DerivedData must be outside /Applications and the repository"
        ;;
esac

if [[ -n "$(/usr/bin/find "$derived_data" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    fail "DerivedData directory must be empty: $derived_data"
fi

echo "Building isolated Safari development app in: $derived_data"

built_app_registration="$derived_data/Build/Products/Release/SmartShot.app"

/usr/bin/xcodebuild \
    -project "$project_path" \
    -scheme SmartShot \
    -configuration Release \
    -destination platform=macOS \
    -derivedDataPath "$derived_data" \
    build \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    AD_HOC_CODE_SIGNING_ALLOWED=YES \
    ENABLE_HARDENED_RUNTIME=YES \
    REGISTER_WITH_LAUNCH_SERVICES=NO \
    ONLY_ACTIVE_ARCH=NO \
    'ARCHS=arm64 x86_64'

app_path="$derived_data/Build/Products/Release/SmartShot.app"
extension_path="$app_path/Contents/PlugIns/SmartShot Safari Extension.appex"
app_development_entitlements="$scratch_directory/app-development.plist"
extension_development_entitlements="$scratch_directory/extension-development.plist"

[[ -d "$app_path" ]] || fail "xcodebuild did not produce $app_path"
[[ -d "$extension_path" ]] || fail "xcodebuild did not embed the Safari extension"

add_development_entitlement "$app_entitlements_source" "$app_development_entitlements"
add_development_entitlement "$extension_entitlements_source" "$extension_development_entitlements"

/usr/bin/codesign \
    --force \
    --sign - \
    --options runtime \
    --timestamp=none \
    --generate-entitlement-der \
    --entitlements "$extension_development_entitlements" \
    "$extension_path"

/usr/bin/codesign \
    --force \
    --sign - \
    --options runtime \
    --timestamp=none \
    --generate-entitlement-der \
    --entitlements "$app_development_entitlements" \
    "$app_path"

verify_development_app "$app_path"
unregister_transient_build

echo
echo "Development-only artifact: $app_path"
echo "It was not installed or registered. Launch this exact app once before Safari testing."
echo "Do not copy this get-task-allow build to /Applications or distribute it."

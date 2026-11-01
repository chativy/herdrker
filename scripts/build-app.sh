#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root_dir"

configuration="${HERDRKER_CONFIGURATION:-release}"
swift build -c "$configuration" "$@"

app_dir="$root_dir/build/Herdrker.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

rm -rf "$app_dir"
mkdir -p "$macos_dir" "$resources_dir"

cp ".build/$configuration/Herdrker" "$macos_dir/Herdrker"
cp "Resources/Info.plist" "$contents_dir/Info.plist"
cp "Resources/Herdr.icns" "$resources_dir/Herdr.icns"

signing_identity="${HERDRKER_SIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]]; then
    available_identities="$(
        security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/.*"\(.*\)".*/\1/p'
    )"
    account_name="$(id -F 2>/dev/null || true)"
    if [[ -n "$account_name" ]]; then
        signing_identity="$(
            print -r -- "$available_identities" \
                | grep -Fi "$account_name" \
                | grep -F "Apple Development:" \
                | head -n 1
        )"
    fi
    if [[ -z "$signing_identity" ]]; then
        signing_identity="$(
            print -r -- "$available_identities" \
                | grep -F "Apple Development:" \
                | head -n 1
        )"
    fi
    if [[ -z "$signing_identity" ]]; then
        signing_identity="$(
            print -r -- "$available_identities" \
                | grep -F "Developer ID Application:" \
                | head -n 1
        )"
    fi
fi

if [[ -z "$signing_identity" ]]; then
    echo "No valid Apple code-signing identity was found." >&2
    echo "Install a signing certificate or set HERDRKER_SIGN_IDENTITY." >&2
    exit 1
fi

codesign --force --deep --options runtime --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

if codesign -dvvv "$app_dir" 2>&1 | grep -q "^Signature=adhoc$"; then
    echo "Herdrker was unexpectedly signed ad hoc." >&2
    exit 1
fi

echo "Signed with $signing_identity"
echo "Built $app_dir"

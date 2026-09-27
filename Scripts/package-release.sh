#!/bin/bash
set -euo pipefail

ROOT="$(dirname "$(dirname "$0")")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP="$ROOT/DerivedData/Build/Products/Release/CannyGit.app"
OUTPUT="$ROOT/Artifacts"

if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    printf '%s\n' 'Notarization requires DEVELOPER_ID_APPLICATION and NOTARY_PROFILE.' >&2
    exit 1
fi

xcodebuild -project "$ROOT/CannyGit.xcodeproj" -scheme CannyGit \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$ROOT/DerivedData" -skipPackagePluginValidation build -quiet

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP"
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$OUTPUT"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ARCHIVE="$OUTPUT/CannyGit-$VERSION-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
fi
shasum -a 256 "$ARCHIVE"

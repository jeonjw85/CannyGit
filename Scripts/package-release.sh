#!/bin/bash
set -euo pipefail

ROOT="$(dirname "$(dirname "$0")")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DERIVED_DATA="${DERIVED_DATA_PATH:-$ROOT/DerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/CannyGit.app"
OUTPUT="${OUTPUT_DIR:-$ROOT/Artifacts}"
BUILD_SETTINGS=('ARCHS=arm64 x86_64' 'ONLY_ACTIVE_ARCH=NO')

if [[ -n "${RELEASE_VERSION:-}" ]]; then
    if [[ ! "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        printf '%s\n' 'RELEASE_VERSION must use MAJOR.MINOR.PATCH.' >&2
        exit 1
    fi
    BUILD_SETTINGS+=("MARKETING_VERSION=$RELEASE_VERSION")
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' 'BUILD_NUMBER must be a positive integer.' >&2
        exit 1
    fi
    BUILD_SETTINGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

if [[ -n "${NOTARY_PROFILE:-}" && -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    printf '%s\n' 'Notarization requires DEVELOPER_ID_APPLICATION and NOTARY_PROFILE.' >&2
    exit 1
fi

xcodebuild -project "$ROOT/CannyGit.xcodeproj" -scheme CannyGit \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" -skipPackagePluginValidation \
    "${BUILD_SETTINGS[@]}" build -quiet

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [[ -n "${RELEASE_VERSION:-}" && "$VERSION" != "$RELEASE_VERSION" ]]; then
    printf '%s\n' 'The built app version does not match RELEASE_VERSION.' >&2
    exit 1
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
    if [[ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]]; then
        printf '%s\n' 'The built app version does not match BUILD_NUMBER.' >&2
        exit 1
    fi
fi
for architecture in arm64 x86_64; do
    lipo "$APP/Contents/MacOS/CannyGit" -verify_arch "$architecture"
    minos=$(vtool -arch "$architecture" -show-build "$APP/Contents/MacOS/CannyGit" |
        awk '$1 == "minos" { print $2; exit }')
    if [[ "$minos" != "14.0" ]]; then
        printf '%s\n' "The $architecture slice targets macOS ${minos:-unknown}, expected 14.0." >&2
        exit 1
    fi
done

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP"
else
    # Seal the finished bundle after dependency resources have been copied.
    codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$OUTPUT"
ARCHIVE_NAME="CannyGit-$VERSION-macOS.zip"
ARCHIVE="$OUTPUT/$ARCHIVE_NAME"
IMAGE_NAME="CannyGit-$VERSION-macOS.dmg"
IMAGE="$OUTPUT/$IMAGE_NAME"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ARCHIVE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
fi
unzip -tq "$ARCHIVE"

# Package the final app, including its stapled ticket when notarization is enabled.
bash "$ROOT/Scripts/create-dmg.sh" "$APP" "$IMAGE"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
    codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$IMAGE"
    codesign --verify --strict "$IMAGE"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$IMAGE" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$IMAGE"
    xcrun stapler validate "$IMAGE"
fi

(
    cd "$OUTPUT"
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
    shasum -a 256 "$IMAGE_NAME" > "$IMAGE_NAME.sha256"
)
printf 'Created %s and %s.sha256\n' "$IMAGE" "$IMAGE"
printf 'Created %s and %s.sha256\n' "$ARCHIVE" "$ARCHIVE"

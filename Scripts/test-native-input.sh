#!/bin/bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$0")")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild -project "$ROOT/CannyGit.xcodeproj" -scheme CannyGit \
    -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$ROOT/DerivedData" -skipPackagePluginValidation build -quiet
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/cannygit-native.XXXXXX")
trap 'rm -rf "$TEMP"' EXIT
swiftc -parse-as-library -swift-version 6 "$ROOT/Scripts/native-ui-probe.swift" -o "$TEMP/NativeUIProbe"
"$TEMP/NativeUIProbe" "$ROOT/DerivedData/Build/Products/Debug/CannyGit.app"

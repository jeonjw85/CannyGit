#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf '%s\n' 'Usage: bash Scripts/create-dmg.sh <CannyGit.app> <output.dmg>' >&2
    exit 1
fi

APP="$1"
IMAGE="$2"
if [[ ! -d "$APP" || ! -f "$APP/Contents/Info.plist" ]]; then
    printf '%s\n' 'The source app bundle is missing.' >&2
    exit 1
fi

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/cannygit-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

ditto "$APP" "$STAGING/CannyGit.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$(dirname "$IMAGE")"
hdiutil create -volname CannyGit -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$IMAGE"
hdiutil verify "$IMAGE"

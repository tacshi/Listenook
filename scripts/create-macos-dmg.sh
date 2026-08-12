#!/usr/bin/env bash
set -euo pipefail

SOURCE_FOLDER="${1:?usage: create-macos-dmg.sh source-folder destination.dmg}"
DESTINATION="${2:?usage: create-macos-dmg.sh source-folder destination.dmg}"
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"

if [[ ! "$MACOS_MAJOR" =~ ^[0-9]+$ ]]; then
  echo "Could not determine the macOS version: $MACOS_VERSION" >&2
  exit 1
fi

if (( MACOS_MAJOR >= 14 )); then
  diskutil image create from \
    --volumeName MeowSTT \
    --format UDZO \
    "$SOURCE_FOLDER" \
    "$DESTINATION" \
    >/dev/null
else
  hdiutil create \
    -volname MeowSTT \
    -srcfolder "$SOURCE_FOLDER" \
    -ov \
    -format UDZO \
    "$DESTINATION" \
    >/dev/null
fi

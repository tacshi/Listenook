#!/usr/bin/env bash
# Builds a signed profile build, installs it on a connected device and
# launches it. Profile, not debug: since iOS 14 a debug Flutter app only starts
# with a debugger attached.
#
# Usage: scripts/run-ios.sh <device name or UDID> [--release]
# Devices: xcrun devicectl list devices
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/environment.sh"
source "$ROOT/scripts/flutter-sdk.sh"
DEVICE="${1:?usage: run-ios.sh <device name or UDID> [--release]}"
shift
MODE=profile
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) MODE=release; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
BUNDLE_ID="$(awk -F' = ' '/PRODUCT_BUNDLE_IDENTIFIER = / {gsub(/;/, "", $2); print $2; exit}' \
  "$ROOT/ios/Runner.xcodeproj/project.pbxproj")"

cd "$ROOT"
"$FLUTTER" build ios "--$MODE"
xcrun devicectl device install app --device "$DEVICE" "$ROOT/build/ios/iphoneos/Runner.app"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE_ID"

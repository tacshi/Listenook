#!/usr/bin/env bash
# Compiles the iOS app in debug mode without signing — a quick check that the
# Dart and native code build for iOS. To put the app on a device, use
# run-ios.sh instead.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/environment.sh"
source "$ROOT/scripts/flutter-sdk.sh"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS builds must run on macOS." >&2
  exit 1
fi
cd "$ROOT"
exec "$FLUTTER" build ios --debug --no-codesign "$@"

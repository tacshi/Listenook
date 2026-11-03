#!/usr/bin/env bash
# Builds a signed App Store ipa into build/ios/ipa. BUILD_NAME and
# BUILD_NUMBER override the pubspec version, as for the desktop builds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/environment.sh"
source "$ROOT/scripts/flutter-sdk.sh"
FLUTTER_VERSION_ARGS=()
if [[ -n "${BUILD_NAME:-}" ]]; then
  FLUTTER_VERSION_ARGS+=(--build-name "$BUILD_NAME")
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  FLUTTER_VERSION_ARGS+=(--build-number "$BUILD_NUMBER")
fi
cd "$ROOT"
exec "$FLUTTER" build ipa --release ${FLUTTER_VERSION_ARGS[@]+"${FLUTTER_VERSION_ARGS[@]}"} "$@"

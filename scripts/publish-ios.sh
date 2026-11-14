#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${1:-}" ]]; then export BUILD_NAME="$1"; fi
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
for NAME in NSH_APP_STORE_APP_ID NSH_APP_STORE_ISSUER_ID NSH_APP_STORE_KEY_ID NSH_APP_STORE_PRIVATE_KEY; do
  [[ -n "${!NAME:-}" ]] || { echo "Set $NAME (see the top of this script)." >&2; exit 1; }
done
export BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
bash "$ROOT/scripts/build-ios.sh" release
IPA="$OUT/$APP_NAME-$VERSION-ios-release.ipa"
echo "Uploading $(basename "$IPA") (build $BUILD_NUMBER) to App Store Connect"
(cd "$ROOT" && nsh publish ios "$IPA")
echo "Uploaded. It appears in TestFlight once Apple has processed it."

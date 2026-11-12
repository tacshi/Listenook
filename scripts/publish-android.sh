#!/usr/bin/env bash
# Builds the signed Android App Bundle and uploads it to Google Play's
# internal testing track, with `nsh publish android`.
#
#   scripts/publish-android.sh [VERSION] [--draft]
#
# Signing: LISTENOOK_ANDROID_KEYSTORE, LISTENOOK_ANDROID_KEY_ALIAS and
# NSH_KEYSTORE_PASSWORD (the upload key registered in Play App Signing).
# Upload: NSH_PLAY_CREDENTIALS (a service account's JSON key, kept outside
# the repository). `--draft` is needed until the app's first release has
# been made in the Play Console.
set -euo pipefail

DRAFT=()
VERSION_ARG=""
for ARG in "$@"; do
  case "$ARG" in
    --draft) DRAFT=(--draft) ;;
    -*) echo "Unknown argument: $ARG" >&2; exit 2 ;;
    *) VERSION_ARG="$ARG" ;;
  esac
done
if [[ -n "$VERSION_ARG" ]]; then export BUILD_NAME="$VERSION_ARG"; fi
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
[[ -n "${NSH_PLAY_CREDENTIALS:-}" ]] || { echo "Set NSH_PLAY_CREDENTIALS (see the top of this script)." >&2; exit 1; }
# Play takes each version code once.
export BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
bash "$ROOT/scripts/build-android.sh" release --aab
BUNDLE="$OUT/$APP_NAME-$VERSION-android-release.aab"
echo "Uploading $(basename "$BUNDLE") (version code $BUILD_NUMBER) to Google Play"
nsh publish android "$BUNDLE" --entry "$NSH_DIR" ${DRAFT[@]+"${DRAFT[@]}"}
echo "Uploaded to the internal testing track."

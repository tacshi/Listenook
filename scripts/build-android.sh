#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
MODE="${1:?usage: build-android.sh debug|release [--aab]}"
shift
FORMAT=apk
while [[ $# -gt 0 ]]; do
  case "$1" in
    --aab) FORMAT=aab; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
start_log "android-$MODE"
PACKAGE="$OUT/nsh/android-$MODE"
ARGS=(--format "$FORMAT" --abi "${LISTENOOK_ANDROID_ABIS:-arm64-v8a}")
if [[ "$MODE" == "release" ]]; then
  KEYSTORE="${LISTENOOK_ANDROID_KEYSTORE:?set LISTENOOK_ANDROID_KEYSTORE to the release keystore}"
  ALIAS="${LISTENOOK_ANDROID_KEY_ALIAS:?set LISTENOOK_ANDROID_KEY_ALIAS}"
  [[ -f "$KEYSTORE" ]] || { echo "Keystore not found: $KEYSTORE" >&2; exit 1; }
  [[ -n "${NSH_KEYSTORE_PASSWORD:-}" ]] || { echo "Set NSH_KEYSTORE_PASSWORD." >&2; exit 1; }
  ARGS+=(--keystore "$KEYSTORE" --key-alias "$ALIAS")
elif [[ "$MODE" != "debug" ]]; then
  echo "usage: build-android.sh debug|release [--aab]" >&2
  exit 2
fi
for ABI in ${LISTENOOK_ANDROID_ABIS:-arm64-v8a}; do
  case "${ABI//,/}" in
    arm64-v8a) TRIPLE=aarch64-linux-android ;;
    armeabi-v7a) TRIPLE=armv7-linux-androideabi ;;
    x86_64) TRIPLE=x86_64-linux-android ;;
    *) continue ;;
  esac
  rustup target list --installed | grep -qx "$TRIPLE" || {
    echo "Install the Rust target first: rustup target add $TRIPLE" >&2
    exit 1
  }
done
echo "Building $APP_NAME $VERSION Android $MODE ($FORMAT)"
nsh_package android "$PACKAGE" "${ARGS[@]}"
ARTIFACT="$OUT/$APP_NAME-$VERSION-android-$MODE.$FORMAT"
cp "$PACKAGE/$APP_NAME.$FORMAT" "$ARTIFACT"
echo "Built $ARTIFACT"

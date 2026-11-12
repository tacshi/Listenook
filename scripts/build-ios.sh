#!/usr/bin/env bash
# Builds the iOS and iPadOS app with `nsh package`.
#
#   build-ios.sh debug     an unsigned .app: a check that everything builds
#   build-ios.sh release   a signed .ipa in build/
#
# A release needs LISTENOOK_IOS_SIGN_IDENTITY (such as "Apple Distribution:
# Example Inc (ABCDE12345)") and LISTENOOK_IOS_PROFILE (a .mobileprovision).
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
MODE="${1:?usage: build-ios.sh debug|release}"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "iOS builds must run on macOS." >&2
  exit 1
fi
start_log "ios-$MODE"
PACKAGE="$OUT/nsh/ios-$MODE"

if [[ "$MODE" == "debug" ]]; then
  echo "Building $APP_NAME $VERSION iOS (unsigned)"
  nsh_package ios "$PACKAGE"
  echo "Built $PACKAGE/$APP_NAME.app"
  exit 0
fi

IDENTITY="${LISTENOOK_IOS_SIGN_IDENTITY:?set LISTENOOK_IOS_SIGN_IDENTITY to a code signing identity}"
PROFILE="${LISTENOOK_IOS_PROFILE:?set LISTENOOK_IOS_PROFILE to a provisioning profile}"
[[ -f "$PROFILE" ]] || { echo "Provisioning profile not found: $PROFILE" >&2; exit 1; }
echo "Building $APP_NAME $VERSION iOS, signed as: $IDENTITY"
nsh_package ios "$PACKAGE" --sign "$IDENTITY" --profile "$PROFILE"
IPA="$OUT/$APP_NAME-$VERSION-ios-release.ipa"
cp "$PACKAGE/$APP_NAME.ipa" "$IPA"
echo "Built $IPA"

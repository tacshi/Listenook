#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/macos-signing.sh"
source "$ROOT/scripts/flutter-sdk.sh"
MODE="${1:?internal usage: build-macos.sh debug|release [--arch ...]}"
shift
ARCH="arm64"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:?--arch requires arm64, x64, or all}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ "$ARCH" != "arm64" && "$ARCH" != "x64" && "$ARCH" != "all" ]]; then
  echo "--arch must be arm64, x64, or all" >&2
  exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS builds must run on macOS." >&2
  exit 1
fi

VERSION="${BUILD_NAME:-$(awk '/^version:/{print $2}' "$ROOT/pubspec.yaml" | cut -d+ -f1)}"
FLUTTER_VERSION_ARGS=()
if [[ -n "${BUILD_NAME:-}" ]]; then
  FLUTTER_VERSION_ARGS+=(--build-name "$BUILD_NAME")
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  FLUTTER_VERSION_ARGS+=(--build-number "$BUILD_NUMBER")
fi
ARCHES=("$ARCH")
if [[ "$ARCH" == "all" ]]; then ARCHES=(arm64 x64); fi
NOTARY_PROFILE="${LISTENOOK_NOTARY_PROFILE:-Listenook}"

if [[ "$MODE" == "release" ]]; then
  RELEASE_SIGN_IDENTITY="${LISTENOOK_MAC_SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:--}}"
  if [[ "$RELEASE_SIGN_IDENTITY" != "-" ]]; then
    if [[ -z "${LISTENOOK_NOTARY_PROFILE:-}" ]] &&
       ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 &&
       xcrun notarytool history --keychain-profile MeowSTT >/dev/null 2>&1; then
      NOTARY_PROFILE=MeowSTT
    fi
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
      echo "No working notarytool keychain profile named '$NOTARY_PROFILE'." >&2
      echo "Create it with 'xcrun notarytool store-credentials $NOTARY_PROFILE ...'" >&2
      exit 1
    fi
    echo "Using notarytool keychain profile: $NOTARY_PROFILE"
  fi
fi

for CURRENT_ARCH in "${ARCHES[@]}"; do
  EXPECTED_MACHO="$CURRENT_ARCH"
  if [[ "$CURRENT_ARCH" == "x64" ]]; then EXPECTED_MACHO="x86_64"; fi
  OUT="$ROOT/dist"
  BASE="Listenook-$VERSION-macos-$CURRENT_ARCH-$MODE"
  if [[ "$MODE" == "debug" ]]; then
    DEBUG_APP="$OUT/$BASE.app"
    DEBUG_EXECUTABLE="$DEBUG_APP/Contents/MacOS/Listenook"
    if bash "$ROOT/scripts/is-macos-app-running.sh" "$DEBUG_EXECUTABLE"; then
      echo "Closing running debug app: $DEBUG_APP"
      bash "$ROOT/scripts/stop-macos-app.sh" "$DEBUG_EXECUTABLE"
    fi
  fi
  echo "Building Listenook $VERSION macOS $CURRENT_ARCH $MODE"
  cd "$ROOT"
  if [[ "$MODE" == "debug" ]]; then
    "$FLUTTER" build macos --debug --config-only ${FLUTTER_VERSION_ARGS[@]+"${FLUTTER_VERSION_ARGS[@]}"}
    xcodebuild \
      -workspace macos/Runner.xcworkspace \
      -scheme Runner \
      -configuration Debug \
      -derivedDataPath build/macos \
      -destination "platform=macOS,arch=$EXPECTED_MACHO" \
      "ARCHS=$EXPECTED_MACHO" \
      ONLY_ACTIVE_ARCH=YES \
      CODE_SIGNING_ALLOWED=NO \
      COMPILER_INDEX_STORE_ENABLE=NO \
      -quiet
  else
    EXCLUDED="x86_64"
    if [[ "$CURRENT_ARCH" == "x64" ]]; then EXCLUDED="arm64"; fi
    FLUTTER_XCODE_EXCLUDED_ARCHS="$EXCLUDED" "$FLUTTER" build macos --release --config-only ${FLUTTER_VERSION_ARGS[@]+"${FLUTTER_VERSION_ARGS[@]}"}
    xcodebuild \
      -workspace macos/Runner.xcworkspace \
      -scheme Runner \
      -configuration Release \
      -derivedDataPath build/macos \
      -destination "platform=macOS,arch=$EXPECTED_MACHO" \
      "ARCHS=$EXPECTED_MACHO" \
      ONLY_ACTIVE_ARCH=YES \
      CODE_SIGNING_ALLOWED=NO \
      COMPILER_INDEX_STORE_ENABLE=NO \
      -quiet
  fi

  CONFIG="Debug"
  if [[ "$MODE" == "release" ]]; then CONFIG="Release"; fi
  APP="$ROOT/build/macos/Build/Products/$CONFIG/Listenook.app"
  [[ -d "$APP" ]] || { echo "Missing build product: $APP" >&2; exit 1; }
  APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/Listenook")"
  [[ " $APP_ARCHS " == *" $EXPECTED_MACHO "* ]] || {
    echo "Expected $EXPECTED_MACHO app, found: $APP_ARCHS" >&2; exit 1;
  }

  if [[ "$CURRENT_ARCH" == "arm64" ]]; then
    mkdir -p "$APP/Contents/Helpers"
    bash "$ROOT/scripts/build-speech-worker.sh" \
      "$APP/Contents/Helpers/ListenookSpeechWorker"
    [[ -s "$APP/Contents/Helpers/mlx.metallib" ]] || {
      echo "Missing packaged MLX Metal library." >&2
      exit 1
    }
  else
    rm -f "$APP/Contents/Helpers/ListenookSpeechWorker"
    rm -f "$APP/Contents/Helpers/mlx.metallib"
  fi

  [[ -x /usr/bin/afconvert ]] || { echo "Missing macOS afconvert." >&2; exit 1; }
  rm -rf "$APP/Contents/Resources/ffmpeg" "$APP/Contents/Resources/flac"
  rm -rf "$APP/Contents/Resources/third_party"
  mkdir -p "$APP/Contents/Resources/third_party"
  cp "$ROOT/assets/third_party/"* "$APP/Contents/Resources/third_party/"
  bash "$ROOT/scripts/strip-macos-download-metadata.sh" "$APP"
  if [[ "$MODE" == "debug" ]]; then
    SIGN_IDENTITY="$(resolve_listenook_debug_sign_identity "$ROOT")"
    if [[ "$SIGN_IDENTITY" == "-" ]]; then
      echo "Warning: no usable release signing identity was found; using ad-hoc signing." >&2
    else
      echo "Using release signing identity for debug: $SIGN_IDENTITY"
    fi
  else
    SIGN_IDENTITY="${LISTENOOK_MAC_SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:--}}"
  fi
  ENTITLEMENTS="$ROOT/macos/Runner/DebugProfile.entitlements"
  if [[ "$MODE" == "release" ]]; then ENTITLEMENTS="$ROOT/macos/Runner/Release.entitlements"; fi
  if ! listenook_sign_app_bundle "$APP" "$SIGN_IDENTITY" "$ENTITLEMENTS" "$MODE"; then
    if [[ "$MODE" == "debug" && "$SIGN_IDENTITY" != "-" ]]; then
      echo "Warning: release-identity signing failed; retrying the debug app ad-hoc." >&2
      SIGN_IDENTITY="-"
      listenook_sign_app_bundle "$APP" "$SIGN_IDENTITY" "$ENTITLEMENTS" "$MODE"
    else
      exit 1
    fi
  fi

  mkdir -p "$OUT"
  if [[ "$MODE" == "debug" ]]; then
    DEBUG_STAGE="$OUT/.$BASE.app.staging"
    rm -f "$OUT/$BASE.app.zip"
    rm -rf "$DEBUG_STAGE"
    ditto "$APP" "$DEBUG_STAGE"
    rm -rf "$DEBUG_APP"
    mv "$DEBUG_STAGE" "$DEBUG_APP"
  else
    rm -f "$OUT/$BASE.app.zip"
    STAGE="$(mktemp -d)"
    ditto "$APP" "$STAGE/Listenook.app"
    ln -s /Applications "$STAGE/Applications"
    DMG="$OUT/$BASE.dmg"
    rm -f "$DMG"
    bash "$ROOT/scripts/create-macos-dmg.sh" "$STAGE" "$DMG"
    rm -rf "$STAGE"

    if [[ "$SIGN_IDENTITY" != "-" ]]; then
      DMG_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp)
      codesign "${DMG_SIGN_ARGS[@]}" "$DMG"
      codesign --verify --strict --verbose=2 "$DMG"

      NOTARY_OUTPUT="$(xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json)"
      echo "$NOTARY_OUTPUT"
      if ! grep -q '"status"[[:space:]]*:[[:space:]]*"Accepted"' <<<"$NOTARY_OUTPUT"; then
        SUBMISSION_ID="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
          <<<"$NOTARY_OUTPUT" | head -n 1)"
        if [[ -n "$SUBMISSION_ID" ]]; then
          xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        fi
        echo "Apple did not accept the notarization submission for $DMG." >&2
        exit 1
      fi

      xcrun stapler staple "$APP"
      xcrun stapler staple "$DMG"
      xcrun stapler validate "$APP"
      xcrun stapler validate "$DMG"
      spctl --assess --type execute --verbose=4 "$APP"
      spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
    else
      echo "Warning: ad hoc-signed release artifacts will not pass Gatekeeper." >&2
    fi

    APP_ZIP="$OUT/$BASE.zip"
    rm -f "$APP_ZIP"
    ditto -c -k --keepParent "$APP" "$APP_ZIP"
  fi

  echo "Artifacts: $OUT"
done

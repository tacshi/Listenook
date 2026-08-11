#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

VERSION="$(awk '/^version:/{print $2}' "$ROOT/pubspec.yaml" | cut -d+ -f1)"
ARCHES=("$ARCH")
if [[ "$ARCH" == "all" ]]; then ARCHES=(arm64 x64); fi

for CURRENT_ARCH in "${ARCHES[@]}"; do
  EXPECTED_MACHO="$CURRENT_ARCH"
  if [[ "$CURRENT_ARCH" == "x64" ]]; then EXPECTED_MACHO="x86_64"; fi
  OUT="$ROOT/dist"
  BASE="MeowSTT-$VERSION-macos-$CURRENT_ARCH-$MODE"
  if [[ "$MODE" == "debug" ]]; then
    DEBUG_APP="$OUT/$BASE.app"
    DEBUG_EXECUTABLE="$DEBUG_APP/Contents/MacOS/MeowSTT"
    if bash "$ROOT/scripts/is-macos-app-running.sh" "$DEBUG_EXECUTABLE"; then
      echo "Refusing to replace the running debug app: $DEBUG_APP" >&2
      echo "Quit MeowSTT, then run this build again." >&2
      exit 1
    fi
  fi
  echo "Building MeowSTT $VERSION macOS $CURRENT_ARCH $MODE"
  cd "$ROOT"
  if [[ "$MODE" == "debug" ]]; then
    flutter build macos --debug --config-only
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
    FLUTTER_XCODE_EXCLUDED_ARCHS="$EXCLUDED" flutter build macos --release --config-only
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
  APP="$ROOT/build/macos/Build/Products/$CONFIG/MeowSTT.app"
  [[ -d "$APP" ]] || { echo "Missing build product: $APP" >&2; exit 1; }
  APP_ARCHS="$(lipo -archs "$APP/Contents/MacOS/MeowSTT")"
  [[ " $APP_ARCHS " == *" $EXPECTED_MACHO "* ]] || {
    echo "Expected $EXPECTED_MACHO app, found: $APP_ARCHS" >&2; exit 1;
  }

  HELPER_DIR="$($ROOT/scripts/fetch-ffmpeg.sh macos "$CURRENT_ARCH")"
  HELPER_DEST="$APP/Contents/Resources/ffmpeg"
  mkdir -p "$HELPER_DEST" "$APP/Contents/Resources/third_party"
  cp "$HELPER_DIR/ffmpeg" "$HELPER_DEST/ffmpeg"
  cp "$HELPER_DIR/ffprobe" "$HELPER_DEST/ffprobe"
  cp "$ROOT/assets/third_party/"* "$APP/Contents/Resources/third_party/"
  cp "$ROOT/packaging/ffmpeg/manifest.json" "$APP/Contents/Resources/third_party/ffmpeg-manifest.json"
  chmod +x "$HELPER_DEST/ffmpeg" "$HELPER_DEST/ffprobe"
  bash "$ROOT/scripts/strip-macos-download-metadata.sh" "$APP"
  SIGN_IDENTITY="${MEOWSTT_MAC_DEBUG_SIGN_IDENTITY:--}"
  if [[ "$MODE" == "release" ]]; then
    SIGN_IDENTITY="${MEOWSTT_MAC_SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:--}}"
  fi
  HELPER_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" != "-" ]]; then HELPER_SIGN_ARGS+=(--options runtime --timestamp); fi
  for TOOL in ffmpeg ffprobe; do
    TOOL_ARCHS="$(lipo -archs "$HELPER_DEST/$TOOL")"
    [[ " $TOOL_ARCHS " == *" $EXPECTED_MACHO "* ]] || {
      echo "Expected $EXPECTED_MACHO $TOOL, found: $TOOL_ARCHS" >&2; exit 1;
    }
    codesign "${HELPER_SIGN_ARGS[@]}" "$HELPER_DEST/$TOOL"
  done

  ENTITLEMENTS="$ROOT/macos/Runner/DebugProfile.entitlements"
  if [[ "$MODE" == "release" ]]; then ENTITLEMENTS="$ROOT/macos/Runner/Release.entitlements"; fi
  COMPONENT_SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
  if [[ "$SIGN_IDENTITY" != "-" ]]; then
    COMPONENT_SIGN_ARGS+=(--options runtime --timestamp)
  fi
  while IFS= read -r -d '' COMPONENT; do
    codesign "${COMPONENT_SIGN_ARGS[@]}" "$COMPONENT"
  done < <(
    find "$APP/Contents/Frameworks" "$APP/Contents/MacOS" -depth \
      \( -type d -name '*.framework' -o -type d -name '*.appex' \
      -o -type d -name '*.xpc' -o -type f -name '*.dylib' \) -print0
  )
  SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS")
  if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--options runtime --timestamp); fi
  codesign "${SIGN_ARGS[@]}" "$APP"
  codesign --verify --deep --strict "$APP"

  mkdir -p "$OUT"
  if [[ "$MODE" == "debug" ]]; then
    DEBUG_STAGE="$OUT/.$BASE.app.staging"
    rm -f "$OUT/$BASE.app.zip"
    rm -rf "$DEBUG_STAGE"
    ditto "$APP" "$DEBUG_STAGE"
    rm -rf "$DEBUG_APP"
    mv "$DEBUG_STAGE" "$DEBUG_APP"
  else
    ZIP="$OUT/$BASE.app.zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/MeowSTT.app"
    ln -s /Applications "$STAGE/Applications"
    DMG="$OUT/$BASE.dmg"
    rm -f "$DMG"
    hdiutil create -volname MeowSTT -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    if [[ -n "${MEOWSTT_NOTARY_PROFILE:-}" ]]; then
      if [[ "$SIGN_IDENTITY" == "-" ]]; then
        echo "Notarization requires DEVELOPER_ID_APPLICATION or MEOWSTT_MAC_SIGN_IDENTITY." >&2
        exit 1
      fi
      xcrun notarytool submit "$DMG" --keychain-profile "$MEOWSTT_NOTARY_PROFILE" --wait
      xcrun stapler staple "$DMG"
    fi
  fi

  CHECKSUMS="$OUT/$BASE.sha256"
  rm -f "$CHECKSUMS"
  if [[ "$MODE" == "debug" ]]; then
    (
      cd "$OUT"
      find "$BASE.app" -type f -exec shasum -a 256 {} + \
        | LC_ALL=C sort \
        > "$BASE.sha256"
    )
  else
    (cd "$OUT" && shasum -a 256 "$BASE"* > "$BASE.sha256")
  fi
  echo "Artifacts: $OUT"
done

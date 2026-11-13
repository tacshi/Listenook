#!/usr/bin/env bash
# Builds the macOS app: `nsh package`, then the speech helper, the
# localized names and notices, and signing. A release also gets the disk
# image, notarization and the archive the in-app updater downloads.
#
#   build-macos.sh debug   [--arch arm64|x64]   build/Listenook-<arch>-debug.app
#   build-macos.sh release [--arch arm64|x64] [--provenance]
#
# Signing: LISTENOOK_MAC_SIGN_IDENTITY (or DEVELOPER_ID_APPLICATION); a
# release is notarized with the notarytool keychain profile named by
# LISTENOOK_NOTARY_PROFILE (default: Listenook). Without an identity the
# app is signed ad hoc. LISTENOOK_SKIP_HELPER=1 leaves the speech helper out.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
MODE="${1:?usage: build-macos.sh debug|release [--arch arm64|x64] [--provenance]}"
shift
[[ "$MODE" == "debug" || "$MODE" == "release" ]] || { echo "Mode must be debug or release." >&2; exit 2; }
[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS builds must run on macOS." >&2; exit 1; }
ARCH="$(uname -m)"
if [[ "$ARCH" == "x86_64" ]]; then ARCH="x64"; fi
PROVENANCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:?--arch requires arm64 or x64}"; shift 2 ;;
    # Records the commit beside the artifacts, for a build that is
    # published from another machine.
    --provenance) PROVENANCE=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
# What the processor is called in a Mach-O file and in the updater's archive.
case "$ARCH" in
  arm64) MACHO="arm64"; UPDATER_ARCH="aarch64" ;;
  x64) MACHO="x86_64"; UPDATER_ARCH="x86_64" ;;
  *) echo "--arch must be arm64 or x64" >&2; exit 2 ;;
esac
# MOSS runs in the Swift helper, on Apple silicon only.
WITH_HELPER=false
if [[ "$ARCH" == "arm64" && -z "${LISTENOOK_SKIP_HELPER:-}" ]]; then WITH_HELPER=true; fi
NOTARY_PROFILE="${LISTENOOK_NOTARY_PROFILE:-Listenook}"
start_log "macos-$MODE"

# The Developer ID to sign with, or "-" for an ad hoc signature. A debug
# build signed like the installed app reads the same keychain items
# without asking.
sign_identity() {
  local chosen="${LISTENOOK_MAC_SIGN_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
  if [[ -n "$chosen" || "$MODE" == "release" ]]; then
    printf '%s\n' "${chosen:--}"
    return
  fi
  local identities
  identities="$(security find-identity -v -p codesigning 2>/dev/null |
    sed -n 's/^[^"]*"\(Developer ID Application:[^"]*\)".*/\1/p')"
  if [[ -n "$identities" && "$(wc -l <<<"$identities" | tr -d ' ')" == 1 ]]; then
    printf '%s\n' "$identities"
  else
    printf '%s\n' '-'
  fi
}

# sign_app APP IDENTITY: inner code first, then the bundle.
sign_app() {
  local app="$1" identity="$2" component
  local args=(--force --sign "$identity")
  if [[ "$identity" != "-" ]]; then
    args+=(--options runtime)
    if [[ "$MODE" == "release" ]]; then args+=(--timestamp); fi
  fi
  if [[ -d "$app/Contents/Helpers" ]]; then
    while IFS= read -r -d '' component; do
      codesign "${args[@]}" "$component" || return 1
    done < <(find "$app/Contents/Helpers" -type f -print0)
  fi
  codesign "${args[@]}" "$app" || return 1
  codesign --verify --deep --strict "$app"
}

# The processes running an executable.
pids_of() {
  ps -axww -o pid= -o command= | awk -v exe="$1" '{
    pid = $1; $1 = ""; sub(/^ +/, "")
    if ($0 == exe || index($0, exe " ") == 1) print pid
  }'
}

SIGN_IDENTITY="$(sign_identity)"
if [[ "$MODE" == "release" && "$SIGN_IDENTITY" != "-" ]]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
    echo "No working notarytool keychain profile named '$NOTARY_PROFILE'." >&2
    echo "Create it with 'xcrun notarytool store-credentials $NOTARY_PROFILE ...'" >&2
    exit 1
  }
fi

echo "Building $APP_NAME $VERSION macOS $ARCH $MODE"
PACKAGE="$OUT/nsh/macos-$ARCH"
# nsh builds either processor from any Mac (the Rust target must be installed).
nsh_package macos "$PACKAGE" --arch "$MACHO"
APP="$PACKAGE/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Missing build product: $APP" >&2; exit 1; }
[[ " $(lipo -archs "$APP/Contents/MacOS/$APP_NAME") " == *" $MACHO "* ]] || {
  echo "The app was not built for $MACHO." >&2; exit 1;
}

# The app's name in each language (聆页 in Chinese).
cp -R "$ROOT/packaging/macos/"*.lproj "$APP/Contents/Resources/"

if [[ "$WITH_HELPER" == true ]]; then
  HELPER="$APP/Contents/Helpers/ListenookSpeechWorker"
  mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/third_party"
  quiet bash "$ROOT/scripts/build-speech-worker.sh" "$HELPER"
  cp "$ROOT/packaging/notices/"* "$APP/Contents/Resources/third_party/"
  # MLX looks for its Metal library beside the worker. Signed there, a file
  # that is not a program keeps its signature in extended attributes, which
  # the in-app updater does not unpack: the updated app then fails its
  # signature check. Among the resources the bundle's own signature covers
  # it, and a link beside the worker leads to it.
  mv "$APP/Contents/Helpers/mlx.metallib" "$APP/Contents/Resources/mlx.metallib"
  ln -s ../Resources/mlx.metallib "$APP/Contents/Helpers/mlx.metallib"
fi

# Files that were downloaded carry marks that fail notarization.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
xattr -dr com.apple.provenance "$APP" 2>/dev/null || true
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Warning: no signing identity; signing ad hoc. The app will not pass Gatekeeper on other Macs." >&2
else
  echo "Signing as: $SIGN_IDENTITY"
fi
if ! quiet sign_app "$APP" "$SIGN_IDENTITY"; then
  [[ "$MODE" == "debug" && "$SIGN_IDENTITY" != "-" ]] || exit 1
  echo "Warning: signing with $SIGN_IDENTITY failed; signing the debug app ad hoc." >&2
  SIGN_IDENTITY="-"
  quiet sign_app "$APP" "$SIGN_IDENTITY"
fi

if [[ "$MODE" == "debug" ]]; then
  DEBUG_APP="$OUT/$APP_NAME-$ARCH-debug.app"
  # A running copy keeps its files open: close it before replacing them.
  RUNNING="$(pids_of "$DEBUG_APP/Contents/MacOS/$APP_NAME")"
  if [[ -n "$RUNNING" ]]; then
    echo "Closing the running debug app"
    kill -TERM $RUNNING 2>/dev/null || true
    for _ in {1..50}; do
      [[ -n "$(pids_of "$DEBUG_APP/Contents/MacOS/$APP_NAME")" ]] || break
      sleep 0.1
    done
    RUNNING="$(pids_of "$DEBUG_APP/Contents/MacOS/$APP_NAME")"
    [[ -z "$RUNNING" ]] || kill -KILL $RUNNING 2>/dev/null || true
  fi
  rm -rf "$DEBUG_APP"
  ditto "$APP" "$DEBUG_APP"
  echo "Built $DEBUG_APP"
  exit 0
fi

STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/$APP_NAME-$VERSION-macos-$ARCH-release.dmg"
rm -f "$DMG"
quiet diskutil image create from --volumeName "$APP_NAME" --format UDZO "$STAGE" "$DMG"
rm -rf "$STAGE"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  quiet codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
  echo "Notarizing $(basename "$DMG")"
  NOTARY_OUTPUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json 2>>"$LOG")"
  echo "$NOTARY_OUTPUT" >>"$LOG"
  if ! grep -q '"status"[[:space:]]*:[[:space:]]*"Accepted"' <<<"$NOTARY_OUTPUT"; then
    SUBMISSION_ID="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$NOTARY_OUTPUT" | head -n 1)"
    [[ -z "$SUBMISSION_ID" ]] ||
      xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    echo "$NOTARY_OUTPUT" >&2
    echo "Apple did not accept the notarization submission for $DMG." >&2
    exit 1
  fi
  quiet xcrun stapler staple "$APP"
  quiet xcrun stapler staple "$DMG"
  quiet spctl --assess --type execute --verbose=4 "$APP"
  quiet spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
else
  echo "Warning: ad hoc-signed release artifacts will not pass Gatekeeper." >&2
fi

# What the in-app updater downloads: the signed (and stapled) app, under
# the name `nsh update-manifest` reads the platform from.
UPDATE_ARCHIVE="$OUT/$APP_NAME-$VERSION-macos-$UPDATER_ARCH.tar.gz"
rm -f "$UPDATE_ARCHIVE"
# The updater unpacks the files alone, so the archive holds no more, and the
# app must pass the updater's check unpacked that way.
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$UPDATE_ARCHIVE" -C "$PACKAGE" "$APP_NAME.app"
UNPACKED="$(mktemp -d)"
tar --no-xattrs --no-mac-metadata -xzf "$UPDATE_ARCHIVE" -C "$UNPACKED"
if ! quiet codesign --verify --deep --strict "$UNPACKED/$APP_NAME.app"; then
  rm -rf "$UNPACKED"
  echo "The app in $UPDATE_ARCHIVE loses its signature when unpacked without extended attributes:" >&2
  echo "the in-app updater would refuse it. Some signed file outside Contents/MacOS is not a program." >&2
  exit 1
fi
rm -rf "$UNPACKED"
if [[ "$PROVENANCE" == true ]]; then
  DIRTY=false
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || DIRTY=true
  printf '{"version": "%s", "build": %s, "commit": "%s", "architecture": "%s", "dirty": %s}\n' \
    "$VERSION" "${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}" \
    "$(git -C "$ROOT" rev-parse HEAD)" "$ARCH" "$DIRTY" > "$DMG.build.json"
fi
echo "Built $DMG"
echo "Built $UPDATE_ARCHIVE"

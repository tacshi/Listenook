# Sourced by build scripts: sets FLUTTER to the Flutter SDK pinned in .fvmrc.
#
# Desktop builds need the master-channel SDK: the player and main windows are
# created through Flutter's multi-window API (lib/core/windowing/), which does
# not exist on stable, so a bare `flutter` from PATH fails to compile. Uses the
# project's `.fvm/flutter_sdk` link, installing the pinned version through FVM
# when it is missing.
#
# Usage (with ROOT set to the repo root):
#   source "$ROOT/scripts/flutter-sdk.sh"
#   "$FLUTTER" build macos --debug

listenook_resolve_flutter() {
  local app_dir="$1"
  local sdk_link="$app_dir/.fvm/flutter_sdk"

  if [[ ! -x "$sdk_link/bin/flutter" ]]; then
    if ! command -v fvm >/dev/null 2>&1; then
      echo "error: the pinned Flutter SDK (.fvmrc) is not installed and fvm is not in PATH" >&2
      echo "       install fvm (brew install fvm), then run: fvm install" >&2
      return 1
    fi
    echo "==> installing the Flutter SDK pinned in .fvmrc" >&2
    (cd "$app_dir" && fvm install --setup && fvm use --skip-pub-get --force) >&2 || return 1
  fi

  if [[ ! -x "$sdk_link/bin/flutter" ]]; then
    echo "error: $sdk_link/bin/flutter not found after fvm install" >&2
    return 1
  fi
  FLUTTER="$sdk_link/bin/flutter"
}

listenook_resolve_flutter "$ROOT" || exit 1

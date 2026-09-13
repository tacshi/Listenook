#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: verify-macos-app.sh /path/to/Listenook.app}"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS launch verification must run on macOS." >&2
  exit 2
fi
if [[ ! -d "$APP" ]]; then
  echo "App bundle does not exist: $APP" >&2
  exit 2
fi

APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
  echo "App executable is missing or not executable: $EXECUTABLE" >&2
  exit 1
fi

APP_ARCHS="$(lipo -archs "$EXECUTABLE")"
SPEECH_WORKER="$APP/Contents/Helpers/ListenookSpeechWorker"
MLX_METALLIB="$APP/Contents/Helpers/mlx.metallib"
if [[ " $APP_ARCHS " == *" arm64 "* ]]; then
  if [[ ! -x "$SPEECH_WORKER" ]]; then
    echo "Apple Silicon bundle is missing its speech worker: $SPEECH_WORKER" >&2
    exit 1
  fi
  if [[ "$(lipo -archs "$SPEECH_WORKER")" != "arm64" ]]; then
    echo "Speech worker must be arm64-only: $SPEECH_WORKER" >&2
    exit 1
  fi
  codesign --verify --strict "$SPEECH_WORKER"
  if [[ ! -s "$MLX_METALLIB" ]]; then
    echo "Apple Silicon bundle is missing its MLX Metal library: $MLX_METALLIB" >&2
    exit 1
  fi
  if [[ "$(LC_ALL=C head -c 4 "$MLX_METALLIB")" != "MTLB" ]]; then
    echo "Apple Silicon bundle contains an invalid MLX Metal library." >&2
    exit 1
  fi
  codesign --verify --strict "$MLX_METALLIB"
elif [[ -e "$SPEECH_WORKER" || -e "$MLX_METALLIB" ]]; then
  echo "Intel bundle must not contain the arm64-only speech worker or MLX library." >&2
  exit 1
fi

codesign --verify --deep --strict "$APP"

open -n -W "$APP" &
OPEN_PID=$!
APP_PID=""
for _ in {1..20}; do
  if ! kill -0 "$OPEN_PID" 2>/dev/null; then
    set +e
    wait "$OPEN_PID"
    LAUNCH_STATUS=$?
    set -e
    echo "App failed to stay open (LaunchServices exit $LAUNCH_STATUS): $APP" >&2
    exit 1
  fi
  APP_PID="$(pgrep -f -x "$EXECUTABLE" | head -n 1 || true)"
  if [[ -n "$APP_PID" ]]; then
    break
  fi
  sleep 0.25
done

if [[ -z "$APP_PID" ]]; then
  kill "$OPEN_PID" 2>/dev/null || true
  wait "$OPEN_PID" 2>/dev/null || true
  echo "LaunchServices did not start the app process: $APP" >&2
  exit 1
fi

sleep 2
if ! kill -0 "$APP_PID" 2>/dev/null; then
  wait "$OPEN_PID" 2>/dev/null || true
  echo "App exited during launch verification: $APP" >&2
  exit 1
fi

kill -TERM "$APP_PID"
wait "$OPEN_PID" 2>/dev/null || true
echo "Launch verified: $APP"

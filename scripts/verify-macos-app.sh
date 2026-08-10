#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: verify-macos-app.sh /path/to/MeowSTT.app}"
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

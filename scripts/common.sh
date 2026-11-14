#!/usr/bin/env bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"

command -v nsh >/dev/null 2>&1 || {
  echo "The nsh CLI is required: https://github.com/longbridge/nsh" >&2
  exit 1
}

nsh_json() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$ROOT/nsh.json" "$1"
}

export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

APP_NAME="$(nsh_json name)"
APP_ID="$(nsh_json id)"
VERSION="${BUILD_NAME:-$(nsh_json version)}"

start_log() {
  LOG="$OUT/logs/$1.log"
  mkdir -p "$(dirname "$LOG")"
  : >"$LOG"
}

quiet() {
  local status=0
  "$@" >>"$LOG" 2>&1 || status=$?
  if (( status != 0 )); then
    tail -n 100 "$LOG" >&2
    echo "Failed: $1 (full log: $LOG)" >&2
  fi
  return "$status"
}

nsh_package() {
  local target="$1" out="$2"
  shift 2
  local args=(--target "$target" --out "$out" --app-version "$VERSION")
  export LISTENOOK_VERSION="$VERSION"
  if [[ -n "${BUILD_NUMBER:-}" ]]; then args+=(--build "$BUILD_NUMBER"); fi
  rm -rf "$out"
  (cd "$ROOT" && quiet nsh package "${args[@]}" "$@")
}

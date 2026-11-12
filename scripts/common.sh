#!/usr/bin/env bash
# Shared by the build scripts: where the app is, its version, and running
# `nsh package` quietly. Source it; it defines ROOT, NSH_DIR and helpers.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NSH_DIR="$ROOT/nsh"
OUT="$ROOT/build"

command -v nsh >/dev/null 2>&1 || {
  echo "The nsh CLI is required: https://github.com/longbridge/nsh" >&2
  exit 1
}

# A value of nsh.json, the app's one source of name, id and version.
nsh_json() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$NSH_DIR/nsh.json" "$1"
}

# The oldest iOS the app runs on. C code among the dependencies is built for
# the SDK's own version unless told, and then does not link with the rest.
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-18.0}"

APP_NAME="$(nsh_json name)"
APP_ID="$(nsh_json id)"
# BUILD_NAME and BUILD_NUMBER override nsh.json, as the release publisher does.
VERSION="${BUILD_NAME:-$(nsh_json version)}"

# The log a build writes to; its tail is shown only when a step fails.
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

# nsh_package TARGET OUT_DIR [more nsh package options]
# Packages the app for a target with the version this build was given.
nsh_package() {
  local target="$1" out="$2"
  shift 2
  local args=(--target "$target" --out "$out" --app-version "$VERSION")
  if [[ -n "${BUILD_NUMBER:-}" ]]; then args+=(--build "$BUILD_NUMBER"); fi
  rm -rf "$out"
  (cd "$NSH_DIR" && quiet nsh package "${args[@]}" "$@")
}

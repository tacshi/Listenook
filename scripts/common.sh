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
  remove_stale_builds
  (cd "$ROOT" && quiet nsh package "${args[@]}" "$@")
}

# nsh package reuses the app's programs it built before (target/**/nsh-app-*) however the code
# changed since, so a package could ship old code. Those whose sources (their Cargo dep-info),
# Cargo.lock, Cargo.toml or nsh.json changed since they were built are removed: nsh builds them
# again, and Cargo only what changed.
remove_stale_builds() {
  local info line output dep stale deps
  local sep=$'\x1f' escaped='\ '
  for info in "$ROOT"/target/*/nsh-app-*.d "$ROOT"/target/*/*/nsh-app-*.d; do
    [[ -f "$info" ]] || continue
    # "<output>: <source> <source> ...", with spaces in paths escaped.
    IFS= read -r line <"$info" || true
    line="${line//"$escaped"/$sep}"
    output="${line%%: *}"
    output="${output//$sep/ }"
    [[ -f "$output" ]] || continue
    stale=""
    for dep in "$ROOT/Cargo.lock" "$ROOT/Cargo.toml" "$ROOT/nsh.json"; do
      [[ "$dep" -nt "$output" ]] && stale=1
    done
    if [[ -z "$stale" ]]; then
      IFS=' ' read -ra deps <<<"${line#*: }"
      for dep in "${deps[@]}"; do
        dep="${dep//$sep/ }"
        if [[ -f "$dep" && "$dep" -nt "$output" ]]; then
          stale=1
          break
        fi
      done
    fi
    if [[ -n "$stale" ]]; then
      echo "Rebuilding $(basename "$output"): its code changed since it was built"
      rm -f "$output"
    fi
  done
}

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="$(mktemp /private/tmp/meowstt-startup-measure.XXXXXX)"
trap 'rm -f "$BINARY"' EXIT

xcrun swiftc \
  -target "$(uname -m)-apple-macosx12.0" \
  "$ROOT/scripts/measure_macos_startup.swift" \
  -o "$BINARY"
"$BINARY" "$@"

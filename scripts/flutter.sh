#!/usr/bin/env bash
# Runs the Flutter SDK pinned in .fvmrc with the given arguments. A bare
# `flutter` from PATH (stable) cannot compile the windowing code.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/flutter-sdk.sh"
exec "$FLUTTER" "$@"

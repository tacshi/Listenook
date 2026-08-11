#!/usr/bin/env bash
set -euo pipefail

APP="${1:?usage: strip-macos-download-metadata.sh /path/to/App.app}"

for ATTRIBUTE in com.apple.quarantine com.apple.provenance; do
  xattr -dr "$ATTRIBUTE" "$APP" 2>/dev/null || true
done

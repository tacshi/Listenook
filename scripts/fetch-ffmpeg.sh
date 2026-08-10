#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:?usage: fetch-ffmpeg.sh macos arm64|x64}"
ARCH="${2:?usage: fetch-ffmpeg.sh macos arm64|x64}"
if [[ "$PLATFORM" != "macos" || ( "$ARCH" != "arm64" && "$ARCH" != "x64" ) ]]; then
  echo "fetch-ffmpeg.sh currently supports: macos arm64|x64" >&2
  exit 2
fi

DEST="$ROOT/.tools/ffmpeg/$PLATFORM/$ARCH"
mkdir -p "$DEST"

if [[ -n "${MEOWSTT_FFMPEG_DIR:-}" ]]; then
  cp "$MEOWSTT_FFMPEG_DIR/ffmpeg" "$DEST/ffmpeg"
  cp "$MEOWSTT_FFMPEG_DIR/ffprobe" "$DEST/ffprobe"
  chmod +x "$DEST/ffmpeg" "$DEST/ffprobe"
  echo "$DEST"
  exit 0
fi

read_manifest() {
  python3 - "$ROOT/packaging/ffmpeg/manifest.json" "$PLATFORM" "$ARCH" "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    item = json.load(handle)[sys.argv[2]][sys.argv[3]][sys.argv[4]]
print(item[sys.argv[5]])
PY
}

for TOOL in ffmpeg ffprobe; do
  URL="$(read_manifest "$TOOL" url)"
  EXPECTED="$(read_manifest "$TOOL" sha256)"
  TARGET="$DEST/$TOOL"
  if [[ -f "$TARGET" ]] && [[ "$(shasum -a 256 "$TARGET" | awk '{print $1}')" == "$EXPECTED" ]]; then
    continue
  fi
  curl --fail --location --retry 3 --output "$TARGET.download" "$URL"
  ACTUAL="$(shasum -a 256 "$TARGET.download" | awk '{print $1}')"
  if [[ "$ACTUAL" != "$EXPECTED" ]]; then
    rm -f "$TARGET.download"
    echo "Checksum mismatch for $TOOL ($ARCH): $ACTUAL" >&2
    exit 1
  fi
  mv "$TARGET.download" "$TARGET"
  chmod +x "$TARGET"
done

echo "$DEST"

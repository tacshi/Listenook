#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/native/speech_worker"
SPEECH_SWIFT_COMMIT="13643ab4361da8f33c8002026c9d357ded0b6896"
SCRATCH="${MEOWSTT_COREML_BUILD_CACHE:-$ROOT/.dart_tool/meowstt-coreml-worker-$SPEECH_SWIFT_COMMIT}"
OUTPUT="${1:-$ROOT/build/native/speech_worker/MeowSTTSpeechWorker}"
MODULE_CACHE="$SCRATCH/module-cache"
XDG_CACHE="$SCRATCH/xdg-cache"

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || {
  echo "MeowSTTSpeechWorker can only be built on Apple Silicon macOS." >&2
  exit 1
}
rg --fixed-strings --quiet "$SPEECH_SWIFT_COMMIT" "$PACKAGE/Package.swift" || {
  echo "speech-swift is not pinned to the expected immutable commit." >&2
  exit 1
}
mkdir -p "$MODULE_CACHE" "$XDG_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
export XDG_CACHE_HOME="$XDG_CACHE"

swift build \
  --package-path "$PACKAGE" \
  --scratch-path "$SCRATCH" \
  --configuration release \
  --product MeowSTTSpeechWorker \
  --disable-sandbox

BINARY="$SCRATCH/arm64-apple-macosx/release/MeowSTTSpeechWorker"
[[ -x "$BINARY" ]] || {
  echo "The Core ML speech worker was not produced at $BINARY." >&2
  exit 1
}
mkdir -p "$(dirname "$OUTPUT")"
cp "$BINARY" "$OUTPUT"
chmod 755 "$OUTPUT"
[[ "$(lipo -archs "$OUTPUT")" == "arm64" ]] || {
  echo "Speech worker is not arm64-only." >&2
  exit 1
}
otool -L "$OUTPUT" | rg --quiet 'CoreML.framework' || {
  echo "Speech worker is not linked to Core ML." >&2
  exit 1
}
echo "Core ML speech worker: $OUTPUT"

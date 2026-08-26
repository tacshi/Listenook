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

BIN_DIR="$(
  swift build \
    --package-path "$PACKAGE" \
    --scratch-path "$SCRATCH" \
    --configuration release \
    --show-bin-path
)"
BINARY="$BIN_DIR/MeowSTTSpeechWorker"
[[ -x "$BINARY" ]] || {
  echo "The Core ML speech worker was not produced at $BINARY." >&2
  exit 1
}
SPEECH_SWIFT_CHECKOUT="$SCRATCH/checkouts/speech-swift"
METAL_BUILD_ROOT="$SCRATCH/meowstt-metal-build"
mkdir -p "$METAL_BUILD_ROOT"
ln -sfn "$SCRATCH/checkouts" "$METAL_BUILD_ROOT/checkouts"
ln -sfn "$BIN_DIR" "$METAL_BUILD_ROOT/release"
METAL_TOOLCHAIN_ID=""
if ! xcrun metal --version >/dev/null 2>&1; then
  METAL_COMPONENT_JSON="$(xcodebuild -showComponent MetalToolchain -json 2>/dev/null)" || {
    echo "The Xcode Metal Toolchain is not installed." >&2
    echo "Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  }
  METAL_TOOLCHAIN_ID="$(
    printf '%s' "$METAL_COMPONENT_JSON" |
      plutil -extract toolchainIdentifier raw -o - - 2>/dev/null
  )"
  [[ -n "$METAL_TOOLCHAIN_ID" ]] || {
    echo "Xcode did not report an installed Metal Toolchain identifier." >&2
    exit 1
  }
  TOOLCHAINS="$METAL_TOOLCHAIN_ID" xcrun metal --version >/dev/null
fi
if [[ -n "$METAL_TOOLCHAIN_ID" ]]; then
  BUILD_DIR="$METAL_BUILD_ROOT" TOOLCHAINS="$METAL_TOOLCHAIN_ID" \
    bash "$SPEECH_SWIFT_CHECKOUT/scripts/build_mlx_metallib.sh" release
else
  BUILD_DIR="$METAL_BUILD_ROOT" \
    bash "$SPEECH_SWIFT_CHECKOUT/scripts/build_mlx_metallib.sh" release
fi
METALLIB="$BIN_DIR/mlx.metallib"
[[ -s "$METALLIB" ]] || {
  echo "The pinned speech-swift MLX Metal library was not produced." >&2
  exit 1
}
[[ "$(LC_ALL=C head -c 4 "$METALLIB")" == "MTLB" ]] || {
  echo "The pinned speech-swift MLX Metal library is invalid." >&2
  exit 1
}
mkdir -p "$(dirname "$OUTPUT")"
cp "$BINARY" "$OUTPUT"
cp "$METALLIB" "$(dirname "$OUTPUT")/mlx.metallib"
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
echo "MLX Metal library: $(dirname "$OUTPUT")/mlx.metallib"

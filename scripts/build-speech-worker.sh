#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE="$ROOT/native/speech_worker"
SPEECH_SWIFT_COMMIT="13643ab4361da8f33c8002026c9d357ded0b6896"
SCRATCH="${LISTENOOK_COREML_BUILD_CACHE:-$ROOT/build/cache/speech-worker-$SPEECH_SWIFT_COMMIT}"
OUTPUT="${1:-$ROOT/build/native/speech_worker/ListenookSpeechWorker}"
MODULE_CACHE="$SCRATCH/module-cache"
XDG_CACHE="$SCRATCH/xdg-cache"

[[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]] || {
  echo "ListenookSpeechWorker can only be built on Apple Silicon macOS." >&2
  exit 1
}
grep -qF "$SPEECH_SWIFT_COMMIT" "$PACKAGE/Package.swift" || {
  echo "speech-swift is not pinned to the expected immutable commit." >&2
  exit 1
}
mkdir -p "$MODULE_CACHE" "$XDG_CACHE"

PLANS="$SCRATCH/out/Intermediates.noindex/XCBuildData"
if [[ -d "$PLANS" ]]; then
  while IFS= read -r MOUNT; do
    if [[ ! -d "$MOUNT" ]]; then
      rm -rf "$PLANS"
      break
    fi
  done < <(grep -rhoE '/[A-Za-z0-9_./-]*MobileAsset\.MetalToolchain-[A-Za-z0-9.]+' "$PLANS" 2>/dev/null | sort -u)
fi
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"
export XDG_CACHE_HOME="$XDG_CACHE"

swift build \
  --package-path "$PACKAGE" \
  --scratch-path "$SCRATCH" \
  --configuration release \
  --product ListenookSpeechWorker \
  --disable-sandbox

BIN_DIR="$(
  swift build \
    --package-path "$PACKAGE" \
    --scratch-path "$SCRATCH" \
    --configuration release \
    --show-bin-path
)"
BINARY="$BIN_DIR/ListenookSpeechWorker"
[[ -x "$BINARY" ]] || {
  echo "The Core ML speech worker was not produced at $BINARY." >&2
  exit 1
}
SPEECH_SWIFT_CHECKOUT="$SCRATCH/checkouts/speech-swift"
METAL_BUILD_ROOT="$SCRATCH/listenook-metal-build"
mkdir -p "$METAL_BUILD_ROOT"
ln -sfn "$SCRATCH/checkouts" "$METAL_BUILD_ROOT/checkouts"
ln -sfn "$BIN_DIR" "$METAL_BUILD_ROOT/release"
export MACOSX_DEPLOYMENT_TARGET=15.0
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
otool -L "$OUTPUT" | grep -q 'CoreML.framework' || {
  echo "Speech worker is not linked to Core ML." >&2
  exit 1
}
echo "Core ML speech worker: $OUTPUT"
echo "MLX Metal library: $(dirname "$OUTPUT")/mlx.metallib"

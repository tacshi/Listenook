#!/usr/bin/env bash
# Downloads the libmpv build of a platform, listed in scripts/mpv-libraries.txt, into
# vendor/mpv/<platform>, checking each file's SHA-256. crates/listenook-mpv's build script runs
# it when that folder is missing; run it again after changing the list.
#
#   scripts/fetch-mpv.sh apple|windows|android
set -euo pipefail

PLATFORM="${1:?usage: fetch-mpv.sh apple|windows|android}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$ROOT/scripts/mpv-libraries.txt"
DEST="$ROOT/vendor/mpv/$PLATFORM"
DOWNLOADS="$ROOT/vendor/mpv/.downloads"
STAMP="$DEST/.fetched"

wanted="$(grep -v '^#' "$LIST" | awk -v p="$PLATFORM" '$1 == p { print $2, $3 }')"
[[ -n "$wanted" ]] || { echo "No libmpv is listed for $PLATFORM." >&2; exit 2; }
if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$wanted" ]]; then exit 0; fi

sha256() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

mkdir -p "$DOWNLOADS"
staging="$DEST.partial"
rm -rf "$staging"
mkdir -p "$staging"
while read -r sum url; do
  file="$DOWNLOADS/$(basename "$url")"
  if [[ ! -f "$file" || "$(sha256 "$file")" != "$sum" ]]; then
    echo "Downloading $(basename "$url")" >&2
    curl -fsSL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  [[ "$(sha256 "$file")" == "$sum" ]] || { echo "$(basename "$url") does not match its checksum." >&2; exit 1; }
  case "$file" in
    *.zip) unzip -qo "$file" -d "$staging" ;;
    *.7z) (cd "$staging" && 7z x -y "$file" >/dev/null) ;;
    *) cp "$file" "$staging/" ;;
  esac
done <<<"$wanted"

# Libdovi is written in Rust and carries its own copy of Rust's standard library, whose symbols
# would clash with the app's. Each slice is linked into one object that exports only `dovi_*`.
hide_dovi() {
  local binary="$1" work arch objects
  work="$(mktemp -d)"
  objects=()
  for arch in $(lipo -archs "$binary"); do
    mkdir -p "$work/$arch"
    lipo -thin "$arch" "$binary" -output "$work/$arch.a" 2>/dev/null || cp "$binary" "$work/$arch.a"
    (cd "$work/$arch" && ar x "../$arch.a")
    ld -r -arch "$arch" -o "$work/$arch.o" "$work/$arch"/*.o -exported_symbol '_dovi_*'
    rm -f "$work/$arch.dovi.a"
    ar rcs "$work/$arch.dovi.a" "$work/$arch.o"
    objects+=("$work/$arch.dovi.a")
  done
  if (( ${#objects[@]} > 1 )); then lipo -create "${objects[@]}" -output "$binary"; else cp "${objects[0]}" "$binary"; fi
  rm -rf "$work"
}

if [[ "$PLATFORM" == "apple" ]]; then
  while IFS= read -r -d '' binary; do
    hide_dovi "$binary"
  done < <(find "$staging/Libdovi.xcframework" -type f -path '*Libdovi.framework*' -name Libdovi -print0)
fi

rm -rf "$DEST"
mv "$staging" "$DEST"
printf '%s' "$wanted" >"$STAMP"
echo "libmpv for $PLATFORM is in $DEST" >&2

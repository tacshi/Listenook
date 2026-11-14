#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cd "$ROOT"

RELEASE_REPO="${LISTENOOK_RELEASE_REPO:-$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["updater"]["github"])' "$ROOT/nsh.json")}"
STAGE_DIR="$OUT/release"
VERSION=""
SKIP_WINDOWS=false
WITH_INTEL=true
WITH_ANDROID=true
NO_UPLOAD=false
ALLOW_BRANCH=false
REUSE=false
RELEASE_BRANCH=main
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "x86_64" ]]; then HOST_ARCH="x64"; fi

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
write_release_notes() {
  local notes_file="$1" range="$2" sha subjects
  while IFS= read -r sha; do
    subjects="$(git log -1 --pretty=tformat:'%b' "$sha" | awk '
      function flush() {
        if (lines == 1 && first ~ /^\*[[:space:]]+/) { sub(/^\*[[:space:]]+/, "", first); print first }
        lines = 0
      }
      /^[[:space:]]*$/ { flush(); next }
      { if (lines == 0) first = $0; lines++ }
      END { flush() }')"
    if [[ -n "$subjects" ]]; then
      printf '%s\n' "$subjects"
    else
      git log -1 --pretty=tformat:'%s' "$sha"
    fi
  done < <(git log --no-merges --pretty=tformat:'%H' "$range") \
    | grep -viE '^(chore|ci|build|test|style|refactor|docs)(\([^)]*\))?!?:' \
    | grep -viE '^(release|bump|merge|wip)([[:space:]]|$)' \
    | grep -vE '^(fixup|squash|amend)!' \
    | sed -E 's/^[a-zA-Z]+(\([^)]*\))?!?:[[:space:]]*//' \
    | sed -E 's/[[:space:]]*\(#[0-9]+\)$//' \
    | awk '!seen[$0]++' \
    | sed -E 's/^/- /' \
    > "$notes_file" || true
}

usage() {
  printf '%s\n' \
    'usage: ./scripts/publish.sh VERSION [options]' \
    '' \
    '  --skip-windows     publish without a Windows build' \
    '  --skip-intel       publish without the other Mac processor'"'"'s package' \
    '  --skip-android     publish without the Android .apk' \
    '  --no-upload        build and write latest.json without publishing' \
    '  --reuse-artifacts  reuse the matching files already in build/release' \
    '  --allow-branch     bypass the main/origin publication check'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-windows) SKIP_WINDOWS=true; shift ;;
    --skip-intel) WITH_INTEL=false; shift ;;
    --skip-android) WITH_ANDROID=false; shift ;;
    --no-upload) NO_UPLOAD=true; shift ;;
    --allow-branch) ALLOW_BRANCH=true; shift ;;
    --reuse-artifacts) REUSE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$VERSION" ]] || die "version supplied twice"; VERSION="$1"; shift ;;
  esac
done

step "preflight"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
  { usage >&2; exit 64; }
TAG="v$VERSION"
BUILD_NUMBER="$(git rev-list --count HEAD)"
HEAD_COMMIT="$(git rev-parse HEAD)"
NEEDS_BUMP=false
if [[ "$(nsh_json version)" != "$VERSION" ]] ||
  ! grep -q "^version = \"$VERSION\"$" "$ROOT/Cargo.toml"; then
  NEEDS_BUMP=true
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null ||
    die "$TAG already exists, but nsh.json has version $(nsh_json version); release versions are immutable"
  [[ "$NO_UPLOAD" == true ]] || BUILD_NUMBER=$((BUILD_NUMBER + 1))
fi
info "version: $VERSION+$BUILD_NUMBER"
info "releases: $RELEASE_REPO"

read_json() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$2" | head -1 | tr -d ' '; }
SOURCE_COMMITS=("$HEAD_COMMIT")
RELEASE_BUILD="$(git rev-list --count HEAD)"
[[ "$NEEDS_BUMP" == false ]] || RELEASE_BUILD=$((RELEASE_BUILD + 1))
if [[ "$NEEDS_BUMP" == false ]] &&
  [[ "$(git diff --name-only HEAD^ HEAD 2>/dev/null | sort | tr '\n' ' ')" == "Cargo.lock Cargo.toml nsh.json " ]]; then
  SOURCE_COMMITS+=("$(git rev-parse HEAD^)")
fi
check_provenance() {
  local sidecar="$1" label="$2" architecture="$3" version build commit known=false
  [[ -f "$sidecar" ]] || die "$label provenance sidecar not found: $sidecar"
  version="$(read_json version "$sidecar")"
  build="$(read_json build "$sidecar")"
  commit="$(read_json commit "$sidecar")"
  [[ "$version" == "$VERSION" ]] || die "$label artifact is version $version, not $VERSION"
  for candidate in "${SOURCE_COMMITS[@]}"; do
    [[ "$commit" != "$candidate" ]] || known=true
  done
  [[ "$known" == true && "$build" == "$RELEASE_BUILD" ]] ||
    die "$label artifact was built from another commit (${commit:0:7}, build $build): this release is build $RELEASE_BUILD, from ${HEAD_COMMIT:0:7}.
Pull on that machine, build it again with -Version $VERSION, and copy it into build/."
  [[ "$(read_json architecture "$sidecar")" == "$architecture" ]] || die "$label architecture must be $architecture"
  [[ "$(read_json dirty "$sidecar")" != "true" && "$(read_json dirty "$sidecar")" != "True" ]] ||
    die "$label artifact was built from a dirty checkout"
}
WIN_EXE="$APP_NAME-$VERSION-windows-x64-release-setup.exe"
WIN_UPDATE="$APP_NAME-$VERSION-windows-x86_64.zip"
if [[ "$SKIP_WINDOWS" == false ]]; then
  [[ -f "$OUT/$WIN_EXE" ]] || die "Windows installer not found: $OUT/$WIN_EXE
Build it on Windows with: .\\scripts\\build-windows.ps1 release -Version $VERSION"
  [[ -f "$OUT/$WIN_UPDATE" ]] || die "Windows updater archive not found: $OUT/$WIN_UPDATE"
  check_provenance "$OUT/$WIN_EXE.build.json" Windows x64
  info "windows: built from $(read_json commit "$OUT/$WIN_EXE.build.json" | cut -c1-7)"
fi
if [[ "$NO_UPLOAD" == false ]]; then
  [[ -z "$(git status --porcelain)" ]] ||
    die "working tree is dirty — commit or stash before releasing"
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git rev-parse "refs/tags/$TAG^{commit}")" == "$HEAD_COMMIT" ]] ||
    die "$TAG already exists on another commit; release versions are immutable"
fi

if [[ "$NO_UPLOAD" == false && "$ALLOW_BRANCH" == false ]]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$BRANCH" == "$RELEASE_BRANCH" ]] ||
    die "releases must be cut from $RELEASE_BRANCH (current: $BRANCH)"
  git fetch --quiet origin "$RELEASE_BRANCH" || die "could not fetch origin"
  [[ "$(git rev-parse "origin/$RELEASE_BRANCH")" == "$HEAD_COMMIT" ]] ||
    die "local $RELEASE_BRANCH must exactly match origin/$RELEASE_BRANCH"
fi
if [[ "$NO_UPLOAD" == false ]]; then
  command -v gh >/dev/null 2>&1 || die "gh is required"
  gh auth status >/dev/null 2>&1 ||
    die "GitHub CLI authentication is invalid; run: gh auth login -h github.com"
  [[ "$(gh repo view "$RELEASE_REPO" --json visibility --jq .visibility)" == PUBLIC ]] ||
    die "$RELEASE_REPO must be public for anonymous app updates"
fi
UPDATE_KEY="${LISTENOOK_UPDATE_KEY:-}"
DEFAULT_UPDATE_KEY="$HOME/.config/listenook/update.secret"
[[ -n "$UPDATE_KEY" || ! -f "$DEFAULT_UPDATE_KEY" ]] || UPDATE_KEY="$DEFAULT_UPDATE_KEY"
if python3 -c 'import json,sys; sys.exit(0 if "publicKey" in json.load(open(sys.argv[1]))["updater"] else 1)' \
  "$ROOT/nsh.json"; then
  [[ -f "$UPDATE_KEY" ]] ||
    die "nsh.json has an updater publicKey: put its secret key at $DEFAULT_UPDATE_KEY or set LISTENOOK_UPDATE_KEY"
fi

mkdir -p "$STAGE_DIR"
NOTES_FILE="$STAGE_DIR/notes.md"
OVERRIDE_NOTES="$ROOT/release-notes/Listenook-$VERSION.md"
if [[ -f "$OVERRIDE_NOTES" ]]; then
  cp "$OVERRIDE_NOTES" "$NOTES_FILE"
else
  PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude "$TAG" 2>/dev/null || true)"
  RANGE="HEAD"
  [[ -z "$PREVIOUS_TAG" ]] || RANGE="$PREVIOUS_TAG..HEAD"
  write_release_notes "$NOTES_FILE" "$RANGE"
  [[ -s "$NOTES_FILE" ]] || printf -- '- Maintenance release\n' > "$NOTES_FILE"
fi

if [[ "$NO_UPLOAD" == false ]]; then
  while :; do
    printf '\n--- release notes for %s ---\n' "$VERSION"
    cat "$NOTES_FILE"
    printf '\n---\n\nPublish these notes? [y]es / [e]dit / [N]o: '
    read -r REPLY
    case "$REPLY" in
      y|Y) break ;;
      e|E)
        "${EDITOR:-${VISUAL:-vi}}" "$NOTES_FILE"
        grep -qE '[^[:space:]]' "$NOTES_FILE" ||
          die "release notes are empty after editing"
        ;;
      *) die "aborted" ;;
    esac
  done
fi

if [[ "$NEEDS_BUMP" == true ]]; then
  step "setting the version to $VERSION"
  python3 - "$ROOT" "$VERSION" <<'PY'
import re, sys, pathlib

root, version = pathlib.Path(sys.argv[1]), sys.argv[2]

def rewrite(name, pattern, what):
    path = root / name
    text, count = re.subn(pattern, lambda m: m.group(1) + version + m.group(2),
                          path.read_text(), count=1, flags=re.M)
    if count != 1:
        sys.exit(f"error: {what} not found in {name}")
    path.write_text(text)

package = re.search(r'^\[package\]\n(?:.*\n)*?name = "([^"]+)"',
                    (root / "Cargo.toml").read_text(), re.M).group(1)
rewrite("nsh.json", r'^(\s*"version"\s*:\s*")[^"]*(")', "the version")
rewrite("Cargo.toml", r'(^\[package\]\n(?:(?!\[).*\n)*?version = ")[^"]*(")', "the package version")
rewrite("Cargo.lock", r'(^name = "%s"\nversion = ")[^"]*(")' % re.escape(package), package)
PY
  if [[ "$NO_UPLOAD" == true ]]; then
    info "left uncommitted (dry run)"
  else
    git add nsh.json Cargo.toml Cargo.lock
    git commit --quiet -m "Release $VERSION"
    git push --quiet origin HEAD ||
      die "could not push the version commit; push it and run again"
    HEAD_COMMIT="$(git rev-parse HEAD)"
    [[ "$(git rev-list --count HEAD)" == "$BUILD_NUMBER" ]] || die "unexpected build number after the version commit"
    info "committed and pushed: Release $VERSION"
  fi
fi

MAC_DMG="$APP_NAME-$VERSION-macos-$HOST_ARCH-release.dmg"
MAC_UPDATE="$APP_NAME-$VERSION-macos-$([[ "$HOST_ARCH" == arm64 ]] && echo aarch64 || echo x86_64).tar.gz"
INSTALLERS=("$MAC_DMG")
UPDATES=("$MAC_UPDATE")

if [[ "$SKIP_WINDOWS" == false ]]; then
  INSTALLERS+=("$WIN_EXE")
  UPDATES+=("$WIN_UPDATE")
fi
OTHER_ARCH=x64
if [[ "$HOST_ARCH" == x64 ]]; then OTHER_ARCH=arm64; fi
if [[ "$WITH_INTEL" == true ]]; then
  INSTALLERS+=("$APP_NAME-$VERSION-macos-$OTHER_ARCH-release.dmg")
  UPDATES+=("$APP_NAME-$VERSION-macos-$([[ "$OTHER_ARCH" == arm64 ]] && echo aarch64 || echo x86_64).tar.gz")
fi
ANDROID_APK="$APP_NAME-$VERSION-android-release.apk"
if [[ "$WITH_ANDROID" == true ]]; then INSTALLERS+=("$ANDROID_APK"); fi

if [[ "$REUSE" == false ]]; then
  find "$STAGE_DIR" -maxdepth 1 -type f ! -name notes.md -delete
  step "building the macOS $HOST_ARCH package"
  BUILD_NAME="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" bash "$ROOT/scripts/build-macos.sh" release
  if [[ "$WITH_INTEL" == true ]]; then
    step "building the macOS $OTHER_ARCH package"
    BUILD_NAME="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" bash "$ROOT/scripts/build-macos.sh" release --arch "$OTHER_ARCH"
  fi
  if [[ "$WITH_ANDROID" == true ]]; then
    step "building the Android package"
    BUILD_NAME="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" bash "$ROOT/scripts/build-android.sh" release
  fi
  for artifact in "${INSTALLERS[@]}" "${UPDATES[@]}"; do
    cp "$OUT/$artifact" "$STAGE_DIR/"
  done
else
  step "reusing staged artifacts"
  for artifact in "${INSTALLERS[@]}" "${UPDATES[@]}"; do
    [[ -f "$STAGE_DIR/$artifact" ]] || die "missing staged artifact: $STAGE_DIR/$artifact"
  done
fi

step "writing latest.json"
MANIFEST_ARGS=(--entry "$ROOT" --notes "$NOTES_FILE" --out "$STAGE_DIR")
[[ -z "$UPDATE_KEY" ]] || MANIFEST_ARGS+=(--key "$UPDATE_KEY")
[[ -z "${LISTENOOK_IOS_LINK:-}" ]] || MANIFEST_ARGS+=(--link "ios=$LISTENOOK_IOS_LINK")
if [[ -n "${LISTENOOK_ANDROID_LINK:-}" ]]; then
  MANIFEST_ARGS+=(--link "android=$LISTENOOK_ANDROID_LINK")
elif [[ "$WITH_ANDROID" == true ]]; then
  MANIFEST_ARGS+=(--link "android=https://github.com/$RELEASE_REPO/releases/download/$TAG/$ANDROID_APK")
fi
rm -f "$STAGE_DIR/latest.json" "$STAGE_DIR/latest.json.sig"
(cd "$STAGE_DIR" && nsh update-manifest "${UPDATES[@]}" "${MANIFEST_ARGS[@]}")
[[ -s "$STAGE_DIR/latest.json" ]] || die "nsh update-manifest wrote no latest.json"

if [[ "$NO_UPLOAD" == true ]]; then
  step "dry run complete"
  info "$STAGE_DIR/latest.json"
  exit 0
fi

ASSETS=()
for artifact in "${INSTALLERS[@]}" "${UPDATES[@]}"; do ASSETS+=("$STAGE_DIR/$artifact"); done
MANIFESTS=("$STAGE_DIR/latest.json")
[[ ! -f "$STAGE_DIR/latest.json.sig" ]] || MANIFESTS+=("$STAGE_DIR/latest.json.sig")

step "tagging $TAG"
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  git tag -a "$TAG" -F "$NOTES_FILE"
fi
git push origin "$TAG"

step "uploading to $RELEASE_REPO"
if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release edit "$TAG" --repo "$RELEASE_REPO" --title "$APP_NAME $VERSION" --notes-file "$NOTES_FILE"
else
  gh release create "$TAG" --repo "$RELEASE_REPO" --verify-tag --draft \
    --title "$APP_NAME $VERSION" --notes-file "$NOTES_FILE"
fi
gh release upload "$TAG" --repo "$RELEASE_REPO" --clobber "${ASSETS[@]}"
gh release upload "$TAG" --repo "$RELEASE_REPO" --clobber "${MANIFESTS[@]}"

step "publishing"
gh release edit "$TAG" --repo "$RELEASE_REPO" --draft=false --latest
info "https://github.com/$RELEASE_REPO/releases/tag/$TAG"

#!/usr/bin/env bash
# Builds and publishes a Listenook release from macOS: the macOS app is
# built here, the Windows and Intel Mac artifacts are brought from their
# machines, and everything goes to a GitHub Release of this repository with
# the manifest (`latest.json`) the in-app updater reads.
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
cd "$ROOT"

# Where installed apps look: nsh.json's "updater".
RELEASE_REPO="${LISTENOOK_RELEASE_REPO:-$(python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["updater"]["github"])' "$NSH_DIR/nsh.json")}"
STAGE_DIR="$OUT/release"
VERSION=""
SKIP_WINDOWS=false
WITH_INTEL=false
WITH_ANDROID=false
NO_UPLOAD=false
ALLOW_BRANCH=false
REUSE=false
RELEASE_BRANCH=main
HOST_ARCH="$(uname -m)"
if [[ "$HOST_ARCH" == "x86_64" ]]; then HOST_ARCH="x64"; fi

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
# The changes since the last release, one per line: commit subjects, and for
# a squash merge the subjects of the commits it holds. GitHub writes those
# as "* <subject>" paragraphs of the body; a "* " line with more lines under
# it is a list inside one commit's own message, not a subject.
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
    '  --with-intel       also build and include the Intel Mac package' \
    '  --with-android     build and include the Android .apk' \
    '  --no-upload        build and write latest.json without publishing' \
    '  --reuse-artifacts  reuse the matching files already in build/release' \
    '  --allow-branch     bypass the main/origin publication check'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-windows) SKIP_WINDOWS=true; shift ;;
    --with-intel) WITH_INTEL=true; shift ;;
    --with-android) WITH_ANDROID=true; shift ;;
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
info "version: $VERSION+$BUILD_NUMBER"
info "releases: $RELEASE_REPO"
# The updater compares the version in nsh.json, and the manifest is written
# from it: it has to be the one being released.
[[ "$(nsh_json version)" == "$VERSION" ]] ||
  die "nsh/nsh.json has version $(nsh_json version): set it and nsh/Cargo.toml to $VERSION, commit, and run again"
grep -q "^version = \"$VERSION\"$" "$NSH_DIR/Cargo.toml" ||
  die "nsh/Cargo.toml is not at version $VERSION"
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
# A signed manifest, when the app has a key to check it with.
UPDATE_KEY="${LISTENOOK_UPDATE_KEY:-}"
# Where the key is kept when nothing says otherwise: outside the repository.
DEFAULT_UPDATE_KEY="$HOME/.config/listenook/update.secret"
[[ -n "$UPDATE_KEY" || ! -f "$DEFAULT_UPDATE_KEY" ]] || UPDATE_KEY="$DEFAULT_UPDATE_KEY"
if python3 -c 'import json,sys; sys.exit(0 if "publicKey" in json.load(open(sys.argv[1]))["updater"] else 1)' \
  "$NSH_DIR/nsh.json"; then
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

# What each platform contributes: installers people download, and the
# archives the updater downloads (named as `nsh update-manifest` expects).
MAC_DMG="$APP_NAME-$VERSION-macos-$HOST_ARCH-release.dmg"
MAC_UPDATE="$APP_NAME-$VERSION-macos-$([[ "$HOST_ARCH" == arm64 ]] && echo aarch64 || echo x86_64).tar.gz"
INSTALLERS=("$MAC_DMG")
UPDATES=("$MAC_UPDATE")

# An artifact built on another machine has to come from this very commit.
read_json() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$2" | head -1 | tr -d ' '; }
check_provenance() {
  local sidecar="$1" label="$2" architecture="$3"
  [[ -f "$sidecar" ]] || die "$label provenance sidecar not found: $sidecar"
  [[ "$(read_json version "$sidecar")" == "$VERSION" ]] || die "$label version mismatch"
  [[ "$(read_json build "$sidecar")" == "$BUILD_NUMBER" ]] || die "$label build-number mismatch"
  [[ "$(read_json commit "$sidecar")" == "$HEAD_COMMIT" ]] || die "$label commit mismatch"
  [[ "$(read_json architecture "$sidecar")" == "$architecture" ]] || die "$label architecture must be $architecture"
  [[ "$(read_json dirty "$sidecar")" != "true" && "$(read_json dirty "$sidecar")" != "True" ]] ||
    die "$label artifact was built from a dirty checkout"
}

if [[ "$SKIP_WINDOWS" == false ]]; then
  WIN_EXE="$APP_NAME-$VERSION-windows-x64-release-setup.exe"
  WIN_UPDATE="$APP_NAME-$VERSION-windows-x86_64.zip"
  [[ -f "$OUT/$WIN_EXE" ]] || die "Windows installer not found: $OUT/$WIN_EXE
Build it on Windows with: .\\scripts\\build-windows.ps1 release -Version $VERSION"
  [[ -f "$OUT/$WIN_UPDATE" ]] || die "Windows updater archive not found: $OUT/$WIN_UPDATE"
  check_provenance "$OUT/$WIN_EXE.build.json" Windows x64
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
MANIFEST_ARGS=(--entry "$NSH_DIR" --notes "$NOTES_FILE" --out "$STAGE_DIR")
[[ -z "$UPDATE_KEY" ]] || MANIFEST_ARGS+=(--key "$UPDATE_KEY")
# Phones cannot replace the app themselves: they are sent to these.
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

# A draft is not offered to installed apps: the release becomes visible
# only once every file, the manifest last, is in place.
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

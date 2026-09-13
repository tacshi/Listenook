#!/usr/bin/env bash
# Build and publish a Listenook desktop release from macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/release-notes.sh"

RELEASE_REPO="tacshi/Listenook-Release"
if [[ -z "${RELEASE_REPO_DIR:-}" ]]; then
  RELEASE_REPO_DIR="$ROOT/../Listenook-Release"
  # Keep existing release checkouts usable without moving their working directory.
  if [[ ! -d "$RELEASE_REPO_DIR/.git" && -d "$ROOT/../MeowSTT-Release/.git" ]]; then
    RELEASE_REPO_DIR="$ROOT/../MeowSTT-Release"
  fi
fi
DIST_DIR="$ROOT/dist"
STAGE_DIR="$DIST_DIR/release"
VERSION=""
SKIP_WINDOWS=false
NO_UPLOAD=false
NO_TAG=false
ALLOW_BRANCH=false
REUSE=false
RELEASE_BRANCH=main

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
usage() {
  printf '%s\n' \
    'usage: ./scripts/release.sh VERSION [options]' \
    '' \
    '  --skip-windows     publish macOS while retaining the previous Windows entry' \
    '  --no-upload        build and generate listenook-latest.json without publishing' \
    '  --reuse-artifacts  reuse the matching files already in dist/release' \
    '  --no-tag           do not create the source-repository tag' \
    '  --allow-branch     bypass the main/origin publication check'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-windows) SKIP_WINDOWS=true; shift ;;
    --no-upload) NO_UPLOAD=true; shift ;;
    --no-tag) NO_TAG=true; shift ;;
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
[[ -z "$(git status --porcelain)" ]] ||
  die "working tree is dirty — commit or stash before releasing"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  die "$TAG already exists; release versions are immutable"
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
  [[ -d "$RELEASE_REPO_DIR/.git" ]] ||
    die "clone git@github.com:tacshi/Listenook-Release.git to $RELEASE_REPO_DIR"
  [[ -z "$(git -C "$RELEASE_REPO_DIR" status --porcelain)" ]] ||
    die "the release-repo checkout is dirty: $RELEASE_REPO_DIR"
  [[ "$(git -C "$RELEASE_REPO_DIR" symbolic-ref --short HEAD)" == main ]] ||
    die "the release-repo checkout must be on main"
  RELEASE_REMOTE="$(git -C "$RELEASE_REPO_DIR" remote get-url origin)"
  [[ "$RELEASE_REMOTE" == *"tacshi/Listenook-Release.git" ]] ||
    die "release-repo origin is unexpected: $RELEASE_REMOTE"
  if git -C "$RELEASE_REPO_DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$RELEASE_REPO_DIR" pull --ff-only ||
      die "could not fast-forward the release-repo checkout"
  else
    printf '%s\n\n%s\n' \
      '# Listenook Releases' \
      'Download the latest build from the Releases page. listenook-latest.json is managed by the release publisher.' \
      > "$RELEASE_REPO_DIR/README.md"
    git -C "$RELEASE_REPO_DIR" add README.md
    git -C "$RELEASE_REPO_DIR" commit -m "Initial release repository"
    git -C "$RELEASE_REPO_DIR" push -u origin main
    info "initialized the empty release repository"
  fi
fi

mkdir -p "$STAGE_DIR"
NOTES_FILE="$STAGE_DIR/notes.md"
OVERRIDE_NOTES="$ROOT/release-notes/Listenook-$VERSION.md"
if [[ -f "$OVERRIDE_NOTES" ]]; then
  cp "$OVERRIDE_NOTES" "$NOTES_FILE"
else
  PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
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

WIN_EXE="$DIST_DIR/Listenook-$VERSION-windows-x64-release-setup.exe"
if [[ "$SKIP_WINDOWS" == false ]]; then
  [[ -f "$WIN_EXE" ]] || die "Windows installer not found: $WIN_EXE
Build it on Windows with: .\\scripts\\win-release.ps1 $VERSION"
  SIDECAR="$WIN_EXE.build.json"
  [[ -f "$SIDECAR" ]] || die "Windows provenance sidecar not found: $SIDECAR"
  read_json() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$SIDECAR" | head -1 | tr -d ' '; }
  [[ "$(read_json version)" == "$VERSION" ]] || die "Windows version mismatch"
  [[ "$(read_json build)" == "$BUILD_NUMBER" ]] || die "Windows build-number mismatch"
  [[ "$(read_json commit)" == "$HEAD_COMMIT" ]] || die "Windows commit mismatch"
  [[ "$(read_json architecture)" == "x64" ]] || die "Windows architecture must be x64"
  [[ "$(read_json dirty)" != "true" && "$(read_json dirty)" != "True" ]] ||
    die "Windows artifact was built from a dirty checkout"
fi

if [[ "$REUSE" == false ]]; then
  find "$STAGE_DIR" -maxdepth 1 -type f ! -name notes.md -delete
  step "building signed macOS arm64 and Intel packages"
  BUILD_NAME="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
    bash "$ROOT/scripts/build-release.sh" --arch all
  cp "$DIST_DIR/Listenook-$VERSION-macos-arm64-release.dmg" "$STAGE_DIR/"
  cp "$DIST_DIR/Listenook-$VERSION-macos-arm64-release.zip" "$STAGE_DIR/"
  cp "$DIST_DIR/Listenook-$VERSION-macos-x64-release.dmg" "$STAGE_DIR/"
  cp "$DIST_DIR/Listenook-$VERSION-macos-x64-release.zip" "$STAGE_DIR/"
  if [[ "$SKIP_WINDOWS" == false ]]; then cp "$WIN_EXE" "$STAGE_DIR/"; fi
else
  step "reusing staged artifacts"
  for required in \
    "$STAGE_DIR/Listenook-$VERSION-macos-arm64-release.dmg" \
    "$STAGE_DIR/Listenook-$VERSION-macos-arm64-release.zip" \
    "$STAGE_DIR/Listenook-$VERSION-macos-x64-release.dmg" \
    "$STAGE_DIR/Listenook-$VERSION-macos-x64-release.zip"; do
    [[ -f "$required" ]] || die "missing staged artifact: $required"
  done
  if [[ "$SKIP_WINDOWS" == false ]]; then
    [[ -f "$STAGE_DIR/$(basename "$WIN_EXE")" ]] || die "missing staged Windows installer"
  fi
fi

step "generating listenook-latest.json"
MANIFEST_ARGS=(--version "$VERSION" --build "$BUILD_NUMBER" --dir "$STAGE_DIR" --out "$STAGE_DIR/listenook-latest.json")
if [[ -f "$RELEASE_REPO_DIR/listenook-latest.json" ]]; then
  MANIFEST_ARGS+=(--previous "$RELEASE_REPO_DIR/listenook-latest.json")
fi
dart run tool/make_update_manifest.dart "${MANIFEST_ARGS[@]}"

if [[ "$NO_UPLOAD" == true ]]; then
  step "dry run complete"
  info "$STAGE_DIR/listenook-latest.json"
  exit 0
fi

ASSETS=()
while IFS= read -r asset; do ASSETS+=("$asset"); done < <(
  find "$STAGE_DIR" -maxdepth 1 -type f \
    \( -name '*.dmg' -o -name '*.zip' -o -name '*.exe' \) | sort
)

step "publishing GitHub release assets"
if gh release view "$TAG" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
  gh release edit "$TAG" --repo "$RELEASE_REPO" --title "Listenook $VERSION" --notes-file "$NOTES_FILE"
  gh release upload "$TAG" --repo "$RELEASE_REPO" --clobber "${ASSETS[@]}" "$STAGE_DIR/listenook-latest.json"
else
  gh release create "$TAG" --repo "$RELEASE_REPO" --title "Listenook $VERSION" --notes-file "$NOTES_FILE" "${ASSETS[@]}" "$STAGE_DIR/listenook-latest.json"
fi

step "publishing manifest last"
cp "$STAGE_DIR/listenook-latest.json" "$RELEASE_REPO_DIR/listenook-latest.json"
git -C "$RELEASE_REPO_DIR" add listenook-latest.json
if ! git -C "$RELEASE_REPO_DIR" diff --cached --quiet; then
  git -C "$RELEASE_REPO_DIR" commit -m "release: $TAG"
  git -C "$RELEASE_REPO_DIR" push -u origin HEAD
fi

step "tagging source"
git push origin HEAD
if [[ "$NO_TAG" == false ]]; then
  git tag -a "$TAG" -F "$NOTES_FILE"
  git push origin "$TAG"
fi
info "https://github.com/$RELEASE_REPO/releases/tag/$TAG"
